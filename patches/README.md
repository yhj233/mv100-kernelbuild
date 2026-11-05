# patches/

这里放**已改好的整份源文件**，`build.sh` 在 `do_config` 开头按相对路径覆盖进内核源码树
（`patches/a/b/c.c` → `$SRC/a/b/c.c`）。用整份文件而不是 diff，是因为上游 `histb` 分支
一直在动，diff 很快就会对不上；这几处改动本身很小，整份替换更抗上游变化。

改完之后请把同一份文件同步到 `_src/`，那里是给人看的副本。

## histb-vdp2.c —— 修 vblank 从不使能（关键）

**症状**：Xorg 的 glamor 初始化要 30 秒，之后任何走 GPU 合成的路径（glamor 合成、
Mesa DRI3 present、kmsro 的 buffer 提交）都会卡在 libdrm 的 `usleep(20)` 轮询里；
`glmark2` desktop 场景 0 FPS；`lima_bench` 直接挂死。

**证据**：

```
histb-vdp2 f8cc0000.display: vbcount=1245 all=0x00000001 sta=0x00000000
                             msk=0xffffffff vblanks=1246      ← 每 5 秒，两个数都不动
```

`INTMSK` 一直是 `0xffffffff`（全屏蔽），所以 `sta = INTSTA & ~INTMSK = 0`，
`drm_crtc_handle_vblank()` 从来没执行过，DRM 的 vblank 计数死在 1246。

**原因**：probe 时 `vo_write(vdp, VO_INTMSK, ~0u)` 全屏蔽，注释假设
"`drm_crtc_vblank_on()` unmasks VTTHD1 later"，但这是错的 —— `vblank_on()` 只把 CRTC
标记成"支持 vblank"，硬件中断要等 `drm_crtc_vblank_get()` 把引用计数从 0 抬到 1 时
才由 `enable_vblank` 回调打开。而本驱动的 flip 事件是在 `atomic_flush()` 里**同步直接发**
的（`drm_crtc_send_vblank_event`），没有任何人需要 `WAIT_VBLANK`，于是引用计数永远是 0。

**修法**：CRTC 使能期间由驱动自己持有一个 vblank 引用。

```c
/* histb_vdp2_crtc_atomic_enable() 末尾 */
drm_crtc_vblank_on(crtc);
drm_crtc_vblank_get(crtc);      /* 新增：真正打开 VTTHD1 并使能 DRM 计数 */

/* histb_vdp2_crtc_atomic_disable() 开头 */
drm_crtc_vblank_put(crtc);      /* 新增：与上面配对，必须在 vblank_off 之前 */
drm_crtc_vblank_off(crtc);
```

`put` 必须放在 `drm_crtc_vblank_off()` 之前，否则 `drm_vblank_off()` 会警告引用计数非 0。

**验证**：直接改寄存器 `INTMSK` 清 bit0 后，`vbcount` 立刻按 60 Hz 增长
（5 秒 +300），确认硬件与中断链路本身没问题，纯粹是没使能。

## histb-vdp2.c —— flip 事件改走 vblank 队列（重复 MSC）

**症状**：vblank 修好之后，客户端日志开始刷

```
Got the same msc value twice ... Possibly broken driver/interlaced mode?
```

**原因**：`atomic_flush()` 里直接调 `drm_crtc_send_vblank_event()`。这个函数用
`drm_vblank_count_and_time()` 取序号，也就是**最近一次已经处理过的** vblank 计数
（`drm_vblank.c`：`seq = drm_vblank_count_and_time(dev, pipe, &now)`）。两次 commit
如果落在同一个 vblank 周期内，两个事件就带着**完全相同的 seq** 发出去。任何把 seq
当帧计数器用的客户端（mpv 的 `--vo=gpu`）都会把第二个判成重复 flip。

原来的注释写的是"VDP 整帧锁存，所以提交后立刻发事件"。前半句对，后半句错的：
锁存说的是像素生效时机，和事件该带哪个序号是两件事。

