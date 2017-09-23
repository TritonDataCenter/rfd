---
authors: Brittany Wald <brittany.wald@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+103%22
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

It is not always possible to know ahead of time how quickly or large a
given Manta deployment will grow.  It is also not possible to perfectly
predict object size and extrapolate growth of the metadata tier from that.
For this reason, it is necessary for us to be able to arbitrarily scale
our metadata tier, so that we can reference however many new objects are
being created.  The process for doing this, which is called resharding,
has been documented in the past, here:

https://github.com/joyent/manatee/blob/3771c6fbd979ad41e7a71b19f9e2b7ff99542134/docs/resharding.md

However, this documentation has become outdated, and it is not possible that
it was thoroughly tested at a scale comparable to our current operation.

This RFD will restate many of the concepts in the manual resharding guide
referenced above, and will use some of the same examples, when appropriate.
This is because the scope of this document will likely expand to include
plans for an automated solution to this problem, and it will be helpful to
update and restate any goals and changes to this implementation in one place
with all available context.

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
performed multiple times.

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

#### 3. Set up a new async peer.

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

Back on the headnode, we can use `manta-adm show -sj` to generate a JSON file of
our current Manta configuration:

        manta-adm show -sj > my_config.json

Open `my_config.json` and increment the value of the key that matches the
postgres instance you are resharding.  Then, run `manta-adm update my_config.json`
to apply your changes.  If you return to your postgres zone now and run `manatee-adm show`
again, you should now see a second async peer trying to catch up.  You can run `manatee-adm pg-status 1`
to view the running process.  This WLSLT:

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

It is a good idea to use manta-mlive to generate some load that you can watch if
you are doing this in a test environment.  The important numbers to watch are
the primary's SENT and the first async's REPLAY.  When they are close together
(at least the first 4 digits are the same) then the async shard is sufficiently
caught up for us to reshard. We can also look at the LAG -- it is a good sign
when it is `-` for the primary and a small number for the other roles.

#### 4. Put the vnodes you want to reshard into read-only mode.

The vnode-to-pnode mapping is stored within four duplicate LevelDB directories
stored in the electric-moray zone at `/electric-moray/chash/leveldb-202{1-4}`.
LevelDB only allows one process to access each db directory at once, this is why
we have four.  Usually, electric-moray holds the lock for the db, and you can
check this with `svcs -p *electric-moray*`.  We can use `svcadm` to disable any
of those processes in order to operate on the LevelDB topology directly.
Otherwise, we will not be able to run any commands on the LevelDB -- not even to
read data out.

However, whatever we do to one LevelDB, we must do to all four in order to
maintain consistency.  We can do these one at a time, which will result -- in a 
4-process, one electric-moray setup -- in a 25% miss rate for reads and writes
from Manta.  To mitigate this, we can go through this process one LevelDB at a
time.  This may sacrifice consistency, and will need more testing.

Erring on the side of consistency over availability, we will disable all four
electric-moray-leveldb processes before making changes to the data mapping of
its associated LevelDB.  However, we only need to change one LevelDB topology in
order to generate a new hash ring image to upload to electric-moray. We will
operate on electric-moray-2021 for this procedure.

        $ svcadm disable electric-moray-2021

Next we're going to use the node-fash cli to set the vnodes we care about to
read-only.  If we try to write to them while moving them we will lose data.

        # Display information, such as which shard this vnode is on
        $ /opt/smartdc/electric-moray/node_modules/fash/bin/fash.js get-vnode-pnode-and-data -v '<your_vnode_number(s)>' -l /electric-moray/chash/leveldb-2021/
        # Put the vnode into read-only mode
        $ /opt/smartdc/electric-moray/node_modules/fash/bin/fash.js add-data -v '<your_vnode_number(s)>' -l /electric-moray/chash/leveldb-2021/ -b leveldb -d 'ro'

The -d flag in node-fash is destructive -- it will overwrite whatever data
previously occupied the value on that key.  To start out, every key's value
defaults to 1.  By setting the field to 'ro', we are telling electric-moray not
to send writes to this vnode.  This puts this topology into a dirty state, which
is why we will not be uploading this topology into electric moray. The purpose
of this step is merely to enter a write-lock so that when we are in the process
of moving the remapped topology between peers, we will not end up with data lost
because it was written during the moving process.  Once you have performed this
operation on all 4 LevelDBs, make sure to give electric-moray back the lock:

        $ svcadm enable electric-moray-2021

#### 5. Take a lock to prevent pg dumps.

An ongoing pg dump will interfere with the resharding process, so we need to
make sure that one is not happening during this time. This command will need to
be run from any nameservice (zookeeper) zone in order to create a lock:

        $ zkCli.sh create /pg_dump_lock whatever_you_want_to_call_the_lock

