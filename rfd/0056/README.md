---
authors: Marsell Kukuljevic <marsell@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 56 Revamp Cloudapi

Cloudapi has a relatively long history in the Triton stack. It was initially
written to support the SDC 6.5 public API, and retained that compatibility for
several years. Since then, Cloudapi has added many new public features, all
while making a best effort at retaining backward compatibility.

Since Cloudapi is a public interface, API stability is a driving consideration.
Any change to Cloudapi is made with preserving existing behaviour in mind. As a
result, changes and refactoring which aren't strictly needed are avoided to
minimize the risk of API breakage, and a fair bit of technical debt has
accumulated within Cloudapi.

The technical debt needs to be cleaned up, and we are reaching the point where
a substantial revamp is needed for scalability and security reasons, as well as
bringing Cloudapi up-to-date with more recent Triton libraries.


## Proposal

### Reduce server.use() in app.js

Cloudapi uses server.use() extensively for authentication, as well as setting a
fair number of pseudo-global variables. Specifically, these calls are convenient
but troublesome:

    server.use(resources.resourceName);
    server.use(datasets.loadDatasets);
    server.use(packages.loadPackages);
    server.use(networks.loadNetworks);
    server.use(machines.loadMachine);
    server.use(resources.loadResource);

These calls are used to set attributes on the req object. For example:

    req.dataset
    req.datasets
    req.pkg
    req.packages
    req.networks
    req.external_nets
    req.internal_nets
    req.machine
    req.machine_role_tags

