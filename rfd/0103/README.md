---
authors: Brittany Wald <brittany.wald@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+103%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 103 Operationalize Resharding

### Intro

It is not always possible to know ahead of time how quickly or large a Manta
deployment will grow.  It is also not possible to perfectly predict object size
and extrapolate growth of the metadata tier from that. For this reason, it is
necessary for us to be able to arbitrarily scale our metadata tier, so that we
can reference however many new objects are being created without being limited
by storage capacity.  The process for doing this, which is called resharding,
has been documented in the past here:

https://github.com/TritonDataCenter/manatee/blob/3771c6fbd979ad41e7a71b19f9e2b7ff99542134/docs/resharding.md

However, this document is now outdated, and it is not possible that it was
thoroughly tested at a scale comparable with our current operation.

This RFD will restate many of the concepts in the manual resharding guide
referenced above, and will use some of the same examples, when appropriate.
This is because the scope of this document will likely expand to include plans
for an automated solution to this problem, and it will be helpful to update and
restate any goals and changes to this implementation in one place with all
available context.

### Background

Our current strategy for evenly splitting up load across the Manatee peers that
comprise our metadata tier is to create a mapping of vnodes (virtual database
shards) to pnodes (physical database shards) using node-fash, a library that
provides a modulo-based consistent hashing algorithm. This distributes
responsibility for our metadata, and in theory, provides the flexibility to
easily move the data assigned to any vnode to a new pnode if we need to.
Electric-moray is responsible for storing the hash ring that results from this
operation, and for communicating with the postgres databases (moray shards)
stored in Manatee instances within a deployment.

### Manual Resharding Step-By-Step

This is a manual process for now, and will likely remain so until it has been
performed multiple times.  Updates to this document will occur as tools are
built.

#### 1. Determine which vnodes to move.

Go into the zone of the primary Manatee shard and run this command to display
how many keys are stored on each vnode.

        $ psql moray -c 'select _vnode, count(*) from manta group by _vnode order by count desc;'

The output will look something like this (WLSLT):

        moray=# select _vnode, count(*) from manta group by _vnode order by count desc;
        _vnode | count
        --------+-------
        0   |   195
        106 |    36
        943 |    28
        689 |    18
        501 |    16
        39  |    16
        428 |    15
        556 |    15
        769 |    13
        997 |    12
        402 |    12
        783 |    11
        807 |    11
        623 |    10
        116 |     7
        44  |     7
        956 |     7
        859 |     7
        59  |     6
        114 |     6
        539 |     6

This is how we're going to choose vnodes to reshard **only** as an example.  In
reality our use case will be to split a pnode in half, moving 50% of its vnodes
to a new pnode.  The query for selecting these in postgres is pending completion
of MANTA-3389, which is meant to confirm (or refute) our expectations that this
(splitting in half) is a sufficient selection mechanism to alleviate our issue,
which is reaching capacity on a given pnode.  However, in the following
walkthrough, we will just be remapping vnodes 0, 106, and 943.  This is because
it is easier to follow along with a smaller number of vnodes, and to check your
work if you are just running through this process as a test.  It is also a sane
use-case (though not ours) to remap vnodes to pnodes by distribution of data on
them as opposed to doing a split down the middle.

#### 2. Create a canary directory.

This step is only for testing out the resharding process, it is not meant to be
carried out on production deployments.

In this case, there will be one additional vnode that we remap, despite the
fact that it will only have one key inside it.  That one key will be a canary
directory that we create purely for the purpose of easily tracking one file
throughout the resharding process.  We aren't going to be able to control which
vnode it goes into, because of the determinstic hashing algorithm, but we can
look at which vnode it has been allocated to once we've created it.

Generate a random uuid with the `uuid` command, and then run:

        $ mmkdir -p /<your_user>/stor/re-shard-canary-dir/<your_uuid>

Now we can log in to a muskie (webapi) zone and find the file via mlocate:

        $ /opt/smartdc/muskie/bin/mlocate -f /opt/smartdc/muskie/etc/config.json /<your_user>/stor/re-shard-canary-dir/<your_uuid>

The output WLSLT (assuming 2178ed56-ed9b-11e2-8370-d70455cbcdc2 was {youruuid}):

        {
            "dirname": "/5884dd74-949a-40ec-8d13-dd3151897343/stor/re-shard-canary-dir",
            "key": "/5884dd74-949a-40ec-8d13-dd3151897343/stor/re-shard-canary-dir/<your_uuid>",
            "headers": {},
            "mtime": 1373926131745,
            "name": "2178ed56-ed9b-11e2-8370-d70455cbcdc2",
            "owner": "5884dd74-949a-40ec-8d13-dd3151897343",
            "type": "directory",
            "_key": "/<your_user>/stor/<your_uuid>",
            "_moray": "tcp://electric-moray.emy-11.joyent.us:2020",
            "_node": {
                "pnode": "tcp://1.moray.emy-11.joyent.us:2020",
                "vnode": "689",
                "data": 1
            }
        }

