---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->


# RFD 87 Docker Events for Triton

## Overview

Docker supports an endpoint for getting events for containers. As of
2017-02-06, sdc-docker does not support this endpoint. Recent changes to the
Docker CLI for Docker version 1.13.0 have increased the priority of
implementing the /events endpoint at least minimally. The CLI now depends on
/events to gather the exit code for the `docker run` command. As a result,
user of sdc-docker will get errors and the wrong exit code for every `docker
run` with the new version until this is implemented.

This document discusses what would be required to implement the minimal
container components of the of /events, with extra focus on what will be
required to minimally support the 'die' event which is required for `docker
run` with Docker 1.13.0.

## What is /events and why does it matter?

At the time of this writing, it's not possible to link to Docker's documentation
for events and recent changes indicate URLs for documentation are not permanent
either. If you go to [this page](https://docs.docker.com/engine/api/v1.25/) and
search for "Monitor events" you can find what little documentation there is
(last checked 2017-02-15).

When a client runs `docker run ...` the call to events looks like:

```
GET /v1.25/events?filters=%7B%22container%22%3A%7B%226f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f%22%3Atrue%7D%2C%22type%22%3A%7B%22container%22%3Atrue%7D%7D
```

where the filter translates to:

    {
        container: {
            '6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f': true
        }, type: {
            container: true
        }
    }

which would be hard to guess from the API documentation, but is the request
that is sent (pulled from snoop). This particular filter limits to events for
the container with DockerId 6f2b1a89ec[...].

The response to the above for a simple docker run session looks something like:

```
HTTP/1.1 200 OK
Api-Version: 1.25
Content-Type: application/json
Docker-Experimental: false
Server: Docker/1.13.0-rc7 (linux)
Date: Tue, 24 Jan 2017 21:20:27 GMT
Transfer-Encoding: chunked

159
{"status":"start","id":"6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f","from":"alpine:latest","Type":"container","Action":"start","Actor":{"ID":"6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f","Attributes":{"image":"alpine:latest","name":"fervent_mestorf"}},"time":1485292827,"timeNano":1485292827815807670}

177
{"status":"resize","id":"6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f","from":"alpine:latest","Type":"container","Action":"resize","Actor":{"ID":"6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f","Attributes":{"height":"44","image":"alpine:latest","name":"fervent_mestorf","width":"201"}},"time":1485292827,"timeNano":1485292827818300628}

164
{"status":"die","id":"6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f","from":"alpine:latest","Type":"container","Action":"die","Actor":{"ID":"6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f","Attributes":{"exitCode":"0","image":"alpine:latest","name":"fervent_mestorf"}},"time":1485292831,"timeNano":1485292831973735934}

0
```

with a chunk in the chunked response for each event. Since the order of the `docker run` calls is:

 * /create
 * /attach
 * /events
 * /start

we don't see the create or attach events in this stream as they happened before
our events call.

As of Docker 1.13.0, Docker uses the `exitCode` from the `die` event here as
the exit code of the `docker run` command. Without implementing this the user
will get an error message when using a 1.13.0 docker client against sdc-docker,
that looks like:

```
ERRO[0046] error getting events from daemon: Error response from daemon: (NotImplemented) events is not implemented (b9e4fddd-e731-475a-9053-8b240536703e)
```

and the exit code will not match that of the process that was run in the
container.

Previous to docker 1.13.0, Docker made an additional call to the "inspect"
(/json) endpoint after the session ended in order to get the exit code.

### Filters

In addition to filtering by container as in the example above, other filters
that are allowed according to the documentation include:

 * event type
 * image name/id
 * container or image label
 * type (container, image, volume, network, or daemon)
 * volume name/id
 * network name/id
 * daemon name/id

Anything related to "daemon" is probably unlikely to ever make sense in
sdc-docker, but the others may make sense to implement eventually. At this
point however, we'll only concern ourselves with at most event types and
specifying a container, implementing only the following filters:

 * type: {container: true}
 * container: {`ContainerId`: true}
 * event: {`EventType`: true}

where `ContainerId` is a Docker container Id, and `EventType` is one of the
supported Docker events (see section below "Docker Events").

### History Features

In addition to filters, docker events supports a `since` and an `until`. The `until`
would be pretty straight-forward to implement for *future* values if it weren't
for the fact that it gives you all data since the daemon last started (unless
you also pass a --since value). This means if I do:

```
docker events --filter event=start --until=2017-01-27T20:15:00
```

where that timestamp is 1 minute in the future, the results would look like:

```
2017-01-24T21:20:27.815807670Z container start 6f2b1a89ecb9585c29e1f431e8f5127ba91efeed99a157054c3516745eb1c84f (image=alpine:latest, name=fervent_mestorf)
2017-01-27T20:12:07.198579871Z container start f0143e00b5570e60affd9f5b07a52940ecfff0d16271a702cb410d4b90f84118 (image=alpine, name=mystifying_cray)
```

if I had started 2 containers since the daemon last restarted. In this
scenario, it would continue to stream events that occurred in the next minute.

The `since` filter works similarly in that it looks at the list of events since
the daemon last started.

These "history" features will be difficult to implement with the current design
of Triton and sdc-docker. More on that below in the [Complicating
Factors](#complicating-factors) section.

## Docker's Supported Events

Docker supports the following events:

 * attach
 * commit
 * copy
 * create
 * destroy
 * detach
 * die
 * exec\_create
 * exec\_detach
 * exec\_start
 * export
 * kill
 * oom
 * pause
 * rename
 * resize
 * restart
 * start
 * stop
 * top
 * unpause
 * update

Some of these don't make sense with the current sdc-docker as:

 * export - is not implemented
 * oom - we have no OOM killer
 * pause - is not implemented
 * unpause - is not implemented
 * update - is not implemented

This leaves us with the following:

 * attach
 * commit
 * copy
 * destroy
 * detach
 * die
 * exec\_create
 * exec\_detach
 * exec\_start
 * kill
 * rename
 * restart
 * start
 * stop
 * top

that we could possibly implement at this point. Below we'll go through each of
these briefly.

### attach

Emitted when a container is attached via `docker attach` or the attach that
happens when using `docker run` without the `-d` flag.

### commit

Emitted when an image is created from a container using `docker commit`.

### copy

Emitted whenever files are copied to/from a container.

### destroy

Emitted when a container is destroyed.

### detach

Emitted when a `docker attach` or `docker run` detaches from its session
connected to the stdio of the init process for a container.

### die

Emitted any time a container stops (init exits).

### exec\_create

Emitted when a `docker exec` session is created.

### exec\_detach

Emitted when a `docker exec` client disconnects from the session.

### exec\_start

Emitted when a `docker exec` session is started.

### kill

Emitted when a signal is sent to the container's init process via
`docker kill`.

### rename

Emitted when a container's name is changed. (alias in sdc-docker)

### restart

Emitted on `docker restart`, after `die` and `start`.

### start

Emitted whenever the container goes to a running state.

### stop

Emitted when the container `die`s via a `docker stop` command.

### top

Emitted when a client gets the `ps` output for a container via `docker top`.

## Complicating factors

### Distributed nature of actions in sdc-docker

In Docker, the docker engine/daemon handles directly calling the functions to
perform the event. This means when there's an create, docker is directly
involved in creating the container. In sdc-docker we have a more distributed
system so a `docker create` actually goes through:

 * sdc-docker
 * vmapi
 * workflow
 * cnapi
 * cn-agent
 * vmadm

and the results are propagated back up that chain as well. This makes
determining which process should be responsible for recording an event more
difficult. Additionally, because users can perform actions on their own from
within the container, it's possible that the `die` event for example could be
caused without any API involvement at all instead through a user running a
`halt` or similar from within their container or from the application running
as init crashing.

Since these events also include additional details about the event (the
exitCode for example in the case of a die event), it's also possible that at
different layers of the stack it will be more difficult to have access to the
required additional information. Especially in a timely manner.

When Docker wants the exit code, it can simply wait(3c) for the process to exit
and read the exit code directly. When sdc-docker wants the exit code this
currently needs to come from:

 * zoneadmd writing the value to the lastexited file
 * vm-agent noticing that the VM exited
 * vm-agent loading the value using vmadm (which reads the lastexited file)
 * vm-agent doing a PUT to VMAPI with the new VM object
 * sdc-docker calling VMAPI to see the exit code.

and this process can take several seconds.

Docker does not document the data that comes with the other events so these
would need to be reverse engineered. However it is obvious from the experiments
already run that Docker (strangely) includes the image name with many of these
responses. In Docker it's easy to pull out that information since we're only
dealing with one host's containers. In sdc-docker, we'd need to do an additional
query to IMGAPI to load that information.

## Requirements for a solution

What is required here just for `docker run` (to resolve
[DOCKER-996](https://smartos.org/bugview/DOCKER-996)) is at
minimum that we must have:

 * the ability to output a `die` event any time a container exits
 * the die event must include the exit code

If we add support for the `die` event, we remove all the user-visible errors
added here in the `docker run` path, and we also fix the exit codes returned by
the Docker CLI in this case. As mentioned in the [previous
section](#distributed-nature-of-actions-in-sdc-docker), this problem is
significantly complicated by the distributed nature of `attach` for docker
containers in sdc-docker.

## Current limitations that conflict with requirements

### Correctness of exit codes and loss of information

There are a number of cases where we may end up with incorrect exit codes if
this endpoint is implemented insufficiently. This is actually the case with
pre-1.13.0 clients and the existing sdc-docker implementation as well.

Cases where exit codes can be lost include:

 * when the container has a restart policy and is restarted on the CN after
   exit but before our GET to gather the container's exit code

 * when a container has exited but been started by a customer via cloudapi or
   other mechanism between the time of exit and the time sdc-docker is able to
   load the state from VMAPI.

Both of those revolve around the fact that at both the VMAPI level and at the CN
with vmadm, we only know *current* state, we don't keep a persistent log of
state changes that allows us to see intermediate state changes.

If we do a GET on the VM object either via `vmadm get` or an HTTP GET to VMAPI,
we may see that the VM has exited and see the exit status, but we cannot know if
the VM has started and exited more than once since the last time we loaded.
Additionally if Changefeed notifies us that a VM object changed, we do not get
the state along with that and need to query for it. When we do so, we don't know
if there were intermediate changes between our notification and our GET.

Even if we were sure we were notified of every change at VMAPI, it would still
be possible to miss events since VMAPI may never be notified about some events.
This is because on the CN, the process works similar in that changes are noticed
via an event mechanism (sysevents, or event ports) that does not tell us exactly
what changed but only that a change occurred, and we need to load the object to
see what changed. In the meantime, there may have been other events that we
missed and therefore were never able to tell VMAPI about.

Without knowing that we didn't miss any stop/start cycles here, we can't know
that the exit code available now is the correct exit code for the user's attach
session, and giving the user the wrong exit code could have disastrous
consequences. For example, if:

 * user has a process that does `docker run ... /.../backup.sh` to run a backup
   script that copies data out of the container to some remote location.
 * the backup process exits with a non-zero code because it had an error and
   didn't complete the backup (exit 1).
 * another script the user is running happens to start that container (maybe a
   bug, or maybe some other script being run) and exits successfully (exit 0).
 * sdc-docker only finds out about the state after the second change, because
   for some reason the notify/load loop took long enough that the load completed
   after the second stop.
 * sdc-docker outputs a `die` event with exitCode 0
 * user's script sees successful execution of backup.sh and destroys the
   container, losing data since the backup did not actually exit with status 0.

Until we've resolved [ZAPI-690](https://smartos.org/bugview/ZAPI-690), we also
have the problem where VMAPI's information may move both forward and backward
(we may temporarily overwrite old data on top of new data in some cases). Which
might have impact here as well if we're relying on VMAPI data via polling after
being notified.

### Also... About those History Features

As mentioned above, the docker endpoints support `until` and `since` which also
throw a wrench into the use of Changefeed (discussed below). Changefeed does not
store any historical data and therefore will not support these features.

## Ideas for discussion

### Triton Changefeed

As what we'd like for the `docker run` use of `/events` is a feed of the
changes to a given container or set of containers, the Changefeed mechanism
described in [RFD 5](https://github.com/joyent/rfd/blob/master/rfd/0005/README.md) and
implemented in VMAPI seems like a logical place to start. However there are a
few things to consider here.

Changefeed operates on VMAPI which is itself a cache of the VM data which
ultimately belongs to a CN. This means that when Changefeed emits an event, it:

 1) is telling you when the *cache* of the current state was updated, not when the
    event itself occurred on the CN
 2) only tells you *that* something changed, not *what changed* or the new value
 3) requires (due to #2) that you separately query VMAPI to find the current
    cached state which might be different from the state immediately following a
    change since there could be intervening changes.

As it stands currently, it's also not possible to watch changefeed for an
individual VM. So the options would be:

 * modify Changefeed and allow watching for changes for an individual VM and
   have sdc-docker create a separate listener for each `docker run` or `docker
   attach` session.

 * have sdc-docker listen for *all* VM changes and filter out those we're not
   waiting for exit from as a client of changefeed.

If we decide it's worth going this route, it's open for discussion which of
these would be preferable. With separate listeners, one concern might be the
overhead and whether the Changefeed changes belong with the design of that API.
With a single listener there would be more data passed that would just be
ignored most of the time by sdc-docker.

In addition, we'd probably want to add the `exit_status` and `boot_timestamp`
fields to the set of VM properties that changefeed can detect.

Even if we modify Changefeed in these ways, we still have a number of
correctness problems here that seem as though they'll be impossible to solve
with the existing implementation of changefeed. More on that in a [previous
section](#correctness-of-exit-codes-and-loss-of-information).

Given the problems listed here, it seems Changefeed may not be the best option
unless some major changes are made.

### If not Changefeed, then what?

It seems that to resolve this correctly, we'd probably want:

 * an ordered log of all changes to a VM that happen on the CN
 * a mechanism to query this from sdc-docker

At minimum for the immediate issue, we'd need to log every time a zone has
exited and the exit code. In the future if we want to support other `/events`,
we'll need to also record the information required for those events.

### Utilizing vminfod

One potential way to implement this would be to rely on `vminfod` ala
[OS-2647](https://smartos.org/bugview/OS-2647) / [RFD
39](https://github.com/joyent/rfd/blob/master/rfd/0039/README.md) when that is
complete. Since vminfod will be the consistent view of VMs that Triton sees.
Until vminfod sees a change, `vmadm get` and the Triton APIs will also not have
seen that change. Therefore if we have vminfod write out the log of changes,
this log can be used as the log of changes for the VM. Because each VM exists on
one CN, we don't need to deal with problems of distributed consistency which
would be required if we were storing this data in (potentially HA) APIs.

A problem with this approach that would require additional changes is that
vminfod, as prototyped currently, is itself *also* a cache. This means that it
stores the current state but may not store every possible intermediate change.

A "VM" in Triton is a virtual construct on top of a number of things including:

 * a zfs filesystem (/zones/<uuid>)
 * a zone configuration (/etc/zones/<uuid>.xml)
 * a zone instance (running in the kernel)
 * a set of JSON files (/zones/<uuid>/config/\*.json)

Each of which can be updated independently with or without our Triton/SmartOS
tooling by operators, or in some cases (e.g. `reboot` or `mdata-put`) from
inside the zones themselves. As such, `vminfod` attempts to watch for changes
using [sysevents](https://docs.oracle.com/cd/E19683-01/817-2703/whatsnew-s9fcs-142/index.html)
which are unreliable and other mechanisms such as event port watchers on various
files. It is not possible with these watchers to currently guarantee that
vminfod sees all changes.

### Changing "lastexited"

With [OS-3429](https://smartos.org/bugview/OS-3429), support was added to
zoneadm/zoneadmd to write the lastexited file in /zones/<uuid>/lastexited which
contains the last exit timestamp and status of init for the zone. This file is
is overwritten on each exit. If we were to modify this mechanism such that it
appends a line to the file on each exit with the code and timestamp, instead of
overwriting the file, we would be able to have an accurate record of all exits.
If we did this and exposed it via cn-agent in a way that sdc-docker could
consume, we would have everything we need to implement the `die` events,
including for history (back the point where the CN was booted onto a supporting
platform).

The biggest downside to doing this is that it would require a platform update in
order to roll this feature out.

If we do go this route, it would be good to consider whether we can make other
changes at the same time to write out other information that will require
platform changes, such as potentially writing out a file on every VM boot as
well.

### Going further

Instead of just making the lastexited change described above, we could also
consider solving a bigger problem by trying to get SmartOS itself to write out a
log of state changes for all of the VM state changes. This would allow us to
support the `docker events` actions that involve state:

 * create
 * destroy
 * die
 * start
 * stop

The remaining events that `docker events` reports (See [Docker's Supported
Events](#dockers-supported-events) section above) could all be emitted by other
components as those are fully handled by Triton except `update` which has unique
problems because:

 * Triton does not control or mediate all the mechanisms that can update a VM.
 * There are many different components of a VM that can be updated and there are
   no transactional guarantees and no way (currently) to record every change.

The goal here would be to create an ordered log of all changes to a VM on a
given CN, minimally with the fields that changed and a timestamp. The mechanism
for exposing this to Triton can be discussed further if we decide this is worth
pursuing.

If we could guarantee that VMs are only ever modified using the desired tools
(e.g. `vmadm update` instead of `zfs set ...`) then the tools themselves could
provide guarantees. Since we allow operators to make changes without using the
tools however, it seems we'd need to move the logging of actions into the OS
itself for these actions if we wanted to be able to have guarantees that all
changes are logged.

Having this single log of all changes to a VM on a CN would give us the
missing primitives required to fully support `docker events` for those events
that we listed above as making sense with sdc-docker at all.

## See also

 * [DOCKER-996](https://smartos.org/bugview/DOCKER-996) (ticket for the 1.13.0 breakage)
 * [RFD 30](https://github.com/joyent/rfd/blob/master/rfd/0030/README.md) (handling last\_exited in case of CN crash)

