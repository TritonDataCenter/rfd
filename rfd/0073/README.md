---
authors: David Pacheco <dap@joyent.com>
state: publish
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
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

### SRV-based discovery

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

### Bootstrap resolvers

There's an additional problem not strictly related to SRV-based discovery, but
which is introduced by cueball's more sophisticated use of nameservers.  To
better survive nameserver failure without introducing significant latency,
cueball may give up on a query when a majority of its configured nameservers
report no results.  This introduces a problem in environments with multiple,
non-equivalent nameservers configured (also called split DNS).  Namely, if the
admin network has a Triton resolver, and is also configured with external
resolvers (as is the case in some deployments), cueball might give up attempting
to resolve an internal name like "moray.emy-10.joyent.us" if both of the
external resolvers respond before the internal one does.  This problem can also
happens in Manta deployments, where there are both Manta and Triton nameservers
present, and in development environments with all three kinds of resolvers
present.

To address this, cueball supports a [Dynamic Resolver
mode](https://github.com/TritonDataCenter/node-cueball#dynamic-resolver-mode) (also called
bootstrap resolver mode).  In this mode, cueball is configured with a DNS domain
for the nameservers themselves (e.g., "binder.emy-10.joyent.us" for the Triton
nameservers).  It queries _all_ configured resolvers for this domain and then
restricts future queries only to those nameservers.  In this case, this ensures
that we'd only use the Triton nameservers for resolving future domains.

Clients can make use of this already using Moray v2 by specifying the
"resolvers" cueball option, but this RFD describes new command-line options and
environment variables to configure this.


## Goals

It should be as easy as possible for Moray-using components to start using
SRV-based service discovery with bootstrap resolvers, and they should use that
by default.

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

Bootstrap resolvers are configured by passing "resolvers" through in
"cueballOptions", the same as today.

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
the "srvDomain" property and "service" = "\_moray.\_tcp".  Otherwise, "domain"
is the value of "host" (or the host in the URL) and "service" is set to a bogus
value to ensure that SRV records will not be located.  Longer-term, we may
replace this mechanism with an explicit cueball configuration to ensure that we
only find the records we want.


## Proposal for server configuration

As a reminder: we want Moray-using components like manta-muskie or sdc-docker to
use SRV-based discovery with bootstrap resolvers in the common case.  But it
should also be possible to override these to point these components at specific
instances.

### Triton example

