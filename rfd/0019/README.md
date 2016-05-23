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
    Copyright 2016 Joyent Inc.
-->

# RFD 19 Interface Drift In Workflow Modules


## Background

Triton can be defined as a collection of services and the interactions between
those services. Those interactions are facilitated by interfaces, be they
module/library interfaces or REST interfaces. Most bodies of software can be
described this way. However, what distinguishes a large project like Triton
from other large projects (like, say, SmartOS) is that the components of Triton
can be upgraded and downgraded independently of each other. In other words,
upgrades of the system are not atomic. As a result, we can't guarantee that all
the interfaces of a service that a consumer may want to use are actually
present.

All highly available distributed systems have to be robust when confronted with
drift between interfaces. Triton has an intricate web of dependencies between
its APIs. Most of those services simply depend on the REST interfaces provided
by other services. Handling the interface drift between _all_ of these services
is certainly an important problem to solve. However, this RFD focuses
specifically on the workflow service and its consumers because -- in addition
to the possible drift between the REST interfaces of these producers/consumers
-- there is a much more frequent (and therefore likely) drift between the
interfaces provided by Node modules _within_ workflow.

So far, five services in Triton -- namely, VMAPI, CNAPI, IMGAPI, DOCKER, and
ADMINUI -- interact with the workflow service to schedule and get information
about jobs. They do this by sending over raw Node code to the workflow, which
is then evaluated as part of the workflow. The code that is sent from the
workflow-consumer to the workflow-service is not self-contained -- it has
dependencies on node modules such as sdc-clients, which are provided by
workflow.

## Problem and Goal

Access to these modules is provided from within workflow, in an unversioned
way. Currently the consumer of workflow must assume that the module provided by
workflow is not out of date and that it has all of the functionality its job
code needs. This of course isn't necessarily the case, and can give rise to
flag days. Flag days are very undesirable, since they involve relying on an
actual human being to do the right thing. In fact, it sometimes involves
relying on _multiple_ human beings doing the exact same right thing, which is
unlikely to happen, and will simply result in at least one underemployed person
writing an unflattering blog post about the Triton upgrade experience. It is
therefore the goal to reduce the number of future flag-days to as small a
number as possible -- ideally zero. It is the goal of this RFD to eliminate
flag-days that result from interface drift in workflow modules.

Currently the consumers of workflow blindly send job code over, without regard
for whether the workflow service that's currently running can actually execute
it. We want to expose versioning information to the job code so that it can
avoid invoking functionality that does not exist. Or put in other words, so
that it can always send something that works, even if it doesn't have the
latest capabilities.

We want to expand the spectrum of interaction between workflow and its
consumers, so that they can ask questions about which workflow functionality is
too new, or too outdated. The proposals below are, of course, very far from a
full-fledged feature-flag implementation. But they are pragmatic, and will get
the job done.

## Proposals

There are two ways to (correctly) solve this problem. The first involves using
modules' version information and the second does not. They are described in the
sections below. They have been organized by how many changes need to be made to
the Triton repos, in increasing order. When discussing drift, both proposals
refer to workflow as 'the producer' and the client APIs as 'the consumer',
individually. Collectively they will be referred to as 'producers/consumers'.

### Versioning

When interface drift happens between workflow and a consumer, it can happen in
one of two ways: (1) workflow is ahead of the consumer by some number of
versions, and (2) workflow is behind the consumer by some number of versions.
In principle, it is possible for an up to date producer/consumer to be
cognizant of all the interface changes that have happened between itself and
its dependencies in the past. In other words, the up to date producer/consumer
can be written to adapt to any outdated interfaces. However, an out of date
producer/consumer cannot be written to adapt to up to date interfaces -- to be
able to do so reliably, one would need a time machine.

With this temporal distinction in mind, we can now focus on the
producers/consumers themselves. Either both workflow and the consumer are up to
date with each other, or one of them is out of date. It is the responsibility
of the _upgraded_ producer/consumer to provide the mechanism that allows for a
graceful degradation of service in the face of interface drift.

The job code needs to be able to detect where it is temporally, relative to
workflow and workflow's modules, and vice versa. The job code will need to be
able to detect the version of the module(s) made available by workflow, and
workflow will need to know what module-versions the job code expects.

In order for workflow to know what module-version the job code expects, the job
code needs to supply more detailed module dependency information.

For example, here is an element from the `chain` array belonging to the
`workflow` variable of the following VMAPI source file:
`lib/workflows/destroy.js`.

	...
	{
		name: 'cnapi.wait_on_vm_ticket',
		timeout: 120,
		retry: 1,
		body: common.waitOnVMTicket,
		modules: { sdcClients: 'sdc-clients' }
	}, 
	...

The job code would have to be modified to have an additional key called
`imports`:

	...
	{
		name: 'cnapi.wait_on_vm_ticket',
		timeout: 120,
		retry: 1,
		body: common.waitOnVMTicket,
		modules: { sdcClients: 'sdc-clients' }
		imports: { sdcClients: {name: 'sdc-clients', ver: '9.0.3'} }
	}, 
	...

The reason we create this object parallel to `modules`, instead of replacing
`modules`, is that this allows old versions of workflow to keep functioning
with new job code. We want to avoid flag days at all costs. Newer workflows can
use `imports` to determine which version of a module is expected by its
consumers.

