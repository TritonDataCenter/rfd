---
authors: Alex Wilson <alex.wilson@joyent.com>
state: publish
---

# RFD 1 Triton Container Naming Service

## Introduction

### The New World

In the New World, the expectations around container longevity and lifecycle have
changed. In particular, containers are coming to be used as immutable,
replaceable components of infrastructure.

To illustrate, let us consider an example application, which provides an HTTP
API service to clients that connect from the Internet. It consists of the
following components:

 * A set of front-end nginx instances which act as TLS terminators and load
   balancers.

 * Stateless application instances which service and process requests.

 * A cluster of database containers running (for example) RethinkDB.

In a traditional deployment of this service using VMs, one might expect to
statically configure IP addresses for each service in the config for other
components -- for example, the application instances may have the IP addresses
of the database cluster members listed in their configuration.

Even in a traditional deployment model, this quickly runs into trouble if the
network architecture or addressing ever needs to change. As a result, often DNS
names are used as a layer of indirection to refer to the other sub-services
within the application.

However, in the New Container World, this is even more important. If we should
want to upgrade, for example, the application instances with new code, in a
traditional VM world we would log into each of them one by one and upgrade them,
perhaps taking them out of the load-balancer config to avoid disruption or
misbehaviour during the upgrade.

In the container world, these containers are expected to be immutable.
This means that they are not to be modified after deployment, and instead are
destroyed and re-deployed from scratch. As a result, the IP addresses that map
to each of the individual containers can be considered much more arbitrary and
ephemeral than in the previous generation of system designs.

Therefore, some means of referring to containers by their function that can
automatically and transparently update during re-deployment, destruction and
creation of new containers, is very much required.

Within this requirement there are two key areas to explore, which have
different constraints:

 1. Internal service discovery within an application -- components within the
    same design finding each other.

 2. External discovery by clients of the application.

The key difference between these two areas is that area 1 always involves
components that are entirely under the application designer's control.

Area 1 is also a well-explored problem, with some prominent and established 
solutions such as Consul and ZooKeeper. These require "smart" clients, which
can reason about the state of the cluster and participate as a part of the
distributed system's consensus protocol.

In this document we propose the Triton Container Naming Service, which is
intended to primarily deal with the area 2 class of problems listed above. While
it is not without utility in area 1, we believe that many users will already
have an existing preferred solution amongst the options available, and that any
solution for external discovery can still co-exist with a different solution for
internal use.

### Key requirements

With the above in mind, we lay out the following core requirements:

 1. We need a way to map an abstract Service to the concrete containers
    which currently provide it.

 2. Scheduled re-deployment, destruction and addition of new containers to
    the service should be achievable with zero downtime. Downtime is defined
    for the purpose of this requirement as an interruption of service where
    new requests made fail due to timeout or error, excluding unexpected
    failures in the containers themselves.

 3. Operation must be transparent to clients: they must be able to operate in
    the standard fashion of looking up a DNS name and connecting without any
    special logic or knowledge of TCNS.

 4. The solution must not require extensive setup or configuration on the part
    of the user for common cases.

There is also a discussion to be had as to whether (or what kind of) accounting
is required. Depending on how we wish to bill for this service, we may require
the ability to keep track of (at least in broad terms) the lookup request
volume associated with each user, or we may only require accounting in the form
of the number of hostnames served per user (or a fixed fee for having the
service enabled).

The design presented below does not take on accounting as hard requirement, but
the implications of the design upon what form of accounting is possible will be
explored.

### Solution options

First, let us consider the implications of requirement 3. A client connecting
by the normal method gives us two opportunities at which we can change its
behaviour:

 * During the DNS lookup, we can supply information on which IP address or
   addresses to connect to. Generally, clients will connect to whichever we
   send them first (in the manner of "round-robin" DNS).

 * During the establishment of the TCP connection to a given IP, we can perform
   address translation or otherwise intercept the connection to send it to
   particular containers.

