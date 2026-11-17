#!/bin/bash
a=($(grep '^cpu0 ' /proc/stat)); sleep $1; b=($(grep '^cpu0 ' /proc/stat))
t=0; for i in 1 2 3 4 5 6 7 8; do d[$i]=$((b[i]-a[i])); t=$((t+d[i])); done
echo "cpu0 user=$((100*d[1]/t))% sys=$((100*d[3]/t))% idle=$((100*d[4]/t))% irq=$((100*d[6]/t))% softirq=$((100*d[7]/t))%"
