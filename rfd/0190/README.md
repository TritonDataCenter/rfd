---
authors: Nick Wilkens <nick.wilkens@mnxsolutions.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+190%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2026 MNX Cloud, Inc.
-->

# RFD 190 Triton bhyve Live Migration Architecture

## Problem Statement

Triton already has a migration control-plane model in VMAPI, CloudAPI,
CNAPI, and cn-agent.  It already knows how to represent a migration as
phased work, how to create a hidden target placeholder VM, and how to
record progress and final state.

What Triton does not yet have is a long-term architecture for live
migration of bhyve VMs.

For bhyve live migration we must solve problems in several layers at the
same time:

- how a destination bhyve is created and prepared;
- how memory, kernel state, and device state move between CNs;
- how ZFS send and receive are orchestrated without violating bhyve's
  assumptions about disk devices;
- how Triton decides where a VM may migrate and how it records that
  work;
- how failure and rollback behave;
- how the entire data plane is secured on an untrusted admin network.

This RFD proposes the long-term architecture for those pieces.

The central recommendation is:

- preserve Triton's existing migration phases and records;
- create destination migration targets through `vmadm` and normal Triton
  provisioning logic;
- add bhyve-specific live migration support in bhyve itself;
- use a dedicated per-CN Global Zone migration service,
  `vmm-migrate-agent`, as the local data plane and remote transport
  endpoint.

## Goals

- Provide live migration for bhyve VMs with a short cutover window.
- Keep one customer-visible machine identity throughout migration.
- Reuse Triton's phased migration model:
  `begin`, `sync`, `switch`, `rollback`, `finalize`, and `abort`.
- Build destination migration targets through the normal `vmadm` and
  Triton provisioning path.
- Treat the admin network as untrusted and secure the remote migration
  transport accordingly.
- Preserve clear failure and rollback semantics.
- Keep VMAPI as the authoritative record of migration state and audit.
- Keep long-running data plane work out of VMAPI and mostly out of
  cn-agent.

## Non-goals

- Introducing live migration for every brand in the same project.
- Supporting passthrough PCI devices in the first bhyve live migration
  release.
- Supporting migration between incompatible platform images or CPU
  feature sets.
- Treating any current prototype transport detail as fixed forever.

## Existing Triton Context

Before describing the bhyve-specific pieces, it is worth spelling out
what Triton already has and should continue to use.

Today Triton already has:

- migration records in VMAPI;
- public migration actions in CloudAPI and VMAPI;
- a hidden target placeholder model using `do_not_inventory=true` and
  `vm_migration_target=true`;
- CNAPI's per-server migration endpoint;
- cn-agent tasks that execute migration-related work on compute nodes.

These are important existing building blocks.  The bhyve live migration
solution should extend this model rather than invent a second, unrelated
migration architecture.

## Design Principles And Constraints

### VMAPI owns orchestration and durable state

VMAPI should remain the source of truth for:

- whether a migration exists;
- which phase it is in;
- which side is primary;
- whether rollback is still possible;
- who initiated the migration;
- what the safe next operator action is.

### A migration is one VM, not two customer-visible VMs

The destination side may exist internally as a hidden target placeholder,
but there must not be a second customer-visible VM during migration.

### Destination preparation must use `vmadm`

The destination migration target should be built as a `vmadm` created
machine, not as a hand-built zone and not as an ad hoc remote shell
sequence.

This gives us:

- the same validation path as normal creation;
- the same representation of disks, NICs, metadata, and brand state;
- a familiar and debuggable lifecycle;
- a destination that naturally stays compatible with future Triton VM
  creation changes.

### Cross-host transport belongs in a CN-local service

`vmadm` is a local lifecycle tool.  bhyve is a local hypervisor.  The
cross-host migration data plane should be owned by a dedicated service
that can manage transport security, framing, retries, quotas, and audit.

### Compatibility must be checked before moving data

Live migration requires compatibility across at least:

- bhyve migration ABI or snapshot format;
- platform image behavior;
- CPU features;
- device model support;
- storage layout and capacity;
- migration agent capabilities.

This must be checked before `begin` performs meaningful work.

### At most one active network-visible copy

At all times, the system must enforce that at most one copy of the VM is
running and network-visible as the authoritative instance.

### Rollback remains possible until finalize

`switch` should not destroy the source-side rollback point.  `finalize`
is the operation that commits the new placement permanently.

### The admin network is untrusted

