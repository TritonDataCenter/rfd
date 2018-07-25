---
authors: Brian Bennett <brian.bennett@joyent.com>, Todd Whiteman
state: predraft
---

# RFD 34 Instance migration

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Introduction](#introduction)
- [Types of Migration](#types-of-migration)
  - [Live Migration](#live-migration)
  - [Offline migration](#offline-migration)
  - [Semi-live migration](#semi-live-migration)
- [The state of migration in SmartOS](#the-state-of-migration-in-smartos)
- [The state of migration in Triton](#the-state-of-migration-in-triton)
- [A vision for the future](#a-vision-for-the-future)
- [High Level Implementation Overview](#high-level-implementation-overview)
  - [Offline migration implementation](#offline-migration-implementation)
  - [Semi-live migration implementation](#semi-live-migration-implementation)
- [Milestones](#milestones)
  - [M1: Check vmadm send/receive](#m1-check-vmadm-sendreceive)
  - [M2: Update vmadm send/receive](#m2-update-vmadm-sendreceive)
  - [M3: Update DAPI (CN provisioning/reservation)](#m3-update-dapi-cn-provisioningreservation)
  - [M4: Update CNAPI](#m4-update-cnapi)
  - [M5: Create sdc-migrate tooling](#m5-create-sdc-migrate-tooling)
  - [M6: End user migration](#m6-end-user-migration)
  - [M7: Migration estimate](#m7-migration-estimate)
  - [M8: Add support for semi-live migration](#m8-add-support-for-semi-live-migration)
- [Open Questions and TODOs](#open-questions-and-todos)
  - [Backups](#backups)
  - [Images](#images)
  - [Provisioning](#provisioning)
  - [Networking](#networking)
  - [Progress](#progress)
  - [Other](#other)
- [Caveats](#caveats)
- [Tests](#tests)
- [References](#references)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Introduction

Migration of instances is a common feature among virtualization platforms. SmartDataCenter is a notable exception. Among public clouds, instance replacement is generally preferred to instance migration.

Nevertheless, at times it has been necessary to migrate instances within the Triton Cloud between compute nodes.

# Types of Migration

There are three types of migration.

- Live migration
- Offline migration
- Semi-live (incremental) migration

## Live Migration

This is when an instance compute task is transferred between physical compute nodes. This is generally done using shared storage, requiring only the memory state and execution context to be synchronized leveraging instance "pausing" to briefly quiesce the instance before resuming on the destination compute node. Due to design choices (vis. the exclusion of shared storage) in SDC, and the nature of OS virtualization in SmartOS (containers, not virtual machines*) live migration is not considered for implementation at this time.

\* Even KVM instances are qemu in a *container*.

## Offline migration

Where an instance is stopped completely (i.e., the guest performs a shutdown procedure), the dataset backing the storage for the instance is synced, and the instance is booted on the destination compute node. Offline migration is the most straightforward type of migration and works in almost any circumstance, but has the disadvantage that the instance will be down for the entire time it takes to transfer the storage dataset.

## Semi-live migration

Occurs when the dataset backing the storage for the instance is synced while the instance is running. Once the dataset is within an acceptable delta on both the source and destination compute node the instance is stopped, a final sync is performed, and the instance is booted on the destination compute node. This allows for both dedicates storage and significantly reduced down time (though, still not as little as live migration).

Semi-live migration is preferred with SmartOS in general and Triton in particular.

# The state of migration in SmartOS

ZFS has well known send/receive capabilities. The ability to snapshot a dataset and send incremental datasets makes syncing ZVOLs between compute nodes easy. Similarly, vmadm has undocumented send/receive subcommands that, in addition to performing zfs send, will send the zone metadata. Due to a design decision with the implementation of KVM zones, vmadm send does not support KVM. Migrations can fail when the dataset size is too close to the quota.

# The state of migration in Triton

While vmadm does have the beginning of a migration feature, migrations are not supported in Triton. Out of necessity, some shell scripts have been written that are capable of migrating instances. This is a road fraught with danger, however. On several occasions changes to the Triton stack have rendered the migration script inoperable or worse, dangerous (i.e., incurring data loss).

# A vision for the future

The following is a description of how instance migration might work.

Instance migration should be a first-class supported feature in Triton. This would be comprised of API calls that trigger a workflow to perform the migration unattended. Migrations could be performed on demand, or scheduled. AdminUI would also provide an interface for migrating an instance. Instance migration should use regular DAPI workflows for selecting the destination compute node, or could be specified by an operator to override DAPI selection.

Product messaging via CloudAPI and/or the user portal would notify customers of upcoming scheduled migration, and at their option choose to migrate ahead of the predefined schedule.

# High Level Implementation Overview

Migration will make use of existing provisioning and placement APIs (e.g. CNAPI)
to ensure compatibility with the regular instance creation workflows. This is
so the created instance will be placed on the correct server and that all of the
same services are available (e.g. CNS, Volumes, Networks, etc...) without having
to duplicate the creation of these services.

The migrating instance will be marked with a "migrating" vm state to ensure no
other operations (e.g. "start", "stop", "reprovision") can occur on the instance
whilst the migration is ongoing (including another migration attempt).

It will be possible to manually stop/abort a migration, though it may take some
time before the migration process can be safely interrupted and before the
instance can return to it's previous state.

## Offline migration implementation

1. CNAPI /servers/:server_uuid/vms/:uuid/migrate endpoint will start the
   migration process for this (source) instance by acquiring a ticket/lock on
   the instance and then changing the instance state to "migrating".
2. DAPI will be used to provision a new (target) instance with the same set of
   provisioning parameters (you can think of this as an instance reservation) on
   a different CN (the target CN). Keep the same uuid but flag it as
   'do_not_inventory' to ensure that no systems know/use it yet. This step
   should install the necessary source images on the target CN and/or setup
   necessary supporting zones (e.g. NAT zone).
3. Run a cn-agent task on the source and target CN which will setup a
   communication channel (TCP socket) on the admin network which the two CNs can
   use to perform the migration operation. (this may be combined with step #1
   and step #2)
4. Stop the source instance (if it was running).
5. Vmadm send (i.e. zfs snapshot and zfs send each zfs dataset used by) the
   source instance to the waiting vmadm receive (zfs receive) on the target CN.
6. Unregister the source instance from systems (set do_not_inventory on the
   source instance) and ensure it no longer auto-restarts.
7. Register the target instance with systems (remove do_not_inventory from the
   target instance).
8. Start the target instance (if it was previously running).
9. Cleanup (remove source zone, or schedule for later removal).

## Semi-live migration implementation

TODO. Similar to offline, but with initial zfs send before stopping the instance
and then a smaller incremental send to fetch the remaining delta after stopping
the instance.

# Milestones

## M1: Check vmadm send/receive

We need to fully test and understand what vmadm send currently supports. Brand
changes in the platform occur all of the time, so having a base test suite to
verify what is/isn't working is essential.

- write tests for vmadm send/receive
  - create small test images (maybe Alpine based) instead of using Ubuntu...
- verify vmadm send/receive is working for all brands (SmartOS, Docker, LX, Kvm, Bhyve)

## M2: Update vmadm send/receive

Update vmadm to support all (needed?) brands. For datasets that are nearly full,
the destination quota may need to be increased slightly, just enough for all
necessary write operations. Ideally, the quota could be reduced to its original
size after migration is complete.

- modify vmadm send/receive to support brands needed (some brands may be
  initially scoped), concentrate on KVM/Bhyve?
- modify vmadm send to support multiple disks
- add workaround for nearly full instances

## M3: Update DAPI (CN provisioning/reservation)

DAPI will be updated to select the target CN and provision (reserve) the
target instance.

- provision (reserve) the target instance
  - choose CN
  - allocate/reserve zone
  - install image(s)
  - setup support infrastructure (e.g. Fabric NAT)

## M4: Update CNAPI

CNAPI will trigger and respond to migration calls, using workflow and cn-agent
tasks to control and monitor the migration.

- add CNAPI API migration endpoint
- add workflow tasks for control of the migration states
- create cn-agent tasks to initiate sending/receiving
- other actions on source/target instance cannot occur during a migration
- instance cleanup
- update sdc-clients to add CNAPI migration API wrappers

## M5: Create sdc-migrate tooling

Operators will need a tool to be able to perform a migration from inside of a
CN/Headnode:

    $ sdc-migrate $instance [$cn]
    Migrating $instance in job $job
    ...<progress events>

    $ sdc-migrate list [--fromCn=$CN]
    ...<see ongoing migrations, state, percentage>

    $ sdc-migrate watch $job
    ...<progress events>

- add cli tool to allow operators to perform an instance migration
- allow operators to specify the target CN?
- allow migration to be monitored ()

## M6: End user migration

Add CN traits (controlled by Admin) to flag whether a CN allows migrations, such
that an announcement can then be sent and end users can then migrate their own
instances via CloudAPI or Triton command line.

- add CloudAPI migration APIs
  - this may want to be a workflow job
  - add support for polling migration job
- add Triton cli instance migration support:

      $ triton $instance migrate
      Migrating $foo - this will take a long time, continue y/n?

## M7: Migration estimate

Add APIs that will return an estimate of the time taken to perform a migration.

## M8: Add support for semi-live migration

TODO. How will this be controlled, it could be separate migration phases
("initial", "incrementing", and "final"), where each step can be initiated on
demand? Alternative would be the migration happens all in one operation.

# Open Questions and TODOs

## Backups

- do we want to create a permanent (or for a limited time) snapshot/backup of
  the migrated machine (e.g. stored in Manta) in case something goes amiss, i.e.
  it looks like migration was successful and the source instance was deleted,
  but in actual fact the target instance is not functioning and now we are SOL?
  An alternative to this is that we mark the original source instance as
  migrated and leave it around for later possible restoration, but this would
  not be good in the case of a CN being decommissioned.

## Images

- should the source instance image (and all of it's origin images) be available
  on the target CN? Ideally I would say yes, because some features (like
  CreateImageFromMachine) will depend on these images being available - but is
  this a hard requirement? I am thinking if we can get the image onto the target
  CN then do it, but if not it's not a deal breaker - maybe a warning should be
  issued in this case as some Triton features would no longer work.

- can KVM (and Bhyve?) skip the vmadm send of the zone root dataset and just
  send the uuid-disk* datasets? Since the root dataset is created again by the
  target instance provisioning.

- can we optimize migration (and or zfs send) to make use of base images (i.e.
  to just perform a zfs incremental send from the base/source image)? c.f.
  [joyent/smartos-live#204](https://github.com/joyent/smartos-live/issues/204)
  If the target instance provisioning (reservation) also installs the source
  image to the target CN, then this should be able to work?

## Provisioning

- if migration re-uses the existing cn-agent provisioning process, can some
  parts (e.g. imgadm image install and dataset creation) be skipped?

- what other Triton components will need updating after a migration (i.e. are
  there any Triton services that expect the instance to be on a particular CN)?

- allow an operator (admin) to specify the target CN?

- what controls can be added to allow a user to migrate their own instances? Do
  we have (or add) server traits (e.g. CNs with an 'evacuate' trait allow users
  to perform their own instance migration via CloudAPI/Portal)?

## Networking

- do the source and destination CNs need to be in the same subnet?

- are there any other restrictions imposed by instance and/or CN networking
  (e.g. arp, DNS, routing, firewall)?

- how to control the creation of networks such that two instances have the same
  IP address/MAC etc... does it initially provision the target instance without
  networks and then later remove these networks from the source and then re-add
  to the target instance?

## Progress

- how/what progress events can/will be used to notify for an instance migration?

## Other

- are there controls or limitations needed on a migration, to ensure that it
  does not affect (or limitedly affects) other tenants on the source/target CN.
  If yes, what are they?

- should migration compress the vmadm send data?

- what are the differences for semi-live migration? (i.e. scope semi-live work)

- draw up an activity/flow diagram to show what happens (especially in case of
  failure) in each step of the migration process.

# Caveats

- CPU must to be the same on both source and target CN (e.g. 64-bit Intel
  with Vt/Vx support).
- Destination platform version needs to be equal to or greater than the source
  platform version.
- The image(s) from which the instance was created must still exist in IMGAPI
- Source/Dest time must be in sync.
- PCI-passthrough (and similar) devices will not be supported.
- Guest within a guest is not supported?
- Cannot migrate core Triton services?

# Tests

This is mostly a dev notes section to run tests on these items:

- delegated datasets
- multiple disks (e.g. KVM disk-0, disk-1, disk-2)
- SSH daemons (and their keys) check they work correctly in a migrated instance
- ensure cannot migrate the same instance at the same time (double migration)
- ensure other actions to the instance (start, stop, delete, etc...) cannot be
  performed while an instance is migrating
- failure cases, by the truckload

# References

- [Joyent Migration Docs](https://docs.joyent.com/private-cloud/instances/compute-nodes)
- [Legacy migrator](https://github.com/joyent/legacy-migrator/)
- [Someday-maybe push button migration](https://mo.joyent.com/docs/engdoc/master/roadmap/someday-maybe/push-button-migration.html)
- [vmbundle](https://github.com/joyent/smartos-live/blob/master/src/vmunbundle.c)
