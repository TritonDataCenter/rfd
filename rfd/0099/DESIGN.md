* [Intro](#intro)
* [Internal Structures](#internal-structures)
    * [Metric](#metric)
    * [MetricVector](#metricvector)
* [External Structures](#external-structures)
    * [Collector](#collector)
        * Private API
        * External API
    * [Counter](#counter)
        * Private API
        * External API
    * [Gauge](#gauge)
        * Private API
        * External API
    * [Histogram](#histogram)
        * Private API
        * External API

## Intro
This document contains a description of the internals of this library.
We outline each of the different objects that will be created, describe
the functions that can be called on each object, and enumerate the
'class variables' that are private to each object.

For more information about the high-level decisions that were made, see
[README.md](./README.md).

## Internal Structures
These structures are internal to `artedi`, and should not be directly
instantiated by the user.

### Metric
A Metric is the most basic structure that we have implemented. Every
collector type uses Metrics, but not directly.

The Metric class represents the value behind an individual metric. For example,
a Metric could represent the count of HTTP POST requests made that resulted in a
204 status code. This class has no knowledge of higher-level concepts like
counters, gauges, or histograms. It is simply a class that maintains a numeric
value, a timestamp, and associated labels.

| Variable | Type | Value |
|----------|------|-----------------|
|labels    |object|A map of label key/value pairs|
|value     |number|A number that describes the current value of the metric|
|timestamp |number|Unix time since the epoch, representing the time this metric was last modified|

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|add       |num     |Adds `num` to the `value` field of the metric. No positive/negative check is done on `num`|None|
|subtract  |num     |Subtracts `num` from the `value` field of the metric. No positive/negative check is done on `num`|None|

The `labels` that belong to each Metric are key/value pairs. There can
be two Metrics that have the exact same key/value pairs, but they cannot
belong to the same collector. For example, a Counter and a Gauge may
both have the labels {method="getObject",code="200"}. The Gauge and
Counter will be tracking different things though. In this case, the
Counter may be tracking requests completed, while the Gauge is tracking
request latency.

All collector functions (`add()`, `subtract()`, `observe()`, etc.) are
all built on top of the Metric's `add()` and `subtract()` functions. To
accomplish subtraction, `add()` is called with a negative number, or
`subtract()` can be called directly. A collector can call `subtract()`
with a negative number to do addition.

The user should never directly perform operations on Metrics, but
instead use collectors (which build on top of Metrics by way of
MetricVectors).

`subtract()` is not yet implemented.

### MetricVector
MetricVectors are built on top of Metrics and give them much more
utility. Counters and Gauges directly use MetricVectors. Histograms use
MetricVectors, but indirectly.

The MetricVector provides a way to organize, create, and retrieve Metric
objects. While a Metric represents a single data point, a MetricVector can
represent one or more data points. For example, a MetricVector could represent
the counts of all HTTP requests separated by method, and response code. Each
unique method and response code pair would result in a new Metric object being
created and tracked. The MetricVector class has no knowledge of higher-level
concepts like counters, gauges, or histograms. Counters, gauges, and histograms
are built on top of MetricVectors.

| Variable | Type | Value |
|----------|------|-----------------|
|fullName  |string|full name of what is being tracked, resulting from concatenation of namespace, subsystem, and collector name|
|metrics   |object|key/value mapping. Each key corresponds to a unique Metric object|

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|getWithLabels|object  |searches metrics map for Metrics with the provided labels|a Metric object, or null if not found|
|createWithLabels|object|creates a new Metric with the given labels, adds it to the metric map|the newly created Metric object|
|createOrGetWithLabels|object|calls `getWithLabels()` to determine if a Metric with the given labels is already created. If so, returns it. Otherwise, calls `createWithLabels()` and returns the created Metric|Metric object|
|prometheus|callback|iterates through the metric map, serializing each Metric into a prometheus-parseable string|None (string via callback)|
|json      |callback|same as `prometheus()`, but in JSON format|None (string via callback)|

Simply put, MetricVectors keep track of multiple Metrics. Counters and
Gauges directly wrap MetricVectors (which we'll explain later).
Histograms use Counters and Gauges in their implementation, so they also
use MetricVectors. MetricVectors do the vast majority of the heavy
lifting for collectors.

`json()` is not yet implemented.

Users should not directly interact with MetricVectors. They should use
things like collectors, which use MetricVectors internally.

## External Structures
These structures are what the user will interact with.

### Collector
A Collector is the 'parent' of all other collector types (Counter, Gauge,
Histogram). A Collector is what is first created by the user, and then the
user will create 'child' collectors from their Collector instance.

All of the labels passed to a Collector will be inherited by child collectors.

#### Private Fields
| Variable | Type | Value |
|----------|------|-----------------|
|namespace | string | top-level namespace provided by the user to identify all metrics registered to this Collector|
|registry  | object | key/value mapping of unique collector names -> child collectors|

`registry` keeps references to all of the previously-instantiated child
collectors. When it is time to serialize metrics, the Collector iterates through
this map and calls the serialization method of choice on each child collector.
The results are concatenated and returned to the user.

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|Collector | opts      | see `createCollector()`| see `createCollector()`|
|register  |collector object|if the given collector has already been registered, returns an error. Otherwise, adds the collector to `registry`|error, or null|
|getCollector|name|returns the collector with the full name of `name`, or null if not present in `registry`|collector object, or null|

`Collector()` is called by the public `createCollector` function.


#### External API
| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|createCollector|opts|creates a new Collector object with the given options (labels are included in `opts`)|a Collector object|
|counter|opts|creates a new Counter object with the given options (incl. labels). This call is idempotent|a Counter object|
|gauge|opts|creates a new Gauge object with the given options (incl. labels). This call is idempotent|a Gauge object|
|histogram|opts|creates a new Histogram object with the given options (incl. labels). This call is idempotent|a Histogram object|
|collect|callback|iterates through `registry`, calling the serialization method on each collector|None (string via callback)|

`collect()` should also take a serialization format (json, Prometheus, etc.),
but it currently assumes Prometheus.


### Counter
Counters are the most simple of the collector types. They simply count
up starting from zero. You can either increment a counter, or add
arbitrary positive numbers to counters. The numbers do not have to be
whole numbers. Each set of unique label key/value pairs results in a new
Metric being created. For this reason, it is very important to limit the
number of unique values that are placed in labels. For more information,
see the section on **Metric Cardinality** in README.md.

#### Private Fields
| Variable | Type | Value |
|----------|------|-----------------|
|fullName|string|full name of what is being tracked, resulting from concatenation of namespace, subsystem, and collector name|
|help|string|user-provided string explaining this collector|
|metricVec|MetricVector|empty to start, is populated as the user performs metric operations|
|type|string|'counter,' used during serialization|
|staticLabels|object|key/value mapping of labels that will be present in all metrics collected by this collector|

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|Counter |parent, opts|creates a Counter object from traits available in the parent, and options passed in|a new Counter object|

`Counter()` is called by the Collector object's `counter()` function.

#### External API
| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|increment |labels|adds 1 to the metric represented by `labels` (calls `add(1, metric)`)|None|
|add       |value, labels|adds `value` to the metric represented by `labels`, `value` must be > 0|None|
|labels|object|returns a metric that have *exactly* the label key/value pairs provided. If none exists, one is created|A Metric object|
|prometheus|callback   |returns all of the Counter's metrics in prometheus format as a string|None (string via callback)|

Counters internally use the `add()` function from the Metric object, and
additionally enforce that values are > 0. The Counter's `labels()`
function wraps the MetricVector's `createOrGetWithLabels()` function to
create Metrics. `prometheus()` wraps the MetricVector function of the
same name, and adds Counter-specific information, like the `# HELP` and `#
TYPE` strings.

There will be a `json()` function, but it is not yet implemented. It
will wrap the MetricVector's `json()` function.

### Gauge
Gauges are similar to counters. Gauges can count up, or count down relative
to their current value. Gauges start with an initial value of `0`. If you want
a gauge that can be set to arbitrary values, look at [AbsoluteGauge](#absolutegauge).

#### Private Fields
| Variable | Type | Value |
|----------|------|-----------------|
|fullName|string|full name of what is being tracked, resulting from concatenation of namespace, subsystem, and collector name|
|help|string|user-provided string explaining this collector|
|metricVec|MetricVector|empty to start, is populated as the user performs metric operations|
|type|string|'gauge,' used during serialization|
|staticLabels|object|key/value mapping of labels that will be present in all metrics collected by this collector|

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|Gauge |parent, opts|creates a Gauge object from traits available in the parent, and options passed in|a new Gauge object|

`Gauge()` is called by the Collector object's `gauge()` function.

#### External API
| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|add       |value, labels|adds `value` to the metric represented by `labels`|None|
|subtract  |value, labels|subtracts `value` from the metric represented by `labels`|None|
|labels|object|returns a metric that have *exactly* the label key/value pairs provided. If none exists, one is created|A Metric object|
|prometheus|callback   |returns all of the Gauge's metrics in prometheus format as a string|None (string via callback)|

`subtract()` has not been implemented yet. It will wrap the
Metric's `subtract()` function. There will be a `json()` function,
but it is not yet implemented. It will wrap the MetricVector's `json()`
function.

### AbsoluteGauge
AbsoluteGauges are metrics that can only be set to an arbitrary value. These are
useful for tracking things like the current amount of memory available on a
system, or the async lag of a postgres peer. If you need to 'move' a gauge
relative to its current position, you probably want to use [Gauge](#gauge)
instead.

| Variable | Type | Value |
|----------|------|-----------------|
|fullName|string|full name of what is being tracked, resulting from concatenation of namespace, subsystem, and collector name|
|help|string|user-provided string explaining this collector|
|metricVec|MetricVector|empty to start, is populated as the user performs metric operations|
|type|string|'gauge,' used during serialization|
|staticLabels|object|key/value mapping of labels that will be present in all metrics collected by this collector|

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|AbsoluteGauge |parent, opts|creates an AbsoluteGauge object from traits available in the parent, and options passed in|a new AbsoluteGauge object|

`AbsoluteGauge()` is called by the Collector object's `absoluteGauge()` function.

#### External API
| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|set|value, labels|sets the metric represented by `labels` to `value`|None|
|labels|object|returns a metric that have *exactly* the label key/value pairs provided. If none exists, one is created|A Metric object|
|prometheus|callback   |returns all of the Gauge's metrics in prometheus format as a string|None (string via callback)|

The `AbsoluteGauge` object has not yet been implemented.

### Histogram
Histograms are internally made up of Counters and Gauges. Once you
understand that, Histograms are much easier to understand. Histograms
count values that fall between a number of user-provided buckets.

#### Private Fields
| Variable | Type | Value |
|----------|------|-----------------|
|fullName|string|full name of what is being tracked, resulting from concatenation of namespace, subsystem, and collector name|
|name|string|short name of the collector, used when creating Counters and Gauges|
|namespace|string|namespace of collector, used when creating Counters and Gauges|
|subsystem|string|subsystem of collector, used when creating Counters and Gauges|
|buckets|number array|an array that holds the upper values of each bucket|
|counters|object|key/value mapping containing Counters for tracking metrics in each bucket|
|gauge|Gauge|a Gauge used to track the \_sum field of each metric|
|help|string|user-provided string explaining this collector|
|metricVec|MetricVector|empty to start, is populated as the user performs metric operations|
|type|string|'histogram,' used during serialization|
|staticLabels|object|key/value mapping of labels that will be present in all metrics collected by this collector|

| Function | Arguments | Result | Return Value|
|----------|-----------|--------|-------------|
|Histogram|parent, opts|creates a Histogram object from traits available in the parent, and options passed in|a new Histogram object|

`Histogram()` is called by the parent object's `histogram()` function.
Buckets will be created using the log/linear method, similar to how it's done in
[DTrace](http://dtrace.org/blogs/bmc/2011/02/08/llquantize/). This reasoning is
outlined in README.md.

#### External API
|observe|value, counter|iterates through buckets. If bucket's value >= `value`, that bucket and all subsequent buckets are incremented. The Gauge is also moved to track the running sum of values associated with the Counter|None|
|labels|object|checks if a Counter with the given labels already exists. If yes, returns it, otherwise creates a new Counter, and initializes another Gauge|None|
|prometheus|callback|iterates through the Counters, calling `prometheus()` on their `MetricVector` object. The results are stitched together and added to the result of calling `prometheus()` on the Gauge's MetricVector|None (string via callback)|

There are helper functions in the global `artedi` namespace to create linear
and exponential buckets. See [Other Public Functions](#other-public-functions).

Histograms are essentially a number of Counters per bucket. Counters are
really a set of Metrics. The **metric cardinality** problem gets even
more painful with Histograms, since each bucket can have multiple
Counters (if you want to measure multiple unique labels).

Here is some sample output from calling `prometheus()` on a Histogram:
```
http_request_latency{le="0",method="getjobsstorage",code="200"} 0
http_request_latency{le="100",method="getjobsstorage",code="200"} 427
http_request_latency{le="500",method="getjobsstorage",code="200"} 428
http_request_latency{le="1000",method="getjobsstorage",code="200"} 428
http_request_latency{le="5000",method="getjobsstorage",code="200"} 428
http_request_latency{le="+Inf",method="getjobsstorage",code="200"} 428
http_request_latency_count{method="getjobsstorage",code="200"} 428
http_request_latency_sum{method="getjobsstorage",code="200"} 5604
```
This output measure request latency (in milliseconds) of Muskie
requests. Our buckets are [0, 100, 500, 1000, 5000, +Inf]. The bucket
values are in milliseconds, with +Inf meaning 'infinity.' The specific
operations that this is measuring are 'getjobsstorage' that responded
with an HTTP 200 code.

From this output, we can see that 427 of the 428 requests took between 0
and 100 milliseconds. 1 request took between 100 and 500 milliseconds.
The average latency is `_sum / _count`, which is 13 milliseconds.

Although at first glance, Histograms look confusing, they are very
powerful!

With respect to the metric cardinality problem, we can see that for this
single method/code Histogram we've created eight metrics. You can
probably imagine the immense number of metrics that get created for all
of the different method/code combinations.

`exponentialBuckets()` and `linearBuckets()` are not implemented yet.
There will be a `json()` function, but it is not yet implemented. It
will wrap the MetricVector's `json()` function.
