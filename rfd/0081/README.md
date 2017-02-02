---
authors: Casey Bisson <casey.bisson@joyent.com>, Jason Pincin <jason.pincin@joyent.com>
state: predraft
---

# RFD 81 ServicesHealth agent implementation

The Mariposa (RFD36) health check agent will be responsible for monitoring the health of user services. The Health Check agent process(es) will read user defined health check definitions from the Project service, and coordinate which health check process will be responsible for running any given definition. The Project service is read at agent start time, then polled on an interval. There's an endpoint exposed by the agent that will trigger a poll as well.

Upon a failed health check, a message will be pushed directly to the Convergence service. 

 The Health Check agents will run in an [sdc-nat zone](https://github.com/joyent/sdc-nat) associated with the project. This enables the Health Check agent to make requests via the user's private fabric. Some cases to discuss:
 
* What if the NAT zone fails?
* What if the user has multiple fabric networks within a project?
* What if the user has instances in a project that are not connected to any NAT?

## Health check types

The available health checks include:

* HTTP(s) - Test the response of an HTTP request against a given service/port. Any part of the response may be validated including response code, headers, or body.
* TCP - Test that a service/port is accepting TCP connections.
* ContainerPilot - Interface with ContainerPilot running within a service container and accept the health state returned by it.

## Health check configuration

All health check definitions will include:

* Healthy poll interval - How often the service is checked while deemed healthy
* Unhealthy poll interval - Defaults to healthy poll interval, but may be desirable to have a smaller value here for two reasons: faster recovery detection, and faster detection of initial healthiness, there could be a back-off associated with this
* Timeout - How long to wait for the health check before aborting and considering the service unhealthy
* Retries - A number of times to re-check a failed health check before transitioning the service to an unhealthy state, default to zero.

## Endpoints

Unless otherwise noted, the output for all endpoints is JSON. All data backing these endpoints is in-memory only (no persistence). 

### /v1/healthchecks

Endpoint operations:

* GET - A summary list of all health checks active in the agent

### /v1/healthchecks/update

Endpoint operations:

* POST - Trigger a refresh of health check configuration (by pulling from the Project service)

### /v1/healthchecks/$healthcheckId

Endpoint operations:

* GET - Detailed health check info/manifest in JSON format

### /v1/healthchecks/$healthcheckId/definition

Endpoint operations:

* GET - Get the healthcheck definition in YAML format as it was provided
