---
authors: Cody Mello <cody.mello@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent, Inc.
-->

# RFD 131 The Triton Datacenter API (DCAPI)

# Introduction

Triton datacenters are currently very weakly connected together: their UFDS
instances are linked together so that they all have the same set of users
and to share some region information, but nothing further. To help promote
the idea of linked datacenters further, we propose a new service, the
Datacenter API (henceforth abbreviated as DCAPI), for tracking all affiliated
datacenters and their relationships.

# Datacenter Representation

Datacenters will be represented as an object with the following attributes:

- `"name"`, the name of a datacenter (e.g. `"us-east-1"`)
- `"id"`, a unique 32-bit identifier for this datacenter

# Regions Representation

A region is a group of datacenters that are geographically close to each other,
and have been grouped together to provide a service (such as Manta). A region
has the following attributes:

- `"name"`, the name of the region (e.g. `"us-east"`)
- `"datacenter"`, an array of datacenters in the region (e.g. `[ "us-east-1", "us-east-2", "us-east-3" ]`)

# Coordinating DCAPI Instances

It is extremely important that all DCAPI instances remain coordinated: opinion
on who's in a region should not differ from datacenter to datacenter, and two
datacenters should never be assigned the same identifier. We will need to
identify a suitable method for coordination between datacenters, and ways for
adding new datacenters.
