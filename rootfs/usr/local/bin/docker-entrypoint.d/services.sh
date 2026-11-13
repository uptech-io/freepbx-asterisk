# shellcheck shell=bash

function prepare_services() {
    log "Preparing services..."
    dbus-uuidgen --ensure

    # fail2ban does not start without the jail log file, which the image does not ship.
    local f2b_log=/usr/local/asterisk/var/log/asterisk/fail2ban
    [[ -e "${f2b_log}" ]] || install -o asterisk -g asterisk -m 0640 /dev/null "${f2b_log}"

    # /etc/fail2ban/jail.d links here: per-instance jail settings kept in the volume.
    mkdir -p /data/fail2ban/jail.d

    # /var/spool/cron/crontabs links here: a new container keeps the jobs FreePBX scheduled.
    install -d -o root -g crontab -m 1730 /data/cron/crontabs

    # Cron mails job output as "From: root (Cron Daemon)"; the SMTP relay rejects it on every run.
    local f table mailto='^[[:space:]]*MAILTO[[:space:]]*='
    for f in /etc/crontab /etc/cron.d/*; do
        [[ -f "${f}" ]] && sed -i --follow-symlinks -e '1i MAILTO=""' -e "/${mailto}/d" "${f}"
    done
    # Read the table before rewriting it: FreePBX keeps its own lines there.
    table="$(crontab -u asterisk -l 2> /dev/null | grep -Ev "${mailto}")"
    printf '%s\n' 'MAILTO=""' ${table:+"${table}"} | crontab -u asterisk -
}

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

function start_apache() {
    log "Starting Apache through supervisord..."
    supervisorctl -c "${SUPERVISOR_CONF}" start apache2
}
