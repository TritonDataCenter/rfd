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
- how the entire data plane is secured.

This RFD proposes the long-term architecture for those pieces.

The central recommendations are:

- preserve Triton's existing migration phases and records;
- create destination migration targets through `vmadm` and normal Triton
  provisioning logic;
- add bhyve-specific live migration support in bhyve itself;
- concentrate the CN-local data plane (RAM transfer, bhyve control,
  ZFS orchestration, authenticated cross-CN transport) in a single
  well-defined component per CN.

Where that CN-local component lives is deliberately left open in this
RFD.  The "CN-Local Migration Data Plane" section describes its
requirements.  The packaging question (standalone service, cn-agent
extension, or something else) is one of the primary open questions
this RFD is seeking feedback on.

## Goals

- Provide live migration for bhyve VMs with a short cutover window.
- Keep one customer-visible machine identity throughout migration.
- Reuse Triton's phased migration model:
  `begin`, `sync`, `switch`, `rollback`, `finalize`, and `abort`.
- Build destination migration targets through the normal `vmadm` and
  Triton provisioning path.
- Secure the remote migration transport with authentication,
  authorization, encryption, and audit.
- Preserve clear failure and rollback semantics.
- Keep VMAPI as the authoritative record of migration state and audit.
- Keep long-running data plane work out of VMAPI and mostly out of
  cn-agent.

## Non-goals

- Introducing live migration for every brand in the same project.
- Supporting passthrough PCI devices in the first bhyve live migration
  release.
- Supporting migration across incompatible bhyve ABI versions or
  between CPU generations with no overlap in architectural features.
  Migration across CPU feature sets that share a workable baseline is
  a goal.  See "CPU and Platform Compatibility" for the options being
  considered.
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

## Hard Requirements: What Must Move And Why

Before discussing who owns which piece of orchestration, it is worth being
explicit about what live migration actually requires at the hypervisor
level.  Every architectural decision downstream (protocol, phasing,
rollback semantics, compatibility matrix) exists to honor one of the
invariants in this section.  If a reviewer disagrees with an invariant
here, they should disagree with the solution built on top of it, not the
other way around.

### The core invariant

At any instant, a running VM is a deterministic state machine.  Its
"state" is the complete set of bytes and counters the guest software can
in principle observe: CPU registers, memory, device register files,
pending interrupts, clock readings.  Live migration must move that state
machine from source to destination such that, immediately after resume on
the destination, the guest's next observable step is the same as the next
observable step would have been on the source.

This gives us two derived obligations:

1. **Atomic capture.** All observable source state must be captured
   relative to a single quiesced instant.  Capturing memory first and
   then CPU registers later, while the guest is still running, produces
   an inconsistent snapshot even if the individual pieces are correct in
   isolation.  This is why `switch` has a pause boundary, and why
   everything that is not dirty-tracked memory must be captured inside
   that boundary.

2. **Translation of host-relative values.**  Several pieces of VM state
   are only meaningful relative to the host the VM was running on: the
   TSC offset, kernel hrtime anchors, re-armed timer deadlines, EPT/NPT
   page table physical addresses.  These cannot be copied verbatim; they
   must be translated into destination-host terms as part of import.
   Skipping that translation is the largest single source of "pings
   work, SSH hangs" class bugs in live migration.

The rest of this section enumerates the state categories that must be
moved and, for each, what makes it non-trivial.

### CPU and per-vCPU state

Each vCPU has a well-defined state vector that must migrate intact.
None of it can be safely regenerated on the destination.

**General-purpose registers.**  RAX through R15, RIP, RSP, RBP, RFLAGS.
These are opaque bytes; the guest chose them and the destination must
present them exactly.

**Control registers.**  CR0, CR2, CR3, CR4, XCR0, and EFER.  CR3 in
particular is the guest's top-level page table pointer; it refers into
guest physical memory, so as long as the destination presents the same
guest physical address space, CR3 can be copied verbatim.  CR0.PG, CR4
feature bits, and EFER.LMA collectively determine the mode the
destination CPU must enter (long mode, paging enabled, etc.) on the next
VM entry.  A missed bit causes an immediate VM-entry failure, not a
subtle later bug.  EFER in particular is worth calling out: it is
architecturally an MSR, but its role in gating long-mode means it must
be restored alongside the control registers rather than landing in the
general MSR transfer, and implementations should explicitly exclude it
from any enumeration-based MSR list to avoid double-restoration.  CR8
is not included here because its guest-visible value is the LAPIC Task
Priority Register; it moves with the LAPIC, not with the control
registers.

**Debug registers.**  DR0, DR1, DR2, DR3, DR6, DR7, plus the
`IA32_DEBUGCTL` MSR.  DEBUGCTL is strictly an MSR but belongs in the
same logical group as the debug registers; as with EFER, it should
transfer alongside the other debug state rather than be left to
whatever the MSR enumeration happens to include.  Must be preserved
for guests that use hardware debug features, even if most guests do
not.

**Segment descriptors and selectors.**  CS, DS, ES, FS, GS, SS, plus TR,
LDTR, GDTR, IDTR.  Each carries a base, limit, access rights word, and
for most segments a selector.  The selector and the descriptor cache are
both architecturally relevant; restoring base/limit/access is not
sufficient if the VMCS also expects the selector to match.  This is a
well-known migration trap (we hit it early as `VMX entry failure
inst_error=7`).

