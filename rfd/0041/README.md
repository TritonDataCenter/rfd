---
authors: Dave Pacheco <dap@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 41 Improved JavaScript errors

We've long used the [verror](https://github.com/davepacheco/node-verror) module
to represent JavaScript errors.  Historically, the main goals were:

* to make it easier to construct useful messages, by providing a printf-style
  format string
* to make it easier to augment lower-level errors with higher-level information,
  by supporting "causes" and building up accretive error messages

This way, instead of getting a message like `some-cli: connection refused`, you
can get something more specific like `some-cli: contacting service XYZ to do
operation Z: connection refused`.  This is a simple step, but it can save both
end users and engineers lots of time just trying to understand what happened
when something went wrong, so it's a big step forward for user experience and
debuggability.

There are two gaps in the current VError functionality:

**1. There's no built-in support for adding informational properties to
VErrors.** In the above example, it would be useful to be able to report which
IP address and TCP port had been contacted.  If there was a request-id
associated with the issue, we could include that on all the Errors as well.
These properties could be used for:

* log analysis to aggregate errors by any of these properties (e.g., errors by
  kind, or by remote IP address)
* programmatically correlating related events from multiple logs, based on these
  properties (e.g., request-id)
* generating custom messages.  While localization is presumably not a priority
  for us right now, it's occasionally useful even today for programs to generate
  their own more specific message about an Error, using these properties to fill
  in details.  (For example, Moray might want to rewrite a PostgreSQL error
  message to report that bucket X does not have a particular property defined in
  its schema instead of just saying that PG index Y was not found.)

**2. When you chain VErrors together, you can confuse callers that are looking
at an Error's `name` property to figure out what kind of Error they got.**
Details below.

