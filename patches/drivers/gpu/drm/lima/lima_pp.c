// SPDX-License-Identifier: GPL-2.0 OR MIT
/* Copyright 2017-2019 Qiang Yu <yuq825@gmail.com> */

#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/device.h>
#include <linux/slab.h>

#include <drm/lima_drm.h>

#include "lima_device.h"
#include "lima_pp.h"
#include "lima_dlbu.h"
#include "lima_bcast.h"
#include "lima_vm.h"
#include "lima_gem.h"
#include "lima_regs.h"

#define pp_write(reg, data) writel(data, ip->iomem + reg)
#define pp_read(reg) readl(ip->iomem + reg)

/* ---- mv100 debug: PP 出错瞬间的硬件寄存器（必须在复位之前读）---- */
static int mv100_hw_dumps;

/* 注意：本内核上 pr_cont() 接不上 dev_err() 的半行，必须整行拼好再打 */
static void lima_pp_dump_dlbu_mem(struct lima_device *dev, struct lima_ip *ip)
{
	u32 cur = pp_read(LIMA_PP_CURRENT_REND_LIST_ADDR);
	u32 off;
	char line[256];
	int i, j;

	if (!dev->dlbu_cpu)
		return;

	/* DLBU 的 tile list 缓冲区被映射在 LIMA_VA_RESERVE_DLBU */
	if (cur >= (u32)LIMA_VA_RESERVE_DLBU &&
	    cur < (u32)LIMA_VA_RESERVE_DLBU + LIMA_PAGE_SIZE)
		off = (cur - (u32)LIMA_VA_RESERVE_DLBU) & ~3u;
	else if (cur >= (u32)dev->dlbu_dma &&
		 cur < (u32)dev->dlbu_dma + LIMA_PAGE_SIZE)
		off = (cur - (u32)dev->dlbu_dma) & ~3u;
	else {
		dev_err(dev->dev,
			"  cur_list=%08x 不在 dlbu buf (va=%08x dma=%08x) 内，从头 dump\n",
			cur, (u32)LIMA_VA_RESERVE_DLBU, (u32)dev->dlbu_dma);
		off = 0;
	}

	/* 出错点前后各看一些，off 向前对齐到 8 字边界 */
	off &= ~31u;
	if (off + 128 > LIMA_PAGE_SIZE)
		off = LIMA_PAGE_SIZE - 128;

	dev_err(dev->dev, "  dlbu_mem @+%03x (cur_list=%08x):\n", off, cur);
	for (i = 0; i < 32; i += 8) {
		snprintf(line, sizeof(line), "   +%03x:", off + i * 4);
		for (j = 0; j < 8; j++)
			snprintf(line + strlen(line), sizeof(line) - strlen(line),
				 " %08x", dev->dlbu_cpu[(off >> 2) + i + j]);
		dev_err(dev->dev, "%s\n", line);
	}
}

static void lima_pp_dump_hw(struct lima_device *dev, struct lima_ip *ip,
			    u32 state, u32 status)
{
	if (mv100_hw_dumps >= 6)
		return;
	mv100_hw_dumps++;

	dev_err(dev->dev,
		"%s hw: state=%08x status=%08x FRAME=%08x RSW=%08x STACK=%08x STACKSZ=%08x\n",
		lima_ip_name(ip), state, status,
		pp_read(LIMA_PP_FRAME), pp_read(LIMA_PP_RSW),
		pp_read(LIMA_PP_STACK), pp_read(LIMA_PP_STACK_SIZE));
	dev_err(dev->dev,
		"%s hw: CUR_REND_LIST=%08x BUS_ERR=%08x ORIGIN_X=%08x INT_RAW=%08x INT_MASK=%08x\n",
		lima_ip_name(ip),
		pp_read(LIMA_PP_CURRENT_REND_LIST_ADDR),
		pp_read(LIMA_PP_BUS_ERROR_STATUS),
		pp_read(LIMA_PP_ORIGIN_OFFSET_X),
		pp_read(LIMA_PP_INT_RAWSTAT), pp_read(LIMA_PP_INT_MASK));
	dev_err(dev->dev, "%s hw: WBND_LOW=%08x CTRL=%08x\n",
		lima_ip_name(ip), pp_read(LIMA_PP_WRITE_BOUNDARY_LOW),
		pp_read(LIMA_PP_CTRL));

	if (dev->dlbu_cpu) {
		struct lima_ip *dlbu = dev->ip + lima_ip_dlbu;
		void __iomem *dm = dlbu->iomem;

		dev_err(dev->dev,
			"dlbu hw: PHYS=%08x VADDR=%08x VBASE=%08x FBDIM=%08x CONF=%08x TILEPOS=%08x EN=%08x\n",
			readl(dm + LIMA_DLBU_MASTER_TLLIST_PHYS_ADDR),
			readl(dm + LIMA_DLBU_MASTER_TLLIST_VADDR),
			readl(dm + LIMA_DLBU_TLLIST_VBASEADDR),
			readl(dm + LIMA_DLBU_FB_DIM),
			readl(dm + LIMA_DLBU_TLLIST_CONF),
			readl(dm + LIMA_DLBU_START_TILE_POS),
			readl(dm + LIMA_DLBU_PP_ENABLE_MASK));
	}
	lima_pp_dump_dlbu_mem(dev, ip);
}
/* ---- end mv100 debug ---- */


