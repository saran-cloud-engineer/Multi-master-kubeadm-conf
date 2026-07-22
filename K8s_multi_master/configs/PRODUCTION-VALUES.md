# HIMS Production Values for These Configs

Answers "will this work for our prod spec" and gives the real substitution values for
`haproxy.cfg`, `keepalived.conf`, and `notify.sh` in this folder — see those files for
the actual populated config; this doc is the reference for what's real, what's still
missing, and which files need per-node copies.

---

## Will it work on our actual hardware? Yes — here's the resource math

MN-01/MN-02/MN-03 are 4 vCPU / 12 GB RAM each, running `etcd` + `kube-apiserver` +
`kube-controller-manager` + `kube-scheduler` + `kubelet` + `containerd` **plus** now
HAProxy + keepalived + `chk_haproxy.sh` (needs `socat`) + `notify.sh` + rsyslog.

- **RAM:** the k8s control-plane components together typically run well under 2 GB on a
  cluster this size (~13 nodes, ~26 services, a few hundred pods total). HAProxy itself
  is lightweight — a few MB at idle; `maxconn 20000` in `haproxy.cfg` is a ceiling, not
  actual usage, and control-plane API traffic (kubelets/controllers watching the API)
  is nowhere near 20,000 concurrent connections at this scale. keepalived is a few MB.
  Total realistic usage is comfortably under 3-4 GB, leaving well over half of each
  node's 12 GB free — and these nodes carry the automatic kubeadm `control-plane:NoSchedule`
  taint, so no application pods compete for that headroom.
- **CPU:** 4 vCPU is more than adequate for API server/etcd load at this cluster size;
  HAProxy's `nbthread 2` is a reasonable, modest allocation that won't starve the other
  processes.
- **Disk:** 512 GB is far more than etcd needs (a cluster this size typically keeps its
  etcd database in the tens-to-low-hundreds of MB) — size isn't the concern.

**One check this doc didn't cover yet and should:** etcd is very sensitive to disk
**write latency** (fsync), not just size. Run the same disk-type check already used for
the DB/NFS nodes on MN-01/02/03 before going live:
```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL
# ROTA=1 = spinning disk — etcd on spinning disk risks slow fsyncs, which can trigger
# leader elections / instability under load. Confirm SSD/NVMe here, same as the DB tier.
```

**Conclusion: architecturally and resource-wise, yes, this will work well on the stated
spec** — the gap isn't capacity, it's that several values in the configs were still
generic placeholders. Populated below; a few genuinely can't be filled in without info
only you (or your network team) have.

---

## Real values — known vs. still needed

| Placeholder | Real value | Status |
|---|---|---|
| MN-01 IP | `10.200.50.129` | ✅ known |
| MN-02 IP | `10.200.50.130` | ✅ known |
| MN-03 IP | `<MN03_IP>` | ❌ **TBD** — new node, not yet assigned — confirm it doesn't collide with whatever `CP_VIP` ends up being |
| `CP_VIP` | `<CP_VIP>` (example used elsewhere: `10.200.50.150`) | ❌ **TBD** — needs network team assignment. Once set, must match exactly in `keepalived.conf`'s `virtual_ipaddress` block (as `<CP_VIP>/24`, a real host address — not a network address like `x.x.x.0/24`) and in the `--control-plane-endpoint` flag at `kubeadm init` |
| Interface name (`eth0`) | `ens7` on MN-02 (confirmed 2026-07-20) | ⚠️ **MN-01/MN-03 not yet individually confirmed** — run this on each box: `ip -br addr` (lists every interface with its IP in one line each), then pick the one that's `UP` and shows that node's real IP (e.g. `10.200.50.129` on MN-01) — ignore `lo` (loopback) and anything virtual like `docker0`/`cni0`/`veth*`. If more than one looks live, `ip route \| grep default` shows exactly which interface the default route actually uses (`default via ... dev <IFACE>`) — that's the one. Likely `ens7` on MN-01/MN-03 too given identical provisioning, but confirm each rather than assume. |
| `virtual_router_id` (`51`) | kept as default | ⚠️ **needs confirmation** — check nothing else on `10.200.50.0/24` already uses VRRP router_id 51 |
| VRRP `auth_pass` (`Ch4ngeMe`) | — | ❌ **generate your own** — do not deploy the example value; max 8 chars, same on all 3 nodes |
| HAProxy stats password hash | — | ❌ **generate your own** via `mkpasswd -m sha-512` — the file ships a literal placeholder string, not a real hash |
| Priorities (200/150/100) | MN-01=200, MN-02=150, MN-03=100 | ✅ arbitrary but fine as assigned — MN-01 preferred owner, matches it being the `kubeadm init` node in `03-master-node-setup.md` |

**`keepalived.conf` still needs 3 separate per-node copies** — `router_id`, `priority`,
`unicast_src_ip`, and `unicast_peer` genuinely differ per master (this is inherent to
VRRP, not a gap in the file). The version in this folder is populated as the **MN-01**
copy; derive MN-02/MN-03 copies from it by swapping those 4 fields per
`DEPLOY_TO_KUBEADM_CLUSTER.md`'s existing per-node edit instructions. `haproxy.cfg` and
`notify.sh`, by contrast, are genuinely identical across all 3 nodes once `<MN03_IP>`
and `<CP_VIP>` are filled in — one file, deployed 3 times unchanged.

---

## Portable vs environment-specific, per file in this folder

| File | Portable? | Notes |
|---|---|---|
| `haproxy.cfg` | **Mostly portable, now populated** | Structure/health-check/stats-auth design is reusable anywhere; the backend `server` list now has real HIMS IPs — re-edit only if a master is added/removed |
| `keepalived.conf` | **Structure portable, values are per-node** | The file's mechanism (unicast VRRP, `nopreempt`, tracked health script) is reusable; `router_id`/`priority`/`unicast_src_ip`/`unicast_peer` are inherently per-node and this copy is populated as MN-01 specifically |
| `chk_haproxy.sh` | **Fully portable** | No environment-specific values at all — checks process/port/backend health generically; requires `socat` installed, same on any node |
| `notify.sh` | **Portable except the VIP constant** | Logic is generic; `VIP` variable now points at `<CP_VIP>` pending assignment |
| `etcd-backup.sh` / `.service` / `.timer` | **Fully portable** | No IPs or node-specific values; same script runs on all 3 masters as-is |
| `ETCD_BACKUP.md` | **Fully portable** | Pure documentation/reasoning, no environment-specific content |
| `logrotate-haproxy` | **Fully portable** | Generic log-rotation config, assumes Debian/Ubuntu (`syslog:adm`) which matches this stack |
| `rsyslog-haproxy.conf` | **Fully portable** | Generic syslog routing rule, no environment-specific content |
| `DEPLOY_TO_KUBEADM_CLUSTER.md` | **Fully portable (by design)** | Explicitly written as a placeholder-driven generic rollout guide — intentionally left generic rather than rewritten per-environment; this file (`PRODUCTION-VALUES.md`) is what supplies the real values it asks for |

---

## Before deploying — do not skip

1. Confirm MN-03's real IP and the `CP_VIP` assignment, then replace `<MN03_IP>`/`<CP_VIP>` in `haproxy.cfg`, `keepalived.conf`, and `notify.sh` — and double-check the two values don't collide with each other.
2. Run `ip -br addr` (then `ip route | grep default` if unsure which interface to pick) on MN-01 and MN-03 specifically — MN-02 is already confirmed as `ens7`; don't assume the other two match without checking.
3. Confirm `virtual_router_id 51` doesn't collide with anything else on `10.200.50.0/24`.
4. Generate a real VRRP `auth_pass` and HAProxy stats password hash — never deploy the example values shown in these files.
5. Run the `lsblk` disk-type check above on all 3 masters before going live.
6. Derive the MN-02 and MN-03 copies of `keepalived.conf` from this MN-01 copy per `DEPLOY_TO_KUBEADM_CLUSTER.md`'s per-node edit steps.
