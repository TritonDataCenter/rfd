<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Managing projects with the Triton CLI

The following commands are all within the scope a specified project, within a specified organization. See more details about [specifying the organization and project](../projects/triton-cli.md#specifying-the-organization-and-project) for CLI commands.


## `triton (projects|project list|project ls)`

List all projects in an organization.


## `triton project (add|create|new) <project name> (-m <path to project manifest>| project manifest on STDIN)`

Add a project to the organization. 

- The `<project name>` must be [a valid DNS label](https://en.wikipedia.org/wiki/Hostname#Restrictions_on_valid_hostnames)
- The `<project name>` must be unique within a given organization

The [project manifest is defined elsewhere](manifest.md).

## `triton project (set|set-current) <project name or UUID>`

Sets a the specified project as the default for all interactions. This has the practical effect of adding an implicit `-j <project name or UUID>` to every command that follows.


## `triton project (get|show)`

Show the project manifest and details for the specified project.


## `triton project update (-m <path to project manifest>| project manifest on STDIN) [--rolling=<positive int>] [--(canary|count)=<positive int>] [--previous=<version uuid>] [(-f|--force)]`

If all validation checks pass, this will add a new project version with the given manifest, set that project version as the default, and trigger a `reprovision` of for services that have been changed by the new manifest.


### Validation checks

The following must all be valid for the manifest to be saved and set as the default version:

- The manifest must parse successfully. The command must fail with an error if the manifest fails to parse successfully.
- One of `--previous` or `--force` is required. If neither are specified, the command must fail with an error.
- If a `--previous=<version uuid>` version is specified, it must match the current default version. If not, then the command must fail with an error.

In the case of a failure, the CLI may provide detailed feedback, and prompts that allow the user to continue easily. For example, if no `--previous` is specified, the CLI might provide a diff between the user-supplied version and the current default, with a prompt for the user to confirm the change. If the user then confirms the change, the CLI may re-submit with the correct `--previous=<version uuid>` inserted. Or, the CLI might suggest the the user re-run the command with that argument added.

The `--previous=<version uuid>` is significant since it's imagined that multiple users will be managing a single project, and it's necessary to protect those users from stomping on each others' edits because they're working with stale data.


### Deployment strategy

For all services changed by the new manifest, this command will trigger a reprovision. The strategy for that reprovision can be defined for each service in the manifest, or overridden for all changed services using options provided to this command:

- `rolling`
- `canary|count`

Arguments provided here apply to all services affected by the manifest changes.


### Example: canary deploys

```bash
# Update the service definition and trigger a canary with three instances
triton project update --canary=3 -m <path to manifest>

# Continue the canary deploy with three more instances
triton project reprovision --count=3

# Continue the canary deploy with one more instance for a specified service 
triton project reprovision --count=3 --service=<service name or UUID>

# Continue the canary deploy with all remaining instances
triton project reprovision
```


### Example: rolling deploys

```bash
# Update the service definition and trigger an aggressive rolling deploy with three instances at a time; old instances will not be removed until new instances are healthy
triton project update --rolling=3 -m <path to manifest>

# Rolling reprovision of one instance at a time (default)
triton project reprovision

# Rolling reprovision with three more instances at a time
triton project reprovision --rolling=3
```


## `triton project (versions|version list|version ls)`

List all versions of the specified project, most recent on top.


## `triton project version get <version uuid>`

Show the details for the specified version uuid.


## `triton project (revert|rollback) <version uuid> [--rolling=<positive int>] [--(canary|count)=<positive int>]`

Sets the default version for any new instance provisioning, including positive `scale`, `reprovision`, and automatic reprovisioning of failed instances. Automatically triggers a `reprovision` when used.

Optional arguments passed through to `reprovision`:

- `rolling`
- `canary|count`


### Example reverts

```bash
# Agressive rolling revert
triton project revert <uuid> --rolling=5

# Tentative canary revert with one instance
triton project revert --count=1

# Continue the canary revert with three more instances
triton project reprovision --canary=3

# Continue the canary revert with one more instance for a specified service 
triton project reprovision --count=1 --service=<service name or UUID>

# Continue the canary revert with all remaining instances
triton project reprovision
```


## `triton project delete [-f | --force]`

Deletes the current project and all versions, instances, networks, storage, and metadata. Action is irreversible.

The command must fail if there are running instances (and `--force` is not specified).

Regarding networks: if a network is shared with multiple projects (including projects in other organizations), then the network is not deleted, but the relationship of that network to this project is deleted.


## `triton project scale <service name or UUID>=<integer or relative integer>`

Scales the number of instances for the specified service. Multiple services can be specified. Examples:

- `triton project scale ade55fd0=5`
- `triton project scale mysql=+1`
- `triton project scale nginx=-1 memcached=-1`

Only supported for `service_type=continuous` services; will error for others. Reason: `event` and `scheduled` service types are best scaled by increase the size of the instance, increasing the schedule frequency, or break up services/events into smaller pieces. This avoids the complexity of maintaining state for these services in the scheduler.

When scaling down, the policy used to select which instances to stop will match the policy defined for `reprovision`.


## `triton project stop [--version <version UUID>]`

Stop all instances of a project using the `removestopped` behavior rules defined elsewhere.

Optional arguments:

- `version` the version UUID to stop; only instances matching that version will be stopped

## `triton project start [--version=<version UUID>]`

Starts one instance of each service specified in the project manifest. Behavior varies based on `service_type`, see XXX.

Optional arguments:

- `version` the version UUID to start


## `triton project (reprovision|restart) [--service=<service name or uuid>] [--version=<version uuid>] [--image=<imagespec:tag>] [--instance=<name|uuid>] [--compute_node=<uuid>] [--(count|canary)=<positive integer>] [rolling=<positive integer>]`

Will replace all existing instances of the project with new instances. Instances that had been provisioned using a previous version of the project manifest will be replaced with instances that conform to the current version of the manifest.

This is intentionally not the same as `triton instance restart <instance uuid>` for all instances in the project. This command will provision new instances of the service, and those new instances will be redistributed throughout the DC following standard DAPI rules and the affinity settings for each service. This can be used to move instances of the project around in advance of a planned downtime (hopefully, the CNs to be offlined have been made un-provisionable).

The command will match all instances or all services by default, but filters can be used to specify what instances are selected for reprovisioning:

- `version`: all instances matching the specified service version uuid
- `service`: all instances of the specified service
- `image`: all instances with the specified image (and tag, if Docker)
- `compute_node|cn`: the uuid of a Triton compute node, to support reprovisioning instances in advance of a CN reboot
- `instance`: a single instance

Additionally, the deployment behavior can be controlled with arguments in the manifest or on the command line:

- `rolling` is the number instances to attempt to start in parallel; default is `1`; valid range is `1` through the current count of instances. Old instances will not be removed until new instances are "healthy"
- `count|canary` is the total number of instances to reprovision; valid range is `1` through the current count of instances; default is `null`: no canary behavior

### Selection policy

Instances will be selected and reprovisioned according to the following policy:

- Select all running instances of the service (stopped instances are intentionally excluded, instances in transition are excluded to prevent flapping)
- Apply user-specified filters
- Order resulting instances:
  - Oldest service version first (excluding the current/default service version)
  - Oldest instance first within each service revision
  - The current/default service version is always last
- Limit by any user-specified `count|canary`

Only supported for `service_type=continuous` services; will error for others.

