---
authors: Dave Pacheco <dap@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 45 Tooling for code reviews and code standards

As we look to scale contributions for Triton, Manta, and other Joyent software
from both new hires and the broader community, we're proposing to formalize the
existing process around code review and code standards.  Particularly, we'd like
to:

* provide an easy golden path for sending out code reviews, providing feedback,
  and iterating on that feedback
* make sure that these processes are clear to newcomers.  Ideally, these
  processes should be well-documented _and_ discoverable.
* enforce basic standards on all code changes, including that code passes `make
  check` (including both style and lint), smoke tests, and code review where
  appropriate, and that commit messages match the expected form.  It would be
  great if tooling made it easy to do the right thing here, rather than just
  disallowing the wrong thing.

The purpose of the proposal is to help automate and enforce the process we want,
not to impose new, different process just because that's what a tool happens to
do.  That said, adopting tooling would likely change the workflow a bit, and
it'll be important to distinguish between changes that are merely different
(e.g., you used to run command X and now you run command Y) from those that are
actually worse (e.g., you used to run command X to do something and now there's
no place in the workflow to do that). 

## Overview

This RFD covers:

* Our process today
* Proposed goals
* Proposal: Gerrit for both automation and code review
* Alternatives (GitHub, webrev, others)
* Gerrit deeper dive
* Frequently asked questions and frequently raised fears
* Questions to be answered
* Road map


## Our process today

The process we follow today is basically:

* Most components have one or more owners whose feedback is recommended for
  changes.
* Any member of the engineering team can push changes to any engineering repo.
  Community members can submit changes, but they generally have to be approved
  by someone on the team.
* Code review is recommended, but not strictly required.  (There is no mechanism
  to enforce code review.)  The specific mechanism for review varies by engineer
  and project: webrev, GitHub pull requests, links directly to commits on
  GitHub, links to patches in gists, and so on.  These sometimes get emailed or
  just dropped into Jabber.
* While reviewers can suggest that a change should not proceed, this is not
  enforced.  In practice, people generally do not integrate changes over the
  objections of reviewers.
* The expectation is that no change is integrated that does not pass `make
  check` and the built-in test suite.  In general, any breakage is considered
  bad, and needs to be either fixed or backed out quickly.
* We have defined requirements around commit messages, but these are not
  enforced by any tooling, and many commits to many repositories don't match
  these requirements.


## Proposed goals

We want to formalize this so that:

* all changes have the opportunity to be reviewed before integration, using an
  easy, uniform process for all core repositories
* we enforce `make check` and optionally basic smoke tests for each push
* we enforce one-commit-per-ticket (except for rare overrides).  That is, the
  same ticket should not be used in multiple commits in the same repository
  except for the rare case of fixups.
* we enforce commit message format

Unchanged from today: we'll continue to let anyone on the team to give final
approval for integrating a change (with the assumption that people are acting in
good faith).

The automation should support people's existing workflows, including allowing
engineers to preserve intermediate commits locally (and even pushing these to a
remote branch) while only submitting some of these checkpoints for review.

It would be nice if the system also supported:

* incremental diffs (e.g., multiple revisions of the same change)
* email notifications of new reviews and review feedback
* both general feedback and feedback associated with specific lines of code
* ability to interact via email or local editors or something other than the
  captive browser interface.  This might mean being able to reply to emails and
  have that feedback show up in the tool, or using a CLI (via an API) to submit
  review, or something else.
* code reviews from open-source community members

This system should also be easy for new users to get set up with.


## Proposal: Gerrit for both automation and code review

Gerrit is a web-based code review and code management system.  Using Gerrit
would be a pretty big change from our existing workflow.  In a typical
configuration:

* Gerrit stores the authoritative source repositories.  We'd use the Gerrit
  server instead of GitHub for cloning, pulling, and pushing repositories.
  People (and CI, through Jenkins) can still clone from GitHub.
