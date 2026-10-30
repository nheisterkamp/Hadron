#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "envcheck: $SRC not present, skipped"; exit 0; }

strip() { sed 's/^[[:space:]]*//'; }
dllpath_line=$(grep '^export WINEDLLPATH="$wine_pe64' "$SRC" | strip)
overrides_line=$(grep 'export WINEDLLOVERRIDES=' "$SRC" | grep 'lsteamclient=b' | strip)
[ -n "$dllpath_line" ] || { echo "FAIL: WINEDLLPATH merge not found"; exit 1; }
[ -n "$overrides_line" ] || { echo "FAIL: WINEDLLOVERRIDES merge not found"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "== WINEDLLPATH (first match wins, runner first) =="
np_root=/R
wine_unix=/R/lib/wine/x86_64-unix
wine_pe64=/R/lib/wine/x86_64-windows
WINEDLLPATH=""
eval "$dllpath_line"
is "no user value" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix" "$WINEDLLPATH"
WINEDLLPATH="/user/dir"
eval "$dllpath_line"
is "user value last" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix:/user/dir" "$WINEDLLPATH"

echo "== WINEDLLOVERRIDES (last wins, trio last) =="
WINEDLLOVERRIDES=""
eval "$overrides_line"
is "no user value" "steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="winhttp=n,b"
eval "$overrides_line"
is "user value first" "winhttp=n,b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="lsteamclient=n"
eval "$overrides_line"
is "trio outranks user" "lsteamclient=n;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides="vcruntime140_1=n,b;"
WINEDLLOVERRIDES="vcruntime140_1=b"
eval "$overrides_line"
is "user outranks the native runtime" \
  "vcruntime140_1=n,b;vcruntime140_1=b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides=""

echo "== Microsoft's Visual C++ runtime loads when it is installed =="
vc_fn=$(sed -n '/^native_vc_runtime() {/,/^}/p' "$SRC")
[ -n "$vc_fn" ] || { echo "FAIL: native_vc_runtime not found"; exit 1; }
eval "$vc_fn"
vc_work=$(mktemp -d)
WINEPREFIX="$vc_work/pfx"
sys32="$WINEPREFIX/drive_c/windows/system32"
mkdir -p "$sys32"
pe() { printf 'MZ%062d%s' 0 "$2" > "$sys32/$1.dll"; }
is "empty prefix overrides nothing" "" "$(native_vc_runtime)"
pe vcruntime140 "Wine builtin DLL"
pe msvcp140_2 "Wine builtin DLL"
is "Wine's own copies are left alone" "" "$(native_vc_runtime)"
pe msvcp140_2 "This program cannot be run in DOS mode."
pe vcruntime140_1 "This program cannot be run in DOS mode."
: > "$sys32/msvcp140.dll"
is "Microsoft's copies load first" "msvcp140=n,b;msvcp140_2=n,b;vcruntime140_1=n,b;" "$(native_vc_runtime)"
rm -rf "$vc_work"

echo "== graphics overlay and launcher environment =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_root="$work/runtime"
log=/dev/null
graphics=$(sed -n '/^unset HADRON_DLL_OVERLAY /,/^echo "graphics:/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$graphics" ] && [ -n "$forward" ] || { echo "FAIL: runner environment blocks not found"; exit 1; }
unset HADRON_GRAPHICS HADRON_DDRAW
eval "$graphics"
is "a runtime without backends leaves the overlay unset" "" "${HADRON_DLL_OVERLAY:-}"
mkdir -p "$np_root/lib/dxmt"
eval "$graphics"
is "a runtime from before lib/graphics still gets DXMT" "$np_root/lib/dxmt" "${HADRON_DLL_OVERLAY:-}"
mkdir -p "$np_root/lib/graphics/dxmt" "$np_root/lib/graphics/d9vk" "$np_root/lib/graphics/dxvk" \
  "$np_root/lib/graphics/dxvk1" "$np_root/lib/graphics/ddraw" "$np_root/lib/graphics/d3dmetal"
eval "$graphics"
is "DXMT with D3D8/9 on DXVK is the default" "$np_root/lib/graphics/dxmt:$np_root/lib/graphics/d9vk" "${HADRON_DLL_OVERLAY:-}"
is "helpers inherit the overlay" "$np_root/lib/graphics/dxmt:$np_root/lib/graphics/d9vk" "$(sh -c 'printf %s "$HADRON_DLL_OVERLAY"')"
mkdir -p "$np_root/share/vulkan/icd.d"
touch "$np_root/share/vulkan/icd.d/MoltenVK_icd.json" "$np_root/share/vulkan/icd.d/kosmickrisp_icd.json"
unset VK_DRIVER_FILES
eval "$graphics"
is "D3D8/9 on DXVK runs on KosmicKrisp" "$np_root/share/vulkan/icd.d/kosmickrisp_icd.json" "${VK_DRIVER_FILES:-}"
unset VK_DRIVER_FILES
HADRON_GRAPHICS=dxvk
eval "$graphics"
is "dxvk picks DXVK 3.1" "$np_root/lib/graphics/dxvk" "${HADRON_DLL_OVERLAY:-}"
is "DXVK 3.1 runs on KosmicKrisp" "$np_root/share/vulkan/icd.d/kosmickrisp_icd.json" "${VK_DRIVER_FILES:-}"
unset VK_DRIVER_FILES
HADRON_GRAPHICS=dxvk1
eval "$graphics"
is "DXVK 1.10 runs on MoltenVK" "$np_root/share/vulkan/icd.d/MoltenVK_icd.json" "${VK_DRIVER_FILES:-}"
VK_DRIVER_FILES=/mine.json
eval "$graphics"
is "a driver from the launch options wins" "/mine.json" "${VK_DRIVER_FILES:-}"
unset VK_DRIVER_FILES
HADRON_GRAPHICS=dxvk1
eval "$graphics"
is "dxvk1 picks DXVK 1.10" "$np_root/lib/graphics/dxvk1" "${HADRON_DLL_OVERLAY:-}"
is "only D3DMetal loads libd3dshared" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
unset VK_DRIVER_FILES
HADRON_GRAPHICS=d3dmetal
eval "$graphics"
is "d3dmetal picks D3DMetal with D3D8/9 on DXVK" "$np_root/lib/graphics/d3dmetal:$np_root/lib/graphics/d9vk" "${HADRON_DLL_OVERLAY:-}"
is "D3DMetal gets libd3dshared loaded early" "$np_root/lib/graphics/d3dmetal/x86_64-unix/libd3dshared.dylib" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
is "D3D8/9 beside D3DMetal runs on KosmicKrisp" "$np_root/share/vulkan/icd.d/kosmickrisp_icd.json" "${VK_DRIVER_FILES:-}"
HADRON_GRAPHICS=dxvk1
eval "$graphics"
is "switching away from D3DMetal drops libd3dshared" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
rmdir "$np_root/lib/graphics/d3dmetal"
HADRON_GRAPHICS=d3dmetal
eval "$graphics"
is "d3dmetal falls back to DXMT where the runtime lacks it" "$np_root/lib/graphics/dxmt:$np_root/lib/graphics/d9vk" "${HADRON_DLL_OVERLAY:-}"
is "and then loads no libd3dshared" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
mkdir "$np_root/lib/graphics/d3dmetal"
rm "$np_root/share/vulkan/icd.d/kosmickrisp_icd.json"
rmdir "$np_root/lib/graphics/dxmt" "$np_root/lib/graphics/d3dmetal" "$np_root/lib/graphics/d9vk" \
  "$np_root/lib/graphics/dxvk" "$np_root/lib/dxmt"
for wanted in dxmt d3dmetal; do
  unset VK_DRIVER_FILES
  HADRON_GRAPHICS=$wanted HADRON_DDRAW=""
  eval "$graphics"
  is "$wanted falls back to DXVK 1.10 where DXMT is missing too, as on arm64" "$np_root/lib/graphics/dxvk1" "${HADRON_DLL_OVERLAY:-}"
  is "that fallback runs on MoltenVK" "$np_root/share/vulkan/icd.d/MoltenVK_icd.json" "${VK_DRIVER_FILES:-}"
done
HADRON_GRAPHICS=wined3d
eval "$graphics"
is "wined3d stays Wine's own Direct3D there" "" "${HADRON_DLL_OVERLAY:-}"
unset VK_DRIVER_FILES
HADRON_GRAPHICS=dxvk
eval "$graphics"
is "without KosmicKrisp, as on arm64, DXVK runs on MoltenVK" "$np_root/share/vulkan/icd.d/MoltenVK_icd.json" "${VK_DRIVER_FILES:-}"
HADRON_GRAPHICS=wined3d HADRON_DDRAW=cnc-ddraw
eval "$graphics"
is "wined3d leaves Wine's own Direct3D, cnc-ddraw adds itself" "$np_root/lib/graphics/ddraw" "${HADRON_DLL_OVERLAY:-}"
HADRON_DDRAW=""
eval "$graphics"
is "wined3d alone leaves Wine's own Direct3D" "" "${HADRON_DLL_OVERLAY:-}"
unset HADRON_GRAPHICS
DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=2.0"
UNRELATED_SETTING=1
export DXMT_CONFIG UNRELATED_SETTING
set --
eval "$forward"
forwarded=""
for arg in "$@"; do
  case "$arg" in DXMT_CONFIG=*) forwarded=${arg#*=} ;; UNRELATED_SETTING=*) forwarded=unrelated ;; esac
done
is "the game launcher receives DXMT settings as one argument" "d3d11.metalSpatialUpscaleFactor=2.0" "$forwarded"
# macOS sed stops at the first invalid UTF-8 value.
# shellcheck disable=SC2016 # The stub and loop expand inside the child shell.
after_bad=$(env -i PATH="$PATH" LANG=en_US.UTF-8 DXVK_HUD=1 sh -c '
  env() { printf "A_BAD=a\377b\nDXVK_HUD=1\n"; }
  f=$1; set --; eval "$f"; printf "%s " "$@"' sh "$forward")
is "settings after a non-UTF-8 value are forwarded" "--env DXVK_HUD=1 " "$after_bad"

echo "== Rosetta-only settings on arm64 Wine =="
drop=$(sed -n '/^np_dropped=""$/,/^fi$/p' "$SRC")
[ -n "$drop" ] || { echo "FAIL: the arm64 settings block was not found"; exit 1; }
defaults=$(sed -n '/^np_from_defaults() {$/,/^np_dropped=""$/p' "$SRC")
[ -n "$defaults" ] || { echo "FAIL: the defaults block was not found"; exit 1; }
verb=run
eval "$defaults"
drop_at=$(grep -n '^np_dropped=""$' "$SRC" | cut -d: -f1)
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward_at=$(grep -n '^for name in $(env ' "$SRC" | cut -d: -f1)
[ "$drop_at" -lt "$forward_at" ] ||
  bad "the arm64 settings block runs before the forwarding loop" "< $forward_at" "$drop_at"
seen() { sh -c 'env | sed -nE "s/^(HADRON_GRAPHICS|D3DM_[A-Z0-9_]*|DXMT_[A-Z0-9_]*|ROSETTA_[A-Z0-9_]*)=.*/\1/p" | sort | tr "\n" " "'; }
for name in $(seen); do unset -v "$name"; done
set_all() { export HADRON_GRAPHICS=dxmt D3DM_ENABLE_METALFX=1 ROSETTA_ADVERTISE_AVX=0 DXMT_CONFIG=x; }
set_all
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine keeps every setting" \
  "D3DM_ENABLE_METALFX DXMT_CONFIG HADRON_GRAPHICS ROSETTA_ADVERTISE_AVX " "$(seen)"
is "x86_64 Wine logs nothing" "" "$np_dropped"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "D3DMetal and Rosetta settings leave the environment" "DXMT_CONFIG HADRON_GRAPHICS " "$(seen)"
is "the run log names what was ignored" \
  "D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX" "$np_dropped"
set_all
unset -v D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX
eval "$drop"
is "other settings stay" "DXMT_CONFIG HADRON_GRAPHICS " "$(seen)"
is "nothing to ignore logs nothing" "" "$np_dropped"
unset -v HADRON_GRAPHICS DXMT_CONFIG

echo "== Rosetta AVX =="
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine turns it on" "1" "$ROSETTA_ADVERTISE_AVX"
is "the default is logged as the default" "default" "$avx_from"
is "helpers inherit it" "1" "$(sh -c 'printf %s "$ROSETTA_ADVERTISE_AVX"')"
ROSETTA_ADVERTISE_AVX=0
eval "$drop"
is "a launch option of 0 is kept" "0" "$ROSETTA_ADVERTISE_AVX"
is "a launch option is logged as one" "environment" "$avx_from"
ROSETTA_ADVERTISE_AVX=
eval "$drop"
is "an empty launch option turns it on" "1" "$ROSETTA_ADVERTISE_AVX"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "arm64 Wine leaves it unset" "unset" "${ROSETTA_ADVERTISE_AVX-unset}"

echo "== FEX reduced x87 precision =="
unset -v FEX_X87REDUCEDPRECISION
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine leaves it unset" "unset" "${FEX_X87REDUCEDPRECISION-unset}"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "arm64 Wine turns it on" "1" "$FEX_X87REDUCEDPRECISION"
is "the default is logged as the default" "default" "$fex_from"
is "helpers inherit it" "1" "$(sh -c 'printf %s "$FEX_X87REDUCEDPRECISION"')"
FEX_X87REDUCEDPRECISION=0
eval "$drop"
is "a launch option of 0 is kept" "0" "$FEX_X87REDUCEDPRECISION"
is "a launch option is logged as one" "environment" "$fex_from"
FEX_X87REDUCEDPRECISION=
eval "$drop"
is "an empty launch option is kept" "" "$FEX_X87REDUCEDPRECISION"
export FEX_X87REDUCEDPRECISION=0 FEX_MULTIBLOCK=0
set --
eval "$forward"
fex_args=""
for arg in "$@"; do
  case "$arg" in FEX_*) fex_args="$fex_args$arg
" ;; esac
done
is "FEX settings reach the game" "FEX_MULTIBLOCK=0 FEX_X87REDUCEDPRECISION=0 " "$(printf %s "$fex_args" | sort | tr '\n' ' ')"
unset -v FEX_X87REDUCEDPRECISION FEX_MULTIBLOCK

echo "== Default Compatibility Settings =="
np_support="$work/support"
mkdir -p "$np_support"
cat > "$np_support/defaults-rosetta" <<'EOF'
MTL_HUD_ENABLED=1
HADRON_RAW_CONTROLLERS=1
ROSETTA_ADVERTISE_AVX=0
HADRON_GRAPHICS=dxmt
DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5
FEX_X87REDUCEDPRECISION=0
HADRON_GRAPHICS=vulkan
HADRON_RETINA=yes
DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1;touch x
WINEDEBUG=+all
FOO=$(touch "$work/ran")

EOF
printf 'D3DM_ENABLE_METALFX=1\nHADRON_GRAPHICS=d3dmetal\nHADRON_RAW_CONTROLLERS=1\nFEX_X87REDUCEDPRECISION=0' \
  > "$np_support/defaults-fex"
keys="MTL_HUD_ENABLED HADRON_RAW_CONTROLLERS ROSETTA_ADVERTISE_AVX HADRON_GRAPHICS DXMT_CONFIG \
FEX_X87REDUCEDPRECISION HADRON_RETINA D3DM_ENABLE_METALFX WINEDEBUG FOO"
clear() { for k in $keys; do unset -v "$k"; done; }
clear
wine_unix="/R R/lib/wine/x86_64-unix"
verb=waitforexitandrun
eval "$defaults"
is "unset settings take the default" "1 1 0 dxmt" \
  "$MTL_HUD_ENABLED $HADRON_RAW_CONTROLLERS $ROSETTA_ADVERTISE_AVX $HADRON_GRAPHICS"
is "the default factor is the DXMT_CONFIG" "d3d11.metalSpatialUpscaleFactor=1.5" "${DXMT_CONFIG-}"
is "the game gets them" "1" "$(sh -c 'printf %s "$MTL_HUD_ENABLED"')"
is "lines that are not settings for this runner are skipped" "unset unset unset unset" \
  "${FEX_X87REDUCEDPRECISION-unset} ${HADRON_RETINA-unset} ${WINEDEBUG-unset} ${FOO-unset}"
is "nothing in the file runs" "absent" "$([ -e "$work/ran" ] && echo ran || echo absent)"
is "the run log names what came from the defaults" \
  "MTL_HUD_ENABLED=1 HADRON_RAW_CONTROLLERS=1 ROSETTA_ADVERTISE_AVX=0 HADRON_GRAPHICS=dxmt DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5" \
  "$np_defaulted"
is "the run log names the file" "defaults-rosetta" "${np_defaults_file##*/}"
eval "$drop"
is "a defaulted AVX2 is logged as one" "defaults-rosetta" "$avx_from"
is "a defaulted AVX2 keeps its 0" "0" "$ROSETTA_ADVERTISE_AVX"
if np_from_defaults HADRON_RAW_CONTROLLERS; then raw=yes; else raw=no; fi
is "a setting knows it came from the defaults" "yes" "$raw"

clear
export MTL_HUD_ENABLED=0 HADRON_GRAPHICS=dxvk DXMT_CONFIG="d3d11.preferredMaxFrameRate=60" ROSETTA_ADVERTISE_AVX=1
eval "$defaults"
is "the game's settings win" "0 1" "$MTL_HUD_ENABLED $ROSETTA_ADVERTISE_AVX"
is "the game's backend wins" "dxvk" "${HADRON_GRAPHICS-unset}"
is "the default factor joins the game's DXMT_CONFIG" \
  "d3d11.preferredMaxFrameRate=60;d3d11.metalSpatialUpscaleFactor=1.5" "$DXMT_CONFIG"
eval "$drop"
is "a game AVX2 is logged as the game's" "environment" "$avx_from"
if np_from_defaults MTL_HUD_ENABLED; then hud=yes; else hud=no; fi
is "a game setting is not from the defaults" "no" "$hud"
clear
export DXMT_CONFIG="a=1; d3d11.metalSpatialUpscaleFactor = 3.0"
eval "$defaults"
is "the game's factor wins" "a=1; d3d11.metalSpatialUpscaleFactor = 3.0" "$DXMT_CONFIG"
clear
cp "$np_support/defaults-rosetta" "$work/rosetta.keep"
printf 'DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=.\nDXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1234567\nDXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=\n' \
  > "$np_support/defaults-rosetta"
eval "$defaults"
is "factors the Settings page would refuse are skipped" "unset" "${DXMT_CONFIG-unset}"
mv "$work/rosetta.keep" "$np_support/defaults-rosetta"

clear
verb=run
eval "$defaults"
is "helpers get no defaults" "unset" "${MTL_HUD_ENABLED-unset}"

clear
verb=waitforexitandrun
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$defaults"
is "arm64 Wine reads the FEX file" "defaults-fex" "${np_defaults_file##*/}"
is "a last line without a newline is read" "1 0" "$HADRON_RAW_CONTROLLERS $FEX_X87REDUCEDPRECISION"
is "FEX skips the Rosetta-only settings" "unset unset" "${D3DM_ENABLE_METALFX-unset} ${HADRON_GRAPHICS-unset}"
eval "$drop"
is "a defaulted x87 is logged as one" "defaults-fex" "$fex_from"
clear
rm -f "$np_support/defaults-fex"
eval "$defaults"
is "no file sets nothing" "unset" "${HADRON_RAW_CONTROLLERS-unset}"
printf 'HADRON_RAW_CONTROLLERS=1\n' > "$np_support/defaults-fex"
chmod 000 "$np_support/defaults-fex"
for sh in /bin/sh /bin/dash; do
  [ -x "$sh" ] || continue
  # shellcheck disable=SC2016
  is "an unreadable file is skipped by $sh, the launch goes on" "went on unset" \
    "$(np_support="$np_support" wine_unix="$wine_unix" verb="$verb" np_block="$defaults" \
      "$sh" -c 'set -e; eval "$np_block"; echo "went on ${HADRON_RAW_CONTROLLERS-unset}"' 2>/dev/null)"
done
chmod 644 "$np_support/defaults-fex"
rm -f "$np_support/defaults-fex"

echo "== Per-build defaults =="
printf 'HADRON_RAW_CONTROLLERS=1\nFEX_X87REDUCEDPRECISION=0\n' > "$np_support/defaults-fex"
printf 'MTL_HUD_ENABLED=1\nFEX_X87REDUCEDPRECISION=1\n' > "$np_support/defaults-override-26.1-fex"
printf 'HADRON_RETINA=1\n' > "$np_support/defaults-override-26.1-rosetta"
clear; unset -v MTL_HUD_ENABLED HADRON_RETINA
np_build=26.1 np_flavor=fex
eval "$defaults"
is "a build's own file replaces the runner's" "defaults-override-26.1-fex" "${np_defaults_file##*/}"
is "the build's settings apply, the runner's do not" "1 1 unset" \
  "${MTL_HUD_ENABLED-unset} $FEX_X87REDUCEDPRECISION ${HADRON_RAW_CONTROLLERS-unset}"
clear; unset -v MTL_HUD_ENABLED
np_build=27.0
eval "$defaults"
is "a build without its own file, like a new one, uses the runner's" "defaults-fex 1" \
  "${np_defaults_file##*/} ${HADRON_RAW_CONTROLLERS-unset}"
clear
: > "$np_support/defaults-override-27.0-fex"
eval "$defaults"
is "an empty build file means no defaults for that build" "unset" "${HADRON_RAW_CONTROLLERS-unset}"
rm -f "$np_support/defaults-override-27.0-fex"
clear; unset -v HADRON_RETINA
np_build=26.1 np_flavor=rosetta wine_unix="/R R/lib/wine/x86_64-unix"
eval "$defaults"
is "the same build on Rosetta reads its Rosetta file" "defaults-override-26.1-rosetta 1" \
  "${np_defaults_file##*/} ${HADRON_RETINA-unset}"
clear; unset -v HADRON_RETINA
np_build="" np_flavor=""
eval "$defaults"
is "no build reads the runner's file" "defaults-rosetta" "${np_defaults_file##*/}"
rm -f "$np_support/defaults-fex" "$np_support/defaults-override-26.1-fex" "$np_support/defaults-override-26.1-rosetta"
unset -v np_build np_flavor
clear; unset -v MTL_HUD_ENABLED HADRON_RETINA
verb=run

if [ "$fails" -eq 0 ]; then
	echo "==> envcheck: all assertions hold"
else
	echo "==> envcheck: $fails failed"
	exit 1
fi
