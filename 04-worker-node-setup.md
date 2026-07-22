# Production Worker Node Setup

Adapted from your UAT worker runbook. Same base steps for every worker, then a **node-specific taint/label step** at the end — this is the piece that didn't exist in the UAT flow because UAT didn't need dedicated node isolation.

Applies to: HIMS-PRD-WN-01, WN-02, WN-03, WN-04, HIMS-PRD-DB-LB-01, HIMS-PRD-RPT-01.

---

## Portable vs Environment-Specific Values in This Runbook

| Item | Portable? | Notes |
|---|---|---|
| sysctl/ulimit tuning block | **Portable** | Same reasoning as `02-technical-implementation-guide.md` / `03-master-node-setup.md` — applies to any node handling real concurrent connections |
| containerd/k8s version install steps (`1.31.0-1.1`) | **Environment-specific (but must match masters exactly)** | Same version-consistency requirement as the masters |
| `CP_VIP` in the join command | **Environment-specific** | Real VIP for this cluster |
| `kubeReserved`/`systemReserved` table per node group | **Environment-specific** | Same caveat as elsewhere — tied to WN-01/WN-02-04/DB-LB-01/RPT-01's actual specs, flat across differently-sized nodes as a simplification |
| Taint/label *key names* (`dedicated`, `node-role`) | **Portable** | Reusable naming convention |
| Taint/label *values and which hostname gets which* (`gateway`→WN-01, `db-lb`→DB-LB-01, `report`→RPT-01) | **Environment-specific** | Tied to this specific hardware assignment — a different node layout needs different pinning |
| `containerLogMaxSize`/`containerLogMaxFiles` (200Mi/7) | **Environment-specific (but a reasonable default)** | Chosen against this per-node local disk capacity; reduce if a node has much less local disk |

---

## 1. Common steps — run on every worker

### System update & prerequisites
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl apt-transport-https ca-certificates software-properties-common
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### Kernel modules & sysctl
Same CRI-required block as UAT, plus the production connection-handling tuning (`02-technical-implementation-guide.md` Section 3) — every worker handles real concurrent connections at 800 users, not just the ones you'd guess (ingress/gateway nodes obviously, but general-pool nodes running phx-* services and Redis too).

```bash
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-hims-k8s.conf
vm.swappiness = 0
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = 1048576
fs.file-max = 2097152
EOF

sudo sysctl --system
```

### Ulimits
```bash
cat <<EOF | sudo tee /etc/security/limits.d/99-hims.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
```

### Install containerd
```bash
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd
```

**`/etc/security/limits.d/99-hims.conf` alone does not reach `containerd` or `kubelet`** — both are started directly by systemd, not via a PAM login session, so they get whatever `LimitNOFILE`/`LimitNPROC` is in their own systemd unit, not the ulimits file above. This matters beyond these two processes' own file usage: containers launched by containerd typically inherit its process limits at exec time, so a low containerd limit can silently cap every pod on this node too — workers are where this bites hardest, since this is where the actual application pods run. Check both, and override whichever is lower than what you set above:

```bash
systemctl show containerd | grep LimitNOFILE
systemctl show kubelet | grep LimitNOFILE
```

