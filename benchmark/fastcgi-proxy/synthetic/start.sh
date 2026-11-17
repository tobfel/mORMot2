#!/bin/bash
# synthetic stack: php-fpm (CPU 1-2), nginx 1 worker (CPU 0), mORMot proxy (CPU 0)
# usage: synthetic/start.sh [proxy-name=upstream] [threads=4]  - wrk then uses CPU 3
D=$(cd "$(dirname "$0")" && pwd); P=$D/../proxy/bin/fcgiproxy_${1:-upstream}
mkdir -p /srv/bench/run && chmod 777 /srv/bench/run && rm -rf /srv/bench/www && cp -r "$D/www" /srv/bench/ && chmod -R a+rX /srv/bench/www
taskset -c 1,2 /opt/php85/sbin/php-fpm -c "$D/php.ini" -y "$D/php-fpm.conf" -R
taskset -c 0 nginx -c "$D/nginx.conf"
(taskset -c 0 "$P" 8080 "fcgi://unix:/srv/bench/run/php-fpm.sock:/srv/bench/www" ${2:-4} < /dev/null > /srv/bench/run/proxy.out 2>&1 &)
sleep 1; cat /srv/bench/run/proxy.out