The remote migration interface must be encrypted, authenticated, and
authorized.  "Peer can connect to a TCP port" is not authorization.

## Recommended Solution Overview

The recommended solution has four major layers:

1. Triton keeps the existing phased migration control plane.
2. `vmadm` and `VM.js` gain explicit support for bhyve migration
   targets and bhyve listen-mode startup.
3. bhyve gains the hypervisor-side primitives required to export, import,
   pause, and resume a migrated VM.
4. A new per-CN Global Zone service, `vmm-migrate-agent`, owns the
   bhyve live migration data plane and the remote authenticated
   transport between CNs.

The rest of this RFD describes those pieces in detail.

## Triton Control Plane

### Preserve the existing migration phases

The public migration model should remain the existing Triton model:

- `estimate`
- `begin`
- `sync`
- `switch`
- `rollback`
- `finalize`
- `abort`

This keeps existing tooling, operator workflows, and migration records
aligned across brands, while allowing the bhyve implementation behind
those phases to differ from older migration implementations.

### Preserve the hidden target placeholder model

On `begin`, VMAPI should provision a hidden target placeholder on the
destination CN using the same internal pattern Triton already uses for
migration:

- the same VM UUID as the source VM;
- `do_not_inventory=true`;
- `vm_migration_target=true`;
- `autoboot=false`.

This model is already a good fit for bhyve live migration because it
provides:

- a durable Triton object to represent the destination;
- a place to validate compute, storage, and network resources;
- a rollback artifact that can exist before `finalize`;
- no second customer-visible VM.

### Extend migration records, do not replace them

VMAPI migration records should remain authoritative.  For bhyve live
migration they should grow additional implementation detail where useful,
for example:

- migration driver or mechanism version;
- source and target server UUIDs;
- an optional inner phase within `switch`;
- byte counters and ETA information;
- captured compatibility information.

CloudAPI and VMAPI should continue to expose the same conceptual phases,
while becoming more expressive about progress within those phases.

## `vmadm` And Destination Target Preparation

### Why `vmadm` should be the building block

The destination side of a bhyve live migration should be a `vmadm`
created machine because that lets us:

- validate the destination through the same path as a normal create;
- use the same zone and disk representation as a normal bhyve VM;
- keep future create-time validation changes automatically relevant to
  migration targets;
- debug migration targets using familiar tooling.

This is a better long-term contract than constructing a destination VM
through custom remote shell logic.

### Proposed `vmadm` behavior

This RFD recommends that `vmadm` and `VM.js` grow an explicit
migration-target mode.  The exact CLI or payload property names are left
open here, but the semantics should be:

- validate the payload as a normal bhyve creation;
- create the zone configuration, metadata, SMF state, and disk or
  dataset layout expected for the final VM;
- skip guest-side first-boot behavior that assumes the image is about to
  boot normally;
- create a hidden target that is safe to destroy and recreate on failed
  `begin` or `abort`.

This is intentionally close to `vmadm receive`, but it is not the same
thing.  `receive` is an offline import primitive for a stopped VM.
Live migration needs a destination that Triton itself created, validated,
and can later start in a bhyve listen mode.

### Proposed bhyve target startup path

This RFD also recommends an explicit startup path for a destination
migration target at the `vmadm` and bhyve brand layer.  The exact
interface is left open here; the important semantics are:

- start bhyve far enough that it can accept imported guest state;
- do not perform the normal guest boot path;
- do not reset guest registers and state that are about to be imported;
- make the resulting bhyve process wait for the migration data plane to
  deliver the guest state.

One reasonable way to express that is as a dedicated lifecycle
operation of the bhyve brand and `vmadm`, but that is a recommendation
rather than a settled interface detail.

## Proposed bhyve Work

To make bhyve live migration possible, the hypervisor side needs several
explicit capabilities.  This RFD recommends them as part of the design,
regardless of what prototype code may already exist.

### 1. A private bhyve control socket

bhyve should expose a private control socket inside the guest zone.  The
intended local caller is the Global Zone migration service.

That control socket should support operations like:

- query status;
- pause the VM;
- resume the VM;
- export bhyve and kernel-side guest state;
- import bhyve and kernel-side guest state.

The control socket is not the remote migration interface.  It is a local
private interface between bhyve and the local migration agent.

### 2. Export and import of guest state

bhyve needs a way to export and import the state that is not represented
by disk synchronization alone.  That includes at least:

