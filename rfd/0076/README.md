---
authors: Richard Bradley <richard.bradley@joyent.com>
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

# RFD 76 Improving Manta Networking Setup

Manta deployment today is done under a number of separate steps for each AZ. To
summarise the [deployment guide]
(http://joyent.github.io/manta/#deploying-manta), they are:

1. Install Triton
2. Create a network configuration file and run manta-net.sh
3. Run manta-init
4. Deploy Manta services

This RFD intends to describe and discuss what would be necessary to make
step 2 of the above process more streamlined (along with adding new servers
to an existing Manta deployment). There is still room for streamlining Manta
deployment as a whole but this document does not intend to cover that process.

The end result of the proposed solutions in this RFD will be a Manta
installation that functions exactly as it does today in regards to network
functionality, but with a smoother journey to get there.

## Background

Manta is made up of many services (e.g. moray, loadbalancer, muskie), and all of
these services consist of multiple zones provisioned via Triton's APIs. These
zones communicate with each other over the Manta network (outlined
[here](http://joyent.github.io/manta/#basic-terminology)), making use of a
zone's VNIC for network communication, as well as in some cases via a VNIC in
the global zone of a compute node (such as for marlin zones, which lack a VNIC
on the manta network and are manipulated via an agent in the global zone, which
subsequently needs to communicate with other zones on the Manta network).

Terminology in this document intends to be easy to follow for someone familiar
with Triton, but Manta adds a few definitions and slight changes to this list.
See Manta's [Basic terminology]
(http://joyent.github.io/manta/#basic-terminology) guide for more details.

### What is a network configuration file and "manta-net.sh"?

The network configuration file is documented
[here](http://joyent.github.io/manta/#networking-configuration), and it
contains a description of all AZs in the Manta deployment from the perspective
of networking, plus networking information regarding the local AZ's servers.
There must be one of these configuration files per AZ. "manta-net.sh" is a
script that consumes this network configuration file and performs the following
tasks against the local AZ.

1. Update/create all required nic tags and networks in NAPI
2. Tag all requested NICs with relevant nic tags
3. Create VNICs in NAPI intended for use in the global zones of all Manta nodes,
which will also reserve IP addresses on the manta network
4. Distribute SMF services to requested servers
    - manta-net: Creates a VNIC in the global zone of the server to the Manta
    network
    - xdc-routes: Creates routes in the global zone of the server to the other
    Manta AZs (only required if multi-AZ)

After running "manta-net.sh", all servers intended to be part of the Manta
deployment should have a VNIC to the manta network in their global zone.

## Problem

Populating the network configuration file is a very manual process. It requires
hand-editing of JSON, and even though we validate this JSON structure before
execution, it can get very unwieldy when there are more than a handful of
servers in each AZ.

We always distribute the SMF services to each server, but if fabrics are enabled
in the datacenter these services will actually disable themselves as they are
not required (boot-time networking will take care of creating the VNIC and
adding routes for us). The only use these scripts have in a fabrics-enabled AZ
is that they will create the Manta VNIC without requiring a reboot of the server
when initially deploying Manta. We currently have no tooling to remove these
services if they are no longer required.

`manta-net.sh` will process the list of servers multiple times in series. There
is no parallel execution of the various steps, and with its use of
`sdc-oneachnode` to distribute the SMF services it means that running this tool
is very time consuming when there are many servers. This is the case even if the
tool does nothing (e.g. if all NICs already have proper tags), and if for some
reason a fatal error is experienced late in its execution (e.g. a NIC is
misspelled and not found in NAPI), the tool will exit with an error and have to
be executed again. Our error message, however, will only contain the last
failure, and a re-run of the tool is required to determine if there are further
issues.

As an example, a Manta deployment of ~130 nodes has a network configuration file
of >1000 lines and may take upwards of 1 hour to run. One of these configuration
files is required for each AZ. It's possible to reduce this size and runtime by
only including nodes that are required on this run of the tool, but this is very
difficult and error prone without additional tooling (which we don't provide).
This also means that you'll have multiple separate configuration files
describing a single AZ which make it difficult to correlate what an operator
requires.

## Proposed solution

The primary goal of this proposed solution is to allow operators to describe the
AZ using existing Triton tooling, as opposed to keeping up-to-date a hand-edited
JSON file. The following sections describe how this might be possible.

**We should no longer perform any NIC tagging; this should be a task for the
operator**

Deploying fabrics in Triton works this way, and this is the best way to put the
most control into the operator's hands, such as changing the tagged NIC on a
server after deployment. It also removes some of the "magic" from Manta
deployment, allowing operators to use tools and systems that transfer knowledge
to/from Triton management.

Today, there is a mix of NIC tagging responsibilities, where some NICs are
tagged by "manta-net.sh" (manta and mantanat), and some are tagged by the
operator (external).

**We should store our required networking configuration that describes all
other AZs in SAPI**

No need for copying this data across AZs. Upload it once to master SAPI, all AZs
can make use of it (thanks to SAPI's "master" mode). Fabrics also make use of
SAPI to store the datacenter's fabric configuration [See here for more
information {want doc link, not code}]
(https://github.com/TritonDataCenter/sdcadm/blob/master/lib/post-setup/fabrics.js#L667).

NB: The network definitions for other AZs are only required for making sure the
routes to these other AZs exist in the local NAPI's network definitions. This
might also be something we push to the operator for the same reasons as not
doing NIC tags, which means SAPI is not required.

**Servers should be traited for their Manta role ("metadata" or "storage")
[[MANTA-2047](https://devhub.joyent.com/jira/browse/MANTA-2047)]**

This will act as a filter to determine what servers require the manta VNIC, but
also as verification that all servers have the correct nic tags (e.g. metadata
need "external" if they are to host loadbalancers, storage need "mantanat" for
marlin zones). The operator is responsible for adding traits to the servers that
are intended for Manta usage.

**Make use of Triton's capabilities of creating global zone VNICs and routes**

This means the SMF services are no longer required and can be removed from
existing deployments, or not deployed at all in new deployments.

The existence of these SMF services is because Triton did not have this
capability prior to fabrics.

**SMF service removal should not be rolled into `manta-adm` and should remain
as a self-contained script for this purpose
[[MANTA-3014](https://devhub.joyent.com/jira/browse/MANTA-3014)]**

These services are deployed via `sdc-oneachnode`, and removing them will need to
use this tool, too. Keeping this as a separate command will mean that we can
remove the symlink part of [step 4 in the deployment guide]
(http://joyent.github.io/manta/#deploying-manta), and only require it in some
form for cleanup of these services.

This process doesn't need knowledge of the whole networking configuration file,
such as other AZ's networks and local NIC tag definitions. All that's required
here is a list of servers to work through.

**This process should still be idempotent**

It should be possible to re-run this process at any point and not cause
disruption or make additional changes if none are required. For example, adding
a new shrimp to a deployment should just be a case of adding some tags/traits
to an already setup server and re-running this Manta networking process
(followed by provisioning the Manta services for this node).

**We should prompt the user to continue after printing a summary**

After a summary is printed, we should prompt that the changes look correct so
the operator can confirm.

**We should parallelise as much of this process as possible**

This is primarily for reasons of speed, where this process should not be
unwieldy when adding any number of new servers to the deployment. It will also
provide a mechanism of summarising all failures of a certain type so they can be
rectified in one batch.

**`manta-adm` should handle this process**

`manta-adm` should have a new sub-command that will handle Manta network
validation and setup, as opposed to this being handled by a script in the global
zone of the head node ("manta-net.sh"). The layout of this sub-command will be
as follows.

- `manta-adm networking`
    - Provides a help summary of all available sub-commands related to
    Manta networking
- `manta-adm networking show`
    - Lists all Manta nodes in the AZ, making use of the servers' traits to
    determine if they are intended for Manta usage
    - This list will be useful for cross-checking against a server's intended
    usage and its current nic tags. For example:
        - A node is traited as "storage" that doesn't yet have a VNIC on the
        Manta network
        - A node is traited as "metadata", which could possibly house a
        loadbalancer zone, but doesn't have an "external" nic tag
- `manta-adm networking gz-nics`
    - Direct replacement for the global zone VNIC creation parts of
    "manta-net.sh", minus shipping the SMF services
    - Gathers list of all Manta nodes in the AZ (using the same mechanism as
    `manta-adm networking show`), cross checking these nodes against a list of
    VNICs on the Manta network that are owned by servers, then provides a
    summary to the operator of what actions it intends to perform
    - After a positive response from a prompt to the operator, the VNICs are
    created, unless:
        - There are no Manta nodes without VNICs to the Manta network. In this
        case there is nothing to do and the operator is informed as such
        - A server has had its Manta trait removed but has a VNIC on the Manta
        network. In this case the sub-command will remove the VNIC

## Additional questions

**Should we also handle the master SAPI changes
([MANTA-3053](https://devhub.joyent.com/jira/browse/MANTA-3053))?**

**Does this process cross paths with any other part of Manta deployment?** For
example, this process could be used as a form of verification that we have the
right amount of Manta nodes in the datacenter based on their traits, but
`manta-adm genconfig` will also perform some level of validation and provide
warnings/errors if need be.

One piece of crossover is with `manta-init`, where that command will add the
poseidon user to the manta, mantanat and admin networks' owner_uuids (see [here]
(https://github.com/TritonDataCenter/sdc-manta/blob/master/cmd/manta-init.js#L493-L505)).
Should/can this be removed from `manta-init` and rolled into the proposed
`manta-adm` networking process? Is this out of scope?

Another piece is regarding the service deployment step, where more JSON is
required to build the view of Manta services in the AZ. Using traits on each
server might be an answer to removing that dependency, too, but that is out of
scope of this RFD. However, this highlights that there needs to be consideration
here in order to allow flexibility to other parts of Manta that may end up using
a server's traits.

**Should this tool handle the full lifecycle of a VNIC?** For example, a
storage node is for some reason no longer going to be part of Manta, but is to
be used in the general pool of available servers in Triton. Should this tool
provide a mechanism for deleting this node's VNIC from NAPI? It may be able to
offer some form of validation and sanity checking here, such as whether all
Manta services have been properly removed from this node.

## Blockers

- Triton has no method of tagging aggregations without rebooting the server
([CNAPI-673](https://devhub.joyent.com/jira/browse/CNAPI-673))
    - Individual MAC addresses can make use of CNAPI's update-nics endpoint
    which triggers a workflow to tag the relevant NICs on the server. This does
    not apply to aggregations
- Triton has no method of creating a VNIC in the global zone without rebooting
the server
    - A reboot is required in order for a VNIC to be created in a global zone.
    This also applies to fabrics
- VNICs will be deleted from NAPI if they don't exist on the server when
sysinfo-refresh is run ([NET-367]
(https://devhub.joyent.com/jira/browse/NET-367))
    - Fabrics make use of GZ VNICs, too, but they get special treatment during
    this process and are not deleted
- Boot-time networking is currently gated on fabrics ([NET-366]
(https://devhub.joyent.com/jira/browse/NET-366))
    - Fabrics must be enabled in the datacenter for boot-time networking to be
    enabled, which is the method that is used to create a VNIC in the global
    zone of a compute node without the SMF services (among other things). Manta
    will not make use of many of the features of fabrics, but boot-time
    networking is the essential piece
