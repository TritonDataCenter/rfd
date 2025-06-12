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

The purpose of this S3 compatibility layer is to translate S3 object requests into 
Manta buckets API requests, which falls in the category of system call
emulation. This scheme has been proven successful in the past, relevant examples are 
[https://github.com/TritonDataCenter/sdc-docker/blob/master/docs/api/features/smartos.md](sdc-docker),
[https://github.com/TritonDataCenter/illumos-joyent/blob/810178ebcf77c96767a9f5c95f845858c5c6f41c/usr/src/uts/common/brand/lx/os/lx_brand.c#L34](Linux Branded Zones). For this specific type of emulation (Object storage API emulation) there are already cases
where it has been implemented successfully, for example [https://min.io/docs/minio/linux/reference/s3-api-compatibility.html](MinIO)


## 1. Design Discussion

### S3 compatibility Layer Description

A S3 compatibility layer will allow a user of an S3 compatible object store, to store
objects into Manta Object store, in order to achieve this premise this layer should be able
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
only focus on allowing users to store objects into Manta and percolade Amazon S3's
request metadata to equivalent Manta metadata attributes for objects stored
through this compatibility layer.
Finally, we want to leverage the current Manta architecture and components
whenever possible.


### Implementation Discussion

These set of objectives and their constraints, will help shape the design
decisions for the S3 compatibility layer. 

#### Authentication 

AWS since [https://aws.amazon.com/es/blogs/aws/amazon_s3/](2006) has been using
SigV2 to authenticate requests, support for this authentication scheme has been 
obsoleted in favor of
[https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html](SigV4). 
That aliviates some of the work as we will need just to concentrate in
implementing SigV4. 
AWS authentication scheme relies in the use of Access Key ID and  symmetric keys

