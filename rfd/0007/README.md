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

In SDC, we have a couple different problems that have led us to desire
new functionality and subsume some existing functionality.

### Datalink State

SDC leverages a compute node's sysinfo as part of its decision making
process when provisioning. One of the parts of selecting the right
compute node is verifying that the compute node satisfies any nic tag
requirements that exist. These nic tags are determined by looking at the
reported sysinfo.

In addition, to increase the likelihood of a successful provision, we
currently will not provision to a compute node where the requsted nic
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

## Proposal

To solve this, we'd like to introduce a new daemon that subscribes to
state change notifications on physical datalinks and also participates
in LLDP.

The daemon should be a simple libdlpi consumer to get notifications of
the link's state and to participate in LLDP. The daemon should export a
door server as a means for configuration commands and commands like
lldpneighbors to function.

In addition, for reactions to link state change, we'd like to put
together a plug-in interface that allows different modules to take
various actions in the system. For example, one such plugin may trigger
various updates to sysinfo or remove its cache. In addition, we'd leave
it up to plugins to define their own approach to hysteresis. The
implementation of the various door servers may be done in a plugin,
whether or not that is the way that we should go down is yet to be seen.

### Why combine these two problems?

A rather obvious question is why should these properties be combined in
a single daemon as opposed to having one daemon which is in charge of
link state changes and another which is responsible solely for LLDP
related actions. It may be that this is the approach which makes more
sense. On the flip side, the state of the link is a reasonable part of
the information that we should include in the LLDP snapshot. It may also
be that as we further explore parts of the Ethernet related RAS features
discussed in [RFD
6](https://github.com/joyent/rfd/tree/master/rfd/0006), we'll find that
we want some additional information and it makes sense to have a single
daemon take care of this.

### User land vs. Kernel

Another question here is whether some of this should be handled by the
user land or as part of the GLDv3 or other aspects. After all, the
kernel already provides read-only snapshots of the link information.

Approaching this from the perspective of LLDP, it makes sense that we
would not want to include that in the kernel. There's no reason that any
of that is required there or that it's worth building up the protocol in
there. The information and participation can be trivially driven from
user land and it certainly simplifies the failure semantics.

Because of that, if it makes sense to combine the two different purposes
here, then it doesn't make sense for this to be driven by the kernel,
but by a relatively simple user land daemon.

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

### Deliverables

This project will deliver the following components:

* A new daemon that manages both the lldp protocol and the datalink
  state change logic. This daemon should be disabled by default in
  illumos; however, it will be enabled by default in SmartOS.

* A client library that allows other software to explore and use the
  lldp information.

* A new lldpneighbors command that provides various lldp information and
  also provides stable, parseable output formats.

* A new configuration utility that will manipulate SMF properties of the
  lldp service to control various aspects of the aforementioned
  configuration.

* A plugin that handles hysteresis and properly updates sysinfo. This
  will help deal with and handle the issues that we've seen around stale
  link information when make provisioning decisions.

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
