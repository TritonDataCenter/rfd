---
authors: Jerry Jelinek <jerry.jelinek@joyent.com>, Patrick Mooney <patrick.mooney@joyent.com>
state: abandoned
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

## Background

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

There are three mount flags on a mountpoint that will interact with a mount
namespace.
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
expected within the chroot-ed process (and its children) with no changes to the
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
to propagate into all of the affected process-related mount lists.
Perhaps some form of chaining could be used to manage these relations.
Slave and private mount operations within the child would only effect that
process's mount list.

## The Selected Approach

Given the identified alternatives, it is clear that the first option is not
very interesting, so the choice comes down to the second and third options.
Either one could be made to work, but in the end we have chosen to pursue
the third option (*Have a process-oriented view of mounts*). This option is
more intrusive in the system to start with, but it appears to lead to a
cleaner final solution in the end. This should pay off in the long term
with a less cluttered architecture and code that is easier to understand. It
should should also reduce the number of unusual corner cases that must be
dealt with.

## Detailed Design For A Process-Oriented View Of Mounts

### Overview

The existing global mount list of vfs's which is chained off of `rootvfs`
will continue to be maintained.

The `proc_t` structure will be extended to add a pointer to the mount namespace
for that process. When a process forks, the new child will point to the same
mount namespace. The namespace must be reference counted so it can be removed
when the last process referencing the namespace has exited.

We must be able to quickly determine which mounts are visible from a process's
namespace. This is needed for various reasons, such as `/proc/self/mounts`
as used in lx. Within the namespace will be a list of mounts that are visible
to that namespace.

The `vfs_t` structure will be extended to include a list of namespaces for
which the mount is visible. The `vfs_t` structure will also be extended so
that we can support a list of different filesystems mounted on the same
mountpoint (from different mount namespaces).

In summary, we'll have pointers from a mounted filesystem `vfs_t` to all
of the namespaces which can 'see' that mount, and we'll also have pointers
from all of the namespaces to the `vfs_t` mounts that those namespaces
can 'see'.

### New and Modified Structures

Because a `vfs_t` entry can be visible in many different namespaces, we cannot
use an approach with embedded `vfs_t` list pointers like we currently do with
`vfs_zone_next` and `vfs_zone_prev`. Instead, we'll define a namespace-specific
vfs list structure which would point to a single vfs entry. This structure
will also contain flags for how the vfs is managed by this specific namespace.
Instead of an actual list, we use an AVL tree indexed by the `vnode_t` on which
the vfs is mounted. This allows for fast traverse during lookup and is
described in detail in *Handling Mountpoints During Lookup*.

    typedef structure mntns_ent {
        vnode_t       *mnse_vnodep; /* mountpoint vnode */
        uint_t        mnse_flags;   /* mointpoint flags */
        vfs_t         *mnse_vfsp;   /* pointer to the vfs visible to the NS */
        struct mntns_ent *mnse_underlayp; /* underlay mount */
        avl_node_t    mnse_avl;
    } mntns_ent_t;

The `mnse_flags` member is described in *Mount Propagation*. The
`mnse_underlayp` member is described in *Overlay Mounts*.

The namespace structure referenced by the `proc_t` will look like this:

    typedef structure mntns {
        uint_t       mntns_cnt;        /* reference count */
        krwlock_t    mntns_lock;       /* lock protecting members */
        avl_tree_t   *mntns_mounts;    /* avl tree of mounts visible to NS */
    } mntns_t;

The `proc_t` will get a new pointer to the mount namespace for that process.

    mntns_t	*p_mntnsp;

The `vfs_t` is modified to hold a list of namespaces which can "see" that
mount. In addition, the `vfs_t` is modified to support a chain of vfs's
on the same mountpoint. For example, if two different namespaces have two
different mounts on `/tmp`, the first mount is the one referenced by
the `v_vfsmountedhere` on the underlying vnode. The second mount is chained
off of the first `vfs_t`.

    typedef structure vfsns_ent {
       list_node_t    vfsns_link;
       mntns_t        *vfsns_mntnsp; /* pointer to a NS seeing this mount */
    } vfsns_ent_t;

