---
authors: Marsell Kukuljevic <marsell@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 57: Update Triton to Node.js v4-TLS

Triton uses node 0.10 heavily for its services, with node 0.8 and 0.12 being
used in a few places. 0.8 is already EOL, with 0.10 EOL on October 1, and 0.12
EOL on December 31. Node.js v4 is currently specified for Long-Term Support
(LST), and will remain supported until April 2018.

It is not critical for internal services to be updated to LTS, although it is
desirable, but external services (e.g. Cloudapi and sdc-docker) should be
updated in order to keep abreast of security fixes.

The greatest difficulty updating to v4 will likely be the Node.js version in the
global zone.


## Proposal

1) Split sdc-clients apart into separate libraries.
2) Update each of the above libraries independently.

Then for each service:

3) Update the libraries it uses, including any of the above separate libraries.
4) Update the Node.js runtime.


### Library dependencies

Unfortunately, switching from 0.10 to v4 is not as simple as switching Node.js
runtimes, because of libraries we depend upon. Specifically: libuuid and
dtrace-provider both have C bindings. Older versions of libuuid and
dtrace-provider either don't work on 0.10, or don't work on v4. Only
libuuid 0.2.1 and higher, and dtrace-provider and higher, support both
0.10 and v4.

Complicating the situation is that many submodules and sub-submodules use older
libuuid and dtrace-provider modules. bunyan, restify, and ldapjs are examples.

Support across both 0.10 and v4 is highly desirable, because it allows us to
update libraries, and exercise them thoroughly, before updating the runtime as
well.

This is an incomplete list of modules that need updates:

* libuuid older than 0.2.1 (tested and confirmed to work)
* dtrace-provider older than 0.6.0 (tested and confirmed to work)
* bunyan older than 1.5.0 (1.8.2 tested and confirmed to work)
* ldapjs older than 1.0.0 (1.0.0 tested and appears to work)
* restify older than 4.0.1 (but see below)

restify 4.1.1 was tested and confirmed to mostly work, but breaks some proxy
functionality that is kept in a restify fork; updating to the restify mainline
breaks this functionality. As Trent Mick puts it:

---

I think best path forward is for me or someone to do the http\_proxy
fwd-porting to restify-clients#4.x and test it (and to restify-clients#5.x –
which is the current development tip, restify-clients#master is currently out of
date). The full set of things I want to do:

* get a restify 2.8.x branch and get our forked changes into it and a published
  2.8.(next) of restify to npm
* get the http\_proxy updates into restify-clients#4.x and #5.x
* do the no\_proxy work (another ticket on me: TOOLS-1398)

---


### Splitting sdc-clients

sdc-clients contains the clients for most of Triton's internal services. While
having them all in one place is convenient, having all clients in a single
module ties them all to the same dependency versions.

Updating and testing services would easier if there was less risk of breaking
other clients by updating various submodules.

Since we want to split sdc-clients anyway, here is yet another reason to do so.


### Order of service updates

The most pressing updates are to external services. These services are exposed
to hostile networks, and thus have the most pressing need of security patches:

* cloudapi
* sdc-docker
* muskie

Come October 1, we'd prefer to have these all tested and happily running on
Node v4.

Internal services are less pressing, particularly since we have our own in-house
expertise on Node.js' runtime. We should move these to v4 as well, but October
is a much softer deadline.

The global zone contains a private copy of Node.js in /usr/node, and agents in
the global zone come with their own copy of Node.js too. Josh Wilson notes
this could turn into a rather troublesome update. As a result, these updates
will likely be last.


### Problems with the GZ

There are two problems facing updating the private Node.js version in the global
zone to v4.

The first is a possible problem with illumos' runtime linker that Julien Gilli
and Robert Mustacchi dug into: https://gist.github.com/misterdjules/1eb7987dc0d59034efb4

Specifically, Node.js v4 binaries are linked against newer versions of the C++
runtime library, but the linker is linking against older versions of that
runtime than is allowed (a newer one isn't available). This should not happen.
To say this accidentally-running binary is a dodgy situation is putting it
mildly. 

Josh Wilson observes that agents need to support running on platforms back to
2013. Since the runtime linker problem may well need a platform update to fix,
this throws a serious roadblock in the way of updating the Node.js version of
agents and the GZ copy to v4.

