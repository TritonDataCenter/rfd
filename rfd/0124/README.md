---
authors: Jordan Hendricks <jhendricks@joyent.com>, David Pacheco <dap@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q="RFD+124"
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent Inc.
-->

# RFD 124 Manta Incident Response Guide

On occasion Joyent engineers are asked to assist in debugging and resolving
production incidents.  Incidents can include a variety of problems with
production systems, including user-facing errors, high request latency, and
unavailability of various components of the system.  Typically engineering is
only recruited to help after the symptoms of the incident have reached a certain
threshold of severity: [RFD
101](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0101/README.md) discusses
models for escalating incident response into the engineering team.

Effectively assisting with debugging an ongoing incident is a skill orthogonal
to many other skills an engineer must develop. Further, opportunities to improve
one's ability to help in incident response are rare outside of participating in
real incidents.  For engineers early in their careers, this means they may have
little to no incident response prior to joining Joyent.  For engineers who are
further in their careers but new to Joyent, there are be other challenges: a
different set of tools, system topologies, set of documentation, and social
norms surrounding incident response.  To help Manta engineers grow more
comfortable participating in real incidents, [RFD
111](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0111/README.md) proposed
simulating incidents in a controlled non-production environment, where engineers
wishing to practice incident response could develop their incident response
skills in a low-risk environment.

This RFD proposes sets of concrete steps for responding to an
incident in a production Manta deployment.  For the most part, this generally
fleshes out what much of the team is already doing.  This RFD proposes one
change from the current process, which is the introduction of the role of
**investigation coordinator.**  Finally, the RFD describes some basic,
guidelines for incident response.  This is intended as an accompanying document
for RFD 111 that can be used for training engineers in incident response.
Eventually, it may also be a useful addition to the Joyent engineering guide
([RFD 104](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0104/README.md)) to
codify engineering's best practices for incident response.

The changes proposed here are aimed primarily at how the engineering team
responds to incidents; however, we think these ideas are generally applicable
and encourage other teams to join the discussion and adopt these ideas as well.


## New role: Investigation Coordinator

Like many organizations, Joyent uses the role of Incident Manager (sometimes
called Incident Commander) to coordinate various activities during an incident.
This typically includes making sure that Customer Support are apprised of status
so that it can be communicated to customers; that company management are kept
aware of the status of the investigation; and that the appropriate technical
teams are engaged to understand and repair the problem.  The Incident Manager's
scope is broad, and not necessarily mostly technical.

Within engineering, we've observed that in some incidents, it's not always clear
what's being investigated.  When certain avenues are being pursued, it's not
always clear why.  When others are being ignored, that's not always clear why.
When people join incidents in progress and they can't tell what's going on,
they're less effective at being able to help.  It can also happen that people
actively investigating the problem get stuck answering increasingly complex
questions that are decreasingly related to the original problem.

To help address this, we propose creating a role called **Investigation
Coordinator.**  This person's job would essentially be to keep track of the
various threads of investigation and report it periodically in chat.  For
example, they might report:

> We're still digging into excessive latency reported by clients.  We've
> confirmed this latency from both Muskie logs and monitoring dashboards, and we
> believe this is a problem in the metadata tier.  Josh has confirmed that all
> PostgreSQL databases are healthy and is now looking for evidence of latency
> elsewhere in the metadata tier.  Jordan is looking at which types of requests
> are affected.  Richard is looking into whether the high level of I/O
> operations on shard 5's Moray may be related.  There's some question about
> whether the lag on shard 27 correlates with the problem.

This report includes:

- the initial symptoms reported
- confirmation that we've observed the symptoms directly
- a summary of the data we've collected so far
- a summary of the questions we're currently seeking to answer, who's working on
  that, and what's potentially interesting but not being investigated

We propose that the Investigation Coordinator report this every half hour while
the incident is ongoing.  The intent is for this to be pretty lightweight -- a
minimal process for periodically summarizing state.  The two main goals are to
give new responders a summary of where we are at this point in the incident and
to give the whole investigation team a chance to re-evaluate what they're doing
in the context of the incident.  **The IC should be empowered to step away from
direct investigation as long as needed to keep a handle on the overall direction
and what people are working on.**

