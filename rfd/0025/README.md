---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 25 Pluralizing CloudAPI CreateMachine et al

Currently, one cloudapi request is required per instance
created/stoped/started/actioned-on. There are two reasons that can be limiting:

1. If many many instances are involved (e.g. scaling up quickly), then one
   can run afoul of CloudAPI request throttling. Theoretically one can
   engineer CloudAPI clients to cope with throttling error codes and retry,
   but in practice that is more difficult and current clients don't support
   that. Also, that would still slow down scaling, which is undesirable.

2. Other clouds' APIs support creating/stopping/etc. multiple instances in
   one go: AWS
   (http://docs.aws.amazon.com/cli/latest/reference/ec2/run-instances.html)
   TODO: Links to the equiv on other clouds' CLIs and APIs would be helpful.
   Customer migrating to Triton/SDC would theoretically have easier lives
   if this impedance mismatch with CloudAPI didn't exist.


## Discussion

- https://devhub.joyent.com/jira/browse/PUBAPI-1117
- https://github.com/joyent/node-triton/issues/50
- scrum@ chat on 2015-01-11

A client-side-only solution isn't ideal because you are still time limited with
throttling. It is up for discussion whether that would be sufficient for
particular customer pains for shorter term.


## Proposal: CloudAPI major rev with pluralized endpoints

A potential way to support this.

- a major rev of the CloudAPI API version

- change the relevant "Machine" endpoints to be plural:

        CreateMachine -> CreateMachines
        StopMachine -> StopMachines
        ...

- Change the output of those endpoints to return new-line separated JSON
  objects. IOW, the response payload is basically the same as before when a
  single instance is involved. "Basically", because this might possibly change
  the "Transfer-Encoding: chunked" which technically won't be an identical
  response. Also if responses before has pretty-indented JSON, that will
  go away.

- Clarify how multiple UUIDs are to be passed. E.g. StopMachine
  (https://apidocs.joyent.com/cloudapi/#StopMachine) currently is:

        POST /:login/machines/:id?action=stop

    Which of these, or something diff?

        POST /:login/machines/:id[,:id2,...]?action=stop
        POST /:login/machines?action=stop,ids=:id1[,:id2,...]
        POST /:login/machines/stop?ids=:id1[,:id2,...]

- Clarify how inputs are limited for CreateMachine. E.g. You cannot pass in
  a name/alias for each created machine.

  *Optional:* What would be nice is joshw's proposed alias template support.
  I.e. one gives an alias template, e.g. "db-{{shortId}}", and each created
  machine gets an alias with that "{{shortId}}" rendered.

- *Optional:* Consider taking this API rev to streamify all JSON responses
  from cloudapi. IOW, instead of returning large JSON arrays in response
  bodies, we instead return (or possibly stream via `Transfer-Encoding:
  chunked`) newline-separated JSON objects. That scales much better: both
  server and client-side.



