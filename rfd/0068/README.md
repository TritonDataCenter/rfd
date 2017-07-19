---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 68 Triton versioning

This document will attempt to codify how we version things in Triton components.
This covers things like the following:

- repo versioning (package.json, CHANGES.md): What should the "version" field in
  a node.js project's package.json file be and how should it change? What are
  requirements for a changelog section (commonly "CHANGES.md") for a new
  version?
- image versioning: What should the "version" field in a Triton component's
  image manifest be? How is the "latest" version of a Triton image from
  updates.joyent.com determined?
- API versioning: How should API versioning work for Triton restify-based
  services?

The scope of "Triton components" here are the components that are used for
Triton DataCenter standup, excluding the platform (see the "Platform Versioning"
section below) and excluding Manta components. I believe that Manta components
could largely follow the same plan, but for starters this RFD doesn't presume
to dictate for them. Note that there are a number of components that are
used by both Triton and Manta (manatee, binder, mahi, etc.), so it'll come up
eventually.


## Current Status

This doc is still in predraft. The versioning handling in Triton (and Manta)
repos and images and API has some common behaviour, but rules for such aren't
really codified anywhere I know.


## Platform Versioning

The "platform" (basically SmartOS) has its own versioning story that isn't going
to change. It is documented here to get it out of the way when discussing how
versioning should work for *other* components of Triton.

The platform version is **a timestamp of the form `YYYYMMDDTHHMMSSZ`**, e.g.:
"20161114T172628Z". It is the UTC time roughly at which the platform build
is started. The platform image (a.k.a. PI) that are added to and distributed
from updates.joyent.com are have a **"version" field that is
`$branch-$timestamp`**, e.g. "master-20161114T172628Z" or
"release-20161110-20161110T013016Z".

Some examples of where the platform version shows up:

```
$ updates-imgadm -C release list name=platform
UUID                                  NAME      VERSION                            FLAGS  OS     PUBLISHED
04530488-825d-11e5-a45c-d3103700b110  platform  master-20130506T233003Z            -      other  2013-05-06T23:30:03Z
...
7e4b683a-cd94-4a10-a134-b30ee76c68ec  platform  release-20161027-20161101T004332Z  -      other  2016-11-01T02:49:34Z
f4ddd924-959b-480f-b0b7-f0f277396694  platform  release-20161110-20161110T013016Z  -      other  2016-11-10T03:41:23Z


[root@headnode (coal) ~]# uname -v
joyent_20161114T141011Z


[root@headnode (nightly-1) ~]# sdc-cnapi /servers | json -Ha uuid current_platform boot_platform
00000000-0000-0000-0000-002590918ccc 20161113T001645Z 20161113T001645Z
44454c4c-5700-1047-804d-b3c04f585131 20141030T081701Z 20141030T081701Z
d5687d93-367b-0010-a9ab-047d7bbb75d9 20161113T001645Z 20161113T001645Z


[root@headnode (nightly-1) ~]# sdcadm platform list
VERSION           CURRENT_PLATFORM  BOOT_PLATFORM  LATEST  DEFAULT
20161113T001645Z  2                 2              true    true
20141030T081701Z  1                 1              false   false
```

The platform is built from a number of repos, so assigning a git sha as an
identifier for a build isn't practical. The constituent top-level repos and
their revision is included in the "/etc/release" file, e.g.:

```
[root@headnode (nightly-1) ~]# cat /etc/release
                       SmartOS 20161113T001645Z x86_64
              Copyright 2010 Sun Microsystems, Inc.  All Rights Reserved.
              Copyright 2010-2012 Joyent, Inc.  All Rights Reserved.
                        Use is subject to license terms.

   Built with the following components:

[
        { "repo": "smartos-live", "branch": "master", "rev": "2cbbbe4f9874864b6995423749c3aa7852df0c39", "commit_date": "1478867126", "url": "git@github.com:joyent/smartos-live.git" }
        , { "repo": "illumos-joyent", "branch": "master", "rev": "ed2e7e1643fd773befc5898dcb2d6bd83b445030", "commit_date": "1478995936", "url": "/root/data/jenkins/workspace/platform/MG/build/illumos-joyent" }
        , { "repo": "illumos-extra", "branch": "master", "rev": "af1592e701d29f3224e5f120b19eeaca1e49f22e", "commit_date": "1478889667", "url": "/root/data/jenkins/workspace/platform/MG/build/illumos-extra" }
        , { "repo": "kvm", "branch": "master", "rev": "a8befd521c7e673749c64f118585814009fe4b73", "commit_date": "1450081968", "url": "/root/data/jenkins/workspace/platform/MG/build/illumos-kvm" }
        , { "repo": "kvm-cmd", "branch": "master", "rev": "70a3b9ac0fffc05cbe541164c097f51040addc8c", "commit_date": "1470436658", "url": "/root/data/jenkins/workspace/platform/MG/build/illumos-kvm-cmd" }
        , { "repo": "mdata-client", "branch": "master", "rev": "58158c44603a3316928975deccc5d10864832770", "commit_date": "1429917227", "url": "/root/data/jenkins/workspace/platform/MG/build/mdata-client" }
        , { "repo": "ur-agent", "branch": "master", "rev": "497236faf4bcb657425d3979e316cc204c00f36a", "commit_date": "1470438392", "url": "/root/data/jenkins/workspace/platform/MG/build/sdc-ur-agent" }
]
```

## Repo Versioning

TODO: this will be done later


## Image Versioning

