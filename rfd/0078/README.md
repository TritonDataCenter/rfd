---
authors: Julien Gilli <julien.gilli@joyent.com>
state: publish
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [RFD 78 Making Moray's findobjects requests robust with regards to unindexed fields](#rfd-78-making-morays-findobjects-requests-robust-with-regards-to-unindexed-fields)
  - [Introduction](#introduction)
    - [Context](#context)
    - [Terminology](#terminology)
  - [Current problems with findobjects requests using unindexed fields](#current-problems-with-findobjects-requests-using-unindexed-fields)
    - [Broken limit](#broken-limit)
    - [non-string search filters do not work as expected](#non-string-search-filters-do-not-work-as-expected)
    - [Problems with `findobjects` requests specific to fields being reindexed](#problems-with-findobjects-requests-specific-to-fields-being-reindexed)
        - [Problems with values of properties added _before_ the corresponding index is added](#problems-with-values-of-properties-added-_before_-the-corresponding-index-is-added)
  - [How ZAPI-747 is impacted by these limitations](#how-zapi-747-is-impacted-by-these-limitations)
    - [A short description of ZAPI-747's use case](#a-short-description-of-zapi-747s-use-case)
    - [Workarounds considered to fix ZAPI-747](#workarounds-considered-to-fix-zapi-747)
      - [Waiting for reindexing to be complete before servicing any request](#waiting-for-reindexing-to-be-complete-before-servicing-any-request)
        - [Time to reindex grows with the number of objects](#time-to-reindex-grows-with-the-number-of-objects)
        - [Inefficient data retention policies](#inefficient-data-retention-policies)
      - [Only waiting for reindexing to be done to enable endpoints using new indexes](#only-waiting-for-reindexing-to-be-done-to-enable-endpoints-using-new-indexes)
  - [Generalization of ZAPI-747's use case](#generalization-of-zapi-747s-use-case)
    - [Growth targets for Triton datacenters](#growth-targets-for-triton-datacenters)
    - [Time to reindex grows with the number of fields](#time-to-reindex-grows-with-the-number-of-fields)
    - [Other factors that contribute to an increase in reindexing time](#other-factors-that-contribute-to-an-increase-in-reindexing-time)
  - [Other use cases](#other-use-cases)
  - [Proposed solution](#proposed-solution)
    - [Implementation details](#implementation-details)
      - [Introduction of a "metadata" message in the moray protocol](#introduction-of-a-metadata-message-in-the-moray-protocol)
      - [Changes to the node-moray client's API](#changes-to-the-node-moray-clients-api)
        - [Changes to the Moray constructor](#changes-to-the-moray-constructor)
        - [Changes to the findObjects method](#changes-to-the-findobjects-method)
      - [Changes to the moray server](#changes-to-the-moray-server)
        - [Handling of the findObjects' requireIndexes option](#handling-of-the-findobjects-requireindexes-option)
        - [Sending an additional metadata record for each findObjects response](#sending-an-additional-metadata-record-for-each-findobjects-response)
      - [Performance impact](#performance-impact)
    - [Backward compatibility](#backward-compatibility)
      - [Workaround for old moray clients connected to new moray servers](#workaround-for-old-moray-clients-connected-to-new-moray-servers)
    - [Forward compatibility](#forward-compatibility)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# RFD 78 Making Moray's findobjects requests robust with regards to unindexed fields

## Introduction

Currently, moray `findobjects` requests may silently return erroneous results
when using a search filter that includes unindexed fields.

This document starts by describing the problem in details. It then presents how
they impact the VMAPI use case that is tracked by [ZAPI-747]. It goes on to
describe how this use case applies to other core services and how these
limitations apply to other use cases.

Finally it presents changes to moray that would allow moray clients to never get
incorrect results returned silently due to unindexed fields.

### Context

This document was written while implementing a new feature in VMAPI needed to
support [NFS shared volumes][RFD 26].

As described in the corresponding [RFD][RFD 26], [new indexes need to be added
to one of VMAPI's moray buckets' schema](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0026/README.md#new-internal_role-property-on-vm-objects).
A [ticket was created][ZAPI-747] to describe and track the work needed to be
able to add these new indexes.

While working on implementing the changes needed to support the addition of
these indexes and the migration process, it seemed that moray's implementation
of `findobjects` requests had some limitations that made these changes
inherently not robust.

Basically, when adding a new index to a moray bucket, there is a window of time
during which `findobjects` requests silently return erroneous results, which
could possibly lead to core services making bogus destructive changes.

Various workarounds have been tried, such as waiting for the updated buckets to
be reindexed, but they are not sufficient to solve the use case described by
ZAPI-747, let alone to solve the general problem.

### Terminology

In this document the term `unindexed field` refers to a moray object field that
has no usable index. It can be a field for which no index is present in the
moray bucket schema. It also applies for fields for which an index is present in
the moray bucket schema, but all existing rows of the moray bucket haven't been
reindexed yet.

Sometimes, this document needs to differentiate between the two use cases. In
that case, the term `'missing index'` is used to refer to an index that is not
present in the bucket schema, and `'reindexing field'` is used to refer to a
field that has a corresponding index but for which existing rows haven't been
reindexed yet.

## Current problems with findobjects requests using unindexed fields

This section describe in details the issues with `findobjects` requests using
search filters that include unindexed fields.

### Broken limit

By default, moray `findobjects` requests are limited to return 1000 objects.
This limit was put in place to ensure that each `findobjects` request is bounded
in terms of the number of records that are processed during a single request.
Otherwise, a single large request could significantly impact the performance of
the system and of other clients' requests.

Moray implements the limit in the the number of entries that are returned at the
database level, by using the `LIMIT` SQL statement. For instance, the following
moray search filter:

```
&(field1=value1)(field2=value2)
```

would make moray generate a SQL statement similar to the following:

```
SELECT * from moray_bucket WHERE field1=value1 AND field2=value2 LIMIT 1000;
```

Note the implicit `LIMIT 1000` that was added to the generated SQL query.

Because fields that are unindexed (either when an index is not present, or when
it is present but rows are still being reindexed) do not necessarily have valid
values in a column that stores their values at the database layer, moray needs
to not include them from the `WHERE` clause of the SQL query used to get the
initial records from the database.

Thus, if `field2` from the moray search filter mentioned above is unindexed, the
SQL statement that is generated by moray would instead be similar to:

```
SELECT * from moray_bucket WHERE field1=value1 LIMIT 1000;
```

This query will return the first 1000 records that match the filter
`(field1=value1)`, and then apply another filter at the application level to
keep only the objects matching the original filter
`&(field1=value1)(field2=value2)`.

However, it is possible that from the first set of 1000 objects that match the
filter `(field1=value1)`, none of them match the second and original
`findobjects` request's filter.

As a result, the request will return an empty set of objects, and the client
will consider that there is no object in the bucket that match the original
filter.

Passing the `noLimit: true` flag to `findobjects` works around this problem.
However, it cannot be recommended as a solution as it can severely impact
performance.

[MORAY-104] fixes the bulk of this issue, but there are still edge cases like
[MORAY-413] that can cause applications to hit this problem.

### non-string search filters do not work as expected

With the following bucket configuration:

```
{
    index: {
        str_field: {
            type: 'string'
        }
    }
}
```

if the following object is added to the bucket:

```
{
    str_field: 'foo',
    boolean_field: true
}
```

searching for objects in this bucket with the filter
`(&(str_field=foo)(boolean_field=true))` will not return any result.

The reason is that the filter used to make sure that all objects returned
actually match the provided filter use a filter that is not aware of the indexed
fields' type _for all unindexed fields_.

The [`compileQuery` function](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/common.js#L126-L304)
is the one responsible for [updating the type of the values specified in the
`findobjects` request's filter](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/common.js#L44-L123).

However, it [only considers indexes that are fully reindexed as valid](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/common.js#L481-L500),
and thus will update the types of filters' values only for
fields that correspond to fully reindexed indexes.

The consequence is that for the following object:

```
{
    str_field: 'foo',
    boolean_field: true
}
```

the filter `(&(str_field=foo)(boolean_field=true))` is able to match a value
`'foo'` (a string) for its property `str_field`, but cannot match a value
`'true'` (a string, when it should be a boolean `true`) for its property
`boolean_field`.

This problem only applies to _unindexed_ fields that have a _non-string_ type.
Filtering on any field of type `'string'` results as expected (with the caveat
described in the other sections regarding pagination).

This limitation with search filters using non-string values is [already
mentioned in the moray-test-suite repository](https://github.com/TritonDataCenter/moray-test-suite/blob/ad95d757/test/objects.test.js#L2055).

However, I have not yet been able to find an existing JIRA ticket that tracks
this problem.

### Problems with `findobjects` requests specific to fields being reindexed

##### Problems with values of properties added _before_ the corresponding index is added

With the following initial bucket configuration:

```
{
    index: {
        str_field: {
            type: 'string'
        }
    },
    options: {
        version: 1
    }
}
```

If the following objects are added to the bucket:

```
{
    str_field: 'foo'
    boolean_field: true
}
```

and:

```
{
    str_field: 'foo',
    boolean_field: false
}
```

and then the bucket is updated to have the following configuration:

```
{
    index: {
        str_field: {
            type: 'string'
        }
        boolean_field: {
            type: 'boolean'
        }
    },
    options: {
        version: 2
    }
}
```

searching for objects in this bucket with the filter
`(&(str_field=foo)(boolean_field=false))` will return both objects.

The reason this `findobjects` request doesn't only return the object that
matches the filter is that, when the database table's column that is storing the
values for the newly indexed property _does not_ contain any value for that
property, [the values on which the filter is applied have that property deleted](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/common.js#L843-L857).

Thus, [the filter that is applied after all records are filtered from the
database](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/find.js#L147)
does not filter on the `boolean_field` property, and the objects that do not
match the filter for that field pass through (without the reindexing field,
even if it should be present).

[MORAY-428] fixes this issue.

## How ZAPI-747 is impacted by these limitations

This section presents why, in the context of [the work done to enable VMAPI to
update its moray buckets' schema][ZAPI-747], these limitations cannot be worked
around and have to be fixed.

### A short description of ZAPI-747's use case

In order to implement part of the [NFS shared volumes RFD][RFD 26], indexes on
new VM objects' fields need to be added to VMAPI moray buckets' schema.

The migration of current schemas to the new ones needs to be performed during
the normal Triton upgrade process. VMAPI functionality and availability that was
provided _before_ the migration must not be impacted after the migration window.

Unavailability of the new features that require the new indexes can be tolerated
for a longer time window, as long as:

1. they result in explicit errors that can be handled by VMAPI users

2. VMAPI's behavior eventually converges towards the new feature being available
   as quickly as possible.

### Workarounds considered to fix ZAPI-747

#### Waiting for reindexing to be complete before servicing any request

Some Triton core services work around the limitations presented above by waiting
for the reindexing process to be complete before allowing _any_ request to be
handled.

For instance, sdc-napi [uses a restify handler that checks for a flag
representing whether or not all moray schema migrations have
completed](https://github.com/TritonDataCenter/sdc-napi/blob/4b413d47/lib/napi.js#L94-L97).

It works for sdc-napi because I believe its maintainers determined that the
current reindexing time for any of its moray buckets falls within the acceptable
range that is allowed for Triton core services on JPC and on premises (40
minutes).

However, this is or will not necessarily be true for all services because the
duration of that process cannot be known in advance in all cases. The duration
of the reindexing process could exceed the migration window allocated for a
given service, and could thus cause it to not be available for an undetermined
amount of time.

##### Time to reindex grows with the number of objects

The main reason for which the amount of time required to complete the reindexing
process cannot be known in advance is that it is inherently associated with the
number of objects in the bucket being reindexed. The more objects there are in a
given moray buckets, the more time it takes to reindex all objects.

The following table describes the time it takes to reindex a given number of
rows after adding one index of type `'string'` on an actual hardware setup, in
the "nightly-2" datacenter:

| number of rows | reindexing time |
|----------------|-----------------|
| 100000 | 2.5 minutes |
| 200000 | 5 minutes |
| 300000 | 8.2 minutes |
| 400000 | 12 minutes |
| 500000 | 17 minutes |
| 600000 | 23 minutes |
| 700000 | 29 minutes |
| 800000 | 40 minutes |
| 900000 | 47 minutes |
| 1000000 | 59 minutes |

We can see from this table that the time it takes to reindex a bucket seems to
grow faster than the number of objects.

These measurements were performed by running the `index.js` program available in
the [moray-reindex-benchmark
repository](https://github.com/misterdjules/moray-reindex-benchmark) from the
sdc-docker core service zone in the nightly-2 datacenter.

The buckets did not contain any data other than the field added and reindexed.

The number of objects reindexed by `reindexObjects` request was `100`.

##### Inefficient data retention policies

Currently, the main factor that contributes to the growth of the number of
objects in moray buckets is that some Triton core services have a data retention
policy that is less than optimal. For instance, VMAPI keeps all VM objects in
its moray buckets, including VM objects that represent VMs that have been
destroyed long ago.

As a result, the number of objects can only grow significantly over time. With
the rise of docker usage, and potentially more short lived Docker containers
being created over time, the growth of VM objects stored in VMAPI's moray
buckets could accelerate.

VMAPI, with about 400K objects in us-east1 for its `vmapi_vms` bucket, is a good
example of a service using moray that might not be able to wait for reindexing
to be done before a migration can be considered complete.

The current numbers of VM objects stored in VMAPI's `vmapi_vms` moray bucket in
each datacenter is following:

| DC | all VMs | active (non-destroyed & non-failed) |
|----|---------|--------------------------------------|
| us-east-1| 416659 | 4453 |
| ams1| 183051 | 1360 |
| sw-1 | 161631 | 3075 |
| us-west-1 | 139873 | 2456 |
| us-east-2 | 109559 | 1045 |
| us-east-3 | 104613 | 783 |
| us-east-3b | 62865 | 444 |

The number of all VMs is growing constantly in most DCs because there is
currently no scrubbing of destroyed VMs. As a result, even if the current amount
of data and the typical changes made when adding indexes would make a full
reindex operation last less than the maintenance window, it might be only a
matter of time before this becomes a problem.

If we look at the number of non-destroyed and non-failed VMs, we can see they
are much lower. Working with that order of magnitude could make the requirement
of reindexing to be complete before using a moray bucket acceptable, but:

1. relying on that constraint is not acceptable for the general use case.

2. optimizing the data retention policy for VMAPI is a separate problem that is
   potentially hard to solve due users of Triton relying on that data to be
   around indefinitely.

#### Only waiting for reindexing to be done to enable endpoints using new indexes

Another approach to solving VMAPI's use case would be to disable specific
endpoints that use specific new indexes that haven't been reindexed yet.

The problem with this approach is that it's difficult to determine which
endpoint uses which index. As code evolves, it seems that this would quickly
become even more difficult to manage.

## Generalization of ZAPI-747's use case

The VMAPI use case described by ZAPI-747 may seem specific to the VMAPI service,
but it seems that it could apply to a lot of other Triton core services.

Over time, changes made to these services sometimes require the introduction of
new moray indexes. For instance, a new IMGAPI endpoint may require to search
through IMGAPI objects by filtering them based on a property that wasn't indexed
before, and for which a new index was added.

Due to the `findobjects` limitations described in the previous section, correct
`findobjects` results for requests using a new index can only be guaranteed once
the bucket to which that index was added is fully reindexed.

During that time window, silently returning an erroneous result might not result
in any damage to the integrity of the system for some requests. However it's not
difficult to imagine other requests for which e.g destructive actions can be
performed.

Because most Triton core services do not suffer from the same pathological data
retention policy as VMAPI does, the workaround that consists of waiting for the
reindexing process to be complete could be an acceptable solution. In fact, as
we mentioned before, this is how the NAPI service solves this problem.

This section presents why it seems that relying on that workaround for any
Triton core service is not reasonable.

### Growth targets for Triton datacenters

Besides Triton core services' data retention policies, the main cause for the
growth of the number of objects is the amount of usage that a given Triton data
center experiences.

As usage grows, more objects are stored in core services' moray buckets and the
time it takes for a reindexing operation to complete increases until it can
become unacceptable.

### Time to reindex grows with the number of fields

Another factor that goes into the time it takes for a full bucket reindex to
complete is the number of fields that need to be reindexed. The more fields that
need to be reindexed, the longer it takes for the operation to complete.

A typical migration would add only a few new indexes at most, but it shows that
the time it takes for a reindex operation to complete can vary significantly
depending on code changes and the data stored.

Thus it is difficult to predict how long that process will take for any given
service at any given time, or even to determine an upper bound.

### Other factors that contribute to an increase in reindexing time

Other factors can cause the reindexing process to take more time: the load of
the system on which the moray instance and/or the underlying database engine
run, bugs in the reindexing process, unavailability of any of these services,
etc.

These events cannot be known in advance and thus add to the unpredictability of
the process for any Triton core service.

## Other use cases

The limitations described in the previous section seem to be a problem by
themselves, and it's not difficult to come up with plenty of concrete use cases
that are negatively impacted besides the Triton core services moray buckets
migration use case described previously.

For instance, performing a search on VM objects with `sdc-vmapi` in the global
zone and using a composite search filter that includes an unindexed field can
silently return an incorrect result.

In the following command, `state` is a VM objects' field that is indexed,
whereas `fs_allowed`'s index is missing:

```
$ sdc-vmapi /vms?predicate=$(urlencode '{"and": [{ "eq": [ "state", "running" ]}, { "eq": ["fs_allowed", "*ufs*" ] } ]}')
```

As a result, this command _will_ silently return erroneous results. See
[ZAPI-756] for an example of such a problem encountered by a user of Triton.

I believe that these other use cases haven't attracted a lot of attention
because most if not all users have been able to work around them.

## Proposed solution

This section presents a solution to all of the `findobjects` limitations
described earlier in this document.

This solution solves both the VMAPI specific use case presented in this document
(tracked by [ZAPI-747]), the more general Triton core API moray buckets migration
use case, and any other use case described in this document, such as the ones
tracked by [MORAY-104].

Different solutions for each of the limitations presented in the
section entitled "Current problems with findobjects requests using unindexed
fields" were available:

1. The `limit` problem can be solved by making sure that
`findobjects` search filters only include indexed fields that are ready to use
(that is, reindexed).

2. the problem with using non-string values for unindexed fields could be fixed
by updating the values types using the schema stored in the bucket cache, or by
allowing clients to send JSON-formatted filters which would include type
information.

3. The issue with not-yet-reindexed fields could be solved by fixing [the
`rowToObject` function](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/common.js#L816-L860)
to not [delete values for fields that are being reindexed](https://github.com/TritonDataCenter/moray/blob/52d7669f/lib/objects/common.js#L849-L852).

However, only applying the changes to solve issues #2 and #3 would still not
guarantee reliable results for all `findobjects` requests, and solving issue #1
would solve all of them.

In other words, in order to serve a `findobjects` request reliably, __indexes
need to be present and ready to use (i.e reindexed) for every field used in the
search filter__.

The solution proposed in this document is that if a `findobjects` request uses
at least one field for which an index is not usable, and if its `options`
parameter sets its `requireIndexes` property to `true`, it results in an
`NotIndexedError`.

This change would solve the problematic use case presented in that document,
where a user of moray needs to add new indexes to an existing moray bucket and
use them from a Triton core service.

In that case, the only new requirement after opting-in into this new interface
would be to handle errors returned by `findobjects` requests until the
reindexing process is complete.

`findobjects` requests using newly added indexes will fail for a period of time
that is at best equivalent to the duration of the reindexing process, and at
worse to the duration of the reindexing process plus the bucket cache's eviction
delay (currently set to 5 minutes).

### Implementation details

The goal is to allow moray clients to be able to opt into the mode where
`findObjects` requests respond with an error if the moray service that handles
them cannot guarantee that all fields included in the search filter represent
index that can be used.

#### Introduction of a "metadata" message in the moray protocol

However, since moray servers do not respond with an error when unhandled
parameters are sent with a given request, it is not possible to rely on servers
that haven't been upgraded to support handling the `requireIndexes: true`
parameter to respond with errors.

To handle the case of moray servers not supporting this new parameter, the
protocol of the communication between moray clients and servers will need to be
changed if the `requireIndexes` option is set to true.

When the `requireIndexes` parameter is set, the first `data` event received by
moray clients will be considered to be a `metadata` record. A metadata record is
a record that has a property named `_handledOptions`. The value of this property
will be an array of strings containing the name of all options that can be
handled by the server (not restricted to just the options that were passed with
the request).

Including the `requireIndexes` option, these options names are:

* `req_id`
* `limit`
* `offset`
* `sort`
* `noLimit`
* `no_count`
* `sql_only`
* `noBucketCache`
* `timeout`
* `requireIndexes`

If the first `'data'` event received by the moray client is not a metadata
record (possibly because the client sent the request to a Moray server that does
not support handling the `requireIndexes` option), and if the `requireIndexes`
option is set to true, the client will emit an `error` event on the request with
an `UnhandledOptionsError` Error instance.

If the `requireIndexes` option is not set to true, the moray client will not
enforce the presence of a metadata record.

#### Changes to the node-moray client's API

node-moray's API will be changed so that:

1. a `requireIndexes` option can be passed to `findObjects` requests

2. a new `UnhandledOptionsError` `'error'` event will be emitted in the case
   this `requireIndexes` option is set to true and the first `data` event
   emitted for the response does not contain the value `requireIndexes` in the
   event's `_handledOptions` property.

In order to make it both convenient for new programs using the moray client that
want to opt-in into that behavior, and for existing programs who want to opt-in
into that behavior _per request_, both the node-moray's constructor API and the
`findObjects` method's API will be changed.

##### Changes to the Moray constructor

A new `requireIndexes` property on the `options` parameter will be handled. When
the value of this property is set to `true`, _all_ `findObjects` requests
performed via this client will be considered to require indexes, or they will
emit:

1. a `UnhandledOptionsError` `'error'` event if the server does not respond with
   a metadata record as the first data event.

2. a `NotIndexedError` `'error'` event if the server responds with a metadata
   record, but at least one field used in a `findObjects` request's search
   filter has an index that is not usable.

This method of opting into the proposed solution will be recommended for any new
program that can rely on the presence of the server-side support.

##### Changes to the findObjects method

The `findobjects` method will accept an additional `requireIndexes` property on
its `options` parameter. When the value of this property is set to `true`, _only
this specific_ `findObjects` request will be considered to require indexes and
it will emit:

1. a `UnhandledOptionsError` `'error'` event if the server does not respond with
   a metadata record as the first data event.

2. a `NotIndexedError` `'error'` event if the server responds with a metadata
   record, but at least one field used in this `findObjects` request's search
   filter has an index that is not usable.

This method of opting into the proposed solution will be recommended for any new
program that __cannot_ rely on the presence of the server-side support.

#### Changes to the moray server

##### Handling of the findObjects' requireIndexes option

The moray server will support a new option for `findObjects` requests named
`requireIndexes`. When the value of this option is `true`, the server will check
that none of the fields used in the search filter:

1. is present in the bucket's `reindex_active` array
2. is not present in the bucket's `index` array

Otherwise, it will respond with a `NotIndexedError` error.

##### Sending an additional metadata record for each findObjects response

For every `findObjects` request, regardless of whether the `requireIndexes`
option is present/set to `true`, a new `metadata` record will be sent as the
first `data` record of the response if the property
`internalOpts.sendHandledOptions` of the `findObjects`' `options` parameter is
set to true.

This record will have only one property named `_handledOptions`, and will
include all the `findObjects` options that can be handled by the server.

Including the `requireIndexes` option, these options names are:

* `req_id`
* `limit`
* `offset`
* `sort`
* `noLimit`
* `no_count`
* `sql_only`
* `noBucketCache`
* `timeout`
* `requireIndexes`

#### Performance impact

The performance of a `findObjects` request could be impacted as the proposed
changes would require to:

1. run additional moray server's pipeline "handlers"

2. perform additional properties/array items lookups in JavaScript to check that
   no unusable index is being used

3. send one additional metadata record as part of the response

In order to quantify this impact, this section documents what performance tests
have been done so far.

Three different cases were tested:

1. a moray client with the changes described in this document connecting to a
   moray server without them

2. a moray client and server with the changes described in this document, with
   the moray client _not_ passing the `requireIndexes: true` option to the
   `findObjects` method

3. a moray client and server with the changes described in this document, with
   the moray client passing the `requireIndexes: true` option to the
   `findObjects` method, thus enabling the new stricted behavior

The performance impact was measured by running
[misterdjules/moray-benchmark-search-filters/benchmark-reindex.js](https://github.com/misterdjules/moray-benchmark-search-filters/blob/49fda6fe/benchmark-reindexed.js)
as following:

```
(I=0; while [ $I -lt 1000 ]; do node benchmark-reindexed.js -n 1000 --norecreatebucket; I=$((I + 1)); done)
```

This program uses a moray client with the changes presented in this document,
connected to a moray server with or without these changes that handles only
these requests.

It performs `findObjects` requests using composite search filters that only
include fields whose indexes are usable.

The moray server would run in a SmartOS zone running itself in a VMWare VM. Then
the following DTrace script running in the same zone would measure the latency
of `findObjects` requests:

```
#!/usr/sbin/dtrace -s

#pragma D option quiet

moray*:::findobjects-start
{
        latency[arg0] = timestamp;
        bucket[arg0] = copyinstr(arg2);
        filter[arg0] = copyinstr(arg3);
}

moray*:::findobjects-done
/latency[arg0]/
{
@[bucket[arg0], filter[arg0], arg1] =
    quantize(((timestamp - latency[arg0]) / 1000000));

  @latencies_avg[strjoin(bucket[arg0], "_avg"), filter[arg0], arg1] =
    avg(((timestamp - latency[arg0]) / 1000000));

  @latencies_min[strjoin(bucket[arg0], "_min"), filter[arg0], arg1] =
    min(((timestamp - latency[arg0]) / 1000000));

  @latencies_max[strjoin(bucket[arg0], "_max"), filter[arg0], arg1] =
    max(((timestamp - latency[arg0]) / 1000000));

        latency[arg0] = 0;
        bucket[arg0] = 0;
        filter[arg0] = 0;
}
```

which is basically [the `find_latency` DTrace script shipped with moray](https://github.com/TritonDataCenter/moray/blob/d23510d05c04a7f4da5e061965c4c351d3246e77/bin/find_latency.d),
with a small change that displays minimum, maximum and average latencies in
addition to a quantized distribution.

The results are shown below for three different combinations mentioned above of
joyent/moray (using code from master or from the MORAY-104 branch),
joyent/node-moray (using code from master or from the MORAY-104 branch) and how
the moray client's `findObjects` is called (whether `requireIndexes: true` is
passed or not):

1. moray's master/node-moray's MORAY-104 branch/requireIndexes: undefined:

   ```
   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_boolean=true))                             500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@@@                                    132      
              64 |@@@@@@@@@@@@@@@@@@@@@@                   560      
             128 |@@@@@@@@@@@                              265      
             256 |@@                                       41       
             512 |                                         2        
            1024 |                                         0        

   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_number=42))                                500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@@@                                    123      
              64 |@@@@@@@@@@@@@@@@@@@@@@@@                 588      
             128 |@@@@@@@@@@                               246      
             256 |@                                        37       
             512 |                                         6        
            1024 |                                         0        

   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_string=sentinel))                          500
           value  ------------- Distribution ------------- count    
               8 |                                         0        
              16 |                                         2        
              32 |@@@@                                     105      
              64 |@@@@@@@@@@@@@@@@@@@@@@@                  565      
             128 |@@@@@@@@@@@                              279      
             256 |@@                                       38       
             512 |                                         10       
            1024 |                                         1        
            2048 |                                         0        

   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_boolean=true))                             500              117
   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_number=42))                                500              119
   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_string=sentinel))                          500              127
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_string=sentinel))                          500               30
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_boolean=true))                             500               34
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_number=42))                                500               37
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_boolean=true))                             500              674
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_number=42))                                500              877
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_string=sentinel))                          500             1295
   ```

2. moray's MORAY-104/node-moray's MORAY-104/requireIndexes: undefined

   ```
   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_number=42))                                500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@@@@                                   152      
              64 |@@@@@@@@@@@@@@@@@@@@@@@@@                614      
             128 |@@@@@@@@                                 208      
             256 |@                                        22       
             512 |                                         4        
            1024 |                                         0        

   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_boolean=true))                             500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@@@@                                   146      
              64 |@@@@@@@@@@@@@@@@@@@@@@@@@                618      
             128 |@@@@@@@@                                 207      
             256 |@                                        24       
             512 |                                         5        
            1024 |                                         0        

   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_string=sentinel))                          500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@@                                     109      
              64 |@@@@@@@@@@@@@@@@@@@@@@@@@@               642      
             128 |@@@@@@@@                                 211      
             256 |@                                        30       
             512 |                                         8        
            1024 |                                         0        

   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_number=42))                                500              108
   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_boolean=true))                             500              109
   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_string=sentinel))                          500              116
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_string=sentinel))                          500               32
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_boolean=true))                             500               37
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_number=42))                                500               40
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_number=42))                                500              938
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_string=sentinel))                          500              964
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_boolean=true))                             500             1003
   ```

3. moray's MORAY-104/node-moray's MORAY-104/requireIndexes: true

   ```
   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_boolean=true))                             500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@                                      77       
              64 |@@@@@@@@@@@@@@@@@@@@@@@@                 604      
             128 |@@@@@@@@@@@                              278      
             256 |@                                        35       
             512 |                                         6        
            1024 |                                         0        

   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_number=42))                                500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@                                      87       
              64 |@@@@@@@@@@@@@@@@@@@@@@@                  582      
             128 |@@@@@@@@@@@                              280      
             256 |@@                                       46       
             512 |                                         5        
            1024 |                                         0        

   moray_benchmark_reindexed                           (&(uuid=*)(reindexed_string=sentinel))                          500
           value  ------------- Distribution ------------- count    
              16 |                                         0        
              32 |@@@                                      67       
              64 |@@@@@@@@@@@@@@@@@@@@@@@                  583      
             128 |@@@@@@@@@@@@                             305      
             256 |@@                                       42       
             512 |                                         2        
            1024 |                                         1        
            2048 |                                         0        

   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_boolean=true))                             500              122
   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_number=42))                                500              126
   moray_benchmark_reindexed_avg                       (&(uuid=*)(reindexed_string=sentinel))                          500              127
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_boolean=true))                             500               37
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_string=sentinel))                          500               38
   moray_benchmark_reindexed_min                       (&(uuid=*)(reindexed_number=42))                                500               42
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_number=42))                                500              743
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_boolean=true))                             500              916
   moray_benchmark_reindexed_max                       (&(uuid=*)(reindexed_string=sentinel))                          500             1063
   ```

From these results, it seems that the duration of the execution of the
`findObjects` handler in the moray server is not significantly longer. Note
however that these measurements do not account for the extra data message sent
to the moray client when `requireIndexes: true` is passed to `findObjects`.

### Backward compatibility

In addition to solving the use cases described in this document, opting-in by
setting this new flag would be recommended for any use case as it would return
identical results at worse, and more correct results at best.

However, because some code relies on the current erroneous behavior, it is
important to provide a backward compatible interface. Thus, this solution should
be opt-in, and clients that want to switch to the strict behavior would need to:

1. upgrade to a version of node-moray that implements the changes proposed in
   this document

2. pass the `requireIndexes` option to the `findObjects` method of node-moray
   client instances and set it to `true` like following ("morayClient" is an
   instance of a moray client created with `require('moray').createClient()`):

    ```
    morayClient.findobjects('bucketName', filter, {requireIndexes: true}, callback);
    ```

Once all usage of `findobjects` requests switch to the strict behavior, it
should be possible to make this the default in moray without causing any
significant breakage. It could then allow to remove support for filtering on
unindexed fields, which could make some of the existing moray code base simpler.

#### Workaround for old moray clients connected to new moray servers

Let's consider the following use case as an example:

1. a user of an old node-moray client passes the `requireIndexes: true` to its
   `findObjects` method

2. the resulting `findObjects` request is handled by a moray server that
   implements the changes presented in this document

3. all fields included in the search filter have usable indexes

The moray client would receive a metadata record as the first record of the
response, even though it does not know how to handle it, and would forward it as
a data record to the user.

In this case, the user of the old moray client would need to handle the metadata
record explicitly, which is not desirable.

In order to work around that problem, a new internal property named
`internalOpts` for the `options` parameter of `findObjects` requests will be
handled by the moray server.

Metadata records will be sent by a moray server implementing this RFD _only_ if
this property is set to `{sendHandledOptions: true}`. Moray clients implementing
this RFD will set this value.

Users of old moray clients would need to pass `{internalOpts:
{sendHandledOptions: true}}` to `findObjects` requests when connected to new
moray servers in order for the request to error with an internal error, which is
not considered a valid use case.

### Forward compatibility

Even if not recommended, after the proposed changes to the moray server are
released as part of a Triton release, it is possible that some Triton setups
will not upgrade to that release.

When a moray client uses the new `requireIndexes` option for `findObjects`
requests handled by a moray server that was not upgraded to support it, an error
event will be emitted on the corresponding request object.

The recommendation in this case is to handle the error event and to fall back to
a behavior that is reasonable for users and operators.

Using the work done as part of RFD 26 as an example, the new VOLAPI service
needs to be able to search VM objects based on a new `volumes`
field.

An index will be added on this field in VMAPI, and all `ListVms` requests
handled by VMAPI will set the `requireIndexes` option for `findObjects` to
`true` _only_ when the `volumes` parameter is sent as part of the
request's parameters.

When this request emits an `'UnhandledOptionsError'` error event because the
moray server is not at a version that supports checking whether indexes are
usable, or a `'NotIndexedError'` error because the reindexing process for the
`volumes` field is not completed, VMAPI will respond with a HTTP
503 `UnsupportedSearchError` error.

The consumer of VMAPI, in this case VOLAPI, will fall back to sending a HTTP 503
`UnsupportedError` error to its clients, which will then output explicit and
clear error messages to end users.

In this specific example, sdc-docker will send an error message mentioning that
a volume can't be deleted when a user runs a `docker volume rm` command.
CloudAPI will send an error message mentioning that the user needs to pass a
`force: true` input parameter to the `DeleteVolume` endpoint in order to delete
a volume.

The rationale for the generic use case is that every consumer of moray opting
into the ``requireIndexes: true`` option of `findObjects` requests will do this
as part of a new feature of Triton.

Thus, it should always be able to provide a fallback that, in the worse case, is
to communicate to users and operators that moray needs to be upgraded in order
to be able to use that new feature.

<!--- Issue links -->
[MORAY-104]: https://smartos.org/bugview/MORAY-104
[MORAY-413]: https://smartos.org/bugview/MORAY-413
[MORAY-428]: https://smartos.org/bugview/MORAY-428
[ZAPI-747]: https://smartos.org/bugview/ZAPI-747
[ZAPI-756]: https://smartos.org/bugview/ZAPI-756

<!-- Other RFDs -->
[RFD 26]: ../0026
