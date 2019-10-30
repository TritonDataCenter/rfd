---
authors: Bryan Cantrill <bryan@joyent.com>
state: publish
discussion: https://github.com/joyent/rfd/issues/114
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 151 Assessing Software Engineering Candidates

How does one assess candidates for software engineering positions?  This is
an age-old question without a formulaic answer: software engineering is
itself too varied to admit a single archetype.

Most obviously, software engineering is intellectually challenging; it
demands minds that not only enjoy the thrill of solving puzzles, but can also
stay afloat in a sea of numbing abstraction.  This raw capacity, however, is
insufficient; there are many more nuanced skills that successful software
engineers must posess.  For example, software engineering is an almost
paradoxical juxtaposition of collaboration and isolation: successful
software engineers are able to work well with (and understand the needs of!)
others, but are also able to focus intensely on their own.  This contrast
extends to the conveyance of ideas, where they must be able to express their
own ides well enough to persuade others, but also be able to understand and
be persuaded by the ideas of others -- and be able to implement all of these
on their own.  They must be able to build castles of imagination, and yet
still understand the constraints of a grimy reality: they must be arrogant
enough to see the world as it isn't, but humble enough to accept the world as
it is.  Each of these is a *balance*, and for each, long-practicing software
engineers will cite colleagues who have been ineffective because they have
erred too greatly on one side or another.

The challenge is therefore to assess prospective software engineers, without
the luxury of firm criteria.  This document is an attempt to pull together
accumulated best practices; while it shouldn't be inferred to be overly
prescriptive, where it is rigid, there is often a painful lesson behind it.

In terms of evaluation mechanism:  using in-person interviewing alone can be
highly unreliable and can select predominantly for surface aspects of a
candidate's personality.  While we advocate (and indeed, insist upon)
interviews, they should come relatively late in the process; as much
assessment as possible should be done by allowing the candidate to show
themselves as software engineers truly work:  on their own, in writing.

## Traits to evaluate

How does one select for something so nuanced as balance, especially when the
road ahead is unknown?  We must look at a wide-variety of traits, presented
here in the order in which they are traditionally assessed:

- Aptitude
- Education
- Motivation
- Values
- Integrity

### Aptitude

As the ordering implies, there is a temptation in traditional software
engineering hiring to focus on aptitude exclusively:  to use an interview
exclusively to assess a candidate's pure technical pulling power.  While
this might seem to be a reasonable course, it in fact leads down the
primrose path to pop quizzes about algorithms seen primarily in interview
questions.  (Red-black trees and circular linked list detection: looking at
you.) These assessments of aptitude are misplaced:  software engineering is
not, in fact, a spelling bee, and one's ability to perform during an
arbitrary oral exam may or may not correlate to one's ability to actually
develop production software.  We believe that aptitude is better assessed
where software engineers are forced to exercise it:  based on the work that
they do on their own.  As such, candidates should be asked to provide three
samples of their works:  a code sample, a writing sample, and an analysis
sample.

#### Code sample

Software engineers are ultimately responsible for the artifacts that they
create, and as such, a code sample can be the truest way to assess a
candidate's ability.

Candidates should be guided to present code that they believe best reflects
them as a software engineer.  If this seems too broad, it can be easily
focused:  what is some code that you're proud of and/or code that took you a
while to get working?  

If candidates do not have any code samples because all of their code is
proprietary, they should write some:  they should pick something that they
have always wanted to write but have been needing an excuse -- and they
should go write it!  On such a project, the guideline to the candidate
should be to spend at least (say) eight hours on it, but no more than
twenty-four -- and over no longer than a two week period.  

