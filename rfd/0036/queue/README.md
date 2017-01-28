<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Activity queue

Scaling, upgrading, even stopping all the instances of an service can take time...sometimes significant time. To represent this to the user, Triton must expose the task queue and offer the ability to cancel jobs. Each project has its own queue.

- [CLI commands](triton-cli.md)
