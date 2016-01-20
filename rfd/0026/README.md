---
authors: Jerry Jelinek <jerry@joyent.com>
state: draft
---

# RFD 26 Network Shared Storage for SDC

## Introduction

In general, support for network shared storage is antithetical to the SDC
philosophy. However, for some customers and applications it is a requirement.
In particular, network shared storage is needed to support Docker volumes in
configurations where the Triton zones are deployed on different compute nodes.

For reliability reasons, compute nodes never use network block storage and SDC
zones are rarely configured with any additional devices. Thus, shared block
storage is not an option.

Shared file systems are a natural fit for zones and SmartOS has good support
for network file systems. A network file system also aligns with the semantics
for a Docker volume. Thus, this is the chosen approach. NFS is used as the
underlying protocol. This provides excellent interoperability among various
client and server configurations. Using NFS even provides for the possibility
of sharing volumes between zones and kvm-based services.

## Requirements

 0. Provide support for 'docker volume create', 'docker volume rm' and running
    with a given volume (e.g. docker run -d -v myvol:/my_app wordpress).
 1. The customer's file system(s) must only be visible on the customer's VXLAN.
 2. The solution must work for both on-prem SDC users and JPC.
 3. The shared file system size must be expandable (i.e. not a fixed quota size
    at creation time).
 4. Support a maximum shared file system size of 1TB.
 5. Although initially targeted toward Docker volume support, the solution
    should be applicable to non-Triton zones as well.
 6. TBD What are the NFS security requirements?

## Non-Requirements

 0. The NFS server does not need to be HA.
 1. The NFS server does not need to be available across data centers.
 2. High performance is not critical.
 3. A dedicated NFS server (or servers) is not necessary.
 4. Robust locking for concurrent read-write access (e.g. as used by a
    database) is not necessary.

## Approach

Because the file system(s) must be served on the customer's VXLAN, it makes
sense to provision an NFS server zone, similar to the NAT zone, which is owned
by the customer and configured on their VXLAN. Serving NFS from within a
zone is not currently supported by SmartOS, although we have reason to believe
that we could fix this in the future. Instead, a user-mode NFS server will
be deployed within the zone. Because the server runs as a user-level process,
it will be subject to all of the normal resource controls that are applicable
to any zone. The user-mode solution can be deployed without the need for a new
platform or a CN reboot.

The NFS server will simply serve files out of the zone's file system. These
could reside on a delegated ZFS dataset, or not (it is irrelevant). There may
be a benefit to using a delegated dataset for other reasons, such as snapshots
or zfs send to a different host, but use of a delegated dataset is orthogonal
to this proposal.

The Triton docker tools will be enhanced to create an NFS server zone when they
receive the 'volume create' command and to destroy the zone on 'volume rm'.
The user-mode server must be installed in the zone and configured to export
the appropriate file system. The docker tools must support the mapping of the
user's logical volume name to the zone name and share.

The placement of the NFS server zone during provisioning is a complicated
decision. There is no requirement for dedicated hardware that is optimized as
file servers. The server zones could be interspersed with other zones to soak
up unused storage space on compute nodes. However, care must be taken so that
the server zones have enough free local storage space to expand into.
Provisioning of regular zones should also take into account the presence
storage zones and any future growth they might incur. It is likely we'll have
to experiment with various approaches to provisioning in order to come up with
an acceptable solution. The provisioning design is TBD.

The Triton docker tools will be enhanced to add the given volumes on
'docker run' as NFS mounts on the zone configuration.

Although the initial implementation is targeted at Triton zones, the SDC tools
should also be enhanced to support these new network shared storage zones.
The deisgn of the SDC tool enhancements is TBD.

## Alternative Approaches

We could partner with a third-party NFS filer solution and make that a
requirement for using SDC on-prem. A third party solution might include more
robust HA capabilities out of the box, although any HA solution can be debated.
Also, adding third-party dependencies as a requirement for using SDC/Triton
is as much a business decision as a technical decision.

## Other Considerations

The user-mode NFS server is a solution that provides for quick implementation
but may not offer the best performance. In the future we could do the work
to enable kernel-based NFS servers within zones. Switching over to that
should be transparent to all clients, but would require a new platform on the
server side.

Although HA is not a requirement, an NFS server zone clearly represents a SPOF
for the application. There are various possibilities we could consider to
improve the availability of the NFS service for a specific customer. These
ideas are not discussed here but could be considered as future projects.

Integration with Manta is not discussed here. However, we do have our manta-nfs
server and it dovetails neatly with the proposed approach. Integrating
manta access into an NFS server zone could be considered as a future project.

Hardware configurations that are optimized for use as NFS servers are not
discussed here. It is likely that a parallel effort will be needed to
identify and recommend server hardware that is more appropriate than our
current configurations.
