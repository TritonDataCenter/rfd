---
authors: Trent Mick <trent.mick@joyent.com>, Todd Whiteman
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+113%22
---

# RFD 113 x-account image transfer and x-DC image copying

The following details a proposal for new IMGAPI, CloudAPI, and node-triton
functionality to make the following improvements to Triton custom images:

- allow transferring ownership of an image (or clone of an image) to another account;
- allow copying one's own custom images from another DC within the same cloud;
- possibly support tooling for a customer to better understand their image usage
  (which images does this image depend upon; which images are derived from
  this one; which instances use this image)


<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Status](#status)
- [Motivation](#motivation)
- [Background](#background)
- [tl;dr](#tldr)
- [Design discussion](#design-discussion)
  - [x-account image clone](#x-account-image-clone)
  - [x-DC image copy](#x-dc-image-copy)
- [Milestones](#milestones)
  - [M1: make image creation *non*-incremental by default](#m1-make-image-creation-non-incremental-by-default)
  - [M2: x-account image clone](#m2-x-account-image-clone)
  - [M3: x-DC image copy](#m3-x-dc-image-copy)
  - [M4: triton-go and terraform support for these new features](#m4-triton-go-and-terraform-support-for-these-new-features)
  - [M5: client improvements for listing image usage](#m5-client-improvements-for-listing-image-usage)
- [Scratch](#scratch)
  - [Open Qs and TODOs](#open-qs-and-todos)
  - [Trent's scratch area](#trents-scratch-area)
- [Appendices](#appendices)
  - [Appendix A: out of scope](#appendix-a-out-of-scope)
  - [Appendix B: share an image with other accounts](#appendix-b-share-an-image-with-other-accounts)
  - [Appendix C: Sharing using account *login* or *uuid*?](#appendix-c-sharing-using-account-login-or-uuid)
  - [Appendix D: Old proposal for copying images x-DC that has IMGAPI talking to a remote CloudAPI](#appendix-d-old-proposal-for-copying-images-x-dc-that-has-imgapi-talking-to-a-remote-cloudapi)
  - [Appendix E: language for x-DC image copy?](#appendix-e-language-for-x-dc-image-copy)
  - [Appendix F: language for x-account image clone?](#appendix-f-language-for-x-account-image-clone)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Motivation

The scenario: An organization has a service infrastructure with a dozen or
so services. Each service has a separate image (and may, of course, be updated
with new versions of the service image). The services each have a number of
instances spread across 3 Triton datacenters in a region. Images are built
and validated by one group (engineering, say) using one Triton account. Those
images are deployed and managed in production by a separate group (ops, say)
using a separate Triton account. Current RBAC (i.e. subusers) is not in play.

Because images are created by one account and deployed by another, we want
the ability to transfer/copy an image from one account to another.

Because Triton images are created in a particular DC (rather than being a
regional resource, like in AWS), the organization requires a way to copy a
transferred image to all DCs in the region (and perhaps outside of the region).
If an image is built with automated tooling (e.g. with Packer), then technically
the customer could just build the image in each DC separately. However, that
isn't a satisfying solution. Tooling that is deploying across the region
shouldn't *have* to manage separate image identifiers for the image in each DC.


## Related discussions

- [The discussion on GitHub](https://github.com/joyent/rfd/issues/71)
- [Some internal discussion](https://devhub.joyent.com/jira/browse/SWSUP-903)
- [RFD-113 labelled issues](https://devhub.joyent.com/jira/issues/?jql=labels%3DRFD-113).


## IMGAPI refresher

Note that currently in IMGAPI:

- There is a single image `owner` (and account UUID). This account has full
  control over the image: UpdateImage, DeleteImage, provisioning, etc.
- There is an optional set of other accounts on the image `acl` (access control
  list). Accounts on the `acl` for an image can *use* the image (GetImage,
  ListImages, provisioning) but cannot modify or delete the image.
- Images can be incremental (currently, all custom images are incremental),
  which means they have a parent (called "origin") chain. The base of the
  parentage is (currently) always an Joyent-provided and operator-imported image
  (e.g. minimal-multiarch-lts@15.4.1 is one). There are implications with
  transferring images and its parentage.

## Example

For the following examples, the following accounts and images already exist:

- Alice (login=alice, uuid=a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef) has an
  image "my-image" built in DC "us-sw-1".
- Bob (login=bob, uuid=b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4).

Alice shares her image "my-image" with Bob.

    [alice]$ triton image share my-image b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4
    Shared image 0965c1f4-6995-c095-ecb5-c1a80be2b08e (my-image@1.2.3) with
        account b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4

Bob can see the shared image (marked with the 'S' flag).

    [bob]$ triton image list
    SHORTID   NAME      VERSION  FLAGS   OS       TYPE          PUBDATE
    6d1bd84b  my-image  1.2.3    S       smartos  zone-dataset  2017-10-17

When provisioning the shared image, Bob must explicitly specify that he wants to
allow provisioning of shared images (default is no).

    [bob]$ triton create --allow-shared-images my-image some-package
    SHORTID   NAME      VERSION  FLAGS   OS       TYPE          PUBDATE
    6d1bd84b  my-image  1.2.3    S       smartos  zone-dataset  2017-10-17

Bob can clone Alice's shared image into his own account, which gives Bob full
control over the image.

    [bob]$ triton image clone my-image
    Cloned image id: 0965c1f4-6995-c095-ecb5-c1a80be2b08e

The cloned image has a different id and is the original image is no longer
shared with Bob.

    [bob]$ triton image list
    SHORTID   NAME      VERSION  FLAGS   OS       TYPE          PUBDATE
    0965c1f4  my-image  1.2.3            smartos  zone-dataset  2017-10-17

Alice copying image from us-sw-1 to us-west-1:

    [alice]$ triton -p us-west-1 image cp us-sw-1 my-image
    Copying image 0965c1f4 (my-image@1.2.3) from datacenter us-sw-1.
    [======>                ] ... progress ...


## Design discussion

### x-account image clone

Cloning will need to take into account incremental images and public
(operator provided) images. Take this scenario:

- image ubuntu-14.04 (public, admin-owned, operator provided base image)
- image A (custom image based on ubuntu-14.04, say it provides the JVM)
- image B (based on A, say it provides Tomcat)
- images C and D (service-specific images, each based on B)
- Eng would like to transfer C and D to Ops

Cloning an image must clone all incremental (origin) images, but not the
public (operator) provided images.

When Eng shares image C with Ops, it will give Ops access to images B and A
(they already have access to ubuntu-14.04).

When Ops clones image C, they get clones of images B and A as well.

When Ops clones image D, they will get *new* clones of image B and A, which
will be different to the cloned B and A images from cloned image C.

To avoid confusion, the cloned incremental images B and A will be marked as
disabled, so they will not show up in Ops `triton images` listing, but will
be visible as the image 'origin' and will still be accessible via
`triton image` operations.

#### Incremental images

We acknowledge that the origin chain of incremental images is confusing to users
and the expected benefit (size savings in transfer, because the bits in image A
and image B may not need to be schlepped around as often) hasn't been justified.
We propose to **change image creation to NOT be incremental by default.** This
would bias custom images to being non-incremental: larger, but simpler to
manage.

Another benefit of custom images being non-incremental is that they do not
depend on operator-provided base images (e.g. minimal, base, etc.) which means
that operators of a cloud do not *need* to ensure that all base images are
identical in all DCs as a requirement for x-DC image copying.

#### Security

Image sharing allows any account in the same cloud to add an image with any
name@version to your list of images. If you are in the habit of using `triton
instance create my-image ...` or equivalent -- i.e. using client tooling that
identifies images by *name* for provisioning -- then there is a possible attack
where an account can inject an image that you might later provision on your
private network. To guard against this, shared images are not provisionable
by default, and the user will need to explicitly allow provisioning from a
shared image.

Note that I (Trent) got the impression from our last customer workshop that
having to explicitly allow shared images before provisioning was considered too
much of a burden. Here are some workaround options, and we would welcome
hearing other opinions.

1.  Triton could add support for an allowed shared account config:
    `image_share_trusted_accounts` A receiver would have to explicitly do the
    following once:

        triton account update image_share_trusted_accounts=$uuid-of-allowed-sharer


### x-DC image copy

The feature is for an account to copy **one's own custom images** from another
DC *in the same cloud* (i.e. sharing an account database).

    [alice]$ triton datacenters
    NAME       URL
    eu-ams-1   https://eu-ams-1.api.joyentcloud.com
    us-east-1  https://us-east-1.api.joyentcloud.com
    us-sw-1    https://us-sw-1.api.joyentcloud.com
    ...

    [alice]$ triton image cp us-sw-1 my-image
    Copying image 0965c1f4 (my-image) from datacenter us-sw-1.
    [======>                ] ... progress ...

A nice to have would be support (or sugar in tooling?) for copying a given
image to *all*, or an explicit set of, other DCs.

The x-DC copying will use IMGAPI-to-IMGAPI communication, this adds an
operational requirement that IMGAPI zones in each DC in a cloud can route to
each other. Given this, x-DC copy ends up being similar to existing image
import -- e.g. where a new image is imported in to the DC's IMGAPI from an
external public image repository like <https://images.joyent.com> and
<https://updates.joyent.com>.


## Milestones

### M1: make image creation *non*-incremental by default

<https://jira.joyent.us/browse/TRITON-51>

See the x-account image transfer design discussion above. This milestone is
about making image creation (cloudapi CreateImageFromMachine) *non*-incremental
by default and then support an option for the old behaviour of making an
incremental image. Implementation notes:

- I *believe* the cloudapi code that calls IMGAPI CreateImageFromVm need only
  pass `incremental=false`. Currently the cloudapi code is always passing
  `incremental=true`. If possible, this means we don't need a platform
  update or cn-agent update for new imgadm functionality, which is great.
- CloudAPI CreateImageFromMachine should add a new `incremental` option
  and document implications of incremental and non-incremental images.
- `triton image create` should expose this incremental option.
- Q: Need we bump the cloudapi major version for this? It *is* a behaviour
  change. However, I believe there is wiggle room given the limited
  current capabilities the user has for image management. I'd still bias
  to a major version bump for this, which would mean a required update
  to node-triton and other clients.


### M2: x-account image share

<https://jira.joyent.us/browse/TRITON-116>

- `triton image share $image $account` new command in node-triton.
    - This command uses the existing CloudAPI.UpdateImage API to add the given
      account uuid to the image ACL list.
- `triton images` grows support to show shared images.
    - Node-triton will use 'S' flag to mark shared images.

### M3: x-account image clone

<https://jira.joyent.us/browse/TRITON-53>

- `triton image clone $image` new command and node-triton library support.
    - Only shared images can be cloned
- New CloudAPI CloneImage that will call IMGAPI to do the work.
  Ideally, given that there is no heavy bit moving here (we are just doing
  `ln` or `mln` of image files on the storage backend), I think this can be
  a synchronous endpoint, i.e. CloudAPI CloneImageToAccount doesn't return until
  the transfer is complete (either successfully or failed).
- New IMGAPI CloneImageToAccount endpoint:
    - The image must be state=active
    - The image.acl must include the given account (i.e. it is a shared image)
    - Gather the ancestry of the image to transfer
    - Ensure that all images in the ancestry to be transferred (all those
      up to the first image owned by 'admin', i.e. an operator-provided
      image) *can* be transferred.
    - Working up from the base of the origin chain to be transferred:
        - copy the image manifests (owner=$newaccount, state=unactivated)
            - image.acl must be deleted (they don't inherit the ACL)
            - image.published_at is reset to the current date/time
        - copy the image files
        - set state=disabled to all images in the origin chain (disabled just
          means you can't provision that image)
        - activate the image
        - remove user from the shared image.acl, so the original image is no
          longer shared with the user
- Adding metadata to cloned images about the source image. This isn't *required*
  for providing the functionality, however it could be helpful for users to grok
  the source of images in `triton image list`.
    - Q: image.tags (quick hack) or top-level fields (less hacky, API
      versioning, more work)?
    - Q: track both source image UUID and source account? What about exposing
      the source account *login*?
    - Q: what field names to use?
    - TODO: evaluate the effort in using top-level manifest fields. If that
      is too difficult and the feature is still desired, then consider
      falling back to using tags.
    - Note: Even if added fields were not exposed via CloudAPI, then could
      be useful for internal auditing.


### M4: x-DC image copy

<https://jira.joyent.us/browse/TRITON-52>

Implementation notes:

- If easier, we will error on incremental images for the first pass. The intent
  is to properly fully support incremental images for this milestone.
- new `triton image copy-from-dc ...` command.
- new CloudAPI CopyImageFromDc, which accepts an image UUID and a source DC
  name. The DC names match those from CloudAPI ListDatacenters.
- CloudAPI calls IMGAPI ImportDcImage. IMGAPI looks for a local image with that
  UUID, and depending on `image.state`:
    - `failed`: Delete it, create new placeholder `state=copying` or whatever,
      and start a new job to re-start
    - `copying`: Look up the job that is doing this actively. If there is one,
      then attach to its progress stream. If not, then delete it and start a
      new job (similar to the "failed" case).
    - `active`: Already copied, but there might be metadata updates to refetch.
      Per <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/CopyingAMIs.html#copy-amis-across-regions>
      one can "recopy" if there were image changes (for us that would
      just be mutable manifest changes). Do a GetImage on the source DC and
      update. Note in the returned progress message whether there were any
      changes.

    Note: Progress could just be info on the placeholder image object with
    number of bytes copied. The IMGAPI endpoint would poll that every couple
    of seconds. Note also it needs to handle looking at origin images.
- Note image *icon* limitation for starters. Arguably image icon support should
  just be dropped.
- `triton image wait IMAGE` should be able to either poll (minimally) for
  an image going to state=active; or perhaps call a
  `CopyImageFromDc?do_not_restart=true` to attach to the progress stream.

Dev Notes:

- must handle origin images... does this have a confirmation? Perhaps just
  client side? Meh. Adding `triton img ancestry IMG` might be nice to
  be able to predict.
- it would be *really* good if this could share the same "import from IMGAPI"
  (e.g. images.jo) code in IMGAPI already
- what about 'DeleteImage' on the target image to cancel the copy job?
- think about failed file transfer
- think about retry
- think about range-gets for retries to cope with huge image files
- think about concurrent attempts
- think about DeleteImage on the src DC during the copy
- operational setup
    - fwrule updates for IMGAPI zones, which typically drop in-bound requests.
    - Would want 'sdcadm post-setup' command to assist with linking IMGAPIs.
      Would we re-use the '$dc imgapi key'? Probably piggyback on that, yes.


### M5: triton-go and terraform support for these new features

TODO: follow up with Go guys on this.


### M6: client improvements for listing image usage

(This section is incomplete.)

From workshop discussion, it was suggested that some client support to be
able to list some usage/dependency details about images would be helpful. E.g.:

- which images does this image depend upon
- which images are derived from this one
- which instances use this image

TODO: a design section above on this would be good

    $ triton image ls
    SHORTID   NAME                    VERSION        FLAGS  OS       TYPE          PUBDATE
    ...
    7b5981c4  ubuntu-16.04            20170403       P      linux    lx-dataset    2017-04-03
    04179d8e  ubuntu-14.04            20170403       P      linux    lx-dataset    2017-04-03
    bc33164c  ubuntu-certified-14.04  20170619       P      linux    zvol          2017-06-19
    80e13c87  ubuntu-certified-17.04  20170619.1     P      linux    zvol          2017-06-21
    6aac0370  centos-6                20170621       P      linux    zvol          2017-06-21
    00a3a25e  minimal-multiarch-lts   17.4.0         P      smartos  zone-dataset  2018-01-04
    915b500a  base-multiarch-lts      17.4.0         P      smartos  zone-dataset  2018-01-04
    55010197  my-origin               4.5.6          I      smartos  zone-dataset  2018-01-12
    0965c1f4  my-image                1.2.3          I      smartos  zone-dataset  2018-01-12

Perhaps an option to list just my custom images:

    $ triton image ls -m
    SHORTID   NAME       VERSION  FLAGS  OS       TYPE          PUBDATE
    55010197  my-origin  4.5.6    I      smartos  zone-dataset  2018-01-12
    0965c1f4  my-image   1.2.3    I      smartos  zone-dataset  2018-01-12

And perhaps just leaf images (i.e. more likely to be ones used for provisioning
rather than for image creation):

    $ triton image ls -me
    SHORTID   NAME       VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  my-image   1.2.3    I      smartos  zone-dataset  2018-01-12

A command to see that image's full ancestry, given that it is incremental:

    $ triton image ancestry my-image
    SHORTID   NAME                   VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  my-image               1.2.3    I      smartos  zone-dataset  2018-01-12
    55010197  my-origin              4.5.6    I      smartos  zone-dataset  2018-01-12
    00a3a25e  minimal-multiarch-lts  17.4.0   P      smartos  zone-dataset  2018-01-04

Or perhaps a tree view of the images which shows the ancestry:

    $ triton images --tree
    SHORTID       NAME                   VERSION  FLAGS  OS       TYPE          PUBDATE
    00a3a25e      minimal-multiarch-lts  17.4.0   P      smartos  zone-dataset  2018-01-04
      55010197    my-origin              4.5.6    I      smartos  zone-dataset  2018-01-12
        0965c1f4  my-image               1.2.3    I      smartos  zone-dataset  2018-01-12
      2575ucf3    other-origin           3.5.0    I      smartos  zone-dataset  2018-02-27
        49fc810a  other-image            1.0.3    I      smartos  zone-dataset  2018-03-10

A command to go the other way to see what images build upon a given one:

    $ triton image children my-origin
    SHORTID   NAME                   VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  my-image               1.2.3    I      smartos  zone-dataset  2018-01-12

An perhaps a command (could be client-side sugar) to list instances using a
given image:

    $ triton ls --image=my-image@1.2.3
    SHORTID   NAME  IMG             STATE    FLAGS  AGE
    2c37513d  mex0  my-image@1.2.3  running  -      3w
    76cc521f  mex1  my-image@1.2.3  running  -      2d

Implementation notes:

- TODO



## Open Qs and TODOs

- Consider tracking the transfer source account and image UUID. A quick way
  to do this would be to define special *tags* for this. Tags would certainly
  be quick, but it is a little weak to use that. We *do* already use tags for
  structured info, e.g. for `tags.kernel_version`, so this wouldn't be the
  first time. That doesn't make it a Good Thing.

  IMO, we should spec out what field or tag names we would use, and then
  see what effort/issues there would be in using first-class manfiest fields
  for this, before considering falling back to the "quick hack" use of tags.

- Consider adding all this behind a feature flag -- whether that is a generic
  TritonDC feature flag mechanism that this RFD guinea pigs, or a simple/quick
  SAPI metadata var on the IMGAPI service.

- Nice to have: a way to list just *my* custom images easily (to see them from
  the noise of all the public ones)
