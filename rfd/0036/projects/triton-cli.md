<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Casey Bisson, Joyent
-->

# Changes to existing Triton CLI commands (and CloudAPI, by extension)

The introduction of projects, and the rule that all infrastructure resources _must_ be within a project requires changes in existing CloudAPI methods and Triton CLI commands.

## Specifying the organization and project

The expectation that infrastructure resources, including compute instances, networks, firewall rules, RFD26 storage, and (in a potential future) Manta buckets/namespaces requires that the organization and project be specified when interacting with those resources.

All `triton` commands must support flags to specify the organization and project:

- `-j <project name|uuid>`
- `-o <organization name|uuid>`

Additionally, the [`triton project set <project name or UUID>` command](./triton-projects-cli.md#triton-project-setset-current-project-name-or-uuid) can set a default project. Once invoked, it will have the effect of injecting a `-j` for each subsequent command that requires a project.

A similar command is expected to set the default organization, perhaps `triton organization set <project name or UUID>`.

If no project or organization are specified using either of the methods described above, the following defaults are used:

- Project: `default`
- Organization: the user's personal organization

## Commands that require an organization and project

The following list of current and proposed Triton CLI commands all require the user to specify an organization and project:

- `triton instance *`
- `triton network *`
- `triton fabric *`
- `triton nic *`
- `triton fwrule *`
- [`triton volume *`](https://github.com/joyent/rfd/blob/master/rfd/0026/README.md#cli)

When invoking commands to list objects, such as `triton instance ls`, those commands must restrict their output to objects that are members of the specified organization and project.

When invoking commands that create new objects, such as `triton inst create`, those objects must be created within the specified organization and project.

TODO: define behavior when attempting to add a network/NIC to an instance from a different project.

Commands that manipulate existing objects, often by UUID, could conceivably continue to operate as usual, but this RFD suggests they must error if the specified object is not within the specified organization and project.

## Commands that require an organization, but not a project

- `triton image *`

## Commands that _do not_ require an organization or project

- `triton account`
- `triton key`
- `triton datacenters`
- `triton packages` (if an org is specified, will show custom packages available to that org)
