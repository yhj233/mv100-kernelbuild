# Hi3798MV100（EC6108V9C）内核编译指南

基于 `histb-mainline/linux` 的 `histb` 分支（基线 Linux 7.3-rc7，ARM32）。
本文所有配置项都对应树里真实存在的 Kconfig 符号。

---

## 编译路线怎么选

| 路线 | 适合 | 编一次 | 痛点 |
|---|---|---|---|
| **GitHub Actions**（推荐先用） | 只想拿到一个能跑的镜像 | 20–25 min（4 vCPU） | 改一行代码也要走一遍 push → 等 → 下载 |
| **WSL2 + Ubuntu** | 要反复改驱动 / 调参数 | 首次 20 min，增量 1–3 min | 得先解掉安全中心对 `wsl.exe` 的黑名单；WSL2 默认 NAT 下板子够不到宿主 tftp，需 `networkingMode=mirrored` |
| **虚拟机 / 独立 Linux 机** | 长期做移植 | 同 WSL | 要装系统、占空间 |

结论：**先 Actions 出镜像验证板子，等真要动驱动代码了再上 WSL。**
上板那一步不需要 Linux——Windows 上跑个 Tftpd64（69/UDP）就能给 U-Boot 发镜像。

Actions 用法：把 `build.sh` 和 `.github/workflows/build.yml` 放进自己的 repo（**public 仓库
Actions 免费无限**；private 每月 2000 分钟，按一次 25 分钟算也够 80 次），
Actions 页点 “Run workflow”，跑完在 artifact 里下 `mv100-uImage`。

---

## 0. 先决条件：你得在 Linux 上编

Windows 本机编不了（WSL 被安全策略拦、无 docker、无 arm 交叉工具链）。三个可用方式：

1. **WSL2 + Ubuntu 24.04**（最省事）
2. **VMware / VirtualBox 里的 Ubuntu**
3. **一台 x86 Linux 服务器**（编得最快）

依赖（Ubuntu/Debian）：

```bash
sudo apt install -y build-essential git bc bison flex libssl-dev libncurses-dev \
                    kmod cpio rsync u-boot-tools gcc-arm-linux-gnueabihf device-tree-compiler
```

`gcc-arm-linux-gnueabihf` 在 Ubuntu 24.04 是 13.x，编 7.3 没问题。

---

## 1. 取源码

```bash
git clone --depth 1 -b histb https://github.com/histb-mainline/linux.git mv100-linux
cd mv100-linux
```

- 只取最新一次提交，约 300 MB；完整历史是 148 万提交，**千万别全 clone**。
- 需要约 **6 GB** 空闲（源码 + 编译产物）。
- 网络不稳时加 `-c http.postBuffer=524288000`，或先 `unset http_proxy https_proxy`。

---

## 2. 配置

基座用 `multi_v7_defconfig`（已含 `CONFIG_ARCH_HISI=y`、`CONFIG_DRM_LIMA=m`），
再把 mv100 需要的功能逐个打开。**全部编成内建（`=y`）**——作者的 initramfs 里没有 kmod，
驱动当模块会白编。

```bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- O=../obj-mv100 multi_v7_defconfig

CFG="scripts/config --file ../obj-mv100/.config"

# --- 时钟 / 复位 / 调压 ---
$CFG -e COMMON_CLK_HI3798MV100
$CFG -e REGULATOR_HISI_STB

# --- 网口 + Festa PHY（PHY 需要 microcode 才会工作）---
$CFG -e HISI_FEMAC
$CFG -e HISI_FESTA_PHY

# --- DMA：改用上游 pl08x，histb-dma 已从树里摘除 ---
$CFG -e AMBA_PL08X

# --- eMMC / SD ---
$CFG -e MMC_DW_HI3798CV200

# --- 遥控器 ---
$CFG -e IR_HIX5HD2
$CFG -e RC_DECODER

# --- 显示：VDP2 主控 + **外置 SiI9134 HDMI 桥** ---
$CFG -e DRM
$CFG -e DRM_HISTB_VDP2
$CFG -e DRM_SII9134              # 关键！mv100 的 HDMI 是 SiI9134，不是片上 HDMI
$CFG -e DRM_CLIENT_SELECTION      # 7.3 的 fbdev console 开关
$CFG -e DRM_FBDEV_EMULATION
# 注意：DRM_HISTB_HDMI 是 mv200 的片上 HDMI，depends on ARM64，mv100 用不到

# --- GPU：Mali-450 走 lima（defconfig 里是 =m，改成 =y）---
$CFG -e DRM_LIMA

# --- 音频：先把 SOUND 抬成内建，否则 SND / SND_SOC 最多只能 =m ---
#    tristate 子项永远不能比父项更内建：multi_v7_defconfig 里 CONFIG_SOUND=m，
#    只设 SND=y 会被 olddefconfig 悄悄降回 m，148 个音频符号全进模块，
#    而 uImage 不带模块 —— 表现就是“内核能起、aplay 看不到声卡”。
$CFG -e SOUND
$CFG -e SND
$CFG -e SND_SOC
$CFG -e SND_SOC_HDMI_CODEC
$CFG -e SND_SOC_HISTB_AIAO_I2S
$CFG -e SND_SOC_HISTB_AIAO_CARD
$CFG -e SND_SIMPLE_CARD

# --- 视频编解码：同理，MEDIA_SUPPORT / VIDEO_DEV 是父项 ---
$CFG -e MEDIA_SUPPORT
$CFG -e VIDEO_DEV
$CFG -e V4L2_MEM2MEM_DEV
$CFG -e VIDEO_HISTB_VDEC
$CFG -e VIDEO_HISTB_JPGD
$CFG -e VIDEO_HISTB_JPGE
$CFG -e VIDEO_HISTB_VENC

# --- 启动相关：串口+屏幕双 console，dtb 追加在 zImage 后面，
#     并让 bootloader 的 ATAGS 折进 dtb（板级 dts 没有 /memory 节点，
#     内存大小是从 ATAGS 来的）---
$CFG --set-str CMDLINE "console=tty0"
$CFG -e CMDLINE_EXTEND
$CFG -e ARM_APPENDED_DTB
$CFG -e ARM_ATAG_DTB_COMPAT
$CFG -e ARM_ATAG_DTB_COMPAT_CMDLINE_FROM_BOOTLOADER

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- O=../obj-mv100 olddefconfig
```

改完可以核对一眼：`grep -E "HISTB|HI3798MV100|FESTA|LIMA" ../obj-mv100/.config`
应该是 `=y` 而不是 `=m`。

> `scripts/config -e` 对不存在的符号是**静默忽略**的。如果某个选项在 `make menuconfig` 里
> 搜不到，说明当前树里它已改名或不存在——不影响其它项。

---

## 3. 编

```bash
make -j$(nproc) ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- O=../obj-mv100 zImage dtbs
```

产物：

| 文件 | 路径 |
|---|---|
| 内核 | `../obj-mv100/arch/arm/boot/zImage` |
| 设备树 | `../obj-mv100/arch/arm/boot/dts/hisilicon/hi3798mv100-ec6108v9c.dtb` |

全内建的话出来的 `zImage` 大约 9–10 MB。

---

## 4. 打包成 uImage

板子的 fastboot 吃 **uImage**（`bootimg` 命令）。zImage 后面拼上 dtb，再套 uImage 头：

```bash
cd ../obj-mv100/arch/arm/boot
cat zImage dts/hisilicon/hi3798mv100-ec6108v9c.dtb > zImage-dtb

mkimage -A arm -O linux -T kernel -C none \
        -a 0x02000000 -e 0x02000000 \
        -n "Linux mv100" -d zImage-dtb uImage-mv100.img
```

**`0x02000000` 是这个板子的硬性要求，不是抄来的通用值。** 依据在原厂 `bootargs` 分区里：

