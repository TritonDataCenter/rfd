---
authors: Jerry Jelinek <jerry@joyent.com>, Kody Kantor <kody.kantor@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+174%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 174 Improving Manta Storage Unit Cost

## Problem

We need to find a way to improve the storage unit cost ($/GB/Month) of Manta
as compared to Manta's competitors.

Here is a back of the envelope analysis using disk overhead as an approximation
for storage unit costs. This is very dependent on the storage server (shrimp)
and zpool layout. We'll assume the configuration of the shrimps we currently
have, since that is likely to be our initial target for the short-term.

The current shrimp can support 36 disks. Each shrimp has a slog + 2 hot spares,
leaving 33 usuable disks. We're currently using raidz2 (9+2) * 3. Thus, the
current configuration has 9 disks of overhead (slog, 2 hot spares, 6 parity
disks).  This leaves 27 disks usable for data.

We store two copies of an object in 2 different AZ's for availability purposes,
so we have to count the total disks for two shrimps (i.e. 36 * 2 == 72).

This results in 27 disks usable for storing data out of 72 disks and is 38%
efficient. The current configuration provides outstanding durability and
availability, but at a comparatively high cost. We need to consider alternatives
with better storage efficiency, albeit at reduced availability and slightly
reduced durability.

## Overview of proposed solution

This RFD discusses an alternative configuration for the Manta storage tier.

One option is to keep the current approach with two copies of each object,
but reconfigure the zpool on the shrimp to improve efficiency. We could remove
the slog and replace it with a disk, then reconfigure the zpool to use
a 12-wide raidz1 layout. That is, (11+1) * 3. This has 3 disks of parity
overhead and 33 disks available for storing data. This configuration is 46%
efficient (33 disks out of 72). This is a straighforward solution, but the
improvement in unit cost is not that compelling.

Instead, we propose storing only a single copy of each object, but with a
distributed high availability (HA) storage solution to maintain good
availability. We believe this is how most of Manta's competitors approach this
problem and storing a single copy of each object virtually cuts our unit cost
in half.

A theoretical setup which might be similar to Manta's competitors is a 20 disk
HA setup using 17+3 erasure coding across multiple machines. This has 3 disks
of parity overhead, but all disks are distributed over 20 machines. The object
data is highly available since another machine can still access the disks if
the active server fails.

ZFS already uses erasure coding for raidz and we can configure a zpool over
iSCSI (iscsi) to build a distributed solution. For this configuration, we would
need an active server, a passive server (waiting to takeover if the active
server fails) and 20 iscsi target servers. Because all of these machines must
have some basic local storage and availability, we could run them off of
mirrored disks for the local "zones" zpool.

This adds 2 disks of overhead on each machine. Because the iscsi target
machines are able to serve multiple upstack active/passive storage servers, we
can amortize the 2 disk overhead on each target and only count these 2 disks
once.

Thus, we would have 3 pairs (6 total) of mirrored system disks on the
active, passive and target machines, for a total disk overhead of 9 (3 disks
for parity + 6 system disks). With 17 disks for data, this is 65%
efficient (17 data disks out of 26) as compared to our current efficiency
of 38%.

The availability is slightly reduced since the object only exists in one AZ,
but because this is now a distributed HA configuration, if the active server
or one of the iscsi targets is down, the data is still available. We can also
still store multiple copies of an object in different AZs if the user wants to
to pay for that.

Using a distributed storage solution does have drawbacks. The configuration
is more complex, has more failure modes, and is harder to troubleshoot when
something goes wrong. These issues are discussed in this RFD.

## Hardware and Network Configuration

For the sake of discussion, assume we're going to deploy a 17+3 configuration.
That is, one raidz3 with 20 disks. We could consider other configurations
with similar parity disk overhead.

We will have one machine which assumes the active role (it has the manta data
zpool imported and is providing the `mako` storage zone service), and one
machine in the passive role (it has iscsi configured to see all 20 disks, but
does not have the zpool imported and the `mako` storage zone is not booted
until the active machine fails). The active and passive machines will only
have 2 local disks for their local mirrored "zones" zpool. We need to
determine if these machines are a new HW configuration or repurposed from one
of our existing HW configurations.

