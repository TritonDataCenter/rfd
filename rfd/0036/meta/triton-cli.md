<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Metadata management

Users can register metadata as key/value pairs that can be used in projects and services. The metadata must be within an project (RBACv2 terms), and each key must by unique within that project.

Needs definition: RBACv2 permissions.

All `triton meta` commands must support a `[-j <project name>]` optional argument to specify the project name/uuid. This is similar to specifying the Triton profile with `triton -p <profile name>`. Example: `triton [-j <project name>] meta list`

## `triton meta list|get|show`

Lists all the metadata keys and values for the project. The list may be filtered using additional args (needs definition: filters).

```bash
$ triton meta list
Key    Val    CAS ID
-----  -----  --------
<key>  <val>  <cas id>
```

## `triton meta add|set|create|new|update <metadata key> <metadata value> <cas id>`

Add a metadata key with the specified value. If the key exists, it will be replaced with the new value.

If `<cas id>` is supplied, it must match the current `<cas id>` for the metadata key, or the update operation will fail.

## `triton meta rm|delete|del <metadata key> <cas id>`

Remove a metadata key.

If `<cas id>` is supplied, it must match the current `<cas id>` for the metadata key, or the delete operation will fail.

## `triton meta increment|incr <metadata key> <positive integer>`

Increments the value of the metadata key. The key value is treater as an integer and incremented by the value of `<positive integer>`. A non-existing key will be created; a null value will be treated as `0`.

## `triton meta decrement|decr <metadata key> <positive integer>`

Decrements the value of the metadata key. The key value is treater as an integer and decremented by the value of `<positive integer>`. A non-existing key will be created; a null value will be treated as `0`.
