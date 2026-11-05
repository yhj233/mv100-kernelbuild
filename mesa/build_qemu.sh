#!/bin/bash
#
# Build Mesa 21.2.6's lima driver NATIVELY inside an armhf ubuntu:20.04 container
# (qemu-user emulated).  This guarantees the result links against glibc 2.31
# (focal), exactly matching the Hi3798MV100 box, so it loads unchanged.
#
# This script runs INSIDE the armhf container (not on the host).  The host-side
# wrapper (.github/workflows/mesa-qemu.yml) does the docker run --platform
# linux/arm/v7 and mounts the repo in, then calls this.
#
# Output: out/libgallium_dri.so (+ sha256.txt + info.txt).  On the device this
# megadriver is dropped in as /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so.
#
set -euo pipefail

MESA_VER=21.2.6
WORK="${WORK:-$PWD}"
OUT="$WORK/out"

echo "=============================================================="
echo " 0. environment (inside armhf container)"
echo "=============================================================="
uname -m
cat /etc/os-release | grep -E 'VERSION|PRETTY'
nproc

echo
echo "=============================================================="
echo " 1. build deps"
echo "=============================================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential ninja-build pkg-config python3 python3-pip \
  python3-mako python3-yaml bison flex git ca-certificates curl \
  libdrm-dev libx11-dev libxext-dev libxfixes-dev libx11-xcb-dev \
  libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev \
  libxcb-present-dev libxcb-sync-dev libxcb-shm0-dev \
  libxcb-xfixes0-dev libxcb-glx0-dev \
  libxshmfence-dev libxrandr-dev libxxf86vm-dev libxdamage-dev \
  libexpat1-dev zlib1g-dev libzstd-dev

# focal's meson (0.53) is too old for mesa 21.2 (needs >=0.54)
pip3 install --quiet --no-cache-dir "meson==0.59.4"
meson --version

echo
echo "=============================================================="
echo " 2. mesa $MESA_VER source"
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
echo " 3. patches"
echo "=============================================================="
for p in "$WORK"/mesa/patches/*.patch; do
  echo "--- $(basename "$p") ---"
  patch -p1 --forward --no-backup-if-mismatch < "$p"
done
grep -n "lima_force_pp_stream" src/gallium/drivers/lima/lima_job.c

echo
echo "=============================================================="
echo " 4. meson setup"
echo "=============================================================="
meson setup build \
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
echo " 5. ninja (megadriver)"
echo "=============================================================="
JOBS=$(nproc)
if ! ninja -C build -j"$JOBS" src/gallium/targets/dri/libgallium_dri.so; then
  echo "!! targeted build failed, full build"
  ninja -C build -j"$JOBS"
fi

echo
echo "=============================================================="
echo " 6. result"
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
