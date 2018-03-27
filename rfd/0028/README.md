---
authors: Cody Mello <cody.mello@joyent.com>
state: predraft
---

# RFD 28 Improving syncing between Compute Nodes and NAPI

# Introduction

When a Triton installation is first set up, all of the service zones are
assigned IP addresses by the installation script and MAC addresses by
[vmadm(1M)]. In order to make sure this information makes its way into NAPI
(as well as any action taken by an operator on a CN outside of the normal APIs)
we deploy a service, `net-agent`, into each node's global zone.

Today, `net-agent` only propagates information in one direction. When VM state
or NIC properties change locally, `net-agent` takes care of making sure they
get reflected in NAPI. When networking properties that are controlled by NAPI
(such as a network's gateway) change, however, we don't take care of pushing
them down to Compute Nodes. When operators and users want to change these
properties today, they need to either manually update all existing instances
or create new instances for exclusive use that will pick up the new properties.

An important consideration here is that `net-agent` should be able to catch up
with changes in the presence of a network partition or if the Compute Node goes
offline for an extended period of time.

# Syncing network changes to VMs

When a VM is created, it gains properties based on which networks it is
placed on, such as `resolvers` and `nics.*.gateways`. Once the VM is created
however, if the network is later updated (i.e. to change a gateway), existing VMs
will never get updated and discover the new gateway. We should sync these
network properties when they change and update the local VMs to make use of
them. Important properties on networks to watch are:

- `gateway`
- `routes`
- `resolvers`

We may also want to consider allowing and processing updates to currently immutable
fields like:


As part of [RFD 120], we will also want to push out updates to Router Objects,
so that net-agent can handle updating the router zones.

NAPI will distribute updates using [sdc-changefeed], which will allow it to
create and manage a stream of updates that can be consumed by net-agents. This
will allow a temporarily partitioned net-agent to catch up on recent changes when
it reconnects, and also allow it to react after being disconnected for a long
period of time by pulling down all networks again for its in-memory cache.

[net-agent] will subscribe to the changefeed using its SAPI instance UUID as
its listener identifier.

# Syncing changes in NAPI NICs to VMs

The following properties should be synced to the local NICs based on NAPI
state:

- `allow_ip_spoofing`
- `allow_mac_spoofing`
- `allow_dhcp_spoofing`
- `allow_restricted_traffic`
- `allow_unfiltered_promisc`
- `model`

The following properties come from networks and are currently immutable, but
we'll check and correct for differences between what's in the NIC received from
NAPI and what's on the local CN to make any future work easier:

- `vlan_id`
- `nic_tag`
- `mtu`

# Syncing changes in VM NICs to NAPI

`net-agent` will currently sync changes to a NIC to NAPI, but there are some
edge cases that it doesn't handle particularly well: repeated failures to send a
NIC to NAPI will exponentially back off, for example, which can cause strange
ordering issues if later changes are successfully performed (such as deleting a
VM and then deleting its NICs in NAPI). Instead of backing off individual
updates, periodic syncs of unsynced NIC should be performed, so that an attempt
to resend an update can never come after a delete.

The following NIC properties should be synced to NAPI based on local state:

- `belongs_to_type` (set to `"zone"`)
- `belongs_to_uuid`
- `owner_uuid`
- `primary`
- `state`
- `cn_uuid`

# Syncing Compute Node NICs to NAPI

CNAPI is currently responsible for syncing information about server NICs into
NAPI. This task is closer to what `net-agent` currently does, and should be
moved into it as part of this work. We can set up `net-agent` to watch for
sysevents produced by [sysinfo(1M)] indicating that its information has been
updated. This event-driven approach will help us keep more accurate information
about the current state of Compute Nodes, versus the current polling approach.
Since we will need to add sysevents for this, `net-agent` will need to also
support a mode where it periodically checks for changes on platforms lacking
support.

We will want to make sure we update NAPI with the following properties:

- `belongs_to_type` (set to `"server"`)
- `belongs_to_uuid`
- `owner_uuid`
- `state` (this will fix [TRITON-253])

As part of this work we will not be reflecting most changes made in NAPI to GZ
NICs on the CN, with one exception: we will take care of propagating
`nic_tags_provided` updates from NAPI to the CN.

We'll avoid other kinds of updates (adding NICs, IPs, etc.) since the global
zone NIC configuration is currently all set up during boot, and we'll probably
want to improve the way it's managed to make it easier for `net-agent` to
cooperate with the network startup scripts.That work should be done in a
separate RFD.

# Enforce updating via NAPI

To ensure updates are applied consistently and correctly, VMAPI should prevent
updates to the following fields, which are network-wide properties:

- `nic.*.gateways`
- `nic.*.netmask`
- `nic.*.vlan_id`
- `nic.*.nic_tag`
- `resolvers`
- `routes`

Attempts to update these properties should fail with an error informing the user
to use NAPI to update them instead. Updating `nic.*.ips` should be allowed via
VMAPI, since it feels like the more obvious place to do so to a user, but doing so
should be equivalent to making a call out to NAPI.

[vmadm(1M)]: https://smartos.org/man/1M/vmadm
[sysinfo(1M)]: https://smartos.org/man/1M/sysinfo
[net-agent]: https://github.com/joyent/sdc-net-agent/
[sdc-changefeed]: https://github.com/joyent/node-sdc-changefeed/
[RFD 120]: ../0120
[TRITON-253]: https://smartos.org/bugview/TRITON-253
