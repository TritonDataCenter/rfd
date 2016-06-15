---
authors: Robert Mustacchi <rm@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent Inc.
-->

# RFD 43 Rack Aware Network Pools

A growing trend in network design is to design the physical topology of
the network such that all the machines in a given rack are part of their
own broadcast domain. In those worlds, each rack basically uses its own
layer three network and VLAN. This may look something like:

```
  Rack  100                   Rack  150                  Rack  200              
  VLAN  100                   VLAN  150                  VLAN  200
  L3    192.168.100.0/24      L3    192.168.150.0/24     L3    192.168.200.0/24 
 +----------------------+    +----------------------+   +----------------------+
 |         TOR          |    |         TOR          |   |         TOR          |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.4/24 |    | CN: 192.168.150.4/24 |   | CN: 192.168.200.4/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.5/24 |    | CN: 192.168.150.5/24 |   | CN: 192.168.200.5/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.7/24 |    | CN: 192.168.150.7/24 |   | CN: 192.168.200.7/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.8/24 |    | CN: 192.168.150.8/24 |   | CN: 192.168.200.8/24 |
 +----------------------+    +----------------------+   +----------------------+
 | CN: 192.168.100.9/24 |    | CN: 192.168.150.9/24 |   | CN: 192.168.200.9/24 |
 +----------------------+    +----------------------+   +----------------------+
 |         ...          |    |         ...          |   |         ...          |
 +----------------------+    +----------------------+   +----------------------+
```

Note how each rack in the example there has its own VLAN and its own L3
network. To communicate between the racks, routing is employed and
generally the top of rack switches (TOR) advertise the summarized
prefix. While these examples are focused on IPv4, the same can logically
be said for IPv6.

## SDC Network Pools

Today, SDC network pools are used as a way of joining together multiple
disjoint L3 networks which provide a common set of resources. The most
common use case for a network pool is for something like an 'external'
pool, whereby an organization groups together their disjoint sets of
public IP addresses into one pool.

The use of a network pool is very useful. It allows us to give users
something for provisioning that will be a constant and work as the
availability of the networks that make it up come and go.

### Constraints on Network Pools

Today the primary constraint on a network pool is that all of the
networks in the pool must have the same nic tag. The reason for this
constraint is in part due to where it comes in the provisioning process
and moreso what the network pool represents. The general idea of a
network pool today is that any of the networks in there should be
interchangeable when considering provisioning. This is enforced by
having them have the same network tag.

## The Case for Something New

While the existing networking pool abstraction is very useful, it breaks
down in the face of customers who are using topologies as described in
the introduction. The problem is that as a nic tag describes a set of
connected resources at the physical level, a given nic tag may only span
a given rack.

Because of this, we cannot construct network pools in such topologies
that can span multiple racks as the nic tags are not equivalent nor
should they be in this world.

What we want is some new kind of networking object that is similar to a
pool, but rather than simply assuming that every network is
interchangeable, we instead say that after we pick a given CN for
provisioning we pick a specific network from this set. In other words,
this is made up of networks that are bound to specific racks. When a
rack is selected for provisioning then the set of networks is whittled
down to those which are available on that rack (which may themselves be a
pool).

### Rack Awareness

One big question with how to proceed here is how do we model rack
awareness. While there are open RFDs on enhancing our own notion of the
datacenter's topology, we don't today maintain accurate notions of the
rack mappings. It may be that we could look at filtering based on nic
tags in the interim as a means of driving the selection here rather than
waiting for those RFDs to be implemented and fully fleshed out.

## Next Steps

At the moment, this RFD primarily lays out an initial problem and one
suggestion at how we should approach the solution. As we further
evaluate this, we'll need to update this to include information around
and answer questions such as:

* What is this new thing called? Is it really different from a network
pool today?
* How do we represent this in NAPI?
* How do we accurately determine where in the topology to place things?
* How do we handle this in the provisioning workflow and how might this
cause provisioning issues with networks that run out of space after CN
selection?
