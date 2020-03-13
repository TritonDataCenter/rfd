---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: abandoned
discussion: https://github.com/joyent/rfd/issues/135
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->


# RFD 171 A Proposal for Manta SnapLinks

## Abandonment

This proposal has been abandoned and only remains here for historical reasons.

## Summary

SnapLinks as they exist now are problematic for garbage collection and
rebalancing. They also cause scaling problems as some operations require knowing
the state on *all* shards at a single point in time since links can be anywhere.

This document proposes a solution that would allow the functionality of
SnapLinks to maintained, but in a manner that removes the need for crossing
shards.


## Very Brief Overview of Snaplinks

[SnapLinks](https://apidocs.joyent.com/manta/#snaplinks) allow Manta customers
to create a new name to an existing object in manta. Similar to how hard links
work in UNIX and UNIX-like systems.

In order to make a SnapLink to an existing object, one calls the
[PutSnapLink](https://github.com/joyent/manta-muskie/blob/master/docs/index.md#putsnaplink-put-loginstordirectorylink)
endpoint on muskie:

```
PUT /:login/stor/[:directory]/:link
```

with this request, the caller includes a:

```
Location: /:login/stor/[:directory]/:object
```

header which specifies the "source" object (the object to which a new link will
be created), and a:

```
content-type: application/json; type=link
```

header which indicates that what we're PUTing is a SnapLink.

In [muskie](https://github.com/joyent/manta-muskie/) the code that handles this
operation is in [the
link.putLinkHandler](https://github.com/joyent/manta-muskie/blob/810d30f043a3c3ee5717146fe7bbb85484cfe0ef/lib/link.js#L242-L257)
function.

This will:

 * Check that the account of the target owner does not have SnapLinks disabled.
 * Ensure the target is not not a root directory.
 * Ensure the target is not a directory at all.
 * Ensure the parent directories exist for the target object.
 * Parse the Location header looking for all the "special" directories (public,
   stor, jobs, reports) and figure out the sub-path and the owner/login and
   directory.
 * Figure out from the Location's "login" who the owner is of the "source" link
   (using mahi).
 * Ensure the owner of the source object has SnapLinks enabled.
 * Load the metadata of the source object and ensure it's a valid object.
 * Ensure the caller has access to "GetObject" the object they're trying to
   create a SnapLink to.
 * Create a new metadata object (one that will go in the manta bucket) with all
   the parameters set appropriately, and the "link" metadata.
 * Put the new metadata object into Moray.

At this point we'll have an additional pointer in the `manta` bucket on the
target shard, to the same on-disk set of objects as existed in the source
metadata object on its shard.


## Uses for SnapLinks

One of the common use-cases for SnapLinks is to "move" files. Since there is no
`mmv` command, and no way to actually rename an object, it is possible to create
a new SnapLink to an object and then remove the original object.

Another use for SnapLinks is for versioning to create a "latest" file or similar
which can be replaced with a different target allowing clients to use a single
target to represent different versions over time.

Both of these use-cases are preserved with this proposal.


## Relevant Problems with SnapLinks

### Garbage Collection

There is discussion in [RFD
123](https://github.com/joyent/rfd/blob/master/rfd/0123/README.md#snap-links)
and [RFD 143](https://github.com/joyent/rfd/blob/master/rfd/0143/README.md)
about SnapLinks and workarounds proposed (some of which have been made) to deal
with the fact that SnapLinks don't work well with the [old garbage collection
system](https://github.com/joyent/manta/blob/mantav1/docs/operator-guide.md#garbage-collection-auditing-and-metering)
(that uses `manta_delete_log`). There's also discussion in [this
document](https://github.com/joyent/manta-mola/blob/master/docs/gc-design-alternatives.md)
of problems including ["The Walking Link
Problem"](https://github.com/joyent/manta-mola/blob/master/docs/gc-design-alternatives.md#the-walking-link-problem)
which is a theoretical problem that's solely due to the design here where links
share object ids between source and target.

The "old" garbage collection system with `manta_delete_log` relied on being able
to take a snapshot of the entire system (all shards) at a point in time, though
this is not actually possible and therefore we need to deal with the "Walking
Link Problem". Looking at all shards was required because when an object was
deleted and added to the `manta_delete_log`, it could not *actually* be cleaned
up until we were sure that there were no SnapLinks on *any* shard that still
referenced that object.

The current system in production avoids problems with SnapLinks and Garbage
Collection only by not using SnapLinks for accounts that need garbage collected.
For all other accounts, garbage collection is disabled and when objects are
deleted from the metadata tier, they remain on disk in the mako/storage zones.


### Rebalancing

[RFD 162](https://github.com/joyent/rfd/blob/master/rfd/0162/README.md) and
other discussion of rebalancing have also necessarily been required to talk
about SnapLinks. The reason here is that if we have multiple pointers in the
metadata tier to the same objects on the makos, we need to update *all* of those
pointers (potentially on multiple or even all shards) at once in order to
actually move the storage.

This becomes complicated very quickly if an object has 10 SnapLinks, we
potentially need to update 10 different shards before we can completely move an
object from one mako/storage zone to another.


### Observations

These problems occur because we have two different links potentially in
different shards to the same object id on the makos. If we had different object
ids when we create a SnapLink, neither rebalancing nor garbage collection would
need to concern themselves with what might be going on in more than one shard
for a given metadata object.

SnapLinks as implemented now seem to be a poor fit for a system intending to
scale as operations on them do not allow horizontal scaling. Any operation that
must know about SnapLinks needs to communicate with *all* shards for any
such operation.


## Proposed Solution

Instead of completely eliminating SnapLinks, (which would also solve the scaling
problems) this document proposes a change to the implementation of SnapLinks
that allows them to be scalable and removes the need for either Garbage
Collection or Rebalancing to be concerned with them at all. In fact, with this
proposal implemented, nothing should need to ever scan all shards for multiple
links to the same object.

The crux of the solution is to change SnapLinks such that they are implemented
in terms of actual hard links on the mako, giving each new SnapLink an
additional hard link to the same file(s) on disk.

How this is proposed to work is:

 * Everything in Muskie's putLinkHandler ([described
   above](#very-brief-overview-of-snaplinks)) works as now up to the point where
   we've validated the source is a valid object and are about to create the new
   metadata object.

 * At that point, instead of just inserting a new entry pointing to the *same*
   object uuids, we will generate a new object uuid for the new link.

 * A call will be made to the "sharks" (mako/storage zones) that house the
   original object and each of these will create a new directory if required (if
   the target is an owner who has no objects on this node) and then link(source,
   target) the file.

 * Once the new link is created, the new metadata object is created with the
   differences from the original object being a new object uuid and path and
   potentially a new owner.

 * The new record will be put into the `manta` bucket as is done now.

With this change, no entries in `manta` will have the same object uuid. After
this:

 * When we delete an object from `manta`, we know we can always put it into the
   `manta_fastdelete_queue` and actually delete the object from disk. We do not
   need to check any other shards or metadata objects. The code for
   non-accelerated GC (using the `manta_delete_log` bucket) and all the code for
   per-account SnapLink disabling can be removed.

 * When we want to rebalance an object, each "link" to that object will be
   handled independently without need for the rebalancer to be concerned with
   the relationship. If you create a link to an object, then repair/rebalance
   that new object, or want to increase the number of copies of that object,
   you can do so independently of the original object.

 * SnapLinks become more like \*NIX hard links in that they're not
   distinguishable by most things from other files. We could also consider
   removing the special "link" properties and type.

 * There is no "Walking Link Problem".

 * Since objects in Manta are immutable, we do not need to worry about problems
   when there are two hard links to the same object and writing to one
   unintentially modifies the other.

 * We've changed an O(n) operation into an O(1) operation which brings the
   system closer to the [stated design
   principle](https://github.com/joyent/manta/#design-principles) of scaling
   horizontally in "every dimension".

## Other Considerations

### Buckets

Based on the author's current understanding, this should not really have much
impact on [RFD 155
buckets](https://github.com/joyent/rfd/blob/master/rfd/0155/README.md).

The current plan as listed in that RFD is to not support SnapLinks for now
anyway.

However, since the object storage with buckets works the same (just the data is
organized differently in the metadata tier), it seems as though it should be
straight-forward to have SnapLinks as proposed here also work with buckets if we
decide we want them in the future.


## Visible Changes

The primary changes here as far as other components are concerned would be:

 * Files under `/manta/<creatorID>/<objectId>` in storage zones might have
   multiple links.
 * In the metadata tier, each object will have its own ObjectId.
 * There will be an additional interface on the mako for creating a link which
   will be used by muskie/webapi.
 * ETag for a HEAD/GET on a SnapLink target object would be different from the
   source due to the separate ObjectIds (though this is not necessary, see below)


### Billing

It was [pointed out in the GH
issue](https://github.com/joyent/rfd/issues/135#issuecomment-500566030) that
customers that use the Manta job-based billing are [not charged for space used
by secondary links to their
objects](https://github.com/joyent/manta-mackerel/blob/6e55545e6040a3270dd4b8c9ac83d41d4201d41f/assets/lib/storage-reduce1.js#L142-L150).
If we wanted to keep this behavior, we'd need some mechanism to identify links
at the point where billing reports are generated.

However, it was subsequently pointed out that there were going to be big billing
changes in the near future, and that billing should not be part of the scope of
this discussion.


### ETags

[A question was raised about ETags](https://github.com/joyent/rfd/issues/135#issuecomment-501367643)

Currently when you create a SnapLink, in moray the two links will have
different `_etag` values in Moray:

```
moray=# select objectid,_etag From manta where dirname = '/96c4ecc0-89aa-4e15-958f-3f50d5e2a68b/public';
               objectid               |  _etag
--------------------------------------+----------
 09241c22-8da6-c142-d515-e1bb0aab703f | 52D3803A
 09241c22-8da6-c142-d515-e1bb0aab703f | A7100205
(2 rows)

moray=#
```

However looking at these same two objects with minfo we see instead:

```
$ minfo ~~/public/plugin.c
HTTP/1.1 200 OK
etag: 09241c22-8da6-c142-d515-e1bb0aab703f
last-modified: Wed, 12 Jun 2019 17:59:57 GMT
access-control-allow-origin: *
durability-level: 2
content-length: 5110
content-md5: U7C89aOfz3X1Gap/uP4C2w==
content-type: text/x-c
date: Wed, 12 Jun 2019 18:06:50 GMT
server: Manta
x-request-id: 3d225429-ae36-446b-bbc3-245e21abf011
x-response-time: 167
x-server-name: 4e32fe68-774b-4a58-9731-ad452e641cd8
connection: keep-alive
x-request-received: 1560362810063
x-request-processing-time: 237

$ minfo ~~/public/plugin2.c
HTTP/1.1 200 OK
etag: 09241c22-8da6-c142-d515-e1bb0aab703f
last-modified: Wed, 12 Jun 2019 18:00:05 GMT
access-control-allow-origin: *
durability-level: 2
content-length: 5110
content-md5: U7C89aOfz3X1Gap/uP4C2w==
content-type: text/x-c
date: Wed, 12 Jun 2019 18:07:02 GMT
server: Manta
x-request-id: 8d642694-64f9-4499-b00d-ab9de1b8b17b
x-response-time: 145
x-server-name: 4e32fe68-774b-4a58-9731-ad452e641cd8
connection: keep-alive
x-request-received: 1560362822628
x-request-processing-time: 183
```

So we're not getting the `_etag` value from the database. Instead we're using
the objectId as the `etag:` value.

At the time of this writing none of:

 * [The Manta API Documentation](https://apidocs.joyent.com/manta/api.html)
 * [The Node SDK Documentation](https://apidocs.joyent.com/manta/nodesdk.html)
 * [The java-manta-client Documentation](https://javadoc.io/doc/com.joyent.manta/java-manta-client/3.4.0)

appears to define `HEAD` requests at all (what minfo uses), nor do they define
semantics around ETags for HEAD/GET on objects. As such it seems any existing
client that does depend on the current semantics is relying on undocumented
behavior, so it is unclear what might break if suddenly the `etag:` header for a
linked object now has a different UUID (the UUID of the new object) where
previously a link had the same UUID.

With [Buckets](https://github.com/joyent/rfd/blob/master/rfd/0155/README.md) I
have been informed that we are also going to be using the objectId as the etag.
So this would at least be consistent.

[The discussion in the GH
issue](https://github.com/joyent/rfd/issues/135#issuecomment-501394987) suggests
that the intention here was for the ETag to indicate when: "two objects refer
not just to the same contents but the same instance of uploading those contents
-- even across snaplinks". In that case, it seems that it would be correct for
us to be having different `etag:` values for separated links since these two are
now independent instances of the object.

As an option, in order to make this match the previous behavior we could combine
this with the field mentioned in the "Identifying Links" section below, and have
muskie return (pseudocode):

```
headers.etag = originalObjectId || objectId
```

instead of setting the etag to the objectId for SnapLinks. If we decide this is
critical.

#### Additional Concerns with ETags and Upgrades

It [was raised](https://github.com/joyent/rfd/issues/135#issuecomment-501458279)
that when we are doing the upgrade from old SnapLinks (same objectId) to new
SnapLinks (different objectIds), that if someone did a GET or HEAD call before
the upgrade and stored that ETag somewhere for the duration of the upgrade and
then did another GET or HEAD after the upgrade, they'd see a different ETag and
it's possible something they are doing would be confused by this.

This would not be a problem if we set the ETag to the originalObjectId as
described above as an option.

### Capacity Questions

Several [issues related to capacity](https://github.com/joyent/rfd/issues/135#issuecomment-501458279)
were raised in the discussion issue. This section attempts to summarize those.

#### Additional Usage Due to Rebalance

When SnapLinks have been created, and a rebalance occurs it's possible for
rebalanced objects to no longer be on the same storage zone (shark/mako). In
this case the physical usage of the entire Manta system would be increased by
the size of the objects that were moved to new storage zones.

With large objects it has been posited that this could surprise operators. It's
also the case that if a manta is full, it might not be possible to do
rebalancing since we'd need to have room for the new objects on the target and
we should make sure this behavior is clear.

#### Creating SnapLinks on "full" Storage Zones

We set a limit on the utilization of a zpool for storage zones. If we're at that
limit what should we do when someone tries to SnapLink an object that lives on
that storage zone since some (small) amount of space is still needed to make a
link?

 * create the link anyway (going over the limit)?
   ** if enough links are created we might hit 100% and really run out of space
 * fail to create the link?
   ** this adds a failure mode to PutSnapLink that doesn't exist now

### Identifying Links

Currently SnapLink objects in the `manta` bucket in Moray have a property:

```
"createdFrom":"/96c4ecc0-89aa-4e15-958f-3f50d5e 2a68b/public/plugin.c"
```

that indicates the object they were created from. Unfortunately this is not that
useful for our purposes here.

If you create a SnapLink from a SnapLink, it's the source SnapLink's path that's
used. So if you do:

 * mln ~~/public/object1 ~~/public/object2
 * mln ~~/public/object2 ~~/public/object3

the `createdFrom` for object3 will show object2's path.

It was [suggested that we should have a mechanism for identifying
links](https://github.com/joyent/rfd/issues/135#issuecomment-501458279)

I think it might be sufficient here to track the original objectId when making a
SnapLink. Though another question is whether we should track both the very first
objectId (in the above example would be object1 for both object2 and object3)
and the immediate source (object1 for object2 and object2 for object3) or
whether one or the other is sufficient here.

This property most likely can live only in the metadata tier and only be
available for internal tools and for debugging. It is not expected that it needs
to be in the public API or exposed to users in any way.

If we use the originalObjectId and keep that through subsequent SnapLinks, we
could mitigate some of the backward incompatible change here.

## Additional Work

### Cleanup

Since there are likely *existing* SnapLinks in some installations, we should
have a process for "fixing" pre-existing SnapLinks as part of this change.

Similar to what was [proposed among the steps in RFD
143](https://github.com/joyent/rfd/blob/master/rfd/0143/README.md#a-concrete-plan),
we will need to do an "audit" to find all existing objects that are SnapLinks. If
any are found, we'll want to:

 * create a new object id for each different name of the object (perhaps
   allowing oldest to keep the current uuid). Alternatively we could give *all*
   of the links a new uuid which could actually be safer depending how we deal
   with garbage collection while this process is running.
 * do a hard link to the new object uuid for each different entry.
 * update the metadata to point to the new object id.

this process should be idempotent since at any point the metadata will be
consistent and valid, and if the object was given a new uuid, it will no longer
show up in the next scan, and if it was not, we will be re-running the same
procedure. Care must be taken such that if we fail after creating the link, we
do everything possible to at least add a `manta_fastdelete_queue` record.

We will however need to complete this process before we enable the accelerated
GC for all objects. Until this is completed, we cannot know when an object is
deleted that it doesn't have links.

One option may be that as part of the "upgrade" here could be to disable
SnapLinks temporarily globally (at muskie) and also pause garbage collection and
then convert all existing SnapLinks as described above. Once this is complete,
the upgrade could be completed and garbage-collection could be re-enabled and
clean up all objects that were deleted while the conversion was running.

There are probably other ways we could handle this transition and this requires
a bit more thought and experimentation.

### Error Handling

While looking into the possibilities here I found that the current
putObjectHandler has poor behavior when there are errors talking to "sharks"
[MANTA-4286](https://jira.joyent.us/browse/MANTA-4286). If there is any error
after data has been written to disk, it will leave garbage around on the storage
zones that will never be cleaned up. We should avoid having that same bug with
this change and ensure that if we fail to create links on any of the "sharks",
we add a `manta_fastdelete_queue` entry to cleanup the potentially partially
written object. Since garbage collection is idempotent, this is always safe when
we're going to return an error after we've talked to any "sharks".


## See Also

* [RFD 123](https://github.com/joyent/rfd/blob/master/rfd/0123/README.md)
* [RFD 143](https://github.com/joyent/rfd/blob/master/rfd/0143/README.md)
* [RFD 162](https://github.com/joyent/rfd/blob/master/rfd/0162/README.md)
* [Mola design notes](https://github.com/joyent/manta-mola/blob/master/docs/gc-design-alternatives.md#the-walking-link-problem)
* [Manta design principles](https://github.com/joyent/manta/#design-principles)
