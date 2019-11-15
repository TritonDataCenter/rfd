---
authors: David Pacheco <dap@joyent.com>
state: abandoned
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent, Inc.
-->

# RFD 17 Cloud Analytics v2

This document is adapted from the original CAv2 docs from 2013.  There may be
some relics of outdated ideas here.  Please report those so they can be fixed!

This document has a number of sections:

* Problem scope: describes the broad problem space into which CA fits
* Limitations of CA 1.0
* Existing systems: examines lessons learned from looking at existing solutions
* **A proposal for CA 2.0**: summarizes everything up to this point and outlines
  a new implementation of Cloud Analytics to address the existing issues
* Concrete roadmap: suggests concrete steps for making useful progress without
  necessarily committing to the whole CA 2.0 plan.

**Urgency**: We need a system that can better monitor metrics for Manta and SDC.
We've already suffered for our inability to quickly watch metrics from across
the system in real-time as well as the lack of historical information.  It's not
clear whether today's CA is a pain point for customers, though it's certainly
not the draw it could be.

## Problem scope

There are a bunch of closely related problems in this space, and it's not
obvious to what extent we should tackle all of them:

* Operating system instrumentation (e.g., what DTrace and kstat can do -- **not
  including** the cross-system data aggregation and presentation parts).  Our
  facilities have a major competitive advantage here.
* Application-level instrumentation (e.g., what dtrace(1M), NewRelic,
  AppDynamics, and custom solutions can do, but still NOT including
  the cross-system data aggregation and presentation parts).  This feels like a
  wash: we *can* do some very interesting stuff with DTrace, but other software
  agents exist that report richer, more relevant information for a lot of
  applications.  (Issues with such agents aside, they are useful for people.)
* Data aggregation and storage (i.e., making collected data available via an
  API).  This is broken out because in principle we could use an open source
  solution (or even a third-party service) for this.
* Data presentation (e.g., a web portal).  Similarly, we could in principle punt
  on this part.

For each of these, there are both real-time and historical elements, which can
be broken up into end-user deliverables:

* portal: user dashboards of high-level metrics (for people to assess status)
* portal: interactive, ad-hoc analysis of real-time data
* portal: queries/reports on historical data (for trend analysis and capacity
  planning)
* API/portal: support for configuring alarms on real-time and historical data
* API (or Manta): real-time data
* API (or Manta): historical data (obviously this can be the same API)

There's also a distinction between what we want internally (for services like
Manta) and what we provide to end users.  While it would be nice to expose the
same APIs and portal features directly to end users, we could also forego the
additional work required to harden and polish those pieces in favor of other
engineering priorities.

Clearly, this is a huge problem space, and we should carefully consider which
parts we want to do and how we can best do them incrementally.


## Limitations of CA 1.0

The existing CA ("CA 1.0") is okay for its primary use case: troubleshooting
real-time problems in a single datacenter.  For a service like Manta, it has a
number of limitations that make it unusable for status monitoring and painful
for both real-time performance analysis and historical data analysis:

* It's way too cumbersome to use the API to deal with historical data.  That's a
  problem in itself, but it also makes it very hard to create the "status page"
  that's arguably the most important piece of distributed system observability.
* There's no ability to combine data from multiple availability zones, even in
  the same region.  This is critical for Manta, since even the most basic Manta
  operations span AZs.
* While CA works well for ad-hoc, low-dimensional instrumentation of high-volume
  events, it has no support for higher-dimensional instrumentations, and no API
  help in managing large numbers of long-term instrumentations (e.g., tags,
  searching, or namespaces within an account).
* Scalability: All CA data currently flows over AMQP through a single rabbitmq
  instance, which caps overall throughput.  Even individual aggregators in JPC
  have run out of CPU capacity monitoring single (expensive) metrics across the
  fleet.
* Availability: CA has multiple single points of failure.  To monitor something
  like Manta, CA should be at least as available as Manta itself.

For end users considering using CA, a major problem is that application-level
metrics are primary for cloud users (for good reason), and CA doesn't support
custom metrics.  It's hard to sell people on a separate system for
infrastructure-level metrics that doesn't include the metrics they actually need
most of the time.  For those interested enough to try it, it's hard to get
people started with such a tool.

