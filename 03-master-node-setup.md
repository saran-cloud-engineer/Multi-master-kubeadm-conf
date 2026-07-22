# Production Master Node Setup (HIMS-PRD-MN-01/02/03)

Adapted from your working UAT runbook, updated for production: 3-node HA control plane instead of a single master, plus the hardening items from `02-technical-implementation-guide.md`. Run the **common steps** on all 3 masters, then the **first-master-only** steps once, then the **join steps** on MN-02/MN-03.

IP placeholders used below — replace with real assignments before running anything:

| Placeholder | Meaning |
|---|---|
| `MN01_IP` | 10.200.50.129 |
| `MN02_IP` | 10.200.50.130 |
| `MN03_IP` | 10.200.50.143 (new node — confirm actual assigned IP) |
| `CP_VIP` | Control-plane floating IP for HAProxy/keepalived — **get this assigned by network team before starting**, e.g. 10.200.50.150 |
| `INGRESS_VIP` | MetalLB address for ingress-nginx external IP — separate from `CP_VIP`, e.g. 10.200.50.160 |

---

## Portable vs Environment-Specific Values in This Runbook

| Item | Portable? | Notes |
|---|---|---|
| k8s/kubeadm/kubelet/kubectl version pin (`1.31.0-1.1`) | **Environment-specific (deployment choice)** | Tied to this cluster's chosen k8s version — must match exactly across every master/worker in this cluster, but the version itself isn't a hardware fact |
| containerd `SystemdCgroup = true`, kernel modules/sysctl CRI block (`overlay`, `br_netfilter`, `bridge-nf-call-iptables`) | **Portable** | Required by any CNI on any kubeadm node, regardless of spec |
| HAProxy/keepalived config | **Lives in `K8s_multi_master/configs/`, not this file** | This doc no longer carries its own copy — see the "HAProxy + keepalived" step in Section 1 below and `K8s_multi_master/configs/PRODUCTION-VALUES.md` for the full portable/environment-specific breakdown of those files specifically |
| `MN01_IP`/`MN02_IP`/`MN03_IP`/`CP_VIP`/`INGRESS_VIP` | **Environment-specific** | Real IPs for this network — never reused across environments |
| kubelet reserved-resources amounts (500m/1Gi) | **Environment-specific** | Same caveat as in `02-technical-implementation-guide.md` — loosely sized against these specific node RAM/CPU figures |
| `--pod-network-cidr=192.168.0.0/16` | **Environment-specific but flexible** | Must not overlap the real node subnet (10.200.50.0/24 here) — fine as-is for this cluster, re-check for overlap before reusing elsewhere |
| GCP project ID (`alyssaglobal-1e548`), Artifact Registry region (`asia-southeast1`), service account email | **Environment-specific** | Org/project-specific, not reusable |
| Namespace name (`phx-prod`) | **Environment-specific** | This environment's naming convention (mirrors `phx-uat`) |
| ingress-nginx replica count (2), resource requests (2 CPU/2Gi) | **Environment-specific** | Sized for WN-01's spec and the "≥2 replicas for HA" decision, not a universal default |
| MetalLB / csi-driver-nfs version pins (`v0.14.8`, `v4.12.1`) | **Environment-specific (deployment choice)** | Specific versions chosen for this build — verify current k8s 1.31 compatibility before reusing on a different cluster |
| StorageClass `server`/`share` values | **Environment-specific** | Tied to NFS-01's actual IP and export paths |
| NetworkPolicy phased rollout approach; cert-manager/ArgoCD/metrics-server install *procedure* | **Portable** | Same steps regardless of environment — only the ClusterIssuer strategy and exact version pins are environment decisions |

---

## Installation packages needed on each master — consolidated checklist

Everything below runs on **all 3 masters** (MN-01/02/03). This is a quick-reference
checklist gathering every package/tool referenced anywhere in this doc — the detailed
step-by-step walkthrough with explanations is still in the numbered sections below;
use this if you just want the full install list in one place.

```bash
# Base OS packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl apt-transport-https ca-certificates software-properties-common gpg

# containerd (container runtime)
sudo apt install -y containerd

# HA control-plane layer (K8s_multi_master/configs/)
sudo apt install -y haproxy keepalived socat whois   # socat: chk_haproxy.sh backend check; whois: mkpasswd for the stats page hash

# NFS client — required to even mount NFS-01's export at all (etcd off-node
# backup copy, and the app-facing NFS CSI driver later use the same client)
sudo apt install -y nfs-common
```

```bash
# Kubernetes packages (kubeadm/kubelet/kubectl) — needs the k8s apt repo added first, see Section 1 below
sudo apt install -y kubeadm=1.31.0-1.1 kubelet=1.31.0-1.1 kubectl=1.31.0-1.1
sudo apt-mark hold kubeadm kubelet kubectl
```

```bash
# Helm CLI — required before any "helm install" command later in this doc
# (ingress-nginx, csi-driver-nfs, cert-manager) — never actually covered as
# its own step until now. Official apt-repo method, consistent with how the
# Kubernetes repo itself is added below:
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt update
sudo apt install -y helm
```