These are discussed in node-verror issues
[10](https://github.com/davepacheco/node-verror/issues/10) and
[11](https://github.com/davepacheco/node-verror/issues/11).  There are several
related issues that have been filed separately.

This RFD contains proposals to address both of these issues.

## Proposal

### Informational properties

We propose adding information properties to Errors by specifying them in the
constructor.  These properties should be strings, numbers, booleans, `null`, or
objects and arrays of other supported informational properties.  (These should
not contain functions, references to native objects, or `undefined`.  They're
intended to be serialized, compared, and plugged into strings, not interacted
with in complex ways.) Here's an example:

```javascript
    var err1 = new VError('something bad happened');
    /* ... */
    var err2 = new VError({
        'name': 'ConnectionError',
        'cause': err1,
        'info': {
            'errno': 'ECONNREFUSED',
            'remote_ip': '127.0.0.1',
            'port': 215
        }
    }, 'failed to connect to "%s:%d"', '127.0.0.1', 215);
```

Callers extract this information using the new `VError.info(err)` function,
which returns an object containing all of the informational properties of the
error _and each of its causes_, with higher-level properties overriding
lower-level ones.  The `info()` method is on `VError` so that callers don't
have to check it exists (and we don't want to polyfill `Error`).  Here's an
example:

```javascript
   console.log(err2.message)
   console.log(VError.info(err2))
```

would output:

    failed to connect to "127.0.0.1:215": something bad happened
    { errno: 'ECONNREFUSED', remote_ip: '127.0.0.1', port: 215 }

This works with cause chaining.  The next level up the stack might create:

    var err3 = new VError({
        'name': 'RequestError',
        'cause': err2,
        'info': {
            'errno': 'EBADREQUEST'
        }
    }, 'request failed');

Now, this code:

    console.log(err3.message);
    console.log(VError.info(err3));

prints out:

    request failed: failed to connect to "127.0.0.1:215": something bad happened
    { errno: 'EBADREQUEST', remote_ip: '127.0.0.1', port: 215 }

To summarize, with this approach:

* The error message is unchanged: it's augmented at each level of the stack to
  produce a clear summary of what happened.
* Each layer of the stack can add informational properties with minimal
  boilerplate and without worrying about clobbering all of the lower-level
  properties.
* Consumers don't need to care which level of the stack added a given property.
* Consumers can dump out all of the informational properties by serializing
  the return value of `info()`.

**Alternative approaches:** It's admittedly a little jarring that this approach
requires a separate method (`VError.info()`) to fetch these properties, since
most code today just hangs properties directly off the Error.  However, the
existing approach doesn't compose very well.  To avoid clobbering all of the
low-level properties when we wrap a low-level error, we'd need to shallow-copy
the properties.  But which properties do we copy?  Presumably we skip `name`,
`message` (which is treated specially anyway), and `stack`.  But there are
several other common but less-standard properties we'd probably want to skip
too, like `fileName` and `lineNumber`.  This list [varies across JavaScript
runtimes](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Error)
and can change in future revisions of JavaScript or the runtime environment.

There are also the private properties used by other Error subclasses.  VError
has its own private properties used to keep track of causes.  Other subclasses
are well within their rights to define their own properties, and shallow-copying
them up can be the wrong thing to do.

If users want to enumerate the informational properties (e.g., for a log entry)
with the traditional approach, they can't distinguish these properties from the
private properties that the Error uses for its own purposes (which they should
not log).  This has all the same problems mentioned above: keeping track of the
fuzzy list of well-known properties mentioned above, potentially breaking with
future changes, and failing to deal with private properties of Error
subclasses.

For these reasons, we decided it was safer and more robust to provide the
informational properties up front in the caller and access them only through a
function-based interface.


### Determining an Error's type when there are multiple causes

Today, the main way to identify an Error's type is using the `name` property.
This breaks when higher-level code wants to wrap a lower-level error and provide
a new cause.  For example, the [new Fast client](../0033/README.md) wraps all
server errors in a FastServerError.  This allows callers to determine whether
any problem was a server-side issue, a client-side issue, a transport-level
issue, or something else.  But it breaks clients that were using the `name`
property to look for specific server-side errors.  For compatibility, the Fast
client has a mode to avoid wrapping these errors, but we want to have a way for
code to check for specific kinds of errors that doesn't break every time a
component wants to add an intermediary to the cause chain.

To do this, we propose that instead of checking for `err.name`, callers should
use the new `VError.findCauseByName(err, name)` function.  If `err` or any of
its causes has name `name`, then this function returns that error.  Otherwise,
it returns null.  So to look for a specific server-side error, callers would
use:

```javascript
    if (VError.findCauseByName(err, 'BucketNotFoundError') !== null) {
```

instead of:

```javascript
    if (err.name == 'BucketNotFoundError') {
```

Like `VError.info()`, this function is global on VError so that callers can use
it with any Error object, not just VErrors.


## Implementation, examples, and consumers

The proposed implementation is basically complete, and provided in this branch:
[https://github.com/davepacheco/node-verror/tree/dev-issue-10](https://github.com/joyent/node-fast2/blob/master/lib/fast_client.js).

The new interfaces are used heavily in the new node-fast implementation,
particularly in the client:
[https://github.com/joyent/node-fast2/blob/master/lib/fast_client.js](https://github.com/joyent/node-fast2/blob/master/lib/fast_client.js).

Server errors are always wrapped as mentioned above:

```javascript
this.requestFail(request, new VError({
    'name': 'FastServerError',
    'cause': cause
}, 'server error'));
```

Then requests are wrapped and annotated as well:

```javascript
request.frq_error = new VError({
    'name': 'FastRequestError',
    'cause': error,
    'info': {
        'rpcMsgid': request.frq_msgid,
        'rpcMethod': request.frq_rpcmethod
    }
}, 'request failed');
```

The branch above also refactors the constructor implementations for the various
classes to ensure they work the same across all classes; fleshes out the
documentation about VErrors, including these interfaces and the underlying
design choices; and upgrades the build system to a more modern version of the
standard Joyent build.


## Summary of impact

All of these changes are fully backwards-compatible.  The existing VError
constructor can already take an object with named properties in order to
support `cause` and a few other properties.  We've just added a new `info`
argument, plus two top-level methods.  Callers that provide a string or Error
as their first argument get the existing behavior for those cases.  They will
have no new informational properties, though the properties reported by their
causes (in the case of the Error argument) will still be reported by
`VError.info()`.

The only directly affected repository is node-verror.  Other repositories will
be affected as they opt into the new behavior.  The only people who interact
directly with these features are engineers writing code to generate errors,
wrap errors, or analyze errors based on the programmatic information.

We may want to modify bunyan to use VError.info() when it logs an error.
