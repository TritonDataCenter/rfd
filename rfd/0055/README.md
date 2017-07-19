---
authors: Jerry Jelinek <jerry.jelinek@joyent.com>, Patrick Mooney <patrick.mooney@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->

# RFD 55 LX support for Mount Namespaces

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
elsewhere in the directory hierarchy. Bind mounting is orthogonal to `mount`
namespaces, but is mentioned briefly below.

One of the pressing reasons to support namespaces, particularly the mount
namespace, is the proliferation of the `PrivateTmp` functionality offered by
systemd. An excerpt of the `systemd.exec(5)` man page describes the behavior:

> If true, sets up a new file system namespace for the executed processes and
> mounts private /tmp and /var/tmp directories inside it that is not shared by
> processes outside of the namespace.

Use of this option is proliferating as package maintainers add it to service
manifests and systemd-enabled distributions see more use in production.  It
must be a workflow which the LX emulation is capable of handling.

Because of the pressing need to support `PrivateTmp`, this RFD is focused on
the LX design for `mount` namespaces. 

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

## The Selected Approach

Given the high-level alternatives, it is clear that the first option is not
very interesting, so the choice comes down to the second and third options.
Either one could be made to work, but in the end we have chosen to pursue
the third option (`Have a process-oriented view of mounts`). This option is
more intrusive in the system to start with, but it appears to lead to a
cleaner final solution in the end. This should pay off in the long term
with a less cluttered architecture and code that is easier to understand. It
should should also reduce the number of unusual corner cases that must be
dealt with.

## Detailed Design For A Process-Oriented View Of Mounts

### The mount list

The existing global mount list of vfs's which is chained off of `rootvfs`
will continue to be maintained.

The `proc_t` structure will be extended to add a pointer to the namespace for
that process. When a process forks, the new child will point to the same
namespace. The namespace must be reference counted so it can be removed when the
last process referencing the namespace has exited.

A namespace is essentially a list of mounts visible to the process.

For performance reasons during lookup, we only want to deal with the current
process's namespace. We do not want to find and search multiple namespaces
during lookup, but this means mount entries must be duplicated into multiple
namespaces during mount operations. Handling for this is discussed in this
design. Since mount operations are much rarer than lookup operations, this is
the best choice for performance.

Because a mount entry can be present in many different namespaces, we cannot
use an approach with embedded vfs_t list pointers like we currently do with
`vfs_zone_next` and `vfs_zone_prev`. Instead, we'll define a namespace-specific
vfs list structure which would point to a single vfs entry. This structure
will also contain information about how the vfs is being used by this specific
namespace.

    typedef structure mntns_ent {
        list_node_t    mnse_link;
        uint_t         mnse_flags; /* mointpoint flags - described below */
        uint_t         mnse_gen;   /* generation number */
        struct vfs     *mnse_vfsp; /* pointer to the vfs visible to the NS */
    } mntns_ent_t;

The `mnse_flags` and `mnse_gen` members are described in section
"Tracking MS\_SHARE, MS\_SLAVE and MS\_PRIVATE per namespace and mount".

The namespace structure referenced by the `proc_t` will look like this:

    typedef structure mntns {
        uint_t       mntns_cnt;        /* reference count */
        krwlock_t    mntns_lock;       /* lock protecting members */
        list_t       *mntns_mntlist;   /* list of mounts visible to proc. */
        mntns_t      *mntns_parent;    /* pointer to parent namespace */
        list_t       *mntns_children;  /* list of direct child namespaces */
        list_node_t  mntns_link;
    } mntns_t;

For mount operation propagation across namespaces, each namespace must
maintain a pointer to it's parent namespace in the hierarchy and a list
of direct children of the namespace. The `mntns_parent` and `mntns_children`
members are used for this.

When a process creates a new `mount` namespace, a new `mntns_t` will be created
and all of the `shared` mount entries will be duplicated into the new
namespace. The reference count on the namespace that the process was previously
associated with must be decremented. The `mntns_parent` for the new
namespace should point to the previous namespace the process belonged to.
The new namespace should be added to the `mntns_children` list of the original
namespace as well.

