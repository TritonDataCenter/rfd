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

# RFD 88 DC and Hardware Management Futures

Managing hardware is at the core of Triton and one of the more
challenging areas to scale. With the rise of the cloud, we are often
seeing fewer people buy more and more machines. The best examples of
this are the likes of Google and Facebook. This leads to a couple of
important high level questions:

* How do we scale the management of a data center?
* How do we make the day to day work of operations staff simpler so they
spend less time fighting fires and can focus on more complex, strategic
problems?
* Can we change what we put into the DC to support these goals?

There are a lot of different avenues to explore here. This document is
organized as follows. The first section gives additional
background information. The second talks about the questions that
we're trying to answer. The third discusses various constraints we have
on the problem. The fourth goes through and lays out various thoughts,
approaches, and proposals.

## Background Information

This section provides a brief introduction to the different parts of the
chassis and data center that we care about as well as some of the
terminology. 

### Triton Today

Today Triton provides basic capabilities for managing servers. Servers
are all operated on independently. Operating on groups of servers has to
be performed via scripts.

Servers can be setup and forgotten. As part of setup some nictags can be
defined; however, the bulk of traits, link aggregations, etc. is done
after initial set up is complete. Sometimes causing the actual IP
address assigned to the CN to change.

### Chassis components

When we talk about a chassis, we're often talking about a server that is
made up of several different parts. Many of these parts are called
'FRUs' or field replaceable units. The reason we think about FRUs is
that they represent an individual replaceable unit on the system. For
example, on most of our servers, the disk is a FRU as is each stick of
DRAM. They can be independently replaced.

However, if you think of the modern laptops from Apple, many of the
pieces are all soldered together. If the CPUs and DRAM are all soldered
to the motherboard, that means that the FRU represents all of those
components -- a failure in one of them means that the whole unit has to
be replaced.

In addition to FRUs, we have a secondary notion which we'd like to
introduce: the Upgradeable Firmware Module (UFM). A given FRU may have
zero or more UFMs on it. For example, a disk drive is a FRU, which has
firmware which can be updated without replacing the FRU itself. For this
categorization, we're interested in what software can upgrade without
having to send a technician to replace a part. On the other hand, a
Yubikey's firmware can never be modified. While it is a FRU, it is not a
UFM.

With that in mind, I'd like to review the major components of the
system.  Parts noted with a '(+)' generally have a UFM of some form or
another. Whether it be firmware, microcode, an EEPROM, etc.  Some of
these components only consist of software and firmware.

* Motherboard
* CPU (+)
* DRAM
* Fans
* Host Bus Adapters (HBAs) (+)
* Disks (+)
* Network Interface Cards (NICs) (+)
* Optics
* Expanders / active backplanes (+)
* Power Supply Units (PSUs)
* Lights Out Management (LOM) (+)
* BIOS/EFI (+)
* Other PCI devices (+)
* USB Devices (internal and external) (+)

### Data Center Components

When we're talking about the data center there are many different
components that we're concerned with. These are ordered in terms of the
order that we care / worry about them.

1. Servers
2. Racks
3. Top of rack switches (TORs)
4. Power distribution units (PDUs)
5. Other networking devices such as aggregation and core switches,
routers, etc.
6. Other devices in the rack, networking related, or otherwise


## Framing Questions

To start, we'll first list questions which cover the regular tasks and
challenges of dealing with the data center and hardware.

### DC Management

This group of questions covers managing the DC as a whole.

* What is in the DC?

This asks everything from how many servers of what type exist to how
many sticks of DRAM broken down by manufacturer exist. This also covers
more than just servers. For example, we may want to consider things like
racks, PDUs, switches, etc.

* Where is everything in the DC?

Operators who are working in the DC want to know where things are
located. If something needs to be serviced, they need to be
able to have an idea of where to find it. This extends beyond just
servers.

In addition, Triton wants to have some degree of visibility into the
physical layout so that it can properly honor affinity requests. For
that we need to have a sense of where shared fault domains are.
Conventionally those domains are based on the rack today, though they
are really based more on PDUs and switches.