Take note of the vnode key's value, in this case 689.  That will be the fourth
node that we want to remap, along with 0, 106, and 943.  Before we do that,
though, lets make a test file under this directory.

        $ mput -f test.txt /<your_user>/stor/re-shard-canary-dir/<your_uuid>/test.txt

Let's also store the vnode of this test file, we'll want it later for other
tests.

(In muskie):

    $ /opt/smartdc/muskie/bin/mlocate -f /opt/smartdc/muskie/etc/config.json /<your_user>/stor/re-shard-canary-dir/<your_uuid>/test.txt

#### 3. Set up new async peer.

The first thing we have to do is create the shard we are going to move data
into.  In production, you will use a combination of `manta-adm show -sj` and `manta-adm update`
to deploy new peers on the CNs where you want them to run, which is similar to
what we would do in a lab environment.

We would specifically, in production, not increment the counter of postgres
instances, but instead create a new block in the configuration file with the new
physical location for that new postgres instance.  See the Manta Operator Guide
for details about recommended placement of services.

In a lab deployment, we can do this by creating a new config file for Manta that
bumps up the number of postgres instances in whichever Moray is holding the
metadata information we want to reshard.  (The reason this is not possible in a
production environment is because there is only one postgres zone on each
physical server, so incrementing this counter would mean we are co-hosting
postgres zones.)  In a lab environment, however, this is not a concern.  So as
an exercise, we can find out which instances these are by running `manta-shardadm list`
in our manta deployment zone (manta0) and noting the name of shards that have
the type "Index" -- the output WLSLT:

        TYPE         SHARD NAME
        Index        1.moray.emy-11.joyent.us
        Index        2.moray.emy-11.joyent.us
        Marlin       1.moray.emy-11.joyent.us
        Storage      1.moray.emy-11.joyent.us

Then, if we go into any postgres peer and run `manatee-adm show`, the "cluster"
field will say which moray it is on.  This command will also let us know which
Manatee is the primary for the given shard.  In this deployment, for example, it
is the instance whose uuid begins `0beca041`.

        $ manatee-adm show
        zookeeper:   10.77.77.113
        cluster:     2.moray.emy-11.joyent.us
        generation:  1 (0/00000000)
        mode:        normal
        freeze:      not frozen

        ROLE     PEER     PG   REPL  SENT          FLUSH         REPLAY        LAG   
        primary  0beca041 ok   sync  0/D225168     0/D225168     0/D225168     -     
        sync     cd79bd3b ok   async 0/D225168     0/D225168     0/D225168     0m42s 
        async    2662e5ad ok   -     -             -             -             0m42s 

Here is a diagram of what this looks like:

          PRIMARY                  SYNC                    ASYNC


       +-----------+           +-----------+           +-----------+
       |           |           |           |           |           |
       | 1.moray   |           |  1.moray  |           |  1.moray  |
       |           |           |           |           |           |
       |           | replicate |           | replicate |           |
       +-----------+  +----->  +-----------+  +----->  +-----------+
       |           |           |           |           |           |
       | 2.moray   |           |  2.moray  |           |  2.moray  |
       |           |           |           |           |           |
       |           |           |           |           |           |
       +-----------+           +-----------+           +-----------+

Back on the headnode, we can use `manta-adm show -sj` to generate a JSON file of
our current Manta configuration:

        manta-adm show -sj > my_config.json

Open `my_config.json` and increment the value of the key that matches the
postgres instance you are resharding.  We will add three peers so that when we
split the shard up later, we are not down for writes during a sync rebuild,
which would be the case if we only moved over one new peer and then had to wait
for the data to replicate over.

To apply these changes, run `manta-adm update my_config.json`.  Next, run `manatee-adm show`
in the postgres zone again.  You should now see three more async peers trying to
catch up.  You can run `manatee-adm pg-status 1` to view the running process.

        $ manatee-adm show
        zookeeper:   10.77.77.113
        cluster:     2.moray.emy-11.joyent.us
        generation:  1 (0/00000000)
        mode:        normal
        freeze:      not frozen

        ROLE     PEER     PG   REPL  SENT          FLUSH         REPLAY        LAG   
        primary  0beca041 ok   sync  0/D2B13A8     0/D2B13A8     0/D2B13A8     -     
        sync     cd79bd3b ok   async 0/D2B13A8     0/D2B13A8     0/D2B13A8     5m48s 
        async    2662e5ad ok   async 0/D2B13A8     0/D2B13A8     0/D2B13A8     5m48s 
        async    85af8d74 ok   -     -             -             -             5m48s 