**修法**：改成 arm，让事件等下一个 vblank 由中断里发。

```c
if (new_state->event) {
	struct drm_pending_vblank_event *event = new_state->event;

	new_state->event = NULL;	/* 必须：hw_done 有 WARN_ON(event) */

	spin_lock_irq(&crtc->dev->event_lock);
	if (drm_crtc_vblank_get(crtc) == 0)
		drm_crtc_arm_vblank_event(crtc, event);
	else
		drm_crtc_send_vblank_event(crtc, event);   /* vblank 不可用时的兜底 */
	spin_unlock_irq(&crtc->dev->event_lock);
}
```

三个约束都是查 `drm_vblank.c` / `drm_atomic_helper.c` 确认的，不是照抄：

- `drm_crtc_arm_vblank_event()` 只是把事件挂到 `dev->vblank_event_list` 并置
  `sequence = accurate_vblank_count() + 1`，**它自己不做 vblank_get**。
- 消费方 `drm_handle_vblank_events()` 在发事件前会 `drm_vblank_put(dev, pipe)`，
  所以 arm 之前必须自己 `drm_crtc_vblank_get()`，否则引用计数被 put 穿。
- `drm_atomic_helper_commit_hw_done()` 里有 `WARN_ON(new_crtc_state->event)`，
  所以 `new_state->event` 必须在 flush 里清掉。
- `drm_crtc_vblank_get()` 走 `vbl_lock`，不碰 `event_lock`，在 `event_lock` 内调用
  不会自死锁（sun4i 也是这么写的）。

**验证**：连续 3 轮 mpv 启动（每次启动都要做模式设置 + 首帧提交，最容易触发），
`Got the same msc` 从**每轮 1 次降到 0 次**，`drop=0`、`vfps=30.000` 不变。
同时 vdp2 自己的探针显示 `vbcount` 5 秒 +300、`vblanks` 同步推进，说明 vblank
计数是活的，不是"事件不发所以不重复"。

## 不要给 Xorg 开 kmsro 覆盖（实测慢 10 倍，已回退）

Xorg 日志里一直有这两行：

```
(II) modeset(0): Refusing to try glamor on llvmpipe
(EE) modeset(0): glamor initialization failed
```

原因是 Mesa 只给 llvmpipe：`histb-vdp2` 不在它的 kmsro 静态映射表里，Mesa 就
认为 card0 没有 3D 能力。modeset 驱动看到 llvmpipe，主动拒绝开 glamor。

**看起来有救**：给 X server 注入 `MESA_LOADER_DRIVER_OVERRIDE=sun4i-drm`
（lightdm 会清掉自己的环境，所以要包一层 `xserver-command` wrapper），glamor
**确实能起来**：

```
(II) modeset(0): glamor X acceleration enabled on Mali450
(II) modeset(0): glamor initialized
```

**但是整个桌面会慢 10 倍**：

| | 桌面 glxgears |
|---|---|
| 不覆盖（llvmpipe） | **127–129 FPS** |
| 覆盖（glamor on Mali450） | **10.4 FPS** |

同期 `lima: pp error irq state=201 status=40` 暴涨到 100+ 条，并且出现
`job timeout` 4 次、`bus stop` 6 次——**lima 在 glamor 的合成负载下会卡住**，
GPU 一旦 bus stop，上屏就阻塞，所有客户端一起卡。

即使在 GPU 路径下 glxgears 显示 60.0 FPS（vsync 锁），那也只是"看起来正常"，
真正跑起来 12 秒只有 127 帧。

**结论：保持 llvmpipe。** 桌面慢是确定的，但至少稳定在 129 FPS；
换成 glamor 是"初始化成功、实际不可用"。相关配置已全部删除：

- `/usr/local/bin/Xorg-kmsro`（wrapper）
- `/etc/lightdm/lightdm.conf.d/60-kmsro.conf`（xserver-command）
- `/etc/X11/Xsession.d/90-kmsro`（客户端全局覆盖）

