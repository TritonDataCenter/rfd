---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: draft
---

# Note on terminology

In order to distinguish between Triton and Docker, I'll use 'Docker' when
talking specifically about Docker Inc's docker, and 'docker' when referring to
things that apply to both Triton and Docker.


# What's --log-driver?

See: https://docs.docker.com/reference/logging/overview/

Basically we want to be able to send a log of stdout/stderr from a docker
container's init process to a remote log sink in a number of formats: syslog,
fluentd and gelf.


# Don't we already have that?

Nope. We support the equivalent of `--log-driver json-file` not including the
rotation options. We also (recently) support the `--log-driver none`. What we
don't support is any of the network logging drivers.


# How does it work in Docker?

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


# Triton Background

This section includes some details that people were confused about in the first
draft.

## What is ZFD? (From Jerry)

The zfd devs are streams driver instances and the general idea here is that
dockerinit will setup the app in the zone so that stdin/out/err are hooked up
properly to one or more zfd devices. This will vary based on how docker is
being used and if the app is being run interactively or not. The streams are
used to get stdio from the app out to the GZ and into zlogin.

The new support adds 1 or 2 additional zfd devices into the zone and dockerinit
can issue an ioctl which will cause the stdout/stderr from the app (via the
original zfd devices) to tee into the new zfd devices. This is done internally
as a streams multiplexer.

Because this is streams there is some queueing/buffering that we get. The
default queue size is 2k, which we could tweak, and because there can be
various streams modules pushed onto the stream we can get multiple spots where
queueing occurs.

What I currently have in zfd is that I chose not to block the app's execution
if the log stream gets full (which could happen if the logging process is slow
or stuck). Thus the app will continue to run and if the log process resumes or
catches up, then it will start getting any new stdout/err msgs that get queued
onto the log stream. Intermediate stdout/stderr msgs are dropped.

If the log process is not running for any reason, then the log stream is not
open and nothing goes into that stream. Any stdout/err is thus not logged.

I could explore stopping the primary stdout/err streams if the log stream gets
full, but that will presumably stop the app from executing. We just need to
settle on the behavior we want to see here.


# How will it work for Triton?

This represents the plan so far.

In Triton's docker, the user's process is the init process for the zone (exec'd
by dockerinit). We don't have a GZ process that is the parent for this process.
Via dockerinit we're sending all stdout/stderr data from the user's process to
/dev/zfd/{1,2} (non-interactive mode) or /dev/zfd/0 (interactive mode). In both
of these cases you can connect to the other end of the zfd devices from the GZ
using `zlogin -I`.

With OS-4694 we will be able to also read another copy of this data from
_within_ docker zones. We'll then have a process that will be started by
dockerinit before we exec the user's init process, which will connect to
/dev/zfd/{3,4} and take the driver name as a cmdline variable and the
configuration from environment variables. This process will continue to read
from the zfd devices and stream data to the remote log until the zone exits.

We want to do the logging inside the container instead of from the GZ for
several reasons including:

 * the container has access to the customer's network(s) which they likely want
   to be able to send logs to
 * the networking, cpu and memory usage then come out of the zone's allocation
   instead of requiring separate accounting
 * customers controlling network connections that happen from the GZ opens up a
   vector for security issues

but this does mean that we'll be adding an extra process in the zone which may
confuse some docker users and adds some of its own complexity.


# What about rotation for json-file?

This will be left as a separate project as the current thinking is that this
would be implemented through hermes, or something like it that runs in the GZ
and can rotate logs. Ultimately we will need to rotate the logs to somewhere
off-box (Manta) since rotated logs are otherwise not accessible to the user. The
`docker logs` command only displays entries from the current log, ignoring the
rotated logs.


# Open questions (input encouraged)

## Handling failure

 * What should we do when the logger process dies?
    * kill the zone?
    * restart the logger? (adding a small restarter as its parent)
    * ignore the failure and stop logging until the container is restarted?

## Handling backpressure

 * What should we do if the buffer for zfd is full?
    * drop the output?
    * block the process?

For OS-4694 Jerry has implemented this such that it will drop data when the
reader process doesn't read if for a while. If someone has other suggestions,
please voice those soon.

## Updates w/o platform rebuild

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

## Go in the build?

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


# Notes from input already given

 * we may want a knob for reliable/unreliable logging which determines whether
   logging should block your app or not
 * contracts are probably the way to go to ensure init dies when the logger
   does (so the container can be restarted)
 * we need to figure out what to do with the logs that are written as the
   container exits

# Related Open Tickets

 * DOCKER-279 - Master ticket for logging
 * DOCKER-535 - Rotating json-file logs to Manta
