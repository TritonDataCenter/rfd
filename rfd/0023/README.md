---
authors: Trent Mick <trent.mick@joyent.com>
state: publish
---

# RFD 23 Manta docs pipeline

Here in the docs plan for Manta (where primary sources live, how to build them,
how to publish them). If this document and reality differ, then someone hasn't
kept this up to date. :)

The Manta docs are spread across a few repositories, and publishing is to
more than one site (and sites that also publish docs for other projects).
For a while (up to Jan 2016) the publishing pipeline was effectively broken:
the published docs at apidocs.tritondatacenter.com were not updatable from primary
sources. Hence this RFD to act as the authority for the plan.

Note that content on <www.joyent.com> for Manta is out of scope for this RFD.


## Manta docs pipeline

### Sources

The primary Manta docs are Markdown files in a number of git repositories.

| Repo | Description |
| ---- | ----------- |
| [manta.git](https://github.com/TritonDataCenter/manta) | General Manta intro/landing-page is the repo [README.md](https://github.com/TritonDataCenter/manta/blob/master/README.md). [Operator Guide](https://github.com/TritonDataCenter/manta/tree/master/docs/operator-guide). [User Guide](https://github.com/TritonDataCenter/manta/tree/master/docs/user-guide). |
| [manta-muskie.git](https://github.com/TritonDataCenter/manta-muskie) | Manta [REST API](https://github.com/TritonDataCenter/manta-muskie/tree/master/docs) docs |
| [node-manta.git](https://github.com/TritonDataCenter/node-manta) | ["Node.js SDK"](https://github.com/TritonDataCenter/node-manta/tree/master/docs) docs: man pages and node.js library docs |
| [manta-compute-bin.git](https://github.com/TritonDataCenter/node-manta) | [Man pages](https://github.com/TritonDataCenter/manta-compute-bin/tree/master/docs/man) for Manta compute job utilities, e.g. `maggr`, `mcat`. |


### Publish Targets

| URL | How to update | Description |
| --- | ------------- | ----------- |
| <https://apidocs.tritondatacenter.com/manta> | [How to update](#how-to-update-the-manta-user-guide) | Manta user guide |
| <https://github.com/TritonDataCenter/manta> | [How to update](#how-to-update-the-manta-landing-page) | Manta project landing page for those with a code/operator interest |
| <http://joyent.github.io/manta/> | [How to update](#how-to-update-the-manta-operator-guide) | (The somewhat hard to find) publishing of the manta operator guide |
| <https://joyent.com/manta> | - | **Out of scope.** Currently redirects to <joyent.com/object-storage>. |

#### How to update the Manta User Guide

The [published User Guide](https://apidocs.tritondatacenter.com/manta) is made up of a
number of separate logical groups. The first step is to find out which.
Currently all results are dumped into one flat directory. Eventually those
will be spread into logical separate dirs making identifying the source easier,
but not yet.

| Name | URL pattern | Source |
| ---- | ----------- | ------ |
| api | api.html | <https://github.com/TritonDataCenter/manta-muskie/blob/master/docs/index.md> |
| nodesdk | nodesdk.html, m\*.html | <https://github.com/TritonDataCenter/node-manta/blob/master/docs>, note some "m\*.html" man pages in manta-compute-bin.git |
| compute-man-pages | m\*.html | <https://github.com/TritonDataCenter/manta-compute-bin/tree/master/docs/man>, note some "m\*.html" man pages in node-manta.git |
| compute-examples | example-\*.html | <https://github.com/TritonDataCenter/manta/tree/master/docs/user-guide/examples> |
| base | \*.html (everything else) | <https://github.com/TritonDataCenter/manta/tree/master/docs/user-guide> |



1. Find the source group from the table above and edit source Markdown.

2. Get a review from  Manta developers (whether via 'manta@' internal chat,
   MANTA internal Jira ticket, email to Manta developers,
   GitHub PR, or `#joyent` IRC).

   Currently the build and publishing of the User Guide is done in a
   private [apidocs.tritondatacenter.com.git repository](https://github.com/TritonDataCenter/apidocs.tritondatacenter.com),
   so non-Joyent employees will have to stop at this step.

3. (For "compute-examples" group only.) The example-FOO.html files are built
   wholely in the "manta.git", and the resultant HTML is commited. The HTML
   is the output of a `mjob share`. The rebuild the full set of example files,
   you first need your SSH key on the Joyent "manta" account used to house
   the examples, then:

        cd manta/     # joyent/manta.git clone
        make docs-regenerate-examples

   See [the examples
   README](https://github.com/TritonDataCenter/manta/tree/rfd23/docs/user-guide/examples)
   for details.

   Review and commit any HTML changes. Note: Because a re-run of a job changes
   its UUID, there will be a large change for what could be effectively no
   change. Try to avoid unnecessary churn.

4. Re-import and build all Manta User Guide changes in a clone of
   apidocs.tritondatacenter.com.git:

        git clone git@github.com:joyent/apidocs.tritondatacenter.com.git
        cd apidocs.tritondatacenter.com
        make import-docset-manta
        # Follow printed instructions to 'git diff' and 'git commit'.

   You can optionally configure separate branches or git SHA revs for
   doc imports in [the "etc/config.json"
   file](https://github.com/TritonDataCenter/apidocs.tritondatacenter.com/blob/master/etc/config.json).

5. Talk to the master o' the docs (current MattF) to re-publish
   apidocs.tritondatacenter.com.


#### How to update the Manta Landing Page

1. Update the manta.git README.md:
   <https://github.com/TritonDataCenter/manta/blob/master/README.md>.

   Get a review from  Manta developers (whether via 'manta@' internal chat,
   MANTA internal Jira ticket, email to Manta developers,
   GitHub PR, or `#joyent` IRC).


#### How to update the Manta Operator Guide

1. Update the Markdown sources at
   <https://github.com/TritonDataCenter/manta/tree/master/docs/operator-guide>.

   Get a review from  Manta developers (whether via 'manta@' internal chat,
   MANTA internal Jira ticket, email to Manta developers,
   GitHub PR, or `#joyent` IRC).

2. Publish via the make target in the manta.git repo:

        cd manta/         # joyent/manta.git clone
        make publish-operator-guide

The operator guide is currently published via GitHub Pages. Publishing is:
(a) build the HTML from the Markdown (restdown) source, (b) update the
gh-pages branch and push.


The Operator Guide *styling* is currently the default "ohthejoy" "brand" for the
[restdown](https://github.com/trentm/restdown) tool being used to build it.
Restdown is a light-weight wrapper for single-page Markdown docs (mostly just
adding a TOC and some styling). The change the styling one would need to
provide a custom restdown "brand". E.g. [the restdown brand for Manta docs
in apidocs.tritondatacenter.com](https://github.com/TritonDataCenter/apidocs.tritondatacenter.com/tree/master/etc/manta-brand),
or the ["remora" restdown brand currently used for cloudapi
docs](https://github.com/TritonDataCenter/restdown-brand-remora).


## Future

Future plans/ideas.

- follow up on mantadoc.git/docs/winmanta.md - Created, but never made it to
  deployment on apidocs.tritondatacenter.com that I can see. TODO: Do we want to clean it
  up and ship it? My pref would be to drop all/most of the screenshots of node
  install b/c maint burden.

- Switch all manta restdown docs away from 'wiki-tables' to GH style tables

- Consider the restdown-brand-remora (used for cloudapi docs) instead of
  "apidocs.tritondatacenter.com.git:etc/manta-brand" (a copy of the old mantadoc.git's
  "bluejoy" brand). This would align styles on apidocs.tritondatacenter.com. However,
  might also just want to move to the styles on docs.joyent.com.
  See the "longer term" TODO below.

- Some sane hierarchical layout:
    - mjob examples in examples/$name/...
    - man pages in man/...

- Having an "edit this" link on the footer of each doc automatically added
  which links to the relevant primary doc in GitHub would be pretty nice.

- Longer term: The styling of docs on apidocs.tritondatacenter.com should move away
  from the current "bluejoy" theme (for manta docs) and "remora" theme (for
  others) to the same style as the docs.joyent.com docs.

- Longer term: I consider apidocs.tritondatacenter.com a bug. Joyent is too small to have
  two separate doc sites. There whould be one "docs.joyent.com" with organized
  publishing of all our content. Same opinion for the Manta operator docs at
  <joyent.github.io/manta>. IMHO. Anyway, that is for another time.


## History of Manta Docs state

### state as of Jan 2016

[DOC-642](https://mnx.atlassian.net/browse/DOC-642) will get us back
to being able to update from primary sources.


### state as of Dec 2015

Sources:

- node-manta.git: "node.js SDK" docs
- manta-muskie.git: Manta web front-end docs (mainly the REST API)
- manta-compute-bin.git: man pages for Manta job utilities
  (e.g. `maggr`, `mcat`)
- manta.git: General Manta intro/landing-page in the README.md, plus
  the operator guide and
- mantadoc.git: A collection point for the other sources *plus additional
  source content*.

"Published" endpoints:

- <joyent.com/manta> currently redirects to <joyent.com/object-storage>. This
  is marketing controlled area -- out of scope for this RFD.
- <https://apidocs.tritondatacenter.com/manta/> Primary Manta user doc area.
- <https://github.com/TritonDataCenter/manta> Landing page for those with a
  code/operator interest Manta.
- <http://joyent.github.io/manta/> A somewhat hard to find publishing of
  the manta operator guide.

Update content for <joyent.github.io/manta>:

- `make docs`
- copy the index.html file into the "gh-pages" branch and push that

Updating content for <apidocs.tritondatacenter.com/manta>:

- Manually edit the HTML previous snapshotted to
  <https://github.com/TritonDataCenter/apidocs.tritondatacenter.com/tree/master/htdocs/manta> !
  Yuck. This is the main doc pipeline thing to fix in the shorterm

Sources:

- node-manta.git: "node.js SDK" docs
- manta-compute-bin.git: man pages for Manta job utilities
  (e.g. `maggr`, `mcat`)
- manta-muskie.git: Manta web front-end docs (mainly the REST API)
- manta.git: General Manta intro/landing-page in the README.md, operator guide,
  and (proposed) new source for the primary content in mantadoc.git.

Currently we are bound by the organization of the doc files as mantadoc.git has
them. A downside of this plan is that it *does* mean that apidocs.tritondatacenter.com.git
becomes the repo that knows how to lay things out. I'd hope to eventually make
apidocs.tritondatacenter.com.git "dumb" in this regard: with manta.git being the repo that
has the logical doc organization with places for the muskie and node-manta.git
docs to slot in.

A reason I want to take mantadoc.git out of the picture is that I want to avoid
a pipeline for doc fixes that involves three repos: (a) fix source doc in, say,
manta.git; (b) update collected docs in mantadoc.git; (c) update for publishing
in apidocs.tritondatacenter.com.git.  I want to cut out repo (b).



## Tickets

- [DOC-642](https://mnx.atlassian.net/browse/DOC-642)
- [DOC-646](https://mnx.atlassian.net/browse/DOC-646)
