----
authors: Nick Zivkovic <nick.zivkovic@joyent.com>
state: predraft
----

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 <contributor>
-->

# RFD 19 Versioning For Workflow Modules


## Background

Most services in SDC use the workflow service to schedule jobs. They do this by
sending over raw Node code to the workflow, which is then evaluated as part of
the workflow. The code that is sent from the workflow-consumer to the
workflow-service is not self-contained -- it has dependencies on node modules
such as sdc-clients.

## Problem

Access to these modules is provided from within workflow, in an unversioned
way. Currently the consumer of workflow must assume that the module provided by
workflow is not out of date and that it has all of the functionality its job
code needs. This of course isn't necessarily the case, and can give rise to
flag days.

## Goal

Currently the consumers of workflow blindly send job code over, without regard
for whether the workflow service that's currently running can actually execute
it. We want to expose versioning information to the consumer so that it can
avoid sending code that'll break a workflow job. Or put in other words, so that
it can always send something that works, even if it doesn't have the latest
capabilities.

## Proposal

There are a few ways to implement this. The first way is to expose module
version information to the job-code, so that the jobs can conditionally execute
code depending on what version is available.

The second way is allow the workflow-consumer to specify -- in
module.exports.chain.\*.modules -- not only the name of the module it depends
on, but also the version. This way workflow, can drop/ignore a task in the
chain if the version doesn't match what's available.

The former method is more flexible, however version-ignoring job code can still
be written. The latter method forces the developer to explicitly think about
versioning, but it is more limited in its capabilities.

There are perhaps other, better ways of doing this that escape the author at
the moment.

## Developer Considerations

If either of the two above proposals are accepted, developers will have to
either a) specify a version as well as a module, or b) write job-code that will
detect the version. The former would be a requirement, while the latter would
be optional.

## Affected Repositories

Affected repositories include sdc-workflow, and pretty much everything that
sends jobs to it.

## Upgrade Impact

If changes are made to the affected repositories and any (but not all) of the
service instances that use these repositories are upgraded, we could
potentially have a problem if the workflow service is not updated and any of
its consumers are, or vice-versa.