```bash
# etcdctl — kubeadm does NOT install this on the host; must match the
# cluster's actual etcd version. Run the version-check first, then substitute
# it into the download:
kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'
# e.g. output: registry.k8s.io/etcd:3.5.15-0  <- use this version below

ETCD_VER=v3.5.15   # replace with whatever the command above actually showed
curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd.tar.gz
tar -xzf /tmp/etcd.tar.gz -C /tmp
sudo cp /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
etcdctl version   # confirm it matches
```

```bash
# calicoctl — only needed if/when you actually attempt the Calico eBPF switch
# (02-technical-implementation-guide.md Section 1). Not urgent while on
# standard iptables mode; check docs.tigera.io for the current release/version
# before downloading — don't guess a version here.
```

```bash
# GCP CLI (for the Artifact Registry image pull secret, Section 5) and the
# ArgoCD CLI (Section 11) are covered in full in their own sections below —
# both need their own repo/download setup, not a simple apt install.
```

---

## 1. Common steps — run on MN-01, MN-02, MN-03

### System update & prerequisites
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl apt-transport-https ca-certificates software-properties-common
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### Kernel modules & sysctl — CRI requirements + production tuning
The CRI-required settings are unchanged from your UAT setup; the block below adds the connection-handling tuning from `02-technical-implementation-guide.md` Section 3 (prevents connection-table exhaustion and backlog drops at production concurrency — masters run HAProxy in front of the API server, so they see real connection volume too, not just etcd/apiserver traffic).

```bash
sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe nf_conntrack

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
nf_conntrack
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

**`nf_conntrack` must be explicitly `modprobe`'d, not just `overlay`/`br_netfilter`.** Without it, `net.netfilter.nf_conntrack_max` in the block above silently has nothing to apply to — the kernel only creates `/proc/sys/net/netfilter/nf_conntrack_max` once the module is loaded, and on a bare node before kubeadm/kube-proxy exist, nothing has triggered it to auto-load yet. If `sudo sysctl --system` above ever reports `cannot stat /proc/sys/net/netfilter/nf_conntrack_max: No such file or directory`, that's this — re-run the three `modprobe`/tee/`sysctl --system` commands above in order and it resolves.

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

**`/etc/security/limits.d/99-hims.conf` alone does not reach `containerd` or `kubelet`** — both are started directly by systemd (not via a PAM login session), so they get whatever `LimitNOFILE`/`LimitNPROC` is in their own systemd unit, not the ulimits file above. This matters beyond just these two processes' own file usage: containers launched by containerd typically inherit its process limits at exec time, so a low containerd limit can silently cap every pod on the node too. Check both, and override whichever is lower than what you set above:

```bash
systemctl show containerd | grep LimitNOFILE
systemctl show kubelet | grep LimitNOFILE
```

If either is below the ulimits set above, add a systemd drop-in override for that service — don't edit the package's own unit file directly, a package upgrade would overwrite it. **In practice on Ubuntu, `containerd`'s packaged unit usually needs this override (often ships with a hard limit around `524288` and a soft limit as low as `1024`); `kubelet`'s packaged unit is often already correct (`1048576`/`1048576`) — check both, don't assume either.**

**Write the override file directly — don't use `systemctl edit`'s interactive editor for this.** `systemctl edit` opens an empty file in nano and silently cancels the whole edit if you save without typing anything (`"...override.conf" canceled: temporary file is empty.`, creates nothing) — easy to do by accident, especially over a copied/pasted command sequence. The heredoc approach below can't have that failure mode:

```bash
sudo mkdir -p /etc/systemd/system/containerd.service.d
cat <<EOF | sudo tee /etc/systemd/system/containerd.service.d/override.conf
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
EOF
sudo systemctl daemon-reload
sudo systemctl restart containerd
```
(If you prefer the interactive `systemctl edit containerd` instead, that's fine too — just make sure you actually type the `[Service]` block above into the editor before saving, and watch for two easy silent mistakes in the restart step: `sudo` must be lowercase, and don't add a trailing period after `containerd` — `containerd.` gets read as a literal unit name and systemd looks for `containerd..service`, which doesn't exist.)

**Verify the override actually took effect** before moving on:
```bash
systemctl show containerd | grep LimitNOFILE
```
Expect `LimitNOFILE=1048576` and `LimitNOFILESoft=1048576` — if it still shows the old values, confirm the override file actually has content: `cat /etc/systemd/system/containerd.service.d/override.conf`.

Repeat the same override (`/etc/systemd/system/kubelet.service.d/override.conf`) / `daemon-reload` / restart for `kubelet` **only if** its `LimitNOFILE` also came back low — often it won't need it. Note kubelet isn't running yet at this point in the bootstrap (it only starts serving once `kubeadm init`/`join` runs in Section 2/3 below) — the override still applies once it does.

### Validating everything in this section, before moving on

```bash
# Swap actually off
swapon --show          # should print NOTHING
free -h                 # "Swap:" row should show 0 across the board

