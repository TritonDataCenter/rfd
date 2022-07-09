---
authors: Richard Kiene <richard.kiene@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 37 Metrics Instrumenter

## Introduction
SmartOS metrics are spread across multiple native libraries
(e.g. kstat, prstat, zfs) and modules such as node-kstat make interacting with
them via Node possible. However, there is not a common interface for
instrumenting a large set of SmartOS metrics from a single place. The goal of
this RFD is to provide a single interface for instrumenting a large set of
SmartOS metrics.

## Motivation
[RFD 27](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0027/README.md)
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
The Metric Instrumenter Node module will be an abstraction on top of one or more
[Node Addons](https://nodejs.org/api/addons.html)
(e.g. [node-kstat](https://github.com/bcantrill/node-kstat)).

Consumers of the Metric Instrumenter node module should not be required to
understand the intricacies of the underlying OS metric sources. Instead,
consumers should only need to know which metric(s) they would like to consume.

For example, a consumer should not need to know that they must retrieve data
from `kstat zones:::nsec_user` to get aggregate user CPU usage. Instead the
Metric Instrumenter will provide methods for metric retrieval, using predefined
metric keys. The string to metric pairs will be documented with each release and
programmatically discoverable via the module itself.

Dynamic, or ad-hoc, instrumentation is not in scope. The goals of simplicity and
proper abstraction are in conflict with dynamic instrumentation. Thankfully,
nothing about the Metric Instrumenter should prevent consumers from combining it
with a future Dynamic Metric Instrumenter.

## Prerequisites

* [node-kstat](https://github.com/bcantrill/node-kstat) needs to be updated so
that it supports Node versions greater than 0.12.x.

* `zfs list` needs to be profiled so we understand it's impact on the box when
used frequently. Furthermore, a node module should be created that allows
calling a native library rather than synchronously calling a shell command.

## Default Metric Keys
* `cpu_agg_usage` => `kstat zones:::nsec_user`
* `cpu_wait_time` => `kstat zones:::nsec_waitrq`
* `zfs_used` => `zfs list used`
* `zfs_available` => `zfs list available`
* `load_average` => `kstat zones:::averun_1min`
* `mem_agg_usage` => `kstat memory_cap:::rss`
* `mem_limit` => `kstat memory_cap:::physcap`
* `mem_swap` => `kstat memory_cap:::swap`
* `mem_swap_limit` => `kstat memory_cap:::swapcap`
* `net_agg_packets_in` => `kstat link:::ipackets64`
* `net_agg_packets_out` => `kstat link:::opackets64`
* `net_agg_bytes_in` => `kstat link:::rbytes64`
* `net_agg_bytes_out` => `kstat link:::obytes64`
* `time_of_day` => `gettimeofday(3C)`

## Methods
* `getMetric(<metric_key>, function(err, metric_data))`
  * metric_data example

  ```
  {
      "origin": "kstat link:::rbytes64",
      "unit": "bytes",
      "base": 2,
      "type": "counter",
      "value": 1234
  }
  ```
  * example usage

  ```
  instrumenter.getMetric('cpu_agg_usage', function(err, metric_data) {
      if (err) {
          assert(!err);
      } else {
          // do things with metric_data here
      }
  });
  ```

* `getMetrics(<metric_keys>, function(err, metrics_data))`
  * metrics_data example

  ```
  {
      "net_agg_bytes_in": {
          "origin": "kstat link:::rbytes64",
          "unit": "bytes",
          "base": 2,
          "type": "counter",
          "value": 1234
      },
      "zfs_used": {
          "origin": "zfs available",
          "unit": "bytes",
          "base": 2,
          "type": "counter",
          "value": 1234
      }
  }
  ```
  * example usage

  ```
  instrumenter.getMetrics(['mem_swap', 'zfs_used'], function(err, metric_data) {
      if (err) {
          assert(!err);
      } else {
          // do things with metrics_data here
      }
  });
  ```

* `getMetricKeys(function(err, keys)`
  * keys example

  ```
  {
    "net_agg_bytes_in": {
        "origin": "kstat link:::rbytes64",
        "unit": "bytes",
        "base": 2,
        "type": "counter"
    },
    ...
  }
  ```
