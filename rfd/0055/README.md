---
author: Jerry Jelinek <jerry.jelinek@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 55 LX Support for Namespaces

## Introduction

We already have namespace isolation within illumos, but this is done at the
zone level and does not nest beyond the two level hierarchy that zones offer.
For the lx brand we need a per-process namespace abstraction which can then
be inherited or modified by children.

This RFD does not provide a detailed design for each type of Linux namespace.
Instead, it outlines a framework for how any namespace can be plugged into lx.
It also provides examples for how some of the different Linux namespaces could
be implemented within the framework.

The Linux `namespaces(7)` man page provides details, but to summarize the
support, there are three system calls which can involve namespaces; `clone`,
`setns`, and `unshare`. There are six primary namespaces:
 1. IPC         CLONE_NEWIPC    System V IPC, etc.
 2. Mount       CLONE_NEWNS     Mount points
 3. Network     CLONE_NEWNET    Network devices, stacks, ports, etc.
 4. PID         CLONE_NEWPID    Process IDs
 5. User        CLONE_NEWUSER   User and group IDs
 6. UTS         CLONE_NEWUTS    Hostname and NIS domain names

The Linux `proc` file system exposes the following entries:
- /proc/{pid}/ns/ipc
- /proc/{pid}/ns/mnt
- /proc/{pid}/ns/net
- /proc/{pid}/ns/pid
- /proc/{pid}/ns/user
- /proc/{pid}/ns/uts

The `mount` syscall can be used to `bind` mount any of these `proc` files
elsewhere in the directory hierarchy. Bind mounting is discussed further
below.

## Design

At a high level, this is a fairly straigtforward enhancment to our per-process
lx process brand data (`lx_proc_data_t`).

We will define a new lx namespace structure (hereafter abbreviated as LNS) with
at least these members:
```
    type (ipc, mnt, etc)
    cnt (reference counter)
    inode (for `/proc` support)
    data (type specific data pointer - similar to vnode data element)
```

We will eventually add 6 pointers to the `lx_proc_data_t` struct, one for each
namespace. These point to an associated LNS. Adding these pointers can be done
incrementally, as we add support for each namespace. When we `fork` a new
process, the newly constructed `lx_proc_data_t` will reference the same
LNS objects as the parent.

We will always start `init` with a full set of LNS objects. These pointers
will be inherited on `fork/clone` so that children get that LNS definition
by default. The LNS is reference counted so we know when it can be cleaned up.

We will modify the relevant code (either in lx itself or we will add new brand
hooks if in generic code) as we support each new type of namespace, so that the
code properly handles the LNS type-specific data.

The `clone` and `unshare` syscalls will create a new LNS of the proper type
and associate the process with that object via the proper LNS pointer in
`lx_proc_data_t`. Each type-specific namespace will also create a structure of
the appropriate type and associate it with the LNS object via the `data`
pointer.

The `/proc` file associated with each namespace will need to reference the
associated LNS object. When the file is open, the LNS object must be held,
via the reference count, so that the object persists even if all processes
referencing the object exit. The LNS `inode` member is used for the
`stat.st_ino` value on the `/proc` file.

The `setns` syscall must take a file descriptor for one of the `/proc/{pid}/ns`
files and associate the correct `lx_proc_data_t` LNS pointer to that object.

## Mount Namespace Example

Since the mount namespace is likely going to be the first one we implement,
lets walk through a proposed implementation of this at a high level.

Our existing mount namespace behavior is built around the zone's `zone_vfslist`
to provide a per-zone mount list. We now want that behavior to be associated
with a mount namespace instead.

The `unshare` syscall will create a new LNS of type `mount` and associate the
process with that object via the new mount LNS pointer in `lx_proc_data_t`.
Because this is an LNS object of type `mount` we also create a structure with a
`vfslist` member and the associated locks, etc. This structure will be
referenced by the LNS `data` pointer.

New brand hooks will be defined and the `vfs_list_add` and `vfs_list_remove`
kernel functions will be enhanced to call the new brand hooks. The lx
implementation of these hooks will manipulate the LNS object vfs list in
addition to the zone's vfs list. Similarly, the code that walks the zone's
vfs list will need modification so that the calling process will walk the LNS
`mount` vfs list instead of the zone's vfs list.

There are a few `/proc` changes also required to handle the correct behavior
for `mounts` and the new `mountstats` file.

The `user` namespace has some interaction the the `mount` namespace. See the
`user_namespaces` man page for details. The `mount` namespace code may need
enhancement when implementing the `user` namespace support.

## Bind Mounts

See the `mount(2)` man page for more details on the `MS_BIND` mount option.
Bind mounts are conceptually similar to an illumos `lofs` mount and we
should be able to emulate at least some of the functionality in this way.
However, as the man page states, there is some complexity here which may
need further design:
```
Bind mounts may cross filesystem boundaries and span chroot(2) jails.
```

Bind mounts interact with namespaces in that the `/proc`/{pid}/ns` file
can be bind mounted someplace else in the filesystem and this will keep
the associated LNS object alive even if all processes referencing the object
have exited.

In order to support this kind of functionality, instead of having simple
support in `/proc`, we will most likely have to implement a new, in-memory,
pseudo filesytem which will maintain all of the LNS object instances. It
may not be necessary to get this complex unless we want to fully run
Linux containers within lx zones. We should start with a simpler implementation
and only add full bind mount support if necessary.
