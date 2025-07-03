---
authors: Dan McDonald <danmcd@mnx.io>
state: predraft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+185%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2025 MNX Cloud, Inc.
-->

# RFD 185 VMM Memory Reservoir Use by SmartOS and Triton


## Problem statement

The VMM memory reservoir landed in illumos-gate in early 2021 with
[illumos#13833](https://illumos.org/issues/13833), and has been enhanced with
[illumos#15372 - want better sizing interface for vmm
reservoir](https://www.illumos.org/issues/15372).  It allows a reserved pool
of kernel memory for hardware virtual machines (e.g. BHYVE) to allocate
without needing to thrash and fight other kernel memory allocators like the
ZFS ARC.

Currently SmartOS does not attempt to use the memory reservoir, nor does it
signal its availability in a way that can be exploited by Triton.  The unit
of abstraction for use of the VMM reservoir is at bhyve(8) invocation time.
If we wish to use the reservoir, we need to signal at bhyve(8) invocation
whether or not to use it. That signaling will need to percolate up the
SmartOS and Triton stack to one or more of:

- vmadm(8)

- VMAPI

Also, the size of the reservoir for a physical machine is something to be
abstracted up the SmartOS and Triton stack to one or more of:

- GZ configuration (perhaps the `zones` service?).

- CNAPI

Beyond presentation of this new feature, there are several hazards and
trade-offs that must be addressed before it is available to SmartOS or Triton
users.

## Hazards and Trade-offs

### HAZARD: Available Machine Memory and Other Consumers

The VMM reservoir design currently assigns all physical memory discounted by
120% of the unlockable pages count as POSSIBLY available for the reservoir.
The remaining amount MAY be insufficient for normal machine operations.

Examples of surprise memory consumers include:

- ZFS Adaptive Replacement Cache (ARC)

- Device driver preallocation of DMA memory, often at initialization
  time. (The `i40e`(4D) driver is a good example, where a lot of VNICs can
  eat a lot of memory.)

Any design will need to consider this hazard.

### HAZARD: Newly Created BHYVE VMs

Today, SmartOS never has its BHYVE VMs use the reservoir.  The current design
of BHYVE is IF reservoir usages is specified in bhyve's configuration, it
will have all kernel memory allocation use the reservoir.  If the reservoir
allocation fails, the bhyve process exits.

Given dynamic machine assignments, we MAY wish to have newly-created VMs
first check reservoir space before launching with reservoir.  If we do that,
then if the check fails we can either error out or proceed without reservoir
use.  Even if we succeed in the check, there is a chance of a concurrent VM
boot racing us to boot (see below).  In such race cases, one may get the
reservoir and one may not, in which case both may continue, or one may fail
if both think reservoir is available to them.

### HAZARD: Triton BHYVE VM Creation And Assignment

For creating BHYVE VMs with Triton's VMAPI, we must make sure that we are not
overprovisioning a compute node.  VMAPI and CNAPI don't allow
overprovisioning, but today it does not take into account the other-consumer
hazards mentioned earlier.  A few large BHYVE VMs with a large number of
small native or LX zones on a i40e(4D) machine may cause memory exhaustion
rather quickly.

### TRADE-OFF: bhyve failure if using reservoir

In SmartOS, the zhyve command launches bhyve as the zone's init(8) process.
zhyve can enable/disable use of the reservoir on a bhyve invocation.  The
tricky part comes if bhyve fails to launch because in spite of any zhyve
checking, the reservoir becomes unavailable.  We need to determine if bhyve
failure should cause a relaunch of zhyve with an automatic downgrade to
no-resevoir, or if it should outright fail, and let the administrator make a
decision on what to do.

## Proposed solution

Rough outline:

- Boot-time tunable for setting the reservoir (can be adjusted using
  /usr/lib/rsrvrctl).  Probably stored in zones SMF configuration somewhere.
  Default to 75% of the max-reported available-for-reservoir RAM by the vmm
  subsystem.

- zhyve will do a propolis-style query of the reservoir, and set the
  use-reservoir configuration accordingly before launching bhyve.

- If launching fails, zhyve will just outright fail, like any other time.

