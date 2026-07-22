# Validation & Testing Guide

One command per config item, across every file in `cluster_conf_plan/` (`00`-`05`) and
`K8s_multi_master/configs/`. Every row says exactly **where** to run it — that's the
part that was missing before. "Run on" means log into that specific host via SSH unless
otherwise noted; "any kubectl-access node" means anywhere your `~/.kube/config` points
at the cluster (a master, or your own workstation if you copied `admin.conf` there) —
it does **not** mean the command executes on that node's workload, just that `kubectl`
talks to the API server from there.

---

## 00 — Server requirements: confirm the inventory is real

| Check | Command | Run on |
|---|---|---|
| vCPU count matches inventory | `nproc` | Each host individually (MN-01/02/03, WN-01-04, DB-01/02, DB-LB-01, NFS-01, DB-IG-01, DB-RPT-01, LOG-01, RPT-01) |
| RAM matches inventory | `free -h` | Same, each host individually |
| Disk size matches inventory | `lsblk` | Same, each host individually |

---

## 01/02 — Architecture & implementation guide: cross-reference tests

Section 01 is decisions, Section 02 is how-to — neither has its own separate config to
run in isolation; their claims are validated by the concrete tests below, so this
section just maps claim → where its test actually lives, so nothing gets skipped.

| Claim in 01/02 | Where it's actually tested |
|---|---|
| 3-master etcd quorum | `K8s_multi_master/configs` section below, "etcd member list" |
| Calico eBPF enabled correctly | `03` section below |
| Guaranteed QoS applied | `03` section below (ingress-nginx/MySQL Router/redis-session) |
| sysctl/ulimit tuning applied | `03`/`04` sections below (masters and workers) |
| kubelet reserved resources applied | `03`/`04` sections below |
| NetworkPolicies enforced correctly | `03` section below |
| NFS efficiency tuning applied | `05` section below |

### Special case: Calico iptables vs eBPF — test both, before go-live

Since this cluster hasn't taken real traffic yet (per `02-technical-implementation-guide.md` Section 1), the safe move is to decide iptables-vs-eBPF **before** go-live by running the same test twice, not to treat it as a risky live change requiring a maintenance window. Run this block once right after initial Calico install (standard iptables mode), record the results, switch to eBPF per `02`'s "Enable steps," then run the exact same block again and compare:

```bash
# Pod-to-pod
kubectl run nettest --rm -it --image=nicolaka/netshoot -n phx-prod -- ping -c 4 <another-pod-ip>

# Pod-to-Service (ClusterIP)
kubectl run svctest --rm -it --image=nicolaka/netshoot -n phx-prod -- curl -v telnet://<mysql-router-svc>.phx-prod:6446

# MetalLB LoadBalancer path (external)
curl -v https://<INGRESS_VIP>/health

# NetworkPolicy still enforcing under this dataplane mode
kubectl run blocked-test --rm -it --image=nicolaka/netshoot -n some-other-namespace -- curl -v --max-time 3 telnet://<mysql-router-svc>.phx-prod:6446

# DNS
kubectl run dnstest --rm -it --image=busybox -n phx-prod -- nslookup kubernetes.default
```

**Run on:** any kubectl-access node, except the MetalLB `curl` line, which must run from a client outside the cluster (same rule as the ingress test in the `03` table below) — the test pods land wherever the scheduler puts them, that's fine, you're testing the network path, not a specific node.

---

## 03 — Master node setup

