---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 46 Origin images for Triton and Manta core images

An important unit of Triton and Manta are the core images for the
services/components, e.g. VMAPI, IMGAPI, manatee, Manta's webapi (aka muskie).
These images are incremental images based on an "origin" image. For example, at
the time of writing the Triton VMAPI image (name "vmapi") is based on image
fd2cc906-8938-11e3-beab-4359c665ac99 (sdc-smartos@1.6.3) which is a private
copy of image 01b2c898-945f-11e1-a523-af1afbe22822 (smartos@1.6.3, now
deprecated).

This RFD discusses these origin images: what they are; how are they chosen,
maintained, built, and distributed. Also, besides documenting the origin
images, this RFD will cover work to modernize the current set in use
by Triton and Manta.


## The problem

Our origin images are woefully out of date. Most core images are based on
sdc-smartos@1.6.3, which harks back to May 2012 and is deprecated for
customers. This ties us to very old pkgsrc which, besides bitrot, can
make coping with updates for security issues more difficult.


## Modernization 2016

### tl;dr

- **Q1:** "-multiarch" for all?
  **A1:** Yup, for now using "-multiarch" sounds sufficient. May add "-64"
  later if needed by any core service.
- **Q2:** Start with "base-*" or "minimal-*"?
  **A2:** "minimal-*", plus a subset of the packages that go into "base". See
  below.
- **Q3:** Use only "-lts" images?
  **A3:** Definitely.
- **Q4:** Still need sdcnode builds for each image?
  **A4:** I think so, but not sure. See below.

### Discussions

TODO: summarize the discussion we had.

The full jabber discussion was here:
https://jabber.joyent.com/logs/mib@conference.joyent.com/2016/07/05.html#21:33:08.388365

### Open Questions

#### Q2: Which packages beyond minimal to include?

The set of packages in base, but not minimal is:
https://github.com/joyent/imagetools/blob/3e45aeb713b794d3a5584ae39f5514aec2c81a56/install-base#L88-L102
I gathered some numbers for incremental image sizes, adding each of those
packages in turn. Some of them share deps so the numbers aren't totally clear.

```
$ triton img ls name=sizetest -o version,size -H | (echo "PACKAGE CUMULATIVE_SIZE SIZE_DIFF"; lastsize=0; while read version size; do echo "$version $size $(( $size - $lastsize ))"; lastsize=$size; done) | column -t
PACKAGE    CUMULATIVE_SIZE  SIZE_DIFF
coreutils  20591743         20591743
curl       136016275        115424532
diffutils  136961800        945525
findutils  138409629        1447829
gawk       146348562        7938933
grep       146855082        506520
gsed       147217632        362550
gtar-base  148646573        1428941
less       152481819        3835246
nodejs     281483862        129002043
patch      281734663        250801
postfix    285383559        3648896
rsyslog    288617604        3234045
sudo       290271427        1653823
wget       291704397        1432970
```

Excluding curl (have it in the platform) and nodejs (each service will
select its own node version, possibly an sdcnode build):

```
$ alias=sizetest1; triton img ls name=$alias -o version,size -H | (echo "PACKAGE CUMULATIVE_SIZE SIZE_DIFF"; lastsize=0;         while read version size; do             echo "$version $size $(( $size - $lastsize ))";             lastsize=$size; done)     | column -t
PACKAGE    CUMULATIVE_SIZE  SIZE_DIFF
coreutils  20517606         20517606
diffutils  22558068         2040462
findutils  24110657         1552589
gawk       32065420         7954763
grep       32596931         531511
gsed       32952789         355858
gtar-base  34373283         1420494
less       38302734         3929451
patch      38551087         248353
postfix    146349778        107798691
rsyslog    149613390        3263612
sudo       157323592        7710202
wget       159390060        2066468
```

IOW postfix has some of the same (large) deps that curl had.

Criteria for chosing images:
- Don't egregiously break current core image usage. E.g. excluing gsed would
  break at least a few core images' boot scripts.
- Size of the USB key. The dominant space usage on the USB key is the
  platform(s) and all the images. Fewer origin images helps. Less duplication
  in each incremental image helps. I.e., if more than one image would use
  postfix, it probably is a space savings to include postfix in the origin
  image.
- A vague desire to "keep it light", i.e. don't include stuff that typically
  shouldn't be needed by core images.

A discussion of each contender package for our "sdc-minimal-multiarch" origin
image:

- coreutils: Include it. Suspect many core image scripts depend on these tools.
- curl: Exclude it. It is large and hopefully the GZ one should suffice.
- diffutils: ???
- findutils: ???
- gawk: TODO: I wonder if core images need this. Would it be hard to tell?
  Does it install as `awk`?
- grep: Might be hard to tell if it is used. I assume this is more featureful
  than the GZ grep.
- gsed: At least a couple core zones' setup scripts use `gsed`.
- gtar: Exclude it. The GZ gtar should suffice.
- less: Is the GZ less sufficient?
- nodejs: Exclude it. Services will choose their own node.js version.
- patch: Small and useful. I'd advocate keeping this. I've used it in the field.
- postfix: I believe amon-master is using postfix. If that is the only one
  then perhaps exclude postfix.
- rsyslog: I believe some Manta zones are using rsyslog? Or they were at one
  time.
- sudo: usage in some core images, e.g. sdc-manatee.git, muppet.git
- wget: Just use the GZ one?


### Q4: Still need sdcnode builds for each image?

Currently we do "sdcnode" builds (see https://github.com/joyent/sdcnode) for
all origin images and for a number of versions. Initially this was to save
build time for each image (every build of, say, vmapi used to rebuilt node from
source), to allow floating patches, and custom configure flags (relevant for
GZ-targetted builds).

The question is whether for new origin images we need sdcnode builds or can
used the 'nodejs' packages in pkgsrc? Some questions there:

- Does pkgsrc keep nodejs-X.Y.Z around when Z is *not* the latest patch
  release? If not, then I think we'd still want sdcnode so that a core image
  need not track the latest patch release on pkgsrc's schedule.
- One recent case of floating a patch is for ECDH support for 0.10 -- currently
  being used by sdc-docker.
- If using pkgsrc, can we react quickly enough with new node builds for
  security issues?


### Plan

- answer open Qs
- build a starter 'triton-origin-multiarch' image (we can debate the name)
- NAPI ticket on Cody to move NAPI to using this base image, if he is
  still game
- roll out to other components


## State as of July 2016

TODO: trent to finish doc'ing this, highlights:

- Origin images defined in mountain-gorilla.git:targets.json.in's `image_uuid`
  fields.