static void lima_pp_handle_irq(struct lima_ip *ip, u32 state)
{
	struct lima_device *dev = ip->dev;
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;

	if (state & LIMA_PP_IRQ_MASK_ERROR) {
		u32 status = pp_read(LIMA_PP_STATUS);

		dev_err(dev->dev, "%s error irq state=%x status=%x\n",
			lima_ip_name(ip), state, status);
		lima_pp_dump_hw(dev, ip, state, status);

		pipe->error = true;

		/* mask all interrupts before hard reset */
		pp_write(LIMA_PP_INT_MASK, 0);
	}

	pp_write(LIMA_PP_INT_CLEAR, state);
}

static irqreturn_t lima_pp_irq_handler(int irq, void *data)
{
	struct lima_ip *ip = data;
	struct lima_device *dev = ip->dev;
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;
	u32 state = pp_read(LIMA_PP_INT_STATUS);

	/* for shared irq case */
	if (!state)
		return IRQ_NONE;

	lima_pp_handle_irq(ip, state);

	if (atomic_dec_and_test(&pipe->task))
		lima_sched_pipe_task_done(pipe);

	return IRQ_HANDLED;
}

static irqreturn_t lima_pp_bcast_irq_handler(int irq, void *data)
{
	int i;
	irqreturn_t ret = IRQ_NONE;
	struct lima_ip *pp_bcast = data;
	struct lima_device *dev = pp_bcast->dev;
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;
	struct drm_lima_m450_pp_frame *frame;

	/* for shared irq case */
	if (!pipe->current_task)
		return IRQ_NONE;

	frame = pipe->current_task->frame;

	for (i = 0; i < frame->num_pp; i++) {
		struct lima_ip *ip = pipe->processor[i];
		u32 status, state;

		if (pipe->done & (1 << i))
			continue;

		/* status read first in case int state change in the middle
		 * which may miss the interrupt handling
		 */
		status = pp_read(LIMA_PP_STATUS);
		state = pp_read(LIMA_PP_INT_STATUS);

		if (state) {
			lima_pp_handle_irq(ip, state);
			ret = IRQ_HANDLED;
		} else {
			if (status & LIMA_PP_STATUS_RENDERING_ACTIVE)
				continue;
		}

		pipe->done |= (1 << i);
		if (atomic_dec_and_test(&pipe->task))
			lima_sched_pipe_task_done(pipe);
	}

	return ret;
}

static void lima_pp_soft_reset_async(struct lima_ip *ip)
{
	if (ip->data.async_reset)
		return;

	pp_write(LIMA_PP_INT_MASK, 0);
	pp_write(LIMA_PP_INT_RAWSTAT, LIMA_PP_IRQ_MASK_ALL);
	pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_SOFT_RESET);
	ip->data.async_reset = true;
}

static int lima_pp_soft_reset_poll(struct lima_ip *ip)
{
	return !(pp_read(LIMA_PP_STATUS) & LIMA_PP_STATUS_RENDERING_ACTIVE) &&
		pp_read(LIMA_PP_INT_RAWSTAT) == LIMA_PP_IRQ_RESET_COMPLETED;
}

static int lima_pp_soft_reset_async_wait_one(struct lima_ip *ip)
{
	struct lima_device *dev = ip->dev;
	int ret;

	ret = lima_poll_timeout(ip, lima_pp_soft_reset_poll, 0, 100);
	if (ret) {
		dev_err(dev->dev, "%s reset time out\n", lima_ip_name(ip));
		return ret;
	}

	pp_write(LIMA_PP_INT_CLEAR, LIMA_PP_IRQ_MASK_ALL);
	pp_write(LIMA_PP_INT_MASK, LIMA_PP_IRQ_MASK_USED);
	return 0;
}