Within `vfs_t`:

    list_t       *vfs_nslist;     /* list of vfsns_ent_t seeing this mount */
    struct vfs   *vfs_mnt_next;   /* next VFS on the same mntpnt */
    struct vfs   *vfs_mnt_prev;   /* prev VFS on the same mntpnt */

### Maintaining the two mount lists

The `vfs_t` and `mntns_t` mount lists are updated during a `mount` or `unmount`
syscall.

It is helpful to reiterate the following points:
 1. A true local filesystem can only be mounted once. We must use `lofs`,
or something like it, if we want a filesystem to appear in more than one place.
That will appear in the mount list just as any other `lofs` mount. A pseudo
filesystem, such as `tmpfs`, can have different `vfs_t`'s mounted at the same
time.
 2. Setting up a new namespace doesn't change where/how the original
filesystems are mounted. We can only change visibility of future mount activity
for our namespace.

A high-level summary of mounting/unmounting behavior, in the absence of
namespace usage within a zone, is that things should behave very much as they
do currently with our two-level global zone/non-global zone mount lists.
We start by discussing how things will work under this scenario before going
on to extend the behavior for full `mount` namespace usage as needed by lx.

#### Removing zone.zone_vfslist

Given the new process-oriented namespace, the existing zone-oriented mount
list in `zone_vfslist` should be removed. When `zoneadmd` readies a zone, the
zone's namespace can be maintained on the `zsched` process. That namespace
would be inherited by all child processes within the zone. See
*Using a Mount Namespace Per Zone* for a detailed breakdown of how the
mount namespace design willl interact with zones.

#### The Controlling Mount

A key idea within the Linux mount namespace design is that a mount operation's
visibility across namespaces is controlled by the `mnse_flags` flags on the
mountpoint under which the new mount is occurring. This is discussed in more
detail under
*Tracking MS\_SHARE, MS\_SLAVE and MS\_PRIVATE Per Namespace and Mount*.
To keep things simple for now, we simply call this the "controlling mount"
and assume that a new mount should be visible in all of the same namespaces
that the controlling mount is visible in. We'll relax that assumption later
in this design.

Determining the controlling mount is simple. Once we do the lookup for a new
mountpoint, we have a `vnode_t`, so we know its `vfs_t` from the `v_vfsp`.
That `vfs_t` is the controlling mount and we can determine our
namespace-specific mount flags from a match in the `mntns_mounts` AVL tree.

#### Mounting

The calling flow here is:
```
domount (and others) -> vfs_add -> vfs_list_add
```
When a filesystem is first mounted, it continues to be added to the single
mount list off of `rootvfs` during `vfs_list_add`. The `vfs.vfs_next` and
`vfs.vfs_next` pointers continue to be used to maintain this list.

As discussed above in *Removing zone.zone_vfslist*, the vfs is no
longer added to the per-zone list `zone_vfslist`, but is instead added to the
process's namespace.

`vfs_list_add` will continue to use `vfs_list_lock` to lock access to the
master list. It will also need to use the `mntns_lock` to lock the namespace
list.

During the mount, we determine the `vfs_t` of the controlling mount. All of
the namespaces on the controlling mount are copied into the namespace
list (`vfs_nslist`) on the new mount. We take a `vfs_hold` for each namespace.
We also update each of those namespaces to add the new mount entry into the
namespace's `mntns_mounts` AVL tree, using the mountpoint vnode as the key.

A special consideration is that different namespaces can have different vfs's
mounted at the same mountpoint. For example, a common use case is that
different namespaces will mount a *private tmp* onto `/tmp`.

When the first namespace performs a mount, the vnode is not a mountpoint, but
will become one after the mount. The `v_vfsmountedhere` on the mountpoint will
reference the newly mounted `vfs_t`. Later, if a different namespace performs
a mount onto the same mountpoint, we must chain the new vfs onto the one that
is already mounted. We use the new `vfs_mnt_next` and `vfs_mnt_prev` pointers
to manage this.

XXX vfs_list (sync list) unused?

