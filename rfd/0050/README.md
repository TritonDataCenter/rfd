---
authors: Angela Fong <angela.fong@joyent.com>
state: predraft
---

# RFD 50 Enhanced Audit Trail for Instance Lifecycle Events

## Introduction

The existing `MachineAudit` CloudAPI endpoint allows Triton users to obtain the
audit trail of lifecycle events for their compute instances. The audit trail is
derived from the workflow jobs and covers only a small subset of the job
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

Audit trail may also serve as the input into monitoring applications for
historical analysis of instance events. A common way to consume the data in
this case is through regular polling for events that happened within a certain
time window.

To fulfill these different use cases, the `MachineAudit` API should support
the use of one or multiple of the following filters:

- event time window
- instance ID
- subuser ID or login
- project ID or name (when the [Project](https://github.com/joyent/rfd/tree/master/rfd/0013) feature is available)
- machine tag key/value pair

### Inclusion of error and performance details about an event 

The content of the audit trail can be expanded to include information such as
event elapse times, error messages for failed actions, attribute values
modified. These details are often useful for debugging and analytics.

(**Note:** The ability to capture and return the error message for a failed
request ties into a long-standing request for improved error handling raised in
[RFD 22](https://github.com/joyent/rfd/blob/master/rfd/0022/README.md). This
work is known to be non-trivial and may have to be handled as a separate project.)

### Inclusion of events that do not result in workflow jobs

The following types of events do not trigger workflow jobs but are desirable
for inclusion in the audit trail, if it is technically feasible:

- Metadata changes made through mdata-put and mdata-delete
- Firewall rule changes that may or may not be specific to an instance
- Server reboot and instance reboot with operating system commands

Changes made through vmadm and other downstack APIs by the operator should also
be captured in the audit trail for completeness.

### Ability to retain audit trail independent of workflow job records

This requirement is not meant to dictate the implementation. But there is a good
reason for persisting audit trail in a new Moray bucket, so that we can avoid
being locked into permanent retention of workflow jobs. In addition, the
performance penality of parsing large job logs to extract the audit trail may
become prohibitive for scalability.


## Open Questions

### Should the enhanced audit API be a new API?

This will depend on whether we want to stay with the current `MachineAudit`
CloudAPI consumption pattern or allow this to be served in a way similar to
[container metrics](https://github.com/joyent/rfd/tree/master/rfd/0027).
There is also the desire of having an event management framework, as part of
[Mariposa](https://github.com/joyent/rfd/tree/master/rfd/0036) where event
callback may become the new paradigm for end-user API interactions.

This is a major decision we have to make before moving forward.

### Should we track the changes made to internal attributes?

Certain instance attributes are not exposed to the end users (e.g. cpu shares,
billing tag). Change tracking for these internal attributes can still be
useful for operators. But they are arguably noises to the end users. Perhaps
we can have two classes of audit trail where the ones related to internal
attributes are filtered out from the end-user API. For MVP, we can consider
scoping out the tracking of internal attributes.

### How far do we go with capturing the details in update requests?

Single attribute modifications (e.g. firewall enabled, owner uuid) is
relatively easy to capture and present to the user. But some other changes may
require the dumping of an entire request payload which contains the 'before'
and 'after' snapshots of the attribute values. We'll probably need a flexible
schema to avoid having to tailor the audit trail format for different events.

### Should we allow user to opt out of audit?

A good reason for opting out is when users are dealing with dev/test instances
that are rapidly created and destroyed. They are not concerned about the change
history and do not want the associated overhead. The caveat is that users may
find that they *do* need the audit trail when something has gone wrong.

### What if a request failed catastrophically without any audit trail?

This is an implementation detail I would gladly leave to someone more capable to
recommend the solution!
