# HIMS Production Kubernetes Cluster — Setup Plan

Consolidated plan based on current server inventory and decisions made during planning.

---

## Portable vs Environment-Specific Values in This Plan

| Value / decision | Portable across environments? | Notes |
|---|---|---|
| Node taint naming pattern (`dedicated=<role>:NoSchedule`, `node-role=<role>`) | **Portable** | The convention is reusable; the specific `<role>` values and which physical node gets which are environment-specific (below) |
| Guaranteed QoS requirement (`requests == limits` for ingress/MySQL Router/redis-session) | **Portable** | The *policy* is universal; the actual CPU/memory numbers are hardware-dependent — see `02-technical-implementation-guide.md` |
| Redis split into session vs cache instances, with `noeviction`/`allkeys-lru` respectively | **Portable** | Architectural decision independent of hardware — applies at any scale |
| InnoDB Cluster needing 3 members for Group Replication quorum | **Portable** | Quorum math is a MySQL Group Replication fact, not a spec-dependent choice |
| NFS scope rule (app PVCs only, never DB storage) | **Portable** | Architectural principle, holds regardless of hardware |
| Node hostnames/IPs, and the RAM/CPU figures used in the capacity math (Section 9's "96 GB total" etc.) | **Environment-specific** | Tied directly to `00-server-requirements.md` — recalculate if hardware changes |
| Replica counts (2, 3, etc. per service) | **Environment-specific** | Best-effort numbers sized for *this* hardware and 800 concurrent users (Section 10) — re-derive for a different scale |
| MySQL Router placement on DB-LB-01 specifically | **Environment-specific** | Depends on a DB-LB-01-shaped node existing; a different topology could place it elsewhere |

---

## 1. Server Inventory

| Host | IP | vCPU | RAM | Disk | Role |
|---|---|---|---|---|---|
| HIMS-PRD-MN-01 | 10.200.50.129 | 4 | 12 GB | 512 GB | k8s control plane |
| HIMS-PRD-MN-02 | 10.200.50.130 | 4 | 12 GB | 512 GB | k8s control plane |
| **HIMS-PRD-MN-03 (new)** | TBD | 4 | 12 GB | 512 GB | k8s control plane (added for etcd quorum) |
| HIMS-PRD-WN-01 | 10.200.50.131 | 16 | 16 GB | 512 GB | k8s worker — tainted (gateway) |
| HIMS-PRD-WN-02 | 10.200.50.132 | 8 | 32 GB | 512 GB | k8s worker — general pool |
| HIMS-PRD-WN-03 | 10.200.50.133 | 8 | 32 GB | 512 GB | k8s worker — general pool |
| HIMS-PRD-WN-04 | 10.200.50.134 | 8 | 32 GB | 512 GB | k8s worker — general pool |
| HIMS-PRD-DB-01 | 10.200.50.135 | 16 | 48 GB | 4 TB | MySQL InnoDB Cluster member |
| HIMS-PRD-DB-02 | 10.200.50.136 | 16 | 48 GB | 4 TB | MySQL InnoDB Cluster member |
| HIMS-PRD-DB-LB-01 | 10.200.50.137 | 8 | 16 GB | 512 GB | k8s worker — tainted (DB routing) |
| HIMS-PRD-NFS-01 | 10.200.50.138 | 4 | 16 GB | 8 TB | NFS storage (app PVCs only) |
| HIMS-PRD-DB-IG-01 | 10.200.50.139 | 4 | 16 GB | 512 GB | Reserved — not yet allocated |
| HIMS-PRD-DB-RPT-01 | 10.200.50.140 | 8 | 48 GB | 4 TB | MySQL InnoDB Cluster member (3rd, reporting) |
| HIMS-PRD-LOG-01 | 10.200.50.141 | 4 | 16 GB | 1 TB | Logging + Prometheus/Grafana |
| HIMS-PRD-RPT-01 | 10.200.50.142 | 8 | 32 GB | 256 GB | k8s worker — tainted (reporting) |

---

## 2. Control Plane HA

- **Problem:** 2 master nodes cannot achieve etcd quorum — losing either one takes the whole API server down (2-node etcd is worse than 1-node for availability).
- **Decision:** Add a 3rd master node (odd number required for quorum).
- **Load balancing:** HAProxy + keepalived running on all 3 master nodes (no separate LB hardware needed).
  - keepalived provides a floating VIP via VRRP across the 3 masters. Use a unique `router_id`, VRRP auth password, and priority ordering per node to avoid split-brain.
  - HAProxy on each master round-robins/least-conns to all 3 API servers' `:6443`, with a TCP or `/healthz` check.
  - **Critical:** every worker kubelet config and every kubeconfig (including admin `kubectl` access) must point at the VIP, not at MN-01's IP directly — otherwise MN-01 going down still breaks everything.

---

## 3. Database Layer — MySQL InnoDB Cluster

- **Topology:** DB-01, DB-02, DB-RPT-01 as a 3-node Group Replication cluster (InnoDB Cluster). 3 members needed because Group Replication also requires majority quorum — 2 nodes cannot auto-fail over, same issue as etcd.
- **Tradeoff accepted:** DB-RPT-01 was originally meant purely for reporting; using it as a Group Replication member risks report queries interfering with cluster health/flow control. Mitigations:
  - Tune `group_replication_flow_control` conservatively.
  - Route heavy/long-running reporting queries through a dedicated read-only connection path, not the same session path as OLTP traffic.
- **MySQL Router:** runs in-cluster on **HIMS-PRD-DB-LB-01** (tainted node, as `phx-db-loadbalance-service`) — gives all app services a single stable endpoint regardless of which node is currently primary.
- **DB-IG-01:** currently reserved, no role assigned yet. Decide before go-live whether it stays spare or gets a purpose.
- **Storage requirement:** MySQL data directories must live on local/attached disk on DB-01/02/DB-RPT-01 — never on NFS. Keeps DB I/O off the network-storage path entirely.
- **To verify:** confirm DB-01/02/DB-RPT-01 disks are local SSD/NVMe, not spinning disks or network-attached — disk latency directly limits InnoDB throughput at 800 concurrent users.

---

## 4. Storage — NFS

- **Scope:** NFS-01 backs **app-level PVCs only** — image uploads and patient report files. Never database storage.
- **Provisioning:** use an NFS CSI driver (or `nfs-subdir-external-provisioner`) for dynamic PVC provisioning per namespace/environment, rather than static PVs.
- **Capacity/retention:** patient report/image data grows continuously and never shrinks on its own — define an archival/retention policy (e.g. move data older than N months to cold storage) before the 8 TB fills up.
- **Redundancy/backup:** NFS-01 is a single point of failure with no built-in redundancy. Add scheduled backup/snapshot to a separate location — this now holds real patient data, not just cache.
- **Performance:** load-test the upload path specifically under concurrent load (not just assumed from disk size) and tune NFS mount options (`nconnect`, `rsize`/`wsize`) if latency shows up.

---

## 5. Caching Layer — Redis

Redis is used for **both session storage and general application/query caching** ("all queries, all data"). These have conflicting requirements and should be split into two separate instances:

| Instance | Eviction policy | Persistence | HA | Notes |
|---|---|---|---|---|
| redis-session | `noeviction` | AOF | Sentinel (1 primary + 2 replica + 3 sentinel) | Critical path — losing this force-logs-out every active user |
| redis-cache | `allkeys-lru` | none needed | single instance acceptable | Losing this just means a temporary DB load spike (cache rebuilds) |

- **Do not** run both concerns on one instance — under memory pressure, `allkeys-lru` would evict sessions too, causing mass logout exactly when the system is under load.
- **Patient-safety note:** if clinical/patient-state data (allergies, active medications, lab results) gets cached, stale reads are a safety issue, not just a performance one. Use short TTLs or write-through invalidation (update DB → invalidate/update cache in the same path) for clinical data. Reference/master data can use longer TTLs.
- **Sizing:** do not size production RAM off the dev measurement (300-400 MB) — dev has near-zero concurrent load and small data volume. Start with a generous but capped `maxmemory` (e.g. 2-4 Gi for cache), deploy `redis_exporter` + a Grafana panel from day one, and calibrate against real eviction/memory metrics after go-live.
- **Placement:** general worker pool (WN-02/03/04), **not** DB-LB-01. DB-LB-01 is a dedicated/tainted node specifically isolating the DB routing path (MySQL Router) from other workloads — putting a variable-footprint cache there couples two failure domains that have no reason to share fate (a Redis memory spike could pressure the node that every service's DB access depends on). Set `requests == limits` on memory wherever Redis lands, to bound blast radius on that node too.

---

## 6. Node Taints, Tolerations & Affinity

| Node | Taint | Services (toleration + nodeAffinity) |
|---|---|---|
| HIMS-PRD-WN-01 | `dedicated=gateway:NoSchedule` | phx-gateway-service, phx-php-service, ingress-nginx |
| HIMS-PRD-DB-LB-01 | `dedicated=db-lb:NoSchedule` | phx-db-loadbalance-service (MySQL Router), phx-php-nginx-service |
| HIMS-PRD-RPT-01 | `dedicated=report:NoSchedule` | phx-helical-service |
| WN-02/03/04 | none (general pool) | all other phx-* services, redis-session, redis-cache |

- Pair every taint with a matching **node label** (e.g. `node-role=gateway`) — a toleration only *permits* scheduling there, it doesn't attract the pod. Use `nodeAffinity`/`nodeSelector` alongside the toleration to actually pin the service.
- Put both toleration and affinity in each service's `values-production.yaml` in Helm, so ArgoCD renders it consistently per environment rather than hardcoding node names in shared templates.

---

## 7. Ingress & TLS

- **Current gap:** ingress-nginx is single-homed on WN-01 with no stated failover — unlike phx-gateway-service/phx-php-service, which are explicitly failover-capable.
- **Recommendation:** run ≥2 ingress-nginx replicas with pod anti-affinity, so a WN-01 failure doesn't take down all external access. (Node placement for the 2nd replica still to be finalized.)
- **TLS:** currently public CA, no wildcard — means manual per-service/per-host cert issuance and renewal. Consider `cert-manager` if your CA supports ACME or an API integration, to avoid manual renewal toil across every service+ingress host indefinitely. **Open decision.**

---

## 8. Monitoring & Logging

- LOG-01 (4 vCPU/16 GB/1 TB) will host both the logging stack and Prometheus + Grafana + Alertmanager.
- **Watch capacity here:** metrics + log retention for a ~13-node cluster with 26+ services at 800 concurrent users can fill 1 TB faster than expected. Define retention windows explicitly up front (e.g. 15-day metrics, 30-day logs) rather than discovering the disk is full in production.

---

## 9. Performance Recommendations (Current Spec)

Beyond the architecture decisions above, these are worth applying given the hardware as specified:

- **WN-01 RAM/CPU imbalance:** 16 vCPU but only 16 GB RAM — the least RAM of any general-purpose-ish node despite the most CPU. It hosts gateway, php, and ingress together. Monitor RAM headroom here specifically once real traffic hits; it's more likely to hit a memory ceiling than a CPU one.
- **kube-proxy mode:** switch from default iptables to IPVS (or Calico's eBPF dataplane if the kernel supports it) — with 26+ services × multiple replicas, iptables rule chains grow large and add latency; IPVS/eBPF scales better at this service count.
- **Calico eBPF dataplane:** consider enabling it for lower-latency east-west traffic between the many phx-* services and the DB routing path, if kernel version supports it.
- **HPA (Horizontal Pod Autoscaler):** enable on phx-* services based on CPU/RAM (or custom latency/queue-depth metrics) so replica counts flex under real load instead of staying fixed at the currently-planned static numbers, which are best-effort guesses.
- **Connection pooling & MySQL Router limits:** ensure each phx service uses a bounded connection pool, and explicitly tune MySQL Router's `max_connections` for 800 concurrent users across ~20 services — an unbounded fan-in of connections is a common bottleneck at this scale.
- **Read/write split:** route reporting/read-heavy queries through a read-only path via MySQL Router rather than the primary — improves both performance and isolates DB-RPT-01's dual role.
- **Guaranteed QoS for latency-sensitive pods:** set `requests == limits` (Guaranteed QoS class) for ingress-nginx, MySQL Router, and redis-session so they aren't first in line for eviction or CPU throttling under node memory/CPU pressure.
- **OS-level tuning for high connection counts:** disable swap (required by kubelet anyway), set `vm.swappiness=0`, and raise `net.core.somaxconn`, `net.ipv4.ip_local_port_range`, and `fs.file-max` on nodes handling high concurrent connections (WN-01, DB-LB-01, general pool).
- **kubelet reserved resources:** set `systemReserved`/`kubeReserved` appropriately per node so OS overhead doesn't eat into pod-schedulable capacity — especially relevant on the smaller-RAM nodes (WN-01, DB-LB-01, LOG-01).

---

## 10. Still Open / To Decide

- [ ] Real per-service CPU/RAM usage at 800 concurrent users — needs load testing; current replica counts are best-effort guesses.
- [ ] RAM capacity budget for WN-02/03/04 (96 GB total) — build an explicit spreadsheet of per-service requests × replicas + Redis before finalizing Helm resource values.
- [ ] DB-IG-01 — decide future use or leave reserved.
- [ ] Ingress 2nd replica — confirm which node it runs on.
- [ ] TLS strategy — cert-manager vs manual renewal.
- [ ] Backup/DR strategy — etcd snapshots, InnoDB Cluster backups, NFS backups — none formally defined yet.
- [ ] RBAC design, private registry, image scanning, secrets management (e.g. Vault or sealed-secrets) — not yet covered.
- [ ] Calico NetworkPolicies for namespace/service isolation — relevant given this handles hospital data.
- [ ] PodDisruptionBudgets and readiness/liveness probes per service.
- [ ] Confirm DB-01/02/DB-RPT-01 disks are local SSD/NVMe, not network-attached or spinning disks.

---

## 11. Helm / ArgoCD Structure (not yet built)

- Structure as an ArgoCD app-of-apps, one Helm chart per phx-* service (or a shared chart with per-service values).
- Per-service `values-production.yaml` should carry: replica count, resource requests/limits, tolerations, nodeAffinity, and any taints-derived scheduling rules from Section 6.
- Keep environment-specific scheduling constraints (taints/affinity) out of shared templates so non-production environments aren't accidentally pinned to production node names.
