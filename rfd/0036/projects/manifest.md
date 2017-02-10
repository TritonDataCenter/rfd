<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Project manifest

The project manifest defines all the services of a project, as well as other details that may be added in time. Each project has a single active manifest that defines the expected state of the entire project.

The `version` and `tags` fields are optional, and are present to help give the user meaningful output from commands like `triton project versions` or `triton project ls`, providing human-readable information in addition to sha1sums, and the ability to filter. See []

```yaml
version: 1
tags: web, cache
services:
  nginx:
    service_type: continuous
    compute_type: docker
    image: autopilotpattern/nginx:latest
    package: g4-highcpu-512M
    ports:
      - 80
      - 443
  redis:
    service_type: continuous
    compute_type: docker
    image: autopilotpattern/redis:latest
    package: g4-general-4G
```

[Reference the service manifest documentation](../service/manifest.md) for services details.

Additional object types that might be expected in future iterations of the project manifest include [network fabrics](https://docs.joyent.com/public-cloud/network/sdn), [firewall rules](https://docs.joyent.com/public-cloud/network/firewall), CNS domains, [RFD26 volumes](https://github.com/joyent/rfd/blob/master/rfd/0026/README.md), and Manta storage "buckets".


## Manifest format

Though JSON is the preferred data interchange format throughout Triton, the inability to support inline comments has proven challenging in ContainerPilot. Those comments are more than a convenience, they're critically needed for inline documentation. This is especially true in operations where small changes can make the difference between smooth running and miserable disaster.

Given that, the default format for the project and service manifest is YAML, and efforts should be made to preserve in their entirety the valid, YAML-formatted manifest file submitted by the user.