It is important to note that the active/passive `mako` storage zpool might not
be configured with a slog. We need to test if running a mirrored slog over
iscsi provides enough of a performance win. If so, we can partition the SSDs
and have multiple `makos` sharing the slogs on the remote server, since we don't
really need a full dedicated device. In this case, we can repurpose the slogs
from our existing shrimps. The rest of the RFD assumes no slog, so some of
the numbers will change if we determine a slog over iscsi is useful.

We will have 20 machines acting as iscsi targets. These 20 machines provide
the disk storage for the active/passive `mako` machines. We can repurpose our
existing shrimp HW for this role. All 20 iscsi target machines should have
disks of the same size.

For proper durability, each iscsi target can only present one disk to each
top-level vdev in the zpool of the active/passive servers. Because the
repurposed shrimps can have 34 usable disks (2 are set aside for the system's
"zones" pool), we can support a maximum of 34 active/passive `makos`.
A better alternative with 34 available disks is to have 17 active/passive
`makos` with a zpool built with two 20-wide raidz3 top-level vdevs. This
allows each `mako` to have a larger zpool with the same durability. If
an iscsi target fails, there will be two disks that are unavailable, but
they will be in different raidz3 vdevs.

Given different configurations for the iscsi target machine or different
raidz choices, a variety of valid options for the `mako` zpool configuration
are possible.

To summarize, the raidz width used by the `makos` defines how many iscsi
target machines we need, and the number of available data disks in the iscsi
target machines determines the maximum number of active/passive `mako` servers
we can provision to use the iscsi target machines. We can configure fewer
`mako` servers with multiple top-level vdevs, as long as disks from a
single iscsi target are configured into different top-level vdevs in the
zpool.

We'll call this collection of machines a storage group. This is the full
set of machines with multiple active/passive `mako` servers making use of
the disks on each iscsi target machine.

Within the storage group, we'll want to isolate all of the local network
traffic (iscsi, heartbeats, etc.) onto at least its own vlan, and more likely
onto a dedicated switch. It is possible that running 17 `makos` and all of
the associated network traffic will be too much network load within the
storage group. In that case, we'll have to support fewer `makos` in the
group and we could remove some of the data disks from the iscsi target
machines to re-use them elsewhere.

An additional point of comparison with our current manta storage tier is that
the basic building block is 2 shrimps in 2 different AZs (because we store 2
copies of an object). In this new approach, the basic building block is the
storage group with 20 iscsi target machines, up to 17 active and 17 passive
servers.  All 54 of these machines will be close together on the same network.

There are two alternatives for how the iscsi target presents disks; either
as raw disks, or as zvols. Both are described here, but there are known
issues and concerns with the zvol case, so we won't be using that option.

Here is an [overview diagram](./storage_rfd.jpg) of these various components.

### Raw Disks

Each iscsi target machine provides all of its data disks (up to 34 when using
the existing shrimps) to the appropriate number of active/passive `mako`
servers. There are 2 disks in each iscsi target machine that are reserved
for a mirrored "zones" zpool for use by that machine.

For the "dense shrimp" model a 62 disk configuration provides more options
than a 60 disk configuration, since we need 2 disks for system's "zones" zpool.
Since the iscsi target has no use for a slog, we might be able to do this.
We could then use 20 dense shrimps to provide 3 raidz3 top-level vdevs
to 20 `mako` zpools.

### ZVOLS

[NOTE: this option is hypothetical and not being pursued]

An alternative on the iscsi target machine would be to use zvols instead of raw
disks. In this case, instead of using two mirrored disks for the system's zpool,
we would continue to make the single "zones" zpool. We would use a new
raidz1 (11+1) * 3 layout to minimize disk overhead. It is hard to compare the
exact disk efficiency to the raw disk case since we have 36 disks as shared
storage, but we also have the zpool overhead to consider.  We would have to do
more measurements to determine the actual efficiency on the iscsi target in
this configuration. In this configuration the target would offer the
appropriate number of zvols to support all of the associated `makos`.

As mentioned, there are a variety of issues and concerns with this
configuration.

There are potential performance questions of running a zpool (on the `makos`)
over another zpool on the iscsi target machine. In the past, serious write
amplification has been observed.

There have been hangs reported in this configuration.

Another potential drawback is that we don't want to provide zvols that are too
large, since that has a direct impact on resilver times in the zpool that is
built on top of these zvols.

### Network