* What is currently broken in the DC?

As part of doing basic, daily work, it's important to understand what's
not functioning in the DC. Getting that information easily is important
as well as being able to quickly and correctly asses the impact.

* How do we add something to the DC? How do we remove it or repurpose
it?

This covers the policies and steps to add new equipment to the DC and
ensure that it is properly configured. As well as what are the actions
we need to take when it leaves.

* What is the history of this DC?

This is a rather broad question and there are a lot of different ways to
think about this. For example: When did a given component (part, server,
switch, etc.) enter the DC?  When does it need to leave? How has it
changed? What incidents has it had?

Importantly, this then raises questions like how do we analyze and
summarize this across the fleet? Including things which have come and
gone from the DC? 

### Chassis Management

While these questions are focused on servers, they extend to other
devices in the DC, though not all of them are things that Triton manages
today or is planned to.

* What is in it?

This covers questions like who makes the server and what FRUs and UFMs
make it up, etc.

* What is it connected to?

There are two different lenses through which to view this question. One
is from a logical networking-based view. As in what can it talk to and
what switch is it plugged into. The second is from a physical view.
Where are the various cables that are plugged into it connected to? For
example, power cables.

* Where is it?

This is asking how does an operator find something in the data center.
It also covers how do we identify a specific unit or part that we care
about in the DC.

* Is it Healthy?

There are many different avenues and subquestions that arise from trying
to determine health. The following questions are some brainstorming ways
to think about this. Is the FRU working? Can it talk to what we expect?
How is the environment (thermals, etc.)? How is the service it provides?
Is it experiencing failures or errors?

* How do we change it?

This covers questions around how do we deal with and perform changes to
system settings, firmware, and scheduled parts replacement.

## Constraints and Realities

As we brainstorm proposals and suggestions, we need to keep in mind the
following to help guide us.

* Commodity Components, Custom Components, and Financial Realities

Money does not grow on trees. Whatever things we want to do should be
generally commercially and financially viable. We're not yet at the
point where extensive custom hardware designs are likely going to end up
being a great ROI. As we evaluate these different options, understanding
the costs associated with them is important.

In general, we'll prefer commodity components available, ideally, from
multiple vendors. However, that doesn't mean that we'll completely rule
out custom things for our own designs and desires. We're still a very
large purchaser ourself.

* Broader Customer Base

While there is a big emphasis on what do we believe we need to manage
our own data center, one thing to remember is that other customers will
have other constraints. The same way that fabrics did not constrain
customers to a particular switch vendor, it is important that we
remember that.

This doesn't mean that we shouldn't do or purchase things that only have
utility for ourselves. After all, our own internal use of Triton is
important.  However, we need to consider how applicable things are to
other customers while designing anything new.

A different way to see this is in the general world of hardware support.
We don't have the luxury of always deciding what a customer should use
in terms of hardware. While there are things that we do not support and
have made the explicit choice not to, we need to remember the trade offs
involved. Where we can avoid cutting off a swath of the market, we
should probably err on that side.

* Closed Source and Vendor Cooperation

Many aspects of what we talk about revolve around firmware management
and other traditionally closed source ecosystems. For us to properly
implement many of these things, we need vendor cooperation. So, much of
what we talk about may only ever be aspirational. It will be tempered by
the underlying realities of the situation.

Similarly, we want to try and ensure that we don't become encumbered and
are unable to open source parts of this stack. 

## Exploration and Proposals

This section attempts to help answer the questions that we posed above.
These ideas are still rather exploratory. The idea here is to prompt
discussion. Nothing should be thought of as definite! 


### Server Classes

The idea behind a 'server class' is that we want an abstract
representation of a server. It represents what many servers should look
like and can be used to help automate many parts of server management.

A server class contains the following kinds of information:

* Set of parts, FRUs, and UFMs
* zpool layout
* NIC Tags
* Traits
* Link Aggregations
* System Firmware Settings
* IPMI/LOM configuration

