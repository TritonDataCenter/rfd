---
authors: Brian Bennett <brian.bennett@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+172%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019 Joyent
-->

# RFD 172 CNS Aggregation

## Problem

Triton Container Name Service (CNS) provides service discovery for applications through DNS names. Instances can be assigned [specialized tags][cns-tags] to have their IP address(es) returned when a particular DNS resource record is queried. This allows for "round-robin" DNS redundancy. Generally a friendly CNAME record points to the CNS service record. CNS, however works only in the context of a single datacenter. Best practices call for distributing services across multiple availability zones, and since there can only be one CNAME value for a DNS resource record, CNS cannot be used to provide service discovery across multiple availability zones. Manta is an example of one such application that has API endpoints in multiple datacenter. The Manta Operators Guide currently states that external DNS is managed manually.

[cns-tags]: https://github.com/joyent/triton-cns/blob/master/docs/metadata.md#instance-tags-vmapi
[manta-dns]: https://github.com/joyent/manta/blob/master/docs/operator-guide/architecture.md#external-service-discovery

## Proposed Solution

To address the issue, we introduce the CNS Aggregator (aggregator). The aggregator would be a DNS server that receives zone data from the Triton cns server for multiple Triton Data Centers and aggregates all records for datacenters within a specific region into a single DNS zone. Any one aggregator will not be limited to a single region, but only datacenters with a common region will be aggregated together.

CNS includes documentation for replicas. We will introduce official images for replicas that will include instructions on deploying replica images which will include aggregation.

## Implementation

We will generate new replica images that require accept a configuration that may look like the following.

```
{
  "zones": {
    "us-west-1.cns.example.com": "2001:db8:1::1:200",
    "us-west-2.cns.example.com": "2001:db8:1::2:200",
    "us-west-3.cns.example.com": "2001:db8:1::3:200",
    "us-east-1.cns.example.com": "2001:db8:2::1:200",
    "us-east-2.cns.example.com": "2001:db8:2::2:200",
    "eu-west-1.cns.example.com": "2001:db8:3::1:200"
  },
  "aggregations": {
    "us-west.cns.example.com": [
      "us-west-1.cns.example.com",
      "us-west-2.cns.example.com",
      "us-west-3.cns.example.com"
    ],
    "us-east.cns.example.com": [
      "us-east-1.cns.example.com",
      "us-east-2.cns.example.com"
    ],
    "eu-west.cns.example.com": [
      "eu-west-1.cns.example.com"
    ]
  }
}
```

Here we have five Triton data centers in three regions. The name server will be configured for **eight** DNS zones. One for each datacenter, plus one for each region. In this example, although `eu-west-1` does not need aggregation, it may be included to make transition easier if datacenters are added in the future.

To perform aggregation, a task will be scheduled to run periodically that will perform the following pseudo-code.

```
for each aggregation; do
    for each datacenter; do
        axfr datacenter
        string replace datacenter_zone with aggregation_zone
        update aggregation_zone serial_number
    done
done
rndc reload
```

Once configured and the zone data has been transferred from the primary, querying a CNS service name with the region suffix will return all records of the associated service across all datacenters within that region.

## Goals

This service should be a core component of Triton, as much as CNS itself is. The build should use the standard eng build framework and generate images that can be easily deployed.

## Assumptions

We will will use bind 9.11 for the service. Bind is chosen due to our familiarity with its behavior. Version 9.11 is chosen because it is the current Extended Support Version (ESV) and [will be supported][bind-support] through 2021. It is expected that sometime during 2021 we will switch to 9.16, with support through 2023.

[bind-support]: https://www.isc.org/blogs/bind-release-strategy-updated/

## Open questions

1. Should these zone be owned by admin?
2. Should these zones be deployed via sdcadm?
3. Should these zones have access to Triton's admin network? (Nothing about them needs access to the admin network.)
    1. Should they be configured with config-agent? (Currently config-agent requires access to SAPI, which would require

## Pitfalls

1. Because all zone data is aggregated together indiscriminately, `NS` records for each region will include the `NS` records of all constituent zones. In each datacenter, `cns` should be configured with the same peers to avoid lookup errors. There is currently no way to enforce this within Triton.
