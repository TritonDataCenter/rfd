---
authors: Chris Burroughs <chris.burroughs@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+165%22
---

# RFD 165 Security Updates for Triton/Manta Core Images

The RFD proposes changes to how updates are handled for the origin images introduced in [RFD 46 Origin images for Triton and Manta core images](../../0046/README.md)


## Current Status

[triton-origin-image](https://github.com/joyent/triton-origin-image) are used by many -- but not all -- components.  The most popular is tied to the 2015Q4 pkgsrc branch which recently left LTS.  To use it one places something like:

```
BASE_IMAGE_UUID = 04a48d7d-6bb5-4e83-8c3b-e60a99e0f48f
```

in a component's Makefile.  In this particular case that UUID corresponds to `triton-origin-multiarch-15.4.1@1.0.1` which includes:

```
        "pkgsrc": [
            "coreutils-8.23nb2",
            "curl-7.51.0",
            "gsed-4.2.2nb4",
            "patch-2.7.5",
            "sudo-1.8.15"
        ],
```

Components may also install additional package.  Origin images have succeeded in making most of these per-component lists short.


## The Problem

There is no mechanism to apply security updates to the origin images.  We neither `pkgin up` nor `pkgin full-upgrade` at any point in the process.  There also isn't any process to evaluate how many outstanding vulneratbilites are known to (that is `pkg_admin fetch-pkg-vulnerabilities && pkg_admin audit`).

As of this writing `triton-origin-multiarch-15.4.1@1.0.1` has 15 outstanding security updates.  (Out of 41 total packages, origin images are intentionally slim.)

Most Triton/Manta components are currently nodejs services with statically linked openssl and lack an externally facing network.  The risk from -- for example -- `coreutils` or `gsed` CVEs is likely low.  However, the risk isn't zero and some components do other externally facing network services (where any openssl update would be of particular relevance).

Despite the risk likely being *low*, confidently evaluating that risk is *high* effort and requires a tremendous amount of context.  One would have to be familiar enough with a package to evaluate the CVE, and then also familiar enough with every single component (over 75 circa 2019) to understand how that package is used.  Leaving non-exploitable known vulnerabilities open can be even more expensive than fixing them.


## Constraints

 * The basic premise of origin images is taken as a given.
 * Speeding up the process of *deploying* updated images is worthy, but out of scope.

## Approaches

### Make it every components problem (strawman)

Have a policy that every component owner is responsible for updating these packages.  Either by evaluating every vulnerability or by doing a full upgrade as part of the component's build.

This would significantly lessen the space savings of origin-images while duplicating most of the evaluation work.  It would also somewhat trend the component builds away from reproducible.  As a practical matter, while circa 2019 Joyent has domain experts there are generally not dedicated owners of individual components.


### update during origin image creation

The origin-image creation process could be changed to:
 * run `pkgin update`
 * run `pkgin full-upgrade`
 * unpin the version of packages installed.  That is use `curl` not `curl-7.51.0`
 
This would apply to new images (the first being 2018Q4).  This would keep us as up to date (at origin creation time) as the underlying pkgsrc branch.  We could then periodically issue new origin images that incorporate the latest changes.  While origin image builds would then become dependent on the build-time, downstream component builds would not necessarily become less reproducible (because they would need to choose to update `BASE_IMAGE_UUID`).

This does exacerbate a slight complication for some downstream components.  Normally if there was a version `1.0.5` with a known security vulnerability, and a `1.0.6` became available with a fix, then `1.0.5` would be removed.  To support the practice of installing obsolete vulnerable versions, we jump through hoops both on the image build side (by using `pkg_add` directly) and the pkgsrc side (by keeping the obsolete package).  This incidentally works today because we never `update`, but would become more likely fail to install when switching to an updated image.

## Related Questions

### origin-image version string

Currently the image version of the origin-image is yoinked out of the `package.json` field in [triton-origin-image](https://github.com/joyent/triton-origin-image).  As of this writing there are 5 `triton-origin-multiarch-15.4.1@1.0.1` images on updates.joyent.com.  To push out updated images with non-conflicting versions we would need a new scheme.

For example `x.y.z` where `x.y` is from `package.json` and `z` is a timestamp.


### How often to update?

On a fixed cadence?  Occasionally? Make a Jenkins job to email whenever a new update is available and talk about it then?


### Is it feasible to keep pkg audit clean?

`pkg_admin fetch-pkg-vulnerabilities && pkg_admin audit` reports *all* known vulnerabilities not just all vulnerabilities for which an update is available.  Is it feasible to keep this list near zero?
