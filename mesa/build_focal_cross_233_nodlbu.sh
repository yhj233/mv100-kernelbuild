#!/bin/bash
#
# Cross-build Mesa 23.3.6's lima_dri.so for armhf (Hi3798MV100 box, Ubuntu 20.04).
#
# EXPERIMENTAL VARIANT of build_focal_cross_233.sh: force-disable the Mali-450
# DLBU (dynamic load balancing) path in lima_job.c, so PPs use the Mali-400
# static tile allocation instead.  Goal: A/B-test whether the periodic PP hang
# on Hi3798MV100 is caused by the DLBU unit (integration bug) vs elsewhere.
#
# If the hang disappears with DLBU off -> root cause is DLBU.  If it persists
# -> DLBU is a red herring and the hang is elsewhere.
#
# Output: out/libgallium_dri.so (+ sha256.txt + info.txt).  On the device this
# megadriver is dropped in as /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so.
#
set -euo pipefail

MESA_VER=23.3.6
WORK="${WORK:-$PWD}"
OUT="$WORK/out"
CROSS=arm-linux-gnueabihf
export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

echo "=============================================================="
echo " 0. environment"
echo "=============================================================="
uname -m
nproc
cat /etc/os-release | head -2

echo
echo "=============================================================="
echo " 1. focal apt sources (EOL -> archive.ubuntu.com + ports)"
echo "=============================================================="
# focal is EOL; its packages moved from archive.ubuntu.com to old-releases, but
# archive.ubuntu.com still serves the focal dists.  We pin amd64 to archive and
# armhf to ports.ubuntu.com (armhf is a ports arch, not on archive.ubuntu.com).
cat > /etc/apt/sources.list <<'EOF'
deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal main universe restricted multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal-updates main universe restricted multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal-security main universe restricted multiverse

deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports focal main universe
deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports focal-updates main universe
deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports focal-security main universe
EOF
dpkg --add-architecture armhf
apt-get update -qq

echo
echo "=============================================================="
echo " 2. native build tools + focal armhf cross toolchain"
echo "=============================================================="
apt-get install -y -qq --no-install-recommends \
  build-essential ninja-build pkg-config python3 python3-pip \
  python3-mako python3-yaml bison flex ca-certificates curl \
  file binutils \
  gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
  crossbuild-essential-armhf

# meson needed EARLY (libdrm cross-build in step 3b uses it before step 4)
pip3 install --quiet --no-cache-dir "meson==0.63.3" || apt-get install -y -qq meson
echo "meson: $(meson --version)"

"$CROSS-gcc" --version | head -1
echo "cross sysroot: $("$CROSS-gcc" -print-sysroot)"
# The cross toolchain ships its own focal glibc 2.31 sysroot under
# /usr/arm-linux-gnueabihf (gcc --print-sysroot reports /, libs live there).
CROSS_LIBC=$("$CROSS-gcc" -print-file-name=libc.so.6)
echo "cross libc: $CROSS_LIBC"
echo "cross glibc max: $(strings "$CROSS_LIBC" 2>/dev/null | grep '^GLIBC_' | sort -V | tail -1)"

echo
echo "=============================================================="
echo " 3. focal armhf dev libs (mesa build deps)"
echo "=============================================================="
apt-get install -y -qq --no-install-recommends \
  libdrm-dev:armhf \
  libx11-dev:armhf libxext-dev:armhf libxfixes-dev:armhf libx11-xcb-dev:armhf \
  libxcb1-dev:armhf libxcb-dri2-0-dev:armhf libxcb-dri3-dev:armhf \
  libxcb-present-dev:armhf libxcb-sync-dev:armhf libxcb-shm0-dev:armhf \
  libxcb-xfixes0-dev:armhf libxcb-glx0-dev:armhf \
  libxshmfence-dev:armhf libxrandr-dev:armhf libxxf86vm-dev:armhf \
  libxdamage-dev:armhf \
  libexpat1-dev:armhf zlib1g-dev:armhf libzstd-dev:armhf

echo "--- armhf pkg-config files present ---"
ls /usr/lib/arm-linux-gnueabihf/pkgconfig/ 2>/dev/null | grep -E 'drm|xcb|x11|expat|zstd|zlib' | head -20

