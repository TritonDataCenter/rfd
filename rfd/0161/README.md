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

# RFD 161 Rust on SmartOS/illumos

## Summary

A bit less structured (at the moment) than other RFDs, but a place to
gather all the various bits and and pieces of what's needed to improve the
experience of using rust on SmartOS with the intention of making it a
viable language option for new work.  At least parts of this will
also likely be of interest to the broader illumos community as well (though
other parts are going to be more focused on SmartOS/Triton/Manta).

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
part of SmartOS.  This makes sense since our intention (as stated earlier)
is that pkgsrc sits on top of the platform.  That does mean that anything
intended to be delivered as part of the platform and be written in rust
may not be able to utilize the pkgsrc rust.  Today, most things are written
in C, bash/ksh, or node.  We build a platform-specific version of node as
part of the illumos-extra repository, and platform bundled node code
utilizes that.  For rust, we will need to think how we want to handle this.
Our experiences w/ the platform bundled node should certainly inform these
discussions, though should not dictate any particular solution.

## rustup

The official mechanism for downloading/using rust is using rustup.  We
should aim to have rust binaries that run on illumos available via rustup.
These rustup binaries should be as similar/compatible with the pkgsrc
delivered rust as make sense (e.g. one might expect some differences with
respect to pathing and such between the two binaries).

While this should be a goal, it need not be an immediate goal that blocks
work on SmartOS, Triton, or Manta that wishes to use rust.

## Current State

Today, the pkgsrc rust uses `x86_64-sun-solaris` as the rust target triple
when building on illumos.  This has a number of drawbacks, as illumos and
Solaris have diverged enough we've discovered a number of issues:

- The rand crate currently issues a direct getrandom(2) syscall.  As the
   getrandom(2) syscall numbers are different on illumos and Solaris, this
   causes programs using the rand crate to die on illumos when getrandom(2) is
   called. This is currently tracked as rust-random/rand#637 with a fix
   hopefully integrated soon.

- The current rust binaries default to omit the use of frame pointers.  While
   a user can explicitly enable the use of frame pointers in their code, the
   core rust libraries (libstd, etc) bundled with the rust compiler that are
   linked in with most rust binaries will not utilize frame pointers.  This
   has an unfortunately consequence of triggering OS-7515 when rust code tries
   to invoke the system unwinder (such as when executing bundled tests).
   Thankfully it appears a small patch can be applied while building the rust
   toolchain that will enable the use of frame pointers by default.  It is
   recommended that no _production_ binaries should be delivered until a rust
   toolchain with this fix is available (however it shouldn't block development
   work).

- External library dependence.  Currently rust built binaries will link against
   things in /opt/local (such as libgcc_s.so).  This is not desirable for
   anything being delivered as part of the platform.  It does appear however,
   that the platform-bundled libgcc_s.so is sufficient, and manual editing
   (elfedit, etc.) can be used to work around this.

- Currently epoll support is advertised as present in Solaris in the libc crate.
    This is a lie, as it's only currently present on illumos.  It seems like
    it might be a bit rude (even while unintentional) to potentially break
    certain uses of rust on Solaris because of advertisement of non-existent
    features.

## Immediate Steps

The immediate priorities should be focused on mitigating the above issues.
Thankfully it appears that we are well on our way with the ongoing work.

## Intermediate Steps

Due to the divergence of illumos and Solaris, we should create a separate rust
target for illumos.  This will allow us to do things such as (not an exhaustive
list):

- Enforce the use of frame pointers by default everywhere
- Disable the rust stack guard in favor of the platform guards
- Enable the use of ELF TLS (thread local storage) over pthread_{get,set}key(3C).
- Expose things such as epoll(2) via rust configuration attributes.
- Allow panics to abort instead of print a backtrace + kill offending thread
    (note: while this is a target option in rust, no other targets are
    currently using it, so it is unknown how well it would work, but may be
    worth checking out)
- Prevent Solaris features not present on illumos from causing problems.
- Allow a illumos toolchain available via rustup to be more compatible with the
    pkgsrc rust toolchain.  To fix a number of the above issues, we can merely
    apply some patches during the pkgsrc build (as a x86_64-sun-solaris target).
    For eventual rustup compataibility, we would want many of those changes to
    be upstreamed.  However, some things are going to pose a problem because of
    the differences between illumos and Solaris.  The best example of this is
    the stack guard feature.  As the rust built-in stack guard conflicts with
    the illumos stack guard, we need this disabled on illumos.  However, people
    using rust on actual Solaris likely _will_ want the stack guard feature.
    This makes it somewhat intractible to have a rustup toolchain that targets
    x86_64-sun-solaris without the rust stack guards, while anyone use the same
    target for illumos needs this disabled.  Having a separate illumos target
    solves this (note: the rust target is a separate entity from the LLVM
    triple, so the creation of an illumos target does not require a new LLVM
    triple).

There will be some upfront costs.  Any lower-level crates will likely need to
have code contributed to include illumos in any platform-specific code.  Our
current hope (based on some work already) suggests this should hopefully not
pose a huge burden.  Generally it should be a one-time deal, and is often just a
matter of adding `target_os="illumos"` in a few places.