static int lima_pp_soft_reset_async_wait(struct lima_ip *ip)
{
	int i, err = 0;

	if (!ip->data.async_reset)
		return 0;

	if (ip->id == lima_ip_pp_bcast) {
		struct lima_device *dev = ip->dev;
		struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;
		struct drm_lima_m450_pp_frame *frame = pipe->current_task->frame;

		for (i = 0; i < frame->num_pp; i++)
			err |= lima_pp_soft_reset_async_wait_one(pipe->processor[i]);
	} else
		err = lima_pp_soft_reset_async_wait_one(ip);

	ip->data.async_reset = false;
	return err;
}

static void lima_pp_write_frame(struct lima_ip *ip, u32 *frame, u32 *wb)
{
	int i, j, n = 0;

	for (i = 0; i < LIMA_PP_FRAME_REG_NUM; i++)
		writel(frame[i], ip->iomem + LIMA_PP_FRAME + i * 4);

	for (i = 0; i < 3; i++) {
		for (j = 0; j < LIMA_PP_WB_REG_NUM; j++)
			writel(wb[n++], ip->iomem + LIMA_PP_WB(i) + j * 4);
	}
}

static int lima_pp_bus_stop_poll(struct lima_ip *ip)
{
	return !!(pp_read(LIMA_PP_STATUS) & LIMA_PP_STATUS_BUS_STOPPED);
}

static int lima_pp_hard_reset_poll(struct lima_ip *ip)
{
	pp_write(LIMA_PP_PERF_CNT_0_LIMIT, 0xC01A0000);
	return pp_read(LIMA_PP_PERF_CNT_0_LIMIT) == 0xC01A0000;
}

static int lima_pp_hard_reset(struct lima_ip *ip)
{
	struct lima_device *dev = ip->dev;
	int ret;

	pp_write(LIMA_PP_PERF_CNT_0_LIMIT, 0xC0FFE000);
	pp_write(LIMA_PP_INT_MASK, 0);

	pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_STOP_BUS);
	ret = lima_poll_timeout(ip, lima_pp_bus_stop_poll, 10, 100);
	if (ret) {
		dev_err(dev->dev, "%s bus stop timeout\n", lima_ip_name(ip));
		return ret;
	}

	pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_FORCE_RESET);
	ret = lima_poll_timeout(ip, lima_pp_hard_reset_poll, 10, 100);
	if (ret) {
		dev_err(dev->dev, "%s hard reset timeout\n", lima_ip_name(ip));
		return ret;
	}

	pp_write(LIMA_PP_PERF_CNT_0_LIMIT, 0);
	pp_write(LIMA_PP_INT_CLEAR, LIMA_PP_IRQ_MASK_ALL);
	pp_write(LIMA_PP_INT_MASK, LIMA_PP_IRQ_MASK_USED);

	/*
	 * if there was an async soft reset queued,
	 * don't wait for it in the next job
	 */
	ip->data.async_reset = false;

	return 0;
}

static void lima_pp_print_version(struct lima_ip *ip)
{
	u32 version, major, minor;
	char *name;

	version = pp_read(LIMA_PP_VERSION);
	major = (version >> 8) & 0xFF;
	minor = version & 0xFF;
	switch (version >> 16) {
	case 0xC807:
	    name = "mali200";
		break;
	case 0xCE07:
		name = "mali300";
		break;
	case 0xCD07:
		name = "mali400";
		break;
	case 0xCF07:
		name = "mali450";
		break;
	default:
		name = "unknown";
		break;
	}
	dev_info(ip->dev->dev, "%s - %s version major %d minor %d\n",
		 lima_ip_name(ip), name, major, minor);
}

static int lima_pp_hw_init(struct lima_ip *ip)
{
	ip->data.async_reset = false;
	lima_pp_soft_reset_async(ip);
	return lima_pp_soft_reset_async_wait(ip);
}

int lima_pp_resume(struct lima_ip *ip)
{
	return lima_pp_hw_init(ip);
}

void lima_pp_suspend(struct lima_ip *ip)
{

}

int lima_pp_init(struct lima_ip *ip)
{
	struct lima_device *dev = ip->dev;
	int err;

	lima_pp_print_version(ip);

	err = lima_pp_hw_init(ip);
	if (err)
		return err;

	err = devm_request_irq(dev->dev, ip->irq, lima_pp_irq_handler,
			       IRQF_SHARED, lima_ip_name(ip), ip);
	if (err) {
		dev_err(dev->dev, "%s fail to request irq\n",
			lima_ip_name(ip));
		return err;
	}

	dev->pp_version = pp_read(LIMA_PP_VERSION);

	return 0;
}

