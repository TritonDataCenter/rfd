---
authors: Brittany Wald <brittany.wald@joyent.com>
state: predraft
discussion: 'https://github.com/joyent/rfd/issues?q=%22RFD+155%22'
---
<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc
-->

# RFD 155 Manta Buckets API

This RFD will describe the new buckets API for the Manta storage service.

# HTTP API

This is a preliminary API design, which may change as we proceed through
research efforts.

## Headers

These are headers we will use on every request.

### Authentication

`Authorization` -- See RBAC.

### Versioning

Semantic versioning.
Current: `0.0.0`

### Date

RFC 1123.

### Host

`*.manta.joyent.com`

## Routes

We will add the following routes to Muskie to support Manta Buckets. See `MANTA-3898`
for more information.

### List buckets

`GET /$MANTA_USER`

### Check bucket

`HEAD /$MANTA_USER/buckets/$BUCKET_NAME`

### Create bucket

`POST /$MANTA_USER/buckets`

### Get bucket

`GET /$MANTA_USER/buckets/$BUCKET_NAME`

### Delete bucket

`DELETE /$MANTA_USER/buckets/$BUCKET_NAME`

### List bucket contents in lexicographical order

`GET /$MANTA_USER/buckets?order_by={order_by_string}`

### List paths under prefixes of the bucket

`GET /$MANTA_USER/buckets?prefix={prefix_string}`

### List objects

`GET /$MANTA_USER/buckets/$BUCKET_NAME`

### Check object

`HEAD /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME`

### Create or overwrite object

`PUT /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME`

### Conditionally create or overwrite object

`PUT /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME`

### Get object

`GET /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME`

### Delete object

`DELETE /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME`

### Conditionally delete object

`DELETE /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME`

### Update object metadata

`PUT /$MANTA_USER/buckets/$BUCKET_NAME/objects/$OBJECT_NAME?metadata=true`

