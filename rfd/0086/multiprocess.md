## First-class support for multi-process containers

ContainerPilot v2 "shims" a single application -- it blocks until this main application exits and spins up concurrent threads to perform the various lifecycle hooks. ContainerPilot was originally dedicated to the control of a single persistent application, and this differentiated it from a typical init system.

Later in v2 we expanded the polling behaviors of `health` checks and `onChange` handlers to include periodic `tasks` [#27](https://github.com/joyent/containerpilot/issues/27). Correctly supporting Consul or etcd on Triton (or any CaaS/PaaS) means requiring an agent running inside the container, and so we also expanded to include persistent `coprocesses`. Users have reported problems with ContainerPilot (via GitHub issues) that stem from three areas of confusion around these features:

- The configuration of the main process is via the command line whereas the configuration of the various supporting processes is via the config file.
- The timing of when each process starts is specific to which configuration block it's in (main vs `task` vs `coprocess`) rather than its dependencies.
- The timing of `preStart` relative to `task` and `coprocess`. This is particularly problematic when a `preStart` requires the `coprocess` (such as a Consul agent) to operate.


#### Multiple services

In v3 we'll eliminate the concept of a "main" application and embrace the notion that ContainerPilot is an init system for running inside containers. Each process will have its own health check(s), dependencies, frequency of run or restarting ("run forever", "run once", "run every N seconds"), and lifecycle hooks for startup and shutdown.

For each application managed, the command will be included in the ContainerPilot `jobs` block. This change merges the `services`, `task`, and `coprocess` config sections. For running the applications we can largely reuse the existing process running code, which includes `SIGCHLD` handlers for process reaping.

_Related GitHub issues:_
- [Support containerpilot.d config directory](https://github.com/joyent/containerpilot/issues/236)
- [Allow multiple commands for preStart](https://github.com/joyent/containerpilot/issues/253)
- [Prevent polling/coprocesses from being started multiple times](https://github.com/joyent/containerpilot/pull/198)
- [Coprocess hooks](https://github.com/joyent/containerpilot/issues/175)
- [preStart a background process](https://github.com/joyent/containerpilot/issues/157)
- [registering containers as separate nodes on Consul](https://github.com/joyent/containerpilot/issues/162)


#### Dependency management

Applications running under ContainerPilot have external dependencies, and the current design does not adequately account for the variety of dependencies we've encountered from users.

1. Applications may depend on an external service. For example an Nginx upstream or database.
2. Applications may depend on a local service (inside the container). For example an application can't know the health of external dependencies without having the local Consul Agent.
3. Applications may depend on environment variables to be set.
4. Applications may depend on generated files that are not in the container image. For example Nginx with `consul-template` expects the rendered configuration to replace the one from the image.
5. Application dependencies may be hard: the application process can't start without the dependency without exiting.
6. Application dependencies may be quasi-hard: the application process can start without the dependency but the application can't operate correctly until the dependency becomes available (it might retry or poll for the dependency).
7. Application dependencies may be soft: the application process can start without the dependency and operates in a degraded state but is safe to mark as healthy.

ContainerPilot currently supports (1) well by original design, supports (2) via coprocess, albeit poorly, and supports (3) and (4) if the user has added the appropriate lifecycle hooks. The "hardness" of a dependency (5)(6)(7) is intended to be managed by the end user's `health` and `onChange` handlers. What makes an application "healthy" is left as a user concern and ContainerPilot will only report backends that are marked healthy. This has been a frequent source of feature requests that amount to a `postStart` hook.

ContainerPilot hasn't eliminated the complexity of dependency management -- that doesn't work without proscribing a narrow set of behaviors like 12Factor, which rules out stateful applications -- but we have tamed that complexity by moving it into the container so that it's owned by the people who know the most about what the application needs.

That being said, a more expressive configuration of event handlers may more gracefully handle all the above situations and reduce the end-user confusion. Rather than surfacing just changes to dependency membership lists, we'll expose changes to the overall state as ContainerPilot sees it.

ContainerPilot will provide events and each service can opt-in to starting on a `when` condition on one of these events. Because the life-cycle of each service triggers new events, the user can create a dependency chain among all the services in a container (and their external dependencies). This effectively replaces the `preStart`, `preStop`, and `postStop` behaviors.

_Related GitHub issues:_
- [Startup dependency sequencing](https://github.com/joyent/containerpilot/issues/273)
- [Proposal for onEvent hook](https://github.com/joyent/containerpilot/issues/227)
- [Allow preStart to set environment of application](https://github.com/joyent/containerpilot/issues/205)
- [Questions about backend service status](https://github.com/joyent/containerpilot/issues/160)
- [Handling apps that can't reload config](https://github.com/joyent/containerpilot/issues/126)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/196)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/173)
- [Yet another proposal for "post start"](https://github.com/joyent/containerpilot/issues/204)


#### Non-advertising jobs

Some applications are intended only for internal consumption by other applications in the container and not should not be advertised to the discovery backend (ex. Consul agent). These applications can mark themselves as "non-advertising" simply by not providing a `port` configuration. ContainerPilot will track the state of non-advertising applications but not register them with service discovery, so jobs that are waiting for `healthy` or `unhealthy` events can react to those events. In the example above, the Consul Agent will not be advertised but Nginx can still have it marked as a dependency.

_Related GitHub issues:_
- [Coprocess hooks](https://github.com/joyent/containerpilot/issues/175)
- [registering services w/o ports](https://github.com/joyent/containerpilot/issues/117)


#### Health checking for non-advertised jobs

ContainerPilot 3 will support the ability for a non-advertised job to have health checks. All health checks for a job must be in a passing state before a job can be marked as healthy.

We'll make the following changes:

- ContainerPilot will maintain state for all jobs, which can be either `healthy` or `unhealthy`, and all health checks, which can be either `passing` or `failing`.
- A health checks must be marked `passing` before ContainerPilot will mark the job as `healthy` and send the event so that it can be consumed by other jobs.
- A job in a `healthy` state will send heartbeats (a `Pass` message) to the discovery backend every `heartbeat` seconds with a TTL of `ttl`.
- A health check will poll every `interval` seconds, with a timeout of `timeout`. If any health check fails (returns a non-zero exit code or times out), the associated job is marked `unhealthy` and a `Fail` message is sent to the discovery job.

**Important note:** end users should not provide a health check with a long polling time to perform some supporting task like backends. This will cause "slow startup" as their job will not be marked healthy until the first polling window expires. Instead they should create another job for this task.


#### "When"

The configuration for `when` includes an event (either `once` or `each`), a sometimes-optional `source`, and an optional `timeout`. ContainerPilot will provide the following events:

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
- `when: {source: "myPreStart", once: "exitSuccess", timeout: "60s"}`: wait up to 60 seconds for the service in the same container named `myPreStart` to exit successfully.
- `when: {source: "myDb", once: "healthy"}`: wait forever, until the service `myDb` has a healthy instance. This service could be in the same container or external.
- `when: {source: "myDb", once: "stopped"}`: start after the service in this container named `myDb` stops. This could be useful for copying a backup of the data off the instance.
- `when: {source: "watch.myDb", each: "changed"}`: run the job each time the watch for the service `myDb` reports a change.

#### Watches

ContainerPilot will generate events for all jobs internally, but the user can create a `watch` to query service discovery periodicially and generate `changed` events. This replaces the existing `backends` feature, except that `watches` don't fire their own executables. Instead the user should create a job that watches for events that the `watch` fires. A `watch` event source will be named `"watch.<watch name>"` to differentiate it from job events with the same name.


#### Ordering

Each job, health check, or watch handler runs independently (in its own goroutine) and publishes its own events. Events are broadcast to all handlers and a handler will handle events in the order they are received (buffering events as necessary). This means events from multiple publishers can be interleaved, but events for a single publisher will arrive in the order they were sent; e.g. a handler won't receive a `stopped` before a `stopping`. (In practice, handlers will receive messages in the same order as all other handlers but this isn't going to be an invariant of the system in case we need to change the internals later.)
