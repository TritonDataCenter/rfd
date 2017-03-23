<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Projects

A project is a collection of related services, metadata, and other resources. Users may be invited to participate in a project, and different users may have different roles within the project. A user's permission for each object must be defined by the user's role, and no more detailed permissions within a given project may be granted.

- [Manifest](manifest.md)
- [Changes to existing CLI commands and API methods](triton-cli.md)
- [New CLI commands to manage projects](triton-projects-cli.md)

## What's in a project?

- [Services, also defined in this RFD](../services)
Services are a new abstraction that will largely replace the direct use of instances
- Fabrics
- [Volumes, as defined in RFD26](/joyent/rfd/blob/master/rfd/0026/README.md#introduction)
- Unmanaged instances
This is a new name for compute instances (VMs and containers) as we knew them before the introduction of projects and services in this RFD.

These objects are now each owned by an account, an individual user or group of people sharing a single Triton account/password. One of the most important aspects of this RFD is the ability to group those objects into projects.

## What can be done with a project

By creating an explicit object in Triton for projects, rather than using tags, users will be more easily able to treat the collection of resources as a single entity. This makes it easier to change permissions (though that will wait for RBACv2 in RFD-13, 48, and 49), as well as to clone objects within an account (or organization, post RBACv2) or transfer them to other organizations (again, post RBACv2).

More simply, users will be able to start or stop all the services in a project as a group, and other actions.

## Migration to projects

This RFD assumes that Triton users already have large numbers of resources that will need to be accommodated in a future world with projects. A migration procedure will be needed for those resources.

All existing accounts will get a default project. Indeed, newly created accounts after the introduction of projects will get a default project as well.

All existing resources will become members of the user's default project.

Triton must prevent the creation of new unmanaged instances, fabrics, volumes, and services that are not associated with a project.