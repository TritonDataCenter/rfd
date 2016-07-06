---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 35 Distributed Tracing for Triton

## Introduction

This will describe requirements and solutions for distributed tracing in Triton
in order to help monitor and diagnose issues around performance and
interdependencies.

## Background Reading

 - [AppDash](https://github.com/sourcegraph/appdash)
 - [Distributed Tracing at Yelp](http://engineeringblog.yelp.com/2016/04/distributed-tracing-at-yelp.html)
 - [DiTrace](https://ditrace.readthedocs.io/en/latest/)
 - [Google's Dapper](http://research.google.com/pubs/pub36356.html)
 - [HTrace](https://github.com/cloudera/htrace)
 - [Introduction to Twitter's Zipkin](https://itszero.github.io/blog/2014/03/03/introduction-to-twitters-zipkin/)
 - [OpenTracing.io](OpenTracing.io)
 - [X-Trace](https://github.com/rfonseca/X-Trace)
 - [Zipkin](http://zipkin.io/)

## Terminology

Throughout this document we'll use the terminology which seems most prevelant in
the industry and has its roots in the Dapper paper.

### Trace

Every user initiated request that comes into Triton starts an associated trace.
The trace represents the initial request combined with all other actions taken
in order to satisfy that request. This can include further requests, execution
of commands, or any other noteworthy work. These individual components of work
are called spans (see below).

### Span

Every individual logical action performed can be considered a span. In the case
of an HTTP request typically this span will have 4 individual components of the
span. There will be:

 * the point where the client sends the request
 * the point where the server receives the request
 * the point where the server responds to the request
 * the point where the client receives the response

after the last component has completed the span will be finished. It is also
common for a span to create additional child spans. In this HTTP example, the
most common case would be the server calling other APIs after receiving the
client's request, but before responding to it. In that case those new requests
are considered separate new spans, but the current span is attached to those
through what we call a "parent span id" which is just the identifier of the span
that created this new span. By creating parent-child relationship for each span
after the initial user request, the trace becomes a tree.

### Logs

As each individual component of a span is written out, it is called a log.
For the example span above we'd have 4 logs, one for each of its components.
Through this RFD we'll also treat each of these logs as a separate call to one
of the bunyan logger's log methods.

### Tags

What Dapper calls "Annotations", OpenTracing.io calls Tags and we'll use that
terminology here. This is basically just a set of key/value pairs that are
attached to a span in order to add additional data about the span. This data can
be added at any point in a span which means it's easy to add tags at the point
that the data is available.

## Goals

### Questions this system should be able to answer

The primary focus of this work is to ensure that it is possible to trace a the
entire series of actions (or as close as possible) that is performed by Triton
to satisfy a given inbound API request, from the first triton component that
receives the request until the response is returned. It should be possible for
each stage in the processing of a request to answer the questions:

 * which API received the request and from which client?
 * what other APIs were called in order to satisfy the request?
 * what commands were executed to in order to satisfy the request?
 * how long did each command and API call take?
 * what type of request was it and what did the result look like?

Since this will be recursive (APIs can call APIs that call other APIs, etc.) we
will end up with a tree (trace) for each top-level request that includes
multiple individual requests and commands (spans).

### Desirable Properties

This section describes some of the desirable properties of a solution to the
problem. It's possible that the initial implementation will not be able to have
all these properties, but they should at least be considered.

#### Implementation in Libraries

One thing that comes out in researching existing work is that a pattern that
engineers elsewhere have been successful with is adding the code required to
support tracing to libraries used for RPC/REST. The Dapper paper calls this
"Application-level transparency".

By adding code to the library, the work required to support tracing of new
programs is minimized. Simplifying the use of tracing in programs this way also
ensures that it is done correctly.

#### Low Overhead

If adding tracing adds significant overhead, the argument for leaving it enabled
all the time is harder to make. And the less often it is enabled, the less
likely it is to be able to catch performance outliers and other events that
happen only in production or when the system is under significant load.

#### ASAP Access to Data

When trying to isolate performance problems in the stack, it is useful to be
able to perform an API call and then as soon as possible look at the trace data
in order to compare performance. This allow a quick loop between
hypothesis-experiment-results.

In a production setting it is also helpful to be able to get feedback as soon as
possible when performance problems occur to minimize the amount of other state
that might be lost or hidden by additional changes to the system that follow.

#### Avoidance of Direct Side Effects

When a request comes in to a server, it might be tempting to immediately and
synchronously send the trace log out over the network to another system. The
problem with this approach is that when a service's number of requests
increases, so does the volume of outbound traffic to log these requests. This
easily could cause either logs to be lost or actual service requests to be
slowed down. Neither is ideal.

Instead, if we write the logs out locally without directly involving another
system, we can have the process that handles offloading and collating this
data be independent from inbound requests. And this tool can control its own
resource usage such that the service itself is not impacted by the tracing.

This can also avoid feedback loops in the case where something goes wrong with
the tracing infrastructure. If each inbound service request resulted in a
corresponding outbound trace log operation, and the trace log operation
triggered an error or for any reason managed to trigger another traced request
it would be possible to end up in a feedback loop that could potentially require
the service to be taken down to recover.

#### Ability to use 3rd party tools

We would like our tracing to be as close as possible to industry standards so
that we can convert our data and send it to 3rd party visualization tools
without too much effort. This allows us to take advantage of other work done by
the community.

## Overview of Proposed Solution

This section describes the solution proposed to gather the information required to achieve the goals
laid out above.

### Headers

The passing of data from a given component to any of the REST APIs in Triton
will be done through the addition of HTTP headers. This section describes those
headers.

#### request-id / x-request-id

For historical reasons (we've historically require the request-id to be
the key we pass through the system) we will use the 'request-id' or
'x-request-id' header as the header for trace identifiers instead of the more
obvious 'trace-id'.

The value of this header must be a UUID.

The 'request-id' form is preferred over 'x-request-id'.

It is considered an error to include both x-request-id and request-id headers.

We should also return the request-id header in all responses at any restify
server. This way clients who make a request will receive back the request-id
header and when they are looking up traces, they can use that ID to find the
logs that match with their request.

#### triton-span-id

This header represents the span identifier (span\_id) of the span that this
request is part of. A new span is started by the client for each request, so the
span\_id sent by the client be treated as the current span\_id on the server.

The value of this header must be a UUID.

#### triton-parent-span-id

This header represents the span identifier of the span that is the parent of the
current span. A client making a request should set this as the current span
identifier then generate a new span identifier for the new request.

The value of this header must be a UUID.

#### triton-trace-enable

This header indicates whether a given trace should have its events written to
logs as separate log messages or not. Even when the trace is not written to
logs, we'll still pass through all the headers so that the request\_id is
maintained for other logs that are unrelated to this tracing.

The valid values of this header are "0" (do not write the traces to the logs)
and "1" (write the traces to the logs).

All requests should include this header but if it is missing, the default will
be to *not* log the request (same as triton-trace-enable: 0).

The primary use-case for this header is to be able to disable traces for some
calls to endpoints (such as /ping) where requests are frequent and the value of
tracing is low. This will reduce the amount of processing required when looking
for actual client requests. Otherwise we'd have many hundreds or thousands of
ping requests (some things ping every second or so per-client-instance and
often multiple things ping each API) for every actual API request in many cases.

#### triton-trace-extra

This header is passed through so that it might be used in the future.

Eventually it can be used for enabling additional tracing for special types of
requests where we might want more information. When this is to be used a format
should be chosen for this in a new RFD. Until then as long as everything just
passes this through, we'll be forward compatible.

### Logical Changes

We will modify restify-clients and node-sdc-clients and attach handlers to all
restify servers such that:

 * When an inbound request includes an x-request-id or request-id header, we use
   that as our trace identifier (trace\_id). When a request does not include
   this, a new trace\_id is generated.
 * When an inbound request includes a triton-span-id header, we use that as our
   span identifier (span\_id). When a request does not include this, a new
   span\_id is generated.
 * When an inbound request includes a triton-parent-span-id header, we use that
   as our parent span identifier (parent\_span\_id). Where the request does not
   include one, parent\_span\_id is set to "0".
 * It will be an error to include one of triton-parent-span-id or triton-span-id
   headers, and to not include the other.
 * It will be an error to include either of triton-parent-span-id or
   triton-span-id and not include a request-id or x-request-id header.
 * For every restify route handled, we generate a bunyan log on request on
   response.
 * For every restify client request (usually through node-sdc-clients) we will:
     * add a request-id header which matches the trace\_id of this trace
     * add a new triton-span-id header for this new span (client requests are
       always a new span)
     * add a triton-parent-span-id header which matches the span\_id of the span
       that is causing the request to be made.
     * pass through the the triton-trace-enabled and triton-trace-extra headers
       unmodified.
 * If triton-trace-enabled is 1, each span.log will result in a span being
   written to the bunyan logger. If it is 0 or unset, span.log will be a no-op.

## Planned Implementation

The implementation of this work will consist of several parts:

1. modifications to restify-client to support .child()
2. modifications to node-sdc-clients to support .child()
3. addition of the event tracing components to all Triton restify servers
4. modification of all Triton client calls to us sdc-client child()
5. modification of cn-agent
6. modification of node-vmadm
7. modification of vmadm

### Modifications to restify-clients

We will add a `.child()` method to restify clients. This will be called as:

```
client.child({
    after: function onAfter() {
      // code that runs after a response is received
    },
    before: function onBefore() {
      // code that runs before anything is sent to the server
    }
})
```

where all `after` and `before` are optional.

If an `after` function is passed, this will be called any time a client receives
a response to a request with the following parameters:

```
callback(err, opts, req, res);
```

and this callback will be called *before* the callback within restify for the
`.write()` or `.read()` method (depending on the type of query).

If a `before` function is passed, this will be called at the beginning of the
`.write()` or `.read()` method in the restify client, before anything is sent to
the server. It will be called with the following parameters:

```
callback(err, opts, req, body);
```

The "opts" parameter here will be the passed API options and can be modified in
the "before" handler. Any of the options specified in https://github.com/restify/clients#api-options
can be changed here before the request is actually made. This is especially
useful for adding or modifying headers in the "before" function.

These changes will allow a caller to do something like:

```
trace_id = uuid();

client.child({
    after: function _afterRequest (err, opts, req, res) {
        // [handle err]

        var code = (res && res.statusCode && res.statusCode.toString());

        req.log.debug({
            error: (err ? true : undefined),
            statusCode: code
        }, 'got response');
    }, before: function _afterRequest (err, opts, req, body) {
        // [handle err]

        opts.headers['trace-id'] = trace_id;

        req.log.debug({
            href: opts.href,
            method: opts.method,
            path: opts.path
        }, 'making request');
    }
});
```

which would add a `trace-id: <trace_id>` header to every outbound request and
would also log the request and response using the request's own bunyan logger.

We will also add an option to the create*Client() option "requiredHeaders"
which would be an array of headers that our begin handler should always be
adding. This allows us to treat it as a [programmer error](https://www.joyent.com/node-js/production/design/errors)
when an outbound request is made without first adding the header. To use this
one would use:

```
var client = restify.createJsonClient({
    ...
    // headers that we should always be setting
    requireHeaders: [
        "request-id",
        "triton-span-id",
        "triton-parent-span-id",
        "triton-trace-enabled"
    ]
    ...
});
```

which would ensure we're always sending the required tracing headers for every
request made by "client".

This would also be used by the "tritonHeaders" option in sdc-clients.

### Modifications to node-sdc-clients

The various clients in node-sdc-clients would be modified such that all of their
restify clients would support the `"tritonHeaders": true` option. When this
option is set, any restify clients created will include the required set of
triton headers in their "requiredHeaders" on creation.

The node-sdc-clients will further be modified such that they also have a
.child() function. This function will take a restify "req" object as its only
parameter. The req is expected to be an object that contains a restify server
request object. This function will:

 * pull out the data required for traceContext from the "req"
 * build a shallow copy of the client itself, but with a .traceContext object
   added containing the information about the request that is required for
   tracing.
 * replace the restify client with a .child() restify client that logs the data
   when making a request and when receiving a response.
 * return the new "contextualized" client object instead of the original client
   object.

When writing a restify handler, one could then create a child of the
application's vmapi handler for example. Any requests made through this child
client would include the trace context for the request being handled so the
headers would be added correctly on these requests and the logs are written out
appropriately.

### Addition of Event Tracing Components for Servers

The prototype at https://github.com/joshwilsdon/evt-tracer will be cleaned up
and moved to https://github.com/joyent. All of the Triton servers will then be
modified to add the tracing handler. This handler will be responsible for:

 * logging all incoming requests and responses
 * attaching a .traceContext to all requests with the trace_id, span_id and
   parent_span_id of the span for the initial request

it will be up to the modifications of the client calls (next section) to ensure
that the headers are added on all outbound requests.

### Modification of Triton Client Calls

All SDC/Triton services which use restify will be modified such that their
clients are used only after being wrapped through the .child() methods. It will
be easy to confirm this is the case since we can use the tritonHeaders option
when creating these clients so it will be an error when they make any requests
that don't include them outbound as well.

The majority of the work here is expected to tbe rearranging the code such that
we have the "req" context wherever we need a client, and modifying so we call
.child() on the sdc-client with that req.

### Modification of cn-agent

The cn-agent agent runs on CNs and has "tasks" which call out and perform
actions requested by SDC/Triton. We will modify this agent such that it includes
trace data in calls to node-vmadm and logs any commands it calls itself on
behalf of requests with the required data to include it in the trace.

### Modification of node-vmadm

The [node-vmadm](https://github.com/joyent/node-vmadm) library is used by
cn-agent to wrap the vmadm tool. It will be modified so that it logs all calls
to vmadm and passes through the trace ids so that vmadm output that contains
traces can be captured and put in the correct format to include in the trace.

### Modification of vmadm

We will modify vmadm such that when the information about the current trace is
passed through from node-vmadm/cn-agent, it will output span logs for every
command it calls so that we have details on how long each executed command takes
to run.

## New APIs

New APIs can be included in the traces by:

 * including the tracer module and instrumenting any restify servers created
 * always accessing restify clients through <client>.child(req)

## Trace Data

### HTTP Request

At an HTTP Request we should have available at least:

 * the client addr + port (peer.addr + peer.port)
 * the HTTP method (http.method, e.g. 'POST')
 * the HTTP path including query string (http.path)
 * the HTTP URL (http://<host>/ -- http.url)
 * the HTTP status code (http.statusCode, e.g. '200')
 * the time the server spent handling the request (http.responseTime)

when available we would also like to include other data such as:

 * the req.timers object from the restify server
 * the restify handler name (e.g. vmapi.updatevm)

every request will also have available:

 * a timestamp on each log entry
 * the name of the service(s) involved (from the bunyan log)
 * the pid of the process(es) involved (from the bunyan log)
 * the hostname of the VM(s) involved (from the bunyan log)

and individual APIs and components will also be able to add additional data to
help identify requests.

### Non-HTTP Actions

Non-HTTP actions such as the execution of a cmdline tool like /usr/sbin/zfs will
not necessarily have all the data an HTTP action will have, but should always
have at least:

 * a number indicating the amount of time spent performing the action
 * a name for the individual action
 * an indication of whether the action was successful or failed
 * the usual timestamp/name/pid/hostname that bunyan gives provides

and may have additional data based on the specific command being executed. Some
examples might be:

 * command line parameters
 * the filter parameters for a moray/ufds request
 * number of retries if something retried before completing / failing

but could include any data that might help the operator understand the behavior
of the system.

## Visualization and Analysis of Data

For the initial version of this work, the data will be logged to the service
logs and be written to Manta through Hermes when it uploads the logs normally
every hour.

A tool will be written which takes a trace\_id/request-id as an argument and
returns the full trace of that request from the manta logs. Additional tools
can be written which take that data as input and pass this on to other systems,
such as POSTing the data to a Zipkin server.

## Examples

### Format of Bunyan Messages

This is an example of what request from sdc-docker to VMAPI could look like
where the "name": "docker" portion comes from the sdc-docker logs and the
"name": "vmapi" portion comes from the vmapi log:

```
    {
      "name": "docker",
      "hostname": "8ba27c76-59f7-43ce-b9a8-2fb9933af21b",
      "pid": 19119,
      "level": 30,
      "evt": {
        "kind": "client.request",
        "operation": "restifyclient.POST",
        "parent_span_id": "9b382e4e-71a6-4af0-a450-afdf9552e891",
        "span_id": "885465f8-9b6b-4f86-96a0-7c6eb799edd5",
        "trace_id": "3a2de950-23bc-11e6-9a99-512596e640ec",
        "tags": {
          "http.method": "POST",
          "http.path": "/vms/4a522c12-3c91-4eea-86de-df3b4920a155?action=start&owner_uuid=3f96f921-f544-4ee0-b4b2-11e7fa5e2445&sync=true&idempot",
          "http.url": "http://vmapi.coal.joyent.us/"
        }
      },
      "msg": "",
      "time": "2016-05-27T03:36:41.957Z",
      "v": 0
    }
    {
      "name": "docker",
      "hostname": "8ba27c76-59f7-43ce-b9a8-2fb9933af21b",
      "pid": 19119,
      "level": 30,
      "evt": {
        "kind": "client.response",
        "operation": "restifyclient.POST",
        "parent_span_id": "9b382e4e-71a6-4af0-a450-afdf9552e891",
        "span_id": "885465f8-9b6b-4f86-96a0-7c6eb799edd5",
        "trace_id": "3a2de950-23bc-11e6-9a99-512596e640ec",
        "end": true,
        "tags": {
          "http.statusCode": "202"
        }
      },
      "msg": "",
      "time": "2016-05-27T03:36:58.091Z",
      "v": 0
    }
    {
      "name": "vmapi",
      "hostname": "07bf44db-2029-47da-aa13-df7625d21055",
      "pid": 20433,
      "level": 30,
      "evt": {
        "kind": "server.request",
        "operation": "vmapi.updatevm",
        "parent_span_id": "9b382e4e-71a6-4af0-a450-afdf9552e891",
        "span_id": "885465f8-9b6b-4f86-96a0-7c6eb799edd5",
        "trace_id": "3a2de950-23bc-11e6-9a99-512596e640ec",
        "tags": {
          "peer.addr": "10.192.0.39",
          "peer.port": 59020
        }
      },
      "msg": "",
      "time": "2016-05-27T03:36:41.958Z",
      "v": 0
    }
    {
      "name": "vmapi",
      "hostname": "07bf44db-2029-47da-aa13-df7625d21055",
      "pid": 20433,
      "level": 30,
      "evt": {
        "kind": "server.response",
        "operation": "vmapi.updatevm",
        "parent_span_id": "9b382e4e-71a6-4af0-a450-afdf9552e891",
        "span_id": "885465f8-9b6b-4f86-96a0-7c6eb799edd5",
        "trace_id": "3a2de950-23bc-11e6-9a99-512596e640ec",
        "tags": {
          "http.statusCode": "202"
        }
      },
      "msg": "",
      "time": "2016-05-27T03:36:58.073Z",
      "v": 0
    }
```

## Future Enhancements

This section is for things that have been partially thought through but will not
be part of the initial implementation of this feature.

### Allowing Whitelisted Users

An enhancement that has been requested is the ability to pass 'trace-id' header
for whitelisted users to cloudapi/sdc-docker, so that clients using cloudapi in
on-prem installations who may eventually have access to the logs can pass in an
id which they can use when looking for these logs later.

### Enabling on Error

One idea that came out of previous discussion was that in some cases we'd like
to be able to turn tracing on based on a condition. For example: if we notice
part-way through the trace that there's a request that's slow, it would be nice
to be able to turn on tracing at that point for at least the rest of the current
request (what data we have) and for all remaining requests.

Since we're passing through the headers indicating which trace a request belongs
to, we'll at least be able to keep further requests together and just set
triton-trace-enabled for the next calls. However it's also possible that we
should just be tracing all requests that we might care about at the
log-to-bunyan level and instead just put an additional entry in the log for
known outliers that highlight them or otherwise send them to another system for
further analysis.

More discussion on this point is likely required.

### Manta Jobs/Triggers

At some point it would be nice to be able to have something run in manta that
can take the logs that are uploaded and output a single file for each trace.
Whether this is done with triggers or some job that runs in manta once all the
data is uploaded the idea here would be to have something that looked like:

```
 .../traces/<uuid>.json
```

where <uuid> is the UUID of a trace-id.

### Additional Tracing

One suggestion for future work was that we use "isenabled" probes and DTrace in
order to be able to turn on additional logs and/or tags for traces.

### Realtime Tracing

Another suggestion for future work was that we have an additional flag which
indicates that we want something to be a "realtime trace" and that data to be
sent to some external system in realtime.

If after a future RFD, data is going in realtime to an external system, it will
be possible for the client to use the request-id they're returned in order to
lookup this data in that external system soon after the request has completed.

## Open Questions

### Manta

This document describes tracing for Triton only. If tracing for Manta is
required, is it acceptable that this be a separate RFD?

### Sampling

Many distributed tracing systems allow for sampling, where only a fraction of
the requests are traced. In general we would like to avoid this in order that we
catch outliers since those are suspected to be issues we want to focus attention
on. However there could be cases where we do not expect that tracing every
request is useful. One example is GET requests to a /ping endpoint which tend to
have very little going on in the handler and also tend to be queried frequently
enough that the cost/benefit is likely not high enough to log every request.

When this is the case, clients should have some option to take a set of
endpoints for which we will set the triton-trace-enabled false for all but some
fraction of calls. We currently expect that this would be implemented as a
probability between 0 and 1.

The open question here is whether this support needs to be in the initial
version or whether this can be a future enhancement.

### Translating existing vmadm messages

With [OS-3902](https://github.com/joyent/smartos-live/commit/d73d040) some
initial experimental support was added to vmadm to log event messages. We will
investigate whether there's some way to include some of these messages from old
platforms in traces while we modify vmadm to log in the new format.

