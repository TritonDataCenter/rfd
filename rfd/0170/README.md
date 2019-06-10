---
authors: rui@joyent.com
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+170%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 170 Manta Picker Component

This RFD describes the Manta Picker component.

## Introduction

Currently the "picker" is part of the `manta-muskie` (webapi) component.  It is
responsible for selecting the list of destination storage nodes for new objects 
on a PUT request.  It functions by querying the `manta_storage` bucket on shard
1 at a default interval of 30s.  Recently, we have found that picker can
overload the shard 1 Moray instance [MANTA-4091].  The new rebalancer project,
[RFD 162], will also require use of the picker.  For these two main reasons this
RFD proposes to split picker out of muskie into its own component.

## Approach and Requirements

The general approach for this work will be to copy the current picker
implementation into its own Manta component, and expose two REST API endpoints:
`poll` and `choose`.  The methods by which the picker queries the
`manta_storage` table and by which it chooses the destination sharks will not be
changed.  

- Picker components should report their availablity to DNS via registrar.
- Multiple picker zones can be deployed for scalability.
- Picker tunables should be added to SAPI, and controlled there. 


## Interfaces

### Poll
Returns a list of storage nodes found in `manta_storage`

#### Inputs
| Field        | Type    | Description                                      |
| ------------ | ------- | ------------------------------------------------ |
| force_update | Boolean | Force Picker to update its view of storage nodes |

#### Example
    GET /poll
	{
      "ruidc": [
		{
		  "availableMB": 196233,
		  "percentUsed": 14,
		  "filesystem": "/manta",
		  "datacenter": "ruidc",
		  "manta_storage_id": "1.stor.east.joyent.us"
		},

        ...

	  ],
      "robdc": [
		{
		  "availableMB": 196233,
		  "percentUsed": 17,
		  "filesystem": "/manta",
		  "datacenter": "robdc",
		  "manta_storage_id": "2.stor.east.joyent.us"
		},

        ...

	  ]
	}


### Choose

__TODO__

## Assumptions and Risks

- A given Manta deployment requires significantly less than M picker components
where M is the total number of muskie processes (M = Muskie zones * Muskie SMF
instances).
- The Picker's intermittent updates will provide a sufficently current view for
use with the Rebalancer's selection of a destination storage node. 




[MANTA-4091]: https://jira.joyent.us/browse/MANTA-4091
[RFD 162]: https://github.com/joyent/rfd/blob/master/rfd/0162/README.md