It is a good idea to use mlive to generate some load that you can watch if you
are doing this in a test environment.  The important numbers to watch are
the primary's SENT and the first async's REPLAY.  When they are close together
(at least the first 4 digits are the same) then the async shard is sufficiently
caught up for us to reshard. We can also look at the LAG -- it is a good sign
when it is `-` for the primary and a small number for the other roles.

#### 4. Put the vnodes you want to reshard into read-only mode.

If we try to write to a vnode while it is moving between pnodes we may lose 
the data in transit depending on what part of the process we are at. The
vnode-to-pnode mapping is stored within four duplicate LevelDB directories
stored in the electric-moray zone at `/electric-moray/chash/leveldb-202{1-4}`.
LevelDB only allows one process to access each db directory at once, this is why
we have four.  Usually, electric-moray holds the lock for the db, and you can
check this with `svcs -p *electric-moray*`.  We can use `svcadm` to disable any
of those processes in order to operate on the LevelDB topology directly.
Otherwise, we will not be able to run any commands on the LevelDB -- not even to
read data out.

However, whatever we do to one LevelDB, we must do to all four in order to
maintain consistency.  We can do these one at a time, but I will demonstrate
only one.  In a multiple-electric-moray setup, you can use `manta-oneach` to
perform each operation more quickly.  We do not need to worry about staggering
updates to each electric-moray, since we will not be down for reads or writes at
any time during this step, since it will be done sequentially for each LevelDB.
There will be 3 databases available to route requests while each one is down.

LevelDB uses a coarse-grained lock in order to ensure that concurrent writes to
the database can be safely inserted.  In order to make any changes to LevelDB we
first need to disable the process which holds that lock.

        # Disable the process that holds the lock
        $ manta-oneach -s electric-moray "svcadm disable electric-moray-2021" 
        # Display information, such as which shard this vnode is on
        $ manta-oneach -s electric-moray "fash get-vnode-pnode-and-data -v '$VNODES' -l /electric-moray/chash/leveldb-2021/"
        # Put the vnode(s) we care about into read-only mode
        $ manta-oneach -s electric-moray "fash add-data -v '$VNODES' -l /electric-moray/chash/leveldb-2021/ -b leveldb -d 'ro'"
        # Check that the read-only vnodes are the ones you expect
        $ manta-oneach -s electric-moray "fash get-data-vnodes -l /electric-moray/chash/leveldb-2021"
        # Give electric-moray back the lock
        $ manta-oneach -s electric-moray "svcadm enable electric-moray-2021"

The -d flag in node-fash is destructive -- it will overwrite whatever data
previously occupied the value on that key.  To start out, every key's value
defaults to 1.  By setting the field to 'ro', we are telling electric-moray not
to send writes to this vnode.  Note that this means muskie will be getting
inconsistent vnode state from electric-moray if a user tries to write to data on
those nodes during this process.  However, until the last LevelDB is flipped to
read-only, a retry has a 75%, then 50%, then 25% chance of succeeding.

Now do the same thing for the electric-moray-202{2-4}.

#### 5. Take a lock to prevent pg dumps.

An ongoing pg dump will interfere with the resharding process, so we need to
make sure that one is not happening during this time.  Maintenance jobs such as
metering, auditing, and garbage collection rely on the dumps.  At risk of these
jobs incorrectly detecting where or how many of the objects stored on the vnodes
we need to put them on hold while we are in states they do not expect with
respect to object storage.  This command will need to be run from a nameservice
(zookeeper) zone in order to create a lock:

        $ zkCli.sh create /pg_dump_lock whatever_you_want_to_call_the_lock

Check that you successfully created the lock:

        $ zkCli.sh get /pg_dump_lock

You should see the name of your lock at the top of the output.  This is a coarse
grained lock -- Manatee will just check for the presence of a dump lock file and
stop all dumps when it sees one.

#### 6. Make sure Manatee dumps are not running.

Log in to the postgres zone for the new shard(s) you created in step 3, and run:

        $ manta-oneach --service postgres "ptree | grep pg_dump.sh"

If anything is running, wait until it is finished (or kill it) before moving to
the next step.

#### 7. Move the new Manatee peer(s) into a new Moray shard.

