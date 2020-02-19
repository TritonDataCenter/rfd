---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+177%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc
-->

# RFD 177 Linux Compute Node Umbrella

Joyent is exploring the introduction of Linux Compute Nodes.  This RFD serves as
an umbrella for various RFDs that are related to this effort.

## Problem statement

There are multiple problems to address:

1. Those that would like to run containerized Linux workloads have an ever
   increasing compatibility gap between the capabilities of the SmartOS lx brand
   and the features used by containers.
2. Some potential users of Triton have hardware that currently runs Linux but
   cannot run SmartOS due to lack of suitable drivers.
3. Some potential Triton users would prefer to use Linux due to familiarity.

## Proposed solution

The proposed solution is to provide interfaces that are familiar to Triton on
Linux Compute Nodes.

The solution will involve use of a platform image that is based on an
established distribution that provides the required feature and maintainability
characteristics that are needed.  We aim to use a Linux distribution and to be
a contributing member of its community.  We do not aim to be the primary
supporter of the distribution.

Triton agents, services, and configuration will installed on the compute node.
The only Triton software that will appear in the platform image is that which is
required to bootstrap installation of other Triton components.

### In scope

For a Linux CN to be a full-fledged member of Triton, it needs to support the
following.  The MVP list is shorter.

- Linux Platform Image
  - Booted via ipxe using booter
  - Persistent storage in a ZFS pool
  - Server setup using ur-agent
- Compute node agents
  - amon-agent and amon-relay: Monitoring and alerting
  - config-agent: SAPI-based configuration management
  - cn-agent: Manages agents, container instances (aka instance, VM), images;
    executes arbitrary commands.
  - cmon-agent: Exposes metrics about the CN and each instance for use by
    Prometheus.
  - firewaller: Configures per-instance firewall rules for Cloud Firewall.
  - net-agent: Tracks per-instance NIC changes, persisting information in NAPI
  - vm-agent: Tracks per-instance changes, persisting information in VMAPI.
- Compute node services
  - metadata service: Provides instance-specific configuration information (e.g.
    ssh keys) to instances.
- Images
  - Existing lx images should work with Linux containers (lxc)

### Out of scope

The following are out of scope:

- Linux headnode.  A SmartOS headnode will continue to be required.
- HVM instances.  HVM efforts are concentrated on bhyve on SmartOS.
- joyent/joyent-minimal/SmartOS containers.  We will not teach Linux to emulate
  SmartOS.
- Cloud firewall logging

### Scope TBD

The following are TBD

- Billing reports via hagfish-watcher
- Support for triton-docker

## Related RFDs

- [RFD 178](../0178/README.md) Linux Platform Image
- [RFD 179](../0179/README.md) Linux Compute Node Networking
- [RFD 180](../0180/README.md) Linux Compute Node Containers