One other note -- we should probably avoid producing anything in rust that
_presents_ an ABI interface that requires any sort of stability (e.g. general
use shared libraries).  The rust name mangling scheme is posed to change in the
near-ish future, which would break ABI compatibility.  If any shared libraries
are created, we should strive to keep their use limited to a small
self-contained set of objects that can easily be upgraded in unison with each
other (XXX: is there a better way to say this?).

## Linker

I'm not sure where this fits (other than it's unlikely to be an immediate
issue), but currently rustc calls `cc` to perform linking (passing linker
arguments as `-Wl,linker_arg`).  While this works, it creates a dependency --
one must have a C compiler installed even when doing strictly rust work.
This certainly isn't the end of the world, but is also less than ideal as well.
It also means that we have some limitations in that we can only make use of
linker features that are accessible via calling the C compiler.

For the most part this isn't an issue (as the `-Wl,arg` feature generally covers what
we need).  As we have discovered however, this means that we must rely on the
C compiler to pass `values-Xc.o` and `values-xpg6.o` as well as _not_ pass
`values-Xa.o` to the linker to get the desired behavior from libc and libm.
It turns out the pkgsrc gcc's spec files (and likely even the upstream gcc
tree) do not specify these for C99 other standards mode.  One must currently
supply their own spec file to get around this.

While pkgsrc will soon be updated to use the fixed specfile, others not using
pkgsrc gcc will not be able to benefit (as this problem has existed for decades
at this point, it seems likely that gcc itself is uninterested/unwilling to
accept any patches to correct the behavior).  For both of those reasons, we
should look into the effort to have rustc invoke `ld(1)` directly.

## Things to ponder / Avenues of futher investigation.

As mentioned above, how we go about delivering things in the platform using
rust needs some thought.

What is the experience like using DTrace on rust binaries?  Creating static
probes?  Are there things needed that would enhance/improve the experience?

What is the port-mortem experience with rust binaries?  How difficult is it to
analyize a core file from a rust binary?  We currently have changes out for
review for demangling support for rust names which should help a bit, but what
else is needed (if anything)?  How does CTF work with rust?

## rust illumos target

(Restating a bit what's above -- this section may eventually replace portions
of the above text in the hope it's a bit more organized, or perhaps moved to
it's own illumos RFD since it's broader than SmartOS/Triton/Manta).

As the features of Solaris and illumos have diverged over the years, it makes
sense for rust to have a separate target for illumos.  As the body of rust
software running on illumos is currently quite small, doing this sooner rather
than later seems ideal in terms of timing.  From a technical perspective,
having a separate target gives the illumos community control of their own
destiny as far as rust is concerned.

