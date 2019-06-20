---
authors: Kelly McLaughlin <kelly.mclaughlin@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues/130
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Joyent, Inc.
-->

# RFD 168 Bootstrapping a Manta Buckets deployment

## Overview

This RFD covers the steps required to bootstrap a manta buckets deployment. This
includes specifying the buckets manatee shards, creating the initial hash ring
for the buckets system, and assigning virtual nodes to the buckets shards. It
also covers the changes to the current manta deployment scripts to enable the
creation of manta buckets shards that are distinct from other manta shard types
and the creation of a hash ring image that is distinct from the hash ring image
used by a standard manta deployment.

## Prerequisites

The manta buckets system is designed to be deployed in an existing manta
system. The manta `webapi` tier has been built to serve both standard manta
directory-based requests as well as manta buckets requests. From a
[SAPI](https://github.com/joyent/sdc-sapi) point-of-view the buckets system
appears to fit under the umbrella of a `manta` application rather than being a
completely separate application. Operating under this assumption there are a few necessary
changes in order to support the addition of the buckets system into the manta
application.

The first required change is to add a new shard type to manta. Shards are
currently managed with the
[`manta-shardadm`](https://github.com/joyent/sdc-manta/blob/master/cmd/manta-shardadm.js)
script. Currently, there are three shard types: `index`, `storage`, and `job` (a.k.a
`marlin`). The `index` shard type houses the object metadata for manta's
directory-based storage option. It is not possible to reuse the `index` shard
type for buckets metadata for a few reasons. First, the version of PostgreSQL being targeted for
buckets is not the same as the current default version used by the `index`
shards. Second, the number of metadata shards required for a buckets deployment
may need to evolve differently from that of directory-based manta. The proposal
is to use a new `buckets` shard type for the manta buckets metadata and change the
`manta-shardadm` script to be aware of this new type.

The next required change is to be able to generate a mapping of virtual nodes to
the `buckets` shards. This is done for production manta deployments using the [`manta-create-topology.sh`](https://github.com/joyent/sdc-manta/blob/master/bin/manta-create-topology.sh)
script. The proposal is to create a new program that provides the functionality
of `manta-create-toplogy.sh` and also provides the ability generate the mapping
of virtual nodes needed for `buckets` shards. The `manta-create-toplogy.sh`
script will be removed.

## Bootstrapping process

This section will operate under the assumption the work to meet the
prerequisites outlined in the previous section has been completed.

It is also assumed that the shards being specified as part of the manta buckets
system have been created. A new `buckets-postgres` sharded service is being
added to manta that allows for buckets shards to be created using the
`manta-adm` tooling.

The first step is to use `manta-shardadm` to create the set of initial shards
for the buckets deployment. The invocation of `manta-shardadm` might look as
follows:

```
manta-shardadm set -b "1.boray 2.boray"
```

Aside from adding the shard information to the SAPI manta application data this
command should also attempt a simple sanity check on each shard. This would
include verifying that each specified shard exists and that each one is an instance of
the `buckets-postgres` service.

The next step is to generate a consistent hash ring that maps a set of virtual
nodes (vnodes) to the shards specified in the previous step. The program that
supersedes `manta-create-topology.sh` script should be used for this. Provide
the script with the number of vnodes to initialize the hash ring with and it
will generate a ring image, upload it to the image API server, and then update
the SAPI metadata for manta with the image UUID under the
`BUCKETS_HASH_RING_IMAGE` key as well as a `BUCKETS_HASH_RING_DIGEST` key
representing the SHA256 digest of the ring file. This information will be used
by the manta buckets component
[`electric-boray`](https://github.com/joyent/electric-boray).

The composition of the image for a buckets deployment will be
different from the images created for the normal manta system. Whereas
`manta-create-topology` uses `node-fash` to create a leveldb database, the hash
ring for the buckets system will be generated using the memory backend option
provided by `node-fash`. The ring data will be serialized and then further
transformed to remove unnecessary data and add other useful data (*e.g.* the
`vnodeToPnodeMap_` that is not directly exposed by `node-fash` when the ring is
serialized) and then captured in a file. This file will be captured in the image
that is uploaded and later retrieved by electric-boray.

Once these steps are completed then the full set of manta buckets zones may be
deployed and used. This set include `electric-boray` service zones and `boray`
service zones. Additionally, the `webapi` service zones must be updated to a
version that has support for manta buckets.
