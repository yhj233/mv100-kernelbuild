/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/* Copyright 2017-2019 Qiang Yu <yuq825@gmail.com> */

#ifndef __LIMA_PP_H__
#define __LIMA_PP_H__

struct lima_ip;
struct lima_device;
struct lima_sched_pipe;

int lima_pp_resume(struct lima_ip *ip);
void lima_pp_suspend(struct lima_ip *ip);
int lima_pp_init(struct lima_ip *ip);
void lima_pp_fini(struct lima_ip *ip);

int lima_pp_bcast_resume(struct lima_ip *ip);
void lima_pp_bcast_suspend(struct lima_ip *ip);
int lima_pp_bcast_init(struct lima_ip *ip);
void lima_pp_bcast_fini(struct lima_ip *ip);

int lima_pp_pipe_init(struct lima_device *dev);
void lima_pp_pipe_fini(struct lima_device *dev);

/*
 * [LOCAL] Completion watchdog hooks.  See the comment on
 * struct lima_sched_pipe::done_timer.  The timer is armed when a PP job is
 * submitted and disarmed when it completes; the callback polls each PP's
 * RENDERING_ACTIVE and accounts any finished-but-unaccounted PP.
 */
void lima_pp_done_timer_arm(struct lima_sched_pipe *pipe);
void lima_pp_done_timer_disarm(struct lima_sched_pipe *pipe);

#endif