This requires changes to SAPI metadata and rebooting the node to pick up the
changes.  In this step, $ZONE_UUID always refers to the zone of an async peer
we created in step 3.  First, we will have to disable the manatee-sitter in each
new async peer.  The order in which they are disabled does not matter, but when
they are re-enabled, which will happen during the reprovision step below, it
must be in the same order as they were created.

        # Run in the headnode to get the list of zonenames for the shard peers
        # For 1.moray that will be each 1.postgres instance
        $ vmadm list | grep 1.postgres | cut -d "OS" -f 1
        # Disable each manatee sitter
        $ manta-oneach --zonename $ZONE_UUID "svcadm disable manatee-sitter"

Next, we have to update the SAPI metadata for each new async zone.  This will
add a zone to the new shard, so be sure to run it for each new async.

        $ sapiadm update $ZONE_UUID metadata.SERVICE_NAME="3.moray.emy-11.joyent.us"
        $ sapiadm update $ZONE_UUID metadata.SHARD=3
        $ sapiadm update $ZONE_UUID metadata.MANATEE_SHARD_PATH='/manatee/3.moray.emy-11.joyent.us'

We will also need to update the alias parameter in the VM, by reprovisioning the
zone with sapiadm, since the alias of the vm is is a first-class property used
to create it, and contains the cluster name.  This will also reboot the zone to
pick up the metadata changes.

        # Update vmapi
        $ sdc-vmapi /vms/"$ZONE_UUID"?action=update -X POST -d '{"alias":"3.postgres.emy-11.joyent.us-<PART_BEFORE_FIRST_HYPHEN_IN_$ZONE_UUID>"}'
        # For consistency, but won't affect cluster state
        $ sapiadm update $ZONE_UUID params.alias=3.postgres.emy-11.joyent.us-<PART_BEFORE_FIRST_HYPHEN_IN_$ZONE_UUID>
        # Reboot the zone and pick up changes
        $ sapiadm reprovision $ZONE_UUID <image_uuid>

At this point, if you run `manta-adm show -sj` you will see that the postgres
zone entries have changed -- there is now another manatee instance.  If you log
in to a zone in the new manatee and try manatee-adm show:

        $ manatee-adm show
        manatee-adm: no state object exists for shard: "3.moray.joyent.us"

This is because the /state file for a zookeeper manatee directory is populated
once there is a cluster for each moray.  The first generation doesn't form
until there are two or more peers.  So, copy the `manta-adm show` output to a
new file and add 2 more postgres zones, since you are adding a sync and async
for the new cluster, then run `manta-adm update`.

Now, we are in a tricky state.  You will notice that if you run `manatee-adm show`
again, the same error message is displayed.  If you check in zookeeper (which we
will walk through shortly), you will see that the election file has updated from
one IP to three IPs -- but there is stil no state file. This is partially
explained by the comments linked here in the code for manatee-state-machine:

https://github.com/TritonDataCenter/manatee-state-machine/blob/a4d6b51355d69f0bed40bf295f31a7fb7f772f84/lib/manatee-peer.js#L445
https://github.com/TritonDataCenter/manatee-state-machine/blob/a4d6b51355d69f0bed40bf295f31a7fb7f772f84/lib/manatee-peer.js#L454

Currently, when we bring up a new shard toplogy, the election is pre-assigned to
zookeeper.  Meaning, we have already decided which node is the primary, which is
the sync, etc.  This is to prevent race conditions and other problems that
occured in the original iteration of manatee.  We can reference this document
for futher details:

https://github.com/TritonDataCenter/manatee/blob/34238c257d3cb6fe7eba247c7e40a1dd49c4f3e8/docs/migrate-1-to-2.md

The relevant part of this for our purposes is this: since we are starting out
with only a single node that has data on it, we are going to be in a state from
a data perspective, as we bring up nodes, that is a similar to the "legacy"
mode referenced below:

https://github.com/TritonDataCenter/manatee/blob/34238c257d3cb6fe7eba247c7e40a1dd49c4f3e8/lib/adm.js#L209

In this mode, the first zone created became the primary.  So, in that older
version of manatee, there would be pre-existing data on the primary that would
then move over to the sync and async.  However, when we bring up a new cluster
today, manatee normally expects that there is no preexisting data in the
cluster.  This means we will need to backfill data from our new primary into the
the other two nodes.  If you get into a bad state at some point while doing
this, this document can help you find your way out:                            
                                                                                
https://github.com/TritonDataCenter/manatee/blob/3771c6fbd979ad41e7a71b19f9e2b7ff99542134/docs/trouble-shooting.md