### 顺带：lima 只有 GL 2.1，wiliwili 用不了

| 渲染器 | OpenGL 版本 | wiliwili |
|---|---|---|
| lima / Mali450 | **2.1** | 启动即崩（`glfw: Failed to create window`） |
| llvmpipe | **3.1** | 正常 |

wiliwili 用的 GLFW 要 3.x，lima 只到 2.1，这是**硬限制**，不是配置问题。
所以千万别把 `MESA_LOADER_DRIVER_OVERRIDE` 放到用户会话里——那样 wiliwili
直接起不来。（mpv 能用是因为 `--vo=gpu` 只需要 GLES2/GL2。）


disable 路径不会漏事件：`drm_crtc_vblank_off()` 会遍历 `vblank_event_list`，
逐个 `list_del` + `drm_vblank_put` + `send_vblank_event`，挂起的事件会被冲掉。

## 顺带

- `histb-vdp2.c` 里那段 5 秒一次的 `vbcount=` 打印是 bring-up 用的探针
  （`histb_vdp2_irq_handler()` 末尾，标了 `[LOCAL]`）。**暂时保留**：它是判断
  vblank 是否真的在推进的唯一直接证据，而 vblank 是本驱动全部问题的源头。
  等整条链路稳定几轮再删。
- Mesa 侧 kmsro 认驱动名靠的是 **编译期静态映射**，`histb-vdp2` 不在表里。
  两种绕法等价，后者更省事（不用编译 .so、不用 LD_PRELOAD）：
  - `_deploy/fake-drm-name/` 的 `libfake_drm_name.so`，把 card0 报的名字改成 `sun4i-drm`
  - 或者直接 `MESA_LOADER_DRIVER_OVERRIDE=sun4i-drm`（**推荐**，已实测等效）

## lima_pp.c —— 已删除

原来是 PP 报错时的现场 dump 补丁，用来查 `job timeout`。结论是**那次排查的
方向错了**，补丁只剩日志噪音，已经从 `patches/` 删掉（`build.sh` 不再覆盖，
`lima_pp.c` 回到上游原样）。这一段留作复盘，见下面"已被证伪的一轮"。

## lima_pp.c 复盘 —— PP 出错时 dump 现场（**已被证伪**）

> 这一节记录的是**已经被证伪**的一轮排查，留在这里是因为下面"运维经验"那几条
> 踩坑成本很高。**不要再按这里的思路继续挖 PP**。当前有效结论见本节末尾。

**当初的症状**：X/glamor 走 lima(kmsro) 时一启动就刷

```
pp0/pp1 error irq state=201 status=40
pp0/pp1 task error int_state=0 status=0
pp0/pp1 job timeout
pp0/pp1 bus stop timeout
```

**曾经的错误推断**：`state=0x201` 被拆成 `END_OF_FRAME | INVALID_PLIST_COMMAND`、
`status=0x40` 被当成 `BUS_ERROR`，于是推论"PP 读了不该读的地址"，进而怀疑
26x32 的小 pixmap 是 X 光标、怀疑 `fragment_stack_address=0` 是根因。
（顺带确认了 `struct lima_pp_frame_reg` 的字段顺序：
`[10]=width [11]=height [12]=fragment_stack_address [13]=fragment_stack_size
[17]=supersampled_height`；以及 `lima_job.c:971` 只在 `pp_max_stack_size` 非 0 时
才建 stack BO，否则这两个字段就是 0——`lima_job.c:874` 写的是
`size << 16 | size`。）

**推翻它的证据**：把 dmesg 拉成时间线数了一遍——

```
job timeout            1 次
pp error irq state=201 36 次     ← 全部落在 lima_pp_hard_reset() 之后 ~1.4ms
```

首个 error IRQ 在 timeout **之后** 1.4ms 才出现，且 `lima_pp_task_error()` 里读到的
`int_state=0 status=0`（寄存器已被复位清空）。**36 次全是 FORCE_RESET 复位动作
自身的副产物，不是故障现场。** 真正的事件只有那 1 次 `job timeout`：PP 卡在
`RENDERING_ACTIVE` 不再前进，之后 driver 反复 reset，每次 reset 都刷一条
`state=201`。

