#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2017 Joyent, Inc.
#

#
# Purge system log archive from Manta.
#
# Usage:
#       purge-system-logs -h                              # help output
#       purge-system-logs /admin/stor/logs                # dry-run by default
#       purge-system-logs -f /admin/stor/logs             # '-f' to actually del
#       purge-system-logs -f /admin/stor/logs $datacenter # specific Triton DC
#       purge-system-logs -f /admin/stor/sdc/usage $datacenter # usage logs
#
# Log files build up in Manta. They need to eventually be purged so they don't
# take up ever increasing space. This script knows how to remove old
# /YYYY/MM/DD/HH logs from a given Manta dir. This script encodes retention
# policy for the different services.
#
# Here "/YYYY/MM/DD/HH" means the typical log dir layout created by hermes.
#
# For Triton, the first-level subdir is the data center:
#                                   # Example:
#   $basedir/                       #   /admin/stor/logs/
#     $datacenter/                  #     us-sw-1/
#       $service/                   #       cloudapi-8081/
#         $year/                    #         2017/
#           $month/                 #           04/
#             $day/                 #             24/
#               $hour/              #               00/                      
#                 $logname          #                 $zoneuuid.log or
#                                   #                 $hostname.log
#
# For example:
#
#   $ mls /admin/stor/logs/us-sw-1/cloudapi-8081/2017/04/24/00
#   534ba55a-d33a-4d91-9690-9c496b78ef22.log
#
#   $ mls /admin/stor/logs/us-sw-1/vm-agent/2017/04/24/23
#   1VYRGS1.log
#   2H5PGS1.log
#   2VYRGS1.log
#   ......
#
# For Manta, there is no breakdown by data center. The first-level subdir
# is the service:
#                                   # Example:
#   $basedir/                       #   /poseidon/stor/logs/
#     $service/                     #     mako/ 
#       $year/                      #       2017/
#         $month/                   #         04/
#           $day/                   #           24/
#             $hour/                #             00/                      
#               $logname            #               $zoneuuid.log
#
# For example:
#
#   $ mls /poseidon/stor/logs/mako/2017/04/24/00
#   00c3e6bd.log
#   2a7157a0.log
#   31850a62.log
#   ......
#
# For the Triton usage CN logs, the breakdown is by CN but shares a very
# similar structure:
#                                   # Example:
#   $basedir/                       #   /admin/stor/sdc/usage
#     $datacenter/                  #     us-sw-1/
#       $server/                    #       44454c4c-5a00-1051-8039-b2c04f485331/
#         $year/                    #         2017/
#           $month/                 #           04/
#             $day/                 #             24/
#               $logname            #               $serveruuid.log
#



if [[ -n "$TRACE" ]]; then
    if [[ -t 1 ]]; then
        export PS4='\033[90m[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }\033[39m'
    else
        export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    fi
    set -o xtrace
fi
set -o errexit
set -o pipefail


#---- globals, config

# Get `mls` et al on the PATH.
TOP=$(cd $(dirname $0)/../ >/dev/null; pwd)
export PATH=$TOP/node_modules/.bin:$PATH

