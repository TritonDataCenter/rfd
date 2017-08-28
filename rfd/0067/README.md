
---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+67%22
---


<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [RFD 67 Triton headnode resilience](#rfd-67-triton-headnode-resilience)
  - [Status](#status)
  - [Goals](#goals)
  - [Implementation Overview](#implementation-overview)
  - [Operator Guide](#operator-guide)
    - [Setting up secondary headnodes](#setting-up-secondary-headnodes)
    - [Setting up HA instances](#setting-up-ha-instances)
    - [Decommissioning a headnode server](#decommissioning-a-headnode-server)
    - [Headnode recovery process](#headnode-recovery-process)
    - [Other new commands](#other-new-commands)
  - [Core services](#core-services)
    - [imgapi](#imgapi)
      - [consider limiting what local IMGAPI data is backed up](#consider-limiting-what-local-imgapi-data-is-backed-up)
    - [dhcpd](#dhcpd)
    - [assets](#assets)
    - [sapi](#sapi)
    - [ufds](#ufds)
    - [sdc](#sdc)
  - [Milestones](#milestones)
    - [M0: secondary headnodes](#m0-secondary-headnodes)
    - [M1: Controlled decommissioning of a headnode](#m1-controlled-decommissioning-of-a-headnode)
    - [M2: Headnode recovery](#m2-headnode-recovery)
      - [restore process](#restore-process)
    - [M3: Surviving the dead headnode coming back](#m3-surviving-the-dead-headnode-coming-back)
  - [TODOs](#todos)
  - [Appendices](#appendices)
    - [Relates Issues](#relates-issues)
    - [data to save](#data-to-save)
    - [Prior art](#prior-art)
    - [Why 3 HNs and not 2?](#why-3-hns-and-not-2)
    - [What does it mean to be a headnode?](#what-does-it-mean-to-be-a-headnode)
    - [Why new zones instead of migrating same UUID?](#why-new-zones-instead-of-migrating-same-uuid)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


# RFD 67 Triton headnode resilience

Some core Triton services support HA deployments -- e.g. binder (which houses
zookeeper), manatee, and moray -- so that theoretically the service can survive
the loss of a single node. Triton ops best practice is to have 3 instances of
these services. However, the many other services that make up Triton either
don't support multiple instances for HA or operator docs and tooling isn't
provided to do so. That means that currently the loss of the headnode (e.g. loss
of the zpool) makes for a bad day: recovery is not a documented process and
could entail data loss.

This RFD is about documenting and implementing/fixing a process for headnode
backup/restore and resilience, and for controlled decommissioning of headnode
hardware. The holy grail is support for fully redundant headnodes and HA
services, so that no single node is "special" -- but that is a large project. We
want someting workable sooner.


## Status

See [rfd67 labelled issues](https://devhub.joyent.com/jira/issues/?jql=labels%20%3D%20rfd67).
Note, however, that not all of these are requirements for this RFD. See details
on particular [milestones](#milestones). Currently partial support for M0 is in
#master (updates so that components can support multiple headnodes) and tooling
for setting up a CN to be an HN is in the works in various "rfd67" branches.


## Goals

A properly setup TritonDC (see below):

- supports controlled decommisioning of a headnode, by migrating service
  instances to other headnodes;
- can maintain service availability with the loss of any single node, other
  than the primary headnode;
    TODO: modify this one if we don't have a "primary" headnode concept; which
    might allow an operator to put some of the core single-inst zones on
    server other than headnode0.
- can be quickly (say within 1h) recovered on a secondary headnode with the
  loss of the primary headnode;
- can boot CNs while the primary headnode is down; and
    Q: CN booting DHCP request: Does that broadcast? Or does it need the
        dhcpd zone IP?
- the customer data path (i.e. fabric overlay networking) is working while
  the primary headnode is down.
    Q: Is the data path broken with the headnode down? I.e. Can portolan still
        work with the primary headnode down?
    TODO: Decide if this is a goal. I hope it can be.
- Q: what about CNS services? ... at least in a production configuration where
  there are DNS servers (details?) slaving off the internal CNS zone. Does a
  short TTL kill DNS while the primary is down?  The issue here is that DNS
  could be considered data-path now.
- Q: what about CMON services while headnode is down?

Non-goals:

- Recovery from off-line backups (of postgres, imgapi files, etc.)
- Full HA, i.e. automatically tolerating the loss of the primary headnode.

A "properly setup TritonDC" is:

- Multiple headnodes (minimum 3, technically could live with 2 "HNs" + one
  "CN" that holds HA manatee and binder instances, but at that point just
  making that CN an HN makes docs and process simpler).
- HA binder (3 insts, on separate nodes, one on the primary HN and one on a
  secondary)
- HA manatee (at least 3 insts, one on each HN)
- HA moray (2 insts minimum, 3 insts are recommended, at least one on the primary HN)
- HA portolan (TODO: details)
- TODO: HA CNS? Even possible? See "Goals" section above.
- TODO: HA CMON? See "Goals" section above.
- Other services: An inst of every "required" core service on the primary HN.
  Here "required" is the set of core services for which the operator cares
  about service availability for the scenarios listed in the goals. E.g.,
  this definitely includes VMAPI, but it might exclude CA or CMON or Docker
  or CloudAPI. TODO: Define this set.


## Implementation Overview

- Docs (and possibly some sdcadm command) define what "properly setup" is.

- Triton components (platform, headnode setup scripts, services) are updated
  to support having multiple headnodes.

- `sdcadm` grows tooling to help operators convert two CNs to HNs.

- Existing sdcadm commands for updating headnodey things (adding platforms
  to /mnt/usbkey and /usbkey, updating gz-tools, `sdcadm self-update`) are
  updated to apply changes to all headnodes.

    - TODO: what about catching up when changes can't be applied to all
      headnodes and/or checking if HNs are in sync.

- A sdcadm-owned SMF service running on each HN handles backing up data for
  local instances of non-HA services (e.g. imgapi) to "/var/sdcadm/restore-data"
  on all the other HNs. IOW, each HN should have the data required for
  restoring the non-HA service instances from other HNs.

- `sdcadm` adds tooling for restoring non-HA service instances. This allows an
  operator to SSH to a secondary HN and run and restore services lost due to
  a dead HN.

- `sdcadm` adds tooling to *migrate* non-HA service instances from one HN to
  another. This allows for controlled (i.e. minimal service downtime) evacuation
  of service instances from an HN to support maintaining or decommissioning it.


## Operator Guide

This section details how operators are expected to "properly setup" their DC
for headnode resilience and to handle headnode recovery and decommissioning.
I.e. this is where we feel out the new operator UX and provide a basis for
operator docs at <https://docs.joyent.com> for DC setup and headnode recovery
and maintenance.

The proposed new sdcadm commands are:

    sdcadm server ls                # replacement for `sdc-server list`
    sdcadm server headnode-setup    # convert a CN to an HN
    sdcadm service migrate          # controlled migration of a service inst
    sdcadm service restore          # restore one or more services

    # Lower priority.
    sdcadm server cn-setup          # replacement for `sdc-server setup ...`
    sdcadm status                   # give DC current setup status and health


### Setting up secondary headnodes

A prerequisite for the proposed headnode recovery support is that a DC is
setup with two secondary headnodes. Current TritonDC operator documentation
suggests that two CNs are used for HA instances of the core binder, manatee, and
moray instances. This RFD suggests the following process to convert those
CNs over to being "secondary headnodes":

    sdcadm server headnode-setup $CN1   # convert CN1 to being a headnode
    sdcadm server headnode-setup $CN2   # convert CN2 to being a headnode

Part of headnode-setup is to ensure that components in the DC are of sufficient
version to support multiple headnodes.

The headnode conversion will involve a reboot (at least, to use the fs-joyent
script that is involved in creating the zones/usbkey dataset). The reboot could
mean temporary service disruptions on the order of what a manatee or binder
instance upgrade can entail.

For starters, this will only support converting a *setup* CN to an HN.
Eventually this same command may support setting up a new *unsetup* server as a
headnode:

    sdcadm server headnode-setup $UNSETUP_CN


### Setting up HA instances

A DC "properly setup" for resiliency has setup a few services to be HA:
binder, manatee, moray.

    sdcadm post-setup ha-binder -s $HN1,$HN2
    sdcadm post-setup ha-manatee -s $HN1,$HN2
    sdcadm create moray -s $HN1,$HN2


TODO: It would be nice to update these commands to *default* to using the
set of headnodes on which to deploy so that these would become:

    sdcadm post-setup ha-binder
    sdcadm post-setup ha-manatee
    sdcadm post-setup ha-moray

TODO: Minimal HA services might be expanded to include the assets and dhcpd
services.


### Decommissioning a headnode server

Occassionally one needs to decommission a headnode server or, relatedly,
perhaps take it down for long term maintenance. The proposed way of doing this
is to run the following command(s) to move all core Triton services to another
headnode, leaving the one needing maintenance empty:

    sdcadm service migrate $HN0 $HN1 [--all | SERVICE ...]

For example, to migrate all services from the initial headnode (hostname
"headnode0") to a secondary headnode (hostname "3WGMXQ1"):

    sdcadm service migrate headnode0 3WGMXQ1 --all

This would do a controlled "move" of services on "headnode" to headnode
"3WGMXQ1". "Move" is quoted because, *new* instances are created and the old
instances destroyed, as opposed to existing "VM migration" scripts which move a
VM dataset and maintain VM UUID, nics, etc. See the [Why new zones instead of
migrating same UUID?](#why-new-zones-instead-of-migrating-same-UUID) section in
the appendix.

Note that service migration will avoid having multiple instances of the same
service on the same HN. For example, if there is already a manatee on this HN,
then another will not be created. It is expect that the operator may have to
re-establish three HA instances of binder, manatee, and moray via the following
on some new server.

    sdcadm server headnode-setup $SERVER
    sdcadm post-setup ha-binder -s $SERVER
    sdcadm post-setup ha-manatee -s $SERVER
    sdcadm create moray -s $SERVER

An alternative is to use a *new server* as the replacement headnode, leaving
the existing secondary headnodes alone:

    sdcadm server headnode-setup $NEW_SERVER
    sdcadm service migrate headnode0 $NEW_SERVER --all
    # decommission headnode0

TODO: ask joshw's opinion on VM migration vs create new insts?


### Headnode recovery process

The main headnode has just died. This section describes how the operator is
expected to recover things.

    ssh $SECONDARY_HEADNODE
    sdcadm service restore

This will walk through recovering all required Triton DataCenter core instances
on this server. On success, the DC should be fully operational. However
the final state will be HA clusters of binder, manatee, and moray that only have
*two* instances -- less than the required three. It is expected that the
operator follow up relatively soon with an additional headnode:

    sdcadm server headnode-setup $SERVER

and re-establishing three HA instances of those services:

    sdcadm post-setup ha-binder -s $SERVER
    sdcadm post-setup ha-manatee -s $SERVER
    sdcadm create moray -s $SERVER


TODO: What happens if 'recover' is run, and then the original headnode
comes back up? Can we explicitly ensure that services on all other servers don't
start talking to the "deposed" server's instances again? Should a booting
primary headnode go "deposed" if it sees another primary? Should cn-agent do
that? What is the mechanism for seeing other primaries? Presumably from CNAPI
talking to manatee (because manatee is the authority). The "authority" could be
in the config (the 'sdc' application metadata.headnode_primary) and retrieved
via config-agent or not. Basically I think this should be at the service level:
if a service FOO doesn't support multiple instances... then perhaps it should be
required to only operate on the primary headnode. It should check that config
var and not start if it isn't on the primary. Does this work? HA services should
behave fine if the deposed primary comes back to life. Requiring a new version
of all services for this is quite a bit. I suppose the sdcadm service could stop
VMs on a deposed headnode if it can detect.


### Other new commands

This RFD proposes some other `sdcadm` commands. They are lower priority.

    sdcadm server ls

`sdc-server` could use an update. We could either improve it, or start
deprecating it and moving improved server management to another tool. This
RFD proposes starting to move common operator server management commands to
`sdcadm server ...`, starting just with listing servers -- with some changes to
default `sdc-server list` output so that headnodes are called out, filtering,
`-H -o` support, etc.

    sdcadm server cn-setup

Given that we are implementing `sdcadm server headnode-setup`, it would make
sense (and be nice) to also support regular CN setup via `sdcadm` as well.

    sdcadm status

Having a command for an operator to ask "what is the status of this Triton DC"
would be very helpful. This would be something with larger scope than the
existing `sdcadm check-health`. Some ideas include:

- Post-setup status: Are binder/manatee/moray setup to be HA yet?
  Are there multiple headnodes setup, as required for headnode resiliency?
- Health: `sdcadm` could start running check-health in the background
  periodically and report in `sdcadm status` the status of the last run.
- Alarms: Should Triton refresh its usage of Amon alarms, then
  `sdcadm status` could should whether there are currently open alarms.
- Listing `zonememstat -a` potential issues.


## Core services

This section discusses issues with each core service. This table gives quick
notes for each service. Details on some services, as required, are below.

TODO: fill in notes on each service:
- delegate dataset that needs to be sync'd to restore-data
- other special notes? e.g. if think this one will be easy to migrate

| Service   | DD? | Notes |
| --------- | --- | ----- |
| adminui   | -   |   |
| amon      | -   |   |
| amonredis | Y   | DD (alarm data, not absolutely critical). |
| assets    | -   |   |
| binder    | Y   | DD (zookeeper data). HA-able. |
| ca        | Y   | DD (logs, "stash"?). |
| cloudapi  | Y*  | DD (plugins, certs). |
| cmon      | Y*  | DD (cert, does it already handle HA of cert?). |
| cnapi     | -   |   |
| cns       | Y   | DD (redis, I *believe* it can be regenerated.) |
| dhcpd     | -   |   |
| docker    | Y*  | DD (certs). |
| fwapi     | Y   | DD (nothing here?). |
| imgapi    | Y*  | DD (local image file data, manifest archive, config). |
| mahi      | Y   | DD (redis cache, can be regenerated but slowly). |
| manatee   | Y   | DD (postgres data). HA-able. |
| manta     | -   |   |
| moray     | Y   | DD (nothing here?). HA-able. |
| napi      | -   |   |
| nat       | -   | Oddball. Really 'admin' shouldn't own these zones. I hope we never have any of these on headnodes. `sdcadm service migrate` will ignore these. |
| papi      | -   |   |
| portolan  | -   | HA-able. |
| rabbitmq  | -   |   |
| sapi      | Y   | DD (what is `sapi_history`? no local data cache?). |
| sdc       | -   |   |
| ufds      | -   |   |
| vmapi     | -   |   |
| workflow  | -   |   |

Legend:
- "DD?" means does this zone have a delegate dataset.
- "*" in the DD column means this is definitely a critical delegate dataset to
  preserve.

In general, as mentioned in the [Implementation
Overview](#implementation-overview) section above, a sdcadm-owned service on
headnode GZs will be sync'ing core zones' delegate datasets to the other HNs.
These will be usable for `sdcadm service {restore,migrate}`.

### imgapi

IMGAPI service migrate/restore will be a lot nicer if we can drop the old imgapi
migrations with the minver thing (SWSUP-731).

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

#### consider limiting what local IMGAPI data is backed up

Discussing with Todd, we talked about how locally stored docker images in
IMGAPI (excepting those from 'docker build', which are sent to manta if
that storage is available) that are retrieved via 'docker pull' could perhaps
be considered ephemeral... in that they could be redownloaded from the
remote Docker registry if they are purged. That seems problematic for, say, a
Docker registry that is now offline, or for which the user might no longer have
creds (if auth has changed).

If we were to consider allowing that, then something that could be done is
to have IMGAPI separate those "emphemeral" image files from the other
"stor=local" files. We'd only put the "stor=local" non-emphemeral files on
a zfs filesystem under IMGAPI delegate dataset, and then we'd be able to limit
cross-headnode backing up of IMGAPI data to just that (presumably smaller)
subset of image file data.


### dhcpd

We want to change so that there is a dhcpd (aka "booter") zone on every
headnode. Without this, CNs would not be able to boot while the initial headnode
(the one with the only instances of "assets" and "dhcpd" zones) is dead.

From discussion at YVR office:

- TODO: should be fine for CN boots, but test it (per joshw)
- TODO: Need to fix cache warming, because with multiple booters it could be
  a bigger potential issue. Also don't want to rely on not having a
  warmed cache for the failure scenario.
- TODO: How to configure booter to use the *local* assets zone for serving
  files? That might not be necessary. We'd just want a given dhcpd zone to
  (a) only use assets zones that are up (does that mean assets using
  registrar?); and (b) fairly use them, so that if a number of CNs are booting,
  they don't all use the same assets zone. To be fair, we don't have numbers
  that we need multiple dhcpd/assets zones for *scaling*. This is about
  availability.


### assets

We want to change so that there is an assets zone on every headnode, for the
same reasons as for the dhcpd zone (see previous section).


### sapi

Need to break sapi's silly circular dep on config-agent.
TODO: ticket for this.


### ufds

This zone should be easy, I hope. I *do* recall some experience with UFDS
zone setup being failure prone if part of the stack is down.

TODO: Wassup with possible ufds-replicator on new IP?

TODO: We'd want docs about possible need to update FW rules to allow replication
to continue. Or perhaps the "migrate/restore" command could warn/wait/fail
on ufds-replicator trying and failing.

TODO: amon alarm for ufds-replication failing and/or falling behind.


### sdc

- Q: Consider doing the sdc key change thing (there is a ticket I think) to
  (a) not have the sdc priv key in SAPI data and (b) to support rotation of
  it. If not in SAPI we'd need to have that in a delegate dataset and
  carry that.
- TODO: We'd want docs about possible need to update FW rules to allow
  replication to continue.


## Milestones

The milestones on the way to completing the work for this RFD.


### M0: secondary headnodes

This milestone is about providing the tooling and support for having multiple
headnodes in a DC. Secondary headnodes will be where we backup data for services
that aren't otherwise HA. The natural choice of servers for secondary headnodes
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
- Tooling and docs to convert a CN to a secondary headnode: i.e.
  `sdcadm server headnode-setup ...`.
- Change default headnode setup to use "headnode0" as the hostname.
- Whatever syncing or data backup between headnodes that is required.


### M1: Controlled decommissioning of a headnode

Basically this is support for `sdcadm service migrate ...` such that we can
fully evacuate a headnode with minimal service downtime.

The ideal is to be able to do the following in nightly-1:

- Full regular setup (perhaps with the hostname="headnode0" change) with two
  secondary headnodes setup.
- Optionally have a "tlive" tool a la `mlive` for watching service availability
  and health over a period of time.
- Move all service instances off headnode0 onto one of the secondary HNs while
  watching `tlive`. Measure what the downtime is for: cloudapi, internal
  services, data path (if any).
- Full nightly-1 test suite run (including testing the nightly-1 Manta).


### M2: Headnode recovery

Basically this is support for `sdcadm service restore ...` such that we can
fully recover from a headnode dying.

The ideal is to be able to do the following in nightly-1:

- Full regular setup (perhaps with the hostname="headnode0" change) with two
  secondary headnodes setup.
- Optionally have a "tlive" tool a la `mlive` for watching service availability
  and health over a period of time.
- `sdc-factoryreset` headnode0 into "recovery mode".
- Recover all services on one of the secondary HNs while watching `tlive`.
  Measure what the downtime is for: cloudapi, internal services, data path (if
  any).
- Full nightly-1 test suite run (including testing the nightly-1 Manta).

Also (secondary HN dies):

- ... setup ...
- `sdc-factoryreset` one of the *secondary* headnodes
- ... recovery and testing ...

Also (restore full HA on new server):

- Ensure can easily setup a 4th CN as the third HN.

* * *

TODO: A problem here is that creating new core zones, we could run out of admin
IPs! How do we know which IPs to use? We could try to get that info from NAPI.

Idea: We reserve admin IPs in NAPI for recovery instances of each of the
zones. Do this as part of ... bg process? or headnode-setup? If during
headnode setup, then we know we'll have enough... but what about when
creating later insts, like 'cloudapi'? Else 'sdcadm st/check' could have
a warning for being too low on free admin network IPs. Could also have
a suggested minimum in initial setup.

Q: Are admin IPs used for core zones in initial headnode setup fed back into
NAPI? How/where?

TODO: ask ops/support if being low on admin IPs is possible/common?


#### restore process

Feeling out the restoration process.

- Expected services to have up and running:
    manatee
    moray
    binder
    assets (NEW)
    dhcpd (NEW)

- sapi
- amonredis: Why this here? Is this following headnode.sh order?
- ufds
- workflow
- amon
- sdc
- papi
- napi
- rabbitmq
- imgapi
- ... TODO


### M3: Surviving the dead headnode coming back

What happens to the system if we've recovered from a dead headnode, and
then it boots back up with the older instances?

TODO: how do we guard against issues here?


## TODOs

See also the TODOs in each milestone section, and any "TODO" or "Q" in this doc.
This section is a general list of things to not forget.

- 'sdcadm ...' should warn/error if there are >1 insts of a service
  that doesn't support that.

- How does being a UFDS master or slave affect things here?



## Appendices

### Prior art

There are ancient `sdc-backup` and `sdc-recover` tools (and related "backup"
and "recover" scripts in "$repo/boot/" for some of the core service Triton
repositories). Those are broken, incomplete, and -- I hope -- not supported.

    [root@headnode (coal) ~]# sdc-backup
    logs at /tmp/backuplog.34881
    Backing up Manatee
    /opt/smartdc/bin/sdc-backup: line 77: sdc-manatee-stat: command not found

If feasible, this RFD will attempt to clean out these obsolete tools.


### Why 3 HNs and not 2?

We chose to document that 3 HNs are required, when the technical possible mininum
is *2* HNs. Reasoning:

- Much simpler expression of requirements in docs and potentially in
  tooling (`sdcadm post-setup ha-manatee` could assume the headnodes),
  balanced with not a big cost to having a 3rd headnode.
- It makes for slightly faster recovery on full reboot of the DC: two HNs
  booting CNs, don't need to wait for the CN with the second manatee to
  boot so can get to the point of recovering.
- Con: Needing that additional headnode which could be a concern for RFD 77
  balance of having to secure HNs against theft.


### What does it mean to be a headnode?

- the physical USB key is up to date
- have full gz tools
- have zones/usbkey mount (the "usbkey copy")
- headnode=true in sysinfo
- menu.lst will boot from the USB key
- have sdcadm installed
- sdc-vmapi, sdc-useradm et al work. Note issues with the sdc0 zone to resolve
  for this one. Perhaps the first pass of this we *don't* support running
  those sdc0-based tools on *secondary* headnodes.
- *don't* have /opt/smartdc/config/node.config
  (else you get a warning from '/lib/sdc/config.json' I believe)


### Why new zones instead of migrating same UUID?

In the [Decommissioning a headnode server][#decommisioning-a-headnode-server]
section above it is mentioned that when migrating a single-instance service from
one headnode to another via `sdcadm service migrate ...`, it will *create a new
VM with a new UUID and NICs* rather than migrating the VM dataset and using the
same UUID, NICs, etc. This section discusses why that choice.

Arguments for migrating with the same UUID, IP, etc.:

- For service migration, just using support's VM migration scripts would likely
  be a fairly quick low-tech answer to evacuate a headnode. It is possible
  (though untested) that with re-used IPs Triton config files and components
  would *not* need to be updated.

- If creating new VMs with new IPs, we will likely have to update other Triton
  components (code and/or config files and restarts) where IPs have been used
  rather than DNS names to find dependent services.

  Likewise for Manta components that use IPs for dependent Triton services. I
  think the only example is `SDC_NAMESERVERS` on some Manta instance SAPI
  metadata. That case might already (should already) be handled by
  `sdcadm post-setup ha-binder`.

Arguments for creating new zones:

- For service *recovery* (e.g. where one the headnodes has died suddenly), it
  would be onerous to do VM migration because we would have to have (relatively)
  up-to-date zfs send/recv copies of the zone root dataset for each of those
  zones. Requiring that for ongoing headnode resilience prep is overkill. For
  example, we'd be `zfs send`'ing all SMF service logs for all the core zones
  to every other headnode. Creating new VMs just means the secondary HN just
  needs: the zone image, data for the `vmadm create`, sync'd delegate dataset
  data, and new NIC IPs.

- Given ^^ that for service *recovery*, it would be nice to have service
  migration (i.e. controlled evacuation of a headnode) share the same
  implementation as recovery.

- On having to update Triton components for new core service IPs: This isn't
  wasted effort. To reach the longer term goal of HA for all or most core
  Triton services, we need to move away from hardcoded IPs to using DNS names
  (for all but bootstrapping DNS/binder itself).
