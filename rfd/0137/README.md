---
authors: Robert Mustacchi <rm@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+137%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent, Inc.
-->

# RFD 137 CPU Autoreplacement and ID Synthesis

Today, the illumos fault management architecture (FMA) watches for
issues with hardware and notes when they are faulty. One of the things
that it looks after are issues with CPUs. For example, if a CPU has a
series of errors occur on it, FMA may end up making the decision to
offline the CPU.

In such cases, as part of offlining the CPU, FMA opens a case that
records that the part is faulty. The case can subsequently be closed
either because a component is replaced or the operator explicitly
acquits the component. The way that FMA knows that a component has been
replaced is based upon serial number or similar information that is part
of the FRU (field replaceable unit) and contained in the FMRI (fault
management resource indicator).

Consequently, if a component lacks such information, FMA will not be
able to automatically close the case and it will fall to the operator to
ensure that the proper component was replaced and inform the system.

As it happens, this is a major problem. This problem is magnified due to
the labeling issues outlined in the current draft of our [RAS
Specifications](https://eng.joyent.com/ras/). To summarize, the CPU
socket and the silkscreen often do not align.

### CPU Identification

Traditionally CPUs have not exposed much identifying information. During
the Pentium III era, there was a short-lived serial number exposed in
cpuid. However, this was deemed to have privacy concerns, especially
because all software could read it.

In recent server SKUs (multi-socket Xeons), Intel has offered a means of
identifying a processor through what they call PPIN, which is intended
for inventory management. See the [Public E5 v4 Product Family
Documentation](https://www.intel.com/content/dam/www/public/us/en/documents/datasheets/xeon-e5-v4-datasheet-vol-2.pdf)
for more information. Based on this, it is possible for us to construct
something that we can use for RAS purposes. This information will not be
available to a non-global zone. It will require cooperation from the
systems firmware.

### ID Scheme

Based on available information, will we synthesize an illumos-specific
ID string for a processor. This scheme will vary based on the vendor and
will allow itself to be versioned in subsequent generations of systems.

The basic scheme is the following:

```
iv0-%vendor-%vendorspecific
iv0-INTC-%vendorspecific
```

The `iv0` portion of the name is used to indicate that this is illumos
version zero. It is expected that for a given processor, the scheme
should not change so as not to cause the system to think that the CPUs
in the system were replaced. However, this allows a newer generation to
use a different schema.

The next part of the string is the name of the vendor. So, in this case
we would use INTC. If we had an AMD scheme for this, we would use 'AMD'
in its place. Finally, the latter part is specific to the actually
processor family.

#### Intel Xeon Scheme

The initial scheme will have the following form:

```
iv0-INTC-%cpuidsig-%ppin
```

Here both the CPUID signature and the PPIN will be printed as
**hexadecimal** values. These will not be zero padded values. There will
be no leading 0x used for either entry.

#### Use of versioning

The core use of versioning here is to deal with a subsequent CPU
generation changing the required information for uniqueness. The version
is specific to the **vendor**. Let's look at an example of how such
versioning might occur.

Let's call the vendor of such processors LINK and assume that their
initial scheme looked like Intel's. However, in their new generation of
processors, let's imagine what would happen if they changed to providing
a classic [RFC 4112 UUID](https://tools.ietf.org/html/rfc4122).

For all previous, supported generations of LINK based processors,
nothing would change. They would use the existing `iv0-LINK-...` scheme.
However, the new generation and onwards would have a system that looked
like:

```
iv1-LINK-%uuid_string
iv1-LINK-b92060fe-4416-11e8-87f7-7b4cbfa373cf
```

To emphasize, the version number here really represents a generation of
processors that have their own unique way of numbering. If multiple
generations of a vendor's processor are guaranteed to be unique and use
the same schema then we should not change this. However, incrementing
the version number when we have these changes will allow us to more
easily tell that these things cannot be directly comparable, especially
if for some reason there would be overlap.

If this changed again in another generation, then we would move to an
`iv2-LINK-` format.

### Exposure via FM

To consume this information, a new routine will be added to the Intel
`cpu_module.h` header which will allow it to obtain a `const char *`
value that has the string, assuming that one exists. If it does, it will
be added to the `nvlist_t` payload that is consumed by `/dev/fm`
through its `FM_IOC_PHYSCPU_INFO` ioctl. This will then be consumed
by the corresponding FM topology modules in user land to allow for
autoreplace to work.

#### FRU changes

One of the biggest challenges that we have with this scheme is that the
FRU of the processor can change in this scheme. This can happen for a
couple of reasons:

* FM detected an error on an older system and we rebooted to a system
that now has support for the synthetic serial number.

* FM detected an error on a new system that supports the synthetic
serial numbers and rebooted to a system prior to this support.

* FM detected an error on a new system that supports the synthetic
serial numbers and a BIOS change locked the ability to synthesize the
serial number.

* FM detected an error on a new system that does not support the
synthetic serial number, but was rebooted and a BIOS change unlocked the
ability to synthesize the serial number.

All of these cases represent instances where we cannot know for certain
whether or not a replacement occurred. In fact, the odds are high that
the replacement did not occur. As such, we need to make sure that FM is
enhanced such that in all of these cases a fault is not considered to
have been autoreplaced and that instead the operator must manually clear
such faults.

This means that the only time the hc schema CPU module would consider a
replacement as having occured is if the original faulted FMRI had a
synthesized serial number and the replacement part did as well.
Othewrise, we will always consider the fault as persisting.

The only caveat wiht this approach is that if we have one of these
changes and the part has not been replaced, we can end up with two FRUs
that both have faults (one with and one without). However, because
these FRUs will refer to the same logical CPUs, we should still see them
being retired.