If the candidate is to write something *de novo* and/or there is a new or
interesting technology that the organization is using, it may be worth
guiding the candidate to use it (e.g., to write it in a language that the
team has started to use, or using a component that the team is broadly
using).  This constraint should be uplifting to the candidate (e.g., "You
may have wanted to explore this technology; here's your chance!").  At
Joyent in the early days of node.js, this was what we called "the node
test", and it yielded many fun little projects -- and many great engineers.

#### Writing sample

Writing good code and writing good prose seem to be found together in the
most capable software engineers.  That these skills are related is perhaps
unsurprising: both types of writing are difficult; both require one to
create wholly new material from a blank page; both demand the ability to
revise and polish.

To assess a candidate's writing ability, they should be asked to provide a
writing sample.  Ideally, this will be technical writing, e.g.:

- A block comment in source code
- A blog entry or other long-form post on a technical issue
- A technical architectural document, whitepaper or academic paper
- A comment on a mailing list or open source issue or other technical
  comment on social media

If a candidate has all of these, they should be asked to provide one of
each; if a candidate has none of them, they should be asked to provide a
writing sample on something else entirely, e.g. a thesis, dissertation or
other academic paper.

#### Analysis sample

Part of the challenge of software engineering is dealing with software when
it doesn't, in fact, work correctly.  At this moment, a software engineer
must flip their disposition:  instead of an artist creating something new,
they must become a scientist, attempting to reason about a foreign world.
In having candidates only write code, analytical skills are often left
unexplored.  And while this can be explored conversationally (e.g., asking
for "debugging war stories" is a classic -- and often effective -- interview
question), an oral description of recalled analysis doesn't necessarily
allow the true depths of a candidate's analytical ability to be plumbed.
For this, candidates should be asked to provide an *analysis sample*: a
*written* analysis of software behavior from the candidate.  This may be
difficult for many candidates: for many engineers, these analyses may be
most often found in defect reports, which may not be public.  If the
candidate doesn't have such an analysis sample, the scope should be
deliberately broadened to any analytical work they have done on any system
(academic or otherwise).  If this broader scope still doesn't yield an
analysis sample, the candidate should be asked to generate one to the best
of their ability by writing down their analysis of some aspect of system
behavior.  (This can be as simple as asking them to write down the debugging
story that would be their answer to the interview question -- giving the
candidate the time and space to answer the question once, and completely.)

### Education

We are all born uneducated -- and our own development is a result of the
informal education of experience and curiosity, as well as a better
structured and more formal education.  To assess a candidate's education,
both the formal and informal aspects of education should be considered.

#### Formal education

Formal education is easier to assess by its very formality: a candidate's
education is relatively easily evaluated if they had the good fortune of
discovering their interest and aptitude at a young age, had the opportunity
to pursue and complete their formal education in computer science, and had
the further good luck of attending an institution that one knows and has
confidence in.

But one should not be bigoted by familiarity:  there are many terrific
software engineers who attended little-known schools or who took otherwise
unconventional paths.  The completion of a formal education in computer
science is much more important than the institution:  the strongest
candidate from a little-known school is almost assuredly stronger than the
weakest candidate from a well-known school.

In other cases, it's even more nuanced:  there have been many later-in-life
converts to the beauty and joy of software engineering, and such candidates
should emphatically not be excluded merely because they discovered software
later than others.  For those that concentrated in entirely non-technical
disciplines, further probing will likely be required, with greater
emphasis on their technical artifacts.

The most important aspect of one's formal education may not be its substance
so much as its *completion*.  Like software engineering, there are many
aspects of completing a formal education that aren't necessarily fun:
classes that must be taken to meet requirements; professors that must be
endured rather than enjoyed; subject matter that resists quick understanding
or appeal.  In this regard, completion of a formal education represents the
completion of a significant task.  Inversely, the failure to complete one's
formal education may constitute an area of concern.  There are, of course,
plausible life reasons to abandon one's education prematurely (especially in
an era when higher education is so expensive), but there are also many paths
and opportunities to resume and complete it.  The failure to complete formal
education may indicate deeper problems, and should be understood.

#### Informal education

Learning is a life-long endeavor, and much of one's education will be
informal in nature.  Assessing this informal education is less clear,
especially because (by its nature) there is little formally to show for it
-- but candidates should have a track record of being able to learn on their
own, even when this self-education is arduous.  One way to probe this may be
with a simple question:  what is an example of something that you learned
that was a struggle for you?  As with other questions posed here, the
question should have a written answer.

### Motivation

Motivation is often not assessed in the interview process, which is
unfortunate because it dictates so much of what we do and why.  For many
companies, it will be important to find those that are *intrinsically
motivated* -- those who do what they do primarily for the value of doing it. 

Selecting for motivation can be a challenge, and defies formula.  Here,
open source and open development can be a tremendous asset:  it allows
others to see what is being done, and, if they are excited by the work,
to join the effort and to make their motivation clear.

### Values

