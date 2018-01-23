---
authors: David Pacheco <dap@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 116 Manta Bucket Exploration

This document describes parameters and a plan for exploring the use of existing
components as a basis for an implementation of the Manta "Buckets" feature.  The
background below describes some motivation and basic requirements around Manta
buckets, but **this is not an RFD for the buckets feature itself.**  For all of
these discussions, Manta buckets have nothing to do with buckets in Moray (that
are used to implement Manta's metadata tier today).

## Background on buckets in Manta

Manta organizes objects into a hierarchical namespace modeled after the
filesystem: each object and directory (aside from the root) must be contained
inside exactly one directory (its parent).  Further, Manta imposes a cap of 1
million entries inside each directory in order to allow the system to provide an
API to efficiently list the contents of any directory.  These choices were made
during the initial system design based on feedback from people with experience
working with other object storage systems that didn't have these properties.
For many use-cases, these tradeoffs work well, since they enforce conventions
that many users expect of a filesystem-like namespace and they enable
enumeration of large datasets.

On the other hand, use-cases exist for which these tradeoffs work very poorly.
Consider a workload involving the storage of many billions of objects managed
by an application-level component.  Such a component maintains its own index
describing which objects exist in Manta.  In this case, the user does not
require enumeration of the objects stored in Manta (since they're indexed in the
application).  On the other hand, in order to be able to store tens of billions
of objects, the user needs to work around the per-directory limit, often using
the well-known pattern of creating a tree of directories with names constructed
based on the basename of the object (e.g., "obj123456" might be stored at
"obj123/obj12345/obj123456").  This hierarchy provides no value to the user, but
it creates a number of costs:

* PUT latency is increased because of the extra parent directories that need to
  be created (or at least validated).
* PUT availability is reduced because any of the extra requests related to the
  parent directories may fail.
* PUT throughput (in terms of objects per second) is decreased because shards
  hosting higher levels of the directory tree wind up being bottlenecks for the
  directory creation or validation operations.
* Cost increases because all of the extra directory metadata becomes a
  considerable fraction of overall metadata bytes stored.
* The extra directory entries exacerbate scaling issues in the metadata tier
  (e.g., PostgreSQL vacuum operations), requiring more frequent and more
  time-consuming reshard operations.

To address this, it's been proposed to add a new set of APIs to Manta that more
resemble buckets in key-value stores.  These buckets may be implemented by
allowing the user to create entries within their account's namespace (e.g.,
`/$MANTA_USER/buckets/$bucket_name`).  Users could create objects in these
buckets without the hierarchy constraints imposed in the rest of the object
namespace (i.e., parent directories would not need to exist).  It's an open
question whether it will be a requirement to list objects within a bucket or to
list objects within a bucket matching a substring filter (as other object stores
do in order to implement directory-like namespaces within each bucket).


## Implementation directions

We believe the current metadata tier can support the proposed model, but the
creation of a new set of APIs affords an unusual opportunity to rethink the
implementation of the metadata tier.  All options are on the table at this time,
including proceeding with the existing metadata tier architecture.


### Option 1: Enhance existing metadata tier

