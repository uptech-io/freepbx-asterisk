# shellcheck shell=bash

function prepare_instance() {
    local instance_directory="${1:?instance_directory required}"

    rm -rf /var/www/html

    if [[ -f "${instance_directory}/asterisk/etc/asterisk/asterisk.conf" ]]; then
        log "Previous installation detected on ${instance_directory}"
        rm -rf /usr/local/asterisk

        return 1
    else
        log "No installation detected. Starting installation mode..."

        mkdir -p "${instance_directory}"/asterisk
        mkdir -p "${instance_directory}"/web
        mkdir -p "${instance_directory}"/fail2ban
        mkdir -p "${instance_directory}"/entrypoint-hooks.d/{nftables.d,scripts.d}

        mv /usr/local/asterisk "${instance_directory}/"
    fi

    return 0
}

function restore_symlinks() {
    local instance_directory="${1:?instance_directory required}"

    log "Verifying and restoring symlinks..."

    ln -sfn "${instance_directory}/asterisk" /usr/local/asterisk
    ln -sfn "${instance_directory}/asterisk/etc/asterisk" /etc/asterisk
    ln -sfn "${instance_directory}/asterisk/var/spool/asterisk" /var/spool/asterisk
    ln -sfn "${instance_directory}"/asterisk/sbin/* /usr/sbin/ || true

    ln -sfn /usr/local/bin/safe_asterisk /usr/sbin/safe_asterisk

    ln -sfn "${instance_directory}/web" /var/www/html

    if [[ -f "${instance_directory}/asterisk/etc/freepbx.conf" ]]; then
        ln -sfn "${instance_directory}/asterisk/etc/freepbx.conf" /etc/freepbx.conf
        ln -sfn "${instance_directory}/asterisk/etc/amportal.conf" /etc/amportal.conf
    fi
}

function fix_permissions() {
    local instance_directory="${1:?instance_directory required}"

    log "Fixing permissions..."
    chown -R asterisk:asterisk "${instance_directory}"
}
