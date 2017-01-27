<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Project meta and variable interpolation

Many applications require configuration values which are undesirable or unsafe to set in the application image. These can include license keys, a flag setting whether it's a staging or production environment, usernames and passwords, and other details.

The importance of project meta grows as we consider the likelihood of importing project and service manifests from a library of components, where it will be especially undesirable to embed configuration details.

### Variable replacement/interpolation

A number of sections of the project manifest (including the service manifests) support variable interpolation using both project metadata and other details about the project.

The following variables are available, where interpolation is supported, at all scopes:

- `meta`: project metadata
- `project`: information about the current project
  - `name`
  - `uuid`
  - `version`: the uuid of the project manifest

These variables are available, where interpolation is supported, within a service manifest:

- `service`: information about the current service
  - `name`
  - `uuid`
  - `version`: the version ID of the project manifest
- `package`: Package details, including RAM, disk, "CPU", package name, package family
  - `ram`
  - `disk`
  - `cpu`: a value that can be used to approximate the number of CPUs that should be scheduled
  - `name`
  - `family`
- `cns`: the Triton CNS names
  - `svc`
    - `public`: The FQDN of this service pointing to the public interface
    - `private`: The FQDN of this service pointing to the "private" interface
    - `<user fabric network name>`: The FQDN of this service pointing to the interface on the named network
    - `<network uuid>`: The FQDN of this service pointing to the interface on the named network
  - `inst`
    - `public`
    - `private`
    - `<user fabric network name>`
    - `<network uuid>`
  - `prefix`
    - `public`
    - `private`
    - `<user fabric network name>`
    - `<network uuid>`
- `placement`: information about where the instance is provisioned in the data center
  - `instance` the name and UUID of the specific instance
	  - `name`
	  - `uuid`
  - `cn` the compute node on which the instance was provisioned
	  - `uuid`
  - `rack` the rack in which the instance was provisioned
	  - `uuid`
  - `dc` the data center in which the instance was provisioned
	  - `name`
- `scale`: the desired number of instances of this service

The syntax for referencing a variable in the manifest:

```yaml
{{ .<key>.<key> }}
{{ .project.name }}
{{ .cns.svc.public }}
```

The correctness of project variables and meta is only guaranteed at the moment of interpolation. That is, changes in project variables or meta will not be reflected in a running instance's environment variables, even if those environment variables were set from project variables or meta.
