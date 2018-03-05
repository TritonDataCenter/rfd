---
authors: Cody Mello <cody.mello@joyent.com>
state: predraft
---

# RFD 28 Improving syncing between Compute Nodes and NAPI

# Introduction

`net-agent`, the agent that lives on Compute Nodes and is responsible for
updating NAPI with changes to the NICs of VMs, currently only pushes information
one way. In order to support updating VMs after a network gets updated, it
should be extended to also pull information from NAPI.

An important consideration here is that `net-agent` should be able to catch up
with changes in the presence of a network partition or if the Compute Node goes
offline for an extended period of time.

# Syncing network changes to VMs

When a VM is created, it gains various properties based on which networks it is
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

- `vlan_id`
- `nic_tag`
- `mtu`

As part of [RFD 120], we will also want to push out updates to Router Objects,
so that net-agent can handle updating the router zones.

NAPI will distribute updates using [sdc-changefeed], which will allow it to
create and manage a stream of updates that can be consumed by net-agents. This
will allow a temporarily partitioned net-agent to catch up on recent changes when
it reconnects, and also allow it to react after being disconnected for a long
period of time by pulling down all networks again for its in-memory cache.

[net-agent] will subscribe to the changefeed using the instance identifier
`<cn uuid>/net-agent`.

# Syncing changes in VM NICs to NAPI

`net-agent` will currently sync changes to a NIC to NAPI, but there are some
edge cases that it doesn't handle particularly well: repeated failures to send a
NIC to NAPI will exponentially back off, for example, which can cause strange
ordering issues if later changes are successfully performed (such as deleting a
VM and then deleting its NICs in NAPI). Instead of backing off individual
updates, periodic syncs of unsynced NIC should be performed, so that an attempt
to resend an update can never come after a delete.

# Syncing Compute Node networking configuration to NAPI

CNAPI is currently responsible for syncing information about server NICs into
NAPI. This task is closer to what `net-agent` currently does, and should be
moved into it as part of this work. We can set up `net-agent` to watch for
sysevents produced by [sysinfo(1M)] indicating that its information has been
updated. This event-driven approach will help us keep more accurate information
about the current state of Compute Nodes, versus the current polling approach.
Since we will need to add sysevents for this, `net-agent` will need to also
support a mode where it periodically checks for changes on platforms lacking
support.

What we will probably not do as part of this work is reflecting changes made in
NAPI to GZ NICs on the CN. The global zone NIC configuration is currently all
set up during boot. At some point we may want to pursue a way for this
information to be refreshed without reboots, but that should probably be done
in a separate RFD.

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

[sysinfo(1M)]: https://smartos.org/man/1M/sysinfo
[net-agent]: https://github.com/joyent/sdc-net-agent/
[sdc-changefeed]: https://github.com/joyent/node-sdc-changefeed/
[RFD 120]: ../0120
