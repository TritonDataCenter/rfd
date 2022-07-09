---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+67%22
---

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


<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


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
  - [dhcpd](#dhcpd)
  - [sapi](#sapi)
  - [ufds](#ufds)
  - [sdc](#sdc)
- [Milestones](#milestones)
  - [M0: secondary headnodes](#m0-secondary-headnodes)
  - [M1: Controlled decommissioning of a headnode](#m1-controlled-decommissioning-of-a-headnode)
  - [M2: Headnode recovery](#m2-headnode-recovery)
  - [M3: Surviving the dead headnode coming back](#m3-surviving-the-dead-headnode-coming-back)
- [Scratch](#scratch)
  - [Separable work](#separable-work)
  - [TODOs](#todos)
  - [Code](#code)
- [Appendices](#appendices)
  - [Prior art](#prior-art)
  - [Why 3 HNs and not 2?](#why-3-hns-and-not-2)
  - [What does it mean to be a headnode?](#what-does-it-mean-to-be-a-headnode)
  - [Why new zones instead of migrating same UUID?](#why-new-zones-instead-of-migrating-same-uuid)
  - ['sdcadm server' notes](#sdcadm-server-notes)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status

See [rfd67 labelled issues](https://mnx.atlassian.net/issues/?jql=labels%20%3D%20rfd67).
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
  (TODO: modify this one if we don't have a "primary" headnode concept; which
  might allow an operator to put some of the core single-inst zones on
  server other than headnode0.)
- can be quickly (say within 1h) recovered on a secondary headnode with the
  loss of the primary headnode;
- can boot CNs while the primary headnode is down;
  (Q: CN booting DHCP request: Does that broadcast? Or does it need the dhcpd zone IP?)
- the customer data path (i.e. fabric overlay networking) is working while
  the primary headnode is down.
  (Q: Is the data path broken with the headnode down? I.e. Can portolan still
  work with the primary headnode down? TODO: Decide if this is a goal. I hope it
  can be.)
- (Q: what about CNS services? ... at least in a production configuration where
  there are DNS servers (details?) slaving off the internal CNS zone. Does a
  short TTL kill DNS while the primary is down?  The issue here is that DNS
  could be considered data-path now.)
- (Q: what about CMON services while headnode is down?)

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

- Docs (and possibly some sdcadm command) defining what "properly setup" is.

- Triton components (platform, headnode setup scripts, services) are updated
  to support having multiple headnodes.

- `sdcadm` grows tooling to help operators convert two CNs to HNs.

- Existing sdcadm commands for updating headnodey things (adding platforms
  to /mnt/usbkey and /usbkey, updating gz-tools, `sdcadm self-update`) are
  updated to apply changes to all headnodes.

    - TODO: what about catching up when changes can't be applied to all
      headnodes and/or checking if HNs are in sync. How about making those
      commands idempotent, so if the update failed... it might be partial,
      and you just re-run to finish (e.g. `sdcadm self-update ...`).

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
updates to operator docs at <https://docs.joyent.com>.

The proposed new sdcadm commands are:

    sdcadm server ls                # replacement for `sdc-server list`
    sdcadm server headnode-setup    # convert a CN to an HN
    sdcadm service migrate          # controlled migration of service insts
    sdcadm service restore          # restore one or more services

    # Lower priority.
    sdcadm server cn-setup          # replacement for `sdc-server setup ...`
    sdcadm status                   # give DC current setup status and health


### Setting up secondary headnodes

A prerequisite for the proposed headnode recovery support is that a DC is setup
with two secondary headnodes. Current TritonDC operator documentation suggests
that two CNs are used for HA instances of the core binder, manatee, and moray
services. This RFD suggests the following process to convert those CNs over to
being "secondary headnodes":

    sdcadm server headnode-setup $CN1   # convert CN1 to being a headnode
    sdcadm server headnode-setup $CN2   # convert CN2 to being a headnode

Part of headnode-setup is to ensure that components in the DC are of sufficient
version to support multiple headnodes. The headnode conversion will involve a
reboot (at least, to use the fs-joyent script that is involved in creating the
zones/usbkey dataset). The reboot could mean temporary service disruptions on
the order of what a manatee or binder instance upgrade can entail.

For starters, this will only support converting a *setup* CN to an HN.
Eventually this same command may support setting up a new *unsetup* server as a
headnode:

    sdcadm server headnode-setup $UNSETUP_CN


### Setting up HA instances

A DC "properly setup" for resiliency has setup a few services to be HA:
binder, manatee, moray.

    # TODO: note move to args rather than opt for servers in TOOLS-1977
    sdcadm post-setup ha-binder $HN0 $HN1 $HN2
    sdcadm post-setup ha-manatee -s $HN1,$HN2
    sdcadm create moray -s $HN1,$HN2

TODO: It would be nice to update these commands to *default* to using the
set of headnodes on which to deploy so that these would become the following.
This has somewhat been started in TOOLS-1977.

    sdcadm post-setup ha-binder
    sdcadm post-setup ha-manatee
    sdcadm post-setup ha-moray

TODO: Minimal HA services might be expanded to include the dhcpd service.


### Decommissioning a headnode server

Occassionally one needs to decommission a headnode server or, relatedly,
perhaps take it down for long term maintenance. The proposed way of doing this
is to run the following command(s) to move all core Triton services to another
headnode, leaving the one needing maintenance empty:

    sdcadm service migrate $HN0 $HN1 [--all | SERVICE ...]

For example, to migrate all services from the initial headnode (hostname
"headnode0") to a secondary headnode (hostname "3WGMXQ1"):

    sdcadm service migrate headnode0 3WGMXQ1 --all

This would do a controlled "move" of services on "headnode0" to headnode
"3WGMXQ1". "Move" is quoted because, *new* instances are created and the old
instances destroyed, as opposed to existing "VM migration" scripts which move a
VM dataset and maintain VM UUID, nics, etc. See the [Why new zones instead of
migrating same UUID?](#why-new-zones-instead-of-migrating-same-uuid) section in
the appendix.

`sdcadm service migrate ...` assumes that the provisioning stack is operational.
If it is broken, then either the operator needs to fix existing instances
that are broken or consider using [`sdcadm service
restore`](#headnode-recovery-process).

Note that service migration will avoid having multiple instances of the same
service on the same HN. For example, if there is already a manatee on this HN,
then another will not be created. It is expected that the operator may have to
re-establish three HA instances of binder, manatee, and moray via the following
on some new server.

    sdcadm server headnode-setup $SERVER
    sdcadm post-setup ha-binder $HN1 $HN2 $SERVER
    sdcadm post-setup ha-manatee -s $SERVER
    sdcadm create moray -s $SERVER

An alternative is to use a *new server* as the replacement headnode, leaving
the existing secondary headnodes alone:

    sdcadm server headnode-setup $NEW_SERVER
    sdcadm service migrate headnode0 $NEW_SERVER --all
    # decommission headnode0


### Headnode recovery process

A headnode has just died and it was running single-instance services. This
section describes how the operator is expected to recover things.

    ssh $SECONDARY_HEADNODE
    sdcadm service restore

This will walk through recovering all required Triton DataCenter core instances
on this server. On success, the DC should be fully operational. However
the final state may be HA clusters of binder, manatee, and moray that only have
*two* instances -- less than the required three. It is expected that the
operator follow up relatively soon with an additional headnode:

    sdcadm server headnode-setup $SERVER

and re-establishing three HA instances of those services:

    sdcadm post-setup ha-binder $HN1 $HN2 $SERVER
    sdcadm post-setup ha-manatee -s $SERVER
    sdcadm create moray -s $SERVER


TODO: What happens if 'recover' is run, and then the original headnode
comes back up? Can we explicitly ensure that services on all other servers don't
start talking to the "deposed" server's instances again? Should a booting
primary headnode go "deposed" if it sees another primary? Should cn-agent do
that? What is the mechanism for seeing other primaries? Presumably from CNAPI
talking to manatee (because manatee is the authority). Basically I think this
should be at the service level. HA services should behave fine if the deposed
primary comes back to life. Requiring a new version of all services for this is
quite a bit. I suppose the sdcadm service could stop VMs on a deposed headnode
if it can detect.


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
(the one with the only "dhcpd" zone) is dead.

From discussion at YVR office:

- TODO: should be fine for CN boots, but test it (per joshw)

- TODO: Need to fix cache warming, because with multiple booters it could be
  a bigger potential issue. Also don't want to rely on not having a
  warmed cache for the failure scenario.

- TODO: fix dhcpd's sapi manifest to use `{auto.ADMIN_IP}` I think it is called:

        sdc-booter/sapi_manifests/dhcpd/template
        32:  "serverIp": "{{{dhcpd_admin_ip}}}",

    rather than `dhcpd_dmin_ip`, because we want it to use its *own* IP, not
    the obsolete hardcoded first `dhcpd0` zone IP on the first headnode.


### sapi

With SAPI-294 and TOOLS-1896 we have broken SAPI's circular dep on config-agent
so updating it is now easy. I *think* SAPI should be HA'able now. TODO: verify
this.



### ufds

This zone should be easy, I hope. I *do* recall some experience with UFDS
zone setup being failure prone if part of the stack is down.

TODO: Wassup with possible ufds-replicator on new IP?

TODO: We'd want docs about possible need to update FW rules to allow replication
to continue. Or perhaps the "migrate/restore" command could warn/wait/fail
on ufds-replicator trying and failing.

TODO: amon alarm for ufds-replication failing and/or falling behind, or if
dropping amon usage for core, then artedi metrics for this and perhaps
`sdcadm status` could report.


### sdc

TODO: Work through how either HA sdc could work (coordinating which one runs
hermes, hourly data dumps, etc.) or issues with migration/recovery of the sdc
zone on the primary (FW rules to allow napi-ufds-watcher access, sdc key
sharing via delegate dataset or separate sdc key for each sdc zone, etc.).

Note: CM-753 for sdc key rotation, TOOLS-1607 for sdc key changes to just
be in the sdc zone(s).


## Milestones

The milestones on the way to completing the work for this RFD.


### M0: secondary headnodes

This milestone is about providing the tooling and support for having multiple
headnodes in a DC. Secondary headnodes will be where we backup data for services
that aren't otherwise HA. The natural choice of servers for secondary headnodes
are the CNs already used to hold the HA instances of manatee, binder, and moray.
The eventual suggested/blessed DC setup will then be:

    Server "headnode0"
        Instance "binder0"
        Instance "manatee0"
        Instance "moray0"
        Instance "sapi0"
        Instance "imgapi0"
        ...
    Server "headnode1"
        Instance "binder1"
        Instance "manatee1"
        Instance "moray1"
        (possibly instances of other HA-capable core services)
    Server "headnode2"
        Instance "binder2"
        Instance "manatee2"
        Instance "moray2"
        (possibly instances of other HA-capable core services)

- Ensure the system can handle multiple headnodes.
- Ensure the system isn't dependent on the headnode hostname being exactly
  "headnode".
- Tooling and docs to convert a CN to a secondary headnode: i.e.
  `sdcadm server headnode-setup ...`.
- Perhaps change headnode setup to take a hostname for the headnode other than
  the current hardcoded "headnode".
- Whatever syncing or data backup between headnodes that is required.


#### headnode USB key image

Here is what I think the minimal required data is for the USB key on a server
we will be booting up to be a headnode. A tarball of this data will be
created by `sdcadm server headnode-setup` and placed at
"/usbkey/extra/headnode-prepare/usbkey-base.tgz" to be used by the CN for
seeding its USB key.

```
.joyliveusb             marker file that this is the headnode bootable USB key
boot/...                boot files
boot/networking.json    generated from hn-netfile
config                  manually generated (see discussion below)
config.inc/...          files used by headnode.sh
license                 Including it, but I assume it isn't used by code.
os/...                  Same set as HN usbkey, but try to pull from usbkey
                        copy for speed.
scripts/...             holds headnode.sh and other scripts used at boot and after
sdcadm-install.sh       Yes, but same version as *deployed* currently rather
                        than the possibly out of date version on the HN USB key.
tools.tar.gz            Used by headnode.sh to install GZ tools.
cn_tools.tar.gz         Used by headnode.sh to setup for this HN setting up CNs.
```

Bits that I'm not sure if are needed, or will be if/when we drop the "CN must
already be setup" limitation:

```
banner
firmware/...            Not sure how used. Leaving this out for now.
ur-scripts/...          This is the agents shar.
```

Other common USB key bits that we don't need:

```
TODO fill this out
```

#### TODO

XXX

- sdcadm server headnode-setup:
    - need to pass *local* assets IP to the headnode-prepare.sh script because
      it is only *this* headnode that has setup /usbkey/extra/headnode-prepare

        See cnapi server-setup.js running agentsetup.sh that passes assets-url via env:
            function executeAgentSetupScript(job, callback) {
                var urUrl = '/servers/' + job.params.server_uuid + '/execute';
                var cnapiUrl = job.params.cnapi_url;
                var assetsUrl = job.params.assets_url;
                var cnapi = restify.createJsonClient({ url: cnapiUrl});

                var script = [
                    '#!/bin/bash',
                    'set -o xtrace',
                    'cd /var/tmp',
                    'echo ASSETS_URL = $ASSETS_URL',
                    './agentsetup.sh'
                ].join('\n');

                var payload = {
                    script: script,
                    env: { ASSETS_URL: assetsUrl }
                };

                cnapi.post(urUrl, payload, function (error, req, res) {
                    if (error) {
                        job.log.info('Error executing agent setup via CNAPI:'
                            + error.message);
                        job.log.info(error.stack.toString());
                        callback(error);
                        return;
                    }
                    callback();
                });
            }
        Can use args too (I prefer that).

    - Use cnapi.serverExecute rather than Ur directly.
      Will that work because it is sync? I don't know about timeouts.
    - trim USB key cruft from update_usbkey_extra_headnode_prepare, we need less
    - on reboot and after headnode.sh runs we don't have:
        /usbkey/extra/{agents,dockerlogger}
      Is this a headnode.sh bug?
        - also missing this mount:
            /lib/sdc/docker/logger on /opt/smartdc/docker/bin/dockerlogger read only/setuid/devices/dev=169000f on Mon Sep 11 06:32:17 2017
          headnode.sh issue? or elsewhere?
    - get headnode-prepare.sh into sdc-headnode.git where it belongs
        - then ensure we can updated it with SdcAdm.updateGzTools
          (it should be updated in /mnt/usbkey/scripts already, need to add
          similar to copyAgentSetup to create /usbkey/extra/headnode-prepare)
    - 'sdcadm' install changes to install the shar, if can, to /var/sdcadm
      somewhere, and update update_usbkey_extra_headnode_prepare to use it
    - move ProcHeadnodeSetup to procedures/

- move this to M3 TODOs:
    - setup sync'ing required for 'sdcadm service migration/restore'
        This is the "restore-data" thing mentioned in the Overview.

- other 'headnode resiliency setup':

    - reserving IPs for replacement insts (does this require VM uuids?)
    - creating starter instances on those new headnodes: dhcpd

    Are these steps part of the headnode-setup? Or separate?

- A replaced my COAL primary headnode, keeping an older secondary CN running
  an older platform. The result was:

    ```
    [root@headnode0 (coal hn) ~]# sdcadm server ls
    HOSTNAME   UUID                                  STATUS   FLAGS  ADMIN IP
    cn2        564dc847-1949-276a-8eb3-8d3a1df000ca  running  SHB    10.99.99.45
    headnode0  564dd1ac-164d-cc50-247c-b2eb0cf21ce5  running  SH     10.99.99.7
    ```

  The "B" flag is that boot_platform differs from current_platform:

    ```
    [root@headnode0 (coal hn) ~]# sdc-cnapi /servers/564dc847-1949-276a-8eb3-8d3a1df000ca | grep platform
      "boot_platform": "20170911T231447Z",
      "current_platform": "20170828T221743Z",
    ```

  Why is that? How is "boot_platform" set for a new headnode server record?
  Is it just some sense of "default" boot platform in CNAPI?
  Anyway this isn't a big issue. "boot_platform" for headnode is only relevant
  if it boots as a CN.

- A secondary headnode: Does it do the right thing with rabbitmq? Or does it
  assume that rabbit will be local or not at all?  Perhaps usbkey/config
  is being used via /lib/sdc/config.sh ?

- Nice to have: The "usbkey/config" file for the secondary headnode *should*
  require a lot less than that on the initial headnode. It would be nice to
  limit it to the minimal set -- taking the opportunity to feel out removing
  cruft that has accumulated there. We shall see if that effort is worth
  validating that some config is truly obsolete.
  Note: Would be really nice to cycle on this *earlier*, as soon as we have
  'sdcadm server headnode-setup' automated for quicker cycling.


### M1: Controlled decommissioning of a headnode

Basically this is support for `sdcadm service migrate ...` such that we can
fully evacuate a headnode with minimal service downtime.

The ideal is to be able to do the following in nightly-1:

- Full regular setup (perhaps with the hostname not hardcoded to "headnode")
  with two secondary headnodes setup.
- Optionally have a "tlive" tool a la `mlive` for watching service availability
  and health over a period of time.
- Move all service instances off headnode0 onto one of the secondary HNs while
  watching `tlive`. Measure what the downtime is for: cloudapi, internal
  services, data path (if any).
- Full nightly-1 test suite run (including testing the nightly-1 Manta).


#### TODO

- easy first one: sdcadm service migrate headnode0 cn2 vmapi
    - Then test can boot the HN and CN independently, etc.
    - Watch log.errors on all services? Or is that too noisy? Would be nice
      to get others to get those log.error's down to nothing as part of
      normal.
    See scratch section below.
- next: cloudapi to test delegate dataset

- ...

- getting test suites to work even if inst is on another HN


#### scratch


    ssh headnode0   # shouldn't matter which one
    sdcadm service migrate headnode0 cn2 vmapi
    sdcadm service migrate headnode0 cn2 --all


Moved vmapi to cn2 with:

    sdcadm create -s cn2 vmapi --dev-allow-multiple-instances


##### appendix: how to migrate

- TODO: move this to an appendix about how to handle min-downtime migration
- TODO: get discussion and review from others on it

What is vmapi *migrate*?

For *migration* we assume the stack is up. If not, then we are *restoring* and
that's different... possibly with slightly less correctness (up to date data
for, e.g., selecting alias).

- Take 1 (no new support for APIs required):
    - put DC in maint mode
    - create the new instance on target HN
    - (hope that there aren't integrity issues with having 2 insts for a short while)
      TODO: quick eval of each repo for whether there could be issues with
      2 running. If so, then might want different procedure for those where
      the old inst is down before the new one is brought up. This requires
      the ability to SAPI CreateInstance this instance without that service
      itself.
    - destroy the old instance on the source HN
    - take DC out of maint mode

- Take 2 (cutesy proxying):
    - Bring up new inst on target HN (assuming here a svc that can handling having
      multiple unused insts; e.g. this excludes the 'sdc' zone for which there
      should only be one at a time) in "disabled" mode. "Disabled mode" means:
      an API functions but isn't in DNS; the "sdc" zone singleton work
      (cronjobs, hermes) is off.
    - Put the old inst in "proxy mode" where it quiesces and proxies all new
      requests to the new insts' IP. (Q: Is this easily possible?)
    - Put the new inst in DNS, then take the old one out of DNS.
    - Quiesce the old inst and then shut it down.
    * * *
    - Q: work for vmapi (simple)?
    - Q: work for cloudapi (simple, delegate dataset)?
    - Q: work for sdc (crontabs, hermes, possible IP whitelisting to Manta)?
    - Q: work for ufds (possible IP whitelisting to master UFDS)?
    - Q: work for imgapi (large delegate dataset)?

Might prefer take 1 because KISS. The *right* answer is for each service to
get to being HA. Better to spend time on that, than on cutesy "proxy mode".


##### appendix: push or pull for svc-restore-data?

TODO: move this to an appendix, conclusion "pull", update with reasons above
Q: Restore data syncing, push or pull?
Pull pros:
- If restoring on a running HN, we can know when we last pulled and if
  successful. I suppose we should be able to tell that with dropped status
  files from pushers, but that's more work?
- Cleanup when insts disappears seems easier with *pull*.
- If we want smarter layout under /var/sdcadm/service-restore-data/... then
  there needs to be a single manager of writes to that area. That argues for
  *pull*.
Push pros:
- If we 'sdcadm up vmapi' on a HN, we can know *right then* to push the updated
  image to the remote HNs and make that push part of commiting the update.
  We can also just poke every sdcadm-agent to update, then they pull.


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


#### TODO

- finish off sync-restore-data.sh work into functioning sdcadm-agent and
  'sdcadm service sync-restore-data' hidden command


#### scratch

##### svc-restore-data

    sdcadm service sync-restore-data
        Hidden command, code in lib/service.js or whatever. Used by 'migrate'
        for each service to ensure have latest bits.... I guess it could be
        a proc then. Used by the bg task that is syncing these every 5m.

            lib_service.listServices(...)
            lib_service.syncRestoreData({
                targetHeadnodes: [array of target servers]
            }, function (err) {...});

        This calls the "sync now" endpoint of the sdcadm-agent API on every
        CN to have them pull. Those all send progress packets (JSON objects)
        with which we show progress.

sdcadm-agent:
- listens on well-known port with an API, a la amon-relay
- takes requests to kick off a svc-restore-data sync for a given service name
- if cannot contact a HN sdcadm-agent for sync'ing then note that for
  'sdcadm status' (eventually an amon alarm for this)
- also takes over the current sdcadm-setup service duties (logadm, anything else?)
- Q: what cleans out svc-restore-data when insts are removed? This argues
  for *pull*.
- does this svc-restore-data sync every 5m


sync-restore-data.sh prototype
    Done:
        /var/sdcadm/svc-restore-data/
            svc-vmapi/
                sapi-insts.json
                vm-$uuid0.json
                    XXX vmapi dump doesn't have, e.g. 'archive_on_delete'
                    Q: what else it is missing from 'vmadm get ...'?
                    TODO: discuss with  joshw
                ...
            images/
                ... db of images here. Clean up is harder, but that is fine.
    TODO: add dump of sapi-app.json and sapi-svc.json to give option to debug
        or construct VM payload from that data.
    TODO: delegate datasets (e.g. cloudapi)

##### restore notes

A *restore* of vmapi is:
- alias: How to determine alias? Possible to have same way as for
  restore?

  We have a periodic dump of the SAPI 'sdc' app data, so we can see all the
  vmapi insts and pick a free alias -- assuming the data isn't split brain.

  TODO: sdcadm status and/or amon alarms for splitbrain data and truing up.
  Perhaps require that to be clean for 'sdcadm up' runs? Add warnings to
  the output of 'sdcadm insts'?

- image: from somewhere in svc-restore-data
- payload: TODO: work out steps from the info we have (perhaps look back at logs
  for the manual experience?). Do we just use SAPI info? Or do we also look at
  instance (also VMAPI obj and 'vmadm get' obj differ!)?
  XXX Do we *use* SAPI CreateInstance if we are after SAPI? No... that doesn't
      work for VMAPI, duh. But need to update SAPI instances after.
- Chose IP how? Is NAPI down? Possibly, so need that IP info in
  svc-restore-data.
    TODO: talk with cody about plan here to reserve IPs on admin for core
    zones. What about public ones? re-use those ones? Might prefer to. Then,
    e.g. 'tlive' would still work without need to update LBs, DNS, configs.
    What about stealing IP for admin network too? We shouldn't have both
    running at the same time... because by def'n they aren't ready for that.
- TODO: what about updating ips in settings everywhere? And ensuring clients
  reconnect properly (they will be expected to).

Re-try: What is vmapi restore procedure?
- pick alias from vm-*.json -> vmapi1
- image: if not already installed on target HN, reverse install origin chain
  from svc-restore-data/images/...
- payload: 2 options
    1. from vm.json dump (from VMAPI or vmadm get)
    2. from SAPI data:
        Q: Does SAPI CreateInstance hardcode to customer_metadata?
        Somewhat. It cherry-picks a few vars from svc.metadata
        (and inst.metadata too?) + unholy special 'pass_vmapi_metadata_keys'
        handling for nat zones. Hopefully we can ignore the latter.
    XXX

##### admin ips

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

##### restore process

Feeling out the restoration process.

- Expected services to have up and running:
    manatee
    moray
    binder
    dhcpd (NEW)
- assets
- sapi: Need to break sapi's silly circular dep on config-agent.
- amonredis: Why this here? Is this following headnode.sh order?
- ufds
  - TODO: We'd want docs about possible need to update FW rules to allow
    replication to continue.
  - TODO: amon alarm for ufds-replication failing and/or falling behind.
- workflow
- amon
- sdc
  - Q: Consider doing the sdc key change thing (there is a ticket I think) to
    (a) not have the sdc priv key in SAPI data and (b) to support rotation of
    it. If not in SAPI we'd need to have that in a delegate dataset and
    carry that.
  - TODO: We'd want docs about possible need to update FW rules to allow
    replication to continue.
- papi
- napi
- rabbitmq
- imgapi
- cnapi: easy?
- fwapi: easy?
- vmapi: easy?
- ca: easy?
- mahi: easy?
- adminui: easy?
- cloudapi?
- cns?
- docker?
- cmon?
- portolan? Kinda expect this one to be HA already.
- ... then other zones that were on that HN and aren't here:
    - manatee?
    - moray?
    - binder?
    - dhcpd?
    - TODO: recover should warn about other zones that existed but were not
      recovered (e.g. portal, sdcsso)


### M3: Surviving the dead headnode coming back

What happens to the system if we've recovered from a dead headnode, and
then it boots back up with the older instances?

TODO: how do we guard against issues here?

Idea: could have each service instance call SAPI to see if they are a valid
instance, else don't engage. Not sure we want SAPI being down to mean everything
fails to start. We could have these fail "open", i.e. if no SAPI, then they
come up.


## Scratch

Trent's scratch area for impl. notes


### Separable work

These need to be fleshed out, ticketed, assigned.

- [HEAD-2207] booter warm cache work
- HA booter (because required for data path rebooting of CNs while
  HN is down): see about fair load balancing if multiple CNs are
  booting (round robin? have a given booter delay by N*100ms on DHCPD responses
  if already booting N CNs?)
- breaking SAPI's circular dep on config-agent
  Currently SAPI is first setup in proto mode and requires headnode.sh
  dorking into it later to get its config-agent going and then changing
  SAPI to full mode. SAPI zone update requires creating a sapi0tmp zone,
  updating sapi0 to the new image, and then deleting the sapi0tmp zone.
  We need to be able to setup a SAPI instance while there are
  no SAPI zones running. If, while designing this, it is easier to just
  require multiple SAPI zones (one on each HN) and ensure HA SAPI works,
  then we could consider that. However, for COAL and non-HA TritonDC
  deployments it would be nice to have SAPI be able to be updated
  without requiring sapi0tmp.
  There was some discussion on config-agent changes to look at
  being able to do all configuration using VM metadata, so that all
  data required for a zone boot is on the CN itself. There is likely
  significant work for that, so not sure of practically.
- doc'ing all the CNAPI server object fields (start a ticket with my
  starter notes)
- doc'ing all the USB key layout (perhaps in a docs/index.md in
  sdc-headnode.git?). Also document if/how/what each of those is
  updated, and how they relay to the USB key "copy" at /usbkey/...
  (e.g. /usbkey/os can contain more plats than on the physical USB key).


### TODOs

See also the TODOs in each milestone section, and any "TODO" or "Q" in this doc.
This section is a general list of things to not forget.

- recovery of a manta-deployment zone: is this a concern? is there potential
  data loss there? or is all the data in SAPI?

- `rg 'headnode=true'` has a lot of hits. WARNING: incomplete list:
  - phonehome from every headnode every day, is that a problem? Might
    actually be a good thing.
  - sdc-headnode/tools/bin/sdc-healthcheck
  - sdc-headnode/tools/bin/sdc-sbcreate
  - node.config different paths, too much to hope to drop node.config?
      /opt/smartdc/config/node.config
      /var/tmp/node.config/node.config
  - sdcadm/lib/sdcadm.js  Something around CN setup I think.
  - smartos-live/...
  - ...

- do our CNs sync ntp from the headnode? if so, there are implications there
  for headnode resiliency

- Update 'sdcadm post-setup cloudapi|docker|volapi|...' to not assume the
  first "cnapi.listServers({headnode:true})" is the server they can use
  for the first instance. Perhaps they should provision on the server on
  which this sdcadm is running? or on the same server that hosts the 'sdc'
  zone? and/or provide a -s/--server SERVER option to specify.
  [TOOLS-1930](https://smartos.org/bugview/TOOLS-1930)

- /lib/sdc/config.sh currently prefers:
    /usbkey/config, /mnt/usbkey/config, /opt/smartdc/config/node.config
  If you are on a CN and /mnt/usbkey/config is there (and mounted) but not
  valid, then you get problems (e.g. with agent setup). Would be nice
  to have it only use the usbkey values on a headnode=true. TODO: bug for it

- Ensure fabrics setup works *after* having multiple headnodes. E.g. adding
  networking.json must be on all headnodes.

- perhaps pick up OS-5889 (fix identity-node comment or impl)

- sdc-healthcheck for cnapi needs to change to support multiple headnodes
    cnapi)
      local got_name=`sdc-cnapi /servers?headnode=true 2>/dev/null | \
          json -H -a hostname`
      [[ "$got_name" == "$(hostname)" ]] && return
      ;;
  I have the changes ready.

- Note for COAL testing: We could have the restore-data going to the local HN as
  well. Then it is usable for (a) COAL testing locally and (b) for local
  recovery of a blown away core zone. E.g. for zpool corruption as on east3b or
  just an accident.

- Get sdcadm (and possibly other gz-tools) on to the other headnodes (perhaps
  part of the "setup as a headnode"). Ensure the 'sdcadm up gz-tools' will
  install on other headnodes.  Consider dropping the diff btwn cn-tools
  and gz-tools (make headnodes less special).
  Note: 'sdcadm experimental update-gz-tools' handles updating cn_tools on
  all CNs.

- after a headnode decommission or death, part of finalizing should be cleaning
  up assigned IPs and NICs in NAPI.
  E.g. see https://github.com/pannon/sdc/blob/master/docs/operator-guide/headnode-migration.md#fixing-napi-entries

- Continue on triton-operator-tools so that we can have `sdc-*` tools in GZ
  without sdc zone? This might be optional.

- Should 'sdcadm server ls' we have 'status' smarts if setting up? See
  sdc-server list.

- 'sdcadm ...' should warn/error if there are >1 insts of a service
  that doesn't support that.

- How does being a UFDS master or slave affect things here?

- sdc-oneachnode:
    - Let people know that '-c' is now not "all other nodes" because some of
      those are headnodes.
    - Consider adding '-H, --headnodes' to run only on headnodes.
    - Consider favouring '--computenodes' over '--computeonly'.

- sdcadm: `sdcadm self-update` to update on all HNs

- sdcadm: 'sdcadm platform install' to install to all usbkeys
    - Perhaps deal with problems of having lots of OSes on usbkeys if
      separate platform versions on separate HNs. Perhaps only subset specific
      to that HN live on that HN's USB key?

- Consider a ticket to have /mnt/usbkey -> /usbkey rsync'ing exclude all but
  those parts that a relevant. E.g. /usbkey/application.json isn't needed.
  /usbkey/os is needed. Etc.

- Ticket to drop 'assets-ip' metadata var. I don't think anything uses it.

- Ticket to drop 'dhcpd_domain' (no one uses it) from config, and stop using
  registrar in dhcpd zones, because nothing uses or should need to lookup
  dhcpd zones in DNS.

- setup file (/var/lib/setup.json) has node_type=headnode|computenode.
    Why? Does this matter. Pretty sure not -- these are the only hits:
        $ rg -w node_type | grep -v javascriptlint | grep -v uglify-js | grep -v illumos-joyent/usr/src | grep -v deps/node | grep -v node_modules/sprintf | grep -v sdcboot/ | grep -v www/js/lib/underscore.string.js
        sdc-headnode/scripts/joysetup.sh:        echo "{ \"node_type\": \"$TYPE\", " \
        smartos-live/overlay/generic/lib/svc/method/smartdc-init:	"\"node_type\": \"computenode\"," \
    TODO: a separate HEAD-??? ticket to remove node_type

### Code

Integrated to master:

- sdc-headnode.git comitted to master
    - HEAD-2343 allow headnode setup to work on a CN being converted to a
      headnode requires gz-tools builds after 20170118
    - HEAD-2367, HEAD-2368 sdc-login improvements to help with running
      test suites with multiple headnodes
    - HEAD-2370 add bin/rsync-to
    - HEAD-2380, HEAD-2383: 'sdc-usbkey mount --nofoldcase'
- sdc-booter.git
    - NET-371 (builds on or after: master-20170518T212529Z)
    - NET-376 (commit 554cb97, builds on or after:
      master-20170907T183323Z-g554cb97)
- smartos-live.git
    - OS-6160
        - fs-joyent (method for filesystem/smartdc SMF service) update to work
          properly for first boot of a CN being converted to a HN. It needs to
          cope with the zones/usbkey dataset not yet existing (that comes later
          when smartdc/init runs headnode.sh for the first time on this server).
        - builds on or after 20170830 (release-20170831)
- sdc-vmapi.git
    - ZAPI-800 Update provision workflow to not assume a single headnode

In CR:

- sdc-booter:
    - TRITON-29  This needs some discussion to solve the "admin on aggrs"
      issue in east3b.

Trent's WiP:

- smartos-live.git branch "rfd67" (g live)
    - root ~/.bashrc has "hn" PS1 marker on HNs
      workaround if don't have latest "rfd67"-branch platform build:
        g live
        scp overlay/generic/root/.bashrc coal:/root/.bashrc
        scp overlay/generic/root/.bashrc cn0:/root/.bashrc
    - /lib/sdc/config.sh changes to only consider [/mnt]/usbkey/config on HNs
      and /opt/smartdc/config/node.config on CNs. This also then no longer
      warns about lingering /opt/smartdc/config/... on a CN.
        TODO: some testing to get comfort this doesn't break setting up HNs or CNs
- sdcadm.git branch "rfd67" (g sa)
    - ready to go to master
        - logToFile improvements
            TODO: get this to master
        - Procedure.viable  (XXX lost this?)
            TODO: move this to master?
    - done, but stays in rfd67:
        - `sdcadm server list`
        - `sdcadm service ls` (new home for `sdcadm services`, aliased)
            Should this change to newer form of "sdcadmService objects"?
    - WiP:
        - lib/common.js: Fixes for the usbKey mounting functions.
            TODO: update this to handle passing back the mount dir!
        - sdcadm to node v4
            See TODOs in scratch: urclient, wf-client releases. Put in master
            after release.
        - `sdcadm server headnode-setup`
    - on deck:
        - `sdcadm service migrate`
        - `sdcadm service restore`
- sdc-headnode.git branch "rfd67" (g head)
    - hostname=headnode0 in prompt-config default
      Will sit on this until all most ready. There is no great justification
      for "headnode0" default until we have RFD 67 mostly all working. And it
      is optional.




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


### 'sdcadm server' notes

From a discussion with some folks in YVR a while back, partly about
having `sdcadm server` taking over most duties from `sdc-server`, plus
possibly a `sdc-cnadm` replacement for lower-level stuff. Currently this
RFD only proposes implementing some of the `sdcadm server` commands shown
here.

The general argument is that some server management isn't *just* about talking
to CNAPI. That justifies putting it in `sdcadm server`. One example is
`sdcadm server delete ...` which also involves talking to SAPI to cleanup
zombie instances.

    sdcadm server list ...          # sdc-server list
    sdcadm server delete|rm ...     # sdc-server delete + SAPI inst cleanup
    sdcadm server get SERVER
    sdcadm server lookup FILTERS... # sdc-server lookup

    sdcadm server cn-setup UUID ...    # sdc-server setup
    sdcadm server headnode-setup UUID ...   # setup as a secondary headnode

    sdcadm server bootparams SERVER     # maybe

Not sure about 'sdcadm post-setup underlay-nics ...'
and 'sdc-server [update|replace|delete]-nictags'.

### Swapping CNS instances

There's no reason why you can't run two CNS instances at once, it's just that if you configure a BIND slave to follow both of them at once if can get confused and inconsistent.

We don't serve records directly from the CNS zone anyway, so bringing it down has only the impact that changes to DNS may be delayed, records continue to be served as normal. The data in the dataset is always safe to throw away, it'll just rebuild it again and the BINDs will have to do full AXFRs to catch up.

The BIND instances all have the IP of the CNS instance in their config, so if you decide to recreate it with a different IP, you will need to go configure them all.

The BIND instances need to be reconfigured upstream and have names like `cns[1-4].my.org.dns.com`

And don't forget to make sure the new one has the same firewall rules.
