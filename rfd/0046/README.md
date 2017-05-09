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


## Current Status

(As of July 2016) This RFD is still being finalized. Tickets will be created
to implement the plan described in the "Modernization 2016" section.


## The problem

Our origin images are woefully out of date. Most core images are based on
sdc-smartos@1.6.3, which harks back to May 2012 and is deprecated for
customers. This ties us to very old pkgsrc which, besides bitrot, can
make coping with updates for security issues more difficult.


## Modernization 2016

### tl;dr

- **Q1:** "-multiarch" for all?
  **A1:** Yup, for now using "-multiarch" sounds sufficient. May add "-64"
  later if needed by any core service. See "Q1" section below.
- **Q2:** Start with "base-*" or "minimal-*"?
  **A2:** "minimal-*", plus a subset of the packages that go into "base".
  See "Q2" section below.
- **Q3:** Use only "-lts" images?
  **A3:** Definitely. See "Considerations" section below.
- **Q4:** Still need sdcnode builds for each image?
  **A4:** Yes. See "Q4" section below.


### Considerations

The following are factors to consider when selecting the origin for core
Triton and Manta images:

- Triton minimum platform: To balance backward compatibility and modernization
  there is a set minimum platform version on which Triton and Manta software is
  guaranteed to work. Before November 2015 the minimum platform was
  **20130506T233003Z**. After November 2015 the minimum platform was updated
  to **20141030T081701Z** -- which is good because that is the `min_platform`
  for "base" and "minimal" images (to which we want to move) for some time:

    ```
    $ joyent-imgadm list name=~-lts -j | json -Ha name version "requirements.min_platform['7.0']" -o jsony-0
    minimal-32-lts 14.4.0 20141030T081701Z
    minimal-64-lts 14.4.0 20141030T081701Z
    minimal-multiarch-lts 14.4.0 20141030T081701Z
    base-32-lts 14.4.0 20141030T081701Z
    base-64-lts 14.4.0 20141030T081701Z
    base-multiarch-lts 14.4.0 20141030T081701Z
    minimal-32-lts 14.4.1 20141030T081701Z
    minimal-64-lts 14.4.1 20141030T081701Z
    minimal-multiarch-lts 14.4.1 20141030T081701Z
    base-32-lts 14.4.1 20141030T081701Z
    base-64-lts 14.4.1 20141030T081701Z
    base-multiarch-lts 14.4.1 20141030T081701Z
    minimal-32-lts 14.4.2 20141030T081701Z
    minimal-64-lts 14.4.2 20141030T081701Z
    minimal-multiarch-lts 14.4.2 20141030T081701Z
    base-32-lts 14.4.2 20141030T081701Z
    base-64-lts 14.4.2 20141030T081701Z
    base-multiarch-lts 14.4.2 20141030T081701Z
    minimal-32-lts 15.4.0 20141030T081701Z
    minimal-64-lts 15.4.0 20141030T081701Z
    minimal-multiarch-lts 15.4.0 20141030T081701Z
    base-32-lts 15.4.0 20141030T081701Z
    base-64-lts 15.4.0 20141030T081701Z
    base-multiarch-lts 15.4.0 20141030T081701Z
    minimal-32-lts 15.4.1 20141030T081701Z
    minimal-64-lts 15.4.1 20141030T081701Z
    minimal-multiarch-lts 15.4.1 20141030T081701Z
    base-32-lts 15.4.1 20141030T081701Z
    base-64-lts 15.4.1 20141030T081701Z
    base-multiarch-lts 15.4.1 20141030T081701Z
    ```

- Use public and supported origin images: It would be a good thing to base
  Triton and Manta core images on public images supported by Joyent because:
  dogfooding, fewer flavours of image in play. See the "Future" section
  for a discussion on having custom pkgsrc/image builds for use by Triton
  and Manta core images.

  Also, sticking with "-lts" (long term support) images should help ensure we
  stay on supported images, which is relevant for security updates.

