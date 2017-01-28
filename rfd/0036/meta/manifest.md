<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Project metadata manifest

A manifest of all metadata in a project. The manifest is a series of keys and values.

```yaml
<key>: <value>
<key>: <value>
<key>: <value>
```


## Manifest format

Though JSON is the preferred data interchange format throughout Triton, the inability to support inline comments has proven challenging in ContainerPilot. Those comments are more than a convenience, they're critically needed for inline documentation. This is especially true in operations where small changes can make the difference between smooth running and miserable disaster.

Given that, the default format for the project and service manifest is YAML, and efforts should be made to preserve in their entirety the valid, YAML-formatted manifest file submitted by the user.

The manifest may be submitted as JSON, but it will be transformed to YAML when submitted, and returned as YAML when requested.