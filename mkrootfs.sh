#!/bin/bash
# 构建 Debian armhf rootfs（给 Hi3798MV100 / EC6108V9C 用）
#
# 需要：Linux + root + qemu-user-static + debootstrap + e2fsprogs
# 用法： sudo ./mkrootfs.sh
#
# 产出：
#   debian-armhf-rootfs.tar.xz   完整文件系统（可解到任意 ext4 分区）
#   debian-armhf-rootfs.img.gz  裸 ext4 镜像（无分区表，可直接 dd 到 /dev/mmcblk0p9）
#
# 环境变量：
#   SUITE=bookworm  ROOTPW=123456  IMGSIZE=4G  BOXNAME=mv100  MIRROR=...

set -euo pipefail

ARCH=armhf
SUITE=${SUITE:-bookworm}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
ROOTPW=${ROOTPW:-123456}
BOXNAME=${BOXNAME:-mv100}
IMGSIZE=${IMGSIZE:-4G}
ROOT=$PWD/rootfs
OUT_TAR=debian-armhf-rootfs.tar.xz
OUT_IMG=debian-armhf-rootfs.img

step() { printf '\n==> %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "需要 root" >&2; exit 1; }
[ -x /usr/bin/qemu-arm-static ] || { echo "缺 qemu-arm-static: apt install qemu-user-static" >&2; exit 1; }

# ---- 1. 第一遍：只下载，不执行（armhf 二进制在 x86 上跑不了） ----
step "debootstrap 第一遍 ($SUITE/$ARCH)"
rm -rf "$ROOT"
mkdir -p "$ROOT"
debootstrap --arch="$ARCH" --foreign --variant=minbase \
	--include=ca-certificates "$SUITE" "$ROOT" "$MIRROR"

# ---- 2. 塞进 qemu 静态解释器，跑第二遍 ----
step "第二遍：chroot 里完成安装"
cp /usr/bin/qemu-arm-static "$ROOT/usr/bin/"
chroot "$ROOT" /debootstrap/debootstrap --second-stage

# ---- 3. 挂上伪文件系统，装包 ----
cleanup() {
	for d in dev/pts dev proc sys; do
		mountpoint -q "$ROOT/$d" && umount -l "$ROOT/$d" || true
	done
}
trap cleanup EXIT
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"

step "安装 sshd 与常用工具"
cat >"$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main
deb $MIRROR $SUITE-updates main
deb http://security.debian.org/debian-security $SUITE-security main
EOF
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive \
	apt-get update -qq
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive \
	apt-get install -y --no-install-recommends \
	-o Dpkg::Options::=--force-confold \
	systemd-sysv systemd-resolved dbus \
	openssh-server iproute2 iputils-ping \
	curl ca-certificates nano vim-tiny less htop rsync \
	e2fsprogs kmod udev

# ---- 4. 配置系统 ----
step "写配置"

echo "$BOXNAME" >"$ROOT/etc/hostname"
cat >"$ROOT/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$BOXNAME
::1		localhost ip6-localhost ip6-loopback
EOF

# fstab：故意不写 / 条目。根设备由 bootargs 的 root= 指定；而 SD 卡和 eMMC 上
# 可能同时存在同一个镜像（LABEL 相同），fstab 里写死设备名或 LABEL 都会在"两份
# 都在"时选错。systemd 不需要 fstab 里有一行 / 才能正常启动。
cat >"$ROOT/etc/fstab" <<'EOF'
# <device>        <mount>  <type>  <options>          <dump> <pass>
# 根分区由内核 bootargs 的 root= 决定，这里不列 / 以免和另一份镜像打架。
# 迁移完成后 eMMC 上的根分区通常是 /dev/mmcblk0p9（原厂 -(ubuntu)）。
tmpfs             /tmp     tmpfs   defaults,nosuid    0      0
EOF

# 网络：systemd-networkd 走 DHCP，网卡名兜住 eth0 / en* 两种
mkdir -p "$ROOT/etc/systemd/network"
cat >"$ROOT/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=eth* en*

[Network]
DHCP=yes

[DHCPv4]
UseDomains=yes
EOF

# root 登录 + 密码认证（默认只允许密钥，得显式打开）
mkdir -p "$ROOT/etc/ssh/sshd_config.d"
cat >"$ROOT/etc/ssh/sshd_config.d/99-mv100.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UseDNS no
EOF
# 兜底：确保主配置真的 include 了 drop-in，并把两行也改掉
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' "$ROOT/etc/ssh/sshd_config" ||
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$ROOT/etc/ssh/sshd_config"
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
       -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
       "$ROOT/etc/ssh/sshd_config"

echo 'LANG=C.UTF-8' >"$ROOT/etc/default/locale"
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOT/etc/localtime"

step "设置 root 密码 + 生成 host key"
printf 'root:%s\n' "$ROOTPW" | chroot "$ROOT" chpasswd

# selinux/apparmor 之类在盒子上没意义，避免起不来时干扰判断
chroot "$ROOT" ssh-keygen -A

# ---- 5. 开机启用 ----
step "启用 ssh / 网络 / 串口 getty"
enable_unit() {   # enable_unit <unit 文件名> [wants 目录]
	local unit=$1 target=${2:-multi-user.target}
	mkdir -p "$ROOT/etc/systemd/system/$target.wants"
	ln -sf "/lib/systemd/system/$unit" "$ROOT/etc/systemd/system/$target.wants/$unit"
}
enable_unit ssh.service
enable_unit systemd-networkd.service
enable_unit systemd-resolved.service
enable_unit systemd-networkd.socket sockets.target
# 串口控制台：console=ttyAMA0 时 systemd 会自动生成，这里显式开一份
mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
	"$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

# ---- 6. 清理镜像里不该留的东西 ----
step "清理"
rm -f "$ROOT/usr/bin/qemu-arm-static"
: >"$ROOT/etc/machine-id"
rm -rf "$ROOT/var/lib/apt/lists"/* "$ROOT/var/cache/apt/archives"/*.deb
rm -f "$ROOT/root/.bash_history"

du -sh "$ROOT"

# ---- 7. 打包 ----
step "打包 tar.xz"
tar --numeric-owner --xattrs -C "$ROOT" -cJf "$OUT_TAR" .

step "生成 ext4 镜像 ($IMGSIZE)"
rm -f "$OUT_IMG"
truncate -s "$IMGSIZE" "$OUT_IMG"
mkfs.ext4 -F -q -L mv100root -m 1 -d "$ROOT" "$OUT_IMG"
echo "镜像内已用: $(dumpe2fs -h "$OUT_IMG" 2>/dev/null | awk -F: '/Block count/{print $2}') 块"
gzip -1 -kf "$OUT_IMG"

ls -lh "$OUT_TAR" "$OUT_IMG".gz
step "完成"