**Picking an Investigation Coordinator.**  It is important that the IC be
technical enough to understand what people are working on during the
investigation without a lot of additional explanation, but it is not necessary
that the IC be among the most experienced or senior members of the team.  In
fact, taking on the IC role is an excellent learning opportunity for more junior
members of the team: Summarizing others' work during an investigation can
often be educational on its own, both in increasing understanding of the Manta
stack and learning techniques for investigating incidents.

An investigation coordinator should be selected as soon as engineering is
engaged in incident response (or sooner, if other groups decide to adopt the
role as well).  If the role is handed off during the incident, that handoff
should be made clear in the chat channel.


## Responding to an incident

Having described this new role, the rest of this RFD will summarize general
incident response procedures.


### Initial steps

When the team is first engaged in an incident, initial steps should be:

1. **Characterize the symptoms.**   What exactly are clients seeing?  Are they
   seeing explicit errors?  Are they timing out?  Is throughput degraded?  Is
   latency degraded?  
2. **Observe the symptoms directly.**  Whatever end users are reporting, be sure
   that you can see corresponding evidence, whether in the monitoring system, or
   server-side logs, or potentially (but not necessarily) by reproducing the
   problem yourself.  Ask the incident reporter for specific examples of the
   reported problem.  Often, this means asking support for a specific request ID
   representative of the problems observed.

You need a concrete description of the symptoms in order to know when the
incident is over.  Also, during an incident, there are often other errors or
problems in the stack that are apparent to investigators, but may or may not be
related to what the customer is experiencing, so it's important to focus on the
urgent problem.  Confusion about the problem statement also makes it hard for
others to participate in the investigation.


### Joining an ongoing incident

When you're paged for an incident (and you're able to respond):

1. Acknowledge the incident in PagerDuty. (XXX should that be "resolve"?)
2. Join the appropriate chat channel ("incidents-jpc" or "incidents-spc").
3. Determine whether there's already an _engineering investigation coordinator_
   already.  If not, work (quickly) with other investigators to choose one.  (If
   you are the first person to respond to an incident, proceed with the intial
   steps documented above until more people respond.)
4. Proceed to help understand and mitigate the problem.


### Understanding and mitigating the problem

Most of the time spent during an incident involves understanding the problem and
mitigating it.  There are no silver bullets for this.  We recommend that the
team put together a Manta Debugging Guide, which should target incident response
as a primary use-case.  In the meantime, we will provide some very general
guidance below.

Most importantly, **communicate what you're doing in the chat channel.**  Even
when your digging into something speculatively or your data is incomplete, it's
very helpful for a number of reasons to communicate what you've got.  More on
this below.


### Wrapping up the incident

**Confirm that the incident is over.**  Assuming the initial symptoms were
characterized precisely (e.g., "500-level errors reported from the front door"),
it should be reasonably clear when the incident is over.  After corrective
action has been taken, you can observe whether the symptoms have gone away.  You
may decide to monitor the original symptoms for a while to confirm that the fix
wasn't temporary.  If a customer reported the problem, and support has an open
channel to them, check with them that the problem seems to be resolved.

**Everyone: save the data you've collected.**  While still wrapping up the
incident, it's important to save any terminal output or the list of core files
or other output files that were created.

**The IC should ensure someone is nominated to provide a brief, immediate update
on the INC or SCI ticket** that includes a summary of the symptoms, the believed
causes, the mitigating actions, and the reason we believe the incident is
resolved.  (The intended audience might be a separate team that gets paged in 3
hours for what might seem like the same problem.)  This sounds like a lot, but
it can be very short.  For example: "The customer reported a 20% throughput
degradation.  We tracked this to a handful of electric-moray processes, and we
believe excessive CPU utilization resulted in high latency outliers that caused
the overall reduction in throughput.  We restarted these instances and confirmed
that throughput has been restored to the pre-incident level."

**Nominate individuals to file tickets for any new issues found and write up a
detailed summary of the incident.**  This should include as much raw data as
possible.  If issues associated with existing tickets are found, those tickets
should also be updated to link to the INC or SCI ticket, as well as any relevant
data from the investigation.


## General guidance for investigation and mitigation

It's helpful to **characterize the problem.**  This is different than
characterizing the symptoms, described above.  Here, we try to answer questions
like: does the problem affect all requests?  Only some requests (e.g., just
reads, or only requests from certain client software)?  Does the problem seem to
result from the metadata tier?  The storage tier?  Something else?  If the
problem affects the metadata tier, are all shards affected, or just some?

