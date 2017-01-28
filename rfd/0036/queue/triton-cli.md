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

- `start` the deploy task for [`triton service start...`](#triton-service-start-service-uuid-or-name) or on [`triton service add...`](#triton-service-addcreatenew-service-name-service-manifest) for a continous service.
- `stop` the deploy task for [`triton service stop...`](#triton-service-stop-service-uuid-or-name) and [`triton service delete...`](#triton-service-delete-service-uuid-or-name)
- `scale` the deploy task for [`triton service scale...`](#triton-service-scale-service-uuid-or-name-integer-or-relative-integer)
- `reprovision` the deploy task for [`triton service reprovision...`](#triton-service-reprovisionrestart-service-uuid-or-name) (`update` and `rollback` commands trigger `reprovision` tasks)

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
