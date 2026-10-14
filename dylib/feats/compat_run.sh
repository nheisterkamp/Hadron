#!/bin/sh
# hadron compatibility tool shim
set -e

verb="$1"
shift || true

# hook_launch.c passes the launch options through a shell before this script runs, matching
# Linux Steam. A NAME=value option placed ahead of %command% is an environment variable,
# and anything after %command% is a launch argument passed to the game.
launch_args="$*"

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

np_support="$HOME/Library/Application Support/hadron"
iconmaker="$np_support/iconmaker"

find_client_root() {
  client_root="$1"
  while [ -n "$client_root" ] && [ "$client_root" != "/" ] && [ ! -d "$client_root/appcache" ]; do
    client_root=$(dirname "$client_root")
  done
}

read_app_meta() {
  appinfo_tool="$np_support/appinfo"
  appinfo_vdf="$client_root/appcache/appinfo.vdf"
  meta_name=""
  meta_icon=""
  meta_clienticon=""
  if [ -x "$appinfo_tool" ] && [ -f "$appinfo_vdf" ]; then
    meta=$("$appinfo_tool" "$appinfo_vdf" "$app_id" 2>> "$log") || meta=""
    meta_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
    meta_icon=$(printf '%s\n' "$meta" | sed -n 's/^icon=//p')
    meta_clienticon=$(printf '%s\n' "$meta" | sed -n 's/^clienticon=//p')
    case "$meta_icon" in *[!0-9a-f]*) meta_icon="" ;; esac
    case "$meta_clienticon" in *[!0-9a-f]*) meta_clienticon="" ;; esac
  fi
}

resolve_icon() {
  set +e
  art_dir="$client_root/appcache/librarycache/$app_id"
  art=""
  ico=""
  if [ -n "$meta_clienticon" ]; then
    ico="$icon_root/clienticon-$meta_clienticon.ico"
    absent="$icon_root/clienticon-$meta_clienticon.absent"
    failed="$icon_root/clienticon-$meta_clienticon.failed"
    find "$icon_root" -maxdepth 1 -name 'clienticon-*'   ! -name "clienticon-$meta_clienticon.*" -delete 2>/dev/null || true
    find "$absent" -mtime +14 -delete 2>/dev/null || true
    find "$failed" -mmin +60 -delete 2>/dev/null || true
    if [ ! -s "$ico" ] && [ ! -f "$absent" ] && [ ! -f "$failed" ]; then
      url="https://shared.fastly.steamstatic.com/community_assets/images/apps/$app_id/$meta_clienticon.ico"
      code=$(curl -fsL --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$ico.new" "$url" 2>>"$log")
      magic=$(od -An -tx1 -N4 "$ico.new" 2>/dev/null | tr -d ' \n')
      if [ "$magic" = "00000100" ]; then
        mv -f "$ico.new" "$ico"
        echo "fetched client icon $meta_clienticon" >> "$log" 2>&1 || true
      else
        rm -f "$ico.new"
        if [ "$code" = "404" ]; then
          : > "$absent"
          echo "no client icon published for $meta_clienticon" >> "$log" 2>&1 || true
        else
          : > "$failed"
          echo "client icon fetch for $meta_clienticon failed (http ${code:-none}), will retry in an hour" >> "$log" 2>&1 || true
        fi
      fi
    fi
    [ -s "$ico" ] && art="$ico"
  fi
  if [ -z "$art" ] && [ -n "$meta_icon" ] && [ -f "$art_dir/$meta_icon.jpg" ]; then
    art="$art_dir/$meta_icon.jpg"
  fi
  if [ -z "$art" ]; then
    art=$(find "$art_dir" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null |   grep -E '/[0-9a-f]{40}\.jpg$' | head -1)
  fi
  # Capsule art (horrible) fallback if no icon at all exists...
  if [ -z "$art" ]; then
    for name in library_600x900.jpg header.jpg; do
      found=$(find "$art_dir" -name "$name" 2>/dev/null | head -1)
      [ -n "$found" ] && { art="$found"; break; }
    done
  fi
  # non-Steam shortcuts have no art, so (as a temporary measure while I think of
  # better ways to solve for this) let's use the icon in the EXE itself instead.
  if [ -z "$art" ] && [ -f "$target" ]; then
    case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
      *.exe) art="$target" ;;
    esac
  fi
  icon_source=""
  if [ -n "$art" ]; then
    icon_source="$art $(stat -f %m "$art" 2>/dev/null || echo 0)"
  fi
  icon_cache="$icon_root/game.icns"
  icon_status=1
  if [ -n "$art" ] && [ -s "$icon_cache" ] &&   [ "$(cat "$icon_root/hadron-icon.source" 2>/dev/null)" =   "$icon_source" ]; then
    icon_status=0
    echo "icon reused from $art" >> "$log" 2>&1 || true
  elif [ -n "$art" ] && [ -x "$iconmaker" ]; then
    if "$iconmaker" "$art" "$icon_cache" >> "$log" 2>&1; then
      icon_status=0
      printf '%s\n' "$icon_source" > "$icon_root/hadron-icon.source"
      echo "icon built from $art" >> "$log" 2>&1 || true
    elif [ "$art" = "$ico" ]; then
      # A cached .ico that iconmaker rejects is corrupt and passes the size
      # guard on every launch, so drop it to force a clean fetch next time.
      rm -f "$ico"
      echo "discarded unreadable client icon $meta_clienticon" >> "$log" 2>&1 || true
    fi
  fi
  set -e
  return $icon_status
}

case "$verb" in
  shortcut-icons)
    app_id="$1"
    case "$app_id" in ''|0|*[!0-9]*) exit 1 ;; esac
    case "$2" in /*) ;; *) exit 1 ;; esac
    find_client_root "$2"
    icon_root="$np_support/shortcut-icons/$app_id"
    mkdir -p "$icon_root"
    log="$icon_root/icon.log"
    : > "$log"
    target=""
    read_app_meta
    resolve_icon && "$iconmaker" --shortcuts "$app_id" "$icon_cache" "$2/steam.icns" >> "$log" 2>&1 || true
    exit 0
    ;;
esac

np_build=""
CDPATH=''
np_tool_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || np_tool_dir=""
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/build" ]; then
  read -r np_build < "$np_tool_dir/build" || np_build=""
fi
case "$np_build" in *[!A-Za-z0-9.-]*) np_build="" ;; esac
np_display=$(sed -n 's/.*"display_name"[[:space:]]*"\(.*\)".*/\1/p' \
  "$np_tool_dir/compatibilitytool.vdf" 2>/dev/null | head -1) || np_display=""
[ -n "$np_display" ] || np_display="Wine runtime ${np_build:-unknown}"
# The runtime the app copied from runtime/build-wine.sh's output.
np_root="$np_support/runners/$np_build"

wine_unix="$np_root/lib/wine/x86_64-unix"
wine_pe64="$np_root/lib/wine/x86_64-windows"
# An arm64 runtime, which runs x86 code with FEX, has aarch64 dirs instead.
if [ -d "$np_root/lib/wine/aarch64-unix" ]; then
  wine_unix="$np_root/lib/wine/aarch64-unix"
  wine_pe64="$np_root/lib/wine/aarch64-windows"
fi
WINELOADER="$wine_unix/wine"
WINESERVER="$np_root/bin/wineserver"
export WINELOADER WINESERVER

# arm64 Wine runs x86 code with FEX, not Rosetta, and has no D3DMetal, so their
# settings mean nothing there.
np_dropped=""
if [ "${wine_unix##*/}" = aarch64-unix ]; then
  for name in $(env | LC_ALL=C sed -nE 's/^(D3DM_[A-Z0-9_]*|ROSETTA_ADVERTISE_AVX)=.*/\1/p' | LC_ALL=C sort); do
    unset -v "$name"
    np_dropped="$np_dropped${np_dropped:+ }$name"
  done
fi

# Keeps Wine from inheriting the prefix and template locks (fd 8 and 9).
without_lock_fds() {
  "$@" 8>&- 9>&-
}

# If two WINEDLLPATH directories have the same DLL, Wine uses the one listed first.
export WINEDLLPATH="$wine_pe64:$wine_unix${WINEDLLPATH:+:$WINEDLLPATH}"
export PATH="$np_root/bin:$PATH"

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  log="$STEAM_COMPAT_DATA_PATH/hadron-run.log"
else
  log=/dev/null
