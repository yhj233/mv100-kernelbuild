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

## lima_pp.c —— 曾经的 dump 补丁（已删除，现在换成真正的修复）

原来这里放的是 PP 报错时的现场 dump 补丁，用来查 `job timeout`。那一轮排查的
方向错了，补丁只剩日志噪音，从 `patches/` 删掉了一段时间。

**现在 `patches/drivers/gpu/drm/lima/lima_pp.c` 又回来了**，但内容完全不同：
是"M450 上 `pipe->task` 被重复递减"的真正修复，见上面那一节。

## lima_pp.c —— 真根因：per-PP handler 抢先把 END_OF_FRAME 清掉（**已修**）

### 怎么找到的

在 `lima_pp_bcast_irq_handler()` 的 `else` 分支（`state == 0` 且
`RENDERING_ACTIVE`）里加现场 dump，把状态抓在**卡死那一刻**而不是 10 秒后。
抓到的东西自相矛盾，而矛盾本身就是答案：

```
[stall] #0 pp=0 done=00000000 task=2 error=0
[stall] gp  status=00000000 rawstat=00080000        <- GP 完全空闲
[stall] pp0 status=00000040 rawstat=00000001 intstat=00000001 intmask=00000f19
[stall] pp1 status=00000040 rawstat=00000001 intstat=00000001 intmask=00000f19
[stall] dlbu fbdim=00010000 conf=20000000 tilepos=0000ffff enmask=00000003
[stall] tllist: 全零
```

- 能进这个分支的前提是 handler 读到 `PP_STATUS` 的 bit0（`RENDERING_ACTIVE`），
  可是 dump 里 `status = 0x40` —— **bit0 已经掉了**，PP 其实是空闲的
- `rawstat = 0x1` = END_OF_FRAME 仍然 pending，而 `intmask = 0xf19` 没屏蔽它
- 也就是说：**中断还在挂着，却被别人清过了**

清它的就是先注册的 `lima_pp_irq_handler()`（pp0/pp1 各一个，注册顺序在
pp_bcast 之前）。

### 机制

```
1. PP 渲染完，拉 END_OF_FRAME，共享 IRQ35 触发
2. lima_pp_irq_handler(pp0) 先跑：读到 state=1，lima_pp_handle_irq() 把
   INT_CLEAR 写掉
3. lima_pp_bcast_irq_handler() 接着跑：先读 status 仍是 ACTIVE（PP 还没掉位），
   再读 state 已经是 0 → 走 else → 认定"还在渲染" → continue
4. PP 随后自己掉 ACTIVE。END_OF_FRAME 已经被清，不会再产生中断
5. 这个 PP 永远不写进 pipe->done，pipe->task 停在 2
6. 干等 10s sched timeout → hard reset → PP 重新读到垃圾 plist →
   才冒出 state=201 INVALID_PLIST_COMMAND
```

**所以 `INVALID_PLIST_COMMAND` 一直是"后果"不是"原因"**，这也解释了三件事：
硬件全空闲却报超时、`error=0` 却走 timeout、以及为什么现象随机（取决于
PP 掉 ACTIVE 与两次寄存器读之间的竞态）。

### 修法

M450 上**只让 bcast handler 消费 PP 中断**：

- `lima_pp_irq_handler()` 在 `pipe->bcast_processor` 存在时直接 `IRQ_NONE`，
  连 `INT_STATUS` 都不读。M400 没有 bcast，保持原样。
- bcast handler 里 `PP_STATUS` 与 `PP_INT_STATUS` 背靠背读，pending 的
  END_OF_FRAME 必然压过陈旧的 `RENDERING_ACTIVE`。
- 因为现在是唯一清中断的人，两处补上 ack：
  - PP 已在 `pipe->done` 里但迟到的中断 → 清掉，否则共享线一直拉着；
  - `!pipe->current_task`（没有任务可记账）→ 遍历所有 PP 清掉残留。

另外两处**必须保留**的既有修复：

- 计数只在 bcast 里做（否则两 PP 任务在第一个完成时归零）；
- `pipe->error` 为真时不再因 `RENDERING_ACTIVE` 而跳过（否则每个错误白等 10s）。

## lima_pp.c —— 上一轮误判为根因的 bug：pipe->task 被重复递减（**真 bug，但不是根因**）

### 症状链（实测抓到的第一次失败）