A subset of Triton-related repos are "top-level" repos (e.g. sdc-vmapi.git,
triton-cns.git, binder.git) that we could call a "component" and for which an
image (e.g. vmapi, cns, binder) is built and added to updates.joyent.com. These
are the building blocks for installable and upgradeable components of Triton
(and Manta). Each such build is an "image" in the [IMGAPI
sense](https://updates.joyent.com/docs/#image-manifests) and has a "version"
field. The question here is what should be the format of that image "version".

### Plan

*(Note this isn't an agreed plan. The "Image Versioning" section is still
very much in discussion.)*

Triton images should move to `X.Y.Z-BUILDSTAMP` for the version string format.
The "BUILDSTAMP" is meant for build information and **not** for version
precedence. Version precendence for builds is determined by:

1. using the "X.Y.Z" part of the version (i.e. the pre-release version must
   be removed); and
2. precedence for builds with the same "X.Y.Z" version is based on timestamp
   (specifically the image `published_at` field).

**Warning:** There are subtleties in attempting to use semver tooling for
comparing versions with the "-BUILDSTAMP" pre-release version part.

    > semver.satisfies('1.0.0-master-20161114T190034Z-g60b9881', '>=1.0.0')
    false
    > semver.satisfies('2.0.0-master-20161114T190034Z-g60b9881', '>=1.0.0')
    false

Read below for details.


### Goals

- Have versions that are valid semver versions. This allows using available
  tooling (i.e. the npm "semver" module) for some version parsing, validation,
  comparison (modulo the "drop the pre-release version for comparison" caveat).
  Also, the node world is pretty much a semver world already, so as long as it
  doesn't get in the way, sticking within semver's definition helps.
- Include the "X.Y.Z" version manually specified from a field in the repo
  (typically the "version" field in package.json). This allows the developer
  to explicitly control semver versioning to give compatibility and feature
  hints. These versions can be used for facilities like the hoped-for
  sdcadm dependency resolution (aka "sdcDependencies", see
  <https://mo.joyent.com/docs/engdoc/master/roadmap/projects/sdc-update.html#someday-m9-dependency-handling>).
- Include details from the buildstamp (branch, build time, git sha) because in
  the common case where the "X.Y.Z" is not incremented for all changes, it is
  very useful to be able to identify the exact build of an installed component.
- Do not egregiously break already deployed tooling.
- Do *not* use the "buildstamp" for version precendence. Our buildstamp is
  `$branch-$buildtime-g$gitsha`. The "branch" should not be used as a sortable
  key. While one does get *lucky* with our "release-YYYYMMDD" branch versions,
  there is nothing to say that a "master" branch build should be sorted
  lower than a "release-" branch build. Likewise for feature branch builds.


### pre-release versions or build metadata

Some background on semver. There are two kinds of things that can go after the
"X.Y.Z" to give more build info: (a) a [pre-release
version](http://semver.org/#spec-item-9) (`1.2.3-$this`) and (b) [build
metadata](http://semver.org/#spec-item-10) (`1.2.3+$this`). From the spec:

```
9.  A pre-release version MAY be denoted by appending a hyphen and a series of
    dot separated identifiers immediately following the patch version.
    Identifiers MUST comprise only ASCII alphanumerics and hyphen [0-9A-Za-z-].
    Identifiers MUST NOT be empty. Numeric identifiers MUST NOT include leading
    zeroes. Pre-release versions have a lower precedence than the associated
    normal version. A pre-release version indicates that the version is unstable
    and might not satisfy the intended compatibility requirements as denoted by
    its associated normal version. Examples: 1.0.0-alpha, 1.0.0-alpha.1,
    1.0.0-0.3.7, 1.0.0-x.7.z.92.

10. Build metadata MAY be denoted by appending a plus sign and a series of dot
    separated identifiers immediately following the patch or pre-release
    version. Identifiers MUST comprise only ASCII alphanumerics and hyphen
    [0-9A-Za-z-]. Identifiers MUST NOT be empty. Build metadata SHOULD be
    ignored when determining version precedence. Thus two versions that differ
    only in the build metadata, have the same precedence. Examples:
    1.0.0-alpha+001, 1.0.0+20130313144700, 1.0.0-beta+exp.sha.5114f85.
```

I'd expect most are somewhat familiar with the former, but fewer with the
latter. There are a couple surprises with using pre-release versions that I see:

- For those with just a casual understanding of semver, it might be surprsing
  that "-$this" is a *pre*-release version, i.e. that this is true:

        > semver.satisfies('1.0.0-master-20161114T190034Z-g60b9881', '>=1.0.0')
        false

  FWIW, this was hit with TOOLS-1610.

- For the even less casual user, that this is true might be surprising:

        > semver.satisfies('2.0.0-master-20161114T190034Z-g60b9881', '>=1.0.0')
        false

  I.e. that a "pre-release" version means that it is a lower version even if
  the "X.Y.Z" part is larger than the given range.


*Downsides to using build metadata*, e.g.
`2.0.0+master-20161114T190034Z-g60b9881`:

- Casual users might expect that suffix to contribute to version precendence.
  That's true for pre-release versions as well, where the actual behaviour can,
  IMO be even more surprising. So, in this regard build metadata is better
  than pre-release versions.
- Current image manifest validation (in node-imgmanifest.git) doesn't allow '+'
  in version fields, and because this is part of `imgadm` in the platform we'd
  need to get it in imgadm *and* get the Triton-supported `min_platform` past
  that version. Wanh wanh. This kills using build metadata for now.
  FWIW, <https://devhub.joyent.com/jira/browse/OS-5798> will be allowing '+'.


### build time or published_at

"Build time" or image "published\_at"? A timestamp is used for secondary
sorting, but which one? IMGAPI tooling like `updates-imgadm` uses
`published_at`, but the buildtime encoded in the buildstamp is more tied to the
built image. The path of least resistance is to use `published_at` because
it is reliably defined for all images, current behaviour is using `published_at`
(e.g. in sdcadm's selection of the latest available image), and our current
build process publishes to updates.joyent.com as part of the build, so the
two are well related.


### Alternatives

- `X.Y.Z+$buildstamp` (e.g. `0.2.1+master-20160527T190021Z-gd6f0708`).
  In semver language that "+..." suffix is called [build
  metadata](http://semver.org/#spec-item-10). It does *not* contribute to version
  precedence. Given that we don't *want* it accidentally used for version
  precendence (`published_at` is used instead, see above), this would work
  well for us.

  *However*, [current image manifest validation does not allow '+' in the
  version](https://github.com/joyent/node-imgmanifest/blob/master/lib/imgmanifest.js#L32).
  That is very unfortunate. I intend to change this so '+' is allow in the
  future. However, this is in 'imgadm' in the platform, so until either (a) the
  Triton supported `min_platform` is one that includes the imgadm allowing '+',
  or (b) until Triton/SmartOS supports independently updating 'imgadm', then we
  can't have Triton's IMGAPI allowing import of images with '+' in the version.

  This is my favourite option and would have been the suggested plan except for
  this issue.

- New idea: change the `$buildstamp` to be `$buildtime-$branch-$gitsha` so
  that it is sortable for build time. Then `X.Y.Z-$buildstamp` would roughly
  sort appropriately. We still have the `semver.satisfies` surprises to watch
  out for.

- XXX chris' idea

- XXX dap's feedback

- `X.Y.Z` (e.g. "1.2.3"), no buildstamp, surface the build info in tooling.
  Perhaps tooling like `sdcadm insts` and the "SDC Agents" key in sysinfo
  (used by CNAPI to expose the version of agents installed on a CN) could be
  extended to show the build info. I don't know if other tooling out there
  would struggle for a while if, say, vmapi versions changed from
  "master-20160527T190021Z-gd6f0708" to "1.2.3", and *stayed* at "1.2.3" for
  sometime because either (a) there weren't any VMAPI changes, or (b) the
  package.json version wasn't bumped for a change.

  JoshW mentions that he really doesn't like have two separate (and differing)
  builds with the same "version". Fair. I agree that sucks. FWIW, it breaks
  this semver rule: <http://semver.org/#spec-item-3>.

- `X.Y.Z` (e.g. "1.2.3"), no buildstamp, bump ver for all changes.
  One *could* require that versions are bumped for all changes, but I
  think that would be difficult and perhaps burdensome to require of all
  changes to all our top-level repos.

- `X.Y.$buildtime` (e.g. `2.1.20140925042127`). This *would* give immediate
  semver sorting for the semver version (ignoring patch-level) plus buildtime.
  However it is subtle and gross (dropping the patch-level and not matching
  the package.json version). It also doesn't include the helpful branch and
  git sha.

  JoshW prefers this to any alternative that doesn't include any build info
  to avoid the issue of multiple differing images with the same version value.

- `$buildstamp` (e.g. "master-20160527T190021Z-gd6f0708"). This is the current
  format for most zone images (vmapi, imgapi, etc.). It defeats one of the goals
  of having meaningful semver "X.Y.Z" semantics for (a) succinct reading of
  version compatibility and (b) possible future usage of those semver versions
  for inter-component version dependencies handled by 'sdcadm'.


### Current image version formats

At the time of writing (14 Nov 2016) the version formats in play are as follows.

```
[root@headnode (nightly-1) ~]# updates-imgadm list --latest -o name,version -s name
NAME                       VERSION
```

Origin images are those from images.joyent.com released by the Joyent images
team (or a "sdc-"-prefixed copy of them). Their versioning is out of scope
for this document:

```
base                       13.3.1
multiarch                  13.3.1
sdc-base                   14.2.0
sdc-base-multiarch-lts     14.4.0
sdc-base64                 13.3.1
sdc-minimal-multiarch-lts  15.4.1
sdc-multiarch              13.3.1
sdc-smartos                1.6.3
smartos                    1.6.3
```

Many agents use a `X.Y.Z` version:

```
agents_core                2.1.0
amon-agent                 1.0.1
amon-relay                 1.0.1
cn-agent                   1.5.3
config-agent               1.5.0
firewaller                 1.3.2
gz-tools                   3.0.0
hagfish-watcher            1.0.0
marlin-agent               0.1.0
net-agent                  1.3.0
vm-agent                   1.5.0
```

Cloud analytics agents have a style of their own, an old attempt to provide
more than the `X.Y.Z` format typical of agents:

```
cabase                     1.0.3vmaster-20161014T142648Z-g360442e
cainstsvc                  0.0.3vmaster-20161014T142648Z-g360442e
```

The (large) Manta compute image has its own versioning scheme that is
(currently, at least) out of scope for this RFD:

```
manta-marlin               master/16.1.0
manta-marlin-64            14.4.2
```

Most components use the
[MG](https://github.com/joyent/mountain-gorilla/blob/master/docs/index.md#versioning)
dictated buildstamp **$branch-$timestamp-g$gitsha** format:

```
adminui                    master-20161110T190717Z-ga3cd71d
amon                       master-20160825T233127Z-gd1fadaa
amonredis                  master-20160825T234251Z-gc27efa7
assets                     master-20160825T234052Z-gb8b8887
ca                         master-20161014T142648Z-g360442e
cloudapi                   master-20161110T182837Z-gd9fcfb6
cnapi                      master-20161114T193416Z-gba575c6
cns                        master-20161025T160818Z-g49a0a7a
dapi                       master-20140424T150134Z-g1016d29
dhcpd                      master-20160825T234250Z-ge269045
docker                     master-20161110T004141Z-ga7aed3c
fwapi                      master-20161028T024800Z-g25c312f
hostvolume                 master-20160720T214815Z-g2462e08
imgapi                     master-20161031T204847Z-g524f363
keyapi                     master-20131023T155010Z-g29f1667
manta-authcache            master-20161010T202610Z-g3b91a33
manta-deployment           master-20161028T155156Z-gf6518de
manta-electric-moray       master-20161028T234913Z-g73ea511
manta-jobpuller            master-20161013T220801Z-g3970e62
manta-jobsupervisor        master-20161114T185125Z-g1fadac2
manta-loadbalancer         master-20161003T221505Z-g0c8fa2c
manta-madtom               master-20161013T220756Z-g86ab6c4
manta-manatee              master-20140228T004419Z-gcd3d25b
manta-marlin-dashboard     master-20160902T182847Z-g84c6cdd
manta-medusa               master-20161014T230434Z-ga2ee117
manta-moray                master-20161028T234229Z-gc216899
manta-nameservice          master-20161029T011844Z-g0f325f9
manta-ops                  master-20161013T220731Z-gc429d2c
manta-postgres             master-20160929T013240Z-g97252b9
manta-propeller            master-20160902T182711Z-g4451811
manta-storage              master-20161110T004936Z-g69aa058
manta-test-postgres        master-20140307T201313Z-g916c75a
manta-webapi               master-20161109T003201Z-g599e020
manta-workflow             master-20140417T190835Z-g71571bb
mockcloud                  master-20161018T175200Z-g1b67a4f
mockcn                     master-20150825T183647Z-gb9411fb
moray                      master-20140924T072241Z-g132fa8b
napi                       master-20161027T183531Z-g5efaf42
nat                        master-20160720T035404Z-ge997023
nfsserver                  master-20160513T193027Z-g5c46a06
papi                       master-20161027T235318Z-gf806e5a
portolan                   master-20161011T214759Z-ga06a34d
rabbitmq                   master-20160825T235611Z-gb1ad38d
redis                      master-20160825T235607Z-g0d6e5b9
sapi                       master-20161007T000942Z-g30045af
sdc                        master-20161111T024905Z-g7ec7223
sdc-postgres               master-20161017T210701Z-g5c63e46
sdc-zookeeper              master-20150417T191251Z-g01e2c98
ufds                       master-20161110T182823Z-g3ff5a93
usageapi                   master-20140828T232034Z-gc8e5604
vmapi                      master-20161028T182616Z-gfd3a8db
volapi                     master-20161013T054420Z-gc6de6ed
workflow                   master-20161007T000810Z-gd7b9d2b
```

And some components have moved to a trial/planned new format that includes
both the `X.Y.Z` and the buildstamp:

```
agentsshar                 1.0.0-master-20161114T190034Z-g60b9881
dockerlogger               1.0.0-master-20160608T082632Z-g3abcf86
sdcadm                     1.13.0-master-20161114T200206Z-gae60b7b
smartlogin                 0.2.1-master-20160527T190021Z-gd6f0708
```

Obsolete or unknown images:

```
heartbeater                2.1.0
provisioner                2.4.0
marlin                     0.1.0       ??? I think this is obsolete
```



## API Versioning

TODO: This will be done later.
