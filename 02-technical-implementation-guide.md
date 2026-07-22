# Technical Implementation Guide

Detailed how-to for the items called out in `01-architecture-plan.md` Section 9 (Performance) and Section 10 (Open Items), plus NFS server efficiency. Companion to `01-architecture-plan.md` — that file has the "what and why," this file has the "how."

---

## Portable vs Environment-Specific Values in This Guide

| Item | Portable? | Notes |
|---|---|---|
| Calico eBPF enable steps, kernel version prerequisite (5.3+/5.10+) | **Portable** | Same procedure and requirement regardless of node spec |
| Guaranteed QoS YAML *structure* (`requests == limits` pattern) | **Portable** | The pattern is universal |
| ingress-nginx / MySQL Router / redis-session actual CPU-memory numbers (2 CPU/2Gi, 1 CPU/512Mi, 500m/1Gi) | **Environment-specific** | Sized against WN-01 (16 vCPU/16 GB), DB-LB-01 (8 vCPU/16 GB), and the general pool (8 vCPU/32 GB) specifically — re-size if node specs differ; formula in Section 8 |
| PriorityClass mechanism / `value: 100000` | **Mostly portable** | The mechanism is universal; the number only needs to be higher than any other PriorityClass in the cluster, not tied to hardware |
| sysctl *parameter names* (`somaxconn`, `tcp_max_syn_backlog`, `ip_local_port_range`, `nf_conntrack_max`, `file-max`) | **Portable** | Relevant for any node handling many concurrent connections, regardless of CPU/RAM |
| sysctl *specific values* (65535, 1048576, 2097152) | **Loosely scale-dependent** | Sized with headroom for ~800 concurrent users on this node count; not tightly coupled to exact CPU/RAM, but a very different scale (10x smaller or larger) would warrant revisiting — `nf_conntrack_max` specifically has a real RAM-cost formula in Section 8 |
| ulimit values | **Portable** | Same reasoning as sysctl |
| `KubeletConfiguration` field structure (`systemReserved`/`kubeReserved`/`evictionHard`) | **Portable** | Standard kubelet mechanism, works the same on any node |
| `kubeReserved`/`systemReserved` *amounts* (flat 500m/1Gi everywhere) | **Environment-specific — and currently a simplification** | Applied uniformly across very differently-sized nodes (masters at 4 vCPU/12 GB vs general pool at 8 vCPU/32 GB); a flat reservation costs the small nodes a bigger % of capacity than the large ones. Works here, but re-derive per node size for tighter tuning rather than copying the flat number elsewhere — formula + a dev-vs-prod worked example in Section 8 |
| Backup/DR *strategy* (etcd snapshot approach, XtraBackup approach, NFS backup approach) | **Portable** | The approach applies to any InnoDB Cluster / etcd / NFS setup |
| Backup *schedule specifics* (daily 01:00, 7-day local retention, weekly full + daily incremental) | **Environment-specific** | Chosen for this system's RPO/RTO tolerance and the 4 TB data volume — adjust for different data sizes or compliance requirements |
| NetworkPolicy YAML structure, phased Ingress-then-Egress rollout approach | **Portable** | Reusable pattern for any namespace |
| NetworkPolicy label selectors and ports (`app: phx-gateway-service`, port 8080, 6446/6447, 6379) | **Environment-specific** | Tied to this app's actual service names, labels, and listening ports — verify against the real Helm charts before applying elsewhere |
| NFS tuning *techniques* (`nconnect`, `rsize`/`wsize`, NFSv4.2, separate exports by workload) | **Portable** | Applicable to any NFS deployment |
| NFS *specific numbers* (`threads=128`, `rsize`/`wsize=1048576`) | **Environment-specific** | Tied to ~13 nodes mounting concurrently and this disk/network capacity — re-tune for a different node count; per-vCPU formula in Section 8 |

---

## 1. Calico eBPF Dataplane

### Why this matters & expected impact

- Standard Calico (iptables mode) routes every Service-destined packet through kube-proxy's iptables NAT chains, which are evaluated roughly in proportion to the number of Services/endpoints. With 26+ phx-* services × multiple replicas, that chain keeps growing, and per-packet latency grows with it. eBPF mode replaces this with a hash-map lookup — the cost stays flat regardless of how many services you add.
- Calico/Tigera's own published benchmarks report **up to ~30% lower pod-to-pod latency and up to ~20% higher throughput** versus iptables mode, with the gain increasing as service count and connection churn go up — which matches your cluster's shape (many small services, high east-west chatter to MySQL Router).
- Enabling DSR on top removes an extra hop on the *return* path of service traffic, cutting node CPU spent on network processing for response traffic specifically.
- **Caveat:** those percentages are Calico's own published figures, not a measurement of your cluster. Actual gain depends on your real service count, connection churn rate, and current CPU headroom. Capture p50/p95/p99 request latency before the change and again after, in the same maintenance window, so you have your own before/after number rather than relying on the vendor figure.

### Prerequisite check
eBPF dataplane needs Linux kernel **5.3+** (5.10+ recommended). Check on every node first:

```bash
uname -r
```

If any node is below 5.3, either upgrade that node's kernel first or skip eBPF and stay on standard iptables mode — don't run a mixed cluster where some nodes support it and others don't.

### Enable steps

1. **Point Calico at the API server directly.** eBPF mode replaces kube-proxy, so Calico needs a direct path to the API server instead of going through the (about-to-be-disabled) kube-proxy iptables rules. Use the HAProxy VIP from `01-architecture-plan.md` Section 2:

