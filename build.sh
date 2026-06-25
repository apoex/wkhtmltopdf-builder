#!/bin/sh
#
# Build wkhtmltopdf + wkhtmltoimage as fully static x86-64 (musl) executables.
# =========================================================================
#
# Run inside an Alpine 3.10 container (GCC 8.3); no other version works — see
# readme.md for why that toolchain is pinned (GCC >= 9 miscompiles the patched
# Qt 4.8.7 that wkhtmltopdf 0.12.5 depends on). The GitHub Actions workflow at
# .github/workflows/build.yml invokes this script via `docker run alpine:3.10`.
#
# Downloads everything it needs, including the wkhtmltopdf source itself: it clones
# wkhtmltopdf at $WKHTMLTOPDF_VERSION (default 0.12.5) and initialises the `qt`
# submodule. (Point $SRC_DIR at an existing checkout to use that instead.) The C
# library (musl), libstdc++, Qt, fontconfig, freetype, expat, openssl, zlib, libpng,
# libjpeg and the X11 client stack are all linked statically. zlib/libpng/libjpeg
# versions are matched to packaging/conanfile.txt (the official static-build set).
# The result has zero shared-library deps and resolves DNS (musl), so remote URLs work.
#
# Output: $OUT_DIR/wkhtmltopdf and $OUT_DIR/wkhtmltoimage (default ./out).
#
set -eu

# --- versions (override via env) ---------------------------------------------
: "${WKHTMLTOPDF_VERSION:=0.12.5}"   # git tag/branch to clone
: "${WKHTMLTOPDF_REPO:=https://github.com/wkhtmltopdf/wkhtmltopdf}"
: "${OPENSSL_VERSION:=1.1.1w}"   # official 0.12.5 pins 1.1.1g; 1.1.1w = same line, newer CVE fixes
: "${ZLIB_VERSION:=1.2.11}"      # matches packaging/conanfile.txt
: "${LIBPNG_VERSION:=1.6.37}"    # matches packaging/conanfile.txt
: "${LIBJPEG_VERSION:=9d}"       # IJG libjpeg, matches packaging/conanfile.txt (libjpeg/9d)
: "${EXPAT_VERSION:=2.6.4}"
: "${FREETYPE_VERSION:=2.10.4}"
: "${FONTCONFIG_VERSION:=2.12.6}"   # 2.13+ needs libuuid (absent on Alpine 3.10)
: "${XCB_PROTO_VERSION:=1.16.0}"
: "${LIBXAU_VERSION:=1.0.11}"
: "${LIBXDMCP_VERSION:=1.1.5}"
: "${LIBXCB_VERSION:=1.16}"
: "${LIBX11_VERSION:=1.8.7}"
: "${LIBXEXT_VERSION:=1.3.6}"
: "${LIBXRENDER_VERSION:=0.9.11}"

# --- paths (override via env) ------------------------------------------------
: "${SRC_DIR:=/tmp/wkhtmltopdf}"
: "${OUT_DIR:=$(pwd)/out}"
: "${QT_PREFIX:=/opt/qt}"

JOBS="$(nproc)"
XORG_LIB="https://xorg.freedesktop.org/archive/individual/lib"
XORG_PROTO="https://xorg.freedesktop.org/archive/individual/proto"
XCFG="--prefix=/usr --enable-static --disable-shared --disable-malloc0returnsnull --disable-docs --disable-specs"

export CFLAGS="-w"
export CXXFLAGS="-w"
export PKG_CONFIG_PATH="/usr/lib/pkgconfig"

# -----------------------------------------------------------------------------
# Toolchain + build-time helpers. No -dev runtime libs: the static dependencies
# are built from source below and install their own headers into /usr.
# -----------------------------------------------------------------------------
apk add --no-cache \
    build-base linux-headers perl python3 bash git wget xz pkgconf file gperf \
    util-macros xorgproto xtrans

# libxcb's configure requires a `pthread-stubs` pkg-config module, which Alpine
# doesn't ship; musl has pthreads in libc, so an empty stub .pc satisfies it.
printf '%s\n' 'Name: pthread-stubs' \
    'Description: pthread stubs (musl provides pthreads in libc)' \
    'Version: 0.4' 'Libs:' 'Cflags:' > /usr/lib/pkgconfig/pthread-stubs.pc

git config --global --add safe.directory '*'

