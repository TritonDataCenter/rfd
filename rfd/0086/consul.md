## Consolidate discovery on Consul

Consul provides a number of higher-level capabilities than a simple KV store like etcd or ZK. Providing the ability to use these capabilities means either going with a least-common-denominator approach or having complex provider-specific configuration options for tagging interfaces, providing secure connection to the backend, and faster deregistration on shutdown, among others.

All the Autopilot Pattern example applications are using Consul (with the sole exception of the etcd blueprint). All known users of ContainerPilot are using Consul. Dropping support for anything other than Consul would reduce the scope of testing and development.

The primary argument against dropping non-Consul support (and one we should not dismiss easily) is that Kubernetes and related projects are using etcd as the service discovery layer. In our discussions with some end users, we haven't found that there's any resistance to the idea that the scheduler's own consensus & membership store doesn't need to be the same store used by applications. And even perhaps _should not_ be the same store, given that in most organizations the team responsible for application development will not be the same team responsible for running the deployment platform.

Another option that's been discussed is to embed the Consul agent inside ContainerPilot, so that ContainerPilot acts as a Consul agent on its own. This would make it more similar the [Habitat supervisor](https://habitat.sh) and reduce the complexity for end users who need to configure a coprocess for Consul agent currently. We've rejected this option to avoid risks of sharing memory with Consul, to allow us to drop-in new versions of Consul without code changes, and to avoid the inevitable scope creep when someone suggests why the agent couldn't also support `consul-template` behavior.

**Related GitHub issues:**

- [Drop support for non-Consul discovery backends](https://github.com/joyent/containerpilot/issues/251)
- [Consul agent discovery backend](https://github.com/joyent/containerpilot/issues/246)
- [Support for Zookeeper (stalled)](https://github.com/joyent/containerpilot/issues/142)

Example of Consul-specific feature support:

- [Node deregistration from Consul](https://github.com/joyent/containerpilot/issues/218)
- [Support Consul EnableTagOverride](https://github.com/joyent/containerpilot/issues/243)
- [Support Consul TaggedAddresses](https://github.com/joyent/containerpilot/issues/226)
- [Consul client certs](https://github.com/joyent/containerpilot/issues/169)
- [Consul availability timeout](https://github.com/joyent/containerpilot/issues/164)
