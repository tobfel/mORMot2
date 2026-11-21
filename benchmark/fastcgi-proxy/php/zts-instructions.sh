#!/bin/bash
# ZTS overhead as executed instructions (valgrind callgrind, deterministic, noise-free):
# Zend/bench.php and N Laravel 13 requests in one CLI process, NTS vs ZTS of 8.5.12 and 8.6.0
B=${1:?php-src}/Zend/bench.php; A=${2:-/srv/laravel13/app}; N=${3:-200}
LOOP='require "vendor/autoload.php"; $app = require "bootstrap/app.php";
$k = $app->make(Illuminate\Contracts\Http\Kernel::class); $n = (int)$argv[1];
for ($i = 0; $i < $n; $i++) { $r = $k->handle($q = Illuminate\Http\Request::create("/api/items")); $k->terminate($q, $r); }'
INI="-d opcache.enable_cli=1 -d opcache.jit=disable -d memory_limit=512M"
ir() { valgrind --tool=callgrind --callgrind-out-file=/dev/null "$@" 2>&1 >/dev/null | awk '/Collected/{print $NF}'; }
for v in 85 86; do for t in "" zts; do php=/opt/php$v$t/bin/php
  a=$(ir $php $INI $B); l1=$(cd $A && ir $php $INI -r "$LOOP" 1); ln=$(cd $A && ir $php $INI -r "$LOOP" $N)
  echo "php$v ${t:-nts} bench.php=$a instructions, laravel=$(( (ln - l1) / (N - 1) )) instructions/request (boot excluded)"
done; done
