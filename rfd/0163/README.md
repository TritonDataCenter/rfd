---
authors: Mike Gerdts <mike.gerdts@joyent.com>, Pedro Palazón Candel <pedro@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+163%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Joyent, Inc.
-->

# RFD 163 Cloud Firewall Logging

**This is very rough.  Please fix.**

This RFD describes how Cloud Firewall may log accepted and rejected packets.  The intent is not to log every packet - rather just the beginning of a new TCP connection or series of related UDP packets.  This will be accomplished using the following components:

* **IPFilter** (`ipf`) will make an initial pass at identifying which packets may be of interest and pass metadata to Cloud Firewall Log Daemon.
* **Cloud Firewall Log Daemon (`cfwlogd`)** will receive packet metadata from IPFilter, discarding uninteresting metadata.  Interesting metadata will be passed to AuditAPI.
* **hermes** will gather log files from compute nodes and store them in the appropriate manta accounts.

The start of each allowed or blocked TCP connection or connection-like series of UDP packets needs to log the following metadata:

* Time stamp with millisecond precision.
* Source IP and port
* Destination IP and port
* Protocol
* Cloud Firewall rule uuid
* VM uuid
* VM alias

Each customer that uses Cloud Firewall Logging must have Manta space available.

In the event of abnormally high logging activity or an extended outage to AuditAPI, log entries may be dropped.

What gets logged will be determined by a `log` boolean attribute on each firewall rule. If and only if it is set to `true` will the rule trigger logging.  The default is for it to be unset, which is the equivalent of `false`.

## IPFilter

### Configuration

This is done by `fwadm` and by the post-ready brand hook.

- What is responsible for pushing rules (initial, updates) from Triton?
  - Does this interface need to change to be able to pass a logging switch?

### Rules

- `call` may be used by knowledgable hackers.  Is that us?  Should we use this rather than log?
- Do we alter the rules to only log when logging is enabled by cloud firewall?  Or do we always log and let `cfwlogd` sort it out?
- Can we use `tag rule-uuid` with each rule so that the log entry will have the cloud firewall rule uuid?

## Cloud Firewall Log Daemon

This is a new component, likely written in rust.  It reads logged packet metadata from the kernel via a device file.  It runs in the global zone on each compute node under the watchful eye of SMF.

- Likely does filtering beyond what is done by ipf
  - Keep some state of recent UDP traffic, logging only first recent
- Buffer some data when AuditAPI endpoint is not available

Dropping of log entries is acceptable if the log rate is too great to stream to AuditAPI or if AuditAPI is unavailable for a long enough time that local buffer space is exhausted.  `cfwlogd` should make a best effort to keep track of the number of dropped entries and log that as conditions normalize.

Should we be logging rule add/remove/change?

### Record Format

Each log entry will be json object stored on a single line with no extra white space. For the sake of clarity in this document, pretty-printed records appear below.

#### Allowed Connection

A typical accepted connection will look like the following.

```json
{
  "event": "allow",
  "time": "2019-02-25T21:02:18.658Z",
  "source_ip": "10.1.0.23",
  "source_port": 1027,
  "destination_ip": "10.1.0.4",
  "destination_port": 22,
  "protocol": "tcp",
  "rule": "ae8a7fe6-f8c5-4670-bef8-196a8071cb84",
  "vm": "8b43c12b-6643-cee7-ad7b-b87a53ae257d",
  "alias": "some-friendly-name-here"
}
```

#### Denied Connection

A typical denied connection will look like the following.

```json
{
  "event": "reject",
  "time": "2019-02-25T21:02:18.658Z",
  "source_ip": "10.1.0.23",
  "source_port": 1028,
  "destination_ip": "10.1.0.4",
  "destination_port": 23,
  "protocol": "tcp",
  "rule": "ae8a7fe6-f8c5-4670-bef8-196a8071cb84",
  "vm": "8b43c12b-6643-cee7-ad7b-b87a53ae257d",
  "alias": "some-friendly-name-here"
}
```

