---
author: Carlos Neira <carlos.neira@mnx.io>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2025 MNX Cloud, Inc.
-->

# RFD 186 S3 Compatibility for Manta

## Introduction

This document will describe the proposed design of a S3 compatibility layer 
for Manta object storage, that will allow third party S3 clients to interact
with Manta.

A driven force for Manta v2 was to move from the traditional Manta Directory API
to a flat structure that resembles more how objects are layout in S3, part of
that effort was the creation of a Manta Buckets API that implement most of the
operations that are expected for an S3 Bucket to support. The shortcomming of
that design was although those operations were supported we still rely on the
Manta set of applications that access this new Buckets API.

The purpose of this S3 compatibility layer is to translate S3 object requests in
to 
Manta buckets API requests, which falls in the category of system call
emulation. This scheme has been proven successful in the past, relevant examples
 are 
[1] sdc-docker, [2] Linux Branded Zones. For this specific type of emulation 
(Object storage API emulation) there are already cases where it has been impleme
nted 
successfully, for example [3]MinIO


## 1. Design Discussion

### S3 compatibility Layer Description

A S3 compatibility layer will allow a user of an S3 compatible object store, to 
store
objects into Manta Object store, in order to achieve this premise this layer sho
uld be able
to present to an S3 client a minimal API surface that will allow existing S3
clients to start using a Manta Object Store without modification of their
current scripts.

### Desired S3 Operations

At a minimum, the Manta S3 Compatibility layer should be able to translate the
following S3 requests into manta-buckets-api requests.

	- S3 bucket creation via PUT /{bucket}
	- S3 bucket listing via GET /
	- S3 bucket deletion via DELETE /{bucket}
	- S3 bucket check existence via HEAD /{bucket}
	- S3 object upload via PUT /{bucket}/{object}
	- S3 PUT object conditional requests (If-None-Match, If-Match)
	- S3 object download via GET /{bucket}/{object}
	- S3 object deletion via DELETE /{bucket}/{object}
	- S3 object metadata retrieval via HEAD /{bucket}/{object}
	- S3 bucket content listing via GET /{bucket}
	- S3 bucket creation via PUT /{bucket}
	- S3 bucket listing via GET /
	- S3 bucket deletion via DELETE /{bucket}
	- S3 bucket check existence via HEAD /{bucket}
	- S3 object upload via PUT /{bucket}/{object}
	- S3 PUT object conditional requests (If-None-Match, If-Match)
	- S3 object download via GET /{bucket}/{object}
	- S3 object deletion via DELETE /{bucket}/{object}
	- S3 object metadata retrieval via HEAD /{bucket}/{object}
	- S3 bucket content listing via GET /{bucket}
	- AWS v2 signature authentication
	- AWS v4 signature authentication
	- S3 bucket creation via PUT /{bucket}
	- S3 bucket listing via GET /
	- S3 bucket deletion via DELETE /{bucket}
	- S3 bucket check existence via HEAD /{bucket}
	- S3 object upload via PUT /{bucket}/{object}
	- S3 PUT object conditional requests (If-None-Match, If-Match)
	- S3 object download via GET /{bucket}/{object}
	- S3 object deletion via DELETE /{bucket}/{object}
	- S3 object metadata retrieval via HEAD /{bucket}/{object}
	- S3 bucket content listing via GET /{bucket}
	- AWS v2 signature authentication
	- AWS v4 signature authentication

### Implementation Requirements and Constraints

In terms of API constraints we will not implement a translation for the
following S3 features: Versioning, Replication, Object Lock, Select, Lifecycle,
Server Side Encryption, Web site hosting and Batch. The compatibility layer will
only focus on allowing users to store objects into Manta and percolade Amazon S3
's request metadata to equivalent Manta metadata attributes for objects stored
through this compatibility layer. Finally, we want to leverage the current Manta
architecture and components whenever possible.

### Proposed solution

These set of objectives and their constraints, will help shape the design
decisions for the S3 compatibility layer. 

#### S3 gateway 

The S3 gateway service will translate AWS S3 object and bucket requests into Man
ta Storage operations. While the gateway won't support all S3 features, nonetheless
it will enable users to interact with Manta Object Storage as a standard S3 endpoint,
as long as the user uses the subset of features that Manta Storage will expose
in it's S3 gateway.

