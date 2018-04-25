---
authors: Rui Loura <rui@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/98
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2018 Joyent, Inc.
-->

# RFD 138 Multi-subnet Admin Networks

Today, the admin network consists of a single subnet over which all of the services across each host and rack communicate.  The goal of this change is to allow multiple admin subnets within a single AZ so that deployments can scale the number of CNs, while keeping a reduced L2 domain, and allow for Clos (spine leaf) network topologies.  Triton and Manta administration tools will be updated to allow provisioning to an "admin" network pool which aggregates all of the admin subnets.

## Feature 
The feature will allow for CNs to be assigned different networks over which admin traffic will traverse.  Each one of these networks will need to be part of an admin network pool.  When a CN boots it will be assigned a nic from the network in the "admin" network pool that matches the desired nictag. 

This feature is dependent upon [RFD 43](../0043/README.md), and a prerequisite for OPS-RFD 27.

## DHCP (sdc-booter) considerations

Each CN in a triton deployment uses iPXE and DHCP to boot. Unfortuantely DHCPDISCOVER packets are broadcasted (255.255.255.255) and routers will not forward broadcast packets.  Therefore, in order to pass DHCP traffic across subnets the `dhcpd`(sdc-booter) service will be modified to handle DHCP option 82 (See RFC 3046), which provides the ability to configure a circuit id.  When the `dhcpd` zone recieves a relayed packet with DHCP option 82 set, it will treat the circuit ID as a nictag and provision a nic on a network within the 'admin' network pool with that nictag.  The development work involved includes the ability of the sdc-booter to parse DHCP option 82, and lookup the appropriate network from an "admin" network pool.  To increase performance the dhcp server will cache the "admin" network pool's networks, and update this cache every 60 seconds (configurable).  Asynchronous cache updates will occur at init time and upon a cache miss.

```
            DHCP Server                  DHCP Relay                  Booting CN
                +                            +                            +
                |                            |       DHCPDISCOVER         |
                |                            <----------------------------+
                |  DHCPDISCOVER with NICTAG  |                            |
                <----------------------------+                            |
                |                            |                            |
+---------+     |                            |                            |
|         <-----+                            |                            |
|  NAPI   |     |                            |                            |
|         +----->                            |                            |
+---------+     |   DHCPOFFER with NICTAG    |                            |
                +---------------------------->                            |
                |                            |         DHCPOFFER          |
                |                            +---------------------------->
                |                            |                            |
                |                            |                            |
                |                            |                            |
                +                            +                            +

``` 

## Multi-subnet Admin Network Deployment Considerations

_many of these could be implemented as future work_

* When a new admin subnet is deployed the HN, and any other CNs in on different subnets will need new static routes to the new admin subnet before any of the CNs on the new subnet are booted.
* The NTP server's config file, `/etc/inet/ntp.conf`, will need to be modified to allow other admin subnets to query it.  Example:
```
restrict 10.99.99.0 mask 255.255.255.0
restrict 10.222.222.0 mask 255.255.255.0
```
* Apply firewall rules to allow traffic to core services from the new rack(subnet). [RFD 117 Network Traits](../0117/README.md) would be useful here. Example:
```
{
    "description": "SDC zones: allow all TCP from admin_rack99 net",
    "enabled": true,
    "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
    "rule": "FROM subnet 10.222.222.0/24 TO tag \"smartdc_role\" ALLOW tcp PORT all"
}
```
* Each admin subnet must have a gateway defined in its NAPI network properties. 
* Admin networks are automaticaly re-created when they go missing.  Therefore, multi-subnet admin networks need to be part of the initial DC deployment, otherwise any new admin network nics on the same subnet will conflict (DAD) with the new admin network nics.
* Fabrics will need to be enabled `sdcadm post-setup fabrics` or booter's config will need to be modified to set `disableBootTimeFiles: false`.  Going forward we may make this the default.


## Assumptions
* A TOR switch with DHCP relay capability will be used to route traffic for each of the admin subnets. 
* The "admin" network pool will only contain a single network per nictag.


## Implementation
One main issue is that most services and configuration scripts require at least one CN nic to have the nictag 'admin'

The convention throughout SDC is to use the format: 
'<tag>_nic=<mac addr>'
to denote which nic should be assigned which nictag.

Initially the approach was to simply override 'admin_xxx' with the admin network's properties (i.e. xxx == ip, mac, etc so that admin_nic=<mac address of admin_rack99_nic>).  Unfortunately that won't work because as noted above most of the configuration processing code use the actual property name as a tag name 'foo_nic' for 'foo' nictag.  When we run `nictagadm list` we will see:

```
NAME           MACADDRESS         LINK           TYPE            
admin_rack99   d2:9c:54:2c:8c:a4  vioif0         normal          
admin          d2:9c:54:2c:8c:a4  vioif0         normal   
```

So any agents looking for the CN's nictags will see a single nic tagged with two different tags.  This may lead other agents and services to believe the CN is on the "admin" subnet(NAPI network), when it is really only on the "admin_rack99" subnet(NAPI network).

This leaves us with two possible approaches:
a) modify the existing behavior of every script that parses 'admin_nic' as '<nictag>_nic'

OR

b) Add a new property "admin_tag" to denote an alternately tagged admin network (e.g. "admin_tag=admin_rack99".  Then in each script that parses the usbkey or networking.json config we could have the value of "admin_tag" override the string "admin" in the results.  Said another way, if "admin_tag" is set, any configuration file consumers will essentially ignore values of the form "admin_XXX", unless "admin_tag=admin" (which would be the default behavior, and there would be no use in actually setting that...).  So if "admin_tag=admin_rack99" then the configuration file consumers would use values of "admin_rack99" instead of those from "admin".  `nictagadm` would simply skip over anything of the form "admin_XXX".

Currently (b) is the preferred approach because it keeps the changes well partitioned, and backwards compatible.  Also docs that refer to the current property format (<tag name>_nic=<mac addr>) would still be valid. (e.g. https://wiki.smartos.org/display/DOC/extra+configuration+options)


There is a general desire to move the CN networking configuration towards being completely contained in the `networking.json` file received from the booter (dhcpd service).  With this in mind, a new property "admin_tag" will be added to the networking.json file.  This property will be set to the nictag value of the admin NIC. 

In the `usbkey/config` or `node.config` files the same property will be valid:
```
    admin_tag=<some nic tag>
```
