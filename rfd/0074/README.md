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
    Copyright 2016 Joyent, Inc.
-->

# RFD 74 Manta fault tolerance test plan

Manta is designed so that it can be deployed to survive failure of any
individual software component, compute node, rack, or availability zone.  This
has been exercised in various configurations, and more regularly on a
per-component basis as people work on individual pieces.  This RFD proposes a
comprehensive test plan for failures that Manta is expected to survive with
minimal impact.  This plan does not cover combinations of failures that are not
expected to be survivable, like failing a majority of ZooKeeper nodes.

## Overview

We want to test transient failures of software components, CNs, and
availability zones.  We also do partition testing.  Partitions have been pretty
rare in Manta deployments, but they do happen, and they're also a reasonable
proxy for CN failure that's easier to induce and control (thanks to
[ipdadm](https://smartos.org/man/ipdadm)).

Failures affecting the following components have potential impact to the data
path, so they're the highest priority.  Known issues related to them are fixed
(or fixes are in progress), so they can be thoroughly tested:

* authcache
* electric-moray
* moray
* nameservice
* postgres
* storage
* webapi

"loadbalancer" is omitted because primarily external clients talk to them, and
when they fail, there's little we can do to measure or mitigate the impact.  It
would be good to verify that our default clients behave reasonably when
loadbalancers fail, but that's outside the scope of this RFD.

The following job-related services are lower priority:

* medusa
* jobpuller
* marlin-agent: there are some known issues around certain types of partitions, but these would generally not affect CN failure.
* jobsupervisor: there are some known issues around certain types of partitions, but these would generally not affect CN failure.

The following components have essentially no impact on user-facing activity
when they're not functioning, so testing is low priority:

* ops
* marlin-dashboard
* madtom

## Testing data-path components

There are several kinds of tests listed below:

* "restarting an instance's service" means restarting the SMF service for the
  instance
* "disabling an instance's service" means disabling the SMF service for the
  instance
* "removing an instance from/to DNS" means disabling the registrar SMF service
  for the instance and verifying that the instance stops getting used within 2
  minutes.  After that, the registrar SMF service should be enabled, and it
  should be verified that the instance starts being used again within 2 minutes.
* "halting/booting an instance" means halting the zone, confirming minimal
  impact on the data path for at least 10 minutes, then boot the zone and
  verify that the instance starts getting used within 2 minutes.
* "partitioning an instance" means using ipdadm(1) to introduce a 100% packet
  drop for the instance's zone.  Confirm minimal impact on the data path for at
  least 10 minutes.  Remove the packet drop and verify that the instance starts
  getting used within 2 minutes.

Note: tests involving loss of network connectivity wait at least 10m to cover
TCP ETIMEDOUT errors.

For each component, pick an instance and apply the suggested test.  Watch the
impact on error rate and latency during the event and for several minutes after
the event.  Unless otherwise specified, we'd expect that during a test, we
might see an elevated error rate (at most about 1/ninstances requests) for up
to 30 seconds, but there should be no significant impact on latency or error
rate beyond that.

In all cases, there should be no core files produced, no services restarted,
and only expected "error"-level log entries.

Open questions:
- Does it make sense to add a "pstop" test?  What real-world failure does this
  emulate?
- How can we exercise a variety of users for the authcache test?  Or should we
  reduce the muskie cache period?

### List of zone-level tests for data path components

The tests here refer to specific procedures described above.

Notes | Component                     | Test
----- | ----------------------------- | -----------
|      | authcache                     | test restarting an instance's service
|      | authcache                     | test disabling an instance's service (wait at least 5m)
|[1](#footnote1)   | authcache                     | test removing/adding an instance from/to DNS (wait at least 7m)
|[1](#footnote1)   | authcache                     | test halting/booting an instance (wait at least 10m)
|      | authcache                     | test partitioning an instance
|      | electric-moray                | test restarting an instance's service (haproxy)
|      | electric-moray                | test restarting an instance's service (electric-moray)
|      | electric-moray                | test disabling an instance's service (haproxy)
|      | electric-moray                | test disabling an instance's service (electric-moray)
|      | electric-moray                | test removing/adding an instance from/to DNS
|      | electric-moray                | test halting/booting an instance
|      | electric-moray                | test partitioning an instance
|      | moray, shard 1                | test restarting an instance's service (haproxy)
|      | moray, shard 1                | test restarting an instance's service (moray)
|[2](#footnote2)   | moray, shard 1                | test disabling an instance's service (haproxy)
|[2](#footnote2)   | moray, shard 1                | test disabling an instance's service (moray)
|[2](#footnote2)   | moray, shard 1                | test removing/adding an instance from/to DNS
|[2](#footnote2)   | moray, shard 1                | test halting/booting an instance
|[2](#footnote2)   | moray, shard 1                | test partitioning an instance
|      | moray, shard 2                | test restarting an instance's service (haproxy)
|      | moray, shard 2                | test restarting an instance's service (moray)
|      | moray, shard 2                | test disabling an instance's service (haproxy)
|      | moray, shard 2                | test disabling an instance's service (moray)
|      | moray, shard 2                | test removing/adding an instance from/to DNS
|      | moray, shard 2                | test halting/booting an instance
|      | moray, shard 2                | test partitioning an instance
|      | webapi                        | test restarting an instance's service (haproxy)
|      | webapi                        | test restarting an instance's service (muskie)
|      | webapi                        | test disabling an instance's service (haproxy)
|      | webapi                        | test disabling an instance's service (muskie)
|      | webapi                        | test removing/adding an instance from/to DNS
|      | webapi                        | test halting/booting an instance
|      | webapi                        | test partitioning an instance   
|      | storage                       | test restarting an instance's service (mako/nginx)
|      | storage                       | test disabling an instance's service (mako/nginx)
|      | storage                       | test removing/adding an instance from/to DNS
|      | storage                       | test halting/booting an instance
|      | storage                       | test partitioning an instance
|      | nameservice (1st)             | test restarting an instance's service (binder)
|      | nameservice (1st)             | test restarting an instance's service (ZooKeeper)
|      | nameservice (1st)             | test disabling an instance's service (binder)
|      | nameservice (1st)             | test disabling an instance's service (ZooKeeper)
|      | nameservice (1st)             | test halting/booting an instance
|      | nameservice (1st)             | test partitioning an instance
|      | nameservice (ZK leader)       | test restarting an instance's service (binder)
|      | nameservice (ZK leader)       | test restarting an instance's service (ZooKeeper)
|      | nameservice (ZK leader)       | test disabling an instance's service (binder)
|      | nameservice (ZK leader)       | test disabling an instance's service (ZooKeeper)
|      | nameservice (ZK leader)       | test halting/booting an instance
|      | nameservice (ZK leader)       | test partitioning an instance
|      | postgres (async)              | test restarting an instance's service (manatee-sitter)
|      | postgres (async)              | test disabling an instance's service (manatee-sitter)
|      | postgres (async)              | test halting/booting an instance
|      | postgres (async)              | test partitioning an instance
|[3](#footnote3)   | postgres (sync)               | test restarting an instance's service (manatee-sitter)
|[4](#footnote4)   | postgres (sync)               | test disabling an instance's service (manatee-sitter)
|[4](#footnote4)   | postgres (sync)               | test halting/booting an instance
|[4](#footnote4)   | postgres (sync)               | test partitioning an instance
|[3](#footnote3)   | postgres (primary)            | test restarting an instance's service (manatee-sitter)
|[4](#footnote4)   | postgres (primary)            | test disabling an instance's service (manatee-sitter)
|[4](#footnote4)   | postgres (primary)            | test halting/booting an instance
|[4](#footnote4)   | postgres (primary)            | test partitioning an instance

Notes:

<a name="footnote1">1.</a>  Authcache tests add an extra 5m because of muskie's cache.

<a name="footnote2">2.</a> For shard 1 moray, make sure that we verify afterwards that minnow records
   are continuing to be updated, and that jobs continue running without issue
   across the test.

<a name="footnote3">3.</a> Restarting manatee-sitter on the PostgreSQL primary or sync will likely
   result in a longer period of errors and high latency -- up to a minute.

<a name="footnote4">4.</a> These operations on manatee-sitter on a PostgreSQL primary or sync should,
   result in a takeover by the cluster.  There may be an outage of up to about
   2 minutes until this happens, and then roles in the cluster will have
   changed, so it will be important to re-check roles before starting the next
   test.

## Testing CN failure

Procedure: test shutting down each machine specified using IPMI.  Impact should
be similar to shutting down all of the zones on the machine, and in no cases
should the data path be impacted more than what's described above.  There
should be minimal to no impact when the CNs come back online.

### List of CN-level tests for data path components

- CN hosting 1st nameservice
- CN hosting ZK leader
- CN hosting PostgreSQL primary
- CN hosting PostgreSQL sync
- CN hosting PostgreSQL async
- CN hosting storage zone

## Testing AZ failure

Procedure: test shutting down all Manta-related CNs in an availability zone.
The impact should be similar to shutting down all of the CNs in that AZ, and in
no cases should the data path be impacted more than what's described above.
There should be minimal to no impact when the AZs CNs come back online.
