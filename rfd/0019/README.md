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
those services. Those interaction are facilitated by interfaces, be they
module/library interfaces or REST interfaces. Most bodies of software can be
described this way. However, what distinguishes a large project like Triton
from other large projects (like, say, Illumos) is that the components of Triton
can upgraded and downgraded independently of each other. In other words,
upgrades of the system are not atomic. As a result, we can't guarantee that all
the interfaces of service that a consumer may want to use are actually present.

All highly available distributed systems have to be robust when confronted with
drift between interfaces. Triton has an intricate web of dependencies between
its dozen or so services. Most of those services simply depend on the REST
interfaces provided by other services. Handling the interface drift between
_all_ of these services is certainly an important problem solve. However, this
RFD focuses specifically on the workflow service and its consumers because --
in addition to the possible drift between the REST interfaces of these actors
-- there is a much more frequent (and therefor likely) drift between the
interfaces provided by Node modules _within_ workflow.

So far, five services in Triton -- namely, VMAPI, CNAPI, IMGAPI, DOCKER, and
ADMINUI -- interact with the workflow service to schedule and get information
about jobs. They do this by sending over raw Node code to the workflow, which
is then evaluated as part of the workflow. The code that is sent from the
workflow-consumer to the workflow-service is not self-contained -- it has
dependencies on node modules such as sdc-clients.

## Problem and Goal

Access to these modules is provided from within workflow, in an unversioned
way. Currently the consumer of workflow must assume that the module provided by
workflow is not out of date and that it has all of the functionality its job
code needs. This of course isn't necessarily the case, and can give rise to
flag days. Which are very undesirable, since they involve relying on an actual
human being to do the right thing. In fact, it involves relying on _multiple_
human beings doing the exact same right thing. Which is likely not going to
happen, and will simply result in at least one underemployed person writing an
unflattering blog post about the Triton upgrade experience. It is therefor the
goal to reduce the number of future flag-days to as small a number as possible
-- ideally zero. It is the goal of this RFD to eliminate flag-days that result
from interface drift in workflow modules.

Currently the consumers of workflow blindly send job code over, without regard
for whether the workflow service that's currently running can actually execute
it. We want to expose versioning information to the job-code so that it can
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
refer to 'workflow' and 'the consumer', individually. Collectively they will be
referred to as two 'actors'.

### Versioning

When interface drift happens between workflow and a consumer, it can happen in
one of two ways: (1) workflow is ahead of the consumer by some number of
versions, and (2) workflow is behind the consumer by some number of versions.
In principle, it is possible for an up to date actor to be cognizant of all
the interface changes that have happened between itself and its dependencies in
the past. In other words, the up to date actor can be written to adapt to any
outdated interfaces. However, an out of data actor cannot be written to adapt
to up to date interfaces -- to be able to do so reliably, one would need a time
machine.

With this temporal distinction in mind, we can now focus on the actors
themselves. Either both workflow and the consumer are up to date with each
other, or one of them is out of date. It is the responsibility of the _newer_
actor to provide the mechanism that allows for a graceful degradation of
service in the face of interface drift.

The job-code needs to be able to detect where it is temporally, relative to
workflow and workflow's modules, and vice versa. The job-code will need to be
able to detect the version of the module(s) made available by workflow, and
workflow will need to know what module-versions the job-code expects.

In order for workflow to know what module-version job-code expects, the
job-code needs to supply more detailed module dependency information.

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

The job-code would have to be modified to have an additional key called
`modules_plus`:

	...
	{
		name: 'cnapi.wait_on_vm_ticket',
		timeout: 120,
		retry: 1,
		body: common.waitOnVMTicket,
		modules: { sdcClients: 'sdc-clients' }
		modules_plus: { sdcClients: {name: 'sdc-clients', ver: '9.0.3'} }
	}, 
	...

The reason we create this object parallel to `modules`, instead of replacing
`modules`, is that this allows old versions of workflow to keep functioning
with new job-code. We want to avoid flag days at all costs. Newer workflows can
use `modules_plus` to determine which version of a module is expected by its
consumers. In the fullness of time, the `modules` will likely be removed, and
`modules_plus` will be renamed to `modules`, in effect replacing it.

