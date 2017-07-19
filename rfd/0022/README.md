---
authors: Angela Fong <angela.fong@joyent.com>
state: draft
---

# RFD 22 Improved user experience after a request has failed

## Background

In SDC, we strive to address the root causes for failed API/UI requests and
perform input validations before accepting a request from end user. There are
however times when requests would fail because:

- There are costs and timing factors associated with validations. In some cases
  it is not practical to replay all of them at request submission time. The
  case in point is the DAPI algorithm exercised in provisioning workflow.
- There are situations when we have system-wide problems and things can still
  fail after a request has gone through all the validations.

The current user experience with failed requests on portal or API:
- CloudAPI, provisioning new instance: The GetMachine API request returns a "failed"
  state for the instance. On portal or using node `triton wait`, user is notified
  of the request failure. There is however no explanation as to why it failed.
- CloudAPI, other actions (instance update/delete/power operations, fabric CRUD, etc):
  There is no way to inquire the status. User knows a request failed when nothing
  seems to have changed after waiting for long enough.
- Docker API: A request ID is returned for every request. User can use it for
  reference when reporting an issue but cannot use it to look up anything. Under
  normal circumstances, final status of requests are reported back to the
  user along with an error message in the case of request failure.

## Desired Outcome

Ideally user is given a request ID for requests that respond asynchronously. They
(or Portal or users' own client applications) can use it to inquire the status and
any associated error messages. The error message will include a short error code
and a friendly message. The status and error code can be programmed to drive other
actions, or at a minimum be referenced when a help desk request is submitted.

There are a number of options for exposing the above information to end user:

### Option 1
Have a new request inquiry endpoint that takes the request ID as input, something like:
```	
GET /requests/:request_id 
```
to return the details of a request that are of interest to the user. It is unlikely that
we want to provide the workflow steps details, like how it is with the `sdc_req` API.
The key attributes to include are probably:
- object type (instance, network, image,...)
- object id/name
- action (create, delete, start, stop,...)
- status (queued, in progress, completed,...)
- started timestamp
- completed timestamp
- error code
- error message

### Option 2
Embed the error fields (for the most recent action only) in the existing
Get<Object> API response, e.g.
``` 
GET /machines/788ba004-6ae4-4c71-cb93-c923b7e9cf52
{
  "id": "788ba004-6ae4-4c71-cb93-c923b7e9cf52",
  "name": "MyInstance",
  "state": "failed",
  "error_code": "NoComputeResource",
  "error_message": "Cannot locate a host that meets the package, image and network requirements for the instance requested",
  ...
}

GET /machines/f7951441-5344-4114-88ce-a064820ed9fe
{
  "id": "f7951441-5344-4114-88ce-a064820ed9fe",
  "name": "MyOtherInstance",
  "state": "stopped",
  "error_code": "DiskFull",
  "error_message": "Instance failed to start up as the zone disk usage has reached its quota",
  ...
}

GET /images/a49df206-d6e4-11e4-86fa-afc46f9b8078
{
  "id": "a49df206-d6e4-11e4-86fa-afc46f9b8078",
  "name": "MyImage",
  "version": "1.0.0",
  "description": "My custom ubuntu 15.10 image",
  ...
  "state": "failed",
  "error_code": "ScriptFailed",
  "error_message": "User script completed with exit code 1"
}
```
This implies that if the latest action is successful, any previous error code/message
should be reset in the instance record.

### Option 3
Enhance MachineAudit API to include the error details as part of the job history for
an instance. This allows multiple error messages to be displayed in the context
of the action performed. The limitation of this option is that the inquiry is
instance-centric. There is no equivalent API for networks, images and other objects.
```
[
  {
    "success": "yes",
    "time": "2015-09-17T06:52:14.219Z",
    "action": "resize",
    "error_code": "NoComputeResource",
    "error_message": "Cannot locate a host that meets the package, image and network requirements for the instance",
    "caller": {
      "type": "signature",
      "ip": "127.0.0.1",
      "keyId": "/bobuser/keys/..."
    }
  },
  {
    "success": "yes",
    "time": "2015-09-01T19:26:29.554Z",
    "action": "provision",
    "error_code": null,
    "error_message": null,
    "caller": {
      "type": "signature",
      "ip": "127.0.0.1",
      "keyId": "/bobuser/keys/..."
    }
  }
]
```

The three options are not mutually exclusive. In all three cases, there will be some
work required in understanding where to capture the appropriate error information
from the job output for different actions against different types of objects. As a
start, we can force-rank the frequently used actions that involve workflow and
chunk out the implementation. Here are the top ones to consider:

1. instance - create/provision
2. instance - power operations
3. instance - snapshot operations
4. instance - add/remove nics
5. image - create custom image from instance

## Open Questions

- Do we want to persist the error code and message in the object instance
  record (similar to how exit_status is stored for docker containers), or
  capture that information from job output on the fly? The latter is likely
  bad for performance.
- Should we "whitelist" common exceptions with specific error message and
  display all unhandled ones as some generic "UnknownSystemError", or expose
  all error messages as is from the workflow step? The latter could mean a
  lot of scrubbing effort on messages to make them appropriate for end users.

## Related Tickets

- [PUBAPI-1201](https://devhub.joyent.com/jira/browse/PUBAPI-1201) -- Expose error details for failed requests
- [PORTAL-1530](https://devhub.joyent.com/jira/browse/PORTAL-1530) -- A way to assist user to handle errors
