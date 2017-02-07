---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 67: Triton headnode resilience

Some parts of Triton support HA deployments -- e.g. binder (which houses
zookeeper), manatee, and moray -- so that theoretically the service can survive
the loss of a single node. Triton ops best practice is to have 3 instances of
these services. However, the many other services that make up Triton either
don't support multiple instances for HA or operator docs and tooling isn't
provided to do so. That means that currently the loss of the headnode (e.g. loss
of the zpool) makes for a bad day: recovery is not a documented process and
could entail data loss.

This RFD is about documenting and implementing/fixing a process for headnode
backup/recovery and resilience. The holy grail is support for fully redundant
headnodes, so that no single node is "special" -- but that is a large
project. We want someting workable sooner.


# Scope

Here are the theoretically possible headnode recovery cases:

1. Recover on a secondary headnode.
   Here the assumption is that the TritonDC is fully setup with three headnodes:
   a primary and two secondaries. The secondaries hold the HA instances of
   binder, manatee, and moray. The primary headnode is lost for some reason.
   There is a documented procedure for recovering full DC operation on one
   of those secondary headnodes.
2. Recover from data backups.
   The primary headnode is lost and the DC does not have functioning secondary
   headnodes. Recovery is performed on an existing or new server that will
   be setup as the primary headnode using backups of DC data.
3. Fully redundant headnodes.
   All Triton DataCenter core services are improved to support and are setup to
   be fully redundant in the DC, such that losing one of three headnodes doesn't
   result in any issues other than a temporary blip in services while failing
   instances are purged from working sets.

This RFD will propose a plan for #1 (secondary headnode recovery). #2 and #3
are currently out of scope.

The first part of #1 is defining and adding support for secondary headnodes,
including automatic processes for data backup or replication to those
secondary headnodes that is needed for recovery. The second part is the work
(support, tooling, docs, testing) for headnode recovery on a secondary headnode.


# Prior art

There are ancient `sdc-backup` and `sdc-recover` tools (and related "backup"
and "recover" scripts in "$repo/boot/" for some of the core service Triton
repositories). Those are broken, incomplete, and -- I hope -- not supported.

    [root@headnode (coal) ~]# sdc-backup
    logs at /tmp/backuplog.34881
    Backing up Manatee
    /opt/smartdc/bin/sdc-backup: line 77: sdc-manatee-stat: command not found

If feasible, this RFD will attempt to clean out these obsolete tools.


# Operator Guide

This section details how operators are expected to setup and work with
secondary headnodes. It should be used at the basis for operator docs
at <https://docs.joyent.com> for DC setup and headnode recovery and maintenance.

## Secondary headnode setup process

A prerequisite for the proposed headnode recovery support is that a DC is
setup with two secondary headnodes. Current TritonDC operator documentation
suggests that two CNs are used for HA instances of the core binder, manatee, and
moray instances. This RFD suggests the following process to convert those
CNs over to being "secondary headnodes":

    sdcadm post-setup headnode headnode # convert current HN to 'headnode0'
    sdcadm post-setup headnode $CN1     # convert CN1 to 'headnode1'
    sdcadm post-setup headnode $CN2     # convert CN2 to 'headnode2'

The first step will convert the current 'headnode' to (a) hostname "headnode0"
and (b) mark it as the "primary" headnode.

The latter two steps will convert the given compute nodes (CNs) over to being
secondary headnodes. This process will involve: rebooting the CN and renaming
its hostname to 'headnode<number>'. The reboot could mean temporary service
disruptions on the order of what a manatee or binder instance upgrade can
entail.

Note that this same command can be used to setup a new unsetup compute node
as a secondary headnode:

    sdcadm post-setup headnode $UNSETUP_CN


TODO: Discuss with joshw whether makes sense to have 'headnode_primary' in
sysinfo somehow (also in usbkey/config) and in CNAPI server record.


## Recovery process

The recovery process on a secondary HN will be as follows. The operator should
login to the secondary HN and run:

    sdcadm headnode recover             # run on a secondary HN to recover a failed primary HN

