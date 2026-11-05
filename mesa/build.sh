#!/bin/bash
#
# Cross-build Mesa 21.2.6's lima_dri.so for armhf (Hi3798MV100 box, Ubuntu 20.04).
#
# Runs NATIVELY on an amd64 runner: an arm-linux-gnueabihf cross toolchain
# compiles arm code at full speed, no qemu emulation, no container.  The .so is
# linked against the armhf sysroot that ships with the cross toolchain (glibc
# 2.31, same as focal), so the result loads on the device unchanged.
#
# Output: out/libgallium_dri.so (+ sha256.txt + info.txt).  On the device this
# megadriver is dropped in as /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so.
#
set -euo pipefail

MESA_VER=21.2.6
WORK="${WORK:-$PWD}"
OUT="$WORK/out"
CROSS=arm-linux-gnueabihf

echo "=============================================================="
echo " 0. environment"
echo "=============================================================="
uname -m
nproc
dpkg --print-foreign-architectures

echo
echo "=============================================================="
echo " 1. armhf cross toolchain + armhf dev libs"
echo "=============================================================="
# armhf is a "ports" architecture: its Packages index lives on ports.ubuntu.com,
# NOT on archive/security.ubuntu.com (those only carry amd64/i386).  The default
# jammy runner already points at archive/security.ubuntu.com for amd64 (which we
# must keep for the native build-essential/toolchain install below).  So we add a
# SEPARATE ports.ubuntu.com source restricted to [arch=armhf], instead of
# rewriting the amd64 sources (ports.ubuntu.com has no amd64 -- only non-x86).
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  build-essential ninja-build pkg-config python3 python3-pip \
  python3-mako python3-yaml bison flex \
  gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
  crossbuild-essential-armhf

"$CROSS-gcc" --version | head -1
echo "cross sysroot: $("$CROSS-gcc" -print-sysroot)"
echo "cross glibc max: $(strings "$("$CROSS-gcc" -print-sysroot)/lib/arm-linux-gnueabihf/libc.so.6" 2>/dev/null | grep '^GLIBC_' | sort -V | tail -1)"

