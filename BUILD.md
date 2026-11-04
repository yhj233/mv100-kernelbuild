# Hi3798MV100（EC6108V9C）内核编译指南

基于 `histb-mainline/linux` 的 `histb` 分支（基线 Linux 7.3-rc7，ARM32）。
本文所有配置项都对应树里真实存在的 Kconfig 符号。

---

## 当前状态（2026-10-31 15:45）

板上已经做完了前两步，**只差重启**：

| 项 | 状态 |
|---|---|
| p6 kernel | ✅ 已写入 7.3 内核（12.17 MB，CI run #5，`sha256 0f072aaf…`），回读校验一致 |
| p2 bootargs | ✅ `bootdelay` 0 → 3，其余 17 个变量逐字节未动，CRC 重算并校验通过 |
| 原内核备份 | ✅ 设备 `/root/kernel-backup/p6-kernel-orig.img` + PC `artifacts/p6-kernel-orig.img`，两处 sha256 一致（`a0bcc792…`） |
| 原 bootargs 备份 | ✅ 设备 `/root/kernel-backup/p2-bootargs-orig.bin` + PC `artifacts/p2-bootargs-orig.bin` |
| 回滚脚本 | ✅ 设备 `/root/kernel-backup/rollback.sh` |
| 重启 | ⬜ 未做，等人在串口前 |

**当前系统仍在跑内存里的 4.4.35**，写入没有影响运行中的系统（已核对根分区可写、uptime 连续）。

⚠️ **下次开机就会用 7.3**。如果这段时间断电重启，而新内核起不来，SSH 会一起消失，
只剩串口和 HiTool 两条路。`bootdelay=3` 给了 3 秒进 U-Boot 的窗口。

新内核 config 自检 37 项全绿，`=m` 929 个（uImage 不带模块，需要的东西都内建了）。

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

### 5.0 推荐路线：SSH 改两个分区，不用 tftp

板子已经能 SSH 进去的话，**根本不需要串口和网络引导**。原理是把两个东西写进 eMMC：

| 分区 | 大小 | 写什么 |
|---|---|---|
| `/dev/mmcblk0p6` | 20 MB | 新内核 `uImage-mv100.img` |
| `/dev/mmcblk0p2` | 1 MB | 改过 `root=` 的启动参数 `bootargs-sd.bin` |

原厂 `bootdelay=0` 看起来没法进 uboot 命令行，但 **`bootargs` 分区是纯文本 + CRC32 的简单格式**，
可以在 PC 上离线改好再写回去，uboot 开机自己会读：

```
偏移 0x00：4 字节 = crc32(其余全部内容) 的小端值
偏移 0x04：NUL 分隔的 key=value 字符串
```

改完重算 CRC 即可。`artifacts/bootargs-stock.bin` 是原厂原样复原件（md5 与固件包一致），
证明生成器正确。顺带把 `bootdelay` 从 0 改成 3，以后开机有 3 秒窗口能按 Ctrl+C 进 `fastboot#`。

流程：

```bash
# PC -> 盒子
scp artifacts/uImage-mv100.img artifacts/bootargs-sd.bin \
    switch-to-sd.sh install-rootfs.sh root@盒子IP:/root/
# 盒子本机
ssh root@盒子IP 'sh /root/switch-to-sd.sh'
reboot
```

`switch-to-sd.sh` 会先备份 `p6`(内核)、`p2`(启动参数)、盘头 64 扇区到 `/root/kernel-backup/`，
再写、再回读比对 sha256。**这三个备份务必 scp 拉回 PC 一份。**

回滚（任何时刻）：

```sh
dd if=/root/kernel-backup/kernel-old.img   of=/dev/mmcblk0p6 bs=1M
dd if=/root/kernel-backup/bootargs-old.bin of=/dev/mmcblk0p2 bs=1M
reboot
```

### eMMC 上没有 MBR，但 `blkdevparts=` 是上游支持的

原厂 eMMC 的 0 偏移就是 uboot 引导代码（`19 08 00 ea …`，尾部没有 `55 AA`），
**没有 MBR/GPT 分区表**，九个分区是 `bootargs` 里的 `blkdevparts=` 凭空造出来的。

