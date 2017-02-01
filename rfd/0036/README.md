---
authors: Casey Bisson <casey.bisson@joyent.com>
state: draft
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

Cloud infrastructure (IaaS) providers offer compute, network, and storage resources on which applications can be built and operated. However, those solutions leave it to the customer to assemble those infrastructure components to meet their needs. A given application might require several compute instances for a given component, but the customer is typically responsible for maintaining a mental model of their application, provisioning each instance, and then recognizing the compute instances that support a given software component within a larger list of instances.

Template-driven provisioning tools like Terraform and many others, along with judicious tagging of instances provide some help to infrastructure customers, but even then there remains a significant gap between raw infrastructure and the applications IaaS customers wish to build and run.

This RFD proposes features that would allow users to organize their infrastructure in ways that better represent their application components. The first of these organizing concepts is the *service*. A service is a collection of compute instances running the same software image with the same configuration, and a collection of services is called a *project*.


## Concepts

### Organizations, projects, users

Significant aspects of this RFD assume the existence of RBACv2 ([proposed in RFD13](../0013/README.md#proposal), with implementation discussion in [RFD48](../0048) and [49](../0049)) and the concepts it introduces, including "organizations" and "projects," and new definition for "users."

The following understanding of those objects is used throughout:

- An organization is a collection of users and projects.
- Any number of organizations can be defined.
- A user must be a member of one or more organizations.
- A user is always a member of their personal organization.
- An organization may have any number of users and projects.
- A project must be a member of one organization.
- A project may have any number of users.

The model for this is GitHub's organizations, users, and repositories. Projects (similar to GitHub's repositories) are further defined below and throughout this document.

We will expand the following diagram with additional components as we introduce them:

```
              +-------------+
          +---+Organizations| --+
          |   +-------------+   |
          |                     |
      +---v----+             +--v--+
      |Projects|<----------->|Users|
      +--------+             +-----+
```

### Service

Services are at the core of Mariposa. Services are any number of compute instances running the same software image and configuration. A service may be run in a single compute instance, or can be scaled scaled to any number of instances as needed.

A service may represent a complete application, if that application runs in a single container, but it's expected that most applications will be comprised of multiple services running together as a [project](#project).

```
          +-------------+
      +---+Organizations| --+
      |   +-------------+   |
      |                     |
  +---v----+             +--v--+
  |Projects|<----------->|Users|
  +---+----+             +-----+
      |
  +---v----+
  |Services|
  +--------+
```

[Read more about what services mean in the Mariposa context](./services), including Triton CLI commands and the manifest file.


### Service and compute types

Mariposa is responsible for provisioning and deprovisioning compute instances for the user based on the service definition. This effectively abstracts away what used to be the core definition of the cloud—virtualized compute—from what the user directly manages.

```
          +-------------+
      +---+Organizations| --+
      |   +-------------+   |
      |                     |
  +---v----+             +--v--+
  |Projects|<----------->|Users|
  +---+----+             +-----+
      |
  +---v----+
  |Services|
  +--------+
      |
  +---v---+
  |Compute|
  +-------+
```

However, the user still needs to control what type of compute resources are provisioned, and how they'll run.

The types of compute providing a service may include:

- `docker` (default)
- `infrastructure|lx|smartmachine`
- `kvm|vm|hvm`
- `manta`

Only `docker`,`infrastructure`, and `kvm` are required for the MVP.

Not all services run continuously. The growing interest in "function as a service" offerings (as demonstrated in Manta Jobs, and later in AWS' Lambda), as well as the common reality of scheduled batch jobs, indicates that Mariposa should include support for non-continuous services.

These types may include:

- `continuous` runs continuously until stopped
- `event` runs when triggered, is not restarted when it stops
- `scheduled` runs according to defined schedule, is not restarted when it stops

Only `continuous` is required for the MVP.

Service and compute types, are discussed further in the [services manifest](./services/manifest.md).


### Project

While [services](#service) abstract any number of compute instances running the same software with the same configuration, a project allows users to group services and other resources together so that they can be managed as a whole without the distraction or complication or unrelated components.

The concept of projects was first introduced with [RBACv2 in RFD13](../0013/README.md#proposal), this RFD intends to replace the definition of services from RFD13. Though projects and other features described in this RFD may be built independently of RBACv2 work, many assumptions about RBACv2 are made throughout this text.

Once projects are implemented, all customer-defined infrastructure resources in Triton, including [compute](https://docs.joyent.com/public-cloud/instances), [network fabrics](https://docs.joyent.com/public-cloud/network/sdn), [firewall rules](https://docs.joyent.com/public-cloud/network/firewall), [RFD26 volumes](https://github.com/joyent/rfd/tree/master/rfd/0026), and other resources that may be defined in the future _must_ be a member of a project. Some resources (networks, for example) may be shared among different projects, while others (example: services and compute instances) must only be part of a single project.

```
                          +-------------+
                      +---+Organizations| --+
                      |   +-------------+   |
                      |                     |
                      |                     |
                  +---v----+             +--v--+
                  |Projects|<----------->|Users|
                  +---+----+             +-----+
                      |
    +-----------+-----+-----+-----------+
    |           |           |           |
+---v----+  +---v----+  +---v---+  +----v----+
|Services|  |Networks|  |Storage|  |Unmanaged|
+--------+  +--------+  +-------+  | Compute |
    |                              +---------+
    |
+---v---+
|Compute|
+-------+
```

In the above diagram "unmanaged compute" describes both existing instances that were defined before the introduction of services, as well as new instances that a user may define without first defining a service. Support for existing unmanaged compute and their ongoing use, as well as the ability to provision new unmanaged instances is required, despite the introduction of services. However, there is no requirement nor intention of providing a migration plan to convert a collection of existing unmanaged instances into a service.

Projects are described by a [project manifest](./projects/manifest.md), a YAML-formatted file that can be easily copied from elsewhere and in which changes are easily discernible in a text diff. They also have attached metadata as described below.

[Read more about what projects mean in the Mariposa context](./projects), including Triton CLI commands and the manifest file.


### Project meta (including secrets)

Many applications require configuration values which are undesirable or unsafe to set in the application image. These can include license keys, a flag setting whether it's a staging or production environment, usernames and passwords, and other details.

This document proposes a simple method of storing those details and injecting them into containers. It is not intended to provide the rich features of solutions like Hashicorp's Vault, instead it is intended to provide a basic solution that is easy to use in a broad variety of applications.

[Read more about meta in the Mariposa context](./meta), including Triton CLI commands and the manifest file.


### Task queue

Scaling, upgrading, even stopping all the instances of an service can take time...sometimes significant time. To represent this to the user, Triton must expose the task queue and offer the ability to cancel jobs.

[Read more about the the Mariposa task queue](./queue), including Triton CLI commands.


## User stories

The following user stories are intended to provide a narrative understanding of how these features are intended to be used:

- [jupiter.example.com: what it is and development workflow](./user-stories/jupiter-example-com.md)
- [Automatically building and testing jupiter.example.com with Jenkins](./user-stories/jupiter-example-com-jenkins.md)
- [Running jupiter.example.com in multiple data centers](./user-stories/jupiter-example-com-multi-dc.md)
- [Health-checking, monitoring, and scaling jupiter.example.com](./user-stories/jupiter-example-com-monitoring-and-health.md)
- [Creating, copying, and moving projects like microsite.jupiter.example.com](./user-stories/microsite-jupiter-example-com.md) (also includes secret management)


## Implementation and architecture

This RFD is mostly concerned with what users can do with Mariposa, not how those features are implemented. Work to define an implementation has begun in additional RFDs, which propose the following components:

- [Projects service](https://github.com/joyent/rfd/blob/master/rfd/0079/README.md), which is where [projects](https://github.com/joyent/rfd/blob/master/rfd/0036/project.md) and their attached [services](https://github.com/joyent/rfd/blob/master/rfd/0036/service.md) and [metadata](https://github.com/joyent/rfd/blob/master/rfd/0036/meta.md) are managed
- [Convergence service](https://github.com/joyent/rfd/blob/master/rfd/0080/README.md), which is responsible for watching the actual state of the project and its services, comparing that to the goal state, developing a plan to reconcile those differences, and maintaining a queue of reconciliation plans currently being executed.
- [Healthcheck agent](https://github.com/joyent/rfd/blob/master/rfd/0081/README.md), which is responsible for executing health checks defined for each service in the project and reporting any failures to the Convergence service.

Those components are intended to be private services and agents within Triton, exposed via CloudAPI:

```
                                 +-------------+
                                 |             |
                                 | Triton user |
                                 |             |
                                 +------+------+
Public                                  |
                                        |
+--------------------------------------------------------------+
                                        |
Private global services                 |
                                  +-----v----+
                                  |          |
                                  | CloudAPI |
                                  |          |
                                  +-----+----+
                                        |
                                        |
+-------------------------+     +-------v------+    +-------+
|                         |     |              |    |       |
| ProjectsConvergence API <-----> Projects API +----> Moray |
|                         |     |              |    |       |
+-----^--------------^-^--+     +--------------+    +-------+
      |              | |
      |              | |
      |  Changefeed  | +-------------+
      |              |               |
      |              |               |
  +---+---+      +---+---+           |
  |       |      |       |           |
  | vmapi |      | cnapi |           |
  |       |      |       |           |
  +-------+      +-------+           |
                                     |
                                     |
+--------------------------------------------------------------+
                                     |
Per-project agents                   |
                                     |
                         +-----------+----------+
                         |                      |
                         | ServicesHealth agent |
                         |                      |
                         +-----------+----------+
                                     |
+--------------------------------------------------------------+
                                     |
 Customer instances in the project   |
                                     |
                          +----------|---------+
                        +------------v-------- |
                        |                    | |
                        | Containers and VMs | |
                        |                    |-+
                        +--------------------+

```