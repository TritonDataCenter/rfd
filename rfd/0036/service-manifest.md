# Service manifest

## `service_type`

Required

- `continuous` (default)
- `scheduled`
- `event`

MVP: Only `continuous`

## `compute_type`

Required

- `docker` (default)
- `infrastructure|lx|smartmachine`
- `kvm|vm|hvm`
- `manta`

## `image`

Required for all compute types except `manta`

This could be:

- a Docker image (resolved using normal rules in sdc-docker)
- the name of an image in imgapi
- the uuid of an image in imgapi

Example: `0x74696d/triton-elasticsearch:0.1.1`

## `package`

Optional

Can specify:

- a package name
- a package uuid
- a package family, by name

## `memory`

Optional

- If `compute_type==manta`, this is the requested DRAM cap for the Manta job.
- If `package` is omitted, or if `package` specifies a family, the smallest package that satisfies this DRAM value will be chosen.

## `labels`

Alias for `tags`

## `tags`

Optional

Example:

- `triton.cns.services=elasticsearch-master`

## `affinity`

Optional

From DOCKER-630. Affinity filters are one of the following

- Filter on instance names: `container<op><value>`
- Filter by instance labels/tags: `<tag name><op><value>`

`<op>` is one of:

- `==`: The new container must be on the same node as the container(s) identified by `<value>`.
- `!=`: The new container must be on a different node as the container(s) identified by `<value>`.
- `==~`: The new container should be on the same node as the container(s) identified by `<value>`. I.e. this is a best effort or "soft" rule.
- `!=~`: The new container should be on a different node as the container(s) identified by `<value>`. I.e. this is a best effort or "soft" rule.

`<value>` is an exact string, simple `*`-glob, or regular expression to match against container names or IDs, or against the given label name.

Examples:

```
- affinity
  container==silent_bob # Run on the same node as silent_bob
  role!=database # Run on a different node as all containers labelled with 'role=database'
  container!=foo* # Run on a different node to all containers with names starting with "foo":
  container!=/^foo/ # Same as above, with regular expression
```

Multiple filters are allowed for a single service, though mixing of "soft" and "hard" filters is not supported. All "hard" filter rules must be fully satisfied for the instance provisioning to succeed.

## `ports`

Optional

As with sdc-docker, this infers that the instance will have an interface on the "public" network, and that fwapi will open the specified ports.

Example:

- 8500

## `dns`

Optional

If the user desires to set custom resolvers

## `dns-search`

Optional

The default should include `<account uuid>.<datacenter name>.cns.joyent.com`, or whatever CNS is set to

## `environment`

Optional

Environment vars that will be passed to the instance. These are passed to Docker containers as expected, for infrastructure containers and KVM, they're passed to the user script.

Example:

- ES_SERVICE_NAME=elasticsearch-{{ .meta.metakey }}
- CLUSTER_NAME=elasticsearch
- ES_HEAP_SIZE={{ .package.ram }}
- ES_NODE_MASTER=true
- ES_NODE_DATA=true
- CONTAINERPILOT=file:///etc/containerpilot.json

Variable replacement:

- `meta`: project metadata ([defined above](#metadata-management))
- `package`: Package details, including RAM, disk, "CPU", package name, package family
  - `ram`
  - `disk`
  - `cpu`: some sort of value that can be used to approximate the number of CPUs that should be scheduled
  - `name`
  - `family`
- `cns`: The Triton CNS names
  - `svc`
    - `public`: The FQDN of this service pointing to the public interface
    - `private`: The FQDN of this service pointing to the "private" interface
    - `<user fabric network name>`: The FQDN of this service pointing to the interface on the named network
    - `<network uuid>`: The FQDN of this service pointing to the interface on the named network
  - `inst`
    - `public`
    - `private`
    - `<user fabric network name>`
    - `<network uuid>`
  - `prefix`
    - `public`
    - `private`
    - `<user fabric network name>`
    - `<network uuid>`
- `service`: information about the current service
  - `name`
  - `uuid`
  - `version`: the uuid of the service version at the time the instance is provisioned

## `entrypoint`

Optional

Only supported for Docker containers. All other compute types will ignore or error with this.

Example:

- `/some/executable.sh`

## `command`

Optional (though maybe required for Manta jobs?)

For `compute_type`:

- `docker`: as expected
- `infrastructure`: sent as user script
- `kvm`: sent as user script
- `manta`: the [Manta job `exec`](https://apidocs.joyent.com/manta/jobs-reference.html#job-configuration)

Example:

``` bash
/bin/containerpilot \
/usr/share/elasticsearch/bin/elasticsearch \
--default.path.conf=/etc/elasticsearch
```

## `containerpilot`

Optional

This tells Mariposa how to connect to ContainerPilot's [telemetry interface](https://www.joyent.com/blog/containerpilot-telemetry). Telemetry will eventually expose all ContainerPilot state, including healthchecks and upstreams, in addition to the user-defined performance metrics. The state of instances can be aggregated by the scheduler and used to manage the overall application.

```
- containerpilot
    - network: <network name|uuid>
    - port
```

## `healthchecks`

Optional

Healthchecks are run on the specified poll frequency on each instance of the service. If a service fails after the specified retries, the instance will be declared unhealthy, stopped, and a new instance provisioned for the service.

If the ContainerPilot details are configured, the scheduler should automatically detect and use the ContainerPilot health checks, in addition to any user-specified health checks here. **Implemention note:** the ContainerPilot health-checks, upstreams, etc. can change after initial launch of the container. Mariposa must be able to accomodate these changes.

Supported types:

- `http|https`: executed in the user's NAT zone connected to the service's network; will error if the user has no NAT zone on the specified network.
- `command`: executed inside the instance.

Additional details are required for each type. Appropriate limits need to be identified for the number of health checks on a single service and their maximum timeout.

Example:

```yaml
  - type: https # the request is made from the user's nat zone
    network: network name/uuid # optional, default is "public"; the network (including user fabric netwokrs) on which the service is listening
    port: 443 # optional, defaults to 80 or 443 based on healthcheck type
    path: /some/path/on/container
    poll: 30
    timeout: 10
    retries: 3

  - type: command # the command is run in the container (only supported for non-KVM)
    command: /usr/sbin/some_executable # any non-zero output is a failure
    user: root
    poll: 30
    timeout: 10
    retries: 3
```

## `restart`

Optional

This has a complex relationship with health checks and service type (`continuous|scheduled|event`) that needs further definition.

Scenario:

The CN on which a `service_type=continuous` instance is provisioned goes offline. This should cause Mariposa to attempt to provision a replacement instance on another CN (because the services healthchecks failed and Mariposa is aware that the CN is offline). If the CN then restarts, and the instance is set to restart, this will result in overcapacity for that service's scale. The user expects Mariposa to scale down the number of instances using the policy described in `triton service scale`.

Values:

- `no`
- `on-failure[:max-retry]`
- `always`
- `unless-stopped`

Adopts the [Docker's options and logic](https://docs.docker.com/engine/reference/run/#restart-policies-restart).

## `autoscale`

Optional

Not required for MVP

A group of sub-options that configure how the scheduler handles scaling triggers (defined elsewhere in the manifest).

- `enable`: Default is `notify|notify-only`; can also be `true|1` or `false|0`
- `min`: The minimum number of instances of the service; default is `1`
- `max`: The maximum number of instances, but how
- `retrigger_delay`: The amount of time to wait after a scaling event before aknowledging new events; default is `60s`
- `notify_email`: one or more email addresses to notify when scaling events are triggered

## `triggers`

Triggers, called "alerts" by some providers, define the threshold performance values on which to scale up or down. Triggers can use any metric exposed by [Container Monitor](https://github.com/joyent/rfd/blob/master/rfd/0027/README.md) or [ContainerPilot](https://www.joyent.com/blog/containerpilot-telemetry). Additionally, the Container Monitor and ContainerPilot metrics of other services in the same project can be used as triggers (example: scaling DB instances based on request latency reported by the main app).

Example:

```
- triggers
    - highram # the user-specified trigger name
        metric: containermonitor.ram_used
        operator: >
        value: 80%
        time: 5 minutes
        action: increment # incr|decrement|decr
        instances: 1
    - lowutilization
        source: containerpilot.tps
        operator: <
        value: .3
        time: 2 minutes
        action: decr # increment|incr|decrement
        instances: 1
    - highlatency
        source: service.another_servicename.containerpilot|containermonitor.dblatency
        operator: >
        value: 90
        time: 3 minutes
        action: increment # incr|decrement|decr
        instances: 1
```

## `stop`

Optional

Controls the instance behavior when it stops. Sub-options include:

- `timeout`: the stop timeout expressed as an integer number of seconds; negative numbers will wait indefinitely
- `preservestopped`: `on-failure` (default); will not automatically delete stopped instances if they exit with a non-zero status; also supports `no` and `always`

Example:

```yaml
  - timeout: -1
  - preservestopped: always
```

## `webhooks`

Not required for MVP, needs additional definition, including of the `POST` payload in these hooks.

Optional

See [Docker events](https://docs.docker.com/engine/reference/commandline/events/), [Mesos events](https://mesosphere.github.io/marathon/docs/rest-api.html#event-subscriptions) and [Singularity webhooks](https://github.com/HubSpot/Singularity/blob/master/Docs/reference/webhooks.md).

Events to consider:

- `start`: sent when an instance of the service is started. This should use similar rules to CNS.
- `stop`: sent when an instance of the service is stopped. This should use similar rules to CNS.
- `health`: sent whenever a container fails all retries of its healthchecks.

## `triggers`

Not required for MVP, needs additional definition

Optional

Triggers are public-facing URLs that allow unsophisticated integrations with other systems. These are exposed by the application operator and have user-defined names and secrets.

Supported actions:

- `start`
- `stop`
- `scale`

## `schedule`

Not required for MVP, needs additional definition

Optional

Only used for `service_type=scheduled`

Needs definition. [Singularity](https://github.com/HubSpot/Singularity) uses [ISO 8601](https://en.wikipedia.org/wiki/ISO_8601#Time_intervals), which appear easier to express in JSON/YAML than most `crontab` formats, but....

## Manifest input formats

Ideally, we will support importing both YAML and JSON formatted manifests. YAML's key advantage over JSON is support for inline comments. The forgoing does not imply a requirement to store manifests in anything other than JSON format, or preserve comments that may be present in imported YAML files.