fi
[ "$(stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ] \
  && : > "$log" || true
{
  echo "=== hadron run $(date) ==="
  echo "verb=$verb"
  echo "args:"; for a in "$@"; do printf '  [%s]\n' "$a"; done
  echo "cwd=$(pwd)"
  echo "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
  echo "STEAM_COMPAT_INSTALL_PATH=$STEAM_COMPAT_INSTALL_PATH"
  echo "STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID"
  echo "-- steam env passed through --"
  env | grep -iE '^(Steam|SDL_)' | sort
  [ -z "$np_dropped" ] || echo "ignored on arm64 Wine: $np_dropped"
} >> "$log" 2>&1 || true

stage_step="startup"
# shellcheck disable=SC2329 # the trap below invokes this
report_early_exit() {
  status=$?
  [ "$status" = 0 ] && return 0
  echo "=== aborted during $stage_step (exit $status) before launch ===" \
    >> "$log" 2>&1 || true
}
trap report_early_exit EXIT

while :; do
  case "$STEAM_COMPAT_INSTALL_PATH" in
    ?*/) STEAM_COMPAT_INSTALL_PATH="${STEAM_COMPAT_INSTALL_PATH%/}" ;;
    *) break ;;
  esac
done
export STEAM_COMPAT_INSTALL_PATH

app_id="$STEAM_COMPAT_APP_ID"
case "$app_id" in ''|0) app_id="$SteamAppId" ;; esac
case "$app_id" in ''|0) app_id=$(basename "$STEAM_COMPAT_DATA_PATH" 2>/dev/null) ;; esac
case "$app_id" in ''|*[!0-9]*) app_id=0 ;; esac
echo "app_id=$app_id (STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID)" >> "$log" 2>&1 || true

# Steam does not set SteamAppId or SteamGameId for helpers like the install-script
# evaluator. If they are set, SteamAPI_Init registers the helper as the running game so the
# real launch fails with AppError_16. Not applicable to non-Steam shortcuts, which come in
# as waitforexitandrun.
case "$verb" in
  waitforexitandrun)
    [ -n "$SteamAppId" ] || export SteamAppId="$app_id"
    [ -n "$SteamGameId" ] || export SteamGameId="$app_id"
    ;;
esac

prefix_machine() {
  dll="$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
  [ -f "$dll" ] || return 1
  off=$(od -A n -t u4 -j 60 -N 4 "$dll" 2>/dev/null | tr -d ' ')
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  sig=$(od -A n -t x1 -j "$off" -N 4 "$dll" 2>/dev/null | tr -d ' \n')
  [ "$sig" = 50450000 ] || return 1
  od -A n -t x2 -j "$((off + 4))" -N 2 "$dll" 2>/dev/null | tr -d ' \n'
}

# Steam passes "run" for helpers such as install scripts, which get no dialog.
show_alert() {
  [ "$verb" != run ] || return 0
  osascript >/dev/null 2>&1 <<APPLESCRIPT || true
display alert "$1" message "$2" as critical
APPLESCRIPT
}

# A quote or backslash in the text would end the AppleScript string early.
alert_safe() {
  # shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
  printf '%s' "$1" | tr -d '"\\'
}

# A wineserver another runtime left on this prefix would write its registry back over
# the conversion below. That runtime's own wineserver -k ends it and its processes,
# saving the registry; SIGTERM is the fallback.
stop_prefix_wineserver() {
  for pid in $(/usr/sbin/lsof -t -- "$WINEPREFIX" 2>/dev/null); do
    server=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$server" in
      /*/wineserver) ;;
      *) continue ;;
    esac
    echo "=== stopping $server ($pid), left by another runtime ===" >> "$log" 2>&1 || true
    without_lock_fds "$server" -k >> "$log" 2>&1 || kill -TERM "$pid" 2>/dev/null || continue
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 50 ]; do
      sleep 0.2
      tries=$((tries + 1))
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  done
  return 0
}

# A prefix moves between x86_64 (Rosetta) and arm64 (FEX) Wine in place: Wine's prefix
# update replaces the builtin DLLs in system32 with the other architecture's. Only the
# WoW64 emulator keys survive it, since wine.inf never overwrites them, so they are
# dropped for the update to write them again, and the update is forced.
convert_foreign_prefix() {
  case "${wine_unix##*/}" in
    aarch64-unix) want=aa64 ;;
    *) want=8664 ;;
  esac
  have=$(prefix_machine) || return 0
  [ "$have" = "$want" ] && return 0
  [ -f "$WINEPREFIX/system.reg" ] || return 0
  echo "=== prefix ntdll is $have and this compatibility tool wants $want, Wine converts it in place ===" >> "$log" 2>&1 || true
  stop_prefix_wineserver
  reg="$WINEPREFIX/system.reg"
  awk '/^\[Software\\\\Microsoft\\\\Wow64\\\\[^]]*\]/ { skip = 1; next }
       skip && /^\[/ { skip = 0 }
       !skip' "$reg" > "$reg.hadron-new" && mv -f "$reg.hadron-new" "$reg" \
    || { rm -f "$reg.hadron-new"; echo "=== could not reset the WoW64 keys ===" >> "$log" 2>&1 || true; }
  printf '0\n' > "$WINEPREFIX/.update-timestamp" 2>/dev/null || true
}