XXX confirm vfs_hash is ok. Only used by getvfs() for fsid lookup (NFS server
only?)

#### Unmounting

The calling flow here is:
```
dounmount -> vfs_remove -> vfs_list_remove
```
When a filesystem is unmounted, the namespace reference is removed from
the `vfs_nslist`. The entry is also removed from the namespace's `mntns_mounts`
AVL tree. When we remove the namespace from `vfs_nslist`, we also perform a
`vfs_rele`. The normal (final) unmounting occurs when the reference
count on the vfs drops to 0.

Unmounting is made more complex due to the vfs chain on a mountpoint. When
the final unmount of a vfs occurs, it is possible that the vfs is the first
element in the list (`v_vfsmountedhere`) on the mountpoint, or it might be
someplace else in the list. The list must be managed properly so that the
vnode continues to be a mountpoint for any remaining filesystems mounted there.

### Handling Mountpoints During Lookup

The lookup code path is the central point where paths resolve into vnodes.
Everything funnels through `lookuppnvp()`. This function handles traversing
across mountpoints during lookup. With `mount` namespaces we will still have
a mountpoint at each relevant location in the filesystem tree, but not every
mountpoint will be visible, or resolve the same way, for every process. For
example, with a local mount under a `MS_SLAVE` mountpoint, a process within the
namespace must traverse that mount, but a process outside the namespace must
not.

For background, the following counts were collected on `traverse` and
`lookuppnvp` calls for 60 seconds on the compute nodes in `east-3b`.
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

This section describes the updated lookup handling for the new
process-oriented namespace mount list.

The following functions are involved in mountpoint traversal.

#### vn_mountedvfs

This function returns the `vfs` mounted on a vnode (if any). The function
currently uses `vp->v_vfsmountedhere` to get the `vfs_t` of the filesystem
mounted on the vnode. It returns NULL if the vnode is not a mountpoint.

Under the new design, there can be one or more filesystems mounted on the same
vnode. The namespace's view will control which vfs to use. In order to keep
lookup as fast as possible, the process uses its namespace's `mntns_mounts`
AVL tree to determine the mounted vfs. We use the vnode to determine what is
mounted on this mountpoint within the namespace. We either get a `vfs_t`,
which we then traverse into, or we have no entry in `mntns_mounts`, which
means we stay on the vnode, never traverse, and stay on the underlying vfs.

We must take a read lock on the `mntns_lock` while accessing `mntns_mounts`.

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

### Overlay Mounts

There are some special considerations needed for overlay mounts under this
design.

Because we want lookup traversal to be fast by using the mountpoint vnode as
the key on the namespace's `mntns_mounts` AVL tree, we can only have a single
entry in the tree for that mountpoint. If an overlay mount is done, then
we remove the original `mntns_ent_t` entry from the AVL tree, add the new
entry, and store the old entry pointer in the `mnse_underlayp` element of the
new entry. During unmount, we reverse this operation.

From the `vfs_t` side, we no longer stack overlay mounts on a mountpoint, but
instead can use the chain of mounts (`vfs_mnt_next` and `vfs_mnt_prev`). There
is some overlay code cleanup we can perform once this project is complete.

### Creating a New Namespace

When a new namespace is created, we must duplicate the original namespace's
`mntns_mounts` AVL tree into the new namespace. We must also add the new
namespace into each `vfsns_mntnsp` list for each vfs that the new namespace
can 'see'. We have the pointers in the `mntns_mounts` AVL tree to access
each of those directly.

Because no actual changes to the mounted filesystems has occured, the master
mount list is not updated to add new entries, but we must increment the
reference count (via `vfs_hold`) on each vfs.

We must also decrement the reference count (`mntns_cnt`) on the original
namespace.

### Deleting a Namespace

When a process exits, it decrements the reference count (`mntns_cnt`) on its
associated namespace. When the reference count on a namespace drops to 0,
the namespace is deleted. This involves removing the namespace reference from
each vfs `vfsns_mntnsp` list. We use the `mntns_mounts` AVL tree to find each
vfs. When we remove the namespace reference, we always do a `vfs_rele`.
This may result in filesystems being unmounted.

