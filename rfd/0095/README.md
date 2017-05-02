---
authors: Joshua M. Clulow <jmc@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2017, Joyent, Inc.
-->

# RFD 95 Seamless Muppet Reconfiguration

## Background

Manta is predominantly accessed via a HTTPS API, exposed to the public Internet
via a set of load balancers.  The load balancer service, "Muppet", provides TLS
termination at the exterior edge of the Manta system, distributing inbound
requests amongst servers in the first internal tier (Muskie).

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
HAProxy service.

This restart terminates all in flight connections.  There is also a brief
period between when the original `haproxy` process has closed its listen socket
and the new `haproxy` process has started listening; incoming connections which
arrive in this window are actively refused.  Further compounding the problem,
all Muppets in the fleet generally receive their topology updates at the same
time, triggering a simultaneous wave of restarts and disruption to _all_ Manta
traffic.

In light of these shortcomings, Manta operators would be forgiven for giving a
wide berth to any maintenance activity which adds or removes a Muskie.  In
order to reduce the disruption that updates, auto-scaling, or even blue-green
software deployment might cause, we should seek to reduce the disruption of
configuration changes -- ideally to zero!

## Proposed Solution

HAProxy provides for a type of "soft" reload of its configuration.  The `-sf`
option to `haproxy` accepts the process ID of an existing `haproxy` process.
This option instructs the new process to take over the listen socket without
interruption.  Once the new process has the listen socket open and can service
requests, it sends a series of signals to the old process, informing it to stop
listening and complete any in flight requests.  Once there are no more requests
in flight, the old process terminates gracefully and the reconfiguration is
complete.

Unfortunately, the reconfiguration procedure described above depends on
operating system support for the `SO_REUSEPORT` socket option.  This option
allows for a process to take over a listen socket from another, unrelated
process.  This option has slightly different semantics on at least Linux and
the BSDs, and there is presently no native support for it in illumos.  Without
`SO_REUSEPORT`, the old and the new `haproxy` processes cannot concurrently
drain old requests and service new ones.

Instead of `SO_REUSEPORT`, we can use another HAProxy feature: binding to an
already established listen socket inherited from a parent process.  The HAProxy
configuration generally contains `bind` directives which are usually used to
nominate a bind address and listen port, or perhaps a UNIX domain socket path,
on which to establish a front end service.  The software will also accept _a
file descriptor_ (e.g., `bind fd@100`), which it treats as a socket on which
[bind(3SOCKET)][bind] and [listen(3SOCKET)][listen] have already been called.
Even more conveniently, the software will expand an environment variable in the
`bind` directive; e.g., `bind fd@${FD_HTTP_0}`.

With a relatively simple C program, we can provide a supervisor of sorts for
HAProxy.  This supervisor would be responsible for opening the configured set
of listen sockets, and starting `haproxy` processes.  On the receipt of a
reconfiguration signal (e.g., `SIGUSR1`), the supervisor would start a new
`haproxy` process using the `-sf` option, as described earlier in this section.
The supervisor would track the drain and exit of the old `haproxy` process as
part of ensuring a flurry of configuration events does not result in an
unbounded number of concurrent restarts.

In this model, the _supervisor_ manages the long term life cycle of all listen
sockets.  Each new `haproxy` process will be a direct child, and can therefore
use the inherited file descriptor `bind` directives in the HAProxy
configuration file.  The supervisor can provide the file descriptors to the
child via symbolic names, using environment variables.  This set of listen
ports is generally relatively static, and that configuration could be provided
to the supervisor by `config-agent`.

Muppet does not run HAProxy directly as a child process.  Instead, it
manipulates the `svc:/manta/haproxy:default` [SMF][smf] service via
[svcadm(1M)][svcadm] commands.  We can introduce the new HAProxy manager
program into the existing `haproxy` SMF service, adding a `refresh` method
which sends the appropriate signal for seamless reconfiguration.  Whereas today
Muppet does a hard `svcadm restart` of the service, in the future it would
perform the new, softer `svcadm refresh` instead.

## Impact on Operation and Development

Apart from a mild increase in implementation complexity, there should be no
degradation in the operability of the system.  HAProxy itself is still calling
[accept(3SOCKET)][accept] on the listen socket, even though it did not open it
-- there is no additional layer of indirection to obscure the source of the
connection.

The HAProxy service exposes statistics, using a UNIX domain socket and a TCP
listen port.  We can continue to expose those same facilities, with a minor
enhancement: the supervisor would be responsible for opening a socket at a path
which includes the process ID of the HAProxy instance; e.g,
`/tmp/haproxy.39430`.  The supervisor could also maintain a symbolic link from
`/tmp/haproxy` to the statistics socket for the current primary HAProxy
instance.

The supervisor should be written to be conservative in the system state that it
will accept.  In the event that something unforeseen happens, e.g. `haproxy`
exits unexpectedly, the supervisor should log an error and degrade to the
traditional, disruptive restart.


[bind]: https://illumos.org/man/3SOCKET/bind
[listen]: https://illumos.org/man/3SOCKET/listen
[accept]: https://illumos.org/man/3SOCKET/accept
[smf]: https://illumos.org/man/5/smf
[svcadm]: https://illumos.org/man/1M/svcadm