```
bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000;bootm 0x1FFFFC0
```

内核分区从 14 MB 开始，读到 `0x1FFFFC0` 再 `bootm`。`0x1FFFFC0` 正好是 `0x02000000` 减去 64 字节 uImage 头，
原厂 kernel 镜像头的 `load/entry` 也都是 `0x02000000`。要是写成 ARM zImage 常见的 `0x00008000`，
`bootm` 会把内核搬到 32 MB 以下的内存去，直接死机。

产物大小：kernel 分区 **20 MB**（`0xA000` 扇区），超了就放不下。

---

## 5. 上板（EC6108V9C 原厂 fastboot）

### 5.1 先内存引导，别急着写 eMMC

串口 115200 连上，开机打断进 `fastboot#`（`bootdelay=0`，需要在串口里一直发 Ctrl+C 抢）。
确认命令能用：`help`、`printenv`。

宿主机（Windows 上用 **Tftpd64**，把根目录指向解压后 img 所在文件夹；或 Linux 上 atftpd）
和板子要在同一网段。板子默认：

```
ipaddr=192.168.1.10   serverip=192.168.1.1
```

所以要么把 PC 设成 `192.168.1.1`，要么直接改板子：

```
setenv ipaddr 192.168.1.10
setenv serverip 192.168.1.2          # 改成你 PC 的地址
setenv bootargs 'console=ttyAMA0,115200 root=/dev/mmcblk0p9 rootfstype=ext4 rootwait blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),512M(backup),-(ubuntu)'
tftp 0x42000000 uImage-mv100.img
bootimg 0x42000000
```

- `0x42000000` 是 uImage **在 RAM 里的落点**，`bootimg` 会按头里的 load 地址把它搬到 `0x02000000`，两者别混。
- 上面这串 `bootargs` 就是从你固件包的 `bootargs9-32.bin` 里抄的原厂值，`root=/dev/mmcblk0p9` 就是
  `-(ubuntu)` 那个分区。`console=tty0` 由内核内置 cmdline 追加（`CMDLINE_EXTEND`），不用手写。
- 断电重启即恢复原厂内核，这一步不动 eMMC，随便试。

### 5.2 确认没问题再写 eMMC（持久化）

内存引导成功、串口日志干净之后：

```
tftp 0x42000000 uImage-mv100.img
mmc write 0 0x42000000 0x7000 0x6100        # 0x7000 = 14MB 偏移；0x6100 ≈ 12.4MB/512
```

扇区数 = 文件大小 ÷ 512，向上取整。写完 `reset` 直接从 eMMC 启动（走原厂 `bootcmd`）。

### 5.3 变砖了怎么救

你手里那套 `TTL-hi3798mv100-32bit/` 就是救砖工具：

- `emmc.flash`（1.29 GB）是整盘备份，`emmc_TTL-hi3798mv100-32.xml` 是 HiTool 的分区表；
- 用 **HiTool**（海思工具，串口 + 网口）加载这个 xml，勾上 `kernel` 分区单刷原厂
  `hi_kernel-mv100-32.bin` 就能回到现在的 4.4 内核；
- 实在不行整盘刷 `emmc.flash`。

所以写 eMMC 之前，**先确认 HiTool 能识别到板子**，别等砖了才找工具。

### 5.4 另一条路：从正在运行的系统里写（SSH，不碰串口）

板子现在跑着 4.4 厂商内核、能 SSH 的话，不用串口也不用 TFTP，直接把 uImage 怼进
kernel 分区。用工作区里的 `install-kernel.sh`：

```sh
scp uImage-mv100.img root@盒子IP:/root/
ssh root@盒子IP 'sh /root/install-kernel.sh /root/uImage-mv100.img'   # 交互确认
ssh root@盒子IP 'AUTO=1 sh /root/install-kernel.sh /root/uImage-mv100.img'  # 跳过确认
```

