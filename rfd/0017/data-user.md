<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent, Inc.
-->

# What's this?

This is straw-man user documentation for the CA 2.0 Data API.  It's 100%
vaporware.

I use "CA" in this document to refer to the new system, though we may well
decide to call it something else.


# Data API Overview

The CA Data API provides services for storing, processing, and reporting on both
log files and real-time performance data.

You can send log files to CA, and then:

* create dashboards of key metrics (e.g., request count, request count by HTTP
  status code, or 99th percentile of query latency)
* watch these dashboards update in real time
* manipulate these graphs interactively: quickly zoom out to see 1-month,
  6-month, or multiple years' worth of data
* run ad-hoc queries on the historical data (e.g., search for occurrences of
  a given request-id or error code)

You can do the same with performance telemetry:

* build real-time dashboards of key performance metrics
* zoom out or scoll back to see historical trends in real-time
* generate ad-hoc reports for any combination of metrics

Besides sending your own data to CA for processing, you can also have CA
*instrument* your systems deployed in the Joyent Public Cloud.  For example, you
can get information about filesystem operations, network activity, and even
application-level activity like Postgres and Node.js -- without custom software
or configuration.


# Concepts

At its core, CA is a time-based **event stream** processing service.  It
processes two kinds of event streams:

* **logs**: streams of **events** called **log entries**, each of which has a
  timestamp and arbitrary other key-value pairs called **fields**.
* **metrics**: like log streams, but in addition to fields, metrics also have a
  primary *numeric field* that's typically plotted as the "value" of a metric.

An example log from a web server running on `mackerel` might be called
`mackerel.http_access_log`, and each entry may have an HTTP method, URL, source
IP, and so on.  An example metric from that system might be
`mackerel.tcp_accepts`, which counts the number of TCP connections accepted on
that system.  The main difference between a log and a metric is that it makes
sense to plot a metric by itself, whereas you have to say what field from a log
you're intending to plot.

Logs and metrics often overlap.  It's totally reasonable to have an HTTP access
log that only gets updated hourly *and* a separate agent that counts HTTP
requests in real-time.


# Getting started

The easiest way to get started is to use Joyent-provided instrumentations (via
the **instrumentation API**).  In the CA portal, enable the "CPU utilization"
metric.  When you do this, the service begins instrumenting CPU usage from each
of your Joyent machines and starts plotting that on a graph in real-time.

If you already have agents that transmit telemetry for Statsd, Nagios, or Munin,
you could instead configure them to transmit directly to CA.  Once you've done
so, you'll see these metrics in the portal.  To start plotting one of these
metrics on a real-time graph, right-click one of them and select "Record
real-time data".  Then click the metric to start plotting it on a graph.
(You'll only see data that came in after you enabled real-time recording, so it
may take a few seconds for data to show up.)


## Working with graphs

Whichever data you started with, you now have a real-time graph of a single
metric.  If you started with the CPU utilization metric, you can *break down*
the utilization by machine name or whether the CPU time was spent by userland or
the kernel.  You can also *filter* the data by datacenter or machine name.

You can also plot a different metric on the same graph, either by clicking the
button to add a metric to the graph, or dragging a metric directly to the graph.
If the metric has different units, you'll see a second Y axis.

You can scroll back, zoom out, and so on.  The graph will be updated right away.


## Dashboards and indexes

At this point, if you close your browser and come back later, the graphs that
you set up will be gone.  If you want to save them for later, click the "Save
dashboard" button at the top of the screen.  This will save all of the graphs
you've set up so that you can come back to them later.

If you come back to the dashboard a month later, you'll see the same set of
graphs showing the latest real-time data.  However, you'll also be able to
zoom out and scroll back and forth to view data for any time period in the last
month.

These graphs update quickly because when you save a dashboard, the system
creates **indexes** for all of the metrics on the dashboard.  When new data
comes in, the index is updated so the dashboard will always load quickly, for
any time interval.

You can see the list of indexes that have been created by clicking the "Indexes"
tab.  You can see how much data is being used by each index so you can see how
much each one costs.  You can also delete an index, which will prompt you to
delete any dashboards using that index.


# API details

The REST API has a few types of objects:

* **event streams**, described above
* **indexes**, which provide efficient access to one or more queries over an
  event stream
* **dashboards**, which represent collections of graphs.  All graphs are based
  on indexes, but the system will generally create and delete indexes for you as
  needed.


## Event details

Each event stream corresponds to a log file or a single metric (e.g.,
"http requests", or "database queries").  Each event stream has a unique name.
Here's an example:

    {
        "name": "postgres.queries",
        "type": "counter"
    }

