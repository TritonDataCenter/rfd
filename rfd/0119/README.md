---
authors: Dan McDonald <danmcd@joyent.com>
state: predraft
discussion: <Coming soon>
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent
-->

# RFD 119 Routing Between Fabric Networks

<!--
TODO:
- need dcapi for coordinating who's in a region
- fill out SVP changes
- describe overlay(5) implementation more
-->

## Problem Statement

Today, Triton Fabric Networks are self-contained. A customer can create a
network using an RFC 1918 subnet, provision instances on it, and have them
communicate using their fabric addresses. They can create additional networks
with disjoint prefixes, but they cannot reach with each other.

We would like to allow customers to configure routes between networks so that
they can pass their traffic between networks as needed. We would also like to
allow routing between fabric networks that are in the same region (like us-east)
but are in different datacenters. This creates several problems:

* The Virtual Network identifier (VNET ID) is not guaranteed to be the same per
  customer across datacenters.
* MAC addresses may be duplicated in different datacenters.
* Network UUIDs may collide across datacenters.

It is worth noting that a lot of the difficulty for implementing this comes from
the strong level of isolation we've created between our datacenters. If NAPI and
Portolan in each datacenter used the same backing store, then coordination would
be easier, but moving them to using the same backing store isn't
an option unfortunately since, for existing installations, it would mean:

* Migrating all of the existing NAPI and Portolan data in the same database.
* Resolving the pre-existing conflicts noted above in NAPI and on all CNs with
  instances using the old pre-resolution information.

Doing these steps would effectively require taking the whole region offline, one
datacenter at a time.

## Proposed Solution

A new attribute, the `attached_networks` attribute, will be added to NAPI's
network object. It will be an array of Triton network UUIDs that VMs on the
network are able to route to. (For people moving from AWS, this is akin to a VPC
Route Table.) For now, only fabric networks owned by the same customer will be
allowed to be attached to a fabric network, but with the introduction of Remote
Network Objects (see [RFE 2]) and someday AUTHAPI (see [RFD 48]),
cross-customer, cross-region, and non-Triton peers can be reachable as well.

### NAPI Changes

The Networking API (NAPI), will need to begin communicating with remote NAPIs in
the same region in order to get the information that it needs to validate and
set up fabrics to communicate with each other: owner UUID, destination subnet,
VNET identifier, VLAN identifier, and the MAC address the network uses for
fabric routing.

#### Connecting Networks

NAPI fabric networks will now have a new property: `attached_networks`.  The
`attached_networks` property consists of an array of network UUIDs. The
networks must be owned by same owner as the containing fabric network. When a
network has other networks attached to it, we will adjust the `"routes"` table
to include entries for each attached subnet.

There are two classes of fabric networks that can be attached to a network, and
affect the routes that get created for it. There are fabrics that are located on
the same Virtual Layer 2 (VL2) network (same datacenter, same VNET identifier,
and same VLAN identifier), and there are fabrics that are located on a separate
VL2, possibly in another datacenter.

The first class of networks can be made to work today with some manual
configuration on the part of the customer. For these networks, we will return
`"linklocal"` in the `"routes"` object to indicate that they can be treated like
they are on the same virtual segment. (See [TRITON-265] and [TRITON-266] for
supporting interface routes in Triton.)

When attaching to the second class of networks, NAPI will select an IP address
from the source network, save it in the `"overlay_router"` field, and use it as
the next-hop address in the `"routes"` object. This IP address will be mapped in
Portolan to a special MAC address recognized by the overlay devices. (See the
Overlay Changes section for more here.)

When fetched from NAPI, the field will look something like:

```
# sdc-napi /networks/03b9302a-0e4f-471c-8f21-2a46173b15bd | json -H
{
  ...
  "attached_networks": [
    "f4104070-df1e-4c4a-891c-58951abd72e8",
    "103b4f01-b8bc-42a5-886a-0a680da22d20",
    "b1963383-6b1a-4025-b73d-a7fb43ff7624"
  ],
  ...
}
```

Note that when a network appears in an `"attached_networks"` array, then it will
also contain its own mirroring `"attached_networks"` entry, to guarantee that
two networks are always mutually routable and help prevent users from
accidentally configuring a network to pass traffic in one direction but
forgetting to do so in the other.

Since attaching networks together requires changes to instance routing tables,
the work for this RFD will depend on the [RFD 28] work being done, too.

### Representing Remote Networks Locally

