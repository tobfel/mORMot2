#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
nginx -c $D/nginx.conf -s stop 2>/dev/null; kill $(cat /srv/bench/run/fpm-lv.pid) 2>/dev/null
pkill -f fcgiproxy_; pkill -f "frankenphp run"; sleep 2
