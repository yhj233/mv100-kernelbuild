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

### ⚠️ eMMC 上没有 MBR 分区表

这是这条路上最容易被忽略的一条。原厂 eMMC 的 0 偏移就是 uboot 引导代码（`19 08 00 ea …`，
尾部没有 `55 AA`），**分区全靠厂商内核的 `blkdevparts=` 参数凭空造出来**。主线内核不认这个参数，
`block/partitions/` 里也没有他的补丁，DTS 里也没有 `partitions` 节点。

所以在新内核眼里 eMMC 只有一整块 `/dev/mmcblk0`，**没有 `mmcblk0p1…p9`**。
`root=/dev/mmcblk0p9` 在新内核下会直接 "VFS: Unable to mount root fs"。

两条出路：

1. **短期（零重编）**：Debian 住在 SD 卡上，`root=UUID=<SD卡>`，eMMC 原系统不动；
2. **长期（要重编 dtb）**：给 `&emmc` 加 `fixed-partitions` 子节点，把厂商那套布局写进 DTS，
   之后 `mmcblk0p9` 就有了，`root=/dev/mmcblk0p9` 原样有效。见 §6.2。

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

#### 路线 B：Debian 落到 eMMC（长期方案，要重编 dtb）

要在 eMMC 上跑，必须先解决 §5 里那个"新内核看不到分区"的问题。两种改法：

**B1. 给 DTS 加 fixed-partitions（推荐）**

在原厂布局的 `&emmc` 节点里补上分区表，`root=/dev/mmcblk0p9` 就原样有效了：

```dts
&emmc {
	partitions {
		compatible = "fixed-partitions";
		#address-cells = <1>;
		#size-cells = <1>;

		partition@0 {
			label = "boot";
			reg = <0x00000000 0x00100000>;	/* p1  1 MB   uboot，只读别动 */
			read-only;
		};
		partition@100000 {
			label = "bootargs";
			reg = <0x00100000 0x00100000>;	/* p2  1 MB */
		};
		partition@200000 {
			label = "baseparam";
			reg = <0x00200000 0x00400000>;	/* p3  4 MB */
		};
		partition@600000 {
			label = "pqparam";
			reg = <0x00600000 0x00400000>;	/* p4  4 MB */
		};
		partition@a00000 {
			label = "logo";
			reg = <0x00a00000 0x00400000>;	/* p5  4 MB */
		};
		partition@e00000 {
			label = "kernel";
			reg = <0x00e00000 0x01400000>;	/* p6 20 MB */
		};
		partition@2200000 {
			label = "busybox";
			reg = <0x02200000 0x04000000>;	/* p7 64 MB */
		};
		partition@6200000 {
			label = "backup";
			reg = <0x06200000 0x20000000>;	/* p8 512 MB */
		};
		partition@26200000 {
			label = "rootfs";
			reg = <0x26200000 0x1d9e00000>;	/* p9 610 MB 起，到盘尾 */
		};
	};
};
```

⚠️ 改这一段的时候有三个坑：

1. **必须原样保留 9 个分区**，编号才对得上。少写一个（比如把 `baseparam` 和 `pqparam`
   并成一段），后面全部前移，`p9` 就变成 `p8`，`root=` 立刻失效。
2. **第一个分区必须从 `0` 开始**（内核 ofpart 解析器对首分区偏移有要求），所以 `boot`
   那段留着占位并标 `read-only`，别让任何东西往它写——那 1 MB 就是 uboot 本体。
3. **`rootfs` 长度要按实际 eMMC 容量算**：

   | eMMC | p9 长度 | DTS 里写 |
   |---|---|---|
   | 4 GB | 3486 MB | `0x0d9e00000` |
   | 8 GB | 7582 MB | `0x1d9e00000` |
   | 16 GB | 15774 MB | `0x3d9e00000` |

   先 SSH 进去 `cat /proc/partitions` 看 `mmcblk0` 的总扇区数（×512 就是字节数）再定。
   **如果是 4 GB 的机器，p9 只有 3.4 GB，装不下 4 GB 镜像**，rootfs 要改用 `IMGSIZE=2G`
   重跑一次 workflow。

**B2. 在 SD 卡上起 Debian，再从那儿覆写 p9**

`install-rootfs.sh` 就是干这个的：它在 SD 卡启动的 Debian 里跑，
自动认出 eMMC（靠 `boot0` 判断）、检查 p9 够不够大、`gunzip | dd` 写进去、
回读 superblock 校验、`resize2fs` 撑满、最后 `tune2fs -U random` 打散 UUID
（避免和 SD 卡上那份撞车）。

```sh
# SD 卡启动的 Debian 里
scp root@PC:/path/debian-armhf-rootfs.img.gz /root/     # 或用 U 盘、或先传到老系统
sh install-rootfs.sh /root/debian-armhf-rootfs.img.gz
poweroff        # 拔卡，开机
```

**注意**：这条只有在 B1 也做了、`mmcblk0p9` 真的存在之后才有意义。否则写进去的东西
新内核根本看不见。

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
