---
authors: Trent Mick <trent.mick@joyent.com>, Todd Whiteman
state: publish
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+113%22
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


- [Motivation](#motivation)
- [Related discussions](#related-discussions)
- [IMGAPI refresher](#imgapi-refresher)
- [Example](#example)
  - [Image sharing](#image-sharing)
  - [Image cloning](#image-cloning)
  - [Image coping across DCs](#image-coping-across-dcs)
- [Design discussion](#design-discussion)
  - [x-account image clone](#x-account-image-clone)
  - [x-DC image copy](#x-dc-image-copy)
- [Milestones](#milestones)
  - [M1: x-account image share](#m1-x-account-image-share)
  - [M2: x-account image clone](#m2-x-account-image-clone)
  - [M3: x-DC image copy](#m3-x-dc-image-copy)

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

- [The discussion on GitHub](https://github.com/TritonDataCenter/rfd/issues/71)
- [Some internal discussion](https://mnx.atlassian.net/browse/SWSUP-903)
- [RFD-113 labelled issues](https://mnx.atlassian.net/issues/?jql=labels%3DRFD-113).


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

### Image sharing

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

### Image cloning

Bob can clone Alice's shared image into his own account, which gives Bob full
control over the image.

    [bob]$ triton image clone my-image
    Cloned image id: 0965c1f4-6995-c095-ecb5-c1a80be2b08e

The cloned image has a different id and is the original image is no longer
shared with Bob.

    [bob]$ triton image list
    SHORTID   NAME      VERSION  FLAGS   OS       TYPE          PUBDATE
    0965c1f4  my-image  1.2.3            smartos  zone-dataset  2017-10-17

### Image coping across DCs

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

#### x-DC config

To be able to use x-DC image copying, each datacenter must have SAPI
configuration, which will specify the IMGAPI endpoints that a datacenter is
allowed to copy into.

The configuration will be a JSON object, which contains a mapping of the dc
short name or the IMGAPI **admin** url where IMGAPI is listening. Note that the
short dc name should match what us shown via:
[CloudAPI ListDatacenters](https://apidocs.tritondatacenter.com/cloudapi/#ListDatacenters).

For example, to allow us-east-1 to copy images into both us-sw-1 and us-west-1
you would run the following SAPI configuration command:

    $ login to us-east-1 headnode
    $ SAPI_IMGAPI_UUID=$(sdc-sapi /services?name=imgapi | json -Hga uuid)
    $ echo '{ "metadata": { "IMGAPI_URL_FROM_DATACENTER": { "us-sw-1": "http://10.2.15.22", "us-west-1": "http://10.2.18.8" }}}' | \
        sapiadm update "$SAPI_IMGAPI_UUID"

Then restart config-agent in the imgapi zone (or wait until imgapi notices the
config has changed, at which point imgapi will then restart itself).

## Milestones

### M1: x-account image share

<https://mnx.atlassian.net/browse/TRITON-116>

- `triton image share $image $account` new command in node-triton.
    - This command uses the existing CloudAPI.UpdateImage API to add the given
      account uuid to the image ACL list.
- `triton images` grows support to show shared images.
    - Node-triton will use 'S' flag to mark shared images.

#### API and Triton CLI changes

- CloudAPI already has the [UpdateImage](https://apidocs.tritondatacenter.com/cloudapi/#UpdateImage)
  endpoint, which can be used to update the image ACL.
- Triton CLI will gain the `triton image share` command.


### M2: x-account image clone

<https://mnx.atlassian.net/browse/TRITON-53>

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

#### API and Triton CLI changes

- CloudAPI will gain the [CloneImage](https://apidocs.tritondatacenter.com/cloudapi/#CloneImage)
  endpoint, which can be used to make a copy of an existing shared image.
- Triton CLI will gain the `triton image clone` command.


### M3: x-DC image copy

<https://mnx.atlassian.net/browse/TRITON-52>

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
- Note that re-import of an image is not supported (a user can delete and
  re-import), it may be nice in the future to allow re-importing in case a
  user just wants to update a part of the image (or image metadata) in one
  DC and populate that change everywhere.

#### API and Triton CLI changes

- CloudAPI will gain the [ImportImageFromDatacenter](https://apidocs.tritondatacenter.com/cloudapi/#ImportImageFromDatacenter)
  endpoint, which can be used to import an image into another datacenter.
- Triton CLI will gain the `triton image copy` command.
