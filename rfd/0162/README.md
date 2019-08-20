---
authors: David Pacheco <dap@joyent.com>, Rui Loura <rui@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 162 Online repair and rebalance of Manta objects

## Introduction

_This introduction is adapted from [MANTA-4000](https://smartos.org/bugview/MANTA-4000)._

Manta allows users to control the number of complete copies of the object's contents that are stored on the backend, promising that if the user requests N copies (where N is at most the number of datacenters in the deployment), then there will be copies on at least N different storage servers in N different datacenters. This semantic is critical for Manta achieving the promised level of durability.

Implementing this behavior involves three parts:

1. Ensuring that newly-uploaded objects are created with the correct number of copies. This is achieved during the initial object upload by selecting N storage servers in as many different datacenters as possible and synchronously writing the object's contents to all of them as part of the upload.
2. Detecting any cases where one or more of the copies have become missing or corrupt. In most deployments, this is largely covered by the built-in audit job, which runs daily to identify any objects that are missing one or more of their expected copies. If any are found, an alarm is raised. (Operators are responsible for monitoring either the alarms or the audit job directly.) This mechanism does not identify corrupt files on disk, but ZFS covers this case as long as the application itself didn't cause the corruption. This mechanism also doesn't scale to large deployments. In those cases, a system like the one described in MANTA-3348 would be needed to identify missing or corrupt files.
3. Repairing any cases where one or more copies are missing or corrupt, generally by copying one of the surviving copies to a different storage server. Today, this is largely an ad hoc process for each event where it's needed.

This RFD describes a system for part (3): repairing objects having a copy that's missing or corrupt.  This is similar to what's known in other systems as anti-entropy, although that usually covers both (2) and (3) above.


## Phased proposal

For reasons described in more detail later, we propose a phased approach.

### Milestone M1 Direct transfer between storage zones, local state

The first deliverable is the capability to remove all objects from a given storage node.  This operation will be called "evacuate."

This deliverable would include:

- a new SAPI service and component with one main SMF service to implement object repair and rebalancing
- Prometheus metrics exposed by the service
- automatic pausing of jobs that have experienced too many transient errors
- a CLI tool for:
    * listing jobs
    * creating jobs
    * observing job status
    * pausing jobs
    * resuming jobs
    * observing a summary of transient and permanent errors from a job, with example objects
    * viewing the progress of a job (i.e., how many are in-progress, how many have finished, how many are queued for retry due to a transient error, and so on). 
- data transfers would happen directly between storage zones
- automatic tests for as much as possible
- configurable throttles on usage of the metadata tier and storage tier

When a job is complete, all information about the job would be archived into Manta automatically and local state would be removed [except maybe a record of the job's metadata].

This implementation would *not* handle the so-called "walking link" problem.  For safety, it would only operate on metadata with `single_path` set, from a whitelisted set of accounts, or when requested by an operator to override these checks.  (In practice, it would likely be sufficient to override the checks and scan muskie logs for snaplink creation if we're worried about that case.)

This zone (remora zone) could be deployed anywhere in the Manta fleet.  It's not clear if it's better suited to a storage server or a metadata server.

The direct zone to zone data transfer will require and update to the storage nodes to add a component (remora agent) to manage that transfer.


### Milestone M2 Shared storage for repair jobs

This milestone:

- replaces the local sqlite database with Moray/Manatee (see the section on persistent state below)
- replaces local files with Manta objects
- adds a CLI tool to enable one instance of this service to take over from another
- updates CLI tools to use the state in Moray/Manatee, providing a global namespace for repair jobs


### Other features

Milestone M2 and M3 can be reversed if the priority makes sense.

Other features we can add at any point after M1:

- Expose an endpoint on the remora agent to calculate and report the md5sum of a locally object
- a proper solution (or better intermediate solutions) to the "walking link" problem
- additional operations, including:
  - "Add Copy": increase the durability of an object
  - "Remove Copy": decrease the durability of an object
  - "Audit" or "Scrub": check whether the existing metadata meets desired constraints (e.g., both copies in different datacenters) and update them accordingly.  Potentially also validate the object's checksum.
  - an operation that could be used to indicate that a particular storage node's ID and/or datacenter was changed.  This would be a fairly special case to handle MANTA-3827 / OPS-4691.


# Components
__this probably belongs elsewhere in the document__

## Remora Zone

The remora zone is responsible for:
 * Managing each rebalancer job.
 * Coordinating the assignments for each remora agent.
 * Updating object metadata as necessary.


### Evacuate Job Threads
#### Picker Thread
The picker thread is responsible for maintaining an up to date snapshot of the
status of the storage nodes in the region.  The final approach here will depend
on the outcome of RFD 170, but as a last resort this thread can query the
`manta_storage` bucket on the shard 1 moray directly.  There are some risks
associated with this approach, specifically
[MANTA-4091](https://jira.joyent.us/browse/MANTA-4091)

#### Assignment Manager Thread
* Get a snapshot from the picker thread
* For each storage node in the snapshot:
    * Determine if the storage node is busy servicing another assignment
    * Create an assignment template  
    * Send template to Assignment Generator thread
    * Mark storage node busy (or increment active assignement count)

The assignment template consists of:
* The shark host name
* The available space for the assignment

#### Assignment Generator Thread
* Get assignment template from Assignment Manager thread
* Get object metadata from Sharkspotter thread.
    * Determine if object can be rebalanced to shark in assignment template.  In
    making this determination we need to consider both size vs free space as the
    possibility that this object already resides on the destination storage
    node.
    * Choose a source storage node for this object to be copied from.  For
    Evacuate jobs this should default to the node that is not being evacauted.
    * If suitable, generate a download task and add that task to the list of
    tasks for the assignment being generated.
    * Continue to get objects from Sharkspotter thread and add them to the
    assignment until the assignment is full based on either max number of tasks
    or available space.
* Regardless of the suitability of the object for current assignment the object
metadata should be written to persistent storage and annotated with the
appropriate state (Skipped, Processing, etc)
* Sends fully generated assignment to Post thread

(TODO: add list of states and meaning of each)
    
#### Sharkspotter Thread
* Runs rust-sharkspotter with the evacuating shark as an argument 
* Sends each object's metadata to the Assignment Generator thread

#### Post Thread
* Posts each assignment to the rebalancer agent running on the destination
storage node.

#### Metadata Update Thread
* Periodically queries rebalancer agents on storage nodes for outstanding
assignments.
* Upon receiving a completed assignment in response to a query updates the
metadata of each object.


## Remora Agent

- Expose and API which is only consumed by the remora zone.
- Excepts arrays of tasks in the form of assignments.
- Task Types:
    * Download:
        * Check for object on disk and matching MD5 sum
        * If object does not exist or there is an MD5 mismatch, download the object from the URL provided
        * Uses a pull method to get objects from another storage node.
        * Is thus idempotent
    * Others: Future work


### Tasks
#### Download
```
{
    "action": "download",
    "source": "1.stor.east.joyent.us",
    "owner": "37fffb8f-5f29-4f67-b2b2-591f3f103eb0",
    "object_id": "c7d5a531-832c-4095-b940-f920ccaa3257",
    "md5_sum": ""
}
```
`origin`, `owner`, and `object_id` can be substituted with a single URL string

### Agent Interface

## ListAssignments

Returns a list of assignments 

### Inputs

| Field  | Type    | Description                    |
| ------ | ------- | ------------------------------ |
| offset | Integer | Starting offset for pagination |
| limit  | Integer | Maximum number of responses    | 

### Example
	GET /assignments
	
	[
		{
            "id": "bc7e140a-f1fe-49fd-8b70-26379fa04492",
            "status": "running",
            "error_count": 7
            "tasks_remaining": 589795,
            "tasks_completed": 98734382,
		}
		{
            "id": "856e77b0-c0b2-4a6a-8c17-4ec1017360af",
            "status": "complete",
            "error_count": 5740 
            "tasks_remaining": 0,
            "tasks_completed": 8972630,
		}
	]

## GetAssignment

Returns details of a specific assignment

### Example
	GET /assignments/:id
	
    {
        "id": "bc7e140a-f1fe-49fd-8b70-26379fa04492",
        "status": "complete",
        "successful_tasks": [{
            "action": "download",
            "source": "1.stor.east.joyent.us",
            "owner": "37fffb8f-5f29-4f67-b2b2-591f3f103eb0",
            "object_id": "c7d5a531-832c-4095-b940-f920ccaa3257",
            "md5_sum": "GO4i6ZQq5SeWxYQlfkxUzQ==",
            "content_length": 54, 
        }, {
            ...
        }],
        "failed_tasks": [{
            "action": "download",
            "source": "7.stor.east.joyent.us",
            "owner": "76809b8f-5a20-4f76-b2b2-591f3f6fb709",
            "object_id": "df4c1682-a77d-11e2-aafc-5354b5c883c7",
            "md5_sum": "GO4i6ZQq5SeWxYQlfkxUzQ==",
            "content_length": 109, 
        }, {
            ...

        ]
    }

**we may consider returning only the objectid for successful and failed tasks as well as the error.**


## CreateAssignment (POST /assignment)

### Input

Array of task objects.

### Example:
    POST /assignments
        -d
    [
        {
            "action": "download",
            "source": "1.stor.east.joyent.us",
            "owner": "37fffb8f-5f29-4f67-b2b2-591f3f103eb0",
            "object_id": "c7d5a531-832c-4095-b940-f920ccaa3257",
            "md5_sum": "GO4i6ZQq5SeWxYQlfkxUzQ==",
            "content_length": 54, 
        }, {
            ...
        }
    ]

Returns a uuid that identifies this assignment


## Job Actions
### Evacuate
An evacuate job removes all objects from a given storage node and rebalances
them on to other other storage nodes in the same region.  Since evacuate softly
implies an issue with the evacuating shark the remora will prefer to use a copy 
copy of the object being evacuated that does not reside on the evacuating
server.  The basic flow is as follows:

#### Initializing Phase
1. Lock evacuating server read-only.
1. Start sharkspotter pointed at evacuating server.
1. Start picker to generate destination sharks.
1. Start Assignment manager and generation threads.
1. Start Post and Metadata Update threads.

#### Generation Phase
1. Remora Zone takes input from sharkspotter and picker to generate Assignments.
1. Assignments are posted to the destination shark via the CreateAssignment
   endpoint, and put in the Assigned state.

#### Metadata Updating Phase
1. When the Assignment Processing thread receives a response from the remora
   Agent's GetAssignment endpoint of a completed assignment it begins to update
   the metadata of the successful objects.  (Note: A completed assignment may
           include both successfully reblananced objects as well as objects that
           failed rebalancing).
2. Each failed task is handled on a case by case basis.
    * A transient failure is logged
    * The object is either put into another Task and Assignment, or tagged as a
    persistent failure.


#### Handling Failures
* Not Enough Space on Destination Shark
    * Response:  Find another destination shark
* md5 Checksum Mismatch
    * Likely means that the source shark has a bad copy of the file.
    * Response:


#### Assignment States
__TODO__

## Deeper background and use-cases

One might expect Manta to already have such a system. Although the audit function was built into Manta since initial launch, we expected that the only reason to need to repair objects would be because of data loss from a ZFS pool, and our experience was that such an event would be extremely rare, and likely significant enough that building a recovery process would be a small part of the overall problem. Indeed, data loss from a ZFS pool has proved quite rare up to this point. However, we've found a number of cases where we've needed to repair the copies of an object, most of which don't involve filesystem data loss:

* Prior to Manta's initial launch, we discovered MANTA-1171 – a missing fsync in nginx that meant if a storage server panicked, the last few seconds' worth of object writes would be lost. This was prior to launch, and I'm not sure if we repaired these objects or not.
* Very shortly after Manta's initial launch, the audit job uncovered MANTA-1760 – a very similar case resulting from a bug in how nginx invoked fsync() after each object write. This was after launch, and I believe it was just handful of objects that were repaired by hand.
* Early in Manta's lifetime, we found a Muskie bug (MANTA-1728) that caused it to place multiple copies of an object into the same datacenter, instead of spreading the copies across datacenters. Technically we still had two copies, but the availability is less than expected, and both copies would be wiped out by some failure modes. We fixed this by introducing the "rebalance" job that would identify these cases and move one copy to a different datacenter.
* In several cases (at least one of which was covered by OPS-3317), we had a slog failure at the same time as a system panic. This is technically a double-failure, which an individual copy is not designed to survive, but it's nevertheless happened a few times. To import the pool, we had to discard writes from the slog device, which lost the last few seconds' worth of writes. Again, these cases usually only affect a few files, and we've generally just repaired them by hand.
* We had a bug in a single-DC on-prem deployment that caused Manta to deploy multiple storage zones to one server, meaning that an object placed onto both servers would would be unavailable with just one server failure. To address this, we fleshed out the process for evacuating one storage server (MANTA-2594) using the same rebalance job as before.
* In a large production deployment, we had a case where a storage zone was deployed with the same storage_id as an existing zone. This led to multiple issues (MANTA-3827 and MANTA-3847): one being that Muskie continued to write to the first storage zone long after it was full because it was seeing the capacity information from the other storage zone; another being that some objects did manage to get written to the second zone – the fix was to rename that storage zone and update the metadata on those objects to refer to the new name; the third problem is that because the duplicate was in a different datacenter than the first zone, once again Muskie had placed multiple copies of objects in the same datacenter. None of these issues has yet been repaired, and they each affect large numbers of objects.

Besides all of those cases, it would be useful to be able to rebalance storage used across storage servers. As we fill up a fleet of storage servers and expand more, it would be nice to move data from the old servers to the new ones so that all storage servers (old and new) could absorb writes. (This might be needed for aggregate network or I/O throughput, or to even out the availability impact of individual servers crashing.)


### Example Use cases

Based on the above experiences, here are several key use-cases.

Restoration of object data:

1. **One copy of an object is missing.**  This might result from a software bug or operator error.  An operator wants to restore the expected number of copies by creating a new copy somewhere else from one of the other valid copies.
2. **One copy of an object is unreadable.**  This might result from partial ZFS pool corruption.  This is essentially the same as case (1), except that the unreadable file should likely be removed.
3. **One copy of an object is corrupt.**  This might result from a software bug or operator error.  This is essentially the same case as (2).

Restoration of availability:

4. **Move one copy of an object** because a software bug has placed both copies on the same server or in the same datacenter.

Capacity planning:

5. **Move one copy of an object** because an operator wants to free space on a server, decommission a server, or better balance free space across servers.  The implementation of this is likely the same as case (4).

User requirements change:

6. **A user wants to create an additional copy of an object.**  They might want this for increased compute job parallelism, increased availability, or increased durability.
7. **A user wants to remove a copy of an object.**  They might want this to save money because they don't need the compute job parallelism, availability, or durability of the copies they have.

Metadata repair:

8. **Indicate to Manta that one copy of an object may be stored in a different location.**  This can happen if storage nodes are renumbered, as has happened due to operational issues in the past.  Repairing this need only update metadata, not storage.

Note that many of these cases should be very unlikely, but cases (1), (2), (4), (5), and (8) have all happened in production Manta deployments, often multiple times.  Case (3) has not happened to our knowledge, though we do not automatically check for it today.  Cases (6) and (7) have occasionally been requested by customers.

### Background on Manta object storage

End users store **objects** into Manta.  An object is any arbitrary-sized sequence of bytes.

Objects are stored at **paths** (or **object paths**) in Manta.  For example, a user might store a log file in the path `/dap/stor/webapi0.log`.  Essentially, this means that when the user issues a `GET` request with this path, they will get back the byte sequence that they initially uploaded to this path.

Internally, each object is assigned a unique **objectid** upon creation.  This is used internally to identify the object.

The implementation of Manta stores multiple **copies** of each object.  Each copy is stored on a **storage server** as a file on a ZFS filesystem.  The file contains the object's bytes, exactly as provided by the user.  By default, Manta creates two copies of each object, but users can adjust this on a per-object basis when they create the object.

An individual object is immutable.  Once an object has been successfully stored to a particular path, all copies of that object (i.e., the files on disk) should never change.  Users can create new objects at the same path as an existing object.  Internally, this is a completely new object that happens to end up stored at the same path.  The original object is usually deleted.

A separate **metadata tier** (in the form of sharded, replicated PostgreSQL databases) is responsible for mapping user paths (like `/dap/stor/webapi0.log`) to objectid and the list of storage servers storing a copy of the object.

Let's summarize with an example.

1. After signing up for a Manta account, a user uploads a log file to `/dap/stor/webapi0.log`.  The object's _path_ is `/dap/stor/webapi0.log`.  Let's call the associated _objectid_ `O1`.  There may be _copies_ on storage servers `S1` and `S2`.
2. Some time later, the user uploads a different log file to the same path.  The new object's path is also `/dap/stor/webapi0.log`.  We'll call the associated _objectid_ `O2`.  Critically, `O1 != O2` -- they're different objects.  The two copies are likely to be stored on other storage servers `S3` and `S4`.  (Asynchronously, object `O1` is cleaned up by the garbage collection process, which is beyond the scope of this document.)

Users can also create **snaplinks**, which are essentially new paths for an existing object.  Internally, the object metadata is duplicated to the new path.  It's not possible to tell from an object's metadata whether any snaplinks have been created.

Key points:

* Most critically, each object is immutable.  Users may perceive that they can modify the object represented by a path, but internally the modified object is a wholly new object.  This significantly simplifies the design of Manta in general and this system in particular.
* As we can see, objects (or their copies) are visible if and only if they're present in the metadata tier.  There may be copies of objects stored on disk that are not visible in the metadata tier (in which case they can (and should) be removed, to avoid leaking storage space).  There should never be objects (or copies) referenced in the metadata tier without corresponding copies on disk on the storage tier.


## Design goals, constraints, scale, and considerations

**Constraint:** Since this system repairs objects, it identifies objects by **objectid**.

**Constraint:** The system should be completely safe.  At no point should metadata or object durability or availability be reduced by this system.  Care must be taken to avoid invalidating object metadata, removing or corrupting any copies of an object that may still be referenced, or writing incorrect metadata.  This constraint is straightforward to implement provided a few details are considered:

* Given an objectid to be repaired, the system must find all references in the metadata tier.
* All new copies of an object must be created before metadata is updated to refer to those new copies.
* Metadata that refers to an old copy of an object must be updated (to remove that reference) before the old copy of the object is removed.
* Metadata updates should be careful to avoid clobbering concurrent changes (e.g., using a conditional PUT-with-etag request).  Those changes may be made by a Manta client or another instance of this system (or any other system in Manta that may modify metadata).

**Goal:** Operators should be able to specify objects for repair by **_objectid_** or all object from a particular server. 

**Goal:** Operators should be able to group objects to be repaired into something like a _job_ so that the progress of the entire operation can be queried and managed as a unit.  For example, evacuating a particular storage node might represent a single job.  Operators shouldn't have to separately track the status of millions of objects that are all part of the same operation.  (As mentioned above, it _is_ currently expected that operators will have to enumerate the set of objects in a job explicitly.)  Jobs should support at least one tag that could be used to associate them with JIRA tickets for more information.

**Goal:** The system should support the use-cases enumerated above.

**Goal:** The system should be able to verify the contents of each copy of an object as part of a repair operation.  Ideally, each repair would support multiple levels of verification: size should always be verified, and md5 content verification should also be an option for operators.  Content verification should happen on the servers storing each copy of the data to avoid unnecessary copies across the network.

**Goal:** The system should provide detailed information about the progress of its operation.  Specifically:

* The system should expose metrics counting the number of repairs queued, running, and completed.  These should be broken out by job.
* For any given job, an operator should be able to tell how many objects are to be repaired, how many have been processed, and aggregate results of these repairs (e.g., no repair necessary vs. new copies successfully made vs. permanent failure vs. transient failure).
* For any given objectid, an operator should be able to determine the status of the repair, including what stage of repair it's at, whether any fatal error has occurred, whether a transient error has occured, and when the repair will be retried (if there was a transient error).

**Goal:** The system must provide resource controls to prevent overload of itself and to prevent overloading other components.

* A basic control to avoid overloading itself could include tunable limits of the the numbers of queued and running repairs.
* This system will interact with both the metadata tier and storage tier.  Load on the metadata tier is critical to availability and end-user performance of Manta, so it's critical that this system provide a throttle on all of its metadata operations to avoid overloading the metadata tier.  Ideally, operators would be able to adjust a tunable to control what fraction of metadata tier resources are used by this system.


**Goal:** The system's progress should not depend on any particular server being available, but operator intervention may be required to resume jobs that were being managed by a component that is offline.  If a component running a job goes offline, operators should be able to either bring the original component back online or resume the job from some other instance.  (Automatic resumption of jobs by other instances is explicitly out of scope of this RFD.)

**Goal:** The system should support multiple instances operating mostly independently.  This enables the previous goal and also eliminates a single instance as a bottleneck for repairs.


**Scale:**

We should assume that each job can support on the order of hundreds of millions of objects.  This is based on the number of object copies typically stored on a single storage server.

We will want to assume that the system can support on the order of tens of jobs, though it's possible that only some of them may be running at a time.  This is based roughly on the number of storage servers we might expect to be offline at any given time.

The system should be able to use all available resources if configured to do so.  Ultimately, the system should be limited by one or more of:

- the networking bandwidth or read I/O bandwidth of an individual storage node used as a source
- the networking bandwidth or write I/O bandwidth of an individual storage node used as a target for new copies
- the networking bandwidth available between source and target storage nodes
- the number of read or write operations that can be supported by the metadata tier

This goal informs the architecture.  We could imagine building this system using a centralized CLI tool or service that interacts with the metadata tier, downloads copies of objects, and uploads copies of objects to target servers.  This might be a useful first milestone or prototype, but such a system would likely be bottlenecked by the networking performance of a single server -- the one running this service.  Instead, the actual object transfers should ideally be carried out directly between storage nodes to distribute the load across as many servers and links as possible.

As mentioned above, resource controls should be available to limit load in order to preserve quality of service for end users.  Implementing these controls effectively would be easiest if the metadata operations were centralized as much as possible.

**Other considerations and open questions:**

These details are described in detail below:

- Should this system directly modify metadata, or should it use the external API to write new copies of objects?  (See below.)
- Where will state about jobs and repairs be stored?  This has a big impact on the HA and horizontal scalability design.  (See below.)

These are open questions:

- We'll need to consider how error handling and reporting works.  For transient errors, the system should back off and retry on a per-object basis.  For persistent errors, the error should be recorded and the system should proceed to work on other objects.  If more than a configurable number (or percentage?) of object repairs result in persistent errors, we should pause the job and wait for operator intervention.
- Is it important to be able to perform the object cleanup step later?  (This might happen if we want to "forget" about some objects on a storage node because it's offline for an extended period, but where we do intend to bring that node back into service.)
- We might need to think through how batch processing works with transient failures.  It'd be nice to keep the batch processing behavior (since it's so much more efficient), but we don't want transient failures for individual objects (e.g., because one storage node is offline) to prevent us from making progress (because we can't complete the batch).  Maybe individual failures are put into a separate retry queue stored in a flat file?
- What language will we use to implement these components?  Rust is a reasonable candidate, with this being a new project.  The main service will require a robust Rust implementation of the Fast protocol (including service discovery similar to cueball), and this will have to reliably support conditional PUTs.  The follow-on services in the storage tier are simpler and may make particularly good candidates.
- How exactly will old copies of objects be deleted?  (See the details about the repair process below.)


## Major design choices

This section includes a lot of information about the considerations that went into the proposal described above.  It's been separated from the proposal because most readers likely aren't interested in all this detail.

### Should this system write new objects using the public API or modify internal metadata and storage directly?

**Approach 1 (rejected): write new objects through the external API.**  If we read any object successfully, we can write it back to Manta with the desired durability level, which should always create new copies.

Pros:

* Relatively easy to implement.
* Very low risk of introducing new metadata or data corruption since only the public API is being used.
* Users can implement this at the application level for the "User requirements change" use-cases above.

Cons:

* This approach cannot correctly handle some metadata repairs, as it would leave cruft on some storage servers.
* This approach always creates N new copies, even if only one copy needed to be made.
* This approach will likely update the modification time and etag of objects as users see them, so it's not transparent to end users.
* Without using internal APIs, we cannot tell ahead of time whether there's any corruption to repair or what type of corruption it is.  When repairing a large number of objects, this makes it hard to tell that we've repaired all of the problems we know about.  (See Approach 2 below.)
* Without using internal APIs, we cannot validate that the new copies were correctly written.  We're just relying on the normal data path to be working correctly.  Put differently, this approach does not also provide an on-demand audit ability.


**Approach 2(preferred): implement a new system using private interfaces inside Manta.**  With this approach, the repair service would fetch individual copies from storage nodes, validate them, create copies on other storage nodes, and update metadata internally, ideally without modifying an object's mtime.

Pros:

* This approach is very flexible.  It can handle all of the cases above (which can be delivered in phases if needed).  Having this as a low-level primitive allows us to respond to unforeseen issues, including other types of corruption or other reasons to move object data or metadata around.
* This approach would necessarily include an on-demand auditor for individual objects, which would be useful on its own.
* This approach creates only as many new copies as needed.
* This approach can report on the number of objects repaired, by type of repair needed.  This makes it easier to say with confidence that we have fully repaired a particular class of issue.  For example, if we know there are 400 objects on some node affected by some issue, we can feed all of the objects on that node to this auditor and it can confirm that it repaired 400 objects having this specific issue.

Cons:

* More work to implement.
* Since storage zones and metadata are being modified directly, care must be taken to ensure data integrity is preserved.  Like all new software, particularly software modifying object data and metadata, this also represents additional test burden going forward.


### What persistent state will this service use and where will it store it?

This question is closely related to the delivery timeline and the goals around availability and scalability.  **Complexity around persistent state is the primary driver for the phased approach.**  The level of sophistication around state persistence enables additional features (like a global view of jobs handled by multiple instances and the possibility of resuming jobs when one instance crashes).  We start with a simple approach that can be delivered quickly and propose improvements that can be rolled out in phases.

**What state does the system maintain?**

- the set of outstanding _jobs_.  This is likely to be a pretty small, rarely-changing amount of data.
- the list of objects associated with each job, including which ones have already been processed, which ones are being processed, and which ones haven't been started yet.  As mentioned elsewhere, we expect on the order of hundreds of millions of objects per job.
- for objects currently being repaired, additional information about the state of the repair.  For more, see "How does the repair process work for each object?"

**Does all this state need to be persistent?**

- The operator's intent (the job and the list of objects) should be stored persistently so that operators don't need to separately track what jobs they expect to exist and re-create them in the event of a crash or takeover.
- Some state associated with objects that are currently being processed should be stored persistently.  In particular, once the system has allocated storage nodes for new copies of an object, that should be recorded.  Otherwise, if the system crashes during the repair, it might pick different storage nodes next time, leaving cruft on the originally-selected storage nodes.  (Alternatively, the system could scan _all_ storage nodes to figure out which ones had been selected for repair, but this seems far too expensive just to avoid saving a bit of state.)
- The list of objects completed, in progress, and not-yet-started should probably be stored persistently.  It's possible that as long as repair operations are idempotent, we could have the system start at the beginning of each job in the event of a crash.  However, re-verifying hundreds of millions of completed objects seems very problematic.

**What exactly do we need to store?**

- The job metadata is likely to be small and structured (e.g., a JSON object or a PostgreSQL row).  It's also likely that operators will want to list and inspect jobs, and it would be nice if they didn't have to know about which instance of this service was handling each job.  For this reason, it would be nice if job metadata were stored in some form of shared storage (e.g., a Manatee shard, like shard 1.).  The metadata could refer to the instance running the job, which would be used by clients to get more information about the job.  Alternatively, clients could be written to simply list all jobs from all instances, using service discovery (i.e., DNS) to locate all the instances.
- The input list of objects is a very large sequence of objectids.  It's not necessary to query this list efficiently; it will likely always be processed sequentially.  Even a flat list of objectids would generally provide random access by offset, if desired.  For this reason, an unstructured list of newline-separated objectids seems sufficient.
- The state of individual objects being repaired is likely to be relatively small but structured (i.e., a list of storage nodes and some flags associated with each one, a list of copies that have been validated with md5sums, etc.)  Fortunately, this set can be tightly bounded -- we likely don't need to work on more than a few thousand objects at a time.
- The list of which objects have been completed, which are in progress, and which are outstanding is a little trickier.  We could use a database, but like the input list, this could be an enormous number of rows.  Using a database like PostgreSQL, our experience suggests we'd likely need to consider long-term database maintenance issues including index rebuilds, table fragmentation, vacuum, and transaction wraparound.  It would be nice to avoid this.  An alternative would be to say that this service will process objects in a single fixed-size batch at a time, and the batches will always be processed in order.  That would allow us to track the full sets of completed objects, pending objects, and unprocessed objects with a single integer (the batch number of the current batch).  However, it means we cannot proceed to the next batch while any objects within a batch are experiencing transient errors (e.g., the source storage node is offline).

**Where exactly will we store this state?**

Since time-to-delivery is a major goal, it would be compelling to start with a command-line tool or an isolated service.  That suggests a very simple implementation: a local directory tree containing one directory per job.  Each job directory would contain:

- a file with the full list of input objectids for the job.  (If it were important to add new objectids to an existing job, we could make this a directory of files.)
- a sqlite database for job metadata (primarily because that makes it easier to correctly persist changes atomically than using a flat file or list of files), which should include the total count of objects and the current batch number (see above).
- For each job, the sqlite database contains state about in-progress repairs.
- For auditing purposes, a bunyan log describing for each object exactly what the system did (the copies that were checked, the calculated md5sums, the new copies that were written, and so on)
- Relatedly, the system should emit a log describing all the objects we failed to process and why we failed to process each one.  This should contain primarily persistent errors (like finding invalid metadata or finding no valid copies).  Transient errors should generally be retried until either success or a persistent error is encountered.

We suggest separate databases for each job to avoid issues related to fragmentation as a single large database evolves over time.  We may even want to truncate this database between batches.

Overall, this approach also keeps individual instances independent of each other.  New instances could be spun up to handle additional jobs.  In the event of a planned outage of the server, a crude "manual takeover" process could be implemented by simply copying the local job directory over to another instance of the service.

**What about multiple instances and takeover between instances?**

The local-filesystem-only approach means that clients wanting to list all jobs (e.g., to provide a single API for operators to manage these jobs) would have to query all instances of the service.  We expect there to be a relatively small number of instances, so this may not be a problem to begin with.  However, it does mean that if instances are offline, their jobs would simply not be listed, which isn't a great user experience for operators.  Clients wouldn't necessarily even know that some instances (and so some jobs) were missing.

While it's theoretically possible to implement a takeover by copying a job's state directory between instances, in practice, this is not likely to be useful in the event of a server crash because the state directory will not be available.

However, we could make a few changes:

- Move job metadata into Moray/Manatee (e.g., shard 1)
- Move state for in-progress repairs into Moray/Manatee (either shard 1 or somehow sharded across the metadata tier)
- Move the list of inputs for each job into Manta itself, stored as a flat object

With this approach, as long as the Moray/Manatee shard(s) are available, clients can observe a complete list of outstanding jobs.  Further, takeover would be straightforward since all relevant state is available to all instances of the service.  (Detecting the need for takeover is somewhat complex, as is ensuring that the original instance is not still running.  We would likely defer these issues, requiring operators to verify the instance is not running and use a tool to perform the takeover.  The takeover should be fully automatic once the operator executes the tool.)

Using Manatee adds constraints around schema design and raises issues related to database maintenance.  In particular, the large number of updates required for tracking in-progress object repairs is likely to exacerbate existing issues around vacuum and transaction id wraparound.  However, it's likely that the volume of data involved would be quite bounded.  New tables could potentially be used for each job, allowing us to drop them rather than vacuum them.  There's still a significant impact on transaction ids used, which significantly affects data path performance.

As described above, we suggest starting with the simple local filesystem approach and adding more sophistication as needed later.


### How does the repair process work for each object?

The per-object repair process is the crux of this system.  It works roughly like this, to start:

1. Given a particular objectid, query every metadata shard for any metadata related to this objectid.  The `manta` table has an index on `objectid`, so this should be a relatively efficient query.  Verify that all copies of the metadata match each other with respect to the size, checksum, and list of sharks.  If the size or checksum do not match, this is a persistent error.  If the list of sharks do not match, and there's no active repair going on, this is a persistent error.  (This step is needed because of the possibility of snaplinks.  It may be possible to make the system more efficient for the special case of objects known to have no snaplinks, though there would be risk of Manta-level data corruption if we rely on operators to attest to this fact.)
2. Identify and verify existing copies.  Use HEAD requests to each shark to determine which copies are available.  If the repair request indicated that some shark is expected to be missing (i.e., we're recovering from a permanently failed shark), we skip it in this stage.
3. Make a plan to execute the repair.  Depending on the action requested, this may involve creating new copies (and so allocating new storage nodes) and causing existing copies to be deleted.  **This plan should be persisted to disk to avoid picking a different set of nodes in the event of a crash after this point.**
4. In parallel, execute the plan to distribute new copies as needed.  This will involve one of a few approaches (see below).
5. Verify each of the new copies.  (See step 2.)
6. Update each of the metadata items found in step 1.  This should use a put-with-etag to update any metadata that hasn't changed since step 1.  If metadata has changed, and the objectid has changed or been removed, then this metadata entry can be ignored entirely.  If metadata has changed and the objectid and sharks are the same, we should be able to merge our changes.  If metadata has changed and the objectid is the same but the sharks have changed, some other process is repairing this object.  We should emit a persistent error for this object.  This should not happen.
7. In parallel, execute the plan to remove any old copies as needed.  See below.
8. Repeat step 1 to scan for any new references to the object in the metadata tier that were not updated.  (The only way this can happen today is if a user creates a snaplink from one of the original paths into a shard that had already been scanned.)  If any are found, repeat the repair process from step 3.  If not, this object has been repaired.  **Note: this step is not guaranteed to catch all cases where an end user has created a snaplink that references the original copies!**  A correct implementation would have to be more careful. One scheme for dealing with this is described in [RFD 123: Online Manta Garbage Collection](https://github.com/joyent/rfd/tree/master/rfd/0123).  Another option would be to create a lock on each path while we complete the repair, but this is not great for end users.  For now, we consider this case sufficiently unlikely that ignore it.  (We could also repeat this scan a number of times, possibly some time later.  The race not handled here is when a snaplink is created but missed during the scan, as a result of the so-called "walking link" problem.)

These steps gloss over a few details:

The object verification in steps 2 and 5 can initially be done with a HEAD request that checks the size of each object.  In the future, it would be useful to add a service to each storage zone that would allow this system to calculate an md5sum of the object without transferring it over the network.  (See also: RFD 112.)  In the meantime, we could provide an option to md5sum existing copies using a network transfer, or to do this for a configurable fraction of objects (sampling).

In step 5, how exactly are copies created?  There are three obvious options:

1. A source storage node could push copies to target storage nodes.
2. A target storage node could pull copies from source storage nodes.
3. This service could pull copies from source zones and push them out to target zones.

Options 1 and 2 both require a new component in each storage zone, and essentially require that all storage zones be updated to run the new component before this system could be used.  Further, any changes in this operation could represent a similar flag day.  Between the two of them, it seems likely that Option 2 seems like it would produce a simpler component that would be less likely to need to change (so fewer future flag days).

Option 3 has the major advantage of working without any changes to any other components in the system, but the major disadvantage of funneling all data through a single server.  This would be a major scaling limitation, described above.

These options aren't mutually exclusive -- the system could support both -- but implementing both would require more total investment up front as well as for ongoing testing and maintenance.

In step 7, how exactly will old object copies be deleted?  The system may be able to issue a DELETE request to nginx to remove the file.  (We would want to verify that this does remove the file and uses fsync correctly, as this operation is not currently used today.)  It would be nice if this system instead used the GC mechanism so that objects were tombstoned and could be recovered in the event of a bug.  However, it's different than traditional GC because the objectid still exists in Manta.  It's unclear if there are any implicit dependencies on this.
