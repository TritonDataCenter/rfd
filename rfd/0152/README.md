---
authors: Rui Loura <rui@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+0152%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent Inc.
-->


# RFD 152 Rack Aware Networking

## Overview
Currently the Triton datacenter assumes many of it's common and/or required
networks are on the same L2 broadcast domain (e.g. `admin`, `manta`,
`external`).  In an effort to increase bandwidth availability, shrink fault
domains, and reduce centralization in the datacenter network we will be moving
to a Clos topology.  Once this work is complete each rack in a Triton
datacenter will be on it's own L3 network.

## Approach
With the introduction of [RFD 43 Rack Aware Network
Pools](https://github.com/joyent/rfd/tree/master/rfd/0043), NAPI networks
grouped into pools can have different nictags.  This then allows a NIC to be
provisioned by providing NAPI with a network pool UUID and a nictag as
parameters.  NAPI will select the correct network from the pool that matches
(among other things) the NIC tag specified.  

In a "Rack Aware Networking" environment each CN will have its NICs tagged with
the nictag that associates the rack the CN is in with the appropriate NAPI
network.  Post RFD 117 these networks and NICs will have traits which can be
leveraged to allow for identification of network type (e.g. admin, manta, etc).
For now we will be leveraging the format of the nictag to determine which
reserved NAPI network a given NIC belongs to.  The namespace of this format is:
`<network name>_rack_<rack id>`.  Where `<rack id>` can be any combination
of alphanumeric characters and "-" or "_".   Below is an example for the
`manta` network:

MANTA network pool:
```
[
  {
    "family": "ipv4",
    "uuid": "7306b0bd-c250-4336-bc9b-c0a06e382560",
    "name": "manta",
    "networks": [
      "cdadfce6-269a-4d4d-b73d-a18c13150cca",
      "b0152d14-5744-4255-ab43-b2d7f0f1dc28"
    ],
    "nic_tags_present": [
      "manta_rack_100",
      "manta_rack_222"
    ],
    "nic_tag": "manta_rack_100"
  }
]
```

MANTA_RACK_100 network
```
{
  "mtu": 1500,
  "nic_tag": "manta_rack_100",
  "name": "manta_rack_100",
  "provision_end_ip": "192.168.100.250",
  "provision_start_ip": "192.168.100.5",
  "subnet": "192.168.100.0/24",
  "uuid": "b0152d14-5744-4255-ab43-b2d7f0f1dc28",
  "vlan_id": 0,
  "resolvers": [],                                                    
  "routes": {                                                         
    "192.168.222.0/24": "192.168.100.1"                               
  },                                                                  
  "owner_uuids": [                                                    
    "4d649f41-cf87-ca1d-c2c0-bb6a9004311d"                            
  ],                                                                  
  "netmask": "255.255.255.0"                                          
}                                                                     
```

`sdc-napi /nic_tags`
```
  {
    "mtu": 1500,
    "name": "manta_rack_100",
    "uuid": "60fdba38-9bf4-455c-bd60-15ac7cc0dcec"                    
  },                                                                  
    {                                                                 
    "mtu": 1500,                                                      
    "name": "manta_rack_222",                                         
    "uuid": "27d610be-9ab0-4341-bf3a-ffdf70d2ce60"
  },

```

```                                                                   
Rack 100                             Rack  222                        
L3: 192.168.100.0/24                 L3: 192.168.222.0/24             
+------------------------------+     +------------------------------+ 
|             TOR              |     |             TOR              | 
+------------------------------+     +------------------------------+ 
| CN0 NIC_TAG: "MANTA_RACK_100"|     | CN2 NIC_TAG: "MANTA_RACK_222"| 
+------------------------------+     +------------------------------+ 
| CN1 NIC_TAG: "MANTA_RACK_100"|     | CN3 NIC_TAG: "MANTA_RACK_222"| 
+------------------------------+     +------------------------------+ 
```    


### Admin Networks                                                     
                                                                      
The "admin" network represents a special case.  Compute Nodes use iPXE and DHCP
to boot.  Unfortunately DHCPDISCOVER packets are broadcasted (255.255.255.255)
and routers will not forward broadcast packets.  Therefore, in the case where
CNs are booted from within a rack separate from the AZ's HN, a DHCP relay is
required.  To satisfy this requirement we plan to leverage DHCP option 82 (See
RFC 3046).  This option provides the ability to configure a "circuit id".  

This circuit id will be configured to specify a rack identifier (noted above) 
which can be associated with NAPI network nictag.  The nictag will then be passed as a parameter to NAPI along with the admin network pool UUID to provision a NIC for the booting CN.


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

### High Level Tasks
* Booter zone enhancements to recognize DHCP option 82, and to cache 'admin'
network pool information to avoid overloading NAPI when multiple CNs are booted
at once.
* Common module creation to provide NIC and IP lookup functions for a given
network and set of information.  This will need to be done for VM metadata as
well as CN sysinfo.
* Update all services, agents, and tools to leverage the lookup functions in
the common module.
* Updating config-agent to properly populate `autoMetadata.<NETWORK>_IP` 

### Triton Common Module

Part of this work includes the creation of a module which will provide common
functions for all Triton and Manta services.  Initially it should provide the
following functionality:  

* Given a NAPI network pool, network, or NIC object (or names or uuids there
of), determine which reserved network it is associated with.
* Given a CN's UUID or sysinfo find the IP and mac address of a given reserved
network (e.g. admin IP), or determine if a given NIC is attached to a reserved
network, and if so which one.
* Given a VM's UUID or metadata find the IP and mac address of a given reserved
network (e.g. admin IP), or determine if a given NIC is attached to a reserved
network, and if so which one.

(Note: RFD 117 will outline which networks will be internally reserved by the
 Triton infrastructure, for now the assumption is that these will include at a
 minimum 'admin', 'manta', and 'external')


This will provide us with the ability to alter the mechanism for determining
the NICs and IPs of various networks in a central location without requiring
subsequent modifications to all affected Triton and Manta services, agents, and
tools.

This module can later be extended to provide other Triton and Manta common
functionality unrelated to Rack Aware Networking.


## Assumptions and Configuration Considerations

* The nodes in a rack aware AZ will connected via routers that are capable of
relaying DHCP messages and adding DHCP option 82 to DHCPDISCOVER messages. 

* Networks of the same type (e.g. admin) will be configured with routes to
other networks of the same type.

* The NTP server will be properly configured to allow for configuration of all
subnets in the admin network.

* Firewall rules will be set to allow for communication between networks of the
same type.

## References

* [RFC 3046](https://tools.ietf.org/html/rfc3046)
* [RFD 43](https://github.com/joyent/rfd/blob/master/rfd/0043/README.md)
* [RFD 117](https://github.com/joyent/rfd/blob/master/rfd/0117/README.md)