* When you push changes to Gerrit, we can (but don't have to) enforce that they
  go through a review and sanity-check process.
* Once changes are integrated, Gerrit replicates changes to GitHub, so the
  GitHub repo is still useful, but changes would always go through Gerrit (even
  if we wanted to bypass the review process).

Pros:
* There's a very clear Golden Path for code review.  It would be pretty easy to
  enforce that all repos work the same way if we want.  The UI guides people
  through the process so that the "easiest path" is also the one that applies
  whatever process we want.
* We can enforce `make check`, successful test runs, and other criteria on all
  changes.  We can also configure these to be overridable, if desired.
* Gerrit has flexibility to implement our existing process, as well as stricter
  processes if we want that.  See the "Gerrit Deeper Dive" below.
* There's a command-line interface and REST API that includes support for
  reviewing changes.
* We could set up GitHub-based authentication/authorization so that external
  community members can use the same system.

Cons:
* The philosophy is pretty different from what we're used to.  Today, we're used
  to being able to push directly, and we assume people have done their homework.
  If they want to get review, they do it however they want.  With Gerrit, we
  would almost certainly want to ensure that the final integration step happens
  through Gerrit (either via the CLI, API, or web UI), and that feels like a
  pretty big change.
* Current engineers, new team members, and community members have to learn how
  to use Gerrit.  (They're less likely to already know how to use it than, say,
  GitHub.)

Gerrit provides a lot of structure around the code integration process.  There's
a deeper dive below.

## Alternatives

The automation and code review pieces are theoretically separate.

### GitHub-driven automation

We could configure all of our repos to run `make check` via jenkins when Pull
Requests are submitted.  Then people could use Pull Requests to submit changes
for review (even if they have access to the repository).   Note that we don't
have to use the PR "Merge" button for this to work, though that would also work
as long as we require merges to always fast forward.

Pros: We get the ability to verify that `make check` and the test suite pass for
each change that we review.

Cons: Pull Requests can be annoying to manage, and people sometimes don't bother
creating them.  For many changes, it's easier to just send people links to
commits and then push it to the repo directly.  Unless we enforce the PR
workflow somehow (including on project owners), then it's not very helpful.

### GitHub-driven code review

We could use GitHub Pull Requests for code reviews.  (This is similar to the
previous section, but we could do either one without the other.)

Pros: we'd have a path for code review.  It matches what many community members
expect, and it remains part of the history (although some of that might
disappear if people destroy their clones).

Cons:
* There are many downsides to GitHub diffs: e.g., they don't render manual
  pages.  Some people prefer to be able to draft comments and revise them before
  submitting them, but GitHub submits each individual piece of feedback right
  away.
* Incremental diffs are possible by submitting multiple commits, but then
  additional work is required to squash them when it's time to integrate.  Also,
  it's not always clear whether multiple commits are drafts of the same work
  (e.g., different checkpoints for reviewers to look at), or just intermediate
  work that the author didn't want to squash yet.

### Webrev-based code review

We could use webrev for code reviews.

Pros:
* Some people prefer webrev's presentation of diffs.
* Webrevs can be generated offline, copied around, and viewed offline.
* Webrevs can be easily archived (e.g., into Manta).

Cons:
* Although webrevs can be archived easily, we'd need to build new tools or
  infrastructure to organize and store them.
* Webrevs aren't a communication channel in themselves.  They don't provide any
  notifications, and feedback would need to be sent and stored separately.
* There's no one golden path for webrevs today; most people drop them into
  various Manta directories.  Incremental diffs are definitely possible, but
  they require manually managing each separate webrev.  For a change with 3
  revisions, you might reasonably want to keep each of the three revisions, plus
  three incremental webrevs.  We would likely want to build some tooling and
  documentation to make this easier.

As mentioned in the Gerrit section, we can have Gerrit generate webrevs to get
many of these benefits.

### Phabricator and other options

Gerrit is one of several systems that can manage process like this.  We have not
explored Phabricator or other similar tools, mainly because we'd heard positive
reports about Gerrit and a negative report about Phabricator.


## Gerrit Deeper Dive

### Quick demo

Let's walk through an example.  I've just created an empty repository on a
prototype server at cr.joyent.us.  First, I clone it:

    dap@sharptooth ~ $ git clone ssh://davepacheco@cr.joyent.us:29418/my-playground.git
    Cloning into 'my-playground'...
    remote: Counting objects: 2, done
    remote: Finding sources: 100% (2/2)
    remote: Total 2 (delta 0), reused 0 (delta 0)
    Receiving objects: 100% (2/2), done.

Now, let me add a README and commit that:

    dap@sharptooth my-playground $ vim README.md
    dap@sharptooth my-playground $ git add README.md 
    dap@sharptooth my-playground $ git commit -m "add initial README"
    [master 95a7c80] add initial README
     1 file changed, 1 insertion(+)
     create mode 100644 README.md

Now I'm ready to send this out for review.  Gerrit first-classes the idea of a
single logical change to the repository, and that's called a **Change** (of
course).  This isn't just a single commit; it encapsulates multiple revisions of
the work as well as the review and automated verification process around the
change.  I can create a new change from my commit by pushing to the magic branch
`refs/for/master`:

    dap@sharptooth my-playground $ git push origin HEAD:refs/for/master
    Counting objects: 4, done.
    Writing objects: 100% (3/3), 266 bytes, done.
    Total 3 (delta 0), reused 0 (delta 0)
    remote: Processing changes: new: 1, refs: 1, done    
    remote: 
    remote: New Changes:
    remote:   http://cr.joyent.us:8080/12 add initial README
    remote: 
    To ssh://davepacheco@cr.joyent.us:29418/my-playground.git
     * [new branch]      HEAD -> refs/for/master

