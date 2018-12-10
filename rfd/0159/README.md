---
authors: Jerry Jelinek <jerry@joyent.com>, Kody Kantor <kody.kantor@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues/123
---

# RFD 159 Manta Storage Zone Capacity Limit

## Overview and Motivation

Within a Manta deployment, there are a number of different components that
use and report on the storage zone capacity. The capacity in turn is used
by Muskie to determine where objects can be stored. Even a small change in
the usage and capacity limit numbers can have a significant impact on the
overall economics of a large Manta deployment.

This RFD describes the relevant components and settings. It then describes
possible future changes to some of these settings which could increase the
usable capacity of a storage node.

## Policy

The intention of the policy for the capacity limit is that Manta should fill
storage zones up to a max utilization of X% (for some specific X). X is chosen
such that performance remains reliably good (at the expected fragmentation
rate).

The max utilization must also account for a fixed amount of space used for
temporary log files, crash dumps, and other files used by the rest of the
system.

Over time, ongoing work may allow us to increase X which decreases the overall
cost of Manta.

## Mechanism

While the policy is fairly straightforward, the mechanism to acheive that
is more complicated.

We want Manta to stop trying to use a storage zone before it's actually full,
otherwise there would be requests that fail as the storage zone fills up.
In addition, we wouldn't have room to write logs or other files inside the
storage zone. This implies that Manta is aware of the physical space available
in the storage zone and stops writing to it before it's full. This behavior is
currently controlled globally by Muskie for all storage zones using the
MUSKIE_MAX_UTILIZATION_PCT tunable.

In addition, we want a ZFS quota on each storage zone to act as a backstop in
case of a problem with the above mechanism.

Since MUSKIE_MAX_UTILIZATION_PCT is effectively applied after the quota, if
the policy has a target of X%, the operator must configure the quota and
MUSKIE_MAX_UTILIZATION_PCT such that the product of these two represents X% of
usable storage on the box. That implies MUSKIE_MAX_UTILIZATION_PCT will be
slightly greater than X.

While it may be obvious, it is worth reiterating that the quota on the zone
is a backstop and cannot be used properly in lieu of the
MUSKIE_MAX_UTILIZATION_PCT setting in Muskie.

## Measuring

There are many different ways to measure the available and used storage on a
node, and some of them report different values.

- theoretical
- zpool list
- zfs list
- minnow (does **statvfs** on dataset within storage zone)
- circonus
- cmon

The theoretical total space is the sum of the disks used to construct the
zpool, once overhead for the configured raid level has been subtracted.
For example, a top-level raidz2 vdev logically uses 2 disks for parity, so
two disks must be omitted from the total. Likewise, hot spares contribute
no usable storage and must be omitted.

The **zpool list** command reports the size and free space for the zpool. The
available space reported by the **zfs list** command will be less than the
size reported by zpool. In general, the observed difference is 3% - 4% less.
This translates to a several TiB difference on our production storage nodes.
This difference is known as the ZFS "slop space" and is by design.

The zfs list value for **avail** will be controlled by any **quota** set on
the dataset. We should never have a quota on the top-level 'zones' dataset
(since it would be pointless), but we do often use quotas on the per-zone
datasets. Thus, these datasets will appear to have less available space than
is shown for the top-level 'zones' dataset.

The **statvfs** value reported by minnow will match the zfs list result when
the -p option is used (which reports parseable numbers instead of human-readable
values). Note that minnow is running inside the storage zone and its values
will reflect any quota set on the zone's dataset.

Circonus is the monitoring tool we use for operations. It reports the parseable
'used' and 'avail' values from a 'zfs list' against the top-level 'zones'
dataset. Thus, it is reporting these values for the entire machine, without
regard for any quota set on any lower dataset in the zpool.

The cmon agent will use the same 'zfs list' approach as Circonus, but it can
do this for each zone's dataset. Thus, for a storage zone, the result will
reflect any quota set on that dataset.

## Quota

Setting a quota on the storage zone dataset obviously reduces the
available space for object storage, as compared to the total space on the
server, due to the values reported by minnow.

Due to various bugs seen in the past, we prefer to use a quota here to prevent
the entire system from filling up if there are bugs in Manta. That is,
we want to limit object space usage in the case when too many objects would be
erroneously written to the node, filling it up. The quota provides a
"safety net" to prevent the entire system from filling up due to a bug in Manta.

Setting a quota gives a lower value of available space for the node vs. what
is actually available. Thus, we don't want to use too high of a value, since
that represents unusable space which increases the overall cost of each node.

Using a quota on the storage zone dataset to reserve 1 TiB of usable space
should be more than adequate as a safety net for the rest of the system.

To set a fixed 1 TiB quota, the total top-level space for the 'zones' dataset
should be used, minus 1 TiB. The resulting value should be applied as the
quota for the storage zone's dataset.

Assuming a fixed 1 TiB for the quota, this accounts for a small precentage
reduction in the total usable space on the system. However, given the
size of our storage servers and the fact that capacity increases with
each generation, this precentage is negligible. For example, on a 177 TiB
server, it is .57% of total capacity, and this faction only goes down as
we deploy larger servers. Thus, for practical purposes, we can usually choose
to ignore the quota.

### Setting a Quota

