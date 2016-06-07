---
authors: Jonathan Perkin <jperkin@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 42 Provide global zone pkgsrc package set

The SmartOS Global Zone is designed to be a mostly read-only environment.  The
operating system is booted as a live image, and directories such as `/etc` and
`/usr` are either read-only or are recreated from the boot image upon each
system start.

This design helps to ensure a consistent environment, provides security
benefits, and allows optimal primary storage layout whilst avoiding issues
around booting from complicated storage configurations.

As the global zone is a minimal environment, users often wish to install
additional software that is not provided by the live image.  Examples include
apcupsd to handle attached UPS, smartctl for SMART diagnostics, or
configuration management systems such as ansible or saltstack to manage their
installed VMs.

However, the global zone is somewhat hostile to the installation of additional
software.  Due to the live image design, many system directories cannot be
written to, and changes to others will be lost on the next boot.  Common
failure modes include:

* User management functions such as `useradd(1M)` fail due to `/etc/shadow`
  being a mount point.
* Modifications to the `smf(5)` database are lost on reboot due to `/etc` being
  a ramdisk.
* Software attempting to install to `/usr/local` will fail as it is a read-only
  mount from the live image.

The official recommendation for users who wish to include additional software
into their global zone is to build their own SmartOS images which include the
extra files and modifications they require.  This will bake their changes into
the live image they boot and ensure they are available.

This however requires a machine capable of building SmartOS, the knowledge to
modify the build process to include their changes, and to continually merge
their work against regular upstream SmartOS changes.  This is often too high a
price to pay just to include a few files, so common alternatives are:

* Install a pkgsrc bootstrap kit into the global zone and use `pkgin` to
  install additional software.
* Build software manually and copy it to `/opt` or one of the other writeable
  and permanent directories.
* Use the `/opt/custom` infrastructure provided by SmartOS to automatically
  configure third-party services on boot.

The first option, installing pkgsrc, is one which many users have chosen as it
provides an easy way to install from a large body of available software, but is
not without drawbacks.  The main issue is that any package installations which
attempt to install users will fail due to the `useradd(1M)` issue described
above, and may leave the pkgdb in an inconsistent state.  Others include issues
around handling `smf(5)`-aware packages, and packages which have build options
which may be incompatible with, or sub-optimal for, a global zone environment.

This RFD is a proposal to create an additional pkgsrc package set that is
designed for use in a SmartOS global zone, is able to correctly function in
that environment, and is optimised for operators of that environment.

## Proposal

There are 4 primary areas that require discussion in order to come to an agreed
desired package set, and we will look at them in turn.

### File system layout

This area concerns what primary prefix and support directories will be used.
The obvious choice is to simply use the same as the existing non-tools sets,
i.e.:

```
--prefix=/opt/local
--pkgdbdir=/opt/local/pkg
--pkgmandir=man
--sysconfdir=/opt/local/etc
--varbase=/var
```

but there may be other considerations involved, e.g. integration with
`/opt/custom`?

While not strictly related to the file system layout, we should also briefly
consider what name this set should have.  The current sets are:

* `i386` (32-bit)
* `x86_64` (64-bit)
* `multiarch` (32-bit with some 32-bit + 64-bit multiarch-enabled packages)
* `tools` (64-bit prefixed to `/opt/tools`)

Suggestions include `gztools`, `global`, `gz`.

Another consideration is whether to simply incorporate the changes proposed in
this RFD into the existing `tools` set rather than have a distinct new set.
This would have to continue using the `/opt/tools` prefix due to its use inside
Joyent's pkgsrc build infrastructure, but otherwise could be reused quite
easily.

### User management

This is the primary area of failure, where packages which require the creation
of users fail to execute their `INSTALL` script due to `useradd(1M)` failing.
This can leave the pkgdb in an inconsistent state.

The initial idea for handling this is to re-use existing system accounts for
all packages, using pkgsrc's existing user management infrastructure.

For example, one of the more common failures is the `cyrus-sasl` package which
is depended upon quite heavily.  By default it is built with:

```
CYRUS_USER?=	cyrus
```

and on install it tries to create its `cyrus` user and fails.

If instead we built the package with the following setting in `mk.conf`:

```
CYRUS_USER=	daemon
```

then the existing `daemon` user will be used instead and the installation will
complete successfully.

There are two issues with this approach.

* The alternate user must be chosen carefully to avoid introducing security
  issues.
* There are currently over 180 separate users created by pkgsrc.  It must be
  easy to add, update, and monitor the user variables to ensure it is not an
  onerous task and that new packages are not missed.

### SMF handling

The current pkgsrc SMF infrastructure is incompatible with the global zone.  By
default packages will attempt to register SMF manifests with the system
repository on install, but those imports will be lost on the next boot.

pkgsrc currently installs SMF manifests to `${PREFIX}/lib/svc/manifest/` and
then (unless the `PKG_SKIP_SMF` environment variable is set) executes
`/usr/sbin/svccfg import /path/to/manifest.xml` to import the manifest into
`/etc/svc/repository.db`.  This is the file which is wiped on boot, losing the
import.

SmartOS will automatically import manifests installed under `/opt/custom/smf`
and `/var/svc/manifest` on boot, and so we should look to install or copy
pkgsrc manifests into one of those directories, most likely the latter.  The
existing `svccfg import` will take care of importing the manifest for the
current boot, and the automatic import will handle future reboots.

Two immediate issues are:

* The pkgsrc SMF infrastructure is currently designed so that manifests must
  reside under the pkgsrc `${PREFIX}`.  If we decide to install directly to one
  of the automatic directories then this restriction will need to be relaxed.

* User configuration should, if possible, be retained, so that if a user
  decides to enable an SMF service rather than simply install it, this should
  be reflected in the installed manifest so that the service is correctly
  started on next boot.

### Packages and build options

This is the area which will likely have the most community involvement.  There
are two parts to consider.

#### Package selection

This is essentially answering the question "Which packages should we include in
this package set?"  Due to constraints on our build infrastructure it isn't
viable to build the full pkgsrc set.  A helpful starting point might be this,
loosely based on the current "tools" list with some extras:

```
devel/git-base
joyent/sun-jre6
lang/nodejs
lang/openjdk7
lang/perl5
net/cacti
parallel/parallel
sysutils/ansible
sysutils/apcupsd
sysutils/cfengine2
sysutils/cfengine3
sysutils/coreutils
sysutils/findutils
sysutils/puppet
sysutils/munin*
sysutils/ruby-chef
sysutils/salt
sysutils/smartmontools
sysutils/ups-nut
www/nginx
wip/zabbix
```

#### Package build options

What build options should be modified from the default sets?  Are there any
packages we should look to strip down?  Input welcome.