But beware, there is some outdated information in that document.  Check each
command's man page before using it.  With that said, this is the order of
operations for moving the now-split manatee peer into the new shard:

        # Log in to a nameservice zone (it doesn't matter which)
        $ manta-login nameservice
        # Press 0, 1, or 2
        # Go into the zookeeper command line interface
        $ zkCli.sh
        # Read the zk election information for whichever moray cluster you're using
        (inside zkCli)$ ls /manatee/3.moray.emy-11.joyent.us/election
        # Confirm that the lowest-numbered IP is the primary

        [zk: localhost:2181(CONNECTED) 16] ls /manatee/3.moray.emy-11.joyent.us/election
        [10.77.77.167:5432:12345-0000000000, 10.77.77.169:5432:12345-0000000002, 10.77.77.168:5432:12345-0000000001]

In this setup, the correct setup is displayed.  10.77.77.167 is the IP of the
primary zone, and it is numbered 12345-0000000000, which is lower than the IPs
assigned to 12345-0000000002 and 0000000001.  Below are instructions to clear
out a bad state:

        # Remove the entire directory
        (inside zkCli)$ rmr /manatee/3.moray.emy-11.joyent.us
        # Check to see if the IP for the postgres zone you've created is there
        (inside zkCli)$ ls /manatee/3.moray.emy-11.joyent.us/election

Now, log in to any postgres zone in the new cluster, and run:

        $ manatee-adm state-backfill
                                                                                
It does not matter which node in the cluster you run this from, because
information about which node has the data on it (the primary) is kept in
zookeeper's `/election` file.  This is why  we need to make sure that the first
zone we created is registered as the primary in zookeeper, otherwise we risk
backfilling data from one of the empty zones, which would remove the data we
just painstakingly moved over from the old shard.

Log in to the zone and check that manatee is back up and running in the new
shard:

        $ manatee-adm show

Also check that state information now exists in zookeeper (and is correct) in a
nameservice zone.

        $ zkCli.sh
        # Read the zk state
        (inside zkCli)$ get /manatee/3.moray.emy-11.joyent.us/state

Double-check that the primary is the original shard that you split off, and you
can also run some test sql in the postgres zones to make sure that data ended up
in the new cluster.

You will notice, however that there is a "freeze" state on the shard, and that
the lag is very high.  The generation is 0 and the initWal is also 0.

        $ manatee-adm state | json
        {
          "primary": {
            "zoneId": "c4ea4236-b7f4-4ce4-b221-7d8289e770fb",
            "ip": "10.77.77.218",
            "pgUrl": "tcp://postgres@10.77.77.218:5432/postgres",
            "backupUrl": "http://10.77.77.218:12345",
            "id": "10.77.77.218:5432:12345"
          },
          "sync": {
            "zoneId": "91c91f35-54e7-46b8-aa0c-40bee7f04547",
            "ip": "10.77.77.220",
            "pgUrl": "tcp://postgres@10.77.77.220:5432/postgres",
            "backupUrl": "http://10.77.77.220:12345",
            "id": "10.77.77.220:5432:12345"
          },
          "async": [
            {
              "zoneId": "441eeb0f-6dd7-4337-8438-fe6aa4207e68",
              "ip": "10.77.77.219",
              "pgUrl": "tcp://postgres@10.77.77.219:5432/postgres",
              "backupUrl": "http://10.77.77.219:12345",
              "id": "10.77.77.219:5432:12345"
            }
          ],
          "generation": 0,
          "initWal": "0/0000000",
          "freeze": {
            "date": "2017-10-26T19:38:42.141Z",
            "reason": "manatee-adm state-backfill"
          }
        }

Or, with show:

        $ manatee-adm show
        zookeeper:   10.77.77.113
        cluster:     3.moray.emy-11.joyent.us
        generation:  0 (0/0000000)
        mode:        normal
        freeze:      frozen since 2017-07-18T21:23:46.494Z
        freeze info: manatee-adm state-backfill
        
        ROLE     PEER     PG   REPL  SENT          FLUSH         REPLAY        LAG   
        primary  75d2077e ok   sync  1/6C9F47C0    1/6C9F47C0    1/6C9F47C0    -     
        sync     b69b60ac ok   async 1/6C9F47C0    1/6C9F47C0    1/6C9F47C0    1279m02s
        async    d2a9cfcf ok   -     -             -             -             1279m02s

To update to generation 1 and start up the cluster, we must remove the freeze
state and reprovision the zones. As per the Manatee migration documentation, we
will log into the async and run:

        $ manatee-adm unfreeze

