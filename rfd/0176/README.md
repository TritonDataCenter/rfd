---
authors: Mike Gerdts <mike.gerdts@joyent.com>, Dan McDonald <danmcd@joyent.com>
state: publish
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+176%22
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

With the commit of
[OS-8198](https://github.com/TritonDataCenter/smartos-live/commit/2c792f83ac6e31db6ee00655a084320e56ca518b),
Phase I is complete.

### Phase II - USB-less Triton Compute Node

Experiments have shown that Triton's booter zone CAN chainload from normal
PXE into booter-zone-provided iPXE.  The current consensus, however, is that
not all PXE implementations handle the chainload correctly.

An alternative would be to enhance `piadm`(1M) from Phase I to install an
iPXE-off-disk boot.  One option is to directly install the iPXE binary in the
ESP if the both pool has an ESP AND the compute node uses EFI boot.  The
other option, which allows a pool to be bootable on either EFI or BIOS, is to
have loader load off the ZFS boot pool like Standalone SmartOS, but then load
iPXE instead of unix/SmartOS.  Because existing USB sticks allow a backup
standalone boot, the latter option (loader off disk, then choice of iPXE or
backup standalone boot) is less of a surprise.

Both PXE to iPXE chainloading, on-disk iPXE, and PXE to provider-iPXE to
Joyent iPXE have been tested on BIOS-bootable (all three) and EFI-bootable
systems (the first two). iPXE in the ESP has additionally been tested on an
EFI-bootable VMware VM.  A modern platform image and iPXE must be used on ESP
resident iPXE, due to bugs found during testing.

Experience with bare-metal providers which provide "custom iPXE" suggests
that a compute node may be best served by chainloading from the provider's
iPXE to a Joyent Triton iPXE.  To avoid endless looping, the Joyent Triton
iPXE may wish to skip network devices that speak with the provider's iPXE,
so it can instead boot from the Triton `admin` network as compute nodes are
supposed to do.

Additionally, new Triton compute nodes should have their `zones` pool attempt
to be ESP-ready if possible.  On a working network-boot system, however,
bootable pools are not required, and if a system is known to work with
network-booting from BIOS or EFI, the pool on that system can be arbitrary.

The commit of
[OS-8206](https://github.com/TritonDataCenter/smartos-live/commit/d2f7462039e2375fb67b961992b8b69439da5681)
addresses iPXE boot from disk specifically for Triton Compute Nodes.  The
commit of
[TRITON-2175](https://github.com/TritonDataCenter/sdc-headnode/commit/6d6b7ae1a5ac0b655b0a6f05d7f3dd0a4a069d59)
addresses the new-Compute-Nodes getting ESP-ready pools if possible. With the
documentation commit of
[TRITON-2202](https://github.com/TritonDataCenter/triton/commit/3f424b6dc37e130de79deaa30bd0d443b60f68b2)Phase
II is now complete.

### Phase III -- USB-less Triton Head Node

#### On Booting a Head Node from a ZFS Pool

After experience from Phases I and II, plus experimenting with a CoaL virtual
machine, we arrived at a fundamental design point for a USB-less Triton head
node:  **The bootable ZFS filesystem MUST serve as the head node's USB key**.

The two interfaces all Triton components use to access USB key information
are:

- `sdc-usbkey`.  This command mounts, unmounts, reports status, updates
  contents, and sets boot variables.
- `/lib/sdc/usb-key.sh` This library provides mount and unmount of the Triton
  USB Key.

Those two interfaces can be altered to ALSO treat a Phase I bootable SmartOS
pool as a "USB Key" for Triton's practical purposes.  The enablement of those
interfaces is done through the setting of the boot parameter
`triton_bootpool`, which is set to the pool that booted the Triton head node.

#### On Installation and Transition

The ability to boot a head node off of a pool is necessary, but not
sufficient.  A head node either needs to be installed to boot from a ZFS
pool, or it needs to be able to transition from a USB key boot into a ZFS
pool boot.

This project will deliver both iPXE and ISO (DVD, given the size) installers.
Various Triton setup scripts will need to act differently in the face of an
installer that does not run from a writeable USB key.  The `triton_installer`
boot parameter will indicate if the installer is an ISO one, or an iPXE one.
An ISO installer will have all of the necessary components on-ISO to install
on the bootable pool's boot filesystem.  The iPXE installer cannot fit the
full Triton contents into it boot archive.  Therefor it will require
additional boot parameters to indicate a downloadable tarfile that contains
the full contents of an ISO installer.  This means it must be reachable from
the same network that serviced the iPXE boot.  Triton's installation sets up
networking prior to actual installation, so such a download can occur at the
appropriate time.

An existing USB-key head node can transition into being a ZFS bootable head
node by use of the Phase I `piadm`(1M) command.  `piadm` will be able to
detect if such a transition can occur (by checking the Triton `gz-tools` are
sufficiently updated). An existing `zones` pool can be used if it can be
enabled to boot SmartOS.  Otherwise, a dedicate boot pool can be created
using a more boot-friendly disk layout.  Invoking `piadm bootable -e
$POOL` will perform the transition, and issue a warning to reboot
immediately.

The commits of TRITON-2188 both in:
[smartos-live](https://github.com/TritonDataCenter/smartos-live/commit/fe68f9f45c5f49e768bd91a9200de1c866e089f8),
[sdc-headnode](https://github.com/TritonDataCenter/sdc-headnode/commit/8ceeeea559ded0fb5c8c5963bd40bb07ff6e880d),
and SmartOS followup
[OS-8261](https://github.com/TritonDataCenter/smartos-live/commit/7784b2913b53b7527db4611b4fe60ae3ca004cd1),
addresses the pool-bootable Triton Head Node.  With the documentation commit
of
[TRITON-2202](https://github.com/TritonDataCenter/triton/commit/3f424b6dc37e130de79deaa30bd0d443b60f68b2)
Phase III is now complete.

## Specific additional problems to solve

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

### Bootable Pool as Triton's USB Key

As mentioned in Phase III, the SmartOS bootable pool also doubles as the
Triton head node USB key.  Per RFD 156, the USB key version reported will
always be '2', as loader is required for this whole project anyway.  Unlike
with USB keys, the filesystem will already be mounted in `/$BOOTPOOL/boot`.
To simulate mounting a USB key, we use lofs(7FS) to mount `/$BOOTPOOL/boot`
on to the standard USB key mount point.  Since unmount works regardless of
filesystem type, we need not modify unmount code.

Also, since ZFS is case-sensitive, we must insure that the proper
capitialization of platform image names occurs (e.g. 20210114T211204Z,
instead of 20210114t211204z).