Components in Triton should provide a block in their configuration file template
that looks like this:

    "moray": {
        "srvDomain": "{{{MORAY_SERVICE}}}"
        "cueballOptions": {
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
        "cueballOptions": {
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
            "cueballOptions": {
                "resolvers": [ "nameservice.{{DOMAIN_NAME}}" ]
            }
        }
    }

This would get turned into:

```json
    "marlin": {
        "moray": {
            "srvDomain": "1.moray.emy-10.joyent.us",
            "cueballOptions": {
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
non-SRV-based discovery.  A new option `-S srvDomain` would be used to specify a
service name for SRV-based discovery with A-based fallback.  The `MORAY_SERVICE`
environment variable can be used to specify a default value.  As with the Node
client, it would be illegal to specify `-S` with either `-h` or `-p`.  It's not
illegal to specify `MORAY_SERVICE` with `MORAY_URL`.  The former takes
precedence (as long as `-h` and `-p` are not also specified).

Examples:

    # Common case: use SRV if available and fall back to A if not.
    listbuckets -S 1.moray.emy-10.joyent.us

    # The same, configured from the environment.
    MORAY_SERVICE=1.moray.emy-10.joyent.us listbuckets

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
    listbuckets -S 1.moray.emy-10.joyent.us -p 2020

The algorithm here is:

- If -S is specified, make sure that -h and -p are not specified, and construct
  a Moray client argument with a `srvDomain` property.
- If -h or -p are specified, construct a Moray client argument with "host" and
  "port", using fallback values from MORAY\_URL and defaults (host 127.0.0.1
  port 2020) if needed.
- If `MORAY_SERVICE` is specified in the environment, construct a Moray client
  argument with a corresponding `srvDomain` property.
- Otherwise, we'll create a Moray client with host and port derived from
  MORAY\_URL and default values.

To support bootstrap resolvers, we also introduce the `-b DOMAIN` option and
`MORAY_BOOTSTRAP_DOMAIN` environment variable, which would be set to
`binder.mydatacenter.joyent.us` for Triton and
`nameservice.mydatacenter.joyent.us` for Manta.  Existing places that configure
MORAY\_URL with a hostname will likely want to set MORAY\_SERVICE and
MORAY\_BOOTSTRAP\_DOMAIN instead.


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

* [RFD 33 Moray client v2](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0033/README.md)
* [MORAY-380 translateLegacyOptions not setting "service"](https://devhub.joyent.com/jira/browse/MORAY-380)


## Appendix: Moray client constructor arguments

The Moray client has historically accepted a variety of complex arguments, and
the list of options accepted and the constraints around which options are
allowed with which other options has changed over time.  This section
summarizes the state up to and including this change.

### Backend discovery

In Moray v1, consumers always specified either `host` and `port` _or_ `url`.
`url` would only be used if `host` was not also specified.  (Making the
implementation even more confusing, the MorayClient constructor only processed
`host` and `port`, but the `createClient` wrapper converted the `url` form into
the `host` and `port` form.  That's all the wrapper did.)  

In Moray v2, the first-class way to specify this information was to specify
`cueballOptions`, and especially `cueballOptions.domain` and
`cueballOptions.defaultPort`.  `host`, `port`, and `url` were supported
in a backwards-compatible way, but they could not be used with any
`cueballOptions`.  As described in this RFD, this approach does not allow
consumers to distinguish between SRV-based discovery with a hostname vs.
A-record-based discovery with a hostname.

With Moray v3 as specified by this RFD, the first-class way to specify this
information is to specify `srvDomain`, `url`, _or_ `host` and `port` (now
first-class options again).  `url`, `host`, and `port` are still interpreted in
the backwards-compatible way, and they specify IP-based or A-record-based
service discovery.

In summary:

Name                   | Meaning                             | before v2 | v2            | v3 
---------------------- | ----------------------------------- | --------- | ------------- | ---
srvDomain              | hostname for SRV lookup             | N/A       | N/A           | okay
host                   | IP address or hostname for A lookup | okay      | discouraged   | okay
port                   | TCP port (defaults to 2020)         | okay      | discouraged   | okay
url                    | combination of `host` and `port`    | okay      | discouraged   | okay
cueballOptions.domain  | hostname for SRV/A lookup           | N/A       | okay (A only) | disallowed
cueballOptions.service | service prefix for SRV lookup       | N/A       | okay          | okay

### Timeouts and limits

Moray v1 supported the following options:

Name              | Meaning                            
----------------- | -----------------------------------
connectTimeout    | connection establishment timeout
dns.checkInterval | how often to re-resolve supplied hostname
dns.resolvers     | DNS nameservers to use
dns.timeout       | timeout on DNS operations
maxConnections    | number of connections to maintain to each backend found in DNS
retry             | node-backoff policy (used confusingly in different contexts)

In Moray v2 and Moray v3, these options are all supported as "legacy" options.

If necessary, consumers should instead use a combination of `failFast` and
options supported by cueball.  **The expectation with Moray v2 and later is
that other than `failFast`, these tunables would very rarely need to be
configured, if ever, because the defaults should be appropriate for all servers
(and clients if `failFast` is specified).**  Supported tunables include:

Name                             | Meaning
-------------------------------- | ----------
failFast                         | for CLI tools: emit `error` upon failure to establish a connection
cueballOptions.target            | the target number of connections to maintain across all backends
cueballOptions.maximum           | the maximum number of connections to maintain across all backends
cueballOptions.maxDNSConcurrency | number of nameservers to query concurrently
cueballOptions.recovery.default  | timeouts, delays, and limits for TCP connection establishment
cueballOptions.recovery.dns      | timeouts, delays, and limits for DNS requests
cueballOptions.recovery.dns\_srv | timeouts, delays, and limits for DNS SRV requests
cueballOptions.resolvers         | DNS nameservers to use or bootstrap resolvers

Legacy options cannot be combined with `cueballOptions`.  The cueball options
are generally much more flexible than the legacy options.  They include backoff
of both timeouts and delays.  There's no analog to `dns.checkInterval`, but
that's not expected to be a tunable consumers will want to configure.


### Other arguments

Required | Name             | As of  | Meaning
-------- | ---------------- | ------ | -------
yes      | log              | always | object: bunyan-style logger
no       | unwrapErrors     | v2     | boolean: report raw server errors instead of wrapping them with useful metadata (for compatibility; see RFD 33)
no       | maxIdleTime      | never  | This option was documented, but appears never to have been used.
no       | pingTimeout      | never  | This option was documented, but appears never to have been used.
no       | noCache          | ?      | If this option was ever used, it was removed before v2.
no       | reconnect        | ?      | If this option was ever used, it was removed before v2.
