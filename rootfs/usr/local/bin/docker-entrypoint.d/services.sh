# shellcheck shell=bash

# Creates the D-Bus machine-id (also read by FreePBX) and the fail2ban jail log file; turns cron mail off.
function prepare_services() {
    log "Preparing services..."
    dbus-uuidgen --ensure

    # fail2ban does not start without the jail log file (older volumes lack it).
    local f2b_log=/usr/local/asterisk/var/log/asterisk/fail2ban
    [[ -e "${f2b_log}" ]] || install -o asterisk -g asterisk -m 0640 /dev/null "${f2b_log}"

    # Cron mails job output as "From: root (Cron Daemon)"; the SMTP relay rejects it on every run.
    local f table mailto='^[[:space:]]*MAILTO[[:space:]]*='
    for f in /etc/crontab /etc/cron.d/*; do
        [[ -f "${f}" ]] && sed -i --follow-symlinks -e '1i MAILTO=""' -e "/${mailto}/d" "${f}"
    done
    # Read the table before rewriting it: FreePBX keeps its own lines there.
    table="$(crontab -u asterisk -l 2> /dev/null | grep -Ev "${mailto}")"
    printf '%s\n' 'MAILTO=""' ${table:+"${table}"} | crontab -u asterisk -
}

# Waits until Asterisk is fully booted. Returns 1 on timeout (default: 60s).
# Loops in the shell: "timeout" would run outside the bootstrap process group.
function wait_for_asterisk() {
    local timeout="${1:-60}"
    local deadline=$((SECONDS + timeout))

    log "Waiting for Asterisk to become fully booted (timeout: ${timeout} seconds)..."

    # -rx exits 0 whenever it connects, so check the output instead.
    until asterisk -rx 'core waitfullybooted' 2>/dev/null | grep -q 'fully booted'; do
        if (( SECONDS >= deadline )); then
            log "Error: Asterisk is not fully booted after ${timeout} seconds timeout."
            return 1
        fi
        sleep 1
    done

    log "Asterisk is now fully booted..."
}

# Starts Apache through supervisord (it is not autostarted).
function start_apache() {
    log "Starting Apache through supervisord..."
    supervisorctl -c "${SUPERVISOR_CONF}" start apache2
}
