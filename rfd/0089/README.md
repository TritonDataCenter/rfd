---
authors: Robert Mustacchi <rm@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent Inc.
-->

# RFD 89 Project Tiresias

We need to have a fresh view on visibility inside of the chassis and
being able to manipulate things inside of it. Like a classic Greek
Oracle, we need to be able to see inside to the best of our ability,
even if there is some uncertainty. 

For more background into the motivation, please see [RFD 88 DC and
Hardware Management Futures](../0088/), which
discusses the next generation of challenges around DC management. This
RFD explicitly tackles portions that lead to enhanced visibility of
what's inside the chassis and allowing for identification of parts via
LEDs. This RFD proposes a foundation for certain parts of the system
that aren't visible or controllable today. It enhances things in the
platform, exposing them mostly through the fault management architecture
(FMA) topology trees.

Today, FMA gives us visibility into a number of devices and to control
LEDs on a subset of devices; however, there are some major pieces that
we're missing. The main goals of this project are the following:

* PCI Express Serial Capability
* UFM visibility
* Transceiver Visibility
* Chassis USB Visibility
* LED management for NICs
* PSU and Chassis Identification
* New FM tree

We opt to focus on this part of the problem first, as without it it will
be harder to build the higher level pieces. In addition, while those
higher level pieces and interactions are still being worked out, this
allows operators to make use of these facilities, even if it's less
orchestrated.

This will generally be consumed through existing interfaces such as the
/devices tree (accessible via prtconf(1M)) or fmtopo. Additional, more
traditional and stable interfaces may be added after we have more
experience with these interfaces.

As part of designing all of these interfaces, an important constraint is
that querying this information should not impact the general
availability of the system. For example, if some of this information is
defined to cause a device reset or some subsystem of a device to reset
as part of querying it, and that causes a substantial service
interruption, then we should opt not to expose it.

## Explaining the FM Focus

An important thing to explain is _why_ we're focusing on the fault
management tree, especially given some of the problems with the topology
trees today: the fault management hardware chassis topology tree does
not always represent all of the devices present in the system if it
can't relate them to something on the chassis.

However, the important benefit of the hardware chassis topology view is
that it shows us all the hardware in the system from the view of the
hardware that actually exists. When dealing with faults and summarizing
what's present in the system this is what we care about. To better
motivate this, let's consider another important view that the system
provides: the /devices tree.

The /devices tree provides a logical view of the system (accessible via
libdevinfo(3LIB) and prtconf(1M)). The /devices tree shows the
relationship between the different instances of device drivers in the
system. Take for example an NVMe device or a SAS disk. When a SAS disk
fails, the sd instance may have a long path that we travel through. The
HBA controller, one or more iports, or something else. Similarly, when
an NVMe device fails, we may have one or more blkdev instances (one for
each NVMe name space) fail as well as the actual nvme driver instance.
While it may be important to understand the tree of impacted devices,
when trying to present a high-level impact, it's not useful information
to most operators, most of the time.

As we mentioned earlier, the hardware chassis tree is not without its
flaws. As such at the end of this document we will outline some
properties we'd like for a more general topology tree.