An excellent example of potential conflicts of continuing to masquerade as
Solaris (as far as rust is concerned) is the issue of stack probe guards.
illumos has built in guards that conflict with the rust stack probes (see
https://github.com/rust-lang/rust/issues/52577 for more detail), while Solaris
does not.  For rust to work reliabily on illumos, the rust stack probes must
be disabled, however it seems likely that users on Solaris will want the rust
stack probes enabled.  While we can patch the pkgsrc delivered rust toolchain
to disable this for illumos (this is in fact what it currently does), this will
not be possible for rustup -- as far as we can tell, rustup has one set of
tools for a given target (i.e. it is highly unlikely they would host a
'solaris' solaris rustup and an 'illumos' solaris rustup).

To accomplish this, the following steps are proposed:

1. Define a minimal illumos target in rust.  This is largely a matter of
    creating the necessary files in src/librustc_target/spec.  The convention
    appears to be to define a set of platform (i.e. OS) defaults, and then
    architecture specific.  In the context of illumos, this would mean the
    features/behaviors present on all variants of illumos, and a separate file
    for AMD64 that would define the things specific/unique to the AMD64
    architecture.  At this point, such a target would be largely
    non-functional, and would not be intended for general use.

2. Add illumos support to core crates.  A number of core libraries (libstd,
libc, etc) will need illumos support added.  While some of these live within
the main rust repo, some do not.  Because of this, it seems simpler to first
have the basic target defined, and then add support to the additional
libraries.  Three key libraries outside of the main rust repo of note are the
libc, num_cpus, and rand crates.

3. Add illumos support to non-core crates as needed.  With the libstd and
libc crates supporting illumos, this should largely be a matter of adding
statements such as `#[cfg(target_os = "illumos")]` as necessary.  In most
cases, our experience (in adding Solaris support) is that most crates often
are using the same interfaces to implement support on other platforms.  For
example, most UNIX platforms have `lstat(2)` whose behavior is largely
identical.  Adding support for the `file_type` method to the `std::fs:DirEntry`
struct is then merely a matter of adding illumos to the list of targets that
use `lstat(2)` to accomplish this.  It is hoped that the amount of actual
additional code that would be needed to add to crates to support illumos
should be minimal.

### illumos target definition

It would be helpful to document the list of options the illumos target
should have.  To start the discussion, an initial list of options is propsed
as follows:

- Use frame pointers by default.  So much of the tooling in illumos -- pstack,
    mdb, dtrace, etc. all rely on frame pointers that we should make this the
    default.  This also avoids triggering [OS-7515](https://smartos.org/bugview/OS-7515).
- XPG6 behavior.  Since rust will be utilizing libc (either more obviously
    via the libc crate, but also through the libstd library) that we should
    make XPG6 behavior the default, as this seems to be similar to the
    expectations for other platforms.  As an example, src/libstd/f64.rs
    currently contains a workaround for Solaris for log(3M), log2(3M), and
    log10(3M) because the default behavior of these functions when passed a
    negative value is to return `-Inf` instead of the standard `NaN`.
    Enabling XPG6 makes these functions conform to the standard behavor and
    not require any workarounds.
- No rust stack probes.  As explained above, these interfere with the
    built-in guards on illumos, and so are unnecessary.
- XTI socket behavior.  In libstd and libc, we should prefer the XTI socket
    behavior over the traditional Solaris socket behavior.  Again, this is
    what is expected on other platforms, and the alternative would likely be
    that like the log(3M) workarounds described above, rust code would need to
    be written to work around the differences even though the expected/desired
    behavior is readily available.  We have two potential approaches:
    1. Add `-lxnet` as part of the linker flags
    2. Specify alternate link names in the rust crate.  rust supports a
    configuration attribute `link_name` where a name in rust uses a different
    name that's used for linking.  It seems analogous to the
    `#pragma redefine_extname` feature used for similar reasons.  The result
    would be doing something similar to:
```
    #[cfg_attr(target_os = "illumos", link_name = "__xnet_bind")]
    pub fn bind(socket: ::c_int, address: *const ::sockaddr,
                address_len: ::socklen_t) -> ::c_int;
```
    We should give a heads up to anyone doing any networking code using the
    current Solaris target that converts to using the illumos target so they're
    not surprised, though hopefully it should be largely transparent.
- ELF TLS (thread local storage).  It is generally preferred as it can have
    less overhead than using `pthread_getspecific(3C)` and
    `pthread_setspecific(3C)`.

For now, we'll not bother with a 32-bit target.  As all illumos kernels are
64-bit, they are all capable of running 64-bit binaries, so 32-bit bit
support is not an immediate need.  Nothing here should preclude or make adding
such a future target any more difficult (if anything it should lessen the
effort).

As the interest in a sparc illumos platform is unknown at the time, the
initial effort won't depend on also creating a sparc illumos target at the
same time.  Nothing should prevent the creation of such a target if the
resources (people, test machines, etc.) are available, however we shouldn't
require it to proceed with the x86_64 illumos target.

It should also be noted that the rust target triple is independent of the
LLVM triple rust uses when compiling.  When one defines a rust target,
one specifies the LLVM triple to use (while they may often match,
there is no requirement that they do so).  This proposal is _not_
proposing any new LLVM triples.  Any such discussions would be better
served being done as their own initative, and as such are out of scope
for this proposal.

#### Forward compatability

Currently, rust does not have any obvious facilities for build-time detection
of OS features.  This presents a bit of a dilemma.  Given the long tradition of
backwards compatability in illumos, a common pattern is to build software on
the oldest version of a platform one intends to support, with the knowledge
that as long as interface stability guidelines are adhered to, the resulting
binary will continue to work well into the future without any recompilation.
pkgsrc as an example makes heavy use of this guarantee.  However, as new
features are added to illumos, we will want to be able to expose these
features in rust.

As an example, the ability to assign names to threads
using `pthread_setname_np(3C)` was added in October 2018.  On systems with
this support, we want `Thread::name` to work.  However this functionality in
rust is part of libstd.  This means absent anything else, a rust toolchain
built on a platform prior to October 2018 will generate binaries where setting
thread names is not supported -- as the rust ABI is not currently stable,
the core rust libraries are statically linked into applications, so delivering
dynamically linked versions of the core libraries w/ the new features matched
to a given platform is not currently possible.

However, we do have the ability to use dlsym(3C) to probe at runtime for the
presence of symbols.  This seems the most straightforward way to deal with
this.  There is also some precedence with rust for this approach.  Within
the std crate, there is a (currently private) macro named `syscall`.  On
non-Linux platforms, instatation of this macro with a function signature (e.g.
`syscall ! getrandom(*mut u8, libc::size_t, libc::c_uint) -> libc::ssize_t`)
appears to create a wrapper function and struct that when first called, will
attempt to lookup the function name via `dlsym(3C)`.  If found, the resulting
address is cached, and then used to call the function in an unsafe block.  If
not found, the wrapper function sets `errno` to `ENOSYS` and returns `-1`.  We
will likely need to adopt a similar approach for situations where it is likely
that merely building on a newer platform is not possible.  This is anticipated
that this will largely be for things in the libc crate and similar, and
hopefully should be too wide spread, though we should build awareness with
any developers to hopefully prevent frustration/problems.