last_wine_build() {
  updated_file="$STEAM_COMPAT_DATA_PATH/pfx/.update-timestamp"
  [ -r "$updated_file" ] || return 0
  read -r updated _ < "$updated_file" || true
  # Wine ends the line with CRLF.
  updated=${updated%"$(printf '\r')"}
  case "$updated" in '' | *[!0-9]*) return 0 ;; esac
  [ "$updated" = "$(stat -f %m "$np_root/share/wine/wine.inf" 2>/dev/null)" ] && return 0
  had_build=other
  had_display="an earlier Wine runtime"
  for inf in "$np_support"/runners/*/share/wine/wine.inf; do
    [ "$(stat -f %m "$inf" 2>/dev/null)" = "$updated" ] || continue
    if [ "$had_build" != other ]; then
      had_build=other
      had_display="an earlier Wine runtime"
      break
    fi
    had_build=${inf#"$np_support/runners/"}
    had_build=${had_build%%/*}
    had_display=$(awk -F '\t' -v b="$had_build" '$2 == b { print $4; exit }' \
      "$np_support/tools" 2>/dev/null) || had_display=""
  done
}

# Wine updates a prefix in place when the runtime changes, as Proton does, so a game can
# move between runtimes, and convert_foreign_prefix moves it to another arch.
note_other_build() {
  record="$STEAM_COMPAT_DATA_PATH/hadron-build"
  had_build=""
  had_display=""
  if [ -r "$record" ]; then
    {
      read -r had_build || true
      read -r had_display || true
    } < "$record"
  else
    last_wine_build
  fi
  if [ -n "$had_build" ] && [ "$had_build" != "$np_build" ]; then
    echo "=== prefix moves from ${had_display:-build $had_build} to $np_display, Wine updates it in place ===" >> "$log" 2>&1 || true
  fi
}

claim_prefix() {
  [ -r "$STEAM_COMPAT_DATA_PATH/hadron-build" ] \
    || echo "=== prefix claimed by build $np_build ===" >> "$log" 2>&1 || true
  printf '%s\n%s\n' "$np_build" "$np_display" > "$STEAM_COMPAT_DATA_PATH/hadron-build" 2>/dev/null \
    || echo "=== could not record build $np_build in the prefix ===" >> "$log" 2>&1 || true
}
# Steam cloud related
merge_user_dir() {
  src=$1
  dst=$2
  failed=
  set -- ""
  while [ "$#" -gt 0 ]; do
    rest=$1
    shift
    src_dir="$src$rest"
    dst_dir="$dst$rest"
    if [ ! -r "$src_dir" ] || [ ! -x "$src_dir" ]; then failed=1; continue; fi
    if [ -L "$dst_dir" ]; then failed=1; continue; fi
    probe=$dst_dir
    through=
    while [ -n "$probe" ] && [ "$probe" != "$dst" ]; do
      if [ -L "$probe" ]; then through=1; break; fi
      probe=${probe%/*}
    done
    if [ -n "$through" ]; then
      echo "=== $rest is held by a link, merge refused ===" >> "$log" 2>&1 || true
      failed=1
      continue
    fi
    if [ -e "$dst_dir" ] && [ ! -d "$dst_dir" ]; then
      failed=1
      continue
    fi
    if ! mkdir -p "$dst_dir" 2>/dev/null; then failed=1; continue; fi
    for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        set -- "$@" "$rest/$name"
        continue
      fi
      landing="$dst_dir/$name"
      if [ -e "$landing" ] || [ -L "$landing" ]; then
        if [ -L "$entry" ] && [ -L "$landing" ] \
          && [ "$(readlink "$entry")" = "$(readlink "$landing")" ]; then continue; fi
        if [ -f "$entry" ] && [ ! -L "$entry" ] && [ -f "$landing" ] \
          && [ ! -L "$landing" ] && cmp -s "$entry" "$landing"; then continue; fi
        echo "=== conflicting profile file: $landing ===" >> "$log" 2>&1 || true
        failed=1
        continue
      fi
      if [ -L "$entry" ]; then
        if ! cp -Ppn "$entry" "$landing" 2>/dev/null; then
          failed=1
        fi
      else
        if ! cp -pn "$entry" "$landing" 2>/dev/null || ! cmp -s "$entry" "$landing"; then
          failed=1
        fi
        chmod u+w "$landing" 2>/dev/null || true
      fi
    done
  done
  [ -z "$failed" ]
}

# Steam Cloud stuff
migrate_user_paths() {
  profile=$1
  migration_failed=0
  for pair in \
    "Local Settings/Application Data|AppData/Local|../AppData/Local" \
    "Application Data|AppData/Roaming|./AppData/Roaming" \
    "My Documents|Documents|./Documents"; do
    old_rel=${pair%%|*}
    rest=${pair#*|}
    new_rel=${rest%%|*}
    link=${rest#*|}
    old="$profile/$old_rel"
    new="$profile/$new_rel"
    case "$(readlink "$new" 2>/dev/null || true)" in
      *"drive_c/users/steamuser/$old_rel") rm -f "$new" 2>/dev/null || true ;;
    esac
    if [ -L "$new" ]; then
      echo "=== $new_rel is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    held=
    for rel in "$old_rel" "$new_rel"; do
      probe=$rel
      while [ "$probe" != "${probe%/*}" ]; do
        probe=${probe%/*}
        if [ -L "$profile/$probe" ]; then held=$probe; break; fi
      done
      if [ -n "$held" ]; then break; fi
    done
    if [ -n "$held" ]; then
      echo "=== $held is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      if ! merge_user_dir "$old" "$new"; then
        echo "=== $old_rel did not merge into $new_rel, left in place ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
      backup="$old BACKUP"
      backup_number=2
      while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$old BACKUP $backup_number"
        backup_number=$((backup_number + 1))
      done
      if ! mv "$old" "$backup" 2>> "$log"; then
        echo "=== $old_rel could not be moved aside, cloud saves stay split ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
    fi
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
      mkdir -p "${old%/*}" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    elif [ -L "$old" ] && [ "$(readlink "$old")" != "$link" ]; then
      rm -f "$old" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    fi
  done
  [ "$migration_failed" -eq 0 ]
}

lay_out_proton_profile() {
  users="${1:-$WINEPREFIX}/drive_c/users"
  profile="$users/steamuser"
  if [ -L "$profile" ]; then
    echo "=== the profile is a link, rebuild the prefix for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  mkdir -p "$profile" 2>/dev/null || return 0
  for folder in Documents Desktop Downloads Music Pictures Videos Templates \
      AppData/Local AppData/Roaming; do
    mkdir -p "$profile/$folder" 2>/dev/null || true
  done
  migrate_user_paths "$profile" || return 1
}

controller_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | tr 'A-F' 'a-f' \
    | sed -n 's/^[[:space:]]*0x\([0-9a-f]\{4\}\)\/0x\([0-9a-f]\{4\}\)[[:space:]]*$/\1\/\2/p' \
    | sort -u
}

ids_without() {
  printf '%s\n' "$2" -- "$1" \
    | awk '$0 == "--" { s = 1; next } !s { b[$0]; next } $0 != "" && !($0 in b)'
}

hidraw_lines() {
  printf '%s\n' "$2" | while read -r id; do
    [ -n "$id" ] || continue
    if [ "$1" = add ]; then
      printf '%s\r\n' "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" \
        '"Hidraw"=dword:00000000' ''
    else
      printf '%s\r\n' "[-HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" ''
    fi
  done
}

write_owned_controllers() {
  if printf '%s\n' "$1" | sed '/^$/d' | sort -u > "$controllers_file.new" \
    && mv -f "$controllers_file.new" "$controllers_file"; then
    return 0
  fi
  rm -f "$controllers_file.new"
  return 1
}

# Proton hides the controllers that Steam Input handles from the Wine process. Wine
# still reads a few directly (DualSense, DualShock 4, Switch 1 Pro Controller and Joy-Cons),
# so Hidraw=0 hides those too. The Switch controllers get Hidraw=0 even when Steam Input
# is off, to avoid silently breaking controller support in most games.
plan_hidden_controllers() {
  controllers_file="$STEAM_COMPAT_DATA_PATH/hadron-hidden-controllers"
  controllers_add=""
  controllers_remove=""
  controllers_wanted=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$controllers_file" ] || return 1
  owned=""
  [ ! -f "$controllers_file" ] || owned=$(sed -n '/^[0-9a-f]\{4\}\/[0-9a-f]\{4\}$/p' "$controllers_file")
  in_registry=""
  [ ! -f "$WINEPREFIX/system.reg" ] || in_registry=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | sed -n 's/^\[system\\\\controlset001\\\\services\\\\winebus\\\\devices\\\\\([0-9a-f]\{4\}\/[0-9a-f]\{4\}\)\].*/\1/p' \
    | sort -u)
  if [ "$HADRON_RAW_CONTROLLERS" != "1" ]; then
    controllers_wanted=$(ids_without "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES")" \
      "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT")")
    controllers_wanted=$(printf '%s\n' "$controllers_wanted" 057e/2006 057e/2007 057e/2009 | sed '/^$/d' | sort -u)
    # Steam sends install scripts no ignore list. Keep the game's hidden controllers instead of clearing them.
    if [ "$verb" = run ]; then
      controllers_wanted=$(printf '%s\n' "$controllers_wanted" "$owned" | sed '/^$/d' | sort -u)
    fi
    controllers_wanted=$(ids_without "$controllers_wanted" "$(ids_without "$in_registry" "$owned")")
  fi
  controllers_add=$(ids_without "$controllers_wanted" "$in_registry")
  controllers_remove=$(ids_without "$owned" "$controllers_wanted")
  write_owned_controllers "$owned
$controllers_wanted"
}

import_prefix_settings() {
  if [ "$HADRON_RETINA" = "1" ]; then
    retina_line='"RetinaMode"="y"'
  else
    retina_line='"RetinaMode"=-'
  fi
  controllers_planned=0
  if plan_hidden_controllers 2>/dev/null; then
    controllers_planned=1
  else
    controllers_add=""
    controllers_remove=""
    echo "=== could not track the hidden controllers, leaving them as they are ===" >> "$log" 2>&1 || true
  fi
  settings_file=$(mktemp "$WINEPREFIX/drive_c/hadron-settings.XXXXXX" 2>/dev/null) \
    || settings_file=""
  if [ -z "$settings_file" ] || ! { printf '%s\r\n' \
      'Windows Registry Editor Version 5.00' '' \
      '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
      '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$retina_line" '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
      '@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' '' \
      && hidraw_lines add "$controllers_add" && hidraw_lines remove "$controllers_remove"; } \
      > "$settings_file" 2>/dev/null; then
    [ -z "$settings_file" ] || rm -f "$settings_file"
    echo "=== could not write the prefix settings, launching without them ===" >> "$log" 2>&1 || true
    # the bridge staging still needs a built prefix
    without_lock_fds "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
    return 0
  fi
  without_lock_fds "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
    && import_status=0 || import_status=$?
  rm -f "$settings_file"
  if [ "$import_status" -eq 0 ] && [ "$controllers_planned" -eq 1 ]; then
    write_owned_controllers "$controllers_wanted" 2>/dev/null || true
    if [ -n "$controllers_add$controllers_remove" ]; then
      # Wine only reads these keys when it starts, so restart Wine to apply them.
      without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
      without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
    fi
    if [ "$HADRON_RAW_CONTROLLERS" = "1" ]; then
      echo "controllers: games read them directly (HADRON_RAW_CONTROLLERS=1)" >> "$log" 2>&1 || true
    elif [ -n "$controllers_wanted" ]; then
      echo "controllers: $(printf '%s\n' "$controllers_wanted" | grep -c .) kept off hidraw" \
        >> "$log" 2>&1 || true
    fi
  fi
  [ "$import_status" -eq 0 ] \
    || echo "=== prefix settings import exited status=$import_status ===" >> "$log" 2>&1 || true
}

