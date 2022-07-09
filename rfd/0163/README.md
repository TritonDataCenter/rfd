---
authors: Mike Gerdts <mike.gerdts@joyent.com>, Pedro Palazón Candel <pedro@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+163%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 163 Cloud Firewall Logging

This RFD describes how Cloud Firewall may log accepted and rejected packets.  The intent is not to log every packet - rather just the beginning of a new TCP connection or series of related UDP or other packets.  This will be accomplished using the following components:

* **IPFilter** (`ipf`) will pass records for new connections, new connection-like traffic, and rejected traffic to the Cloud Firewall Log Daemon.
* **Cloud Firewall Log Daemon** (`cfwlogd`) will receive events from IPFilter, match these events with relevant per-zone metadata, and write logs to the file system.
* **Triton Log Archiver Service** will gather the logs written by Cloud Firewall Log Daemon and store them in Manta.

The start of each allowed or blocked TCP connection or connection-like series of UDP packets needs to log the following metadata:

* Time stamp with millisecond precision.
* Source IP and port
* Destination IP and port
* Protocol
* Cloud Firewall rule uuid
* VM uuid
* VM alias

Each customer that uses Cloud Firewall Logging must have Manta space available.

In the event of abnormally high logging activity or an extended outage the log archiver service, log entries may be dropped.

What gets logged will be determined by a `log` boolean attribute on each firewall rule. If and only if it is set to `true` will the rule trigger logging.  The default is for it to be unset, which is the equivalent of `false`.

## IPFilter

IPFilter will be enhanced in the following ways:

* It will gain the ability to optionally log connection and connection-like events that gain state via `set-tag(cfwlog)`.  These will be logged to a new special-purpose device.
* Each rule will be optionally tagged with a UUID, which is noted in the ipf rule with `set-tag(uuid=<uuid>)`.

### Configuration

The IPFilter configuration for each zone lives in `/zones/:zone/config/ipf[6].conf`.  The generation of these files is discussed in the *fwadm* section below.

### Rules

Traditionally, an `ipf.conf` file may look like:

```
# rule=da831f67-5016-42ec-817e-be7471445906, version=1521822733108.003634, wildcard=any
pass in quick proto icmp from any to any  keep frags

# rule=0366b13a-d9eb-47a6-9590-43708cc499cf, version=1521822734055.003636, wildcard=any

# fwadm fallbacks
block in all
pass out quick proto tcp from any to any flags S/SA keep state
pass out proto tcp from any to any
pass out proto udp from any to any keep state
pass out quick proto icmp from any to any keep state
pass out proto icmp from any to any
```

Supposing that the first rule in the configuration above is to be logged, it would become:

```
# rule=da831f67-5016-42ec-817e-be7471445906, version=1521822733108.003634, wildcard=any
pass in quick proto icmp from any to any keep frags set-tag(cfwlog, uuid=da831f67-5016-42ec-817e-be7471445906)
```

The UUID will be stored in the kernel along with the rest of the rule configuration.  It will be included with each event.  If an event is logged and no `uuid` tag was specified, the logged UUID will be the nil UUID, 00000000-0000-0000-0000-000000000000.

### Event device

A new device, `/dev/ipfev`, will be created with the intent that there will be a single process reading records from it.  The record for each BEGIN and BLOCK event is as described below.

```c
#define	CFWEV_BLOCK	1
#define	CFWEV_BEGIN	2
#define	CFWEV_END	3
#define	CFWDIR_IN	1
#define	CFWDIR_OUT	2

typedef	struct cfwev_s {
	uint16_t cfwev_type;    /* BEGIN, END, BLOCK */
	uint16_t cfwev_length;  /* in bytes, so capped to 65535 bytes */
	zoneid_t cfwev_zonedid; /* Pullable from ipf_stack_t. */

	uint32_t cfwev_ruleid;  /* Pullable from fr_info_t. */
	uint16_t cfwev_sport;   /* Source port (network order) */
	uint16_t cfwev_dport;   /* Dest. port (network order) */

	uint8_t cfwev_protocol; /* IPPROTO_* */
	/* "direction" informs if src/dst are local/remote or remote/local. */
	uint8_t cfwev_direction;
	uint8_t cfwev_reserved[6];      /* Ensures 64-bit alignment. */

	in6_addr_t cfwev_saddr; /* IPv4 addresses are V4MAPPED. */
	in6_addr_t cfwev_daddr;

	/*
	 * Because of 'struct timeval' being different between 32-bit and
	 * 64-bit ABIs, this interface is only usable by 64-bit binaries.
	 */
	struct timeval cfwev_tstamp;

	uuid_t cfwev_ruleuuid;  /* Pullable from fr_info_t. */
} cfwev_t;
```

