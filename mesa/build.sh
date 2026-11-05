#!/bin/bash
#
# Build Mesa 21.2.6's lima_dri.so inside an Ubuntu 20.04 armhf container
# (runs under qemu-user on an amd64 runner).
#
# Why a container and not a cross toolchain: the target box runs focal armhf
# with mesa 21.2.6-0ubuntu0.1~20.04.2.  Building inside the same release
# guarantees the GLIBC/GLIBCXX symbol versions and the libdrm/libglapi ABI
# match exactly, which is the whole point -- the .so is dropped straight onto
# the device in place of the distro one.
#
# Only one target is built: src/gallium/targets/dri/lima_dri.so.
#
set -euo pipefail

MESA_VER=21.2.6
SRC=/src
OUT=/work/out
JOBS=$(nproc)

echo "=============================================================="
echo " 0. environment"
echo "=============================================================="
uname -a
grep -E '^(NAME|VERSION)=' /etc/os-release || true
echo "nproc=$JOBS"
df -h / /work 2>/dev/null | tail -3

echo
echo "=============================================================="
echo " 1. apt sources (ports.ubuntu.com -- focal is armhf-only there)"
echo "=============================================================="
cat > /etc/apt/sources.list <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports focal main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports focal-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports focal-security main restricted universe multiverse
EOF
apt-get update -qq || { echo "apt update failed"; exit 1; }

echo
echo "=============================================================="
echo " 2. build dependencies"
echo "=============================================================="
apt-get install -y -qq --no-install-recommends \
  build-essential ninja-build pkg-config python3 python3-pip \
  python3-mako python3-yaml bison flex \
  libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev \
  libx11-dev libxext-dev libxfixes-dev libx11-xcb-dev \
  libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev libxcb-present-dev \
  libxcb-sync-dev libxcb-shm0-dev libxcb-xfixes0-dev \
  libxcb-glx0-dev \
  libxshmfence-dev libxrandr-dev libxxf86vm-dev libxdamage-dev \
  ca-certificates curl xz-utils file
echo "--- installed ---"
dpkg-query -W -f='${Package} ${Version}\n' \
  libdrm-dev libx11-dev build-essential ninja-build bison flex 2>/dev/null

echo
echo "=============================================================="
echo " 3. meson (focal ships 0.53, mesa 21.2 wants newer)"
echo "=============================================================="
echo "distro meson: $(meson --version || echo none)"
if ! pip3 install --quiet --no-cache-dir "meson==0.59.4"; then
  echo "!! pip install failed, keeping distro meson"
fi
command -v meson
meson --version

echo
echo "=============================================================="
echo " 4. mesa $MESA_VER source"
echo "=============================================================="
mkdir -p $SRC
cd $SRC

fetch() {
  local u sz
  for u in "$@"; do
    echo "  -> $u"
    rm -f /tmp/mesa.tar
    if curl -fsSL --retry 3 --retry-delay 5 -m 420 -o /tmp/mesa.tar "$u"; then
      sz=$(stat -c%s /tmp/mesa.tar)
      echo "     $sz bytes"
      if [ "$sz" -gt 8000000 ]; then
        return 0
      fi
      echo "     too small, next"
    else
      echo "     curl failed"
    fi
  done
  return 1
}

fetch \
  "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" \
  "https://mesa.freedesktop.org/archive/mesa-$MESA_VER.tar.xz" \
  "https://github.com/mesa3d/mesa/archive/refs/tags/mesa-$MESA_VER.tar.gz" \
  "https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-$MESA_VER/mesa-mesa-$MESA_VER.tar.gz" \
  || { echo "!! cannot fetch mesa source"; exit 1; }

file /tmp/mesa.tar
tar xf /tmp/mesa.tar
cd "$(ls -d mesa-* | head -1)"
echo "source root: $(pwd)"
head -8 meson.build

echo
echo "=============================================================="
echo " 5. patches"
echo "=============================================================="
for p in /work/mesa/patches/*.patch; do
  echo "--- $(basename "$p") ---"
  patch -p1 --forward --no-backup-if-mismatch < "$p"
done
echo "--- verify ---"
grep -n "lima_force_pp_stream" src/gallium/drivers/lima/lima_job.c

echo
echo "=============================================================="
echo " 6. meson setup"
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
echo "--- summary ---"
grep -E "Gallium drivers|GLX|shared-glapi|Platforms|LLVM" build/meson-logs/meson-log.txt | tail -12 || true

echo
echo "=============================================================="
echo " 7. ninja (lima_dri.so = the megadriver libgallium_dri.so)"
echo "=============================================================="
# Mesa 21.2 builds lima as part of the "megadriver": every DRI driver is
# compiled into one libgallium_dri.so, and `install_megadrivers.py` turns it
# into per-driver .so files (lima_dri.so, etc.) at install time.  There is no
# standalone lima_dri.so ninja target, so build the megadriver target.
if ! ninja -C build -j"$JOBS" src/gallium/targets/dri/libgallium_dri.so; then
  echo "!! targeted build failed, falling back to a full build"
  ninja -C build -j"$JOBS"
fi

echo
echo "=============================================================="
echo " 8. result"
echo "=============================================================="
SO=$(find build -name 'libgallium_dri.so' -type f | head -1)
[ -n "$SO" ] || { echo "!! libgallium_dri.so not found"; find build -name '*.so' | head -20; exit 1; }
echo "built: $SO"
ls -l "$SO"
file "$SO"
echo "--- NEEDED ---"
readelf -d "$SO" | grep NEEDED
echo "--- max GLIBC symbol version (must be <= 2.31) ---"
readelf --version-info "$SO" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -3
echo "--- max GLIBCXX symbol version (must be <= 3.4.28) ---"
readelf --version-info "$SO" | grep -oE 'GLIBCXX_[0-9.]+' | sort -Vu | tail -3 || true
echo "--- lima driver symbol present (megadriver marker) ---"
nm -D "$SO" | grep -c '__driDriverGetExtensions_lima' || true
echo "--- exported symbols ---"
nm -D --defined-only "$SO" | wc -l

mkdir -p $OUT
cp "$SO" $OUT/libgallium_dri.so
sha256sum $OUT/libgallium_dri.so | tee $OUT/sha256.txt
echo "GLIBC max: $(readelf --version-info "$SO" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1)" > $OUT/info.txt
echo "mesa: $MESA_VER" >> $OUT/info.txt
chmod -R a+rX $OUT
ls -l $OUT
echo
echo "===== DONE ====="
