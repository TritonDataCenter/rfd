---
authors: Orlando Vazquez <orlando@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 61 CNAPI High Availability

## Introduction

The Triton Compute Node API (or CNAPI) is an important piece of the Triton
Datacenter management stack. CNAPI is responsible for:

- Maintaining an up to date picture of compute nodes running in a datacenter
- Detailing compute node properties such as running status, hardware dimensions,
  boot parameters, etc.
- Serializing and controling access to compute node resources.
- Preparing and handling actions to be performed on compute nodes or their
  containers.

If the CNAPI service is interrupted, because of scheduled maintenance or
headnode failure, there is a signficant negative impact on the datacenter.
Should the situation arise where a CNAPI instance becomes unavailable, it is
desireable to have service requests flow to sibling instances to pick up the
slack. The main objective is to minimize disruption to services which depend on
CNAPI.

For the purposes of this document we will define "CNAPI high availability" as
meaning at any given time, there is always at least one CNAPI instance up and
able to fulfill requests. While distribution of the workload amongst redundant
instances for performance reasons is a potential side-benefit, running multiple
instances of CNAPI is a primarily a step to mitigating the risk should one of
those instances experience problems as a result of software, hardware or
network faults.


## This RFD

The ultimate goal of this document is to:

- Describe an architure which does not regress existing functionality but
  does reduce impact on the datacenter when one or more instances are unavailable.
- Outline changes required to allow CNAPI to co-exist with multiple instances
  of itself.


## About CNAPI

CNAPI is comprised of a number of sub-systems, so it is worthwhile to look at
each in turn. We shall examine how each one works and what changes, if any, are
required to in order to allow them to correctly operate multiple CNAPI
instances. As currently designed, some CNAPI subsystems are more able to deal
other CNAPI instances running alongside without unwanted or undefined behavior,
such as unintentional overwriting of data) of itself running in parallel than
others.

In general, the guiding principle should be to allow any CNAPI instance to
provide correct and up to date information and successfully fulfill any
request, regardless of which other CNAPI instance may have initiated or
performed the work.

Much of CNAPI can be broken down into rough subsystems responsible for certain
functionality. These are described below.


## Restify HTTP Server

The primary method of interacting with CNAPI and its various subsystems is
CNAPI's use of restify which presents an HTTP server interface.


## Ur

When a compute node (or headnode) boots up it starts the Ur agent service. Ur
exists primarily to bootstrap the compute node setup process and facilitate
debugging and troubleshooting. Ur is a part of the "platform" and so is always
present on a compute node, even if the compute node is unsetup. On start-up it
connects to the datacenter rabbitmq AMQP server (on which CNAPI listens) and
broadcasts a message to the routing key 'ur.startup.#'. Unsetup compute nodes
periodically emit messages to 'ur.sysinfo' to notify any listening CNAPI
instances that the compute node exists.  Both of these types of messages
contain the compute node's current 'sysinfo' payload at the time the message
was sent.

When CNAPI starts it also broadcasts to all listening Ur agents a request for
their sysinfo payloads. It connects to the 'ur.cnapi' queue. It then binds to
this queue the routing keys, 'ur.startup.#' and 'ur.sysinfo.#'.

When multiple CNAPI consumers are connected to a single queue, the expected
behaviour is round-robin distribution of messages amongst connected consumer
CNAPI instancess. That is, given the case of two compute nodes emitting
sysinfo, and two CNAPIs present, the expected idea is that each CNAPI would
receive a message from one compute node.

If one CNAPI instance receives a startup or sysinfo message it is its
responsibility take any necessary action on it.

These actions include:

- updating sysinfo value in moray for that compute node
- starting a server-sysinfo workflow for that server
- update running status, in the case of unsetup servers


### HA Status

This aspect of CNAPI should be HA-ready.


## Waitlist

One of the facilities CNAPI provides is the ability of creating waitlist
tickets. These objects enable clients to wait on a queue for sequential access
to a resource. Typically this is used as a means to safe-guard against two
actions which when performed simultaneously could have adverse or undefined
behaviour. Classic examples include a quick succession of a mix of create,
start, stop, reboot, and destroy requests for containers. CNAPI allows one to
create waitlist tickets around a particular (resource type, resource id, server
uuid) combination. These are usually created by workflow jobs.

## HA Status

This aspect of CNAPI should be HA-ready.


## cn-agent

One type of global-zone agent is the compute node agent, or `cn-agent`. It
allows CNAPI to execute actions on the compute node as well as receive periodic
data from it. It's role as it relates to CNAPI, as well as strategies to allow
multiple CNAPI to service its requests, will be described in greater detail in
the following sections.

