---
authors: David Pacheco <dap@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 105 Engineering Guide - Node.js Best Practices

This RFD is the second of several that together propose an updated Joyent
Engineering Guide.  See [RFD 104](../0104/README.md) for background.  This RFD
proposes contents for the "Node.js Best Practices" section, based primarily on
content from the existing engineering guide.  The rest of this RFD is the
proposed content for that section.

## General Principles

The Joyent Engineering Guide covers general principles that apply to all of our
software, including Node.js software.  Everything about FCS quality all the
time, style, lint, documentation, tests, error handling, logging, source
control, issue tracking, and everything else in the General Principles section
applies here.

## Node.js repository best practices

### Repository naming

See the "General Principles" section for information about naming Triton and
Manta components.

Standalone Node modules generally start with `node-`, per the Node repository
naming convention.  Examples:

- `node-bunyan` (for bunyan, our logging library)
- `node-restify` (for restify, an HTTP REST server library)
- `node-verror` (for verror, an error library)

### Coding style

See the "General Principles" section for basic information.

Node.js repositories **must** use a style checker.
[jsstyle](https://github.com/davepacheco/jsstyle) as our primary JavaScript
style checker.  jsstyle supports overriding style checks on a per-line and block
basis.  It also supports configuration options for indent style and a few other
items.  Options can also be put in a "tools/jsstyle.conf" and passed in with '-f
tools/jsstyle.conf'. See the [jsstyle
README](https://github.com/davepacheco/jsstyle)) for details on
JSSTYLED-comments and configuration options.

gjslint can be used as a style checker, but it is **not** a substitute for
javascriptlint. And as with all style checkers, it **must** be integrated into
`make check`.

### Lint checks

See the "General Principles" section for basic information.

JavaScript repositories **must** use
[javascriptlint](http://github.com/davepacheco/javascriptlint).


### Automated testing

See the "General Principles" section for basic information.

New repositories typically use either [catest](https://github.com/joyent/catest)
or `tape`.  Historically, repositories have also used `tap` or `nodeunit`, but
these are both considered deprecated.


### Node add-ons and Node binaries

For building our own add-ons, we typically use
[v8plus](https://github.com/joyent/v8plus).

Until [very recently](https://github.com/nodejs/abi-stable-node) (as of this
writing), Node.js did not provide a stable binary interface.  We have not yet
evaluated the newly-added interface, and it depends on newer Node versions than
we're running anyway.  So ignoring that, because C++ does not define a useful
compiler- or platform-dependent
[binary](http://stackoverflow.com/questions/7492180/c-abi-issues-list)
[interface](http://developers.sun.com/solaris/articles/CC_abi/CC_abi_content.html),
and we have seen breakage resulting from changing compiler versions, any repo
that uses add-ons (binary modules) **must** bundle its own copy of "node" and
use that copy at runtime.

Almost every repo will fall into this bucket, since we use the native
node-dtrace-provider heavily for observability.  Platform components that use
the platform Node are generally exempt, since they know which version of Node
they're building for.

There are two ways you can get a Node build for your repo:

1. Use a prebuilt node. Read and use "tools/mk/Makefile.node\_prebuilt.defs"
   and "tools/mk/Makefile.node\_prebuilt.targ".

2. Build your own from sources. Read and use "tools/mk/Makefile.node.defs" and
   "tools/mk/Makefile.node.targ". You'll also need a git submodule of the node
   sources:

        $ git submodule add https://github.com/joyent/node.git deps/node
        $ cd deps/node
        $ git checkout v0.6.18   # select whichever version you want


### Managing Node Dependencies

There are reusable eng.git Makefiles for managing `npm install`.  These create a
build stamp so that `make` doesn't have to re-run `npm install` every time.

There are three cases for Node dependencies:

* external public dependencies (e.g., restify, express): specify these in
  package.json as usual.  The vast majority of dependencies should be in this
  bucket, even for our own internal modules (since they're still open-source).
* internal (Joyent-private) dependencies (e.g., ca-vis): either specify these in
  package.json using git URLs instead of version numbers, or use git submodules
  and treat these as local (repo-private) dependencies (see below). All things
  being equal, prefer git URLs in package.json to git submodules.
* local, repo-private dependencies (e.g., ca-native in cloud-analytics or amon
  modules): During the build process, run "npm install path/to/dep". **This
  approach is deprecated and should only be used for code that lives inside the
  repo but is installed as a separate package for whatever reason. This does not
  apply to most dependencies.**

We generally use flexible semver expressions (e.g., `^1.0.0`) for dependencies
that we control and precise versions for other dependencies.  Git-based
dependencies are generally deprecated.

We generally do not use shrinkwrap (though it might be a good idea for release
branches).


## Recommended modules and tools

### Debugging

For fatal failures and many types of non-fatal failures, we use core files and
[mdb\_v8](https://github.com/joyent/mdb_v8).  The [mdb\_v8 user
guide](https://github.com/joyent/mdb_v8/blob/master/docs/usage.md) has a basic
tutorial for understanding the state of a JavaScript program from a core file.
This tool can be used for pulling out state from the stack, any other JavaScript
state on the heap (including closures), and memory leaks.

For CPU profiling, we typically [profile with DTrace using Node's built-in
ustack helper](https://nodejs.org/en/blog/uncategorized/profiling-node-js/) and
then use [stackvis](https://github.com/joyent/node-stackvis) to generate flame
graphs.

We also use the ustack helper and
[node-dtrace-provider](https://github.com/chrisa/node-dtrace-provider) to
correlate program activity with system activity, which supports [runtime log
snooping](https://www.joyent.com/blog/node-js-in-production-runtime-log-snooping)
and [more sophisticated
techniques](https://www.joyent.com/blog/stopping-a-broken-program-in-its-tracks).

See the "General Principles" section for more context.

See also: logging.


### Errors and error handling

See the public guide for [Error Handling in
Node.js](https://www.joyent.com/node-js/production/design/errors).  The basic
concepts described there are extremely important, particularly around
operational errors and programmer errors and the way each type is handled.

We use [verror](https://github.com/joyent/node-verror) widely to support:

- printf-style format strings
- chaining errors with causes (including stack traces)
- structured information properties (e.g., to tack on an IP address of the
  remote server)

With causes, it's important to use `VError.findCauseByName()` rather than
switching on an error's `name` property directly.  See the verror docs for more
information.

verror makes it relatively easy to produce the error messages we like to see
from servers and command-line tools.  See the "General Principles" section for
details.

### Logging

See the "General Principles" section for basic information.

We use the [bunyan](https://github.com/trentm/node-bunyan) module to produce
machine-parseable (JSON) logs.  The bunyan(1) tool renders these logs nicely.

We frequently use logs for:

- basic interactive debugging
- activity auditing, which extends to metering and eventually billing
- _post hoc_ debugging of complex, distributed failures, which requires that the
  logs be reasonably complete in terms of providing all of the parameters,
  results, and key values related to a request.  For example, a Manta upload
  request includes information about the remote client IP and port, the object
  size, the object path, the account of the caller as well as the account into
  which the object was created, the loadbalancer IP that the request came from,
  the metadata shard used, the storage servers contacted (and how long it took
  to contact them), the object id created, and so on.


### Asynchronous control flow

Asynchronous control flow can be challenging to understand and debug in Node.js
programs.  Common failure modes include:

- a callback is never invoked when it should have been.  This can cause the Node
  program to prematurely exit with status 0, which is especially dangerous.
- a callback has not been invoked because something hasn't happened yet, so the
  program appears hung
- a callback is erroneously invoked multiple times

We use [vasync](https://github.com/davepacheco/node-vasync) for most
asynchronous control flow.  It doesn't solve all of these problems, but it
provides a data structure that you can include in log output or kang output or
view in a core file that lets you see which phases of a pipeline have completed
and which ones are outstanding.

Although callback-based control flow isn't a major concern in all languages,
it's always important that whatever control flow is used be debuggable.  When
programs are hung, it's important to be able to understand why.


### HTTP servers

We use the [restify](https://github.com/restify/node-restify) module for
building HTTP servers.  It has good support for defining routes and common
handlers.  It also has built-in DTrace support for observing the behavior of
individual handlers and routes.


### Input validation

See [jsprim](https://github.com/joyent/node-jsprim), which has a function for
validating that a simple object matches a JSON schema, as well as a robust
`parseInteger()` that beats the various built-in approaches.


### Building command-line tools

[cmdln](https://github.com/trentm/node-cmdln) is widely used for command-line
tools, especially those with subcommands or multiple levels of subcommand.

If you opt out of a framework for building a CLI, you may find these modules
useful:

- [cmdutil](https://github.com/joyent/node-cmdutil): provides analogs to the C
  functions `err(3c)` and `warn(3c)` (for printing out fatal and non-fatal
  messages in reasonably consistent ways) and usage messages
- [dashdash](https://github.com/trentm/node-dashdash): declarative-style
  command-line option parsing, with types
- [posix-getopt](https://github.com/davepacheco/node-getopt): traditional
  getopt-style option parsing
- [tab](https://github.com/joyent/node-tab): a little dated, but makes it
  relatively easy to emit tables of output with selectable columns

Tools should generally provide both human-readable summaries and, when
appropriate, machine-parseable summaries.  A common pattern is to use the
`-o`/`--columns` to select individual columns of output and a
`-H`/`--omit-header` option to elide the header row.  Especially when combined
with basic filters to select only the rows of interest, this lets other
command-line tools extract pretty specific pieces of information from your tool
in a way that's easy to keep backwards-compatible.


### Other useful modules

* [forkexec](https://github.com/joyent/node-forkexec): useful when shelling
  out to run other commands, because the Node.js standard library functions are
  awkward and somewhat difficult to use correctly
* [jsprim](https://github.com/joyent/node-jsprim) provides a bunch of useful
  operations for primitive JavaScript types, including checking whether objects
  are empty, iterating the key-value pairs of an object, and parsing integers
  robustly.


### Useful command-line tools

* [json](https://github.com/trentm/json): for formatting and transforming JSON
* [nhttpsnoop](https://github.com/joyent/nhttpsnoop): allows you to dynamically
  trace garbage collection or HTTP client or server requests for any Node
  program using the standard library