void lima_pp_fini(struct lima_ip *ip)
{
	struct lima_device *dev = ip->dev;

	devm_free_irq(dev->dev, ip->irq, ip);
}

int lima_pp_bcast_resume(struct lima_ip *ip)
{
	/* PP has been reset by individual PP resume */
	ip->data.async_reset = false;
	return 0;
}

void lima_pp_bcast_suspend(struct lima_ip *ip)
{

}

int lima_pp_bcast_init(struct lima_ip *ip)
{
	struct lima_device *dev = ip->dev;
	int err;

	err = devm_request_irq(dev->dev, ip->irq, lima_pp_bcast_irq_handler,
			       IRQF_SHARED, lima_ip_name(ip), ip);
	if (err) {
		dev_err(dev->dev, "%s fail to request irq\n",
			lima_ip_name(ip));
		return err;
	}

	return 0;
}

void lima_pp_bcast_fini(struct lima_ip *ip)
{
	struct lima_device *dev = ip->dev;

	devm_free_irq(dev->dev, ip->irq, ip);
}

static int lima_pp_task_validate(struct lima_sched_pipe *pipe,
				 struct lima_sched_task *task)
{
	u32 num_pp;

	if (pipe->bcast_processor) {
		struct drm_lima_m450_pp_frame *f = task->frame;

		num_pp = f->num_pp;

		if (f->_pad)
			return -EINVAL;
	} else {
		struct drm_lima_m400_pp_frame *f = task->frame;

		num_pp = f->num_pp;
	}

	if (num_pp == 0 || num_pp > pipe->num_processor)
		return -EINVAL;

	return 0;
}

static void lima_pp_task_run(struct lima_sched_pipe *pipe,
			     struct lima_sched_task *task)
{
	if (pipe->bcast_processor) {
		struct drm_lima_m450_pp_frame *frame = task->frame;
		struct lima_device *dev = pipe->bcast_processor->dev;
		struct lima_ip *ip = pipe->bcast_processor;
		int i;

		pipe->done = 0;
		atomic_set(&pipe->task, frame->num_pp);

		if (frame->use_dlbu) {
			lima_dlbu_enable(dev, frame->num_pp);

			frame->frame[LIMA_PP_FRAME >> 2] = LIMA_VA_RESERVE_DLBU;
			lima_dlbu_set_reg(dev->ip + lima_ip_dlbu, frame->dlbu_regs);
		} else
			lima_dlbu_disable(dev);

		lima_bcast_enable(dev, frame->num_pp);

		lima_pp_soft_reset_async_wait(ip);

		lima_pp_write_frame(ip, frame->frame, frame->wb);

		for (i = 0; i < frame->num_pp; i++) {
			struct lima_ip *ip = pipe->processor[i];

			pp_write(LIMA_PP_STACK, frame->fragment_stack_address[i]);
			if (!frame->use_dlbu)
				pp_write(LIMA_PP_FRAME, frame->plbu_array_address[i]);
		}

		pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_START_RENDERING);
	} else {
		struct drm_lima_m400_pp_frame *frame = task->frame;
		int i;

		atomic_set(&pipe->task, frame->num_pp);

		for (i = 0; i < frame->num_pp; i++) {
			struct lima_ip *ip = pipe->processor[i];

			frame->frame[LIMA_PP_FRAME >> 2] =
				frame->plbu_array_address[i];
			frame->frame[LIMA_PP_STACK >> 2] =
				frame->fragment_stack_address[i];

			lima_pp_soft_reset_async_wait(ip);

			lima_pp_write_frame(ip, frame->frame, frame->wb);

			pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_START_RENDERING);
		}
	}
}

static void lima_pp_task_fini(struct lima_sched_pipe *pipe)
{
	if (pipe->bcast_processor)
		lima_pp_soft_reset_async(pipe->bcast_processor);
	else {
		int i;

		for (i = 0; i < pipe->num_processor; i++)
			lima_pp_soft_reset_async(pipe->processor[i]);
	}
}


/* ---- mv100 debug: PP 出错后 dump task 描述符与 GPU 命令流 ---- */
static int mv100_pp_dumps;

