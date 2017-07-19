---
authors: Marsell Kukuljevic <marsell@joyent.com>, Trent Mick <trent.mick@joyent.com>
state: publish
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD 59 Update Triton to Node.js v4-LTS

Triton circa 2016 uses node 0.10 heavily for its services, with node 0.8 and
0.12 being used in a few places. 0.8 is already EOL, with 0.10 EOL on October 1,
and 0.12 EOL on December 31. Node.js v4 is currently specified for Long-Term
Support (LTS), and will remain supported until April 2018.

It is not critical for internal services to be updated to LTS, although it is
desirable, but external services (e.g. Cloudapi and sdc-docker) should be
updated in order to keep abreast of security fixes.

Expected work:
- Running node v4 in the global zone has some challenges. See the
  "Node in the GZ" section below.
- There will be a slog of updating node modules dependencies to those building
  cleanly against and supporting node v4 -- including dealing with
  incompatibilities when this involves crossing major versions.
  See the "Node modules" section below.
- Then there remains to be seen if there are subtle issues that result from
  a new major version of node. For example, event ordering changes, possible
  memory leaks.


## Current Status

- The 'imgapi' image is now using node v4 (IMGAPI-587)
- A number of modules have been updated to have node v4 support. See the
  [Node modules](#node-modules) section below.
- 'sdcnode' now includes node v4 builds for usage both in zones using
  sdc-minimal-multiarch-lts@15.4.1 as an origin, and in the GZ.
- In progress (as of 25 Oct 2016):
    - cloudapi (PUBAPI-1310)
    - vmapi (joshw)
    - v8plus (TOOLS-1586)
    - sdc-docker (DOCKER-947)
    - platform's node (OS-5742)
    - cmon (CMON-11)

```
$ grep NODE_PREBUILT_VERSION */Makefile | awk -F '(/|=)' '{print $1 " " $3}' | sort | awk '{printf("%-10s %s\n", $2, $1)}'
v0.12.9    binder
v0.10.25   electric-moray
v0.12.14   eng
v0.10.30   mahi
v0.10.40   manta-mackerel
v0.10.32   manta-madtom
v0.8.26    manta-mako
v0.10.26   manta-manatee
v0.10.32   manta-marlin
v0.10.25   manta-marlin-dashboard
v0.10.42   manta-medusa
v0.10.25   manta-minnow
v0.10.32   manta-mola
v0.10.48   manta-muskie
v0.10.30   manta-propeller
v0.10.25   manta-wrasse
v0.10.24   mantamon
v0.10.24   moray
v0.10.32   muppet
v0.12.10   node-task-agent
v0.10.26   node-ufds-controls
v0.10.26   registrar
v0.10.48   sdc-adminui
v0.12.14   sdc-agents-core
v0.8.28    sdc-amon
v0.10.32   sdc-booter
v0.10.48   sdc-cloudapi
v0.10.26   sdc-cn-agent
v0.10.42   sdc-cnapi
v0.10.26   sdc-config-agent
v0.10.48   sdc-docker
v0.10.46   sdc-docker-build
v0.10.26   sdc-firewaller-agent
v0.10.26   sdc-fwapi
v4.6.1     sdc-imgapi
v0.10.26   sdc-manatee
v0.10.32   sdc-manta
v0.12.14   sdc-mockcloud
v0.10.32   sdc-napi
v0.10.29   sdc-napi-ufds-watcher
v0.10.26   sdc-net-agent
v0.10.43   sdc-nfsserver
v4.4.0     sdc-nfsserver
v4.6.1     sdc-papi
v0.10.32   sdc-portolan
v0.10.26   sdc-sapi
v0.10.29   sdc-sdc
v0.10.26   sdc-system-tests
v0.10.26   sdc-ufds
v0.10.26   sdc-ufds-replicator
v4.6.0     sdc-vm-agent
v4.6.1     sdc-vmapi
v0.10.40   sdc-volapi
v0.10.26   sdc-workflow
v0.10.26   sdcadm
v0.12.9    triton-cns

$ grep NODE_PREBUILT_VERSION */Makefile | awk -F '(/|=)' '{print $1 " " $3}' | sort | awk '{printf("%-10s %s\n", $2, $1)}' | grep -v '^v4\.6' | wc -l
      52
```


## Order of service updates

The most pressing updates are to external services. These services are exposed
to hostile networks, and thus have the most pressing need of security patches:

* cloudapi (PUBAPI-1310)
* sdc-docker (DOCKER-947)
* muskie (MANTA-2999)
* imgapi (IMGAPI-587, done)
* CMON (CMON-11)
* adminui (ADMINUI-2314)
* portal (PORTAL-2113)

Internal services (including agents) are less pressing.

Dev Note: Here is one way you can get a fairly complete picture of node versions
in use in Triton components:

    mkdir ~/all
    cd ~/all

    # Clone all the repos. Here is a way (thought unfortunately still in a
    # private engadm.git repo):
    engadm clone-repos .

    grep NODE_PREBUILT_VERSION */Makefile


## Node in the GZ

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


## v8plus

The following binary modules use v8plus: zonename, lockfd, zutil, zsock,
illumos_contract, zsock-async. v8plus doesn't work with node v4 yet.
jclulow mentioned in chat that he could look at making v8plus work with v4.
A start at that work: https://github.com/joyent/v8plus/commits/jclulow
It was agreed that updating v8plus is worth at least looking at first:
<https://smartos.org/bugview/TOOLS-1586>.


## Node modules

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

## restify

It is suggested that you upgrade to restify 4.x (at least restify@4.2.0). Some
update notes:

1. Restify v4 introduced a breaking change in the function signature for custom
   `formatters`. For example, if you pass custom formatters to `restify.createServer`
   like this code in VMAPI (https://github.com/joyent/sdc-vmapi/blob/af77e72ae7b26f51d4ac3b5cb9484cd8d04b27dc/lib/vmapi.js#L179):

    ```
    this.server = restify.createServer({
        name: 'VMAPI',
        log: log.child({ component: 'api' }, true),
        formatters: {
            'application/json': formatJSON,    // <---- HERE
    ...
    ```

    then you will need to change your formatter function to take and call
    a callback. For example, this VMAPI change did that:
    <https://github.com/joyent/sdc-vmapi/commit/3f90d04>

   See this restify issue for details:
   <https://github.com/restify/node-restify/pull/851#issuecomment-251541881>

2. restify v3 introduced this breaking change:

    ```
    - #753 **BREAKING** Include `err` parameter for all \*Error events:
      Error events will all have the signature `function (req, res, err, cb)` to
      become consistent with the handling functionality introduced in 2.8.5.
      Error handlers using the `function (req, res, cb)` signature must be updated.
    ```

    For example if you have `server.on('NotFound', ...)` or similar.
    Note that this does **not** apply to `uncaughtException`, which continues
    to have this signature:

    ```
    server.on('uncaughtException', function (req, res, route, err) {
        ...
    });
    ```

3. restify v4 introduced a breaking subtlety in query string parsing (i.e.
   usage of the `queryParser()` plugin). This happened because of a default
   behaviour change in the "qs" module that `queryParser` uses for parsing.

   The suggested way to handle this is to (a) use restify@4.2.0 at least
   and (b) use the `queryParser` plugin as follows:

    ```
    restify.queryParser({allowDots: false, plainObjects: false})
    ```

   When eventually we move to restify 5.x and beyond (**but don't move to
   restify@5.x yet!**), the plugins are unbundled to a separate restify-plugins.
   Use at least restify-plugins@XXX (Trent has yet to submit the PR to
   restify-plugins with this functionality), and use the same options to
   queryParser (those will actually be the new default options):

    ```
    var restifyPlugins = require('restify-plugins');
    ...
    restifyPlugins.queryParser({allowDots: false, plainObjects: false})
    ```

   See <https://devhub.joyent.com/jira/browse/ZAPI-744> for gory details.


### restify-clients

If your repo only needs the clients (and possibly the error classes) from
restify, then you should switch to restify-clients@1.x and restify-errors@3.x.

The current suggested minimum version of these deps is as follows.
For modules/libraries (where my suggestion is to use semver ranges):

    "restify-clients": "^1.4.1",
    "restify-errors": "^3.0.0",

For apps (where the suggestion is to pin versions):

    "restify-clients": "1.4.1",
    "restify-errors": "3.1.0",

**Note**: We are intentionally avoiding restify-errors@4 which introduced a
backward incompatible change in error code names. The plan is a coming
restify-errors@5 that restores the compatible behaviour with v3 and
restify (the server component) before this change. See
<https://github.com/restify/clients/pull/42#issuecomment-251758900> for
discussion and details.

### sdc-clients

For node v4 support, update to sdc-clients@10.x or later. Note that this
version is a major bump that dropped the UFDS client. If you use the UFDS
client from sdc-clients, switch to "ufds@1.2.0" or later.


### ufds

Move to the "1.2.0" release if you can.


### wf-client

Move to "wf-client@0.2.0" or later.
https://github.com/joyent/sdc-wf-client


## How to update a zone to node v4

1. You need a 15.4.x-generation origin image. Until RFD 46 comes along that
   means (a) sdc-minimal-multiarch-lts@15.4.1 plus (b) adding a few pkgsrc
   package beyond minimal. Make changes similar to this to MG:

    ```
    -    "image_uuid": "fd2cc906-8938-11e3-beab-4359c665ac99",
    +    "// image_uuid": "sdc-minimal-multiarch-lts@15.4.1",
    +    "image_uuid": "18b094b0-eb01-11e5-80c1-175dac7ddf02",
         "pkgsrc": [
    +        "coreutils-8.23nb2",
    +        "curl-7.47.1",
    +        "gsed-4.2.2nb4",
    +        "patch-2.7.5",
    +        "sudo-1.8.15"
         ],
    ```

    This set of pkgsrc packages comes from
    <https://github.com/joyent/rfd/tree/master/rfd/0046#q2-base--or-minimal--or-something-in-between>.

    TODO: Is `dateutils-0.3.1nb1` required? IMGAPI is using it right now but
    there is not history for why that package (which isn't included in the RFD
    46 set) was included. For now we should exclude it from future users, and
    test removing it from IMGAPI's current list.

2. Update your Makefile to get a 4.x sdcnode build. Something like this:

    ```
    -NODE_PREBUILT_VERSION=v0.10.46
    +NODE_PREBUILT_VERSION=v4.6.1
     ifeq ($(shell uname -s),SunOS)
            NODE_PREBUILT_TAG=zone
    -       # Allow building on a SmartOS image other than sdc-smartos@1.6.3.
    -       NODE_PREBUILT_IMAGE=fd2cc906-8938-11e3-beab-4359c665ac99
    +       # Allow building on other than image sdc-minimal-multiarch-lts@15.4.1.
    +       NODE_PREBUILT_IMAGE=18b094b0-eb01-11e5-80c1-175dac7ddf02
     endif
    ```

3. Update your Node modules deps and code per the "Node modules" section notes
   above. For a complete example see the change to IMGAPI for this:
   <https://github.com/joyent/sdc-imgapi/commit/7d0b4b7dedc7c36ba1eec23394d009567b6ef35a>

4. To test your changes, one way is to use Jenkins' `TRY_BRANCH` builds:

    (a) Push your changes to a feature branch (of MG and your repo, say,
        sdc-cnapi.git)
    (b) Make a `TRY_BRANCH=<feature branch name>` build in Jenkins.
    (c) Update your COAL to that image, e.g.: `sdcadm up -C experimental cnapi`
    (d) Or possibly build a COAL with your image, by adding something like this
        to `build.spec.local` in your sdc-headnode.git clone:

        ```
        "zones": {
            "cnapi": {
                "source": "manta",
                "branch": "<feature branch name>"
            }
        },
        ```
