---
authors: David Pacheco <dap@joyent.com>, with input from Joshua Clulow, Alex Wilson
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

# RFD 143 Manta Scalable Garbage Collection Plan

## Introduction

This RFD describes a set of projects that can be delivered in a phased approach
to address several goals:

- Significantly reduce the work required for garbage collection in the most
  common case of objects having no snaplinks.
- Enable the optimized path to be used in existing deployments without modifying
  data in cases where operators can manually confirm the absence of snaplinks.
- Enable garbage collection in Manta deployments where full-shard backups cannot
  be completed on a regular basis.  The basis for this is described in [RFD
  123](../0123/README.md).

This document does not obviate [RFD 123 ("Online Manta Garbage
Collection")](../0123/README.md).  The project described in RFD 123 is part of
the plan described in this RFD.


## Background

**Manta garbage collection and snaplinks**  In Manta, garbage collection ("GC")
refers to the process of cleaning up data associated with objects that have been
removed from Manta.  Because of Manta's support for snaplinks, when the system
processes an API request to delete an object, it is not possible for the system
to know whether the last reference to the object is being removed.  In the case
that a user has created a snaplink `B` from an object `A`, then the object
itself cannot be deleted until both `A` and `B` have been removed.  When only
`A` or `B` is removed, the GC process sees the removal but takes no action,
seeing another reference to the underlying object.  When the other link has been
removed, then GC needs to clean up the associated object.  This needs to work
no matter the order and timing that `A` and `B` are removed.

To address this, the system records the delete request into a delete log.  A
separate process later scans these logs, determines which objects' data can be
cleaned up (because they're not referenced elsewhere), and then executes the
cleanup.  This process is referred to as garbage collection.

**Garbage collection today.**  Today, the GC process requires periodic backups
of metadata databases.  These backups include the delete log itself (which is
stored in the database), plus the set of all objects referenced in the database.
With this information, the system runs a job to find any references to deleted
objects, filter out such objects, and schedule the rest of the objects for
cleanup.  This process is fairly straightforward, but somewhat expensive to run.
Since the process needs to look for references to each object across all
database dumps, the time required increases with the number of objects stored in
Manta.

## Proposed improvements

### Online garbage collection

RFD 123 proposes a process for _online garbage collection_, which refers to
executing this process continuously using the live databases rather than
periodically using batch jobs on database backups.  The primary advantage is
that this would not require the system to create full backups on a regular
basis, nor scan the whole database every day.  It could take advantage of
indexes already provided in the database for the fields it needs to query on.

However, online garbage collection still requires a number of database
operations _on each shard for each object deleted_.  There are likely ways to
mitigate the impact, and definitely ways to control it, but this is still a lot
of extra work to do, and that work competes for resources with the Manta data
path.

### Accelerated GC for objects with only one link

The above approaches to GC are expensive and complex because of the need to
determine for each deleted link whether the underlying object has other links
referencing it.  But while snaplinks are very useful for many use-cases, the
vast majority of objects in most Manta deployments are never snaplinked.  We
propose modifying the data path so that Manta can tell when an object is being
removed that has never had a snaplink created from it.  In that case, instead of
recording the delete to the delete log, it would be recorded to a new table
that's used for accelerated deletion (see 'Accelerated Delete Table').  A new
component would periodically read entries from this table and immediately queue
objects for deletion, rather than going through the expensive part of the GC
process.

The essence of the mechanism is as follows:

- When new objects are created, they are created with a new top-level metadata
  field called `singlePath` with boolean value `true`.
- Whenever a snaplink `B` is created from an object at path `A`, before the new
  metadata entry is created for `B`, the metadata for `A` is modified to remove
  the `singlePath` property (or set it to `false`).
- Whenever any object is removed, if its metadata has `singlePath == true`, then
  for each copy of the object, a row is created in the accelerated delete table.
  There is no row created in the existing delete log table.
- A new component periodically scans entries in the accelerated delete table and
  generates instructions for both storage zones and Moray shards that are
  identical to those generated by the existing GC mechanism.

Note that instead of a new component generating instructions similar to the
existing GC pipeline, we could consider a component that runs _inside_ each
storage zone and processes these deletes.  This is simpler in a sense, but means
that the number of Moray connections and database requests would scale up more
aggressively with the number of storage zones.  It would also make it more
difficult to control the amount of load applied to the databases from this
process, since the configuration of hundreds or thousands of components would
need to be updated.

This scheme was initially proposed under
[MANTA-3347](https://smartos.org/bugview/MANTA-3347).  However, it's largely
orthogonal to online GC.  In particular, this mechanism can be implemented
before or after online GC, and it would likely handle the vast majority of
cases, whether or not the online GC project had already been integrated.

### Accelerated GC for existing objects

The scheme proposed above for accelerated deletion requires that a new bit of
information be stored with new objects.  Existing objects won't have this bit,
and the system will have to assume for safety that these objects may have other
references in other shards.  This means that even after the above has been
implemented and deployed, all existing objects would have to be cleaned up via
the traditional GC mechanism.

There are existing Manta deployments with large amounts of data for which we
would like to take advantage of the accelerated delete mechanism.  In these
cases, it is believed that snaplinks have not been used at all within the
accounts that want to take advantage of the accelerated GC mechanism.  This
suggests another way to trigger accelerated GC:

- Add support for an operator-controlled per-account flag to disable snaplinks
  for the account.
- Add support for an operator-controlled per-account flag to indicate that the
  account's metadata has been checked and verified to contain no snaplinks.
- Modify Manta so that when an object is removed in an account with both of
  these flags set, cleanup runs through the accelerated delete flag described
  above.

This approach enables the accelerated GC option to be used for an account that
already has a lot of object data that the user wants to delete, provided that an
operator can verify that there are no snaplinks in the account.  This puts a
significant burden on the operator, since incorrectly setting this flag could
result in data loss, where an object was removed when it was still referenced.
Real business situations exist where we believe this can be verified reliably
and it would be worthwhile to do so.

#### Accelerated Delete Table

As described in the previous sections, the accelerated delete mechanism will
keep track of objects deleted in a new table called `manta_fastdelete_queue`.
We propose the following Postgres schema for this new table

```
                                      Table "public.manta_fastdelete_queue"
  Column   |     Type     |                                   Modifiers
-----------+--------------+--------------------------------------------------------------------------------
 _id       | bigint       | default nextval('manta_fastdelete_queue_serial'::regclass)
 _txn_snap | integer      |
 _key      | text         | not null
 _value    | text         | not null
 _etag     | character(8) | not null
 _mtime    | bigint       | default ((date_part('epoch'::text, now()) * (1000)::double precision))::bigint
 _vnode    | bigint       |
Indexes:
    "manta_fastdelete_queue_pkey" PRIMARY KEY, btree (_key)
    "manta_fastdelete_queue__etag_idx" btree (_etag) WHERE _etag IS NOT NULL
    "manta_fastdelete_queue__id_idx" btree (_id) WHERE _id IS NOT NULL
    "manta_fastdelete_queue__mtime_idx" btree (_mtime) WHERE _mtime IS NOT NULL
    "manta_fastdelete_queue__vnode_idx" btree (_vnode) WHERE _vnode IS NOT NULL
```

This schema differs from the `manta_delete_log` in that we omit the `objectId`
column (and its corresponding index). We opt to include the object id of the
deleted object in the `_key` column of the table instead. The `_key` column
will now contiain entries like this:
```
objectid/manta_storage_id
```
This sort of identifier is unique under the described scheme because:
1. Object ids are unique
2. Any rows inserted into `manta_fastdelete_queue` must have had no snaplinks
when they were removed from the `manta` table

(2) implies that a row in `manta_fastdelete_queue` can be neither a delete
record for a snaplink nor a delete record for an object that could at some point
be snaplinked to a different path (that object id will never be in the manta
bucket again). It follows from (1) that all insertions into
`manta_fastdelete_queue` will have unique `_key` values under the proposed accelerated
delete mechanism.

The `_value` column of the table will store the same contents as the
identically named column in `manta_delete_log` does. Crucially, these contents
include

1. The `manta_storage_id`s of the sharks on which the object is located
2. The the uuid of the account that created object

These two pieces of information are needed to identify the backing file for
the object on a Mako. For context, the backing file is stored at the following
path on some subset of the Makos:

```
/manta/<creator-uuid>/<object-id>
```

We choose to keep the remaining contents of `_value` because they may be useful
in the future. Further, `manta_fastdelete_queue` is unlikely to ever grow that
much since it is processed continuously by a new component described in the
next section. The suggests that any space gains that might come from paring
away at the contents `_value` column would likely be minimal.

#### Moray Fast Delete Component

We couple the new `manta_fastdelete_queue` with a component that periodically
reads delete records added to the queue and makes arrangements for the
corresponding objects to be garbage collected.

This component performs a function roughly analagous to the existing GC job that
reads unpacked database dumps from `/posiedon/stor/manatee_backups` and
uploads Moray and Mako instructions to Manta for later processing. There are two
main functional differences between the existing GC and the proposed component:

1. Instead of reading unpacked database dumps, this component will periodically query
   the `manta_fastdelete_queue` to learn about recently deleted objects.
2. Instead of generating Moray instructions, the new component will first upload
   Mako instructions for the deleted objects to Manta and, on success, delete the
   corresponding rows from `manta_fastdelete_queue`

There is a case that is not covered by (1) or (2) above which at first appears
to leak `manta_fastdelete_queue` entries. If the components reads an entry from
`manta_fastdelete_queue`, uploads an instruction to Manta, and then crashes,
then there may be a row in the `manta_fastdelete_queue` that corresponds to an
object that doesn't exist anymore. This is fine as long as the process removing
backing files on Mako nodes ignores delete requests for objectids that don't
exist. We can simply restart the new delete component and process the entry
again.

Function (1) described above requires that the fast delete component be able to
interface with Postgres. Broadly, there are two options

* We can connect to the Postgres primary directly (as the Manta Resharding
   system does)
* We can point the node-moray client at Moray (as the existing offline GC
   system does)

Technically we could also point the node-moray client at electric-moray (as
Muskie does today). However, this component has no need for routing and so
introducing the extra network roundtrip is probably unnecessary.

We choose to use the Moray interface since it is the component used to create
`manta_fastdelete_queue`. Using the node-moray client will also allow us to
leverage the work done to improve cueball queueing. Additionally, using a
collection of node-moray clients affords us the option of tuning the subset of
Moray shards that a given (or all) garbage collectors poll for new records.

Function (2) can be accomplished with the node-manta client API.

##### Tuning/Control

We'll want the ability to alter the behavior of the new garbage collection
component to mitigate impact to the datapath or speed up
`manta_fastdelete_queue` processing when necessary. Additionally, we may want
to avoid polling certain shards that might be undergoing maintenance operations
or are otherwise unresponsive. To these ends, the garbage collection component
should allow an operator to do the following:

* Pause/resume a garbage collector
* Get/set the subset shards that a given worker polls for new delete records
* Get/set the polling batch size (how many records are read from
  `manta_fastdelete_queue` per database transaction)
* Get/set the polling concurrency (how many outstanding `findobjects` are allowed at
  a time)
* Get/set the delete batch size
* Get/set the delete concurrency
* Get/set the Manta upload concurrency (for uploading Mako instructions).
* Get/set the cueball target and maximum connection count
* Get/set the cueball recovery spec options

We can expose these options via a restify server in a manner similar to that of
the Manta Reshard system. We may consider exposing some of these options on a
per-shard basis, though we should balance the number of tunables we expose with
the complexity of the API to avoid configurations that result in performance
pathologies.

We'll determine the default configuration of the tunables with performance
impact testing on SPC-like hardware.

## A concrete plan

We have described a number of possible improvements that can be implemented in
many possible orders.  Some are unrelated, while others address overlapping (but
not identical) parts of the problem.  We propose the following plan to maximize
short-term value and minimize wasted effort:

1.  Construct a procedure to confirm the absence of snaplinks within a Manta
    account (or Manta deployment).  This procedure must be safe and low-impact to
    run on very large scale production systems.
2.  Using this procedure, verify that the production systems in question have no
    snaplinks.  (If they do, this whole plan needs to be reconsidered in light of
    the specific usage of snaplinks.)
3.  Implement support for setting, storing, and reading the per-account flags to
    disable snaplinks and confirm that they do not exist.
4.  Implement support for actually disabling snaplinks when the corresponding
    flag is set.
5.  Implement schema changes for the new table of accelerated GC operations.
    (These schema changes should be automated by the software, with no impact to
    production, since it's just creating a new Moray bucket.)
6.  Implement the component to read items from the accelerated GC table and write
    out instructions for Mako and Moray cleanup.
7.  Modify the Moray cleanup process to handle the new type of instruction.
    (Some consideration may be required here to avoid a flag day with the
    existing Moray GC component.)
8.  Modify the Muskie path for object removal to honor these flags and use the
    accelerated delete mechanism.
9.  Modify the Muskie path for object creation to include the new "singlePath"
    field.  Modify the path for object removal to honor this new field as well.
    (Note that this should not require schema changes, since we do not need to
    be able to query directly on this field.)
10. Implement the rest of the "online GC" project (RFD 123).

In terms of deployment, in each deployment where this issue is important, we would:

1. Deploy the changes for the account flags.
2. Set the flag to disable snaplinks on the account.
3. Verify one more time that there are no snaplinks on the account.
4. Set the flag that indicates that an operator has verified that there are no
   snaplinks in the account.
5. Deploy the rest of the changes required for the accelerated mechanism to work.
   (This could likely happen at any time, since without the above flags, this
   process won't be used.)
6. Deploy the rest of the online GC project when ready.

## TODO

- write up list of components that need to be changed (including repositories)
- write up how users and operators will interact with this
- write up changes to public, private interfaces
- write up upgrade impact
- write up security impact
