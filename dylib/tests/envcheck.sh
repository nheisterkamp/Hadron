#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "envcheck: $SRC not present, skipped"; exit 0; }

strip() { sed 's/^[[:space:]]*//'; }
dllpath_line=$(grep 'export WINEDLLPATH=' "$SRC" | grep 'x86_64-windows' | strip)
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
graphics=$(sed -n '/^unset NOTPROTON_DLL_OVERLAY$/,/^echo "graphics:/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$graphics" ] && [ -n "$forward" ] || { echo "FAIL: runner environment blocks not found"; exit 1; }
unset NOTPROTON_GRAPHICS
eval "$graphics"
is "a runtime without DXMT leaves the overlay unset" "" "${NOTPROTON_DLL_OVERLAY:-}"
mkdir -p "$np_root/lib/dxmt"
eval "$graphics"
is "DXMT is the default" "$np_root/lib/dxmt" "${NOTPROTON_DLL_OVERLAY:-}"
is "helpers inherit the overlay" "$np_root/lib/dxmt" "$(sh -c 'printf %s "$NOTPROTON_DLL_OVERLAY"')"
NOTPROTON_GRAPHICS=wined3d
eval "$graphics"
is "wined3d leaves Wine's own Direct3D" "" "${NOTPROTON_DLL_OVERLAY:-}"
unset NOTPROTON_GRAPHICS
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
