---
authors: Trent Mick <trent.mick@joyent.com>, Richard Kiene <richard.kiene@joyent.com>, Isaac Davis <isaac.davis@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=RFD+150
---

# RFD 150 Operationalizing Prometheus

This RFD's purpose is to define how Prometheus (and Grafana) will added as
core Triton and Manta components.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Status](#status)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status

Still a draft write-up that has yet to be discussed widely.
M0 (milestone 0) exists now for experimentation.
M1 is in progress.

See [RFD-150 labelled issues](https://jira.joyent.us/issues/?jql=labels%20%3D%20RFD-150), if any.


## Overview

Prometheus and Grafana have become an important resource for Joyent operating
its Triton and Manta deployments. They will also likely become recommended
operating practice for other users of Triton and Manta. For Joyent's and
other's usage it would be beneficial (for maintenance, consistency,
improvements) to have prometheus and, likely, grafana be core services deployed,
configured, and upgraded by the usual Triton and Manta operator tooling.

The current plan starts with adding core Triton services for "prometheus"
and "grafana". Subsequently we will add core Manta services for these,
subject to more discussion with the Manta team.


## Service requirements

If we lose occasional metrics due to a Prometheus outage, it is acceptable with
our current level of maturity.

That said, I think there should be tracked SLO (service level objectives) for a
given prometheus core service. This would be measureable from Prometheus' from
separate DCs in a cloud monitoring each other.


## Triton service

There are two optional new Triton core services, "prometheus" and "grafana",
setup via:

    sdcadm post-setup prometheus
    sdcadm post-setup grafana

They depend on CMON being setup. "prometheus0" gets metrics from the local CMON
as the 'admin' account; "grafana0" sources from prometheus0 and has preset
dashboards. For M1, only a single instance of each is supported (i.e. no HA, no
sharding yet).

The networking plan:

- Prometheus needs to be on the external to properly work with CMON Triton
  service discovery and CNS -- at least until CNS support split horizon
  DNS to provide separate records on the admin network.
- prometheus0 will therefore have a NIC on CMON's non-admin network.
  For M1, a firewall will be setup on prometheus0 so that by default no inbound
  requests are allowed on that interface. For later miletones we could put it
  behind a reverse proxy for UFDS auth for UFDS accounts in the operators group
  (a la AdminUI).
- grafana0 will speak to prometheus0 on the admin network. For M1, it will only
  be on the admin. It will be setup for TLS with a self-signed cert. That
  cert will be on a delegate dataset so reprovisioning doesn't wipe it.
  For later miletones we could put it behind a reverse proxy for UFDS auth
  for UFDS accounts in the operators group (a la AdminUI).

The Prometheus service will scrape the local CMON as the admin account,
from which it discovers all the core Triton zones (TODO: exclude nat zones)
and gets service metrics (via the existing "triton-core-services" cmon-agent
collector). This will require a Prometheus key on the admin account. We will
not use the "sdc key" on the admin account. Prometheus will store metrics
for one month by default -- this will be a (SAPI) tunable -- on a delegate
dataset to preserve across reprovisions. Long term storage of prometheus
metrics is the subject of separate work by Richard (TODO: link). That work will
be integrated into the prometheus image.

The Grafana service will have the prometheus service as its source. It is
preset with core dashboards from <https://github.com/joyent/triton-dashboards>.
For M1, all Grafana configuration is stock. I.e., grafana is stateless.
For later milestones the Grafana zone will allow custom dashboards that are
preserved (within reason) between reprovisions.


## Manta service

TODO: Discuss with Manta team after getting some experience with the Triton
services.


## Security

TODO: discuss security concerns and answers


## Milestones

### M0: plain bash setup scripts

Currently <https://github.com/joyent/triton-prometheus/> provides
"setup-prometheus.sh" and "setup-grafana.sh" scripts that will setup
"prometheus0" and "grafana0" core(ish) Triton zones (based on LX) configured
to scrape metrics for all core Triton VMs, including service-specific metrics
from many of the APIs, and with preset dashboards for some Triton services,
per <https://github.com/joyent/triton-dashboards>.

If desired for expediency, these could be used to setup quick and disposable
instances in production to explore Triton service metrics.


### M1: core prometheus0 and grafana0 Triton zones

- Ensure Prometheus and Grafana work sufficiently on SmartOS.
  Isaac is investigating this. E.g. see
  <https://github.com/fsnotify/fsnotify/pull/263>
- [create a triton-prometheus image](https://jira.joyent.us/browse/MANTA-3552)
  Trent and Isaac are working on this.
- create a triton-grafana image
- sdcadm setup and upgrade support


### M2: Manta service design

It is expected that a single Prometheus will not suffice for large Manta
deployments. The plan is to shard prometheus instances by having them scrape
a subset of poseidon instances from the CMON discovery endpoints. The plan
is to add filtering support to CMON's discovery endpoint and in
Prometheus'
[`triton_sd_config`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#%3Ctriton_sd_config%3E)
such that a given prometheus instance could handle a subset of services. (TODO:
link to this ticket).

- discovery filtering support
- determine if shared or separate Triton/Manta images
- determine if Manta eng wants a core *grafana* instance
- sharding plan
- manta deployment tooling updates for the new services


### M3: Improve auth

Consider UFDS-based reverse proxy auth for the prometheus and grafana zones.


## Open Questions

- Define SLOs for prometheus service and how to measure it.
- Expand on the prometheus and grafana auth story described in the "Triton
  service" section for beyond M1.
- How to setup prometheus' and grafana's to monitor themselves (across DCs)?


## Q & A

- Q: Does Triton and Manta have the same requirements for a Prometheus server?

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

  A: I feel pretty confident that we can scale by sharding the set of work
  across multiple independent prometheus installs for quite some time.

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


## Trent's notes

- prom zone firewalling by default (a la IMGAPI of old)
- grafana https and cert:
    http://docs.grafana.org/installation/configuration/#protocol
    cert_file, cert_key below that