We should also keep in mind that it is possible to depend, not on a version of
a module, but on any arbitrary commit SHAs in that module's RCS history. This
is deeply unfortunate, since the SHAs on their own don't contain any temporal
information. Regardless, I'd suggest specifying this kind of dependency like
so:

	...
	{
		name: 'cnapi.wait_on_vm_ticket',
		timeout: 120,
		retry: 1,
		body: common.waitOnVMTicket,
		modules: { sdcClients: 'sdc-clients' }
		modules_plus: { sdcClients: {name: 'sdc-clients',
		    ver: 'ee86d6312' } }
	}, 
	...

Since the SHAs are not as temporally descriptive as semantic versions, workflow
will need to provide a few helper functions to allow the job-code to determine
its temporal position relative to workflow. Which brings us to the
consumer-side of version awareness.

The job-code's awareness of available module-versions, would require metadata
on `sdc-workflow`'s side of things, that's similar to the `modules_plus`
information.

Workflow has to store much more information because it has to store a sequence
of SHAs in some kind of temporal order. This may sound crazy, but if a
developer had go in and make changes to a module like `node-sdc-clients`, then
they also had to touch `package.json` to specify the new SHA (so that they
could run `make all`). This also means that they are in an ideal position to
update the tables that store the SHAs and versions. It's extra work, but it
seems necessary to provide robust behavior in the face of drift between module
interfaces.

The most commonly used modules in workflow jobs are as follows:

	MODULE		TASKS DEPENDENT
	sdc-clients	156
	restify		24
	async		18
	vasync		5
	url		1

The history of `sdc-workflow`'s package.json, shows sdc-workflow depending
on a SHA of sdc-clients, instead of a semantic version, while the other modules
above are specified with a semantic version. 

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

We can modify the code to inspect the job-code's expected versions as follows:

	...
	if (opts.task.modules) {
		if (typeof (opts.task.modules) !== 'object') {
			throw new TypeError(
			'opts.task.modules must be an Object');
		}
		Object.keys(opts.task.modules).forEach(
			function (mod) {
			global[mod] = require(opts.task.modules[mod]);
			/* HERE */
			global['wf_current_versions'] = wf_current_versions;
			global['job_versions'] = [];
			global['job_versions'].push(opts.task.modules_plus[mod]);
			global['isVerGrtrThan'] = isVerGrtrThan;
			var task_expects = opts.task.modules_plus[mod].ver;
			var available = wf_current_versions[mod];
			/*
			 * The consumer is outdated.
			 */
			if (isVerGrtrThan(available, task_expects)) {
				/*
				 * On the off chance that backward compatibility
				 * was broken between `available` and
				 * `task_expects`, we abort the job.
				 */
				if (!isBackComp()) {
					/* abort w/ helpful error msg */
				}
				/* Otherwise, we can allow the job to continue */
			}
			/* HERE */
			sandbox[mod] = global[mod];
		});
	} 
	...

The `isVerGrtrThan()` function essentially compares the positions of the
versions (be they SHAs or semantic versions -- they are just strings) in
another global object that is of the following type:

	var wf_historical_versions =
	    { $mod_name: [ $ver1, $ver2, $sha1, $ver3, $sha2, ... ], ... };

The `isBackComp()` function checks for backwards compatibility. It also does a
lookup on an in-memory array, that is updated by the developers whenever they
bump any of the dependencies.

	var wf_back_comp =
	    { $mod_name: [ { ver: $ver1, breaks_bc: false}, { ver: $ver2,
		breaks_bc: true }, { ver: $ver3, breaks_bc: false }, ... ],
	      $mod_name: [ { ver: $ver1, breaks_bc: false}, { ver: $ver2,
		breaks_bc: true }, { ver: $ver3, breaks_bc: false }, ... ],
	     ...
	    }

It is obviously possible to neglect this table, which would make the results of
`isBackComp()` useless. However, we _can_ extend our test infrastructure to
test workflow against current and old versions of the consumers that use it. If
we get any kind of job failure that does not look like the 'helpful error msg'
in the comment above, we should investigate the BackComp tables.

