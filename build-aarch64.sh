#!/usr/bin/env bash
# 64-bit (aarch64) build of Macro Osc for Gen 2 MPCs, without Docker.  See BUILD-AARCH64.md.
#
#   ./build-aarch64.sh            build + assemble the plugin folder under build/aarch64/
#   ./build-aarch64.sh native     also build a library for this computer (build/native/) for offline tests
#
# Needs: git, python3, curl, shasum and a Zig toolchain.  Zig defaults to the one bundled with inMusic's MPC
# Plugin Builder SDK ($SDK/.sdk-tools/zigenv); override with ZIG="zig" or ZIG="/path/to/python -m ziglang".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

SDK="${SDK:-$HOME/dev/mpc-plugin-builder-sdk}"
ZIG="${ZIG:-$SDK/.sdk-tools/zigenv/bin/python -m ziglang}"
# Same target as the SDK's tools/build.py "arm64" (file64): glibc 2.31 symbols at most, Cortex-A55 code.
ZIG_TARGET="aarch64-linux-gnu.2.31"
ZIG_CPU="cortex_a55"

# The framework this plugin is built with, at the commit its release workflow pins (FRAMEWORK.md).
FW_REPO="https://github.com/saustin2010/mpc-vst-plugins.git"
FW_COMMIT="e3a0af4e8cb7eacd4bfcc2fbcbcde834aef50fa4"
FW="$HERE/build/framework"

# The published 32-bit release: its touch-screen skin, version.xml and presets are architecture-independent.
REL_VERSION="1.1.1"
REL_ZIP="SYN-Macro-Osc-$REL_VERSION-mpc-armv7.zip"
REL_URL="https://github.com/saustin2010/mpc-vst-macro-osc/releases/download/v$REL_VERSION/$REL_ZIP"
REL_SHA256="de7d11274fb341b92f7446a06bf191758fd5a672107a7194d201b17e643fbe3f"   # GitHub asset digest = Open MPC catalogue
REL="$HERE/build/upstream-release"

FOLDER="Émilie Gillet - VST - [SYN] Macro Osc"   # "<vendor> - VST - <name>" from vst.json
OUT="$HERE/build/aarch64"

# --- 1. framework at the pinned commit --------------------------------------------------------------------
if [ ! -d "$FW/.git" ]; then
  mkdir -p "$HERE/build"
  git clone -q "$FW_REPO" "$FW"
fi
git -C "$FW" checkout -q "$FW_COMMIT"
[ "$(git -C "$FW" rev-parse HEAD)" = "$FW_COMMIT" ] || { echo "framework is not at $FW_COMMIT" >&2; exit 1; }

# --- 2. params.h (parameter table, identity, defines) from vst.json: pure Python, no skin step ------------
python3 -I "$FW/tools/gen_vst.py" "$HERE/vst.json" --params-h
eval "$(python3 -I "$FW/tools/gen_vst.py" "$HERE/vst.json" --shell)"   # SOURCES, CFLAGS, LIBS, SO, ADAPTER
ADAPTER_SRC="$FW/adapters/$ADAPTER/${ADAPTER}_engine.c"

# --- 3. compile: build_port.sh's C++ branch, with zig cc / zig c++ in place of gcc / g++ in Docker ---------
build() {   # build <object dir> <output file> <folder holding params.h> [zig target flags...]
  local OBJ="$1" LIB="$2" INC="$3"; shift 3
  local OBJS=() f o
  rm -rf "$OBJ"; mkdir -p "$OBJ" "$(dirname "$LIB")"
  for f in $SOURCES; do
    o="$OBJ/${f//\//_}.o"
    # shellcheck disable=SC2086
    $ZIG c++ "$@" -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -fvisibility=hidden -std=gnu++11 $CFLAGS \
      -I"$INC" -I"$FW/wrapper" -c "$f" -o "$o"
    OBJS+=("$o")
  done
  $ZIG cc "$@" -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -fvisibility=hidden -std=gnu11 \
    -I"$INC" -c "$FW/wrapper/vst2_wrap.c" -o "$OBJ/vst2_wrap.o"
  $ZIG cc "$@" -O2 -Wall -Wextra -fPIC -fvisibility=hidden -std=gnu11 -c "$ADAPTER_SRC" -o "$OBJ/adapter.o"
  OBJS+=("$OBJ/vst2_wrap.o" "$OBJ/adapter.o")
  # shellcheck disable=SC2086
  $ZIG c++ "$@" -O2 -shared -fPIC -fvisibility=hidden "${OBJS[@]}" $LIBS -lpthread $LINK_EXTRA -o "$LIB"
}

