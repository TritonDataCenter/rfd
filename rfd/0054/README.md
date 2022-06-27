---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 54 Remove 'autoboot' when VMs stop from within

## Introduction

When a Triton VM/container is stopped with `vmadm stop` regardless of brand, the
autoboot property on the VM object is set to `false` so that the VM will not be
started automatically if the CN reboots at this point. It won't be started until
a specific request comes in to start the VM.

When a user stops their container by running `shutdown` or `halt` from within
the container itself, the flag is *not* changed.

This RFD exists to discuss whether we should change this behavior on shutdown
from within the zone and if so: discuss consequences of doing so.

## Known Potential Issues

 * When a user reboots a non-KVM VM from within, the zone's state will briefly
   go to uninitialized before starting up again. We need to make sure that in
   this case we do the right thing and don't mark the VM as `autoboot=false`
   and miss setting it back to `autoboot=true` when it boots.

## Related Tickets

 * [joyent/smartos-live#641](https://github.com/TritonDataCenter/smartos-live/issues/641)

