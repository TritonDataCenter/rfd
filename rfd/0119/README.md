---
authors: Jason King <jbk@joyent.com>, Rui Loura <rui@joyent.com>, Dan McDonald <danmcd@joyent.com>, Cody Mello <melloc@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues/88
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.  --> 
<!--
    Copyright 2018 Joyent
-->

# RFD 119 Routing Between Fabric Networks

<!--
TODO:
- fill out SVP changes
- describe overlay(5) implementation more
-->

## Problem Statement

Today, Triton Fabric Networks are self-contained. A customer can create a
network using an RFC 1918 subnet, provision instances on it, and have them
communicate using their fabric addresses. They can create additional networks
with disjoint prefixes, but they cannot reach with each other.

We would like to allow customers to configure routes between networks so that
they can pass their traffic between networks as needed.

## Proposed Solution

A new attribute, the `attached_networks` attribute, will be added to NAPI's
network object. It will be an array of a {Triton network UUID, prefix} tuples
that VMs on the network are able to route to.  For establishing
`attached_networks` only network UUIDs are required. (This is akin to an
Amazon VPC Route Table.) For now, only fabric networks owned by the same
customer on the same DC will be allowed to be attached to a fabric network,
but with the introduction of Remote Network Objects (see [RFE 2] and [RFD
130]) and someday AUTHAPI (see [RFD 48]), cross-customer, cross-DC, and
non-Triton peers can be reachable as well.

### NAPI Changes

#### Connecting Networks

NAPI fabric networks will now have a new property: `attached_networks`.  The
`attached_networks` property consists of an array of {network UUID, IP
prefix} tuples. The networks must be owned by same owner as the containing
fabric network. When a network has other networks attached to it, we will
adjust the `"routes"` table to include entries for each attached
subnet. Using static routes for each destination subnet interacts more
nicely with existing instances that have a primary NIC on the internet and
are using its gateway as their default route.  `attached_networks` cannot be
specified at network creation time, but must be specified via an update.

There are two classes of fabric network attachments. There are fabrics that
are located on the same Virtual Layer 2 (VL2) network (same datacenter, same
VNET identifier, and same VLAN identifier), and there are fabrics that are
located on a separate VL2 (different VLAN identifier).

The first class of networks can be made to work with existing SmartOS with
some manual configuration on the part of the customer. For these networks, we
will return `"linklocal"` in the `"routes"` object to indicate that they can
be treated like they are on the same virtual segment. (See [TRITON-265] and
[TRITON-266] for supporting interface routes in Triton.)

When attaching different-VLAN networks, NAPI will select an IP address from
both networks, save it in the `"overlay_router"` field, and use it as the
next-hop address in the `"routes"` object. This IP address will have a
`belongs_to` setting of `router`, and if one exists already, it will be
reused.  This IP address will also be mapped in Portolan such that the SDC
VXLAN Protocol (SVP) can indicate to the overlay that this IP is a
cross-fabric router. (See the Overlay Changes section for more here.)

When fetched from NAPI, the `attached_networks` will look something like:

```
# sdc-napi /networks/03b9302a-0e4f-471c-8f21-2a46173b15bd | json -H
{
  ...
  "attached_networks": [
    {
      "network_uuid": "f4104070-df1e-4c4a-891c-58951abd72e8",
      "subnet": "10.91.25.0/24"
    },
    {
      "network_uuid": "103b4f01-b8bc-42a5-886a-0a680da22d20",
      "subnet": "10.51.50.0/24"
    },
    {
      "network_uuid": "b1963383-6b1a-4025-b73d-a7fb43ff7624",
      "subnet": "10.21.12.0/24"
    }
  ],
  ...
}
```

Note that when a Triton network appears in an `"attached_networks"` array,
then it will also contain its own mirroring `"attached_networks"` entry, to
guarantee that two networks are always mutually routable and help prevent
users from accidentally configuring a network to pass traffic in one
direction but forgetting to do so in the other.  Remote Networks (see next
section) that are not Triton instances may not be able to provide similar
guarantees about network knowledge.

Since attaching networks together requires changes to instance routing tables,
the work for this RFD will depend on the [RFD 28] work being done, too.

### Representing Remote Networks Locally

In the future `"remote"` may be used to indicate other kinds of remote
networks, possibly reachable through some kind of authenticated tunnel or
other method.  Remote Network Objects are discussed in more depth in [RFD
130].  The current 2-tuple of {network-UUID, prefix} may expand to account
for remote networks.

### Overlay and `varpd` Changes

Currently the SmartOS [overlay(5)] device works with `varpd` and its SDC
VXLAN Protocol (SVP) plugin to determine MAC addresses for a given IP. The
SVP plugin communicates with Portolan to resolve overlay IPs (VL3 addresses)
to overlay MACs (VL2 addresses), and the IP address & port for compute nodes
on the underlay network (UL3). This information gets cached in the kernel for
future packets.

