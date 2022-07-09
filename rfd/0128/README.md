---
authors: Robert Mustacchi <rm@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+128%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018 Joyent, Inc.
-->

# RFD 128 VXLAN Tunneling Performance Improvements

This RFD covers a series of enhancements to the networking stack that
we'd like to make in order to improve the performance of VXLAN
Encapsulated traffic.

## Background

VXLAN (or VxLAN) is a protocol defined in RFC 7348. The VXLAN protocol
takes a normal, fully formed L2 packet (as in MAC, IP, TCP or UDP, etc.)
and places it inside of a UDP packet with a defined 8-byte header that
includes a 24-bit client id. Consider, the following image:

Original packet:

```
+----------+---------+--------+---------+
| Ethernet | IP      | TCP    | Data    |
| Header   | Header  | Header | Payload |
+----------+---------+--------+---------+
```

Encapsulated packet:

```
*==========*========*========*========*============================================*
v          v        v        v        v Original Packet                            v
v Outer    v Outer  v Outer  v        v  +----------+---------+--------+---------+ v
v Ethernet v IP     v UDP    v VXLAN  v  | Ethernet | IP      | TCP    | Data    | v
v Header   v Header v Header v Header v  | Header   | Header  | Header | Payload | v
v          v        v        v        v  +----------+---------+--------+---------+ v
*==========*========*========*========*============================================*
```

In Triton, VXLAN is the networking underpinning of the series of
features called 'fabrics'. On top of fabrics, customers can define their
own arbitrary networks. In Triton, traffic that customers see is called
overlay traffic, while the underlying network that this UDP traffic is
created over is called underlay traffic.

To implement this, a dladm construct called an `overlay` exists. The
overlay device solves the problem of determining how to send traffic out
on the underlying network and where to send it. This is done in
conjunction with the userland daemon called `varpd`. In the broader
Triton infrastructure, `vardp` communicates with a service called
`portolan` which helps interface with the rest of the Triton control
plane.

