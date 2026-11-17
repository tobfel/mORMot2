#!/bin/bash
# build FrankenPHP v1.13.5 against /opt/php85zts (PHP 8.5.12 ZTS) into php/bin/frankenphp
# needs Go (GOTOOLCHAIN=auto fetches the version required by go.mod)
set -e
D=$(cd "$(dirname "$0")" && pwd); W=${1:-$PWD/frankenphp-build}; mkdir -p "$W" "$D/bin"
[ -d "$W/frankenphp" ] || git clone -q --depth 1 --branch v1.13.5 https://github.com/php/frankenphp "$W/frankenphp"
P=/opt/php85zts/bin/php-config
cd "$W/frankenphp/caddy/frankenphp"
GOTOOLCHAIN=auto CGO_ENABLED=1 CGO_CFLAGS="$($P --includes)" \
CGO_LDFLAGS="-L/opt/php85zts/lib $($P --ldflags) $($P --libs) -Wl,-rpath,/opt/php85zts/lib" \
  go build -tags=nobadger,nomysql,nopgx,nowatcher -o "$D/bin/frankenphp" .
"$D/bin/frankenphp" version
