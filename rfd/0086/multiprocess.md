## First-class support for multi-process containers

ContainerPilot currently "shims" a single application -- it blocks until this main application exits and spins up concurrent threads to perform the various lifecycle hooks. ContainerPilot was originally dedicated to the control of a single persistent application, and this differentiated it from a typical init system.

In v2 we expanded the polling behaviors of `health` checks and `onChange` handlers to include periodic `tasks` [#27](https://github.com/joyent/containerpilot/issues/27). Correctly supporting Consul or etcd on Triton (or any CaaS/PaaS) means requiring an agent running inside the container, and so we also expanded to include persistent `coprocesses`. Users have reported problems with ContainerPilot (via GitHub issues) that stem from two areas of confusion around these features:

- The configuration of the main process is via the command line whereas the configuration of the various supporting processes is via the config file.
- The timing of when each process starts is specific to which configuration block it's in (main vs `task` vs `coprocess`) rather than its dependencies.

#### Multiple services

In v3 we'll eliminate the concept of a "main" application and embrace the notion that ContainerPilot is an init system for running inside containers. Each process will have its own health check(s), dependencies, frequency of run or restarting ("run forever", "run once", "run every N seconds"), and lifecycle hooks for startup and shutdown.

For each application managed, the command will be included in the ContainerPilot `services` block. This change eliminates the `task` and `coprocess` config sections. For running the applications we can largely reuse the existing process running code, which includes `SIGCHLD` handlers for process reaping. Below is an example configuration, assuming we use YAML rather than JSON (see [config updates](config.md) for more details).

```yml
services:
  nginx:
    command: nginx -g daemon off;
    port: 80
    heartbeat: 5
    ttl: 10
    interfaces:
      - eth0
      - eth1
    depends:
      - consul_agent

  consul_agent:
    command: consul -agent
    port: 8500
    interfaces:
      - localhost
    advertise: false

health:
    nginx:
      check: curl --fail http://localhost/app
      poll: 5
      timeout: "5s"

```

_Related GitHub issues:_
- [Support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [Allow multiple health checks per service](https://github.com/joyent/containerpilot/issues/245)
- [Allow multiple commands for preStart](https://github.com/joyent/containerpilot/issues/253)
- [Prevent polling/coprocesses from being started multiple times](https://github.com/joyent/containerpilot/pull/198)
- [Coprocess hooks](https://github.com/joyent/containerpilot/issues/175)
- [preStart a background process](https://github.com/joyent/containerpilot/issues/157)
- [registering containers as separate nodes on Consul](https://github.com/joyent/containerpilot/issues/162)


#### Multiple health checks

ContainerPilot 3 will support the ability for a service to have multiple health checks. All health checks for a service must be in a passing state before a service can be marked as healthy. The service definition will be separated from the health check definition in order to support proposed [configuration improvements](config.md).

We'll make the following changes:

- ContainerPilot will maintain state for all services, which can be either `healthy` or `unhealthy`, and all health checks, which can be either `passing` or `failing`.
- All health checks must be marked `passing` before ContainerPilot will mark the service a `healthy`.
- A service in a `healthy` state will send heartbeats (a `Pass` message) to the discovery backend every `heartbeat` seconds with a TTL of `ttl`.
- A health check will poll every `poll` seconds, with a timeout of `timeout`. If any health check fails (returns a non-zero exit code or times out), the associated service is marked `unhealthy` and a `Fail` message is sent to the discovery service.
- Once any health check fails, _all_ health checks need to pass before the service will be marked healthy again. This is required to avoid service flapping.

**Important note:** end users should not provide a health check with a long polling time to perform some supporting task like backends. This will cause "slow startup" as their service will not be marked healthy until the first polling window expires. Instead they should create another service for this task.

```
consul:
  host: consul.svc.triton.zone

services:
  nginx:
    port: 80
    heartbeat: 5
    ttl: 10

health:
  nginx:
    check-A:
      command: curl -s --fail localhost/health
    check-B:
      command: curl -s --fail localhost/otherhealth

```


_Related GitHub issues:_
- [Support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [Allow multiple health checks per service](https://github.com/joyent/containerpilot/issues/245)


#### "No advertise"

Some applications are intended only for internal consumption by other applications in the container not should not be advertised to the discovery layer (ex. Consul agent). These applications can mark themselves as "no advertise." ContainerPilot will track the state of non-advertising applications but not register them with service discovery, so it can fire `onChange` handlers for other services that depend on it. In the example above, the Consul Agent will not be advertised but Nginx can still have it marked as a dependency.

_Related GitHub issues:_
- [Coprocess hooks](https://github.com/joyent/containerpilot/issues/175)
- [registering services w/o ports](https://github.com/joyent/containerpilot/issues/117)


#### Dependency management

Applications running under ContainerPilot have external dependencies, and the current design does not adequately account for the variety of dependencies we've encountered from users.

1. Applications may depend on an external service. For example an Nginx upstream or database.
2. Applications may depend on a local service (inside the container). For example it can't know the health of external dependencies without having the local Consul Agent.
3. Applications may depend on environment variables to be set.
4. Applications may depend on generated files that are not in the container image. For example Nginx with `consul-template` expects the rendered configuration to replace the one from the image.
5. Application dependencies may be hard: the application process can't start without the dependency without exiting.
6. Application dependencies may be quasi-hard: the application process can start without the dependency but the application can't operate correctly until the dependency becomes available (it might retry or poll for the dependency).
7. Application dependencies may be soft: the application process can start without the dependency and operates in a degraded state but is safe to mark as healthy.

ContainerPilot currently supports (1) well by original design, supports (2) via coprocess, and supports (3) and (4) if the user has added the appropriate lifecycle hooks. The "hardness" of a dependency (5)(6)(7) is intended to be managed by the end user's `health` and `onChange` handlers. What makes an application "healthy" is left as a user concern and ContainerPilot will only report backends that are marked healthy. This has been a frequent source of feature requests that amount to a `postStart` hook.

ContainerPilot hasn't eliminated the complexity of dependency management -- that doesn't work without proscribing a narrow set of behaviors like 12Factor, which rules out stateful applications -- but we have tamed that complexity by moving it into the container so that it's owned by the people who know the most about what the application needs.

That being said, a more expressive configuration of event handlers may more gracefully handle all the above situations and reduce the end-user confusion. Rather than surfacing just changes to dependency membership lists, we'll expose changes to the overall state as ContainerPilot sees it.

ContainerPilot will provide the following events:

- `onSuccess`: when a service exits with exit code 0.
- `onFail`: when a service exits with a non-zero exit code.
- `onHealthy`: when ContainerPilot receives notice that the dependency has been marked healthy. This is only triggered when there were previously no healthy instances (typically when the application first starts but also if all instances have previously failed).
- `onChange`: when ContainerPilot receives notice of a change to the membership of a service.
- `onUnhealthy`: when ContainerPilot receives notices that the dependency has been marked unhealthy (no instances available of a previously healthy service).

Services can have additional options for their dependencies:

- `wait`: do not start the service until the desired state has been reached. Fire any other event handlers associated with the state before starting the application.
- `timeout`: if the dependency is unhealthy for this period of time, mark this service as failed as well.

In the example below, we have a Node.js service `app`. The Node app needs configuration from the environment before it can start, so it must wait until a one-time service named `setup` has completed successfully. It will wait until `consul_agent` and `database` have been marked healthy, and will automatically reconfigure itself on changes to the `database` and `redis`.


```yml
services:
  app:
    depends:

      # `app` will not start if `setup` fails
      setup:
        wait: onSuccess

      # ContainerPilot will give the agent 60 sec to become healthy,
      # otherwise mark `app` as failed
      consul_agent:
        wait: onHealthy
        timeout: "60s"

      # `app` needs this DB and also needs to configure itself when the DB
      # is healthy. It reloads its config if the DB changes.
      database:
        wait: onHealthy
        timeout: "60s"
        onHealthy: configure-db-connnection.sh
        onChange: reload-db-connections.sh

      # `app` gracefully handles missing redis so we just update the config
      # whenever the list of members changes
      redis:
        onChange: reload-configuration.sh
```

Note that to avoid stalled containers, ContainerPilot will need to automatically detect unresolvable states. In the example above, if `setup` fails ContainerPilot will never start `app`, so it should mark the `app` service state as failed as well. If ContainerPilot reaches a state where no services can continue, it will exit.

This change eliminates the current `preStart` configuration. Instead a user will have a one-time service that all other services depend on (like `setup` above). With multi-application support we can create a chain of dependencies.

_Related GitHub issues:_
- [Startup dependency sequencing](https://github.com/joyent/containerpilot/issues/273)
- [Proposal for onEvent hook](https://github.com/joyent/containerpilot/issues/227)
- [Allow preStart to set environment of application](https://github.com/joyent/containerpilot/issues/205)
- [Questions about backend service status](https://github.com/joyent/containerpilot/issues/160)
- [Handling apps that can't reload config](https://github.com/joyent/containerpilot/issues/126)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/196)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/173)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/204)