This will mark the server as the primary headnode and walk through recovering
all required Triton DataCenter core instances on this server. On success,
the DC should be fully operational. However, assuming the original primary
does not return, the final state will be HA clusters of binder, manatee, and
moray that only have *two* instances -- less than the required three. It is
expected that the operator follow up relatively soon with an additional
headnode:

    sdcadm post-setup headnode $SERVER

and re-establishing three HA instances of those services:

    sdcadm post-setup ha-binder -s $SERVER
    sdcadm post-setup ha-manatee -s $SERVER
    sdcadm create moray -s $SERVER


TODO: What happens if 'recover' is run, and then the original primary headnode
comes back up? Can we explicitly ensure at least that services on all other
servers don't start talking to the "deposed" primary again? Should a booting
primary headnode go "deposed" if it sees another primary? Should cn-agent do
that? What is the mechanism for seeing other primaries? Presumably from
CNAPI talking to manatee (because manatee is the authority).


## Controlled headnode takeover process

Similar to headnode recovery, is the occassional need for an operator to
decommission a headnode server. To do this, it is desirable to move the primary
headnode from that server to a replacement in a controlled manner. This is
called *headnode takeover* and is performed as followers

    sdcadm headnode takeover $OTHERHN

For example:

    ssh heanode1
    sdcadm headnode takeover headnode0

On success, "headnode1" will be running replacements for all core VM instances
that were running on "headnode0", and the instances on headnode0 will be
removed. If "headnode0" was the primary headnode, then "headnode1" will
now be the new primary. "headnode0" can now be decommissioned.

Note that headnode takeover will avoid having multiple instances of the same
service on the same HN. For example, if there is already a manatee on this HN,
then another will not be created here. Therefore, as with the recovery process
in the previous section, it is expect that the operator may have to re-establish
three HA instances of binary, manatee, and moray via the following on some
new server.

    sdcadm post-setup headnode $SERVER
    sdcadm post-setup ha-binder -s $SERVER
    sdcadm post-setup ha-manatee -s $SERVER
    sdcadm create moray -s $SERVER

An alternative is to use a *new server* as the replacement headnode, leaving
the existing secondary headnodes alone:

    sdcadm post-setup headnode $NEW_SERVER
    ssh $NEW_SERVER
    sdcadm headnode takeover headnode0
    # decommision headnode0


## How things work differently with secondary headnodes

- "usbkey" writes are too all the headnodes (platform install, etc.)
- non-manatee data is backed up periodically to secondary headnodes, e.g.
  the imgapi delegate dataset, the dhcpd delegate dataset?
- TODO: fill this out


# Core service changes

This section details changes needed for various core services to support
secondary headnode recovery.

Minimum versions of components that support multi-headnode TritonDC:

| Component | Version | Notes |
| --------- | ------- | ----- |
| cnapi     | ???     | CNAPI-686 |
| gz-tools  | ???     | Note that 'gz-tools' includes "[/mnt]/usbkey/scripts" updates. |


## imgapi

How should IMGAPI change so that losing the headnode doesn't mean potential
data loss of image files that are stored locally? One potential is to make
IMGAPI HA so that there are, say, 3 instances and local image files are
written to all or a subset of them before "commiting". Bryan described that as
IMGAPI trying to solve the Manta problem (without using Manta)... which feels
like sadness.

The alternative proposal is this:

- Get a periodic backup of the imgapi local file storage to the other two
  "core" CNs (those with the HA instances). For non-blessed setups, perhaps
  offer a config var to specify the servers to use for this backup, or even
  using a remote Manta for this backup.
- During recovery the new imgapi instance would use this backup to seed itself.
- This leaves the potential that you lose up to one $period of image file data
  (e.g. one hour). A post-recovery check (I think `imgapiadm check-files`
  already implements this) would give a report on file data that is missing.
- Fix IMGAPI-487 so that Docker image files are backed by Manta (if the IMGAPI
  is configured to use a Manta).

The "story" to Triton operators then is this: Try to configure your IMGAPI to be
backed by Manta, then all images except core images themselves are in Manta
and hence durable. Otherwise, there is a $period window for image file loss.

## sdcadm status

I'm consider implementing a `sdcadm status` as part of this work that will
give a report on current faults with the Triton setup:

- Is it in a blessed state with HA manatee, moray, etc.?
- Perhaps listing 'sdcadm check-health' faults.
- Listing `zonememstat -a` potential issues.

