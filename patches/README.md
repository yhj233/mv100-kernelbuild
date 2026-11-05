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

## 顺带

- `histb-vdp2.c` 里那段 5 秒一次的 `vbcount=` 打印是 bring-up 用的探针，
  修好之后可以删掉（位置在 `histb_vdp2_irq_handler()` 末尾，标了 `[LOCAL]`）。
- Mesa 侧要配合 `_deploy/fake-drm-name/` 的 `libfake_drm_name.so`：把 card0 报的驱动名
  从 `histb-vdp2` 改成 kmsro 认识的名字（`sun4i-drm`），Mesa 才会用 lima 渲染、
  经 DMA-BUF 交给 vdp2 扫描输出。只有 vblank 修好之后这条路才跑得动。

## lima_pp.c —— PP 出错时 dump 现场（**临时诊断补丁**）

**症状**：X/glamor 走 lima(kmsro) 时，一启动就刷

```
pp0/pp1 error irq state=201 status=40
pp0/pp1 task error int_state=0 status=0
pp0/pp1 bus stop timeout     -> GPU 卡在 RENDERING_ACTIVE，此后再也复位不了
```

`state=0x201` = `END_OF_FRAME | INVALID_PLIST_COMMAND`；
`status=0x40` = `BUS_ERROR`（与 GP_STATUS 的 bit6 定义一致）。两者同时出现
说明 PP 去读了不该读的地址。**注意 MMU 一条 fault 都没有**，所以不是页表缺失，
而是 PP 拿到的地址/配置本身不对。

**已知线索**（第 2 版 dump 得到）：
- 出错任务是个 26x32 的小 pixmap（`frame[10]=25, frame[11]=31`,
  `frame[17]=supersampled_height=63`）——量级上正是 X **光标**的尺寸，
  与「X 一启动就崩」吻合。
- `frame[12]=fragment_stack_address=0`、`frame[13]=fragment_stack_size=0`。
  内核 `lima_pp_task_run()` 会无条件把它们写进 `PP_STACK` / `PP_STACK_SIZE`。
  但纯 clear 的 GBM 测试（lima_bench，369fps）同样 stack=0 却不报错，
  所以 stack=0 本身未必致命，需要实测寄存器确认。

**这一版加了什么**：
1. `lima_pp_dump_hw()`：在 **中断上下文、hard reset 之前** 读 PP 硬件寄存器
   （FRAME/RSW/STACK/STACKSZ/STATUS/CUR_REND_LIST/BUS_ERR/ORIGIN_X/INT_RAW）。
   上一版是在复位之后 dump，寄存器已被清零，拿到的值没有意义。
2. `lima_pp_dump_task()`：work 上下文 dump task 描述符、23 个 frame 寄存器、
   `plbu_array_address` / `fragment_stack_address`。
3. `lima_pp_dump_va()`：把 VA 反查回所属 BO 并 dump 内容；
   BO 未被 CPU 映射时用 `drm_gem_shmem_vmap_locked()` 临时映射。

**注意**：诊断用，定位完应删除（从 `patches/` 删掉，build.sh 就不再覆盖）。