| Check | Command | Run on |
|---|---|---|
| sysctl values applied | `sysctl net.core.somaxconn net.ipv4.ip_local_port_range net.netfilter.nf_conntrack_max fs.file-max vm.swappiness` | Each master individually (MN-01, MN-02, MN-03) |
| ulimits applied | `ulimit -n` (as the user that will run workloads; check a live process with `cat /proc/<pid>/limits`) | Each master individually |
| containerd running, correct cgroup driver | `systemctl status containerd` and `grep SystemdCgroup /etc/containerd/config.toml` | Each master individually |
| kubeadm/kubelet/kubectl versions pinned correctly | `kubeadm version && kubelet --version && kubectl version --client` | Each master individually |
| kubelet reserved resources took effect | `kubectl describe node <node-name> \| grep -A6 Allocatable` (compare against `Capacity`) | Any kubectl-access node, targeting each master's node name in turn |
| kubeadm init succeeded, cluster reachable | `kubectl get nodes -o wide && kubectl cluster-info` | MN-01 (or any kubectl-access node once `admin.conf` is copied) |
| kubeconfig points at the VIP, not a single master | `kubectl config view --minify \| grep server` — must show `CP_VIP`, not a master's real IP | Any kubectl-access node |
| All 3 masters joined and healthy | `kubectl get nodes -o wide` (expect 3× `Ready control-plane`) | Any kubectl-access node |
| etcd has 3 healthy members | `kubectl -n kube-system exec etcd-<any-master-podname> -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list -w table` | Any kubectl-access node |
| Calico running, eBPF status (if enabled) | `calicoctl node status` and `kubectl -n kube-system logs -l k8s-app=calico-node \| grep -i bpf` | Any kubectl-access node for both; for `bpftool prog list` specifically, that inspects the local kernel, so run it directly on each node individually |
| Pod-to-pod / pod-to-MySQL-Router connectivity after any CNI change | `kubectl run nettest --rm -it --image=nicolaka/netshoot -n phx-prod -- curl -v telnet://<mysql-router-svc>:6446` | Any kubectl-access node (the test pod itself runs wherever the scheduler places it) |
| GCP image pull secret works | `kubectl get secret gcr-docker-config -n phx-prod` to confirm it exists; then deploy any test pod referencing an Artifact Registry image and check `kubectl describe pod <pod> -n phx-prod` for a successful pull event, not `ImagePullBackOff` | Any kubectl-access node |
| MetalLB assigned the ingress IP | `kubectl get pods -n metallb-system`, `kubectl get ipaddresspools -n metallb-system`, `kubectl get svc -n ingress-nginx` (expect `EXTERNAL-IP` = `INGRESS_VIP`) | Any kubectl-access node |
| Ingress actually reachable from outside the cluster | `curl -v https://<ingress-host>/health` (or any known path) against `INGRESS_VIP` | **A client machine outside the cluster network** — this is the one test that must NOT run from a node inside the cluster, since that wouldn't prove external (north-south) reachability |
| Ingress has 2 replicas on 2 different nodes, Guaranteed QoS | `kubectl get pods -n ingress-nginx -o wide` (check `NODE` column differs) and `kubectl get pod <pod> -n ingress-nginx -o jsonpath='{.status.qosClass}'` (expect `Guaranteed`) | Any kubectl-access node |
| Ingress fails over when a node drops | `kubectl cordon <node-currently-holding-vip>`, then re-run the external `curl` test above | Cordon command: any kubectl-access node. Re-test: the external client machine again |
| NFS CSI driver + StorageClasses work end-to-end | Apply a test PVC (`kubectl apply -f test-pvc.yaml -n phx-prod`), confirm `kubectl get pvc -n phx-prod` shows `Bound`, then `kubectl exec <a-pod-using-it> -n phx-prod -- df -h <mount-path>` to confirm the mount is real | Any kubectl-access node for the `kubectl` commands; the `exec`'d command runs inside whichever pod, wherever it's scheduled |
| NetworkPolicies enforce correctly (Phase 1: Ingress-only) | From a pod **not** in the allowed source list, attempt a connection that should now be blocked: `kubectl run blocked-test --rm -it --image=nicolaka/netshoot -n some-other-namespace -- curl -v --max-time 3 telnet://<mysql-router-svc>.phx-prod:6446` (expect timeout/refused); then from an allowed pod inside `phx-prod`, confirm the same connection still works | Any kubectl-access node (both test pods run in-cluster) |
| DNS still resolves under NetworkPolicy | `kubectl run dnstest --rm -it --image=busybox -n phx-prod -- nslookup kubernetes.default` | Any kubectl-access node |
| metrics-server working | `kubectl top nodes && kubectl top pods -A` | Any kubectl-access node |
| cert-manager issuing certs | `kubectl get pods -n cert-manager` (all Running) and, after creating a test `Certificate`, `kubectl describe certificate <name> -n <ns>` (expect `Ready: True`) | Any kubectl-access node |
| ArgoCD reachable and logged in | `kubectl get pods -n argocd` (all Running); then `argocd login <argocd-server-address> --username admin --password <initial-password>` and `argocd app list` | `kubectl get pods` from any kubectl-access node; the `argocd` CLI commands from wherever you installed the `argocd` binary (per the doc, typically your own workstation or a jump box, not necessarily a cluster node) |
| node-exporter now reaches every node (including newly-tainted ones) after adding tolerations | `kubectl get pods -n monitoring -l app=node-exporter -o wide` — count must equal total node count, including WN-01/DB-LB-01/RPT-01/MN-01/02/03 | Any kubectl-access node |
| node-exporter metrics actually scrape-able | `curl http://<any-node-ip>:9100/metrics \| head` | From a host that can route to that node IP — LOG-01 (where Prometheus lives) is the realistic choice, since that's who actually needs to reach it |
| kube-state-metrics converted to Deployment, not DaemonSet | `kubectl get deployment kube-state-metrics -n monitoring` (should exist) and `kubectl get pods -n monitoring -l app=kube-state-metrics` (1-2 pods total, not one per node) | Any kubectl-access node |

