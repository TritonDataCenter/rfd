---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: draft
discussion: 'https://github.com/joyent/rfd/issues?q=%22RFD+154%22'
---
<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc
-->

# RFD 154 Flexible disk space for bhyve VMs

This document includes a proposal for how to allow a VM to flexibly allocate space to any of 1 or more virtual disks, snapshots of those disks, and/or free space that may be put to use at a future time.

<!-- toc -->

- [Problem statement](#problem-statement)
- [Solution](#solution)
  * [CloudAPI](#cloudapi)
    + [`CreateMachine`](#createmachine)
    + [`GetMachineDisks`](#getmachinedisks)
    + [`ResizeMachineDisk`](#resizemachinedisk)
    + [`CreateMachineDisk`](#createmachinedisk)
    + [`DeleteMachineDisk`](#deletemachinedisk)
  * [Package Changes](#package-changes)
    + [Package `flexible_disk` attribute](#package-flexible_disk-attribute)
    + [Default disks in package](#default-disks-in-package)
  * [Triton CLI changes](#triton-cli-changes)
    + [`triton instance create` options](#triton-instance-create-options)
    + [`triton instance disks`](#triton-instance-disks)
    + [`triton instance disk create`](#triton-instance-disk-create)
    + [`triton instance disk delete`](#triton-instance-disk-delete)
    + [`triton instance disk resize`](#triton-instance-disk-resize)
  * [VMAPI changes](#vmapi-changes)
    + [`GetVm disks`](#getvm-disks)
    + [`CreateVmDisk`](#createvmdisk)
    + [`ResizeVmDisk`](#resizevmdisk)
    + [`DeleteVmDisk`](#deletevmdisk)
  * [Platform Image changes](#platform-image-changes)
    + [`VM.js`: overriding image size in payload](#vmjs-overriding-image-size-in-payload)
    + [`VM.js`: Resize with `update_disks`](#vmjs-resize-with-update_disks)
    + [`VM.js` PCI slot assignment for disks](#vmjs-pci-slot-assignment-for-disks)
    + [Keeping track of space](#keeping-track-of-space)
      - [How much space can be allocated to a new or grown disk?](#how-much-space-can-be-allocated-to-a-new-or-grown-disk)
      - [Calculation of ZFS space](#calculation-of-zfs-space)
    + [Platform limitations](#platform-limitations)
  * [Guest Support for Resize](#guest-support-for-resize)
    + [Guests that use cloud-init](#guests-that-use-cloud-init)
    + [Windows Guests](#windows-guests)
- [Other considerations](#other-considerations)
  * [Keep images small to minimize gratis space](#keep-images-small-to-minimize-gratis-space)
  * [Relation to snapshots](#relation-to-snapshots)
  * [Relation to VM resize](#relation-to-vm-resize)
- [Development Phases](#development-phases)
  * [Phase 1: Platform](#phase-1-platform)
  * [Phase 2: CloudAPI](#phase-2-cloudapi)
  * [Phase 3: CLI changes](#phase-3-cli-changes)
  * [Phase 4: AdminUI and User Portal Updates](#phase-4-adminui-and-user-portal-updates)

<!-- tocstop -->

# Problem statement

Customers are demanding flexibility in how disk space is allocated to VMs. In particular:

* The image size is not sufficiently large to handle the amount of data that must be placed into the boot disk. This leads to ad-hoc resizes later using SmartOS and guest OS tools or the creation of custom images that differ from stock images only in their size.
* Some customers see no value in splitting space between the root disk and the data disk. Rather, this causes extra work because it forces application configurations to be customized to use non-standard paths and/or causes confusion for users. These customers tend to request that all space is allocated to the boot disk.
* Customers that snapshot VMs are likely to need "snapshot space" to allow snapshots of disks that have had a significant amount of data written to them. See RFD 148.

Additionally, customers that may be transitioning from LX to bhyve may have an easier transition without having space fragmented across the root and data file systems.

# Solution

**Flexible disk packages** are introduced. An instance that is associated with a flexible disk package is known as a **flexible disk instance**. A flexible disk instance may have a variable number of disks, the disks may be resized during or after provisioning, and non-boot disks may be added or removed. Disk space that is reserved for an instance but not used by a disk may be used by snapshots of the instance's disks.

If a package is not a flexible disk package, the changes described in this RFD do not apply to a VM using that package.

An instance that is not a flexible disk instance may become a flexible disk instance by being resized into a flexible disk package.

To support flexible disks, changes are required in packages, CloudAPI, AdminUI, the User Portal, and the platform. Full realization of the benefits will require actions within guests. These in-guest changes may be accomplished through in-image automation and/or instance-specific procedures.

These changes are explained in detail below.

## CloudAPI

CloudAPI will be enhanced to allow various attributes of any number of disks to be specified at instance creation time. Most importantly, the size of each disk may be specified, subject to the size limit imposed by the package. Disks may be resized, added, and deleted.

This new functionality will be added with CloudAPI version 9.x.y

### `CreateMachine`

[`CreateMachine`](https://apidocs.joyent.com/cloudapi/#CreateMachine) may pass disk quantity and size information. If `disks` input is not present and the package does not specify `disks`, traditional behavior is preserved. The `CreateMachine` documentation will be updated with:

> **Inputs**
>
> | Field | Type | Description |
> | ----- | ---- | ----------- |
> | disks | Array | A list of objects representing disks to provision. New in CloudAPI 9.x.y. Each disk may specify the attributes described in the inputs to `CreateMachineDisk`. If the first disk (the boot disk) does not specify `size`, the `image` must be defined and the size of the image will be used. |
>
> **disks**
>
> New in API version 9.x.y. The use of `disks` is only supported if the package has [flexible disk support enabled](XXX link). The `disks` input parameter allows the user to specify a list of disks to provision for the new machine. The first disk is the boot disk. A maximum of 8 disks per VM are supported.
>
> ```json
> {
>   "package": "c4fa76e0-6178-ec20-b64a-e5567f3d62d5",
>   "image": "aa788e1f-e143-c46e-9417-b4212486c4ae",
>   "disks": [
>     {
>     },
>     {
>       "size": 20480
>     },
>     {
>       "size": "remaining"
>     }
>   ]
> }
> ```
>
> If the `disks` object is not specified, but `packages.disks` is specified, the storage configuration from the package is used. If neither `disks` nor `packages.disks` are specified, two disks are created. The size of the first disk size will match the image size. The second disk will consume the remainder of the space allowed by the package.
>
> **Returns**
>
> | Field | Type | Description |
> | ----- | ---- | ----------- |
> | image | String | The image UUID used when provisioning the root disk |
> | disks | Array[Object] | (v9.x.y+) One disk object per disk in the VM. See `GetMachineDisks` for details. |

Suppose the example input above is used with this package for the boot disk:

```json
{
  "default": false,
  "description": "Compute Optimized bhyve 3.75G RAM - 2 vCPUs - 100 GB Disk",
  "disk": 102400,
  "group": "Compute Optimized bhyve",
  "id": "c4fa76e0-6178-ec20-b64a-e5567f3d62d5",
  "lwps": 4000,
  "memory": 3840,
  "name": "b4-highcpu-bhyve-3.75g",
  "swap": 15360,
  "vcpus": 2,
}
```

This will lead to the following `disks` in the `vmadm` payload:

```json
{
  ...,
  "disks": [
    {
      "image_uuid": "aa788e1f-e143-c46e-9417-b4212486c4ae",
      "boot": true,
      ...
    },
    {
      "size": 20480,
      ...
    }
    {
      "size": 81920,
      ...
    }
  ],
  ...,
```

### `GetMachineDisks`

`GetMachineDisks` will be added, with the following CloudAPI documentation.

> **GetMachineDisks (POST /:login/machines/:id/disks)**
>
> Gets the details of a virtual machine's disks and unallocated disk space. Only supported with bhyve VMs. New in CloudAPI 9.x.y.
>
> **Inputs**
>
> None.
>
> **Returns**
>
> | Field | Type | Description |
> | ----- | ---- | ----------- |
> | disks | Array | An array of disk objects. Each disk object is described in a table below. |
> | total\_space | Number | Maximum size in mebibytes available to the VM for disks and snapshots of those disks. This value will match the package's `disk` value. |
> | free\_space | Number | Size in mebibytes of space that is not allocated to disks nor in use by snapshots of those disks. If snapshots are present, writes to disks may reduce this value. |
> | flexible | Boolean | Does this machine use the [flexible disk space](XXX link) feature? |
>
> Each disk object has the following fields:
>
> | Field | Type | Description |
> | ----- | ---- | ----------- |
> | slot  | String | An indentifier that describes where this disk is attached to the VM. (`disk0`, `disk1`, ..., `disk7`)
> | boot  | Boolean | Is this disk the boot disk? |
> | image | UUID | The image from which this disk was created |
> | size  | Number | The size of the disk in mebibytes |
> | snapshot\_size | Number | The amount of space in mebibytes used by all snapshots of this disk |

### `ResizeMachineDisk`

`ResizeMachineDisk` will be added, with the following CloudAPI documentation.

> **ResizeMachineDisk (POST /:login/machines/:id/disks/:slot?action=resize)**
>
> Resizes a VM's disk. Only supported with bhyve instances that use the [flexible disk space](XXX link) feature. New in CloudAPI 9.x.y.
>
> While the ability to shrink disks is offered, its purpose is to recover from accidental growth of the wrong disk. Shrinking a disk preserves the first part of the disk, permanently discarding the end of the disk. VM snapshots offer no protection against accidental shrinkage. If a file system within the VM has been grown to use the new space after accidental growth, shrinking the disk will result in file system corruption and data loss.
>
**XXX should deletion protection also protect against truncating disks? This would be useful for providing oversight if RBAC allowed `ResizeMachineDisk` but did not allow `DisableMachineDeletionProtection`.**
>
> **Inputs**
>
> | Field | Type | Description |
> | ----- | ---- | ----------- |
> | size  | Number | New size in mebibytes |
> | dangerous\_allow\_shrink | Boolean | If set to true the disk may be resized to a smaller size. If unset or set to false, an attempt to shrink the disk will result in an InvalidArgument error. **WARNING: setting this to true while specifying a size smaller than the current disk size will cause permanent data loss at the end of the disk. Snapshots offer no protection.** |
>
> **Returns**
>
> None.
>
> **Errors**
>
> For general errors, see CloudAPI HTTP Responses. Specific errors for this endpoint are:
>
> | Error Code | Description |
> | ---------- | ----------- |
> | InvalidArgument | `size` was specified such that it would shrink the disk but `dangerous_allow_shrink` was not set to true. |
> | InsufficientSpace | There is not sufficient `free_space` (see `GetMachineDisks`) to grow the disk to specified size. |

### `CreateMachineDisk`

`CreateMachineDisk` will be added, with the following CloudAPI documentation.
>
> **CreateMachineDisk (POST /:login/machines/:id/disks)**
>
> Creates a VM's disk. Only supported with bhyve instances that use the [flexible disk space](XXX link) feature. New in CloudAPI 9.x.y.
>
> **Inputs**
>
> | Field | Type | Description |
> | ----- | ---- | ----------- |
> | size  | Number or String | The size in mebibytes of the disk or the string `remaining`. If `size` is `remaining` the remainder of the VM's disk space is allocated to this disk. |
>
> **Returns**
>
> None.
>
> **Errors**
>
> For general errors, see CloudAPI HTTP Responses. Specific errors for this endpoint are:
>
> | Error Code | Description |
> | ---------- | ----------- |
> | InsufficientSpace | There is not sufficient `free_space` (see `GetMachineDisks`) to grow the disk to specified size. |

### `DeleteMachineDisk`

`DeleteMachineDisk` will be added, with the following CloudAPI documentation.

**XXX should deletion protection also protect against deleting disks? This would be useful for providing oversight if RBAC allowed `DeleteMachineDisk` but did not allow `DisableMachineDeletionProtection`.**

> **DeleteMachineDisk (POST /:login/machines/:id/disks/:slot)**
>
> Deletes a VM's disk. Only supported to remove data disks (disks other than the boot disk) from bhyve instances that use the [flexible disk space](XXX link) feature. New in CloudAPI 9.x.y.
>
> **Inputs**
>
> None.
>
> **Returns**
>
> None.
>
> **Errors**
>
> For general errors, see CloudAPI HTTP Responses. Specific errors for this endpoint are:
>
> | Error Code | Description |
> | ---------- | ----------- |
> | InvalidArgument | `:slot` belongs to the boot disk or no matching disk found. |

## Package Changes

### Package `flexible_disk` attribute

Packages will gain an optional `flexible_disk` attribute. If set to `true` the package's `disk` attribute (aka `quota`) reflects the amount of space available for all disks. Consider the following packages:

**Inflexible package**
```
{
  ...,
  "disk": 102400,
  ...,
}
```

**Flexible package**
```
{
  ...,
  "disk": 102400,
  "flexible_disk": true,
  ...,
}
```

The following table outlines the results when used with various images.

| Image size | Inflexible boot disk size | Inflexible data disk size | Flexible boot disk size | Flexible data disk size |
| --------| ------- | ------- | ------- | ------- |
| 10 GiB  | 10 GiB  | 100 GiB | 10 GiB  | 90 GiB  |
| 90 GiB  | 90 GiB  | 100 GiB | 90 GiB  | 10 GiB  |
| 1 TiB   | 1 TiB   | 100 GiB | Error   | Error   |

### Default disks in package

A flexible disk package may specify the default size for disks. These sizes can be overridden by `disks` in a `CreateMachine` call.

In this example, any image smaller than 102400 MiB is resized to occupy all of the instance's disk space (102400 MiB).

```
{
  ...,
  "disk": 102400,
  "flexible_disk": true,
  "disks": [ { "size": "remaining" } ],
  ...,
}
```

In this example, all space not allocated to the image remains free for future disk allocations and snapshots.

```
{
  ...,
  "disk": 102400,
  "flexible_disk": true,
  "disks": [ { } ],
  ...,
}
```

## Triton CLI changes

Various `triton instance` commands will be changed and/or added to mirror the CloudAPI changes.

**XXX in these we use "name" instead of "slot".  I'm conflicted as to which one we should use.**

### `triton instance create` options

Disks may be specified with the new `--disks` option, described in `triton instance create --help` as:

```
    --disks=DATA
                Configure disks in a flexible disk instance. DATA is a JSON
                object (if the first character is "{"} or "@FILE" to have disks
                loaded from FILE.
```

### `triton instance disks`

Show an instance's disks, described in `triton instance disks --help` as:

```
Show the disks that belong to an instance.

Usage:
    triton instance disks [OPTIONS] INST

Options:
    -h, --help          Show this help.

  Output options
    -H                  Omit table header row.
    -o field1,...       Specify fields (columns) to output.
    -l, --long          Long/wider output. Ignored if "-o ..." is used.
    -s field1,...       Sort on the given fields. Default is "name".
    -j, --json          JSON output.

Where "INST" is an instance name, id, or short id.
```

An example of the default output is:

```
NAME  SIZE
disk0 10240
disk1 92160
```

The JSON output is as shown in `GetMachineDisks`.

### `triton instance disk create`

A new disk may be added to a flexible disk instance `disk add`, described in `triton instance disk add --help` as:

```
Add a disk to a flexible disk instance.

Usage:
    triton instance disk add [OPTIONS] INST SIZE

Options:
    -h, --help           Show this help.
    -w, --wait           Block until instance state indicates the action is
                         complete.

Arguments:
    INST        Instance name, id, or short id
    SIZE        Size in mebibytes
```

### `triton instance disk delete`

A disk may be removed from a flexible disk instance with `disk delete`, described in `triton instance disk delete --help` as:

```
Delete a disk from a flexible disk instance.

Usage:
    triton instance disk delete [OPTIONS] INST

Options:
    -h, --help           Show this help.
    -w, --wait           Block until instance state indicates the action is
                         complete.

Where "INST" is an instance name, id, or short id.
```

### `triton instance disk resize`

An existing disk in a flexible disk instance may be resized with `disk resize`, described in `triton instance disk resize --help` as:

```
Resize a disk in a flexible disk instance.

Usage:
    triton instance disk resize [OPTIONS] INST DISK SIZE

Resize options:
    --dangerous-allow-shrink
                         Allows the disk size to be reduced. This will truncate
                         (chop off the end of) the disk. Any data previously
                         written to the truncated area is permanently lost.
                         Snapshots will not be useful to recover from this
                         operation.

Other options:
    -h, --help           Show this help.
    -w, --wait           Block until instance state indicates the action is
                         complete.

Arguments:
    INST        Instance name, id, or short id
    DISK        Disk name, such as "disk0"
    SIZE        Size in mebibytes. If --dangerous-allow-shrink is not also used,
                SIZE must be greater than the current size of the disk.
```

## VMAPI changes

Alonside the changes described here for VMAPI's end-points, there will be required changes
for VMAPI (3 new workflows for disks creation, resize and deletion), modifications of the
create VM workflow if needed, and updates of VMAPI's parameter validations.

#### CNAPI and CN-Agent changes

Additionally, if we can proceed with the new disk related modifications using CNAPI's `VmUpdate`
end-point and the associated CN-AGENT's `machine-update` task, we'll just need to modify these
accordingly. Otherwise, it's possible that the creation of a new CNAPI's end-point and CN-AGENT
task were required, similar to `VmNicsUpdate` and `machine_update_nics` respectively.

#### node-sdc client changes

The VMAPI's client will have new methods to allow creation, resize and removal of
machine disks. See VMAPI's end-points below for more information regarding the available
arguments.

### CreateVM disks

VMAPI's `CreateVM` end-point will accept the new parameter `disks` allowing exactly the same
input than CloudAPI's [`CreateMachine`](#createmachine) described above. This parameter will
be supported only when package used to create the VM has [flexible disk support enabled](XXX link)

### GetVm disks

VMAPI's will not have a [`GetMachineDisks`](#getmachinedisks) end-point like CloudAPI's. Instead,
`GetVm` will always include the `disks` member when present; it's to say, if machine has been
created using `disks` parameter or with a package with [flexible disk support enabled](XXX link)
which will cause the member to appear and be set to the defaults.

It'll be CloudAPI's task to display or not `disks` member depending on the request it's responding to.

### CreateVmDisk (POST /vms/:uuid?action=create_disk)

VMAPI's end-point with exactly the same input than CloudAPI's [`CreateMachineDisk`](#createmachinedisk).

### ResizeVmDisk (POST /vms/:uuid?action=resize_disk)

VMAPI's end-point with exactly the same input than CloudAPI's [`ResizeMachineDisk`](#resizemachinedisk).
Target disk will be referenced by `:slot` parameter (exactly the same way than CloudAPI).

### DeleteVmDisk (POST /vms/:uuid?action=delete_disk)

VMAPI's end-point with exactly the same input than CloudAPI's [`DeleteMachineDisk`](#deletemachinedisk).
Target disk will be referenced by `:slot` parameter (exactly the same way than CloudAPI).


## Platform Image changes

The platform image will be updated in the following areas:

* `disk.*.size` will be supported even when the image is specified.
* `update_disks` will be able to resize disks.
* PCI slot assignments will be sticky so that disk removals do not confuse guests that rely on consistent physical paths to disks.

### `VM.js`: overriding image size in payload

Currently, when a disk is created from an image, the disk size will match the image size. The new behavior will allow `disk.N.size` to specify that the ZFS volume created by cloning the image should be grown to the value specified by `disk.N.size`.

The following `vmadm` payload indicates that the `d4c79fef-da87-48e6-8178-f2357b43c293` image should be used as the boot disk. It will be grown to 200 GiB. There will be no data disk.

```json
{
  ...,
  "disks": [
    {
      "image_uuid": "d4c79fef-da87-48e6-8178-f2357b43c293",
      "size": 204800,
      "boot": true
    }
  ],
  ...,
}
```

### `VM.js`: Resize with `update_disks`

A disk will be growable with `update_disks` in the payload passed to `vmadm update <uuid>`. The following grows a disk to 100 GiB.

```
# vmadm update 926b8205-4b16-6ec4-f9ad-9883a8c84ce1 <<EOF
{
  "update_disks": [
    {
      "path": "/dev/zvol/rdsk/zones/926b8205-4b16-6ec4-f9ad-9883a8c84ce1/disk0",
      "size": 102400
    }
  ]
}
EOF
Successfuly updated 926b8205-4b16-6ec4-f9ad-9883a8c84ce1
```

To prevent a typo from destroying data, disks may only get smaller if `dangerous_allow_shrink` is set to true. Suppose there is a desire to further grow the disk to 200 GiB, but there was an input error.

```
# vmadm update 926b8205-4b16-6ec4-f9ad-9883a8c84ce1 <<EOF
{
  "update_disks": [
    {
      "path": "/dev/zvol/rdsk/zones/926b8205-4b16-6ec4-f9ad-9883a8c84ce1/disk0",
      "size": 20480
    }
  ]
}
EOF
vmadm: ERROR: Can not shrink disk from 102400 MiB to 20480 MiB
```

With `dangerous_allow_shrink` set to true this would be allowed. `dangerous_allow_shrink` is not added to VM's configuration.

```
# vmadm update 926b8205-4b16-6ec4-f9ad-9883a8c84ce1 <<EOF
{
  "update_disks": [
    {
      "path": "/dev/zvol/rdsk/zones/926b8205-4b16-6ec4-f9ad-9883a8c84ce1/disk0",
      "size": 20480,
      "dangrous_allow_shrink": true
    }
  ]
}
EOF
Successfuly updated 926b8205-4b16-6ec4-f9ad-9883a8c84ce1
```

**XXX We may want to limit this to one disk update per call to `vmadm update` so that we can't have partial failures. Alternatively, we could explore using [ZFS channel programs](https://www.delphix.com/blog/delphix-engineering/zfs-channel-programs) to allow multiple updates that are applied atomically. Use of ZFS channel programs is not straight-forward as they do not yet support changing property values, such as `volsize`.**

### `VM.js` PCI slot assignment for disks

The PCI slot for each disk can be specified with `disks.*.pci_slot`, which will correspond to an optional `pci_slot` property in each NIC.

Prior to this change, the boot and data disks were assigned to slot `4:0` and `4:1`, respectively. This comes by happenstance from the order that they appear in the zone configuration. The new allocation scheme will ensure that existing disks remain at the same PCI functions as the historical implementation while allowing disks to remain at their paths in the face of removal. For example:

At provisioning, disk add, or boot time, if a disk does not have a `pci_slot` property, one will be assigned at 0:4:N for disks or 0:3:N for cdroms. The assignment of N will follow the algorithm previously used to allocate pci slots dynamically at boot time.

The goal of this change is to ensure that any guest code that depends on "physical" location is tolerant of device removal. Consider the following example:

After provisioning a VM with three disks, `lspci` may report the following, which correspond to `disk0`, `disk1`, and `disk2`.

```
00:04.0 SCSI storage controller: Red Hat, Inc Virtio block device
00:04.1 SCSI storage controller: Red Hat, Inc Virtio block device
00:04.2 SCSI storage controller: Red Hat, Inc Virtio block device
```

If `disk1` is removed, `lspci` will report:

```
00:04.0 SCSI storage controller: Red Hat, Inc Virtio block device
00:04.2 SCSI storage controller: Red Hat, Inc Virtio block device
```

If a disk is subsequently added and `pci_slot` is not specified, it is assigned to the first empty slot. In the example above, a new disk would default to PCI slot 0:4:1.

### Keeping track of space

The amount of space that a flexible disk instance may use is tracked in the new `VM.flexible_disk_size` attribute and corresponding `flexible-disk-size` zone configuration attribute.

For the sake of clarity in the following subsections, some variables are defined.

| Variable    | Sum of values returned by                             |
| ----------- | ----------------------------------------------------- |
| `DISK_SIZE` | `zfs list -Hpr -t volume -o volsize zones/$UUID`      |
| `DISK_RESV` | `zfs list -Hpr -t volume -o refreserv zones/$UUID`    |
| `DISK_SNAP` | `zfs list -Hpr -t volume -o usedsnap zones/$UUID`     |

The value of `DISK_SNAP` may change as writes occur to a disk. `vmadmd` should make no effort to accurately track this value. Future interfaces should be designed such that this value is queried infrequently - such as only when trying to determine the maximum amount of space that may be allocated to a new disk. No interface should be designed such that this value is retrieved for every instance as a default behavior.

As described in [RFD 148's snapspace](../0148/snapspace.md), ZFS volumes require space for metadata storage. This space is overhead that should not be charged against `VM.flexible_disk_size`.

#### How much space can be allocated to a new or grown disk?

The amount of new disk space that can be allocated is

```
allocatable = VM.flexible_disk_size - DISK_SIZE - DISK_SNAP
```

#### Calculation of ZFS space

As described in [RFD 148's snapspace](../0148/snapspace.md), the zone's top-level ZFS `quota` and `reservation` properties are set to matching values. These ensure that the VM has acccess to all of the space that is allocated to it without being able to consume more space.

The ZFS `quota` and `reservation` properties on the zone's top-level dataset (`zones/<UUID>`) are set to the sum of:

* the VM's `quota` property (see vmadm(1))
* the amount of disk space allocated to the VM by `VM.flexible_disk`.
* the amount of space required by ZFS to store the metadata for all of the VM's disks.

In pseudocode:

```
zfs.reservation = zfs.quota = VM.quota + VM.flexible_disk_size + DISK_RESV - DISK_SIZE
```

The `zfs.quota` and `zfs.reservation` values need to be recalculated in the following circumstances:

* `VM.flexible_disk_size` changes, such as when a VM is asscociated with a different package that has different value for `package.disk`
* A disk is resized
* A disk is added
* A disk is removed

As a reminder, `VM.quota` mirrors `zfs.refquota`, not `zfs.quota`.

### Platform limitations

Bhyve does not support hot-add or remove of devices. As such, the VM must be down when disks are added or removed.

It is likely fairly straight-forward to support resizing of disks without a reboot. See OS-6632.

## Guest Support for Resize

Modern operating systems tend to support the idea that disks may be resized and as such support growing partition tables and file systems. This is true of Ubuntu 16.04 and later, CentOS 7 and later, and Windows Server 2012r2 and later (**XXX verify all of these**).

### Guests that use cloud-init

Joyent's Linux images generally include cloud-init, which has explicit support for resizing the root file system. This support is imperfect because some images do not have the root partition at the end of the disk and cloud-init has no support for moving partitions out of the way. As a concrete example, Ubuntu 18.04 images have a swap partition after the root partition.

There are multiple parts to the solution:

* For images that Joyent creates, ensure that the root partition is at the end of the disk.
* For images that Joyent's partners create (e.g. Ubuntu), provide a user script and documentation that can disable swap, remove the swap partition, grow the partition table, create a swap partition of the same size at the end of the disk, then grow the root partition to occupy the free space.
* Work with Canonical to fix their product such that root disk growth works well out of the box. This could be in the form of putting swap ahead of the root file system or enhancing cloud-init to move swap as described above.

### Windows Guests

[A procedure exists](https://social.technet.microsoft.com/wiki/contents/articles/38036.windows-server-2016-expand-virtual-machine-hard-disk-extend-the-operating-system-drive.aspx) to grow the `C` drive via the GUI. Surely the same can exist for powershell. That powershell script needs to be included in our images.

# Other considerations

There are various other considerations that are relevant to the feature described above. These considerations are about how this feature interacts with other Triton features and operator behavior.

## Keep images small to minimize gratis space

As mentioned above, the disk space consumed by a VM is based on the size of the image and the `disk` size specified in the package. Because billing is attached to a package, two instances that use different images may get a different amount of disk space for the same price.

It is recommended that images are the same size or otherwise limited in their association with packages so that billing abuse does not happen.

## Relation to snapshots

Creation or removal of snapshots will be unaffected by this, aside from the fact that it will be possible to allocate space to a VM that can be reserved for snapshots by not allocating it to disks.

As described in RFD 148, a new snapshot requires enough space to store a copy of every allocated block that is not already referenced by another snapshot. If the `zfs.quota` is not sufficient to allow a new snapshot, there are several choices available which may offer varying degrees of relief.

* Remove existing snapshots
* Remove unused disks
* Resize the VM to a package that has a larger `package.disk`

Simply removing data in an existing disk will not help. This could change if the guest and host disk drivers supported [TRIM](https://en.wikipedia.org/wiki/Trim_(computing)) or similar and this led to ZFS volumes freeing the associated blocks.

## Relation to VM resize

The general rule is that a VM may be resized only to a larger package. That does not necessarily have to be the case. If some amount of `VM.flexible_disk_size` is unused, that space could be taken away from the VM via a VM resize. A VM should be considered a candidate for resize if:

```
DISK_SIZE + DISK_SNAP <= newpackage.disk
```

# Development Phases

The delivery of this functionality can be broken in the following phases.

## Phase 1: Platform

In this phase, the changes required to `VM.js`, `vminfod`, and the bhyve brand are implemented. This ensures that CNs that are rebooted to newer PIs will be ready to use these features as soon as the Triton bits are ready. It will also allow operators to easily resize bhyve VMs.

As part of this phase, at least one guest image that will automatically resize the root disk. Alternatively, a procedure may be documented to accomplish the same.

## Phase 2: CloudAPI

In this phase, CloudAPI will be updated to perform all of the operations described.

## Phase 3: CLI changes

The Triton CLI will be updated to mirror the CloudAPI changes.

## Phase 4: AdminUI and User Portal Updates

Both the AdminUI (operator portal) and the User Portal will require updates to be able to

* Specify disk quantity and sizes during VM creation
* Add disks
* Remove disks
* Resize disks
