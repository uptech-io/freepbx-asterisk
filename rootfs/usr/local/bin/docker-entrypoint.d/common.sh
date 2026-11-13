# shellcheck shell=bash

SUPERVISOR_CONF=/etc/supervisor/supervisord.conf
INSTANCE_DIR=/data
HOOKS_DIR="${INSTANCE_DIR}/entrypoint-hooks.d"
INSTALL_PENDING_FLAG="${INSTANCE_DIR}/.freepbx-install-pending"

function log() {
    echo "$(date +"%Y-%m-%d %T") $1"
}

function install_pending() {
    [[ -f "${INSTALL_PENDING_FLAG}" && "$(stat -c %u "${INSTALL_PENDING_FLAG}")" == 0 ]]
}

function ipvlan_iface() {
    ip -o link show type ipvlan | awk -F': ' '{print $2}' | cut -d'@' -f1 | head -n1
}