**Extended state: FPU, SSE, AVX, AVX-512, AMX.**  An XSAVE area
containing floating-point, vector, and supervisor-state components.
Its length is not a compile-time constant; it grows with each new
state component the CPU supports (AVX YMM hi128, AVX-512 opmask /
hi256 / hi16-zmm, AMX tile config and tile data).  Implementations
should query the required buffer size at runtime from the kernel
(via the equivalent of `VM_DESC_FPU_AREA`) rather than hardcode a
size that will silently truncate on future microarchitectures.  The
XSAVE area must also be compatible with the destination's supported
XCR0 feature bits; migrating an AVX-512 guest onto a host that does
not support AVX-512 is inherently unsafe and should be rejected up
front rather than discovered at first guest FPU use.

**Model-specific registers (MSRs).**  A non-exhaustive list of MSRs
whose value is guest-observable and must migrate:

- `MSR_STAR`, `MSR_LSTAR`, `MSR_CSTAR`, `MSR_SF_MASK` (syscall entry).
- `IA32_FS_BASE`, `IA32_GS_BASE`, `IA32_KERNEL_GS_BASE` (TLS pointers
  on Linux and Windows).
- `IA32_SYSENTER_CS/ESP/EIP` (legacy fast syscall).
- `IA32_PAT` (page attribute table, affects caching behavior).
- `IA32_APIC_BASE` (LAPIC mode and base address).
- `IA32_TSC_DEADLINE` (per-vCPU LAPIC timer deadline, in TSC ticks; see
  the clocks subsection for why this is treacherous).
- Variable-range and fixed-range MTRRs.

EFER and DEBUGCTL are architecturally MSRs but should transfer with
the control registers and debug registers respectively (see above).

