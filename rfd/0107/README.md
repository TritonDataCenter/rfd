---
authors: Mike Zeller <mike.zeller@joyent.com>
state: publish
discussion: https://github.com/TritonDataCenter/rfd/issues/49
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->

# RFD 107 Self assigned IP's and reservations

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
	fabric network with a route object. This route object will apply the
	defined routes to new zones when they are created on the fabric.
	However, until [rfd
	28](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0028/README.md) is
	implemented there is no way for a user to update the route object on a
	fabric.  Even if the route object was updated the new routes would not
	be synced to exisiting zones. This often leads to users wanting to
	manage their own route tables on zones via a tool like ansible (chef,
	salt, puppet etc).  It often makes sense for them to want to be able to
	manage where IP's land, especially when recreating an instance used as
	a vpn or IPSec host.

2. Mirroring deployments across Datacenters.

	Customers sometimes wish to deploy identical environments to multiple
	datacenters for a variety of reasons such as disaster recovery or
	failover.  Being able to mirror the IP mappings across the datacenters
	lightens the Ops load when working with configuration management as
	well as simplifying the environments overall.

3. Routing tables cannot take advantage of CNS.

	Most of the time users don't have to worry about managing IP's when
	they take advantage of
	[CNS](https://docs.joyent.com/public-cloud/network/cns).  We often
	recommend that users use `CNS`'s ability to group instances by service
	label/tag.  Then applications and end users can consume the services
	via DNS based lookups.  However, this approach falls short when the
	user needs to add a particular service to a routing table e.g. vpn's,
	and zones acting as routers between networks. Recreation of one of
	these types of zones means new IP's which also means the users need to
	update all routing tables everywhere in addition to updating and
	configuration management scripts they have in place.

## Proposed Solution

The solution needs to handle both the `CloudAPI`/Portal as well as the Docker
interface into Triton.  `NAPI` currently allows the assigning of an IP on a
network which is documented
[here](https://github.com/TritonDataCenter/sdc-napi/blob/master/docs/index.md#createnic-post-nics).
In the future, when a Triton user wants to specify a specific IP address they
will need to pass in the desired network UUID and ip as an object. However, in
our current API deployment you can only pass in the desired network UUID. To
address this issue we will need to modify `VMAPI`.

### VMAPI changes

tl;dr No changes will be made to `VMAPI` for this RFD. Some notes below about
future directions.

The `VMAPI` endpoint already accepts a new Network Object type that is outlined
[here](https://github.com/TritonDataCenter/sdc-vmapi/blob/master/docs/index.md#specifying-networks-for-a-vm),
in addition to being backwards compatible with a list of network UUID's.

###### Network Object

IPv4

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ipv4_uuid		| UUID		| UUID of network.			|
| ipv4_count		| Number	| Number of IPs on network. (Default 1; omit if using ipv4_ips) |
| ipv4_ips		| Array		| Array of IP's.			|

Each network object represents one *interface*.  Currently this interface
supports only IPv4, as well as a count of 1 or a single IP address.  In the
future an *interface* will be able to support multiple IP's (i.e. "ipv4_count":
2) in addition to multiple networks, but that is beyond the scope of this
proposal.

```
[
  { "ipv4_uuid": "58f75b3e-15aa-4bab-ad22-c6546cfd6b59" },
  { "ipv4_uuid": "458827a7-dd75-4157-8184-0e38bd97177f", "ipv4_count": 1 },
  { "ipv4_uuid": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2", "ipv4_ips": ["192.168.1.234"] }
]

//Not yet supported
[
  { "ipv4_uuid": "01b2c898-945f-11e1-a523-af1afbe22822", "ipv4_ips": [ "10.0.1.78", "10.0.1.88" ] },
  { "ipv6_uuid": "d1516824-ece0-46d0-bbe1-87a120268d16", "ipv6_count": 2 },
]
```

The ongoing IPv6 work as well as [RFD 32 Multiple IP Addresses in
NAPI](https://github.com/TritonDataCenter/rfd/tree/master/rfd/0032) may introduce
additional changes to `VMAPI` at some point in the future.

### primaryIp changes

The `primaryIp` is a fiction from `CloudAPI`'s point of view. It is commonly
used by customers to determine what IP they should SSH in on.  Historically it
has defaulted to a public IP. We should tell users to rely on `CNS` for this
purpose, however there may be some users who do not enable `CNS` for their
accounts.  When a user sets the primaryIp we really want the NIC to be primary,
not the IP specified. When a NIC is primary it effects things like default
route for the instance. For more information check out PUBAPI-1216. This
becomes important when we start allowing users to have multiple IPs attached to
the same NIC.

### CloudAPI changes

`CloudAPI` should expose endpoints to allow users to self assign and reserve
IP's specifically on a non-public network.  The endpoints should look something
like this.

#### Nics

##### AddNic (POST /:login/machines/:id/nics)

Until we have support for multiple IPs per NIC, `CloudAPI` will restrict
requests to only allow a count of 1 and an ips array with a single element.
It is also still possible to pass in just a network UUID.

###### input

A single network object.

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ipv4_uuid		| UUID		| Network UUID				|
| ipv4_ips		| Array		| Specific IPs to assign to the NIC. Optional |
| ipv4_count		| Integer	| Number of IP's wanted. Optional (not needed if ipv4_ips is provided)	|


```
{ "ipv4_uuid": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2" }

or

{
  "ipv4_uuid": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2",
  "ipv4_ips": ["192.168.1.234"]
}
```

###### output

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ip			| String	| NIC's IP Address			|
| mac			| String	| NIC's Mac Address			|
| primary		| Boolean	| Whether this is the instance's primary NIC |
| netmask		| String	| IP netmask				|
| gateway		| String	| IPv4 gateway				|
| state			| String	| Describes the state of the NIC (most likely 'provisioning') |
| network		| String	| Network UUID				|

###### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| If :login or :id does not exist			|
| InvalidArgument	| If :id isn't a UUID, the network argument isn't a valid UUID, or the IP isn't valid |
| MissingParameter	| If the network argument isn't present			|

This future-proofs us for the additional ongoing work mentioned above, allowing
to data to eaisly map to any `VMAPI` changes.

#### Networks

There are some fields returned in `ListNetworkIPs` and `GetNetworkIP` that are
only displayed under certain conditions.

- ip: always displayed
- reserved: always displayed
- managed: always displayed
- owner_uuid: displayed only if the ip address has a belongs_to_uuid field, and
  uuid is not the admin uuid.
- belongs_to_uuid: displayed only if the ip is allocated to
  "something"<sup>1</sup> AND the owner_uuid matches the user making the
  request.

  [1] Currently in Triton "something" can refer to "zone", "server", or
  "other".  `NAPI` lists this type in `belongs_to_type`.  We would like to
  expose this type information in the future, and possibly extend the values in
  the field to be more meaningful such as "nat", "nfs", or "router"

##### ListNetworkIPs (GET /:login/networks/:id/ips)

Only provisioned and reserved IP's will be returned.  In addition users will be
able to list IPs on any network they are an owner of as well as public
networks.  On public networks, only the users provisioned IPs will be returned.
In order to support listing a public networks IPs we will have to add the
`owner_uuid` filter to the `NAPI` request. This means `CloudAPI` will have a
requirement on minimum `NAPI` version.

###### output

Returns and array of provisioned or reserved IP objects.

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ip			| String	| IP Address				|
| reserved		| Boolean	| Whether this IP is reserved or not	|
| managed		| Boolean	| True if the user cannot modify the IP via UpdateNetworkIP (example broadcast and gateway IPs) |
| owner_uuid		| String	| Optional owner UUID of the instance the IP is associated with |
| belongs_to_uuid	| String	| Optional UUID of the instance the IP is associated with |

###### output (example)

```
GET /:login/networks/b330e2a1-6260-41a8-8567-a8a011f202f1/ips
[
 ...... elided
  {
    "ip": "10.88.88.105",
    "reserved": true,
    "managed": false
  },
  {
    "ip": "10.88.88.106",
    "reserved": false,
    "belongs_to_uuid": "0e56fe34-39a3-42d5-86c7-d719487f892b",
    "owner_uuid": "7dfbbcda-4f62-cdf8-df31-d1e4d8d34c5e",
    "managed": false
  }
 ...... elided
]
```

###### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| If :login or :id does not exist			|

##### GetNetworkIP (GET /:login/networks/:id/ips/:ip_address)

###### output

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ip			| String	| IP Address				|
| reserved		| Boolean	| Whether this IP is reserved or not	|
| managed		| Boolean	| True if the user cannot modify the IP via UpdateNetworkIP (example broadcast and gateway IPs) |
| owner_uuid		| String	| Optional owner UUID of the instance the IP is associated with |
| belongs_to_uuid	| String	| Optional UUID of the instance the IP is associated with |

###### output (in use)

```
GET /:login/networks/b330e2a1-6260-41a8-8567-a8a011f202f1/ips/10.88.88.106

{
  "ip": "10.88.88.106",
  "reserved": false,
  "belongs_to_uuid": "0e56fe34-39a3-42d5-86c7-d719487f892b",
  "owner_uuid": "7dfbbcda-4f62-cdf8-df31-d1e4d8d34c5e",
  "managed": false
}
```

###### output (not in use)

```
GET /:login/networks/b330e2a1-6260-41a8-8567-a8a011f202f1/ips/10.88.88.105

{
  "ip": "10.88.88.105",
  "reserved": true,
  "managed": false
}
```

###### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| If :login or :id does not exist			|

##### UpdateNetworkIP (PUT /:login/networks/:id/ips/:ip_address)

It is worth noting that when you delete an instance that has a reserved IP the
IP will remain reserved. This means that the IP will not be in the allocation
pool of possible IPs when creating another instance.

###### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| reserved		| Boolean	| Reserve/Unreserve the IP		|

```
{ "reserved": true }
```

###### output

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ip			| String	| IP Address				|
| reserved		| Boolean	| Whether this IP is reserved or not	|
| managed		| Boolean	| True if the user cannot modify the IP via UpdateNetworkIP (example broadcast and gateway IPs) |
| owner_uuid		| String	| Optional owner UUID of the instance the IP is associated with |
| belongs_to_uuid	| String	| Optional UUID of the instance the IP is associated with |

###### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| If :login, :id, or :ip_address does not exist		|
| MissingParameter	| ip and or reserved are not set			|
| InvalidArgument	| trying to modify a triton_reserved ip			|

#### Instances

##### CreateMachine (POST /:login/machines)

The only change here is to the networks array, it is now an array of objects.
CloudAPI will also still accept an array of network UUID strings.

###### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| ...			|		|					|
| networks		| Array		| Array of network objects		|
| ...			|		|					|

```
"networks": [
  { "ipv4_uuid": "58f75b3e-15aa-4bab-ad22-c6546cfd6b59" },
  { "ipv4_uuid": "72a9cd7d-2a0d-4f45-8fa5-f092a3654ce2", "ipv4_ips": ["192.168.1.234"] }
]
```

See the relevant notes in the AddNic section.

### Docker Changes

There are no changes to `VMAPI` planed for this RFD.  There should be no
changes in how docker operates for the time being.
