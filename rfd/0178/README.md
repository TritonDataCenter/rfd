---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+179%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc
-->

# RFD 178 Linux Platform Image

This RFD describes the Linux Platform Image, which is part of a larger effort
described in [RFD 177](../0177/README.md).

As described in [RFD 177](../0177/README.md), the platform image is based on an
established distribution that provides the required feature and maintainability
characteristics that are needed.  We aim to use a Linux distribution and to be
a contributing member of its community.  We do not aim to be the primary
supporter of the distribution.

Triton agents, services, and configuration will installed on the compute node.
The only Triton software that will appear in the platform image is that which is
required to bootstrap installation of other Triton components.

## Requirements

1. The PI must be an ephemeral image that is booted via the Triton booter
   service.
2. For development purposes, it must be possible to boot a Linux CN in
   standalone mode without requiring a network boot.
3. The PI must be based on an actively maintained Linux distribution that has a
   track record of providing timely security updates and other fixes.  There
   should be no indication that this is unlikely to change in the foreseeable
   future.
4. The PI must support ZFS.
5. The PI must use systemd and support
   [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html)
   containers.
6. The PI must be freely distributable or an automated build process must exist
   that allows users that have a Triton head node to build PIs using automation.
7. The base distribution should be well-known enough that customers are likely
   to be able to self-support the operating system  or find third-party
   operating system support from companies that are likely to be acceptable to
   Fortune 500 purchasing departments.

## Proposed solution

Debian 10 or CentOS 8 will be used as the base image, with the intent of
minimizing reliance on distribution-specific behavior to minimize the effort
required to support any of Red Hat Enterprise Linux, CentOS, Oracle Linux,
Debian, Ubuntu, and perhaps other distributions.  It is anticipated that
installation of Triton agents on traditionally managed (not live) Linux
instances would be rather straight-forward, should the demand arise.

As much as is practical, operating system integration will happen through the
use of systemd. In particular:

- Agents and any other daemons will be managed as systemd services.
- [systemd-networkd](https://www.freedesktop.org/software/systemd/man/systemd-networkd.html)
  will be used for host network configuration.
- [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html)
  will be used for container configuration and execution.

Persistent configuration will be stored in a Triton-centric form.  As a CN boots
and as changes are pushed to the CN, the Triton-centric form will be transformed
into a transient native configuration and then made active.  This will allow
implementation details to evolve over time without requiring complex
configuration migrations.

The initial work is being done with Debian 10 in the
[linux-live](https://github.com/joyent/linux-live/tree/linuxcn) repository.

See the [platform image
document](https://github.com/joyent/linux-live/blob/linuxcn/docs/2-platform-image.md)
in the linux-live repository for the status of in-flight work on the platform
image.
