# Mariposa Health Check Service

The Mariposa (RFD36) health check service will be responsible for monitoring the health of user services. It establishes a set of supported health checks and provides an API for defining health checks that should be ran against project services. These health check definitions will be persisted in a proper data store (Postgres/Manatee?).

The Health Check service process(es) will read user health check definitions, and coordinate which health check process will be responsible for running any given definition. 

Failed health checks will be broadcast to interested services, such as the Convergence service.

## Health check types

The available health checks include:

* HTTP(s) - Test the response of an HTTP request against a given service/port. Any part of the response may be validated including response code, headers, or body.
* TCP - Test that a service/port is accepting TCP connections.
* ContainerPilot - Interface with ContainerPilot running within a service container and accept the health state returned by it.

In addition to the health checks specified, the health check service will interface with VMAPI and ChangeFeed to understand when a container state transitions between stopped/paused/running. Stopped/paused will be considered unhealthy and the above health checks will not be attempted against containers in these states.

## Health check configuration

Health check definitions files will be YAML, to be consistent with project manifests and metadata files. 

All health check definitions will include:

* Healthy poll interval - How often the service is checked while deemed healthy
* Unhealthy poll interval - Defaults to healthy poll interval, but may be desirable to have a smaller value here for two reasons: faster recovery detection, and faster detection of initial healthiness, there could be a back-off associated with this
* Timeout - How long to wait for the health check before aborting and considering the service unhealthy
* Recheck - A number of times to re-check a failed health check before transitioning the service to an unhealthy state, default to zero.

## Endpoints

Unless otherwise noted, the output for all endpoints is JSON.

All below endpoints may be prefixed with `/users/$userId` to access data for a user other than the one you're authenticated as, assuming authorization is granted. For example:

`GET /users/abc123/healthchecks` will return the same data as a request to `/healthchecks` would if you were authenticated as `abc123`.

### /healthchecks

Endpoint operations:

* GET - A list of all health checks defined by the user, along with project and service they're associated with. This list can be filtered by passing `project` or `service` GET params with ID values.
* POST - Create a new health check via YAML definition transmitted in POST payload

### /healthchecks/$healthcheckId

Endpoint operations:

* GET - Get health check configuration and state
* PUT - Update health check configuration and state via JSON document transmitted in PUT payload
* DELETE - Remove health check

### /healthchecks/$healthcheckId/definition

Endpoint operations:

* GET - Get the healthcheck definition in YAML format as it was provided
* PUT - Update the health check definition by sending YAML payload