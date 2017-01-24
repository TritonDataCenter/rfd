---
authors: Cody Mello <cody.mello@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 84 Providing Manta access on multiple networks

# Introduction

Manta currently assumes that its load balancers only need to provide access to
the `manta` and `external` networks. The `external` network provides access to
the public internet, and the `manta` network allows
[Marlin] privileged access to Manta.

It is common for Triton deployments to have a datacenter-internal network that
allows instances deployed in the same datacenter or region to talk to each other
using [RFC 1918] networks. Since these networks tend to not have gateways to the
internet, any instances on them that need to talk to Manta must also be on an
external network. Or, if the network does have a NAT to the internet, then the
NAT introduces a performance bottleneck for accessing Manta.

This RFD proposes extending the Manta tooling to allow configuring load
balancers to listen on multiple networks, so that they can provide service to
private networks throughout the region.

# New `manta-adm` commands

`manta-adm` will need to gain commands for managing how many load balancers
there are for each untrusted network. These numbers should be disjoint, so that
IPs on one network do not have to be exhausted solely because more load
balancers are needed on another. For example, it may be desirable to have 5 load
balancer IPs on a private network, and 10 load balancer IPs on an external
network. To avoid wasting resources, these networks could be distributed across
the same zones. In our example, we would only need 10 zones, where each would
have one external IP, and half of them would have a private IP.

# Load balancer configuration changes

`stud` already listens on all interfaces, so its configuration should not
require any changes. `haproxy`, however, neds to have two different groups of
configurations for listening on port 80: one for [Marlin], and one for public,
untrusted access. When the `haproxy` configuration is generated, the untrusted
group will need to be set up for each required network. Information on which
networks these are will probably come from SAPI.

<!-- GitHub repositories -->
[Marlin]: https://github.com/joyent/manta-marlin

<!-- RFCs -->
[RFC 1918]: https://tools.ietf.org/html/rfc1918