It's also important to realize that many end users who would be interested in
the services CA could provide already have their own monitoring system.  In the
limit, we could support funneling our data directly to customers' existing
monitoring systems as well as ingesting data from existing monitoring agents.
This would avoid the problem of adoption being all-or-nothing: people could
start by piping our data into whatever they use, and move over to our
aggregation and portal if that's useful for them.

CA has a number of other issues, including tracking VM state changes and
operating on user tags.  While this makes CA 2.0 sound like a lot of work, on
the plus side, *much* of the work that went into the original CA has been
obviated by newer SDC facilities (e.g., UFDS, restify, WFAPI, bunyan).


## Notes on existing systems

There are many existing monitoring systems, both open-source and proprietary,
both on-prem and as-a-service.  Many can be eliminated from consideration if we
assume the constraint that we cannot require on-prem users of SDC and Manta to
purchase third-party monitoring systems that are proprietary or available only
as-a-service.  Here, we only consider graphite/statsd, which have been
influential in this domain.


### Overview of graphite/statsd

**The information in this section was compiled in 2013, and may be out of
date.**

Graphite and statsd are separate systems, but are frequently deployed together.

**Graphite** provides three basic services:

* carbon-cache: receives metrics (over TCP or UDP) and stores them using a
  custom database called *whisper* that resembles rrdtool
* web frontend for graphing metrics and creating dashboards
* carbon-relay: provides replication and sharding for the data service

There's also a carbon-aggregator service for buffering data in-memory before
recording them.

**Statsd** is a network service that exposes a richer data model than Graphite
does.  You put Statsd in front of Graphite: your agents send data over the
Statsd protocol to a Statsd instance, and Statsd processes it and reports it to
Graphite.


#### Data model

