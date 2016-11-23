---
authors: Chris Burroughs <chris.burroughs@joyent.com>
state: draft
---

# RFD 70: Joyent Repository Metadata

## Introduction

As of 2016-11 Joyents maintains upwards of 400 repositories.  The vast majority of these are public and hosted on GitHub.  GitHub provides only a flat hierarchy with no folders, tags, or other basic organizational tools. Currently there is little to no metadata to make sense of the state of -- or relationship among -- these repositories.  This document proposes maintaining centralized registry of repository metadata.


## Use Cases for Metadata

 * As a new employee or contributor, I'd like to be able to check out all of "Triton" on my first day.
 * As an engineer, I'd like to sync all of my repositories or do a basic bulk action like `git grep` across all of them.
 * For a policy change (such as [RELENG-612](https://smartos.org/bugview/RELENG-612)), which repositories are considered relevant?  Which can be considered archived and no longer need to be kept up to date?
 * If a node package has a known vulnerability, does it appear anywhere in our transitive dependency graph?
 * For a library we maintain, are all Joyent depends above version x.y.z? For a 3rd party library, how many unique version of it are we using?
 * Which repositories should be branched/tagged for a release?
 * Which repositories should be indexed by Hound or another tool?
 * Are all of the right repositories in Gerrit?
 * Audit github permissions or some other policy.
 * What are all of the open GitHub issues on active projects that been linked to an internal ticket that is now closed?
 * When testing a change to a 3rd party library we use, I'd like a reasonable path for computers to do all of the `package.json` mangling to build all of the CoaL services with the patched library.
 * An large customer might wish to know all 3rdparty packages that make up "Triton" (or "Manta") or have other compliance requirements that require a full dependency graph.
 * [Farther out] Pragmatically generate jenkins jobs.


## Proposal

## Option A (Android repo tool)

Within [another repository](https://xkcd.com/927/), maintain a repository manifest.  This would be a machine readable list of repositories and associated metadata.  Android has an existing convention for the >200 repositories that make up the "Android Open Source Project".  It's xml (eww?) and somewhat specific to Android's idiosyncrasies, but it already exists, is occasionally used by other projects, XML is purportedly extensible, and has a a small amount of (optional) existing tooling.

A small contrived example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote  name="github"
           fetch="https://github.com/"
           review="https://cr.joyent.us/" />
  <default revision="master" remote="github" sync-j="4" />

  <project path="meta/rfd" name="joyent/rfd" groups="" />
  <project path="meta/eng" name="joyent/eng" groups="" />

  <project path="os/smartos-live" name="joyent/smartos-live" groups="" />
  <project path="os/illumos-joyent" name="joyent/illumos-joyent" groups="" />
  <project path="os/illumos-kvm" name="joyent/illumos-kvm" groups="" />

  <project path="triton/triton" name="joyent/triton" groups="triton">
    <linkfile src="README.md" dest="triton/README.md" />
  </project>

  <project path="manta/manta" name="joyent/manta" groups="manta">
    <linkfile src="README.md" dest="manta/README.md" />
  </project>
</manifest>
```
Here the  `name` is the full name of the repository on GitHub, `path` is where to put it if you were to check out all of the repositories at once on your workstation, and `groups` is an arbitrary set of tags.  With the Android [repo tool](http://source.android.com/source/using-repo.html) a first time checkout would look like:

```
$ ./repo init -u example://manifest
$ ./repo sync
$ tree -L 2
.
├── manta
│   ├── manta
│   └── README.md -> manta/README.md
├── meta
│   ├── eng
│   └── rfd
├── os
│   ├── illumos-joyent
│   ├── illumos-kvm
│   └── smartos-live
├── repo
└── triton
    ├── README.md -> triton/README.md
    └── triton

```

Background Links:
 * [Initial Tool Announcement](https://opensource.googleblog.com/2008/11/gerrit-and-repo-android-source.html)
 * [Getting Started on Android](https://source.android.com/source/downloading.html#installing-repo)
 * [Format "Spec"](https://gerrit.googlesource.com/git-repo/+/master/docs/manifest-format.txt)
 * [Android Manifest](https://android.googlesource.com/platform/manifest/+/master/default.xml)
 * [3rd party blog](https://harrow.io/blog/using-repo-to-manage-complex-software-projects/)

Note that this is *not* a proposal to make the use of `repo` mandatory, to bless a particular hierarchical structure of Joyent repositories as the One True Way that you Must Use on your workstation, or adopt other parts of the Android workflow.

See [#Initial Layout and Tagging]() for a proposed initial layout.  The intent of the on-disk layout is to provide some clues to humans (so they don't have 400+ repos in one directory) while groups will  provide the metadata for computer programs.  ("manta" and "triton" are well known examples, but likely poor choices due to overlap.  A more likely example would be a node library could be tagged with both "manta" and "triton" and placed in lib/js.)

This model *would* struggle with private and internal repositories.  Having the manifest be private would be lame, while gluing multiple public and private repositories together would be error prone.  It's possible that the set of repositories that are still active *and* private is sufficiently small that no further format structure is needed.

## Option B (roll our own)

Same basic approach as Option A, but role our own format and tools.

There are several desirable attributes that we could get by rolling out own format:
 * json
 * not xml
 * richer key-value labels instead of csv strings
 * Tooling support for composing multiple manifests (public vs private)

Over the long term we would have more control over the tooling and be able to customize to our needs.

A possible example json manifest that is similar to the repo xml:

```json
{
    "remote": {
        "default": "ghjoyent",
        "remotes": [
            {"name": "ghjoyent",
             "template": "https://github.com/joyent/{{reponame}}"},
            {"name": "cr",
             "template": "somethingsomething-gerrit"}
        ]
    },

    "repository": {
        "defaultLabels": {
            "public": true,
            "status": "active"
        },
        "repositories": [
            {
                "name": "rfd",
                "defaultDir": "meta",
                "labels": {
                    "meta": true
                }
            },{
                "name": "triton",
                "defaultDir": "meta",
                "linkFiles": [
                    {"src": "README.md", "dest": "README.triton.md"}
                ],
                "labels": {
                    "triton": true,
                    "meta": true
                }
            },{
                "name": "manta",
                "defaultDir": "meta",
                "linkFiles": [
                    {"src": "README.md", "dest": "README.manta.md"}
                ],
                "labels": {
                    "manta": true,
                    "meta": true
                }
            },{
                "name": "eng",
                "defaultDir": "meta",
                "linkFiles": [
                    {"src": "README.md", "dest": "README.eng.md"}
                ],
                "labels": {
                    "meta": true
                }
            },{
                "name": "smartos-live",
                "defaultDir": "os",
                "labels": {
                    "os": true
                }
            },{
                "name": "illumos-joyent",
                "defaultDir": "os",
                "labels": {
                    "os": true
                }
            },{
                "name": "illumos-kvm",
                "defaultDir": "os",
                "labels": {
                    "os": true
                }
            }
        ]
    }
}
```

In this scenario we would write our own cli tool to check out all of the repos, or sync them on a workstation.  The primary virtue of Android's repo is that it already exists for the simple CLI cases (check out all the repos).  To my knowledge there isn't a broader ecosystems of tooling around it.


Q: Same "manifest must be versioned in a repository" requirement as Android-repo?

## Initial Layout and Tagging

TODO: What should the initial organization and labels be.

## Alternatives

### GitHub Teams

GitHub does have the notion of "Teams" that can contain repositories.  Today for example `joyent/python-manta` is in the `python-manta` team.  These could function be used with a convention to behave like tags.  The introduces no new tools or concepts.  However:
 * Teams are obscured in the GitHub UI, for example when you view it repository there is no list of teams displayed.
 * No read only API access, making use on workstations or jenkins awkward.
 * Modifying tags becomes a mouse clicking contest instead of editing a text file.

GitHub teams may be a worthwhile complimentary approach for very coarse grained grouping.  For example, a "Graveyard" of repositories that have not seen updates for years, are no longer used, and won't be maintained.

### In-repo Piggyback

There are several files (such as `README.md` or `package.json`) that are present in most repositories already.   We could develop a convention for encoding the same metadata within one of those files, such as `python-markdown2` blocks at the top of the README.  This has the notable advantage of placing the metadata front and center for humans explorers.

On the down side, this is awkward for forks and there are likely many corner cases where no consistent file exists.  While it is not likely that performance will be particularly important, "iterate over all of the repos and download their README's" isn't the most promising start.  More importantly, in the long run I think this will prove unwieldy to manage due to the same problems that call for metadata to begin with. Adding a tag to 100 projects would be 100 commits in 100 different places, instead of one commit in one place.

### Dramatically reduce total number of repositories

For example by aggressive pruning, consolidation, or [architectural](https://twitter.com/monorepi) changes.  This would be a disproportional disruption to the scale of the original problem.


### Migrate Git hosting to a platform with more features

For example, something with tags or a directory structure.  This again would be disproportionate effort & disruption to the problem at hand.

### Other Tools

There are a few other "manage a bunch of git repo" projects:
 * [myrepos](https://myrepos.branchable.com/)
 * [mu-repo](https://fabioz.github.io/mu-repo/)
 * [gr](http://mixu.net/gr/)
 * [vcspull](http://vcspull.readthedocs.io/en/latest/)

Most appear more focused on running ad-hoc commands on *existing* checkouts, and not describing remotes.  `vcspull` is closest in spirit -- there is a config file! -- but is narrowly focused on the checkout & sync cycle of a simple hierarchy.

There are also several ways of taking an existing large repository and working with it as if it were a series of smaller repositories, but that is the opposite of the current problem.


## Questions

Q: Are in-active/dead/archived things listed as such in the manifest, implicit by being ignored, or stuck in their own GitHub team "graveyard"?

Q: Do we need to handle the private repos at all, since they are not part of the main product offering?

## Resources and Prior Art

The [triton](https://github.com/joyent/triton/blob/master/docs/developer-guide/repos.md) and [manta](https://github.com/joyent/manta) docs have a manually curated list of relevant repositories.

Internal RELENG tooling has a `repos.json` with partial coverage.

Some of the doc building tools (ie apidocs) have a smaller list of repos to pull from.

## Appendix

### Json Schema for Option B

WIP Example

```json
{
    "$schema": "http://json-schema.org/draft-04/schema#",
    "type": "object",
    "required": ["remote", "repository"],
    "properties": {
        "remote": {
            "type": "object",
            "properties": {
                "default": {"type": "string"},
                "remotes": {
                    "type": "array",
                    "items": {
                        "$ref": "#/definitions/remote"
                    }
                }
            }
        },
        "repository": {
            "type": "object",
            "properties": {
                "defaultLabels": {
                    "$ref": "#/definitions/labels"
                }
            }
        },
        "repositories": {
            "type": "array",
            "items": {
                "$ref": "#/definitions/repo"
            }
        }
    },
    "definitions": {
        "remote": {
            "type": "object",
            "required": ["name", "template"],
            "properties": {
                "name": {"type": "string"},
                "template": {"type": "string"}
            }
        },
        "labels": {
            "type": "object",
            "additionalProperties": false,
            "patternProperties": {
                ".+": {
                    "oneOf": [
                        {"type": "boolean"},
                        {"type": "string"}
                    ]
                }
            }
        },
        "repo": {
            "type": "object",
            "required": ["name"],
            "properties": {
                "name": {"type": "string"},
                "defaultDir": {"type": "string"},
                "labels": {"$ref": "#/definitions/labels"},
                "linkFiles": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["src", "dest"],
                        "properties": {
                            "src": {"type": "string"},
                            "dest": {"type": "string"}
                        }
                    }
                }
            }
        }
    }
}
```