static void lima_pp_dump_u32(struct lima_device *dev, const char *tag,
			     const u32 *p, int n)
{
	char line[256];
	int i, j;

	for (i = 0; i < n; i += 8) {
		int m = (n - i) < 8 ? (n - i) : 8;

		snprintf(line, sizeof(line), "  %s[%02d]:", tag, i);
		for (j = 0; j < m; j++)
			snprintf(line + strlen(line), sizeof(line) - strlen(line),
				 " %08x", p[i + j]);
		dev_err(dev->dev, "%s\n", line);
	}
}

/* 把 GPU 侧 VA 翻译回所属 BO，并 dump 那段内容；未映射则临时 vmap */
static void lima_pp_dump_va(struct lima_device *dev, struct lima_sched_task *task,
			    u32 va, const char *tag)
{
	struct lima_vm *vm = task->vm;
	int i;

	if (!vm)
		return;

	for (i = 0; i < task->num_bos; i++) {
		struct lima_bo *bo = task->bos[i];
		size_t size = lima_bo_size(bo);
		u32 bo_va = lima_vm_get_va(vm, bo);
		struct iosys_map map;
		char *base;
		size_t off;

		if (va < bo_va || va >= bo_va + size)
			continue;

		off = (size_t)(va - bo_va) & ~3UL;
		base = bo->base.vaddr;
		if (!base && !drm_gem_shmem_vmap_locked(&bo->base, &map))
			base = map.vaddr;
		dev_err(dev->dev,
			"  %s va=%08x -> bo[%d] va=%08x size=%zu off=%zu kva=%px\n",
			tag, va, i, bo_va, size, off, base);
		if (!base || off + 4 * 16 > size)
			return;
		lima_pp_dump_u32(dev, tag, (const u32 *)(base + off), 16);
		return;
	}

	dev_err(dev->dev, "  %s va=%08x NOT FOUND in %d bos\n",
		tag, va, task->num_bos);
}

static void lima_pp_dump_task(struct lima_device *dev, struct lima_sched_pipe *pipe,
			      struct lima_ip *ip)
{
	struct lima_sched_task *task = pipe->current_task;
	int i;

	if (!task) {
		dev_err(dev->dev, "%s no current task to dump\n", lima_ip_name(ip));
		return;
	}

	dev_err(dev->dev,
		"%s task seqno=%llu frame=%px heap=%px num_bos=%d vm=%px\n",
		lima_ip_name(ip),
		(unsigned long long)task->base.s_fence->finished.seqno,
		task->frame, task->heap, task->num_bos, task->vm);

	if (pipe->bcast_processor) {
		struct drm_lima_m450_pp_frame *f = task->frame;

		dev_err(dev->dev, "  m450 num_pp=%u use_dlbu=%u\n",
			f->num_pp, f->use_dlbu);
		lima_pp_dump_u32(dev, "reg", f->frame, LIMA_PP_FRAME_REG_NUM);
		dev_err(dev->dev, "  dlbu_regs: vbase=%08x fbdim=%08x conf=%08x tilepos=%08x\n",
			f->dlbu_regs[0], f->dlbu_regs[1],
			f->dlbu_regs[2], f->dlbu_regs[3]);
		for (i = 0; i < 8; i++)
			dev_err(dev->dev, "  pp%d plbu_va=%08x stack_va=%08x\n", i,
				f->plbu_array_address[i], f->fragment_stack_address[i]);
		lima_pp_dump_va(dev, task, f->plbu_array_address[0],
				f->use_dlbu ? "tllist/plb" : "plbu");
		if (f->fragment_stack_address[0])
			lima_pp_dump_va(dev, task, f->fragment_stack_address[0], "stack");
	} else {
		struct drm_lima_m400_pp_frame *f = task->frame;

		dev_err(dev->dev, "  m400 num_pp=%u\n", f->num_pp);
		lima_pp_dump_u32(dev, "reg", f->frame, LIMA_PP_FRAME_REG_NUM);
		for (i = 0; i < 4; i++)
			dev_err(dev->dev, "  pp%d plbu_va=%08x stack_va=%08x\n", i,
				f->plbu_array_address[i], f->fragment_stack_address[i]);
		lima_pp_dump_va(dev, task, f->plbu_array_address[0], "plbu");
		lima_pp_dump_va(dev, task, f->fragment_stack_address[0], "stack");
	}