echo
echo "=============================================================="
echo " 3b. cross-build libdrm 2.4.109 (mesa 23.3 needs >=2.4.109)"
echo "=============================================================="
# Mesa 23.3.6 requires libdrm >= 2.4.109, but focal ships 2.4.107 (and the
# device runs 2.4.107).  Critically, mesa's src/loader/loader.c calls
# drmGetDevice2() and drmGetDeviceFromDevId(), which are NEW symbols added in
# 2.4.109 -- they do NOT exist in 2.4.107's headers OR .so, so a version-spoof
# fails at compile time with -Werror=implicit-function-declaration.
#
# So we genuinely cross-build libdrm 2.4.109 as a BUILD-ONLY dependency (for
# its headers + pkg-config metadata), and DO NOT install it on the device.
# The device's 2.4.107 runtime stays put: lima's own code paths (drmIoctl,
# drmCommandWriteRead, drmGetVersion, ...) use symbols unchanged since
# <2.4.107, and the loader's new-symbol calls are guarded / only hit on render
# node probing paths that lima exercises minimally.
LIBDRM_VER=2.4.109
cd "$WORK"
rm -rf libdrm-src
mkdir -p libdrm-src
cd libdrm-src
echo "  fetching libdrm $LIBDRM_VER ..."
# 1) prefer the vendored tarball shipped in this repo (no network needed)
if [ -f "$WORK/mesa/libdrm-$LIBDRM_VER.tar.gz" ]; then
  cp "$WORK/mesa/libdrm-$LIBDRM_VER.tar.gz" /tmp/libdrm.tar
  echo "  using vendored $WORK/mesa/libdrm-$LIBDRM_VER.tar.gz ($(stat -c%s /tmp/libdrm.tar) bytes)"
fi
# 2) fallback to network sources
if [ ! -f /tmp/libdrm.tar ]; then
  for u in \
    "https://gitlab.freedesktop.org/mesa/libdrm/-/archive/libdrm-$LIBDRM_VER/libdrm-libdrm-$LIBDRM_VER.tar.gz" \
    "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" \
  ; do
    echo "  -> $u"
    if curl -fsSL --retry 2 --retry-delay 3 -m 120 -o /tmp/libdrm.tar "$u" 2>/tmp/libdrm.curlerr; then
      sz=$(stat -c%s /tmp/libdrm.tar 2>/dev/null || echo 0)
      echo "     got $sz bytes"
      if [ "$sz" -gt 100000 ]; then
        break
      fi
      rm -f /tmp/libdrm.tar
    else
      echo "     curl FAILED: $(cat /tmp/libdrm.curlerr 2>/dev/null | head -3)"
      rm -f /tmp/libdrm.tar
    fi
  done
fi
if [ ! -f /tmp/libdrm.tar ]; then
  echo "!! cannot fetch libdrm source"; exit 1
fi
# detect archive type by magic bytes (use od to avoid grep binary issues)
MAGIC=$(head -c 2 /tmp/libdrm.tar | od -An -tx1 | tr -d ' \n')
echo "  libdrm archive magic: $MAGIC"
case "$MAGIC" in
  1f8b*)  echo "  -> gzip, extracting (strip top dir)"; tar xzf /tmp/libdrm.tar --strip-components=1 || { echo "!! tar gz failed"; exit 1; } ;;
  fd377a*) echo "  -> xz, extracting (strip top dir)"; tar xJf /tmp/libdrm.tar --strip-components=1 || { echo "!! tar xz failed"; exit 1; } ;;
  *) echo "!! unknown archive type ($MAGIC)"; exit 1 ;;
esac
echo "libdrm source root: $(pwd)"
test -f meson.build && echo "meson.build present" || { echo "!! libdrm tree broken"; ls -la | head -20; exit 1; }

# Install libdrm INTO the focal multiarch tree (--prefix=/usr --libdir=lib/arm-linux-gnueabihf
# with DESTDIR=/), so it lands exactly where the cross gcc and pkg-config already look:
#   headers -> /usr/include/libdrm/  (new drmGetDeviceFromDevId decl)
#   lib     -> /usr/lib/arm-linux-gnueabihf/libdrm.so.2.4.0
#   .pc     -> /usr/lib/arm-linux-gnueabihf/pkgconfig/libdrm.pc  (Version 2.4.109)
# This OVERWRITES focal's 2.4.107 dev headers/lib inside the build container only;
# the device keeps 2.4.107 until we separately ship libdrm.so.2.4.0 in out/.
# NOTE: gcc-arm-linux-gnueabihf reports -print-sysroot = "/", its real sysroot is the
# multiarch tree /usr/lib/arm-linux-gnueabihf + /usr/include, so we install straight
# into / with the multiarch libdir.

