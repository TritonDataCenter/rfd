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

# Changes to `manta-adm update`

The configuration passed to `manta-adm update` will need to support specifying
how many load balancers there should be on each untrusted network. The
configuration should support specifying the number of load balancers on each
network such that they are managed independently from each other. This is
important, since it helps ensure that scaling more instances on one network does
not exhaust addresses on another.

For example, it may be desirable to have 5 load balancer IPs on a private
network, and 10 load balancer IPs on an external network. To avoid wasting
compute resources, these networks could be distributed across the same zones. In
our example, we would only need 10 zones, where each would have one external IP,
and half of them would have a private IP. Configuring this would look like:

```json
{
    "d141fd2e-cb51-4e39-bb8e-e7ebfb0dc989": {
        ...
        "loadbalancer": [
            {
                "image_uuid": "2b4bb987-427c-435f-becf-a1465de9bfa8",
                "networks": [
                    "7e15c9dd-aef7-4b6e-8e7d-be878c9212a0",
                    "c2bf1351-fed0-4e72-a02e-e64963a0b427"
                ],
                "count": 5
            },
            {
                "image_uuid": "2b4bb987-427c-435f-becf-a1465de9bfa8",
                "networks": [ "c2bf1351-fed0-4e72-a02e-e64963a0b427" ],
                "count": 5
            }
        ],
        ...
    }
}
```

The contents of `"networks"` can be either an array of UUIDs, or specified in
the [interface-centric style], as with VMAPI. (This is how `manta-adm show -j`
will display the configuration.) For example, the first configuration above
could have been specified as:

```json
{
    "image_uuid": "2b4bb987-427c-435f-becf-a1465de9bfa8",
    "networks": [
        { "ipv4_uuid": "7e15c9dd-aef7-4b6e-8e7d-be878c9212a0" },
        { "ipv4_uuid": "c2bf1351-fed0-4e72-a02e-e64963a0b427" }
    ],
    "count": 5
}
```

In the future, this will enable you to specify IPv4 and IPv6 networks on the
same interface. Note that when specifying things this way, you cannot use
`ipv4_ips` or `ipv6_ips`, since a single address cannot belong to multiple
instances.

When updating an existing configuration, `manta-adm` should show, in addition to
its planned provisions and reprovisions, the NIC additions and removals that it
is about to perform, so that the operator can see how the network configuration
is about to change.

# Load balancer configuration changes

`stud` already listens on all interfaces, so its configuration should not
require any changes. `haproxy`, however, needs to have two different groups of
configurations for listening on port 80: one for [Marlin], and one for public,
untrusted access. When the `haproxy` configuration is generated, the untrusted
group will need to be set up for each required network. Untrusted networks will
be the set of networks available in the zone that are not on the `admin` or
`manta` networks.

## Preparing for IPv6

IPv6 support is being added to Triton as laid out in [RFD 11]. To prepare for
when IPv6 networks can be added to zones, Manta's load balancers should listen
on IPv6 addresses when present. When [Muppet] selects addresses for `haproxy` to
use, it will use the [sdc:nics] metadata key to learn about its NICs and their
addresses, and use the stable, documented `"ips"` field on the NIC objects,
which will include any IPv6 addresses assigned to the NIC.

`stud` will not require any changes since it already listens on the IPv6
unspecified address `::`.

<!-- GitHub repositories -->
[Marlin]: https://github.com/joyent/manta-marlin
[Muppet]: https://github.com/joyent/muppet

<!-- RFCs -->
[RFC 1918]: https://tools.ietf.org/html/rfc1918

<!-- RFDs -->
[RFD 11]: ../0011

<!-- Other links -->
[sdc:nics]: https://eng.joyent.com/mdata/datadict.html#sdcnics
[interface-centric style]: https://github.com/joyent/sdc-vmapi/blob/master/docs/index.md#specifying-networks-for-a-vm
