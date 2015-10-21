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


## Questions that need to be answered

### Should we support `max-file` or `max-size` at all?

In Docker, the `max-size` parameter can be set which will control how large the
log file can get before it's rotated. The `max-file` parameter can be used to
limit the number of old rotated files we keep for a given container. These
options are only valid when `--log-driver` is set to `json-file`.

The first problem then will be that unlike Docker, we're logging to this log
with drivers other than `json-file`. If we want to allow `--log-opt max-file=3`
for all drivers, it may be confusing for users. Since all other options for the
various log drivers are prefixed with the driver name such as `syslog-address`.

For our use-case where we want to write logs to Manta as soon as possible so
that customers have access to their logs, it seems like the `max-size` parameter
would get in the way if implemented. If a user sets `max-size=2g` and the log
does not reach 2g but we have reached the time to send the data to Manta, it
seems like we would want to send it to Manta and rotate it at that point which
would make `max-size` irrelevant.

The `max-file` parameter is also irrelevant in our implementation unless we
start using that as the number of files to keep in Manta. The reason it's
irrelevant is that the way `docker logs` works is that it will show the data
from the latest log file. If there are *any* rotated files (i.e. `max-file` >
0), then those will be inaccessible to the user. Using this to limit the number
of files in Manta will mean that each time we write a file we'll also need to
check existing files and delete older ones.

### What should rotate the logs?

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
periodically looks at /zones/*/logs/ for non-empty files, rotates them to .0 and
then consumes the .0 while sending to Manta. Since this would be running in the
GZ though, it would need to proxy through another zone (perhaps sdc zone) in
order to talk to Manta. It would also need to find the owner_uuid's Manta login
so that it knows the path to write the log.

Another option might be to have logadm rotate /zones/*/logs/stdio.log on some
frequency and have another separate tool (or maybe hermes?) which takes the
rotated files and uploads them. Since we would like to keep the latency between
the logs being written to disk and showing up in Manta minimal, it seems like
for this mode we might need to have logadm and hermes run more frequently, as
currently both run hourly.

Additional problems also arise if we separate the rotation and the upload.
These are surrounding cases where for some reason the upload stopped or got
behind, but not the rotation. In that case we might move stdio.log.0 -> .1 and
then .1 -> .2 and so forth, but if nothing is consuming them these will build up
quickly. Especially if we're doing this rotation every 5 minutes. Unless we
rotated an unlimted number of these, it seems we'd eventually lose data.

Other considerations here:

 * given that we can potentially have over 2000 containers per CN (assuming 128M
   containers and 256G CN) and we can have 1000 CNs per DC... How problematic is
   it to write up to 2M files to Manta every 5 minutes per DC? At what rate
   would we start having problems? Not writing empty files would likely help
   decrease this number significantly.
 * if we're going to use logadm we may need to first fix OS-3097 and related
   tickets.

### Where should the log files go in Manta?

Assuming that we will take the logs on some frequency > 1 minute to write to
Manta, I was thinking we could use the same directory the old KVM-based docker
service used for logs in Manta. This was:

```
/<login>/stor/.joyent/docker/logs/<vm_uuid>
```

in our case under this directory what I would propose is that we have files
named something like:

```
.../<YYYY>/<MM>/<DD>/<HH>/<mm>.log
```

That's 4-digit year, 2-digit month, 2 digit day-of-month, 2 digit hour (00-23),
and 2 digit minute. This would be UTC based on the mtime of file (or is it
better to use the timestamp of the last log entry?).

Any other suggestions? Is it better to use the dockerId instead of the vm_uuid?
The dockerId is what they'll see in their docker client.

### Container Deletion

When a container is deleted between the log-rotation periods, it's likely that
data will still be in its stdio.log that has not yet been sent to Manta. In
order to prevent losing logs here, I'd suggest that we change the
archive_on_delete feature such that it knows to also keep the stdio.log files
in the archived data and have the thing doing rotation also look here for the
last logs to upload for a container.
