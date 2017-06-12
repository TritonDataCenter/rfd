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

(*) Moray clients using a version prior to v2 doesn't survive certain Moray
failures without operator intervention. For better Moray HA support, client
upgrade is essential.

### _Should_ be ready for HA-deployment
- adminui
- cloudapi
- papi
- portolan
- workflow

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
- ufds

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
  multiple instances for stateless services.
- Through analysis and testing, identify HA-ready services and those that
  are considered low-hanging fruits to be HA-capable.
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
- Drain connections before shutting down a node for update

Related tickets:
[TOOLS-1644](https://devhub.joyent.com/jira/browse/TOOLS-1644),
[TOOLS-1682](https://devhub.joyent.com/jira/browse/TOOLS-1682)

### Cueball changes for better connection management

Sdcadm itself needs to be ready to work with HA setups, which means being able
to properly talk to services hosted by different VMs on several nodes using
HTTP. This is exactly the kind of functionality cueball's HTTP Agent library
has been designed for. (See [TOOLS-1642](https://devhub.joyent.com/jira/browse/TOOLS-1642))

Additionally, sdcadm uses DNS lookups during the updates of moray and SAPI VMs
when we're just updating a single instance of each one of them. Right now those
lookups are performed calling system's `/usr/bin/dig` command directly without
any additional development regarding proper error handling, reconnections to
binder, ...

While it's not clear if we will be able or not to get rid of these functions,
in the short term those should use Cueball's resolvers interface, and take
advantage of all the DNS related functionalities that it provides in order to
simplify sdcadm itself. (See [TOOLS-1643](https://devhub.joyent.com/jira/browse/TOOLS-1643))

Related tickets:
[TOOLS-1642](https://devhub.joyent.com/jira/browse/TOOLS-1642),
[TOOLS-1643](https://devhub.joyent.com/jira/browse/TOOLS-1643)

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
The main issue with multiple NAPI instances is the potential race conditions
in assigning IP addresses. There may be other issues that need to be resolved
to allow NAPI tasks to be distributed without any contention. A RFD will be
required for NAPI HA work.

### FWAPI
...