Speaking of consumers, let's look at the consumer side of version awareness.
The job code's awareness of available module-versions would require metadata on
`sdc-workflow`'s side of things, that's similar to the `imports` information.

The most commonly used modules in workflow jobs are as follows:

	MODULE		TASKS DEPENDENT
	sdc-clients	156
	restify		24
	async		18
	vasync		5
	url		1

This is the code from `node-workflow` that 'links' the module into a task:

	...
	if (opts.task.modules) {
		if (typeof (opts.task.modules) !== 'object') {
			throw new TypeError(
			'opts.task.modules must be an Object');
		}
		Object.keys(opts.task.modules).forEach(
			function (mod) {
			global[mod] = require(opts.task.modules[mod]);
			sandbox[mod] = global[mod];
		});
	} 
	...

We can modify the code to inspect the job code's expected versions as follows:

	...
	if (opts.task.modules) {
		if (typeof (opts.task.modules) !== 'object') {
			throw new TypeError(
			'opts.task.modules must be an Object');
		}
		Object.keys(opts.task.modules).forEach(
			function (mod) {
			global[mod] = require(opts.task.modules[mod]);
			/* DELTA BEGIN */
			global['wf_current_versions'] = wf_current_versions;
			global['job_versions'] = [];
			global['job_versions'].push(opts.task.imports[mod]);
			global['semver'] = semver;
			var task_expects = opts.task.imports[mod].ver;
			var available = wf_current_versions[mod];
			/*
			 * The consumer is outdated.
			 */
			if (semver.gt(available, task_expects)) {
				/*
				 * On the off chance that backward compatibility
				 * was broken between `available` and
				 * `task_expects`, we abort the job.
				 */
				if (semver.diff(available, task_expects) ==
				    'major')) {
					/* abort w/ helpful error msg */
				}
				/* Otherwise, we can allow the job to continue */
			}
			/* DELTA END */
			sandbox[mod] = global[mod];
		});
	} 
	...

On the job code side of things, we can access (and branch on) the module
versions like so:

	if (semver.gt(job_versions['sdcClients'].ver,
	      wf_current_versions['sdcClients'].ver)) {
		/* try to get by with old functionality */
	} else {
		/* use awesome new function */
	}

Of course, workflow currently does not expose things like `wf_current_versions`
or `job_versions` or `semver`. If the job tried to use these new variables and
functions it would be trying to call/access `undefined` values.  This is why
`sdc-workflow` should expose an extra global:

	global['WORKFLOW_VERSIONING'] = true;

This way we can make the above job code robust against workflows that never
supported a notion of module-versioning:


	if (global.WORKFLOW_VERSIONING) {
		if (global.semver.gt(job_versions['sdcClients'].ver,
		      wf_current_versions['sdcClients'].ver)) {
			/* try to get by with old functionality */
		} else {
			/* use awesome new function */
		}
	}


### Versionless (aka Thinner Workflow, Thicker Services)

Solving the problem in a way that requires no version information, would be
very appealing. The most obvious way to do this, is to invert the relationship
between workflow and its consumers. Instead of consumers sending job code to
workflow, they would simply execute the job code themselves, and send job
progress-reports to workflow. Since all of the job code runs internally, all
module dependencies would be handled within the consumer's own repository.

Running the job code in the consumer APIs is very easy. The consumer can import
the `node-workflow` and the workflow JSON files. It could then run those JSON
files by invoking the `WorkflowRunner` object that comes with `node-workflow`.
One disadvantage of doing it this way is that there is less concurrency --
sdc-workflow forks a new process for every workflow. However, the service APIs
can also use fork. If one wants to be truly cautious, one could simply have an
`sdc-workflow` process running in each API zone. The zone's respective API can
remain unmodified in all aspects, except that it sends job code to the local
workflow instead of the remote workflow.

So the running of the workflows in the API zones is _not_ a problem. There are
a few ways to do it, depending on how much surgery you want to do on the APIs.
Either of the above modifications (importing `node-workflow` or running a
parallel `sdc-workflow`), would probably bump the phys-mem requirements of each
of the API zones. Probably not a concern for SDC on the metal, but may be
problematic for COAL.

The thornier aspect of this is what to do with the workflow zone itself. It
would still need to exist for a) backwards compatibility with unupgraded APIs,
and b) providing an established and stable interface to operators for getting
job information. Due to requirement (a) the workflow zone would need to retain
the ability to run workflows as it does now. Requirement (b) makes it necessary
to extend the workflow zone's interface to accept 'status updates' from the
APIs that run their own workflows. This way the operators would use the same
exact interface that they are used to using to get job info, even though the
jobs run in the API zone.

Because we still need a centralized workflow service, we still have a single
point of failure. In other words, the API zones cannot execute their workflows
if the central workflow service is not running. We don't get any resiliency
benefits that one would normally get by distributing a previously centralized
service.

In summary, this solution requires more physical resources, a larger number of
changes, and changes to the _roles_ of both workflow and its consumers, than
the versioning solution. Whether or not this cost is justified by the
'versionlessness' of this solution is hard to determine without some empirical
analysis.

## Empirical Analysis

It seems that before any kind of meaningful discussion can take place on the
merits of each approach, we will need to do some empirical analysis to make the
discussion about concrete quantitites, rather than abstract ideas. Simple
prototypes of each solution should be implemented and tested. What tests we
should be doing and what the prototypes should look like, is open to
discussion.
