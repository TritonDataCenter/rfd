---
author: Robert Mustacchi <rm@joyent.com>
state: draft
---

# RFD 53 Improving ZFS Pool Layout Flexibility

Each compute node in Triton is based off of SmartOS. All file system
data is managed by ZFS in a single pool (zpool) of storage. This zpool
is traditionally named `zones`. This zpool is created when the compute
node (or headnode) is first set up.

Today, Triton effectively hard-codes specific zpool layouts. This is
implemented by some of the logic in
[disklayout(1M)](http://smartos.org/man/1m/disklayout). While disklayout
logically allows for a couple of different layouts to be used, Triton
does not allow administrators to specify them. In an ideal, more
appliance centric world, this continue being determined automatically;
however, reality does not allow us to be quite so rigid.  In fact, over
the life time of disklayout.js, there have been many changes to these
hard-code defaults based on sometimes contradictory customer
requirements.

As such, we've reached the point where instead of hard-coding this
information, we should instead choose to expose it. The challenge is to
make this useful to administrators without introducing too much
additional complexity.

## Exposed Options

### Exposing RAID Stripe Options

There are two different ways we could choose to expose the pool
topology. The first is to describe pool layouts in a style similar to
`disklayout(1M)`. `disklayout(1M)` has the notion of different layouts,
like `mirror`, that describe how disks are laid out. The supported
profiles today are:

* mirror - Indicating drives should be mirrored and then striped.
* raidz1 - Indicating that drives should be put into a RAID-Z1 stripe
* raidz2 - Indicating that drives should be put into RAID-Z2 stripes

If we moved forward with this, we need to also add support for the
following:

* raidz3 - Indicating that drives should be put into a RAID-Z3 stripe

Note that this is only intended to allow the operator to have a broad
level of specification. This is not meant to allow or force the operator
to learn about and configure the following which are taken care of
automatically:

1. Stripe Size
2. Assignment of devices as SLOGs and Cache Devices
3. Number of spares

### Qualitative Descriptions

Another option that we could go for is allowing for the user to describe
and pick more qualitative options. In this world, the user would have to
basically prioritize the following three axis:

1. Capacity of Storage
2. Performance of Storage
3. Durability of Storage

The challenge with expressing things here is that it makes it harder for
us to set expectations and to really help customers understand what
they'll be ending up with. It also may end up causing us to repeat a
similar class of mistakes and issues that we have with the current
generation of storage layout. Mainly that the ideas of what is best for
performance or capacity may change on a per-customer basis, forcing us
to have conflicting and contradictory desires for what these different
axis represent in terms of actual layouts.

On the other hand, it may also allow us more flexibility and require us
to teach customers less. You don't have to explain how the RAID profiles
work.

It is the author's belief that while this options is interesting and has
merits (and was in fact the first idea we had here), it's not the most
useful idea or approach for this problem.

## User Interfaces

This choice should be presented as part of setting up a compute node.
Setting this information should always be considered *optional*. In
other words, existing installations shouldn't have to change anything in
their processes and scripts. For the purpose of this discussion, I'm
going to describe this using the world where we're exposing the specific
pool layouts like `mirror` or `raidz2`.

### SAPI Properties

A new SAPI property should be introduced that is used to describe the
default pool layout. Tools need to treat the absence of this property as
basically saying that there is no default pool layout and thus we should
have today's default behavior.

The name of the SAPI property is beyond the scope of this document;
however, users themselves should never directly interact with SAPI and
instead this should be covered by other means of manipulating the
property as described below.

### Changes to Compute Node Setup

When setting up a compute node whether via AdminUI or via sdc-server a
new optional argument to pass the layout should be provided. If no
layout is provided, it should consult SAPI using the new property
described above.

For the `sdc-server` command an explicit layout option may be specified
through something like a new `-l` option or as a parameter that's at the
end. These may look like:

```
sdc-server setup [-s] [-l layout] <uuid> [PARAMS]
sdc-server setup [-s] <uuid> [layout=<str>] [PARAMS]...
```

In addition, a similar change should be made to AdminUI, allowing a
specific layout to be selected. Like with sdc-server if nothing is
selected, it should default to checking SAPI.

To help deal with the software being at different versions, the lack of
a property in SAPI should always be treated as no property being set
which should be equivalent to the default behavior.

Note, the actual way that this information gets passed to the compute
node as part of set up should be worked out by those who are working on
this.

#### Propagating Failure

An important part of extending this interface is to make the error very
clear that when an unsupported layout gets passed through the stack.
Today, many set up failures are hard to diagnose. The work associated
with this rfd should ensure that the following is true:

1. Final validation of the layout is done on the CN during setup
2. When an unknown layout is specified, setup is failed and the fact
that this is the reason set up failed should be obvious.

This likely could be extended to other parts of the CN setup process.

### Managing the Default

As part of this, we've suggested that there should be a new property.
That property needs to be made available to the operator and they need
the ability to inspect and change that, as well as understand their
options. These needs to be represented in both AdminUI and through
`sdcadm`.

In AdminUI, the option to set the default should be added to some set of
defaults page for servers.

For sdcadm, I'd suggest that we add a new endpoint to sdcadm for
managing servers explicitly. This is a bit of a straw man and subsumes a
bit of the `sdc-server` tool's use. This could be something like `sdcadm
server`.

Under here in the fullness of time we may want to some of the endpoints
that sdc-server does today. But the main thing to focus on is something
like:

`sdcadm server defaults`

This could be used to get and set the default zpool layout and might be
a good place to allow operators to change things like the default
console.

It may also make sense to have a `sdcadm server setup` which allows for
specifying the hostname, pool layout override, and others. As well as
using that as the vector for the storage pool layout dry run. If we add
the `sdcadm server setup` option, we should make sure that it and the
`sdc-server` code can share implementation where possible and start the
process of deprecating sdc-server in favor of `sdcadm server`.

### Storage Profile Dry Runs

One of the first things that'll come up as soon as we introduce options
is that an operator will ask what do the different pools look like,
what are the trade-offs associated with them, and how much storage is
available is available with a given layout. As part of presenting these,
we should make sure that we take into account the dump and swap space
required, so they get a sense of the fixed costs and their impact.

We'll want to have some kind of ability to perform a storage layout
dry-run. In other words, we should go and run disklayout on the compute
node with the specified profile via ur or some other mechanism and then
report back something for the operator.

In both sdcadm and the browser it may be interesting to put something
together like was done in the fishworks UI. The following image shows an
example of what this looked like:

![Fishworks UI](img/fw.png)

This is a useful summary and way to view things. While it doesn't make
sense to put this in the CLI server path, making a variant available
there and in the UI is important.

On the CLI this might be a good fit for something under `sdcadm server`,
whether under a setup command or other option.

### Headnode Setup

The last piece of this picture is dealing with headnode setup. We should
put together a new question to prompt what the user wants as the layout
for their headnode and then optionally make this the new default layout
for the DC. It may make sense to logically specify this as two different
questions, but we'll want to be careful about how we do that so as not
to introduce too much additional complexity into the headnode set up
process.

## Upgrading DCs

While a new DC will be able to have the default layout set as part of
its setup, it's worth talking through the flow that we want to use for
updating existing DCs and how that works.

As part of any upgrade, there's no guarantee that the metadata for this
will be added nor should it be required. This is actually the core
tenant: all tools which begin to query this need to treat the absence of
the property as the equivalent of basically saying SDC should decide it.

While diskinfo is part of the platform and thus there may be RAID
profiles that we introduce which disklayout doesn't know about, it
should be possible with the improved CN setup process (which does not
come from the platform) to go through and handle the potential
disconnect and report it in a useful way to the user.

There will be a need for AdminUI, sdcadm, and others to know that some
support for specifying this is available as part of CN setup. As the
implementation is worked through, that will need to be determined.
