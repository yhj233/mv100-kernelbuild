#!/bin/bash
# Hi3798MV100 (Huawei EC6108V9C) kernel build helper
#
# Usage:
#   ./build.sh              # configure + build zImage/dtbs + pack uImage
#   ./build.sh config       # only configure
#   ./build.sh build        # only build (uses existing .config)
#   ./build.sh pack         # only repack uImage from existing artifacts
#
# Env:
#   SRC=...    kernel source tree   (default: ./mv100-linux)
#   OUT=...    build output dir     (default: ./obj-mv100)
#   CROSS=...  toolchain prefix     (default: arm-linux-gnueabihf-)
#   JOBS=...   parallel jobs        (default: nproc)
#   LOADADDR=  uImage load/entry    (default: 0x02000000, the vendor value)
#
# Requires: build-essential bc bison flex libssl-dev libncurses-dev
#           kmod cpio rsync u-boot-tools gcc-arm-linux-gnueabihf

set -euo pipefail

SRC=${SRC:-$PWD/mv100-linux}
OUT=${OUT:-$PWD/obj-mv100}
CROSS=${CROSS:-arm-linux-gnueabihf-}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
LOADADDR=${LOADADDR:-0x02000000}   # must match the vendor uImage header, see do_pack
DTB=hi3798mv100-ec6108v9c.dtb
UIMAGE=${UIMAGE:-uImage-mv100.img}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

