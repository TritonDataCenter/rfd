---
authors: Dave Pacheco <dap@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 52 Moray test suite rework

## Background

Moray consists of both client and server components.  There's an automated test
suite that exercises much of both the client and server.  It's currently bundled
with the server.

The documented procedure for testing a new version of the server is to "npm
install" all the dependencies, which includes the moray client, and then run the
test suite.  This will exercise your server with the stock client.

The documented procedure for testing a new version of the client is to "npm
install" your client into a fresh clone of the server repository and then run
the test suite.  This will exercise your client against the stock server.

The test suite can function in two modes: by default, it spins up new Moray
servers as needed based on a provided configuration file.  It can also be
configured to point at a running Moray server.  However, there's at least one
test that exercises behavior of multiple servers, which can only work in the
first mode.

While it's not called out explicitly anywhere, running the test suite at all for
either the client or server implicitly depends on a Manatee instance, including
ZooKeeper and PostgreSQL instances.  While we could separate basic tests from
those that exercise the interactions with Manatee and ZooKeeper, even the basic
tests would require PostgreSQL to be running.


## Problem

The immediate problem is that the Moray server currently only
functions with Node 0.10 and earlier, while the Moray client rewrite under RFD
33 will depend on Node 0.12 and later.  As a result, the client and server
require different sets of npm dependencies, and they cannot run as part of the
same Node program.  While we do want to move Moray to 0.12, we would like to
avoid coupling that work to RFD 33.


## Goals and constraints of the solution

* Besides testing a stock client and server, it needs to be possible to test a
  stock server with a new client, or a stock client with a new server.
* The process for running automated tests for either the server or the client
  should be documented, straightforward, and as automated as possible.  It
  should not require lots of manual steps.
* Ideally, it would be nice to preserve the property that the test suite can
  instantiate servers, because that makes it easier to automatically test
  multi-server behavior as well as server-restart behavior.  This won't be very
  possible while the two components require different Node versions, but that
  won't be true forever, and the solution for the test suite shouldn't make this
  harder.

The implementation of the test suite requires a working client, so the test
suite necessarily inherits the Node requirements of the client (namely, Node >=
0.12, and corresponding npm dependencies).  That essentially rules out keeping
it in the server repository.

The test suite currently supports the ability to spin up new instances of the
server, and it makes use of this to test multi-server behavior.  This could also
be used to test server-down and server-restart behavior.  Unless we want the
client module to depend on the server one, and know a bit about how to start
servers (including server config file details), we probably don't want the test
suite in the client repository either.

## Proposal: move the test suite to a separate repository

Suppose that we move the test suite to a separate, third repository.

* The configuration in this repository would allow you to specify paths to the
  Moray client and server implementations, as well as configuration pointing at
  the Manatee and ZooKeeper servers.
* The explicit dependencies in this repository would include whatever packages
  are explicitly used in the test suite.  The client and server would not be
  included using npm dependencies.
* The test suite would continue to support two modes: one which starts servers
  as needed (based on the implementation path specified), and one which is
  pointed at an existing set of servers.  Unlike today, the start-servers option
  would start the server in a separate process to satisfy the different Node
  version constraints.

The README for this repository will specify exactly how to configure it (namely,
pointing it at implementations of the client and server and configuration for
the dependent services).  The READMEs for the client and server repositories
will have a sentence or two pointing people at this one.

We could go a step further and have "make test" in the server and client
repositories clone the test repository, configure it, and run it, but this has
diminishing value and some of the same problems mentioned above (i.e., the
client knowing some server implementation details).

## User impact

None.

## Security impact

None.

## Upgrade impact

None.

## Interfaces affected

No programmatic interfaces are affected, public or private.

The test suite will have knowledge of how to start servers using command-line
tools.  We may decide later to have it use a programmatic interface for starting
servers in the same process.  The test suite will use the existing stable client
interface.

## Repositories affected

* Create https://github.com/TritonDataCenter/moray-test-suite with all tests from "moray"
  and "node-moray", plus documentation, tools, and Makefile targets to run the
  tests.
* Update https://github.com/TritonDataCenter/moray: remove existing test suite and update
  README.md and possibly Makefile to point to moray-test-suite repo.
* Update https://github.com/TritonDataCenter/node-moray: remove existing tests (which are
  mostly ad-hoc) and update README.md to point to moray-test-suite repo.