```
[   42.654762] lima f9200000.gpu: pp0 error irq state=201 status=40
[   42.654824] lima f9200000.gpu: pp1 error irq state=201 status=40
[   42.654950] lima f9200000.gpu: [hang] sched task_count=-3 done=00000003 error=1
...
[   53.725898] lima f9200000.gpu: pp0 status=00000005 rawstat=00000004 intstat=00000000
```

- `state=0x201` = `END_OF_FRAME | INVALID_PLIST_COMMAND`
- `status=0x40` = bit6（PP 内部错误状态位，lima 没定义名字）
- **两个 PP 在 62µs 内报同一组状态** → 不是竞争，是同一帧的 plist 内容坏了
- `task_count=-3` 而 `done=0x3` → 这个任务的计数器被递减了 **5 次**，而
  `num_pp` 只有 2
- 之后 PP 进 `status=0x5`（`RENDERING_ACTIVE|BUS_STOPPED`）+ `rawstat=0x4`
  （`LIMA_PP_IRQ_HANG`，**不在 `IRQ_MASK_USED` 里，所以根本没有中断**）→
  调度器干等 10s 超时 → `STOP_BUS` 再也停不住 → 只能重启

### 根因

IRQ35 是共享的，pp0/pp1/pp_bcast **三个 handler 挂在同一条中断上**，
注册顺序（`enum lima_ip_id`）是 pp0 → pp1 → pp_bcast。

M450 上每个 PP 的完成中断会在同一次 IRQ 里被**两个 handler 各减一次**：

1. `lima_pp_irq_handler()`（pp0/pp1 各一个）读到 `INT_STATUS != 0` → `dec`
2. `lima_pp_bcast_irq_handler()` —— 此时状态已被上一步 `INT_CLEAR` 清掉，
   走 `else` 分支，PP 已不在 `RENDERING_ACTIVE` → `pipe->done |= 1<<i` → 再 `dec`

于是 `pipe->task = 2` 在**第一个 PP 完成时**就归零 →
`lima_sched_pipe_task_done()` → fence 提前 signal → 调度器立刻提交下一帧，
而第二个 PP 还在读上一帧的 plist。GP 为新帧重建 plist 堆，PP 读到的就是
垃圾 → `INVALID_PLIST_COMMAND`。

也解释了为什么**单客户端 60 FPS 稳定、两路负载几十秒必挂**：两个 PP 平时
几乎同时完成，提前一点看不出来；有负载时 PP1 会落后，落后就炸。

### 修法

**M450 上只让 bcast handler 记账。** 它本来就有 `pipe->done` 位图和
"轮询 `PP_STATUS` 判断完成"的兜底逻辑，是天然的所有者；per-PP handler
只负责 ack 中断。M400（无 bcast）保持原来的行为。

另外给 bcast 的 `dec` 加了 `atomic_read(&pipe->task) > 0` 的护栏，
防止迟到的完成中断把计数减成负数、从而让**下一个**任务被陈旧中断提前完成。

### 验证结果（run #21）：计数修好了，plist 错误**没修好**

刷 run #21 后同样的负载，超时 dump 从 `task_count=-3` 变成：

```
[hang] sched task_count=0 done=00000003 num_processor=2 error=1
```

计数完全对上了（2 个 PP，2 次 dec，落到 0）。**但第一个 PP 错误仍在 X 起来后
约 0.7s 出现**，形态还是 `state=201 status=40`
（`END_OF_FRAME | INVALID_PLIST_COMMAND`），124 次错误里 122 次都是它。

所以"提前完成导致 plist 被回收"这个因果链**不成立**，`INVALID_PLIST_COMMAND`
是独立的上游问题（看实测，是 Xorg glamor 的 2D 任务在报，而 glxgears 这种纯 3D
客户端几乎不报，且在 lima 上能跑到 106 FPS）。

这个补丁本身仍然是对上游的实质修复（重复递减/下溢是确凿的 bug），保留。

### 相关寄存器/结构事实

- `LIMA_PP_IRQ_MASK_USED = END_OF_FRAME | MASK_ERROR`，**不含 `HANG`(bit2)**
  → PP 真挂住时 `rawstat` 有 bit2 但 `intstat` 永远是 0，内核完全无感
