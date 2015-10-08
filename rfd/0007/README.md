---
authors: Robert Mustacchi <rm@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent Inc.
-->

# RFD 7 Datalink LLDP and State Tracking

The purpose of this RFD is to introduce a new daemon whose purpose it is
to watch and react to the state of datalinks and be a queryable source
of information about link-layer metadata.

## Problems

In SDC, we have a couple of different problems that have led us to desire
new functionality and subsume some existing functionality.

### Datalink State

SDC leverages a compute node's sysinfo as part of its decision making
process when provisioning. One of the parts of selecting the right
compute node is verifying that the compute node satisfies any nic tag
requirements that exist. These nic tags are determined by looking at the
reported sysinfo.

In addition, to increase the likelihood of a successful provision, we
currently will not provision to a compute node where the requested nic
tags are backed by downed datalinks. A datalink may be down because of
a cable problem, an upstream switch failure, localized hardware failure,
or another problem.

One problem in SDC is that there is nothing which updates sysinfo
actively when there are changes in this state. This means that a link
which starts down, but later turns up will not be updated and that state
will not be reflected in SDC. This may happen because of an aggregation
failure or something as simple as a switch port being mis-programmed.

While [libdlpi](http://illumos.org/man/3lib/libdlpi) can be used to
obtain notifications, nothing is wired up to listen to them and respond
to them. Further, while `net-agent` may seem like a reasonable place to
do this, the component that needs updating is part of the core of SmartOS, the
sysinfo command. We should not rely on something from SDC to bundle this
as otherwise SmartOS will be incorrect.

### Link Layer Discovery

Today, SmartOS ships a basic link layer discover protocol (LLDP) daemon
openlldp. The `lldpneighbors` command is useful today for being consumed
by an operator; however, it is not something which we can easily
consume from other programs. As part of what's been discussed in [RFD
6](https://github.com/joyent/rfd/tree/master/rfd/0006) we'd like to
start consuming this information in a more programmatic way and allowing
it to help us get a sense of the data center or use it to better
understand the impact of failures.

In addition, because of how the current LLDP daemon works, it doesn't
currently work on physical interfaces which are used in aggregations.

## Proposal

To solve this, we'd like to tackle the problem in two different forms.
To solve the first problem, we'd like to add a new class of sysevents to
the kernel and combine that with a syseventd module which will consume
the various notifications and end up launching the sysinfo update
command with some amount of hysteresis.

To solve the issue of LLDP and state change notifications, we'd like to
introduce a new daemon which uses libdlpi to participate in LLDP. The
daemon will export a door server as a means for both configuration and
for getting information like lldpneighbors. While it will keep track of
link state and provide that information, it is not the one that will be
in charge of it. In addition, we should consider having the LLDP daemon
emit sysevents to indicate changes that occur.

### Why are these problem separate?

In earlier drafts of this proposal, we had called for these two issues
to be solved by the same daemon. This proved to be untenable for a
couple different, but important reasons.

The biggest issue is that when libdlpi holds open a device, it prevents
the destruction of the device. This is generally what we want. For
example, when an IP interface is plumbed up, it has the same semantics
as with a libdlpi consumer, you won't be able to destroy the device
while we're listening. While one could change the semantics of the
libdlpi consumers, it's not necessarily the case that this makes sense
for link state change notifications, which may be desirable for a larger
set of devices than for those used by LLDP.

While the lldpd daemon will want to know the state of a device, it can
leverage the existing libdlpi interfaces for that, as it will have to
have the device open in general.

### User land vs. Kernel

Ultimately, it makes sense to leverage the existing kernel data paths
for generating the notifications to update sysinfo. The kernel already
has these and it allows us to handle them in a way where we don't have
to worry about keeping links open or not.

Approaching this from the perspective of LLDP, it makes sense that we
would not want to include that in the kernel. There's no reason that any
of that is required there or that it's worth building up the protocol in
there. The information and participation can be trivially driven from
user land and it certainly simplifies the failure semantics.

### Why not dlmgmtd? 

Another question one might ask is why not make this a part of dlmgmtd?
One could argue that because dlmgmtd is maintaining all of the sets of
datalinks and their properties, this could be a natural way to manage
things.

On the other hand, dlmgmtd already handles many different things,
including the management of non-global zones and forking and entering
them. It'd substantially complicate dlmgmtd to have another
responsibility here and add to its existing workload. It is my opinion
that it will be simpler to provide this functionality in a new daemon.

### What happens to the existing lldpd?

Because the current upstream lldp appears to be moribund, we are not
going to use it as a starting point and will instead be writing a new
daemon. However, we will leverage some of the older community lldp
projects here to build out the lldp protocol processing and management.

As part of delivering this, we will remove the exiting lldpd daemon and
lldpneighbors command that are currently delivered from the `openlldp`
directory in illumos-extra. Note that the neither of these are
documented, though they have been used by administrators traditionally.
Because lldpneighbors is hard to parse and it does not have a stable
output, we should not worry about making the existing output be
compatible with a future command.

### Use in non-global zones

While in many SDC and JPC deployments it does not make sense to use lldp
inside of the non-global zones, it should be designed to run inside of
its zone and be able to operate on any of the datalinks that exist
inside of that zone. This is useful, especially if in traditional
illumos deployments a physical device is passed directly for use inside
of the zone. However, the default non-global zone configuration will be
disabled.

As part of this, we'd like to explore what it means to have these events
be able to be delivered to a per-zone sysevent; however, it is not a
required part of this project at this time.

### LLDP parameters

From surveying several implementations and deliverables of LLDP daemons,
the following are various areas that we'll want to allow for
administrators to control behavior:

* Should we actively participate in lldpd or passively participate?
* Which datalinks should be participating?

By default, we suggest that the lldp daemon be enabled in the global
zone, running on all physical datalinks in the global zone. In terms of
of configuring the set of datalinks, we should probably allow it to be
set to the following set:

* All physical device
* All datalinks
* An explicit list of datalinks

### Lack of State?

One of the questions that we need to answer is whether or not we should
persist LLDP information on-disk. This would allow the daemon to
bootstrap information that we consider 'stale'. The reason we might want
to do this is such that when a link goes down, it's impossible to know
why it went down. It could be due to a cable failure or something else
entirely. As such, keeping around and maintaining stale information
during those times, even across crashes of the daemon or even reboots of
the system may be desirable.

If we do this, we should note that the information is stale and provide
an explicit command that can be used by an administrator to clear out
the stale cache. The state could be as simple as an nvlist_t saved per
datalink via librename.

### Challenges with Aggregations

LLDP and link aggregations don't really work together very well at the
moment. When a link aggregation is created, we end up not allowing any
active use of the DLPI device, which means we specifically bind to the
LLDP Ethertype.

We'll need to investigate a new way of handling this, perhaps adding a
way for an aggregation to forego subscribing to a given SAP and leaving
it to the parent devices.

### Deliverables

This project will deliver the following components:

* A new series of sysevents that will be used to indicate that the state
  of a datalink has changed.

* A new syseventd plugin which will watch for the above system events,
  perform hysteresis, and update sysinfo occasionally.

* A new lldpd daemon which is responsible for participating in the lldp
  protocol. This daemon should be disabled by default in illumos;
  however, it will be enabled by default in SmartOS.

* A client library that allows other software to explore and use the
  lldp information.

* A new lldpneighbors command that provides various lldp information and
  also provides stable, parseable output formats.

* A new configuration utility that will manipulate SMF properties of the
  lldp service to control various aspects of the aforementioned
  configuration.

### Future Directions

This work is expected to build upon part of the information that we
discussed in [RFD
6](https://github.com/joyent/rfd/tree/master/rfd/0006). It will be used
as the foundation of the Ethernet RAS related sections and the
combination of the datalink state and the LLDP information will be used
to augment and form the base of a series of new datalink entries in the
FM topology tree. This will be used both for better understanding and
alerting on failed links and putting together pictures of the data
center's topology.
