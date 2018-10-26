---
authors: Rob Johnston <rob.johnston@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=RFD+156
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 156 SmartOS/Triton Boot Modernization

This RFD proposes to rework the boot support mechanisms in SmartOS/Triton in
order to better support both current and future hardware platforms.

## Problem Statement

### Outdated Boot Loader (GRUB)

Currently SmartOS and Triton use GRUB as the boot loader.  GRUB - an acronym
for GRand Unified Bootloader - is an open-source bootloader that was originally
developed in the mid-90s.  For roughly a decade after its introduction, it was
the de facto bootloader for most Linux distributions and was also the
bootloader for OpenSolaris up until Oracle closed the project.

The original GRUB (commonly referred to as Legacy GRUB) ceased development
with version 0.97 in 2005.  This is the version that SmartOS/Triton currently
uses.  Due to its age, legacy GRUB has a number of limitations including:

- it cannot boot on volumes larger than 2TB
- it only supports the X86 architecture
- it does not support UEFI boot mode

Today SmartOS is able to boot on UEFI-capable systems because these systems
support booting in legacy BIOS mode via a compatibility support module (CSM)
that allows UEFI firmware to provide BIOS services.

However, Intel has announced that its reference implementations will no longer
support booting in legacy BIOS mode via CSM starting in 2020[1].  Thus the
inability of SmartOS to boot in UEFI mode has become particularly acute.

Legacy GRUB was succeeded by GRUB2, which was a complete rewrite that added,
among other things, UEFI support.  Most Linux distributions had transitioned to
GRUB2 by 2007.  Oracle Solaris transitioned to GRUB2 in late 2012.

### Outdated PXE Implementation

PXE - an acronym for Preboot eXecution Environment - is an Intel standard
that defines a firmware mechanism for booting a software image over the
network.  Triton compute nodes boot off from the network using an open-source
implementation of the PXE standard called iPXE[2].

In addition to using an outdated boot loader, the version of iPXE used with 
Triton is based on a fork of iPXE that was last synced with upstream in early
2016.  Thus it does not support network booting on some of the newer network
interfaces, including the Intel Fortville nics, which are the standard onboard
interface on most currently shipping enterprise-level system boards.


## Proposed Solution

### New Boot Loader

Loader is the boot loader introduced by the FreeBSD community.  It was ported
to illumos in September 2016[3] and is now the default boot loader for a number
of illumos distributions such as OpenIndiana and OmniOS.

Like GRUB2, Loader supports UEFI boot and has been successfully ported to
a variety of machine architectures that may be interesting to us in the future
(such as ARM).  

This project proposes to change the USB key boot images that are constructed for
SmartOS/Triton and COAL to use the FreeBSD boot loader (referred to herein as
simply "Loader").

The current USB key image uses the Master Boot Record (MBR) paritioning scheme
with a single partition that spans the entire disk. This partition contains
both the boot loader and the platform image.  In legacy BIOS boot mode, BIOS
reads the first sector of the disk and looks for a magic byte sequence
indicating that this sector contains boot code.  If found, BIOS executes this
code.  Because a disk sector is only 512b, it's not enough to hold a complete
boot loader implementation.  So generally, this sector contains what is known
as a first stage loader, which consists simply of the code needed to mount a
partition on the disk and then execute the actual boot loader.

To accomodate booting in UEFI mode, the partitioning scheme used on the USB key
must be changed to the GUID Partitioning Scheme (GPT)[4].  With GPT, each
partition has a UUID, which denotes the type of partition.  UEFI firmware scans
the partition table and looks for a partition with a UUID that corresponds to
the EFI System Partition (ESP).  This partition must be created and formatted
with a FAT filesystem (typically FAT32).  If found, the UEFI firmware will
mount this partition and search for and execute the executable found at a
well-known location defined by the UEFI specification.  The boot loader is
normally placed in this location.

The UEFI specification reserved the first sector of the drive so that MBR-style
boot code can be installed into it.  This sector is known as the protected MBR
(PMBR) and allows for the same disk to support booting in both legacy BIOS and
UEFI modes.  To continue to support legacy BIOS boot mode, a first stage loader
will be installed into the PMBR.  This code will jump to and execute a second
stage loader (gptzfsboot) that will be intalled into a small boot slice.
gptzfsboot will then mount the root partition and execute the legacy BIOS
version of Loader.

The resulting GPT partitioning layout will look like this:


<pre>
Slice  Type                                                            Size 
0      C12A7328-F81F-11D2-BA4B-00A0C93EC93B (ESP)                      33 MB*
1      6A82CB45-1DD2-11B2-99A6-080020736631 (solaris/illumos boot)      1 MB
2      6A85CF4D-1DD2-11B2-99A6-080020736631 (solaris/illumos root)   rest of disk 
</pre>

* The size of the ESP is still being investigated.  The proposed size of 33 MB was
chosen simply becase that is the smallest PCFS filesystem that mkfs will create
and currently the only thing in the ESP is the boot loader executable, which is
under 2MB.  That said, future platforms may require software to placed into
the ESP in order to update the system board firmware.  So we know some amount
of headroom is required there.

#### Build Tool Changes

The joyent/smartos-live repo contains the following two scripts:

tools/build_iso

tools/images/make_image

The first script is used to build SmartOS boot media (either an ISO or a USB
key image).  The second tool creates empty disk images that are used by tools
in the joyent/sdc-headnode repo to construct Triton and COAL boot images.

These two scripts will be replaced by a new tool (tools/build_image) which
will provide the functionality of both of the above tools.  build_image will
create the boot images to use GPT partitioning and will install Loader to
support both legacy BIOS and UEFI boot modes, as described above.

