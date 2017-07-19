---
authors: Bryan Cantrill <bryan@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q="RFD+101"
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->

# RFD 101 Models for operational escalation into engineering

## Overview

For any system, there will always be problems that lie outside of the system's
operational parameters, in which the system becomes inoperable due to
conditions not forseen by its operators, its implementors and/or its
designers.  In systems designed to be robust, these conditions should be rare,
but as such they take on even greater urgency:  because the system is normally
so reliable, that it has become inoperable requires expertise not usually
required to operate it.  Further, it is imperative that these conditions get
broad attention:  that the system is operating (or, more likely, not
operating) in such an unintended manner means that it is often difficult to
predict the specific expertise that will be required to right it.  During such
an outage, we need the ability to *escalate into engineering*, and we need
this process to be quick in terms of timing and broad in terms of scope.

## Models for escalation

### "On-call rotation" model

The traditional mechanism for resolving this is with the *on-call rotation*
whereby an engineer is required to be available at any given moment to serve
an escalation.  This has the appeal of "guaranteeing" the availability of an
engineer -- and of assuring those who are not on-call that they will not, in
fact, be called due to a production outage.

This model has some obvious appeal (and indeed, it is the most commonly
deployed model), but it suffers from several flaws:

* **It demands availability for a low-likelihood event.**  Those who are
on-call are expected to remain ready for work -- but because this period
stretches for some length of time (e.g., 12, 24, 36, 72 hours or longer),
readiness can represent a significant impediment to the way one lives one's
life:  socializing must be limited, travel must be eliminated, presentations
(or anything else that has an upfront and non-negotiable demand on one's
time) must be canceled, etc.  This can be very stressful -- even if an
engineer is never, in fact, called.

* **It doesn't necessarily solve the problem.**  Because escalation into 
engineering is (tautologically) due to a problem outside of the system's
designed parameters, one cannot know that the engineer who
happens to be on call will be able to root-cause the problem.  Indeed, it
is quite possible (if not likely!) that the engineer on-call will themselves
need to call another engineer (not on-call!) to summon the necessary
domain expertise.  This undermines the entire idea of an on-call rotation.

* **It's not amenable to a growing team.**  When escalations into engineering
are rare (and if they aren't, there are more serious problems!), it becomes
difficult to learn how to become an on-call engineer:  because the
system is so large, its pathologies so varied, and the opportunity to
diagnosis it so unusual, it becomes difficult to train new engineers to
become part of the on-call rotation.  That is, the normal technique of
shadowing an on-call rotation is useless if there are, in fact, no
calls during the rotation.

All of these flaws combine to make the on-call model at best suboptimal,
and much more likely brittle if not entirely ineffective.

### "Code Blue" model

Because escalations into engineering are rare but urgent, we can instead view
them as a sudden but brief change in priorities:  the escalation has -- for the
duration of the outage that induced it -- become the top priority of every
engineer on the team.  We therefore propose a *broadcast alert* model whereby
all engineers are alerted (and expected to respond) simultaneously.  That is,
_every_ engineer on the team is simultaneously paged, expected to acknowledge
the page, and (to the best of their ability and situation) get to a designated
chat location for details and further instructions.

This model finds analogues in many safety-critical domains:  this is a "code
blue" in the context of a hospital, a "mayday" in the context of a vessel in
trouble, and an order for "all hands on deck" in the context of a ship at sea.

The Code Blue model has a number of advantages:

* **It assures fastest time to resolution.**  By getting every engineer
involved, we are assuring that the problem is resolved as fast as it could be:
there is no engineer that is not notified; no resource left unengaged.  And
debugging is one of the few actitivies in software engineering that defies
Brooks' Law: adding more engineers to debug a problem in fact accelerates work.

* **It becomes more resilient as the team grows.**  Absent an on-call rotation,
at any given moment, some number of engineers will be entirely unavailable:
they will be on a plane, or giving a talk, or out of cell phone range.  But it
is also true that some number will be available:  most of the time, most
engineers are in close proximity to their phone.  By relying on a broadcast
(and demanding that all engineers check in), we are greatly increasing the
likelihood that *someone* will be available -- and that that someone will have
the necessary expertise to provide the operations team the assistance to
resolve the service outage.

* **It shares the load evenly.**  It should not be the sole responsibility of
those with expertise in the system to endure its off-hours crises.
Supporting production systems must be a shared burden, and even an
on-call rotation doesn't share that load evenly.

* **It allows engineers to learn the system.**  Watching engineers
debug a problem can be enormously educational with respect to how the system
works -- which pays dividends not just in future outages, but also for
future work on the system.  In a traditional on-call rotation it is difficult

* **It lends urgency to a postmortem.**  When every engineer has become
aware of a problem, there becomes much greater collective urgency to get
a problem entirely understood, documented, and resolved such that the
particular cascading failure that necessitated engineering escalation becomes
(in the limit, anyway) impossible.

## Recommendations

Engineering escalation is a regretable necessity of any software deployed
as a service; the Code Blue model is -- as Churchill famously described
democracy -- probably the worst escalation model except for all of the
others.