Some popular established options for the IP-level virtualisation option include
protocols such as VRRP and CARP. These provide high availability by way of
floating "virtual IP addresses", which belong to only one member of the VRRP or
CARP group at a time.

However, both these particular techniques have limitations that make them
unsuitable for our use:

 * They can allow only a small, set number of virtual IPs to be provided --
   usually 256 or 128 in total per layer 2 network.

 * They require multicast/broadcast traffic to work.

So, while we could work around the low number of virtual IP groups available by
using our VXLAN virtual networks, the second requirement precludes this, leaving
us without a practical means to achieve multi-tenancy at the scale required by
our number of customers.

There are other options for practical floating IP addresses in concert with our
network virtualisation stack, which are worthy of further research. However,
these are not likely to produce sale-ready solutions in a timeframe less than
6-12 months.

Solutions like anycast routing are also an option, but when these are combined
with TCP the results can sometimes be extremely surprising to users. These
solutions also typically suffer from some of the same problems as VRRP/CARP, and
are very complex to deploy. It would be hard to expect that our on-premise users
would be willing and capable to deploy a complex BGP or OSPF topology.

On the other hand, a DNS-centric approach has some key merits:

 * DNS service high availability and scalability in a multi-tenant environment
   are very well-understood and well-studied problems.

 * Multiple active instances for the service can be listed in DNS, and clients
   will spread across them (though not necessarily evenly).

 * It is unsurprising and intuitive for our users.

It also has some disadvantages:

 * Updates to DNS typically take a minimum of 30-60 seconds to propagate, no
   matter how low you set TTLs and other tweakables in the SOA record.

 * There is no opportunity to actively redirect connections on an individual
   basis, to make sure load is spread evenly across instances.

However, if the latter is a heavier requirement, or high uptime in the case of
unplanned failure is integral to operations, DNS can still serve as a useful
building block. One can simply register DNS records pointing at a floating IP
address (or multiple such IPs) and proceed from there.

As a result, the Triton Container Naming Service is designed along a DNS-centric
approach, with consideration for the fact that it could be combined with a
VXLAN-based load balancer service developed separately at a later date.

### Not a load balancer

It is important to note that an approach built around DNS round-robin can never
provide "true" HA in the face of machine or network failure (in the sense of
requests never failing), nor can it provide true load balancing (since it
depends on client behaviour to spread the load out).

That said, many "HA load balancer" solutions are in fact not as HA or as load-
balancing as they claim or as users expect them to be. In particular, many
designs (for performance reasons) depend on the results of periodic health
checks whose information can be out of date by the time the packet redirection
decision is made.

As TCNS is designed for service discovery rather than load balancing, and
clients connect directly to the service containers once discovery is complete,
external health-checking is particularly unreliable. If a netsplit occurs that
isolates the health checker node from a service container, but does not isolate
a client from that container, we will fail to advertise an available container.
This scenario can also happen the other way around, where we incorrectly
advertise a container as running that is not available to the client.

As a result, we depend only on container self-reporting for health checks.
Containers can perform self-tests on their own service and report the results
to TCNS. We can also augment this with data from the control plane of the CNs
and the datacentre as a whole, to detect conditions where the container is
definitely inaccessible regardless of self-test reporting.

This design, and the focus on service discovery, still allows users to safely
perform "blue-green" upgrades and deal with other kinds of expected, planned
maintenance without downtime. These are the key features of TCNS.

## Proposal

### Assumptions and limits of scope

 * A fully-fledged "Cloud DNS" service is out of scope -- we assume that
   customers will continue to use their own DNS hosting for their own domains,
   and will likely serve CNAMEs to a TCNS name as needed.
 * The risk associated with running a newly developed, entirely custom
   Internet-facing DNS server is too high for the development timeframe
   desired. We assume the presence of existing DNS master/slave
   infrastructure that we can integrate with.
 * We need to deal with the JPC UFDS and VMs data sets as they are today and
   not embark upon cleanup operations just for this project.

### DNS structure

