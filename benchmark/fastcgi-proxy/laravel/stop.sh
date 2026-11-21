#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
nginx -c /srv/bench/run/nginx-lv.conf -s stop 2>/dev/null; kill $(cat /srv/bench/run/fpm-lv.pid) 2>/dev/null
pkill -f fcgiproxy_; pkill -f "Caddyfile\.(classic|worker)"; sleep 2