The gateway layer will translate requests from *AWS S3* clients to *Manta V2* bu
cket storage, exposing the Manta object storage operations that have S3 equivalents.
 This will allow existing applications and scripts that use S3 to work with Mant
a Object Storage through the S3 gateway seamlessly.
To achieve S3 compatibility will need to think on how to address the following
problems.

1. Authentication.
2. S3 request translation to Manta Storage requests equivalents whenever is
   applicable.
3. Buckets subdomains.
4. Billing
5. Multipart Uploads

##### 1. Authentication 

AWS since [https://aws.amazon.com/es/blogs/aws/amazon_s3/](2006) has been using
Sigv2 to authenticate requests, support for this authentication scheme has been 
obsoleted in favor of SigV4. That aliviates some of the work required as efforts
will be concentrated in SigV4 implementation. Sigv4 authentication scheme relies
in the use of Access Key ID and Access Secret Key ID which are used to authentica-
te requests[7].
In Manta the authentication scheme  relies in the tuple MANTA_USER and a ssh MD5
fingerprint which is used to authenticating requests using
[https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures-00](the HTTP
Signature over TLS) scheme. Manta authentication is done through [4]Unified foun
dation directory service which is cached by [5]mahi, the first stepping
stone towards S3 compatiblity is to add the required metadata to UFDS (access ke
ys per account), in order for mahi to be able to start using them, efforts
towards this goal have already been integrated in TRITON-2152, but more efforts 
are required to access keys to be usable in the mahi authentication cache.


##### 2. Convert S3 requests into Manta Object storage requests.

The manta-buckets already possess an API surface alike AWS S3 buckets, with that
in mind he will convert all incoming requests to the S3 gateway into
manta-buckets requests.


```
                             ┌─────────────────────┐
                             │                     │
                             │      S3 Client      │
                             │                     │
                             └─────────────────────┘
                                        ▲
                                        │
                   1. S3 Bucket Request │     4. S3 gateway Response
                   GET|PUT|DELETE|HEAD  │       GET|PUT|DELETE|HEAD
                    /{bucket}/{object}  │
                                        │
┌───────────────────────────────────────┼───────────────────────────────────────┐
│Triton Datacenter                      │                                       │
│                                       │                                       │
│                                       │                                       │
│                                       │                                       │
│                                       ▼                                       │
│                             ┌───────────────────┐                             │
│                             │    S3-gateway     │                             │
│                             └───────────────────┘                             │
│                                       ▲                                       │
│                                       │                                       │
│                                       │                                       │
│                                       │        3. MANTA Buckets Response      │
│           2. MANTA BucketsRequest     │           GET|PUT|DELETE|HEAD         │
│             GET|PUT|DELETE|HEAD       │                                       │
│        {manta-bucket}/{manta-object}  │                                       │
│                                       │                                       │
│                                       │                                       │
│                                       ▼                                       │
│                         ┌────────────────────────────┐                        │
│                         │                            │                        │
│                         │                            │                        │
│                         │     manta-buckets-api      │                        │
│                         │                            │                        │
│                         │                            │                        │
│                         └────────────────────────────┘                        │
│                                                                               │
│                                                                               │
│                                                                               │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

1. A client sends a request to upload or delete an object to a Triton bucket thr
ough the `s3-gateway` service using an existing S3 script.
2. The `s3-gateway`  service processes the request by generating a request for `
manta-buckets-api` and converting the S3 request metadata into Manta Object stor
age equivalents. 
3. The `manta-buckets-api` responds with a success/error back to the `s3-gateway
.`
4. The S3 gateway converts the `manta-buckets-api` response to an S3-compatible 
success or error response.

The 



### References

[1] https://github.com/TritonDataCenter/sdc-docker/blob/master/docs/api/features
/smartos.md
[2] https://github.com/TritonDataCenter/illumos-joyent/blob/810178ebcf77c96767a9
f5c95f845858c5c6f41c/usr/src/uts/common/brand/lx/os/lx_brand.c#L34
[3] https://min.io/docs/minio/linux/reference/s3-api-compatibility.html
[4] https://github.com/TritonDataCenter/sdc-ufds/tree/master
[5] https://github.com/TritonDataCenter/mahi/tree/master
[6] https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html
[7] https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html