cat > /tmp/libdrm-cross.txt <<EOF
[binaries]
c = '${CROSS}-gcc'
ar = '${CROSS}-ar'
strip = '${CROSS}-strip'
pkgconfig = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7l'
endian = 'little'
EOF
meson setup _build --cross-file /tmp/libdrm-cross.txt \
  --buildtype=release --prefix=/usr --libdir=lib/arm-linux-gnueabihf \
  -Dudev=false -Dintel=false -Dradeon=false -Damdgpu=false -Dnouveau=false \
  -Dvmwgfx=false -Domap=false -Dexynos=false -Dfreedreno=false -Dtegra=false \
  -Dvc4=false -Detnaviv=false -Dman-pages=false \
  -Dvalgrind=false -Dcairo-tests=false -Dinstall-test-programs=false
ninja -C _build -j"$(nproc)"
DESTDIR=/ ninja -C _build install
# verify the headers + libdrm.pc landed
echo "--- /usr/include/libdrm/xf86drm.h (should have drmGetDeviceFromDevId) ---"
grep -c 'drmGetDeviceFromDevId' /usr/include/libdrm/xf86drm.h 2>/dev/null || echo "!! header missing"
echo "--- /usr/lib/arm-linux-gnueabihf/pkgconfig/libdrm.pc ---"
grep '^Version:' /usr/lib/arm-linux-gnueabihf/pkgconfig/libdrm.pc 2>/dev/null || echo "!! libdrm.pc missing"
echo "--- libdrm.so ---"
ls -l /usr/lib/arm-linux-gnueabihf/libdrm.so* 2>/dev/null | head

echo
echo "=============================================================="
echo " 4. meson (focal has 0.53; mesa 23.3 needs >=0.60 -> pip 0.63)"
echo "=============================================================="
pip3 install --quiet --no-cache-dir "meson==0.63.3" || apt-get install -y -qq meson
meson --version

echo
echo "=============================================================="
echo " 5. mesa $MESA_VER source"
echo "=============================================================="
SRC="$WORK/src"
mkdir -p "$SRC"
cd "$SRC"
fetch() {
  local u sz
  for u in "$@"; do
    echo "  -> $u"
    rm -f /tmp/mesa.tar
    if curl -fsSL --retry 3 --retry-delay 5 -m 420 -o /tmp/mesa.tar "$u"; then
      sz=$(stat -c%s /tmp/mesa.tar)
      echo "     $sz bytes"
      [ "$sz" -gt 8000000 ] && return 0
      echo "     too small, next"
    fi
  done
  return 1
}
fetch \
  "https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-$MESA_VER/mesa-mesa-$MESA_VER.tar.gz" \
  "https://github.com/mesa3d/mesa/archive/refs/tags/mesa-$MESA_VER.tar.gz" \
  || { echo "!! cannot fetch mesa source"; exit 1; }
tar xf /tmp/mesa.tar
cd "$(ls -d mesa-* | head -1)"
echo "source root: $(pwd)"

echo
echo "=============================================================="
echo " 6. patch: force-disable DLBU (static PP tile allocation)"
echo "=============================================================="
# Replace lima_update_pp_stream()'s body so it ALWAYS builds the static PP
# stream (lima_update_damage_pp_stream) and never leaves pp_stream.map NULL.
# With map set, lima_job.c's submit path takes the `if (ps->map)` branch and
# leaves use_dlbu == 0, so the kernel runs the PPs in Mali-400 static-tile mode.
python3 - <<'PY'
import re
p = "src/gallium/drivers/lima/lima_job.c"
s = open(p).read()

# Locate the lima_update_pp_stream definition and force the static path.
old = re.search(
    r"static void\nlima_update_pp_stream\(struct lima_job \*job\)\n\{\n"
    r".*?\n\}\n",
    s, re.S)
if not old:
    raise SystemExit("!! lima_update_pp_stream not found (mesa source changed?)")

new = (
    "static void\n"
    "lima_update_pp_stream(struct lima_job *job)\n"
    "{\n"
    "   /* [EXPERIMENT] Force static PP stream (no DLBU) to A/B-test the\n"
    "    * Mali-450 DLBU hang on Hi3798MV100. */\n"
    "   lima_update_damage_pp_stream(job);\n"
    "}\n"
)
s = s[:old.start()] + new + s[old.end():]
open(p, "w").write(s)
print("patched lima_update_pp_stream -> static PP stream (DLBU disabled)")
PY

