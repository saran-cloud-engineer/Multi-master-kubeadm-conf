# Kubernetes Multi-Master (HA Control Plane) — Complete Setup & Failover Guide

This document is the consolidated, production-oriented reference for building a highly
available kubeadm control plane: load-balancer layer → VIP-based `kubeadm init` →
attaching additional control-plane nodes → full failover / disaster-recovery playbook.

Reference topology used throughout this document:

```
VIP (Virtual/Floating IP) : 10.10.10.100
Master1                   : 10.10.10.101
Master2                   : 10.10.10.102
Master3                   : 10.10.10.103
Worker1..N                : 10.10.10.11x
API Server port           : 6443
HAProxy stats port        : 8404 (optional)
```

Replace these IPs/interfaces with your environment's real values.

---

## 1. Architecture at a Glance

```
                    kubectl / kube-apiserver clients
                                |
                                v
                        VIP  10.10.10.100:6443
                                |
                 (Keepalived elects the VIP owner)
                                |
                +---------------+----------------+
                |               |                |
           HAProxy(M1)     HAProxy(M2)      HAProxy(M3)
                |               |                |
        +-------+-------+-------+-------+--------+
        |               |               |
   kube-apiserver   kube-apiserver   kube-apiserver
   controller-mgr   controller-mgr   controller-mgr
   scheduler        scheduler        scheduler
   etcd member      etcd member      etcd member
   (Master1)        (Master2)        (Master3)
```

Key facts (frequently misunderstood):

| Question | Answer |
|---|---|
| Does the API server "run on" the VIP? | No. It binds `0.0.0.0:6443`. The VIP is just another local IP that Linux routes port 6443 traffic through — HAProxy in front of it decides which real apiserver receives the packet. |
| Does `--control-plane-endpoint=VIP` create the VIP? | No. It only **records** the endpoint string inside `kubeadm-config` and every generated kubeconfig. The VIP itself must already exist (created by Keepalived or your external LB) **before** you run `kubeadm init`. |
| What actually owns the VIP? | Keepalived (VRRP), a cloud/hardware load balancer, or DNS+health-check — never kube-apiserver itself. |
| What uses quorum? | Only **etcd** (Raft). HAProxy and Keepalived have no concept of quorum. |
| Minimum masters for real HA? | 3 (tolerates 1 loss). 2 masters is worse than 1 for availability — see §6.1. |

---

## 2. Prerequisites & Version Compatibility Table

| Component | Requirement | Check command |
|---|---|---|
| OS | Same distro/kernel baseline on all masters | `uname -r` |
| Container runtime | containerd (same version on all nodes) | `containerd --version` |
| kubeadm / kubelet / kubectl | **Identical minor version** across all control-plane nodes | `kubeadm version`, `kubelet --version`, `kubectl version --client` |
| Network | All masters + VIP in the same L2 broadcast domain (required for Keepalived/VRRP) | `ip addr`, `ping <VIP>` |
| Firewall | 6443 (API), 2379-2380 (etcd), 10250-10252 (kubelet/scheduler/controller), 8404 (HAProxy stats, optional), VRRP protocol 112 | `firewall-cmd --list-all` / `ufw status` |
| Time sync | NTP/chrony on all nodes (cert validation & etcd depend on clock skew) | `timedatectl` |

---

## 3. Step 1 — Load Balancer Layer (build the VIP first)

You must build the **VIP / load-balancer layer before `kubeadm init`**. The control-plane
endpoint you pass into kubeadm has to already be reachable.

### Method Comparison

| | **Method 1: HAProxy + Keepalived** (self-hosted) | **Method 2: External Load Balancer** (cloud/hardware) |
|---|---|---|
| Where it runs | On the control-plane nodes themselves (or dedicated LB nodes) | Outside the cluster: cloud LB (ELB/ALB, Azure LB, GCP LB), F5, or hardware appliance |
| VIP ownership | Keepalived (VRRP) moves a floating IP between masters | Provider-managed; no VRRP needed |
| Cost | Free, only needs 2 extra packages | May incur cloud LB cost |
| Complexity | You own config, failover timing, split-brain prevention | Provider handles failover; you just point health checks at 6443 |
| Best for | On-prem / bare-metal / self-managed VMs | Cloud-native deployments (AWS/Azure/GCP) |
| Failover speed | ~1-3s (`advert_int` dependent) | Depends on provider health-check interval |
| Requires L2 adjacency | Yes (VRRP is L2) | No |

