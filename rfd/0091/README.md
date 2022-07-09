---
authors: Richard Kiene <richard.kiene@joyent.com>,
         Kody Kantor <kody.kantor@joyent.com>,
         Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->


# RFD 91 Application Metrics in SDC and Manta

## Intro
Having at-a-glance insight into how our deployed applications are performing is
valuable for identifying problems and the extent that problems are affecting
users.

In this document we'll discuss patterns we can use in applications to expose application-level metrics.

Some points that this document will cover:
* Tools Available
* Application Pattern
* Potential Problems
  * Metric cardinality
* Architecture Overview
  * Discovery
  * Overview of how this fits in to the higher-level monitoring stack
* Using aggregated metrics + dtrace to help identify problems

## Tools Available
These are some of the tools that are useful when adding metrics to a
applications:
* [node-artedi](https://github.com/TritonDataCenter/node-artedi)
  * We made node-artedi to make instrumenting our node services easier. It acts
  in a way similar to Bunyan, where 'child' metric collectors can be created
  from a 'parent' collector. It's easy to pass artedi collector into libraries,
  if a library is a target of your metric collection. See joyent/node-fast#9 for
  more information on instrumenting libraries, and MANTA-3258 for instrumenting
  a daemon.
  * artedi was designed so that it can be agnostic of the tools used to do
  metric reporting and dashboarding.

* [prometheus](https://prometheus.io/)
  * Prometheus is the metric format that node-artedi initially exposes. It's
  easy to set up a Prometheus server inside an LX zone. There is also an illumos
  build of Prometheus floating around. The Prometheus server includes a
  dashboard that's useful for one-off graphs and queries, which makes it great
  for development.

Additionally, [CMON](https://github.com/TritonDataCenter/triton-cmon/),
[RFD 27](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0027/README.md), and
[RFD 99](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0099/README.md) are good
resources for learning more about metrics at Joyent.

## Application Pattern
Patterns that an application can follow looks like this:
* Use node-artedi (or another language's equivelant) to collect metrics
  * Metrics are named generically when possible, and specifically when
    appropriate     
    * For example, a generic metric could be 'http_requests_completed' while a
      specific metric is 'postgres_replication_lag'
    * 'Generic' names are names that could conceivably be part of multiple
      components
  * Metric names should include a unit, if necessary
    (e.g. 'http_request_latency_ms')
* Metrics are scrape-able over a REST endpoint on the '/metrics' route
  * A few components include a Kang server, which can perform double duty also
    acting as the metric server
* The metric REST endpoint should be accessible on the 'admin' network
* Metrics are serialized in Prometheus format

## Potential Problems
### Metric Cardinality
Metric cardinality is a problem that comes about when too many time series are
tracked at either the client or the server. Each unique 'label' or metadata
value attached to a metric causes a new 'metric' and the client and a new 'time
series' on the server. The more metadata key-value pairs, the bigger the more
data that has to be kept track of in memory and on disk. The easiest way to
prevent this problem is to _not_ track metadata keys with a large range of
values. To put it concretely, adding metadata labels for object name, object
owner name, or requestor name would be perilous, since those all have a very
high number of possible metadata values (at least in JPC).

## Architecture Overview
### Discovery

One of the problems that comes about when we have so many services exposing
metrics is how we discover where the metric HTTP endpoints are, and how to
access them. Many Manta instances run many (up to 16) Node.js processes in a
zone, each exposing metrics on a different port number. It would be helpful to
have a system in place to track where to access each process exposing metrics.

We've thought of a couple options for providing discovery to applications. The
first is to use CMON, which already has an API for discovering Prometheus-format
metric endpoints.

CMON already provides a form of discovery, so we can extend that to allow
application to self-identify their metric collection endpoints. Our initial
thought is that we can add an application discovery interface, and read new tags
from VMs that describe how the application within can be scraped.

An application discovery interface would have an API that looks similar to SAPI:
```

// SAPI has two 'applications' in a Manta deployment: 'manta' and 'sdc'.
// SAPI has a 'service' for each Manta service.
// SAPI has an 'instance' for each instantiation of a Manta service.

// Existing CMON API for listing containers, could be expanded to have an
// 'applications' array.
GET https://cmon.<az>.triton.zone:9163/v1/discover
---
{
    "containers":[
        {
            "server_uuid":"44454c4c-5000-104d-8037-b7c04f5a5131",
            "source":"Bootstrapper",
            "vm_alias":"container01",
            "vm_image_uuid":"7b27a514-89d7-11e6-bee6-3f96f367bee7",
            "vm_owner_uuid":"466a7507-1e4f-4792-a5ed-af2e2101c553",
            "vm_uuid":"ad466fbf-46a2-4027-9b64-8d3cdb7e9072",
            "cached_date":1484956672585
        },
        {
            "server_uuid":"44454c4c-5000-104d-8037-b7c04f5a5131",
            "source":"Bootstrapper",
            "vm_alias":"container02",
            "vm_image_uuid":"7b27a514-89d7-11e6-bee6-3f96f367bee7",
            "vm_owner_uuid":"466a7507-1e4f-4792-a5ed-af2e2101c553",
            "vm_uuid":"a5894692-bd32-4ca1-908a-e2dda3c3a5e6",
            "cached_date":1484956672672
        }
    ],
    "applications": [
        {
            "application_name": "manta",
            "application_uuid": "cec008ba-a93e-11e7-abe8-2f563cea6db8"
        },
        {
            "application_name": "sdc",
            "application_uuid": "3f70efe4-a93e-11e7-b103-230269950b8d"
        }
    ]
}

// Lists the services in the manta application (webapi, moray, manatee, etc.).
GET /v1/discover?application=manta
---
{
    "services": [
        {
            "service_name": "webapi",
            "service_uuid": "c0db6bb8-a93e-11e7-91ee-e3d8afbb636a",
            "instance_count": 3,
            "metric_nic_tags": ['admin', 'manta'],
            "metric_ports": [8881, 8882, 8883, 8884],
            "metric_path": "/metrics"
        }
    ]
}

// It may be useful to also have service and instance information. Maybe some
// of the above information would be present in these levels instead.
// Lists the instances in the 'webapi' service.
GET /v1/discover?service=manta-webapi

// Lists the instance-specific metric information (if any... I'm not sure
// that this is useful).
GET /v1/discover?instance=webapi-e5d0b3

```

This API looks a lot like the Services API (SAPI). Each service could report
things like metric HTTP path, port, and network that metrics are available on.
These could conceivably be tunables, but they aren't at this point (though maybe
they should be). If they were tunable, this would get more complicated, since
CMON would need something like a changefeed from SAPI to get updates.

There are a few ways we could get the required data (ports, networks, etc) into
CMON for discovery.

The first option is to add tags to the VM. Those tags might look something like
this:
```
metric_ports=[8881, 8882, 8883, 8884]
metric_nic_tags=['admin', 'manta']
```

CMON is currently set up to get most of its information about VMs from VMAPI
changefeed events, so this fits right in with the existing workflow.

The second option is to have the application notify CMON of its configuration
via a REST request. I don't believe this is possible with the current CMON
setup. The application would have to deal with a bunch of CMON failure cases
(unavailable, not routable, etc.), and would complicate the startup procedure.

The third option is for CMON to get the information from SAPI. This seems like
it would be a good option, but SAPI doesn't have support for changefeed events
like VMAPI does. I'm not sure if it is worth implementing a changefeed for SAPI,
though it may allow an alternative implementation of the config-agent in
addition to solving this problem.

### How Application Metrics Fit In
To be written once we figure out what our monitoring solution supports.
