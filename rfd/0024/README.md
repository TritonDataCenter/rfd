---
authors: Angela Fong <angela.fong@joyent.com>
state: draft
---

# RFD 24 Designation API improvements to facilitate platform update

## Introduction

The designation API (DAPI) has a set of algorithms to determine where to place a
new compute instance. There are a number of knobs and dials for placement decisions.
In a nutshell, DAPI 'pipes' all available compute nodes through certain filtering
criteria, then ranks the eligible servers based on another set of criteria to pick
the most appropriate one:

**Filtering** (in the order they are applied):

|Criteria                         | Notes                                                   |
|---------------------------------|---------------------------------------------------------|
|hard-filter-running              |                                                         |
|hard-filter-invalid-servers      |                                                         |
|hard-filter-volumes-from         | picks the CN which has the docker volume to be mounted  |
|hard-filter-reserved             |                                                         |
|hard-filter-headnode             |                                                         |
|hard-filter-vm-count             | currently set to 224 due to vmadm performance issue     |
|hard-filter-capness              | prevents the mixing of workload with/without cpu caps   |
|hard-filter-vlans                | checks for fabric network compatibility                 |
|hard-filter-platform-versions    | checks against image min_platform value, N/A to Docker  |
|hard-filter-traits               |                                                         |
|hard-filter-sick-servers         |                                                         |
|hard-filter-overprovision-ratios |                                                         |
|hard-filter-min-ram              |                                                         |
|hard-filter-min-cpu              |                                                         |
|hard-filter-min-disk             |                                                         |
|soft-filter-locality-hints       | becomes a hard filter if --strict arg is 'true'; indicates which instances to provision near to (or away from); considers both rack and server co-location |

**Ranking** (only one of them should take effect):

|Sort Order                | Notes            |
|--------------------------|------------------|
|sort-min-ram              | default setting  |
|sort-max-ram              |                  |
|sort-min-owner            |                  |
|sort-random               |                  |
|pick-weighted-random      |                  |

As it is, the placement logic does not take into account the platform image version,
machine reboot schedule and hardware class. Currently operators have to track
some of this information outside of SDC, and manually reserve compute nodes
that are due for EOL or reboot.

## Problems at hand

- The current placement algorithms are mainly driven by capacity and infrastructural
  constraints. New instances may land on compute nodes that have ancient platform
  versions. Unfortunately those CNs are the prime candidates for rebooting to a newer
  platform. Owners of these new instances may be disrupted sooner than expected even
  when there is a well-spaced out reboot schedule.
- Instances provisioned to older platforms miss out on new features or bug fixes.
  To work around this, the min_platform values in application images are sometimes
  bumped up by the image preparers. The process is manual and may eliminate a large
  number of servers that are actually eligible for provisioning.
- Docker API does not support the use of locality hints at this time. Users who
  have applications configured for HA may still experience down time when the instances
  in the cluster happen to be located on the same server or rack that is being
  rebooted.
