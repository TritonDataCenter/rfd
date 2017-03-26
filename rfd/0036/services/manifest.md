<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Service manifest

The service manifest is a component of the project manifest. Each service has a single active manifest that defines the expected state of the service.

Each of the following options is in the context of the larger project manifest:

```yaml
services:
  <service name>:
    <option>: <value>
    <option>: <value>
  <service name>:
    <option>: <value>
    <option>: <value>
```

Options avalailable for services include:

## `service_type`

Required

- `continuous` (default)
- `scheduled`
- `event`

MVP: Only `continuous`

Example:

```yaml
service_type: continuous
```

## `compute_type`

Required

- `docker` (default)
- `infrastructure|lx|smartmachine`
- `kvm|vm|hvm`
- `manta`

```yaml
compute_type: docker
```

## `image`

Required for all compute types except `manta`

This could be:

- a Docker image (resolved using normal rules in sdc-docker)
- the name of an image in imgapi
- the uuid of an image in imgapi

Example:

```yaml
image: 0x74696d/triton-elasticsearch:0.1.1
```

## `resources`

Optional

Used to specify the package type for all instances of a service, and maximum number of instances of the service.

Options:

- `package`: `<package name|uuid>`
- `max_instances`: `<integer>`, negative values unlimit the count; default is `-1`

Example:

```yaml
resources:
  package: g4-highcpu-512M
  max_instances: 50
```

## `tags`

Optional

Example:

```yaml
tags: 
  - com.example.tag: "A tag that will be appled to all instances of the service"
  - triton.cns.services=elasticsearch-master
```

## `placement`

Optional

Allows users to control (or guide) the placement of containers based on a number of constraints. As instances are being provisioned, the placement constraints can limit them to compute nodes, racks, or data centers that match (including negative match) user specified criteria.

Scopes:

- `cn`, `compute_node`, or `node`: evaluates only against the characteristics of the compute node
- `rack`: for future use, not an MVP feature
- `dc` or `data_center`: for future use, not an MVP feature

Criteria:

- `project`: matches other projects within the same organization only
- `project:<tag name>`: matches the tags on other projects within the same organization only
- `service`: matches services within the same project only
- `service:<tag name>` matches tags on services within the same project only
- `volume`: matches volumes within the same project only
- `volume:<tag name>` matches tags on volumes within the same project only
- `cn:<tag name>`: matches a CN with a specified tag
- `cn:<uuid>`: matches a given CN UUID

Operators:

- `==`: The new container must be on the same node as the container(s) identified by `<value>`.
- `!=`: The new container must be on a different node as the container(s) identified by `<value>`.
- `==~`: The new container should be on the same node as the container(s) identified by `<value>`. I.e. this is a best effort or "soft" rule.
- `!=~`: The new container should be on a different node as the container(s) identified by `<value>`. I.e. this is a best effort or "soft" rule.

`<value>` is an exact string, simple `*`-glob, or regular expression to match against container names or IDs, or against the given label name.

Some rules and operators in context:

- `container==silent_bob` Run on the same node as silent_bob
- `role!=database` Run on a different node as all containers labelled with 'role=database'
- `container!=foo*` Run on a different node to all containers with names starting with "foo":
- `container!=/^foo/` Same as above, with regular expression

Examples:

```
placement:
	cn|compute_node:
		# do not place on a compute node with the specified project name
		- project!=<project name>
		# try to avoid CNs with the specified service (soft rule, must be a service in this project)
		- service!=~<service name>
	rack: # not an MVP feature
		# require that the instance be in the same rack as a CN with a specified tag (but not necessarily on that CN)
		- cn:<tag name>==<tag value>
	dc|data_center: # not an MVP feature
		# do not provision in a DC that also has a project with a given tag (only evals against projects in this org)
		- project:<tag name>!==<tag value>
```



## `ports`

Optional

As with sdc-docker, this infers that the instance will have an interface on the "public" network, and that fwapi will open the specified ports. The "public" network will be either the default public network for the project, or network specified in `public_network`.

Examples:

```
ports:
  - 8500
```

Alternatively, these can be specified as a dictionary with network names and ports:

```
ports:
	<network name>
	  - 80
	  - 443
	<network name>
	  - 8500
```



## `dns`

Optional

If the user desires to set custom resolvers

Example:

```
dns:
  - 127.0.0.1
```



## `dns_search`

Optional

The default must include `<account uuid>.<datacenter name>.cns.joyent.com`, or whatever CNS is set to

Example:

```
dns_search:
  - my.example.com
```



## `environment`

Optional

Environment vars that will be passed to the instance. These are passed to Docker containers as expected, for infrastructure containers and KVM, they're passed to the user script. Environment variables are subject to project variable and metadata interpolation.

Example:

```yaml
environment:
  - ES_SERVICE_NAME=elasticsearch-{{ .meta.metakey }}
  - CLUSTER_NAME=elasticsearch
  - ES_HEAP_SIZE={{ .package.ram }}
  - ES_NODE_MASTER=true
  - ES_NODE_DATA=true
  - CONTAINERPILOT=file:///etc/containerpilot.json
```