- relevant kernel-side VM state;
- bhyve userspace device state;
- per-vCPU state;
- timing state needed for correct resume.

The precise wire format is a private implementation detail, but it must
be versioned, bounded, and validated.

### 3. Destination listen mode

The destination bhyve needs a startup mode where it does not boot the
guest in the normal way.  Instead, it should:

- initialize enough local bhyve and VMM state to accept imported guest
  state;
- avoid clobbering the imported state by running a normal reset path;
- block until the local migration agent imports the migrated state.

This is the bhyve-side half of the `vmadm start` migration-target path
described above.

### 4. Device hibernate and wake behavior

The destination side must sometimes release backing storage handles so
that the final `zfs recv` can complete cleanly before state import and
resume.

That means bhyve device layers need a way to:

- pause device activity;
- release storage handles where appropriate;
- reopen those handles once the final synchronized storage state is in
  place;
- then resume device operation.

### 5. Dirty-page tracking

Live migration needs dirty-page tracking so that memory transfer can be
optimized beyond a single all-or-nothing copy at cutover.  Even if the
first production release starts conservatively, the hypervisor-side
design should assume dirty tracking is part of the long-term solution.

### 6. Strong validation on import

The destination host is importing guest-derived state.  bhyve must treat
that as hostile input and validate it accordingly.  The import path is a
security boundary.

## Proposed `vmm-migrate-agent`

### Why a dedicated service is the right boundary

bhyve live migration needs a component on each CN that can:

- talk to `/dev/vmm`;
- talk to the bhyve control socket;
- talk to ZFS;
- maintain a remote transport session to a peer CN;
- survive a single RPC round-trip;
- emit metrics and structured logs;
- expose a small local API to cn-agent and local admin tools.

This is not a natural fit for VMAPI.  It is also not a great long-term
fit for long-running cn-agent child processes.  A dedicated per-CN
service is the correct boundary.

This RFD proposes that service be `vmm-migrate-agent`.

### Local responsibilities

The local migration agent should own:

- local interaction with `/dev/vmm`;
- local interaction with bhyve's control socket;
- RAM transfer logic;
- bhyve state transfer logic;
- disk synchronization transport orchestration;
- transport metrics and detailed logging;
- a root-only local Unix socket API.

`cn-agent` remains the task broker and privileged local caller.  It
should drive the agent, not reimplement the migration protocol.

### Remote responsibilities

The remote agent-to-agent interface should own:

- remote authentication and authorization;
- encryption;
- framing and multiplexing;
- negotiation of migration parameters;
- remote delivery of ZFS, RAM, and state streams;
- remote cutover coordination.

The long-term contract should not be "ssh as root and run a shell
pipeline".  That is acceptable for exploration, but it is not the
steady-state Triton architecture.

### Local API

The local API should be narrow and phase-oriented.  It should allow
cn-agent or local admin tooling to request operations such as:

- estimate;
- begin;
- sync;
- switch;
- rollback;
- finalize;
- status.

This API should live on a local Unix socket and be restricted to
privileged callers.

### Remote transport

The underlying transport may use WebSocket or another framing layer, but
the architecture should treat transport as an implementation detail of
the agent-to-agent protocol.  The important part is:

- mutual authentication;
- explicit authorization for a particular migration;
- auditability;
- support for carrying both control and bulk data cleanly.

If one underlying session is used for multiple kinds of data, the design
should plan for multiplexed streams or equivalent separation so bulk
storage traffic does not block latency-sensitive control and cutover
traffic.

## Storage Transfer

### Keep ZFS native semantics

For bhyve migration, ZFS send and receive remains the right logical unit
for disk state synchronization.  The architecture should preserve native
ZFS semantics such as:

- full and incremental sends;
- stream validation;
- resumability.

### Integrate storage transfer into the agent

The question is not whether to stop using ZFS send and receive.  The
question is where orchestration of that work belongs.

This RFD recommends that disk synchronization be orchestrated by
`vmm-migrate-agent`, not by external ssh glue.  That means the agent
should:

- know which datasets belong to the migrating VM;
- perform full and incremental synchronization as part of `begin` and
  `sync`;
- coordinate the final synchronized storage state needed for `switch`;
- eventually support resumable transfer behavior for large disks or
  interrupted links.

### Use a migration manifest, not just naming conventions

The migration agent should operate from a validated manifest derived from
local VM state.  It should not depend forever on hard-coded dataset
names.  This is especially important as bhyve disk layouts evolve.