# Kernel modules loaded
lsmod | grep -E 'overlay|br_netfilter'                    # both should appear
cat /proc/sys/net/bridge/bridge-nf-call-iptables          # should print 1

# sysctl values actually applied, not just written to file
sysctl net.core.somaxconn net.core.netdev_max_backlog net.ipv4.ip_local_port_range \
       net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
       net.netfilter.nf_conntrack_max fs.file-max vm.swappiness
# each should echo back the value you set, not a distro default

# Ulimits file is correct (governs future login/PAM sessions, not already-running daemons)
cat /etc/security/limits.d/99-hims.conf

# containerd healthy and correctly configured
sudo systemctl status containerd                          # expect "active (running)"
grep SystemdCgroup /etc/containerd/config.toml            # expect "SystemdCgroup = true"

# The LimitNOFILE fix above, confirmed
systemctl show containerd | grep LimitNOFILE
systemctl show kubelet | grep LimitNOFILE
```

Only once containerd's `LimitNOFILE` shows the value you set is this section actually done — a clean `systemctl status` output alone doesn't confirm the override took effect.

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

### Install Kubernetes components
```bash
sudo apt install -y kubeadm=1.31.0-1.1 kubelet=1.31.0-1.1 kubectl=1.31.0-1.1
sudo apt-mark hold kubeadm kubelet kubectl
```

### kubelet reserved resources (before joining the cluster)
This is the `02-technical-implementation-guide.md` Section 4 change — set it up before `kubeadm init`/`join` so the node enforces reservations from the moment it joins, not retrofitted afterward.

**Sizing basis:** ~10% of this node's CPU/RAM combined (kubeReserved + systemReserved), with a ~1 vCPU/2 GiB floor — at 4 vCPU/12 GB, the floor is what actually applies here. Full formula and a worked dev-vs-prod example in `02-technical-implementation-guide.md` Section 8 — recompute rather than copy if this ever runs on different-sized masters.

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
**Don't pass this file via `kubeadm init --config`** — kubeadm rejects mixing `--config` with `--control-plane-endpoint`/`--pod-network-cidr`/`--upload-certs`; those become part of the config file's own `ClusterConfiguration`/`InitConfiguration` documents if you go that route, and mixing produces a hard error. Simplest correct path, used consistently for MN-01/02/03 in this doc: run `kubeadm init`/`join` with the plain CLI flags as shown below, then apply this `KubeletConfiguration` **after** the node joins by merging it into `/var/lib/kubelet/config.yaml` and restarting kubelet (kubeadm-managed nodes get their base `KubeletConfiguration` from the `kubelet-config` ConfigMap in `kube-system`; this file supplies the node-local overrides on top of it — see Section 2 for MN-01 and Section 3 for MN-02/03).

### HAProxy + keepalived — control-plane load balancer

**Single source of truth for this is `K8s_multi_master/configs/` — do not deploy an inline sketch here.** That folder has the production-ready version: a 3-layer health check (process + port + actual backend health via HAProxy's admin socket, not just `killall -0 haproxy`), a TLS-handshake backend check, `nopreempt` to avoid VIP flapping when a recovered master rejoins, unicast VRRP, an authenticated stats endpoint, log rotation, `notify.sh` hooks for VRRP state transitions, and the etcd backup/restore playbook — none of which an inline version here would have without duplicating (and inevitably drifting from) that folder.

Steps:
1. Copy `haproxy.cfg`, `keepalived.conf`, `chk_haproxy.sh`, `notify.sh`, `rsyslog-haproxy.conf`, and `logrotate-haproxy` from `K8s_multi_master/configs/` onto each of MN-01/02/03, per that folder's own `DEPLOY_TO_KUBEADM_CLUSTER.md`.
2. Fill in whatever's still outstanding per `K8s_multi_master/configs/PRODUCTION-VALUES.md` (MN-03's real IP, `CP_VIP` itself, the actual interface name, a `virtual_router_id` collision check, a real VRRP auth password, and a real HAProxy stats password hash) — none of these should be deployed as the example placeholder values.
3. Validate with the test commands in `06-validation-testing.md`'s `K8s_multi_master/configs/` section (syntax checks, service status, VIP ownership, and a manual failover test) before moving on to Section 2 below.

This gives you the floating `CP_VIP` in front of the 3 API servers, so losing any one master doesn't break `kubectl`/worker access — resolving the etcd-quorum HA gap from `01-architecture-plan.md` Section 2. Only proceed to `kubeadm init` once HAProxy and keepalived report healthy on all 3 masters.

---

## 2. First master only (MN-01) — cluster bootstrap

**If HAProxy is already running on this node (per Section 1), stop it first** — both
HAProxy and kube-apiserver want port 6443, and HAProxy already holding it will make
this command fail with `[ERROR Port-6443]: Port 6443 is in use`. See
`K8s_multi_master/configs/PORT-6443-CONFLICT-FIX.md` for the full fix (stop HAProxy for
this step, restrict both processes to their own specific address afterward, then bring
HAProxy back) — don't just retry this command as-is if you hit that error.

```bash
sudo systemctl stop haproxy   # only if it's already running — see the conflict-fix doc above

