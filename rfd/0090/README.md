---
authors: Josh Wilsdon <jwilsdon@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent
-->


# RFD 90 Handling CPU Caps in Triton

## What is a CPU cap?

For the purposes of this discussion, `cpu_cap` is the field that is used by the
Triton stack which is intended to be an upper bound on the amount of CPU an
instance can consume. It is expressed as a percentage of a single CPU core on
the node, so a `cpu_cap` value of 100 means that the instance can not use more
than 100% of 1 core even if the node had 64 cores and no other instances.

The mechanism in SmartOS that makes this possible is the zone.cpu-cap rctl about
which [resource\_controls(5)](https://smartos.org/man/5/resource_controls) says:

```
zone.cpu-cap

    Sets a limit on the amount of CPU time that can be used by a zone.
    The unit used is the percentage of a single CPU that can be used by
    all user threads in a zone. Expressed as an integer. When projects
    within the capped zone have their own caps, the minimum value takes
    precedence. This resource control does not support the syslog
    action.
```

importantly this is only an upper bound and does not relate directly to other
controls such as CPU Shares (FSS).

One can find the value of `cpu_cap` from within an instance using:

```
prctl -P -n zone.cpu-cap -t privileged -i zone $(zonename)
```

or:

```
kstat -C -m caps -n cpucaps_zone_* -s value
```

or from the global zone, using:

```
vmadm get <zone UUID> | json cpu_cap
```

or for all local instances:

```
vmadm list -o uuid,type,ram,cpu_cap,alias
```

One of the primary reasons for having `cpu_cap` on instances is to prevent
runaway or malicious processes from causing major contention and poor
performance for all other instances on a system. Adding a `cpu_cap` to one
instance protects other instances to some degree from that instance running
away and monopolizing *all* the available extra capacity.

## Caps vs Shares

In addition to CPU Caps, we have CPU shares (also called FSS some places). This
document is focussed only on caps, but it's worth mentioning that if a system
has no caps, when multiple zones are competing for CPU the only component of
Triton instance packages that will mediate their interaction here would be the
CPU shares. The interactions of CPU shares with the system are complex and hard
to explain to users, and as such, in a world where sum of the caps is equal to
or less than the number of cores * 100 we could consider avoiding shares
entirely.

People have also often asked for a *minimum* amount of CPU for an instance.
The current design does not allow for setting an actual minimum except through
limiting every *other* instance on the CN such that the sum of the cores
available minus the sum of other instance `cpu_cap`s will be the effective
minimum for your container (almost always negative currently).

## History

### The Beginning (or as far back as records go)

Setting `cpu_cap` by default on all zones dates back to at least December 2007.
At that time MCP would provision zones by building a new .xml file for
/etc/zones from a template and writing that out manually. The template included
lines that looked like:

```
<rctl name="zone.cpu-cap">
  <rctl-value priv="privileged" limit="<%= cpu_cap %>" action="deny"/>
</rctl>
```

At that time `cpu_cap` was required for provisioning and the (Ruby) code for
determining the default cap when none was specified was:

```
def default_cpu_cap_for_zones
  return 700 if cpu_cores == 8
  return 800 if cpu_cores == 16
  350
end
```

it does not seem to have been possible to provision using MCP without an integer
number for a cap.

### Bursting and Marketing

Using Zones/Containers allows SmartOS flexibility to give containers arbitrary
amounts of CPU. Unlike hardware virtualization where one gives a guest kernel a
fixed amount of DRAM and a fixed number of virtual CPUs, in a container your
application runs using the host kernel. This means we can allow zones to use
more CPU when the compute node (CN) is otherwise idle and that CPU would be
"wasted".

To take advantage of this feature, Joyent has offered "CPU bursting" as a
feature in its marketing since at least
[2007](http://www.cuddletech.com/RealWorld-OpenSolaris.pdf). This feature means
that users will get much better CPU performance than they'd otherwise be
allocated given the size of their Triton package.

The bursting can be limited to prevent an instance from using the entire machine
by setting a `cpu_cap` which is less than 100 times the number of CPU cores
available in the CN. In the case of Joyent's public cloud, the total `cpu_cap` /
100 has usually been much higher than the number of cores in a given CN.

### Alternate Opinions on Bursting

Within Joyent Engineering, there has been some debate about whether allowing
bursting is the best approach. The biggest arguments against allowing bursting
past the package share of a CN has been the fact that bursting guarantees
unpredictable performance. Specifically, if you provision an instance without
any caps, or with a cap that is higher than its share of the CN and it
happens to be the first instance on a CN it will start out very fast because it
can use up to all of the CPU in the machine. An instance can be in a similar
situation if it happened to be provisioned on a node that was not busy most of
the time but suddenly got very busy (e.g. Black Friday).

The maximum performance will then decrease over time as other instances are
provisioned on the CN or as they start using more of their CPU. This makes
testing and capacity planning harder as the application running in the zone can
not rely on current peak performance being anywhere near normal peak
performance.

In addition to these performance penalties, having different packages with
different amounts of bursting makes instance placement much more difficult. If
there are two instances that both have 1G of DRAM, but one has a `cpu_cap` of 800
and the other has 400, depending where we place these instances one could be up
to twice as fast as the other (if for example we place each of them on an
otherwise empty CN). In other circumstances such as a CN that's usually fairly
busy on CPU, both of these instances will see the same performance. It's even
possible that the one with the lower `cpu_cap` regularly sees better performance
than the one with the `cpu_cap` of 800.

### Manta

Until Manta, all zones in Triton have had `cpu_cap`, but Manta zones have always
been [placed manually](https://github.com/joyent/manta/blob/5a6f6401fbccb83222c675dfe2f9834447dacdb7/docs/operator-guide/index.md#choosing-how-to-lay-out-zones)
without relying on the Triton placement tools or following the package
requirements that all other Triton zones follow. As such, the consistency checks
such as requiring a `cpu_cap` or a package/billing\_id are skipped. This has
allowed Manta to avoid adding `cpu_cap`s even though every user zone in Triton
normally still has such caps.

The reasoning for not adding caps historically can be summarized by the
statement: "If the CN has compute available, why not let the manta components
use it?"

### Triton Beta

When we stood up the first beta hardware for the new Triton+Docker components,
it was decided at that time that we wanted to do an experiment where we'd go
"capless" (no instances would have `cpu_cap` set) in this initial datacenter for
Triton instances. As this was a new DC and intended to be "beta" this seemed
like the best chance for such an experiment. Additionally, since this DC would
have no KVM VMs it allowed observation of realistic workloads any of which could
burst up to the entirety of the CPU available on a compute node.

This setup proved to be challenging due to many existing assumptions in the
Triton stack which had been operating under the assumption that all zones had
`cpu_cap`s for at least 8 years by this point.

Since all instances created in SDC/Triton up to the Triton Beta that were not
created by an operator for Manta had a `cpu_cap` value, and as that value had
always previously been required it was not possible to remove a `cpu_cap` from
an instance using vmadm. Support for this was added in
[OS-4429](https://smartos.org/bugview/OS-4429) which allowed Triton Operators
and SmartOS Users to remove these caps.

For the Beta DC we avoided problems w/ mixing capped and uncapped instances
(described in the next section) by removing all caps from the zones and
modifying PAPI and other components to ensure that no instances in the DC got a
`cpu_cap`.

### Problems Mixing Capped and Capless Instances

With DAPI-272 (internal ticket, not public) changes were made to the designation
API (DAPI) to disallow mixing of instances with `cpu_cap` and no `cpu_cap` on
the same system. This change was required because otherwise DAPI could not
determine how "full" a given system was on CPU in order to determine whether
we'd yet hit the overprovisioning limits and therefore assumed the system was
"full" if there were any instances without `cpu_cap` on the CN. With these
changes, DAPI allowed placement of instances without `cpu_cap` only on CNs that
had no instances with a cap, and instances with `cpu_cap` could only be placed
on CNs with no capless instances.

For development setups, sometimes it is useful to setup a single-node Manta
configuration, and currently [this is
problematic](https://smartos.org/bugview/MANTA-2843) because of the fact that
Manta does not use `cpu_caps` and the Triton stack continues to use `cpu_cap`s.
The solutions to this for now all involve manually either modifying DAPI's
filters (removing the hard-filter-capness filter), or removing the caps from all
non-Manta zones (which needs to be redone periodically since sdcadm will add
them back). Without one of these changes a mixed cap/capless node will be
unprovisionable.

## Questions For Discussion

At this point, this RFD really exists to request discussion. The following are
questions that we should attempt to answer, but are probably not a complete set
of the open questions here. Once these are answered the answers will be folded
back into this document, possibly with more questions.

 * Should Manta have `cpu_cap`s? Why or why not?
 * Should Triton components have `cpu_cap`s? Why or why not?
 * Should Triton allow mixing `cpu_cap` and no `cpu_cap`?
   * if so: how should this work?
   * if not: how should the system distinguish between cap and capless CNs?
 * What should we tell customers in order that they can set their expectations
   correctly regarding the minimum / maximum CPU performance of their instances?
   * should they be able to specify whether they want predictable performance or
     bursting?
 * How does KVM fit into a capless world? Or does it?
