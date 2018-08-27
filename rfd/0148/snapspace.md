Space Management for Snapshots of Bhyve VMs
=

# TL;DR

The following are core requirements to support snapshots of bhyve instances.

1. They must not allow the use of an unbounded amount of space.
1. Basic operations must be available. These include: create snapshot, destroy snapshot, list snapshots, and roll back to a snapshot.
1. If an instance uses multiple filesystems and/or volumes, snapshots must be created as *recursive snapshots* to ensure that a crash-consistent image is obtained.  Likewise, all rollback operations must roll back all filesystems and volumes to the same snapshot.
1. The system must default to not overprovision storage.

The following should be implemented for the sanity of developers working on systems with relatively small storage.

1. It should be possible to enable overprovisioning of storage.

## MVP implementation

To meet the requirements above, *refquota*, *quota*, *refreservation*, and *reservation* shall be set by default as follows on bhyve instances.

| Dataset         | refquota | quota | refreservation | reservation |
| --------------- |:--------:|:-----:|:--------------:|:-----------:|
| zones/<img-uuid> | [1]     |  [2]  | [1]            | [2]         |
| zones/<img-uuid>/disk<N> | none | none | [3]        | none        |

1. A size sufficiently large to store configuration and log files.  100 MiB is probably plenty large, but a historical allocation (quota) of 10 GiB may exist.
2. This is the sum of [1] and all [3]s for this instance.  The vmadm payload value of *quota* may override this value, but only if it is larger than the calculated value.
3. The value calculated by the system when *refreservation* is set to *auto*.

Automated and manual procedures that alter storage allocations (resizing, adding disks, etc.) must recalculate the values above to ensure that the right amount of storage is reserved.

## Developer friendly implementation

To allow developers to overprovision, an option should exist that causes VMs to be deployed with *reservation* and *refreservation* set to *none*.

## Future work

The work specified above seems likely to cause minimal disruption to existing platform code, DAPI, etc.  It does not address all concerns related to over-provisioning.  In order to do that, most filesystems that are not associated with bhyve will need to have *refreservation* and *refquota* set to ensure that the various parts of the system stay within reasonable bounds.  Arriving at those reasonable bounds is not a straight forward task.

# Gory details

Currently, snapshots are allowed of smartos and lx zones. This is being extended to bhyve.  Due to the nature of how space is used in virtual machines, the space required for snapshots trends toward 100% of the size of disks being snapshotted.

This document provides background information and suggestions for how to safely use snapshots with bhyve.

This document ignores how deduplication may play into the picture.

## Definitions

***Dataset*** is a generic term referring to a filesystem, volume, or snapshot.  The term dataset is commonly used (sloppily) in cases where snapshots are not allowed.  For instance `<dataset>@<snapname>` implies that `<dataset>` could be a snapshot, which is not true because on filesystem and volume datasets can be snapshotted.

On any filesystem or volume dataset, the **available** space is the amount of space that may be allocated.  Roughly speaking, it is the least of:

* Free space in the pool
  * Adjusted for pool layout (mirrors, raidz) - cannot use `zpool get free` directly.
  * Free means not allocated or reserved
  * If neither *quota* nor *refquota* are set on the top-level dataset, `zfs get free <pool>` can be used.
* `quota - used + usedbyreservation`
  * Moot if *quota* not set.
  * If *reservation* is not set, *usedbyreservation* is 0.
* `refquota - usedbydataset + usedbyrefreservation`
  * Moot if *refquota* not set.
  * If *refreservation* is not set, *usedbyrefreservation* is 0.

A zfs ***reservation*** reserves space for a particular filesystem or volume and its descendants.  That is, if a *reservation* is set on the filesystem `tank/a`, that reserved space can be used only by `tank/a` and any filesystems, volumes, and snapshots created under `tank/a`.  A *reservation* of 1 GB on an empty dataset hierarchy reduces the parent's *available* space by about 1 GB.  When *reservation* is set, the amount of space that is reserved but otherwise unused is available via the *usedbyreservation* zfs property.

