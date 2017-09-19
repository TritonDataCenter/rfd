---
authors: Jerry Jelinek <jerry@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+108%22
---

# RFD 108 Remove Support for the Kernel Memory Cage

## Overview

The support for Memory/CPU dynamic reconfiguration (DR) was first added to
Solaris in the late '90s to support dynamic hardware reconfiguration for some
niche, high-end SPARC platforms. The intention is to allow the addition/removal
of hardware boards containing memory and/or CPUs while the system is running.

This concept is dubious at best for the modern hardware landscape, and certainly
does not apply to the hardware on which illumos will run for the forseeable
future. There is currently a significant amount of code complexity to support
memory/CPU DR, but the hardware that illumos runs on is not suitable for this
style of DR. Ideally we'd remove the support for memory and CPU DR to simplify
the system.

However, there is still one use case where some level of memory and CPU DR is
useful; when an illumos distribution is being run inside a virtual machine.
Some virtualization platforms allow for memory or CPU to be changed while the
guest OS is running.

Given that there is still some interest in maintaining this capability, even
though it is limited in practice, we will instead simply remove support for the
kernel cage. This provides the benefit of simplification in the virtual memory
system and should have no impact for users running on x86 as a guest under
virtualization, since we already do not support dynamically removing memory
on x86.

## Motivation

The primary motivation for this change is to simplify the kernel's virtual
memory code by the removal of the kernel cage.

## Background

The kernel cage is only actually used on SPARC platforms. See these files:

    uts/sun4u/ngdr/io/dr_mem.c
    uts/sun4u/opl/io/dr_mem.c
    uts/sun4u/starcat/os/starcat.c
    uts/sun4u/sunfire/io/ac_stat.c
    uts/sun4/os/memlist.c
    uts/sun4u/io/sbd.c
    uts/sun4u/serengeti/os/serengeti.c
    uts/sun4u/io/sbd_mem.c
    uts/sfmmu/vm/hat_sfmmu.c
    uts/sun4u/starfire/os/starfire.c

The `kcage_on` variable is set by this code path:

    kcage_range_init() -> kcage_init()

However, this path is only called by the `set_platform_cage_params` function
from within SPARC platform-specific code.

The `kcage_on` variable is referenced within the `uts/i86pc/io/dr/dr_mem_acpi.c`
file, but it will never be true.

Within the `uts/i86pc/io/dr/dr_mem_acpi.c` file the `dr_pre_detach_mem`
function returns `-1` and the `dr_detach_mem` function is empty. Because
`dr_pre_detach_mem` returns `-1`, the `dr_detach_mem` and
`dr_post_detach_mem` hooks will never be called and memory cannot be detached.

With respect to FMA, when a memory error is detected, the FMA memory analysis
engine will issue the `FM_IOC_PAGE_RETIRE` ioctl. Within the kernel this
calls `fm_ioctl_page_retire` which in turn calls `page_retire` to blacklist
the single bad page. The kernel cage is never involved in this code path.

Since the entire purpose of the kernel cage is to support DR memory removal, it
is clear that removing the cage is a reasonable approach.

## VM System Changes

The interfaces defined in `uts/common/sys/mem_cage.h` are scattered throughout
the kernel. All of these should be removed.

    extern void kcage_range_init(struct memlist *, kcage_dir_t, pgcnt_t);
    extern int kcage_range_add(pfn_t, pgcnt_t, kcage_dir_t);
    extern int kcage_current_pfn(pfn_t *);
    extern int kcage_range_delete(pfn_t, pgcnt_t);
    extern int kcage_range_delete_post_mem_del(pfn_t, pgcnt_t);
    extern void kcage_recalc_thresholds(void);
    /* Called from vm_pageout.c */
    extern void kcage_cageout_init(void);
    extern void kcage_cageout_wakeup(void);
    /* Called from clock thread in clock.c */
    extern void kcage_tick(void);
    /* Called from vm_pagelist.c */
    extern int kcage_next_range(int, pfn_t, pfn_t, pfn_t *, pfn_t *);
    extern kcage_dir_t kcage_startup_dir;

The `uts/common/os/mem_cage.c` file should be removed. All files which
include `sys/mem_cage.h` will need to be inspected and cleaned up.
In particular, these generic files interact with memory caging:

    uts/common/os/clock.c
    uts/common/os/mem_config.c
    uts/common/os/mem_config_stubs.c
    uts/common/vm/seg_kmem.c
    uts/common/vm/vm_page.c
    uts/common/vm/vm_pagelist.c
    uts/common/os/vm_pageout.c

Within the sun4 code there is a lot to cleanup. In `startup.c` we should remove
`setup_cage_params`. All platform code which calls `set_platform_cage_params`
should be cleaned up.
