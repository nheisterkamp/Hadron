#!/bin/sh
# Build one of Hadron's x86_64 (Rosetta) Wine runtimes.
#
#   ./build-wine.sh <id>    build the runtime runtime/runtimes/<id>.env describes
#   ./build-wine.sh --all   build every runtime there
#
# The result is staged into out/runtime/<id>. Each runtime gets its own source and
# build tree under scratch/runtimes/<id>, because wine-staging rewrites the source.
# The source is Wine at a pinned commit, or a pinned source tarball such as the one
# CodeWeavers publishes for CrossOver. wine-staging goes on top when the runtime names
# a release of it, then lsteamclient and steam.exe are registered with configure, and
# then come the patches in runtime/patches: they redirect steamclient to lsteamclient
# in the loader, name the profile steamuser, and let a DLL overlay stand in for
# builtins. A patch in runtime/patches/<id> replaces the one of the same name.
#
# Third party libraries are x86_64 builds under DEPS, never the arm64 Homebrew ones.
# PKG_CONFIG_LIBDIR is pinned to DEPS so configure cannot pick up the wrong arch.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

if [ "${1:-}" = --all ]; then
    for definition in "$here"/runtimes/*.env; do
        id="${definition##*/}"
        "$0" "${id%.env}"
    done
    exit 0
