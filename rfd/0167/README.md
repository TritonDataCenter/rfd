---
authors: Jonathan Perkin <jperkin@joyent.com>
state: predraft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+167%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Jonathan Perkin
-->

# RFD 167 Drop i386 and multiarch Package Sets

SmartOS packages, like SmartOS itself, support both 32-bit (i386) and 64-bit
(x86\_64) userland binaries, despite the kernel always running 64-bit.

All packages were built 32-bit up until 2011, when the first 64-bit package
sets were introduced, allowing users to utilise the full 64-bit address space
and take advantage of the additional x86\_64 instruction set.

In 2012 we introduced a multiarch package set, which is a 32-bit package set
that additionally bundles 64-bit binaries and libraries for specific packages.
This mirrors functionality that SmartOS provides natively through the
`isaexec(3C)` feature and allows users to choose via the `ABI` environment
variable whether to run the 32-bit or 64-bit version, as well as providing
shared libraries for both architectures in order for local applications to
built against either from a single image.

While still potentially useful in certain specific contexts, there are costs
associated with continuing to produce both the i386 and multiarch package
sets, and so the scope of this RFD is to explain why it is now unlikely that
it is worth the costs involved to keep producing these sets, as well as
document other reasons why users should probably move to the 64-bit sets.

## Usage Statistics

Before we look at the specific costs involved, it's useful to get an overview
of how popular each package set is.  Below is a table with the download
statistics for each set from pkgsrc.joyent.com as of 2019-04-08.

| Branch |            x86\_64 |            tools |                i386 |       multiarch |
|-------:|-------------------:|-----------------:|--------------------:|----------------:|
| 2010Qx |                N/A |              N/A |    31,281 (100.00%) |             N/A |
| 2011Qx | 1,185,780 (82.37%) |              N/A | 1,439,523  (17.62%) |             N/A |
| 2012Qx |   542,161 (80.48%) |              N/A |   122,902  (18.24%) |   8,532 (1.26%) |
| 2013Qx | 1,659,722 (80.36%) |              N/A |   203,880   (9.87%) | 201,640 (9.76%) |
| 2014Qx | 4,067,584 (96.04%) |     948  (0.02%) |    98,388   (2.32%) |  68,225 (1.61%) |
| 2015Qx | 1,803,847 (91.09%) |  12,802  (0.64%) |    75,826   (3.82%) |  87,787 (4.43%) |
| 2016Qx |   664,694 (87.15%) |  21,001  (2.75%) |    55,907   (7.33%) |  21,044 (2.75%) |
| 2017Qx |   612,933 (87.16%) |  36,677  (5.21%) |    36,579   (5.20%) |  17,033 (2.42%) |
| 2018Qx |   411,405 (68.01%) | 157,307 (26.00%) |    27,116   (4.48%) |   9,083 (1.50%) |
|  trunk |   152,093 (43.75%) | 195,476 (56.24%) |                 N/A |             N/A |

Some notes:

* Log data for 2010 and earlier is incomplete.  There are also missing logs
  for a few months around January 2013.

* A number of institutions make use of the rsync service available from
  pkgsrc.joyent.com to provide their own local mirrors of the package
  repositories.  Any package downloads from these mirrors will naturally not
  be reflected in these numbers.

* The tools set is a modified x86\_64 package set designed for the SmartOS
  Global Zone, introduced in 2014.

* The 2013Q3 and 2015Q4 multiarch sets were used for SmartOS builds and Triton
  origin images, which may explain why their download stats are higher than
  the norm.

* The trunk sets were introduced in 2018 and users were encouraged to migrate
  to them for most situations rather than having to upgrade between releases
  every quarter.  No i386 or multiarch images were provided, and thus far no
  users have requested them.

## Software Availability

One of the primary reasons why users should migrate to the 64-bit sets is that
upstream software continues to drop support for 32-bit binaries, or indeed has
never supported it at all.  Some examples are:

### Java / OpenJDK

SmartOS 32-bit is only supported up to OpenJDK 7.x.  OpenJDK 8.x onwards
removed all support for illumos 32-bit and is now 64-bit only.  While it would
be technically possible to re-instate 32-bit support, this would be a large
amount of work and result in a large patchset to maintain.

### Go

The Go programming language has only ever supported illumos 64-bit.  Porting
work including low-level assembly would be required to add 32-bit support.

