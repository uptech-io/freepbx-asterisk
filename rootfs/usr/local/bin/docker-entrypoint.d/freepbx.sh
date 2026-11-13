# shellcheck shell=bash

function freepbx_install() {
    local instance_directory="${1:?instance_directory required}"
    local line installed=1

    # Left by an install that died in this same container: with them ./install would skip the modules.
    [[ -L /etc/freepbx.conf ]] || rm -f /etc/freepbx.conf /etc/amportal.conf

    cd /usr/src/freepbx

    # ./install exits 1 even on success: only its last line tells.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        printf '%s\n' "${line}"
        [[ "${line}" == *'You have successfully installed FreePBX'* ]] && installed=0
    done < <(./install --no-interaction \
        --dbname="${DBNAME-asterisk}" \
        --dbuser="${DBUSER-dev}" \
        --dbpass="${DBPASSWORD:?DBPASSWORD is required to install}" \
        --dbhost="${DBHOST-db}" \
        --webroot="${instance_directory}/web" \
        --ampbin="${instance_directory}/asterisk/var/lib/asterisk/bin" \
        --ampplayback="${instance_directory}/asterisk/var/lib/asterisk/playback" 2>&1)
    (( installed == 0 )) || return 1

    if [[ ! -L "/etc/freepbx.conf" ]]; then
        # The next boots read both files from the volume: without them the install does not count.
        cp /etc/amportal.conf /etc/freepbx.conf "${instance_directory}/asterisk/etc/" || return 1
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

# Makes Asterisk log failed logins to the file the fail2ban jail reads.
function ensure_fail2ban_channel() {
    local etc="${1:?instance_directory required}/asterisk/etc/asterisk"
    local custom="${etc}/logger_logfiles_custom.conf"
    local f2b_log="${1}/asterisk/var/log/asterisk/fail2ban"
    local size

    # A commercial module may declare the channel itself; two entries would log each failure twice.
    if ! grep -qsE '^[[:space:]]*fail2ban[[:space:]]*=' "${etc}/logger_logfiles_additional.conf" "${custom}"; then
        log "Adding the fail2ban log channel to Asterisk..."
        printf '\nfail2ban => warning,security\n' >> "${custom}"
        chown asterisk:asterisk "${custom}"
    fi

    # "logger reload" writes a header line to every log file Asterisk has open: no growth, no channel.
    size="$(stat -c %s "${f2b_log}" 2>/dev/null || echo 0)"
    asterisk -rx 'logger reload' > /dev/null 2>&1

    if (( $(stat -c %s "${f2b_log}" 2>/dev/null || echo 0) <= size )); then
        log "Warning: Asterisk is not writing to the fail2ban log; the jail cannot ban."
    fi
}