#
# A mapping from service name to the number of days' logs to keep.
#
# TTL (Time To Live) values are set based on the nature of the service:
# - end-user API and account management: do not purge
#       examples: cloudapi, docker, ufds
# - services on orchestration path: 2 years
#       examples: imgapi, vmapi, vmadm, napi, fwapi, fmadm, cns
# - services serving administrative or metrics functions: 1 year
#       examples: amon, adminui, ca, cmon, dhcpd, registrar, hermes
#
TTL_DAYS_FROM_NAME_TRITON='{
    "adminui": 365,
    "amon-agent": 365,
    "amon-master": 365,
    "amon-updater": 365,
    "binder": 365,
    "caaggsvc-auto0": 365,
    "caaggsvc-auto1": 365,
    "caaggsvc-auto10": 365,
    "caaggsvc-auto11": 365,
    "caaggsvc-auto12": 365,
    "caaggsvc-auto13": 365,
    "caaggsvc-auto14": 365,
    "caaggsvc-auto15": 365,
    "caaggsvc-auto16": 365,
    "caaggsvc-auto17": 365,
    "caaggsvc-auto18": 365,
    "caaggsvc-auto19": 365,
    "caaggsvc-auto20": 365,
    "caaggsvc-auto21": 365,
    "caaggsvc-auto22": 365,
    "caaggsvc-auto23": 365,
    "caaggsvc-auto24": 365,
    "caaggsvc-auto25": 365,
    "caaggsvc-auto2": 365,
    "caaggsvc-auto3": 365,
    "caaggsvc-auto4": 365,
    "caaggsvc-auto5": 365,
    "caaggsvc-auto6": 365,
    "caaggsvc-auto7": 365,
    "caaggsvc-auto8": 365,
    "caaggsvc-auto9": 365,
    "caconfigsvc": 365,
    "castashsvc": 365,
    "cloudapi-8081": 9999,
    "cloudapi-8082": 9999,
    "cloudapi-8083": 9999,
    "cloudapi-8084": 9999,
    "cmon": 365,
    "cmon-agent": 365,
    "cn-agent": 730,
    "cnapi": 730,
    "cns-server": 730,
    "cns-updater": 730,
    "config-agent": 365,
    "dhcpd": 365,
    "docker": 9999,
    "dockerlogger": 365,
    "firewaller": 730,
    "fwadm": 730,
    "fwapi": 730,
    "hermes": 365,
    "hermes-proxy": 365,
    "imgapi": 730,
    "mahi-replicator": 365,
    "mahi-server": 365,
    "manatee-backupserver": 365,
    "manatee-postgres": 365,
    "manatee-sitter": 365,
    "manatee-snapshotter": 365,
    "moray": 365,
    "napi": 730,
    "napi-ufds-watcher": 365,
    "net-agent": 365,
    "papi": 365,
    "pgdump": 365,
    "portolan": 365,
    "provisioner": 365,
    "rabbitmq": 365,
    "redis": 365,
    "registrar": 365,
    "sapi": 730,
    "sdcadm": 365,
    "tftpd": 365,
    "ufds-capi": 9999,
    "ufds-master": 9999,
    "ufds-master-1390": 9999,
    "ufds-master-1391": 9999,
    "ufds-master-1392": 9999,
    "ufds-master-1393": 9999,
    "ufds-replicator": 9999,
    "vm-agent": 730,
    "vmadm": 730,
    "vmadmd": 730,
    "vmapi": 730,
    "wf-api": 730,
    "wf-backfill": 365,
    "wf-runner": 365,
    "zookeeper": 365 
}'

# We are not purging any manta logs at this time
TTL_DAYS_FROM_NAME_MANTA='{
}'

# All usage logs will be retained for 90 days only
TTL_DAYS_FROM_NAME_USAGE='{
    "all": 90
}'

opt_dryrun=yes    # Dry-run by default.
opt_quiet=no


#---- functions

function usage() {
    if [[ -n "$1" ]]; then
        echo "error: $1"
        echo ""
    fi
    echo 'Usage:'
    echo '  purge-system-logs [<options>] MANTA-LOGS-DIR [DATACENTER]'
    echo ''
    echo 'Options:'
    echo '  -h          Print this help and exit.'
    echo '  -q          Quiet output.'
    echo '  -n          Dry-run (the default!).'
    echo '  -f          Force actually doing deletions.'
    echo ''
    echo 'Examples:'
    echo '  purge-system-logs /admin/stor/logs               # dry-run by default'
    echo '  purge-system-logs -f /admin/stor/logs            # -f to actually rm'
    echo '  purge-system-logs -f /admin/stor/logs datacenter # prune a certain DC'
    echo '  purge-system-logs -f /admin/stor/sdc/usage datacenter # usage logs'
    if [[ -n "$1" ]]; then
        exit 1
    else
        exit 0
    fi
}

function fatal {
    echo "$(basename $0): error: $1" >&2
    exit 1
}

function errexit
{
    [[ $1 -ne 0 ]] || exit 0
    fatal "error exit status $1"
}

function log
{
    if [[ "$opt_quiet" == "no" ]]; then
        echo "$*"
    fi
}

function ttl_days_from_name
{
    local logs_dir
    local name
    logs_dir=$1
    name=$2

    if [[ $logs_dir == "/admin/stor/logs" ]]; then
        echo "$TTL_DAYS_FROM_NAME_TRITON" | json -- $name
    elif [[ $logs_dir == "/poseidon/stor/logs" ]]; then
        echo "$TTL_DAYS_FROM_NAME_MANTA" | json -- $name
    elif [[ $logs_dir == "/admin/stor/sdc/usage" ]]; then
        echo "$TTL_DAYS_FROM_NAME_USAGE" | json -- $name
    else
        fatal "Cannot get TTL for unknown log archive $logs_dir"
    fi
}

function purge_dir_all
{
    local dir
    dir="$1"
    log "mrm -r $dir"
    if [[ "$opt_dryrun" == "no" ]]; then
        if [[ -n "$TRACE" ]]; then
            mrm -rv "$dir"
        else
            mrm -r "$dir"
        fi
    fi
}

