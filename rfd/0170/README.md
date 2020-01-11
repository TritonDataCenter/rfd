---
authors: rui@joyent.com,rob.johnston@joyent.com
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+170%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc.
-->

# RFD 170 Manta Picker Component

This RFD describes the Manta Picker component.

## Introduction

In mantav1, the "picker" is part of the `manta-muskie` (webapi) component.  It is responsible for selecting the list of destination storage nodes for new objects on a PUT request.  It functions by querying the `manta_storage` bucket on shard 1 at a default interval of 30s.  Recently, we have found that picker can
overload the shard 1 Moray instance [MANTA-4091].

The new Rebalancer project introduces yet another consumer of the data in the ```manta_storage``` bucket.  For mantav2, in order to avoid hot-shard issues that would be caused by all of the rebalancer and muskie service instances hitting shard 1 to get storage utilization data, the picker functionality has been split out into a separate service (manta-picker).  This new service provides an interface for retrieving a cached view of the contents of the manta_storage bucket via the /poll REST endpoint.  The Rebalancer will be designed to leverage the manta-picker and the mantav2 equivalent of muskie (buckets-api) will be modified to use the manta-picker service [MANTA-4821].



## Requirements

- Picker instances should report their availability to DNS via registrar.
- Multiple picker zones can be deployed for scalability.
- Picker tunables should be added to SAPI, and controlled there. 



## Interfaces

### GetSharks (GET /poll)
Returns a list of storage nodes found in the `manta_storage` bucket, sorted by the ```manta_storage_id``` field.  Because the list of makos can be quite large, this endpoint enforces pagination to limit the response size.

```poll``` will implement a cursor-based pagination scheme using the mako's ```manta_storage_id``` as the cursor value.`

#### Inputs
| Field    | Type   | Description                                                  |
| -------- | ------ | ------------------------------------------------------------ |
| after_id | String | return results for mako with a storage id greater than "after_id" (default="0") |
| only_id  | String | return result for only the mako specified by the storage id "only_id" |
| limit    | Number | max number of results to return (default/max = 500)          |

#### Example

Get up to the first 100 results:

    /poll?limit=100

Get up to the next 100 results:

```/poll?limit=100&after_id=<last_id>```

### FlushCache (POST /flush)

Forces the picker's cached view of the manta_storage bucket to be immediately invalidated and refreshed.  The only intended consumer of this API is the Rebalancer, which will call this API after marking a storage node as read-only, prior to evacuating the objects on it.

This interfaces takes no input parameters.

## Assumptions and Risks

- A given Manta deployment requires significantly less than M picker components
where M is the total number of muskie processes (M = Muskie zones * Muskie SMF
instances).
- The Picker's intermittent updates will provide a sufficiently current view for
use with the Rebalancer's selection of a destination storage node. 




[MANTA-4091]: https://jira.joyent.us/browse/MANTA-4091
[MANTA-4821]: https://jira.joyent.us/browse/MANTA-4821
[RFD 162]: https://github.com/joyent/rfd/blob/master/rfd/0162/README.md