The `wf_back_comp` table, and the `isBackComp()` function are there to provide
a mechanism that can helpfully bail the job out, if backwards compatibility was
broken, which _can_ happen. However, I'd like to point out that almost all of
the modules that workflow exposes to the job-code were _created by the Joyent
engineering organization_. We really should put in every effort to maintain
backwards compatibility between versions of our modules. But in case we break
something, the above mechanism could prove useful. Also, we should purge
`async` (which is not maintained by the organization) from all of our job code,
and replace it with `vasync`.

On the job-code side of things, we can access (and branch on) the module
versions like so:

	if (isVerGrtrThan(job_versions['sdcClients'].ver,
	      wf_current_versions['sdcClients'].ver)) {
		/* try to get by with old functionality */
	} else {
		/* use awesome new function */
	}

Of course, workflow currently does not expose things like `wf_current_versions`
or `job_versions` or `isVerGrtrThan`. If the job tried to use these new
variables and functions it would be trying to call/access a `undefined` values.
This is why `sdc-workflow` should expose an extra global:

	global['WORKFLOW_VERSIONING'] = true;

This way we can make the above job-code robust against workflows that never
supported a notion of module-versioning:


	if (WORKFLOW_VERSIONING) {
		if (isVerGrtrThan(job_versions['sdcClients'].ver,
		      wf_current_versions['sdcClients'].ver)) {
			/* try to get by with old functionality */
		} else {
			/* use awesome new function */
		}
	}


### Versionless (aka Thinner Workflow, Thicker Services)

Solving the problem in a way that requires no version information, is an
appealing proposition. It sounds elegant and simple, and in may ways it is.
However, it would require starting with a blank sheet of paper, so to speak.
The idea is to invert the relationship between workflow and the consumers.
Instead of consumers sending job-code to workflow, they would simply execute
the job-code themselves, and send job progress-reports to workflow. Since all
of the job code runs internally, all module dependencies would be handled
within the consumer's own repository.

This solution has a few major problems. First, workflow would have to be
modified to behave like more of a progress-bar than a task-runner. All of the
workflow-logic for handling timeouts and retries for each task would have to be
moved into the services. This would mean that each service would need to be
rewired to run the existing workflows through the `node-workflow` module. But
it would also have to send a copy of the task chain to the new workflow, and
send status updates for each task. This would be necessary, so that operators
could see task failures and successes, and so that they could do so using
interfaces (be they programming or operational) that they are familiar with.

The second problem is that services (including the workflow service) can be
upgraded and downgraded in any order. This means that even if we have this new
versionless generation of services ready for deployment, they may be deployed
at the operator's discretion. This means that a FWAPI or VMAPI that is of this
versionless generation may be deployed before the versionless workflow gets
deployed. If they are expecting progress-update endpoints, they won't be able
to use workflow at all. They can in principle continue functioning, without
updating the progress-info in workflow. However, this would no doubt cause a
lot of operator confusion: "I can't find the job for that VM that is
provisioning -- better open a support ticket so that Joyent, can fix this".

The other scenario is that one deploys a versionless workflow without updating
the consumers. The consumers may be trying to send job code over to a new
workflow that can't even execute jobs.

Of course, there _is_ a way around this. Workflow can act as a progress-bar for
those services that run their own jobs, but can keep executing job-code for
services that have not been updated to do their own work. But this means that
we have essentially _two_ workflow services in the same address space that do
two _very_ different things. If we do it this way -- and we would have to since
we care about backwards compatibility -- we would end up with an even more
complicated workflow service that would present more opportunities for operator
confusion (and panic). So while the versionless idea seems like it would make
workflow thinner and the services thicker, all it would do is make both the
services and workflow thicker.

It is difficult to quantify how much work would be needed to implement this,
but it would likely be extensive as it would involve 1) a restructuring of all
of the services that communicate with workflow, 2) new status update code, 3)
new workflow code that does something very different from what it does now.

### Comparison

The versionless approach seems like something that would be a great idea, if we
were designing Triton on a blank sheet of paper, and didn't have to concern
ourselves with the logistics of upgrading existing deployments of the product.
But because of these concerns we can't simplify workflow, without breaking
backwards compatibility. What we end up with in either case, is a 'bag on the
side of workflow' (to borrow a phrase from Steve Wallach). The versioned
approach results in a smaller, more manageable bag than the versionless
approach.
