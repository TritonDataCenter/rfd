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

# RFD 115 Improving Manta Data Path Availability

This RFD discusses availability of Manta, including what that means, how we
measure it, how we manage it, and concrete steps to improve it.  This RFD
considers only data path availability, not availability of the jobs tier or any
of the system's internal functions (like garbage collection, metering, auditing,
and resharding).

This RFD is divided into several sections:

- Defining data path availability
- Measuring error count and latency
- Causes of data path unavailability (a survey of known causes of downtime)
- Suggested software changes
- Possible process changes


## Defining data path availability

Broadly, availability of a service means that it's working.  Availability is
often measured in terms of the percentage of client requests that complete
successfully.  But a concise target like "99.9% available" hides a number of
assumptions that affect the calculation: which requests are included, what
constitutes a successful request, over what period that is measured, and within
what load parameters that target is expected to be met.  A more complete
discussion of these factors is contained in the appendix below.

We propose that for Manta, "99.9% availability" means that when the system
receives incoming requests at a rate within the expected capacity of the system,
the percentage of requests completing with a 500-level HTTP response code in any
given 5-minute calendar window is no more than 0.1% of total requests in that
interval.  While this target does not explicitly incorporate latency, internal
timeouts on request processing do imply an upper bound on the order of tens of
seconds for time-to-first-byte.

Some large deployments additionally have an inbound or outbound throughput
target that, combined with a concurrency level, could imply a latency target.
For this purpose, an average latency may prove more useful than a 99th
percentile latency value.  More research is needed to determine an appropriate
target for latency.


## Measuring error count and latency

Measuring the underlying metrics for availability (error rate and latency)
presents its own challenges:

- Log files vs. live metrics: Polling live metrics is much more efficient than
  processing log files, though this approach loses data proportional to the
  polling interval when a component crashes.  Log files would include this data,
  but still lose information about in-flight requests when the component
  crashes.
- Observation from Muskie vs. Loadbalancer: Measuring at Muskie doesn't quite
  represent what end users see, since end users can see timeouts even when
  Muskie successfully completes a request.  However, the loadbalancer doesn't
  have per-request context, so we can't get a useful request error rate from
  them.  Even if they did, this would not reflect problems clients are having
  reaching the loadbalancers.
- Observation from clients would address some of the pitfalls of observing at
  either Muskie or the Loadbalancer, but we don't generally control clients, and
  we can't generally collect performance or error data from them (at least not
  today).  We can generate our own load from our own clients, but this is only
  representative for major issues or when the simulated load comprises a
  sizable fraction of requests.

Generally, the most efficient, reliable way to measure the error rate and
latency uses the Muskie live metrics.  We use loadbalancer metrics and simulated
clients (e.g., mlive) to supplement this, and potentially as a way to detect
incidents, but they don't provide a useful way to measure availability.


## Causes of data path unavailability

We group data path unavailability into two broad categories:

- simple failures: planned upgrade, transient fatal failure, and extended fatal
  failure of individual instances
- complex failures: non-fatal failure and failures affecting entire multiple
  instances

### Simple instance failure

The impact of individual instance failure depends on the service.  Here is a
summary, ordered roughly by increasing severity:

Component       | Upgrade                                      | Transient failure | Extended failure
--------------- | -------------------------------------------- | ----------------- | ---------
nameservice     | no impact                                    | no impact         | no impact
authcache       | in-flight requests only, 100% mitigatable    | in-flight         | in-flight
electric-moray  | in-flight requests only, 100% mitigatable    | in-flight         | in-flight
moray           | in-flight requests only, 100% mitigatable    | in-flight         | in-flight
webapi          | in-flight requests only, 100% mitigatable    | in-flight         | in-flight
storage         | ~1m, limited, mitigatable                    | in-flight         | same as upgrade, for duration of failure
loadbalancer    | ~1m, mitigatable                             | in-flight         | same as upgrade, for duration of failure or until removed from DNS
postgres        | ~1-5m, _not_ mitigatable                     | ~1m               | same as upgrade, for ~1-5m

In all cases, only end-user requests that require requests to the specific
instances are affected.  That is, if there are 90 "webapi" instances and one is
upgraded, then we'd expect that about 1.1% of requests in-flight at the moment
of upgrade would be affected.

Explanations:

