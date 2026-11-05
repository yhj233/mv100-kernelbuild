#!/bin/bash
#
# Cross-build Mesa 23.3.6's lima_dri.so for armhf (Hi3798MV100 box, Ubuntu 20.04).
#
# Same approach as build_focal_cross.sh but bumped to Mesa 23.3.6 (last 23.3
# release).  Goal: A/B test against 21.2.6 to rule out a userspace command
# stream bug in the PP hang.  23.3.6 needs meson>=0.60 (21.2 only needed 0.52)
# and gcc>=4.8 (gcc 9.3 is fine).
#
# This build is intentionally *pure upstream* (no PP-stream patch): we want to
# see whether stock 23.3 still wedges the PP, not re-apply our 21.2 workaround.
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
echo " 3b. cross-build libdrm 2.4.109 (mesa 23.3 needs >=2.4.109, focal has 2.4.107)"
echo "=============================================================="
# Mesa 23.3.6 requires libdrm >= 2.4.109 but focal ships 2.4.107 (and the
# device runs 2.4.107).  The 2.4.109 bump only adds amdgpu-only symbols
# (drmGetDeviceFromDevId etc.), so a cross-built 2.4.109 .so is ABI-compatible
# with the device's 2.4.107 runtime -- we build it ONLY as a build dep for the
# headers + pkg-config metadata, and do NOT install it on the device.
LIBDRM_VER=2.4.109
DRM_DIR="$WORK/libdrm-$LIBDRM_VER"
mkdir -p "$DRM_DIR"
cd "$DRM_DIR"
if [ ! -f libdrm.pc ]; then
  curl -fsSL --retry 3 -m 120 \
    "https://gitlab.freedesktop.org/mesa/drm/-/archive/libdrm-$LIBDRM_VER/drm-libdrm-$LIBDRM_VER.tar.gz" \
    -o /tmp/libdrm.tar.gz || \
  curl -fsSL --retry 3 -m 120 \
    "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" \
    -o /tmp/libdrm.tar.xz
  [ -f /tmp/libdrm.tar.gz ] && tar xzf /tmp/libdrm.tar.gz
  [ -f /tmp/libdrm.tar.xz ] && tar xJf /tmp/libdrm.tar.xz
  # move source up one level
  d=$(ls -d drm-* libdrm-* 2>/dev/null | head -1)
  [ -n "$d" ] && mv "$d"/* . 2>/dev/null && rmdir "$d" 2>/dev/null
fi
# libdrm has no arch-specific deps for lima; build static-ish, install to
# /usr/local/arm-linux-gnueabihf and point pkg-config at it.
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
  --buildtype=release --prefix=/usr/local/arm-linux-gnueabihf \
  -Dudev=false -Dintel=false -Dradeon=false -Damdgpu=false -Dnouveau=false \
  -Dvmwgfx=false -Domap=false -Dexynos=false -Dfreedreno=false -Dtegra=false \
  -Dvc4=false -Detnaviv=false -Dman-pages=false \
  -Dvalgrind=false -Dcairo-tests=false -Dinstall-test-programs=false
ninja -C _build -j"$(nproc)"
DESTDIR=/tmp/libdrm-stage ninja -C _build install
# make its .pc visible to mesa's pkg-config lookup
export PKG_CONFIG_PATH="/tmp/libdrm-stage/usr/local/arm-linux-gnueabihf/lib/pkgconfig:$PKG_CONFIG_PATH"
export PKG_CONFIG_SYSROOT_DIR="/tmp/libdrm-stage"
ls /tmp/libdrm-stage/usr/local/arm-linux-gnueabihf/lib/pkgconfig/
grep -E '^Version:' /tmp/libdrm-stage/usr/local/arm-linux-gnueabihf/lib/pkgconfig/libdrm.pc

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
echo " 6. patches (NONE for 23.3 -- pure upstream A/B test)"
echo "=============================================================="
# Deliberately apply no patches: this build is to see whether stock Mesa 23.3
# still wedges the PP.  (The 21.2 PP-stream patch won't apply to 23.3 anyway,
# lima_job.c was restructured by the NIR work.)
echo "(no patches for the 23.3 A/B build)"

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
pkg_config_libdir = ['/usr/lib/arm-linux-gnueabihf/pkgconfig', '/usr/share/pkgconfig', '/tmp/libdrm-stage/usr/local/arm-linux-gnueabihf/lib/pkgconfig']
sys_root = '$("$CROSS-gcc" -print-sysroot)'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7l'
endian = 'little'
EOF
cat /tmp/cross.txt
export PKG_CONFIG_LIBDIR="/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig:/tmp/libdrm-stage/usr/local/arm-linux-gnueabihf/lib/pkgconfig"
# keep the sysroot override so meson resolves the cross-built libdrm headers+lib
export PKG_CONFIG_SYSROOT_DIR="/tmp/libdrm-stage"

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
echo "GLIBC max: $(readelf --version-info "$SO" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1)" > "$OUT/info.txt"
echo "mesa: $MESA_VER" >> "$OUT/info.txt"
chmod -R a+rX "$OUT"
ls -l "$OUT"
echo "===== DONE ====="