The proposed DNS structure for the TCNS consists of multiple DNS zones for each
SDC data centre, which contain records under them for both individual containers
and for provided services.

Service records are of the following form:

```
<servicename>.svc.<user>.<dc>.triton-hosted.io
```

```
eg.
frontdoor.svc.5450ee30-5352-11e5-a7b9-77da49db660f.us-east-1.triton-hosted.io
```

Under the service DNS name, there will exist `A` and `AAAA` records that are the
union of all the records for the containers that are active members of the
service. In the same vein, `TXT` records will exist with the UUIDs of all member
containers (see the explanation of individual container records below).

The `user` part of the service name will be the user's UUID. It may also be
desirable to provide shorter or "friendlier" names than the whole UUID, but this
creates issues around users claiming names that are desired by another customer,
and also problems around name expiration in future, as well as keeping track of
all the reservations.

While the `login` field of an SDC user is required to be unique, it is not
required to be DNS-safe, and in the JPC we also have to deal with legacy account
names that are not even case-insensitively unique. This makes mapping it 1:1
to a DNS-safe name problematic as well, though it may be worthwhile examining this
more closely.

UUIDs are quite long, but they do not suffer from these issues. It is also
entirely possible to provide records named by UUID in addition to ones named
by another name, so we can punt on this decision a little if necessary.

Individual container records are of the following form:

```
<container>.inst.<user>.<dc>.triton-hosted.io
```

```
eg.
c43ae904-528e-11e5-8df0-fbdc6110bcba.inst.5450ee30-5352-11e5-a7b9-77da49db660f.us-east-1.triton-hosted.io
```

Under this DNS name, there will exist `A` (and potentially `AAAA`) records for
each of the container's IP addresses. In addition, there will be a `TXT` record
containing the container's SDC UUID, for debugging and use by other tools.

The `container` part of the DNS name is the UUID of the individual container in
question, while the `user` part is as defined above.

Once again, using the `alias` field would be nice, but is quite problematic.
Container aliases are even less constrained than values of `login`, so it is
unlikely we can come up with a perfect solution here -- although, at least,
container aliases are easily changeable by the user to escape from a potential
problem.

### DNS zones, public and private addressing

The name structure specified in the last section was shown with a suffix of
`triton-hosted.io`. Clearly, this same structure can be used with a different
suffix as necessary.

One key item of configuration for TCNS shall be the mapping of DNS zones to NAPI
networks (or network pools). In this way, it may be configured to provide a
division between "public" networks and "private" ones and put addresses from
each into a different part of the DNS tree.

This configuration shall be provided in SAPI metadata (as a JSON object), as it
is not expected to change often, and in the recommended deployment a restart of
the TCNS daemon does not have an impact on availability.

In addition, TCNS shall also serve reverse lookup DNS zones, which map the IP
addresses of each container back to their container record name.

As many of our competitors provide DNS hosting for arbitrary domains, we may
wish to examine this option in future as well. However, the mechanisms needed
for scalable service of arbitrary domains are quite a bit more extensive than
what is proposed herein.

### Service membership

Membership of a service for a container shall be determined based on the
SDC tags on that zone.

Tags of the form below will be used:

```
triton.cns.services = <servicename>[,<servicename>,...]
```

Such tags comply also with the format needed for exposure as Docker tags through
sdc-docker, and can be applied as such.

VMAPI shall be modified to perform validation on the contents of these tags at
the time of their being set by the end-user. In this way, the user will receive
immediate feedback if the tag they attempt to set will not work. This kind of
validation will likely be needed in future for other special Docker labels
anyway, so the infrastructure and error codes can be shared.

For members of a service to appear in DNS, they must write to their own metadata
using the `mdata-put` tool, to indicate their status. They must write to the
metadata key `triton.cns.status` with either `up` or `down` as the value. If
this key is not present, `down` is assumed.

The intent is for the container to write to this key when it has finished
starting up (and perhaps passed any power-on tests desired), and again before
it begins to shut down. This can be done by an SMF service or a startup/shutdown
script of some kind.

