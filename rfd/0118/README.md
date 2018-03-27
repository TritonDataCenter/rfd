---
authors: Robert Mustacchi <rm@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+118%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018 Joyent, Inc.
-->

# RFD 118 MAC Checksum Offload Extensions

When sending and receiving networking traffic, there are many different
checksums that need to be calculated and verified in a packet. These
checksums are often included in the L2, L3, and L4 headers. An example
of an L2 checksum is the Ethernet CRC. An example of an L3 header
checksum is the IPv4 header checksum. An example of an L4 header
checksum is the TCP header checksum.

Specifically, we're concerned with L3 and L4 checksums. The L2 Ethernet
checksum is usually taken care of by hardware. Not all protocols have
checksums. Consider ARP or LLDP. Both of these are L3 protocols, but
neither have checksums. Similarly, while IPv4 has an L3 header checksum,
IPv6 does not!

We're specifically concerned about the following L3 protocols with
checksums:

* IPv4

We're specifically concerned about the following L4 protocols with
checksums:

* TCP
* UDP
* ICMP
* SCTP

Traditionally, these checksums were all calculated by the networking
stack. However, hardware has offered support to offload the calculation
of these checksums. This RFD covers some additional checksum extensions
offered by modern hardware that we'd like to take advantage of.

## Checksums and the GLDv3

The GLDv3 is the framework that networking device drivers implement. The
GLDv3 has a notion of a capabilities, one of which, `MAC_CAPAB_HCKSUM`
is used to identify whether or not hardware supports checksum offload
features. A driver indicates what features it supports for transmit.
When the networking stack is assembling packets, it will use this
information to determine whether a checksum will be calculated in
software or if it will be calculated in hardware.

