---
authors: Marsell Kukuljevic <marsell@joyent.com>
state: draft
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


## Dapi's Purpose

When Triton receives a request to provision a new container, it needs to
determine which server the new container will live on.

As part of a new provision, Triton passes details of the requested container to
dapi. Dapi looks at the fleet of servers, and determines which server fulfills
all of the new container's requirements (e.g. amount of RAM and disk) and also
is more desirable for that allocation (e.g. a server with a more recent
platform version). A fair number of details are considered by dapi when
allocating a new container.


## History

SDC 6.5 did much of its allocation logic within Postgres, thus had less
difficulty with allocation scaling. Unfortuntely, 6.5 had plenty of other
limitations, so SDC 7.0 was a grand rebuild of SDC. As part of the rebuild,
a workflow pipeline was developed, which called out to many microservices.
Dapi was one of those HTTP APIs.

While this presented a clean architecture, it also had (and has) an important
limitation: data and code are potentially kept far apart. Moving data to code
can get very expensive.

Initially, the workflow retrieved bothserver and container information from
cnapi, before passing it to dapi. This involved several serialization and
deserialization steps. Roughly, server data traveled like this:

    Postgres
      |
      |  postgres protocol
      v
    Moray (deserialize Postgres data and serialize as JSON)
      |
      |  JSON over FAST
      v
    cnapi (deserialize JSON, do some transforms, serialize results as JSON)
      |
      |  JSON over HTTP
      v
    workflow (deserialize and reserialize JSON)
      |
      |  JSON over HTTP
      v
    dapi (deserialize JSON)

As long as there were very few servers and containers, this worked fine.

That didn't last long, because the data quickly ballooned to several MB of
JSON. A lot of time was spent de/serializing data and shuffling it between
services.

This data movement was reduced by converting dapi from a service to a library,
and embedding that library within cnapi. This eliminated the last two steps in
the above diagram; once cnapi had retrieved the server details from Moray, it
was immediately passed on to dapi within the same process. The allocation time
dropped to a few milliseconds once cnapi had the details.

More recently, we have been trying to clean up cnapi's storage of container
details. vmapi is the canonical service for container information, but cnapi
maintains its own copy of container information in a 'vms' object attached to
server objects. Alas, querying vmapi introduces an additional
serialization/deserialization step on container information, where that
information is pulled from vmapi to cnapi, before being fed to dapi.

This results in allocations taking several seconds in some production
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

  We have reduced this a bit by pushing some filtering logic for setup servers
  towards Moray. Instead of Javascript doing filtering on the 'setup' attribute
  on server objects, this is sent as a query to Moray. NB: dapi still retains
  the Javascript filtering step for setup servers just in case there is ever a
  bug in the Moray query; this will likely be removed.

  We need to do more of this. Unfortunately, Moray's querying capabilities are
  limited.

- Dapi as a pure function.

  Dapi was initially conceived as a pure function -- it contained no state, had
  no query abilities, and therefore its results were always entirely determined
  by its inputs (some intentional addition of randomess aside). Many of Triton's
  services were conceived this way to reduce bugs.

  This has certainly aided debugging problems, especially on remote sites. It
  has also pessimized data requirements: since dapi cannot make its own queries,
  and we won't know what information it'll need beforehand, we need to provide
  dapi with everything it could possibly use.

  When it comes to scaling, we need to reduce the amount of data fed to dapi.
  Loading unnecessary data is contrary to that, which implies we need to lose
  the pure functionality.

- Dapi as a single conceptual entity.

  A general trend that most other DC allocators take is spreading out their
  functionality. They don't have a global view, and there isn't a single entity
  that makes all the allocation choices.

  This is up in the air.


## Proposal

### Phase 1

Reorder the filter plugins. We need to push the usage of container data, or any
data derived from container data (e.g. the unreserved\_\* attributes), as late
as possible. In Phase 2, we add support for dapi to query vmapi for container
information, meaning that we should filter out as many servers as possible
beforehand, so we need to make fewer queries to vmapi.

We would also like to have fewer servers given to dapi to begin with, by
providing more query arguments to Moray when initially constructing a list of
servers to consider. This is a tad less surprising when these simple filters
are at the top of the plugin list.

The proposed (albeit simplified) plugin chain is as follows:

    hard-filter-setup
    hard-filter-running
    // servers above invalid-servers could contain gibberish
    hard-filter-invalid-servers
    // keep volumes-from early; if present, it cuts down number
    // of servers to just one:
    hard-filter-volumes-from
    hard-filter-reserved
    hard-filter-vlans
    hard-filter-platform-versions
    hard-filter-traits
    hard-filter-headnode
    hard-filter-overprovision-ratios
    // above plugins do not need vm info
    // we defer vm loading as late as possible:
    load-server-vms
    calculate-ticketed-vms
    hard-filter-capness
    hard-filter-vm-count
    hard-filter-sick-servers
    calculate-server-unreserved
    hard-filter-min-ram
    hard-filter-min-cpu
    hard-filter-min-disk
    hard-filter-locality-hints
    hard-filter-owners-servers
    hard-filter-reservoir
    hard-filter-large-servers
    soft-filter-locality-hints
    // final scoring steps
    score-unreserved-ram
    score-unreserved-disk
    score-num-owner-zones
    score-current-platform
    score-next-reboot
    score-uniform-random

Those filters which can be replaced with a query argument to Moray will be left
in for the time being, in case of bugs, but will be removed in the long run.


### Phase 2