When the last process referencing a namespace exits, the `mntns_parent` and
`mntns_children` may need to be updated if the process is in the middle of a
chain of namespaces. All children now need to point at the parent namespace
of the exiting process. That namespace should also inherit all of the
children in the exiting process's `mntns_children` list.

### Maintaining the mount list

The mount list is updated during a `mount` and `unmount` syscall.

It is helpful to reiterate the following points:
 1. A true local filesystem can only be mounted once. We must use `lofs`,
or something like it, if we want a filesystem to appear in more than one place.
That will appear in the mount list just as any other `lofs` mount.
 2. Setting up a new namespace doesn't change where/how the original
filesystems are mounted. We can only change visibility of future mount activity
for our namespace.

A high-level summary of mounting/unmounting behavior, in the absence of
namespace usage within a zone, is that things should behave very much as they
do currently with our two-level global zone/non-global zone mount lists.
We start by discussing how things will work under this scenario before going
on to extend the behavior for full `mount` namespace usage.

#### Removing zone.zone_vfslist

Given the new process-oriented namespace, the existing zone-oriented mount
list in `zone_vfslist` could be removed. When `zoneadmd` readies a zone, the
zone's namespace can be maintained on the `zsched` process. That
namespace would be inherited by all child processes within the zone.

As a performance optimization, when this namespace is created, there is no
need to duplicate any of the global zone mounts since the zone mounts, as
expressed in the `zsched` namespace, are completely built up for the new
zone. In terms of namespaces, the zone ready process creates an entirely
new mount tree that behaves approximately like `MS_SHARED`, but because
the zone is in a chroot-ed environment, all in-zone mount operations are always
relative to the zone's root. The global zone can see any mounts the non-global
zone has made. Any mounts made by the global zone under the zone's
hierarchy would take effect for the zone, although they are not in the zone's
mount list. Note that this type of mount action would not be considered normal
for zone operations.

XXX Add details for when we lofs mount something in the GZ that is visible
under a mount in the NGZ, e.g. mount foo on /usr/bin/xxx, in zone have
/native/usr/bin/xxx

#### Mounting

The calling flow here is:
```
domount (and others) -> vfs_add -> vfs_list_add
```
When a filesystem is first mounted, it continues to be added to the single
mount list off of `rootvfs` during `vfs_list_add`. The `vfs.vfs_next` and
`vfs.vfs_next` pointers continue to be used to maintain this list.

As discussed above in section "Removing zone.zone_vfslist", the vfs is no
longer added to the per-zone list `zone_vfslist`, but is instead added to the
process's namespace.

`vfs_list_add` will continue to use `vfs_list_lock` to lock access to the
master list. It will also need to use the `mntns_lock` to lock the namespace
list.

The `mnse_flags` member in `mntns_ent_t` is used to track information about
this mountpoint for this namespace. This is discussed further in section
"Tracking MS\_SHARE, MS\_SLAVE and MS\_PRIVATE per namespace and mount".

When a new namespace is created, this action will duplicate the namespace
mount list into a new namespace list. Because no actual changes
to the mounted filesystems has occured, the master mount list is not updated to
add new entries in this case, but we must increment the reference count
(via `vfs_hold`) on the vfs.

Handling of new mounts under a `MS_SHARED` mountpoint is discussed below
in section "Tracking mount changes across namespaces".

XXX vfs_list (sync list) unused?

XXX confirm vfs_hash is ok. Only used by getvfs() for fsid lookup (NFS server
only?)

#### Unmounting

The calling flow here is:
```
dounmount -> vfs_remove -> vfs_list_remove
```
When a filesystem is unmounted from within a namespace, the entry is removed
from the namespace list and the reference count is decremented on the vfs
(via `vfs_rele`). The normal (final) unmounting occurs when the reference
count on the vfs drops to 0.

Handling of unmounts under a `MS_SHARED` mountpoint is discussed below
in section "Tracking mount changes across namespaces".

### Handling mountpoints during lookup

