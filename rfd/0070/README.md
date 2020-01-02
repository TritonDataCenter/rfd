---
authors: Chris Burroughs <chris.burroughs@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+70%22
---

# RFD 70 Joyent Repository Metadata

## Introduction

As of 2018-03 Joyent maintains well over 500 repositories.  The vast majority of these are public and hosted on GitHub.  GitHub provides only a flat hierarchy with no folders, tags, or other basic organizational tools. Currently there is little to no metadata to make sense of the state of -- or relationship among -- these repositories.  Several repositories maintain ad-hoc lists of other repositories for their own purposes.  This document proposes maintaining a centralized machine readable registry of repository metadata.


## Use Cases for Metadata

 * As a new employee or contributor, I'd like to be able to check out all of "Triton" on my first day.
 * As an engineer, I'd like to sync all of my repositories or do a basic bulk action like `git grep` across all of them.
 * For a policy change (such as [RELENG-612](https://smartos.org/bugview/RELENG-612)), which repositories are considered relevant?  Which can be considered archived and no longer need to be kept up to date?
 * If a node package has a known vulnerability, does it appear anywhere in the transitive dependency graph of any shipped product?
 * For a library we maintain, are all Joyent projects above version x.y.z? For a 3rd party library, how many unique version of it are we using?
 * Which repositories should be branched/tagged for a release?
 * Which repositories should be indexed by Hound or another tool?
 * Audit GitHub permissions or some other policy.
 * What are all of the open GitHub issues on active projects that been linked to an internal ticket that is now closed?
 * When testing a change to a 3rd party library we use, a reasonable path for computers to do all of the `package.json` mangling to build all of the Triton services with the patched library.
 * An large customer might wish to know all 3rdparty packages that make up "Triton" (or "Manta") or have other compliance requirements that require a full dependency graph.
 * Programatically generate Jenkins jobs.
 * Stitch disparate documentation together into a cohesive whole.

Circa 2018-03 there are several upcoming bulk changes (`TOOLS-1981`, `TRITON-155`) that are motivating starting points.  The human driven exploratory use cases ("check out all the code") are not as clear.

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
 * [ChromeOS Manifeset](https://chromium.googlesource.com/chromiumos/manifest.git/+/master/full.xml)
 * [3rd party blog](https://harrow.io/blog/using-repo-to-manage-complex-software-projects/)
 * [tips and tricks](http://xda-university.com/as-a-developer/repo-tips-tricks)

Note that this is *not* a proposal to make the use of `repo` mandatory, to bless a particular hierarchical structure of Joyent repositories as the One True Way that you Must Use on your workstation, or adopt other parts of the Android workflow.

The intent of the on-disk layout is to provide some clues to humans (so they don't have 400+ repos in one directory) while groups will provide the metadata for computer programs.  ("manta" and "triton" are well known examples, but likely poor choices due to overlap.  A more likely example would be a node library could be tagged with both "manta" and "triton" and placed in lib/js.)

This model would struggle with private and internal repositories.  Having the manifest be private would be lame, while gluing multiple public and private repositories together would be error prone.  It's possible that the set of repositories that are still active *and* private is sufficiently small that no further format structure is needed.


### Future of repo tool

In late 2016 proposals were [published](https://storage.googleapis.com/gerrit-talks/summit/2016/bye-bye-repo.pdf) for Android to [migrate away](https://groups.google.com/d/topic/repo-discuss/tyteGt1rHME/discussion) from `repo` in favor of git sub-modules (contingent on future improvements to sub-modules).  `repo` is still in use circa 2018 and the status of the migration is unclear.  While there is now a surprising plurality of non-Google contributors to `repo`, this does cause significant concern about the longevity of the tool.

It also illustrates a divergences of use cases between `repo` and this RFD.  The raison d'être of `repo` is to pretend there is only a single repository with all of the Android code.  The grouping & tagging of repositories (the most important part for this RFD) is secondary or subservient to that goal.

## Option B (roll our own)

Same basic approach as Option A, but role our own format and tooling.

There are several desirable attributes that we could get by rolling out own format:
 * json (not xml)
 * richer key-value labels instead of csv strings
 * The xml schema wasn't a particularly valuable part of `repo` anyway.

Over the long term we would have more control over the tooling and be able to customize to our needs.  If we don't value `repo` in particular, adopting it's format brings us no closer to the tooling we do care about.

In this scenario we would write our own cli tool to check out all of the repos, or sync them on a workstation.  Tooling would likley grow organically to solve the various outlined use cases.  The primary virtue of Android's repo is that it already exists for the simple CLI cases (check out all the repos).  To my knowledge there isn't a broad ecosystems of more interesting tooling around it.

Most narrowly, this option can be read as replacing the `n` existing ad-hoc json listings of repositories with a single file.

## Alternatives

### GitHub Teams

GitHub does have the notion of "Teams" that can contain repositories.  Today for example `joyent/python-manta` is in the `python-manta` team.  These could function be used with a convention to behave like tags.  The introduces no new tools or concepts.  However:
 * Teams are obscured in the GitHub UI, for example when you view it repository there is no list of teams displayed.
 * Limited API access, making use on workstations or jenkins awkward.
 * Modifying tags becomes an arduous mouse clicking contest instead of editing a text file.

GitHub teams may be a worthwhile complimentary approach for very coarse grained grouping.  The mapping of Joyent roles to GitHub teams could also be clearer.


### In-repo Piggyback

There are several files (such as `README.md` or `package.json`) that are present in most repositories already.   We could develop a convention for encoding the same metadata within one of those files, such as `python-markdown2` blocks at the top of the README.  This has the notable advantage of placing the metadata front and center for humans explorers.

On the down side, this is awkward for forks and there are likely many corner cases where no consistent file exists.  While it is not likely that performance will be particularly important, "iterate over all of the repositories and download their READMEs" isn't a promising start.  We have enough repositories that doing any compound operation that requires many GitHub requests per repo could run into the 5k/hour/account limit.

Most importantly, in the long run I think this will prove unwieldy to manage due to the same problems that call for metadata to begin with. Adding one tag to 100 projects would be 100 commits in 100 different places, instead of one commit in one place.


### Dramatically reduce total number of repositories

For example by aggressive pruning, consolidation, or [architectural](https://twitter.com/monorepi) changes.  This would be a disproportional disruption to the scale of the original problem.  Basic cleanup and archiving are worthwhile in their own right, but are unlikely to reduce the number of repositories to something that can fit in one person's memory.  Over 100 new repositories have been created since the writing of this RFD started.


### Migrate Git hosting to a platform with more features

For example, something with tags or a directory structure.  This again would be disproportionate effort & disruption relative to the problem at hand.

### Other Tools

There are a few other "manage a bunch of git repos" projects, including:
 * [myrepos](https://myrepos.branchable.com/)
 * [mu-repo](https://fabioz.github.io/mu-repo/)
 * [gr](http://mixu.net/gr/)
 * [vcspull](http://vcspull.readthedocs.io/en/latest/)

Most appear focused on running ad-hoc commands on *existing* checkouts, and not describing remotes or adding context with tags.  `vcspull` is closest in spirit (there is a config file!) but is narrowly focused on the checkout & sync cycle of a simple hierarchy.

There are also several ways of taking an existing large repository and working with it as if it were a series of smaller repositories, but that is the opposite of the current problem.


## Questions

Q: Are in-active/dead/archived things listed as such in the manifest, implicit by being ignored, or stuck in their own GitHub team "graveyard"?

Q: Now that [archiving](https://help.github.com/articles/archiving-a-github-repository/) exists as a GitHub, that should be satisfactory as a graveyard.  Manifests do not need to include zombies.

Q: Do we need to handle the private repos at all, since they are not part of the main product offering?

A: The use case that include non-public repositories are unclear.  Bringing together internal and public docs is one likely use case.  It's possible that listing the *existence* of a small number of private repositories in a public manifest would also be satisfactory.

## Resources and other Prior Art

The [triton](https://github.com/joyent/triton/blob/master/docs/developer-guide/repos.md), [triton-dev](https://github.com/joyent/triton-dev), and [manta](https://github.com/joyent/manta) docs have a manually curated list of relevant repositories. `triton` even has a second list in [json](https://github.com/joyent/triton/blob/master/etc/repos.json)

Internal `RELENG` tooling has a `repos.json` with partial coverage.

Some of the doc building tools (ie apidocs) have a [smaller list](https://github.com/joyent/apidocs.joyent.com/blob/master/etc/config.json) of repos to pull from.

## Archiving

GitHub now supports a notion of [archiving](https://help.github.com/articles/archiving-a-github-repository/) old repositories to make them read-only.  That is no new commits, comments, issues, wiki articles, etc. can be created.  Archiving can be reversed by clicking through the same series of steps.

Archiving provides a clear UI banner to humans and is a machine readable field in the API.  Joyent repositories that are only historical artifacts should be archived for both human clarity and so they type of maintenance tooling uses cases described in this RFD can ignore them.

## Appendix

### Example JSON Schema for Option B

#### Schema

```json
{
    "$schema": "http://json-schema.org/draft-04/schema#",
    "type": "object",
    "required": ["remotes", "repositories"],
    "properties": {
        "remotes": {
            "type": "object",
            "additionalProperties": false,
            "patternProperties": {
                ".+": {
                    "$ref": "#/definitions/remote"
                }
            }
        },
        "default": {
            "$ref": "#/definitions/repository"
        },
        "repositories": {
            "type": "object",
            "additionalProperties": false,
            "patternProperties": {
                ".+": {
                    "$ref": "#/definitions/repository"
                }
            }
        }
    },
    "definitions": {
        "remote": {
            "type": "object",
            "required": ["template"],
            "properties": {
                "enable": {"type": "boolean"},
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
        "repository": {
            "type": "object",
            "properties": {
                "labels": {"$ref": "#/definitions/labels"},
                "remotes": {
                    "type": "array",
                    "minItems": 1,
                    "items": { "type": "string" },
                    "uniqueItems": true
                },
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

#### Small Contrived Initial Example


```json
{
    "remotes": {
        "joyent": {
            "enable": true,
            "template": "https://github.com/joyent/{{reponame}}.git"
        },
        "trentm": {
            "enable": true,
            "template": "https://github.com/trentm/{{reponame}}.git"
        }
    },

    "default": {
        "labels": {
            "public": true
        },
        "remotes": ["joyent"]
    },

    "repositories": {
        "rfd": {
            "labels": {
                "meta": true
            },
            "remotes": ["joyent"]
        },
        "triton": {
            "linkFiles": [
                {"src": "README.md", "dest": "README.triton.md"}
            ],
            "labels": {
                "triton": true,
                "meta": true
            }
        },
        "manta": {
            "linkFiles": [
                {"src": "README.md", "dest": "README.manta.md"}
            ],
            "labels": {
                "manta": true,
                "meta": true
            }
        },
        "eng": {
            "linkFiles": [
                {"src": "README.md", "dest": "README.eng.md"}
            ],
            "labels": {
                "meta": true
            }
        },
        "smartos-live": {
            "labels": {
                "os": true
            }
        },
        "illumos-joyent": {
            "labels": {
                "os": true
            }
        },
        "illumos-kvm": {
            "labels": {
                "os": true
            }
        },
        "node-bunyan": {
            "labels": {
                "os": true,
                "lang": "js",
                "lib": true
            },
            "remotes": ["trentm"]
        }
    }
}
```

#### Open Schema Questions

 * Should the schema be versioned?
 * The "labels" are similar to Triton [traits](https://docs.joyent.com/private-cloud/traits) and [Kubernetes](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/).  Is there any tooling benefit from making them identical?
 * Kubernete has a convention of "namespacing" labels with a slash.  Since it is expected that all early use cases are for tools X to be able to do Y, is that worthwhile to adopt instead of prematurely choosing a general name?  Note that `/` and most reasonable namespace characters would complicate being used to group repositories in directories on a local filesystem.
 * How to express express multiple checkout urls (such as GitHub `git` vs `https`)?
 * Merit to the "manifest must be used from a git checkout" requirement as Android's `repo`?
