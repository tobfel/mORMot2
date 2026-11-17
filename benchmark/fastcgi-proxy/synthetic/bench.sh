#!/bin/bash
# usage: bench.sh <label> <pids-of-proxy (space sep, quoted)> <url> <conc> <secs> [wrk extra args]
label=$1; pids=$2; url=$3; conc=$4; secs=$5; shift 5
HZ=$(getconf CLK_TCK)
cpu() { local s=0; for p in $1; do read -a f < /proc/$p/stat; s=$((s + f[13] + f[14])); done; echo $s; }
rss() { local s=0; for p in $1; do s=$((s + $(awk '/VmRSS/{print $2}' /proc/$p/status))); done; echo $s; }
hwm() { local s=0; for p in $1; do s=$((s + $(awk '/VmHWM/{print $2}' /proc/$p/status))); done; echo $s; }
fpm=$(pgrep -f "php-fpm: pool" | tr '\n' ' ')
c0=$(cpu "$pids"); f0=$(cpu "$fpm"); r0=$(rss "$pids")
out=$(taskset -c ${WRKCPU:-3} wrk -t${WRKT:-1} -c$conc -d${secs}s --timeout 30s --latency "$@" "$url" 2>&1)
c1=$(cpu "$pids"); f1=$(cpu "$fpm"); r1=$(rss "$pids"); h=$(hwm "$pids")
reqs=$(echo "$out" | awk '/requests in/{print $1}')
rps=$(echo "$out" | awk '/Requests\/sec/{print $2}')
lat=$(echo "$out" | awk '/^    Latency/{print $2}')
p50=$(echo "$out" | awk '/^     50%/{print $2}')
p99=$(echo "$out" | awk '/^     99%/{print $2}')
non2xx=$(echo "$out" | awk '/Non-2xx/{print $5}'); non2xx=${non2xx:-0}
serr=$(echo "$out" | awk -F'Socket errors: ' '/Socket errors/{print $2}'); serr=${serr:-none}
pcpu=$(( c1 - c0 )); fcpu=$(( f1 - f0 ))
awk -v l="$label" -v c="$conc" -v rps="$rps" -v lat="$lat" -v p50="$p50" -v p99="$p99" -v n="$non2xx" \
    -v e="$serr" -v pc=$pcpu -v fc=$fcpu -v hz=$HZ -v s=$secs -v req=$reqs -v r0=$r0 -v r1=$r1 -v h=$h \
  'BEGIN{ printf "%-28s c=%-5d rps=%-9s avg=%-8s p50=%-8s p99=%-8s non2xx=%-6s proxyCPU=%5.1f%% (%5.1f us/req) phpCPU=%5.1f%% RSS=%dMB->%dMB HWM=%dMB sockerr=[%s]\n",
      l, c, rps, lat, p50, p99, n, 100*pc/hz/s, 1e6*pc/hz/(req>0?req:1), 100*fc/hz/s, r0/1024, r1/1024, h/1024, e }'
