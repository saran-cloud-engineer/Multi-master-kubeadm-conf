# etcd Backup — Troubleshooting

Companion to [`ETCD_BACKUP.md`](ETCD_BACKUP.md) (setup) and
[`PRODUCTION-VALUES.md`](PRODUCTION-VALUES.md) — this doc is for when the backup is
installed but isn't actually producing files, on a node you've already set up.

## Symptom: NFS mount to NFS-01 works fine, but no etcd snapshot files ever appear — locally or off-node

Don't assume the NFS mount being fine means the backup itself is fine — they're
separate mechanisms. A manually-created test file syncing correctly through
`/mnt/etcd-backups/` only proves the **mount** works; it says nothing about whether
`etcd-backup.sh`/`.service`/`.timer` have ever actually run.

### Step 1 — check by log tag, not just by systemd unit

`journalctl -u etcd-backup.service` only shows runs triggered **through systemd**. If
the script was ever run directly (`sudo /usr/local/sbin/etcd-backup.sh`, e.g. for
manual testing), that output goes to the general log under its `logger` tag instead,
and won't show up under the unit at all:

```bash
sudo journalctl -t etcd-backup -n 50 --no-pager
```
(Note: `--no-pager`, not `--no-paper` — an easy typo that just errors the command
outright rather than doing something unexpected.)

If **this** comes back empty too, the script has never successfully logged anything at
all, on this node, by any invocation method — move to Step 3.

### Step 2 — confirm the timer/service are actually installed and enabled

```bash
systemctl list-timers | grep etcd-backup
systemctl status etcd-backup.timer
systemctl status etcd-backup.service
```
If these come back "could not be found" or show as disabled, the install step from
`ETCD_BACKUP.md` (`sudo cp etcd-backup.service /etc/systemd/system/... && sudo cp
etcd-backup.timer /etc/systemd/system/... && sudo systemctl daemon-reload && sudo
systemctl enable --now etcd-backup.timer`) likely never actually ran on this specific
node — easy to miss when this needs repeating identically on all 3 masters.

### Step 3 — trigger it fresh, through systemd, and watch it end to end

```bash
sudo systemctl start etcd-backup.service
journalctl -u etcd-backup.service -n 50 --no-pager
```
This is the most direct test. Every step in the script logs its own success/failure
(snapshot save, snapshot verify, the off-node copy, rotation) — the log will show
exactly which step it dies at, rather than just "it didn't work."

### Step 4 — isolate whether `etcdctl` itself even works, independent of the script entirely

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/manual-test-snapshot.db
```
If this fails on its own, the problem is etcd/cert access on this node — unrelated to
the script, the timer, or the NFS copy. Fix this first before re-testing the script.

### Reading the result

| What you see | What it means |
|---|---|
| Step 1 empty, Step 2 shows timer/service missing | Install step from `ETCD_BACKUP.md` was never run on this node — do that first |
| Step 1 empty, Step 2 shows timer/service present and enabled | Installed but never actually fired yet — check `systemctl list-timers`' `NEXT`/`LEFT` columns, or just run Step 3 to trigger it now rather than waiting |
| Step 3 fails at the `etcdctl snapshot save` line specifically | Go straight to Step 4 — isolates whether it's an etcd/cert problem versus something in the script's own logic |
| Step 3 succeeds through snapshot save/verify but fails/warns at the copy step | The snapshot itself is fine and safe locally — only the off-node copy needs fixing (check the NFS mount is actually active *at the moment the timer fires*, not just when you tested it manually: `mount \| grep etcd-backups`) |
| Step 4 fails on its own | Not a script problem at all — check cert file paths exist (`ls -la /etc/kubernetes/pki/etcd/`) and that etcd itself is healthy (`sudo crictl ps \| grep etcd`) |

## Confirmed real-world case: `etcd-backup.sh: line 47: etcdctl: command not found`

Seen via Step 3's `journalctl -u etcd-backup.service -n 50 --no-pager` output:
```
Jul 22 01:06:28 hims-prd-mn-01 systemd[1]: Starting One-shot etcd snapshot backup for this control-plane node...
Jul 22 01:06:28 hims-prd-mn-01 etcd-backup.sh[2527794]: /usr/local/sbin/etcd-backup.sh: line 47: etcdctl: command not found
Jul 22 01:06:28 hims-prd-mn-01 systemd[1]: etcd-backup.service: Main process exited, code=exited, status=1/FAILURE
```

**What this actually means, and what it doesn't:** the timer and service infrastructure
are working *correctly* — the timer fired exactly on schedule, the service ran, and it
logged the failure clearly. This is not a systemic problem, just one missing binary:
`etcdctl` was never installed on this host. kubeadm never installs it — it only runs
etcd's binary inside the static pod's container image (same gap tracked in
`DEPLOY_TO_KUBEADM_CLUSTER.md`'s "Quick Reality Check" table).

**Fix — install `etcdctl` matching the cluster's actual etcd version:**
```bash
# 1. Find the exact version this cluster is running
kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'
# e.g. output: registry.k8s.io/etcd:3.5.15-0  <- use this version below

# 2. Download the matching release
ETCD_VER=v3.5.15   # match whatever step 1 actually showed
curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd.tar.gz
tar -xzf /tmp/etcd.tar.gz -C /tmp
sudo cp /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
etcdctl version   # confirm it matches step 1
```

**Then re-trigger and confirm:**
```bash
sudo systemctl start etcd-backup.service
journalctl -u etcd-backup.service -n 20 --no-pager
sudo ls -la /var/backups/etcd/
```
Should now show an actual `etcd-snapshot-<hostname>-<timestamp>.db` file, and the log
should read `Snapshot OK: ...` instead of `command not found`.

**Check this proactively on MN-02 and MN-03 too** — same gap will hit them the first
time their own timer fires, rather than waiting to discover it the same way twice more.
