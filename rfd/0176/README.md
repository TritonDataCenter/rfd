---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+176%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc
-->

# RFD 176 SmartOS boot from ZFS pool

This RFD describes how SmartOS compute nodes and head nodes may boot from system
pool (i.e. zones pool) without the need for USB flash drives.

## Problem statement

SmartOS runs from a ramdisk which is typically loaded from removable media (USB,
virtual CDROM, etc.) or the network via iPXE.  Since head nodes cannot boot the
booter zone that is hosted on the headnode, head nodes must boot from removable
media.  While compute nodes are likely to support PXE, few support the
extensions supported by iPXE that Triton requires.  For this reason, compute
nodes commonly use a USB flash drive solely to run iPXE.

The reliance on USB flash drives is problematic in the following ways:

* In third-party hosting environments (e.g. Metal as a Service), it may be
  impossible or impractical to insert a USB drive into a machine's USB slot.
* A USB stick becomes a single point of failure.  If it fails, the compute node
  or head node that is using it is unable to boot.

XXX Why is [chainloading iPXE](http://ipxe.org/howto/chainloading) not
sufficient for CNs?  That is, why would a CN ever need to have a USB drive to
get the ipxe executable?

## Proposed solution

The proposed solution is to boot from the disks that make up the system pool.
There are two distinct scenarios to cover:

1. Network boot with iPXE
2. Boot from an image stored in the system pool

There are a couple dimensions to each of those:

1. BIOS boot
2. UEFI boot

### Network boot with BIOS

In this scenario, the boot process is:

1. Hardware loads master boot record (MBR) from a boot disk
2. The code in the MBR loads iPXE from the ZFS boot area on that same disk
3. iPXE performs a network boot

### Local boot with BIOS

In this scenario, the boot process is:

1. Hardware loads master boot record (MBR) from a boot disk
2. The code in the MBR loads booter from the ZFS boot area on that same disk
3. booter loads its configuration from `loader.conf` (XXX?) in the dataset
   identified by the pool's `bootfs` property.  The `loader.conf` file will
   generally reference files (kernels, ramdisk images, and boot modules) that
   are in that same dataset.

### Network boot with UEFI

In this scenario, the boot process is:

1. Hardware loads ipxe from the system partition.
2. iPXE performs a network boot

### Local boot with UEFI

In this scenario, the boot process is:

1. Hardware loads booter from the system partition.
2. booter loads its configuration from `loader.conf` (XXX?) in the dataset
   identified by the pool's `bootfs` property.  The `loader.conf` file will
   generally reference files (kernels, ramdisk images, and boot modules) that
   are in that same dataset.

## Problems to solve

### CN Setup

How will CN setup work?  It will presumably need to perform a network boot
once, which could be done via
[chainloading](http://ipxe.org/howto/chainloading).  If chainloading is good for
that, why not good for always?

### HN Setup

How will HN setup work?  Presumably a one-time network boot would load the HN
media, which would then but the appropriate boot bits in place.

### Disk add/replace

When `zpool add` or `zpool replace` happens, zfs already will rewrite boot
blocks under certain circumstances.  Those circumstances will need to change and
perhaps there will need to be changes in what is written to the various boot
areas.

### EFI system partition

This scheme implies that in the face of EFI boot, at least a subset of the disks
will need to have an EFI system partition (ESP).  An EFI system partition is not
currently present in any pool because we don't expect to boot from it.  We would
to change the way that disks are partitioned to include a small ESP on each disk
and ensure that ZFS does not disable write caching due to the disk being
partitioned.

It may be that we want to always create an ESP, even when not using EFI.  In
this case, the MBR would load a boot loader from the FAT file system in the ESP
and the ZFS boot area would not be used.  If the system switches from BIOS to
EFI (perhaps via chassis swap), an EFI boot program in the ESP could just do the
right thing.