---

## 04 — Worker node setup

| Check | Command | Run on |
|---|---|---|
| sysctl/ulimits applied | Same commands as the `03` sysctl/ulimit rows above | Each worker individually (WN-01-04, DB-LB-01, RPT-01) |
| containerd/kubeadm/kubelet versions correct | Same commands as `03` | Each worker individually |
| Worker joined and Ready | `kubectl get nodes -o wide` | Any kubectl-access node |
| Worker's kubelet points at the VIP (not one master) | `grep server /etc/kubernetes/kubelet.conf` — must show `CP_VIP`, not a master's real IP | Each worker individually |
| kubelet reserved resources took effect | `kubectl describe node <worker-name> \| grep -A6 Allocatable` | Any kubectl-access node, targeting each worker's node name |
| Taints/labels applied correctly | `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,LABELS:.metadata.labels` | Any kubectl-access node |
| Scheduling actually respects the taints | Deploy a test pod **without** the toleration targeting a tainted node via `nodeSelector`, confirm it stays `Pending` (`kubectl describe pod <pod>` shows `FailedScheduling`); then redeploy **with** the correct toleration and confirm it schedules | Any kubectl-access node |

---

## 05 — NFS server setup

| Check | Command | Run on |
|---|---|---|
| Disk type confirmed (not spinning) | `lsblk -d -o NAME,ROTA,SIZE,MODEL` | HIMS-PRD-NFS-01 directly |
| Network speed confirmed | `ethtool eth0 \| grep Speed` (adjust interface name if it isn't `eth0` — verify first) | HIMS-PRD-NFS-01 directly |
| nfsd thread count applied | `ps -ef \| grep [n]fsd \| wc -l` (should reflect `threads=128`) or `cat /proc/fs/nfsd/threads` | HIMS-PRD-NFS-01 directly |
| Exports are live | `sudo exportfs -v` and `showmount -e localhost` | HIMS-PRD-NFS-01 directly |
| Exports reachable from the cluster subnet | `showmount -e 10.200.50.138` | Any worker node (proves the export is visible to an actual client, not just the server itself) |
| Real mount + write test with production options | `sudo mount -t nfs4 -o vers=4.2,nconnect=4,rsize=1048576,wsize=1048576,noatime,hard,timeo=600 10.200.50.138:/srv/nfs/phx_prod_uploads /mnt/nfstest && touch /mnt/nfstest/writetest && ls -la /mnt/nfstest/writetest && sudo umount /mnt/nfstest` | A worker node (e.g. WN-02) acting as a real client — deliberately **not** NFS-01 itself, since mounting your own export locally doesn't prove the client-side path works |
| Negotiated mount options match what was requested | `nfsstat -m` (after the mount test above, before unmounting) | Same worker node used for the mount test |
| NFS I/O visibility for monitoring | `nfsiostat` and `cat /proc/net/rpc/nfsd` | HIMS-PRD-NFS-01 directly |
| Client-side per-mount latency visibility | `cat /proc/self/mountstats \| grep -A20 phx_prod` | Any worker node that has an active mount |

---

## `K8s_multi_master/configs/` — HAProxy, keepalived, etcd backup

These files get copied onto the real MN-01/02/03 boxes per `DEPLOY_TO_KUBEADM_CLUSTER.md`
— every test below runs **after** that copy step, directly on the masters, not from
this repo checkout.

### Config validity

| Check | Command | Run on |
|---|---|---|
| `haproxy.cfg` syntax is valid | `sudo haproxy -c -f /etc/haproxy/haproxy.cfg` (expect only `[NOTICE]` lines, no `[ALERT]`) | Each master individually |
| `keepalived.conf` syntax is valid | `sudo keepalived -t -f /etc/keepalived/keepalived.conf` (expect `Configuration file is valid`) | Each master individually |
| **VIP address is actually a valid host address, not the network/broadcast address** | `ip route \| grep "10.200.50.0/24"` to confirm the subnet, then manually check the VIP in `keepalived.conf`'s `virtual_ipaddress` block isn't `.0` (network) or `.255` (broadcast) or any already-assigned IP (`.129`, `.130`, etc.) | Each master individually — `keepalived -t` does **not** catch this, it's a semantic error, not a syntax one |

### Systemd services

| Check | Command | Run on |
|---|---|---|
| Both services running | `sudo systemctl status haproxy keepalived` (expect `active (running)` for both) | Each master individually |
| Both set to start on boot | `systemctl is-enabled haproxy keepalived` (expect `enabled` for both) | Each master individually |
| HAProxy actually listening on 6443 | `sudo ss -tlnp \| grep 6443` (expect `0.0.0.0:6443`, process `haproxy`) | Each master individually |

### VIP ownership and failover

| Check | Command | Run on |
|---|---|---|
| VIP is owned by exactly one master | `ip addr show ens7 \| grep "<CP_VIP>"` | All 3 masters, one at a time — exactly one should show it, labeled `ens7:vip` |
| HAProxy sees healthy backends | `echo "show stat" \| sudo socat stdio /run/haproxy/admin.sock \| grep kube-masters` (all listed servers should show `UP` once kubeadm has run; `DOWN` is expected/normal before `kubeadm init`) | Each master individually |
| API port reachable through the VIP | `nc -zv <CP_VIP> 6443` and `curl -k https://<CP_VIP>:6443/version` | Any worker node, or an external jump box — proves the LB path works from a real client, not just localhost on a master |
| HAProxy stats page auth works | `curl -u admin:<real-password> http://127.0.0.1:8404/haproxy?stats` (or the node's real IP if you uncommented the second `bind` line for remote scraping) | The master itself, or your monitoring host if remote scraping is enabled |
| Failover actually works | On the current VIP owner: `sudo systemctl stop keepalived`. Then check the next-priority master. | Stop command: the current VIP-owning master. Verification (`ip addr show ens7`): the next-priority master |
| Failover is logged correctly | `journalctl -u keepalived -f` (watch during the failover test above) | Any master — most useful run on the master taking over |

### Scripts actually triggering correctly

| Check | Command | Run on |
|---|---|---|
| `chk_haproxy.sh` behaves correctly when healthy | `sudo /etc/keepalived/chk_haproxy.sh; echo "exit code: $?"` (expect `0`) | Each master individually |
| `chk_haproxy.sh` correctly detects failure | `sudo systemctl stop haproxy`, re-run the script above (expect exit `1`), then `sudo systemctl start haproxy` to restore | One master at a time, in a maintenance window — restart haproxy immediately after |
| `notify.sh` runs correctly on manual test | `sudo /etc/keepalived/notify.sh MASTER TEST_INSTANCE; journalctl -t keepalived-notify -n 5 --no-pager` | Any master — simulates the hook without needing a real VRRP transition |
| `notify.sh` is actually firing on real transitions (not just manual tests) | `journalctl -t keepalived-notify --no-pager \| tail -20` — look for real `transitioned to BACKUP`/`MASTER` lines matching actual service restarts/failovers, not just your manual test | Any master |

### etcd backup

| Check | Command | Run on |
|---|---|---|
| Manual run works end-to-end | `sudo systemctl start etcd-backup.service && journalctl -u etcd-backup.service -n 50 --no-pager` | Each master individually (all 3 run their own backup) |
| Snapshot file exists and is valid | `ls -lh /var/backups/etcd/` and `ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/backups/etcd/etcd-snapshot-$(hostname)-<latest-timestamp>.db` | The master where the backup just ran |
| Timer is actually scheduled | `systemctl list-timers \| grep etcd-backup` | Each master individually |
| Off-node copy (NFS mount option) actually landed the file | `ls -lh /mnt/etcd-backups/` on the master, then confirm the same file is visible from NFS-01 itself: `ls -lh /srv/nfs/phx_prod_backups/` | Both the master and NFS-01 |
| Restore path actually works | Run the restore command from `ETCD_BACKUP.md` against a fresh data dir | **A lab/staging VM only — never a production master directly** |

### Log rotation — check which config is actually active first

Ubuntu's `haproxy` package ships its own default `/etc/rsyslog.d/49-haproxy.conf` + `/etc/logrotate.d/haproxy` (routing/rotating `/var/log/haproxy.log`). Confirm which one you're actually relying on before testing — don't assume it's the custom `haproxy-k8s-api` naming from this repo if you never actually replaced the distro default.

**Two different tools, two different diagnostic approaches — don't conflate them:**
- **`logrotate` is not a running service** — it's a one-shot program invoked by a timer, runs, then exits. There's nothing to "restart"; diagnose it with a dry run (`-d`), which shows its reasoning without changing anything.
- **`rsyslog` *is* a persistent daemon** — it only reads `/etc/rsyslog.d/*.conf` at startup, so a config change genuinely needs `systemctl restart rsyslog` to take effect. But confirm it's actually broken *before* restarting, so you know whether a restart is really the fix or whether the config content itself is wrong.

**Step-by-step diagnostic sequence** (run in this order — each step tells you whether to proceed or where the actual problem is):

| Step | Command | What it tells you |
|---|---|---|
| 1. What's actually configured | `cat /etc/rsyslog.d/49-haproxy.conf` | Note the exact filename it routes HAProxy logs to |
| 2. Is that routing *actually* active right now | `logger -p local2.info "manual test message $(date)"` then check **both**: `grep "manual test message" /var/log/haproxy.log` (or whatever Step 1 showed) **and** `grep "manual test message" /var/log/syslog` | Lands in the dedicated file → routing works, skip to step 4. Lands only in the generic `syslog` → routing isn't active yet |
| 3. Only if step 2 landed in the wrong place | `sudo systemctl restart rsyslog && sudo systemctl status rsyslog` (confirm clean restart), then repeat step 2's test with a new message | Still wrong after a restart → the config content itself has a real problem (wrong facility/path), not just a stale reload |
| 4. Which logrotate config exists and matches | `ls /etc/logrotate.d/ \| grep -i haproxy` then `cat` whichever file(s) exist — confirm the filename inside matches what Step 1 showed | Mismatched filename here = rotation will silently do nothing, even though the file looks configured |
| 5. Logrotate dry run (no side effects) | `sudo logrotate -d /etc/logrotate.d/haproxy` (or whichever filename Step 4 found) | Shows exactly what it would do — file found or not, already rotated today or not. **Known failure mode**: `error: skipping "..." because parent directory has insecure permissions` — newer `logrotate` versions require an explicit `su <user> <group>` directive (matching the config's `create` line) before they'll trust rotating the file at all; add it to `logrotate-haproxy` (already fixed in this repo's copy) rather than changing directory permissions to work around it |
| 6. Only once 1-5 line up — force a real rotation | `sudo logrotate -f /etc/logrotate.d/haproxy && ls -la /var/log/haproxy*` | Expect a new dated/rotated file + a fresh empty current one |
| 7. Confirm rsyslog reopened the file post-rotation (the postrotate gotcha) | `sudo lsof /var/log/haproxy*.log` | Should show `rsyslogd` holding the **new** file, size near-zero — if it's still holding the old renamed file, `postrotate` didn't fire correctly |

---

## Order to actually run these in

1. **00** checks — before touching any config, confirm the hardware matches the inventory.
2. **`K8s_multi_master/configs`** HAProxy/keepalived syntax + service checks — before `kubeadm init`, since the VIP must exist first.
3. **03** kubeadm/Calico/cluster-formation checks — as each master joins.
4. **`K8s_multi_master/configs`** failover + etcd-backup checks — once all 3 masters are up.
5. **04** worker checks — as each worker joins.
6. **05** NFS checks — can run in parallel with 3/4, but StorageClass/PVC checks in `03` depend on these passing first.
7. Everything else in **03** (MetalLB, ingress, NetworkPolicies, monitoring, cert-manager, ArgoCD) — after the base cluster is fully formed.
