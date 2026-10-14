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

if [ "$fails" -eq 0 ]; then
	echo "==> envcheck: all assertions hold"
else
	echo "==> envcheck: $fails failed"
	exit 1
fi
