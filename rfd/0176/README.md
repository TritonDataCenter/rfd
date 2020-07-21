---
authors: Mike Gerdts <mike.gerdts@joyent.com>, Dan McDonald
<danmcd@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+176%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc
-->

# RFD 176 SmartOS and Triton boot from ZFS pool

This RFD describes how SmartOS standalone machines, Triton compute nodes, and
Triton head nodes may opt to boot from a ZFS pool, including the `zones` pool
if desired, without the need for USB flash drives or other removable media.

(Special thanks to Toomas Soome for illumos loader help.)

## Problem statement

SmartOS runs from a ramdisk which is typically loaded from removable media
(USB, virtual CDROM, etc.) or the network via iPXE.  Since Triton head nodes
cannot boot the booter zone that is hosted on itself, head nodes must also
boot from removable media; the same holds true for standalone SmartOS.  While
Triton compute nodes are likely to support PXE, some PXE implementations do
not cooperate with the PXE-to-iPXE chainloading support in modern Triton
booter zones.  For this reason, compute nodes commonly use a USB flash drive
solely to run iPXE.

The reliance on USB flash drives is problematic in the following ways:

* In third-party hosting environments (e.g. Metal as a Service), it may be
  impossible or impractical to insert a USB drive into a machine's USB slot.
* Some third-party hosting environment have USB or ISO over IPMI, but the
  bandwidth in those cases is slow.  (One user quoted a 4-hour SmartOS
  installation time from an IPMI-mounted ISO.)
* A USB stick becomes a single point of failure.  If it fails, the compute node
  or head node that is using it is unable to boot.

### What this problem is not

This RFD does NOT propose the elimination of a ramdisk root, or otherwise
breaking the SmartOS root filesystem architecture.  One way to look at this
is to say that we're putting the "removable media" on to a hard drive, for
better reliability, OR to more readily access Metal as a Service machines.

## Proposed solution

The proposed solution is to boot SmartOS, or even just iPXE, from a ZFS pool,
including the possibility of the disks that make up the system pool (`zones`).

There are two distinct scenarios to cover:

1. Network boot with iPXE, where iPXE comes off of the disk.
2. Boot from an image stored in the system pool

There are a couple dimensions to each of those:

1. BIOS boot
2. UEFI boot

### Network boot with BIOS off of a pool

In this scenario, the boot process is:

1. Hardware loads master boot record (MBR) from a boot disk.
2. The code in the MBR executes the illumos loader from the ZFS boot
   filesystem - named in the pool's `bootfs` property, on that same disk.
   All subsequent boot-time files are loaded from the ZFS boot filesystem.
3. This includes its configuration from `loader.conf`, which will direct
   loader to boot the iPXE program and use the iPXE boot archive, as the USB
   stick version does.

### Local boot with BIOS

In this scenario, the boot process is:

1. Hardware loads master boot record (MBR) from a boot disk.
2. The code in the MBR executes the illumos loader from the ZFS boot
   filesystem - named in the pool's `bootfs` property, on that same disk.
   All subsequent boot-time files are loaded from the ZFS boot filesystem.
3. The illumos loader loads its configuration from `loader.conf`.  Unlike
   other illumos distributions where "/" is the `bootfs`, SmartOS will
   continue to use the ramdisk root extracted from the boot archive.  The
   illumos loader can maintain the ramdisk by having a `loader.conf` line
   specifying `fstype="ufs"`.  The boot archive is a UFS data stream loaded
   onto a ramdisk, which SmartOS uses by default.

### Network boot with UEFI

In this scenario, the boot process is:

1. Hardware loads ipxe from the EFI System Partition (ESP), which is moved
   in as the ESP's `/efi/boot/bootx64.efi` file.
2. iPXE then performs a network boot as a USB stick version would.

Alternatively, a similar-to-BIOS situation can occur:

1. Hardware loads the illumos loader from the EFI System Partition (ESP).
   The EFI version of loader appears as `loader64.efi` and needs to be placed
   in the ESP's `/efi/boot/bootx64.efi` file.
2. The network boot proceeds as it does in the network boot with BIOS
   scenario's step 3.

### Local boot with UEFI

In this scenario, the boot process is:

1. Hardware loads the illumos loader from the EFI System Partition (ESP).
   The EFI version of loader appears as `loader64.efi` and needs to be placed
   in the ESP's `/efi/boot/bootx64.efi` file.
