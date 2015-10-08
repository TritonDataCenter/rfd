----
authors: Pedro Palazón Candel <pedro@joyent.com>
state: draft
----

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent Inc.
-->

# RFD 9 sdcadm fabrics management

## Introduction

The purpose of this RFD is to define the sdcadm CLI tools to setup and
configure fabrics, update fabrics configuration and create default
fabric for customers.

## Overview

Actually there are a set of `sdcadm experimental` subcommands intended to
provide operators the toolkit required in order to setup and configure
fabrics:

- `sdcadm experimental portolan`: Adds/updates the portolan service.
- `sdcadm experimental fabrics`: Initializes fabrics in the SDC setup.
- `sdcadm experimental default-fabric <account-uuid>`: Initializes default
  fabric for the given account.

Additionally, in order to complete the initial fabrics setup, we need to
add underlay nics to the list of desired Compute Nodes:

    sdcadm post-setup underlay-nics NETWORK-UUID [CN1 CN2 CN3 ...]

Finally when docker service is installed, we need to update service
configuration in order to use fabrics:

    docker=$(sdc-sapi /services?name=docker | json -Ha uuid)
    sapiadm update $docker metadata.USE_FABRICS=true

Furthermore, given that it's possible to re-run the `experimental fabrics`
subcommand with the `-f|--force` flag to update `fabric_cfg` value in SAPI,
this subcommand is also used with that purpose.

## Objective

Simplify the initial setup and configuration of fabrics into a SDC setup
through a single `sdcadm post-setup fabrics` subcommand. (TOOLS-1094)

## Proposal

`sdcadm post-setup fabrics` subcommand will include functionality from both,
`sdcadm experimental fabrics` and `sdcadm experimental portolan`, and will
deprecate both.

Also, the aforementioned docker service update when present will also
take place when required, without any need for the operator to issue a
separate step.

The subcommand `sdcadm experimental default-fabric` will be moved out of
experimental and remain available to create customers default fabrics.

### Command options

#### No prompt for config

The current `sdcadm experimental fabrics` help claims that it'll be able to
prompt the user about the desired configuration values for `fabric_cfg` when no
configuration file is provided through the `-c|--conf` option. This was just
an original design desire and never was implemented. There is no need to
implement such ability on a first pass and the new `sdcadm post-setup fabrics`
command can continue having the same `-c|--conf` option as the only way to
provide the desired configuration.

#### Remove --coal option

The `--coal` option available when running `sdcadm experimental fabrics` in
COAL is not really needed in order to apply default COAL configuration instead
of providing a configuration file.

This option will be removed in order to do not introduce COAL specific
functionality. Explanation on the recommended configuration for COAL will
be provided as an example.

### Do not use to reprovision portolan

The `--force` option for `sdcadm experimental portolan` is used to allow a
re-run of the command and, eventually, to update the image used to provision
the portolan zone and reprovision it. Given `sdcadm update portolan` can handle
that functionality, we'll remove such reprovisioning functionality for portolan
from `sdcadm post-setup fabrics`.

### Rename --force option to something meaningful for fabrics reconfiguration

The `--force` option for `sdcadm experimental fabrics` allows to re-run the
command and makes an update of SAPI's `fabric_cfg` metadata for the `sdc`
application. Additionally, and despite of the fact that this configuration
update might just left the configuration as it was, the command is restarting
`config-agent` service into `napi`, `vmapi` and `dhcpd` zones.

In the case of changes happening on the configuration of those services,
such restart of `config-agent` will result into a restart of these services.
The command doesn't provide any kind of warning or requests any confirmation
from the user and, furthermore, didn't locks the DC.

Proposal will be to reword this option into a new `--reconfigure` option, which
is clearer regarding the purpose or re-running the `sdcadm post-setup fabrics`
command.

It will continue taking care of restarting the required `config-agent` services
here and there as needed and will make clear to the user that the command which
is issuing will have effects over other services and that we can temporary put
the SDC setup into maintenance.