The complete set of guest-observable MSRs is effectively defined by
the guest operating system, not by the hypervisor.  Implementations
that match MSRs against a hardcoded list in userspace silently drop
any MSR added to the kernel's data class later; implementations that
enumerate the MSR set from the kernel directly (read-all on the
kernel's MSR data class) absorb new kernel MSRs without userspace
ABI change.  The latter pattern is strongly preferred.

**Per-vCPU run state.**  RUNNING, HLT, WAITING_FOR_SIPI, SHUTDOWN,
plus the SIPI vector for APs still in the INIT/SIPI handshake.  For
a BSP that has started APs, the APs are in specific run states
determined by whether the guest has issued INIT/SIPI; these run
states and their associated SIPI vectors must migrate as a pair.
Restoring run state without the vector on an AP that has received
INIT but not yet SIPI produces a vCPU that will never start.  On
illumos-joyent bhyve this runs through `vm_set_run_state`.

**Pending injected events and interrupt shadow.**  Two distinct
pieces captured at pause instant, both of which must be re-injected
on the destination:

- **Pending events.**  Exceptions, NMIs, external interrupts, and
  intinfo captured at pause.  On illumos-joyent bhyve these surface
  as the `VAI_PEND_EXCP`, `VAI_PEND_NMI`, `VAI_PEND_EXTINT`, and
  `VAI_PEND_INTINFO` fields under the `VDC_VMM_ARCH` data class, and
  represent events the guest has not yet observed.  Dropping them is
  visible to guests as disappeared signals.
- **Interrupt shadow.**  The one-instruction VMX shadow window that
  follows `STI` and `MOV SS`, during which the CPU suppresses
  interrupt delivery.  Exposed via `VM_REG_GUEST_INTR_SHADOW`.
  Dropping the shadow on migration can cause the guest to take an
  interrupt one instruction earlier than it otherwise would, which
  on carefully-crafted guest critical sections can be visible as
  a bug.

Both require kernel support (illumos#15143 / bhyve API V10 on
modern kernels); older kernels must skip the import cleanly rather
than silently pretend it succeeded.

**TSC continuity.**  Each vCPU has a TSC that the guest treats as
monotonic within that vCPU and typically treats as roughly monotonic
across vCPUs.  The host TSC may differ between source and destination
CNs in both value and frequency.  The VMM must:

- preserve guest-observable TSC continuity (no backwards jumps; no
  visible gap larger than the pause window);
- rescale guest TSC if the destination's host TSC frequency differs,
  using hardware TSC scaling where available and rejecting migration
  where it is not;
- adjust the per-vCPU TSC offset on the destination so that the guest's
  next TSC read matches the monotonic expectation.

On illumos this is handled by the `VDC_VMM_TIME` class plus the
userspace `snapshot_vmm_time_merge` path, which rebases boot_hrtime,
rescales guest_tsc by the ratio of destination to source frequency, and
adds a delta for real wall-clock time spent in migration.

### Virtual interrupt controller state

Interrupt state is as important as CPU registers, and is more commonly
underestimated.

**LAPIC (per-vCPU).**  Every LAPIC register has a guest-observable
value that must migrate: ID, LDR, DFR (logical routing), SVR,
the LVT entries (timer, thermal, performance, LINT0, LINT1, error),
the timer initial/current/divide count, TPR, ESR, ISR/IRR/TMR bitmaps,
and the pending ICR.  The timer state is particularly subtle: the
guest's next scheduled timer fire must land at the right wall-clock
time on the destination, which means the hypervisor must store the
fire time in a host-independent form (hrtime-normalized) and re-arm
the host callout on resume.

The "LAPIC callout re-arm" path is a class of bug worth calling out
explicitly: on a paused VM, restoring LAPIC state does not actually
arm the hypervisor's timer callout; the callout is armed by the
subsequent VM-wide resume, which in turn requires the vCPU to be on
the active list at the moment of resume.  Any live migration
implementation must sequence these three steps correctly or it will
appear to succeed while silently starving the guest's timer IRQ.

**I/OAPIC.**  Twenty-four (on most configs) redirection table entries
mapping device IRQ lines to LAPIC vectors, delivery modes, destination
masks, and trigger modes.  The guest programmed these at boot; the
destination IOAPIC must present the same values or devices stop
delivering interrupts.

**Legacy 8259 (ATPIC).**  Still programmed by UEFI and legacy OS boot
code.  Must migrate for correctness on guests that fall back to legacy
PIC delivery in any code path.

**HPET.**  Counter value, per-comparator match registers and enable
bits, and a base_time anchor relative to the host's hrtime.  The
comparators drive guest timer delivery on some OSes; HPET state cannot
be reset on migration.  The base_time anchor is a host-relative
quantity and must be rebased on the destination.  Failing to rebase
produces "time jumped into the future" rejections at restore.

**ACPI PM timer (PMTMR).**  A 24- or 32-bit counter driven off the
power-management clock.  Some guests poll it for timing calibration.

**Virtual RTC (CMOS).**  64-ish bytes of CMOS state plus alarm
registers.  Migrates verbatim.  The guest wall-clock reading the RTC
gives will differ from the CN's wall-clock by however much host clocks
differ, but that is a guest-level NTP concern, not a migration bug.

### Guest physical memory

The guest's physical address space is the largest migratable state, but
conceptually the simplest: every byte the guest can read at a GPA must
be byte-identical on the destination immediately after resume.

Concrete implications:

- **Full coverage.** Every populated guest physical page must be
  transferred.  "Most pages" is not good enough; a single stale page in
  kernel text or page tables is a panic waiting to happen.
- **Dirty tracking is mandatory for acceptable downtime.**  Copying all
  of memory inside the pause window is only acceptable for very small
  VMs.  For any realistic size, memory must be transferred in a
  baseline pre-copy pass while the guest runs, followed by iterative
  dirty-only passes that converge, followed by a final dirty pass
  inside the pause window.
- **Device DMA must be reflected in dirty tracking.**  Virtio and viona
  write into guest RAM; if those writes bypass the EPT/NPT accessed/
  dirty bits, dirty tracking silently under-reports and the destination
  receives stale bytes for pages the guest believes are current.  The
  hypervisor must guarantee DMA writes go through paths that record
  dirtiness, or must drain devices to quiescence before the final RAM
  pass.
- **Zero-page detection is a latency optimization, not a correctness
  requirement.**  A migration protocol that does not detect zero pages
  still produces correct results; it just wastes bandwidth transferring
  them.

Page tables in host memory (EPT/NPT structures) are not part of guest
state; the destination kernel rebuilds them from the same GPAs using
its own physical page allocations.

### Device state

PCI devices and their backing resources carry a rich set of state that
must migrate.

**PCI configuration space.**  Vendor/device ID and subsystem fields are
static, but command register, status register, interrupt line, cache
line size, BAR values, capability list, MSI/MSI-X configuration tables,
and MSI-X pending bit array are all guest-writable and guest-observable.
The destination's PCI emulation must present the same config space
contents, because guest drivers have cached decisions based on reading
them.

**BAR registration.**  At boot the guest writes BAR addresses; the
hypervisor registered those addresses as its MMIO or I/O space
callbacks.  On migration, both the BAR values AND the MMIO/IOPort
callback registrations must be recreated on the destination.
Restoring only the config-space copy of the BAR is a common bug that
appears to work in trivial tests but breaks whenever the guest
accesses the device.

**Virtio device state.**  Per-device: negotiated feature bits, queue
sizes, queue base GPAs, queue enable bits, notify registers.
Per-queue: `last_avail_idx`, `last_used_idx` (or their in-ring
equivalents), and translation of in-ring guest pointers to host
addresses valid on the destination.

**viona (in-kernel virtio-net).**  Queue state is owned by the kernel
and must be exported via a per-device pause + snapshot path; the
destination must re-import the same queue state and then kick the
queue so that pending RX/TX descriptors drain.  MAC address and vnic
identity must be preserved at the dladm layer, not rediscovered.

**Block device backing.**  The zvol must be open on the destination
AND must contain the correct contents AND must match size, sector
size, and write-cache-enabled properties.  Any in-flight I/O at pause
instant must be either drained to completion before the snapshot blob
is taken, or explicitly recorded and re-submitted on resume.
In-flight writes not captured this way re-surface as silent data
corruption on the destination.

**The illumos-specific storage quirk.**  illumos rejects `zfs recv`
onto a dataset that is actively held open.  The destination bhyve
holds its zvol open for the entire migration-listen window, which
means the final incremental `zfs recv` cannot complete.  Either:

- the destination bhyve must release the fd before the final recv and
  reopen it after (the "hibernate/wake" pattern), or
- the hypervisor must use a filesystem primitive that allows
  concurrent open + recv (does not currently exist in illumos ZFS), or
- the order must be inverted so that the final recv completes before
  the destination bhyve opens the zvol (requires capturing all of
  memory and state before the destination bhyve exists, which breaks
  pre-copy).

The hibernate/wake option is the only one that preserves pre-copy
semantics on current illumos, and therefore drives requirements at
the bhyve device-layer level.

**fbuf, xhci, uart, nvme, hostbridge, LPC.**  Each has a per-device
state blob.  Devices that own backing file descriptors or host
kernel state need the equivalent of the block-device pause/hibernate/
wake discipline; devices that are pure userspace register
implementations are simpler and need only a register-file snapshot.

### Clocks and time

Time is where live migration most often goes wrong, and where the
smallest errors have the most visible symptoms.

The hypervisor must handle:

- **TSC value and frequency.**  Source and destination host TSCs
  differ.  Guest TSC must stay monotonic from the guest's point of
  view across the pause.  Hardware TSC scaling, where available,
  handles frequency differences; absence of TSC scaling on the
  destination must be a hard migration-incompatibility check, not a
  runtime surprise.
- **boot_hrtime / hrtime anchor.**  The kernel's notion of "how long
  the guest has been running" is expressed in host hrtime.  It must
  be rebased to the destination's hrtime clock on import.
- **Re-armed kernel callouts.**  Any VMM-internal callout (LAPIC
  timer, HPET comparator fire, VRTC alarm) whose fire time was
  expressed in source-host hrtime must be re-expressed in
  destination-host hrtime and the callout re-armed at the equivalent
  future instant.  Missing this is exactly the category of bug that
  produces "ping works, SSH hangs" because the kernel callout driving
  the guest's LAPIC timer IRQ was never scheduled.
- **Wall clock.**  The guest's view of wall clock comes from the RTC
  plus post-boot adjustments the guest made via NTP.  Cross-host
  wall-clock skew presents to the guest as NTP does; the migration
  agent should minimize the migration pause window but is not
  obligated to adjust the guest RTC.

A good test for "did we handle time correctly" is whether `uptime`
inside the guest is continuous across migration.  If it is, boot_hrtime
rebase worked.

### Storage

The guest's view of its block devices must remain byte-identical.

- **Full dataset coverage.**  Every zvol and delegated dataset
  belonging to the VM must reach the destination.
- **Incremental synchronization.**  ZFS native send/receive with
  incremental snapshots is the correct primitive.  Migration should
  not invent its own block-level transfer.
- **Consistency point.**  The final snapshot used at cutover must
  reflect guest disk state at the exact pause instant, not a window
  before or after.  This is why `switch` takes `@mig-final` after
  pausing the source and before unpausing the destination.
- **Resumable transfer for large disks.**  A transient network fault
  during a multi-hour `zfs send` must not require re-sending
  everything.  This is not a first-release requirement but it must be
  part of the long-term design.

### Network

- **MAC address preservation.**  The guest NIC's MAC must not change.
  The destination's viona vnic must present the same MAC.
- **ARP/neighbor reconvergence.**  Immediately after destination
  resume, upstream switching and routing infrastructure must re-learn
  that the MAC is now on the destination's physical port.  In a
  single-L2 fabric this is accomplished by a gratuitous ARP from the
  guest after resume, which happens automatically for any normal
  guest OS.  In more complex topologies the platform must ensure
  egress traffic from the destination triggers the same re-learning.
- **In-flight packets during pause.**  Packets in the source's viona
  RX queue at pause instant may be lost.  This is acceptable for TCP,
  which will retransmit; it may be visible to UDP-based protocols,
  which is a migration-latency concern, not a correctness bug.
- **One active network-visible copy at all times.**  After
  destination resume, source-side NIC must be prevented from
  transmitting under the guest's MAC.  If the source bhyve is
  preserved as a rollback artifact, the platform must either (a)
  leave its vCPUs paused so it cannot transmit, or (b) administratively
  down its vnic.

### Guest-visible identity

Some state the guest cached at boot is not usually thought of as
"state" but must nonetheless be identical on the destination.

- **CPUID results.**  The guest ran CPUID at boot and cached results
  in data structures it still uses.  Vendor string, family/model/
  stepping, feature bits, cache topology, addressable bits: all must
  match.  Migration between hosts with differing CPUID is at best
  unsafe, and should be rejected at capability-check time.
- **Microcode-visible behavior.**  Spectre/Meltdown mitigation feature
  bits, CPUID 0x7 extended feature flags, and related behavior are
  observed by guests at boot and reflected into guest scheduling and
  syscall paths.  A guest that observed speculation mitigation present
  at boot and does not observe it present after migration is in an
  inconsistent state.
- **APIC IDs and logical CPU layout.**  The guest has cached which
  APIC ID belongs to which logical CPU.  Destination must present the
  same IDs.  This is usually automatic because APIC IDs are
  sequentially assigned and the destination creates the same number
  of vCPUs, but it remains an invariant to respect, not a side
  effect to hope for.

### What does not need to move

Explicitly listing what is not part of the transfer is as important as
listing what is:

- **Host EPT/NPT page tables.**  Rebuilt on the destination from the
  same GPAs against the destination's own allocated host physical
  pages.
- **Host kernel state that is not guest-observable.**  Callout queues,
  scheduler bookkeeping, per-CPU host data.
- **Host wall clock.**  The destination's host wall clock is its own;
  the guest sees its own clock.
- **Host process identity.**  bhyve PID on source is meaningless on
  destination.  The bhyve process on the destination is a new process
  that happens to import the old process's state.
- **Host TCP state.**  Sockets that a guest had open through its vnic
  are connected to peers, not to source host resources.  The vnic
  moves to the destination; the TCP state is inside the guest RAM
  and moves with it.

Anything else not on the "must move" list is either inferred from the
state above (e.g., device interrupt routing tables flow from IOAPIC
plus PCI MSI state) or is implicitly excluded.

### How the hypervisor must enforce these requirements

Stated as a handful of hypervisor-level invariants:

1. **Versioned migration ABI.**  Every piece of transferred state must
   be carried in a versioned, self-describing format.  Destination
   rejects unrecognized versions explicitly; silent acceptance of
   partial data is forbidden.
2. **Atomic snapshot at pause instant.**  All state that is not
   dirty-tracked memory must be captured between source pause and
   destination resume, from a consistent quiesced point.
3. **One-shot import.**  The destination must reject a second import
   attempt after a successful one.  Importing twice into the same
   bhyve process is not a supported mode.
4. **Translation, not copy, for host-relative values.**  Any piece of
   state whose meaning depends on the source host (hrtime-anchored
   deadlines, TSC offset, per-CN object identifiers) must be
   translated into destination-host terms during import.
5. **Validation of all untrusted input.**  The destination is
   deserializing guest-derived and peer-CN-provided state.  Length
   fields, structural invariants, and range checks must be enforced
   before anything touches `/dev/vmm`, bhyve device callbacks, or
   `zfs recv`.  This applies even if the peer CN is nominally
   trusted; a compromised peer is part of the threat model.
6. **Compatibility check before data movement.**  Host CPUID, TSC
   frequency and scaling support, bhyve ABI version, agent version,
   platform image version, and device-model set must be verified
   pair-wise between source and destination before `begin` performs
   any meaningful work.  Discovering incompatibility after a multi-GB
   ZFS send is a design bug.

Everything in the rest of this RFD is in service of making the items
above happen robustly in a production Triton fleet.

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

### The remote migration interface must be secured

Regardless of the operator's chosen network posture, the remote
migration interface must be encrypted, mutually authenticated, and
explicitly authorized for each migration.  "Peer can connect to a TCP
port" is not authorization.  The specific threat model (whether the
admin network is assumed trusted, partially trusted, or hostile) is
deployment-dependent and is discussed further in "Security Impact",
but the interface should be hardened regardless.