As mentioned in the NAPI section, an attached network has a dedicated router
IP address.  This IP address will have a conventional MAC address, but its
UL3 destination will be `0::0, port 0`, which indicates to both `varpd` and
[overlay(5)] that this IP is a router.

Upon encountering a VL2 cache entry that is a router, overlay will consult a
new cache, the routing cache.  The routing cache is searched by the inner
packet's following fields

| Field          | Description                                        |
|----------------|----------------------------------------------------|
| Source IP      | The source IP address of the packet to be routed.  |
| Destination IP | The destination IP address of the packet.          |
| Source VLAN id | The local VLAN ID for the packet                   |

The routing cache will provide destination information:

| Field           | Description                                        |
|-----------------|----------------------------------------------------|
| Dest. VLAN id   | The VLAN ID for the destination, which will be     |
|                 | placed into the VXLAN packet.                      |
| Dest. VNET id   | For now, identical to the local VNET id, but it    |
|                 | change if we allow cross-user or cross-DC traffic. |
| Data Center id  | For future use in cross-DC traffic.                |
| Remote port     | UDP port for VXLAN traffic.                        |
| Remote IP       | IP address for VXLAN traffic.  (aka. UL3 address)  |
| Source MAC      | MAC source address, so the packet will look local  |
|                 | when it arrives at the remote network.             |
| Destination MAC | MAC destination address, which should match the    |
|                 | router MAC address for the receiving network.      |

Once the route-cache entry is found or resolved by SVP (see below), the
packet moves on as if it were going to a same-subnet peer, as we have the
required information to send it straight to its UL3 destination.

### Portolan and SVP Protocol Changes

Portolan will need to be informed by NAPI what a network is allowed to route
to, so that it can supply the information needed by [overlay(5)].

This will involve an increment of the SVP protocol version from 1 to 2.  With
one exception, version 1 messages will work as they did before in version 2.
For version 2, we will introduce two new message types, `SVP_ROUTE_REQ` and
`SVP_ROUTE_ACK`:

```
{ "name": "struct svp_route_req", "struct": [
		{ "name": "srr_vnetid", "type": "uint32_t" },
		{ "name": "srr_vlanid", "type": "uint16_t" },
		{ "name": "srr_pad", "type": "uint16_t" },
		{ "name": "srr_srcip", "type": "uint8_t [16]" },
		{ "name": "srr_dstip", "type": "uint8_t [16]" }
] },
{ "name": "struct svp_route_ack", "struct": [
		{ "name": "sra_status", "type": "uint32_t" },
		{ "name": "sra_dcid", "type": "uint32_t" },
		{ "name": "sra_vnetid", "type": "uint32_t" },
		{ "name": "sra_vlanid", "type": "uint16_t" },
		{ "name": "sra_port", "type": "uint16_t" },
		{ "name": "sra_ul3ip", "type": "uint8_t [16]" },
		{ "name": "sra_vl2_srcmac", "type": "uint8_t [6]" },
		{ "name": "sra_vl2_dstmac", "type": "uint8_t [6]" },
		{ "name": "sra_src_prefixlen", "type": "uint8_t" },
		{ "name": "sra_dst_prefixlen", "type": "uint8_t" }
		{ "name": "sra_pad", "type": "uint16_t" },
] },

```

Post-version-1 SVP clients (like `varpd`) will send an SVP_R_PING message to
determine the SVP server's version.  The SVP server MUST be able to handle v1
and v2 messages.  The client MUST verify version-appropriate requests, and the
server MUST verify version-appropriate responses.

#### SVP_ROUTE_REQ

| Field      | Type        | Description            |
|------------|-------------|------------------------|
| srr_vnetid | uint32_t    | Source VNET id         |
| srr_vlanid | uint16_t    | Source VLAN id         |
| srr_pad    | uint16_t    | Padding                |
| srr_srcip  | uint8_t[16] | Source IP address      |
| srr_dstip  | uint8_t[16] | Destination IP address |



#### SVP_ROUTE_ACK

| Field             | Type       | Description                         |
|-------------------|-------------|-------------------------------------|
| sra_status        | uint32_t    | Status Code                         |
| sra_dcid          | uint32_t    | Destination datacenter id (future)  |
| sra_vnetid        | uint32_t    | Destination VNET id                 |
| sra_vlanid        | uint16_t    | Destination VLAN id                 |
| sra_port          | uint16_t    | Destination UL port                 |
| sra_ip            | uint8_t[16] | Destination UL IP                   |
| sra_vl2_srcmac    | uint8_t[6]  | Source VL MAC address               |
| sra_vl2_dstmac    | uint8_t[6]  | Destination VL MAC address          |
| sra_src_prefixlen | uint8_t     | Source VL subnet prefix length      |
| sra_dst_prefixlen | uint8_t     | Destination VL subnet prefix length |
| srr_pad           | uint16_t    | Padding                             |



