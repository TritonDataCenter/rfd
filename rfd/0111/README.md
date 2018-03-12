---
authors: David Pacheco <dap@joyent.com>
state: publish
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+111%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 111 Manta Incident Response Practice

## Goals

When production incidents arise, operations and engineering must respond
quickly (but effectively) to fully understand the problem and restore service
as quickly as possible.  As a team, our ability to respond reliably to
incidents depends on many (or all) team members being comfortable with the
process.  Effectively working through an incident involves a number of skills:

- familiarity with the components involved, how they work, how they interact
  with each other, and their various quirky behaviors and commonly-encountered
  known issues
- familiarity with the tools, log files, and other data sources that are
  available to help understand the system.  (In our case, this includes
  Manta-specific tools, Triton tools, operating system tools, and tools
  specific to third-party components like ZooKeeper and PostgreSQL.)
- comfort learning more about components and tools on the fly: finding
  documentation and source code, understanding it quickly, and applying that
  knowledge
- comfort running commands, including potentially invasive or destructive
  commands, on production-like systems.  This includes multi-datacenter,
  multi-CN systems, and systems where incorrect action can have serious
  consequences beyond impacting one engineer's development time.  Example tools
  in this category include `sdc-oneachnode` and `manta-oneach`.
- time management, including judgment about the relative severity of a number
  of anomalies
- collaboration with others at various experience levels to parallelize this
  whole activity