If either is below the ulimits set above, add a systemd drop-in override — don't edit the package's own unit file directly, a package upgrade would overwrite it:
```bash
sudo systemctl edit containerd
```
Add in the editor that opens:
```
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
```
Then:
```bash
sudo systemctl daemon-reload
sudo systemctl restart containerd
```
Repeat the same `systemctl edit kubelet` / override / `daemon-reload` / restart for `kubelet` if its `LimitNOFILE` also came back low (kubelet isn't running yet at this point — it starts once `kubeadm join` runs below — the override still applies once it does).

### Add Kubernetes 1.31 repository
```bash
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo apt-key del "8BAF3E3DF27D8B67648A57DC7BB65CCB98664F05" || true
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
```

### Install Kubernetes components (no kubectl needed on workers)
```bash
sudo apt install -y kubeadm=1.31.0-1.1 kubelet=1.31.0-1.1
sudo apt-mark hold kubeadm kubelet
```

### Join the cluster
Get the join command from any master (`03-master-node-setup.md` Section 4):
```bash
sudo kubeadm join CP_VIP:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```
Note this targets the **HAProxy/keepalived VIP** (`CP_VIP`), not a single master's IP — this is the one thing that must be different from the UAT join command, which pointed directly at the single UAT master. If a worker's kubelet config ever gets pointed at one master's IP directly instead of the VIP, that worker silently loses cluster connectivity the moment that specific master goes down, even though the other two are healthy.

### kubelet reserved resources
Apply after joining — same `KubeletConfiguration` content as the masters (`03-master-node-setup.md` Section 1), reproduced here so this doc is self-contained:

```bash
sudo mkdir -p /etc/kubernetes
cat <<EOF | sudo tee /etc/kubernetes/kubelet-extra-config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
enforceNodeAllocatable:
  - pods   # NOT system-reserved/kube-reserved — see 02-technical-implementation-guide.md
           # Section 4: kubelet refuses to start if those are listed without matching
           # cgroup paths we don't set. This still reduces Allocatable correctly on its own.
containerLogMaxSize: 200Mi
containerLogMaxFiles: 7
EOF

```

The file above is a reference copy — **the actual merge target is
`/var/lib/kubelet/config.yaml`**, the one file kubelet actually reads (it only exists
after `kubeadm join` completes, above). Kubelet has no drop-in override directory
(unlike systemd services' `.d/` convention) — a separate `config.yaml.d/` file, or any
path other than `config.yaml` itself, is never read at all:

```bash
# Confirm none of these keys already exist (avoids creating duplicate top-level keys)
sudo grep -E "^systemReserved|^kubeReserved|^evictionHard|^enforceNodeAllocatable|^containerLogMaxSize|^containerLogMaxFiles" /var/lib/kubelet/config.yaml

# If that came back empty, append the settings directly to the real file
cat <<EOF | sudo tee -a /var/lib/kubelet/config.yaml
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
enforceNodeAllocatable:
  - pods   # NOT system-reserved/kube-reserved — see 02-technical-implementation-guide.md
           # Section 4: kubelet refuses to start if those are listed without matching
           # cgroup paths we don't set. This still reduces Allocatable correctly on its own.
containerLogMaxSize: 200Mi
containerLogMaxFiles: 7
EOF

sudo systemctl restart kubelet
kubectl describe node <this-node-name> | grep -A6 Allocatable   # confirm Allocatable dropped below Capacity
```

Values differ slightly in *rationale* by node group (see table below), though currently all resolve to the same numbers across this fleet:

| Node group | kubeReserved | systemReserved | Why |
|---|---|---|---|
| WN-01 | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | Lowest RAM-per-vCPU of the tainted nodes; hosts ingress+gateway+php together |
| WN-02/03/04 | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | General pool — more RAM headroom, same reservation for consistency |
| DB-LB-01 | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | Hosts MySQL Router — the single DB access path, leave real headroom |
| RPT-01 | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | Single-service tainted node |

**Sizing basis:** ~10% of each node's CPU/RAM combined, floored at ~1 vCPU/2 GiB — see `02-technical-implementation-guide.md` Section 8 for the formula and a worked dev-vs-prod example (e.g. a 4-core dev box vs a 12-core prod node). The flat number above is a safe approximation across this specific fleet, not a universal constant — recompute per node if these ever run on different-sized hardware.

### Status check
```bash
sudo systemctl status kubelet
ls -l /var/lib/kubelet
```

### Log rotation
Already included in the `kubelet-extra-config.yaml` block above (`containerLogMaxSize: 200Mi`, `containerLogMaxFiles: 7`) — no separate step needed, this is just calling it out explicitly since it's easy to miss inside a larger YAML block.

---

## 2. Node-specific taints and labels (run once per node, from a master or with kubectl access)

This is the piece that's new versus UAT — production has 3 nodes carrying isolated, critical-path workloads (MySQL Router, the gateway/ingress path, and reporting) that must not share a node with anything else. Pair every taint with a matching label so `nodeAffinity` can actually pull the intended pods there — a toleration alone only *permits* scheduling, it doesn't attract it.

### WN-01 — gateway/ingress/php
```bash
kubectl label node HIMS-PRD-WN-01 node-role=gateway
kubectl taint node HIMS-PRD-WN-01 dedicated=gateway:NoSchedule
```

### DB-LB-01 — MySQL Router / DB routing
```bash
kubectl label node HIMS-PRD-DB-LB-01 node-role=db-lb
kubectl taint node HIMS-PRD-DB-LB-01 dedicated=db-lb:NoSchedule
```

### RPT-01 — reporting (phx-helical-service)
```bash
kubectl label node HIMS-PRD-RPT-01 node-role=report
kubectl taint node HIMS-PRD-RPT-01 dedicated=report:NoSchedule
```

### WN-02/03/04 — general pool
No taint. These carry the rest of the phx-* services plus `redis-session`/`redis-cache` (deliberately **not** placed on DB-LB-01 — see `01-architecture-plan.md` Section 5 for why co-locating Redis with the DB routing node was rejected).

Verify:
```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,LABELS:.metadata.labels
```

Each service's Helm `values-production.yaml` needs the matching toleration + nodeAffinity to actually land on its intended node — see `03-master-node-setup.md` Section 6 for the ingress-nginx example, and apply the same pattern (toleration for the node's taint key/value, `nodeAffinity` on `node-role`) to `phx-db-loadbalance-service`/`phx-php-nginx-service` (→ `db-lb`), `phx-php-service` (→ `gateway`), and `phx-helical-service` (→ `report`).

---

## 3. Does this affect existing traffic flow?

Nothing in this document touches the north-south (external client → ingress) path directly — that's entirely in `03-master-node-setup.md` Section 6/8. The one thing worth double-checking here: **the taints in Section 2 change where pods are *allowed* to schedule.** If any existing UAT-style Helm values file lacks the matching toleration when you deploy it against production, that service's pods will simply fail to schedule on the tainted nodes (stuck `Pending`, visible via `kubectl describe pod` showing a `FailedScheduling` taint mismatch) rather than silently misrouting traffic — so this fails loud, not quiet, but confirm each service's production values file has the right toleration/affinity before first deploy rather than discovering it live.
