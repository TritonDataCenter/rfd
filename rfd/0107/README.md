---
authors: Mike Zeller <mike.zeller@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/49
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

Since the introduction of Fabric Networks users have far longed for a truly
self service experience when it comes to networking. We often encounter users
requesting the ability to self assign IPs on their networks to specific zones.
Currently `NAPI` allows for this but it is not exposed to end users via
`CloudAPI`. In addition to assigning IP's, users should also be able to reserve
IP's.


## Common scenarios leading to the need for self assigned IP's

This section describes some known customer scenarios.

1. Fabric routes cannot be updated after creation.

	In our current situation `NAPI` via `CloudAPI` allows users to create a
fabric network with a route object. This route object will apply the defined
routes to new zones when they are created on the fabric. However, until [rfd
28](https://github.com/joyent/rfd/blob/master/rfd/0028/README.md) is
implemented there is no way for a user to update the route object on a fabric.
Even if the route object was updated the new routes would not be synced to
exisiting zones. This often leads to users wanting to manage their own route
tables on zones via a tool like ansible (chef, salt, puppet etc). It often
makes sense for them to want to be able to manage where IP's land, especially
when recreating an instance used as a vpn or IPSec host.

2. Mirroring deployments across Datacenters.

	Customers sometimes wish to deploy identical environments to multiple
datacenters for a variety of reasons such as disaster recovery or failover.
Being able to mirror the IP mappings across the datacenters lightens the Ops
load when working with configuration management as well as simplifying the
environments overall.

3. Routing tables cannot take advantage of CNS.

	Most of the time users don't have to worry about managing IP's when
they take advantage of [CNS](https://docs.joyent.com/public-cloud/network/cns).
We often recommend that users use `CNS`'s ability to group instances by service
label/tag.  Then applications and end users can consume the services via DNS
based lookups.  However, this approach falls short when the user needs to add a
particular service to a routing table e.g. vpn's, and zones acting as routers
between networks. Recreation of one of these types of zones means new IP's
which also means the users need to update all routing tables everywhere in
addition to updating and configuration management scripts they have in place.

## Proposed Solution

The solution needs to handle both the `CloudAPI`/Portal as well as the Docker
interface into Triton.  `NAPI` currently allows the assigning of an IP on a
fabric network which is documented
[here](https://github.com/joyent/sdc-napi/blob/master/docs/index.md#createnic-post-nics).
In the future, when a Triton user wants to specify a specific IP address they
will need to pass in the desired network UUID and ip as an object. However, in
our current API deployment you can only pass in the desired network UUID. To
address this issue we will need to modify `VMAPI`.

The `VMAPI` endpoint should accept a new Network Object type that is outlined
[here](https://github.com/joyent/sdc-vmapi/blob/master/docs/index.md#specifying-networks-for-a-vm).

###### Network Object

IPv4

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ipv4_uuid		| UUID		| UUID of network.			|
| ipv4_count		| Number	| Number of IPs on network. (Default 1; omit if using ipv4_ips) |
| ipv4_ips		| Array		| Array of IP's.			|

IPv6

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ipv6_uuid		| UUID		| UUID					|
| ipv6_count		| Number	| Number of IPs on network. (Default 1; omit if using ipv6-ips) |
| ipv6_ips		| Array		| Array of IP's.			|

Each network object will represent one *interface*.  In the future an
*interface* will be able to support multiple IP's (i.e. "ipv4_count": 2) but
that is beyond the scope of this proposal.  Possible additional fields such as
`PrimaryIP` are omitted in this document.

```
[
  { "ipv4_uuid": "58f75b3e-15aa-4bab-ad22-c6546cfd6b59" },
  { "ipv4_uuid": "458827a7-dd75-4157-8184-0e38bd97177f", "ipv4_count": 1 },
  { "ipv4_uuid": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2", "ipv4_count": ["192.168.1.234"] },
  { "ipv4_uuid": "01b2c898-945f-11e1-a523-af1afbe22822", "ipv4_ips": [ "10.0.1.78", "10.0.1.88" ] }, //Not yet supported
  { "ipv6_uuid": "d1516824-ece0-46d0-bbe1-87a120268d16", "ipv6_count": 1 },
  { "ipv6_uuid": "931d828f-d0a5-406a-a9aa-cc972ad8bcaf", "ipv6_ips": [ "2001:db8:a0b:12f0::1" ] },
]
```

### CloudAPI changes

`CloudAPI` should expose endpoints to allow users to self assign and reserve
IP's specifically on a fabric network.  The endpoints should look something
like this.

#### Nics

##### AddNic (POST /:login/machines/:id/nics)

###### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| network		| UUID		| Network UUID				|
| ip			| IP		| Specific IP to assign to the NIC. Optional |

```
{ "network": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2" }

or

{
  "network": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2",
  "ip": "192.168.1.234"
}
```

It may be reasonable to accept an array of network objects so that an end user
can add multiple nics in one go, incurring only a single reboot.

#### Fabrics

##### UpdateFabricNetworkIPs (PUT /:login/fabrics/default/vlans/:vlan_id/networks/:id/ips)

###### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ip			| IP		| The IP Address			|
| reserved		| Boolean	| Reserve/Unreserve the IP		|

```
{ "ip": "192.168.1.234", "reserved": true }
```

#### Instances

##### CreateMachine (POST /:login/machines)

###### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ...			|		|					|
| networks		| Array		| Array of network objects		|
| ...			|		|					|

```
[
  { "network": "58f75b3e-15aa-4bab-ad22-c6546cfd6b59" },
  { "network": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2", "ip": "192.168.1.234" }
]
```

### Docker Changes

The `sdc-docker` endpoint should parse the users docker client payload into the
new `VMAPI` format.
