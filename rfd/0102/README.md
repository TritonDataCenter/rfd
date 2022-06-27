---
authors: Bryan Cantrill <bryan@joyent.com>
state: publish
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+102%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->

# RFD 102 Requests for Enhancement

## Overview

[Requests for Discussion](https://github.com/TritonDataCenter/rfd) have allowed for
technical thinking to be formally written down over a wide range of subjects.
Their broad subject matter is not accidental: RFDs are intentionally informal
in their subject and structure, with the belief that it is better to write
things down than to refuse them in the name of a foolish consistency.  That
said, a subcategory has emerged that merits a distinction: RFDs that don't
really discuss *how something is designed* but rather *what problem should be
solved*.  Rather than describing the concrete plans on how something will be
implemented, such RFDs are often subjective, representing (to a degree) the
priorities of the author(s):  the problem is important enough that it merits
being written down -- but not (yet) at the point where the architecture has
been seriously considered.  Such RFDs are not requests for discussion on
detailed design but rather *requests for enhancement* (RFEs).  However,
because we have lacked a formalized mechanism for RFEs, these RFDs have felt
an implicit obligation to discuss implementation.  This urge is perilous;
these RFDs can become the worst of all worlds in which desired functionality
is framed as loosely conceived implementation rather than a clear problem
statement.

This RFD, then, is for the creation of a formalized RFE:  in the spirit of an
RFD (and mechanically similar, though without any discussion of design or
implementation) but thought of, conceived of, and catalogued separately.  This
dichotomy will make clear(er) that which is being actively contemplated by
those developing the software versus that which that which is being externally
requested by those using the software.

The rest of this document proposes RFEs.

## RFE definition

An RFE is the request for additional functionality to the system, with the
emphasis on requirements rather than design -- it is the "what" than the
"how".  RFEs should almost always result in the addition of user- or
operator-visible abstraction, with the exception being an existing abstraction
that is to be enhanced in some quantifiable way.  A good RFE needs to answer
two questions:  what problem needs to be solved (and why?) and what defines
success?

### "What needs to be solved?"

There is an art to describing the problem that needs to be solved:  too
vague, and one runs the risk of putative solutions that don't actually
solve the problem; too specific and the problem description drifts into
a solution description.  Ideally, the problem description should be
abstract and yet still sufficiently concrete to constrain (but not overly
constrain!) solutions.  For example, an RFE asking for a GPGPU-based
container offering (say) is vague and likely underspecified -- but
one asking for
an offering based on NVIDIA Tesla P100 GPUs may be too confining.
Rather, the RFE may be for GPGPU-based container offering that allows
for CUDA-based workloads that can economically compete with a p2-8xlarge
AWS instance (say). Or perhaps it's even higher level than that:
an offering that allows for optimal execution of specific frameworks
like PyTorch, Theano and TensorFlow.  Or perhaps the RFE phrases the problem
at its most general ("we need GPGPU-based instances") and provides specific
use-case detail to convey an understanding of the solution space.

### "Why?"

Engineers are problem solvers -- and understanding _why_ a problem needs to
be solved it very much helps to understand the implications in terms of
what needs to be solved.
Sometimes the "why" of a problem only helps to motivate its solution (or
the engineer providing it!),
but in some cases the "why" can shape the solution significantly -- or
imply other problems that need to be solved.

### "What defines success?"

It's important to know the least that can be done to be considered
successful -- not because engineers are underachievers, of course, but
rather to allow for an iterative course to be plotted.  This is an exercise
in defining the [minimum viable
product](https://en.wikipedia.org/wiki/Minimum_viable_product):  at what
point is the problem considered to be sufficiently solved to at least allow
further feedback?  Alternatively, it may be that emphasis is not on
"minimum" but "viable":  many pieces of software infrastructure require
significant work to render something that is at all usable, and the emphasis
may be on the high level of functionality required to meet even the
lowest of expectations.

## RFEs in contrast

To better understand an RFE, it can be helpful to contrast it to other
similar (but distinct!) concepts.

### RFEs vs. RFDs

RFEs will tend to be shorter, vaguer, and more speculative than RFDs.
There will be projects that have both an RFE and an RFD:  the RFE
describing what is desired, the RFD describing the mechanism that satisfies
that desire and how it is built.  There will also be projects that have an
RFE but no matching RFD -- namely, those that are not implemented, or for
which the implementation is so straightforward as to not merit a separate
RFD.  Finally, there will be projects that have an RFD but no corresponding
RFE -- especially if they pertain to improvements to the implementation or
architecture of the system that do not extend or modify its abstractions.
Note that this implies an unfair assymetry:  RFDs may freely discuss the
"what", but RFEs should really refrain from specifying the "how".
The implication here is that engineering-originated discussion will often
(though not always) better fit as an RFD than an RFE -- and certainly where
that discussion centers on improving how it works or how it's built rather
than expanding what it does.

### RFEs vs. PRDs

The notion of an RFE goes by many other names, but our nomenclature here is
deliberate -- and in particular, an RFE is not a Product Requirements
Document (PRD).  This is to avoid two common (and related) pathologies of
PRDs:  that they focus too much on the solution rather than the problem and
that they therefore often contain "requirements" that are not, in fact,
requirements.  (In the argot of the PRD, these are considered "table
stakes" -- and it is the tyranny of ten thousand table stakes that brought
the revolution of the "minimum viable product.") An RFE is not specifying a
product; it is specifying a desire for particular functionality that is
couched in sufficient context to assure that the problem is solved.

### RFEs vs. MRDs

Those that routinely use PRDs may also use a Market Requirements Document
(MRD).  An RFE is likely much more technical than an MRD, which typically
will focus on total addressable market (TAM) and its segmentation rather
than what technically is required, though an RFE may have some elements
typically found in an MRD.

### RFEs vs. Epics/Stories

Epics and stories are [agile
concepts](https://www.atlassian.com/agile/delivery-vehicles).  Stories
describe -- in narrative form -- what the software should do from a
user's perspective.  ("As a user, I would like to create a container that
is attached to a GPGPU instance.")  While RFEs may very well look like an
agile story, they are likely to be more technical than what is
traditionally thought of as a story, but the technique of adding a
narrative may well be considered useful to flesh out an RFE.

## Mechanics

RFEs -- like RFDs -- are public.  Like RFDs, they will have their own
public repository and numbering scheme.
