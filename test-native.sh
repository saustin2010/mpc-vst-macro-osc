#!/usr/bin/env bash
# Offline tests of the same sources on this computer (run ./build-aarch64.sh native first).  See BUILD-AARCH64.md.
#   1. inMusic's host simulator ($SDK/.sdk-tools/host_sim) on build/native/braids-native.so
#   2. the framework's own host test (tools/host_test.c) under UBSan, in place of tools/test_port.sh (which needs Docker)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
SDK="${SDK:-$HOME/dev/mpc-plugin-builder-sdk}"
ZIG="${ZIG:-$SDK/.sdk-tools/zigenv/bin/python -m ziglang}"
FW="$HERE/build/framework"
INC="$HERE/build/native/inc"          # params.h with MODULE_DIR pointing at the extracted presets
T="$HERE/build/native/host_test"
[ -f "$INC/params.h" ] || { echo "run ./build-aarch64.sh native first" >&2; exit 1; }

echo "== host_sim =="
"$SDK/.sdk-tools/host_sim" "$HERE/build/native/braids-native.so" test

echo "== framework host test (UBSan) =="
eval "$(python3 -I "$FW/tools/gen_vst.py" "$HERE/vst.json" --shell)"
SAN="-fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g -O1"
rm -rf "$T"; mkdir -p "$T"
OBJS=()
for f in $SOURCES; do
  o="$T/${f//\//_}.o"
  # shellcheck disable=SC2086
  $ZIG c++ $SAN -std=gnu++11 $CFLAGS -I"$INC" -I"$FW/wrapper" -c "$f" -o "$o" 2>/dev/null
  OBJS+=("$o")
done
for f in "$FW/tools/host_test.c" "$FW/wrapper/vst2_wrap.c" "$FW/adapters/$ADAPTER/${ADAPTER}_engine.c"; do
  o="$T/$(basename "$f").o"
  # shellcheck disable=SC2086
  $ZIG cc $SAN -std=gnu11 -I"$INC" -c "$f" -o "$o" 2>/dev/null
  OBJS+=("$o")
done
EXTRA=""
[ "$(uname)" = Darwin ] && EXTRA="-Wl,-undefined,dynamic_lookup"
# shellcheck disable=SC2086
$ZIG c++ $SAN "${OBJS[@]}" $LIBS -lpthread $EXTRA -o "$T/host_test"
"$T/host_test"
