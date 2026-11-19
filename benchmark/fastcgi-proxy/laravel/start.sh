#!/bin/bash
# start the 5 Laravel stacks on CPU 0-2 (wrk uses CPU 3)
D=$(cd "$(dirname "$0")" && pwd); B=$D/../proxy/bin; F=$D/../php/bin/frankenphp
FCGI="fcgi://unix:/srv/bench/run/fpm-lv.sock:/srv/laravel/app/public"
taskset -c 0-2 /opt/php85/sbin/php-fpm -c $D/php.ini -y $D/php-fpm.conf -R
taskset -c 0-2 nginx -c $D/nginx.conf
[ -x $B/fcgiproxy_upstream ] && (taskset -c 0-2 $B/fcgiproxy_upstream 8090 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormot.out 2>&1 &)
[ -x $B/fcgiproxy_fix ] && (taskset -c 0-2 $B/fcgiproxy_fix 8095 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormotfix.out 2>&1 &)
# master + PR #810 with the front controller: pretty URLs as with nginx try_files
[ -x $B/fcgiproxy_pr810 ] && (FCGI_INDEX=index.php taskset -c 0-2 $B/fcgiproxy_pr810 8091 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormot810.out 2>&1 &)
(cd /srv/laravel/app && PHPRC=$D taskset -c 0-2 $F run --config $D/Caddyfile.classic --adapter caddyfile > /srv/bench/run/lv-fclassic.out 2>&1 &)
(cd /srv/laravel/app && PHPRC=$D taskset -c 0-2 $F run --config $D/Caddyfile.worker --adapter caddyfile > /srv/bench/run/lv-fworker.out 2>&1 &)
sleep 3
