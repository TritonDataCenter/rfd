---
authors: Kelly McLaughlin <kelly.mclaughlin@joyent.com>
state: predraft
discussion:
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 149 PostgreSQL Schema For Manta buckets

## Overview

The manta *buckets* project aims to add the ability to store objects in manta
using a flat namespace in addition to the hierarchical directory-based storage
currently provided. A named bucket may be created in the context of a user
account and then any number of objects may be stored in the bucket.

The storage for buckets storage in manta will continue to be based
on [PostgreSQL](https://www.postgresql.org/), but the schema will differ from
that used by the directory-based storage.

This RFD presents the proposed schema for use in buckets-based storage.

## Schema

There proposed schema includes four tables: one to represent the buckets in an
account, one to represent the objects in each bucket, one to record information
about deleted buckets, and one to record information about deleted or overwritten
objects.

### manta_bucket

The table to model a bucket in manta is named `manta_bucket` and has five
columns. The breakdown of those is as follows:

  * `id` - A unique identifier for the bucket.
  * `name` - A string representing the name of the bucket
  * `owner` - The unique identifier of the account owner of the bucket
  * `created` - The timestamp indicating when the bucket was created

Here is the statement to create the `manta_bucket` table in PostgreSQL:

```SQL
CREATE TABLE manta_bucket (
    id uuid NOT NULL,
    name text NOT NULL,
    owner uuid NOT NULL,
    created timestamptz DEFAULT current_timestamp NOT NULL,

    PRIMARY KEY (owner, name)
);
```

The primary key for the `manta_bucket` table is a composite key of `owner` and
`name` columns. Only one instance of a particular named bucket may be present at
one time. When a bucket is deleted its `manta_bucket` record is moved to the
`manta_bucket_deleted_bucket` table. The unique identifier (`id`) is used for
tracking different incarnations of a particular named bucket and determining the
visibility of objects within that bucket.

### manta_bucket_object

The table to model an object in manta is named `manta_bucket_object` and has
fourteen columns. The description each column is as follows:

  * `id` - A unique identifier for the object
  * `name` - A string representing the name of the bucket
  * `owner` - The unique identifier of the account owner of the bucket
  * `bucket_id` - The id of the incarnation of a named bucket that the object is
    associated with
  * `created` - The timestamp indicating when the object was created
  * `modified` - The timestamp indicating the time when the metadata (`headers`)
    were last updated or when the object was created.
  * `creator` - The unique identifier of the account creating the object if it
    differs from the value of `owner`
  * `vnode` - A 64 bit integer value indicating the vnode that the object is
    associated with
  * `content_length` - A 64 bit integer value representing the number of bytes
    of object data.
  * `content_md5` - A byte sequence representing the MD5 hash of the object content
  * `content_type` - A string representing the value of the HTTP Content-Type
    header for this object.
  * `headers` - A set of key-value mappings from HTTP header name to HTTP header value.
  * `sharks` - A set of key-value mappings from datacenter to manta storage
    identifier. This value of this column indicates where the object data
    resides.
  * `properties` - This column provides a place to store unstructured data in
    situations where it becomes valuable or necessary to store information that could
    impact performance or correctness of the system, but for which a proper
    schema update and deployment as structured data has not yet been done.

Here is the statement to create the `manta_bucket_object` table:

```SQL
CREATE TABLE manta_bucket_object (
    id uuid NOT NULL,
    name text NOT NULL,
    owner uuid NOT NULL,
    bucket_id uuid NOT NULL,
    created timestamptz DEFAULT current_timestamp NOT NULL,
    modified timestamptz DEFAULT current_timestamp NOT NULL,
    creator uuid,
    vnode bigint NOT NULL,
    content_length bigint,
    content_md5 bytea,
    content_type text,
    headers hstore,
    sharks hstore,
    properties jsonb,

    PRIMARY KEY (owner, bucket_id, name)
);
```

The primary key for the `manta_bucket_object` table is a composite of the
`owner`, `bucket_id`, and `name` columns. This means only one instance an object
may be *live* for a bucket at any time.

### manta_bucket_deleted_bucket

The `manta_bucket_deleted_bucket` table is used to maintain records of deleted
buckets to ensure the storage resources for objects from the bucket are properly
released before the record of the bucket is permanently discarded. The table has
three columns:

  * `id` - The unique identifier of the bucket incarnation
  * `name` - The name of the deleted bucket
  * `owner` - The unique identifier of the account owner of the deleted bucket
  * `created` - The timestamp indicating when the bucket was created
  * `deleted_at` - The timestamp indicating when the bucket was deleted

The statement to create the `manta_bucket_deleted_bucket` table is as follows:

```SQL
CREATE TABLE manta_bucket_deleted_bucket (
    id uuid NOT NULL,
    name text NOT NULL,
    owner uuid NOT NULL,
    created timestamptz NOT NULL,
    deleted_at timestamptz DEFAULT current_timestamp NOT NULL
);
```

The column structure is identical to the `manta_bucket` table except for the
addition of the `deleted_at` column to record the time of deletion and the lack
of a primary key. Multiple records for the same `(owner, bucket)` pair may need
to be tracked and this table schema allows for that. At first glance it might
seem that the table should use the `id` column as the primary key, but this
could cause issues if a situation arose where two different deleted or
overwritten object versions happened to have the same value for the `id`
column. The table will maintain two non-unique indexes, one on the `id` column
and one on the `deleted_at` column. These indexes will let the garbage
collection system gather batches of records for deleted buckets to process in
the rough order of deletion and then to delete those records based on the `id`
once the garbage collection process is done with them.

The statements to create those indexes are as follows:

```SQL
CREATE INDEX manta_bucket_deleted_bucket_id_idx
ON manta_bucket_deleted_bucket (id);

CREATE INDEX manta_bucket_deleted_bucket_deleted_at_idx
ON manta_bucket_deleted_bucket (deleted_at);
```

### manta_bucket_deleted_object

The `manta_bucket_deleted_object` table is similar in purpose to the
`manta_bucket_deleted_bucket` table except rather than records about deleted
buckets it maintains records for deleted or overwritten objects. The number,
name, and type of the columns is similar to the `manta_bucket_object`
table with the addition of a single column to record the time of deletion.

The description each column is as follows:

  * `id` - A unique identifier for the object
  * `name` - A string representing the name of the bucket
  * `owner` - The unique identifier of the account owner of the bucket
  * `bucket_id` - The id of the incarnation of a named bucket that the object is
    associated with
  * `created` - The timestamp indicating when the object was created
  * `modified` - The timestamp indicating the time when the metadata (`headers`)
    were last updated or when the object was created.
  * `creator` - The unique identifier of the account creating the object if it
    differs from the value of `owner`
  * `vnode` - A 64 bit integer value indicating the vnode that the object is
    associated with
  * `content_length` - A 64 bit integer value representing the number of bytes
    of object data.
  * `content_md5` - A byte sequence representing the MD5 hash of the object content
  * `content_type` - A string representing the value of the HTTP Content-Type
    header for this object.
  * `headers` - A set of key-value mappings from HTTP header name to HTTP header value.
  * `sharks` - A set of key-value mappings from datacenter to manta storage
    identifier. This value of this column indicates where the object data
    resides.
  * `properties` - This column provides a place to store unstructured data in
    situations where it becomes valuable or necessary to store information that could
    impact performance or correctness of the system, but for which a proper
    schema update and deployment as structured data has not yet been done.
  * `deleted_at` - The timestamp indicating when the object record was either
    deleted or overwritten.

Here is the statement to create the `manta_bucket_deleted_object` table:

```SQL
CREATE TABLE manta_bucket_deleted_object (
    id uuid NOT NULL,
    name text NOT NULL,
    owner uuid NOT NULL,
    bucket_id uuid NOT NULL,
    created timestamptz NOT NULL,
    modified timestamptz NOT NULL,
    creator uuid,
    vnode bigint NOT NULL,
    content_length bigint,
    content_md5 bytea,
    content_type text,
    headers hstore,
    sharks hstore,
    properties jsonb,
    deleted_at timestamptz DEFAULT current_timestamp NOT NULL
);
```

The only difference from the `manta_bucket_object` table is the addition of the
`deleted_at` column to track the time the object was deleted or overwritten and
the lack of a primary key. This is similar to the relationship between the
`manta_bucket` and `manta_bucket_deleted_bucket` tables. Like the
`manta_bucket_deleted_bucket` table, `manta_bucket_deleted_object` has two
indexes: one on the `id` column and one on the `deleted_at` column Again these
two indexes serve to help the garbage collector complete its work efficiently.

The statements to create those indexes are as follows:

```SQL
CREATE INDEX manta_bucket_deleted_object_id_idx
ON manta_bucket_deleted_object (id);

CREATE INDEX manta_bucket_deleted_object_deleted_at_idx
ON manta_bucket_deleted_object (deleted_at);
```

## Queries

This section covers some queries that might be used for higher level operations
in the manta buckets system.

### Read a bucket

```SQL
SELECT id, owner, name, created
FROM manta_bucket
WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7' AND name = 'mybucket';
```

### Read an object

```SQL
SELECT id, owner, bucket_id, name, created, modified, content_length,
       content_md5, content_type, headers, sharks, properties
FROM manta_bucket_object
WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
AND bucket_id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
AND name = 'myobject';
```

### Write a bucket

```SQL
INSERT INTO manta_bucket (id, owner, name)
VALUES ('293def5e-a57f-11e8-9ef0-bf343ab6f823',
'14aafd84-a57f-11e8-8706-4fc23c74c5e7', 'mybucket');
```

### Write an object

```SQL
WITH write_deletion_record AS (
  INSERT INTO manta_bucket_deleted_object (
    id, owner, bucket_id, name, created, modified, creator, vnode,
    content_length, content_md5, content_type, headers, sharks, properties
  )
  SELECT id, owner, bucket_id, name, created, modified, creator, vnode,
         content_length, content_md5, content_type, headers, sharks, properties
  FROM manta_bucket_object
  WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
  AND bucket_id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
  AND name = 'myobject'
)
INSERT INTO manta_bucket_object (id, owner, bucket_id, name, vnode,
content_length, content_md5, content_type, headers, sharks)
VALUES ('06d40bb8-a581-11e8-84b2-93ddb053d02b',
'14aafd84-a57f-11e8-8706-4fc23c74c5e7', '293def5e-a57f-11e8-9ef0-bf343ab6f823',
'myobject', 2091564, 14917, '\xc736398c96d1f6b72b3118657268bff2'::bytea,
'text/plain', 'm-custom-header1=>value1,m-custom-header2=>value2',
'us-east-1=>1.stor.us-east.joyent.com,us-east1=>3.stor.us-eas.joyent.com')
ON CONFLICT (owner, bucket_id, name) DO UPDATE
SET id = EXCLUDED.id, vnode = EXCLUDED.vnode,
  content_length = EXCLUDED.content_length,
  content_md5 = EXCLUDED.content_md5,
  content_type = EXCLUDED.content_md5,
  headers = EXCLUDED.headers,
  sharks = EXCLUDED.sharks,
  properties = EXCLUDED.properties;
```

One interesting thing to note about this query is that in the case of an
`INSERT` conflict the resulting update should be able to be done as a [Heap Only Tuple
(HOT) update](https://github.com/postgres/postgres/blob/REL_10_5/src/backend/access/heap/README.HOT) which may have performance benefits and help us avoid vacuuming
costs that might otherwise be incurred. The following query can be used to
observe this before and after running the above object query:

```
SELECT n_tup_upd, n_tup_del, n_tup_hot_upd FROM pg_stat_user_tables
WHERE schemaname = 'public' AND relname = 'manta_bucket_object';
```

### Delete a bucket

```SQL
WITH write_deletion_record AS (
 INSERT INTO manta_bucket_deleted_bucket (id, owner, name, created)
 SELECT id, owner, name, created FROM manta_bucket
 WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7' AND name = 'mybucket';
)
DELETE FROM manta_bucket
WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7' AND name = 'mybucket';
```

### Delete an object

```SQL
WITH write_deletion_record AS (
  INSERT INTO manta_bucket_deleted_object (
    id, owner, bucket_id, name, created, modified, creator, vnode,
    content_length, content_md5, content_type, headers, sharks, properties
  )
  SELECT id, owner, bucket_id, name, created, modified, creator, vnode,
         content_length, content_md5, content_type, headers, sharks, properties
  FROM manta_bucket_object
  WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
  AND bucket_id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
  AND name = 'myobject'
)
DELETE FROM manta_bucket_object
WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
AND bucket_id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
AND name = 'myobject';
```

### Collect a batch of object records for purposes of a bucket content listing

```SQL
SELECT id, owner, bucket_id, name, created, modified, content_length,
       content_md5, content_type, headers, sharks, properties
FROM manta_bucket_deleted_object
WHERE owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
AND bucket_id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
ORDER BY name LIMIT 250;
```

### Collect a batch of deleted bucket records for garbage collection processing

```SQL
SELECT id, owner, name, created
FROM manta_bucket_deleted_bucket
WHERE deleted_at < current_timestamp - interval '24 hours'
ORDER BY deleted_at LIMIT 25;
```

### Collect a batch of deleted object records for garbage collection processing

```SQL
SELECT id, owner, bucket_id, name, created, modified, content_length,
       content_md5, content_type, headers, sharks, properties
FROM manta_bucket_deleted_object
WHERE deleted_at < current_timestamp - interval '24 hours'
ORDER BY deleted_at LIMIT 100;
```

### Remove a deleted bucket record after garbage collection processing

```SQL
DELETE FROM manta_bucket_deleted_bucket
WHERE id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
AND owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
AND name = 'mybucket';
```

### Remove a deleted object record after garbage collection processing

```SQL
DELETE FROM manta_bucket_deleted_object
WHERE id = '06d40bb8-a581-11e8-84b2-93ddb053d02b'
AND owner = '14aafd84-a57f-11e8-8706-4fc23c74c5e7'
AND bucket_id = '293def5e-a57f-11e8-9ef0-bf343ab6f823'
AND name = 'myobject';
```

## Higher level operations

The example queries shown in the previous section represent a majority of what
will be needed to build the higher level operations that the manta buckets API
will provide. Services further up the stack such as moray that interface
directly with postgres will expose API operations that ultimately result in the
execution of these queries.

There may be need for further adjustments that include additional columns or
indexes primarily based on the results of further research into the behavior and
performance of bucket content listing.