### Log location

`cfwlogd` logs will be stored in a new dataset that will be mounted at `/var/log/firewall`.  This dataset should have compression enabled.  Logs will be named

```
/var/log/firewall/:customer_uuid/:vm_uuid/current.log.gz
```

### Log rotation

When `cfwlogd` receives a `SIGHUP` (or some other mechanism TBD), it will close all log files and reopen on demand.  It is expected that this will be delivered on a regular (e.g. hourly) basis by `logadm`.

`logadm` will be configured to periodically rotate all `current.log` files found in `/var/log/firewall/*/*` to `:iso8601stamp.log.gz`.

**XXX should the stamp be the time of the first record or the last?**

### Log archival

The `logarchiver` service, described in the *Log Archiver Service* section below, will be responsible for gathering cloud firewall logs from each compute node and storing them in Manta.

### Log retention

Triton will not automatically remove old log files that reside in the Manta reports directory.  It is up to the customer to remove expired logs.

Any file in `/var/log/firewall/*/*` that reaches seven days old (`find -mtime +7`) will be removed.

### Log Compression

As alluded to above, the log files will be written as gzip files.  On-the-fly compression is used so that a zone that is experiencing a very heavy connection rate will be logging at a rate that does not quickly fill the available log space.  Experimentation shows that a simulated DDoS attack generates a stream that compresses with `gzip` to 0.5% of its original size.  This level of compression can also greatly reduce the load on the archival process.

`cfwlogd` MUST NOT blindly open logs in append mode, as a compressed log file that was not closed properly is likely to be in a state that would cause any appended data to be unreadable.  Instead, when `cfwlogd` finds an existing log file, it will rename it according to the same pattern that is used during log rotation.  The log file open (creation) will then be retried.

## Log Archiver Service