## Recommended Solution Overview

The recommended solution has four major layers:

1. Triton keeps the existing phased migration control plane.
2. `vmadm` and `VM.js` gain explicit support for bhyve migration
   targets and bhyve listen-mode startup.
3. bhyve gains the hypervisor-side primitives required to export, import,
   pause, and resume a migrated VM.
4. A CN-local data-plane component (whose deployment home is one of
   several live options) owns the bhyve live migration data plane and
   the cross-CN transport between source and destination.

The rest of this RFD describes those pieces in detail.  Layer 4's
deployment home is treated as an open architectural decision rather
than a settled one; see "The CN-Local Migration Data Plane".

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

## CPU And Platform Compatibility

This is one of the most consequential decisions in the design, and it
is genuinely open.  In a real Triton fleet, compute nodes have mixed
CPU generations (Haswell, Broadwell, Skylake, Cascade Lake, Ice Lake,
Sapphire Rapids, AMD EPYC generations, etc.) and get upgraded
asynchronously.  Without some form of CPU feature alignment between
source and destination hosts, live migration's placement decisions
become severely constrained.  In the worst case a VM can only
migrate to an exact-match host, which defeats the operational purpose.

This section enumerates what we must handle, how other hypervisors
handle it, and the candidate approaches for Triton.

### The underlying problem

