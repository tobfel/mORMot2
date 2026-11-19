#!/bin/bash
# usage: bench.sh <stack> <path> <conc> <secs>
# stack: nginx | mormot | mormotfix | mormot810 | fclassic | fworker
stack=$1; path=$2; conc=$3; secs=$4
fpm=$(pgrep -f "php-fpm: (master|pool).*" | xargs)
case $stack in
  nginx)     port=8081; front=$(pgrep -f "nginx: .*laravel/nginx.conf|nginx: worker" | xargs); php=$fpm;;
  mormot)    port=8090; front=$(pgrep -f "fcgiproxy_upstream 8090"); php=$fpm;;
  mormotfix) port=8095; front=$(pgrep -f "fcgiproxy_fix 8095"); php=$fpm;;
  mormot810) port=8091; front=$(pgrep -f "fcgiproxy_pr810 8091"); php=$fpm;;
  fclassic)  port=8086; front=$(pgrep -f "Caddyfile.classic"); php="";;
  fworker)   port=8087; front=$(pgrep -f "Caddyfile.worker"); php="";;
esac
all="$front $php"; HZ=$(getconf CLK_TCK)
sum() { local s=0 v; for p in $2; do v=$($1 $p 2>/dev/null); s=$((s + ${v:-0})); done; echo $s; }
cpu() { local f; read -a f < /proc/$1/stat; echo $((f[13] + f[14])); }
rss() { awk '/VmRSS/{print $2}' /proc/$1/status; }
hwm() { awk '/VmHWM/{print $2}' /proc/$1/status; }
pss() { awk '/^Pss:/{print $2}' /proc/$1/smaps_rollup; }
fds() { ls /proc/$1/fd | wc -l; }
thr() { awk '/Threads/{print $2}' /proc/$1/status; }
c0=$(sum cpu "$all"); f0=$(sum cpu "$front")
(taskset -c 3 wrk -t1 -c$conc -d${secs}s --timeout 20s --latency "http://127.0.0.1:$port$path" > /srv/bench/run/wrk.out 2>&1 &)
sleep $((secs / 2))
mid="$(( $(sum rss "$all") / 1024 )) $(( $(sum pss "$all") / 1024 )) $(sum fds "$all") $(sum thr "$all") $(( $(sum rss "$front") / 1024 )) $(sum fds "$front") $(sum thr "$front")"
while pgrep -x wrk > /dev/null; do sleep 0.3; done
c1=$(sum cpu "$all"); f1=$(sum cpu "$front"); out=$(cat /srv/bench/run/wrk.out)
reqs=$(echo "$out" | awk '/requests in/{print $1}')
echo "$out" | awk -v st="$stack" -v pa="$path" -v c=$conc -v s=$secs -v req=$reqs -v hz=$HZ \
  -v ac=$((c1 - c0)) -v fc=$((f1 - f0)) -v mid="$mid" -v fh=$(( $(sum hwm "$front") / 1024 )) '
  /Requests\/sec/{rps=$2} /^     50%/{p50=$2} /^     99%/{p99=$2} /Non-2xx/{n=$5}
  /Socket errors/{e=$0; sub(/.*errors: /,"",e)}
  END{ split(mid, m, " ");
    printf "%-9s %-20s c=%-4d rps=%-8s p50=%-8s p99=%-8s err=%s/%s | CPU stack=%3.0f%% front=%3.0f%% %4.0fus/req | stack RSS=%dMB PSS=%dMB fds=%d thr=%d | front RSS=%dMB HWM=%dMB fds=%d thr=%d\n",
      st, pa, c, rps, p50, p99, (n==""?0:n), (e==""?"-":e), 100*ac/hz/s, 100*fc/hz/s, 1e6*ac/hz/(req>0?req:1),
      m[1], m[2], m[3], m[4], m[5], fh, m[6], m[7] }'
