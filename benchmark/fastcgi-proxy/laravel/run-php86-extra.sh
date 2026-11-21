#!/bin/bash
# extra runs of the 2026-11-21 PHP 8.6 update (needs the stacks of laravel/start.sh with
# PHPX=86 LARAVEL_APP=/srv/laravel13/app; restarts php-fpm with 8.5 for part C)
D=$(cd "$(dirname "$0")" && pwd); R=$D/../results; B=$D/../proxy/bin
# A. 5 more interleaved runs nginx vs mORMot
: > $R/php86-repeat-5x-nginx-mormot.txt
for r in 1 2 3 4 5; do for e in /api/items /page /; do for s in nginx mormot810; do
  "$D/bench.sh" $s $e 32 10 >> $R/php86-repeat-5x-nginx-mormot.txt; done; done; done
# B. 2 min mixed soak of mORMot (RSS MB, fds, threads every 10 s)
X=$(pgrep -f "fcgiproxy_[a-z0-9]* 8091"); : > $R/php86-soak.txt
(for i in $(seq 1 12); do sleep 10; echo "$(awk '/VmRSS/{print int($2/1024)}' /proc/$X/status) $(ls /proc/$X/fd | wc -l) $(awk '/Threads/{print $2}' /proc/$X/status)" >> $R/php86-soak.txt; done &)
taskset -c 3 wrk -t1 -c100 -d120s --timeout 20s --latency -s "$D/mixed-front.lua" http://127.0.0.1:8091/ > $R/php86-soak-wrk.txt 2>&1
sleep 3
# C. PHP 8.5.12 vs 8.6.0 on the same Laravel 13 app, nginx + php-fpm only
: > $R/php85-vs-86-laravel13.txt
for r in 1 2 3; do for v in 85 86; do
  kill $(cat /srv/bench/run/fpm-lv.pid); sleep 2
  taskset -c 0-2 /opt/php$v/sbin/php-fpm -c "$D/php.ini" -y "$D/php-fpm.conf" -R; sleep 2
  for e in / /page /api/items; do taskset -c 3 wrk -t1 -c16 -d2s "http://127.0.0.1:8081$e" > /dev/null; done
  for e in /api/items /page /; do echo "php$v $("$D/bench.sh" nginx $e 32 10)" >> $R/php85-vs-86-laravel13.txt; done
done; done
kill $(cat /srv/bench/run/fpm-lv.pid); sleep 2
taskset -c 0-2 /opt/php86/sbin/php-fpm -c "$D/php.ini" -y "$D/php-fpm.conf" -R
echo done