Provided that we continue down the path of removing cached container data from
cnapi in lieu of the canonical data from vmapi, we shouldn't load all the
container information up-front. Instead, dapi will receive two functions upon
initialization, and use that to query vmapi for container data when needed.
In short: move from strict to lazy loading of container data.

cnapi will no longer load container details from vmapi for every server before
feeding the data to dapi. dapi will contain a load-server-vms.js plugin in its
plugin chain, after much of the server filtering that doesn't depend on
container or container-derived data has been run.

The two async functions are getVm() and getServerVms(). getVm() is needed by the
hard-filter-volumes-from plugin, which is early in the plugin chain.
getServerVms() is needed by a new plugin, load-server-vms.js; after that plugin
is run, the `vms` attributes on server objects are populated with container
information retrieved from vmapi.

cnapi currently continues to cache container information because of the
unreserved\_\* attributes that are added when calling ServerGet, or ServerList
with a ?extras=capacity or ?extras=all. This invokes dapi's serverCapacity(),
which requires container information. If cnapi did not cache container
information in its server objects, all invocations of the above calls would
require a further call to vmapi to pull in the required container information.

cnapi's container cache is largely outside the scope of this document, but
dapi's plugins will also support server objects which have already had their
'vms' attribute loaded with container information:

load-server-vms.js must support a null getServerVms() -- if getServerVms()
isn't provided to dapi, dapi assumes the servers' objects' `vms` attribute is
already populated. This is the case when serverCapacity() is called, and also
for actual allocation when ALLOC\_USE\_CNAPI\_VMS is set in cnapi's sapi
metadata -- cnapi populates all servers with container data it has cached in
Moray.


### Phase 3

Ideally, we would not load all servers at once, but rather in constant-size
batches. Each batch would be loaded and fed into dapi until dapi finds an
eligible server.

An unfortunate limitation of Moray -- and one that can be a tad tricky to
efficiently solve with the backing Postgres -- is the ability to sort results
randomly. Without this ability, it's not possible to load servers in batches
without biasing servers towards the beginning of the sort order. As a result,
all eligible servers need to be pulled up-front from Moray by cnapi.

However, we can still dramatically reduce the amount of data movement by feeding
these servers in batches to dapi -- cnapi would retrieve all eligible servers
from Moray, sort them randomly, and then feed batches from this list into dapi.
While this will not reduce the number of servers loaded by cnapi, it will
dramatically cut the amount of vmapi queries needed by dapi for a large fleet
of servers: rather than dapi filtering all servers and then querying vmapi
information for the (e.g.) 50% of surviving servers, dapi would filter servers
in batches, and pull in the vmapi information for (e.g.) 50% of the batch size.

Unless the spare aggregate capacity of a fleet of servers is approaching full,
operating in batches will cut the typical amount of vmapi information to be
loaded to only one batch. If a fleet has little spare capacity, or heavy traits
usage, an allocation is still guaranteed to succeed if it's possible, since all
servers will be checked in the worst case. Worst-case loading of vmapi
information is the same as before support for batching is added to cnapi/dapi.

A statistical rule-of-thumb is thirty samples (or larger) gives a reasonable
approximation of an underlying distribution; we'll go with a batch size of
fifty servers.

NB: to reduce memory usage, after each batch is run, cnapi should delete the
'vms' attribute on the batched server objects.


### Phase 4

Moving dapi to vmapi will reduce the worst-case movement of data by at least
an order of magnitude. The current default maximum number of containers per
server is 224, and this number will go up in the future. Container data from
vmapi for 224 servers is ~70KB data, whereas the data for a single (unpopulated)
server is ~5KB. The break-even point, where server data is more than the
container data, is roughly twenty or fewer containers.

cnapi will still load all servers, and still perform batching, but instead of
invoking dapi directly, it wll send that batch to vmapi. vmapi will feed the
batch to dapi directly, whereupon dapi will work the same as in Phase 3. The
only material difference is that the getVm() and getServerVms() functions
provided to dapi by vmapi will contain logic to query the local vmapi, instead
of making an HTTP call (from cnapi to vmapi).

After Phase 4, the server and container scaling targets we wish to hit by the
end of 2016 will sadly still require ~5MB of server data to be pulled in to
cnapi, and in a worst case an additional ~5MB to be sent to vmapi, but this
is an sizeable improvement compared with the ~75MB of data needed before
Phase 1.

Phase 4 will also likely render the container caching in cnapi to be largely
unnecessary. Since cnapi already has a vmapi dependency when invoking dapi, we
do not lose much by utilizing vmapi more from cnapi. When doing server listings
that require the unreserved\_\* attributes to be populated, cnapi can pass a
copy of this list of servers to vmapi, where dapi can calculate the
unreserved\_\* attributes, and vmapi would then pass back to cnapi solely those
three attributes per server.


## Wild ideas

- Send SQL queries to Postgres through Moray, bypassing vmapi and cnapi
  altogether. Possibly abuse PL/pgSQL to reduce calls even further. This would
  lagely solve the data movement problem, but presents difficulties with JSON
  and the version of Postgres Triton uses. Bug prone and brittle.

- Add support to Moray to return raw Postgres data, instead of deserializing
  it and reserializing as JSON. However, this would break Moray's abstraction,
  and add unwanted dependencies on Moray's Postgres schema (as with the previous
  wild idea).

- Turn dapi into a stateful cached service and feed it vmapi and cnapi events.
  Allocations would take milliseconds. Very bug prone.
