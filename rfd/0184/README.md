---
authors: Nahum Shalman <nahum.shalman@mnx.io>
state: predraft
---

# RFD 184 SmartOS BHYVE Image Builder Brand

## Problem statement

We currently build our BHYVE images in a `joyent` branded zone which has to be manually
modified to allow access to sensitive device nodes
[as documented](https://github.com/TritonDataCenter/triton-cloud-images/blob/401f1b8/README.md#granting-permission-for-a-zone-to-use-bhyve)

## Proposed Solution

- Create a dedicated brand that already has access to those device nodes
- Wire up vmadm to know how to use that brand to simplify spinning up build zones
- Wire up triton to know how to create zones using that brand
- Wire up automation to automate building (and testing) images on a regular cadence

## Implementation Details

## Open Questions

- How do we keep this functionality from being visible to non-admins from CloudAPI?
