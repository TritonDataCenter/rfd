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

Alice copying image from us-sw-1 to us-west-1:

    [alice]$ triton -p us-west-1 image cp us-sw-1 my-image
    Copying image 0965c1f4 (my-image) from datacenter us-sw-1.
    [======>                ] ... progress ...

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





Dev Notes:

- must handle origin images... does this have a confirmation? Perhaps just
  client side? Meh. Adding `triton img ancestry IMG` might be nice to
  be able to predict.
  Could punt origin chain for M0.
- it would be *really* good if this could share the same "import from IMGAPI"
  (e.g. images.jo) code in IMGAPI already
- think about failed file transfer
- think about retry
- think about concurrent attempts
- think about DeleteImage on the src DC during the copy
- `triton image cp`:
    - fwrule updates for IMGAPI zones, which typically drop in-bound requests.
    - Would want 'sdcadm post-setup' command to assist with linking IMGAPIs.
      Would we re-use the '$dc imgapi key'? Probably piggyback on that, yes.
    - `triton image cp` is short for `triton image copy-from-dc` perhaps
    - What's the progress mechanism? Meta info on the placeholder image?
    - If have state=copying (see below), then `triton image wait IMAGE` would
      be useful for resuming waiting for a copy in progress.
    - Have state=copying (or similar) for images that are being copied, and
      then "ActivateImage" (again?) to make it active when done importing the file?
    - On error: ensure a state="copying/failed" image doesn't interfere with a retry.
    - Note image *icon* limitation for starters.
- Per <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/CopyingAMIs.html#copy-amis-across-regions>
  note that one can "recopy" if there were image changes (for us that would
  just be mutable manifest changes).


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



## Scratch

### Open Qs and TODOs

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


### Old proposal for copying images x-DC that has IMGAPI talking to a remote CloudAPI

This is an old proposal. After discussion, the suggestion was to pursue direct
IMGAPI-to-IMGAPI communication for transferring image data. For the current
design, see M0.

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

```
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
```

### Out of scope

From [discussion](https://github.com/joyent/rfd/issues/71), some related
potential features are determined to be out of scope for this RFD.

- Transferring *ownership* of an image to another account: not needed based
  on review of competitors ...
  ([discussion](https://github.com/joyent/rfd/issues/71#issuecomment-337149084)).
- Nice to have: `triton image clone` so Bob can create a personal (owned)
  copy of Alice's shared image? That way he can be confident it won't be
  deleted out from under him if Alice deletes the image.


### 'copy' or 'pull' language?

Answer: copy

    triton pull REPO:IMAGE
    triton pull DC IMAGE

    sdc-imgadm import -S REPO IMAGE

"Pull" intuition is about pulling from some external repository. When I'm
making my image available throughout the same cloud... it feels less like a
"pull" and more like "scp", i.e. "copy". Sync?  AWS lang is copy, so use that.
