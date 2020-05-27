---
authors: Jason King <jason.king@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc.
-->

# RFD 182 Altering system pool detection in SmartOS/Triton

## Introduction

Today, when a SmartOS system boots (whether it be standalone, a Triton compute
node, or a Triton headnode), the `filesystem/smartdc` service
attempts to identify which zpool visible to the system is the 'system' zpool
(the zpool containing the /var, /cores, /opt, etc. filesystems as well as the
zpool containing all of the zone filesystems). The service accomplishes this by
importing all zpools that are present and using the last zpool whose root
dataset contains a file named `.system_pool`. It then sets the SMF property
`config/zpool` in the `smartdc/init` sevice to the name of the system zpool.

With the advent of encrypted compute nodes (aka EDAR / RFD 77), this presents
some issues. Most notably, one cannot reliably determine the system pool until
the keys for the root dataset of each zpool has been loaded. This also can
prevent the `sdc-factoryreset` utility from working reliabily -- it relies on
setting a property on `${SYS_POOL}/var` to determine if the system zpool should
be destroyed, but it cannot determine which zpool is the system pool until
the pool's key has been loaded. If the ebox or yubikey protecting the ebox
for the pool has already been destroyed or reset, the pool cannot be unlocked
automatically, and the node factory reset will fail. This can be worked around
but it provides a less than ideal operator experience.

## Proposal

Since zfs properties are always available once a zpool has been imported
(regardless of the encryption status), we propose moving this setting to a
zfs property on the root dataset of a zpool.

The proposal here is to migrate this setting/flag into a zfs property on the
root dataset tentatively named `smartdc:system_pool`. During system setup,
this property will be set on the system zpool in addition to creating
`/.system_pool` (for backwards compatability).

When the `filesystem/smartdc` service runs during boot, it will import all of
the pools present on the system unless the `zpools` boot parameter is
given, then only the pools listed there are imported (i.e. no change here).
For each pool, if the `smartdc:system_pool` property is present, the last
pool with the property set will be used for the system pool. In addition, if
multiple pools have the `smartdc:system_pool` property set, a warning will
be written to the console to alert the operator.

If no pool is found with the property, the service will fall back to looking
for `.system_pool`.

For backwards compatibility, once the system pool has been set and imported,
`touch /.system_pool` will be executed to allow for backwards compatability.
Additionally, the `smartdc:system_pool` property will be set on the root dataset
of the pool. At some indeterminate point in the future, the `.system_pool`
logic can be removed (i.e. after a sufficient amount of time has passed that
all customers are running on a PI version that includes the functionality
described here).

With this, the factory reset check (which looks at `${SYS_POOL}/var`) can be
proceed prior to unlocking of any encrypted zpools.

Once the system pool has been identified, we can unlock it as necessary.
Additionally, kbmd can then use the `config/zpool` SMF property to determine
the system zpool instead of having to be informed of the value during boot
(since it has to unlock the system pool if the node is encrypted, kbmd must
start before the SMF property has been set).

## Potentially Unresolved Bits

The current proposal doesn't specify a value for `smartdc:system_pool` -- it
just looks for its presence. If we want to have a definitive value here, the
question is what should it be -- 'yes/no', a GUID, something else? There
could be advantages to tieing the value to something on the system (e.g. the
smbios uuid). Any such behavior would need to consider things such as
chassis swaps (i.e. what would the procedure be to update the value) and
encrypted compute nodes.

An additional possibility might be to allow the zpool GUID to be _optionally_
specified in the boot parameters. When present, that value (and only that
value) is used to locate the system pool. All pools (or the ones in the
`zpools` boot parameter when precent) could still be imported.
