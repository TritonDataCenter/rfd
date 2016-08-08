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

# RFD 6 Improving Triton and Manta RAS Infrastructure

This RFD covers the background of what exists in the operating system
for reliability and serviceability (RAS) and then goes on from there to
cover what it might look like to extend this to software components such
as Triton (formerly SmartDataCenter or SDC) and Manta. It also looks at hooking into existing RAS artifacts
in the system such as the Fault Management Architecture (FMA) in
illumos.

This RFD serves as an introduction and a high level direction that we
would like to proceed down. Future RFDs will cover more specific
component interfaces and explicit APIs. Currently this is focused on
*operators* of Triton and Manta; however, there's no reason that it could
not be extended to users in the future.


## Goal

The following is the guiding principle for all of this work:

Triton and Manta operators need to be able to quickly assess the status of
the entire system and of individual components.  They also need to be
notified with *actionable* messages whenever problems develop.


## Examples of how this would be used

Before we get into too many details of what we need to build, we'd first
like to go through and talk about how this might be used.


### Actionable Notifications of Developing Problems

As an operator of Triton or Manta who is currently doing something else, I
need to be notified when problems occur that affect service (e.g., a
critical service has gone offline) or that compromise the system's
tolerance to future failures (e.g., a disk fails and a hot spare is
activated).  These notifications should be specific and include the
severity of the problem, a summary of what happened, what the known
impact is, what automated response the system already took, and what the
operator should do about it.  For example:

- Severity: medium

- Summary: A Manta storage node has become unresponsive.

- Impact: Some in-flight data plane requests affecting objects on that
  node may have failed. Until the storage node is back in service,
  subsequent requests to fetch objects with durability 1 that are stored
  on this node will fail.  Compute tasks that operate on such objects
  will also fail.

- Automated response: requests to write new objects will be directed
  away from this node.  Requests to fetch or compute on objects stored
  on this node will be redirected to nodes with other copies, if any are
  available.

  When the node becomes responsive again, the system will automatically
  start directing read, write, and compute requests to this node again.

- Suggested action: Determine why the system has become unresponsive.
  Likely reasons include: the system has been powered off or rebooted or
  the system has panicked.  If the system has been powered off, power
  it back on.  If the system has been rebooted or has panicked, wait
  for the reboot to complete.  If you cannot reach the system's service
  processor, check for network problems.


### System Status

As an operator of Triton or Manta, I have reason to believe the system is
not working correctly.  (This may be because I was just notified or
because a user has reported a problem.)  I want to walk up to the system
and quickly assess the status of all components, highlighting those
which are believed to be not working.  If any components have been
removed from service because they were deemed faulty, those should be
highlighted as well.  I should also be able to explicitly bring such
components back into service if I determine that they're not faulty.


### System Review

In the same situation as 'System Status', or after having finished
restoring service after an incident, I want to review the actionable
messages that were emitted by 'Actionable Notifications of Developing
Problems' to fully understand what happened across the whole system.


### Rephrased Use Cases

Another way to phrase the previous three narratives is as the following
points:

1. Operator Notification of all knowledge article's emitted (mail,
   jabber, record, etc).

1. List retired Components

1. List degraded Components

1. "Clear" retired components

1. List all knowledge articles that have been emitted

Above, we have both a notion of degraded and retired components. It's
worth taking some time to explain the differences. A *retired*
component, is one that has been taken out of service. For example, a
disk that has failed and removed from a zpool has been retired.

There are a few important points to emphasize about a device being
retired:

* The system retires components

* Retired components do not return to service without explicit operator
  intervention

* Operators are required to notify the system that the retired component
  has been replaced.

In general, components that can be retired are hardware components and
not software components. We generally retire things due to hardware
faults and not software defects.

On the other hand, we have degraded components. A degraded component,
whether software or hardware, can be diagnosed from both outside of the
process and inside of it. For example, if a service cannot connect to a
downstream component, it has the knowledge that it is degraded, even if
it doesn't know the reason as to why it is in this state. For example,
if NAPI cannot connect to moray, it doesn't know if that's because of a
network partition, moray is down, or some other failure; however, it
knows that its functionality is impaired.


