#!/bin/sh
# Build one of Hadron's Wine runtimes: x86_64 ones that run under Rosetta, or an arm64
# one (ARCH=arm64 in its definition) that runs natively and emulates x86 with FEX.
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
# Third party libraries are built for the runtime's arch under DEPS, never taken from
# Homebrew. PKG_CONFIG_LIBDIR is pinned to DEPS so configure cannot pick up the wrong arch.
#
# An arm64 runtime needs macOS 26.5. Its loader maps over a large PAGEZERO and starts
# itself with 4K pages (patch 0004 in patches/wine-11.19-fex), which only a process signed with the
# com.apple.developer.cross-architecture-support entitlement may do, and an entitlement
# like that only holds for the main executable of an app bundle with a provisioning
# profile, and the kernel kills it at launch when it is signed by a certificate the
# profile does not list. So the loader becomes lib/wine/aarch64-unix/Wine.app, signed with
# HADRON_SIGN_IDENTITY (default: an identity whose certificate the profile lists) and the profile
# HADRON_PROVISIONING_PROFILE (default: the newest installed one for WINE_BUNDLE_ID
# that grants the entitlement).
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
ARCH=x86_64
# yes for a Wine with CodeWeavers' D3DMetal glue, see where D3DMetal is staged.
D3DMETAL=""
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
case "$ARCH" in
    x86_64)
        HOST=x86_64-apple-darwin HOST_CPU=x86_64 WINE_ARCHS=i386,x86_64
        UNIX_DIR=x86_64-unix PE64_DIR=x86_64-windows
        CC_ARCH="clang -arch x86_64" CXX_ARCH="clang++ -arch x86_64" ;;
    arm64)
        # llvm-mingw on PATH has its own clang, so the Mac compiler is named in full.
        HOST=aarch64-apple-darwin HOST_CPU=aarch64 WINE_ARCHS=arm64ec,aarch64,i386
        UNIX_DIR=aarch64-unix PE64_DIR=aarch64-windows
        CC_ARCH="/usr/bin/clang -arch arm64" CXX_ARCH="/usr/bin/clang++ -arch arm64" ;;
    *) die "$definition has ARCH=$ARCH, expected x86_64 or arm64" ;;
esac
DEPS="${DEPS:-$repo/scratch/deps-$ARCH}"
FREETYPE_URL="${FREETYPE_URL:-https://gitlab.freedesktop.org/freetype/freetype.git}"
FREETYPE_TAG="${FREETYPE_TAG:-VER-2-13-3}"
FREETYPE_SRC="${FREETYPE_SRC:-$repo/scratch/freetype}"
ADDONS="${ADDONS:-$repo/scratch/downloads/addons}"
DOWNLOADS="${DOWNLOADS:-$repo/scratch/downloads}"
OUT="${OUT:-$repo/out/runtime/$RUNTIME_ID}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# arm64 only: llvm-mingw builds the ARM64EC, ARM64 and i386 PE side, and FEX, at a
# pinned release, runs x86 code. FEX goes in as Wine's default emulators, xtajit64.dll
# for x86_64 and xtajit.dll for i386, so a prefix finds them from its first boot.
LLVM_MINGW_VERSION=20261006
LLVM_MINGW_SHA=a7a19b11048e89372637d26279cdb7c430ed3cf8c1e224310421312bf986ebf6
FEX_TAG=FEX-2610
FEX_COMMIT=14c92681f4d62cf84d901460e0358de09c8847a7
FEX_URL="${FEX_URL:-https://github.com/FEX-Emu/FEX.git}"
WINE_BUNDLE_ID="${WINE_BUNDLE_ID:-nl.nhsd.hadron.wine}"

# Vulkan for winevulkan, DXVK and wined3d's Vulkan renderer. Wine loads the Khronos
# loader, which takes its driver from VK_DRIVER_FILES: MoltenVK, or KosmicKrisp (Mesa's
# Vulkan 1.3+ driver on Metal) for DXVK 3, which MoltenVK cannot run. MoltenVK is pinned
# to the digest GitHub publishes; the loader and KosmicKrisp come from the template below.
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
wine-mono-11.3.0-arm64.tar.xz 227cbeef943c71d9bbcbd9d00ea026decbc4ecfb758346f13d2a34a7fd8ecfcf
wine-gecko-2.47.4-x86.tar.xz 2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
wine-gecko-2.47.4-x86_64.tar.xz fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814
"