Check that you successfully created the lock:

        $ zkCli.sh get /pg_dump_lock

You should see the name of your lock at the top of the output.  This is a coarse
lock -- Manatee will just check for the presence of a dump lock file and stop
all dumps when it sees one.

#### 6. Make sure Manatee dumps are not running.

Log in to the postgres zone for the new shard you created in step 3, and run:

        $ ptree | grep pg_dump.sh

If anything is running, wait until it is finished (or kill it) before moving to
the next step.

#### 7. Move the new Manatee peer into the new shard.

This requires changes to SAPI metadata and rebooting the node to pick up the
changes.  In this step, <zone_uuid> always refers to the zone of the new async
peer we created in step 3.  First, we will have to disable the manatee-sitter:

        $ svcadm disable manatee-sitter

Next, we have to update the SAPI metadata for the zone to add it to the new
shard:

        $ sapiadm update <zone_uuid> metadata.SERVICE_NAME="3.moray.joyent.us"
        $ sapiadm update <zone_uuid> metadata.SHARD=3
        $ sapiadm update <zone_uuid> metadata.MANATEE_SHARD_PATH='/manatee/3.moray.joyent.us'

We will also need to update the alias parameter in the VM, by reprovisioning the
zone with sapiadm, since the alias of the vm is is a first-class property used
to create it, and contains the cluster name.  This will also reboot the zone to
pick up the metadata changes.

        # Update vmapi
        $ sdc-vmapi /vms/<zone_uuid>?action=update -X POST -d '{"alias":"3.postgres.emy-11.joyent.us-<zone_uuid_first_bit_before_hyphen>"}'
        # For consistency, but won't affect cluster state
        $ sapiadm update <zone_uuid> params.alias=3.postgres.emy-11.joyent.us-<zone_uuid_first_bit_before_hyphen>
        # Reboot the zone and pick up changes
        $ sapiadm reprovision <zone_uuid> <image_uuid>

At this point, if you run `manta-adm show -sj` you will see that the postgres
zone entries have changed -- there is now another group that contains just one
instance.  If you log in to the postgres zone and try manatee-adm show:

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

https://github.com/joyent/manatee-state-machine/blob/a4d6b51355d69f0bed40bf295f31a7fb7f772f84/lib/manatee-peer.js#L445
https://github.com/joyent/manatee-state-machine/blob/a4d6b51355d69f0bed40bf295f31a7fb7f772f84/lib/manatee-peer.js#L454

Currently, when we bring up a new shard toplogy, the election is is pre-assigned
to zookeeper.  Meaning, we have already decided which node is the primary, which
is the sync, etc.  This is to prevent race conditions and other problems that
occured in the original iteration of manatee.  We can reference this document
for futher details:

https://github.com/joyent/manatee/blob/34238c257d3cb6fe7eba247c7e40a1dd49c4f3e8/docs/migrate-1-to-2.md

The relevant part of this for our purposes is this: since we are starting out
with only a single node that has data on it, we are going to be in a state from
a data perspective, as we bring up nodes, that is a similar to the "legacy"
mode referenced below:

https://github.com/joyent/manatee/blob/34238c257d3cb6fe7eba247c7e40a1dd49c4f3e8/lib/adm.js#L209

In this mode, the first zone created became the primary.  So, in that older
version of manatee, there would be pre-existing data on the primary that would
then move over to the sync and async.  However, when we bring up a new cluster
today, manatee normally expects that there is no preexisting data in the
cluster.  This means we will need to backfill data from our new primary into the
the other two nodes.  If you get into a bad state at some point while doing
this, this document can help you find your way out:                            
                                                                                
https://github.com/joyent/manatee/blob/3771c6fbd979ad41e7a71b19f9e2b7ff99542134/docs/trouble-shooting.md

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

Also check that state information now exists in zookeeper (and is correct).

        $ zkCli.sh
        # Read the zk state
        (inside zkCli)$ get /manatee/3.moray.emy-11.joyent.us/state

Double-check that the primary is the original shard that you split off, and you
can also run some test sql in the postgres zones to make sure that data ended up
in the new cluster.

If everything looks correct, we can move on.  That WLSLT:

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

You should also check that the vnode you took note of in step 2, when we created
a canary directory, is in the new postgres shard.  You can do that using this
query:

        $ psql moray -c 'select name from manta where _vnode=<vnode_number>;'

The uuid returned from the query should match the one you originally generated
and named the file you mput to manta.

Finally, we'll deploy new morays for the new cluster.  Generate your manta
config via `manta-adm show -sj` on the headnode, copy-paste that into a new
file, then add an entry below your final moray with an identical, incremented
value. It should be very clear what needs to happen, given the structure of
the file.  Then, run `manta-adm update {name of your new file}` to apply your
changes (from now on I'm just going to say 'update manta' and assume you know
what to do).

