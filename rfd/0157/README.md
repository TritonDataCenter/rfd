---
authors: David Pacheco <dap@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+157%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent, Inc.
-->

# RFD 157 Notices to Operators

This RFD proposes a process for documenting Notices to Operators<sup>1</sup>
("NTOs").  NTOs are intended to document anything that an operator of Triton or
Manta would want to know about a particular deployment, including:

- instances where the "config-agent" service has been disabled in order to
  modify the default configuration
- instances where the "registrar" service has been disabled to remove it from
  service
- Manatee shards that have been frozen for some reason or another to prevent
  automatic failover (e.g., due to a bug)
- Manta storage nodes where "minnow" has been disabled to remove the node from
  service for writes
- kernel tunables that have been applied to some servers
- hot-patches, which are important to know about when upgrading or scaling out
  components
- deployment flag days that have not yet been dealt with (e.g., situations where
  a particular version of service A must be deployed before a particular version
  of service B may be deployed)

More specifically, an NTO should describe a condition:

- that is different from a stock deployment.  (Documentation for stock
  conditions should generally belong in regular Manta documentation.)
- that is temporary.  (A condition may last for weeks, months or years, but if
  it's going to last indefinitely, then it probably ought to be part of the
  product documentation.  It's also not likely worth creating an NTO for a
  condition that's expected to last less than a week.)
- that is likely to affect an operator in some way, especially an operator who
  might be performing maintenance or responding to an incident.

The intent is that NTOs would be reviewed:

- while a Change Management (CM) operation is being reviewed, to see if any NTOs
  affect the correctness or impact of the procedure
- before executing a CM operation, to verify that no relevant NTOs were created
  since the CM was reviewed
- during incident response, before taking corrective action (ideally; in
  practice, this will be a judgment call by the incident responders)
- on some basis (e.g., weekly) to ensure that outdated NTOs are closed.

It's recommended that we call operators' attention to active NTOs by linking to
a list of them in the message-of-the-day on all headnodes.

## Examples

### Example: NTO-123 Manatee shards frozen due to MANATEE-400

_This example NTO describes a serious bug that operators may need to know about
before performing any kind of maintenance.  Incident responders also need to
know about it.  It provides specific actions for the conditions where an
operator needs to know about it._

| | |
| --- | --- |
| Identifier       | NTO-123 |
| Synopsis         | Manatee shards frozen due to MANATEE-400 |
| State            | Active |
| Priority         | Notice |
| Regions affected | All SPC, JPC Manta deployments |
| Related tickets  | MANATEE-400 |
| Contact persons  | Joshua Clulow, Angela Fong, David Pacheco |

MANATEE-400 is a critical issue that causes Manatee to attempt to remove the
local copy of the database under some conditions.  This can happen whenever the
"manatee-sitter" process attempts to stop the database, but fails to do so
because the "pg\_prefaulter" process is still using the database directory.
**While unlikely, if this issue were encountered on all three peers in a Manatee
cluster, major Manta-level data loss may result.**

Since this problem can happen during takeover, in order to avoid this situation,
all Manatee shards in affected regions have been frozen.  The impact is that the
system will not automatically respond to failure of a primary or sync.  A single
failure of these servers may result in a partial Manta outage until an operator
can safely trigger a takeover.

To manually, safely cause a Manatee shard to failover (e.g., if a primary or
sync fails and we want to trigger a takeover), operators should:

- Confirm that the Manatee cluster is frozen with reason "See NTO-123", by
  running `manatee-adm show` in one of the Manatee zones for this shard.  (If
  the reason is different, then you'll need to evaluate whether it's safe to
  unfreeze the cluster.  The reason should link you to another NTO or issue with
  more information.)
- In all surviving Manatee peers for this shard (in all datacenters), disable
  the "pg\_prefaulter" SMF service by running `svcadm disable -s pg_prefaulter`.
- Unfreeze the cluster by running `manatee-adm unfreeze`.  This should trigger a
  takeover.  Wait for that to happen, using `manatee-adm show` periodically to
  monitor it.
- Freeze the cluster again using `manatee-adm freeze --reason='See NTO-123'`.
- In all the peers in which you disabled the "pg\_prefaulter" service, re-enable
  it with `svcadm enable pg_prefaulter`.
- Verify that the overall system has recovered.

If for some reason we find a shard on which we've hit MANATEE-400 (i.e., an `rm
-rf` operation is attempting to remove the database), **disable the
manatee-sitter process immediately using `svcadm disable -s manatee-sitter` and
escalate to engineering.**  You should probably freeze the shard to avoid
another takeover triggering MANATEE-400 on another peer.  Check other peers in
the shard to make sure that they haven't also hit MANATEE-400.  (You may need to
re-check periodically, in the event that the shard initiates a takeover and hits
MANATEE-400 again.)

**Conditions for closing NTO:** This NTO can be removed for any region once all
Manatee shards in that region have been upgraded to an image containing the fix
for MANATEE-400.  (If these changes are rolled back, the NTO should be
re-added.)


### Example: NTO-124 Storage node disabled for writes

_This example NTO describes a storage node that's been removed from service for
writes.  Operators or incident responders may need to know about this.  They
might think the storage node is erroneously out of service and re-enable it,
causing whatever problem we were worried about when we removed the node from
service in the first place.  (Alternatively, people may be so worried about that
that we avoid bringing it into service, even though the underlying issue has
been resolved.)_

| | |
| --- | --- |
| Identifier       | NTO-124 |
| Synopsis         | Storage nodes disabled for writes |
| State            | Active |
| Priority         | Notice |
| Regions affected | SPC EU |
| Related tickets  | DCOPS-123 |
| Contact persons  | Brian Bennett |

Manta storage server MS123456 (zone fa8cc746-d271-11e8-abdf-c7e6a72b3a3d) has
been removed from service for writes because it has had multiple disk failures
and is resilvering.  This has very little impact on overall system availability
and performance.

**Conditions for closing NTO:** When resilvering finishes, the system should be
brought back into service for writes and the NTO should be closed.


### Example: NTO-125 flag day between electric-moray, webapi, and jobsupervisor

_This example NTO describes constraints on how the system can be updated, based
on incompatible changes made to various components.  These should be rare, but
have happened.  The example below uses made-up image names, but these would be
replaced by real uuids in a real NTO._

| | |
| --- | --- |
| Identifier       | NTO-125 |
| Synopsis         | Flag days between electric-moray, webapi, and jobsupervisor |
| State            | Active |
| Priority         | Notice |
| Regions affected | All (particularly SPC) |
| Related tickets  | MANTA-3877, MORAY-490, MANTA-1387 |
| Contact persons  | David Pacheco, Cody Mello, Angela Fong |

A series of changes have been made to the "webapi", "jobsupervisor", and
"electric-moray" images that must be deployed in a particular sequence to avoid
a major service disruption.  Such disruptions were seen during SCI-552 and
SCI-600.  There are two different problems described here.

As a result of MANTA-1387, **webapi instances currently running versions prior
to M1 should be updated to M1 before being updated to any later image.**  The
reason is that any webapi instance prior to M1 _will not start up_ if any webapi
instance has ever been updated to a newer version than that.  The easiest way to
avoid this is to upgrade all instances to M1 before upgrading any of them to a
newer image.  (Note: this is unlikely to affect deployments that always upgrade
all instances at the same time, since you _can_ upgrade all instances from a
version before M1 to a version after M1.  However, you'd be at serious risk
because if you decide to rollback, or if the upgrade needs to be paused or
aborted, then you won't be able to start any other webapi instances.)  If this
constraint is accidentally violated and webapi instances are failing to start,
escalate to engineering.  (There is no written process for rolling back the
change that triggers this issue, but it can be accomplished by manually updating
the "manta" bucket version in affected shards.)

As a result of MANTA-3877, **all webapi images between M2 and M3 should never be
deployed.  All jobsupervisor images between J1 and J2 should never be
deployed.**

As a result of MORAY-490 and MANTA-3877, **all electric-moray instances should
be updated to image E1 or later before _any_ webapi instances are updated to
image M3 (or later) and before _any_ jobsupervisor instances are updated to
image J2 (or later).**

If either of these two constraints is violated, and any shard is currently
running a PostgreSQL wraparound autovacuum, then it's likely that all traffic to
that shard will hang, eventually resulting in a total hang of most Manta
requests.  The condition can be unwound using the steps described in SCI-600.

**Conditions for closing NTO:** The NTO can be removed from each region when all
electric-moray instances are at version E1 or later, all webapi instances are at
version M3 or later, and all jobsupervisor instances are at version J2 or later.
(If these changes are rolled back, the NTO should be re-added.)


## Format

We'll start by putting NTOs on the internal Joyent wiki.  This is a lightweight
way to experiment with the process.  (If this proves useful, we may decide it's
worth storing these in a proper database so we can build better tooling around
filtering or reporting on NTOs.)

We generally want to avoid putting too much structure on NTOs, but we suggest a
number of fields to start with:

| | |
| --- | --- |
| Unique identifier | `NTO-001` or the like, intended to allow people and tooling to refer to current and past NTOs unambiguously. |
| Synopsis | A short description of the notice (ideally 72 characters or fewer).  |
| State | One of `Draft`, `Active`, or `Closed`. |
| Priority | `Critical` or `Notice`.  (`Critical` NTOs respresent major risks to the system's availability or durability.  This is intended to be used rarely, but might include a storage system that has suffered the maximum allowable number of drive failures before data is lost.) |
| Region / deployment | Identifies which Triton or Manta regions this NTO applies to.  For example, an NTO about frozen shards might only apply to one region.  An NTO about a flag day might initially apply to all regions, but each region would be removed as it crosses the flag day. |
| Description | A free-form description of what the operator needs to know.  See below. |
| Conditions for closing the NTO | Describes the conditions for transitioning the NTO to "Closed" so that people (other than the author) can determine when it's no longer needed.  (Many NTOs may initially apply to all regions, and this section may just describe when it can be removed from that region.  When it applies to no region, the NTO can be closed.) |
| Related tickets |  If there is a ticket describing the underlying problem, that should be called out in the NTO.  This is important for making sure that we close NTOs that no longer apply because the underlying tickets have been resolved (and the fixes deployed).
| Contact persons | If there are questions about the NTO, these people should be contacted.  This is _not intended for use during incident response_ but rather for questions that might come up during CM review. |

The description should be written clearly, with as much context as an operator
might need (who may not be familiar with deep implementation details of the
system).  When possible, make reference to existing tickets or documentation.
From the description, an experienced operator who's not familiar with this
problem should generally be able to determine with confidence:

- any impact to the system's availability (e.g., one or more storage nodes are
  offline for an extended period).
- any risk of impact to the system's availability (e.g., reduced redundancy of
  some metadata shards).
- whether this NTO affects an operation that they're doing.

## Workflow

**Creating an NTO.**  You create an NTO by just creating a new wiki page for your NTO under the top-level NTO page.  You probably want to start by copying the contents of an existing NTO and replacing the contents in the table.  When ready, **make sure mark your NTO having state `Active` and link your NTO from the top-level NTO page**.

**Reviewing NTOs as part of the CM process.**  It's recommended that we review open NTOs when reiewing CMs and before executing each CM.  The expectation is that NTOs will change relatively rarely, so this won't take that long most of the time.

**Regular review of NTOs.**  We should probably designate a role to periodically review open NTOs to make sure we close those that are no longer active.  As part of this review, we should visit each NTO, review the conditions for closing, check whether the underlying tickets have been resoled and deployed, and decide whether each NTO should remain open.  If there are questions, we should contact the "Contact persons".

**Closing an NTO.**  An NTO is closed by simply updating its state to `Closed` and moving it from the `Active` table to the `Closed table.`  (Do not remove it from the page, as these can be useful for historical reference!)

## Open questions and future work

Open questions:

- Where exactly on the wiki will this go?
- Should we create a mail alias for NTOs and have each new one be mailed out?

If this process works well, we may decide to automate more of it (e.g., create
an actual database, possibly with an API; integrate with JIRA; provide
command-line tools; add specific NTOs to MOTD).  However, we want to start with
the minimum helpful process and see how that goes.

<hr />

Footnotes:

<sup>1</sup> The Notice to Operators idea is very loosely based on the FAA's
[Notice to Airmen (NOTAM)](https://en.wikipedia.org/wiki/NOTAM) process, which
alerts pilots to various sorts of items that might affect their flight planning
(and especially flight safety).  Of course, that's a different environment, and
[NOTAMs have many
issues](https://www.flightglobal.com/news/articles/pilot-error-behind-air-canada-a320-near-miss-at-san-452180/),
so we're not trying to replicate them exactly.