need_tools() {
	local missing=()
	# dtc is not required here: the kernel builds its own copy under scripts/dtc
	for t in make gcc "${CROSS}gcc" bc bison flex mkimage; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	if [ ${#missing[@]} -gt 0 ]; then
		die "missing tools: ${missing[*]}
  sudo apt install -y build-essential bc bison flex libssl-dev libncurses-dev \\
                      kmod cpio rsync u-boot-tools gcc-arm-linux-gnueabihf device-tree-compiler"
	fi
	[ -d "$SRC" ] || die "kernel tree not found: $SRC
  git clone --depth 1 -b histb https://github.com/histb-mainline/linux.git $SRC"
	[ -f "$SRC/Makefile" ] || die "$SRC does not look like a kernel tree"
}

do_config() {
	step "configuring (multi_v7_defconfig + mv100 options)"
	mkdir -p "$OUT"
	make -C "$SRC" ARCH=arm CROSS_COMPILE="$CROSS" O="$OUT" multi_v7_defconfig

	# scripts/config must run from the source tree; --file points at the O= config
	local cfg=("$SRC/scripts/config" --file "$OUT/.config")

	# clock / reset / regulator
	"${cfg[@]}" -e COMMON_CLK_HI3798MV100
	"${cfg[@]}" -e REGULATOR_HISI_STB

	# ethernet + Festa PHY (PHY needs hisilicon/festa.<id>.ucode to be fully happy)
	"${cfg[@]}" -e HISI_FEMAC
	"${cfg[@]}" -e HISI_FESTA_PHY

	# DMA: upstream amba-pl08x (the old histb-dma was dropped from the tree)
	"${cfg[@]}" -e AMBA_PL08X

	# storage
	"${cfg[@]}" -e MMC_DW_HI3798CV200

	# IR remote
	"${cfg[@]}" -e IR_HIX5HD2
	"${cfg[@]}" -e RC_DECODER

	# display: VDP2 master.  The Hi3798MV100 drives an *external* SiI9134 HDMI
	# transmitter, so the bridge is DRM_SII9134 (drivers/gpu/drm/bridge),
	# NOT DRM_HISTB_HDMI -- that one is the on-chip HDMI of mv200 and is
	# ARM64-only.  Without SII9134 the VDP2 CRTC has no downstream bridge
	# and the display never comes up (serial console only).
	"${cfg[@]}" -e DRM
	"${cfg[@]}" -e DRM_HISTB_VDP2
	"${cfg[@]}" -e DRM_SII9134
	"${cfg[@]}" -e DRM_CLIENT_SELECTION
	"${cfg[@]}" -e DRM_FBDEV_EMULATION

	# GPU: Mali-450 via lima (defconfig ships it as =m)
	"${cfg[@]}" -e DRM_LIMA

	# audio: SND / SND_SOC must be built in first, otherwise every ASoC driver
	# is capped at =m and ends up in no image at all
	"${cfg[@]}" -e SND
	"${cfg[@]}" -e SND_SOC
	"${cfg[@]}" -e SND_SOC_HISTB_AIAO_I2S
	"${cfg[@]}" -e SND_SOC_HISTB_AIAO_CARD
	"${cfg[@]}" -e SND_SIMPLE_CARD

	# video codecs: same story with MEDIA_SUPPORT / VIDEO_DEV
	"${cfg[@]}" -e MEDIA_SUPPORT
	"${cfg[@]}" -e VIDEO_DEV
	"${cfg[@]}" -e V4L2_MEM2MEM_DEV
	"${cfg[@]}" -e VIDEO_HISTB_VDEC
	"${cfg[@]}" -e VIDEO_HISTB_JPGD
	"${cfg[@]}" -e VIDEO_HISTB_JPGE
	"${cfg[@]}" -e VIDEO_HISTB_VENC

	# boot: dual console, dtb appended to zImage, and let the bootloader's
	# ATAGS (bootargs + memory size) be folded into the appended dtb --
	# the board dts has no /memory node, memory comes from the ATAGS.
	"${cfg[@]}" --set-str CMDLINE "console=tty0"
	"${cfg[@]}" -e CMDLINE_EXTEND
	"${cfg[@]}" -e ARM_APPENDED_DTB
	"${cfg[@]}" -e ARM_ATAG_DTB_COMPAT
	"${cfg[@]}" -e ARM_ATAG_DTB_COMPAT_CMDLINE_FROM_BOOTLOADER

	make -C "$SRC" ARCH=arm CROSS_COMPILE="$CROSS" O="$OUT" olddefconfig

	step "resulting mv100 options"
	grep -E "HISTB|HI3798MV100|HISI_FESTA|FEMAC|LIMA|APPENDED_DTB|^CONFIG_CMDLINE" \
		"$OUT/.config" || true
}

do_build() {
	[ -f "$OUT/.config" ] || die "no .config in $OUT, run './build.sh config' first"
	step "building zImage + dtbs (-j$JOBS)"
	make -C "$SRC" ARCH=arm CROSS_COMPILE="$CROSS" O="$OUT" -j"$JOBS" zImage dtbs

	[ -f "$OUT/arch/arm/boot/zImage" ] || die "zImage missing"
	[ -f "$OUT/arch/arm/boot/dts/hisilicon/$DTB" ] || die "$DTB missing (CONFIG_ARCH_HISI?)"
	printf 'zImage: %s\n' "$(du -h "$OUT/arch/arm/boot/zImage" | cut -f1)"
	printf 'dtb   : %s\n' "$(du -h "$OUT/arch/arm/boot/dts/hisilicon/$DTB" | cut -f1)"
}

do_pack() {
	local boot="$OUT/arch/arm/boot"
	[ -f "$boot/zImage" ] || die "zImage missing, run './build.sh build' first"
	[ -f "$boot/dts/hisilicon/$DTB" ] || die "$DTB missing"

	step "packing uImage"
	# Load/entry address must match what this bootloader expects.  On the
	# EC6108V9C the stock bootargs partition carries:
	#   bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000;bootm 0x1FFFFC0
	# and the vendor kernel image header says load=0x02000000 entry=0x02000000.
	# 0x1FFFFC0 is the uImage header, i.e. 0x02000000 minus the 64-byte header.
	# Using 0x00008000 here makes bootm relocate the kernel into low memory
	# and the board hangs.
	cat "$boot/zImage" "$boot/dts/hisilicon/$DTB" >"$boot/zImage-dtb"
	mkimage -A arm -O linux -T kernel -C none \
		-a "$LOADADDR" -e "$LOADADDR" \
		-n "Linux mv100" -d "$boot/zImage-dtb" "$boot/$UIMAGE"

	local sz
	sz=$(stat -c%s "$boot/$UIMAGE")
	printf 'uImage: %s (%s bytes)\n' "$boot/$UIMAGE" "$sz"
	[ "$sz" -lt 16777216 ] || echo "WARNING: over the 16 MB eMMC partition limit"
	cat <<EOF

Next: serve it over tftp and boot on the board (fastboot# prompt):

  tftp 0x42000000 $UIMAGE
  bootimg 0x42000000

If the board hangs right after "Starting kernel", the load address in the
uImage header is wrong for this bootloader.  Read the vendor image once:

  mkimage -l recovery.img

and rebuild with -a/-e set to the values it reports (default here 0x00008000).
EOF
}

need_tools
case "${1:-all}" in
	config) do_config ;;
	build)  do_build ;;
	pack)   do_pack ;;
	all)    do_config; do_build; do_pack ;;
	*)      die "unknown target '$1' (config|build|pack|all)" ;;
esac