Containers have the (highly recommended) option of self-monitoring using this
metadata interface -- they can write to this key if any health checks fail on
the service while running, to remove it from DNS.

A very simple service may also, if it wishes, simply write this metadata key
once after it has been set up, and leave it set forever (running with the
assumption that if the container is running, the service is accessible). This
is perfectly acceptable.

### Self-removal hysteresis

In the particular case of containers that self-remove from DNS using the
`triton.cns.status` metadata key, the TCNS system will apply a form of
hysteresis to avoid cascading failures removing all service nodes from DNS in
rapid succession.

Proposed policy:

No more than `max(floor(n/3), 1)` containers with a given service tag will be
removed due to self-removal in any 60-second window. If the final container in a
service tag sets its self-removal flag, it will be subject to a delay of 600
seconds before this removal becomes effective.

(these exact numbers are subject to change)

Note that this hysteresis will be overruled by containers having their service
tag removed, completely shutting down or being destroyed, a detected CN hardware
failure, or any other kind of "hard" removal.

The idea behind this is to allow self-monitoring to be used safely without
concern that a faulty or flakey probe can completely take down a service in one
fell swoop.

### Operation

The Triton Container Naming Service will operate as an authoritative DNS
nameserver, written in node.js. The service will typically operate as a DNS
"hidden master". This is a configuration where the built-in DNS mechanisms for
high availability (namely zone transfers, AXFR and IXFR) are used to mirror the
original DNS zone to "slave" servers, but only the slave servers are publicly
reachable. The original "master" DNS server in the SDC DC need never be exposed
to the Internet or be present in the records of the zone.

This also allows TCNS to integrate seamlessly into existing DNS systems deployed
both internally at Joyent, and at our on-premise customers' sites. It reduces
risks for the new code running on the master, as the actual client workload is
served entirely by the existing adequately-provisioned slaves running proven
code.

For small deployments with on-premise customers or open-source users who do
not have or wish to have a full DNS infrastructure, the TCNS master will also
be able to serve records directly, and this should still be thoroughly tested.

It would be highly desirable to also integrate into our existing systems for
planned maintenance operations (such as rebooting CNs) to automatically remove
containers from services temporarily during such operations. We might also want
to perform this operation in the face of other kinds of clear-cut CN failure
(but see above about this not being a system for building HA services).

The suggested software to be run on slaves is the standard ISC BIND nameserver.
It fully supports all of the features required to integrate with this solution.

Additionally, BIND can be configured to record statistics about per-zone query
rates without having to log all queries to disk. These counters could be
queried and collected by a node.js process on each slave nameserver and
aggregated by some other means, to be used for accounting purposes.

The TCNS will have the ability to serve, through an HTTP REST API, a list of
JSON objects describing at a high level the DNS zones available on the service.
This is necessary as DNS itself has no suitable means to provide this
information. An automatic script to convert the JSON into BIND configuration
syntax is one option that could be used to automatically update configuration on
the slaves, but its development will not be considered directly in the scope of
TCNS.

### User opt-in and opt-out flags

Some users may not wish to use the TCNS service. Some others may even view
having their containers' public IP addresses in DNS as a "security risk"
(despite any logic or evidence to the contrary). As a result, two flags
will be provided:

 * A per-account global opt-in flag, stored on their account record in UFDS.
   Without this flag, no records whatsoever for an account's containers will be 
   served.

 * A per-container tag that can be added to block that container from
   appearing anywhere in DNS, named `triton.cns.disable`.

The per-account opt-in flag will be stored as a free field on the account's UFDS
record, and settable by the user themselves through the CloudAPI UpdateAccount
endpoint. It will be named `triton_cns_enabled`. A toggle for the option will
also appear in the SDC user portal. Once set in one DC, the flag will be
sync'd by ufds-replicator to other related DCs.

The per-container tag can be set and removed in the same way as the service
membership tags, through CloudAPI or Docker Labels.

### Interaction with SDC

In order to obtain the information needed for its operation, TCNS should only
depend on the high-level SDC API services such as VMAPI and UFDS.

