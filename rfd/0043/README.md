---
authors: Robert Mustacchi <rm@joyent.com>, Cody Mello <cody.mello@joyent.com>
state: publish
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent Inc.
-->

# RFD 43 Rack Aware Network Pools

A growing trend in network design is to design the physical topology of
the network such that all the machines in a given rack are part of their
own broadcast domain. In those worlds, each rack basically uses its own
layer three network and VLAN. This may look something like:

```
  Rack  100                   Rack  150                  Rack  200              
  VLAN  100                   VLAN  150                  VLAN  200
  L3    192.168.100.0/24      L3    192.168.150.0/24     L3    192.168.200.0/24 
 +----------------------+    +----------------------+   +----------------------+
 |         TOR          |    |         TOR          |   |         TOR          |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.4/24 |    | CN: 192.168.150.4/24 |   | CN: 192.168.200.4/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.5/24 |    | CN: 192.168.150.5/24 |   | CN: 192.168.200.5/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.7/24 |    | CN: 192.168.150.7/24 |   | CN: 192.168.200.7/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.8/24 |    | CN: 192.168.150.8/24 |   | CN: 192.168.200.8/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.9/24 |    | CN: 192.168.150.9/24 |   | CN: 192.168.200.9/24 |
 +----------------------+    +----------------------+   +----------------------+
 |         ...          |    |         ...          |   |         ...          |
 +----------------------+    +----------------------+   +----------------------+
```

Note how each rack in the example there has its own VLAN and its own L3
network. To communicate between the racks, routing is employed and
generally the top of rack switches (TOR) advertise the summarized
prefix. While these examples are focused on IPv4, the same can logically
be said for IPv6.

## Triton Network Pools

Today, Triton network pools are used as a way of joining together multiple
disjoint L3 networks which provide a common set of resources. The most
common use case for a network pool is for something like an 'external'
pool, whereby an organization groups together their disjoint sets of
public IP addresses into one pool.

The use of a network pool is very useful. It allows us to give users
something for provisioning that will be a constant and work as the
availability of the networks that make up the pool come and go.

### Constraints on Network Pools

Today the primary constraint on a network pool is that all of the
networks in the pool must have the same NIC tag. In SmartOS and Triton,
NIC tags are a way of assigning a name to a physical network and marking
which NICs are on it. This allows configuring VMs with the name of the
physical network they should be on instead of a Compute Node's MAC
address or the name of a NIC.

The reason for this constraint is largely due to where it comes in the
provisioning process and what the network pool currently represents. The
general idea of a network pool today is that any of the networks in the
pool should be interchangeable when considering provisioning. This is
enforced by requiring that each network have the same NIC tag.

## Removing the NIC tag constraint

While the existing networking pool abstraction is very useful, it breaks
down in the face of customers who are using topologies as described in
the introduction. Since a NIC tag describes a set of connected resources
at the physical level, a given NIC tag may only span a given rack.

Because of this, we cannot construct network pools in such topologies
that can span multiple racks as the NIC tags are not equivalent nor
should they be in this world.

What we want is a way to use network pools where, rather than simply
assuming that every network is interchangeable, we instead say that
after we pick a given CN for provisioning we pick a specific, compatible
network from this set. In other words, the pool can be made up of
networks that are bound to specific racks. When a rack is selected for
provisioning then the set of networks is whittled down to those which
are available on that rack, and an IP provision is attempted on each
one.

## Changes to Provisioning Workflow

This work will require changes to both DAPI and NAPI, and changes to
VMAPI's workflows to take advantage of their new behaviour.

NAPI will need to return a `nic_tags_present` array on network pools to
indicate the union of all contained networks' tags. Using this
information, DAPI's server selection logic will need to determine which
servers provide all of the NIC tags needed to satisfy at least one of
the networks from each pool that is being provisioned on.

Once the decision is made, the VMAPI workflow will provision the NIC
with a `nic_tags_available` field, which will contain a list of all of
the NIC tags present on the selected CN. This will allow NAPI to try
multiple possible solutions when networks are full.

Consider an attempt to provision a VM with two NICs, each one on a
different network pool:

```
[root@headnode (coal) ~]# sdc-napi /network_pools/232074d4-ca09-c15c-b5ee-d836de76514d | json -H
{
  "family": "ipv4",
  "uuid": "232074d4-ca09-c15c-b5ee-d836de76514d",
  "name": "external",
  "description": "Internet-accessible networks",
  "networks": [
    "e1d9e935-4cfb-4d55-b968-2ff7c8470ffe",
    "8bf3b871-2888-469d-97f5-910ca8ba7ec5",
    "af7e657a-3a01-488f-9002-957ceb02bcf9",
    "56198bc6-6a0d-4286-ba4b-2b295cd27ab3",
    "ede0ebea-5288-4d16-a405-da86c21a6547"
  ],
  "nic_tag": "r1external",
  "nic_tags_present": [
    "r1external",
    "r2external",
    "r3external"
  ]
}
[root@headnode (coal) ~]# sdc-napi /network_pools/ef8ac216-4205-cd47-a839-bd4e269dc6c3 | json -H
{
  "family": "ipv4",
  "uuid": "673603c1-38c6-4db1-acb7-a7b51f6469c3",
  "name": "internal",
  "description": "DC-internal networks",
  "networks": [
    "7434e9cd-f887-49f5-8e22-4121cb628344",
    "46a357de-e875-4ee9-a46f-5e6375f04e86",
    "25a2969e-02ba-4dc3-aeec-28f1884ee66d"
  ],
  "nic_tag": "r1internal",
  "nic_tags_present": [
    "r1internal",
    "r2internal",
    "r3internal"
  ]
}
```

VMAPI would pass this information to DAPI, which would then look for a
server that is on one of the NIC tags from each network pool. In this
example, where each NIC tag corresponds to a network classified as
internal or external in each rack, DAPI might find servers that match
`"r1external"/"r1internal"`, `"r2external"/"r2internal"`, or
`"r3external"/"r3internal"`.

At this point, DAPI would pick a matching server, whose NIC tags might
be `"r1internal"`, `"r1external"`, `"admin"`, `"sdc_underlay"`, and
`"sdc_overlay"`. VMAPI would send this set of tags to NAPI in the
`nic_tags_available` field for both NICs that it's provisioning. When
considering the set of networks in the pools, it'll select those that
are on `"r1internal"` and `"r1external"`, and ignore those that are on
other racks.

If all networks in the pool for the provided NIC tags are full, then the
NIC provision will fail, and an operator will need to either create
additional networks for that NIC tag and add them to the pool or remove
the full networks to stop attempts to provision on them.

See [DAPI-340], [NAPI-403], and [ZAPI-781] for the work done to implement
the logic described above.

### Handling Partial Upgrades

If VMAPI and CNAPI are upgraded ahead of NAPI, then network pools with
mixed NIC tags cannot be created, and the APIs can behave in the same
way that they do today. If, however, NAPI is upgraded ahead of VMAPI and
CNAPI, it would be possible for someone to create a network pool with
mixed tags, and try to provision on it. In this case, NAPI would not
receive the `nic_tags_available` array, and would not be able to safely
select which networks can be used on the destination CN. NAPI would then
fail NIC provisions on this pool until VMAPI and CNAPI are upgraded to
new enough versions.

<!-- Issue links -->
[DAPI-340]: https://smartos.org/bugview/DAPI-340
[NAPI-403]: https://smartos.org/bugview/NAPI-403
[ZAPI-781]: https://smartos.org/bugview/ZAPI-781
