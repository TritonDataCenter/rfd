---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues/83
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 127 In-process Brand Hooks

## Introduction

Some zone brands, in particular bhyve (see [RFD 121](../0121/README.md)), could
benefit from tighter coupling.  For example use cases, see

- [OS-6717](https://jira.joyent.us/browse/OS-6717) bhyve brand boot should not
  succeed until bhyve allocates resources
- [OS-6718](https://jira.joyent.us/browse/OS-6718) need console and other logs
- [OS-6760](https://jira.joyent.us/browse/OS-6760) bhyve brand should create ppt
  devices

It is proposed that each brand is able to provide a set of callbacks that may
be used to replace some or all of the brand hooks.  A default set of callbacks
will be implemented that preserve existing behavior, allowing existing brands to
be unchanged in implementation and behavior.

## Background

In the initial public implementation of zones, there were no brands.  All
zone operations were carried out directly by `zoneadm` or by `zoneadmd`.
Branded zones were created by Sun to behavior specific to various forms of
emulation as they added Solaris 8, Solaris 9, and Linux zones as distinct
brands.

The introduction of branded zones introduced brand hooks that may be called to
perform all or part of the tasks needed before, during, and after various state
changes.  Brand hooks are implemented as separate programs - usually shell
scripts - that are forked from `zoneadm` or `zoneadmd`.  The only meaningful
interchange between `zoneadm` or `zoneadmd` and the brand hooks involve command
line arguments and exit codes.

The existing implementation has led to a complex mixture of mandatory operations
performed by code that descends directly from the initial zones implementation,
optional brand-specific behavior, and in some cases fallback behavior if the
brand does not specify an option.  There is no way for a brand to fully override
the behavior of some state change operations and code reuse between `zoneadmd`
and brand hooks is not practical.

## Implementation

Only those brand hooks that are called from zoneadmd are relevant to this RFD.

| Hook              | In Scope  | Called By |
|-------------------|:---------:|-----------|
| boot              | yes       | zoneadmd  |
| halt              | yes       | zoneadmd  |
| poststatechange   | yes       | zoneadmd  |
| prestatechange    | yes       | zoneadmd  |
| query             | yes       | zoneadmd  |
| shutdown          | yes       | zoneadmd  |
| attach            | no        | zoneadm   |
| clone             | no        | zoneadm   |
| detach            | no        | zoneadm   |
| install           | no        | zoneadm   |
| postsnap          | no        | zoneadm   |
| postattach        | no        | zoneadm   |
| postclone         | no        | zoneadm   |
| postinstall       | no        | zoneadm   |
| predetach         | no        | zoneadm   |
| presnap           | no        | zoneadm   |
| preuninstall      | no        | zoneadm   |
| sysboot           | no        | zoneadm   |
| uninstall         | no        | zoneadm   |
| validatesnap      | no        | zoneadm   |
| verify\_cfg       | no        | zonecfg   |
| verify\_adm       | no        | zoneadm   |

It is expected that over time this list of in-process brand hooks will grow.
For example, while implementing
[logging](https://jira.joyent.us/browse/OS-6718), a new brand hook will likely
be added that is called whenever zoneadmd starts.  The addition of a new
in-process brand hook like this does not automatically trigger the creation of a
legacy brand hook.

## Interfaces

These interfaces are private to `zoneadmd`.  Each brand that implements
in-process brand hooks is expected to be built as part of illumos or a
derivative of illumos.  As experience is gained with these interfaces, they may
become public and implementable as a shared library.

The expected header file content is:

```
typedef int (*zcb_func_t)(zcb_ctx *);
extern int zcb_noop(zcb_ctx);

typedef struct zcb_ctx {
        zlog_t          *zctx_zlogp;
        zone_cmd_arg_t  *zctx_cmd;
        zone_state_t    zctx_state;
        /* TBD */
} zcb_ctx_t;

typedef struct zcb_callbacks {
        zcb_func_t zcb_preready;
        zcb_func_t zcb_ready;
        zcb_func_t zcb_postready;
        zcb_func_t zcb_preboot;
        zcb_func_t zcb_boot;
        zcb_func_t zcb_postboot;
        zcb_func_t zcb_prehalt;
        zcb_func_t zcb_halt;
        zcb_func_t zcb_posthalt;
        zcb_func_t zcb_query;
        zcb_func_t zcb_shutdown;
} zcb_callbacks;
```

## Compatibility with traditional brand hooks

A set of legacy brand callbakcs will be provided that preserve existing
behavior.  If no in-process brand hooks exist for a particular brand, the legacy
brand hook callbacks will be used.  A brand that wishes to ovverride only a
subset of the legacy hooks can uses a mixture of in-process hooks and legacy
hooks.
