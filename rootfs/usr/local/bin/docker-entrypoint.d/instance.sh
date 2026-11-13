# shellcheck shell=bash

function prepare_instance() {
    local instance_directory="${1:?instance_directory required}"
    local tables

    rm -rf /var/www/html

    if [[ -f "${instance_directory}/asterisk/etc/asterisk/asterisk.conf" ]]; then
        log "Previous installation detected on ${instance_directory}"

        rm -rf /usr/local/asterisk
        return 0
    fi

    log "No installation detected. Starting installation mode..."

    if [[ -d "${instance_directory}/asterisk" ]] && ! rmdir "${instance_directory}/asterisk" 2> /dev/null; then
        log "Error: ${instance_directory}/asterisk has files but no etc/asterisk/asterisk.conf; move it away to install."
        exit 1
    fi

    # An empty volume over a database in use is the wrong volume: installing would overwrite the PBX.
    tables="$(mysql -h "${DBHOST-db}" -u root -p"${DBROOT_PASSWORD-root}" -N \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${DBNAME-asterisk}'")" || {
        log "Error: could not query the database as root (see the mysql error above)."
        exit 1
    }
    if [[ "${tables}" != 0 ]]; then
        log "Error: ${instance_directory} has no installation, but database ${DBNAME-asterisk} has tables; refusing to install over it."
        exit 1
    fi

    mkdir -p "${instance_directory}"/web
    mkdir -p "${instance_directory}"/fail2ban
    mkdir -p "${instance_directory}"/entrypoint-hooks.d/{nftables.d,scripts.d}

    # Marker first, then a copy that only shows up when complete: a boot killed here must not look installed.
    rm -f "${INSTALL_PENDING_FLAG}"
    touch "${INSTALL_PENDING_FLAG}"
    rm -rf "${instance_directory}/asterisk.new"

    cp -a /usr/local/asterisk "${instance_directory}/asterisk.new" \
        && mv -T "${instance_directory}/asterisk.new" "${instance_directory}/asterisk" || exit 1

    rm -rf /usr/local/asterisk
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
    chown root:root "${instance_directory}"
    chown -R asterisk:asterisk "${instance_directory}/asterisk" "${instance_directory}/web"
}