stage_step="runner check"
if [ -z "$np_build" ] || [ ! -d "$np_root/lib/wine" ]; then
  echo "=== build ${np_build:-(none recorded)} behind this compatibility tool is not set up, set it up in Hadron ===" >> "$log" 2>&1 || true
  show_alert "The Wine runtime is not set up" "The Wine runtime behind $(alert_safe "$np_display") is not set up. Set it up in Hadron, or pick another compatibility tool for this game."
  exit 1
fi
echo "runner: build $np_build ($np_display) at $np_root" >> "$log" 2>&1 || true

# Each runtime carries graphics backends under lib/graphics, beside Wine's own Direct3D,
# and its Wine searches HADRON_DLL_OVERLAY first. HADRON_GRAPHICS in a game's launch
# options picks dxmt (D3D10/11 on Metal, D3D8/9 on DXVK), d3dmetal (Apple's D3D11/12,
# D3D8/9 on DXVK), dxvk (DXVK 3.1), dxvk1 (DXVK 1.10) or wined3d (Wine's own).
# HADRON_DDRAW=cnc-ddraw adds cnc-ddraw.
unset HADRON_DLL_OVERLAY CX_APPLEGPTK_LIBD3DSHARED_PATH
np_graphics="${HADRON_GRAPHICS:-dxmt}"
case "$np_graphics" in
  dxmt) np_overlays="dxmt d9vk" ;;
  d3dmetal) np_overlays="d3dmetal d9vk" ;;
  dxvk) np_overlays="dxvk" ;;
  dxvk1) np_overlays="dxvk1" ;;
  *) np_overlays="" ;;
esac
[ "${HADRON_DDRAW:-}" != cnc-ddraw ] || np_overlays="$np_overlays ddraw"
for np_overlay in $np_overlays; do
  np_dir="$np_root/lib/graphics/$np_overlay"
  # Runtimes set up before lib/graphics kept DXMT in lib/dxmt.
  [ -d "$np_dir" ] || [ "$np_overlay" != dxmt ] || np_dir="$np_root/lib/dxmt"
  [ -d "$np_dir" ] || continue
  HADRON_DLL_OVERLAY="${HADRON_DLL_OVERLAY:+$HADRON_DLL_OVERLAY:}$np_dir"
done
# D3DMetal is only in the CrossOver runtime, and the arm64 runtimes have neither DXMT
# nor D3DMetal. A backend the runtime lacks falls back to DXMT, or to DXVK 1.10 (which FEX
# runs), rather than to Wine's own Direct3D.
case "$np_graphics" in
  dxmt|d3dmetal)
    case ":${HADRON_DLL_OVERLAY:-}:" in
      *"/dxmt:"*|*"/d3dmetal:"*) ;;
      *)
        for np_fallback in dxmt dxvk1; do
          np_dir="$np_root/lib/graphics/$np_fallback"
          [ -d "$np_dir" ] || continue
          HADRON_DLL_OVERLAY="$np_dir${HADRON_DLL_OVERLAY:+:$HADRON_DLL_OVERLAY}"
          np_overlays="$np_fallback $np_overlays"
          echo "graphics: $np_graphics is not in this runtime, using $np_fallback" >> "$log" 2>&1 || true
          break
        done ;;
    esac ;;
esac
[ -z "${HADRON_DLL_OVERLAY:-}" ] || export HADRON_DLL_OVERLAY
# CrossOver's Wine loads libd3dshared early so it can mark native code for Rosetta.
case ":${HADRON_DLL_OVERLAY:-}:" in
  *"/lib/graphics/d3dmetal:"*)
    export CX_APPLEGPTK_LIBD3DSHARED_PATH="$np_root/lib/graphics/d3dmetal/x86_64-unix/libd3dshared.dylib" ;;
esac
# Runtimes with the Vulkan loader pick its driver: KosmicKrisp for DXVK 3 and D3D8/9 on
# DXVK, which need Vulkan features MoltenVK lacks, and MoltenVK otherwise. A driver set
# in the launch options wins. The arm64 runtimes have MoltenVK only.
np_icd="$np_root/share/vulkan/icd.d"
if [ -z "${VK_DRIVER_FILES:-}" ] && [ -d "$np_icd" ]; then
  np_driver=MoltenVK
  case " $np_overlays " in
    *" dxvk "*|*" d9vk "*) [ ! -f "$np_icd/kosmickrisp_icd.json" ] || np_driver=kosmickrisp ;;
  esac
  export VK_DRIVER_FILES="$np_icd/${np_driver}_icd.json"
fi
echo "graphics: $np_graphics (${HADRON_DLL_OVERLAY:-Wine builtin}, Vulkan ${VK_DRIVER_FILES:-direct})" >> "$log" 2>&1 || true

# Each runtime build needs its own template.
runner_id=""
[ -z "$np_build" ] || runner_id="$np_build-${wine_unix##*/}"

in_template_env() {
  prefix="$1"
  shift
  without_lock_fds \
    env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" \
    PATH="$np_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WINEDLLPATH="$wine_pe64:$wine_unix" \
    WINELOADER="$WINELOADER" WINESERVER="$WINESERVER" WINEPREFIX="$prefix" "$@"
}

seed_scratch=""
seed_building=0
# shellcheck disable=SC2329 # the traps in seed_prefix_from_template invoke this
abandon_seed() {
  if [ -n "$seed_scratch" ]; then
    if [ "$seed_building" -eq 1 ]; then
      in_template_env "$seed_scratch" "$WINESERVER" -k >/dev/null 2>&1 || true
      in_template_env "$seed_scratch" "$WINESERVER" -w >/dev/null 2>&1 || exit "$1"
    fi
    rm -rf "$seed_scratch" 2>/dev/null || true
  fi
  exit "$1"
}

prefix_server_dir() {
  [ -n "${1:-$WINEPREFIX}" ] || return 1
  ids=$(stat -f '%d-%i' "${1:-$WINEPREFIX}" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  printf '/tmp/.wine-%s/server-%s' "$(id -u)" \
    "$(printf '%s' "$ids" | awk -F- '{printf "%x-%x", $1, $2}')"
}

sweep_dead_seeds() {
  for leftover in "$@"; do
    [ -d "$leftover" ] && [ ! -L "$leftover" ] || continue
    case "${leftover##*.}" in ''|0|*[!0-9]*) continue ;; esac
    [ "$(stat -f %u "$leftover" 2>/dev/null)" = "$(id -u)" ] || continue
    kill -0 "${leftover##*.}" 2>/dev/null && continue
    stale_server=$(prefix_server_dir "$leftover") || continue
    if [ -d "$stale_server" ]; then
      stale_users=$(lsof -t +D "$stale_server" 2>&1 || true)
      [ -z "$stale_users" ] || continue
    fi
    rm -rf "$leftover" 2>/dev/null || true
  done
}

same_volume() {
  one=$(stat -f %d "$1" 2>/dev/null) || return 1
  two=$(stat -f %d "$2" 2>/dev/null) || return 1
  [ "$one" = "$two" ]
}

# On non-APFS file systems, a full copy is made rather than a clone.
volume_clones() {
  device=$(stat -f %Sd "$1" 2>/dev/null) || return 1
  mount | grep -q "^/dev/$device on .* (apfs[,)]"
}

