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

#### Authentication

`Authorization` -- Existing RBAC mechanisms will be used to authenticate
requests.

#### Versioning

Semantic versioning.
Current: `0.0.0`

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

#### List buckets (PUT /:login/buckets)

Sample Request
```
$ manta /$MANTA_USER/buckets -X GET

GET /$MANTA_USER/buckets HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Tue, 18 Dec 2018 20:38:18 GMT
Authorization: $Authorization

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

TODO

#### Create bucket (PUT /:login/buckets/:bucket)

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

HTTP/1.1 204 No Content
Connection: close
Date: Wed, 19 Dec 2018 21:38:00 GMT
Server: Manta
x-request-id: 82692740-0305-11e9-a402-b30a36c2c748
x-response-time: 185
x-server-name: $zonename
```

#### Get bucket (GET /:login/buckets/:bucket)

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket -X GET

GET /$MANTA_USER/buckets/mybucket HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:39:06 GMT
Authorization: $Authorization

HTTP/1.1 200 OK
Connection: close
Content-Type: application/json
Content-Length: 70
Content-MD5: /U2BUYH8SXcSO6Tyo7PTiA==
Date: Wed, 19 Dec 2018 21:39:06 GMT
Server: Manta
x-request-id: ddb1f290-0304-11e9-a402-b30a36c2c748
x-response-time: 128
x-server-name: $zonename

{"name":"mybucket","type":"bucket","mtime":"2018-12-18T22:04:55.518Z"}
```

#### Delete bucket (DELETE /:login/buckets/:bucket)

Sample Request
```
$ manta /$MANTA_USER/buckets/newbucket -X DELETE

DELETE /$MANTA_USER/buckets/newbucket HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:39:56 GMT
Authorization: $Authorization

HTTP/1.1 204 No Content
Connection: close
Date: Wed, 19 Dec 2018 21:39:56 GMT
Server: Manta
x-request-id: ddb1f290-0304-11e9-a402-b30a36c2c748
x-response-time: 128
x-server-name: $zonename
```


### Objects

#### List bucket contents unordered (GET /:login/buckets?sorted=false

TODO

#### List bucket contents in lexicographical order (GET /:login/buckets?sorted=true)

TODO

#### List paths under prefixes of the bucket (GET /:login/buckets?prefix={:filter})

TODO

#### List objects (GET /:login/buckets/:bucket/objects)

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects -X GET

GET /$MANTA_USER/buckets/mybucket/objects HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:43:27 GMT
Authorization: $Authorization

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

TODO

#### Create or overwrite object (PUT /:login/buckets/:bucket/objects/:object)

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

#### Conditionally create or overwrite object (PUT /:login/buckets/:bucket/objects/:object)

TODO

### Get object (GET /:login/buckets/:bucket/objects/:object)

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json -X GET

GET /$MANTA_USER/buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:53:35 GMT
Authorization: $Authorization

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

Sample Request
```
$ manta /$MANTA_USER/buckets/mybucket/objects/myobject.json -X DELETE

DELETE /$MANTA_USER/buckets/mybucket/objects/myobject.json HTTP/1.1
Host: *.manta.joyent.com
Accept: */*
date: Wed, 19 Dec 2018 21:47:39 GMT
Authorization: $Authorization

HTTP/1.1 204 No Content
Connection: close
Date: Wed, 19 Dec 2018 21:47:40 GMT
Server: Manta
x-request-id: b4e96f40-03d7-11e9-bc2d-0501f01773f1
x-response-time: 251
x-server-name: $zonename
```

### Conditionally delete object (DELETE /:login/buckets/:bucket/objects/:object)

TODO


## Unsupported operations

* Snaplinks: object-level versioning will not be supported at this time.
* Multi-Part Uploads: this is not supported for bucket objects.
