---
authors: rm@joyent.com
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+166%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 166 Improving phy Management

The phy, or physical layer, of devices is an important part of many
different hardware devices in the system. Unfortunately, it also happens
to be a soft underbelly in the system where today we don't have good
visibility or control of the phy of the system.

Specifically, we're concerned with the following types of devices in the
system:

* PCIe (PCI Express) Devices
* SAS (Serial Attached SCSI) Devices
* SATA (Serial ATA) Devices
* USB Devices
* Network Controllers

In this RFD, we us the term 'phy' to refer to the physical interconnect
that a device is plugged into. For example, this often refers to the
slot that we insert a PCIe device into, or the bay that we plug a disk
into. Some devices, like a USB hub or a SAS expander, are both a device
that plugs into phys and then also have phys that other devices might
plug into.

## Questions

To help motivate the discussion of what we want to add, it's useful to
first go through and discuss a number of the questions that we have of
the system that we need to answer.

* What speed is the device linked up at?

For example, what generation and link width is a PCIe device at? Is a
SAS device running at 3.0, 6.0, or 12.0 Gb/s?

* What speeds do the devices support?

For example, which PCIe generations does the device support? What lane
widths does it support? Is the USB device a USB 1.x, 2.x, or 3.x
device? Is it a USB 3.x 5 Gb/s, 10 Gb/s, 20 Gb/s, etc. device?

* What speeds does the phy support?

This is a similar question to the previous one, but asking about it on
the other side.

* Is the device and phy linked up at the maximum speed?

Based on the device and phy's capabilities, are they linked up at the
top speed for them. For example, if a SAS device and the HBA support
running at SAS 12.0 Gb/s, is it actually running at that.

* Is the device and phy linked up at a sufficient speed? Does it have
all of the bandwidth it needs?

Based on the device's needs, is it linked up to its phy at the needed
level, which may be less than the maximum. Based on the paths to the
device, does it have enough bandwidth or are some of the links to it
overprovisioned.

For example, if a SAS device is behind an expander of an NVMe device is
behind a PCIe switch, what is the ration of bandwidth overprovisioning
between the various sides of the expander/switch?

* What are all the paths to the device?

For a given device, how do we reach it? For example, when a SAS expander
is on the scene, are we reaching it via a single path or multiple paths?
A PCIe switch may be linked to multiple different upstream PCIe ports.

* What other devices are behind a given phy?

For a given phy, what are all of the devices that are behind it or that
it can reach. This is especially important when we consider the question
of a given cable going bad which might create problems for everything
behind the phy.

* What information or errors about a phy or link on a path should we be
looking at?

For example, we've had cases where we have an image that looks like:

```
+-----+      +-----+       +-----+
| HBA |<---->| EXP |<----->| EXP |
+-----+      +-----+       +-----+
                |             |
                v             v
            +-------+     +-------+
            | Disks |     | Disks |
            +-------+     +-------+
```

Here, we have a SAS fabric where two expanders are linked together.
We've seen several cases about where the link between the two expanders
has been bad; however, we often only see it as a bunch of errors on a
set of disks. So part of this is what information can we gather and
understand about the system to help us understand that.

## Goals and Scope

