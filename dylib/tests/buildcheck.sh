#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "buildcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in prefix_machine last_wine_build note_other_build claim_prefix; do
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
is "a newer runtime takes over an older runtime's prefix" "status=0
moves from Hadron Wine 11.15 to
wine-12.0-arm64" "$(launch wine-12.0-arm64 "" "wine-11.15
Hadron Wine 11.15
")"

echo "== alerts =="
alert=$(extract show_alert)
[ -n "$alert" ] || { echo "FAIL: show_alert not found in $SRC"; exit 1; }
data=$(mktemp -d "$work/compatdata.XXXXXX")
(
	verb=waitforexitandrun
	# shellcheck disable=SC2329 # show_alert runs this in place of the real dialog
	osascript() {
		if /usr/bin/lockf -s -t 0 "$data/.hadron-prefix.lock" true; then
			echo free > "$data/during-alert"
		else
			echo held > "$data/during-alert"
		fi
	}
	eval "$alert"
	exec 8>> "$data/.hadron-prefix.lock"
	/usr/bin/lockf -s -t 0 8
	show_alert "title" "message"
)
is "an open alert does not keep the prefix locked" "free" "$(cat "$data/during-alert" 2>/dev/null)"

echo "== rebuild choices =="
rebuild="$(extract run_rebuild)
$(extract rebuild_prefix)"
mkdir -p "$work/app with spaces"
cat > "$work/app with spaces/HadronApp" <<'SH'
#!/bin/sh
data=$2
[ -z "$DYLD_INSERT_LIBRARIES$TEST_LEAK" ] || exit 65
printf '%s\n' "$@" > "$data/arguments"
printf '%s' "$HADRON_REBUILD_WINDOW" > "$data/window"
/usr/bin/lockf -s -t 0 "$data/.hadron-prefix.lock" true || exit 66
[ ! -f "$data/slow" ] || sleep 3
echo finished > "$data/finished"
exit "$(cat "$data/status")"
SH
chmod +x "$work/app with spaces/HadronApp"
printf '%s' "$work/app with spaces/HadronApp" > "$np_support/app-executable"

rebuild_case() {
	choice=$1 command_status=$2 launch_verb=$3 skip=${4:-}
	data=$(mktemp -d "$work/compat data.XXXXXX")
	(
		export TEST_LEAK=1
		printf '%s' "$command_status" > "$data/status"
		STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=selected-build np_flavor=rosetta
		np_display='Selected "tool" with \ and a newline
in its name'
		verb=$launch_verb log="$data/log"
		# shellcheck disable=SC2329
		osascript() { cat > "$data/prompt"; shift; printf '%s\n' "$@" > "$data/prompt-args"; [ "$choice" != cancel ] || return 1; printf '%s\n' "$choice"; }
		# shellcheck disable=SC2329
		show_alert() { echo "$1" >> "$data/alerts"; }
		# shellcheck disable=SC2329
		show_rebuild_failure() { echo "rebuild failed" >> "$data/alerts"; }
		# shellcheck disable=SC2329
		prepare_prefix_directory() { [ -z "${relock_fails:-}" ] || [ ! -f "$data/arguments" ] || return 1; exec 8>> "$data/.hadron-prefix.lock"; /usr/bin/lockf -s -t 0 8; echo locked >> "$data/checks"; }
		# shellcheck disable=SC2329
		note_other_build() { echo build >> "$data/checks"; }
		# shellcheck disable=SC2329
		convert_foreign_prefix() { echo arch >> "$data/checks"; }
		eval "$rebuild"
		prepare_prefix_directory
		: > "$data/checks"
		echo stale > "$data/hadron-switch"
		rebuild_prefix 'A title' 'Previous "tool" with \ and a newline
in its name' ${skip:+"$skip"}
		echo launched >> "$data/checks"
	) && status=0 || status=$?
}
rebuild_case 'Backup & Rebuild Prefix' 0 waitforexitandrun
is "backup rebuild succeeds with lock released for the app" 0 "$status"
is "selected tool and backup choice reach the app as arguments" "--rebuild-prefix
$data
chosen
selected-build
rosetta
keep-backup" "$(cat "$data/arguments")"
is "launch retakes its lock and rechecks both mismatches" "locked
build
arch
launched" "$(cat "$data/checks")"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "rebuild without backup succeeds" 0 "$status"
is "rebuild without backup passes discard-backup" discard-backup "$(tail -1 "$data/arguments")"
rebuild_case cancel 0 waitforexitandrun
is "cancel stops the launch" 1 "$status"
is "cancel never calls the app" no "$([ -f "$data/arguments" ] && echo yes || echo no)"
rebuild_case 'Rebuild Prefix' 7 waitforexitandrun
is "a failed rebuild stops the launch" 1 "$status"
is "a failed rebuild never continues launch preparation" "" "$(cat "$data/checks")"
is "a failed rebuild says so" "rebuild failed" "$(cat "$data/alerts")"
rebuild_case 'Rebuild Prefix' 0 run
is "install helpers refuse silently" 1 "$status"
is "install helpers never prompt" no "$([ -f "$data/prompt" ] && echo yes || echo no)"
rebuild_case cancel 0 waitforexitandrun 'Launch Without Rebuilding'
is "skipping an offered rebuild goes on with the launch" 0 "$status"
is "a skipped rebuild retakes the lock and launches" "locked
launched" "$(cat "$data/checks")"
is "a skipped rebuild never calls the app" no "$([ -f "$data/arguments" ] && echo yes || echo no)"
is "the skip button is labelled as asked" "Launch Without Rebuilding" "$(tail -2 "$data/prompt-args" | head -1)"
is "a missing Hadron icon falls back to caution" "" "$(tail -1 "$data/prompt-args")"
rebuild_case 'Rebuild Prefix' 0 run 'Launch Without Rebuilding'
is "install helpers skip an offered rebuild silently" 0 "$status"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "the app gets none of Steam's environment" 0 "$status"
is "a rebuild from Play asks the app for its progress window" 1 "$(cat "$data/window")"
is "a finished rebuild clears the switch record" no "$([ -f "$data/hadron-switch" ] && echo yes || echo no)"
relock_fails=1
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
relock_fails=
is "a launch that cannot retake its lock after a rebuild stops" 1 "$status"
is "and says another launch has the prefix" "Prefix rebuilt" "$(cat "$data/alerts")"
printf '%s' "$work/missing" > "$np_support/app-executable"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "a moved or missing app stops the launch" 1 "$status"
is "a missing app explains how to repair" "Couldn't find the Hadron app" "$(cat "$data/alerts")"

data=$(mktemp -d "$work/stopped.XXXXXX")
printf 0 > "$data/status"
: > "$data/slow"
(
	STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=b np_flavor=rosetta log="$data/log"
	eval "$rebuild"
	run_rebuild "$work/app with spaces/HadronApp" keep-backup
) &
waiter=$!
sleep 1
pkill -KILL -P "$waiter" 2>/dev/null || true
kill -KILL "$waiter" 2>/dev/null || true
sleep 4
is "Stop kills the launch but not the rebuild under it" finished "$(cat "$data/finished" 2>/dev/null)"

echo "== crashes after a switch =="
health_functions="$(extract prefix_machine)
$(extract note_other_build)
$(extract preview_name)
$(extract running_name)
$(extract last_wine_build)
$(extract session_health)
$(extract set_switch_state)
$(extract record_session)
$(extract offer_switch_rebuild)"
crash_log="$work/crash.log"
printf 'wine: Unhandled page fault on execute access to 0000000001A23DA0\n' > "$crash_log"
clean_log="$work/clean.log"
printf 'fixme:ntdll:stub\n' > "$clean_log"
health() {
	(
		log=/dev/null
		eval "$health_functions"
		session_health "$@"
	)
}
is "a crash in the first minute is a failure" failed "$(health "$crash_log" 5 0)"
is "a crash after a minute says nothing" unknown "$(health "$crash_log" 300 0)"
is "a crash Steam stopped says nothing" unknown "$(health "$crash_log" 5 1)"
is "a session without a crash is healthy" healthy "$(health "$clean_log" 3 0)"
is "a long session Steam stopped is healthy" healthy "$(health "$clean_log" 600 1)"
is "a short session Steam stopped says nothing" unknown "$(health "$clean_log" 5 1)"
is "a missing log is healthy" healthy "$(health "$work/none.log" 5 0)"

# Each step is one launch: switch to a build, then a session that ends healthy or failed.
switch_world() {
	data=$(mktemp -d "$work/switch.XXXXXX")
	[ -z "$1" ] || printf '%s\n' "$1" > "$data/hadron-healthy"
	printf 'old-build\nOld Tool\n' > "$data/hadron-build"
}
session() {
	(
		STEAM_COMPAT_DATA_PATH=$data np_build=$1 np_display="New Tool" log=/dev/null verb=waitforexitandrun
		# shellcheck disable=SC2329
		rebuild_prefix() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$data/offers"; }
		eval "$health_functions"
		note_other_build
		printf '%s\nNew Tool\n' "$1" > "$data/hadron-build"
		offer_switch_rebuild
		record_session "$2" "$3" 0
	)
}
state() { sed -n 3p "$data/hadron-switch" 2>/dev/null || echo none; }

switch_world old-build
session new-build "$clean_log" 5
is "a switch from a build that worked is tracked" 1 "$(state)"
session new-build "$clean_log" 5
is "two healthy sessions clear the record" none "$([ -f "$data/hadron-switch" ] && state || echo none)"
is "the healthy build is remembered" new-build "$(cat "$data/hadron-healthy")"

switch_world old-build
session new-build "$crash_log" 5
is "a crash after the switch is recorded" failed "$(state)"
is "nothing is offered in the session that crashed" no "$([ -f "$data/offers" ] && echo yes || echo no)"
session new-build "$crash_log" 5
is "the next launch offers a rebuild for the selected tool" "This game may need its prefix rebuilt|Something appears to have gone wrong the last time you ran this game! Rebuilding the prefix may fix it.

Rebuild your prefix for New Tool? Your save games will be preserved and not lost.|Launch Without Rebuilding" "$(cat "$data/offers")"
is "the offer is made once per switch" none "$([ -f "$data/hadron-switch" ] && state || echo none)"
session new-build "$crash_log" 5
is "a crash after the offer is not offered again" 1 "$(grep -c "^This game may need" "$data/offers")"

switch_world ""
session new-build "$crash_log" 5
is "a game never seen working is not blamed on the switch" none "$([ -f "$data/hadron-switch" ] && state || echo none)"
switch_world other-build
session new-build "$crash_log" 5
is "a game seen working on another build is not blamed on this switch" none "$([ -f "$data/hadron-switch" ] && state || echo none)"

if [ "$fails" -eq 0 ]; then
	echo "==> buildcheck: all assertions hold"
else
	echo "==> buildcheck: $fails failed"
	exit 1
fi
