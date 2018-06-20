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

# RFD 130 The Triton Remote Network Object

<!--
TODO:
- need dcapi for coordinating who's in a region
- MORE -- FILL ME IN!
-->

## Problem Statement

Other cloud solutions, such as Amazon VPC, allow the specification of
off-local-cloud networks.  Today, Triton has no such abstraction in NAPI and
other higher-level APIs.  These off-local-cloud networks include
IPsec-protected VPNs, and in our case, potentially other-region Triton
instances.

## Proposed Solution

The Remote Network Object introduces an extension to Network Objects to
contain all information required to establish a remote network outside of
Triton.

A remote network will have an encapsulation strategy.  Proposed encapsulation
strategies include:

### Same-region Remote Triton VXLAN with SVP discovery.

Two or more Triton DCs can have cross-DC-reachable underlay infrastructure,
allowing AWS-style availability zones in a region. This creates several
problems:

* The Virtual Network identifier (VNET ID) is not guaranteed to be the same per
  customer across datacenters.
* MAC addresses may be duplicated in different datacenters.
* Network UUIDs may collide across datacenters.

When a remote network is attached locally, we will import the properties
about it that we need to know locally and assign it a local UUID. When
fetched from NAPI, it will look like:

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

#### NAPI changes for same-region Remote Triton

The Networking API (NAPI), will need to begin communicating with remote NAPIs
in the same region in order to get the information that it needs to validate
and set up fabrics to communicate with each other: owner UUID, destination
subnet, VNET identifier, VLAN identifier, and the MAC address the network
uses for fabric routing.

#### Tracking Changes

Since each NAPI will have a different backing store, they'll need to track
changes made in the other datacenter. To do this, they will use
[sdc-changefeed] to learn about updates as they happen, similar to what
[net-agent] will start doing for [RFD 28]. This will allow NAPI to generate
shootdowns for Portolan to distribute locally whenever it sees a network or
fabric NIC destroyed in the remote datacenter.

As part of deploying this work, we will want to start deploying multiple NAPI
instances for high availability. Since changefeed currently only supports a
single publisher mode, we will want to add support for multiple publishers as
part of this work (see [TRITON-276]).

#### Overlay changes

There are several properties of cross-DC routing that guide the solution
here:

- VNET identifiers differ from datacenter to datacenter, so they need to be set
  to match the destination network.

- MAC addresses aren't guaranteed to be unique across datacenters, so we can't
  rely on the MAC address of the destination host to map 1-to-1 to an underlay
  IP.

- Destination subnets are not guaranteed to be unique to a datacenter. (For
  example, each user has a `My-Fabric-Network` in each datacenter in a region
  today, each one using the 192.168.128.0/22 subnet.)

One new addition to the SVP overlay lookup service for cross-DC encapsulation
is:

- `dcid`, the local datacenter identifier from DCAPI (see [RFD 131])

#### Portolan changes

We will also add source VLAN information to VL3 requests so that we can allow
overlapping subnets on different VLANs within a datacenter. This will allow
people to create parallel setups that look exactly alike for testing
purposes.

_remove ?_ Portolan, like NAPI, will need to start querying Portolans in
other datacenters within the region to share their mappings locally.

#### Platform changes

* Since we'll need to route between datacenters within a region, we'll need to
  make sure that the underlay networks can reach each other. In case the
  traffic needs to be routed through something other than the admin network's
  default gateway, we should add support for setting up static routes in the
  global zone network initialization script. (See [OS-6816].)


### OEM VXLAN

A remote network may be attached to a Triton cloud using VXLAN
encapsulation.  Such a network would use the overlay varpd ```direct```
discovery method on the Triton/SmartOS side, and similar configuration on the
remote side.

Like other OEM networks, Triton will need to provide OEM Parameters so the
OEM network can be appropriately configured.

### OEM IPsec

A remote network, especially when traversing a hostile internet

Like other OEM networks, Triton will need to provide OEM Parameters so the
OEM network can be appropriately configured.

## Minimum Attributes

A Remote Network Object at a minimum contains:

- At least one remote IP prefix that is not a prefix already used by the user
  on a fabric.
- An encapsulation strategy

Some encapsulation-strategies may require additional strategy-specific
parameters.

For Same-region Remote Triton VXLAN with SVP discovery:

- A remote DC name or identifier
- A remote network UUID
- A remote network vnet ID
- A remote network VLAN ID

For OEM VXLAN:

- A remote external IP address.
- (optional) A remote UDP port.
- A remote network vnet ID

For OEM IPsec:

- A remote external IP address.
  NOTE: It is highly recommended that this IP not be the front of a NAT.
- (write-only) a Preshared key, either as an ASCII string or a 0xnnn
  arbitrarily long hex-digit string 

## OEM Parameters

For OEM networks, Triton will have to produce a list of parameters that can
be fed into the OEM network configuration tool(s).

<!-- Other RFDs -->
[RFD 119]: ../0119



