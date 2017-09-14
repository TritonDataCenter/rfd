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
general throttles for Manta. The initial iteration of this throttle was
implemented as per-muskie-process rate limiter. The reason we chose to go this
direction initially is that it was relatively simple to implement and could be
used during incidents to quickly lighten the load on the entire system.

The intention is to eventually create a general purpose throttling library
that can used by any service with parameters that can be dynamically configured
by the operator. This means that instead of just throttling client requests
at the front door the operator would be able to, for example, select a
particular moray process and set a request rate limit for just that moray
process. This more complex throttle will also have a mechanism for making
globally-aware throttling decisions by talking to multiple services that opt-in
to throttle inbound requests. The later iteration will require a state-sharing
mechanism that we will not attempt to describe yet in this RFD.

A motivating [example](https://devhub.joyent.com/jira/browse/MANTA-3283)
for throttling in manta is the observation that
during Manta stress tests, the asynchronous peer in a Manatee cluster can
fall arbitrarily far behind the primary because the application rate of
postgres WAL records on the peer is slower than the rate at which they
are being sent. In such a situation, it would be useful not only for the
asynchronous peer to throttle incoming requests, but also for the sending
peer to recognize this and either back off or queue outgoing requests to
reduce the send rate.

Another motivating [example](https://devhub.joyent.com/jira/browse/MANTA-3261)
is the availability lapse that occurs when
users publish URLs to Manta objects on social media with using a CDN.
In this situation a muskie throttle probably makes the most sense.

## Terminology
When a request is "throttled," muskie sends an HTTP response with status code
429 without doing any processing that is specific to the request. In the current
iteration, muskie treats all incoming requests equally, not attempting to
differentiate PUTs from GETs, for example. Doing so may be useful and merits
further investigation.

In the language associated with a vasync queue, a request is "pending" if it is
has been received by muskie, but the callback for processing it has not been
scheduled. In the current iteration, every request that enters the "pending"
state is eventually processed. It may be useful to implement some sort of
timeout for requests sitting in the pending state, opting to get clients to retry
requests instead of allowing them to observe high request latencies.

## Restify
Restify has a throttling [plugin](http://restify.com/docs/plugins-api/#throttle)
that was proposed at a manta call, but we came to the conclusion that we'd
rather not use it because (1) not all services we want to throttle use restify
and (2) we'd rather not depend on restify. Ultimately, we would like a modular
npm package that we can plug in to any manta service with minimal change to the
service's operation or configuration.

Testing to compare the performance of a throttle that we roll on our own against
the restify throttle later in the development process may be useful for ensuring
that efficiency is up to par. We might also consider some of the options that
the restify throttle exposes that might be useful for our throttle when
designing the library.

## Initial Proposal
As an initial iteration, this RFD proposes the addition of a throttling
module to the Muskie repo. Over a longer time horizon, we plan to implement a
generic throttling library that any node.js service in manta can require and add
to middleware to any request-processing codepath.

### Parameters
Currently, the muskie module is configured via the file
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
concurrently. Surplus requests are put in the pending state.

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
either the concurrent operation of
10 mlive instances or the muskie test-suite. Further investigation
based on real workloads is necessary.

Finally the "queueTolerance" tunable corresponds to the number of requests
muskie will tolerate in the queue during periods in which the request rate
goes above capacity before it starts throttling requests. The queueTolerance
can be viewed as a "hard" capacity or buffer space for queueing requests
during bursty traffic.

### Dtrace Probes
The current iteration of the muskie-throttle exposes a dtrace provider
called "muskie-throttle" with four probes. The probes along with example scripts
and output are listed below:

- *request_received*. This probe passes the number of requests currently queued
  on the request queue at the moment that it fired. Queued requests are
  operations that are not running, but waiting for other requests to be
  serviced. This number is used to decide whether, during periods of bursty
  requests the next request is throttled or queued (according to whatever soft
  capacity is decided upon).
	```
	muskie-throttle*:::request_received{
		printf("%d", arg0);
	}
	```
  The output shows the number of requests that are in the pending state of the
  vasync queue at the time the probe was fired:
	```
	7  11007 request_received:request_received 5
	7  11007 request_received:request_received 5
	4  11007 request_received:request_received 5
	4  11007 request_received:request_received 4
	4  11007 request_received:request_received 4
	4  11007 request_received:request_received 5
	4  11007 request_received:request_received 5
	```
  The results above are generated with 25 concurrent mlive processes. Looking at
  a larger output window the number of queued requests seems cyclic - there is a
  period of ~10 outputs that show 0 requests queued followed by ~10 outputs
  that show 10-15 requests queued, and so on. For lower volume workloads (1-5
  mlive processes) there is almost no discernible request queueing even with
  relatively low concurrency values.
- *request_rate_checked*. This change exposes a configuration called
  "reqRateCheckIntervalSec" which indicates the number of seconds muskie should
  allow between checking subsequent request rates. Request rates are evaluated as
  the number of requests that arrived during one of these intervals. This probe
  fires at the end of one of these intervals, reporting the most recently
  observed request rate.
	```
	muskie-throttle*:::request_rate_checked{
		printf("%d", arg0);
	}
	```
  This output shows the request rate of a muskie process being checked
  periodically. It should be noted that the load here was generated with a
  single mlive process so the numbers aren't astronomical:
	```
	[root@0e176aeb-3a6b-cf90-b846-9e1d293ac1ae ~/muskie-stats/bin]# dtrace -s \
		request_rate_checked.d
	CPU     ID                    FUNCTION:NAME
	  7  11008 request_rate_checked:request_rate_checked 1
	  7  11008 request_rate_checked:request_rate_checked 6
	  5  11008 request_rate_checked:request_rate_checked 18
	  6  11008 request_rate_checked:request_rate_checked 18
	  4  11008 request_rate_checked:request_rate_checked 15
	```
- *request_handled*. This probe fires after a request has been handled and
  reports both *that* request's latency followed by the running average over all
  latencies recorded during the most recent check interval.
	```
	muskie-throttle*:::request_handled{
		printf("%d %d", arg0, arg1);
	}
	```
  Example output of a request that took ~1 millisecond. The second number is the
  running average request rate in the most recent check interval:
	```
	[root@0e176aeb-3a6b-cf90-b846-9e1d293ac1ae ~/muskie-stats/bin]# dtrace -s \
		request_handled.d
	CPU     ID                    FUNCTION:NAME
	  3  11047  request_handled:request_handled 1 1
	```
- *request_throttled*. This probe fires when a request is throttled. If this
  probe fires the the client originating the offending request received a 429
  status code. The probe returns the most recent request rate followed by the target
  url and http method of the throttled request.
	```
	muskie-throttle*:::request_throttled{
		printf("queue: %d, rate: %d, url: %s, method: %s", arg0, arg1, copyinstr(arg2),
				copyinstr(arg3));
	}
	```
  Example output here shows the queue size, rate that caused the throttle,
  with some basic information about the throttled request:
	```
	[root@0e176aeb-3a6b-cf90-b846-9e1d293ac1ae ~/muskie-stats/bin]# dtrace -s \
		request_throttled.d
	CPU     ID                    FUNCTION:NAME
	  7  11010 request_throttled:request_throttled queue: 10, rate: 222, url:
		/notop/stor/mlive/mlive_24/obj method": GET
	```
  This output shows a GET request being throttled when the request rate was
  222 requests/second and the number of pending request reached the threshold
  that I configured muskie to have to generate this output.

### Testing
Initial testing for the muskie-throttle was done against a coal deployment with
a single muskie instance running a single muskie process and
mlive to generate a uniform workload. The test was repeated for various
combinations of mlives and concurrencies. Average request latency, average queue
size and average request rates for different mlive-concurrency pairs are
reported in the table below:

| number of mlives/concurrency | 1       | 10    | 100   | 1000  |
|------------------------------|---------|-------|-------|-------|
| 1                            | 2, 1    | 2, 0  | 2, 0  | 1, 0  |
| 10                           | 112, 6  | 25, 1 | 25, 0 | 20, 0 |
| 25                           | 220, 16 | 45, 2 | 40, 0 | 55, 1 |

The tuples in the matrix above correspond to (average request latency,
average queue size). Request latencies are given in milliseconds. It seems that
the trend is as we increase concurrency muskie queues fewer requests and latency
generally goes down. The actual character of request latencies in the dtrace
output used to collect these results is periodic. There are periods low latency
requests followed by periods of high latency requests. The crests and troughs of
this latency measurement remain constant over the lifetime of the muskie
process.

To see the throttle work in action, I used observed request rates from the
experiments documented above. Since the experiment with concurrency 1 against 25
mlive instances showed the most queueing I re-ran that experiment with a
queue tolerance of 10 requests and a request rate capacity of 20 requests/second (the
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

### Future Work

#### Generalizing
For now, the core throttling logic is implemented as a module in muskie. To
generalize the logic, it would be useful to implement a library as an npm
package that any manta service written in node.js. All throttling logic
including and http endpoint exposed for tuning throttle parameters would be
contained in the module.

An important concern when generalizing throttling logic is minimizing the number
of changes that need to be made to the invoking service in order to apply the
logic. As of right now, it seems reasonable to have an init function which
instantiates a restify server and allows the invoker to point the throttle at a
particular static configuration (passing either a file path or a sub-object of
the invoking service's main configuration).

To actually use the module, it would be ideal to plug in a single callback
into a handler chain through which all incoming requests to the service pass.
Identifying such a chain or codepath will require further investigation.

#### Global Decisions
In a more complex iteration of the throttle, we want to have a way to make
throttling decisions with system-wide information. This means that we will want
to either have a separate horizontally-scalable manta component that talks to
all throttled services, tuning throttle parameters as necessary, or have the
throttled services themselves communicate with each other to make the same
decisions. For this reason, the per-muskie-process iteration of the throttle
should be built with the possibility of sharing information concerning resources
and various tunable parameters in mind.

#### Throttle Types
In different contexts, we will want to be able to throttle based on different
request properties. For example, there is good motivation for throttling
on a per-user basis in muskie. In other contexts, we might want to throttle on
the type of request (for example on whether it's a read or write of a metadata
or an object). With the initial throttle design it will be useful to consider
how requests might be filtered/selected by these various properties. We'll
probably want generic logic to handle throttle of a subset of requests, and then
separate self-contained logic for selecting the appropriate subset based on
whatever filters the throttle has been configured with.

#### Configuration
Two big open questions concerning the implementation of *operator-configurable*
throttling are:

- *How* are things configured?
- *What* is configured?

#### How

We'd like to be able to configure the
tunables statically in a configuration file, but we'd also like to be able to
tune these parameters dynamically without restarting whatever process is using
the throttling library. The former configuration method can be implemented
without changing the configuration scheme of the invoking service by pointing
the throttling library at a json configuration file that can either be in a
well-known location or a specific location specified by the invoking service
with a module "init" function.

Implementing dynamic configuration requires being able to talk to the invoking
service at runtime. An obvious possible direction is to expose these
configurations as http endpoints that are registered by the throttling library at
initialization time. To avoid interfering with whatever http server the invoking
service has created, the throttling library can create it's own restify server that
listens on a configurable port number. With such endpoints in place, we can add
a mode to the manta-adm that allows the operator to set values for these
parameters. We could also consider adding these as tunables on adminui.

It may also be useful to have a stand-alone configuration service that
periodically checks on the request rates of various muskie instances to present
a more globally-aware picture of the load that manta is under. This may allow
the operator to make better decisions about how to tune the throttle parameters
of individual requests.

We may or may not want to investigate the possibility of having the library tune
throttling parameters automatically when it experiences various levels of
traffic. With a global configuration service, we may also be able to automate
such inter-process decisions. Figuring out what paramaters it makes sense to
tune automatically will require further investigation.

#### What

##### Request Rate Check Interval
It seems pretty clear that
a configuration akin to "maximum request rate" should be included. Less clear is
whether it would be useful to set a "check interval" -- that is, the amount of
time muskie should allow before checking it's incoming request rate again.
Though this doesn't have any effect on the correctness of the request rate
figure reported in the dtrace probes, having a check interval that is too wide
may prevent muskie from effectively reacting to bursty traffic, and having one
that is too narrow may increase the average request latency more substantially.

##### Concurrency
Another question motivated by the operational semantics of a vasync queue is how
to handle the situation in which the number of incoming requests exceeds the
concurrency value of the queue.
In this situation, the queue will begin to accumulate requests
that will not be scheduled until a slot in the queue becomes available. It may
be useful to have muskie tune the concurrency value of the queue to adapt to
higher or lower queue lengths. For example, if muskie finds that there are
consistently more than 5 requests in the pending state on the queue, it may
choose to increase the queue's concurrency value by 5 so that these extra
requests can be scheduled. Alernatively (or perhaps additionally) this configuration
could be exposed to the operator.

##### Soft and Hard Capacities
Currently not implemented on the 'manta-throttle' branch is a distinction
between a "soft" and a "hard" request rate capacity. One possible design begins
queueing requests (leaving them in a kind of pending state) when a request rate
above the soft capacity is observed and rejecting requests (HTTP 429) when a
request rate above the hard capacity is observed. The reason this scheme is
not already implemented is mostly simplicity. At the moment, throttle.js has one
request vasync queue which runs up to 'concurrency' requests concurrently and
leaves all other requests in a pending state. In this way the concurrency serves
as a kind of soft capacity and a numeric upper bound on the number of pending
requests serves as a hard capacity. This implementation doesn't truly capture
the design described in the beginning of this paragraph because it deals in
request volume as opposed to request rate. It would be possible to implement the
design in a request-rate oriented manner by having an additional pending queue
that requests would be put on when a request rate above the soft capacity is
observed (below the soft cap requests are put on the original vasync queue -
which actually runs them).

This discussion also begs the question of whether using a vasync is useful. It
may be simpler to queue requests when a request rate above the soft
capacity is observed and begin dequeuing them once the request rate falls below
the soft cap. The hybrid scheme described at the end of the previous paragraph
may be useful because it allows the operator to control the volume of callbacks
dedicated to service incoming requests as well as the rate at which requests can be
received.

#### Validation
The parameters described in the "Parameters" section do not currently undergo
any validation. Another important point to address is what upper/lower bounds
should be set on numeric values. It is clear that the exclusive lower bound on
the rate check interval should be 0 but it's less clear what the bounds on
concurrency, max request rate, or queue tolerance should be. Determining these
bounds will require more experimentation with realistic workloads.

It would be nice to enforce parameter bounds with a JSON validation library like
ajv.

#### Testing
It is important to determine as early as possible what the symptoms of a
manta-component under heavy load are. What limits are hit? What failures crop up
(if any)? Determining this will require testing under different types of
realistic loads. Once the symptoms of heavy load are determined, we can build
whatever interface is necessary for the throttle observed them and adapt to
prevent brownout.

The next logical step for testing the throttle would be to deploy it in some
muskie instance on staging and generate different types of workloads. Some types
of workloads to consider are:
- Uniform workloads with just metadata operations.
- Uniform workloads with just small PUTs.
- Uniform workloads interleaving GETs, HEADs with small PUTs.
- Bursty variants for the three previous workload types.
- Uniform workloads interleaving small PUTs, GETs and, HEADs, with large PUTs.
- Bursty workloads interleaving small PUTs, GETs, and HEADs, with large PUTs.
- Uniform workloads with large PUTs
- Random workloads.

Included in the above cases should be mmpu operations as well as non-mpu
operations. We anticipate that the last type, random workloads, will be most
difficult for the throttle to handle. The test results should show that for
workloads that muskie instances in staging can handle well, the throttle should
not degrade performance, but thta for workloads that muskie instances in staging
do not handle well, the throttle begins to send 429s to protect against
brownout. It may be useful to write some scripts like mlive that can generate
these different types of workloads.

Testing in staging also provides an opportunity to demonstrate dynamic configuration
of the tunables listed in previous sections. We should be able to set values
that cause aggressive throttling and values that cause less aggressive
throttling and see that the 429s were sent when expected.
