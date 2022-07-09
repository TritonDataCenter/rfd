---
authors: David Pacheco <dap@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+112%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 112 Manta Storage Auditor

This RFD proposes a new Manta subsystem for:

- auditing data stored in Manta without daily backups of either the metadata
  tier or the storage tier ("online auditing")
- assisting in a process for garbage collection that will not rely on daily
  backups of either the metadata tier or the storage tier ("online GC")
- maintaining real-time statistics about storage used on a per-storage-zone
  basis

While these problems appear largely orthogonal, we believe the same components
will be in a position to implement much of this functionality, so we propose
this together.

## Background

Today, Manta employs several housekeeping processes, all encapsulated in the
[Mola](https://github.com/TritonDataCenter/manta-mola) repository.

- **Auditing**: Data integrity is the single most critical goal for Manta.  Each
  day, the audit process looks for any files that are missing from the storage
  nodes where they're expected to be, which would indicate a data integrity
  problem.  Successful completion of the audit job gives us confidence that
  Manta retains copies of the data it's supposed to be storing.
- **Garbage collection**: This process identifies and removes files for objects
  that have been removed from Manta.  As much of the data in Manta churns (i.e.,
  newer data replaces older data), it's critical to clean up old space.
  Efficient use of storage capacity requires that deleted data be cleaned up
  relatively quickly.
- **Cruft identification**: This process identifies and removes data that's been
  left around by Manta, usually as a result of bugs in the data storage
  pipeline.  (This job is not run automatically, but can be run _ad hoc_ by an
  operator.)  In a sense, this is the complement of the audit process: this
  looks for files that are present on the storage nodes when they should not be.  

(There are other housekeeping processes, but they are not relevant for this RFD.)

There is also an important, missing piece of Manta functionality: physical
storage reporting.  Specifically, running a space-efficient (and therefore
cost-efficient) Manta deployment requires up-to-date information about the
overall physical space used as well as the physical space used on a per-account
and per-server basis.  Additionally, since Manta retains deleted data for some
number of days as a precaution, it's also important to have up-to-date
information about the physical space scheduled for removal on a per-day basis
for however long this data is retained.  (Physical space usage is very different
than the logical space usage reported by Manta's metering subsystem primarily
because of built-in ZFS compression.)  Manta does not support physical storage
reporting out-of-the-box today, but the
[manta-physusage](https://github.com/TritonDataCenter/manta-physusage) tools are sometimes
used to generate limited reports on an _ad hoc_ basis.

Each of these processes (auditing, garbage collection, cruft identification, and
physical storage reporting) currently relies on daily backups of either the
metadata tier, the storage tier, or both:

| Function                   | Requires metadata backup? | Requires storage manifest? |
| -------------------------- | ------------------------- | -------------------------- |
| Auditing                   | Yes                       | Yes                        |
| Garbage collection         | Yes                       | No                         |
| Cruft identification       | Yes                       | Yes                        |
| Physical storage reporting | No                        | Yes                        |

To implement these pieces, there are a few bash scripts that execute daily
(driven by cron(1)) in each storage zone:

- `upload_mako_ls.sh`: traverses the entire set of Manta files in this storage
  zone, producing a report of the logical and physical space used for each one.
  This is the aforementioned storage manifest.
- `mako_gc.sh`: executes the part of garbage collection that happens in each
  storage zone.  This involves two phases.  The first phase processes
  instructions from the GC jobs to "tombstone" individual files that correspond
  to objects that have been deleted.  This process moves these files from
  visibility, putting them into per-day tombstone directories as a precaution.
  The second phase removes old tombstone directories.

## The problems

First of all, the housekeeping processes are primarily implemented in terms of a
number of Manta jobs and other small scripts executed by cron(1) at predefined
times.  These jobs and scripts are generally
[unobservable](https://smartos.org/bugview/MANTA-2593), do not handle many
operational errors well (see
[MANTA-3311](https://smartos.org/bugview/MANTA-3311),
[MANTA-3316](https://smartos.org/bugview/MANTA-3316), and
[MANTA-3317](https://smartos.org/bugview/MANTA-3317)), and perform or scale very
poorly (see [MANTA-3325](https://smartos.org/bugview/MANTA-3325) and
[MANTA-3085](https://smartos.org/bugview/MANTA-3085)).  These issues are
themselves painful and costly for both engineering and operations, but even
worse is the problem that if some process fails or just takes longer than
expected, operators must manually diagnose the problem and then re-run that part
of the pipeline _and_ subsequent stages.  When delays don't result in outright
failures (for processes that pick up the last available output, regardless of
what day it came from), poor timing means that processes that should take only a
day instead wind up taking as long as a week instead.  When this happens to
garbage collection in a highly utilized deployments, it makes a moderate
operational crisis substantially worse.  While steps have been taken to avoid
running such highly utilized deployments, future forecasts and an eye towards
cost efficiency suggest that we'll likely always be concerned about physical
space management at high levels of utilization.

Many of the above problems are documented in [RFD 16](../0016/README.md).  That
RFD proposes a job scheduling system to address many of the job-related issues,
but it would not change many of the various cron-based scripts that make up the
rest of these processes.

And as costly as those problems are, recent experience has demonstrated more
substantial challenges with the scalability of the existing architecture.  It's
becoming increasingly clear that daily backups of the metadata tier are not
tenable for two reasons:

- Database backups, which today are executed on the async peer of a
  [Manatee](https://github.com/TritonDataCenter/manatee) cluster, significantly impact the
  performance of the database and can compromise its ability to keep up with
  incoming replication data.  When the async peer falls behind, the availability
  of the shard is compromised because any takeover operation would be blocked on
  the peer catching up, which can take an arbitrarily long time.  (It has been
  considered that we back up from the synchronous peer, which -- assuming we're
  able to address [MANTA-3283](https://smartos.org/bugview/MANTA-3283) -- would
  at least avoid the availability risk, though it would still likely have a
  significant negative performance impact.)
- Database backups on even moderately-sized shards can easily take upwards of 24
  hours, meaning that we cannot perform these important processes each day.  We
  could run them less often, but even that would require non-trivial work, and
  it's not clear that there's an upper bound on how long they may grow to
  require.

It's possible that we could address these issues by reducing the size of each
database, but this would have other implications, likely significant, since
optimal database size is a highly-dimensional problem.  It would be valuable to
decouple the ability of these houskeeping processes to run at all from a
dependency on database size.

As for the storage tier backups: on large deployments, these can take anywhere
from 1 to upwards of 24 hours, resulting in many of the same problems.  While
the current implementation can likely be sped up considerably, there's still a
gross inefficiency in scanning the entire contents of the filesystem (the vast
majority of which has not changed at all) every day.


## Goals

For auditing, our goal is that the following checks are performed on a regular
basis for all objects in Manta:

- cheap data integrity check: each physical copy of the object exists as a file
  on disk with the correct size
- comprehensive data integrity check: each physical copy of the object has the
  right checksum
- cheap metadata integrity check: metadata exists for all parent directories for
  the object

We would like to be able to configure two periods:

- the period over which cheap data integrity and metadata integrity checks are
  run for all objects in Manta (e.g., a day)
- the period over which expensive data integrity checks are run for all objects
  in Manta (e.g., a week)

The idea is that over the course of one such period, we check all objects within
Manta, and we should be able to tell relatively cheaply what the oldest
un-checked object is.


## Proposal

We propose three major pieces:

1. A new mechanism for auditing the contents of Manta without the need for daily
   backups of the metadata tier or storage tier.  This would be driven by a new
   service with state stored in the metadata tier itself.
2. A new component to live in each storage zone to keep a cached summary of
   metadata for that storage zone.  This component enables fast answers to
   questions about physical space used on a whole-zone, per-account, or
   per-tombstone-day basis, as well as to questions about the presence of files
   on the system.  With modest integration with the new auditing system, this
   component can also easily identify cruft, making it the primary piece in an
   online cruft system.
3. A new mechanism for online cruft detection.  This isn't high priority, but
   is easy to add with these other two pieces.

### Online Auditing

For online auditing, the goal is to have a component sweep through the entire
"manta" table on each metadata shard, auditing each entry that it finds.  When
the entire table has been audited, it would start another sweep.  The system
would control the speed of the sweep (by adjusting concurrency or pausing
between entries) so that the time taken for each sweep matches some tunable
parameter (e.g., a day).

There are a few pieces to this:

- sweeping through the table
- auditing each record
- reporting any problems

#### Sweeping through metadata

For audit coverage, we want that:

- an object whose metadata is not changing is audited at least once per audit
  period (e.g., once per day or once per week)
- an object that has been around for at least as long as the audit period is
  always audited
- ideally, newly-created objects would also be audited, but it's okay if objects
  whose total lifetime is less than the audit period are never audited

To sweep through the "manta" Moray bucket, we propose adding a new string field
called "timeAuditSweep" to the "manta" bucket.  By default, this field would be
null (both for rows that predate this column as well as for newly-created
metadata).  When the auditor completes auditing an entry, it updates
"timeAuditSweep", setting it to an ISO 8601 timestamp of the current time.  To
find the next set of entries to audit, the auditor queries Moray for objects in
the "manta" bucket sorted in increasing order of "timeAuditSweep".  It would
also separately query for objects with null values of "timeAuditSweep".  This
allows the auditor to balance auditing of least-recently-audited entries and
newly-created entries according to whatever parameters it wants.

Alternative approaches:

- Create one very long-running transaction for auditing.  This transaction would
  select all rows, auditing each one as it's returned from the database.  Since
  this transaction would be open for the duration of an entire sweep, any
  transactions that modify the table would force PostgreSQL to create dead
  tuples, and those tuples could not be cleaned up until a vacuum runs that
  starts after the sweep transaction is closed.  This seems likely to result in
  a lot of table bloat and associated issues.
- Scan through the table using multiple queries like above, but based on some
  existing field (like `_id`).  If the field is mutable (like `_mtime`), it
  would be easy to miss records that were updated during the sweep.  For
  example, for a daily sweep sorted in increasing order of `_mtime`, a record
  that gets updated daily early in the day but before the sweep gets to it could
  easily be missed every day (because with each update, it's effectively put at
  the back of the queue, which is never really reached).  `_id` could
  conceivably work for this.  However, having "timeAuditSweep" as a first-class,
  searchable column allows us to quickly verify the health of this mechanism,
  which has traditionally proven quite valuable.


#### Auditing each record

To audit each record, we would find the storage zones that are supposed to have
copies of this object and contact a new service on those zones to audit the
object.  That service would report whether the file exists, its current size,
and any other properties that we may find useful (e.g., the last verified md5
sum of the object).  This component is described below, but critically, this
information would generally come from a metadata cache that can answer this
question quickly.

The auditor only needs to verify that each of the storage nodes returns a
result, that the sizes match what's expected, and potentially that the md5sums
match what's expected.

Additionally, the auditor could check that the entry's parent metadata exists.


#### Reporting results

It's important that we be able to quickly summarize outstanding integrity
issues.  And as new issues are detected and old ones are repaired, we should be
able to see that in the results without having to complete another full scan.
It's also important to keep in mind that we expect never to have very many of
these issues.  Putting this all together, we propose that we store errors from
the audit job into a new Moray bucket called "manta\_audit\_errors" on shard 1
(_not_ sharded).

Upon completion of an audit, the auditor checks to see if there are any audit
error records for this metadata entry already.  If the audit found no problems
and there were error records already, then the auditor would remove the error
records from the table.  If the audit did find a problem, and there was already
an error record, then it would bump a counter and update a timestamp in the
existing error record so that we can see that this happened more than once.  If
there was no previous error record and the auditor found a new error, then it
would insert a new error record into the table.

Any time the table is modified (to insert a new error record, update an existing
one, or remove an existing one), the auditor would log a bunyan audit log entry
so that we can clearly find the full of history of any audit errors.

Regardless of whether the audit found any issues or not, the auditor updates
"timeAuditSweep" on the metadata record to a relatively current timestamp so
that it won't see it until it's audited all other records.  If the original
metadata record no longer exists, the auditor should attempt to remove the audit
error that it previously inserted (since the object no longer exists).


#### Auditor scalability

In principle, the audit process is highly scalable because auditing each record
is orthogonal to auditing every other record.  To the extent that the auditor
has any local state at all, it can be reconstructed from the state in the
"manta" and "manta\_audit\_errors" tables.

Because the "manta" table is already sharded, and the entries for
"manta\_audit\_errors" are always for metadata from a particular shard, it would
be trivial to support at least as many auditors as there are metadata shards.
The process could likely be scaled out even further (to support more than one
auditor per shard) using a two-phase approach to sweeping: instead of querying
for the next set of records to audit, each auditor marks the next set of records
for itself (using a new field) and then fetches the records it just marked.
This ensures that the auditors are working on disjoint records.  This would
allow large numbers of auditors to be applied to a shard.

However, based on the work the auditor is doing, it's not expected that we will
need more than one or two Node processes, even for large deployments.  We
propose creating two by default just to make sure the multi-auditor case is
tested regularly.  These instances would be configured to audit disjoint shards.


#### Auditor availability

In general, auditing is invisible to end users.  If it doesn't run for a few
minutes, hours, or even days, there's no consequence as long as there's not an
additional data integrity issue, and that issue will be found once the auditor
is back online.  If an auditor were down for an extended period, a new one could
be provisioned elsewhere and pick up where the first one left off.  For these
reasons, it seems unnecessary to provide multiple instances for availability.

However, clearly the auditor should identify cases where it's competing with
another auditor for the same records, and with that feature in place, it seems
easy to just allow multiple auditors to run, with one of them backing off if it
detects a conflict.


#### Tooling and observability

There will be a tool to report audit errors.  It essentially scans the new
bucket containing the audit errors and prints out each one.  This tool will exit
0 if there were no errors and non-zero otherwise.  There will be an Amon probe
that executes this tool to raise an alarm if there are any audit errors.

There will be a tool to mark a metadata record as un-audited (to trigger an
immediate audit).

If it seems useful, there may be a tool to mark a metadata record as audited (to
cause the auditor to skip it).

The auditor will provide a kang entrypoint and node-artedi-based metrics
describing the number of records audited, successes, failures, and the time of
the oldest record not yet processed.


#### Operational issues

* **Falling behind:** We'll want to monitor the progress of the auditor.  With
  the proposed fields, we can easily identify the least-recently-audited object
  (or the oldest-never-audited object), and we should alarm on that.
* **Storage nodes down for extended periods:** We likely don't want to produce
  audit errors if we cannot contact a particular storage node.  (This happens
  often enough that we need to handle this first-class.)  Instead, we need to
  keep track of the fact that we haven't audited some objects, move on, and try
  later.
* **Going haywire:** Bugs can cause systems like this to incorrectly generate
  tons of bad output.  We may want a circuit breaker of sorts that says that if
  a large number of errors are produced in a short period, we stop and raise an
  alarm.


### Storage auditor

We also propose a new service to run inside each storage zone, tentatively
called the storage-auditor.  The storage-auditor would be responsible for
maintaining a cache of metadata for the files stored in that zone.  We envision
this being a sqlite database with one main table, with one row per local file.
The row would include:

- the file's path,
- the Triton account uuid for creator of the object
- the object uuid
- whether it's tombstoned,
- the object's logical size,
- the object's physical size,
- the object's creation time,
- the object's modification time,
- the last time the above data was collected,
- the md5sum of the object,
- the last time the md5sum was calculated, and
- the last time the object was audited by the online auditing system

There would be a separate table of statistics describing:

- a scope, which would either be an account uuid or a tombstone directory
- the number of objects in that scope
- the sum of logical sizes of these objects
- the sum of physical sizes of these objects

**Auditing:** With the above information, the storage auditor can quickly
respond to queries from the online auditing system, as described above.  When
responding to these requests, it should update the last audit timestamp of the
record.

**Cruft:** This component can identify cruft by looking for objects audited
longer ago than the oldest audit timestamp in the metadata tier.  We can extract
the set of cruft objects by:

- searching all shards for the earliest timeAuditSweep value
- taking the earliest of all of these
- looking for objects in all storage auditors' caches whose last audit time was
  prior to this timestamp.  We probably want to add a grace period to this
  interval to account for GC's grace period

**Cache coherency:** This would be a non-authoritative cache.  All of the above
information is reconstructible from the filesystem state except for the
timestamp of the last audit, which is not so critical.  In fact, the component
should periodically scan the entire filesystem to verify that this information
is complete.  (Like the auditor, it will have some target period -- perhaps a
day or a week -- and seek to scan the whole filesystem in that time.  As we gain
confidence in the cache's correctness, we can tune this period to be quite
long.)

Assuming this cache were populated initially from a full file scan, there are
only a few common operations that would need to modify it:

| Operation         | Component    | Details             |
| ----------------- | ------------ | ------------------- |
| file create       | nginx        | PUTs of object data |
| tombstone         | `mako_gc.sh` | Move files from live area to tombstone after they've been GC'd |
| deletion          | `mako_gc.sh` | Unlink files from the tombstone area |
| MPU part deletion | nginx        | mako-finalize |

There are other cases to consider as well:

- operator intervention, including both creation and deletion of files.  Files
  can be removed accidentally or as part of emergency space cleanup.  Files can
  be created as part of undoing previous accidental losses.
- the cruft job, which may remove files
- the rebalance job, which may create and remove files

The cruft and rebalance jobs can be modified to update the cache, but the
possibility of operator intervention or other software bugs reinforces that we
should periodically re-scan the entire filesystem even if practical experience
confirms our hope that we don't need to do this very often.


**Garbage collection:** the `mako_gc.sh` steps could be incorporated into this
component.  That would not require much work, it would provide the opportunity
to address many issues with that script, and it would allow us to ensure that
this cache is kept up-to-date for these operations.  Additionally, online GC
will almost certainly benefit from having a component that it can invoke to GC
an object rather than relying on the batch system used for `mako_gc.sh` today.

The file creation part is a little trickier.  This happens inside nginx.  We
could:

- write an nginx module that keeps the database up-to-date directly, though this
  would potentially limit the concurrency of PUTs.  It's not clear if this would
  be a measurable bottleneck, though, since it's 1-2 (small) database updates
  per PUT.
- write an nginx module that pokes the cache to update itself.  This would avoid
  the concurrency problem, though the cache would need to have a bounded-size
  queue, and if it couldn't keep up with the workload, then it will never become
  up to date.  This also has to deal with the cache being offline or slow,
  presumably by skipping the update.
- have the cache use the file events monitoring (FEM) API in the OS to notice
  when new files have been created.  This decouples the data path from the
  cache, which is likely preferable.

Importantly, if the auditor is asked about a file that it does not know about,
then it would go fetch the information immediately, and synchronously with
respect to the request (except for the checksum).

The checksum field would likely be managed differently than the rest of the
fields because it may be very expensive to compute.  This field could be
recomputed on a much less frequent basis.



## Summary of changes

* Online Auditor:
   * New software component (including repo, SAPI service, and SMF service) for the
     Online Auditor.
   * New un-sharded Moray bucket `manta_audit_errors` on shard 1, initialized by
     the new auditor.
   * New indexed column in sharded Moray bucket `manta` called `timeAuditSweep`.
     This would likely be initialized by libmanta or the new auditor.
   * New non-indexed columns in Moray bucket `manta`: `lastAuditor` (uuid of the
     auditor that audited it) and `timeAuditChecksum` (the timestamp when the
     checksum was last audited, which is presumed to be potentially older than
     `timeAuditSweep`).  These would be written by the new auditor and preserved by
     other libmanta consumers.
   * A private Node library for observing the auditor, including printing out audit
     errors.
   * A CLI tool exercising the above library.
* Storage auditor:
   * New software component (including repo, SMF service) living inside the
     existing storage zone
   * CLI tools for interacting with the cache: invalidating entries, adding
     entries, suspending scan, resuming scan, etc.


## Related problems

This proposal does not address the problem of online storage metering (i.e.,
generating per-account reports of _logical_ storage used for use by end users
and for billing end users).

There is an outline of a proposal for online garbage collection (i.e., GC that
does not require daily backups of the metadata tier) in
[MANTA-3347](https://smartos.org/bugview/MANTA-3347).  This largely describes
the operations required to make it work, not the components required.  That
outline assumes a component that lives in each storage zone that actually
tombstones removed objects and later removes the tombstoned objects.  Today,
that could be the aforementioned `mako_gc.sh` script, or it could be the
new component described here.

## Open questions

* Are the proposed new indexes really okay?  Are writes to the whole table once
  per day okay?
* What should we do if a storage node is down for an extended period?  (This
  isn't as uncommon as we would like.)  It can obviously skip particular entries
  for now, but how does it avoid seeing the same entries when it queries
  PostgreSQL for the next batch?  One option would be to use a secondary sort by
  `_id` when scanning for the next entries to audit.
  This relates to what we do when only a few storage zones haven't been updated,
  too.
* Should audit results (and scans) be based on path or objectid?  Objectid is
  what we're actually checking on the storage servers, and there's no sense in
  re-auditing an objectid twice just because it has two paths.  On the other
  hand, there aren't usually many links for the same objectid, so that wouldn't
  be a big deal, either.  Also, it's conceivable that two metadata records could
  have the same objectids and different sharks.  This would be a bug, but the
  audit process should avoid relying too much on the integrity of the system
  it's trying to validate.
* How will configuration work?  Ideally, auditors would divvy up the shards
  among themselves.  How could we make sure they don't stomp on each other?
* Should the storage auditor checksum the object when asked to by the online
  auditor, or should it do so with some lesser frequency on its own and have the
  online auditor just report the older of the checksum timestamps?
* How will the online auditor discover that a particular storage zone does not
  support online auditing (as opposed to it just being down)?
* Do we want to be more precise about what "timeAuditSweep" means?  Do we want
  to distinguish between timeAudited, timeAuditSwept (in case we skipped it),
  timeAuditedWithChecksum, etc.?  That's a lot of indexes.

There are several pieces we probably want to de-risk early in the project:

- See the questions above about the new database indexes and writes.
- Will the storage-auditor be built in Node?  (Bias should be yes, but it can be
  hard to get much concurrency for filesystem operations in Node.)
- How large would a sqlite database for a typical production node be?  How long
  would it take to build?  How many writes per second can it do, and how would
  that compare to writes that our production systems actually do?



## RFD Basics

### User interaction

End users will not interact with this feature at all.

If things go well, operators will not interact with this feature at all.  If an
audit issue is detected, they will see an Amon alarm whose knowledge article
will refer them to the CLI tools that will identify the problems.  Since audit
errors usually represent a bug in Manta or some errant process having removed or
modified files behind Manta's back, action will likely require engagement from
support, operations, engineering, or someone else able to dive into Manta
internals to investigate the issue.

### Repositories affected

* new repository for the online auditor
* new repository for the storage auditor
* joyent/sdc-manta will be updated to deploy the new auditor
* joyent/manta-mola will be updated to disable (and possibly remove) the
  existing audit and cruft jobs.  We may keep them around for a while to deal
  with upgrade (see below).

### Public interfaces

No end-user public interfaces are changing.

Operators will see a new stable command-line tool for understanding audit
errors.  They will also see new artedi-based metrics for the auditing systems.

### Private interfaces

The new "manta\_audit\_errors" bucket is essentially a new private interface.
It will have a rigid schema validated with JSON schema, both on the way in (from
the tools that consume it) and on the way out (for the auditor that writes
records into it).

The new fields in the "manta" bucket represent an extension to the existing
private interface.  They do not change the semantics of any existing fields, and
older software will ignore the new fields.

The new storage auditor component will expose private HTTP APIs to fetch basic
stats and state about itself, to fetch the information about a particular file,
to invalidate the cache entry for a file, and to enumerate objects not audited
since some particular time in the past (a list of likely cruft).

This component will also consume the existing inputs to `mako_gc.sh`.

### Upgrade impact

Once the updated storage zone is deployed, the cache will begin populating, and
it will start executing the job previously done by `mako_gc.sh`.  This will be
invisible to the rest of the system.  Once the cache is populated, up-to-date
metrics will be available from the cache for this storage zone.  The new
component will also deploy SRV records for itself, allowing the auditor to
discover which storage zones support online auditing.

Once the online auditor is deployed for the first time, it will deploy whatever
new buckets and fields it needs to Moray and reindex the "manta" table.  In
parallel, it will attempt to discover all storage zones that support online
auditing.  Once all of them do, it will begin auditing, and it will indicate
that the legacy audit job should be disabled.

The new "ops" zone's crontab entry for auditing will attempt to determine if the
online auditor is available based on looking for its SRV records and querying it
to determine if the legacy audit job should be enabled.  If so, it will kick off
the job like it does today.  If not, it will skip the job.  (There's no actual
problem with having both audits running at the same time.)

### Security impact

This RFD does not propose delivering any interfaces available to end users.

There are private interfaces delivered by this project that expose new
information or new potentially destructive operations (e.g., tombstoning an
object or removing a tombstoned object).  Like the rest of Manta, these
interfaces are exposed unauthenticated over trusted networks.  Long-term, RBACv2
plans to authenticate and authorize these operations, and there is nothing about
this API that makes this appear more difficult than for any other APIs.
