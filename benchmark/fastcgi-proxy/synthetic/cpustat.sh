#!/bin/bash
# print per-cpu busy% (incl. irq/softirq) and steal% during $1 seconds
a=$(grep '^cpu[0-9]' /proc/stat); sleep $1; b=$(grep '^cpu[0-9]' /proc/stat)
paste <(echo "$a") <(echo "$b") | awk '{n=NF/2; t0=0;t1=0; for(i=2;i<=n;i++){t0+=$i; t1+=$(i+n)}; idle=($(n+5)+$(n+6))-($5+$6); st=$(n+9)-$9; printf "%s busy=%3.0f%% steal=%2.0f%%  ", $1, 100*(1-idle/(t1-t0)), 100*st/(t1-t0)} END{print ""}'
