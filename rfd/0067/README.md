---
authors: Trent Mick <trent.mick@joyent.com>
state: predraft
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

1. Vanilla first headnode setup for a new zone. This is the thing we already
   have.
2. The "blessed" recovery case. Recovery of a headnode when the DC has been
   following blessed suggestions. Namely that there is an HA cluster of all of:
   binder, manatee, moray, assets (new), dhcpd (new), and imgapi (new).
3. The "backup" recovery case. Recovery of a headnode from a *backup* of one or
   more of: manatee, imgapi, and the usbkey data (e.g. platforms, usbkey/config
   needed?); and not necessarily any binder/manatee/moray/assets/dhcpd/imgapi
   running zones to work with.
4. The "M6" case. Setup of a redundant headnode (or conversion of a CN to
   being another headnode). I.e. fully redundant headnodes (e.g. headnode0,
   headnode1, headnode2) such that loosing one of them to thermite doesn't
   result in any issues other than a temporary blip in services while failing
   instances are purged from working sets. This requires full HA for all
   services, which a matter bigger than just this RFD (read: out of scope).

This RFD will propose a plan for #2 and #3.


# Prior art

There are ancient `sdc-backup` and `sdc-recover` tools. Those are broken,
incomplete, and -- I hope -- not supported.

    [root@headnode (coal) ~]# sdc-backup
    logs at /tmp/backuplog.34881
    Backing up Manatee
    /opt/smartdc/bin/sdc-backup: line 77: sdc-manatee-stat: command not found


# Recovery process

For cases #2 and #3 the recovery process may go like this:

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


# M1: "blessed" recovery

TODO


# M2: "backup" recovery

Dev Note: A test for this is to `sdc-factoryreset` a COAL, select recovery mode
in the boot menu and see if one can fully recover the headnode.

TODO



# Trent's scratch notes

## TODO

Quick TODOs to not forget about:

- When an operator boots a new headnode, what happens if they don't catch the
  grub menu in time? That headnode could start a vanilla headnode setup (or any
  state in that process: prompt-config, partial setup that is interrupted). How
  can that cause damage to the existing setup? If the same IPs end up getting
  used then bits from the rest of the DC will talk to it... so there could be
  a lot of surprises.
- Wildcard: how does being a UFDS master or slave affect things here?

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
- platforms at usbkey/os
- Q: is there other info on the usbkey that we want/need to save?