Gerrit gave me back a URL that I can use to refer to this Change.  It also
assigns it a ChangeId.  (There's a long ChangeId and a short one.  We can
generally use the short one.  In this case, that's `12`.)

Reviewers can be automatically notified and they can leave their feedback in the
UI.  We won't go through that process here.

Once I've got feedback, I might make some changes to the README:

    dap@sharptooth my-playground $ vim README.md 
    dap@sharptooth my-playground $ git add README.md 
    dap@sharptooth my-playground $ git commit -m "forgot to add content"
    [master f6eb4be] forgot to add content
     1 file changed, 2 insertions(+)

At this point, I want to upload a new revision of the same Change.  Gerrit calls
each revision a **PatchSet**.  In order to submit it, I need to squash my
change:

    dap@sharptooth my-playground $ git rebase -i HEAD^^
    [detached HEAD 920280c] initial README; forgot to add content
     1 file changed, 3 insertions(+)
     create mode 100644 README.md
    Successfully rebased and updated refs/heads/master.

And then I push that to the magical reference `refs/changes/12` (because this is
a new PatchSet for Change 12):

    dap@sharptooth my-playground $ git push origin HEAD:refs/changes/12
    Counting objects: 4, done.
    Delta compression using up to 8 threads.
    Compressing objects: 100% (2/2), done.
    Writing objects: 100% (3/3), 316 bytes, done.
    Total 3 (delta 0), reused 0 (delta 0)
    remote: Processing changes: updated: 1, refs: 1, done    
    remote: 
    remote: Updated Changes:
    remote:   http://cr.joyent.us:8080/12 initial README; forgot to add content
    remote: 
    To ssh://davepacheco@cr.joyent.us:29418/my-playground.git
     * [new branch]      HEAD -> refs/changes/12

The Change's URL is the same as it was.  Now if you visit it, you'll see the
latest patchset by default.  You can also view diffs against the previous
patchset.

When we're satisfied with everything, we can integrate the change directly from
the Gerrit UI.  I've configured this project to only integrate changes into
master if they can be fast-forwarded.  Once the review process is done, the
Submit button will show up, and you click that to land the change.


### More about Gerrit

There are a few things to know about Gerrit before digging too far into it:

1. Gerrit formalizes the notion of a Change and patchset.  See above.
2. The process of "integrating" (or "landing") a change (either by merge,
   rebase, fast-forward, or cherry-pick) is called **submitting** it.  This
   might be confusing if you think of "submitting a change for review".  **In
   Gerrit, submitting a change refers to integrating it into master.**
3. Gerrit enforces that each patchset consists of exactly one commit.  This
   matches our policy for pushes, although we do sometimes review changes that
   aren't yet squashed.  You can still do this with Gerrit!  See the FAQ below.
4. Gerrit also formalizes the notion of approval with a voting system.  It uses
   numeric values, but these don't get added together.

**Gerrit's voting system:** Each reviewer can vote one of five ways on a change.
Note that **the votes do not get added together**.  By default, a Change must
have at least one +2 and no -2's in order to be merged.  The way this is
typically used is more like:

* +2: A thumbs-up, plus an endorsement to integrate the change.  Think of this
  as approval by a project owner to land the change in its current form.  In the
  illumos world, this is like approval by an RTI advocate.
* +1: The reviewer has given their thumbs-up for this change, but someone else
  will have to +2 it.  This would be used by a reviewer who still wants someone
  else to look at it.
* 0 (default): Use this to leave feedback without weighing in one way or the
  other.
* -1: The reviewer has issues with this change, but not so severe that it should
  block the change.
* -2: The reviewer believes the change should absolutely not integrate as-is.

In typical deployments, the policy is that a change requires one +2 (i.e., an
owner has to endorse the change) and no -2s (i.e., nobody has vetoed the
change).  You can see why no number of +1s add up to a +2 (and no number of -1s
add up to a -2).

The proposal is that we use "+2" to mean: "This looks like a good change and I'm
satisfied with the level of code review, testing, and risk associated with the
change."  (This does not mean that the person voting +2 has reviewed the code,
though they may also do that.)

