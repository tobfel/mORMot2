#!/bin/bash
# build the benchmark proxy from the current mORMot 2 sources, always with FPC_X64MM
# usage: proxy/build.sh <name> [program]   e.g. proxy/build.sh upstream ; proxy/build.sh fix
# - MORMOT_ROOT=<another mORMot 2 checkout> builds against those sources instead
# - needs FPC 3.2.x and the static libraries in <repo>/static/x86_64-linux
set -e
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "${MORMOT_ROOT:-$D/../../..}" && pwd)
NAME=${1:?name}; PRG=${2:-fcgiproxy}
mkdir -p "$D/bin" "$D/units-$NAME-$PRG"
# sources with PR #810 (THttpProxyUrlSettings.FastCgiIndex): enable FCGI_INDEX in the program
DEF=""; grep -q "property FastCgiIndex" "$R/src/net/mormot.net.proxy.pas" && DEF="-dHASFASTCGIINDEX"
fpc -O3 -Xs -MDelphi -dFPC_X64MM -dFPCMM_SERVER $DEF -Fi"$R/src" -Fu"$R/src/core" -Fu"$R/src/lib" \
  -Fu"$R/src/net" -Fu"$R/src/crypt" -Fu"$R/src/db" -Fl"$R/static/x86_64-linux" \
  -FU"$D/units-$NAME-$PRG" -o"$D/bin/${PRG}_$NAME" "$D/$PRG.dpr" | grep -E "Error|Fatal|compiled" || true
ls -la "$D/bin/${PRG}_$NAME"