- `enum lima_ip_id` 里有两个 bcast：`lima_ip_bcast`（`BROADCAST_MASK` 0x0 /
  `INTERRUPT_MASK` 0x4，控制哪些 PP 的中断汇入 bcast 线）和
  `lima_ip_pp_bcast`（PP 寄存器块 0x1000 段，做 soft reset 的载体）。
  `lima_pp_soft_reset_async()` 写的是后者的 `PP_INT_MASK`，不会误伤前者。
- `lima_bcast_enable()` 每个 job 只改 `BROADCAST_MASK` 低 16 位（广播
  `START_RENDERING` 的 PP 掩码），`INTERRUPT_MASK` 自 init 起就没再动过
  → bcast 中断线一直是活的，可以放心让它独占计数

## lima_pp.c —— 第二个 bug：PP 报错后 RENDERING_ACTIVE 永不清，白等 10s（**已修**）

run #22 的 `[done]` / `[pp]` 日志把时间线钉死了：

```
39.796869  pp0 error irq state=201 status=40
39.796931  pp1 error irq state=201 status=40
39.797027  [pp] pp1 still active rawstat=00000000 status=00000001   <-- 只有 bit0
   ...... 10 秒空白，PP1 一直是 RENDERING_ACTIVE、却没有任何待处理中断 ......
49.854852  [hang] sched task_count=1 done=00000001 error=0           <-- 这才是真正的 10s 超时
49.855911  [done] task_count=0 done=00000003 recov=0
49.856031  [hang] sched jiffies=...929 task_count=0 done=00000003 error=1   <-- 0.12ms 后就 TDR
```

结论有两条：

1. **`drm_sched_fault()` 是立即生效的**（`[done]` 到 TDR 只差 0.12ms），
   所以"错误后干等 10s"不是 drm_sched 的问题，而是**根本走不到 `task_done`**。
2. `lima_pp_handle_irq()` 在出错时会把该 PP 的 `INT_MASK` 清 0，
   而 PP 出错后 `PP_STATUS.RENDERING_ACTIVE` **不会自己清**——要等
   `lima_pp_task_error()` 里的 hard reset，而那只有超时处理里才调用。
   于是 bcast handler 永远在 `if (status & RENDERING_ACTIVE) continue;` 打转，
   `pipe->task` 停在 1，整整等一个 sched timeout（默认 10s）。

**修法**：`pipe->error` 一旦置位就说明这个 job 注定要被 reset，
此时不再因为 `RENDERING_ACTIVE` 而跳过，直接把它记成 done 并 dec，
让 `task_done()` → `drm_sched_fault()` → hard reset 立刻发生。

效果：**每个 PP 错误的代价从 10 秒冻结变成毫秒级重置**。
（plist 本身为什么非法还没解决，但至少桌面不会再一卡 10 秒。）

## lima_sched.c —— job timeout 时 dump GP/PP/MMU（**临时诊断补丁**）

**症状**：X/glamor 走 lima(kmsro) 时，桌面空闲完全正常（PP 错误 0），
但一加负载（两路 glxgears、wiliwili）GPU 就卡死：

```
[drm:lima_sched_timedout_job] *ERROR* pp0 job timeout
lima f9200000.gpu: pp0 bus stop timeout
lima f9200000.gpu: pp1 bus stop timeout
```

**注意顺序**：`job timeout` 在**前**，`bus stop timeout` 在**后**。
bus stop 是 `lima_pp_hard_reset()` 里 `STOP_BUS` 等 100ms 也没停住的结果，
**是后果不是原因**。真正要查的是"GPU 为什么 500ms 不返回"。

### 为什么打在 `lima_sched_timedout_job()`

这是唯一能拿到现场的位置：`pipe->task_mask_irq(pipe)` 之后、`pipe->task_error()`
（会 hard reset）之前 —— 中断已屏蔽但**硬件状态还没被清掉**。

dump 的内容（全部走 `dev_err`，行首带 `[hang]`）：

