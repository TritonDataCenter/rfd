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

# RFD 121 bhyve brand

<!--
    Courtesy of markdown-toc.
-->
- [Overview of bhyve](#overview-of-bhyve)
- [The bhyve brand](#the-bhyve-brand)
- [Public interfaces](#public-interfaces)
  * [Zone Configuration](#zone-configuration)
    + [global scope](#global-scope)
    + [admin resource](#admin-resource)
    + [attr resource](#attr-resource)
    + [capped-cpu resource](#capped-cpu-resource)
    + [capped-memory resource](#capped-memory-resource)
    + [dataset resource](#dataset-resource)
    + [dedicated-cpu resource](#dedicated-cpu-resource)
    + [device resource](#device-resource)
    + [fs resource](#fs-resource)
    + [lpc resource](#lpc-resource)
    + [net resource](#net-resource)
    + [rctl resource](#rctl-resource)
    + [security-flags resource](#security-flags-resource)
    + [disk resource](#disk-resource)
    + [pci resource](#pci-resource)
  * [`zoneadm`](#zoneadm)
    + [`zoneadm install`](#zoneadm-install)
    + [`zoneadm attach`](#zoneadm-attach)
    + [`zoneadm detach`](#zoneadm-detach)
    + [`zoneadm clone`](#zoneadm-clone)
    + [`zoneadm boot`](#zoneadm-boot)
    + [`zoneadm reboot`](#zoneadm-reboot)
    + [`zoneadm shutdown`](#zoneadm-shutdown)
  * [`zlogin`](#zlogin)
- [Brand implementation details](#brand-implementation-details)
  * [Guest networking configuration](#guest-networking-configuration)
  * [PCI slot and function allocation](#pci-slot-and-function-allocation)
  * [Zone directory hierarchy](#zone-directory-hierarchy)
  * [Devices](#devices)
  * [Privileges](#privileges)
  * [Zone init command: `zhyve`](#zone-init-command-zhyve)
    + [Implementation note](#implementation-note)
    + [Future direction](#future-direction)
  * [Live reconfiguration](#live-reconfiguration)
    + [Resizing virtual disks](#resizing-virtual-disks)
    + [Hot add/remove of devices](#hot-addremove-of-devices)
    + [Hot add/remove of vcpus](#hot-addremove-of-vcpus)
    + [Memory resizing or ballooning](#memory-resizing-or-ballooning)

**NOTE**  This is a draft.  Your feedback and that of others will likely
cause things to change. Open [issues](https://github.com/joyent/rfd/issues/76)
are tagged with @githubusername.

The FreeBSD hypervisor, bhyve (pronounced "beehive"), is being ported to SmartOS
as a potential replacement for KVM.  The key motivations for this include
better network performance and more opportunities for collaboration with the
FreeBSD bhyve community.

There are several motivations for the bhyve zone brand.  In no particular order,
they are:

- In the unlikely event of a security flaw that leads to a guest escape, the
  escape may be into a zone with greatly reduced privileges.
- Zones are well integrated with a variety of resource controls that are
  important for predictable behavior on shared resources.
- Zones provide easy mechanisms network virtualization and isolation.
- Many cloud and virtualization management frameworks are designed to work with
  zones.  This is particularly true in Joyent's environment.

The following sections provide a brief overview bhyve then significant detail
on the bhyve brand.

## Overview of bhyve

`bhyve` is the name of the user space process that acts as the hypervisor.  It
also uses the `vmm` (virtual machine monitor) and `viona` (VirtIO Network
Adaptor) drivers, which are being introduced with the bhyve project.

The configuration of the virtual hardware is controlled purely through
command-line arguments to the `bhyve` command.  A typical command line looks
like:

```
bhyve -m 4g -c 2 -l com1,stdio -P -H -s 1,lpc \
    -s 3,virtio-blk,/dev/zvol/rdsk/tank/myfirstvm/disk0 \
    -s 4,virtio-net-viona,net0 \
    -l bootrom,/usr/share/bhyve/bhyve-csm-rom.fd myfirstvm
```

That is, the VM named *myfirstvm* has:

- 4 GB of RAM
- 2 virtual CPUs
- first serial port (`ttya`, `ttyS0`, `com1`) attached to `stdin` and `stdout`
- An LPC PCI-ISA bridge, providing connectivity to `com1`, `com2`, and bootrom
- A disk device at PCI (bus, slot, function) 0,3,0.  This disk device is created
  before running the bhyve program, and is most likely populated with an
  installed operating system.
- A network device at PCI 0,4,0.  This device, typically a vnic, must exist
  before `bhyve` is executed.
- A boot ROM

There are a variety of other things that may be configured via command line
arguments.  See [bhyve(8)](https://www.freebsd.org/cgi/man.cgi?query=bhyve&apropos=0&sektion=8&manpath=FreeBSD+11.1-RELEASE+and+Ports&arch=default&format=html).

Even after the `bhyve` command exits, the VM state may still be present in the
kernel.  Subject to certain limitations, this can be reused by future
invocations of `bhyve` to avoid the expensive freeing and allocation of
gigabytes of memory.  When one wants to free up these resources, `bhyvectl
--vm=<name> --destroy` must be used.

It is possible to run an arbitrary number of `bhyve` instances in the global
zone or non-global zones, subject to resource constraints.

## The bhyve brand

The bhyve brand will be implemented in a way that allows it to be included in
illumos so as to benefit from community involvement and to minimize the
troubles associated with maintaining a fork.  The key implication for SmartOS
is that all interaction between `vmadm[d]` and the `bhyve` must be through
public zones interfaces.  This is contrast to how other SmartOS brands are
currently implemented:  most or all of the brand files for the smartos, lx, and
kvm brands live outside of the illumos-joyent repository.

Within a bhyve zone, a special version of the `bhyve` program is used as the
only process in the zone.  It goes by the name `zhyve`.  The life of a `zhyve`
instance and its `vmm` state (e.g.  guest memory, etc.) will match the life of
the zone virtual platform.  That is, the zone's `init` process is `zhyve` and
care is taken to ensure that all resources are freed before the virtual
platform is taken down.  No `vmm` instance will outlive the `zone_t` of the
zone in which it was created.

By default, LPC device `com1` will be connected to `/dev/zconsole`.  If the
guest boot loader and/or operating system redirects its console to the first
serial port (`COM1`, `ttya`, `ttyS0`, etc.), `zlogin -C` may be used to access
the guest's console.  This may be customized with a `serial` resource.

## Public interfaces

The public interfaces to the `bhyve` brand are via `zonecfg(1M)`, `zoneadm(1M)`,
and `zlogin(1M)`.  A new man page, `bhyve(5)` will be added to describe the
uniqueness of the brand.

### Zone Configuration

Because hardware virtual machines have unique configuration requirements,
various new resource types and properties will be needed.  Some resource types
and properties that are appropriate for other brands will not be appropriate for
the bhyve brand.  Details of how resource types and properties are selectively
enabled per-brand are found in [RFD 122](../0122/README.md).  Details on the
resource types and properties supported by the bhyve brand are found below.

Of particular note with this brand is that it is being designed for inclusion
in illumos, while allowing the various distributions to extend it to their
needs.  In a nutshell this means:

- No `attr` resources are required to have a usable bhyve zone.
- No code in illumos will process `attr` resources for any purpose other than
  storing and retrieving them on behalf of users or layered software.
- As described in [RFD XXX](../0XXX/README.md), all resource types will support
  custom properties.  This will allow customers that use illumos and layered
  software to attach metadata to every resource.  This is following the lead of
  SmartOS' use of the `property` complex property in `network` and `device`
  resources.

The following sections describe the various resource types and properties
configurable by zonecfg(1M).

#### global scope

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| autoboot	| simple | yes	| Determines whether zone boots at system boot |
| bootargs	| N/A	| N/A	| Not supported.  Disabled.		|
| brand		| simple | yes	| Must be "bhyve"			|
| fs-allowed	| N/A	| N/A	| Pending [virtfs](https://reviews.freebsd.org/D10335) |
| hostid	| N/A	| N/A	| Not supported.  Disabled.		|
| ip-type	| simple | yes	| Must be "exclusive"			|
| limitpriv	| simple | no	| See "privsetspec" in ppriv(1)		|
| pool		| simple | no	| Resource pool to which the zone binds |
| scheduling-class | simple | no |					|
| uuid		| simple | no	|					|

#### admin resource

No change from historical use.

#### attr resource

No change from historical use.

#### capped-cpu resource

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| ncpus		| simple | no	| If there is no `dedicated-cpus` resource, `min(1,floor(ncpus))` is used to determine the number of virtual cpus configured in the guest. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

#### capped-memory resource

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| guest		| simple | yes	| Guest memory size.  Must be a multiple of the page size used by the guest. |
| locked	| alias | no	| Alias for `rctl` with name `zone.max-locked-memory` `rctl` |
| physical	| alias | no	| Alias for `rctl` with name `zone.max-rss` `rctl` |
| swap		| alias | no	| Alias for `rctl` with name `zone.max-swap` `rctl` |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

#### dataset resource

Not supported.

#### dedicated-cpu resource

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| ncpus		| simple | no	| The number of CPUs that are reserved for the exclusive use of this zone.  This will also be the number of virtual cpus configured in the guest. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

#### device resource

**XXX The scope of this resource is unclear.  See notes in `disk` and `pci`
resources below.**

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| boot		| simple | no	| Only relevant to non-passthrough disk devices.  If set to `true` this device will be the boot disk.  Set on at most one device. |
| match		| simple | yes	| The global zone device to delegate to the zone.  Must be unique across all zones.  Globs are not allowed. |
| emulation	| simple | yes	| See bhyve(8).  Typically `virtio-blk`, `passthru`, or `none`.  If `emulation` is `none`, the device is not visible in the guest. |
| pci-slot	| simple | no	| Not used if `emulation` is `none`.  Otherwise if not specified, dynamically generated on each boot.  If specified, must be in *pcislot[:function]* or *bus:pcislot:function* format.  See bhyve(8).  `pci-slot` must be unique within this zone's configuration. |
| option	| list of complex | no	| Optional configuration options that are specific to `emulation`.  See `bhyve(8)`.  Any option that involves IP addresses is not supported. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

Note that this scheme gives no meaningful way to control the probe order of
devices inside the guest, aside from manually setting `pci-slot`.  This is
especially important for disks if the guest is sensitive to device ordering, as
configuration changes could prevent a guest from booting by moving a boot disk
to a different location.  If `pci-slot` is not specified on all disks, use the
`boot` property on one disk to ensure it is put into a slot that the bootrom
will likely choose as a boot device.

**XXX This does not give a way to have multiple disks on a controller. From bhyve(8):**
```
     Run an 8GB	quad-CPU virtual machine with 8	AHCI SATA disks, an AHCI ATAPI
     CD-ROM, a single virtio network port, an AMD hostbridge, and the console
     port connected to an nmdm(4) null-modem device.

	   bhyve -c 4 \
	     -s	0,amd_hostbridge -s 1,lpc \
	     -s	1:0,ahci,hd:/images/disk.1,hd:/images/disk.2,\
	   hd:/images/disk.3,hd:/images/disk.4,\
	   hd:/images/disk.5,hd:/images/disk.6,\
	   hd:/images/disk.7,hd:/images/disk.8,\
	   cd:/images/install.iso \
	     -s	3,virtio-net,tap0 \
	     -l	com1,/dev/nmdm0A \
	     -A	-H -P -m 8G
```
**But maybe that's not required?**

**Example 1:**  Add a virtual disk backed by a zvol in
[4Kn](https://en.wikipedia.org/wiki/Advanced_Format#4K_native) mode.

```
z1> add device
z1:device> set emulation=virtio-blk
z1:device> set match=/dev/zvol/rdsk/zones/z1/disk0
z1:device> add conf (name=nocache,value="")
z1:device> add conf (name=sectorsize,value="4096")
z1:device> end
```

**Example 2:** Connect the host's first serial port to the guest's second serial port.

This example supposes a device such as a GPS receiver used for NTP is attached
to the host's first serial port and there is a desire to present that device to
the guest on its second serial port.

```
z1> add device
z1:device> set emulation=none
z1:device> set match=/dev/term/a
z1:device> end
z1> select lpc
z1:lpc> set com2=/dev/term/a
z1:lpc> end
```

**Example 3:** Use PCI passthrough to give a real PCI device to the guest

In this example, the device in the host PCI slot 2:0:0 is passed through to the
guest in PCI slot 8:0:0.  A comment is added using a custom property.

```
z1> add device
z1:device> set emulation=passthru
z1:device> set match=2:0:0
z1:device> set pci-slot=8:0:0
z1:device> add property (name=comment,value="AR8151 v2.0 Gigabit Ethernet")
z1> end
```

#### fs resource

Not supported, at least until [virtfs](https://reviews.freebsd.org/D10335) or
or similar is viable.

#### lpc resource

This is a new resource type being added to allow configuration of bhyve's LPC
devices.  A maximum of one `lpc` resource is supported.  The recommended values
for `bootrom` and `com1` will appear in the `SYSbhyve` `zonecfg` template.

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| bootrom	| simple | no	| The bootrom image to load and associate with the LPC device.  The suggested value is `/usr/share/bhyve/uefi-csi-rom.bin` |
| com1		| simple | no	| Where to connect the first serial device.  The suggested value is `/dev/zconsole`.  If the guest then redirects the console output to its first serial port, `zlogin -C` may be used to access the guest console. |
| com2		| simple | no	| Where to connect the second serial device. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

#### net resource

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| address	| N/A	| N/A	| Not supported. Disabled.		|
| allowed-address | N/A | N/A	| Not supported. Disabled.		|
| defrouter	| N/A	| N/A	| Not supported. Disabled.		|
| global-nic	| N/A	| N/A	| Obsolete.  Not Supported.  Disabled.	|
| linkprop	| list of complex | no | A list of link properties that will be set on the vnic specified by `virtual` in `<linkprop>="<value>"` format.  Valid link properties and values are found in `dladm(1M)`. |
| mac-addr	| simple | no	| A MAC address.  If not specified, a MAC address will be dynamically generated and stored in this property. |
| model		| simple | no	| Specifies NIC type that is emulated.  If not specified, defaults to `virtio-viona`.  See bhyve(8) for other supported models. |
| pci-slot	| simple | no	| If not specified, dynamically generated on each boot.  If specified, must be in *pcislot[:function]* or *bus:pcislot:function* format.  See bhyve(8).  Most not conflict with any other `pci-slot` in any other resource. |
| physical	| N/A	| N/A	| This is the name of a physical device or a NIC tag in the global zone.  If `virtual` is specified, this will be the device from which a vnic is created.  If `virtual` is not specified, this device will be delegated. |
| virtual	| simple | no	| If specified, it is the name of a vnic that will be created on top of `physical`.  The value must be valid as a vnic name and must be unique within this zone. |
| vlan		| simple | no	| The vlan ID set on `virtual`.  Only used if `virtual` is set. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

SmartOS will use the following custom properties ([RFD 122](../0122/README.md)).

| Property	| Description						|
|---------------|-------------------------------------------------------|
| ips		| List of IP addresses in CIDR format that are to be configured on this NIC |
| gateways	| List of gateways accessible from this NIC		|
| primary	| XXX useful?						|

**Example:** Create a vnic named `eth0` on `ixgbe1`.

Configure the vnic to prevent DHCP spoofing and only allow outgoing traffic
from 10.88.88.25 or 10.88.88.26.  The `ips` and `gateways` custom properties
are not used by the zones framework - they are only used by SmartOS metadata
service.

```
z1> add net
z1:net> set physical=ixgbe1
z1:net> set virtual=eth0
z1:net> add linkprop (name=protection,value="dhcp-nospoof")
z1:net> add linkprop (name=allowed-ips,value="10.88.88.25,10.88.88.26")
z1:net> add property (name=ips,value="10.88.88.25/24,10.88.88.26/24")
z1:net> add property (name=gateways,value="10.88.88.1")
z1:net> end
z1>
```

**Compatibility warning:**

SmartOS has historically used `physical` to specify the name of the vnic and
`global-nic` to specify the name of physical nic.  This SmartOS convention
seems likely to be difficult to sell to upstream reviewers.

#### rctl resource

No change from historical use.

#### security-flags resource

No change from historical use.

#### disk resource

**XXX It is not clear if this will exist or we will continue to use device
resources for presenting virtual disks**

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| path		| simple | yes	| Path to the raw device (`/dev/rdsk`) that provides the backing store. |
| boot		| simple | no	| Defaults to `false`, may be `true` or `false`.  Only one disk can have this set to true.  Setting it to true causes the disk to appear in a lower-numbered PCI slot than other disks.  Ignored if `pci-slot` is also configured. |
| model		| simple | no	| If not specified, defaults to `virtio` (disk) or `ahci-cd` (cd), depending on value of `media` property.  Other block device emulation type specified in bhyve(8) may be specified. |
| media		| simple | no	| Defaults to `disk`.  May be `disk` or `cd` |
| pci-slot	| simple | no	| If not specified, dynamically generated on each boot.  If specified, must be in *pcislot[:function]* or *bus:pcislot:function* format.  See bhyve(8).  Most not conflict with any other `pci-slot` in any other resource. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

SmartOS will use the following custom properties ([RFD 122](../0122/README.md)).

| Property	| Description						|
|---------------|-------------------------------------------------------|
| image-size	| XXX							|
| image-uuid	| XXX							|

#### pci resource

**XXX It is not clear if this will exist or if we will somehow use device resources**

| Property	| Type	| Required | Notes				|
|---------------|:-----:|:-----:|---------------------------------------|
| XXX		| simple | yes	| Specifies the physical device		|
| pci-slot	| simple | no	| If not specified, dynamically generated on each boot.  If specified, must be in *pcislot[:function]* or *bus:pcislot:function* format.  See bhyve(8).  Most not conflict with any other `pci-slot` in any other resource. |
| property	| list of complex | no	| Arbitrary custom properties for use by SmartOS and other consumers downstream from illumos. |

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
are `raw` and `zfs`, either of which may be compressed with `gzip`, `bzip2`, or
`xz`.  `zoneadm install` will only install to the boot disk.  For multi-disk
installations, other tools should populate the virtual disks and then use
`zoneadm attach`.

If `-c cfgdisk` is specified, the guest is booted once with the specified
configuration disk attached temporarily.  The configuration disk must be in a
raw disk image in a format that is understood by the guest.

In the second form, `-b` specifies installation media that will be temporarily
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

** XXX ** Need a mechanism to communicate to the global zone when `zhyve`
actually starts running guest code.  It's been observed that there can be a
significant delay as kvm evicts arc buffers to make room for guest RAM.  Perhaps
`zoneadm boot` should not return until that initialization is done.
Alternatively, we could implement [auxiliary
states](https://docs.oracle.com/cd/E53394_01/html/E54762/gqhar.html#VLZONgqhej)
and have an aux state like `guest-running`.  Aux state changes would generate
sysevents, allowing management frameworks to be notified of changes.

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

Guest networking can be configured statically, via DHCP, or via cloud
orchestration protocols.  The bhyve brand will not implement a built-in
DHCP server.  If DHCP is needed for guest configuration, a DHCP server needs
to be configured and maintained.

In SmartOS, each guest image will be configured to use `cloud-init` or a
similar program to configure guest networking.  The network configuration
will be obtained through the metadata socket, which is configured on the
second serial port in each guest.

### PCI slot and function allocation

**XXX this needs work, subject to resolution of the `device` vs. `disk` & `pci`
resource type discussion.**

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

### Zone directory hierarchy

The in-zone directory hierarchy will be:

| Zone directory 	| Notes 					|
| --------------------- | --------------------------------------------- |
| `/`			| Read-write `<zonepath>/root` directory	|
| `/dev`		| `dev(7FS)` mount point			|
| `/lib`		| Mounted read-only from global `/lib`		|
| `/usr`		| Mounted read-only from global `/usr`		|
| `/var/run`		| `tmpfs(7FS)` mount point			|
| `/etc/svc/volatile`	| `tmpfs(7FS)` mount point, required by `dlmgmtd` |

Note that `/tmp` is not `tmpfs`.  It is used by `zhyve` to store logs that
should survive a zone reboot.

### Devices

The bhyve command needs very few devices, and as such the platform will provide
a small subset of what is typically available within a zone.  Those include:

| Device		| Notes						|
| --------------------- | --------------------------------------------- |
| `/dev/dld`		|						|
| `/dev/fd`		|						|
| `/dev/null`		| Attached to `stdin`				|
| `/dev/random`		|						|
| `/dev/rdsk`		|						|
| `/dev/viona`		| To open VirtIO network devices		|
| `/dev/vmmctl`		|						|
| `/dev/vmm/`		| Only the nodes for instances belonging to the zone. |
| `/dev/zvol/rdsk/`	| For access to ZFS volumes			|
| `/dev/zconsole`	| So the guest console may be mapped to the zone console |

Any other devices will be present in the zone only if specified in the per-zone
configuration with `zonecfg(1M)`.

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

We are striving to not modify `bhyve` code any more than required so that it is
easier to keep in sync with upstream.  For this reason, a new source file,
`zhyve.c` is being added.  This will contain an implementation of `main()` and
any other `bhyve` brand-specific code that is required.  The `main()` that is in
`bhyverun.c` is renamed to `bhyve_main()` via `-Dmain=bhyve_main` in `CPPFLAGS`
while compiling `bhyverun.c`

In the global zone, `/usr/sbin/amd64/bhyve` and
`/usr/lib/brand/bhyve/zhyve` will be hard links to the same file.  When
invoked with a basename of `bhyve`, the command will behave exactly as
documented in `bhyve(8)`.  When invoked with a basename of `zhyve`, it will read
its arguments from `/var/run/bhyve/zhyve.args`

The format of `/var/run/bhyve/zhyve.args` is a packed nvlist with one string
array element at key `zhyve_args`.  The array and size returned by
`nvlist_lookup_string_array()` are suitable for passing to `bhyve_main()`.

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

### Live reconfiguration

#### Resizing virtual disks

**WARNING: Aspirational statement ahead** @jussisallinen

When the backing store for a disk is resized, the next time the guest makes a
geometry request, the virtio-blk driver will return the new size.  That is, the
virtio-blk driver will not cache the disk size, rather it will query the backing
store each time the guest requests the geometry.

No zone utility will be involved in the actual resizing of the device in the
host.

#### Hot add/remove of devices

Changing the set of devices visible to a guest without a reboot is not feasible
in the initial implementation.  This is an area where there may need to be guest
cooperation, which would further complicated the implementation. @jussisallinen

**XXX** Solaris implemented *removable `lofi`* devices.  Such an approach may be
feasible to create empty disks slots that can be filled without a reboot.  The
occupants of those slots will not be present in the zone's configuration and as
such will not persist across host reboot.

#### Hot add/remove of vcpus

In the future, maybe.

#### Memory resizing or ballooning

In the future, maybe.

## Integration with SmartOS

While SmartOS will benefit greatly from the features that are core to the bhyve
brand, SmartOS has its own mechanisms for zone configuration, installation,
console access, guest network configuration, etc.

### Configuration mapping

SmartOS zones are configured via a `json` file.  The supported configuration
items are described in `vmadm(1M)`.  The following table shows how each
supported configuration item maps to zone configuration or externally maintained
metadata.  All `attr` resources have `type=string`.

| SmartOS Config        | Resource                      | Property      |
|-----------------------|-------------------------------|---------------|
| alias                 | attr name=alias               | value         |
| archive_on_delete     | attr name=archive_on_delete   | value         |
| billing_id            | attr name=billing_id          | value         |
| boot                  | attr name=boot                | value         |
| boot_timestmap        | xxx                           | xxx           |
| brand                 | global                        | brand         |
| cpu_cap               | capped-cpu                    | ncpus         |
| cpu_shares            | global                        | cpu-shares    |
| cpu_type              | *not supported in this brand* |               |
| create_timestmap      | attr name=create-timestamp    | value         |
| server_uuid           | *dynamic, based on server*    |               |
| customer_metadata     | *stored `<zonepath>/config/`* |               |
| datasets              | *not supported in this brand* |               |
| delegate_datasets     | *not supported in this brand* |               |
| disks                 | *Each disk gets a unique `device` resource* | |
| disks.\*.block_size   | device                        | option name=sectorsize |
| disks.\*.boot         | device                        | boot          |
| disks.\*.compression  | device                        | property name=compression |
| disks.\*.nocreate     | device                        | property name=nocreate |
| disks.\*.image_name   | device                        | property name=image-name |
| disks.\*.image_size   | device                        | property name=image-size |
| disks.\*.image_uuid   | device                        | property name=image-uuid |
| disks.\*.refreservation | device                      | property name=refreservation |
| disks.\*.size         | device                        | property name=size |
| disks.\*.media        | device                        | *See **Note 1**, below* |
| disks.\*.model        | device                        | *See **Note 1**, below* |
| disks.\*.zpool        | xxx                           | xxx           |
| disk_driver           | xxx                           | xxx           |
| do_not_inventory      | attr name=do-not-inventory    | value         |
| dns_domain            | attr name=dns-domain          | value         |
| filesystems           | *not supported in this brand* |               |
| filesystems.\*.type   | *not supported in this brand* |               |
| filesystems.\*.source | *not supported in this brand* |               |
| filesystems.\*.target | *not supported in this brand* |               |
| filesystems.\*.raw    | *not supported in this brand* |               |
| filesystems.\*.options | *not supported in this brand* |              |
| firewall_enabled      | xxx                           | xxx           |
| fs_allowed            | *not supported in this brand* |               |
| hostname              | attr name=hostname            | value         |
| image_uuid            | xxx                           | xxx           |
| internal_metadata     | *see `<zonepath>/config/`*    |               |
| internal_metadata_namespace | xxx                     |               |
| indestructable_delegated | xxx                        | xxx           |
| indestructable_zoneroot | *zfs snapshot and hold*     |               |
| kernel_version        | *not supported in this brand* |               |
| limit_priv            | *not supported in this brand (set to fixed value)* | |
| maintain_resolvers    | attr name=maintain-resolvers  | value         |
| max_locked_memory     | capped-memory                 | locked        |
| max_lwps              | global                        | max-lwps      |
| max_physical_memory   | capped-memory                 | physical      |
| max_swap              | capped-memory                 | swap          |
| mdata_exec_timeout    | *not supported in this brand* |               |
| nics                  | *Each nic gets a unique `net` resource* |     |
| nics.\*.allow_dhcp_spoofing           | net           | *See **Note 2**, below* |
| nics.\*.allow_ip_spoofing             | net           | *See **Note 2**, below* |
| nics.\*.allow_mac_spoofing            | net           | *See **Note 2**, below* |
| nics.\*.allow_restricted_traffic      | net           | *See **Note 2**, below* |
| nics.\*.allow_unfilterd_promisc       | net           | *See **Note 2**, below* |
| nics.\*.allow_blocked_outgoing_ports  | net           | *See **Note 2**, below* |
| nics.\*.allow_allowed_ips             | net           | *See **Note 2**, below* |
| nics.\*.allow_dhcp_server             | net           | *See **Note 2**, below* |
| nics.\*.gateway       | net                           | property name=gateway   |
| nics.\*.gateways      | net                           | property name=gateways  |
| nics.\*.interface     | net                           | virtual                 |
| nics.\*.ip            | net                           | property name=ip        |
| nics.\*.ips           | net                           | property name=ips       |
| nics.\*.mac           | net                           | mac-addr                |
| nics.\*.model         | net                           | model                   |
| nics.\*.mtu           | net                           | property name=mtu       |
| nics.\*.netmask       | net                           | property name=metask    |
| nics.\*.network_uuid  | net                           | property name=network_uuid |
| nics.\*.nic_tag       | net                           | physical                |
| nics.\*.primary       | net                           | primary                 |
| nics.\*.vlan_id       | net                           | vlan-id                 |
| nics.\*.vrrp_primary_ip | *not supported in this brand* |                       |
| nics.\*.vrrp__vrid    | *not supported in this brand* |                         |
| nic_driver            | *not supported in this brand* |               |
| nowait                | attr name=nowait              | value         |
| owner_uuid            | attr name=owner-uuid          | value         |
| package_name          | attr name=package-name        | value         |
| package_version       | attr name=package-version     | value         |
| pid                   | *dynamic*                     |               |
| qemu_opts             | *not supported in this brand* |               |
| qemu_extra_opts       | *not supported in this brand* |               |
| quota                 | *zfs property*                |               |
| ram                   | capped-memory                 | guest         |
| resolvers             | attr name=resolvers           | value         |
| routes                | *see `<zonepath>`/config/`*   |               |
| snapshots             | *not supported in this brand* |               |
| space_opts            | *not supported in this brand* |               |
| spice_password        | *not supported in this brand* |               |
| spice_port            | *not supported in this brand* |               |
| state                 | *dynamic*                     |               |
| tmpfs                 | *not supported in this brand* |               |
| transition_expire     | xxx                           | xxx           |
| transition_to         | xxx                           | xxx           |
| type                  | *fixed `BHYVE`*               |               |
| uuid                  | global                        | uuid          |
| vcpus                 | dedicated-cpu                 | ncpus *(but see **Note 3**, below)* |
| vga                   | xxx                           | xxx           |
| virtio_txburst        | xxx                           | xxx           |
| virtio_txtimer        | xxx                           | xxx           |
| vnc_password          | xxx                           | xxx           |
| vnc_port              | xxx                           | xxx           |
| zfs_data_compression  | *not supported in this brand* |               |
| zfs_data_recsize      | *not supported in this brand* |               |
| zfs_filesystem_limit  | *not supported in this brand* |               |
| zfs_io_priority       | global                        | zfs-io-priority |
| zfs_root_compression  | *not supported in this brand* |               |
| zfs_root_recsize      | *not supported in this brand* |               |
| zfs_snapshot_limit    | *not supported in this brand* |               |
| zfs_max_size          | *not supported in this brand* |               |
| zlog_max_size         | *not supported in this brand* |               |
| zone_state            | xxx                           | xxx           |
| zonepath              | global                        | zonepath      |
| zonename              | global                        | zonename      |
| zoneid                | *dynamic*                     |               |
| zpool                 | xxx                           | xxx           |

**Note 1:** For each disk `media` and `model` work together to populate to
populate the `model` and `media` in the `device` resource.

| json media	| json model	| device media		| device model	|
|---------------|---------------|-----------------------|---------------|
|		|		| disk			| virtio-blk	|
| disk		|		| disk			| virtio-blk	|
| disk		| virtio	| disk			| virtio-blk	|
| disk		| ide		| disk			| ahci		|
| disk		| ide		| disk			| ahci		|
| disk		|		| *not supported*	|		|
| cdrom		|		| cdrom			| ahci		|
| cdrom		| virtio	| *not supported*	|		|
| cdrom		| ide		| cdrom			| ahci		|
| cdrom		|		| *not supported*	|		|

**Note 2:** All of the properties related to the `protection` link property gets
turned into a single comma-separated list and added to the `net` resource's
`linkprop name=protection`.

**Note 3:** This assumes that for SmartOS we do not allow oversubscription of
CPUs.  This seems to be the direction we are going, at least initially.  In the
future, we can add an `oversubscribe_cpus` knob which would suggest that we
may use `capped-cpus`.  Both modes are accounted for in the descriptions of the
`dedicated-cpu` and `capped-cpu` resources above.