# -----------------------------------------------------------------------------
# Static dependencies built from source (Alpine 3.10 ships almost no *-static).
# -----------------------------------------------------------------------------
echo "=== building openssl ${OPENSSL_VERSION} ==="
cd /tmp
wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
tar xf "openssl-${OPENSSL_VERSION}.tar.gz"
( cd "openssl-${OPENSSL_VERSION}" \
    && ./config no-shared no-tests no-async --prefix=/usr --openssldir=/etc/ssl \
    && make -j"$JOBS" && make install_sw )
rm -rf /tmp/openssl-*

# zlib / libpng / libjpeg: versions matched to packaging/conanfile.txt so the linked
# set is the same as the official wkhtmltopdf static builds. Qt links these via
# -system-* (see configure below); zlib is also used by freetype and libpng.
echo "=== building zlib ${ZLIB_VERSION} ==="
cd /tmp
# Fetched from the madler/zlib git tag archive rather than zlib.net, which
# frequently refuses automated/cloud downloads (HTTP errors in CI). The tag
# archive unpacks to zlib-${ZLIB_VERSION}/, matching the layout below.
wget -q -O "zlib-${ZLIB_VERSION}.tar.gz" \
    "https://github.com/madler/zlib/archive/refs/tags/v${ZLIB_VERSION}.tar.gz"
tar xf "zlib-${ZLIB_VERSION}.tar.gz"
( cd "zlib-${ZLIB_VERSION}" && ./configure --static --prefix=/usr && make -j"$JOBS" && make install )
rm -rf /tmp/zlib-*

echo "=== building libpng ${LIBPNG_VERSION} ==="
cd /tmp
wget -q "https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"
tar xf "libpng-${LIBPNG_VERSION}.tar.xz"
( cd "libpng-${LIBPNG_VERSION}" \
    && ./configure --prefix=/usr --enable-static --disable-shared \
    && make -j"$JOBS" && make install )
rm -rf /tmp/libpng-*

echo "=== building libjpeg ${LIBJPEG_VERSION} ==="
cd /tmp
wget -q "https://www.ijg.org/files/jpegsrc.v${LIBJPEG_VERSION}.tar.gz"
tar xf "jpegsrc.v${LIBJPEG_VERSION}.tar.gz"
( cd "jpeg-${LIBJPEG_VERSION}" \
    && ./configure --prefix=/usr --enable-static --disable-shared \
    && make -j"$JOBS" && make install )
rm -rf "/tmp/jpeg-${LIBJPEG_VERSION}" "/tmp/jpegsrc.v${LIBJPEG_VERSION}.tar.gz"

echo "=== building expat ${EXPAT_VERSION} ==="
cd /tmp
EXPAT_TAG="R_$(echo "${EXPAT_VERSION}" | tr . _)"
wget -q "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VERSION}.tar.xz"
tar xf "expat-${EXPAT_VERSION}.tar.xz"
( cd "expat-${EXPAT_VERSION}" \
    && ./configure --prefix=/usr --enable-static --disable-shared \
        --without-docbook --without-examples --without-tests \
    && make -j"$JOBS" && make install )
rm -rf /tmp/expat-*

# freetype: use the system zlib built above (NOT freetype's bundled copy, which would
# export clashing inflate/deflate symbols against libz.a in the final static link);
# everything else off.
echo "=== building freetype ${FREETYPE_VERSION} ==="
cd /tmp
wget -q "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
tar xf "freetype-${FREETYPE_VERSION}.tar.xz"
( cd "freetype-${FREETYPE_VERSION}" \
    && ./configure --prefix=/usr --enable-static --disable-shared \
        --with-zlib=yes --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no \
    && make -j"$JOBS" && make install )
rm -rf /tmp/freetype-*

# fontconfig: needs expat + freetype; skip the install-time font-cache run.
echo "=== building fontconfig ${FONTCONFIG_VERSION} ==="
cd /tmp
wget -q "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.gz"
tar xf "fontconfig-${FONTCONFIG_VERSION}.tar.gz"
( cd "fontconfig-${FONTCONFIG_VERSION}" \
    && ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
        --enable-static --disable-shared --disable-docs \
    && make -j"$JOBS" && make install RUN_FC_CACHE_TEST=false )
rm -rf /tmp/fontconfig-*

