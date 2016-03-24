---
authors: Angela Fong <angela.fong@joyent.com>, Casey Bisson <casey.bisson@joyent.com>, Jerry Jelinek <jerry@joyent.com>, Josh Wilsdon <jwilsdon@joyent.com>, Julien Gilli <julien.gilli@joyent.com>, Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 26 Network Shared Storage for SDC

## Introduction

In general, support for network shared storage is antithetical to the SDC
philosophy. However, for some customers and applications it is a requirement.
In particular, network shared storage is needed to support Docker volumes in
configurations where the Triton zones are deployed on different compute nodes.

## Use cases

The stories in this section have been gathered from Triton users. The UGC
(User Generated Content) story is genericized because it's been described by
many people as something they need. The video conferencing story is more
specific because it’s a one-off so far. The names, of course, are fictional.

### Storing user generated content for a CMS application

Danica runs WordPress, Drupal, Ghost, or some other tool that expects a local
filesystem that stores user generated content (UGC). These are typically
images, but are not limited to it. The size of these filesystems is typically
hundreds of megabytes to hundreds of gigabytes (a 1TB per volume limit would
likely be very acceptable).

When Danica builds a new version of her app, she builds an image (can be
Docker or infrastructure container) with the application code, runtime
environment, and other non-UG content. She tests the image with a sample set
of content, but needs to bring the UGC into the image in some way when
deploying it.

In production, Danica needs to run multiple instances of her app on different
physical compute nodes for availability and performance, and each instance
needs access to a shared filesystem that includes the UGC and persists across
application deploys.

The application supports some manipulation of the UG content (example: an
image editor for cropping), but the most common use for the content is to
serve it out on the internet. The result is that filesystem performance is not
critical to the app or user experience.

Though the UGC is stored on devices that offer RAID protection, Danica further
protects against loss of UG content by making regular backups that she does as
nightly tarballs stored in other infrastructure. She often uses those backups
in her development workflow as a way to get real content and practice the
restore procedures for them.

Danica can’t use an object store for the UGC because there’s no plugin for it
in her app, or no plugin that supports Manta, or she depends on features that
are incompatible with object storage plugins, or she’s running the app on-prem
and can’t send the data to an off-site object store (and she doesn’t have the
interest or budget to run Manta on prem).

Danica does not yet run her application across multiple data centers, but
she’d love to do so as a way to ensure availability of her site in the case of
a data center failure and so to improve performance by directing requests to
the closest DC.

### Recording calls for a video conferencing application

Vinod is building a video conferencing app that allows the optional recording
of conversations. The app component that manages individual conferences is
ephemeral with the exception of the recordings. The recordings are spooled to
disk as the conversation progresses, then the file is closed and enters a task
queue for further processing. Because the recordings can become quite large,
and because the job queue is easier to design if the recordings are on a
shared filesystem, Vinod has chosen to build his application with that
expectation. The recordings don’t stay in the shared filesystem indefinitely,
but workers in the queue compress and move them to an object store
asynchronously to the conversation activity.

Conversation recordings are typically in the low hundreds of gigabytes, and
performance requirements for any single conversation are limited by the bit
rates for internet video. Vinod currently uses a single filesystem, but
expects to add additional filesystems if necessary for performance. By running
the application in multiple data centers, each with its own set of conference
manager instances, shared filesystems, and work queues, Vinod’s app can remain
available despite the loss of individual data centers or shared filesystems,
though users would have to restart any conference calls that were interrupted
by that failure.

Vinod has chosen not to push the recordings into an object store immediately
because doing so would require larger in-instance storage for the video than
is available in all but the most expensive Triton packages, because adding
support for chunked uploads to the app that is managing the conversation is a
big expansion of scope for that component, and because the current process
works and makes sense to him.

## General scope

### Requirements

1. The solution must work for both on-prem SDC users and Triton.

2. A shared volume size must be expandable (i.e. not a fixed quota size at
creation time).

3. Support a maximum shared file system size of 1TB.

4. Although initially targeted toward Docker volume support, the solution should
be applicable to non-Docker containers as well.

### Non-requirements

1. Shared volumes do not need to be available across data centers.

2. High performance is not critical.

3. Dedicated storage server (or servers) hardware is not necessary.

4. Robust concurrent read-write access (e.g. as used by a database) is not
necessary.

