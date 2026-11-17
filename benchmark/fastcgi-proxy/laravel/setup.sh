#!/bin/bash
# create the Laravel 12 benchmark app in /srv/laravel/app (no database, production mode)
# needs composer (with any PHP >= 8.2 CLI) and /opt/php85 from php/build-php.sh
set -e
D=$(cd "$(dirname "$0")" && pwd); export COMPOSER_ALLOW_SUPERUSER=1
mkdir -p /srv/laravel && cd /srv/laravel
[ -d app ] || composer create-project --no-interaction --no-scripts laravel/laravel app "12.*"
cd app && composer require --no-interaction -W laravel/octane
cp -r "$D/app/." .
cp vendor/laravel/octane/src/Commands/stubs/frankenphp-worker.php public/
cp .env.example .env
php -r '$e = file_get_contents(".env");
foreach (["APP_ENV"=>"production","APP_DEBUG"=>"false","APP_URL"=>"http://127.0.0.1","LOG_CHANNEL"=>"stderr",
  "LOG_LEVEL"=>"error","SESSION_DRIVER"=>"cookie","CACHE_STORE"=>"array","QUEUE_CONNECTION"=>"sync",
  "BROADCAST_CONNECTION"=>"log"] as $k=>$v)
  $e = preg_match("/^$k=.*/m",$e) ? preg_replace("/^$k=.*/m","$k=$v",$e) : $e."\n$k=$v";
file_put_contents(".env",$e);'
composer install --no-dev -o --no-interaction
/opt/php85/bin/php artisan key:generate --force
/opt/php85/bin/php artisan optimize
chmod -R a+rwX storage bootstrap/cache; chmod -R a+rX /srv/laravel
/opt/php85/bin/php artisan route:list