早先这里写的是"主线内核不认这个参数、必须改 DTS 加 fixed-partitions"——**那是错的**。
`blkdevparts=` 是 2013 年就进了上游的东西，实现就在 `block/partitions/cmdline.c`：

```
__setup("blkdevparts=", cmdline_parts_setup);
```

对应 `CONFIG_CMDLINE_PARTITION`，`multi_v7_defconfig` 里本来就是 `=y`，`build.sh` 也把它
钉进了配置自检门（37 项之一）。所以**现有 bootargs 原样传下去，`mmcblk0p1…p9` 就会正常出现**，
`root=/dev/mmcblk0p9` 直接有效，DTS 一个字不用改。

唯一要记住的是：这个选项一旦没开（比如换了 defconfig），p9 就会消失，而现象只是
"VFS: Unable to mount root fs"，很容易误判成驱动问题。这就是它被写进自检门的原因。

> 顺带纠一个更早的猜测：eMMC 是 `mmcblk0`（dtsi 里 `emmc@9830000` 在 `sd@9820000` 之前，
> 且标了 `non-removable`），SD 卡是 `mmcblk1`，和原厂 `root=/dev/mmcblk0p9` 一致。

### 5.1 没有 SSH 时：内存引导（需要 tftp）

串口 115200 连上，开机打断进 `fastboot#`（`bootdelay=0`，需要在串口里一直发 Ctrl+C 抢）。
确认命令能用：`help`、`printenv`。板子出厂没编 `ext4load`，只有 `fatload`/`usb start`/`loady`，
所以没法直接从 eMMC 的 ext4 分区里读文件，只能用网络或 USB。

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
- 上面这串 `bootargs` 就是从你固件包的 `bootargs9-32.bin` 里抄的原厂值。
- 断电重启即恢复原厂内核，这一步不动 eMMC，随便试。
- 换成 U 盘也行（uboot 有 `usb start` + `fatload`）：把 uImage 放在 FAT32 盘上，
  `usb start; fatload usb 0:1 0x42000000 uImage-mv100.img; bootimg 0x42000000`。

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

### 5.4 只换内核、不动 rootfs（install-kernel.sh）

如果只想先验内核、rootfs 保持原厂 Ubuntu，用 `install-kernel.sh`，它只动 `p6`：

```sh
scp uImage-mv100.img root@盒子IP:/root/
ssh root@盒子IP 'sh /root/install-kernel.sh /root/uImage-mv100.img'
```

校验 uImage magic → 检查是否放得下 20 MB 分区 → 备份原内核到
`/root/kernel-backup/kernel-old.img` → 写入 → **回读比对 sha256**。
`restore-kernel.sh` 负责回滚。

⚠️ 但**只换内核的话大概率看不到东西**：原厂 rootfs 在 `mmcblk0p9`，
而新内核没有分区表（见上面那段），`root=` 会失效。所以这条路只适合
"我在别处已经解决分区问题"的情况，日常请走 5.0。

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
（uboot 里的 USB 是另一套驱动，能用，但那只帮得上引导，帮不上挂根分区。）

#### 先搞清 mmcblk 编号

dtsi 里 `emmc@9830000` 写在 `sd@9820000` 之前，作者也在注释里写死了
`/* unremovable emmc as mmcblk0 */`。所以**插着卡时**：

| 设备 | 节点名 |
|---|---|
| eMMC | `/dev/mmcblk0` |
| SD 卡 | `/dev/mmcblk1` |

想自己确认：eMMC 会多出 `boot0`/`boot1` 硬件分区。

```sh
for d in /sys/block/mmcblk*; do [ -e "$d/boot0" ] && echo "eMMC = /dev/$(basename $d)"; done
```

#### 路线 A：Debian 住 SD 卡（零重编，今天就能跑）

`&sd` 是 okay，走 `snps,dw-mshc`（`MMC_DW_PLTFM=y` 覆盖），卡检测走控制器内部的 CDETECT。

