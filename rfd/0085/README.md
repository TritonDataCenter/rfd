---
authors: David Pacheco <dap@joyent.com>
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
difficult to work with, and a modest list of proposed changes to address the
most burning issues.  Because subtle design choices have led to some of these
burning issues, it's worth examining the usability problems in some detail to
make sure we actually address them.

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

The "Proposed probe groups" section below discusses exactly how this scheme
applies to all existing Manta probes.


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
rate spikes, or any number of other metric-based issues go awry.  The unofficial
plan for this is to integrate CMON and Prometheus with Manta.

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
There's no tooling to support this today, and the probes would be dropped by a
subsequent "mantamon drop".

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


## Proposed probe groups

This section lists all probes in Manta today and how they will be grouped after
this change.  As mentioned above, probes today are grouped by the type of zone
(also called the _role_ or the SAPI service name).  The proposal is to replace
most of these with a single probe group per datacenter (per probe), but there
are several special cases as well.

These are the criteria for putting probes into probe groups:

* If two problems are likely to have different root causes or different
  remediation steps, they probably should be in different probe groups.  This
  allows us to more easily divide up work of debugging and fixing alarms, and
  it also allows us to disable or enable notifications for known issues without
  affecting notifications for different issues.
* If two problems are likely to be caused by the same underlying issue (e.g.,
  Registrar in both Muskie and Moray reporting an error), they probably should
  be in the same probe group (even if they're in different types of zones, as
  in this case).

### Service-specific probes

These probes all currently apply to a specific service, though in some
cases the check runs in a zone for a different service than the one being
monitored.  Even though they're per-service, it still makes sense to move away
from per-service probegroups because we want different failure modes to
generate different alarms even if they're in the same type of zone.

Current probe name                                      | Proposed grouping    | Notes
------------------------------------------------------- | -------------------- | -------
mahi v1 falling behind by more than 5000 changenumbers  | One per DC           | "authcache" zones only 
mahi v2 falling behind by more than 5000 changenumbers  | One per DC           | "authcache" zones only
redis-ok                                                | One per DC           | "authcache" zones only
haproxy memory size (1G)                                | One per DC           | "loadbalancer" zones only
muppet memory size (512M)                               | One per DC           | "loadbalancer" zones only
stud memory size (1G)                                   | One per DC           | "loadbalancer" zones only
no backend servers                                      | One per DC           | "loadbalancer" zones only
ZK: ruok                                                | One per DC           | "nameservice" zones only
mackerel-compute-missing                                | One per DC           | "ops" zones only
mackerel-request-missing                                | One per DC           | "ops" zones only 
mackerel-storage-missing                                | One per DC           | "ops" zones only 
mackerel-summary-missing                                | One per DC           | "ops" zones only 
manatee-backups-failed                                  | One per DC           | "ops" zones only
mola-create-link-files-piling-up                        | One per DC           | "ops" zones only
mola-job-running-too-long                               | One per DC           | "ops" zones only
mola-mako-files-piling-up                               | One per DC           | "ops" zones only 
mola-moray-files-piling-up                              | One per DC           | "ops" zones only 
wrasse-behind                                           | One per DC           | "ops" zones only
database dataset space running low                      | One per DC           | "postgres" zones only
manatee-stat                                            | One per DC           | "postgres" zones only
manatee-state-transition                                | One per DC           | "postgres" zones only
minnow heartbeat too old                                | One per storage zone | "storage" zones only
shrimp-nginx-ping                                       | One per storage zone | checks "storage" zones, but runs in "webapi"


### Generic probes

These probes apply to all non-global zones, all global zones, or both.  A few of
these are easy:

Current probe name          | Proposed grouping    | Notes
--------------------------- | -------------------- | -----
free space on / below 20%   | One per DC           | applies to all non-GZs
logs not uploaded           | One per DC           | applies to all non-GZs
mbackup: logs not uploaded  | One per DC           | applies to GZs only

A more complicated case is the "svcs: SMF maintenance" probe.  Ideally, we would
get a new alarm for each distinct SMF service FMRI that goes into maintenance.
(So if 18 "registrars" went into maintenance, that would be one alarm.  But if a
"config-agent" went into maintenance, that would be a different alarm.)  That's
because often many instances of a service go into maintenance for the same
reason, and that may be a known issue for which we'd like to suspend
notifications, but we don't want to squelch notifications when other services in
the same zone or service go into maintenance.  Amon does not support this, but
we can approximate it by keeping the one-probegroup-per-service pattern that's
used prior to this change.

