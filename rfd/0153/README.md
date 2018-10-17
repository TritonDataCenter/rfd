---
authors: Kelly McLaughlin <kelly.mclaughlin@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues/117
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 153 Incremental metadata expansion for Manta buckets

## Overview

The manta *buckets* project aims to add the ability to store objects in manta
using a flat namespace in addition to the hierarchical directory-based storage
currently provided. A named bucket may be created in the context of a user
account and then any number of objects may be stored in the bucket.

The addition of the *buckets* feature provides an opportunity to consider
different operational pain points of the current system and look for
opportunities to address them. One area of pain is in resizing or resharding the
metadata tier. It requires significant investment in new hardware as well as a
good deal of investment of time and operational resources.

This RFD presents a set of ideas that in concert could provide an incremental
approach to metadata expansion that potentially saves money, time, and resources
and allows for expansion with minimal disruption to the service provided by the
system.

## Metadata resizing today

The current metadata resizing process is referred to as metadata resharding and is described
as [RFD 103](https://github.com/joyent/rfd/blob/master/rfd/0103/README.md). The
software created based on this RFD is housed in the [`manta-reshard`](https://github.com/joyent/manta-reshard)
repository.

## Goals

First, it is important to state the overall goals that this proposal attempts to
satisfy. The list is as follows:

* Allow for the addition of new metadata shards to a manta buckets deployment
  with a lower bound on the number of shards that must be added of only one.
* Allow for multiple new metadata shards to be added simultaneously with the
  upper bound of added shards only limited by the maximum number of shards
  supported by the existing system.
* Allow for new shards to be added and incorporated into the system without
  interruption to the availability of the system metadata service and with
  minimal impact on performance. The goal of no service interruption includes
  both read and write requests for data whose ownership must be transferred as
  part of incorporating the new shards.
* Remove the potential for human error where possible.

## Proposal

### Data placement and routing

Manta uses [consistent hashing](https://www.akamai.com/es/es/multimedia/documents/technical-publication/consistent-hashing-and-random-trees-distributed-caching-protocols-for-relieving-hot-spots-on-the-world-wide-web-technical-publication.pdf) and
the concept of virtual nodes (vnodes) to place the metadata for new objects in
the system and to route requests to retrieve metadata for existing objects. The hash
function used by the consistent hashing implementation maps an object key value
to a particular vnode. Each vnode is *owned* by a physical node (pnode) and as
the system grows (*i.e.* new pnodes are added) the ownership of vnodes may be
transferred to the new pnodes. In manta pnodes are known as metadata shards, but
the details of metadata shards are covered in a later section. The data
structure used by consistent hashing is commonly referred to as *the ring*
because the hash function forms a circular keyspace.

The manta component that instantiates and manages access to the ring is
`electric-moray`. Each instance of electric-moray creates its own instance
of the ring. This means that for system correctness it is imperative that each
version of the ring reflects an identical mapping of ownership from pnodes to
vnodes.

Currently, the ownership mapping in the ring changes infrequently and it is
reasonable to manage the process of updating the ring information by updating
each electric-moray instance sequentially. However, it does require that the
vnodes being transferred be placed in read-only mode for the duration of the
transition.

With incremental expansion we can expect more frequent changes to the ring than
currently take place. Additionally, there is the goal of expansion without any service
interruption. Minimizing the risk of inconsistent or conflicting operations
during expansion and meeting the goal of no service interruption requires some
reconsideration of the existing process.

The new process must be implemented carefully so that we do not run into a
situation where the ring is mutated on one electric-moray (*Note*: I use
electric-moray here to refer either the altered version of the existing
electric-moray application or perhaps a completely new application should that
make more sense. In the latter case the application may have a different
moniker) instance and vnode data transfers begin prior to the mutations being
reflected on other instances; otherwise, we risk a situation where read requests
could fail because they are routed to the wrong pnode or object writes could be
lost. The new process should also reduce the chances of human operator error to
the full extent possible.

One option is to introduce some means of consensus or coordination by which all
electric-moray instances can agree on the correct version of the ring to be used
and vnode transfers may only proceed once the electric-moray instances have all
agreed to use the new version. The downside to this is that it introduces more
complexity into the routing layer of the system for something that still does
not happen with extreme frequency. Also, we only avoid problems if all
electric-moray instances agree in concert, but this could prove difficult in the
case of network partitions or downed compute nodes. For these reasons I am not
in favor of this option.

Another option that avoids these problems is to have a single source of truth
for the ring and only allow mutations through this single source. Each
electric-moray instance fetches the current version of the ring data at start
time, stores it in a local data structure, and periodically polls for changes
thereafter. If a change is found then the electric-moray instance loads the new
ring. We can then determine an upper bound in the time from when the ring is
mutated (*i.e.* a new ring version is created) to when vnode data transfers can
safely be initiated. We can even expose an API in electric-moray to query the
current ring version in order to be certain rather than solely relying on
time. We also want to avoid the ring storage becoming a single point of
failure. In this scenario the centrally located ring might be stored in leveldb
with some sufficient means of replication or backup established or it could be
stored in a replicated PostgreSQL (postgres) database. Manatee could work for this, but it
might make more sense to use a `synchronous_commit` value of `remote_apply` and
have all peers use synchronous replication in order to increase the capacity to
handle read requests. Performance is often a concern when using `remote_apply`,
but for this use case the quantity and frequency of reads should vastly dominate
the amount of write activity. Write performance is not critical for this use
case and I think the performance trade-off should be acceptable. I do not think
that the `remote_apply` setup is required immediately for this proposal to move
forward. A single ring server should be able to service sufficiently many
electric-moray instances for current needs, but increasing the read capacity
would be beneficial to ensuring a smooth scaling path in the future. This is the
option I believe we should proceed with.

The two options above rely on being able to easily discern one ring version from
another. Part of this proposal is to add versioning to the ring so that such a
comparison is possible. Any mutation to the ring should result in the change of
a version indicator as well as an update to a timestamp indicating the time of
last mutation. The version update would need to be done atomically with the ring
mutations to avoid any issues. The `node-fash` implementation uses leveldb for
storage and while it doe not have transaction support it does allow for atomic
updates through its `WriteBatch` interface that should be suitable.

Another aspect of this proposal involves determining how to rebalance the vnodes
when pnodes are added or removed from the system. The [`node-fash`](https://github.com/joyent/node-fash) library has a
`remapVnode` function, but the function requires a set of vnodes to assign to a
new pnode be given as input. It lacks a balancing function to redistribute
vnodes when the set of pnodes changes. This function would need to be
implemented as part of the work for this proposal. Ideally such a function would
provide a way to give weight to certain pnodes to reflect the reality that the
capability of all pnodes may not be the same. In manta we need not be concerned
with overlapping vnode ranges or other problems that can occur when trying to
distribute vnodes among a set of pnodes because vnode ranges are not used for
data replication. For manta vnodes are simply an way to organize data to
facilitate pnode topology changes. The ratio of a pnodes' weight to the sum of
all weights multiplied by the total number of vnodes is probably sufficient for
this. Any remainder vnodes are assigned by ordering the pnodes for assignment in
descending order of the fractional portion of the calculated vnode
distribution. To illustrate consider the case of a ring with eight vnodes split
evenly between two pnodes with an equal weighting of `1`.

```
Pnode 1: Vnodes [1, 3, 5, 7]
Pnode 2: Vnodes [2, 4, 6, 8]
```

If we add a third pnode with a weight of `1.5` then the vnode distribution becomes:

```
Pnode 1: 2.29 vnodes
Pnode 2: 2.29 vnodes
Pnode 3: 3.43 vnodes
```

Let's also assume we want to minimize data transfer and have each existing pnode
give up vnodes in a round-robin fashion. After redistributing vnodes based on
the integer portion of the distribution amount the vnode allocation might look
like this:

```
Pnode 1: Vnodes [1, 3]
Pnode 2: Vnodes [2, 4, 6]
Pnode 3: Vnodes [5, 7, 8]
```

The integer portions of our vnode distribution numbers only accounts for seven
of the eight total vnodes. To allocate the final vnode (or any vnodes remaining
after each pnode is assigned its full complement of vnodes based on the integer
portion of its distribution amount) we sort the pnodes by the fractional portion
of the vnode distribution numbers and assign any remaining vnodes based on this
ordering. Here is that ordering:

```
Pnode 3: 0.43
Pnode 1: 0.29
Pnode 2: 0.29
```

The reasoning behind this is that the pnode whose fractional portion is closest
to one is most capable of handling more vnodes based on the provided
weights. Pnodes sharing the same fractional vnode distribution would be further
ordered based on the integer portion of the vnode distribution. Again with the
idea that more heavily weighted pnodes are more ready to accommodate extra
vnodes.

So the final vnode allocation would look as follows:

```
Pnode 1: Vnodes [1, 3]
Pnode 2: Vnodes [2, 4]
Pnode 3: Vnodes [5, 6, 7, 8]
```

Again, the actual vnodes numbers assigned to a particular pnode are not
important and so the fact that the new pnode has the entire vnode range from
`[5-8]` has no negative impact on the balance of the system. This actually works
out to be an advantage because an algorithm to ensure the vnode ranges do not
overlap is much more complicated.

In summary, the proposed changes to data placement and routing that are part of
this proposal are as follows:

* Move to a single source of truth model for storage of the ring.
* Add versioning to the ring that is updated on every mutation.
* Expose a new service for retrieval and mutation of the ring.
* Modify electric-moray or create a similar service that retrieves the ring from
  the *ring service* and routes incoming requests to the correct metadata shard.
* Create a function to rebalance vnodes across a set of pnodes that also allows
  for pnodes to be weighted relative to other pnodes in order to unevenly
  distribute vnodes based on the capability of certain pnodes.

### Vnode data organization and transfer

#### Data organization

The storage backend for the buckets system is postgres. In manta a metadata
shard comprises a replicated postgres database along with software to manage
failover in the case that the primary replication database has an issue. Each
metadata shard has three databases: *primary*, *sync*, and *async*. All reads
and writes are directed to the primary. The primary replicates data to the
`sync` using postgres' streaming replication with a level of
`synchronous_commit` and the `sync` cascades the changes to the `async` also via
streaming replication, but asynchronously as the name implies.

Each metadata shard in manta is equivalent to a pnode in the discussion in the
previous section. Each shard is responsible for a set of vnodes and currently in
manta the data for all vnodes owned by a pnode are stored in a single database
table. There is a `vnode` column that identifies the vnode for a particular piece
of metadata.

For incremental expansion, it would be possible to still use a single table to
co-locate the data for all vnodes residing on a pnode, but the extraction
process would require dumping the entire table contents and then filtering out
only the data for the vnode to be transferred. This would certainly be possible,
but then once the vnode data is transferred to the new pnode it must be deleted
from the old pnode. With a single table this could be time-consuming and those
deletes will create dead tuples that eventually must be cleaned up by postgres
autovacuum. Another approach is to partition the data using some ratio of
partitions to vnodes. Postgres offers a few f`. The ideal ratio of
partitions to vnodes is one-to-one. This is the most easy configuration for a
human to reason about because the partition naming can reflect the vnode of that
data it contains and it avoids the requirement for any other schemes for placing
or mapping data within the shard. It also simplifies the extraction and transfer
of vnode data for incremental expansion because the data can easily be
identified since it is already partitioned by vnode. Once transferred the
partition can be dropped without incurring any postgres vacuum
overhead. Finally, the one-to-one ratio allows for us to drop the vnode column
from the postgres schema. The postgres partition alone is sufficient to
associate the data with a particular vnode. No other ratio of vnodes to postgres
partitions allows for this. This detail is also important in the subsequent
description of ring resizing as well. Given these advantages I feel it is
worthwhile to proceed under the assumption that we want to use the one-to-one
ratio. An important implication of this choice is examined in the **Vnode
count and ring resizing** section below.

#### Data transfer

There are a few options for transferring vnode data from one pnode to
another. We might establish a replication link, wait for the replication
to synchronize, then terminate the replication link, and finally remove the data from
the original pnode. We might dump the database contents and transfer the data
outside of the database context and then remove the data once the data was
successfully transferred. We could even employ a zfs snapshot to transfer
the data.

Logical replication is a new feature in postgres 10 so I thought through how we
might use that feature to transfer the vnode data, but quickly realized some problems. To
illustrate I will consider the case of a new pnode (shard) receiving data from a single
vnode. Assume we have the new shard configured and ready to receive data. We
configure logical replication between the new shard and the current location of
the vnode data transitioning to the new shard. While the initial replication
sync is occurring we continue to direct writes for this vnode to the current
physical node (rather than the new location). Forwarding writes to the new
location will not work because logical replication does not support any means of
conflict resolution. It simply stops at the first error that occurs (such as a
conflict) and these error conditions require human intervention to resolve
before replication can continue. Once the replication of the vnode data to the new location is complete
it is time to cut over to the new location for vnode operations. The problem is
that the cut-over cannot be done atomically. There will be a window of time where
incoming writes may go to either the current or the new location for the
vnode. In terms of the logical replication there are two options during the
cut-over window. The first is to disable replication prior to the cut-over and the
other option is to leave it in place. Unfortunately both of these options are
susceptible to conflict that requires human intervention to resolve. In the
former case the new location would need to be brought in sync with the current
location after the cut-over window was completed either via automatic replication
or a manual process and this reconciliation could run into conflicts if writes
to the same object occurred in both locations. In the latter case the conflict
could arise at any time during the cut-over window. Aside from the potential for
requiring human intervention for conflict resolution, the system could also
exhibit unexpected behavior from an end user perspective during the cut-over
window. Writes and reads for out vnode could end up being directed to either the
current or new location during this period and this could result in the strong
consistency guarantee being violated. These problems are not limited to logical
replication, other options such as using `pg_dump` to gather vnode data could
suffer from this problem as well.

There are a few key requirements for data transfer in the face of ongoing read
and write requests. The first is to have a known point where writes may no
longer be directed to the transferring pnode for the vnode to be transferred. The
second is a way to easily reconcile the vnode data on the pnode receiving the
transfer in the case that writes for an object occur while the transfer is in
progress. The third is the ability to properly service requests during the
transfer period. The first requirement is addressed by the proposed changes in
the **Data placement and routing** section. The second requirement will be
addressed in the **Operations** section that follows. The third requirement is
also discussed in the **Operations** section and can be satisfied by directing
all writes for transferring vnodes to the new pnode and directing read requests
first to the new pnode location and redirecting them to the transferring pnode
if the requested data is not found.

There might be a way to do something similar using logical replication or
another means of transfer, but I like that `pg_dump` works quickly, does not
interfere with the current operations of the database, and offers a lot of
flexibility. At this point I wouldn't rule out other options completely and
it still might be worth exploring it more as an option.

Here is a summary of the proposed work and changes related to data organization and transfer:

* Vnode data on a pnode is partitioned with a ratio of one vnode per partition.
* The partitioning will be done using one of postgres' available levels of
  hierarchy: `database`, `schema`, or `table`.
* Vnode data that is to be transferred will be extracted using `pg_dump`.
* Identify a suitable means to transfer the vnode data between pnodes.
* Apply transferred vnode data on the new pnode in such a way as to properly
  reconcile conflicts and maintain system consistency guarantees. This is
  further discussed in the **Operations** section below.

### Operations

#### Add a new pnode

My initial consideration of the steps of adding and removing pnodes did not
consider all of the issues involved in allowing uninterrupted service during the
migration of vnodes while maintaining all of the system guarantees. I had to
rethink my initial version of the process and come up with a set of steps that
avoids those issues. Here are the steps for the case of a new shard receiving
data from only a single vnode:

1. Update the ring to reflect the addition of the new pnode, update the vnode
   assignments for the new pnode and current pnode owner of the transferring
   vnode, and set the ring to a `transitioning` state.
2. Wait for all electric-moray instances to use the updated ring. This step is
   critical. Once all electric-moray instances are using the `transitioning`
   ring then no more writes should be directed to the current pnode
   for the transitioning vnode. Hooray!
3. Except it is not quite so simple. While this is true for writes that arrive
   from the web tier after step 2 is completed, there is still the possibility
   of queued postgres requests waiting that could result in writes. So we also
   need to do something to ensure all requests queued prior to the completion of
   step 2 affecting the transferring vnode have been processed before proceeding
   any further. One possible way to check this is to push an entry onto each
   processing queue that triggers a notification when the message is
   processed. Once this notification is received for each processing queue we
   should be assured that no more writes will be received for the transferring
   vnode to its current (now former) pnode.
4. Use `pg_dump` on the former pnode to extract the data from whatever level of
   postgres hierarchy we end up using to group data (*i.e.* different databases,
   schemas, or tables). Rename the destination table to
   `manta_bucket_object_<VNODE_ID_HERE>_import`. One important note about
   `pg_dump` is this statement from the [documentation](https://www.postgresql.org/docs/10/static/app-pgdump.html):
   *pg_dump does not block other users accessing the database (readers or
   writers).*
5. Transfer the dumped data to the new pnode and import the data into the new
   database.
6. Populate the local `manta_bucket_object` table with the data
   from the `manta_bucket_object_<VNODE_ID_HERE>_import` table that does not
   conflict with any new data that has been written since the `transitioning`
   ring was put in place. Also move any conflicting object records to
   the `manta_bucket_deleted_object` table so that overwritten objects can be
   properly garbage collected. I'll show some SQL queries to accomplish this
   below after the description of other operations.
9. Drop the `manta_bucket_object_<VNODE_ID_HERE>_import` table.
10. Remove the vnode data from the previous pnode database (but ensuring not to
    write these records to the garbage collection table)
11. Remove the previous pnode information from the relocated vnodes and mark the
    ring state as stable.

During the transition phase:

* The ring maintains information about the both the new and previous
  pnodes for each relocating vnode.
* Reads and writes are first directed to the new pnode.
* If the read fails to find the object record and the the vnode has previous
  pnode data associated with it then the read is redirected to the previous
  pnode.

###  Remove a pnode

Removing a pnode follows a very similar process to adding a node. Again
considering the case of removing a vnode from a pnode that has ownership of only
that one vnode.

1. Update the ring to reflect the vnode re-assignment to another pnode and set
   the ring to a `transitioning` state.
2. Same as step 2 from above. Wait for all electric-moray instances to use
   updated ring.
3. Same as step 3 above. Ensure all queued messages involving the vnode have
   been processed.
4. Same as step 4 above. Extract the vnode data.
5. Same as step 5 above. Transfer vnode data.
6. Same as step 6 above. Place the imported data into the proper table on the
   new pnode.
7. When transfers are complete update the ring to exclude the exiting pnode and
   mark the ring state as `stable`.
8. Remove the vnode data from the previous pnode database (this step may or may
   not be necessary).
9. The exiting node may now be removed from service.

The steps above presented the steps for the case of only transferring a single
 vnode. Migrating multiple vnodes would follow the same process with the following
 exceptions:

* The first step would be to use the vnode rebalance function discussed in the
  **Data placement and routing** section to determine the new vnode to pnode
  mapping to use as input to the ring rebalancing function.
* Cases where the steps describe actions for single vnodes (*e.g.* deleting
  vnode data after a transfer is complete) must be done for all vnodes being
  transferred.

Adding or removing multiple pnodes would follow the same process. The vnode
rebalancing function should take a set of pnodes as input rather than being
specialized to a single pnode.

Here are two example SQL queries that would load the unconflicted transferred
vnode data into the `manta_bucket_object` table and load the conflicted data
into the `manta_bucket_delete_object` table:

```
INSERT INTO manta_bucket_object
SELECT id, name, owner, bucket_id, created, modified,
creator, vnode, content_length, content_md5::bytea, content_type,
headers, sharks, properties
FROM manta_bucket_object_import
WHERE NOT EXISTS (
  SELECT id, name, owner, bucket_id, created, modified,
creator, vnode, content_length, content_md5::bytea, content_type,
headers, sharks, properties FROM manta_bucket_object
  WHERE name = manta_bucket_object_import.name
  AND owner = manta_bucket_object_import.owner
  AND bucket_id = manta_bucket_object_import.bucket_id
);

INSERT INTO manta_bucket_deleted_object
SELECT id, name, owner, bucket_id, created, modified,
creator, vnode, content_length, content_md5::bytea, content_type,
headers, sharks, properties
FROM manta_bucket_object_import
WHERE EXISTS (
  SELECT id, name, owner, bucket_id, created, modified,
creator, vnode, content_length, content_md5::bytea content_type,
headers, sharks, properties FROM manta_bucket_object
  WHERE name = manta_bucket_object_import.name
  AND owner = manta_bucket_object_import.owner
  AND bucket_id = manta_bucket_object_import.bucket_id
);
```

## Vnode count and ring resizing

As part of writing this RFD I have thought a lot about vnodes and the
relation to how we might organize vnode data on each metadata shard for the
buckets work (see **Data
organization** under **Vnode data organization and transfer** above). Manta
currently uses one million vnodes in its ring and I don't know if that was
chosen intentionally or just because it is the default used by the `node-fash`
library. In my experience the guidance for choosing the number of vnodes tends
to be vague and usually resembles something akin to *select more than you'll
ever need* or *just use a big number*. This is not particularly helpful for
those intending to deploy a new system and the motivation for this advice may
not always even be understood. The reason for this guidance is that most
consistent hashing implementations do not support ring resizing and the number
of vnodes represents an upper bound on the number of pnodes and therefore has
implications to the scalability of the system.

The choice of one million vnodes for manta makes sense given the current metadata
storage details. *i.e* The data on a shard is stored in a single database table
and when the metadata system needs to expand the data residing on a pnode is
fully duplicated to a new pnode with only the data for certain vnodes being
retained long-term on the old and new pnodes. There is never a case (that I know
of) where the data for single vnode is extracted and transferred. However, when
considering incremental expansion providing a means to efficiently extract and
transfer the data for a targeted vnode is critical and one million vnodes
probably makes less sense. The following few paragraphs explore why this is the
case.

As mentioned in the **Data organization** subsection of the **Vnode data
organization and transfer** section, we would like to have a ratio of one data
partition per vnode, but there is a practical limit on the number of
`databases`, `schemas`, or `tables` that a postgres `cluster` can support.
Exploring the limits of each of these levels of hierarchy is part of MANTA-3896,
but there will be some limit for each and I am concerned that a default of one
million vnodes will cause trouble for deployments that only require relatively
small shard counts. For a system with 200 shards one million vnodes works out to
only 5000 vnodes per shard, but for a system of ten shards the per-shard vnode
count is 100,000.

This takes me back to thinking about the whole point of having vnodes in the
first place and looking at the vnode count as the upper bound of pnodes for the
system. While it could be possible that a single manta deployment could some day
reach one million metadata shards, it seems very unlikely that this is a
realistic possibility. I think even operating a system with tens or hundreds of
thousands of metadata shards would be very difficult. At some point I think it
makes more sense to divide up user accounts or even buckets into independent
systems than to try to support one overly large system.

Ideally, I think we could start most of our deployments with a much more modest
count of vnodes such as 10,000 or 100,000 (even less in some cases such as
 a COAL deployment) and allow the initial number to be configured by
users based upon the expected size of a deployment. Of course that leads to the
inevitable question of *What happens when you need to grow beyond the maximum
number of pnodes that the ring size allows for?* I think the answer to this
question is to support resizing the ring. This is very easy to state, but

Ring resizing would resemble the process of metadata resharding that is in place
for manta today, but the resizing process need not be coupled to the addition of
new pnodes. Essentially there would be a `resizing` state similar to the
`transitioning` state I previously described for adding or removing pnodes that
would allow incoming requests to be properly routed while the resizing work is
carried out. Once the ring is resized and new vnodes are created on each
existing pnode the transfer of vnodes can proceed using the same process I
outlined in a previous comment for adding pnodes. For each vnode to split we
would divide the keyspace owned by the vnode and then partition the data for
that vnode into multiple separate vnodes. In the **Data organization**
subsection of the *Vnode data organization and transfer** section above I
mentioned that the use of a one-to-one ratio of data partitions to vnodes would
allow us to drop the `vnode` column from the schema and that this was an
important detail. The reason this is important (actually critical is probably
the more appropriate term) is that if the vnode information is stored as part of
each metadata record then after increasing the number of vnodes we would have to
update the vnode column value for some portion of the data for each vnode, the
portion depending on by what factor the vnode count was increased. I think this
amount of extra work would be prohibitive. We might be able to avoid some of the
pain of garbage collection since the updates should be able to be done
as [Heap Only Tuple (HOT) updates](https://github.com/postgres/postgres/blob/REL_10_5/src/backend/access/heap/README.HOT),
but it would still represent a large amount of work that could interfere with
the normal system operation.

The precise steps required for the ring resizing process is out of the scope of
this document and warrants a separate RFD, but many of the ideas in this RFD
relate very closely. The nice thing is that if we are convinced that a process
exists to do this we do not need to actually implement it as part of the initial
work for the buckets project. As long as it is possible we should have plenty of
time to implement it before it becomes a necessity.

## Process Automation

This section addresses the final stated goal of minimizing the chances for human
error by automating the process of adding and removing shards as much as
possible. The steps outlined in the **Operations** section above for adding new
pnodes to or removing existing pnodes from the system could be executed manually
by an operator, but could also largely be automated. The primary concern is
ensuring the automation does adequate validation, executes safely, and can
handle failures and provide a means for rollback or recovery when things go
wrong.

The first step any automation must undertake before making any changes is to
ensure that no other metadata topology changes are already in-progress. Given
the distributed nature of the system this requires some sort of global lock or
point of coordination. The proposed ring server could serve this purpose. An API
operation representing intent to modify the metadata topology could be created
and such a request might either be accepted or rejected if another modification
was underway. The request submission should include the timestamp of the
request, the name or email address of the requester, as well as information
about the reasons for the request. This would be separate from the operation to
move the ring to a transitioning state. An API operation to allow the release of
the intent to modify would also be needed.

The next step is to ensure that the new shards are valid and prepared to receive
vnode data as well as handle requests. The following sanity check questions
should be answered:

* Are all new shards resolvable via DNS?
* Is postgres running on all shards and is the port accessible?
* Are new shards reachable from electric-moray hosts?
* Are the new shards able to communicate to the existing shards where the
  transferring vnode data resides?

If all these questions are answered in the affirmative then the automation can
proceed. The next step is to calculate the new distribution of vnodes that
includes the new shards. Once this is done, the set of vnode data partitions can
be created in the database on each new shard. Once this step is completed
successfully then the new shards should be ready to receive vnode data
transfers.

At this point the most prudent step is to have the automation provide a summary
of the changes to be executed to the operator and wait for confirmation. The
operator should be provided with information about the new topology in order to
verify that the plan includes all expected shards and that the plan for data
transfer matches expectations. The operator will have the option to proceed or
to cancel the process. In the case of cancellation, a further option should be
provided to remove the created data partitions that were created for the
transferring vnodes before exiting.

The next step is to modify the ring by moving it to a *transitioning* state and
providing the new vnode distribution information. This marks a *point of no
return* for the automation because once writes are allowed to go to the new
shards operator intervention is needed to cancel the process and reconcile the
data and avoid data loss. We might avoid this by mirroring writes to both the
old and new shards for a particular vnode during the transition process, but
this could negatively affect performance and has its own failure case
complexities that would need to be dealt with. So the intention is that after
this point a rollback of the addition or removal process will require operator
intervention.

Once the ring is in the *transitioning* state, the automation has assured
that all of the electric-moray instances are using the new version, and the
requests queues have been flushed of any writes for transferring vnodes the
vnode data transfers can begin. It may be beneficial to have the new shards pull
their vnode data from the existing shards rather than have the existing shards
push all the data. Throttling the data transfer should be more manageable using
a pull model. A concurrency level for transfers can be set and enforced at each
new shard joining the system.

Once the automation is notified that all transfers are complete the ring can be
marked as *stable* and the final cleanup of vnode data from their former shards
can commence. The completion of the cleanup phase marks the end of the process.

Failure handling needs to be carefully considered for the automation of
the process. Manipulating the metadata topology is a stateful process and
involves many different components of the system. The process should probably
keep a log of the progress in persistent storage with enough recorded information
that if the automation crashes and must be restarted it can examine the log and
resume the process. Each component involved in the process also must be able to
provide its status so that the primary automation process can inspect the status
of the different components, report any problems, and retry in cases of failure.

Automation of the process could be managed either by a continuously running
program that might sit idle and wait for requests to change the metadata
topology or the program could be run only when needed and then exit once the
process completed or an unrecoverable error occurred. The `manta-adm` command
could provide a convenient interface. A new `metadata` subcommand might provide
`add-shards` and `remove-shards` options.

Invocations of the command might look as follows:

```
manta-adm metadata add-shards '[{"name": "555.moray.com", "weight": 1.2}, {"name": "556.moray.com"}]'

manta-adm metadata remove-shards '[{"name": "3.moray.com}, {"name": "4.moray.com"}]'
```