	if (task->vm)
		dev_err(dev->dev, "  vm pd.dma=%pad\n", &task->vm->pd.dma);
	for (i = 0; i < task->num_bos; i++) {
		if (task->vm)
			dev_err(dev->dev, "  bo[%d] va=%08x size=%zu\n", i,
				lima_vm_get_va(task->vm, task->bos[i]),
				lima_bo_size(task->bos[i]));
		else
			dev_err(dev->dev, "  bo[%d] size=%zu\n", i,
				lima_bo_size(task->bos[i]));
	}
}

static void lima_pp_dump_int_state(struct lima_device *dev, struct lima_ip *ip, u32 state)
{
	dev_err(dev->dev, "%s pp_int=%08x:%s%s%s%s%s%s%s\n", lima_ip_name(ip), state,
		(state & LIMA_PP_IRQ_END_OF_FRAME) ? " END_OF_FRAME" : "",
		(state & LIMA_PP_IRQ_HANG) ? " HANG" : "",
		(state & LIMA_PP_IRQ_FORCE_HANG) ? " FORCE_HANG" : "",
		(state & LIMA_PP_IRQ_BUS_ERROR) ? " BUS_ERROR" : "",
		(state & LIMA_PP_IRQ_WRITE_BOUNDARY_ERROR) ? " WRITE_BOUNDARY_ERROR" : "",
		(state & LIMA_PP_IRQ_INVALID_PLIST_COMMAND) ? " INVALID_PLIST_COMMAND" : "",
		(state & LIMA_PP_IRQ_CALL_STACK_UNDERFLOW) ? " CALL_STACK_UNDERFLOW" : "");
}
/* ---- end mv100 debug ---- */

static void lima_pp_task_error(struct lima_sched_pipe *pipe)
{
	int i;

	for (i = 0; i < pipe->num_processor; i++) {
		struct lima_ip *ip = pipe->processor[i];

		u32 int_state = pp_read(LIMA_PP_INT_STATUS);

		dev_err(ip->dev->dev, "%s task error %d int_state=%x status=%x\n",
			lima_ip_name(ip), i, int_state, pp_read(LIMA_PP_STATUS));
		lima_pp_dump_int_state(ip->dev, ip, int_state);

		lima_pp_hard_reset(ip);
	}

	if (pipe->bcast_processor)
		lima_bcast_reset(pipe->bcast_processor);

	if (mv100_pp_dumps < 3) {
		mv100_pp_dumps++;
		lima_pp_dump_task(pipe->ldev, pipe, pipe->processor[0]);
	}
}

static void lima_pp_task_mmu_error(struct lima_sched_pipe *pipe)
{
	if (atomic_dec_and_test(&pipe->task))
		lima_sched_pipe_task_done(pipe);
}

static void lima_pp_task_mask_irq(struct lima_sched_pipe *pipe)
{
	int i;

	for (i = 0; i < pipe->num_processor; i++) {
		struct lima_ip *ip = pipe->processor[i];

		pp_write(LIMA_PP_INT_MASK, 0);
	}

	if (pipe->bcast_processor)
		lima_bcast_mask_irq(pipe->bcast_processor);
}

static struct kmem_cache *lima_pp_task_slab;
static int lima_pp_task_slab_refcnt;

int lima_pp_pipe_init(struct lima_device *dev)
{
	int frame_size;
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;

	if (dev->id == lima_gpu_mali400)
		frame_size = sizeof(struct drm_lima_m400_pp_frame);
	else
		frame_size = sizeof(struct drm_lima_m450_pp_frame);

	if (!lima_pp_task_slab) {
		lima_pp_task_slab = kmem_cache_create_usercopy(
			"lima_pp_task", sizeof(struct lima_sched_task) + frame_size,
			0, SLAB_HWCACHE_ALIGN, sizeof(struct lima_sched_task),
			frame_size, NULL);
		if (!lima_pp_task_slab)
			return -ENOMEM;
	}
	lima_pp_task_slab_refcnt++;

	pipe->frame_size = frame_size;
	pipe->task_slab = lima_pp_task_slab;

	pipe->task_validate = lima_pp_task_validate;
	pipe->task_run = lima_pp_task_run;
	pipe->task_fini = lima_pp_task_fini;
	pipe->task_error = lima_pp_task_error;
	pipe->task_mmu_error = lima_pp_task_mmu_error;
	pipe->task_mask_irq = lima_pp_task_mask_irq;

	return 0;
}

void lima_pp_pipe_fini(struct lima_device *dev)
{
	if (!--lima_pp_task_slab_refcnt) {
		kmem_cache_destroy(lima_pp_task_slab);
		lima_pp_task_slab = NULL;
	}
}
