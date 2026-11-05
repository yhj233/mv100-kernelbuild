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

## lima_pp.c —— PP 出错时 dump task 描述符与 GPU 命令流（**临时诊断补丁**）

**目的**：lima 在 X/kmsro 负载下持续报

```
lima f9200000.gpu: pp0/pp1 error irq state=201 status=40
lima f9200000.gpu: pp0/pp1 task error 0/1 int_state=0 status=0
lima f9200000.gpu: pp0/pp1 reset time out
```

`state=0x201` 拆开是 `BIT(0) END_OF_FRAME | BIT(9) INVALID_PLIST_COMMAND`
（`lima_regs.h: LIMA_PP_IRQ_INVALID_PLIST_COMMAND`）：GPU 读到的图元命令流非法。
MMU 一条 fault 都没有，说明地址转换是通的，问题在命令流内容本身。

**改动**（只加打印，不动逻辑，最多打印 3 次避免刷屏）：

1. `int_state` 逐位翻译成名字（不再靠十六进制猜）
2. `task->frame` 的 23 个 PP 寄存器原值
3. 每个 PP 的 `plbu_array_address` / `fragment_stack_address`（GPU 真正去读的 GPU VA）
4. 拿这两个 VA 反查所属 BO（`lima_vm_get_va`），dump 那段 16 个 u32 —— 也就是
   GPU 眼里「非法命令流」的实际内容
5. `vm->pd.dma`、全部 BO 的 `va`/`size` 清单

**注意**：诊断用，定位完应删除（从 `patches/` 删掉，build.sh 就不再覆盖）。
