---
authors: Sam Gwydir <sam.gwydir@joyent.com>, Joshua Clulow <jclulow@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Sam Gwydir
-->

# RFD 109 Run Operator-Script Earlier during Image Creation

# Overview

When a user creates an image of a VM they expect that the resulting image will
be a snapshot of the state of their VM at the time of their request. Images are
often created for easy deployment of a service, e.g. nginx or Consul. The
current image creation process is well documented:

> It will take several minutes to create an image. When  sdc-createimagefrommachine creates an image, the following things happen:
> 
> 1. Your instance is stopped to checkpoint the data on the instance so that it can be rolled back to its current state after the process ends.
> 2. The prototype instance is rebooted. 
> 3. A script runs on the prototype instance to clear root and host SSH keys, as well as common log files from the prototype instance.
> 4. An image is created from the prototype instance's root volume.
> 5. The prototype instance is rebooted to the state of the checkpoint in step 1.

This process works for most services, however, some services, like Consul,
initialize some configuration data the first time they are started. In Consul's
case, a node id based on the zone id is stored the first time Consul is started.
Thus all instances of a Consul image will share a node id -- this is highly
undesirable.

Though the documentation states that the prototype instance will be rebooted, it
is surprising to the user and unnecessary to start all daemons as well.

We propose moving the "operator-script", the mechanism that performs step 3 from
above, as early as possible in the boot order, thus avoiding the problem
outlined above and possibly improving image creation time.

# Background
The image creation process depends on the "operator script"
mechanism.  A request to CloudAPI to create an image becomes an
internal request to IMGAPI to create an image from a particular VM.

IMGAPI itself ships the operator scripts; e.g., for SmartOS zones:

    https://github.com/joyent/sdc-imgapi/blob/master/tools/prepare-image/smartos-prepare-image

It loads them from disk during the image creation API call:

    https://github.com/joyent/sdc-imgapi/blob/master/lib/images.js#L1928-L1973

And then includes them wholesale in the workflow job which actually
talks to the compute node to create the image:

    https://github.com/joyent/sdc-imgapi/blob/master/lib/images.js#L2017

---------

The workflow job arranges to run "imgadm create" on the compute node. This is
the engine that actually drives rebooting and snapshoting the zone. It is passed
the prepare script from IMGAPI using the "-s" flag to "imgadm create".

The manual page describes this flag, and then it describes the actual image
creation process (including the use of the "sdc:operator-script" key in the
"PREPARE IMAGE SCRIPT" section:

    https://smartos.org/man/1M/imgadm

---------

The two services inside the zone which fetch various metadata
properties and then execute the "sdc:operator-script" are:

    svc:/smartdc/mdata:fetch
    svc:/smartdc/mdata:execute

The XML definition of these services is shipped in the SmartOS
platform image (ramdisk) from:

    https://github.com/joyent/smartos-live/blob/master/overlay/generic/lib/svc/manifest/system/mdata.xml

The scripts run by the services are there also:

    https://github.com/joyent/smartos-live/blob/master/overlay/generic/lib/svc/method/mdata-fetch
    https://github.com/joyent/smartos-live/blob/master/overlay/generic/lib/svc/method/mdata-execute

---------

# Changes

Extract the fetching and executing of "sdc:operator-script" from "mdata:fetch"
and "mdata:execute" respectively, creating a new "operator-script" SMF service
that is a dependency of other services such that the operator script runs and
shuts down the system before any services other than the filesystem and possibly
networking start.

# Other Solutions

- It should be possible to support creating an image without restarting the VM
  to run the clean up script. If we're willing to have separate image creation
  routines for zones and KVM guests, we can improve image creation time for
  zones a great deal while solving the problems discussed above as well. KVM
  guests will probably have to continue utilizing the operator-script mechanism.
