---
authors: Trent Mick <trent.mick@joyent.com>
state: publish
---

# RFD 40 Standalone IMGAPI deployment

The primary standalone IMGAPI deployments are <https://images.joyent.com>
(a.k.a. images.jo) and <https://updates.joyent.com> (a.k.a. updates.jo).
"Standalone" here means, not an IMGAPI instance that is running as one of the
core services for a Triton DataCenter.


## The problem

Updates.jo and images.jo are pets: manually setup, updated in-place, it isn't
easy to update their images, backups are a manually setup cronjob that isn't
part of setup, there isn't a documented/script recovery procedure, it isn't
currently possible to make a standalone IMGAPI HA, etc.

E.g., given a new vuln in some part of its dependency stack (e.g. stud), it
isn't clear how to update it.

This RFD will attempt to converge on a plan, implementation and docs for
standalone IMGAPI deployments.

## IMGAPI primer

IMGAPI source is in <https://github.com/joyent/sdc-imgapi>.

IMGAPI is an API to serve Triton images. The server stores two main kinds
of things: image manifests (JSON documents) and image files (large binary
blobs). The code's name for the component that handles manifests is
"the database" ([code](https://github.com/joyent/sdc-imgapi/blob/master/lib/database.js))
and for image files, the "storage"
([code](https://github.com/joyent/sdc-imgapi/blob/master/lib/storage.js)).
An IMGAPI server can be
[configured](https://images.joyent.com/docs/#configuration)
with one "database.type" and one or more ["storage"
mechanisms](https://images.joyent.com/docs/#image-file-storage).

The core IMGAPI in a Triton DataCenter runs with a "moray" database (a HA-able
key-value store) and for starters "local" storage (needed at least for
bootstrapping). A "manta" storage can be added -- generally a requirement to
enable custom image creation in the datacenter for durability of custom
image data.

Standalone IMGAPI deployments use a "local" database (generally there isn't
a [Moray](https://github.com/joyent/moray) to use) and typically use a "local"
and, optionally, a "manta" storage. "local" storage is just files on the local
disk (no replication).

Auth and TLS also differ: A in-Triton DataCenter IMGAPI doesn't use auth (it
only accepts connections on the admin interface) and uses HTTP. A standalone
IMGAPI of course requires auth for endpoints that change data (CreateImage et
al). Basic auth is/was supported, but is deprecated. HTTP Signature auth (the
same as [CloudAPI](https://github.com/joyent/sdc-cloudapi)) is preferred. TLS
termination is currently done via stud (stud -> haproxy -> imgapi) per [these
setup docs](https://images.joyent.com/docs/#configuring-imgapi-for-https). The
use of HAproxy was a copy from Manta's muskie and CloudAPI. Currently only a
single IMGAPI process is behind the HAproxy.

## Requirements

The base requirements of a standalone IMGAPI plan (i.e. good enough that
we are happy to live with for images.jo and updates.jo) are:

1. data (manifests, image files) is *durable*
2. *redeployable*: There is a simple documented procedure for getting on a
   newer/older/latest version of the software.

An open question for #1: Is a periodic backup of the manifests (to Manta)
sufficient (e.g. manifests in the last N minutes since last backup could be
lost)? If you say "no", does your opinion change if a more durable solution
comes with future planned work for HA (e.g. durability could be achieved via an
HA DB cluster)? I.e. "periodic backups are fine for now if we have a plan to do
better later."


## Nice to haves

Eventually these may be promoted to requirements.

1. TLS certs auto-renew (via letsencrypt)
2. HA
3. logs are rotated and uploaded to manta
4. Monitoring

Hopes and dreams: It would be lovely to expose delegate datasets and reprovision
via cloudapi so theoretically those could be used for easier/quicker standalone
IMGAPI instance updates/deployments.


## Current Status

IMGAPI-567/IMGAPI-571 will implement milestone 0 (M0). Remaining milestones are
incomplete and not currently scheduled. M0 implements a significant part of M1
(backup, deploy, restore) and M3 (log file rotation and upload). Good enough for
now.


## M0: a better and documented deploy/update/backup/restore

Issues:

- [IMGAPI-567](https://devhub.joyent.com/jira/browse/IMGAPI-567)

The milestones below are nice and I'd still like to do them. However, priorities
call, so I need to get images.jo and updates.jo on a modern base and updateable
in the shorter term. That's what this milestone is about. It will:

- Update sdc-imgapi.git such that the resultant "imgapi" images can be used both
  for DC-mode IMGAPI instances and for standalone IMGAPI instances (like
  images.jo).
- Document how to setup and maintain a new standalone imgapi zone for images.jo
  or updates.jo.
- Include a number of improvements for standalone IMGAPI instances:
    - log file rotation and upload
    - HTTP signature authkeys can be added to Manta and are sync'd from there
    - background hourly backup (and support for restore)

Basically this milestone stops short of HA IMGAPI and image manifests are
only backed up to durable storage (Manta) hourly.


## M1: backup, deploy, restore

Issues:

- [IMGAPI-571](https://devhub.joyent.com/jira/browse/IMGAPI-571): re-do
  images.jo/updates.jo deployment to be able use stock 'imgapi' images


Milestone "M<number>" sections are for proposed order of work done to pick off
first the requirements, then the nice-to-haves.

Here I'm making the assumption that the answer to the open question in the
"Requirements" section is "yes, periodic backups, with a documented/scripted
restore is sufficient for starters."

Right now setting up an images.jo, for example, is very manually and not
wholely documented. With M1 we'll fix that and integrate first class (i.e.
scripted and documented) backup and restore.

The overall plan here is to deploy using the same "imgapi" images we build for
core Triton IMGAPI zones. We'll add the additional software needed for
standalone mode (HAproxy and stud for now), and add "standalone" boot scripts
(parallel to the standard Triton "boot/{setup,configure}.sh" boot scripts) so
that running a standalone IMGAPI is as simple as: (a) (re-)provision with that
image and (b) possibly ssh in to provide secrets (key access to Manta account,
TLS cert).

Metadata provided at provision-time tells the zone which mode to run in. In core
Triton, a user-script that runs "/opt/smartdc/boot/setup.sh" is what triggers
running on "dc" mode. For standalone mode we'll use a separate user-script or
metadata key.


### Backup

First backup. A standalone-mode IMGAPI will regularly attempt to backup
local data to Manta (whether that is a cronjob or background process in
imgapi is TBD). `imgapiadm status` will report a warning if not configured
for backup (i.e. no Manta config) or if backup is failing.

Specifics: A standalone IMGAPI's local data dir looks like this:

    /data/imgapi/
        # The stuff we want to backup:
        manifests/...       # all the image manifest
        images/...          # image files for those with stor=local
        # The stuff we don't want to backup:
        etc/
            imgapi.config.json
            imgapi-$shortzonename-$datestamp.id_rsa{,.pub}
            cert.pem
        archive/...
        logs/...            # NYI

Given a `manta.user=bob` and `manta.baseDir=myimages`
the Manta base dir is: `/bob/stor/myimages'.  The regular backup
process will backup to: `/bob/stor/myimages/backup/...`.


### Deploy

Minimally a new IMGAPI zone deployment will look as follows. For now we'll use
the 'imgapi' images in updates.joyent.com. So the operator needs to import
one to the DC (say we want the latest one):

    # (1)
    img=$(updates-imgadm list -H -o uuid --latest name=imgapi)
    sdc-imgadm import -S https://updates.joyent.com $img
    # Give the 'bob' account access to it:
    sdc-imgadm add-acl $img $(sdc-useradm get bob | json uuid)

Then create the zone (we are using metadata for configuration):

    # (2a)
    triton create -w --name myimages0 imgapi g4-highcpu-2G \
        -m mode=public -m manta.user=bob -m manta.baseDir=myimages

Practically speaking we'll probably want to use a delegate dataset and
*re*provisioning, so we'll be going through VMAPI (I'll still attempt to make
things work without requiring a delegate dataset):

```
# (2b)
cat <<EOP | sdc-vmadm create
{
    "alias": "myimages0",
    "owner_uuid": "$(sdc-useradm get sdc | json uuid)",
    "billing_id": "$(sdc-papi /packages | json -H -c "this.name=='g4-highcpu-2G'" 0.uuid)",
    "networks": [{"uuid": "$(sdc-napi /network_pools | json -H -c "this.name=='Joyent-SDC-Public'" 0.uuid)"}],
    "image_uuid": "$(sdc-imgadm list name=imgapi --latest -H -o uuid)",
    "brand": "joyent-minimal",
    "delegate_dataset": true,
    "customer_metadata": {
        "mode": "public"
        "manta": {
            "user": "bob",
            "baseDir": "myimages"
        }
    }
}
EOP
```

Every IMGAPI instance creates its own SSH key. This key won't be on the
'bob' account, so we'll have to add it.

    # (3)
    ssh root@$(triton ip myimages0) cat /data/imgapi/etc/imgapi.id_rsa.pub \
        | triton -a bob key add -n 'imgapi-4dad5922-20160607' -f -

As long as there are no other IMGAPI instances running out of this Manta dir,
we should be good: The instance will download the backups, and then become
active.

However, if a current or earlier instance was running out of this Manta dir,
then this IMGAPI instance will refuse to go active (see next section). We'll
need to tell to it take over:

    # (4)
    imgapiadm state set active

If that works, then our new guy should now be active:

    $ curl -ik https://$(triton ip myimages0)/ping | json -H state
    active


For IMGAPI services where we have operator access to the DC (i.e. images.jo
and updates.jo) we'll want to use delegate datasets and reprovision to get
faster updates. The procedure for images.joyent.com then will be:

    # (1)
    img=$(updates-imgadm list -H -o uuid --latest name=imgapi)
    sdc-imgadm import -S https://updates.joyent.com $img
    sdc-imgadm add-acl $img $(sdc-useradm get sdc | json uuid)

    # (2) Put the service in readonly and drain.
    joyent-imgadm adm readonly    # or something like this

    # (3)
    owner=$(sdc-useradm get sdc | json uuid)
    inst=$(sdc-vmadm list owner_uuid=$owner alias=imagesjo0 -H -o uuid)
    sdc-vmadm reprovision $inst $img

    # Should be back soon.
    joyent-imgadm ping


### A single active IMGAPI instance

We don't have multi-instance coordination here. There needs to be a *single*
IMGAPI instance running out of a given Manta dir (called the "primary").
How do we coordinate that? My plan is a lock file in Manta using [PutObject's
test/set semantics](https://apidocs.joyent.com/manta/api.html#PutObject):

    /bob/stor/myimages/run/primary.lock

If that exists and does not contain this instance's id, then the instance
won't go active.
TODO: prove I can do this.

When a instance stops being active for whatever reason, the (now stale)
'primary.lock' is left in place. This tells us what instance *last* was active.
If/when a new instance is to take over the active spot (see "Server States"
section below), it knows from that stale lock that it needs to sync to the
backup.

Further all instances will write a "runstate" JSON file to that dir:

    /bob/stor/myimages/run/$(zonename).runstate

This will allow the `imgapiadm status` command in each IMGAPI zone to know
about other standby instances.


### Server States

This section describes the states an IMGAPI server goes through to become
active (or not) and the valid transitions.

- `initializing`: A starting IMGAPI service starts in this state. In this
  state it will:
    - Setup its local data dir, "/data/imgapi/...".
      On failure, go to "initfail" state.
    - Setup its Manta data dir, if appropriate, "/$user/stor/$baseDir/...".
      On failure, go to "initfail" state.
    - If not already currently the primary instance, then sync to the backup
      local data in Manta. Go to "initfail" state, on failure.
    - Attempt to become "active" (per the "primary.lock" described above).
      If able to grab the lock, go to "active" state.
      If not, go to "standby" state.
- `initfail`: There was an error in initialization. This'll be saved out so
  `imgapiadm status` can report the specific issue. E.g. the common one will
  be that the new SSH key for this instance isn't on the Manta account yet.
  All API endpoints will respond with 503 Server Unavailable when in this state.
  Restart the service to get out of this state (it'll attempt "initialization"
  again).
- `standby`: The server is a warm standby. Only "warm" because it may be
  slightly out of date if the active instance made changes since it last sync'd
  from the backup. In standby mode, the API will respond with 503 Service
  Unavailable for all endpoints. A manual `imgapiadm state set ...` is
  required to get out of this mode.
- `active`: The service is up, has the "primary.lock" and the API is responding.
- `readonly`: The service is up, but only non-read endpoints will error with
  503 Service Unavailable. The only way to this state is manually from
  either "active" or "standby" via `imgapiadm state set readonly`. This can
  be useful for switching primaries:
    - get B to standby
    - put A (the current primary) in readonly
    - wait for A to drain
    - make B the primary and add to DNS
    - remove A from DNS, drain, decommission


## M2: letsencrypt

See about tooling/scripted setup for letsencrypt-based auto TLS cert renewal.

TODO: I need to reacquaint with the tooling here. Brian and I setup automatic
renewal for mo.jo.

Also look at getting standard A or higher rating on
<https://www.ssllabs.com/ssltest/analyze.html>.


## M3: log rotation and upload

tl;dr: Standard /etc/logadm.conf entry(ies) for standalone mode. Rotate to
"/data/imgapi/logs". Script to upload rotated logs to Manta
"/$account/stor/$baseDir/logs/imgapi/YYYY/MM/DD/$instance.log" -- possibly
likewise for stud and HAproxy logs.

Might be able to crib the Manta shell script for log file uploading.


## M4: Monitoring

Currently I believe ops has a pingdom (or similar) check or checks on, say,
images.jo. But there is nothing first class.

TODO: Explore using Amon for this. If that is feasible, then could ship
suggested Amon probes to use for a given instance.


## M5: HA

Getting to HA means:

1. storage: All image files in manta (as opposed to local storage)
2. database: An HA story for the "database" of manifests
3. load balancing
4. shared config

Storage (#1) is easy: `imgapiadm status` would warn/error about image durability
if there are image files using local storage. With IMGAPI-536 there is now
AdminChangeImageStor to easily migrate image files from local to manta storage.

Load balancing (#3): For *Joyent's* services (images.jo, updates.jo) we could
use the LB solution we use for other things. Another alternative is to use a
CNAME to a CNS service record and call it good enough.

Shared config (#4): Some things, like updates.jo's configured "channels"
would need to be common between all instances. Some ideas here would be to
share some of this config in the Manta area with periodic checking for
config changes. An alternative is something like consul for shared config.
The poor man's solution is to just be careful and keep the instance
configs in sync. :)

Database (#2): Trying to coordinate via a flat file database isn't tenable.
My current thought is to look at using a RethinkDB cluster. We don't yet have
RethinkDB in pkgsrc (https://github.com/rethinkdb/rethinkdb/pull/4309). Lacking
that, we'd probably run a separate set of RethinkDB instances in LX zones. So
far we've had good experience with RethinkDB with thoth and sesat -- granted
only with a single RethinkDB instance currently. Writing a RethinkDB backend
for IMGAPI's database would not be difficult. We should also consider a
Moray/Manatee cluster.


## Trent's scratch notes, ignore this section

    [root@4dad5922 myimages0]$ imgapiadm status
    State: initfail
    ...

     Error: Cannot connect to Manta storage
     Error:      NotAuthorized: ...   (error message from client)
    Reason: Likely this instance's SSH key has not been added to the 'bob' account
       Fix: # Run the following where 'triton' is setup:
       Fix: ssh root@IP cat /data/imgapi/etc/imgapi.id_rsa.pub | triton -a bob key add -n 'imgapi-4dad5922-myimgapi1-20160607' -f -
    Impact: This IMGAPI server will not be able to complete initialization