| IP | 寄存器 | 看什么 |
|---|---|---|
| GP | `STATUS` / `INT_RAWSTAT` / `INT_STAT` | `VS_ACTIVE`/`PLBU_ACTIVE` 卡在哪级；`BUS_ERROR`(bit6)、`WRITE_BOUND_ERR`(bit8) |
| GP | `VSCL_START_ADDR_READ` | GP 正在执行 VS 指令流的哪个地址 |
| GP | VS/PLBU/ALLOC 的 start-end 区间 | 命令流是否越界 |
| PP0/1 | `CURRENT_REND_LIST_ADDR` | **PP 当前读到 plist 的哪个地址**，和 `FRAME` 一比就知道是不是跑飞 |
| PP0/1 | `FRAME` / `STACK` / `STACK_SIZE` / `CTRL` | plist 起点、fragment stack 配置 |
| GPMMU/PPMMU | `STATUS` / `DTE` / `PAGE_FAULT_ADDR` / `INT_RAWSTAT` | 区分"地址翻译失败"还是"PP/GP 自己卡住" |
| task | `frame` 前 64 字节 | Mesa 实际提交的 frame 描述符 |

只打前 5 次（`lima_hang_dump_count`），避免刷屏。

**注意**：用 `print_hex_dump()` 而不是手写 `snprintf` 拼行 —— 7.3 把 `snprintf`
挪到了 `linux/sprintf.h`，手写容易踩头文件问题；`pr_cont()` 也不好用（实测
`dev_err` 之后的 `pr_cont` 接不上，只输出半行）。

**诊断用，定位完应删除。**

### 与之相关的结构事实（查 Mesa 21.2.6 源码得到）

- Mali450 **只有在「非全屏 damage」时才生成 PP stream**：
  `lima_update_pp_stream()` 里 `!lima_damage_fullscreen(job)` 才走
  `lima_update_damage_pp_stream()`，否则 `ctx->pp_stream.map = NULL` 走 DLBU。
  所以局部窗口/光标/文字走 PP stream，全屏渲染不走。
- `LIMA_CTX_PLB_BLK_SIZE = 512` 字节/16×16 tile，`plb_max_blk = 4096`(Mali450)
  → 每个 context 两张 2MB 的 PLB BO。
- `LIMA_PLB_PP_STREAM_CACHE_SIZE` 默认 **0**，即 PP stream 的 BO 每次重建、不缓存。

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

## lima_pp.c —— 第三个 bug：bus stop 超时后 INT_MASK 被永久留在 0（**已修**）

这个和前面几个不是同一个 bug，但它是**把"一帧出错"放大成"GPU 到重启为止全废"**的
原因，也是为什么之前每次实验看起来都像"挂死"。

### 现场（run #32，`dmesg | head` 的第一条就是它，前面全是干净启动）

```
[51.470909] [hang] timeout on pipe=pp ...
[51.470985] [hang] sched task_count=1 done=00000002 num_processor=2 error=0
[51.471011] [hang] gp   status=00000000 rawstat=00080000 intstat=00000000   # GP 全空闲
[51.471056] [hang] pp0  status=00000000 rawstat=00000001 intstat=00000000 intmask=00000000
[51.471083] [hang] pp1  status=00000000 rawstat=00000000 intstat=00000000 intmask=00000000
[51.471134] [hang] gpmmu  status=80000019 pfaddr=00000000 rawstat=00000000
[51.471154] [hang] ppmmu0 status=80000019 pfaddr=00000000 rawstat=00000000
[51.471265] [drm:lima_sched_timedout_job] *ERROR* pp0 job timeout
[51.471314] lima: pp0 task error 0 int_state=0 status=0
```

三个数摆在一起是自相矛盾又自解释的：

- `pp0 status=0` —— PP **没在渲染**，硬件是空的（`RENDERING_ACTIVE` 已掉）；
- `pp0 rawstat=0x1` —— `END_OF_FRAME` 早就置起了，一直躺着没人消费；
- `pp0 intmask=0` —— 这个 EOF **永远不会变成中断**，所以 bcast handler 永远拿不到它，
  `pipe->done` 缺这一位，`pipe->task` 停在 1 → 干等 10s 超时。

也就是说硬件其实**已经把这一帧渲染完了**，只是完成中断被自己的掩码挡死了。
之后每 10.25s 再超时一次（93.6 / 103.8 / 114.1 / 124.4 / 134.6），每次
`int_state=0 status=0` —— 硬件始终空闲，纯粹是软件死锁。

### 成因

