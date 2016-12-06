---
authors: David Pacheco <dap@joyent.com>
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

# RFD 73 Moray client support for SRV-based service discovery

## Background

Historically, the Moray service was exposed to consumers on port 2020.  For a
long time now, the service listening there was actually an haproxy that balances
incoming connections across actual Moray processes listening on ports 2021
through 2024.  Moray's registrar causes DNS A records to be published with the
IP of the zone.  Clients find Moray instances by looking up A records for the
Moray hostname, finding a bunch of IPs, and establishing connections to port
2020 on those IPs.

The use of haproxy on port 2020 is suboptimal for a number of reasons, including

* it's impossible for clients to reasonably load-balance across multiple
  instances because they don't know which processes they're connected to
* debugging is hindered by the extra level of indirection
* the haproxy we're using uses a grossly inefficient socket poller, which
  becomes especially problematic at scale

To address this, Moray's registrar configuration was modified to publish DNS SRV
records (in addition to the A records).  SRV records specify both an IP address
and port.  This way, there is one record per process, and clients know exactly
which backends exist.  In this model, clients look up SRV records for the Moray
hostname (using a "\_moray.\_tcp" prefix) and find a bunch of IPs _and ports_,
and establish connections to those IP/port pairs.  If no SRV records are found,
then clients fall back to the previous scheme.

The intention is to enable support for SRV everywhere, eliminate use of haproxy,
and eventually eliminate the haproxy instance inside each Moray zone altogether.
This will address the three problems above.


## Goals

It should be as easy as possible for Moray-using components to start using
SRV-based service discovery, and they should use that by default.

It should also be possible for operators to configure components (both servers
and CLI tools) to talk individual zones or processes for debugging and testing.


## Proposal for Node API

The clearest way to express what's desired is to have consumers be explicit
about what they want.  We'll say that clients _must_ specify exactly one of the
following combinations of properties:

* `srvDomain`: use SRV-record-based discovery, looking for SRV records on
  `_moray._tcp.$srvDomain`.
* `host` (and optionally `port`): use A-record-based discovery.  If `port` is
  not specified, use port 2020.  If `host` is an IP address, connect directly to
  it.  Otherwise, connect to any combination of the IP addresses referenced by
  `host`.
* `url`, which contains at least a host and possibly a port, and behaves the
  same way as above (using only A records)

It's a programmer error to specify a combination of these (e.g., `srvDomain`
with any of `url`, `host`, or `port`).

Here are some examples:

```javascript
    /*
     * Common case, and the easiest way to use SRV-based discovery.  This will
     * fall-back to A-record-based discovery if SRV records do not exist.
     */
    client = moray.createClient({
        'log': ...,
        'srvDomain': '1.moray.emy-10.joyent.us'
    })


    /* point client at a specific Moray process (no DNS) */
    client = moray.createClient({
        'log': ...,
        'host': '10.1.2.3'
        'port': 2021
    });

    client = moray.createClient({
        'log': ...,
        'url': 'tcp://10.1.2.3:2021'
    });


    /* point client at haproxy in a specific Moray zone (no DNS) */
    client = moray.createClient({
        'log': ...,
        'host': '10.1.2.3'
    });

    client = moray.createClient({
        'log': ...,
        'url': 'tcp://10.1.2.3'
    });


    /* point client at any 1.moray instance, port 2021 (uses A records) */
    client = moray.createClient({
        'log': ...,
        'host': '1.moray.emy-10.joyent.us'
        'port': 2021
    });

    client = moray.createClient({
        'log': ...,
        'url': 'tcp://1.moray.emy-10.joyent.us:2021'
    });


    /* point client at any 1.moray instance, haproxy (uses A records) */
    client = moray.createClient({
        'log': ...,
        'host': '1.moray.emy-10.joyent.us'
    });

    client = moray.createClient({
        'log': ...,
        'url': 'tcp://1.moray.emy-10.joyent.us'
    });


    /* illegal: cannot specify "srvDomain" and "port" */
    client = moray.createClient({
        'log': ...,
        'srvDomain': '1.moray.emy-10.joyent.us',
        'port': 2020
    });
```

