----
authors: Richard Kiene <richard.kiene@joyent.com>
state: draft
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

## The Case For A Pull Based Architecture

While the inspirational reading link above provides a broad description of when
push or pull based metrics may be appropriate, an explanation of why pull based
metrics are best in this scenario seems called for.

Because Container Monitor is being built to provide data to external customer
systems with a broad set of requirements (e.g. data staleness, format, delivery,
etc.), pushing data to these systems could introduce needless complexity.

Consider the following scenario: Customer A has 10,000 containers and requires
that data be no older than 5 minutes. Customer B has 1000 containers and
requires data be no older than 15 seconds. If we assume equal payload per packet
customer B requires twice the bandwidth of customer A, with an order of
magnitude less containers. From a bandwidth perspective, push and pull are not
different.

Now consider the same scenario with an eye toward delivery. In a push model our
infrastructure will be constantly pushing every 15 seconds to customer B and
every 5 minutes to customer A. If either customer's endpoint goes down or
becomes unreachable (network partition), our infrastructure lacks a good way to
know if it should continue pushing data to customers. Intelligence, buffering,
and backoff could be added to the push agent, but that means that each metric
agent on each compute node must juggle tens if not hundreds of different
customer endpoints and their respective backoff and buffering state per compute
node, in addition to remembering the push interval for each customer.

Apply that same problem to a pull based model and each metric agent responds
on-demand when a customers endpoint polls on a given interval. The only
intelligence required is the allowable polling rate per customer. The metric
agent does not care if the customers endpoint is up or down and only sends data
when it will actually be processed. If a customer tries to pull more frequently
than allowed, the metric agent can respond appropriately, but more realistically
this will be handled by the metric proxy as to not put unnecessary load on
compute nodes.

This isn't intended to be an exhaustive list of scenarios, but I do think it
demonstrates the thought process behind choosing a pull based architecture. It
isn't that this can't be done with a push based model, it's that a push based
model makes the design more complicated than necessary, especially when you take
into consideration that the end users collection point may not be under the
control of the operator of the cloud.


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
they are with Prometheus. Unfortunately InfluxDB uses a push mechanism

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
syntax. Juttle is currently pivoting it's strategy, and it is not clear how it
would easily fit into our infrastructure.

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
[node-kstat](https://github.com/bcantrill/node-kstat). Additionally, it seems
likely that we can leverage the proc(4) backend instrumenter in CAv1 to provide
prstat type collection.

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

If not guarded against, a DDoS attack could be structured such that all compute
nodes are kept busy trying to respond to polling requests and crippling the
performance of running containers across the fleet. That is why it is critical
that the Metric Proxy be the first line of defense for the Metric Agents
(e.g. not allowing customers to go beyond their pre-configured polling frequency
and proxying authenticated polling requests to only the compute nodes
necessary).

### Cloud API
End users will leverage CloudAPI to enable Container Monitor for their account,
manage which containers are monitored by adding and removing tags, and configure
their polling frequency allowance. Triton CLI will also use CloudAPI to manage
settings and provide alternate Container Monitor configuration endpoints.
Admin UI will talk directly with VMAPI and UFDS for enabling Container Monitor
on an account and adding the container monitor tag to containers.

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

## Happy Path Walk Through

### Configuration
* Configure account for use with Container Monitor via Portal, AdminUI, or
  the Triton CLI
    * Enable Container Monitor
    * Choose your allowed polling interval
    * Upload your container monitor TLS configuration via Portal or AdminUI
    * Tag instances that should not be monitored with `triton_cm_collect=false`
        _by default all of your instances will be collected_

* [Configure](https://prometheus.io/docs/operating/configuration/) your
  Prometheus server
    * Use the same TLS cert and key you provided in the previous steps
    * Add a job for the availability zones that your containers run in, using
      the polling interval configured in the previous step.
      ```
      - job_name: triton_jpc_east1

        tls_config:
            cert_file: valid_cert_file
            key_file: valid_key_file

            bearer_token: avalidtoken
            scrape_interval: 60s
            scrape_timeout:  10s

        target_groups:    
        - targets: ['<useruuid>.east1-cm.triton.zone']
          labels:
            triton_jpc: east1

        scheme: https
      ```

### Flow
* Prometheus server makes HTTPS requests to the configured Metric Proxy
    _The configured metric proxy will actually be multiple Metric Proxies in the
    same availability zone, presented as a single DNS record by Triton CNS._
* The Metric Proxy authenticates and authorizes the request based on the TLS
  information provided and the UUID provided in the hostname
* The Metric Proxy queries only the necessary metric agents for current metrics
  and a special header value is passed along so that only the metrics for
  containers pertaining to this request are scraped.
  ```
  x-container-metric-uuids:uuid1,uuid2,uuid3,uuid4,...
  ```
* Each Metric Agent returns a Prometheus compatible HTTP response to the Metric
  Proxy.
* The Metric Proxy combines all Metric Agent responses into a single response
  and returns it to the customers Prometheus server.

## High Availability
### Metric Agent
This is a single agent on a compute or head node, it has no more availability
than the other supporting agents like cn-agent and vm-agent. Additional agents
would only be helpful in the case of an agent crash, and not node failure. At
this time it does not make sense to provide guarantees beyond SMF restarts.

### Metric Proxy
This is an entirely stateless service and because of that there is no limit to
the number of proxies that can be in use at a given time. The proxy can be
deployed in much the same way that we deploy multiple manatee zones across head
and compute nodes. The major difference here is that the Metric Proxy will be
stateless and active/active unlike Manatee. Triton CNS can be used to present
multiple Metric Proxies to end users.

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

* Examples provided as a loose example of what could be done. This is not
  intended to be prescriptive at this time.
```
# default raw response
$ triton monitor <useruuid>.east1-cm.triton.zone
...
http_request_duration_seconds_bucket{le="0.05"} 24054
http_request_duration_seconds_bucket{le="0.1"} 33444
http_request_duration_seconds_bucket{le="0.2"} 100392
http_request_duration_seconds_bucket{le="0.5"} 129389
...
```

```
# Formatted response listing vm caps data
$ triton monitor <useruuid>.east1-cm.triton.zone --caps
    VM_UUID                                 value    usage    maxusage
    fbb8e583-9c87-4724-ac35-7cefb46c0f7b    100      0        87
    ...
```
## Default Metric Collection
* kstat -p caps::cpucaps_zone*
* kstat -p memory_cap:::
* kstat -p | grep ifspeed
* kstat -p <nic kind>::*
* prstat -mLc
* df -h

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