# sanity: show the patched function
sed -n '/lima_update_pp_stream/,/^}/p' src/gallium/drivers/lima/lima_job.c

echo
echo "=============================================================="
echo " 7. meson cross file + setup"
echo "=============================================================="
cat > /tmp/cross.txt <<EOF
[binaries]
c = '${CROSS}-gcc'
cpp = '${CROSS}-g++'
ar = '${CROSS}-ar'
strip = '${CROSS}-strip'
pkgconfig = 'pkg-config'

[properties]
pkg_config_libdir = ['/usr/lib/arm-linux-gnueabihf/pkgconfig', '/usr/share/pkgconfig']
sys_root = '$("$CROSS-gcc" -print-sysroot)'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7l'
endian = 'little'
EOF
cat /tmp/cross.txt
export PKG_CONFIG_LIBDIR="/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig"

meson setup build \
  --cross-file /tmp/cross.txt \
  --buildtype=release \
  --prefix=/usr \
  --libdir=lib/arm-linux-gnueabihf \
  -Dplatforms=x11 \
  -Dglx=dri \
  -Degl=disabled \
  -Dgbm=disabled \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dgallium-drivers=lima \
  -Dvulkan-drivers= \
  -Dllvm=disabled \
  -Dvalgrind=disabled \
  -Dlibunwind=disabled \
  -Dlmsensors=disabled \
  -Dgallium-va=disabled \
  -Dgallium-vdpau=disabled \
  -Dgallium-xa=disabled \
  -Dgallium-nine=false \
  -Dgallium-opencl=disabled \
  -Dosmesa=false \
  -Dtools= \
  -Dbuild-tests=false

echo
echo "=============================================================="
echo " 8. ninja (megadriver)"
echo "=============================================================="
JOBS=$(nproc)
if ! ninja -C build -j"$JOBS" src/gallium/targets/dri/libgallium_dri.so; then
  echo "!! targeted build failed, full build"
  ninja -C build -j"$JOBS"
fi

echo
echo "=============================================================="
echo " 9. result"
echo "=============================================================="
SO=$(find build -name 'libgallium_dri.so' -type f | head -1)
[ -n "$SO" ] || { echo "!! not found"; find build -name '*.so' | head; exit 1; }
echo "built: $SO"
ls -l "$SO"
file "$SO"
echo "--- NEEDED ---"
readelf -d "$SO" | grep NEEDED
echo "--- max GLIBC (must be <= 2.31) ---"
readelf --version-info "$SO" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -3
echo "--- lima driver symbol ---"
nm -D "$SO" | grep '__driDriverGetExtensions_lima' || echo "!! lima symbol missing"

mkdir -p "$OUT"
cp "$SO" "$OUT/libgallium_dri.so"
sha256sum "$OUT/libgallium_dri.so" | tee "$OUT/sha256.txt"

# Also export the cross-built libdrm.so.2.4.0 (soname libdrm.so.2) so the device
# can be upgraded from 2.4.107 -> 2.4.109 (adds drmGetDeviceFromDevId, needed by
# mesa 23.3's loader.c).  Backward compatible: soname unchanged, only new symbols.
LIBDRM_SO=$(find /usr/lib/arm-linux-gnueabihf -name 'libdrm.so.2.4.0' 2>/dev/null | head -1)
if [ -n "$LIBDRM_SO" ]; then
  cp "$LIBDRM_SO" "$OUT/libdrm.so.2.4.0"
  echo "libdrm.so.2.4.0 exported:"
  ls -l "$OUT/libdrm.so.2.4.0"
  echo "--- libdrm NEW symbols ---"
  nm -D "$OUT/libdrm.so.2.4.0" | grep -E 'drmGetDeviceFromDevId|drmGetDevice2' || echo "(none)"
else
  echo "!! libdrm.so.2.4.0 not found, skipping export"
fi

echo "GLIBC max: $(readelf --version-info "$SO" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1)" > "$OUT/info.txt"
echo "mesa: $MESA_VER" >> "$OUT/info.txt"
echo "libdrm: 2.4.109 (exported libdrm.so.2.4.0)" >> "$OUT/info.txt"
chmod -R a+rX "$OUT"
ls -l "$OUT"
echo "===== DONE ====="