And then reprovision, in order, the async, then the sync, then the primary. If
you re-run the show and state commands, you should now see low lag, initWal that
is non-zero, generation 1, and a freeze state of "not frozen," which WLSLT:

        $ manatee-adm state | json
        {
          "generation": 1,
          "primary": {
            "id": "10.77.77.218:5432:12345",
            "ip": "10.77.77.218",
            "pgUrl": "tcp://postgres@10.77.77.218:5432/postgres",
            "zoneId": "c4ea4236-b7f4-4ce4-b221-7d8289e770fb",
            "backupUrl": "http://10.77.77.218:12345"
          },
          "sync": {
            "zoneId": "441eeb0f-6dd7-4337-8438-fe6aa4207e68",
            "ip": "10.77.77.219",
            "pgUrl": "tcp://postgres@10.77.77.219:5432/postgres",
            "backupUrl": "http://10.77.77.219:12345",
            "id": "10.77.77.219:5432:12345"
          },
          "async": [
            {
              "id": "10.77.77.220:5432:12345",
              "zoneId": "91c91f35-54e7-46b8-aa0c-40bee7f04547",
              "ip": "10.77.77.220",
              "pgUrl": "tcp://postgres@10.77.77.220:5432/postgres",
              "backupUrl": "http://10.77.77.220:12345"
            }
          ],
          "deposed": [],
          "initWal": "6/4A57A2A8"
        }

        $ manatee-adm show        
        zookeeper:   10.77.77.173
        cluster:     3.moray.emy-11.joyent.us
        generation:  1 (6/4A57A2A8)
        mode:        normal
        freeze:      not frozen

        ROLE     PEER     PG   REPL  SENT          FLUSH         REPLAY        LAG   
        primary  c4ea4236 ok   sync  6/4A57A308    6/4A57A308    6/4A57A308    -     
        sync     441eeb0f ok   async 6/4A57A308    6/4A57A308    6/4A57A308    -     
        async    91c91f35 ok   -     -             -             -             -     

You should also check that the vnode(s) you took note of in step 2, when we
created the canary directory, is in the new postgres shard.  You can do that
using this query:

        $ psql moray -c 'select name from manta where _vnode=<vnode_number>;'

The uuid returned from the query should match the one you originally generated
and named the file you mput to manta.

Finally, we'll deploy new morays for the new cluster.  Generate your manta
config via `manta-adm show -sj` on the headnode, copy-paste that into a new
file, then add an entry below your final moray with an identical, incremented
value. It should be very clear what needs to happen, given the structure of
the file.  Then, run `manta-adm update my_config.json` to apply your changes
to update manta.

Note that LevelDB will not intuit the addition of a new moray and therefore will
not update the list of pnodes for the ring accordingly.  (If you use fash to `get vnodes`
it will return the old list.). We will deal with this in the next step.

#### 8. Reshard the vnodes. (Add new pnode(s) to the ring.)

The next step is to use node-fash's remap-vnodes instruction to create a new
hash ring that reflects the desired state of the topology.  You may want to test
that you can remap vnodes both to existing pnodes with room on them, or to a new
pnode.  In this example, and when doubling the space available to a given vnode
topology, we will create and use a new pnode.  This is what we'll be doing:

1.  First, we will download a pristine copy of hash ring from imgapi, because
    we've made changes to the one we've been using that may not be perfectly
    reversible via the node-fash command line tools.  We will pull our ring
    image uuid from SAPI by running this command in our manta deployment zone:

        $ ORIGINAL_HASH_RING_IMAGE_UUID=$(curl -s "$(cat /opt/smartdc/manta-deployment/etc/config.json | json sapi.url)/applications?name=manta&include_master=true" | json -Ha metadata.HASH_RING_IMAGE)

    There are a few variables that you need to make sure are available to you
    before file download will work:

        $ SAPI_URL=$(mdata-get SAPI_URL)
        $ MANTA_APPLICATION=$(curl --connect-timeout 10 -sS -i -H accept:application/json \
            -H content-type:application/json --url "$SAPI_URL/applications?name=manta&include_master=true" | json -Ha)
        # This needs to be an exported variable because the command we use it
        # for will check for the presence of process.env.SDC_IMGADM_URL before
        # defaulting to a nonexistent default value
        $ export SDC_IMGADM_URL=$(echo $MANTA_APPLICATION | json metadata.HASH_RING_IMGAPI_SERVICE)

    Then, in an electric-moray:

        # Make a temporary directory for the pristine ring tarball
        $ mkdir /var/tmp/hash_ring.tar.gz
        # Put the file from imgapi into the temporary directory
        $ /opt/smartdc/electric-moray/node_modules/.bin/sdc-imgadm get-file "$ORIGINAL_HASH_RING_IMAGE_UUID" -o /var/tmp/hash_ring.tar.gz
        # Make a new directory for the hash ring for remapping to live in
        $ mkdir /var/tmp/hash_ring
        # Untar the tarball so that we can use fash on it
        $ tar -xzf /var/tmp/hash_ring.tar.gz -C /var/tmp/hash_ring

