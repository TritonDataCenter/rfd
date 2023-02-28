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

### HAZARD: Available Machine Memory and Other Consumers

### HAZARD: Newly Created BHYVE VMs

### HAZARD: Concurrent BHYVE Creation or Boot (fold in with ^^^?)

### HAZARD: Triton BHYVE VM Creation And Assignment

### TRADE-OFF: Selective Enablement of Reservoir Use

### TRADE-OFF: Percentage of Machine Memory for Reservoir Use in Triton CNs

## Proposed solution