2. The local boot proceeds as it does in the local boot with BIOS scenario's
   step 3: the `fstype="ufs"` line is required in `loader.conf`.

## Three Phase Implementation

We propose three phases for complete implementation of this RFD:

### Phase I - Standalone SmartOS

The first step is to allow standalone SmartOS installations (i.e. non-Triton
ones) to boot off of a ZFS pool.  That pool can either be the `zones` pool,
or one or more dedicated boot pools.

The SmartOS USB/ISO installer must be able to create a bootable zones pool,
or detect a `standalone` pool created during manual-pool-configuration, and
install the Platform Image and Boot Image on to the pool's `boot`
filesystem.

Additionally a new command, `piadm`(1M), will administer bootable SmartOS
pools, including:

- Managing a pool's bootability.  This includes enabling or disabling a
  pool's bootability, status-reporting, and updating a MBR and ESP on disks.

- Managing Platform Images, and their accompanying Boot Images if available,
  on a bootable pool.  This includes status-reporting, installation, and
  removal.

### Phase II - USB-less Triton Compute Node

Experiments have shown that Triton's booter zone CAN chainload from normal
PXE into booter-zone-provided iPXE.  The current consensus, however, is that
not all PXE implementations handle the chainload correctly.

An alternative would be to enhance `piadm`(1M) from Phase I to install an
iPXE-off-disk boot.  One option is to directly install the iPXE binary in the
ESP if the both pool has an ESP AND the compute node uses EFI boot.  The
other option, which allows a pool to be bootable on either EFI or BIOS, is to
have loader load off the ZFS boot pool like Standalone SmartOS, but then load
iPXE instead of unix/SmartOS.

Both PXE to iPXE chainloading, AND on-disk iPXE have been tested on
BIOS-bootable systems. iPXE in the ESP has been tested on an EFI-bootable
VMware VM.  A modern platform image and iPXE must be used on ESP resident
iPXE, due to bugs found during testing.

### Phase III -- USB-less Triton Head Node

THIS is the tricky part, and requires Phase I to be finished at least.  This
section MAY require a distinct RFD, and resolving that will keep this RFD in
predraft state for now.


## Specific problems to solve

### Disk add/replace

When `zpool add` or `zpool replace` happens, zfs already will rewrite boot
blocks under certain circumstances.  Those circumstances will need to change
and perhaps there will need to be changes in what is written to the various
boot areas.

Even if a newly-deployed Triton system had a dedicated disk or disk-pair for
booting (as opposed to embedding in the default `zones` pool), SOMETHING
needs to ensure that when disks are replaced, the replacements also get the
boot sectors.

The zfs resilvering code takes care of data that is within ZFS, but does not
do it for the MBR, ESP, or zfs boot area. In other distributions (i.e. ones
who have / on an actual ZFS filesystem), pools created with zpool create -B
will have things set up in a way that disk replacement triggers something
along the lines of `bootadm install-bootloader` or as a side-effect of the
`beadm` command. The actual solution will need to see what's available, and
if it is sufficient.

The Phase I `piadm`(1M) command has a `piadm bootable -r $POOL` which will
ensure disks in the pool have updated MBR and ESP for standalone SmartOS.

### EFI system partition

This scheme implies that in the face of EFI boot, any bootable disks will
need to have an EFI system partition (ESP).  An EFI system partition is not
currently present in any pool because we don't expect to boot from it.  We
would to change the way that disks are partitioned to include a small ESP on
each disk and ensure that ZFS does not disable write caching due to the disk
being partitioned.  The `-B` option to `zpool create` (i.e. `zpool create
-B`) will perform this partitioning by default.

It may be that we want to always create an ESP, even when not using EFI.  In
this case, the MBR would load a boot loader from the FAT file system in the
ESP and the ZFS boot area would not be used.  If the system switches from
BIOS to EFI (perhaps via chassis swap), an EFI boot program in the ESP could
just do the right thing.  If that were the case, `zpool create -B` would
become a new default behavior and `zones` pool creation-time.

Currently, the "zones" pool will not be created with -B by the installer
unless, at install time, the installation requests a bootable zones pool.  If
a system is BIOS bootable, most zones pools DO have the ability to boot via
the MBR into a bootable today.  The Phase I `piadm`(1M) command can enable a
pool to be bootable, even if it's only BIOS-bootable.  The same command can
report on a pool's ability to boot with BIOS, or BIOS and EFI.
