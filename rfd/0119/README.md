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

# RFD 119 The attached_networks Attribute for Fabric Networks


## Problem Statement

Today, Triton Fabric Networks are self-contained.  A prefix is assigned, and
instances attach to it.  A Triton customer can create *multiple* Fabric
Networks with disjoint prefixes.  Today, these multiple Fabric Networks
cannot reach each other.

## Proposed Solution

A new attribute, the attached_networks attribute, will be added to NAPI's
network object.  It is a list of Triton network UUIDs.  For people moving
from AWS, this is akin to a VPC Route Table.  Initially allowable networks
must share the same VLAN ID and the same VNET ID (i.e. same-customer).
Eventually the VLAN ID restriction can be lifted, and with the introduction
of Remote Network Objects (see RFE 2), cross-customer, cross-DC, and
non-Triton peers can be reachable as well.

### NAPI changes

NAPI fabric networks will now have a new property:  ```attached_networks```.
The ```attached_networks``` property consists of an array of network UUIDs.
The networks MUST be owned by same owner as the containing fabric network.

     XXX KEBE ASKS: For real remote-networks, a Remote Network Object can be
     here, but what about remote-networks that are same-region/different-DC?
     Or even other-triton (where we can cheat a little w.r.t knowing things)
     Cody and I had this discussion and didn't come to a satisfying
     conclusion.

```
{
  "attached_networks": [
    "f4104070-df1e-4c4a-891c-58951abd72e8",
    "103b4f01-b8bc-42a5-886a-0a680da22d20",
    "b1963383-6b1a-4025-b73d-a7fb43ff7624"
  ]
}
```

Networks specified in attached_networks can be directly reachable from any
instance on the network.  For example if the three networks above have
prefixes 192.168.2.0/24, 192.168.3.0/24, and 192.168.4.0/24, and the network
object has prefix 192.168.1.0/24, then any instance on 192.168.1.0/24 can
reach the other three networks.  Note that the other networks MUST ALSO
include 192.168.1.0/24 in THEIR OWN ```attached_networks``` list for two-way
reachability.  It is assumed that the user will maintain
```attached_networks``` lists on all of their network as appropriate.

### Implementation

XXX KEBE SAYS FILL ME IN XXX.