`cn-agent` on start-up does a DNS request for the CNAPI IP address. Every 5
seconds, `cn-agent` POSTs a message to the CNAPI at that IP address to let
it know the server is still present. CNAPI uses this information to determine
wether a compute node's `status` is 'running' or 'unknown'.

## cn-agent tasks

One method CNAPI use to execute code on a compute node is via `cn-agent` tasks.
`cn-agent` task requests are simply HTTP POSTs sent to the `cn-agent` HTTP
server. These requests contain the name of a task to be run (i.e.
machine\_destroy) along with a JSON payload.

When CNAPI makes one of these requests, the POST will block until successful
execution of the task. Upstream clients can then call a "TaskWait" endpoint
which will return when this task has completed, either successfully or with an
error. Internally what CNAPI is doing here is polling the moray bucket where
the task results are stored and checking for evidence of a sucessful
completion.

##### HA Status

Incomplete.

##### Problem #1

Presently, CNAPI is unlikely to change IP addresses, even due to upgrades, etc.
In a deployment where there may be two CNAPI instances, and if one CNAPI
instance is created and another destroyed, the CNAPI instance at the IP-address
we may have on-hand could be unvavailable.

##### Proposed solution

 If `cn-agent` is ever unable to
contact CNAPI it should force a new look-up of CNAPI's IP address and
re-attempt the operation.


## cn-agent Heartbeats/VM Status Updates

A compute node's `status` property indicates whether we have heard from the
compute node within a certain amount of time. When `cn-agent` starts, it looks
up CNAPI's IP address and begins to periodically post to a URL there.

This CNAPI endpoint is the first step in computing compute node 'status'.

##### HA Status

Incomplete.


##### Proposed Solution

See section below, titld 'Server Status'.



## Server Status

CNAPI's existing server status management mechanism relies on writing to moray
each time a heartbeat is received. For large numbers of compute nodes, each
heartbeating every 5 seconds, the impact this has on the moray service becomes
prohibitive.

It would be ideal to only have to write to moray any time there is a signficant
change in server's status (ie it comes up or goes down).

In addition to the performance cost of this architecture, because of the
periodic nature of updates, an update of the "status" property of a server
could happen as much as 5 seconds after the fact, which is less than ideal.
Ideally the moment a server went offline, its status would reflect that fact.

Any new logic should not signficantly regress existing CNAPI behaviour.


### Tentative Plan

Have `cn-agent` maintain persistent connections to CNAPI and have CNAPI use
these to determine server status. Using these persistent connections each CNAPI
instance will maintain a roster of servers connected to it via their
cn-agent. CNAPI will only write to moray if/when there is a status change (the
mechanics of which will be described below). Each CNAPI will be considered a
roster authority for a number of servers, maintain a list of cn-agent server
uuids connected it.


#### POV of cn-agent

At startup, or any time a connection CNAPI is lost and must be reconnected,
cn-agent should resolve `cnapi.<datacenter_name>.<dns_domain>` where the values
within angled brackets correspond to the datacenter configuration values.
Following this, a websocket connection is negotiated between CNAPI and cn-agent
and held open for as long as cn-agent is up and running.

While this connection is open, it is cn-agent's responsibility to emit periodic
heartbeat messages through this channel (with an period of 1 second). This will
allow CNAPI to detect if the connection to cn-agent is silently severed.

Questions: How frequently should cn-agent send these messages? 1 second?



#### POV of CNAPI

On start-up:

CNAPI should ensure it has a moray bucket (cnapi_roster_authority) with the
following schema/indexes:

    String cnapi_uuid
    string server_uuid (unique)


On receiving a new connection:

- write a record with CNAPI uuid and the uuid of cn-agent server
- CNAPI's restify endpoint accepts a connection from a cn-agent residing on
  compute node with identified by `server_uuid`

On connection opened:
- update server status => 'running'

On connection loss:
- check if `cnapi_instance_agent` bucket still lists us as the CNAPI acting
  on behalf of this compute node. If so:
   - update server status => 'unknown'
  else:
   - do nothing

Periodically:
- check all tracked connections have sent a byte in the last 2 seconds. This is
  to guard against a server silently disconnecting without us noticing.

If no message in last 2 seconds:
- update server status => 'unknown'

#### Backwards Compatability

For a period of time it may be the case that we have a CNAPI running the code
described in this RFD, but receiving heartbeats from older versions of cn-agent
(using the previous heartbeat scheme where it periodically POSTs requests to a
CNAPI endpoint). Likewise it may also be the case that we have newer cn-agents
running which are trying to talk to older versions of CNAPI not yet running the
scheme described here. In both these cases it is important that the system
continue to work, regardless of whether the software is at the most recent
version (or not.)

