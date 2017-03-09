<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Deprecated

I propose deprecating `triton queue` in favor of `triton project task`.

# Managing the queue with the Triton CLI

The following commands are all within the scope a specified project, within a specified organization. See more details about [specifying the organization and project](../projects/triton-cli.md#specifying-the-organization-and-project) for CLI commands.


## `triton queue list`

Lists all queued tasks.

Example:

```bash
$ triton queue list
uuid          scope      task         state
<short uuid>  <scope>    <task>       <state>
a3954a48279b  project    start        active
85978f42289e  my_mysql   reprovision  queued
```

## `triton queue (terminate|stop) <task uuid>`

Terminates a task and triggers a `freeze` task with the same scope as the terminated task.


## `triton queue freeze [--service=<service name or UUID, comma separated>]`

Terminates all existing tasks for the entire project. Or, if one or more services are specified, just for those services. Calling this also starts a `freeze` task for the same scope, preventing any new, automatically generated tasks from being added to the queue until the freeze is terminated.
