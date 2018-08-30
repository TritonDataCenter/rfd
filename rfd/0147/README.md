---
authors: Robert Mustacchi <rm@joyent.com>
state: publish
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+147%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joynet, Inc.
-->

# RFD 147 Project Tiresias: USB Topology

This RFD is an extension of [RFD 89 Project
Tiresias](../0089/README.md). RFD 89 suggests the idea of having USB
topology, which this document attempts to describe.

## Background and Complications

Unlike many other pluggable interfaces, there is a significant
disconnect between USB ports that a user plugs devices into and how USB
ports appear to the operating system. The operating system interfaces
with USB devices through the host controller. There may be multiple USB
host controllers present on the system. Often times these are part of
the chipset; however, it is also possible to install PCI cards that are
USB host controllers.

The host controller has some number of logical ports which it exposes,
each of which has a port on it. In many ways it functions as its own
style of USB hub. The visible physical ports may be directly wired up
to the host controller or there may be one or more intermediate USB hubs
that are present.

### USB 3

With the introduction of USB 3, the situation became much more
complicated. To maintain backwards compatibility with USB 2 devices, a
USB 3 port generally has two independent sets of wiring: one for USB 2
and one for USB 3. This allows users to plug either USB 2 or USB 3
devices into the port in an interoperable fashion.

Along with USB 3, a new host controller interface specification (xhci)
was introduced. The xhci specification supports both USB 2 and USB 3
devices, eliminating the need to also have a USB 2 controller (ehci).

Aforementioned USB 3 ports that have wiring for both USB 2 and USB 3
devices are connected to two different logical xhci ports. This means
that a single physical port can show up as two different logical ports.

In an attempt to allow operating systems to be able to better understand
this information, the xhci specification suggests a method for allowing
the operating system to tell that these two logical ports are the same.
The method in Appendix D suggests using the ACPI _PLD method for USB
objects. The ACPI _PLD method returns a byte array that describes the
physical device location. If a subset of these values are equal, then the
two ports are the same.

This method only applies to ports on an xhci controller, it does not
apply to ports on an ehci or older USB controller.

#### USB 3 Hubs

Many USB 3 hubs support both USB 2 and USB 3. They take advantage of the
same wiring trick that is described above. While most devices will
connect to only one of the USB 2 or USB 3 wiring, that is not true for
USB 3 hubs. When one is plugged into a USB 3 port, it will connect to
both the USB 2 and USB 3 wiring. This causes it to show up as two
disjoint devices, even though it's in the same physical port.

While we can map the logical ports together as described above, that
only applies to the root port or other ports that are part of the
chassis. The USB 3 hub descriptor does not describe a way of telling us
that its USB 2 and USB 3 ports are actually identical physical ports.

### Systems with ehci and xhci

When USB 3 was initially introduced, most systems that had an xhci
controller still retained ehci controllers. Based on the BIOS
configuration, most ports would start connected to the ehci controller.
However, it was also possible for the physical ports to instead be wired
to the xhci controller and various Intel chipsets provided a means for
the devices to be redirected to the USB 3 controller by software.

One of the goals that we have is to be able to map these disjoint ports
together. We want to know from a topology perspective when the same
physical port is the same whether its using ehci or xhci.

With the introduction of Skylake, Intel has dropped support for the ehci
controller from chipsets, so this mainly is a problem on systems from
approximately Sandy Bridge through Broadwell.

### ACPI

The Advanced Configuration and Power Interface (ACPI) specification
provides two methods for ancillary information about a USB port. This
information can describe not only the ports on the root hub, ports or
built-in hubs.  There are two different ACPI methods that we care about.
The first is the USB port capabilities: `_UPC`. The second is the
physical device location: `_PLD`.

The USB port capabilities information can tell information about what
form factor a USB port is. It also, when combined with the _PLD data is
supposed to tell you about whether a port is user-visible or not or
whether something is wired up by default.

While a number of the host controller logical ports are physically wired
up, the vast majority are actually just sitting on headers and aren't
wired up. As such, the ACPI information for these usually does not
define a defined port type or other information.

## Goals

Before we define how the topo system should be laid out, we should
discuss our goals.

1. We want to know what USB devices are in the system and which ports
they are physically connected to. This includes USB device that are
hanging off of child hubs. This allows us to know that if a given device
is disconnected, then everything under it has been.

2. We want to know where the USB port in question actually is. This USB
port may be sitting on the chassis somewhere external. It may be
internal to the chassis. This information is useful in so far as putting
together policies for systems like [RFD 77](../0077/README.md) where we
want to have stricter trust policies on what devices we'll use for
signing.

3. For known ports that operators see, we should be able to provide
human readable labels such that it's easier for operators and
technicians to be able to service these devices.

4. Where possible, we should be able to provide information about the
USB protocol and speed that is supported by ports and being used by
devices.

## Topology Tree

Our plan is to introduce two new topology nodes, one that represents a
USB port and one that represents a USB device. The location of these
nodes will vary depending on the node itself. First, we'll describe what
these new topology nodes look like and the properties that they cover.

