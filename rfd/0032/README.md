---
authors: Cody Mello <cody.mello@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 32 Multiple IP Addresses in NAPI

# Introduction

With [RFD 11], we began moving towards allowing multiple IP addresses per NIC,
and supporting IPv6. With multiple addresses, it becomes necessary to change how
consumers can map a NIC's addresses to the UUID of the network that the address
is on, as well as make it easier for consumers, both human and programs, to
manipulate the set of addresses on a NIC. This RFD lays out changes to the
Network API (NAPI), to solve these issues.

Originally, [RFD 11] planned to add a single field **network6\_uuid**, which
would contain the UUID of the network that IPv6 addresses were allocated out of.
As work progressed, it became apparent that this scheme had several issues:

* Adding a new field for every address family is not a clean solution
* It prohibits breaking up a subnet into multiple non-overlapping networks with
  different start and end addresses for provisioning, and then using addresses
  from several of those networks on the same NIC
* It prohibits ever supporting multiple IPv6 prefixes on a network interface

While there are no immediate plans for implementing and supporting the latter
two in Triton, we wish to avoid designing ourselves out of the possibility of
doing so in the future.

# Changes to NAPI

The only API that will change is NAPI, as described below. VMAPI will be updated
to take advantage of the new API as part of the [RFD 11] work, but the API that
it exposes to consumers will remain the same as currently documented.


## Mapping Addresses to Network UUIDs

Once NAPI gains support for IPv6 and multiple addresses, addresses will be
mapped to their network by the **addresses** field, which is an array of objects
describing each IP the NIC has:

```
"addresses": [
	{
		"cidr": "10.0.0.3/24",
		"network_uuid": "0cb352c0-9c60-4fcd-96a9-5369ba78f2c2",
		"family": "ipv4"
	},
	{
		"cidr": "10.0.1.241/24",
		"network_uuid": "911f674d-c74e-4fe1-bc7d-daf8c1866fd4",
		"family": "ipv4"
	},
	{
		"cidr": "fd00::a2c/64",
		"network_uuid": "c97033e2-8eff-4a4f-a7e5-564ee2eb8863",
		"family": "ipv6"
	}
]
```


## Modifying a NIC's IP addresses

Addresses can be added and removed from a NIC by describing the desired changes
in the **addresses\_updates** field. For example, the following would request a
specific address on an IPv4 network, 4 addresses on an IPv6 network pool, and
delete an address from a NIC:

```
"addresses_updates": [
	{
		"action": "add",
		"ip": "10.0.0.3",
		"network_uuid": "0cb352c0-9c60-4fcd-96a9-5369ba78f2c2"
	},
	{
		"action": "add",
		"count": 4,
		"network_uuid": "40284ee1-81cb-4a72-9cc8-c8c7121f3ea9"
	},
	{
		"action": "delete",
		"ip": "10.0.1.241",
		"network_uuid": "911f674d-c74e-4fe1-bc7d-daf8c1866fd4"
	}
]
```

This field can be specified when creating (`POST /nics`) or updating
(`PUT /nics/:mac`) a NIC. Specifying a `delete` action is only allowed when
updating a NIC, and only an `ip` can be deleted, not a `count`. If an `action`
is not specified, then the field defaults to `add`. The `network_uuid` must
always be specified for both `add` and `delete` actions.


## Ensuring consistent NIC properties

Since network properties can vary in several ways that are relevant to
instantiating a VNIC (`nic_tag`, `vnet_id`, `vlan_id` and `mtu`), it is
important to ensure that the specified networks and pools are used in such a way
that these properties are consistent between all of them. If multiple pools are
specified, and their networks have different properties as allowed by [RFD 43],
then NAPI will try each possible configuration that allows for consistently
selecting these properties.

Updatable physical properties on networks, like `mtu`, will require checks that
an update does not introduce conflicts in combinations of networks on existing
NICs.


## Handling Partial Upgrades

Since NAPI will continue to accept the old `ip` and `network_uuid` fields,
upgrading NAPI ahead of VMAPI will not be an issue. If VMAPI is upgraded ahead
of NAPI, though, VMAPI's workflow will not be able to determine if the new NAPI
is aware of `addresses_updates` until after it attempts to provision a new NIC
with multiple addresses. If multiple addresses are requested on a NIC, VMAPI
will check if the provisioned NIC contains the `addresses` field. If it doesn't,
then it will fail the VM provision and release the provisioned NICs.

[RFD 11]: ../0011
[RFD 43]: ../0043
