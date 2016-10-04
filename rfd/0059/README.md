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

# RFD 59: Update Triton to Node.js v4-LTS

Triton uses node 0.10 heavily for its services, with node 0.8 and 0.12 being
used in a few places. 0.8 is already EOL, with 0.10 EOL on October 1, and 0.12
EOL on December 31. Node.js v4 is currently specified for Long-Term Support
(LTS), and will remain supported until April 2018.

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
* imgapi
* CMON
* adminui
* portal

Come October 1, we'd prefer to have these all tested and happily running on
Node v4.

Internal services are less pressing, particularly since we have our own in-house
expertise on Node.js' runtime. We should move these to v4 as well, but October
is a much softer deadline.

The global zone contains a private copy of Node.js in /usr/node, and agents in
the global zone come with their own copy of Node.js too. Josh Wilson notes
this could turn into a rather troublesome update. As a result, these updates
will likely be last.


### Node in the GZ

There are some issues that make running Node >=v4.x in the GZ difficult:

- There is a bug in the illumos' runtime linker where a binary that requires
  a lib version newer than that in the platform still runs instead of failing.
  Details from Julien Gilli and Robert Mustacchi here:
  https://gist.github.com/misterdjules/1eb7987dc0d59034efb4
  (and more notes here: https://gist.github.com/misterdjules/eae9ec70dc1d91fb8dd1).
  This issue is just relevant to be away that some binaries might appear to
  run fine until they run into a crash if a newer lib version symbol is
  actually used. Julien indicates that this is likely the case for coming
  Node v7 changes.
- Node v4 and greater require at least gcc v4.8 to build. Our older images
  only have v4.7. This means we need to update to v15.4.x LTS origin images.
- That newer gcc means linking to a gcc runtime that is newer than what is
  provided in the platform. The solution here is to include the needed GCC
  runtime libs with our sdcnode builds and set node's RPATH/RUNPATH to
  pick those up. See TOOLS-1555 and TOOLS-1558 for this work.

As of TOOLS-1558, there is now a sdcnode v4.6.0 build for 'gz' usage. E.g.:

    NODE_PREBUILT_TAG = gz
    NODE_PREBUILT_VERSION = v4.6.0
    NODE_PREBUILT_IMAGE = 18b094b0-eb01-11e5-80c1-175dac7ddf02

Likely will require changing the jenkins job params to build on a slave
using a multiarch-*@15.4.1 image.  See sdc-imgapi.git for an example
(after IMGAPI-587 is complete).


## Notes on specific node packages

### bunyan

tl;dr: Update to latest 1.x. No compat issues to worry about.

Bunyan >= 1.5.1 supports building against node v4. However it is suggested
that at least Bunyan 1.8.1 be used because it includes this fix to the CLI
to use `bunyan -p` on node 4.x and above:

- [issue #370] Fix `bunyan -p ...` (i.e. DTrace integration) on node
  4.x and 5.x.

The only incompatible change in Bunyan was from 0.x to 1.x with the CLI's
`bunyan -c CODE` option. IOW, there hasn't been an incompatibility in the
node.js module usage and therefore there isn't a reason to not upgrade to
the latest 1.x.


### ldapjs

tl;dr: If you are just building filters for Moray: switch to `moray-filter`.
If you are just building filters for UFDS: switch to `ldap-filter`.
Else if you aren't node-ufds.git or sdc-ufds.git, let's talk and perhaps 0.8.0
is adequate.

If your app is only using the "filters" functionality of ldapjs, it is
suggested that you switch to 'node-ldap-filter'
(https://github.com/pfmooney/node-ldap-filter).

- 1.0.0: This was a large change that added node v4 support (by updating its
  deps), but also incompatibilities for which we don't necessarily grok
  all the implications.

    [Patrick Mooney]
    > 1.0 changed error handling
    > ...
    > IIRC, the circumstances of when error objects are emitted for things like
    > socket errors, etc
    > when/how those errors are emitted

  At this point, switching from 0.7.x to 1.0.0 would require some digging
  and testing. Consider 0.8.0 as an alternative.

- 0.8.0: This was a quiet compatibility release that Patrick added after
  Trent and he discussed the issues here. The branch point was commit
  aed6d2b043715e1a37c45a6293935c25c023ebce -- a number of commits after
  v0.7.1, and the commit upon which node-ufds currently depends -- and
  then it updated dependencies required to get a clean 'npm install' with
  node v4.

- 0.7.1: The last release before 1.0.0. It has a optional dep on
  dtrace-provider@0.2.8, so while it installs with just a warning, there is
  a lot of noise (and dtrace-y features won't work):

    ```
    gyp ERR! node -v v4.5.0
    gyp ERR! node-gyp -v v3.4.0
    gyp ERR! not ok
    npm WARN optional dep failed, continuing dtrace-provider@0.2.8
    [10:45:33 trentm@danger0:~/src/node-ldapjs ((0a88109...))]
    $ echo $?
    0
    ```

- 0.7.0: This has required "dependencies" that don't compile on node v4, e.g.
  dtrace-provider.


### moray

tl;dr: Update to latest, or at least the following commit to get node v4
support. I don't know of any compat issues.


```
commit 31c0902f47408d43bc9684e200b1ee93e13c2477
Author: Marsell Kukuljevic <marsell@joyent.com>
Date:   Sun Jul 3 19:52:27 2016 +1000

    MORAY-342: updates deps for node 4.x support, try no. 2.
```

### sdc-clients

TODO: lots here


### ufds

Move to the "1.2.0" release if you can.
