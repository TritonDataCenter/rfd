---
author: Dan McDonald <danmcd@mnx.io>
state: predraft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+184%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2023 MNX Cloud, Inc.
-->

# RFD 184 VMM Memory Reservoir Use by SmartOS and Triton


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

<XXX KEBE ASKS -- Subsection "HAZARDS" and "TRADE-OFFS"?  Or keep as-is?>

### HAZARD: Available Machine Memory and Other Consumers

The VMM reservoir design currently assigns all physical memory discounted by
120% of the unlockable pages count as POSSIBLY available for the reservoir.
The remaining amount MAY be insufficient for normal machine operations.

Examples of surprise memory consumers include:

- ZFS Adaptive Replacement Cache (ARC)

- Device driver preallocation of DMA memory, often at initialization
  time. (The `i40e`(4D) driver is a good example, where a lot of VNICs can
  eat a lot of memory.)

- XXX KEBE ASKS MORE?

This hazard will need to be addressed by two of the tradeoffs below.

### HAZARD: Newly Created BHYVE VMs

Today, SmartOS never has its BHYVE VMs use the reservoir.  The current design
of BHYVE is IF reservoir usages is specified in bhyve's configuration, it
will have all kernel memory allocation use the reservoir.  If the reservoir
allocation fails, the bhyve process exits.

Given dynamic machine assignments, we MAY wish to have newly-created VMs
first allocate reservoir space before launching with reservoir.  If we do
that, then if allocation fails we can either error out or proceed without
reservoir use.  Even if we succeed, there is a chance of a concurrent VM boot
racing us to boot.  In such race cases, one may get the reservoir and one may
not, in which case both may continue.

### HAZARD: Triton BHYVE VM Creation And Assignment

For creating BHYVE VMs with Triton's VMAPI, we must make sure that we are not
overprovisioning a compute node.  VMAPI and CNAPI don't allow
overprovisioning, but today it does not take into account the other-consumer
hazards mentioned earlier.  A few large BHYVE VMs with a large number of
small native or LX zones on a i40e(4D) machine may cause memory exhaustion
rather quickly.

### TRADE-OFF: Parameterizing Machine Memory for Reservoir Use in Triton CNs

At the end of the day the reservoir sets aside guaranteed-for-BHYVE-VM
memory.  It means a BHYVE VM does not need to wait for ARC to clear, nor for
other memory reclamation to take place.  The only re

## Proposed solution


