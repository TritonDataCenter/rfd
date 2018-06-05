---
authors: jeff emershaw <jeff.emershaw@joyent.com>
state: predraft
---

<!--
    this source code form is subject to the terms of the mozilla public
    license, v. 2.0. if a copy of the mpl was not distributed with this
    file, you can obtain one at http://mozilla.org/mpl/2.0/.
-->

<!--
    copyright 2018 joyent, inc.
-->

# RFD 143 Conch: Datacenter Switch Automation

## Problem

Today, Conch doesn't maintain the state of the switch/network configuration. To
extend Conch's visibility to an overall datacenter design, it needs to routinely
run health check and to maintain up to date configuration. By centralizing the
deployment of a switch this should speed up the replacement of a device when it
turns to the dark side.

## Requirements

- vendor-agnostic configuration process
  - tacacs servers/keys
  - syslog servers
- benchmarking
- health check process
- ipam
- toggle between production/conch
- decommission switch/replacement
- ability to resolve device mgmt ip

## Proposed Solution

TODO:

### Health Check Process

- get running config
- banner exists
- dns resolvers
- acls
- snmp server
- ntp server
- mac tables
- port descriptions
- mtu
- serial number
- optics serial number
- optical light levels
- crc errors
- check vendor known bugs
- vlan, lag, and stp checks
- integration test
- fan direction checking
- pdu check
- acl rules


### Switch path/stages to production and death

Lets start by breaking down each stage of a switch so the right tool can be
utilized. The basic workflow of a switch promotion would be as follows.

```
build -> burn-in -> shipped -> staging -> production -> maintenance -> decommission
                                                             |
                                                              -> staging -> production
```

#### Integration / Build

During the build phase, the DRD device needs to access the arista and cisco switches
because it is responsible for pxe booting the CNs and managing switch config changes. There are
some limitations on what we can test during this because this rack is isolated
and not connected to the existing datacenter.

> **q:** how will the drd device be cabled?
>
> **a:** The goal is limit how many cables are utilized. For our environment we
should be able to use 1 ethernet cable from the DRD device. Since the cisco
switches will act as a management(out-of-band) switch, it should be able to
bootstrap the cisco and the aristas. 
>
> **Q:** how much of the "real" config do we need?
>
> **A:** at this stage, we should have a custom configuration that can validate the hardware.
> 
> **solution:**
> There will be four 25Gbps DAC cables patched between TOR0 and TOR1. To allow
> the DRD to pxe boot the servers, there are one temporary 1G DAC going from the
arista TORs
> to the MGMT0 switch. By getting lldp neighbors the DRD should be able to
> customize the design. To bootstrap the switches it will be best to utilize
ZTP(or whatever proprietary name the vendor wants to call it). ZTP will take
care of upgrading to the correct vendor version of the switch and will also
enable remote access of the network gear.
>```
>               +------------+
>           XXXX|  TOR0      |XXXX
>           X   +------------+   X 4x25G(DAC)
>           X   +------------+   X
>           X   |  TOR1      |XXXX
> 1x1G(DAC) X   +------------+
>           XXXX+------------+
>               |  MGMT0     |XXXXX
>               +------------+    X 1x1G
>                       +----+    X
>                       |DRD |XXXXX
>                       +----+
>```

#### Burn-in test

We will be able to generate traffic flow to analyze the switch. Since this is
isolated the test will only be able to test the local rack/cns.
> **Q:** TODO: 

#### Shipped

This is where the real configuration will needed. Once the rack passed the
burn-in test the switches will be reset to factory defaults and will ZTP their
production configuration.
> **Q:** What sort of switch configuration do we need for this?
> **A:** Real IPs and real config is needed for this stage if we want to speed up
> delivery time.

#### Staging/pre-prod

