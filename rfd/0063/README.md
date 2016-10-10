---
authors: Patrick Mooney <patrick.mooney@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 63 Add branding to kernel cred\_t

## Introduction

SmartOS makes use of the concept of 'branding' to implement differing
personalities for zones on a system.  The most prominent of these is the LX
brand, which mimics a Linux kernel though several mechanisms include a custom
syscall table.  Since much of this branding functionality requires additional
context information when evaluating kernel logic, the `zone_t`, `proc_t`, and
`klwp_t` structures each contain fields to attach brand-specific data.

## This RFD

The goal of this document is to describe the justification and proposed steps
for associating branding information to `cred_t` entities in the kernel.

## Background

### Brand Data Lifetime

The lifetime of branding data associated with in-kernel entities determines
when brand-custom behavior can be applied to those entities.  Zones receive
branding early in their lifetime and retain it until being destroyed.  LWPs
under a branded process will receive their branding during creation, shedding
it upon destruction.  Processes are more complicated when it comes to branding
due to the effects of `exec(2)`.

When initiating an `exec(2)`, attributes of the executable may dictate if the
process is to be branded at the conclusion of the syscall.  This may be as
simple as leaving the brand state (or lack there of) unchanged.  In more
complicated cases, branding may be added or removed from the process during
operation.

### The Native "Hole"

A branded process executing a native binary will lose all of its brand state
during the `brand_clearbrand` portion of the `exec(2)`.  While this is expected
-- a native process should not observe custom behavior which would depend on
that data -- it means that brand state will not "follow" the process or its
children, even if/when they take actions to become re-branded.  There are
instances when it would be valuable for a subset of branding information to
persist in non-branded processes.  The most prominent potential consumers in LX
would be `capabilities(7)` and `namespaces(7)` emulation.

### Capabilities Emulation

Linux features a granular permissions system, `capabilities(7)`, which is very
similar in operation to illumos `privileges(5)`.  The current emulation in LX
acts as a mapping between equivalent entities in the two systems.  While this
is a simple and secure way to provide the expected interface, it falls short
for Linux-only capabilities which lack equivalent native privileges.  They
could be stored in the process brand data to later dictate behavior in LX, but
a trip through the mentioned "native hole" means the extra capabilities data
would be discarded.

### Namespaces Emulation

`Namespaces(7)` are a mechanism on Linux for isolating the resources which are
visible to sets of processes.  There are several types for constraining
resource visibility: filesystems (mount namespaces), networking (net
namespace), SysV/POSIX IPC primitives (IPC namespace), processes and PIDs
(process namespace), hostname and domainname (UTS namespace), and user/group
IDs (user namespace).  These are often combined to implement a container-like
abstraction.  Another common consumer is `systemd`, which will enforce
restrictions on processes by using a smaller subset of the available
namespacing features.

To emulate this functionality in LX, the kernel could apply restrictions and/or
transformations to syscall inputs and their results to mimic the expected
behavior.  This approach may seem adequate at first, but the previously
mentioned "native hole" proves to be a difficulty.  A process could slip the
confines of its namespace(s) by simply executing a native binary to become
unbranded.  This nullifies much of the value offered by namespaces.

## Proposal

In order to address the shortcomings of the current branding system as it
pertains to data persistently following processes through brand transitions, a
new field should be added to the `cred_t` to store per-brand data.  This is a
semantically congruent place to store identity information which is specific to
a brand.  For both the `capabilities(7)` and `namespaces(7)` examples, it would
prevent resource grants or restrictions from being shirked for processes which
transition between native and branded states.  Implementing this will require
several changes to the system.


### Credential Interface

The internal implementation of the `cred_t` structure is kept opaque to the
rest of the system, being exposed through a set of accessor functions.  A new
new field, `void *cr_brand`, will be added to the `cred_t` definition to store
the branding.  These two new accessors will be added for outside consumers to
manipulate it:

```
void *crgetbrand(cred_t *cr);
void crsetbrand(cred_t *cr, void *brand_data);
```

