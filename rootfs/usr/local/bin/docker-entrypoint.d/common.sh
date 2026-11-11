# shellcheck shell=bash

SUPERVISOR_CONF=/etc/supervisor/supervisord.conf
INSTALL_PENDING_FLAG=/data/.freepbx-install-pending

function log() {
    echo "$(date +"%Y-%m-%d %T") $1"
}

function ipvlan_iface() {
    ip -o link show type ipvlan | awk -F': ' '{print $2}' | cut -d'@' -f1 | head -n1
}