A new Triton service, `logarchiver`, will be created.  This service will have a core VM `logarchiver0` that will run a hermes master and a hermes proxy. This service will be responsible for creating an SMF service, `svc:/smartdc/agent/logarchiver-agent:default`, that will run the hermes actor.  See [sdc-hermes](https://github.com/joyent/sdc-hermes) for more information related to hermes.

Logarchiver-agent will be configured to collect all of the `/var/log/firewall/:customer_uuid/:vm_uuid/:iso8601stamp.log.gz` files and place them in Manta at `/:customer_login/reports/firewall-logs/:vm_uuid/:year/:month/:day/:iso8601stamp.log.gz`.  Once hermes has stored the file in Manta, hermes will remove it from the compute node.  Note that `/var/log/firewall` is a distinct directory from `/var/log/fw`, the location for the global zone's firewaller agent.

### Customer UUID to Manta account translation

The [`logsets.json`](https://github.com/joyent/sdc-hermes/blob/master/etc/logsets.json.sample) file format will be extended to allow `%U` to represent a manta username.  The value of `%U` may be obtained by translating an account UUID using mahi.  The `customer_uuid` is the source UUID for this translation.

The following serves as an example of how this may be configured.

```json
  {
    "name": "firewall_logs",
    "search_dirs": [ "/var/log/firewall" ],
    "regex": "^/var/log/firewall/([0-9a-f]{8}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{12})/([0-9a-f]{8}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{4}\\-[0-9a-f]{12})/([0-9]+)-([0-9]+)-([0-9]+)T([0-9]+):([0-9]+):([0-9]+)\\.log.gz$",
    "manta_path": "/%U/reports/firewall-logs/$2/#y/#m/#d/#y-%m-%dT%H:%M:%S.log.gz",
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

### Phased Delivery

To meet initial needs while working toward a more scalable hermes implementation, the logarchiver work will be delivered in phases.

XXX Phases 1 & 2 can probably be collapsed, which maybe makes it so that we can just do an upgrade of hermes in the sdc zone and forgo splitting it off into logarchiver0.

The logarchiver service remains experimental until phase three begins.

### Log Archiver Phase 1: Basic functionality.

The initial implementation of logarchiver will be simple - comparable to the hermes instance found in the sdc zone.  Each CN will have multiple hermes actors: the traditional sdc hermes instance and the new logarchiver instance.

### Log Archiver Phase 2: Scalability

The second phase of logarchiver will focus on scalability, with the goal of being able to scale up the capacity to be able to handle all cloud firewall logs as well as those traditionally handled by hermes in the sdc zone.

The proxy is believed to be the least scalable part of the architecture.  That will be addressed using one or more of the following techniques:

* Use multiple hermes proxy instances in logarchiver0 that are fronted by HAProxy to balance the load between them.
* Create multiple logarchiver service zones, each containing a hermes proxy.  [Binder](https://github.com/joyent/binder) would then be used to distribute the load across the horizontally scaled proxy zones.
* Create multiple logarchiver service zones, each containing a hermes master and proxy.  This approach would require work to support multiple masters.
* Replace the current hermes proxy with [nginx](https://nginx.org/en/).  The actor is already provided with appropriate credentials to perform the upload - the proxy just needs to forward the TCP stream.

This phase may also deliver load smoothing to ensure that there is not a "top of the hour" spike.

### Log Archiver Phase 3: Retire hermes from sdc zone

During this phase, hermes is removed from the sdc zone.  The work previously done by this hermes instance is transitioned to logarchiver.

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

Presumably we need a boolean `log`. Need schema migration to allow the new member `log (Boolean)` to be added. It would be desirable to follow up with somebody familiar with FWAPI and check if we need to add anything to the UFDS flavor of fwrules. Other than that, this would mean a moray version bump when adding the new member to the object. Apparently, there's not need for such field to be part of an index.

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

## CloudAPI

- Needs to be able to specify logging.
  - Is this done per VM or per rule? Doing per rule will definitely simplify things, otherwise we'll need to raise multiple fwrules updates from VMAPI or from CloudAPI itself.

Given the `log (Boolean)` member in fwapi is not strictly required for the firewall rule to work, we should possibly give it exactly the same treatment as the existing `enabled (Boolean)`, it's to say, it's an additional parameter to the rule itself, and it's represented separately by CloudAPI.

Additionally, we have `enable|disable` end-points for fwrules in CloudAPI. May also consider having `addLogging|removeLoogin` end-points but initially just adding the required code changes to the existing update end-point should be more than enough.

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

Needs to be modified in order to be able to handle new member from CloudAPI both, reading and adding/removing it. Rule get and list output need to be updated. Tests need to be updated accordingly.

## node-smartdc

Deprecated unless User portal needs it and cannot transition to node-triton. No need to take any action.

## AdminUI

- Add a checkbox for the log (Boolean) new member (Can be bellow to the one existing for enabled in both the edit and create screens).
  - **We need a way to check availability of the logging feature** maybe checking `fwapi` version?
  - When there's no availability of such feature, the application should either disable the aforementioned checkbox or
  even do not display it at all.

## Portal
- Once we have the CloudAPI/node-triton changes in place, can be altered to include a "log" option for each rule (Can be just a checkbox).
- It may be nice to be able to batch update. On this page: https://my.joyent.com/main/#!/network/firewall#rule-form, select any number of rules then under the Actions drop down, select "Enable Log" or "Disable Log". The fact that I say "may be nice" means that it is not required for MVP.

## sdcadm

Despite of the final components we need to deploy, i.e. add or not AuditAPI, or just deploy `cwlogd` to a given set of CNs, we need to add a `sdcadm post-setup` subcommand which will be responsible to create the required SAPI services/instances.

(`sdcadm post-setup` itself will appreciate some general purpose refactoring, given we have a lot of similar subcommands sharing intention and more code than differences but using c&p instead of something easier to maintain. That's obviously part of a separated problem).
