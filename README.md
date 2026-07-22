# HIMS Production Kubernetes Cluster — Documentation Index

Start here. This folder documents the production k8s cluster build for HIMS, from
hardware inventory through to the actual node-by-node runbooks. Files are numbered in
the order you should read/check them — earlier files establish the *why*, later files
are the actual *how*.

## Read/verify in this order

| # | File | What it is | Why it comes at this point |
|---|---|---|---|
| 00 | [`00-server-requirements.md`](00-server-requirements.md) | Original server inventory (hostnames, IPs, CPU/RAM/disk) and the initially-planned service replica counts | Ground truth for every resource decision downstream — if hardware changes, everything after this needs re-checking against it |
| 01 | [`01-architecture-plan.md`](01-architecture-plan.md) | The architecture decisions and their rationale: control-plane HA, InnoDB Cluster topology, NFS scope, Redis split, taints/tolerations, open items still to decide | Explains *why* the cluster is shaped this way before you look at *how* to build it |
| 02 | [`02-technical-implementation-guide.md`](02-technical-implementation-guide.md) | Detailed how-to for the hardening/performance items named in `01` — Calico eBPF, Guaranteed QoS, OS-level sysctl tuning, kubelet reserved resources, backup/DR, NetworkPolicies, NFS efficiency — each with why-it-matters and expected impact | Deep-dive reference for specific topics; the node runbooks below point back into this file rather than repeating the reasoning inline |
| — | [`K8s_multi_master/`](K8s_multi_master/) *(external folder)* | **The single source of truth** for the HAProxy + keepalived + etcd-backup control-plane HA layer — production-ready configs (`configs/`, populated with real HIMS values in `PRODUCTION-VALUES.md`), a full failover/DR playbook, `configs/PORT-6443-CONFLICT-FIX.md` for the HAProxy-vs-kube-apiserver port conflict this self-hosted topology runs into at `kubeadm init`/`join`, and `configs/ETCD-BACKUP-TROUBLESHOOTING.md` for when the backup is installed but isn't actually producing files | Required reading before the "HAProxy + keepalived" step in `03` Section 1 — `03` no longer carries its own copy of this config, it just points here |
| 03 | [`03-master-node-setup.md`](03-master-node-setup.md) | Actual build runbook for HIMS-PRD-MN-01/02/03: OS prep, containerd, kubeadm HA bring-up, Calico, MetalLB + ingress, NFS CSI, NetworkPolicies, cert-manager, ArgoCD, monitoring exporters | First runbook to execute — the control plane must exist before any worker can join |
| 04 | [`04-worker-node-setup.md`](04-worker-node-setup.md) | Actual build runbook for HIMS-PRD-WN-01..04, DB-LB-01, RPT-01: OS prep, join, node-specific taints/labels | Run after `03` — workers join against the control plane's VIP |
| 05 | [`05-nfs-server-setup.md`](05-nfs-server-setup.md) | Actual build runbook for HIMS-PRD-NFS-01: disk/network checks, exports split by workload, mount tuning | Can be built in parallel with `03`/`04`, but StorageClasses in `03` need its exports to exist before PVCs will bind |
| 06 | [`06-validation-testing.md`](06-validation-testing.md) | One test command per config item across every file above and `K8s_multi_master/configs/`, each with an explicit "run this on `<host>`" — plus the order to actually run them in | Use after (or during) executing `03`-`05` to confirm each piece actually works, not just that the commands ran without error |

## Quick mental model

```
00 (hardware facts)
   -> 01 (decisions made from those facts)
        -> 02 (how to implement the hardening those decisions call for)
             -> K8s_multi_master/ (deep-dive for the HA control-plane piece specifically)
        -> 03, 04, 05 (execute: masters, then workers, then NFS)
             -> 06 (validate every piece actually works, with exact commands + hosts)
```

## Naming convention

Numbered prefixes (`00`-`05`) reflect the order to read and execute the docs, not
alphabetical or chronological order of when they were written. If a new doc is added
between two existing steps, renumber rather than inserting suffixes like `03a` — keeps
the ordering unambiguous at a glance from `ls`. `K8s_multi_master/` is left unnumbered
since it's an external reference folder, not a step in this sequence.

## Cross-references

Each file references the others by their current filename (e.g. `03-master-node-setup.md`
Section 6) — if you rename any file again, update the references in the other files to
match, or the pointers will go stale.
# Multi-master-kubeadm-conf
# Multi-master-kubeadm-conf
