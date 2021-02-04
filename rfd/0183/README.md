---
authors: Brian Bennett <brian.bennett@joyent.com>
state: predraft
---

# RFD 183 Triton Volume Replication and Backup

This RFD describes a method for using Manta to facilitate backups and
replication of Triton Volumes.

High Availability, fault tolerant storage is best left to a dedicated SAN.
We will not try to implement SAN features in Triton. However, there is much we
can do to make the process of backing up, replicating, and recovering Volumes.

This RFD aims to make volume recovery manageable and user servicable.

## Problem statement

Triton Volumes are one of several strategies users may employ to decouple data
and applications. Triton Volumes, being in essense a zone running on a Compute
Node are subject to the availability of that compute node. In the event of
hardware failure, a volume may be unavailable for an extended period of time,
or worse, lost completely.

Additionally, CloudAPI does not allow changing volume mounts after create time.
Because of this, in the current implementation if a volume is offline or lost,
the instances using that volume will need to be destroyed.

## Proposed Solution

On the subject of data preservation, there are two complementary practices:
backups and replication. This solution adds opt-in automatic backups to Triton
Volumes, as well as opt-in automatic restore. When multiple volumes are created,
where one is creating backups and others are consuming the backed up data,
replication can be performed. With Manta being a fault tolerant object storage
service, manta will be used to facilitate this.

Additionally, we will allow changes to volumes defined for an instance.

## Implementation Details

### Volume Backup & Replication

* volume flag for "push to manta"
* volume flag for "pull from manta"
* push/pull volume flag can be reversed
* push zfs snapshots into manta
* use bookmarks so we don't have to retain snapshots
* create json index of sanps so users can locate something they want to restore
* need rbac credentials for manta

### Post-Provision Volume Mapping

* allow volume map changes via cloudapi -> trigger reboot of zone

## Open Questions

* How do volume instances discover the MANTA_URL?