A zfs ***refreservation*** is very similar to a *reservation*.  The difference is that a *refreservation* only applies to the filesystem or volume on which it is set.  Descendant filesystems, snapshots, and volumes do not charge space against their ancestor's *refreservation*.  When *reservation* is set, the amount of space that is reserved but otherwise unused is available via the *usedbyreservation* zfs property.

A zfs **quota** is used to limit the amount of space that a filesystem or volume can consume.  This limit also applies to its descendants.  If a quota of 1G is set on `tank/a`, the hierarchy rooted at `tank/a` can consume no more than 1 GB of space.  The amount of *quota* left can be calculated by subtracting the value of the zfs property *used* from *quota*.

A zfs **refquota** is like a *quota*.  The difference is that a *refquota* only applies to the filesystem or volume on which it is set.  Descendant filesystems, snapshots, and volumes are not bound by an ancestor's *refquota*.  The amount of *refquota* left can be calculated by subtracting the value of the zfs property *usedbydataset* from *refquota*.

A zfs **snapshot** maintains references to the blocks that existed in a filesystem or volume at a particular point in time.  A recursive snapshot is a hierarchy of snapshots that capture multiple snapshots at the same point in time.  A *recursive snapshot* is created with `zfs snapshot -r <filesystem|volume>@<snapname>`.

## Overprovisioning

If disk space is overprovisioned, writes may fail because the pool has run out of space.  If running out of space at runtime is a problem, overprovisioning should be avoided.  This means that any out of space conditions will be hit during provisioning rather than during normal operations.

To avoid overprovisioning, space must be reserved and restricted on every filesystem and volume.  Space may be reserved with *refreservation* and/or *reservation*.  It may be restricted with *refquota* and/or *quota*.  By pairing each *referservation* with *refquota* and every *reservation* with *quota*, every dataset will be guaranteed the amount of space that it is promised.  Note that on a volume, a *refquota* value that is equal to or greater than the value calculated by *refreservation=auto* will have no impact, as the calculated value is the maximum amount of space that a volume can reference.

There may be cases where runtime failures due to lack of space are acceptable.  For instance, it may be OK to allow core dumps or snapshots to fail due to pool-wide space shortfall.  Neither of these failures would cause runtime failures for workloads within an instance.  Snapshot failures may cause other failures that complicate maintenance operations.

## Compute Node `zones` pool layout

Each CN has a `zones` pool with with the following hierarchy

* `zones/<image-uuid>`
    * Typically many of them -- one per image
    * Populated via `zfs receive` from a simple stream.
        * The stream does not include properties like *refreservation* or *refquota*
        * Never written to after being received
    * May be a filesystem or a volume
    * Always has a snapshot, (typically?) named `@final`
* `zones/<instance-uuid>`
    * Typically many of them -- one per instance
    * Commonly cloned from `<image-uuid>@final`
    * May be created directly via `zfs create`
    * May be a filesystem or a volume
* `zones/<instance-uuid>-disk<N>`
    * One or more per KVM instance
    * Always a volume
* `zones/<instance-uuid>/diskN`
    * One or more per bhyve instance
    * Always a volume
* `zones/archive`
    * If `archive_on_delete` is `true`, this is where the zone is archived during deletion.
* `zones/config`
    * Mounted at `/etc/zones` to store zone configurations
* `zones/cores`
    * Parent of per-zone (per-instance) core filesystem
* `zones/cores/global`
    * Cores of global zone processes stored here
* `zones/cores/<instance-uuid>`
    * One per instance
* `zones/dump`
    * Pre-allocated volume that stores crash dump during crash reboot
* `zones/opt`
    * Mounted at `/opt`
* `zones/swap`
    * Pre-allocated volume for swap space
* `zones/usbkey`
    * Stores CN configuration
* `zones/var`
    * Mounted at `/var`
    * Includes `/var/crash`, home to potentially huge crash dumps that are extracted from `zones/dump`.