# X11 client stack. Order: xcb-proto -> Xau/Xdmcp -> xcb -> X11 -> Xext/Xrender.
# xcb-proto is built from source so libxcb's version requirement is met regardless
# of the Alpine release. Installed into /usr (Qt's default search path).
echo "=== building xcb-proto ${XCB_PROTO_VERSION} ==="
cd /tmp
wget -q "${XORG_PROTO}/xcb-proto-${XCB_PROTO_VERSION}.tar.xz"
tar xf "xcb-proto-${XCB_PROTO_VERSION}.tar.xz"
( cd "xcb-proto-${XCB_PROTO_VERSION}" && ./configure --prefix=/usr && make install )
rm -rf /tmp/xcb-proto-*

for pkg in \
    "libXau-${LIBXAU_VERSION}" \
    "libXdmcp-${LIBXDMCP_VERSION}" \
    "libxcb-${LIBXCB_VERSION}" \
    "libX11-${LIBX11_VERSION}" \
    "libXext-${LIBXEXT_VERSION}" \
    "libXrender-${LIBXRENDER_VERSION}"
do
    echo "=== building ${pkg} ==="
    cd /tmp
    wget -q "${XORG_LIB}/${pkg}.tar.xz"
    tar xf "${pkg}.tar.xz"
    # shellcheck disable=SC2086
    ( cd "${pkg}" && ./configure ${XCFG} && make -j"$JOBS" && make install )
    rm -rf "/tmp/${pkg}"
done

# -----------------------------------------------------------------------------
# wkhtmltopdf source: clone at the requested version (unless $SRC_DIR already holds
# a checkout) and init the patched-Qt submodule (pinned by the checkout; fetched
# from GitHub via the repo origin's relative submodule URL).
# -----------------------------------------------------------------------------
echo "=== fetching wkhtmltopdf ${WKHTMLTOPDF_VERSION} ==="
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone --depth 1 --branch "$WKHTMLTOPDF_VERSION" "$WKHTMLTOPDF_REPO" "$SRC_DIR"
fi
cd "$SRC_DIR"
git submodule update --init --recursive qt   # full fetch: pinned qt commit need not be a branch tip
test -x qt/configure
echo "=== building wkhtmltopdf $(cat VERSION) ==="

# -----------------------------------------------------------------------------
# Qt source patches for musl (idempotent; applied to the working tree).
# -----------------------------------------------------------------------------
# musl: QT_SOCKLEN_T is gated on __GLIBC__ (else `int`); musl lacks __GLIBC__, so
# socket calls pass int* where musl declares socklen_t*. Force socklen_t.
sed -i 's/#define[[:space:]]\{1,\}QT_SOCKLEN_T[[:space:]]\{1,\}int/#define QT_SOCKLEN_T socklen_t/' \
    qt/mkspecs/linux-g++/qplatformdefs.h

# musl: QIconvCodec assumed glibc iconv UTF-16 semantics for the generic Linux
# case; add the non-glibc branch (upstream qt-musl-iconv-no-bom.patch).
if ! grep -q 'Q_OS_LINUX) && !defined(__GLIBC__)' qt/src/corelib/codecs/qiconvcodec.cpp; then
    sed -i 's@defined(Q_OS_FREEBSD) || defined(Q_OS_MAC)@defined(Q_OS_FREEBSD) || defined(Q_OS_MAC) || (defined(Q_OS_LINUX) \&\& !defined(__GLIBC__))@' \
        qt/src/corelib/codecs/qiconvcodec.cpp
fi

# musl: QSettings global mutex must be recursive (upstream qt-recursive-global-mutex.patch).
sed -i 's@Q_GLOBAL_STATIC(QMutex, globalMutex)@Q_GLOBAL_STATIC_WITH_ARGS(QMutex, globalMutex, (QMutex::Recursive))@' \
    qt/src/corelib/io/qsettings.cpp

# Static X11 link: a static libX11.a doesn't pull its own deps (a .so records them
# via DT_NEEDED), so name them. Append to QMAKE_LIBS_X11 in the mkspec.
if ! grep -q 'QMAKE_LIBS_X11.*-lxcb' qt/mkspecs/common/linux.conf; then
    sed -i 's|\(QMAKE_LIBS_X11[[:space:]]*=.*\)|\1 -lxcb -lXau -lXdmcp|' \
        qt/mkspecs/common/linux.conf
fi