## CLI

The `triton` CLI currently doesn't support the concept of (shared) volumes, so
new commands and options will need to be added.

The docker CLI already supports shared volumes, but some conventions will need
to be established to allow Triton users to pass triton-specific input to SDC's
Docker API.

### Triton

#### Overview

```
triton volumes
triton volume create|list|get|delete

triton volume create --opt network=mynetwork --name wp-uploads --size 100g
triton volume create -n wp-uploads -s 100g
```

#### Create

```
triton volume create --opt network=mynetwork --name wp-uploads --size 100g -e affinity:container!=wp-server
```

##### Options

###### Size

The size of the shared volume. Matched with the closest available shared
volume package.

###### Network

The network to which this shared volume will be attached.

###### Affinity (not necessarily in MVP)

See [Expressing locality with affinity filters](FIXME) below.

#### List

```
$ triton volume create -n foo ...
$ triton volume list
NAME  SIZE  NETWORK             RESOURCE
foo   100g  My Default Network  nfs://10.0.0.1/foo # nfs://host[:port]/pathname
$
```

#### Get

```
$ triton volume get volume-name
{ id: ... name: ... size: ... network: ... resource: ... compute_node: ... }
```

Including the amount of space used/amount of space available is a nice to
have. It might be possible to use the upcoming container monitoring service to
have quick metrics cache for a VM available and add that to the 'metrics'
field in cloudapi.

#### Delete

```
$ triton volume rm volume-name
```

This command _fails_ if docker containers are using the volume to be deleted,
but not if only non-Docker containers use it. In the latter case, it is the
responsibility the shared volume's owner to determine whenever it is
appropriate to delete it without impacting other compute containers.

#### Adding a new `triton report` command

Creating a shared volume results in creating a VM object and an instance with
`container_type: 'volume'`. As such, a user could list all their "resources"
(including instances _and_ shared volumes) by listing instances.

However, the fact that shared volumes have a 1 to 1 relationship with their
underlying containers is an implementation detail that should not be publicly
exposed.

Shared volumes should instead be considered as a separate resource type and a
new `triton report` command could list all resources of any type for a given
user, including:

* actual compute instances.
* NAT zones.
* shared volumes zones.

### Docker

