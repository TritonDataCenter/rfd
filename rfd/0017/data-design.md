<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent, Inc.
-->

# CA 2.0 Design

This document complements the CA 2.0 overview document.  That document outlines
the problem space, motivation, and intended scope, while this document gets into
the design and implementation details of the Data API.

There's also separate proposed user-facing documentation for the Data API.  You
should probably read that first to get a sense of what we're trying to
accomplish.


## Sketch of requirements

Basic requirements:

- **Data API** that supports:
  - POST data to HTTP service, and possibly lower-overhead mechanism (UDP,
    websockets, or the like)
  - GET data from HTTP service (including complex queries, heat maps, etc.)
  - management operations
- **Instrumentation API** that supports:
  - POST to create instrumentation, which reports data to data service
  - DELETE to remove instrumentation
  - management operations
- The Data API should be region-wide, so that data from multiple datacenters in
  the same region is available in the same place.
- The system should be highly availability, choosing A over C in CAP.
- Every component should be horizontally scalable.
- There should be no single point of failure, though it's potentially okay to
  lose a small amount of performance data when a service restarts.

With respect to CAP: If a datacenter becomes partitioned, then requests to the
data api inside the majority partition will succeed and return data from the
majority DCs.  Requests for data from the partitioned DC *should* show data from
that DC.  (Otherwise, it may be difficult to debug the networking problem in
that DC.)

If a data service instance crashes (say, the box panics), the data cannot remain
unavailable for the time required for that system to come up.  That suggests
that either the leaf servers report to multiple data service instances or else
the data service instances "take over" for one another somehow.  If the latter,
it's an open question whether these instances replicate to each other to reduce
data loss in the event of a crash.  In the extreme case, we'll have multiple
agents on each CN POSTing data frequently to the data service.


## User stories

**User-generated data**

1. User wants to plug a custom data source into CA.  They configure pgstatsmon 
   on their postgres instance, point it at our API, and want to see a real-time
   graph of the size of each table (e.g., number of live tuples).
1. The same user comes back a week later and wants to see a graph of live
   tuples, per table, over the last week.
1. The same user zooms in on a 6-hour period spanning two calendar days earlier
   in the week.
1. The same user zooms in on a 5-minute period earlier in the week.


**Real-time ad-hoc metric**

1. User sets up CA to monitor Postgres query latency.  (This is similar to steps
   1-4 above, but with a high-volume, DTrace-based metric.)
1. User later logs into CA to debug a performance problem with the database.
   User looks at query latency, then digs into CPU time and filesystem
   operations (not previously collected).


**Big system dashboard**

1. Manta team sets up instrumentation:
    * pgstatsmon: table size, vacuum and analyze stats, dead tuples, replication
      lag
    * postgres query latency (DTrace-based)
    * moray query latency (DTrace-based)
    * nginx time-to-first-byte (p95)
    * muskie requests, by type and status code
    * muskie time-to-first-byte (p95, by type)
    * muskie throughput per-request (p95)
    * muskie total bytes in/out
    * muskie top URLs (???)
    * muskie top users whose storage is accessed (???)
    * muskie top users making requests (???)
    * marlin tasks dispatched
    * marlin tasks completed
    * marlin jobs submitted
    * marlin jobs completed
1. Manta team creates dashboard for several of the above metrics
1. Manta team also creates several "reports": metrics for which we want
   historical data available.


**Big system log analysis**

1. Manta and SDC both set up logging into CA 2.0.
1. Build automated reports on some of the above metrics.
1. Manta team wants to "grep" for some request-id.


## User abstractions

* **Event stream**: a stream of events that a user wants to process.  This may
  be either a log (e.g., a bunyan log) or a metric (e.g., "postgres queries").
  Each event has a timestamp, a source, a stream name, and arbitrary key-value
  pairs.
* **Metric**: an event stream where each event has a primary numeric field.
  "Postgres queries" might be a metric.  Each "event" may represent a summary of
  queries over an interval (e.g., 457 queries in the given second) or it may
  correspond to a single query (in which case the count might be "1").  In
  either case, key-value pairs may describe other attributes like the database
  name, table name, query type, and so on, which we can use to produce separate
  graphs.
* **Dashboards** (or **reports**): These are user-configured web pages that have
  one or more graphs, each over one or more event streams (and associated
  metadata).  The system will index event streams for which users have
  configured dashboards.
