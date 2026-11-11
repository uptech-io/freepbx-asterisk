# shellcheck shell=bash

function freepbx_install() {
    local instance_directory="${1:?instance_directory required}"

    log "Creating asteriskcdrdb database if it does not exist..."
    mysql -h "${DBHOST-db}" -u root -p"${DBROOT_PASSWORD-root}" \
    -e "CREATE DATABASE IF NOT EXISTS asteriskcdrdb;
        GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO '${DBUSER-dev}'@'%' IDENTIFIED BY '${DBPASSWORD-1234567890}';
        FLUSH PRIVILEGES;"

    cd /usr/src/freepbx

    ./install --no-interaction \
        --dbname="${DBNAME-asterisk}" \
        --cdrdbname="${DBCDR-asteriskcdrdb}" \
        --dbuser="${DBUSER-dev}" \
        --dbpass="${DBPASSWORD-1234567890}" \
        --dbhost="${DBHOST-db}" \
        --webroot="${instance_directory}/web" \
        --astetcdir="${instance_directory}/asterisk/etc/asterisk" \
        --astmoddir="${instance_directory}/asterisk/usr/lib64/asterisk/modules" \
        --astvarlibdir="${instance_directory}/asterisk/var/lib/asterisk" \
        --astagidir="${instance_directory}/asterisk/var/lib/asterisk/agi-bin" \
        --astspooldir="${instance_directory}/asterisk/var/spool/asterisk" \
        --astrundir="${instance_directory}/asterisk/var/run/asterisk" \
        --astlogdir="${instance_directory}/asterisk/var/log/asterisk" \
        --ampbin="${instance_directory}/asterisk/var/lib/asterisk/bin" \
        --ampplayback="${instance_directory}/asterisk/var/lib/asterisk/playback"

    if [[ ! -L "/etc/freepbx.conf" ]]; then
        cp /etc/freepbx.conf "${instance_directory}/asterisk/etc/" || true
        cp /etc/amportal.conf "${instance_directory}/asterisk/etc/" || true
        cp /usr/sbin/fwconsole "${instance_directory}/asterisk/sbin/" || true
    fi
}

function freepbx_post() {
    # Module upgrades may migrate the database: opt-in.
    if [[ "${FREEPBX_AUTO_UPGRADE:-0}" == 1 ]]; then
        log "Running FreePBX module upgrades..."
        fwconsole ma upgradeall
    else
        log "Skipping FreePBX module upgrades (set FREEPBX_AUTO_UPGRADE=1 to enable)."
    fi

    log "Reloading FreePBX configuration..."

    fwconsole reload
    fwconsole start -q
}