### Topo Nodes

#### USB Port

A USB port node is a node of type `port`. The port type was introduced
earlier in [RFD 89 Project Tiresias](../0089/README.md) for NIC
transceiver ports. There will be two property groups that are a part of
this and a label.

The first is the `port` group, which will have a single string property
`type` whose value is always `usb`. As discussed initially in Project
Tiresias, the type field is always required for a port node and will be
used to inform the user to find a property group that has additional
information specific to that kind of port.

The second property group is the `usb-port` property group. This
represents information about the USB port itself. Currently the
following properties are defined:

* `port-type`: A string that describes the physical USB port. This is
currently based on the ACPI list of port types and includes entries such
as 'Type A connector' or 'USB 3 Micro-AB connector', etc. This describes
the physical connector type on the port and some aspects of its wiring,
if known.

* `usb-versions`: An array of strings that indicates the supported USB
protocol versions that a port supports. This will include the following
strings, '1.x', '2.0', '3.0', '3.1'. On most systems, the '1.x' will not
show up unless an older system with the ohci or uhci controllers are
present.

* `logical-ports`: An array of strings which is used to describe the set
of logical ports that are present here. These are described in a variant
of their cfgadm paths. Each string has two parts, a driver and instance
number, combined with the path to the usb port. For example, port 3 on
the xhci instance 0 would be described as `xhci0@3`. Ports that are on
hubs are described with their port path, much as is used in cfgadm. For
example a if ehci port 1 was a hub and there was a device on port 5 of
that, we would describe this as `ehci0@1.5`. There will be one logical
port entry for each host controller port that maps to this port.

* `port-attributes`: This is an array of strings that describes
different aspects of the port. These aspects currently include:

1. `internal-port` to describe that a port is known to not be accessible
without opening up the chassis.
2. `external-port` to describe a port that is accessible external to the
chassis.
3. `user-visible` to describe a port that has is supposed to be
something that a user can see by default as described by ACPI.
4. `port-connected` to describe a port that is not visible, but has been
wired up to another device.
5. `port-disconnected` to describe a port that is physically not wired
up to anything.

Finally, if we have information such that we can set a human readable
label, then the port will have a label set to that string.

#### USB Device

For a USB device we want to have a node that describes what that device
is and information about the device. The USB device is currently planned
to have two different property groups, one which describes properties of
the USB device and the other is the traditional `io` property group
which describes properties of the driver.

The following fields of the `io` property group are currently planned on
being filled in:

* `driver`: Indicates the driver in use.
* `instance`: Indicates the instance of the driver for the device
* `devfs-path`: Indicates the path in `/devices` for the device
* `module`: The FMRI of the module that's in use.

