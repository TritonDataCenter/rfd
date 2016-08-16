---
authors: Nick Zivkovic <nick.zivkovic@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent Inc.
-->

# RFD 58 Moving Net-Agent Forward


## Background

In Triton the CNs are usually the source of truth, and this truth must
eventually be reflected in the data returned by our APIs (VMAPI, NAPI, etc).
Eventual consistency of this metadata is a goal in Triton, and some changes
need to be made to net-agent to bring us closer to this goal. There are
situations in which the database (Moray) is the source of truth. For example
this is true for higher-level objects such as the `network` object that NAPI
creates.

When a VM is deleted through CloudAPI or VMAPI, a workflow job is created that
destroys the VM and its dependent data such as the NICs that were used by it.
However, if a VM is deleted through vmadm or zoneadm -- thereby circumventing
VMAPI -- net-agent detects that the VM has been removed from the CN and it
updates/destroys the NIC records in NAPI to reflect this.

The scope of net-agent's responsibilities is greater than simply destroying
NICs. Net-agent is responsible for updating any metadata in NAPI that needs to
be updated in order to make that metadata a more accurate reflection of the
reality on the CNs that are managed by Triton. When this is not done,
inconsistencies arise between the figurative map and territory. Currently,
net-agent is responsible for the NIC-object that gets stored in Moray. However,
it may have to manage other/new networking related objects in the future.

Net-agent previously had a minor defect in which it would -- under certain
conditions -- not detect removals of VMs through the `vmadm` interface, and
would thus not destroy the NICs that used to belong to the VMs. This resulted
in the leaking of NIC objects. As a result, the agent had to be modified to
both (a) always detect removals of VMs and (b) reap the NICs that have been
orphaned by the previous incarnation of the agent. See [NAPI-327].

Regardless of the source of the inconsistency between the metadata and the
state on the CN, the agent must always bring them into sync. In the following
section we enumerate various parts of the networking-related metadata that may
be out of sync with the CNs' aggregate state, and propose how net-agent should
bring these things back into sync.

## Sources of Inconsistencies

There are, broadly, two main sources of inconsistencies as you can see below.
See the next section for an enumeration of how we can improve net-agent's
ability to detect and handle inconsistencies from these sources.

### (Changes to) Component Behavior

As mentioned before, a change to a component can result in an inconsistency of
state, even if the change itself is flawless. For example, NAPI has been
modified to store the UUID of the CN in the NIC object through a new `cn_uuid`
property. NAPI (correctly) only did this for newly created NICs, leaving the
old ones without the new property. To do otherwise would cost too much in terms
of performance. For NAPI to backfill the `cn_uuid` onto old NICs, NAPI would
have to do a scan over all of the NICs in the DC, lookup what CN it's
associated VM is on (by making a request to VMAPI), and set the `cn_uuid`
property of the NIC to the value of the CN's UUID. The root of the problem of
putting NAPI in charge of backfilling the `cn_uuid` property would put more
load on the head-node's CPUs, its VNICs, and on VMAPI. Net-agent is the optimal
place to put this functionality (see the Backfill section below), as that would
put no extra load on any of our services on the head node, and would allow part
of the backfill process to scale with the number of CNs.

Another example in which a component's behavior may put the system in an
inconsistent state, is when a component creates a NIC (the default state is
`provisioning`), but forgets to update the state to `running`. VMAPI always
does this update, while `sdcadm` does not. As a result NICs created by the
latter end up stuck in `provisioning`. Net-agent should detect that this has
happened and should sync up the state by changing it to `running`.


### Use of System Level Tools

The use of Triton's system-level tools (like `vmadm`) is supported because
operators may need to do things that are not currently possible using the
Triton APIs, but absolutely _must_ be done. A prominent example of this kind of
necessary task is migrations (currently unimplemented, see [RFD 34]).

System-level tools can empower anyone to arbitrarily change any state on the
system. The agents should try to detect common side-effects that would result
from the use of these tools (such as the disappearance of a VM due to the use
of `zoneadm`). While agents can detect and react to simple side-effects such as
VM disappearance, they can't infer intent. This means that scripts that combine
a lot of these tools, and make changes that are not local to a single CN,
should be as well behaved as possible.

For example, in the case of migrations, it is imperative to disable net-agent
on the destination node. The reason is that the agents are oblivous to each
other, and not doing this would create a race between the source-agent and the
destination-agent because they both think they own the NICs of the VM that is
being migrated. At first glance, it may seem that the `do_not_inventory` member
would tell the agents to leave the NIC alone. However, it cannot be used in
this capacity, because there is some latency from the point time when we set
`do_not_inventory`in the store, and the poin in time when net-agent updates its
view of the world via a `sendFullSample()` call. It is during this window, that
net-agent can change/destroy a NIC that does not belong to it, specifically if
it begins its reap-routine in this window.

## Improving Net Agent

In this section we will enumerate the changes that need to be made to net-agent
and peripheral components, to get Triton closer to its goal of eventual
consistency.

### Reaping

