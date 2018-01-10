---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/76
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD XXX bhyve brand

## Introduction

**NOTE**  This is an early draft.  Your feedback and that of others will likely
cause things to change.

For reasons beyond the scope of this document, `bhyve` is needed by SmartOS.  It
is at least an analog for `kvm` and perhaps an outright replacement.  This
document describes the `bhyve` brand, a new zone brand.

## Overview of bhyve

`bhyve` is the name of the user space process that acts as the hypervisor.  It
also uses the `vmm` (virtual machine monitor) and `viona` (VirtIO Network
Adaptor) drivers, which are being introduced with the bhyve project.

The configuration of the virtual hardware is controlled purely through
command-line arguments to the `bhyve` command.  In the prototype implementation,
the command line looks like:

```
/usr/sbin/amd64/bhyve -m 4g -c 2 -l com1,/dev/zconsole -P -H -s 1,lpc \
    -s 3,virtio-blk,/dev/zvol/rdsk/zones/$zone/data/disk0 \
    -s 4,virtio-net-viona,net0 \
    -l bootrom,/BHYVE_UEFI.fd "$zone"
```

That is, the virtual platform has:

- 4 GB of RAM
- 2 virtaul CPUs
- first serial port (ttya, ttyS0, com1) attached to /dev/zconsole
- An LPC PCI-ISA bridge, providing connectivity to com1, com2, and bootrom
- A disk device at PCI 0,3,0
- A network device at PCI 0,4,0
- A boot ROM

The guest OS is installed on the ZFS volume `zones/*zone*/data/disk0` which is
visible within the zone.  `net0` is a vnic configured via a net resource.  The
guest OS uses the MAC address that is specified in the zone's configuration for
that `net` resource.

As `bhyve` starts, the sequence of events is roughly the following and not
necessarily in this order.

- A new virtual machine is created by opening `/dev/vmm/ctl` and issuing a
  `CREATE` `ioctl`.  This results in:
  - Various host kernel resources allocated for the vm
  - RAM for guest memory is allocated and mapped into guest memory
  - Creation of a new `vmm` minor, accessible at `/dev/vmm/<zone>`
- The `/dev/vmm/<zone>` node is opened
- The disk device is opened.
- The `/dev/viona/ctl` node is opened and a `CREATE` ioctl is issued.  This
  creates a new minor that does not require a minor node.  The return value from
  the `ioctl` is a file descriptor associated with the new `viona` minor.
- The boot ROM file is opened and mapped into guest memory.

At this point, the `VMRUN` `ioctl` is issued on the VM's `vmm` device node.  The
guest will begin executing the code in the boot ROM.  From there, the guest OS
runs as it would anywhere else.  Note that since the disk and network devices
are using `virtio`, the guest OS must have `virtio` drivers.  `virtio` drivers
are present in recent versions of common Linux distributions, FreeBSD, and
Windows.

As mentioned above, the first serial port is connected to `/dev/zconsole`.  If
the guest OS attaches its console to its first serial port, `zlogin -C <zone>`
will give access to the guest OS console.  It is possible to attach guest serial
ports to any serial device, to stdio of the bhyve process, or to a special
`bcons` UNIX domain socket.

The `bhyve` command may emit errors to `stderr`, which can be redirected to a
log file.

When the `bhyve` command exits, the kernel state remains present until a
`DESTROY` `ioctl` is issued.  To free these resources, `vmctl --destroy` must be
used.

## Public interfaces

The public interfaces to the `bhyve` brand are via `zonecfg(1M)`, `zoneadm(1M)`,
and `zlogin(1M)`.  A new man page, `bhyve(5)` will be added to describe the
uniqueness of the brand.

### `zonecfg`

The `bhyve` brand places restrictions on several properties and resources, as
described below.