The lookup code path is the central point where paths resolve into vnodes.
Everything funnels through `lookuppnvp()`. This function handles traversing
across mountpoints during lookup. With `mount` namespaces we will still have
a mountpoint at each relevant location in the filesystem tree, but not every
mountpoint will be visible, or resolve the same way, for every process. For
example, with a local mount under a `MS_SLAVE` mountpoint, a process within the
namespace must traverse that mount, but a process outside the namespace must
not.

This section describes the updated lookup handling for the new
process-oriented namespace mount list.

The following functions are involved in mountpoint traversal.

#### vn_mountedvfs

This function returns the `vfs` mounted on a vnode (if any). The function
currently uses `vp->v_vfsmountedhere` to get the `vfs` of the filesystem
mounted on the vnode. It returns NULL if the vnode is not a mountpoint.
Under the new design, there can be one or more filesystems mounted on the same
vnode. The namespace view will control which vfs to use. In order to keep
lookup as fast as possible for the common case, when there is only one
filesystem mounted on a vnode, we will continue to reference it directly in the
`v_vfsmountedhere` pointer. If there are multiple mounts on the vnode, or
a namespace has locally unmounted the filesystem, this pointer will be set
to 0xffffffff. This distinguishes it from NULL, and indicates that we must use
the proccess's namespace mount list to determine which vfs to use. We must take
a read lock on the `mntns_lock` while traversing the `mntns_mntlist`. We will
match on the `vfs_vnodecovered` member to determine if our vfs is mounted on the
given vnode. The `vfs_vnodecovered` must always be set to the base vnode, no
matter how many per-process mounts are there.

For example, if we have two different processes in two different namespaces,
each of which has its own mount on `/tmp`, the underlying vnode (`T`) for `/tmp`
will have its `v_vfsmountedhere` set to 0xffffffff. A lookup into `/tmp`
will search the process's namespace mount list, looking for a vfs that matches
`vfs_vnodecovered` to `T`. Once found, that vfs will be returned.

As another example, if we have two different processes in two different
namespaces, and one of them has unmounted `/tmp` locally, the underlying vnode
(`T`) for `/tmp` will have its `v_vfsmountedhere` set to 0xffffffff. A lookup
into `/tmp` will search the process's mount list looking for a vfs that matches
`vfs_vnodecovered` to `T`. For the namespace which still has `/tmp` mounted,
the vnode match on `T` will succeed and the correct vfs will be returned.
For the namespace which unmounted `/tmp`, there will be no matching entry in
its mount list, so there is no vfs transition and NULL is returned. The lookup
will stay in the vfs in which `T` resides.

Note that within `vn_mountedvfs` we do not have to check the `mnse_flags` to
determine how to traverse a mount. If the mount is in our list, we follow it.
Otherwise it will not be in our list and we stay on the underlying vfs.

XXX TBD overlay mounts

#### vn_ismntpt

This function also uses `vp->v_vfsmountedhere`. It must essentially work the
same way as `vn_mountedvfs`, in terms of checking the namespace list, to
determine if the vnode is a mountpoint in the current namespace.

#### traverse

This function does the work of transitioning from a vnode underlying
a mountpoint to the vnode of the root of the filesystem mounted there.
It also loops to handle overlay mounts. It uses `vn_mountedvfs` so it will
work as-is under the new design.

#### Misc. other functions

There are various other functions, such as `localpath` or `zone_set_root`,
which use `vn_ismntpt` and `traverse`, so these should work as-is.

### Tracking MS\_SHARED, MS\_SLAVE and MS\_PRIVATE per namespace and mount

The `mnse_flags` member tracks if the mountpoint is `MS_SHARED`, `MS_SLAVE`
or `MS_PRIVATE` private within the namespace. This, along with the generation
number (`mnse_gen`), impacts propagation for future mount operations within the
namespace.

In addition to tracking the flag value, the key behavior here is that whenever
a mountpoint within a namespace is changed from `MS_SLAVE` (or `MS_PRIVATE`) to
`MS_SHARED`, then we increment the generation number on that mountpoint.