## dhcpd

Q: Do we make the dhcdp service HA? Without this, CNs would not be able to boot
while the headnode is dead.


## usbkey and assets

The usbkey holds the platforms that CNs use for netboot. Those are served
via the 'assets' zone. We will need to change the processing that add data
to the usbkey to update the keys on the "core" CNs (or some concept of
a backup target if don't have other "core" CNs). We will also need tooling
to check and sync. Some examples:

- adding a platform (via 'sdcadm platform install ...')
- changing usbkey/config (and the various split brain issues with this)
- other assets-zone-served files in the usbkey/extra dir: agentsshar, cn-tools
- usbkey copy (i.e. /usbkey)


# Milestones

The milestones on the way to completing the work for this RFD.
Issues: ["rfd67 labelled issues"](https://devhub.joyent.com/jira/issues/?jql=labels%20%3D%20rfd67)


# M0: seconary headnodes

This milestone is about providing the tooling and support for having multiple
headnodes in a DC. Secondary headnodes will be where we backup data for services
that isn't otherwise HA. The natural choice of servers for secondary headnodes
are the CNs already used to hold the HA instances of manatee, binder, and moray.
The eventual suggested/blessed DC setup will then be:

    Server "headnode0" (the "primary" headnode)
        Instance "binder0"
        Instance "manatee0"
        Instance "moray0"
        Instance "sapi0"
        Instance "imgapi0"
        ...
    Server "headnode1" (a secondary headnode)
        Instance "binder1"
        Instance "manatee1"
        Instance "moray1"
        (possibly instances of other HA-capable core services)
    Server "headnode2" (a secondary headnode)
        Instance "binder2"
        Instance "manatee2"
        Instance "moray2"
        (possibly instances of other HA-capable core services)

- Ensure the system can handle multiple headnodes.
- Ensure the system isn't dependent on the headnode hostname being exactly
  "headnode".
- Tooling and docs to update the "headnode" hostname to "headnode0".
- Tooling and docs to convert a CN to a headnode (assigning hostname "headnode1"
  and "headnode2").
- Change default headnode setup to use "headnode0" as the hostname.
  Note: Using this "headnodeN" host naming shouldn't be a requirement, but will
  be the default used by provided tooling.
- CNAPI ServerUpdate support to change a headnode's hostname. CNAPI-686


# M1: secondary headnode recovery

Dev Note: A target is to get nightly-1 to running in the "blessed" configuration
then `sdc-factoryreset` the headnode into recovery mode, recover, and verify
that we recovered correctly. This assumes the same hardware (same headnode
UUID), so ideally we'd next try stopping the headnode and attempting recovery
with a fourth, and otherwise unused, server.

TODO



# Appendices

## Open Questions

- That 'sdcadm post-setup headnode headnode' requires a reboot of the primary
  headnode, *just* to udpate the hostname to 'headnode0' is unfortunate.
  Can we avoid or skip that? Perhaps offer option for that:
        sdcadm post-setup headnode --skip-rename headnode
- What about an easier case that just snapshots all the core zones and zfs sends
  those to external storage?
- Any "Q:" and "TODO:" notes above.


## TODOs

Quick TODOs to not forget about:

- GZ PS1 update to differentiate primary vs secondary headnode

- Wildcard: how does being a UFDS master or slave affect things here?

- Grok https://github.com/joyent/rfd/tree/master/rfd/0058 relevance, if any.

- Need a ticket to handle the SAPI circular dep on itself because it uses
  config-agent.

## data to save

This is a scratch area to list data that ideally would be backed up and
restored:

- manatee postgres db
- imgapi images with stor=local
- data in any core zone with a delegate dataset:
    - cloudapi: plugin docs suggest putting them here
    - amonredis: meh, only live alarms are stored here
    - redis: Q: Is anything still using this?
    - ca: ???
    - imgapi: Q: fully handled above?
    - manatee: Q: fully handled above?
    - Q: other zones with delegate dataset?
- booter's cache of CN boot info (see HEAD-2207, HEAD-2208, MANATEE-257)
- platforms at usbkey/os
- Q: is there other info on the usbkey that we want/need to save?
