<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Managing projects with the Triton CLI

The following commands are all within the scope of a given project.

The `triton` CLI must allow users to specify an organization and project to work within in a manner similar to how the user can now specify a profile. Once the default organization and project are set, all interactions with the resources defined here are within the scope of that organization and project.

Additionally, `triton project` commands must support a `-j <project name>` optional argument to specify the project name/uuid. This is similar to specifying the Triton profile with `triton -p <profile name>`. Example: `triton [-j <project name>] project list`. Support for `-o <organization name>` is similarly expected.


## `triton (projects|project list|project ls)`

List all projects in an organization.

## `triton project (add|create|new) <project name> <project manifest>`

Add a project to the organization. The [project manifest is defined elsewhere](manifest.md).

## `triton project (get|show) <project uuid or name>`

Show the project manifest and details for the specified project.

## `triton project update <project uuid or name> <project manifest> (rolling=<positive int>) (canary|count=<positive int>)`

Add a new project version with the given manifest, set that project version as the default, and trigger a `reprovision` of all service instances to the new version.

Optional arguments passed through to [`reprovision`](#triton-service-reprovisionrestart-service-uuid-or-name-versionversion-uuid-imageimagespectag-instancenameuuid-compute_nodeuuid-countcanarypositive-integer-rollingpositive-integer) (see defaults in `reprovision`):

- `rolling`
- `canary|count`

## `triton project versions <project uuid or name>`

List all versions of the specified project, most recent on top.

## `triton project version <project version uuid>`

Show the details for the specified version uuid.

## `triton project (revert|rollback|set|set-current) <service uuid or name> <service version uuid> [rolling=<positive int>] [canary|count=<positive int>]`

Sets the default version for any new instance provisioning, including positive `scale`, `reprovision`, and automatic reprovisioning of failed instances. Automatically triggers a `reprovision` when used.

Optional arguments passed through to `reprovision`:

- `rolling`
- `canary|count`

## `triton project delete <project uuid or name>`

Deletes the service and all versions. Action is irreversible.

## `triton project stop <project uuid or name> [version=<version uuid>]`

Stop all instances of a project using the `removestopped` behavior rules defined elsewhere.

Optional arguments:

- `version` the version UUID to stop; only instances matching that version will be stopped

## `triton project start <service uuid or name> [version=<version uuid>]`

Starts one instance of each service specified in the manifest. Behavior varies based on `service_type`, see XXX.

Optional arguments:

- `version` the version UUID to start

## `triton project instances <project uuid or name>`

Lists all instances of all services in the project, including stopped instances and instances not associated with a service.


