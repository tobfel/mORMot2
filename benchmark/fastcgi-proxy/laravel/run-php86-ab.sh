#!/bin/bash
# A/B under Laravel 13 / PHP 8.6: mORMot before (PR #810, 29820f9) and after Arnaud's rework
# (master 883701d, FastCGI on the HTTP server's TAsyncConnections), nginx as reference
D=$(cd "$(dirname "$0")" && pwd); R=$D/../results; B=$D/../proxy/bin; W=$D/..
export PHPX=86 LARAVEL_APP=/srv/laravel13/app FRANKENPHP=$W/php/bin/frankenphp-1.14-php86 MORMOT_FRONT=$B/fcgiproxy_master883
"$D/start.sh"; pkill -f "fcgiproxy_upstream 8090"; pkill -f "fcgiproxy_fix 8095"; pkill -f "Caddyfile\.(classic|worker)"
(FCGI_INDEX=index.php taskset -c 0-2 $B/fcgiproxy_pr810 8092 "fcgi://unix:/srv/bench/run/fpm-lv.sock:$LARAVEL_APP/public" 4 < /dev/null > /dev/null 2>&1 &); sleep 1
N=$(pgrep -f "nginx: worker" | xargs); M=$(pgrep -f "fcgiproxy_master883 8091"); P=$(pgrep -f "fcgiproxy_pr810 8092")
cpu() { local s=0 f; for p in $1; do read -a f < /proc/$p/stat; s=$((s + f[13] + f[14])); done; echo $s; }
cs() { local s=0; for p in $1; do for t in /proc/$p/task/*; do s=$((s + $(awk '/ctxt_switches/{x+=$2} END{print x}' $t/status))); done; done; echo $s; }
for x in 8081 8091 8092; do taskset -c 3 wrk -t1 -c16 -d3s http://127.0.0.1:$x/api/items > /dev/null; done
: > $R/php86-ab-rework.txt
for r in 1 2 3 4; do for x in "nginx 8081 $N" "pr810 8092 $P" "master883 8091 $M"; do set -- $x; name=$1; port=$2; shift 2
  c0=$(cpu "$*"); s0=$(cs "$*")
  out=$(taskset -c 3 wrk -t1 -c32 -d10s --latency http://127.0.0.1:$port/api/items)
  c1=$(cpu "$*"); s1=$(cs "$*"); n=$(echo "$out" | awk '/requests in/{print $1}')
  echo "$name rps=$(echo "$out" | awk '/Requests\/sec/{print $2}') p99=$(echo "$out" | awk '/^     99%/{print $2}') front_cpu=$(echo "scale=1; ($c1 - $c0) / 10" | bc)% front_us_per_req=$(( (c1 - c0) * 1000000 / 100 / n )) ctxsw_per_req=$(echo "scale=2; ($s1 - $s0) / $n" | bc)" >> $R/php86-ab-rework.txt
done; done
"$D/stop.sh"; pkill -f fcgiproxy_; echo done
