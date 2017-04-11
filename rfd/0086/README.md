----
authors: Tim Gross <tim.gross@joyent.com>
state: predraft
----
<!--
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->


# RFD 86 ContainerPilot 3

ContainerPilot is an application-centric micro-orchestrator that automates the process of service discovery, configuration, and lifecycle management inside a container. ContainerPilot v1 ("ContainerBuddy") explored these ideas, ContainerPilot v2 was a production-ready expression of those ideas. ContainerPilot v3 will take the lessons learned from real-world production usage of ContainerPilot and refine its behavior. Additionally, ContainerPilot v3 will have features intended to interoperate with new application management features of Triton described in [RFD36 "Mariposa"](https://github.com/joyent/rfd/blob/master/rfd/0036/README.md).

This RFD is broken into multiple sections:

- [First-class support for multi-process containers](multiprocess.md)
- [Mariposa integration](mariposa.md)
- [Configuration improvements](config.md)
- [Backwards compatibility and support](compat.md)
- [Consolidate discovery on Consul](consul.md)
- [Example configurations](examples/)
