#!/bin/sh
# Build a complete x86_64 (Rosetta) Wine runtime from source, so NotProton can run
# without CrossOver.
#
#   ./build-wine.sh     configure, build and stage into out/runtime/wine-<version>
#
# Uses the same pinned source tree as bridge/setup-wine-tree.sh, which has to run
# first: it registers lsteamclient and steam.exe with configure. The patches in
# runtime/patches are applied on top. The loader patch does in source what
# ntdll-patch does to CrossOver's binary, so this runtime needs no NtdllPatcher step.
#
# Third party libraries are x86_64 builds under DEPS, never the arm64 Homebrew ones.
# PKG_CONFIG_LIBDIR is pinned to DEPS so configure cannot pick up the wrong arch.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

WINE_VERSION="${WINE_VERSION:-11.15}"
WINE_COMMIT="${WINE_COMMIT:-2df1ee28039cf84776eb1421ed90bd154cebb65f}"
WINE_SRC="${WINE_SRC:-$repo/scratch/wine}"
WINE_BUILD="${WINE_BUILD:-$repo/scratch/wine-build-runtime}"
DEPS="${DEPS:-$repo/scratch/deps-x86_64}"
FREETYPE_URL="${FREETYPE_URL:-https://gitlab.freedesktop.org/freetype/freetype.git}"
FREETYPE_TAG="${FREETYPE_TAG:-VER-2-13-3}"
FREETYPE_SRC="${FREETYPE_SRC:-$repo/scratch/freetype}"
ADDONS="${ADDONS:-$repo/scratch/downloads/addons}"

# The versions Wine 11.15 asks for in dlls/appwiz.cpl/addons.c. Wine uses these shared
# from share/wine instead of installing them into every prefix. The pins are of the
# tarballs on dl.winehq.org; the mono one matches its GitHub release digest.
MONO_VERSION=11.2.0
GECKO_VERSION=2.47.4
ADDON_PINS="
wine-mono/$MONO_VERSION/wine-mono-$MONO_VERSION-x86.tar.xz c9fb2e2823acf30b000b8806177db0f40751786136dd3f8fb2be7897b1643d06 mono
wine-gecko/$GECKO_VERSION/wine-gecko-$GECKO_VERSION-x86.tar.xz 2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6 gecko
wine-gecko/$GECKO_VERSION/wine-gecko-$GECKO_VERSION-x86_64.tar.xz fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814 gecko
"
OUT="${OUT:-$repo/out/runtime/wine-$WINE_VERSION}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

PATH="/opt/homebrew/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/autoconf/bin:$PATH"
export PATH

die() { echo "error: $*" >&2; exit 1; }

# Wine dlopens its optional libraries by the name configure recorded. A bare name
# only resolves through DYLD_* variables, which SIP strips whenever /bin/sh sits in
# between, so the libraries are named relative to the unix modules that open them.
UNIX_TO_LIB="@loader_path/../.."

[ -d "$WINE_SRC/.git" ] || die "no wine source at $WINE_SRC, run bridge/setup-wine-tree.sh first"
[ "$(git -C "$WINE_SRC" rev-parse HEAD)" = "$WINE_COMMIT" ] || die "$WINE_SRC is not at $WINE_COMMIT"
grep -q 'WINE_CONFIG_MAKEFILE(dlls/lsteamclient)' "$WINE_SRC/configure.ac" \
    || die "lsteamclient is not registered, run bridge/setup-wine-tree.sh first"
if [ ! -f "$DEPS/lib/libfreetype.6.dylib" ]; then
    echo "==> building x86_64 freetype $FREETYPE_TAG into $DEPS"
    [ -d "$FREETYPE_SRC/.git" ] || git clone --depth 1 --branch "$FREETYPE_TAG" "$FREETYPE_URL" "$FREETYPE_SRC"
    cmake -S "$FREETYPE_SRC" -B "$FREETYPE_SRC-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=ON \
        -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
        -DFT_REQUIRE_ZLIB=ON -DCMAKE_INSTALL_PREFIX="$DEPS"
    ninja -C "$FREETYPE_SRC-build" install
    install_name_tool -id "$UNIX_TO_LIB/libfreetype.6.dylib" "$(readlink -f "$DEPS/lib/libfreetype.6.dylib")"
