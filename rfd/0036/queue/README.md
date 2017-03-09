<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Activity queue

Scaling, upgrading, even stopping all the instances of a project and its services can take time...sometimes significant time. To represent this to the user, Triton must expose the task queue and offer the ability to cancel jobs. Each project has its own queue.

- [CLI commands](triton-queue-cli.md)

## Tasks

Tasks that may appear in the queue include:

- `start` the deploy task for `triton project start...`
- `stop` the deploy task for `triton project stop...` and `triton project delete...`
- `scale` the task for `triton project scale...`, and when Mariposa is replacing a failed instance (it's re-scaling to get back to the desired number of healthy instances)
- `reprovision` the deploy task for `triton project reprovision...`; `triton project (update|rollback)` commands trigger `reprovision` tasks


## States

Tasks may have one of the following states:

- `queued`: a task in the queue and waiting for execution
- `active`: an in-progress task
- `completed`: a successful task, no longer executing
- `failed`: an unsuccessful task, no longer executing
- `terminated`: a task that was prematurely cancelled by the operator and is no longer executing


## Scope

Each of those tasks may be scoped to the entire project or one or more of its services.

A `start` task is likely to effect all services of a project (as well as the creation of networks, storage, and other resources), however a `scale` task will likely be executed on one service at a time. A `reprovision` task triggered by updating a project may apply to some services, but not all.

Tasks must support scope and scope resolution that allows us to detect and prevent potentially incompatible concurrency conditions.


## Concurrency

Some tasks can be done concurrently, most tasks can't. In some cases, the presence of an active task in the queue must block adding any other tasks in the queue, and in other cases, adding a task to the queue must terminate other tasks in the queue.

The following table describes whether tasks can be executed concurrently, sequentially (FIFO), must cancel existing tasks, or must be rejected with an error if an attempt is made to add them to the queue while others are active.

Tasks reading down the chart are those already in the queue; tasks reading across the chart are those to be added.

|                      | Add `start` | Add `stop` | Add `scale` | Add `reprovision` |
|----------------------|-------------|------------|-------------|-------------------|
| `start` active       | Reject      | Terminate  | FIFO        | FIFO              |
| `stop` active        | Reject      | Reject     | Reject      | Reject            |
| `scale` active       | FIFO        | Terminate  | Reject      | Concurrent        |
| `reprovision` active | FIFO        | Terminate  | Concurrent  | Terminate         |

- `Reject`: an attempt to add the task must result in an error
- `Terminate`: adding the task must terminate the existing task(s)
- `FIFO`: the task can be added to the queue to execute after existing tasks have completed (successfully or not)
- `Concurrent`: the task can be added to the queue and execute concurrently with the existing task(s); the only case for this is reprovision and scale

## Execution

It is expected that most (all?) non-instantaneous tasks relate to provisioning instances. It is further assumed that cloud operators may want to apply throttles to the number of instances that can be provisioned at a given time. It's also assumed that users will eventually attempt to change the project manifest while tasks are being executed.

Given those assumptions, it is desirable to ensure that any execution plan that must be completed in multiple steps should be reevaluated as steps are completed and before new steps are undertaken.

Consider the following example:

A user has a project with 35 instances of a service. The user modifies the project manifest in a way that triggers a reprovision of all the instances of that service.

The reprovision begins executing, replacing five instances at a time. While executing the second batch of five instances, the user then decides to scale the service down from 35 instances to 20.

In this case:

1. The scaling behavior is expected to [stop the oldest instances first](../projects/triton-projects-cli.md), leaving the recently reprovisioned instances for last.
2. As the reprovision step completes a step, it re-evaluates the state of the infrastructure before beginning the next step.
3. Instead of executing seven steps to reprovision the containers for the service (as would have been required for the 35 containers when the task was started), only four steps will be executed (since the goal state is for only 20 containers).

Consider another example:

A user has a project with 19 instances of a service. The user modifies the project manifest in a way that triggers a reprovision of all the instances of that service.

The reprovision begins executing, replacing two instances at a time. While executing the third batch of instances, two of the old instances fail.

In this case:

1. Mariposa is expected to detect the failed instances and trigger a `scale` event to re-scale the service to the desired level
1. The newly provisioned replacements for the failed instances must match the current manifest spec, not the manifest the earlier instances were provisioned under
1. Both `scale` and `reprovision` events can be executed simultaneously
1. The (re)`scale` task is expected to complete before the `reprovision` task
1. As the reprovision task reevaluates its steps, it will discover the replacement instances already match the current manifest spec and exclude them from reprovisioning
