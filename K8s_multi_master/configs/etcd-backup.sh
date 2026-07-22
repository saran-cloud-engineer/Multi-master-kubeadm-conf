#!/bin/bash
#-----------------------------------------------------------------------------
# /usr/local/sbin/etcd-backup.sh
#
# Takes a point-in-time etcd snapshot on THIS control-plane node and prunes
# local snapshots older than RETENTION_DAYS (7). Intended to run once daily
# via etcd-backup.timer (systemd) — see etcd-backup.service / etcd-backup.timer
# alongside this file. A cron alternative is documented in ../ETCD_BACKUP.md.
#
# Run this on EVERY control-plane node — all of them host an etcd member in
# a stacked-etcd kubeadm cluster, and a snapshot from any single healthy
# member is sufficient to restore the whole cluster (see
# multi_master_ha_setup.md §6.3). Backing up from every node just means you
# still have a usable snapshot even if the node you'd normally pull from is
# the one that's down.
#
# IMPORTANT: local rotation alone does NOT protect you if this entire node
# is lost (disk failure, terminated instance, etc.) — the OFF_NODE_COPY
# section below is where you wire in shipping snapshots elsewhere (another
# host, object storage, etc.). Do not skip that in production — see
# ../ETCD_BACKUP.md for why.
#-----------------------------------------------------------------------------

set -euo pipefail

BACKUP_DIR="/var/backups/etcd"
RETENTION_DAYS=7
TIMESTAMP="$(date +%F_%H-%M-%S)"
# Hostname included so snapshots from all 3 masters can share one destination
# (e.g. NFS-01) without colliding and without losing track of which master
# produced which file — matters once OFF_NODE_COPY lands all 3 in one folder.
SNAPSHOT_FILE="${BACKUP_DIR}/etcd-snapshot-$(hostname)-${TIMESTAMP}.db"
LOGTAG="etcd-backup"

export ETCDCTL_API=3
ENDPOINTS="https://127.0.0.1:2379"
CACERT="/etc/kubernetes/pki/etcd/ca.crt"
CERT="/etc/kubernetes/pki/etcd/server.crt"
KEY="/etc/kubernetes/pki/etcd/server.key"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

logger -t "${LOGTAG}" "Starting etcd snapshot -> ${SNAPSHOT_FILE}"

if ! etcdctl \
    --endpoints="${ENDPOINTS}" \
    --cacert="${CACERT}" \
    --cert="${CERT}" \
    --key="${KEY}" \
    snapshot save "${SNAPSHOT_FILE}"; then
    logger -t "${LOGTAG}" "FAIL: etcdctl snapshot save failed"
    exit 1
fi

# Verify the snapshot is structurally readable before trusting it — a
# truncated or corrupt snapshot must never silently sit there looking fine.
if ! STATUS_OUT=$(etcdctl --write-out=table snapshot status "${SNAPSHOT_FILE}" 2>&1); then
    logger -t "${LOGTAG}" "FAIL: snapshot status check failed for ${SNAPSHOT_FILE}: ${STATUS_OUT}"
    rm -f "${SNAPSHOT_FILE}"
    exit 1
fi
logger -t "${LOGTAG}" "Snapshot OK: ${SNAPSHOT_FILE} ($(du -h "${SNAPSHOT_FILE}" | cut -f1))"

#-----------------------------------------------------------------------------
# OFF_NODE_COPY: ship the snapshot off this node before it can be lost along
# with the node itself. Uncomment and adapt exactly ONE of these before
# relying on this in production, then set OFF_NODE_COPY_CONFIGURED=1 above
# so the warning below stops firing. Full setup steps (NFS mount prep, SSH key
# generation, sshpass install) for each option are in ../ETCD_BACKUP.md.
#
#   Option 1 (recommended if NFS-01 is the target) - NFS mount, plain copy,
#   no auth setup needed at all. "timeout 60" matters here: the mount uses
#   "hard", which retries forever rather than failing fast if NFS-01 is
#   unreachable - without it, a stalled mount could hang this whole script:
#   timeout 60 cp "${SNAPSHOT_FILE}" /mnt/etcd-backups/ || logger -t "${LOGTAG}" "WARN: off-node NFS copy failed or timed out"
#
#   Option 2 - rsync over SSH, key-based auth (separate host, e.g. offsite):
#   rsync -az "${SNAPSHOT_FILE}" backup-user@backup-host:/srv/etcd-backups/
#
#   Option 3 - rsync over SSH, password auth via sshpass (only if key auth
#   isn't available - see ../ETCD_BACKUP.md for the security tradeoff):
#   sshpass -f /root/.backup-pass rsync -az "${SNAPSHOT_FILE}" backup-user@backup-host:/srv/etcd-backups/
#
#   aws s3 cp "${SNAPSHOT_FILE}" s3://your-bucket/etcd-backups/ --sse AES256
#-----------------------------------------------------------------------------
if [ -z "${OFF_NODE_COPY_CONFIGURED:-}" ]; then
    logger -t "${LOGTAG}" "WARN: no off-node copy configured - backup only exists on this node's local disk"
fi

# 7-day local rotation: delete snapshots older than RETENTION_DAYS.
find "${BACKUP_DIR}" -maxdepth 1 -name 'etcd-snapshot-*.db' -type f -mtime +"${RETENTION_DAYS}" -print | \
while read -r old; do
    rm -f "${old}"
    logger -t "${LOGTAG}" "Pruned old snapshot: ${old}"
done

logger -t "${LOGTAG}" "Backup cycle complete."
exit 0
