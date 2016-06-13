---
authors: Richard Kiene <richard.kiene@joyent.com>
state: pre-draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 0037 Metrics Instrumenter
## Introduction
SmartOS metrics are spread across multiple native libraries
(e.g. kstat, prstat, zfs) and modules such as node-kstat make interacting with
them via Node possible. However, there is not a common interface for
instrumenting a large set of SmartOS metrics from a single place. The goal of
this RFD is to provide a single interface for instrumenting a large set of
SmartOS metrics.

## Motivation
[RFD 27](https://github.com/joyent/rfd/blob/master/rfd/0027/README.md)
introduces the concept of a global zone Metric Agent which exposes metrics on a
per container, per request basis. The Metric Agent will need to interface
directly with native libraries in order to return the necessary metrics. Rather
than embedding the code necessary to interact with native metrics in the Metric
Agent itself, it seems preferable to provide an abstraction between the Node to
native modules and the calling code. This should provide more portable code and
code re-use, should a different application/agent need to instrument SmartOS.

## Considerations
Before deciding on a Node based module implementation, the following options
were also considered but not chosen:

* Removing the need for a Node based module by implementing a C based Metric
Agent and calling the native libraries directly.

    Languages written in C can take advantage of all of the mature debugging
    tooling SmartOS has to offer, which is nice. However, the set of HTTP server
    libraries leave quite a bit to be desired (e.g. cumbersome to work with,
    incompatible license, etc.), and the amount of de novo work necessary is not
    justified by a language that by its very nature will require more work than
    JavaScript.

* Implementing the Metric Agent and the instrumenter in a static language such
as Rust.

    Rust seems like a very promising language. The downside to Rust is that
    it is also not very mature, and lacks support for the SmartOS debugging
    suite. Given that the instrumenter will be in the global zone, using an
    immature language does not seem prudent. Additionally, choosing Rust would
    require a significant investment to support the full suite of debugging
    tools SmartOS has to offer.

* Providing the Metric Agent functionality with a pluggable front and backend
  instrumenter.

    On the surface a pluggable instrumenter seems nice, but in reality it should
    not be necessary. If the Metric Agent in RFD 27 is designed correctly, it
    will be the only up-stack facing piece necessary, thus eliminating the need
    for a pluggable front end. Similarly, OS level metrics should not be
    gathered by more than one agent per compute node, so the set of consumers of
    metrics will not be diverse. Since there should not be a diverse set of
    metrics consumers, it seems appropriate to keep the abstraction between
    instrumenter and OS level intrumentation inside the instrumenter module
    itself.

## Approach

Consumers of the Metric Instrumenter node module should not be required to
understand the intricacies of the underlying OS metric sources. Instead,
consumers should only need to know which metric(s) they would like to consume.

For example, a consumer should not need to know that they must retrieve data
from `kstat zones:::nsec_user` to get aggregate user CPU usage. Instead the
Metric Instrumenter will provide a method such as
`getAggUserCPUusage(container_id, interval)` which will return the percent of
user CPU usage for the given container_id over and for the given time interval.
