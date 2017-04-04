## First-class support for multi-process containers

ContainerPilot v2 "shims" a single application -- it blocks until this main application exits and spins up concurrent threads to perform the various lifecycle hooks. ContainerPilot was originally dedicated to the control of a single persistent application, and this differentiated it from a typical init system.

Later in v2 we expanded the polling behaviors of `health` checks and `onChange` handlers to include periodic `tasks` [#27](https://github.com/joyent/containerpilot/issues/27). Correctly supporting Consul or etcd on Triton (or any CaaS/PaaS) means requiring an agent running inside the container, and so we also expanded to include persistent `coprocesses`. Users have reported problems with ContainerPilot (via GitHub issues) that stem from three areas of confusion around these features:

- The configuration of the main process is via the command line whereas the configuration of the various supporting processes is via the config file.
- The timing of when each process starts is specific to which configuration block it's in (main vs `task` vs `coprocess`) rather than its dependencies.
- The timing of `preStart` relative to `task` and `coprocess`.

#### Multiple services

In v3 we'll eliminate the concept of a "main" application and embrace the notion that ContainerPilot is an init system for running inside containers. Each process will have its own health check(s), dependencies, frequency of run or restarting ("run forever", "run once", "run every N seconds"), and lifecycle hooks for startup and shutdown.

For each application managed, the command will be included in the ContainerPilot `jobs` block. This change merges the `services`, `task`, and `coprocess` config sections. For running the applications we can largely reuse the existing process running code, which includes `SIGCHLD` handlers for process reaping. Below is an example configuration, using the JSON5 configuration syntax described in the [config updates](config.md) section.

```json5
{
  jobs: [
    {
      name: "nginx",
      when: {
        source: "consul-agent",
        event: "healthy"
      },
      exec: "nginx",
      port: 80,
      heartbeat: 5,
      ttl: 10,
      interfaces: [
        "eth0",
        "eth1",
      ]
    },
    {
      name: "consul-agent",
      exec: "consul -agent",
      port: 8500,
      interfaces: ["localhost"],
    },
  ],
  health: [
    {
      name: "nginx",
      exec:  "curl --fail http://localhost/app",
      poll: 5,
      timeout: "5s"
    }
}
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

ContainerPilot 3 will support the ability for a job to have multiple health checks. All health checks for a job must be in a passing state before a job can be marked as healthy. The job definition will be separated from the health check definition in order to support proposed [configuration improvements](config.md).

We'll make the following changes:

- ContainerPilot will maintain state for all jobs, which can be either `healthy` or `unhealthy`, and all health checks, which can be either `passing` or `failing`.
- All health checks must be marked `passing` before ContainerPilot will mark the job as `healthy`.
- A job in a `healthy` state will send heartbeats (a `Pass` message) to the discovery backend every `heartbeat` seconds with a TTL of `ttl`.
- A health check will poll every `poll` seconds, with a timeout of `timeout`. If any health check fails (returns a non-zero exit code or times out), the associated job is marked `unhealthy` and a `Fail` message is sent to the discovery job.
- Once any health check fails, _all_ health checks need to pass before the job will be marked healthy again. This is required to avoid service flapping.

**Important note:** end users should not provide a health check with a long polling time to perform some supporting task like backends. This will cause "slow startup" as their job will not be marked healthy until the first polling window expires. Instead they should create another job for this task.

```json5
{
  consul: {
    host: "consul.svc.triton.zone"
  },
  jobs: [
    {
      name: "nginx",
      port: 80,
      heartbeat: 5,
      ttl: 10
    }
  ],
  health: [
    {
      name: "check-A",
      job: "nginx",
      exec: "curl -s --fail localhost/health"
    },
    {
      name: "check-B",
      job: "nginx",
      exec: "curl -s --fail localhost/otherhealth"
    }
  ]
}
```


_Related GitHub issues:_
- [Support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [Allow multiple health checks per service](https://github.com/joyent/containerpilot/issues/245)


#### Non-advertising jobs

Some applications are intended only for internal consumption by other applications in the container and not should not be advertised to the discovery backend (ex. Consul agent). These applications can mark themselves as "non-advertising" simply by not providing a `port` configuration. ContainerPilot will track the state of non-advertising applications but not register them with service discovery, so it can fire `watch` handlers for other jobs that depend on it. In the example above, the Consul Agent will not be advertised but Nginx can still have it marked as a dependency.

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

ContainerPilot will provide events and each service can opt-in to starting on a `when` condition on one of these events. Because the life-cycle of each service triggers new events, the user can create a dependency chain among all the services in a container (and their external dependencies). This effectively replaces the `preStart`, `preStop`, and `postStop` behaviors.

#### "When"

The configuration for `when` includes an `event`, a sometimes-optional `source`, and an optional `timeout`. ContainerPilot will provide the following events:

- `startup`: when ContainerPilot has completed all configuration and has started its telemetry server and control socket. This event also signals the start of all timers used for the optional timeout. This event may not have an event source. If no `start` is configured for a service, starting on this event is the default behavior.
- `exitSuccess`: when a service exits with exit code 0. This event requires an event source.
- `exitFailed`: when a service exits with a non-zero exit code. This event requires an event source.
- `healthy`: when ContainerPilot determines that a dependency has been marked healthy. This can be determined by either a `watch` for an external service (registered with the discovery backend) or by a passing health check for another service in the same container. This is only triggered when there were previously no healthy instances (typically when the application first starts but also if all instances have previously failed). This event requires an event source.
- `changed`: when ContainerPilot receives notice of a change to the membership of a service. This event requires an event source.
- `unhealthy`: when ContainerPilot receives notices that the dependency has been marked unhealthy (no instances available of a previously healthy service). This event requires an event source.
- `stopping`: when a service in the same container receives SIGTERM. This event requires an event source.
- `stopped`: when the process for a service in the same container exits. This event requires an event source.

The optional event source is the service that is emitting the event. The optional timeout (in the format `timeout 60s`) indicates that ContainerPilot will give up on starting this service if the timeout elapses.

Some example `start` configurations:

- `when: {event: "startup"}`: start immediately (this is the default behavior if unspecified).
- `when: {source: "myPreStart", event: "exitSuccess", timeout: "60s"}`: wait up to 60 seconds for the service in the same container named `myPreStart` to exit successfully.
- `when: {source: "myDb", event: "healthy"}`: wait forever, until the service `myDb` has a healthy instance. This service could be in the same container or external.
- `when: {source: "myDb", event: "stopped"}`: start after the service in this container named `myDb` stops. This could be useful for copying a backup of the data off the instance.


#### Watches

ContainerPilot will generate events for all jobs internally, but the user can create a `watch` to query service discovery periodicially and generate `changed` events. This replaces the existing `backends` feature, except that `watches` don't fire their own executables. Instead the user should create a job that watches for events that the `watch` fires. A `watch` event source will be named `"watch.<watch name>"` to differentiate it from job events with the same name.

#### Ordering

Each job, health check, or watch handler runs independently (in its own goroutine) and publishes its own events. Events are broadcast to all handlers and a handler will handle events in the order they are received (buffering events as necessary). This means events from multiple publishers can be interleaved, but events for a single publisher will arrive in the order they were sent; e.g. a handler won't receive a `stopped` before a `stopping`. (In practice, handlers will receive messages in the same order as all other handlers but this isn't going to be an invariant of the system in case we need to change the internals later.)

#### Example

In the example below, we have a Node.js service `app`. It needs to get some configuration data from the environment in a one-time `setup` job. The Node app has to make requests to redis and a database. The app can gracefully handle a missing redis but can't safely start without the database (this is an intentionally arbitrary example). We also need a consul-agent job to be running so that we can get the configuration for all of the above.

The diagram below roughly describes the dependencies we have.

```
       +----> setup ------+
       |                  |
app ---+----> database ---+----> consul-agent ----> container start
       |                  |
       +~~~~> redis ------+
```

The configuration syntax for `when` doesn't permit multiple dependencies, but we can describe a chain of dependencies by forcing one of the hard dependencies to depend on the other as shown in the configuration below. The user could also accomplish the same dependency chain by merging the `configure-db-connection` and `setup` service executables, or even by having the `setup` executable poll the ContainerPilot status endpoint for more fine-grained control.

```json5
{
  jobs: [
    {
      name: "consul-agent",
      when: {
        event: "startup" // this is the default
      },
      exec: "consul -agent -join {{ .CONSUL }}"
    },
    {
      // the db is a hard dependency for 'app'
      // onHealthy for an external db implies we are also waiting for
      // consul-agent so we meet that requirement too
      name: "configure-db-connection",
      when: {
        source: "database",
        event: "healthy"
      }
      exec: "/bin/configure-db.sh"
    },
    {
      name: "setup",
      when: {
        source: "configure-db-connection",
        event: "exitSuccess"
      },
      exec: "/bin/setup.sh"
    },
    {
      name: "app",
      // 'app' will never start if 'setup' fails
      when: {
        source: "setup",
        event: "exitSuccess"
      },
      exec: "node /bin/app.js"
    },
    {
      name: "reconfigure-db-connection.sh",
      when: {
        source: "watch.database",
        event: "changed"
      },
      exec: "reconfigure-db-connection.sh",
    },
    {
      name: "reconfigure-redis-connection.sh",
      when: {
        source: "watch.redis",
        event: "changed"
      },
      exec: "reconfigure-redis-connection.sh",
    }
  ],
  health: [
    {
      // because we haven't provided a port for consul-agent this health check
      // won't result in it registering with service discovery, but we still
      // get its health events inside this container
      name: "consul-agent-check",
      job: "consul-agent",
      exec:  "consul info | grep peers",
      poll: 5,
      timeout: "5s"
    }
  ]
  watches: [
    {
      name: "database",
    },
    {
      // we gracefully handle missing redis so this is a soft dependency.
      // we update the config whenver the list of members changes
      name: "redis",
    }
  ]
}
```

In the example above, if `setup` fails ContainerPilot will never start `app`, so it should mark the `app` job state as failed as well. If ContainerPilot reaches a state where no jobs can continue, it should exit. To avoid stalled containers, ContainerPilot will need a way to automatically detect unresolvable states.

_Related GitHub issues:_
- [Startup dependency sequencing](https://github.com/joyent/containerpilot/issues/273)
- [Proposal for onEvent hook](https://github.com/joyent/containerpilot/issues/227)
- [Allow preStart to set environment of application](https://github.com/joyent/containerpilot/issues/205)
- [Questions about backend service status](https://github.com/joyent/containerpilot/issues/160)
- [Handling apps that can't reload config](https://github.com/joyent/containerpilot/issues/126)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/196)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/173)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/204)