fdisk(1m) does not support creating/modifying GPT labels. Other CLIs that
can work with GPT labels (like zpool) require something that looks like a disk
device path to be passed to it, in order to work.  However, the only practical
way to expose an image file as disk device is to use labelled LOFI devices,
which are not supported in non-global zones.  Therefore, in order to continue
to allow building smartos-live in a zone, without requiring platform changes,
a new build tool, format_image, will be created which will handle creating the
GPT label when constructing USB images.

The joyent/sdc-headnode repo contains the following scripts which are used to
construct Triton and COAL boot images.  These will be modified to handle the
new partitioning layout.

bin/build-coal-image

bin/build-tar-image

bin/build-usb-image

#### Triton Runtime Changes

The following scripts in joyent/smartos-live will be modified to handle the new
partitioning scheme:

overlay/generic/lib/sdc/config.sh

overlay/generic/lib/svc/method/fs-joyent

Similar changes will be made to the following scripts in joyent/sdc-headnode:

scripts/mount-usb.sh

tools/lib/usbkey.js

The joyent/sdc-headnode and repo contains a number of scripts and commands which
directly modify the boot loader configuration for the purposes of configuring
things like the console settings and which platform image to boot.  These tools
will need to be modified such that they can determine which boot loader the
USB key has installed (GRUB or Loader) and then use the appropriate
bootloader-specific logic to inact the desired configuration change.

The "sdcadm platform" command will also be modified such that it can modify
the Loader configuration.

#### Documentation Changes

The Triton documentation contains a number of sections which include
screenshots of GRUB and/or reference details specific to the GRUB boot loader.
These sections will be modified to include screenshots and documentation
specific to Loader.  At this point, the following docs have been identified as
needing updates:

https://github.com/joyent/triton/blob/master/docs/developer-guide/coal-setup.md

https://docs.joyent.com/private-cloud/install/headnode-installation

https://docs.joyent.com/private-cloud/install/compute-node-setup

### Update iPXE

In order to provide support for booting off of more modern network interfaces,
the Joyent fork of ipxe will be resync'd to the tip of the upstream codebase.

At a minimum, the resulting binary will tested on every network interface used
in a Joyent BOM, to ensure regressions are not introduced.

Once that the resync has been tested, the updated ipxe will then be seeded into
the joyent/sdcboot and joyent/kvm-cmd repos.

### Conversion Tool for OPS

Replacing the USB key in existing systems can be expensive as often the USB key
is installed in an internal slot on the system board and so replacing it
requires powering the system down and opening the chassis up.  While this
project will not require the conversion of USB keys in existing systems, OPS
may want to convert existing USB keys so as to standardize the boot experience
across a fleet.  Therefore, as part of this project, a tool will be developed
to automate the process of converting a USB key to the new format in situ.

## Dependencies

The changes described in the RFD are dependent on various in-flight illumos
changes being worked on by Toomas Soome from the illumos community[5].
Primarily, these changes include:

- Loader fixes related to UEFI boot that have been pulled from upstream
- Kernel changes to provide support for a VGA console during UEFI boot

For the purposes of prototyping the SmartOS and Triton changes described above,
a preliminary set of patches has been pulled from Toomas Soome's loader branch
into a development branch ("uefi") of illumos-joyent.


## Design Constraints

In order to simplify deployment and OPS procedures, the build system should
produce a single USB key image that can support booting in both legacy BIOS and
UEFI modes.

If possible, the build tool changes should not require an updated platform 
image on compute nodes that host build zones.

Triton headnodes must be able to manage a hetergeneous set of compute nodes
where some of them still use MBR/GRUB-based USB keys while others may use the
newer GPT/Loader-based USB keys.

The solution should allow OPS maximum flexibility with respect to determining
when or if to replace/convert the USB key in an existing system to the new
format.


## Planned Testing

Verify ability to create SmartOS ISO images

Verify ability to create SmartOS USB images

Verify SmartOS boots with new USB image in legacy BIOS boot mode

Verify SmartOS boots with new USB image in UEFI boot mode

Verify SmartOS boots with new ISO image in legacy BIOS boot mode in vmware

Verify SmartOS boots with new ISO image in UEFI boot mode in vmware

Verify appearance of Loader over serial line

Verify appearance of Loader over VGA

Verify functionality of Loader menus on SmartOS Image

Verify ability to create proforma disk images

Verify ability to create COAL image under Mac OS X

Verify ability to create COAL image under Linux

Verify ability to create COAL image under SmartOS zone

Verify COAL image boots and initial configuration succeeds

Verify ability to create Triton USB image under Mac OS X

Verify ability to create Triton USB image under Linux

Verify ability to create Triton USB image under SmartOS zone

Verify Triton image boots and initial configuration succeeds

Verify functionality of Loader menus on Triton Image

Verify functionality of sdc-setconsole

Verify functionality of all sdc-usbkey subcommands

Manually verify functionality of all "sdcadm platform" subcommands

Run sdcadm unit tests

Verify Functionality of USB key Conversion tool

Verify no regressions in Triton's ability to manage systems using an
MBR/GRUB-based USB key

Verify ipxe functionality on each network interface used in a Joyent BOM

Verify ability to PXE boot in legacy BIOS boot mode

Verify ability to PXE boot in UEFI boot mode

Verify additional boot modules / DTrace anon tracing


## References

[1] http://www.uefi.org/sites/default/files/resources/Brian_Richardson_Intel_Final.pdf

[2] https://ipxe.org

[3] https://www.openindiana.org/2016/09/28/loader-integration/

[4] https://en.wikipedia.org/wiki/GUID_Partition_Table

[5] https://github.com/tsoome/illumos-gate/tree/loader
