---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 23 A plan for Manta docs

The problem: Currently manta docs are published in a number of places, have
primary sources in a number of repos, and the update process is undocumented
and/or broken.

This RFD intends to clarify current state, make a plan for fixing shortterm
egregious issues, provide some future goals/dreams, and live on as the
documented plan for Manta docs. Note that content on <www.joyent.com> for Manta
is out of scope for this RFD.


## state as of Dec 2015

Sources:

- node-manta.git: "node.js SDK" docs
- manta-muskie.git: Manta web front-end docs (mainly the REST API)
- manta.git: General Manta intro/landing-page in the README.md, plus
  the operator guide and
- mantadoc.git: A collection point for the other sources *plus additional
  source content*.

"Published" endpoints:

- <joyent.com/manta> currently redirects to <joyent.com/object-storage>. This
  is marketing controlled area -- out of scope for this RFD.
- <https://apidocs.joyent.com/manta/> Primary Manta user doc area.
- <https://github.com/joyent/manta> Landing page for those with a
  code/operator interest Manta.
- <http://joyent.github.io/manta/> A somewhat hard to find publishing of
  the manta operator guide.

Update content for <joyent.github.io/manta>:

- `make docs`
- copy the index.html file into the "gh-pages" branch and push that

Updating content for <apidocs.joyent.com/manta>:

- Manually edit the HTML previous snapshotted to
  <https://github.com/joyent/apidocs.joyent.com/tree/master/htdocs/manta> !
  Yuck. This is the main doc pipeline thing to fix in the shorterm


## short term plan

- Stick with all the current publish endpoints.
- Move any primary content in mantadoc.git over to manta.git and deprecate
  mantadoc.git.
- Add a build script to apidocs.joyent.com.git to build and import the
  manta user docs from the three source repos (similar to what is done for
  the cloudapi and sdc-docker docs).
- Add a Makefile target to manta.git to simplify updating joyent.github.io/manta
  for updates to the operator guide.
- Backport manual edits to *HTML* content in apidocs.joyent.com.git back to
  source Markdown.

Sources:

- node-manta.git: "node.js SDK" docs
- manta-muskie.git: Manta web front-end docs (mainly the REST API)
- manta.git: General Manta intro/landing-page in the README.md, operator guide,
  and (proposed) new source for the primary content in mantadoc.git.

Currently we are bound by the organization of the doc files as mantadoc.git has
them. A downside of this plan is that it *does* mean that apidocs.joyent.com.git
becomes the repo that knows how to lay things out. I'd hope to eventually make
apidocs.joyent.com.git "dumb" in this regard: with manta.git being the repo that
has the logical doc organization with places for the muskie and node-manta.git
docs to slot in.

A reason I want to take mantadoc.git out of the picture is that I want to avoid
a pipeline for doc fixes that involves three repos: (a) fix source doc in, say,
manta.git; (b) update collected docs in mantadoc.git; (c) update for publishing
in apidocs.joyent.com.git.  I want to cut out repo (b).


## longer term

Longer term #1: The styling of docs on apidocs.joyent.com should move away from
the current "bluejoy" theme to the same style as the docs.joyent.com docs.

Longer term #2: I consider apidocs.joyent.com a bug. Joyent is too small to have
two separate doc sites. There whould be one "docs.joyent.com" with organized
publishing of all our content. Same opinion for the Manta operator docs at
<joyent.github.io/manta>. IMHO.  Anyway, that is for another time.