To help develop these skills and general experience debugging critical
production issues, this RFD proposes Incident Response Practice sessions.  The
basic idea is to induce scheduled outages in non-critical, production-like
deployments (such as [the engineering staging
environment](https://mo.joyent.com/docs/lab/master/staging.html)) and have people
respond to them the same way that we would respond to a production outage.


## Scope of the simulation

There's an enormous spectrum of how far we could take this simulation.  Here
are two relatively extreme options:

1. **Simpler case:** an outage is induced at a specific, scheduled time.
   Specific team members (who explicitly signed up for this practice session)
   are notified the same way they normally would be (e.g., an alarm message in
   chat).  They debug the incident until service is restored.
2. **More realistic case:** we announce that an outage will be induced during
   business hours during a particular week (time zone TBD).  At that time,
   all of engineering gets a [Code
   Blue](https://github.com/joyent/rfd/blob/master/rfd/0101/README.md) and
   responds to the incident as though it were a normal production incident.
   Support is engaged to manage simulated customer notifications.  After the
   incident is complete, the team writes a postmortem, including a detailed
   timeline of the service impact, the debugging steps, and steps to
   resolution.

Similar to the way we build systems incrementally and enhance them as we
understand the problems better, this RFD proposes starting with something closer
to the simpler case above.  As the team's comfort level grows with the
components, the tools, and the incident response environment, we may consider
adding new dimensions to the practice (e.g., starting the incident at surprising
times or incorporating the process of engaging support for customer
notifications).


## Incident Response Practice sessions

At this point, this is still a straw man for discussion.  See the Rationale
section for reasons for the specific details proposed here.

**Scheduled.** On a regular basis or as requested, specific _practice sessions_
will be scheduled at specific times.  (They will not be surprises.) Although
the start of the incident is scheduled, there may be large variance in the time
required to resolve it.  We should target completion within the business day,
and likely within 1-4 hours.  (If we find an outage takes only a few minutes to
resolve, we could immediately instigate another one if desired.)

**Predefined participants.** Any number of _instigators_ will sign up to induce
the outage and help run the session.  3-6 _incident responders_ will sign up
ahead of time to debug and resolve the incident.

**The process:**

1. The instigators will discuss ahead of time what type of outage to induce and
   how to induce it.  They will test that process as needed.
2. The incident will begin at the scheduled time when the instigators induce the
   outage.
3. Responders will be notified through the usual means of an outage: Amon alarm
   messages in chat and by email.
4. Responders will assess the situation, debug the incident, and resolve the
   problems until service is fully restored.
5. Responders will generate a _detailed_ assessment of the overall impact,
   including the time the incident started, the time it ended, and the impact to
   end users during that window (e.g., what percentage of what types of
   requests).  This may take some time after the incident is resolved -- e.g.,
   if _post hoc_ analysis of core files or logs is needed.
6. Some time later, responders and instigators will follow up on a call to
   discuss the overall incident, lessons learned, and suggestions for both
   incident response and for the practice process.  Responders will write up a
   brief summary.  Anyone may join the call to listen.

**Guidelines for engagement:**

All of these guidelines are designed to make the exercise most useful for
responders.  These are not hard and fast rules, and there aren't penalties.  The
expectation is that following these will help people get the most out of this
experience.

* All communication about the incident itself should happen in a public chat
  channel designated for incident practice (e.g., `~incident-practice`).
  **Responders should only discuss the incident itself with other responders.**
* Instigators _may_ comment in the channel with specific pointers to
  manual pages or tools.  (The purpose of this is to point out _that_ specific
  tools exist that a responder seems to need but might not know about.  Such
  comments should be limited to pointers to the manual page or other docs,
  or the source code, or the files on disk.  If the responder needs more
  information, they'll need to look at the docs or source.)
* If responders feel like they're truly stumped and cannot make forward
  progress, they can ask for more help.  It's recommended that instigators
  provide help in the form of suggested questions (e.g., "what's the database
  query throughput?").
* Anybody who is not participating in the practice as an instigator or a
  responder should avoid communicating with responders, and definitely not about
  the incident itself.  (If you think responders should be told about some tool,
  contact an instigator.)

**Other guidelines**

* There should be 1-3 instigators for each practice. Instigators should
  generally be people very comfortable dealing with production incidents.  They
  should be watching closely to see when help may be needed, but they should
  offer help sparingly.  In particular, they should probably remain quiet as
  long as forward progress is being made, even if it's not in the right
  direction.  Blind alleys are part of debugging and incident response.
* The makeup of the response team can have a significant impact on the
  usefulness of this experience.  We don't want a team where one or two
  experts can quickly solve the problem without anybody else's help, nor do
  we want a team entirely of beginners who don't know where to start.  Ideally,
  there will be a mix of less experienced people and people familiar enough with
  the system and its components to provide general direction for the group.

**Who can be involved:**

* For the time being, this is entirely opt-in.  If this works well, we may
  decide to incorporate it into new-hire onboarding, but that's further down the
  road.
* Any Joyent employee is welcome to participate -- including people
  from engineering, operations, support, product, and solutions.  However, for
  now, we require two things from participants: (1) You must have credentials to
  access the Ops VPN and log into headnodes _before_ you can sign up. (2) You
  must have set up your own Manta deployment already.

## Rationale

**Why are practices scheduled rather than surprising?  Why not incorporate the
process of engaging support for customer notifications?  Why not write a formal
postmortem?**  These would would make the simulation more realistic, but the
primary goal of this phase of incident response practice is to build experience
and comfort with debugging the system -- the components, the process, and the
tools.  Subsequent phases can take into account other challenges like keeping
stakeholders up to date and being interrupted in the first place.

**Why aren't responders allowed to talk to other people during the incident?
Why are instigators limited in what they can say?**  Learning about the system
and its tools (including figuring out how they work) is one of the skills we're
trying to develop.  In a real incident, people won't necessarily have lifelines
whom they can ask arbitrary questions about the system and its tools, so it's
important to develop the skills to find this information.  (At the same time,
people can spend hours trying to collect information that some tool makes
available trivially.  That's why instigators can provide such pointers.)

**Why can't non-participants chime in with useful information?**  Focus during
incident response is challenging enough, and we want to avoid inexperienced
participants thrashing because they're getting lots of suggestions from people
not involved in the practice.  But feel free to contact an instigator, and they
can decide if it's an avenue worth sending people down (and if the responders
are lost enough that it's worth giving them a pointer).

**Should we provide training to participants ahead of time?**  This RFD provides
links to key resources.  Responders are encouraged to familiarize themselves
with these before starting!  Formal training would be great, but that's its own
large project.  People are being thrown into incident response today, and we
hope that having this exercise even without prior training would be a major
help.

**What level of time pressure is part of this exercise?**  Incident response
always involves resolving tension between restoring service quickly and fully
root-causing the problem.  In general, we bias towards understanding (but we use
practices that avoid having to compromise -- that's why core files and being
able to remove instances from service for debugging are so important).  That's
especially true in these practice sessions.  It's more important to learn how to
understand the problem completely and fix it robustly than to restore service
quickly.  However, the practice should not be treated as an unbounded debugging
activity.  It should be all-responders-on-deck while the incident is ongoing,
and time-to-recovery should be minimized as much as possible.

**What about operational prerequisites?**  Debugging in staging leaves out some
of the mechanical prerequisites that are required when people debug production
instances:

- credentials for the Ops VPN
- credentials for the Ops LDAP server used for logging into headnodes
- Duo setup (two-factor-auth)
- hostnames for headnodes

To address this without adding all these mechanisms to the engineering staging
environment, we will require that responders have set all this up in order to
even sign up for a practice session.

## Open questions

Do we want to be able to re-use the same problems for multiple groups?  It seems
like this might be pretty useful, particularly as we onboard new people.  If so,
how do we keep people from finding the resolutions before their turn at
practice?

Are there other Manta deployments in which we could do this?  It needs to be an
environment that we can pretty much wreck for an extended period.  It basically
needs to be a multi-DC deployment.  It might not be a bad idea if it required
the Ops VPN + Duo in order to access it.

## Future extensions

- Surprise times
- Doing it as a Code Blue
- Coordinating with support to notify stakeholders
- More detailed postmortem reports


## Key resources for participants

Documentation:

- [Manta Operator's Guide](https://joyent.github.io/manta/).  There are several
  specific sections around locating components, accessing them, translating
  between various ids, locating objects, and so on.
- [Service discovery documentation (Registrar/Binder)](https://github.com/joyent/registrar/blob/master/README.md)

Tools:

- [manta-adm(1)](https://github.com/joyent/sdc-manta/blob/master/docs/man/man1/manta-adm.md) tool
- [manta-oneach(1)](https://github.com/joyent/sdc-manta/blob/master/docs/man/man1/manta-oneach.md) tool
- [madtom](https://joyent.github.io/manta/#madtom-dashboard-service-health) dashboard
- [marlin-dashboard](https://joyent.github.io/manta/#marlin-dashboard-compute-activity)
- [mlive](https://github.com/joyent/manta-mlive) tool
- [mlocate](https://joyent.github.io/manta/#locating-object-data) tool
- [moray command-line tools](https://github.com/joyent/node-moray/blob/master/docs/man/man1/moray.md)
- [mrjob](https://joyent.github.io/manta/#marlin-tools)
- [pgsqlstat](https://github.com/joyent/pgsqlstat)
- [moraystat.d](https://github.com/joyent/moray/blob/master/bin/moraystat.d)
- [mdb_v8 guide](https://github.com/joyent/mdb_v8/blob/master/docs/usage.md)
- [`bunyan -p` ("runtime log snooping")](https://www.joyent.com/blog/node-js-in-production-runtime-log-snooping)
- OS tools:
  - svcs(1) (including `svcs -L`)
  - proc(1) (the "ptools", especially pgrep, pfiles, pstack)
  - netstat(1M)
  - netstat(1M) with "-s" option
  - [DTrace Guide](http://dtrace.org/guide/)
  - zonememstat(1M)
  - vfsstat(1M)
  - prstat(1M)
  - mpstat(1M)
- TBD: muskie scripts to summarize error rates and latency

## See also

* [Nexus of
  Evil](https://blogs.nasa.gov/waynehalesblog/2010/02/16/post_1266353065166/),
  about NASA's team that helps train mission teams for handling failure
