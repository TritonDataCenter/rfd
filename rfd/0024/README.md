---
authors: Angela Fong <angela.fong@joyent.com>
state: pre-draft
---

# RFD 24: Designation API improvements to facilitate platform update

## Problems at hand

- The current designation strategies for provisioning instances are mainly
  driven by capacity and infrastructural constraints. New instances may land
  on compute nodes that have ancient platform versions. Unfortunately those CNs
  are the prime candidates for rebooting to a newer platform. Owners of the
  new instances may be disrupted sooner than expected even if scheduled reboot
  is done infrequently (say, twice a year).
- Owner of instances provisioned to old platforms cannot take advantage of new
  features or bug fixes that are only available on the newer platforms. To
  prevent version incompatibility problems, the min_platform attributes in
  application images are sometimes bumped up by the image preparers. The process
  is manual and causes confusion at times.
- Docker API does not support the spreading of instances across multiple servers/racks.
  Users who have applications configured for HA may still experience down time when the
  instances in the cluster happen to be located on the same server or rack that is being
  rebooted. CloudAPI allows the use of 'locality' hints (to provision near or far
  from another set of instances) though user doesn't have much visibility into how
  spread out the compute nodes are. Also if a provisioning attempt failed, CloudAPI
  does not provide any error code to indicate if it was due to the locality constraint
  or some other problems (more on this in [RFD 22](https://github.com/joyent/rfd/tree/master/rfd/0022)).

## Desired State

- **DAPI to bias towards placing new instances to CNs with newer platform versions:**
  With this, over time, servers with older platform versions can be 'drained'
  when containers are destroyed and re-created.
- **CloudAPI and sdc-docker to provide better support for spreading out a cluster:**
  CloudAPI currently allows user to provide 'locality' hints to place new containers
  away from certain containers but it requires exact container IDs to be passed. This
  forces user to keep track of the IDs in their provisioning scripts. It will be much
  easier if user can specify the hint based on a machine tag or label. This will work
  naturally with Docker Compose and CNS since the instances are tagged with service
  names. DAPI can query the machine tag to locate all existing instances of the same
  compose project and service owned by the user on the fly when the service is scaled
  up. We'll also need a way to pass the strict rack locality requirement (DAPI attempts
  first to locate a different rack, then a different server, but doesn't provide a
  switch for strict placement on a different rack.)
- **AdminUI to support locality:**
  A less important requirement is to provide the same ability to operators to pass
  locality hints when provisioning on behalf of an end user. This is possible through
  VMAPI though the current documentation is missing this information.
- **Exposing locality information in List/GetMachine CloudAPI:**
  It is a nice-to-have feature and has been brought up by one customer ([PUBAPI-1175]
  (https://devhub.joyent.com/jira/browse/PUBAPI-1175)).
  Server uuid is already exposed in CloudAPI. Maybe all that we need is exposing the
  rack identifiers. However they may contain physical location information that is better
  hidden from end users.
- **All compute nodes have their racks marked and kept accurate:**
  This is more an operator action item than a software change. For the designation
  spread across racks to be useful, the rack attribute needs to be filled in
  consistently.

## Open Questions

- How do we rank the newer platform criterion against other soft requirements?
  We may want to apply it after considering locality, and make 'stacking' a lower
  priority (currently the bias is to stack servers full before moving to emptier ones).
  Marsell has brought up the need for a bigger enhancement to change the algorithm
  to calculate a weighted score which will provide the flexibility. We may consider
  to move towards this new approach. The challenge will likely be in knowing how to
  allocate the weights without a lot of trial and error in production.
- How feasible is it to assign rack identifiers to all existing compute nodes in JPC?
- Are rack identifiers something that can be exposed to end users? Do we need another
  attribute to present the rack locality information?
- (A somewhat unrelated question) Does sdc-oneachnode and sdc-server API support
  rack id based filtering to allow actions to be performed at a rack level?
