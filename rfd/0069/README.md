---
authors: Josh Wilsdon <jwilsdon@joyent.com>
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


# RFD 69 Metadata socket improvements

## Related reading

 * [OS-5783](https://smartos.org/bugview/OS-5783)

## How metadata works

To understand the proposal here, it is helpful to have a general understanding
of how the metadata process works. This section attempts to give an overview.

[Metadata](https://docs.joyent.com/private-cloud/instances/using-mdata) is the
name for the system which provides key/value access to the `customer_metadata`
and (in some special cases) `internal_metadata` of a given Triton instance. It
also provides access to certain instance properties from the instance's "VM
object" as available via
[vmadm](https://github.com/joyent/smartos-live/blob/master/src/vm/man/vmadm.1m.md).
The list of supported keys and their descriptions are detailed in the [Joyent
Metadata Data Dictionary](https://eng.joyent.com/mdata/datadict.html).

There's an agent written in node.js (here called the metadata agent) which runs
in the GZ of all SmartOS systems. This metadata agent is responsible for
providing metadata services to all instances running on the system. The
mechanism is slightly different between the kvm brand and other zone brands.

For KVM instances, the qemu process is started with an option that creates an a
serial tty device which shows up as a unix domain socket in the zoneroot and a
serial device inside the KVM's guest OS. The metadata agent connects to the
socket which is in <zoneroot>/tmp/vm.ttyb of the instance and starts a server
which the guest can connect to via the second serial port using the
[mdata-client](https://github.com/joyent/mdata-client) tools.

For joyent, joyent-minimal and lx branded zones, the metadata agent creates a
unix domain socket inside the zone (more details on this process later as that's
the mechanism that this RFD is proposing to change). A server is started on this
socket and the [mdata-client](https://github.com/joyent/mdata-client) tools
access this socket via the path `/.zonecontrol/metadata.sock` for joyent and
joyent-minimal and `/native/.zonecontrol/metadata.sock` for lx zones.

## How zsocks are used

When creating unix domain sockets for joyent, joyent-minimal and lx branded
zones (we'll use the term "zone" to mean only these for the rest of this
document) we cannot just create a socket within the zoneroot for the zone to
use. The biggest reason for this is that when a zone is running there are
security implications of creating files from the GZ as zones can adjust symlinks
within the zone which are traversed in GZ context. Since zones can run code from
potentially untrusted users, we must do something different to create these
sockets and the current mechanism is to use a zsocket via
[node-zsock](https://github.com/mcavage/node-zsock).

What node-zsock does, is to `zone\_enter` a zone and create a unix domain socket
within the zone. It then passes the file descriptor for this socket using
sendmsg() through a socketpair() back to the metadata agent process in the GZ.
The metadata agent then does a `server.listen({fd: fd});` to start an instance
of the metadata API listening on this socket. From that point the clients in the
zone can connect to the socket and talk to the metadata API.

The consequences of using this mechanism that are relevant to the rest of the
discussion in this RFD include:

 * the zone must be running in order to create a zsock
 * ...

## Problems specific to Manta's "marlin"

One specific motivation for this RFD is a set of problems that Joyent's
[Manta](https://github.com/joyent/manta) service has experienced while resetting
[Marlin](https://github.com/joyent/manta-marlin) zones. Details of marlin will
not be covered here except to the degree they're relevant to metadata which is
specifically surrounding the "reset" process.

Marlin zones have a zfs snapshot created at some point in the past (presumably the
point where the zone was created). These snapshots are of the zoneroot dataset
for the zone. In order to do a reset the relevant steps are:

 * the zone is stopped (via zoneadm)
 * the zfs filesystem for the zoneroot is rolled back to the snapshot
 * the zone is started

The specific problem for metadata is in the second step here. Assuming the zone
was running normally prior to being stopped, it will have a metadata socket in
`/.zonecontrol/metadata.sock` which the metadata agent in the GZ is listening on.
When the snapshot is rolled back, the metadata agent does not receive any
notification that the socket has been changed, and indeed the metadata agent is
still listening to the (now wrong) socket. Inside the zone after it has booted
however, the zone expects that it should be able to access metadata via the
`/.zonecontrol/metadata.sock` socket, but the socket that exists there now has
been replaced by an ancient one from the snapshot rather than the one the
metadata agent is actually listening on.

Currently a few strategies are employed in order to try to ensure this works.
First, the metadata agent does a `fs.stat()` on the socket after it creates it
and then periodically checks that the stat "signature" (ctime, ino, dev) are the
same otherwise the socket is considered "stale" and is recreated. Secondly,
inside the zone the `mdata-fetch` service uses the `/usr/vm/sbin/filewait` tool
in order to wait for the `/.zonecontrol/metadata.sock` socket to show up before
proceeding though this fails sometimes due to the fact that the snapshot we
roll back to has a metadata.sock socket in it.

## Proposed solution

In order to improve this situation and ensure more reliable metadata service,
this RFD proposes a few things. A summary of the proposals are:

 * moving /.zonecontrol (/native/.zonecontrol in LX) to be mounted into zones
   (readonly lofs) rather than being written into the zoneroot dataset.
 * eliminating the need for and use of zsock by creating sockets in
   /zones/zonecontrol/<uuid>/metadata.sock directly instead of inside the
   zoneroot.
 * mounting the zonecontrol dataset into the zone while it is in the ready state
   so there is no window where the zone is running and we need to wait for the
   metadata.sock to show up.
 * eliminating the periodic checking of the "stat signature" of sockets by
   creating the sockets on metadata agent or zone startup, and not providing a
   mechansim for them to be changed by the zone even in the case of a marlin
   reset / snapshot rollback.

Additional changes to be explored include:

 * having zone create/destroy notify the metadata agent so that it doesn't need
   to rely solely on unreliable sysevents and periodically running `zoneadm
   list` to work around this unreliability.

The rest of this document will discuss these proposed changes.

\[To be continued...\]
