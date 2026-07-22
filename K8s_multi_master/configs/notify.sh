#!/bin/bash
#-----------------------------------------------------------------------------
# /etc/keepalived/notify.sh
#
# Generic VRRP state-transition hook, called by keepalived per the
# notify_master / notify_backup / notify_fault / notify_stop directives
# in keepalived.conf. Each directive passes a fixed first argument, the
# transition type. keepalived then appends the instance name, new
# state, and priority as additional arguments.
#
# Usage as configured in keepalived.conf:
#   notify_master "/etc/keepalived/notify.sh MASTER"
#   notify_backup "/etc/keepalived/notify.sh BACKUP"
#   notify_fault  "/etc/keepalived/notify.sh FAULT"
#   notify_stop   "/etc/keepalived/notify.sh STOP"
#-----------------------------------------------------------------------------

STATE="$1"
INSTANCE="${2:-VI_KUBE_API}"
LOGTAG="keepalived-notify"
VIP="<CP_VIP>"   # HIMS production VIP — see ../PRODUCTION-VALUES.md, not yet assigned

logger -t "${LOGTAG}" "VRRP instance ${INSTANCE} transitioned to ${STATE}"

case "${STATE}" in
    MASTER)
        logger -t "${LOGTAG}" "This node is now MASTER — owns VIP ${VIP}"
        # Optional hooks:
        # - Flush conntrack so stale connections don't linger with the old owner:
        #   conntrack -F >/dev/null 2>&1
        # - Notify external monitoring / chatops:
        #   curl -s -X POST -H 'Content-Type: application/json' \
        #     -d "{\"text\":\"$(hostname) became MASTER for ${INSTANCE}\"}" \
        #     "${WEBHOOK_URL:-}" >/dev/null 2>&1 || true
        ;;
    BACKUP)
        logger -t "${LOGTAG}" "This node is now BACKUP"
        ;;
    FAULT)
        logger -t "${LOGTAG}" "WARNING: ${INSTANCE} entered FAULT state (chk_haproxy failing) on $(hostname)"
        ;;
    STOP)
        logger -t "${LOGTAG}" "keepalived stopping on $(hostname), releasing VIP"
        ;;
    *)
        logger -t "${LOGTAG}" "Unknown state '${STATE}' for ${INSTANCE}"
        ;;
esac

exit 0
