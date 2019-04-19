---
authors: Trent Mick <trent.mick@joyent.com>, Richard Kiene <richard.kiene@joyent.com>, Isaac Davis <isaac.davis@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=RFD+150
---

# RFD 150 Operationalizing Prometheus, Thanos, and Grafana

This RFD's purpose is to define how Prometheus, Thanos, and Grafana will be
added as core Triton and Manta components.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Status (2019-02-14)](#status-2019-02-14)
- [Overview](#overview)
- [What are Prometheus, Thanos, and Grafana?](#what-are-prometheus-thanos-and-grafana)
- [Service requirements](#service-requirements)
- [Milestones](#milestones)
  - [M0: plain bash setup scripts](#m0-plain-bash-setup-scripts)
  - [M1: core prometheus0 and grafana0 Triton zones](#m1-core-prometheus0-and-grafana0-triton-zones)
  - [M2: Manta service design](#m2-manta-service-design)
  - [M3: Improve auth](#m3-improve-auth)
- [Forks](#forks)
- [Prometheus](#prometheus)
  - [Architecture](#architecture)
  - [Sharding](#sharding)
  - [HA](#ha)
  - [Networking](#networking)
  - [Current Status (2019-02-11)](#current-status-2019-02-11)
  - [Remaining Tasks (2019-02-11)](#remaining-tasks-2019-02-11)
  - [Unresolved Questions](#unresolved-questions)
- [Thanos](#thanos)
  - [Architecture](#architecture-1)
  - [Networking](#networking-1)
  - [Current Status (2019-02-13)](#current-status-2019-02-13)
  - [Unresolved Questions](#unresolved-questions-1)
- [Grafana](#grafana)
  - [Architecture](#architecture-2)
  - [Networking](#networking-2)
  - [Current Status (2019-02-14)](#current-status-2019-02-14)
  - [Remaining Tasks (2019-02-14)](#remaining-tasks-2019-02-14)
  - [Unresolved Questions](#unresolved-questions-2)
- [General Q & A (somewhat outdated)](#general-q--a-somewhat-outdated)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status (2019-02-14)

Still a draft write-up that has yet to be discussed widely.
M0 (milestone 0) exists now and prometheus0 and grafana0 zones have been
deployed to some DCs.

M1:
- MANTA-3552 - add Triton Prometheus service - in progress
- MANTA-3992 - add Triton Grafana service - in progress

M2:
- MANTA-4008 - add Manta Prometheus service - in progress

M3:
- Work has not yet started.

See "Status" subsections under each component for more detail.

See [RFD-150 labelled issues](https://jira.joyent.us/issues/?jql=labels%20%3D%20RFD-150), if any.


## Overview

Prometheus and Grafana have become an important resource for Joyent operating
its Triton and Manta deployments. They will also likely become recommended
operating practice for other users of Triton and Manta. For Joyent's and
other's usage it would be beneficial (for maintenance, consistency,
improvements) to have Prometheus and Grafana be core services deployed,
configured, and upgraded by the usual Triton and Manta operator tooling.

We will also deploy Thanos to aggregate Prometheus metrics between Prometheus
and Grafana and perform long-term storage of metrics.

## What are Prometheus, Thanos, and Grafana?

- [Prometheus](https://github.com/prometheus/prometheus) is a monitoring system
  and time-series database. It aggregates metrics exposed in a specific format
  by various sources (In our case, Triton and Manta components) and presents
  a query language and simple web interface for querying the collected data.
- [Thanos](https://github.com/improbable-eng/thanos) aggregates metrics from
  Prometheus instances. It manages the long-term retention of metrics in object
  storage, deduplicates and merges metrics from Prometheus HA pairs, and
  provides its own Prometheus-compatible interface that exposes all of the
  metrics it's aggregated from individual Prometheus instances.
- [Grafana](https://github.com/grafana/grafana) provides a full-featured web
  interface that allows users to create and save dashboards that visualize the
  results of queries against various metrics databases, including Prometheus.
  In this deployment, Thanos will serve as Grafana's data source. Joyent
  employees may be familiar with Grafana through Starfish.

## Service requirements

If we lose occasional metrics due to a Prometheus outage, it is acceptable with
our current level of maturity.

That said, I think there should be tracked SLO (service level objectives) for a
given prometheus core service. This would be measureable from Prometheus' from
separate DCs in a cloud monitoring each other.

## Milestones

TODO update milestones to include Thanos, subject to discussion.

### M0: plain bash setup scripts

Currently <https://github.com/joyent/triton-prometheus/> provides
"setup-prometheus-prod.sh" and "setup-grafana-prod.sh" scripts that will setup
"prometheus0" and "grafana0" core(ish) Triton zones (based on LX) configured
to scrape metrics for all core Triton VMs, including service-specific metrics
from many of the APIs, and with preset dashboards for some Triton services,
per <https://github.com/joyent/triton-grafana>.

If desired for expediency, these could be used to setup quick and disposable
instances in production to explore Triton service metrics.

### M1: core prometheus0 and grafana0 Triton zones

- **[DONE]** Ensure Prometheus and Grafana work sufficiently on SmartOS.
  Isaac is investigating this. E.g. see
  <https://github.com/fsnotify/fsnotify/pull/263>
- **[IN PROGRESS]** Create a Triton Prometheus image - see [MANTA-3552](https://jira.joyent.us/browse/MANTA-3552)
- **[IN PROGRESS]** Create a Triton Grafana image - see [MANTA-3992](https://jira.joyent.us/browse/MANTA-3992)
- sdcadm setup and upgrade support, being done as part of the above tickets
- UFDS-based reverse proxy auth for the grafana zone.
- No HA, no sharding

### M2: Manta service design

- **[DONE]** discovery filtering support
- **[IN PROGRESS]** Expand the Triton Prometheus image to support Manta - see [MANTA-4008](https://jira.joyent.us/browse/MANTA-4008)
- determine if Manta eng wants a core *grafana* instance
- sharding plan
- manta deployment tooling updates for the new services

### M3: Improve auth

Consider UFDS-based reverse proxy auth for the prometheus zone.

## Forks

We have current outstanding changes to some repos for illumos/SmartOS support:

- [prometheus](https://github.com/prometheus/prometheus/compare/release-2.5...joyent:joyent/2.5)
- [grafana](https://github.com/grafana/grafana/compare/v5.3.x...joyent:joyent/5.3.x)
- [fsnotify](https://github.com/fsnotify/fsnotify/compare/v1.4.7...joyent:joyent/1.4.7) - For discussion, see https://github.com/fsnotify/fsnotify/pull/263

## Prometheus

### Architecture

There will be one Prometheus image, shared between the Triton and Manta
prometheus services. The Manta Prometheus service will be sharded, in
anticipation of the high volume of metrics that will come with a
production-scale Manta deployment.

Neither Triton nor Manta will have Prometheus deployed by default; it is an
optional service. The Triton Prometheus image will be deployed using
`sdcadm post-setup prometheus`. The Manta Prometheus image will be deployed
using `manta-adm update`.

Both the Triton and Manta services will discover their scrape targets through
CMON using the `triton_sd_configs` option in the Prometheus configuration file -
the Triton service as the admin account and the Manta service as the poseidon
account. They thus depend on CMON and CNS being deployed. CMON will supply
service metrics for core Triton zones (excluding "nat" zones) and Manta zones
via the existing ["triton_core" cmon-agent collector](https://github.com/joyent/triton-cmon-agent/blob/master/lib/instrumenter/collectors-vm/triton_core.js).

CMON will require Prometheus to supply a certificate signed by the private key
of the admin or poseidon account for Triton and Manta, respectively. The
Prometheus image will contain a `certgen` script that generates this key upon
provisioning.

Prometheus must be able to resolve CNS-generated domain names. However, it is
not sufficient to put CNS resolvers in `/etc/resolv.conf`. Theoretically, there
could be an arbitrary number of CNS instances deployed in the Triton deployment,
and we'd like Prometheus to be able to use all of the CNS resolvers. However,
the native Go name resolution only looks at the first three resolvers in
`/etc/resolv.conf`. To circumvent this limitation, the Prometheus zone will run
its own BIND server listening on localhost. This will be the only entry in
`/etc/resolv.conf`. The server will replicate the CNS zone locally, and forward
all other requests to the Binder and public-internet resolvers. This will allow
name resolution using an arbitrary number of CNS resolvers.

Prometheus will store metrics for one month by default -- this will be a (SAPI)
tunable -- on a delegate dataset to preserve across reprovisions. Long term
storage of Prometheus metrics is the subject of
[separate work by Richard](https://jira.joyent.us/browse/MANTA-3881). That work
will be integrated into the Thanos image.

### Sharding

TRITON-755 provides the mechanism for sharding: the list of zones returned from
CMON's discovery endpoint can be filtered by a user-defined zone tag, and such a
tag can be specified under `triton_sd_configs` in the Prometheus configuration
file. It would make sense to have a CLI tool for automatically assigning tags
upon deploying a Prometheus fleet for the first time. This tool would have to
iterate over every Manta service zone, so running it would be expensive.

The actual _logic_ of how to divide zones into shards is up for discussion -
see the "Unresolved Questions" section below.

### HA

We can deploy pairs of Prometheii that filter using the same shard tag, thus
scraping the same set of zones. Thanos can deduplicate metrics.

### Networking

- Prometheus needs to be on the external to properly work with CMON Triton
  service discovery and CNS -- at least until CNS support split horizon
  DNS to provide separate records on the admin network.
- prometheus0 will therefore have a NIC on CMON's non-admin network.
  For M1, a firewall will be setup on prometheus0 so that by default no inbound
  requests are allowed on that interface. For later milestones we could put it
  behind a reverse proxy for UFDS auth for UFDS accounts in the operators group
  (a la AdminUI).

### Current Status (2019-02-11)

- The Triton Prometheus image is in review (MANTA-3552)
- The Manta Prometheus image is ready for review and will be submitted after
  the Triton image is merged (MANTA-4008)

### Remaining Tasks (2019-02-11)

- Decide upon sharding scheme and implement CLI tool for sharding
- Add Thanos sidecar process to Prometheus image

### Unresolved Questions

- Should Manta Prometheus instances also scrape Triton zones, or should a
  discrete Triton Prometheus instance exist in parallel with the Manta
  Prometheii?
  - I (Isaac) think the latter option is preferable, because it lends itself to
    a clean separation of concerns:
    - The targets CMON returns from its discovery endpoint depend on the key
      that was used to sign the Prometheus certificate: the admin key for
      Triton targets, and and the poseidon key for Manta targets. It would be
      cumbersome to get the Manta Prometheus service access to the Triton admin
      key, when a Triton Prometheus service would have access to it by default.
    - Given that the Manta Prometheus instances will be sharded, what logic
      would we use to divvy up responsibility among them for scraping Triton
      targets? It would be cleaner to keep responsibility for Triton targets
      separate -- the Triton Prometheus service will be just one instance
      running in a datacenter that will potentially have many.
- What is the unit of coverage for a given Prometheus instance? Datacenter?
  Region? Cross-region?
  - The Prometheii currently deployed in Starfish each handle (a subset of)
    metrics across an entire region.
    - I (Isaac) think it would be better to have Prometheii local to each
      datacenter and responsible for only that datacenter, for the reason that
      we won't lose metric-gathering capability if there's a partition between
      datacenters. This also means we will shard within datacenters, not
      regions.
    - This will rule out cross-datacenter monitoring unless we special-case it
      for zones for which we deem it necessary.
      - Is Prometheus itself a candidate for this special case?
- How will we handle sharding, logically?
  - Intuitively, we must generate a unique tag per Prometheus instance and
    assign these tags to Manta zones such that every zone has a tag. There are
    a few things we must consider when choosing the logic for assigning tags:
  - No Prometheus instance can be under an infeasible load
    - Starfish currently divides responsibility by service type - there is one
      Prometheus for moray and electric moray, one for muskie, and so on.
      - This makes no guarantee that load is distributed evenly - it is
        possible, for example, that the muskies generate many more metrics than
        the morays, placing the muskie Prometheus under heavier load, but there
        is still enough headroom _right now_ that we don't notice or care.
    - We will want to ensure that load is distributed more
      evenly. We could accomplish this by assigning tags randomly. That way,
      each Prometheus server will, in the limit, have responsibility for the
      same number of zones and distribution of different types of zones, leading
      to an even load distribution.
      - If we have _n_ zones and are scaling from _m_ to _m+1_ Prometheus
        instances, we will need to reassign _n/(m+1)_ zones to achieve an even
        distribution - the CLI tool will handle this. Adding a new Prometheus
        instance after-the-fact will thus not be as expensive as deploying a
        Prometheus fleet for the first time, though the expense will still scale
        linearly with the number of zones in the Manta deployment.
        - If this expense is an issue, we could assign tags using consistent
          hashing instead, which would maintain an even distribution of zones
          among Prometheii while allowing cheaper changes to the Prometheus
          fleet. If we don't anticipate adding and removing Prometheii often, it
          may not be worth it to write and maintain the extra code consistent
          hashing would require.
        - We could also keep exact track of the number of zones assigned to each
          Prometheus instance. This would require a bookkeeping process
          somewhere - we would use changefeed or something similar to track zone
          creation and deletion.
          - This feels to me (Isaac) like overkill when random assignment will
            lead to equal load in the limit.
- What maintenence will we need to perform? How will we perform it?
  - With random shard assignment, it's possible that the load between
    Prometheii will become unbalanced to the point where one Prometheus instance
    is overloaded. This would require redistributing responsibility for zones.
    among Prometheii - moving zones from the overloaded Prometheus to its peers.
    We could build this functionality into the CLI tool.
  - As more zones are deployed, we might have to add another Prometheus to the
    fleet. This would require redistributing responsibility for zones from the
    existing Prometheii to the new one. This could also be performed with the
    CLI tool.
  - Both of these reconfigurations will cause time series for a given zone
    to be split between different Prometheus instances. Thanos appears to be
    able to handle this, as described below.
- How will we detect whether a Prometheus instance is overloaded and requires
  operator intervention?
  - It would be nice to receive alarms when the frequency of dropped scrapes
    rises above some threshold. Is this feasible?
  - We should also monitor CPU and disk usage.
- How will we monitor Prometheus?
  - The Triton and Manta Prometheus instances will be ordinary Triton/Manta core
    zones, so they will get included in CMON discovery.
    - The Triton Prometheus service will monitor itself, or, if we have a HA
      pair, they could monitor each other.
    - We can take care when assigning shard tags to not have Manta Prometheus
      instances monitor themselves, or alternatively have HA pairs monitor
      each other.
- How will we monitor GZ metrics for the admin account? (TODO: link to ticket
  for this).
- How will we define and measure SLOs for the Prometheus service?

## Thanos

### Architecture

We will need an operationalized Thanos image alongside the
Prometheus and Grafana images. Thanos will sit between the Prometheii and
Grafana, aggregating metrics and handling long-term metric storage. The
Triton Thanos service will be deployed using `sdcadm post-setup thanos`.

TODO flesh out with details as they become clear

### Networking

Thanos can communicate with Prometheii over the admin network. Thanos does not
need to be on the external network.

### Current Status (2019-02-13)
  - Operationalization work has not yet started.

### Unresolved Questions

- How should we fit Thanos into the existing milestones?
- What work needs to be done to port Thanos to SmartOS?
  - I (Isaac) am optimistic - both Prometheus and Grafana were ported with
    relative ease.
  - We will need to port the Thanos sidecar too.
- How much traffic can one Thanos instance handle? Can we get away with
  deploying only one Thanos per SPC region?
  - From the [official Thanos design overview](https://github.com/improbable-eng/thanos/blob/master/docs/design.md): "None of the Thanos components provides any means of
  sharding."
  - With that said - it looks like Thanos can scale somewhat by adding more
    "querier" frontends.
- Does Thanos have the ability to present a coherent view of a single time
  series when the time series data comes from multiple sources? When we
  rebalance Prometheus shards, the various time series for a given zone will
  suddenly be collected by a different Prometheus. Thanos should handle this
  gracefully and present an undisturbed view of the time series.
  - It looks like Thanos can handle this, after a fashion - its Github page says
    that it supports "Deduplication and merging of metrics collected from
    Prometheus HA pairs." It looks like we can merge metrics from all Prometheii
    by assigning each Prometheus a unique "replica" label, as explained in the
    Thanos documentation [here](https://github.com/improbable-eng/thanos/blob/master/docs/getting_started.md#deduplicating-data-from-prometheus-HA-pairs).
- Do we need separate Triton and Manta Thanos instances?
  - I (Isaac) don't think so. We can have one Thanos, perhaps deployed as a
    Triton service, that pulls from the Triton and Manta Prometheii alike.
- What is the unit of coverage for a given Thanos instance? Datacenter? Region?
  Cross-region?
  - I (Isaac) think that we should have one Thanos instance per region. This
    will give Grafana one datasource per region, which will be easy to manage
    when creating dashboards. Each Thanos instance will be responsible for
    all the Prometheii from all the datacenters in the region.
- What is the networking plan for Thanos?
- Do we need to handle HA?
  - I (Isaac) am not sure how we could make Grafana handle this automatically.
- How will we monitor Thanos?
  - Thanos, as a core Triton service, will be automatically monitored by the
    Triton Prometheus service.

## Grafana

### Architecture

Grafana will have the Thanos instances as its datasources and present graphs
to the user. The Triton Grafana service will be set up using
`sdcadm post-setup grafana`.

The Grafana image will run an Nginx server to perform TLS termination. It will
use a self-signed certificate by default; the certificate will be kept on a
delegated dataset to persist across reprovisions.

Clients will authenticate using HTTP basic authentication. Upon receiving a
request, Nginx will issue an [authentication subrequest](http://nginx.org/en/docs/http/ngx_http_auth_request_module.html#auth_request)
to a `graf-proxy` restify service, which will use the credentials provided by
the client to authenticate against the datacenter's UFDS instance. Access will
be restricted to operators. `graf-proxy` will pass headers back to Nginx with
the authenticated user's username, full name, and email address, and Nginx will
then pass these to Grafana. Grafana will be configured to use proxy
authentication and will use these headers to create a user account in sync with
UFDS.

A set of stock dashboards will be included and versioned alongside the
Grafana image. These will be updated by reprovisioning the zone.

Users will additionally be able to create custom dashboards. These will be
stored on a delegated dataset and thus persist across reprovisions.

Grafana will use the various Thanos instances as its datasources.

### Networking

Grafana will speak to Prometheus0 on the admin network. For M1, it will only
be on the admin. We will eventually need to make it accessible in the same
fashion as Starfish.

### Current Status (2019-02-14)
- The Triton Grafana image is in review (MANTA-3992).

### Remaining Tasks (2019-02-14)
- The current iteration of the image directly scrapes the Triton Prometheus.
  Once we have a Thanos image, we must change the Grafana image to scrape
  Thanos. In the interim, we may want the Grafana image to directly scrape
  the Manta Prometheii as well.

### Unresolved Questions

- Do we need separate Triton and Manta Grafana services?
  - I (Isaac) don't think so, assuming we have one Thanos service that pulls
    from both the Triton and Manta Prometheii. Grafana will use that Thanos
    service as its datasource and have access to metrics from both Triton and
    Manta zones.
- What is the unit of coverage for a given Grafana instance? Datacenter? Region?
  Cross-region?
  - Starfish currently uses one Grafana for multiple regions, and allows users
    to choose which region's data they want to view. This is user-friendly, so
    it would be nice to continue this pattern. The operationalized Grafana
    instance would have each region's Thanos as a datasource, and the user would
    be able to choose.
    - This will require inter-region networking of some sort - can we safely and
      easily accomplish this by putting the Thanos instances on the external
      network?
  - If this isn't feasible, I (Isaac) think it would be acceptable to have one
    Grafana instance per region and make users navigate to a separate URL for
    each region.
  - Will we want to alter the UFDS `graf-proxy` authentication scheme in the
    long run?
- The Grafana instance in Starfish currently has non-Prometheus datasources.
  Should the new Grafana image support these?
  - These include InfluxDB, Telegraf, and Zabbix.
- How will we monitor Grafana?
  - Grafana, as a core Triton service, will be automatically monitored by the
    Triton Prometheus service.

## General Q & A (somewhat outdated)

- Q: Do Triton and Manta have the same requirements for a Prometheus server?

  A: Only "scale". The current expectation is to have separate prometheus
  services for Triton and Manta that can be scaled independently.

- Q: What do the failure modes for Prometheus look like?

  A: At this point Prometheus only has single node operability, so the failure
  modes aren't very complex. As I see it you can have a failure of the software
  (e.g. app crash), failure of the VM (e.g. OS crash), failure of the hardware
  (e.g. CN hang), failure of the network (e.g. high latency preventing polling
  from finishing), failure of the time series data store (e.g. data corruption).
  I'm not sure this is an exhaustive list, but it is the main pieces I'd be
  concerned about.

- Q: What can we do to proactively secure Prometheus?

  Richard: Prometheus covers this fairly well in
  https://prometheus.io/docs/operating/security/ but basically we need to keep
  Prometheus on the admin network only so that non-operators cannot access it
  (effectively what we do with Admin UI but without the login).

  Jclulow: We could presumably do something like put a reverse proxy in front
  of Prometheus, requiring UFDS password authentication as AdminUI does today.

- Q: How do we monitor Prometheus?

  A: I'm sure there are many ways to do this, but my preference, for the
  installs that we control, would be to have each Region/AZ/Whatevers
  Prometheus install to have a check for every other Prometheus and utilize
  the built in /metrics endpoint that each Prometheus has by default.

- Q: Will there be a realistic need to N scale Prometheus?

  A: "I feel pretty confident that we can scale by sharding the set of work
  across multiple independent prometheus installs for quite some time." --
  RichardK

- Q: What will a low risk deployment look like?

  A: The main risks with a baked in Prometheus install, as I see it, are
  security (e.g. making sure Prometheus is only on the admin network so that
  others cannot access it) and resource exhaustion (e.g. Prometheus instance(s)
  dominating a CN so that other VMs don't get as much time/resources). Once you
  start talking about pointing it at CMON the risk becomes overwhelming the
  proxy (e.g. setting the polling rate so high that CMON can't keep up with the
  request rate w/o scaling CMON out furether). Once you add in a remote long
  term store (e.g. manta) then we'll need to start concerning ourselves with a
  queueing problem as it pertains to metrics being written to the long term
  store in a timely manner. More or less a single prometheus install is the
  least risky deployment and there isn't much to think about there. The biggest
  risk comes from all the other pieces of the system that it will touch.

- Q: Should we get prometheus into pkgsrc?

  A: Sounds like a good idea, but likely Triton/Manta prometheus images
  would still build their own prometheus.