Which also has the consequence that sometimes these attributes are set, and
sometimes are not, depending on the HTTP call made; for example, a call to
/my/packages does not need req.machine. Thus there are many conditionals
sprinkled throughout the code like this:

    $  grep machine.*test *
    app.js:                    if (!/\/machines/.test(req.getUrl().pathname)) {
    datasets.js:    if (/\/machines/.test(pathname) && req.method === 'GET') {
    datasets.js:    if (!/\/machines/.test(pathname) &&
    datasets.js:    if (/\/machines/.test(pathname) &&
    datasets.js:        !/\/machines\//.test(pathname) &&
    datasets.js:    if (/\/machines\//.test(pathname)) {
    datasets.js:    if (!/\/(machines|images)/.test(pathname)) {
    machines.js:    if (!req.params.machine || !(/\/machines/.test(pathname))) {
    networks.js:    if (!/\/networks/.test(pathname) && !((/\/machines$/.test(pathname) &&
    packages.js:    if (/\/machines$/.test(pathname) &&

And some of these:

    $  grep '\-\-ping' *
    account.js:    if (req.params.account === '--ping') {
    audit_logger.js:        if (req.path() === '/--ping' && req.method === 'GET') {
    auth.js:    if (req.getUrl().pathname === '/--ping') {
    auth.js:    if (req.getUrl().pathname === '/--ping') {
    auth.js:    if (req.getUrl().pathname === '/--ping') {
    auth.js:    if (req.getUrl().pathname === '/--ping') {
    datasets.js:    if (req.getUrl().pathname === '/--ping') {
    machines.js:    if (pathname === '/--ping') {
    networks.js:    if (pathname === '/--ping') {
    packages.js:    if (pathname === '/--ping') {
    resources.js:    if (req.getUrl().pathname === '/--ping') {
    resources.js:    if (req.getUrl().pathname === '/--ping') {

This has turned into a confusing mess: more bug prone, less efficient, and a
potential source of security vulnerabilities.

These server.use()es should be eliminated. A less invasive change would be to
move these calls into pre calls. For example, GetMachine could change from this:

    server.get({
        path: '/:account/machines/:machine',
        name: 'GetMachine'
    },
    before,
    get);

To this:

    server.get({
        path: '/:account/machines/:machine',
        name: 'GetMachine'
    },
    before,
    loadNetwork,
    loadPackage,
    loadDataset,
    loadMachine,
    get);

Alternatively, load calls can be made directly within the get() function itself;
zero magic.  Considering the numerous conditionals that are sprinkled throughout
loadMachine(), this is probably a better approach.

All the other server.use() in app.js need to be audited as well. Authentication
is a reasonable use of server.use(), as there are no doubt others as well.


### More asserts

While Cloudapi's test suite is reasonably thorough, Cloudapi typically faces a
hostile Internet, and thus needs to be much more rigorous about checking
assumptions and invariants throughout the code. A break in Cloudapi is
potentially catastrophic for a customer, thus the code should be far more
paranoid than it is.

This is a high-risk change, because implicit behaviours that once worked may
stop doing so, thus breaking API stability. It's worth it, considering the
alternative.

At minimum, all function args need their types checked (using assert-plus), and
owner\_uuid should be checked on every object possible loaded from backend
services.


### Add support for streaming

This is very much a wishlist item, since it would depend upon all internal
services that Cloudapi calls to also support streaming, and it's not clear there
would be a major advantage by supporting this.

Cloudapi makes almost no use of streams. When a user calls any list endpoint,
Cloudapi loads all objects from backend services (with a possible object limit
of 1000), before doing various transformations and returning JSON to the caller.

The main reasons for using streams is to keep less data buffered in memory, and
a small improvement in latency; more API calls could be served by the same node
processes. If the entire Triton stack supported streams, it would also make
limit/offset -- and the associated concurrency problems -- less relevant; a
caller could terminate at any time.

A major roadblock on making Cloudapi streamable is that most backend services
do not support streaming, particularly for list endpoints. Instead of returning
1000 separate JSON objects, they return a JSON array containing 1000 separate
objects.

This also depends on an update to at least nodejs 0.12, to use the Streams3
interface.


### Reduce the use and impact of listJobs()

Cloudapi calls vmapi.listJobs() in several places. This is expensive.

For example, a VM with nothing more than a single job returns several KB of
data:

    [root@headnode (coal) ~]# sdc-vmapi /vms/a5b3173d-0163-ef57-eddf-ee1893f28f3b/jobs | wc
         383     773   12108

This data passed from Postgres, to Moray, to Wfapi, to Vmapi, to Cloudapi, with
several de/serialization steps along the way.

The DeleteMachine endpoint uses listJobs() to find whether a VM is deletion is
already in progress. While this check isn't much of a gain overall, such a call
isn't expensive either -- there should be only one deletion job per VM, and the
query filters on such jobs. There might be problems if deletion jobs fail, thus
multiple jobs accumulate.

snapshots.js queries snapshot jobs using listJobs(); Cloudapi needs this
information for the snapshot attribute creation\_state it returns to callers.
Unfortunately, this could become a particularly expensive call for any VMs that
have had a lot of snapshot activity over their lifetime; although there's a
limit how many active snapshots a VM can have at any particular time, listJobs()
returns the history of up to 1000 snapshots jobs ever made on that VM.

MachineAudit has a legtimate use for jobs, but this could likewise become a very
expensive call depending on how many jobs were performed on the VM over its
lifetime.

At minimum, the amount of data being pulled should be reduced to only the
attributes Cloudapi needs to complete an operation.


### Use VError/WError

Cloudapi's error handling is largely ad-hoc. Both for internal errors and for
returning information to callers.

Cloudapi should be modified to use node-verror for all errors; VError should be
used for internal errors, and errors returned to callers should be wrapped with
WError. This will both aide debugging through logs, and help prevent unexpected
information leaks through error messages.


### Use node-cueball

Given the multi-instance world that Triton is moving to, Cloudapi should
effectively support pools of connections to multiple instances of the same
service. This will hopefully be supported within sdc-clients, requiring minimal
changes to Cloudapi itself.


### Attempt idempotent calls more than once

Currently Cloudapi never makes more than one attempt to perform calls to
internal services. As Triton standups get larger, uncommon errors start to
become common. In order to mask some temporary errors from callers, and present
a more reliable interface, Cloudapi should reattempt all idempotent calls that
indicate service failure.

The simplest starting point is to retry any GETs that fail with a 5xx, or a
connection failure.

Cloudapi does not use node-backoff yet. This is a suitable place for its use.


### Performance tests

Cloudapi's highest priorities are API stability and security. Unfortunately,
little attention has been given to performance. Although Cloudapi is a
relatively thin layer above internal services, some calls might prove
unexpectedly expensive if some query args are missed.

Furthermore, as Triton installs grow, the amount of data Cloudapi could
potentially face will grow as well. We need to prevent unnecessary slowdowns
caused by large movements of data through the various internal services to
Cloudapi.

Trent Mick added some performance tests to Dapi, and this is a good starting
point for Cloudapi as well. As a first step, all existing tests should have
reasonable timeouts set on them; tests that do not complete in time should fail.
After that, we need to test scaling, by shoving increasing numbers of VMs,
snapshots, and the like through the system.

Testing scaling would be a long affair. Perhaps mock cloud could be used for
standard tests, and the full non-mock tests run on Jenkins nightly.

One important advantage to adding performance tests to Cloudapi is that it will
help exercise the rest of Triton's stack as well, particularly for Jenkins
nightly test runs.

A wishlist item would be tracking how long each test takes across many
revisions, ala arewefastyet.com. This is particularly useful when combined with
Jenkins nightly, because it could catch slowdowns elsewhere in the Triton stack.


### Remove support for ufds plugins

loadPlugins() in app.js configures plugins found in plugins/ using information
from both config.json and UFDS.

Considering that configuration data is already kept in Sapi, storing plugin
configuration in UFDS seems superfluous, and an abuse of UFDS. The only
advantage UFDS has over Sapi is the ability to replicate between data centers.


### Add fuzzer?

Almost all randomization has been removed from Cloudapi tests, since it makes
catching errors much harder, particularly when errors happen only occasionally.
Perhaps this should be revisited; just because tests always pass with the same
set of test data does not mean that it would pass with other valid sets of data,
or fail to catch invalid data.

