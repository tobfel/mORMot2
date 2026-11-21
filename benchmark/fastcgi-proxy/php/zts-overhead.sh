#!/bin/bash
# ZTS overhead: the same PHP code on NTS and ZTS builds of 8.5.12 and 8.6.0, pinned to CPU 3
# - Zend/bench.php (pure VM) and N Laravel 13 requests handled in one CLI process (opcache on)
# usage: php/zts-overhead.sh <php-src dir with Zend/bench.php> [laravel app] [requests]
B=${1:?php-src}/Zend/bench.php; A=${2:-/srv/laravel13/app}; N=${3:-3000}
LOOP='require "vendor/autoload.php"; $app = require "bootstrap/app.php";
$k = $app->make(Illuminate\Contracts\Http\Kernel::class); $n = (int)$argv[1]; $t = hrtime(true);
for ($i = 0; $i < $n; $i++) { $r = $k->handle($q = Illuminate\Http\Request::create("/api/items")); $k->terminate($q, $r); }
printf("%.1f", $n / ((hrtime(true) - $t) / 1e9));'
INI="-d opcache.enable_cli=1 -d opcache.jit=disable -d memory_limit=512M"
for run in 1 2 3; do for v in 85 86; do for t in "" zts; do
  php=/opt/php$v$t/bin/php
  vm=$(taskset -c 3 $php $INI $B | awk '/^Total/{print $2}')
  lv=$(cd $A && taskset -c 3 $php $INI -r "$LOOP" $N 2>/dev/null)
  echo "run$run php$v ${t:-nts} bench.php=${vm}s laravel=${lv}req/s"
done; done; done
