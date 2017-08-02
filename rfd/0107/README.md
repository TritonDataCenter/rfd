---
authors: Mike Zeller <mike.zeller@joyent.com>
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

# RFD 107 Self assigned IP's on fabric network

## Problem Statement

Since the introduction of Fabric Networks users have far longed for a truly self service experience when it comes to networking. We often encounter users requesting the ability to self assign IPs on their networks to specific zones. Currently `NAPI` allows for this but it is not exposed to end users via `CloudAPI`. In addition to assigning IP's, users should also be able to reserve IP's.


## Common scenarios leading to the need for self assigned IP's

This section describes some known customer scenarios.

1. Fabric routes cannot be updated after creation.

	In our current situation `NAPI` via `CloudAPI` allows users to create a fabric network with a route object. This route object will apply the defined routes to new zones when they are created on the fabric. However, until [rfd 28](https://github.com/joyent/rfd/blob/master/rfd/0028/README.md) is implemented there is no way for a user to update the route object on a fabric.  Even if the route object was updated the new routes would not be synced to exisiting zones. This often leads to users wanting to manage their own route tables on zones via a tool like ansible (chef, salt, puppet etc). It often makes sense for them to want to be able to manage where IP's land, especially when recreating an instance used as a vpn or IPSec host.

2. Mirroring deployments across Datacenters.

	Customers sometimes wish to deploy identical environments to multiple datacenters for a variety of reasons such as disaster recovery or failover.  Being able to mirror the IP mappings across the datacenters lightens the Ops load when working with configuration management as well as simplifying the environments overall.

3. Routing tables cannot take advantage of CNS.

	Most of the time users don't have to worry about managing IP's when they take advantage of [CNS](https://docs.joyent.com/public-cloud/network/cns). We often recommend that users use `CNS`'s ability to group instances by service label/tag.  Then applications and end users can consume the services via DNS based lookups.  However, this approach falls short when the user needs to add a particular service to a routing table e.g. vpn's, and zones acting as routers between networks. Recreation of one of these types of zones means new IP's which also means the users need to update all routing tables everywhere in addition to updating and configuration management scripts they have in place.

## Proposed Solution

`CloudAPI` should expose endpoints to allow users to self assign and reserve IP's specifically on a fabric network.
`NAPI` currently allows the assigning of an IP on a fabric network which is documented [here](https://github.com/joyent/sdc-napi/blob/master/docs/index.md#createnic-post-nics).
