---
authors: Jerry Jelinek <jerry@joyent.com>, Patrick Mooney (pmooney@joyent.com>
state: draft
---

# RFD 15 Reduce/Eliminate runtime LX image customization

## Problem

The handling for customizing images so that they run under lx is disjoint
between the creation of the image and using the image on lx. It depends on
runtime scripts which modify files in the image during install & boot.
Supporting new images (e.g. a new release of fedora or alpine) often requires
modifications to the platform scripts to customize the image appropriately.

Some of these runtime image customizations are for services that are run during
bootup and which block booting because those services do not work. There are
also configuration files which are modified and misc. other changes.

As an aside, because Docker does not normally boot a full system (e.g. one
using upstart or systemd) this is less of an issue for Docker, although
it is possible to use Docker with full system images and we do not control
those images.

## Goal

Most, if not all, of the image modifications should be made at image creation
time so that we can roll out new images onto existing platforms at any time.

Ideally there will be few modifications to the image as compared to the
original since lx should handle most apps running in the zone. However, some
parts of the emulation are incomplete or may never be implemented. Any service
which depends on one of those features, and which can block the image from
booting up, will need modification.

All instance-specific customization should be performed at bootup by our
in-zone service (rc.local) and driven by the metadata.

## Background

The current approach to customizing images for lx started before we had any
images created by our standardized process. We have continued to live with
this but as time goes on it becomes more and more problematic.

In general the Ubuntu images are the cleanest since we made an explicit effort
to avoid customizing the official Canonical bits as part of our meetup with
Canonical. No such work has been done for Apine, Centos, Fedora, etc.

## Approach

The existing image customization code is in the following scripts in the
illumos-joyent repo under usr/src/lib/brand/lx/zone:

  * lx_install.ksh
  * lx_boot_zone_busybox.ksh
  * lx_boot_zone_debian.ksh
  * lx_boot_zone_redhat.ksh
  * lx_boot_zone_ubuntu.ksh

These scripts can be used as a guide to see what customization we should be
doing as part of image creation.

The image modifications fall into the following general categories:

  1. creating directories which are needed (e.g. /native).
  2. setting up ld.config so native apps can run
  3. setting up symlinks for native files
  4. cleaning up config files (e.g. removing invalid entries from /etc/fstab,
     inittab configuration, selinux, etc.)
  5. populating resolv.conf (not done for docker)
  6. creating fake services (e.g. to emit service events for services we can't
     run but on which other services depend, network setup, etc.)
  7. disabling services
     - We originally disabled a lot of services because they were obviously
       unneeded in a zone. For Ubuntu we no longer do that and we just let
       those services come up (and possibly fail). We need to do that
       evaluation for the other distros.
     - We need to disable services which don't come up and which block
       booting. For upstart that can be done by adding an override file for
       that service to the image. We need to identify these services and do
       something similar for systemd, sysvinit, etc.
     - When possible we can try to leverage the "container awareness" of the
       distro to avoid starting services which don't work in a container.

Many of these customizations should be easy to make at image creation time
(e.g. mkdir some directories, pre-cleanup some files, override services, etc.).

We already have our own service (/etc/rc.d/rc.local) we're adding to each
image. This service should be enhanced to perform the instance specific
customization, such as using the metadata to populate the resolv.conf file
for that specific zone (the docker handling already does this differently).

Issues
------

We need to phase this in so that new images are cleaner but at the same time
we need to continue to work with the existing images which depend on runtime
customization.

We should enhance the platform customization scripts so that they can detect
when an image already has some customization and the scripts should then skip
over that work. We need to determine what happens with the existing scripts if
they are given an image which is already customized.

We need to continue to handle full system Docker images, all of which originate
outside of our control.

We need to determine how likely it is for a user to install/update packages
in their instance which will require runtime customization for the zone to
continue to boot. We may be able to control some of this by installing our own
package which manages some of the customized files instead of doing runtime
customization.

Our own service (rc.local) runs late during boot so it is limited as to the
runtime customization it can do for services that start earlier. We need to
investigate what issues this will cause and may need to work on moving this
service earlier in the boot process.
