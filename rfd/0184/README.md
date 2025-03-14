---
authors: Nahum Shalman <nahum.shalman@mnx.io>
state: predraft
---

# RFD 184 SmartOS BHYVE Image Builder Brand

## Problem statement

We currently build our BHYVE images in a `joyent` branded zone which has to be manually
modified to allow access to sensitive device nodes
[as documented](https://github.com/TritonDataCenter/triton-cloud-images/blob/401f1b8/README.md#granting-permission-for-a-zone-to-use-bhyve)
This need for additional `zonecfg` manipulation makes it hard to automate dynamically creating zones suitable for doing these builds.

## Proposed Solution

- Create a dedicated brand that already has access to those device nodes
- Wire up vmadm to know how to use that brand to simplify spinning up build zones
- Wire up just enough in triton to know how to create zones using that brand so that operators can use it
- Wire up automation to automate building (and testing) images on a regular cadence

## Implementation Details

The brand will need a name. For the moment we are using `builder` as the new brand name.

Phase 1: 
- Create the brand in illumos-joyent
- Wire it up into vmadm in smartos-live
- Verify that it works to do bhyve builds as documented in triton-cloud-images

Phase 2:
- Verify that Triton doesn't automatically expose this new brand to CloudAPI in a dangerous way
- Figure out what else is needed in Triton to make it possible for operators to use this brand
- Do it
- Test it

Phase 3:
- Automate builds from triton-cloud-images
- Automate testing of those builds
- Automate shipping those builds after verification

## Open Questions

- Is there a better name to use than `builder`?
- How do we keep this functionality from being visible to non-admins from CloudAPI?
  - In theory this should at least be partly gated by packages. If no packages
    reference this brand, it shouldn't be possible to accidentally use it.
