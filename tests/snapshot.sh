#!/bin/bash
# Read-only picture of a running instance, to diff before/after a change.
# Use: CONTAINER=<name|id> DBHOST=... DBROOT_PASSWORD=... ./snapshot.sh > before.txt
C="${CONTAINER:?set CONTAINER}"
x() { docker exec "$C" "$@" 2>&1; }
echo "## image";            docker inspect -f '{{.Config.Image}} {{.Image}}' "$C"
echo "## supervisor";       x supervisorctl status asterisk apache2 dbus cron fail2ban | awk '{print $1, $2}'
echo "## asterisk";         x asterisk -V
echo "## binary (sha256)";  x sha256sum /usr/local/asterisk/sbin/asterisk
echo "## pjsip endpoints";  x asterisk -rx 'pjsip show endpoints' | grep -E '^ *Endpoint:' | sort
echo "## registrations";    x asterisk -rx 'pjsip show registrations' | grep -Ei 'registered|rejected|unregistered' | sort
echo "## transports";       x asterisk -rx 'pjsip show transports' | grep -E '^ *Transport:' | sort
echo "## loaded modules";   x asterisk -rx 'module show' | tail -1
echo "## odbc";             x asterisk -rx 'odbc show all' | grep -Ei 'name|active connections'
echo "## FreePBX modules";  x fwconsole ma list | grep -E '^\| ' | sort
echo "## fail2ban";         x fail2ban-client status asterisk
echo "## nft (rule count)"; x nft list ruleset | grep -c .
echo "## HTTP (loopback)";  x curl -s -o /dev/null -w 'admin=%{http_code}\n' http://127.0.0.1/admin/config.php
echo "## owners";           x stat -c '%U:%G %a %n' /data/entrypoint-hooks.d /data/asterisk/sbin/asterisk /data/asterisk/etc/asterisk/asterisk.conf /data/asterisk/etc/freepbx.conf
echo "## asterisk crontab"; x crontab -l -u asterisk
echo "## CDR count";        x mysql -h "${DBHOST:-db}" -u root -p"${DBROOT_PASSWORD:?set DBROOT_PASSWORD}" --skip-ssl -N -e 'SELECT COUNT(*) FROM asteriskcdrdb.cdr'
