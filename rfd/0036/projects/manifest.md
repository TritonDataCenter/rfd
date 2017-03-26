<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Project manifest

The project manifest defines all the services of a project, as well as other details that may be added in time. Each project has a single active manifest that defines the expected state of the entire project.

The `tags` fields is optional. If provided, these manifest tags will be accessible via the Triton CLI, and able to be filtered upon in project list operations. 

```yaml
defaults:
    network: <network name>
    public_network: <network name or uuid>
cns:
    namespace:
		    # "public" is a reserved name for
		    # the default public network
        public: mydomain.example.com
        <network name>: <domain space>
    # the service name to point queries for
    # the top of the namespace
    primary_service: <service name>
    ttl: 5m # default TTL for all services
tags:
    - <tag name> = <tag value>
    - <tag name> = <tag value>
    - <tag name> = <tag value>
services:
    <name>:
        description: <textual description>
        service_type: continuous
        compute_type: docker
        image: autopilotpattern/nginx:latest
        resources:
            package: g4-highcpu-512M
            max_instances: 150
        environment:
            - ES_HEAP_SIZE={{ .package.ram }}
        mdata:
            - com.example.cluster-name={{ .cns.svc.public }}
        containerpilot: true
        start:
            parallelism: 2
            window: 3m
        restart:
            - on-failure
            - on-cn-restart
        placement:
            cn:
                - service!=~<this service name>
                - service=~<another service name>
        networks:
            - <network name>
        public_network:
            - <network name or UUID>
        cns:
            services:
                - <service name>
            ttl: <duration> # overrides default
            hysterises: <duration> # extended period of unhealth before removing an instance from DNS
        ports:
            - 80
            - 443
        tags:
            - <tag name> = <tag value>
            - <tag name> = <tag value>
            - <tag name> = <tag value>
        logging:
            driver: syslog
            options:
                syslog-address: "tcp://192.168.0.42:123"
        volumes:
            - <volume name>:<mount point in instance>
vlans:
    <name>:
        description: <textual description>
        # VLAN IDs must be automatically generated
networks:
    <name>:
        description: <textual description>
        vlan: <name>
        subnet: <cidr>
        gateway: <ip addr>
        resolvers: # default is 8.8.8.8 and 8.8.4.4
            - <ip addr>
            - <ip addr>
        nat-enabled: <falsey> # NAT is on by default, the only useful value here is false
firewalls:
    <name>:
        description: <textual description>
        from: (any|<(project|network|tag|instance) name|id>)
        to: (any|<(project|network|tag|instance) name|id>)
        allow: <rule>
        deny: <rule>
        enabled: <truthy>
volumes:
    <name>:
        description: <textual description>
        network:
            - <network name>
            - <network name> # one or multiple networks may be specified
        size:
        placement:
            cn:
                - service!=~<service name>
unmanaged_instances:
    <name>:
        description: <textual description>
        compute_type: kvm
        image: ubuntu:16.04
        package: g4-highcpu-512M
        mdata:
            - com.example.es-node-master=true
        networks:
            - <network name>
        tags:
            - <tag name> = <tag value>
            - <tag name> = <tag value>
```

[Reference the service manifest documentation](../service/manifest.md) for services details.

Additional object types that might be expected in future iterations of the project manifest include [network fabrics](https://docs.joyent.com/public-cloud/network/sdn), [firewall rules](https://docs.joyent.com/public-cloud/network/firewall), CNS domains, [RFD26 volumes](https://github.com/joyent/rfd/blob/master/rfd/0026/README.md), and Manta storage "buckets".


## Manifest format

Though JSON is the preferred data interchange format throughout Triton, the inability to support inline comments has proven challenging in ContainerPilot. Those comments are more than a convenience, they're critically needed for inline documentation. This is especially true in operations where small changes can make the difference between smooth running and miserable disaster.

Given that, the default format for the project and service manifest is YAML, and efforts should be made to preserve in their entirety the valid, YAML-formatted manifest file submitted by the user.