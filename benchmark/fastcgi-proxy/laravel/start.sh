#!/bin/bash
# start the 5 Laravel stacks on CPU 0-2 (wrk uses CPU 3)
D=$(cd "$(dirname "$0")" && pwd); B=$D/../proxy/bin; F=$D/../php/bin/frankenphp
FCGI="fcgi://unix:/srv/bench/run/fpm-lv.sock:/srv/laravel/app/public"
taskset -c 0-2 /opt/php85/sbin/php-fpm -c $D/php.ini -y $D/php-fpm.conf -R
taskset -c 0-2 nginx -c $D/nginx.conf
(taskset -c 0-2 $B/fcgiproxy_upstream 8090 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormot.out 2>&1 &)
(taskset -c 0-2 $B/fcgiproxy_fix 8095 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormotfix.out 2>&1 &)
(cd /srv/laravel/app && PHPRC=$D taskset -c 0-2 $F run --config $D/Caddyfile.classic --adapter caddyfile > /srv/bench/run/lv-fclassic.out 2>&1 &)
(cd /srv/laravel/app && PHPRC=$D taskset -c 0-2 $F run --config $D/Caddyfile.worker --adapter caddyfile > /srv/bench/run/lv-fworker.out 2>&1 &)
sleep 3
