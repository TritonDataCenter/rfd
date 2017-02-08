---
authors: Casey Bisson <casey.bisson@joyent.com>, Jason Pincin <jason.pincin@joyent.com>
state: predraft
---

# RFD 79 Projects API implementation

The Mariposa (RFD36) Project service will be responsible for maintaining and exposing data about user projects, services, and metadata. The project service will provide multiple endpoints for interacting with this data, to be exposed to users via CloudAPI and consumed directly by services within Triton.

Projects and their services will be wholly versioned such that a change to the project manifest, metadata, or any service associated with the project will result in a new (sha1 sum) tag being created. 

## Data

The Project service will persist data to Moray. Persisted data will represent user projects and their associated services. See:

* [Mariposa service manifest](https://github.com/joyent/rfd/blob/master/rfd/0036/service-manifest.md)
* [Mariposa project manifest](https://github.com/joyent/rfd/blob/master/rfd/0036/project-manifest.md)

In addition to manifest data, the requested running state of each service will be managed by the Project service, which includes: stopped, started, frozen, and paused (paused needs further discussion).

## Project and service tagging

Upon creation or change to a project, it's metadata, or any associated service, the sha1sum of it's parts (project manifest, all service manifests, metadata) along with the date/time of the event will be recorded and associated with the given change set.

In addition to this, it's desirable that users should be able to associate custom tags with any given sha1 sum, though not strictly required. 

It will be easily discernible which project tags a given service changed in. 

## Endpoints

Unless otherwise noted, the output for all endpoints is JSON. The exception to this, as documented below, is for the project manifest and metadata endpoints, which will output YAML as it was provided. If the project was created via the JSON interface, then YAML will be generated. 

All below endpoints may be prefixed with `/users/$userId` to access data for a user other than the one you're authenticated as, assuming authorization is granted. For example:

`GET /v1/users/abc123/projects` will return the same data as a request to `/v1/projects` would if you were authenticated as `abc123`. 

### /v1/projects

Endpoint operations:

* GET - A list of projects associated with requesting user filterable by organization
* POST - Create a new project via YAML manifest transmitted in POST payload

### /v1/projects/$projectId

Endpoint operations:

* GET - Project data and metadata derived from manifest and meta file in JSON format for specified project ID
* PUT - Update project data and/or metadata via JSON document transmitted in PUT payload
* DELETE - Mark project as removed, and remove any running services associated with the project

### /v1/projects/$projectId/manifest

Endpoint operations:

* GET - Get project manifest in YAML format as it was provided
* PUT - Update project manifest by sending YAML payload

### /v1/projects/$projectId/healthchecks

Endpoint operations:

* GET - All health checks associated with the project

### /v1/projects/$projectId/metadata

Endpoint operations:

* GET - Get project metadata in YAML format as it was provided
* PUT - Update project metadata by sending YAML payload

### /v1/projects/$projectId/metadata/$key

Endpoint operations:

* GET - Returns value associated with metadata key
* PUT - Update value for metadata key
* DELETE - Remove metadata key

### /v1/projects/$projectId/tags

Endpoint operations:

* GET - list of tags associated with project, automatic and custom
* POST - Create a user-defined tag, associated with a specified sha1sum tag

### /v1/projects/$projectId/tags/$tagId

Endpoint operations

* GET - Detailed project information and manifest for the version associated with the given tag ID
* DELETE - Remove a user-specified tag, this will return an error if user attempts to delete a sha1 sum tag

### /v1/projects/$projectId/state

Endpoint operations:

* GET - Goal/Actual state information via a proxied request to the Convergence servic
* PUT - Update goal state information (freeze, thaw, reprovision, stop, start)

### /v1/projects/$projctId/healthchecks

Endpoint operations:

* GET - All health checks associated with the project

### /v1/projects/$projctId/services

Endpoint operations:

* GET - Summarized service information for specified project
* POST - Create a new service for the specified project via service manifest transmitted in POST payload

### /v1/projects/$projctId/services/$serviceId

Endpoint operations:

* GET - Detailed service information and manifest for specified service ID
* PUT - Updated service manifest via new manifest transmitted in PUT payload
* DELETE - Mark service as removed

### /v1/projects/$projectId/services/$serviceId/manifest

Endpoint operations:

* GET - Get service manifest in YAML format as it was provided
* PUT - Update service manifest by sending YAML payload

### /v1/projects/$projctId/services/$serviceId/state

Endpoint operations:

* GET - Goal/Actual state information via a proxied request to the Convergence service
* PUT - Update goal state information (stop, start, freeze, thaw, reprovision, pause, resume, scale)

### /v1/projects/$projctId/services/$serviceId/healthchecks

Endpoint operations:

* GET - All health checks associated with the service

### /v1/services

Endpoint operations:

* GET - A list of all user services across all projects, filterable by organization and project
