---
authors: Jordan Hendricks <jhendricks@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent Inc.
-->

# RFD 124 Incident Response Guidelines

On occasion Joyent engineers are asked to assist in debugging and resolving
production incidents.  Incidents can include a variety of problems with
production systems, including user-facing errors, high request latency, and
unavailability of various components of the system.  Typically engineering is
only recruited to help after the symptoms of the incident have reached a certain
threshold of severity: [RFD
101](https://github.com/joyent/rfd/blob/master/rfd/0101/README.md) discusses
models for escalating incident response into the engineering team.

Effectively assisting with debugging an ongoing incident is a skill orthogonal
to many other skills an engineer must develop. Further, opportunities to improve
one's ability to help in incident response are rare outside of participating in
real incidents.  For engineers early in their careers, this means they may have
little to no incident response prior to joining Joyent.  For engineers who are
further in their careers but new to Joyent, there are be other challenges: a
different set of tools, system topologies, set of documentation, and social
norms surrounding incident response.  To help Manta engineers grow more
comfortable participating in real incidents,
[RFD 111](https://github.com/joyent/rfd/blob/master/rfd/0111/README.md) proposed
simulating incidents in a controlled non-production environment, where engineers
wishing to practice incident response could develop their incident response
skills in a low-risk environment.

This RFD proposes a set of basic, non-exhaustive set of incident response
guidelines for Joyent engineers.  It is intended as an accompanying document
for RFD 111, that can be used for training engineers in incident response.
Eventually, it may also be a useful addition to the Joyent engineering guide ([RFD 104](https://github.com/joyent/rfd/blob/master/rfd/0104/README.md))
to codify engineering's best practices for incident response.

## Assumptions

## Guidelines

**Guideline**: Ask the incident reporter for specific examples of the reported
problem.  Often, this means asking support for a specific request ID
representative of the problems observed.

**Justification**: It is important to focus on the problems the customer is
reporting.  During an incident, there are often other errors or problems in the
stack that are apparent to engineers, but may or may not be related to what the
customer is experiencing.  Having a concrete example in hand is an excellent
starting point for debugging an incident.

**Examples**: TODO


**Guideline**: Before embarking on a debugging task, announce in chat what you are
about to do.  Where possible, be precise with what symptoms you are going to
investigate, and what steps you wil take to perform the investigation.

**Justification**: This helps all other stakeholders following along what
engineers are working on.  It helps customer-facing participants keep a pulse on
what specific things the team is investigating, and prevents someone else from
starting a task that someone else is already working on.

**Examples**: TODO



**Guideline**: When pasting command output into chat, accompany it with a sentence
or two providing some context to elucidate why you are sharing it in chat.
Relevant information can include: what the command is, why it is relevant to the
incident, what you interpret the output's significance to be, and questions that
it leaves you with.

**Justification**: There may be readers in chat who are not familiar with the
command you posted, what its output means, or why its relevant.  The mental cost
of understanding unfamiliar commands and their output can be high, so readers
may take time away from debugging tasks they are working on to understand, or
worse, ignore your message.  Taking a moment to explain a bit about the output
you have posted represents reduces the mental cost of other participants in the
incident as well as ensuring your message is read by others.

**Examples**: TODO