# Built in a temporary folder and renamed when the build finishes, so a broken template is never used
build_prefix_template() {
  sweep_dead_seeds "$template_dir"/pfx.building.*
  seed_scratch="$template_dir/pfx.building.$$"
  mkdir "$seed_scratch" || return 1
  echo "=== building the prefix template for $runner_id ===" >> "$log" 2>&1 || true
  # The Steam user folders have to exist before wineboot runs, or wineboot will make its own
  # and cloud saves end up in the wrong place.
  lay_out_proton_profile "$seed_scratch" || return 1
  seed_building=1
  in_template_env "$seed_scratch" "$WINELOADER" wineboot --init >> "$log" 2>&1 &
  initialized=0
  wait $! || initialized=$?
  in_template_env "$seed_scratch" "$WINESERVER" -w >> "$log" 2>&1 &
  if ! wait $!; then
    echo "=== template server did not finish, leaving its staging folder intact ===" >> "$log" 2>&1 || true
    seed_scratch=""
    seed_building=0
    return 1
  fi
  seed_building=0
  if [ "$initialized" -ne 0 ] || [ ! -s "$seed_scratch/system.reg" ] \
    || [ ! -s "$seed_scratch/user.reg" ] || [ ! -s "$seed_scratch/userdef.reg" ]; then
    echo "=== wineboot produced no template, this game gets its own prefix ===" \
      >> "$log" 2>&1 || true
    rm -rf "$seed_scratch" 2>/dev/null || true
    seed_scratch=""
    return 1
  fi
  if [ ! -e "$template_dir/pfx" ] && [ ! -L "$template_dir/pfx" ]; then
    mv "$seed_scratch" "$template_dir/pfx" 2>/dev/null || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
  [ -f "$template_dir/pfx/system.reg" ]
}

