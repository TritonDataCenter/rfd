---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
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

### Trace

Every user initiated request that comes into Triton starts an associated
"trace." The trace represents the initial request combined with all other
actions taken in order to satisfy that request. This can include: further
requests, execution of commands, or any other work a program has been
instrumented to expose. These individual components of work are called spans
(see below).

### Span

Every individual action performed can be considered a span. For example any of:

 * a client request
 * a server handling a single request
 * execution of a function

would be represented by a span. Each of these spans has at least a start and an
end point but may also have other points logged through the course of execution.

NOTE: See [Open Questions](#OpenQuestions) section below for discussion on
another option here which was also used in previous versions of this RFD.

It is also common for a span to create additional child spans. Given an example
of an HTTP request, the most common case would be the server calling other APIs
after receiving a client's request, but before responding to it. In that case
those new requests are considered separate new spans, but the current span (the
one handling the client's request itself) is attached to those through what we
call "parent span id" which is just the identifier of the span that created this
new span. By creating parent-child relationship for each span after the initial
user request, the trace becomes a tree.

### Logs / Events

As each individual events on a span is written out, it is called a log.
As mentioned above most spans have at least 2 logs one for the start of the span
and one for the end. Logging requires at least a name for the event.

### Tags

What Dapper calls "Annotations", OpenTracing.io calls Tags, and we'll use that
terminology here. This is basically just a set of key/value pairs that are
attached to a span in order to add additional data about the span. This data can
be added at any point in a span which means it's easy to add tags at the point
that the data is available.

Examples of things that might be tags include:

 * the HTTP method for the request
 * the IP address of the remote host
 * the query string for a request
 * the HTTP status code for a response

See "Open Questions" section for some discussion about alternative layouts for
spans.

## Goals

### Questions this system should be able to answer

The primary focus of this work is to ensure that it is possible to trace the
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

Moving things like the individual headers we use into the libraries also allows
us to change these without modification to application code. Application code
needs to have instrumentation turned on once and then the library handles all
the details. If we want to change so that tracing goes to a separate 3rd party
system we should be able to do that without further modification to the
application code.

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

This section describes the solution proposed to gather the information required
to achieve the goals laid out above.

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
   parent span identifier (parent\_span\_id) and create a new span which is a
   child of that span. When a request does not include this, the new span is
   considered a root span.
 * It will be an error to include triton-span-id and not include a request-id or
   x-request-id header.
 * For every restify route handled, we generate a single bunyan log.
 * For every restify client request (usually through node-sdc-clients) we will:
     * add a request-id header which matches the trace\_id of this trace
     * add a new triton-span-id header for this new span (client requests are
       always a new span)
     * add a parent span property which matches the span\_id of the span
       that is causing the request to be made.
     * pass through the the triton-trace-enabled and triton-trace-extra headers
       unmodified.
 * If triton-trace-enabled is 1, each span.log will result in a span being
   written to the bunyan logger. If it is 0 or unset, span.log will be a no-op.

## Planned Implementation (Option A)

The implementation of this work will consist of several parts:

1. modifications to restify-client to support .child()
2. modifications to node-sdc-clients to support .child()
3. creation of an opentracing implementation for Triton
4. addition of the event tracing components to all Triton restify servers
5. modification of all Triton client calls to us sdc-client child()
6. modification of cn-agent
7. modification of node-vmadm
8. modification of vmadm
9. modification of node-moray

### Modifications to restify-clients

We will add a `.child()` method to restify clients. This will be called as:

```
client.child({
    afterSync: function onAfter() {
      // code that runs after a response is received
    },
    beforeSync: function onBefore() {
      // code that runs before anything is sent to the server
    }
})
```

where all `after` and `before` are optional.

If an `after` function is passed, this will be called any time a client receives
a response to a request with the following parameters:

```
onAfter(err, req, res, ctx);
```

and this callback will be called *before* the callback within restify for the
`.write()` or `.read()` method (depending on the type of query).

If a `before` function is passed, this will be called at the beginning of the
`.write()` or `.read()` method in the restify client, before anything is sent to
the server. It will be called with the following parameters:

```
onBefore(opts, ctx);
```

The "opts" parameter here will be the passed API options and can be modified in
the "before" handler. Any of the options specified in https://github.com/restify/clients#api-options
can be changed here before the request is actually made. This is especially
useful for adding or modifying headers in the "before" function.

These changes will allow a caller to do something like:

```
trace_id = uuid();

client.child({
    afterSync: function _afterRequest (err, opts, req, res) {
        // [handle err]

        var code = (res && res.statusCode && res.statusCode.toString());

        req.log.debug({
            error: (err ? true : undefined),
            statusCode: code
        }, 'got response');
    }, beforeSync: function _beforeRequest (opts) {
        // [handle err]

        opts.headers['request-id'] = trace_id;

        req.log.debug({
            href: opts.href,
            method: opts.method,
            path: opts.path
        }, 'making request');
    }
});
```

which would add a `request-id: <trace_id>` header to every outbound request and
would also log the request and response using the request's own bunyan logger.

We will also add an option to the create*Client() functions "requiredHeaders"
which would be an array of headers that our begin handler should always be
adding. This allows us to treat it as a [programmer
error](https://www.joyent.com/node-js/production/design/errors) when an
outbound request is made without first adding the header. To use this one would
use:

```
var client = restify.createJsonClient({
    ...
    // headers that we should always be setting
    requireHeaders: [
        "request-id",
        "triton-span-id",
        "triton-trace-enabled"
    ]
    ...
});
```

which would ensure we're always sending the required tracing headers for every
request made by "client".

This would also be used by the "tritonHeaders" option in sdc-clients that
passes all these options.

NOTE: There's a preliminary prototype of these modifications to restify-clients
in https://github.com/joshwilsdon/restify-clients in the "upstream" branch
which has also been submitted upstream as:

https://github.com/restify/clients/pull/77

though the current state is that this PR is stalled on some decisions around
alternative implementation options (discussed further below).

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

### Creation of an OpenTracing implementation for Triton

In order to use [the opentracing javascript
library](https://github.com/opentracing/opentracing-javascript) we need to
create an "implementation". This implementation will be plugged into the
opentracing tracer.

All of the Triton servers will then be modified to add the tracing handler.
This handler will be responsible for:

 * logging all incoming requests and responses
 * attaching the data for a span to all `req` objects

it will be up to the modifications of the client calls (next section) to ensure
that the headers are added on all outbound requests.

NOTE: there are some experiments (with examples) of this at:
https://github.com/joshwilsdon/triton-tracer

#### Alternative

Instead of creating an opentracing implementation and using the
opentracing-javascript library, we may also want to just create our own tracing
implementation and skip opentracing. The reason for this is that
opentracing-javascript is pretty unstable (several times minor and even patch
versions have changed the API) and the implementation is also fairly complex.
Also what we're using of it is pretty minimal. It seems that a much simpler
implementation is possible which would also make it much easier to debug. If we
created a new module that exposed the same basic API as opentracing, it seems
we'd potentially be much better off.

The opentracing-javascript library also does things like for example "minifying"
some of the source which makes it very difficult to look at in mdb with
`::jssource` or `::jsstack -v`.

The biggest risk of doing our own thing w/o using the official
opentracing-javascript would be that if OpenTracing really takes off and we want
to use some community components that only work with OpenTracing and somehow
don't work with our implementation that could be a problem. Since all the
tracing is independent of the APIs however, it still seems like this sort of
change would be possible to do in one place (triton-tracer) and not require
anything more than an update to the APIs. Worth more discussion however on
pros/cons.

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

The [node-vmadm](https://github.com/TritonDataCenter/node-vmadm) library is used by
cn-agent to wrap the vmadm tool. It will be modified so that it logs all calls
to vmadm and passes through the trace ids so that vmadm output that contains
traces can be captured and put in the correct format to include in the trace.

Note that the vmadm output will be parsed after the completion of the vmadm
command, which is then used to generate tracing event information.

### Modification of vmadm

We will modify vmadm such that when the information about the current trace is
passed through from node-vmadm/cn-agent, it will output span logs for every
command it calls so that we have details on how long each executed command takes
to run.

### Modification of node-moray

The node-moray module will be modified such that we are able to trace between
request and response for each moray request at least on the client side. Ideally
this will also include information about which moray instance handled the
request.

### New APIs

New APIs and services can be included in the traces by:

 * including the tracer module and instrumenting any restify servers created
 * always accessing restify clients through <client>.child(req)


## Planned Implementation (Option B)

After working for a while on the prototype of "Option A" above, I learned about
something called continuation-local-storage. This lead to prototyping an
alternative implementation with a number of very nice features but a few new
problems.

To implement this option we'd need:

1. modifications to restify-clients but no need for .child()
2. modifications to node-sdc-clients to use modified client
3. creation of an opentracing implementation for Triton (same as above)
4. very minimal modifications to existing Triton services
5. modification of cn-agent
6. modification of node-vmadm
7. modification of vmadm
8. modification of node-moray

### Brief overview of the "CLS" functionality

When using the continuation-local-storage module or any of the
AsyncListener/async_wrap/async_hooks implementations, the fundamental idea is to
add hooks (init/before/after) to all functions that queue async work to the
event loop such that we can keep track of the entire callchain even across
asynchronous events. Combining the mechanism that keeps track of the calls (via
an id) and some some storage that's associated with that continuation chain,
it's possible to store data in this "continuation local storage" instead of
having to pass data through every intervening method and manually passing things
across async calls using closures.

For further investigation, some links (in no particular order):

 - [AsyncWrap Tutorial](http://blog.trevnorris.com/2015/02/asyncwrap-tutorial-introduction.html)
 - [Node.js – Preserving Data Across Async Callbacks](https://datahero.com/blog/2014/05/22/node-js-preserving-data-across-async-callbacks/)
 - [Conquering Asynchronous Context with CLS](http://fredkschott.com/post/2014/02/conquering-asynchronous-context-with-cls/)
 - [node-continuation-local-storage (github)](https://github.com/othiym23/node-continuation-local-storage)
 - [async-listener (github)](https://github.com/othiym23/async-listener)
 - [cls-hooked (github)](https://github.com/jeff-lewis/cls-hooked)
 - [How we instrument node.js (Opbeat)](https://opbeat.com/community/posts/how-we-instrument-nodejs/)
 - [Talk by Forest Norvell (2014)](https://www.youtube.com/watch?v=xyjvFBTyFSE)
 - [https://github.com/nodejs/diagnostics/tree/master/tracing/AsyncWrap](AsyncWrap doc from the WG)
 - [Updated async_hooks API (proposed)](https://github.com/nodejs/node-eps/blob/e35d4813fdbbd99a751296e24361dba0d0dd9e10/XXX-asyncwrap-api.md) (from: [PR 18](https://github.com/nodejs/node-eps/pull/18]))
 - [pull request that adds support for async_hooks](https://github.com/nodejs/node/pull/8531)

### Modification to restify-clients

The modifications required for restify-clients would be much the same as with
Option A with one important exception. Unlike Option A, we can distinguish
between requests without passing through the req object to each call. As such,
there's no need to have a .child() object created for each client. Instead the
original clients themselves can have a .beforeSync and .afterSync option which
has the added benefit that in core files the objects will be "real" restify
client objects instead of generic cloned objects that behave like restify
clients.

### Modifications to node-sdc-clients

The modifications to sdc-clients in Option B are minimal. The only changes
required will be to change the require statements so that a wrapper is called
for the create*Client functions that adds the beforeSync and afterSync options.
In the prototype, this happens via a wrapper that lives in the triton-tracer
repo. As with restify-clients, objects created here will not need a .child()
for Option B and will be "real" sdc-clients objects.

### Creation of Opentracing implmentation

This work would be almost exactly the same as with Option A. Only a few minor
changes are required to use the CLS mechanism(s) for passing the traces instead
of the req objects.

See also "Creation of an OpenTracing implementation for Triton" section in
Option A above.

### Modification to existing Triton services

This is the point where Option A and Option B differ the most. With Option B,
adding tracing to an existing service or a new service will require adding just
a few lines of code and should not require any modification to handlers, just
initialization. As such, far fewer files are modified and the integration is
*much* easier.

### Modification of cn-agent, node-vmadm, vmadm and node-moray

The modification of these will be the same or easier than with Option A.
Definitely no harder.

### Additional complications of Option B

All the points above make Option B seem like the clear choice and indeed this
functionality was designed exactly for the sort of use-case we're trying to use
it here. But there are some additonal complications this option brings which
leave Option A on the table.

The biggest decision to make here between the Option A and Option B is whether
we can find an acceptable way to use the CLS/AsyncListener/AsyncWrap/AsyncHooks
functionality. This depends somewhat on which version of node we'll be shipping
too. The current state of affairs follows...

### Advantages of Option B

It's hard to overstate how much less intrusive Option B is vs Option A for
existing code. For Option A: *a lot* of functions need to have to be modified
including *a lot* of function prototypes. This is required because when we
currently have a handler(req, res, next) for an endpoint, that handler often
does not pass the `req` object to the backend that's actually going to deal with
the request. In those cases, we need to modify all functions that the handler
calls, and all functions that those functions call until `req` is passed to
every function that might ever need to make an outbound request to handle the
request or might perform any local work (which is basically everything).

Changing so many functions across so many files is both tedious and dangerous.
It also makes the code more brittle since any additional function that gets
added may accidentally break tracing if it doesn't pass the `req` through
everywhere. The `req` is needed since that's the object we've got the span
context tied too (since we need one for each request we're handling).

With Option B we can avoid all these modifications. The modifications to
existing code and new code are very minimal. Most likely this will require the
addition of less than 10 lines of code plus modification of some includes. The
rest of the code will not be modified and it should be much easier to avoid
accidentally introducing new bugs.

#### node v0.10

Almost everything that would be traced is at the time of this writing
(2016-10-19) using node v0.10.x even though this version was intended to be EOL
at the beginning of October 2016 and was extended to the end of October 2016
due only to a mistake. So it seems reasonable to think that everything will
need to move to at least v4.x in the timeframe that tracing is ready to be
rolled into master. As such, it could be quite reasonable to require moving to
v4.x to have tracing enabled.

If for some reason this is *not* the case, we can also use the
[node-continuation-local-storage](https://github.com/othiym23/node-continuation-local-storage)
module which uses [async-listener](https://github.com/othiym23/async-listener)
which polyfills the v0.11 AsyncListener API for node v0.10, though this is
sub-optimal for a number of reasons including a large number of monkey-patches
to node core APIs.

#### node v4.x

Node versions 4.5+ can use the
[cls-hooked](https://github.com/jeff-lewis/cls-hooked) implementation of the
CLS pattern. This has exactly the same API as node-continuation-local-storage
(it was forked from this) but implements using
[async-hook](https://github.com/AndreasMadsen/async-hook) instead which uses
node's built-in async_wrap functionality and only a few monkey-patches.

There's also new async hooks functionality that's being worked on via [a PR in
the tracing WG](https://github.com/nodejs/node/pull/8531) that might be
backported to v6 and v4 when it's done. That would allow for even fewer (perhaps
none?) monkey patches with this same functionality.

### Option A vs Option B

Option B seems nicer in almost every way from the perspective of just updating
an individual service. There are far fewer changes required to instrument a
service and implementing in a new service will also be trivial. The biggest
challenge for Option B however is working out a way to do this that's going to
be acceptable with regard to debugging and performance. Experimentation in this
area is ongoing.

## Trace Data

### HTTP Request

At an HTTP Request we should have available at least:

 * the client addr + port (peer.addr + peer.port)
 * the HTTP method (http.method, e.g. 'POST')
 * the HTTP path including query string (http.path)
 * the HTTP URL (http://<host>/ -- http.url)
 * the HTTP status code (http.status_code, e.g. '200')
 * the time the server spent handling the request (http.response_time)

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

As part of the prototype, I've written a very quick tool called "ziploader":

https://github.com/TritonDataCenter/ziploader

which can upload traces with a small delay to a zipkin server. This works by
running in the GZ after being pointed at a zipkin instance and watching the logs
on the node. As log messages come in about spans, these are batched up and
pushed to zipkin.

## Open Questions

### Manta

This document describes tracing for Triton only. If tracing for Manta is
required, is it acceptable that this be a separate RFD?

### Breaking down Spans

When this work was started, we assumed that we'd want Zipkin-like spans where we've got the client
and server portions for an individual request as part of the same span.
OpenTracing seems to guide implementers toward instead treating the components
that occur on separate systems as separate spans. The difference here would be:

Zipkin-style:

```
 TRACE X
  \_ SPAN Y
      \_ [client] send request
      \_ [server] receive request
      \_ [server] send response
      \_ [client] receive response
```

Opentracing-style:

```
 TRACE X
  \_ SPAN Y
      \_ [client] send request
      \_ [client] receive response
      \_ [child of Y] SPAN Z
          \_ [server] receive request
          \_ [server] send response
```

in both cases we would still be able tie things together. The difference is just
whether these events are part of one or 2 spans. This also in turn impacts the
scope of tags and the operation name of the span.

The biggest reason I can see that we might want to go with Opentracing-style is that we
can add a tag `component` that indicates `restifyclient` or `restifyserver`
potentially also with a tag for version. It also simplifies implementation
somewhat since you're *always* creating a new span and never trying to continue
a span.

If there are strong arguments for Zipkin-style, we can reconsider.

### Data propagation

See also the Planned Implementation sections above and specifically the section
on "Option A vs Option B". We need to make a decision on this before any changes
are merged to master. If we're going with Option A, then that mostly excludes
Option B from being as useful (since all code changes that Option A requires
will have already been completed removing much of the benefit of Option B). If
we're going with Option B, we'll need to figure out a working mechanism for that
that's acceptable to Joyent Engineering.

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

How I expect this would work is that when starting a new trace (i.e. entrypoint
into triton whether this is as a client or server) a set of criteria can be
passed in which indicate probabilities that a given trace should be enabled or
not. For most endpoints I expect that the probability would be 1, meaning trace
always. But for others (/ping especially) we might want a much smaller
probability. When the entrypoint decides it sets the triton-trace-enabled flag
which gets passed along to all other services down the stack.

When a service receives a message, it always passes along the headers even when
the tracing is disabled. This ensures that other logs still contain the correct
request-id per the Joyent Engineering Guidelines and if something crashes we'll
be able to still track it back to which request by pulling that data out of the
core dump. The only difference between triton-trace-enabled true and false will
be whether the traces get written out when span.finish() is called.

### Translating existing vmadm messages

With [OS-3902](https://github.com/TritonDataCenter/smartos-live/commit/d73d040) some
initial experimental support was added to vmadm to log event messages. We will
investigate whether there's some way to include some of these messages from old
platforms in traces while we modify vmadm to log in the new format.

### Volume of data

Since this tracing will be writing out a lot of data, we should do some
investigation into how acceptable this will be. Suggested plan of attack here is
to look at existing logs from Triton and use existing numbers of requests for
various services combined with prototype numbers of logs per request to
determine how much additional data this might be.

Preliminary testing of the sdc-docker zone using the sdc-docker test suite on
19th Dec 2017 (running 1500 tests) in COAL showed a doubling of log file size:

    -rw-r--r--  1 root root  7,002,769 Dec 18 21:53 docker-testsuite.log
    -rw-r--r--  1 root root 13,567,770 Dec 18 23:59 docker-testsuite-rfd35.log

If at some point we determine that this will be too much data to write to disk,
we should be able to change the target of the data by adding a separate bunyan
log backend that sends the data somewhere other than the disk. A previous
experiment had created:

https://github.com/joshwilsdon/effluent-logger

which plugs into bunyan and sends messages to fluentd. We could have these go to
some other system in a simlar manner and not write them to local disk.

### Performance impact

Preliminary testing of the sdc-docker zone using the sdc-docker test suite on
19th Dec 2017 (running ~1500 tests) in COAL showed around 7% performance
penalty, where all triton components had rfd-35-cls tracing enabled:

    # No RFD 35 test results:
    # Completed in 3144 seconds.
    # PASS: 1574 / 1574

    # RFD 35 cls test results:
    # Completed in 3360 seconds.
    # PASS: 1574 / 1574

### Impact on post-mortem debugging

A question came up about how using CLS (assuming we're going with Option B for
implementation) would impact debugging using post-mortem debugging.

After some discussion internally, it seems that it is unlikely that CLS will
have any impact on post-mortem facilities, especially if care is taken to fork
libraries where required to not catch exceptions. The libraries investigated so
far do sometimes catch exceptions, but a fork has already been created that does
not and this will not impact our ability to use them at all.

The facilities themselves in node here also should not lead to any new
complications for debugging using mdb.

One complication if we implement this functionality using Option A is that
because we're cloning objects, the JsonClient and StringClient and HttpClient
objects from restify would show up with a prototype of Object instead of
JsonClient in mdb. This problem is eliminated using CLS since no object cloning
is involved. With CLS/Option B, we'll also not need to create a clone for every
used client for each request.

### Feature flag

In order to deal with many of the non-specific or yet undeveloped concerns
people have mentioned about tracing with regard to post-mortem debugging,
performance and other impacts on Triton components one proposed option has been
to add a "feature flag" which allows tracing to be fully disabled as a
configuration option. With the tracing feature disabled, the system should
behave the same as it would have without tracing support and ideally the only
code run would be the init function (which would setup to make other trace
initializers be no-ops).

When confidence is gained in the feature, support for disabling tracing could be
removed.

This feature flag feature itself has also proven controversial. The argument
against doing so is that we'd need to test both with and without the feature
flag. This may be mitigated somewhat by the fact that the code without the
feature is a subset of the code with the feature and there's no *different* code
run with the feature disabled, just less total code. But it is still something
worth mentioning here.

## Status

### Prototype Status

Several prototypes have been made and some discarded or in various stages of
completion. The currently actively worked-on prototype is in the rfd-35-cls
branch. The goal of this prototype is to prove that the CLS feature described
above can work for our tracing. This only supports APIs that have moved to node
v4 so some APIs cannot yet use this.

Experience has shown that these tracing features are easier to make work with
when work starts at the top and works down. This is because we can get quick
feedback on whether tracing is working at the top level with large chunks of
work and break those larger chunks into smaller and smaller spans as we go down
the system. A request to sdc-docker for example for containerlist will show at
the top level how much time it spent talking to vmapi and other APIs, and then
when we add support to vmapi we can see what *that* was doing and so on.

Currently status of prototype:

 * cloudapi
     * status: mostly complete and working

 * cn-agent
     * status: not started

 * cnapi
     * status: partially implemented, but working

 * docker
     * status: mostly complete

 * fwapi
     * status: not started, needs update to v4

 * imgapi
     * status: mostly complete

 * napi
     * status: not started, needs update to v4

 * papi
     * status: mostly complete

 * vmapi
     status: mostly complete

 * workflow
     status: initial work started based on WORKFLOW-213 branch which updates workflow to v4.


The above lists all of the components that are expected to be complete for the
MVP of this feature, though it's possible that if fwapi and napi are not updated
to node v4 they can be left out until later.

