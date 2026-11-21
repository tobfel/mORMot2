#!/bin/bash
# build PHP twice from the php-src git tag (PHP_VERSION, default 8.5.12):
# - NTS + php-fpm into /opt/phpXY (for nginx and the mORMot proxy), e.g. /opt/php85
# - ZTS + embed into /opt/phpXYzts (for FrankenPHP), e.g. /opt/php85zts
# apt: build-essential autoconf bison re2c pkg-config libxml2-dev libsqlite3-dev zlib1g-dev
#      libssl-dev libonig-dev libcurl4-openssl-dev libzip-dev
set -e
V=${PHP_VERSION:-8.5.12}; X=$(echo "$V" | cut -d. -f1-2 | tr -d .)   # e.g. 85
W=${1:-$PWD/php-build-$V}; mkdir -p "$W"; cd "$W"
[ -d php-src ] || git clone -q --depth 1 --branch "php-$V" https://github.com/php/php-src php-src
COMMON="--disable-cgi --disable-phpdbg --without-pear --with-zlib --with-openssl --enable-mbstring --enable-pcntl --with-curl --with-zip"
rm -rf php-zts && cp -r php-src php-zts
(cd php-src && ./buildconf --force && ./configure --prefix=/opt/php$X --enable-fpm $COMMON && make -j"$(nproc)" && make install)
(cd php-zts && ./buildconf --force && ./configure --prefix=/opt/php${X}zts --enable-zts --enable-embed --disable-zend-signals $COMMON && make -j"$(nproc)" && make install)
/opt/php$X/sbin/php-fpm -v | head -1
