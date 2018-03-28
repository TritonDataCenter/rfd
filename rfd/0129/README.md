---
authors: Tim Kordas <tim.kordas@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/89
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018 Joyent, Inc.
-->

# RFD 129 Manta Performance Bottleneck Investigation

## Overview

This RFD will propose questions about manta performance along with
some methods for answering same.

In a large scale manta deployment we have observed that manta throughput
hits metadata limits before data-storage limits. We will prioritize
performance investigation of metadata limits over data-path limits,
but eventually will need to address both.

## Background

A manta deployment consists of a loadbalancer layer, backed by a
collection of webapi/muskie processes. Webapi/Muskie is the "fork"
point where metadata is separated from bulk-data (Muskie
stores/retrieves the metadata information, and routes the bulk-data appropriately).

### Metadata data path

Metadata requests issued by Webapi/Muskie are sent to Electric-moray, which
functions as a load-balancer and router for the underlying sharded
store managed by Moray and Manatee (on top of Postgres).

We have observed that small changes in the database storage tier can
result in reduced throughput for a given shard. We will attempt to
answer questions throughout the metadata tier; but will iniitially
focus on the database tier, moving effort toward upstream services as
appropriate.

## Approach

We plan to set up a test lab with hardware consistent with that
used in a large manta deployment, but initially limited to a single
shard. We plan to set up additional hardware to evaluate
alternative hardware configurations for their performance
impact. Example hardware alternatives include: additional SSD storage,
or increases/decreases in the amount of main memory available in the
metadata nodes; and evaluation of software settings on such variant hardware.

The main baseline test setup will consist of a single shard instance
matched to the hardware used by the largest production manta
deploy. It is against this baseline system that our tests will be benchmarked.

In addition to testing against an experimental setup, we hope to also
extract metrics from a large manta deployment to observe real
production system behavior and use it to direct further experiments.

We plan on publishing relevant tools and data to a github repository:
https://github.com/joyent/manta-perf-testing

## Hardware

TBD

## Components

The components comprising the metadata storage tier in backend to
frontend order.

### Postgres/Manatee

* How many transactions per second are production deploys capable of
performing ?
* Are non-moray benchmarking tools helpful for testing our Postgres
  instances (e.g. pgbench or others).

#### Autovacuum

We have observed autovacuum operations on manta database tables (especially
xid-wraparound autovacuum) having a deleterious effect on manta
performance.

* Can we demonstrate the impact on manta-object creation performance
in a test rig ?
* Can the autovacuum cost limit/delay tuneables mitigate impact ?
(what are appropriate values for such tuneables)
* What is the mechanism by which autovacuum causes impact on manta
  work (IO starvation ?)
* Does the impact of xid-wraparound autovacuum differ appreciably from
ordinary autovavuum ?

#### SSD vs. HDD

We have preliminary results which are disappointing; and which
indicate that random-IO is not the limiting factor for manta postgres
storage.

* What are the bottlenecks on our HDD-based database storage ?
* Do SSDs help when faced with competing workloads (e.g. make the
system more autovacuum resistant)
* Why do we consistently see SSDs perform only slightly better than
  HDDs ?

#### Memory

For future manta metadata deployments, it would be good to understand
the performance impact of adding or reducing the amount of main memory
in the metadata tier systems.

* When allocating memory, should we dedicate more to shared_buffers ?
or leave it available for filesystem cache ?
* Does additional memory (as buffers or not) make the system more
resistant or more vulnerable to autovacuum issues?

#### Replication

We have had great success with the pg_prefaulter reducing WAL-apply
lag in our replicated Postgres setup, are there other aspects to our
replication setup which are impacting performance ?

* During shard async-rebuild latency increases substantially, what is
the limiting resource during rebuild ?
    * network ?
* Can the latency impact of async-rebuild be mitigated easily ?
* During normal operation are we throughput-limited by the wal-transport ?
* Are there tuneables available for improving performance of
replication ?
    * full_page_writes (turning *off* should reduce volume of WAL)
    * wal_compression (turning *on* should reduce volume of WAL)
    * wal_log_hints (turning *off* should reduce volume of WAL)
	* commit_delay (group commit time-window)

#### Other

* Are there other tuneables for query execution which we should be
modifying for our write-heavy workload ? (wal_buffers etc).
* Are any particular manta schema updates likely to improve
performance ?

### Moray

* Metrics from large production deployment
   * median/p90/p99 latencies for requests
* For a single Moray-instance, what is the upper bound on the number
of requests it can perform against the database ?
   * create
   * update
   * delete
* We have seen Moray consume lots of CPU, is this expected ?

### Electric-moray

We have seen Electric-moray "mis-route" work such that a very heavily
loaded Moray is assigned more work when there are other Morays in the
same shard that have no work.

* Metrics from large production deployment
   * median/p90/p99 latencies for requests
* Can we measure the distribution of work assigned to Moray instances
by an Electric-Moray instance ? (we currently collect little
performance data from deployed Electric-moray instances).
* What is the upper-bound on Electric-Moray's routing performance ?
* Are there any edge cases for very large numbers of shards ?
* Are there any edge cases for very large numbers of instances for a
single-shard ?
* Are there any edge cases for very "skew" in numbers of instances
between shards ?
* Does a non-random work assignment strategy improve performance ?

### Muskie

* Metrics from large production deployment
    * median/p90/p99 latencies for requests
* How many requests per second (for each endpoint) does Muskie receive
in production ?
* How fast can Muskie complete requests for zero-duration Moray
requests ?
* What are the intrinsic rate limits per Muskie-instance on
create/delete/update of objects ?
* How many requests execute for a complete manta-put of a particular
  object. That is /dirA/dirB/dirC/dirD/objABCD likely involves a
  series of putdir requests followed by a putobj request)

### Other services

#### Binder/DNS

Manta uses Binder's SRV records to do service discovery: each service
has a registrar instance responsible for maintaining its state in a
shared Zookeeper store. Binder uses the Zookeeper store as its source
of truth for deciding which service instances are available.

It is known that there are some limits to the number (and size ?) of
records, but we don't know how close current deployed systems are to
those limits, nor do we have any mechanism for alerting that such
limits have been hit.

* How does the system behave when we hit this limit
* How close are we to EDNS global response size limit (64Kbytes)
* How does the behavior of the system change when DNS responses grow
  beyond the 512-byte message limit for UDP ?

#### Authcache/Mahi

* Metrics from large production deployment
   * median/p90/p99 latencies for requests
* What are the limits in Mahi to the number of requests ?
* Is Mahi caching effective ?
* Are there any important edge cases to Mahi caching ?

#### Loadbalancer

* Metrics from large production deployment
    * median/p90/p99 latencies for requests
* Are there important limits to the number of external-IPs in the
  A-record for the manta-loadbalancer (related to DNS above, but
  externally-facing).

#### Additional measurements

* Metrics from large production deployment
   * median/p90/p99 latencies by shard
   * request rate by shard

### Tools

* mdshovel with single-shard enhancements
* a tool for harvesting/comparing configuration (possibly archiving
such configs over time ?)
* a tool for generating load based on muskie-logs
