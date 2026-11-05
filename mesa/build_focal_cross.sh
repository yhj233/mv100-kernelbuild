#!/bin/bash
#
# Cross-build Mesa 21.2.6's lima_dri.so for armhf (Hi3798MV100 box, Ubuntu 20.04).
#
# Runs INSIDE an amd64 ubuntu:20.04 (focal) container.  We install focal's own
# arm-linux-gnueabihf cross toolchain (gcc 9.3) + focal armhf dev libs, then
# cross-compile at full amd64 speed (NO qemu emulation).  Because the cross
# toolchain ships focal's glibc 2.31 sysroot, the .so links against <=2.31
# symbols and loads unchanged on the device.
#
# Output: out/libgallium_dri.so (+ sha256.txt + info.txt).  On the device this
# megadriver is dropped in as /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so.
#
set -euo pipefail

MESA_VER=21.2.6
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
echo " 4. meson (focal has 0.53, mesa 21.2 needs >=0.52 -> use pip 0.59.4)"
echo "=============================================================="
pip3 install --quiet --no-cache-dir "meson==0.59.4" || apt-get install -y -qq meson
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
echo " 6. patches"
echo "=============================================================="
for p in "$WORK"/mesa/patches/*.patch; do
  echo "--- $(basename "$p") ---"
  patch -p1 --forward --no-backup-if-mismatch < "$p"
done
grep -n "lima_force_pp_stream" src/gallium/drivers/lima/lima_job.c

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
echo "GLIBC max: $(readelf --version-info "$SO" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1)" > "$OUT/info.txt"
echo "mesa: $MESA_VER" >> "$OUT/info.txt"
chmod -R a+rX "$OUT"
ls -l "$OUT"
echo "===== DONE ====="
