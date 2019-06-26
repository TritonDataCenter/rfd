---
authors: Joshua M. Clulow <jmc@joyent.com>, John Levon <john.levon@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=RFD+95
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019, Joyent, Inc.
-->

# RFD 95 Seamless Muppet Reconfiguration

## Background

Manta is predominantly accessed via a HTTPS API, exposed to the public Internet
via a set of load balancers.  The `loadbalancer` service, also known as "Muppet",
provides TLS termination at the exterior edge of the Manta system, distributing
inbound requests amongst servers in the first internal tier (Muskie).

Muppet is composed of three chief components:

* Stud, for TLS termination.  Stud is configured to listen on the external
  HTTPS port (443), passing all connections to HAProxy via `localhost`.

* HAProxy, for load balancing and request routing.  HAProxy is configured
  to accept connections via Stud, as well as on a public HTTP port (80) and
  an internal HTTP port.  All requests are divided between the current set
  of available Muskie hosts as listed in the configuration file.

* The Muppet application itself, responsible for updating the HAProxy
  configuration file in response to changes in the Muskie topology, and
  restarting HAProxy to apply the new configuration.

## Motivation

Today, the reconfiguration of HAProxy by Muppet is quite disruptive to service.
Muppet connects to ZooKeeper, reacting to changes in the set of registered
Muskie instances.  Whenever the membership of the set of Muskies changes,
Muppet immediately writes an updated HAProxy configuration and restarts the
HAProxy service. Only recently was Muppet changed to provide some hysteresis
and throttling in this process via [MANTA-4337](https://jira.joyent.us/browse/MANTA-4337).
For example, a simple reboot of a Muskie should no longer cause a restart of HAProxy.

This restart terminates all in-flight connections.  There is also a brief
period between when the original `haproxy` process has closed its listen socket
and the new `haproxy` process has started listening; incoming connections which
arrive in this window are actively refused.  Further compounding the problem,
all Muppets in the fleet generally receive their topology updates at the same
time, triggering a simultaneous wave of restarts and disruption to _all_ Manta
traffic, although a randomized restart time does help a little here.

In light of these shortcomings, Manta operators would be forgiven for giving a
wide berth to any maintenance activity which adds or removes a Muskie.  In
order to reduce the disruption that updates, auto-scaling, or even blue-green
software deployment might cause, we should seek to reduce the disruption of
configuration changes -- ideally to zero!

## Proposed Solution

With the [master-worker](https://cbonte.github.io/haproxy-dconv/1.8/configuration.html#3.1-master-worker) setting, haproxy will spawn child processes for handling connections, and keep around a parent "master" process.
On receiving `SIGUSR2`, the master will re-exec itself, passing the listen sockets
to a new child process (via the [expose-fd listeners](https://cbonte.github.io/haproxy-dconv/1.8/configuration.html#5.1-expose-fd%20listeners) option). Any new connections will be processed by the new child.
When the old worker(s) are drained of connections, they will terminate gracefully.

With this process, there is no harsh interruption to service or existing connections.

The old child processes continue their operation with the old configuration. This does
mean that existing connections will neither use newly-added Muskie instances, nor avoid
Muskie instances removed from Zookeeper. Instead, such an open connection will respond
to haproxy's layer 4 and layer 7 health check timeouts as needed.

Muppet does not run HAProxy directly as a child process.  Instead, it
manipulates the `svc:/manta/haproxy:default` [SMF][smf] service via
[svcadm(1M)][svcadm] commands. Muppet will be updated to invoke `svcadm refresh`
on haproxy, which sends the `SIGUSR2`. As the master haproxy process stays
around, this doesn't affect SMF's fault management of the haproxy service
instance - the re-exec is not visible to SMF. At the same time, any issues
with the child processes (such as a core dump) will still trigger the traditional
SMF behaviour such as restarting the entire service.

### Updating haproxy version

Currently we are deploying HAProxy 1.5. To get these new features, we need to update
to the latest LTS version - at the time of writing, this is 1.8.20. The event port
poll handler has to be ported to this version, as there are some significant changes
from 1.5. Updating also gives us some other potential advantages, such as possibly
replacing stud with haproxy's own SSL termination.

### pfiles(1) issues

During testing, [MANTA-4335](https://smartos.org/bugview/MANTA-4335) was discovered. As
we are only deploying HAProxy single-threaded, however, we will apply a workaround to
our version of haproxy. The thread management code has changed significantly in HAProxy 2.0,
so hopefully we won't need it for the next update. The underlying OS issue has also
been fixed, but we can't yet presume we're running on a PI with that fix.

### Child worker management

As mentioned above, after a reload, the old child worker process stays open (in what
HAProxy calls "soft-stop") until the final client connection is closed. This can be
arbitrarily long, especially in the case of clients such as `marlin-agent`, which has
a tendency to hold onto connections.

Since each worker child takes some amount of RSS and other resources in the `loadbalancer`
zone, we don't want the process list to grow unbounded. To this end, we'll introduce a
new `max-old-workers` configuration property for HAProxy. On reaching this limit, the
oldest still extant child process will be sent `SIGTERM`. This will close the connection
of any old clients still connected to it. On re-connection, they will connect to the
current child worker instead.

The hope is that most clients will be done with old children before we hit the worker
maximum limit, and those that persist such as `marlin-agent` cope well with losing
their connection.

This was deemed preferable to the other option, the existing [hard-stop-after](https://cbonte.github.io/haproxy-dconv/1.8/configuration.html#hard-stop-after) option, on the basis that there is no
good timeout value we could choose that's suitable for all scenarios (especially large PUTs).

This is strictly an improvement on the status quo, of course, which would terminate
such connections via restarting HAProxy.

Note that the Manta alarm tracking HAProxy RSS only works on a per-process basis. However,
it still seems likely that a runaway HAProxy will be reflected in an individual process
rather than in aggregate, so the alarm seems sufficient as is.

# Impact on Operation and Development

Apart from a mild increase in implementation complexity, there should be no
significant degradation in the operability of the system.  As discussed, the fault management
properties of SMF are unaffected, and HAProxy logging remains much the same with
the new version and new configuration (including staying compatible with [haplog](https://github.com/joyent/node-haproxy-log). `haproxystat`, used in Manta alarming, remains functional as
the statistics domain socket is served by the current child process. This does *not*
provide visibility into old, active, workers however.

As open client connections stay connected to an old child worker, there is potential
risk there. As mentioned, if a Muskie backend goes away or is unhealthy, the connection
would have to wait for haproxy's health checks to decide it is unavailable before
closing the request. This could lead to increased timeouts on the client side.

A future enhancement to Muppet may ameliorate this concern: it is possible to directly
disable a backend over the HAProxy socket via the "CLI" interface. If we are solely
removing Muskie instances, we could use this direct mechanism to avoid even needing to
reload HAProxy at all.

[bind]: https://illumos.org/man/3SOCKET/bind
[listen]: https://illumos.org/man/3SOCKET/listen
[accept]: https://illumos.org/man/3SOCKET/accept
[smf]: https://illumos.org/man/5/smf
[svcadm]: https://illumos.org/man/1M/svcadm
[sdcnics]: https://eng.joyent.com/mdata/datadict.html#sdcnics