fi
[ $# -eq 1 ] || die "usage: $0 <runtime id> | --all"
definition="$here/runtimes/$1.env"
[ -f "$definition" ] || die "no runtime definition at $definition"
WINE_TAG=""
WINE_COMMIT=""
SOURCE_URL=""
SOURCE_SHA256=""
SOURCE_SUBDIR=""
STAGING_TAG=""
STAGING_COMMIT=""
# lsteamclient and steam.exe are built in the runtime's own tree unless this names
# another runtime to take them from, for a Wine too old to build them.
COMPONENTS_FROM=""
# shellcheck disable=SC1090
. "$definition"
[ "$RUNTIME_ID" = "$1" ] || die "$definition names itself $RUNTIME_ID"

WINE_URL="${WINE_URL:-https://gitlab.winehq.org/wine/wine.git}"
STAGING_URL="${STAGING_URL:-https://gitlab.winehq.org/wine/wine-staging.git}"
WORK="${WORK:-$repo/scratch/runtimes/$RUNTIME_ID}"
# The component scripts find the source at ../wine from the build tree.
WINE_SRC="$WORK/wine"
WINE_BUILD="$WORK/build"
STAGING_ROOT="${STAGING_ROOT:-$repo/scratch/staging}"
DEPS="${DEPS:-$repo/scratch/deps-x86_64}"
FREETYPE_URL="${FREETYPE_URL:-https://gitlab.freedesktop.org/freetype/freetype.git}"
FREETYPE_TAG="${FREETYPE_TAG:-VER-2-13-3}"
FREETYPE_SRC="${FREETYPE_SRC:-$repo/scratch/freetype}"
ADDONS="${ADDONS:-$repo/scratch/downloads/addons}"
DOWNLOADS="${DOWNLOADS:-$repo/scratch/downloads}"
OUT="${OUT:-$repo/out/runtime/$RUNTIME_ID}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Vulkan for winevulkan, DXVK and wined3d's Vulkan renderer. Pinned to the digest
# GitHub publishes for the release asset.
MOLTENVK_VERSION=1.4.2
MOLTENVK_SHA=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e

# Graphics backends are staged under lib/graphics/<name>, not over Wine's own DLLs, and
# the run script points HADRON_DLL_OVERLAY (patch 0003) at the ones a game picked.
# DXMT translates D3D10/11 to Metal.
DXMT_VERSION=0.80
DXMT_SHA=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d

# DXVK 3.1.1 and 1.10.3 for MoltenVK, D3D8/9 on its own from DXVK 3.1.1, and cnc-ddraw,
# from the wrapper template Sikarugir publishes. Its DLLs are native, so they are marked
# builtin here to load through the overlay.
TEMPLATE_URL=https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.21.tar.xz
TEMPLATE_SHA=bbe996e4e4375318485953d0c7818b7b4b0a4dc1f13303bcc584f99f7602f78d
TEMPLATE_BACKENDS="dxvk3:dxvk dxvk:dxvk1 d9vk:d9vk cnc_ddraw:ddraw"

# TLS for schannel, which game launchers need to log in. GnuTLS and Nettle are checked
# against their signatures (Zoltan Fridrich, Niels Möller), GMP against its published
# digest.
TLS_PINS="
gmp-6.3.0.tar.xz https://ftp.gnu.org/gnu/gmp a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
nettle-3.10.2.tar.gz https://ftp.gnu.org/gnu/nettle fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5
gnutls-3.8.13.tar.xz https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8 ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e
"
TLS_LIBS="libgmp.10.dylib libnettle.8.dylib libhogweed.6.dylib libgnutls.30.dylib"

# Each Wine asks for its own wine-mono and wine-gecko in dlls/appwiz.cpl/addons.c.
# Wine uses them shared from share/wine instead of installing them into every prefix.
# These are the tarballs on dl.winehq.org; the mono ones match their GitHub release
# digest. A Wine asking for a version not listed here stops the build.
ADDON_PINS="
wine-mono-10.4.1-x86.tar.xz a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb
wine-mono-11.2.0-x86.tar.xz c9fb2e2823acf30b000b8806177db0f40751786136dd3f8fb2be7897b1643d06
wine-mono-11.3.0-x86.tar.xz 54a1b0111c3fe4b785eae688af94d27e64995707ad648b6fee8000381b80d298
wine-gecko-2.47.4-x86.tar.xz 2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
wine-gecko-2.47.4-x86_64.tar.xz fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814
"

PATH="/opt/homebrew/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/autoconf/bin:$PATH"
export PATH

# Wine dlopens its optional libraries by the name configure recorded. A bare name
# only resolves through DYLD_* variables, which SIP strips whenever /bin/sh sits in
# between, so the libraries are named relative to the unix modules that open them.
UNIX_TO_LIB="@loader_path/../.."

echo "==> runtime $RUNTIME_ID ($RUNTIME_NAME)"

prepare_source() {
    if [ -f "$WINE_SRC/.hadron-prepared" ]; then
        echo "==> source tree ready: $WINE_SRC"
        return
    fi
    rm -rf "$WINE_SRC"
    mkdir -p "$WORK"
    if [ -n "$SOURCE_URL" ]; then
        tarball="$DOWNLOADS/${SOURCE_URL##*/}"
        mkdir -p "$DOWNLOADS"
        [ -f "$tarball" ] || curl -fsSL -o "$tarball" "$SOURCE_URL"
        [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$SOURCE_SHA256" ] || die "$tarball does not match its pin"
        echo "==> unpacking $SOURCE_SUBDIR from ${tarball##*/} into $WINE_SRC"
        mkdir -p "$WINE_SRC"
        depth=$(printf '%s' "$SOURCE_SUBDIR" | awk -F/ '{ print NF }')
        tar -xzf "$tarball" -C "$WINE_SRC" --strip-components "$depth" "$SOURCE_SUBDIR"
        # git apply wants a repository, and a base commit shows what the patches changed.
        git -C "$WINE_SRC" init --quiet
        git -C "$WINE_SRC" add -A
        git -C "$WINE_SRC" -c user.name=hadron -c user.email=hadron@localhost commit --quiet -m "${tarball##*/}"
    else
        echo "==> cloning $WINE_TAG into $WINE_SRC"
        git clone --quiet --depth 1 --branch "$WINE_TAG" "$WINE_URL" "$WINE_SRC"
        # A shallow clone of a tag records nothing about what it resolved to, so a moved
        # tag would change the build with no signal.
        [ "$(git -C "$WINE_SRC" rev-parse HEAD)" = "$WINE_COMMIT" ] \
            || die "$WINE_TAG is not at the pinned $WINE_COMMIT"
    fi

    if [ -n "$STAGING_TAG" ]; then
        staging="$STAGING_ROOT/$STAGING_TAG"
        [ -d "$staging/.git" ] \
            || git clone --quiet --depth 1 --branch "$STAGING_TAG" "$STAGING_URL" "$staging"
        [ "$(git -C "$staging" rev-parse HEAD)" = "$STAGING_COMMIT" ] \
            || die "wine-staging $STAGING_TAG is not at the pinned $STAGING_COMMIT"
        [ "$(cat "$staging/staging/upstream-commit")" = "$WINE_COMMIT" ] \
            || die "wine-staging $STAGING_TAG is made for another Wine commit"
        echo "==> applying wine-staging $STAGING_TAG"
        "$staging/staging/patchinstall.py" --destdir="$WINE_SRC" --all --no-autoconf
    fi

    if [ -z "$COMPONENTS_FROM" ]; then
        echo "==> registering lsteamclient and steam.exe with configure"
        git -C "$WINE_SRC" apply --include=configure.ac "$repo/bridge/register-components.diff"
    fi
    for patch in "$here"/patches/*.patch; do
        [ -f "$here/patches/$RUNTIME_ID/${patch##*/}" ] && patch="$here/patches/$RUNTIME_ID/${patch##*/}"
        echo "==> applying ${patch#"$here"/patches/}"
        git -C "$WINE_SRC" apply "$patch" || die "${patch##*/} does not apply to $RUNTIME_ID"
    done
    # configure is regenerated from configure.ac rather than patched, so the same
    # registration works on any Wine. wine-staging may also change the server protocol.
    ( cd "$WINE_SRC" && autoreconf -f && tools/make_requests )

    if [ -z "$COMPONENTS_FROM" ]; then
        "$repo/lsteamclient/fetch.sh"
        "$repo/steam-shim/fetch-headers.sh"
        # Whole trees, since makedep reads every source a Makefile.in lists.
        mkdir -p "$WINE_SRC/dlls/lsteamclient" "$WINE_SRC/programs/steam.exe"
        rsync -a "$repo/build/lsteamclient/" "$WINE_SRC/dlls/lsteamclient/"
        rsync -a --exclude build.sh --exclude gen-implib.sh --exclude fetch-headers.sh \
            "$repo/steam-shim/" "$WINE_SRC/programs/steam.exe/"
    fi
    touch "$WINE_SRC/.hadron-prepared"
}

prepare_source

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

if [ ! -f "$DEPS/lib/libMoltenVK.dylib" ]; then
    echo "==> adding x86_64 MoltenVK $MOLTENVK_VERSION to $DEPS"
    tarball="$DOWNLOADS/MoltenVK-$MOLTENVK_VERSION-macos.tar"
    mkdir -p "$DOWNLOADS" "$DEPS/lib"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
        "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK_VERSION/MoltenVK-macos.tar"
    [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$MOLTENVK_SHA" ] || die "$tarball does not match its pin"
    unpacked="$DOWNLOADS/MoltenVK-$MOLTENVK_VERSION"
    rm -rf "$unpacked" && mkdir -p "$unpacked"
    tar -xf "$tarball" -C "$unpacked"
    lipo -thin x86_64 "$unpacked/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" \
        -output "$DEPS/lib/libMoltenVK.dylib"
    install_name_tool -id "$UNIX_TO_LIB/libMoltenVK.dylib" "$DEPS/lib/libMoltenVK.dylib"
fi

# Builds one TLS library into DEPS and names it relative to whatever loads it, which is
# always another library in the runtime's lib.
build_tls_lib() {
    name=$1
    shift
    line=$(echo "$TLS_PINS" | awk -v n="$name" 'index($1, n "-") == 1')
    file=$(echo "$line" | awk '{ print $1 }')
    tarball="$DOWNLOADS/tls/$file"
    mkdir -p "$DOWNLOADS/tls"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" "$(echo "$line" | awk '{ print $2 }')/$file"
    [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$(echo "$line" | awk '{ print $3 }')" ] \
        || die "$tarball does not match its pin"
    src="$repo/scratch/tls/${file%.tar.*}"
    rm -rf "$src" && mkdir -p "$repo/scratch/tls"
    tar -xf "$tarball" -C "$repo/scratch/tls"
    echo "==> building x86_64 ${file%.tar.*} into $DEPS"
    ( cd "$src" && ./configure --quiet --host=x86_64-apple-darwin --prefix="$DEPS" \
        --enable-shared --disable-static CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
        CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names" \
        PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" "$@" && make -j"$JOBS" && make install )
}

if [ ! -f "$DEPS/lib/libgnutls.30.dylib" ]; then
    build_tls_lib gmp --disable-assembly
    build_tls_lib nettle --disable-documentation --disable-openssl
    build_tls_lib gnutls --disable-doc --disable-tests --disable-tools --disable-cxx \
        --disable-guile --disable-nls --without-p11-kit --with-included-libtasn1 \
        --with-included-unistring --without-idn --without-brotli --without-zstd \
        --without-tpm --without-tpm2
    for lib in $TLS_LIBS; do
        install_name_tool -id "@loader_path/$lib" "$DEPS/lib/$lib"
        for dep in $TLS_LIBS; do
            install_name_tool -change "$DEPS/lib/$dep" "@loader_path/$dep" "$DEPS/lib/$lib"
        done
    done
fi

if [ ! -f "$WINE_BUILD/Makefile" ]; then
    echo "==> configuring $WINE_BUILD"
    mkdir -p "$WINE_BUILD"
    ( cd "$WINE_BUILD" && PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" "$WINE_SRC/configure" \
        --prefix=/ --enable-archs=i386,x86_64 --without-x \
        --host=x86_64-apple-darwin CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
        FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
        ac_cv_lib_soname_freetype="$UNIX_TO_LIB/libfreetype.6.dylib" \
        ac_cv_lib_soname_MoltenVK="$UNIX_TO_LIB/libMoltenVK.dylib" \
        ac_cv_lib_soname_gnutls="$UNIX_TO_LIB/libgnutls.30.dylib" )
fi
grep -q '^host_cpu = x86_64' "$WINE_BUILD/config.status" \
    || die "configure did not take the x86_64 host"
grep -q 'SONAME_LIBVULKAN "@loader_path' "$WINE_BUILD/include/config.h" \
    || die "configure did not take MoltenVK, remove $WINE_BUILD to configure again"
grep -q 'SONAME_LIBGNUTLS "@loader_path' "$WINE_BUILD/include/config.h" \
    || die "configure did not take GnuTLS, remove $WINE_BUILD to configure again"

# tools/sfnt2fon links freetype too, and runs from the build tree during the build.
ln -sf "$DEPS/lib/libfreetype.6.dylib" "$WINE_BUILD/libfreetype.6.dylib"

# lsteamclient.so is left to lsteamclient/build.sh. The tree's make links its C++
# objects without the C++ runtime, so -o keeps make from touching it.
skip="-o dlls/lsteamclient/lsteamclient.so"

echo "==> building with $JOBS jobs"
# shellcheck disable=SC2086
make -C "$WINE_BUILD" -j"$JOBS" $skip

# The component scripts build lsteamclient and the steam.exe shim against this tree.
if [ -z "$COMPONENTS_FROM" ]; then
    WINE_BUILD="$WINE_BUILD" "$repo/lsteamclient/build.sh"
    WINE_BUILD="$WINE_BUILD" "$repo/steam-shim/build.sh"
fi

echo "==> staging into $OUT"
rm -rf "$OUT"
# shellcheck disable=SC2086
make -C "$WINE_BUILD" install-lib DESTDIR="$OUT" $skip
# steam.exe goes into each prefix from the bridge, not in as a builtin.
rm -f "$OUT"/lib/wine/*-windows/steam.exe
cp "$DEPS/lib/libfreetype.6.dylib" "$DEPS/lib/libMoltenVK.dylib" "$OUT/lib/"
for lib in $TLS_LIBS; do cp "$DEPS/lib/$lib" "$OUT/lib/"; done
if [ -n "$COMPONENTS_FROM" ]; then
    # Its unixlib interface is stable across Wine 11, so these load in the older Wine.
    donor="$repo/out/runtime/$COMPONENTS_FROM/lib/wine"
    [ -f "$donor/x86_64-unix/lsteamclient.so" ] || die "build $COMPONENTS_FROM first, $RUNTIME_ID takes lsteamclient from it"
    for arch in i386-windows x86_64-windows x86_64-unix; do
        cp "$donor/$arch"/lsteamclient.* "$OUT/lib/wine/$arch/"
    done
else
    for arch in i386-windows x86_64-windows; do
        cp "$WINE_BUILD/dlls/lsteamclient/$arch/lsteamclient.dll" "$OUT/lib/wine/$arch/"
    done
    cp "$WINE_BUILD/dlls/lsteamclient/lsteamclient.so" "$OUT/lib/wine/x86_64-unix/"
fi

# compat_run.sh runs the loader from the unix dir, beside ntdll.so.
[ -e "$OUT/lib/wine/x86_64-unix/wine" ] || cp "$OUT/bin/wine" "$OUT/lib/wine/x86_64-unix/wine"

# Wine builds with -g, which is most of the size. The x86_64 unix halves stay unsigned.
echo "==> stripping debug info"
find "$OUT/lib/wine/i386-windows" -type f -exec i686-w64-mingw32-strip --strip-debug {} +
find "$OUT/lib/wine/x86_64-windows" -type f -exec x86_64-w64-mingw32-strip --strip-debug {} +
find "$OUT/lib/wine/x86_64-unix" -type f -name '*.so' -exec strip -S {} +
strip -S "$OUT/bin/wine" "$OUT/bin/wineserver" "$OUT/lib/wine/x86_64-unix/wine"

addons_c="$WINE_SRC/dlls/appwiz.cpl/addons.c"
mono_version=$(sed -n 's/^#define MONO_VERSION "\(.*\)"$/\1/p' "$addons_c")
gecko_version=$(sed -n 's/^#define GECKO_VERSION "\(.*\)"$/\1/p' "$addons_c")
[ -n "$mono_version" ] && [ -n "$gecko_version" ] || die "no add-on versions in $addons_c"
echo "==> adding wine-mono $mono_version and wine-gecko $gecko_version"
mkdir -p "$ADDONS"
for addon in "mono/wine-mono/$mono_version/wine-mono-$mono_version-x86.tar.xz" \
             "gecko/wine-gecko/$gecko_version/wine-gecko-$gecko_version-x86.tar.xz" \
             "gecko/wine-gecko/$gecko_version/wine-gecko-$gecko_version-x86_64.tar.xz"; do
    subdir="${addon%%/*}"
    path="${addon#*/}"
    name="${path##*/}"
    sha=$(echo "$ADDON_PINS" | awk -v n="$name" '$1 == n { print $2 }')
    [ -n "$sha" ] || die "no pin for $name, add its sha256 to ADDON_PINS"
    tarball="$ADDONS/$name"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" "https://dl.winehq.org/wine/$path"
    [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$sha" ] || die "$tarball does not match its pin"
    mkdir -p "$OUT/share/wine/$subdir"
    tar -xJf "$tarball" -C "$OUT/share/wine/$subdir"
done

echo "==> adding DXMT $DXMT_VERSION under lib/graphics/dxmt"
tarball="$DOWNLOADS/dxmt-v$DXMT_VERSION-builtin.tar.gz"
[ -f "$tarball" ] || curl -fsSL -o "$tarball" \
    "https://github.com/3Shain/dxmt/releases/download/v$DXMT_VERSION/dxmt-v$DXMT_VERSION-builtin.tar.gz"
[ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$DXMT_SHA" ] || die "$tarball does not match its pin"
mkdir -p "$OUT/lib/graphics/dxmt"
tar -xzf "$tarball" -C "$OUT/lib/graphics/dxmt" --strip-components 1
# winemetal is DXMT's bridge to Metal, imported by its d3d11 and dxgi. Wine resolves
# a builtin only when the prefix has a placeholder for it, and wineboot makes those
# for what is in lib/wine, so winemetal goes there. Nothing else imports it.
for arch in i386-windows x86_64-windows x86_64-unix; do
    cp "$OUT"/lib/graphics/dxmt/$arch/winemetal.* "$OUT/lib/wine/$arch/"
done

tarball="$DOWNLOADS/${TEMPLATE_URL##*/}"
[ -f "$tarball" ] || curl -fsSL -o "$tarball" "$TEMPLATE_URL"
[ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$TEMPLATE_SHA" ] || die "$tarball does not match its pin"
renderers="$DOWNLOADS/template-renderers"
if [ ! -d "$renderers" ]; then
    rm -rf "$renderers.new" && mkdir -p "$renderers.new"
    template="${tarball##*/}"
    tar -xJf "$tarball" -C "$renderers.new" --strip-components 4 \
        "${template%.tar.xz}.app/Contents/Frameworks/renderer"
    mv "$renderers.new" "$renderers"
fi
for pair in $TEMPLATE_BACKENDS; do
    from="${pair%%:*}"
    name="${pair#*:}"
    echo "==> adding $(head -1 "$renderers/$from/version") under lib/graphics/$name"
    for arch in i386-windows x86_64-windows; do
        [ -d "$renderers/$from/wine/$arch" ] || continue
        mkdir -p "$OUT/lib/graphics/$name/$arch"
        for dll in "$renderers/$from/wine/$arch"/*.dll; do
            cp "$dll" "$OUT/lib/graphics/$name/$arch/"
            "$WINE_BUILD/tools/winebuild/winebuild" --builtin "$OUT/lib/graphics/$name/$arch/${dll##*/}"
        done
    done
    cp "$renderers/$from/LICENSE" "$renderers/$from/version" "$OUT/lib/graphics/$name/"
done

# The app identifies the runtime by this, see RuntimeSource.swift.
echo "$RUNTIME_ID" > "$OUT/hadron-runtime"

echo "==> done: $OUT"