When a network is attached locally, we will import the properties about it that
we need to know locally and assign it a local UUID. When fetched from NAPI, it
will look like:

```
# sdc-napi /networks/410fc93e-957a-4344-9112-ec17d5a946b5 | json -H
{
    "uuid": "410fc93e-957a-4344-9112-ec17d5a946b5",
    "remote": true,
    "remote_uuid": "025133ae-d107-47ab-aa08-27bb5e16e699",
    "remote_dc": "us-east-3",
    "subnet": "10.0.34.0/24",
    "fabric": true,
    "vnet_id": 56634,
    "vlan_id": 23
}
```

In the future `"remote"` may be used to indicate other kinds of remote networks,
possibly reachable through some kind of authenticated tunnel.

#### Tracking Changes

Since each NAPI will have a different backing store, they'll need to track
changes made in the other datacenter. To do this, they will use [sdc-changefeed]
to learn about updates as they happen, similar to what [net-agent] will start
doing for [RFD 28]. This will allow NAPI to generate shootdowns for Portolan to
distribute locally whenever it sees a network or fabric NIC destroyed in the
remote datacenter.

As part of deploying this work, we will want to start deploying multiple NAPI
instances for high availability. Since changefeed currently only supports a single
publisher mode, we will want to add support for multiple publishers as part of
this work (see [TRITON-276]).

### Overlay Changes

Currently the SmartOS [overlay(5)] device works with `varpd` and its SDC VXLAN
Protocol (SVP) plugin to determine where MAC addresses live. The SVP plugin
communicates with Portolan to resolve overlay IPs (VL3 addresses) to overlay
MACs (VL2 addresses), and the VL2 addresses to underlay addresses (UL3). This
information gets cached in the kernel for future packets.

There are several properties of cross-DC routing that guide the solution here:

- VNET identifiers differ from datacenter to datacenter, so they need to be set
  to match the destination network.
- MAC addresses aren't guaranteed to be unique across datacenters, so we can't
  rely on the MAC address of the destination host to map 1-to-1 to an underlay
  IP.

To get around these, we will use a special MAC address to determine whether we
need to inspect the destination IP address (which we can then use to find the
UL3 information), whether we need to rewrite the VL2 information, and what VNET
identifier to use. We will also need to change the source MAC address to match
the special MAC address being used on the destination fabric network.

To help the SVP plugin, we will pass additional arguments to `create-overlay`
(which currently come from booter):

- `dcid`, the local datacenter identifier
- `svp/router_oui`, the prefix used in the fabric router MAC address

### Portolan Changes

Portolan will need to be informed by NAPI what a network is allowed to route to,
so that it can supply the information needed by [overlay(5)]. We will introduce
two new message types, `SVP_ROUTE_REQ` and `SVP_ROUTE_ACK`:

```c

```

We will also add source VLAN information to VL3 requests so that we can allow
overlapping subnets on different VLANs within a datacenter. This will allow
people to create parallel setups that look exactly alike for testing purposes.

Portolan, like NAPI, will need to start querying Portolans in other datacenters
within the region to share their mappings locally.


### Platform Changes

* In order to make the impact of attaching networks more immediate, we will update
  the routing table for OS and LX zones at the time of `vmadm update`, instead of
  waiting for the next reboot. (See [OS-6817] and [OS-6818].)
* Since we'll need to route between datacenters within a region, we'll need to
  make sure that the underlay networks can reach each other. In case the traffic
  needs to be routed through something other than the admin network's default
  gateway, we should add support for setting up static routes in the global zone
  network initialization script. (See [OS-6816].)

<!-- Manual pages -->
[overlay(5)]: https://smartos.org/man/5/overlay

<!-- GitHub links -->
[sdc-changefeed]: https://github.com/joyent/node-sdc-changefeed/

<!-- Issue links -->
[OS-6816]: https://smartos.org/bugview/OS-6816
[OS-6817]: https://smartos.org/bugview/OS-6817
[OS-6818]: https://smartos.org/bugview/OS-6818
[TRITON-265]: https://smartos.org/bugview/TRITON-265
[TRITON-266]: https://smartos.org/bugview/TRITON-266
[TRITON-276]: https://smartos.org/bugview/TRITON-276

<!-- RFE links -->
[RFE 2]: https://github.com/joyent/rfe/tree/master/rfe/0002

<!-- Other RFDs -->
[RFD 28]: ../0028
[RFD 48]: ../0048