1. **PC 写卡**：Win32DiskImager 把 `artifacts/debian-armhf-rootfs.img`（4 GB，裸 ext4）
   写进卡。写的是**裸文件系统，没有分区表**，所以卡上 `/` 就是 `/dev/mmcblk1` 本身，
   没有 `p1`。Windows 会弹"需要格式化"——别理它，那是它读不懂 ext4。
2. **改启动参数**：`artifacts/bootargs-sd.bin` 已经把 `root=` 换成
   `root=UUID=0052686e-5a26-48f6-b2d2-eafdf1477d17`（就是镜像里那个 UUID）。
   用 UUID 而不是 `/dev/mmcblk1` 是为了不依赖枚举顺序——eMMC 整盘在偏移 1024 处
   没有 ext4 超级块，不会被误匹配。
3. **写进去再重启**：`sh switch-to-sd.sh`（见 §5.0），reboot。

起来之后先撑满卡：

```sh
resize2fs /dev/mmcblk1        # 卡多大就撑多大
```

#### 路线 B：Debian 落到 eMMC（长期方案）

`blkdevparts=` 是上游解析器（见 §5 那段），所以**不需要改 DTS**，`mmcblk0p9` 在新内核下
本来就会出现。剩下的问题只是"怎么往一个正在被当作根分区的分区里写东西"——你没法在线覆盖它，
必须从另一个系统写。

两条：

**B1. 从 SD 卡上的系统写（推荐）**

先按路线 A 让 Debian 从卡起来，然后：

```sh
# 卡上系统里跑
scp root@PC:/path/debian-armhf-rootfs.img.gz /root/
sh install-rootfs.sh /root/debian-armhf-rootfs.img.gz
```

`install-rootfs.sh` 会自动认出 eMMC（靠 `boot0` 判断，别靠编号猜）、检查 p9 容量、
`gunzip | dd` 写进去、回读 superblock 校验、`resize2fs` 撑满、最后 `tune2fs -U random`
换掉 UUID（避免和卡上那份撞车）。

p9 有 **6.53 GiB**（实测 `Block count 1711616 × 4096`），4 GB 镜像装得下，撑满后能用 6.5 G。

**B2. 从原厂 Ubuntu 里"借"一个临时根**——不推荐，要 remount 根分区为只读、
往另一个 mount namespace 里写，比 B1 危险得多。

> 之前这里写的是"给 `&emmc` 加 fixed-partitions、重编 dtb"，那是基于"主线不认 blkdevparts"
> 的错误判断。现在不需要了。

#### 路线 C：网络刷（没有卡时）

需要一个内核内置 initramfs 的"刷机内核"：起机后自己从 PC 拉 img 写进 p9。
比 A/B 多一次构建，但完全不需要额外硬件。

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

**前三条决定"能不能活"，先看它们，别的都是后话：**

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E "root=|blkdevparts"   # root= 要指向 mmcblk0p9
lsblk                                                          # p1..p9 在不在（CMDLINE_PARTITION）
cat /sys/block/mmcblk0/device/name                             # 应为 M72808
```

**然后是驱动：**

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

**如果网口没起来**（`ip link` 里没有 eth0，或一直 NO-CARRIER）：主线用的是 FEMAC 而不是
vendor 的 `hieth`，且 PHY 的 microcode 固件 `festa.<id>.ucode` 不在系统里。这时只能串口操作。
先 `dmesg | grep -i femac` 看 probe 到哪一步。

**如果 `lsblk` 里没有 p1..p9**：说明 `CMDLINE_PARTITION` 没生效或 `blkdevparts=` 没传进来。
内核会报 `VFS: Cannot open root device`。这是唯一一个"内核启动了但进不了系统"的典型症状。

---

## 回滚（板上现成的）

```sh
sh /root/kernel-backup/rollback.sh    # p6 → 原厂 4.4.35，p2 → bootdelay=0
reboot
```

只能在这个系统能登录时用。如果新内核根本起不来（没 SSH），走 §5.3：串口 U-Boot 或 HiTool。

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