2.  We will next run the node-fash remap-vnodes command to move the vnodes we
    want to the new pnode.  This command will create a new LevelDB pnode with
    the key passed from the -p flag if it does not exist already.

        # Check the list of pnodes, which should just be the original ones
        $ fash get-pnodes -l /var/tmp/hash_ring -b leveldb
        # Assign the vnodes to a variable so we can update them all at once
        $ VNODES_FOR_REMAP='0, 106, 943, 689'
        # Remap vnodes to the new pnode, which creates the new pnode in LevelDB
        $ fash remap-vnode -v "$VNODES_FOR_REMAP" -l /var/tmp/hash_ring -b leveldb -p 'tcp://3.moray.emy-11.joyent.us:2020'

3.  Next we will upload the remapped hash topology to imgapi.

    First, generate a uuid for the image, which we will reuse later:

        $ NEW_IMAGE_UUID=$(uuid -v4)
    
    Next, we tar up the new image:

        # You MUST call the tarred-up folder "hash_ring"
        $ /usr/bin/tar -czf /var/tmp/"$NEW_IMAGE_UUID".tar.gz -C /var/tmp hash_ring

    Then we make an image manifest for it, which requires the owner UUID
    environmental variable from your Manta zone:

        $ OWNER_UUID=$(curl -s "$(cat /opt/smartdc/manta-deployment/etc/config.json | json sapi.url)/applications?name=manta&include_master=true"| json -Ha owner_uuid)

    Now, use these variables to create a new ring manifest.  Create a file (for
    example, `/var/tmp/$NEW_IMAGE_UUID.ring.manifest.json`) with the following
    contents:

        cat <<HERE > "/var/tmp/$NEW_IMAGE_UUID.ring.manifest.json"
        {
            "v": 2,
            "uuid": "$NEW_IMAGE_UUID",
            "owner": "$OWNER_UUID",
            "name": "manta-hash-ring",
            "version": "$(date +%Y%m%dT%H%m%SZ)",
            "state": "active",
            "public": false,
            "published_at": "$(node -e 'console.log(new Date().toISOString())')",
            "type": "other",
            "os": "other",
            "files": [
            {
                "sha1": "$(sha1sum /var/tmp/"$NEW_IMAGE_UUID".tar.gz | tr -s ' ' | cut -d ' ' -f1)",
                "size": $(stat -c %s /var/tmp/"$NEW_IMAGE_UUID".tar.gz),
                "compression": "gzip"
            }
            ],
            "description": "Manta Hash Ring"
        }
        HERE

    In order to upload the new ring to imgapi you will have to copy over the new
    image and the manifest file into the headnode.  Using a here document will
    perform the shell expansions that the headnode cannot.  So, copy those files
    over (probably into `/var/tmp`), and finally upload the new ring to imgapi:

        $ sdc-imgadm import -m /var/tmp/"$NEW_IMAGE_UUID".ring.manifest.json -f /var/tmp/"$NEW_IMAGE_UUID".tar.gz

4.  Then we will update SAPI in the headnode, replacing the old `HASH_RING_UUID`
    with the uuid of the new hash ring topology we just uploaded to imgapi.

        $ SAPI_URL=$(cat /opt/smartdc/manta-deployment/etc/config.json | json sapi.url)
        $ MANTA_APPLICATION=$(curl -s "$SAPI_URL/applications?name=manta&include_master=true" | json -Ha uuid)
        $ SDC_IMGADM_URL=$(cat /opt/smartdc/manta-deployment/etc/config.json | json imgapi.url)
        $ curl --connect-timeout 10 -fsS -i -H accept:application/json \
            -H content-type:application/json\
            --url "$SAPI_URL/applications/$MANTA_APPLICATION" \
            -X PUT -d \
            "{ \"action\": \"update\", \"metadata\": { \"HASH_RING_IMAGE\": \"$NEW_IMAGE_UUID\", \"HASH_RING_IMGAPI_SERVICE\": \"$SDC_IMGADM_URL\" } }"

5.  Finally, we will reprovision electric-moray so that its setup script will 
    run, setting up LevelDB the way it is in the new image we just created.

    On the headnode:
    
        $ sdc-vmadm get <your_electric_moray_zone_uuid> | json image_uuid
        $ sapiadm reprovision <your_electric_moray_zone_uuid> <the_image_uuid_you_just_got>

This should end the write block, as the vnodes in the pristine copy of the
topology were never set to read-only mode.  Check that this worked as expected
(that you can see the remapped topology in the correct path in electric-moray
and it responds to fash commands appropriately) and then reprovision any other
electric-moray zones.

#### 9. Re-enable pg dumps.

