#!/bin/bash
# create the Laravel benchmark app (no database, production mode)
# - LARAVEL_VERSION (default 12.*), LARAVEL_APP (default /srv/laravel/app), PHPX (default 85)
# - PHP 8.6 needs Laravel 13: LARAVEL_VERSION='13.*' LARAVEL_APP=/srv/laravel13/app PHPX=86
# needs composer and /opt/phpXY from php/build-php.sh (composer runs with that PHP)
set -e
D=$(cd "$(dirname "$0")" && pwd); export COMPOSER_ALLOW_SUPERUSER=1
A=${LARAVEL_APP:-/srv/laravel/app}; PHP=/opt/php${PHPX:-85}/bin/php; C="$PHP $(command -v composer)"
mkdir -p "$(dirname "$A")" && cd "$(dirname "$A")"
[ -d "$A" ] || $C create-project --no-interaction --no-scripts laravel/laravel "$(basename "$A")" "${LARAVEL_VERSION:-12.*}"
cd "$A" && $C require --no-interaction -W laravel/octane
cp -r "$D/app/." .
cp vendor/laravel/octane/src/Commands/stubs/frankenphp-worker.php public/
cp .env.example .env
$PHP -r '$e = file_get_contents(".env");
foreach (["APP_ENV"=>"production","APP_DEBUG"=>"false","APP_URL"=>"http://127.0.0.1","LOG_CHANNEL"=>"stderr",
  "LOG_LEVEL"=>"error","SESSION_DRIVER"=>"cookie","CACHE_STORE"=>"array","QUEUE_CONNECTION"=>"sync",
  "BROADCAST_CONNECTION"=>"log"] as $k=>$v)
  $e = preg_match("/^$k=.*/m",$e) ? preg_replace("/^$k=.*/m","$k=$v",$e) : $e."\n$k=$v";
file_put_contents(".env",$e);'
$C install --no-dev -o --no-interaction
$PHP artisan key:generate --force
$PHP artisan optimize
chmod -R a+rwX storage bootstrap/cache; chmod -R a+rX "$(dirname "$A")"
$PHP artisan route:list
