---
authors: Mike Gerdts <mike.gerdts@joyent.com>
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
* **AuditAPI** is inclusive of an API and the associated service running on a head node or some other compute node.  The service is responsible for ingesting audit entries (e.g. containing connection metadata) and persisting it to a designated store, such as Manta.

The start of each allowed or blocked TCP connection or connection-like series of UDP packets needs to log the following metadata:

* Time stamp with millisecond precision.
* Source IP and port
* Destination IP and port
* Protocol
* Cloud Firewall rule uuid
* VM uuid
* Customer uuid (XXX questionable - can be derived from VM uuid)

Each customer that uses Cloud Firewall Logging must have Manta space available.

In the event of abnormally high logging activity or an extended outage to AuditAPI, log entries may be dropped.

Where is logging specified?
- The firewall rule?  <<<< Seems the most straight forward
- The VM?
- The NIC?
- The network?
- The customer?

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

This is a new component, likely written in rust.  It receives logged packet metadata from the kernel via a door or socket.  It runs in the global zone on each compute node under the watchful eye of SMF.

- Likely does filtering beyond what is done by ipf
  - Keep some state of recent UDP traffic, logging only first recent
- Buffer some data when AuditAPI endpoint is not available
- Is this a general purpose audit forwarder?  Should it be designed to forward Solaris audit logs, or is that something different?
- Presumably this daemon makes REST calls to AuditAPI.
  - compressed streams ideal

Dropping of log entries is acceptable if the log rate is too great to stream to AuditAPI or if AuditAPI is unavailable for a long enough time that local buffer space is exhausted.  `cfwlogd` should make a best effort to keep track of the number of dropped entries and log that as conditions normalize.

Should we be logging rule add/remove/change?

## AuditAPI

- One or more zones on the admin network
- If multiple
  - How does the log daemon know which one to log to?
  - How are logs coalesced so that instance A does not clobber instance B's logs?
- Needs to be able to receive streamed audit logs
- Need definition of audit entries and audit log format
- How is it configured?
  - Manta path for each customer
  - File interval (time, size?)
  - Retention period

### Record Format

The first consumer of AuditAPI will be Cloud Firewall Logging.  There may be future consumers.  For instance, SmartOS auditing may be extended with a module similar to `audit_remote(5)` to forward operating system audit logs to AuditAPI.  The audit record format needs to be designed to meet current needs while being easily extended to meet future needs.

- bunyan has some nice ideas, but it is designed for other uses.  Some of its [core fields](https://github.com/trentm/node-bunyan#core-fields) may not map well to AuditAPI's needs.

### Persistence

- Can [chunked encoding](https://github.com/joyent/manta/blob/master/docs/user-guide/storage-reference.md#content-length) be used to dribble the content into manta?
  - If this is used, what precautions need to be taken against an AuditAPI zone outage?  That is, after reboot, will the current file need to start from the beginning?
  - If it is not possible to resume an interrupted upload, what causes the partial upload to manta to be cleaned up?

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

Requires updates to acomodate this new `log (Boolean)` value, affecting at least to rule creation/update/deletion and, additionally, to the output retrieved by get/list rules. (Default to false when nothing given or known).

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

Additionaly, we have `enable|disable` end-points for fwrules in CloudAPI. May also consider having `addLogging|removeLoogin` end-points but initally just adding the required code changes to the existing update end-point should be more than enough.

All the fwrules end-points need the new boolean value to be added (and tests need to be updated accordingly). By default, logging should be false and it must be documented in CloudAPI.

Current fwrule format is:

```
{
  "id": "38de17c4-39e8-48c7-a168-0f58083de860",
  "rule": "FROM vm 3d51f2d5-46f2-4da5-bb04-3238f2f64768 TO subnet 10.99.99.0/24 BLOCK tcp PORT 25",
  "enabled": true
}
```

with the changes described, it should become:

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