We'll ignore the "type" property for now.

You'd configure a monitor to send **events** into the event stream.  (If the
event stream is a metric, then each event is just a data point.)  Here's an
example:

    {
        "stream": "postgres.queries",
        "timestamp": "2013-12-11T00:57:04",
        "hostname": "mackerel",
        "database": "website_data",
        "shard": "1",
        "table": "users",
        "count": "52"
    }

This data point indicates that during the 1-second interval starting at
2013-12-11T00:57:04, there were 52 queries on shard 1 of the "users" table of
the "website\_data" database.

CA refers to this whole event stream as a metric called "postgres.queries", but
you can plot a whole bunch of different metrics from this data by filtering or
expanding the key-value pairs.  For example, you could plot "database queries on
hostname mackerel", or "database queries" for each of N shards.

You submit events with:

* `POST /:stream_name/data`: inject data into an event stream.
  
The event stream doesn't need to exist already.  It's automatically created when
you first submit data.

You can fetch the event stream's configuration with:

* `GET /:stream_name/info`: fetch event stream information

This will report:

* the stream's type
* the Manta directory with all of the raw data that's ever been received

If you want to fetch only data:

* from a specific interval,
* matching a certain filter, or
* aggregated based on the values

then you either need to use an *index* or an *ad-hoc report*.


## Indexes

An **index** allows you to fetch, filter, and aggregate data over an arbitrary
time interval.  By default, every **event stream** has a single index that sums
all values for all key-value pairs.  So if you have the above stream, then you
also have an index that allows you to fetch the total number of postgres queries
over any time interval.

On the other hand, if you want to get the number of postgres queries for table
"users", the default index doesn't support that query.  Instead, create an
index:

    * `POST /index`: create an index

Here's an example index configuration:

    {
        "name": "users_table",
        "columns": [ {
            "stream": "postgres.queries",
            "filter": { "eq": [ "table", "users" ] }
        } ]
    }

Once you create that index, the system will start building it based on the data
that's already present, and new data will be incorporated into the index.  You
can fetch the state of the index with:

    * `GET /index/:name`: fetch index state

which reports something like this:

    {
        "name": "users_table",
        "columns": [ {
            "stream": "postgres.queries",
            "filter": { "eq": [ "table", "users" ] }
        } ],
        "state": "building",
        "created": "2013-12-11T01:23:49.509Z"
    }

Once the index is created, you can also see how much storage the index is using:

    {
        "name": "users_table",
        "columns": [ {
            "stream": "postgres.queries",
            "filter": { "eq": [ "table", "users" ] }
        } ],
        "state": "ready",
        "created": "2013-12-11T01:23:49.509Z",
        "nobjects": 10,
        "nbytes": 4028314
    }

You can fetch data from the index using:

    * `GET /index/:name/value`: fetch index data

As part of this request, you specify a start and end time.  You'll get all the
datapoints in between.

You can also create a single index on two different values:

    "columns": [ {
        "stream": "postgres.queries",
        "filter": { "eq": [ "table", "users" ] }
    }, {
        "stream": "postgres.queries",
        "filter": { "eq": [ "table", "sessions" ] }
    } ]

In that case, when you fetch values for an interval, you'll get two datapoints
for each timestamp.  This may be useful for a graph that includes multiple
series.


## Dashboards

Dashboards are basically a collection of graphs of indexed metrics.  The server
doesn't do anything with dashboards except store these configurations.

You can create a dashboard with:

    * `POST /dashboards`: create a new dashboard

You can give the dashboard a name (for identifying it via the API) and title
text.  The dashboard also lets you specify a number of *graphs*, each with its
own title text and configuration.  To refer to a series, you can either use an
index or the specification you'd use to create an index, in which case the index
will be created for you.

You can list dashboards with:

    * `GET /dashboards`: list dashboards

and fetch the configuration for one with:

    * `GET /dashboards/:name`: fetch a specific dashboard's configuration


## Ad-hoc searches

For one-off queries like searching for a specific log message or data point, you
may not want to create and store a whole index.  Instead, you can fire off an
ad-hoc search:

    * `POST /search`: start an ad-hoc search

The input looks like what you'd use to create an index: some number of filters
on some number of event streams.  The difference is that this will not save
intermediate results that may be useful for performing similar queries again.

Running a search can take time, since it has to process all of the data in the
given date range without indexes.  The `POST /search` API doesn't wait for the
search to complete, but returns immediately with a URL that you can use to check
the status of the search.

    * `GET /search/:id`: fetch the status of an ad-hoc search

When the `state` becomes `done`, this output will include a link to the results.