Note that LevelDB will not intuit the addition of a new moray and therefore will
not update the list of pnodes for the ring accordingly.  We will deal with this
in the next step.

#### 8. Reshard the vnodes. (Add new pnode(s) to the ring.)

The next step is to use node-fash's remap-vnodes instruction to create a new
hash ring that reflects the desired state of the topology.  Before doing this,
it is probably a good idea to copy the current topology to a new folder in case
you need the original.  Note that you may want to test that you can remap vnodes
both to existing pnodes with room on them, or to a new pnode.  In this example,
and when doubling the space available to a given vnode topology, we will create
and use a new pnode.  This is the heart of the process, and is actually more
like 5 mini-steps than one.  This is what we'll be doing:

1.  First, we will download a pristine copy of hash ring from imgapi, because
    we've made changes to the one we've been using that may not be perfectly
    reversible via the node-fash command line tools.  We will pull our ring
    image from SAPI by running this command in our manta deployment zone:

        $ curl -s "$(cat /opt/smartdc/manta-deployment/etc/config.json | json sapi.url)/applications?name=manta&include_master=true" | json -Ha metadata.HASH_RING_IMAGE

    Next, use the upload image tool to get put this image into electric-moray in
    a directory at `/var/tmp` -- we do not want this hash ring to be in use yet,
    the old one, with read-only vnodes marked, should still be the one
    electric-moray uses for the time being:

        $ WIP: MANTA-3388

2.  We will next run the node-fash remap-vnodes command to move the vnodes we
    want to the new pnode.  This command will create a new LevelDB pnode with
    the key passed from the -p flag if it does not exist already.

        $ /opt/smartdc/electric-moray/node_modules/fash/bin/fash.js remap-vnodes -v '0, 106, 943, 689' -l /var/tmp/hash_ring -b leveldb -p 'new.pnode'

3.  Next we will upload the remapped hash topology to imgapi.

    First, generate a uuid for the image, which we will reuse later:

        $ NEW_IMAGE_UUID=$(uuid -v4)
    
    Next, we tar up the new image:

        $ /usr/bin/tar -czf /var/tmp/($NEW_IMAGE_UUID).ring.tar.gz -C /var/tmp/hash_ring

    Then we make an image manifest for it, which requires the owner UUID
    environmental variable from your manta zone:

        $ OWNER_UUID=$(curl -s "$(cat /opt/smartdc/manta-deployment/etc/config.json | json sapi.url)/applications?name=manta&include_master=true"| json -Ha owner_uuid)

    Now, use these variables to create a new ring manifest.  Create a file (for
    example, `/var/tmp/$NEW_IMAGE_UUID.ring.manifest.json`) with the following
    contents:

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
                    "sha1": "$(sha1sum $RING_IMAGE | tr -s ' '| cut -d ' ' -f1)",
                    "size": $(stat -c %s $RING_IMAGE),
                    "compression": "gzip"
                }
                ],
                "description": "Manta Hash Ring"
            }

    And finally, upload the new ring to imgapi:

        $ sdc-imgadm import -m /var/tmp/($NEW_IMAGE_UUID).ring.manifest.json -f /var/tmp/($NEW_IMAGE_UUID).ring.tar.gz

4.  Then we will update SAPI, replacing the old HASH_RING_UUID with the uuid of
    the new hash ring topology we just uploaded to imgapi.

        $ SAPI_URL=$(cat /opt/smartdc/manta-deployment/etc/config.json | json sapi.url)
        $ MANTA_APPLICATION=$(curl -s "$SAPI_URL/applications?name=manta&include_master=true" | json -Ha uuid)
        $ SDC_IMGADM_URL=$(cat /opt/smartdc/manta-deployment/etc/config.json | json imgapi.url)
        $ curl --connect-timeout 10 -fsS -i -H accept:application/json \
            -H content-type:application/json\
            --url "$SAPI_URL/applications/$MANTA_APPLICATION" \
            -X PUT -d \
            "{ \"action\": \"update\", \"metadata\": { \"HASH_RING_IMAGE\": \"$NEW_IMAGE_UUID\", \"HASH_RING_IMGAPI_SERVICE\": \"$SDC_IMGADM_URL\" } }"

5.  Finally, we will download the new sapi manifest into electric-moray.

    On the headnode:
    
        $ sdc-vmadm get <your_electric_moray_zone_uuid> | json image_uuid
        $ sapiadm reprovision <your_electric_moray_zone_uuid> <the_image_uuid_you_just_got>

        OR

        $ WIP: MANTA-3388

