----
authors: Richard Kiene <richard.kiene@joyent.com>
state: predraft
----

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 0027 Triton Container Monitoring
## Introduction
Presently, Triton does not offer a always-on mechanism for engineers and
operators to collect metrics about their containers and have them ingested by
their existing systems. Many engineers and operators have pre-existing
monitoring solutions such as Nagios, Graylog, ELK, and Splunk. The intent of
this RFD is to define a solution that allows customers to easily attach their
existing solutions to the metrics that are available via SmartOS commands and
DTrace probes, while simultaneously leveraging existing open-source tooling
where possible.


## Goals
* Produce a clearly defined interface for users and operators to extract data
that is readily available in SmartOS today.

* The end result should facilitate a persistent instrumentation of the
[USE Method](http://www.brendangregg.com/USEmethod/use-smartos.html) (or some
subset of it at a minimum).

* Should not limit the set of potential customer ingest solutions.

* Should allow customers to use a push or a pull model externally.

* Should not require operators to store metric data on behalf of end users.

* If possible, leverage an existing open source tool with traction.

## Note
This RFD is orthogonal to
[RFD 0017](https://github.com/joyent/rfd/blob/master/rfd/0017/README.md). While
it is likely that the two RFD will be complementary, they are distinctly
different applications/product offerings.

## Inspirational Reading
[Push vs Pull](http://www.boxever.com/push-vs-pull-for-monitoring) for metrics

## Existing Solutions
### [Prometheus](http://prometheus.io/)
>Prometheus is an open-source systems monitoring and alerting toolkit originally built at SoundCloud. Since its inception in 2012, many companies and organizations have adopted Prometheus, and the project has a very active developer and user community. It is now a standalone open source project and maintained independently of any company.

A distinguishing feature of Prometheus is that it uses a pull mechanism instead
of a push mechanism for metric delivery. This is advantageous because it helps
accomplish the goal of facilitating the delivery of metric data, but not storing
it. That said, allowing customers to have this data pushed to them is also a
goal. Adding a customer zone that acts as a Prometheus poller and pushes data to
a configurable protocol and endpoint may accommodate that requirement nicely.

Prometheus is already a supported platform for Docker and Kubernetes.
It has an open-source user base that appears to be similar in size to ours, and
many large companies are already using it for this purpose. Additionally,
support for service discovery via [Consul](https://www.consul.io/) and DNS is
available to alleviate manual configuration. This means operators and end users
can leverage our own CNS or Consul.

### [InfluxDB](https://influxdata.com/)
>InfluxData provides a robust, open source and fully customizable time-series data management platform backed by 24/7 enterprise support. InfluxData has helped hundreds of startups and multi-national corporations solve complex data challenges.

InfluxDB has a really nice SQL like CLI, and data points are formed much like
they are with Prometheus. Unfortunately InfluxDB requires that we store customer
data because it is a push mechanism. This could be minimized by adding smarts to
whatever agent does the pushing (e.g. only push metrics for customers that have
this feature turned on), but ultimately we would still need to cache the data
for some point in time. Push mechanisms introduce back pressure problems and
complexity that doesn't seem to be desirable.

### [Graylog](https://www.graylog.org/)
Has a very nice dashboard and is extremely configurable. Unfortunately it's
based on a push model using Syslog and/or GELF. In addition, Graylog has _lots_
of moving parts (e.g. MongoDB, ElasticSearch, Java, etc.) which make it
undesirable from an operational perspective.

### [ELK](https://www.elastic.co/products)
>By combining the massively popular Elasticsearch, Logstash and Kibana, Elasticsearch Inc has created an end-to-end stack that delivers actionable insights in real time from almost any type of structured and unstructured data source. Built and supported by the engineers behind each of these open source products, the Elasticsearch ELK stack makes searching and analyzing data easier than ever before.

A popular combination of tools in the open-source arena. Unfortunately, ELK
requires a push mechanism _and_ storing data. That said, Logstash may warrant
more consideration as it applies to the metric proxy or metric translator
components.

### [Juttle](http://juttle.github.io/juttle/)
>Juttle is an analytics system and language for developers built upon a stream-processing core and targeted for presentation-layer scale. Juttle gives you an agile way to query, analyze, and visualize live and historical data from many different big data backends or other web services. Using the Juttle dataflow language, you can specify your presentation analytics in a single place with a syntax modeled after the classic unix shell pipeline. There is no need to program against data query and visualization libraries. Juttle scripts, or juttles, tie everything together and abstract away the details.

Juttle is more of a language or stream-processing system than an end to end
solution or protocol. It has many similarities to our own Manta, and a powerful
syntax. Unfortunately Juttle doesn't seem mature enough, or complete enough to
be considered.

### [StatsD](https://github.com/etsy/statsd/wiki)
>StatsD is a simple NodeJS daemon (and by “simple” I really mean simple — NodeJS makes event-based systems like this ridiculously easy to write) that listens for messages on a UDP port. (See Flickr’s “Counting & Timing” for a previous description and implementation of this idea, and check out the open-sourced code on github to see our version.) It parses the messages, extracts metrics data, and periodically flushes the data to graphite.

StatsD is popular, simple, and based on NodeJS. Its main drawback is a push
model that would require us storing or caching data for some period of time.

### [cAdvisor](https://github.com/google/cadvisor)
>cAdvisor (Container Advisor) provides container users an understanding of the resource usage and performance characteristics of their running containers. It is a running daemon that collects, aggregates, processes, and exports information about running containers. Specifically, for each container it keeps resource isolation parameters, historical resource usage, histograms of complete historical resource usage and network statistics. This data is exported by container and machine-wide.

This is the de facto docker monitoring daemon, and it also has Prometheus
support built in. If cAdvisor could be baked into our Docker implementation
easily, it would compliment a Prometheus based solution quite well.

### [OpenTSDB](http://opentsdb.net/)
>OpenTSDB consists of a Time Series Daemon (TSD) as well as set of command line utilities. Interaction with OpenTSDB is primarily achieved by running one or more of the TSDs. Each TSD is independent. There is no master, no shared state so you can run as many TSDs as required to handle any load you throw at it. Each TSD uses the open source database HBase to store and retrieve time-series data.

A very powerful time series database which supports a pull mechanism. However,
given it's complexity (e.g. HBase Hadoop requirement), it seems unlikely that we
can reach a wide audience by standardizing on this.

## Chosen Solution
Expose metrics in a way that is *compatible* with Prometheus, but not include a
Prometheus server or any of their code.

Prometheus facilitates each of the goals listed above, has a great amount of
open-source traction, and provides an end-to-end solution. That said, it does
contain a few technologies and moving pieces that are undesirable
(e.g. its storage engine and front end). So rather than implanting Prometheus
into our platform, we should become Prometheus compatible. What this means is
that we will support the Prometheus protocol and semantics, but implement the
components of the solution ourselves.

## Components
### Metric Agent
Runs in the global zone on the head node and compute nodes. It provides a
Prometheus compatible HTTP endpoint for the Metric Proxy to make requests of.
The agent does not buffer or retain any data, it responds to requests for
metrics with the data available at the time of request. Static pre-defined
metrics will be collected using modules like
[node-kstat](https://github.com/bcantrill/node-kstat), etc. A similar module
will likely need to be written for prstat type collection.

The reasoning behind running in the global zone is that metrics are necessary in
scenarios where an in-zone agent may become unresponsive (e.g. CPU caps exceeded
, DRAM exceeded, etc.).

While this is likely the most correct location, it is not without drawbacks. If
the agent lived in-zone the failure domain has more breadth
(i.e. the failure of one Metric agent only impacts a single zone), and its
resource utilization could be easily controlled by existing functionality. With
the Metric agent living in the global zone, a crash will result in all zones on
that CN lacking data until it comes back up. It is also easier for the agent to
become a noisy neighbor.

### Metric Proxy
The Metric Proxy presents a data-center/availability zone as a single Prometheus
endpoint, much the same way that the sdc-docker API works.

This is an operator controlled zone, deployed with sdcadm. The zone will need to
have a leg on the admin network in order to talk with the Metric Agent, and a
leg on the external network to expose it to customers. However it does consume
additional resources on any node that it is provisioned on, so it should keep an
accounting of customer usage.

Metric Proxy is per data-center resource for all customers, not a per-customer
deployment.

For customers that can use Prometheus data directly or via a
[plugin](https://github.com/prometheus/nagios_plugins), this and the Metric
Agent are the only components that need to be in place.

Metric Proxy pollers will need to be authenticated and authorized. The proxy
support the same TLS based scheme as the official Prometheus endpoints. The
maximum set of results returned will be all non-destroyed instances that pertain
to the given user. However, end users should be able to blacklist instances and
metrics that should not be returned (this will be configured via Cloud API).

Authentication and authorization will also be leveraged to decide how frequently
an end user is allowed to poll the Metric Proxy. By default end users will be
able to poll every five minutes. In a public cloud deployment, operators may
choose to charge for more frequent polling intervals. Users who attempt to poll
more frequently than their defined interval will receive a
[HTTP 429](https://tools.ietf.org/html/rfc6585#page-3) response.

### Cloud API
End users will leverage CloudAPI to enable Container Monitor for their account,
manage their monitoring black list, and configure their polling frequency
allowance. Triton CLI and Admin UI can also use CloudAPI to manage settings and
provide alternate Container Monitor configuration endpoints.

### Metric Forwarder (optional)
For customers that need to have data pushed to them, and can't use an existing
Prometheus plugin, a Metric Forwarder zone can be deployed. This zone will poll
a configurable set of Metric Proxy endpoints for data, translate it to the
desired metric format (e.g. [InfluxDB](https://influxdata.com/), Syslog, etc.),
and push the translated data to the customers existing system.

This is provisioned by the customer, but some configuration will be necessary to
dictate which type of translation should be done. It's likely a configuration
file will suffice for version 1 along side a pre-defined SmartOS or LX package
with the necessary pieces pre-installed.

The minimum viable set of translations are Syslog, statsd, and InfluxDB.

## Architecture Overview
![Container Monitor Layout](http://us-east.manta.joyent.com/shmeeny/public/container_monitor.png)

## High Availability
### Metric Agent
This is a single agent on a compute or head node, it has no more availability
than the other supporting agents like cn-agent and vm-agent. Additional agents
would only be helpful in the case of an agent crash, and not node failure. At
this time it does not make sense to provide guarantees beyond SMF restarts.

### Metric Proxy
This is an entirely stateless service and because of that there is no limit to
the number of proxies that can be in use at a given time. The proxy can be
scaled in much the same way that we scale multiple manatee zones across head and
compute nodes.

### Metric Forwarder
Because the metric forwarder is an outbound stream/push mechanism, multiple
translators cannot push data to the same customer endpoint without duplication.
Because of this limitation, the translator must only operate in an
active/passive configuration.

## Scaling
### Metric Agent
Because the Metric Agent is a single agent running on a compute or head node,
there is no good way of scaling it. That said, it does need to be sensitive to
overloading the global zone. If the Metric Agent finds itself in an overloaded
state it should sacrifice itself in order to maintain the performance of the
node it is on.

### Metric Proxy
Multiple Metric Proxy zones should be added to Triton CNS so that requests can
be balanced across multiple instances and new Metric Proxy zones can be added
and removed without needing to reconfigure pollers/end users.

An additional scaling option would be to affine pollers to different Triton
CNS groupings of Metric Proxy (e.g. UID 0 - 1000 get one HA group, and 1001 -
2000 get another HA group, etc.).

### Metric Forwarder
The Metric Forwarder should support an instance/container whitelist so that
end users can scale active/passive pairs horizontally. For example one pairing
could have containers 0 - 100, another pairing with 101 - 200, and so on. This
maintains a single writer per container, but allows for scale out.

## Dynamic metrics (e.g. on-demand DTrace integration)
Dynamic metrics are already somewhat supported by CAv1, and are out of scope for
version one of Container Metrics.

## Triton CLI integration
The Triton CLI should be able to act as a Prometheus polling server. This will
act both as a debugging tool and a convenient ad-hoc stats gathering mechanism
for end users.

## Default Metric Collection
* kstat -p caps::cpucaps_zone*
* kstat -p memory_cap:::
* kstat -p | grep ifspeed
* kstat -p <nic kind>::*
* prstat -mLc
* df -h
* iostat -xnz
* iostat -En

## Prometheus Compatible [Response Definition](https://prometheus.io/docs/instrumenting/exposition_formats/#exposition-formats)
### Example text based response
```
# HELP api_http_request_count The total number of HTTP requests.
# TYPE api_http_request_count counter
http_request_count{method="post",code="200"} 1027 1395066363000
http_request_count{method="post",code="400"}    3 1395066363000

# Escaping in label values:
msdos_file_access_time_ms{path="C:\\DIR\\FILE.TXT",error="Cannot find file:\n\"FILE.TXT\""} 1.234e3

# Minimalistic line:
metric_without_timestamp_and_labels 12.47

# A weird metric from before the epoch:
something_weird{problem="division by zero"} +Inf -3982045

# A histogram, which has a pretty complex representation in the text format:
# HELP http_request_duration_seconds A histogram of the request duration.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.05"} 24054
http_request_duration_seconds_bucket{le="0.1"} 33444
http_request_duration_seconds_bucket{le="0.2"} 100392
http_request_duration_seconds_bucket{le="0.5"} 129389
http_request_duration_seconds_bucket{le="1"} 133988
http_request_duration_seconds_bucket{le="+Inf"} 144320
http_request_duration_seconds_sum 53423
http_request_duration_seconds_count 144320

# Finally a summary, which has a complex representation, too:
# HELP telemetry_requests_metrics_latency_microseconds A summary of the response latency.
# TYPE telemetry_requests_metrics_latency_microseconds summary
telemetry_requests_metrics_latency_microseconds{quantile="0.01"} 3102
telemetry_requests_metrics_latency_microseconds{quantile="0.05"} 3272
telemetry_requests_metrics_latency_microseconds{quantile="0.5"} 4773
telemetry_requests_metrics_latency_microseconds{quantile="0.9"} 9001
telemetry_requests_metrics_latency_microseconds{quantile="0.99"} 76656
telemetry_requests_metrics_latency_microseconds_sum 1.7560473e+07
telemetry_requests_metrics_latency_microseconds_count 2693
```
