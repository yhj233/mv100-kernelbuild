# mesa — lima 驱动的自建版本

设备上的 `/usr/lib/arm-linux-gnueabihf/dri/lima_dri.so` 来自
`libgl1-mesa-dri 21.2.6-0ubuntu0.1~20.04.2`（Ubuntu 20.04 armhf）。这里从
Mesa 21.2.6 源码重新编译同一份驱动，替换掉它。

## 为什么

`lima_pp` 的内核补丁（`../patches/drivers/gpu/drm/lima/`）已经把 DLBU 路径的
几个内核 bug 修好了，但 **DLBU 本身在这颗 Mali450 上就是坏的**：实测一个
16×32 的 surface 走 DLBU 就能把 PP 卡死（`PP_STATUS` = `RENDERING_ACTIVE|bit2`，
不报 `END_OF_FRAME`，之后 `BUS_STOPPED` 永不回来）。而同样 3600 个 tile 走
PP stream 一次 HANG 都没有。

Mesa 里这条岔路只有一处：

```c
/* src/gallium/drivers/lima/lima_job.c */
if ((screen->gpu_type == DRM_LIMA_PARAM_GPU_ID_MALI400) ||
    (damage && damage->region) || !lima_damage_fullscreen(job))
   lima_update_damage_pp_stream(job);      /* PP stream，2 个 PP 按 Hilbert 顺序交错分配 tile */
else
   ctx->pp_stream.map = NULL;              /* Mali450 全屏 -> DLBU */
```

补丁 `patches/0001-lima-always-use-pp-stream.patch` 让全屏也走 PP stream，
用环境变量 `LIMA_FORCE_PP_STREAM=1` 开启，这样同一份 `.so` 可以做 A/B 对比。

## 构建

`.github/workflows/mesa.yml` 在 **Ubuntu 20.04 armhf 容器（qemu-user 模拟）**
里编译。用容器而不是交叉工具链，是因为只需要 `lima_dri.so` 这一个文件直接
覆盖到设备上：同版本容器编译出来的 `.so`，GLIBC / GLIBCXX 符号版本、
libdrm / libglapi 的 ABI 和发行版包完全一致。在 24.04 runner 上交叉编译会
引入 `GLIBC_2.38+` 符号，focal 加载不了。

只编 `src/gallium/targets/dri/lima_dri.so` 一个 target，关掉 llvm / vulkan /
egl / gbm / 其他 gallium 驱动。

产物：artifact `lima_dri`，含 `lima_dri.so` / `sha256.txt` / `info.txt`
（记录最大 GLIBC 符号版本，必须 ≤ 2.31）。

## 装到设备

```sh
# 备份原版
cp -a /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so \
      /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so.orig
# 换成新编的
cp lima_dri.so /usr/lib/arm-linux-gnueabihf/dri/lima_dri.so

# A/B 对比
LIMA_FORCE_PP_STREAM=0 ...   # 原行为（全屏走 DLBU）
LIMA_FORCE_PP_STREAM=1 ...   # 全屏也走 PP stream
```

回滚：`cp -a .../lima_dri.so.orig .../lima_dri.so`。

## 验证要点

- `glxinfo | grep renderer` 必须还是 `Mali450`（加载失败会静默退回 llvmpipe）
- `dmesg | grep -c 'job timeout'` / `'error irq'` / `'HANG irq='`
- 全屏 glxgears / Xorg glamor 合成时不再出现 `HANG irq=4`
