#!/bin/bash
# start the 5 Laravel stacks on CPU 0-2 (wrk uses CPU 3)
# PHPX=85|86 selects /opt/phpXY for php-fpm, FRANKENPHP the binary, MORMOT_FRONT the front-controller proxy
D=$(cd "$(dirname "$0")" && pwd); B=$D/../proxy/bin; F=${FRANKENPHP:-$D/../php/bin/frankenphp}
X=${PHPX:-85}; M810=${MORMOT_FRONT:-$B/fcgiproxy_pr810}
A=${LARAVEL_APP:-/srv/laravel/app}; export LARAVEL_PUBLIC=$A/public
FCGI="fcgi://unix:/srv/bench/run/fpm-lv.sock:$A/public"
taskset -c 0-2 /opt/php$X/sbin/php-fpm -c $D/php.ini -y $D/php-fpm.conf -R
sed "s#LARAVEL_PUBLIC#$A/public#" $D/nginx.conf > /srv/bench/run/nginx-lv.conf   # root = the selected app
taskset -c 0-2 nginx -c /srv/bench/run/nginx-lv.conf
[ -x $B/fcgiproxy_upstream ] && (taskset -c 0-2 $B/fcgiproxy_upstream 8090 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormot.out 2>&1 &)
[ -x $B/fcgiproxy_fix ] && (taskset -c 0-2 $B/fcgiproxy_fix 8095 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormotfix.out 2>&1 &)
# master + PR #810 with the front controller: pretty URLs as with nginx try_files
[ -x $M810 ] && (FCGI_INDEX=index.php taskset -c 0-2 $M810 8091 "$FCGI" 4 < /dev/null > /srv/bench/run/lv-mormot810.out 2>&1 &)
(cd $A && PHPRC=$D taskset -c 0-2 $F run --config $D/Caddyfile.classic --adapter caddyfile > /srv/bench/run/lv-fclassic.out 2>&1 &)
(cd $A && PHPRC=$D taskset -c 0-2 $F run --config $D/Caddyfile.worker --adapter caddyfile > /srv/bench/run/lv-fworker.out 2>&1 &)
sleep 3
