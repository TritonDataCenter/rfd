---
authors: Jan Wyszynski <jan.wyszynski@joyent.com>
state: predraft
dicussion: https://github.com/joyent/rfd/issues/52
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 <contributor>
-->

# RFD 110 Operator-Configurable Throttles for Manta

## Overview

The purpose of this RFD is to discuss possible directions for implementing
general throttles for Manta. While the initial iteration of the throttle
will be implemented in Muskie as a per-process rate-limiter, the intention
is to create a general purpose throttling library that can used by any
service and can be dynamically instrumented by the operator. This means
that instead of just throttling client requests at the front door the
operator would be able to, for example, select a particular moray process
and set a request rate limit for just that moray process.

A motivating example for the utility of throttling is the observation that
during Manta stress tests, the asynchronous peer in a Manatee cluster can
fall arbitrarily far behind the primary because the application rate of
postgres WAL records on the peer is slower than the rate at which they
are being sent. In such a situation, it would be useful not only for the
asynchronous peer to throttle incoming requests, but also for the sending
peer to recognize this and either back off or queue outgoing requests to
reduce the send rate.

Another motivating situation is the availability lapse that occurs when
users publish URLs to Manta objects on social media with using a CDN.
In this situation a muskie throttle probably makes the most sense.

## Proposal

As an initial iteration, this RFD proposes the addition of a throttling
module to the Muskie repo.

### Parameters

This module is configured via the file in
etc/config.json in the "throttle" object. It exposes the following
tunables:

```json
...
"throttle" : {
	"concurrency": int,
	"requestRateCap": int,
	"reqRateCheckIntervalSec": int
},
...
```

Internally, the muskie-throttle is implemented with a vasync queue. The
concurrency value passed through the above configuration is fed directly
into the queue and indicates the number of tasks that the queue schedules
concurrently. Any surplus of requests is queued.

The request rate capacity "requestRateCap" is a request/second value that
indicates the maximum tolerable request rate before muskie starts sending
back responses with HTTP status code 429. Once the observed request rate
falls back to appropriate levels, muskie will start handling requests as
usual.

The request rate check interval "requestRateCheckIntervalSec" is the time
interval that muskie should wait before computing the request rate again.
It's unclear currently what this value should be, but setting it too low
risks capturing too few requests in the calculation, and setting it too
high risks muskie not responding to a burst quickly enough. The default
is 5 seconds. This is an arbitrary choice.

As of now, the default values for the above parameters are set to be
values that do not interfere with neither the concurrent operation of
10 mlive instances nor the muskie test-suite. Further investigation
based on real workloads is necessary.

### Configuration & Instrumentation

Currently, it would be desirable for the values referenced in the
previous section to be configured with manta-adm in addition to the
muskie configuration file. Eventually, it would be nice to add functionality
that would allow the operator to dynamically instrument these values in
response to unexpected traffic surge.

The end goal is to have something like a throttling "service" which has
global visibility over the throttling operations of all participating
manta services. Individual manta services could periodically send request
rate statistics to the global throttle service, which could in turn send
requests to other manta services with instructions from the operator to
modify their "concurrency" values, for example.

Having global visbility seems useful as an approach for distributing
traffic and also tuning the above parameters for all services. It might
even allow for the implementation of operator-defined throttling "rules"
that impose rate limits for particular requests coming from particular
ip addresses at particular times.

### Dtrace Providers

The current iteration of the muskie-throttle exposes a dtrace provider
called "muskie-throttle" with three probes: request_received, request_throttled,
and request_handled.

The "request_received" probe fires when the throttling module received a new
request. It passes two integers corresponding to observed request rate in the
last check interval, followed by the current length of the request queue.

The "request_handled" probe fires when the work for handling a specific request
and sending it's response is complete. The probe passes two integers
corresponding to the handled request's latency followed by the observed average
latency as computed for the entire lifetime of the muskie process.

The "request_throttled" probe firest when a request is throttled. This indicates
that muskie has returned a 429 status code to the client. This probe passes
three arguments: the request rate observed in the most recent check interval,
the throttled request's target url, and the request's HTTP method.
