---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->


# RFD 114 GPGPU Instance Support in Triton

## Introduction

IMPORTANT NOTE: This is a work in progress intended to start discussion. It is
not expected to be anywhere near complete yet. Expect that any aspect of this
document could change.

This RFD exists to discuss the work required to support GPGPU instances in
Triton. For provisioning instances, this includes at least:

 * New package parameter(s) for number of GPUs required by an instance.
 * Modifications to server objects to indicate which GPGPU features are exposed
   by a CN.
 * Modifications to DAPI to take into account GPGPU parameters (if not using
   traits on packages/servers) when making placement decisions.
 * Expose new instance properties at VMAPI and cloudapi (read-only initially)
     * Do we need indexes?
 * New image (imgapi/imgadm) type? How would images be distinguished? (or are
   drivers all the same?)

Additionally, for "Option A":

 * New "bhyve" brand?
 * Changes to vmadm to support GPGPU instances and new (bhyve) cmdline
   arguments.

And additionally, for "Option B":

 * Additional CN type
 * Booter/dhcpd parameters
 * Define how data for VMs should be stored
     * multiple json files?
     * zone filesystem layout
 * Mechanism for identifying GPGPU instances
     * call it vm.brand, even though not zone?
 * Mechanism for passing/applying CN network parameters
 * A solution for managing platform images (sdcadm?)
 * Agent requirements
     * cn-agent (and underlying changes, vmadm? node-vmadm? vminfod?)
     * mdata
     * net-agent
     * ur
     * vm-agent

Other future work specific to "Option B", but not specific to MVP of
provisioning instances would include:

 * amon
 * cmon-agent
 * config-agent
 * firewaller
 * hagfish
 * hermes

\[Additional details to be filled in soon.\]
