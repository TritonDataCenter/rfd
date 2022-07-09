---
authors: Jordan Hendricks <jhendricks@joyent.com>, Joshua Clulow <jmc@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent Inc.
-->

# RFD 123 Online Manta Garbage Collection


## Overview

This RFD will propose an online garbage collection system for Manta.

Garbage collection in Manta comprises two general processes: the deletion of
backing data files for Manta objects as end users delete or overwrite objects,
and the deletion of data associated with multipart uploads.

The existing garbage collection system is "offline", meaning that it operates
_post hoc_ on backups taken from Manta's databases.  This model has several
issues, including that it does not scale well to very large deployments.
The primary goal of this RFD is to propose an "online" system, meaning that it
does not have a dependency on database backups, and instead queries the live
database to make decisions about garbage collection.

The initial proposal for online garbage collection is documented in
[MANTA-3347](https://smartos.org/bugview/MANTA-3347).  This RFD includes
content directly from the ticket, with additional context and considerations
for the proposal.  It also includes multipart uploads and a discussion of other
steps in the garbage collection pipeline, which were not addressed in the
ticket.


## Background

### Object Storage in Manta

Manta exposes a namespace not unlike the UNIX virtual file system.  Directories
may be created, each of which may contain either objects, or further nested
directories.  Objects are analogous to files, except that they can only be
created by storing the entire contents at one time as an atomic operation.  Once
stored, they may only be deleted or replaced with another wholesale PUT
operation.

The Manta object namespace is represented in a database.  Each path (either
object or directory) is represented as an entry in the `manta` bucket.
This database is split into some number of isolated shards, to increase
performance and maximum object count.  All of the entries representing paths
in a particular directory are co-located within one shard, allowing us a
coherent sort of the entries in that directory by either name or creation time.


### Snap Links

Manta also supports "snap links", where a particular Manta object is linked
(e.g., using the `mln` command) to another Manta path.  The internal structure
of Manta is a bit like that of a traditional UNIX file system.  While paths are
visible to the user, these paths are really just pointers to a particular
backing data file which has a unique numeric identifier (cf. the UFS `inode`).
Creating a snap link is an `O(1)` operation, analogous to creating hard links
with the `link(2)` system call.  To link an existing object at a new path, a new
metadata entry is created which refers to the same underlying object ID as the
original path.  The fact that a particular Manta path cannot be modified except
to replace it wholesale, an operation which does not affect the backing file, is
the chief functional difference between traditional hard links and Manta snap
links.

### Deleting or Replacing Manta Objects

When an object is deleted from Manta, or an object is replaced by a new object
at the same path, an entry is created in the `manta_delete_log` Moray bucket
on the same shard for which the object's entry in the `manta` bucket exists.
This is done so that the `manta` entry may be deleted atomically, in the same
transaction as the creation of the `manta_delete_log` entry.  These entries
chiefly consist of the object ID of the backing data file (stored in Mako zones)
and the wall time of the deletion.

Because of snap links, metadata entries that point to the same object ID may
exist in many directories throughout the Manta namespace.  While paths in the
same directory are stored in the same shard, paths in another directory may be
in an different shard.  As a transaction cannot span multiple shards, it is not
feasible to track the number of existing references to any particular backing
file.  In order to know when it is safe to delete a particular backing data
file, we must perform garbage collection after the fact.


### Multipart Uploads

Manta supports an additional interface to create objects via the multipart
upload API, described in detail in
[RFD 65](https://github.com/TritonDataCenter/rfd/tree/master/rfd/0065).  In short,
multipart uploads allow users to upload an object in parts, then "commit" the
object when all parts have been uploaded, exposing the object in Manta at the
path of the user's choice.

Associated metadata and parts for ongoing multipart uploads are stored in the
top-level directory tree `/:account/uploads`.  A given multipart upload's parts
are stored in its _parts directory_, which is of the form:
`/:account/uploads/[0-f]+/:uuid`, where the uuid refers to the multipart upload's
ID.

For example, for a multipart upload with uuid
`d5cdf46c-ef9f-6186-ae5a-9b2ef163ff43` under the account `jhendricks`, the parts
directory might be:

    /jhendricks/uploads/d5c/d5cdf46c-ef9f-6186-ae5a-9b2ef163ff43

And it might have parts such as:

    /jhendricks/uploads/d5c/d5cdf46c-ef9f-6186-ae5a-9b2ef163ff43/0
    /jhendricks/uploads/d5c/d5cdf46c-ef9f-6186-ae5a-9b2ef163ff43/1
    /jhendricks/uploads/d5c/d5cdf46c-ef9f-6186-ae5a-9b2ef163ff43/2

The parts directory is a Manta directory, with a corresponding entry in the
`manta` bucket on the relevant shard.  The parts stored in the parts directory
are normal Manta objects, with entries in the `manta` bucket on the relevant
shard.  As normal Manta objects do, the parts have a backing data file in some
number of Manta storage zones, provided the multipart upload has not yet been
committed.  When a multipart upload is committed, these parts are deleted
locally from the storage zones after creation of the new object, but the
associated metadata information still exists.

When a multipart upload is "finalized" --- that is, committed as an object or
aborted by the user --- an entry in the `manta_uploads` bucket is created.  This
record, called the "finalizing record", is inserted atomically on the same shard
as the new object record is created (or would be, in the case of an abort).  The
presence of the finalizing record indicates that a multipart upload has been
finalized, and its associated data --- its finalizing record, parts directory
record, part records and their backing data files --- are thus eligible for
garbage collection.


### Existing Offline Garbage Collection

Garbage collection is performed, at present, by software in the
[Mola](https://github.com/TritonDataCenter/manta-mola) consolidation.  That repository
contains an
[overview](https://github.com/TritonDataCenter/manta-mola/blob/master/docs/gc-overview.md)
of garbage collection and some deeper discussion of the
[design](https://github.com/TritonDataCenter/manta-mola/blob/master/docs/gc-design-alternatives.md)
and possible alternatives.

#### Object Garbage Collection

In short, the daily offline garbage collection process is roughly as follows:

- take full dumps of each shard, using the PostgreSQL `pg_dump` tool
- a Manta job reads the dumps and groups together all entries in the
  `manta_delete_log` and `manta` buckets by the object ID to which they refer,
  and then determines if the delete log entries refer to backing files that no
  longer have live paths in the Manta namespace
- a process in the "ops" (Mola) zone removes all `manta_delete_log` entries
  that were processed correctly
- a process in each "storage" (Mako) zone tombstones backing data files (named
  by object ID) that are no longer referenced
- after the tombstome period, a process in each "storage" (Mako) zone removes
  the tombstoned files from disk

Records in the delete log are not processed until a grace period has passed.
The expectation is that if a `manta_delete_log` entry is several days old, and
there are no longer any active references in the `manta` bucket to the object
ID in question, it is safe to delete the backing data file.  The grace period
helps to account for the fact that the database dumps cannot be taken at exactly
the same time across all shards, as well as for the possibility that a snap link
creation operation was in flight at the time of the dump.

#### Multipart Upload Garbage Collection

Garbage collection for multipart uploads has a similar process to the normal
offline garbage collection.  To summarize:

- take full dumps of each shard, using the PostgreSQL `pg_dump` tool.  (This
  step is shared with normal garbage collection.)
- a Manta job reads the dumps and groups together all entries in the
  `manta_uploads` bucket and entries in the `manta` bucket under the top-level
  directory `/:account/uploads` by their multipart upload ID.  Entries in the
  `manta` bucket are only included if their multipart upload has a corresponding
  entry in the `manta_uploads` bucket.
- a process in the "ops" (Mola) zone removes parts and upload directories of
  finalized multipart uploads from the front door of Manta, then removes all
  `manta_uploads` entries directly from Moray.
- part directories and parts removed from the front door are garbage collected
  via the object garbage collection process

Similar to normal garbage collection, entries in the `manta_uploads` bucket are
not processed until a grace period has passed.  The grace period for multipart
uploads functions differently than for normal objects:  Once a multipart upload
is finalized, all related Moray records for it can be safely removed, but having
a grace period allows end users to verify that a given multipart upload has been
finalized for the duration of the grace period.  This is useful, for instance,
if the response from the front door of Manta was lost from the client's
perspective.


### Problems with existing garbage collection

The existing garbage collection system has many problems, much of which have
been documented in other resources.  RFD 16
[notes](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0016/README.md#problems-with-the-existing-implementation)
that the pipeline is brittle, not very observable, and doesn't handle all errors
well.

The other key issue this RFD attempts to address is problems with using database
backups as a critical step in the system.

TODO: mako gc, moray cleaner


## Proposal

### Principles

There are several guiding principles to the proposed design of online garbage
collection.  They are:

- Correctness is the first priority above all.  Even a minuscule possibility of
  garbage collecting data that should not be deleted is unacceptable.  More
  concretely: No objects that have references in the metadata tier should be
  deleted, and no data associated with multipart uploads that have not yet been
  finalized should be deleted.
- Delete all data that should be within a reasonable timeframe.  (But when faced
  with the choice of potentially deleting data that should not be or not
  deleting data that should be, choose to not delete the data to preserve
  correctness.)
- The service should be observable by operators.
- The service should be tunable by operators, at the least to adjust its impact
  on the system as needed.
- The service should have a clean upgrade path, including managing its potential
  co-existence with the existing offline garbage collection processes.
- The service should be designed such that it will function with only one
  instance of the service, but should also be designed such that it is safe to
  deploy more than one instance of it.  TODO: explain potential concurrency
  benefits, as well as safety aspect in case something is accidentally deployed?

TODO: reference eng guide for ideas here?

### Online GC service

This RFD proposes a new long-running program, deployed as an SMF service, either
in a new zone or the same zone as the online auditing system proposed in [RFD
112](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0112/README.md).  (If the
service were to be deployed in a new, separate zone, then it should be a SAPI
service; see the "Open Questions" section below TODO).  The program should be
designed such that it is safe to deploy more than one instance of the service
in Manta, but this proposal is designed such that only one instance of the
service is required to function.

Having the program run within an SMF service gives several advantages.  Since
this is a long-running program, SMF can manage monitoring and restarting the
service if it crashes.  It also allows us to use SMF amon (TODO: link) alarms on
the service, such as opening an alarm if the service goes into maintenance,
which could indicate that GC is not running in Manta.

The proposed service's primary goal, for the scope of this RFD, is to replace
the offline system that determines which objects should be deleted from the
system.  This step is perhaps the most complex piece of the garbage collection
pipeline, but there are also other steps: carrying out the deletion of metadata
records, backing data files for objects, and tombstoning data prior to deletion.
All of these steps can be generally replaced by functions in the new service.

The proposed service's key functions are:
- online garbage collection of objects in the `manta_delete_log`
- online garbage collection of multipart uploads in the `manta_uploads` bucket 

### Online GC pipeline summary

The existing garbage collection system is a pipeline, in which output from each
phase is passed to the next.  In general, the online GC system will preserve the
same pipeline, but address issues with each step in the pipeline.

The proposed pipeline is:
- the online GC service collects a list of objects to delete
- the online GC service deletes these objects from Moray
- the online GC service deletes these objects from Mako

TODO

### Deleting objects from Mako

TODO

#### Delete log processing pipeline

TODO

#### Mulitpart upload processing pipeline

TODO


### Online delete log processing

The new service will be responsible for processing deleted and overwritten
objects, using the `manta_delete_log` as its source of input for potential
objects to clean up.  Recall that an entry to the `manta_delete_log` is added
when an object is overwritten or deleted.  An entry in the delete log means it
is now _possible_ that no further references to the object exist.  Recall that
the online system can query shards directly for information about object
references, instead of operating on database backups.

#### Example scenarios

To illustrate how this process should work, we will walk through how we could
verify a single entry in the delete log was safe to delete.  Let's suppose there
is an object with ID _A_ in the delete log on shard _N_ in a Manta that has
three shards: _L_, _M_, and _N_.

First, we need to verify that there no references to _A_ on any shard in the
system.  We can make requests to all other shards to verify that there are no
references to _A_ for live objects: that is, no entries in the `manta` bucket
that refer to _A_.  If any references are found, it is not safe to delete _A_.
If none are found, this means that _A_ might be safe to delete.  The reason this
is not guaranteed is because shards are inherently distributed; there is no way
to atomically ask all shards to do any operation, including checking for
references to _A_.

This is one order of events in our example system in which _A_ would be
incorrectly marked as being safe for garbage collection using only the
verification steps above:

1. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
2. Shard _L_ replies that it has no reference to object _A_.
3. A snap link request creates a link to _A_ on shard _L_.
4. Shard _M_ replies that it has no reference to object _A_.
5. GC concludes that there no references to _A_ on any shard (even though there
is still a reference to _A_ to shard _L_).

To account for in-flight snap link requests, as we see in the example above, we
can adopt a strategy from offline garbage collection: a grace period.  The grace
period should be long enough to allow in-flight requests to complete across any
Muskie in the fleet.  It probably should be tunable; see "Tunables" below (TODO:
local link?)

After allowing the grace period to expire, we need to again check for references
to _A_ on all shards to see if any snap link requests occurred since
verification began.  If any shard has a reference to _A_ in the `manta` bucket,
then _A_ is no longer a candidate for deletion, and we should remove it from the
`manta_delete_log` of shard _N_.  If none find any references, then _A_ might be
a candidate for deletion, but the problematic scenario from the first round of
checks is not solved by the grace period.

This is one order of events in our example system in which _A_ would be
incorrectly marked as being safe for garbage collection using only the
verification steps so far:

1. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
2. Shard _L_ replies that it has no reference to object _A_.
3. A snap link request creates a link to _A_ on shard _L_.
4. Shard _M_ replies that it has no reference to object _A_.
5. GC waits for the grace period _T_ to pass.
6. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
7. Shard _M_ replies that it has no reference to object _A_.
8. A snap link request creates a link to _A_ on shard _M_.
9. An object DELETE removes the reference to _A_ on shard _L_.
10. Shard _L_ replies that it has no reference to object _A_.
11. GC concludes that there no references to _A_ on any shard (even
though there is still a reference to shard _L_).

As we can see, the crux of the problem with verifying that there are no
references to an object is the distributed nature of it; there is not an atomic
way to capture a global snapshot of the metadata.  The fact that links can
"walk" between shards without being captured in the GC's systems snapshot view
of all all shards is referred to as
["The Walking Link Problem"](https://github.com/TritonDataCenter/manta-mola/blob/master/docs/gc-design-alternatives.md#the-walking-link-problem)
in the GC Design Alternatives document.

So we need a way for a shard to indicate to the GC process that an object that
is a candidate for deletion has been touched in a snap link operation _after it
was determined by GC to be a candidate for deletion_.  Given that we need this
functionality on a per-shard basis --- as discussed, there is no way to do a
global operation on all shards --- an obvious way to do so is by creating a new
bucket on each shard where objects that are candidates for garbage collection
can be marked after the first round of reference checks.  We will call this new
bucket `manta_gc`.

In order for this strategy to be correct:

- the GC service must also check for references to objects in this new bucket
  as well as the `manta` bucket after it has done its first round of checks for
  references to the object on all shards
- snap link requests should make an update to the `manta_gc` bucket when forming
  a snap link that indicates to GC that an object deletion candidate has been
  used in a snap link

Let's suppose the GC service uses the `manta_gc` bucket as a list of possible
objects to delete, and when making snap link requests to Moray, Muskie also
issues a delete request to the `manta_gc` bucket for the object ID atomically
with the link's insertion into the `manta` bucket.  When the GC
service does its second round of checks after the grace period, it will also
check for references to the object in the `manta_gc` bucket.  If it _does not_
find an entry for the object, then this means a snap link was created in between
the first and second round of checks.  If an entry is found for all shards, then
it is safe to delete.

Thus, for our example object _A_, the following series of steps would lead to
its garbage collection:

0. GC observes object _A_ in the `manta_delete_log` bucket of shard _N_.
1. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
2. Shard _L_ replies that it has no reference to object _A_.
3. Shard _M_ replies that it has no reference to object _A_.
4. GC writes an entry in the `manta_gc` bucket on shards _L_ and _M_ (and waits
for the write to successfully complete).
5. GC waits for the grace period _T_ to pass.
6. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
7. Shard _L_ replies that it has no reference to object _A_.
8. Shard _M_ replies that it has no reference to object _A_.
9. GC asks shards _L_ and _M_ whether they have an entry for _A_ in the
`manta_gc` bucket.
10. Shard _L_ replies that it has an entry for _A_ in the `manta_gc` bucket.
11. Shard _M_ replies that it has an entry for _A_ in the `manta_gc` bucket.
12. GC concludes that _A_ can be safely deleted.

Now let's see how the problematic scenario from before would play out using this
strategy:

1. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
2. Shard _L_ replies that it has no reference to object _A_
3. A snap link request creates a link to _A_ on shard _L_.
4. Shard _M_ replies that it has no reference to object _A_
5. GC asks shards _L_ and _M_ to create an entry for object _A_ in the
   `manta_gc` bucket and waits for their successful reply.
5. GC waits for the grace period _T_ to pass.
6. GC asks shards _L_ and _M_ whether they have any references to _A_ in the
`manta` bucket.
7. Shard _M_ replies that it has no reference to object _A_
8. A snap link request creates a link to _A_ on shard _M_ in the `manta` bucket
**and removes its entry in the `manta_gc` bucket**.
9. An object DELETE removes the reference to _A_ on shard _L_ from the `manta`
bucket.
10. Shard _L_ replies that it has no reference to object _A_ in the
`manta`bucket.
11. GC asks shards _L_ and _M_ whether they have an entry for _A_ in the
`manta_gc` bucket.
12. Shard _L_ replies that it has an entry for _A_ in the `manta_gc` bucket.
13. Shard _M_ replies that it *does not* have entry for _A_ in the `manta_gc`
bucket.
14. Because object _A_ has been removed from a shard's `manta_gc` bucket, GC
concludes that it is not safe to delete, and removes the entry from the delete
log of shard _N_.


#### Online delete log processing summary

The following is a more succinct summary of the process described above.

**Online delete log processing algorithm**

For each shard, for each entry in its delete log:
- Query all other shards using `FindObjects` to check the `manta` bucket for
  entries that refer to the object ID for this delete log entry.
  - If a reference is found, the object is not safe to be deleted. Remove the
    delete log entry and stop here.
  - If no reference is found, this object _may_ not be referenced; move to the
    next step.
- On each shard, write the object ID into the `manta_gc` bucket.
  - Wait for a grace period to expire, to catch a Muskie snap link transaction
    that overlapped with our write to `manta_gc`.
- In each shard, check again that there are no references in the `manta`
  bucket to the object ID.
  - If a reference is found, this object is not safe to be deleted. Remove the
    delete log entry and all `manta_gc` entries, and stop here.
  - If no reference is found, this object _may_ not be referenced; move to the
    next step.
- On each shard, check that the object still exists in the `manta_gc` bucket.
  - If the object still exists in the `manta_gc` bucket of every shard, the
    object can be garbage collected.
  - If the object has been removed from the `manta_gc` bucket of any shard,
    this object is not safe to be deleted. Remove the delete log entry and all
    `manta_gc` entries, and stop here.


The grace period in this process can be much shorter than the grace period from
the existing offline process.  It exists merely to catch the following race
condition:

```
                                                           |
  [MUSKIE] ---- START ---- PUT manta ------ DEL manta_gc --|------ COMMIT --->
                                                           |
                                                           |
  [GC] --------------- START --- PUT manta_gc ---------- COMMIT ---------->
                                                           |

  --- time --->
```

We use the `READ COMMITTED` transaction isolation in most Moray operations,
which means each new command in a transaction can see data committed prior to
the start of that particular command.  In the timing diagram above, the `INSERT
INTO manta_gc` would not be visible until _after_ the `DELETE FROM manta_gc`
that Muskie performs.  Using a grace period that is much longer than we ever
expect the Muskie transaction to run, followed by another check for entries in
`manta` is one possible mitigation.  There may be others; e.g., inspecting
inflight transactions to ensure no overlap, or possible coordination with the
Muskies themselves.

**Muskie snap link changes**

For the above algorithm to work, Muskie must be modified to perform the
following pair of operations in a transaction when snap linking an object:

- the existing `PutObject` that creates the snap link path entry in `manta`
- a `DeleteObject` request to remove the object ID from `manta_gc`


#### Format of `manta_gc` entries

This section will document the schema for the `manta_gc` bucket.

At a minimum, each entry will need:

- object ID to be collected (indexed)
- uuid of GC process
- time of check in manta bucket
- size

TODO


### Online finalized multipart uploads processing

In addition to processing entries in the delete log, the service will be
responsible for garbage collecting data associated with committed or aborted
multipart uploads.  Conceptually, this is a much more straightforward problem
than online delete log processing. The relevant shards for a given multipart
upload are fixed; there is no possibility of "walking links" as there are with
Manta objects.

The basic algorithm for multipart upload garbage collection, given a finalizing
record, is:

1. Remove all parts for the multipart upload (metadata records and backing
data).
2. Remove the parts directory (metadata record).
3. Remove the finalizing record (metadata record).

TODO MANTA-3350 discussion

**Online multipart upload processing algorithm**

For the process below, if at any point there is a non-retryable error besides
the equivalent of a "record not found error", the process should stop for the
multipart upload. The expectation is that there should not be errors for this
process that are not indicative of problems elsewhere in the system that may
require operator intervention regardless.

TODO explain above better

For each shard, for each entry in its `manta_uploads` bucket:
- Query the shard containing the parts for the multipart upload, using
  `FindObjects`, to find all part records for the multipart upload.
- Issue a `DELETE` request to the front door of Manta for all parts.
- Delete the parts directory from the relevant shard using `DelObject`.
- Delete the finalizing record from the relevant shard using `DelObject`.

TODO

### Tunables

The service should be tunable by operators, at the least to reduce load on the
system if it is possible it is making a bad state of the system worse.

The following are the proposed tunables:
- flag to turn delete log processing off for all shards
- flag to turn multipart upload processing off for all shards
- grace period for delete log processing
- grace period for multipart upload processing
- tune the number of concurrent delete operations ongoing

It may also be desirable to disable delete log processing and/or multipart
uploads processing for a subset of shards.  This may be useful for similar
reasons that the global flags are useful, including a shard under heavy load or
undergoing maintenance in which more load on the shard is not desirable.

TODO


### Alarms

TODO

### Tooling and Observability

TODO
- want: way to see the last ID gc'd
- how much space will be freed up after current grace period
- current grace period
- some of these may go into the metrics section
- number of candidates for deletion

### Metrics

The garbage collection program will expose metrics using the
[node-artedi](https://github.com/TritonDataCenter/node-artedi) library.  In particular, we
should collect:

TODO

## Repositories Affected

The following repositories will require changes:
- garbage collection code will be added to _manta-mola_, or perhaps a new
  repository
- _manta-muskie_: must be changed to properly delete entries from `manta_gc`
  table on changes
- _libmanta_: used to install `manta_gc` bucket

TODO

## Public Interface Changes

Garbage collection is an internal housekeeping process that should not be
visible to end users.  In general, this RFD does not propose any public
interface changes.

That said, there is one public API change that was introduced to expedite
multipart upload garbage collection: the ability for operators to delete parts
and upload directories from the front door of Manta.  This was introduced in
[MANTA-3350](https://smartos.org/bugview/MANTA-3350) and should not be
needed after online garbage collection is deployed.  We may want to consider
removing this change to simplify API complexity.

## Private Interface Changes

TODO

## Upgrade Impact

TODO

### Flag day between online GC and Muskie

There is an important flag day between the online GC service deployment and
Muskie: It is critical that *all* Muskie instances in a system contain the
updates to its handling of snap links in order for the GC delete log process to
work correctly.

TODO


## Security Impact

Given that garbage collection is solely an internal process, there is no
expected security impact of this project.

## Open Questions

- Should online GC be shipped in its own zone? If not, which zone? Candidates
  include the existing "ops" zone and a with the online auditing system proposed
  in RFD 112.

TODO