The overlay device sends and receives traffic by creating a kernel
socket. A kernel socket is the same thing as a normal socket created
with [socket(3SOCKET)](http://illumos.org/man/3socket/socket). There are
kerenel analogues for functions like
[bind(3SOCKET)](http://illumos.org/man/3socket/bind) or
[semdmsg(3SOCKET)](http://illumos.org/man/3socket/sendmsg). The ksocket
is a straightforward basis for what we've implemented. Traffic that
comes in the ksocket will have the VXLAN encapsulation removed and
traffic that goes out of it, will have VXLAN encapsulation added.

Different overlay devices may share the same interface information. For
example, in Triton, a compute node has a single underlay device, so all
VXLAN traffic would enter or leave that single ksocket. The overlay
driver calls this a multiplexor, or mux for short. The tuple of the
listen IP address, listen port, and encapsulation type must be unique
for each mux.

Finally, each of the encapsulation plugins exist in the kernel as a
unique kernel module.  Each overlay plug-in module is given the chance
to register any specific socket options it'd like on the mux. While most
of this can apply to other modules, our focus is on
[vxlan(7P)](http://smartos.org/man/7p/vxlan).

### Previous Enhancements

To date, we've implemented two different enhancements for VXLAN traffic
in a general fashion.

The first enhancement is UDP source port hashing. Through the private
kernel UDP socket option, the vxlan driver (part of the overlay
framework) can enable the `UDP_SRCPORT_HASH` socket option. This socket
option causes us to hash the inner Ethernet header's MAC addresses, IP
addresses, and ports. That hash will be used as the source port of the
UDP socket.

The gaurantee that we make is that a given flow will always hash to the
same UDP source port. This is useful for a number of different systems.
For example, it helps with LACP hashing, ECMP (Equal Cost
Multi-Pathing), and the internal fanout in the illumos networking stack.

The second enhancement we've made is the idea of a direct ksocket
receive callback. Traditionally when a socket receives data from sockfs,
it will sit in the socket buffer. The kernel socket will then need to
receive a poll notification to know that it can read the socket and then
call kernel equivalent of the recvmsg function on the socket.

Instead, to minimize the latency of acting on a packet, the ksocket has
a direct receive callback. This direct receive callback allows for
standard socket back pressure to be communicated, while still allowing
for the overlay module to receive data inline.

## Proposed Enhancements

There are several different enhancements that we'd like to make to the
networking stack and GLDv3 to improve the performance of VXLAN
encapsulated traffic. First, we will list each of the different areas
that we care about, then we will come back to each one in detail. In
those sections we will explain the rationale for the enhancement and how
we might implement it.

The current proposed enhancements are:

1. Construct a means for overlay devices to advertise hardware
capabilities to VNICs and allow for interface binding
2. Leverage Hardware for VXLAN-aware checksums ([RFD
118](../0118/README.md))
3. Relaxed UDP checksumming
4. Leverage Hardware for VXLAN-aware TCP Segmentation Offload (TSO)
5. Reduce mblk\_t overhead
6. Reduce UDP destination cache costs
7. Introduce a means for VXLAN-dedicated MAC groups

### Advertising Hardware Features

In the networking world, we spend all of our time building up different
layers of abstraction, only to need to tear them all away in the name of
performance.

In order for overlay devices to be able to advertise different hardware
capabilities, we need a few things:

1. A means of communicating the hardware capabilities to a UDP socket
2. A means of making sure that traffic can only go out a specified
interface
3. A means of being notified when underlying hardware capabilities
change

To do all of this, I propose introducing a new socket option. This
socket option will subsume the previous `UDP_SRCPORT_HASH` socket
option.

The basic form of the structure looks something like:

```
#define UDP_TUNNEL_VXLAN        1
#define UDP_TUNNEL_OPT_SRCPORT_HASH     0x01
#define UDP_TUNNEL_OPT_HWCAP            0x02
#define UDP_TUNNEL_OPT_RELAX_CKSUM      0x04

typedef struct udp_tunnel_opt {
        uint32_t        uto_type;
        uint32_t        uto_opts;
        uint32_t        uto_cksum_flags;
        uint32_t        uto_lso_flags;
        uint32_t        uto_lso_max;
} udp_tunnel_opt_t;
```

The way that this is used is that after a UDP socket is bound, it will
set the `UDP_TUNNEL` socket option by filing in the `uto_type` and
`uto_opts` members.

Currently, the only valid `uto_type` is for VXLAN. However, everything being
discussed here is equally applicable to other UDP tunnel protocols, like
[Geneve](https://datatracker.ietf.org/doc/draft-ietf-nvo3-geneve/).

When calling getsockopt(3SOCKET), the members such as the
`uto_cksum_flags`, `uto_lso_flags`, `uto_lso_max`, etc. will be filled
in based on the underlying capabilities and options set.

The `UDP_TUNNEL_OPT_SRCPORT_HASH` will request that the source port is
hashed. This is identical to the current `UDP_SRCPORT_HASH` socket
option.

If the `UDP_TUNNEL_OPT_HWCAP` flag is set, this will indicate that the
caller wants to be able to use hardware capabilities from the underlying
socket. If this is set, then at setting time, the UDP socket will become
bound to the underlying socket as though the IP_BOUND_IF socket option
had been called. This will ensure that all traffic will only ever enter
and leave the corresponding socket.

The capabilities of a MAC device can change after the device has been
initialized. To indicate this, a GLDv3 device driver can call the
`mac_capab_update()` function. This will cause a `MAC_NOTE_CAPAB_CHG`
event to be generated. This will be noticed by the dld module and it
will generate a `DL_NOTE_CAPAB_RENEG` to occur. This will cause the IP
module to listen for and renegotiate properties as required.

There are a few complications in terms of dealing with this. In
particular, not all clients support renegotiation. For example, a viona
device which communicates across the virtio specification does not
support having the set of capabilities changed once it has been
initialized.

To accommodate this, I believe that we'll need to a multi-pronged
approach. First, we will need to have the IP module arrange to callback
into us that this has occurred. This will cause the overlay module to
trigger its own `mac_capab_update()` function called, which will in turn
cause other clients on top of the overlay to renegotiate.

However, as we have previously mentioned, some clients cannot
renegotiate. In those cases, the overlay driver must remember if it has
ever advertised a feature to a client and when it changes what it can
support, then it must deal with it in software. This may mean fixing up
checksums or performing LSO in software.

If possible, we should not push this onto the mac clients, if we can
avoid it.

At this time, hardware capabilities imply binding to the interface. All
of the UDP tunnels that we're talking about are ultimately just at the
level of UDP. This means that the IP routing tables can take effect and
direct packets to different interfaces than the one that the socket is
bound over. The act of binding to the interface eliminates this concern.
This all mimics how we actually deploy and use VXLAN today -- all
traffic is required to go over one interface.

#### Summary of Changes

To implement all of this, we need to do the following:

1. Add a new property for all overlay devices, "mux/bound" that will
default to true. This will be used to control whether or not we bind to
interfaces.

2. Add a new overlay property type, the boolean, to account for the
above.

3. Add a new UDP socket option, `UDP_TUNNEL` that will subsume the
existing `UDP_SRCPORT_HASH` socket option.

4. Add a new plug-in callback function that allows the overlay plugins
to note if they can advertise any hardware capabilities.

### VXLAN Checksumming

The ability to provide checksum offload is described in [RFD 118 MAC
Checksum Offload Extensions](../0118/README.md). What is not discussed
in that RFD is how clients like the overlay driver will consume this
knowledge.

Here, we propose that this happen through the `UDP_TUNNEL` socket option
and the `UDP_TUNNEL_OPT_HWCAP` option. When set, then the overlay driver
or its plugins will be able to retrieve the hardware capabilities and
advertise the corresponding options. The overlay driver will then
advertise the corresponding flags that make sense.

#### Summary of Changes

To implement this, we need to do the following:

1. Implement RFD 118 for several drivers

2. Make sure that the checksum bits are available through the
`UDP_TUNNEL` socket option.

3. Modify the overlay driver to translate inner checksum bits to outer
checksum bits when it receives a packet.

4. Modify the overlay driver to translate outer checksum bits to inner
checksum bits when it transmits a packet and to set it on the next
message block.

5. Make sure that when the UDP module prepends the header template, it
shifts the message block checksum bits to the outer most message block.

6. Modify the ip module to make sure that it properly notices that the
inner checksum bits are set when it is considering whether or not it can
perform hardware checksum.

### Relaxed UDP Checksumming

In IPv4, the UDP checksum is actually optional, where as in IPv6 it is
required. Many NICs will consider it a checksum error if an IPv6 UDP
checksum is set to zero. The VXLAN specification says that the UDP
checksum may be left as zero. It is presumed that this is because the
IPv4 checksum and the Ethernet FCS will provide some modicum of error
checking.

Unfortunately, some amount of hardware is implemented such that it does
not provide support for offloading the outer UDP checksum and only
supports offloading the inner L4 checksum. It is an unfortunate reality
that the outer UDP checksum and the inner L4 checksums are the most
expensive part of the checksum process. This is due to the fact that the
UDP and TCP checksums cover the entire payload of the packet, not just
the header like the IPv4 checksum does.

Because the stack today does not support any checksumming of inner
packets, we always leverage hardware's ability to checksum the outer
headers. In many ways if we introduce the VXLAN-aware checksum offload
features that were discussed in the previous section, then we may not
actually save any computational time if we both require the outer UDP
checksum and hardware doesn't calculate it.

To deal with this, we suggest adding a new flag to the `UDP_TUNNEL`
socket option, `UDP_TUNNEL_OPT_RELAX_CKSUM`. When this flag is set, the
networking stack _may_ relax the calculation of the UDP checksum.

The UDP checksum will not be set to zero if any of the following is
true:

* The bound socket is using IPv6 (this does not include IPv4-mapped IPv6
addresses).
* The hardware does not support any VXLAN related checksum offloads
* The hardware does not support offload of both the inner and outer
headers.

While this may seem like a small case, for a large number of systems and
networking cards, this will provide a benefit.

#### Summary of Changes

To implement all of this, we need to do the following:

1. Add the `UDP_TUNNEL_OPT_RELAX_CKSUM` option to the `UDP_TUNNEL`
socket option.

2. Add a flag to the ip_xmit_attr_t that indicates that the L4 checksum
(but not the L3) should be skipped. This will only be used by UDP.

3. Modify the IP and UDP modules to honor these settings.

### VXLAN-Aware Hardware TCP Segmentation Offload

Just as modern hardware is providing for VXLAN checksum offload, it is
also allowing for TSO (TCP segmentation offload) to be performed in a
VXLAN aware manner. This means that hardware will duplicate the outer
UDP/VXLAN header and send it on the wire while segmenting an inner TCP
header.

Just as TSO requires hardware checksum offload to function and be
enabled, the same is true for the VXLAN aware TSO. One wrinkle here is
that because UDP on IPv6 always requires a valid checksum, VXLAN-aware
TSO will not be advertised by hardware unless it supports calculating
the outer checksum.

At the GLDv3 level, we will add the following structure. With this
member present, the `mac_capab_lso_t` will now look like:

```
#define	LSO_VXLAN_OUDP_CSUM_NONE	0
#define	LSO_VXLAN_OUDP_CSUM_PSUEDO	1
#define	LSO_VXLAN_OUDP_CSUM_FULL	2

typedef struct lso_vxlan_tcp {
	uint_t	lso_oudp_cksum;		/* Checksum flags */
	uint_t	lso_tcpv4_max;          /* maximum payload */
	uint_t	lso_tcpv6_max;          /* maximum payload */
} lso_vxlan_tcp_t;

#define	LSO_TX_VXLAN_TCP	0x02		/* VXLAN LSO capability */

typedef struct mac_capab_lso_s {
	t_uscalar_t             lso_flags;
	lso_basic_tcp_ipv4_t    lso_basic_tcp_ipv4;
	lso_vxlan_tcp_t         lso_vxlan_tcp;
	/* Add future lso capabilities here */
 } mac_capab_lso_t;

```

mac(9E) will be updated to indicate to device driver writers that they
should not advertise these without corresponding checksum support. It
will also take into account the UDPv4 checksum relaxation note.

The lso_oudp_cksum member will be used to communicate the requirements
of the outer UDP checksum member. In this case,
`LSO_VXLAN_OUDP_CSUM_NONE` means that the hardware does not support any
checksum offload. This means that VXLAN-aware LSO will not be supported
for IPv6 and that for IPv4, it will require the relaxed zero checksum.
It is the responsibility of layers above MAC to determine if they can
leverage VXLAN aware TSO.

Once a driver plumbs this through, then it will be up to DLD to
determine whether or not it advertises this functionality. If DLD does,
it will set two additional flags in the dld_capab_lso_t. In particular:
`DLD_LSO_VXLAN_TCP_IPV4` and `DLD_LSO_VXLAN_TCP_IPV6`.  Checksum
requirements may also be passed in if it appears that the software stack
requires this. The DLD flags are currently passed through to the overlay
driver in the form of the UDP_TUNNEL socket option.

It will be up to the overlay driver to translate these to and from the
corresponding traditional MAC TSO capabilities.

#### Summary of Changes

To implement this, we need to do the following:

1. Add new structures to <sys/mac_provider.h> to cover the MAC
capabilities.

2. Modify DLD to look for these capabilities and advertise it up the
stack.

3. Modify the UDP_TUNNEL socket option implementation to be able to get
this information and push it through.

4. Modify the vxlan plugin to be able to advertise this information.

5. Modify UDP to make sure that if it has a packet requiring LSO that
the flags are propagated to the outer message block.

#### Open Questions

Right now, it's not clear if we'll want to dedicate a bit to indicate
that we're performing a tunneled LSO or not. It's not clear if
indicating that a mblk_t is tunneled with vxlan would be more useful or
not.

### Reduce VXLAN mblk_t overhead

Today, the overlay module asks its encapsulation plugin to generate a
message block that has the protocol-specific header. This will then
allocate an 8 byte message block that gets prepended. Then, when we
enter UDP, we'll have another message block prepended that has the
Ethernet, IP, and UDP header.

Each additional message bock that we prepend will create overhead when
we're trying to transmit this out to a driver. Today we'll have a chain
that looks like:

```
<L2/L3 header> -> <VXLAN header> -> <Inner L2 frame>
```

There are two different ways that we can approach this. One is that we
can try and ask UDP how much space it needs for a header and the other
way we can do this is to ask UDP to copy the length of our header with
the promise that it's always in a solitary message block.

It's worth keeping in mind that while VXLAN has a fixed size header,
other tunneling protocols like Geneve do not and allow for options.
While we may start prototyping by asking UDP to allocate the extra bytes
and freeing the header if it's short, it may be worthwhile to experiment
in the other direction.

The advantage of taking care of the size in the overlay module is that
then we remove a copy and allocation. The disadvantage is that the size
of the message block that we need to allocate will vary based on the
destination IP.

On the other hand, UDP already has functionality that manages to handle
this logic and take it into account. So we could have the protocol set
an upper bound on this. For example, it may be that almost all of the
geneve protocol usage (which we don't implement) will not end up using
many options, in which case having a fixed upper bound of say 64-128
bytes of options will make things simpler.

Because there are still a lot of unknowns in this, the exact series of
implementation steps that we might need to take are unclear.

### Reduce UDP Destination Costs

The ip module and its interfaces are fundamentally connection oriented.
While it is possible to use UDP in a connected fashion by calling
connect(3SOCKET), in the overlay module we do not do such a thing.
Every time that a UDP packet goes out to a new destination, the UDP
module will reset the IP attribute structure and effectively 'connect'
it to a new address.

We need to explore ways of caching these attribute structures for longer
so we don't have to constantly recalculate and throw out this data. This
is especially painful when we are going to more than one CN. There are a
couple of different ways to consider tackling this, each with their own
pros/cons:

1. Currently UDP caches the most recent place. We could have UDP cache
several more entries.

2. We could effectively cache these IP xmit attributes and the
corresponding header templates as part of the overlay target table.

This latter option could be very interesting to integrate with the
options we have to reduce VXLAN mblk_t overhead.

### VXLAN-dedicated MAC Groups

This is perhaps the most involved piece that we'd like to add and in
some ways the most promising. What we'd like to do is leverage filtering
advances in hardware to try and classify traffic. There a couple of
different levels of classification that we are considering:

1. Traffic that targets the entire underlay tunnel
2. Traffic that targets a specific VNI (VXLAN identifier) on the
underlay tunnel
3. Traffic that targets a specific VNI/MAC/VLAN on the underlay tunnel.

Each of the above layers is more and more specific. However, if hardware
supports it, this can end up leading to a much simpler receive path for
a couple of reasons:

1. We can get the overlay driver an entire chain of messages to deliver
2. The only IP/UDP logic we need to check/apply is the firewall, which
we can still do in a chain aware fashion
3. Depending on how we structure things, we can actually turn this into
a virtual group support for the overlay mac clients

Effectively, what this would do is take advantage of the MAC RING pass
through work that was introduced in
[OS-6719](https://smartos.org/bugview/OS-6719). The main premise is that
rather than doing normal soft ring processing, we'll pass it straight
through to the mac client that consumes and controls these. This is
slightly different from a VNIC, because the VNIC's mac client is a bit
more of a fiction.

The main goal here is to expose a mac capability that covers setting
up a group to target a specific tuple. We're still working through the
details with several different vendors and thus right now all that we
have is a token proposal, though this is all up in the air. At the
moment this is an extension to the MAC_CAPAB_RINGS, though it could
really be its own extension.

```
/*
 * These are bits that can be performed for a given filter.
 */
#define	MAC_GROUP_FILTER_SRC_MAC	(0x1 << 0)
#define	MAC_GROUP_FILTER_DST_MAC	(0x1 << 1)
#define	MAC_GROUP_FILTER_ETHERTYPE	(0x1 << 2)
#define	MAC_GROUP_FILTER_VLAN		(0x1 << 3)
#define	MAC_GROUP_FILTER_SRC_IP		(0x1 << 4)
#define	MAC_GROUP_FILTER_DST_IP		(0x1 << 5)
#define	MAC_GROUP_FILTER_IP_PROTOCOL	(0x1 << 6)
#define	MAC_GROUP_FILTER_SRC_PORT	(0x1 << 7)
#define	MAC_GROUP_FILTER_DST_PORT	(0x1 << 8)
#define	MAC_GROUP_FILTER_TUNNEL_TYPE	(0x1 << 9)
#define	MAC_GROUP_FILTER_TUNNEL_VNI	(0x1 << 10)

/*
 * These are bits that describe the type of flow that we can apply these
 * tunnels to. For VXLAN, etc. it indicates that we can see into that
 * flow.
 */
typedef enum mac_group_flow_filter {
	MAC_GROUP_FLOW_BASIC = 	(0x1 << 0)
	MAC_GROUP_FLOW_VXLAN =	(0x1 << 1)
	MAC_GROUP_FLOW_GENEVE =	(0x1 << 2)
	MAC_GROUP_FLOW_NVGRE =	(0x1 << 3)
	MAC_GROUP_FLOW_IPTUN =	(0x1 << 4)
	MAC_GROUP_FLOW_IPSEC =	(0x1 << 5)
} mac_group_flow_filter_t;

/*
 * The mac_capab_rings_t structure will be extended to have the following
 * two members that will only be considered for RX purposes:
 */

	/*
	 * This should be the OR of all of the mac_group_flow_filter_t
	 * bits that this hardware can support filtering in. Each one
	 * will have the callback called on it to get more information.
	 */
	mac_group_flow_filter_t	mr_filters;

	/*
	 * This function gets called by MAC to determine whether or not
	 * we can support a specific filter. Because hardware has
	 * specific constraints in terms of what it can and can't do,
	 * it's much easier to phrase this as can you do this filter
	 * rather than trying to ask the driver to declare what
	 * combinations are supported.
	 */
	boolean_t (*mr_filter_query)(void *, nvlist_t *);



/*
 * To program the filter, we'll add a pair of members to the
 * mac_group_info_t structure. These will be used to add and remove
 * filters to the group. We'll communicate these as an nvlist_t which
 * has a number of members to allow for the expression of complex
 * filters and gives us an extensible format.
 *
 * Because these filters are complex. Rather than try and give the
 * driver an nvlist_t to figure out what it corresponded to, we'll store
 * a cookie on behalf of the driver so it knows what to go through and
 * add.
 */

	int (*mgi_addfilter)(mac_group_driver_t, nvlist_t *filter,
	    void **cookiep);

	int (*mgi_remfilter)(mac_group_driver_t, void *cookie);
```

Now, there's one gotcha with all this that we haven't figured out how to
express that I'd appreciate feedback on. There are certain things which
aren't activated by hardware specific to these tunnels without specific
actions being taken.

For example, the Intel X710 requires a UDP port to be associated with
something to be able to perform receive checksum offload. It's not clear
if we should tie that into this or try and elevate this a bit more
somehow. It may be useful to have i40e implicitly do this and only do
this when we create a UDP tunnel, but it may also be useful to have a
UDP tunnel specific thing.
