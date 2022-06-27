---
authors: Trent Mick <trent.mick@joyent.com>
state: publish
---

# RFD 47 Retention policy for Joyent engineering data in Manta

Joyent engineering puts a lot of stuff in Manta through automated processes
(builds, images, logs, crash dumps, etc.). Currently that data is growing
forever. This can prove to be untenable. Let's get a policy for what to
retain and for how long.


## Current Status

Dave Pacheco has worked on Manta (poseidon) usage.

Trent has worked on Triton/Manta [builds](#builds) usage. There is a
`purge-mg-builds` script and Jenkins job to handle daily removal of old builds.

See the [Tickets](#tickets) section below for work that has been done cleaning
up some usage.


## mdu

Having `mdu` per <https://github.com/TritonDataCenter/node-manta/issues/143> would be
really helpful to understand how much is used where.

Status:
- Dave has a prototype here: <https://github.com/davepacheco/manta-mdu>
  Importantly, Dave's does real `stat` calls on the storage CNs, so the
  numbers more accurately reflect disk usage, rather than file size.
- Trent has a couple poorman's prototypes here:
  <https://mo.joyent.com/trentops/blob/master/bin/poormans-mdu-subdirs>,
  <https://mo.joyent.com/trentops/blob/master/bin/poormans-mdu>
- Trent had a start at one which involved changes to node-manta. This
  is currently uncommited.

## mprune

The [mprune tool](https://github.com/TritonDataCenter/manta-mprune) can be used to
automate purging of old objects inside date-organized directory structures.  See
"Manta's Manatee backups" below for an example.

This tool is still pretty simple, but could be extended to support additional
use-cases.


## builds

Automatic builds of Triton and Manta bits are done for various reasons
(commits to #master of top-level repos, commits to `release-YYYYMMDD` release
branches, a regular schedule for `headnode*` builds, etc.). In general the
builds all get uploaded to one of:

```
/Joyent_Dev/public/builds/$name/$branch-$buildstamp
/Joyent_Dev/stor/builds/$name/$branch-$buildstamp
```

Retention policy for builds:

- Have a whitelist of build `name`s that will be deleted. This means new ones
  won't get cleaned out by default -- i.e. safe by default.
- Delete anything older than:
    - for `headnode*` builds: a month
      A year of `headnode*` builds is too much. At ~1 per day \* 4 build
      flavours (`headnode[-joyent][-debug]`) \* 6 GiB per build, that is
      8 TiB of space. At one month retention we are down to 744 GiB of space.
    - for other builds: a year
- "master" builds are special: Always retain at least one (the latest) master
  build, even if it older than the configured cut off.
- Ensure that the `$branch-latest` "link" files are removed if the last
  such dir was removed.

This policy is hardcoded and handled by:
    https://github.com/TritonDataCenter/mountain-gorilla/blob/master/tools/purge-mg-builds
and is run daily against `/Joyent_Dev/stor/builds` and
`/Joyent_Dev/public/builds` by the Joyent-internal "purge-mg-builds" Jenkins
job.


Some considerations for a retention policy:

- Builds for customers should always exist elsewhere in Manta for retention:
  images (including agents, platforms, etc.) in updates.joyent.com (see
  next section), headnode (aka COAL and USB) builds in
  `/Joyent_Dev/public/SmartDataCenter`, onprem headnode releases in
  `/joyentsup/stor/SDC7` (see
  "/joyentsup/stor/SDC7/usb-joyent-release.latest.README"). Exceptions to this:
  `platform-debug`.
- As an educated guess, my [Trent] bet is that the `headnode*` builds are the
  big culprit for the `Joyent_Dev` account usage.
  TODO: check that
  We currently build these once per day, there are 4 flavours (headnode,
  headnode-debug, headnode-joyent, headnode-joyent-debug), and each is
  ~6G. That's 24G per day. It remains to be seen how significant that is.
- RobertM mentioned "Though I have to admit, having some of the old platform
  builds have helped for bisecting some things."
  In discussion with rm, we felt that having release builds of the platform
  in updates.jo "release" channel going back years should be sufficient.



## updates.joyent.com

Status: No implementation of a retention policy for updates.joyent.com
is in place. IOW, all images in updates.joyent.com are currently living forever.

The Joyent updates server holds all the images/platforms/agentsshars et al
used for updating Triton builds after initial install. All commits to #master
of top-level repositories lead to new builds being added. There are currently
around 25k images, which naively (this doesn't count copies, or actual
blocks used in Manta) takes 1.7 TiB of space.

```
$ updates-imgadm -C '*' list -H | wc -l
   25335
$ updates-imgadm -C '*' list -H -o size | awk '{s+=$1} END {print s}'
1896458696205
```

Updates.jo has channels, which are relevant for retention policy:

```
$ updates-imgadm channels
NAME          DEFAULT  DESCRIPTION
experimental  -        feature-branch builds (warning: 'latest' isn't meaningful)
dev           true     main development branch builds
staging       -        staging for release branch builds before a full release
release       -        release bits
support       -        Joyent-supported release bits
```

One wrinkle is for Manta: Currently Manta's deployment procedure pulls images
from the *default* "dev" channel, and not from release. This isn't currently
configurable. That means there is a need for greater rentention of *Manta*
images on the "dev" channel.

Suggested retention policy for each channel:

1. `support`: No automated deletion. We can delete from here manually after
   the Joyent support org confirms all onprem customers have moved past.
2. `release`: No automated deletion. At a later date we might consider removal
   of ancient builds after a period of time after which long term support for
   that version has expired.
3. `staging`: Delete after six months. This channel is a staging area to group
   images for a release. The release process adds all latest images to the
   "release" channel as part of release. Given bi-weekly releases, 6 months
   should be ample retention.
4. `dev`: Keep if less than a year old. If this is a Manta image, keep if
   less than 3 years old (Q: is this long enough for Manta images?). Have a
   specific list of image `name` values to consider for automated deletion --
   this is intended to help guard against deleting some images that shouldn't
   be: the large and laborious manta-marlin images used for Manta jobs, the
   origin images (see RFD 46), etc.
5. `experimental`: Keep if less than 3 months old. Keep the latest by `(name,
   branch)` for at least one year. Here "branch" is inferred from `version` if
   it matches the pattern `$branch-$buildstamp-g$gitsha` or the whole version if
   it doesn't match that pattern.

Deletion requirements:

- Ability to do a dry run.
- A script to confirm that the Triton component and platform images in use on
  JPC are available in updates.jo (as some kind of pre-purge "health check").
- The script should log all deletions to a log file that gets uploaded to
  Manta for verification.
- If reasonable, it would be nice to have a "purgatory" for deleted images
  so that an accidentally delete image is recoverable up to some period after
  it is removed from access via the updates API.

Ticket: <https://mnx.atlassian.net/browse/IMGAPI-572>



## Manual cruft and calculations

### Cruft dirs in `/Joyent_Dev/stor/builds`

    $ mls /Joyent_Dev/stor/builds | while read d; do echo "# $d"; mget /Joyent_Dev/stor/builds/${d}release-20160707-latest; done
    # firmware-tools/
    /Joyent_Dev/stor/builds/firmware-tools/release-20160707-20160707T045517Z
    # fwapi/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/fwapi/release-20160707-latest was not found
    # headnode-joyent/
    /Joyent_Dev/stor/builds/headnode-joyent/release-20160707-20160707T062959Z
    # headnode-joyent-debug/
    /Joyent_Dev/stor/builds/headnode-joyent-debug/release-20160707-20160707T061159Z
    # mockcloud/
    /Joyent_Dev/stor/builds/mockcloud/release-20160707-20160707T044945Z
    # mockcn/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/mockcn/release-20160707-latest was not found
    # old/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/old/release-20160707-latest was not found
    # propeller/
    /Joyent_Dev/stor/builds/propeller/release-20160707-20160707T035011Z
    # sdc-system-tests/
    /Joyent_Dev/stor/builds/sdc-system-tests/release-20160707-20160707T045322Z
    # sdcsso/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/sdcsso/release-20160707-latest was not found
    # vapi/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/vapi/release-20160707-latest was not found
    # vmapi/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/vmapi/release-20160707-latest was not found
    # volapi/
    mget: ResourceNotFoundError: /Joyent_Dev/stor/builds/volapi/release-20160707-latest was not found

Those "was not found" cases are, I think, cruft.


### Cruft in `/Joyent_Dev/stor/logs`

All the us-beta-4 stuff can be turfed IMO (Trent):

    [trent.mick@us-east /Joyent_Dev/stor/logs]$ ls
    us-beta-4
    ...
    [trent.mick@us-east /Joyent_Dev/stor/logs]$ ls fwadm
    us-beta-4
    [trent.mick@us-east /Joyent_Dev/stor/logs]$ ls vmadm
    us-beta-4

All the 'sf-2' stuff IMO (dates from Mar 2014 to Jan 2015):

    /Joyent_Dev/stor/logs/sf-2


### Triton Logs

A Triton DC setup to upload logs to Manta, currently uploads about
83 logsets, covering 50+ "core" services and 30+ agent services, e.g.:

```
$ mls /Joyent_Dev/stor/logs/staging-1
adminui/          # core Triton service running on the headnode
amon-agent/       # agent service running on each server
amon-master/
binder/
caaggsvc-auto0/
caaggsvc-auto1/
...
```

And one per hour, per instance. Assuming one instance for each core service
(some typically have more: manatee, moray, binder), and one log for each
agent service *per CN*, the total number of log files generated per day for
a modest datacenter with 100 servers is:

- core services: 50 x 24 = 1200
- agent services: 30 x 24 x 100 = 72000
- total: 73200 log files per day, or ~27 million per year!

There are so many logs here, that `mfind /Joyent_Dev/stor/staging-1/logs` and
similar is getting untenable (anecdote: I've been mfind'ing that dir
for >1h now in a mlogin session).

How big are these log files? Here is a [snapshot](./triton_log_size.md) of
logs on Joyent's beta datacenter for a given day. Despite the large raw sizes,
the space taken up after compression is not as substantial as builds and
database backups. However they likely contribute to a large proportion of the
Manta metadata. The burden of log purge is currently on the operator, as there
is no built-in pruning process on Triton or Manta.

Although the retention decisions for system logs are largely dependent on the
corporate data retention policy of the Triton operator, the nature of the logs
should be taken into account as well. Some logs are important as audit trails
to record the actions taken by end users (e.g. cloudapi, docker) and probably
need to be kept indefinitely. Some logs are useful for debugging orchestration
issues and are typically useful for a limit period of time. Some logs are
generated by "administrative" services (e.g. DNS, DHCP, queuing) and may be
required for an even shorter period of time.

Based on the [build purge script](https://github.com/TritonDataCenter/mountain-gorilla/blob/master/tools/purge-mg-builds),
a similar [log purge script](./log_purge_script.sh) with retention period
configurable per-service can be used to restrict the space taken up by log
files while maintaining important data.


### Manta's Manatee backups

Manta backs up a full copy of each shard's database every day.  These get stored
into Manta in /poseidon/stor/manatee\_backups.  There is no automatic cleanup of
old backups.  We run the [mprune tool](https://github.com/TritonDataCenter/manta-mprune)
manually as needed to implement the following policy:

* keep shard 1 backups forever.  These are relatively small, and it's
  occasionally useful to debug old Marlin jobs from these dumps.
* for the rest of the shards, for backups older than 2 months, we keep two
  backups per calendar month.  (This used to be a full year.)
* for the rest of the shards, for backups within the last 2 months, we keep all
  backups.

See MANTA-2961 and MANTA-3033 for examples.


## Other stuff

After an `mdu` implementation it should be easier to poke around looking for
particularly heavy usage areas where we need spend effort.

- logs: /{admin,Joyent_Dev}/stor/logs
  JoshC suggested moving these, at least for the nightly and staging envs,
  to the Staging Manta.
  TOOLS-1523 has done this for nightly's usage -- old nightly-1 data has not
  yet been removed.
- sdc data dumps: /{admin,Joyent_Dev}/stor/sdc
  JoshC suggested moving these, at least for the nightly and staging envs,
  to the Staging Manta.
  TOOLS-1523 has done this for nightly's usage -- old nightly-1 data has not
  yet been removed.

TODO: dig into size usage for these


## Tickets

Some relevant tickets in the course of discussing and implementing some
Engineering cleanup of Manta usage:

- [MANTA-2961](https://mnx.atlassian.net/browse/MANTA-2961) "poseidon" using too much Manta space
- [TOOLS-1508](https://mnx.atlassian.net/browse/TOOLS-1508) prep_dataset_in_jpc.sh using wrong "mantapath" dir for built image export
- [RELENG-703](https://mnx.atlassian.net/browse/RELENG-703) clean out headnode builds in Manta per RFD 47
- [RELENG-704](https://mnx.atlassian.net/browse/RELENG-704) clean out non-headnode builds in Manta per RFD 47
- [TOOLS-1523](https://mnx.atlassian.net/browse/TOOLS-1523) switch nightly-1 to staging Manta, and get nightly's IMGAPI to use Manta
- [CMON-9](https://mnx.atlassian.net/browse/CMON-9) add cmon builds to purge-mg-builds process