We want to isolate all of the iscsi traffic to at least its own vlan, and
perhaps even onto a dedicated switch. Using a dedicated switch will help
reduce or eliminate network partitions, which simplifies failure analysis.

We need to determine how well our NICs and network stack performs with all
of the iscsi traffic.

TBD anything else here?

## Bootup and Configuration

We will extend SmartOS to support booting and running as an iscsi target and
active or passive Manta storage server. The necessary iscsi SMF services
are already delivered with SmartOS, although not all are enabled.

We will add a new configuratation directory `/zones/stg` which will
hold the relevant information on how each new role will be configured. We'll
also add a new SMF `/system/smartdc/stg` service which will read the new
configuration data, if it is present, and setup the machine in the correct role.

The existence of the `/zones/stg/target` file indicates the machine should
setup as an iscsi target. The `stg` service will import that
file (`svccfg import /zones/stg/target`) which is an iscsi configuration dump
from `svccfg export -a stmf` when the iscsi configuration was created. The
`stg` service will also enable the `system/stmf` and `network/iscsi/target`
services. At this point, the machine will be active as an iscsi target.

The existence of the `/zones/stg/server` file indicates the machine should
setup as either an active or passive storage server. This file will
contain a list of iscsi target names and IP addresses. For example:
```
iqn.2010-08.org.illumos:02:a649733b-c4de-e1ee-918c-893622209f41 10.88.88.133
...
```
The `stg` service will read this list, run `iscsiadm add static-config` for
each target, then run `iscsiadm modify discovery --static enable`. At this
point, all of the configured iscsi targets will be visible on the machine. The
final step of the `stg` service will be to assume the role of either an active
or passive storage server.

The `/zones/stg/twin` file will contain the IP address of the other
machine in the active/passive pair.

We make use of the Multi-Modifier Protection (`mmp`) capability of ZFS to
assist in the HA behavior of the active/passive machines. `mmp` is used in an
HA configuration to determine at `zpool import` time if the zpool is
currently actively in use on another machine, or when that machine was last
alive. This capability is enabled by turning on the `multihost` property.

The following outline describes what happens after the `stg` service configures
the iscsi targets and prepares to become either the active or passive server.
```
1. Run `zpool import` on the data zpool residing on the iscsi targets.
2a. If the import succeeds, the machine becomes the active server. It starts
    the heartbeat responder and boots the `mako` storage zone.
2b. If the import fails because the zpool is already active on the other host,
    the machine becomes the passive server. The service starts the heartbeater
    using the IP address from the `/zones/stg/twin` file and blocks until the
    heartbeater exits (implying the active server is dead). When the heartbeater
    exits, the service starts over at step 1.
2c. If import fails because the zpool was previously active on the other
    host, but that host is no longer active, the service forcefully imports
    the zpool and finishes the work from step 2a.
```

### Installation

We have described the configuration and behavior for SmartOS in the role
of an HA storage server or iscsi target, but we also need to determine how this
configuration is initially installed and setup. This process is TBD.

## Mako Storage Zone Manta Visibility

The active/passive servers will each have a `mako` storage zone configured.
These will be identical zone installations since either machine can provide the
identical storage service to the rest of Manta. The `mako` storage zone will
only be booted and running on the active server.

There are a bunch of open questions on how the active/passive `mako` visibility
will be exposed to the rest of Manta when we have a failover. We're targeting
one minute for a passive to become the active. This includes the time for
the heartbeater timeout, importing the zpool, booting the `mako` zone, etc.
so we'd ideally like the network flip to be completed within around 30
seconds, if possible.

- If the active/passive `mako` zones share the same IP, when we have a flip,
  how quickly will this propagate through the routing tables? Is there anything
  we could actively do to make it faster? Is having the same IP all that is
  necessary? Is the gratuitous arp that gets emitted when the new `mako` zone
  boots adequate?
- Is there some way to configure DNS so that records have a short TTL and we
  quickly flip?
- Is there some other approach, perhaps using cueball or other upstack
  services which we can use to quickly flip the `mako` over when the passive
  machine becomes the active machine?

## HA and Failures

This section discusses the various failure cases and how the system behaves
in each case.

### Active/Passive Failover

The active server can fail for several different reasons; it can panic or
hang, HW can fail, it can lose its network connection, etc.