| Scope	| Property	| Notes						|
| ----- | ------------- | --------------------------------------------- |
| global | bootargs	| Ignored					|
| global | fs-allowed	| Not supported.  The zone cannot mount any file system |
| global | ip-type	| Only `exclusive` is supported			|
| global | hostid	| Ignored					|
| dataset | name	| Not supported, at least once [OS-5161](https://jira.joyent.us/browse/OS-5161) is fixed |
| device | match 	| Must match exactly one raw disk device (e.g. in `/dev/rdsk` or `/dev/zvol/rdsk`). |
| fs 	| all		| Not supported					|
| inherit-pkg-dir | all | Not supported				| 

As with the `kvm` brand, properties on `device` and `net` resources as well as
various `attr` resources may impact how the guest runs.  The following table
summarizes the impact.

| Scope | Property	| Notes						|
| ----- | ------------- | --------------------------------------------- |
| device | boot		| Is this the boot device? `true` or `false`	|
| device | model	| See *emulation* in [bhyve(8)](https://www.freebsd.org/cgi/man.cgi?query=bhyve&format=html) |
| device | media	| `hd` for hard drive or `cd` for cdrom		|
| device | image-size	| If the device does not exist during installation, the size that it will be created as, in megabytes (10^6 bytes) |
| device | image-uuid	| XXX - specific to vmadm?			|
| net	| gateway	| XXX I do not yet know how we will do guest network config |
| net	| gateways	| XXX						|
| net	| netmask	| XXX						|
| net	| ip		| XXX						|
| net	| ips		| XXX						|
| net	| model		| See *emulation* in [bhyve(8)](https://www.freebsd.org/cgi/man.cgi?query=bhyve&format=html) |
| net	| primary	| XXX						|
| attr	| resolvers	| XXX still don't know about net configuration	|
| attr	| vcpus		| The number of guest vcpus.			|
| attr	| ram		| Guest memory size in MiB (2^20 bytes)		|

Some of the properties above, and others not mentioned, may be used by `vmadm`.
The interaction between `vmadm` and the brand is beyond the scope of this
document.

**XXX** Future (near future, I hope) work should add new properties or overload
existing properties to make it so that `attr` resources are not needed to
configure things that are fundamental to the brand.  If adding properties and/or
resources that are unique to the brand, we need a mechanism to disable them in
brands where they don't exist.  This is an opportunity to copy Solaris.

### `zoneadm`

The `zoneadm` command supports most of the operations supported with other
brands.  There are exceptions:

- `attach -n` will have no updates.
- `boot` will not support the `-i`, `-m`, or `-s` options.  Boot options after
  `--` are also not supported.
- `move` will not be supported
- `shutdown` will not support `boot_options`

#### `zoneadm install`

Install will only install from some form of media.  This could be a local iso
file, PXE boot, etc.  In particular, we will not support anything like [direct
install](https://docs.oracle.com/cd/E53394_01/html/E54751/gnrjk.html#scrolltoc).
The expected help message is:

```
zoneadm -z <bhyve-zone> install -i <format>,<file> [-c cfgdisk]
zoneadm -z <bhyve-zone> install -b <boot.iso> [-c cfgdisk]
```

In the first form, `-i` specifies the disk image that the host will write to the
device that has a `boot` property with value set to `true`.  Supported formats
are `raw` and `zfs`, either of which may be compressed wtih `gzip`, `bzip2`, or
`xz`.  `zoneadm install` will only install to the boot disk.  For multi-disk
installations, other tools should populate the virtual disks and then use
`zoneadm attach`.

If `-c cfgdisk` is specified, the guest is booted once with the specified
configuration disk attached temporarily.  The configuration disk must be in a
raw disk image in a format that is understood by the guest.

In the second form, `-b` specifices installation media that will be temporarily
attached.  If `-c cfgdisk` is also specified, the configuration disk will also
be attached during the installation boot.  The zone will always transition to
the installed state when the guest halts or reboots.  If the guest installation
fails, this could lead to the zone being in an installed state with a broken
guest installation.

Install will create any missing devices specified by `device` resources.  When
the guest shuts down after the installation boot, the zone transitions to the
`installed` state.

#### `zoneadm attach`

Attach transitions from the configured to the installed state, optionally
performing a configuration boot.

```
zoneadm -z <bhyve-zone> attach [-c cfgdisk]
```

If the `-c cfgdisk` option is used, the zone is booted once with the specified
raw disk image temporarily attached.

#### `zoneadm detach`

Detach transitions from the installed state to the configured state.  No data
inside the zone is altered.

#### `zoneadm clone`

```
zoneadm -z <bhyve-zone> clone [-m copy] [-c cfgdisk]
```

Clone makes a copy of the source zone's boot disk to the new zone.  If a zfs
clone is possible and `-m copy` is not specified, the disk is cloned with `zfs
clone`.  Otherwise, the disk will be cloned with `dd`.  If the new zone's boot
disk already exists, it must be at least as large as the source disk.  Any new
zfs snapshots that are created for the clone will be set to self-destruct (via
`zfs destroy -d <snapshot>`) when no longer needed.

If the `-c cfgdisk` option is used, the zone is booted once with the specified
raw disk image temporarily attached.

#### `zoneadm boot`

```
zoneadm -z <bhyve-zone> boot [-i <boot.iso>] [-c cfgdisk]
```

If a `boot.iso` or `cfgdisk` is specified, these devices will be temporarily
attached.  These options facilitate rescue operations and/or reconfiguration.
In the case of a live CD, it should be possible to run *diskless* using only the
specified `boot.iso`

#### `zoneadm reboot`

This will be the same as `zoneadm halt` followed by `zoneadm boot`.

#### `zoneadm shutdown`

This will send an ACPI shutdown (or reboot, with `-r`) to the guest.

**XXX** It's not clear to me that we have a means to do this yet.

### `zlogin`

The `zlogin` may only be used with the `-C` option to reach the guest console.

## Brand implementation details

The following are private implementation details that are architecturally
relevant.

### Guest networking configuration

In the `kvm` brand, DHCP packets are intercepted by (kvm? qemu?) and an
in-hypervisor DHCP server responds handles the DHCP conversation.  No such
facility exists in bhyve.

**XXX** We need to work out what we will do for bhyve.

### PCI slot and function allocation

[bhyve(8)](https://www.freebsd.org/cgi/man.cgi?query=bhyve&sektion=8) says:

```
     -s	slot,emulation[,conf]
		 Configure a virtual PCI slot and function.

		 bhyve provides	PCI bus	emulation and virtual devices that can
		 be attached to	slots on the bus.  There are 32	available
		 slots,	with the option	of providing up	to 8 functions per
		 slot.

		 slot	     pcislot[:function]	bus:pcislot:function

			     The pcislot value is 0 to 31.  The	optional
			     function value is 0 to 7.	The optional bus value
			     is	0 to 255.  If not specified, the function
			     value defaults to 0.  If not specified, the bus
			     value defaults to 0.
```

By default, the boot device (`boot=true` in zone configuration) will be at
`0:0:1`.  Any temporarily attached boot/install media to take precedence
over the persistently attached disk images, 

**XXX** Do we need to expose the bus:slot:function as a property on device and
net resources?


### Customized sparse root

Aside from the shared libraries with which `bhyve` is linked, there are few
other things that are needed for the ongoing operation of a `bhyve` process.
The only known command that it may spawn is
[iasl](https://www.freebsd.org/cgi/man.cgi?query=iasl&sektion=8) if the `-A`
option is used.  Because of having so few dependencies, the `bhyve` brand is an
excellent candidate for an extremely sparse root.

The `bhyve` sparse root will be read-only `lofs` mounted from
`/usr/lib/brand/bhyve/root` with its `/lib` subdirectoring being mounted from
`/lib/brand/bhyve/root/lib`.  All of the executables and libraries found in
each of those directories will be hard links from their normal locations in the
`/` and `/usr` file systems.  Thus, the overhead for supporting the new
alternate root will be tiny

All executables and libraries that exist in the bhyve brand will be 64-bit only.
Executables will not be placed in ISA-specific subdirectories, but libraries
will be.

### Zone directory hierarchy

The in-zone directory hierarchy will be:

| Zone directory 	| Notes 					|
| --------------------- | --------------------------------------------- |
| `/`			| Mounted read-only from global `/usr/lib/brand/bhyve/root` |
| `/dev`		| `dev(7FS)` mount point
| `/lib`		| Mounted read-only from global `/lib/brand/bhyve/root/lib` |
| `/lib/amd64`		| 						|
| `/system/contract`	| `ctfs(7FS)` mountpoint			|
| `/usr/sbin`		| Contains 64-bit executable(s)			|
| `/var/run`		| `tmpfs(7FS)` mount point			|

The list above intentionally does not include `/proc` or `/tmp`.  The only
writable directory is `/var/run`.

**XXX** It is not yet known if the following are needed:

- `objfs(7FS)` at `/system/object`
- `fd(7FS)` `/dev/fd`
- Does `dladm` need anything as its setting up datalinks?  Does `dladm` really
  need to be the one setting up datalinks?  See `dladm_zone_boot()`.

### Devices

The bhyve command needs very few devices, and as such the platform will provide
a small subset of what is typically available within a zone.  Those include:

| Device		| Notes						|
| --------------------- | --------------------------------------------- |
| `/dev/null`		| Attached to `stdin`				|
| `/dev/viona/ctl`	| To open VirtIO network devices		|
| `/dev/vmm/`		| Only the `ctl` node and any nodes for instances belonging to the zone. |
| `/dev/zfd/`		| Attached to `stdout` and `stderr` for logging	|
| `/dev/zvol/rdsk/`	| For access to ZFS volumes in delegated datasets |
| `/dev/zconsole`	| So the guest console may be mapped to the zone console |

Any other devices will be present in the zone only if specified in the per-zone
configuration with `zonecfg(1M)`.

**XXX** It is not yet known if the following are needed:

- `vnd(8d)`

### Privileges

The privileges will be stripped to the minimum required to run a guest. If
`bhyve` only needs a privilege during startup, the privilege will be dropped
prior to running code in the guest.

### Zone init command: `zhyve`

Communicating the `bhyve` configuration options to zone's `bhyve` process is
difficult to do an an elegant way because the zone has no direct access to
the zone configuration or `zoneadmd`.  While some of the needed information is
accessible via `zone_getattr(2)`, some isn't.  In the interest of expedience, a
not so elegant mechanism will be used.

The `boot` brand hook will be used to transform portions of the zone
configuration into the command line options required by `bhyve`.

In the zone, `/usr/sbin/zhyve` will be the init command.  `zhyve` is `bhyve` by
a unique name so that it may self-detect that it is intended to fetch its
arguments from `/var/run/bhyve/zhyve.args`.

#### Implementation note

In the global zone, `/usr/sbin/amd64/bhyve` and
`/usr/lib/brand/bhyve/usr/sbin/zhyve` will be hard links to the same file.  When
invoked with a basename of `bhyve`, the command will behave exactly as
documented in `bhyve(8)`.  When invoked with a basename of `zhyve`, it will read
its arguments from `/var/run/bhyve/zhyve.args`

The format of `/var/run/bhyve/zhyve.args` is one option or argument per line.
No comments are allowed.  Any blank lines will be translated into a "" argument.

We are striving to not modify `bhyve` code any more than required so that it is
easier to keep in sync with upstream.  For this reason, a new source file,
`zhyve.c` is being added.  This will contain an implementation of `main()` and
any other `bhyve` brand-specific code that is required.  The `main()` that is in
`bhyverun.c` is renamed to `bhyve_main()` via `-Dmain=bhyve_main` in `CPPFLAGS`
while compiling `bhyverun.c`

#### Future direction

It is anticipated that in the future a mechanism will be needed to transmit
information between `zoneadmd` and `zhyve`.  Prior art in Kernel Zones
illustrates a generic solution for this type of problem.

In Solaris Kernel Zones, we solved this need by having the in-zone process
listen on a door in the zone.  When zoneadmd wished to interact with the in-zone
process, it would do so via a `fork()`, `zone_enter()`, `door_call()` sequence.
An event pipe also existed between `zoneadmd` and the in-zone process to allow
zoneadmd to know when in-zone process needed attention.  This formed the
foundation of important features like hot add/remove, live migration, and other
features.

For the case of passing the bhyve configuration, this mechanism would involve
`zhyve` starting the door server, then waiting for `zoneadmd` to make a door
call passing the required configuration.
