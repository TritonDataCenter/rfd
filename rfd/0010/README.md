---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

# RFD 0010 Sending GZ Docker Logs to Manta

## Overview

With [RFD 0002](https://github.com/joyent/rfd/tree/master/rfd/0002), we've added
support for docker logging modes which for the most part leave log files in the:

```
/zones/<uuid>/logs/stdio.log
```

for each docker container. These files are accessible (with docker cli >= 1.9)
for any log-driver except 'none' via the `docker logs` mechanism. We do not yet
support the `max-file` or `max-size` options for the `json-file` driver. As it
stands right now, without these changes, the GZ log file will continue to grow
until it has exhausted the quota of the container's zoneroot filesystem.

Since these log files are not accessible to customers any way other than `docker
logs`, they cannot rotate them. So currently they can grow until they fill the
zoneroot quota of the container. If we just rotated them in place, customers
would not be able to access them as `docker logs` only provides access to the
most recent log. In order to deal with these problems, we wanted to instead
rotate the logs to Manta so that customers could access all their logs (using
any Manta tools) and so that these logs will not fill up their container.

Per [RFD 0002](https://github.com/joyent/rfd/tree/master/rfd/0002),
these will be the main source of "reliable" logs, as such we would also like to
get them into Manta in a timely manner.

With Docker, because all the data is going through the docker daemon, what they
do for each log line is basically:

 * stat the log file
     * if the size is > max-size, rotate() and re-open
 * write the new entry

The rotate() function here then checks the max-file and renames .8->.9, .7->.8,
etc. and then renames the current log. This way when the write immediately
following a file reaching max-size occurs, it'll be rotated immediately.


## Proposal (no-Manta)

If Manta is not available most of the rest of this discussion does not apply. In
that case, what we will do is use the same watcher agent as described below,
but:

 * when the size of the log is >= max-size:
     * move the log file to stdio.log.&lt;YYYY&gt;&lt;mm&gt;&lt;dd&gt;T&lt;HH&gt;&lt;MM&gt;&lt;SS&gt;Z
     * signal zoneadmd to re-open original log
     * if max-file is set, delete oldest until we're at count == max-file
     * nothing further

In this mode the zone will still fill up with logs unless the operator has setup
some mechanism for archiving / deleting old log files.

Notes:

 * `max-size` and `max-file` are only available when `log-driver` is `json-file`

## Proposal (Manta)

We will write an agent that runs in the GZ, is installed with the other agents
and:

 * watches all docker container's stdio.log files (probably w/ event ports)
 * when one of those files changes, do a stat and check against max-size
 * if size >= max-size:
     * move log file to stdio.log.&lt;YYYY&gt;&lt;mm&gt;&lt;dd&gt;T&lt;HH&gt;&lt;MM&gt;&lt;SS&gt;Z
     * signal zoneadmd to re-open original log
     * leave hermes to deal with uploading and max-file
 * when a container is deleted, upload the stdio.log file from the archive and
   delete it

We will modify vmadm to include the stdio.log file in the files that get
archived when a VM is deleted. On deletion the stdio.log file should also be
renamed to match the timestamp pattern of the other rotated files (and those in
Manta).

We will modify hermes to support uploading to a customer's Manta area based on
the owner_uuid of the container, and also to support a limited number of remote
files. We will also make any other required modifications for hermes to pick up
and upload these files.

This will mean that:

 * `docker logs` will be the primary way to access *recent* logs for your
   container
 * logs which have reached the maximum size or for containers which have been
   destroyed will be available in Manta

Notes:

 * `max-size` and `max-file` are only available when `log-driver` is `json-file`

## Things considered

### Hermes

Josh Clulow points out:

```
[...] I think we should use hermes to achieve the upload/archival portion
of this.  It would probably require some modification to support the idea of
uploading to an account other than "admin", but the actual upload engine
already does basically everything that would be required:

- Manta configuration through SAPI
- upload parallelism
- retries on failure
- uploading through a DC-wide proxy
- converting local rotated log file names into Manta paths
  based on token expansion, mtime, etc
- debouncing mtime to ensure we don't upload a file that's
  still being written to
- deleting files only once successfully uploaded, potentially
  with a limited retention of already-uploaded files on the
  local system
```

The Manta proposal above relies on the use of hermes.

### Support for `max-file` or `max-size`

There was some discussion on whether we should support these at all. If we were
using a periodic scanner to do the uploading (e.g. something that ran every 5
minutes and always uploaded if there was data) `max-size` would never make any
sense. With Manta, unlike a local disk, storage space is less of a concern so
it's not clear in this model that `max-file` is necessary either.

Unlike Docker, we're logging to the GZ log with drivers other than `json-file`.
If we want to allow `--log-opt max-file=3` for all drivers, it may be confusing
for users. Since all other options for the various log drivers are prefixed with
the driver name such as `syslog-address`.

The most recent suggestion here is:

 * support `max-size` and `max-file`, but only for the `json-file` driver
 * for drivers other than json-file and when not specified, the max-size and
   max-file will have default values (actual values TBD)

### Rotation Strategy

Given that we have a container and it has data written to:

```
/zones/<vm_uuid>/logs/stdio.json
```

a few questions arise:

 * what should notice that a new docker container with a log showed up?
 * what should rotate that file?
 * how frequently should the rotation occur?
 * should we skip empty logs?
 * how do we find the manta login for the owner_uuid of the VM? Mahi?

One option would be to have a new agent that runs in the GZ of all nodes and
periodically looks at /zones/*/logs/ for non-empty files, rotates them and then
consumes the file while sending to Manta. Since this would be running in the GZ
though, it would need to proxy through another zone (perhaps sdc zone) in order
to talk to Manta. It would also need to find the owner_uuid's Manta login so
that it knows the path to write the log.

Another option might be to have logadm rotate /zones/*/logs/stdio.log on some
frequency and have another separate tool (or maybe hermes?) which takes the
rotated files and uploads them. Since we would like to keep the latency between
the logs being written to disk and showing up in Manta minimal, it seems like
for this mode we might need to have logadm and hermes run more frequently, as
currently both run hourly.

A new option was raised after the initial draft of this, which was to have a new
agent but have it watch files and rotate when they hit max-size. This behavior
is much closer to Docker's and would allow us to upload files much less
frequently to Manta on average. As such, it's what we've chosen for the current
proposal above.

Other considerations here (apply to the first two options):

 * given that we can potentially have over 2000 containers per CN (assuming 128M
   containers and 256G CN) and we can have 1000 CNs per DC... How problematic is
   it to write up to 2M files to Manta every 5 minutes per DC? At what rate
   would we start having problems? Not writing empty files would likely help
   decrease this number significantly.
 * if we're going to use logadm we may need to first fix OS-3097 and related
   tickets.

### Manta Paths

Original thinking was that we could use the same directory the old KVM-based
docker service used for logs in Manta. This was:

```
/<login>/stor/.joyent/docker/logs/<vm_uuid>
```

in our case we'd replace &lt;vm_uuid&gt; with &lt;docker_id&gt; since that's the id that
customers would see with their docker clients. And under this directory what I
would propose is that we have files named something like:

```
.../<YYYY>/<mm>/<dd>/<HH>/stdio.log.<YYYY><mm><dd>T<HH><MM><SS>Z
```

That's 4-digit year, 2-digit month, 2 digit day-of-month, 2 digit hour (00-23),
and additionally in the filename, the 2 digit minute and 2 digit second. This
would be the UTC timestamp of the time the file was rotated.

One suggestion that was made was that we ensure the filename of the rotated
files in the GZ of the CNs matches the directory and filename of the files in
Manta for easier comparison during uploads. This seems quite reasonable so I've
updated the rotation to use this format too.

A suggestion has also been made that we make this configurable, potentially even
configurable via cloudapi per-login using something like:

 * https://mo.joyent.com/docs/cloudapi/master/#config

and/or a SAPI metadata variable. Either of these would obviously add additional
complexity.

### Container Deletion

When a container is deleted between the log-rotation periods, it's likely that
data will still be in its stdio.log that has not yet been sent to Manta. In
order to prevent losing logs here, I'd suggest that we change the
archive_on_delete feature such that it knows to also keep the stdio.log files
in the archived data and have the thing doing rotation also look here for the
last logs to upload for a container.

### Inspect Output

One suggestion was made that we query sdc-docker at the time of rotation and get
the /containers/&lt;docker_id&gt;/json output and add that to the root directory for
the container.

If we did this, we would need to do something differently for destroyed
containers as they would not show up in sdc-docker.

We'd also need to figure out how to query sdc-docker as the owner of the
container.

### More Tools

With logs going into Manta, it has been suggested that people would want tools
to manage these other than the m* tools. (mls, mget, mfind, etc.)

### Knowing when all logs are uploaded

Trent suggested a use case of wanting to be able to script knowing when a final
log upload was complete. Ignore the "container didn't log" case where there
will be no uploaded log files. The use case could theoretically be handled if
the last log upload used the same timestamp [or a later one] as a 'destroy'
time in the cloudapi MachineAudit.

Josh points out that some VMs will never have any logs uploaded (if nothing
ever got written to stdout/stderr) which means users may be waiting for a log
>= destroy time that will never show up.

## Open Questions

 * what should the defaults be for `max-size` and `max-file`?
     * for drivers other than json-file, we'll always only use these defaults
 * what path should we use?
     * Original suggestion was /&lt;login&gt;/stor/.joyent/docker/logs/&lt;docker_id&gt;,
       but others have suggested we *not* use that
 * do we want to include the inspect output with the container?
 * can we leave cli tools out of scope?
 * any other major concerns that were missed?