**nameservice**: Data path DNS resolution uses Cueball, which makes DNS requests
outside the per-request path, tries multiple nameservers, and caches results as
long as needed.  As a result, all single failures, transient or extended,
generally have no impact.

**authcache**, **electric-moray**, **moray**, and **webapi**: The impact of a
all single failures, transient or extended, is that in-flight requests fail.
Subsequent requests are generally not affected because clients of these servers
stop using a backend instance that's offline.  For upgrade, impact can be
completely avoided operationally via SOP-267, which mostly involves removing
these instances from service discovery, waiting for that information to
propagate, then completing the update.

**storage**: For all write requests and for read requests for objects with at
least two copies (the default), the impact a single storage zone failure is that
in-flight requests fail.  Similar to the components above, subsequent requests
will avoid this zone, and the impact can be completely mitigated operationally.
(Reads for objects with only one copy stored in the affected zone will fail
while the zone is offline.  For upgrades, this is usually about 1 minute.)

**loadbalancer**: Transient failures affect only in-flight requests.  Extended
failures affect all requests to this zone while the zone is offline unless an
operator removes the public IP from public DNS (and that propagates).  For
upgrades, this typically takes about 1 minute, and it's operationally avoidable
as with the other zones.

**postgres**.  All single-instance failures, transient or extended, are expected
to impact service for ~1-5 minutes, either for the component to be restarted or
failover to occur.  In both cases, PostgreSQL may need to replay any
uncheckpointed WAL records, which we operationally try to limit to only a few
minutes' worth of work.  There is no SOP for operationally mitigating this
today.


### Complex failures

We believe that the vast majority of Manta unavailability in both JPC and SPC in
the last year has resulted not from simple component failure described above,
but more complex failures.  These are not so easily categorizable, so we will
take them in turn.

