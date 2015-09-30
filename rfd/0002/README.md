---
authors: Josh Wilsdon <jwilsdon@joyent.com>, Jerry Jelinek <jerry@joyent.com>
state: draft
---

# RFD 2 Docker Logging in SDC

## Note on terminology

In order to distinguish between Triton and Docker, I'll use 'Docker' when
talking specifically about Docker Inc's docker, and 'docker' when referring to
things that apply to both Triton and Docker.


## What's --log-driver?

See: https://docs.docker.com/reference/logging/overview/

Basically we want to be able to send a log of stdout/stderr from a docker
container's init process to a remote log sink in a number of formats: syslog,
fluentd and gelf.


## Don't we already have that?

Nope. We support the equivalent of `--log-driver json-file` not including the
rotation options. We also (recently) support the `--log-driver none`. What we
don't support is any of the network logging drivers.


## How does it work in Docker?

In Docker, the daemon itself is the parent process for all container processes.
As such, it can connect stdout/stderr as a pipe in the non-tty case (one pipe
for each of stdout/stderr) and in the tty case it just has one descriptor.

When a container is in interactive mode and the docker daemon crashes, the child
gets a SIGHUP and accessing the descriptors will fail since they're connected to
the pipe to the daemon. Also note that if systemd/upstart restarts the docker
daemon the daemon kills any running containers on startup so that it can become
the parent again when they're started (which it only does on restart=always).

In Docker all the log drivers have host-scope. This means that if I set:

  --log-driver syslog --log-opt udp://127.0.0.1:514