We also cleanup the namespace itself, since nothing can access it any further.

### Tracking MS\_SHARED, MS\_SLAVE and MS\_PRIVATE Per Namespace and Mount

Up to this point in the design, we have made a simplifying assumption that all
new mounts will show up in all of the namespaces on the controlling mount.

In fact, as noted previously in *Mount Namespace Overview*, the mount flags on
the controlling mount will dictate how new mounts and unmounts propagate into
related namespaces.

The `mnse_flags` member tracks if a mountpoint is `MS_SHARED`, `MS_SLAVE`
or `MS_PRIVATE` within the namespace. When this is the controlling
mount, it impacts propagation for future mount operations within, and across,
namespaces.

### Syscall interface

The `mount` syscall must be updated to handle setting the `MS_SHARE`,
`MS_SLAVE` and `MS_PRIVATE` flags on existing mountpoints. This mount
operation only effects the calling process's namespace, and will change
the `mnse_flags` value in the namespace's mountpoint entry.

#### Mount Propagation

Any mount operation that takes place under a controlling mount which is
`shared` will have to propagate that change into all of the related namespaces.

This is best described with some examples.

For the first example, assume namespace `A` has a shared mount on `/tmp`.
Namespace `B` also has the same shared mount. Namespace `C` has changed its
`/tmp` mount to be a slave. The table shows the resulting `mnse_flags`
value for the vfs on the `/tmp` mountpoint on each namespace.
```
   NS | controlling mount | flags
    A | tmp0 vfs          | shared
    B | tmp0 vfs          | shared
    C | tmp0 vfs          | slave
```
This configuration means that anything mounted under `/tmp` by `A`
must also be visible in `B` and `C`, but anything mounted under `/tmp` by `C`
must only be visible in `C`.

When a mount operation is initiated in `A`, we do the following sequence of
steps (e.g. `A` is mounting `/tmp/foo`):
 1. `A` finds the controlling mount vfs (i.e. `tmp0`; the vfs visible on `/tmp`)
and checks `mnse_flags` in its namespace to determine if that mountpoint
is `shared`. It is.
 2. We mount `/tmp/foo`.
 3. We iterate all of the namespaces on the controlling mount vfs (`tmp0` which
is visible in namespaces `A`, `B` and `C`) and add an entry for `/tmp/foo` into
each namespace's mount AVL tree. We also add those namespaces to the list of
namespaces visible on the vfs mounted on `/tmp/foo`.

This behavior is what has been described previously in the design.

When a mount operation is initiated in `C`, we do the following sequence of
steps (e.g. `C` is mounting `/tmp/bar`):
 1. `C` finds the controlling mount vfs (i.e. `tmp0`; the vfs visible on `/tmp`)
and checks `mnse_flags` in its namespace to determine if that mountpoint
is shared. It is a `slave` within this namespace.
 2. We mount `/tmp/bar`.
 3. Since `tmp0` is not shared in `C`, we only add an entry for `/tmp/bar`
into `C`'s namespace mount AVL tree, and add `C` to the list of namespaces
visible on the vfs mounted on `/tmp/bar`.

For our second example, assume a configuration such as setup by `PrivateTmp`,
where namespace `C` recursively updates all of its mounts to `MS_SLAVE`, then
mounts a new vfs on `/tmp`, then recursively updates all of its mounts
to `MS_SHARED`. This means that we have a chain of vfs's at the `/tmp`
mountpoint. We have removed `C` from the `tmp0` vfs and added it to the
`tmp1` vfs.
```
   NS | controlling mount | flags
    A | tmp0 vfs          | shared
    B | tmp0 vfs          | shared
    C | tmp1 vfs          | shared
```
This configuration means that anything mounted under `/tmp` by `A` or `B` 
must only be visible in `A` or `B`. Anything mounted under `/tmp` by `C` 
must only be visible in `C`.