Statsd appears to owe its existence to Graphite's limited data semantics.  In
Graphite, each metric is configured with a data retention period (e.g.,
per-10-second-data for a week), and if you send multiple data points for the
same metric during the same period, it clobbers whatever other data point it had
for the same period.  This low-level approach makes it difficult to incorporate
data for the same metric from multiple sources (since each one's data would
clobber the other's), though you can solve this by keeping separate top-level
metrics for each source.

Statsd, by contrast, accepts [several types of
data](https://github.com/etsy/statsd/blob/master/docs/metric_types.md) using a
simple plaintext protocol:

* counters (numbers that get summed within an interval and reset to zero at the
  end of each interval)
* gauges (numbers that represent levels, which are never summed nor reset)
* timers (misnamed, these are numbers for which statsd will maintain the mean,
  median, min, max, and any fixed set of percentiles.  You can also configure it
  to track histogram data (i.e., buckets), which could be used as the basis of a
  heat map.)

Statsd buffers all incoming data in memory until a specified flush interval
elapses, at which point it sends the data to Graphite.  The flush interval
should correspond with the minimum resolution that Graphite's storing, or else
data will be clobbered for the reasons described above.

All Statsd really does is buffer the incoming data and use the type to express
it more usefully to Graphite.  For example, if you have a counter, Statsd sums
the incoming values for the duration of the flush interval, then sends that to
Graphite and resets the counter.  For a gauge, it also maintains a value, and
allows you to send incremental changes to it, but it doesn't reset the gauge to
zero, and assumes that non-incremental changes clobber the existing value.
(That's the desired behavior for a gauge.)

More interestingly, for a timer value, statsd stores all data points for the
current interval.  When the interval is complete, it computes the mean, median,
and whatever percentiles you ask for, and sends these all to Graphite as
separate metrics.  (In this case, a single Statsd metric is modeled as a whole
bunch of Graphite metrics.)  Each separate histogram bucket that you configure
will also create a new Graphite metric.  (Graphite has reasonable facilities for
selecting and plotting groups of metrics, so this is probably a reasonable
approach.)

For more information, see [Understanding StatsD and
Graphite](http://blog.pkhamre.com/2012/07/24/understanding-statsd-and-graphite/).


#### Web interface

The Graphite web server has a [powerful
API](http://graphite.readthedocs.org/en/latest/render_api.html) for drawing
graphs based on expressions.  You can easly plot one metric (`stats.foo`) over
an arbitrary time interval, or a family of metrics
(`stats.postgres.tables.*.nrows`), as well as the sum of a bunch of metrics
(`sumSeries(stats.postgres.tables.*.nrows)`), or any of a bunch of [other
functions](http://graphite.readthedocs.org/en/latest/functions.html) on metrics.
You can plot constant values, only values above or below some other value, and
so on.  These are trivial in some sense, but go a long way towards supporting
useful dashboards.  The API can also emit images, CSV, or JSON.

The flip side is that the web interface itself is pretty janky, and this makes
creating useful dashboards quite cumbersome.  Beyond that, the results are also
not easy on the eyes: bright colors, awkward fonts, and so on.  Again, these
things sound trivial, but have an impact on the ability to quickly read
information on a dashboard.  The graphs are not interactive at all, and graph
refreshes are *very* visually disruptive, so it's not great for real-time data.

There are [alternative visual
interfaces](http://dashboarddude.com/blog/2013/01/23/dashboards-for-graphite/),
but the client-side ones either require lots of custom code (i.e., they're more
like frameworks for drawing graphs based on Graphite data than a complete
client) or aren't very useful.  ([Graphene](https://github.com/jondot/graphene)
was the only one that auto-configured itself from the dashboards already in
Graphite, but it only seemed capable of showing three series on a chart, which
is a non-starter.)  I haven't tried setting up the server-side dashboard systems
yet.

[Grafana](http://grafana.org/) seems to be popular.


#### Conclusions about Graphite and Statsd

The Graphite/Statsd combination is obviously very powerful, and while I haven't
explored the sharding and replication features, it appears intended for
significant scale, and is used at some reasonably large enterprises.  That said,
the model seems unsuitable for high-dimensional data and for ad-hoc data (e.g.,
metrics that are only watched for a few minutes, and then never viewed again).
It's not clear how programmatically manageable the data layer is.

Problems aside, there are a number of important ideas in it.  Most importantly,
it's incredibly easy to start beaming arbitrary data to Statsd and Graphite.
People rave about the value of empowering engineers to add new metrics to
existing software by just configuring the software to emit them.

* It's a very simple plaintext protocol over UDP, and the only thing you send
  are data points.  That is, there's no configuration, or "creating" a metric:
  you just start sending data.  
* Many of the properties are configured based on [regular expressions on the the
  metric's
  name](http://graphite.readthedocs.org/en/latest/config-carbon.html#storage-schemas-conf).
  For example, you could say that metrics called `^manta\.*` are kept according
  to one retention policy, and `^sdc.*` another.  While a regex isn't an awesome
  way to configure this, configuring based on patterns is a nice way to deal
  with the fact that you want differing policies and configuration without
  having to configure each metric individually.

The underlying point behind all of this is: **any visualization of *useful* data
is much better than none**.  However awkward, unscalable, and limited, the
metrics we're gathering for Manta in statsd right now have already proved very
insightful.

There are a few details worth commenting on:

* The whole business about [configuring the Statsd flush interval to match the
  Graphite retention
  time](https://github.com/etsy/statsd/blob/master/docs/graphite.md) (discussed
  above) is ridiculous.  It basically works if you configure it right, but leads
  to data loss if you get it wrong, and neither Statsd nor Graphite knows when
  the wrong thing is happening.
* For timer metrics (the ones that can support percentiles and histograms),
  statsd assumes you're sending every single data point to it (or at least
  sampling every single datapoint).  While sampling is nice, this seems
  enormously less scalable than reporting buckets the way CA does (though that
  only allows percentiles to be approximated).
* The implicit assumptions about the smoothness of data seem unfortunate.  For
  example, in my test rig, I'm monitoring vacuum and analyze operations from
  Postgres.  It's important to know when these are happening (and when they're
  not), but it's pretty binary over any reasonable interval because they only
  happen every few minutes.  Since they're not that frequent, I'm having
  Graphite store only per-5-second data.  But as a result, I *never* see 1
  operation: I only see the line go up to 0.2 operations, since it was 1
  operation over a 5 second interval.  (This problem seems to permeate this
  space: rrdtool, the precursor to whisper in Graphite and the heart of many
  other systems, also does silent interpolation.)
* The way these systems deal with timestamps seems suboptimal: they all seem to
  take timestamps when the data is received, rather than sending a timestamp
  with the data.  While clock skew should generally be small, it seems like
  different transit delays from different systems could have a noticeable effect
  on graphs that record data from multiple systems.  There's no way to buffer
  data during a partition or transient service failure and report it later.
  (This problem also seems to affect other systems, including rrdtool.)
* While the Graphite metric namespace is simple to understand, working with it
  is very cumbersome.  Between all the layers that each add their part to a
  stat's name, it can be hard to predict when you first start sending it, and
  then it's annoying to delete ones created with the wrong name.  Even with
  wildcards, it's also tricky to get the names right when building a dashboard.

## A proposal for CA 2.0

To summarize everything up to this point, addressing the broad problem of
software monitoring involves:

* Ad-hoc and ongoing infrastructure-level instrumentation
* Ad-hoc and ongoing application-level instrumentation
* Data aggregation and storage for real-time queries
* Data aggregation and storage for historical queries
* Data reporting, alarming, and presentation (i.e., a portal)

Additional design goals:

* Instrumentation sources should be able to report to existing third-party data
  sinks, like statsd and Circonus.
* Our own data sink should be able to accept data from third-party data sources,
  like collectd or any statsd source.

Broadly, we'd break this up into:

* **IAPI**, the Instrumentation API.  This looks broadly like today's CA API,
  where users can enable and disable instrumentations for their infrastructure.
  This service would be responsible for enabling and disabling various sources
  of data in the cloud.  Like the CA API, in the limit, this would be exposed
  via CloudAPI (and a user portal) and AdminUI.
* **EVAPI**, the Events API.  This looks similar to today's CA aggregators.  The
  Events API would accept data in any number of forms (including, of course,
  data reported by IAPI, but also probably statsd data) and store it both in a
  real-time tier and a Manta-based historical tier.  Ad-hoc queries would be
  supported, but expensive.  Users would configure queries they'd like to be
  answer quickly, and dashboards and reports that are made up of these queries.
  The historical part of EVAPI is embodied today as a command-line tool called
  [Dragnet](http://github.com/joyent/dragnet).
* Integration into a portal and alarming system.

There are prototype end user docs and design docs for both IAPI and EVAPI:

* IAPI: [design](instr-design.md), straw-man [end user docs](instr-user.md)
* EVAPI: [design](data-design.md), straw-man [end user docs](data-user.md)

Extremely early implementations exist as well.

## Concrete roadmap

At this time, it's not expected that we'll necessarily tackle much of this
project, but in order to alleviate the critical monitoring problems we have
today, we'd suggest implementing pieces in this order:

* [Dragnet](http://github.com/joyent/dragnet), a system for historical analysis
  of data stored in Manta.  This is largely functional today, but with very
  limited support for data formats and queries.
* A Node.js library for reporting metrics that are automatically uploaded to
  Manta or an alternative data source.  The foundations for this (using statsd
  as a backend) are part of
  [node-statblast](https://github.com/davepacheco/node-statblast).  With this
  component, various SDC and Manta components could be configured to store
  performance data into Manta that could be analyzed with Dragnet.
* An Instrumenter, a stand-alone program for instrumenting the system.  The
  instrumenter should support pluggable sources, including dtrace (via Meta-D)
  and kstat (via a similar declarative configuration).  This standalone program
  would be controlled and monitored using an HTTP API and command-line tool.
  The instrumenter should support pluggable sinks, including a file-based sink
  and a Manta-based sink.  The Manta-based sink would use the above library.
  With this, we'll be able to generate data and store it in Manta for historical
  analysis.  This component would mainly be used for reporting infrastructure
  metrics.
* Wrapping up the Instrumenter as an SDC agent to manage its deployment.
* IAPI, which would manage the configuration of a fleet of Instrumenters.
* EVAPI (see below)
* A portal

EVAPI needs further design consideration to determine whether it makes more
sense to implement this as an API or a client library.  An API could hide the
distinction between a real-time and historical data tiers, but introduces
new failure modes when the API itself is down.  A client library could spool
data to disk while the API is down in order to deal with partitions and other
transient failures.