These classes can be defined by users and
constructed from existing systems. By default, we would try to use
things like SMBIOS and other part configurations to try and suggest a
server class that the system belongs to; however, it would still be up
to the operator to decide which one to apply, if any. A DC should always
function without server classes being defined or assigned to any server.

The server class will be used in a few different parts of a server's
life cycle. For example, this can be used to help automate setup of a
server by going through and applying default settings such as nic tags,
traits, etc. to a system to avoid an operator having to manually do such
a task. For example, an operator might define a class for a Richmond A
or Mantis Shrimp.

There are other ways we could leverage systems with a defined server
class. We could look for deviations in FRUs and UFMs and alert to that.
We could also use this as a way to help drive a broader fleet-wide
firmware upgrade and define how to take a UFM from one version to
another.

This should also be used as a way to report on what's inside of the data
center. For example, we could use these classes as one way to group and
summarize things. Say, we have so many Mantis Shrimp MK III, so many
HAs, and so many of the different HC models.

Another possible way we could use this is to construct various
`/etc/path_to_inst` style files so that we could have consistent naming
of network ports, etc.

##### Componsing Classes

While thinking about how to design these different classes, we should
also think about how to compose them, whether it's through a more
traditional inheritance-like strategy or something else. Consider a
data center that has both a traditional Manta installation and also
offers Triton compute. Both may use the same hardware for the manta
metadata tier and for the Trtion computation tier.

One way to approach this is that we have a base class for these shared
machines, that represents the class of machine and describes the vast
majority of the configuration, but then also have a Manta class. The
Manta class for these metadata nodes would define the additional NIC
tags and traits that may be required for Manta and any other
customizations.

The appeal of an inheritance-like model is that then when trying to
report on these, we can still group on the broader class for reporting
information, while retaining the ability to break down into smaller
groups if needed.

#### Visualizations

One thing we'd like to be able to do is visualize a given server class.
The inspiration from this comes from our experience with the Fishworks
UI, though it is not limited to that product. The idea is that we'd like
to be able to go through and see the different components that are a
part of the class.

We may not be able to always do this and will have to result to some
generic view, but having some way to see things will help even if it
doesn't capture every detail of the system.

This could also be leveraged when looking at individual units in the DC
so we can use it to 

### Location and Connection Information

#### Views of the World

There are multiple ways we can view connections. Each of the following
is potentially useful and tells us different information.

##### Network View

One of the primary questions we often have is what switches is a given
server plugged into. We care about this primarily for the server itself;
however, the LOM is also important to think about.

