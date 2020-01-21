---
authors: John Levon <john.levon@joyent.com>
state: publish
discussion: https://github.com/joyent/rfd/issues/143
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 175 SmartOS integration process changes

## Problem

The vast majority of Joyent repositories have now been moved out of the Joyent
Gerrit server, leaving basically just the "platform" repositories, namely:

1. smartos-live
1. illumos-joyent
1. illumos-extra
1. illumos-kvm
1. illumos-kvm-cmd

With little appetite for continuing to maintain our own Gerrit server solely for
the platform repositories, we need to look at other options, and settle on a
plan that causes least friction for making platform changes easily. We'll
presume from this point that [cr.joyent.us](https://cr.joyent.us/) is no longer
going to be available.

## Github pull requests

The other Joyent repositories all now use github PRs for their integration
process. While some automation in this area is still in progress, this appears
to be working well in general.

However, for illumos-joyent especially, PRs can be a pretty miserable experience
when it comes to reviewing larger changes. In particular, the diff browser
insists on every file's diff being on the same page, making it close to
impossible to keep track of a large review, or newly introduced large files. The
canonical example I've been using is
[KPTI](https://github.com/illumos/illumos-gate/commit/74ecdb5171c9f3673b9393b1a3dc6f3a65e93895#diff-9ddb7d82a1170d4cf11ae141b03511b6).

It's common to pull down the PR to a local checkout for large reviews, but this
is still unpleasant when trying to comment on the actual diffs in the PR.

This is likely to be much less of an issue outside of illumos-joyent: large changes
are much rarer, although they can happen in the case of smartos-live.

We use github PRs for all of these repositories, despite the drawbacks.
For significant changes that prove difficult to review
via github, reviewers can request a webrev. In this case, review comments should
be added to the PR on the comment thread - it's not necessary to add them in
place in the PR's diffs, as that would defeat the point. If feasible though,
reviews should be done in github.

### Commit format

Commit messages should look like this:

```
OS-99999 Really kill Perl (#223)

OS-100000 Also Python
Reviewed by: Jack Reviewer <jack.reviewer@joyent.com>
Approved by: Jill Approver <jill.approver@joyent.com>
```

As previously, no free-form text is allowed or expected: prose should be in the ticket,
perhaps in the "Description" so it's clearly visible.

Note the addition of the git-style blank line: this change is for multiple reasons, but
the most relevant is that you cannot avoid adding this using the github user interface.
We don't want to *require* use of additional tooling.

The oneline also includes the pull request number (#223), as this is automatically added
by github, and it seems useful to have a direct link to the PR.

Any additional tickets should go on the third line next to the tags. Commits should not
needlessly group unrelated tickets together.

No changes are planned to what these annotations currently mean. Bugs will still be
filed and managed in JIRA. There is still an ongoing requirement of one code review
AND one integration approval before a PR can be merged to the master branch.

Code review corresponds to the reviewer approving the PR. For integration approval,
a reviewer must also add the "integration-approval" label to the PR.

If the branch is updated (e.g. to pull in the latest upstream code) after
the "integration-approval" label is added, the label must be manually removed
and the approver must re-add the label.

You may find that the merge button is disabled as you need to update to the current master
`HEAD`: in this case you can either do a merge from master yourself and push to the PR
branch, or use the handy "update branch" button in the `github` PR directly.

Never rebase a PR: this will necessitate a force-push to your PR branch, which means all
the previous changes get deleted, alongside all review comments.

There is a CLI utility [joyent/prr](https://github.com/joyent/prr) that can help automate
the final squash and merge, collecting the necessary ticket IDs and attributions from the
PR and building a suitable commit message.

The process will look something like this for repositories other than illumos-gate:

1. develop your changes on a branch
1. file JIRA bug(s) as before with more details on the changes
1. open a PR against master after pushing your branch, pointing to JIRA as needed.
1. request reviewers, wait for code review 
1. iterate as needed
1. add testing notes on any final version to the JIRA
1. wait for integration approval (as represented by the label)
1. squash and merge your change, with the commit message in the form above
1. close the JIRA(s) as Fixed

## Upstream first of illumos changes

One major change we'd like to experiment with concerns changes to illumos-joyent
that apply in part or in whole to illumos-gate.

Historically, we'd integrate a fix into illumos-joyent, and then sometime later,
an engineer might port the changes over to illumos-gate, build and re-verify as
needed, then go through the [standard illumos-gate RTI
process](https://illumos.org/books/dev/integrating.html). Soon after, those
changes would be merged *back* up to illumos-joyent as part of the daily merge.

This is clearly not working very well, as can be seen by [comparing our
trees](https://us-east.manta.joyent.com/Joyent_Dev/public/webrevs/platform-upstream-webrev/index.html).
It involves an unpleasant amount of busy-work resolving conflicts in both
directions. It is of little surprise that we are so badly divergent, even in
areas that don't in any way need to be.

Instead, we're going to switch over to an "upstream first" policy: that is, the
primary way to get changes into the product will be to integrate them into
illumos-gate, and let them arrive into downstream via the daily merge. This
should greatly reduce the tediousness of upstreaming currently necessary, and
reduce the risk represented by our divergence from mainstream illumos.

There are of course disadvantages to doing this: the merge with illumos-joyent
may end up more complex, as there may be implications to certain changes between
the two trees. Platform engineers will have to be directly involved in the
upstream review process rather than the Joyent-only one, and that might involve
some adjustments.

Some changes, such as those to lx and to various parts of the networking stack,
don't really make sense to upstream: either our divergence is already too significant
to cherry pick meaningfully, or - rarely - it really is a SmartOS specific change.
"Upstream first" should be considered a default attitude, not a hard-and-fast
policy; use judgement.

Note that illumos-gate are experimenting with a Gerrit server: this would be a
nice way to avoid the issues with github PRs identified above.

Platform-related JIRA bugs that correspond to changes that *aren't* going upstream
first like this should use the following labels:

1. no-upstream - this is never suitable for upstreaming into illumos-gate
1. upstream - this should be upstreamed at some point
1. upstreamed - this has been upstreamed

### Testing process

Testing is a potentially thorny issue: without significant illumos-gate testing
resources, Joyent engineers are somewhat limited in what can be tested directly
against that repository. This is especially true for anything involving
hardware.

The typical proposed development process for changes could be:

1. engineer works on the change against illumos-joyent until satisfied the
changes work as intended against SmartOS/Triton/Manta.
1. the changes are then brought over to illumos-gate for the usual review and
integration process. This would typically involve some basic re-confirmation
that the changes still work as expected, but this should of course be
shrink-to-fit.
1. the changes are integrated into illumos-gate
1. any necessary "glue" for merging them into illumos-joyent (such as adjusting
for a changed API in code that is only in illumos-joyent) can be dealt with by
a PR against illumos-joyent at the time of the daily merge.

Of course, this is only a suggested workflow - it might make sense to do the
whole thing against illumos-gate. The crucial part being that we do suitable product
testing as needed.

The illumos bug should contain all the relevant testing notes etc - this might
include SmartOS Specifics, and that seems fine. If necessary, a separate JIRA
could be filed for any Joyent-private details.
