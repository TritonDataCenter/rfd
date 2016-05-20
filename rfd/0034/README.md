---
authors: Brian Bennett <brian.bennett@joyent.com>
state: predraft
---

# RFD 34 Instance Migration

## Introduction

Migration of instances is a common feature among virtualization platforms. SmartDataCenter is a notable exception. Among public clouds, instance replacement is generally preferred to instance migration.

Nevertheless, at times it has been necessary to migrate instances within the Triton Cloud between compute nodes.

### Types of Migration

There are three types of migration.

* Live migration
* Offline migration
* Semi-live migration

**Live Migration** is when an instance compute task is transferred between physical compute nodes. This is generally done using shared storage, requiring only the memory state and execution context to be synchronized leveraging instance "pausing" to briefly quiesce the instance before resuming on the destination compute node. Due to design choices (vis. the exclusion of shared storage) in SDC, and the nature of OS virtualization in SmartOS (containers, not virtual machines*) live migration is not considered for implementation at this time.

\* Even KVM instances are qemu in a *container*.

**Offline migration** is when an instance is stopped completely (i.e., the guest performs a shutdown procedure), the dataset backing the storage for the instance is synced, and the instance is booted on the destination compute node. Offline migration is the most straightforward type of migration and works in almost any circumstance, but has the disadvantage that the instance will be down for the entire time it takes to transfer the storage dataset.

**Semi-live migration** is when the dataset backing the storage for the instance is synced while the instance is running. Once the dataset is within an acceptable delta on both the source and destination compute node the instance is stopped, a final sync is performed, and the instance is booted on the destination compute node. This allows for both dedicates storage and significantly reduced down time (though, still not as little as live migration).

Semi-live migration is preferred with SmartOS in general and Triton in particular.

## The state of migration in SmartOS

ZFS has well known send/receive capabilities. The ability to snapshot a dataset and send incremental datasets makes syncing ZVOLs between compute nodes easy. Similarly, vmadm has undocumented send/receive subcommands that, in addition to performing zfs send, will send the zone metadata. Due to a design decision with the implementation of KVM zones, vmadm send does not support KVM. Migrations can fail when the dataset size is too close to the quota.

## The state of migration in Triton

While vmadm does have the beginning of a migration feature, migrations are not supported in Triton. Out of necessity, some shell scripts have been written that are capable of migrating instances. This is a road fraught with danger, however. On several occasions changes to the Triton stack have rendered the migration script inoperable or worse, dangerous (i.e., incurring data loss).

## Proposal for enhancing migration capability in SmartOS

Vmadm send requires the following enhancements.

* Workaround for nearly full instances
* Support for KVM
* Semi-live migration

Datasets that are nearly full can be migrated successfully if the zone quota on the destination is incremented slightly, just enough for all necessary write operations. Ideally, the quota could be reduced to its original size after migration is complete.

KVM uses two datasets outside the zone root for disk0 and disk1. Vmadm needs to be enhanced to snapshot and send these datasets.

Vmadm should also be enhanced to perform semi-live migration by default.

## Migration in Triton: A vision for the future

The following is a description of what instance migration might work, imagined by one engineer.

Instance migration should be a first-class supported feature in Triton. This would be comprised of API calls that trigger a workflow to perform the migration unattended. Migrations could be performed on demand, or scheduled. AdminUI would also provide an interface for migrating an instance. Instance migration should use regular DAPI workflows for selecting the destination compute node, or could be specified by an operator to override DAPI selection. Product messaging via CloudAPI and/or the user portal would notify customers of upcoming scheduled migration, and at their option choose to migrate ahead of the predefined schedule.
