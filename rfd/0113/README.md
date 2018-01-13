---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+113%22
---

# RFD 113 x-account image transfer and x-DC image copying

The following details a proposal for new IMGAPI, CloudAPI, and node-triton
functionality to make the following improvements to Triton custom images:

- allow transferring ownership of an image to another account;
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
  - [transfer an image to another account](#transfer-an-image-to-another-account)
  - [x-DC image copy](#x-dc-image-copy)
- [Milestones](#milestones)
  - [M1: make image creation *non*-incremental by default](#m1-make-image-creation-non-incremental-by-default)
  - [M2: x-account image transfer](#m2-x-account-image-transfer)
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
  - [Appendix E: 'copy' or 'pull' language?](#appendix-e-copy-or-pull-language)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status

Still in design discussions. See:

- [The discussion on GitHub](https://github.com/joyent/rfd/issues/71)
- [Some internal discussion](https://devhub.joyent.com/jira/browse/SWSUP-903)
- [RFD-113 labelled issues](https://devhub.joyent.com/jira/issues/?jql=labels%3DRFD-113).


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

Earlier versions of this RFD talked about the separate functionality of
"sharing" images -- providing read access to an image to another account. The
issue with this is that the shared (by engineering) image is still ultimately
controlled by engineering. It is unsatisfying for operations to be deploying
instances using an image that could be deleted at anytime by a separate
corporate group. Likewise, engineering would prefer to not have the
responsibility to not mess up production when wanting to do house cleaning.


## Background

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

Our scenario for examples below:

- Alice (login=alice, uuid=a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef) has an
  image "my-image" built in DC "us-sw-1".
- Bob (login=bob, uuid=b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4).


## tl;dr

Alice transferring a *copy* of image "my-image" to Bob. (In the current
proposal, Alice needs to know Bob's account UUID. This is to avoid a method by
which account logins can be enumerated.)

    [alice]$ triton image transfer my-image b0bac663-9f3b-4a55-9079-e6fa0d308e13
    Copied image 0965c1f4-6995-c095-ecb5-c1a80be2b08e (my-image@1.2.3)
        to image 6d1bd84b-7a32-4242-8350-e0cbe7d6cb1b (my-image@1.2.3)
        owned by account b0bac663-9f3b-4a55-9079-e6fa0d308e13

    [bob]$ triton image list
    SHORTID   NAME      VERSION  OS       TYPE          PUBDATE
    6d1bd84b  my-image  1.2.3    smartos  zone-dataset  2017-10-17
    ...

Alice copying image from us-sw-1 to us-west-1:

    [alice]$ triton -p us-west-1 image cp us-sw-1 my-image
    Copying image 0965c1f4 (my-image@1.2.3) from datacenter us-sw-1.
    [======>                ] ... progress ...


## Design discussion

### transfer an image to another account

How should giving ownership of an image to another account work?
The naive first pass at this would be **just change the owner to the new
account.** If an image is incremental you run into potential problems. Take
this scenario:

- image ubuntu-14.04 (admin-owned, operator provided base image)
- image A (custom image based on ubuntu-14.04, say it provides the JVM)
- image B (based on A, say it provides Tomcat)
- images C and D (service-specific images, each based on B)
- Eng would like to transfer C and D to Ops

If the implementation simply updated `owner` on images C and D, we need to
decide what to do with images B and A on which they depend. If Ops was made
owner of those, then the Eng account has lost access to those images for
subsequent image building work. That's unacceptable. If images B and A were
left alone, then the Ops account has incomplete access to images C and D.
Eng could delete images B or A, breaking future provisions using C and D.
That is also unacceptable.

Below we will consider moving away from incremental images (at least by
default). However, they exist now and likely aren't completely going away.
That means "just change the owner to the new account" isn't a candidate
solution. Further, even if we only supported non-incremental images, it isn't
clear that the account transferring the image would accept losing access to
the image.

* * *

Other options:

1. **Create a duplicate copy of the image (and its non-admin-owned origin
   images) with a new UUID** and assign *that* image to the new account owner.
2. Create a new image that flattens any incremental origin layers of the
   origin image, and assign *that* image to the new account owner.

The argument for #2 over #1 is that a set of origin images (i.e. images A
and B) could be confusing for the receiving account. In our example, when
Ops "received" a new "image C" (now with a new UUID), they would also see
copies of images A and B in their `triton image list` output. If the image
was flattened, then there wouldn't be any origin images to copy over. However,
that flattening isn't trivial work to do for this transfer, so I'd prefer to
avoid it.

**The proposal is as follows.** We acknowledge that the origin chain of
incremental images is confusing to users and the expected benefit (size savings
in transfer, because the bits in image A and image B may not need to be
schlepped around as often) hasn't been justified. We propose to **change
image creation to NOT be incremental by default.** This would bias custom
images to being non-incremental: larger, but simpler to manage.
And then **for cross-account image transfer, we'd do option #1** as described
above.

The expected *common case* would be transfer of a non-incremental image.
A copy image with a new UUID is created, and `image.owner` is set to the new
account.

Another benefit of custom images being non-incremental is that they do not
depend on operator-provided base images (e.g. minimal, base, etc.) which means
that operators of a cloud do not *need* to ensure that all base images are
identical in all DCs as a requirement for x-DC image copying.

* * *

Security considerations. So far the feature as described allows any account
in the same cloud to add an image with any name@version into your list of
images. If you are in the habit of using `triton instance create my-image ...`
or equivalent -- i.e. using client tooling that identifies images by *name*
for provisioning -- then there is a possible attack where an account can
inject an image that you might later provision on your private network.
Some guard against this is justified.

To guard against this, the receiving account needs to one or more of:

- Explicitly trust the sending account to do this (i.e. grant permission to
  specific accounts to transfer images to me)

- Explicitly trust every transferred image: every transferred image goes into
  a "not yet available for provisioning" bucket until some explicit action by
  the receiver.

  This is akin to the "transfer" process being a "publish" by the sender and a
  "pull" by the receiver, except that the Triton imaging system doesn't have a
  concept of an repository with access control to which customers can publish
  images.

I got the impression from our last customer workshop that the latter (having
to explicitly accept every new image transferred before using for provisioning)
was considered too much of a burden. However, I would welcome hearing opinions.

Potential ways to implement this:

1.  Triton could add support for an account config:
    `image_transfer_trusted_accounts` A receiver would have to explicitly do the
    following once:

        triton account update image_transfer_trusted_accounts=$uuid-of-allowed-sender

2.  Transferred images could be tracked (with a new
    `image.transferred_by=$account` manifest field) and client tooling that
    allows identifying images by name (node-triton, triton-go, terraform) could
    be written to require that the source account be specified when looking up
    the image.

    I'm not a big fan of this one. It puts a burden on existing client tooling.
    For example, I don't have a feel for the impact on Terraform support to
    require this.

3.  Transferred images could have a new image state=transferred. The receiver
    would have to `triton image accept-transfer IMAGE...` to move it to
    state=active to have it in the default set of listed images for
    provisioning. This is an example of the latter "explicitly trust every
    transferred image".

So far my favourite is #1, but I welcome others' opinions.


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

An original design of this feature discussed image copy being done involving
IMGAPI (in the receiving DC) to CloudAPI (in the source DC) communication.
After discussion it was decided to instead pursue direct IMGAPI-to-IMGAPI
communication for transferring image data. The older proposal is in Appendix
D below.

For IMGAPI-to-IMGAPI communication, this adds an operational requirement that
IMGAPI zones in each DC in a cloud can route to each other. Given this,
x-DC copy ends up being similar to existing image import -- e.g. where a
new image is imported in to the DC's IMGAPI from an external public image
repository like <https://images.joyent.com> and <https://updates.joyent.com>.
See the Milestones section below for implementation details.


## Milestones

### M1: make image creation *non*-incremental by default

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


### M2: x-account image transfer

See the design notes above for reasoning. This milestone is about the new
support for x-account image transfer. Implementation notes:

- `triton image transfer` new command (and node-triton library support)
- New CloudAPI TransferImage that will call IMGAPI to do the work.
  Ideally, given that there is no heavy bit moving here (we are just doing
  `ln` or `mln` of image files on the storage backend), I think this can be
  a synchronous endpoint, i.e. CloudAPI TransferImage doesn't return until
  the transfer is complete (either successfully or failed).
- New IMGAPI TransferImage endpoint:
    - The image must be state=active
    - Gather the ancestry of the image to transfer
    - Ensure that all images in the ancestry to be transferred (all those
      up to the first image owned by 'admin', i.e. an operator-provided
      image) *can* be transferred. It is possible that one of those images
      is accessible to the original account, only because the account is
      on the `image.acl`. Being on the image ACL implies read-only access to
      the image, and should not convey the ability to create a copy of the
      image on another account. If this situation is hit, it is an error.
    - Working up from the base of the origin chain to be transferred:
        - copy the image manifests (owner=$newaccount, state=unactivated)
        - copy the image files
        - activate the images. Note that if a source image was state=disabled,
          it should have that same state afterwards. In other words, it is
          okay to transfer an image if one of its origin images is disabled
          (disabled just means you can't provision that image).
    - TODO: consider adding new `transferred_by=$source_account_uuid` manifest
      variable for bookkeeping. This *could* be exposed via CloudAPI and
      `triton` client tooling or not. Having that data internal could help
      with auditing if there is a problem. On the client side, it *could*
      be used for one of the proposed guards. For *auditing*, if we had
      lightweight jobs, then we'd have that info in job data. Using a job
      for this feels like overkill, however.
- Guards on calling TransferImage: TODO once a guard design is selected.


### M3: x-DC image copy

Implementation notes:

- If easier, we will error on incremental images for the first pass. The intent
  is to properly fully support incremental images for this milestone.
- A new `triton image copy-from-dc ...` command.
- a new CloudAPI CopyImageFromDc, which accepts an image UUID and a source DC
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
- think about failed file transfer
- think about retry
- think about range-gets for retries to cope with huge image files
- think about concurrent attempts
- think about DeleteImage on the src DC during the copy
- operational setup
    - fwrule updates for IMGAPI zones, which typically drop in-bound requests.
    - Would want 'sdcadm post-setup' command to assist with linking IMGAPIs.
      Would we re-use the '$dc imgapi key'? Probably piggyback on that, yes.


### M4: triton-go and terraform support for these new features

TODO: follow up with Go guys on this.


### M5: client improvements for listing image usage

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



## Scratch

### Open Qs and TODOs

- What guard to implement for x-account image transfer? See the design
  section for this.

- Naming the action. Alice is giving Bob a *copy* of the image. Alice
  retains the original. "share"? "transfer"? Some other verb?)

        ... publish?
            [eng]
            $ triton image create name=mex version=1.2.3
            $ triton image publish mex@1.2.3
        Publish to whom? Where? Who has access to that repo?
        Publish directly to their account? This could be the verb instead of transfer.
            $ triton image publish mex@1.2.3 bob

- Nice to have: a way to list just *my* custom images easily (to see them from
  the noise of all the public ones)


### Trent's scratch area

(If you aren't Trent, you can ignore all this.)


    triton imgs           # public and images I own
    triton imgs -a|--all  # includes inactive image (state=all)

How to show also shared ones, or *just* shared ones? Is the latter really
that important?

    triton imgs --shared  # also include shared ones? or *just* all shared ones?

Try this:

    triton imgs --shared  # *also* includes shared ones

Is it weird that `triton imgs owner=$alice` can show things not in `triton imgs`
default list?  Kinda, yes. So that also requires `--shared`:

    triton imgs --shared owner=$alice

To show a particular, UUID works:

    triton img get UUID

but by name you must specify from whom it is being shared?

    alice=<alice's account uuid>
    triton img get -S $alice cool-image


    triton imgs -S

    # how to only list shared ones?
    triton imgs public=false 'owner!=me'   # too hard
    # Could consider a 'shared=true'.
    triton imgs

    triton img get NAME[@VERSION]
    triton inst create NAME[@VERSION] PACKAGE


New "S" flag for shared images. This requires knowing the account uuid.
Which means extra work if this is client side. Could easily do server side.


TODO:
- a way to unshare
- a way to see with whom I've shared my images
- what's the story for account uuid vs login


## Appendices

### Appendix A: out of scope

From a review of competitors, Casey suggested in
[discussion](https://github.com/joyent/rfd/issues/71#issuecomment-337149084)
that transferring *ownership* of an image **not** be implemented.

However in later discussions at the December workshop it was determined that
it is image **sharing** (via the `image.acl`) that isn't needed, and that
transfer of ownership *is* wanted. The use case for transfer of ownership
is where an engineering or build group creates images for a given service,
and transfers ownership of the image to a separate deployment ops account
for deployment. Granted that in an AWS IAM model, these would just be
subusers under a common account and the need for cross-account transfer would
be less acute. However, we don't have RBACv2 right now.

This means that for now, this RFD will no longer propose image *sharing*
via `image.acl`.

* * *

In separate [discussion](https://github.com/joyent/rfd/issues/71) it was
decided that the following is just *nice to have*: `triton image clone` so Bob
can create a personal (owned) copy of Alice's shared image? That way he can be
confident it won't be deleted out from under him if Alice deletes the image.
Given that image sharing is now out of scope, this use case for `triton image
clone` is moot.



### Appendix B: share an image with other accounts

(Note: This appendix is now *moot* because image sharing is now out of scope.
See Appendix A.)

We expose the ability to share a custom image with other accounts, while
retaining ownership. Here "share" means read-only access to the image --
GetImage, ListImages, provisioning. We say "expose" because this is what
`image.acl` provides.

    [alice]$ triton image share my-image bob
    Image "my-image" shared with account "bob"

    [alice]$ triton image get my-image
    {
        "id": "0965c1f4-6995-c095-ecb5-c1a80be2b08e",
        "name": "my-image",
        "version": "1.0.0",
        "owner": "a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef",
        "owner_login": "alice",     // added this
        ...
        "shared_with": [            // not re-using "acl" for discussion
            "bob"
        ]
    }

    [bob]$ triton image list --shared
    SHORTID   OWNER_LOGIN  NAME       VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  alice        my-image   1.0.0    S      smartos  zone-dataset  2017-10-17
    ...

If Alice fat-fingers the account name to one that doesn't exist, it still
"works":

    $ triton image share my-image bib
    Image "my-image" shared with account "bib"

See the "Sharing using account *login* or *uuid*?" appendix below for some
earlier debate on this functionality.

TODO:

- Still need to spec how to deal with treating shared images separately from
  public and ones own images. Specifically for matching images by name
  (a convenience provided by the `triton` CLI), e.g. when providing an image
  by name for `triton instance create ...`. We want to avoid an attacker
  being able to affect a user's use of, e.g.,
  `triton create minimal-multiarch-lts ...`.


Implementation notes:

- IMGAPI's acl handling could be updated to support account *login* rather than
  just UUID for `acl` valies. It would be a new v3 major API version, but we're
  already doing API versioning, so that should be fine.
- IMGAPI ListImages and GetImage for API v2 would elide the non-UUID entries
  of `image.acl`.
- CloudAPI GetImage and ListImages would add `owner_login`.
  Q: Do we add `owner_login="admin"` for admin-owned images? We already *do*
  expose the admin UUID with the `owner` field, FWIW.
- Decide on the "shared_with" field name. If it maps directly to what IMGAPI
  stores, then we could/should call it the same "acl" name.


### Appendix C: Sharing using account *login* or *uuid*?

(Note: This is now *moot* because image sharing is now out of scope.
See Appendix A.)

This section discusses the tradeoffs with the API speaking only in terms of
account UUIDs or account login.

We want to enable Alice (login=alice, uuid=a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef)
to share here image (name=my-image) with Bob (login=bob,
uuid=b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4). Here "share" means adding Bob's
account UUID to the image's [acl](https://images.joyent.com/docs/#manifest-acl).


#### take 1: only support account UUIDs

Alice shares her image like this:

    $ triton image share my-image c6512b9a-7835-4fbe-bbfd-8ecb5a7881c4  # typo
    triton image share: error: account "c6512b9a-7835-4fbe-bbfd-8ecb5a7881c4" does not exist
    $ triton image share my-image b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4
    Image "my-image" shared with account "b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4"

And she can see with whom she has shared a given image something like this:

    $ triton image get my-image
    {
        "id": "0965c1f4-6995-c095-ecb5-c1a80be2b08e",
        "name": "my-image",
        "version": "1.0.0",
        "owner": "a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef",
        ...
        "acl": [
            "b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4"
        ]
    }

Then Bob can see the shared image via something like:

    $ triton image list --shared
    SHORTID   OWNER                                 NAME       VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef  my-image   1.0.0    S      smartos  zone-dataset  2017-10-17
    ...


Pros:
- This is very straightforward to implement and the implementation would be
  efficient because the semantics of sharing map directly to the current
  [`image.acl`](https://images.joyent.com/docs/#manifest-acl) behaviour.

Cons:
- Getting and recognizing Bob's account UUID could be a burden for Alice.
- Recognizing Alice's account UUID could be a burden for Bob.


#### take 2: attempting to support login names

It would be nice (for end users) if login names could be used instead (easy to
communicate, remember, recognize):

    $ triton image share my-image bob
    Image "my-image" shared with account "bob"

    $ triton image get my-image
    {
        "id": "0965c1f4-6995-c095-ecb5-c1a80be2b08e",
        "name": "my-image",
        "version": "1.0.0",
        "owner": "a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef",
        "owner_login": "alice",     // added this
        ...
        "shared_with": [            // not re-using "acl" for discussion
            "bob"
        ]
    }

    # Bob
    $ triton image list --shared
    SHORTID   OWNER_LOGIN  NAME       VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  alice        my-image   1.0.0    S      smartos  zone-dataset  2017-10-17
    ...

If Alice fat-fingers the account name:

    $ triton image share my-image bib
    triton image share: error: account "bib" does not exist

*Problem:* This error message gives end users a way to test if a given login
name exists. See [MANTA-3356](https://devhub.joyent.com/jira/browse/MANTA-3356)
for why we don't want to allow that.

A solution for this would be to not validate that given account login names
exist. Instead they are just stored as given.

    $ triton image share my-image bib
    Image "my-image" shared with account "bib"

    $ triton image get my-image
    {
        "id": "0965c1f4-6995-c095-ecb5-c1a80be2b08e",
        "name": "my-image",
        "version": "1.0.0",
        "owner": "a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef",
        "owner_login": "alice",     // added this
        ...
        "shared_with": [    // the "shared_with" field name is up for discussion
            "bob",
            "bib"
        ]
    }

Pros:
- More convenient for Alice and Bob.

Cons:
- Less straightforward to implement. However, I don't think it is super
  difficult.


Dev Notes:
- IMGAPI's acl handling could be updated to support account *login* rather than
  just UUID for `acl` valies. It would be a new v3 major API version, but we're
  already doing API versioning, so that should be fine.
- IMGAPI ListImages and GetImage for API v2 would elide the non-UUID entries
  of `image.acl`.
- CloudAPI GetImage and ListImages would add `owner_login`.
  Q: Do we add `owner_login="admin"` for admin-owned images? We already *do*
  expose the admin UUID with the `owner` field, FWIW.
- Decide on the "shared_with" field name. If it maps directly to what IMGAPI
  stores, then we could/should call it the same "acl" name.


### Appendix D: Old proposal for copying images x-DC that has IMGAPI talking to a remote CloudAPI

(This is an old proposal. After discussion, the suggestion was to pursue direct
IMGAPI-to-IMGAPI communication for transferring image data. For the current
design, see the Milestones section above.)

* * *

The feature is to pull/copy one's own custom image (named "my-image") from one
DC (us-sw-1) to another DC (us-west-1) in the same cloud.

    # Usage:       triton image pull SOURCE-DC IMAGE
    $ triton -p us-west-1 image pull us-sw-1   my-image
    Pulling image 0965c1f4 (my-image) from datacenter us-sw-1.
    [======>                ] ... progress ...

Per usual, the `triton` CLI provides the sugar to map "my-image" to the actual
image UUID.

* * *

Here is a proposed implementation plan for this. Names are all open for debate.
My main questions are whether my "Assumption"s are reasonable and if the
design seems sane.

- `triton image pull` calls `us-west-1 CloudAPI PullImageFromDc`
  and then maintains the connection and gets a stream of progress events
  until the pull is complete.

- `us-west-1 CloudAPI PullImageFromDc` passes on to its `IMGAPI PullImageFromDc`
  to handle the pull (i.e. the smarts are in IMGAPI).

The IMGAPI in the destination DC (us-west-1) gets the data it needs for the
image from the source DC's (us-sw-1) *CloudAPI* as follows:

- `us-west-1 IMGAPI PullImageFromDc` calls `us-sw-1 CloudAPI AdminGetImage`
  (not the existing GetImage) to get the full unadulterated image manifest. This
  call verifies the user owns the image and that the image is active. IMGAPI
  authenticates as "admin" using the "$dcName imgapi key", which is already on
  the admin user.

  **Assumption 1**: Within a cloud (shared UFDS), the IMGAPIs can reach the
  CloudAPI in the other clouds and can auth as "admin" on them.

- `us-west-1 IMGAPI PullImageFromDc` calls `us-sw-1 CloudAPI AdminGetImageFile`

    - `us-sw-1 CloudAPI AdminGetImageFile` calls its `IMGAPI
      CreateImageFilePullUrl` which will:

        - Create a snaplink of the image file to an export location in its
          Manta area. E.g.:

                mls /admin/stor/imgapi/us-sw-1/images/341/341ef22c-9b65-ecec-894a-ff8bb8133f77/file0 \
                    /admin/stor/imgapi/us-sw-1/pulls/20171023/341ef22c-9b65-ecec-894a-ff8bb8133f77.file0.$req_id

        - Create a signed URL (expiry <1d) to that pulls/... object and respond
          with that URL.

    - `us-sw-1 CloudAPI AdminGetImageFile` will then respond with an HTTP 307
      redirect to the signed pull URL.

    - `us-west-1 IMGAPI PullImageFromDc` will then:
        - If it notices that the Manta URL is the same as its Manta storage,
          attempt to `mln` that Manta object path. This is shortcut that will
          greatly benefit a setup like JPC. Otherwise,
        - download the image file from the signed URL

    **Assumption 2**: Within a cloud, the IMGAPIs can reach the Manta area of the
    other IMGAPIs.


Notes:

- This design requires that pulled images are stored in Manta. The feature is
  intended for end-user custom images, which are typically stored in Manta, so
  this should be fine. There is a "typically solely for development"
  option to [allow custom images without a
  Manta](https://github.com/joyent/sdc-imgapi/blob/master/docs/operator-guide.md#dc-mode-setup-enable-custom-image-creation-without-manta)
  but not production TritonDCs should be using this.
  `IMGAPI CreateImageFilePullUrl` will error out if the given image is not
  stored in Manta.

- If assumption #2 isn't true (IMGAPIs cannot reach the Manta area of other
  DCs) for a DC we need to support, then we could handle that as follows.
  Initially this work would be deferred.

    - `us-west-1 IMGAPI PullImageFromDc` would be configured to used a param
      to `us-sw-1 CloudAPI AdminGetImageFile` saying that redirects to its
      Manta are not supported.

    - `us-sw-1 CloudAPI AdminGetImageFile` would then stream the image file
      via its `IMGAPI GetImageFile`.

  Similarly, if a source DC knows that its Manta won't be externally accessible,
  it can configure its `CloudAPI AdminGetImageFile` to always stream the image
  file.

- IMGAPI will need a reaper that cleans up $mantaArea/pulls/$day for days more
  than 2 days old.


* * *

Sequence diagram for <https://bramp.github.io/js-sequence-diagrams/>
See it rendered here: <https://gist.github.com/trentm/b02c6977c2cacfdb580a2b3c09fcf3a5>

    # for https://bramp.github.io/js-sequence-diagrams/

    title: Proposal for `triton image pull`

    Note right of "triton image pull":*the INTERNET*

    "triton image pull"->"us-west-1 CloudAPI":PullImageFromDc

    "us-west-1 CloudAPI"->"us-west-1 IMGAPI":PullImageFromDc

    Note right of "us-west-1 IMGAPI":*cross-DC network*

    "us-west-1 IMGAPI"->"us-sw-1 CloudAPI":AdminGetImage
    "us-sw-1 CloudAPI"-->"us-west-1 IMGAPI":image manifest
    "us-west-1 IMGAPI"-->"triton image pull":{progress}

    "us-west-1 IMGAPI"->"us-sw-1 CloudAPI":AdminGetImageFile
    "us-sw-1 CloudAPI"->"us-sw-1 IMGAPI":CreateImageFilePullUrl
    "us-sw-1 IMGAPI"-->"us-sw-1 CloudAPI":signed pull URL

    "us-sw-1 CloudAPI"-->"us-west-1 IMGAPI":HTTP 307 to signed pull URL
    Note over "us-west-1 IMGAPI":mln or download pull URL
    "us-west-1 IMGAPI"-->"triton image pull":{progress}


### Appendix E: 'copy' or 'pull' language?

    triton pull REPO:IMAGE
    triton pull DC IMAGE

    sdc-imgadm import -S REPO IMAGE

"Pull" intuition is about pulling from some external repository. When I'm
making my image available throughout the same cloud... it feels less like a
"pull" and more like "scp", i.e. "copy". Sync?  AWS lang is copy, so use that.

Answer: copy
