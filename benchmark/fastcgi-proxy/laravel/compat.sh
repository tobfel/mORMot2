#!/bin/bash
# compare the answers of nginx try_files (8081), mORMot front controller (8091) and
# FrankenPHP worker (8087): status, size, content type and md5 of the normalized body
T=$(mktemp -d); trap 'rm -rf $T' EXIT
norm() { sed -E 's/name="_token" value="[^"]*"//g; s/content="[A-Za-z0-9]{40}"//g; s/127\.0\.0\.1:[0-9]+/HOST/g' | md5sum | cut -c1-8; }
for u in / /page /api/items "/page?x=1&y=2" /index.php /index.php/page /up /robots.txt /favicon.ico \
         /nonexistent /some/deep/path /build/missing.css /storage/x; do
  for p in 8081 8091 8087; do
    r=$(curl -s -m 10 -o $T/b -w "%{http_code} %{size_download} %{content_type}" "http://127.0.0.1:$p$u")
    printf "GET   %-20s %s: %-46s md5=%s\n" "$u" $p "$r" "$(norm < $T/b)"
  done
done
for p in 8081 8091 8087; do
  b=http://127.0.0.1:$p
  lm=$(curl -s -I $b/robots.txt | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{print $2}')
  et=$(curl -s -I $b/robots.txt | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
  echo "== $p: HEAD=$(curl -s -m 5 -I -o /dev/null -w '%{http_code}' $b/robots.txt)" \
    "POST-static=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -d x=1 $b/robots.txt)" \
    "POST-/page=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -d x=1 $b/page)" \
    "traversal=$(curl -s -m 5 --path-as-is -o /dev/null -w '%{http_code}' "$b/../../etc/passwd")" \
    "dotenv=$(curl -s -m 5 -o /dev/null -w '%{http_code}' $b/.env)" \
    "range=$(curl -s -m 5 -o /dev/null -w '%{http_code}/%{size_download}' -r 0-4 $b/robots.txt)" \
    "IMS=$(curl -s -o /dev/null -w '%{http_code}' -H "If-Modified-Since: $lm" $b/robots.txt)" \
    "INM=$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $et" $b/robots.txt)" \
    "link=$(curl -s $b/page | grep -o 'href="[^"]*"' | head -1)"
done