install_seed_tree() (
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    source_dir="$seed_scratch$relative"
    target_dir="$WINEPREFIX$relative"
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    [ -r "$source_dir" ] && [ -x "$source_dir" ] || return 1
    for source in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
      [ -e "$source" ] || [ -L "$source" ] || continue
      name=${source##*/}
      if [ -z "$relative" ]; then
        case "$name" in system.reg|.update-timestamp) continue ;; esac
      fi
      target="$target_dir/$name"
      if [ -d "$source" ] && [ ! -L "$source" ]; then
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          mkdir "$target" || return 1
        fi
        [ -d "$target" ] && [ ! -L "$target" ] || return 1
        set -- "$@" "$relative/$name"
      elif [ -e "$target" ] || [ -L "$target" ]; then
        case "$relative/$name" in
          /drive_c/users/steamuser/*) continue ;;
        esac
        [ -L "$source" ] && [ -L "$target" ] \
          && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      elif [ -L "$source" ]; then
        ln -sh "$(readlink "$source")" "$target" || return 1
        [ -L "$target" ] && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      elif [ -f "$source" ]; then
        ln -h "$source" "$target" || return 1
        [ ! -L "$target" ] && [ "$source" -ef "$target" ] || return 1
      else
        return 1
      fi
    done
  done
  ln -h "$seed_scratch/system.reg" "$WINEPREFIX/system.reg" \
    && [ ! -L "$WINEPREFIX/system.reg" ] \
    && [ "$seed_scratch/system.reg" -ef "$WINEPREFIX/system.reg" ] || return 1
  if [ -f "$seed_scratch/.update-timestamp" ]; then
    ln -h "$seed_scratch/.update-timestamp" "$WINEPREFIX/.update-timestamp" || return 1
  fi
)

copy_template_into_prefix() {
  seed_scratch="$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$"
  if ! mkdir "$seed_scratch" 2>/dev/null; then
    echo "=== prefix staging folder is occupied, skipping the template ===" >> "$log" 2>&1 || true
    seed_scratch=""
    return 0
  fi
  if same_volume "$template_dir" "$STEAM_COMPAT_DATA_PATH" && volume_clones "$template_dir"; then
    how="cloned this prefix from the $runner_id template"
    cp -c -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  else
    how="copied this prefix from the $runner_id template, not a clone"
    cp -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  fi
  if [ "$copied" -eq 0 ] && prefix_is_bare && install_seed_tree; then
    echo "=== $how ===" >> "$log" 2>&1 || true
  else
    echo "=== could not seed from the template, wine builds this prefix itself ===" \
      >> "$log" 2>&1 || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
}

prefix_is_bare() (
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    directory="$WINEPREFIX$relative"
    [ -d "$directory" ] && [ ! -L "$directory" ] \
      && [ -r "$directory" ] && [ -x "$directory" ] || return 1
    for node in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ -e "$node" ] || [ -L "$node" ] || continue
      part="$relative/${node##*/}"
      if [ -L "$node" ]; then
        if [ "$part" = /dosdevices/s: ] && [ "$(readlink "$node")" = "$(game_drive_record)" ]; then
          continue
        fi
        case "$part:$(readlink "$node")" in
          /dosdevices/c::../drive_c|/dosdevices/z::/|\
          '/drive_c/users/steamuser/My Documents:./Documents'|\
          '/drive_c/users/steamuser/Application Data:./AppData/Roaming'|\
          '/drive_c/users/steamuser/Local Settings/Application Data:../AppData/Local') continue ;;
          *) return 1 ;;
        esac
      fi
      case "$part" in
        /drive_c|/drive_c/users|/drive_c/users/steamuser|/dosdevices)
          [ -d "$node" ] || return 1 ;;
        /drive_c/users/steamuser/*)
          [ -d "$node" ] || [ -f "$node" ] || return 1 ;;
        *) return 1 ;;
      esac
      if [ -d "$node" ]; then set -- "$@" "$part"; fi
    done
  done
)

template_identity() (
  stat -f '%d:%i:%c' "$np_root" || return 1
  /usr/bin/shasum -a 256 < "$np_tool_dir/run" || return 1
  cd "$np_root" || return 1
  set -- "$WINELOADER" "$WINESERVER" share/wine/wine.inf
  for file in lib/wine/*-windows/ntdll.dll lib/wine/*-windows/lsteamclient.dll \
    lib/wine/*-unix/lsteamclient.so; do
    [ ! -f "$file" ] || set -- "$@" "$file"
  done
  /usr/bin/shasum -a 256 "$@"
)

# Each game's prefix is copied from one template (per runner) instead of running wineboot.
# On APFS the copy is a clone, so it takes almost no space.
seed_prefix_from_template() {
  sweep_dead_seeds "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*
  [ -n "$runner_id" ] || return 0
  if ! prefix_is_bare; then
    [ -f "$WINEPREFIX/system.reg" ] \
      || echo "=== prefix is not empty or a standalone Steam profile, skipping the template ===" \
        >> "$log" 2>&1 || true
    return 0
  fi
  # Since a user can have more than one Steam library and libraries can be on different drives,
  # the template is stored alongside the Steam library to support APFS cloning.
  template_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/hadron-template"
  template_lock="$(dirname "$STEAM_COMPAT_DATA_PATH")/.hadron-template.lock"
  [ ! -L "$template_cache" ] && [ ! -L "$template_lock" ] || return 0
  [ ! -e "$template_lock" ] || [ -f "$template_lock" ] || return 0
  if ! { : >> "$template_lock"; } 2>/dev/null; then
    echo "=== prefix template cache is not writable, skipping the template ===" >> "$log" 2>&1 || true
    return 0
  fi
  exec 9>> "$template_lock"
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    echo "=== prefix templates are busy, wine builds this prefix itself ===" >> "$log" 2>&1 || true
    return 0
  fi
  template_dir="$template_cache/$runner_id"
  if [ -L "$template_cache" ] || [ -L "$template_dir" ] \
    || ! mkdir -p "$template_dir"; then exec 9>&-; return 0; fi
  if ! identity=$(template_identity); then exec 9>&-; return 0; fi
  trap 'abandon_seed 143' TERM
  trap 'abandon_seed 130' INT
  trap 'abandon_seed 129' HUP
  if [ -L "$template_dir/pfx" ] || [ -L "$template_dir/ready" ] \
    || { [ -e "$template_dir/pfx" ] && [ ! -d "$template_dir/pfx" ]; } \
    || { [ -e "$template_dir/ready" ] && [ ! -f "$template_dir/ready" ]; }; then
    exec 9>&-
    trap - TERM INT HUP
    return 0
  fi
  if [ ! -s "$template_dir/pfx/system.reg" ] \
    || [ "$(cat "$template_dir/ready" 2>/dev/null)" != "$identity" ]; then
    if ! rm -f "$template_dir/ready" || ! rm -rf "$template_dir/pfx"; then
      echo "=== could not invalidate the old prefix template, skipping it ===" >> "$log" 2>&1 || true
      exec 9>&-
      trap - TERM INT HUP
      return 0
    fi
    if build_prefix_template; then
      if ! printf '%s\n' "$identity" > "$template_dir/ready"; then
        rm -f "$template_dir/ready" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$(cat "$template_dir/ready" 2>/dev/null)" = "$identity" ] \
    && [ -s "$template_dir/pfx/system.reg" ]; then
    copy_template_into_prefix
  fi
  exec 9>&-
  trap - TERM INT HUP
}

prepare_prefix_directory() {
  mkdir -p "$STEAM_COMPAT_DATA_PATH" || return 1
  prefix_lock="$STEAM_COMPAT_DATA_PATH/.hadron-prefix.lock"
  [ ! -L "$prefix_lock" ] && { [ ! -e "$prefix_lock" ] || [ -f "$prefix_lock" ]; } || return 1
  exec 8>> "$prefix_lock"
  if ! /usr/bin/lockf -s -t 0 8; then
    echo "=== another launch is preparing this prefix ===" >> "$log" 2>&1 || true
    /usr/sbin/lsof -- "$prefix_lock" >> "$log" 2>&1 || true
    return 1
  fi
  for interrupted in "$STEAM_COMPAT_DATA_PATH"/pfx.replaced.*; do
    [ -e "$interrupted" ] || [ -L "$interrupted" ] || continue
    echo "=== interrupted prefix replacement needs recovery: $interrupted ===" >> "$log" 2>&1 || true
    show_alert "Prefix recovery required" "An interrupted prefix replacement may hold saved games. Do not delete this prefix. Check its hadron-run.log for the recovery folder."
    exit 1
  done
  mkdir -p "$WINEPREFIX"
}

game_drive_record() {
  record="$STEAM_COMPAT_DATA_PATH/hadron-game-drive"
  [ -f "$record" ] && [ ! -L "$record" ] && cat "$record" 2>/dev/null
}

record_game_drive() {
  record="$STEAM_COMPAT_DATA_PATH/hadron-game-drive"
  [ "$(game_drive_record)" != "$1" ] && [ ! -L "$record" ] || return 0
  { printf '%s\n' "$1" > "$record.new" && mv -f "$record.new" "$record"; } 2>/dev/null \
    || rm -f "$record.new" 2>/dev/null || true
}

restart_for_drive() {
  # Wine only picks up a new drive when it starts.
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
}

unmap_game_drive() {
  [ -L "$drive" ] && [ "$(readlink "$drive")" = "$(game_drive_record)" ] || return 0
  rm -f "$drive" || return 0
  rm -f "$STEAM_COMPAT_DATA_PATH/hadron-game-drive" 2>/dev/null || true
  echo "=== removed drive S:, the game is not in a Steam library ===" >> "$log" 2>&1 || true
  restart_for_drive
}

# Like Proton, the game's Steam library gets drive S: so the game does not run from Z:.
map_game_drive() {
  drive="$WINEPREFIX/dosdevices/s:"
  [ -d "$WINEPREFIX/dosdevices" ] && [ ! -L "$WINEPREFIX/dosdevices" ] || return 0
  library=""
  set -f
  old_ifs=$IFS
  IFS=:
  for path in $STEAM_COMPAT_LIBRARY_PATHS; do
    path=${path%/}
    [ -n "$path" ] || continue
    case "$STEAM_COMPAT_INSTALL_PATH/" in
      "$path"/*) if [ "${#path}" -gt "${#library}" ]; then library=$path; fi ;;
    esac
  done
  IFS=$old_ifs
  set +f
  if [ -z "$library" ]; then
    unmap_game_drive
    return 0
  fi
  target=$library
  if real=$(cd -P -- "$library" 2>/dev/null && pwd) && [ "${real##*/}" = steamapps ]; then
    parent=${real%/*}
    if [ -n "$parent" ] && [ -w "$parent" ] \
      && [ "$(stat -f %d "$real")" = "$(stat -f %d "$parent")" ]; then
      target=$parent
    fi
  fi
  if [ -L "$drive" ]; then
    current=$(readlink "$drive") || return 0
    if [ "$current" = "$target" ]; then
      record_game_drive "$target"
      return 0
    fi
    if [ "$current" != "$(game_drive_record)" ]; then
      echo "=== drive S: already points to $current, left in place ===" >> "$log" 2>&1 || true
      return 0
    fi
    rm -f "$drive" || return 0
  elif [ -e "$drive" ]; then
    echo "=== drive S: is not a link, left in place ===" >> "$log" 2>&1 || true
    return 0
  fi
  if ln -s "$target" "$drive" 2>> "$log"; then
    record_game_drive "$target"
    echo "=== mapped drive S: to $target ===" >> "$log" 2>&1 || true
    restart_for_drive
  else
    echo "=== could not map drive S: to $target ===" >> "$log" 2>&1 || true
  fi
}

# Implementation of Proton's create_fonts_symlinks().
link_fonts() {
  [ -f "$WINEPREFIX/system.reg" ] || return 0
  fonts_dir="$WINEPREFIX/drive_c/windows/Fonts"
  mkdir -p "$fonts_dir" 2>> "$log" || return 0
  for dir in "$np_support/fonts" "$np_root/share/wine/fonts"; do
    for src in "$dir"/*.ttf "$dir"/*.ttc; do
      [ -f "$src" ] || continue
      name=$(basename "$src")
      case "$app_id:$name" in
        1313860:arial.ttf|1506830:arial.ttf) src="$dir/alt/$name" ;;
      esac
      dst="$fonts_dir/$name"
      if [ -L "$dst" ]; then
        rm -f "$dst" && ln -s "$src" "$dst" 2>> "$log" || true
      elif [ ! -e "$dst" ]; then
        ln -s "$src" "$dst" 2>> "$log" || true
      fi
    done
  done
}

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  stage_step="prefix lock"
  prepare_prefix_directory
  stage_step="prefix build check"
  note_other_build
  stage_step="prefix arch check"
  convert_foreign_prefix
  claim_prefix
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  stage_step="prefix seed"
  seed_prefix_from_template
  stage_step="profile layout"
  if ! lay_out_proton_profile; then
    show_alert "Saved-game folders need attention" "Hadron left the conflicting files in place. Open this prefix's hadron-run.log for details before trying again."
    exit 1
  fi
  echo "video: RetinaMode=${HADRON_RETINA:-0}" >> "$log" 2>&1 || true
  stage_step="game drive"
  map_game_drive
  stage_step="prefix settings"
  import_prefix_settings
  stage_step="fonts"
  link_fonts
  # A prefix that Wine built just now only has dosdevices from this point on.
  stage_step="game drive"
  map_game_drive
fi

bridge_src="$np_support/bridge"
prefix_steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
verify_runner() {
  for arch in i386-windows "${wine_pe64##*/}" "${wine_unix##*/}"; do
    case "$arch" in
      *-unix) name="lsteamclient.so" ;;
      *) name="lsteamclient.dll" ;;
    esac
    [ -f "$np_root/lib/wine/$arch/$name" ] && continue
    echo "=== runner is missing $arch/$name, set up the runner in Hadron ===" >> "$log" 2>&1 || true
  done
}
install_lsteamclient_trigger() {
  src="$bridge_src/i386-windows/lsteamclient.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/lsteamclient.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file i386-windows/lsteamclient.dll "$dst"; then
    echo "=== installed syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy i386-windows/lsteamclient.dll to $dst ===" >> "$log" 2>&1 || true
    return 1
  fi
}

# A fix to match Proton
install_legacy_steam_dll() {
  src="$bridge_src/legacycompat/Steam.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/Steam.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file legacycompat/Steam.dll "$dst"; then
    echo "=== installed legacy Steam.dll ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy legacycompat/Steam.dll to $dst ===" >> "$log" 2>&1 || true
  fi
}

