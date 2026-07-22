# etcd Backup — Daily Snapshots, 7-Day Rotation

Files involved: [`etcd-backup.sh`](etcd-backup.sh), [`etcd-backup.service`](etcd-backup.service),
[`etcd-backup.timer`](etcd-backup.timer). If it's installed but not actually producing
snapshot files, see [`ETCD-BACKUP-TROUBLESHOOTING.md`](ETCD-BACKUP-TROUBLESHOOTING.md)
instead of re-reading the setup steps below.

## What this actually protects you from — and what it doesn't

| Failure | Does this backup help? |
|---|---|
| Bad `kubectl apply`, accidental `kubectl delete`, config drift | Yes — restore from a recent snapshot |
| A single master's etcd data directory gets corrupted | Yes — that master rejoins/restores from a snapshot |
| Quorum loss (majority of etcd members down) | Helps, but §6.2 in `multi_master_ha_setup.md` (repair from the surviving member) is preferred — only fall back to a snapshot if no member survives |
| Entire node hosting the snapshot is destroyed (disk failure, terminated VM) at the SAME time you need it | **No, not by itself.** The snapshot lives on that node's local disk. This is why the script's `OFF_NODE_COPY` hook is not optional in production — see below. |

A 7-day local rotation with no off-node copy protects you against "I broke something
today, restore yesterday's snapshot." It does **not** protect you against "the master
that had the only copy of the backup just burned down." Wire up the off-node copy.

## Install (per control-plane node — all 3 masters)

```bash
sudo cp etcd-backup.sh /usr/local/sbin/etcd-backup.sh
sudo chmod 700 /usr/local/sbin/etcd-backup.sh
sudo chown root:root /usr/local/sbin/etcd-backup.sh

sudo cp etcd-backup.service /etc/systemd/system/etcd-backup.service
sudo cp etcd-backup.timer   /etc/systemd/system/etcd-backup.timer

sudo systemctl daemon-reload
sudo systemctl enable --now etcd-backup.timer
```

Before relying on this: open `/usr/local/sbin/etcd-backup.sh` and configure the
`OFF_NODE_COPY` section (pick **one** of the options below), then set
`OFF_NODE_COPY_CONFIGURED=1` near the top so the "no off-node copy" warning stops firing
in the logs. Until you do this, treat the backup as **incomplete**.

### OFF_NODE_COPY option 1 (recommended) — NFS mount, plain local copy

If NFS-01's `/srv/nfs/phx_prod_backups` export (`05-nfs-server-setup.md`) is the backup
target, this is the simplest option — no SSH keys, no separate user account, no
network-auth setup at all.

**Where each part of this actually runs — don't skip this, it's not one step done once:**

| Step | Runs on | Notes |
|---|---|---|
| Export already exists and is live | **NFS-01** only | Prerequisite from `05-nfs-server-setup.md` — nothing to run here, just confirm it (`showmount -e` from any master) |
| Install `nfs-common` (NFS **client** package — different from NFS-01's `nfs-kernel-server` **server** package) | **Each master individually** — MN-01, MN-02, MN-03 | `sudo apt install -y nfs-common`. Without it, `mount -t nfs4` fails with `unknown filesystem type 'nfs4'` — verify first with `dpkg -l \| grep nfs-common` and `which mount.nfs4` |
| `mkdir` + `mount` + the `/etc/fstab` entry below | **Each master individually** | `/etc/fstab` is per-node, not shared — each master needs its own entry, and this whole sequence runs 3 times total (once per master), never just once cluster-wide |

**Two different directories, on two different machines — don't confuse them:**

| Directory | Where | What it actually is |
|---|---|---|
| `/srv/nfs/phx_prod_backups` | **NFS-01 only** | The real directory holding the actual snapshot files, exported over NFS. Created once, on NFS-01, per `05-nfs-server-setup.md` — not created again here. |
| `/mnt/etcd-backups` | **Each master individually** | An empty local mount point — just a "docking point" name, arbitrary, doesn't need to match NFS-01's path at all. Nothing is actually stored on the master's own disk here; once mounted, this path transparently shows the contents of NFS-01's `/srv/nfs/phx_prod_backups` over the network. Created fresh on each master via the `mkdir` below — it starts empty and stays empty until the mount is active. |

If `/srv/nfs/phx_prod_backups` doesn't exist yet on NFS-01, create it there first (same
pattern as the other exports in `05-nfs-server-setup.md`):
```bash
# On NFS-01 only
sudo mkdir -p /srv/nfs/phx_prod_backups
sudo chown nobody:nogroup /srv/nfs/phx_prod_backups
sudo chmod 770 /srv/nfs/phx_prod_backups
```
**Expected:** a plain `cd /srv/nfs/phx_prod_backups/` as your own login user will now fail
with `Permission denied` — that's correct, not broken. `770` only allows the owner
(`nobody`) and group (`nogroup`) in; your admin user is neither, by design. Use
`sudo ls /srv/nfs/phx_prod_backups/` to peek in as root instead — **`sudo cd ...` does not
work**, since `cd` is a shell builtin, not a program `sudo` can execute.

**Directory existing is not the same as it being mountable — this is the step most likely
to be missed.** A folder only becomes reachable over NFS once it's an actual export;
until then, any client `mount` attempt fails with `No such file or directory` even though
the directory is sitting right there on disk. Register and activate the export:
```bash
# On NFS-01 only
echo '/srv/nfs/phx_prod_backups  10.200.50.0/24(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
sudo exportfs -rav
sudo exportfs -v              # confirm phx_prod_backups now appears in the list
showmount -e localhost        # double-check
```

