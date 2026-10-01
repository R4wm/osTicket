FROM php:8.4-apache-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libzip-dev \
        unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        gettext \
        intl \
        mysqli \
        opcache \
        zip \
    && pecl install apcu \
    && docker-php-ext-enable apcu \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

COPY docker/apache-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY docker/entrypoint.sh /usr/local/bin/osticket-entrypoint.sh
RUN chmod +x /usr/local/bin/osticket-entrypoint.sh

WORKDIR /var/www/html

ENTRYPOINT ["/usr/local/bin/osticket-entrypoint.sh"]
CMD ["apache2-foreground"]