Pick **Method 1** for on-prem/bare-metal. Pick **Method 2** if you're already on a cloud
provider with a managed LB product.

### 3.1 Method 1 — HAProxy + Keepalived (generic, reusable config)

Install on **every** control-plane node that will host the LB layer (commonly all masters):

```bash
sudo apt update
sudo apt install -y haproxy keepalived
```

**Generic `/etc/haproxy/haproxy.cfg`** (identical on every master — just list all master IPs):

```
global
    log /dev/log local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend kubernetes-api
    bind *:6443
    mode tcp
    option tcplog
    default_backend kube-masters

backend kube-masters
    mode tcp
    balance roundrobin
    option tcp-check
    server master1 10.10.10.101:6443 check fall 3 rise 2
    server master2 10.10.10.102:6443 check fall 3 rise 2
    server master3 10.10.10.103:6443 check fall 3 rise 2

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
```

```bash
sudo systemctl enable --now haproxy
sudo systemctl restart haproxy
```

**Generic `/etc/keepalived/keepalived.conf`** — same file structure on all masters, only
`state` and `priority` differ (highest priority = preferred VIP owner):

```
vrrp_script chk_haproxy {
    script "/usr/bin/pgrep haproxy"
    interval 2
    weight -20   # NEGATIVE: priority drops on failure, so a dead HAProxy actually triggers failover
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    interface eth0                # match your NIC name
    virtual_router_id 51          # same on all masters, unique per cluster on the LAN
    priority 200                  # Master1=200, Master2=150, Master3=100 (unique per node)
    state MASTER                  # MASTER on the highest-priority node, BACKUP elsewhere
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k8s_ha_secret   # change this
    }
    virtual_ipaddress {
        10.10.10.100/24
    }
    track_script {
        chk_haproxy
    }
}
```

> The `track_script` block is important: it ties VIP ownership to a **healthy local
> HAProxy**, not just "server is up." If HAProxy dies but the OS is alive, the VIP still
> fails over.

```bash
sudo systemctl enable --now keepalived
sudo systemctl restart keepalived
sudo systemctl status keepalived
```

**Verify:**

```bash
# On the current VIP owner
ip addr show eth0 | grep 10.10.10.100

# From any other host on the network
nc -zv 10.10.10.100 6443
curl -k https://10.10.10.100:6443/version

# Failover test
sudo systemctl stop keepalived     # on current owner
ip addr show eth0                  # on the next-highest-priority master — VIP should appear here
```

### 3.2 Method 2 — External Load Balancer

Generic pattern (cloud LB or hardware LB):

1. Create a TCP (Layer 4) load balancer — **not HTTP/L7**, the API server does TLS itself.
2. Listener: TCP `6443` → target group of all master IPs on port `6443`.
3. Health check: TCP connect to `6443` (or HTTPS GET `/livez` if the LB supports TLS passthrough health checks).
4. Note the LB's stable address (VIP, static IP, or DNS name) — this becomes your
   `--control-plane-endpoint`.

Example (AWS CLI, illustrative — adapt to your provider):

```bash
aws elbv2 create-load-balancer --name k8s-api-lb --type network \
  --subnets <subnet-ids>

aws elbv2 create-target-group --name k8s-api-tg --protocol TCP --port 6443 \
  --vpc-id <vpc-id> --health-check-protocol TCP

aws elbv2 register-targets --target-group-arn <tg-arn> \
  --targets Id=<master1-instance-id> Id=<master2-instance-id> Id=<master3-instance-id>

aws elbv2 create-listener --load-balancer-arn <lb-arn> \
  --protocol TCP --port 6443 \
  --default-actions Type=forward,TargetGroupArn=<tg-arn>
```

Verify the same way as Method 1: `nc -zv <lb-address> 6443` and
`curl -k https://<lb-address>:6443/version`.

---

## 4. Step 2 — Initialize First Master Against the VIP, Then Attach Others

### 4.1 If this is a brand-new cluster

On **Master1 only** — this is the *only* `kubeadm init` you ever run:

```bash
sudo kubeadm init \
  --control-plane-endpoint "10.10.10.100:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=10.10.10.101
```