For the purposes of efficiency, the services it uses should all support filtered
change feeds in some manner, so that TCNS can be notified on changes and does not
have to poll all data out of the service on a timed basis.

TCNS will build up a cache of the DNS zones in memory (perhaps in a Redis store)
based on the feeds and queries it executes against SDC services. All DNS queries
and zone transfers will be served from this cache.

### Configuration and SAPI metadata

SAPI metadata items that will be used:

 * `my_name`   -- DNS name of the TCNS server itself
 * `dns_zones` -- object describing the forward DNS zones and their properties
                  (see below)

Format of `dns_zones`:

```json
{
  "triton-hosted.io": {
    "networks": ["napi-uuid-1", "napi-uuid-2"],
    "slaves": ["ns0.joyent.com", "ns1.joyent.com"],
    "hidden_master": true
  },
  "tcns.joyent.us": {
    "networks": ["*"]
  }
}
```

There can only be one DNS zone with a `networks` array including `"*"` -- this
becomes a "catch-all" zone for IP addresses that do not fit in any other zone
listed. If no catch-all zone is provided, then only IPs belonging to explicitly
listed networks will become part of the DNS records served.

When a DNS zone is listed with explicit `slaves`, or `hidden_master` is set to
`true`, AXFR and IXFR zone transfers for that zone are limited only to the IP
addresses of the hosts in the `slaves` array.

If neither of these properties are set, AXFR and IXFR transfers for a given
zone are only available to `127.0.0.1` (ie, the TCNS zone itself) for testing
and debugging. No zone transfers will be served to other addresses.

A commandline tool for editing the `dns_zones` payload and other settings will
be provided in the global zone, by the name of `cnsadm`, as editing
embedded JSON payloads in SAPI metadata is not the most enjoyable operator
experience. The tool will also validate its input by looking up the names of
`slaves`, validating NAPI UUIDs, and verifying that there is only one catch-all
zone configured. The existing SAPI support for `metadata_schema` will be used
for basic validation of structure, but the `cnsadm` tool will be able to
perform additional validation.

#### SAPI metadata schema

```json
{
  "type": "object",
  "properties": {
    "my_name": {
      "type": "string",
      "required": true,
      "pattern": "^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]).)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9])$"
    },
    "dns_zones": {
      "type": "object",
      "required": true,
      "additionalProperties": {
        "type": "object",
        "properties": {
          "networks": {
            "type": "array",
            "required": true,
            "minItems": 1,
            "items": {
              "type": "string",
              "pattern": "^[*]$|^[a-f0-9-]+$"
            }
          },
          "slaves": {
            "type": "array",
            "minItems": 1,
            "items": {
              "type": "string",
              "pattern": "^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]).)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9])$"
            }
          },
          "hidden_master": {
            "type": "boolean"
          }
        },
        "additionalProperties": false
      }
    }
  }
}
```

## Tasks

### Creating a new service

 * Services are created implicitly when a container is added to them for the
   first time.

### Adding a container to a service

 * Add the SDC Tag or Docker Label of the form `triton.cns.services = servicename`.

Updates will likely take 30-60 sec to finish propagating through DNS.

### Removing a container from a service

 * Remove the corresponding SDC Tag or Docker Label.

Updates will likely take 30-60 sec to finish propagating through DNS.

### "Blue-green" upgrades, container replacement within a service

 * Add a new container with the SDC Tag or Docker Label set.
 * Wait until DNS propagation has completed.
 * Remove the SDC Tag or Docker Label from the old container to be replaced.
 * Wait until DNS propagation has completed and requests have drained (old
   container is no longer receiving new requests).
 * Destroy the old container.

This can also be performed on multiple containers in parallel in the same
service.

### Rebooting a CN with containers on it

 * Ideally, make sure the CN's status in CNAPI is set to "rebooting" -- either
   by using the `/servers/:uuid/reboot` route (eg via `adminui`'s reboot
   button), or by doing an
   `sdc-cnapi -XPOST /servers/:uuid -d '{"transitional_status":"rebooting"}'`
   or similar.
 * TCNS will automatically remove containers on a CN that is marked as not
   running, whether for reboot or other reasons.

