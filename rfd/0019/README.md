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

A third way of solving this problem is to simply move the job-execution code to
the services that consume workflow, and have workflow be a coordinator --
workflow would know which jobs are being executed, and would recieve progress
updates from the services.

This approach essentially makes workflow thinner, and fattens up the \*API
services. It has the benefit of circumventing the versioning problem all
together, but it makes the logistics surrounding services more complicated.
Previously stateless services would now have state, and that would make them
harder to reboot on a whim. Furthermore there is more than one container for
each service. How would the load be distributed between these containers? Many
of the problems that have been solved by workflow, would have to be re-solved
for each service. This entails significant development effort, and replaces the
versioning problem with a handful of other problems (both forseen and
unforseen).

A fourth way of resolving this problem is to create a new endpoint for workflow
-- something like `/version` that will report the version of workflow itself to
the consumer, which then takes action based on that. This is similar to the
first method described above, however we are versioning the entire workflow
service instead of its modules, and the \*API service handles branching (as
opposed to its job code).

A fifth way of resolving this problem is a lot like the fourth way except
instead of a `/version` endpoint, we'd have a `/features` endpoint. And \*API
services will generate job-code based on the available features. This clearly
has the downside of forcing some kind of conditional code-generation logic in
the \*API services. But on the upside it is much more granular than the
previous solution.

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
