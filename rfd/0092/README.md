---
authors: Angela Fong <angela.fong@joyent.com>, Pedro <pedro@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->


# RFD 92 Triton Services High Availability

## Background
Within the Triton stack, currently only a small subset of the services are
architected to run in a highly available fashion. Even though these services
are stateless and can be recovered without any data loss, users are disrupted
when the only serving instance is undergoing an update or when it encounters
issues.

With the increasing number of services in Triton, users have to tolerate a
considerable maintenance window for full stack update. Some data center can
take even longer to update if there are more compute nodes for agent updates,
more accounts for ufds backup, more images or instances to migrate to newer
schema (when there are changes). The typical impact is the unavailability of
orchestration activities when the data center is put into the maintenance mode.
This was considered tolerable in the past. However, as more users architect
their applications to use auto-scaling, orchestration outage will soon become
a major pain point. Users take an even bigger hit when services supporting
run-time functionalities are unavailable. For example, portolan outage causes
fabric network MAC address resolution to fail, whereas docker outage prevents
users from attaching to docker containers or copying files in/out of them.

At this time, Triton components are at different levels of readiness for HA.

### Already support HA-deployment
- binder
- cmon
- mahi (note: [MANTA-3307](https://smartos.org/bugview/MANTA-3307) might be
  relevant for large installations)
- manatee
- moray*
- papi
- portolan
- workflow

(*) Moray clients using a version prior to v2 doesn't survive certain Moray
failures without operator intervention. For better Moray HA support, client
upgrade is essential.

### _Should_ be ready for HA-deployment

- adminui
- cloudapi

### Work required to support HA-deployment
- amon
- amonredis
- cnapi
- dhcpd
- docker
- fwapi
- imgapi
- napi
- sapi
- sdc
- vmapi

### Not considered for HA enhancements (deprecation planned)
- ca
- rabbitmq
- ufds. Note that if we need to keep ufds around for a while, we could
  just move ufds-replicator into `sdc` zone and move forward. Everything
  else is HA-ready and has been tested [CAPI-414](https://mnx.atlassian.net/browse/CAPI-414)

Transitioning the entire stack to the HA deployment model is a major
undertaking. With some careful planning and focus based on criticality would
allow Triton resiliency to improve over time.


## Proposed Implementation

### Overview

The immediate need is on building a common HA framework for stateless services,
which can be simpler than what we have currently for Manatee. The new framework
should also leverage cueball for more robust service discovery and connection
management. On a parallel track, the services that are known or supposed to be
HA-ready can start to be tested and deployed in the HA mode to address the more
pressing pain points (e.g. portolan update causing fabric network outage). Over
time, we need to work through the rest of the stack to eventually get all
Triton components to the HA architecture. By then, the issue of headnode being
the single point of failure for the control plane will also be addressed.

The broad steps to break up the work are:
- Enhance sdcadm to support a simpler way of provisioning and upgrading
  multiple instances for stateless services. Done `sdcadm create` support
  all the stateless services. For some of the services not yet HA-ready
  there are pending issues like [TOOLS-1966](https://mnx.atlassian.net/browse/TOOLS-1966)
  and [TOOLS-1963](https://mnx.atlassian.net/browse/TOOLS-1963)
- Through analysis and testing, identify HA-ready services and those that
  are considered low-hanging fruits to be HA-capable. We've already tested
  that `papi`, `portolan` and `workflow` are HA-ready and have been running
  in beta environment for at least 6 months now.
- Services that are known to require a fair amount of work to support HA
  (e.g. napi, cnapi) will have individual RFDs to scope the work properly.
- Apply cueball to Triton service management; this is not a strict dependency
  for deploying more HA services but is something required for better resiliency.
- Update Moray clients in individual services to Moray v2.

### SDCADM support for creating/updating multiple instances of a stateless service

Feature in scope
- Ability to provision additional instances for a service
- Ability to update multiple instances in a service
- Ability to de-provision instances of a service
- Healthcheck to properly report on status of multiple instances
- Service discovery to keep track of all available nodes and exclude the ones
  that are offline

Feature not in scope (existing `binder` gaps)
- Ability to load balance
- Ability to fail over inflight requests
- Drain connections before shutting down a node for update (already done by
  sdcadm, which takes each instance of HA services out of DNS before updating
  the instance).

Related tickets:
[TOOLS-1644](https://mnx.atlassian.net/browse/TOOLS-1644) done,
[TOOLS-1682](https://mnx.atlassian.net/browse/TOOLS-1682) done

### Cueball changes for better connection management

Sdcadm itself needs to be ready to work with HA setups, which means being able
to properly talk to services hosted by different VMs on several nodes using
HTTP. This is exactly the kind of functionality cueball's HTTP Agent library
has been designed for. (See [TOOLS-1642](https://mnx.atlassian.net/browse/TOOLS-1642))

Additionally, sdcadm uses DNS lookups during the updates of moray and SAPI VMs
when we're just updating a single instance of each one of them. Right now those
lookups are performed calling system's `/usr/bin/dig` command directly without
any additional development regarding proper error handling, reconnections to
binder, ...

While it's not clear if we will be able or not to get rid of these functions,
in the short term those should use Cueball's resolvers interface, and take
advantage of all the DNS related functionalities that it provides in order to
simplify sdcadm itself. (See [TOOLS-1643](https://mnx.atlassian.net/browse/TOOLS-1643))

Related tickets:
[TOOLS-1642](https://mnx.atlassian.net/browse/TOOLS-1642) done,
[TOOLS-1643](https://mnx.atlassian.net/browse/TOOLS-1643) waiting for review

### Analyze and test HA-ready candidates

A service must meet the following criteria to be considered HA-capable:

Add Instances
- CN spread: should be able to provision new instance to any running servers
  (CN or HN)
- Naming: unique instance name should be auto-generated with the $service$number
  notation, e.g. workflow1, workflow2
- Image version: should be able to provision to a newer or older version, or the
  same version as the last provisioned instance (default)
- VM config: all instance setting defined in SAPI (e.g. delegate dataset,
  network, quota, metadata) should be honored

Update Instances
- Image version: allow update to a specific image version, or to the latest if
  no version is specified
- Execution mode: update/reprovisioning should be executed sequentially against
  all instances in a single update command, i.e. instances are taken out of
  service, reprovisioned and put back one at a time
- Forced update option: An instance should be reprovisioned only if it does not
  have the image version specified, or if the force-same-version flag is passed

Remove Instances
_(Note: the only way to achieve this now is using sapi instance delete action;
there is probably not a strong need for a sdcadm command for it)_
- Basic removal support: can remove instances of a service

Service Discovery
- Stop the node with active connections: in-progress transactions will still
  fail but new requests should hit the available node(s)
- Start a stopped node: the node should be picked up by the service discovery
  process
- Restart an idle node: no impact to the service

Service Functional Behavior
- A request should be served by one and only one service instance
- A service should work correctly functionally on any of the non-headnode
  instances (i.e. the HN instance should not have any significance)
- A service that listens for updates and performs shared data write (e.g.
  changefeed) should not duplicate or drop updates when there are multiple
  service instances _(the test design will require input from the subject
  matter expert of the service)_


## HA for services that have known gaps

### DHCPD
Need to analyze what it means to have multiple dhcpd servers and how that
interacts with the broadcast. Does it just work? can the request packets
end up serviced by different instances, is that a problem?

### CNAPI
CNAPI maintains the source of truth about servers through agents. The data allow
DAPI (a service deployed within CNAPI) to identify an appropriate server for
allocating new instances. CNAPI also controls the access and orchestration
activities on compute nodes. Having multiple CNAPI instance can cause issues
such as excessive polling and inaccurate server capacity calculations. [RFD 61]
(../../0061/README.md) covers the scope of work required to support CNAPI HA.

### VMAPI
VMAPI is generally working with multiple instances deployed. The only known
contention is the changefeed service which can result in dropped updates. A
RFD or bug ticket will be required to outline the approach for remediation.

### NAPI
There are no potential race conditions in assigning IP addresses.

The main issue is the upcoming changefeed implementation which can result in
dropped updates. (TRITON-284)[https://mnx.atlassian.net/browse/TRITON-284]

There may be other issues that need to be resolved to allow NAPI tasks to be
distributed without any contention. A RFD will be required for NAPI HA work.

### FWAPI
Improve update logic to support multiple instances.

FWAPI also has the same problem than NAPI. Firewaller is subscribed to updates
from FWAPI using a long running "node-fast" request. So it needs something like
a changefeed too.

### HA-changefeed
Work has been started to add changefeed support for multiple publishers, i.e.
HA support for services publishing changefeed updates from different instances
(TRITON-276)[https://mnx.atlassian.net/browse/TRITON-276]


### AMON/AMONREDIS
Amon should drop in-memory caching. Amonredis should be removed once amon moves
to using moray for storing alarms.

There might be a conflict between (a) scaling and (b) HA here.  If Amon alarm
data moves to moray... then the load on Moray might very likely go up
as well... alarm data is using redis data structures that Moray doesn't support,
so that might be a real effort. Need to evaluate if it's worth it from a Triton
POV.

### IMGAPI
Work to be done:

- imgapi stops any in-memory caching
- we discuss and decide on how imgapi handles locally-stored image files being
  shared across to other imgapi instances (probably low-tech). This could be
  really complex ... or it could just be: there is a 1min/5min background job
  that rsync's local file image data between imgapi's + imgapi0 knowing how to
  redirect to imgapi1 to get a locally stored image.
- we get nightly-1 doing multiple imgapis as a matter of course to see if other
  bugs result

- The biggest issue will likely be docker images because they are still local.
  Really would be better if they were in Manta, but there is a long standing
  bug for that.

### DOCKER

Are we gonna put more work into Docker instance? Meaning any work not being
strictly maintenance.

### CNS
In theory there is no problem with two CNS instances running at once.
It's just that if you configure a BIND slave to follow both of them at once
it can get confused and inconsistent. 
We don't serve records directly from the CNS zone anyway so bringing it down
has only the impact that changes to DNS may be delayed. 
Records continue to be served as normal. The data in the dataset is always
safe to throw away, it'll just rebuild it again and the BINDs will have to do
full AXFRs to catch up.

### SAPI
At a minimum we need the work required to properly handle DB updates HA
friendly. Also, we need work on SAPI-294 finished in order to break circular
dependency "SAPI first boot (in non-proto mode) depends on SAPI".