function purge_dir
{
    local dir
    dir="$1"
    log "mrmdir $dir"
    if [[ "$opt_dryrun" == "no" ]]; then
        if [[ -n "$TRACE" ]]; then
            mrmdir -v "$dir"
        else
            mrmdir "$dir"
        fi
    fi
}

function purge_file
{
    local file
    file="$1"
    log "mrm    $file"   # spacing to line up with purge_dir log line
    if [[ "$opt_dryrun" == "no" ]]; then
        mrm "$file"
    fi
}

function purge_system_logs
{
    local logs_dir
    local dc_dir
    local top_dir
    local ttl_days
    local cutoff
    local cutoff_year
    local cutoff_month
    local service
    local services
    local logname
    local lognames
    local year
    local years
    local month
    local months
    local day
    local days
    local hour
    local hours
    local ttl_key

    logs_dir=$1
    dc_dir=$2
    dryrun_msg=
    if [[ $opt_dryrun != "no" ]]; then
        dryrun_msg=", dry-run"
    fi

    if [[ -n $dc_dir ]]; then
        top_dir=$logs_dir/$dc_dir
    else
        top_dir=$logs_dir
    fi
    services=$(mls $top_dir | sed -e 's#/$##' | xargs)

    for service in $services; do
#       The 'cutoff' is the current time minus the ttl_days number of days,
#       in the format of YYYY-MM-DD.
        if [[ $logs_dir == "/admin/stor/sdc/usage" ]]; then 
            ttl_key="all"
        else
            ttl_key=$service
        fi

        ttl_days=$(ttl_days_from_name $logs_dir $ttl_key)

        if [[ -z "$ttl_days" ]]; then
            log "# skip $top_dir/$service: do not have a TTL for '$service'"
            continue
        fi

        cutoff=$(node -e "c=new Date();
            c.setDate(c.getDate() - $ttl_days);
            console.log(c.toISOString().substring(0,10))")
        cutoff_year=$(echo $cutoff | cut -d'-' -f 1)
        cutoff_month=$cutoff_year"-"$(echo $cutoff | cut -d'-' -f 2)
        log "# purge-system-logs in $top_dir/$service older than" \
            "$cutoff (ttl $ttl_days days$dryrun_msg)"

        years=$(mls $top_dir/$service | sed -e 's#/$##' | xargs)
        for year in $years; do
            if [[ $year > $cutoff_year ]]; then
                continue
            fi
            months=$(mls $top_dir/$service/$year | sed -e 's#/$##' | xargs)
            for month in $months; do
                dir=$year"-"$month
                if [[ $dir > $cutoff_month ]]; then
                    continue
                fi
                days=$(mls $top_dir/$service/$year/$month | sed -e 's#/$##' | xargs)
                for day in $days; do
                    dir=$year"-"$month"-"$day
                    if [[ $dir > $cutoff ]]; then
                        continue
                    fi
                    purge_dir_all $top_dir/$service/$year/$month/$day
                done
            done
        done
    done

}


#---- mainline

trap 'errexit $?' EXIT

while getopts "hqnf" ch; do
    case "$ch" in
    h)
        usage
        ;;
    q)
        opt_quiet=yes
        ;;
    n)
        opt_dryrun=yes
        ;;
    f)
        opt_dryrun=no
        ;;
    *)
        usage "illegal option -- $OPTARG"
        ;;
    esac
done
shift $((OPTIND - 1))

LOGS_DIR=$1
DATACENTERS=$2
[[ -n "$LOGS_DIR" ]] || fatal "MANTA-LOGS-DIR argument not given"
shift
NAMES="$*"

if [[ $LOGS_DIR == "/admin/stor/logs"* ]]; then
    log "# Pruning Triton log archive"

    if [[ -z "$DATACENTERS" ]]; then
        DATACENTERS=$(mls --type d $LOGS_DIR | sed -e 's#/$##' | xargs)
    fi

    for DC_DIR in $DATACENTERS; do
        purge_system_logs "$LOGS_DIR" "$DC_DIR"
    done
elif [[ $LOGS_DIR == "/poseidon/stor/logs" ]]; then
    log "# Pruning Manta log archive"
    purge_system_logs "$LOGS_DIR"
elif [[ $LOGS_DIR == "/admin/stor/sdc/usage"* ]]; then
    log "# Pruning usage log archive"

    if [[ -z "$DATACENTERS" ]]; then
        DATACENTERS=$(mls --type d $LOGS_DIR | sed -e 's#/$##' | xargs)
    fi

    for DC_DIR in $DATACENTERS; do
        purge_system_logs "$LOGS_DIR" "$DC_DIR"
    done
else
    fatal "Unknown log archive $LOGS_DIR"
fi