## Phase Behavior

### `begin`

`begin` should:

- create the hidden target placeholder on the destination CN;
- validate that source and destination are compatible;
- perform a full initial storage synchronization;
- create the migration record if it does not already exist.

The source VM remains running.

### `sync`

`sync` should:

- perform one incremental storage synchronization pass;
- be safely repeatable;
- leave the source VM running;
- move the target closer to cutover readiness.

### `switch`

`switch` is the critical phase.  The long-term order should be:

1. ensure the target placeholder exists and is storage-synchronized;
2. start destination bhyve in migration-listen mode;
3. reserve or confirm network ownership for cutover;
4. pause the source guest;
5. run the final storage synchronization;
6. transfer memory and bhyve state;
7. hide or stop the source as the active instance;
8. resume the destination as the active instance;
9. update the authoritative Triton record to the new server UUID.

The key invariant is that there must never be two active network-visible
copies of the VM.

### `rollback`

`rollback` should remain meaningful after a successful `switch` and
before `finalize`.  That means the source-side rollback artifact must
still exist until `finalize`.

### `finalize`

`finalize` should:

- remove the rollback artifact on the source side;
- remove migration snapshots and temporary migration state;
- commit the new placement as final.

`finalize` is the point of no return, not `switch`.

## Failure Handling

Failure handling is part of the architecture, not a follow-up task.

The system should guarantee:

- `begin` and `sync` are idempotent or restartable;
- failure before destination resume prefers resuming or preserving the
  source and cleaning up the destination;
- a successful `switch` does not require manual operator cleanup to
  avoid split-brain;
- the migration record always states which side is authoritative and
  whether rollback remains possible.

Manual `vmadm stop` of the source as a normal part of the long-term
contract is not sufficient.  The system should do the right thing as
part of the workflow.

## Compatibility And Placement

CNAPI and VMAPI should only place bhyve live migration targets on CNs
that advertise compatibility with the source VM.

That capability set should include at least:

- bhyve migration ABI or snapshot format compatibility;
- platform image compatibility;
- CPU feature compatibility for the VM's configured virtual CPU model;
- required device-model support;
- storage pool availability and capacity;
- `vmm-migrate-agent` version or capability.

Live migration should also explicitly reject unsupported device classes,
such as passthrough PCI.

This compatibility information belongs in CN inventory and scheduling.
It should not first be discovered after `begin` has already moved data.

## Observability And Audit

Live migration is operationally sensitive.  The architecture should
include:

- structured migration logs on each CN;
- migration metrics at the local migration agent;
- progress history and inner-phase reporting in VMAPI watch output;
- byte counters, ETA, and failure reason reporting;
- durable audit information on who initiated the migration and which CNs
  participated.

## User And Operator Interaction

### Operators

Operators should continue to use the existing Triton migration model.
The mechanism behind the phases changes for bhyve, but the operator
contract remains:

- estimate;
- begin;
- sync;
- switch;
- rollback;
- finalize;
- abort.

### Users

If user-initiated migration remains allowed, it should continue to be
gated through existing VMAPI policy such as `user_migration_allowed`.
The shift to live migration does not require a new policy model.

### Local administration

`vmadm` should gain enough local support to create and start bhyve
migration targets, but these interfaces are primarily platform-internal
and operator debugging tools.  The primary Triton contract remains the
existing migration API model.

## Public Interfaces That Change

- CloudAPI migration endpoints can remain the same, but migration
  status and watch output should expose richer live migration progress
  detail.
- VMAPI migration estimate for bhyve should account for both storage
  transfer and memory or state transfer.
- VMAPI migration objects may need additional fields for bhyve live
  migration, such as inner phase, byte counters, or implementation
  driver.
- Triton may need a way to expose migration capability or eligibility
  for a given bhyve VM or target CN.
- No tenant-visible second VM should appear during migration.

## Private Interfaces That Change

- `vmadm` and `VM.js` gain bhyve migration-target creation support.
- `vmadm start` and the bhyve brand gain a supported migration-listen
  startup path.
- bhyve gains a private control socket contract for live migration.
- `vmm-migrate-agent` gains a stable local API used by cn-agent and, if
  useful, local admin tooling.
- CNAPI migration task payloads and CN inventory need to carry
  migration-driver and compatibility information.