- Size: A complete set of images for Triton (not Manta), along with one or
  more platforms and other pieces (e.g. the agents) must fit on a 4G USB key.
  Currently the images (in the "datasets" directory on the USB key) dominate:

    ```
    [root@headnode (nightly-1) /mnt/usbkey]# du -sk * | sort -n
    ...
    664	cn_tools.tar.gz
    723	tools.tar.gz
    1187	boot_archive.manifest
    1643	dos
    2614	boot
    15623	sdcadm-install.sh
    67358	firmware
    159285	ur-scripts
    536624	os                  // this is with 2 platforms
    1818037	datasets
    ```

  Typically, all "active" platforms in a DC are stored on the USB key. If
  the images leave little remaining space, that can have an impact for the
  operator.


### Q1: -multiarch or -32 or -64?

Assume we want to base on one of the "base" or "minimal" supported Joyent
images -- at least for a start. (See the "Future" section for considering custom
pkgsrc/images.) There are then three flavours: "-multiarch", "-32", and "-64".

The raison d'etre of "multiarch" is basically "like -32, but some packages have
been built for 64-bit" where it makes sense for those packages and (somewhat)
where Joyent eng has required. E.g., Manatee requires a 64-bit postgres, but
also runs Node services and a 64-bit node.js is/was problematic. I believe
the "problematic" was related to binary node modules.

In the first chat discussion (see "Discussions" section below for links) it
was decided that using "-multiarch" should suffice for all our cases. Jonathan
Perkin expressed some warnings about "-multiarch" usage if the use case was
to be largely 64-bit. However, at the time of writing, all Triton and Manta
services are fine running 32-bit with the exception of 64-bit postgres for
Manatee. [TODO: While postgres is the main one, I'm not positive there aren't
other 64-bit components in use. Something in electric-moray? -- Trent]
Should a service eventually require 64-bit, then we'll add a stream of Triton
origin images based on the "-64" Joyent images.


### Q2: base- or minimal- or something in between?

```
$ joyent-imgadm list name=~-lts version=15.4.1 -o name,version,size
NAME                   VERSION  SIZE
minimal-32-lts         15.4.1   67941979
minimal-64-lts         15.4.1   73691842
minimal-multiarch-lts  15.4.1   94912226
base-32-lts            15.4.1   291021161
base-64-lts            15.4.1   307766730
base-multiarch-lts     15.4.1   377863971
```

The minimal images are much smaller, so it bears looking into what pkgsrc
packages added to "base" might no be necessary for Triton/Manta core images.

The set of packages in base, but not minimal is:
https://github.com/joyent/imagetools/blob/3e45aeb713b794d3a5584ae39f5514aec2c81a56/install-base#L88-L102
I gathered some numbers for incremental image sizes, adding each of those
packages in turn. Some of them share deps so the numbers aren't totally clear
(e.g. excluding curl results in the bump for "postfix" being large).

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

Criteria for chosing packages:
- Don't egregiously break current core image usage. E.g. excluing gsed would
  break at least a few core images' boot scripts.
- Size of the USB key. The dominant space usage on the USB key is the
  platform(s) and all the images. Fewer origin images helps. Less duplication
  in each incremental image helps. I.e., if more than one image would use
  postfix, it probably is a space savings to include postfix in the origin
  image.
- A vague desire to "keep it light", i.e. don't include stuff that typically
  shouldn't be needed by core images.
- In opposition to the previous point: a desire to have tooling available that
  has proved useful for in-situ debugging.

A discussion of each contender package for our "sdc-minimal-multiarch" origin
image:

- coreutils: Include it. Suspect many core image scripts depend on these tools.
- curl: Include it. While there *is* a `curl` from the GZ, we shouldn't rely on
  the GZ curl because: security updates (using the platform OpenSSL), CA lists.
- diffutils: Exclude it. GZ `diff` should suffice.
- findutils: Exclude it. GZ `find` should suffice.
- gawk: Exclude it. Cody Mellow searched through current `awk` usage in
  Triton/Manta repos "and it doesn't look like we need gawk. There is a comment
  in a number of makefiles about needing gawk for multi-byte -F, but it turns
  out that nawk [the `awk` available from the GZ] does that, too."
