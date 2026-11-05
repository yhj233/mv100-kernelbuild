// SPDX-License-Identifier: GPL-2.0 OR MIT
/* Copyright 2017-2019 Qiang Yu <yuq825@gmail.com> */

#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/timer.h>

#include <drm/lima_drm.h>

#include "lima_device.h"
#include "lima_pp.h"
#include "lima_dlbu.h"
#include "lima_bcast.h"
#include "lima_vm.h"
#include "lima_regs.h"

#define pp_write(reg, data) writel(data, ip->iomem + reg)
#define pp_read(reg) readl(ip->iomem + reg)

/*
 * Upstream never listens for PP_IRQ_HANG: LIMA_PP_IRQ_MASK_ERROR does not
 * contain it and LIMA_PP_IRQ_MASK_USED is built from END_OF_FRAME +
 * MASK_ERROR, so the bit stays masked in PP_INT_MASK.
 *
 * Measured on this Mali450 (kernel 802cdc9fde): a wedged PP does *not* raise
 * HANG, nor any of the MASK_ERROR bits -- INT_RAWSTAT only ever carries
 * END_OF_FRAME.  So unmasking HANG does not by itself rescue anything; it is
 * kept because it costs nothing and it is what turns a real hang into an
 * immediate, accurately timestamped report if the core ever does raise it.
 *
 * What the wedge actually looks like is a *silent* PP: RENDERING_ACTIVE
 * drops, END_OF_FRAME sits pending in INT_RAWSTAT, and PP_INT_MASK is zero,
 * so no interrupt is ever delivered, pipe->done never gets the bit, and the
 * job waits out the whole sched timeout on idle hardware.  See the
 * lima_pp_hard_reset() comment for how that mask got stuck at zero.
 */
#define LIMA_PP_IRQ_MASK_ERROR_HANG \
	(LIMA_PP_IRQ_MASK_ERROR | LIMA_PP_IRQ_HANG)

#define LIMA_PP_IRQ_MASK_USED_HANG \
	(LIMA_PP_IRQ_END_OF_FRAME | LIMA_PP_IRQ_MASK_ERROR_HANG)

/* how many broadcast read-backs to complain about before going quiet */
static int pp_verify_left = 8;

static void lima_pp_hang_dump(struct lima_ip *ip, u32 state)
{
	struct lima_device *dev = ip->dev;
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;
	const char *name = lima_ip_name(ip);

	dev_err(dev->dev,
		"%s HANG irq=%08x status=%08x ctrl=%08x buserr=%08x wbnd=%08x\n",
		name, state, pp_read(LIMA_PP_STATUS), pp_read(LIMA_PP_CTRL),
		pp_read(LIMA_PP_BUS_ERROR_STATUS),
		pp_read(LIMA_PP_WRITE_BOUNDARY_LOW));
	dev_err(dev->dev,
		"%s HANG rendlist=%08x rawstat=%08x mask=%08x done=%08x task=%d\n",
		name, pp_read(LIMA_PP_CURRENT_REND_LIST_ADDR),
		pp_read(LIMA_PP_INT_RAWSTAT), pp_read(LIMA_PP_INT_MASK),
		pipe->done, atomic_read(&pipe->task));

	if (pipe->bcast_processor && pipe->current_task) {
		struct drm_lima_m450_pp_frame *frame = pipe->current_task->frame;

		dev_err(dev->dev,
			"%s HANG job num_pp=%u dlbu=%u plbu=%08x/%08x stack=%08x/%08x\n",
			name, frame->num_pp, frame->use_dlbu,
			frame->plbu_array_address[0],
			frame->plbu_array_address[1],
			frame->fragment_stack_address[0],
			frame->fragment_stack_address[1]);
		dev_err(dev->dev,
			"%s HANG dlbu_regs=%08x %08x %08x %08x\n",
			name, frame->dlbu_regs[0], frame->dlbu_regs[1],
			frame->dlbu_regs[2], frame->dlbu_regs[3]);
	}
}

static void lima_pp_handle_irq(struct lima_ip *ip, u32 state)
{
	struct lima_device *dev = ip->dev;
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;

	if (state & LIMA_PP_IRQ_MASK_ERROR_HANG) {
		u32 status = pp_read(LIMA_PP_STATUS);

		dev_err(dev->dev, "%s error irq state=%x status=%x\n",
			lima_ip_name(ip), state, status);

		if (state & LIMA_PP_IRQ_HANG)
			lima_pp_hang_dump(ip, state);

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
	u32 state;

	/*
	 * On M450 (pp_bcast present) lima_pp_bcast_irq_handler() walks every
	 * PP and is the only consumer of their interrupt state.  It has to
	 * own that job because it is the one keeping pipe->done per PP, and
	 * because the two handlers race for the same END_OF_FRAME bit:
	 *
	 *   1. PP finishes and raises END_OF_FRAME on the shared IRQ line.
	 *   2. This handler runs first (registered before pp_bcast), reads
	 *      the state and clears it.
	 *   3. The bcast handler then samples PP_STATUS while the PP has not
	 *      yet dropped RENDERING_ACTIVE, sees no pending interrupt (step 2
	 *      already cleared it) and skips the PP as "still rendering".
	 *   4. The PP goes idle.  Nothing is left to raise the interrupt
	 *      again, so the PP is never accounted in pipe->done, pipe->task
	 *      never reaches zero and the job sits there for a full sched
	 *      timeout with completely idle hardware -- and the hard reset
	 *      that follows is what finally produces INVALID_PLIST_COMMAND.
	 *
	 * Leaving the interrupt untouched here removes the race: the bcast
	 * handler reads PP_STATUS and PP_INT_STATUS back to back, so a
	 * pending END_OF_FRAME always wins over a stale RENDERING_ACTIVE.
	 *
	 * The counting lives in the bcast handler for the same reason: letting
	 * both handlers decrement made a two-PP job complete as soon as the
	 * first PP finished, i.e. while the second was still reading its
	 * polygon list.
	 */
	if (pipe->bcast_processor)
		return IRQ_NONE;

	state = pp_read(LIMA_PP_INT_STATUS);

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

	/*
	 * No job to account interrupts to.  They still have to be acked,
	 * because on M450 this is the only handler that clears them and a
	 * stale END_OF_FRAME would keep the shared IRQ line asserted.
	 */
	if (!pipe->current_task) {
		for (i = 0; i < pipe->num_processor; i++) {
			struct lima_ip *ip = pipe->processor[i];
			u32 state;

			if (!ip || !ip->present)
				continue;
			state = pp_read(LIMA_PP_INT_STATUS);
			if (state) {
				pp_write(LIMA_PP_INT_CLEAR, state);
				ret = IRQ_HANDLED;
			}
		}
		return ret;
	}

	frame = pipe->current_task->frame;

	for (i = 0; i < frame->num_pp; i++) {
		struct lima_ip *ip = pipe->processor[i];
		u32 status, state;

		if (!ip || !ip->present)
			continue;

		/* status read first in case int state change in the middle
		 * which may miss the interrupt handling
		 */
		status = pp_read(LIMA_PP_STATUS);
		state = pp_read(LIMA_PP_INT_STATUS);

		/*
		 * This handler is now the only one acking PP interrupts on
		 * M450, so an interrupt that arrives after its PP was already
		 * accounted still has to be cleared here -- otherwise the
		 * shared IRQ line stays asserted forever.
		 */
		if (pipe->done & (1 << i)) {
			if (state)
				pp_write(LIMA_PP_INT_CLEAR, state);
			continue;
		}

		/*
		 * Error/HANG bits must be handled (and acknowledged) even when
		 * the core has not yet dropped RENDERING_ACTIVE: they carry the
		 * real failure report and, once raised, the job is going to be
		 * reset anyway.  Pass the full state through so lima_pp_handle_irq
		 * can mask + dump on HANG.
		 */
		if (state & (LIMA_PP_IRQ_MASK_ERROR_HANG))
			lima_pp_handle_irq(ip, state);
		else if (state)
			pp_write(LIMA_PP_INT_CLEAR, state);
		if (state)
			ret = IRQ_HANDLED;

		/*
		 * The wire-ORed interrupt line (all eight Mali units share SPI 94
		 * on this SoC) means INT_STATUS/END_OF_FRAME can be consumed by a
		 * competing handler before we sample it, so the interrupt bit is
		 * NOT a reliable completion signal.  RENDERING_ACTIVE, by contrast,
		 * is pure hardware state that nothing on the shared line clears:
		 * treat its falling edge as the authoritative "PP finished".
		 *
		 *   1. RENDERING_ACTIVE still set and no error: genuinely still
		 *      drawing, wait for a later interrupt to re-run this handler.
		 *   2. RENDERING_ACTIVE cleared: the core finished, account it done
		 *      regardless of whether END_OF_FRAME is still pending.  This
		 *      is the fix for the race where the END_OF_FRAME bit was
		 *      cleared out from under us, leaving the PP idle but never
		 *      accounted -- which is exactly the silent, periodic wedge.
		 *   3. pipe->error already set: the job is doomed; account done so
		 *      the timeout/reset path runs instead of stalling a full sched
		 *      timeout on idle-but-flagged-as-active hardware.
		 */
		if (status & LIMA_PP_STATUS_RENDERING_ACTIVE) {
			if (!pipe->error)
				continue;
		}

		pipe->done |= (1 << i);

		/*
		 * A completion IRQ that arrives after the job already finished
		 * must not be accounted to the next job: never let pipe->task
		 * go below zero, otherwise a later job can be completed by a
		 * stale decrement and its buffers get recycled while the PP is
		 * still reading them.
		 */
		if (atomic_read(&pipe->task) <= 0)
			continue;

		if (atomic_dec_and_test(&pipe->task))
			lima_sched_pipe_task_done(pipe);
	}

	return ret;
}

/*
 * [LOCAL] Completion watchdog.
 *
 * The eight Mali units on this SoC are wire-ORed onto one GIC line (SPI 94),
 * and the PP units share that line with gp/gpmmu/pmu.  A PP can therefore
 * finish (RENDERING_ACTIVE drops) while its END_OF_FRAME interrupt bit is
 * consumed by a competing shared handler before this driver samples it -- and
 * once every pending bit on the line is cleared, no interrupt will ever
 * re-enter this handler, so that PP is never accounted: the job idles for a
 * whole scheduler timeout (10s) and then gets hard-reset.  That is the
 * periodic stall seen as stale framebuffer + input lag on screen.
 *
 * RENDERING_ACTIVE is pure hardware state that nothing on the shared line
 * clears, so it is the authoritative "finished" signal.  This timer polls it
 * and folds any finished-but-unaccounted PP into pipe->done, which lets the
 * job complete promptly instead of timing out.
 */
static void lima_pp_done_poll(struct lima_sched_pipe *pipe)
{
	struct drm_lima_m450_pp_frame *frame;
	int i;

	/*
	 * Only meaningful for the broadcast (M450) pipe: the per-PP shared
	 * handler there is what races for the wire-ORed END_OF_FRAME.  On
	 * Mali400 each PP has its own interrupt and the plain irq handler
	 * accounts it, so there is nothing to poll.
	 */
	if (!pipe->bcast_processor)
		return;

	if (!pipe->current_task)
		return;

	frame = pipe->current_task->frame;

	for (i = 0; i < frame->num_pp; i++) {
		struct lima_ip *ip = pipe->processor[i];

		if (!ip || !ip->present)
			continue;
		if (pipe->done & (1 << i))
			continue;

		/* RENDERING_ACTIVE still set: genuinely drawing, leave it. */
		if (pp_read(LIMA_PP_STATUS) & LIMA_PP_STATUS_RENDERING_ACTIVE)
			continue;

		/* finished but never accounted -- fold it in */
		pipe->done |= (1 << i);

		if (atomic_read(&pipe->task) <= 0)
			continue;
		if (atomic_dec_and_test(&pipe->task))
			lima_sched_pipe_task_done(pipe);
	}
}

static void lima_pp_done_timer_cb(struct timer_list *t)
{
	struct lima_sched_pipe *pipe =
		container_of(t, struct lima_sched_pipe, done_timer);

	lima_pp_done_poll(pipe);

	/* keep polling until the job is fully accounted */
	if (pipe->current_task && atomic_read(&pipe->task) > 0)
		mod_timer(&pipe->done_timer, jiffies + msecs_to_jiffies(50));
}

void lima_pp_done_timer_arm(struct lima_sched_pipe *pipe)
{
	if (!pipe->bcast_processor)
		return;
	mod_timer(&pipe->done_timer, jiffies + msecs_to_jiffies(50));
}

void lima_pp_done_timer_disarm(struct lima_sched_pipe *pipe)
{
	/*
	 * timer_delete(), not timer_delete_sync(): this is also called from the
	 * timer callback itself (via lima_sched_pipe_task_done) and
	 * timer_delete_sync on the running timer would self-deadlock.  The
	 * re-arm guard checks current_task && task>0, so after the job is
	 * accounted the timer will not re-arm; lima_pp_pipe_fini() does the
	 * synchronous teardown.
	 */
	timer_delete(&pipe->done_timer);
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
	pp_write(LIMA_PP_INT_MASK, LIMA_PP_IRQ_MASK_USED_HANG);
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
		/*
		 * The core reports RENDERING_ACTIVE=0 and an idle bus, yet
		 * BUS_STOPPED never comes back.  Upstream gives up right here
		 * and leaves PP_INT_MASK = 0 behind, i.e. the core can never
		 * signal END_OF_FRAME again: every following job waits out the
		 * full sched timeout with completely idle hardware, and after
		 * that every further job does the same.  One bad frame turned
		 * into a permanently deaf pipe.
		 *
		 * Do not yank FORCE_RESET on a bus that did not stop (that is
		 * the one step that can wedge the SoC), but always put the
		 * interrupt mask back so the core can be accounted again.
		 */
		dev_err(dev->dev, "%s bus stop timeout, restoring irq mask\n",
			lima_ip_name(ip));
		goto restore;
	}

	pp_write(LIMA_PP_CTRL, LIMA_PP_CTRL_FORCE_RESET);
	ret = lima_poll_timeout(ip, lima_pp_hard_reset_poll, 10, 100);
	if (ret)
		dev_err(dev->dev, "%s hard reset timeout\n", lima_ip_name(ip));

restore:
	pp_write(LIMA_PP_PERF_CNT_0_LIMIT, 0);
	pp_write(LIMA_PP_INT_CLEAR, LIMA_PP_IRQ_MASK_ALL);
	pp_write(LIMA_PP_INT_MASK, LIMA_PP_IRQ_MASK_USED_HANG);

	/*
	 * if there was an async soft reset queued,
	 * don't wait for it in the next job
	 */
	ip->data.async_reset = false;

	return ret;
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

		/*
		 * DIAGNOSTIC: the whole frame is programmed through the
		 * pp_bcast window, so if the broadcast mask is wrong the cores
		 * simply never start -- and the symptom (idle PP, INT_MASK 0,
		 * END_OF_FRAME pending in RAWSTAT, job timeout) looks exactly
		 * like a hang.  Read back what the cores actually got before
		 * handing them the start bit.
		 */
		if (pp_verify_left > 0) {
			for (i = 0; i < frame->num_pp; i++) {
				struct lima_ip *pp = pipe->processor[i];
				u32 want = frame->use_dlbu ? LIMA_VA_RESERVE_DLBU :
					    frame->plbu_array_address[i];
				u32 got_frame, got_mask, got_status;
				bool bad;

				got_frame = readl(pp->iomem + LIMA_PP_FRAME);
				got_mask = readl(pp->iomem + LIMA_PP_INT_MASK);
				got_status = readl(pp->iomem + LIMA_PP_STATUS);
				bad = got_frame != want ||
				      got_mask != LIMA_PP_IRQ_MASK_USED_HANG ||
				      (got_status & LIMA_PP_STATUS_RENDERING_ACTIVE);
				if (!bad)
					continue;

				pp_verify_left--;
				dev_err(dev->dev,
					"%s precheck pp%d frame=%08x want=%08x mask=%08x status=%08x dlbu=%u\n",
					lima_ip_name(pp), i, got_frame, want,
					got_mask, got_status, frame->use_dlbu);
			}
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

	/* [LOCAL] arm the completion watchdog now that the cores are running */
	lima_pp_done_timer_arm(pipe);
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

static void lima_pp_task_error(struct lima_sched_pipe *pipe)
{
	int i;

	for (i = 0; i < pipe->num_processor; i++) {
		struct lima_ip *ip = pipe->processor[i];

		dev_err(ip->dev->dev,
			"%s task error %d int_state=%x status=%x int_mask=%x rawstat=%x\n",
			lima_ip_name(ip), i, pp_read(LIMA_PP_INT_STATUS),
			pp_read(LIMA_PP_STATUS), pp_read(LIMA_PP_INT_MASK),
			pp_read(LIMA_PP_INT_RAWSTAT));

		lima_pp_hard_reset(ip);
	}

	if (pipe->bcast_processor)
		lima_bcast_reset(pipe->bcast_processor);
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

	/* [LOCAL] completion watchdog */
	timer_setup(&pipe->done_timer, lima_pp_done_timer_cb, 0);

	return 0;
}

void lima_pp_pipe_fini(struct lima_device *dev)
{
	struct lima_sched_pipe *pipe = dev->pipe + lima_pipe_pp;

	/* [LOCAL] completion watchdog */
	timer_delete_sync(&pipe->done_timer);

	if (!--lima_pp_task_slab_refcnt) {
		kmem_cache_destroy(lima_pp_task_slab);
		lima_pp_task_slab = NULL;
	}
}