## Implementation steps

### Changes to `node-named`

 * Need IXFR incremental zone transfer support

The [arekinath/node-named](https://github.com/arekinath/node-named) fork of
the `node-named` already has support for TCP and AXFR zone transfers added.
IXFR needs to be added to make sure that slaves can efficiently update large
zones quickly.

### Changes to SDC services

 * Need VMAPI change feeds -- [ZAPI-662](https://smartos.org/bugview/ZAPI-662)
 * Efficient way to query IP addresses and tags only -- [ZAPI-663](https://smartos.org/bugview/ZAPI-663)
 * Tag updates need to be faster (currently triggers a WF job)

### Implementing `tcns` server

 * Decide whether to use Redis for in-memory cache or something else
 * Implement similarly to other SDC services, using `node-sdc-clients` to talk
   to VMAPI and UFDS as needed.
 * Daemon will connect to UFDS/VMAPI change feeds and run queries to gather its
   initial data, building up and maintaining its in-memory cache.
 * Every time there is a change, update SOA serial number.
 * Needs to keep track of differences to last few SOA serial numbers so that it
   can send NOTIFYs and respond to IXFR as needed.

There is some horrible nasty code in
[arekinath/sdc-zonedns](https://github.com/arekinath/sdc-zonedns) which could
serve as a point of reference or starting point for the actual server. It's
probably best to largely ignore the actual code here but use its features and
basic structure for inspiration.

### Deployment

 * Work with ops to create a plan for which DNS zones to use and what the SOA
   records have to look like to cover our NS.
 * Test extensively on staging, and also with mockcloud to confirm efficiency
   of operation with large number of CNs and VMs before deployment.

A new command should likely be added to `sdcadm experimental`, in the vein of
the `update-docker` command, which will install or upgrade the TCNS zone and
daemon.

Configuration will be necessary, including the base DNS zone name and the names
and addresses of the slave NS that should be listed in the SOA and allowed to
perform zone transfers. This should be stored in the SAPI metadata for the
service.

## Implementation Notes

As of early 2016, CNS is now available in the Joyent Public Cloud and in
on-premise SDC installations. It has been implemented basically as outlined
in this document, with some small changes.

 * Flags were added that enable the use of `alias` and `login` in DNS names
   for on-premise deployments which are not subject to the same legacy data
   requirements as JPC.
 * In the JPC, the use of `alias` in DNS names was enabled by default after
   careful examination of existing data and some adjustments to the validation
   code in VMAPI.
 * The removal hysteresis function has not yet been implemented.
 * The `triton.cns.services` tag has had its syntax enhanced to support
   additional metadata, such as a port number for generating SRV records.
   See [the relevant documentation](https://github.com/joyent/triton-cns/blob/master/docs/metadata.md) for details.
 * Support for generating SRV records was added.
 * Some support for custom PTR record generation was added, but has not been
   fully documented and deployed as yet.
 * CloudAPI now coordinates with CNS to add a `dns_names` field to the output
   of the GetMachine endpoint. This means that commands like `triton inst get`
   can now show the user all the CNS-generated names associated with a VM (both
   its instance names and service names).
 * The `node-named` library ended up needing quite extensive rework due to
   many bugs and problems in its packet parsing code, rather than just the
   proposed IXFR enhancement. A [local fork](https://github.com/arekinath/node-named) was necessary.
 * The `sdc-tcnsadm` command became `cnsadm`, which has been quite well
   received by operators, particularly for its status reporting commands.
 * For various non-technical reasons, the terminology of `master` and `slave`
   has been excised from the code and documentation and replaced by `primary`
   and `secondary`.
 * The `tcns_enabled` UFDS key was renamed to `triton_cns_enabled` as part of
   the wider tendency to refer to the system as "CNS" rather than "TCNS".