The primary way we'd suggest to get this information is to leverage LLDP
(link layer discover protocol) and use this to build up a map of what's
connected in the DC. This is also important as part of affinity
decisions as we often want to try and avoid the failure of a given
networking domain from bringing down applications. [RFD
7](https://github.com/joyent/rfd/tree/master/rfd/0007) provides some
more concrete details of how we might manage this approach.
 
##### Physical View

The second primary way that we want to view the world of our systems is
through the physical world. We want to answer questions like: What rack
is it plugged into? Where in the rack is it? Where is this rack in the
DC?

Right now this is a rather manual procedure. Likely having ways to do
bulk imports and assignments of this data from manifests will probably
help. 

###### An Intelligent Rack

One thing that we've been thinking about is what if a rack itself had
some amount of intelligence. What if a rack knew certain information
about itself like:

* A UUID
* Some human readable name
* Some notion of a location
* Other potential Key/Value pairs of metadata

In some ideal world the server would be able to figure out this
information automatically and determine where in the rack it is located.
This could be some form of NFC, i2c, or something else entirely. The
exact mechanism isn't too important in terms of what we want to get out
of the system.  This is one area where a lot of exploration is required.
It's not yet clear if this is possible.

##### Power View

The final view that's worth thinking about is the power view. One thing
that's worth considering is what information we can get out of PDUs.
What we really want is some kind of LLDP for PDUs.

#### Mapping the DC

The primary motivation for all of this location information is to be
able to automate the mapping of the DC and deriving information used for
locality and the like based on it. 

The better we can build a map in adminui that lets us visualize the DC,
the more useful it will be for us. Seeing how things are actually
connected will allow us to confirm what we expect and what is reality.
Ideally we'll be able to zoom in from a DC view to a rack, to a server,
and into an individual component in that server.

In addition, with this kind of information, it will better allow us to
determine what's been impacted during outages. For example, if a TOR
dies, we can know all the machines impacted by it and communicate that
out. Making this programmatic will help in building a bundle of needed
tooling.

#### Identifying Units

Another aspect of this map based view and zooming into individual units
should be to toggle the identification and service LEDs of chassis and
parts that support this. Ideally this could be driven by having an
operator actually click the representation of the disk or device that
they want to deal with. 

We should also be able to get basic service level information ranging
from things like the model, UFM revision (if applicable), to any
historical issues with the part and its general service levels.

#### Integration with Other Components

In an ideal world, we'd like to be able to also cross-reference and draw
upon information from switches, LOMs, etc. Though this is a slightly
lower priority than the rest of the mapping information, it would allow
us to paint a much more useful and accurate vision of the DC.

### Server Health and Inventory

This section focuses on individual servers; however, this could be
extended to other components of the DC that are managed by Triton.

#### Topology Trees

Today, we primarily rely on the 'hc' or hardware chassis FM topology
tree. We need to make sure that this is as accurate as possible for
systems we deploy. In addition, we've talked about the idea of adding a
logical tree. The logical tree would provide a way for us to describe
resources that we know about, but may not have physical location
information.

A good example of this is removable USB devices, where we may not be
able to relate them to a specific place on the chassis. The same is also
true for some PCI slots or disk drives when we're not able to get
information automatically from sources like SMBIOS and SES.

The next few sections talk about ways we want to explicitly augment the
topology trees in the system.

##### Networking

Many networking cards use a separate device as an optic. This optic is a
FRU separate from both the card and cable. They often have their own
statistics and sensors. We should consider doing the following:

* Having optics show up as a separate device in /devices so that they
can be noted as faulty. This would likely consist of a new driver and
GLD enhancements to make this as smooth or as painless as possible. We
wouldn't want to expose the need to load or manage this driver to
consumers of the GLD directly.

* We'd also like to have data link state tracking as discussed roughly
in [RFD 7](https://github.com/joyent/rfd/tree/master/rfd/0007). Ideally
we can also augment the tree with some of this connection information.

* We'd like to be able to toggle and flash location LEDs and the like
when the device supports this ability.

##### UFMs

Upgradable firmware modules represent a large missing chunk of the
topology tree today. Firmware information is spread out across the
system in a somewhat haphazard way. The
[fwflash(1M)](http://illumos.org/man/1m/fwflash) utility knows about
versions. Other devices end up adding some arbitrary properties to the
/devices tree.

We'd like to have a uniform set of properties to represent such a thing,
regardless of the source, type, and whether or not it can be upgraded.
For example, this should be able to cover everything from reporting a
CPU's microcode version, to a disk drive's firmware version, to the
firmware version of a device like a Yubikey which cannot be modified.

This suggests a series of DDI enhancements to make it easier for
different device driers to implement and handle this information as well
as tools and FM enhancements.

##### LEDs

We'd like to make sure all the LEDs that are part of a system chassis,
whether it be a disk, PSU, NIC, or some more general chassis device are
controllable by the OS.  There are already LED properties for several
devices, but more broadly we want to make sure that we get as much of
this fleshed out as possible. Today FMA gives us a uniform interface for
manipulating them, and it may be useful to continue down that path.

##### Chassis Specific

We are likely going to need specific ways to get at and understand the
fans and other parts in the system on a per-chassis basis as they are
unlikely to all use standard methods.

##### Synchronization

We should extend the system agnets to take care of heartbeating out
topology information at some interval as well as the retire store and
`/etc/path_to_inst`. There'll be a lot of tie-in here with general
data center notifications, etc. As we'll also want to be able to handle
propagation of faults and defects, and maybe even ereports.

#### Sensor Data

Today systems have a lot of temperature and voltage sensors strewn
throughout them (amongst others). Right now this information is
sometimes obtained through ipmitool, though some drivers and parts of
the system have this information.

In general, we should be working towards having a uniform system of
collecting and displaying these statistics. This means that in some
cases we'll need to write new logic to be able to access those
temperature and voltage sensors.

We'll need to do additional research to determine what parts of the
system we should be looking at for these sensors and how to get that
data. There may need to be new drivers for CPUs or other work.

#### QoS Threshold Data

An avenue that we need to consider and explore is the use of
quality of service threshold data. For example, we should be track disk
activity as increasing service time latencies can end up being an early
warning sign of disk problems, among other things.

Figuring out which latencies are worth collecting, how to collect them,
and how to notify and act on these are open questions. An important
thing is that we don't want to be too aggressive with taking action on
these, because these represent a similar challenge that we have with
disk errors, where being too aggressive with faulting a device can end
badly.

Other examples of this may be things like the RPM that a fan is
operating at or the amount of voltage being drawn. This will all fold
into the discussion later of a 'FRU monitor'.

#### FRU 'suspension'

One thing that we need to look at operationally is the ability to
turn off a FRU for a period of time, to allow some service to fail over.
A good example of this is with a NIC. Many NICs are often aggregated
together. What we'd like an ability to do is to turn off one off the
link on a given NIC so we can have all traffic fail over to the other
member before we go ahead and do an upgrade.

The means of this is always going to be specific to the set of deices.
For example, [psradm(1M)](http://illumos.org/man/1m/psradm) can be used
for processors. [cfgadm(1M)](http://illumos.org/man/1m/cfgadm) can be
used to manage certain classes of devices as well. This isn't
necessarily something that should be FRU specific, but FRUs are a useful
place to start.

We should also evolve this into allowing a forced offlining of a part
similar to what FMA would do it if determined that a part was faulty.

#### Reacting to FRU Replacements

Another thing that the system needs to handle is gracefully recovering
and updating its metadata in the case of a FRU replacement. A good
example of this is a networking card.

Because we don't leverage `/etc/path_to_inst` in any way because of the
live boot nature of SmartOS, we end up having nic tags that are based
upon MAC addresses. However, if we have to service a NIC, then that
means that the NIC tags will be out of whack because the MACs will have
all changed. We should likely come up with some way to leverage the
`/etc/path_to_inst` information to know that this should be the
replacement for this and adjust things accordingly.

#### Firmware Management

As we talked about earlier, we need to be able to understand the
firmware versions of all components. However, it would also be useful
to be able to actually upgrade these firmware revisions. We should
likely break the analysis of needed fw upgrade into two different
categories based on whether or not they require service downtime.

As an example, a disk in a RAID array can be updated without service
downtime, as it can be removed from a pool and then returned to service.
Similarly a system with two discrete NICs that are built into an HA pair
may not need to do anything special here. You could offline one NIC,
upgrade it, fail back over again to the other aggregate member, and then
repeat.

However, some things may not be able to handle service in this way. The
disruption from upgrading an expander may be too great to perform
online. We may want to explore sending down firmware upgrades to perform
in a bootfs style fashion to perform before the network or disk has
started.

#### BIOS/UEFI Settings

In an ideal world, we'd like some way to be able to capture and set the
BIOS/UEFI settings. Though we need to think through how we want to
manage aspects of this and how to do this in a way that's actually
secure. But, being able to get and set and determine the differences in
subsets of the systems firmware will help with the acts of automating
and managing the DC.

#### FRU Monitor

For many components there's no specific thing that's monitoring or
verifying its state is correct. For a lot of things, we need something
to monitor and issue ereports based on observed behavior or thresholds
being exceeded. It's hard to say at this time where in the system this
should live and how it should exist, but it's something for us to think
through and figure out.

This might be the way you monitor things like:

* A fan's speed and livelihood
* The amount of FTL still usable on a Flash device

### DC Management

This section goes through and collects a bunch of disparate pieces of
managing the DC, particularly servers.

#### Operator Notifications and Visibility

This is probably the most important part of the system. This is well
treaded ground, particularly by the following RFDs:

* [RFD 6](https://github.com/joyent/rfd/tree/master/rfd/0006)
* [RFD 17](https://github.com/joyent/rfd/tree/master/rfd/0017)

Being able to collect and visualize this information, as well as notify
on it, is paramount to the long term success. From a hardware
perspective, we want this for any local failures or otherwise. These
kinds of alerts should cover the following:

* Hardware Faults
* Software Defects
* Thresholds Exceeded

#### Customer Correlation

As we continue to develop and drive what the experience is for
customers, we need to make it easy for operators to relate any of the
issues or information here to those customers. This might manifest in a
few different ways:

* Being able to overlay our topology information with a customers.
* Being able to correlate impacts and failures in the system to the
  group of impacted customers.
* Combining the resource utilization, QoS, etc., faults to better plan
  capacity and future purchases.

#### Tracking Rack and Other Components

We should likely grow the ability to have a rack object that has the
metadata described earlier in the `Location and Connection Information`
section. This will help us with understanding what's in the DC. Being
able to also annotate the racks with information about objects that
aren't currently known by Triton is also useful. It may be worth having
a more general way to represent a data center's topology. This'll need
more exploration.

#### Lifecycle Tracking

One of the things that's useful is to give operators tools to help keep
track of the life cycle. This includes information on when the system
entered the system, when it's due to be removed, etc. This can cover
things like lease tracking. At the moment, it's not clear what the exact
content needs to be and the best way to present this.

#### Historical Information

One of the things that's important to start tracking is changes to
servers and their life cycle. For example, if we've had parts replaced
or parts fail, we want to understand and keep track of that.  We should
be able to go to a given CN and just see the record of everything that
has happened. All the replacements and changes that have occurred.

It's important that we be able to ask questions like how many HGST and
Seagate drives have seen failures or what pattern of merrs, derrs, and
I/O service times often occur before the drive's death.

Ideally we'd love to be able to pull in data from TORs, PDUs, etc. It's
more important that we first gather this data and later be able to go
back and process it.

This can also be the building block of data we use for reports about the
DC itself and understand what's going on. An important use is to track
and figure out whether we were on or off mark with density and
utilization of our current systems. This will allow us to know what we
should consider for what we want to build in the future.

#### Bootstrapping

Importantly, we need to deal with bootstrapping a new DC. In this case
we need to figure out ways to handle the following different parts of
the system:

* LOM IP assignments
* Validating chassis components 
* Verifying and potentially upgrading firmware
* Potentially performing smbios or systems firmware updates
* Performing burn-in testing
* Confirming that external and internal cabling is correct. NICs are
correctly wired and disk LEDs refer to the right disk.
* Figuring out and inputting topology information, which may be rather
manual

#### Tooling and Visualizations

One of the biggest things here will be coming up with proper APIs and
other tooling in the browser to allow us to make this easy to use, but
still easy to automate via scripts. 

### Wrapping Up

At a high level, what this suggests is to think through and develop
several new suites of APIs and tooling to deal with the day to day
management of servers and their life cycles. We want to understand what
they are, where they are, and their health.

While many OS related aspects were talked about in terms of and relating
to faults and firmware, it's vitally more important to nail and get the
general management and configuration to be sane. Being able to have
Triton help reduce the burdening of configuring and managing a data
center is part of its core calling.

### Follow Ups

The following list of RFDs delve into more details on how portions of
the functionality described in this document are going to be
implemented. This list will be appended to as more RFDs are written:

* [RFD 89 Project Tiresias](../0089/)
