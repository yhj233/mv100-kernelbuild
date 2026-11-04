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

# Everything the board needs at runtime must be =y: the uImage carries no
# modules and the rootfs has no matching /lib/modules, so a =m driver simply
# does not exist at boot. Checked after olddefconfig, see do_config.
REQUIRED_Y="ARCH_HISI COMMON_CLK_HI3798MV100 REGULATOR_HISI_STB HISI_FEMAC
	MDIO_HISI_FEMAC HISI_FESTA_PHY AMBA_PL08X MMC_DW_HI3798CV200 DRM DRM_HISTB_VDP2
	DRM_SII9134 DRM_CLIENT_SELECTION DRM_FBDEV_EMULATION DRM_LIMA SOUND SND
	SND_SOC SND_SOC_HDMI_CODEC SND_SOC_HISTB_AIAO_I2S SND_SOC_HISTB_AIAO_CARD
	MEDIA_SUPPORT
	VIDEO_DEV VIDEO_HISTB_VDEC VIDEO_HISTB_VENC VIDEO_HISTB_JPGD
	CGROUP_SCHED CGROUP_FREEZER CGROUP_DEVICE CGROUP_PIDS FANOTIFY
	CMDLINE_PARTITION DEVTMPFS MMC_BLOCK EXT4_FS SERIAL_AMBA_PL011
	PHY_HISI_INNO_USB2 USB_EHCI_HCD USB_EHCI_HCD_PLATFORM
	USB_OHCI_HCD USB_OHCI_HCD_PLATFORM CFG80211 MAC80211 RTL8XXXU
	ZRAM ZSMALLOC LZ4_COMPRESS LZ4_DECOMPRESS
	ARM_APPENDED_DTB ARM_ATAG_DTB_COMPAT ARM_ATAG_DTB_COMPAT_CMDLINE_FROM_BOOTLOADER"

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
	# 本地补丁：patches/ 下按"源码树相对路径"存放已改好的文件，直接覆盖。
	# 用于修上游还没修的问题（见 patches/README 与 _src/ 里的说明）。
	if [ -d "$PWD/patches" ]; then
		step "applying local patches"
		local f
		while IFS= read -r f; do
			mkdir -p "$SRC/$(dirname "$f")"
			cp "$PWD/patches/$f" "$SRC/$f"
			echo "  patched $f"
		done < <(cd "$PWD/patches" && find . -type f ! -name 'README*' | sed 's|^\./||')
	fi

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

	# MDIO bus controller -- the missing link between the two above.
	# HISI_FEMAC is only the MAC; it reaches the PHY through the MDIO bus
	# provided by MDIO_HISI_FEMAC (drivers/net/mdio/mdio-hisi-femac.c,
	# compatible "hisilicon,hisi-femac-mdio").  multi_v7_defconfig leaves it
	# off, and the failure mode is silent and confusing: the platform device
	# f9841100.mdio exists but binds to no driver, /sys/class/mdio_bus shows
	# only the virtual fixed-0, then hisi_femac_probe() reports
	#   "hisi-femac f9840000.ethernet: connect to PHY failed!"
	# and returns -ENODEV (not -EPROBE_DEFER, so never retried) -> no eth0.
	"${cfg[@]}" -e MDIO_HISI_FEMAC

	# DMA: upstream amba-pl08x (the old histb-dma was dropped from the tree)
	"${cfg[@]}" -e AMBA_PL08X

	# storage
	"${cfg[@]}" -e MMC_DW_HI3798CV200

	# USB: two EHCI+OHCI host pairs (9880/9890 and 9920/9930), each behind an
	# INNO USB2 PHY described as a child of peripheral-controller@8a20000.
	# multi_v7_defconfig ships PHY_HISI_INNO_USB2 as a *module*; the uImage
	# carries no modules, so the PHY never registers and both host pairs sit
	# in probe limbo forever:
	#   platform f9890000.usb: deferred probe pending: platform: wait for
	#     supplier .../usb2-phy@124/phy@1
	# -> no /sys/bus/usb/devices, no keyboard, no stick.  The generic
	# ehci/ohci platform glue is already =y, only the PHY is missing.
	"${cfg[@]}" -e PHY_HISI_INNO_USB2
	"${cfg[@]}" -e USB_EHCI_HCD
	"${cfg[@]}" -e USB_EHCI_HCD_PLATFORM
	"${cfg[@]}" -e USB_OHCI_HCD
	"${cfg[@]}" -e USB_OHCI_HCD_PLATFORM
	"${cfg[@]}" -e USB_STORAGE
	"${cfg[@]}" -e USB_HID

	# wireless: the on-board USB dongle is an RTL8188F (0bda:f179, "802.11n").
	# multi_v7_defconfig ships CFG80211/MAC80211 as modules and leaves
	# RTL8XXXU off, so with a module-less uImage there is no wireless stack
	# at all -- the dongle enumerates on the bus but never gets a wlan iface.
	"${cfg[@]}" -e CFG80211
	"${cfg[@]}" -e MAC80211
	"${cfg[@]}" -e RTL8XXXU
	"${cfg[@]}" -e LEDS_CLASS

	# zram: compressed RAM swap.  1 GB of RAM with Firefox running means the
	# disk swap on eMMC gets hit constantly; zram trades a few CPU cycles for
	# ~2x compression, which on this board is an order of magnitude faster
	# than swapping to eMMC.  ZRAM is simply absent from multi_v7_defconfig
	# and the uImage carries no modules, so it has to be built in.
	# Both backends are kept: the default stays lzo-rle (cheapest on a
	# Cortex-A7), the setup script switches to lz4 when it is available.
	"${cfg[@]}" -e ZRAM
	"${cfg[@]}" -e ZRAM_BACKEND_LZO
	"${cfg[@]}" -e ZRAM_BACKEND_LZ4

	# firmware: rtl8xxxu is built in and probes at ~1.65 s, while the rootfs on
	# p9 does not mount until ~1.69 s.  request_firmware() always loses that
	# race, so /lib/firmware is not reachable yet and the probe dies with
	#   Direct firmware load for rtlwifi/rtl8188fufw.bin failed with error -2
	# leaving no wlan0 (a manual unbind/bind later works, which is how this was
	# diagnosed).  Embedding the blob into the image sidesteps the ordering.
	fwdir="$PWD/firmware"
	[ -f "$fwdir/rtlwifi/rtl8188fufw.bin" ] ||
		die "firmware/rtlwifi/rtl8188fufw.bin missing (CONFIG_EXTRA_FIRMWARE needs it)"
	"${cfg[@]}" -e EXTRA_FIRMWARE
	"${cfg[@]}" --set-str EXTRA_FIRMWARE "rtlwifi/rtl8188fufw.bin"
	"${cfg[@]}" --set-str EXTRA_FIRMWARE_DIR "$fwdir"

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

	# audio: SOUND -> SND -> SND_SOC is a chain of tristates, and a child can
	# never be more built-in than its parent. multi_v7_defconfig ships
	# CONFIG_SOUND=m, so setting SND/SND_SOC to y silently degrades to m and
	# every ASoC driver ends up in a module that the uImage does not carry.
	# SOUND has to be flipped first.
	"${cfg[@]}" -e SOUND
	"${cfg[@]}" -e SND
	"${cfg[@]}" -e SND_SOC
	"${cfg[@]}" -e SND_SOC_HDMI_CODEC
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

	# systemd: the rootfs on p9 is Ubuntu 20.04 (systemd 245), which runs in
	# hybrid cgroup mode and expects the cgroup v1 controllers the vendor
	# 4.4 kernel exposes.  With only CONFIG_CGROUPS=y systemd still boots but
	# reports a missing controller set and loses resource accounting.
	# FANOTIFY is what journald uses to notice log rotation.
	"${cfg[@]}" -e CGROUP_SCHED
	"${cfg[@]}" -e CGROUP_FREEZER
	"${cfg[@]}" -e CGROUP_DEVICE
	"${cfg[@]}" -e CGROUP_PIDS
	"${cfg[@]}" -e FANOTIFY

	# boot-critical plumbing.
	# CMDLINE_PARTITION is what parses the vendor's blkdevparts= argument
	# (upstream block/partitions/cmdline.c, __setup("blkdevparts=", ...)).
	# The eMMC on this board has NO MBR/GPT at all -- the nine partitions
	# exist only because that parser creates them.  Lose this option and
	# root=/dev/mmcblk0p9 stops resolving, i.e. no root filesystem.
	"${cfg[@]}" -e CMDLINE_PARTITION
	"${cfg[@]}" -e DEVTMPFS
	"${cfg[@]}" -e MMC_BLOCK
	"${cfg[@]}" -e EXT4_FS
	"${cfg[@]}" -e SERIAL_AMBA_PL011

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
	grep -E "HISTB|HI3798MV100|HISI_FESTA|FEMAC|LIMA|APPENDED_DTB|^CONFIG_CMDLINE|^CONFIG_SOUND|^CONFIG_SND|^CONFIG_CGROUP|^CONFIG_FANOTIFY|^CONFIG_MMC_BLOCK|^CONFIG_EXT4_FS|^CONFIG_SERIAL_AMBA" \
		"$OUT/.config" || true

	step "verifying every required option is built in"
	local missing=0 sym got
	for sym in $REQUIRED_Y; do
		if ! grep -qx "CONFIG_$sym=y" "$OUT/.config"; then
			got=$(grep -m1 -E "^CONFIG_$sym=|^# CONFIG_$sym is not set" "$OUT/.config" || true)
			printf '  not built in: CONFIG_%s (%s)\n' "$sym" "${got:-absent}" >&2
			missing=$((missing + 1))
		fi
	done
	if [ "$missing" -gt 0 ]; then
		die "$missing required option(s) are not =y -- the uImage would boot with them missing"
	fi
	echo "  all $(echo $REQUIRED_Y | wc -w) required options are =y"
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
