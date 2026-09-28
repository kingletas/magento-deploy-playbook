# A web node: nginx, PHP-FPM 8.4 and sshd in one container, laid out the way
# bin/zdt-arm expects a real host to be.
FROM php:8.4-fpm

# The extension compile is the heavy part of the build; two jobs keep it from
# taking every core of a host that runs other work.
ARG BUILD_JOBS=2

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx openssh-server rsync mariadb-client \
        libfreetype-dev libjpeg62-turbo-dev libpng-dev libicu-dev \
        libxml2-dev libxslt1-dev libzip-dev libsodium-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j "$BUILD_JOBS" bcmath ftp gd intl opcache pdo_mysql soap sockets xsl zip \
    && rm -rf /var/lib/apt/lists/*

# Fail the build, not the install, if an extension Magento needs is missing.
RUN for ext in bcmath ctype curl dom ftp gd intl mbstring pdo_mysql SimpleXML soap sockets sodium xsl zip "Zend OPcache"; do \
        php -m | grep -qx "$ext" || { echo "missing PHP extension: $ext" >&2; exit 1; }; \
    done

# current is left for the deploy to create as a symlink: a directory in its
# place would make ln -sfn put the link inside it.
RUN useradd -m -s /bin/bash deploy \
    && mkdir -p /var/www/magento/releases /var/www/magento/shared/app/etc \
        /var/www/magento/shared/pub/media /var/www/magento/zdt-snapshots \
        /home/deploy/.ssh /run/sshd /releases \
    && chown -R deploy:deploy /var/www/magento /home/deploy/.ssh /releases \
    && chmod 700 /home/deploy/.ssh \
    && printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' 'AllowUsers deploy' > /etc/ssh/sshd_config.d/zdtfleet.conf \
    && rm -f /etc/nginx/sites-enabled/default

COPY nginx.conf /etc/nginx/conf.d/magento.conf
COPY php.ini /usr/local/etc/php/conf.d/99-zdtfleet.ini
COPY fpm-pool.conf /usr/local/etc/php-fpm.d/zz-zdtfleet.conf
COPY entrypoint.sh /usr/local/bin/zdtfleet-entrypoint
RUN chmod 755 /usr/local/bin/zdtfleet-entrypoint && nginx -t

EXPOSE 22 80
ENTRYPOINT ["/usr/local/bin/zdtfleet-entrypoint"]
