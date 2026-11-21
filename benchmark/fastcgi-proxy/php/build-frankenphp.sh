#!/bin/bash
# build FrankenPHP against a ZTS + embed PHP into php/bin/frankenphp<suffix>
# - FRANKENPHP_VERSION (default v1.13.5), PHP_ZTS (default /opt/php85zts), SUFFIX (default empty)
# needs Go (GOTOOLCHAIN=auto fetches the version required by go.mod)
set -e
D=$(cd "$(dirname "$0")" && pwd); W=${1:-$PWD/frankenphp-build}; mkdir -p "$W" "$D/bin"
FV=${FRANKENPHP_VERSION:-v1.13.5}; Z=${PHP_ZTS:-/opt/php85zts}
[ -d "$W/frankenphp-$FV" ] || git clone -q --depth 1 --branch "$FV" https://github.com/php/frankenphp "$W/frankenphp-$FV"
P=$Z/bin/php-config
cd "$W/frankenphp-$FV/caddy/frankenphp"
GOTOOLCHAIN=auto CGO_ENABLED=1 CGO_CFLAGS="$($P --includes)" \
CGO_LDFLAGS="-L$Z/lib $($P --ldflags) $($P --libs) -Wl,-rpath,$Z/lib" \
  go build -tags=nobadger,nomysql,nopgx,nowatcher -o "$D/bin/frankenphp$SUFFIX" .
"$D/bin/frankenphp$SUFFIX" version