- VMAPI workflows for bhyve migration should call the local migration
  agent on source and destination CNs rather than rely on older
  data-mover logic.

## Repositories Likely Affected

- `illumos-joyent`
- `smartos-live`
- `sdc-cn-agent`
- `sdc-cnapi`
- `sdc-vmapi`
- `sdc-cloudapi`
- `sdc-workflow` or `node-workflow`
- the eventual home and packaging of `vmm-migrate-agent`
- optional later CLI and portal consumers

## Upgrade Impact

- Live migration must be feature-gated until both source and target CNs
  are running compatible platform and agent versions.
- Compute nodes should be upgraded before headnode services start using
  the feature.
- A mixed-version fleet may continue to run bhyve VMs, but VMAPI must
  refuse live migration between incompatible nodes.
- Existing cold migration or send/receive behavior should continue to
  work.
- Non-migrating VMs should see no customer-visible behavior change.

## Security Impact

This design assumes the admin network is untrusted.

That means:

- the remote migration listener must require mutual authentication and
  explicit per-migration authorization;
- the steady-state transport should not depend on ssh root shell access;
- incoming manifests, stream sizes, phase transitions, and VM identity
  must be validated before touching `/dev/vmm`, bhyve state, or
  `zfs recv`;
- local control interfaces should remain Unix domain sockets restricted
  to privileged local callers;
- migration traffic should be attributable and auditable;
- the destination host is deserializing guest-derived state, so the
  bhyve import path remains a security boundary.

The attacker model is not just "malicious guest".  We must also assume a
malicious or compromised peer CN, or an attacker with visibility into
the admin network, attempting to inject migration traffic, replay a
previous migration, or cause the destination to import attacker-chosen
state.

## Implementation Plan

### Phase 0: define the contract

- define the compatibility and versioning story for bhyve live
  migration;
- document unsupported device classes and invariants;
- define success, failure, rollback, and finalize semantics.

### Phase 1: platform destination-target support

- add bhyve migration-target support to `vmadm` and `VM.js`;
- add a supported migration-listen start path for bhyve;
- package and SMF-enable `vmm-migrate-agent` on compute nodes;
- ensure the target placeholder can be created, started, stopped, and
  destroyed through normal platform tooling.

### Phase 2: CN-local agent integration

- teach `cn-agent` to drive the local migration agent;
- stop adding bhyve-specific complexity to older migration data movers;
- move remote coordination under the authenticated agent protocol.

### Phase 3: VMAPI and CNAPI orchestration

- reuse existing migration records and workflow phases for bhyve;
- add capability-aware target selection;
- add richer progress reporting and durable failure state;
- implement automatic source quiesce, rollback, and finalize semantics.

### Phase 4: public exposure

- wire CloudAPI and existing CLI tooling to the bhyve live migration
  driver;
- decide whether and when to allow user-initiated bhyve live
  migration.

### Phase 5: transport and scale improvements

- resumable ZFS transfer;
- multiplexed transport or equivalent channel separation;
- better ETA and throughput reporting;
- coverage for multi-disk, high-memory, and busy-guest workloads.

## Alternatives Considered

### Keep bhyve migration mostly inside cn-agent child processes

Rejected.  That repeats the older migration pattern and mixes durable
orchestration with long-running hypervisor and transport work in a place
that is not a good fit for it.

### Use `vmadm receive` as the live migration target primitive

Rejected.  `receive` is the right primitive for offline import, but it
is not the right abstraction for a hidden Triton migration target that
must be provisioned, validated, started in listen mode, rolled back, and
finalized through normal control-plane semantics.

### Keep ssh as the long-term remote control path

Rejected.  This does not match the required security posture for an
untrusted admin network and makes authorization and audit difficult to
reason about.

### Create a separate bhyve-only migration API

Rejected.  Triton already has migration records, phases, and workflows.
The bhyve mechanism should fit into that model.

## Open Questions

- Should `vmm-migrate-agent` live inside `smartos-live` packaging, or in
  a separate repo with its own release and packaging pipeline?
- What exact capability vector should CNs advertise for migration
  compatibility?
- Do we want one multiplexed agent-to-agent transport session, or
  separate authenticated channels for memory and ZFS streams?
- What is the precise platform mechanism for keeping destination NICs
  quiescent until cutover?
- How much rollback support must be present in the first
  operator-visible release?

## Related Work

- RFD 121 bhyve brand
- RFD 154 Flexible disk space for bhyve VMs
