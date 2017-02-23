---
authors: Orlando Vazquez <orlando@joyent.com>
state: predraft
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

The Triton Compute Node API (or CNAPI) fulfills an important role within the
Triton Datacenter management stack.

CNAPI is responsible for:

- Maintaining an up to date picture of compute nodes running in a datacenter
  and their lifecycle-related data such as running status, hardware dimensions,
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
- Outline what needs to be done to allow CNAPI to co-exist with multiple instances
  of itself and be be brought up to the model described above.

CNAPI is comprised of a number of sub-systems, so it is worthwhile to look at
each sub-system in turn. We shall examine how each one works and what changes,
if any, are required to in order to allow them to correctly operate multiple
CNAPI instances. As currently designed, some CNAPI subsystems are more able to
deal other CNAPI instances running alongsie without unwanted or undefined
behavior, such as unintentional overwriting of data) of itself running in
parallel than others.

In general, the guiding principle should be to allow any CNAPI instance to
provide correct and up to date information and successfully fulfill any
request, regardless of which other CNAPI instance may have initiated or
performed the work.


### A note about Agents

Loosely speaking, agents are of services running mainly in the global zone.
Some agents may also run within zones to provide facilities to the core service
running within a zone. Some examples of these are the 'config-agent' and
'amon-agent'. They typically are a means of performing operations which require
greater access to operation system facilities, such as creation of zones,
gathering metrics, etc.


## CNAPI subsystems

Much of CNAPI can be broken down into rough subsystems responsible for certain
functionality. These are described below.


### Restify HTTP Server

The primary method of interacting with CNAPI and its various subsystems is
CNAPI's use of restify which presents an HTTP server interface.


### Relationship with the Ur Agent

When a compute node comes comes online, it starts the Ur agent. The main
reason for Ur's existence is to bootstrap the compute node setup process, and
debugging/troubleshooting. Ur is always present on a compute node, even if the
compute node is unsetup and other agents are not yet installed. It connects to
the datacenter rabbitmq AMQP server (on which CNAPI listens) and broadcasts a
message to the routing key 'ur.startup.#'. Unsetup compute nodes periodically
emit messages to 'ur.sysinfo' to alert any listening CNAPI instances that the
server exists.  Both of these types of messages contain the compute node's
current 'sysinfo' payload at the time the message was sent.

When CNAPI starts up it also broadcasts a request to all listening Ur agents
for their sysinfo payloads. It connects to the 'ur.cnapi' queue. It then binds
to this queue the routing keys, 'ur.startup.#' and 'ur.sysinfo.#'. 


### Ur messages

When multiple CNAPI consumers are connected to a single queue, the expected
behaviour is round-robin distribution of messages amongst connected consumer
CNAPI instancess. That is, given the case of two compute nodes emitting
sysinfo, and two CNAPIs present, the expected idea is that each CNAPI would
receive a message from one server.

If one CNAPI instance gets a startup or sysinfo message it is its
responsibility take any necessary action on it:

These actions include:

- updating sysinfo value for that server in moray
- starting a server-sysinfo workflow for that server
- update running status, in the case of unsetup servers


### Relationship With the Compute Node Agent

One type of global-zone agent is the compute node agent, or `cn-agent`. It
allows CNAPI to execute actions on the compute node as well as receive periodic
data from it. It's role as it relates to CNAPI, as well as strategies to allow
multiple CNAPI to service its requests, will be described in greater detail in
the following sections.

### Waitlist

One of the facilities CNAPI provides is the ability of creating waitlist
tickets. These objects enable clients to wait on a queue for sequential access
to a resource. Typically this is used as a means to safe-guard against two
actions which when performed simultaneously could have adverse or undefined
behaviour. Classic examples include a quick succession of a mix of create,
start, stop, reboot, and destroy requests for containers. CNAPI allows one to
create waitlist tickets around a particular (resource type, resource id, server
uuid) combination. These are usually created by workflow jobs.

HA Status:

This aspect of CNAPI should be HA ready.


### Compute node heartbeats

`cn-agent` on start-up does a DNS request for the CNAPI IP address. Every 5
seconds, `cn-agent` POSTs a message to the CNAPI at that IP address to let 
it know the server is still present. CNAPI uses this information to determine
wether a compute node's `status` is 'running' or 'unknown'.

# Problems

[needs to be remedied]

This is a problem because if one CNAPI instance is created and another
destroyed, the CNAPI instance at the IP-address we may have on-hand could be
unvavailable.


### Heartbeats/VM Status Updates

A compute node's `status` property indicates whether we have heard from the
compute node within a certain amount of time. When `cn-agent` starts, it looks
up CNAPI's IP address and begins to periodically post to a URL there.

This CNAPI endpoint is the first step in computing compute node 'status'.


### Compute Node Agent Task Execution

One method CNAPI use to execute code on a compute node is via `cn-agent`.


# Next Steps

## Server Status

CNAPI's existing server status management mechanism relies on writing to moray
each time a heartbeat is received. For large numbers of compute nodes, each
heartbeating every 5 seconds, this becomes prohibitive.

It would be ideal to only have to write to moray any time there is a signficant
change in server's status (ie it comes up or goes down).

Any new logic should not signficantly regress existing CNAPI behaviour.


### Tentative Plan

Have `cn-agent` maintain persistent connections to CNAPI and use these to
determine server status. Only write to moray if/when something changes.


#### POV of cn-agent

On start-up:
- resolve cnapi.\<datacenter\_name>.<dns\_domain>
- open a (HTTP?) connection to CNAPI

Periodically:
- write a byte to CNAPI via this connection


#### POV of CNAPI

On start-up:
- cnapi ensures it has a moray bucket (cnapi_instance_agent)
  (string cnapi_uuid, string server_uuid)

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
- check all tracked connections have sent a byte in the last 2 seconds.

If no message in last 2 seconds:
- update server status => 'unknown'

Questions/Thoughts:
- rely on TCP sockets and lean on TCP keep-alive to maintain or use some sort of HTTP
- how does cn-agent maintain compatability with older CNAPI
- how does CNAPI maintain compatability with older cn-agent