The obvious approach to enhancing the existing metadata tier would be to create
a new Moray bucket called `"manta_bucket_contents"` on each shard.  Most API
operations would work similar to the way they work today, except that where we
currently enforce the existence of the parent directory, we would instead
enforce the existence of the parent bucket (which is easy to parse out of the
name of an object that's supposed to be in a bucket); and where we currently use
the parent directory of an object as input to a consistent hashing algorithm to
find its shard, we would instead use the full name of the object.  In this way,
the metadata describing the objects in each bucket would be spread across all
shards in a uniform way, but we could still find it efficiently, and we could
likely still list the contents of buckets reasonably efficiently by walking
through the shards and providing the current shard as part of the marker used to
request each next page of results.

This approach has the primary advantage that it's mostly made up of components
that already exist, that already work together, and that we know how to deploy
and operate.  However, it has all the disadvantages of today's metadata tier,
which mostly involve the upgrade, scalability, and operability challenges
associated with a fleet of highly-available PostgreSQL clusters.


### Option 2: Build a new metadata storage service using an off-the-shelf distributed database

A number of distributed databases exist today that did not exist when Manta was
first designed, and many of these systems are built from the ground up for high
availability and online expansion.  Exploration is needed to determine which of
these systems, if any, may be suitable as the backing store for the buckets
feature, as well as the costs and risks of building a system with one of these
components.


### Option 3: Build a new metadata storage service using low-level components

Consideration has been given to building a new metadata tier using a combination
of an off-the-shelf non-replicated, single-consumer databases (e.g., sqlite)
with replication managed by a proven consensus algorithm (e.g., Raft, either
using an off-the-shelf component or a new implementation).  As with option 2,
exploration is needed to determine which of these systems may be suitable, as
well as the costs and risks of building such a system.


## Exploration

We will explore these three options in a time-bounded way so that we can decide
on the most promising path and implement it.

If we pursue an off-the-shelf component, it would ideally satisfy several
qualitative and quantitative requirements below.

### Qualitative requirements

* It should be **open-source.**
* It should run inside a SmartOS or LX-branded zone.
* It has to support the PUT, GET, LIST, and DELETE operations that we need.
* It should provide strong **durability** guarantees: corruption of the
  database, even in the face of ungraceful fatal failure of either hardware or
  software should be virtually unheard of.  Such failures include system resets,
  power loss, running out of disk space, and the like (though it does not cover
  arbitrary filesystem corruption).  Maturity in this area often involves some
  way to verify the integrity of data read (e.g., checksums), tools for
  inspecting internal data structures, and tools for recovering from unexpected
  corruption.
* The system must be **horizontally scalable**, essentially arbitrarily, by
  adding additional instances.  This should not require downtime, and this
  should allow us to scale out essentially any resource -- not just total
  storage capacity, but also request processing capacity.
* It should enable us to build a system with **zero planned downtime**, even for
  maintenance operations, even for operations that upgrade the system or expand
  capacity.  Examples of operations that should not require downtime
  proportional to database size include major upgrades, failovers, and periodic
  maintenance activities (like PostgreSQL's "vacuum").  The system should not
  able to accumulate forms of debt that must be repaid at future times before
  the data path can proceed (again, similar to "vacuum" or various forms of
  replication lag).
* It should provide a path for **upgrade** of the component itself with
  virtually no downtime.  (By contrast, typical PostgreSQL major upgrade
  procedures require rebuilds of replication peers, which results in many hours
  of potential risk.)  The upgrade risk itself should be somewhat mitigatable
  (e.g., rollback options, even if it's just to restart the database from ZFS
  snapshots).
* It must be **automatable**, particularly around **deployment**, **expansion**,
  and **monitoring**.  The system should provide **runtime metrics** for
  monitoring its performance and general behavior.  When issues develop that
  require human intervention, it must be possible to raise alarms
  programmatically based on **crisp alarm conditions.**
* There should be plenty of **observability tools** for examining the behavior
  of the system.  That should not be limited just to user-facing operations, but
  internal operations as well -- things like SQL's `EXPLAIN [ANALYZE]`, DTrace
  probes, metrics, logging of unusual or pathological behavior, and ways to ask
  the system about internal details that are important for operators (e.g.,
  PostgreSQL's `pg_locks` view).
* We assume that even if we select an off-the-shelf distributed database, our
  deployment will likely become the largest deployment of that database within
  12-24 months.  A rigorous **community** is important, and **commercial
  support** options may be nice, but **it's critical that we be able to monitor,
  observe, and modify the component ourselves.**  This may affect the
  **programming environments** that we're willing to deploy, though nothing is
  off the table at this point.

### Quantitative requirements

* It should provide substantial **write throughput** (in terms of
  metadata-records-written-per-second), even in the face if simultaneous reads.
  **Read latency and throughput** are also important.
* It should be **cost-efficient**.  We will focus first on **storage
  efficiency** (e.g., disk bytes required per object stored) and **resource
  efficiency** (e.g., memory, CPU, and network bandwidth required to satisfy a
  given level of workload), though ultimately these are mostly proxies for cost
  efficiency.

This is obviously quite a high bar, and it's possible that no existing component
satisfies all of these requirements.  But ultimately, the above is what we're
charged with building.  We will consider solutions that don't meet all of the
above provided that we can use them as the foundation for what we need to build.


### Other considerations

* **Strong consistency** is not a hard requirement at this stage, though it's
  likely that a system would have to be truly an excellent match on most of the
  above criteria for us to consider not having it.
* A strong result from [Jepsen](https://jepsen.io/analyses) would be hugely
  valuable for demonstrating the system's overall data integrity in the face of
  failures.
* How will we implement "list" operations efficiently using this store?  What
  about prefix-based searching?
* What options will be available for migration of data in the non-bucket
  namespace into the bucket namespace?
* Will we need to support multipart upload for objects inside buckets?  How does
  that affect the latency, availability, and throughput of object uploads?


## Testing notes

We do not place much weight on a system having a positive reputation or vague
anecdotes about its use by other large organizations.  We have experience with
well-known, well-liked components used by many organizations that nevertheless
have major architectural defects or implementation issues exposed at high levels
of scale or under workloads that differ from the mainstream, so it's important
that we do our own validation under load.

Ideally, before committing to a path, we would have tested it:

- for an extended period (at least 48 hours)
- under very high read/write load (essentially, at the physical limits of the
  systems that it's deployed on)
- with very high total record counts (e.g., at least hundreds of millions of
  records)
- with various types of injected faults (killing processes, injected network
  partitions, system panics, power resets)

and verified that the overall integrity of the system is never compromised and
that latency and throughput remain steady aside from transient degradations
during and very shortly after injected failures.