#### SVP_ROUTE operation

When portolan receives an `SVP_ROUTE_REQ`, it will query the
`portolan_vnet_routes` [moray bucket] for all objects containing the
combination of `srr_vnetid,srr_vlanid`.  It will then check each matching
object to see if the `srr_srcip` and `srr_dstip` are included in the object's
`subnet` and `r_subnet` respectively.  If a match is found portolan will fill
out the `SVP_ROUTE_ACK` message and return it to the caller.



#### Shootdowns

The SVP_R_LOG_ACK message can include, for version 2, SVP_LOG_ROUTE
data, in addition to version 1's SVP_LOG_VL2 and SVP_LOG_VL3.

```
{ "name": "struct svp_log_route", "struct": [
		{ "name": "svlr_type", "type": "uint32_t" },
		{ "name": "svlr_id", "type": "uint8_t [16]" },
		{ "name": "svlr_src_vnetid", "type": "uint32_t" },
		{ "name": "svlr_dst_vnetid", "type": "uint32_t" },
		{ "name": "svlr_dcid", "type": "uint32_t" },
		{ "name": "svlr_srcip", "type": "uint8_t [16]" },
		{ "name": "svlr_dstip", "type": "uint8_t [16]" },
		{ "name": "svlr_src_vlan", "type": "uint16_t" },
		{ "name": "svlr_dst_vlan", "type": "uint16_t" },
		{ "name": "svlr_src_prefixlen", "type": "uint8_t" },
		{ "name": "svlr_dst_prefixlen", "type": "uint8_t" },
		{ "name": "svlr_pad", "type": "uint16_t" },
] },

```

| Field              | Type        | Description               |
|--------------------|-------------|---------------------------|
| svlr_type          | uint32_t    | Type, SVP_LOG_ROUTE       |
| svlr_id            | uint8_t[16] | 16-byte UUID              |
| svlr_src_vnetid    | uint32_t    | Source VNET id            |
| svlr_dst_vnetid    | uint32_t    | Destination VNET id       |
| svlr_src_dcid      | uint32_t    | Destination DCID (future) |
| svlr_srcip         | uint8_t[16] | Source IP address base    |
| svlr_dstip         | uint32_t    | Dest. IP address base     |
| svlr_src_vlan      | uint16_t    | Source VLAN id            |
| svlr_dst_vlan      | uint16_t    | Destination VLAN id       |
| svlr_src_prefixlen | uint8_t     | Source IP prefix length   |
| svlr_dst_prefixlen | uint8_t     | Dest. IP prefix length    |
| svlr_pad           | uint16_t    | Padding for alignment     |

In addition to whole-route deletions, VL3 shootdowns may cause additional
work, as any route entries that contain the VL3 address should be deleted as
well.

### Moray Buckets

A new moray bucket will be created named `portolan_vnet_routes`:

Key: `vnet_id,vlan_id,subnet,r_subnet`

NOTE: Both subnets MUST be in IPv6 form, and IPv4 subnets of the form
`a.b.c.d/N` must be expressed as `::FFFF:a.b.c.d/96+N`

| Field      | Type   | Description                                    |
|------------|--------|------------------------------------------------|
| vnet_id    | number | Local VNET id                                  |
| vlan_id    | number | Local VLAN id                                  |
| subnet     | string | Source subnet                                  |
| r_dc_id    | number | Remote DC id                                   |
| r_vnet_id  | number | Remote VNET id                                 |
| r_vlan_id  | number | Remote VLAN id                                 |
| r_subnet   | string | Remote Subnet                                  |
| r_send_mac | number | MAC address that the remote VM should reply to |



### Platform Changes

* In order to make the impact of attaching networks more immediate, we will
  update the routing table for OS and LX zones at the time of `vmadm update`,
  instead of waiting for the next reboot. (See [OS-6817] and [OS-6818].)

<!-- Manual pages -->
[overlay(5)]: https://smartos.org/man/5/overlay

<!-- GitHub links -->
[sdc-changefeed]: https://github.com/TritonDataCenter/node-sdc-changefeed/
[moray bucket]: https://github.com/TritonDataCenter/rfd/blob/master/rfd/0119/README.md#moray-buckets


<!-- Issue links -->
[OS-6816]: https://smartos.org/bugview/OS-6816
[OS-6817]: https://smartos.org/bugview/OS-6817
[OS-6818]: https://smartos.org/bugview/OS-6818
[TRITON-265]: https://smartos.org/bugview/TRITON-265
[TRITON-266]: https://smartos.org/bugview/TRITON-266
[TRITON-276]: https://smartos.org/bugview/TRITON-276

<!-- RFE links -->
[RFE 2]: https://github.com/TritonDataCenter/rfe/tree/master/rfe/0002

<!-- Other RFDs -->
[RFD 28]: ../0028
[RFD 48]: ../0048
[RFD 130]: ../0130
[RFD 131]: ../0131
