---
authors: David Pacheco <dap@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent, Inc.
-->

# RFD 20 Manta Slop-Aware Zone Scheduling

Tickets: [MANTA-2801](https://devhub.joyent.com/jira/browse/MANTA-2801)

## Problem summary (for background, see below)

Today's Manta zone scheduling algorithm uses "task count" to compute each job's
share of the available zones on the system.  Although the implementation avoids
overcommitting memory or disk from the slop pools, it doesn't take slop usage
into account when determining shares.  That makes it possible for one job to use
all slop memory, inducing errors when subsequent jobs want to use any slop
memory at all.  (Since zone assignment is actually based on job and phase, not
just job, it's even possible for a map phase with a lot of tasks using slop
memory to cause the same job's reduce phase to fail because no slop memory is
available.)  It's nearly impossible for Manta consumers to work around this
problem.

In these cases, the preferred behavior would be for Manta to take slop usage
into account when determining the number of zones each group should get.  When
the second group shows up wanting slop, zones assigned to the first group should
be re-assigned to the second one.  As more slop is requested, zones allocated to
existing groups should shrink.  

We've always had this problem, but the increasing use of Dragnet to aggregate
Manta usage data is running into this more.  Data aggregation requires lots of
memory, and aggregating from a data source with lots of objects causes Marlin to
allocate lots of zones for these jobs and use up the slop pool.


## Background: Manta zone scheduling

Manta _zone scheduling_ refers to the algorithm that Manta uses to assign
compute zones to various end user jobs.  Broadly, allocation of zones to jobs is
based on the ratio of tasks outstanding for each job to the total number of
tasks in the system.  This is an online algorithm: we don't know how long each
job's tasks are going to take, and we start scheduling zones long before we know
how many tasks each job is going to have, so Manta constantly re-evaluates its
scheduling choices.

There are several points where a scheduling decision is made:

* When a new zone becomes available (after having just been reset), we have to
  figure out which task group, if any, to assign it to.
* Whenever a zone finishes executing any task, we have to decide whether it
  makes sense to keep this zone assigned to its current task group or re-assign
  it to some other group.
* When a new task group becomes runnable (roughly, when tasks first show up for
  a job), we have to find which available zone, if any, to assign it.
* When a new task arrives for an existing task group, we have to decide whether
  to allocate a new zone to increase the concurrency of the task group.
* Periodically, we sweep running groups to figure out if any of them has been
  using too much of its share for too long, in which case we will kill the
  currently-running task in order to trigger a zone re-assignment.

The details of the algorithm are explained in the [Big Theory Statement for the
Marlin
agent](https://github.com/TritonDataCenter/manta-marlin/blob/3203685ae50c9f8941e9c05c721f5c36b50e602e/agent/lib/agent/agent.js#L27-L183).
That explanation describes the competing design goals (maximizing resource
utilization while maintaining fairness), how our approach achieves that, and
several examples worked out to show how it works.


## Background: memory and disk slop

Tasks get a default allocation for both memory and disk.  (The number of zones
on each Manta storage node is configured in part based on how much memory and
disk will be used for these zones.)  End users can also request that some tasks
run with additional memory or disk.  To satisfy these requests, each storage
node maintains _slop_ pools of both memory and disk.  When we run a task that
requests extra memory or disk, that comes out of the corresponding slop pool.

Manta never overcommits from the slop pool.  If no slop is available when we
need to run a task that requests extra memory or disk, that task fails with a
`TaskInitError`.  This is not as common as it sounds because as long as that
task is part of a group that already has at least one zone, we will just run
tasks in the zones already allocated for that group.  This may mean that tasks
run sequentially, even though other zones are available for additional
concurrency, because we don't have enough slop to assign those zones.  Jobs only
see a `TaskInitError` when there's not enough slop available to assign the
_first_ zone for that group.  When they do happen, these `TaskInitError`s are
very bad for end users because there's nothing they can really do to avoid them.


## Background: implementation today

Today, Manta computes the _share_ for each task group as the ratio of the number
of tasks in that group to the total number of tasks in the system.  Groups with
more tasks are given more zones.  If a group represents all of the outstanding
tasks in the system, it has access to all zones.  (This discussion excludes the
reserve zones.)

Manta tries to keep each group at its _target_ number of zones, which is just
the share percentage times the total number of non-reserve zones.  This means:

* When a zone becomes available, we'll assign it a group that has fewer zones
  than the group's target.
* When a zone finishes executing a task for this group, we may re-assign the
  zone to another group if this group is over its target share.
* When new tasks show up for a task group, we add another zone to the task group
  if the group is below its target (computed with the new task included).
* If we find that a group has too many zones, we re-assign its zones as
  tasks complete.  This reduces concurrency, but gracefully, since we're not
  cancelling any running tasks.
* If a group has too many zones for too long, we'll start killing its tasks and
  then re-assigning its zones.  This ends up throwing away work, so we avoid
  this if possible.

The implementation is made more complicated by idle zones.  We keep zones idle
and assigned to jobs for a little while to avoid unnecessary zone resets during
bursty workloads (which is pretty common).  This makes computing target share,
and whether a group is over its share, a little more complicated.


## Proposal

Instead of computing each group's share as the percentage of tasks in the
system, we'll consider three shares:

* "concurrency share": the ratio of the count of this group's tasks to the total
  number of tasks in the system
* "memory share": the ratio of the count of this group's tasks _multiplied_ by
  the slop memory desired for each task to the total number of tasks in the
  system multiplied by the slop memory desired for each task.
* "disk share": the ratio of the count of this group's tasks _multiplied_ by
  the slop disk space desired for each task to the total number of tasks in the
  system multiplied by the slop disk space desired for each task.

Then, the final share is computed by taking the minimum of these three share
percentages.

Compared with the current system:

* When slop resources are not under contention, jobs can use all available slop
  resources, and the scheduling algorithm works the same as today.
* When slop resources are contended-for, then one of the two "slop shares" will
  reduce the number of zones assigned to each job that wants slop resources.
  But this sharing will be proportional to the desired amount of slop.
* There may be situations when there are idle zones even though there is more
  work to do, but in those cases, some other resource (either memory or disk)
  must be tapped out.

  An interesting case would be if slop was fully allocated, and we had some
  available zones, _and_ we had a job that required no slop, but couldn't be
  assigned the available zones because it was already at its concurrency share.
  However, it seems like this is already possible today: imagine you have two
  jobs: Job A has 500 tasks, each needing 1GB of memory slop.  Job B has 100
  tasks, each needing no slop.  The system has 100 non-reserve zones and 50GB of
  slop memory.  In this case, by share count, Job A would get 83 zones, and Job
  B would get only 17.  But slop availability caps Job A at 50 zones.  Job B
  still only gets 17, though.  This is inefficient, because Job B could get more
  zones.  This is already an issue, though it's not clear that it happens very
  often.
