#!/bin/sh
# Packs staged runtimes for Hadron to download, and writes the manifest the app bundles.
#
#   ./release.sh [--publish] <tag> <runtime id>...
#
# Each runtime in out/runtime becomes hadron-<id>.tar.xz in out/release/<tag>, without
# D3DMetal, which Apple's Game Porting Toolkit licence keeps from being passed on; Hadron
# adds it from a copy the user has. app/Sources/HadronApp/Resources/runtimes.manifest then
# names the release and each archive's SHA-256 and size; entries for other runtimes in the
# same release stay. With --publish the archives go up as GitHub release <tag> of
# nheisterkamp/Hadron, or are added to it when it exists, which needs gh signed in.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }

publish=0
if [ "${1:-}" = --publish ]; then
    publish=1
    shift
fi
tag="${1:?usage: $0 [--publish] <tag> <runtime id>...}"
shift
[ $# -gt 0 ] || die "name at least one runtime"
case "$tag" in *[!A-Za-z0-9._-]*) die "$tag is not a tag name" ;; esac

github=nheisterkamp/Hadron
out="$repo/out/release/$tag"
work="$out/stage"
manifest="$repo/app/Sources/HadronApp/Resources/runtimes.manifest"
mkdir -p "$out"

lines=""
for id in "$@"; do
    staged="$repo/out/runtime/$id"
    [ -f "$staged/hadron-runtime" ] || die "$staged is not a staged runtime, build it first"
    [ "$(cat "$staged/hadron-runtime")" = "$id" ] || die "$staged holds another runtime"

    # A loader signed with a development profile runs on the Macs the profile lists and
    # is killed everywhere else.
    loader="$staged/lib/wine/aarch64-unix/Wine.app"
    if [ -d "$loader" ]; then
        security cms -D -i "$loader/Contents/embedded.provisionprofile" 2>/dev/null \
            | plutil -extract ProvisionedDevices raw -o - - >/dev/null 2>&1 \
            && die "$id is signed with a development profile, which only runs on its own devices; build it with a Developer ID profile (HADRON_PROVISIONING_PROFILE)"
    fi

    echo "==> staging $id"
    rm -rf "${work:?}/${id:?}"
    mkdir -p "$work"
    ditto "$staged" "$work/$id"
    rm -rf "${work:?}/${id:?}/lib/graphics/d3dmetal"

    archive="hadron-$id.tar.xz"
    echo "==> packing $archive"
    ( cd "$work" && COPYFILE_DISABLE=1 tar --no-mac-metadata -cf - "$id" ) | xz -T0 -8 > "$out/$archive.new"
    mv -f "$out/$archive.new" "$out/$archive"
    sha=$(shasum -a 256 "$out/$archive" | cut -d' ' -f1)
    bytes=$(stat -f %z "$out/$archive")
    echo "    $sha  $bytes bytes"
    lines="${lines}runtime  $id  $archive  $sha  $bytes
"
done
rm -rf "${work:?}"

# A runtime added to a release keeps the ones the manifest already lists for it.
base="https://github.com/$github/releases/download/$tag"
if grep -q "^base  *$base\$" "$manifest" 2>/dev/null; then
    kept=$(grep '^runtime ' "$manifest" | while read -r _ id rest; do
        case " $* " in (*" $id "*) ;; (*) echo "runtime  $id  $rest" ;; esac
    done)
    [ -z "$kept" ] || lines="$kept
$lines"
fi

{
    echo "# Wine runtimes Hadron downloads, written by runtime/release.sh. Each archive is"
    echo "# fetched from the base, checked against its SHA-256 and unpacked into runtimes/."
    echo
    echo "base     $base"
    echo
    printf '%s' "$lines"
} > "$manifest"
echo "==> wrote ${manifest#"$repo"/}"

if [ "$publish" = 1 ] && gh release view "$tag" --repo "$github" >/dev/null 2>&1; then
    echo "==> adding to release $tag on $github"
    for id in "$@"; do
        gh release upload "$tag" --repo "$github" --clobber "$out/hadron-$id.tar.xz"
    done
elif [ "$publish" = 1 ]; then
    echo "==> publishing release $tag on $github"
    # The tag goes on the commit the runtimes were built from, not the default branch.
    gh release create "$tag" --repo "$github" --target "$(git -C "$repo" rev-parse HEAD)" \
        --title "Wine runtimes $tag" \
        --notes "Wine runtimes for Hadron, downloaded and checked by the app. Built from the definitions and patches in runtime/ at this tag. D3DMetal is not included." \
        "$out"/hadron-*.tar.xz
fi
