---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+148%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc
-->

# RFD 148 Snapper: VM Snapshots

Today, Triton only allows snapshots of OS containers which do not have delegated
datasets.  With the increasing emphasis virtual machines using bhyve, it is
important to extend snapshot support so that customers may have a way to roll
back to an earlier point in time.

This RFD describes Snapper, a project that will offer the following:

- The ability to take an arbitrary number of snapshots of a VM's disks and
  metadata.
- The ability to roll back to arbitrary snapshots without losing the ability to
  roll back or roll forward to any snapshot.
- Off-host storage of snapshots, enabling instance recovery and cloning from
  snapshots.

The features described in this document are aimed specifically at bhyve but may
be supportable with some or all other brands.

## Anatomy of a VM snapshot

A VM snapshot contains the VM's metadata and its data.  That is, it contains all
of the information stored in the zone's dataset (`zones/<uuid>`) and its
descendants.

A VM snapshot uses a recursive ZFS snapshot of the `zones/<uuid>` filesystem.
Each snapshot may then be sent from the ZFS pool and stored in manta along with
metadata.  The initial snapshot is sent as a full stream.  Subsequent snapshots
may be sent as full or incremental streams.

At such a time as the snapshot is successfully stored in manta, the
system will create a ZFS bookmark and may delete the snapshot.  The snapshot
may, however, be retained for some time to allow for rapid rollback in those
cases where the compute node has an abundance of available disk space.  Either
the bookmark or the snapshot (if it still exists) may be used for sending future
incremental snapshots.

XXX for on-prem customers, we may need a store other than manta.  Do we do this
by streaming snapshots via `zfs send $snap | ssh $snap_host "cat > $snap_path"`
or via some simple webapp that needs to run in an infrastructure container?

## Snapshot Operations

The following operations will be available through the `triton` CLI and
cloudapi.

### Snapshot Create

