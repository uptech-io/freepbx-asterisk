# shellcheck shell=bash

function wait_for_db() {
    log "Waiting for db to become available (timeout: 60 seconds)..."

    if ! timeout 60 bash -c 'until mysql -h "${DBHOST-db}" -u root -p"${DBROOT_PASSWORD-root}" -e "SELECT 1" > /dev/null 2>&1; do sleep 2; done'; then
        log "Error: db is not available after 60 seconds timeout."
        exit 1
    fi

    log "db is now online..."
}

function prepare_database() {
    local charset='DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci'

    [[ -n "${DBPASSWORD:-}" ]] || { log "Error: DBPASSWORD is required to install."; exit 1; }
    [[ "${DBUSER-dev}" != root ]] || { log "Error: DBUSER cannot be root."; exit 1; }
    [[ "${DBNAME-asterisk}" =~ ^[A-Za-z0-9_]+$ ]] || { log "Error: DBNAME accepts only letters, digits and _."; exit 1; }

    log "Creating the databases and the application user if they do not exist..."
    mysql -h "${DBHOST-db}" -u root -p"${DBROOT_PASSWORD-root}" -e "
        CREATE DATABASE IF NOT EXISTS \`${DBNAME-asterisk}\` ${charset};
        CREATE DATABASE IF NOT EXISTS asteriskcdrdb ${charset};
        GRANT ALL PRIVILEGES ON \`${DBNAME-asterisk}\`.* TO '${DBUSER-dev}'@'%'
            IDENTIFIED BY '${DBPASSWORD}';
        GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO '${DBUSER-dev}'@'%';" || {
        log "Error: could not prepare the databases (see the mysql error above)."
        exit 1
    }
}
