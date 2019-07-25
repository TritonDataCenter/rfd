---
authors: Brittany Wald <brittany.wald@joyent.com>, Kelly McLaughlin <kelly.mclaughlin@joyent.com>, Dave Eddy <dave.eddy@joyent.com>
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

## Versioning

TBD

## Authentication

Authentication will be handled in the same manner as it is currently with Manta
as described [here](https://apidocs.joyent.com/manta/api.html#authentication).

## Common Request Headers

These are request headers that are used with every request.

* Authorization
* Host

## Common Response Headers

These are response headers that are present in all responses.

* Server
* Date
* x-request-id
* x-response-time
* x-server-name

## Object names

There are very few limitations imposed on object names. Object names must
contain only valid UTF-8 characters and may be a maximum of 1024 characters in
length. Object names may include forward slash characters (or any other valid
UTF-8 character) to create the suggestion of a directory hierarchy for a set of
object even though the buckets system uses a flat namespace. Care must be taken,
however, to properly URL encode all object names to avoid problems when
interacting with the server.

## Routes

We will add the following routes to Muskie to support Manta Buckets. See `MANTA-3898`
for more information.

### Buckets

#### Check allowed methods for buckets (OPTIONS /:login/buckets)

Returns the HTTP methods allowed for this resourcein the `Allow` response header
value. No response body is returned.

Request headers

* N/A

Response headers

* Allow

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

List all buckets for an account's namespace.

The `type` of each object in the `\n` separated JSON stream should be `bucket`
or `group`, since each object returned should represent a Manta bucket or a
group of buckets. A successful request should return an HTTP status code of
200, as well as records containing a `name`, a `type` (of "bucket" or "group",
as stated previously), and `mtime` for buckets.

By default, a request will return up to a maximum of 1024 records (can be set
with the `limit` query parameter outlined below).  If there are more records to
be retrieved, the server will respond with the `Next-Marker` header set, and it
is the job of the client to handle pagination and request the next set of
results.  The client should continue requesting pages with the query parameter
`marker` set to the value of the `Next-Marker` header from the previous
response, until the server no longer returns a `Next-Marker` header.

Request headers

* N/A

Response headers

* `Next-Marker` (optional)

Query Parameters

* `limit` (integer, optional) limit the number of results returned, defaults to `1024`
* `prefix` (string, optional) string prefix names must match to be returned
* `marker` (string, optional) the continuation marker for the next page of results
* `delimiter` (character, optional) a character to use to group names with a common prefix

Sample Request
```
$ manta /$MANTA_USER/buckets -X GET

GET /$MANTA_USER/buckets HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Date: Tue, 18 Dec 2018 20:38:18 GMT
Authorization: $Authorization
```

Sample Response
```
$ manta "/$MANTA_USER/buckets" -X GET -i
HTTP/1.1 200 OK
Connection: close
Date: Wed, 24 Jul 2019 20:30:20 GMT
Server: Manta
x-request-id: db299430-ae51-11e9-9ac3-9f05ab77498b
x-response-time: 335
x-server-name: 42d242a4-7fba-4d3b-ae3f-405982bd49da
Transfer-Encoding: chunked

{"name":"bucket-01","type":"bucket","mtime":"2019-06-26T18:35:33.792Z"}
{"name":"bucket-02","type":"bucket","mtime":"2019-06-26T18:35:34.809Z"}
{"name":"bucket-03","type":"bucket","mtime":"2019-06-26T18:35:35.726Z"}
...
```

Prefix

```
$ manta "/$MANTA_USER/buckets?prefix=z" -X GET
{"name":"z-bucket-01","type":"bucket","mtime":"2019-07-17T20:21:51.771Z"}
{"name":"z-bucket-02","type":"bucket","mtime":"2019-07-17T20:21:55.742Z"}
{"name":"z-bucket-03","type":"bucket","mtime":"2019-07-17T20:21:59.637Z"}
{"name":"z-bucket-04","type":"bucket","mtime":"2019-07-17T20:22:03.033Z"}
{"name":"z-bucket-05","type":"bucket","mtime":"2019-07-17T20:22:06.192Z"}
```

Limit

```
$ manta "/$MANTA_USER/buckets?prefix=z&limit=2" -X GET
{"name":"z-bucket-01","type":"bucket","mtime":"2019-07-17T20:21:51.771Z"}
{"name":"z-bucket-02","type":"bucket","mtime":"2019-07-17T20:21:55.742Z"}
```

Limit & Marker (pagination)

Note: Some headers removed for brevity

```
$ manta "/$MANTA_USER/buckets?prefix=z&limit=2" -X GET -i
HTTP/1.1 200 OK
Next-Marker: z-bucket-02

{"name":"z-bucket-01","type":"bucket","mtime":"2019-07-17T20:21:51.771Z"}
{"name":"z-bucket-02","type":"bucket","mtime":"2019-07-17T20:21:55.742Z"}
```

```
$ manta "/$MANTA_USER/buckets?prefix=z&limit=2&marker=z-bucket-02" -X GET -i
HTTP/1.1 200 OK
Next-Marker: z-bucket-04

{"name":"z-bucket-03","type":"bucket","mtime":"2019-07-17T20:21:59.637Z"}
{"name":"z-bucket-04","type":"bucket","mtime":"2019-07-17T20:22:03.033Z"}
```

```
$ manta "/$MANTA_USER/buckets?prefix=z&limit=2&marker=z-bucket-04" -X GET -i
HTTP/1.1 200 OK

{"name":"z-bucket-05","type":"bucket","mtime":"2019-07-17T20:22:06.192Z"}
```

Delimiter

```
$ manta "/$MANTA_USER/buckets?prefix=z&delimiter=-" -X GET
{"name":"z-","type":"group"}
```

```
$ manta "/$MANTA_USER/buckets?delimiter=-" -X GET
{"name":"bucket-","type":"group"}
{"name":"full-","type":"group"}
{"name":"one-","type":"group"}
{"name":"slash-","type":"group"}
{"name":"two-","type":"group"}
{"name":"z-","type":"group"}
```

#### Check bucket (HEAD /:login/buckets/:bucket)

Ping a bucket as specified in the HTTP Request-URI. A successful response should
return an HTTP status code of 200, and no response body.

Request headers

* N/A

Response headers

* N/A

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
create a bucket, set the HTTP Request-URI to the buckets path you want to make.
There is no request body. An HTTP status code of 204 is returned on
success and a 409 is returned in the event the bucket already exists.

Request headers

* N/A

Response headers

* N/A

Sample Request
```
$ manta /$MANTA_USER/buckets/newbucket \
    -X PUT

PUT /$MANTA_USER/buckets/newbucket HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Date: Wed, 19 Dec 2018 21:38:00 GMT
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
return an HTTP status code of 204, and no response data. If the bucket does not
exist then an HTTP status code of 404 is returned. If the bucket is not empty
the deletion is not performed and an HTTP status code of 409 is returned.

Request headers

* N/A

Response headers

* N/A

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

The `type` of each object in the `\n` separated JSON stream should be
`bucketobject` or `group` since each object returned should represent a Manta
bucket object or a group of objects. A successful request should return an HTTP
status code of 200, as well as records containing a `name`, an `etag`, a
`size`, a `type` (of "bucketobject" or "group", as stated previously), a
`contentType` of "application/json; type=bucketobject", a `contentMD5` string,
and an `mtime`.

By default, a request will return up to a maximum of 1024 records (can be set
with the `limit` query parameter outlined below).  If there are more records to
be retrieved, the server will respond with the `Next-Marker` header set, and it
is the job of the client to handle pagination and request the next set of
results.  The client should continue requesting pages with the query parameter
`marker` set to the value of the `Next-Marker` header from the previous
response, until the server no longer returns a `Next-Marker` header.

Request headers

* N/A

Response headers

* `Next-Marker` (optional)

Query Parameters

* `limit` (integer, optional) limit the number of results returned, defaults to `1024`
* `prefix` (string, optional) string prefix  names must match to be returned
* `marker` (string, optional) the continuation marker for the next page of results
* `delimiter` (character, optional) a character to use to group names with a common prefix

Sample Request
```
$ manta /$MANTA_USER/buckets/slash-bucket-objects -X GET

GET /$MANTA_USER/buckets HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Date: Tue, 18 Dec 2018 20:38:18 GMT
Authorization: $Authorization
```

Sample Response
```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects" -X GET -i
HTTP/1.1 200 OK
Connection: close
Date: Wed, 24 Jul 2019 20:46:08 GMT
Server: Manta
x-request-id: 10663390-ae54-11e9-9ac3-9f05ab77498b
x-response-time: 144
x-server-name: 42d242a4-7fba-4d3b-ae3f-405982bd49da
Transfer-Encoding: chunked

{"name":"foo","type":"bucketobject","etag":"13916fe0-517a-cb0b-9656-abbdf1f425a9","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-24T20:47:31.699Z"}
{"name":"thing/a","type":"bucketobject","etag":"62251003-649f-6da5-f0e6-ba31b639547e","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:43.635Z"}
{"name":"thing/b","type":"bucketobject","etag":"e218e998-6a5c-4fe6-e7a0-9c6945555e20","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:48.582Z"}
{"name":"thing/c","type":"bucketobject","etag":"5014f5e8-f377-c5d0-aec6-c6aec3668b2d","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:53.803Z"}
{"name":"thing/d","type":"bucketobject","etag":"db4a7059-0749-69e1-8f71-d0c13f34b146","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:59.987Z"}
{"name":"thing/e","type":"bucketobject","etag":"b4b8eaa3-af6c-48de-970f-ae4c873a9c0a","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:27:04.831Z"}
```

Prefix

```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects?prefix=thing" -X GET
{"name":"thing/a","type":"bucketobject","etag":"62251003-649f-6da5-f0e6-ba31b639547e","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:43.635Z"}
{"name":"thing/b","type":"bucketobject","etag":"e218e998-6a5c-4fe6-e7a0-9c6945555e20","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:48.582Z"}
{"name":"thing/c","type":"bucketobject","etag":"5014f5e8-f377-c5d0-aec6-c6aec3668b2d","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:53.803Z"}
{"name":"thing/d","type":"bucketobject","etag":"db4a7059-0749-69e1-8f71-d0c13f34b146","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:59.987Z"}
{"name":"thing/e","type":"bucketobject","etag":"b4b8eaa3-af6c-48de-970f-ae4c873a9c0a","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:27:04.831Z"}
```

Limit

```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects?prefix=thing&limit=2" -X GET
{"name":"thing/a","type":"bucketobject","etag":"62251003-649f-6da5-f0e6-ba31b639547e","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:43.635Z"}
{"name":"thing/b","type":"bucketobject","etag":"e218e998-6a5c-4fe6-e7a0-9c6945555e20","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:48.582Z"}
```

Limit & Marker (pagination)

Note: Some headers removed for brevity

```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects?prefix=thing&limit=2" -X GET -i
HTTP/1.1 200 OK
Next-Marker: thing/b

{"name":"thing/a","type":"bucketobject","etag":"62251003-649f-6da5-f0e6-ba31b639547e","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:43.635Z"}
{"name":"thing/b","type":"bucketobject","etag":"e218e998-6a5c-4fe6-e7a0-9c6945555e20","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:48.582Z"}
```

```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects?prefix=thing&limit=2&marker=thing/b" -X GET -i
HTTP/1.1 200 OK
Next-Marker: thing/d

{"name":"thing/c","type":"bucketobject","etag":"5014f5e8-f377-c5d0-aec6-c6aec3668b2d","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:53.803Z"}
{"name":"thing/d","type":"bucketobject","etag":"db4a7059-0749-69e1-8f71-d0c13f34b146","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:26:59.987Z"}
```

```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects?prefix=thing&limit=2&marker=thing/d" -X GET -i
HTTP/1.1 200 OK

{"name":"thing/e","type":"bucketobject","etag":"b4b8eaa3-af6c-48de-970f-ae4c873a9c0a","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-22T18:27:04.831Z"}
```

Delimiter

Note: `%2f` is `/` encoded

```
$ manta "/$MANTA_USER/buckets/slash-bucket/objects?delimiter=%2f" -X GET -i
HTTP/1.1 200 OK
Connection: close
Date: Wed, 24 Jul 2019 20:51:36 GMT
Server: Manta
x-request-id: d3f8e1e0-ae54-11e9-9ac3-9f05ab77498b
x-response-time: 129
x-server-name: 42d242a4-7fba-4d3b-ae3f-405982bd49da
Transfer-Encoding: chunked

{"name":"foo","type":"bucketobject","etag":"13916fe0-517a-cb0b-9656-abbdf1f425a9","size":2,"contentType":"application/json; type=bucketobject","contentMD5":"SfaKXIST7CwL9ImCHCH8Ow==","mtime":"2019-07-24T20:47:31.699Z"}
{"name":"thing/","type":"group"}
```

#### Check object (HEAD /:login/buckets/:bucket/objects/:object)

Ping a bucket object as specified in the HTTP Request-URI. A successful response
should return an HTTP status code of 200, and no response body.

Request headers

* `If-Modified-Since`
* `If-Unmodified-Since`
* `If-Match`
* `If-None-Match`

Response headers

* `Durability-Level`
* `Content-Type`
* `Content-MD5`
* `Content-Length`
* `Etag`
* `Last-Modified`

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
Etag: b3d3e058-4638-eeb9-b433-83393bc19a71
Last-Modified: Fri, 19 Jul 2019 16:51:19 GMT
Durability-Level: 2
Content-Length: 18
Content-MD5: UE8cRSdpJ/cMOc6ofHJFgw==
Content-Type: application/json
Date: Mon, 01 Apr 2019 22:59:51 GMT
Server: Manta
x-request-id: dadb6460-54d1-11e9-8ff7-393f00357a3f
x-response-time: 297
x-server-name: $zonename
```

#### Create or overwrite object (PUT /:login/buckets/:bucket/objects/:object)

Request headers

* `Content-MD5`
* `Durability-Level`
* `If-Unmodified-Since`
* `If-Match`
* `If-None-Match`

Response headers

* `Durability-Level`
* `Computed-MD5`
* `Content-Length`
* `Etag`
* `Last-Modified`

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/newobject.json \
    -X PUT \
    -H "Content-Type: application/json" \
    -d '{"example":"text"}'

PUT /$MANTA_USER/buckets/mybucket/objects/newobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Content-Type: application/json
Date: Wed, 19 Dec 2018 21:41:40 GMT
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

Request headers

* `If-Modified-Since`
* `If-Unmodified-Since`
* `If-Match`
* `If-None-Match`

Response headers

* `Durability-Level`
* `Content-Type`
* `Content-MD5`
* `Content-Length`
* `Etag`
* `Last-Modified`

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json -X GET

GET /$MANTA_USER/buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
Date: Wed, 19 Dec 2018 21:53:35 GMT
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 200 OK
Connection: close
Accept-Ranges: bytes
Etag: b3d3e058-4638-eeb9-b433-83393bc19a71
Last-Modified: Fri, 19 Jul 2019 16:51:19 GMT
Content-Type: application/json
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

The following HTTP conditional headers are supported:
* `If-Unmodified-Since`
* `If-Match`
* `If-None-Match`

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

### Get object metadata (GET /:login/buckets/:bucket/objects/:object/metadata)

Request headers

* `If-Modified-Since`
* `If-Unmodified-Since`
* `If-Match`
* `If-None-Match`

Response headers

* `Durability-Level`
* `Content-Type`
* `Content-MD5`
* `Content-Length`
* `Etag`
* `Last-Modified`

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json/metadata -X GET

GET /$MANTA_USER/buckets/mybucket/objects/myobject.json/metadata HTTP/1.1
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
Etag: b3d3e058-4638-eeb9-b433-83393bc19a71
Last-Modified: Fri, 19 Jul 2019 16:51:19 GMT
Durability-Level: 2
Content-Length: 18
Content-MD5: UE8cRSdpJ/cMOc6ofHJFgw==
Content-Type: application/json
m-custom-header: myheadervalue
Date: Wed, 19 Dec 2018 21:53:35 GMT
Server: Manta
x-request-id: 88c12790-03d8-11e9-bc2d-0501f01773f1
x-response-time: 355
x-server-name: $zonename
```

### Update object metadata (PUT /:login/buckets/:bucket/objects/:object/metadata)

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json/metadata -X PUT -H 'm-custom-header: myupdatedheadervalue'

PUT /$MANTA_USER/buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:53:35 GMT
m-custom-header: myupdatedheadervalue
Authorization: $Authorization
```

Sample Response
```
HTTP/1.1 204 No Content
Connection: close
Etag: 4d39c55e-a204-6a2b-f220-c5566b3c657a
Last-Modified: Thu, 20 Jun 2019 13:16:56 GMT
m-custom-header: myupdatedheadervalue
Date: Thu, 20 Jun 2019 13:16:56 GMT
Server: Manta
x-request-id: ad59b5d0-935d-11e9-9d8b-cd762420ff2a
x-response-time: 147
x-server-name: 6a05c503-0313-4666-a24c-5a24c2777f07

```

## Errors

New errors for buckets include:

BucketAlreadyExists
BucketNotEmpty
BucketNotFound
ObjectNotFound


## Unsupported operations

* Snaplinks: object-level versioning will not be supported at this time.
* Multi-Part Uploads: this is not yet supported for bucket objects.
* Jobs: compute functionality is not available with buckets.
