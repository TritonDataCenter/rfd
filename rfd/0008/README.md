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
    Copyright 2015 Joyent Inc.
-->

# RFD 8 Datalink Fault Management Topology

This RFD introduces the notion of a datalink topology tree within the
broader FMA topology tree.

## Problems

When managing systems and dealing with issues of physical datalinks,
there are several questions that we often try to answer.

1. Which add-on card or on-board device in the chassis is responsible
for driving a driver instance. For example, which slot has ixgbe0 and
which slot has igb0. Or, when there are four on-board devices, which
locations are igb 0-4.

2. What are these devices connected to in the context of the broader
network? What port at they plugged into on an upstream device, if any?

3. What is the current state of the device, if there is a failure, what
are the set of impacted links or services on the machine?

The goal is to address several different aspects of the operate rational
experience and life time of managing these devices, similar to the life
time and management of disk devices. Information on upstream devices can
be useful in diagnosing cable problems, switch misconfigurations, or
general failure.

## Goals

The purpose of this part of the toplogy tree is to associate several
different pieces of information that eixst inside of the system today:

* Physical datalinks and the slots that they're plugged into
* Describe the state of the physical datalinks in the system
* Relate the current chassis to the next hop of connected chassis,
  allowing a picture of the datacenter to be built

## Datalink topology group

To this end, we'd like to add a new datalink topology group which
contains information related to the state of the datalinks in the
system. By default, only datalinks corresponding to **physical** devices
will be included.

The datalink group will have the following properties:

**name**: The current name of the datalink. This is the name that is
used when accessing the datalink with
[dladm(1M)](http://illumos.org/man/1m/dladm).

**class**: This is a string which represents the class of the device.
These correspond to the various datalink classes defined currently in
`<sys/dls_mgmt.h>`. The only valid class that will show up for now is
`DATALINK_CLASS_PHYS` which should be encoded as a string.

**type**: The type of the device refers to the MAC plugin that we're
using. In this case, we refer specifically to things such as whether the
device uses Ethernet, Infiniband, etc. This will be used to help decode
the logical address category later on.

**address**: This is a string that represents the current address of the
datalink. The format of this depends on the type of the data.

**in-use**: This is a boolean property which indicates whether or not
the port is currently being used by any clients. Note that this is
different from the dladm notion of in-use which only cares about the
usage of the MAC address, as opposed to the physical port itself.

For example, a VNIC is created over some device and uses it; however,
because a VNIC has its own MAC address, it does not actually use the
MAC address of the device, which is what dladm's `INUSE` property is
trying to address.

**state**: This is the current state of the link, there are currently
three valid states for a link which mimic
[dladm(1M)](http://illumos.org/man/1m/dladm):

1. **Unknown**

2. **Up**

3. **Down**

**mtu**: This is the current value of the maximum transmission unit for
the device. This must represent the largest frame that the device can
send, not accounting for any defined margin on the datalink. While today
the MTU of the physical datalink represents the maximum of all devices
under it, if that were to be divorced, then this value must still
represent the current value of the physical device as configured in
hardware, as opposed to the logical entity.

**lldp-address**: This refers to the current upstream address that we
have received via the Link Layer Discover Protocol. Note, this will not
be present if there is no source of LLDP information available.

**lldp-chassis**: This refers to the current upstream chassis as noted
by the Link Layer Discover protocol. This will not be present if there
is no source of LLDP information available.

**lldp-port**: This refers to the current upstream port as noted by the
Link Layer Discover protocol. This will not be present if there is no
source of LLDP information available.

**lldp-stale**: This is a boolean property that reflects whether or not
the LLDP information is stale. When handling LLDP information, we may
have had information that we cannot confirm. For example, if a link is
down, we'd like to still note the last piece of information that we had
seen.

### FMRI Scheme

For datalinks, we'd like to propose a new top-level FMRI scheme called
`dl`, which stands for datalink. Currently all physical datalinks will
be a child of the top-level `dl` node and will all be siblings of
one another. Any top-level datalinks (which could include etherstubs and
overlays) will be at this immediate level.

### Datalinks delegated to zones

One way to configure zones is with non-transient datalinks which may be
delegated or given to the non-global zone. A datalink that enters there
is considered inside of the zone and no longer present in the global
zone. No matter which zone a datalink is in, it will still be eligible
for the topo tree.

However, because the zone may be given a physical datalink, that may
cause other global zone services to not be able to see the device by
default. For example, the LLDP daemon will not run on a datalink that
belongs to a non-global zone which may leave the LLDP information
unavailable for such a datalink.

## Relationship to existing topology tree

In an ideal world we'd be able to associate the (typically) PCI device
with the datalink state above and with the port and chassis information.
Because of the fact that the kernel knows what datalink corresponds to
what entry in the devices path, we should generally be able to fill in
that information.

Ideally we'd like to then relate this information to the chassis if
possible. While parts of smbios can be used to determine what physical
slot they are plugged into, if there is more than one port on a card, we
need a better way of determining which port is which. This likely
requires assistance from hardware manufacturers to achieve correctly. It
will be a future project to determine the best way to incorporate that
into our information, specifically when dealing with broader third-party
hardware vendors.

## Deliverables and Dependencies

This RFD builds on top of [RFD 7](../rfd/0007). It will leverage the
LLDP information which that RFD proposes collecting. Based on this we'll
deliver the following:

* A new fmtopo plugin which plugs into the topology tree and generates
  this logical datalink information.

## Future Work

In the future, we'd like to augment the static topology maps to define
the physical port/PCI function mapping and include that information.
Some ways we might be able to do this is to work with vendors to define
an order of the cards, eg. we might be able to say all bnxe or all ixgbe
multi-port configurations follow this pattern. Or for these device ids
versus others. If we have that, we may be able to then augment the topo
map that relates the orientation with the way that it was plugged in.

Another aspect of this which may become something interesting is to
further invest in ways to define topology maps such that, through
adminui, a class of topology maps can be created by the users of the DC
and associated with a class of servers or even if a single system. Those
additional maps could then be added via boot-time modules.

### Including more than physical devices

Another thing that we could consider doing in the future is including
additional devices such as VNICs, bridges, overlays, VPNs, etc. in the
logical datalink tree. That is partially why the class property is
currently present. It allows us to differentiate what might exist. If we
were to do this, we'd define additional children of the physical
datalinks for devices that rely on them and we'd define siblings for
things like etherstubs and overlays which may have their own children.