Drivers can currently indicate the following flags. These flags are
documented in [`mac(9E)`](http://illumos.org/man/9e/mac):

* `HCKSUM_IPHDRCKSUM`: This indicates that the calculation of a checksum
of an IPv4 header can be offloaded

* `HCKSUM_INET_FULL_V4`: This indicates that the calculation of a
checksum of an IPv4 packet's L4 header can be offloaded.

* `HCKSUM_INET_FULL_V6`: This indicates that the calculation of a
checksum of an IPv6 packet's L4 header can be offloaded.

* `HCKSUM_INET_PARTIAL`: The hardware requires that a psuedo-header is
calculated for it when performing L4 offloads.

Later, when a driver transmits a packet it calls the
[`mac_hcksum_get(9F)`](http://illumos.org/man/9f/mac_hcksum_set) function
to retrieve the set of operations it must perform on the packet. Based
on these options, it generally sets bit in the packet's descriptor
header.

When a driver receives data, it looks at the header and indicates which
checksum features were triggered in a packet's descriptor header.
Depending on the type of packet, nothing may have been done or it's
possible that checksums were validated and errors were determined. Once
the driver understands what has occurred, it calls the
[`mac_hcksum_set(9F)`](http://illumos.org/man/9f/mac_hcksum_get)
function and sets checksum information as documented in the manual page.

Aside from this, everything else is handled internally in the OS and by
consumers such as DLS, IP, viona, etc.

### Limitations

Today there are two major issues that we want to bring up.

1. Support for VXLAN encapsulation checksum offload
2. Clarifying the `HCKSUM_INET_FULL_V*` and `HCKSUM_INET_PARTIAL` values.

The first issue is that we want to have the ability to leverage hardware
checksum offload for encapsulation protocols. Modern hardware has the
ability to peer into and understand VXLAN, GRE, and Geneve encapsulation
headers and calculate the inner and outer L3 and L4 header checksums.
This can be used on transmit to calculate the checksum in hardware and
on receive to verify that the checksum is correct in hardware.

This is complicated by the fact that in the VXLAN spec, it is considered
optional to set a checksum in the UDP header. However, if one does, then
the checksum must be validated.

The second issue is somewhat related. Today, when we have the
`HCKSUM_INET_FULL_V4`, `HCKSUM_INET_FULL_V6` and `HCKSUM_INET_PARTIAL` flags
we do not indicate the set of L4 protocols that are considered by these.
The issue comes to the forefront when hardware supports different sets from
what the operating system expects.

The four L4 checksums that come up most often are the ones we mentioned
earlier: TCP, UDP, ICMP, and SCTP. Of these, the OS implies that those
values mean TCP, UDP, and ICMP. However, while most hardware supports
TCP and UDP checksum offload, the same is not true for ICMP. For
example, the `qede` driver does not support ICMPv6 checksum offload and
the `i40e` driver does not support partial checksum calculation for ICMP.

## Proposals

### Dealing with `HCKSUM_INET_FULL_V*` and `HCKSUM_INET_PARTIAL`

To deal with the question around what does `HCKSUM_INET_FULL_V4`,
`HCKSUM_INET_FULL_V6` and `HCKSUM_INET_PARTIAL` mean, I propose that we
clarify things in the manual page to specifically say that these only apply
to the TCP and UDP protocols.

This does mean that there are some drivers that currently provide ICMP
checksum support which will be missing out. However, the percentage of
traffic that is ICMP and the corresponding cost for such drivers will be
minimal. In addition, we should add three new flags to cover ICMP.

* `HCKSUM_INET_FULL_ICMPv4`

This indicates that hardware supports checksum offload for IPv4 ICMP
packets.

* `HCKSUM_INET_FULL_ICMPv6`

This indicates that hardware supports checksum offload for IPv6 ICMP
packets.

* `HCKSUM_INET_PARTIAL_ICMP`

This indicates that hardware supports partial checksum offload for ICMP
packets.

These could also be extended to cover SCTP in a similar fashion by
adding `HCKSUM_INET_FULL_SCTPv4`, `HCKSUM_INET_FULL_SCTPv6` and
`HCKSUM_INET_PARTIAL_SCTP`. Or if some future IPv4 protocol has hardware
checksum offload support, we can indicate it in a similar way.

One nice side effect of this is that it does not impact the set of flags
that we need to offer to use with `mac_hcksum_get(9F)` or
`mac_hcksum_set(9F)`.


### Encapsulation Checksum Offload

There are a few more challenges with checksum offload features. First,
the following hardware table of features is useful to share. This table
table surveys devices that are currently on the market and what they
support for VXLAN encapsulation. Inner L4 only refers to TCP and UDP.

| Driver | Inner L3 | Inner L4 | Outer L3 | Outer L4 | Notes |
|--------|----------|----------|----------|----------|-------|
| bnxt | yes | yes | yes | yes | no illumos driver |
| cxgbe | yes* | yes* | yes* | yes* | Pending verification |
| i40e | yes | yes | yes | no* | Outer L4 only supported on X722 MAC |
| ixgbe | yes* | yes* | yes* | no* | Only supported on X550 MAC |
| mlx4x | yes* | yes* | yes* | yes*  | no illumos driver, pending verification |
| mlx5x | yes* | yes* | yes* | yes* | no illumos driver, pending verification |
| qede | yes | yes | yes | yes | - |


Based on this there are a few important things to note. The first is
that this table is focused entirely on VXLAN. However, there are other
encapsulation protocols such as GENEVE that might need to be dealt with
in the future.

Next, we should only concern ourselves only with the inner TCP and UDP
headers. While this means that we're leaving out inner ICMP traffic,
as a proportion of traffic it isn't very large and not a lot of
hardware supports it.

In addition, if we're talking about VXLAN, then really that means that
the outer L4 is UDP. Today's hardware seems to always support the inner
L3 and L4 offloads, even if it varies on the support of the outer L3 and
L4. As such, we should start with a more limited bit set that covers
what we care about. If hardware offers more options then we can add
flags to cover that hardware if it's required.

As such, I'd propose that we add the following flags to the capability
set:

* `HCKSUM_VXLAN_FULL`

This indicates that the inner L3, inner L4, outer L3, and outer L4, can
all be offloaded to hardware for processing. Specifically this means
the following:

1. Inner L4 can be TCP or UDP
2. Inner L3 can be IPv4 or IPv6
3. Outer L4 must be UDP
3. Outer L3 can be IPv4 or IPv6

There is no checksum in an IPv6 header. However, this indicates that
an L3 IPv6 header can be understood by the hardware.

* `HCKSUM_VXLAN_FULL_NO_OL4`

This is similar to the `HCKSUM_VXLAN_FULL`; however, there is no support
for offloading the checksum of the outer L4 header and instead, the
checksum must be calculated on its own.

Finally, there are no partial checksum flags or non-verified checksum
flags present here. The intent is to only support the full header
checksums that are completely validated by the OS at this time. If
hardware comes along that requires this mode, then we can add support
for this.

We must add a few more flags to the `mac_hcksum_get(9F)` and
`mac_hcksum_set(9F)` family of functions. First, we suggest that we
treat all of the existing flags as referring to the outer headers. This
means that there are no changes to the existing values and their meaning
in drivers, even when dealing with encapsulated packets.

When receiving we should add the following flags:

* `HCK_INNER_IPV4_HDRCKSUM_OK`: This is the equivalent of the
`HCK_IPV4_HDRCKSUM_OK` flag; however, it applies to the inner IPv4
header.

* `HCK_INNER_FULLCKSUM_OK`: This is equivalent of the `HCK_FULLCKSUM_OK`
flag; however, it applies to the inner L4 header.

When transmitting we should add the following flags:

* `HCK_INNER_IPV4_HDRCKSUM_NEEDED`: Indicates that the hardware must
calculate the inner IPv4 header checksum. This is the equivalent of
`HCK_IPV4_HDRCKSUM`.

* `HCK_INNER_FULLCKSUM_NEEDED`: Indicates that the hardware must
calculate the inner L4 header checksum. This is the equivalent of
`HCK_FULLCKSUM`.


To round this off, we may need to add additional support functions.
These functions should be used by the overlay driver and other internal
routines that need to know how to shift values from a message block with
an encapsulated packet to the message block that just has the inner
payload or vice versa.

For example, when a frame is being encapsulated, something may have
already set the `HCKSUM_FULLCKSUM` flag. When the frame is encapsulated,
this will need to transform from `HCK_FULLCKSUM` to
`HCK_INNER_FULLCKSUM_NEEDED`. The opposite will need to happen in
decapsulation. If `HCK_INNER_IPV4_HDRCKSUM_OK` was set, then
`HCK_IPV4_HDRCKSUM_OK` will need to be set on the decapsulated packet.

The following are function prototypes that may be able to offer this
functionality. However, this is subject to change as we further develop
this featuer and gain a better understanding of how it is supposed to
work.

```
/*
 * Take the flags that indicate a needed set of checksum values and turn
 * them into the corresponding flags that refer to inner values. This
 * should be called when a mblk_t is being encapsulated.
 */
extern void mac_hcksum_encap_shift(mblk_t *mp, uint32_t flags);

/*
 * Take the flags that were applied to a full message block and
 * transform them so that they apply to the decapsulated version. For
 * example, if HCK_INNER_FULLCKSUM_OK was set in flags, instead
 * HCK_FULLCKSUM_OK will be set on mp.
 */
extern void mac_hcksum_decap_shift(mblk_t *mp, uint32_t flags);
```

With this scheme, we'll still need to make sure that the checksum flags
are cleared on the original message blocks, so nothing gets confused. In
addition, we may need to go through and improve mac_fixup_cksum(),
viona, and others to handle these newer flags and work around them.

It is also likely that we're going to end up coming up with other
additions that we need when we're working with the specific drivers. For
example, it may be useful to indicate that VXLAN encapsulation
specifically was used with some additional metadata. We'll let the
implementation guide us here.