sudo kubeadm init \
  --control-plane-endpoint "CP_VIP:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=MN01_IP
```

`--apiserver-advertise-address` is explicit here rather than left to kubeadm's auto-detection — on a multi-homed node (more than one NIC), auto-detection can pick the wrong interface; being explicit removes that ambiguity. This is MN-01's own real IP, distinct from `--control-plane-endpoint` (the shared VIP) — the old single-master UAT command only had this flag because there was no VIP concept yet; both flags are needed together now.

### How these two flags actually relate

- **`--apiserver-advertise-address` is per-node.** It tells *this specific* master's own kube-apiserver which of its own IPs to advertise/register itself under. Each master gets its own value here — MN-02 and MN-03 will each use their own real IP when they join, not MN-01's.
- **`--control-plane-endpoint` is cluster-wide and permanent.** It's written once into the `kubeadm-config` ConfigMap and into **every kubeconfig kubeadm ever generates from this point on** — `admin.conf` here on MN-01, and later every worker's `kubelet.conf` (`04-worker-node-setup.md`) and every additional master's config (Section 3 below) when they join. This is what makes the VIP "stick" everywhere downstream, permanently — not just at the moment of joining.

| | `--apiserver-advertise-address` | `--control-plane-endpoint` (`CP_VIP`) |
|---|---|---|
| Scope | Per-node — each master has its own value | Cluster-wide — exactly one value, identical everywhere |
| What it actually is | That master's own real IP | The HAProxy/keepalived floating VIP |
| Set on | Every `kubeadm init`/`join --control-plane` command, once per master | Only the very first `kubeadm init` — never set again after |
| Where it ends up stored | That node's own apiserver registration/etcd peer address | `kubeadm-config` ConfigMap + baked into every kubeconfig ever generated |
| Who reads it | Just that one node's own apiserver process | Every client, forever: `kubectl`, every worker kubelet, every future join |
| Must pre-exist before `kubeadm init`? | No — it's just the node's own already-existing IP | Yes — HAProxy/keepalived must already be up and the VIP reachable |
| Impact if that address becomes unreachable | Only that one master's direct apiserver is affected — HAProxy routes around it | If this were a single master's IP instead of a VIP, the entire cluster becomes unreachable the moment that master dies |

Workers don't have an equivalent "advertise address" for the API server — they're not running one. Whatever address you `kubeadm join` against gets baked permanently into that worker's own `kubelet.conf` as the `server:` field for the rest of that node's life. That's the entire reason `04-worker-node-setup.md` joins against `CP_VIP` and not a specific master's IP: a worker that joined against MN-01's raw IP would be tied to MN-01 specifically forever, and lose cluster connectivity the moment MN-01 goes down, regardless of how many other masters are healthy.

### If you start with a single master and add MN-02/MN-03 later

This works, but only if one thing isn't skipped: **`--control-plane-endpoint` must already be the VIP at this very first `kubeadm init`, even though only MN-01 exists yet.** That means HAProxy + keepalived (`K8s_multi_master/configs/`) must be stood up on day 1 too — even with only one real backend server line in `haproxy.cfg` pointing at MN-01. It's extra setup now, but it avoids the alternative: adding `--control-plane-endpoint` after the fact requires manually patching the `kubeadm-config` ConfigMap and *every already-issued kubeconfig* by hand (every worker's `kubelet.conf` included) — far riskier than doing it once, correctly, up front.

When MN-02/MN-03 actually become available:
1. Add their real IPs as new `server` lines in `haproxy.cfg`, and install HAProxy + keepalived on the new nodes themselves too, with their own `priority`/`unicast_src_ip`/`router_id` per `K8s_multi_master/configs/PRODUCTION-VALUES.md`.
2. The certificate key from `--upload-certs` above **expires after 2 hours** — if you're adding masters weeks or months later, it's long dead. Re-run `sudo kubeadm init phase upload-certs --upload-certs` on MN-01 to get a fresh key first.
3. Run the `kubeadm join --control-plane --certificate-key <new-key> ...` command from Section 3 below on each new master. Nothing about `kubeadm-config` or any existing kubeconfig needs to change — they already point at the VIP.

**Honest caveat:** doing this makes adding masters later painless, but it does **not** give you HA before they actually join. With only MN-01 up, etcd is a single-member "cluster" — same single-point-of-failure exposure as before, just deferred. Treat a single-master period as a temporary state to close out promptly, not a stable end state to leave running.

Note the two join commands kubeadm prints at the end — one for **additional control-plane nodes** (has `--control-plane --certificate-key ...`) and one for **workers**. Save both; the certificate key expires after 2 hours (`kubeadm init phase upload-certs --upload-certs` regenerates it if you miss the window).

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Apply the kubelet reserved-resources config from Section 1 now that the node has
joined — **merge directly into `/var/lib/kubelet/config.yaml`, the actual file kubelet
reads.** Kubelet has no drop-in override directory (unlike systemd services' `.d/`
convention) — a separate `config.yaml.d/` file is never read at all, and that path
doesn't even exist by default:
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
kubectl describe node HIMS-PRD-MN-01 | grep -A6 Allocatable   # confirm Allocatable dropped below Capacity
```