Other nice things about Gerrit for our use-case:

* It's got a REST API and CLI for working with changes.
* It can integrate with GitHub auth.
* It's got a decent plugin system.  We can use this for Jenkins and JIRA
  integration.

Further reading:

* https://www.beepsend.com/2016/04/05/abandoning-gitflow-github-favour-gerrit/


## Frequently asked questions and frequently raised fears

**Are we changing our existing policies around code review or pre-integration
checks?**

No, but we've got several policies around commit message format and "make check"
that are not currently enforced, and we're proposing enforcing these.  To do
that, the long term plan would be that we only do most pushes through the Gerrit
Change Review process.

Gerrit's policies appear flexible enough to implement our existing policy (which
is essentially that anything goes -- see above), and it may be that Gerrit is
valuable even if all of the code review and verification features are optional.
But the assumption here is that it's worthwhile to enforce the practices we
already consider strongly recommended.


**What about merges from upstream (as for illumos)?**

While most deployments disallow pushing directly to master without going through
the Change process, Gerrit does support direct pushes.  Upstream merges may want
to bypass the review process and push directly to master, as we've already
decided that our policy is to incorporate these changes without review
(unless/until we discover breakage).  This seems like a special case.


**As an author, sometimes I want to be able to control exactly when integration
happens, even if all the reviewers are satisfied.  Can I do this?**

A Change becomes eligible for integration when requirements are met, like when a
+2 is provided _and_ no -2's are provided.  But the change isn't automatically
integrated.  There's a separate "Submit" button for this.  One approach that
some teams use is to provide an implicit -2 from the author on all new changes
to give the author a final opportunity to check on things before integrating a
change.


**I heard that Gerrit only supports single-commit changes.  How do we iterate on
reviews?**

Yes, each revision of a change (called a patchset) has to be encapsulated in a
single commit.  However, you can submit a new commit to an existing change.
This will show up as a new revision.  The web UI makes it easy for reviewers to
see the latest patchset (which encapsulates the current version of the entire
change) _or_ diff it against any previous patchset.  That allows reviewers to
diff between whatever they saw last time (or any previous time).


**Okay, but what if I like to keep a bunch of commits that I don't want to send
out for review?**

You can do this, too.

The deal with Gerrit is that each patchset (each revision of a change) has to be
a single commit.  That makes sense, because the patchset represents _exactly_
what's going to land onto master, which is a good thing.  Test what you ship,
and ship what you test.

But that doesn't mean you can't keep multiple commits locally.  All it means is
that when you want to send something for review, you have to create a squashed
commit -- but that doesn't have to change your working directory or even change
"master" on your working copy.  We could (and probably should) build a tool that
creates a new, temporary branch based on origin/master, cherry-picks all of your
local commits onto it, squashes them, submits that to Gerrit as either a new
change or a new patchset, and then switches back to the branch you were on.
Several of us have been using this workflow internally (without a tool), and it
works fine.

