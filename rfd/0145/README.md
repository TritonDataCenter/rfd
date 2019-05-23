---
authors: Tim Foster <tim.foster@joyent.com>
state: publish
discussion: https://github.com/joyent/rfd/issues?q=RFD+145
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 145 Lullaby 3: Improving the Triton/Manta builds

This RFD describes a series of improvements to the Triton/Manta builds,
with the overall aim to:

- simplify the build
- improve build performance
- reduce barriers to entry for new engineers

In this document, we'll discuss these aims and will describe some work that
will help us achieve them.

Some attributes of the build system that we aspire to are written up in
[this gist](https://gist.github.com/timfoster/8e7cd48bf39dc34922b5815cefde50c6)
which provides more of the motivation behind the work described in this RFD.

## Background and scope

A basic Triton deployment is composed of:

- A platform image forming the contents of the global zone, which runs on
bare metal
- one or more component images, each image being a compressed zfs send-stream
with an associated image manifest, deployed as a SmartOS zone
- a set of software agents, typically SMF services that run in the SmartOS zones
 and/or the global zone

Manta delivers software agents and additional component images on top of a
Triton instance.

Build tools are provided to deploy and assemble Triton and Manta.

The scope of this work is to concentrate on the building and assembly of
Triton and Manta component images and software agents, scripts
to create iso or usb images, scripts to upgrade existing deployments and
tools to aid developers in their daily develop/test/debug cycle. We are
explicitly not addressing the platform image build process yet.

Before this RFD, component images and agents were built using a tool called
[Mountain Gorilla](https://github.com/joyent/mountain-gorilla/blob/master/README.md),
which is effectively a series of build scripts that:

- clones relevant git repositories
- downloads prebuilt dependencies
- builds those repositories
- invokes SDC APIs to create remote VM instances within the Joyent Public Cloud
to construct the image
- uploads the resulting images to Manta
- downloads a copy of the images to the engineer's build machine.

There are several limitations with this approach:

- build speed is dependent on JPC speed/responsiveness
- build metadata is distributed between the component git repositories and MG
itself
- build speed is dependent on network bandwidth of the build machine
- offline builds are impossible

Along with these, we have some missing features in MG and the Triton/Manta
component builds in general:

- no validation that the current build machine is capable of building any given
component
- significant quantity of "background noise" in build logs
- complicated sharing of build script infrastructure

## Proposed improvements

### Improve the sharing of build infrastructure by using eng.git as a submodule

By moving eng.git as a submodule of all Manta/Triton repositories, e.g.

`<component>/eng/`

we establish a place where global build tools and improvements can be made
that will be available to all repositories.

Before this RFC, shared Makefiles were simply copied from eng.git into each
repository's `tools/mk` directory, which allows components the choice of
deciding when to update to new versions, but had the drawback that each
upgrade is a copy/paste job, and could result in build improvements not
propagating across repositories.

By using a submodule instead, repositories still have the choice of upgrading,
as git submodules are locked to a specific commit until upgraded. For those
unfamiliar with git submodules, performing the upgrade of a component to
use the latest changes from eng.git is as simple as:

```
$ git submodule update --remote deps/eng
$ git add deps/eng
```

Developers should then commit changes as usual. Some deps/eng updates may
need to be applied across all repositories that use eng.git as a submodule,
other changes may be performed on an as-needed basis for the specific
repositories that require new eng.git features or bug fixes.

Before this RFD, we were being conservative about which new eng.git code was
used in each component. This RFD proposes we become aggressive about taking
all eng.git changes, at least to the granularity of a single git commit, but
ideally having all components stay current.

We replace uses of shared tools/mk/Makefile.* with deps/eng/tools/mk/Makefile.*
and ensure that the eng submodule is always checked out and present in a
repository using a `./<component>/Makefile` macro definition:

```
REQUIRE_ENG := $(shell git submodule update --init deps/eng)
```

This allows for subsequent `include deps/eng/tools/mk/...` statements
to Just Work.

If developers are modifying files in deps/eng, for example when testing eng.git
changes, then uncommitted files will not be overritten as a result of the
`$(REQUIRE_ENG)` macro, however **any commits made to a local deps/eng
repository would be clobbered**, so either temporarily comment out the
`REQUIRE_ENG` macro, or temporarily point the deps/eng submodule to a
local eng.git clone, taking care to revert that change before committing:

```
$ git config -f .gitmodules --replace-all submodule.deps/eng.url /home/timf/projects/my-eng-clone.git
$ git submodule sync deps/eng
Synchronizing submodule url for 'deps/eng'
$ git submodule update --remote deps/eng
remote: Enumerating objects: 5, done.
remote: Counting objects: 100% (5/5), done.
remote: Compressing objects: 100% (3/3), done.
remote: Total 3 (delta 2), reused 0 (delta 0)
Unpacking objects: 100% (3/3), done.
From /home/timf/projects/my-eng-clone
   d25b8fc..7a03a85  master     -> origin/master
Submodule path 'deps/eng': checked out '7a03a85352a6035b1f098ff41fb7ff112bda052b'
```

Over time, we expect additional common build tools to be added to eng.git,
again, ensuring that components upgrade to versions of eng.git that they're
compatible with.

The alternative of bundling build tools on build machines themselves was
considered, but we feel that tightly coupling the build tool versions to
matching versions of source repositories is less error-prone.

### Stop using Mountain Gorilla

While MG is good in that it provided a somewhat shared build infrastructure,
splitting the build metadata between components makes it more complicated to
determine exactly how an image should be built and makes it cumbersome to
build local changes without first pushing those to a git TRY_BRANCH.

MG's requirement to instantiate remote VMs to perform image assembly is
cumbersome, and imposes a delay on the build.

The ['buildymcbuildface'](https://github.com/joyent/buildymcbuildface)
prototype showed that it is possible to create images directly on the build
machine, so the work covered by this RFD extends that prototype, and
introduces `buildimage`.

Each component includes the metadata required to build it or its dependencies
(eg. software agents) Agent builds can either be downloaded in the style of
the "NODE_PREBUILT_IMAGE" builds, or can be built directly on the build machine,
then cached for use by other repositories.

The rollout of components to the new 'MG-less' model can be staged over time,
with MG builds still being supported and used by Jenkins jobs up to the point
that all components have switched, allowing for developer convenience during
the transition period as each component is converted, but minimal disruption
to our nightly builds.

### Strive towards reproducible builds (start with package-lock.json)

Builds of Triton and Manta components before the work described in this RFD
are not reproducible according to the guidelines established by
[reproducible-builds.org](https://reproducible-builds.org/)

While the motivation behind those guidelines emphasises the security aspect
of reproducible builds, we are more interested in the impact on developer
productivity during debugging and our ability to provide QA testers sometime
assurance that the changes made to a given component are exactly equal to the
sum of the git commits that were made to the Joyent source repositories that
make up a component.

The [Joyent Engineering Guide](https://github.com/joyent/eng/blob/master/docs/index.md#user-content-packagejson-and-git-submodules)
and the draft [RFD 105](https://github.com/joyent/rfd/blob/master/rfd/0105/README.md)
have some guidelines on the use of `package.json`, recommending exact
(semver)[https://docs.npmjs.com/getting-started/semantic-versioning] versioning
at the top-level (i.e. the component's immediate dependencies) for dependencies
not controlled by Joyent. However, that doesn't lock the versions right down
the dependency tree. That is, a dependency of a component's dependency might
specify a semver range such that two successive builds of the same Triton/Manta
component can result in different software being deployed.

Of course, the above has benefits and drawbacks. We will get the latest version
of any node dependencies that have been updated and while those versions may
include critical fixes, they may also introduce critical bugs.

By producing and git-committing a `package-lock.json` file (generated by npm
version 5.1.x and later) we solve the problem above by guaranteeing that,
until the package-lock.json file changes, we always build the same software.

Moving components towards using npm v5.1.x involves upgrading the version
of node that many components use. From experimentation, the earliest node
version in use across Manta/Triton that seems capable of running npm 5.1.0
is node v4.6.1.

A side effect of using a package-lock.json file, is that we may be able to
more effectively cache downloaded npm content and thereby reduce our reliance
on the network, though that is not the primary goal.

As an aid to investigating build reproducibility, during publication, the
build saves the result of `npm ls --json` which would allow us to develop
automation to determine package differences across releases for components
which aren't yet using `package-lock.json` files.

### Validate the build environment

Before this RFD, there was very little build environment validation - the build
checks that an expected version of the platform image is running, and ensures
that a component builds with the version of node it bundles
(see the [sdcnode README](https://download.joyent.com/pub/build/sdcnode/README.html))
but does little else in the way of validation before the build.

In particular, we always assume that we're running on a build machine with the
correct base image/pkgsrc version, that the correct version of build tools
(e.g. gcc) are in our path and that we're running as a user with permissions to
perform the required build operations.

Diagnosing build failures due to having a mismatched build machine or toxic
build environment is not straight-forward.

One route around this problem, would be to better publicise the existence of the
(slightly misleadingly named) "Jenkins agent images", which are SmartOS images
that contain all the build tools needed to build a given component. Jenkins
builds use a labelling mechanism triggered by the value of $NODE_PREBUILT_IMAGE
to lookup the correct base image version and map that to a Jenkins agent which
is capable of building the component.

Another route, would be to more rigorously define the build environment used
for a given component by publishing a pkgsrc package which has dependencies
on the tools required to build. SmartOS build images could be easily distributed
with those packages pre-installed and Makefiles could verify a given version of
that package is present before proceeding with the build.

Makefiles should hardcode paths to the tools being invoked, rather than
relying on discovering the correct tool in $PATH wherever possible.

We should sanitise the shell environment before the build is run, and report
errors when a build machine appears incapable of building a given component.

### Avoid building as 'root'

Building as root is error-prone as it is difficult to spot Makefile errors
that result in the build modifying the build machine.

When we inadvertently modify a build machine as root, we may break subsequent
builds performed on the same system, reducing the chances of getting build
reproducibility.

Instead, components which require privileged operations on build machines should
use RBAC configurations (possibly delivered by the pkgsrc packages mentioned
in the previous section) which are responsible for doing the setup/tear down
of any privileged resources.

To address this problem, and the one concerning build environment cleanliness,
we might also consider shipping a "builder" user on the equivalent of the
"Jenkins agent image" (or whatever we name it), which is configured with the
correct environment.
This may introduce an inconvenience for developers used to building as
their own user however, perhaps such that developers would ignore this facility.

If we do ship a 'builder' user, we should have a mechanism to inherit certain
important attributes from a developer's own environment (such as ssh keys)

### Current status ###

At the time of writing, the Lullaby 3 project is considered "complete".

The project delivery was staggered over four phases, with TOOLS-2043
being the Jira ticket that tracked the overall project progress.

The flag day mails for these phases were:

phase 1: build framework and a few components converted to use it
  * https://gist.github.com/timfoster/ebd30a91087ca2c09b2d68a03ecbaba4

phase 2: Triton components converted to build framework
  * https://gist.github.com/timfoster/1dc9fb5d8e2fd80e1c94e7987851b42d

phase 3: Manta components converted to build framework
  * https://gist.github.com/timfoster/82802c2ab95b5af5d6bc76127d8059f3

phase 4: smartos-live, sdc-headnode and firmware-tools converted to build framework
  * https://gist.github.com/timfoster/fb31254fd726af217397da40b622c637

While we have not yet reached build reproducibility across all projects,
it should continue to be a goal, and new projects should have reproducible
builds by default.

We are updating the Manta and Triton developer documentation to reflect
the build changes that were delivered (MANTA-4132 and TRITON-1376).
