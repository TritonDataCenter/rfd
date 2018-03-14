---
authors: Jan Wyszynski <jan.wyszynski@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/84
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent Inc.
-->

# RFD 125 Online Schema Changes in Manta


## Overview

This RFD will propose an online schema change system for Manta.

A schema change in Manta is a modification to any part of the database structure
that Moray is aware of. This includes, but is not limited to: tables, sequences,
and indexes.

As we scale Manta to handle heavier workloads, we may find it necessary to
change these schemata to consolidate storage or improve data-path performance
and availability. We cannot predict all changes we may have to make in the
future. For this reason, we should have a system for making such changes in
production Manta deployment with minimal performance impact and no service
disruption.


## Background

### Moray

Moray provides a key-value interface to Postgres, serving a role similar to that
of an ORM. Buckets are implemented as tables and objects are implemented as rows in
those tables. While buckets and objects are two key points of interest to a
consumer of the Moray API, Moray also deals directly with indexes, sequences, and
triggers.

#### Indexes

It's important to distinguish between a Moray index and a Postgres index. In
Moray, indexes in a bucket are represented as a json object. These objects are
stored in the `index` column of the `buckets_config` table, that indicates which
fields of a bucket should have Postgres indexes in the corresponding table. Each
key in this object maps to a column name, and the body is an object that specifies
the type of values in the column, in addition to other properties such as whether
the index should enforce uniqueness. The full AJV schema for Moray indexes is
defined
[here](https://github.com/joyent/moray/blob/master/lib/schema.js#L277-L292).
Moray maintains a mapping from 'Moray
types' such as 'string', 'ip', and 'number', to 'Postgres types' such as 'TEXT',
'INET', and 'NUMERIC'. These type mappings also specify what index
implementation to use for fields of the corresponding types. The mapping is
defined
[here](https://github.com/joyent/moray/blob/master/lib/types.js#L20-L71).

Indexes are used to implement efficient object search and uniqueness constraints
for certain endpoints in Moray's API. They are generally defined on bucket
creation. Indexes may be created later, but doing so will require objects that
existed in the bucket prior to the index creation to be re-indexed. Reindexing
can be an expensive operation which locks out writes to the target bucket.

Currently, Manta's Moray uses `BTREE` indexes on single top-level fields. There
are other types of indexes exposed by Postgres including multi-column or
'composite' indexes, partial indexes, and indexes on expressions. These other
index types are not currently leveraged by Moray.

#### Sequences

Each Moray bucket created via the Moray API with a corresponding `SEQUENCE`
named `<bucket-name>_serial`. This sequence is used to assign increasing
integer ids to objects in the bucket as they are inserted.

The implementation of Moray currently includes a mechanism that allows an
operator to observe the order in which two requests happened by comparing the
values of `_txn_snap` for two rows in a bucket. These values are drawn from a
single-row table called `<bucket-name>_locking_serial` using the Postgres
`SELECT FOR UPDATE` mechanism, and updated with an incremented value after a new
object is inserted or updated. It's unclear whether this feature is used in any
Manta deployments.

#### Triggers

When speaking about Moray and Postgres, it is important to distinguish between
Moray's notion of a trigger and the similar concept in Postgres. Moray's buckets
API gives the consumer the ability to define arrays of javascript functions called
`pre` and `post` in the configuration of a bucket. These chains of function are
executed in the Moray node process before and after any operation on that
bucket.

#### Moray#updateBucket

Moray has an API for updating a bucket schema. Morays definition of a bucket
schema includes a set of indexes, and two arrays of functions to run before and
after any operation on the bucket. Currently, the index set is in one-to-one
correspondence with the bucket columns. The Moray update bucket route works by
accepting a new desired schema and making whatever changes necessary to bring
the bucket to it's new schema. This translates into add or dropping columns,
and/or creating regular or unique indexes.

The proposed changes in MORAY-424 show some limitations of this approach. In
particular, these operations all acquire numerous locks and run within a
transaction. In some cases, such as dropping an index, performing this operation
in a manner less disruptive to incoming load would require executing some SQL
queries outside of a transaction.

There are two general approaches for dealing with this. The first is we try to
defer schema change work to periods where they are less likely to disrupt
incoming traffic. We may be able to leverage a canary mechanism to direct load
away from shards that are running this differed work. The second method is to
implement schema updates by creating new tables to replace those defined by
previous schema.

### Postgres

#### Indexes

As described in the corresponding Moray section, Postgres tables in Manta only
have single-column btree indexes. Postgres offers other index implementations
including 'Hash', 'GiST', and 'GIN'. Due to the definition of the mapping
between Moray types and Postgres types referenced above, Postgres zones in Manta
do not currently leverage any of these alternatives.

Indexes impose an additional time cost on all object put and update operations
because the on-disk format must be updated to maintain btree balance. Indexes
grow over time and can result in significant space overhead that is generally a
function of the correpsonding relation size. Indexes can also slow down routine
`VACUUM` operations, as they also accumulate dead-tuple metadata which must be
re-claimed.

Indexes on tables are currently created serially, inside a transaction, near table
creation time. Standard index builds lock out writes (but not reads) to the table
to which the new index will belong. Currently, there is no automated method for
dropping indexes in the Manta source. Dropping indexes is even more disruptive
as it acquires an exclusive lock on the corresponding table. Index changes to
tables that already have rows require `REINDEX` operations. `REINDEX` operations
may also be necessary to consolidate space in a bloated index that has a lot of
sparse pages.

#### Triggers

Postgres triggers are SQL routines that run at configurable points during the
lifetime of an operation on a given table. Currently, we employ a single trigger
called 'count_directories' on the manta table. The definition of this trigger is
as follows:
```
count_directories AFTER INSERT OR DELETE ON manta FOR EACH ROW EXECUTE PROCEDURE
count_manta_directories_v3()
```
At a high level, this trigger is used to udpate a count, the `entries` column, of
the number of metadata records in Manta with `_key` fields whose dirname
corresponds to a given `_key` in the `manta_directory_counts` table.


### Manta Schema Definitions

Existing database schema creation, deletion, and modification (with
the exception of the creation of the 'buckets_config' table) requests pass
through Moray. This is a consequence of the more general design of Manta, in
which all Manta traffic directed towards Postgres is mediated by Moray. Requests
involving such modification fall into two categories:
1. Changes initiated by an operator.
2. Changes initiated by Manta proper.
The first category includes requests that alter the structure of buckets
created by the operator via the Moray buckets
[API](https://github.com/joyent/moray/blob/master/docs/index.md#buckets). Such
changes can be targeted at any element of the database schema, and will
generally be invoked from an operator script, or on the command line with the
tools provided in the Moray repository.

The second category includes requests that originate from the Manta source
itself. Such requests are generally creation requests that occur early in the
lifetime of a Manta deployment and are required for the stable operation of the
object store. At no point and under no circumstances does an end-user of Manta
alter the layout of the database. All requests that pass through the front-end
loadbalancers are targeted at the Manta table.

Currently, database schemata are defined in a number of places in Manta. These
include:
* 'node-libmanta', which
[defines](https://github.com/joyent/node-libmanta/blob/master/lib/moray.js#L37-L91)
the layout of the 'manta', 'manta_delete_log', 'manta_upload', and
'manta_directory_counts' tables and their indexes.
* The 'manta-minnow' configuration file, which
[specifies](https://github.com/joyent/manta-minnow/blob/master/etc/config.coal.json#L3-L15)
sourcethe layout of the 'manta_storage' table and its indexes.
* 'manta-reshard', the automated resharding system for Manta, which
[defines](https://github.com/joyent/manta-reshard/blob/master/lib/data_access.js#L13-L39)
the 'manta_reshard_plans' and 'manta_reshard_locks' tables.
* 'manta-medusa' which
[defines](https://github.com/joyent/manta-medusa/blob/master/lib/control.js#L379-L390)
the 'medusa_sessions' table to track active mlogin sessions.
* The Moray setup script, which
[creates](https://github.com/joyent/moray/blob/master/boot/setup.sh#L297-L299)
the 'buckets_config' table.
* 'manta-marlin', which
[defines](https://github.com/joyent/manta-marlin/blob/master/common/lib/schema.js)
defines the schemas for all jobs-tier buckets.

### Tickets and Prior Work

There have been a number of circumstances in which we have found it necessary to
modify data schemata in our production environment:
* [MANTA-3399](https://jira.joyent.us/browse/MANTA-3399) describes the
performance impact of low-cardinality indexes such as
`manta_directory_counts_entries_idx`. Low-cardinality `BTREE` indexes become
flat, resulting in little search-time improvement and significant update cost.
Under such circumstances, it would have been beneficial to have a tested system
for dropping indexes.
* [MANTA-3401](https://jira.joyent.us/browse/MANTA-3401) addresses the potential
for the `manta_dirname_idx` index to become a low-cardinality index due to the
lack of MPU GC. The ticket also references
[MANTA-3169](https://jira.joyent.us/browse/MANTA-3169), which documents a
pathological directory listing performance due to query plans that scan
`manta_dirname_idx` and then sort the resulting set based on another field. We
might address such cases by creating composite indexes that support sorted
traversal.
* [MORAY-425](https://jira.joyent.us/browse/MORAY-425) proposes support for
composite indexes to adress the use-case described in the previous ticket.
* [MORAY-424](https://jira.joyent.us/browse/MORAY-424) proposes support for
disabling Moray indexes to adress the use-case described in MANTA-3399.
It is clear from these examples that we can expect to change our database schema
over time.

## Proposal

The following proposal is limited in scope to the implementation of Moray and
Postgres. We understand a 'schema change' to be any update in the schema
configuration for a bucket that Moray is aware of. In the discussion, we use the
term 'schema' to refer to the abstract
[definition](https://github.com/joyent/moray/blob/master/lib/schema.js#L277-L327)
of a bucket from Morays perspective. In Manta, these definitions
correspond to rows in the `buckets_config` table in a Postgres database.

### Constraints

There are several constraints that limit the both types and implementation
avenues of schema changes.

#### Performance and Availability

1. Schema changes must be performed 'online'. This means that they should not
   require planned downtime.
2. Schema changes should not have prolonged and significant impact on the
   performance of the Manta data-path.

#### Compatibility

1. Schema changes must be atomic with respect to inbound requests to a
   particular shard. If a shard transitions from schema A to B, requests must
   use either schema A, or schema B.
2. Schema changes should be transactional with respect to inbound requests.
   Requests should not fail before, after, or during the transition. If a schema
   change fails to transition from schema A to B, the shard should revert to
   using schema A.
3. Schema changes must not cause request failures due to incompatibility. If a
   shard transitions from schema A to B, no request sent after the transition should
   fail because it depends on schema A.
4. Morays that are able to make certain kinds of schema changes should be able
   to run alongside Morays that cannot make those changes.
5. All Moray processes in a shard should be able to detect that a schema change
   is going on and should be able to read the new schema after the change is
   complete.

### Interface

The system proposed in this RFD is intended to be available to operators of a
Manta deployment only. We may consider adding an API function to node-libmanta,
or require that operators make whatever API calls are necessary using cli tools
from a Moray zone. No end-user facing interfaces would change under the proposal
in this RFD. It is not clear at this time what the exact interface for changing
database schemata will look like.

### Upgrade Impact

Leveraging the system in proposed in this RFD would likely require a Moray image
upgrade. We have no reason to think that incremental changes adding new possible
schema changes would increase upgrade complexity. Under the proposal described in
this RFD, the initial Moray image upgrade would trigger a schema change of the
`buckets_config` relation itself to add the proposed fields. For this reason,
all of the Moray processes in a single shard would need to be restarted with an
updated Moray image at the same time.

### Security Concerns

Changes to database schema have strong implications for how requests are
serviced in Manta. Exposing the metadata layer to software-initiated structural
changes can lead to all sorts of nasty bugs including dangling references, and
service denial issues stemming from demanding too many long-running CPU and I/O
intensive schema changes. The latter class of issues can present itself as a bug
in virtually any other Manta component that depends on low-latency Postgres
queries.

While the proposed system is intended to transition the database schema from one
state to another, unexpected states may arise due to failures in the transition
function itself. A system for changing the layout of data on disk is a system
for introducing untested schemata that may be detrimental to Manta's performance.

The changes proposed in this RFD would be exposed to operators only, but we
should provide ample safeguards to prevent against schema changes that could
severely disrupt and or hinder the datapath.

#### Extensibility

1. It should be easy to introduce new possible schema changes.
2. It should be easy to temporarily disable and enable possible schema changes.

#### Concurrency

1. Concurrent schema changes that leave the database in an undefined
   state should not be allowed.
2. If concurrent changes are allowed, there must be a means by which to limit
   the table contention they cause.

### Potential Schema Changes

In the current implementation, a bucket schema from Morays perspective consists
of the following fields:

* `name` the name of the bucket
* `index` a json object describing the set of indexes that the bucket has
* `options` a json object
    * `version` the current version of the bucket
    * `trackModification` it is unclear currently how (or if) this option is
      used in Manta. It is not documented in the Moray buckets API, nor does
      it seem to have a substantial effect on the Moray datapath.
    * `guaranteeOrder` describes whether objects should be written with a
      `_txn_snap` field which can be used to deduce the order in which rows
      were inserted into the bucket post hoc.
    * `syncUpdates` - also currently does not seem to be used in Manta.
* `pre` an array of javascript functions for Moray to execute before performing
  an operation on this bucket.
* `post` an array of javascript function for Moray to execute after performing
  an operation on this bucket.
* `mtime` a timestamp indicating the last time the bucket configuration was
  modified.
Each of these fields should be considered candidates for schema changes.

From the perspective of Postgres, the are a number of other schema changes we
might potentially be able to make. Some of these may overlap with the above.
* Dropping an index.
    * A standard `DROP INDEX` operation takes an exclusive lock on the
      associated relation, making it infeasible in a production environment.
      Such an operation would also need to run in a transaction. For this
      reason, we can only consider `DROP INDEX CONCURRENTLY`.
    * We cannot drop unique indexes or primary keys concurrently.
* Creating an index.
    * A standard `CREATE INDEX` operation blocks writes, but allows reads.
    * `CREATE INDEX CONCURRENTLY` does not block write operations. Creating an
      index concurrently is implemented as follows:
        * One transaction to add index metadata to system tables.
        * Two table scan transactions each blocking on concurrent transactions
          which may modify the indexes.
        * After the second scan the operation must wait for transactions holding
          snapshots predating the second scan to terminate.
    * An index created concurrently may not be available for immediate use and
      may need to wait for transactions predating the start of the index build
      to terminate.
    * Concurrent index builds may discover constraint violations and will leave
      behind partially constructed indexes. These indexes do not interfere with
      the operation of the database, but may take up substantial disk space.
      Fixing such broken indexes would require retrying the concurrent build, or
      performing an expensive `REINDEX` operation in a transaction.
Concurrent index builds are a fickle, expensive operations that can require
multiple retries and are highly sensitive to an incoming workload.
* Dropping a table column.
    * Without running a `VACUUM FULL` this operation doesn't get rid of the heap
      space taken up by the column, it just marks the column as invisible.
* Adding a table column.
    * This requires an `ACCESS EXCLUSIVE` lock.
* Changing a column type.
    * This requires an `ACCESS EXCLUSIVE` lock.
    * This also updates dependent indexes and table constraints.
* Add/Delete/Alter table constraints.
    * All of these operations require an `ACCESS EXCLUSIVE` lock.
    * Adding and altering a constraint will generally require a
      potentially-lengthy validation period (table scan) at some point.
    * Deleting constraints that depend on indexes will also drop the
      corresponding index.
* Enabling/disabling a trigger.
    * Requires a `SHARE ROW EXCLUSIVE` lock.
    * Does not delete the physical backing for the trigger.

It should be noted that if we choose to support schema changes that affect
fields from both of these sets, we may need to restructure the way a schema is
represented in `buckets_config` itself.

## Possible Implementations

### Buckets Configuration Relation

The `buckets_config` relation is visible to all Morays in a shard and stores the
schemata for all tables in that shard. Since `buckets_config` is itself a table
that can be updated and read using Postgres transactions, it provides one avenue
for implementing a schema change system that meets the compatibility constraints
described in this RFD.

Since the `buckets_config` table is relatively small, even in production
environments, it is feasible to modify its schema without incurring significant
performance penalties.

We could modify `buckets_config` to store the complete bucket schemas in fields
called `prev_schema`, `curr_schema`, and `next_schema` (instead of storing them
in separate columns). `schema_change_sql` could store the sql required to perform
the schema change so that it can be restarted as necessary. The change will take
`next_schema` not being null to indicate that a schema transition is in progress.
`prev_schema` will allow us to rollback a schema change if the transition query
fails. `curr_schema` could include all the information (and possibly more) that
is currently stored in the `name`, `index`, `options`, and `mtime` columns in
`buckets_config`.

Moray processes wanting to initiate a schema transition will manage these fields
accordingly.  When a Moray process wants to change a bucket schema, it will first
check if one is in progress. If not, the Moray process will compute the sql
query necessary to affect the transition. This computation will throw an
exception if the schema change is invalid, or if it is prohibitively expensive
and should therefore be disallowed. If all goes well, the Moray process will
(in a transaction) write the desired schema and sql to the `next_schema` and
`schema_change_sql` fields of the appropriate row in the `buckets_config` table.

Once `buckets_config` is updated, any number of failures could occur:
1. Postgres could fail.
2. The initiating Moray process could abort.
3. The schema change query could fail.
Since we cannot predict any of these happening all other Moray processes must be
able to detect when a schema change has failed, and what must be done to
complete it. The only logically correct way to do this is to track the query
itself, which means we will have to store information about the query process in the
`buckets_config` table as well, allowing Morays to restart the query if it
terminates unexpectedly.

To allow other Morays to pick up and restart failed schema transitions, there
must be some process in each Moray which periodically sweeps the
`buckets_config` table, checking for failed/incomplete transitions.
When a query completes, the supervising Moray process will update the fields
added in `buckets_config` to reflect the new schema.

#### Problems and Considerations

There are some considerations that stand out with this approach. These include:
1. How often should Morays check the `buckets_config` table? With enough entries
   in this table running table scans periodically from each Moray might become
   expensive.
2. What if we accumulate too many long-running schema changes?
3. Should we support canceling a schema change if possible?
4. Should Morays ever check that the schema reported in `buckets_config` matches
   what is really stored in the database? Can these ever come out of sync?
5. What steps may be necessary to ensure that schemas stored in `buckets_config`
   remain in sync with the actual database schemata.
6. Can Moray always know whether a given schema change is expensive?

One of the constraints described in this RFD is that it should be easy to add
schema changes and run Morays that are aware of certain possible schema changes
next to Morays that aren't aware of them. For this reason, we'll need to make
sure that Moray doesn't reject schemas that contain fields that may be foreign
to it. One example of a change that might give rise to this situation is
`pgIndexDisabled`, as proposed in MORAY-424. Some Morays may know about this
schema option, others may not.

One downside of changing `buckets_config` is that it will require Moray changes
to use the new configuration, which doesn't allow a Moray with the schema change
system to run alongside a Moray without it. We could, instead of changing `buckets_config`,
introduce a new one-to-many relation that tracks various schemas for a given
bucket by version number. This would allow us to store a longer history of
bucket schema changes. In terms of implementation details, this method would not
be that much different, though it would require some extra metadata to identify
the target schema for a transition.

### Schema Versioning

Modifying Postgres relations while serving low-latency responses to requests
modifying those tables is border-line intractable due to locking.
One way we might get around this problem is with versioning. For example,
instead of running an expensive and potentially locking operation to add a
column to a table, we might instead create a new table with the desired schema
and divert future incoming traffic to use the new table. Since we'll want to
then access objects written with the old schema, there will have to be a
mechanism for migrating objects to the new table. This could be done using an
on-demand strategy when an object living in an old table is next read.

The `buckets_config` table seems the logical place to start. We may
amend the table with a new column holding some pointer to the current relation
(table name or relation OID, for example). We can cache this value at Moray and
let each process poll `buckets_config` to update this cache so as to
discover schema changes committed by other Moray processes.

When a request reaches a Moray process, the process determines what buckets
are involved in servicing the request. For each of these, the process can look
up the corresponding relation pointers for each bucket in its cache.
It's possible that this will result in less-than-current versions of the
buckets, which implies that some objects might be written to out-dated tables.
As long as added columns have reasonable default values, the on-demand
triggers will take care of migrating objects from old tables to the new tables
when necessary.

#### Problems and Considerations

There are a number of open questions regarding the versioning approach above.
1. Are there always reasonable default values to fill in when migrating an
   object to a table with new columns?
3. Should we allow a schema change for a given table if one is already running?
4. How large of a version history should we maintain, if any?
5. If we use a Postgres trigger to copy an object from a previous table version
   to a new one when it is read, then a read-heavy workload for a large number
   of objects stored in a previous table version becomes a read and double-write
   (one write to create the new row, one to delete the old) workload for those
   objects. Is this okay?
A final question is whether we should delete tables that no longer store any
objects. If we were to implement this, it would have to be part of the Postgres
trigger that migrates an object when it is next read. The trigger would need to
be able to check the size of the table quickly (or at least determine whether
it is zero).

## Further Inquiry

There seem to be two general approaches to addressing schema changes.

One approach is to find existing mechanisms by which we can alter database
objects with minimal service disruption. It should be clear that due to locking
and I/O contention, this approach has serious limitations and may even preclude
some types of changes. The efficiency of this approach will generally be a
function of the size of the objects we try to alter schemas for.

* Immediate further inquiry for this approach involves testing under load to
determine which schema changes are feasible.

The other approach is a versioning approach. Instead of trying to change
existing objects, we create new objects to replace the old ones. This approach
requires careful coordination to ensure that consumers of the Manta continue to
see Manta behave normally except in the cases where the schema change affords
new functionality or is made as part of an intentional API modification.

* Immediate further inquiry for this approach involves testing whether old and new
objects can be synchronized well under load. An important question to answer
here is whether we want active synchronization (long running background
processes) or lazy synchronization (triggers on each new request for records
living in objects with outdated schemata).

With buckets on the horizon ([RFD
  116](https://github.com/joyent/rfd/blob/master/rfd/0116/README.md)), we may
want to consider whether we can generalize the approaches described here to
different datastores. We may also want to factor in schema change feasibility
when evaluating new datastores.