```c
	pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_STOP_BUS);
	ret = lima_poll_timeout(ip, lima_pp_bus_stop_poll, 10, 100);
	if (ret) {
		dev_err(dev->dev, "%s bus stop timeout\n", lima_ip_name(ip));
		return ret;          /* ← 下面恢复 INT_MASK 的代码全被跳过 */
	}
	...
	pp_write(LIMA_PP_INT_CLEAR, LIMA_PP_IRQ_MASK_ALL);
	pp_write(LIMA_PP_INT_MASK, LIMA_PP_IRQ_MASK_USED);   /* ← 永远到不了这里 */
```

进 `lima_pp_hard_reset()` 之前，`lima_pp_task_mask_irq()`（超时路径）或
`lima_pp_handle_irq()` 的 error 分支已经把这个 PP 的 `INT_MASK` 写成 0；
只要 `STOP_BUS` 没等到 `PP_STATUS.BUS_STOPPED`(bit4)，函数就提前返回，
**掩码再也没有人去恢复** → 这个 PP 永久失聪。

### 修法

bus stop 超时不再 `return`，跳到 `restore:` 标签，无条件清 RAWSTAT 并把
`INT_MASK` 写回 `LIMA_PP_IRQ_MASK_USED_HANG`。

**没有**在总线没停的情况下硬拉 `FORCE_RESET`：那一步最可能把 AXI 总线一起锁死，
而 `status=0` 已经说明核内没有渲染在跑，放回掩码就足够让它重新上报完成。
宁可掉一帧，也不要变砖。

### 与 HANG 假设的关系（**HANG 已证伪**）

一度认为 `PP_STATUS` bit2 是"硬件自己置的 HANG 位"，而 `LIMA_PP_IRQ_HANG` 不在
`IRQ_MASK_USED` 里，所以只要把它并进掩码就能立刻感知挂死。实测（run #32）：

```
汇总: job timeout=9  error irq=0  HANG=0  bus stop=12
```

**9 次超时，0 次 error IRQ，0 次 HANG。** 这颗 Mali450 挂死时根本不报任何错误中断，
`INT_RAWSTAT` 里只有 `END_OF_FRAME`。掩码里加上 HANG 不解决问题（留着无害，
若真触发能拿到准确时刻的寄存器），真正的病灶是上面那个 premature return。

### 同时加的两个诊断（定位完就删）

1. `lima_pp_task_run()` 里 **广播回读自检**（前 8 帧）：整个 frame 是经 `pp_bcast`
   窗口广播下发的，如果 `BCAST_BROADCAST_MASK` 不对，PP 收不到 frame 寄存器、
   永远不会启动，症状（PP 空闲 + INT_MASK=0 + RAWSTAT 挂 EOF + 超时）和"挂死"
   一模一样。所以在 `START_RENDERING` 之前逐 PP 回读 `PP_FRAME`/`PP_INT_MASK`/
   `PP_STATUS` 与期望值比对。不符会打：

   ```
   pp0 precheck pp0 frame=00000000 want=fff00000 mask=00000f1d status=00000000 dlbu=1
   ```

   顺带记一条上游 bug：`lima_bcast_mask_irq()` / `lima_bcast_reset()` 被调用时传的是
   `pipe->bcast_processor`（= `pp_bcast`，偏移 0x16000），而这两个函数内部用的是
   `LIMA_BCAST_*` 寄存器偏移（真 BCAST 在 0x13000）——**它们一直在写错块**。
   `pp_bcast` 窗口的 0x00 正是 `LIMA_PP_FRAME`，所以"清广播掩码"实际是在
   把两个 PP 的渲染地址广播成 0。目前只在错误路径上调用，暂不修。
2. `lima_pp_task_error()` 输出补上 `int_mask` / `rawstat`；`lima_sched.c` 的
   `[hang] pp%d` 行补上 `buserr`(`PP_BUS_ERROR_STATUS`,0x1050) / `wbnd`
   (`LIMA_PP_WRITE_BOUNDARY_LOW`,0x1044)。

### 一条方法论教训

run #31 的"单 PP 实验"是**无效实验**，不能拿它否定任何假设：Mesa 的
`lima_job.c` 固定送 `pp_frame.num_pp = screen->num_pp`（=2），而内核
`lima_pp_task_validate()` 里有 `if (num_pp > pipe->num_processor) return -EINVAL;`
—— 只登记 1 个 PP 时每个 PP job 都被 `-EINVAL` 挡掉，所以"无帧输出、jt 照涨"
根本不是"单 PP 也挂"，而是 job 压根没提交。
