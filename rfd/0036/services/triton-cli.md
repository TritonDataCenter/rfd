<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Managing services with the Triton CLI

The following commands are all within the scope of a given project.

The `triton` CLI must allow users to specify an organization and project to work within in a manner similar to how the user can now specify a profile. Once the default organization and project are set, all interactions with the resources defined here are within the scope of that organization and project.

Additionally, `triton service` commands must support a `-j <project name>` optional argument to specify the project name/uuid. This is similar to specifying the Triton profile with `triton -p <profile name>`. Example: `triton [-j <project name>] service list`. Support for `-o <organization name>` is similarly expected.

## `triton (services|svcs|service list|svc list)`

List all services within a project

## `triton service (add|create|new) <service name> <service manifest>`

Add a service to the project. The [service manifest is defined elsewhere](./manifest.md).

Triton will immediately start provisioning a `service_type=continuous` service (with a scale of 1) when defined. Triton will not automatically start other service types.

## `triton service (get|show) <service uuid or name>`

Show the service manifest and details for the specified service

## `triton service update <service uuid or name> <service manifest> [rolling=<positive int>] [canary|count=<positive int>]`

Add a new service version with the given manifest, set that service version as the default, and trigger a `reprovision` of all instances to the new version.

Optional arguments passed through to [`reprovision`](#triton-service-reprovisionrestart-service-uuid-or-name-versionversion-uuid-imageimagespectag-instancenameuuid-compute_nodeuuid-countcanarypositive-integer-rollingpositive-integer) (see defaults in `reprovision`):

- `rolling`
- `canary|count`

### Example: canary deploys

```bash
# Update the service definition and trigger a canary with three instances
triton service update <uuid> <manifest> --canary|count=3

# Continue the canary deploy with three more instances
triton service reprovision <uuid> --count|canary=3

# Continue the canary deploy with all remaining instances
triton service reprovision <uuid>
```

### Example: rolling deploys

```bash
# Update the service definition and trigger an aggressive rolling deploy with three instances at a time; old instances will not be removed until new instances are healthy
triton service update <uuid> <manifest> --rolling=3

# Rolling reprovision of one instance at a time (default)
triton service reprovision <uuid>

# Rolling reprovision with three more instances at a time
triton service reprovision <uuid> --rolling=3
```

## `triton service versions <service uuid or name>`

List all versions of the specified service, most recent on top

## `triton service version <service version uuid>`

Show the details for the specified version uuid

## `triton service (revert|rollback|set|set-current) <service uuid or name> <service version uuid> [rolling=<positive int>] [canary|count=<positive int>]`

Sets the default version for any new instance provisioning, including positive `scale`, `reprovision`, and automatic reprovisioning of failed instances. Automatically triggers a `reprovision` when used.

Optional arguments passed through to `reprovision`:

- `rolling`
- `canary|count`

### Example reverts

```bash
# Agressive rolling revert
triton service revert <uuid> <uuid> --rolling=5

# Tentative canary revert with one instance
triton service revert <uuid> <uuid> --canary|count=1

# Continue the canary revert with three more instances
triton service reprovision <uuid> --count|canary=3

# Continue the canary revert with all remaining instances
triton service reprovision <uuid>
```

## `triton service delete <service uuid or name>`

Deletes the service and all versions. Action is irreversible.

## `triton service scale <service uuid or name> <integer or relative integer>`

Scales the number of instances for the service. Examples:

- `triton service scale ade55fd0 5`
- `triton service scale ade55fd0 +1`
- `triton service scale ade55fd0 -1`

Only supported for `service_type=continuous` services; will error for others. Reason: `event` and `scheduled` service types are best scaled by increase the size of the instance, increasing the schedule frequency, or break up services/events into smaller pieces. This avoids the complexity of maintaining state for these services in the scheduler.

When scaling down, the policy used to select which instances to stop will match the policy defined for `reprovision`.

## `triton service stop <service uuid or name> [version=<version uuid>]`

Stop all instances of a service using the `removestopped` behavior rules defined elsewhere.

Optional arguments:

- `version` the version UUID to stop; only instances matching that version will be stopped

## `triton service start <service uuid or name> [version=<version uuid>]`

Starts an instance of the specified service. Behavior varies based on `service_type`:

- `continuous`: if no instances of the service are running, this has the same effect as `triton service scale <service uuid or name> 1`. If there are instances running, including unhealthy instances, this must error with a message saying the service is already running.
- `event` and `scheduled`: start an instance of this service, observing any limits on concurrency that may be set for the service.

Optional arguments:

- `version` the version UUID to start

## `triton service (reprovision|restart) <service uuid or name> [version=<version uuid>] [image=<imagespec:tag>] [instance=<name|uuid>] [compute_node=<uuid>] [count|canary=<positive integer>] [rolling=<positive integer>]`

Will replace all existing instances of the service with new instances. Replacement instances will be provisioned using the current default version uuid, not version uuid of the replaced instance.

This is intentionally not the same as `triton instance restart <instance uuid>` for all instances in the service. This command will provision new instances of the service, and those new instances will be redistributed throughout the DC following standard DAPI rules and service affinity settings. This can be used to move services around in advance of a planned downtime (hopefully the CNs to be offlined have been made un-provisionable).

The command will match all instances by default, but filters can be used to specify what instances are selected for reprovisioning:

- `version`: all instances matching the specified service version uuid
- `image`: all instances with the specified image (and tag, if Docker)
- `compute_node|cn`: the uuid of a Triton compute node, to support reprovisioning instances in advance of a CN reboot
- `instance`: a single instance

Additionally, the deployment behavior can be controlled with the following arguments:

- `rolling` is the number instances to attempt to start in parrallel; default is `1`; valid range is `1` through the current count of instances. Old instances will not be removed until new instances are "healthy"
- `count|canary` is the total number of instances to reprovision; valid range is `1` through the current count of instances; default is `null`: no canary behavior

Instances will be selected and reprovisioned according to the following policy:

- Select all running instances of the service (stopped instances are intentionally excluded, instances in transition are excluded to exclude flapping)
- Apply user-specified filters
- Order resulting instances:
  - Oldest service version first (excluding the current/default service version)
  - The current/default service version is always last
  - Oldest instance first within each service revision
- Limit by any user-specified `count|canary`

Only supported for `service_type=continuous` services; will error for others.

## `triton service instances <service uuid or name>`

Lists all instances of the service, including stopped instances.