We are also planning to have a `usb-properties` group that is used to
describe information about a USB device in the system. This will have
the following properties`:

* `usb-vendor-id`: An integer that represents the USB vendor id declared
by the device.

* `usb-product-id`: An integer that represents the USB product id
declared by the device.

* `usb-revision-id`: A string that represents the USB revision
declared by the device. While this value is traditionally a binary coded
decimal value, there will be no attempts to translate this into major
or minor values and instead it will just be a hexadecimal string.

* `usb-vendor-name`: A string that includes the device's USB vendor
string obtained from the configuration descriptor. This may not always
be different.

* `usb-product-name`: A string that includes the device's USB product
string obtained from the configuration descriptor. This may not always
be present.

* `usb-serialno`: A string representing the device's serial number. This
is obtained from the configuration descriptor when it is present.

* `usb-version`: A string that represents what USB version this device
is currently linked up at. USB 3 devices that are plugged into a USB 2
port will describe themselves as running at version `2.1` to indicate
that they are USB 3 capable, but running at USB 2 speeds.

* `usb-speed`: This will be one of the following strings 'full-speed',
'low-speed', 'high-speed', and 'super-speed' to indicate the speed that
the device is operating at.

* `usb-port`: This will be an integer that suggests the port number of
the parent device.

##### Child Nodes

There are currently two cases where we will go and create child nodes
for usb-devices. The first case is for instances where a disk node
should be created underneath. If the `scsa2usb` driver is present, we
will add the additional required property groups such that a disk node
can be enumerated.

The second case is where we find that an instance of `hubd` is present.
In those cases, we will then enumerate child ports under the device.
Those child ports will then have devices enumerated, if they are plugged
in and present.

### Enumeration Points

There are three different points of entry for enumerating USB ports that
we are considering:

1. Ports that are on the chassis (this includes rear ports from the
motherboard passed out the back).

2. Ports that are on the motherboard.

3. Ports that belong to discrete PCI(e) expansion cards.

Any PCI card that belongs to a discrete slot will be explicitly
enumerated and all of its ports will be associated with that device.
This means that it will show up in the tree as a child of a PCI or PCIe
node and its parent slot.

Any controller that is not enumerated in the above fashion, will be
considered as part of the motherboard as it will almost certainly be a
part of the chipset. Ports will need to be indicated that they belong to
part of the chassis. The method for doing this will be described later
on.

### USB 3 Hubs

USB 3 hubs present an interesting challenge. As discussed in the
background section, they show up as two different distinct USB devices
with no real good way of knowing that they are actually the same device.
While there are hacks that could be done to try and figure out this
mapping, they don't work past the root hub.

As such, I think it makes sense to just treat them as two separate USB
devices. While this is a little unfortunate for the case of nested hubs
which are really the same device, piratically, there aren't many options
for us given that we don't actually have information to match them up.

### Mapping Logical Ports Together

As part of this, I believe that we should attempt to map all of the
logical ports together in the system that we can. The case of xhci is a
little bit simpler as in theory there will be ACPI information (this is
more complicated in practice); however, ACPI doesn't cover the case of
ehci and xhci.

Effectively, for root ports, a single port will be created that knows
about all of the logical ports it is a part of. For other ports where we
don't know because it may require headers or other information, then
they will not be joined. If we later get information, they will then be
joined together, which will cause the FMRIs for ports to change.
Unfortunately, there isn't a good way of dealing with this in the face
of changing information. However, we will know which ports they were due
to the fact that the logical ports are there. Further, if we have
information like serial numbers or revisions, that information will be
part of the FMRI to try and give us more information.

#### Trusting ACPI data

While it'd be nice to trust the ACPI data in a given system for the
purpose of matching logical ports together, we have seen issues with
that in the field where the ACPI information provided is in fact
incorrect. As such, we're going to opt to make the default to disable
ACPI based port matching.

### Product-specific usbotpo Metadata File

To glue all of this information together we'd like to propose a new
metadata file that exists on per-product basis like existing topology
maps. This file which we're calling a `usbtopo` metadata file serves
several purposes:

* Provides labels for ports.
* Allows additional metadata for ports to be provided.
* Allows for overrides of the port-type when ACPI information is
incorrect or lacking.
* Provides a means for mapping logical ports together when there are
issues with ACPI.
* Allows ACPI port matching to be enabled for a platform.

This file format is erring on the side of being perhaps too simple and
eschews the traditional XML format of topo. However, this file format is
intended to be 100% private to the gate and changed at any time.

The `usbtopo` file format will have a series of directives, one per
line. Leading and trailing whitespace on each line will be trimmed;
however, using whitespace to make contents clearer is recommended. A
comment can be created with a `#` character.

The file will consist of a series of port declarations. A port is
started using the `port` declaration and ends with the `end-port`
declaration on a line. All lines between that are used to describe
aspects of the port.

Inside of a port, the following strings are supported to indicate
properties of the port:

* `label`: The subsequent line will have a string label that describes
the port.

* `chassis`: This indicates that the port should be thought of as
belonging to the chassis. This causes the port to be enumerated under
the chassis and not any other port.

* `external`: This indicates that the port is externally accessible to
anyone passing by the system.

* `internal`: This indicates that the port is only accessible if the
chassis is open.

* `port-type`: This indicates that the following line will contain a
number corresponding to the ACPI _UPC port type table.

* `acpi-path`: This indicates that the following line will contain a
string path that is the ACPI value for this port that is one of the
matching values for this entry. Multiple entries indicate different
logical ports that are all mapped to the same physical port.

Finally, the additional top-level directives will be supported:

* `enable-acpi-match`: Indicates that the platform should explicitly
enable ACPI based port matching.

* `disable-acpi-match`: Indicates that the platform should explicitly
disable ACPI based port matching.

Regardless of whether or not ACPI matching is enabled, multiple path
entries for a logical port will map to the same entry.

The following is an example of the file format. Again, the use of
whitespace between entries is mostly to make it clearer to the writer as
to the relationship between entries:

```
port
        label
                Rear Upper Left USB
        chassis
        external
        port-type
                0x3
        acpi-path
                \_SB_.PC00.XHCI.RHUB.HS02
        acpi-path
                \_SB_.PC00.XHCI.RHUB.SS02
end-port

port
        label
                Rear Lower Left USB
        chassis
        external
        port-type
                0x3
        acpi-path
                \_SB_.PC00.XHCI.RHUB.HS01
        acpi-path
                \_SB_.PC00.XHCI.RHUB.SS01
end-port

port
        label
                Rear Upper Right USB
        chassis
        external
        port-type
                0x3
        acpi-path
                \_SB_.PC00.XHCI.RHUB.HS04
        acpi-path
                \_SB_.PC00.XHCI.RHUB.SS04
end-port

port
        label
                Rear Lower Right USB
        chassis
        external
        port-type
                0x3
        acpi-path
                \_SB_.PC00.XHCI.RHUB.HS03
        acpi-path
                \_SB_.PC00.XHCI.RHUB.SS03
end-port

port
        label
                Internal USB
        internal
        port-type
                0x3
        acpi-path
                \_SB_.PC00.XHCI.RHUB.HS10
        acpi-path
                \_SB_.PC00.XHCI.RHUB.SS07
end-port
```