echo
echo "=============================================================="
echo " 1b. focal (glibc 2.31) armhf runtime sysroot"
echo "=============================================================="
# The jammy cross toolchain links against glibc 2.35 (libc6-armhf-cross), which
# stamps GLIBC_2.32/2.33/2.34 symbol versions into the .so (pthread_* moved into
# libc at 2.34, stat64 got bumped at 2.33).  The device is focal glibc 2.31, so
# those symbols fail to resolve at load.  Fix: drop focal's 2.31 libc/libgcc/
# libstdc++ into a sysroot and make the linker use THOSE instead of the jammy
# 2.35 ones.  Symbol versions then fall back to <= 2.31.
FOCAL="$WORK/focal-sysroot"
mkdir -p "$FOCAL"
P="http://ports.ubuntu.com/ubuntu-ports"
dl() {  # dl <pool-path> <out>
  curl -fsSL --retry 3 --retry-delay 5 -m 180 -o "$2" "$P/$1" || { echo "!! fetch $1"; return 1; }
}
dl "pool/main/g/glibc/libc6_2.31-0ubuntu9.18_armhf.deb"              "$FOCAL/libc6.deb"
for d in "$FOCAL"/*.deb; do
  echo "--- $(basename "$d") ---"
  dpkg-deb -x "$d" "$FOCAL/root"
done
FOCAL_LIB="$FOCAL/root/lib/arm-linux-gnueabihf"
ls -l "$FOCAL_LIB"/libc.so.6 "$FOCAL_LIB"/ld-linux-armhf.so.3
echo "focal libc max: $(strings "$FOCAL_LIB/libc.so.6" | grep '^GLIBC_' | sort -V | tail -1)"

# Locate the cross toolchain's armhf lib dir and back up its glibc runtime libs,
# then overwrite them with the focal 2.31 ELF files.  This is what makes the linker
# stamp <= 2.31 symbol versions.  We replace ONLY glibc's own runtime libs (libc/
# libpthread/libm/libdl/librt/ld + their versioned .so files).  libgcc_s/libstdc++
# stay on the jammy versions -- their GLIBCXX_* symbol versions are a separate
# namespace and don't cause GLIBC_2.32+, and keeping the toolchain's own libstdc++
# avoids any C++ ABI mismatch with g++ 11.
CROSS_LIB="$("$CROSS-gcc" -print-file-name=libc.so.6 | xargs dirname)"
echo "cross lib dir: $CROSS_LIB"
mkdir -p "$FOCAL/backup"
# glibc versioned ELF + their unversioned symlinks (libc.so.6 -> libc-2.31.so etc.)
for f in libc-2.31.so libm-2.31.so libpthread-2.31.so libdl-2.31.so librt-2.31.so \
         ld-2.31.so libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
         ld-linux-armhf.so.3 libutil-2.31.so libutil.so.1 libresolv-2.31.so libresolv.so.2 \
         libnsl-2.31.so libnsl.so.1 libcrypt.so.1 libanl-2.31.so libanl.so.1; do
  if [ ! -e "$FOCAL_LIB/$f" ]; then
    continue
  fi
  # back up the jammy version if present
  if [ -e "$CROSS_LIB/$f" ]; then
    cp -a "$CROSS_LIB/$f" "$FOCAL/backup/" 2>/dev/null || true
    rm -f "$CROSS_LIB/$f"
  fi
  # copy the focal file/symlink in (resolve to real content)
  if [ -L "$FOCAL_LIB/$f" ]; then
    # symlink: recreate it pointing at the focal versioned .so
    target="$(readlink "$FOCAL_LIB/$f")"
    cp -a "$FOCAL_LIB/$target" "$CROSS_LIB/$target" 2>/dev/null || true
    ln -sf "$target" "$CROSS_LIB/$f"
  else
    cp -a "$FOCAL_LIB/$f" "$CROSS_LIB/$f"
  fi
done
echo "--- cross libc now points at ---"
ls -l "$CROSS_LIB"/libc.so.6 "$CROSS_LIB"/libpthread.so.0 "$CROSS_LIB"/libm.so.6 2>/dev/null
echo "cross glibc max now: $(strings "$CROSS_LIB/libc.so.6" | grep '^GLIBC_' | sort -V | tail -1)"

# armhf libraries Mesa links against.  dpkg --add-architecture lets apt pull the
# :armhf .so/.pc side by side with the native amd64 ones.  armhf lives on
# ports.ubuntu.com (not archive/security.ubuntu.com), so we add a dedicated
# [arch=armhf] source.
#
# ALSO: the runner's default sources (both the old one-line /etc/apt/sources.list
# AND any deb822 /etc/apt/sources.list.d/*.sources on GitHub/Azure runners) have NO
# arch qualifier.  Once armhf is added, `apt update` tries to fetch the armhf
# Packages index from those amd64-only hosts (security.ubuntu.com etc.) -> 404,
# which is exactly what killed the earlier runs.  So we nuke every pre-existing
# source and write ONE clean set: amd64 -> archive/security.ubuntu.com, armhf ->
# ports.ubuntu.com.  No sed guessing about file format.
sudo dpkg --add-architecture armhf
sudo rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
sudo tee /etc/apt/sources.list >/dev/null <<'EOF'
deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy main universe restricted multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy-updates main universe restricted multiverse
deb [arch=amd64] http://security.ubuntu.com/ubuntu jammy-security main universe restricted multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy-backports main universe restricted multiverse

deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports jammy main universe restricted multiverse
deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports jammy-updates main universe restricted multiverse
deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports jammy-security main universe restricted multiverse
deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports jammy-backports main universe restricted multiverse
EOF
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
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
echo " 2. meson (24.04 ships 1.x, fine for mesa 21.2)"
echo "=============================================================="
command -v meson || pip3 install --quiet --no-cache-dir "meson==0.59.4"
meson --version

echo
echo "=============================================================="
echo " 3. mesa $MESA_VER source"
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
echo " 4. patches"
echo "=============================================================="
for p in "$WORK"/mesa/patches/*.patch; do
  echo "--- $(basename "$p") ---"
  patch -p1 --forward --no-backup-if-mismatch < "$p"
done
grep -n "lima_force_pp_stream" src/gallium/drivers/lima/lima_job.c

echo
echo "=============================================================="
echo " 5. meson cross file + setup"
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
# Force pkg-config to only see armhf .pc files (not the native amd64 ones).
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
echo " 6. ninja (megadriver)"
echo "=============================================================="
JOBS=$(nproc)
if ! ninja -C build -j"$JOBS" src/gallium/targets/dri/libgallium_dri.so; then
  echo "!! targeted build failed, full build"
  ninja -C build -j"$JOBS"
fi

echo
echo "=============================================================="
echo " 7. result"
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