[CreateMachineSnapshot](https://apidocs.joyent.com/cloudapi/#CreateMachineSnapshot)
will be updated as follows.

**Inputs**

| Add/Change | Field | Type | Description |
| ---------- | ----- | ---- | ----------- |
| Add | `backup` | Boolean | Optional. Should this snapshot be stored off this compute node?  This attempts to override the default CN trait `snapshot.backup.enabled`. |
| Add | `from_name` | String | Optional.  Implies `backup` is True.  When backing up a snapshot, save an incremental stream from the specified snapshot.  If not specified, the most recent snapshot will be used.  If this is the first snapshot, a full stream will be generated. |

XXX For backwards compatibility, do we need to use a per-brand CN trait?  Flesh
this out after discussion.

**Errors**

| Add/Change | Error Code | Description |
| ---------- | ---------- | ----------- |
| Change | InvalidArgument | If `name` or `from_name` was invalid. |
| Add | NotAuthorized | If `backup` is True or `from_name` is specified and the CN does not allow backups due to `snapshot.backup.enabled` being set to `force-false`. |

### Snapshot List

[ListMachineSnapshots](https://apidocs.joyent.com/cloudapi/#ListMachineSnapshots)
is not changed.

### Snapshot Get

[GetMachineSnapshot](https://apidocs.joyent.com/cloudapi/#GetMachineSnapshot)
will be updated as follows.

**Returns**

| Add/Change | Field | Type | Description |
| ---------- | ----- | ---- | ----------- |
| Add | `created` | Timestamp | The time that the snapshot was created |
| Add | `backup_size` | Integer | The size in bytes of a single copy of the backup.  A value of 0 means there is no backup. |
| Add | `children` | List of Strings | Snapshots that must be removed before this snapshot can be removed.  The snapshots listed here may also have children which do not appear in this list (children, not descendants). |

XXX If `backup` is True during creation, the `state` return value will become
"created" once the backup is complete.  Between completion of `zfs snapshot` and
the completion of `zfs send`, what will it be?

### Snapshot Delete

[DeleteMachineSnapshot](https://apidocs.joyent.com/cloudapi/#DeleteMachineSnapshot)
will be updated as follows.

**Errors**

| Add/Change | Error Code | Description |
| ---------- | ---------- | ----------- |
| Add | InUseError | If removal of this snapshot is blocked by the existence of one or more child snapshots. |

### Boot from a Snapshot

This is a rollback.  The compute node rolls back to the specified snapshot if it
exists.  Otherwise, it will restore from the specified snapshot.

XXX Restore can be tricky, potentially leading to data loss.  If the CN is short
on space, it may be necessary to destroy the existing volumes before trying to
receive the snapshot.  If that is done and then the snapshot cannot be received
for some reason, we've completely lost the VM.  It may be better to restore to
another CN then delete from the original CN.

XXX A rollback that involves receiving a full stream will no longer be a
descendant of a particular image.  Is that a problem?

## Snapshots in Manta

Snapshots are stored in manta in a hierarchy that ensures that the parent of an
incremental is not removed prior to its children.

  TOP/VM1/SNAP1/stream
  TOP/VM1/SNAP1/meta.json
  TOP/VM1/SNAP1/inc/SNAP2/stream
  TOP/VM1/SNAP1/inc/SNAP2/meta.json
  TOP/VM1/SNAP1/inc/SNAP2/inc/SNAP3/stream
  TOP/VM1/SNAP1/inc/SNAP2/inc/SNAP3/meta.json
  TOP/VM1/SNAP2.path.json
  TOP/VM1/SNAP4/stream
  TOP/VM1/SNAP4/meta.json

In the hierarchy above, SNAP1 and SNAP3 are full snapshots.  SNAP2 is an
incremental snapshot from SNAP1.

If a request to delete SNAP1 were received while the `inc` (incremental)
directory exists, SNAP1 will not be removed.

If a request to access SNAP3 is received, the system will recognize that the
`SNAP3` directory does not exist at the top level in VM1.  The system will read
`SNAP3.path.json`, which will contain `[ SNAP1, SNAP2 ]` to signify that SNAP3
is an incremental snapshot that requires that SNAP1 and SNAP2 first be received.

## Compute Node Space Management

Each snapshot will use space approximately equal to the value of the `written`
property for the filesystem or volume being snapshotted.  For technical and
chargeback reasons, not space limit is enforced by a ZFS quota.  To ensure that
space is available for each filesystem and volume, refreservation must be used.
For the typical bhyve zone, the essential space-related properties are:

- `zones/UUID`
  - `refquota` ensures that the zone can't write too much data to this file
    system.  `refquota` is used instead of `quota` so that the value does not
    need to include space for its descendants (volumes and snapshots).
  - `refreservation` should be set to the same value as refquota.  This will
    ensure that the amount of space specified by the quota is available to this
    file system.  `refreservation` is used instead of `reservation` so that this
    value does not need to include space for its descendants.
- `zones/UUID/disk0`
  - `volsize` is set automatically to the size of the image from which it is
    created.  This value may increase if growing of the boot disk is supported.
  - `refreservation` should be set to `auto`, which will cause the system to
    calculate a value that ensures that there is always enough space to fully
    fill the disk and store its metadata.
- `zones/UUID/disk1`
  - `volsize` is set during instance creation to the size that is required by
    the imgapi payload.  This value may increase if growing of the boot disk is
    supported.
  - `refreservation` should be set to `auto`, which will cause the system to
    calculate a value that ensures that there is always enough space to fully
    fill the disk and store its metadata.

The `quota` and `reservation` properties should never be used in this scheme.

When a VM is snapshotted, the pool's available space will decrease by the sum
of values of the `written` properties on each of the VM's volumes and
filesystem.  The pool's available space is obtained via `zfs list -Ho available
zones`, or equivalent commands.  This value is typically very different from the
pool's free space (`zpool get free zones`), which should not be used for this
purpose.

When a snapshot is created, a hold should also be placed on the snapshot until
it is successfully sent to manta.  Before the hold is removed, a bookmark should
be created so that it may be used as the incremental source for future
snapshots.

The system should be aware of the space that may be freed by removing
snapshots that do not have holds.  This freeable space should be considered free
space for the purposes of VM placement.  During image import and instance
creation, imgapi and cnapi (?) should free space by deleting unheld snapshots,
as needed.

## Chargebacks

The space used by snapshots should be billed to customers based on the amount of
space ✕ time ✕ copies used in manta.

## Instance Recovery from Snapshots

???

```
imgadm recover VM <snapname>
```

Grabs the metadata associated with the VM from manta, finds a suitable CN and
does the same thing as a rollback.

## Open questions

These are here for the sake of discussion.  They will be removed before this RFD
is published.

### Would it be better to base this on IMGAPI?

IMGAPI already knows how to store images in manta and files.

This would make rollback and recovery able to reuse the instance create code.

Complications:

- Creating a VM from an image involves downloading the image file, sending that
  image file into the pool, then cloning the image.  Consider what this
  means for a 1 TB image.
  - 1 TB of reads from the network
  - 1 TB of writes to disk (storing the file)
  - 1 TB of reads from disk (reading the file)
  - 1 TB of writes to disk (receiving the stream)
  - There's a 1 TB image sitting around that can't be destroyed because there's
    an instance that depends on it.
- Does storing to manta involve writing to a file, then copying that file to
  manta?  If so, we probably want to revisit that for the TB+ snapshot case.

Mitigations:

- Ensure that we can stream directly between zfs(1M) and manta.
- After creating a VM from a snapshot
  - Promote the VM's datasets
  - Destroy the image datasets
  - Create a bookmark of the snapshot used during the clone
  - Destroy aforementioned snapshot

### What if there is no manta?

When deployed outside of JPC, manta may not be a viable option.

As mentioned above, an IMGAPI based solution would be able to store to files.
Customers could potentially use NFS to easily store off the compute node, else
move them using scp or similar after creation.

### Very large snapshots issues

Suppose there is a 1 TB snapshot that needs to be sent.  If it is allowed to
saturate a 10 gigabit link, it would take nearly half an hour to complete the
transfer.  It is quite likely that such a high data rate would have significant
impact on workloads on the CN.  A more moderate rate of 1 Gb/s would require
nearly 3 hours.

If the sending or receiving of a large stream is interrupted (network outage,
reboot, etc.) it will need to be restarted from the beginning.  One may argue
this is a reason to stream to a local file first, then copy the file.

### Stream to a live ZFS pool?

The initial thought for off-host snapshots was to stream to an off-host zpool.
Ideally, that would be to multiple off-host zpools.  This would solve several
problems that are not solved with streaming to files in manta (or not in manta).
In particular:

- It would be possible to remove any snapshot without having any impact on the
  usability of later snapshots.
- Rollback to any snapshot could involve sending a single stream without having
  to send intermediate streams that may have no useful data.
- It becomes feasible to have scheduled snapshots that are always incremental
  without accumulating a large number of intermediate incrementals.  This could
  be part of a strategy to make it so that snapshots of multi-terabyte VMs are
  quite fast without excessive storage cost or rollback complication.
- Instead of sharing code with IMGAPI, this code would be shared with instance
  migration (See RFD 34).

The manta approach is currently viewed as the best option, largely because it
relies on a battle-tested solution to storage resilience in the face of
failures.  Getting a ZFS-based solution that handles storage node outages,
failures, and replacements well is a big task.
