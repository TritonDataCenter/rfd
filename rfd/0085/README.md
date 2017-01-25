---
authors: David Pacheco <dap@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 85 Tactical improvements for Manta alarms

## Introduction

Manta uses amon-based probes and alarms to notify Operations and Engineering
when parts of the system are not functioning.  While the existing alarms do
generally fire when there's something wrong, the underlying problems range
enormously in severity and scope.  They may be:

- major issues affecting the data path or jobs path
- minor issues that don't affect the data path yet, but which might induce
  errors if left unresolved (e.g.,
  [QA-196](https://devhub.joyent.com/jira/browse/QA-196)).
- transient blips that may have affected a small number of requests, but are
  not ongoing
- issues with non-customer-visible background activities (e.g., GC failures)

For a variety of reasons, it's very time-consuming to understand the severity
and scope of a problem based on its notification, to enumerate the distinct
issues affecting Manta right now, and to enumerate the distinct issues that are
not yet diagnosed.  The result is that both Operations and Engineering waste a
lot of time re-diagnosing the same issues.  (Operations has long since disabled
notifications about Manta failures entirely because of the extremely low
signal-to-noise ratio.)

We also miss important issues in the noise and wind up debugging them much
later when they've caused cascading failures.

This RFD describes how Manta alarms work today, the problems that make them
difficult to work with, and a relatively modest list of proposed changes to
address the most burning issues.  Because subtle design choices have led to some
of these burning issues, it's worth examining the usability problems in some
detail to make sure we actually address them.

The underlying goals and design principles are described in [RFD
6](https://github.com/joyent/rfd/blob/master/rfd/0006/README.md).


## Manta alarms today

In amon terms:

* Each **probe** describes a specific check for a specific container (e.g.,
  watch log file /var/log/muskie.log in container
  "cd231b44-e285-11e6-ba10-f37241740ff1" for errors).
* **Probe groups** combine multiple probes whose failures are consolidated
  into a single alarm.  The way Manta groups probes into probe groups appears
  to be the heart of most of our issues.
* **Faults** are individual instances of a probe failure (e.g., an error message
  in /var/log/muskie.log on container "cd231b44-e285-11e6-ba10-f37241740ff1")
  Multiple faults for a given alarm may trigger new **notifications**, but may
  not.

For details on these terms, see the [amon
docs](https://github.com/joyent/sdc-amon/blob/master/docs/index.md).

Manta alarms are defined as a bunch of **probe templates** in the
[mantamon](https://github.com/joyent/mantamon/tree/master/probes) repository.
(They're not called probe templates explicitly, but that's what they are.)
Here's an example that runs a script to check on Manatee every minute:

    {
        "name": "manatee-stat",
        "type": "cmd",
        "config": {
            "cmd": "/opt/smartdc/manatee/bin/manatee-stat-alarm.sh",
            "interval": "60",
            "threshold": "5",
            "period": "360",
            "timeout": "60",
            "stdoutMatch": {
                "pattern": "fail",
                "type": "substring"
            }
        }
    }

This looks just like an [amon probe (see docs for what the fields
mean)](https://github.com/joyent/sdc-amon/blob/master/docs/index.md#probe-types),
except that it doesn't specify a specific container (technically, a specific
amon agent).  Instead, the Manta tooling will take this template, see that it's
in a file associated with "postgres" zones, and stamp out an amon probe _for
each postgres zone_.  That makes sense, because to monitor each zone with amon,
we need a probe for each zone.

More interesting is how these probes are grouped.  Today, probes are grouped by
the combination of the zone's role (e.g., "storage") and severity (e.g.,
"alert" or "info").  We'll ignore severity in this RFD because it's largely
orthogonal to the issues here.  As a result, we end up creating a single group
for all probes in "storage" zones:

                                       probe for storage zone A   probe for storage zone B
    check 1 (e.g., minnow heartbeat)   probegroup 1               probegroup 1
    check 2 (e.g., "error" log entry)  probegroup 1               probegroup 1
    check 3 (e.g., "svcs -xv")         probegroup 1               probegroup 1

As a result, when any of these probes fails in any zone, we get one alarm.  (We
do get multiple notifications, though.)


## Problems addressed by this RFD

### Many alarms cover multiple, unrelated issues

Because of the way probe groups are configured (described in detail above), it's
common to wind up with several different issues covered by one alarm.  In the
example above, if an alarm fires in a global zone because we failed to upload a
log file (see MANTA-3088), and subsequently `vm-agent` goes into maintenance
(see AGENT-1048), and subsequently `marlin-agent` logs an error (see
MANTA-2147), all three of these are grouped into a single alarm, even though
they're almost certainly different issues.

This is a particular problem in the "ops" zone, which has a number of
miscellaneous probes for Manta houskeeping operations.  These all wind up on the
same alarm:

    37   ops-alert          eae78bb  mackerel-storage-missing
    37   ops-alert          eae78bb  wrasse-behind
    37   ops-alert          eae78bb  mola-pg-transform-logscan-fatal
    37   ops-alert          eae78bb  mola-pg-transform-logscan-error
    37   ops-alert          eae78bb  mola-mako-files-piling-up
    37   ops-alert          eae78bb  mola-audit-logscan-fatal
    37   ops-alert          eae78bb  mola-moray-files-piling-up
    37   ops-alert          eae78bb  mackerel-request-missing
    37   ops-alert          eae78bb  mackerel-compute-missing
    37   ops-alert          eae78bb  manatee-backups-failed
    37   ops-alert          eae78bb  mackerel-summary-missing
    37   ops-alert          eae78bb  mola-job-running-too-long

even though there are several different issues here.

This obviously makes it hard to assess how many different problems there are at
any given time and even to track them in JIRA, as we'd often like to do because
even diagnosing several issues like this can take several engineer-days and
could be delegated among several people.

There a less obvious problem once you've actually resolved one of these issues:
you either have to leave the alarm open (which means you have to keep seeing it
in the list, which means you likely need to keep a separate list of issues that
are _actually_ unresolved) or you close the alarm.  But if you close it, you're
either papering over the other issues associated with the alarm (if they were
transient and don't reopen) or the system ends up firing off new notifications
for existing issues (which reduces the signal-to-noise-ratio for notifications).

**Proposal:** It seems like this situation could be greatly improved by grouping
probes by failure mode rather than by component.  So it would look like this:

                                       probe for storage zone A   probe for storage zone B
    check 1 (e.g., minnow heartbeat)   probegroup 1               probegroup 1
    check 2 (e.g., "error" log entry)  probegroup 2               probegroup 2
    check 3 (e.g., "svcs -xv")         probegroup 3               probegroup 3

This way, we get a new alarm for each distinct kind of probe failure (which
usually represent different failure modes).  When another instance of the
component experiences the same problem, we'll get a new notification, but not a
new alarm.  When we resolve the underlying issue, we can close that alarm and
know that we're not papering over some other problem, and the alarm should not
reopen.

Some additional research is needed about the existing probe templates to make
sure this makes sense for all of them.


### Same issue opens several alarms

The reverse also happens, where the same issue opens different alarms.  The most
common, fixable case of this seems to be when Manta is experiencing issues at
the top of the hour and many components fail to upload their log files.  This
winds up creating an alarm for each different component.  Each alarm winds up
with dozens of notifications (one for each instance).

Another failure mode that results in many alarms with many faults is when
ZooKeeper fails and every registrar instance reports that.

**Proposal:** These issues would be addressed by the above proposal to group
probes differently.  In this case, we'd create one probegroup for all components
that have a "log files piling up" probe or a "registrar logged an error" probe.


### Too many notifications for the same issue

Manta deployments can have many instances of a given component (e.g., hundreds
of global zones).  It's fairly common for one problem (e.g., an agent going
into maintenance) to affect all of them.  We end up getting hundreds emails and
chat messages for the same issue.

amon actually has support for suspending notifications for an alarm, but the
previous issues make that dangerous.  Additionally, there's no tooling for it.

**Proposal:** Once we've separated different issues into different alarms, it's
reasonable to have a tool that can update amon to suppress notifications for an
alarm.


### Known issues are difficult to ignore

At any given time, there are often a handful of known issues that fire alarms.
(Nearly any alarm that fires as a result of a bug winds up in this category for
some period of time until the bug fix is deployed.)  Since the set of known
issues changes over time, but slowly, and these issues may manifest as any
number of underlying alarms, these make it hard to get a handle on which new
notifications and which open alarms are actually relevant.

**Proposal:** This should also be addressed with support for suspending
notifications for an alarm.


### Alarm messages are difficult to understand

Most Manta alarms include the contents of bash scripts or JSON log messages.
Here's an example:

    Subject: [Alarm: probe=minnow heartbeat too old, vm=storage.us-east.scloud.host-e864b1c6, type=cmd] poseidon#55 in us-east-1c

    Alarm: 55 (alarm is open)
    Time: Sun, 22 Jan 2017 00:22:44 GMT
    Data Center: us-east-1c


    {
      "v": 1,
      "type": "probe",
      "user": "8a70155f-752f-eb91-a755-f4edbee5c99f",
      "probeUuid": "d1d65d1c-fc0c-4f2c-8acd-80b538debfa9",
      "clear": false,
      "data": {
        "message": "Command failed (exit status: 2).",
        "value": 3,
        "details": {
          "cmd": "/bin/bash -c 'let delta=$(date +%s)-$(PATH=/opt/smartdc/minnow/build/node/bin:/opt/smartdc/minnow/node_modules/.bin:$PATH findobjects -h $(cat /opt/smartdc/minnow/etc/config.json | json moray.host) manta_storage hostname=$(hostname)* | json -e _mtime=_mtime/1000 -e _mtime=~~_mtime _mtime) ; test $delta -lt 900'",
          "exitStatus": 2,
          "signal": null,
          "stdout": "",
          "stderr": "findobjects: moray client \"1.moray.us-east.scloud.host\": failed to establish connection\n/bin/bash: let: delta=1485044563-: syntax error: operand expected (error token is \"-\")\n/bin/bash: line 0: test: -lt: unary operator expected\n"
        }
      },
      "machine": "e864b1c6-fdf7-4cce-af6d-9b1353b1caa0",
      "uuid": "f6a5f6f7-ff9d-c8ab-97a1-e0a0bc8f3ac7",
      "time": 1485044564434,
      "agent": "e864b1c6-fdf7-4cce-af6d-9b1353b1caa0",
      "agentAlias": "storage.us-east.scloud.host-e864b1c6",
      "relay": "00000000-0000-0000-0000-0cc47adeaa56"
    }

If you aren't accustomed to reading these notifications, it may take some time
to understand what this means.  Most immediately, this alarm is telling us that
a script we configured to run periodically exited with status 2 instead of 0.
We have the contents of the script, the stdout, and the stderr.  We don't have
any indication about what this means in terms of Manta, the user-facing impact,
any automated response, or suggested action.

**Proposal:** create documentation for common probe failures that includes
information like the following:

* severity: normal
* synopsis: minnow heartbeat record may be out of date
* description: The system failed to verify that a storage container's heartbeat
  records are being reported.  This may indicate that the storage container is
  offline or that the database shard that stores these records is offline.
* impact: If the storage zone is offline, objects created with only one copy
  will be unavailable from the data path and for jobs.  If multiple storage
  zones are offline, some objects created with more than one copy will also be
  affected.  If this is a multi-datacenter deployment, availability of objects
  with more than one copy requires at least one storage zone to be offline in at
  least two datacenters.  In these cases, writes are unaffected as long as there
  are enough storage containers remaining to accept writes.  If the database
  shard storing these heartbeat records is offline, then reads and job tasks are
  unaffected, but the system may be completely unavailable for writes.
* automated response: If possible, requests for objects and tasks operating on
  objects stored in the affected storage container will be directed to other
  storage containers that have a copy of the object.  When this is not possible
  because all storage containers with a copy of the object are offline, some
  requests and tasks will fail.
* suggested action: Determine whether the storage container is offline and take
  action to bring it back online.  The underlying compute node may have
  rebooted or lost power or the heartbeating service may have failed.

This format is intended to match the [knowledge
articles](https://github.com/joyent/rfd/tree/master/rfd/0006#knowledge-articles)
that are part of the operating system's FMA.  As with FMA, each knowledge
article could be assigned a unique ID that we could include in the probe's name.
That way, it's in the amon notification message.  The chat bot could notice this
and report the detailed information.  It would be ideal if amon included this in
emails, but there's a lot of complexity associated with that, and it's probably
beyond the scope of this work.
 
Of course, we still need the low-level information about what script was run and
the results so that we can debug the problem.


### mantamon reports all open faults, not alarms

"mantamon alarms" lists faults, not alarms.  This makes some sense given the
previously-mentioned issue where alarms cover multiple distinct issues, but it
creates a separate problem: assessing what's actually broken right now is much
harder because of all the duplicate lines of output.  The better answer seems to
be to make sure alarms cover only one issue, and then have "mantamon alarms"
list alarms.

**Proposal:** "mantamon alarms" should list actual alarms, along with a count of
faults.  There should be another subcommand or option to list faults in detail.


## Problems not addressed here

There are a number of issues not addressed by this RFD.  These are worth
cataloguing for future reference.  It might also turn out in discussing this RFD
that we'd rather address all the issues holistically rather than continue
incrementally improving what we've got.

**Metrics:** We still have no robust historical nor real-time metrics, so we
still have no good way to notify when the request rate drops, when the error
rate spikes, or any number of other metric-based issues go awry.

**Tracking alarms with tickets:** We described cases where we would like to
suppress notifications for an issue.  Ideally, we'll want to re-enable
notifications when we believe the underlying issue is resolved, but how do we
know when that is?  It would be nice to be able to tag alarms with ticket
identifiers that could contain additional information about the problem and why
it's still outstanding.  For bugs, this might be a MANTA ticket.  For other
issues that aren't software bugs (e.g., a CN is down for hardware component
replacement), this might be an OPS ticket.

**Lack of topology information when different alarms fire because of shared
dependencies:** Often, many different probes end up firing for the same
underlying issue.  For example, if a storage node reboots, we typically get
several alarms:

- an nginx "ping" alarm fires because it can't reach nginx on the storage node
- a jobsupervisor alarm fires to report that the agent on that CN has disappeared
- if the server is down at the top of the hour, its logs may not upload

Similarly, if CPU utilization exceeds an alarming threshold, that's a CN-wide
problem, but separate alarms fire for each component on that CN (often postgres,
loadbalancer, moray, electric-moray, and webapi).  This was originally intended
to help convey the scope of the problem (i.e., that it affects all those
components), and that's nice to have, but there's really one underlying issue
(CPU utilization on that CN), and it's confusing to have it show up several
times (and none with an indication of which CN it is).  We probably ought to
re-group these so that there's one "CPU utilization" probe group with faults
(not alarms) for each component.  That still won't make it easy to identify
which CN has the problem, but it will reduce the number of distinct alarms for
the same issue.

Longer-term, it would be better if amon understood the topology of services so
that you could query it for issues affecting a given CN, service, or instance.
This way you also wouldn't have to choose just one grouping scheme: sometimes
it's useful to be able to see all the problems by failure mode (as we do in this
RFD), but sometimes it is more useful to see them by component.

**Lack of topology information leads to exact duplicate alarms:**  When a
Manatee shard has a problem, we wind up with one alarm per datacenter instead of
just one alarm because each PostgreSQL instance has the probe configured.  Once
we have topology information, it would be nice to be able to include metadata
like "shard" and say that a probe check should be executed once per shard per
unit time, not once per unit time.

**Maintaining probes:** Today, probes are not created and removed automatically
when instances are deployed and removed.

**Ability for operators to add probes:** It's often desirable to add probes for
known runtime issues (e.g., [OS-5363](https://smartos.org/bugview/OS-5363)).
There's no tooling to support this today, and the probes may be dropped by
a subsequent "mantamon drop".

**Loosey-goosey bash scripts:** Many Manta probes today are implemented as
inline bash scripts that are not very readable, have no comments, do not
always check for errors, and often produce syntax errors when a dependent
command fails.  They do not distinguish between the check failing and the
actual condition that they're checking being violated.

**Managing the delivery of probe dependencies:** There's a subtle but serious
issue resulting from the fact that probes are defined only in one place (the
manta deployment zone) today: if we want to add a more sophisticated check that
depends on tools provided by a new version of a given zone, there's a flag day
in the alarm definition, and there's no good way to manage this.

This happened when we created the new "manatee-adm verify" command, which was
essentially created for programmatically identifying when there's something
wrong with a Manatee cluster.  However, we weren't able to update the Manta
alarms to use this new command until we knew we'd updated all Manatee instances
to a version that provides the command.  This is a nice pattern because it
allows the component to define how to tell when something's wrong with it and
integrate that with tools that summarize status for operators, but it's hard to
deal with the resulting flag day.

This is a big deal if we want to address the bash script problem above.  The
natural way to address that problem would be to have each component deliver
formatted, documented, diagnostic programs, but each of these would represent a
flag day.  It would be better if each component somehow registered probes with
amon.  But this adds a bunch of complexity (including versioning of the probes
themselves).

Adding to the complexity is that we'd still want system-defined probes that
apply to all zones (e.g., based on low free space or swap allocation failures),
and we'd still want operator-defined probes.

**Summary:** There are a lot of serious issues here, and it's not clear that the
best way forward leverages what we've already built (even with the changes
proposed by this RFD).  However, at this point the operational problems are so
acute and a complete solution so incompletely understood that we think it's
worth doing the incremental work proposed here.

## Summary of proposed changes

- For each probe template we already have (at least for major ones), add
  documentation about the check similar to what's described above.  Tag each
  piece of documentation with a unique identifier and include this in the probe
  group's name.
- Tooling changes:
  - "mantamon add" should create probe groups for each probe template rather
    than just for each component.
  - "mantamon alarms" should list only alarms, not faults.  There should be
    additional options to list the faults associated with an alarm.
  - "mantamon" needs an subcommand for suppressing notifications for an alarm.
  - "mantamon" probably needs a subcommand for managing maintenance windows.

"mantamon add" and "mantamon drop" likely need to deal with systems that
already have groups deployed with the old organization scheme.

## Open questions

We need to review the existing probe templates to make sure this scheme works
for them.

It's not clear how much of today's "mantamon" is worth preserving.  Note that
none of this behavior is Manta-specific, so this could become a generic amon
management tool suite.

It would be good if these knowledge articles were actually part of the FMA event
registry described in RFD 6.  It's not yet clear how best to do that.  However,
it should be possible to define these in a structured form in a repository that
could later be transformed into any other event registry format.


## Repositories affected

The existing repositories that would be affected by this are:

- `sdc-manta`: manta deployment tooling, which delivers `mantamon`
- `mantamon`: contains the probe templates and tooling used to manage Manta
  alarms today

As mentioned above, we may end up wanting to separate the tools from the
configuration, and we'll be adding documentation.  The specific new
repositories for this are still TBD.


## Upgrade impact

Generally, when updating across this change, old probes should continue to work,
but options for configuration are limited until operators explicitly update to
the new organization scheme.  Operators will not be able to add new probes until
they've removed all of the old probe groups.  The tool will refuse to add probes
while there are old probe groups around.

The expected workflow will be to update the tooling (by updating the "manta"
zone), drop all probes, then re-add all probes.  The only downside to doing this
is that open alarms will need to be closed, but we consider this impact minimal.

It's likely an operator will not realize they need to do this until some time
later when they try to update probe configuration or list open alarms, but they
can just update the probes at that point.  The old probes will continue to
function in the meantime.

If the operator later chooses to roll back, they will need to first remove all
probes, then rollback, then re-add probes with the old tools.


## Security implications and interfaces changed

There are no end-user security implications because these are all private
interfaces.

Additionally, no interfaces are being created or changed, nor additional private
information being provided to a consumer that couldn't already access it.


## See also

* [RFD 6](https://github.com/joyent/rfd/tree/master/rfd/0006) Improving Triton
  and Manta RAS Infrastructure
* [Amon](https://github.com/joyent/sdc-amon/blob/master/docs/index.md)
* [mantamon](https://github.com/joyent/mantamon)
