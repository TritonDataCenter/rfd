---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+<Number>%22
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
Each snapshot is then sent from the ZFS pool and stored in manta along with
metadata.  The initial snapshot is sent as a full stream.  Subsequent snapshots
may be sent as full or incremental streams.

At such a time as the snapshot is successfully stored in manta, the
system will create a ZFS bookmark and may delete the snapshot.  The snapshot
may, however, be retained for some time to allow for rapid rollback in those
cases where the compute node has an abundance of available disk space.  Either
the bookmark or the snapshot (if it still exists) may be used for sending future
incremental snapshots.

## Snapshot Operations

The following operations will be available through the `triton` CLI and
cloudapi.

### Snapshot Create

XXX When sending
  - First snapshot is always a full
  - Customer may specify
    - full
    - incremental - delta from previous snapshot
    - differential - delta from a specific snapshot

### Snapshot List

Lists existing snapshots, their sizes, and metadata (maybe?).

XXX probably need some means to verify that the snapshot copy to manta has
completed.

### Snapshot Delete

Delete a specific snapshot, but not if it is the origin for another snapshot.

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

When a VM is snapshotted, the pool's available space will descrease by the sum
of values of the `written` properties on each of the VM's volumes and
filesystem.  The pool's available space is obtained via `zfs list -Ho available
zones`, or equivalent commands.  This value is typically very different from the
pool's free space (`zpool get free zones`), which should not be used for this
purpose.

When a snapshot is created, a hold should also be placed on the snapshot until
it is successfully sent to manta.  Before the hold is removed, a bookmark should
be created so that it may be used as the incremental source for future
snapshots.

The system (DAPI?) should be aware of the space that may be freed by removing
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
