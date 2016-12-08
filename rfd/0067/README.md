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

# Overview

Four cases of headnode setup:

1. Vanilla first headnode setup for a new server. This is the thing we already
   have.
2. Essential services are HA, recovery on an unused server.
   In this case the DC has been setup in the full recommended config where there
   is an HA cluster of all the "essential" services: binder, manatee, moray,
   assets (new), dhcpd (new), and imgapi (new). And recovery is on an unused
   server (either a repaired and wiped original headnode, or a new unused
   server) which will become the headnode.
3. Essential services are HA, convert existing CN to a HN and recover on it.
   In this case the DC has been setup in the full recommended config
   where there is an HA cluster of all the "essential" services (as in #2).
   However, there isn't a spare unused server that can be used for headnode
   recovery, so the desire is to use an existing CN, potentially one of the
   CNs hosting some of the HA cluster components (e.g. binder1, manatee1,
   moray1). Obviously a third server will eventually be required to get back
   to an "HA essentials" blessed state, but that might be acceptable to quickly
   get back to an HA state.
4. Recovery of a headnode from a *backup* of one or more of the essentials
   and not necessarily any binder/manatee/moray/assets/dhcpd/imgapi running
   instances to work with.
5. Setup of a redundant headnode (or conversion of a CN to being another
   headnode). I.e. fully redundant headnodes (e.g. headnode0,
   headnode1, headnode2) such that loosing one of them to thermite doesn't
   result in any issues other than a temporary blip in services while failing
   instances are purged from working sets. This requires full HA for all
   services, which a matter bigger than just this RFD.


This RFD will propose a plan primarily for #3. Cases #2 and #4 will likely also
be discussed, but are a lower priority. Case #5 is out of scope.

TODO: Re-number these things, add a #2 for headnode replacement. I.e. controlled
EOL'ing of a headnode server by moving headnode to another. The test there
is nightly-1 being able to swap headnode back and forth between servers. Call
this M1.


# Prior art

There are ancient `sdc-backup` and `sdc-recover` tools (and related "backup"
and "recover" scripts in "$repo/boot/" for some of the core service Triton
repositories). Those are broken, incomplete, and -- I hope -- not supported.

    [root@headnode (coal) ~]# sdc-backup
    logs at /tmp/backuplog.34881
    Backing up Manatee
    /opt/smartdc/bin/sdc-backup: line 77: sdc-manatee-stat: command not found


# Recovery process

For cases #2 and #4 where a new unused server is used, the recovery process may
go like this:

- You boot your new headnode and select a new "Headnode recovery" mode.
  This passes recovery=true bootparams to headnode.sh (or whatever).
- "headnode.sh" will then use available information ('config' on the usbkey?
  or perhaps another recovery file we start writing to the usbkey?) to attempt
  to find running and healthy clusters of binder, manatee, moray, imgapi, etc.
  If all "blessed" conditions are met, then it automatically runs
  'sdcadm recover ...' with this data to have it recover the headnode.
- If all the blessed conditions are *not* met, then:
    - It sets PS1 to indicate that the headnode isn't setup and needs recovery
      (see [HEAD-2165](https://devhub.joyent.com/jira/browse/HEAD-2165) for
      a throw back).
    - It sets motd with details that recovery needs to be run manually and
      how to run 'sdcadm recover'.
    - It stops setting up.
  At this point it is up to the operators to run 'sdcadm recover' with options
  pointing to the necessary backups.


For case #3 where a existing server (hosting some core instances) will take
on more instances, the recovery process may go like this:

- If this isn't already a secondary headnode, then convert it to being a
  headnode. There will need to be a new tool added to "cn-tools" that supports
  converting to a headnode (ensure a USB key, install headnode-specific GZ
  tools, sdcadm, etc.).
- Call `sdcadm recover` similar to above.


# imgapi

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

# sdcadm status

I'm consider implementing a `sdcadm status` as part of this work that will
give a report on current faults with the Triton setup:

- Is it in a blessed state with HA manatee, moray, etc.?
- Perhaps listing 'sdcadm check-health' faults.
- Listing `zonememstat -a` potential issues.

# dhcpd

Q: Do we make the dhcdp service HA? Without this, CNs would not be able to boot
while the headnode is dead.


# usbkey and assets

The usbkey holds the platforms that CNs use for netboot. Those are served
via the 'assets' zone. We will need to change the processing that add data
to the usbkey to update the keys on the "core" CNs (or some concept of
a backup target if don't have other "core" CNs). We will also need tooling
to check and sync. Some examples:

- adding a platform (via 'sdcadm platform install ...')
- changing usbkey/config (and the various split brain issues with this)
- other assets-zone-served files in the usbkey/extra dir: agentsshar, cn-tools
- usbkey copy (i.e. /usbkey)


# M1: "blessed" recovery

Dev Note: A target is to get nightly-1 to running in the "blessed" configuration
then `sdc-factoryreset` the headnode into recovery mode, recover, and verify
that we recovered correctly. This assumes the same hardware (same headnode
UUID), so ideally we'd next try stopping the headnode and attempting recovery
with a fourth, and otherwise unused, server.

TODO


# M2: "backup" recovery

Dev Note: A test for this is to `sdc-factoryreset` a COAL, select recovery mode
in the boot menu and see if one can fully recover the headnode.

TODO



# Appendices

## Open Questions

- Do we need to support case #3?
- Do we need to support case #4 on an existing CN (converting it to an HN
  and not restarting with a fresh zpool)?
- What about an easier case that just snapshots all the core zones and zfs sends
  those to external storage?
- Any "Q:" notes above.


## TODOs

Quick TODOs to not forget about:

- When an operator boots a new headnode, what happens if they don't catch the
  grub menu in time? That headnode could start a vanilla headnode setup (or any
  state in that process: prompt-config, partial setup that is interrupted). How
  can that cause damage to the existing setup? If the same IPs end up getting
  used then bits from the rest of the DC will talk to it... so there could be
  surprises.

  The main thing we want to avoid here is the vanilla headnode setup polluting
  the clusters to which we want to attach with a proper recovery. We know from
  nightly-1 experience that agents and the manatee cluster from the pre-existing
  CNs will interfere with the vanilla headnode setup: see RELENG-532 and
  RELENG-602

- As part of moving to a future "no headnode is special" world, we
  may attempt to start using "headnode<num>" for the hostname for headnodes
  (e.g. headnode0, headnode1).

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
