# shellcheck shell=bash

# DBCDR is legacy: kept for volumes installed with it; new installs refuse another name (db.sh).
function write_odbc_ini() {
  cat <<EOF > /etc/odbc.ini
[MySQL-asteriskcdrdb]
driver=MariaDB Unicode
server=${DBHOST-db}
database=${DBCDR-asteriskcdrdb}
Port=3306
option=3
EOF
}