In general, **follow the data.**  From the initial observations, you generally
have either error messages or excessive latency.  For errors, seek to understand
what the message indicates.  They may be self-explanatory, they may be correct
but obtuse, or they may be totally wrong!  If the message is not
self-explanatory, one often needs to check source code to understand the meaning
of the message, but this is important to do, since the system is trying to tell
us what's wrong (even if indirectly).  For problems of excessive latency in the
data path, we have timers in webapi logs that can help track down the source of
latency.  We also have metrics in monitoring dashboards that show latency at
various points in the stack (especially in the metadata tier).  These can
quickly focus the search for the problem.

While investigating the incident, **keep the chat channel updated with what
you're doing.**  Even if you feel the data you have is incomplete or
inconclusive, it's helpful for people to know what others are looking at, for
several reasons:

- Others might be able to learn from your tools and techniques.
- Others might be duplicating effort investigating the same problem.
- The data you have, however incomplete, might be useful later -- possibly even
  for a different reason (e.g., it might provide a data point with a timestamp
  that can be used to reconstruct what happened).
- Others might have useful suggestions for answering the question you're trying
  to answer.
- Others might be able to explain data points that seem confusing to you.
- The incident coordinator may know of questions that should be investigated,
  but they can't tell whether you're busy investigating something or idle
  looking for suggestions about what to do.

Get in the habit of whenever embarking on a debugging task, announce in chat
what you are about to do.  Where possible, be precise with what symptoms you are
going to investigate, and what steps you will take to perform the investigation.

**When you report any finding, include the raw data when possible** -- whether
that's a screenshot from a monitoring tool, DTrace output, or output from some
other tool.  Use gists if the data doesn't fit in chat.

Relatedly, **when reporting data, include a sentence or two of context**.
Context can include what the output means directly, what it might imply, why it
might be relevant, and what follow-up questions it generates.  The mental cost
of understanding unfamiliar commands and their output can be high, so readers
may take time away from debugging tasks they are working on to understand, or
worse, ignore your message.  Taking a moment to explain a bit about the output
you have posted represents reduces the mental cost of other participants in the
incident as well as ensuring your message is read by others.

**Avoid taking action until there is good reason to believe the action will
help.**  If we suspect that restarting a service will help, is there any data
that can be collected to prove this first?  (For example, if you suspect that a
service has become disconnected from a dependency and restarting will cause it
to reconnect, at least check first -- say, with `pfiles` or `netstat` -- that
the service is, in fact, disconnected.)  The reason we push for collecting data
first is that if taking action doesn't fix the problem, then we're no closer to
understanding how to fix the real problem, and oftentimes having taken action
makes it harder to root cause the real problem.

To pick on a simple but realistic example, if we start restarting services that
seem to be producing errors, we may find that:

- the problem is not fixed,
- a number of additional requests failed because of the restart (that otherwise
  would have succeeded),
- the resulting system behavior (e.g., rediscovery of service instances and
  reconnection) makes things worse, and
- the fact that we restarted services makes it harder to reason about the
  system's current behavior.  This makes it harder to root-cause the initial
  failure, which makes it more likely that it will happen again, since we won't
  be able to fix what we haven't root-caused.

That said, some situations call for taking action before a problem is completely
understood.  In this case, **consider what information can be collected before
taking action that will allow a more complete root cause analysis later.** For
example, a latency issue may be tracked down to a specific process that's doing
a lot of garbage collection and is using much more memory than other instances.
In this case, it may be warranted to try restarting the service, even though we
haven't fully root-caused the reason for the excessive GC.  But before we do
this, we want to make sure that we preserve both a core file (the
easily-recorded static state) and some information about the dynamic state
(e.g., some `prstat` samples to characterize on-CPU activity, as well as
`nhttpsnoop -g` output to show what percentage of time is being spent in garbage
collection).

**A fundamental challenge of incident response is balancing the desire to fully
understand a problem with restoring service as quickly as possible.**  We seek
to build mechanisms to eliminate this tradeoff -- e.g., core file analysis,
which lets us save a great deal of state and still restore service; or removing
individual instances from service discovery so that we can debug them in
isolation without affecting end users.  **Deferring understanding in the name of
service restoration is often a mistake because spending a few minutes
understanding a problem the first time it happens may significantly reduce the
number of times it happens and thus improve overall availability.**  However, we
have to use our judgment in each case.