| Flag | Purpose |
|---|---|
| `--control-plane-endpoint` | The **VIP/LB address**, written into `kubeadm-config`, `admin.conf`, and every future join's generated kubeconfig. This is what makes future masters attachable to a stable address instead of Master1's real IP. |
| `--upload-certs` | Uploads control-plane certs to a Secret so joining masters can auto-download them (skips manual cert copying). Prints a **certificate key** — save it, it expires in 2 hours by default. |
| `--apiserver-advertise-address` | Master1's **real** IP — what the local apiserver actually binds/advertises, distinct from the VIP. |
| `--pod-network-cidr` | Required by most CNIs (Calico/Flannel/etc.) — match your CNI manifest. |

Save the printed **control-plane join command** and **certificate key** — or regenerate later:

```bash
kubeadm token create --print-join-command
sudo kubeadm init phase upload-certs --upload-certs   # if the cert-key already expired
```

### 4.2 If a cluster already exists and was initialized WITHOUT a VIP

Check first:

```bash
kubectl -n kube-system get cm kubeadm-config -o yaml | grep controlPlaneEndpoint
```

If it's missing or points to Master1's real IP instead of the VIP, patch it before joining
any new master:

```bash
kubectl -n kube-system edit cm kubeadm-config
# set:
#   controlPlaneEndpoint: "10.10.10.100:6443"
```

Also update every existing kubeconfig (`admin.conf`, `~/.kube/config`, CI/CD configs) to
point `server:` at the VIP instead of the old real IP.

### 4.3 Attach Additional Master Nodes to the VIP

On **Master2 / Master3** — install matching kubeadm/kubelet/kubectl/containerd versions
first (must match Master1 exactly), then:

```bash
sudo kubeadm join 10.10.10.100:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key-from-step-4.1>
```

What this does under the hood:

```
kubeadm join --control-plane
    │
    ├─> Connects to VIP:6443 (via HAProxy → any healthy Master)
    ├─> Authenticates using token + CA cert hash
    ├─> Downloads cluster config + certificates (via --certificate-key)
    ├─> Generates a LOCAL admin.conf, controller-manager.conf, scheduler.conf
    ├─> Starts local kube-apiserver, controller-manager, scheduler
    └─> Joins local etcd as a new Raft member (auto-syncs data from existing members)
```

Nothing is manually copied — certificates, RBAC, CoreDNS, and cluster CA all already
exist from Master1's single `kubeadm init`; every subsequent master only ever **joins**.

### 4.4 Verify

```bash
kubectl get nodes -o wide
# master1   Ready   control-plane
# master2   Ready   control-plane
# master3   Ready   control-plane
# worker1   Ready   <none>

kubectl -n kube-system exec etcd-master1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

kubectl cluster-info
kubectl config view --minify | grep server     # should show the VIP, not a master's real IP
```

### 4.5 Command Cheat-Sheet — Init vs Join

| Action | Where | Command |
|---|---|---|
| First-ever init | Master1 only | `kubeadm init --control-plane-endpoint=<VIP>:6443 --upload-certs ...` |
| Regenerate join token | Any existing master | `kubeadm token create --print-join-command` |
| Regenerate cert key (expired) | Any existing master | `kubeadm init phase upload-certs --upload-certs` |
| Join as control-plane | New master | `kubeadm join <VIP>:6443 --token ... --discovery-token-ca-cert-hash ... --control-plane --certificate-key ...` |
| Join as worker | New worker | `kubeadm join <VIP>:6443 --token ... --discovery-token-ca-cert-hash ...` (no `--control-plane`) |
| Check current endpoint | Any master | `kubectl -n kube-system get cm kubeadm-config -o yaml \| grep controlPlaneEndpoint` |

---

## 5. Quorum Refresher (needed to understand §6)

Only **etcd** uses Raft quorum = `floor(N/2) + 1`.

| etcd members (N) | Quorum required | Tolerable failures |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | 0 (worse than 1 — any loss breaks quorum) |
| 3 | 2 | 1 |
| 4 | 3 | 1 (even count wastes a node — no benefit over 3) |
| 5 | 3 | 2 |

**Always deploy an odd number ≥ 3 masters.** Two masters gives you extra failure surface
with zero extra fault tolerance.

---

## 6. Failover & Disaster Recovery Playbook

Decision tree:

```
                         Master Failure
                               |
             +-----------------+------------------+
             |                                     |
       One Master Down                       All Masters Down
             |                                     |
      Is quorum still alive?                Is etcd data recoverable
      (majority of etcd up)                 on any surviving disk?
             |                                     |
        Yes        No                    Yes                No
         |          |                      |                  |
    Normal ops   Quorum-loss          Restore from       Restore from
    continue     recovery (6.2)       surviving disk     etcd snapshot
    (6.1)                             (6.3)               backup (6.3)
```

