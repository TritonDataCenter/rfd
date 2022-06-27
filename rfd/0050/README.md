---
authors: Angela Fong <angela.fong@joyent.com>
state: predraft
---

# RFD 50 Enhanced Audit Trail for Instance Lifecycle Events

## Introduction

The existing `MachineAudit` CloudAPI endpoint allows Triton users to obtain the
audit trail of lifecycle events for their compute instances. The audit trail is
derived from the workflow jobs and covers only a small subset of the request
attributes. There are some major limitations with the API:

1. Workflow job records are process logs in nature. They can take up a fair
amount of space in the database. If we ever purge the historical job records,
the API will no longer return the complete audit trail.
2. The amount of information returned currently is not adequate for in-depth
troubleshooting or analytical purposes. Certain actions even show up with
"unknown" type in the API response.
3. Machine changes performed outside the context of a workflow job (e.g. vmadm)
are missing in the audit trail altogether.

For reference, these are the actions captured and properly categorized at this time:

- provision
- start/stop/reboot/kill
- add/remove/update nics
- create/rollback/delete snapshots
- add/set/delete tags
- rename
- resize
- reprovision

These actions are captured but reported with "unknown" action type:

- enable/disable firewall
- add/set/delete internal metadata
- add/set/delete customer metadata
- update owner

These are the event details returned by the API:

- caller information (SSH key id, IP address)
- event end time
- overall job status (succeeded vs failed)

Here is an example of the API response:
```
  {
    "success": "yes",
    "time": "2016-04-27T06:18:34.699Z",
    "action": "set_tags",
    "caller": {
      "type": "signature",
      "ip": "127.0.0.1",
      "keyId": "/angela.fong/keys/e8:da:41:32:5c:ac:2e:6e:20:c9:05:8f:a7:2b:7e:bd"
    }
  }
```

## Feature Gaps

### Ability to inquire events for multiple instances

The existing API allows account owners to inquire the audit trail of a single
instance on an ad hoc basis. For accounts that include subusers or projects,
the owners should have the ability to narrow down the inquiries by subuser,
projects or tags. 

Audit trail may also serve as the input for monitoring applications for
historical analysis of instance events. A common way to consume the data in
this case is through regular polling for events that happened within a certain
time window.

To fulfill these different use cases, the `MachineAudit` API should support
the use of one or multiple of the following filters:

- event time window
- instance ID
- subuser ID or login
- project ID or name (when the [Project](https://github.com/TritonDataCenter/rfd/tree/master/rfd/0013) feature is available)
- machine tag key/value pair
- event/action type

A reasonable limit on the number of records returned in a single API call will
be required for performance reasons. If the number of events based on the filtering
criteria exceeds that limit, the API should support a way to traverse to the
next set of records (e.g. by using event time as the offset).

### Inclusion of error and performance details about an event 

The content of the audit trail can be expanded to include information such as
request ids (if applicable), event elapse times, error messages for failed actions,
attribute values modified. These details are often useful for debugging and analytics.

(**Note:** The ability to capture and return the error message for a failed
request ties into a long-standing request for improved error handling discussed
in [RFD 22](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0022/README.md). This
work is known to be non-trivial and may have to be handled as a separate project.
As a start, we can extract the error messages that are readily available at the
moment.)

### Inclusion of events that do not result in workflow jobs

The following types of events do not trigger workflow jobs but are desirable
for inclusion in the audit trail, if it is technically feasible:

- Metadata changes made through mdata-put and mdata-delete
- Firewall rule changes that may or may not be specific to an instance
- Server reboot and instance reboot with operating system commands

Changes made through vmadm and other downstack APIs by the operator should also
be captured in the audit trail for completeness.

In the event that the instances went down catastrophically (e.g. because of a
forced reboot of the server), we can consider providing some way for the
operator to add the instance kill/stop events manually.

### Ability to retain audit trail independent of workflow job records

This requirement is not meant to dictate the implementation. However, there is
a good reason for persisting audit trail in a new Moray bucket as we can avoid
being locked into permanent retention of workflow jobs. In addition, the
performance penality of parsing large job logs to extract the audit trail may
become prohibitive for scalability.

### Event tracking for other cloud objects

Ideally, all other user-owned objects such as networks, images and volumes
(introduced in [RFD 26](https://github.com/TritonDataCenter/rfd/tree/master/rfd/0026))
should have similar change tracking for audit purposes. These requirements can
be considered as part of the future scope based on user demand. 


## Open Questions

### Should the enhanced audit API be a new API?

This will depend on whether we want to stay with the current `MachineAudit`
CloudAPI consumption pattern or allow this to be served in a way similar to
[container metrics](https://github.com/TritonDataCenter/rfd/tree/master/rfd/0027).
There is also the desire of having an event management framework, as part of
[Mariposa](https://github.com/TritonDataCenter/rfd/tree/master/rfd/0036) where event
callback may become the new paradigm for end-user API interactions.

The current bias is to keep the API as a new revision of `MachineAudit` for
two main reasons:

1. There is an established mechanism for authentication and authorization.
2. Unlike metrics which are needed for real-time monitoring and can
   tolerate occasional data loss, audit trail availability allows a minor delay
   but needs to be complete and persistent. 

### How does this feature relate to `docker events`?

Enhanced instance audit does not fully cover `docker events` but can bring us
a step closer to it. Currently `docker events` supports

1. the live-streaming of events
2. change tracking of images, networks, and volumes
3. non-lifecycle events such as attach/detach and mount/unmount

We can consider 2 and 3 in the next iteration, but the support for streaming
is obviously based on the decision on the previous question.

### Should we track the changes made to internal attributes?

Certain instance attributes are not exposed to the end users (e.g. cpu shares,
billing tag). Change tracking for these internal attributes can still be
useful for operators but can be considered noises to the end users.
We can have two classes of audit trail where the ones related to internal
attributes are filtered out from the end-user API. For MVP, we can consider
scoping out the tracking of internal attributes.

### How far do we go with capturing the details in update requests?

Single attribute modifications (e.g. firewall enabled, owner uuid) are
relatively easy to capture and present to the user, but some changes may
require the dumping of the entire input and the 'after' attribute values.
We'll probably need a flexible response format to avoid having to tailor
the audit trail output for different events.

### Should we allow user to opt out of audit?

A good reason for opting out is when users are dealing with dev/test instances
that are rapidly created and destroyed. They are not concerned about the change
history and do not want the associated overhead. The caveat is that users may
find that they *do* need the audit trail when something has gone wrong. As
such, the bias is to make audit required all the time. The permission to query
the audit trail is still controlled by RBAC as how it is currently.