# aarch64: nothing exported but VSTPluginMain (zig links the C++ runtime statically), symbols stripped
LINK_EXTRA="-Wl,--no-undefined -Wl,--version-script=exports-aarch64.map -Wl,-s"
build "$OUT/obj" "$OUT/$SO" "$HERE/build" -target "$ZIG_TARGET" -mcpu="$ZIG_CPU"

# --- 4. the published release: download once, verify, extract ---------------------------------------------
mkdir -p "$REL"
[ -f "$REL/$REL_ZIP" ] || curl -fsSL "$REL_URL" -o "$REL/$REL_ZIP"
echo "$REL_SHA256  $REL/$REL_ZIP" | shasum -a 256 -c - >/dev/null
rm -rf "$REL/x"; mkdir -p "$REL/x"
python3 -I -m zipfile -e "$REL/$REL_ZIP" "$REL/x"
( cd "$REL/x/SYN-Macro-Osc-$REL_VERSION" && shasum -a 256 -c SHA256SUMS >/dev/null )   # every file in the zip
SRC="$REL/x/SYN-Macro-Osc-$REL_VERSION/portable/$FOLDER"

# --- 4b. optional: a library for this computer, for the offline tests only (never installed) ---------------
if [ "${1:-}" = native ]; then
  # The wrapper finds its data folder through /proc/self/maps, which macOS lacks, so the test build's params.h
  # points MODULE_DIR straight at the extracted presets.  Same sources, same flags, host CPU.
  NAT="$HERE/build/native"
  mkdir -p "$NAT/inc"
  sed -e '/#define MODULE_SUBDIR/d' -e "s|#define MODULE_DIR .*|#define MODULE_DIR \"$SRC/braids\"|" \
    "$HERE/build/params.h" > "$NAT/inc/params.h"
  LINK_EXTRA=""
  [ "$(uname)" = Darwin ] && LINK_EXTRA="-Wl,-undefined,dynamic_lookup"   # the wrapper's optional (weak) engine hooks
  build "$NAT/obj" "$NAT/braids-native.so" "$NAT/inc"
  echo "native test library: $NAT/braids-native.so"
fi

# --- 5. the installable folder for MPC OS 3.10.1+ ("VST2 Plugins/<folder>/") --------------------------------
DEST="$OUT/$FOLDER"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -R "$SRC/Plugin Skins" "$DEST/Plugin Skins"      # reused as published (TUI.json, Q-Links, artwork)
cp -R "$SRC/braids" "$DEST/braids"                  # presets: the .so reads <its own folder>/braids/presets
cp "$SRC/version.xml" "$DEST/version.xml"
cp "$OUT/$SO" "$DEST/$SO"
cp "$HERE/LICENSE" "$DEST/LICENSE"
cp "$HERE/CREDITS-aarch64.txt" "$DEST/CREDITS.txt"
python3 -I - "$HERE/vst.json" "$DEST/plugin.json" "$REL_VERSION" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
uid = int.from_bytes(cfg["uid"].encode(), "big")
manifest = {
    "name": cfg["name"],                 # = PLUG_NAME, what the binary reports (effGetEffectName)
    "manufacturer": cfg["vendor"],       # = PLUG_VENDOR (effGetVendorString)
    "version": sys.argv[3],
    "format": "vst2",
    "kind": "instrument",
    "uid": "0x%08x" % uid,               # = PLUG_UID, the same number as the plugin-list entry's uid="42724473"
    "category": "Synth",
    "numInputs": 0,
    "numOutputs": 2,
    "file64": cfg["so"],
    "license": "MIT",
    "url": "https://github.com/saustin2010/mpc-vst-macro-osc",
    "description": "Macro Osc: a macro oscillator with 47 synthesis models, from Émilie Gillet's open-source Braids. "
                   "Unofficial aarch64 build of release %s." % sys.argv[3],
}
json.dump(manifest, open(sys.argv[2], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
open(sys.argv[2], "a").write("\n")
PY
find "$DEST" -name .DS_Store -delete
( cd "$DEST" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS )
echo "built: $DEST"
shasum -a 256 "$DEST/$SO"