### 6.1 Single Master / Single etcd-member Failure (quorum intact)

This is the routine case with 3+ masters — no special action required beyond repair.

```bash
# Diagnose
kubectl get nodes
kubectl -n kube-system get pods -o wide
crictl ps -a                      # on the affected master
journalctl -u kubelet -f          # on the affected master

# If only kube-apiserver container crashed (static pod), restarting kubelet
# re-creates the static pod:
sudo systemctl restart kubelet

# Confirm HAProxy marks it healthy again
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock   # or check :8404/stats
```

Impact: **none** to running workloads. `kubectl` traffic transparently continues via the
VIP → remaining healthy masters. Restart of the failed node's control-plane node → etcd
auto re-syncs from the other members once it rejoins (no manual etcd action needed).

### 6.2 Quorum Failure — Minority of Masters Alive (e.g., 1 of 3 up)

This is a **disaster-recovery** procedure, not routine failover — the cluster's API is
effectively read-only or fully unavailable until quorum is restored.

**Restore plan:**

```bash
# 1. Identify surviving, healthy master (the one with the most recent etcd data)
kubectl -n kube-system exec etcd-<survivor> -- etcdctl member list -w table

# 2. Stop kube-apiserver/etcd static pods cluster-wide is not needed; only touch etcd
#    on the survivor. Move the manifest out to stop the static pod:
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak

# 3. Remove the dead members from etcd's membership list (run against the survivor)
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
etcdctl member remove <dead-member-id-1>
etcdctl member remove <dead-member-id-2>

# 4. Force the survivor to run as a single-member cluster (edit the etcd static
#    pod manifest: set --initial-cluster to just itself, --force-new-cluster on
#    first boot only, then remove that flag immediately after it comes up clean)
sudo vi /tmp/etcd.yaml.bak
#   add:  - --force-new-cluster    (TEMPORARY — remove after next step confirms health)

# 5. Restart etcd
sudo mv /tmp/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
watch crictl ps                 # wait for etcd + apiserver to become healthy

# 6. IMPORTANT: remove --force-new-cluster from the manifest immediately after
#    confirming health, otherwise the next restart will corrupt the cluster.

# 7. Rejoin fresh control-plane nodes to replace the dead ones
kubeadm token create --print-join-command
sudo kubeadm init phase upload-certs --upload-certs
# on each new master:
kubeadm join <VIP>:6443 --token ... --discovery-token-ca-cert-hash ... \
  --control-plane --certificate-key ...
```

This process **temporarily sacrifices redundancy** (runs on 1 member) to regain
availability, then rebuilds back to 3 members. Do it carefully and avoid any further
writes to etcd mid-procedure.

### 6.3 All Masters Down — Full Restore, Without Affecting Worker-Node Applications

Key fact that makes this safe: **worker nodes keep running existing Pods** even with
zero control-plane availability, because kubelet, containerd, and already-programmed
`kube-proxy`/CNI rules on workers don't depend on a live API server for pods that are
already scheduled. Only *new* scheduling, scaling, secret/configmap changes, and node
health eviction stop working.

**Restore plan (etcd snapshot):**

```bash
# 1. Take/locate the latest etcd snapshot (you should be taking these on a schedule —
#    see §7, and configs/ETCD_BACKUP.md for a ready-to-deploy daily backup with
#    7-day local rotation + an off-node copy hook). If none of the master disks
#    are usable, this snapshot is your only path.
etcdctl snapshot save /backup/etcd-snapshot-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 2. Provision a fresh Master1 (same hostname/IP if possible, to minimize churn for
#    kubelets on workers, which still trust the old CA/certs).

# 3. Restore the snapshot into a new etcd data dir
etcdctl snapshot restore /backup/etcd-snapshot-<date>.db \
  --name master1 \
  --initial-cluster master1=https://10.10.10.101:2380 \
  --initial-cluster-token etcd-cluster-restored \
  --initial-advertise-peer-urls https://10.10.10.101:2380 \
  --data-dir /var/lib/etcd-restored

# 4. Point the etcd static pod manifest's --data-dir at /var/lib/etcd-restored,
#    keep the SAME certs/CA that workers already trust (from /etc/kubernetes/pki),
#    then start kubelet so the static pods (etcd, apiserver, controller, scheduler)
#    come up.
sudo systemctl restart kubelet
watch crictl ps

# 5. Verify control plane is healthy and workers reconnect on their own —
#    they keep retrying the SAME VIP/endpoint they were already configured with.
kubectl get nodes
kubectl get pods -A -o wide         # confirm existing workloads are untouched

# 6. Re-join Master2 / Master3 as normal control-plane joins (§4.3) to
#    restore full HA.
```

