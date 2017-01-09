---
authors: Dave Pacheco <dap@joyent.com>
state: publish
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 33 Moray client v2

## Overview and motivation

Most SDC and Manta services store and access persistent state using the Moray
service, a Node.js-based key-value interface built atop PostgreSQL.  Moray
provides a Node.js client library that accesses the Moray server using the Fast
RPC protocol.  While this works well in the happy case and tolerates some kinds
of failures, there are several issues with the Moray and Fast client libraries
that cause, exacerbate, or prolong service outages:

* Service discovery: as we configure it today, Moray clients identify servers
  by DNS hostnames, and the Moray client uses DNS "A" records to locate servers.
  The client assumes that the server is listening on port 2020 on all IP
  addresses found in DNS.  This makes scaling a single Moray container to
  multiple processes tricky.  Historically, we deploy an haproxy instance inside
  the container to listen on port 2020 and forward connections to a variable
  number of Moray processes, but this has its own serious downsides: haproxy is
  an additional component to monitor, it makes it more complex to debug
  connection issues, it scales poorly with the number of connections because of
  its use of poll(2), and we have observed significant performance problems
  resulting from poor distribution of load across the backend processes.  See
  [MORAY-263](https://devhub.joyent.com/jira/browse/MORAY-263) for details.
  This is similar to problems we have using haproxy to front with several other
  services, including muskie and electric-moray.  The
  [cueball](https://github.com/arekinath/node-cueball) module aims to provide
  facilities for DNS-based discovery using "SRV" records, falling back to "A"
  records using a default port.  (Cueball also provides significantly improved
  semantics with respect to resolver failure than the system resolver currently
  provides, though the Moray client does not currently use the system resolver.)
* Connection management robustness: the Moray client is a relatively thin
  wrapper on top of the Fast client.  The Fast client attempts to manage
  connection failure by noticing when connections are no longer readable or
  writable and terminating them.  The Moray client then replaces the broken Fast
  client.  However, the design is subject to races that are not easily resolved.
  Specifically, if a connection seems readable or writable but a subsequent I/O
  operation fails due to a network error (e.g., ETIMEDOUT, ECONNRESET, or the
  like), then the Fast client emits an error that gets propagated out of the
  Moray client.  It's incorrect for most server programs to be watching for
  'error' from the Moray client (since there's no reason the Moray client should
  come to rest in a failed state), so this crashes correctly-written servers.
  See [MORAY-309](https://devhub.joyent.com/jira/browse/MORAY-309).
* Connection scalability: the Moray client currently establishes a fixed number
  of connections to every IP address found in DNS.  This results in
  O(N<sup>2</sup>) connections, which is not just unhelpful, but problematic in
  large deployments.  Cueball can address this issue by providing a more
  appropriate policy for the number of connections to maintain to which IP
  addresses.

## Design goals and constraints

This RFD proposes updating the Fast and Moray clients to better manage service
discovery and connection management in order to address these problems.  The end
result should be that if a server (like Muskie) instantiates a Moray client
using a DNS hostname for a particular Manatee shard:

* The Moray client will locate instances of the server via DNS and establish a
  small pool of connections to each server.
* The connection pool may grow in size according to the client's request load,
  up to a predefined limit.  New connections may be distributed across multiple
  instances.
* When a server is removed from DNS, the Moray client will notice this and stop
  using it within a few minutes.
* When a server is added to DNS, the Moray client will notice this and start
  using it within a few minutes.
* When any connection is terminated unexpectedly, the Moray client will attempt
  to replace it by establishing a new connection, either to the same or a
  different instance of the server (based on the instances registered in DNS).
* When any connection establishment fails, the Moray client will retry using
  exponential backoff to avoid overwhelming Moray instances.
* Continued service should not be affected by either transient or extended
  outages of any number of DNS resolvers.  Explicit errors or timeouts should
  only result in delays propagating changes from DNS; they should not affect
  existing established connections.  As long as any resolver is functioning,
  updates to the list of server instances should continue to work, possibly with
  additional delay.

One-shot command-line utilities that use Moray clients should continue to be
supported, with basically the same behavior except that it's not necessary for
DNS to be re-checked (but it's okay if it is).

As part of this work, we would like to also build:

* Documentation for the Fast protocol and Fast client.  The protocol itself is
  not well-specified.
* A more robust test suite for the Fast client and server.
* Command-line tools for exercising and monitoring the Fast client and server.
* First-class the Fast and Moray Node modules: these should be versioned with
  semver, published in npm, and contain CHANGES.md documents that describe at
  least breaking changes.

On performance: as described below, many additional problems were found in the
Moray and Fast clients, and fixing them is likely to increase the overhead of
these components.  However, the changes implemented in this proposal must not
significantly increase synchronous RPC latency, decrease synchronous RPC
throughput, or prevent the system from scaling linearly with additional
concurrency for asynchronous requests (i.e., whose processing time is dominated
by off-CPU time), as long as the server is not saturated.

On compatibility: the primary deliverable is an updated version of the Moray
client that will be nearly a drop-in replacement for the existing module, but
with better service discovery and connection management properties.  Callers
may need to supply updated configuration to take full advantage of these
improvements.  We assume the node-fast interfaces can be changed freely (see
below), and we expect to make two incompatibles change to the Moray client
(described in detail below).


## Changed and affected components

The starting points for these components are:

* [node-moray](https://github.com/joyent/node-moray): moray client library and
  command-line client tools
* [node-fast](https://github.com/mcavage/node-fast): fast client and server
  library (used by node-moray; consumers do not use these directly).

These repositories will see new major versions as part of this project.  We
will move node-fast to the "joyent" github organization.  This project will be
the first consumer of a [small node-verror project to support properties on
Errors](https://github.com/davepacheco/node-verror/issues/10).

**node-fast changes and impact:** node-fast provides both a client and server
interface.  The client interface is used only by the Moray client, and the
server interface is used only by the Moray server.  We expect to make breaking
changes to the node-fast module and release that under a new major version.
Existing Moray servers and clients will be unaffected by this.  We will move
the Moray client to the updated Fast client as part of this project.  **The
Moray server should be updated to use the new Fast server interface, but not as
part of this project.**

**node-moray changes and impact:** node-moray provides only a client interface,
but it's used by many different components.  In Manta, the node-moray client is
used by Muskie (through node-libmanta to access the metadata tier, through the
"picker" to access metadata about the "storage" tier, and through the Marlin
client to access job metadata), the Marlin jobsupervisor, the Marlin agent,
Minnow, Medusa, and command-line tools like mlocate.  Many SDC services also use
node-moray.

The node-moray changes will include two breaking changes described below and
will be released under a new major version.  Existing node-moray consumers will
be unaffected until they opt into the new version, at which point they will
want to ensure they're not affected by the breaking change.  The configuration
will be backwards-compatible, but a new set of configuration properties will be
provided to make it improve default behavior.

## End user impact

End users and operators don't interact with these components, so there is no
impact on them (other than operator observability).

## Security impact

These components are not directly exposed to untrusted users, and the programs
that use them are responsible for ensuring the validity and integrity of data
both sent and received.  Neither Moray nor Fast supports any form of
authentication, let alone authorization.  However, since these components are
directly attached the network and so communicate across fault domains, it's
critical that they validate input that arrives over the network and treat
invalid input as an operational error.

When a Fast client or server receives any kind of malformed or unexpected
message, the connection should be terminated and any outstanding requests should
be failed with an error that reflects the underlying protocol error.  Such
cases would include: unexpected errors when reading or writing from the socket,
messages with incorrect checksums, unexpected end-of-file, messages that
duplicate message ids that are still in use, or any other kind of protocol
error.  Both the client and server will have test suites that validate this
behavior.

To catch programmer errors as soon as possible, the Moray and Fast clients will
attempt to validate requests before they're made (e.g., that required parameters
are passed and have the correct types).

### Compatibility and upgrade impact

The basic constraints are laid out above.  In summary, the Fast client and
server library interfaces are expected to change incompatibly.  The Moray
client will be drop-in compatible except for one uncommon case that
necessitates a major version bump and a default behavior change that can be
configured to work the old way (both described below).  Thus, all consumers of
both will have to opt into the new versions, but the expectation is that this
will be trivial for node-moray consumers.

Although the Fast client will get a major version bump, the protocol itself is
not being changed.  As a result, there should be no issue if either servers or
clients are upgraded in any order after this change.  To verify this, the new
Fast version will have tests that exercise behavior against the
currently-deployed Fast server version.

#### Explicit breakage: Moray versioning

During development, it was determined that the `version` RPC call cannot
reasonably be used programmatically, so it has been removed from the
documented, public interface.

Versioning Moray is hard because the Moray client interface uses pooled
connections.  There is no interface to run an RPC against a particular server
instances, nor all server instances, nor to ensure that subsequent requests go
to the same instance as previous requests.  As a result, asking whether the
server is at version N means effectively nothing.  The next request may hit a
server at some previous version.  Even if you execute `version()` and get back
the expected `N`, the server at version N may be immediately removed from the
pool.  (In the presence of electric-moray, where clients make a normal Moray
connection to electric-moray, which itself maintains many backend connections
that may be used depending on the sharding key, it's not even safe to assume
that multiple requests made over the same TCP connection will wind up hitting
the same server instance.)

Robust versioning would require that consumers specify which server version is
required on either a per-request or a per-client basis, and the Moray client
would be responsible for both identifying the version of each server instance
and funneling requests to appropriate server instances.  (Electric-moray would
have to provide similar behavior.)  Identifying the version for each service
instance is itself extremely tricky because of
[MORAY-336](https://devhub.joyent.com/jira/browse/MORAY-336).  Details on that
are below.

The only consumer in SDC or Manta that appears to use this option is NAPI, which
needs to find a more robust approach to ensuring that Moray supports the
necessary facilities.

It may still be useful to use the "version" RPC against individual server
instances so that a human can identify those which need to be upgraded.  This
functionality is provided by the `morayversion` tool, which uses a now-private
RPC call.  While the previous implementation of this RPC had a short timeout and
interpreted a timeout to mean that the server is running version 1 (because of
MORAY-336), the new version uses a generous timeout and reports a timeout error
on failure, with a note indicating that the cause _may_ be an ancient Moray
version.

For reference, here are the revisions of Moray that are relevant to this
discussion:

* Early revisions had no support for the "version" RPC.  Because of MORAY-336,
  requests for this RPC hang.  The existing node-moray client interprets this as
  "version 1".
* On 2014-08-11 with commit 7413e2e213ce7ae3bbc0772c635b75f8da19a342 under
  MORAY-249, the "version" RPC was added to the server with version 1.
  These revisions of the server will properly report version 1 instead of
  hanging on requests.
* On 2015-02-16 with commit 95771e5835184fc03398825adedd69063e1ff126 under
  MORAY-297, the server version was incremented to 2 to support IP and subnet
  types.  These revisions of the server will properly report version 2.

In terms of affected deployments:

* Most existing SDC deployments are believed to be at version 2.
* Some Manta deployments may still be at version 1, but Manta components do not
  use the "version" RPC nor the version 2 functionality.
* It is believed that at least one SDC deployment exists on release 20140626,
  which would be running a Moray version that hangs on the "version" RPC.  As a
  result, it's important that the new Moray client behave at least reasonably
  for such deployments.  (See above -- that's why the new client uses a generous
  timeout and fails with an error reflecting the problem.  The expected operator
  action will likely be to upgrade Moray in this case.)


#### Explicit breakage: Error classes

The new Moray client will use the new features associated with VError
hierarchies.  Clients should no longer check an Error's `name` to determine
what type it is, but should instead use `VError.findCauseByName()`.  This
change allows Errors to more precisely describe what happened: you can tell,
for example, whether an Error happened on the server or on the client, in
addition to what exactly the Error was (e.g., an invalid argument).  It's
strongly recommended that consuming code that checks Error `name` properties to
instead use `VError.findCauseByName()`.  If for some reason that's a hardship,
clients can set the `unwrapErrors` constructor property to `true`, which causes
the Moray client to report the same kinds of Errors that it reported before (at
the expense of losing a great deal actionable information).


#### On request aborting and cancellation

Neither the new Fast client nor server supports a meaningful form of
cancellation of in-flight requests.  The following explanation is quoted from
the new source:

    The history of cancellation in node-fast is somewhat complicated.
    Early versions did not support cancellation of in-flight requests.
    Cancellation was added, but old servers would interpret the
    cancellation message as a new request for the same RPC, which is
    extremely dangerous.  (Usually, the arguments would be invalid, but
    that's only the best-case outcome.)  We could try to avoid this by
    avoiding specifying the RPC method name in the cancellation request.
    Since the protocol was never well-documented, the correctness of this
    approach is mainly determined by what other servers do with it.
    Unfortunately, old servers are likely to handle it as an RPC method
    of some kind, which triggers an unrelated bug: if old servers
    received a request for a method that's not registered, they just
    hang on it, resulting in a resource leak.

    Things are a little better on more modern versions of the fast
    server, where if you send a cancellation request and the RPC is not
    yet complete when the server processes it, then the server may stop
    processing the RPC and send back an acknowledgment of sorts.
    However, that doesn't mean the request did not complete, since the
    implementation may not have responded to the cancellation.  And more
    seriously, if the RPC isn't running, the server won't send back
    anything, so we don't know whether we need to expect something or
    not.

    To summarize: if we were to send a cancellation request, we would not
    know whether to expect a response, and it's possible that we would
    inadvertently invoke the same RPC again (which could be very
    destructive) or leak resources in the remote server.  For now, we
    punt and declare that request abortion is purely a client-side
    convenience that directs the client to stop doing anything with
    messages for this request.  We won't actually ask the server to stop
    doing anything.


## Instructions for node-moray consumers

This change published a new node-moray major version to the npm registry.
Clients wishing to upgrade a project from the old version to this version
should:

* Make sure the project is using Node v0.10 or v0.12.  (The client appears to
  largely work with v4 as well, but that has not been extensively tested.)
* Update the project's package.json to depend on node-moray via the npm
  registry rather than a git URL.
* Review the [breaking
  changes](https://github.com/joyent/node-moray/blob/master/CHANGES.md) and deal
  with them appropriately in the project.
* Consider updating the way the Moray client is constructed to take advantage
  of the better control afforded by the new constructor options.
* **Verify that the component still works as expected**.  It would be a bug if
  it doesn't, but it's the integrator's responsibility to test all changes
  before pushing.


## Design and implementation details

### Design overview

There are several logical concerns addressed by these components:

* Moray-level translation of method calls into RPC calls
* Fast-level marshaling and unmarshaling of RPC requests, responses, and data
* Transport-level connection management, including establishment, failure
  detection, and backoff.
* Service discovery using DNS

In today's implementation, these are not layered the way one might expect.

* node-fast: responsible for Fast protocol-level concerns, including message id
  generation, checksumming, marshaling and unmarshaling.  But also responsible
  for connection establishment, failure detection, reconnection, and backoff.
  Also contains an optional facility for DNS-based service discovery with random
  host selection but no periodic re-resolve.
* node-moray: responsible for translating consumer method calls into RPCs, but
  also service discovery via DNS resolution (including periodic re-resolve);
  connection establishment (using a retry and backoff policy); maintaining
  mappings between hostnames and IPs, and IPs and Fast clients; tracks which
  hosts are present and which connections are online; and maintains a policy for
  picking new connections.

Adding to the confusion, there's node-libmanta, which contains a class called
"Moray" which actually represents a logical client for the Manta metadata tier.
Rather than representing a Moray client, this "Moray" class _uses_ a Moray
client (that's actually attached to electric-moray).  This class is responsible
for setting up the node-moray client, initializing Manta buckets (and PostgreSQL
triggers), and providing APIs for CRUD of object metadata and recording delete
logs.  It wasn't clear at first, but this class is unaffected by this project.

In the new implementation:

* cueball will be responsible for service discovery, including periodic
  re-resolve; connection establishment, failure detection, retry, and backoff;
  and tracking which hosts are present and selecting clients for new requests.
* node-fast will be responsible for Fast protocol-level concerns.  The only real
  interaction it has with the transport is that it listens for errors and
  end-of-stream on the transport so that it can detach itself and fail any
  outstanding requests.
* node-moray will be responsible for Moray-level translation of method calls
  into RPC requests, and for gluing together cueball with node-fast clients.
  None of the logic for service discovery or connection management will be part
  of node-moray, but consumers will still instantiate a Moray client with
  service discovery and connection management parameters.  Moray will farm all
  this off to cueball and provide the small bit of glue that mates cueball
  connections with Fast clients.

The original Fast client contains mostly connection management code that will
be obviated by cueball and protocol-level code that is generally very simple
but nevertheless ignores all kinds of important bad-input cases.  As a result,
there is little code worth saving, and this project reimplements the Fast
client and server from scratch.

The Moray client is heavily simplified by the removal of the service discovery
and connection management logic.  It's now mostly a bunch of code to (a)
translate constructor arguments into cueball options, and (b) provide thin,
uniform wrappers that turn method calls into RPC calls.

### Moray constructor options

To ensure compatibility, it became necessary to enumerate the many options
accepted by the _old_ node-moray constructor.  These options used to be
documented here, but a more complete discussion is now part of [RFD
73](../0073/README.md#appendix-moray-client-constructor-arguments).

### Related issues

The following important bugs were found in the existing Fast implementation:

* Sending a request abort when no request is outstanding results in treating the
  abort as a new request, with very confusing results.  (Note that there's no
  way to ensure that the request _isn't_ outstanding -- there's an intrinsic
  race there.)  This is described above.
* Many bad-input cases were not checked in the protocol parser.  **Some of these
  are very basic, like messages with the wrong version number.**  (The existing
  protocol parser never looks at the version number of incoming messages.)
  Sending a message with an unknown type would generally be treated as a
  "new-request" message.

There were several bugs fixed in node-fast, but not yet integrated into the
Moray server, so they affect current Moray server deployments:

* Sending a request for an unknown RPC method results in the server dropping the
  request (sending no response).

There were several bugs in the old node-moray implementation:

* The constructor asserts the type of `options.checkInterval`, but attempts to
  use `options.dns.checkInterval`.  The example uses
  `options.dns.checkInterval`.
* The constructor example uses `options.url`, but the implementation actually
  looks at `host` and `port`.  That's because the `createClient()` factory
  method translates `url` into `host` and `port`.
* The `noCache`, `maxIdleTime`, and `pingTimeout` constructor options were
  unused.
* The programs in `bin` are not linted.
* The `version` API function, in addition to the problems above, interprets a
  request timeout as version `1`.  While this was the only reasonable option,
  it's really not reasonable, given that legitimate timeouts do happen in
  production systems.  It would be more reasonable if we sandwiched the
  `version` request between two other requests that we knew the server would
  answer.

### Test plan

Since these components are the heart of much intra-service communciation in SDC
and Manta, it's critical that they correctly handle all failure modes we expect
to see in production systems.  At the very least, we'll want to:

* build a comprehensive Fast test suite that exercises as many edge cases as
  reasonable in the client and server
* build a compatibility test suite that exercises as much of the main test
  suite as is reasonable against a server running bits from before this project
* pass the existing node-moray test suite.  This is tricky because the
  node-moray test process is normally just to run the moray server test suite
  using the client to be tested as the client.  But the client and server may be
  running at different versions.  See [RFD 52](../0052/README.md) for details.

We'll want to manually test:

* adding and removing Moray servers from DNS under load
* removing all servers from DNS under load
* restarting Moray servers under load
* disabling Moray servers under load in a way that fails explicitly (i.e.,
  ECONNREFUSED)
* disabling Moray servers under load in a way that fails implicitly (i.e.,
  dropping all packets)

In all cases, there may be some transient errors, but the system should
converge to a working state while there is at least one working server listed
in DNS.

Additionally, the new Fast implementation will be checked for:

* basic code coverage: although coverage tools cannot be used to determine
  coverage per se, they can be used to identify error cases that are _not_
  covered by any tests.
* memory leaks and fd leaks in both the client and server

Before integration, we'll test incorporating the new node-moray into Marlin,
node-libmanta, minnow, and other Manta components, and make sure that Manta
sets up correctly and passes basic smoke tests.

## See also

* [RFD 73 Moray client support for SRV-based service discovery](../0073/README.md)
