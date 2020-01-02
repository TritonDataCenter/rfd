---
authors: David Pacheco <dap@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+104%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 104 Engineering Guide - General Principles

Joyent Engineering has long maintained an [Engineering Best Practices
Guide](https://github.com/joyent/eng/blob/master/docs/index.md) to help maintain
consistency and quality in our software.  As it's written today, this guide is a
little outdated (not matching current practice), a little wordy, and a little
confusingly organized.  Some sections are duplicated or overlapping, and many of
the principles are tightly coupled to Node.js, though there are sections for
REST APIs, Makefiles, and bash scripts.  It also never had an RFD, since it
predates the RFD process.

This RFD is the first of several that together propose an updated Joyent
Engineering Guide.  This RFD proposes separating out common principles from
language-specific best practices.  The new Guide would be organized similarly to
the existing guide, as follows:

1. General Principles (edited from the existing eng guide)
   1. FCS Quality All the Time
   2. Engineering tools and processes (git/GitHub, JIRA)
   3. Repository guidelines (language, naming, copyright, style, lint, testing,
      docs, build system, etc.)
   4. Tickets and commit messages
   5. Component design (debuggability, error handling, logging, SMF)
   6. Miscellaneous Best Practices
   7. Security and development notes (existing security and process statements)
2. REST API Best Practices (same as eng guide today)
3. Node.js Best Practices (style, lint, observability, recommended modules)
4. Bash Best Practices (same as eng guide today)
5. Make Best Practices (same as eng guide today)
6. C Best Practices (initially very small: starting with style notes in eng
   guide today)

The rest of this RFD is the proposed content for section 1 "General Principles".
This is largely just an edited version of the existing Engineering guide.

Sections 2 and 4 through 6 will largely match the existing sections, with the
notable change that the "API Documentation" section that's currently under
"Repository guidelines" will move to the "REST API Best Practices" section.

A subsequent RFD will propose Section 3, the Node.js Best Practices section,
based on the existing engineering guide and additional content.


## Joyent Engineering Guide: General Principles

To maintain consistency and quality in all of our production software, the
engineering team has put together this document describing standards and best
practices for software development at Joyent.  It's understood that situations
differ, and rules should not be followed blindly, but these guidelines represent
the consensus of the team.  If you feel it necessary to diverge from them, be
sure to document the divergence (including why it's necessary) and get review
for the change.

In general, process is shrink-to-fit: we adopt process that help us work better,
but process for process's sake is avoided. Any resemblance to formalized
methodologies, living or dead, is purely coincidental.


### Rule #1: FCS Quality All the Time

**The "master" branch of a repository should be FCS (first customer ship)
quality all the time.**  That means the code is style-clean, lint-clean, passes
all automated tests, and generally works.  Any testing required for a change
**must** be completed before it's integrated into master.  Later sections of
this guide discuss these pieces in more detail.

In general, use the "master" branch for all development.  This does not mean you
can't use your own branches for personal development, but try to keep these
branches sync'd up with master.  If it becomes necessary to share these dev
branches, consider instead integrating whatever pieces you can into "master" to
minimize divergence.

**Rationale:** The goal is to avoid the [quality death spiral
(QDS)](http://wiki.illumos.org/display/illumos/On+the+Quality+Death+Spiral) that
results when people stop using the "master" branch for everyday development.


### Engineering tools and processes

#### Source control

All software **must** live in a git repository.  To the extent possible,
software **should** be open-source, and open-source Joyent software should be
hosted on GitHub under the Joyent organization.  For historical reasons, some
components still live under individuals' GitHub accounts.

Note that just because a repo is on github doesn't mean its issues are tracked
there.  See "Issue Tracking".

Some older components (and a few proprietary ones that are still used) are
managed by gitosis running on the internal Joyent git server. Files, commits,
and documentation for these projects can be browsed at mo.joyent.com by Joyent
employees.


#### Issue Tracking

We use an internal JIRA instance for tracking issues with the operating system
(SmartOS), Triton, Manta, and most other components that we build.

Standalone repositories or those with the expectation of heavy community
involvement (e.g., [node-manta](https://github.com/joyent/node-manta)) may use
GitHub issues instead.

**If in doubt about where to file an issue for a project, look at the commit
messages for recent changes to the project.**


#### Change management

All changes must be reviewed and approved through a GitHub pull request (PR).


### Repository guidelines

#### Programming language

New server-side projects **should** use one of the languages for which we have
developed a Best Practices section within this Guide.  That's primarily Node.js
at the moment, but it's expected to expand in the near future.

Language-specific best practices guides **must** address the sections of this
guide that refer to language-specific guides, including repository naming,
coding style, lint checks, automated testing, and debuggability.


#### Repository naming

Triton repositories **should** be prefixed with `triton-` or `sdc-` (the latter
for historical reasons) and contain the name of the API that they implement.
Examples:

- `sdc-cnapi` (for CNAPI, the Compute Node API)
- `sdc-napi` (for NAPI, the Network API)
- `triton-cmon` (for the Container Monitor)

Manta repositories **should** be prefixed with `manta-` and mostly use fish
names as code names:

- `manta-muskie` (for Muskie, the Manta API server)
- `manta-mako` (for Mako, the API on the storage server)

Many component repositories are common to both Triton and Manta.  These
generally have no prefix.  Examples include `moray` and `binder`.

See language-specific guides for additional guidelines.


#### Licenses and copyright

For Triton and Manta repositories, every source file (including documentation
and Makefiles) **must** have the MPL 2.0 header and a copyright statement. These
statements should match one of the [prototypes supplied by
eng.git](https://github.com/joyent/eng/tree/master/prototypes).

The contents of the MPL 2.0 header must be:

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.

For other repositories (mostly standalone Node.js repositories), we generally
use the MIT license.

The copyright line should look like this:

    Copyright (c) 2017, Joyent, Inc.

There should be a single year, not a list.  When modifying existing code, the
year should be updated to be the current year that the file was modified.  **Do
not diverge from this form** except to change the year to the current year.


#### Coding style

Every repository **must** have a consistent coding style that is enforced by
some tool.  It's not necessary that all projects in a language use the same
style, but all styles **must** limit line length to 80 columns.  Differences
across repositories **should** be kept to an absolute minimum (e.g., only hard
vs. soft tabs and tabstops).

Style checking tools **must** support disabling checks for individual lines in
files and for individual sections in files.

Note that many projects have patterns that are not enforced by a tool  (e.g.,
naming conventions).  Look for and respect the patterns within the repositories
that you're working in.

See the language-specific guides for details.


#### Lint checks

Most languages have static analysis tools that attempt to identify software bugs
or dangerous coding patterns.  For each language, we will standardize on a small
set of these tools (ideally just one), and one of those tools **must** be run on
all code written in that language.

Linters selected for each language **should** have discrete checks that can be
individually disabled by configuration, on a per-repository basis, for certain
lines in files, and for certain sections in files.

See the language-specific guides for details.


#### Automated testing

All repos **must** be tested by a comprehensive automated test suite that
**should** be driven by `make test`.  These test suites tend to be a mix of unit
tests, integration tests, and system tests.  Instructions for running the
automated test suite, including environment variables and other external
dependencies, **must** be part of the README.

Bug fixes and new features **should** include new automated tests.  The tests
**should** be run automatically (as via jenkins) either with every commit or
daily. 

Understanding and fixing failures in the automated test run **must** be
considered the top development priority for that repo's team.  Persistent
failures are not acceptable. 

The automated test suite **should** be able to generate
[TAP-format](https://testanything.org/tap-specification.html) output.

See the language-specific guides for details.

Notes on Triton automated testing: currently this is handled by the [staging
environment](https://mo.joyent.com/docs/globe-theatre/master/) and the
"stage-test-\*" Jenkins jobs. In other words, your project should have some sort
of "stage-test-\*" job. Currently, these staging and CI environments can only be
accessed by Joyent employees.  All Triton components **should** provide a
"runtests" driver script (preferably in the "test" subdirectory) and the
necessary test files for running system tests (and unit tests are fine too)
against your running service -- as opposed to starting up parallel dev versions
of your service. The goal here is to provide a common, simple, and "just works"
entry point for test components as they are deployed in the product, for the
benefit of QA, continuous-integration testing, and devs not familiar with a
given component. Dev environment != production environment.  All "runtests"
scripts **must** exit non-zero if any tests failed.


#### Required documentation (README.md, CONTRIBUTING.md)

Every repository **must** have in its root a README file (preferably in
Markdown) that includes:

* (if part of Triton or Manta) the common preamble used for all Triton and Manta
  components.  This should link to the Triton or Manta project.
* the name of the API or other component(s) contained in the repo and a brief
  description of what they do
* basic development workflow: how to run the code and start playing with it
* how to test the component, including environment variables that need to be
  set, commands that need to be run, and how to know that the result worked (if
  it's not obvious)
* **anything else you would want someone to know who was making their first
  change to this project without your help**

Please also include:

* useful but non-standard Make targets
* a description of the structure of the project
* useful design notes

Every repository **should** also have in its root a CONTRIBUTING file that
exactly matches the one used for other projects.  There's one file used for
Triton repositories, one for Manta, and one for standalone components.  This
file causes GitHub to make these guidelines prominent when people submit issues
or pull requests, so it's very useful to include.


#### Build system

All repos **must** have a Makefile that defines at least the following targets:

* `all`: builds all intermediate objects (e.g., binaries, executables, docs,
  etc.). This should be the default target.
* `check`: checks all files for adherence to lint, style, and other
  repo-specific rules not described here.
* `clean`: removes all built files
* `prepush`: runs all checks/tests that are required before pushing changes to
  the repo
* `docs`: builds documentation (restdown markdown, man pages)
* `test`: Runs the test suite. Specifically, this runs the subset of the
  tests that are runnable in a dev environment. See the "Testing" section
  below.
* `release`: build releasable artifacts, e.g. a tarball (for projects that
  generate release packages)

The `check` and `test` targets **must** fail if they find any 'check' violations
or failed tests. The `prepush` target is intended to cover all pre-commit
checks. It **must** run successfully before any push to the repo. It should
also be part of the automated build. Any commit which introduces a prepush
failure **must** be fixed immediately or backed out.

There are several modular Makefiles you can use to implement most of this. See
the separate "Make Best Practices" for details.


#### Code comments

Source files **should** have a block comment at the top of the file (below the
license and copyright notice) that describes at a high level the component
that's implemented in the file. For example:

    /*
     * ca-profile.js: profile support
     *
     * Profiles are sets of metrics. They can be used to limit visibility of
     * metrics based on module, stat, or field names, or to suggest a group of
     * metrics to a user for a particular use case.
     */

For non-trivial subsystems, consider adding a Big Theory statement that
describes what the component does, the external interface, and internal details.
For a great example, check out
[panic.c](https://github.com/joyent/illumos-joyent/blob/403b9b2581c0e421d5fd8a74975df28290e276e5/usr/src/uts/common/os/panic.c#L30-L122)
in the kernel.

#### Design documents

Design documents should generally either be
[RFDs](https://github.com/joyent/rfd) or Markdown files inside the repository
under "docs".


#### Deployment environment

* The SmartOS platform itself necessarily runs directly on hardware (or, in
  dev/test environments, in KVM instances to consolidate physical server usage).
* Triton and Manta agents necessarily run inside SmartOS global zones.
* Other new software components written by Joyent **must** target SmartOS
  non-global zones.
* Third-party software components for which the cost of porting to SmartOS is
  known to be very high and the value is considered to be very low **may** be
  deployed inside LX zones.

KVM-based components **should** be avoided if at all possible.


### Tickets and commit messages

#### Commit messages

For established repositories, commit messages to the "master" branch **must**
follow a very specific form.  Each commit **must** be associated with one or
more tickets, and those tickets **must** be listed in the commit message, one
ticket per line, with the synopsis _exactly_ as it appears in the bug tracker,
optionally truncated to 80 characters with "...".  After that should go the
reviewer and approval messages.  For a repository using GitHub issues, the
result might look like this:

    joyent/node-manta#284 improvements to CLI -h/--help output
    joyent/node-manta#279 mjob should expressly list out allowed sizes for memory
    Reviewed by: Chris Burroughs <chris.burroughs@joyent.com>
    Approved by: Dave Pacheco <dap@joyent.com>

Note that there is *no* colon between the ticket identifier and the synopsis,
and there are no blank lines.  With JIRA tickets, it would look like this:

    MANTA-3335 Muskie doesn't return after invoking callback with NotEnoughSpaceError
    Reviewed by: Jordan Hendricks <jordan.hendricks@joyent.com>
    Approved by: Jordan Hendricks <jordan.hendricks@joyent.com>

A given ticket **must not** be reused for multiple commits to the same
repository except in rare cases for very minor fixes immediately after the
previous commit.  In that case, the ticket lines from the commit message
**must** be the same except for a parenthetical explaining why the follow-up
commit is needed:

    INTRO-581 move mdb_v8 into illumos-joyent (missing file)

**There must be no information in the commit message aside from the ticket
identifiers, the ticket synopsis, and the reviewer and approver information.**

**Rationale:** This format makes it easy to correlate tickets and commits, since
there's usually exactly one commit for each resolved ticket.  It also makes it
easier to back out the changes for a particular project.  The other valuable
information that is sometimes put into commit messages should instead go into
the bug tracker.  That includes the nature of the bug and the debugging process
(if applicable), the change, and the test plan.  We keep this information in the
bug tracker so that it can be edited, augmented, searched, and so on.

It's fine to put multiple tickets into a commit, even if they're unrelated.
There's generally a tension between bunching changes together so that they can
be tested once and separating changes so that they can be more easily understood
by reviewers and future engineers looking at the history.  However, each commit
should stand alone with respect to documentation, tests, and tooling.  That is,
a project that delivers a new feature should deliver the code, documentation,
tests, and tooling in one commit, if possible.


#### Ticket contents

In collaborating on a body of software as large as Triton or Manta, it's
critical that the issues and thought processes behind non-trivial code changes
be documented, whether that's through code comments, git commit comments, or
JIRA tickets.  There are many cases where people other than the original author
need to examine the git log:

* An engineer in another area tries to understand a bug they've run into (in
  your repo or not), possibly as a result of a recent change. The easier it is
  for people to move between repos and understand recent changes, the more
  quickly bugs in master can be root-caused. This is particularly important to
  avoid an issue bouncing around between teams where the problem is *not*.
* An engineer in another area tries to understand when a feature or bugfix
  was integrated into your repo so that they can pull it down to use it.
* An engineer working on the same code base, possibly years later, needs to
  modify (or even rewrite) the same code to fix another bug. They need to
  understand why a particular change was made the way it was to avoid
  reintroducing the original bug (or introducing a new bug).
* A release engineer tries to better understand the risk and test impact of a
  change to decide whether it's appropriate to backport.
* A support engineer tries to better understand the risk and test impact of a
  change to decide whether it's appropriate for binary relief or hot patching.
* Product management wants to determine when a feature or bugfix was integrated.
* Automated tools want to connect commits to JIRA tickets.

This is why we require that every commit **must** link to at least one ticket
(see "Commit comments" above).  **Between the ticket and the commit comment
itself, there must be sufficient information for an engineer that's moderately
familiar with the code base, possibly years later but with source in hand, to
understand how and why the change was made.** The worst case is when the
thought process and issue list are nowhere: not in the comments and not in the
ticket.

For bugs, especially those that a customer could hit, consider including
additional information in the JIRA ticket:

* An explanation of what happened and the root cause, referencing the source
  where appropriate. This can be useful to engineers debugging similar issues
  or working on the same area of code who want to understand exactly why a
  change was made.
* An explanation of how to tell if you've hit this issue. This can be pretty
  technical (log entries, tools to run, etc.). This can be useful for engineers
  to tell if they've hit this bug in development as well as whether a customer
  has hit the bug.
* A workaround, if any.

Of course, much of this information won't make sense for many bugs, so use your
judgment, but don't assume that you're the only person who will ever look at the
ticket.



### Component design

#### Debuggability

Between the fact that most programs are deployed at large scale and that
distributed system failures are often non-fatal, it's especially important that
programs be debuggable after the fact (_post hoc_).  Concretely, this means:

* Crashes should be debuggable after the the program has died (_post mortem_).
  We don't rely on just having a stack trace in the event of a crash, nor on the
  process being able to dump its own state as it dies.  We automatically
  generate core files when programs crash.

Software should be able to exonerate itself in the face of production incidents.
Even when a component is not itself the problem, it's extremely valuable for it
to provide tools that demonstrate that it's working correctly (e.g., handling N
requests per second with no errors and maximum latency of M ms).  Runtime
observability is critical, since not all failure is fatal (and often the most
time-consuming failures to debug are implicit, non-fatal failures).  Concretely,
this means:

* It should be possible to inspect arbitrary runtime state of a program.  This
  is important for understanding cases when a program is hung, is disconnected
  from dependencies, or otherwise not functioning in a non-fatal way.  We use
  `gcore(1M)` to generate core files of running programs with minimal
  disruption.  For a lighter-weight way of observing pre-defined pieces of
  program state, some programs use [kang](https://github.com/davepacheco/kang).
* Programs should expose metrics about activity, including counters for
  operations, error cases, and the like.  Kang supports a limited form of this,
  but components are moving towards exposing the Prometheus API (e.g., via the
  [node-artedi](https://github.com/joyent/node-artedi) module.
* It should be possible to understand excessive memory usage, particular in the
  case of memory leaks, even if they're not fatal.  Again, core files are a good
  vehicle for this.
* It should be possible to understand the causes of excessive CPU utilization,
  generating flame graphs or similar visualizations.  Ideally, the sampling can
  be done by DTrace.  That allows users to specify arbitrary intervals and avoid
  biases associated with in-process sampling.
* Ideally, it should be possible to correlate system activity (e.g., I/O
  operations or system calls) with program activity.
* Ideally, it should be possible to enable application-level tracing of
  predefined events without restarting the program.  With the
  [dtrace-provider](https://github.com/chrisa/node-dtrace-provider/) family of
  language extensions, applications can define their own probe points, and
  DTrace can trace them.  This allows them to be traced across processes and
  even across zones on the same machine, which is extremely useful for services
  that are horizontally scaled.  Bunyan's support for this enable's [runtime log
  snooping](https://www.joyent.com/blog/node-js-in-production-runtime-log-snooping).
  With other operating system facilities, this also allows us to [stop programs
  at specific points of interest, save a core file, and resume the
  program](https://www.joyent.com/blog/stopping-a-broken-program-in-its-tracks).

There are specific recommendations for accomplishing this in the
language-specific guides.

#### Error handling

Error handling should reflect the ideas and practices around programmer errors
and operational errors as described in [Error Handling in
Node.js](https://www.joyent.com/node-js/production/design/errors).  While that
document was written for Node.js, most of it applies to other programming
languages.  **Make sure to read and understand this document!**  Programmer
errors **should** generally cause crashes, while operational errors **must** be
cleanly handleable, reportable, and traceable.  They should provide enough
information for consumers to switch on different error types and report on
metadata.


#### Logging

There are at least three different consumers for a service's logs:

- engineers debugging issues related to the service (which may not actually be
  problems with the service)
- monitoring tools that alert operators based on error events or levels of
  service activity
- non real-time analysis tools examining API activity to understand performance
  and workload characteristics and how people use the service

For the debugging use case, **the goal should be to have enough information
available after a crash or an individual error to debug the problem from the
very first occurrence in the field**. It should also be possible for engineers
to manually dump the same information as needed to debug non-fatal failures.

Logs for home-grown components **must** be formatted in JSON using Bunyan.

Multiple use cases do not necessarily require multiple log files. Most services
should log all activity (debugging, errors, and API activity) in JSON to either
the SMF log or into a separate log file in
"/var/smartdc/&lt;service&gt;/log/&lt;component&gt;.log". For services with
extraordinarily high volume for which it makes sense to separate out API
activity into a separate file, that should be directed to
"/var/smartdc/&lt;service&gt;/log/requests.log". However, don't use separate
log files unless you're sure you need it. All log files in
"/var/smartdc/&lt;service&gt;/log" should be configured for appropriate log
rotation.

For any log entries generated while handling a particular request, the log
entry **must** include the request id. See "Request Identifiers" under "REST
API Guidelines" below.

Log record fields **must** conform to the following (most of which comes
for free with Bunyan usage):

| JSON key | Description | Examples | Required |
| -------- | ----------- | -------- | -------- |
| **name** | Service name. | "ca" (for Cloud Analytics) | All entries |
| **hostname** | Server hostname. | `uname -n`, `os.hostname()` | All entries |
| **pid** | Process id. | 1234 | All entries |
| **time** | `YYYY-MM-DDThh:mm:ss.sssZ` | "2012-01-26T19:20:30.450Z" | All entries |
| **level** | Log level. | "fatal", "error", "warn", "info", or "debug" | All entries |
| **msg** | The log message | "illegal argument: parameter 'foo' must be an integer" | All entries |
| **component** | Service component. A sub-name on the Logger "name". | "aggregator-12" | Optional |
| **req_id** | Request UUID | See "Request Identifiers" section below. Restify simplifies this. | All entries relating to a particular request |
| **latency** | Time of request in milliseconds | 155 | Strongly suggested for entries describing the completion of a request or other backend operation |
| **req** | HTTP request | -- | At least once as per Restify's or [Bunyan's serializer](https://github.com/trentm/node-bunyan/blob/master/lib/bunyan.js#L856-870) for each request. |
| **res** | HTTP response | -- | At least once as per Restify's or [Bunyan's serializer](https://github.com/trentm/node-bunyan/blob/master/lib/bunyan.js#L872-878) for each response. |

We use these definitions for log levels:

- "fatal" (60): The service/app is going to stop or become unusable now.
  An operator should definitely look into this soon.
- "error" (50): Fatal for a particular request, but the service/app continues
  servicing other requests. An operator should look at this soon(ish).
- "warn" (40): A note on something that should probably be looked at by an
  operator eventually.
- "info" (30): Detail on a regular operation that's quiet enough to be on all
  the time.
- "debug" (20): Additional details that are too verbose to be on by default.
- "trace" (10): Logging from external libraries used by your app or *very*
  detailed application logging.

Suggestions: Use "debug" sparingly. Information that will be useful to debug
errors _post hoc_ should usually be included in "info" messages if it's
generally relevant or else with the corresponding "error" event. Don't rely
on spewing mostly irrelevant debug messages all the time and sifting through
them when an error occurs.

Most of the time, different services should log to different files. But in some
cases it's desirable for multiple consumers to log to the same file, as for
vmadm and vmadmd. For such cases, syslog is an appropriate choice for logging
since it handles synchronization automatically. Care must be taken to support
entries longer than 1024 characters.

Standalone libraries that are long-running and complicated (e.g., `restify`,
being an HTTP server framework, and `cueball`, since it performs a bunch of
background asynchronous activity) should accept loggers and log normal operation
at "trace" or "debug" level.  These components can log at "warn" level when
something very bad happens, but they should avoid higher levels, since they
cannot generally know how severe their problem is for the application using
them.

Standalone components that are relatively simple or with well-bounded discrete
operations do not need to log directly.


#### Service (process) management with SMF

Both home-grown and third-party services **must** use SMF to manage the service,
which includes starting, stopping, and restarting the service.

While SMF itself is grimy and the documentation is far from perfect, the
documentation _is_ extensive and useful. Many common misunderstandings about how
SMF works are addressed in the documentation. It's strongly recommended that you
take a pass through the docs before starting the SMF integration for your
service. In order of importance, check out:

- SMF concepts: `smf(5)`, `smf_restarter(5)`, `smf_method(5)`, `svc.startd(1M)`
- Tools: `svcs(1)`, `svcadm(1M)`, `svccfg(1M)`

Common mistakes include:

- Setting the start method to run the program you care about (e.g., "node
  foo.js") rather than backgrounding it (e.g., "node foo.js &"). SMF expects
  the start method to start the service, not *be* the service. It times out
  start methods that don't complete, so if you do this you'll find that your
  service is killed after some default timeout interval. After this happens
  three times, SMF moves the service into maintenance.
- Using "child" or "wait model" services to avoid the above problem. Read the
  documentation carefully; this probably doesn't do what you want. In
  particular, if your "wait model" service fails repeatedly, SMF will never put
  it into maintenance. It will just loop forever, forking and exiting.
- Not using "-s" with svcadm enable/disable. Without "-s", these commands are
  asynchronous, which means the service may not be running when "svcadm enable"
  returns. If you really care about this, you should check the service itself
  for liveness, not rely on SMF, since the start method may have completed
  before the service has opened its TCP socket (for example).

SMF manages processes using an OS mechanism called contracts. See `contract(4)`
for details. The upshot is that it can reliably tell when a process is no
longer running, and it can also track child processes.

Quoting `svc.startd(1M)`:

     A contract model service fails if any of the following conditions
     occur:

         o    all processes in the service exit

         o    any processes in the service produce a core dump

         o    a process outside the service sends a service process a
              fatal signal (for example, an administrator terminates a
              service process with the pkill command)

Notice that if your service forks a process and *that* process exits,
successfully or otherwise, SMF will not consider that a service failure. One
common mistake here is forking a process that will be part of your service, but
not considering what happens when that process fails (exits). SMF will not
restart your service, so you'll have to manage that somehow.

SMF maintains a log for each service in /var/svc/log. The system logs restarter
events here and launches the start method with stderr redirected to the log,
which often means the service itself will have stderr going to this log as
well. It's recommended that services either use this log for free-form debug
output or use the standard logging facility described under "Logging" above.

### Miscellaneous Best Practices

- Use JSON for config data, and use an automatic validator (such as JSON
  schema) to validate the contents.  (Plain text "ini" files make it more
  difficult to encode and validate non-string values.)  Be sure to validate
  application-specific semantics as well!
- For services and distributed systems, consider building rich tools to
  understand the state of the service, like lists of the service's objects and
  information about each one. Think of the SmartOS proc(1) tools (see man pages
  for pgrep, pstack, pfiles, pargs).
- Consider doing development inside a SmartOS zone rather than directly on a
  non-SmartOS workstation or in a CoaL global zone. Not only does this force us
  to use our product the way customers might, it also eliminates classes of
  problems where the dev environment doesn't match production (e.g., because
  you've inadvertently picked up a globally-installed library instead of
  checking it in, or resource limits differ between MacOS and a SmartOS zone, or
  you've forgotten which files you've copied over to the running system in order
  to test changes).
- Document what's necessary to get from scratch to a working development
  environment so that other people can try it out. Ideally, automate it.
- Similarly, build tools to automate deploying bits to a test system (usually a
  Triton headnode). The easier it is to test the actual deployment, the more
  likely people will actually test that, and you'll catch environment issues in
  development instead of after pushing.


### Security and production code deployment process

Joyent Engineering makes security a top priority for all of our projects. All
engineering work is expected to follow industry best practices. New changes
affecting security are reviewed by a developer other than the person who wrote
the new code. Both developers test that these changes are not vulnerable to the
OWASP top 10 security, pass PCI DSS, and are safe.

Common vulnerabilities to watch out for:

- Prevent code injection
- Buffer overflow. Truncate strings at their maximum length.
- Encrypt all sensitive data over HTTPS.
- Do not leak sensitive data into error logs.
- Block cross-site-scripting(XSS) by specifically validating input and
  auto-escaping HTML template output.
- Wrap all routes in security checks to verify user passes ACLs.
- Prevent cross-site-request-forgery(CSRF)

For the Joyent Public Cloud, Jira change tickets should include the following
before the code is promoted to production:

- Description of the change's impact
- Record of approval by authorized stake holders
- Confirmation of the code's functionality and proof that vulnerablity testing
  was performed. A log or screenshot from a security scanner is sufficient
- Steps to undo this change if necessary.

For reference, read the [owasp top 10](https://www.owasp.org/index.php/Category:OWASP_Top_Ten_Project) vulnerabilities.