```bash
sudo apt install -y nfs-common
sudo mkdir -p /mnt/etcd-backups
sudo mount -t nfs4 -o vers=4.2,hard,timeo=600 10.200.50.138:/srv/nfs/phx_prod_backups /mnt/etcd-backups
```
Persist it in `/etc/fstab` so it survives a reboot (the backup timer needs the mount to
already exist when it fires):
```
10.200.50.138:/srv/nfs/phx_prod_backups /mnt/etcd-backups nfs4 defaults,vers=4.2,hard,timeo=600 0 0
```

**Verify the mount actually reaches NFS-01 — don't trust a local file test.** If the mount
was ever attempted while the export above wasn't live yet, `/mnt/etcd-backups` may have
been used as a plain local directory in the meantime; a file written there before the
mount succeeds sits on the master's own disk, not on NFS-01, and proves nothing. Confirm
from **both ends**:
```bash
# On the master, after mount succeeds
sudo touch /mnt/etcd-backups/realtest
# On NFS-01 — this is the actual proof it worked
ls -la /srv/nfs/phx_prod_backups/   # should show "realtest"
```
Then in `etcd-backup.sh`:
```bash
timeout 60 cp "${SNAPSHOT_FILE}" /mnt/etcd-backups/ || logger -t "${LOGTAG}" "WARN: off-node NFS copy failed or timed out"
```
The network transfer still happens — NFS handles it transparently underneath the mount.
`timeout 60` is deliberate, not decorative: the mount option above uses `hard`, which
retries indefinitely rather than failing fast if NFS-01 is ever unreachable — without
this wrapper, a plain `cp` could hang the whole backup script for a long time instead of
failing loudly. The local snapshot itself (already saved and verified earlier in the
script) is unaffected either way — this only guards the off-node copy step.

### OFF_NODE_COPY option 2 — `rsync` over SSH, key-based auth

Only if the destination is a genuinely separate host outside any NFS export (e.g.
offsite). Requires a dedicated user + SSH key pair per master, set up in advance:
```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
sudo ssh-copy-id backup-user@backup-host
sudo ssh backup-user@backup-host "echo ok"   # confirm it logs in with no password prompt
```
Then in `etcd-backup.sh`:
```bash
rsync -az "${SNAPSHOT_FILE}" backup-user@backup-host:/srv/etcd-backups/
```

### OFF_NODE_COPY option 3 — `rsync` over SSH, password auth (`sshpass`)

If only password-based SSH access is available (no key auth possible), the backup runs
unattended via `systemd`/cron with no terminal to type a password into — `sshpass`
supplies it non-interactively instead:
```bash
sudo apt install -y sshpass
sudo bash -c 'echo "the-password" > /root/.backup-pass'
sudo chmod 600 /root/.backup-pass
sudo chown root:root /root/.backup-pass
```
Then in `etcd-backup.sh`:
```bash
sshpass -f /root/.backup-pass rsync -az "${SNAPSHOT_FILE}" backup-user@backup-host:/srv/etcd-backups/
```
**Security tradeoff worth knowing:** this leaves a plaintext password on disk on every
master — anyone who compromises root on a master also gets into the backup host. Key
auth (option 2) doesn't have that exposure. Use option 3 only if key auth genuinely
isn't available, and lock the password file down to `600`/`root:root` as shown.
Never pass the password inline as `sshpass -p '...'` — that's visible to anyone on the
box via `ps` while the command runs.

## Why 7 days, and why `find -mtime` instead of `logrotate`

etcd snapshots are binary data files consumed by `etcdctl snapshot restore`, not
line-oriented text logs — `logrotate` (compress/rotate/postrotate-signal-the-writer) is
built for the latter and doesn't apply here. Pruning by `find ... -mtime +7 -delete` is
the standard pattern for this kind of dated-artifact retention instead.

7 days is a reasonable default balance between disk usage and having enough history to
recover from a problem that wasn't noticed immediately. Adjust `RETENTION_DAYS` in the
script if your recovery-point objective is different — e.g. `14` or `30` if you have
disk headroom and want a longer window, especially at the off-node copy destination
(the local copy can stay shorter-lived than the off-node archive).

## Verify it's actually working

```bash
# Timer is scheduled and was hit persistent-safe
systemctl list-timers | grep etcd-backup

# Run it once by hand, watch it end-to-end (don't wait for 01:00)
sudo systemctl start etcd-backup.service
journalctl -u etcd-backup.service -n 50 --no-pager

# Confirm files exist and are non-trivial size
ls -lh /var/backups/etcd/

# Confirm a snapshot is actually valid (this is what the script itself checks
# automatically, but useful to re-verify manually):
ETCDCTL_API=3 etcdctl --write-out=table snapshot status \
  /var/backups/etcd/etcd-snapshot-<latest-timestamp>.db
```

## Test the restore path BEFORE you need it for real

An untested backup is not a backup. In a lab/staging environment (never against a
production master directly):

```bash
ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd/etcd-snapshot-<ts>.db \
  --name master1-test \
  --initial-cluster master1-test=https://127.0.0.1:2380 \
  --initial-cluster-token etcd-restore-test \
  --initial-advertise-peer-urls https://127.0.0.1:2380 \
  --data-dir /tmp/etcd-restore-test
```

If that completes without error, the snapshot is restorable. For the full real-cluster
restore procedure (replacing a dead master's etcd, or rebuilding after all masters are
lost, without disrupting worker-node applications), see **§6.3 "All Masters Down"** in
`../multi_master_ha_setup.md` — this backup is the input to that procedure, not a
replacement for it.

## Cron alternative (if you're not using systemd timers)

```cron
# /etc/cron.d/etcd-backup
0 1 * * * root /usr/local/sbin/etcd-backup.sh
```

`logger` calls inside the script go to syslog either way, so you don't need to redirect
cron's output to a separate log file — that would just duplicate what's already in
syslog/journal.