This ends the block on writes.  Log in to a nameservice zone and run this
command:

        $ zkCli.sh rmr /pg_dump_lock

Then, check if any pg_dumps did not run while zookeeper held your lock.  This
is probable if this process took more than an hour.

At midnight, the dumps will run.  This is the way that the new shard topology
will become visible to Manta, so that metering and GC can pick up these changes.

#### 10. Drop rows from old mappings.

Now we need to clean up data left over from the previous ring topology. Because
we are about to delete data irretrievably, let's take a moment to step back and
review our overall goal with this process, which is to split existing data
between two database shards, one which is left behind on old hardware, and the
other which is moved to new hardware.

As a note, we have no plans at this time to split the administrative shard, and
it is likely that we will house the information to track the automated version
of this process in the administrative shard.  Thus, we do not need to worry
about getting rid of all the tables that house marlin and storage information,
since at this time the split shard will never be the administrative shard.

In step 3, we made new async peers that replicate all data from the original
shard.  This would add 3 more "async" boxes after the async in the diagram from
step 3.

In step 7, we *stopped* the replication process and moved the async peers we
made into new peers on a new pnode -- in other words, in a new shard.

In step 12 (this step), we must clear out the data that each shard is no longer
responsible for.  For the old shard, the rows for the "remapped" vnodes must be
deleted.  For the new shard, the rows for all other vnodes must be deleted. This
achieves the desired end state of this operation, which is to split the metadata
between an old and a new peer, resulting in at least double the amount of free
storage space.

Basically, we are going from this:

          1.moray                  3.moray


       +-----------+     +     +-----------+
       |           |     |     |           |
       | not       |     |     | not       |
       | remapped  |     |     | remapped  |
       | vnodes    |     |     | vnodes    |
       +-----------+     |     +-----------+
       |           |     |     |           |
       | remapped  |     |     | remapped  |
       | vnodes    |     |     | vnodes    |
       |           |     |     |           |
       +-----------+     +     +-----------+

To this:

          1.moray                  3.moray


       +-----------+     +     +-----------+
       |           |     |     |           |
       | not       |     |     |   EMPTY   |
       | remapped  |     |     |           |
       | vnodes    |     |     |           |
       +-----------+     |     +-----------+
       |           |     |     |           |
       |   EMPTY   |     |     | remapped  |
       |           |     |     | vnodes    |
       |           |     |     |           |
       +-----------+     +     +-----------+

Here is the process to delete these rows:

On the original shard's primary peer, run:

        $ sudo -u postgres psql moray -c 'delete from manta where _vnode in (0, 105, 943, 689);'

On the new shard's primary peer, run the inverse of the previous command:

        $ sudo -u postgres psql moray -c 'delete from manta where _vnode not in (0, 105, 943, 689);'

In a production reality, where we are splitting these databases in half, we will
need to construct deletion sql that operates in batches.

This was the final step.  It is a good idea to double-check that all data is
where you think it should be, and then follow up with stakeholders.

### Automation of Resharding

We want to have a tool that can execute each of these steps in the background,
and also report on the status of each of these steps.  It will live in its own 
zone and have access through sdc-manta to manta-adm. 

#### Inputs

1.  The origin server and origin pnode.
2.  The DC setup -- single-DC mode for lab machines or triple-DC mode for
production deployments.
3.  The destination server and pnodes.
4.  For verification that the correct number of servers was given, the number of
destination pnodes to split the data between, i.e. 1 would mean 1 server for a
lab-mode reshard or 3 servers for a production-mode reshard, 2 would mean 2
servers for a lab-mode reshard or 6 servers for a production-mode reshard, etc.

#### Outputs

1.  The complete phase list for the reshard.
2.  The phase list with progress information.
3.  The phase of the process we are currently in.
4.  Lock state (i.e. pg_dump_lock, vnode_remap_lock, what shards are in a
read-only "write locked" state).
5.  Time spent thus far in each phase.

#### Code changes pending

1.  Create a resharding Manta service zone.
2.  Turn manta-adm and manta-oneach into NPM modules.
3.  Add support for read-only pnode state that will obviate the need for fash's
'ro' setting and possibly the add-data command in its entirety (step 3) -- this
will potentially include an API on electric-moray to manage the hash ring.
4.  Split out the LevelDB setup from electric-moray's `setup.sh` so that we can
reboot the electric-moray zone rather than needing to provision it after
updating SAPI metadata.
5.  Create code to speak to APIs in DCs that are not where the reshard zone is.
6.  Automate dump lock management via node-zkstream.
7.  Automate reliable clean up (deletion) of the data from each side of the
split without impacting service.
8.  Expose the state of the resharding via a CLI.