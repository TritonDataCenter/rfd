---
authors: Kelly McLaughlin <kelly.mclaughlin@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues/103
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 142 Use SMF logging for Manta services

This RFD proposes a set of steps to replace the use of syslog for service logs
with SMF logging. This proposal is only targeted at the Joyent-authored manta
services. There are other third party services that may rely on syslog for their
logging, but changing those is outside the scope of this RFD.

The following list of services are the targets of this proposal:

* [buckets-api](https://github.com/joyent/buckets-api)
* [electric-boray](https://github.com/joyent/electric-boray)

Older manta components may be updated at some point, but they are not the focus
of this work at the current time.

The motivations for this change are:

1. To standardize logging across manta services. Currently, there are some
   services using SMF logging and other using syslog logging.
1. To avoid [cases](https://jira.joyent.us/browse/MANTA-1936?focusedCommentId=176160&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-176160) where log messages that are important to debugging issues may be dropped due to the use of syslog.
1. To avoid [issues](https://jira.joyent.us/browse/MANTA-1936?focusedCommentId=176160&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-176160) when updating the services to more recent versions of
   node. Many of the services that use syslog for logging do so via UDP. This
   leads to issues with more recent versions of node (v4 and up) where the
   service processes will frequently crash due to log messages larger than the
   maximum UDP datagram size. This could also be avoided by not using UDP, but
   in discussions with the manta team we decided this could be a useful forcing
   function to encourage us to get this work done.

## Proposal

There are several aspects to moving away from syslog logging that must be
covered by the proposal. The list of concerns that must be addressed is as
follows:

* Log rotation
* Initiation of log rotation and upload
* Inspection of current logs
* Amon alarms
* Documentation
* Service setup and configuration
* Removal of unnecessary build dependencies

The following sections explain the proposed method to address each one.

### Log rotation

The manner in which the log files are rotated is the most significant change in
this proposal. Rather than all of the service processes logging to a single log
file via syslog SMF logging will use one log file for each process.

This means the experience of _post hoc_ debugging or log searching will differ
slightly for manta components that have historically used syslog logging.

Moving from a single log file per service to many also requires a change to the
naming convention used for uploaded log files. The proposed naming convention
is: `$zone.$port.log` where `zone` is the short id of the zone and `port` is the
port number of the process that generated the log file.


### Initiation of log rotation and upload

Currently the process of log rotation and upload are controlled by two lines in
the crontab:

```
0 * * * * /usr/sbin/logadm
1,2,3,4,5 * * * * /opt/smartdc/common/sbin/backup.sh >> /var/log/mbackup.log 2>&1
```

This should work most of the time, but the reliance on timing could also
fail. To avoid any issues with timing causing logs to not be uploaded in a
timely manner it is proposed that we combine the steps necessary to rotate and
upload the log files into a single script that can be invoked in the `logadm`
configuration. The intetion is to add this script to the [manta-scripts](https://github.com/joyent/manta-scripts) repository.
The script can do proper logging and error handling and avoid reliance on timing
to properly complete the task.

### Inspection of current logs

A change in the way operators inspect a service's logs in real time is another
significant change in this proposal.

With syslog logging to a single file it is very convenient to inspect the log
output for all the processes of a service using the `tail`, `less`, or `cat`
commands; however, this is still possible with multiple log files.

Here are some example invocations suggested by Trent:

```
bunyan `svcs -L buckets-api`
tail -f `svcs -L buckets-api` | bunyan
```

### Amon alarms

Many manta services use amon probes to scan the log files for error
conditions. New probes must be added that scan the all the SMF log files related
to a service. Fortunately the `bunyan-log-scan` probe type has this capability.

A probe similar to the following example for muskie should be added for each
manta service:


```
-
    event: upset.manta.webapi.smf_log_error
    legacyName: muskie-logscan
    scope:
        service: webapi
    checks:
        -
            type: bunyan-log-scan
            config:
                smfServiceName: muskie
                fields:
                    level: ERROR
                threshold: 1
                period: 60
    ka:
        title: '"muskie" logged an error'
        description: The "muskie" service has logged an error.
        severity: major
        response: No automated response will be taken.
        impact: >-
            If the problem was transient, there may be no impact.  Otherwise,
            some end user requests may be experiencing an elevated error rate.
        action: >-
            Determine the scope of the problem based on the log message and
            resolve the underlying issue.
```

The new probe may coexist with the existing probe for the syslog file scan. Once
the change is fully deployed the syslog file scan probe could be removed.

### Documentation

The [Logs](https://joyent.github.io/manta/#logs) section of the Manta Operator's
Guide must be updated once the move to SMF logging is complete.

Additionally any service-specific documents that reference the logging needs to be
updated to reflect the change.

For example, the muskie service has a [design document](https://github.com/joyent/manta-muskie/blob/afd0a3aae1c910298cbf05ef67035216884da92e/docs/internal/design.md) inside the manta-muskie
git repository contains a reference to the location of the log file.

### Service setup and configuration

Any setup and configuration scripts with references to the syslog log files must
be updated.

Buckets-api, for example, has references to `/var/log/buckets-api.log` in the `setup.sh`
script in the `/boot` directory of the manta-buckets-api repository.

Additionally, the `syslog` subsection of the `bunyan` configuration section in
the service configuration file must be removed.

### Removal of unnecessary build dependencies

The `bunyan-syslog` build dependency will no longer be needed and should be
removed from the `package.json` file in the repository for each affected
service.