- Though CloudAPI allows the use of 'locality' hints, it requires users to pass the
  exact instance UUIDs to provision near to or away from. The burden is on the user
  to keep track of UUIDs. Also when a provisioning request failed, CloudAPI does
  not return any error code to indicate if it was due to the locality constraint
  or some other problems (more on this in [RFD 22](https://github.com/joyent/rfd/tree/master/rfd/0022)).

How much rack locality hints should play a role in DAPI is still subject to debate.
The likelihood for a rack-level failure is largely dependent on the data center
topology. The actual impact of switch failure, PDU failure or other adverse physical
conditions may make the effort to spread instances across racks irrelevant. On the other
hand, rack locality would matter more for machine reboot, assuming that it is usually
scheduled on a per-rack basis.

## Desired State

- **DAPI to bias towards placing new instances to CNs with newer platform versions:**
  With this, over time, servers with older platform versions can be 'drained'
  when containers are destroyed and re-created elsewhere.
- **DAPI to avoid placing new instances to CNs that are due for reboot soon:**
  The pre-requisite for this is to make available some memo attributes for operators
  to enter a planned reboot date or a batch number. Based on this information,
  DAPI can avoid placing new instances on a server that has impending reboot planned.
  This criterion may be treated as a hard filter (e.g. exclude servers that will be
  rebooted in N days, where N is configurable by operator), or as a sort order
  (i.e. return the server that has no or the farthest out reboot date). The former is
  likely too restrictive as there will be instances that have very short life-span.
- **DAPI to bias towards the 'better' hardware class:**
  The pre-requisite for this is to make available some memo attributes for operators
  to enter a hardware priority number for DAPI to consume. This requirement was brought
  up for the ease to EOL servers, rather than the ease to reboot. We may still
  want to take this into account for the overall DAPI enhancement.
- **CloudAPI and sdc-docker to provide better locality hint support:**
  Besides specific instance UUIDs, we may want to support the use of machine tags as
  locality hints. This will work naturally with Docker Compose and CNS since the members
  of a service are already tagged with the service name. DAPI can query the instance UUIDs
  on the fly using the tag name. There are however two concerns on how well this works:
  1) the lookup of instances will be incomplete when there are concurrent provisioning
  requests for a 'scale up' action, 2) the syntax is different from Docker Swarm's way
  of specifying 'affinity' (https://docs.docker.com/swarm/scheduler/filter).
- **All compute nodes have their racks marked and kept accurate:**
  This is more an operator action item than a software change. For the designation
  spread across racks to be useful, the rack attribute needs to be filled in
  consistently.
- **Portals to support locality:**
  Both user and operator portals have not caught up with the locality enhancement.
  They should allow user to specify locality hints in provisioning requests.
- **Exposing locality information in List/GetMachine CloudAPI:**
  It is a nice-to-have feature and has been brought up by one customer ([PUBAPI-1175]
  (https://devhub.joyent.com/jira/browse/PUBAPI-1175)).
  Server UUID is already exposed in CloudAPI. Rack identifiers, which may contain
  physical location information and allow end users to map/size our DCs, are best hidden
  from the end users. We may consider providing some kind of locality index instead.

## Open Questions

- How do we rank the different soft requirements? Choosing first a newer platform, then
  a later reboot date, then min RAM (stack a server full before moving to emptier ones)
  may be a logical choice. This is assuming that CNs with newer platforms are typically
  scheduled to reboot later. Having DAPI choose newer platforms and farther out reboot
  date will likely end up packing servers anyway. Marsell has also brought up the idea
  of moving towards a weighted score approach. The approach provides the flexibility of
  considering multiple factors simultaneously rather than linearly. The challenge with
  this will likely be knowing how to allocate the weights appropriately without a lot
  of trial and error.
- How should rack locality information be presented to end users? Should the actual
  rank identifiers be allowed in the case of on-prem deployment (where the information
  might be more useful to end users and less prone to abuse)?

## Other Thoughts

- To facilitate rolling reboot, tools such as sdc-oneachnode and sdc-server API may
  need to be enhanced to make filtering with different server attributes easier.
- Mesos/Marathon already has the support for tag-based [locality hints](https://mesosphere.github.io/marathon/docs/constraints.html), though some
  people have found it hard to use without the knowledge about the data center topology.

## Proposed Solution

Dapi currently is only able to effectively prioritise one thing at a time; by
default that thing is memory. If we switch to prioritising new platforms, that
means memory will be ignored. We need a way to handle multiple priorities at
once, and ones that potentially conflict to boot. The simplest means to do this
is using a weighted score.

Currently, each plugin in dapi returns an array of servers. This should be
modified to become an array of servers and scores, with each server having a
score. A score ranges from 0.0 to 1.0, where higher values indicate that a
server is more desirable for an allocation. This will primarily affect the
sorting plugins, which will no longer sort servers in preference from most to
least, but assign a score.

Server memory will be scored based on an inverse ration of how much free memory
is left; more free memory will get a lower score, thus biasing new allocations
to full(er) servers.

A new plugin will be added that looks at all server platforms, and ranks them
based on the range of server platforms. Servers with the newest platforms will
receive scores close to 1.0, while old platforms will receive close to 0.0.

A new plugin will be added that looks at the range of reboot dates on servers.
Servers closer to a reboot date should be scored lower than servers further away.
Reboot dates are not as important as a server's free memory or platform image,
so it should have less of an effect on the final server score. It should ignore
reboot dates that have already passed, in case ops doesn't update the field.

For reboot dates to work, cnapi will need to be modified to support a new date
attribute on server objects (e.g. "next_reboot_date"); a Moray migration will
be in order. Ideally this attribute will then be exposed through adminui.

Each plugin will return the score it assigned to a server, which then must be 
combined with the aggregate score for that server from previous steps. Perhaps a
simple multiplication will suffice, but normalisation will then be desirable at
every plugin step to keep server scores nicely distributed between 0 to 1.

Tangentially:

Locality hints for provisioning need to be exposed through adminui and portal.
Hints also need to support tags, not just VM UUIDs.

