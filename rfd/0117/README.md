---
authors: Cody Mello <cody.mello@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/122
---

# RFD 117 Network Traits

# Introduction

Networks quite often have properties that aren't always obvious from their
names, descriptions, or IP ranges. These can range from what application lives
on the network, internet accessibility, what other networks it can route to, and
more.

Today in Triton the closest that you can get to indicating that a bunch of
networks have some common property is placing them together in a network pool.
This allows operators to group related networks together under a single UUID for
provisioning purposes, but its usefulness stops there: if an operator removes a
network from a pool (e.g., to drain the instances on it over time), then the
common thread disappears. This is problematic for several of the proposed use
cases discussed in this document. (Additionally, only operators can create and
manage network pools at this time, although this should someday be improved.)

To improve the situation, we will allow networks to be marked with traits, much
like Compute Nodes in CNAPI or instances in VMAPI.

# Support in Triton APIs

## Networking API

NAPI will handle validating, storing and searching the traits added to each
network.

## CloudAPI

CloudAPI will need to be updated to allow people to add and remove traits to the
networks that they own.

## Container Naming Service

In [CNS-170], support for accessing addresses of instances on a specific network
was added to CNS. This is limited to a single network though, and only to those
owned by the instance owner, to avoid making network names a stable interface.
For [CNS-208], we would like to be able to aggregate multiple networks, and in
a stable way, so that operator-managed networks can also be used in CNS. It
would also be good to allow users to manage which of their personal networks get
used themselves.

If we generate names based on traits, then we can allow users to add appropriate
traits to their networks. Operators will also be able to add traits like
`public` and `private` to the networks they provide to their users so that names
can be generated based on whether the addresses are external or internal.

We will probably want to restrict what characters are allowed to be used in
network traits so that they remain safe for use in DNS. (If we determine that we
need to allow non-ASCII characters into traits, then we can explore restricting
names to the subset used in Punycode.)

## Cloud Firewall

Today, Cloud Firewall rules can be written to allow traffic between instances
based on their tags. If a user wishes to allow all traffic from a private
network used by the application through, then they must either tag each instance
and maintain the tags over time, or use the `ALL VMS` keyword in the rule, which
may be too broad.

It would be nice if specific networks could be targeted, either by its UUID or
by traits. For example:

```
FROM network 2ba9f25e-ace9-4fd8-aaae-086e24aff887 TO network 2ba9f25e-ace9-4fd8-aaae-086e24aff887 ALLOW tcp PORT all
FROM network trait "appnet" TO network trait "appnet" ALLOW tcp PORT all
```

This will also allow us to create rules that target specific addresses on a NIC,
instead of all of them.

# Support in tooling

## config-agent

We would like to be able to split up the `manta` and `admin` networks into
multiple subnets. [RFD 43] took care of allowing network pools to span different
Layer 2 networks, but this means that Triton and Manta applications can no
longer rely on `nic_tag` always being the same value. [AGENT-1086] fixed this by
allowing NIC tags to be suffixed with `_rackN` (e.g., `manta_rack5`), and
stripping it to generate `auto.MANTA_IP` and `auto.ADMIN_IP`.

It would be nice if we could create `auto.*_IP` values based on network traits,
too, so that operators can assign `nic_tag` values that are more meaningful to
them, such as `admin_row13`, and just mark the networks with an `admin` trait,
instead.

## node-triton

Once CloudAPI exposes a way to update a network's traits, `triton(1)` will need
support for managing them.

## firewaller

The [firewaller] agent will need to track updates to networks so that when
traits are changed the firewalls of relevant VMs get updated. This will require
first implementing [RFD 28], so that [firewaller] can subscribe to the NAPI
changefeed. [firewaller] will subscribe to the feed using the instance
identifier `<cn uuid>/firewaller`.

[fwadm(1M)], the tool for managing firewall rules local to a machine, will need
to gain commands for storing network information locally, like it does today for
remove VMs.

<!--- GitHub repositories -->
[firewaller]: https://github.com/joyent/sdc-firewaller-agent/

<!--- Manual page links -->
[fwadm(1M)]: https://smartos.org/man/1M/fwadm
[fwrule(5)]: https://smartos.org/man/5/fwrule

<!-- Issue links -->
[CNS-170]: http://smartos.org/bugview/CNS-170
[CNS-208]: https://jira.joyent.us/browse/CNS-208
[AGENT-1086]: https://smartos.org/bugview/AGENT-1086

<!-- Other RFDs -->
[RFD 28]: ../0028
[RFD 43]: ../0043