```bash
kubectl -n kube-system create configmap kubernetes-services-endpoint \
  --from-literal=KUBERNETES_SERVICE_HOST=<HAPROXY_VIP> \
  --from-literal=KUBERNETES_SERVICE_PORT=6443
kubectl -n kube-system rollout restart daemonset calico-node
```

2. **Disable kube-proxy** (don't delete it — give it a nodeSelector that matches nothing, so it's easy to revert):

```bash
kubectl -n kube-system patch daemonset kube-proxy -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"non-calico-ebpf":"true"}}}}}'
```

3. **Turn on eBPF mode** via Felix configuration:

```bash
calicoctl patch felixconfiguration default --patch='{"spec": {"bpfEnabled": true}}'
```

4. **Optional — DSR (Direct Server Return)** for lower-latency service traffic. Only enable if all nodes have direct L2 reachability to each other (verify with your network team first — DSR breaks silently if that's not true):

```bash
calicoctl patch felixconfiguration default --patch='{"spec": {"bpfExternalServiceMode": "DSR"}}'
```

5. **Verify:**

```bash
calicoctl node status
kubectl -n kube-system logs -l k8s-app=calico-node | grep -i bpf
# on a node:
bpftool prog list
```

Test pod-to-pod and pod-to-MySQL-Router connectivity explicitly after switching — this changes the whole traffic path.

### Your situation is a fresh build, not a live migration — that changes the risk calculus

Everything above (maintenance window, rollback plan, "don't flip cluster-wide in one shot") is written for the scenario where **real traffic is already flowing** and a bad change causes a live outage. That is not your situation right now — you're still standing the cluster up, before onboarding real users. That's actually the easiest possible time to make this decision, because there is no live traffic to protect. Concretely:

- You can enable eBPF (or leave it off) as part of initial Calico bring-up, test it thoroughly with synthetic/test workloads, and change your mind and flip it back **as many times as you want** — the "rollback" is trivial when nobody is depending on the cluster yet.
- Treat your entire pre-go-live window as one long maintenance window. There's no need to schedule a special one later — do the comparison now, before real services and real patients depend on this cluster.
- Recommended sequence for a fresh cluster specifically:
  1. Install Calico in standard iptables mode first (the default — simpler, the most widely-tested path, and what the rest of this guide's examples assume unless stated otherwise).
  2. Bring up the full cluster per `03-master-node-setup.md`/`04-worker-node-setup.md`, deploy a couple of real or representative phx-* services, and run the full connectivity/NetworkPolicy test suite in `06-validation-testing.md` against **iptables mode**. Record the results (pass/fail, and rough latency if you want a baseline).
  3. Only then, still pre-go-live, follow the "Enable steps" above to switch to eBPF, and **re-run the exact same tests from `06-validation-testing.md`** against eBPF mode.
  4. Compare the two runs on your own cluster and decide which mode to actually launch with. You get a real, cluster-specific answer instead of trusting Calico's published benchmarks blind — and there's zero customer-facing risk either way, since nobody is live yet.
- The one thing *not* to skip even though you're pre-production: the NetworkPolicy interaction and the MetalLB interaction (Section 6 below, and `03-master-node-setup.md` Section 8) still need to be re-verified after switching dataplane modes — "pre-production" means the blast radius is small, not that the interaction risk itself disappears.

### Test commands for this comparison

Run this same block twice — once right after initial Calico install (iptables mode), once right after switching to eBPF — and diff the results:

```bash
# Pod-to-pod connectivity
kubectl run nettest --rm -it --image=nicolaka/netshoot -n phx-prod -- ping -c 4 <another-pod-ip>

# Pod-to-Service (ClusterIP) — proves kube-proxy/eBPF Service handling works either way
kubectl run svctest --rm -it --image=nicolaka/netshoot -n phx-prod -- curl -v telnet://<mysql-router-svc>.phx-prod:6446

# MetalLB LoadBalancer path end-to-end (see 03-master-node-setup.md Section 6/8)
curl -v https://<INGRESS_VIP>/health

# NetworkPolicy still enforcing correctly under this dataplane mode (see Section 6 below)
kubectl run blocked-test --rm -it --image=nicolaka/netshoot -n some-other-namespace -- curl -v --max-time 3 telnet://<mysql-router-svc>.phx-prod:6446

# DNS still resolving
kubectl run dnstest --rm -it --image=busybox -n phx-prod -- nslookup kubernetes.default
```

**Run all of these from any kubectl-access node** (a master, or your workstation with `admin.conf` copied) — the test pods themselves land wherever the scheduler places them, which is fine; you're testing the network path, not a specific node.

### Rollout approach (for later — once you're actually live)
Once real traffic exists, don't flip this cluster-wide in one shot; do it during a maintenance window with the rollback ready. This is the procedure to come back to *after* go-live, not the one to follow during initial setup:

```bash
calicoctl patch felixconfiguration default --patch='{"spec": {"bpfEnabled": false}}'
kubectl -n kube-system patch daemonset kube-proxy -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{}}}}}'
```

---

## 2. Guaranteed QoS for Latency-Sensitive Pods

A pod gets **Guaranteed** QoS only if *every* container in it has CPU **and** memory `requests == limits`. This protects it from being first-evicted under node memory pressure and reduces CPU throttling surprises.

### Why this matters & expected impact

- **This is not a raw throughput gain — it's the removal of a specific, well-documented tail-latency risk.** Under Linux's CFS CPU quota enforcement, a container with a CPU *limit* gets throttled once it exhausts its quota within a 100ms scheduling period — and this happens even at **low average CPU usage** if the workload is bursty (request/response traffic and cache lookups both are). Multiple public engineering write-ups (Indeed, Buffer, Datadog) document containers throttled 20%+ of wall-clock time while averaging under 50% CPU, producing periodic **p99 latency spikes of 5-10x** with no change in average load. Guaranteed QoS alone doesn't remove CPU limits, but pairing it with a correctly-sized (not artificially tight) limit avoids this trap, since the whole point of the exercise is to size the limit from real observed usage rather than guessing low.
- **Eviction order:** under node memory pressure, Kubernetes kills BestEffort pods first, then Burstable, then Guaranteed last. For ingress-nginx, MySQL Router, and redis-session — where every single request/session passes through — this moves them from "could be killed to free memory for anything" to "last resort," which matters more as more services share the general pool.
- **Expected impact, stated honestly:** no clean percentage — the benefit is eliminating a known latency-spike class and an eviction risk for exactly the three pods where a stall or restart is costliest. Validate the CPU-throttling piece specifically via the `container_cpu_cfs_throttled_periods_total` metric in Prometheus before and after — if throttled-period counts for these three pods drop to near zero, the change worked.

### ingress-nginx (Helm values)

```yaml
controller:
  resources:
    requests:
      cpu: "2"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "2Gi"
```

### MySQL Router (phx-db-loadbalance-service, on DB-LB-01)

```yaml
resources:
  requests:
    cpu: "1"
    memory: "512Mi"
  limits:
    cpu: "1"
    memory: "512Mi"
```

### redis-session

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "500m"
    memory: "1Gi"
```

Redis is single-threaded — 500m-1 full core is normally plenty; don't over-allocate CPU here without evidence. Start with the numbers above, watch actual usage (`kubectl top pod`, or the redis_exporter dashboard from `01-architecture-plan.md` Section 5) for 1-2 weeks, then adjust the exact number — the important part is requests==limits, not the specific value.

**Sizing basis for all three of the resource blocks above — see Section 8 below**: the rule is ~15-25% of the *allocatable* capacity of the node each pod lands on, not an arbitrary number — Section 8 shows the percentage each of these actually works out to on your real nodes, so you can rescale correctly if these ever run on different-sized hardware.

### Pair with a PriorityClass
QoS class controls eviction order; PriorityClass controls scheduling/preemption order. Use both together for these three:

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: hims-critical
value: 100000
globalDefault: false
description: "Critical path: ingress, MySQL Router, redis-session"
```

Add `priorityClassName: hims-critical` to each of those pod specs / Helm values.

---

## 3. OS-Level Tuning for High Connection Counts

Apply to WN-01, DB-LB-01, and the general pool (WN-02/03/04) — anywhere handling high concurrent connections.

### Why this matters & expected impact

- **The failure mode this prevents is a cliff, not a slowdown.** Default `nf_conntrack_max` on most distros is 65,536-262,144 entries. A 12+ node cluster doing NAT for many Services can fill that table under moderate concurrent-connection load; once full, the kernel **silently drops new connection attempts** (visible in `dmesg` as `nf_conntrack: table full, dropping packet`) — that's 100% failure for those specific attempts until existing entries expire, not a percentage slowdown. Raising it to 1,048,576 gives you an order-of-magnitude more headroom before that cliff is reached.
- Similarly, `somaxconn`/`tcp_max_syn_backlog` bound how many pending connections the kernel will queue before it starts dropping/resetting new ones. At your stated target of 800 concurrent users, a burst (e.g. shift-change login spike) can exceed the default backlog even though sustained average load is fine — this shows up as intermittent connection resets specifically at peak, which is a hard thing to diagnose after the fact if you haven't already raised the ceiling.
- `ip_local_port_range` — widening from the default (~28,000 usable ports) to the full ~64,000 range roughly **doubles** the ephemeral port pool available for outbound connections (app pods → MySQL Router, service-to-service calls), delaying port-exhaustion errors as connection volume grows.
- **Expected impact, stated honestly:** these settings don't make anything faster under normal load — they raise the load level at which the system starts failing outright. Validate via `node_exporter`'s conntrack (`node_nf_conntrack_entries` vs `_limit`) and TCP retransmit/drop metrics before and after a load test at your target concurrency.

### Disable swap (required by kubelet anyway)

```bash
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### sysctl tuning

Create `/etc/sysctl.d/99-hims-k8s.conf`:

```
vm.swappiness = 0
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = 1048576
fs.file-max = 2097152
```

Apply:

```bash
sysctl --system
```

**Why each one matters:**
- `somaxconn` / `tcp_max_syn_backlog` / `netdev_max_backlog` — raise the connection backlog so ingress-nginx and the gateway pods don't drop connections under a burst at 800 concurrent users.
- `ip_local_port_range` — widens the ephemeral port pool; prevents port exhaustion on nodes making many outbound connections (app pods → MySQL Router, service-to-service calls).
- `nf_conntrack_max` — k8s clusters generate a lot of iptables/NAT conntrack entries across many Services; the default table fills up under load and starts silently dropping packets. This is a common, hard-to-diagnose production issue at this service count. **Sizing basis: see Section 8 below** — unlike the other sysctls here, this one has a real RAM cost (~350 bytes/entry) and should be sized as a percentage of node RAM, not copied blindly onto smaller hardware.
- `fs.file-max` — system-wide open file ceiling; needed alongside per-process ulimits below.

### Raise ulimits

Create `/etc/security/limits.d/99-hims.conf`:

```
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
```

Also make sure containerd's systemd unit isn't capping this lower — check `/etc/systemd/system/containerd.service.d/` (or the vendor unit) for `LimitNOFILE` and raise it to match, then `systemctl daemon-reload && systemctl restart containerd`.

### Deployment method
These are **node/OS-level** settings, not pod-namespaced sysctls — they can't be set via pod `securityContext.sysctls`. Apply them through your node provisioning tooling (Ansible/cloud-init) so they're reproducible and reapplied automatically if a node is rebuilt, rather than done by hand once.

---

## 4. kubelet Reserved Resources

`systemReserved`/`kubeReserved` carve out capacity for the OS and Kubernetes system daemons so they don't compete with pods for the last bit of RAM/CPU — this is what actually protects the smaller-RAM nodes (WN-01, DB-LB-01) from starving themselves.

### Why this matters & expected impact

- **Without this, Kubernetes reports 100% of node capacity as allocatable to pods.** The scheduler will then happily pack pods right up to the node's physical RAM/CPU, leaving nothing for the OS, kubelet, and containerd themselves. Under sustained load, this starves the very processes responsible for keeping the node healthy — kubelet can miss its heartbeat, the node flips to `NotReady`, and Kubernetes reschedules every pod that was on it elsewhere, all at once. That's a worse outage than the original resource pressure that caused it.
- The reservations sized in the table (~5-10% of CPU/RAM per node) match the same order of magnitude used by managed Kubernetes offerings (GKE/EKS default node-allocatable formulas) — this is standard practice, not a conservative guess specific to your cluster.
- **Expected impact, stated honestly:** this is a stability floor, not a throughput number — you're not making pods faster, you're preventing a node-instability failure mode that would otherwise cost you far more (a reschedule storm across the cluster) than the small amount of capacity you're setting aside. Validate by checking `kubectl describe node <name> | grep -A6 Allocatable` matches expectations, and watch that kubelet/containerd CPU and memory usage stay well within the reserved slice under load rather than growing into it.

### Suggested values per node group

| Node(s) | kubeReserved | systemReserved | Rationale |
|---|---|---|---|
| MN-01/02/03 (4 vCPU/12 GB) | cpu: 500m, mem: 512Mi | cpu: 500m, mem: 1Gi | Also running etcd + apiserver + HAProxy + keepalived — protect control plane first |
| WN-01 (16 vCPU/16 GB) | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | Lowest RAM-per-vCPU of the tainted nodes; hosts ingress+gateway+php together |
| WN-02/03/04 (8 vCPU/32 GB) | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | General pool, more RAM headroom |
| DB-LB-01 (8 vCPU/16 GB) | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | Hosts MySQL Router — the single DB access path, leave real headroom |
| RPT-01 (8 vCPU/32 GB) | cpu: 500m, mem: 1Gi | cpu: 500m, mem: 1Gi | Single-service tainted node |

**Sizing basis for this table — see Section 8 below** for the actual rule (~10% of node CPU/RAM combined, with a ~1 vCPU/2 GiB floor) and a worked dev-vs-prod example. The flat 500m/1Gi + 500m/1Gi used here is a safe approximation of that rule across this specific fleet, not an arbitrary constant — recompute it if you ever deploy this on different-sized hardware.

Example `KubeletConfiguration` (per-node, since values differ by node group — manage via your node config templating, e.g. Ansible, or per-node kubeadm join config):

```yaml
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
  - pods
```

**Correction, found the hard way in production:** `enforceNodeAllocatable` must **not**
list `system-reserved`/`kube-reserved` unless you also set matching
`systemReservedCgroup`/`kubeReservedCgroup` paths — kubelet **refuses to start at all**
if those categories are listed without a cgroup path to enforce them against (it
crash-loops with an exit code, not just a warning). The `kubeReserved`/`systemReserved`
*values* above still correctly reduce the reported `Allocatable` on their own —
enforcement at the cgroup level (an extra hard ceiling on the system/kubelet processes
themselves) is a separate, stronger guarantee that needs real cgroup path configuration
to use safely. Leaving `enforceNodeAllocatable` at just `[pods]` (kubelet's own default)
gets the scheduling-safety goal this section actually needs, without that risk.

**Merge these settings into the existing `/var/lib/kubelet/config.yaml` on each node —
don't overwrite the whole file with just this content, and don't create a separate
drop-in file.** Kubelet has no `.d/`-style override directory the way systemd services
do; it reads exactly one file, and kubeadm has already generated that file (with
`cgroupDriver`, `authentication`, `clusterDNS`, etc.) by the time a node joins. Append
only the new keys shown above (`systemReserved` through `enforceNodeAllocatable`) to
the end of that existing file — check with `grep` first that none of them are already
present, to avoid duplicate top-level keys. See `03-master-node-setup.md` Section 2/3
and `04-worker-node-setup.md` for the exact per-node commands. Then:

```bash
systemctl daemon-reload
systemctl restart kubelet
```

Verify allocatable dropped as expected: `kubectl describe node <name> | grep -A6 Allocatable`.

---

## 5. Backup / DR Strategy

### Why this matters & expected impact

- **This section isn't about performance — it's about bounding data loss (RPO) and recovery time (RTO) when something fails, not if.** Worth stating the "do nothing" baseline explicitly so the value of doing this is concrete:
  - No etcd backup: losing quorum (e.g. 2 of 3 masters) means rebuilding the entire cluster's state from scratch — every Deployment, Secret, ConfigMap, and Service definition — by hand, from whatever's in git/Helm, taking anywhere from hours to days depending on how much is actually reproducible from source control.
  - No DB backup: losing the InnoDB Cluster beyond quorum means data loss back to whenever the last ad hoc dump happened to be taken — for a live hospital system, that's an unbounded and unacceptable loss window.
  - No NFS backup: an NFS-01 disk failure means every patient upload and report file is gone permanently, with no path to recovery at all.
- **With the plan as described, the loss windows become bounded and known in advance:**
  - etcd: RPO ≈ 24 hours (daily snapshot — acceptable here since etcd holds cluster/service config and secrets, not patient records; that data lives in MySQL, covered separately below); RTO is typically tens of minutes for a restore, but this must be timed on your own hardware, not assumed.
  - MySQL InnoDB Cluster: RPO can approach near-zero if binary logs are replayed on top of the last XtraBackup (rather than accepting the full 24-hour gap between incrementals) — but restoring a 4 TB node is realistically an hours-long operation, and the actual number depends entirely on your disk I/O, which is why the quarterly restore drill matters more here than anywhere else in this document.
  - NFS: RPO depends on your chosen snapshot/backup interval (daily is a reasonable starting point for patient files); RTO depends on whether you're restoring from local ZFS snapshots (fast) or an offsite copy (bounded by your network link to that target).
- **Expected impact, stated honestly:** there's no percentage to quote here — the entire value of this section is converting "unknown, possibly unbounded data loss and recovery time" into "a known, tested number you can put in an SLA or incident runbook." The only way to get real RTO numbers is to actually run the restore drill — don't estimate them from documentation.

### etcd

**Implemented, not just planned** — see `/home/agira/Projects_files/Alyssa/K8s_multi_master/configs/` for the actual scripts (`etcd-backup.sh`, `etcd-backup.service`, `etcd-backup.timer`, `ETCD_BACKUP.md`), which supersede the sketch originally in this section. Key points, corrected to match:

- Runs once **daily at 01:00** (not every 6 hours as originally sketched here) via a systemd timer, staggered up to 10 minutes across the 3 masters (`RandomizedDelaySec=600`) so they don't all hit disk/network at the same second. `Persistent=true` means a missed run (node rebooting at 01:00) fires shortly after next boot instead of waiting a full day.
- **Verifies the snapshot before trusting it** — runs `etcdctl snapshot status` immediately after `snapshot save` and deletes the file if it's corrupt, rather than assuming a non-error exit code means the backup is good.
- 7-day **local** rotation via `find -mtime +7`, run on **all 3 masters** (any single healthy member's snapshot is sufficient to restore the whole cluster, per `multi_master_ha_setup.md` §6.3).
- **The off-node copy is not wired up yet** — the script has an `OFF_NODE_COPY` hook (rsync to a separate host, or `aws s3 cp`) that must be uncommented and configured before this counts as a real backup; until then, treat it as incomplete per `ETCD_BACKUP.md`'s own warning. Point it at NFS-01's backup export or an offsite target — a snapshot that only lives on the master it was taken from doesn't survive that master's disk failure.
- Also back up `/etc/kubernetes/pki/` and the kubeadm config — you need certs to restore, not just data.
- **Restore procedure**: fully documented in `multi_master_ha_setup.md` §6.2 (quorum loss, minority survives) and §6.3 (all masters down, restore from snapshot) — more detailed than the one-line sketch originally here, including the worker-node-is-unaffected reasoning and the "don't change the restored master's identity" warning.

### MySQL InnoDB Cluster

- Use **Percona XtraBackup** (or MySQL Enterprise Backup) for hot physical backups — at 4 TB per node, logical dumps (`mysqldump`) are too slow for both backup and restore.
- Weekly full + daily incremental via XtraBackup.
- Run the backup against **DB-02** (not DB-RPT-01, which already carries reporting query load, and not the primary) to keep backup I/O off the busiest nodes.
- Push backups to NFS-01's backup export or offsite storage — not left only on the DB node's local disk.
- Binary logs are already required for Group Replication — set `binlog_expire_logs_seconds` deliberately so you have enough retention to support point-in-time recovery between full backups.
- **Test the restore quarterly.** An untested backup is a hope, not a backup.

### NFS (patient uploads/reports)

- This now holds real patient data — encrypt backups at rest and control access to them.
- If NFS-01's filesystem is ZFS or Btrfs: use scheduled snapshots (`zfs snapshot`) plus `zfs send/receive` to a secondary target for an offsite copy — cheap, fast, incremental.
- If plain ext4/xfs: use **Restic** or **BorgBackup** (both give deduplication + encryption, which matters for compliance) on a schedule, or `rsnapshot`-style hard-link rotation if you want something simpler.
- Keep backup jobs on a separate export/mount point from live upload traffic, so a backup run doesn't compete with live pod I/O (see NFS efficiency section below).

---

## 6. Calico NetworkPolicies

### Why this matters & expected impact

- **This is a blast-radius/security control, not a speed control.** Without NetworkPolicies, every pod can reach every other pod by default — so a vulnerability in any single phx-* service's dependency (which is a "when," not "if," across 26+ services over time) gives an attacker a free path to MySQL Router and Redis directly, i.e. straight to patient data and live sessions, rather than being contained to the one compromised service. Default-deny + explicit allow rules turn "one compromised pod = access to everything" into "one compromised pod = access to only what it's explicitly allowed to reach."
- **Honest cost, not just benefit:** policy enforcement isn't free. In iptables mode, evaluating many NetworkPolicies adds a small per-packet cost — Calico's own documentation describes this as a low single-digit percentage of CPU/latency overhead for typical policy counts, growing somewhat with the number of policies and pods matched. The eBPF dataplane (Section 1) evaluates policies more efficiently than iptables mode, so if you do both changes, eBPF actively offsets part of the cost NetworkPolicies add — one more reason to sequence eBPF first or alongside this.
- **Expected impact, stated honestly:** the security benefit (blast-radius reduction) isn't expressible as a percentage — it's a qualitative shift in what a single compromised pod can reach. The performance cost is small and further reduced by eBPF mode. Roll out default-deny one namespace at a time and watch for unexpected drops (a policy blocking a legitimate path you didn't know existed shows up as failed connections, not a subtle slowdown), rather than pushing it cluster-wide in one step.

Default-deny first, then explicitly allow only the paths that need to exist. Roll this out in a lower environment first, or apply default-deny to one namespace at a time and watch for unexpected drops before going cluster-wide — you will find traffic paths you didn't know about.

**Important correction — do this in two phases, not one.** A `default-deny-all` that includes `Egress` blocks *outbound* connections from every pod unless something explicitly allows it. The Ingress-side allow rules below (gateway, db-router, redis) only permit traffic **into** those pods — they do nothing for the ~20 other phx-* services that need to **call out** to db-router/Redis. Applying Egress-default-deny with only the rules below and no matching egress allows would silently break every DB and Redis call cluster-wide the moment it's applied — a full outage, not a partial one.

- **Phase 1 (do this now):** `default-deny-all` scoped to **Ingress only**, plus the Ingress-allow rules below. This alone achieves the actual stated goal — a compromised pod elsewhere in the cluster can no longer freely connect *into* MySQL Router or Redis, since only explicitly-listed sources are allowed in. This doesn't require knowing every service's outbound call graph.
- **Phase 2 (later, needs more input):** extending `default-deny-all` to also cover `Egress` requires mapping which of the ~20 phx-* services call which others, plus db-router and Redis — do this once that call graph is actually known, not as a guess. `allow-dns-egress` below is written now so it's already in place when you do reach Phase 2.

### Default deny-all (per namespace) — Phase 1: Ingress only

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: hims-prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

### Allow ingress-nginx → gateway

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-gateway
  namespace: hims-prod
spec:
  podSelector:
    matchLabels:
      app: phx-gateway-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
```

### Allow app services → MySQL Router (DB-LB-01)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-db-router
  namespace: hims-prod
spec:
  podSelector:
    matchLabels:
      role: db-router
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: hims-prod
      ports:
        - protocol: TCP
          port: 6446
        - protocol: TCP
          port: 6447
```

### Allow app services → Redis

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-redis
  namespace: hims-prod
spec:
  podSelector:
    matchLabels:
      role: redis
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: hims-prod
      ports:
        - protocol: TCP
          port: 6379
```

### Cluster-wide baseline (optional, Calico-specific)

For a stronger default posture given this handles patient data, consider a Calico `GlobalNetworkPolicy` that denies all egress to the internet by default except explicitly allowed destinations (package mirrors, NTP, any external API integrations) — most HIMS traffic should be east-west within the cluster or to the DB tier, not outbound.

---

## 7. Making NFS-01 More Efficient

A few levers, roughly in order of impact — with expected impact quantified where there's a real industry-standard figure to quote, and flagged honestly where there isn't:

1. **Confirm the underlying disk type first — this dominates everything else on this list.** Random I/O (many small files, exactly the report/image upload pattern) differs by **100-1000x** between disk classes: a 7200rpm spinning disk does roughly 100-150 random IOPS, a SATA SSD roughly 10,000-90,000, and NVMe 100,000+. If the 8 TB is spinning disk, no amount of NFS protocol tuning below will fix the actual bottleneck — this check should happen before any of the others.

2. **Use NFSv4.1/4.2, not v3.** Single port (2049), better caching semantics, session support, and modern clients auto-negotiate larger I/O sizes than v3 typically does by default. Set on both server exports and client mount options (`vers=4.2`). No universal percentage here — the gain is mostly about avoiding v3's smaller negotiated defaults and multi-port complexity, not a standalone throughput number.

3. **Increase nfsd thread count.** Default is often just 8 threads — well known to under-serve more than a handful of concurrent clients; you have ~13 nodes potentially mounting concurrently. In `/etc/nfs.conf` (or `/etc/sysconfig/nfs` on older distros):
   ```
   [nfsd]
   threads=128
   ```
   Restart `nfs-server` after changing. No clean percentage to quote — thread starvation shows up as growing RPC wait time, visible via `nfsstat -rpc`; watch that metric before and after rather than assuming a number.

   **Sizing basis: see Section 8 below** — the rule is ~8-16 threads per vCPU on the NFS server, scaled for expected concurrent client count; 128 is that rule applied to NFS-01's 4 vCPU and ~13 potential concurrent clients, not an arbitrary round number.

4. **Tune client mount options** (set in the StorageClass / PV spec used by the CSI driver):
   ```
   vers=4.2,nconnect=4,rsize=1048576,wsize=1048576,noatime,hard,timeo=600
   ```
   - `nconnect=4` — parallelizes a mount across multiple TCP connections instead of one. Published benchmarks (Red Hat, AWS EFS documentation) report roughly **2-4x throughput improvement** for high-parallelism / read-heavy workloads that were bottlenecked by a single TCP connection's window size — this is the single biggest *protocol-level* lever on this list, though it still can't exceed whatever the disk (#1) and network (#6) allow.
   - `rsize`/`wsize=1048576` — only helps if your current negotiated size is actually below 1 MB. Many modern NFSv4.2 clients already auto-negotiate up to 1 MB — check first with `nfsstat -m` or `cat /proc/mounts` before assuming this is a real gap to close.
   - `noatime` — avoids an extra metadata write on every read; matters more for read-heavy access (staff repeatedly viewing the same reports) than write-heavy upload traffic.

5. **Separate exports/mount points by workload.** Put uploads, patient reports, and backups on separate exports (ideally separate underlying volumes) so a backup job or a burst of report generation doesn't starve live upload traffic. Not quantifiable generically — the benefit is eliminating a specific contention pattern (backup I/O competing with live traffic), which today shares one undifferentiated 8 TB pool.

6. **Check network bandwidth to NFS-01.** This is a flat, calculable ceiling: 1GbE tops out around 125 MB/s; 10GbE around 1.25 GB/s — a **10x** raw ceiling increase. With ~13 cluster nodes potentially mounting concurrently plus image/report traffic at 800 users, 1GbE saturates fast and becomes the real limit regardless of any tuning above it.

7. **Monitor it, don't guess.** Add `node_exporter` plus NFS-specific stats (`nfsiostat`, `/proc/net/rpc/nfsd`, client-side `mountstats`) to the Prometheus/Grafana stack on LOG-01 (from `01-architecture-plan.md` Section 8), so you catch a growing bottleneck before it becomes a production incident rather than after.

8. **Longer-term scaling path (not urgent now).** If growth outpaces a single NFS box, the next step is usually a distributed storage system (Ceph, MinIO for object-style access, GlusterFS) rather than a bigger single NFS server — worth knowing this ceiling exists, but not a decision to make today.

**Caveat that applies to all of the above:** the percentages quoted (disk IOPS classes, nconnect's 2-4x, the 10x network ceiling) are well-established industry figures and vendor benchmarks — not measurements of your specific NFS-01 box. Confirm disk type and network speed first, since either one can dominate or invalidate the smaller protocol-level gains, and measure your own before/after throughput once changes are applied rather than assuming the published numbers transfer directly.

---

## 8. Sizing Formulas — How to Recompute These Values for a Different Environment

Every numeric value in this guide was picked for *this* hardware (`00-server-requirements.md`). If you ever stand up a smaller environment — e.g. a 4-core/8 GB dev box instead of a 12-core/32 GB prod node — copying the numbers verbatim is wrong in both directions: too small a reservation under-protects a big node, too large a reservation wastes capacity on a small one. This section gives the **rule**, not just the number, so you can recompute it for any hardware.

### kubelet `kubeReserved` + `systemReserved` (Section 4)

**Rule of thumb: reserve ~10% of the node's total CPU and ~10% of its total RAM (combined kubeReserved + systemReserved), with a floor of ~1 vCPU / 2 GiB combined** — daemons like etcd/kubelet/containerd have a baseline overhead that doesn't shrink just because the node is smaller, so very small nodes need the floor, not the percentage, to actually protect them.

Worked example — the scenario you asked about, dev at 4 cores vs prod at 12 cores:

| Node | Total capacity | 10% rule gives | Floor applies? | Recommended reservation |
|---|---|---|---|---|
| Dev (example: 4 vCPU / 8 GB) | 4 vCPU / 8 GB | 400m / 800Mi | Yes — 10% (400m/800Mi) is below the 1 vCPU/2Gi floor | **Use the floor: 1 vCPU / 2 GiB combined** |
| Prod (example: 12 vCPU / 32 GB) | 12 vCPU / 32 GB | 1200m / 3.2Gi | No — 10% already exceeds the floor | **Use the 10% figure: ~1.2 vCPU / ~3.2 GiB combined** |

Applying this same rule to your **actual** current fleet shows why a flat 500m/1Gi + 500m/1Gi (1 vCPU/2 GiB combined) everywhere is a simplification, not a precise fit:

| Node | Actual spec | 10% rule (combined) | Currently reserved (combined) | Currently over/under the 10% target |
|---|---|---|---|---|
| MN-01/02/03 | 4 vCPU / 12 GB | 400m / 1.2 GiB → floor applies → 1 vCPU / 2 GiB | 1 vCPU / 2 GiB | Matches the floor — correct as-is |
| WN-01 | 16 vCPU / 16 GB | 1.6 vCPU / 1.6 GiB | 1 vCPU / 2 GiB | Under-reserving CPU slightly (1 vs 1.6), over-reserving RAM slightly — close enough, but the tightest node, worth revisiting once real usage data exists |
| WN-02/03/04 | 8 vCPU / 32 GB | 800m / 3.2 GiB | 1 vCPU / 2 GiB | Over-reserving CPU, under-reserving RAM relative to the rule — fine given headroom, but not the "correct" 10% number |
| DB-LB-01 | 8 vCPU / 16 GB | 800m / 1.6 GiB | 1 vCPU / 2 GiB | Slightly over-reserved both ways — acceptable given this node protects the sole DB access path |
| RPT-01 | 8 vCPU / 32 GB | 800m / 3.2 GiB | 1 vCPU / 2 GiB | Same as WN-02/03/04 |

None of these are *wrong* — they're all safely on the conservative side — but if you want to be precise rather than approximate, recompute per node with the 10%-with-a-floor rule above instead of copying the flat number.

**More rigorous alternative, if you want it:** GKE's published node-allocatable formula (a well-known, publicly documented reference point, not something specific to this cluster) uses a tiered percentage instead of a flat 10% — for memory: 25% of the first 4 GB, 20% of the next 4 GB (4-8 GB), 10% of the next 8 GB (8-16 GB), 6% of the next 112 GB (16-128 GB); for CPU: 6% of the first core, 1% of the next core, 0.5% of cores 3-4, 0.25% beyond that. This is more precise for very large or very small nodes than a flat 10%, at the cost of being more complex to apply by hand.

### sysctl connection-handling values (Section 3)

- **`somaxconn` / `tcp_max_syn_backlog` / `netdev_max_backlog`**: these track *expected concurrent connections*, which scales with traffic (number of services × replicas × concurrent users), not CPU/RAM directly. There's little cost to setting these generously — 65535 is a ceiling, not something you pay for unless you actually reach it — so the same value is reasonable on a 4-core dev box or a 12-core prod node; only revisit if you're deploying at 10x this cluster's scale (thousands of concurrent users, not hundreds).
- **`nf_conntrack_max`** is the one exception that has a real RAM cost: each tracked connection costs roughly 300-350 bytes of kernel memory. **Rule: keep `conntrack_max × 350 bytes` under ~2-3% of the node's total RAM.** At 1,048,576 entries, that's ~350 MB — about 3% of a 12 GB node (fine), but ~9% of a 4 GB dev box (worth halving to ~524,288 there, or checking actual usage via `conntrack -C` before assuming you need the full 1M).
- **`fs.file-max`** and the ulimits: driven by expected number of open files/sockets (proportional to connection count and process count), not RAM directly, though extremely small nodes with little RAM can't usefully hold as many open file descriptors anyway — no specific formula needed at the scale this cluster runs at.

### HAProxy `nbthread` / `maxconn` (`K8s_multi_master/configs/haproxy.cfg`)

- **`nbthread`: roughly 50% of the node's vCPU count** when HAProxy shares the node with etcd/apiserver (as on your masters) — leaves the other half for the k8s control-plane processes it's fronting. On a dedicated LB-only node, you could reasonably use closer to 100% of cores. At 4 vCPU per master, `nbthread 2` already follows this 50% rule.
- **`maxconn`: sized so that `maxconn × ~32 KB` (a rough per-connection buffer estimate) stays under ~10-15% of available RAM.** At `maxconn 20000`, worst-case buffer usage is ~640 MB — about 5% of a 12 GB master, comfortably under the guideline. On a much smaller box (e.g. a 2 GB dev VM), you'd want to cut this down (e.g. `maxconn 2000-4000`) rather than copy 20000 verbatim.

### Guaranteed QoS resource requests/limits (Section 2: ingress-nginx, MySQL Router, redis-session)

**Rule: size each Guaranteed pod at no more than ~15-25% of the *allocatable* capacity of the node it's expected to land on**, leaving room for at least 3-4x headroom for bursts, other pods sharing the node, and the kubelet/system reservation above. This is a starting point for a fresh deployment with no usage data yet — always recalibrate from `kubectl top pod` after real traffic exists (Section 2 already says this; the point here is *how* to pick the starting number before that data exists, and how to rescale it for different hardware).

Worked check against your actual values:
- ingress-nginx at 2 CPU/2 GiB on WN-01 (16 vCPU/16 GB, ~15 vCPU/~14 GiB allocatable after the reservation above) ≈ 13% CPU / 14% RAM — within the 15-25% guideline.
- MySQL Router at 1 CPU/512 MiB on DB-LB-01 (8 vCPU/16 GB, ~7 vCPU/~14 GiB allocatable) ≈ 14% CPU / 3.6% RAM — comfortably within range.
- redis-session at 500m/1 GiB on the general pool (8 vCPU/32 GB, ~7 vCPU/~30 GiB allocatable per node) ≈ 7% CPU / 3.3% RAM — well within range, and correctly conservative since this shares a node with many other phx-* pods.

If you moved any of these to a 4-core/8 GB dev box, the same **percentage** (not the same absolute number) is what to preserve — e.g. ingress-nginx at ~13-14% of a 4 vCPU/8 GB dev node would be roughly 500m CPU / 1 GiB RAM, not the prod values of 2 CPU/2 GiB.

### NFS `nfsd` thread count (Section 7 / `05-nfs-server-setup.md`)

**Rule of thumb: 8-16 threads per vCPU on the NFS server, scaled up further for higher expected concurrent-client counts.** NFS-01 has 4 vCPU and ~13 nodes potentially mounting concurrently — 8 threads/core × 4 cores = 32 as a bare floor, scaled up to 128 to give headroom for concurrent access from all ~13 nodes plus some safety margin. On a dev NFS box with 2 vCPU and only 2-3 clients, something like 16-32 threads would be the equivalent starting point, not 128.

### containerd/kubelet log rotation (`containerLogMaxSize`/`containerLogMaxFiles`, `03`/`04`)

**Rule: `containerLogMaxSize × containerLogMaxFiles × (expected containers per node)` should stay under ~5-10% of the node's local disk.** At 200 MiB × 7 files ≈ 1.4 GiB per container, this is trivial on the 512 GB nodes but worth checking specifically on **RPT-01, which only has 256 GB** — still fine at typical container counts, but the one node in this fleet where this ratio is tightest, so it's the first place to reduce `containerLogMaxFiles` if disk pressure ever shows up there.
