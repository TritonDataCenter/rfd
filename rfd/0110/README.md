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
	"concurrency": 50,
	"requestRateCap": 5000,
	"reqRateCheckIntervalSec": 5,
	"queueTolerance": 10
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
is 5 seconds. This is an arbitrary choice.  As of now, the default values
for the above parameters are set to be values that do not interfere with
neither the concurrent operation of
10 mlive instances nor the muskie test-suite. Further investigation
based on real workloads is necessary.

Finally the "queueTolerance" tunable corresponds to the number of requests
muskie will tolerate in the queue during periods in which the request rate
goes above capacity before it starts throttling requests. The queueTolerance
can be viewed as a "hard" capacity or buffer space for queueing requests
during bursty traffic.

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

### Dtrace Probes

The current iteration of the muskie-throttle exposes a dtrace provider
called "muskie-throttle" with four probes:

- *request_received*. This probe passes the number of requests currently queued
  on the request queue at the moment that it fired. Queued requests are
  operations that are not running, but waiting for other requests to be
  serviced. This number is used to decide whether, during periods of bursty
  requests the next request is throttled or queued (according to whatever soft
  capacity is decided upon).
- *request_rate_checked*. This change exposes a configuration called
  "reqRateCheckIntervalSec" which indicates the number of seconds muskie should
  allow between checking subsequent request rates. Request rates are evaluated as
  the number of requests that arrived during one of these intervals. This probe
  fires at the end of one of these intervals, reporting the most recently
  observed request rate.
- *request_handled*. This probe fires after a request has been handled and
  reports both *that* request's latency followed by the running average over all
  latencies recorded during the most recent check interval.
- *request_throttled*. This probe fires when a request is throttled. If this
  probe fires the the client originating the offending request received a 429
  status code. The probe returns the most recent request rate followed by the target
  url and http method of the throttled request.

### Testing

Initial testing for the muskie-throttle was done against a coal deployment using
mlive to generate a uniform workload. The test was repeated for various
combinations of mlives and concurrencies. Average request latency, average queue
size and average request rates for different mlive, concurrency pairs are
reported in the table below:

| number of mlives/concurrency | 1       | 10    | 100   | 1000  |
|------------------------------|---------|-------|-------|-------|
| 1                            | 2, 1    | 2, 0  | 2, 0  | 1, 0  |
| 10                           | 112, 6  | 25, 1 | 25, 0 | 20, 0 |
| 25                           | 220, 16 | 45, 2 | 40, 0 | 55, 1 |

The the tuples in the matrix above correspond to (average request latency,
average queue size). Request latencies are given in milliseconds. It seems that
the trend is as we increase concurrency muskie queues fewer requests and latency
generally goes down. Looking at the actual latencies all the tests above show
periodicity in terms or request latencies. It seems that there are periods of
fewer low latency followed by periods of higher latency. The values during
high/low latency periods are roughly constant.

To see the throttle work in action, I used observed request rates from the
experiments documented above. Since the experiment with concurrency 1 against 25
mlive instances showed the most queueing I re-ran that experiment with a
soft-cap of 10 requests and a request rate capacity of 20 requests/second (the
rate I observed in my experiments was rougly 28 requests/second). I expected to
find that the request_throttled probe fires when the most recent observed
request rate is greater than 20 rps *and* there are 10 requests queued. For the
purpose of this experiment alone I modified the request_throttled probe to
additionally print the number of queued requests at the time the probe fired.

Running the following probe:
```
muskie-throttle*:::request_throttled{
        printf("queue: %d, rate: %d, url: %s, method: %s", arg0, arg1,
				copyinstr(arg2), copyinstr(arg3));
}
```
Generates the following output whenever the throttle observes a request rate
higher than 20 rps with more than 10 requests queued:
```
CPU     ID                    FUNCTION:NAME
  0  12190 request_throttled:request_throttled queue: 10, rate: 66, url:
/notop/stor/mlive, method: PUT
  4  12190 request_throttled:request_throttled queue: 10, rate: 66, url:
/notop/stor/mlive, method: PUT
  5  12190 request_throttled:request_throttled queue: 10, rate: 66, url:
/notop/stor/mlive/mlive_21, method: PUT
  4  12190 request_throttled:request_throttled queue: 10, rate: 55, url:
/notop/stor/mlive, method: PUT
  4  12190 request_throttled:request_throttled queue: 10, rate: 55, url:
/notop/stor/mlive, method: PUT
  2  12190 request_throttled:request_throttled queue: 10, rate: 55, url:
/notop/stor/mlive, method: PUT
  2  12190 request_throttled:request_throttled queue: 10, rate: 55, url:
/notop/stor/mlive, method: PUT
  3  12190 request_throttled:request_throttled queue: 10, rate: 55, url:
/notop/stor/mlive, method: PUT
```

We can also see the requests being throttle from the mlive output:
```
using base paths: /notop/stor/mlive
time between requests: 50 ms
maximum outstanding requests: 100
environment:
    MANTA_USER = notop
    MANTA_KEY_ID = 9c:bc:f3:fa:47:0b:79:2b:e1:72:6f:91:09:f0:d2:d6
    MANTA_URL = http://localhost:8080
    MANTA_TLS_INSECURE = true
creating test directory tree ... failed (manta throttled this request)
creating test directory tree ... failed (manta throttled this request)
creating test directory tree ... failed (manta throttled this request)
creating test directory tree ... failed (manta throttled this request)
```

This is last output line is the message of the new `ThrottledError`
added to muskie's error.js.
