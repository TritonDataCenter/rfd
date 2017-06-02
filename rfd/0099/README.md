---
authors: Kody Kantor <kody.kantor@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 99 Client Library for Collecting Application Metrics

* [About](#about)
* [Intro and Background](#intro-and-background)
* [Example Usage](#example-usage)
* [Unique Design Elements](#unique-design-elements)
    * [Parent/Child Relationship](#parentchild-relationship)
    * [Dynamic Labelling](#dynamic-labelling)
    * [Children are leaf collectors](#children-are-leaf-collectors)
* [Problems](#problems)
    * [Metric Cardinality](#metric-cardinality)
* [Seeking Review](#seeking-review)

## About
`artedi` is a Node.js library for measuring fish -- specifically, the fish
being the services involved in Manta, the Triton Object Store.

This document will be a general overview of how this library is different
from other metric client libraries. To learn how the code is organized,
and for details on the user-facing API, see [DESIGN.md](./DESIGN.md).

## Intro and Background
Having access to live metrics is very valuable to operations teams. It
would help to find issues before they arise, and help to discover where
(and in what cases) issues are occurring.

Before we can start collecting metrics from our applications (Manta in
particular), as will be stated in
[RFD-91](https://github.com/joyent/rfd/blob/master/rfd/0091/README.md), we need
a metric library that fulfills our requirements. RFD-91 will be a proposal for
how we integrate application-level metrics into CMON itself. This document isn't
intended to be an RFD, but it could be mentioned in the RFD-91 writeup as a
means to an end.

This document is an explanation of the high-level design choices made during
the development of this metric client library. This is here so that we can
review the design of the library before we start integrating it into our
applications.

CMON is beginning to address metric reporting from an
infrastructure level. Application level metrics are also important. It
would be great we could view the latency of requests,
number of jobs running, number and rate of DNS queries, and error counts
(and more) occurring in Manta at a glance. In order to provide application level
metrics, we need our applications to broadcast metrics for a metric collector
(Prometheus, telegraf) to collect.

To begin with, we'll be exposing metrics from Manta. Manta is
written in Node.js. There is an existing Prometheus-style metric client
called [prom-client](https://github.com/siimon/prom-client). prom-client
works, but there are some features missing. We would like to be able to
pass an instance of a collector into imported libraries so that they can
also report their metrics. The use case for this is primarily for
node-cueball. We would like to pass a child of a metric collector into
cueball so that it can report detailed information about any network
errors that are occurring. prom-client doesn't support the notion of
child clients.

Another key factor is that the metric client be relatively agnostic to
the recipient of metrics. prom-client can output metrics in either json
or the Prometheus text format. This metric library will also support json and
Prometheus style text formats. Prometheus was chosen for a couple reasons. First
is that CMON already exists and exposes the Prometheus format. Second is that it
metric scrapers (Prometheus server, telegraf, etc.) have plugins that accept
the Prometheus format. In the future it should be possible to add metric formats
as needed.

Most metric reporting formats are pretty similar. They all have a particular
format for metric names, and include numbers and timestamps. This library only
does conversion to Prometheus when metrics are requested. The metrics are stored
in memory in a format that is not specific to Prometheus. When the time comes,
it should be relatively easy to add support for another metric format. If all
else fails, we can convert everything to json, and then convert from json to
the target format in question.

Due to our desire for a parent/child metric client, we have decided to
create our own metric client library to use in Node.js. This is a
description of some of the design decisions made (and why), and an
overview of some things to watch out for in using the library.

## Example Usage
Here is a simple example usage of counters and histograms.
```
var artedi = require('artedi');

// collectors are the 'parent' collector.
var collector = artedi.createCollector({
    namespace: 'http'
});

// counters are a 'child' collector.
// This call is idempotent.
var counter = collector.counter({
    name: 'requests_completed',
    help: 'count of muskie http requests completed',
    labels: {
        zone: ZONENAME
    }
});

// Add 1 to the counter with the labels 'method=getobject,code=200'.
counter.increment({
    method: 'getobject',
    code: '200'
});

collector.collect(function (metrics) {
    console.log(metrics);
    // Prints:
    // http_requests_completed{zone="e5d3",method="getobject",code="200"} 1
});

var histogram = collector.histogram({
    name: 'request_latency',
    help: 'latency of muskie http requests',
    buckets: [100, 1000, 10000] // Measure <= 100ms, 1000ms, or 10000ms.
});

// Observe a latency of 998ms for a 'putobjectdir' request.
histogram.observe(998, {
    method: 'putobjectdir'
});

// For each bucket, we get a count of the number of requests that fall
// below or at the latency upper-bound of the bucket.
// This output is defined by Prometheus.
collector.collect(function (metrics) {
    console.log(metrics);
    // Prints:
    // # HELP http_requests_completed count of muskie http requests completed
    // # TYPE http_requests_completed counter
    // http_requests_completed{zone="e5d3",method="getobject",code="200"} 1
    // # HELP http_request_latency latency of muskie http requests
    // # TYPE http_request_latency histogram
    // http_request_latency{le="100"}zone="e5d3",method="putobjectdir"} 0
    // http_request_latency{le="1000",zone="e5d3",method="putobjectdir"} 1
    // http_request_latency{le="10000",zone="e5d3",method="putobjectdir"} 1
    // http_request_latency{le="+Inf",zone="e5d3",method="putobjectdir"} 1
    // http_request_latency_count{zone="e5d3",method="putobjectdir"} 1
    // http_request_latency_sum{zone="e5d3",method="putobjectdir"} 998
});
```

## Unique Design Elements
### Parent/Child Relationship

The parent/child relationship is very important for our use case. This
concept is taken from [bunyan](https://github.com/trentm/bunyan).
This is a description of how it is implemented (or will be) in this library.
A parent collector is created with a set of properties including a name,
and a set of labels. Labels are key/value pairs that can be used to
'drill down' metrics. For example, to create a new parent collector:

```
var collector = artedi.createCollector({
    namespace: 'marlin',
    labels: {
        zone: ZONENAME
    }
});
```
And to create a child collector:
```
var gauge = collector.gauge({
    subsystem: 'agent',
    name: 'jobs_running',
    labels: {
        key: 'value'
    }
});
```

All of the child collectors created from the parent collector will have
the label `zone=ZONENAME`. The child that we created is a gauge in this
case. A user could also call `.counter()`, `.histogram()`, or
`.summary()` (summary not implemented yet).

In the Prometheus nomenclature, gauges, counters, histograms, and
summaries are all called 'collectors.' For this library, we're also
calling the parent instance a 'collector.' The child collector (gauge)
that we just created has the following labels: zone=ZONENAME,key=value.
It inherited the 'zone' label from its parent. Any metric measurement
that we take will include these two labels in addition to any labels
provided at the time of measurement. For example:

```
gauge.subtract(1, {
    owner: 'kkantor'
});
```
The reported metric from that operation will look something like this:
```
marlin_agent_jobs_running{zone="e5d03bc",key="value",owner="kkantor"} 4
```

### Log/Linear Buckets
One of the major problems with creating histograms in existing metric clients
is that they require the user to provide a static list of bucket values for
values to fall into. There are some problems with this, and to understand them
we first need to understand what role buckets serve.

Buckets are upper bounds on the value being tracked. For example, if a histogram
is tracking request latency, you may have the following buckets: [100, 200, 300,
400, 500, Inf] where each number represents time to completion in milliseconds.
Inf is a special bucket that counts ALL values, including those that are greater
than the largest bucket. So the value of Inf is >= sum(all bucket counts). Each
bucket counts values that are less than or equal to the bucket. So for a request
that took 222ms, the 300, 400, 500, and Inf buckets will be incremented.

This sounds good if we know that we'll have a normal distribution of inputs and
we know the approximate values that we should be receiving. This makes a lot of
sense for simple use cases, like a webserver that serves text files. The latency
of something simple like that should be relatively consistent. The usefulness of
tatic buckets degrades quickly when workloads become much more varied.

In Muskie, for example, we have some operations that finish quickly
(`putdirectory`), and some that can take a long time (`putobject`). The latency
of `putdirectory` will be relatively stable and low when compared to
`putobject`. The latency of `putobject` can vary widely based on how large the
object being uploaded is. We would like fine granularity when monitoring the
latency of `putdirectory`, and a coarse granularity when monitoring `putobject`.

We could solve this problem by maintaining separate histograms for each request
type. That's not a good idea for many reasons. One is that we still won't know
our exact latencies ahead of time, so we can't properly configure buckets with
accurate values. Another is that creating a separate histogram collector for
each request type would make the code look horrendous.

Luckily, this problem has been solved in-house already! DTrace has support
for log/linear quantization. In short, it gives us the ability to represent
both fine and coarse granularity in the same histogram. For more information on
log/linear quantization, see
[this DTrace blog post](http://dtrace.org/blogs/bmc/2011/02/08/llquantize/).

### Dynamic Labelling
We can see in the last example that the metric inherited two labels, and
we additionally crated a third label (`owner="kkantor"`) on the fly.
Existing metric clients (prom-client, the golang Prometheus client)
don't allow for dynamic creation of labels. We allow that in this
library. It is also unique for this library to allow for 'static'
key/value pairings of labels. Existing clients only allow users to
specify label keys at the time a collector is created, but we are
allowing a user to specify both a label key and value (`labels{'zone'}`
vs `labels{zone: ZONENAME}`).

By allowing on the fly creation of labels, we gain a lot of flexibility,
but lose the ability to strictly control labels. This makes it easier for
a user to mess up labeling. For example, a user could do something like
this:
```
var counter = collector.counter({
    name: 'requests_completed',
    help: 'count of requests completed'
});

if (res.statusCode >= 500 && res.err) {
    counter.increment({
        method: req.method,
        err: res.err.name
    });
} else {
    counter.increment({
        method: req.method
    });
}

// Elsewhere in the code...
collector.collect(function (str) {
    console.log(str);
});

/*
 * If both of the counter.increment() statements are hit once each,
 * the output might look something like this:
 * HELP: muskie_requests_completed count of requests completed
 * TYPE: muskie_requests_completed counter
 * muskie_requests_completed{method="putobject"} 1
 * muskie_requests_completed{method="putobject",err="Service Unavailable"} 1
 */
```
The above example shows that two different metrics were created. This is
possibly the intended behavior, but depending on how queries are being
run, this may result in information being lost. Other implementations
would require a user to define labels up-front, and throw an error if
the user tried to create a label ad-hoc, like above.

Merits of up-front label declaration:
* Programming mistakes become runtime errors, rather than producing
    valid, but confusing data
    * This defines a type of 'metric schema'

Merits of dynamic label declaration:
* Flexibility, ease of use

In the end, I decided to implement dynamic declaration due to the
increase in flexibility.

### Children are leaf collectors
Children cannot be created from children. That is, a user can't call
.gauge() on a Counter to create a child Gauge.

The name of the metric (`marlin_agent_jobs_running` from our example) is
created by appending the `namespace` field from the parent collector to
the `subsystem` and `name` fields of the child, separated by
underscores.

When a child collector is created, the parent registers the collector.
This is done for two reasons. The first is that the user only needs to
call .collect() on the parent collector in order to generate metric
output. The second is so that child collectors are not garbage collected
into non-existence after they are dereferenced by whatever function
created them to measure a certain task. When a user calls .gauge() on a
parent collector, it may or may not create a new gauge depending on if
one with the same metric name (`marlin_agent_jobs_running` from our
example) already has been registered.

## Problems
### Metric Cardinality

To illustrate this problem, let's say that we have the label keys
`method`, `code`, and `username`. `method` can take the values `get`,
and `post`. `code` can take the values `200`, `500`, and `404`.
`username` can take any value from a list of 100 users. The number of
possible counters created in this situation is `(2*3)*100=600`. For this
very small data set, you can see that we have the possibility of having
a shitload of data. Keeping unbounded fields like `username` to a
minimum (or not including them at all) is very important to maintaining a
manageable amount of data (as well as conserving memory in the metric
client and server). This is called the problem of **metric
cardinality**.

## Seeking Review

Please let me know your thoughts especially on the design decisions
listed above (parent/child relationship, dynamic labelling, children are
leaf collectors). All other feedback is also very much appreciated!

Biggish TODOs:
* The way that we create children is kind of hackey - we directly read
traits from the parent object passed in
* Our hash function is taken from prom-client, and is pretty bad (but it works)
    * Do we need to change it?
* Performance fixes:
    * Histogram: Change from map of Counters to a single Counter
    * A lot of nested for-in loops
    * Actually do performance measurements
* Consider possible CLI integrations
    * It could be useful to provide a convenient way to access application-level
        metrics. It's probably more in the scope of the individual application,
        but it's something to write down and consider
* How do we come up with values for Histogram buckets?
    * SOLVED: We're going to automatically do log/linear buckets, like dtrace.
    * More info is in [DESIGN.md](./DESIGN.md).
* We can potentially use DTrace to do some cool things here, like to help
    determine what values are really coming in through Histograms so we can
    make more intelligent decisions when creating buckets (thanks, Chris!).
    Also, possibly using DTrace like we do in Bunyan with `bunyan -p` to collect
    metrics that are not usually collected in production (debug metrics, if you
    will).
