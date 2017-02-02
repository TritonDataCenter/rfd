<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Managing the queue with the Triton CLI

The task queue is especially significant to provisioning/deprovisioning services in projects, but will likely also be the place to watch other long-running tasks unrelated to services.

All `triton queues` commands must support optional arguments to specify the organization and project:

- `-j <project name|uuid>`
- `-o <organization name|uuid>`

This is similar to specifying the Triton profile with `triton -p <profile name>`. Example: `triton [-j <project name>] queue list`.

## `triton queue list`

Lists all queued tasks, including service deploy tasks. 

A service deploy task can include:

- `start` the deploy task for `triton service start...` or on `triton service add...` for a continuous service.
- `stop` the deploy task for `triton service stop...` and `triton service delete...`
- `scale` the deploy task for `triton service scale...`
- `reprovision` the deploy task for `triton service reprovision...` (`update` and `rollback` commands trigger `reprovision` tasks)

Service deploy tasks can have the following states:

- `active`: an in-progress deploy
- `completed`: a successful previous deploy
- `failed`: an unsuccessful previous deploy
- `terminated`: a previous deploy that was prematurely cancelled by the operator

Example:

```bash
$ triton queue list
uuid          component    task         state    target
<short uuid>  <component>  <task>       <state>  <target>
85978f42289e  service      reprovision  active   <org>.<project>.<service>
```

## `triton queue stop <task uuid>`

Terminates a task.

However, because the task resulted from a difference between the  desired state of the project and the actual state of the infrastructure, the task (or a similar one) may be respawned if the difference continues.

Questions:

1. Should stopping a task in a project suppress the spawning of new tasks for the same project until the user changes the project's desired state? If so, how should that be represented to the user?