To reiterate some earlier points, if a mounpoint has been locally unmounted,
then it will no longer be in the process's namespace list at all. Also, within
`vn_mountedvfs` we do not have to check the `mnse_flags` to determine how to
traverse a mount.  If the mount is in our list, we follow it. Otherwise it will
not be in our list and we stay on the underlying vnode.

#### Syscall interface

The `mount` syscall must be updated to handle `MS_SHARE`, `MS_SLAVE` and
`MS_PRIVATE` changes to existing mountpoints. This mount operation only
effects the calling process's namespace, and will change the `mnse_flags`
value (and potentially also `mnse_gen`) in the namespace's mountpoint entry.

#### Flag and generation example

The following example shows how the `mnse_flags` and `mnse_gen` members
are handled during the setup of a new `PrivateTmp` namespace

 1. The original namespace has all mounts `MS_SHARED`; the `mnse_flags` on each
entry is marked as `shared`, the generation number (`mnse_gen`) on each entry
is 0.
 2. A new namespace is created, all current mount entries are duplicated for the
process. On the duplicated entries the `mnse_flags` and `mnse_gen` members are
the same as the original (i.e. `shared` and 0).
 3. The new namespace changes a mount entry to `MS_SLAVE`; the `mnse_flags` for
this mountpoint changes to `slave`.
 4. The new namespace changes its mount enries back to `MS_SHARED`; the
`mnse_flags` changes to `shared` and the generation is incremented on the
entry (i.e. it goes to 1 in the second namespace to be created).

If a namespace changes a mountpoint to `MS_PRIVATE`, `mnse_flags` is set to
`private`.

### Tracking mount changes across namespaces

When performing a mount operation within a namespace, we must first find the
lowest parent mount in the namespace mount list. This mount will determine how
to behave. For example, if we're mounting on `/a/b/c/d`, we must look at `d`,
then `c`, then `b`, then `a`, then `/`, until we hit a mountpoint in our
namespace. The subsequent mount operation behavior is dictated by the
`mnse_flags` and `mnse_gen` members on the mountpoint that we just found.

Any mount operation that takes place under a portion of the hierarchy which
is `shared` will have to propagate that change into all of the related
namespaces. This propagation is controlled by the `mnse_flags` and `mnse_gen`
members.

This is best described with some examples.

For the first example, assume a configuration where a new `B` namespace
recursively updates all of its mounts to `MS_SLAVE`.
The diagram shows the resulting namespace hierarchy with the
`mnse_flags` and `mnse_gen` values for the `/tmp` mountpoint on the side of
each namespace (i.e. 'sh' is `shared`, 'sl' is `slave`, and the generation is
0 on both).
```
             +---+
             | A | sh:0
             +---+
               |
               |
             +---+
             | B | sl:0
             +---+
```
This configuration means that anything mounted under `/tmp` by `A`
must be visible in `B`, but anything mounted under `/tmp` by `B`
must only be visible in `B`.

When a mount operation is initiated in `A`, we do the following
sequence of steps (e.g. `A` is mounting `/tmp/foo`):
 1. `A` finds the parent mount in it's namespace mount list (i.e. `/tmp`) and
determines if that mountpoint is `shared`. It is.
 2. Next we find the highest namespace in the hierarchy where `/tmp` is shared
and has the same generation number (0). There is no higher namespace.
 3. We actually mount `/tmp/foo`.
 4. Starting from `A` we iterate down the tree to every child which has
a `shared` or `slave` entry for `/tmp` in its mount list and which has the
same generation number (0). We add an entry for `/tmp/foo` into that
namespace's mount list.

When a mount operation is initiated in `B`, we do the following
sequence of steps (e.g. `B` is mounting `/tmp/bar`):
 1. `B` finds the parent mount in it's namespace mount list (i.e. `/tmp`) and
determines if that mountpoint is shared. It is a `slave`, so its not shared.
 2. We actually mount `/tmp/bar`.
 3. Since `/tmp` is not shared in `B` we only need to add an entry for
`/tmp/bar` into `B`'s namespace mount list.