Notice that there are three broad classes of datasets:
1. Images
2. Instances
3. Miscellaneous for compute node operation and diagnostics

## Snapshot space accounting

When a ZFS snapshot is created, a very small amount of space (kilobytes) is consumed for metadata.  Additional space is consumed to reference all of the blocks in the snapshotted filesystem or volume that are not already referenced.  Prior to creating the snapshot, the filesystem's or volume's *written* zfs property can be queried to see how much space (sans constant metadata overhead) will be required.

The snapshot's *referenced* property indicates how much space the snapshot references.  Each referenced block may be referenced by other datasets and as such is not useful in understanding the space consumed by the snapshot.

As a block is changed in a filesystem or volume, the space consumed by the newest snapshot that also refers to that block (if any) increases.  The amount of space used by (or *referenced only by*) a particular snapshot is stored in the snapshot's *written* zfs property.

When a snapshot is destroyed, any blocks that are referenced by another snapshot, but not referenced by the snapshotted filesystem or volume, are freed.  These freed blocks result in changes to many zfs properties:

* *usedbysnapshots* will decrease
* *used* will decrease
* *usedbyreservation* will decrease if *used* becomes less than *reservation*
* 

have their space accounting associated with the newest snapshot that references the blocks.

As mentioned above, a snapshot's space is charged against the *refreservation* then the *available* space.  Two snapshots that reference the same block result in one block of charge.  Before creating a snapshot, the filesystem or volume's *written* property can be used to determine how much space a snapshot will consume.

## Clones

A clone is a filesystem or volume that is created from a snapshot.  The amount of space reserved by a snapshot of a clone is enough to store the still referenced blocks that have been written since the clone was created.

## Behavior in face of space shortfall

**Altering Reservations**
Operations that set or increase a reservation or refreservation will fail if there is not sufficient available space in the pool.  Sufficient space is defined as the difference between the space currently used by the covered datasets and the space specified by the new reservation or refreservation.  Examples of these operations include:
* `zfs create -o reservation=<val> <filesystem>`
* `zfs create -V <size> <volume>`
  *Note: Creation of a volume without `-s` and without an explicit refreservation implies `-o refreservation=auto`.*
* `zfs set refreservation=<value> <filesystem|volume>`

**Creating Snapshots**
The amount of space needed is slightly more than the sum of the sizes of all the blocks referenced by the dataset being snapshotted that are not already referenced by another snapshot.  An attempt to create a snapshot will fail if there is insufficient unused *refreservation* plus *available* space.  If there is insufficient *quota* available, this will also cause the snapshot creation to fail.  Because *refquota* does not apply to descendants, *refquota* cannot cause a snapshot creation to fail.

**Writes**
Writing new blocks (i.e. not overwriting) to a filesystem or volume requires allocation of a block.  The allocation will fail if the unused *reservation*, *refreservation*, and *available* space is smaller than the size of the number of blocks required for the write. The write will also fail if the *quota* or *refquota* would be breached.

Overwriting blocks that are referenced by a snapshot require an allocation just as if this was the initial write and can fail in the same way.

When a write fails, the application sees `errno` set to `ENOSPC`.  This is passed to VMs as a generic I/O error, `EIO`.

**Swap and dump devices**
Swap and dump devices are preallocated volumes.  Preallocated volumes are special in that the space that they will use is allocated during creation and they are not copy-on-write.  This means that writes to them will not fail due to shortage of disk space.

Snapshots of preallocated volumes are not useful because snapshots rely on copy-on-write.

## Freeing space

When a file is removed or truncated to a smaller size, the filesystem that contains the file removes its reference to the affected blocks.  If no snapshot references those blocks, the blocks are freed.  This will be accounted for in a subset of *available*, *usedbydataset*, *usedbyreservation*, and *usedbyrefreservation*.

## Abusing snapshots to consume all space

If not restricted by *quota*, a user that is able to write to a volume or filesystem and take snapshots of that dataset can consume all of the space in the pool.  That is:

```
while true; do
    # Overwrite a bunch of data
    # Create a snapshot
done
```
