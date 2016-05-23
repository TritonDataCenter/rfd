----
authors: Robert Mustacchi <rm@joyent.com>
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

# RFD 31 libscsi and uscsi(7I) Improvements for Firmware Upgrade

If there is one rule of firmware, it is that it will inevitably have
bugs and that field upgrades will be required. It is our experience that
this is certainly true for disk drives, where this problem is most
egregious due to the sheer quantity of drives that need to be upgraded.

While the broader system should make managing and rolling out such
upgrades for all types of FRUs (field replacement units) easier, the
present focus of this RFD is on the interfaces that illumos provides for
upgrading disks that leverage SCSI.

## Background and Problems

The history of firmware upgrades on systems is fraught with peril, DOS,
and then more peril. While an individual FRU cannot remain in service
while a firmware upgrade is being performed, having to switch to an
alternative operating system and take down service for the entire box is
not acceptable. To that end, illumos has the
[fwflash(1M)](http://illumos.org/man/1m/fwflash) command which can be
used to both list the firmware versions of parts and perform firmware
upgrade.

Firmware upgrade of disks is plagued by two different, but related
problems.

* The fwflash(1M) tool hard codes a maximum firmware size of 1.4 MiB
which is suspiciously close to the size of a floppy disk.

There is no basis for this value. SCSI itself supports a maximum
transfer of around 16 MiB and provides facilities to query what the
maximum supported buffer size is and devices advertise the maximum size
that they'll support.

* uscsi(7I) does not support partial DMA. This is compounded by the
general lack of use of an IOMMU on x86.

It's worth talking about why this is a problem in more detail. An
example of how it might manifest is discussed in
[illumos#5012](https://www.illumos.org/issues/5012). If a given
operation cannot fit in one contiguous DMA buffer, then the operation
must be spread out across multiple DMA windows. The underlying buffer is
bound into the smaller DMA window. It precedes to slide along to perform
this activity, binding different portions. The end result is that a
single logical operation is broken up into multiple operations.

This works; however, it is complicated in the face of retries. If for
some reason a device needs to retry an operation, then it may have to
replay the entire transaction, meaning all of the various commands that
caused DMA transactions. This is fine if and only if the various
operations are idempotent during a given period. For example, when
performing reads and writes of a sector of a device, those operations
are idempotent, even though you may opt to overwrite that disk sector
some time in the future, while performing the single I/O it will always
be the same. 

uscsi(7I) doesn't have this same guarantee. Because uscsi(7I) allows for
arbitrary SCSI commands to be generated and sent, they may or may not be
idempotent at all, as the underlying set of SCSI commands that are
possible to send are quite varied.

While an I/O MMU does solve address this problem by allowing the logical
DMA to be broken up into multiple series of physically disjoint pages,
many x86 systems do not have an I/O MMU or enable it. Therefore a
solution needs to be worked out that addresses this.

## Proposals

The key observation here is that we're trying to perform firmware
upgrade specifically, not solve this problem for every possible
uscsi(7I) ioctl that one might issue. This means that we specifically
care about the WRITE BUFFER SCSI command (SPC-3 6.35), which has
different modes for writing firmware to devices. There are two modes
that we generally care about. Note, the phrase microcode is used below
to match the SCSI specification; however, it can be used interchangeably
with firmware.

* Mode 5 - Download Microcode Data (to the device) and Save
* Mode 7 - Download Microcode Data (to the device) with Offsets and Save

Mode 5 is used to perform a single download of the entire firmware image
in a single SCSI command. This is the form that the fwflash(1M) utility
uses today.

Mode 7 is designed to allow for multiple writes into the buffer.
Specifically the specification allows for the firmware download to occur
across multiple WRITE BUFFER requests. Using this mode, we can handle
the partial writes as long as we can determine what the right size of
the buffer is.

Ideally we would say that if we could do the entire write of the
firmware image in one go then we'll use a single WRITE BUFFER command
with mode 5, otherwise we'll issue a number of mode 7 requests. Mode 7
offsets are subject to a required alignment which we can determine via
the READ BUFFER command (SPC-3 6.15) mode 3.

For this to work though, we need to know what that maximum buffer size
is. While it may be tempting to try and determine it by doing a single
mode 5 write and then having the buffer size until one works, it makes
more sense to instead plumb that through the stack as the kernel
actually knows. For example, in sd(7D), it's contained in the `struct
sd_lun`'s `un_max_xfer_size` member. The first step of this is to allow a
user to query this through uscsi(7I).

#### uscsi(7I) Changes

To allow consumers of uscsi(7I) to determine what the actual maximum
transfer size is, I propose to add a new ioctl that drivers may support
called `USCSIMAXXFER` along with a new type that is used with the ioctl.
The following is an excerpt from the updated uscsi(7I) manual page which
describes the ioctl.

```
       USCSIMAXXFER
                   The argument is a pointer to a uscsi_xfer_t value. The
                   maximum transfer size that can be used with the USCSICMD
                   ioctl for the current device will be returned in the
                   uscsi_xfer_t. The actual transfer size may be limited
                   further based on the specific SCSI device and details
                   of the implemented command.


                   Not all devices which support the USCSICMD ioctl also
                   support the USCSIMAXXFER ioctl.
```

The definition of the uscsi_xfer_t is provided in the uscsi header files
and is simply a uint64_t. It looks like:

```
typedef	uint64_t       usci_xfer_t
```

This new ioctl has the exact same requirements for use as the existing
`USCSICMD` ioctl. A user that does not have the privilege to use the
`USCSICMD` ioctl will not be able to use the `USCSIMAXXFER` ioctl.

Note that at this time, only sd(7D) will be enhanced to support the
`USCSIMAXXFER` ioctl. This is part of the reason that a new ioctl was
chosen and that the reserved portion of a `uscsi_cmd_t` was not used, to
allow for different devices to opt into supporting this as the need
arises.

#### libscsi Changes

libscsi is a private library that was introduced by Eric Schrock in
`PSARC 2008/196 libscsi and libses`. The work originally came as part of
the work done by Fishworks. While we do not have the same firmware
upgrade tooling that the team there used (it is lost to the sands of
time behind closed doors at Oracle), it was built upon libscsi and
friends.

Importantly, fwflash(1M) uses libscsi to do the heavy lifting in a
rather useful way. To enable this, a new function will be added to
libscsi to allow a user to determine the maximum amount of bytes that
can be transferred in a single command. The current function prototype
looks like:

```
extern int libscsi_max_transfer(libscsi_target_t *, size_t *);
```

This function will leverage the appropriate libscsi engine (currently
only uscsi) based on the target to determine the maximum transfer size.
Note a `size_t` here is explicitly chosen for a few reasons as opposed
to using a 64-bit capable type similar to the `uscsi_xfer_t`. libscsi
already describes buffer sizes using a `size_t` (see
`libscsi_get_buffer()` or `libscsi_set_datalen()`). Part of this is
likely based on the fact that uscsi(7I) leverages values of `size_t`, thus
causing the ioctl to be different on ILP32 and LP64.

I made the concious choice to try and give an accurate value via the
uscsi(7I) ioctl interface even if consumers could not do more.
Practically speaking, this isn't a realistic problem as SCSI itself
generally has a 16 MiB maximum transfer size. If such a case where to
occur, the uscsi engine of libscsi would silently truncate the value at
the maximum size of a `size_t` on the appropriate platform.

In addition, the libscsi engine API will need to be enhanced to provide
a new means of asking the engine this question. This private interface
will be amended to add another entry point to the `libscsi_engine_ops_t`
structure. It will add a new member that looks like:

```
int (*lseo_max_transfer)(libscsi_hdl_t *, void *, size_t *);
```

As part of this the value of `LIBSCSI_VERSION` will be incremented to
version 2. Note as this is a private interface, older versions and out
of gate consumers should not be a problem; however, incrementing the
interface version should still be done. 

### Determining the Maximum Firmware Image Size

Arguably, this is just a simple bug in fwflash(1M); however, as it ties
into the previous section it's worth mentioning here again explicitly.
To determine the maximum image size rather than assuming anything, we
must actually ask the device. Specifically we can use the READ BUFFER
command to determine the maximum size that will be accepted for the
firmware image. The mode 3 option 'descriptor' returns both the maximum
image size and the required offset alignment.

The generic SD verification module for fwflash(1M) will be updated to
use this as the basis for the maximum size rather than its current
assumption.

## Conclusions and Future Directions

With these changes to the stack, it should be possible to address all of
the current issues around firmware upgrade of devices handled by sd.
This is particularly prominent as many users are using `mpt_sas` which
has a single transfer size of 1 MiB and the firmware for many drives
exceeds that size.

It is planned that all of these changes will be integrated at the same
time in illumos-joyent and after a period of additional production
experience, integrated into illumos.

In the future, we should have RFDs that aggregate information about
component firmware revisions across a fleet so that operators can
understand what versions firmware is at and we should also look at
providing the means for rolling out rolling upgrades of these across
systems in a similar fashion to how the Fishworks appliances rolled out
firmware upgrades across all the disks in a chassis.

Today fwflash(1M) can already handle general disks, SES devices, and
some various IB and FC devices. We should evaluate having specific
firmware update mechansims for SPs, NIC EEPROMs, etc. We should also do
work to make sure that all of the versioning information is shared with
the topo snapshot so that we can better aggregate and report on this in
fmtopo and an eventual DC-wide aggregation.
