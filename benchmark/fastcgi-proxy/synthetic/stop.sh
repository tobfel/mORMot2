#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
nginx -c "$D/nginx.conf" -s stop 2>/dev/null; nginx -c "$D/nginx4.conf" -s stop 2>/dev/null
kill $(cat /srv/bench/run/php-fpm.pid) 2>/dev/null; pkill -f fcgiproxy_; sleep 1