Values are often not evaluated formally at all in the software engineering
process, but they can be critical to determine the "fit" of a candidate.  To
differentiate values from principles:  values represent *relative
importance* versus the *absolute importance* of principles.  Values are
important in a software engineering context because we so frequently make
tradeoffs in which our values dictate our disposition.  (For example, the
relative importance of speed of development versus rigor; both are clearly
important and positive attributes, but there is often a tradeoff to be had
between them.)  Different engineering organizations may have different
values over different times or for different projects, but it's also true
that individuals tend to develop their own values over their career -- and
it's essential that the values of a candidate do not clash with the values
of the team that they are to join.

But how to assess one's values?  Many will speak to values that they don't
necessarily hold (e.g., rigor), so simply asking someone what's important to
them may or may not yield their true values.  One observation is that one's
values -- and the adherence or divergence from those values -- will often be
reflected in happiness and satisfaction with work.  When work strongly
reflects one's values, one is much more likely to find it satisfying; when
values are compromised (even if for a good reason), work is likely be
unsatisfying.  As such, the specifics of one's values may be ascertained by
asking candidates some probing questions, e.g.:

- What work have you done that you are particularly proud of and why?
- What mistakes have you made that you particularly regret and why?
- When have you been happiest in your professional career and why?
- When have you been unhappiest in your professional career and why?

Our values can also be seen in the way we interact with others.  As such,
here are some questions that may have revealing answers:

- Who is someone who has mentored you, and what did you learn from them?
- Who is someone you have mentored, and what did you learn from them?
- What qualities do you most admire in other software engineers?

**The answers to these questions should be written down** to allow them to
be answered thoughtfully and in advance -- and then to serve as a starting
point for conversation in an interview.

Some questions, however, are more amenable to a live interview.  For
example, it may be worth asking some situational questions like:

- What are some times that you have felt values come into conflict?
  How did you resolve the conflict?

- What are some times when you have diverged from your own values and how
  did you rectify it?  For example, if you value robustness, how do you 
  deal with having introduced a defect that should have been caught?

### Integrity

In an ideal world, integrity would not be something we would need to assess
in a candidate:  we could trust that everyone is honest and trustworthy.
This view, unfortunately, is naïve with respect to how malicious bad
actors can be; for any organization -- but especially for one that is biased
towards trust and transparency -- it is essential that candidates be of high
integrity: an employee who operates outside of the bounds of integrity can
do nearly unbounded damage to an organization that assumes positive intent.

There is no easy or single way to assess integrity for people with whom one
hasn't endured difficult times.  By far the most accurate way of assessing
integrity in a candidate is for them to already be in the circle of one's
trust:  for them to have worked deeply with (and be trusted by) someone that
is themselves deeply trusted.  But even in these cases where the candidate
is trusted, some basic verification is prudent.

#### Criminal background check

The most basic integrity check involves a criminal background check.  While
local law dictates how these checks are used, the check should be performed
for a simple reason:  it verifies that the candidate is who they say they
are.  If someone has made criminal mistakes, these mistakes may or may not
disqualify them (much will depend on the details of the mistakes, and on
local law on how background checks can be used), but if a candidate fails to
be honest or remorseful about those mistakes, it is a clear indicator of
untrustworthiness.

#### Credential check

A hidden criminal background in software engineering candidates is unusual;
much more common is a slight "fudging" of credentials or other elements of
one's past: degrees that were not in fact earned; grades or scores that have
been exaggerated; awards that were not in fact bestowed; gaps in employment
history that are quietly covered up by changing the time that one was at a
previous employer.  These transgressions may seem slight, but they can point
to something quite serious:  a candidate's willingness or desire to mislead
others to advance themselves.  To protect against this, a basic credential
check should be performed.  This can be confined to degrees, honors, and
employment.

#### References

