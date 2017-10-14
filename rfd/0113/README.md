---
authors: Trent Mick <trent.mick@joyent.com>
state: predraft
---

# RFD 113 Triton custom image sharing, transfering, and x-DC copying

The following details a proposal for new IMGAPI, CloudAPI, and node-triton
functionality to make the following improvements to Triton custom images:

- allow sharing a custom image with other accounts;
- allow transferring ownership of an image to another account;
- allow copying one's own custom images from another DC within the same cloud.

Alternative proposals are welcome!


<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Status](#status)
- [Background](#background)
- [tl;dr](#tldr)
- [M0: share an image with other accounts](#m0-share-an-image-with-other-accounts)
- [M1: transfer ownership of an image to another account](#m1-transfer-ownership-of-an-image-to-another-account)
- [M2: copying a custom image from another DC](#m2-copying-a-custom-image-from-another-dc)
- [Open Qs and TODOs](#open-qs-and-todos)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status

See [RFD-113 labelled issues](https://devhub.joyent.com/jira/issues/?jql=labels%3DRFD-113).
Still in earlier discussions.


## Background

Note that currently in IMGAPI:

- There is a single image `owner` (and account UUID). This account has full
  control over the image: UpdateImage, DeleteImage, provisioning, etc.
- There is an optional set of other accounts on the image `acl` (access control
  list). Accounts on the `acl` for an image can *use* the image (GetImage,
  ListImages, provisioning) but cannot modify or delete the image.

Here is a scenario that Angela and I discussed that motivated part of the
proposal below. Say there are three accounts: Eng (builds the images), QA
(approves the images for prod), and Ops (deploys images in prod). When Eng
builds an image and QA starts evaluating it, it would be good if QA could assume
full control of the image. Likewise when Ops starts using the image in prod, it
should have full control of the image so that, e.g., someone in Eng cannot
delete the image that is in use.


## tl;dr

Alice sharing an image with Carl:

    [alice]$ triton image share my-awesome-image carl

    [carl]$ triton image offer ls
    ID        FROM   ACTION  IMAGE                              EXPIRES
    9dce1460  alice  share   060fda88 (my-awesome-image@1.2.3)  2017-10-14T03:17:55

    [carl]$ triton image offer accept 9dce1460

Alice transfering ownership to Bob:

    [alice]$ triton image transfer my-awesome-image bob

    [bob]$ triton image offer ls
    ID        FROM   ACTION    IMAGE                              EXPIRES
    c2972170  alice  transfer  060fda88 (my-awesome-image@1.2.3)  2017-10-14T03:17:55

    [bob]$ triton image offer accept c2972170

Bob copying image from us-sw-1 to us-west-1

    #      triton               image cp  DC      IMAGE
    [bob]$ triton -p us-west-1  image cp  us-sw-1 my-awesome-image



## M0: share an image with other accounts

We expose the ability to share a custom image with other accounts, while
retaining ownership. Here "share" means read-only access to the image --
GetImage, ListImages, provisioning. We say "expose" because this is what
`image.acl` provides.

We felt it was necessary that the target account must explicitly take an
action to be added to an image.acl. Otherwise an attacker could create a
custom image named after Joyent-provided images (e.g. minimal-multiarch-lts)
and add target accounts to the ACL. Then the attacker would hope that one of
those target accounts would `triton inst create minimal-multiarch-lts ...`
and unintentionally get the attacker's image.

The proposal is to handle this via "offers". (Suggestions for better naming
are welcome.)

First Alice offers to share her image with Carl and Deena. She needs to know
their account login names.

    # triton image share IMAGE ACCOUNT...
    [alice]$ triton image share my-awesome-image carl deena
    Created offer (9dce1460) to share image 060fda88 with "carl" (expires 2017-10-14T03:17:55)
    Created offer (c2972170) to share image 060fda88 with "deena" (expires 2017-10-14T03:17:55)

Then Carl can accept:

    [carl]$ triton image offer ls
    ID        FROM   ACTION  IMAGE                              EXPIRES
    9dce1460  alice  share   060fda88 (my-awesome-image@1.2.3)  2017-10-14T03:17:55

    [carl]$ triton image offer accept -y 9dce1460
    Accepting image share offer for image 060fda88 from alice.
    Account carl can now use image 060fda88 (my-awesome-image@1.2.3).

Carl is added to `image.acl`.

Dev Notes:
- Offers expire after a day by default. No strong reason for that expiry,
  other than I think they *should* expire. FWIW, GitHub repo transfer offers
  expire after a day.
- Offers should not expose account UUIDs.
- Offers should not expose whether those accounts exist. I.e. the offers are
  accepted whether the target account exists or not.
- Have a `-j` option to emit structured JSON objects for the offer objects.
- Would be nice if default output lines are <80 chars.


## M1: transfer ownership of an image to another account

We add the ability to *transfer ownership* of an image to another account.
First the current owner of the image initiates a transfer:

    [alice]$ triton image transfer my-awesome-image bob

This creates an "offer to transfer" ownership of the image to account `bob`.
Bob must then *accept or decline the offer*:

    [bob]$ triton image offer ls            # list current image offers
    ID        FROM   ACTION     IMAGE                              EXPIRES
    a8f9e18f  alice  ownership  060fda88 (my-awesome-image@1.2.3)  2017-10-14T03:17:55

    [bob]$ triton image offer accept -y a8f9e18f
    Accepting image ownership offer for image 060fda88 from alice.
    Account bob now owns image 060fda88 (my-awesome-image@1.2.3).

This results in two things:

1. Bob is made `image.owner` (affording full control over the image), and
2. Alice is added to `image.acl` (so Alice can still see and provision with
   the image).

Note: The concept of transferring ownership of a Triton object could be
extended to VMs, volumes, etc. but that is out of scope here. I don't
believe I've proposed anything that gets in the way of doing it later.


## M2: copying a custom image from another DC

We add the ability for an account to copy one's custom image from another
DC in the same cloud (i.e. sharing a UFDS account database).

    [alice]$ triton datacenters
    NAME       URL
    eu-ams-1   https://eu-ams-1.api.joyentcloud.com
    us-east-1  https://us-east-1.api.joyentcloud.com
    us-sw-1    https://us-sw-1.api.joyentcloud.com
    ...

    [alice]$ triton image cp us-sw-1 my-awesome-image
    Copying image 060fda88 (my-awesome-image) from datacenter us-sw-1.
    [======>                ] ... progress ...

Implementation notes:

- `triton image cp ...` calls CloudAPI CopyImageFromDc, which calls
  IMGAPI CopyImageFromDc, which does:
    - calls source IMGAPI GetImage,
    - validates perms to copy the image,
    - creates a placeholder image object with state=copying,
    - streams the image file from source IMGAPI GetImageFile,
    - activates the image.
- IMGAPI is configured with the name-to-host mapping (including info like
  tls_insecure=true) for the IMGAPI in each other DC. Perhaps this could be
  made available via UFDS to avoid operators having to deal with this, or via
  a 'sdcadm ...' command to help.
- Each IMGAPI in the cloud must be able to talk to the other IMGAPIs, whether
  that is by IP or (preferably) via cross-DC DNS. This means, in general, the
  DC's IMGAPI needs to use TLS and http-sig auth, as the public IMGAPIs
  (images.jo, updates.jo) already do. I'm not sure if certs are a potential
  problem here.

Q: Can we avoid exposing the IMGAPIs to the other DCs? What if the target IMGAPI
talked only to the CloudAPI of the source DC. It uses CloudAPI GetImage and
CloudAPI GetImageFile (new) to stream out the file. This would require the
target IMGAPI authenticating as the user's account or as 'admin'. I think that
is less new work, but I'm not positive the auth story is a good thing. Does
authenticating as the user like this pose a problem for RBACv2 design? E.g.
what if it a subuser calling? Or is it a good/bad idea to have admin from a DC
authenticating as 'admin' on another DC's cloudapi? Perhaps no worse than:
    triton -a admin --act-as $user image get IMAGE
What key setup is required for this? Perhaps less than for IMGAPI-to-IMGAPI
communication.


## Open Qs and TODOs

- `triton image cp`:
    - fwrule updates for IMGAPI zones, which typically drop in-bound requests.
    - Would want 'sdcadm post-setup' command to assist with linking IMGAPIs.
      Would we re-use the '$dc imgapi key'? Probably piggyback on that, yes.
    - `triton image cp` is short for `triton image copy-from-dc` perhaps
    - What's the progress mechanism? Meta info on the placeholder image?
    - If have state=copying (see below), then `triton image wait IMAGE` would
      be useful for resuming waiting for a copy in progress.
    - Could call this "PullImage"? `triton image pull us-sw-1 my-awesome-image`
      Wary of getting in the way of pulling non-ZFS (security) images from
      public repos (a la docker pull).
    - Have state=copying (or similar) for images that are being copied, and
      then "ActivateImage" (again?) to make it active when done importing the file?
    - On error: ensure a state="copying/failed" image doesn't interfere with a retry.
    - Note image *icon* limitation for starters.
- Per <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/CopyingAMIs.html#copy-amis-across-regions>
  note that one can "recopy" if there were image changes (for us that would
  just be mutable manifest changes).
- Accepting a transfer of ownership should invalidate offers to share/use/read
  the image? Or that could be handled at 'accept' time: if the current owner
  isn't the account that originally offered, then it fails.
- Cannot have multiple offers of transfer at the same time.
- Nice to have: `triton image clone` so Carl can create a personal (owned)
  copy of Alice's shared image? That way he can be confident it won't be
  deleted out from under him if Alice deletes the image.