## `mdata`

Optional

[Mdata](https://eng.joyent.com/mdata/datadict.html) values can be checked (and in some cases set) via the [mdata CLI tools](https://github.com/joyent/mdata-client). Mdata   variables are similar to environment variables, but there are some differences:

- Unlike environment variables, mdata can be updated while an instance is running. 
- In cases where an mdata values reference project variables or metadata, **the returned value is the current state of the project variables or metadata**, not the value at the time the instance was provisioned.

Example:

```yaml
mdata:
  - com.example.es-node-master=true
  - com.example.cluster-name={{ .cns.svc.public }}
```



## `entrypoint`

Optional

Only supported for Docker containers. All other compute types will ignore or error with this.

Example:

```yaml
command: /some/executable.sh
```



## `command`

Optional (though maybe required for Manta jobs?)

For `compute_type`:

- `docker`: as expected
- `infrastructure`: sent as user script
- `kvm`: sent as user script
- `manta`: the [Manta job `exec`](https://apidocs.joyent.com/manta/jobs-reference.html#job-configuration)

Example:

```yaml
command:
  /bin/containerpilot \
  /usr/share/elasticsearch/bin/elasticsearch \
  --default.path.conf=/etc/elasticsearch
```



## `containerpilot`

Optional

This tells Mariposa how to connect to ContainerPilot's [telemetry interface](https://www.joyent.com/blog/containerpilot-telemetry). Telemetry will eventually expose all ContainerPilot state, including health checks and upstreams, in addition to the user-defined performance metrics. The state of instances can be aggregated by the scheduler and used to manage the overall application.

Examples:

```yaml
containerpilot:
    - network: <network name|uuid> # defaults to the project's default fabric
    - port: 9090 # defaults to 9090
```

To use the default network and port, it is enough to simply declare a truthy value:

```yaml
containerpilot: true
```



## `healthchecks`

Optional

Health checks are run on the specified poll frequency on each instance of the service. If the health check is unsuccessful after the specified retries, the instance will be declared unhealthy, stopped, and a new instance provisioned for the service.

If the ContainerPilot details are configured, the scheduler should automatically detect and use the ContainerPilot health checks, in addition to any user-specified health checks here. **Implemention note:** the ContainerPilot health-checks, upstreams, etc. can change after initial launch of the container. Mariposa must be able to accommodate these changes.

The `ServicesHealth` agent responsible for running health checks will run in a NAT zone associated with the project that is connected to the service's network.

Supported types:

- `http|https`: makes a request to the given URL and validate response code. Any HTTP 200 response is healthy; and other response is unhealthy.
- `tcp`: verifies that a service is accepting tcp connections on a given port.
- `command`: (only valid for Docker images) executes the specified test command in the container. An exit code of zero is healthy; any other exit code is unhealthy.

Additional details are required for each type. Appropriate limits need to be identified for the number of health checks on a single service and their maximum timeout.

Example:

```yaml
healthchecks:
    <name>
        - type: (http|https)
        - network: <network name/uuid> # optional
        - port: 443 # optional, defaults to 80 or 443 based on healthcheck type
        - path: /some/path/on/container
        - interval: 30
        - timeout: 10
        - retries: 3
    <name>
        - type: tcp
        - network: <network name/uuid> # optional
        - port: 9078 # required
        - interval: 30
        - timeout: 10
        - retries: 3
    <name>
        - type: command
        - command # the command to run in the container
        /usr/bin/mysql \
            -u wpdbuser -sN \
            wp -e "SELECT COUNT(1) FROM wp_posts;"
        - interval: 30
        - timeout: 10
        - retries: 3
```



## `start`

Optional

This policy affects normal startup, restarts, and scaling attempts.

- `parallelism`: `<integer>` the number of instances to attempt to start, scale, or replace simultaneously; default `1`
- `window`: `<duration>` the maximum time to wait after the start attempt before starting `healthchecks` on the instance; default `60s`


```
start:
    parallelism: 1
    window: 60s
```



## `restart`

Optional

Defines the behavior for restarting individual instances of a service. If an instance fails, it will be restarted according to the policy here. At the exhaustion of the restart policy, this instance will be abandoned and a new instance will be provisioned to replace it (called reprovisioning in Mariposa).

Upon restart of an instance, the start window is reset before health check attempts are restarted.

Options:

- `condition`: one or more of:
	- `(no|never)`: never attempt to restart the instance (not compatible with other values)
	- `on-failure`: (default) attempt to restart if the health check fails or if PID 1 (in a container) exits non-zero (can be combined with others)
	- `on-cn-restart`: (default) attempt to restart the instance when the compute node is restarted (can be combined with others)
	- `always`: attempt to restart the container regardless of the conditions that caused it to stop, including the normal exit of PID 1 (includes `on-failure` and `on-cn-restart`,  not compatible with other values)
- `max_attempts`: `<integer>` number times to attempt to restart a container before giving up; default: `3`
- `window`: `<duration>` Maximum time after a restart (or start) attempt to wait before deciding if the start has succeeded; default `60s`


Example:

```yaml
restart:
    condition:
        - on-failure
        - on-cn-restart
    max_attempts: 3
    window: 90s
```



## `stop`

Optional

Controls the instance behavior when it stops. Sub-options include:

- `timeout`: the stop timeout expressed as an integer number of seconds; negative numbers will wait indefinitely; default is `10s`
- `preservestopped`: will not automatically delete stopped instances if they exit; supports the same options as the restart policy; default is `on-failure`

Example:

```yaml
stop:
    - timeout: 10s
    - preservestopped:
        - on-failure
```



## `logging`

Optional

Logging configuration. Only supported for Docker containers in MVP.

```
logging:
	driver: syslog
	options:
		syslog-address: "tcp://192.168.0.42:123"
```



## `networks`

Optional

The list of network names or IDs to attached to every instance of this service. Defaults to the default network for the project.

Examples:

```
networks:
	- <network name>
	- <network name>
	- <network name>
```



## `public_network`

Optional

The network name or ID to treat as public for any open ports for this service. Defaults to the default public network for the project. If `ports` are defined for the service, the service will be attached to this network, and those ports will be opened on it.

Examples:

```
public_network:
	- <network name>
```



## `cns`

Optional

Triton Container Name Service automated DNS details.

Options:

- `services`: `<service name>`; multiple may be specified; if no service names are specified, the default is the Mariposa service name
- `ttl`: `<duration>`; overrides the default set in the top-level CNS directive for the project
- `hysteresis`: `<duration>` an extended period of unhealth before stopping advertisement of an instance in CNS/DNS

Example:

```
        cns:
            services:
                - <service name>
            ttl: <duration>
            hysterises: <duration>
```



## `firewalls`

Optional

Specifies firewall rules to apply to instances of the service.

Examples

```
firewalls:
	- <firewall name>
	- <firewall name>
	- <firewall name>
```



## `volumes`

Optional

Specifies an attachment and mount point for an RFD26 volume.

```
volumes:
	- <volume name>:<mount point in instance>
```



## `monitors`

Not required for MVP.

Monitors, called "alerts" by some providers, define the threshold performance values on which to scale up or down. This implements autoscaling (alternate spellings, for people searching this doc: auto scaling and auto-scaling).

Monitors can use any metric exposed by [Container Monitor](https://github.com/joyent/rfd/blob/master/rfd/0027/README.md) or [ContainerPilot](https://www.joyent.com/blog/containerpilot-telemetry). Additionally, the Container Monitor and ContainerPilot metrics of other services in the same project can be used as triggers (example: scaling DB instances based on request latency reported by the main app).

Options:

- `metric`: `<name of metric>`
- `operator`: `<`,`>`,`=`,`<=`,or `>=`
- `value`: `<integer, real, or percent>`
- `sustain`: `<duration>`; optional, default is `90s`
- `action`: `(notify|increment|incr|decrement|decr)`; optional, default is `notify`
- `instances`: `<integer>`; optional, default is `0`
- `retrigger_delay`: `<duration>`; optional, default is `5m`


Examples:

```yaml
monitors:
    highram # the user-specified trigger name
        metric: containermonitor.ram_used
        operator: >
        value: 80%
        sustain: 5m
        action: notify
        instances: 1
        retrigger_delay: 5m
    lowutilization
        source: containerpilot.tps
        operator: <
        value: .3
        sustain: 2m
        action: decr
        instances: 1
        retrigger_delay: 60m
    highlatency
        source: service.another_servicename.containerpilot.dblatency
        operator: >
        value: 90
        sustain: 15s
        action: increment
        instances: 1
        retrigger_delay: 7m
```



## `webhooks`

Not required for MVP, needs additional definition, including of the `POST` payload in these hooks.

Optional

See [Docker events](https://docs.docker.com/engine/reference/commandline/events/), [Mesos events](https://mesosphere.github.io/marathon/docs/rest-api.html#event-subscriptions) and [Singularity webhooks](https://github.com/HubSpot/Singularity/blob/master/Docs/reference/webhooks.md).

Events to consider:

- `start`: sent when an instance of the service is started. This should use similar rules to CNS.
- `stop`: sent when an instance of the service is stopped. This should use similar rules to CNS.
- `health`: sent whenever a container fails all retries of its health checks.

Example:

```yaml
webhooks: XXX # Needs more detail
```


## `triggers`

Not required for MVP, needs additional definition

Optional

Triggers are public-facing URLs that allow unsophisticated integrations with other systems. These are exposed by the application operator and have user-defined names and secrets.

Supported actions:

- `start`
- `stop`
- `scale`

Example:

```yaml
triggers: XXX # Needs more detail
```


## `schedule`

Not required for MVP, needs additional definition

Optional

Only used for `service_type=scheduled`

Needs definition. [Singularity](https://github.com/HubSpot/Singularity) uses [ISO 8601](https://en.wikipedia.org/wiki/ISO_8601#Time_intervals), which appear easier to express in JSON/YAML than most `crontab` formats, but....

Example:

```yaml
schedule: XXX # Needs more detail
```