# Steam runs a Windows game's installscript.vdf by invoking the standalone
# evaluator through the compat tool, the same way the linux client does, but
# the binaries are missing on macOS, so...
install_legacycompat() {
  src="$bridge_src/legacycompat"
  dst="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat"
  [ -d "$src" ] && [ -n "$STEAM_COMPAT_CLIENT_INSTALL_PATH" ] || return 0
  mkdir -p "$dst" || return 0
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cmp -s "$f" "$dst/$b" && continue
    if cp -c -f "$f" "$dst/$b" 2>> "$log"; then
      echo "=== installed legacycompat/$b ===" >> "$log" 2>&1 || true
    else
      echo "=== could not copy legacycompat/$b to $dst/$b ===" >> "$log" 2>&1 || true
    fi
  done
}

# Steam on Linux symlinks this for every compat tool launch. Is needed for some legacy games.
link_legacy_steam_dll() {
  src="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat/Steam.dll"
  [ -n "$STEAM_COMPAT_INSTALL_PATH" ] && [ -f "$src" ] || return 0
  dst="$(dirname "$STEAM_COMPAT_INSTALL_PATH")/Steam.dll"
  [ -L "$dst" ] || [ ! -e "$dst" ] || return 0
  [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && return 0
  if ln -sfn "$src" "$dst" 2>> "$log"; then
    chflags -h hidden "$dst" 2>/dev/null || true
    echo "=== linked legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  else
    echo "=== could not link legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  fi
}

bridge_files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll"
bridge_files="$bridge_files lsteamclient.dll lsteamclient.so steam.exe"
# A clone cannot cross drives, so a prefix on another drive clones from a copy of the
# bridge kept beside that drive's templates.
bridge_origin() {
  origin="$bridge_src/$1"
  [ -n "$bridge_cache" ] || return 0
  cached="$bridge_cache/$1"
  for d in "${bridge_cache%/*}" "$bridge_cache" "${cached%/*}"; do
    [ ! -L "$d" ] || return 0
  done
  mkdir -p "${cached%/*}" 2>/dev/null || return 0
  if ! cmp -s "$origin" "$cached"; then
    if ! { cp -p "$origin" "$cached.$$" && mv -f "$cached.$$" "$cached"; } 2>/dev/null; then
      rm -f "$cached.$$"
      return 0
    fi
  fi
  origin="$cached"
}
place_bridge_file() {
  bridge_origin "$1"
  cp -c -fp "$origin" "$2" 2>/dev/null || cp -fp "$bridge_src/$1" "$2" 2>> "$log"
}
if [ -d "$bridge_src" ] && [ -n "$WINEPREFIX" ]; then
  stage_step="bridge staging"
  mkdir -p "$prefix_steam"
  bridge_cache=""
  if [ -n "$STEAM_COMPAT_DATA_PATH" ] && ! same_volume "$bridge_src" "$STEAM_COMPAT_DATA_PATH" \
    && volume_clones "$STEAM_COMPAT_DATA_PATH"; then
    bridge_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/hadron-template/bridge"
  fi
  bridge_matches=1
  for f in $bridge_files; do
    src="$bridge_src/$f"
    if [ "$f" = lsteamclient.so ]; then
      src="$bridge_src/${wine_unix##*/}/$f"
    fi
    if ! cmp -s "$src" "$prefix_steam/$f"; then
      bridge_matches=0
      break
    fi
  done
  if [ "$bridge_matches" -eq 1 ]; then
    echo "=== bridge already staged ===" >> "$log" 2>&1 || true
  else
    unstaged=0
    for f in $bridge_files; do
      rel="$f"
      if [ "$f" = lsteamclient.so ]; then
        rel="${wine_unix##*/}/$f"
      fi
      src="$bridge_src/$rel"
      if [ ! -f "$src" ]; then
        echo "=== bridge missing $f ===" >> "$log" 2>&1 || true
        # One staged for the other arch, before the prefix was converted, would load
        # instead of the runtime's own.
        [ "$f" != lsteamclient.so ] || rm -f "$prefix_steam/$f"
        continue
      fi
      cmp -s "$src" "$prefix_steam/$f" && continue
      if ! place_bridge_file "$rel" "$prefix_steam/$f"; then
        echo "=== could not copy $rel to $prefix_steam/$f ===" >> "$log" 2>&1 || true
        unstaged=1
      fi
    done
    if [ "$unstaged" -eq 1 ]; then
      show_alert "Steam files could not be copied" "Hadron could not copy a file into this game's prefix. Open this prefix's hadron-run.log for details."
      exit 1
    fi
  fi
  for f in "$prefix_steam"/*.dll "$prefix_steam"/*.so "$prefix_steam"/*.exe; do
    [ -f "$f" ] || continue
    case " $bridge_files " in
      *" $(basename "$f") "*) ;;
      *) rm -f "$f" && echo "=== pruned stale $(basename "$f") ===" >> "$log" 2>&1 ;;
    esac
  done
  verify_runner
  if ! install_lsteamclient_trigger; then
    show_alert "Steam files could not be copied" "Hadron could not copy a file into this game's prefix. Open this prefix's hadron-run.log for details."
    exit 1
  fi
  install_legacy_steam_dll
  export WINEDLLPATH="$prefix_steam:$WINEDLLPATH"
  # If the same DLL appears twice in WINEDLLOVERRIDES, the last entry wins.
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}steamclient=n;steamclient64=n;lsteamclient=b"
  native_client="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  if [ -z "$native_client" ]; then
    native_client="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  fi
  install_legacycompat
  link_legacy_steam_dll
  echo "=== bridge staged into $prefix_steam ===" >> "$log" 2>&1 || true
  echo "WINEDLLPATH=$WINEDLLPATH" >> "$log" 2>&1 || true
  echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >> "$log" 2>&1 || true
  echo "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH" >> "$log" 2>&1 || true
fi

export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
exec 8>&-
trap - EXIT
printf 'launch_args=%s\n' "$launch_args" >> "$log" 2>&1 || true
printf '=== launching (%s): %s %s ===\n' "$verb" "$WINELOADER" "$*" >> "$log" 2>&1 || true

target="$1"
# A game can arrive as a URL with no install path to match, so the verb has to decide the route.
case "$verb" in
  waitforexitandrun) foreground=1 ;;
  *) foreground=0 ;;
esac

shim_exe="C:\\Program Files (x86)\\Steam\\steam.exe"

if [ "$foreground" = 0 ]; then
  status=0  # set -e would exit before the status is read
  case "$verb" in
    # runinprefix is the one verb the Linux client keeps on the raw loader.
    runinprefix)
      echo "=== running helper on raw loader: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$@" >> "$log" 2>&1 || status=$?
      ;;
    *)
      # A helper target can be a URL, which steam.exe resolves.
      echo "=== running helper through the shim: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$shim_exe" "$@" >> "$log" 2>&1 || status=$?
      ;;
  esac
  echo "=== helper exited status=$status ===" >> "$log" 2>&1 || true
  exit $status
fi

# Fixes window focus issues
steam_root="$(dirname "$(dirname "$(dirname "$STEAM_COMPAT_DATA_PATH")")")"
manifest="$steam_root/steamapps/appmanifest_$app_id.acf"
find_client_root "$STEAM_COMPAT_CLIENT_INSTALL_PATH"
# Icon stuff
read_app_meta
game_name="$meta_name"
if [ -z "$game_name" ] && [ -f "$manifest" ]; then
  game_name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -1)
fi
[ -z "$game_name" ] && game_name=$(basename "$STEAM_COMPAT_INSTALL_PATH")
[ -z "$game_name" ] && game_name="Steam Game"
# shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
bundle_name=$(printf '%s' "$game_name" | tr -d '/:"`$\\')
bundle_name=${bundle_name#"${bundle_name%%[!.]*}"}
[ -n "$bundle_name" ] || bundle_name="Steam Game"
game_name_xml=$(printf '%s' "$game_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
loader_root="$HOME/Library/Application Support/hadron/launchers/$app_id"
mkdir -p "$loader_root"
loader_app="$loader_root/$bundle_name.app"
find "$loader_root" -maxdepth 1 -name '.build.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
loader_stage="$loader_work/new/$bundle_name.app"
loader_contents="$loader_stage/Contents"
loader_macos="$loader_contents/MacOS"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_macos" "$loader_res"

icon_arg=""
icon_root="$loader_root"
if resolve_icon && cp -f "$icon_cache" "$loader_res/game.icns"; then
  icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
fi
[ -n "$icon_arg" ] || echo "no icon resolved, launching without one" >> "$log" 2>&1 || true

uielement_arg=""
if [ "${HADRON_HIDE_LAUNCHER_TILE:-0}" = "1" ]; then
  uielement_arg="  <key>LSUIElement</key><true/>"
  echo "launcher tile hidden by HADRON_HIDE_LAUNCHER_TILE" >> "$log" 2>&1 || true
fi
cat > "$loader_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$game_name_xml</string>
  <key>CFBundleDisplayName</key><string>$game_name_xml</string>
  <key>CFBundleIdentifier</key><string>nl.nhsd.hadron.launcher.$app_id</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>This game would like to access your microphone.</string>
  <key>NSCameraUsageDescription</key><string>This game would like to access your camera.</string>
  <key>NSLocalNetworkUsageDescription</key><string>This game would like to access devices on your local network.</string>
$uielement_arg
$icon_arg
</dict>
</plist>
PLIST

# Invokes macOS Game Mode
for f in "$wine_unix"/*; do
  [ -e "$f" ] || continue
  base=${f##*/}
  case "$base" in
    wine) continue ;;
  esac
  ln -sfn "$f" "$loader_macos/$base"
