---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 44 Create VMs with Delegated Datasets

## Background Reading

 * OS-1566
 * OS-1750
 * OS-2329
 * OS-2492
 * OS-3757
 * OS-4195
 * OS-4196
 * DOCKER-775

## Introduction

For various reasons, we'd like to be able to have user containers with delegated
datasets so that they can manage their ZFS filesystems themselves.  Some of this
functionality already exists, but there are a number of OS safety concerns and
general API/usability concerns that need to be addressed before this feature can
be deployed for customer consumption.

## Use Cases

[TODO]

## API Considerations

In SDC, end-users generally interact with their containers either through
[sdc-docker](https://apidocs.joyent.com/docker) or [cloudapi](https://apidocs.joyent.com/cloudapi/).
For sdc-docker we don't intend to add any additional API features at this point.
While we can add delegated\_datasets for these containers, there will be no
options exposed to users.

When using cloudapi, the [\*MachineSnapshot](https://apidocs.joyent.com/cloudapi/#CreateMachineSnapshot)
endpoints may no longer do what a customer expects when they have a delegated
dataset. The change here is that instead of taking a snapshot of a "machine"
and rolling back that machine (because the machine only has one dataset), we're
now actually only taking a snapshot of the zoneroot.

If a customer has created a database on their delegated dataset, and taken a
snapshot of this "machine" using cloudapi, and then they upgrade their database
which migrates their data to a new format, it is their responsibility to
understand that if they do a StartMachineFromSnapshot their data will not be
rolled back and their database may not work. Basically: using this feature
requires a firm understanding of its implementation and of ZFS. We need to make
that clear in the documentation.


## Safety Considerations

### Ability to `zfs recv`

We've discussed internally many times that arbitrary "zfs recv" in a zone is
dangerous. In order to mitigate this, we'll disable zfs recv in zones with a
delegated dataset unless that zone has special operator privilege (e.g. for
manatee which needs to be able to import datasets in order to catch up).

The ability to recv or not will depend on vmapi including the -sys\_fs\_import
privilege in the limit\_priv set we send when provisioning. For manatee VMs
provisioned against VMAPI, we'd not set this. But for VMs created by cloudapi
and docker we'd always set this privilege.

The way this would be implemented is to add the ability for clients (cloudapi
and docker) to pass a special:

```
    "delegate_dataset": "safe",
```

option to VMAPI. At VMAPI this would get translated to:

```
    "delegate_dataset": true,
    "limit_priv": "-sys_fs_import",
    "zfs_snapshot_limit": 128,
    "zfs_filesystem_limit" 32,
```

when sending the payload to CNAPI. We also would prevent the combination of
setting delegate\_dataset="safe" and limit\_priv including "sys\_fs\_import".
The zfs\_*\_limit options are discussed below.

Related: OS-4195

### Limits on the Number of Snapshots

Having many snapshots on a CN can significantly slow down ZFS operations (such
that zfs list takes *minutes* to return). This in-turn slows down every single
action that occurs on the CN to the point where the CN can become unusable.
Additional snapshots can also slow deletion of the VM. In order to limit these
problems in attempt to ensure we're able to always make forward progress we want
to set limits on the number of snapshots a customer can take in their zone.

This limit will be set with the zfs\_snapshot\_limit feature from OS-2329. The
initial plan would be to limit to 128 snapshots whenever
delegate\_dataset="safe" in the payload to VMAPI.

Related: OS-1566, OS-2329

### Limits on the Number of Filesystems

Similar to having a lot of snapshots and DoSing the system, it's possible to
cause problems for the system by having too many filesystems in your zone. We
will mitigate this by ensuring that the zfs\_filesystem\_limit option is set
whenever delegate\_dataset="safe" is passed.

Zones with delegate\_dataset="safe" would be limited to 32 filesystems per zone.

Related: OS-2329, OS-4196

### Limits on Platform Versions

The delegate\_datasets="safe" property can only be supported on platforms that
have OS-3757 and OS-2329, so we will need some mechanism to specify a
min\_platform when using this option so that DAPI will refuse to place the VM
on an older platform.

Currently it looks like 20150418T\*Z would be the oldest platform that would
support the recv limit and the limit on snapshots/filesystems.

Related: OS-3757, DOCKER-775

### Ability to Disable

In order to have some mechanism to shut this down in the case some future
security or other issues are discovered with this feature, we should add a
feature flag in cloudapi and sdc-docker so that we can enable/disable user
creation of delegated datasets.


## Initial Rollout

In order to facilitate rolling this out for beta testing, we should add a
whitelist in cloudapi and sdc-docker such that customers (based on owner\_uuid)
on this list will have delegated datasets for their VMs. This way we can control
access to this feature on a per-customer basis. Eventually this support could be
removed once the feature is considered stable.


## Other Considerations

Unsupported 3rd party scripts which modify zfs filesystems (e.g. by moving
around zfs datasets) will need to make sure that they are keeping the zfs
properties limiting the snapshots and filesystems.


## Out Of Scope and Future Work

### Reprovision Support in Cloudapi

This RFD does not cover the addition of reprovision support to cloudapi. When
reprovision support is added later, it should be made clear that reprovisioning
an instance that has a delegated dataset will:

 * destroy all existing snapshots for the VM
 * destroy and replace all data in the zoneroot
 * leave all data on the delegated dataset as-is

Any work here will also need to resolve OS-5484 and thereby require a newer
platform than exists currently as the min\_platform for being able to
reprovision. Unless this is worked-around in the agents.

### Renaming Cloudapi Endpoints

In order to make the behaviour more consistent with the name, we may want to
rename the cloudapi endpoints to remove the name "Machine" and replace it with
"Root". E.g. CreateRootSnapshot is more correct than CreateMachineSnapshot since
there are many aspects of the machine that are not being snapshotted in this
case.


## Summary of Proposed Changes

 * Add delegate\_dataset="safe" virtual parameter to VMAPI for provisioning,
   which:
    * Ensures -sys\_fs\_import is set in limit\_priv
    * Sets zfs\_snapshot\_limit=128 in the payload (if limit not already provided)
    * Sets zfs\_filesystem\_limit=32 in the payload (if limit not already provided)

 * Update documentation for cloudapi to indicate that \*MachineSnapshot endpoints
   are now misnamed and they *only* take a snapshot of the zoneroot. Any data
   stored on delegated datasets will be up to you to manage and you should
   really know what you're doing when using this feature if you want to avoid
   losing your data.

 * Update documentation for sdc-docker to indicate that containers may have
   delegated datasets and pointing to more information about what this means.

 * Add support to (or confirm if there's existing support in) DAPI for receiving
   a min\_platform based on the use of a feature. In this case we'd pass a
   min\_platform value when delegate\_dataset="safe".

 * Modify VMAPI to ensure we only provision delegate\_dataset="safe" VMs to CNs
   that support safety. (Using the DAPI mechanism above.)

 * Add a feature flag to cloudapi and a separate flag to sdc-docker in order to
   allow enabling/disabling this feature.

 * Add support for a whitelist of users who are able to use this feature in
   cloudapi and sdc-docker while the feature is being beta tested.

 * Remove existing code which prevents VMs with delegated datasets from being
   snapshotted.

 * Add tests for all of the described behaviours.

 * Close out the existing tickets which were planning to implement this feature
   differently (to actually make the snapshots include all the datasets).
