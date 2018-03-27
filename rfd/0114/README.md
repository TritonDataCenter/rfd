---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/72
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent
-->

# RFD 114 GPGPU Instance Support in Triton

## Introduction

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

 * New "bhyve" brand
 * Changes to vmadm to support GPGPU instances and new (bhyve) cmdline
   arguments.
 * See also:
   [RFD 121](https://github.com/joyent/rfd/blob/master/rfd/0121/README.md)

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
     * cn-agent
     * mdata
     * vm-agent
 * Infrastructure for building new platform images.
     * new Jenkins agent images?

Other future work specific to "Option B", but not specific to MVP of
provisioning instances would include:

 * amon
 * cmon-agent
 * config-agent
 * firewaller
 * hagfish
 * hermes
 * net-agent

Because we intend to use bhyve rather than KVM, there is some conflation here of
changes for the bhyve brand generally and for the GPGPU instances specifically.
We will be implementing the two together, but intend to do so in such a way that
if we're able to attach PCI devices to non-HVM zones in the future, we should
not need to do much work to support that in the Triton stack.

## Changes to Triton Objects

### sysinfo

The `sysinfo` tool on SmartOS generates a JSON object describing a given Triton
node. The resulting "sysinfo" data is stored in the server objects in CNAPI. In
order to support GPGPU instances, we'll need some way to track what GPGPU
hardware is available on a system and sysinfo is the obvious place. The proposal
here is to add the following fields to sysinfo (example for an NVIDIA "GV100
[Tesla V100 PCIe]" card):

```
{
    ...
    "Assignable Devices" [
        {
            device: "1db4",
            id: "/devices/pci@7b,0/pci8086,6f08@3/pci10b5,8747@0/pci10b5,8747@10/pci10de,1214@0",
            revision: "a1",
            subsystem: "1214",
            subvendor: "10de",
            vendor: "10de"
        },
        ...
    ]
    ...
}
```

The format of the `id` field should be enough to uniquely identify this device
across reboots assuming the physical hardware does not change. Changes in
hardware such as replacing one card with a different card are not handled here.
Those will be assumed for now to require updating all VMs on the CN that are
using the replaced device.

It will be up to the sysinfo tool to determine which devices should be included
in the "Assignable Devices" array.

### CNAPI Sever Objects

In CNAPI, the core abstraction is the "server". Servers include both head nodes
and compute nodes. These server objects already include a "sysinfo" parameter
which, once sysinfo has been modified as described in the previous section, will
include the new "Assignable Devices" property. When sysinfo is updated in CNAPI,
it also maintains other fields. Things like: traits, disk/memory/cpu utilization
and so-forth. This allows consumers of CNAPI to access these parameters without
having to dig into the sysinfo object directly.

#### servers

What is being proposed here is that at the top-level of server objects, we'd add
an `assignable_devices` property which would include a sub-set of the data
available for each of the entries from sysinfo. For the device used as an
example in the previous section, this new server object would look like (eliding
unchanged fields):

```
{
    ...
    "assignable_devices": [
        {
            id: "/devices/pci@7b,0/pci8086,6f08@3/pci10b5,8747@0/pci10b5,8747@10/pci10de,1214@0",
            type: "gpu",
            variant: "NVIDIA_GPU_GEN1"
        }
    ],
    gpus: 1,
    ...
}
```

The "variant" field here is a triton-specific translation of the device, vendor
and revision string into a single value that can be used to reference a specific
GPU configuration.

The variants should be configurable within a given DC and it should only ever be
CNAPI that does translation. Everything else in the APIs (packages, etc.) should
only need to reference devices via variant, type and id. The variant definition
should also include the type (here: "gpu").

You can also see here we've added a `gpus: 1` field. This will simply represent
the count of objects in `assignable_devices` that have type 'gpu'. When a CNAPI
client wishes to find all systems that are capable of hosting any GPU workloads,
they can first query the set of servers that have a non-zero value for gpus and
from there, they can narrow down to the system(s) they're looking for. As a
possible enhancement, we could potentially also add a:

```
{
    ...
    gpus_available: 1,
    ...
}
```

field which takes into account those `assignable_devices` which have already
been assigned. This could make searching easier.

#### servers.vms

CNAPI objects also contain a `vms` property that stores some basic information
about VMs on the server for purposes of placement. Each of these vm objects
currently looks something like:

```
"fb91c72c-8c05-eeeb-c076-f1b5eb132fd0": {
  "uuid": "fb91c72c-8c05-eeeb-c076-f1b5eb132fd0",
  "owner_uuid": "06cfb495-1865-4cc2-a3f6-6d17920dcf7c",
  "quota": 25,
  "max_physical_memory": 1024,
  "zone_state": "installed",
  "state": "stopped",
  "brand": "lx",
  "cpu_cap": 100,
  "last_modified": "2017-12-08T23:54:48.000Z"
},
```

What is being proposed here is that we'd change these objects to add an
(optional) additional field `assigned_devices`. This can actually (when support
is available) be agnostic to brand. So using the LX VM above and the example
device from previous examples, if that were assigned to this LX VM, we'd see:

```
"fb91c72c-8c05-eeeb-c076-f1b5eb132fd0": {
  "assigned_devices": ["/devices/pci@7b,0/pci8086,6f08@3/pci10b5,8747@0/pci10b5,8747@10/pci10de,1214@0"],
  "uuid": "fb91c72c-8c05-eeeb-c076-f1b5eb132fd0",
  "owner_uuid": "06cfb495-1865-4cc2-a3f6-6d17920dcf7c",
  "quota": 25,
  "max_physical_memory": 1024,
  "zone_state": "installed",
  "state": "stopped",
  "brand": "lx",
  "cpu_cap": 100,
  "last_modified": "2017-12-08T23:54:48.000Z"
},
```

which allows someone with the output of `/servers/<server_uuid>` to know which
VM is assigned any of the available devices.

When doing placement of a new GPGPU-using VM, DAPI would need to find a server
with an appropriate device that's not in-use, and the system would need to
reserve that device for the VM as part of the provisioning process.


### CNAPI Endpoints

It's an open question as to whether we should add endpoints to CNAPI (or
elsewhere) for managing variants of devices.


### VM Objects

#### vmadm

At vmadm we'd add an additional `assigned_devices` parameter. The value of this
parameter would be an array of device IDs. Those devices would be attached to
the VM whenever it is booted.

The `assigned_devices` field would also be visible on `vmadm get` looking
something like:

```
{
    ...
    "assigned_devices": ["/devices/pci@7b,0/pci8086,6f08@3/pci10b5,8747@0/pci10b5,8747@10/pci10de,1214@0"],
    ...
}
```

in the VM objects.

In the initial implementation, assigned devices would not be searchable via
`vmadm lookup` or included in the `vmadm list` output, and the devices will not
be able to be modified once the VM is created, but these would be obvious areas
for future enhancement.


#### VMAPI

For existing package parameters, it's possible to call VMAPI with a VM payload
and create a VM with arbitrary parameters. In the case of GPUs the proposal here
is that when a package is specified, no GPGPU parameters can be specified. When
no package is specified, a client will be able to add an `assigned_devices`
field just like the one at vmadm described above.

These will be the only options when creating a GPGPU VM at VMAPI. Either a
package or an `assigned_devices` array. As a future enhancement we may want to
allow specifying a variant in the assigned\_devices array rather than a specific
device id.

When loading VMs from VMAPI, the `assigned_devices` array will be visible,
again matching what one would see with `vmadm`. This field will not initially
be updatable but the ability to modify `assigned_devices` is a logical future
enhancement, though this would require restarting the VM.


#### CNAPI

See the previous section on `servers.vms` for details of how the representation
of VMs at CNAPI would change.

### Packages

All instances in Triton have their parameters defined by a package. As such, in
order to be able to provision instances that have GPGPUs we'll need something in
the packages indicating some number of GPUs.

The proposal here is that a package should contain something like:

```
{
    ...
    devices: {
        "NVIDIA_GPU_GEN1": 1
    }
    ...
}
```

How this will interact with moray and indexes is not yet worked out in detail.

## Open Questions

### Do we need changes to images/image fields?

Since we will be using bhyve rather than KVM, do we need to make any changes to
images? It seems that mostly the existing KVM images can work, so probably not?
Do we want to be able to mark an *image* as requiring GPGPUs?

### How should packages define requirements for GPUs?

See `Packages` section above for some more discussion of the issues here.

### Should device variants be exposed via an API?

For example, CNAPI could have endpoints for managing mappings between device
types and variant names?

### How do we make sure it's safe to use a device that was previously assigned to another customer

When a VM has a device assigned and that VM is deleted, we want to make sure
we've done what's necessary to "clean" the device before it gets assigned to
another VM. Things here might include:

 * resetting firmware
 * zeroing memory
 * making sure that if VM adds a zpool to a disk device it doesn't get imported by the host

### Should we expose location info, and how?

It was pointed out that device location info like:

```
"CPU2 SLOT2"
```

would be helpful to have. Should we include that information for devices in the
sysinfo? If so: how should we gather and display it? If not: should we show it
anywhere?

## Other ideas/things that are being investigated

Since most Triton development is done on systems that do not have GPU hardware,
we'd like to have some mechanism for adding "fake" GPUs that will allow us to
provision instances that claim to have GPUs for purposes of Triton, but don't
actually have GPUs.

## Things that are out of scope

* Changes to Ops' migration scripts (not part of Triton) in order to change
  assigned devices and only migrate where a compatible device is available.