When a mount operation is initiated in `B`, we do the following sequence of
steps (e.g. `B` is mounting `/tmp/foo`):
 1. `B` finds the controlling mount vfs (i.e. `tmp0`; the vfs visible on `/tmp`)
and checks `mnse_flags` in its namespace to determine if that mountpoint
is `shared`. It is.
 2. We mount `/tmp/foo`.
 3. We iterate all of the namespaces on the controlling mount vfs (`tmp0` which
is visible in namespaces `A` and `B`) and add an entry for `/tmp/foo` into each
namespace's mount AVL tree. We also add those namespaces to the list of
namespaces visible on the vfs mounted on `/tmp/foo`.

When a mount operation is initiated in `C`, we do the following sequence of
steps (e.g. `C` is mounting `/tmp/bar`):
 1. `C` finds the controlling mount vfs (i.e. `tmp1`; the vfs visible on `/tmp`)
and checks `mnse_flags` in its namespace to determine if that mountpoint
is `shared`. It is.
 2. We mount `/tmp/bar`.
 3. We iterate all of the namespaces on the controlling mount vfs (`tmp1` which
only has namespace `C`) and add an entry for `/tmp/bar` into `C`'s namespace
mount AVL tree. We also add `C` to the list of namespaces visible on the vfs
mounted on `/tmp/bar`.

A `private` controlling mount is similar, since only the single namespace
is involved.

#### Locking

Given the design, it is clear that multiple locks must be taken during
mount/umount. The global `vfslist` lock that is taken during mount and
umount operations (see `vfs_list_lock`, `vfs_list_read_lock' and
`vfs_list_unlock`) can be used to manage the updates to the new vfs members.

During a lookup, the code must take a read lock on `mntns_lock`. This should
normally not cause any performance impact, since we can have many readers
with no contention.

During a mount operation, the code must first take a write lock on all of the
namespaces which will be updated. Once that is done, the mount can actually
occur, then all of the namespaces can be updated, and finally the write lock
can be dropped on all of the namespaces. A mount operation which is only
changing the `mnse_flags` on a mount entry must also take the write lock, in
case a separate mount operation, which needs the controlling mount, is underway.

A write lock must also be taken when a new namespace is being created or
destroyed, since the `mntns_mounts` AVL list of the previous namespace is
being updated.

### Debugging support

We will need basic debugging support for this new construct. At a minimum
we should have an mdb walker which will walk the list of mounts for a process's
namespace. We probably also want a dcmd to print a process mount list in a
similar way to `::fsinfo`.

We may want a new `pns` p-tool which can print the mount information for a
process at the command line. This tool's arguments for mount namespaces should
be parameterized so it can work with future namespaces (e.g. pid) as support
for additional namespaces is added.

There might be other debugging tools which may also be necessary. These can be
added as the need is identified.

### LX /proc support

The work to extend LX `/proc` will need to be done. The `/proc/self/mountinfo`
file will need to be enhanced to report the correct information about the
mounts within the namespace. This should follow the description in the
Linux `proc(5)` manpage.

## Using a Mount Namespace Per Zone 

The existing zone-oriented mount list in `zone_vfslist` will be removed.
When `zoneadmd` readies a zone, the zone's new namespace will setup on
the `zsched` process. That namespace will be inherited by all child processes
within the zone. A zone's usage of a mount namespace will be somewhat different
from the typical Linux usage. Except for lx instances which actually use
multiple mount namespaces within the zone, each zone will only have a single
namespace shared by all processes within the zone.

The act of creating the first namespace for a zone can be somewhat different
from the behavior described earlier in the design. We can provide an
alternate function for zone mount namespace creation.

When the namespace is created, we do not need to duplicate any of the global
zone mounts, since the zone mounts are completely built up for the new zone. In
terms of the namespace, the zone `ready` transition will create an entirely
new mount tree that behaves like `MS_SHARED`, but because the zone is in a
chroot-ed environment, all subsequent in-zone mount operations are always
relative to the zone's root. The global zone can see any mounts the non-global
zone has made. Any mounts made by the global zone under the zone's
hierarchy also take effect for the zone, as usual when under a `MS_SHARED`
controlling mount.