The end goal of all of this is to have a single, albeit verbose, way to
get a snapshot of everything that's hardware related in the system
(basically all the FRUs) and relevant information related to their
context in broader topology (e.g. [RFD 7 / LLDP](../0007/).

By having the information available, even if it's not in the simplest
form to consume, it will allow folks to make forward progress on
figuring out what subsets of information are useful and what additional
tooling whether in the OS, or in the broader context of Triton, is
useful.

## PCI Express Serial Capability

The PCI Express specification added an optional capability: the Device
Serial Number Capability. The specification describes the value as an
IEEE EUI-64 value whose first three octets are a vendor OUI. This is
supposed to correspond to the board's serial number and is often unique
on a per-function basis.

To make it easier for operators to get information about an arbitrary
device, I propose that we have the PCI Express subsystem in the OS
automatically detect if this capability is present, and if so, always
add a property to the /devices tree for the PCI device. The property
will be an 8 byte array that contains the EUI-64.

The advantage to performing this as part of the PCIe initialization
(pcie_initchild()) is that it will be uniform for all devices in the
system, having the bytes always be in the same order, with the same
property name, and represented in the same way.

## UFM Visibility

Upgradable Firmware Modules (UFMs) are a potential component of many
different FRUs (field replaceable units). UFMs may come in many
different styles. For example, some of the following that belong to
devices might all be considered a UFM:

* EEPROMs
* Traditional Firmware Blobs
* Microcode
* General binary images

Some concrete examples might make this useful. Modern hard disk drives
have firmware images. The disk drive itself is traditionally a FRU and
it has some amount of firmware which controls the drive. The firmware on
the drive can be upgraded based on standard SCSI commands. That firmware
image is something we consider a UFM.

The motherboard often has a UFM in the form of the BIOS or UEFI. The
Lights out management controller on a system has a UFM, which is usually
the entire system image. CPUs also have a UFM in the form of microcode.

However, there are a few devices that behave in different ways. Some
devices require the driver to upload the microcode/firmware to the
device when it starts up. This is fairly common of many WiFi drivers.
An important property of these devices is the transient nature of that
image. Every time the device is powered on or even resets, it needs to
have that microcode/firmware uploaded anew. Because of this inherently
volatile nature, it means that the distribution and management of this
image is different. These items are sometimes embedded inside of the
device driver binary or they may be different files in the file system
that are part of a system package. Importantly, in this case, it doesn't
describe something that can be upgraded or managed on the device.

There are also devices that have firmware which is a property of the
device, but may not be upgradable from the running OS. This may be
because the vendor doesn't have tooling to upgrade the image or because
the firmware image itself cannot be upgraded in the field at all. For
example, a YubiKey has a firmware image that's burned into it in the
factory, but there is no way to change the firmware on it short of
replacing the device in its entirety.  Despite that, because these
images are properties of the device and not transient images like
previously described, it is worth representing them.

### Existing Firmware Management Tools

Today, firmware is managed in a somewhat haphazard way in the system.
There is a single tool which can be used to __flash__ firmware for a
variety of devices called
[`fwflash(1M)`](http://illumos.org/man/1m/fwflash). As a side effect, it
has a limited ability to report the current firmware versions of
devices.  However, it can only do this for firmware devices that it
knows about and has plug-ins for.

Because it it based on this plug-in infrastructure, it is possible to
extend it to be able to report arbitrary firmware information. However,
the fwflash design isn't really around consumption by the rest of the
system. Importantly it doesn't expose any kind of programmatic
interface.

CPUs have a [`ucodeadm(1M)`](http://illumos.org/man/1m/ucodeadm) command
which can be used to report the microcode of a given CPU and update it.
This works for Intel and AMD CPUs. It provides a means for reporting the
current revision. However, this information isn't widely available
outside of this form. It has its own one off way for getting firmware
information.

Finally, some devices put random information in their devinfo
properties. For example:

* The [`igb(7D)`](http://illumos.org/man/7d/igb) driver has a
  'nvm-version' which contains the version of the NVM image of the
  device.

* The [`i40e(7D)`](http://illumos.org/man/7d/i40e) driver has a
 'firmware-revision', 'firmware-build', and 'api-version' property.


Basically, all of this is currently a jumble. There's no consistency for
operators to know both what to look for or even where to look.  Because
it's such a hodgepodge, it makes it hard to create one-off tools which
actually get all of this information in one place, even if its
understood that these are currently unstable interfaces.

### Properties of a UFM

We'd like to model a UFM as an image that has a number of slots. The
idea here is that the image represents a purpose, for example, this may
be a BIOS image, or a NIC's EEPROM. Then, each slot represents one or
more different versions that can exist, only one of which is active.

For example, an NVMe device has a single firmware image; however, there
are 1-8 slots available on the device. This would be modeled as the NVMe
PCIe Device having a UFM node with 1-8 slots.

The motherboard is another interesting example to look at. The
motherboard may have _two_ different images. The first image is a CPLD
image and the second is a BIOS image. Now, this BIOS image may have two
physically different units, one being used as a primary BIOS image and
the second being a backup or fail safe unit.

This would be modeled as two different UFM nodes, one of the CPLD and
one for the BIOS. The BIOS image would then have two different slots.

This raises where we make the important distinction. Basically, each
piece of firmware that can run in parallel is its own top-level object.
Then each different place we can store that data, is in a slot.

With that in mind, here's the data that we roughly have on each of these
units:

Broader UFM / Image unit:

* Description (string)
* Ancillary data (nvlist_t)

Slot data:

* Version / revision (free form string)
* A notion of whether or not the image is readable or writable (bit
  field)
* Slot number (int)
* Is the slot active (boolean_t?)
* Ancillary  data (nvlist_t)

### Actions on UFMs

There are three main actions that we want to take on UFMs:

1. Reporting
2. Reading
3. Upgrading (writing)

#### Reading and Writing

While having the ability to report information is fairly straightforward
in terms of desire, given that most devices can report their firmware
revision, it's not always the most straightforward path to actual dump
the images or update.

The longer term goal here will be to use this as a framework where we
can add additional support for reading and writing these images, though
some of this may be leveraged through fwflash as opposed to using new
utilities.

### Visible Devices

The following is the set of devices that we want to be able to have
information about the UFMs for in an initial release:

* CPU microcode
* BIOS/EFI revision
* LOM revision
* Disk Firmware revs
* SES firmware revs
* PCI HBAs:
    - mpt_sas
    - smrt
* PCI NICs:
    - e1000g
    - igb
    - ixgbe
    - i40e
* Misc. PCI:
    - nvme

If we can get others networking device drivers, that'd be a major boon,
but we shouldn't assume that we'll be able to. It really depends on what
those devices provide.

### Data Consumption

Before we think too much about how we want to arrange for different
parts of the system to contribute this information, it's worth thinking
through how we want to actually consume it ourselves.

There are a couple of different primary objectives:

* An operator wants to list all the firmware revisions on the system and
understand what parts they belong to.

* We'd like these to be visible in the hc tree for anything that
supports it.

* Make it easy for tools which want to consume this information to do
so without jumping through too many hoops.

#### FM Topo Model

We'd like the FM topo model to mimic the description we discussed in the
introduction to the UFM section. Effectively we'd create one node per
image, which itself would have one child node for each slot. These would
be attached to relevant nodes in the tree, such as PCI devices, the
chassis, etc.

### /devices integration

While not everything listed in the initial portion above shows up in
/devices, in fact the majority of it aside from the BIOS/LOM does. One
way we could begin to expose all of this is to add a series of
properties or ioctls to devices that can be used to support this. One
could see if a device supports this by checking for a property like
'ufm-report-capable' to know that it supported a series of reporting
ioctls to get the slot / firmware information.

Similarly, if a device upports the firmware upgrade through a similar
ioctl, it could use something like a 'ufm-upgrade-capable' property and
if the image could be dumped to disk, 'ufm-dump-capable'.

For example, you could imagine a set of DDI routines that a driver could
have such as:

The UFM operations vector would include something like:

```
/*
 * Opaque structure
 */
typedef struct ddi_ufm_image {
	uint_t		ufmi_imageno;
	char   		*ufmi_desc;
	nvlist_t	*ufmi_misc;
} ddi_ufm_image_t;

typedef enum {
	DDI_UFM_ATTR_READABLE	= 1 << 0,
	DDI_UFM_ATTR_WRITEABLE	= 1 << 1
} ddi_ufm_attr_t;

/*
 * Opaque structure
 */
typedef struct ddi_ufm_slot {
	uint_t		ufms_slotno;
	char		*ufms_version;
	ddi_ufm_attr_t	ufms_attrs;
	boolean_t	ufms_primary;
	nvlist_t	*ufms_misc;	
} ddi_ufm_slot_t;

/*
 * nimages and nslots may both be present or NULL. If both are NULL,
 * then just have a single default image that we fill. nslots == NULL,
 * means slots == 1
 */
typedef struct ddi_ufm_ops {
	int (*ddi_ufm_op_nimages)(ddi_ufm_handle_t *uhp, void *arg,
	    uint_t *nimgp);
	int (*ddi_ufm_op_fill_image)(ddi_ufm_handle_t *uhp, void *arg,
            uint_t imgid, ddi_ufm_image_t *img);
	int (*ddi_ufm_op_nslots)(ddi_ufm_handle_t *uhp, void *arg,
            uint_t imgid, uint_t *nslots);
	int (*ddi_ufm_op_fill_slot)(ddi_ufm_handle_t *uhp, void *arg,
            int imgid, uint_t slotid, ddi_ufm_slot_t *slotp);
} ddi_ufm_ops_t;

typedef struct ddi_ufm_handle ddi_ufm_handle_t;

int
ddi_ufm_init(dev_info_t *, int version, ddi_ufm_ops_t *, ddi_ufm_handle_t **, void *);

void
ddi_ufm_fini(ddi_ufm_handle *);

boolean_t
ddi_ufm_is_ioctl(ddi_ufm_handle_t *, int cmd);

int
ddi_ufm_ioctl(ddi_ufm_handle_t *, dev_t dev, int cmd, intptr_t cmd,
    int mode, cred_t *credp, int *rvalp);

void
ddi_ufm_update(ddi_ufm_handle_t *);
```

All of these functions and more are documented in the following series
of draft manual pages:

* [ddi_ufm(9E)](./man/ddi_ufm.9e.pdf)
* [ddi_ufm(9F)](./man/ddi_ufm.9f.pdf)
* [ddi_ufm_image(9F)](./man/ddi_ufm_image.9f.pdf)
* [ddi_ufm_slot(9F)](./man/ddi_ufm_slot.9f.pdf)

## Transceiver Visibility

Transceivers are a part of many high-speed networking parts. The
transceiver is often a separate FRU from the NIC and may be separate
from the cable that's actually in use. Today, there's no uniform way to
expose transceiver information in the system or to really get at what's
being used, short of some amount of mdb -k. The following is the kind of
information that we want to have access to. This will likely need to be
fleshed out as a newer set of GLDv3 interfaces. Based on the current
standards the following seems reasonable to try and include / gather for
an FM topology node:

* Manufacturer
* Part Number
* Part Revision
* Serial Number
* Transceiver type
* Whether the transceiver is present or not
* Whether the transceiver is usable or not by the driver

### Topo Nodes

As a part of this, we should expose this information as a child node of
any NICs that are present in the system with a 'transceiver' type. This
can also be used by other devices as drivers end up adding support for
it, for example, FC and IB.

### Transceiver Types

Here, we're generally interested in transceivers that are used for NICs,
though this is generally extendible to FibreChannel and Infiniband.
There are four different standards that roughly cover what we care about
today:

* INF-8074: SFP Transceiver
* SFF-8472: Diagnostic Monitoring for Optical Transceivers
* SFF-8436: QSFP+ 10 Gbs 4X PLUGGABLE TRANSCEIVER
* SFF-8636: Management Interface for Cabled Environments

Roughly speaking, traditional SFP/SFP+ transceivers were standardized
for gigabit based systems in INF-8074. These provided basic information
about the SFP over an i2c bus. The amount of information was extended in
SFF-8742.  All of the information present in INF-8074 is present in
SFF-8742, SFF-8742 adds an additional page of data. Generally speaking
all 1 / 10 Gb/s SFP/SFP+ transceivers implement either or both of
INF-8074 and SFF-8472.

SFP28 which are a 28 Gbit/s SFF device that are used for 25 Gbit/s
Ethernet were ratified in SFF-8402. These are defined to use the
management interface in SFF-8472.

QSFP+ which is a standard which comes 4 SFP+ 10 Gbit/s lanes. This is
used for 40 GBit/s Ethernet. QSFP+ standardized its own management
interfaces.

More generally, future transceivers seem to be planning on using
SFF-8636. Particularly, from SFF-8636, this updated common management
interface is being used both for shielded SAS and for QSFP+ 28 Gbit/s,
which will be used for up to 100 Gbit/s cables.

Based on these, it's important to note that while these have similar
information, they are not equivalent data formats. All four of the
standards does give us information on the following:

* Manufacturer
* Part Number
* Part Revision
* Serial Number

Each standard here has a different amount of information available and
there are different ranges that we care about. For example, for basic SFP
devices (INF-8074), the first 128 bytes are defined and that we care
about. Where as SFF-8636 defines 256 bytes, the upper 128 bytes are the
common read-only part. Similarly, SFF-8472 defines a second 256 byte
page.

The following table summarizes the different standards, speeds, and
content:

| Standard | Supported Speeds | Total Data Length | Page Number |
| -------- | ---------------- | ------------------| ----------- |
| INF-8074 | 1 Gb/s, 10 Gb/s | 256 bytes | 0xa0 |
| SFF-8472 | 1 Gb/s, 10 Gb/s, 25 Gb/s | 512 bytes | 0xa0, 0xa2 |
| SFF-8436 | 40 Gb/s | 256 bytes | 0x00 |
| SFF-8636 | 100 Gb/s, SAS | 256 bytes | 0x00 |

#### Multi-port PHYs

There is some evidence that some devices support having multiple PHYs
correspond to a single logical MAC. We've seen this in the datasheet for
the Intel XL710 (i40e driver); however, we have not seen this in the
wild per se. In cases such as these, it may be possible that a given
instance of a device driver there are multiple distinct PHYs and
therefore SFPs. While we do not consider this the common case, we should
make sure to think through it while designing the API.

### Implementation

As noted in the previous section, there are several different standards
at play all of which define slightly different data structures and
places that this data can be found.

The following drivers support devices that can access this information:

* bnxe
* cxgbe
* igb
* ixgbe
* sfxge
* Next gen Broadcom and QLogic parts that we don't have drivers for

The i40e driver does support gathering this information, but does not
provide raw access to the i2c information, instead it is abstracted by
the firmware and the driver can only get a limited amount of information
about the phy.

At this time, our primary focus is on exposing this so that it can be
consumed by topo for the limited number of fields that we care about.
While we do not intend to actually implement ways for dladm or other
userland utilities to parse the entire SFF i2c information, we want to
make sure that it all can be gathered by the driver as needed.

Based on this, we're going to make sure tht what we're creating has ways
to get the entire information from the SFP, even if we're not exercising
them immediately. We also will need to have a way to have a driver
create synthetic information when it does not have access to the actual
information and in such a way that it does not have to cons up the
actual SFF data format.

#### GLDv3 Interfaces

We'd like to abstract what device drivers have to implement into a new
GLDv3 capability (see mac(9E) for more information). This new capability
will be called: `MAC_CAPAB_TRANSCEIVER`.

A driver that implements this capability will need to fill out the
following structure:

```
typedef struct mac_capab_transceiver {
	uint_t	mct_flags;
	uint_t	mct_ntransceivers;
	int	(*mct_info)(void *driver, uint_t id,
		    mac_transceiver_info_t *infop);
	int	(*mct_read)(void *driver, uint_t id, uint_t page, void *buf,
		    size_t buflen, off_t off, size_t *nwritten);
} mac_capab_transceiver_t;
```

For more information on the interface, how drivers will be expected to
fill out the structures, and additional support functions that are going
to be provided, first review the draft manual page
[mac_capab_transceiver(9E)](./man/mac_capab_transceiver.9e.pdf). The
suport functions that drivers have are avaiable in
[mac_transceiver_info(9F)](./man/mac_transceiver_info.9f.pdf).

The interface that topo and others will use to fetch this information is
still to be determined and will be a private interface. This may just
end up translating into a link property, but we'll come back to and
update that when we have more experience. Importantly, that can change
over time.

##### Device Support Planned

| Driver | info | read | Have HW | planned |
| -----  | ---- | ---- | ------- | ------- |
| bnxe | yes | yes | no+ | no |
| cxgbe | yes | yes | yes | yes | 
| igb | yes | yes | no+ | no |
| ixgbe | yes | yes | yes | yes | 
| i40e | yes | no | yes | yes | 
| sfxge | yes | yes | no | no* |

Items marked with a `+` indicate that we have hardware, but not hardware
that accepts transceivers.

Items noted with `no*` in the `planned` column are because we do not
have hardware for these devices that supports this mode of operation.
For devices which are not listed here, we have no current intention of
adding support or the devices themselves do not support anything like
this.

##### Intersection with ETHER_STAT_XCVR_*

There already exist some information in MAC about various transceivers
through the `ETHER_STAT_XCVR_INUSE` values. These provide some minimal
information, but they are generally situated around older copper
Ethernet. While it may be reasonable for us to figure out how to make
sense of these in the modern world, they don't really provide ways for
us to get the information that we need.

## Chassis USB Visibility

Today, USB devices are not present in the hardware chassis view. What
we'd like to do is make it so that a chassis's USB ports are visible in
the topology tree, at which point we can enumerate the USB devices
underneath them.

We'd like to use this in part so we can determine what's plugged in and
active, as well as to determine whether devices are present in internal
or external USB ports to allow for additional system policies. One
example of a policy this could enable is to not trust a yubikey or other
USB key-based device unless it is plugged into an internal slot.

### Topo Nodes

This would introduce a new set of nodes that are not dissimilar to the
existing `bay` nodes that have disk drive names. The exact name is still
to be determined.

Under this, we would have a USB topology that was not dissimilar to
cfgadm. This would allow us to see all the devices that are under one
another, likely including the io property groups or binding nodes.

### Implementation Details

This still needs a large amount of research and is still at the initial
idea phase. A subsequent RFD will need to flesh this out.

Today, leveraging ACPI on x86, we're able to map physical USB ports to
their corresponding entries on the actual root hubs that drivers see for
at least xhci. One of the reasons this is challenging is that a physical
USB port that has support for USB 3.x speeds, shows up as both a
separate USB 2.x and USB 3.x port on the root hub.

From there, we'll need to see if ACPI actually provides any meaningful
data or labels, or more likely, supplement this information with
optional topology maps that describe how these ports in ACPI map to the
actual things that humans see on the chassis.

## NIC LED Management

We would like to introduce the idea of having an identifier and/or fault
LEDs for various GLDv3 devices. Now, one of the challenges is that
devices do not have a default notion of an identification LED. The only
thing that they have is the default activity LEDs and then the device
writer can transform that into something else.

### Topo Nodes

Under the current I/O entries for individual PCI functions, we should
add additional nodes like we do with disks. Specifically, we should add
an indicator node of type 'ident' which all drivers implement. We may
want to also add the notion of a 'fault' indicator that drivers can
optionally implement. It's not clear if having the same output for both
will be more confusing or if expressing both so that software can toggle
one or the other in different cases is more useful.

### Implementation Notes

We'd like to present the model to GLDv3 device drivers that they have to
set an LED into a certain mode. We want to allow them to express the
different modes that they support. Importantly, we do not believe that
the driver should have to know about the different combination of
requests that may or may not want to be handled, instead the driver
should simply be told what it should be set to.

From surveying a number of devices, there usually aren't multiple,
independent LEDs that exist for a given port. For the time being, we
will not be introducing anything that provides a device a way to specify
that multiple LEDs exist; however, the current design does not preclude
that being added.

We will introduce a new GLDv3 capability for this called
`MAC_CAPAB_LED`. The capability will have the following structure:

```
typedef enum mac_led_mode = {
	/*
	 * Set the LED to its default behavior and type. This is
	 * generally based on activity and link presence.
	 */
	MAC_LED_DEFAULT	= (1 << 0),
	/*
	 * Indicates that the LED should be turned off entirely.
	 */
	MAC_LED_OFF	= (1 << 1),
	/*
	 * Indicates that the LED should be transitioned to an
	 * identification mode, which is driver specific. 
	 */
	MAC_LED_IDENT	= (1 << 2)
} mac_led_mode_t;

typedef struct mac_capab_led {
	uint_t mcl_flags;
	mac_led_mode_t mcl_modes;
	int (*mcl_set)(void *driver, mac_led_mode_t mode, uint_t flags);
} mac_capab_led_t;
```

For more informatino on the interface, how drivers will be expected to
fill out the structures, and the behavior of various functions, review
the draft manual page [mac_capab_led(9E)](./man/mac_capab_led.9e.pdf).

The interface that topo and others will use to fetch this information is
still to be determined and will be a private interface. This may just
end up translating into a link property, but we'll come back to and
update that when we have more experience. Importantly, that can change
over time.

#### Initial Driver Targets

The following devices cover the set that we'd like to make sure is
initially covered with this work. This list is based on a combination of
available hardware and what's used in the field.

* bge
* bnxe (copper only, missing SFP hw)
* cxgbe
* e1000g
* igb
* ixgbe
* i40e

## PSU and Chassis Identification

Today, the PSU and the hardware chassis already may be present in the
topology tree. The chassis always shows up as it's the root of the tree.
However, power supplies do not always show up. Today their presence is
enumerated as part of IPMI.

What we'd like to do is investigate the major Joyent-used hardware, as
well as that of other Tier-1 OEMs and determine what's necessary to make
the PSUs always show up and drive the LED identifiers for them as best
as we can.

### Topo Nodes

This will create new indicator nodes under existing devices. We will
focus on exposing ident nodes. However, if it turns out that fault nodes
are available, then we will also expose them.

## New FM Tree

Finally, the last of the pieces that we'd like to include is the
construction of a new FM tree. Today the `hc://` (hardware chassis) tree
only has a notion of what exists if the device can be mapped as a
descendent of something that is physically in the chassis. For example,
if for some we don't have any kind of enclosure services or a static
mapping, then the `hc://` tree does not represent any disks!

We'll want to spend a bit more time on this and flesh out how things
show up in here. Perhaps it mirror /devices, but then doesn't have some
of the chassis specific information, such as labels, etc. For the
interim we're calling this the general device scheme, with the fmri
(gd://).

## Impacted Repositories

As part of this work, only the illumos-joyent repository should be
impacted.

## See Also

* [RFD 6 Improving Triton and Manta RAS Infrastructure](../0006/)
* [RFD 7 Datalink LLDP and State Tracking](../0007/)
* [RFD 88 DC and Hardware Management Futures](../0088/)
