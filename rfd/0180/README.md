---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+180%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc
-->

# RFD 180 Linux Compute Node Containers

This RFD describes containers on Linux compute nodes.  This is part of a larger
effort described in [RFD 177](../0177/README.md)..

## Problem statement

The Linux Compute Node project intends to introduce Linux containers on Linux
Compute Nodes.  The intent is for native Linux containers to fill the role
traditionally filled by lx on SmartOS.  Since the SmartOS lx brand was created
to emulate a Linux kernel, lx images *just work* on Linux, except in those
places where the image was customized to take advantage of SmartOS features.
For example, most lx images will try to use the SmartOS `zfs` command as
`/native/usr/sbin/zfs`, a path that does not exist on Linux.

Linux containers and zones share many concepts, but the implementation is quite
different.  While zones have a bespoke set of utilities for configuration and
administration, no such thing exists for Linux containers.  To the contrary,
Linux containers lack a firm definition in practice or code and the various
container management tools vary in which containment features they use.

A Linux container can be nebulously defined as a collection of
[name spaces](http://man7.org/linux/man-pages/man7/namespaces.7.html) and
[control groups](http://man7.org/linux/man-pages/man7/cgroups.7.html) that
provide isolation and resource controls.  Unlike zones, containers have no
unique in-kernel ID.  Taken together, this makes it rather easy to create a
container that does a poor job of containing the things that run inside it.  For
example, some container managers do not virtualize the UID namespace.  Without a
distinguishing in-kernel container ID, this means that the root user in the
container is the same as the root user outside of the container, which has been
repeatedly leveraged in container escapes.

Since Linux containers are intended to be managed using Triton APIs, the focus
of this effort is to provide the glue between the container features found in
popular Linux distributions and the Triton APIs.  Particular care must be taken
to ensure that security best practices are used.

## Terminology

[`machinectl`](https://www.freedesktop.org/software/systemd/man/machinectl.html)
uses terminology that is generally consistent with that used in Triton.  Terms
that are important to this document are:

- A *virtual machine* (VM) virtualizes hardware to run full operating system
  (OS) instances (including their kernels) in a virtualized environment on top
  of the host OS.
- A *container* shares the hardware and OS kernel with the host OS, in order to
  run OS userspace instances on top the host OS.
- *Machine* is a generic term to refer to a *virtual machine* or a *container*.
  *Instance* has sometimes been used in place of *machine*.
- *Image* has multiple meanings, depending on the context.  In Triton, an image
  is a machine image that may be cloned to create a machine.  It is typically
  obtained through
  [IMGAPI](https://github.com/joyent/sdc-imgapi/blob/master/docs/index.md).
  `machinectl` expands on this definition by considering the on-disk bits used
  by a specific machine to be that machine's image.  In contrast, Triton would
  normally consider a specific machine's image to be the storage that was cloned
  to build the virtual machine.

Linux CNs are intended to only support containers, but many of the management
concepts apply equally well to containers and virtual machines.  When no
distinction is needed, *machine* will be used instead of *container*.

## Implementation

The implementation aims to be as distribution agnostic as possible to allow
flexibility in choosing to run on a different distributions, as the market
dictates.  Partially for this reason, the implementation will be leverage
[systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html)
for most aspects of container management.  Notable exceptions include:

- Images will be managed using
  [node-imgadm](https://github.com/joyent/node-imgadm).
- Instance installation will be performed by
  [node-vmadm](https://github.com/joyent/node-vmadm).

As much as possible, native tools will be usable to observe and control
machines.

To allow for evolution of the platform, configuration will be maintained in a
Triton-centric form and transformed into the form appropriate for the platform
image at CN boot time and as machines are added/removed/changed through the
course of normal operation.

### Storage layout

The following files and directories are required for a machine.

- `/<pool>/<uuid>`: the mountpoint of the machine's dataset, `<pool>/<uuid>`.
  - `/root`: a subdirectory containing the container's root file system.
  - `/config`: a subdirectory containing instance metadata, typically as json
    files.
- `/run/systemd/nspawn/<uuid>.nspawn`: The machine's
  [systemd.nspawn(5)](https://www.freedesktop.org/software/systemd/man/systemd.nspawn.html)
  configuration file.
- `/var/lib/machines/<uuid>`: a symbolic link to `/<pool>/<uuid>/root` that
  exists for compatibility with `machinectl` and `systemd-nspawn@.service`.

To support persistence of image and machine configuration across reboots,
`/var/triton`, will contain the
following:

- `/var/triton/` mounted from `<systempool>/system/var/triton`
  - `imgadm/` - the same as `/var/imgadm` on SmartOS.  A compatibility symbolic
    link will exist in the PI.
    - `imgadm.conf`
    - `images/`
      - `<uuid>`.json - Image manifest for a particular image
      - ...
  - `vmadm/` - similar structure to `imgadm/`, analogous to `/etc/zones` on
    SmartOS.
    - `vmadm.conf` - any required configuration.  Perhaps only includes a
      configuration version initially.
    - `machines/`
      - `<uuid>`.json - Payload for a particular machine.  The content that is
        authoritatively stored in `/<pool>/<uuid>/config/*.json` is not included
        in this file.
      - ...

### nspawn configuration

The systemd-nspawn configuration is stored
as`/run/systemd/nspawn/<uuid>.nspawn`.  There are alternative locations for this
configuration file and alternative means for configuring per-instance nspawn
parameters.  This location was chosen for the following reasons:

- If the configuration is at `/var/lib/machines/<uuid>.nspawn`, the
  `systemd-nspawn@service` start command would need to be customized to trust
  configuration.  If Linux CNs were to eventually support virtual machines, this
  file would need to be in a different location (next to the disk image).
- `/run/systemd/nspawn/<uuid>.nspawn` is unsuitable because it would not persist
  across reboots.
- A per-machine systemd unit file, stored at
  `/run/systemd/system/systemd-nspawn@<uuid>.service` could be created with all
  the required command line options.  To get systemd to recognize this file,
  `systemdctl daemon-reload` would need to be invoked.  This seems like a
  heavy-weight operation.

The typical `/run/systemd/nspawn/<uuid>.nspawn` file will look like:

```
[Exec]
Boot=on
PrivateUsers=pick
MachineID=371f18c0-9f73-6e86-94f6-c1cf71188d23

[Network]
Private=yes
MACVLAN=external0
```

Resource controls can be managed via dbus, allowing for live updates.  For
example:

```bash
uuid=371f18c0-9f73-6e86-94f6-c1cf71188d23
uuid_mangled=${uuid//-/_2e}
prop=MemoryMax
newval=$(( 1024 * 1024 * 1024 ))

# Set to false to update
# /etc/systemd/system.control/systemd-nspawn@$uuid.service.d/50-$prop.conf
runtime_only=true

busctl call org.freedesktop.systemd1 \
    /org/freedesktop/systemd1/unit/systemd_2dnspawn_$uuid_mangled \
    org.freedesktop.systemd1.Unit \
    SetProperties 'ba(sv)' $runtime_only 1 $prop t $newval
```

There are a couple of node module that provide an easy way to interact with dbus
programmatically:

- [dbus-next](https://github.com/dbusjs/node-dbus-next) is a pure
  JavaScript implementation that is actively maintained.  It is the successor to
  [dbus-native](https://www.npmjs.com/package/dbus-native), which is deprecated.
- [node-dbus](https://github.com/Shouqun/node-dbus) is a mixture of C++ and
  JavaScript.  It seems to be less active both in maintenance and popularity on
  npm.

Prototyping will start with dbus-next.

### Implementation Strategy

#### node-vmadm

The linux implementation of node-vmadm will have at least the following machine
states:

- **configured**: The machine payload, `/var/triton/vmadm/machines/<uuid>.json`,
  exists and the machine's dataset exists.
- **installed**: The machine payload has been transformed into native
  configuration.
- **running**: The init process in the container is running.


The state transitions happen via `configure`, `unconfigure`, `install`,
`uninstall`, `start`, and `stop` primitive functions, some of which are not
exported.

                           +------------+
                           |  no state  |
                           +------------+
                                |  ^
                    configure() |  | unconfigure()
                                V  |
                           +------------+
                           | configured |
                           +------------+
                                |  ^
                      install() |  | uninstall()
                                V  |
                           +------------+
                           | installed  |
                           +------------+
                                |  ^
                        start() |  | stop()
                                V  |
                           +------------+
                           |  running   |
                           +------------+

Higher level functions are composed of primitive functions.  For example:

- [`create()`](https://github.com/joyent/node-vmadm/#createopts-callback)
  invokes `configure()` and `install()`.
- [`delete()`](https://github.com/joyent/node-vmadm/#deleteopts-callback)
  may invoke `stop()`, `uninstall()`, and `unconfigure()`.
- [`reboot()`](https://github.com/joyent/node-vmadm/#rebootopts-callback)
  invokes `stop()` and `start()`.

Unlike with SmartOS, `vmadm.install()` will be called on each boot by a systemd
generator.  Its job is to ensure that the Triton configuration has been
transformed into Linux native configuration.

`node-vmadm` will gain a `vmadm` command that mimics the command of the same
name found on SmartOS.

#### VMAPI mapping

With a few exceptions, the [VMAPI properties](https://github.com/joyent/sdc-vmapi/blob/master/lib/common/vm-common.js#L115)
will be stored in `/var/triton/vmadm/machines/<uuid>.json`.  The exceptions are:

- `customer_metadata` is stored in `/<pool>/<uuid>/config/metadata.json` in the
  `customer_metadata` key.
- `internal_metadata` is stored in `/<pool>/<uuid>/config/metadata.json` in the
  `internal_metadata` key.
- `last_modified` is derived from the timestamp of the last modification.  If
  there is no in-memory state that tracks this, then it will be the modification
  time of the newest of `/var/triton/vmadm/machines/<uuid>.json` and
  `/<pool>/<uuid>/config/*.json`.
- `platform_buildstamp` comes from `TRITON_RELEASE` in `/etc/os-release`.
- `routes` is stored in `/<pool>/<uuid>/config/routes.json`.
- `server_uuid` comes from DMI (e.g. `/usr/sbin/dmidecode -s system-uuid`).
- `snapshots` comes from listing snapshots on the appropriate dataset(s).
- `state` is derived from the state of `systemd-nspawn@<uuid>.service` or
  on-disk state if there is no such service.
- `tags` is stored in `/<pool>/<uuid>/config/tags.json`.
- `zfs_filesystem` is dynamically generated as `<zpool>/<uuid>`.
- `zone_state` does not exist.
- `zonepath` is `/<zfs_filesystem>`.

Various [VMAPI properties](https://github.com/joyent/sdc-vmapi/blob/master/lib/common/vm-common.js#L115)
map to run time state, as described below:

| Property            | Maps To                                               |
|---------------------|-------------------------------------------------------|
| cpu\_cap            | dbus `org.freedesktop.systemd1.Unit` `CPUQuota`       |
| cpu\_shares         | dbus `org.freedesktop.systemd1.Unit` `CPUWeight`      |
| hostname            | nspawn: Exec.Hostname                                 |
| init\_name          | nsapwn: Exec.Parameters
| max\_locked\_memory | *Not supported*                                       |
| max\_lwps           | dbus `org.freedesktop.systemd1.Unit` `TasksMax`       |
| max\_physical\_memory | dbus `org.freedesktop.systemd1.Unit` `MemoryHigh`   |
| max\_swap           | dbus `org.freedesktop.systemd1.Unit` `MemomorySwapMax`, but keep in mind that this is swap space usage, not memory reservation |
| nics                | nspawn: Network.MACVLAN, plus scripting?              | 
| pid                 | TBD                                                   |
| quota               | zfs property, same as SmartOS                         |
| ram                 | *TBD: how is this different from max_physical_memory?* |
| snapshots           | *Not implemented initially*                           |
| state               | dbus `org/freedesktop/machine1/machine/<uuid>` `org.freedesktop.DBus.Properties` `State` |
| zfs\_data\_compression | zfs property, same as SmartOS                      |

XXX Networking configuration is rather uncertain at this point.  There are some
options:

- Require cloud-init in each image
- Add another container that configures networking using tools that are under
  host control.  After that container comes up, start the desired container with
  [JoinsNamespaceOf](https://www.freedesktop.org/software/systemd/man/systemd.unit.html#JoinsNamespaceOf=)
  so that it has the network namespace configured via the controlled
  environment.
- Use
  [ExecStartPost](https://www.freedesktop.org/software/systemd/man/systemd.service.html#ExecStartPre=)
  to run `ip netns exec` commands to configure the network.  This seems likely
  to race with things that are starting in the container, so it may require a
  customized init that waits for network configuration to be complete.

#### CN Agent

[CN Agent](https://github.com/joyent/sdc-cn-agent) has backends for SmartOS and
dummy (mockcloud).  The backends make use of `imgadm`,
[node-vmadm](https://github.com/joyent/node-vmadm), and other modules.  This
document is primarily concerned with `node-vmadm`.

`node-vmadm` also has per-platform backends.  A backend will be added that
implements the [API](https://github.com/joyent/node-vmadm#api) by interacting
with dbus as much as possible.  There are parts of `create`, `delete`, and
update that will require manipulation of datasets and files.

##### create(opts, callback)

The [create](https://github.com/joyent/node-vmadm#createopts-callback) function
will:

- Create `/var/triton/vmadm/machines/<uuid>` link.
- Clone the image
- Populate `/<pool>/<uuid>/config/*.json`
- Set resource controls using dbus.
- Create `/run/systemd/nspawn/<uuid>.nspawn`, as described above.

The order should be arranged such that if a `create` operation is interrupted it
is possible to determine that the creation was not complete and to identify all
of the components that are related to the instance.  The existence of the
`/usr/lib/machines/<uuid>` link indicates the machine creation has begun.  The
existence of `/run/systemd/nspawn/<uuid>.nspawn` indicates that the creation has
completed.

##### delete(opts, callback)

The [delete](https://github.com/joyent/node-vmadm#deleteopts-callback) function
will undo the operations performed by `create()`, in the reverse order from
create.

##### kill(opts, callback)

The [kill](https://github.com/joyent/node-vmadm#killopts-callback) function will
send the specified signal to the init process.

##### reboot(opts, callback)

The [reboot](https://github.com/joyent/node-vmadm#rebootopts-callback) function
will reboot the instance, similar to `machinectl reboot`.

##### reprovision(opts, callback)

Not implemented initially.

##### start(opts, callback)

The [start](https://github.com/joyent/node-vmadm#startopts-callback) function
will start `systemd-nspawn@<uuid>.service`.

XXX It remains to be determined if that is sufficient: there may be additional
networking setup or other actions required.

XXX How does this related to `machinectl enable`?

##### stop(opts, callback)

The [stop](https://github.com/joyent/node-vmadm#stopopts-callback) function
will perform the equivalent of `machinectl stop` (without force) or `machinectl
terminate` (with force).

XXX How does this related to `machinectl disable`?

##### sysrq(opts, callback)

The [sysrq](https://github.com/joyent/node-vmadm#sysrqopts-callback) function
will be a no-op.

##### update(opts, callback)

The [update](https://github.com/joyent/node-vmadm#updateopts-callback) function
will be make the modifications to the machine in a manner using the same
mechanisms used during `create` and perhaps `delete`.

##### load(opts, callback)

The [load](https://github.com/joyent/node-vmadm#loadopts-callback) function
will load the machine's properties from the authoritative sources described
above in [VMAPI mapping](#vmapi-mapping).

##### lookup(search, opts, callback)

The [lookup](https://github.com/joyent/node-vmadm#lookupsearch-opts-callback)
function will perform a `load` on every VM, removing those that do not match the
filter specified by `search`.  If `opts.fields` is specified, fields not listed
are elided.

##### create\_snapshot(opts, callback)

Not implemented initially.

##### delete\_snapshot(opts, callback)

Not implemented initially.

##### rollback\_snapshot(opts, callback)

Not implemented initially.

##### rollback\_snapshot(opts, callback)

Not implemented initially.

##### event(opts, handler, callback)

Not implemented initially.

It is anticipated that this will be built on watching for relevant dbus events.


#### VM Agent

The responsibilities and theory of operation of VM agent are described in
[`vm-agent.js`](https://github.com/joyent/sdc-vm-agent/blob/master/lib/vm-agent.js#L11-L113).
On the Linux port will follow the same general operation, but the implementation
will leverage dbus and inotify to get updates about machine and file system
state changes.  It is likely that `node-vmadm` will be useful.
