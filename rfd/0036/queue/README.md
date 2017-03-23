<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Activity queue

Scaling, upgrading, even stopping all the instances of a project and its services can take time...sometimes significant time. To represent this to the user, Triton must expose the task queue and offer the ability to cancel jobs and prevent the [convergence service](../../0080/README.md) from queueing new tasks as it might determine necessary to reconcile differences between the goal state of the project and its actual state.

Additionally, adding this level of automation to infrastructure management demands improvements in a user's ability to audit changes, both the changes triggered automatically by the [convergence service](../../0080/README.md) and changes that other users may make to the project or its resources.

## Todo

[Previous versions of this RFD](https://github.com/joyent/rfd/tree/e38e0b02776a286db47c9fccea1e90646b5f31ef/rfd/0036/queue) included far more detail about the queue. That detail has been removed so that we have more freedom to develop the [convergence service](../../0080/README.md), and then figure out how to represent that to the user.

## Rough requirements

- The user must be able to see the contents of the queue, including tasks currently executing, those that may be waiting, and those that have executed in the past
- The state of items in the queue must be visible and filterable, though the enumeration of what states are possible will need to be done in future work
- The user must have the ability to stop the execution of all items in the queue and prevent the execution of any new items in the queue (or maybe prevent the addition of new items in the queue)