脚本会：校验 uImage magic → 检查大小是否放得下 20 MB 分区 → 备份现内核到
`/root/kernel-backup/kernel-old.img` 和分区表 → 写入 → **回读比对 sha256**。

失败回滚（只在新内核还能进 shell 时有意义）：

```sh
sh restore-kernel.sh
```

**这条路的风险比串口那条高**：`bootdelay=0`，没有交互窗口，新内核如果 panic 就直接停在那里，
回滚脚本也没机会跑。所以要么先确认 HiTool 能连上，要么先走 5.1 的内存引导验一轮。

写之前自己核对一眼分区，别把 kernel 写到 rootfs 上：

```sh
cat /proc/cmdline        # 里面的 blkdevparts 就是权威分区表
cat /proc/partitions     # 找 20 MB 的那个，通常 /dev/mmcblk0p6
```

---

## 6. 根文件系统

内核本身不带 rootfs。这台机器的原厂 rootfs 是 4.4 时代的 Ubuntu，挂到 7.3 上
systemd/udev 大概率闹脾气，所以**推荐直接换一份干净的 Debian armhf**。

### 6.1 用 Actions 造一份（推荐）

`.github/workflows/rootfs.yml` + `mkrootfs.sh` 会 debootstrap 出 Debian armhf，
装好 openssh-server、DHCP、串口 getty，root 密码可设，产出两个 artifact：

| artifact | 内容 | 用法 |
|---|---|---|
| `debian-armhf-rootfs-tar` | `debian-armhf-rootfs.tar.xz` | 解到任意已 mkfs 的 ext4 分区 |
| `debian-armhf-rootfs-img` | `debian-armhf-rootfs.img.gz` | 解压后直接 dd 到 `/dev/mmcblk0p9` |

在 Actions 页选 **Debian armhf rootfs** → Run workflow，可改版本（bookworm/trixie）、
密码、镜像大小。默认 `2G`；要装 XFCE 就给 `4G`。

打开 root 密码登录是显式做的三件事，缺一不可：

```
PermitRootLogin yes            # bookworm 默认 prohibit-password
PasswordAuthentication yes     # 默认只认密钥
/etc/shadow 里写 hash          # 空密码会被 sshd 直接拒
```

### 6.2 怎么落到板子上

⚠️ **U 盘不行**：mv100 的 USB2 PHY（`hisilicon,hi3798mv100-usb2-phy`）在这个树里没有
驱动，`ehci0` 会一直 probe defer，`lsusb` 空的。虽然 `USB_STORAGE=y`，但没 PHY 就没设备。

可用的两条路：

**A. microSD（最简单）** — `&sd` 是 okay，走 `snps,dw-mshc`（`MMC_DW_PLTFM=y` 覆盖）。
在 PC 上用 Win32DiskImager 把解压后的 `debian-armhf-rootfs.img` 直接写进卡，然后：

```
setenv bootargs 'console=ttyAMA0,115200 root=/dev/mmcblk1 rootfstype=ext4 rootwait'
tftp 0x42000000 uImage-mv100.img
bootimg 0x42000000
```

⚠️ **`root=` 后面没有分区号，是整卡。** 产出的是**裸 ext4 镜像**（`mkfs.ext4 -d` 直接
做在文件上，没有 MBR 分区表），写进卡之后文件系统就占满整张卡，`/dev/mmcblk1` 本身就是
那个文件系统。这也正是后面 `dd` 到 eMMC `/dev/mmcblk0p9` 需要的格式——那个分区同样是
一个裸文件系统。想在 PC 上看卡内容要用支持 ext4 的工具，Windows 资源管理器看不见。

⚠️ **`mmcblk` 编号别猜。** mainline DTS 里 `sd@9820000` 在 `emmc@9830000` 之前注册，
插卡时 SD 很可能抢到 `mmcblk0`、eMMC 变 `mmcblk1`，和原厂 DTS 正好相反。用 CID 认：