**PostgreSQL lag and associated issues.**  In 2017, we found that Manta was
susceptible to major downtime incidents relating to PostgreSQL replication lag.
This has been discussed extensively in tickets like
[MANTA-3283](https://smartos.org/bugview/MANTA-3283), MANTA-3402, and many
incident tickets.  Fundamentally, there are two types of lag that can
accumulate:

- replication replay lag, which reflects transactions that have been replicated
  but not yet applied.  This can accumulate without bound on both sync and
  async peers.  Failover time is bounded below by the time required to replay
  these transactions, and this is a constraint from PostgreSQL.  Further,
  transient replication failures (e.g., a TCP connection failure between primary
  and sync) can result in downtime windows for the time required to catch up
  again.
- checkpoint lag, which reflects data replicated and applied, but not yet
  checkpointed.  This affects primaries, syncs, and asyncs.  With the current
  Manatee implementation, failover time is bounded below by the time required to
  replay uncheckpointed transactions on all peers.

Replication lag accumulates when WAL write speed on the primary exceeds replay
speed on the sync and async.  As a result, lag issues can be caused either by
excessive write volume or pathological replay performance.  There are two
factors that contribute to high write volume:

- High client write volume intrinsically results in large WAL volume.  This is
  unavoidable, but is believed to be a small part of the problem (relative to
  other issues below).
- The current Manta schema is believed to contribute to more WAL writes than
  necessary: see MANTA-3399,
  [MANTA-3401](https://smartos.org/bugview/MANTA-3401).  Addressing this
  requires [MORAY-424](https://smartos.org/bugview/MORAY-424) and
  [MORAY-425](https://smartos.org/bugview/MORAY-425).  (These changes may also
  significantly improve the overall object write throughput of each shard.)
- This in turn was exacerbated by the default directory structure used for
  multi-part uploads.  This was fixed in the software under
  [MANTA-3427](https://smartos.org/bugview/MANTA-3427) and
  [MANTA-3480](https://smartos.org/bugview/MANTA-3480) and deployed under
  CM-1356.

While high write volume can be a problem, the far bigger problem was slow replay
performance, which was caused by a number of issues:

- While write operations on the primary database are serviced by hundreds of
  threads, replay operations on downstream peers are serviced by a single
  thread.  This is a deep issue with the PostgreSQL replication design.  We
  worked around this (fairly successfully) by creating our own prefetcher,
  called [pg\_prefaulter](https://github.com/joyent/pg_prefaulter).
- Databases were initially deployed with a 16K recordsize (see
  [MANATEE-330](https://smartos.org/bugview/MANATEE-330)).  Because PostgreSQL
  writes 8K blocks, a large number of PostgreSQL write operations required a
  read-modify-write in ZFS.  Once the database size exceeded physical memory,
  the streaming write workload effectively became a random read workload.  We
  changed the recordsize for new deployments to 8K under
  [MANATEE-370](https://smartos.org/bugview/MANATEE-370), and we applied that
  operationally to the SPC under MANTA-3453, CM-1329, and CM-1341.  The
  mismatched record size was a major contributor to both replay lag and
  checkpoint lag.
- One deployment used a particular model of disk drive that we found would
  starve read operations in the face of writes.  Ticket ROGUE-28 describes in
  detail how a round of read operations would remain outstanding while the disk
  completed several rounds of write operations.  We have removed this model of
  disk from all SPC deployments.

The combination of these last three issues was especially devastating: what
should have been a streaming write workload became a random-read workload from a
single-thread from disks that would starve read operations for seconds at a
time.

Lag alone does not induce downtime -- another failure is required to do that.
Most commonly:

- An unusually high rate of uncorrectable ECC errors in DIMMs, resulting in
  a large number of unexpected system resets.  This is described in OPS-2638.
- Operating-system non-responsiveness resulting from memory allocator reap
  activity (see [OS-6363](https://smartos.org/bugview/OS-6363), now fixed).
  This issue was exacerbated by
  [MANTA-3338](https://smartos.org/bugview/MANTA-3338), also now fixed.
- PostgreSQL timing out replication connections as a result of OS-6363.  This
  behavior was disabled under
  [MANATEE-372](https://smartos.org/bugview/MANATEE-372).

It remains true that when lag is high, major network disruptions or transient
failures of a compute node, the operating system, or PostgreSQL itself can
result in extended downtime.  However, **with the above mitigations in place**
(MPU directory structure changed, prefaulter in place, recordsize changed to 8K,
poorly-performing disks swapped out), **we have not seen a significant
accumulation of lag under the normal workload**.  With OS-6363 and MANATEE-372
fixed and a reduced rate of DIMM failures, we believe we have had many fewer
instances of a replication connection being severed unexpectedly.

As part of working these issues, we addressed several queueing issues in Moray,
including [MORAY-397](https://smartos.org/bugview/MORAY-397) and
[MORAY-437](https://smartos.org/bugview/MORAY-437).  Additional improvements are
also planned.  Some of these had the side effect of turning previously long
requests into failures, resulting in other incidents.  We updated the
configuration to reduce this, and it has not been a problem since the above
changes to fix pathological PostgreSQL performance.

**Memory leaks (and excessive usage)**  We have had a couple of memory leaks (or
excessive memory usage) that contributed to a significant increase in latency
and reduction in overall system throughput.  In extreme cases, this could result
in timeout errors from clients.  These are covered by
[MORAY-454](https://smartos.org/bugview/MORAY-454),
[MANTA-3538](https://smartos.org/bugview/MANTA-3538), and
[MORAY-455](https://smartos.org/bugview/MORAY-455), all of which have been
fixed.  These issues were generally root-caused from the initial occurrences
using postmortem debugging (i.e., core files and mdb\_v8).  They were fixed and
the fixes deployed within a few days.  We also had instances that were more
complex to debug (such as [MANTA-3338](https://smartos.org/bugview/MANTA-3338)).

**Network switch failures.**  In JPC, NETOPS-852 (blocked ports resulting from a
firmware issue on certain switches) has resulted in a number of storage zones
becomes unreachable.  This has resulted in at least two incidents in which not
enough storage zones were available to allow Manta to take any writes.

**Insufficient quotas on some Manatee zones after transient failures.**  Under
SCI-297 and related incidents, we saw shards fail after having run out of local
disk space.  The cause is believed to be one of MANATEE-386, MANATEE-332, or
MANATEE-307, where cleanup mechanisms have failed fatally.  This has generally
been mitigated via monitoring until the underlying issues are addressed.

**Incorrect service discovery from loadbalancers.**  Several issues (now fixed)
caused loadbalancers to continue to use webapi instances that were not healthy,
or caused loadbalancers to be restarted when not necessary.  These are discussed
under [MANTA-3079](https://smartos.org/bugview/MANTA-3079) and
[MANTA-2038](https://smartos.org/bugview/MANTA-2038) (both now fixed).

**Transient connection management issues.**  A very small ambient error rate was
caused by [MORAY-422](https://smartos.org/bugview/MORAY-422) (now fixed).

**Resharding.**  Resharding operations currently require individual shards to be
offline for writes while hash rings are updated in all electric-moray instances.
(See [RFD 103](https://github.com/joyent/rfd/blob/master/rfd/0103/README.md).)
The severity of this is not very clear because immediate plans only involve
resharding regions that are already out of capacity, and future reshard
operations are not yet clear.

**Major database upgrades.** Last year saw major PostgreSQL updates from 9.2 to
9.6 in production deployments.  In stock configuraiton, this requires several
hours of downtime per shard because peers need to be rebuilt and replication
re-established.  Options exist to improve this (e.g., allow writes to only the
single peer during this mode); however, at this time, we do not expect to make
another major PostgreSQL upgrade in the foreseeable future.


### Out-of-scope causes

**Transit issues.** A number of client-visible incidents have resulted from
failures in the network circuits being used between clients and Manta.  These
are beyond the scope of this RFD.

**Insufficient storage capacity.**  In several SPC deployments, Manta ran out of
capacity well ahead of the ability to provision more.  This seems worth
mentioning, but this failure mode is beyond the scope of this RFD.




## Suggested software changes

We believe that most of the downtime in the last year was not caused by simple
component failure or planned updates.  (Interestingly, very few issues appear
to have started with rollout of a bad change.)  That said, most of the complex
failures leading to downtime have been addressed already, leaving mostly work
to reduce the impact of planned updates and PostgreSQL takeovers:

Summary                           | Severity | Tickets
--------------------------------- | -------- | -------
postgres: planned takeover time   | high     | [MANATEE-380](https://smartos.org/bugview/MANATEE-380), [MANTA-3260](https://smartos.org/bugview/MANTA-3260)
postgres: unplanned takeover time | high     | [MANTA-3260](https://smartos.org/bugview/MANTA-3260)
webapi: planned updates           | moderate | [MANTA-2834](https://smartos.org/bugview/MANTA-2834)
loadbalancer: planned upates      | moderate | N/A -- needs further specification
resharding: write downtime        | moderate | [MANTA-3584](https://smartos.org/bugview/MANTA-3584)
moray: planned updates            | low      | [MANTA-2834](https://smartos.org/bugview/MANTA-2834), [MANTA-3233](https://smartos.org/bugview/MANTA-3233)
electric-moray: planned updates   | low      | [MANTA-2834](https://smartos.org/bugview/MANTA-2834), [MANTA-3232](https://smartos.org/bugview/MANTA-3232)
authcache: planned updates        | very low | [MANTA-2834](https://smartos.org/bugview/MANTA-2834), [MANTA-3585](https://smartos.org/bugview/MANTA-3585)
storage: planned updates          | very low | [MANTA-3586](https://smartos.org/bugview/MANTA-3586)
postgres: major version bump      | very low | N/A -- needs further specification

A few incidents were caused by operational problems that can be monitored --
e.g., switch port failure or unexpected high disk utilization.  These
conditions are currently being monitored, and more sophisticated monitoring is
also being put together.

Additionally, in order to be able to confidently update components without fear
of generating incidents, we should be seriously considering canary deployments.
See [MANTA-3587](https://smartos.org/bugview/MANTA-3587) for details.


## Possible process changes

It's one thing to address known causes of unavailability in order to maximize a
service's uptime.  If we want to establish specific consequences for quantified
levels of downtime (i.e., an SLA with specific availability targets), we would
want to:

- Establish better historical monitoring of error rates.  We have historical
  data in access logs, but we only have a limited amount of data readily
  accessible in real time, which makes it very hard to evaluate an historical
  error rate.
- Establish a target error budget, as described in [The Calculus of Service
  Availability](https://queue.acm.org/detail.cfm?id=3096459).  An error budget
  quantifies the amount of downtime per period (e.g., per month) that's allowed
  by the SLA.  This provides criteria for operational decision-making -- for
  example, if we want to roll out a risky change, we can use the error budget to
  assess our current risk tolerance.  Obviously, this is only effective so long
  as the availability requirements that define the error budget actually match
  customers' expectations.
- Establish better ways of associating specific periods of downtime with
  specific issues.  In order to prioritize work on improving availability, we
  want to quantify the error budget consumed by each issue.
- Implement canary deployments with straightforward rollback controls, mentioned
  earlier.  This piece is essential to be able to reliably deploy updates when
  any downtime is so costly.  (As an example, in at least two of the cases
  involving memory leaks that resulted in significant reductions in Manta
  throughput, a canary-based deployment ought to have quickly identified the
  issue and facilitated rapid rollback.)

At this time, it's not clear whether we want to focus on quantifying an error
budget, but the other pieces are likely worth prioritizing.



## Appendix: Defining Availability

This section discusses a number of assumptions that go into a phrase like "99.9%
availability".

**Over what time period is the rate measured?**  For an issue that affects 5% of
requests in a 5-second window, what's the impact to availability?  Over those 5
seconds, availability might be 95%.  Over the surrounding minute, availability
might be 99.6%.  Within arbitrarily short periods within that window,
availability might be 0%.  In reality, these windows are often not even so
well-defined as "5% of the requests over a 5-second period", so choosing the
time interval becomes a real problem.  Further, the finer this interval, the
more expensive it is to measure availability.

**Exactly what constitutes a successful request?  Does latency count?**  In many
systems, performance is part of correctness -- and certainly pathological
performance often results in broken systems.  If Manta completes all requests
with successful status codes, but at twice the normal latency (or half the
normal request throughput), is that still considered 100% available?  This
question has deep implications for at least two reasons.

First, internal to a distributed system, when an internal subrequest encounters
an error, there is often a choice to be made: fail the entire end user request
or retry the subrequest (possibly to a different backend instance).  And there's
a corresponding tradeoff: retrying the request can increase the probability of a
successful end user request, but at increased latency, particularly if the
nature of the underlying failure is a timeout.  This approach can result in
architectures where several layers of the stack issue retries, resulting in
potentially significant latency.  Additionally, in many situations, it's
preferable to have a quick failure than a slow one.  For this reason, Manta
takes as a design principle that we should avoid retries for internal requests,
and rather that end users should retry requests according to whatever policy
works for them.  This is the most transparent option, but has downsides of its
own: clients need to know to retry, and when they don't, they perceive that
availability is worse than it would be with the other approach.  Even with
effective retry policies in clients, this approach makes typical metrics of
availability look worse -- a real problem that presents real monitoring and
organizational challenges.

Another example of a major design choice affected by whether latency is part of
availability is that there are several situations today that result in periods
of brief unavailability that are architecturally very difficult to eliminate,
including brief periods of transition during resharding operations.  One
approach to addressing this is to simply pause incoming requests during this
window.  This can technically eliminate failures -- at a potentially significant
hit to latency.  Which approach is actually preferable?  This may depend on end
users.

**Does it matter which requests are affected?**  Many incidents affect only some
class of operations -- such as write operations, or write operations only to
particular subsets of the Manta namespace.  If the write completion rate is 0%,
but writes make up only 1% of the workload, are we still satisfied that the
service is 99% up?

**What about when a system is overloaded?**  If a service is physically built
out to process 1 million requests per second and receives 10 million requests
per second, the best-case scenario is a 10% success rate.  (In practice,
achieving this is itself quite difficult.)

Public cloud environments present the illusion of infinite capacity, but
physical systems have limits; this only works in public clouds because most
individual customers there are small enough that major changes in their behavior
do not meaningfully affect the system's utilization in the short term, and in
the long term, utilization changes are predictable enough that additional
physical capacity can be built up before growth results in overload.

The situation is different for managed, private deployments, which are often
built to meet specific target capacities for a small number of end users.
Operators are still expected to monitor utilization and plan capacity expansion
to avoid overload, but behavior changes by the handful of end users can
significantly affect overall utilization in the short term.

[Service-level agreements
(SLAs)](https://en.wikipedia.org/wiki/Service-level_agreement) exist to define
expectations between customers and service providers, and real-world SLAs define
consequences for missing targets.   See, for example, the [Amazon S3
SLA](https://aws.amazon.com/s3/sla/), which only considers explicit error
responses (i.e., ignores latency); examines error rate in 5-minute windows; and
credits end users based on a monthly average of these error rates.
