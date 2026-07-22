#!/bin/bash
#-----------------------------------------------------------------------------
# /etc/keepalived/chk_haproxy.sh
#
# Health check invoked by keepalived's `chk_haproxy` vrrp_script.
# Exit 0 = healthy   (keep/regain priority)
# Exit 1 = unhealthy (lose `weight` priority -> VIP fails over via keepalived)
#
# Checks, in order (cheapest/fastest first):
#   1. haproxy process is running
#   2. haproxy is actually listening on the API port
#   3. at least one real kube-apiserver backend is UP, per HAProxy's own
#      admin socket (catches "HAProxy alive but all backends dead" case,
#      which a bare process/port check would miss)
#
# Requires: socat (apt install socat / yum install socat)
#-----------------------------------------------------------------------------

set -uo pipefail

HAPROXY_PORT=6443
STATS_SOCKET="/run/haproxy/admin.sock"
BACKEND_NAME="kube-masters"

# 1. Process check
if ! pgrep -x haproxy >/dev/null 2>&1; then
    logger -t chk_haproxy "FAIL: haproxy process not running"
    exit 1
fi

# 2. Port check
if ! ss -ltn "( sport = :${HAPROXY_PORT} )" 2>/dev/null | grep -q LISTEN; then
    logger -t chk_haproxy "FAIL: haproxy not listening on :${HAPROXY_PORT}"
    exit 1
fi

# 3. Backend health check via the HAProxy admin socket
if [ -S "${STATS_SOCKET}" ]; then
    UP_COUNT=$(echo "show stat" | socat stdio "${STATS_SOCKET}" 2>/dev/null \
        | awk -F',' -v be="${BACKEND_NAME}" \
            '$1==be && $2!="BACKEND" && $2!="FRONTEND" && $18=="UP" {c++} END{print c+0}')

    if [ -z "${UP_COUNT}" ] || [ "${UP_COUNT}" -lt 1 ]; then
        logger -t chk_haproxy "FAIL: no healthy backend servers in '${BACKEND_NAME}'"
        exit 1
    fi
else
    logger -t chk_haproxy "WARN: stats socket ${STATS_SOCKET} not found, skipping backend check"
fi

exit 0
