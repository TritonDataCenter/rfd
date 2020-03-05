---
authors: Kody Kantor <kody.kantor@joyent.com>, Jerry Jelinek <jerry@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+181%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc.
-->


# RFD 181 Improving Manta Storage Unit Cost (MinIO)

## Problem and background

As stated in RFD 174, there is a desire to decrease the cost (in terms of
$/GB/month) of running large scale Manta installations.

RFD 174 proposes a solution for this problem by deploying ZFS on top of iSCSI
targets exported from each of ten shrimp in a rack. Each storage node would
host a zpool composed of 10 disk wide RAIDZ stripes where each disk is provided
by an iSCSI target. In this manner ZFS is providing erasure coding over the rack
of storage nodes and allows Manta to store only one logical copy of each object
without drastic sacrifices in data durability.

This RFD proposes an alternative approach. In this RFD we'll describe a system
that utilizes the MinIO object storage system to provide erasure coding to the
Manta storage tier.

## Proposed solution

As with RFD 174 we propose storing a single logical copy of user data to one
rack in one datacenter. Durability of the data will be increased by relying on
MinIO's erasure coding software to store and reconstruct shards of the object on
each storage node in the rack.

Currently each rack consists of ten storage nodes. We propose
deploying one MinIO instance to each storage node in the rack to form a single
HA MinIO cluster per rack. Read and write requests can be serviced by any MinIO
instance in the cluster.

Each storage node will either have a RAIDZ-based storage topology similar to
what we use today on storage nodes (specifics of the topology is TBD), or will
not use RAIDZ at all. A high-level diagram of this can be found
[here](./minio_arch.jpg).

For a given rack of 350 disks and double parity MinIO on top of
5x7-wide RAIDZ1 we can accomplish 85.7% ZFS efficiency and 80% MinIO efficiency.
This is a total of 68.6% efficient (80% of 85.7%). Realistic MinIO efficiency is
lower than 80% due to metadata files being required for each data shard. Our
current efficiency is 38% and the RFD 174 efficiency is 65%.

### Erasure Coding Configuration

MinIO uses reed-solomon erasure coding. RAIDZ also uses a modified reed-solomon
erasure coding algorithm. We'll discuss a few different erasure coding
configurations here and provide theoretical storage efficiency numbers for each.
Note that the storage efficiency numbers do not take into account MinIO's
metadata. MinIO writes a metadata file for each shard of data that is written.
This has a negative capacity efficiency impact especially on small files.

MinIO allocates storage in what they call erasure coding zones and sets. An
EC zone is a grouping of servers, and an EC set is a selection of disks within
the EC zone. An EC set can have 4, 6, 8, 10, 12, 14, or 16 disks. An EC set is
conceptually similar to a RAIDZ stripe that spans machines.

All of the following data only applies to a 36-bay BoM and does not apply to the
dense shrimp 60-bay or greater machines. Separate zpool layout and MinIO EC set
configuration analysis would need to be done for other BoMs. The following data
also only accounts for 10 shrimp machines per rack, since this is our most
common.

In our configuration we would have a single EC zone consisting of all ten
storage nodes. Each storage node would then expose either a single disk
(in the RAIDZ case), or 35-36 disks (in the RAIDZ-less case).

#### MinIO on RAIDZ

Using RAIDZ beneath MinIO provides some advantages over allowing MinIO to
handle individual disks. We would primarily gain additional object durability.

Using RAIDZ would also allow us to rely less on MinIO's healing (resilver)
and bit-rot detection functionality which we have not tested in production.

Using RAIDZ also has disadvantages. Writing to RAIDZ is slower than writing to
non-RAIDZ pools. RAIDZ also brings additional storage unit cost compared to
relying completely on MinIO.

If we used RAIDZ we would likely use only double parity in MinIO. This would
mean we could lose two of ten zpools and not lose any data. This is the
minimum parity allowed by MinIO. Double parity in a 10-wide EC set adds
20% capacity overhead. If we configured a zpool with 5x7-wide RAIDZ1 that adds
an additional 14.3% overhead for a total of 34.3% overhead. Each rack would have
350 disks (and 10 SSDs for slog or l2arc).

#### MinIO without RAIDZ

If we would not use RAIDZ the question is more difficult. If we have 35 disks
on each system, that is 350 disks in each rack. This would allow us to have
25 14-wide EC sets in the rack. This means each storage node would have one disk
in each EC set and four storage nodes would have two disks in the EC set.
Quadruple parity is required to survive losing two storage nodes, which is about
28.6% overhead.

If each machine was configured with 36 disks the best EC set configuration is
30 12-wide EC sets. In this scenario only two machines would provide two disks
in the EC set. Quadruple parity would allow us to survive losing two storage
nodes and contributes 33.3% overhead.

36 disk machines grant us 2.8% more disks compared to 35 disk machines but the
parity overhead is almost 5% greater. MinIO doesn't have the notion of 'hot
spares' as we do in ZFS, so we would have to consider what to do with the 36th
slot if we chose a 35-disk MinIO EC configuration. Currently the last disk slot
is used for an SSD, but MinIO would not be able to take advantage of an SSD in
a bare-disk configuration.

### Load balancing

Each MinIO instance in the rack can service read and write requests. Our system
must be able to tolerate the failure of some number of MinIO instance in a rack.
We have thought of two approaches to this problem.

#### DNS

DNS load balancing is used in other areas of Manta, like managing
connections to Moray instances. Each MinIO instance could register an A
record for the rack (e.g. rack0.stor.local). This would allow clients (e.g.
Muskie) to perform round-robin selection of A records.

