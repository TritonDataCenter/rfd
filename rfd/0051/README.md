---
author: Jerry Jelinek <jerry.jelinek@joyent.com>
state: predraft
---

# RFD 51 Code Review Guidance

## Introduction

With the adoption of
[RFD 45](https://github.com/joyent/rfd/blob/master/rfd/0045/README.md)
and the expectation for code review across all of the SDC repositories, it is
helpful for us to have a general consensus on how a code review should proceed.

The high level goal of code review is generally well understood. The purpose
is to catch bugs, or other mistakes, before the code is integrated.

This RFD outlines some general guidance for how the code author, and reviewers,
should approach the review process.

## The Code Author

Receiving code review feedback can sometimes feel like an attack. After
spending considerable effort to solve a problem, someone else is telling you
that you did something wrong. During code review it helps to recognize that
the feedback is not malicious and that the reviewer is trying to help you
integrate the best solution possible. As a developer, I am always grateful
when code review identifies a mistake or helps me toward a better approach.
There is nothing worse than the feeling you have if your code causes a problem
in production. And of course, fixing problems in production is much more
difficult than in pre-integration.

As the code author, you bear the ultimate responsibility for the code that is
integrated. Reasonable people can disagree, and it is always your perogative
to decline any piece of feedback if you are confident in your approach. However,
be open to feedback and willing to consider alternatives. The reviewer is
looking at your code with a new perspective and may have ideas which you did
not consider. The reviewer may have invested considerable effort in going
through your change, and you should be open to that feedback.

If there is feedback which you disagree with, or are unclear about, it is
generally best to contact the reviewer directly and have a discussion about
the issue. The code review tool is not the best way to discuss a complicated
issue.

## The Reviewer

As a reviewer you should follow the golden rule; give feedback with respect in
the same way that you want to receive feedback on your code. As noted above,
code review feedback can easily feel like an attack, so consider your wording
on any non-obvious comment.

As we all know, each of us would likely come up with a different implementation
to solve a complex problem. Recall that the purpose of code review is not to
make the code look like the way you would implement it. It is to find bugs or
other obvious mistakes. If you can think of a "better" solution to the problem,
it is fine to propose that, but the code author is the one who is responsible
for the code and they are free to choose the implementation that makes sense
for them. However, algorithmic mistakes, such as order problems (big O), are
valid objections for code review.

Be clear in your feedback. Don't confuse the author with your input. As noted
above, if there is a complex issue, it is best to have a discussion with the
author directly so you can work through the problem together. The code review
tool is not a good mechanism for a lengthy discussion.

Be sparing in your use of -1. Obviously use -1 for a bug, or a typo in a
comment, but if you want something more nebulous, such as comment rewriting,
propose that but use a 0 or even +1. The author can accept that input without
feeling blocked.

Restrict your feedback to the change being reviewed. Fixing unrelated parts
of the code is outside the scope of code review. File a separate bug for that
if you are concerned.

Recall that as a reviewer, you are trying to assist the author. You are not
a gatekeeper and your role is not to block integration; it is to find mistakes
and help the author integrate a good change.