PATH="/opt/homebrew/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/autoconf/bin:$PATH"
if [ "$ARCH" = arm64 ]; then
    llvm_mingw="$DOWNLOADS/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
    if [ ! -x "$llvm_mingw/bin/arm64ec-w64-mingw32-clang" ]; then
        tarball="$llvm_mingw.tar.xz"
        mkdir -p "$DOWNLOADS"
        [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
            "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/${tarball##*/}"
        [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$LLVM_MINGW_SHA" ] || die "$tarball does not match its pin"
        tar -xJf "$tarball" -C "$DOWNLOADS"
    fi
    PATH="$llvm_mingw/bin:$PATH"
fi
export PATH

# Wine dlopens its optional libraries by the name configure recorded. A bare name
# only resolves through DYLD_* variables, which SIP strips whenever /bin/sh sits in
# between, so the libraries are named relative to the unix modules that open them.
UNIX_TO_LIB="@loader_path/../.."

echo "==> runtime $RUNTIME_ID ($RUNTIME_NAME)"

# Every runtime gets patches/*.patch, where patches/<runtime>/ may replace one by
# name. A patch only in patches/<runtime>/ is for that runtime alone.
runtime_patches() {
    for name in $( (cd "$here/patches" && ls ./*.patch; [ -d "$RUNTIME_ID" ] && cd "$RUNTIME_ID" && ls ./*.patch) \
        | sed 's|^\./||' | sort -u); do
        if [ -f "$here/patches/$RUNTIME_ID/$name" ]; then
            echo "$here/patches/$RUNTIME_ID/$name"
        else
            echo "$here/patches/$name"
        fi
    done
}

prepare_source() {
    if [ -f "$WINE_SRC/.hadron-prepared" ]; then
        echo "==> source tree ready: $WINE_SRC"
        # A patch added since the tree was prepared goes on top. One already there
        # reverses cleanly.
        for patch in $(runtime_patches); do
            git -C "$WINE_SRC" apply --reverse --check "$patch" 2>/dev/null && continue
            echo "==> applying ${patch#"$here"/patches/} to the prepared tree"
            git -C "$WINE_SRC" apply "$patch" || die "${patch##*/} does not apply to $RUNTIME_ID"
            if grep -qE '^\+\+\+ b/(configure\.ac|server/protocol\.def)' "$patch"; then
                ( cd "$WINE_SRC" && autoreconf -f && tools/make_requests )
            fi
        done
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
    for patch in $(runtime_patches); do
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
    echo "==> building $ARCH freetype $FREETYPE_TAG into $DEPS"
    [ -d "$FREETYPE_SRC/.git" ] || git clone --depth 1 --branch "$FREETYPE_TAG" "$FREETYPE_URL" "$FREETYPE_SRC"
    cmake -S "$FREETYPE_SRC" -B "$FREETYPE_SRC-build-$ARCH" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=/usr/bin/clang \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=ON \
        -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
        -DFT_REQUIRE_ZLIB=ON -DCMAKE_INSTALL_PREFIX="$DEPS"
    ninja -C "$FREETYPE_SRC-build-$ARCH" install
    install_name_tool -id "$UNIX_TO_LIB/libfreetype.6.dylib" "$(readlink -f "$DEPS/lib/libfreetype.6.dylib")"
fi

if [ ! -f "$DEPS/lib/libMoltenVK.dylib" ]; then
    echo "==> adding $ARCH MoltenVK $MOLTENVK_VERSION to $DEPS"
    tarball="$DOWNLOADS/MoltenVK-$MOLTENVK_VERSION-macos.tar"
    mkdir -p "$DOWNLOADS" "$DEPS/lib"
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
        "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK_VERSION/MoltenVK-macos.tar"
    [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$MOLTENVK_SHA" ] || die "$tarball does not match its pin"
    unpacked="$DOWNLOADS/MoltenVK-$MOLTENVK_VERSION"
    rm -rf "$unpacked" && mkdir -p "$unpacked"
    tar -xf "$tarball" -C "$unpacked"
    lipo -thin "$ARCH" "$unpacked/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" \
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
    src="$repo/scratch/tls/$ARCH/${file%.tar.*}"
    rm -rf "$src" && mkdir -p "$repo/scratch/tls/$ARCH"
    tar -xf "$tarball" -C "$repo/scratch/tls/$ARCH"
    echo "==> building $ARCH ${file%.tar.*} into $DEPS"
    ( cd "$src" && ./configure --quiet --host="$HOST" --prefix="$DEPS" \
        --enable-shared --disable-static CC="$CC_ARCH" CXX="$CXX_ARCH" \
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
    # steam.exe comes from the bridge, and llvm-mingw cannot build its i386 half.
    disable=""
    [ "$ARCH" = x86_64 ] || disable="--disable-steam.exe"
    # shellcheck disable=SC2086
    ( cd "$WINE_BUILD" && PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" "$WINE_SRC/configure" \
        --prefix=/ --enable-archs="$WINE_ARCHS" --without-x $disable \
        --host="$HOST" CC="$CC_ARCH" CXX="$CXX_ARCH" \
        FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
        ac_cv_lib_soname_freetype="$UNIX_TO_LIB/libfreetype.6.dylib" \
        ac_cv_lib_soname_vulkan="$UNIX_TO_LIB/libvulkan.1.dylib" \
        ac_cv_lib_soname_gnutls="$UNIX_TO_LIB/libgnutls.30.dylib" )
fi
grep -q "^host_cpu = $HOST_CPU" "$WINE_BUILD/config.status" \
    || die "configure did not take the $HOST_CPU host"
grep -q 'SONAME_LIBVULKAN "@loader_path/../../libvulkan.1.dylib"' "$WINE_BUILD/include/config.h" \
    || die "configure did not take the Vulkan loader, remove $WINE_BUILD to configure again"
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
# On arm64 the tree's make builds the PE halves, ARM64X (for ARM64EC games) and i386,
# and the script only the unix half.
if [ -z "$COMPONENTS_FROM" ] && [ "$ARCH" = x86_64 ]; then
    WINE_BUILD="$WINE_BUILD" "$repo/lsteamclient/build.sh"
    WINE_BUILD="$WINE_BUILD" "$repo/steam-shim/build.sh"
elif [ -z "$COMPONENTS_FROM" ]; then
    make -C "$WINE_BUILD" -j"$JOBS" dlls/lsteamclient/aarch64-windows/lsteamclient.dll \
        dlls/lsteamclient/i386-windows/lsteamclient.dll
    UNIX_ARCH=arm64 WINE_BUILD="$WINE_BUILD" WINE_SRC_REL=../wine "$repo/lsteamclient/build.sh" --unix
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
    [ -f "$donor/$UNIX_DIR/lsteamclient.so" ] || die "build $COMPONENTS_FROM first, $RUNTIME_ID takes lsteamclient from it"
    for arch in i386-windows "$PE64_DIR" "$UNIX_DIR"; do
        cp "$donor/$arch"/lsteamclient.* "$OUT/lib/wine/$arch/"
    done
else
    for arch in i386-windows "$PE64_DIR"; do
        cp "$WINE_BUILD/dlls/lsteamclient/$arch/lsteamclient.dll" "$OUT/lib/wine/$arch/"
    done
    cp "$WINE_BUILD/dlls/lsteamclient/lsteamclient.so" "$OUT/lib/wine/$UNIX_DIR/"
fi

# compat_run.sh runs the loader from the unix dir, beside ntdll.so.
[ -e "$OUT/lib/wine/$UNIX_DIR/wine" ] || cp "$OUT/bin/wine" "$OUT/lib/wine/$UNIX_DIR/wine"

# Wine builds with -g, which is most of the size. The x86_64 unix halves stay unsigned,
# because a signed x86_64 builtin no longer loads. arm64 is the other way round: an
# arm64 image needs the signature its linker gave it, which strip would break and a
# codesign ad hoc signature does not replace (the loader is killed when it maps one),
# so on arm64 only the PE side is stripped.
echo "==> stripping debug info"
if [ "$ARCH" = x86_64 ]; then
    find "$OUT/lib/wine/i386-windows" -type f -exec i686-w64-mingw32-strip --strip-debug {} +
    find "$OUT/lib/wine/x86_64-windows" -type f -exec x86_64-w64-mingw32-strip --strip-debug {} +
    find "$OUT/lib/wine/x86_64-unix" -type f -name '*.so' -exec strip -S {} +
    strip -S "$OUT/bin/wine" "$OUT/bin/wineserver" "$OUT/lib/wine/x86_64-unix/wine"
else
    find "$OUT/lib/wine/i386-windows" "$OUT/lib/wine/aarch64-windows" -type f -exec llvm-strip --strip-debug {} +
fi

addons_c="$WINE_SRC/dlls/appwiz.cpl/addons.c"
mono_version=$(sed -n 's/^#define MONO_VERSION "\(.*\)"$/\1/p' "$addons_c")
gecko_version=$(sed -n 's/^#define GECKO_VERSION "\(.*\)"$/\1/p' "$addons_c")
[ -n "$mono_version" ] && [ -n "$gecko_version" ] || die "no add-on versions in $addons_c"
mkdir -p "$ADDONS"
# An arm64 Wine asks for the arm64 build of wine-mono, and there is no wine-gecko for it.
if [ "$ARCH" = x86_64 ]; then
    addons="mono/wine-mono/$mono_version/wine-mono-$mono_version-x86.tar.xz
gecko/wine-gecko/$gecko_version/wine-gecko-$gecko_version-x86.tar.xz
gecko/wine-gecko/$gecko_version/wine-gecko-$gecko_version-x86_64.tar.xz"
else
    addons="mono/wine-mono/$mono_version/wine-mono-$mono_version-arm64.tar.xz"
fi
echo "==> adding $(echo "$addons" | sed 's|.*/||' | tr '\n' ' ')"
for addon in $addons; do
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

# DXMT and D3DMetal have x86_64 unix halves, so they are for the Rosetta runtimes only.
if [ "$ARCH" = x86_64 ]; then
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
fi

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
# The Vulkan loader and KosmicKrisp, beside MoltenVK, each with a driver manifest whose
# path is relative to the manifest.
template="${tarball##*/}"
frameworks="${template%.tar.xz}.app/Contents/Frameworks"
vulkan="$DOWNLOADS/template-vulkan"
if [ ! -d "$vulkan" ]; then
    rm -rf "$vulkan.new" && mkdir -p "$vulkan.new"
    tar -xJf "$tarball" -C "$vulkan.new" --strip-components 3 \
        "$frameworks/libvulkan.1.4.363.dylib" "$frameworks/libvulkan_kosmickrisp.dylib"
    mv "$vulkan.new" "$vulkan"
fi
# The loader is universal; KosmicKrisp is x86_64 only, so arm64 has MoltenVK alone.
lipo -thin "$ARCH" "$vulkan/libvulkan.1.4.363.dylib" -output "$OUT/lib/libvulkan.1.dylib"
drivers="MoltenVK:libMoltenVK.dylib:1.4.0"
if [ "$ARCH" = x86_64 ]; then
    cp "$vulkan/libvulkan_kosmickrisp.dylib" "$OUT/lib/"
    drivers="$drivers kosmickrisp:libvulkan_kosmickrisp.dylib:1.4.363"
fi
mkdir -p "$OUT/share/vulkan/icd.d"
for driver in $drivers; do
    printf '{\n    "file_format_version": "1.0.1",\n    "ICD": {\n        "library_path": "../../../lib/%s",\n        "api_version": "%s"\n    }\n}\n' \
        "$(echo "$driver" | cut -d: -f2)" "$(echo "$driver" | cut -d: -f3)" \
        > "$OUT/share/vulkan/icd.d/$(echo "$driver" | cut -d: -f1)_icd.json"
done

# These are x86 PE only, which FEX runs on arm64. An ARM64EC process looks for 64-bit
# builtins in aarch64-windows, so that is where the x86_64 ones go there.
backends="$TEMPLATE_BACKENDS"
[ "$ARCH" = x86_64 ] || backends="dxvk:dxvk1 cnc_ddraw:ddraw"
for pair in $backends; do
    from="${pair%%:*}"
    name="${pair#*:}"
    echo "==> adding $(head -1 "$renderers/$from/version") under lib/graphics/$name"
    for arch in i386-windows x86_64-windows; do
        [ -d "$renderers/$from/wine/$arch" ] || continue
        to=$arch
        [ "$arch" = i386-windows ] || to=$PE64_DIR
        mkdir -p "$OUT/lib/graphics/$name/$to"
        for dll in "$renderers/$from/wine/$arch"/*.dll; do
            cp "$dll" "$OUT/lib/graphics/$name/$to/"
            "$WINE_BUILD/tools/winebuild/winebuild" --builtin "$OUT/lib/graphics/$name/$to/${dll##*/}"
        done
    done
    cp "$renderers/$from/LICENSE" "$renderers/$from/version" "$OUT/lib/graphics/$name/"
done

# D3DMetal, Apple's D3D11/12 on Metal from the Game Porting Toolkit. It needs the glue
# CodeWeavers keeps in their Wine, and it calls its unix code straight from Windows code,
# which only works in a Wine that leaves %gs alone on macOS, as theirs does and upstream
# Wine no longer does. So only a runtime with D3DMETAL=yes gets it. Its DLLs are marked
# builtin already. Its unix modules are one library under six names, which have to stay
# links to it so they load as one image with shared state.
if [ "$D3DMETAL" = yes ]; then
echo "==> adding D3DMetal under lib/graphics/d3dmetal"
d3dmetal="$renderers/d3dmetal"
mkdir -p "$OUT/lib/graphics/d3dmetal/x86_64-windows" "$OUT/lib/graphics/d3dmetal/x86_64-unix"
cp "$d3dmetal"/wine/x86_64-windows/*.dll "$OUT/lib/graphics/d3dmetal/x86_64-windows/"
cp "$d3dmetal/external/libd3dshared.dylib" "$OUT/lib/graphics/d3dmetal/x86_64-unix/"
for so in "$d3dmetal"/wine/x86_64-unix/*.so; do
    ln -s libd3dshared.dylib "$OUT/lib/graphics/d3dmetal/x86_64-unix/${so##*/}"
done
cp -R "$d3dmetal/external/D3DMetal.framework" "$OUT/lib/graphics/d3dmetal/x86_64-unix/"
cp "$d3dmetal"/*.rtf "$OUT/lib/graphics/d3dmetal/"
fi

if [ "$ARCH" = arm64 ]; then
    # FEX at its pin with runtime/fex on top, which lets its unix half switch threads to
    # hardware TSO on macOS when HADRON_FEX_HARDWARE_TSO=1; by default FEX orders memory
    # itself. The builds are incremental, so they run every time.
    fex="$repo/scratch/fex/$FEX_TAG"
    if [ ! -d "$fex/.git" ]; then
        git clone --quiet --depth 1 --branch "$FEX_TAG" --recurse-submodules --shallow-submodules "$FEX_URL" "$fex"
    fi
    [ "$(git -C "$fex" rev-parse HEAD)" = "$FEX_COMMIT" ] || die "$FEX_TAG is not at the pinned $FEX_COMMIT"
    if [ ! -f "$fex/.hadron-patched" ]; then
        for patch in "$here"/fex/*.patch; do
            echo "==> applying fex/${patch##*/}"
            git -C "$fex" apply "$patch" || die "${patch##*/} does not apply to $FEX_TAG"
        done
        touch "$fex/.hadron-patched"
    fi
    for target in arm64ec:arm64ec wow64:aarch64; do
        echo "==> building FEX $FEX_TAG for ${target%%:*}"
        [ -f "$fex/build_${target%%:*}/build.ninja" ] || cmake -S "$fex" -B "$fex/build_${target%%:*}" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$fex/Data/CMake/toolchain_mingw.cmake" \
            -DMINGW_TRIPLE="${target#*:}-w64-mingw32" -DENABLE_LTO=False -DENABLE_ASSERTIONS=False \
            -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DBUILD_TESTING=False -DTUNE_ARCH=generic \
            -DTUNE_CPU=none -DRANGES_NATIVE=OFF
        cmake --build "$fex/build_${target%%:*}"
    done
    echo "==> building FEX's unix half"
    [ -f "$fex/build_unixlib/build.ninja" ] || cmake -S "$fex/Source/Windows/UnixLib" -B "$fex/build_unixlib" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.5
    cmake --build "$fex/build_unixlib"

    # install_name_tool keeps a linker signature valid but breaks a codesign one, such as
    # MoltenVK's, and an arm64 library without a valid signature takes the process down.
    for lib in "$OUT"/lib/*.dylib; do
        codesign -v "$lib" 2>/dev/null || codesign -f -s - "$lib"
    done

    echo "==> adding FEX $FEX_TAG as xtajit64.dll and xtajit.dll"
    cp "$fex/build_arm64ec/Bin/libarm64ecfex.dll" "$OUT/lib/wine/aarch64-windows/xtajit64.dll"
    cp "$fex/build_wow64/Bin/libwow64fex.dll" "$OUT/lib/wine/aarch64-windows/xtajit.dll"
    for dll in xtajit64.dll xtajit.dll; do
        "$WINE_BUILD/tools/winebuild/winebuild" --builtin "$OUT/lib/wine/aarch64-windows/$dll"
    done
    # FEX loads these by name from the unix dir.
    cp "$fex/build_unixlib/libarm64ecfex.so" "$fex/build_unixlib/libwow64fex.so" "$OUT/lib/wine/aarch64-unix/"
    cp "$fex/LICENSE" "$OUT/lib/wine/aarch64-windows/FEX-LICENSE"

    # The loader as the main executable of a bundle that carries the profile. The arm64 patch
    # has it look for ntdll.so beside the bundle, in the unix dir.
    profile="${HADRON_PROVISIONING_PROFILE:-}"
    if [ -z "$profile" ]; then
        newest=0
        for candidate in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile \
                         "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
            [ -f "$candidate" ] || continue
            plist=$(security cms -D -i "$candidate" 2>/dev/null) || continue
            appid=$(echo "$plist" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - - 2>/dev/null) || continue
            [ "${appid#*.}" = "$WINE_BUNDLE_ID" ] || continue
            echo "$plist" | plutil -extract Entitlements.com\\.apple\\.developer\\.cross-architecture-support raw -o - - >/dev/null 2>&1 || continue
            expiry=$(date -j -f %Y-%m-%dT%H:%M:%SZ "$(echo "$plist" | plutil -extract ExpirationDate raw -o - -)" +%s)
            [ "$expiry" -gt "$(date +%s)" ] && [ "$expiry" -gt "$newest" ] || continue
            newest=$expiry profile=$candidate
        done
    fi
    [ -n "$profile" ] || die "no provisioning profile for $WINE_BUNDLE_ID with the cross-architecture entitlement, set HADRON_PROVISIONING_PROFILE"
    team=$(security cms -D -i "$profile" | plutil -extract TeamIdentifier.0 raw -o - -)
    # The identity has to be one whose certificate the profile lists.
    identity="${HADRON_SIGN_IDENTITY:-}"
    if [ -z "$identity" ]; then
        identities=$(security find-identity -v -p codesigning)
        plist=$(security cms -D -i "$profile")
        count=$(echo "$plist" | plutil -extract DeveloperCertificates raw -o - -)
        i=0
        while [ "$i" -lt "$count" ] && [ -z "$identity" ]; do
            hash=$(echo "$plist" | plutil -extract "DeveloperCertificates.$i" raw -o - - | base64 -D \
                | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)
            echo "$identities" | grep -q " $hash " && identity=$hash
            i=$((i + 1))
        done
    fi
    [ -n "$identity" ] || die "no signing identity for the certificates in $profile, set HADRON_SIGN_IDENTITY"

    echo "==> signing the loader as $WINE_BUNDLE_ID for team $team"
    unix="$OUT/lib/wine/aarch64-unix"
    app="$unix/Wine.app"
    rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
    sed "s/@BUNDLE_ID@/$WINE_BUNDLE_ID/" "$here/arm64/Info.plist" > "$app/Contents/Info.plist"
    cp "$profile" "$app/Contents/embedded.provisionprofile"
    mv "$unix/wine" "$app/Contents/MacOS/wine"
    ln -s Wine.app/Contents/MacOS/wine "$unix/wine"
    rm -f "$OUT/bin/wine" && ln -s ../lib/wine/aarch64-unix/Wine.app/Contents/MacOS/wine "$OUT/bin/wine"
    entitlements="$WINE_BUILD/wine.entitlements"
    sed -e "s/@TEAM@/$team/g" -e "s/@BUNDLE_ID@/$WINE_BUNDLE_ID/g" "$here/arm64/wine.entitlements" > "$entitlements"
    codesign --force --sign "$identity" --entitlements "$entitlements" "$app"
fi

# The app identifies the runtime by this, see RuntimeSource.swift.
echo "$RUNTIME_ID" > "$OUT/hadron-runtime"

echo "==> done: $OUT"