**Why worker applications are unaffected (if you preserve CA/certs and the VIP/endpoint):**

```
Worker kubelet/containerd
        |
        v
   Already-running Pods  ---->  Still serving traffic
        |
        v
   kube-proxy iptables/ipvs rules --> unchanged, no API dependency
        |
        v
   Only NEW api calls (deploy/scale/new pod) are blocked until API is back
```

If you provision the restored master with a **different** IP/hostname and a **new**
cluster CA, workers will NOT reconnect automatically — you'd have to re-join every
worker, which does disrupt them. Always restore onto the same identity (or update the
VIP/DNS + re-distribute new CA/kubelet configs deliberately) if you must change it.

### 6.4 Other Failure Scenarios

| Scenario | Symptom | Restore Action |
|---|---|---|
| Client certs expired (kubeadm certs are valid 1 year by default) | `x509: certificate has expired` on `kubectl` | `sudo kubeadm certs renew all`, then restart control-plane static pods (`kubelet restart`) |
| etcd disk full | etcd logs `mvcc: database space exceeded` | `etcdctl defrag`, `etcdctl compact <revision>`, alert on `etcd_mvcc_db_total_size_in_bytes` before it recurs |
| Split-brain VIP (two nodes both think they own VIP) | Intermittent API timeouts, duplicate ARP replies | Fix `virtual_router_id` collisions (must be unique per broadcast domain), verify `track_script` health-gates HAProxy, check VRRP packets aren't being filtered/firewalled |
| Network partition between masters (but each individually alive) | etcd loses quorum from perspective of minority partition | Minority side becomes read-only/unavailable automatically (correct Raft behavior) — restore network, cluster self-heals without manual intervention |
| Certificate key for `--upload-certs` expired before all masters joined | `kubeadm join --control-plane` fails at "certificate key has expired" | Re-run `kubeadm init phase upload-certs --upload-certs` on any healthy master, use the new key |
| HAProxy up but backend master unhealthy | HAProxy `show stat` shows server as `DOWN` | Check `kube-apiserver` container/static pod on that master; HAProxy will auto re-include it once health checks pass |
| Keepalived process dies but node/OS is fine | VIP doesn't fail over even though HAProxy is dead on that node | Confirm `track_script` is configured (this doc's config includes `chk_haproxy`) — without it, Keepalived only checks its own process, not HAProxy's health |
| Wrong kubelet/kubeadm version on a joining master | `kubeadm join` fails version skew check | Match versions exactly to existing masters before joining (`apt-cache policy kubeadm` to pick the right version) |

---

## 7. Operational Best Practices

* Use **3 (or 5) control-plane nodes** — never 2, never an even number as the sole HA target.
* Only **one** `kubeadm init`, ever, per cluster. Every other master **joins**.
* Always set `--control-plane-endpoint` to the VIP/LB/DNS at init time, even for a
  single-master cluster you plan to scale out later — retrofitting it later requires
  manually patching `kubeadm-config` and every kubeconfig (see §4.2).
* Keep the load-balancer layer (HAProxy/Keepalived or external LB) logically separate
  from "is a master healthy" — use `track_script`/health checks tied to the actual
  apiserver, not just host liveness.
* Take **scheduled etcd snapshots** (`etcdctl snapshot save`) off-box, and periodically
  test restoring them — an untested backup is not a backup. See
  `configs/ETCD_BACKUP.md` for a ready-to-deploy daily backup (systemd timer, 7-day
  local rotation, off-node copy hook, restore-path testing steps).
* Practice the failover drills before you need them for real:
  * Kill Keepalived on the VIP owner → confirm VIP moves, `kubectl` keeps working.
  * Kill kube-apiserver on one master → confirm HAProxy routes around it.
  * Simulate quorum loss in a lab (not prod) → walk through §6.2 end-to-end.
* Never hand-edit `controller-manager.conf`, `scheduler.conf`, or `kubelet.conf` — they
  are kubeadm-managed. `admin.conf` is the one safe to inspect/copy for `kubectl` use.
* Document your actual VIP, priorities, and `virtual_router_id` per cluster — reusing a
  `virtual_router_id` across two clusters on the same LAN causes VRRP collisions.