* **Ad-hoc reports**: These are like dashboards, but scoped to a user's browser
  session, and not indexed by the system.  Dashboards are updated in real-time,
  and historical data is available for a long time, while ad-hoc reports may
  take some time to run.

Internally, there's also the idea of an **index** on one or more event streams.
See "Implementation details" below.

## Use cases

### Use case 1: plugging in a custom data source

We use [pgstatsmon](https://github.com/TritonDataCenter/pgstatsmon) as a representative
example of an agent that users may already be using that uses a totally custom
instrumentation mechanism and reports it in the widely-used statsd format.  We
assume that our data service already has a way to ingest statsd data over the
REST API, though that itself is a non-trivial problem to be discussed later.

#### Option 1: simple statsd ingest

The user starts by pointing pgstatsmon at our REST API.  pgstatsmon reports a
number of stats with names like:

    stats.us-east.postgres.1.365cd938.manta_storage.n_tup_ins

That stat denotes the number of rows (tuples) inserted into the "manta\_storage"
table on database shard "1" on the system identified as "365cd938".

When the server starts receiving these stats, each distinct statsd stat will
become a separate **metric event stream** in CA.  Each data point will be
reformatted to match the internal schema, which includes a timestamp, a source
IP, a metric name (that corresponds to the statsd stat name), and a single
value.  The data will be stored in the real-time cache for a few hours and
flushed to Manta every few minutes.

When the user logs into the portal, they'll see a list of all these event
streams.  They can click one of them to get a real-time graph of that metric.
They can use controls add additional metrics to the same graph.

If the user log out at this point, the system continues to collect real-time
data and saving that data to Manta, but it doesn't remember the graphs that the
user created.

Now suppose the user logs in a week later.  Once again, they're presented with a
list of event streams, but the graphs they created a week earlier are gone.
(They're assumed to be ad-hoc, and they expired when the browser session
expired.)  Now suppose they click one of the metrics again.  As before, this
pulls up a real-time graph for that metric.  But since they've collected a
week's worth of data, they can zoom out or scroll back to look at any period
over the last week.  They can select a specific 6-hour window, from earlier in
the week, for example.  They can zoom in to a 5-minute interval as well.

What's going on is this:

* data for the 30-second real-time graph comes from the real-time cache
* data for the one-week period is fetched by combining data from 7 daily
  reports, possibly combined with some data points from hourly reports on either
  of the endpoint days, and possibly combined with some individual data points
  on either end of the endpoint hours
* data for the 6-hour period is fetched by combining hourly summaries with
  individual data points for the corresponding period
  

#### Option 2: mapping statsd stats to CA metrics

The problem with this simplistic approach is that it ignores the fact that so
many distinct event streams are obviously related.  Suppose instead that it
works like this:

When ingesting data, the user can configure a mapping from a statsd name to a CA
metric stream.  For example, they may use a regular expression to tell us that
this:

    stats.us-east.postgres.1.365cd938.manta_storage.n_tup_ins

should really be represented as:

    {
        "metric": "postgres.n_tup_ins",
        "region": "us-east",
        "hostname": "365cd938",
        "shard": "1",
        "table": "manta_storage"
    }

In that case, all of the `n_tup_ins` metrics are represented with a single
event stream.  When the user logs in, they'll see a much smaller number of event
streams.  As before, they can click a stream name to get a real-time graph of
that metric, but we can also provide controls to filter or decompose by any of
these other fields.

Like in Option 1, the user can come back a week later and pull up graphs of
these metrics over the last week, but there's an important difference: we only
index the entire event stream by default, so queries that break out a particular
field (like "hostname" or "table") will take several seconds or minutes as we
run a Manta job to process the data.

However, the user can choose to *save* a set of graphs to a dashboard (or
report), in which case we'll build indexes on the event stream based on
whichever fields the user has broken out.  


#### Option 3: defer reformatting of statsd data

This is like Option 1, except that we don't actually reformat the statsd data.
We still store each stat as a separate event stream.  However, we provide a user
interface that allows the user to tell us what parts of the stat name denote
key values.  Once this is configured, we create an index for the combined
streams.  This basically flips the sense of Option 2: instead of starting with a
combined metric and allowing users to index parts of it, we start with
individual pieces and allow users to index groups of them.


#### Tradeoffs

Option 1 is easiest for the user to work with, but option 2 probably provides a
better user experience.  Option 3 allows us to start with the easier option, and
convert to the more useful one after the fact without rewriting all of the data.


### Use case 2: ad-hoc real-time debugging

Suppose the user in case 1 finds that there seems to be a performance problem
with their application, and they suspect the database.  Logging into cloud
analytics, they find that there's a "Postgres: query latency" metric available,
so they enable it.  Unlike case 1, where the user started sending data to our
*data API*, this translates to a request to the *instrumentation API* to enable
the DTrace-based postgres queries metric.  The instrumentation API soon starts
blasting data with enough metadata that the *data API* knows to create a single
event stream for this metric.  The UI immediately starts displaying the
real-time graph for this data.

In this way, and similar to CA 1.0, the user can create new instrumentations,
filter and decompose on specific fields, and so on.  In this case, the user
creates instrumentations for CPU utilization and filesystem operation latency.
In each case, the instrumentation API contacts agents running in the global
zones where the users' machines are deployed and they start blasting data to the
data API.

The user can save a dashboard of these graphs, which will cause that data to be
collected indefinitely.  (But see "Other considerations" below.)


### Use case 3: Manta dashboard

In this example, the Manta team sets up several kinds of instrumentation:

* They use the UI to set up some instrumentation-API-based instrumentations
  (e.g., CPU utilization, memory usage)
* They set up pgstatsmon and similar tools for third-party software we're using
* They may use a CA SDK for submitting statsd-like data directly to CA
* They write Meta-D for their own metrics and use this to blast data to the data
  API.

A team member then logs in, creates a set of graphs on this data, and explicitly
saves it.  CA then starts indexing this data so that it can be read cheaply
on-demand.


### Use case 4: Manta log analysis

In this example, the Manta team sets up CA to ingest log data from various Manta
services.  The details of this part are TBD, but either the services directly
PUT objects into CA, or else CA is configured to ingest logs from another Manta
directory tree (where the logs already go).

When a user first logs in, they'll see the names of log event streams that CA
knows about.  When you click one for the first time, you'll be asked to confirm
details about the log format (which we'll hopefully have inferred based on a few
log entries).  After that, you'll have the option of constructing a query that
will produce a graph, by describing which numeric fields to plot, and how to
filter or decompose the log entries.  This will produce an *ad hoc* graph of a
selected time period.  If you save the graph, we'll start indexing that event
stream on the fields required to produce that graph.  You can then include this
as part of a report or dashboard, and even get a graph that updates in
real-time.


## Internals

There are three main components in this system: a frontend API, a real-time
cache, and Manta, which stores historical data.

The frontend API services:

* PUT event stream data: buffer data to disk and flush to Manta periodically.
  If any real-time cache has a subscription to it, send the data to it.
* GET event stream data: for older data, fetch from Manta.  For newer data,
  check the real-time tier.
* POST dashboard (XXX naming): trigger creation of indexes on the event streams
  required to serve the dashboard

Every N minutes, each frontend API flushes data to Manta.

For event streams marked for real-time, the frontend API stores data into some
highly-available, scalable data store.  At the moment, we're considering using a
Moray consistent hashing ring for this.

There are also a set of periodic jobs:

* Every hour, reframe objects stored in the last hour.  (In general, there may
  be multiple objects for a given hour because frontend API servers flush data
  every N minutes and because there may be multiple frontend API servers that
  received the data.)
* Periodic indexing jobs

Internally, there's a notion of an *index*.  An index provides a fast way to
fetch values for one or more metrics.  There's an implicit index for each event
stream, but indexes can also be created for a bunch of metrics.  For example, if
I save a historical graph involving four event streams, the system will create
an index that includes the value of each event stream at each time value.

Unlike the raw event stream, indexes are always aggregated on a time interval
and can be stored using a column-store format.  That is, an event stream cannot
necessarily be stored very efficiently because there can be an arbitrary number
of events during any given time interval and they can have an arbitrarily large
set of distinct key-value pairs.  But an index is always identified by a fixed
set of key-value pairs (e.g., hostname=foo), and the matching points always
aggregated, so the storage used (and time to scan) is easily predictable.

For each index, there are a few periodic jobs:

* Every day, generate an index of values for every 10 second period within that
  day (8640 intervals)
* Every week, generate an index of values for every 1-minute period within that
  week (10080 intervals)
* Every month, generate an index of values for every 5-minute period within
  that month (8064 to 8928 intervals)
* Every year, generate an index of values for every 1-hour period within
  that year (~8736 intervals)

Each of these summaries yields enough data points to plot each one as a single
pixel on a decent-size screen, yet the number of different objects that must be
scanned to fetch data for a given interval is bounded.  (The maximum for any
period less than two years is 22 month-summaries, plus 8 week-summaries, plus 12
day-summaries, plus 46 hour-summaries, totalling 88 objects, plus one object for
each full year after the first two.  This is truly pathological; much more
likely would be more like 20, and aligned intervals would require only one.

### Implementation details

Raw metric data is dumped into Manta as:

    $CA_ROOT/$user/streams/$stream/stream.json
    $CA_ROOT/$user/streams/$stream/raw/YYYY/MM/DD/$server_uuid-$timestamp

Indexes are created in

    $CA_ROOT/$user/indexes/$index/index.json
    $CA_ROOT/$user/indexes/$index/year/year-YYYY
    $CA_ROOT/$user/indexes/$index/month/month-YYYY-MM
    $CA_ROOT/$user/indexes/$index/week/week-YYYY-DD
    $CA_ROOT/$user/indexes/$index/day/day-YYYY-DD

The index name is computed by deterministically hashing the index parameters
(metric name, filter criteria, and breakdowns).  XXX is that feasible?

The JSON files describe metadata about the metrics and indexes.  Stream metadata
may include information about the first time the stream was seen, the format of
the stream, a user-given label for the stream, and so on.  Index metadata may
describe the start time of the index (if we want to support allowing users to
say that only the last N years are indexed).

#### PUT event stream data

Incoming event stream data is streamed to a file, one file per event stream.
After 5 minutes elapse, the file is dropped directly into the directory
described above.

If the event stream is marked for real-time consumption, the raw data is also
directed to a Moray instance.


#### GET event stream data

We first determine whether there's an index for the requested data.  If so, we
use that to fetch it, potentially rebucketize it, and send it to the client.  If
not, we kick off a Manta job to select and aggregate the data.

If the requested interval includes time that's too recent (i.e., requires
accessing the real-time cache), we fetch data from the real-time cache (Moray
ring) and include that.


**Indexed case**

This case may be processed on the client or as part of a Manta job, if the
latency of job execution is low enough.  In either case, we first enumerate the
objects that we have to retrieve to cover the requested time interval, fetch
them, filter only the data points we need, aggregate them as requested, and
return them.

**Non-indexed case**

This case is always run as part of a Manta job.  We enumerate the raw data files
we'll need and run a job to select the data points we want and aggregate them.

In the indexed case, the number of objects will always be bounded, and the
indexes are input-format-agnostic.  In the non-indexed case, the number of
input objects can be very large and the execution will likely depend on the
input format (e.g., statsd data vs. some other data).


#### POST a dashboard

A dashboard describes one or more graphs, each covering one or more event
streams.  This operation figures out what indexes must be available to serve
this dashboard efficiently, initializes each index, and kicks off jobs to
do the indexing.


#### Creating and using indexes

Since data points include arbitrary key-value pairs, queries that filter and
decompose on arbitrary values can be arbitrarily expensive to execute.  The
point of an index is to take specific sets of key-values that a user cares about
and precompute the metric data that the user wants to see.  This trades space
for time, so we only create indexes for the raw event stream itself (i.e., the
sum of the metric over all key-value pairs) and whatever other specific graphs
the user creates.

For example, if the user creates a graph of Postgres queries by table, we'll
create an index for that specific graph.  The index consists of an object for
each period that tells us how many queries we saw for each table.  Since we can
tell how many different tables are represented within the interval, the index
can be made of fixed-size records, allowing constant-time random access for a
given timestamp.

The actual storage representation is still TBD.  One option is a flat file with
a header that describes the exact parameters of the index: the metric, the
filter that was applied (if any), the fields decomposed (e.g., "table name"),
and the values of whatever fields are decomposed (e.g., specific table names) in
the order they appear in each record.  This would be followed by fixed-size
records describing for each row, for each column, the corresponding count of the
primary metric.  We likely would want to keep at least a min value, max value,
and sum, if not also a few interesting percentiles.

XXX for latencies, we probably want min/max/percentiles, while for counts, we
probably just want sum.  how do we know what we want?

An alternative might be a LevelDB, Sqlite, or even Postgres database.

XXX What do we do if the number of values for a column grows too big?  What if
it's too big to even record the top N?

XXX Another type of index might be required for doing top-N queries.


## Other considerations

### Data ingest format

Recall that the basic abstraction is the **event stream**.  In general, events
consist of:

* a type: "metric" or "log" (XXX should this be part of the name?)
* a timestamp
* an event stream name (e.g., "postgres.queries", or "muskie.requests")
* an arbitrary set of key-value pairs (e.g., "host=foo", "database=moray",
  "table=manta\_storage"

If the event stream is a **metric** (rather than a log), then it also has:

* a primary numeric value (e.g., "count")

Since it's critical to be able to ingest data from other metric systems, we'll
want to support other formats for which we'll have to infer some of this
information.  See the statsd example above for details.

### Data ingest transport and authentication

Many monitoring systems use UDP, sacrificing a number of the niceties of TCP:

* packet ordering: since each data point either has a timestamp or is assigned
  one upon receipt, packet ordering is irrelevant
* congestion control and flow control: these are *undesirable* in a monitoring
  system because the data sources generally cannot be throttled.  While
  monitoring is critical, it's usually much preferred that telemetry be dropped
  rather than causing the sending process to buffer indefinitely or block
  threads trying to send telemetry.
* reliability: while retransmission is nice for transient network issues, it's
  undesirable when lots of packets are being dropped, since the alternative to
  dropping packets is indefinite buffering or blocking.

It's tempting to argue that monitoring system reliability is even more critical
when the network is falling apart (and that's true), but the reality is that for
a prolonged event, between dropping packets, blocking the sender, or buffering
on the sender, dropping packets is almost always preferable.

However, the need for authentication changes the situation significantly.  We
don't want to allow anyone to send telemetry for a given user, so we must
authenticate all incoming data.  UDP can make this enormously more expensive,
since we have to compute and attach a signature for every single packet, instead
of setting up a single TLS session and funneling tons of data through that.

There are two better options:

* Use HTTPS, possibly with websockets.
* Support unauthenticated UDP over a UDS inside each zone, and from there
  transmit data over a secure network using either UDP or TCP.


### Meta-D

Meta-D is a declarative description of a group of DTrace-based metrics.  With a
Meta-D description and a set of fields to gather, you can produce a DTrace
script that emits data in a format suitable for CA.

If users want to enable custom real-time metrics, exposing Meta-D would be a
good way to do that.  There are two obvious approaches to this:

1. First-class Meta-D in the instrumentation API.  Harden the format and
   validator, and then let users submit their own Meta-D that we'll run as a D
   script in the global zone of their systems.  There may be significant
   challenges to making this robust.
2. Open-source an SMF service that lets users run their own Meta-D scripts
   inside their own zone and blast that data to our Data API.  This way, the
   damage is limited to whatever the user can already do in their own zone.

### Miscellaneous open questions

* Do we want to enable all metrics for real-time analysis by default, or does
  the user have to turn that on explicitly?  Maybe it depends on the kind of
  data?  (Logs no, statsd no, our instrumentations yes)
* Do we want to allow users to run DTrace-based metrics indefinitely?
* How do we do indexes when the user asks to decompose by something with way
  too many possible values?
* How do we keep track of what indexes are already available for a metric?
  Similarly, how do we keep track of what indexes are being used by what
  dashboards / reports?
* Is the RT cache really separate from the front door?  If so, how do we find
  the right service?  How is it replicated?  How do subscriptions work, and how
  is data transmitted?  If not, how do we ensure a consistent view on the data?
* Should indexes be more directly exposed via the API?  Maybe dashboards
  actually refer to indexes?  This would be more transparent, since we could
  have "GET index data" as separate from "GET ad-hoc data", and it would be
  clear that one should be quick, while the other might take a long time.
* What does the index look like for heat map data?

## Performance

XXX do some napkin math to see how the system will perform

## Scalability

XXX figure out how we add capacity to each component of the system

## Availability

XXX figure out how the system responds to individual component, system, network,
and datacenter failures
