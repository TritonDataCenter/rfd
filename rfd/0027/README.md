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

## Use Case Examples
### End user
* Real time alarms for resource utilization (disk capacity, CPU, DRAM, etc.).
* Monitor the impact of app utilization and throughput on container utilization.
* Correlate resource metrics with application metrics.
### Operators
* ZFS zpool health (metrics and alerts)
* Compute node utilization (metrics and alerts)

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

A powerful time series database which supports a pull mechanism. However, given
it's complexity (e.g. HBase Hadoop requirement), it seems unlikely that we can
reach a wide audience by standardizing on this.

## Chosen Solution
Expose metrics in a way that is compatible with the Prometheus
[text format HTTP client](http://prometheus.io/docs/instrumenting/exposition_formats/#format-version-0-0-4)
specification. This is distinctly different from the Prometheus HTTP API and
server components, which will not be implemented.

Furthermore, a blueprint and/or Docker image for forwarding metrics to
pre-existing customer solutions should be created so that customers do not have
to feel locked into the Prometheus model or be forced to switch.

Prometheus facilitates each of the goals listed above, has a great amount of
open-source traction, and provides an end-to-end solution. Users can easily spin
up a new Prometheus server in minutes and start polling new metrics. Thanks to
the optional metric forwarding, users with existing time-series stores can also
get up to speed quickly.

## Components
### Metric Agent
Runs in the global zone on the head node and compute nodes. It provides a
Prometheus compatible HTTP endpoint for the Metric Proxy to make requests of.

------

###### Option 1 (No buffer)
The client does not buffer or retain any data, it responds to requests for
metrics with the data available at the time of request.

###### Option 2 (Selective caching)
The client caches expensive calls and allows for a configurable expiration. In
this scenario metrics would always be retrievable, but some metrics would remain
the same for the duration of the cached value. The expensive calls would only be
made if a cached value does not exist or the currently cached value has expired.

###### Option 3 (Self populated caching)
The client caches all metrics and allows for a configurable per metric
expiration. Metric Agent Proxy requests do not result in metric collection,
instead metrics are automatically collected by the client on a timer.

------

Regardless which of the above options are chosen, the Metric Agent should support
an operator configurable global minimum polling frequency. This will allow an
operator to dial back metric collection on an overloaded compute node and
potentially avoid stopping the Metric Agent.

Static pre-defined metrics will be collected using modules like
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

### Metric Agent Proxy
The Metric Agent Proxy lives between a customers Prometheus server and the
Metric Agents that live on each compute node.

Though the Metric Agent is a highly available cluster per data center, it will
have a DNS A record per monitored customer container assigned to it so that it
can respond as if it was the monitored instance itself. In addition to the DNS A
records, one or more DNS SRV records will be created to allow a customers
Prometheus server to automatically discover containers that should be polled.

This is an operator controlled zone, deployed with sdcadm. The zone will need to
have a leg on the admin network in order to talk with the Metric Agent, and a
leg on the external network to expose it to customers. However it does consume
additional resources on any node that it is provisioned on, so it should keep an
accounting of customer usage.

For customers that can use Prometheus data directly or via a
[plugin](https://github.com/prometheus/nagios_plugins), this and the Metric
Client are the only components that need to be in place.

Customers polling servers will need to be authenticated and authorized. The
proxy will utilize the same TLS based scheme as the official Prometheus
endpoints. Customers existing SSH key(s) (the same key(s) used for accessing
instances and sdc-docker) will be used. Optionally a customer may choose to
restrict polling of their instances to specific IPs or subnets.

Authentication and authorization will also be leveraged to decide how many
polling requests an end user is allowed to make to the Metric Agent Proxy
within a configurable amount of time.

-----

###### Option 1 (Configurable per user request quota, global per user maximum)

User request quota will default to an operator set value, and an optional per
user maximum can also be set by an operator.

For example, a per user default could be 1000 requests per minute, and a global
per user maximum could be 10000 requests per minute. Operators can choose
whether or not to throttle users that go beyond 1000 requests per minute or
charge them. That said, users are not allowed to violate the global per user
maximum request quota if it is set.

###### Option 2 (Package based request quota, global per user maximum)

Each deployable package will be configured with a request quota. Each users
request quota will be the sum total of their deployed packages quota. An
operator can optionally configure a global per user maximum quota.

For example, a user may have three containers deployed:

1. 10 request per minute quota
2. 100 request per minute quota
3. 20 request per minute quota

In this scenario the users request quota would be 130 requests per minute. An
operator can choose to throttle users at their request quota, or set a per user
global maximum limit. An operator may choose to bill for requests that exceed
the users request quota up until they hit the global maximum. When the
global maximum is hit, users will be throttled.

-----

If configured, users who poll beyond their allotment or global maximum will
receive a [HTTP 429](https://tools.ietf.org/html/rfc6585#page-3) response.

### Discovery

When existing accounts are backfilled and when new accounts are created, CNS
will detect the change and create the following DNS records

```
    <vm_uuid>.cm.triton.zone A <ip of metric agent proxy>
```
```
    _cm._tcp.<useruuid>.triton.zone <ttl> IN SRV <priority> <weight> 3000 <vm_uuid>.cm.triton.zone
```

for each of the accounts containers. Going forward all new containers will get a
Container Monitor A record and an SRV record automatically. This allows
Prometheus built-in DNS discovery to automatically find and collect metrics from
all of a users containers.

If a user does not wish to use DNS SRV record discovery, they may list their
containers via CloudAPI which will include the Container Monitor A record for
each container as a part of the payload.

## Architecture Overview
![Container Monitor Layout](http://us-east.manta.joyent.com/shmeeny/public/container_monitor.png)

## Happy Path Walk Through

### Container Creation
* User creates a new container
* VMAPI pushes a changefeed event to CNS
* CNS creates an A record of the form
  ```
    <vm_uuid>.cm.triton.zone A <ip of metric agent proxy>
  ```
  for each Metric Agent Proxy IP and a new SRV record of the form
  ```
    _cm._tcp.<useruuid>.triton.zone <ttl> IN SRV <priority> <weight> 3000 <vm_uuid>.cm.triton.zone
  ```

### End User Configuration
* Install and run a Prometheus server
    * Create prometheus.yml [configuration](https://prometheus.io/docs/operating/configuration/)
        * TLS is configuration is required, use the same cert and key that you
          configured for use with CloudAPI, sdc-docker, etc.
        * Add a job for the availability zones that your containers run in, using
          DNS SRV discovery.
          ```
          - job_name: triton_jpc_east1

            tls_config:
                cert_file: valid_cert_file
                key_file: valid_key_file

                bearer_token: avalidtoken
                scrape_interval: 30s
                scrape_timeout:  10s

            dns_sd_configs:
                names:
                    - _cm._tcp.<useruuid>.triton.zone
                # refresh_interval defaults to 30s.

            labels:
                triton_jpc: triton_jpc

            scheme: https
          ```
    * User creates a Dockerfile using their specific prometheus.yml
      ```
        FROM prom/prometheus
        ADD prometheus.yml /etc/prometheus/
      ```
    * Build a new docker image
      ```
        docker build -t my-prometheus .
      ```
    * Run the Prometheus server
      ```
        docker run -p 9090:9090 my-prometheus
      ```
    * Prometheus server polls `_cm._tcp.<useruuid>.triton.zone` to discover
      end points to collect from
    * Prometheus server polls discovered endpoints every thirty seconds, such as
     ```
     https://fbb8e583-9c87-4724-ac35-7cefb46c0f7b.cm.triton.zone/metrics
     ```
    * Metric Agent Proxy validates the end users key and cert file
    * Metric Agent Proxy determines which compute node the container is on and
      makes an HTTP call to its Metric Agent

      ```
        GET fbb8e583-9c87-4724-ac35-7cefb46c0f7b.cm.triton.zone/metrics
        ---
        # HELP cpucaps_usage_percent current CPU utilization
        # TYPE cpucaps_usage_percent gauge
        cpucaps_usage 0
        # HELP cpucaps_below_seconds time spent below CPU cap in seconds
        # TYPE cpucaps_below_seconds gauge
        cpucaps_below 16208
        # HELP cpucaps_above_seconds time spent above CPU cap in seconds
        # TYPE cpucaps_above_seconds gauge
        cpucaps_above 0
        # HELP memcaps_rss_bytes memory usage in bytes
        # TYPE memcaps_rss_bytes gauge
        memcaps_rss 491872256
        # HELP memcaps_swap_bytes swap usage in bytes
        # TYPE memcaps_swap_bytes gauge
        memcaps_swap 577830912
        # HELP memcaps_anonpgin anonymous pages from swap device
        # TYPE memcaps_anonpgin gauge
        memcaps_anonpgin 11019
        # HELP memcaps_anon_alloc_fail memory allocation failures
        # TYPE memcaps_anon_alloc_fail gauge
        memcaps_allocfail 0
        ...
      ```
    * Metric Agent Proxy proxies the Metric Agent response back to the calling
      Prometheus server.
    * Container Monitor data is now available in the users Prometheus endpoint

### Container Destroyed
* User destroys a container
* VMAPI pushes a changefeed event to CNS
* CNS removes the A records and SRV record associated with the container

## High Availability
### Metric Agent
This is a single agent on a compute or head node, it has no more availability
than the other supporting agents like cn-agent and vm-agent. Additional agents
would only be helpful in the case of an agent crash, and not node failure. At
this time it does not make sense to provide guarantees beyond SMF restarts.

### Metric Agent Proxy
This is an entirely stateless service and because of that there is no limit to
the number of proxies that can be in use at a given time. The proxy can be
deployed with sdcadm to multiple nodes in a given data center. The recommended
deployment is three Metric Agent Proxies, one on the headnode and the other two
on different compute nodes which are ideally in different racks.

When multiple Metric Agent Proxies are in use, CNS and round robin DNS
(e.g. multiple A records per <container uuid>.cm.triton.zone) will be leveraged.
To ensure minimum disruption in the case of a Metric Agent Proxy failure, a low
TTL should be used.

## Scaling
### Metric Agent
Because the Metric Agent is a single agent running on a compute or head node,
there is no good way of scaling it. That said, it does need to be sensitive to
overloading the global zone. If the Metric Agent finds itself in an overloaded
state it should sacrifice itself in order to maintain the performance of the
node it is on.

### Metric Proxy
Multiple Metric Proxy zones can be added as load requires and without penalty.
When new Metric Proxies are added, CNS will detect this and add new A records.

## Dynamic metrics (e.g. on-demand DTrace integration)
Dynamic metrics are already somewhat supported by CAv1, and are out of scope for
version one of Container Monitor. The intent is to add support for dynamic
metrics in a future version.

## Triton CLI integration
The Triton CLI should be able to act as a Prometheus polling server. This will
act both as a debugging tool and a convenient ad-hoc stats gathering mechanism
for end users.

* Examples provided as a loose example of what could be done. This is not
  intended to be prescriptive at this time.

```
    # default raw response
    $ triton monitor <container uuid or name>
    ...
    cpucaps_usage 0
    cpucaps_below 16208
    cpucaps_value 100
    ...
```

```
    # Formatted response listing vm caps data
    $ triton monitor <container uuid or name> --caps
        VM_UUID                                 value    usage    maxusage
        fbb8e583-9c87-4724-ac35-7cefb46c0f7b    100      0        87
        ...
```
## Default Metric Collection
* kstat caps::cpucaps_zone*
  * usage
  * value
  * above_sec
* kstat memory_cap:::
  * rss
  * physcap
  * swap
  * swapcap
  * anonpgin
  * anon_alloc_fail
* zfs list
  * used
  * available
* prstat -mLc equivalent
  * PID
  * USERNAME
  * USR
  * SYS
  * TRP
  * TFL
  * DFL
  * LCK
  * SLP
  * LAT
  * VCX
  * ICX
  * SCL
  * SIG
  * PROCESS/LWPI
* ulimit -a
* pfiles PID

## [Prometheus Response Definition](https://prometheus.io/docs/instrumenting/exposition_formats/#exposition-formats)

## [Example agent code](https://github.com/joyent/sdc-cn-agent/blob/rfd27/lib/monitor-agent.js)

## Metric Forwarder
For customers that need to have data pushed to them, and can't use an existing
Prometheus plugin, a Metric Forwarder zone can be deployed. This zone will poll
a configurable set of Metric Proxy endpoints for data (just like a Prometheus
server), translate it to the desired metric format
(e.g. [InfluxDB](https://influxdata.com/), Syslog, etc.), and push the
translated data to the customers existing system.

This is provisioned by the customer and not in the scope of this RFD. That said,
in the near future Joyent will create a few blueprints to help customers get
started. The blueprints may be for Syslog, statsd, InfluxDB, etc.
