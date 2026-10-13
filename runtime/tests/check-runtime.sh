#!/bin/sh
# Smoke test for a staged runtime, without Steam.
#
#   ./check-runtime.sh <runtime dir> [<steamclient dir>]
#
# Boots a fresh prefix, then checks the steamclient redirect (patch 0001) for 64 and
# 32 bit, that HTTPS works (it needs the network), and that DXMT loads through HADRON_DLL_OVERLAY (patch 0003). The redirect
# needs Valve's steamclient.dll and steamclient64.dll, taken from the bridge Hadron
# installs unless a directory with them is given, and is skipped without them.
# Needs mingw-w64.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
runtime="$(cd "${1:?usage: $0 <runtime dir> [<steamclient dir>]}" && pwd)"
valve="${2:-$HOME/Library/Application Support/hadron/bridge}"
have_valve=1
for dll in steamclient.dll steamclient64.dll; do
    [ -f "$valve/$dll" ] || have_valve=0
done

work=$(mktemp -d)
trap 'WINEPREFIX="$work/pfx" "$runtime/bin/wineserver" -k 2>/dev/null; rm -rf "$work"' EXIT
x86_64-w64-mingw32-gcc -O1 -o "$work/redirect64.exe" "$here/redirect.c"
i686-w64-mingw32-gcc -O1 -o "$work/redirect32.exe" "$here/redirect.c"
x86_64-w64-mingw32-gcc -O1 -o "$work/overlay64.exe" "$here/overlay.c"
x86_64-w64-mingw32-gcc -O1 -o "$work/tls64.exe" "$here/tls.c" -lwinhttp

WINEPREFIX="$work/pfx"
WINEDEBUG=-all
WINEDLLOVERRIDES="steamclient=n;steamclient64=n;lsteamclient=b"
export WINEPREFIX WINEDEBUG WINEDLLOVERRIDES
wine="$runtime/lib/wine/x86_64-unix/wine"

fails=0
check() {
    label=$1
    shift
    if out=$("$@" 2>&1); then
        printf '  ok    %s\n' "$label"
    else
        printf '  FAIL  %s\n%s\n' "$label" "$out"
        fails=$((fails + 1))
    fi
}

echo "== $(cat "$runtime/hadron-runtime" 2>/dev/null || echo "${runtime##*/}")"
check "a fresh prefix boots" "$wine" wineboot --init
"$runtime/bin/wineserver" -w
check "the profile is steamuser" test -d "$WINEPREFIX/drive_c/users/steamuser"
cd "$work"
if [ "$have_valve" -eq 1 ]; then
    # steamclient64 imports tier0_s64 and vstdlib_s64.
    for dll in steamclient.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll; do
        cp "$valve/$dll" "$work/"
    done
    check "steamclient64.dll goes to lsteamclient" "$wine" redirect64.exe
    check "steamclient.dll goes to lsteamclient" "$wine" redirect32.exe
else
    printf '  skip  the steamclient redirect, no Valve steamclient in %s\n' "$valve"
fi
check "HTTPS works through schannel" "$wine" tls64.exe
check "Wine's own d3d11 creates a device" "$wine" overlay64.exe
check "DXMT comes through the overlay" sh -c \
    "HADRON_DLL_OVERLAY='$runtime/lib/graphics/dxmt' '$wine' overlay64.exe | grep -q '^d3d11: dxmt'"
check "DXVK comes through the overlay" sh -c \
    "HADRON_DLL_OVERLAY='$runtime/lib/graphics/dxvk' '$wine' overlay64.exe | grep -q '^d3d11: dxvk'"

if [ "$fails" -eq 0 ]; then
    echo "==> all checks hold"
else
    echo "==> $fails failed"
    exit 1
fi
