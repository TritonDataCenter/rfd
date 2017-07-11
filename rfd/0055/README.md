---
authors: Jerry Jelinek <jerry.jelinek@joyent.com>, Patrick Mooney <patrick.mooney@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->

# RFD 55 LX Support for Mount Namespaces

## Introduction

We already have namespace isolation within illumos, but this is done at the
zone level and does not nest beyond the two level hierarchy that zones offer.
For the LX brand we need a per-process namespace abstraction which can then
be inherited or modified by children.

The Linux `namespaces(7)` man page provides details, but to summarize the
support, there are three system calls which can involve namespaces; `clone`,
`setns`, and `unshare`. There are six types of namespaces:
 1. IPC         CLONE\_NEWIPC    System V IPC, etc.
 2. Mount       CLONE\_NEWNS     Mount points
 3. Network     CLONE\_NEWNET    Network devices, stacks, ports, etc.
 4. PID         CLONE\_NEWPID    Process IDs
 5. User        CLONE\_NEWUSER   User and group IDs
 6. UTS         CLONE\_NEWUTS    Hostname and NIS domain names

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

One of the pressing reasons to support namespaces, particularly the mount
namespace, is the proliferation of the `PrivateTmp` functionality offered by
systemd. An excerpt of the `systemd.exec(5)` man page describes the behavior:

> If true, sets up a new file system namespace for the executed processes and
> mounts private /tmp and /var/tmp directories inside it that is not shared by
> processes outside of the namespace.

Use of this option is proliferating as package maintainers add it to service
manifests and systemd-enabled distributions see more use in production.  It
must be a workflow which the LX emulation is capable of handling.

Because of the need to support `PrivateTmp`, this RFD focuses on the LX
design for `mount` namespaces. 

## Mount Namespace Overview

There are three mount operations that interact with a mount namespace.
- `MS_SHARED` - The mount point is shared between the parent and child
namespace. Any new mount or unmount under the shared mount point is visible to
both namespaces, no matter which side initiated the action. That is, mount
changes propagate both ways.
- `MS_SLAVE` - Any new mount or unmount initiated by the child under the slave
mountpoint is only visible to the child namespace, but any mount or unmount
initiated by the parent is visible to the child. That is, mount changes
propagate into the child, but not out to the parent.
- `MS_PRIVATE` - Any new mount or unmount initiated under the private
mountpoint is only visible within the namespace. That is, mount changes do not
propagate.

In addition, Linux supports another type of mount; `MS_BIND`. This is similar
to our native `lofs` mount which is used to mount an existing directory
someplace else in the filsystem. One key difference is that under a `MS_BIND`
mount, filesystems mounted under the source directory will not be visible under
the bind mounted directory, unless the recursive option (`MS_REC`) was used.
See the `mount(2)` man page for more details on the `MS_BIND` mount option.

## Mount Namespace Example

In order to gain insight into the `PrivateTmp` mechanisms in play, systemd was
straced on a Linux machine while it started a PrivateTmp-enabled service.
These are the relevant actions which were recorded:

```
unshare(CLONE_NEWNS)
mount(NULL, "/", NULL, MS_REC|MS_SLAVE, NULL)
mount("/tmp/systemd-private-05a301e42bdd44cb9cb6cf41331ea4f1-test.service-uHYy7p/tmp", "/tmp", NULL, MS_BIND|MS_REC, NULL)
mount("/var/tmp/systemd-private-05a301e42bdd44cb9cb6cf41331ea4f1-test.service-2PWYJy/tmp", "/var/tmp", NULL, MS_BIND|MS_REC, NULL)
statfs("/tmp", ...)
mount(NULL, "/tmp", NULL, MS_REMOUNT|MS_BIND, NULL)
statfs("/var/tmp",  ...)
mount(NULL, "/var/tmp", NULL, MS_REMOUNT|MS_BIND, NULL)
mount(NULL, "/", NULL, MS_REC|MS_SHARED, NULL)
```

