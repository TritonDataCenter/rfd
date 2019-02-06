---
authors: Jason King <jason.king@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+<Number>%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Joyent, Inc.
-->

# RFD 0161 Rust on SmartOS/illumos

## Summary

A bit less structured (at the moment) than other RFDs, but a place to
gather all the various bits and and pieces of what's needed to improve the
experience of using rust on SmartOS with the intention of making it a
viable language option for new work.  At least parts of this will
also likely be of interest to the broader illumos community as well (though other parts are going to be more focused on SmartOS/Triton/Manta).

This is all still predraft, so nothing here should be set in stone or
taken as the gospel truth.

## Background

Currently most/all use of rust on SmartOS is via the pkgsrc packages.
pkgsrc can be viewed as a layer that sits on top of SmartOS that is
broadly compatible with a _very_ wide range of SmartOS releases (XXX:
fill in oldest supported release -- late Oct 2014).  pkgsrc is both used
by users of native SmartOS images as it's packaging system, as well as with
Triton and Manta services to provide any needed third party software.
As this works quite well for us, there seems no reason to not use pkgsrc
rust in all the places we use pkgsrc today.

One place we don't currently use pkgsrc is for components bundled as a
part of SmartOS.  This makes sense since out intention (as stated earlier)
is that pkgsrc sits on top of the platform.  That does mean that anything
intended to be delivered as part of the platform and be written in rust
may not be able to utilize the pkgsrc rust.  Today, most things are written
in C, bash/ksh, or node.  We build a platform-specific version of node as
part of the illumos-extra repository, and platform bundled node code
utilizied that.  For rust, we will need to think how we want to handle this.
Our experiences w/ the platform bundled node should certainly inform these
discussions, though should not dictate any particular solution.

## rustup

The official mechanism for downloading/using rust is using rustup.  We
should aim to have rust binaries that run on illumos available via rustup.
These rustup binaries should be as similar/compatible with the pkgsrc
delivered rust as make sense (e.g. one might expect some differents with
respect to pathing and such between the two binaries).

While this should be a goal, it need not be an immediate goal that blocks
work on SmartOS, Triton, or Manta that wishes to use rust.

## Current State

Today, the pkgsrc rust uses `x86_64-sun-solaris` as the rust target triple
when building on illumos.  This has a number of drawbacks, as illumos and
Solaris have diverged enough we've discovered a number of issues:

- The rand crate currently issues a direct getrandom(2) syscall.  As the getrandom(2) syscall numbers are different on illumos and Solaris, this causes programs using the rand crate to die on illumos when getrandom(2) is called.This is currently tracked as rust-random/rand#637 with a fix hopefully integrated soon.

- The current rust binaries default to omit the use of frame pointers.  While a user can explicitly enable the use of frame pointers in their code, the core rust libraries (libstd, etc) bundled with the rust compiler that are linked in with most rust binaries will not utilize frame pointers.  This has an unfortunately consequence of triggering OS-7515 when rust code tries to invoke the system unwinder (such as when executing bundled tests).  Thankfully it appears a small patch can be applied while building the rust toolchain that will enable the use of frame pointers by default.  It is recommended that no _production_ binaries should be delivered until a rust toolchain with this fix is available (however it shouldn't block development work).

- External library dependence.  Currently rust built binaries will link against things in /opt/local (such as libgcc_s.so).  This is not desirable for anything being delivered as part of the platform.  It does appear however, that the platform-bundled libgcc_s.so is sufficient, and manual editing (elfedit, etc.) can be used to work around this.
-
## Immediate Steps

The immediate priorities should be focused on mitigating the above issues.  Thankfully it appears that we are well on our way with the ongoing work.

## Intermediate Steps

Due to the divergence of illumos and Solaris, we should create a separate rust target for illumos.  This will allow us to do things such as (not an exhaustive list):
- Enforce the use of frame pointers by default everywhere
- Disable the rust stack guard in favor of the platform guards
- Enable the use of ELF TLS (thread local storage) over pthread_{get,set}key(3C).
- Expose things such as epoll(2) via rust configuration attributes.
- Allow panics to abort instead of print a backtrace + kill offending thread (note: while this is a target option in rust, no other targets are currently using it, so it is unknown how well it would work, but may be worth checking out)
- Prevent Solaris features not present on illumos from causing problems.
- Allow a illumos toolchain available via rustup to be more compatible with the pkgsrc rust toolchain.  To fix a number of the above issues, we can merely apply some patches during the pkgsrc build (as a x86_64-sun-solaris target).  For eventual rustup compataibility, we would want many of those changes to be upstreamed.  However, some things are going to pose a problem because of the differences between illumos and Solaris.  The best example of this is the stack guard feature.  As the rust built-in stack guard conflicts with the illumos stack guard, we need this disabled on illumos.  However, people using rust on actual Solaris likely _will_ want the stack guard feature.  This makes it somewhat intractible to have a rustup toolchain that targets x86_64-sun-solaris without the rust stack guards, while anyone use the same target for illumos needs this disabled.  Having a separate illumos target solves this (note: the rust target is a separate entity from the LLVM triple, so the creation of an illumos target does not require a new LLVM triple).

There will some upfront costs.  Any lower-level crates will likely need to have code contributed to include illumos in any platform-specific code.  Our current hope (based on some work already) suggests this should hopefully not pose a huge burden.  Generally it should be a one-time deal, and is often just a matter of adding `target_os="illumos"` in a few places.

One other note -- we should probably avoid producing anything in rust that _presents_ an ABI interface that requires any sort of stability (e.g. shared libraries for general use).  The rust name mangling scheme is posed to change in the near-ish future, which would break ABI compatibility.  If any such use is needed, we should strive to keep it to a small self-contained set of objects that can be upgraded in unison with each other (XXX: is there a better way to say this?).

## Things to ponder / Avenues of futher investigation.

As mentioned above, how we go about delivering things in the platform using rust needs some thought.

What is the experience like using DTrace on rust binaries?  Creating static probes?  Are there things taht could be added/written to enhance/improve the experience?

What is the port-mortem experience like with rust binaries?  How difficult is it to analyize a crashed rust binary?  We currently have changes out for reivew for demangling support for rust names which should help a bit, but what else is needed?  How does CTF work with rust?
