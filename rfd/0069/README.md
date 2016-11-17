---
authors: Josh Wilsdon <jwilsdon@joyent.com>
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
socket which is in `<zoneroot>/tmp/vm.ttyb` of the instance and starts a server
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

What node-zsock does, is to `zone_enter` a zone and create a unix domain socket
within the zone. It then passes the file descriptor for this socket using
sendmsg() through a socketpair() back to the metadata agent process in the GZ.
The metadata agent then does a `server.listen({fd: fd});` to start an instance
of the metadata API listening on this socket. From that point the clients in the
zone can connect to the socket and talk to the metadata API.

The most important consequence of using this mechanism that is relevant to the
rest of the discussion in this RFD is that in order to create a zsock, the zone
must be running. The zsock implementation also adds significant complexity to
debugging efforts and has itself been the source of a number of bugs.

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

 * moving `/.zonecontrol` (`/native/.zonecontrol` in LX) to be mounted into zones
   (readonly lofs) rather than being written into the zoneroot dataset.
 * eliminating the need for and use of zsock by creating sockets in
   `/zones/<uuid>/zonecontrol/metadata.sock` directly instead of inside the
   zoneroot.
 * mounting the zonecontrol directory into the zone while it is in the ready
   state so there is no window where the zone is running and we need to wait for
   the metadata.sock to show up.
 * eliminating the periodic checking of the "stat signature" of sockets by
   creating the sockets on metadata agent or zone startup, and not providing a
   mechansim for them to be changed by the zone even in the case of a marlin
   reset / snapshot rollback.

Additional changes to be explored in the future (not part of this RFD) include:

 * having zone create/destroy notify the metadata agent so that it doesn't need
   to rely solely on unreliable sysevents and periodically running `zoneadm
   list` to work around this unreliability.

## Implementation

Instead of creating a `<zoneroot>/.zonecontrol` (or
`<zoneroot>/native/.zonecontrol` directory within the zoneroot I'm proposing
making the following changes to smartos-live:

```
diff --git a/overlay/generic/usr/lib/brand/jcommon/cuninstall b/overlay/generic/usr/lib/brand/jcommon/cuninstall
index 54a8102..c496c57 100644
--- a/overlay/generic/usr/lib/brand/jcommon/cuninstall
+++ b/overlay/generic/usr/lib/brand/jcommon/cuninstall
@@ -67,6 +67,7 @@ fi
 [[ -n ${ORIGIN} && ${ORIGIN} != "-" ]] && zfs destroy -F $ORIGIN

 rm -rf $ZONEPATH
+rm -rf /zones/${ZONENAME}/zonecontrol

 jcommon_uninstall_hook

diff --git a/overlay/generic/usr/lib/brand/jcommon/statechange b/overlay/generic/usr/lib/brand/jcommon/statechange
index 339510f..16ea53b 100644
--- a/overlay/generic/usr/lib/brand/jcommon/statechange
+++ b/overlay/generic/usr/lib/brand/jcommon/statechange
@@ -622,6 +622,9 @@ setup_fw()
 #
 setup_fs()
 {
+       # create directory for metadata socket
+       mkdir -m755 -p /zones/${ZONENAME}/zonecontrol
+
        uname -v > $ZONEPATH/lastbooted
        [[ -n "$jst_simplefs" ]] && return

diff --git a/overlay/generic/usr/lib/brand/joyent-minimal/platform.xml b/overlay/generic/usr/lib/brand/joyent-minimal/platform.xml
index f778768..9b82bca 100644
--- a/overlay/generic/usr/lib/brand/joyent-minimal/platform.xml
+++ b/overlay/generic/usr/lib/brand/joyent-minimal/platform.xml
@@ -34,6 +34,9 @@
        <global_mount special="/dev" directory="/dev" type="dev"
            opt="attrdir=%R/root/dev"/>

+       <global_mount special="%R/zonecontrol" directory="/.zonecontrol"
+           opt="rw" type="lofs" />
+
        <global_mount special="/lib" directory="/lib"
            opt="ro,nodevices" type="lofs" />
        <global_mount special="%P/manifests/joyent" directory="/lib/svc/manifest"
diff --git a/overlay/generic/usr/lib/brand/joyent/platform.xml b/overlay/generic/usr/lib/brand/joyent/platform.xml
index 4efeb82..237bdb6 100644
--- a/overlay/generic/usr/lib/brand/joyent/platform.xml
+++ b/overlay/generic/usr/lib/brand/joyent/platform.xml
@@ -34,6 +34,8 @@
        <global_mount special="/dev" directory="/dev" type="dev"
            opt="attrdir=%R/root/dev"/>

+       <global_mount special="%R/zonecontrol" directory="/.zonecontrol"
+           opt="ro" type="lofs" />
        <global_mount special="/lib" directory="/lib"
            opt="ro,nodevices" type="lofs" />
        <global_mount special="%P/manifests/joyent"
```

and the following to illumos-joyent (sadly the platform.xml files are not in the
same place):

```
diff --git a/usr/src/lib/brand/lx/zone/platform.xml b/usr/src/lib/brand/lx/zone/platform.xml
index 4a7010f..28c4b57 100644
--- a/usr/src/lib/brand/lx/zone/platform.xml
+++ b/usr/src/lib/brand/lx/zone/platform.xml
@@ -59,6 +59,8 @@
            opt="ro" type="lofs" />
        <global_mount special="/etc/zones/%z.xml"
            directory="/native/etc/zones/%z.xml" opt="ro" type="lofs" />
+       <global_mount special="%R/zonecontrol" directory="/native/.zonecontrol"
+           opt="ro" type="lofs" />

        <!-- Local filesystems to mount when booting the zone -->
        <mount special="/native/dev" directory="/dev" type="lx_devfs" />
```

With these changes, non-kvm zones should always be using
`/zones/<uuid>/zonecontrol/metadata.sock` for their metadata (mounted at the
same location as before within the zone).

After doing this we can also change the metadata agent so that instead of
creating a zsock through `zone_enter`, it creates a regular unix domain socket in
`/zones/<uuid>/zonecontrol` for the zone. This socket can then be left in place
across zone reboots, resets and even reprovisions since it is not attached to
the zoneroot. Since the dataset is mounted read-only inside the zone, it should
be safe for metadata agent to create its file in the GZ path without concern
for someone having created a symlink from within the zone.

The code in metadata agent can also be simplified to avoid the need to poll the
metadata socket's fs.stat() signature.

