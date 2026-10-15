#!/bin/sh
# Builds Hadron for release and offers it to Sparkle.
#
#   ./release.sh [--sign-only | --publish]
#
# Signs the app and every piece of code in it with Developer ID, the hardened runtime and
# a secure timestamp, has Apple notarize it and staples the ticket, signs the zip with the
# Sparkle key, and adds it to the appcast. --sign-only stops after signing, to check the
# app runs. --publish uploads the zip as GitHub release app-<version> and pushes the
# appcast to the updates branch, which SUFeedURL reads.
#
# Needs the "Developer ID Application" identity, notarytool credentials stored as
# "hadron" (xcrun notarytool store-credentials hadron) and the Sparkle key for account
# nl.nhsd.hadron (generate_keys --account nl.nhsd.hadron).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }

mode=release
case "${1:-}" in
    --sign-only) mode=sign ;;
    --publish) mode=publish ;;
    "") ;;
    *) die "usage: $0 [--sign-only | --publish]" ;;
esac

github=nheisterkamp/Hadron
account=nl.nhsd.hadron
profile=hadron
feed_branch=updates
sparkle="$here/.build/artifacts/sparkle/Sparkle/bin"

identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[ -n "$identity" ] || die "no Developer ID Application identity in the keychain"
if [ "$mode" != sign ]; then
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || die "no notarytool credentials named $profile; run: xcrun notarytool store-credentials $profile"
fi

version=$(sed -n 's/^#define HADRON_VERSION "\(.*\)"/\1/p' "$repo/dylib/version.h")
[ -n "$version" ] || die "no HADRON_VERSION in dylib/version.h"
tag="app-$version"
if [ "$mode" = publish ] && gh release view "$tag" --repo "$github" >/dev/null 2>&1; then
    die "release $tag exists; raise HADRON_VERSION in dylib/version.h first"
fi

echo "==> building Hadron $version"
make -C "$repo" app >/dev/null
app="$repo/out/Hadron.app"
out="$repo/out/release/$tag"
rm -rf "${out:?}"
mkdir -p "$out"

sign() {
    codesign -f -s "$identity" --options runtime --timestamp "$@"
}

# Inside out: the payload Hadron installs, then Sparkle's helpers, then Sparkle and the app.
echo "==> signing with $identity"
find "$app/Contents/Resources" -type f | while read -r file; do
    case "$(file -b "$file")" in
        Mach-O*) sign "$file" ;;
    esac
done
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$framework/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$framework/XPCServices/Downloader.xpc"
sign "$framework/Autoupdate"
sign "$framework/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app"
codesign --verify --deep --strict "$app"
echo "==> signed and verified"
[ "$mode" = sign ] && exit 0

zip="$out/Hadron-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "==> notarizing"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute "$app" || die "Gatekeeper still refuses the notarized app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "==> signing the update for Sparkle"
signature=$("$sparkle/sign_update" --account "$account" "$zip")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")

# The appcast lives on its own branch, so the feed's address never moves.
feed="$repo/out/release/feed"
if [ ! -d "$feed/.git" ]; then
    rm -rf "${feed:?}"
    if git -C "$repo" ls-remote --exit-code origin "refs/heads/$feed_branch" >/dev/null 2>&1; then
        git clone --quiet --branch "$feed_branch" --single-branch "$(git -C "$repo" remote get-url origin)" "$feed"
    else
        git init --quiet -b "$feed_branch" "$feed"
        git -C "$feed" remote add origin "$(git -C "$repo" remote get-url origin)"
    fi
fi
git -C "$feed" pull --quiet --ff-only origin "$feed_branch" 2>/dev/null || true
python3 - "$feed/appcast.xml" "$version" "$build" "$minimum" \
    "https://github.com/$github/releases/download/$tag/Hadron-$version.zip" "$signature" <<'PY'
import sys, os, email.utils
path, version, build, minimum, url, signature = sys.argv[1:]
item = f"""    <item>
      <title>Hadron {version}</title>
      <pubDate>{email.utils.formatdate()}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <enclosure url="{url}" type="application/octet-stream" {signature}/>
    </item>
"""
if os.path.exists(path):
    text = open(path).read()
    if f"<sparkle:version>{build}</sparkle:version>" in text:
        sys.exit(f"the appcast already lists build {build}")
    marker = "  <channel>\n    <title>Hadron</title>\n"
    if marker not in text:
        sys.exit("the appcast does not have the layout this script writes")
    text = text.replace(marker, marker + item, 1)
else:
    text = ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n    <title>Hadron</title>\n" + item + "  </channel>\n</rss>\n")
open(path, "w").write(text)
PY
echo "==> added $version to $feed/appcast.xml"

if [ "$mode" = publish ]; then
    echo "==> publishing $tag on $github"
    gh release create "$tag" --repo "$github" --target "$(git -C "$repo" rev-parse HEAD)" \
        --title "Hadron $version" --notes "Hadron $version. Hadron updates itself to this release through Sparkle." "$zip"
    git -C "$feed" add appcast.xml
    git -C "$feed" -c user.name="$(git -C "$repo" config user.name)" -c user.email="$(git -C "$repo" config user.email)" \
        commit --quiet -m "Hadron $version"
    git -C "$feed" push --quiet origin "$feed_branch"
    echo "==> published; the feed is https://raw.githubusercontent.com/$github/$feed_branch/appcast.xml"
else
    echo "==> ready in $out; run with --publish to release it"
fi
