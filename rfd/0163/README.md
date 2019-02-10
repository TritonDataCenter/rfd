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
* **Cloud Firewall Log Daemon (`cfwld`?)** will receive packet metadata from IPFilter, discarding uninteresting metadata.  Interesting metadata will be passed to AuditAPI.
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
- Do we alter the rules to only log when logging is enabled by cloud firewall?  Or do we always log and let `cfwld` sort it out?
- Can we use `tag rule-uuid` with each rule so that the log entry will have the cloud firewall rule uuid?

## Cloud Firewall Log Daemon

This is a new component, likely written in rust.  It receives logged packet metadata from the kernel via a door or socket.  It runs in the global zone on each compute node under the watchful eye of SMF.

- Likely does filtering beyond what is done by ipf
  - Keep some state of recent UDP traffic, logging only first recent
- Buffer some data when AuditAPI endpoint is not available
- Is this a general purpose audit forwarder?  Should it be designed to forward Solaris audit logs, or is that something different?
- Presumably this daemon makes REST calls to AuditAPI.
  - compressed streams ideal

Dropping of log entries is acceptable if the log rate is too great to stream to AuditAPI or if AuditAPI is unavailable for a long enough time that local buffer space is exhausted.  `cfwld` should make a best effort to keep track of the number of dropped entries and log that as conditions normalize.

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

## CloudAPI

- Needs to be able to specify logging.
  - Is this done per VM or per rule?

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

Presumably we need a boolean `log`. 

## fwadm

Likely no changes.
