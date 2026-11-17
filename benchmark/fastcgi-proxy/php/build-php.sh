#!/bin/bash
# build PHP 8.5.12 twice from the php-src git tag:
# - NTS + php-fpm into /opt/php85 (for nginx and the mORMot proxy)
# - ZTS + embed into /opt/php85zts (for FrankenPHP)
# apt: build-essential autoconf bison re2c pkg-config libxml2-dev libsqlite3-dev zlib1g-dev
#      libssl-dev libonig-dev libcurl4-openssl-dev libzip-dev
set -e
W=${1:-$PWD/php-build}; mkdir -p "$W"; cd "$W"
[ -d php-src ] || git clone -q --depth 1 --branch php-8.5.12 https://github.com/php/php-src php-src
COMMON="--disable-cgi --disable-phpdbg --without-pear --with-zlib --with-openssl --enable-mbstring --enable-pcntl --with-curl --with-zip"
rm -rf php-zts && cp -r php-src php-zts
(cd php-src && ./buildconf --force && ./configure --prefix=/opt/php85 --enable-fpm $COMMON && make -j"$(nproc)" && make install)
(cd php-zts && ./buildconf --force && ./configure --prefix=/opt/php85zts --enable-zts --enable-embed --disable-zend-signals $COMMON && make -j"$(nproc)" && make install)
/opt/php85/sbin/php-fpm -v | head -1
