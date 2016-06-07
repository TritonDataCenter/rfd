---
authors: Jonathan Perkin <jperkin@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 42 Provide global zone pkgsrc package set

The SmartOS Global Zone is designed to be a mostly read-only environment.  The
operating system is booted as a live image, and directories such as `/etc` and
`/usr` are either read-only or are recreated from the boot image upon each
system start.

This design helps to ensure a consistent environment, provides security
benefits, and allows optimal primary storage layout whilst avoiding issues
around booting from complicated storage configurations.

As the global zone is a minimal environment, users often wish to install
additional software that is not provided by the live image.  Examples include
apcupsd to handle attached UPS, smartctl for SMART diagnostics, or
configuration management systems such as ansible or saltstack to manage their
installed VMs.

However, the global zone is somewhat hostile to the installation of additional
software.  Due to the live image design, many system directories cannot be
written to, and changes to others will be lost on the next boot.  Common
failure modes include:

* User management functions such as `useradd(1M)` fail due to `/etc/shadow`
  being a mount point.
* Modifications to the `smf(5)` database are lost on reboot due to `/etc`
  being a ramdisk.
* Software attempting to install to `/usr/local` will fail as it is a
  read-only mount from the live image.

The official recommendation for users who wish to include additional software
into their global zone is to build their own SmartOS images which include the
extra files and modifications they require.  This will bake their changes into
the live image they boot and ensure they are available.

This however requires a machine capable of building SmartOS, the knowledge to
modify the build process to include their changes, and to continually merge
their work against regular upstream SmartOS changes.  This is often too high a
price to pay just to include a few files, so common alternatives are:

* Install a pkgsrc bootstrap kit into the global zone and use `pkgin` to
  install additional software.
* Build software manually and copy it to `/opt` or one of the other writeable
  and permanent directories.
* Use the `/opt/custom` infrastructure provided by SmartOS to automatically
  configure third-party services on boot.

The first option, installing pkgsrc, is one which many users have chosen, but
is not without drawbacks.  The main issue is that any package installations
which attempt to install users will fail due to the `useradd(1M)` issue
described above, and may leave the pkgdb in an inconsistent state.  Others
include issues around handling `smf(5)`-aware packages, and packages which
have build options which may be incompatible with, or sub-optimal for, a
global zone environment.

This RFD is a proposal to create an additional pkgsrc package set that is
designed for use in a SmartOS global zone, is able to correctly function in
that environment, and is optimised for operators of that environment.
