<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Managing metadata with the Triton CLI

The following commands are all within the scope a specified project, within a specified organization. See more details about [specifying the organization and project](../projects/triton-cli.md#specifying-the-organization-and-project) for CLI commands.


## `triton (metas | meta ls | meta list)`

Lists all the metadata keys and values for the project. The list may be filtered using additional args (needs definition: filters).

```bash
$ triton meta list
Key    Value  CAS ID
-----  -----  --------
<key>  <val>  <cas id>
```

## `triton meta (add|set|create|new|update) <metadata key> <metadata value> [<cas id>]`

Add a metadata key with the specified value. If the key exists, it will be replaced with the new value.

If `<cas id>` is supplied, it must match the current `<cas id>` for the metadata key, or the update operation will fail.

## `triton meta (rm|delete|del) <metadata key> [<cas id>]`

Remove a metadata key.

If `<cas id>` is supplied, it must match the current `<cas id>` for the metadata key, or the delete operation will fail.

## `triton meta (increment|incr) <metadata key> <positive integer>`

Increments the value of the metadata key. The key value is treated as an integer and incremented by the value of `<positive integer>`. A non-existing key will be created; a null value will be treated as `0`.

## `triton meta (decrement|decr) <metadata key> <positive integer>`

Decrements the value of the metadata key. The key value is treater as an integer and decremented by the value of `<positive integer>`. A non-existing key will be created; a null value will be treated as `0`.

## `triton meta import [(--force|-f)] (-m <path to manifest> | manifest on STDIN)`

Imports a YAML or JSON-formatted manifest of metadata (support for both is expected).

A warning must be issued for any keys in the manifest that are already set in the project metadata, but other data must be imported.

If `--force` or `-f` is specified, it will overwrite existing keys in the project metadata.