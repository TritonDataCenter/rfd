---
authors: Brittany Wald <brittany.wald@joyent.com>
state: draft
discussion: 'https://github.com/joyent/rfd/issues?q=%22RFD+155%22'
---
<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Joyent, Inc
-->

# RFD 155 Manta Buckets API

This RFD will describe the new buckets API for the Manta storage service. The
functional purpose of this requires some background understanding of Manta's
capabilities today.

We expect that each directory or object creation requires about the same
amount of database work. Because of our usage of a metadata tier, which, among
other things, ensures that database records (metadata) are all around the same
size regardless of the size of the actual object stored to disk, we describe
our workload capacity in terms of TPS (transactions per second).

This is related to, but not the same as, total throughput in bytes. This is
because we use a hierarchical data storage filesystem. Whenever we create an
object, we may also have to create some number of its parent directories. On
average, the number of directories created in order to upload an object is 3.8.

Switching to an API which uses buckets will bring our ratio of objects created
to database records created to 1:1. This will improve write performance, as
well as simplify conversions from database TPS to bytes throughput.


# HTTP API

We use a RESTful API design. For now, this includes the ability to create, get,
delete, and list buckets as well as objects in buckets. Eventually this API
will need to expand to include the ability to do multi-part uploads.


## Headers

These are headers we will use on every request.


#### Authentication

`Authorization` -- Existing RBAC mechanisms will be used to authenticate
requests.

#### Versioning

Semantic versioning. Current: `0.0.0`

#### Date

RFC 1123.

#### Host

`*.manta.joyent.com`

#### Content-Length

Ensure that we handle zero-byte objects. Zero-byte objects with a trailing
slash may be treated as folders later.


## Routes

We will add the following routes to Muskie to support Manta Buckets. See `MANTA-3898`
for more information.


### Buckets

#### Check allowed methods for buckets (OPTIONS /:login/buckets)

Returns the HTTP methods allowed for this resourcein the `Allow` response header
value. No response body is returned.

Sample Request
```
$ manta /$MANTA_USER/buckets -X OPTIONS

OPTIONS /$MANTA_USER/buckets HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Tue, 18 Dec 2018 20:38:18 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 204 No Content
Allow: OPTIONS, GET
Date: Tue, 18 Dec 2018 20:38:18 GMT
Server: Manta
x-request-id: da0b31b0-0304-11e9-a402-b30a36c2c748
x-response-time: 27
x-server-name: $zonename
```

#### List buckets (GET /:login/buckets)

List all buckets for an account's namespace. The `type` of each object in the `\n`
separated JSON stream should be `bucket`, since each object returned should
represent a Manta bucket. A successful request should return an HTTP status
code of 200, as well as records containing a `name`, a `type` (of "bucket", as
stated previously), and an `mtime`.

Sample Request
```
$ manta /$MANTA_USER/buckets -X GET

GET /$MANTA_USER/buckets HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Tue, 18 Dec 2018 20:38:18 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 200 OK
Date: Tue, 18 Dec 2018 20:38:18 GMT
Server: Manta
x-request-id: da0b31b0-0304-11e9-a402-b30a36c2c748
x-response-time: 27
x-server-name: $zonename
Transfer-Encoding: chunked

{"name":"hello","type":"bucket","mtime":"2018-12-04T01:50:54.018Z"}
{"name":"mybucket","type":"bucket","mtime":"2018-12-14T03:18:10.567Z"}
```

#### Check bucket (HEAD /:login/buckets/:bucket)

Ping a bucket as specified in the HTTP Request-URI. A successful response should
return an HTTP status code of 200, and no response body.

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket -X HEAD -vvv

HEAD /$MANTA_USER/buckets/mybucket HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Mon, 01 Apr 2019 22:50:10 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 200 OK
Connection: close
Date: Mon, 01 Apr 2019 22:50:10 GMT
Server: Manta
x-request-id: 80e3e320-54d0-11e9-8c2b-2bfe93ce4d12
x-response-time: 141
x-server-name: $zonename
```

#### Create bucket (PUT /:login/buckets/:bucket)

Create a bucket if it does not already exist. Your private namespace
begins with `:/login/buckets`. You can create buckets in that namespace. To
create a bucket, set the HTTP Request-URI to the buckets path you want to make
or update, and set the `Content-Type` header to `application/json; type=bucket`.
There is no request body. An HTTP status code of 204 is returned on
success and a 409 is returned in the event the bucket already exists.

Sample Request
```
$ manta /$MANTA_USER/buckets/newbucket \
    -X PUT \
    -H "Content-Type: application/json; type=bucket"

PUT /$MANTA_USER/buckets/newbucket HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Content-Type: application/json; type=bucket
date: Wed, 19 Dec 2018 21:38:00 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 204 No Content
Connection: close
Date: Wed, 19 Dec 2018 21:38:00 GMT
Server: Manta
x-request-id: 82692740-0305-11e9-a402-b30a36c2c748
x-response-time: 185
x-server-name: $zonename
```

#### Delete bucket (DELETE /:login/buckets/:bucket)

Delete a bucket as specified in the HTTP Request-URI. A successful response will
return an HTTP status code of 204, and no response data.

Sample Request
```
$ manta /$MANTA_USER/buckets/newbucket -X DELETE