The Docker CLI [already has support for
volumes](https://docs.docker.com/engine/reference/commandline/volume_create/).
This section describes what commands and command line options will be used by
Triton users to manage their shared volumes on Triton.

#### Overview

```
docker network create mynetwork ...
docker volume create --driver tritonnfs --name wp-uploads \
    --opt size=100g --opt network=mynetwork
docker run -d -v wp-uploads:/var/wp-uploads wp-server
```

The `tritonnfs` driver is the default driver on Triton. If not specified, the
network to which a newly created volume is attached is the default nic. So
more typically, creating a shared volume can be done using the following
shorter command line:

```
docker volume create --name wp-uploads --opt size=100g
```

#### Create

##### Options

###### Size

The size of the shared volume. Matched with the closest available shared
volume package. This option is passed using docker's CLI's `--opt` command
line switch:

```
docker volume create --name --opt size=100g
```

###### Network

The network to which this shared volume will be attached. This option is
passed using docker's CLI's `--opt` command line switch:

```
docker volume create --name --opt network=mynetwork
```

###### Driver

The Triton shared volume driver is named `tritonnfs`. It is the default driver
when creating shared volumes when using Triton's Docker API with the docker
client.

#### Run

Users need to be able to mount shared volumes in read-only mode using the
`:ro` command line suffix for the `-v` option:

```
docker run -d -v wp-uploads:/var/wp-uploads:ro wp-server
```

## Shared storage implementation

For reliability reasons, compute nodes never use network block storage and SDC
zones are rarely configured with any additional devices. Thus, shared block
storage is not an option.

Shared file systems are a natural fit for zones and SmartOS has good support
for network file systems. A network file system also aligns with the semantics
for a Docker volume. Thus, this is the chosen approach. NFS is used as the
underlying protocol. This provides excellent interoperability among various
client and server configurations. Using NFS even provides for the possibility
of sharing volumes between zones and kvm-based services.

### Non-Requirements

1. The NFS server does not need to be HA.
2. Dedicated NFS server (or servers) hardware is not necessary.
3. Robust locking for concurrent read-write access (e.g. as used by a
    database) is not necessary.

### Approach

Because the file system(s) must be served on the customer's VXLAN, it makes
sense to provision an NFS server zone, similar to the NAT zone, which is owned
by the customer and configured on their VXLAN. Container zones can only talk
to NFS server zones that are on the same customer's network.

The current design has a one-to-one mapping between shared volumes and NFS
server zones, but this is an implementation detail: it is not impossible that
in the future more than one volumes be served from one NFS server zone.

Serving NFS from within a zone is not currently supported by SmartOS, although
we have reason to believe that we could fix this in the future. Instead, a
user-mode NFS server will be deployed within the zone. Because the server runs
as a user-level process, it will be subject to all of the normal resource
controls that are applicable to any zone. The user-mode solution can be
deployed without the need for a new platform or a CN reboot.

The NFS server will serve files out of a ZFS delegated dataset, which allow
for the following use cases:

1. Upgrading the NFS server zone (e.g to upgrade the NFS server software) without
needing to throw away users' data.

2. Snapshotting.

3. Using ZFS send to send users' data to a different host.

The user-mode server must be installed in the zone and configured to export
the appropriate file system. The Triton docker tools must support the mapping
of the user's logical volume name to the zone name and share.

When a Docker container uses a shared volume, the NFS file system is mounted
in the container from the shared volume zone automatically at startup.
However, when a non-Docker container uses a shared volume, mounting of the NFS
file system is not automatic: users need to use command line tools to mount it
manually using the appropriate NFS path.

### Other Considerations

#### Differences between compute containers and shared volumes containers

1. Users cannot ssh into shared volume containers.

2. Users cannot list shared volume containers when listing compute instances
(they can list them using CloudAPI's /volumes endpoint).

#### Kernel vs user-mode NFS server

The user-mode NFS server is a solution that provides for quick implementation
but may not offer the best performance. In the future we could do the work
to enable kernel-based NFS servers within zones. Switching over to that
should be transparent to all clients, but would require a new platform on the
server side.

#### High availability

Although HA is not a requirement, an NFS server zone clearly represents a SPOF
for the application. There are various possibilities we could consider to
improve the availability of the NFS service for a specific customer. These
ideas are not discussed here but could be considered as future projects.

#### Manta integration

Integration with Manta is not discussed here. However, we do have our manta-nfs
server and it dovetails neatly with the proposed approach. Integrating
manta access into an NFS server zone could be considered as a future project.

#### Choice of hardware

Hardware configurations that are optimized for use as NFS servers are not
discussed here. It is likely that a parallel effort will be needed to
identify and recommend server hardware that is more appropriate than our
current configurations.

#### Concurrent access

Concurrent access use cases need to be supported, but support for robust high
concurrency ones (such as database storage) is not critical.

## Allocation (DAPI, packages, etc.)

### Packages for volume containers

Somewhat like for NAT zones, in that we'll have separate packages for these.
However, a couple hurdles:

  * These volume containers will be owned by the account (unlike nat zones), can
we still have the packages private to the 'admin' user?

  * We'll need a range of packages for sizing. Will we need quite a lot to not
force the user to a large gap? Do we want to expose those sizes to the user?
I.e. how does the user know that we don't have any disk sizes between 64G and
128G, for example.

#### Packages size

Each volume would have a minimum size of 10GB, and support resizing in units
of 10GB and then 100GB as the volume size increases:

* 10GB
* 20GB
* 30GB
* 40GB
* 50GB
* 60GB
* 70GB
* 80GB
* 90GB
* 100GB
* 200GB
* 300GB
* 400GB
* 500GB
* 600GB
* 700GB
* 800GB
* 900GB
* 1,000GB

### Placement of volume containers

The placement of the NFS server zone during provisioning is a complicated
decision. There is no requirement for dedicated hardware that is optimized as
file servers. The server zones could be interspersed with other zones to soak
up unused storage space on compute nodes. However, care must be taken so that
the server zones have enough free local storage space to expand into.

Provisioning of regular zones should also take into account the presence
storage zones and any future growth they might incur. It is likely we'll have
to experiment with various approaches to provisioning in order to come up with
an acceptable solution. The provisioning design is TBD.

#### Mixing compute containers and volume containers

#### Expressing locality with affinity filters

_This functionality is not required for the MVP._

In order to have better control on performance and availability, Triton users
need to be able to express where in the data center their shared volumes are
located in relation with their compute containers.

For instance, a user might need to place a shared volume on a compute node
that is as close as possible than the compute containers that use them.

The same user might need to place another shared volume on a different
computer node than the compute containers that use them to avoid a single
point of failure.

Finally, the same user might need to place several different or identical
shared volumes on different compute nodes to avoid a single point of failure.

These locality constraints are expressed in terms of relative affinity between
shared volumes and compute containers.

Affinity filters are [already supported by the docker
CLI](https://docs.docker.com/swarm/scheduler/filter/#use-an-affinity-filter).
Triton users should be able to express affinity using:

* partial names
* labels

and the following operators:

* `==`:
* `!=`:
* `~=`:

## REST APIs

Several existing APIs are directly involved when manipulating shared volumes:
sdc-docker, VMAPI, CloudAPI, NAPI, etc. . This section presents the changes
that will need to be made to existing APIs as well as new APIs that will need
to be created to support shared volumes and their use cases.

### Changes to existing APIs

#### CloudAPI

##### New `/volumes` endpoints

Users need to be able to manage their shared volumes from CloudAPI.

###### ListVolumes

###### CreateVolume

###### GetVolume

###### DeleteVolume

##### Filtering shared volumes zones from the ListMachines endpoint

Zones acting as shared volumes host need to not be included in `ListMachines`
output.

#### VMAPI

##### Filtering shared volumes zones from list endpoint

Zones activing as shared volumes hosts need to be filtered out from the
`ListVms` endpoint.

##### New `container_type` property on VM objects

A `container_type` property with the values `docker | zone | kvm | volume |
nat` will need to be added on VM objects.

This overlaps with the existing `docker` property. The intention is to keep
both properties at first, and to migrate existing VMAPI clients that use the
`docker` property to use the new `container_type` property. When all clients
are migrated, then the `docker` could potentially be deprecated and finally
removed.

##### Naming of shared volumes zones

Shared volumes names are __unique per account__. Thus, in order to be able to
easily identify and search for shared volume zones without getting conflicts
on VM aliases, shared volume zones' aliases will have the following form:

```
alias='volume-$volumename-$volumeuuid'
```

### Adding a new `VAPI` service and API

Even though shared volumes are implemented as actual zones in a way similar to
regular instances, they represent an entirely different concept with different
constraints, requirements and life cycle. As such, they need to be represented
in SDC as different "Volume" objects.

The creation, modification and deletion of these "Volume" objects could
_technically_ be managed by VMAPI, but it would defeat the principle of having
a separate API/service for managing objects that are loosely coupled together.

As a result, this section proposes to add a new API/service named "Volume API"
or "VAPI".

#### Main VAPI endpoints

##### ListVolumes GET /volumes

##### GetVolume GET /volumes/volume-uuid

##### CreateVolume POST /volumes

##### DeleteVolume DELETE /volumes/volume-uuid

Deletion of a shared volume is not allowed if at least one _Docker_ container
uses it. This will result in an error and a 409 HTTP response. This is in line
with Docker's API's documentation about deleting volumes.

However, a shared volume can be deleted if only non-Docker containers use it,
because there's currently no clean way to determine if a non-Docker container
uses a shared volume.

##### SnapshotVolume POST /volumes/volume-uuid

#### Volume objects

Volumes will be represented as separate objects in their own moray bucket as
follows:

```
{
  "owner_uuid": "some-uuid",
  "name": "foo",
  "size": "100000", // in MBs
  "resource_path": "nfs://host:port/path",
  "vm_uuid": "some-vm-uuid",
}
```

###### Naming constraints

Volume names need to be __unique per account__. As indicated in the "Shared
storage implementation" section, several volumes might be on the same zone at
some point.

## Snapshots

### Use case

Triton users need to be able to snapshot the content of their shared volumes,
and roll back to any of these snapshots at any time. The typical use case that
needs to be supported is a user who needs to be able to make changes to the
data in a shared volume while being able to roll back to a known snapshot.
Snapshot backups are out of scope.

### Implementation

Shared volumes' user data are stored in a delegated dataset. This gives the
nice property of being able to update the underlying zone's software (such as
the NFS server) without having to recreate the shared volume.

Snapshotting a shared volume involves snapshotting only the delegated dataset
that contains the actual user data, not the whole root filesystem of the
underlying zone.

Snapshotting a shared volume is done by using VAPI's `SnapshotVolume`
endpoint. Creating a snapshot can fail as no space might be left in the
corresponding zfs dataset.

#### Limits

As snapshots consume storage space even if no file is present in the delegated
dataset, limiting the number of snapshots that a user can create may be
needed. This limit could be implemented at various levels:

* In the Shared Volume API (VAPI): VAPI could maintain a count of how many
snapshots of a given volume exist and a maximum number of snapshots, and send
a request error right away without even reaching the compute node to try and
create a new snapshot.

* At the zfs level: snapshotting operation results would bubble up to VAPI,
which would result in a request error in case of a failure.

## Support for operating shared volumes

Shared volumes are hosted on zones that need to be operated in a way similar
than other user-owned containers. Operators need to be able to migrate, stop,
restart, upgrade them, etc.

### `sdcadm` changes

SDC operators need to be able to perform new operations using new `sdcadm`
commands and options.

#### Listing shared volume zones

* Listing all shared volume zones:
```
sdcadm shared-volumes list
```

* Listing all shared volume zones for a given user:
```
sdcadm shared-volumes list owner-uuid
```

#### Restarting shared volume zones

Shared volumes owner by a given user, or with a specific uuid, can be
restarted. Specifying both an owner and a shared volume uuid checks that the
shared volume is actually owned by the owner.

```
sdcadm shared-volumes restart [--owner owner-uuid] [--volume shared-volume-uuid] [shared-volumes@uuid]
```

If Docker containers use the shared volumes that need to be restarted,
`sdcadm` doesn't restart the shared volume zones and instead outputs the
containers' uuids so that the operator knows which containers are still using
them.

#### Updating shared volume zones

Shared volume zones can be updated to the latest version, or any specific
version, for a specific user or for a specific shared volume. Specifying both
an owner and a shared volume uuid checks that the shared volume is actually
owned by the owner.

```
sdcadm shared-volumes update [--owner owner-uuid] [--volume shared-volume-uuid] [shared-volumes@uuid]
```

If Docker containers use the shared volumes that need to be updated, `sdcadm`
doesn't update the shared volume zones and instead outputs the containers'
uuids so that the operator knows which containers are still using them.

#### Deleting shared volume zones

Shared volume zones owned by a specific user, or with a specific uuid, can be
deleted by an operator. Specifiying both an owner and a volume uuid checks
that the shared volume is actually owned by the owner:

```
sdcadm shared-volumes rm [--owner owner-uuid] [--volume shared-volume-uuid]
```

If Docker containers use the shared volumes that need to be deleted, `sdcadm`
doesn't delete the shared volume zones and instead outputs the containers'
uuids so that the operator knows which containers are still using them.

## Open questions

### Interaction with local volumes

Do we support local volumes? If so, is there any chance of conflicts between
local and shared volumes?

#### What happens when mounting of a volume fails?

The current recommendation is to fail the provisioning request with an error
message that is as clear as possible.

### What NFS versions need to be supported?

NFSv3 and NFSv4 are both supported in LX containers, and it may be desirable
to support NFSv3 for mounting shared volumes from the command line in non-
Docker containers.

What are the differences between these two versions?

### Security

What are the NFS security requirements?

At this point sdc-nfs does not support anything other than restricting to a
specfic list of IPs, so we're planning to leave it open to any networks assigned
to the container. Is this a acceptable?

#### Can we limit the number of NFS volumes a single container can mount?

If so: how many?

#### Volume name limitations

Can we limit to `[a-zA-Z0-9\-\_]`? If not, what characters do we need? How long
should these names be allowed to be?

### NFS server zone's packages

#### NFS server zone's packages' CPU and memory requirements

It's not clear currently what the optimal CPU and memory requirements for
packages are. The correlation between the amount of I/O operations performed on
a given shared volume and its CPU and memory requirements hasn't been determined
yet.

As for minimum requirements, the NFS server zone currently runs one node
application (sdc-nfs) and has a smaller number of services running compared to
most "core" SDC zones. These run fine in a zone with 512 MBs of memory,
`cpu_shares === 4` and `cpu_cap === 200`, but these minimum requirements could
probably be lower.