# -----------------------------------------------------------------------------
# Configure + build the patched Qt, statically. Flags are qt-config.common +
# qt-config.docker from packaging/build.yml, verbatim — including -system-zlib/
# -system-libpng/-system-libjpeg, which link the from-source static libs built
# above (versions matched to packaging/conanfile.txt).
# -----------------------------------------------------------------------------
mkdir -p "$QT_PREFIX"
cd "$QT_PREFIX"
"$SRC_DIR/qt/configure" \
    -opensource -confirm-license -fast -release -static \
    -graphicssystem raster -webkit -exceptions -xmlpatterns \
    -system-zlib -system-libpng -system-libjpeg \
    -no-libmng -no-libtiff -no-accessibility -no-stl -no-qt3support \
    -no-phonon -no-phonon-backend -no-opengl -no-declarative \
    -no-script -no-scripttools \
    -no-sql-db2 -no-sql-ibase -no-sql-mysql -no-sql-oci -no-sql-odbc \
    -no-sql-psql -no-sql-sqlite -no-sql-sqlite2 -no-sql-tds \
    -no-mmx -no-3dnow -no-sse -no-sse2 -no-multimedia \
    -nomake demos -nomake docs -nomake examples -nomake tools \
    -nomake tests -nomake translations \
    -silent -xrender -largefile -iconv -openssl-linked \
    -no-javascript-jit -no-rpath -no-dbus -no-nis -no-cups -no-pch \
    -no-gtkstyle -no-nas-sound -no-sm -no-xshape -no-xinerama \
    -no-xcursor -no-xfixes -no-xrandr -no-mitshm -no-xinput -no-xkb \
    -no-glib -no-gstreamer -no-icu -no-openvg -no-xsync -no-audio-backend \
    -no-sse3 -no-ssse3 -no-sse4.1 -no-sse4.2 -no-avx -no-neon \
    --prefix="$QT_PREFIX"
make -C "$QT_PREFIX" -j"$JOBS"

# -----------------------------------------------------------------------------
# Build wkhtmltopdf / wkhtmltoimage as fully static executables.
#
# Build src/pdf/pdf.pro and src/image/image.pro DIRECTLY (not the top
# wkhtmltopdf.pro): in static mode they include lib.pri and embed libwkhtmltox,
# whereas the top .pro also builds src/lib/lib.pro which hardcodes `CONFIG += dll`
# (a shared .so that cannot be linked with -static).
#
#   CONFIG+=static            -> executable embeds libwkhtmltox.
#   QMAKE_LFLAGS+=-static -no-pie ... -> classic static ELF (Alpine GCC defaults to
#                              PIE; -static alone yields a static-PIE with an interp).
#   Makefile LIBS += -lexpat -lz -> static libfontconfig.a (fcxml.o) needs expat and
#                              libpng16.a/libfreetype.a need zlib, but qmake emits
#                              user LIBS before Qt's late -lfontconfig/-lpng/-lz;
#                              appending to the generated Makefile puts them last,
#                              where ld can resolve the back-references.
# DESTDIR=../../bin from a 2-level-deep build dir (/build/{pdf,image}) -> /bin.
# -----------------------------------------------------------------------------
build_app() {
    pro="$1"; dir="$2"
    mkdir -p "$dir"
    cd "$dir"
    "$QT_PREFIX/bin/qmake" "$SRC_DIR/$pro" \
        CONFIG+=silent CONFIG+=static \
        "QMAKE_LFLAGS+=-static -no-pie -static-libgcc -static-libstdc++"
    sed -i 's|^\(LIBS[[:space:]]*=.*\)|\1 -lexpat -lz|' Makefile
    make -j"$JOBS"
}
build_app src/pdf/pdf.pro     /build/pdf
build_app src/image/image.pro /build/image

# -----------------------------------------------------------------------------
# Collect, strip and verify (no NEEDED entries, classic static ELF).
# -----------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
cp /bin/wkhtmltopdf /bin/wkhtmltoimage "$OUT_DIR/"
strip "$OUT_DIR/wkhtmltopdf" "$OUT_DIR/wkhtmltoimage"
for b in "$OUT_DIR/wkhtmltopdf" "$OUT_DIR/wkhtmltoimage"; do
    echo "=== $b ==="
    file "$b"
    if readelf -d "$b" 2>/dev/null | grep -q 'NEEDED'; then
        echo "ERROR: $b has dynamic NEEDED entries — not fully static"
        readelf -d "$b"; exit 1
    fi
    ( ldd "$b" 2>&1 || true ) | grep -qiE 'not a (valid )?dynamic|statically linked' \
        || { echo "ERROR: $b appears dynamically linked"; ldd "$b"; exit 1; }
    "$b" --version
done
echo "=== done: static binaries in $OUT_DIR ==="