This section describes the different goals we have for this project and
what we consider in scope. Our main goal is to answer the above
questions and provide tooling to operators to make understanding this
state and manipulating it much simpler. Some initial proposals about how
to meet these goals will be in the [Implementation
Ideas](#Implementation-Ideas) section.

The scope of this is in the core operating system. We intend to
initially design this so that we can ask the running system these
questions. This project is intended to serve as a foundational piece and
building block that other Triton and Manta based systems can consume and
present. For example, some of the controls could conceivably find their
way into AdminUI or other Triton tooling, the statistics into
[CMON](../0027/README.md), etc.

* Visibility of the device and phy capabilities and the current
negotiated rates.

Effectively, for each of the categories of devices that we've talked
about, we need to know what the phy and device are capable of and what
they've negotiated.

* Ability to understand SAS, SATA, and PCIe fabrics

For this to be useful, we need to be able to understand how all of the
SAS, SATA, and PCIe fabrics are interconnected and what are all the
paths that we take to a given device. This should also help us answer
the question of what is reachable from a given path.

* Ability to consume informational and error statistics about phys and
the corresponding fabrics

For each of the major device types we'll need to figure out what error
and statistical information is available to us and what the best way to
present that is.

* Ability to manipulate phy state and power cycle devices

If a device ends up in a weird state, then we should look at using
in-protocol methods to ask it to try and negotiate this again. This
should also include allowing the operator to hard-code a particular
state.

* Ability to understand when phy state is not what we expect

As part of all this, we need to have some means of knowing whether or
not this state is what we expect the system to be in. For example, if we
have a PCIe Gen 3 device plugged into a PCIe Gen 3 slot, but it's
operating at PCIe Gen 1 speeds, that's probably bad. It's not
immediately clear where such rules and mappings should exist or what can
tell and notice this.

In some ways, this is reminiscent of old Windows behavior that tried to
warn you when you plugged a USB High speed device into a full-speed
device. However, it's not necessarily the case that we want to indicate
that this has happened on every device insertion, etc.

* Ability to be notified on changes to the negotiated phy state

We'd like the system to be able to understand when a change has happened
so it can go back and reassess the current state and whether or not it
matches our expectations.

* Ability to see the history of changes to a given negotiated phy state

We want to have a sense of when changes occurred, whether it was
instigated directly by the operating system, and understand whether or
not we consider a device to be flapping, as in changing back between
states in rapid succession.

## Background: Phy States and Options

This section provides additional background on the different concerns
and configurability of different types of phys based on the underlying
hardware.

### PCI Express

PCI express (PCIe) devices and slots have two different dimensions which are
equally important when understanding the state of their phy. These are:

1. The PCIe Generation
2. The Lane Count

In the PCIe specification, what they call an endpoint, is what we have
been calling a device. In general, that device is something like a
networking card or a SAS host bust adapter (HBA). A device is always on
the other side of a PCI-PCI bridge. In such a case, the upstream port of
the device (endpoint), is the bridge. The downstream port of the bridge
is the device.

To understand the PCIe state, there is a PCI capability called the PCI
Express capability which has several different registers which are
supposed to describe device capabilities and state and others which
control device behavior.

The Link Capabilities Register (offset 0xc) and the Link Status Register
(offset 0x12) can be used to determine what a given device supports and
what it is linked up at. Further information about what the device
supports is available through the Link Capabilities 2 Register (offset
0x2c).

In addition, the upstream port of a PCIe device has the ability to
request that the link be retrained or the device can suggest a target
speed through the Link Control Register (offset 0x10) and the Link
Control 2 Register (offset 0x30).

The control registers also allow for us to obtain interrupts when a
change in the link state occurs, if the hardware supports it.
Importantly though, this is always going to be on the upstream port and
not the downstream port. However, the fact that this is something that
we can use to know when something changes is useful. We already have
logic to look for information on the bridge when it comes to hotplug, so
it is not a large stretch to leverage this further.

### SAS

SAS devices comes in (as of this writing) three generations of speeds,
with a fourth one coming. These are:

| Gen | Throughput |
|-----|------------|
| SAS-1 | 3.0 Gbit/s |
| SAS-2 | 6.0 Gbit/s |
| SAS-3 | 12.0 Gbit/s |
| SAS-4\* | 22.5 GBit/s |

SAS devices are part of a fabric. For the operating system, it's way of
communicating with that fabric is usually with PCIe based host-bus
adapters (HBAs). As part of this, we need to know what all of the paths
along the fabric support. There are also devices called 'SAS Expanders'
which take as input a fixed number of ports and provide more ports of
output.

The general SAS specifications do not provide a means for getting this
information directly from the device. However, the phy information can
be obtained through a combination of asking the HBA and asking any
expanders, which should all support the SCSI Management Protocol (SMP).
Through SMP and the HBA we can often get the type of link, the minimum,
maximum, and negotiated phy rates.

For example, the SMP SAS phy mode descriptor has information about the
negotiated link rate (byte 5), programmed and hardware minimum and
maximum link rates (bytes 32-33)

Each device on the SAS fabric is identified by a [World Wide Name
(WWN)](https://en.wikipedia.org/wiki/World_Wide_Name). This uniquely
identifies a device on the SAS fabric. To build a full picture of the
fabric, we'll need to now only walk all of the devices that the HBA
sees, but to also go through all of the SMP based devices and the HBAs
themselves to get detailed information about their phys.

To get error counters, we can ask SMP devices for their 'REPORT PHY
ERROR LOG' function. This will include information about the phy
including:

* Invalid dword count
* Running disparity error count
* Loss of dword synchronization count
* Phy reset problem count

### SATA

SATA devices come in three different revisions, each with a different
speed. These are:

| Gen | Throughput |
|-----|------------|
| SATA-1 | 1.5 Gbit/s |
| SATA-2 | 3.0 Gbit/s |
| SATA-3 | 6.0 Gbit/s |

SATA devices can be found either behind a dedicated SATA controller
which is most often based on the [Advanced Host Controller
Interface](https://en.wikipedia.org/wiki/Advanced_Host_Controller_Interface)
(AHCI) specification. Many SAS controllers can also support using SATA
devices as well. SATA devices are supposed to have GUIDs which are
adopted into the SAS WWNs. While SATA does have support for port
multipliers like SAS does, our primary focus will be on direct attach
SATA or SATA devices that are a part of a SAS fabric.

### USB

USB devices are a somewhat complicated affair. There are different
revisions of the USB protocol, such as 1.1, 2.x, and 3.x. There are also
explicit names that are used to describe the speeds like 'full-',
'low-', 'high-', and 'super-' speed devices. These speeds describe the
upper bound in terms of throughput that a device has. While these often
map to a specific USB standard, it can be a little more complicated than
that, unfortunately.

The following table attempts to explain the various speeds that exist
and how they're used.

| Name | Throughput | Protocols |
|------|------------|-----------|
| Low Speed | 1.5 Mbit/s | USB 1.x |
| Full Speed | 12 Mbit/s | USB 1.x, USB 2.x |
| High Speed | 480 Mbit/s | USB 2.x |
| SuperSpeed | 5 Gbit/s | USB 3.0, USB 3.1 Gen 1, USB 3.2 Gen 1x1 |
| SuperSpeed+ | 10 Gbit/s | USB 3.1 Gen 2, USB 3.2 Gen 2x1 |
| SuperSpeed+ | 20 Gbit/s | USB 3.2 Gen 2x2 |
| SuperSpeed+ | 40 Gbit/s | USB 4.0 |

The mapping of speeds to protocols has been somewhat confusing. While
low- and full-speed devices both existed with USB 1.x, only full-speed
made the leap to USB 2.x. Further, USB 2.1 is exclusively used for USB
3.x devices that are operating on a USB 2.0 port.

There are a couple of different ways that exist to understand what a
device can do and what a port is capable of. These vary slightly based
on which device we're referring to. In particular, the way that we
obtain information about a Hub's ports varies based on whether or not
this is the hub built into a PCI USB controller or not.

Starting with the xHCI specification (USB 3.x), a single controller
could have ports that operate at different speeds. Each xHCI instance is
required to have at least one instance of the 'xHCI Supported Port
Capability' which allows us to understand and map a group of ports on
the controller to the set of speeds that they provide. This capability
describes the speed capabilities of the given port. This allows us to
know whether a given port supports which variant of USB 2.x and USB 3.x
speeds.

On the other hand, with devices it's a bit more complicated. There are
two different mechanisms that we can use. First, the device declares
what USB specification it is compliant to in its standard USB Device
Descriptor. The `bcdUSB` field has the version of the USB specification
the device is compliant to. There are additional descriptors that are
returned that describe the USB endpoints that can hint at the
capabilities of the device. These include the SuperSpeed Endpoint
Companion and SuperSpeedPlus Isochronous Endpoint Companion descriptors.
The latter is optional, so it isn't a reliable way to identify this
case.

However, there is a secondary mechanism that exists in the USB to
identify information that was introduced with the USB 3.0 and USB 2.0
LPM specifications. This is called the 'Binary Object Store' or BOS.
This store contains multiple pieces of additional information about a
hardware device. While this is only present for USB 3.x devices, the
information is most relevant for USB 3.x devices. For example, there is
a SuperSpeed USB Device Capability which describes the lower speeds that
the device supports and also something that describes the lowest speed
the device can operate at. As this is required of all USB 3.x devices,
it provides a lot of useful configuration information. In addition, we
can get information about SuperSpeedPlus devices and what they require.

While USB devices don't support the ability to control what speeds they
link up, that's determined entirely by hardware, we do have the ability
to power cycle them through
[cfgadm(1M)](https://illumos.org/man/1m/cfgadm) today.

### Network Controllers

Networking devices represent a historically well-trodden ground in
multiple operating systems. Generally, cards support different speeds
and the cables themselves also support different types of speeds. The
selection of which speeds are used or retriggering a negotiation is
controlled in illumos through the
[dladm(1M)](https://illumos.org/man/1m/dladm) utility.

A given link state is described by its combination of the speed of the
link and whether the link is full-duplex or not. A full-duplex link
means that the cable can transmit and receive at the described rate at
the same time. While Ethernet has historically supported a half-duplex
mode, it was dropped from 10GBASE-T and was, generally speaking, not
supported when using transceivers such as SFP/Twinax.

Ethernet devices support different speeds and different types of cables.
The different types of cables that exist support a set of speeds. These
also then intersect with the other end of a device and after a
negotiation, one is picked.

Currently, we're missing support for explicitly bringing down or
bringing up a link, though dladm does support understanding the current
link capabilities. Some hardware is more upfront about what it supports
versus others, though with Ethernet there are more dimensions that we
need to consider and control.

## Implementation Ideas

There is a log of groundwork required for each different type of device
in the system that we have here. This is broken down into additional
sections based on the general focus that they have.

### phy visibility

One of the first things that we want to do is to go through and improve
the phy visibility for each of the different parts of the system and rig
up ways of knowing when they've changed, when possible. The means by
which we expose this information will likely vary based on the device in
question.

Today, [dladm(1M)](https://illumos.org/man/1m/dladm) already has the
means to communicate the information about the phy state to the system.
Though, some supplemental information about what the cable supports is
available through the private library, libsff, which knows how to parse
information about SFF based transceivers (generally SFP/twinax based
products).

USB devices already have information related to them available in the
devices tree and some basic information available in the form of the
hardware chassis topology tree. See [RFD 147 Project Tiresias: USB
Topology](../0147/README.md) for more information. Given that USB
devices have static information, it would likely make sense to add
additional devinfo properties that are then consumed by the hardware
chassis topology tree.

disks and PCIe devices do not currently expose any phy related
information at all. We could put some of this information on the devices
as devinfo properties, but it's not clear that that representation will
make sense for all such things. While it's useful for a disk to indicate
that it's at a certain speed, it's not clear that it's useful to try and
cram the devinfo tree full of all of the different ends that an expander
of PCIe switch has.

There may be value in trying to build a general ioctl that we can use to
do things like:

* Identify the type of phy a device has
* The number of phys that a device has
* Information about each phy

There is a bit of a framework for this that is supposed to exist in the
form of the library
[libSMHBAAPI](https://illumos.org/man/3lib/libSMHBAAPI). However, it is
likely the case that it will need to be extended and other devices will
need to be added to support it. This powers the
[sasinfo(1M)](https://illumos.org/man/1m/sasinfo) command. It's likely
the case that we'll need to determine how much of this infrastructure or
how much overhaul all of this requires to meet our needs. We'll need to
dig in a bit further.

#### Hardware Chassis Tree

Ultimately, I believe all of this basic information about the current
running state of a device should be exposed as a property group on the
node representing the device. While we should have a similar form
between the different types of devices, because each one has slightly
different needs and values, we should not try to standardize the
existence of it too much or if we do, we should have a standard property
that indicates the type of property group to go search for more detailed
information under.

### Managing phy state and resets

When it comes to setting the phy states and resetting devices, it seems
like the best starting point is likely to end up being cfgadm. Already
today SATA, SAS, and USB devices are enumerated under it. When the
hotplug service is enabled, then a number of PCI devices are also
enumerated under the device. This to me suggests that when we want to
perform actions that manipulate the phy state of a specific device, that
cfgadm may be the best place to start looking at adding that
infrastructure, especially since it already had support for some of
this.

It is true that cfgadm can sometimes be a bit oblique. But our recent
experience with the `hotplug` command suggests that some of the basics
of cfgadm are still more straightforward. To me it's an open question as
to how we end up wanting to proceed. While cfgadm is an easy way to add
things, it's not the friendliest interface and it will likely be
awkward. On the other hand, I don't believe that adding a phy-centric
thing is necessarily the right way forward. It may make more sense to
add additional device-centric commands. So adding things that operate
on USB devices, disks of all kinds, etc.

### SAS and PCIe Topology Fabrics

One thing I believe that makes sense for us to concretely add are new FM
topologies that are specific to SAS and PCIe. The current hardware
chassis topology view is not a good fit for these as the hardware
chassis view is based on an operator-centric physical view of how things
fit together.

There are a couple of different things that cause us to want a new view:

1. These fabrics are not modeled as a tree, but rather are closer to a
DAG.
2. We want to name FMRIs not based on their hierarchical structure, but
based on concrete properties of the device because there may be multiple
paths to a given device on a fabric.

Concretely, we should add support to fmtopo, and to FMA in general, for
these new types of trees. This will allow us to build diagnosis engines
that are better aware of the different paths and also allow us to
serialize this information in a way that other tools like AdminUI can
then visualize and augment.

These topology fabrics might be the right way to surface the statistic
counters that we've talked about as well at a first glance. Though it
likely won't be the final form that makes sense for them.

### Change notifications

I think the most straightforward way to implement change notifications
would be to generate a sysevent that describes what type of device has
changed. It's not clear that we can relink devices other than PCIe
without a reset or if they can be, that we get an interrupt when that
happens. At the very least, we'd add logic to the PCIe bridge driver
(pcieb) to manage this.

### Alerts

At the moment, I think it doesn't make sense to go into too many details
about how alerts should be synthesized for these kinds of events. It may
make sense to have the FRU monitor take these sysevents or poll devices
every once and a while to determine what the phy state is and compare it
to known expectations. It may be that we have to describe what we expect
in a platform-specific file much like we have topo extensions via
platform-specific XML.

We'll need to circle back on this as we do more research and more
initial development to see what makes sense.

## Future Directions

There is still a great deal of additional research needed on all of
these projects. However, once we have the initial per-server view taken
care of, then we should figure out how to better reflect this
information and aggregate it across the broader fleet. Different things
that we can imagine include:

* Integration of stats with CMON, etc.
* Being able to visualize the hardware chassis and topology fabrics
through something like AdminUI.
* Being able to drive some of the control mechanisms into upstack
components like various CLI tools or browser interfaces.
* Being able to leverage this in some of the broader ideas of RFD 88
about server classes and validating at run time the current state of the
system.
* Integrating with broader future evolutions of the Triton and Manta
alerting systems when state changes to something that might require
operation action.

## See Also

* [RFD 6 Improving Triton and Manta RAS Infrastructure](../0006/README.md)
* [RFD 7 Datalink LLDP and State Tracking](../0007/README.md)
* [RFD 8 Datalink Fault Management Topology](../0008/README.md)
* [RFD 27 Triton Container Monitor](../0027/README.md)
* [RFD 88 DC and Hardware Management Futures](../0088/README.md)
* [RFD 89 Project Tiresias](../0089/README.md)
* [RFD 94 Global Zone metrics in CMON](../0094/README.md)
* [RFD 147 Project Tiresias: USB Topology](../0147/README.md)