**现在的结论**：

1. **lima 的 3D/视频通路本身是好的**。用真实素材验证过：

   ```
   mpv --vo=gpu --gpu-context=drm --ao=null --drm-atomic=no /home/ubuntu/t720.mp4
   GL_VENDOR=lima  GL_RENDERER=Mali450
   frame-drop-count = 0        （30 秒 720p30 H.264 + AAC，pos 3.2 → 33.2 线性推进）
   pp error irq     = 0 次
   ```

   所以"lima 在这颗 SoC 上不能用"是错的，PP 超时是**特定场景**才触发。

2. **PP 超时只在 X/glamor 场景出现**。桌面（llvmpipe）正常，DRM 直出（lima）正常，
   唯独 Xorg 挂上 glamor 后走 kmsro 就卡死。第一因还没定位，但排查面已经从
   "lima 驱动整体" 收窄到 "glamor + kmsro 的提交序列"。

3. **这个补丁到此为止**。它 dump 的东西（PP 硬件寄存器、task 描述符、VA 反查）
   在"复位后噪声"这个前提下没有信息量。定位完成后应从 `patches/` 删掉，
   build.sh 不再覆盖即可恢复原版。

**这一版（v5）改了什么**：只修了输出格式。v3/v4 用 `dev_err()` 打半行 + `pr_cont()`
续行，实测在 printk 的 `KERN_CONT` 合并路径上被其它输出打断，dump 出来只有
`reg[00]:` 后面没有数值。改成 `snprintf` 拼整行再 `dev_err("%s\n", line)`。

**运维经验（这轮最值钱的部分）**：

- **`--vo=drm` 不走 GPU**。mpv 0.32 的 `vo=drm` 是老式 legacy modesetting +
  CPU swscale 直写 framebuffer，日志里是 `Using Legacy Modesetting` 和
  `swscaler ... using C`。要走 Mali 必须 `--vo=gpu --gpu-context=drm`。
  `bili --drm` 之所以流畅，是因为它**完全绕开了渲染**，不是因为 GPU 好用。
- **`--drm-atomic=no`** 可绕过 `Failed to commit atomic request (-22)`
  （vdp2 的 atomic commit 返回 EINVAL，非致命，drm.debug 里看不到拒绝点）。
- **测 fps 必须带音轨**。lavfi 的 `testsrc` 没音频，mpv 靠音频时钟同步，
  会报 11% 的假丢帧。用 ffmpeg 生成带 AAC 的 mp4 + `--ao=null` 才能拿到 drop=0。
- **`MESA_LOADER_DRIVER_OVERRIDE=sun4i-drm` 完全替代了 `libfake_drm_name.so`**。
  后者是 LD_PRELOAD 改 `drmGetVersion` 的返回值，前者是 Mesa 自带的加载器覆盖，
  更干净，也不影响其它进程。

## histb-vdp2.c 还剩一个 bug —— flush 阶段就发 vblank 事件

`histb_vdp2_crtc_atomic_flush()` 第 1450 行附近：

```c
if (new_state->event) {
    spin_lock_irq(&crtc->dev->event_lock);
    drm_crtc_send_vblank_event(crtc, new_state->event);   /* ← 问题在这 */
    new_state->event = NULL;
    spin_unlock_irq(&crtc->dev->event_lock);
}
```

`send_vblank_event()` 是**立即**把事件发出去，而此刻帧还没扫描出去。客户端（mpv）
拿到的事件时间戳/MSC 与真实 vblank 对不上，日志里就是：

```
Got the same msc value twice ... Possibly broken driver/interlaced mode?
```

应该改成 `drm_crtc_arm_vblank_event(crtc, new_state->event)`——排队到下一个
vblank 再发，这也是 atomic 驱动的标准写法。**尚未修改**，等 PP 那条线定了再一起动。