DELETE /$MANTA_USER/buckets/newbucket HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:39:56 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 204 No Content
Connection: close
Date: Wed, 19 Dec 2018 21:39:56 GMT
Server: Manta
x-request-id: ddb1f290-0304-11e9-a402-b30a36c2c748
x-response-time: 128
x-server-name: $zonename
```


### Objects

#### List objects (GET /:login/buckets/:bucket/objects)

List objects within a bucket.

TBD: Sorting parameters may be specified in the format:
`/:login/buckets?sorted=false` for unordered listing of bucket contents. `sorted=true`
would list in lexicographical order. Listing paths under prefixes would use the
format `:login/buckets?prefix={:filter}`.


The `type` of each object in the `\n` separated JSON stream should be `bucketobject`
since each object returned should represent a Manta bucket object. A successful
request should return an HTTP status code of 200, as well as records containing
a `name`, an `etag`, a `size`, a `type` (of "bucketobject", as stated
previously), a `contentType` of "application/json; type=bucketobject", a `contentMD5`
string, and an `mtime`.

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects -X GET

GET /$MANTA_USER/buckets/mybucket/objects HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:43:27 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 200 OK
Date: Wed, 19 Dec 2018 21:43:28 GMT
Server: Manta
x-request-id: da0b31b0-0304-11e9-a402-b30a36c2c748
x-response-time: 27
x-server-name: $zonename
Transfer-Encoding: chunked

{"name":"myobject.json","etag":"6bf98a73-6cc7-4afb-9e3c-4ea0693b4cf1","size":18,"type":"bucketobject","contentType":"application/json; type=bucketobject","contentMD5":"UE8cRSdpJ/cMOc6ofHJFgw==","mtime":"2018-12-18T22:05:01.102Z"}
{"name":"newobject.json","etag":"b56eb23c-90ce-47b3-9367-1f566d993d8e","size":18,"type":"bucketobject","contentType":"application/json; type=bucketobject","contentMD5":"UE8cRSdpJ/cMOc6ofHJFgw==","mtime":"2018-12-19T21:41:40.676Z"}
```

#### Check object (HEAD /:login/buckets/:bucket/objects/:object)

Ping a bucket object as specified in the HTTP Request-URI. A successful response
should return an HTTP status code of 200, and no response body.

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json -X HEAD -vvv

HEAD /$MANTA_USER//buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Mon, 01 Apr 2019 22:59:50 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 200 OK
Connection: close
Durability-Level: 2
Content-Length: 18
Content-MD5: UE8cRSdpJ/cMOc6ofHJFgw==
Content-Type: application/json; type=bucketobject
Date: Mon, 01 Apr 2019 22:59:51 GMT
Server: Manta
x-request-id: dadb6460-54d1-11e9-8ff7-393f00357a3f
x-response-time: 297
x-server-name: $zonename
```

#### Create or overwrite object (PUT /:login/buckets/:bucket/objects/:object)

Conditional headers may be supported.

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/newobject.json \
    -X PUT \
    -H "Content-Type: application/json; type=bucketobject" \
    -d '{"example":"text"}'

PUT /$MANTA_USER/buckets/mybucket/objects/newobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Content-Type: application/json; type=bucketobject
date: Wed, 19 Dec 2018 21:41:40 GMT
Authorization: $Authorization
Content-Length: 18
```

Sample Response
```
HTTP/1.1 204 No Content
Connection: close
Etag: b56eb23c-90ce-47b3-9367-1f566d993d8e
Last-Modified: Wed, 19 Dec 2018 21:41:40 GMT
Computed-MD5: UE8cRSdpJ/cMOc6ofHJFgw==
Date: Wed, 19 Dec 2018 21:41:40 GMT
Server: Manta
x-request-id: 82692740-0305-11e9-a402-b30a36c2c748
x-response-time: 185
x-server-name: $zonename
```

### Get object (GET /:login/buckets/:bucket/objects/:object)

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json -X GET

GET /$MANTA_USER/buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:53:35 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 200 OK
Connection: close
Accept-Ranges: bytes
Content-Type: application/json; type=bucketobject
Content-MD5: UE8cRSdpJ/cMOc6ofHJFgw==
Content-Length: 18
Durability-Level: 2
Date: Wed, 19 Dec 2018 21:53:35 GMT
Server: Manta
x-request-id: 88c12790-03d8-11e9-bc2d-0501f01773f1
x-response-time: 355
x-server-name: $zonename

{"example":"text"}
```

### Delete object (DELETE /:login/buckets/:bucket/objects/:object)

Conditional headers may be supported.

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json -X DELETE

DELETE /$MANTA_USER/buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:47:39 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 204 No Content
Connection: close
Date: Wed, 19 Dec 2018 21:47:40 GMT
Server: Manta
x-request-id: b4e96f40-03d7-11e9-bc2d-0501f01773f1
x-response-time: 251
x-server-name: $zonename
```


## Errors

New errors for buckets include:

ParentNotBucketError
ParentNotBucketRootError


## Unsupported operations

* Snaplinks: object-level versioning will not be supported at this time.
* Multi-Part Uploads: this is not yet supported for bucket objects.
* Jobs: compute functionality is not available with buckets.
