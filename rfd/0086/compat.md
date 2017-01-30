## Backwards compatibility and support

The changes in this RFD are not backwards compatible with ContainerPilot 2.x configuration. For end users using Consul as their discovery backend, each container image can be safely updated independently; there is no communication between ContainerPilot instances except through the Consul API.

There are several organizations using ContainerPilot 2.x in production. We will support ContainerPilot 2.x for _N_?? with bug fixes released as patch versions but without additional features being added.

ContainerPilot 2.x will be tagged in GitHub but marked as deprecated. The `master` branch on GitHub will be for 3.x development but will be noted as "unstable" until ready to ship the first release.
