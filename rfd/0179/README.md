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

# RFD 179 Linux Compute Node Networking

This RFD describes the networking on Linux compute nodes.  This is part of a
larger effort described in [RFD 177](../0177/README.md).

## Problem statement

Linux compute node networking needs to be implemented in such a way that it
implements the following features:

- NIC tags for associating links with logical networks
- Network interfaces that allow communication between container instances on the
  same network.
- The ability to add anti-spoof protections to each virtual NIC in such a way
  that they can't be removed within the container while still allowing the
  container to add additional firewall rules.

## Proposed solution

```
  +---------+       +-------------+
  |  eth0   |-------| 10.99.99.41 |
  | (admin) |       +-------------+
  +---------+

  +---------+       +-------------+       +-------------+
  |  eth0   |-------| br-admin0   |-------| 10.99.99.41 |
  +---------+       +-------------+       +-------------+

                    +-------------+
                    | veth-vm1.41 |
                    +-------------+
```

## Considerations

- bridge
- net namespace
