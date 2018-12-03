---
authors: Jerry Jelinek <jerry@joyent.com>
state: draft
---

# RFD 159 The Manta Storage Zone Capacity Limit

## Overview and Motivation

Within a Manta deployment, there are a number of different components that
use and report on the storage zone capacity. The capacity in turn is used
by Muskie to determine where objects can be stored. Even a small change in
the usage and capacity limit numbers can have a significant impact on the
overall economics of a large Manta deployment.

This RFD describes the relevant components and settings. It then describes
possible future changes to some of these settings which could increase the
usable capacity of a storage node.

## Measuring

There are many different ways to measure the available and used storage on a
node, and some of them report different values.

- theoretical
- zpool list
- zfs list
- minnow (does **statvfs** on dataset within storage zone)
- circonus

The theoretical total space is the sum of the disks used to construct the
zpool, once overhead for the configured raid level has been subtracted.
For example, a top-level raidz2 vdev logically uses 2 disks for parity, so
two disks must be omitted from the total. Likewise, hot spares contribute
no usable storage and must be omitted.

The **zpool list** command reports the size and free space for the zpool. The
available space reported by the **zfs list** command will be less than the
size reported by zpool. In general, the observed difference seems to
be 3% - 4% less. This translates to a several TiB difference on our
production storage nodes.

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

## Quota

If we set a quota on the storage zone dataset, this obviously reduces the
available space for object storage, due to the values reported by minnow.

Due to various bugs, we prefer to use a quota here to prevent the entire
system from filling up if there are bugs in other parts of Manta. That is,
we want to limit object space usage in the case when too many objects would be
erroneously allocated to the node, filling it up.

Setting a quota gives a lower value of available space for the node vs. what
is actually available. Thus, we don't want to use too high of a value, since
that represents unusable space which increases the overall cost of each node.

Using a quota on the storage zone dataset to reserve 1 TiB of usable space
should be more than adequate for the rest of the system. In the future, we
might want to reduce this even more.

One TiB of space will vary based on the size of the zpool. For example, our
smaller storage nodes have approximately 177 TiB of usable space in the
top-level dataset. Thus, the storage zone's quota should be the total top-level
space (177) * .994 = 176. For our larger nodes, they have approximately 266 TiB,
so the quota would be 266 * .996 = 265. That is, as the storage capacity
grows, we must use a different scaling factor to reserve approximately 1 TiB via
setting the storage zone's quota.

## Muskie Limit

Within muskie, there is a limit as to how much space will be used in each
storage zone. This limit is currently set to 95%, but there is a lot of
relevant history behind this which we'll briefly summarize.

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

## Capacity Limit

The investigation for OS-7151 has shown that our ZFS performance was dependent
on the zpool fragmentation much more than on how full the dataset was. The
key point here is that fragmentation is for the entire zpool, not any specific
dataset.

By setting aside 1 TiB of space with a quota on the storage zone dataset, and
then also setting a muskie limit of 95%, we are being quite conservative and
leaving a lot of usable storage on the table. At a minimum, we should account
for the quota overhead in the overall calculation for how much space muskie
be able to consume on the node. However, doing this directly would involve
source code changes, which can be a slow process to implement and deploy.
Instead, a simpler approximation might be to set the muskie allocation limit
to 96% (or some other value slightly over 95%).

During testing in the lab, we have run a zpool up to 99% full with no
noticeable degradation in spa sync and zil commit latency (but remember that
the fragmentation profile is important).

We should develop a plan to gradually roll out increases of the muskie limit,
beyond 95%, into production. Ideally we can do this incrementally, on a few
storage nodes at a time, then observe performance there, and roll back if
we encounter new ZFS problems, before we deploy the updated limit to the entire
fleet.

As we develop this plan, it will be described in this RFD.