As expected, `crgetbrand` will retreive the pointer field.  The `crsetbrand`
function is similarly simple, although it will verify two things:

1. The process exists inside a zones which branded
2. No existing brand data pointer resides in `cr_brand`.  No circumstances
   which which would require un-branding a `cred_t` (except during `crfree()`)
   are apparent at this time.

In addition to `cr_brand`, a `zone_t *cr_brand_zone` field will also be
included in the `cred_t` definition.  Its purpose, explained in the
_Psetzoneid_ section below, is to hold a reference to the originating zone when
branded `cred_t` entities are temporarily reassigned to a different zone.

### Brand Hooks

Several additional brand hooks will be added to the `brand_ops` structure
definition to support this new functionality.  While they are optional, any
brand using branded credentials *must* implement all three:
```
void b_credbrand(cred_t *cr);
void b_credclear(void *brand_data);
void b_creddup(cred_t *src, cred_t *dst);
```

The `b_credbrand` hook is used to apply branding to a `cred_t` for a process
which has recently entered the zone (like zlogin or init).  In order to
facilitate `cred_t` destruction, the `b_credclear` hook is called to release and
deallocate brand data during `crfree()`.  Finally, `b_creddup` is called to
allocate and duplicate brand data when a branded `cred_t` undergoes `crdup()`.

### The Psetzoneid Problem

Normally, processes stay locked inside a single zone for their entire lifetime.
There are two primary activities where this is not the case: When a `zsched`
processes is created as part of zone boot and during `zone_enter` as performed
by `zlogin(1)`.  Both are a GZ-to-NGZ transition and are performed carefully
from a branding perspective.  Transitions from NGZ-to-GZ are generally
forbidden, given the security ramifications, but there is one prominent
exception.  When altering `zone.*` rctls for an NGZ process, prctl will
temporarily assign the `cred_t` of the process into the global zone so it has
appropriate permissions to alter the zone rctls.  This is performed via
`Psetzoneid(3PROC)` which results in a `crsetzone` call.

Dealing with the potential for branded `cred_t` entities to be temporarily
moved into the global zone presents a problem.  The `cr_zone` field cannot be
reliably used to determine the brand to which the data is associated with.  In
order to mitigate this shortcoming, an additional field `cr_brand_zone` should
be setup to hold a reference to the original zone when the `cred_t` transitions
into the GZ.  When it transitions back, the reference can be dropped.

The `prctl` implementation will ideally be updated at some point to remove the
need for `Psetzoneid` machinations.  If that occurs, and the whole `Psetzoneid`
interface is removed from procfs, then `cr_brand_zone` and its associated logic
can be removed from the `cred_t` handling.

## Alternatives

An obvious alternative method for ensuring that certain brand-specific data is
maintained when a process drops other branding during an `exec(2)` would be to
keep a separate field in `proc_t`.  Such an approach would be feasible, with
similar footprint of additional scoping and hooks to make it viable.  Despite
that, there are a few reasons why this might be less favorable in the long run.

Both of the described use-cases are focused mainly on process identity.  The
`capabilities` enhancement is a direct analog to `privileges`.  While
`namespaces` are a bit of a stretch, they still can be boiled down to system
accesses being authorized (and perhaps manipulated) based on the identity of
the thread.  This is a closer fit, semantically speaking, for `cred_t`.

Beyond the semantics, `cred_t` offers some hard technical advantages when it
comes to how the brand data may be consumed.  Updates to `cred_t` state in a
process are made visible to its threads in a very controlled manner.  A thread
in the middle of a syscall will not receive the updated `cred_t` until it makes
a fresh trip through the pre-syscall logic.  This ensures that `CRED()` will
yield a consistent credential throughout the length of syscall.  It is likely
that the complex interactions required to implement the `mount namespace` will
require this consistency during lookups in VFS.  In that context, holding
`p_lock` or a similar process lock would be too expensive and exclusionary.
