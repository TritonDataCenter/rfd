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
encapsulate the information needed to establish a remote network outside of
Triton.

## Minimum Attributes

A Remote Network Object at a minimum contains:

- An existing Fabric Network for local attachment (and local peers)
- A local external IP
- A remote external IP (Needed if encapsulation strategy is something?!?)
- At least one remote IP prefix that is not a prefix already used by the user
  on a fabric.
- An encapsulation strategy (Remote-Triton VXLAN, IP-IP-clear, IP-in-IPsec,
  etc.)

Some encapsulation-strategies may require additional strategy-specific
parameters.

