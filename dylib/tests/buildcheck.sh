#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "buildcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in last_wine_build note_other_build claim_prefix; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

np_support="$work/support"
clone() {
	inf="$np_support/runners/$1/share/wine/wine.inf"
	mkdir -p "$(dirname "$inf")"
	: > "$inf"
	touch -t "$2" "$inf"
}
clone wine-11.15 202607151200
clone wine-12.0-arm64 202608211200
printf 'hadron-proton-wine-arm64\twine-12.0-arm64\tfex\tHadron Wine 12.0 (FEX)\nhadron-proton-wine\twine-11.15\trosetta\tHadron Wine 11.15\n' \
	> "$np_support/tools"
mtime() { stat -f %m "$np_support/runners/$1/share/wine/wine.inf"; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

launch() {
	build=$1 updated=$2 record=$3
	data=$(mktemp -d "$work/compatdata.XXXXXX")
	mkdir -p "$data/pfx"
	[ -z "$updated" ] || printf '%s\r\n' "$updated" > "$data/pfx/.update-timestamp"
	[ -z "$record" ] || printf '%s' "$record" > "$data/hadron-build"
	(
		STEAM_COMPAT_DATA_PATH=$data
		np_build=$build
		np_display="display of $build"
		np_root="$np_support/runners/$build"
		log="$data/out"
		eval "$functions"
		note_other_build
		claim_prefix
	) >> "$data/out" 2>&1 && status=0 || status=$?
	echo "status=$status"
	grep -o 'moves from .* to' "$data/out" || true
	[ ! -f "$data/hadron-build" ] || head -1 "$data/hadron-build"
}

echo "== prefixes from before the record =="
is "a fresh prefix is claimed" "status=0
wine-11.15" "$(launch wine-11.15 "" "")"
is "a prefix this build last updated is claimed" "status=0
wine-11.15" "$(launch wine-11.15 "$(mtime wine-11.15)" "")"
is "a prefix another runtime updated moves over, named" "status=0
moves from Hadron Wine 12.0 (FEX) to
wine-11.15" "$(launch wine-11.15 "$(mtime wine-12.0-arm64)" "")"
is "a prefix no runtime updated moves over" "status=0
moves from an earlier Wine runtime to
wine-11.15" "$(launch wine-11.15 1 "")"
is "updates the user disabled say nothing, so the prefix is claimed" "status=0
wine-11.15" "$(launch wine-11.15 disable "")"

clone wine-12.0 202608211200
is "a prefix either of two runtimes updated names neither" "status=0
moves from an earlier Wine runtime to
wine-11.15" "$(launch wine-11.15 "$(mtime wine-12.0)" "")"

echo "== prefixes with a record =="
is "the record wins over the Wine that updated the prefix" "status=0
wine-12.0-arm64" "$(launch wine-12.0-arm64 "$(mtime wine-11.15)" "wine-12.0-arm64
Hadron Wine 12.0 (FEX)
")"
is "a prefix recorded for another runtime moves over and is recorded anew" "status=0
moves from Hadron Wine 12.0 (FEX) to
wine-11.15" "$(launch wine-11.15 "" "wine-12.0-arm64
Hadron Wine 12.0 (FEX)
")"

if [ "$fails" -eq 0 ]; then
	echo "==> buildcheck: all assertions hold"
else
	echo "==> buildcheck: $fails failed"
	exit 1
fi
