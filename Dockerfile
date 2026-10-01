# The PHP image of the Maho Cloud servers: FrankenPHP on Debian 13, the PHP
# extensions Maho needs, Node and the Chromium libraries for the accessibility
# scanner of Maho 26.9+, Composer, and the tools a customer SSH shell and the
# SFTP service use. It holds no application code: the checkout is bind-mounted
# at /app on the server.
#
# One image per PHP version and database engine. The targets mysql, pgsql and
# sqlite share every layer except the last one, so CI compiles the shared
# extensions once, and the registry stores them once. The maho-cloud control
# plane writes `FROM ghcr.io/mahocommerce/mahocloud-php:<php>-<engine>` into
# the default Dockerfile of each website (MahoDefaultConfig::dockerfile()).

ARG PHP_VERSION=8.5

# The workflow passes the base pinned by digest, so the published image records
# exactly the base it was built from. A local `docker build` uses the tag.
ARG BASE_IMAGE=dunglas/frankenphp:1-php${PHP_VERSION}-trixie

FROM node:24-trixie-slim AS node

FROM ${BASE_IMAGE} AS common

# Part of the cache key of every RUN below. The workflow passes the ISO week
# (2026-W40), so `apt-get upgrade` and the PECL extensions are built again once
# a week. Within the week a build is a cache hit of the published image, which
# reuses its layers byte for byte, so a server that deploys after a rebuild
# downloads nothing new. A rebuild without the cache writes different layers
# for the same content (file times, apt logs), and every server would download
# them again.
ARG REFRESH=local

LABEL org.opencontainers.image.source="https://github.com/MahoCommerce/mahocloud-docker-images" \
      org.opencontainers.image.description="PHP image of the Maho Cloud servers"

RUN groupadd -g 1000 maho && useradd -u 1000 -g 1000 -m maho \
 && mkdir -p /data/caddy /config/caddy && chown -R 1000:1000 /data /config

# Every extension except the database driver, which the engine stages add. The
# default Dockerfile of a website installed `redis` whatever the Redis toggle
# said, and this image keeps that: a deploy that turns Redis off must not build
# an image without the extension while local.xml still names Redis.
RUN install-php-extensions gd intl zip opcache ctype curl dom fileinfo filter \
    ftp hash iconv json libxml mbstring openssl redis session simplexml soap \
    spl zlib ffi vips

# The tools, Node and the Chromium libraries, in one layer that ends with the
# apt lists removed.
#
# - `apt-get upgrade` is the reason for the scheduled rebuild: it brings the
#   Debian security updates that the base image does not have yet.
# - openssh-server carries sftp-server (the customer SSH gate and the sftp
#   service) and sshd (the sftp service). Its postinst writes SSH host keys.
#   This image is public and runs on every server, so those private keys are
#   deleted. The sftp service generates its own keys on a volume at start.
# - Node and npm are copied out of the official Node image. The Chromium list
#   is the chromium list of Playwright's nativeDeps.ts for debian13, identical
#   on amd64 and arm64, plus two font packages. libgbm1 depends on
#   mesa-libgallium, which pulls in LLVM (about 180 MB) that headless Chromium
#   never loads, so an empty package with that name and the candidate version
#   stands in for it. The same recipe is in MahoCommerce/docker-images.
RUN --mount=type=bind,from=node,source=/,target=/mnt/node set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y git patch unzip nano vim-tiny openssh-server rsync; \
    rm -f /etc/ssh/ssh_host_*; \
    mkdir -p /usr/local/lib/node_modules; \
    cp -a /mnt/node/usr/local/bin/node /usr/local/bin/node; \
    cp -a /mnt/node/usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm; \
    cp -a /mnt/node/usr/local/bin/npm /mnt/node/usr/local/bin/npx /usr/local/bin/; \
    node --version; npm --version; \
    ver=$(apt-cache show libgbm1 | awk '/^Version:/ { print $2; exit }'); \
    mkdir -p /tmp/stub/DEBIAN; \
    printf 'Package: mesa-libgallium\nVersion: %s\nArchitecture: all\nMaintainer: Maho <https://mahocommerce.com>\nDescription: empty stand-in for mesa-libgallium\n Installed so that libgbm1, which headless Chromium links, does not pull in\n the Mesa software renderer and LLVM. Remove this package before installing\n anything that renders with Mesa.\n' "$ver" > /tmp/stub/DEBIAN/control; \
    dpkg-deb -b /tmp/stub /tmp/mesa-libgallium-stub.deb; \
    apt-get install -y --no-install-recommends /tmp/mesa-libgallium-stub.deb \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 \
        libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 \
        libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 \
        libxfixes3 libxkbcommon0 libxrandr2 fonts-liberation fonts-noto-color-emoji; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/*

ENV EDITOR=nano

COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

# One stage per engine, the last layer of the image. MariaDB websites use the
# mysql image: the same PHP driver and the same Debian client package.
FROM common AS mysql
RUN set -eux; \
    install-php-extensions pdo_mysql; \
    apt-get update; \
    apt-get install -y default-mysql-client; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

FROM common AS pgsql
RUN set -eux; \
    install-php-extensions pdo_pgsql; \
    apt-get update; \
    apt-get install -y postgresql-client; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

FROM common AS sqlite
RUN set -eux; \
    install-php-extensions pdo_sqlite; \
    apt-get update; \
    apt-get install -y sqlite3; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*