The heartbeater is used by the passive server to determine if the active
server is still alive. The active server runs the heartbeat responder, which
simply acks the heartbeats from the passive server. The passive server runs
the hearbeater which periodically checks the active server and expects an
ack. If the heartbeater exits because it did not receive an ack, the passive
server takes advantage of the `mmp` capability in ZFS to attempt to become
the active server.

We need further testing before we have a final value, but we have a target
of one minute for an active/passive flip before the `mako` storage service
instance is once again available.

If the active server loses its internal storage group network connection, it
will no longer be able to ack heartbeats, but it will also lose access to the
iscsi target disks. The `mmp` feature in ZFS will suspend the zpool if the
active server cannot write the txg within the `mmp` timeout. At this point
the only option is to reboot the server since we cannot export the zpool (or
do any other writes). We probably want to configure ZFS so it just panics the
system in this case. This will also reduce the possibility of an errant write
operation from within the iscsi or network stack if whatever issue was
preventing the writes were to suddenly clear.

If the active server stops responding to heartbeats the `mmp` capability
in ZFS makes it possible for the passive machine to forcefully import the
zpool because the `mmp` timeout has been exceeded. The passive machine
cannot forcefully import the zpool when the `mmp` status shows the zpool
is live on another host.

If the passive server fails for any reason, there is no impact unless the
active server fails at the same time. At this point, all of the objects on
that `mako` would be unavailable.

### iscsi Target Machine Failure

When one of the iscsi target machines goes down, all 17 active `mako` servers
will see a disk fail in their zpool, but because they are a raidz3, there
would have to be more than three iscsi target machines down before there was
a loss of data and availability.

When the failed iscsi target machine comes back up, all 17 `mako` zpools will
be resilvering against disks in that box. This might be a performance concern
and is called out in the testing section.

### iscsi Target Disk Failure

This will be just like a normal disk failure in the `mako's` zpool, but only
one of the 17 `mako` servers would be impacted. Once the disk was replaced,
the single impacted `mako` zpool would resilver.

## Maintenance procedures

### Active Server Maintenance

Force a flip before doing maintenance by exporting the zpool and stopping
the heartbeat responder.

TBD maybe some other action to flip muskie requests to new active?

### Passive Server Maintenance

No special action required.

### iscsi Target Machine Maintenance

TBD, but `mako` zpool resilvering should handle most cases.
- when we have to do maintenance on all of the iscsi targets (e.g. new PI
  reboot), we need to do them one at a time, wait for all of the `makos` to
  finish resilvering the disks on that machine, then move on to the next
  iscsi target. This entire sequence will need to be monitored and coordinated
  within the storage group.

### Switch Maintenance

TBD, but entire storage group might be unavailable unless we have an HA
switch configuration

## Troubleshooting procedures

TBD section needs more

- With ZFS sitting on top of iscsi we lose FMA in both directions (faults,
  blinkenlights etc). Do we need a transport between the iscsi targets and
  the `makos`? Is this a new project to extend the capabilities here? There is
  a lot of iscsi work in the Nexenta illumos-gate clone. We should upstream
  all of that and it may also contain some improvements that could help here.

## Testing

### Failure Testing

This section needs more details, but here is a rough list.

- active server failure and failover
- active stops responding to HB, passive takes over (imports zpool), active
  should panic/reboot.
- Force a scenario where iscsi stops working but heartbeater still works,
  should be the same result as previous test
- Kill the heartbeat responder so passive thinks the active died. The passive
  should not be able to takeover.
- network partition (is it possible to only lose access to iscsi disks or only
  HB access without losing all storage group network access? how?)
- iscsi target node failure
- when iscsi target fails and reboots, all 17 makos will be resilvering
  against disks in the box. Are there any load or other performance problems
  in this scenario?
- iscsi target disk failure
- storage group switch failure

### Load Testing

This section needs more details, but here is a rough list.

- Need to estimate the expected read/write load.
- How much network traffic on iscsi vlan/switch in a full 54 node config?
- How well do our NICs and network stack handle the expected maximum iscsi
  load from all 17 `makos`.
- How well do the iscsi targets handle the load for at the disk level?
- How well do the iscsi targets handle the load when all 17 active nodes are
  doing heavy I/O?
- Is the active node seeing unacceptable load because of the iscsi initiator?

### Performance Testing

TBD but related to load testing. Probably want to see how hard we can push
1 `mako` (i.e. not the expected load, but what is the max?).

## Open Issues

TBD