This should end the write block, as the vnodes in the pristine copy of the
topology were never set to read-only mode.

#### 9. Verify changes.

This is where the canary directory we made in step 3 becomes useful.  We're
going to try to write to the file that should now be in write mode and on the
new shard, not the old one.

        $ ./bin/mput /poseidon/stor/re-shard-canary-dir/2178ed56-ed9b-11e2-8370-d70455cbcdc2 -f change.txt

NOTE: I'm not so sure about the effectiveness of the test below.

Check that the `_id` field increments on the new shard rather than the old one.
You can see this if you run this query on the primaries of the old and the new
shard and make sure that the `_id` field is larger on the new shard:

        $ psql moray -c 'select _id from manta where _key = /<user_uuid>/stor/re-shard-canary-dir/2178ed56-ed9b-11e2-8370-d70455cbcdc2/;

#### 10. Upload the new shard topology into Manta.

NOTE: It is at this time unclear if this is still something that needs to be
done, and is not just automatic when SAPI is updated.  The purpose of this is 
so that metering and GC can pick up these changes.

#### 11. Re-enable pg dumps.

This ends the block on writes.  Log in to a nameservice zone and run this
command:

        $ zkCli.sh rmr /pg_dump_lock

Then, check if any pg_dumps did not run while zookeeper held your lock.  This
is probable if this process took more than an hour.

#### 12. Drop rows from old mappings.

Now we need to clean up data left over from the previous shard relation. Because
we are about to delete data irretrievably, let's take a moment to step back and
review our overall goal with this process, which is to split existing data
between two database shards, one which is left behind on old hardware, and the
other which is moved to new hardware.  We will also need to get rid of all the
tables that housed marlin and storage information, if the split shard was the
administrative shard.

In step 3, we made a new async peer that needed to replicate all data from the
original shard.  This diagram is simplified.  Instead of showing the real
3-shard setup with a primary, sync, and async, to which we add a second async,
I'm going to show only the primary on the left and the second async on the
right, skipping the sync and first async for simplicity.  `1.moray` and `2.moray`
are abbreviations for "data that was stored on x.moray".


         PRIMARY                 2ND ASYNC


       +-----------+           +-----------+
       |           |           |           |
       | 1.moray   |           |  1.moray  |
       |           |           |           |
       |           | replicate |           |
       +-----------+  +----->  +-----------+
       |           |           |           |
       | 2.moray   |           |  2.moray  |
       |           |           |           |
       |           |           |           |
       +-----------+           +-----------+


In step 7, we stopped the replication process and moved the async peer we made
into the new peer on the new pnode.  Note that there are now two peers, and the
shard which was previously the fourth in the pipeline to receive data
replication is now the primary in a new peer.


         PRIMARY               ANOTHER PRIMARY


       +-----------+     +     +-----------+
       |           |     |     |           |
       | 1.moray   |     |     |  1.moray  |
       |           |     |     |           |
       |           |     |     |           |
       +-----------+     |     +-----------+
       |           |     |     |           |
       | 2.moray   |     |     |  2.moray  |
       |           |     |     |           |
       |           |     |     |           |
       +-----------+     +     +-----------+


In step 12 (this step) we must clear out the data that each shard is no longer
responsible for.  This will achieve the desired end state of this operation,
which is to split the metadata between an old and a new peer, freeing space on
both.


         PRIMARY               ANOTHER PRIMARY


       +-----------+     +     +-----------+
       |           |     |     |           |
       | 1.moray   |     |     |           |
       |           |     |     |           |
       |           |     |     |           |
       +-----------+     |     +-----------+
       |           |     |     |           |
       |           |     |     |  2.moray  |
       |           |     |     |           |
       |           |     |     |           |
       +-----------+     +     +-----------+


Now that we have a good picture in mind of what we are doing conceptually, we
can run the commands to perform this cleanup.

On shard 1, run:

        $ sudo -u postgres psql moray -c 'delete from manta where _vnode in (0, 105, 943, 689)'

And on shard 2, run its inverse:

        $ sudo -u postgres psql moray -c 'delete from manta where _vnode not in (0, 105, 943, 689)'

This was the final step.  It is probably a good idea to double-check that all
the data is where you think it should be, and then follow up with stakeholders.

### Automation of Resharding

The most critical section of this process to automate is the period where
writes are blocked (steps 4-8).  This time interval must be reported to
stakeholders before performing the resharding process, and optimized as much as
possible.  A script in the sdc-manta repo is in-progress, which implies that
this operation will be run from the manta zone.  There has been some discussion
of running it from the ops zone, but we do not have all the necessary
components in that zone today, such as node-fash, and it is not yet clear at
the time of writing how trivial it would be to add them all.