Open questions for this approach are how quickly changes can be propagated when
a MinIO instance fails, and how much load this may place upon our DNS servers.
We will likely need to find the optimal Cueball behavior for this configuration.

#### HAproxy

HAproxy is used in Manta for load balancing at the front door and Muskie
processes within Muskie zones. A few HAproxy instances could be deployed
to the rack and registered an A record in DNS (e.g. rack0.stor.local). This
approach is similar to the DNS load balancing approach but may allow us to have
a lower turnaround time in the face of an individual MinIO failure.

## Failover

We will need to test how quickly Cueball or HAproxy is able to shuffle
connections after a MinIO instance goes offline. MinIO should be able to handle
reconstructing any erasure coded data on the fly.

## Maintenance

### Storage node maintenance

No special action should be required for short term maintenance of individual
storage nodes (rebooting, chassis swaps, etc.).

### Switch Maintenance

Our production deployments have two ToR switches per rack in an HA
configuration. We then create aggregated links (aggrs) on each machine using
one port from both switches to ensure that the machines are still accessible in
the event of a switch failure.

We need to consider if we should dedicate one of the ToR switches to serve
rack-local traffic (communications between MinIO instances). This would mean
reduced availability during a ToR switch failure. A drastic increase in
throughput or decrease in latency by dedicating a switch to rack-local traffic
may make the availability tradeoff acceptable.

## Changes required in Manta

### Muskie -> MinIO

The most risky change is in the data path from Muskie to MinIO. Since MinIO
speaks the S3 API we would need to modify the shark client code to use the S3
API instead of the much simpler WebDAV API. Another option is to investigate
deploying a WebDAV -> S3 broker service. This would translate WebDAV API
operations to S3 API operations. There is prior art for this.

One open question is how Manta decides when to stop writing to a MinIO rack.
With a rack-based MinIO deployment storage unit changes from representing an
individual zone (e.g. 2.stor.local) to an entire rack (e.g. rack0.stor.local).
Currently the Minnow service uploads heartbeat data to Postgres and the Picker
service is able to filter the results to not include storage zones that are
at or near capacity. We would need to revisit this path for a rack-based MinIO
deployment. MinIO reports some capacity usage statistics, but it currently
relies on scanning on-disk metadata. We expect this will not work at scale.

### Garbage collection

We have not thought much about the delete path before writing this document.
Delete operations in MinIO appear to be synchronous. In Manta delete operations
are asynchronous.

We could allow delete operations to remain asynchronous and have the garbage
collection software issue delete requests to MinIO clusters instead of directly
deleting files on disk (as is done in Manta v1).

Alternatively we could have Muskie issue delete requests to MinIO immediately
upon receipt from the customer.

### Rebalancer

We also need to consider the role of the rebalancer with a MinIO storage tier.
MinIO provides facilities for reconstructing data when a storage node is lost,
and a facility for bit-rot detection. We have not tested either of these MinIO
features.

Decommissioning an entire rack of storage nodes would require the rebalancer.
The rebalancer would read all the data from one rack, write it to other
racks and update the corresponding metadata in Manta. The file layout and API
are different in MinIO vs Manta v1's nginx, so some amount of modification would
be required for the rebalancer.

## Changes required in MinIO

## Sync writes

MinIO only uses sync writes for metadata. This means that data files can become
lost in the event of a system crash. Upstream recommends users mount their
filesystem with the `sync` mount option if they would like sync writes by
default. This does not make sense for ZFS, so we could carry a small change to
enable sync writes in MinIO, just as we do for nginx.

## illumos platform support

MinIO currently does not fully support running on illumos. We have a set of
changes that allows MinIO to build and are working on sending these changes
upstream. We may discover further down the road that some functionality is
more optimized for Linux than illumos which requires fixing. We've already
discovered problems like this with MinIO's file locking and directory walking
code on illumos.

These problems will need to be root caused and fixed. We will be responsible for
maintaining support and fixing platform support problems as they are introduced
upstream.

## File layout

In the process of going to Manta v2 we discussed adding a new storage node
file layout for objects created using the Buckets API. Objects created with the
current directory-style API are written in a single directory for each user.
The proposed file layout for objects created using the Buckets API would involve
creating more directories based on the object UUID. The intent of this is to
make it easier to map objects to the metadata shard they are stored in. A
secondary goal was to reduce the number of files stored in each directory.

MinIO appears to support somewhat arbitrary file layouts.

For example, a user can upload a file to the path `/bucket_name/object_name` and
the on-disk layout looks like this:
```
/disk_path/bucket_name/object_name/[object_metadata, object_data]
```

Or the user can specify an arbitrary depth of directories in which to nest
the final object. For example, an upload to the path
`/bucket_name/dir0/dir1/dir2/object_name` looks like this on disk:

```
/disk_path/bucket_name/dir0/dir1/dir2/object_name/[object_metadata, object_data]
```

Using this feature we could accomplish the file layout changes suggested in
MANTA-4591 with minor modifications and no changes to MinIO:
- The bucket uuid and owner uuids would be swapped (since MinIO always addresses
  by bucket uuid first)
- We would need to consider what to do with the `v2` portion of the path. One
  option would be to add it after the bucket name, e.g.
  `/disk_path/bucket_name/v2/owner_uuid/object_uuid_first_n_chars/[...]`

## Testing

### Performance (throughput and latency) testing

Test plan and results will continue to be made available in
[manta-eng](https://github.com/joyent/manta-eng/tree/master/minio_poc).

## MinIO implementation details

### Healing

To be tested.

### Bit-rot detection

To be tested.

### Locking

To be tested. This may not be critical given that Manta implements locking in
Postgres.