Which roughly corresponds to:
 1. Create a new mount namespace for the process. Because the parent is sharing all of its mounts, every mount remains visible in the new child namespace.
 2. Recursively set `/` to `MS_SLAVE` mode.  This means that mount changes in the parent namespace will appear in this child, but any mount changes here will not propagate up.
 3. Bind-mount custom directories for `/tmp` and `/var/tmp`
 4. Check and re-apply mount flags for `/tmp` and `/var/tmp`.  This apparent no-op seems to be a consequence of code generalization in systemd.
 5. Recursively set the `MS_SHARED` mount flag on `/` and its children.  This does not "reattach" it to the parent namespace, but does mean that any new namespaces created by children of this process would share the same initial mount view.

## High-Level Design Alternatives

A high-level observation is that mount and unmount are rare operations compared
to lookup, so it is preferable to favor any expensive work within the
mount/umount path and avoid complicating the lookup path.

### Leverage a filesystem similar to `lofs` for `tmp MS_SLAVE` behavior

We can observe that a new mount namespace usually sees all of the same
filesystems as the parent. Any mounts that change in the parent will be visible
in the child. Thus we get the `MS_SHARE` visibility from parent to child for
free. If we focus on the `PrivateTmp` behavior, we could do something
like a `lofs` mount onto `/tmp` and `/var/tmp`. This would only be applicable to
the child namespace. We could create a filesystem similar to `lofs` that
could direct vfs traversal to the top filesystem or the underlying filesystem,
depending on which namespace the process doing the lookup was in.

Implementing this approach to address the `PrivateTmp` use case might be
fairly straightforward, but it seems to have a lot of limitations.
Any unmount of an existing filesystem which occurs in the child under a
`MS_SLAVE` tree (all of the tree for the `PrivateTmp` case), would incorrectly
impact the parent. Maintaining the correct per-process view of
`/proc/self/mounts` would be tricky (although this is also presumably a rare
operation). We can assume that there could be many mounts on top of `/tmp` and
`/var/tmp`, so that might cause complications. Finally, while this approach
might work for `PrivateTmp`, it doesn't generalize to all of the mount
namespace behavior.

### Use an approach similar to the way we setup a zone

When a process creates a new mount namespace we could `chroot` the process
someplace out of the way within the zone. We could use a filesystem like
`lofs` to recreate all of the shared mounts in the child that are visible in
the parent.

Because of the way our current `lofs` works, mount changes for a shared portion
of the tree in the parent would cause the proper visibility in the child, but
the child `/proc/self/mounts` view would still somehow need to be updated.
Likewise, with our current `lofs` behavior, mount changes in the child for a
slave or private portion of the tree won't propagate into the parent.

However, the existing `lofs` would not properly handle propagating visibility
for shared mount changes made in the child. It also would not properly mask
parent visibiltiy of `/proc/self/mounts` entries for mounts under a child's
`MS_SLAVE` or `MS_PRIVATE` tree. A new filesystem, similar to `lofs`, would
need to be written which would handle all of these issues. In addition, it
would have to handle the differences in `MS_BIND` behavior at mountpoint
boundaries. We would need some way to track which mountpoints are shared,
slave, or private.

Because the child is chrooted someplace within the zone, the new filesystem
would need to mask the entire tree from visibility in the parent (even though
shared mount changes must still propagate correctly).

The advantage of this approach is that mountpoint traversal would work as
expected withn the chroot-ed process (and its children) with no changes to the
lookup code.

One difficult aspect of this approach is handling shared mount changes from the
parent side and getting those propagated into any child namespaces.

### Have a process-oriented view of mounts

In addition to (or instead of) the per-zone mount view, the mount view would
be associated with a process. Child processes would normally share the same
view.

When a new namespace is created, the current mount view is duplicated into
a new structure associated with the process. Any child processes will share
this same structure until they create their own namespace. All mount operations
operate on the structure associated with the process. This approach involves
changing the lookup code so that vfs traversal is specific to the the mount
structure associated with the calling process. This per-process structure
pointer might be similar to the per-zone `zone_vfslist` pointer.

Conceptually, during lookup, every mount point traversal (or perhaps this could
be limited to only those impacted by a mount namespace) would have to reference
the processes associated mount structure list to determine how to proceed (i.e.
which vnode to traverse to next).

As with the previous alternative, mount operations which are shared would need
to propagate into all of the effected process-related mount lists.
Perhaps some form of chaining could be used to manage these relations.
Slave and private mount operations within the child would only effect that
process's mount list.

### XXX Any other high level alternative?

## XXX Detailed design for the selected approach
