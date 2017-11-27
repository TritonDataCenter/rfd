---
authors: Dan McDonald <danmcd@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/<FILLMEIN>
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->

# RFD 120 The Triton Router Object, phase 1 (intra-DC, fabric only)

## Problem Statement

RFE 1 explores the ways to join two Triton Network Objects together such that
IP packets from one can reach IP packets from another.  This RFD provides the
design for the first phase of Triton Network Objects, the intra-DC Router
Object.  The intra-DC Router Object will take a list of network objects, and
create a new NAPI object to provide connectivity between instances on either
network.

## Proposed Solution

### NAPI changes

#### CreateRouterObject (POST /routers)

Creating a Router Object simply involves listing a number of NAPI network
objects one wishes to join together.  For now, these network objects MUST be
fabrics.

##### input

Requires an array of network objects and a name.  These network object must
be of the same address family (IPv4 or IPv6).

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| networks		| Array		| Array of network objects	|
| name			| String	| Name for this Router Object.	|


```
{
  "name": "My first Router Object",
  "networks": [
    { "uuid": "f4104070-df1e-4c4a-891c-58951abd72e8" },
    { "uuid": "103b4f01-b8bc-42a5-886a-0a680da22d20" },
    { "uuid": "b1963383-6b1a-4025-b73d-a7fb43ff7624" }
  ]
}
```

##### output

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| router		| UUID		| UUID of the Router Object	|
| networks		| Array		| Array of network object UUIDs	|
| family		| String	| Either 'ipv4' or 'ipv6'	|
| name			| String	| Name for this Router Object. |

##### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| MissingParameter	| No array of networks, or a single-element array of networks, get passed in.		|
| InvalidArgument	| Overlapping or duplicate IP prefixes.  Other issues |



#### ModifyRouterNetworks (PUT /routers/:uuid/networks/)

A multi-entry list of networks to add or delete from a router object.

##### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| router		| UUID		| UUID of the Router Object	|
| network_updates	| Array		| Array of actions and networks	|

```
"network_updates": [
	{
		"action": "add",
		"network_uuid": "0cb352c0-9c60-4fcd-96a9-5369ba78f2c2"
	},
	{
		"action": "add",
		"network_uuid": "40284ee1-81cb-4a72-9cc8-c8c7121f3ea9"
	},
	{
		"action": "delete",
		"network_uuid": "911f674d-c74e-4fe1-bc7d-daf8c1866fd4"
	}
]

```

##### output

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| router		| UUID		| UUID of the Router Object	|
| networks		| Array		| Array of network object UUIDs	|
| family		| String	| Either 'ipv4' or 'ipv6'	|
| name			| String	| Name for this Router Object. |

##### errors


| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| Router object or network object does not exist |
| MissingParameter	| No network.				 |
| InvalidArgument	| Overlapping or duplicate IP prefixes.  Other issues |


#### GetRouterObject (GET /routers/:uuid)

##### input

None.

##### output

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| router		| UUID		| Router Object UUID		|
| networks		| Array		| Array of network object UUIDs |
| family		| String	| Either 'ipv4' or 'ipv6'	|
| name			| String	| Name for this Router Object. |

##### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| Router Object :uuid does not exist		|

#### ListRouterObjects (GET /routers)



##### input

| Field			| Type		| Description				|
| ---------------------	| ------------- | ------------------------------------- |
| offset		| integer	| Starting offset, see Pagination |
| limit		| integer		| Maximum number of responses, see Pagination |

##### output

Array of Router Objects, formatted per GetRouterObject.

##### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| InvalidArgument	| Bad offset.			|

#### DeleteRouterObject (DELETE /routers/:uuid)

Deleting a Router Object is done by specifying its UUID.

##### input

None.

##### output

None.

##### errors

| Error Code		| Description						|
| --------------------- | ----------------------------------------------------- |
| ResourceNotFound	| The Router Object :uuid does not exist.	|


### CLOUDAPI changes

<Coming soon.>

### Implementation details.

#### Requirement for RFD 28

RFD 28 (link?) specifies an improved syncing between NAPI and the Compute
Nodes.  That RFD MUST be implemented as a predecessor or concurrent project
to Router Objects.  Any changes in Router Objects must have their routes
propagated to VMs.

#### Router Object Creation - Behind the Scenes

Apart from the API-specified address-family checks, the creation of a Router
Object involves several steps:

- Determine that the networks are Fabric Networks. For now, we only accept
  Fabrics.

- Determine if any network-object prefixes overlap or are duplicated.  For
  now, these are error conditions.

- Create Router Object zones (see below) on every CN.

- Make sure RFD 28 (see above) pushes out new routes to every affected VM.

#### Router Object zones

A router object is implemented by one or more minimal zones per Compute Node
that has the following properties:

- NICs for every network listed in the router object.

- Each zone has the *same* IP addresses regardless of which Compute Node it's
  on.  This will require some NAPI changes to handle an IP address that spans
  multiple zones/CNs.  A new belongs_to_type may be the solution.

These zones perform the work of packet-forwarding.  Because one instantiates
per CN, the availability is equivalent to that of Fabric Networks.  A packet
leaves a zone, its next-hop router is insured to be on the same CN, so at
most, a forwarded packet transits one cross-CN fabric.

Configuring such zones that share IP addresses (exploiting MAC's same-machine
short-circuit path to avoid VARPd) will 

#### Router Object Destruction - Behind the Scenes

Everything that went on behind the scenes in creation gets inverted in Router
Object destruction:

- Router Object zones get destroyed.

- RFD 28 pushes out route deletions to every affected VM.

#### Adding and Deleting Networks

The single primitive ModifyRouterNetworks requires a list of network changes
which can both add and delete networks.  It is possible that the Router
Object's "family" attribute could change if the deletion list eliminates all
of one family, and the addition list adds all of another.

The list will have to be inspected prior to execution of individual adds and
deletions, in cases of conflict (which should return an error), or outright
replacement (which should not).  Conflicts need to be monitored as well.
Adding a network with a specific already-attached prefix may be an error, but
not if the already-attached prefix is being deleted in the same list of
requests.  Only after the list of additions and deletions is checked and
organized can actual deletions and additions occur.

Adding new networks is similar to creating a new Router Object, save that
Router Object zones already exist, and those zones need to be updated via RFD
28.

Deleting existing networks from a Router Object first involves checking
whether or not deleting networks obviates the need for a Router Object
(i.e. only one or zero remaining networks).  In that case, the deletion of
networks reduces to a Router Object deletion.  Otherwise, similarly to adding
new networks, RFD 28 not only needs to reach attached VMs, but the Router
Object zones as well.


