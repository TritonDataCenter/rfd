---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+113%22
---

# RFD 113 Triton custom image sharing and x-DC copying

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
- [Milestones](#milestones)
  - [M0: copying an image from another DC](#m0-copying-an-image-from-another-dc)
  - [M1: share an image with other accounts](#m1-share-an-image-with-other-accounts)
- [Scratch](#scratch)
  - [Open Qs and TODOs](#open-qs-and-todos)
  - [Trent's scratch area](#trents-scratch-area)
- [Appendices](#appendices)
  - [Sharing using account *login* or *uuid*?](#sharing-using-account-login-or-uuid)
  - [Out of scope](#out-of-scope)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status

Still in design discussions. See:

- [The discussion on GitHub](https://github.com/joyent/rfd/issues/71)
- [Some internal discussion](https://devhub.joyent.com/jira/browse/SWSUP-903)
- [RFD-113 labelled issues](https://devhub.joyent.com/jira/issues/?jql=labels%3DRFD-113).


## Background

Note that currently in IMGAPI:

- There is a single image `owner` (and account UUID). This account has full
  control over the image: UpdateImage, DeleteImage, provisioning, etc.
- There is an optional set of other accounts on the image `acl` (access control
  list). Accounts on the `acl` for an image can *use* the image (GetImage,
  ListImages, provisioning) but cannot modify or delete the image.

Our scenario for examples below:

- Alice (login=alice, uuid=a45c9276-b8e1-11e7-90b1-6fc7cbadf3ef) has an
  image "my-image" built in DC "us-sw-1".
- Bob (login=bob, uuid=b6512b9a-7835-4fbe-bbfd-8ecb5a7881c4).


## tl;dr

Alice sharing an image with Bob:

    [alice]$ triton image share my-image bob
    [alice]$ triton image get my-image
    {
        "id": "0965c1f4-6995-c095-ecb5-c1a80be2b08e",
        "name": "my-image",
        ...
        "shared_with": [        // "shared_with" name still up for discussion
            "bob"
        ]
    }

    [bob]$ triton image list --shared
    SHORTID   OWNER_LOGIN  NAME       VERSION  FLAGS  OS       TYPE          PUBDATE
    0965c1f4  alice        my-image   1.0.0    S      smartos  zone-dataset  2017-10-17
    ...

Alice copying image from us-sw-1 to us-west-1:

    [alice]$ triton -p us-west-1 image cp us-sw-1 my-image
    Copying image 0965c1f4 (my-image) from datacenter us-sw-1.
    [======>                ] ... progress ...


## Milestones

### M0: copying an image from another DC

We add the ability for an account to copy **one's own custom images** from
another DC in the same cloud (i.e. sharing an account database).

    [alice]$ triton datacenters
    NAME       URL
    eu-ams-1   https://eu-ams-1.api.joyentcloud.com
    us-east-1  https://us-east-1.api.joyentcloud.com
    us-sw-1    https://us-sw-1.api.joyentcloud.com
    ...

    [alice]$ triton image cp us-sw-1 my-image
    Copying image 0965c1f4 (my-image) from datacenter us-sw-1.
    [======>                ] ... progress ...



Implementation notes:
- `triton image cp ...` calls CloudAPI CopyImageFromDc which streams back
  progress (perhaps after 100-Continue and then chunked).
- TODO(trent): finish next section for implementation ideas


#### IMGAPI-to-IMGAPI or target cloudapi pulls?

An IMGAPI-to-IMGAPI implementation:

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

A "target cloudapi pulls" implementation:

Q: Can we avoid exposing the IMGAPIs to the other DCs? What if the target IMGAPI
talked only to the CloudAPI of the source DC. It uses CloudAPI GetImage and
CloudAPI GetImageFile (new) to stream out the file. This would require the
target IMGAPI authenticating as the user's account or as 'admin'. I think that
is less new work, but I'm not positive the auth story is a good thing. Does
authenticating as the user like this pose a problem for RBACv2 design? E.g.
what if it a subuser calling? Or is it a good/bad idea to have admin from a DC
authenticating as 'admin' on another DC's cloudapi? Perhaps no worse than:
`triton -a admin --act-as $user image get IMAGE`. What key setup is required for
this? Perhaps less than for IMGAPI-to-IMGAPI communication.

Can we also get benefit of shared Manta to avoid streaming of the whole image
file? Does this method give up potential for a higher BW internal-DC-to-DC link?


### M1: share an image with other accounts

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

- Still need to spec how to deal with treating shares images separately from
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



## Scratch

### Open Qs and TODOs

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
- Nice to have: `triton image clone` so Carl can create a personal (owned)
  copy of Alice's shared image? That way he can be confident it won't be
  deleted out from under him if Alice deletes the image.


### Trent's scratch area

(If you aren't Trent, you can ignore all this.)


    triton imgs           # public and images I own
    triton imgs -a|-all   # includes inactive image (state=all)

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

### Sharing using account *login* or *uuid*?

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


### Out of scope

From [discussion](https://github.com/joyent/rfd/issues/71), some related
potential features are determined to be out of scope for this RFD.

- Transferring *ownership* of an image to another account: not neede based
  on review of competitors ...
  ([discussion](https://github.com/joyent/rfd/issues/71#issuecomment-337149084)).
- Nice to have: `triton image clone` so Bob can create a personal (owned)
  copy of Alice's shared image? That way he can be confident it won't be
  deleted out from under him if Alice deletes the image.