done
ln "$WINELOADER" "$loader_macos/wine" 2>/dev/null || cp "$WINELOADER" "$loader_macos/wine"
if [ -x "$loader_macos/wine" ]; then
  WINELOADER="$loader_app/Contents/MacOS/wine"
  echo "loader staged in bundle for game mode" >> "$log" 2>&1 || true
else
  echo "loader staging failed, game mode unavailable" >> "$log" 2>&1 || true
fi

cat > "$loader_macos/launcher" <<LAUNCHER
#!/bin/sh
export WINELOADER="$WINELOADER"
wine_log="$loader_root/hadron-wine.log"
exec > "\$wine_log" 2>&1
shim="$HOME/Library/Application Support/hadron/overlay-shim.dylib"
if [ -n "\$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  if [ -f "\$shim" ]; then
    export DYLD_INSERT_LIBRARIES="\$shim:\$STEAM_DYLD_INSERT_LIBRARIES"
    export HADRON_OVERLAY_SHIM="\$shim"
  else
    export DYLD_INSERT_LIBRARIES="\$STEAM_DYLD_INSERT_LIBRARIES"
  fi
fi
[ -n "\$HADRON_GAME_CWD" ] && cd "\$HADRON_GAME_CWD"
"$WINELOADER" "\$@"
exit \$?
LAUNCHER
chmod +x "$loader_macos/launcher"

bundle_listing() {
  (cd "$1" && find . | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf 'l %s %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then
      printf 'd %s\n' "$p"
    else
      printf 'f %s %s %s\n' "$p" "$(stat -f %Lp "$p")" "$(cksum < "$p")"
    fi
  done)
}
install_bundle() (
  exec 7>> "$loader_root/.lock"
  /usr/bin/lockf -s -t 30 7 || exit 1
  same=""
  for b in "$loader_root"/*.app; do
    if [ "$b" = "$loader_app" ] && [ -d "$b" ] && [ ! -L "$b" ] &&
       [ "$(bundle_listing "$b")" = "$(bundle_listing "$loader_stage")" ]; then
      same=1
    fi
  done
  if [ -n "$same" ]; then
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app; do
      if [ "$b" != "$loader_app" ]; then rm -rf "$b" || true; fi
    done
    echo "launcher bundle unchanged" >> "$log" 2>&1 || true
  else
    stage_identity=$(stat -f '%d:%i' "$loader_stage") || exit 1
    loader_backup=$(mktemp -d "$loader_root/.backup.XXXXXX") || exit 1
    finish_bundle() {
      result=$?
      trap - EXIT
      trap '' HUP INT TERM
      installed_identity=$(stat -f '%d:%i' "$loader_app" 2>/dev/null) || installed_identity=""
      if [ "$installed_identity" != "$stage_identity" ]; then
        for saved in "$loader_backup"/* "$loader_backup"/.[!.]*; do
          [ -e "$saved" ] || [ -L "$saved" ] || continue
          mv "$saved" "$loader_root/${saved##*/}" || result=1
        done
        rmdir "$loader_backup" 2>/dev/null || result=1
      else
        rm -rf "$loader_backup" || true
      fi
      rm -rf "$loader_work" || true
      exit "$result"
    }
    trap 'finish_bundle' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app "$loader_app"; do
      if [ -e "$b" ] || [ -L "$b" ]; then
        mv "$b" "$loader_backup/${b##*/}" || exit 1
      fi
    done
    mv "$loader_stage" "$loader_app" || exit 1
    echo "launcher bundle updated" >> "$log" 2>&1 || true
    finish_bundle
  fi
  rm -rf "$loader_work" || true
)
install_bundle

kill_wine_prefix() {
  "$WINESERVER" -k >> "$log" 2>&1 || true
  "$WINESERVER" -w >> "$log" 2>&1 || true
  if command -v lsof >/dev/null 2>&1 && server_dir=$(prefix_server_dir); then
    if [ -d "$server_dir" ]; then
      survivors=$(lsof -t +D "$server_dir" 2>/dev/null | sort -u)
      if [ -n "$survivors" ]; then
        echo "=== sweeping prefix stragglers: $survivors ===" >> "$log" 2>&1 || true
        # shellcheck disable=SC2086 # survivors is a list of pids and has to split
        kill -9 $survivors 2>/dev/null || true
      fi
    fi
  fi
}

# Steam's "Exit Game" and the client shutting the game down both send a
# termination signal to this run script, this handles it
# shellcheck disable=SC2329 # the trap below invokes this
terminate() {
  echo "=== termination signal received, killing wine prefix ===" >> "$log" 2>&1 || true
  kill_wine_prefix
  [ -n "$open_pid" ] && kill "$open_pid" 2>/dev/null || true
}
trap terminate TERM INT HUP

game_cwd="$(pwd)"
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  echo "=== overlay injected from $STEAM_DYLD_INSERT_LIBRARIES ===" >> "$log" 2>&1 || true
else
  echo "=== client staged no overlay renderer, overlay disabled ===" >> "$log" 2>&1 || true
fi
set -- --args "$shim_exe" "$@"
for name in $(env | LC_ALL=C sed -nE 's/^(Steam[A-Za-z0-9]*|VK_DRIVER_FILES|CX_APPLEGPTK_LIBD3DSHARED_PATH|(DXMT_|DXVK_|D3DM_|MTL_|ROSETTA_)[A-Z0-9_]*)=.*/\1/p'); do
  eval "value=\$$name"
  # shellcheck disable=SC2154 # eval assigns value on the line above
  set -- --env "$name=$value" "$@"
done
set -- \
  --env WINESERVER="$WINESERVER" \
  --env WINEDLLPATH="$WINEDLLPATH" \
  --env WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
  --env HADRON_DLL_OVERLAY="${HADRON_DLL_OVERLAY:-}" \
  --env WINEPREFIX="$WINEPREFIX" \
  --env WINEDEBUG="$WINEDEBUG" \
  --env PATH="$PATH" \
  --env STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH" \
  --env STEAM_COMPAT_INSTALL_PATH="$STEAM_COMPAT_INSTALL_PATH" \
  --env STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
  --env STEAM_COMPAT_APP_ID="$STEAM_COMPAT_APP_ID" \
  --env STEAM_DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES" \
  --env HADRON_GAME_CWD="$game_cwd" "$@"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A"
lsregister="$lsregister/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1 || true
open -n -W -a "$loader_app" "$@" >> "$log" 2>&1 &
open_pid=$!
status=0
wait "$open_pid" || status=$?
echo "=== game exited status=$status, killing wine prefix ===" >> "$log" 2>&1 || true
kill_wine_prefix
echo "=== wine prefix killed, session ending ===" >> "$log" 2>&1 || true
exit $status