Current probe name          | Proposed grouping    | Notes
--------------------------- | -------------------- | -----
svcs: SMF maintenance       | One per service      |


Less obvious is what to do with the "cpu utilization" probe.  This is currently
attached to all non-global zones, but it measures server-wide CPU utilization.
As a result, when it fires today, it opens one alarm for each type of zone on
the CN.  This was done so that we'd understand which components were affected by
CPU saturation, but it makes it more difficult to understand the CNs affected.
Keeping with the pattern, we propose putting these probes into one probe group
per datacenter.  We may want to explore putting the probes on GZs instead of
non-global zones, but that's basically orthogonal.

Current probe name          | Proposed grouping    | Notes
--------------------------- | -------------------- | -----
cpu utilization             | One per DC           |



### Log scanning probes

Scanning logs and firing alarms based only on the severity of the message does
not lend itself to providing actionable messages for each type of problem.
In the long term, we probably need to replace error- and fatal-level messages
with messages that have a well-known property (similar to FMA's event classes)
that identifies the specific problem (and effectively the knowledge article
associated with this issue).  In that world, we would have one probegroup per
distinct kind of problem.

That's beyond the scope of this RFD, so the plan here is to maintain one probe
group per log file monitored.  This roughly corresponds to one probe group per
probe.  This differs from what we have today, where any log files in the same
type of zone are grouped together.  Two cases worth mentioning are:

* Today, because the Registrar log scanner is grouped with other log scanners in
  the zone, when Registrar hits a problem, we get one alarm per service instead
  of just one alarm.
* Today, if many different components within a service hit a problem
  (particularly in the "ops" zone, which has a lot of different components whose
  alarms are driven by their log files), they all get grouped into one alarm.

In the new scheme, there would be one probe group for all Registrar log files in
all components and one probe group for each distinct log file in the "ops" zone
(and other zones).

Probe name                               | Messages matched      | Proposed grouping
---------------------------------------- | --------------------- | ----------------
binder: logscan                          | bunyan: error only    | one per DC
electric-moray-logscan                   | bunyan: error only    | one per DC
jobsupervisor-logscan-core               | regex related to "dumped core" | one per DC
jobsupervisor-logscan-error, jobsupervisor-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
mackerel-logscan                         | bunyan: fatal only    | one per DC
mahi-replicator-logscan-error            | bunyan: error only    | one per DC
mahi-server-logscan-error                | bunyan: error only    | one per DC
mako-gc-logscan                          | string: "fatal error" | one per DC
manatee-backupserver-logscan             | bunyan: fatal only    | one per DC
manatee-logscan                          | bunyan: fatal only    | one per DC
manatee-snapshotter-logscan              | bunyan: fatal only    | one per DC
marlin-agent-logscan-core                | regex related to "dumped core" | one per DC
marlin-agent-logscan-error,marlin-agent-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
minnow-logscan                           | bunyan: error only    | one per DC
mola-audit-logscan-error,mola-audit-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
mola-gc-create-links-logscan-error,mola-gc-create-links-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
mola-logscan-error,mola-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
mola-moray-gc-logscan-error,mola-moray-gc-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
mola-pg-transform-logscan-error,mola-pg-transform-logscan-fatal | bunyan: error and fatal | one per DC (for both probes)
moray-logscan                            | bunyan: "error" only  | one per DC 
muppet-logscan                           | bunyan: "error" only  | one per DC
muskie-logscan                           | bunyan: "error" only  | one per DC
pg\_dump-logscan                         | regex "fatal"         | one per DC
registrar-logscan                        | bunyan: "fatal" only  | one per DC
ZK: logscan 'Connection refused'         | regex                 | one per DC
ZK: logscan 'ERROR'                      | regex                 | one per DC

This change does not address any of the other potential issues here:

* There are no probes for the config-agent log.
* Many probes only match "error"-level bunyan messages or "fatal" ones, but not
  both.
* Most services do not watch the log files for events where the service dumped
  core.  That said, since Manta is supposed to survive service failure, core
  dump notifications are not necessarily critical, and may be better driven by
  thoth.


## Status of this RFD

Done:

- basic outline of goals and plan
- research existing probe groups and how to restructure them
- prototype of new probe group configuration, documentation, and command-line
  interface using `manta-adm` that supports updating probes and probe groups;
  listing alarms, faults, and probe groups; and enabling and disabling alarm
  notifications.
- prototype knowledge article content for all probes today
- proposed changes: https://cr.joyent.us/#/q/topic:MANTA-3195

Tickets:
- [MANTA-3195 manta amon configuration could use work](http://smartos.org/bugview/MANTA-3195)
- [MANTA-3196 want tool for creating and managing amon maintenance windows](http://smartos.org/bugview/MANTA-3196)

## manta-adm CLI changes

Due to all of the existing issues with `mantamon` (see tickets linked to
MANTA-3195), and because `manta-adm` is intended to be a unified interface for
administering Manta, the proposal is to deprecate `mantamon` entirely and build
a new set of commands under `manta-adm alarm`.

Below is the proposed change to the manual page to describe these changes.  You
can currently see the latest version of the proposal in [the feature branch for
this
work](https://github.com/joyent/sdc-manta/compare/master...davepacheco:dev-RFD-85).
Look at "docs/man/man1/manta-adm.md", and select the "rich diff" to see a
rendered version.

    diff --git a/docs/man/man1/manta-adm.md b/docs/man/man1/manta-adm.md
    index 6c50d43..a35e050 100644
    --- a/docs/man/man1/manta-adm.md
    +++ b/docs/man/man1/manta-adm.md
    @@ -1,4 +1,4 @@
    -# MANTA-ADM 1 "2016" Manta "Manta Operator Commands"
    +# MANTA-ADM 1 "2017" Manta "Manta Operator Commands"

     ## NAME

    @@ -6,6 +6,8 @@ manta-adm - administer a Manta deployment

     ## SYNOPSIS

    +`manta-adm alarm SUBCOMMAND... [OPTIONS...]`
    +
     `manta-adm cn [-l LOG_FILE] [-H] [-o FIELD...] [-n] [-s] CN_FILTER`

     `manta-adm genconfig "lab" | "coal"`
    @@ -30,6 +32,9 @@ deployment.  This command only operates on zones within the same datacenter.
     The command may need to be repeated in other datacenters in order to execute it
     across an entire Manta deployment.

    +`manta-adm alarm`
    +  List and configure amon-based alarms for Manta.
    +
     `manta-adm cn`
       Show information about Manta servers in this DC.

    @@ -125,6 +130,14 @@ Many commands also accept:
       Emit verbose log to LOGFILE.  The special string "stdout" causes output to be
       emitted to the program's stdout.

    +Commands that make changes support:
    +
    +`-n, --dryrun`
    +  Print what changes would be made without actually making them.
    +
    +`-y, --confirm`
    +  Bypass all confirmation prompts.
    +
     **Important note for programmatic users:** Except as noted below, the output
     format for this command is subject to change at any time. The only subcommands
     whose output is considered committed are:
    @@ -133,13 +146,176 @@ whose output is considered committed are:
     * `manta-adm show`, only when used with either the "-o" or "-j" option
     * `manta-adm zk list`, only when used with the "-o" option

    -The output for any other commands may change at any time. Documented
    +The output for any other commands may change at any time.  The `manta-adm alarm`
    +subcommand is still considered an experimental interface.  All other documented
     subcommands, options, and arguments are committed, and you can use the exit
    -status of the program to determine success of failure.
    +status of the program to determine success or failure.


     ## SUBCOMMANDS

    +### "alarm" subcommand
    +
    +`manta-adm alarm close ALARM_ID...`
    +
    +`manta-adm alarm config probegroups list [-H] [-o FIELD...]`
    +
    +`manta-adm alarm config show`
    +
    +`manta-adm alarm config update [-n] [-y] [--unconfigure]`
    +
    +`manta-adm alarm config verify [--unconfigure]`
    +
    +`manta-adm alarm details ALARM_ID...`
    +
    +`manta-adm alarm faults ALARM_ID...`
    +
    +`manta-adm alarm list [-H] [-o FIELD...]`
    +
    +`manta-adm alarm metadata events`
    +
    +`manta-adm alarm metadata ka [EVENT_NAME...]`
    +
    +`manta-adm alarm notify on|off ALARM_ID...`
    +
    +`manta-adm alarm show`
    +
    +The `manta-adm alarm` subcommand provides several tools that allow operators to:
    +
    +* view and configure amon probes and probe groups (`config` subcommand)
    +* view open alarms (`show`, `list`, `details`, and `faults` subcommands)
    +* configure notifications for open alarms (`notify` subcommand)
    +* view local metadata about alarms and probes (`metadata` subcommand)
    +
    +The primary commands for working with alarms are:
    +
    +* `manta-adm alarm config update`: typically used during initial deployment and
    +  after other deployment operations to ensure that the right set of probes and
    +  probe groups are configured for the deployed components
    +* `manta-adm alarm show`: summarize open alarms
    +* `manta-adm alarm details ALARM_ID...`: report detailed information (including
    +  suggested actions) for the specified alarms
    +* `manta-adm alarm close ALARM_ID...`: close open alarms, indicating that they
    +  no longer represent issues
    +
    +For background about Amon itself, probes, probegroups, and alarms, see the
    +Triton Amon reference documentation.
    +
    +As with other subcommands, this command only operates on the current Triton
    +datacenter.  In multi-datacenter deployments, alarms are managed separately in
    +each datacenter.
    +
    +Some of the following subcommands can operate on many alarms.  These subcommands
    +exit failure if they fail for any of the specified alarms, but the operation may
    +have completed successfully for other alarms.  For example, closing 3 alarms is
    +not atomic.  If the operation fails, then 1, 2, or 3 alarms may still be open.
    +
    +`manta-adm alarm close ALARM_ID...`
    +
    +Close the specified alarms.  These alarms will no longer show up in the
    +`manta-adm alarm list` or `manta-adm alarm show` output.  Amon purges closed
    +alarms completely after some period of time.
    +
    +If the underlying issue that caused an alarm is not actually resolved, then a
    +new alarm may be opened for the same issue.  In some cases, that can happen
    +almost immediately.  In other cases, it may take many hours for the problem to
    +resurface.  In the case of transient issues, a new alarm may not open again
    +until the issue occurs again, which could be days, weeks, or months later.  That
    +does not mean the underlying issue was actually resolved.
    +
    +`manta-adm alarm config probegroups list [-H] [-o FIELD...]`
    +
    +List configured probe groups in tabular form.  This is primarily useful in
    +debugging unexpected behavior from the alarms themselves.  The `manta-adm alarm
    +config show` command provides a more useful summary of the probe groups that are
    +configured.
    +
    +`manta-adm alarm config show`
    +
    +Shows summary information about the probes and probe groups that are configured.
    +This is not generally necessary but it can be useful to verify that probes are
    +configured as expected.
    +
    +`manta-adm alarm config update [-n] [-y] [--unconfigure]`
    +
    +Examines the Manta components that are deployed and the alarm configuration
    +(specifically, the probes and probe groups deployed to monitor those components)
    +and compares them with the expected configuration.  If these do not match,
    +prints out a summary of proposed changes to the configuration and optionally
    +applies those changes.
    +
    +If `--unconfigure` is specified, then the tool removes all probes and probe
    +groups.
    +
    +This is the primary tool for updating the set of deployed probes and probe
    +groups.  Operators would typically use this command:
    +
    +- during initial deployment to deploy probes and probe groups
    +- after deploying (or undeploying) any Manta components to deploy (or remove)
    +  probes related to the affected components
    +- after updating the `manta-adm` tool itself, which bundles the probe
    +  definitions, to deploy any new or updated probes
    +- at any time to verify that the configuration matches what's expected
    +
    +This operation is idempotent.
    +
    +This command supports the `-n/--dryrun` and `-y/--confirm` options described
    +above.
    +
    +`manta-adm alarm config verify [--unconfigure]`
    +
    +Behaves exactly like `manta-adm alarm config update --dryrun`.
    +
    +`manta-adm alarm details ALARM_ID...`
    +
    +Prints detailed information about any number of alarms.  The detailed
    +information includes the time the alarm was opened, the last time an event was
    +associated with this alarm, the total number of events associated with the
    +alarm, the affected components, and information about the severity, automated
    +response, and suggested actions for this issue.
    +
    +`manta-adm alarm faults ALARM_ID...`
    +
    +Prints detailed information about the events (faults) associated with any number
    +of alarms.  The specific information provided depends on the alarm.  If the
    +alarm related to a failed health check command, then the exit status,
    +terminating signal, stdout, and stderr of the command are provided.  If the
    +alarm relates to an error log entry, the contents of the log entry are provided.
    +There can be many faults associated with a single alarm, though not all of them
    +are reported by this command.
    +
    +`manta-adm alarm list [-H] [-o FIELD...]`
    +
    +Lists open alarms in tabular form.  See also the `manta-adm alarm show` command.
    +
    +`manta-adm alarm metadata events`
    +
    +List the names for all of the events known to this version of `manta-adm`.  Each
    +event corresponds to a distinct kind of problem.  For details about each one,
    +see `manta-adm alarm metadata ka`.  The list of events comes from metadata
    +bundled with the `manta-adm` tool.
    +
    +`manta-adm alarm metadata ka [EVENT_NAME...]`
    +
    +Print out knowledge articles about each of the specified events.  This
    +information comes from metadata bundled with the `manta-adm` tool.  If no events
    +are specified, prints out knowledge articles about all events.
    +
    +Knowledge articles include information about the severity of the problem, the
    +impact, the automated response, and the suggested action.
    +
    +`manta-adm alarm notify on|off ALARM_ID...`
    +
    +Enable or disable notifications for the specified alarms.  Notifications are
    +generally configured through Amon, which supports both email and XMPP
    +notification for new alarms and new events on existing, open alarms.  This
    +command controls whether notifications are enabled for the specified alarms.
    +
    +`manta-adm alarm show`
    +
    +Summarize open alarms.  For each alarm, use the `manta-adm alarm details`
    +subcommand to view more information about it.
    +

     ### "cn" subcommand

    @@ -479,15 +655,8 @@ See above for information about the `-l`, `-H`, and `-o` options for
     ordinal number of each server), "datacenter", "zoneabbr", "zonename", "ip", and
     "port".

    -The `manta-adm zk fixup` command supports options:
    -
    -`-n, --dryrun`
    -  Print what changes would be made without actually making them.
    -
    -`-y, --confirm`
    -  Bypass all confirmation prompts.
    -
    -It also supports the `-l/--log_file` option described above.
    +The `manta-adm zk fixup` command supports the `-l/--log_file`, `-n/--dryrun`,
    +and `-y/--confirm` options described above.


     ## EXIT STATUS
    @@ -504,7 +673,7 @@ It also supports the `-l/--log_file` option described above.

     ## COPYRIGHT

    -Copyright (c) 2016 Joyent Inc.
    +Copyright (c) 2017 Joyent Inc.

     ## SEE ALSO


## Open questions

It would be good if these knowledge articles were actually part of the FMA event
registry described in RFD 6.  It's not yet clear how best to do that.  However,
it should be possible to define these in a structured form in a repository that
could later be transformed into any other event registry format.


## Repositories affected

The existing repositories that would be affected by this are:

- `sdc-manta`: manta deployment tooling, which delivers `mantamon`
- `mantamon`: contains the probe templates and tooling used to manage Manta
  alarms today
- `manta`: contains the Manta Operator Guide, whose documentation will be
  updated to reflect the CLI changes

As mentioned above, we may end up wanting to separate the tools from the
configuration, and we'll be adding documentation.  The specific new
repositories for this are still TBD.


## Upgrade impact

When updating across this change, old probes continue to work, and the new tools
for viewing alarms work fine with existing alarms, probes, and probe groups.
The tools will not be able to match older alarms with the new knowledge article
content.

The new tools include `manta-adm alarm config update`, which will remove all of
the old probes and probe groups and replace them with new ones that will be
linked to the local knowledge article content.  This command does not touch
operator-created probes or probe groups (or anything else that it does not
recognize).

The expected workflow will be to update the tooling (by updating the "manta"
zone) and run `manta-adm alarm config update`.  It's likely an operator will not
realize they need to do this until some time later when they try to update probe
configuration, but they can just update the probes at that point.  The old
probes will continue to function in the meantime.

If the operator later chooses to roll back, they will need to roll back the
"manta" zone.  They will likely need to remove all of the new probes and probe
groups and replace them with the old ones in order to use `mantamon` to view
open alarms.  The "mantamon drop" command works to remove all of the new probes
and probe groups, subject to all of its known issues.


## Security implications and interfaces changed

There are no end-user security implications because these are all private
interfaces.

The only interfaces being created are:

- a new format for configuring probes
- a new format for documenting probes

These will likely only be processed by tools in the same repository as the data,
though it would still be worthwhile to include version information so that we
can separate the tools for use by other components if desired.

No private information being provided to a consumer that couldn't already access
it.


## See also

* [RFD 6](https://github.com/joyent/rfd/tree/master/rfd/0006) Improving Triton
  and Manta RAS Infrastructure
* [Amon](https://github.com/joyent/sdc-amon/blob/master/docs/index.md)
* [mantamon](https://github.com/joyent/mantamon)