As mentioned above, net-agent has to reap the NICs that have been leaked by
previous incarnations of net-agent. There are many ways to achieve this, but
the most straightforward is to query NAPI for a list of all NICs that are
associated with the agent's CN, and to make sure that each NIC's
`belongs_to_uuid` points to a VM that is present on the CN. If not, we reap the
NIC. This query only needs to be executed once when net-agent starts up. After
the initial reap, net-agent will discard the list it obtained from NAPI, and
will properly react to VM-events (all obtained from a child `zoneevent`
process's stdout), and destroy NICs on the fly. The only exception to this
on-the-fly destruction, is if a VM-event gets dropped (`zoneevent` can drop
events under high system load). If this happens, net-agent will run `vmadm
lookup` (at some long, pre-determined interval) on its set of VMs and will
compare all the metadate of the VMs on the CN to the metadata it keeps in
memory. If there is a difference it will react to that difference. In other
words, net-agent _will_ react to all VM-related changes, within some amount of
time. This is situation is logically equivalent to having a single VM-event
source that _never_ drops events but delivers them in batches every `T` units
of time in random order. This in no way hinders net-agent's ability to maintain
eventual consistency of the NIC objects in Moray.

But back to the reaping procedure. Net-agent will have a random delay in the
range of 2 to 10 minutes, before initiating the query and subsequent reap. This
is so that the agents don't try to query NAPI at the same exact time, as that
could overwhelm NAPI.

Furthermore, some changes need to be made to NAPI. Currently, NAPI's `/nics`
endpoint does not support filtering NICs by `cn_uuid`. While net-agent _could_
filter through this list of NICs on its own, this approach is very wasteful
of the available bandwidth that could be utilized for other purposes. In large
data centers with many CNs, NAPI would be sending a list of all the NICs in the
DC to each and every CN.

While this filtering support needs to be in the `/nics` endpoint, we will also
need to create a new `/search/nics` endpoint which is an alias to `/nics`. The
reason for this seemingly redundant endpoint is that NAPI previously did not do
any strict-checking on the properties we were filtering by. In other words,
older version of NAPI would only filter by recognized properties. For instance,
`/nics?cn_uuid=$UUID` would return a list of all the NICs in the datacenter. By
making `/search/nics` an alias for `/nics`, we gain the ability to determine if
NAPI can filter by `cn_uuid`. If we try to query using `/search/nics` and
`cn_uuid` filtering is not supported, we will get a 404. In the event that
net-agent gets a 404, it will backoff for a very long time (on the order of
hours). If NAPI gets updated to the most recent version, net-agent will reap
the NICs successfully when the backoff-timer hits zero.

Note, also, that `node-sdc-clients` will need to get support for this new
endpoint.

See [NAPI-327], [NAPI-360], and [NAPI-347] for more details. [NAPI-327]
describes the net-agent related changes, [NAPI-360] describes the
implementation of the new endpoint, and [NAPI-347] adds, among other things,
the ability for the old endpoint to filter by `cn_uuid`.


### Backfill

Net-agent should detect NICs that lack a `cn_uuid` property and set that
property. This can be done as part of the reaping procedure. We use the
`/search/nics` endpoint to load all of the NICs that are within net-agent's
purview and have a `cn_uuid` set. We can then use `node-vmadm` to get a list of
NICs that are on the CN itself. Any NIC that is in the latter list but not in
the former list, is missing a `cn_uuid`, which should be set. Once this is
done, we should add the NICs in the latter list to the former list, and get rid
of the latter list. This way, when we begin a reap we will reap all the NICs
that need to be reaped, even those that lacked a `cn_uuid`. In other words, we
carry out the backfill before the reap.


### NIC States

Some NICs end up stranded in the `provisioning` state. We update these NICs'
states as part of the VM-event code path. Whenever net-agent detects that a
VM-event has occured, it can fetch the VM's NICs from NAPI (the MAC addresses
are stored in the VM's `nics` array). We check if any NIC has the state set to
`provisioning`. If so, we set it to `running`. This method, however, only works
for NICs that belong to VMs (`belongs_to_type` is set to `zone`). We do this as
part of the VM-event code-path instead of the reaping code-path because we know
that if we get a VM-event, then the VM is running, and the NIC _should_ be in
the running state as well.

If the `belongs_to_type` is set to `server` or `other`, we will need to update
the state on startup in the same way that we reap the NICs on startup. So the
startup path will be responsible for both reaping, and for moving the state of
non-zone NICs from `provisioning` to `running` for non-zone NICs.

## Relationship Between Net-Agent and VMAPI

Currently, VMAPI removes a VM's NIC as part of the destroy workflow. A ticket,
[ZAPI-725], has been opened requesting to remove this functionality as it is
redundant with net-agent's functionality. This approach is not tenable because
agents can, in theory, be downgraded. If [ZAPI-725] got put back, and net-agent
was downgraded to the leaky version, we would leak NICs on _every_ VM
destruction not just those initiated by system-level tools.

In general, net-agent needs to understand the relationship between VMs and
NICs. Thus it needs to read data from both VMAPI and NAPI. However it only has
the authority to change networking-related objects (except for firewall rules,
which is in the jurisdiction of firewaller-agent), like NICs.

## User Impact

None.

## Security Impact

None.

## Upgrade Impact

Some improvements will not work if a sufficiently recent version of NAPI is not
on the system. However, net-agent will continue to react to VM events and
modify NIC-state accordingly.

## Interfaces Affected

Some new interfaces are added to net-agent, NAPI, and the sdc-clients module.
All interfaces remain backwards compatible.

## Repositories Affected

`sdc-napi`, `sdc-net-agent`, `node-sdc-clients`.

<!-- Issue Links -->
[NAPI-327]: https://smartos.org/bugview/NAPI-327
[NAPI-360]: https://smartos.org/bugview/NAPI-360
[NAPI-347]: https://smartos.org/bugview/NAPI-347
[ZAPI-725]: https://smartos.org/bugview/ZAPI-725

<!-- RFDs -->
[RFD 34]: ../rfd/0034
