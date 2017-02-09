## Backwards compatibility and support

There are several interfaces to consider for ContainerPilot backwards compatibility:

1. [The interface with the discovery service (Consul or etcd).](#interface-with-the-discovery-service)
2. [The interface exposed to Prometheus-compatible clients.](#interface-with-prometheus)
3. [The ContainerPilot configuration file and arguments.](#containerpilot-configuration)
4. [The interface with behavior hooks.](#behavior-hooks)
5. [The internal ContainerPilot APIs with its golang packages.](#internal-containerpilot-apis)
6. [The interface with the ContainerPilot development community.](#containerpilot-development-community)
7. [The interface with Joyent Support.](#joyent-support)


##### Interface with the discovery service

The proposal to [consolidate discovery on Consul](consul.md) means that any users of the etcd backend will need to move to Consul in order to upgrade to ContainerPilot 3. For end users using Consul as their discovery backend, each container image can be safely updated independently; there is no communication between ContainerPilot instances except through the Consul API. The interface with Consul itself will remain unchanged.

##### Interface with Prometheus

This interface will remain unchanged except as we upgrade any Prometheus client library bindings over time.

##### ContainerPilot configuration

The changes in this RFD are not backwards compatible with ContainerPilot 2.x configuration and each container image using ContainerPilot will need to be newly configured. Upgrading can be done independently for each application image, as there is no communication between ContainerPilot instances except through the Consul API. This should allow organizations to do an upgrade over time.

##### Behavior hooks

The changes in this RFD leave the general interface of forking behavior hooks unchanged; the executables are forked and the exit code of the hook determines success. Many of the separate behavior hooks will be merged together in ContainerPilot 3:

- `preStart`, `preStop`, and `postStop` hooks will be folded into the new [dependency management](multiprocess.md#dependency-management).
- `coprocess` and `task` hooks will be folded into the new multi-process configuration with [no-advertise](multiprocess.md#no-advertise).

In the case of `sensors` the existing interface is to read the stdout of the forked process and parse it as a value, but this has proven to be brittle and reduces debuggability. Instead `sensors` will use the proposed [`PutMetric`](mariposa.md#putmetric-post-v3metric) API to record metrics.

##### Internal ContainerPilot APIs

Although the ContainerPilot code base is broken into multiple packages, the interfaces have not been designed for independent consumption. The stability of these APIs has not been guaranteed and we should document this as part of contributor guidelines.


##### ContainerPilot development community

ContainerPilot 2.x will be tagged in GitHub but marked as deprecated. The `master` branch on GitHub will be for 3.x development but will be noted as "unstable" until ready to ship the first release. We will also expand the contributor guidelines and generally improve the "first contribution" story over the period of this work.


##### Joyent Support

There are several organizations using ContainerPilot 2.x in production. We will support ContainerPilot 2.x for _N_?? (TODO) with bug fixes released as patch versions but without additional features being added.
