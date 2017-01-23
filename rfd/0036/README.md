---
authors: Casey Bisson <casey.bisson@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# RFD 36 Mariposa

Mariposa is a scheduler service running in Triton that supports a variety of service and instance types and is tightly integrated with other Triton components.

We are pursuing Mariposa and introducing a new scheduler in the market, rather than integrating an existing scheduler, because of the requirement that it be a tightly integrated core service of Triton. This integration includes:

- Users, orgs, and projects as described in [RFD13](https://github.com/joyent/rfd/blob/master/rfd/0013/README.md).
- Support for Triton and Manta compute types, including [Docker Containers](https://docs.joyent.com/public-cloud/instances/docker), [infrastructure containers](https://docs.joyent.com/public-cloud/instances/infrastructure), and [hardware virtual machines](https://docs.joyent.com/public-cloud/instances/virtual-machines), in addition to [Manta functions](https://apidocs.joyent.com/manta/jobs-reference.html).
- A single instance scheduling/provisioning layer. Because Triton runs containers on bare metal, an entire management layer -- customer cluster management and scheduling/provisioning of containers in that cluster -- can be eliminated. In its place, containers can be provisioned using cloud provisioning tools, and customers can scale containers without needing to scale VMs or place containers in them.

Contents:

- [Concepts](#concepts)
- `triton` commands
  - [`triton project...`](project.md)
  - [`triton service...`](service.md)
  - [`triton meta...`](meta.md)
  - [`triton queue...`](queue.md)
- Manifest files
	- [Project manifest](project-manifest.md)
	- [Service manifest](service-manifest.md)
- User stories
	- [jupiter.example.com: what it is and development workflow](./user-stories/jupiter-example-com.md)
	- [Automatically building and testing jupiter.example.com with Jenkins](./user-stories/jupiter-example-com-jenkins.md)
	- [Running jupiter.example.com in multiple data centers](./user-stories/jupiter-example-com-multi-dc.md)
	- [Health-checking, monitoring, and scaling jupiter.example.com](./user-stories/jupiter-example-com-monitoring-and-health.md)
	- [Creating, copying, and moving projects like microsite.jupiter.example.com](./user-stories/microsite-jupiter-example-com.md) (also includes secret management)



## Concepts

### Project

A project is a collection of related compute instances and other related resources ([see "projects" in RFD13](../0013/README.md#proposal) for more detail). A service and all its instances _must_ be a member of a single project. Permissions about who can view or modify a service are set according to RFD13 rules for the project.

### Service

Services are at the core of Mariposa. A service is defined by a service manifest that specifies a single image (any image supported by IMGAPI) or Manta job command. A service may be run in a single compute instance, or can be scaled scaled to any number of instances as needed.

A service may represent a complete application, if that application runs in a single container, but most applications will be comprised of multiple services in a single project.

### Service and compute types

Not all services run continuously. The growing interest in "function as a service" offerings (as demonstrated in Manta Jobs, and later in AWS' Lambda), as well as the common reality of scheduled batch jobs, indicates that Mariposa should include support for non-continuous services.

These types may include:

- `continuous` runs continuously until stopped
- `event` runs when triggered, is not restarted when it stops
- `scheduled` runs according to defined schedule, is not restarted when it stops

Only `continuous` is required for the MVP.

The types of compute providing these services may include:

- `docker` (default)
- `infrastructure|lx|smartmachine`
- `kvm|vm|hvm`
- `manta`

Only `docker`,`infrastructure`, and `kvm` are required for the MVP.

### Task queue

Scaling, upgrading, even stopping all the instances of an app can take time...sometimes significant time. To represent this to the user, Triton must expose the task queue and offer the ability to cancel jobs.

This document defines tasks specific to deploying services, but the task queue is not limited to services.

### Project meta (including secrets)

Many applications require configuration values which are undesirable or unsafe to set in the application image. These can include license keys, a flag setting whether it's a staging or production environment, usernames and passwords, and other details.

This document proposes a simple method of storing those details and injecting them into containers. It is not intended to provide the rich features of solutions like Hashicorp's Vault, instead it is intended to provide a basic solution that is easy to use in a broad variety of applications.
