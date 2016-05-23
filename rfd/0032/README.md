---
authors: Cody Mello <cody.mello@joyent.com>
state: draft
---

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
two in SDC, we wish to avoid designing ourselves out of the possibility of doing
so in the future.

# Changes to NAPI

The only API that will change is NAPI, as described below. VMAPI will be updated
to take advantage of the new API as part of the [RFD 11] work, but the API that
it exposes to consumers will remain the same as currently documented.


## Mapping Addresses to Network UUIDs

Once NAPI gains support for IPv6 and multiple addresses, addresses will be
mapped to their network by the **network\_uuids** field, where the key is the IP
address in CIDR form:

```
"network_uuids": {
	"10.0.0.3/24": "0cb352c0-9c60-4fcd-96a9-5369ba78f2c2",
	"10.0.0.241/24": "911f674d-c74e-4fe1-bc7d-daf8c1866fd4",
	"fd00::a2c/64": "c97033e2-8eff-4a4f-a7e5-564ee2eb8863"
}
```

## Adding Specific Addresses to a NIC

Specific addresses can be added to a NIC either during creation (`POST /nics`)
or during an update (`PUT /nics`), through the **add\_ips** field:

```
"add_ips": {
	"c97033e2-8eff-4a4f-a7e5-564ee2eb8863": [ "fd00::a2c", "fd00::f87" ],
	"911f674d-c74e-4fe1-bc7d-daf8c1866fd4": [ "10.0.0.241", "10.0.0.50" ],
	"456fc468-17ab-11e6-9825-2f5dfdfdfc63": [ "192.168.2.4", "192.168.2.75" ]
}
```

## Requesting Addresses for a NIC

If one does not care about the specific address used on a NIC so long as it is
on the desired network, new addresses can be requested by specifying the network
UUID, or the UUID of a network pool:

```
"add_networks": {
	"c97033e2-8eff-4a4f-a7e5-564ee2eb8863": 3,
	"911f674d-c74e-4fe1-bc7d-daf8c1866fd4": 1,
	"456fc468-17ab-11e6-9825-2f5dfdfdfc63": 4
}
```

## Removing IPs from a NIC

IP addresses can be removed from a NIC via several methods. To delete a single address:

```
DELETE /nics/:mac/ips/:ip
```

Or to just delete all of them from a NIC:

```
DELETE /nics/:mac/ips
```

Or, if moving to a subset, the NIC can be updated (`PUT /nics/:mac`) with a
payload that specifies the addresses to keep in the **ips** field:

```
{
	"ips": [ "fd00::a2c", "10.0.0.241", "192.168.2.75" ]
}
```

[RFD 11]: ../rfd/0011
