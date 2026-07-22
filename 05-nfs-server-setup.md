# Production NFS Server Setup (HIMS-PRD-NFS-01)

Adapted from your UAT NFS runbook, applying the efficiency levers from `02-technical-implementation-guide.md` Section 7 and the scope rule from `01-architecture-plan.md` Section 4 (NFS backs app PVCs only — uploads and patient reports — never database storage).

---

## Portable vs Environment-Specific Values in This Runbook

| Item | Portable? | Notes |
|---|---|---|
| `lsblk`/`ethtool` disk-and-network verification steps | **Portable** | Worth checking on any NFS box regardless of spec |
| NFSv4.2, `sync` (not `async`), separate-exports-by-workload approach | **Portable** | Policy/architecture decisions independent of hardware |
| nfsd thread count (`threads=128`) | **Environment-specific** | Tied to ~13 nodes mounting concurrently and this box's vCPU count — re-tune for a different node count |
| Export paths (`/srv/nfs/phx_prod_*`), subnet (`10.200.50.0/24`) | **Environment-specific** | This environment's naming convention and actual network range |
| `chmod 770` tightening, `no_root_squash` requirement | **Portable reasoning, environment-specific value** | The *reasoning* (tighten from UAT's 777; `no_root_squash` needed for CSI dynamic provisioning) applies anywhere; the exact UID/GID must be re-verified per environment against whatever the CSI driver/pods actually run as |
| Mount options (`nconnect=4`, `rsize`/`wsize=1048576`) | **Environment-specific** | Tied to actual client kernel support and network capacity — verify before reuse |

---

## 0. Before anything else — confirm the disk

This dominates every other change below. If HIMS-PRD-NFS-01's 8 TB is spinning disk, no NFS tuning here will fix the real bottleneck (random I/O differs by 100-1000x between HDD and SSD/NVMe). Confirm now, not after go-live:
```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL
# ROTA=1 means spinning disk, ROTA=0 means SSD/NVMe
```
Also confirm network capacity — 1GbE tops out around 125 MB/s and will saturate under concurrent access from ~13 cluster nodes plus 800 users' worth of upload/report traffic; 10GbE gives a flat 10x ceiling increase if it's not already in place:
```bash
ethtool eth0 | grep Speed
```

---

## 1. Install NFS kernel server
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y nfs-kernel-server
```

## 2. Increase nfsd thread count
Default is often just 8 threads — well known to be too few once more than a handful of clients mount concurrently, and you have ~13 nodes potentially mounting from this box.

`/etc/nfs.conf`:
```
[nfsd]
threads=128
```
```bash
sudo systemctl restart nfs-server
```
Validate under load with `nfsstat -rpc` (growing wait time = still under-provisioned) rather than assuming 128 is the right final number.

**Sizing basis:** ~8-16 threads per vCPU on the NFS server, scaled up for expected concurrent-client count — see `02-technical-implementation-guide.md` Section 8. NFS-01 has 4 vCPU and ~13 nodes that may mount concurrently, so 128 is that rule applied here, not an arbitrary round number; a dev NFS box with 2 vCPU and 2-3 clients would start much lower (16-32).

## 3. Separate exports by workload

Unlike UAT's single shared directory, split uploads / reports / backups onto **separate directories** (ideally separate underlying volumes/partitions if the hardware allows it) so a backup job or a burst of report generation doesn't starve live upload traffic.

```bash
sudo mkdir -p /srv/nfs/phx_prod_uploads
sudo mkdir -p /srv/nfs/phx_prod_reports
sudo mkdir -p /srv/nfs/phx_prod_backups

sudo chown nobody:nogroup /srv/nfs/phx_prod_uploads /srv/nfs/phx_prod_reports /srv/nfs/phx_prod_backups
sudo chmod 770 /srv/nfs/phx_prod_uploads /srv/nfs/phx_prod_reports /srv/nfs/phx_prod_backups
```
Note: UAT used `chmod 777` — tightened to `770` here since this now holds real patient data, not UAT test data. Confirm the actual UID/GID your CSI driver/pods run as and adjust ownership accordingly rather than opening it to everyone.

## 4. Export with NFSv4.2, restricted to the cluster subnet
```bash
cat <<EOF | sudo tee -a /etc/exports
/srv/nfs/phx_prod_uploads  10.200.50.0/24(rw,sync,no_subtree_check,no_root_squash)
/srv/nfs/phx_prod_reports  10.200.50.0/24(rw,sync,no_subtree_check,no_root_squash)
/srv/nfs/phx_prod_backups  10.200.50.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

sudo exportfs -rav
sudo exportfs -v
sudo systemctl enable --now nfs-server
sudo systemctl status nfs-server
sudo showmount -e
```

`sync` (not `async`) is kept here deliberately — this holds patient uploads/reports, and `async` risks acknowledging a write before it's actually durable on disk, which is not an acceptable tradeoff for this data even though it would be faster.

## 5. Backup job (targets `/srv/nfs/phx_prod_backups`)
Per `01-architecture-plan.md`/`02-technical-implementation-guide.md` Section 5:
- etcd snapshots and MySQL XtraBackup output land here from the master/DB nodes.
- NFS's own uploads/reports data should itself be backed up **off** this box — via `zfs send/receive` if the underlying filesystem is ZFS, or Restic/BorgBackup (dedup + encryption) otherwise — to a genuinely separate target, since this single disk is still a point of failure regardless of internal export separation.
- Encrypt backups at rest — this is patient data.

---

## 6. In the cluster: StorageClasses per export

See `03-master-node-setup.md` Section 7 for the full StorageClass/PVC definitions — one `StorageClass` per export (`nfs-uploads-rwx`, `nfs-reports-rwx`), each with production mount options:
```
vers=4.2,nconnect=4,rsize=1048576,wsize=1048576,noatime,hard,timeo=600
```

- `nconnect=4` — parallelizes a mount across multiple TCP connections; published benchmarks report roughly 2-4x throughput improvement for high-parallelism workloads bottlenecked by a single connection's TCP window. Requires a reasonably modern client kernel — confirm support on the worker nodes (`modinfo nfs | grep nconnect` or check kernel ≥ 5.3).
- `rsize`/`wsize=1048576` only helps if the negotiated size isn't already 1 MB — check current negotiated values with `nfsstat -m` on a mounted worker before assuming this is a real gap.

---

## 7. Monitor before it becomes an incident
Add `node_exporter` on NFS-01 plus NFS-specific stats to the Prometheus/Grafana stack on HIMS-PRD-LOG-01 (`01-architecture-plan.md` Section 8):
```bash
nfsiostat
cat /proc/net/rpc/nfsd
```
Client-side, `mountstats` on any worker (`cat /proc/self/mountstats | grep -A20 phx_prod`) shows per-mount RPC latency — useful for catching a growing bottleneck before staff start reporting slow report/image loads.

---

## 8. Does this affect existing traffic flow?

This document only affects **storage I/O paths** (pods reading/writing uploads and reports) — it has no interaction with north-south application traffic (external client → ingress → services) at all. The two things worth flagging as *changes from UAT* rather than pure additions:

- **Export paths changed** (`phx_uat_data` → three separate `phx_prod_*` exports). Any Helm chart or values file copied forward from UAT that hardcodes the old share path or the old single combined mount will fail to find its data — update the `share:` parameter in each StorageClass to match the correct export for that workload (uploads vs reports), not a single shared one.
- **Permissions tightened** (`777` → `770`). If any existing pod runs as a UID/GID that UAT's open permissions were silently covering for, it may get permission-denied errors on first mount in production. Test each service's actual write path against the tightened permissions before go-live, not after.
