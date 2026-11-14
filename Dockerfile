# syntax=docker/dockerfile:1
#
# Picstome - single-container self-hosted image.
#
# Upstream application: https://github.com/picstome/picstome (AGPL-3.0)
#
# The application hardcodes the "s3" filesystem disk for every photo and
# builds public object URLs from it, so a S3-compatible object store has to
# live inside the container. This image runs nginx, PHP-FPM, the Laravel queue
# worker, the scheduler and MinIO under supervisord.

ARG PHP_VERSION=8.4
ARG NODE_VERSION=22

# Upstream commit this image is built and tested against. Bump it deliberately
# and regenerate the patches in patches/ when you do.
ARG PICSTOME_REF=e1baba36883894e2cd65d86a2d69799d3bff8b16

###########################  source  ###########################
FROM alpine:latest AS source

ARG PICSTOME_REF

RUN apk add --no-cache curl tar patch

RUN set -eux; \
    curl -fsSL "https://codeload.github.com/picstome/picstome/tar.gz/${PICSTOME_REF}" -o /tmp/src.tar.gz; \
    mkdir -p /src; \
    tar -xzf /tmp/src.tar.gz -C /src --strip-components=1; \
    rm -f /tmp/src.tar.gz

COPY patches/ /tmp/patches/

# A failing patch must stop the build: the commit above is pinned, so a failure
# means the project changed shape and the image needs to be reviewed.
RUN set -eux; \
    cd /src; \
    for p in /tmp/patches/*.patch; do \
        echo "Applying ${p}"; \
        patch -p1 --batch --forward < "${p}"; \
    done

###########################  vendor  ###########################
FROM composer:2 AS vendor

WORKDIR /app
COPY --from=source /src/composer.json /src/composer.lock /app/

RUN composer install \
        --no-dev \
        --no-interaction \
        --prefer-dist \
        --no-scripts \
        --optimize-autoloader \
        --ignore-platform-reqs

###########################  assets  ###########################
FROM node:${NODE_VERSION}-bookworm-slim AS assets

# The upstream package.json lists playwright; its browser download is not
# needed to compile the Vite assets.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app
COPY --from=source /src /app

# resources/css/app.css imports the TallStackUI stylesheet straight out of
# vendor/, so the Composer tree has to exist before Vite runs.
COPY --from=vendor /app/vendor /app/vendor

RUN mkdir -p storage/framework/views \
    && npm ci --no-audit --no-fund \
    && npm run build

###########################  runtime  ###########################
FROM php:${PHP_VERSION}-fpm-bookworm

LABEL org.opencontainers.image.title="Picstome" \
      org.opencontainers.image.description="Self-hosted galleries, contracts and client management for photographers" \
      org.opencontainers.image.url="https://picstome.com" \
      org.opencontainers.image.source="https://github.com/picstome/picstome" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gettext-base \
        gifsicle \
        imagemagick \
        jpegoptim \
        libimage-exiftool-perl \
        nginx-light \
        optipng \
        patch \
        pngquant \
        supervisor \
        tzdata \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions \
        bcmath \
        exif \
        gd \
        imagick \
        intl \
        opcache \
        pcntl \
        pdo_mysql \
        pdo_sqlite \
        sockets \
        zip \
    && rm -f /usr/local/bin/install-php-extensions

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# MinIO withdrew the community binaries from dl.min.io (HTTP 410) and its
# Docker Hub images. These are the last releases that still publish assets on
# GitHub; they are unmaintained, so treat them as a pinned dependency.
ARG MINIO_RELEASE=RELEASE.2025-09-07T16-13-09Z
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z

ARG TARGETARCH
RUN set -eux; \
    arch="${TARGETARCH:-amd64}"; \
    minio_file="minio.linux-${arch}.${MINIO_RELEASE}"; \
    mc_file="mc.linux-${arch}.${MC_RELEASE}"; \
    curl -fsSL "https://github.com/minio/minio/releases/download/${MINIO_RELEASE}/${minio_file}" -o "/tmp/${minio_file}"; \
    curl -fsSL "https://github.com/minio/minio/releases/download/${MINIO_RELEASE}/${minio_file}.sha256sum" -o "/tmp/${minio_file}.sha256sum"; \
    curl -fsSL "https://github.com/minio/mc/releases/download/${MC_RELEASE}/${mc_file}" -o "/tmp/${mc_file}"; \
    curl -fsSL "https://github.com/minio/mc/releases/download/${MC_RELEASE}/${mc_file}.sha256sum" -o "/tmp/${mc_file}.sha256sum"; \
    echo "$(awk '{print $1}' "/tmp/${minio_file}.sha256sum")  /tmp/${minio_file}" | sha256sum -c -; \
    echo "$(awk '{print $1}' "/tmp/${mc_file}.sha256sum")  /tmp/${mc_file}" | sha256sum -c -; \
    install -m 0755 "/tmp/${minio_file}" /usr/local/bin/minio; \
    install -m 0755 "/tmp/${mc_file}" /usr/local/bin/mc; \
    rm -f /tmp/minio.linux-* /tmp/mc.linux-*

###########################  application  ###########################
WORKDIR /var/www/html

COPY --from=source /src /var/www/html
COPY --from=vendor /app/vendor /var/www/html/vendor
COPY --from=assets /app/public/build /var/www/html/public/build

RUN mkdir -p \
        storage/app/private \
        storage/app/public \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
        bootstrap/cache \
    && php artisan package:discover --ansi \
    && chown -R www-data:www-data storage bootstrap/cache

###########################  runtime config  ###########################
RUN rm -f /etc/nginx/sites-enabled/default

COPY docker/nginx.conf.template /etc/nginx/templates/picstome.conf.template
COPY docker/php-fpm-pool.conf /usr/local/etc/php-fpm.d/zz-picstome.conf
COPY docker/supervisord.conf /etc/supervisor/conf.d/picstome.conf
COPY docker/first-run.php /usr/local/share/picstome/first-run.php
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
COPY docker/minio-init.sh /usr/local/bin/minio-init

RUN chmod 0755 /usr/local/bin/entrypoint /usr/local/bin/minio-init

# /data holds the SQLite database, the MinIO bucket, application storage and
# the generated secrets, so one mapping backs up the whole install.
VOLUME ["/data"]

# 80   - web UI
# 9000 - S3 API. Browsers fetch gallery photos and presigned downloads from
#        this endpoint, so it has to stay reachable by clients.
EXPOSE 80 9000

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS http://127.0.0.1/up >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf", "-n"]