**Recovery, if `kubeadm init` doesn't complete cleanly** (same as your UAT process, unchanged):
```bash
sudo systemctl stop kubelet
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes/manifests
sudo rm -rf /var/lib/etcd
sudo lsof -i :6443 -i :10250 -i :10257 -i :10259 -i :2379 -i :2380
sudo kill -9 $(sudo lsof -t -i :6443 -i :10250 -i :10257 -i :10259 -i :2379 -i :2380)
sudo systemctl restart containerd
sudo systemctl daemon-reexec
sudo systemctl restart kubelet
sudo systemctl enable kubelet
# then re-run the kubeadm init command above
```

### Install Calico CNI (with eBPF prerequisites in mind)
Check kernel version on all nodes first — eBPF dataplane needs 5.3+ (5.10+ recommended):
```bash
uname -r
```
Install Calico (check `https://docs.tigera.io` for the current manifest URL/version tag for your Calico release — don't reuse the old `docs.projectcalico.org` URL from the UAT runbook, that domain is retired):
```bash
kubectl apply -f <current-calico-manifest-url>
```
Enable eBPF mode once Calico is running and connectivity is confirmed on iptables mode first — do this as a **separate, deliberate step** during a maintenance window, not inline with initial bring-up. Full steps and rollback are in `02-technical-implementation-guide.md` Section 1.

### Just installing Calico vs. installing + enabling eBPF

The `kubectl apply` above only gets you standard iptables-mode Calico — eBPF is a separate, deliberate step on top, not something that command enables by itself:

| Aspect | Just installing Calico (this step) | + eBPF enabled (`02` Section 1) |
|---|---|---|
| What it does | Service/NodePort/LoadBalancer routing goes through **kube-proxy's iptables** NAT chains | Replaces kube-proxy's job entirely with an in-kernel eBPF program |
| kube-proxy | Runs normally alongside Calico | Must be explicitly disabled (nodeSelector trick, not deleted) |
| Extra requirement | None beyond standard Calico | Kernel **5.3+** (5.10+ recommended) — check `uname -r` on every node first |
| Setup steps | One manifest apply, done | Manifest apply, **then**: point Calico at the API server directly (ConfigMap), disable kube-proxy, patch `FelixConfiguration` (`bpfEnabled: true`) |
| Performance at scale | Per-packet cost grows roughly with the number of Services/endpoints (26+ here) | Cost stays flat regardless of service count (hash-map lookup, not chain evaluation) |
| Published gain (Calico's own benchmarks) | Baseline | Up to ~30% lower pod-to-pod latency, ~20% higher throughput — vendor figures, not yet measured on this cluster |
| NetworkPolicy enforcement cost | Low single-digit % CPU/latency overhead, grows with policy count | More efficient at the same job — partially offsets the NetworkPolicy cost |
| MetalLB interaction | Standard, widely-tested path | Known configuration interactions (`externalTrafficPolicy`, `bpfExternalServiceMode`) — must be re-verified after switching, per Section 13 below |
| Maturity | Default, most widely used/tested mode | Newer, less common in the wild, but production-supported by Tigera |
| Rollback | N/A | Trivial on a pre-production cluster — flip `bpfEnabled` back to `false`, re-enable kube-proxy |

**In simple terms, why enable it at all:**
- Replaces kube-proxy's iptables rules with a faster in-kernel program for routing Service traffic
- Lower latency for pod-to-pod and pod-to-Service calls
- Performance stays flat as more services/replicas are added — iptables mode gets slower as the service count grows (this cluster has 26+ services), eBPF doesn't
- Less CPU spent per packet processing network rules
- NetworkPolicy checks run more efficiently under eBPF than under iptables
- Optional DSR mode removes one extra network hop on the return path, for a further latency cut
- Not required for the cluster to work — it's a performance upgrade on top of a fully functional default, not a fix for something broken

---

## 3. Additional masters (MN-02, MN-03)

### What actually gets installed on MN-02/MN-03

Exactly the same as MN-01 — there is no separate "additional master" package set. Run **all** of Section 1's **Common steps** on MN-02 (and separately on MN-03) before attempting to join:

1. System update & prerequisites, swap off
2. Kernel modules + sysctl (CRI requirements + `99-hims-k8s.conf` production tuning)
3. Ulimits (`99-hims.conf`)
4. containerd install + `SystemdCgroup = true` + the containerd/kubelet `LimitNOFILE` check
5. Kubernetes 1.31 apt repository
6. `kubeadm`, `kubelet`, `kubectl` packages (same pinned version as MN-01 — `apt-cache policy kubeadm` to confirm before installing if unsure)
7. HAProxy + keepalived (`K8s_multi_master/configs/`), with **this node's own** `priority`/`unicast_src_ip`/`router_id` per `PRODUCTION-VALUES.md` — and add this node's real IP as a new backend line in `haproxy.cfg` on **all** masters (existing ones too), not just this one
8. The `kubelet-extra-config.yaml` file created (not yet applied — that happens after joining, below)

Only once all of that is done does this node attempt to actually join the cluster.

### Where the token, hash, and certificate-key actually come from

Three different values, three different lifetimes — worth being precise about which is which:

| Value | What it's actually for | Lifetime |
|---|---|---|
| `--token` | Temporary credential authenticating the *joining node* to the API server during the join handshake | Default 24 hours from creation, then invalid |
| `--discovery-token-ca-cert-hash` | A hash of the cluster's CA public key — lets the joining node verify it's really talking to this cluster's API server before trusting it | Doesn't expire — tied to the CA cert itself, which doesn't change for the cluster's life |
| `--certificate-key` | Decrypts the control-plane certificates uploaded to a `kubeadm-certs` Secret during `--upload-certs` — **only needed for control-plane joins**, not worker joins | **2 hours** from when it was generated |

All three are generated by running commands **on an already-joined, healthy control-plane node** (MN-01 to start with) — never on MN-02/MN-03 itself, since it isn't part of the cluster yet.

**Scenario A — joining right after MN-01's `kubeadm init`, same session:** all three values are already printed in that command's own output, in the block starting "You can now join any number of the control-plane node...". Just copy that whole command as-is.

**Scenario B — doing this later, terminal long closed, or the certificate-key has expired (very likely if "later" means days/weeks):** regenerate each piece explicitly, run on MN-01:

```bash
# Token + hash together, in one command — prints a ready-to-use join command
kubeadm token create --print-join-command
```
This prints something like `kubeadm join CP_VIP:6443 --token <new-token> --discovery-token-ca-cert-hash sha256:<hash>` — that's the worker-style command; for a control-plane join, take this same token+hash and add the `--control-plane --certificate-key ... --apiserver-advertise-address=...` flags yourself, as shown below.

```bash
# Fresh certificate-key (old one from init is almost certainly expired by now)
sudo kubeadm init phase upload-certs --upload-certs
```
This prints just the key — a 64-character hex string — under a line like `[upload-certs] Using certificate key:`.

```bash
# Only if you need the hash independently, without generating a new token
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'
```

```bash
# See what tokens are currently still valid, if unsure whether you need a new one
kubeadm token list
```

### Join command — on MN-02

**Same HAProxy-vs-kube-apiserver port conflict as MN-01 applies here too** — HAProxy is
already running on this node (from step 7 above) and will collide with kube-apiserver
on port 6443 during `kubeadm join --control-plane` exactly like it did during `kubeadm
init` on MN-01. Follow `K8s_multi_master/configs/PORT-6443-CONFLICT-FIX.md`'s "On MN-02
/ MN-03" section: stop HAProxy, join, patch this node's own `kube-apiserver.yaml`
manifest with `--bind-address=<this node's own IP>`, then start HAProxy back up — don't
just run the join command below against an already-running HAProxy expecting it to work.

```bash
sudo kubeadm join CP_VIP:6443 \
  --token <token-from-scenario-A-or-B> \
  --discovery-token-ca-cert-hash sha256:<hash-from-scenario-A-or-B> \
  --control-plane \
  --certificate-key <certificate-key-from-scenario-A-or-B> \
  --apiserver-advertise-address=MN02_IP
```

And on **MN-03**, the same command with `--apiserver-advertise-address=MN03_IP` instead (and its own fresh token/hash/certificate-key if enough time has passed that the ones used for MN-02 expired too — the token's 24-hour and the certificate-key's 2-hour windows apply the same way regardless of which master you're joining). `kubeadm join --control-plane` accepts `--apiserver-advertise-address` exactly like `kubeadm init` does (Section 2) — each master needs its **own** real IP here, for the same reason MN-01 does: without it, kubeadm auto-detects which local IP to advertise, which can pick the wrong interface on a multi-homed node. This is unrelated to `CP_VIP` in the command above — that address is only used to *reach* the cluster to join it; `--apiserver-advertise-address` is what this node's own apiserver then advertises itself as, permanently, once it's up.

### After joining

Apply the kubelet reserved-resources config on this node too — same as MN-01 (Section
2), **merge directly into this node's own `/var/lib/kubelet/config.yaml`**, not a
drop-in file (kubelet doesn't support one):
```bash
sudo grep -E "^systemReserved|^kubeReserved|^evictionHard|^enforceNodeAllocatable|^containerLogMaxSize|^containerLogMaxFiles" /var/lib/kubelet/config.yaml

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
kubectl describe node <this-node-name> | grep -A6 Allocatable
```

Repeat `mkdir -p $HOME/.kube && sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown ...` on each master if you want local `kubectl` access from all three.

**Verify** before moving on: `kubectl get nodes -o wide` should show this node as `Ready control-plane`, and the etcd member-list check in `06-validation-testing.md` should show 3 healthy members once both MN-02 and MN-03 are in.

---

## 4. Generate worker join command
```bash
kubeadm token create --print-join-command
```
Use this on each worker node — see `04-worker-node-setup.md`.

---

## 5. GCP Artifact Registry image pull secret

Create the production namespace first — nothing else in this doc does it, and every command below assumes it already exists:
```bash
kubectl create namespace phx-prod
```

Unchanged from UAT otherwise, just update the namespace and confirm the service account key is the production one, not the UAT key. Note the key is passed as a literal CLI argument below — it will briefly appear in this shell's history and in `ps` output while the command runs. If this terminal session is logged/recorded anywhere, treat the key as exposed and rotate it afterward; otherwise prefix the command with a space (if `HISTCONTROL=ignorespace` is set) to keep it out of `.bash_history`.
```bash
sudo apt update && sudo apt install -y google-cloud-cli
gcloud auth activate-service-account --key-file=/opt/gcp-service-key/gcp-service-key.json
gcloud config set project alyssaglobal-1e548
gcloud auth configure-docker asia-southeast1-docker.pkg.dev

kubectl create secret docker-registry gcr-docker-config \
  --docker-server=asia-southeast1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat /opt/gcp-service-key/gcp-service-key.json)" \
  --docker-email=mahesh.m@alyssa.global \
  -n phx-prod
```

---

## 6. MetalLB + Ingress — production approach

**This is a deliberate change from the UAT runbook's Method 2 (hostNetwork + single-node taint pinning).** Your UAT setup pins the ingress pod to one named node (`dtd-his-dev-lb`) with no failover — fine for UAT, not acceptable for production where `01-architecture-plan.md` calls for ≥2 ingress replicas with failover. Recommendation: **MetalLB (Method 1) with 2 ingress-nginx replicas and node affinity/anti-affinity**, not hostNetwork pinning to a single node. Reasoning and the specific interaction with Calico eBPF are covered in Section 13 below.

### Install MetalLB
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl get pods -n metallb-system
```

### IP pool
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ingress-pool
  namespace: metallb-system
spec:
  addresses:
  - INGRESS_VIP/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ingress-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - ingress-pool
```

### Install ingress-nginx with 2 replicas, preferring WN-01, spread across nodes
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

`values-production.yaml` for the ingress-nginx chart:
```yaml
controller:
  replicaCount: 2
  publishService:
    enabled: true
  service:
    type: LoadBalancer
    loadBalancerIP: INGRESS_VIP
  resources:
    requests:
      cpu: "2"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "2Gi"
  priorityClassName: hims-critical
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "gateway"
      effect: "NoSchedule"
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: node-role
                operator: In
                values: ["gateway"]
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: ingress-nginx
            topologyKey: kubernetes.io/hostname
```
```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f values-production.yaml
```

This gives you one replica preferring WN-01 (soft affinity — still works if WN-01 is briefly unschedulable) and a second replica forced onto a *different* node by anti-affinity, so a single node failure doesn't take out ingress. MetalLB's L2 mode fails the external IP over to whichever node still has a healthy speaker/backend within a few seconds.

**Sizing basis for the 2 CPU/2Gi request/limit above** — see `02-technical-implementation-guide.md` Section 8: roughly 15-25% of the target node's allocatable capacity (WN-01 here). Recompute this percentage, not the absolute number, if this chart is ever deployed on differently-sized hardware.

### Verify
```bash
kubectl get pods -n ingress-nginx -o wide
kubectl get svc -n ingress-nginx
kubectl logs -n metallb-system deploy/controller | grep "assigned"
kubectl get l2advertisements -n metallb-system
```

---

## 7. CSI Driver (NFS) — StorageClasses split by workload
Per `02-technical-implementation-guide.md` Section 7, uploads/reports/backups get **separate exports**, so a backup job doesn't compete with live upload traffic. Coordinate exact export paths with `05-nfs-server-setup.md`.

```bash
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update
helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs --namespace kube-system --version v4.12.1
```

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-uploads-rwx
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.200.50.138
  share: /srv/nfs/phx_prod_uploads
reclaimPolicy: Retain
mountOptions:
  - hard
  - nfsvers=4.2
  - nconnect=4
  - rsize=1048576
  - wsize=1048576
  - noatime
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-reports-rwx
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.200.50.138
  share: /srv/nfs/phx_prod_reports
reclaimPolicy: Retain
mountOptions:
  - hard
  - nfsvers=4.2
  - nconnect=4
  - rsize=1048576
  - wsize=1048576
  - noatime
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: phx-prod-uploads-pvc
  namespace: phx-prod
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-uploads-rwx
  resources:
    requests:
      storage: 500Gi
```

---

## 8. NetworkPolicies (default-deny + explicit allow)
See `02-technical-implementation-guide.md` Section 6 for the full set — **rolled out in two phases, not one.** Phase 1 (do now) is `default-deny-all` scoped to **Ingress only** plus the Ingress-allow rules for gateway/db-router/redis; this alone closes off lateral movement into those pods without needing to know every service's outbound call graph. Phase 2 (later) extends `default-deny-all` to `Egress` too, once the actual phx-* service-to-service call map is known — applying Egress-default-deny before that map exists would block every DB/Redis call cluster-wide, a full outage, since the current allow rules only cover the *ingress* side of those paths.

Deploy `allow-dns-egress` now anyway, even though Phase 1's Ingress-only default-deny doesn't strictly need it yet — it's what keeps DNS working the moment Phase 2 turns on Egress restrictions, and there's no reason to wait.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: phx-prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

Apply this in the same batch as `default-deny-all`, not as an afterthought.

---

## 9. Metrics server
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl edit deployment metrics-server -n kube-system
# add: --kubelet-insecure-tls
```

## 10. cert-manager
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true
kubectl get pods -n cert-manager
```
Decide the ClusterIssuer approach (ACME via your public CA if supported, or manual `Certificate` resources) before onboarding real ingress hosts — this was flagged as an open decision in `01-architecture-plan.md` Section 7.

## 11. ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -o wide
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
argocd version --client
```

## 12. Monitoring exporters
Deploy `kube-state-metrics` and `node-exporter` into the `monitoring` namespace, pointing Prometheus (on HIMS-PRD-LOG-01, per `01-architecture-plan.md` Section 8) at these targets, plus `redis_exporter` for the two Redis instances from `01-architecture-plan.md` Section 5. **Two changes required to the UAT manifests before reusing them here — not optional:**

- **`node-exporter`'s DaemonSet needs tolerations added, or it silently loses coverage on exactly the nodes that matter most.** As written in your UAT runbook, this manifest has no `tolerations` at all. Once the taints from `04-worker-node-setup.md` Section 2 (`dedicated=gateway`/`db-lb`/`report`) and kubeadm's own automatic `node-role.kubernetes.io/control-plane:NoSchedule` taint on MN-01/02/03 are in place, a DaemonSet with no tolerations simply won't schedule onto any of those 6 nodes — meaning no host-level metrics from the gateway node, the DB routing node, the reporting node, or any master. Add:
  ```yaml
  tolerations:
    - operator: "Exists"
  ```
  This is the standard idiom for cluster-wide monitoring agents — tolerate every taint, since a monitoring DaemonSet's whole job is to run everywhere regardless of what else is scheduled there.
- **`kube-state-metrics` should be a `Deployment`, not a `DaemonSet`.** It watches the API server for object state — it doesn't need one instance per node the way `node-exporter` does (which reads *local* host `/proc`/`/sys`). Running it as a DaemonSet (as in the UAT manifest) means every node runs a redundant copy all hitting the API server and exposing the same cluster-wide metrics — wasteful, and not how it's designed to be deployed upstream. Convert it to a single-replica (or 2-replica, for HA) `Deployment` instead.

---

## 13. Does this affect existing north-south traffic flow?

Going through each production change against the ingress path (external client → MetalLB VIP → ingress-nginx → phx-gateway-service → backend services):

| Change | Affects north-south path? | Notes |
|---|---|---|
| 3-master HA + HAProxy/keepalived | **No** | This fronts the API server (`:6443`) only — control-plane traffic (`kubectl`, kubelet↔apiserver). Completely separate path from application ingress traffic. |
| kubelet reserved resources, sysctl tuning | **No** | Node/OS-level, affects scheduling and connection-handling headroom, not the traffic path itself. |
| Guaranteed QoS on ingress-nginx | **No** | Affects eviction/throttling behavior under pressure, not routing. |
| **Calico eBPF dataplane** | **Yes — verify explicitly before relying on it** | eBPF mode replaces kube-proxy, including how it handles `LoadBalancer`/`NodePort` Service traffic. Calico's eBPF dataplane is designed to fully replace kube-proxy for this path, but MetalLB + Calico eBPF has known configuration interactions (e.g. `externalTrafficPolicy`, `bpfExternalServiceMode`). **Enable eBPF only after ingress-nginx + MetalLB are confirmed working on standard iptables mode first**, then re-test the same external requests immediately after switching, before treating it as done. |
| NetworkPolicies (default-deny) | **Yes, if the allow rules are incomplete** | The explicit `allow-ingress-to-gateway` and `allow-dns-egress` rules in Section 8 above are what keep this path open — apply them in the *same batch* as `default-deny-all`, never default-deny first and "add allows later," or you will have a live outage window. |
| MetalLB + ingress-nginx replica/affinity change (Method 1 vs UAT's Method 2) | **Yes — this is an intentional architecture change** | Replaces UAT's single-node hostNetwork pinning with a floating VIP + 2 replicas. External clients now connect to `INGRESS_VIP` instead of a specific node's IP — update any firewall rules, DNS records, or hardcoded IPs that currently point at the old UAT-style single node. |

**Practical validation before go-live:** after each of the two "Yes" items above, run the same synthetic external request (e.g. `curl -v https://<ingress-host>/health` from outside the cluster) before and after the change, and kill the node currently holding `INGRESS_VIP` mid-test to confirm MetalLB fails over within a few seconds without dropping the connection permanently.