we will be sending logs to 127.0.0.1 on the *host*. This is why they are using
the unix driver (which we'll not support) by default and writing to the host's
syslog socket. It is also why they support a journald driver which writes to
systemd's journald in the host. We'll also not have that.


## Requirements

 0. Support most of the docker --log-driver capabilities.
 1. Ability to redirect the application's stdout and stderr into a logging
    process. The two streams can either be merged into one log stream or
    handled separately.
 2. The logging process must run inside the zone so that its resource usage is
    accounted for in the zone and so that it has access to the zone's network.
 3. As a corollary to the previous requirement, we cannot allow customers
    to control network connections that happen from the GZ since that opens up
    a vector for security issues.


## Triton Background

This section includes some details that people were confused about in the first
draft.

### How are ZFD(7D) devices used?

The zfd devices are streams driver instances and they are currently used by
dockerinit to setup the app in the zone so that stdin/out/err are hooked up
properly to one or more zfd devices. This will vary based on how docker is
being used and if the app is being run interactively or not. The streams are
used to get stdio from the app out to the GZ and into zlogin, as well as the
GZ log file.

The new support adds 1 or 2 additional zfd devices into the zone and dockerinit
can issue an ioctl which will cause the stdout/stderr from the app (via the
original zfd devices) to tee into the new zfd devices. This is done internally
as a streams multiplexer.

These additional zfd instances can now be read by a logging process running
inside the zone to obtain the application's stdout/stderr.

Because this is streams there is some queueing/buffering that we get. The
default queue size is 2k, which we could tweak, and because there can be
various streams modules pushed onto the stream we can get multiple spots where
queueing occurs.

The way that the zfd tee devices currently behave (although this can be changed)
is that they do not block the app's execution if the log stream gets full
(which could happen if the logging process is slow or stuck). Thus the app will
continue to run and if the log process resumes or catches up, then it will
start getting any new stdout/err msgs that get queued onto the log stream.
Intermediate stdout/stderr msgs that flow while the tee is full are dropped.

If the log process is not running for any reason, then the log stream is not
open and nothing goes into that stream. Any stdout/err is thus currently not
logged, although again, this can be changed.


## How will logging work for Triton?

This represents the plan so far.

In Triton's docker, the user's application process is the init process for the
zone (exec'd by dockerinit). We don't have a GZ user-level process that is the
parent for this process. Via dockerinit we're currently sending all
stdout/stderr data from the application process to /dev/zfd/{1,2}
(non-interactive mode) or /dev/zfd/0 (interactive mode). In both of these cases
you can connect to the other end of the zfd devices from the GZ using
`zlogin -I`.

Using the zfd tee devices described above, we will be able to also read another
copy of this data from _within_ the docker zone. We'll have a logging process
that will be started by dockerinit before we exec the user's application
program. The logging process will be connected to the zfd tee device(s) and
take the driver name as a cmdline variable and the configuration from
environment variables. This process will continue to read from the zfd devices
and stream data to the remote log until the zone exits.

Running the logger inside the zone does mean that we'll be adding an extra
process in the zone which may confuse some docker users and adds some of its
own complexity.

The current plan is to add a capability to setup the zone's init (dockerinit)
contract(4) such that CT_PR_EV_EXIT will be part the contract's fatal event
set. Because the application and the logger will be in the same process
contract, if the logger dies, the contract will send SIGKILL to the
application and the zone will halt. The existing behavior of halting the zone
when the application exits will continue to be in effect.


## What about rotation for the GZ json logfile?

This will be left as a separate project as the current thinking is that this
would be implemented through hermes, or something like it that runs in the GZ
and can rotate logs. Ultimately we will need to rotate the logs to somewhere
off-box (Manta) since rotated logs are otherwise not accessible to the user. The
`docker logs` command only displays entries from the current log, ignoring the
rotated logs.


## Open questions (input encouraged)

### Should the logging service be reliable?

 That is, should capturing all log data take precedence over keeping the
 application running? It is important to be clear that we are talking about
 the presence of the log service and the data it receives, not what the logger
 does with the data. This breaks down into two questions:

#### Handling failure

 * What should we do when the logger process dies?
    * kill the zone? (the current plan)
    * restart the logger? (this requires a small restarter as its parent)
    * ignore the failure and stop logging until the container is restarted?

For this question, as described above, the current plan is to use CT_PR_EV_EXIT
in init's contract fatal event set so that if the logger dies, the contract
will send SIGKILL to the application and the zone will halt.

#### Handling backpressure

 * What should we do if the buffer for the logging zfd is full? This could
   easily happen if the logger is blocked trying send data across the net.
    * drop new output? (the current plan)
    * block the application process?

For this question, the current zfd(7D) implementation is such that the log tee
is "best effort". That is, if no log process has the device open, the log tee
gets nothing. Likewise, if the log tee is full, the primary application message
stream will continue to flow and that output will be lost to the logger. Both
of these behaviors can be changed.

#### Alternative approach

In discussion it has been suggested that logging is critical and should be made
reliable (in the sense that the logger is restarted and receives all stdout/err
data).

The first implication of this is that we should not use a contract to kill the
zone if the logger dies. Instead, we need a restarter for the logger. Having a
restarter for the logger implies that instead of two (or more) processes within
the zone, there will be at least three. We might want to modify the lx procfs
so that we have a mechansim to hide these 'infrastructure' processes from ps(1).

The second implication is that we should change the zfd tee behavior so that
we stop the flow in the primary stream when the tee is full and that we tee
even if the device is not open. This means that a blocked logger will block
the application from executing once the log stream is full. We may want to
consider a tunable for reliable/unreliable logging which determines whether
logging should block your application or not.

The third implication of this is that we need to figure out what to do with
the log data that is waiting to be written if the application exits and the
zone shuts down. An apparently simple way to handle this would be to change
dockerinit so that it did not exec the application over itself. Instead,
dockerinit would be the parent of the application, as well as the restarter for
the logger, and when the application exits dockerinit would wait until the
logger drained the zfd tee stream before it exited, halting the zone. However,
this cannot work for all images since any image which provides its own "init"
(e.g. systemd) requires that init to be pid 1 in the zone. Once the primal
process exits the zone will halt immediately and any queued log data would be
lost. It might be possible to stream the log data into a file and setup the
logger to read from that file. If the zone restarted the logger could pickup
where it left off in the file, but the docker model seems to assume "ephemeral"
containers, so there is no guarantee that the zone will ever be restarted.
In this case any unsent log data will still be lost.

### Updates w/o platform rebuild

It has been requested that we attempt to build this feature in such a way that
if docker adds log drivers, we can somehow roll these out without a platform
reboot. At this point my thinking on how we could accomplish this is:

 * have the logger be something like /usr/docker/bin/logger with /usr/docker
   being mounted writable in the GZ (or whatever path with this property)
 * add an option to the dockerlogger which outputs a list of supported drivers
 * have another procedure for updating /usr/docker/bin/logger on all CNs
   similar to agents updates or perhaps `sdcadm experimental update-docker`?

This way we could roll out a new /usr/docker/bin/logger to all CNs when new
drivers are wanted. Already the list of drivers we want to allow has to be in
SAPI's metadata for sdc-docker to allow those drivers to be used. So in this
case adding a new driver would mean:

 * update sdc-docker so it knows about validation for the new driver
 * roll out the new /usr/docker/bin/logger to all CNs
 * enable the new driver via SAPI's metadata for the docker SAPI service

### Go in the build?

When I explained to him what I was doing, Trent made an excellent suggestion
which I tried out and seems like it will work well. What he suggested was to
take the docker logger code and use that. This way:

 * we can support any of the drivers Docker does (that can work inside the zone)
 * we're using the same code so behavior will be (hopefully) more similar

The prototype I wrote up is at:

 https://github.com/joyent/dockerlogger

and does in fact work to write logs to syslog, fluentd and gelf targets. The
only thing I'm waiting for before hooking it up in dockerinit is the OS-4694
work. Once that's in I'll connect the prototype to that and do some testing.

The problems with this approach include:

 * building the logger will then require Go in the build system somewhere
     * though not necessarily in the platform if we ship the logger separately
 * not everybody here knows how to work with Go if something goes wrong

However there are also a number of advantages which include:

 * lower run-time memory usage than using node.js
 * single binary to drop in instead of a whack of .js and .node files
 * we won't have to try to find (or write) a good node implementation of the
   various logging protocols
 * there's very little code we have to write my prototype is only ~100 lines
   including all the imports and comments
 * it already basically works with what I did as a prototype


## Related Open Tickets

 * DOCKER-279 - Master ticket for logging
 * DOCKER-535 - Rotating json-file logs to Manta