- grep: Exclude it. A trawl through `grep` usage in current repos didn't
  turn up any fancy usage.
    ```
    [15:35:43 trentm@danger0:~/all-joy-repos]
    $ ag -w grep | grep -v illumos | grep -v '/deps/' | grep -v smartos-live \
        | grep -v ^sdcboot | grep -v ^sdcadm  | grep -v Makefile \
        | grep -v .ldif  | grep -v min.js | grep -v /docs/
    ```
  Actually for a while there DATASET-1269 meant that the GNU grep from pkgsrc
  *was* required for sm-set-hostname (if used, it was for standalone IMGAPI
  scripts). But now that that is fixed, there is no known requirement for
  GNU grep in Triton setup scripts.
- gsed: Include it. At least a couple core zones' setup scripts use `gsed`.
- gtar: Exclude it. The GZ gtar should suffice.
- less: Exclude it. GZ `less` should suffice.
- nodejs: Exclude it. Services will choose their own node.js version.
- patch: Include it. Small and useful. I'd advocate keeping this. I've used it
  in the field.
- postfix: Exclude it. I believe amon-master is using postfix. If that is the
  only one then perhaps exclude postfix.
- rsyslog: Exclude it. Not used currently.
    - CloudAPI has boot script code for haproxy syslog setup. However the
      'rsyslog' service is not running in the zone in nightly. See
      [PUBAPI-776](https://devhub.joyent.com/jira/browse/PUBAPI-776) for when
      rsyslog usage for the cloudapi SMF service was dropped.
    - Other Triton zones don't have the rsyslog service running:
        ```
        [root@headnode (nightly-1) ~]# sdc-oneachnode -a 'svcs -Z | grep syslog'
        HOSTNAME              STATUS
        00-1b-21-9b-62-00
        90-e2-ba-18-c4-c8
        headnode
        ```
    - Manta zones don't have the rsyslog service running:
        ```
        [root@headnode (staging-1) ~]# manta-oneach -a 'svcs | grep syslog'
        SERVICE          ZONE     OUTPUT
        authcache        51ae8301
        electric-moray   2a689e6c
        jobpuller        9d1ffdcd
        jobsupervisor    2b1d10be
        loadbalancer     49a3d111
        medusa           5ba88602
        moray            69790d4a
        moray            b3c6c144
        moray            b68396db
        nameservice      c6bfb16d
        postgres         70d44638
        postgres         a5223321
        postgres         ef318383
        storage          f7954cad
        webapi           380920d9
        ```
- sudo: Include it. Usage in some core images, e.g. sdc-manatee.git, muppet.git
- wget: Exclude it. While there is a GZ `wget`, we shouldn't use that for the
  same reasons mentioned for `curl` above. However, Triton and Manta core
  tooling *should use curl*.

Suggested starter set of minimal+ packages then is: `coreutils curl gsed patch
sudo`.


### Q4: Still need sdcnode builds for each image?

Currently we do "sdcnode" builds (see https://github.com/joyent/sdcnode) for
all origin images and for a number of versions. Initially this was to save
build time for each image (every build of, say, vmapi used to rebuilt node from
source), to allow floating patches, and custom configure flags (relevant for
GZ-targetted builds).

The question is whether for new origin images we need sdcnode builds or can
used the 'nodejs' packages in pkgsrc? Some questions there:

1. Does pkgsrc keep nodejs-X.Y.Z around when Z is *not* the latest patch
   release? If not, then I think we'd still want sdcnode so that a core image
   need not track the latest patch release on pkgsrc's schedule.
2. One recent case of floating a patch is for ECDH support for 0.10 -- currently
   being used by sdc-docker.
3. If using pkgsrc, can we react quickly enough with new node builds for
   security issues?

Jonathan Perkin answered "no" to the #1. That means we should continue to
provide sdcnode builds for now.

Note, however, that we can just use the sdcnode builds for the origin image
on which a triton-origin image is based. E.g. a `triton-origin-multiarch-15.4.1`
image based on `minimal-multiarch-lts@15.4.1` can use sdcnode builds for the
latter. This is because the triton-origin images do not add an custom binary
libraries on which a sdcnode build would depend.


### Naming and versioning

Say I have the following 3 active triton-origin image flavours:

1. based on minimal-multiarch-lts@15.4.x
2. based on minimal-multiarch-lts@16.4.x
3. Based on base-64@16.3.x.  If need be, we can argue against ever officially
   using a ".3" (which isn't LTS). If need be, we can argue against ever
   officially supporting "base" instead of always minimal.
   I think it is fair to potentially have a desire for "-64"-based origins.
   (Aside: I'm talking about portal, which currently deploys on base-64@16.3.1).

What should the triton-origin image names and versions be?

Recent prio art:

```
$ updates-imgadm -C '*' list name=~jenkins-agent -H -o name | sort | uniq
jenkins-agent-ia32-1.6.3
jenkins-agent-ia32-14.2.0
jenkins-agent-multiarch-13.3.1
jenkins-agent-multiarch-15.4.1
```

Full discussion at
https://jabber.joyent.com/logs/mib@conference.joyent.com/2017/04/28.html#19:23:08.951660

Conclusion: `name = "triton-origin-$pkgsrcArch-$originImageVersion"`, e.g.:

    NAME                                VERSION     NOTES
    triton-origin-multiarch-15.4.1      1.2.3
    triton-origin-multiarch-16.4.1      1.2.3
    triton-origin-x86_64-15.4.1         1.2.3       theoretical, hope we don't have to bother
    triton-origin-i386-15.4.1           1.2.3       theoretical, hope we don't have to bother

Because:

- This copies the pattern used by jenkins-agent, which is a nice commonality.
- As with `jenkins-agent-*` images, the `triton-origin-*` images are meant to
  primarily be compatible with the underlying arch and generation of
  minimal/base images
  (https://docs.joyent.com/public-cloud/instances/infrastructure/images/smartos/minimal).
  Hence, calling out the underlying image's arch and version in the name
  makes this clear.



### Plan

- [TOOLS-1752](https://smartos.org/bugview/TOOLS-1752) is the main ticket
  for implementing building triton-origin images.
    - Finish 'make publish' task. DONE.
    - Get 'triton-origin-image' jenkins job going. DONE.
        - add the commit hook... and for this branch. DONE.
    - Get a triton-origin-multiarch-15.4.1 build into 'experimental' channel.
      DONE.
        Q: What happens if the origin isn't in that channel yet?
        A: It blows up. I think for now we just leave it or document it.
    - For IMGAPI usage we'd need the blessed ones published to *images.jo*
      and in TPC. Doc this in "releasing" section of triton-origin README. DONE.
    - Usage docs in triton-origin-image/README.md. DONE.
    - Guinea pigs: vmapi and docker.  TRITON-2
        - Switch vmapi over in MG and get branch builds (in 'experimental' branch).
            - sdc-vmapi.git and mg.git changes for this
        - Ensure 'sdcadm up -C experimental vmapi' works.
            DONE
                ...
                download 1 image (56 MiB):
                    image ea9f516a-2f6f-11e7-826f-678a368f05b7
                        (vmapi@master-20170502T193901Z-g590a4e0)
            That doesn't mention the origin images. I think it should.
            It doesn't show the origin image pulls in the workign output either.
            Boo.
        - Ensure 'sdcadm up -C experimental vmapi docker' works.
          This is about testing that parallel pull of images with a common and
          locally missing origin is handled properly. It wasn't for a while, and
          this is an additional level.
            DONE (TOOLS-1634, TOOLS-1634 also TOOLS-1767 for an improvement)
    - Test that pulling this works if a *public* version of
      minimal-multiarch-lts@15.4.1 is already pulled from images.jo. DONE.
    - Build a COAL with this vmapi and ensure headnode setup works.
      DONE (HEAD-2361, in review)
    - Build a headnode-joyent with this and run it through nightly-1.
    - Switch 'docker' over to this and test it in coal/nightly-1,2.

- roll out to other components

Issues:

- [TOOLS-1752](https://smartos.org/bugview/TOOLS-1752) Create tool for creating Triton origin images
- [TOOLS-1634](https://smartos.org/bugview/TOOLS-1634) 'sdcadm up' parallel import of images can break when multiple images share a new origin image
- [TOOLS-1763](https://smartos.org/bugview/TOOLS-1763) sdcadm: TOOLS-1634 change to DownloadImages procedure mishandles theoretical custom-source-with-image-origins case
- [TOOLS-1767](https://smartos.org/bugview/TOOLS-1767) sdcadm's DownloadImages procedure could fail faster and use a refactor
- [TRITON-2](https://smartos.org/bugview/TRITON-2) switch VMAPI and docker to use a triton-origin image
- [HEAD-2361](https://smartos.org/bugview/HEAD-2361) support multi-level incremental core images for sdc-headnode build and headnode setup


## State as of July 2016

The state of Triton/Manta origin images before the "Modernization 2016"
effort.

- Most images are using (the ancient) sdc-smartos@1.6.3 (a private copy of
  the now deprecated smartos@1.6.3).
- Some images that require some 64-bit components (manatee, electric-moray)
  are using sdc-base@14.2.0.
- A couple newer service images are using more modern images (likely an
  attempt to start a modernization):
    - hostvolume (now deprecated) is using sdc-base-multiarch-lts@14.4.0
    - nfsserver is using sdc-minimal-multiarch-lts@15.4.1

Details:

```
[14:07:16 trentm@danger0:~/joy/mountain-gorilla (master)]
$ JOYENT_BUILD=true bash targets.json.in | json -Ma -c 'this.value.image_uuid' value.image_uuid key | sort
18b094b0-eb01-11e5-80c1-175dac7ddf02 nfsserver
1e81e08c-d406-11e4-aac9-6feb515aeb81 hostvolume
b4bdc598-8939-11e3-bea4-8341f6861379 cns
b4bdc598-8939-11e3-bea4-8341f6861379 electric-moray
b4bdc598-8939-11e3-bea4-8341f6861379 manta-manatee
b4bdc598-8939-11e3-bea4-8341f6861379 sdc-manatee
de411e86-548d-11e4-a4b7-3bb60478632a cloudapi
de411e86-548d-11e4-a4b7-3bb60478632a docker
de411e86-548d-11e4-a4b7-3bb60478632a muppet
de411e86-548d-11e4-a4b7-3bb60478632a nat
de411e86-548d-11e4-a4b7-3bb60478632a portolan
de411e86-548d-11e4-a4b7-3bb60478632a volapi
fd2cc906-8938-11e3-beab-4359c665ac99 adminui
fd2cc906-8938-11e3-beab-4359c665ac99 amon
fd2cc906-8938-11e3-beab-4359c665ac99 amonredis
fd2cc906-8938-11e3-beab-4359c665ac99 assets
fd2cc906-8938-11e3-beab-4359c665ac99 binder
fd2cc906-8938-11e3-beab-4359c665ac99 ca
fd2cc906-8938-11e3-beab-4359c665ac99 cnapi
fd2cc906-8938-11e3-beab-4359c665ac99 dhcpd
fd2cc906-8938-11e3-beab-4359c665ac99 fwapi
fd2cc906-8938-11e3-beab-4359c665ac99 imgapi
fd2cc906-8938-11e3-beab-4359c665ac99 madtom
fd2cc906-8938-11e3-beab-4359c665ac99 mahi
fd2cc906-8938-11e3-beab-4359c665ac99 mako
fd2cc906-8938-11e3-beab-4359c665ac99 manta-deployment
fd2cc906-8938-11e3-beab-4359c665ac99 marlin
fd2cc906-8938-11e3-beab-4359c665ac99 marlin-dashboard
fd2cc906-8938-11e3-beab-4359c665ac99 medusa
fd2cc906-8938-11e3-beab-4359c665ac99 mockcloud
fd2cc906-8938-11e3-beab-4359c665ac99 mola
fd2cc906-8938-11e3-beab-4359c665ac99 moray
fd2cc906-8938-11e3-beab-4359c665ac99 muskie
fd2cc906-8938-11e3-beab-4359c665ac99 napi
fd2cc906-8938-11e3-beab-4359c665ac99 papi
fd2cc906-8938-11e3-beab-4359c665ac99 propeller
fd2cc906-8938-11e3-beab-4359c665ac99 rabbitmq
fd2cc906-8938-11e3-beab-4359c665ac99 redis
fd2cc906-8938-11e3-beab-4359c665ac99 sapi
fd2cc906-8938-11e3-beab-4359c665ac99 sdc
fd2cc906-8938-11e3-beab-4359c665ac99 sdcsso
fd2cc906-8938-11e3-beab-4359c665ac99 ufds
fd2cc906-8938-11e3-beab-4359c665ac99 vmapi
fd2cc906-8938-11e3-beab-4359c665ac99 workflow
fd2cc906-8938-11e3-beab-4359c665ac99 wrasse
[14:07:27 trentm@danger0:~/joy/mountain-gorilla (master)]
$ JOYENT_BUILD=true bash targets.json.in | json -Ma -c 'this.value.image_uuid' value.image_uuid | sort | uniq -c
   1 18b094b0-eb01-11e5-80c1-175dac7ddf02
   1 1e81e08c-d406-11e4-aac9-6feb515aeb81
   4 b4bdc598-8939-11e3-bea4-8341f6861379
   6 de411e86-548d-11e4-a4b7-3bb60478632a
  33 fd2cc906-8938-11e3-beab-4359c665ac99
[14:07:41 trentm@danger0:~/joy/mountain-gorilla (master)]
$ JOYENT_BUILD=true bash targets.json.in | json -Ma -c 'this.value.image_uuid' value.image_uuid | sort | uniq | while read uuid; do updates-imgadm get $uuid | json -a uuid name version; done
18b094b0-eb01-11e5-80c1-175dac7ddf02 sdc-minimal-multiarch-lts 15.4.1
1e81e08c-d406-11e4-aac9-6feb515aeb81 sdc-base-multiarch-lts 14.4.0
b4bdc598-8939-11e3-bea4-8341f6861379 sdc-multiarch 13.3.1
de411e86-548d-11e4-a4b7-3bb60478632a sdc-base 14.2.0
fd2cc906-8938-11e3-beab-4359c665ac99 sdc-smartos 1.6.3
```


## Future

Ideas for future work for Triton origin images.

In the second chat discussion (see the "Discussions" section) Jonathan and
Josh Clulow advocated for doing custom package builds (possibly a full pkgsrc
set) for Triton core images.

Pros:
- Jonathan could build some of the larger packages with fewer optional features
  to make them smaller: e.g. postfix without LDAP/SASL support, db4 without its
  reams of docs.
- The custom packages could include DWARF for debugging.

Cons:
- Not using the public supported Joyent images means we aren't dogfooding what
  we support for customers.
- Custom packages mean separate packages to potentially debug.
- Including DWARF results in large packages. See this discussion from when
  pkgsrc for a short while changed to enabling DWARF:
  https://jabber.joyent.com/logs/scrum@conference.joyent.com/2016/04/25.html#16:34:38.688120

Basically my (Trent's) argument was that I didn't feel Triton/Manta's core
images was a strong enough case to be a special-case w.r.t. pkgsrc packages.
If Triton core needs could inform changes to core pkgsrc releases, and then
eventually benefit from those changes, that would be good.

So... this is something that could be looked into further. Perhaps
'triton-origin-*' 1.x images could start based on 'minimal-multiarch-lts',
and future work could move 'triton-origin-*' 2.x images to be based on
'minimal-debug-multiarch-lts'. For now I'm calling this out of scope for the
"Modernization 2016" effort, for which the main goal is to modernize to
other than the ancient smartos@1.6.3 base.


## Discussions

Here are links to a chat discussions relevant to this RFD:

- The first discussion
  https://jabber.joyent.com/logs/mib@conference.joyent.com/2016/07/05.html#21:33:08.388365
- A second discussion the next morning after this RFD was initially written,
  starting here:
  https://jabber.joyent.com/logs/scrum@conference.joyent.com/2016/07/06.html#16:07:55.442834
  and then continued after bot's scrum here:
  https://jabber.joyent.com/logs/scrum@conference.joyent.com/2016/07/06.html#16:33:04.165302
