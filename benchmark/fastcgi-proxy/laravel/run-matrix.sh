#!/bin/bash
# full Laravel matrix used for the 2026-11-19 update (master + PR #810 front controller)
# output: results/<prefix>-matrix.txt, -repeat-3x.txt, -static.txt
D=$(cd "$(dirname "$0")" && pwd); R=$D/../results; P=${1:-update}
STACKS="nginx mormot810 fclassic fworker"; port() { case $1 in nginx) echo 8081;; mormot810) echo 8091;; fclassic) echo 8086;; fworker) echo 8087;; esac; }
for s in $STACKS; do for e in / /page /api/items; do taskset -c 3 wrk -t1 -c16 -d3s "http://127.0.0.1:$(port $s)$e" > /dev/null; done; done
: > $R/$P-repeat-3x.txt
for r in 1 2 3; do for e in /api/items /page /; do for s in $STACKS; do "$D/bench.sh" $s $e 32 10 >> $R/$P-repeat-3x.txt; done; done; done
: > $R/$P-matrix.txt
for e in /api/items /page /; do for s in $STACKS; do "$D/bench.sh" $s $e 256 15 >> $R/$P-matrix.txt; done; done
: > $R/$P-static.txt
for f in /robots.txt /favicon.ico; do for s in $STACKS; do "$D/bench.sh" $s $f 64 10 >> $R/$P-static.txt; done; done
echo done
