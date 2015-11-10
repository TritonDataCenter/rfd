<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent, Inc.
-->

# What's this?

This is internal design documentation for the CA 2.0 **Instrumentation API.**


# Instrumentation API Overview

The goal of the Instrumentation API is to allow users to manage the collection
of performance data from the cloud, exposing:

* familiar OS-level metrics that users may want to plug into their own
  monitoring systems (e.g., CPU utilization, memory utilization)
* OS-level metrics that users wouldn't have known we could collect (e.g.,
  activity by subsecond offset)
* specific reports like CPU time flame graphs or TCP connection graphs
* application-level metrics that users wouldn't have known we could collect
  (e.g., DTrace-based metrics, like postgres queries by query string)

Ultimately, we want to make this data available in a real-time API and in Manta,
both via the CA 2.0 **Data API**.  We also want to make it available to other
systems like statsd or graphite, either by building those targets directly into
the Instrumentation API or else by building a connector from the Data API to
these other systems.


# Key concepts

The basic model is not significantly changed from CA 1.0.  We have:

* **metrics** (e.g., postgres.queries)
* **fields** (e.g., hostname, zonename, table name, query string)
* **instrumentations**, which configure collection of a specific metric.
  Instrumentations specify:
    * the *metric* to collect
    * a *predicate* to filter collection at the source
    * *fields* to decompose by
    * a *scope* that specifies a set of hosts (for operators only), zones, or
      tags describing hosts and zones
    * a *target* describing where to report data (e.g., data API, statsd)
    * *tags* on the instrumentation itself, so different consumers can organize
      their instrumentations
    * a *granularity* describing how fine-grained the data should be sampled


## Kinds of operations

* Create instrumentation (should probably be async)
* Delete instrumentation
* Search instrumentations
* For a given instrumentation, list which hosts/zones are being instrumented
* For a given instrumentation, refresh the set of hosts/zones being instrumented
* List which hosts/zones would be instrumented for a given instrumentation
  configuration


## Kinds of metrics

* kstat-based: for basic resource consumption
* ZFS-based: for filesystem consumption
* procfs-based: for basic process information
* DTrace-based: for more sophisticated, ad-hoc analysis

The set of IAPI metrics should be fixed.  Users can define their own metrics by
implementing their own collectors that report to the Data API.  There will be no
integration with the instrumentation API, but that's not obviously a problem.

We can even provide DTrace-based (MetaD-based) collectors that blast data at the
Data API.

From an implementation perspective, it would be cool if metrics could be
"downloaded" to an agent so that the agent didn't have to be upgraded in order
to support a new kstat-based or DTrace-based metric.


## Differences from CA 1.0

* Instrumentations have tags, allowing consumers to organize them.  This has
  been a longstanding pain point.
* Instrumentations can also be bound to users' existing VM tags, so that they
  can select sets of zones.  This too has been a longstanding pain point.
* We're keeping AMQP out of the design, as it's difficult to make horizontally
  scalable and redundant.
* Aggregation is totally outside this API.  Data reporting happens directly to
  the Data API, either over HTTP or UDP.


# Design

## Key design points

* One agent per host
* First cut: only report data to the Data API, using HTTP + WS or UDP.
* User configuration (instrumentations) lives in UFDS

## IAPI

IAPI is the name of the service that coordinates the instrumentation API.  It
receives requests from both cloudapi and workflows.

Cloudapi requests: create/delete/search, and other queries described under
"Operations" above.

Workflow requests:

* machine provisioned
* machine deprovisioned
* machine's tags have been updated

These trigger instrumentation refreshes -- that is, they cause IAPI to
reevaluate an instrumentation and figure out what agents should be instrumenting
it.

IAPI should also do this periodically to deal with manual changes (e.g., "vmadm
delete").

## Managing instrumentations

How does the system keep track of what agents are supposed to be doing what?  We
need to consider several cases:

* A new instrumentation is created (or destroyed) and the corresponding agents
  need to find out about it.
* A VM is provisioned (or deprovisioned) and the corresponding agents need to
  find out about any affected instrumentations.
* A VM's tags are updated and the corresponding agents need to find out about
  any affected instrumentations.
* An agent crashes and needs to figure out what it should be instrumenting.
* An IAPI instance crashes and needs to figure out if any state changes have
  occurred while it was down that it needs to propagate.

There are a few obvious approaches:

* Marlin-like approach, IAPI-managed: store a record in a Moray instance for
  each instrumentation for each agent that needs to know about it.  When any of
  the above instrumentation or VM changes happens, the SDC service notifies an
  IAPI instance, which reevaluates affected instrumentations and updates Moray
  records (writing new ones, invalidating old ones).  Agents poll for records
  associated with them that they haven't processed yet.  On startup, they fetch
  all records associated with them.  As an optimization, we use AMQP to notify
  agents that they should poll immediately.
* Marlin-like approach, agent-managed: state is stored similarly to the above
  approach, except that agents are responsible for figuring out which new
  instrumentations apply to them.  This pushes a lot more logic to the agent,
  and it's not clear how they can reliably learn about such changes anyway.
* IAPI as arbiter: IAPI keeps track of all instrumentations and which agents are
  responsible for what.  Additionally, agents and IAPI instances heartbeat via
  Moray or DNS.  When an agent starts up, it makes a request to an IAPI instance
  to find out what it's supposed to be doing.  When state changes happen, IAPI
  makes requests to the corresponding agents.  (The challenge here is that IAPI
  has to keep track of each agents' state so it knows whether to retry these
  requests.)
* IAPI as arbiter, refined: IAPI keeps track of all instrumentations and agents.
  Each agent has a "configuration" resource on IAPI.  On state changes, IAPI
  makes requests directly to the agents.  But the agent also periodically polls,
  using conditional HTTP GETs to cheaply figure out if anything has changed.

The thing that makes this easiest is if there's a single summary of what each
agent is responsible for, but this is tricky to deal with in a multi-IAPI world,
which we should assume from day 1.


# Open questions

* How does IAPI figure out what should be instrumented at any given time?
  (Presumably, it talks to VMAPI.)
* How does IAPI find out about changes?
    * Changes that happen through workflows (e.g., provision)
    * Changes that happen through vmadm (e.g., "vmadm delete")
* How do the agents know what they should be instrumenting?
* Do we want to allow users to run DTrace-based instrumentations indefinitely?
  It's not really the right way to do things, but it's also sort of arbitrary to
  say that you can't.
