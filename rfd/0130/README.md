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

[RFD 119] Discusses same-region remote Triton VXLANS in more detail.  Two or
more Triton DCs can have cross-DC-reachable underlay infrastructure, allowing
AWS-style availability zones in a region.

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