Note that in Moray v2, clients can configure the host and port by specifying
"domain" and "defaultPort" in `cueballOptions` directly.  That's no longer
recommended because it doesn't allow that component to be configured to use
A-record-based discovery.  We propose to make it illegal to specify
`cueballOptions.domain`.  This would be a major bump to the Moray client (to
v3.0.0), which will also make it easy to communicate this major configuration
change.

In terms of the implementation: for the immediate future, if "srvDomain" is
specified, the client will specify cueball options with "domain" = the value of
the "srvDomain" property and "service" = "_moray._tcp".  Otherwise, "domain" is
the value of "host" (or the host in the URL) and "service" is set to a bogus
value to ensure that SRV records will not be located.  Longer-term, we may
replace this mechanism with an explicit cueball configuration to ensure that we
only find the records we want.


## Proposal for server configuration

As a reminder: we want Moray-using components like manta-muskie or sdc-docker to
use SRV-based discovery in the common case.  But it should also be possible to
override these to point these components at specific instances.

### Triton example

Components in Triton should provide a block in their configuration file template
that looks like this:

    "moray": {
        "srvDomain": "{{{MORAY_SERVICE}}}"
        "dns": {
            "resolvers": [ "{{{BINDER_SERVICE}}}" ]
        }
    }

(Note that use of "dns.resolvers" here causes us to opt into Cueball's
bootstrap-resolver mode.  That's orthogonal to all the changes described in this
document, but it's an important change to roll out to Moray consumers.)

To construct a Moray client, you would do something like this:

```javascript
    var config, morayOptions, morayClient;

    config = /* read config file, parse as JSON, and validate it */
    morayOptions = mod_jsprim.deepCopy(config.moray);
    morayOptions.log = ...
    morayClient = mod_moray.createClient(morayOptions);
```

In this example, the config block might be transformed to something like this by
config-agent:

```json
    "moray": {
        "srvDomain": "moray.emy-10.joyent.us",
        "dns": {
            "resolvers": [ "binder.emy-10.joyent.us" ]
        }
    }
```

A developer or operator who wanted to point their client at some specific Moray
zone could modify the configuration file to look like this:

```json
    "moray": {
        "host": "172.25.10.17"
    }
```

or any of the other examples under "Configuring clients" above.


### Manta example

Manta looks similar, except that:

1. There are many different Moray shards in Manta.  `{{{MORAY_SERVICE}}}` won't
   work.  You'll need something like `{{MARLIN_MORAY_SHARD}}`,
   `{{STORAGE_MORAY_SHARD}}`, or `{{ELECTRIC_MORAY}}`.
2. The service name for the nameservice is `nameservice` instead of `binder`.

Here's an example that talks to the Marlin shard:

    "marlin": {
        "moray": {
            "srvDomain": "{{MARLIN_MORAY_SHARD}}",
            "dns": {
                "resolvers": [ "nameservice.{{DOMAIN_NAME}}" ]
            }
        }
    }

This would get turned into:

```json
    "marlin": {
        "moray": {
            "srvDomain": "1.moray.emy-10.joyent.us",
            "dns": {
                "resolvers": [ "nameservice.emy-10.joyent.us" ]
            }
        }
    }
```

The code using it would be similar, but it would begin with
`config.marlin.moray`.


### Other Moray constructor options

We expect that consumers will not need to configure other cueball options (like
`recovery`, `target`, and `maximum`) because the defaults will be appropriate
for nearly all components.  However, these can be configured by specifying them
in `cueballOptions`, just as in Moray v2.

Other client options (like `failFast`) are orthogonal to all this and continue
to be supported.


## Proposal for CLI tools

Moray CLI tools currently take the `-h hostname` option to specify a hostname or
IP address, the `-p port` option to specify a port, and the `MORAY_URL`
environment variable to specify a URL.  The command-line arguments override the
environment variable, which overrides the default of hostname `127.0.0.1` and
port `2020`.

The proposal is to keep this behavior the same: the `-h` and `-p` options would
be used to specify a hostname (or IP address) and port for use with
non-SRV-based discovery.  A new option `-s srvDomain` would be used to specify a
service name for SRV-based discovery with A-based fallback.

As with the Node client, it would be illegal to specify `-s` with either `-h` or
`-p`.

Examples:

    # Common case: use SRV if available and fall back to A if not.
    listbuckets -s 1.moray.emy-10.joyent.us

    # Point client at a specific Moray process (no DNS)
    listbuckets -h 10.1.2.3 -p 2021
    MORAY_URL=tcp://10.1.2.3:2021 listbuckets

    # Point client at haproxy in a specific Moray zone (no DNS)
    listbuckets -h 10.1.2.3
    listbuckets -h 10.1.2.3 -p 2020
    MORAY_URL=tcp://10.1.2.3 listbuckets
    MORAY_URL=tcp://10.1.2.3:2020 listbuckets

    # Point client at any 1.moray instance, port 2021 (uses A records)
    listbuckets -h 1.moray.emy-10.joyent.us -p 2021
    MORAY_URL=tcp://1.moray.emy-10.joyent.us:2021 listbuckets

    # Point client at any 1.moray instance, haproxy (uses A records)
    listbuckets -h 1.moray.emy-10.joyent.us -p 2020
    MORAY_URL=tcp://1.moray.emy-10.joyent.us:2020 listbuckets
    listbuckets -h 1.moray.emy-10.joyent.us
    MORAY_URL=tcp://1.moray.emy-10.joyent.us listbuckets

    # Illegal: cannot specify "srvDomain" and "port"
    listbuckets -s 1.moray.emy-10.joyent.us -p 2020

The algorithm here is:

- If -s is specified, make sure that -h and -p are not specified, and construct
  a Moray client argument with a `srvDomain` property.
- If `MORAY_SERVICE` is specified in the environment, construct a Moray client
  argument with a corresponding `srvDomain` property.
- Otherwise, we'll create a Moray client argument with `host` and `port`
  properties.  We'll start with host = 127.0.0.1 and port = 2020.
  - If `MORAY_URL` is specified, parse it.  Replace the host with the host from
    the URL.  If the port was specified, replace the port with the port from the
    URL.
  - If -h HOST is specified, replace the host with HOST.
  - If -p PORT is specified, replace the port with PORT.


## Limitations of this approach

As described above, we would bump the major version of the client to v3.0.0.
Most consumers today are likely on pre-2.0 versions, and it won't be much harder
to move from v1 to v3 than it is from v1 to v2.  Consumers on v2.0.0 will need
to make the above configuration changes.  We will provide very clear
instructions with examples so that this is as easy as possible.

Nearly every instance of `MORAY_URL` will likely need to be replaced with
`MORAY_SERVICE`.

Older clients and environments with `MORAY_URL` specified will continue to work.
They'll just be using A records instead of SRV records.  To get us to an all-SRV
world, we can smoke out the components that need to be updated by seeing which
components connect to haproxy.


## Alternative approaches

The obvious other approach would be to attempt to interpret the existing `host`,
`port`, and `url` properties and `MORAY_URL` environment variable.  There are a
few easy cases:

- If an IP address is specified in the host and a port was specified, connect
  to that IP and port.
- If an IP address is specified in the host and no port was specified, connect
  to that IP port 2020.

But what if the host is not an IP address?

If there was no port specified, we could use SRV-based discovery and fall back
to A-based discovery.  If there was a port specified, we could use A-based
discovery and connect to the specified port.  This results in the surprising
behavior that explicitly specifying port 2020 (what has historically been the
default port) is totally different than leaving it out.

Relatedly, many (most?) consumers of the client library and CLI tools already do
specify both a host and port for completeness.  These consumers will still need
to be updated anyway to use SRV-based service discovery.

Unrelated to all that: We could potentially avoid the major version bump
associated with this change by allowing consumers to specify
cueballOptions.domain, and treating that the same way as if that value had been
specified for "service".  The major bump allows us to keep the
already-cluttered interface clearer, and also makes it easier to communicate
and check for SRV-readiness.


## End user impact

End users of Triton and Manta aren't affected by these changes.

Operators who have copies of the Moray tools will need to update their
environments and configurations accordingly.


## Security implications

There are no known security implications of these changes.


## Compatibility, repositories affected, and rollout

The bulk of the change will be in `node-moray` and `moray-test-suite`.  We will
publish node-moray@3.0.0 as described above.

Many Moray-using components will eventually want to upgrade to this version by
following the instructions provided by this work.


## See also

* [RFD 33 Moray client v2](https://github.com/joyent/rfd/blob/master/rfd/0033/README.md)
* [MORAY-380 translateLegacyOptions not setting "service"](https://devhub.joyent.com/jira/browse/MORAY-380)
