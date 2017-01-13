# Mariposa Project service

The Mariposa (RFD36) Project service will be responsible for maintaining and exposing data about user projects and services. The project service will expose multiple endpoints for interacting with this data, to be used by the Triton CLI as well as other Triton services, including the Convergence service. 

Projects and their services will be wholly versioned such that a change to the project manifest, metadata, or any service associated with the project will result in a new (sha1 sum) tag being created. 

## Data

The Project service will persist data to an appropriate backend (Postgres/Manatee?). Persisted data will represent user projects and their associated services. See:

* [Mariposa service manifest](https://github.com/joyent/rfd/blob/master/rfd/0036/service-manifest.md)
* [Mariposa project manifest](https://github.com/joyent/rfd/blob/master/rfd/0036/project-manifest.md)

In addition to manifest data, service goal state data will be managed by the Project service, including:

* status - whether a service is stopped, started, or paused
* scale - the number of containers that should be running for a particular service

## Project and service tagging

A project will be automatically tagged with the sha1 sum of it's parts (project manifest, all service manifests, and any applicable metadata). This will occur upon the creation of the project or any change to it or it's associated services. 

In addition to this, users should be able to associate custom tags with any given sha1 sum. 

It will be easily discernible which project tags a given service changed in. Services will support custom user tags that will be associated with the service's project sha1 sum. 

## Endpoints

Unless otherwise noted, the output for all endpoints is JSON. The exception to this, as documented below, is for the project manifest and metadata endpoints, which will output YAML as it was provided. If the project was created via the JSON interface, then YAML will be generated. 

All below endpoints may be prefixed with `/users/$userId` to access data for a user other than the one you're authenticated as, assuming authorization is granted. For example:

`GET /users/abc123/projects` will return the same data as a request to `/projects` would if you were authenticated as `abc123`. 

### /projects

Endpoint operations:

* GET - A list of projects associated with requesting user
* POST - Create a new project via YAML manifest transmitted in POST payload

### /projects/$projectId

Endpoint operations:

* GET - Project data and metadata derived from manifest and meta file in JSON format for specified project ID
* PUT - Update project data and/or metadata via JSON document transmitted in PUT payload
* DELETE - Mark project as removed

### /projects/$projectId/manifest

Endpoint operations:

* GET - Get project manifest in YAML format as it was provided
* PUT - Update project manifest by sending YAML payload

### /projects/$projectId/metadata

Endpoint operations:

* GET - Get project metadata in YAML format as it was provided
* PUT - Update project metadata by sending YAML payload

### /projects/$projectId/metadata/$key

Endpoint operations:

* GET - Returns value associated with metadata key
* PUT - Update value for metadata key
* DELETE - Remove metadata key

### /projects/$projectId/tags

Endpoint operations:

* GET - list of tags associated with project, automatic and custom
* POST - Create a user-defined tag, associated with a specified sha1sum tag

### /projects/$projectId/tags/$tagId

Endpoint operations

* GET - Detailed project information and manifest for the version associated with the given tag ID
* DELETE - Remove a user-specified tag, this will return an error if user attempts to delete a sha1 sum tag

### /projects/$projctId/services

Endpoint operations:

* GET - Summarized service information for specified project
* POST - Create a new service for the specified project via service manifest transmitted in POST payload

### /projects/$projectId/state

Endpoint operations:

* GET - Goal/Actual state information via a proxied request to the Convergence service

### /services

Endpoint operations:

* GET - A list of all user services across all projects
* POST - Create a new service via service manifest transmitted in POST payload; the associated project must be specified in the manifest

### /services/$serviceId

Alias: `/projects/$projectId/services/$serviceId`

Endpoint operations:

* GET - Detailed service information and manifest for specified service ID
* PUT - Updated service manifest via new manifest transmitted in PUT payload
* DELETE - Mark service as removed

### /services/$serviceId/state

Endpoint operations:

* GET - Goal/Actual state information via a proxied request to the Convergence service
* PUT - Update goal state information (stop, start, pause, resume, scale)
