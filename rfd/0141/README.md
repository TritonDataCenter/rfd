---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+141%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 141 Platform Image Build v2 (PIBv2)

This RFD describes improvements to the Platform Image (PI) build process and the
common build environment (CBE) to accomplish the following goals:

- Allow CI-based builds of typical illumos-joyent changes in a way that doesn't
  require a rebuild of the build tools.
- Allow developers to perform full builds of illumos-joyent and generate a new
  platform image without requiring a build CBE components or illumos-extra.
- Allow developers to use relatively current platform images without worrying
  that their changes break builds on platforms that are relatively old.
- Allow one or many developers to simultaneously use the same build zone on
  both sides of a CBE flag day.

## Background: Platform Image Build v1

This section describes the organization of the PI build as of May, 2018.  Surely
there was a PIBv0 and perhaps earlier, but that's not interesting now.  This
section is present in this draft to facilitate discussion of later sections.

The PI is built from components found in the following repositories:

- [smartos-live](https://github.com/joyent/smartos-live/) is the topmost
  repository containing the makefiles and utilities required to the PI.  It also
  delivers programs like `vmadm`, `vmadmd`, and the metadata server which
  provide stable interfaces used by cloud operators, Triton software, and the
  various containers and virtual machines that will run on a compute node.
- [illumos-joyent](https://github.com/joyent/illumos-joyent/) is the SmartOS
  fork of [illumos-gate](https://github.com/illumos/illumos-gate).  Former
  Solaris developers will recognize this as the OS/Net or ON consolidation.
- [illumos-extra](https://github.com/joyent/illumos-extra/) contains various
  open source components that are built using the tarball plus patches approach.
  Many of these components are built twice.  A bootstrap (strap) build is used
  to build a native version of a subset of the components so that they may be
  used for a cross-compile of illumos-joyent.  After illumos-joyent is built,
  a build of a different, yet overlapping, subset of illumos-extra is performed
  to build components that will be delivered in the PI.
- [ur-agent](https://github.com/joyent/sdc-ur-agent/) provides the Ur agent,
  which is used to connect a compute node to the head node
- [kvm](https://github.com/joyent/illumos-kvm/) provides an illumos port of
  [KVM](https://www.linux-kvm.org/page/Main_Page).
- [kvm-cmd](https://github.com/joyent/illumos-kvm-cmd) provides an illumos port
  of [QEMU](https://www.qemu.org/), which is used with KVM.
- [mdata-client](https://github.com/joyent/mdata-client) provides tools used for
  metadata retrieval and manipulation within guests.

Every PI full PI build builds everything above.  This means that to perform a
get a PI to test a relatively small change in illumos-joyent, the developer
must wait for a build of gcc, two builds of Perl, etc.  A recent Jenkins build
of a one line change in illumos-joyent took 138 minutes.  24 minutes of that was
the illumos-joyent build.  The vast majority of the rest of the time was spent
building illumos-extra twice.

The various component builds install software into various `proto` root
directories.  Relative to the root of smartos-live, these are:

- `proto.strap` contains the CBE tools built from illumos-extra.
- `proto` contains a mixture of content from the illumos-joyent build, the
  second illumos-extra build, and most other components.
- `proto.boot` contains grub components required to create bootable media.
- `overlay/generic` contains various files that are delivered into the platform
  image as-is.  This is how most SmartOS-specific services, zone brands, etc.
  are delivered.
- `man/man` contains man pages for software whose source lives in smartos-live.

Each component delivers a `manifest` file that indicates which subset of the
proto content is to be included in the PI.  The `tools/build_live` script uses
the manifest content and the list of proto directories to populate file systems
that will be included in the PI.

There is a spoken rule that the CBE involves a PI from sometime in 2015.  This
is contradicted by the [Building SmartOS on
SmartOS](projects/local/kvm-cmd/libpng-1.5.4/proto) page.  Futher, Jenkins
builds are being performed with the 20180329T002515Z PI.  Staging machines used
by developers for build zones are using the same PI.  Short of running builds
(very slowly) in VMware, there is no way for Joyent engineers to build a PI on
the legendary PI from 2015.

The [SDC Relase
instructions](https://mo.joyent.com/docs/engdoc/master/sdcrelease/index.html)
indicate that release builds are also performed using Jenkins.  All three
(platform, platform-debug, and smartos) Jenkins projects seem to be building
with a PI form March 2018 rather than the 2015 PI.

## Common Build Environment Platform Image

The PI delivers the operating system and other base components.  Unlike
application software, it is mostly independent of other software.  Software on
which it depends will typically be accessed over the network via standards-based
protocols or Triton APIs.  Software that depends on it should use only the
public ABI.  This means that it should be safe for the PI to be built using a
current PI.  Indeed, trough accident it seems that point has been proven by the
fact that all Jenkins builds are now using the 20180329T002515Z PI.

This RFD seeks to obsolete the fabled 2015 image as the official PI for building
new PIs.  Instead, the supported PI for all builds is 20180329T002515Z or later.
The oldest PI supported will change from time to time so as to minimize the
burden of backwards compatibility in the PI build process.  Examples of things
that may cause the oldest supported PI to be a newer PI include:

- Any change that would otherwise require that the build process make one or
  more special cases to support the old PI.
- Any change that requires non-trivial extra work for the sole purpose of
  supporting old PIs.

The smartos-live `configure` script will verify that the PI on which it is
running is no older than the oldest supported PI.

## Common Build Environment Tools

The tools required to build smartos-live and its subcomponents will be delivered
in binary form via pkgsrc.  This means that `proto.strap` will no longer be
populated during each build.

From time-to-time the PI may require changes to the set of required CBE tools.
To allow this, a pkgsrc repo will be created for each incompatible change to the
set of those tools.  Generally, adding an additional package or a security fix
to an existing package will not be considered an incompatible change.  Upgrading
gcc is likely to be an incompatible change.

Each pkgsrc tree will be rooted at `/opt/smartos-cbe/<version>`.  The
smartos-live `configure` script will ensure that the appropriate CBE tools
version is present and up to date.  Each pkgsrc tree will correspond to a branch
in [joyent/pkgsrc](https://github.com/joyent/pkgsrc/).  Each of the packages in
the pkgsrc repo for a particular CBE will be built on the oldest PI supported.

The smartos-live build process will set PATH
and any other required environment variables to use tools from
`/opt/smartos-cbe/<version>` and NOT `/opt/local` or similar.

## Death to illumos-extra!  Long live smartos-extra!

The rate of change of illumos-extra is quite slow compared to that of
smartos-live and illumos-joyent and the nature of the build is quite similar to
that of pkgsrc.  For those reasons, it makes sense to transition illumos-extra
to another branch (joyent/smartos-extra) of pkgsrc.

To allow a full clobber of illumos-joyent, including its proto area,
smartos-extra will be rooted in `proto.extra`.

While building a PI, the build may build the illumos-extra packages or it may
install pre-built version.  Most changes to the joyent/smartos-extra branch
should result in the creation of a new tarball named
`smartos-extra-<hash>.tar.bz2` or similar.  The `<hash>` is the hash of the HEAD
changeset from which it was built.  This tarball contains the entire pkgsrc
build root (`proto.extra`).

The smartos-live build process will automatically determine if a pre-built
version `proto.extra` will be used.  The process will involve checking the hash
of the HEAD of the joyent/smartos-extra branch and checking to see if a matching
tarball is available from a well-known location.  If so, the tarball is
retrieved and extracted into `proto.extra`.  Otherwise, a pkgsrc build is
performed in the joyent/smartos-extra branch.  In addition to a hash mismatch,
uncommitted changes in smartos-extra will also trigger a local build.

If any component in smartos-extra is using private interfaces from
illumos-joyent and those interfaces change, it will be necessary to trigger a
rebuild of smartos-extra.  A file in smartos-extra will be used to store the
hash of the oldest supported illumos-joyent.  When an incompatible change
happens, this file will need to change, which will trigger a full build and
indicate the generation of a new tarball.

The smartos-extra tarball will be generated on a machine running the oldest
supported PI.

## illumos-joyent gets its own proto

To allow a full rebuild of illumos-joyent without forcing a rebuild or
re-download of other components, illumos-joyent needs to install into its own
proto directory.  This new proto directory will be `proto.illumos`.

To perform a fully clean build of illumos-joyent, it should be possible to do
something along the lines of `make clobber-illumos`, which would do something
along the lines of:

```
cd projects/illumos && git clean -xdf .
rm -rf proto.illumos
rm 0-illumos.stamp
```

## Old and new build processes

The PIBv1 build process is:

```
$ git clone git@github.com:joyent/smartos-live.git
$ cd smartos-live
$ cp sample.configure.smartos configure.smartos
$ ./configure
$ make live
   (wait 2 - 2.5 hours)
$
```

The PIBv2 build process is:

```
$ git clone git@github.com:joyent/smartos-live.git
$ cd smartos-live
$ cp sample.configure.smartos configure.smartos
$ ./configure
$ make live
   (wait about 30 minutes in typical cases)
$
```

If the tarball for `proto.extra` is missing, the build process will be about an
hour longer.