References can be very tricky, especially for someone coming from a
difficult situation (e.g., fleeing poor management).  Ideally, a candidate
is well known by someone inside the company who is trusted -- but even this
poses challenges:  sometimes we don't truly know people until they are in
difficult situations, and someone "known" may not, in fact, be known at all.
Worse, references are most likely to break down when they are most needed:
dishonest, manipulative people are, after all, dishonest and manipulative;
they can easily fool people -- and even references -- into thinking that
they are something that they are not.  So while references can provide value
(and shouldn't be eliminated as a tool), they should also be used carefully
and kept in perspective.

#### Interviews

For individuals outside of that circle of trust, checking integrity is
probably still best done in person.  There are several potential mechanisms
here:

- A very broad interview schedule that includes some people
  clearly subordinate to the candidate.  Some people will treat people
  differently depending on the status that they perceive.

- A very broad interview schedule that includes some people with a talent
  for reading others.  For example, someone who is effective at sales often
  has a knack for picking up on subtle body langauge cues that others will
  miss.

- Interviews that deliberately probe, e.g., asking candidates to
  describe a time that preserving integrity necessitated taking a more
  difficult path.

- Interviews that setup role playing, e.g., asking candidates how they
  would handle a co-worker approaching them privately asking them to
  do something that they perceived as wrong.

## Mechanics of evaluation

Interviews should begin with phone screens to assess the most basic
viability, especially with respect to motivation.  This initial conversation
might include some basic but elementary (and unstructured) homework to gauge
that motivation.  The candidate should be pointed to material about the
company and sources that describe methods of work and specifics about what
that work entails.  The candidate should be encouraged to review some of
this material and send formal written thoughts as a quick test of
motivation.  If one is not motivated enough to learn about a potential
employer, it's hard to see how they will suddenly gain the motivation to see
them through difficult problems.

If and when a candidate is interested in deeper interviews, *everyone*
should be expected to provide the same written material.  

### Candidate-submitted material

The candidate should submit the following:

- Code sample (no more than three)
- Code project, if deemed applicable/appropriate
- Writing sample (no more than one per category)
- Analysis sample (no more than three)
- **Written answers** to eight questions:
  1. What work have you done that you are particularly proud of and why?
  2. What mistakes have you made that you particularly regret and why?
  3. What is an example of something that you learned that was a struggle
    for you? 
  4. When have you been happiest in your professional career and why?
  5. When have you been unhappiest in your professional career and why?
  6. Who is someone who has mentored you, and what did you learn from them?
  7. Who is someone you have mentored, and what did you learn from them?
  8. What qualities do you most admire in other software engineers?

Lest this seem arduous, note that much of this material is likely to be
preexisting (e.g., samples of prior work).  As for the balance, it has been
our experience that candidates themselves find answering these
self-reflective questions to be helpful to their own job search process,
entirely independently of any specific opportunity.

Once gathered from the candidate, submitted material should be distributed
to everyone on the interview list prior to the interview.

### Before the interview

Everyone on the interview schedule should read the candidate-submitted
material, and a pre-meeting should then be held to discuss approach:
based on the written material, what are the things that the team wishes
to better understand?  And who will do what?

### Pre-interview job talk

For senior candidates, it can be effective to ask them to start the day by
giving a technical presentation to those who will interview them.  On the
one hand, it may seem cruel to ask a candidate to present to a roomful of
people who will be later interviewing them, but to the candidate this should
be a relief:  this allows them to start the day with a home game, where they
are talking about something that they know well and can prepare for
arbitrarily.  The candidate should be allowed to present on anything
technical that they've worked on, and it should be made clear that:

1. Confidentiality will be respected (that is, to the degree that they are
   permitted by extant covenants, the candidate can present on work that
   isn't public with the assurance that privacy will be honored)

2. The presentation needn't be novel -- it is fine for the candidate to
   give a talk that they have given before

3. Slides are fine but not required

4. The candidate should assume that the audience is technical, but not
   necessarily familiar with the domain that they are presenting

5. The candidate should assume about 30 minutes for presentation and 15
   minutes for questions.

The aim here is severalfold.  

First, this lets everyone get the same information at once:  it is not
unreasonable that the talk that a candidate would give would be similar to a
conversation that they would have otherwise had several times over the day
as they are asked about their experience; this minimizes that repetition.

Second, it shows how well the candidate teaches.  Assuming that the
candidate is presenting on a domain that isn't intimately known by every
member of the audience, the candidate will be required to instruct. 
Teaching requires both technical mastery and empathy -- and a pathological
inability to teach may point to deeper problems in a candidate.

Third, it shows how well the candidate fields questions about their work.
It should go without saying that the questions themselves shouldn't be
trying to find flaws with the work, but should be entirely in earnest;
seeing how a candidate answers such questions can be very revealing about
character.

All of that said: a job talk likely isn't appropriate for every candidate --
and shouldn't be imposed on (for example) those still in school.  One
guideline may be:  those with more than seven years of experience are
expected to give a talk; those with fewer than three are not expected to
give a talk (but may do so); those in between can use their own judgement.

### Interviews

Interviews shouldn't necessarily take one form; interviewers should feel
free to take a variety of styles and approaches -- but should generally
refrain from "gotcha" questions and/or questions that may conflate
surface aspects of intellect with deeper qualities (e.g., Microsoft's
infamous "why are manhole covers round?").  Mixing interview styles
over the course of the day can also be helpful for the candidate.

### After the interview

After the interview (usually the next day), the candidate should be
discussed by those who interviewed them.  The objective isn't necessarily to
get to consensus first (though that too, ultimately), but rather to areas of
concern.  In this regard, the post-interview conversation must be handled
carefully:  the interview is deliberately constructed to allow broad contact
with the candidate, and it is possible than someone relatively junior or
otherwise inexperienced will see something that others will miss.  The
meeting should be constructed to assure that this important data isn't
supressed; bad hires can happen when reservations aren't shared out of fear
of disappointing a larger group!

One way to do this is to structure the meeting this way:

1. All participants are told to come in with one of three decisions: *Hire*,
   *Do not hire*, *Insufficient information*.  **All** participants should
   have one of these positions and they should not change their initial
   position.  (That is, one's position on a candidate may change over the
   course of the meeting, but the *initial* position shouldn't be
   retroactively changed.)  If it helps, this position can be privately
   recorded before the meeting starts.

2. The meeting starts with everyone who believes *Do not hire* explaining
   their position.  While starting with the *Do not hire* positions may
   seem to give the meeting a negative disposition, it is extremely
   important that the meeting start with the reservations lest they be
   silenced -- especially when and where they are so great that someone
   believes a candidate should not be hired.  

3. Next, those who believe *Insufficient information* should explain their
   position.  These positions may be relatively common, and it means that
   the interview left the interviewer with unanswered questions.  By
   presenting these unanswered questions, there is a possibility that others
   can provide answers that they may have learned in their interactions with
   the candidate.

4. Finally, those who believe *Hire* should explain their position, perhaps
   filling in missing information for others who are less certain.

If there are **any** *Do not hire* positions, these should be treated very
seriously, for it is saying that the aptitude, education, motivation, values
and/or integrity of the candidate are in serious doubt or are otherwise
unacceptable.  Those who believe *Do not hire* should be asked for the
dimensions that most substantiate their position.  **Especially** where
these reservations are around values or integrity, a single *Do not hire*
should raise serious doubts about a candidate: the risks of bad hires around
values or integrity are far too great to ignore someone's judgement in this
regard!

Ideally, however, no one has the position of *Do not hire*, and through a
combination of screening and candidate self-selection, everyone believes
*Hire* and the discussion can be brief, positive and forward-looking!

If, as is perhaps most likely, there is some mix of *Hire* and *Insufficient
information*, the discussion should focus on the information that is missing
about the candidate.  If other interviewers cannot fill in the information
about the candidate (and if it can't be answered by the corpus of material
provided by the candidate), the group should together brainstorm about how
to ascertain it.  Should a follow-up conversation be scheduled?  Should the
candidate be asked to provide some missing information?  Should some aspect
of the candidate's background be explored?  **The collective decision should
not move to *Hire* as long as there remain unanswered questions preventing
everyone from reaching the same decision.**

## Assessing the assessment process

It is tautologically challenging to evaluate one's process for assessing
software engineers:  one lacks data on the candidates that one doesn't hire,
and therefore can't know which candidates should have been extended offers
of employment but weren't.  As such, hiring processes can induce a kind of
ultimate [survivorship
bias](https://en.wikipedia.org/wiki/Survivorship_bias) in that it is only
those who have survived (or instituted) the process who are present to
assess it -- which can lead to deafening echo chambers of smug certitude.
One potential way to assess the assessment process:  **ask candidates for
their perspective on it.** Candidates are in a position to be evaluating
many different hiring processes concurrently, and likely have the best
perspective on the relative merits of different ways of assessing software
engineers.

Of course, there is peril here too:  while many organizations would likely
be very interested in a candidate who is bold enough to offer constructive
criticism on the process being used to assess them *while* it is being used
to assess them, the candidates themselves might not realize that -- and may
instead offer bland bromides for fear of offending a potential employer.
Still, it has been our experience that a thoughtful process will encourage a
candidate's candor -- and we have found that the processes described here
have been strengthened by listening carefully to the feedback of candidates.

