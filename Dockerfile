FROM php:8.2-apache

ARG ASTVERSION=22
ARG IONCUBE_ARCH="x86-64"
ARG TZ=America/Recife

LABEL br.com.uptech.image.name="@uptech-io/freepbx-asterisk"
LABEL br.com.uptech.image.vendor="UPTECH"

ENV DEBIAN_FRONTEND=noninteractive \
    AST_PREFIX=/usr/local/asterisk \
    APACHE_RUN_USER=asterisk \
    APACHE_RUN_GROUP=asterisk

RUN --mount=type=cache,id=freepbx,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=freepbx,target=/var/lib/apt,sharing=locked \
    apt update && \
    apt upgrade -y && \
    apt install -y --no-install-recommends --no-install-suggests \
    tzdata \
    nftables \
    iproute2 \
    fail2ban \
    git \
    ffmpeg \
    curl \
    dbus \
    nodejs \
    npm \
    unixodbc \
    sox \
    cron \
    wget \
    build-essential \
    doxygen \
    zip \
    unzip \
    libcurl4-openssl-dev \
    mariadb-client \
    bison \
    flex \
    subversion \
    libssl-dev \
    libxml2-dev \
    libnewt-dev \
    libncurses5-dev \
    libsqlite3-dev \
    libjansson-dev \
    libxml2-dev \
    libicu-dev \
    libzip-dev \
    uuid-dev \
    default-libmysqlclient-dev \
    sngrep \
    lame \
    mpg123 \
    odbc-mariadb \
    openssh-client \
    ssmtp

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    sed -ri 's/^upload_max_filesize.*/upload_max_filesize = 64M/; s/^memory_limit.*/memory_limit = 512M/' "$PHP_INI_DIR/php.ini" && \
    docker-php-ext-install -j$(nproc) \
    mysqli \
    pdo \
    pdo_mysql \
    xml \
    intl  \
    gettext \
    gd \
    curl \
    sysvsem \
    zip

WORKDIR /tmp

RUN wget -q "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${IONCUBE_ARCH}.zip" -O ioncube.zip && \ 
    unzip ioncube.zip && \
    PHP_EXTENSION_DIR=$(php -r 'echo ini_get("extension_dir");') && \
    cp ioncube/ioncube_loader_lin_8.2.so "${PHP_EXTENSION_DIR}/" && \
    echo "zend_extension=${PHP_EXTENSION_DIR}/ioncube_loader_lin_8.2.so" > /usr/local/etc/php/conf.d/00-ioncube.ini

RUN --mount=type=cache,id=freepbx,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=freepbx,target=/var/lib/apt,sharing=locked \
    apt update && \
    wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz" -O asterisk.tar.gz && \
    wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.sha256" -O asterisk.sha256 && \
    echo "$(cut -d' ' -f1 asterisk.sha256)  asterisk.tar.gz" | sha256sum -c - && \
    tar xvf asterisk.tar.gz && \
    rm asterisk.tar.gz asterisk.sha256 && \
    cd asterisk*/ && \
    sed -i 's/"Asterisk"/"UPTECH"/g' res/res_pjsip/pjsip_configuration.c && \
    ./contrib/scripts/install_prereq install && \
    ./configure --prefix="$AST_PREFIX" --libdir="$AST_PREFIX/usr/lib64" --with-pjproject-bundled --with-jansson-bundled && \
    make menuselect.makeopts && \
    ./contrib/scripts/get_mp3_source.sh && \
    # BUILD_NATIVE (-march=native) would tie the binary to the build machine's CPU.
    menuselect/menuselect \
    --disable BUILD_NATIVE \
    --enable format_mp3 \
    --enable chan_mobile \
    --enable codec_ulaw \
    --enable codec_alaw \
    --enable MOH-OPSOUND-G729 \
    menuselect.makeopts && \
    make -j$(nproc) && \
    make install && \
    make samples && \
    make config

RUN wget -q https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest-EDGE.tgz -O freepbx.tgz && \
    tar zxf freepbx.tgz && \
    mv freepbx /usr/src/

RUN groupadd asterisk && \
    useradd  --home-dir "$AST_PREFIX/var/lib/asterisk" --gid asterisk asterisk && \
    sed -ri 's|^#?(AST_USER)=.*|\1=asterisk|; s|^#?(AST_GROUP)=.*|\1=asterisk|' /etc/default/asterisk && \
    sed -ri 's|^;?runuser *=.*|runuser = asterisk|; s|^;?rungroup *=.*|rungroup = asterisk|' "$AST_PREFIX/etc/asterisk/asterisk.conf"

RUN a2dismod status && \
    a2enmod rewrite headers expires remoteip && \
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone && \
    mkdir -p /var/run/asterisk && \
    mkdir -p /var/run/dbus && \
    chown asterisk:asterisk /var/run/asterisk && \
    chown messagebus:messagebus /var/run/dbus && \
    rm -rf /etc/fail2ban/jail.d && \
    ln -s /data/fail2ban/jail.d /etc/fail2ban/jail.d && \
    rm -rf /tmp/*

RUN --mount=type=cache,id=freepbx,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=freepbx,target=/var/lib/apt,sharing=locked \
    apt update && \
    apt install -y --no-install-recommends --no-install-suggests \
        supervisor \
        logrotate \
        psmisc \
    && \
    rm -f /etc/logrotate.d/apache2

WORKDIR /

COPY rootfs /

RUN chmod +x /usr/local/bin/* && \
    chmod 0644 /etc/logrotate.d/asterisk && \
    ln -sfn /usr/local/bin/php /usr/bin/php

HEALTHCHECK --interval=30s --timeout=5s --retries=5 --start-period=10s \
    CMD asterisk -rx 'core show uptime' >/dev/null 2>&1 || exit 1

# The base image sets STOPSIGNAL SIGWINCH, which supervisord ignores.
STOPSIGNAL SIGTERM

ENTRYPOINT ["docker-entrypoint"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
