---
authors: Marsell Kukuljevic <marsell@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 60: Scaling the Designation API

The Designation API -- usually referred to by its old name, dapi -- is a library
which selects a server for a new container. It currently resides inside cnapi as
a dependency, and is invoked by the provision workflow, where a large wad of
server and container data is loaded before being passed into dapi. This large
wad of data presents a scaling problem.


## History

SDC 6.5 did much of its allocation logic within Postgres, thus had less
difficulty with allocation scaling. Unfortuntely, 6.5 had plenty of other
limitations, so SDC 7.0 was a grand rebuild of SDC. As part of the rebuild,
a workflow pipeline was developed, which called out to many microservices.
Dapi was one of those HTTP APIs.

While this presented a clean architecture, it also had (and has) an important
limitation: data and code are potentially kept far apart. Moving data to code
can get very expensive.

Initially, the workflow retrieved server and container information from cnapi,
before passing it to dapi. This involved two serialization and deserialization
steps. As long as there were very few servers and containers, this worked fine.

That didn't last long, because the data quickly ballooned to several MiB of
JSON.

This was solved by converting dapi from a service to a library, and embedding
that library within cnapi. Once cnapi had retrieved the server details from
Moray, it was immediately passed on to dapi within the same process. The
allocation time dropped to a few milliseconds once cnapi had the details.

More recently, we have been trying to clean up cnapi's storage of container
details. vmapi is the canonical service for container information, but cnapi
maintains its own copy of container information in a 'vms' object attached to
server objects. Alas, this introduces an additional
serialization/deserialization step on container information, when that
information is pulled from vmapi to cnapi, before being fed to dapi.

This results in allocation taking several seconds in some production
environments, and will become a much more serious limitation with server and
container scaling targets we wish to hit before the end of 2016.


## Scaling limitations

There are a few notable limitations with dapi's original design goals that give
dapi poor scaling:

- Dapi as a service. Since rectified.

  See the history above. What was once a distinct microservice is now a library.
  This results in at least one less serialization/deserialization step.

- Dapi having a global view of the datacenter.

  We used to, and still mostly do, feed dapi a complete description of all
  servers and containers in a datacenter. With many servers and containers,
  this becomes increasingly expensive (specifically Θ(sc), with number of
  (s)ervers and (c)ontainers).  

  We have reduced this a bit by pushing the filtering logic for setup servers
  towards Moray. Instead of Javascript doing filtering on the 'setup' attribute
  on server objects, this is sent as a query to Moray. NB: dapi still retains
  the Javascript filtering step for setup servers just in case there is ever a
  bug in the Moray query; this will likely be removed.

  We need to do more of this. Unfortunately, Moray's querying capabilities are
  fairly limited.

- Dapi as a pure function.

  Dapi was initially conceived as a pure function -- it contained no state, had
  no query abilities, and therefore its results were always entirely determined
  by its inputs (some intentional addition of randomess aside). Many of Triton's
  services were conceived this way to reduce bugs.

  This has certainly aided debuggin problems, especially on remote sites. It has
  also pessimized data requirements: since dapi cannot make its own queries, and
  we won't know what information it'll need beforehand, we need to provide dapi
  with everything it could possibly use. 

  When it comes to scaling, we need to reduce the amount of data fed to dapi.
  Loading unnecessary data is contrary to that, which seems to imply we need to
  lose the pure functionality.

- Dapi as a single conceptual entity.

  A general trend that most other DC allocators take is spreading out their
  functionality. They don't have a global view, and there isn't a single entity
  that makes all the allocation choices.

  This is up in the air.


## Proposal

### Phase 1

Reorder the filter plugins called by dapi so that simple checks that can also be
done by Moray are at the top. Then move these all to Moray arguments, removing
them from dapi.

### Phase 2

Provided that we continue down the path of removing cached container data from
cnapi in lieu of the canonical data from vmapi, we shouldn't load all the
container information up-front. Instead, dapi should receive a vmapi client
upon initialization, and use that to query vmapi for container data when needed.
In short: move from strict to lazy loading.

cnapi should no longer load container details from vmapi for every server before
feeding the data to dapi. dapi would contain a load-vms.js in its plugin chain,
after all the server filtering, but before the first plugin that needs container
informationi -- likely calculate-server-unreserved.js.

load-vms.js would then use the vmapi client provided to dapi to pull in
container information from vmapi for all remaining servers that dapi is still
considering for allocation.

XXX more details

cnapi currently continues to keep container information because of the
unreserved\_\* attributes that are added when calling ServerGet, or ServerList
with a ?extras=capacity or ?extras=all. This invokes dapi's serverCapacity(),
which requires container information. If cnapi did not cache container
information in its server objects, and all invocation of the above calls would
require a further call to vmapi to pull in the required container information.

cnapi's container cache is largely outside the scope of this document, but
dapi's plugins should support server objects which have already had their 'vms'
attribute loaded with container information. The proposed load-vms.js should
skip any server object it receives which already has a 'vms' attribute.


### Phase 3

Do not load all servers at once, but rather in constant-sized batches. Provided
that servers can be selected randomly by Moray (it currently cannot), there is a
high probability that an allocation can be fulfilled with a single call. If a DC
has little spare capacity, or heavy traits usage, an allocation is still
guaranteed to succeed if it's possible, since all servers can be checked in the
worst case.

XXX more details

There are a couple important challenges here, both related to randomness. In
order to avoid biasing servers which haven't yet been scored, we need some means
of querying Moray with a random sort (i.e. sort: 'RANDOM'). Moray's docs claim
that FindObjects isn't a streaming interface, which presents the second problem:
how to divide random selection into pages using limit/offset.

A less invasive and less efficient work-around is loading all server objects
from Moray, randomizing their order, and feeding batches of that result to dapi.
Every allocation would load all servers, but it would further reduce the number
of containers that need to be loaded. Making dapi batch internally would achieve
a similar effect.


### Phase 4

Depending on the amount of data loaded in a typical allocation, moving dapi to
vmapi would likely reduce cost a lot. There can be several hundred containers on
a single server.


## Wild ideas

- Send SQL queries to Postgres through Moray, bypassing vmapi and cnapi
  altogether. Possibly abuse PL/pgSQL to reduce calls even further. This would
  lagely solve the data movement problem, but presents difficulties with JSON
  and the version of Postgres Triton uses. Bug prone and brittle.

- Turn dapi into a stateful cached service and feed it vmapi and cnapi events.
  Allocations would take milliseconds. Very bug prone.