fi

for patch in "$here"/patches/*.patch; do
    if git -C "$WINE_SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "==> already applied: ${patch##*/}"
    else
        echo "==> applying ${patch##*/}"
        git -C "$WINE_SRC" apply "$patch"
    fi
done

if [ ! -f "$WINE_BUILD/Makefile" ]; then
    echo "==> configuring $WINE_BUILD"
    mkdir -p "$WINE_BUILD"
    ( cd "$WINE_BUILD" && PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" "$WINE_SRC/configure" \
        --prefix=/ --enable-archs=i386,x86_64 --without-x \
        --host=x86_64-apple-darwin CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
        FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
        ac_cv_lib_soname_freetype="$UNIX_TO_LIB/libfreetype.6.dylib" )
fi
grep -q '^host_cpu = x86_64' "$WINE_BUILD/config.status" \
    || die "configure did not take the x86_64 host"

# tools/sfnt2fon links freetype too, and runs from the build tree during the build.
ln -sf "$DEPS/lib/libfreetype.6.dylib" "$WINE_BUILD/libfreetype.6.dylib"

# lsteamclient.so is left to lsteamclient/build.sh. The tree's make links its C++
# objects without the C++ runtime, so -o keeps make from touching it.
skip="-o dlls/lsteamclient/lsteamclient.so"

echo "==> building with $JOBS jobs"
# shellcheck disable=SC2086
make -C "$WINE_BUILD" -j"$JOBS" $skip

# The component scripts build lsteamclient and the steam.exe shim against this tree.
WINE_BUILD="$WINE_BUILD" "$repo/lsteamclient/build.sh"
WINE_BUILD="$WINE_BUILD" "$repo/steam-shim/build.sh"

echo "==> staging into $OUT"
rm -rf "$OUT"
# shellcheck disable=SC2086
make -C "$WINE_BUILD" install-lib DESTDIR="$OUT" $skip
# steam.exe goes into each prefix from the bridge, as with CrossOver, not in as a builtin.
rm -f "$OUT"/lib/wine/*-windows/steam.exe
cp "$DEPS/lib/libfreetype.6.dylib" "$OUT/lib/"
for arch in i386-windows x86_64-windows; do
    cp "$WINE_BUILD/dlls/lsteamclient/$arch/lsteamclient.dll" "$OUT/lib/wine/$arch/"
done
cp "$WINE_BUILD/dlls/lsteamclient/lsteamclient.so" "$OUT/lib/wine/x86_64-unix/"

# compat_run.sh finds the loader where CrossOver keeps it.
[ -e "$OUT/lib/wine/x86_64-unix/wine" ] || cp "$OUT/bin/wine" "$OUT/lib/wine/x86_64-unix/wine"

# Wine builds with -g, which is most of the size. The x86_64 unix halves stay unsigned.
echo "==> stripping debug info"
find "$OUT/lib/wine/i386-windows" -type f -exec i686-w64-mingw32-strip --strip-debug {} +
find "$OUT/lib/wine/x86_64-windows" -type f -exec x86_64-w64-mingw32-strip --strip-debug {} +
find "$OUT/lib/wine/x86_64-unix" -type f -name '*.so' -exec strip -S {} +
strip -S "$OUT/bin/wine" "$OUT/bin/wineserver" "$OUT/lib/wine/x86_64-unix/wine"

echo "==> adding wine-mono $MONO_VERSION and wine-gecko $GECKO_VERSION"
mkdir -p "$ADDONS"
echo "$ADDON_PINS" | while read -r path sha subdir; do
    [ -n "$path" ] || continue
    tarball="$ADDONS/${path##*/}"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" "https://dl.winehq.org/wine/$path"
    [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$sha" ] || die "$tarball does not match its pin"
    mkdir -p "$OUT/share/wine/$subdir"
    tar -xJf "$tarball" -C "$OUT/share/wine/$subdir"
done

# The app identifies the runtime by this, see WineRuntime.swift.
echo "wine-$WINE_VERSION" > "$OUT/notproton-runtime"

echo "==> done: $OUT"
