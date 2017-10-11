---
authors: Richard Kiene <richard.kiene@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+94%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent Inc.
-->

# RFD 94 Global Zone metrics in CMON

## Introduction

### Motivation

Presently operators of Triton and Manta do not have a frictionless way to obtain
metrics and health data about compute nodes (CN) and each CN's Global Zone (GZ).
Operators tend to install a myriad of scripts and/or agents in the GZ and plumb
the output to a collection source of their choosing. This is problematic for a
number of reasons, kstat metrics are not easily interpreted in their raw form
without consulting source code, CLI applications that consume kstats and other
metrics require a significant amount of parsing and transformation, operators
need to spend time writing and installing scripts which takes time away from
other tasks, etc..

### Goal

Provide a consistent view of available SmartOS metrics via the
[CMON API](https://github.com/joyent/triton-cmon), as well as provide a way to
discover each available metric endpoint via the
[CMON API](https://github.com/joyent/triton-cmon) so that operators can consume
a fleet of CN metrics as they would kstats from a single CN. Additionally, we
should provide thorough documentation for each metric provided so that operators
do not need to guess or consult source code.

### Requirements

* CN and GZ metrics should only be available to accounts with the operator role
* Metrics and Discovery will be secured by HTTPS and TLS authentication
* Must support the Prometheus text format like VM metrics does currently
* Must provide an easy path for future metrics formats to be added (e.g. Influx)
* Must not introduce any new components (e.g. agents, vms, etc.) to CMON
* Must follow the same rules and requirements detailed in
[RFD 27](https://github.com/joyent/rfd/tree/master/rfd/0027)

### Assumption

Since it is a requirement that this RFD not introduce any new components and
that it must adhere to the requirements of RFD 27, the assumptions of the
author is that this RFD can detailed, to the point, and brief. Below you will
only see what will be added. If you're uncertain about how these will work,
please refer to RFD 27.

## Proposed Solution

### The following routes will be added to [triton-cmon](https://github.com/joyent/triton-cmon/)

* Compute node metrics discovery:

```
/v1/cn/discover
---
{
    "compute_nodes":[
        {
            "server_uuid":"44454c4c-5000-104d-8037-b7c04f5a5131"
        },
        ...
    ]
}
```

* Compute node metrics:

```
/v1/cn/metrics
---
# HELP time_of_day System time in seconds since epoch
# TYPE time_of_day counter
time_of_day 1499915882106
# HELP arcstats_misses ARC misses
# TYPE arcstats_misses counter
arcstats_misses 3739816645
# HELP cpu_info_model CPU model
# TYPE cpu_info_model gauge
cpu_info_model 42
...
```

### The following route will be added to [triton-cmon-agent](https://github.com/joyent/triton-cmon-agent)

* Compute node metrics:

```
/v1/cn/metrics
---
# HELP time_of_day System time in seconds since epoch
# TYPE time_of_day counter
time_of_day 1499915882106
# HELP arcstats_misses ARC misses
# TYPE arcstats_misses counter
arcstats_misses 3739816645
# HELP cpu_info_model CPU model
# TYPE cpu_info_model gauge
cpu_info_model 42
...
```

### The following functionality will be added to [triton-cns](https://github.com/joyent/triton-cns)

* When compute nodes come and go, CNS will detect the change and create a DNS
CNAME record which points to the CMON proxy A RECORD.

```
<cn_uuid>.cm.triton.zone CNAME <region>.cmon.triton.zone
```
