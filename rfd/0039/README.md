----
authors: Dave Eddy <dave@daveeddy.com>
state: draft
----

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

RFD 0039 vminfod
================

Introduction
------------

### The "VM" abstraction

SmartOS is a hypervisor that can manage many different types of VMs.  A VM, in
the SmartOS world, is an abstraction that can contain:

- An Illumos zone
- One (or more) ZFS datasets
- Networking (etherstub, vnic, etc.)
- and more

Some are just a bare zone, like a SmartOS zone, LX zone, docker container,
etc. while others are a zone coupled with a hardware virtualization process
(ie. KVM) - but all are examples of "VM"s.

### `vminfod`

`vminfod` is two things.  First, it is a daemon that provides read-only access
to this VM abstraction on a given system. Second, it is a cache for this
information, only reaching out to the system when modifications are made - so it
is very fast.  `vminfod` makes this information available over an HTTP
interface to the Global zone.

On top of this static interface for looking up VM information in `vminfod`, there
is a second streaming interface that can be used, that will emit an event
anytime an update is done on the system.  To be specific, there is an `/events`
endpoint that will remain open when connected to, and spit out newline-separated
JSON whenever a change to the system is made - for example when a VM is created
or deleted, or a property of an existing VM is modified.

### History

This project has been in progress for the last couple years, with the first
commits being seen around the middle of 2014.  The project was originally started
by [Josh Wilsdon](https://github.com/joshwilsdon) and
[Tyler Flint](https://github.com/tylerflint) and has since been effectively taken
over by [Dave Eddy](https://github.com/bahamas10).

The main project ticket is here https://smartos.org/bugview/OS-2647

### `vmadm` and its relation to `vminfod`

In the current world, `vmadm` provides the VM abstraction for us.  When an
operator runs `vmadm list` for instance, the code base itself (through mostly
`VM.js`) will reach out to various parts of the system to create a list of all
VMs on the system, typically through forking userland tools such as `zfs(1M)`,
`zoneadm(1M)`, `dladm(1M)`, etc.

In the new world, any read-only actions with `vmadm` such as `vmadm list`,
`vmadm lookup`, `vmadm get`, etc. will be thin wrappers around HTTP requests to
the `vminfod` daemon.  Read-write actions such as `vmadm create`, `vmadm
reboot`, `vmadm update`, etc. by contrast, will still behave in their normal
way by reaching out to the system directly to make the changes requested.  In
addition to this however, these read-write actions will now "block" on
`vminfod`, and wait for the changes to be reflected before returning to the
caller.  As an example, if an operator deletes a VM using `vmadm delete $uuid`,
the code will now wait for the delete event for that VM to be fired in
`vminfod` before returning success.  This allows us to avoid problems such as
404 on GET immediately after PUT, or in this case, "VM Not Found" on `vmadm
get` immediately after `vmadm create`.

### Event driven

An important design decision for `vminfod` is that all of its updates are
event-driven.  With the exception of when the daemon first starts up (or an
optional debug flag), `vminfod` will never do a full scan of the system for VM
modifications, it will rely solely on events.  These events come in mainly 2
forms:

- sysevents - `sysevent(1M)` is used to see relevant ZFS and Zone events
- file changes - `fswatcher.c` (in this project) is used to watch files
for modifications

When an event is received, `vminfod` figures out what information it needs
to reload and ensures that it has the latest correct image of what the system
looks like.  *`vminfod` uses the system as the source of
truth*.  This means that `vminfod` is able to catch ad hoc actions that are done
on a system, because they will inevitably result in an event being fired such
as a Zone or ZFS sysevent, or a file being modified.

Implementation
--------------

### Where this lives

The `vminfod` project currently spans the following repositories:

1. [smartos-live](https://github.com/joyent/smartos-live) - majority of the
code here
2. [illumos-joyent](https://github.com/joyent/illumos-joyent) - ZFS patch
for sysevents only

Note: The Illumos change is not `vminfod` specific, and as such has been proposed
to the OpenZFS project on GitHub through this pull request.

https://github.com/openzfs/openzfs/pull/101

If this can be merged, and pulled into the `illumos-joyent` repo, then all
of the `vminfod` code will *only* live in the `smartos-live` repo.

For now though, in both repositories there is a `vminfod` branch that contains
the latest code for the project.

### What makes `vminfod`

At the core of `vminfod`, is a daemon in `/usr/sbin` that is started at boot
in the Global zone that extracts all of the necessary information off of the system
to create a comprehensive list of VM objects.  The majority of this code lives
in `/usr/vm/node_modules/vminfod` in the following files:

- [client.js](https://github.com/joyent/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/client.js):
vminfod client library, this is used by VM.js and `vmadm`
- [diff.js](https://github.com/joyent/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/diff.js):
a generic JavaScript object diff'ing library, this is used by `vminfod` to
figure out what events to fire when an object is updated
- [fswatcher.js](https://github.com/joyent/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/fswatcher.js):
a JavaScript wrapper for `fswatcher.c` to watch files for modifications
- [vminfo.js](https://github.com/joyent/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/vminfo.js):
majority of the code for the `vminfod` daemon
- [zonewatcher.js](https://github.com/joyent/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/zonewatcher.js):
thin wrapper around `sysevent-stream.js` to watch for Zone sysevents
- [zpoolwatcher.js](https://github.com/joyent/smartos-live/blob/vminfod/src/vm/node_modules/vminfod/zpoolwatcher.js):
thin wrapper around `sysevent-stream.js` to watch for ZFS sysevents

Management
----------

### Logging

`vminfod`, like most other services in SmartOS, uses bunyan for logging,
and goes to the default SMF location for logs, ie.

    # svcs -L vminfod
    /var/svc/log/system-smartdc-vminfod:default.log

### Health

`GET /ping` to ensure the daemon is running

    # curl localhost:9090/ping
    {
      "ping": "pong"
    }

`GET /status` to get various stats about the process and current
running tasks

    # curl localhost:9090/status
    {
      "pid": 3601,
      "uptime": 1427,
      "memory": {
        "rss": 50143232,
        "heapTotal": 28908416,
        "heapUsed": 9082576
      },
      "state": "running",
      "status": "working",
      "queue": {
        "paused": false,
        "working": 0,
        "max_jobs": 2,
        "channels": [],
        "backlog": []
      }
    }

### CLI tool

**NOTE:** usage subject to change

There is `vminfod` CLI tool that can be used to query the daemon.
This was mostly written for debugging purposes but has proven itself
sufficiently useful to warrant being shipped with the platform.

    # vminfod ping
    {
      "ping": "pong"
    }

`vminfod ping` is a thin wrapper around `GET /ping`

List of vms on the system (`GET /vms`).  This is what `vmadm list` now uses
under-the-hood.

    # vminfod vms | json -ag uuid state alias | head -5
    25df11d6-70c2-485b-92a6-4ab651e8fd88 running assets0
    874d1b68-88ae-4d69-abf0-39168835d1dc running sapi0
    96f0d23a-6123-477d-8c97-2bd7d4122de9 running binder0
    652b1818-3278-4404-8612-85a94afacba7 running manatee0
    0d8697ae-9877-4aa6-8af9-a9b30f54dc23 running moray0

Get a specific vm (`GET /vms/:uuid`).  This is what `vmadm get` and `vmadm
lookup` now use under-the-hood.

    # vminfod vm 25df11d6-70c2-485b-92a6-4ab651e8fd88 | json alias quota max_physical_memory
    assets0
    25
    128

And finally, watch for events in realtime on the system (`GET /events`).
These commands were run in two separate terminals on the same machine.

    # vmadm create < minimal.json

and

    # vminfod events
    [2016-05-31T16:29:09.477Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec create
    [2016-05-31T16:29:09.634Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zone_state changed :: "configured" -> "incomplete"
    [2016-05-31T16:29:09.882Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: quota added :: null -> 10
    [2016-05-31T16:29:09.882Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zfs_root_recsize added :: null -> 131072
    [2016-05-31T16:29:09.882Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zfs_filesystem added :: null -> "zones/5595d88c-6e4d-4bda-b58e-97dd02e32bec"
    [2016-05-31T16:29:09.882Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zpool added :: null -> "zones"
    [2016-05-31T16:29:10.403Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zone_state changed :: "incomplete" -> "installed"
    [2016-05-31T16:29:10.556Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: last_modified changed :: "2016-05-31T16:29:09.000Z" -> "2016-05-31T16:29:10.000Z"
    [2016-05-31T16:29:10.556Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: customer_metadata added :: null -> {}
    [2016-05-31T16:29:10.556Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: internal_metadata added :: null -> {}
    [2016-05-31T16:29:11.259Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zone_state changed :: "installed" -> "ready"
    [2016-05-31T16:29:11.259Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zoneid changed :: null -> 24
    [2016-05-31T16:29:11.259Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: boot_timestamp added :: null -> "1970-01-01T00:00:00.000Z"
    [2016-05-31T16:29:11.259Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: pid added :: null -> 0
    [2016-05-31T16:29:11.974Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: zone_state changed :: "ready" -> "running"
    [2016-05-31T16:29:11.974Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: boot_timestamp changed :: "1970-01-01T00:00:00.000Z" -> "2016-05-31T16:29:11.000Z"
    [2016-05-31T16:29:11.974Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: pid changed :: 0 -> 20374
    [2016-05-31T16:29:15.221Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: state changed :: "provisioning" -> "running"
    [2016-05-31T16:29:15.221Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: transition_to removed :: "running" -> null
    [2016-05-31T16:29:15.221Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: transition_expire removed :: 1464712449309 -> null
    [2016-05-31T16:29:15.221Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: last_modified changed :: "2016-05-31T16:29:10.000Z" -> "2016-05-31T16:29:15.000Z"

Now, updating the zone

    # vmadm update 5595d88c-6e4d-4bda-b58e-97dd02e32bec quota=20

results in

    [2016-05-31T16:29:59.967Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: last_modified changed :: "2016-05-31T16:29:15.000Z" -> "2016-05-31T16:29:59.000Z"
    [2016-05-31T16:29:59.967Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: quota changed :: 10 -> 20

And, because sysevents are used, `vminfod` will catch any update to the
underlying system

    # zfs set quota=10G zones/5595d88c-6e4d-4bda-b58e-97dd02e32bec

showing

    [2016-05-31T16:34:39.145Z] 5595d88c-6e4d-4bda-b58e-97dd02e32bec modify: quota changed :: 20 -> 10


Deployment
----------

In order to deploy `vminfod`, the following conditions must be met

1. The ZFS sysevent kernel change must be in place (either via the OpenZFS pull
request, or a flag day set for the SmartOS release)
2. All tests in `/usr/vm/test` must pass

From there, deployment is as simple as merging the code into master, and
building a new platform
