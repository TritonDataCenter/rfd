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

No. We support the equivalent of `--log-driver json-file` not including the
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


## End-User uses for logging

We believe that there are two high-level ways that logging is used.

 1. For real-time monitoring or analytics of the application. Logging for these
    cases is not critical and drops of some messages are ok.
 2. It is fundamental to the correct behavior of the overall system (e.g. for
    billing). In these cases logging is expected to be reliable, drops are not
    ok and all data is needed.


## Triton Background - How are ZFD(7D) devices used?

The zfd devices are streams driver instances and they are currently used by
dockerinit to setup the app in the zone so that stdin/out/err are hooked up
properly to one or more zfd devices. This will vary based on how docker is
being used and if the app is being run interactively or not. The streams are
used to get stdio from the app out to the GZ and into zlogin, as well as the
GZ log file.

We've added new support for one or two additional zfd devices in the zone and
dockerinit can issue an ioctl which will cause the stdout/stderr from the app
(via the original zfd devices) to tee into the new zfd devices. This is done
internally as a streams multiplexer.

These additional zfd instances can now be read by a logging process running
inside the zone to obtain the application's stdout/stderr.


## How will logging work for Triton?

Because of the requirements listed above, the logger process must run inside
the zone. There are several error cases which cause concern for how logging
behaves.

 1. What happens if the logger dies?
 2. What happens to the application if the logger gets behind and can't keep up?
 3. What happens to in-flight messages when the application exits, perhaps
    unexpectedly, and the zone halts?

The design of the logging solution addresses these questions.

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
process in the zone which may confuse some docker users. We'll handle this via
separate lx proc work to make this appear as a system process.

We will provide an option the user can specify on their docker log invocation
which will control if the zfd log stream provides back pressure. If there
is no back pressure and the logger gets backed up, the primary stream will
continue to flow, the application will continue to run, but those messages
will not be sent to the logger. If the option specifies back pressure and
the logger gets backed up, the primary stream will be flow controlled, the
application writes will block, and the application will stop running until
the logger catches up and the primary stream can flow again.

In order to ensure that a zone does not run for a long time if the logger dies
we will add a capability to setup the zone's init (dockerinit) contract(4) such
that CT_PR_EV_EXIT will be part the contract's fatal event set. Because the
application and the logger will be in the same process contract, if the logger
dies, the contract will send SIGKILL to the application and the zone will halt.
This is similar to how the Docker deamon works. If its logger dies it will
most likely take out the daemon and all containers will halt. The existing
behavior of halting the zone when the application exits will continue to be in
effect.

This leaves the question of what happens if the application exits while log
messages are in the stream but the logger hasn't handled them yet. Those
messages will be lost to the logger because the zone will halt immediately.
However, our view is that the "reliable" log path is the one that goes out to
the global zone and into the JSON log file. We will always maintain that log
path, even when in-zone logging is being used. We will rotate the GZ JSON log
file to Manta on a regular basis and those logs should contain all of the zfd
stream data, even in cases when the in-zone logger did not consume those
messages before the zone halted.


## What handles rotation for the GZ json logfile?

This will be left as a separate project as the current thinking is that this
would be implemented through hermes, or something like it, that runs in the GZ
and can rotate logs. Ultimately we need to rotate the logs to Manta since
rotated logs are otherwise not accessible to the user. The `docker logs`
command only displays entries from the current log, ignoring the rotated logs.


## Alternative Approachs

This section captures the historical thinking around the behavior of the
logging service in the face of errors. It is provided here to give context
for the design choices we made.

Should the logging service be reliable? That is, should capturing all log data
take precedence over keeping the application running? It is important to be
clear that we are talking about the presence of the log service and the data it
receives, not what the logger does with the data. This breaks down into three
questions:

1. Handling failure

   What should we do when the logger process dies?

      * kill the zone? (the plan)
      * restart the logger?
      * ignore the failure and stop logging until the container is restarted?

   We could have a simple restarter for the logger but this does not handle
   the case when the zone halts. As described below, that case is much more
   complex and if that case is not reliable, then there is not much gained by
   having a restarter for the logger. Instead, we chose to kill the zone since
   this is similar to the Docker behavior and ensures the zone is not running
   indefinitely without a logger.

2. Handling backpressure

   What should we do if the buffer for the logging zfd is full? This could
   easily happen if the logger is blocked trying to send data across the net.

     * drop new output?
     * block the application process?

   We chose to make this a user-configurable option since either behavior can
   be desirable.

3. Handling application exit

   What should we do when the application exits while messages are in-flight?

     * nothing, the messages are lost?
     * block zone halt until we somehow know the messages have been handled?

   Blocking the halt implies that the zone shutdown or reboot is delayed
   indefinitely. It also means that the application cannot be the initial
   process inside the zone, but that there must instead be a "meta init" which
   sticks around when the application exits. However, the application must
   continue to behave like init, it must be pid 1 and it must inherit zombies,
   otherwise applications such as systemd, upstart, runnit, etc. will not work
   correctly. While we could add code to work around this, it would be complex.
   Instead, while we recognize that these final messages can be critical, we
   treat the GZ JSON logging as the reliable path. Thus, users will be able to
   get those messages out of Manta.

## Open questions (input encouraged)


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