Over time other event types may be added.  Each event will start with a 2-byte `type` field that stores the type and a 2-byte `size` field that stores the size of the entire structure in bytes. No event will be larger than 8 KiB, the minimum recommend size of the buffer used when reading from the device.

A successful `read()` from `/dev/ipfev` will return one or more event structures.  If there are no events available, the `read()` will block.  The number of events returned will be determined by the size of the passed buffer and the number of available events.  Each returned event may be of a different type and/or size.  Variable sized event types are allowed.

The process that reads from `/dev/ipfev` must check the `type` field.  If an unknown type is encountered, the `size` field should be used to find the start of the next event.

If the read rate on `/dev/ipfev` is too low events may be dropped.  A best effort will be made to track the number of dropped events.

## Cloud Firewall Log Daemon

The Cloud Firewall Log Daemon, `cfwlogd`, is a new component that reads events from `/dev/ipfev`.  Each event is processed, transforming it into a json-formatted log entry which is then written to a per-VM log file.

In the event of insufficient disk space or other conditions, log entries may be dropped.

### SMF Services

The Cloud Firewall Log Daemon will be delivered with the [firewall-logger-agent](https://github.com/TritonDataCenter/firewall-logger-agent) agent.  That is, it will not be part of the platform image.  It runs in the global zone on each compute node under the watchful eye of SMF in the `svc:/smartdc/agent/firewall-logger-agent:default` service.  Setup of this agent will be handled by the `svc:/smartdc/agent/firewall-logger-setup:default` service.  See the *FWAPI* section below.

### Record Format

Each log entry will be json object stored on a single line with no extra white space. For the sake of clarity in this document, pretty-printed records appear below.

#### Allowed Connection

The pretty-printed log entry for a typical allowed connection will look like the following.

```json
{
  "event": "begin",
  "protocol": "TCP",
  "direction": "in",
  "source_port": 1234,
  "destination_port": 22,
  "source_ip": "::ffff:192.168.128.12",
  "destination_ip": "::ffff:192.168.128.5",
  "timestamp": "2019-05-02T14:27:32.104586532Z",
  "rule": "43854efd-976b-485c-9e79-6f4e94eba8fd",
  "vm": "473b158d-023c-c4f7-9785-b027275580c9",
  "alias": "cfw-test-1"
}
```

#### Denied Connection

The pretty-printed log entry for a typical blocked connection will look like the following.

```json
{
  "event": "block",
  "protocol": "UDP",
  "direction": "in",
  "source_port": 2116,
  "destination_port": 60973,
  "source_ip": "::ffff:192.168.128.12",
  "destination_ip": "::ffff:192.168.128.5",
  "timestamp": "2019-04-11T18:30:53.000730227Z",
  "rule": "66cb0a3e-4843-46aa-9a35-330a20800462",
  "vm": "473b158d-023c-c4f7-9785-b027275580c9",
  "alias": "cfw-test-1"
}
```

### Log location

`cfwlogd` logs will be stored in a new dataset that will be mounted at `/var/log/firewall`.  Logs will be named

```
/var/log/firewall/:customer_uuid/:vm_uuid/current.log
```

### Log rotation

When `cfwlogd` receives a `SIGHUP`, it will close all log files and reopen on demand.  It is expected that this will be delivered on a regular (e.g. hourly) basis by `logadm`.

`logadm` will be configured to periodically rotate all `current.log` files found in `/var/log/firewall/*/*` to `:iso8601stamp.log.gz`.

### Log archival

The `triton-logarchiver` service, described in the *Log Archiver Service* section below, will be responsible for gathering cloud firewall logs from each compute node and storing them in Manta.

### Log retention

Triton will not automatically remove old log files that reside in the Manta reports directory.  It is up to the customer to remove expired logs.

Any file in `/var/log/firewall/*/*` that reaches seven days old (`find -mtime +7`) will be removed.

### Triton Cloud Firewall Log Agent

A new agent, `firewall-loggger-agent`, will be created.  It will consist of:

* `cfwlogd`
* `svc:/smartdc/agent/firewall-logger-setup:default` is a new service that will handle the setup required for `cfwlogd`.
* `svc:/smartdc/agent/firewall-logger:default` is a new service that will run `cfwlogd`.

Dependencies will be established in the services mentioned above to ensure the following order:

1. `svc:/smartdc/agent/firewall-logger-setup:default`
2. `svc:/smartdc/agent/firewall-logger:default`
3. Services that may boot zones
   - `svc:/system/zones:default`
   - `svc:/system/smartdc/vmadmd:default`

## Log Archiver Service

A new Triton service, `triton-logarchiver`, will be created.  This service will have a core VM `logarchiver0` that will run a hermes master and a hermes proxy. This service will be responsible for creating an SMF service, `svc:/smartdc/agent/logarchiver-agent:default`, that will run the hermes actor.  See [sdc-hermes](https://github.com/TritonDataCenter/sdc-hermes) for more information related to hermes.

Logarchiver-agent will be configured to collect all of the `/var/log/firewall/:customer_uuid/:vm_uuid/:iso8601stamp.log.gz` files and place them in Manta at `/:customer_login/reports/firewall-logs/:year/:month/:day/:vm_uuid/:iso8601stamp.log.gz`.  Once hermes has stored the file in Manta, hermes will remove it from the compute node.  Note that `/var/log/firewall` is a distinct directory from `/var/log/fw`, the location for the global zone's firewaller agent.

### Customer UUID to Manta account translation

The [`logsets.json`](https://github.com/TritonDataCenter/sdc-hermes/blob/master/etc/logsets.json.sample) file format will be extended to allow `%U` to represent a manta username.  The value of `%U` may be obtained by translating an account UUID using mahi.  The `customer_uuid` is the source UUID for this translation.

The following serves as an example of how this may be configured.

```json
  {
    "name": "firewall_logs",
    "search_dirs": [ "/var/log/firewall" ],
    "regex": "^/var/log/firewall/([0-9a-f]{8}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{12})/([0-9a-f]{8}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{12})/([0-9]+)-([0-9]+)-([0-9]+)T([0-9]+):([0-9]+):([0-9]+)\\.log.gz$",
    "manta_path": "/%U/reports/firewall-logs/#y/#m/#d/$2/#y-%m-%dT%H:%M:%S.log.gz",
    "customer_uuid": "$1",
    "date_string": {
      "y": "$3", "m": "$4", "d": "$5",
      "H": "$6", "M": "$7", "S": "$8"
    },
    "date_adjustment": "-1H",
    "debounce_time": 600,
    "retain_time": 0,
    "zones": [
      "global"
    ]
  }
```

In the event that the translation fails or `/%U/reports/firewall-logs/` is not writeable, an error will be returned to the hermes actor and the log file will not be removed from compute node.

## FWAPI

Currently rules look like:

```json
{
  "created_by": "fwapi",
  "description": "SDC zones: allow all UDP from admin net",
  "enabled": true,
  "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
  "rule": "FROM subnet 10.99.99.0/24 TO tag \"smartdc_role\" ALLOW udp PORT all",
  "uuid": "65b1ccca-589f-4711-85bb-f4b2490b7505",
  "version": "1547854685782.003869"
}
```

A new boolean `log` will be added to indicate whether matching connection begin and reject events should be logged.  Schema migration to allow the new `log (Boolean)` will be implemented.

### Firewaller Agent

As described in the *fwadm* section below and the *IPFilter* section above, the per-zone `ipf.conf` and `ipf6.conf` files will change in a way that is not backward compatible.  A new service, `svc:/smartdc/agent/firewaller-config-migration:default`, will be responsible for ensuring that each zone's `ipf` configuration files are a version that is compatible with the running system.  This new service will be depended upon by `svc:/system/smartdc/vmadmd:default` and `svc:/system/zones:default`.  These dependencies will be added to the `svc:/smartdc/agent/firewaller-config-migration:default` service using `dependent` elements similar to the following:

```xml
  <dependent name="smartdc_vmadmd" grouping="optional_all" restart_on="none">
    <service_fmri value='svc:/system/smartdc/vmadmd:default' />
  </dependent>
  <dependent name="system_zones" grouping="optional_all" restart_on="none">
    <service_fmri value='svc:/system/zones:default' />
  </dependent>
```

The existence of `/dev/ipfev` indicates that the new rule format should be used. Otherwise the old format should be used.  Care should be taken to avoid needlessly rewriting all of the configuration files, as over time no compute node will require the old configuration syntax version.  The migration script will look for `# smartos_ipf_version <version>` in `ipf*.conf` files to determine which configuration syntax version is used.  An `ipf*.conf` file that uses the `cfwlog` or `uuid` tags introduced in this project will use configuration version 2 and as such will have the following comment.

```
# smartos_ipf_version 2
```

Any `ipf*.conf` file that does not specify `smartos_ipf_version` is considered to be a version 1 file.  Version 1 does not use `cfwlog` or `uuid` tags.

The configuration syntax version supported by a compute node is dependent on the PI that is currently running.  The firewaller agent is not part of the PI and as such the same version of the firewaller agent may be deployed across many PI versions.  Future platform images may support different features that require yet another version bump.  The latest configuration syntax version supported by the platform is stored in `/etc/ipf/smartos_version`.  If this file does not exist, version 1 is assumed.  If an `ipf*.conf` file's configuration syntax version does not match the platform's latest supported configuration syntax version, the `ipf*.conf` file is rewritten using the platform's configuration syntax version.

The format of `/etc/ipf/smartos_version` is a single line containing a single integer.  For example, this project delivers a file containing only the following:

```
2
```

## fwadm

Requires updates to accommodate this new `log (Boolean)` value, affecting at least to rule creation/update/deletion and, additionally, to the output retrieved by get/list rules. (Default to false when nothing given or known).

For example, the following output needs to be modified in order to include the "LOG" column:

```
[root@headnode (coal) ~]# fwadm list
UUID                                 ENABLED RULE
2532a46e-73bf-418b-b71e-7001027d9369 true    FROM any TO all vms ALLOW icmp TYPE all
59ba1d92-48c8-425e-b740-70339a84b8fd true    FROM any TO all vms ALLOW icmp6 TYPE all
6164f3cc-d1ad-4ac5-bcb2-e4b3ae2edd33 true    FROM subnet 10.99.99.0/24 TO tag "smartdc_role" ALLOW udp PORT all
e1c9d7dc-2f59-4907-8c17-7cf5bf1136b9 true    FROM subnet 10.99.99.0/24 TO tag "smartdc_role" ALLOW tcp PORT all
```
Not implemented yet.

## CloudAPI

Given the `log (Boolean)` member in fwapi is not strictly required for the firewall rule to work, we should possibly give it exactly the same treatment as the existing `enabled (Boolean)`. That is, it is an additional parameter to the rule itself, and it's represented separately by CloudAPI.

All the fwrules end-points need the new boolean value to be added (and tests need to be updated accordingly). By default, logging should be false and it must be documented in CloudAPI.

Current fwrule format is:

```
{
  "id": "38de17c4-39e8-48c7-a168-0f58083de860",
  "rule": "FROM vm 3d51f2d5-46f2-4da5-bb04-3238f2f64768 TO subnet 10.99.99.0/24 BLOCK tcp PORT 25",
  "enabled": true
}
```

With the changes described, it should become:

```
{
  "id": "38de17c4-39e8-48c7-a168-0f58083de860",
  "rule": "FROM vm 3d51f2d5-46f2-4da5-bb04-3238f2f64768 TO subnet 10.99.99.0/24 BLOCK tcp PORT 25",
  "enabled": true,
  "log": false
}
```

## node-triton

node-triton will be updated to handle reading and modifying `fwrule.log`.  The output of `triton fwrule list` will be updated to include a `LOG` column, as shown below.

```
SHORTID   ENABLED  GLOBAL  LOG   RULE
285d7f76  false    -       true  FROM any TO vm efe45825-4c0d-48f5-d62c-c5a50433fad1 BLOCK tcp PORT 666        4ef987de  true     -       true  FROM subnet 10.99.99.0/TO vm 3a2b9998-965d-c4ab-d952-eb2802f8d6b9 ALLOW tcp PORT all
44eae6bb  true     -       true  FROM subnet 10.99.99.0/24 TO vm efe45825-4c0d-48f5-d62c-c5a50433fad1 ALLOW tcp PORT all
```

The output of `triton frwrule get` is updated to include the `log` member.

```
$ triton fwrule get 44eae6bb
{
    "id": "44eae6bb-337f-45ba-8ff9-dddcd46e5918",
    "rule": "FROM subnet 10.99.99.0/24 TO vm efe45825-4c0d-48f5-d62c-c5a50433fad1 ALLOW tcp PORT all",
    "enabled": true,
    "log": true
}
```

`triton fwrule create <-l|--log>` may be used for creating a rule with logging enabled.  `triton fwrule update <rule> log=<true|false>` may be used to enable or disable logging on a rule.


## AdminUI

AdminUI will be updated to include a checkbox on each firewall rule to indicate whether logging is enabled.  This will be present on the edit and create screens.  If the cloud firewall logging feature is not supported by `fwapi`, the checkbox is disabled.

## Portal

Changes in portal will mimic those done in AdminUI.  This is not required for MVP.

## sdcadm

### Setup Firewall Loger Agent using sdcadm:

#### Command usage options:

```
sdcadm post-setup help firewall-logger-agent
Create "firewall-logger-agent" service and the required agent instances.

Usage:
     sdcadm post-setup firewall-logger-agent

Options:
    -h, --help                          Show this help.
    -y, --yes                           Answer yes to all confirmations.
    -n, --dry-run                       Do a dry-run.

  Server selection (by default all setup servers are updated):
    -s NAMES, --servers=NAMES           Comma-separated list of servers (either
                                        hostnames or uuids) on which to update
                                        cn_tools.
    -S NAMES, --exclude-servers=NAMES   Comma-separated list of servers (either
                                        hostnames or uuids) to exclude from
                                        cn_tools update.
    -j CONCURRENCY, --concurrency=CONCURRENCY
                                        Number of concurrent servers being
                                        updated simultaneously. Default: 10.
  Image selection (by default latest image on default channel):
    -i ARG, --image=ARG                 Specifies which image to use for the
                                        instances. Use "latest" (the default)
                                        for the latest available on
                                        updates.joyent.com, "current" for the
                                        latest image already in the datacenter
                                        (if any), or an image UUID or version.
    -C ARG, --channel=ARG               The updates.joyent.com channel from
                                        which to fetch the image. See `sdcadm
                                        channel get` for the default channel.

The "firewall-logger-agent" service generates specific Triton log files
for the configured firewall rules.
```

#### Create the service and setup the agent:

```
sdcadm post-setup firewall-logger-agent

This will make the following changes:
    create "firewall-logger-agent" service in SAPI
    download image e9c42432-016a-452f-a0c8-639033a4c510 (firewall-logger-agent@1.0.0)
        from updates server using channel "dev"
    create "firewall-logger-agent" service instance on "1" servers

Would you like to continue? [y/N] y

Importing image e9c42432-016a-452f-a0c8-639033a4c510 (firewall-logger-agent@1.0.0)
Downloading image e9c42432-016a-452f-a0c8-639033a4c510
    (firewall-logger-agent@1.0.0)
Imported image e9c42432-016a-452f-a0c8-639033a4c510
    (firewall-logger-agent@1.0.0)
Creating "firewall-logger-agent" service
...firewall-logger-agent [====================================>] 100%        1
Successfully installed "firewall-logger-agent" on all servers.
Completed successfully (elapsed 18s).
```

### Setup logarchiver using sdcadm: 

#### Command usage options:

```
sdcadm post-setup logarchiver

Create the "logarchiver" service and a first instance.

Usage:
     sdcadm post-setup logarchiver

Options:
    -h, --help                  Show this help.
    -y, --yes                   Answer yes to all confirmations.
    -n, --dry-run               Do a dry-run.
    -s SERVER, --server=SERVER  Either hostname or uuid of the server on which
                                to create the instance. (By default the headnode
                                will be used.).

  Image selection (by default latest image on default channel):
    -i ARG, --image=ARG         Specifies which image to use for the first
                                instance. Use "latest" (the default) for the
                                latest available on updates.joyent.com,
                                "current" for the latest image already in the
                                datacenter (if any), or an image UUID or
                                version.
    -C ARG, --channel=ARG       The updates.joyent.com channel from which to
                                fetch the image. See `sdcadm channel get` for
                                the default channel.

The "logarchiver" service uploads specific Triton log files to a configured Manta object store.
```

#### Create the service and setup the agent:

```
[root@headnode (coal) ~]# sdcadm post-setup logarchiver

This will make the following changes:
    create "logarchiver" service in SAPI
    download image a1b75ba0-336b-46f0-a9fb-3260947b2114 (logarchiver@master-20190507T165334Z-gb5754db)
        from updates server using channel "dev"
    create "logarchiver" service instance on server "564d2b36-7e25-7d79-e3c2-7ceb79d8abd6"

Would you like to continue? [y/N] y

Importing image a1b75ba0-336b-46f0-a9fb-3260947b2114 (logarchiver@master-20190507T165334Z-gb5754db)
Downloading image a1b75ba0-336b-46f0-a9fb-3260947b2114
    (logarchiver@master-20190507T165334Z-gb5754db)
Imported image a1b75ba0-336b-46f0-a9fb-3260947b2114
    (logarchiver@master-20190507T165334Z-gb5754db)
Creating "logarchiver" service
Creating "logarchiver" instance on server 564d2b36-7e25-7d79-e3c2-7ceb79d8abd6
Created VM eb394c52-916e-4b95-aa53-3a7b6452824d (logarchiver0)
Completed successfully (elapsed 109s).
```
