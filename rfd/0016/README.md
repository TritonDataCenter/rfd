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
    Copyright 2015 Joyent, Inc.
-->

# RFD 16 Manta Metering

## Motivation

Manta performs a number of periodic "housekeeping" operations.  These include
daily jobs for:

* metering: reporting how much storage, compute, bandwidth, and other resources
  are used, on a per-user basis, and delivering per-user reports and activity
  logs
* garbage collection: cleaning up objects no longer referenced
* auditing: checking for Manta-level data corruption

Additional jobs that run on-demand are:

* cruft: identify objects unexpectedly left around that are no longer referenced
* rebalance: move object copies between storage nodes

There are a number of problems with the current implementation that require a
lot time spent on a daily basis by both engineering and operations to keep the
system functioning.  This RFD describes those issues, benefits for the current
system, and a suggested approach for resolving them.  The focus is on metering,
which is the source of most issues today, but several other components are
affected.


## Background

The jobs described above are all driven hourly or daily by the "ops" zone, which
is built from the [manta-mola](https://github.com/TritonDataCenter/manta-mola) repository,
with metering implemented by the
[manta-mackerel](https://github.com/TritonDataCenter/manta-mackerel) by reference.  The
various jobs and their relationships are described in the [documentation in that
repository](https://github.com/TritonDataCenter/manta-mola/blob/6f3b46703d9c906ee76ae884755acd377c815b1f/docs/index.md).

The jobs are much more interdependent than it might seem.  The daily process
broadly works like this:

* At 0000Z each day, the async peer in each PostgreSQL shard takes a ZFS
  snapshot of the current dataset, starts a separate PostgreSQL database
  instance using the copy in the snapshot, and dumps this data to a local file.
  The file is then uploaded to Manta for use by the various jobs.  This object
  represents a backup of the whole database for that shard at 0000Z that day.
* Some time later, each shard's backup object is "unpacked": it's transformed
  into a group of objects, one for each database table.  These objects represent
  a backup of the corresponding _table_ for that shard at 0000Z that day.
* Some time later, the daily metering, auditing, and GC jobs kick off, using
  these per-table backups as input.  The processes diverge at this point.

There are a few other jobs that go through different processes:

* There are also a number of hourly metering jobs that do not use these daily
  backups, but rather use log files uploaded hourly from services like Muskie
  and Marlin.
* There are daily summary jobs that operate on the previous day's metering job
  outputs.

All of these jobs are driven by cron, and each job knows nothing about its
logical dependencies.  As a result, correctness depends critically on all jobs
completing on time.  The discrete jobs and their schedules are described in the
["System
Crons"](https://github.com/TritonDataCenter/manta-mola/blob/6f3b46703d9c906ee76ae884755acd377c815b1f/docs/system-crons.md)
documentation.

It's probably worth reading through the Mola documentation to better understand
everything up to this point.


## Problems with the existing implementation

These are listed in rough order of impact today:

1. The most serious problem is that **the pipeline that drives all of these jobs
   is very brittle**.  This applies to metering, garbage collection, auditing,
   cruft, and rebalance jobs.  If the daily backup is late, or the unpacking job
   takes too long or experiences an error, then all of the other jobs fail or
   produce bad data.  If the daily metering jobs fail, the subsequent summary
   jobs also fail.  See
   [MANTA-2531](https://mnx.atlassian.net/browse/MANTA-2531).
2. **Error handling, particularly for metering jobs, is not clear.**  Metering
   jobs can experience a variety of issues of varying severity.  They mostly
   exit non-zero when these happen, causing the job to produce an error.  But
   the issue often only affects that one entry, and at most one user.  It's not
   clear to subsequent stages (e.g., summary jobs and monitoring systems)
   whether the output of that job is valid.  When debugging them, it's not easy
   to identify the issues.  See
   [MANTA-2759](https://mnx.atlassian.net/browse/MANTA-2759) and
   [MANTA-2756](https://mnx.atlassian.net/browse/MANTA-2756).
3. **The results of each job are not very observable.**  Questions that are
   impossible to answer include: how many objects were scanned?  How many users?
   How many objects were processed normally?  How many experienced a non-fatal
   error?  How many fatal errors were experienced?
4. **The jobs themselves are not very observable.**  This applies to all of
   these jobs.  It's not easy to look at the last N days' worth of each kind of
   job and see what happened.  See
   [MANTA-2593](https://mnx.atlassian.net/browse/MANTA-2593).
5. There are some unproven concerns about **scalability of some of the metering
   processes**.  In various cases in the past, we've observed metering processes
   running out of memory without an obvious leak, where the process itself was
   just attempting to keep track of an enormous amount of data (e.g., metadata
   for each object owned by a given account).  We can conceivably address this
   by tuning up the number of reducers, but that only goes so far.  See
   [MANTA-2780](https://mnx.atlassian.net/browse/MANTA-2780).
6. **Many of the tasks used by these jobs are very long-running.**  Manta jobs
   were designed around tasks that would complete in a few seconds to a few
   minutes.  When very large tasks are used, jobs get less parallelization,
   they're more significantly affected by transient issues (because retries end
   up taking a very long time), and they're subject to new failure modes (like
   Manta killing the job for using zones for too long).
7. The automatically generated per-user reports and activity logs grow unbounded.

Solutions to these problems can be grouped into a few broad categories:

* Items (1) (the brittle execution pipeline) and (4) (recent job observability)
  can be addressed using a system like
  [Chronos](https://github.com/TritonDataCenter/chronos), possibly coupled with triggers,
  to manage job execution and dependencies.
* Items (2) (error handling) and (3) (error reporting) likely require
  considerable re-work of the bodies of the metering jobs.  Each task should
  keep track of the unexpected events, the severity of each event, and example
  instances of each event for later debugging.  This metadata should be passed
  through the job pipeline so that a final report can include information
  about failures across the whole job.  This would allow consumers to figure out
  if the job really succeeded or not (based on the presence of severe errors),
  and the rest of the metadata would be useful for humans to debug specific
  failures and to track scalability over time.  This obviously requires
  considerable rework, but the sum total of all of the metering job code appears
  to be about 1900 lines of code -- it's not a huge component.  There's a bunch
  more code that manages job execution, but for the reasons mentioned above,
  that has a lot of issues as well.
* To address item (5), we need to examine the affected jobs and re-architect
  them to avoid such heavy memory usage.  Again, these jobs aren't actually that
  large or complex.
* To address item (6), we could consider modifying the transform step
  of the daily pipeline to produce a much larger number of objects for each
  table (rather than one), which would allow the rest of the jobs to start on
  much smaller tasks.
* To address item (7), we could  could allow customers to opt-in and out of the 
  metering reports being delivered.

## Important parts of the existing implementation

* It's primarly made up of a few relatively simple map-reduce jobs.
* It has a lot of amon alarms that fire when things go wrong.  However, as with
  nearly all other amon alarms, it's generally pretty labor-intensive to figure
  out what actually went wrong or what to do about it when one of these fires.
* There's a single command-line tool that allows operators to re-run any part of
  the pipeline.  However, it does not take dependencies into account.
* There are a number of parameters that allow pieces of the metering code to be
  executed independently or in test modes.  That said, these are often not that
  well-documented, and often assume a number of variables are set correctly for
  testing, so this is a little hard to use.
* There are a lot of tests.  However, these are not well-documented, and they're
  likely not factored in a way that would be directly usable in a rewrite.


## Incremental development and rollout

As mentioned above, the code for all of these jobs is delivered by the "ops"
zone, which is driven from the "mola" repo.  For this project, it's suggested
that we create a new zone class representing version 2 of the daily pipeline.
It should start with an arbitrarily small piece of functionality (e.g.,
executing the daily transform job).  It can be augmented piece-by-piece until it
contains as much of the existing "ops" functionality as we feel prudent to
reimplement.  Here's a straw-man schedule:

* Phase 1: a new service delivers a Chronos-like mechanism for reliable
  execution of periodic jobs, along with configuration to execute the daily
  pipeine jobs that transform daily database backups into per-table JSON
  objects.  The old "ops" zone continues to operate the rest of the pipeline,
  including metering.
* Phase 2: besides producing a per-table object, the new version also produces
  chunked per-table objects (see the solution to item (6) above).  This version
  also delivers a new metering implementation based on these chunked table
  objects.  (Even this can be broken into sub-parts: we could start with storage
  metering in a phase 2A, followed by request metering in phase 2B, followed by
  access log deliver in phase 2C, and so on.)  As before, whichever parts are
  not done by the new implementation are done by the old one.
* Some time later: the daily garbage collection, audit, rebalance, and cruft
  jobs are moved over to the new Chronos-based job executor in the new zone.

In this way, both the old and new versions run side-by-side for a while until
we're satisfied with the new implementation.  This significantly de-risks each
piece of the work, since we can always fall back to the old implementation.  We
can also build the new implementation from the ground up without worrying about
the many points of integration between these various components (while still
deploying it incrementally).

The main open question is how to configure which parts of the old "ops" pipeline
get executed.  The simplest solution is to allow the entire old pipeline to
continue to run, and build the new system to put outputs in a different place.
This is trivial to implement, though it will cause us to use a significant
amount more physical resources while both systems are deployed, since poseidon
jobs are responsible for a lot of compute resource usage.  A fairly simple
mechanism to address this would be to add boolean SAPI tunables for turning off
various parts of the old pipeline.  When we deploy a new version of the new
component, we run both versions for a few days, check the output, and then flip
the tunable to turn off the corresponding part of the old component.  (We
definitely don't want to have flag days every time functionality moves from the
old to the new component.)
