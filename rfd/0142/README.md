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
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 142 Use SMF logging for Manta services

This RFD proposes a set of steps to replace the use of syslog for service logs
with SMF logging. This proposal is only targeted at the Joyent-authored manta
services. There are other third party services that may rely on syslog for their
logging, but changing those is outside the scope of this RFD.

The following list of services are the targets of this proposal:

* electric-moray
* mackerel
* mola
* moray
* muskie

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

The ideal situation would be to continue to have a single historical log file uploaded
to make the experience of _post hoc_ debugging or log searching the same as it
is today.

To achieve this the log rotation process will now encompass the following steps:

1. The SMF log file for each manta service process is rotated using a version
   number suffix rather than a timestamp and the files remain in the
   `/var/svc/log` directory rather than being immediately moved to the
   `/var/log/manta/upload` directory.
1. A shell script is run that uses bunyan's ability to sort and merge files by
   timestamp and copy the resulting merged file to `/var/log/manta/upload`. This
   script merges all files having the same version suffix and checks for the
   last 48 hours worth of logs that may need to be merged and uploaded.
1. The sorted and merged log files in `/var/log/manta/upload` directory are
   uploaded to manta just as they are today.

Here is the logadm.conf file that has been used for testing these changes with muskie:

```
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
# Copyright (c) 2001, 2010, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2012, Joyent, Inc. All rights reserved.
#
# logadm.conf
#
# Default settings for system log file management.
# The -w option to logadm(1M) is the preferred way to write to this file,
# but if you do edit it by hand, use "logadm -V" to check it for errors.
#
# The format of lines in this file is:
#       <logname> <options>
# For each logname listed here, the default options to logadm
# are given.  Options given on the logadm command line override
# the defaults contained in this file.
#
# logadm typically runs early every morning via an entry in
# root's crontab (see crontab(1)).
#
/var/log/syslog -C 8 -a 'kill -HUP `cat /var/run/*syslog*.pid`'
/var/log/authlog -C 5 -a 'kill -HUP `cat /var/run/*syslog*.pid`' -s 100m
/var/log/maillog -C 5 -a 'kill -HUP `cat /var/run/*syslog*.pid`' -s 100m
/var/cron/log -c -s 512k -t /var/cron/olog
/var/lp/logs/lpsched -C 2 -N -t '$file.$N'
/var/fm/fmd/errlog -M '/usr/sbin/fmadm -q rotate errlog && mv /var/fm/fmd/errlog.0- $nfile' -N -s 2m
/var/fm/fmd/fltlog -A 6m -M '/usr/sbin/fmadm -q rotate fltlog && mv /var/fm/fmd/fltlog.0- $nfile' -N -s 10m
/var/log/*.log -C 2 -c -s 5m
/var/log/*.debug -C 2 -c -s 5m
#
p# The entry below is used by turnacct(1M)
#
/var/adm/pacct -C 0 -N -a '/usr/lib/acct/accton pacct' -g adm -m 664 -o adm -p never
#
# The entry below manages the Dynamic Resource Pools daemon (poold(1M)) logfile.
#
/var/log/pool/poold -N -a 'pkill -HUP poold; true' -s 512k
/var/fm/fmd/infolog -A 2y -M '/usr/sbin/fmadm -q rotate infolog && mv /var/fm/fmd/infolog.0- $nfile' -N -S 50m -s 10m
/var/fm/fmd/infolog_hival -A 2y -M '/usr/sbin/fmadm -q rotate infolog_hival && mv /var/fm/fmd/infolog_hival.0- $nfile' -N -S 50m -s 10m

/var/adm/messages -C 4 -a 'kill -HUP `cat /var/run/rsyslogd.pid`'
config-agent -C 48 -c -p 1h -t '/var/log/manta/upload/config-agent_$nodename_%FT%H:00:00.log' /var/svc/log/*config-agent*.log
registrar -C 48 -c -p 1h -t '/var/log/manta/upload/registrar_$nodename_%FT%H:00:00.log' /var/svc/log/*registrar*.log
muskie -C 48 -c -p 1h /var/svc/log/*muskie:muskie*.log
mbackup -C 3 -c -s 1m /var/log/mbackup.log
smf_logs -C 3 -c -s 1m /var/svc/log/*.log

```

The change is with the entry for `muskie`. Here is the logadm configuration
entry for the current entry used for syslog log rotation:

```
muskie -C 48 -c -p 1h -t '/var/log/manta/upload/muskie_$nodename_%FT%H:00:00.log' /var/log/muskie.log
```

Here's is the test script used to sort and merge the SMF service log files:

```
#!/bin/bash

for i in {0..47}; do
    if [ $(ls -1 /var/svc/log/*muskie:muskie*.log.$i 2>/dev/null | wc -l) -gt 0 ]; then
        bunyan /var/svc/log/*muskie:muskie*.log.$i -o bunyan > /var/log/manta/upload/muskie_$(uname -n)_$(date --date="$i hours ago" '+%Y-%m-%dT%H:00:00').log;
        rm /var/svc/log/*muskie:muskie*.log.$i;
    fi
done
```

Currently the script is specialized to muskie, but it could be parameterized to
work with any service.

### Initiation of log rotation and upload

Currently the process of log rotation and upload are controlled by two line in
the crontab:

```
0 * * * * /usr/sbin/logadm
1,2,3,4,5 * * * * /opt/smartdc/common/sbin/backup.sh >> /var/log/mbackup.log 2>&1
```

This should work most of the time, but the reliance on timing could also
fail. To avoid any issues with timing causing logs to not be uploaded in a
timely manner and given that this proposal introduces the extra step of merging
log files prior to upload it is proposed to change the crontab entries so that
the launch of one phase of the process only occurs once the previous phase is
complete.

For example in the case of muskie the two crontab entries presented above would
be replaced by a single entry such as this:

```
0 * * * * /usr/sbin/logadm && /opt/local/sbin/merge-muskie-logs.sh && /opt/smartdc/common/sbin/backup.sh >> /var/log/mbackup.log 2>&1 && echo "Log rotation and backup completed at $(date)" >> /var/tmp/logtimes.out
```

The logging of the completion time to `/var/tmp/logtimes.out` is not necessary,
but has been useful for examining how long the rotation/merge/upload process
takes during testing.

### Inspection of current logs

A change in the way operators inspect a service's logs in real time is another
significant change in this proposal.

With syslog logging to a single file it is very convenient to inspect the log
output for all the processes of a service using the `tail`, `less`, or `cat`
commands. This is still possible with multiple log files, but not nearly as
convenient or easy to remember. A solution is to help with this is to add helper
scripts that are easy to remember and give the same results. Credit to Bryan
Horstmann-Allen for this idea. He implemented this when we worked together at a
previous job and it was very useful.

A `logtail` script could be used to provide a similar experience to the `tail`
command:

```
#!/bin/bash

if [ $# -eq 0 ]
  then
    echo "Usage: logtail SERVICE";
    exit 1;
fi

tail -q -F `svcs -L "$1" | xargs echo` | bunyan
```

In a similar manner a `logcat` script could be used to do a sort and merge of
the files:

```
#!/bin/bash

if [ $# -eq 0 ]
  then
    echo "Usage: logcat SERVICE";
    exit 1;
fi

bunyan /var/svc/log/*$1:$1*.log -o bunyan
```

Both scripts would reside in the `/opt/local/sbin` directory so that they are on
the operator's PATH to maximize the ease of use.

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

Muskie, for example, has references to `/var/log/muskie.log` in the `setup.sh`
script in the `/boot` directory of the manta-muskie repository.

Additionally, the `syslog` subsection of the `bunyan` configuration section in
the service configuration file must be removed.

### Removal of unnecessary build dependencies

The `bunyan-syslog` build dependency will no longer be needed and should be
removed from the `package.json` file in the repository for each affected
service.
