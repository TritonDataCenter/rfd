----
authors: Nick Zivkovic <nick.zivkovic@joyent.com>
state: predraft
----

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 <contributor>
-->

# RFD 21 Metadata Scrubber For SDC


## Background/Problem

SDC services primarily store metadata in Moray, our key-value store. There are
relationships (and therefor dependencies) between the objects we put in there.
However, we don't actually describe the relationships formally, and this
sometimes results in unused KV pairs lingering in the store. We want some kind
of scrubber that will essentially garbage-collect the unneeded values.

## Proposal

Two ways come to mind in which this problem can be solved. First we can create
an entirely new scrubber service that periodically scrubs each Moray store.
Alternatively, we can build in some kind of scrubbing into the existing
services (FWAPI, NAPI, etc). The latter approach allows us to pay-as-we-go --
we can solve the scrubber problem one service at a time (perhaps even
concurrently). The former approach is more comprehensive, may allow us to
handle dependencies/relationships that span across services more easily, and is
a single source of bugs -- don't have to spend as much time guessing which
service is failing to scrub dead KV pairs.

## Plan of Attack

A preliminary git-grep for `node-moray` revealed that the following \*API repos
depend on the `node-moray` library.

        sdc-cnapi
        sdc-adminui
        sdc-docker
        sdc-fwapi
        sdc-imgapi
        sdc-napi
        sdc-vmapi
        sdc-portolan
        sdc-papi
        sdc-sapi
        sdc-sdc
        sdc-ufds

The next logical step would be to see -- for each repo -- where calls are made
to the moray library, and which objects are stored in Moray.

We will want to describe relationships between objects in Moray. For this we
may need a kind of relationship-schema-format. Joyent-schemas is not currently
used in this way -- it is used to verify that the JSON payloads a service
recieves are not garbage. For the curious, `joyent-schemas` is consumed by the
following repos.

        sdc-cloudapi
        sdc-designation
        sdcadm

Clearly it is used to verify objects that are inbound to SDC. We may be able to
extend the `joyent-schemas` code to allow specifiying interdependencies between
objects in Moray. If not, we will have to roll our own description format.

It is essential to describe, not only which objects refer to each other, but
whether it makes sense for an object to exist without a referring object
present in the store.

### Considerations

 - Moray is distributed and interdependent objects may be spread throughout the
   stores.

 - Totally theoretical, but if a service is currently putting a bunch of
   interdependent objects into Moray, the scrubber should not scrub until the
   service is done updating the store -- otherwise, it may scrub objects that
   that should not be scrubbed.  This suggests some coordination might be
   necessary between the scrubber and services. Won't be sure, until we see
   which concrete objects get stored in Moray.

### Affected Repositories

If we choose the iterative, pay-as-you-go strategy many of the repositories
listed in the third section will be affected. If we choose the
single-scrubber-service strategy, it seems that no other repositories will be
affected, except perhaps for Mountain Gorilla, if we're creating a new service
zone. If on the other hand we are stashing the scrubber in the `sdc0` zone, we
will need to change the `sdc-sdc` repo.