When a guest boots, it executes CPUID and caches the result.  The
guest kernel scheduler, JIT, libc, TLS allocator, and syscall paths
may branch on those cached feature bits.  If the guest later runs on
a destination host that does not support one of those features, the
guest may execute an instruction that generates `#UD` (invalid
opcode) and crash.  More insidiously, it may silently produce
incorrect results in a path the guest compiled for AVX-512 that now
runs on an AVX2 host that happens to decode the same byte sequence
differently.

The reverse case (destination host supports a superset of source) is
safe from a crash perspective but still surprises guests that cached
"feature X not present" at boot and are now confused by feature X
appearing mid-migration.

So the practical rule is: the CPU features visible to the guest must
be **stable across migration**.  Either the guest always sees the
same feature set regardless of which host it runs on, or migration
is restricted to host pairs that present the same feature set
natively.

The second concern is **TSC frequency**.  If source and destination
have different host TSC frequencies, the guest's TSC rate will
visibly change on migration.  Modern Intel VMX and AMD SVM
implementations support hardware TSC scaling, which can rescale guest
TSC transparently.  Hosts without TSC scaling must either run at the
same native frequency or refuse migration.  illumos-joyent's
`snapshot_vmm_time_merge` already rescales `vt_guest_tsc` by the
ratio of destination to source frequency (see the "Clocks and time"
subsection); the question is when to trust that scaling versus reject.