You can even push all your intermediate commits to a remote branch.  We don't
have to apply the Change Review process to every branch in a repo.


**What about cross-repository changes?**

As far as we can tell at this point, changes to multiple repositories have to be
submitted as separate Changes in Gerrit, without any link between them.  This is
analogous to separate webrevs or separate PRs.

When there's a cross-repo change to repositories A and B, and A explicitly
depends on B, then the automated verification might do the wrong thing,
depending on how that dependency is expressed.  If A depends on B's "master"
branch, then the automated verification will pull in the wrong B.  If A depends
on a specific commit of B (or semver), then the automated verification may pull
in the right version.  We may need to explore this more.


**What about cross-repository flag days?**

We'll have to treat these as separate changes, and whoever submits them will
need to know the appropriate order to submit them, and that all changes need to
be submitted.  (This isn't that different from the way pushes are coordinated
today.)


**I heard Gerrit pollutes commit messages with a piece of change-id metadata.**

To make iterating on changes easier, the common Gerrit workflow is that you
include this change-id line in your commit message.  That's how Gerrit knows
this is a new patchset for an existing Change, rather than a new Change.
However, this is not required: you can push to the special remote
`refs/changes/CHANGE_ID`, in which case you can leave the metadata out of the
commit message.  We recommend this approach.


**But I like webrev's presentation of diffs!**

We could build a Gerrit plugin that generates a webrev, stores it into Manta,
and links to it from the Gerrit interface.  We would still get the benefits of
automated checks and a channel for code review feedback, and we'd also get the
webrev benefit of rendering manual pages and generating PDFs.


**But I like GitHub's presentation of diffs!**

I haven't actually heard this request yet.  But there are Gerrit plugins that
attempt to synchronize pull requests with Gerrit changes.  Much more exploration
would be needed to figure out if this is possible, how to do it, and how to
avoid creating confusion.


**Will we be able to review community contributions in the same way?**

While we haven't tested this, the prototype Gerrit uses GitHub auth, so the
expectation is that community members could use the same process (provided
they're willing to use Gerrit).  This may mean that we need to manage access
control for repositories in Gerrit instead of GitHub, though.

## Questions to be answered

* Are we as a team and community happy with Gerrit specifically?  Particularly:
  with the inversion of control (i.e., Gerrit itself does all integrations, and
  we just push the button)?
* Are there other workflows in use today that we want to keep supporting that
  Gerrit doesn't support?

## Road map

Here's the proposed plan, assuming we don't decide to abort partway through if
we discover Gerrit won't work for us:

* get a prototype Gerrit instance set up so that people can start playing with
  it
* start fleshing out features of the Gerrit instance that we'll want (e.g.,
  commit message validation, running `make check`)
* meanwhile, have interested people start using Gerrit in earnest for their
  repositories (even if those features aren't all present yet)

For any given repository, the steps would be:

* add the repo to Gerrit so that people can submit changes and leave feedback
  with it
* add support for replication _from_ Gerrit _to_ GitHub so that people can also
  submit changes through Gerrit
* disallow pushing to GitHub directly, or pushing to #master in Gerrit without
  going through the submission process

To this end, we've set up a prototype Gerrit deployment in west1.  You can reach
it at:

    https://cr.joyent.us

**This isn't done yet!**  It's definitely usable, but it's missing things like
commit message validation, `make check` and more.  It may be redeployed and
updated frequently.  The plan is to avoid blowing away any state there, but at
this point, it's best to assume that changes there may get blown away as part of
playing with the prototype.

There are instructions for getting set up with the prototype and importing
projects here:

https://gist.github.com/davepacheco/66694bf6336736f289651f612579de24

There's also a summary there of what features have been implemented (e.g., email
notification, GitHub replication) and which are on the TODO list.

If you want to take a look at two real code reviews that went through Gerrit:

* https://cr.joyent.us/#/c/1/ (node-cueball)
* https://cr.joyent.us/#/c/14/ (node-jsprim)