The rack will be delivered to the destination and there will be validation tests
that will check to see switches are ready to be promoted to production. Since
there is lead time for a rack to be delivered we need to validate the
configuration again. Since the rack is now in the datacenter we should be able
to test more of the network configuration like uplinks and inter rack
reachability. How conch will access this gear and manage it could be different
than build/burn-in.
> **Q:** How can we automate the validation of the current production switch if we
don't have SSH access?
>
> **A:** We should be able to utilize the OOB devices to validate this information.
This also gives us a back door into the switches.

#### Live/Production

Now the switch is considered production ready, we should restrict what routine
checks we run on the switches. Once the switch is in this phase we can start
validating the CNs again and running other burn-in tests since we have a larger
scope to test.
> **Q:** Will the DRD setup be different for after the build phase?

#### Maintenance

The goal is to be able to put a device into maintenance mode so we could run
a full intrusive diagnostics on the switch. This phase might also be utilized to
upgrade a switch to the latest supported version. If the switch needs to go back
into production it will have to flow through the staging phase first before
entering production.
> **Q:** Can conch run particular scripts to put device in maintenance mode?
>
> **A:** Yes that is the goal so the system can do most of the legwork.

#### Decommissioned

For a device to be decommissioned it will have to be in maintenance mode first.
This will only be used for EOL or RMAs. Of course there should be another device
replacing this which will then flow through the same staging->production
workflow.

### IPAM

To have Conch take over the network automation portion, it would need to retain
network information like VLAN, Subnet, VRFs, etc. To first allocate a new data
center it needs to know what private network space it will use. It would be nice
to have this automatically allocate this based on already existing network
space.

The idea is Conch needs to have a global VRF zone, the new network would default
to the global zone if it isn't assigned to a VRF. Networks are allowed to
overlap each other in different datacenters as long as they are part of a
different VRF. Since some vendors require a unique route distinguisher that also
needs to be provided to the VRF. It might be smart to add some config setting
that allows the global zone to enforce the uniqueness of a network.

Subnets should be assigned to only one vrf. It is unclear if this would also
maintain aggregates of all the available network space. A wishful list would be
to have this be assigned to a RIR(Regional Internet Registries) like ARIN, RIPE,
APNIC, LACNIC, and AFRINIC. There are some spaces that are reserved to be used
for internal only(RFCs 1918 and 6598). By allowing a RIR Conch could maintain
the registration process. It would be great if Conch could maintain a aggregate
net block in a location so when a new network/vlan needs to be provisioned Conch
can automatically allocate those.

VLANs are the most important to this since they will provide the bridging
between Subnet and VRFs. The information that needs to be stored for this, would
be VLAN ID(1-4094) IEE 802.1Q, short description, custom role as to what this
would be used for(NAT, LAB, Out-of-band), etc. Multiple networks can be assigned
to a VLAN, but only if dhcp isn't running in those networks. It is best practice
to only use one network per vlan. A VLAN would be applied to a
datacenter/site, if not it would default to the global site.

### Integration test

This would be an intrusive test, usually when a rack is promoted to production
that means it went through some sort of intrusive test. For this test it might
consist a switch failover to make sure connectivity still exists. This can range
from a healthy reboot of a switch, or a hard power cycle of the switch using
managed PDUs. After chaos monkey happens there should then be a
bandwidth utilization test to make sure port utilizations are consistent. This is
mostly to check the hashing on the switches are correct. 

### Device mgmt IP

This part is useless if Conch is acting as the IPAM solution, but since it
doesn't do that today then for Conch to maintain a switch it will need to be
able to resolve the switch. It should be utilizing dns for this, now to do this
conch needs a way to know what the DNS record is. Without a standard naming
convention it makes this process very difficult.

Of course naming conventions always creates politics, but for this process to
be automated there needs to be logical and preferable less code. A good naming
convention could be {region}-{location}-{az}-{vendor 2 characters}-{serial number roughly
8 characters}

examples:

```
us-west-1a-FT-ABC123 (US West 1a Force10 ABC123)
us-east-1a-JU-ABCDEF (Us East 1a Juniper ABCDEF)
```
### Vlan provision process

TODO:
