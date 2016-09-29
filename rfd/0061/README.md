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
    Copyright 2016 Joyent, Inc.
-->

# RFD 61: CNAPI High Availability

The Trition Compute Node API (or CNAPI) fulfills an important role within the
hiearchy of the Triton stack. It not only maintains an up to date picture of
compute nodes running in the datacenter, and their lifecycle-related data, such
as compute node status, hardware dimensions, boot parameters, etc, but also
serializes and controls access to compute node resources, prepares and
handles actions performed by compute nodes, such as container and compute node
operations.

Given the position it occupies on the critical path of normal operation of the
Triton stack, it is therefore not surprising that if the CNAPI service is
interrupted, because of scheduled maintenance or headnode failure, the
potential impact on the datacenter is great. Should the situation arise where a
CNAPI instance becomes unavailable, it will be desireable to have service
requests flow to sibling instances, allowing them to pick up the slack,
striving for minimal disruption to upstream dependents. Running multiple
concurrent instances of CNAPI is a step to mitigating the risk should one of
those instances experience problems as a result of software, hardware.
Distribution of the workload amongst redundant instances is a side-benefit.

The ultimate goal of this document is to:

    - Describe an architure which does not regress existing functionality but
      does reduce impact on the datacenter when one or more instances are unavailable.
    - Outline what needs to be done to allow CNAPI to co-exist with multiple instances
      of itself and be be brought up to the model described above.

Because CNAPI is composed of a number of subsystems it is worthwhile to look at
each subsystem in turn. We shall examine what they do and what changes if any are
required to in order to benefit from multiple CNAPI instances running alongside
each other. As currently designed some CNAPI subsystems are more able to deal
other instances (without unwanted or undefined behavior, such as clobbering of
data) of itself running in parallel than others.

In general, the guiding principle to any changes should be to allow any
instance of CNAPI to provide correct and up to date information and
successfully fulfill any request, regardless of which other CNAPI instance may
have initiated or performed the work.


## CNAPI subsystems

Much of CNAPI can be broken down into rough subsystems responsible for certain
functionality. These are described below.


### Restify HTTP Server

The primary method of interacting with CNAPI and its various subsystems is
CNAPI's use of restify which presents an HTTP server interface.


### Relationship With the Compute Node Agent

One of the steps of the compute node setup process is installation of agents.
Agents are of services running the global zone that are typically a means of
performing operations which require greater access to operation system
facilities, such as creation of zones, gathering metrics, etc.

One such agent is the compute node agent, or `cn-agent`. It allows CNAPI to
execute actions on and receive periodic data from the compute node. It's role
with respect to CNAPI, as well as strategies to allow multiple CNAPI to service
its requests will be examined in greater depth in the following sections.


### Ur Messages

When a compute node comes comes online, it will start the Ur agent, which is
always present, even if the compute node is unsetup and other agents are not
installed. It connects to the datacenter rabbitmq AMQP server (on which CNAPI
listens) and broadcasts a message to the routing key `ur.startup.#`. Unsetup
compute nodes will periodically emit messages to `ur.sysinfo` to alert any
listening CNAPI instances that the server exists. Both of these types of
messages contain the compute node's current `sysinfo` payload at the time the
message was sent.

When CNAPI starts up it will also broadcast a request to all
listening Ur agents for their sysinfo payloads. It will connect to the
`ur.cnapi` queue. It will then bind to this queue the routing keys,
`ur.startup.#` and `ur.sysinfo.#`. 

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
    - update `status`, in the case of unsetup servers


## Waitlist

One of the facilities CNAPI provides is the ability of creating waitlist
tickets. These objects enable clients to wait on a queue for sequential access
to a resource. Typically this is used as a means to safe-guard against two
actions which when performed simultaneously could have adverse or undefined
behaviour. Classic examples include a quick succession of a mix of create,
start, stop, reboot, and destroy requests for containers. CNAPI allows one to
create waitlist tickets around a particular (resource type, resource id, server
uuid) combination.


## Compute node heartbeats

`cn-agent` on start-up does a DNS request for the CNAPI IP address. Every 5
seconds, `cn-agent` POSTs a message to the CNAPI at that IP address to let 
it know the server is still present. CNAPI uses this information to determine
wether a compute node's status is 'running' or 'unknown'.

This is a problem because if one CNAPI instance is created and another
destroyed, the CNAPI instance at the IP-address we may have on-hand could be
unvavailable.


## Compute Node Agent Task Execution

One method CNAPI use to execute code on a compute node is via `cn-agent`.


## VM Status Updates

A compute node's `status` property indicates whether we have heard from the
compute node within a certain amount of time. When `cn-agent` starts, it looks
up CNAPI's IP address and begins to periodically post to a URL there.

This CNAPI endpoint is the first step in computing compute node `status`.
