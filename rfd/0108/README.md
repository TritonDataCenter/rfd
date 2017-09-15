---
authors: Jerry Jelinek <jerry@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+108%22
---

# RFD 108 Remove Support for Memory/CPU Dynamic Reconfiguration (DR)

## Overview

The support for Memory/CPU DR was first added by Sun in the late '90s to
support dynamic hardware reconfiguration for some niche, high-end SPARC
platforms. The intention is to allow the addition/removal of hardware boards
containing memory and/or CPUs while the system is running.

This concept is dubious at best for the modern hardware landscape, and certainly
does not apply to the hardware on which illumos will run for the forseeable
future.

There is currently a significant amount of code complexity and overhead to
support memory/CPU DR, but the hardware that illumos runs on is not suitable
for this style of DR. Given this, removing the support for DR will simplify and
streamline the core kernel code in ways which will benefit all illumos
derivatives.

## High-Level Changes

### User-Level Commands

The `cfgadm` command is the primary user-interface for DR operations. This
command is still important for some operations, such as disk replacement,
but there is likely some opportunity for cleanup here.

It is also possible that there is opportunity to cleanup some of the
hotplug-related code and the hotplug SMF service.

    cmd/hotplug/*
    cmd/hotplugd/*

### Kernel-Wide Data and Functions

See all usage of `plat_dr_options`, `PLAT_DR_FEATURE_CPU` and
`PLAT_DR_FEATURE_MEMORY`.

The `lgrp` and cross-call code makes use of functions like `plat_dr_support_cpu`
and `plat_dr_support_memory`. This could all be cleaned up.

### Files

At least the following are candidates for removal.

    uts/i86pc/io/acpi/acpidev/acpidev_dr.c
    uts/i86pc/io/acpi/drmach_acpi/drmach_acpi.c
    uts/i86pc/io/dr/dr.c
    uts/i86pc/io/dr/dr_cpu.c
    uts/i86pc/io/dr/dr_mem_acpi.c
    uts/sun4u/ngdr/io/dr.c
    uts/sun4u/ngdr/io/dr_cpu.c
    uts/sun4u/ngdr/io/dr_mem.c
    uts/sun4u/opl/io/dr_mem.c
    uts/sun4u/serengeti/io/sbdp_dr.c
    uts/sun4u/starfire/io/drmach.c
    uts/sun4v/io/dr_cpu.c

At least the following can be trimmed down or removed.

    cmd/acpihpd/notify.c
    cmd/fm/fmd/common/fmd_dr.c
    cmd/picl/plugins/sun4v/mdesc/dr.c
    lib/cfgadm_plugins/sbd/common/ap_sbd.c
    uts/sun4u/serengeti/io/ssm.c

### VM system

The kernel memory cage should be removed. The interfaces defined in
`uts/common/sys/mem_cage.h` are scattered throughout the kernel. All of these
should be removed.

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