A quota is not automatically applied when an operator deploys a new storage
zone. After a new storage zone is deployed the operator must go back and apply
a quota. This is usually done using `vmadm update` invoked by `manta-oneach`,
like in [CM-1448](https://jira.joyent.us/browse/CM-1448).

Occasionally we forget to run this command and end up with a number of storage
nodes that don't have _any_ quota. This is problematic, and could lead to a
zone completely filling the zpool. Some examples of this problem can be found in
[OPS-4338](https://jira.joyent.us/browse/OPS-4338) and
[MANTA-3827](https://jira.joyent.us/browse/MANTA-3827).

Further complicating things, if we realize that we forgot to apply a quota to a
storage zone and apply one later, it might be too late. Quotas will not
be enforced if the zone has already surpassed the quota when it is applied
([OS-4302](https://jira.joyent.us/browse/OS-4302)).

Another potential problem is that operators must know the correct quota to set
for each storage zone. As discussed earlier, this is based on the zpool capacity
of the storage node on which the zone is being deployed. Any time we install a
storage node with a new zpool capacity the operator will have to re-calculate
the proper quota to use for any storage zones it hosts. If the zpool capacity of
storage nodes isn't homogenous then this can quickly becomes an operational
burdon and potential for misconfiguration.

## Muskie Limit

As described in the 'Mechansim' section, within Muskie there is a limit
(MUSKIE_MAX_UTILIZATION_PCT) as to how much space will be used in each storage
zone. This limit is currently set to 95%, but there is some relevant
history behind this which we'll briefly summarize.

In the past, we had the limit set to 93%. The investigation on
[MANTA-3571](https://jira.joyent.us/browse/MANTA-3571)
identified that ZFS performed well up to the 96% - 96.67% full level. Based
upon that investigation, we raised the limit to 95%. However, after doing
that, we hit
[OS-7151](https://jira.joyent.us/browse/OS-7151)
where we see metaslabs being loaded and unloaded at
high frequency. This in turn leads to long spa sync and zil commit times,
which in turn leads to bad latency hiccups for object writes. In addition,
we observed other zil commit latency issues
([OS-7314](https://jira.joyent.us/browse/OS-7314)), but those have since
been fixed in the upstream ZFS code (although not yet deployed in Manta
production).

As a short-term fix for this problem, we're currently setting
'metaslab_debug_unload' to prevent metaslabs from unloading. This is a
temporary workaround until we have a production fix for OS-7151 deployed.

After attempting, and failing, to reproduce OS-7151 in the lab, we have
determined that this issues is sensitive the fragmentation profile on the
machine. That is, the 'zpool list' command will show the overall fragementation
of the metaslabs, but this by itself is not useful. Some metaslabs can be
very highly fragmented while others are not. OS-7151 seems to occur when
**all** of the metaslabs are fragmented in a similar way. So far we haven't been
able to recreate this scenario, but some of the production machines are in
this state. In the lab, we have have been able to run the system up to 99%
full with no observed latency issues in either spa sync or zil commit times.

Thus, the investigation from MANTA-3571 is not helpful as a guideline for
setting the maximum capacity across production. For now, using 95% is working
well with the 'metaslab_debug_unload' workaround (which is only necessary
for those nodes with problematic fragmentation). We're also testing a
proposed fix for OS-7151 on one of the nodes with the problematic fragmentation
and it is working well so far.

There is one additional factor to be aware of with the Muskie limit. The way
Muskie works, it rounds up its usage calculation. That is, with a
setting of 95%, Muskie will actually only use slightly over 94% of the
available storage in the zone.

Thus, if our intended target utilization of the total space on the storage zone
is 95%, then we must actually set the Muskie limit to 96%. Note that even with
this setting, we won't go over 95% of the total space on the server since the
quota has already been subtracted from the total available space to the zone.

### Setting the Muskie Limit

The feature to allow the Muskie storage utilization threshold be configurable
was added in [MANTA-2947](https://jira.joyent.us/browse/MANTA-2947). This
introduced the `MUSKIE_MAX_UTILIZATION_PCT` tunable for the `manta` application
in SAPI. Relatedly, [MANTA-3488](https://jira.joyent.us/browse/MANTA-3488)
allows the 'poseidon' user to write to Manta after it has reached the
Muskie storage utilization threshold.

This means that the Muskie storage utilization limit is effectively a
region-wide value. When this limit is modified it will be propagated to each
Muskie zone the next time the in-zone config-agent polls SAPI for configuration
changes. The config-agent poll interval is currently set to two minutes. This
will have be considered in the plan to gradually roll out storage utilization
changes across a region.

## The Future of the Muskie Capacity Limit

The investigation for OS-7151 has shown that our ZFS performance was dependent
on the zpool fragmentation much more than on how full the dataset was. The
key point here is that fragmentation is for the entire zpool, not any specific
dataset.

By setting a muskie limit of 95%, we are being fairly conservative and
leaving a lot of usable storage on the table (even with the quota abosrbed
into the round up behavior).

During testing in the lab, we have run a zpool up to 99% full with no
noticeable degradation in spa sync and zil commit latency (but remember that
the fragmentation profile is important).

We should develop a plan to gradually roll out increases of the muskie limit,
beyond 95%, into production. Ideally we can do this incrementally, on a few
storage nodes at a time, then observe performance there, and roll back if
we encounter new ZFS problems, before we deploy the updated limit to the entire
fleet.

As we develop this plan, it will be described in this RFD.
