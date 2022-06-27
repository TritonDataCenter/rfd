---
authors: Dave Eddy <dave@daveeddy.com>, Josh Wilsdon <jwilsdon@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent, Inc.
-->

# RFD 39 VM Attribute Cache (vminfod)

Introduction
------------

### The "VM" abstraction

SmartOS is a hypervisor that can manage many different types of VMs.  A VM, in
the SmartOS world, is an abstraction that contains at least:

 - An Illumos zone (xml file + index entry + kernel state)
 - One (or more) ZFS datasets
 - A set of resource controls

But in SDC also always contains:

 - Networking (etherstub, vnic, etc.)
 - Tags and Metadata

There are different flavors of these zones including:

 - SmartOS (joyent and joyent-minimal brand)
 - LX (lx brand)
 - KVM (kvm brand which utilizes Qemu and HVM)
 - BHYVE (bhyve brand which uses HVM via bhyve)
 - docker (can be either LX or SmartOS but contain some additional properties)

All of these are for the purposes of this discussion "VMs".

In SmartOS a VM is usually represented by a "VM Object" which is a JSON
formatted object that represent the given VM. Modifications to VMs are done
through partial VM Objects (representing just the properties to be changed).

### A bit of background

In SDC 6.5 and earlier we had an API named
[MAPI](https://apidocs.joyent.com/sdcapidoc/mapi/) which was the primary API
interface to the SDC DC. It had endpoints for /vms which allowed you to load
information about VMs and perform actions (shutdown, startup, etc.) on these
VMs.

When you loaded the list of VMs from MAPI or when you went to perform an action
and MAPI needed to first check whether a VM existed or not, MAPI would check its
own SQL database. It would not actually check the CNs. The agents (specifically
[heartbeater]) were responsible for keeping the information in MAPI up-to-date.
Unfortunately this often failed and MAPI's view of the world would regularly
diverge from the actual system.

Sometimes VMs would exist in MAPI that had been destroyed manually by an
operator on the CN. Sometimes VMs would exist on a CN that MAPI had somehow
either lost track of or never known about. Since MAPI thought it was the one
with the correct view of the system, this split-brain caused a large number
of problems which lead to some of the design decisions that were made with
SDC7. One of these in particular was the change to having the ultimate source of
truth be the reality that exists on a CN.

With SDC7 the VM functionality was moved to
[VMAPI](https://github.com/TritonDataCenter/sdc-vmapi) which treats the data on the CNs as
the ultimate source of truth and its own data about VMs as merely a cache. When
state is changed on a CN through the APIs, the final state of the VM is reported
back to VMAPI through the agents to the job and written to VMAPI's Moray bucket.
The [vm-agent](https://github.com/TritonDataCenter/sdc-vm-agent) that runs on each CN is
[responsible for keeping VMAPI up-to-date in the face of manual actions](https://github.com/TritonDataCenter/sdc-vm-agent/blob/release-20160609/lib/vm-agent.js#L11-L115)
on the CN which would otherwise be outside the view of the APIs.

Along with the changes to the APIs to manage VMs through VMAPI and have the
ultimate source of truth be the CN, new tools were developed to manage those VMs
on the CNs directly. The primary one that's relevant here is
[vmadm](https://github.com/TritonDataCenter/smartos-live/blob/master/src/vm/man/vmadm.1m.md).

### The problem

When SDC APIs are used, all changes made to VMs will go through vmadm. If
changes were only allowed through vmadm, `vmadm` itself could store a consistent
view of a VM and update that view whenever it made changes. This is not
possible however, because SDC does not prevent operators from logging into CNs
and making arbitrary changes with tools other than vmadm.

Since a VM object is made up of many components and each of these components can
be modified by an operator without any notification and possibly even putting
the VM in an invalid state, `vmadm` must load all of the data about a VM every
time it wants to use it.

When an operator runs `vmadm list` for instance, the code in `/usr/vm` (mostly
in this case `/usr/vm/node_modules/vmload`) will reach out to various parts of
the system to create a list of all VMs on the system, typically through forking
userland tools such as `zfs(1M)`, `zoneadm(1M)`, reading files from
`/etc/zones` and `/zones/$uuid/config`, and reading from kstats.

This process can be slow.

Every time a VM's attributes are queried, through `vmadm list`, `vmadm lookup`
or `vmadm get`, all the required data to is queried directly from its source
(e.g. dataset data comes from ZFS and zone config comes from the `/etc/zones`
files). Loading this data can take in the range of hundreds of milliseconds, to
multiple minutes on systems with high load or many VMs or
[many zfs snapshots](https://github.com/TritonDataCenter/smartos-live/pull/151). Because
the rest of SDC relies on `vmadm` as the ultimate source of truth (which in turn
relies on the OS itself) any slowdown here is seen all over the system,
manifesting in long provision times, long VM modification or deletion times,
and generally poor user experience.

If we didn't load this data each time however, an operator could change the
quota for a VM using `/usr/sbin/zfs` and `vmadm` would be operating with an
incorrect quota until it *did* load this data from zfs. And since there's no
current mechanism to notify `vmadm` that something has changed, there's not much
it can do other than assume its environment is entirely hostile and load all the
data it needs from the ultimate source each time. This is true for all
components of a VM object, not just zfs datasets.

`vminfod` will speed this process up immensely by creating a separate process
that will run responsible for querying this data whenever it changes, and
caching it for callers to be able to get the information almost immediately when
they request it.

### `vminfod` - What it is

`vminfod` is two things.  First, it is a daemon that provides read-only access
to this VM abstraction on a given system. Second, it is a cache for this
information, only reaching out to the system when modifications are made - so it
is very fast.  `vminfod` makes this information available over an HTTP
interface to the global zone on port 9090 of 127.0.0.1.

In the new world, any read-only actions with `vmadm` such as `vmadm list`,
`vmadm lookup`, `vmadm get` will be thin wrappers around HTTP requests to
the `vminfod` daemon.  Read-write actions such as `vmadm create`, `vmadm
reboot`, `vmadm update`, etc. by contrast, will still behave in their normal
way by reaching out to the system directly to make the changes requested (e.g.
`vmadm update <vm_uuid> quota=10` does some checks and calls `zfs set quota=10g`
on the zoneroot dataset).  In addition to making the change however, these
read-write actions will now "block" on `vminfod`, and wait for the changes to
be reflected before returning to the caller. See the Guarantees/
"Read-after-write consistency" section below for more details.

On top of this static interface for looking up VM information in `vminfod`, there
is a second streaming interface that can be used, that will emit an event
anytime an update is done on the system (whether the source of the change was
`vmadm` or not).  To be specific, there is an `/events` endpoint that will remain
open when connected to, and send newline-separated JSON whenever a change to
the system is made - for example when a VM is created or deleted, or a property
of an existing VM is modified.

### History

Originally conceived soon after `vmadm` was created, work was finally started on
this project in 2014 by [Josh Wilsdon](https://github.com/joshwilsdon).
Unfortunately due to unrelated issues the project stalled but was picked up
again from outside Joyent by [Tyler Flint](https://github.com/tylerflint) who
moved the project far enough ahead that it worked for his requirements and made
a significant improvement to his systems' performance. There was still work
required to make it a general-purpose SmartOS feature that would work for all
SmartOS users and for all the use-cases of SDC. Most recently,
[Dave Eddy](https://github.com/bahamas10) has been the primary engineer at
Joyent working to try complete the remaining work required to get this into
SmartOS master.

The main project ticket is here https://smartos.org/bugview/OS-2647

### Project design goals

#### Event driven

Wherever possible vminfod should update VM state based on the receipt of events.
The goal being to try to update the VM object cache as soon after events occur
as possible. The primary types of events that will be watched are:

 - sysevents - `sysevent(1M)` is used to see relevant ZFS and Zone events
 - file changes - `fswatcher.c` (in this project) is used to watch files
   associated with any given VM for modifications

The fswatcher tool uses event ports to watch all files associated with VMs and
directories where additional files could be created so that any files that might
change in relation to a VM will result in an event. Files at this point include:

Globally

1. `/tmp/.sysinfo.json`

Per VM

1. `/etc/zones/<uuid>.xml`
2. `/zones/<uuid>/lastexited`
3. `/zones/<uuid>/config/tags.json`
4. `/zones/<uuid>/config/routes.json`
5. `/zones/<uuid>/config/metadata.json`

If a file changes (including creation or deletion), the in-memory VM object
will be updated for the appropriate VM(s).

The `sysevent` tool receives sysevent messages from the kernel. When a zone
changes state an event is emitted with the old and new state. When a zfs
filesystem is created or modified (anything that will result in a `zpool
history` change) a zfs event should be emitted. Unfortunately however,
sysevents are not reliable from a consumer's perspective.  This is because
there's a fixed-size queue for events in the kernel and once that's full
messages will be dropped at the source. This means as a consumer, even if you're
reading events as fast as you receive them, you cannot know whether you have
received all events.

In order to work around the fact that events may be lost without notification,
vminfod must periodically scan for changes in these watched components. When
unexpected modifications are detected, the VM objects can be updated
accordingly. We can also log this situation in order to alert the operator that
events are being lost which generally means some other tool is having a problem.

If there is an read-write action (e.g. a VM stop) waiting on the cache being
updated and an event is lost, this will mean the action will take longer than
usual (because of the polling interval) but it still can complete and
correctness is maintained.

#### Transparent

When `vminfod` is working, you shouldn't even know it is there.  Any tools
or code that uses `VM.js` or `vmadm` should benefit from the use of `vminfod`
without having to consider it.

It is a bug with `vminfod` if any existing tools break because of `vminfod`,
or if any new code is written with considerations specifically for `vminfod`
except where this new code is taking advantage of vminfod-specific features such
as the event notifications or using vminfod to load VM objects without calling
`vmadm get`.

Guarantees
----------

### Disableability

When the vminfod daemon is disabled, the system should be able to continue to
perform all actions with information looked up directly from the system. I.e.
`vmadm` must be able to fall back to loading the data directly. This way if there
are critical bugs found in vminfod, it can be disabled until such time as these
bugs are fixed. Once confidence in vminfod has been achieved we can consider
phasing this requirement out in order to simplify the implementation.

**Update:**  This constraint was dropped due to how deeply into the
implementation of the system vminfod has become as its been developed - once
vminfod is enabled a node it can not be disabled without rebooting a new
platform, or LOFS mounting a lot of files and restarting a lot of services.

However, there is no "upgrade" required for vminfod to work.  Meaning, if a
vminfod platform is rolled out to a node, and then sometime later rolled back,
the node will work the same before vminfod was introduced and after it was
removed.

### Read-after-write consistency

Any change made successfully through `vmadm` should be visible immediately after
success by any client using `vmadm` to lookup that VM.

As an example, if an operator deletes a VM using `vmadm delete $uuid`,
the `vmadm` process will delete the VM, but will wait for the delete event for
that VM to be fired in `vminfod` before returning success.  This ensures read
after write consistency.  Which means we avoid problems such as 404 on GET
immediately after PUT, or in this case, "VM Not Found" on `vmadm get`
immediately after `vmadm create`.

Actions which are performed *without* `vmadm` will not have this guarantee. If a
change is made with `zonecfg(1M)` or by editing one of the files that makes up a
zone manually, a `vmadm get` immediately following may not include this
information. In these cases the guarantee becomes one of eventual consistency.
Once `vmadm` has received an event or otherwise noticed that this action has
happened it will reflect this change, even if there are other changes in the
interim. The exception is when there are conflicting changes in which case the
most recent state will be returned. A specific example:

 - an action is performed with `/usr/sbin/zfs` that sets the zoneroot quota to
   10g
 - an action is performed with `vmadm` that sets the zoneroot quota to 20g
 - a `vmadm` get is performed on this VM

When the `vmadm get` here occurs the value will be 20g and there will be no
indication to the consumer that the value was ever 10g.

Impact
------

### Public and private interface changes

In the `vminfod` world, the switch to use it should be completely transparent.
This means that, all of the existing `vmadm` commands, and all of the
existing `VM.js` functions will use `vminfod` under-the-hood, but will not
change their usage or signatures.  All of the existing tools, either shipped
with the platform, or from other places, will work without modification,
and will be able to reap the performance benefits of `vminfod`.

Implementation
--------------

### Where this lives

The `vminfod` project most recently lives in one repo.

1. [smartos-live](https://github.com/TritonDataCenter/smartos-live) - majority of the
code here

### History

There used to be vminfod specific code in the `vminfod` branch of
illumos-joyent, but this has since been merged to master:

1. https://github.com/openzfs/openzfs/pull/101

### What makes `vminfod`

At the core of `vminfod`, is a daemon in `/usr/vm/sbin` that is started at boot
in the global zone that extracts all of the necessary information from the system
to create a comprehensive list of VM objects.  The majority of this code lives
in `/usr/vm/node_modules/vminfod` in the following files:

- [client.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/client.js):
vminfod client library, this is used by VM.js and `vmadm`
- [vminfo.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/vminfo.js):
majority of the code for the `vminfod` daemon
- [zonewatcher.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/zonewatcher.js):
thin wrapper around `sysevent-stream.js` to watch for Zone sysevents
- [zpoolwatcher.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/zpoolwatcher.js):
thin wrapper around `sysevent-stream.js` to watch for ZFS sysevents
- [diff.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/diff.js):
a generic JavaScript object diff'ing library, this is used by `vminfod` to
figure out what events to fire when an object is updated
- [fswatcher.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/fswatcher.js):
a JavaScript wrapper for `fswatcher.c` to watch files for modifications
- [queue.js](https://github.com/TritonDataCenter/smartos-live/blob/vminfod/src/vm/node_modules/queue.js)
a JavaScript queueing and serializing module for running tasks asynchronously

### VM properties

VM properties loaded by `vminfod` are the same as those gathered from
[vmload](https://github.com/TritonDataCenter/smartos-live/tree/master/src/vm/node_modules/vmload)
with the current system.  `vminfod` instead uses a series of filesystem and sysevent
watchers to call the `vmload` functions when appropriate to update the VM
objects.

VM Updates and Modifications
----------------------------

In each of the examples below there are 5 distinct steps seen.

1. A change is made on the system
2. An event is fired almost immediately after the change is made
3. `vminfod` catches this event and pauses the work queue
4. `vminfod` gathers the latest information off of the system
5. `vminfod` resumes the queue and proceeds as normal

There is a delay between step 1 and step 3.  During this time, it is possible
for `vminfod` to give out stale data.

For example, if an operator changes the ZFS quota for a VM, there is a delay
(in the realm of milliseconds) before 1. ZFS fires a sysevent of the change
and 2. `vminfod` catching this sysevent and pausing its work queue.  During
this window, doing a `vmadm get $uuid` will have the old value for the ZFS
quota.

### Examples

With the following VM created

``` json
{
  "brand": "joyent-minimal",
  "image_uuid": "01b2c898-945f-11e1-a523-af1afbe22822",
  "alias": "foo"
}
```

    # vmadm create < vm.json
    Successfully created VM 698fed0c-b754-4073-e230-9f37c6b4d79f

### Updating an alias

    # vmadm update 698fed0c-b754-4073-e230-9f37c6b4d79f alias=bar
    Successfully updated VM 698fed0c-b754-4073-e230-9f37c6b4d79f

Relevant log lines from `vminfod`

    [2018-04-11T17:04:44.146Z] DEBUG: vminfod/4670 on headnode: handleFsEvent: pathname: /etc/zones/698fed0c-b754-4073-e230-9f37c6b4d79f.xml (FILE_EXCEPTION,FILE_RENAME_TO)
    [2018-04-11T17:04:44.147Z] DEBUG: vminfod/4670 on headnode: /etc/zones/698fed0c-b754-4073-e230-9f37c6b4d79f.xml modified
    [2018-04-11T17:04:44.147Z] DEBUG: vminfod/4670 on headnode: refreshing zoneData for 698fed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:04:44.157Z] DEBUG: vminfod/4670 on headnode: requesting new vmobj for 698fed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:04:44.158Z]  INFO: vminfod/4670 on headnode: emitting "modify" event, 30 VMs total
    ...

This change is detected from the zone's XML file (in `/etc/zones`) being
modified, which triggers a refresh of the VM's data.

Output from `vminfod events` - these are the events emitted from `vminfod`.

    [17:04:44.158Z] 698fed0c bar modify: alias changed :: "foo" -> "bar"
    [17:04:44.158Z] 698fed0c bar modify: last_modified changed :: "2018-04-11T17:03:53.000Z" -> "2018-04-11T17:04:44.000Z"

### Updating memory

    # vmadm update 698fed0c-b754-4073-e230-9f37c6b4d79f max_physical_memory=128
    Successfully updated VM 698fed0c-b754-4073-e230-9f37c6b4d79f

Relevant log lines from `vminfod`

    [2018-04-11T17:07:37.733Z] DEBUG: vminfod/4670 on headnode: handleFsEvent: pathname: /etc/zones/698fed0c-b754-4073-e230-9f37c6b4d79f.xml (FILE_EXCEPTION,FILE_RENAME_TO)
    [2018-04-11T17:07:37.733Z] DEBUG: vminfod/4670 on headnode: /etc/zones/698fed0c-b754-4073-e230-9f37c6b4d79f.xml modified
    [2018-04-11T17:07:37.734Z] DEBUG: vminfod/4670 on headnode: refreshing zoneData for 698fed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:07:37.745Z] DEBUG: vminfod/4670 on headnode: requesting new vmobj for 698fed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:07:37.746Z]  INFO: vminfod/4670 on headnode: emitting "modify" event, 30 VMs total
    ...

Like the alias change, this change was triggered from the zone's XML file
being updated.

Output from `vminfod events`

    [17:07:37.746Z] 698fed0c bar modify: max_physical_memory changed :: 256 -> 128
    [17:07:37.746Z] 698fed0c bar modify: max_locked_memory changed :: 256 -> 128
    [17:07:37.746Z] 698fed0c bar modify: tmpfs changed :: 256 -> 128
    [17:07:37.746Z] 698fed0c bar modify: last_modified changed :: "2018-04-11T17:04:44.000Z" -> "2018-04-11T17:07:37.000Z"

### Updating a ZFS property

    # vmadm update 698fed0c-b754-4073-e230-9f37c6b4d79f quota=20
    Successfully updated VM 698fed0c-b754-4073-e230-9f37c6b4d79f

Relevant log lines from `vminfod`

    [2018-04-11T17:09:42.201Z] DEBUG: vminfod/4670 on headnode: handleZpoolEvent: dsname: zones/698fed0c-b754-4073-e230-9f37c6b4d79f action: set quota=21474836480
    [2018-04-11T17:09:42.203Z] DEBUG: vminfod/4670 on headnode: executing zfs
        cmdline: /usr/sbin/zfs list -H -p -t filesystem,snapshot,volume -o compression,creation,filesystem_limit,mountpoint,name,quota,recsize,refquota,refreservation,snapshot_limit,type,userrefs,volblocksize,volsize,zoned -r zones/698f
        ed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:09:42.246Z] DEBUG: vminfod/4670 on headnode: zfs[45295] running
    [2018-04-11T17:09:42.254Z] DEBUG: vminfod/4670 on headnode: zfs[45295] exited with code: 0 (1 lines to stdout)
    [2018-04-11T17:09:42.255Z] DEBUG: vminfod/4670 on headnode: refreshing vmobj 698fed0c-b754-4073-e230-9f37c6b4d79f after zfs event
    [2018-04-11T17:09:42.258Z]  INFO: vminfod/4670 on headnode: emitting "modify" event, 30 VMs total

This change is detected using sysevents fired from ZFS core, which
triggers a refresh of the ZFS data for the VM.

Output from `vminfod events` - events emitted from `vminfod` after the VM
abstraction/translation has been applied

    [17:09:42.258Z] 698fed0c bar modify: quota changed :: 10 -> 20
    [17:09:42.927Z] 698fed0c bar modify: last_modified changed :: "2018-04-11T17:07:37.000Z" -> "2018-04-11T17:09:42.000Z"

**NOTE:** because of the nature of the sysevents, the same effect could be seen
with `vminfod` by running the following command instead

    # zfs set quota=20G zones/698fed0c-b754-4073-e230-9f37c6b4d79f

### Adding a nic

``` json
{
    "add_nics": [
        {
            "physical": "net1",
            "index": 1,
            "nic_tag": "external",
            "mac": "b2:1e:ba:a5:6e:71",
            "ip": "10.2.121.71",
            "netmask": "255.255.0.0",
            "gateway": "10.2.121.1"
        }
    ]
}
```

    # vmadm update 698fed0c-b754-4073-e230-9f37c6b4d79f < nics.json
    Successfully updated VM 698fed0c-b754-4073-e230-9f37c6b4d79f

Relevant log lines from `vminfod`

    [2018-04-11T17:12:24.047Z] DEBUG: vminfod/4670 on headnode: handleFsEvent: pathname: /etc/zones/698fed0c-b754-4073-e230-9f37c6b4d79f.xml (FILE_EXCEPTION,FILE_RENAME_TO)
    [2018-04-11T17:12:24.048Z] DEBUG: vminfod/4670 on headnode: /etc/zones/698fed0c-b754-4073-e230-9f37c6b4d79f.xml modified
    [2018-04-11T17:12:24.049Z] DEBUG: vminfod/4670 on headnode: refreshing zoneData for 698fed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:12:24.061Z] DEBUG: vminfod/4670 on headnode: requesting new vmobj for 698fed0c-b754-4073-e230-9f37c6b4d79f
    [2018-04-11T17:12:24.063Z]  INFO: vminfod/4670 on headnode: emitting "modify" event, 30 VMs total

Same as the alias and memory changes, this refresh was caused by the zone's XML
file being modified.

Output from `vminfod events`

    [17:12:24.063Z] 698fed0c bar modify: nics.* added :: undefined -> {"interface":"net0","mac":"b2:1e:ba:a5:6e:71","nic_tag":"external","gateway":"10.2.121.1","gateways":["10.2.121.1"],"netmask":"255.255.0.0","ip":"10.2.121.71","ips":["10.2.121.71/16"]}
    [17:12:24.063Z] 698fed0c bar modify: last_modified changed :: "2018-04-11T17:09:42.000Z" -> "2018-04-11T17:12:24.000Z"

API
---

### GET /ping

Returns a JSON object:

``` json
{
    "ping": "pong"
}
```

### GET /status

Returns a JSON object. See the Management/Health section for details on the
format of this object.

### GET /vms

Returns a JSON representation of all VMs on the system known to vminfod.

### GET /vms/:uuid

Returns a VM Object for the VM with :uuid, or 404 if not found.

### GET /events

This endpoint returns JSON objects as single '\n'-terminated lines. These
objects have at least:

 - date: (timestamp: `new Date()`)
 - type: (string in the set: ['ready', 'create', 'delete', 'modify'])

But will also have:

 - changes: (JSON object) -- for 'modify'
 - vm: (JSON VM object) -- for 'create' and 'modify'
 - zonename: (string: uuid) -- for 'create' and 'delete'

When you first GET /events you should immediately get a 'ready' event which
allows you to know events will be streamed. After that, you'll get an additional
JSON line for each new event with the above properties.

The ready event contains a `vms` property that contains a snapshot of every VM
on the system when the events listener was created, so any modify events seen
thereafter can be applied to the original snapshot for an up-to-date view of
all VMs on the system.

**Note:** For performance reasons, vminfod maintains the full list of VMs in a
pre-serialized way so it can handle requests to `/vms` very quickly.  Because
of this, the `vms` key in the ready event must be JSON parsed, as it contains a
JSON stringified array of objects.

``` json
{
    "type": "ready",
    "date": "2018-04-11T17:28:12.046Z",
    "uuid": "f93c9a88-6c3d-66a9-f5ea-c08068d803a3",
    "vms": "[{...},{...},...]"
}
```

A modify event will look like this:

``` json
{
  "type": "modify",
  "date": "2018-04-11T17:32:30.147Z",
  "zonename": "c4103a37-356c-4898-fe9e-bc61fd3f7ac8",
  "uuid": "c4103a37-356c-4898-fe9e-bc61fd3f7ac8",
  "vm": { ... },
  "changes": [
    {
      "prettyPath": "quota",
      "path": [
        "quota"
      ],
      "action": "changed",
      "oldValue": 10,
      "newValue": 20
    }
  ]
}
```

where `vm` is the full new VM object and `changes.*.action` is one of:
'changed', 'removed', 'added'

Management
----------

### Logging

`vminfod`, like most other services in SmartOS, uses bunyan for logging,
and goes to the default SMF location for logs, ie.

    # svcs -L vminfod
    /var/svc/log/system-smartdc-vminfod:default.log

### Health

`GET /ping` to ensure the daemon is running

``` json
# curl localhost:9090/ping
{
  "ping": "pong"
}
```

`GET /status` to get various stats about the process and current
running tasks

``` json
# curl localhost:9090/status
{
  "pid": 4670,
  "uptime": "54632.555733604s (15.18h)",
  "memory": {
    "rss": 59695104,
    "heapTotal": 31955456,
    "heapUsed": 14105164
  },
  "state": "running",
  "status": "working",
  "numVms": 30,
  "curDate": "2018-04-11T17:16:47.353Z",
  "curTime": "54859.766171547",
  "queue": {
    "now": "54859.766305453",
    "paused": false,
    "idle": true,
    "vasync_queue": {
      "concurrency": 1,
      "npending": 0,
      "nqueued": 0,
      "pending": {},
      "queued": []
    }
  },
  "lastRefresh": "113.349678424s (1.88m)",
  "refreshErrors": [],
  "eventsListeners": {
    "7ab5cb99-18d6-42d1-aa98-f8312bbd68c6": {
      "userAgent": "VM.js events - zoneevent CLI (amon-agent) - headnode/5651 (/usr/vm/sbin/zoneevent)",
      "createdTime": "239.302449140",
      "createdDate": "2018-04-11T02:06:25.203Z",
      "createdAgo": "54620.463900351s (15.17h)"
    },
    "f9f02fc5-92bb-434e-84ed-bebe91c6d7fa": {
      "userAgent": "VM.js events - zoneevent CLI (amon-zoneevents) - headnode/6071 (/usr/vm/sbin/zoneevent)",
      "createdTime": "239.454193578",
      "createdDate": "2018-04-11T02:06:25.355Z",
      "createdAgo": "54620.312155913s (15.17h)"
    },
    "7df1ddfa-6b12-c4bd-ac55-825c8eb31393": {
      "userAgent": "Metadata Agent - VminfodWatcher - headnode/6100 (/usr/vm/sbin/metadata)",
      "createdTime": "239.814803846",
      "createdDate": "2018-04-11T02:06:25.716Z",
      "createdAgo": "54619.951545645s (15.17h)"
    },
    "845fb199-27ae-6918-a086-9a3f4c93aadb": {
      "userAgent": "VM.js events - vmadm CLI - VM Agent - headnode/22159 (/usr/sbin/vmadm)",
      "createdTime": "363.563448727",
      "createdDate": "2018-04-11T02:08:29.262Z",
      "createdAgo": "54496.202900764s (15.14h)"
    },
    "e6553333-d807-cb56-d1a0-af10e1a31427": {
      "userAgent": "VM.js events - zoneevent CLI (net-agent) - headnode/22358 (/usr/vm/sbin/zoneevent)",
      "createdTime": "384.786879657",
      "createdDate": "2018-04-11T02:08:50.486Z",
      "createdAgo": "54474.979469834s (15.13h)"
    },
    "b6548475-8be6-6c4b-e29c-81f64186dc24": {
      "userAgent": "VM.js events - zoneevent CLI (cn-agent) - headnode/22383 (/usr/vm/sbin/zoneevent)",
      "createdTime": "387.299505713",
      "createdDate": "2018-04-11T02:08:52.999Z",
      "createdAgo": "54472.466843778s (15.13h)"
    },
    "3b9c6fb9-8650-47fa-e0ac-a361781d217c": {
      "userAgent": "VM.js events - vmadmd ZoneEvent - headnode/15125 (/usr/vm/sbin/vmadmd)",
      "createdTime": "4836.906985918",
      "createdDate": "2018-04-11T03:23:02.761Z",
      "createdAgo": "50022.859363573s (13.9h)"
    },
    "5bee83ee-c6f6-44ff-ee45-cfd65820b702": {
      "userAgent": "VM.js events - zoneevent CLI (amon-relay) - headnode/24704 (/usr/vm/sbin/zoneevent)",
      "createdTime": "13431.857157978",
      "createdDate": "2018-04-11T05:46:18.010Z",
      "createdAgo": "41427.909191513s (11.51h)"
    },
    "3c74ab1e-e35b-e8a5-dfc0-8c5aaa48d860": {
      "userAgent": "VM.js events - vmadm CLI - headnode/44500 (/usr/sbin/vmadm)",
      "createdTime": "54071.550631206",
      "createdDate": "2018-04-11T17:03:39.110Z",
      "createdAgo": "788.215718285s (13.13m)"
    }
  }
}
```

### CLI tool

**NOTE:** usage subject to change - this command will need to change to act
more like `sdcadm` or `manta-adm` - ie. give something more user friendly
than raw JSON that can be seen by curling the endpoints directly.

There is `vminfo` CLI tool that can be used to query the daemon.
This was mostly written for debugging purposes but has proven itself
sufficiently useful to warrant being shipped with the platform.

    # vminfo ping
    pong

`vminfo ping` is a thin wrapper around `GET /ping`

    # vminfo status [-f]

Get status (`-f` for "full" output).

List of vms on the system (`GET /vms`).  This is what `vmadm list` now uses
under-the-hood.

    # vminfo vms | json -ag uuid state alias | head -5
    25df11d6-70c2-485b-92a6-4ab651e8fd88 running assets0
    874d1b68-88ae-4d69-abf0-39168835d1dc running sapi0
    96f0d23a-6123-477d-8c97-2bd7d4122de9 running binder0
    652b1818-3278-4404-8612-85a94afacba7 running manatee0
    0d8697ae-9877-4aa6-8af9-a9b30f54dc23 running moray0

Get a specific vm (`GET /vms/:uuid`).  This is what `vmadm get` and `vmadm
lookup` now use under-the-hood.

    # vminfo vm 25df11d6-70c2-485b-92a6-4ab651e8fd88 | json alias quota max_physical_memory
    assets0
    25
    128

And finally, watch for events in realtime on the system (`GET /events`).
These commands were run in two separate terminals on the same machine.

    # vmadm create < vm.json
    Successfully created VM c4103a37-356c-4898-fe9e-bc61fd3f7ac8

and

    # vminfo events
    [17:19:03.015Z] c4103a37 foo create
    [17:19:03.230Z] c4103a37 foo modify: zone_state changed :: "configured" -> "incomplete"
    [17:19:03.528Z] c4103a37 foo modify: quota added :: undefined -> 0
    [17:19:03.528Z] c4103a37 foo modify: zfs_root_recsize added :: undefined -> 131072
    [17:19:03.528Z] c4103a37 foo modify: zfs_filesystem added :: undefined -> "zones/c4103a37-356c-4898-fe9e-bc61fd3f7ac8"
    [17:19:03.528Z] c4103a37 foo modify: zpool added :: undefined -> "zones"
    [17:19:04.144Z] c4103a37 foo modify: quota changed :: 0 -> 10
    [17:19:06.810Z] c4103a37 foo modify: zone_state changed :: "incomplete" -> "installed"
    [17:19:08.154Z] c4103a37 foo modify: zone_state changed :: "installed" -> "ready"
    [17:19:08.154Z] c4103a37 foo modify: zoneid changed :: null -> 611
    [17:19:08.154Z] c4103a37 foo modify: last_modified changed :: "2018-04-11T17:19:02.000Z" -> "2018-04-11T17:19:06.000Z"
    [17:19:08.154Z] c4103a37 foo modify: boot_timestamp added :: undefined -> "1970-01-01T00:00:00.000Z"
    [17:19:08.154Z] c4103a37 foo modify: pid added :: undefined -> 0
    [17:19:08.473Z] c4103a37 foo modify: zone_state changed :: "ready" -> "running"
    [17:19:08.473Z] c4103a37 foo modify: boot_timestamp changed :: "1970-01-01T00:00:00.000Z" -> "2018-04-11T17:19:08.000Z"
    [17:19:08.473Z] c4103a37 foo modify: pid changed :: 0 -> 45822
    [17:19:11.953Z] c4103a37 foo modify: state changed :: "provisioning" -> "running"
    [17:19:11.953Z] c4103a37 foo modify: transition_to removed :: "running" -> undefined
    [17:19:11.953Z] c4103a37 foo modify: transition_expire removed :: 1523467442755 -> undefined
    [17:19:11.953Z] c4103a37 foo modify: last_modified changed :: "2018-04-11T17:19:06.000Z" -> "2018-04-11T17:19:12.000Z"

Now, updating the zone

    # vmadm update c4103a37-356c-4898-fe9e-bc61fd3f7ac8 quota=20
    Successfully updated VM c4103a37-356c-4898-fe9e-bc61fd3f7ac8

results in

    [17:20:09.634Z] c4103a37 foo modify: quota changed :: 10 -> 20
    [17:20:09.928Z] c4103a37 foo modify: last_modified changed :: "2018-04-11T17:19:12.000Z" -> "2018-04-11T17:20:09.000Z"

And, because sysevents are used, `vminfod` will catch any update to the
underlying system

    # zfs set quota=10G zones/c4103a37-356c-4898-fe9e-bc61fd3f7ac8

showing

    [17:20:56.635Z] c4103a37 foo modify: quota changed :: 20 -> 10

Deployment
----------

### Prerequisites for merging

Before `vminfod` can be merged to master:

 - (Done) The ZFS sysevent kernel change must be in place (either via the OpenZFS pull
   request, or a flag day set for the SmartOS release)
 - (Done) All tests in `/usr/vm/test` must pass
 - (Done) All vm-agent tests must pass
 - (Done) All vmapi tests must pass
 - (Done) All sdc-docker tests must pass
 - (Done) All cloudapi tests must pass
 - (N/A) All the above tests must pass on a vminfod-enabled platform with vminfod
   disabled.
 - (Done) `make check` must pass
 - (In Progress) All code must have passed review
 - (In Progress) The authors must be confident that all reasonable tests have been completed.

### Initial deployment

Actual deployment of `vminfod` will be done via the normal platform update
mechanism. Booting a CN onto a vminfod-enabled platform will cause it to start
using vminfod immediately.

The expected order of deployment would be:

 - the nightly smoke test setup (will happen automatically after merge to
   master)
 - installation in various dev setups for further stress testing after
   integration.
 - installation in beta DCs
 - installation in engineering staging environments (also testing Manta)
 - installation in operations staging environments
 - installation in production once operations testing is complete

### Post deployment

After vminfod has been deployed for some time and confidence has been
established in its correct operation, it should be possible:

 - to consider raising the `ALLOC\_FILTER\_VM\_COUNT` value in production

### Backporting

It won't be possible without significant work (including alternative
implementations of things that were added to illumos) to install vminfod on
older platforms. So the use of these features will be limited to CNs that are
rebooted onto platforms containing vminfod.

### Future changes

Because `vminfod` will be shipped with the platform, upgrading it will
be as simple as rebooting with a new platform image.

Questions that have been asked and (hopefully) answered here
------------------------------------------------------------

### Question(s) about consistency

There were a few questions that were similar to:

Q: "... [I]f I we add an interface to a VM, at what point in the process of querying a
VM using vminfod does the interface shows up?  Can clients ever get the wrong
state?  And does that matter?"

A: See the Guarantees/"Read-after-write consistency" section for some related
discussion, but basically:

 - If a `vmadm get` happens while an operation is ongoing it should not see the
   result of that operation. That is: a `vmadm get` before `vmadm update` has
   returned success should return the VM as it was before the update operation.
 - If a `vmadm get` happens after an operation has returned success, it should
   never see the state before the update has occurred.


### Question about events and racing

Q: "Do these events describe the change (e.g., property X was changed to Y), or
only that the change happened (e.g., some properties changed)?  One problem
I've run into with a lot of event notification systems is that it's easy for
consumers to react to events that have been superseded by subsequent events.
If there's any concurrency, it gets worse because the results are
non-deterministic if events are handled out of order.  Problems can also arise
when programs respond to each change in a sequence that were logically made at
once.  The solution for all of these has generally been that the events don't
contain change details, but rather just trigger the consumer to re-fetch the
real state.

How does a program that wants to use the /events interface avoid racing?  Is
the expectation that they will connect to /events and only then read the state
of the world that they're interested in (in order to make sure they don't miss
anything)?"

A: Hopefully the API note about GET /events answers this question to some
degree but as things are now, on a change you'd get both the details of the
change (array of change objects) and the current VM object after the change.
A note has been added to the "Open Questions" section below about whether there
are still issues here with events that were logically made together coming in
separately.


Open Questions
--------------

### Naming of CLI

Should the cli be named something like `vminfoadm` instead of `vminfo`?

### Logical Events

Related to the "Question about events and racing" above, do we need to do
anything special to handle logical changes made at once? Should we instead have
the event interface just return the uuid of VMs that are modified and require
the consumer to (re)load the VM themselves? It seems that one problem with this
would be that on delete there's nothing to get.

### Backpressure on Events

How do we manage backpressure for this interface?  Suppose a component accesses
/events, but then stops reading from the socket for some reason (e.g., gets
stuck processing one event).  Does vminfod terminate the connection if it's been
idle for too long?  Do events queue indefinitely inside vminfod?  Do events get
dropped?  Does it affect other consumers?


Other Notes
-----------

Miscellaneous notes:

 - vminfod must expose VMs with `do_not_inventory` set so that `vmadm` works in
   a backward compatible way. Consumers should be aware of this.

<!-- Repo Links -->
[heartbeater]: https://github.com/TritonDataCenter/sdc-heartbeater-agent