## Background

Today FMA (Fault Management Architecture) provides information about
hardware faults, software defects, diagnoses them, and automatically
performs actions based on the generated events. For example, the
operating system reports events called ereports which are facts. These
include, but are not limited to, correctable ECC DRAM errors, ZFS
checksum errors, and I/O errors. 

The system processes these and determines if there is a hardware fault,
generally based on SERD, and if so, then takes action such as off-lining
a component, notifying administrators, and on-lining a new one, if
appropriate.  For example, if a disk has reached a fatal number of
errors and FMA decides to off-line it, it will swap in a hot-spare, if
available.

For each of these faults or defects, there's a corresponding knowledge
article which informs the administrator what has happened, what the
impact is, what actions have been taken, and what the operator's next
steps are.

However, while this exists on a per-CN basis, Triton is entirely unaware of
it. It has no integration into any facilities to inform operators, be
collected, logged, etc.

In addition, at the moment there's no way to leverage the ideas of FMA
inside of Triton. Components can't emit the equivalent of events like
ereports that can be transformed by something into knowledge articles
which detail information that an operator can use.

It's worth going into a bit more detail about what FMA consists of today
and how they fit together:


### Events

We've mentioned events, it's worth going into more detail about they
include. In FMA, events fall into the following categories:

* error reports (ereports)
* errors
* defects
* faults
* upsets

Each of these has a class, which is a dot delineated ASCII name and it
has a payload, which has a structured body. The dot delineated scheme
describes a hierarchical relationship. An event will have all of the
payload properties of its parents. Each of these events cover different
information.

**faults** indicate that something is broken. Generally, this only ever
refers to *hardware*. Fixing a fault usually involves replacing it and
telling the system that the fault has gone away. For example, a hard
drive that needs to be replaced is faulty or has suffered from a fault. 

**defects** indicate a design defect. Generally this only ever refers to
*software* and *firmware*. For example, when a service enters
maintenance, that usually indicates a bug in the software. It also
covers things like the service processor.

**upsets** are used to indicate the cause of a soft error. This often is
used to describe various transport related issues, for example, an I/O
that gets retried.

**errors** are events that indicate some kind of signal or datum was
incorrect. Generally they are referred to by *error reports*.

**error reports** are reports of errors that have occurred and often
referred to as ereports. These are reports of errors and have additional
report information inside of them to allow for components to better
understand what's going on. These reports are generated by error
detectors which may be the kernel or the hardware. For example, when a
CPU generates an ECC error, the OS is notified and the kernel generates
an error report.

Traditionally the payload has been defined in XML; however, we recommend
that we move instead towards a JSON based schema to describe these in
the future. We'll talk more about structuring this in the section
'Events Gate'.

### Diagnosis Engines

The role of a diagnosis engine is to take a list of ereports and errors
and transform them into something actionable. The purpose of the
diagnosis engine is to take some set of ereports, and transform them
into specific problems, or additional ereports. For example, there's a
diagnosis engine that watches the rate of ECC errors that a CPU
generates, and if it exceeds that rate, it then will generate additional
events that will result in the CPU being faulted.


### Knowledge Articles

For every problem in the system that gets reported to the operator,
(*faults*, *defects*, etc), there is a corresponding knowledge article
that gets emitted. In many ways, these *knowledge articles* are the most
important part of FMA for the operator. They tell an operator several
facts:

* The severity of the issue.

* What the impact of the issue is.

* What action has been taken by the system, if any.

* What to do next.

The information contained within is designed to be used by both programs
and software. In addition, various fields may be localized and therefore
translated. Those that are localized are not used for programmatic
consumption.

Importantly, a knowledge article also has a list of events that map to
it. This is how the system knows what knowledge article to display for
a given event.

The following are examples of the articles generated by the system:

[AMD-8000-2F](http://illumos.org/msg/AMD-8000-2F)

[ZFS-8000-8A](https://www.illumos.org/msg/ZFS-8000-8A)


### Event Registry

The event registry represents a collection of events and knowledge
articles. All of the events and knowledge articles consumed by a part of
the system are contained inside a single registry. Today the registry is
a series of XML files, though we'd like to change that longer term. In
addition, while today there is a single registry that exists for the OS,
there's no reason that various components couldn't have their own
registries and therefore overlapping IDs and the like.


### fmd

`fmd` is the fault management daemon. It's in charge of listening for
various reports, diagnosing them, and handles the logic around faulting
and marking devices repaired. The domain of the daemon is the single
compute node that it's on. It doesn't have a real sense of remote
systems. But it watches over both the global zones and non-global zones.


## Workflows

Earlier we talked about three different examples and phrased those as
five different use cases. It's worth taking each of them apart and
talking about them in more detail. Let's also take a little bit of time
to describe the application workflow. There are basically three
different ways that data transmits through the system, we'll letter
these A, B, and C, while the use cases are numbered 1-5.

```
  A) Software ------> Event -------> Knowledge Article
                       |                  ^
                       |                  |
                       |                  |
                       v                  |
                      Diagnosis -------> Event
                      Engine


  B) Software -----> Event ------> Diagnosis ----> Event
                                   Engine           || 
                                                    || 
                                                    vv 
                                                 Component
                                                 Retired


  C) Software ----------> event    =====+
           ^                           || Indicates
           |                           || degraded
           +------------> polled   =====+
```

These three entries correspond to different flows. It's worth noting
that B is a subset of A.

Looking back at our use cases, today FMA handles the logic of operations
A, B, and use cases 2 and 4 within the context of a single system, not
across the cloud.

Use case 3, on the other hand, listing degraded components, in Triton and
Manta today. While the information can be both polled and pushed, today
we poll it in the form of things such as sdc-healthcheck and madtom.
While these may not be the final forms that we want things to take, they
at least form the starting points. 

If we now want to look at what we'd need to do, we'd want to create
some new interface that helps provide a way for our new software to have
these events noticed and emitted and have a new Triton component that is in
charge of helping deal with these events and potentially perform
diagnosis. That API would help facilitate the use cases of 1, 2, 4, and
5 across the cloud and interact with the local fmd as appropriate.

By integrating with the local fmd, we can provide operators a
centralized view of the state of a given compute node's health. This
will also allow the new Triton component to integrate with the current
notion of cases and retirement that fmd has today.

We may also want to create a new fmd-like daemon which knows how to do
simpler mappings of events to knowledge articles and tracking that which
doesn't relate to the current fmd implementation, but leverages the same
metadata. This would allow an Triton or Manta component to emit an event
that can be noticed, transformed into a knowledge article, and alert an
operator.

At this point in time we want to take a gradual approach and not start
to go down doing software retirement due to defects and faults, but this
allows us to still have components emit events that can be used to
notify operators and have the needed documentation to help operators end
up in one place.


## Reworking the events gate

At Sun, the set of events and the knowledge articles about them were
stored in a single place. The gate itself was a morass of XML and
tooling which relied on the sccs history. There are a couple things that
we'd like to make sure are changed about this:

* Simplify adding of events and knowledge articles
* Allow there to be multiple repositories

To that end we have several goals. The biggest is getting tooling to
make it easy to add non-conflicting events and to have this tooling live
separate from the event repositories. This allows different event
repositories, illumos, Triton, Manta, and anything else in the future to
have different sets of events, but share the same tooling.

One of the challenges we have here is that the system has codes for
every knowledge article that can be used to determine what they refer
to. No two articles can have the same code. If they do, then that will
cause a collision. Traditionally this was solved by just always using
the next available ID and having the single repository of record be
serialized. Unfortunately, this isn't always a desirable property for
some repositories as it makes it harder for downstream forks to develop.
There are many different considerations here. It's useful to consult
the [birthday problem
table](http://en.wikipedia.org/wiki/Birthday_problem#Probability_table) for a
look at various probabilities so we can determine what makes sense here.

We still need to work out what the best scheme is here. Unfortunately,
it seems like there may be some need for a project to coordinate at the
end of the day; however, the strategy of improving the tooling will
allow different repositories to co-exist.

We recommend that the tooling be such that event payloads are now
defined using JSON schema and that knowledge articles are defined in a
markdown-like format that allows variables from the payload to be
inserted. The tooling should likely be set up in such a way as to
randomly choose an ID and to properly initialize the markdown file.

While the operating system itself will likely only use a single
repository, we'll want to make sure that whatever we're working with has
the ability to use multiple event sources each with their own
overlapping events and registries.


## Enhancing Topology

One of the other major things that we'd like to do is to talk about how
we enhance the topology of the system. Today, most FMRIs are referring
to specific chassis; however, there are other components in the data
center that we could want to talk about or other logical aspects that
we'd want to consider.

One of the things that operators would like to be able to do, and often
Triton would like to better leverage, is to paint a picture of the data
center so we know what's in what rack, where. This covers more than just
compute nodes, but also other things in the data center that operations
staff have to manage, such as switches. Ideally, we could leverage
things like LLDP to put together a picture of how the data center itself
is connected and allow operations staff to note various things like EOL
time frames, leases, etc.

To that end, there are a bunch of different things that we should
explore:

* Creating a new set of APIs that exposes the topology of the data
  center, whether it's a part of some existing API or something new can
  be hashed out later.

* Expanding the current chassis topology to have logical nodes for
  datalinks that can include information about their state and what
  they're connected to, if it's knowable. For this we can leverage lldp.

* Capturing information about service processors and associating that
  with their chassis, regardless if we want to provide numbers for them.

* Making sure that we have a concrete way of describing service topology
  in terms of FMRIs. This is really more of a mapping of SAPI than
  anything else.

* Better representing and gathering service processor information in the
  data center.


## Integration with Existing Operating Monitoring

Many on-premise customers have many existing monitoring and alerting
solutions that run the gamut from home-grown systems, systems built
around tools like zabbix and nagions, and traditional use of SNMP.

As part of this, we should work with the JPC operations staff and with
sevearl of our on-premise customers to determine the best way to provide
this information in ways that can hook into their existing systems.
This may be a simple as providing a means that these services can poll
the general set of alerts; however, with others it may be more
challenging because many of the events that we announce will be single
alerts that fire, but do not come back up again. It also may not be
practical as part of the broad set of existing systems to fit in all of
the event payload.

The exact form of this integration will be the subject of a future RFD.

## Next Phases and Crazier Ideas

From here, we have several more specific directions that we can do on
which will want to be the subject of future RFDs that further explore
how we want to build these up and how this interacts with the rest of
the system.

A lot of the things we've discussed have overlaps with existing APIs
such as amon, cnapi, etc. At this time, this RFD isn't trying to suggest
where something should or shouldn't be built. It's important that we
co-exist well with amon's existing uses and make sure that this isn't a
parallel world, but rather something we can move all of Triton and Manta
to. The specific mechanics of that will be left to future RFDs and
research.

* Capturing compute node and service processor topology

* Datalink FMA topology and RAS

This would also play into various other things we've had bugs on such
as better handling Ethernet card replacements and handling things that
rely on datalink state (such as sysinfo and provisioning).

* New Events Gate Tooling and Automation

Note that the following three points need to integrate in some form with
amon.

* Existing FMA event centralization, notification, and fault database
  persistence

* Component knowledge articles and events

* Alert integration with existing Operator Systems

* Data center Topology, APIs, and Management


### CloudAPI facing features?

One thing that might be interesting is to rig up the status of various
docker containers and SMF services to events and knowledge articles,
giving customers a way that they could see these kinds of events for
their architecture or even plug into it themselves, though that seems a
bit more far reaching and less practical. Folks aren't generally going
to rewrite their app to take advantage of our features.


### Thresholds, Cloud Analytics, and Dragnet

Another aspect of the RAS services that we might want to explore in the
future is the idea of threshold alerting based on various Cloud
Analytics features or dragnet tables. A lot of what we might do here
depends on how future developments of Cloud Analytics might develop.


### Related RFDs

This lists other RFDs that go into more details on what it is we'd like
to accomplish:

| RFD |
| --- |
| [RFD 7 Datalink LLDP and State Tracking](../0007/README.md) |
| [RFD 8 Datalink Fault Management Topology](../0008/README.md) |


## See Also

[Self-Healing in Modern Operating Systems](http://queue.acm.org/detail.cfm?id=1039537)