```sh
cat /sys/block/mmcblk*/device/name     # eMMC 显示芯片型号，SD 显示卡型号
ls /sys/block/mmcblk*/                  # eMMC 通常还多出 boot0/boot1
```

所以 rootfs 镜像里**故意不写 `/etc/fstab` 的 `/` 条目**——两份镜像 LABEL 相同，
写死设备名或 LABEL 都会在"SD 和 eMMC 同时存在"时选错。

Debian 起来、SSH 通了，再从卡上系统把 img `dd` 到 eMMC 的 rootfs 分区（注意先
`umount` 不相关的东西、`dd` 时 `bs=1M` 别加 `conv=fsync` 以外的东西）：

```sh
# 在 SD 上的 Debian 里，向 eMMC 的 rootfs 分区写入同一份镜像
gunzip -c /root/debian-armhf-rootfs.img.gz | dd of=/dev/mmcblk0p9 bs=1M conv=fsync status=progress
sync
```

然后串口把 bootargs 改回 `root=/dev/mmcblk0p9`，拔卡重启。**全程不动 eMMC 直到这一步，
失败了拔卡就回到原系统。**

**B. 网络刷（没有卡时）** — 需要一个内核内置 initramfs 的"刷机内核"：起机后自己
从 PC 拉 img 写进 p9。比 A 多一次构建，但完全不需要额外硬件。

### 6.3 起来之后补 XFCE

**在板子上直接装，不要在 CI 里预装。** qemu 下跑几百个 postinst 又慢又容易挂在
`update-initramfs`、`fontconfig` 这类地方；板子上原生 apt 只要几分钟：

```sh
apt update
apt install xfce4 xserver-xorg-video-modesetting lightdm
systemctl set-default graphical.target
```

三条硬注意：

1. **必须 armhf（ARMv7 hard-float）**，不是 armel、不是 aarch64。
2. 板级 DTS 里 `media_cma` 固定占 **160 MB**，512M 版的机器留给桌面会很紧。
3. 装之前先把根分区撑满——镜像默认 4 GB，而分区是整个盘剩余空间：
   `resize2fs $(findmnt -no SOURCE /)`

---

## 7. 起来之后先验这几条

```bash
dmesg | grep -iE "histb|vdp|sii9134|lima|pl08x|festa|aiao"
cat /proc/device-tree/model                      # Huawei EC6108V9C
ls /sys/class/drm/                               # card0-HDMI-A-1
modetest -M histb                                # 看 CRTC/plane/格式（只有 XRGB8888）
cat /sys/bus/amba/devices/*/id                   # dmac 应为 0a141080
ls /sys/class/dma/                               # dma0chan0-3 + dma1chan0-15
aplay -l                                         # AIAO 声卡
v4l2-ctl --list-formats-out -d /dev/video0       # NV21_16L16（16x16 tiled）
es2_info; kmscube                                # lima 是否真的活
```

---

## 常见坑

| 现象 | 原因 |
|---|---|
| 起来后没有任何输出 | `CMDLINE` / `CMDLINE_EXTEND` 没开，或没拼 dtb（`ARM_APPENDED_DTB`） |
| 卡在 "Starting kernel..." | uImage 的 load 地址不对，这块板子必须 `0x02000000`（见第 4 节） |
| 网口不通 | 缺 `festa.<id>.ucode` 固件，PHY 只跑 bootloader 留给它的码（不致命，但可能不稳） |
| 串口有日志但屏幕全黑 | 八成是 `DRM_SII9134` 没编进去（不是 `DRM_HISTB_HDMI`，那个只给 mv200） |
| 起来后没有 `/dev/mmcblk0p9` | `blkdevparts` 没传进去，检查 `bootargs` 或 ATAGS 是否被合入 dtb |
| `=m` 的驱动不加载 | initramfs 里没 modprobe，全部改成 =y |
| 编译报 `bc: command not found` / `openssl` 错 | 依赖没装全，回到第 0 节 |