The lack of Go support means many popular user applications such as syncthing,
hugo, influxdb, etc. are also unavailable.

### Rust

The Rust programming language has only ever supported illumos 64-bit.  Rust is
based on LLVM which continues to support 32-bit, so the work required to add
32-bit support to Rust is perhaps easier than Go, but still a reasonable
amount of work nevertheless.

Without support for Rust a number of user applications are also unavailable,
including Firefox.

## Costs

Any discussion around dropping support for something has to consider the costs
involved, otherwise they would be supported indefinitely.  The costs for
supporting package sets falls into 3 broad categories.

### Build Hardware

All package builds are performed on the same hardware, so while there is no
requirement for additional hardware to support each build, any additional
package sets increase the load on the existing hardware.

This primarily then has a direct correlation with the build time for a full
package set (the time required to produce the initial package set, and
therefore how quickly the new set can be released), and any updates (how
quickly we can publish important security fixes).

One important note is that pkgsrc always ensures a full rebuild of updated
packages and all of their dependencies.  This avoids issues where a package
may have subtle changes to its API or ABI that can go undetected with naive
rebuilds of just the package in question, but does mean that, for example, an
update to OpenSSL will result in a large package set rebuild, given the huge
number of packages that directly or indirectly depend upon OpenSSL.

As a rough guide, a full build of all i386, x86\_64, and multiarch package
sets simultaneously takes around 30 hours, whereas just an x86\_64 build takes
around 16 hours.

It is likely that the single x86\_64 build time can be further decreased with
tuning, if it is known that there will be no other builds running
concurrently.  In the past we have achieved full bulk builds in under 3 hours.

### Disk Usage

Disk usage is easy enough to quantify, here are the requirements for the
2018Q4 package sets:

| Package Set | Disk Usage |
|------------:|-----------:|
|        i386 |       29GB |
|   multiarch |       23GB |
|       tools |        3GB |
|     x86\_64 |       33GB |

The disk usage cost is exacted in a number of different places:

* The NFS server used by the bulk build infrastructure.

* The <https://pkgsrc.joyent.com/> servers.

* Any mirrors of <https://pkgsrc.joyent.com/>.

* The package archive at
  <https://us-east.manta.joyent.com/pkgsrc/public/packages/>

While it might be tempting to dismiss disk usage as irrelevant in this era of
multi-terabyte desktop hard drives, these numbers grow quickly when you
account for quarterly releases, and it may not always be possible to
continually request more storage in all the places where it is required.

### Multiarch Patch Maintenance

While support for 32-bit packages requires no changes to the pkgsrc tree, the
story for multiarch is very different.

As a starter, the `git diff --stat`
[statistics](https://github.com/NetBSD/pkgsrc/compare/9f38a44ab229f4110f65d90653d0b28e046dd832...joyent:joyent/feature/multiarch/trunk)
for the multiarch feature tree are:

```
585 files changed, 3828 insertions(+), 940 deletions(-)
```

Touching a large number of files across the pkgsrc tree, and with pkgsrc's
high number of commits, means regular grunt work to merge the changes back in.

Some packages require large changes, for example the patches required to get
python to support multiarch are [quite
invasive](https://github.com/NetBSD/pkgsrc/commit/fa1710908c9fa44fcf607314b07c819edad8e42a#diff-f862a5f68aaa82c12568786f5e6c993f)
and can be difficult to merge every time python is updated.

Running highly modified and complicated patch sets against common software
like Python not only increases the chances of failure, but also introduces
risk.

When multiarch was first proposed it was anticipated that it would be
incorporated into the main pkgsrc tree, as it was a feature in use on other
operating systems of the time such as Linux and macOS.  Over time however
multiarch support across all OS has diminished such that this is now no longer
desirable.

# Proposal

The 2019Q1 release will be the first quarterly to ship only 64-bit package
sets (x86\_64 and tools).  Users who wish to continue using 32-bit packages
may use the 2018Q4 release which is LTS and supported until 2021.

Dropping support for 32-bit packages will free up resources in 3 primary
areas:

* Hardware requirements for bulk build infrastructure, speeding up package
  releases and updates.

* Disk usage across build and mirror sites.

* Engineer costs merging the complicated multiarch patch set and maintaining
  builds, allowing them to spend more time focusing on requested features and
  package additions and updates.
