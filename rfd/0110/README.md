---
authors: Jan Wyszynski <jan.wyszynski@joyent.com>
state: predraft
dicussion: https://github.com/TritonDataCenter/rfd/issues/52
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

This RFD documents the design and implementation of a coarse muskie
rate-limiter. The use-case addressed by the design is alleviating
manta-wide stress when there is simply too much load for the system to
handle. When manta load is too high, it is desirable to respond to
clients in a way that will make them back-off until outstanding requests
are handled.

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
To reject a request when manta is under too much load, a rate-limited muskie
will send an HTTP status code 503 (ServiceUnavailable) without doing any
processing that is specific to the request. Currently, muskie doesn't
differentiate between different types of requests, such as PUTs and GETs.
Maintaining separate queues for reads and writes, or metadata and content
operations, may be useful and merits further investigation.

In the language associated with a vasync queue, a request is "pending" if it is
has been received by muskie, but the callback for processing it has not been
scheduled. In the current iteration, every request that enters the "pending"
state is eventually processed. It may be useful to implement some sort of
timeout for requests sitting in the pending state, opting to get clients to retry
requests instead of allowing them to observe high request latencies.

## Restify
Restify has a throttling [plugin](http://restify.com/docs/plugins-api/#throttle)
that was proposed at a manta call, but the conclusion reached in various
discussions was that muskie should not use it because
    * Not all services we want to rate-limit use restify
    * Dependence on restify has led to bugs in the past

Testing to compare the performance of the throttle discussed here and
the restify throttle later in the development process may be useful for ensuring
that efficiency is up to par. It may be useful to consider including some of the
options that the restify throttle exposes in this design. One such option is
maintaining a per-client-IP request queue.

### Parameters
Currently, the muskie module is configured via the file `etc/config.json`
the "throttle" object. It exposes the following configuration parameters
(shown with their corresponding default values):

```json
...
"throttle" : {
        "enabled": false,
	"concurrency": 50,
	"queueTolerance": 25
},
...
```

The corresponding SAPI tunables are:

    - MUSKIE_THROTTLE_ENABLED
    - MUSKIE_THROTTLE_CONCURRENCY
    - MUSKIE_THROTTLE_QUEUE_TOLERANCE

A dicussion concerning the tradeoffs between configuring these values on the fly
and making them SAPI tunables concluded that it was better to preserve
consistency, maintaining SAPI as the main source of manta component
configuration.

The "enabled" parameter decides whether muskie performs any request throttling
at all. If the throttle is not enabled, muskie will operate just as it did prior
to the introduction of the throttle. With the goal of being minimally-invasive
to normal manta operation in mind, the throttle is disabled by default.

The "concurrency" parameter corresponds to the concurrency option passed to the
vasync queue that the coarse rate-limiter is implemented with. It represents the
number of request-processing callbacks muskie can run at once. If all the slots in
the queue are filled, incoming requests will start entering the "pending" state,
waiting for request callbacks to finish.

The "queueTolerance" parameter corresponds to the number of "pending" requests
muskie will tolerate before it responds to new requests with 503 errors.
Experiments with mlive show that queueing rarely occurs with a concurrency value
of 50. Queues that hit a depth of 25 likely indicate anomalous request latency
and suggest a problem elsewhere in the system that should be investigated.

The default values of these parameters are based on load that was observed on
SPC muskie instances. In general, tracing with the restify `route-start` and
`route-done` parameters shows that under typical operation a muskie instance in
SPC processes an average of 15 requests concurrently. The default value of the
concurrency parameter is deliberately much higher than this average request
rate. The reason for this being that the throttle is designed to be minimally
invasive under normal and even slightly-higher-than-normal load.

### Dtrace Probes
Currently, the muskie-throttle exposes a dtrace provider called "muskie-throttle"
with two probes:

- *request_throttled*. This probe fires when a request is throttled. If this
  probe fires then the client originating the offending request received a 503
  status code. The probe passes the number of occupied vasync queue slots, the
  number of queued or "pending" requests, the url, and the http method of the
  request as arguments.
	```
	muskie-throttle*:::request_throttled{
		printf("slots: %d, queued: %d, url: %s, method: %s", arg0, arg1, copyinstr(arg2),
				copyinstr(arg3));
	}
	```
  Example output:
	```
	[root@0e176aeb-3a6b-cf90-b846-9e1d293ac1ae ~/muskie-stats/bin]# dtrace -s \
		request_throttled.d
	CPU     ID                    FUNCTION:NAME
	  7  11010 request_throttled:request_throttled slots: 50, queued: 25, url:
		/notop/stor/mlive/mlive_24/obj method": GET
	```
  This probe will only fire if all the slots are occupied and the number of
  queued requests has reached the "queueTolerance" threshold. The probe includes
  the occupied slots and queue arguments despite the fact that, given knowledge
  of the muskie configuration, they provide no new information. The hope is that
  including these parameters will answer the question of whether the SAPI
  tunables need to be adjusted without requiring the operator to look in two
  places.

- *request_handled*. This probe fires every time a request is handled. It includes
  the same information that the request_throttled probe provides. The benefit
  of having this probe is that the operator can use it to differentiate between
  requests being throttled and requests being handled under high-load situations.
  The output of the the probe is the same as that of the request_throttled probe
  only that the slots and queued values are not guaranteed to be the
  operator-defined threshold values.

### Future Work

#### Generalizing
For now, the core throttling logic is implemented as a module in muskie. To
generalize the logic, it may be useful to implement a library as an npm
package that any manta service written in node.js can use. All throttling logic
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

#### Fine-grained Throttle
It may be useful to maintain separate request queues for differente types of
requests. For example, certain loads might generate a much higher volume of PUTs
than GETs. In this case, because the PUTs are the root cause of the load, it would
be beneficial to throttle only PUTs and maintain a high GET throughput as opposed
to blocking GETs because some client is generating a lot of PUTs. An even more
fine-grained throttle might differentiate between different types of operations
(putobject vs putdirectory) and could even use tools such as the one outlined in
[MANTA-3426](https://devhub.joyent.com/jira/browse/MANTA-3426) to throttle requests
that put a lot of stress an a particular metadata shard, which seemed to be
a contributing factor to [SCI-293](https://devhub.joyent.com/jira/browse/SCI-293).

As mentioned in the discussion of the restify throttle plugin, it could also be
useful to throttle requests on a per-IP basis. In general, it does not make
sense to throttle clients that are not responsible for high load. Doing so also
does not address the root cause of the load.

With a more fine-grained throttle comes the problem of managing a more
fine-grained configuration. For each request differentiating property described
in the previous two paragraphs, it may be desirable to impose concurrency or
queue tolerance thresholds for only those requests that match a specific set of
criteria. It might even be desirable to disable (or enabled) throttling for some
types of requests altogether.

#### Global Decisions
In a more complex iteration of the throttle, we want to have a way to make
throttling decisions with system-wide information. This means that we will want
to either have a separate horizontally-scalable manta component that talks to
all throttled services, tuning throttle parameters as necessary, or have the
throttled services themselves communicate with each other to make the same
decisions. For this reason, the per-muskie-process iteration of the throttle
should be built with the possibility of sharing information concerning resources
and various tunable parameters in mind.

#### Configuration
Two big open questions concerning the implementation of *operator-configurable*
throttling are:

- *How* are things configured?
- *What* is configured?

#### How

Currently, the muskie throttle parameters are configured as SAPI tunables. The
reason for this decision, as mentioned above, is to maintain consistency with
the way that other manta components are configured.

In the future, it may be useful to have a stand-alone configuration service that
periodically checks on various muskie instances to present a more globally-aware
picture of the load that manta is under. This may allow the operator to make
better decisions about how to tune the throttle parameters of individual requests.

We may or may not want to investigate the possibility of having the library tune
throttling parameters automatically when it experiences various levels of
traffic. With a global configuration service, we may also be able to automate
such inter-process decisions. Figuring out what paramaters it makes sense to
tune automatically will require further investigation.

#### What

##### Concurrency
Higher concurrency values will result in more concurrent requests being handled
by manta at any given point. This comes at the cost of greater load, but decreases the
likelihood of exceptionally high request latencies. Lower concurrency
values will result in fewer requests being handled concurrently at the cost of higher
muskie queue depths (or 503 responses if the queue tolerance is low), which in turn
increase the likelihood of high request latency.

Another question motivated by the operational semantics of a vasync queue is how
to handle the situation in which the number of incoming requests exceeds the
concurrency value of the queue. In this situation, the queue will begin to accumulate
requests that will not be scheduled until a slot in the queue becomes available. It may
be useful to have muskie tune the concurrency value of the queue to adapt to
higher or lower queue lengths. For example, if muskie finds that there are
consistently more than 5 requests in the pending state on the queue, it may
choose to increase the queues concurrency value by 5 so that these extra
requests can be scheduled. Alernatively (or perhaps additionally) this configuration
could be exposed to the operator.

##### Queue Tolerance
A high queue tolerance value will result in more requests being queued under
high load but may decrease the likelihood of rejecting requests with 503s.
A low queue tolerance will result in more requests being rejected with 503s
under high load, but will also limit muskies memory footprint in those
situations.

One possibly unintended consequence of a high queue tolerance value is increased
individual request latency. If clients timeout waiting for a response and then
retry the request, the queue can actually lead in more requests being rejected
with 503s because of induced client retries.

#### Validation
The parameters described in the "Parameters" section do not currently undergo
any validation. Another important point to address is what upper/lower bounds
should be set on numeric values. Determining these bounds will require more
experimentation with realistic workloads.

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
not degrade performance, but that for workloads that muskie instances in staging
do not handle well, the throttle begins to send 503s to protect against
brownout. It may be useful to write some scripts like mlive that can generate
these different types of workloads.

Testing in staging also provides an opportunity to demonstrate dynamic configuration
of the tunables listed in previous sections. We should be able to set values
that cause aggressive throttling and values that cause less aggressive
throttling and see that the 503s were sent when expected.
