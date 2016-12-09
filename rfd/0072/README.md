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

# RFD 72 Chroot-independent Device Access


## Background

Several facilities such as `epoll`, `timerfd`, and `signalfd` have been added
to the native system as part of the Linux compatibility effort for LX-branded
zones.  Rather than representing each facet of the API in a separate syscall,
as Linux does, they are implemented as functions in libc which act upon a
character device handle.

## Problem

The initialization routines (`epoll_create()`, `timerfd_create()`, etc) for the
aforementioned drivers all have an implicit expectation that the backing
character device will be available to be `open(2)`ed at the expected path
(`/dev/poll` for epoll, as an example).  While this works in most situations,
processes which attempt to initialize such resources after a `chroot()` will
often encounter problems.  On Linux, the `*_create` syscalls are not effected
by the chroot context in the same way as their illumos libc counterparts.

## Proposed solution

In order to facilitate the opening of certain devices in a chroot-constrained
context, a new syscall, tentatively named `devopen` should be added.  This
syscall will accept two arguments, a string identifier under which the desired
device has register (such as "epoll") and an integer of `open(2)`-compatible
flags.  Upon success, it will yield a valid file descriptor.  Only drivers
which opt-in via registration at the time of their attachement will be
accessible via `devopen`.  This will prevent `devopen` from being used as a
vector for access control bypass or unwanted access from inside a chroot.  It
is expected that only pseudo devices will make use of `devopen`.

Several steps will be required to achieve this goal:


* Expose `devopen_register()` and `devopen_deregister()` kernel functions for
  manipulating driver registration within the `devopen(2)` framework.

* Add `devopen()` syscall which will open a fresh file descriptor for requests
  matching the device list.

* Update Linux-related drivers (`epoll`, `timerfd`, `signalfd`, `inotify`) so
  that they opt into `devopen` access.

* Change libc `*_create` functions for those drivers to use `devopen(2)`