The third concern is **platform image / bhyve ABI compatibility**.
A newer platform image may ship bhyve with a different snapshot blob
format or with different vlapic / vmcs feature handling.  Source and
destination must agree on the protocol version before they exchange
bytes.

### How other hypervisors handle this

**VMware vSphere, Enhanced vMotion Compatibility (EVC).**  An
administrator sets a cluster-level baseline CPU generation (e.g.,
Intel "Haswell Generation", AMD "Zen 2").  vCenter masks the CPUID
presented to every VM in the cluster down to that baseline,
regardless of the host's native generation.  All hosts in the
cluster must be capable of *at least* the baseline.  EVC is cluster-
scoped by default; per-VM EVC exists for finer granularity.  TSC
scaling is handled transparently by ESXi when available.  EVC does
not support cross-vendor migration (Intel↔AMD).

**QEMU / libvirt, explicit CPU model.**  `-cpu <model>` picks a
named feature set: `qemu64`, `Nehalem`, `Haswell`, `Cascadelake-Server`,
`x86_64-v2`, `x86_64-v3`, `x86_64-v4`, `EPYC-Rome`, etc.  The model
is a fixed tuple of CPUID bits, TSC features, and MSR defaults.
For migration, libvirt tooling typically queries all hosts in a
potential migration pool and picks the lowest-common-denominator
model.  `virsh domcapabilities` reports what models the local host
can run; migration fails up-front if the destination can't run the
source's model.  Custom models are supported; admins can take a base
and add or remove specific flags.

**Microsoft Hyper-V, processor compatibility mode.**  A per-VM
checkbox that exposes only Hyper-V's conservative baseline feature
set, enabling Live Migration across Intel generations (or across AMD
generations, but not across vendors).

**Nutanix AHV (KVM-based).**  Same model as QEMU/libvirt: named CPU
models, admin picks a cluster baseline.

**Oxide Propolis, per-instance CPUID profile.**  Propolis is Oxide's
Rust userspace for the same illumos bhyve kernel VMM that Triton uses,
which makes its CPU feature handling directly relevant to our design.
Propolis ships a
[`cpuid-profile-config`](https://github.com/oxidecomputer/propolis/tree/master/crates/cpuid-profile-config)
crate that expresses guest CPU features as a per-instance CPUID
profile: an explicit vendor (AMD or Intel) plus a map of CPUID leaf
to (eax, ebx, ecx, edx) values, parsed from configuration and
programmed into the kernel VMM in place of the host CPUID.  This is
structurally the same shape as a per-VM `cpu_baseline`: a stable
per-instance profile that the guest sees regardless of which host
it lands on.

The consistent theme: every production hypervisor exposes some form
of CPU feature masking, because without it, live migration is
constrained to impractical hardware homogeneity.

### Candidate approaches for Triton

Four approaches are compatible with the phased migration architecture
described elsewhere in this RFD.  They can be layered.

#### 1. Strict compatibility (no masking)

Placement only allows migration between hosts that present identical
CPUID natively.  No masking anywhere.

- **Pros.**  Simplest; no CPUID-management surface to design, test,
  or audit; no performance surprises.
- **Cons.**  Severely constrains placement in any fleet with mixed
  hardware; a single new CPU generation splits the fleet into
  migration-incompatible islands; unusable at scale for long-lived
  customer VMs.

#### 2. Per-VM CPU baseline, chosen at create time

Each bhyve VM's creation payload includes a `cpu_baseline` property
(`host`, `avx2`, `sse42`, or named generations).  The kernel VMM is
programmed at VM start with the masked CPUID.  Migration placement
checks that the destination host can run at or above the VM's
baseline.

- **Pros.**  Predictable; the VM sees the same CPUID across its
  entire lifetime regardless of host; maps cleanly onto the existing
  VM-property model in VMAPI.
- **Cons.**  Operator picks the baseline at create time without
  necessarily knowing the future fleet composition; conservative
  baselines forgo features on newer hardware; aggressive baselines
  may trap the VM on older hardware.

#### 3. Fleet / pool baseline (VMware EVC-style)

A Triton concept of a "migration pool": CNs in a pool advertise
their native capability, but a pool-level CPU baseline caps what VMs
in that pool see.  New VMs created into a pool inherit the pool's
baseline.  Migration is pool-scoped, not fleet-scoped.

- **Pros.**  Matches production practice in VMware and Nutanix;
  allows heterogeneous fleet with homogeneous pools; upgrades are
  operator-controlled (raise the pool baseline once every CN in the
  pool supports the new floor).
- **Cons.**  Introduces a new Triton concept (pools) at the CNAPI /
  DAPI layer; adds placement complexity; most useful only for
  fleets large enough to benefit from pools, which is a non-trivial
  subset of Triton deployments.

#### 4. Negotiated-at-migration (lowest common denominator on the fly)

Source sends its effective masked feature set in the migration
preamble; destination computes the feature set *it* would present
the VM at the same baseline; migration proceeds only if they match.
No attempt is made to downgrade the VM mid-migration; a mismatch is a
migration failure, not a silent feature retraction.

- **Pros.**  Source of truth for each migration is the preamble, not
  a pool config; composable with approaches 2 and 3.
- **Cons.**  Not a *selection* mechanism, only a *validation*
  mechanism.  Something else still has to choose destinations
  likely to pass the check (i.e., approach 2 or 3, or DAPI pre-
  filtering on a compatibility vector).

### A recommended combination

A defensible long-term position is approaches 2 + 4 together: VMs
carry a create-time CPU baseline (2) that determines what they see
and what placement filters on, and every migration additionally
validates compatibility dynamically at preamble time (4) to catch
edge cases and platform-image skew.  Approach 3 (pools) can be
layered on later if operators want VMware-EVC-style fleet
management, but it is not required for a first production release.

The first production release should ship with:

- A VM-level `cpu_baseline` property with at least three meaningful
  values (e.g. `host`, `avx2`, `sse42`);
- DAPI aware of that property when selecting migration destinations;
- Preamble validation at migration time rejecting mismatches before
  any data moves;
- TSC-scaling capability as part of the CN capability vector, with
  migration refused if source requires scaling and destination
  cannot provide it;
- Explicit refusal of cross-vendor (Intel ↔ AMD) migration.

This is a strong, defensible default that matches what other
hypervisors do in practice.  It does not preclude pools or more
aggressive negotiation later.

### Platform image compatibility

Separate from CPU masking but related in spirit.  The bhyve snapshot
blob format, VDC_* class versions, and per-device `pe_snapshot`
contracts evolve between platform images.  Two CNs with mismatched
platform images cannot safely exchange snapshot blobs even if their
CPUs match perfectly.

The mechanism described in "Hard Requirements: How the hypervisor
must enforce these requirements" (a versioned migration ABI with
explicit-reject-on-mismatch) is the right enforcement layer.  In
practice this means:

- Every platform image publishes a bhyve migration ABI version
  number that CNAPI can surface;
- VMAPI's migration estimate and DAPI's placement decisions consult
  that version;
- If source and destination versions differ and are not
  forward/backward compatible, migration is refused before any data
  moves.

Short term, "same platform image" is the safe refinement of that
check.  Longer term, the ABI can declare "v1 ↔ v2 compatible" windows
explicitly, enabling rolling platform upgrades without pausing live
migration.

### Open questions in this area

- Should `cpu_baseline` be a package property (so the operator
  chooses it once per SKU) or a per-VM creation property (so
  individual VMs can override)?
- How do we express CPU baseline compatibility in CN inventory
  without exposing raw CPUID leaves to scheduling?  A small named
  capability vector (e.g. `max_baseline: "avx2"`) or a full leaf
  fingerprint?
- For the preamble-time validation path, what is the right
  granularity of mismatch reporting to operators?  "Incompatible",
  or "host X lacks AVX-512_BF16 which source is using"?
- Do we ever support a guest-consenting feature downgrade on
  migration (i.e., after PV-driver-level signalling that the guest
  is willing to re-read CPUID), or is the answer always "the guest
  sees the same features forever"?

## The CN-Local Migration Data Plane

bhyve live migration requires one component per CN that owns the heavy
lifting: RAM transfer, per-VM bhyve control, ZFS send/recv, and the
cross-CN transport to the peer.  This RFD describes what that component
must do; where it is ultimately packaged is left open for the community
to resolve.

### Why it is a component at all

It is not a natural fit for VMAPI: VMAPI is the orchestration record
keeper, not a per-CN data mover, and the migration data plane is
inherently per-CN and long-running.  It is also not ideal as short-lived
cn-agent child processes: the existing "fork a Node process per task"
pattern was workable for stopped-VM ZFS send, but a live migration's
state (WebSocket session, NPT dirty bitmap, mmap of guest RAM, bhyve
control-socket handle) does not naturally live across fork boundaries
and is expensive to re-establish.  A single long-lived process per CN
is the right shape regardless of who owns that process.

### Capabilities this component must have

- talk to `/dev/vmm` (ioctl + mmap) for RAM access, NPT dirty tracking,
  VMM_TIME, pause/resume, and kernel-state transfer;
- talk to each bhyve VM's in-zone control socket for userspace device
  state and pause/hibernate/resume coordination;
- orchestrate ZFS send/recv for the VM's datasets, including final
  cutover-time snapshot discipline;
- maintain a long-lived authenticated cross-CN transport session for
  the duration of a migration;
- survive more than a single RPC round-trip (a migration can run for
  many minutes to hours on a large VM);
- expose a narrow, phase-oriented local API to cn-agent and, optionally,
  local admin tooling;
- emit structured progress, metrics, and audit events VMAPI can surface.

### Local responsibilities

The component should own:

- local interaction with `/dev/vmm`;
- local interaction with bhyve's in-zone control socket;
- RAM transfer logic (baseline pass, convergent pre-copy, final pass);
- bhyve kernel and device state transfer;
- ZFS send/recv transport orchestration;
- transport metrics and detailed per-phase logging;
- a root-only local Unix-socket API.

`cn-agent` remains the task broker and privileged caller; it drives
the data plane rather than reimplementing it.  The driver/data-plane
split is the right internal design boundary even if both pieces happen
to live in the same process.

### Remote responsibilities

The cross-CN interface should own:

- authentication and authorization of the peer;
- encryption;
- framing and multiplexing;
- negotiation of migration parameters (protocol version, CPU
  capability, memory size, dataset list);
- delivery of ZFS, RAM, and state streams;
- cutover coordination.

The long-term contract should not be "ssh as root and run a shell
pipeline".  That is acceptable for exploration but is not the
steady-state architecture.

### Local API

The local API should be narrow and phase-oriented.  cn-agent or local
admin tooling should be able to request:

- estimate;
- begin;
- sync;
- switch;
- rollback;
- finalize;
- status.

Unix-domain socket, restricted to privileged callers.

### Remote transport

The underlying wire format is an implementation detail of the
component-to-component protocol.  WebSocket framing with TLS is the
current prototype choice; whatever is chosen long-term must offer:

- mutual authentication;
- explicit authorization for a particular migration;
- auditability;
- clean carriage of both low-latency control traffic and high-volume
  bulk data.

If one underlying session carries multiple kinds of data, the design
should plan for multiplexed streams or equivalent channel separation
so bulk storage traffic does not block latency-sensitive control and
cutover traffic.

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

This RFD recommends that disk synchronization be orchestrated by the
CN-local migration data plane (whichever home it lives in), not by
external ssh glue.  That means the data plane should:

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
- migration data-plane component version or capability.

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
- the CN-local migration data plane gains a stable local API used by
  cn-agent and, optionally, local admin tooling.  The packaging
  decision (separate process, cn-agent-internal, or other) is open.
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
- the eventual home of the CN-local migration data plane (TBD)
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

The migration data plane should be secured as a matter of principle,
independent of any specific assumption about the admin network's trust
level.  Different Triton deployments will have different views on
whether that network is trusted, partially trusted, or hostile; the
design should hold up across that spectrum rather than depend on a
particular assumption.

Concretely:

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

Beyond "malicious guest", the design should be resilient to a
compromised peer CN or an attacker with observation of migration
traffic.  Injection of migration traffic, replay of a previous
migration, or coaxing the destination into importing attacker-chosen
state must be designed out, not assumed impossible.

## Implementation Plan

The concrete sequencing of implementation work is intentionally left
out of this RFD.  The shape of the work follows from the design: the
compatibility and versioning contract has to exist before data moves,
`vmadm` and bhyve need to grow their migration-target support before
the CN-local data plane can drive them, and user-facing exposure
follows operator-visible readiness.  Scheduling those pieces into
milestones is a planning exercise for the implementing team, not an
architectural decision this document needs to lock in.

## Alternatives Considered

### Keep bhyve migration mostly inside cn-agent child processes

This repeats the older migration pattern and mixes durable
orchestration with long-running hypervisor and transport work in a
place that is not a great fit for either.  cn-agent's short-lived
fork-per-task model also doesn't carry the long-lived state a live
migration needs (WebSocket session, NPT dirty bitmap, mmap of guest
RAM, bhyve control-socket handle).  Workable in principle, but it
pushes the design in a direction that makes every later phase harder.

### Use `vmadm receive` as the live migration target primitive

`vmadm receive` is the right primitive for offline import of a stopped
VM.  It is not shaped for a hidden Triton migration target that must
be provisioned, validated, started in listen mode, rolled back, and
finalized through normal control-plane semantics.  Forcing live
migration through `receive` would either narrow what `receive` means
today or require a parallel `receive`-like mode.  Either way, less
useful than a first-class migration-target shape in `vmadm`.

### Keep ssh as the long-term remote control path

Acceptable for exploration and prototyping (and is what the prototype
uses today), but does not match the required security posture for
production (mutual authentication, explicit per-migration
authorization, and clean auditability), and ties the long-term
transport to a root-shell trust relationship between CNs that is
hard to constrain.

### Create a separate bhyve-only migration API

Triton already has migration records, phases, and workflows.  A
parallel bhyve-specific API would duplicate that surface without
adding expressiveness; extending the existing API with richer
progress detail and inner-phase reporting gets the same capabilities
with one model for operators and tooling to learn.

## Open Questions

- **Where does the CN-local data plane live?**  A dedicated per-CN
  service, part of cn-agent, or elsewhere?  This RFD states the
  requirements but does not pick the home; community feedback on this
  question is explicitly invited.
- What exact capability vector should CNs advertise for migration
  compatibility?
- Do we want one multiplexed CN-to-CN transport session, or separate
  authenticated channels for memory and ZFS streams?
- What is the precise platform mechanism for keeping destination NICs
  quiescent until cutover?
- How much rollback support must be present in the first
  operator-visible release?

## Related Work

- RFD 121 bhyve brand
- RFD 154 Flexible disk space for bhyve VMs