For the second example,
assume a configuration such as setup by `PrivateTmp`, where a new `B`
namespace recursively updates all of its mounts to `MS_SLAVE`, then mounts
a new `/tmp`, then recursively changes its mount hierarchy to `MS_SHARED`.
Following that, the `C`, `D`, `E` and `F` namespaces are created by child
processes. The diagram shows the resulting namespace hierarchy with the
`mnse_flags` and `mnse_gen` values for the `/tmp` mountpoint on the side of
each namespace (i.e. 'sh' is `shared` and the generation is 0 on `A`, 1 on
the rest).
```
             +---+
             | A | sh:0
             +---+
               |
               |
             +---+
             | B | sh:1
             +---+
             /    \
            /      \
           /        \
        +---+      +---+
        | C | sh:1 | D | sh:1
        +---+      +---+
        /    \
       /      \
      /        \
    +---+      +---+
    | E | sh:1 | F | sh:1
    +---+      +---+
```
This configuration means that anything mounted under `/tmp` by `B`, `C`, `D`,
`E` or `F` must be visible in all of those namespaces. Depending on which
namespace performs the mount, it must propagate the mount entry both up, and
down, the tree. For example, if `C` mounts `/tmp/foo`, then that entry must
propagate into the mount lists for `B`, `D`, `E` and `F`.

To handle this, when a mount operation is initiated, we do the following
sequence of steps (e.g. `C` is mounting `/tmp/foo`):
 1. `C` finds the parent mount in it's namespace mount list (i.e. `/tmp`) and
determines if that mountpoint is `shared`. It is.
 2. Next we find the highest namespace in the hierarchy where `/tmp` is shared
and has the same generation number (1). Searching up the list we find `B`,
but when we get to `A` the generation number is lower, so we know `B` is the
top-level of our shared hierarchy for `/tmp`.
 3. We actually mount `/tmp/foo`.
 4. Starting from `B` we iterate down the tree to every child which has
a `shared` or `slave` entry for `/tmp` in its mount list, and which has the
same generation number (1). We add an entry for `/tmp/foo` into that
namespace's mount list.

#### Locking

Given the description above, it is clear that all of the namespaces sharing the
same view of a mount must be updated together. The `mntns_lock` is used to manage
this.

During a lookup, the code must take a read lock on `mntns_lock`. This should
normally not cause any performance impact, since we can have many readers
with no contention.

During a mount operation, the code must first take a write lock on all of the
namespaces which will be updated. Once that is done, the mount can actually
occur, then all of the namespaces can be updated, and finally the write lock
can be dropped on all of the namespaces. A mount operation which is only
changing the `mnse_flags` on a mount entry must take the write lock.

A write lock must also be take when a child namespace is being created or
destroyed, since the `mntns_children` member is being updated.

For reference, the following counts were collected on `traverse` vs.
`lookuppnvp` calls for 60 seconds on the compute nodes in `east-3b`.
The percentage ranges from ~50% to over 100%.
```
traverse   64292
lookuppnvp 70406

traverse   60917
lookuppnvp 72152

traverse   79490
lookuppnvp 60526

traverse   18211
lookuppnvp 21363

traverse   38085
lookuppnvp 53405

traverse   7002
lookuppnvp 9226

traverse   62691
lookuppnvp 56240

traverse    57357
lookuppnvp 127795
```

### Debugging support

We will need basic debugging support for this new construct. At a minimum
we should have an mdb walker which will walk the list of mounts for a process.
We probably also want a dcmd to print a process mount list in a similar way
to `::fsinfo`.

We may want a new `pns` tool which can print the mount information for a process
at the command line. This tool's arguments for mount namespaces should be
parameterized so it can work with future namespaces (e.g. pid) as support for
additional namespaces is added.

There might be other debugging tools which may also be necessary. These can be
added as the need is identified.

### LX /proc support

The work to extend LX `/proc` will need to be done. The `/proc/self/mountinfo`
file will need to be enhanced to report the correct information about the
mounts within the namespace. This should follow the description in the
Linux `proc(5)` manpage.
