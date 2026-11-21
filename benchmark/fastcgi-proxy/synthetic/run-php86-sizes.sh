#!/bin/bash
# synthetic 2026-11-21 (PHP 8.6.0): nginx vs mORMot before (bbbb264 + fix) and after Arnaud's
# rework (master 883701d), 1 core each, 3 interleaved runs per size; plus context switches
D=$(cd "$(dirname "$0")" && pwd); R=$D/../results; B=$D/../proxy/bin
FC="fcgi://unix:/srv/bench/run/php-fpm.sock:/srv/bench/www"
PHPX=86 "$D/start.sh" fix                                   # fix = bbbb264 + fix on :8080
(taskset -c 0 $B/fcgiproxy_master883 8095 "$FC" 4 < /dev/null > /dev/null 2>&1 &); sleep 1
P1=$(pgrep -f "fcgiproxy_fix 8080"); P2=$(pgrep -f "fcgiproxy_master883 8095"); N=$(pgrep -f "nginx: worker")
for u in hello.php json.php "big.php?kb=100" "big.php?kb=1024"; do for x in 8080 8095 8081; do
  taskset -c 3 wrk -t1 -c16 -d2s "http://127.0.0.1:$x/$u" > /dev/null; done; done
: > $R/php86-synthetic-sizes.txt
for r in 1 2 3; do for u in "hello.php 64" "json.php 64" "big.php?kb=100 64" "big.php?kb=1024 16"; do set -- $u
  WRKCPU=3 "$D/bench.sh" "nginx $1" "$N" "http://127.0.0.1:8081/$1" $2 10 >> $R/php86-synthetic-sizes.txt
  WRKCPU=3 "$D/bench.sh" "bbbb264+fix $1" "$P1" "http://127.0.0.1:8080/$1" $2 10 >> $R/php86-synthetic-sizes.txt
  WRKCPU=3 "$D/bench.sh" "master883 $1" "$P2" "http://127.0.0.1:8095/$1" $2 10 >> $R/php86-synthetic-sizes.txt
done; done
cs() { local s=0; for p in $1; do for t in /proc/$p/task/*; do s=$((s + $(awk '/ctxt_switches/{x+=$2} END{print x}' $t/status))); done; done; echo $s; }
: > $R/php86-ctxswitch.txt
for u in hello.php "big.php?kb=100" "big.php?kb=1024"; do for x in "nginx 8081 $N" "bbbb264+fix 8080 $P1" "master883 8095 $P2"; do set -- $x
  a=$(cs "$3"); n=$(taskset -c 3 wrk -t1 -c64 -d5s "http://127.0.0.1:$2/$u" | awk '/requests in/{print $1}'); b=$(cs "$3")
  echo "$1 $u: $n req, $(( (b - a) * 10 / n ))/10 context switches per request" >> $R/php86-ctxswitch.txt
done; done
"$D/stop.sh"; echo done
