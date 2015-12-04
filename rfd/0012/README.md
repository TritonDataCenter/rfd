---
authors: Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 12 Bedtime for node-smartdc

[node-smartdc](https://github.com/joyent/node-smartdc) is Joyent's current
and venerable CLI for CloudAPI. It is pretty basic (UX-wise) and we want to
replace it with the more useful and usable
[node-triton](https://github.com/joyent/node-triton). That means we need full
coverage of CloudAPI (along with rosetta stone docs, and general user docs,
etc.). This RFD is about nailing down the work to get there.


## `triton` coverage of CloudAPI

A `triton` CLI guide for every CloudAPI endpoint. This effectively is a
comparison to node-smartdc -- for which every CloudAPI has a direct
`sdc-<lowercase endpoint name>` command. This, then, effectively is a TODO
list for node-triton being a full function replacement for node-smartdc.

Values for the "Status" column:
- `NYI` means that the command is proposed but *Not Yet Implemented* in
  node-triton.
- `-` means that no `triton` command has yet been designed/proposed for that
  functionality.
- `INC` means the coverage of the CloudAPI endpoint is incomplete.
- `DONE` means `triton` supports complete coverage of the cloudapi endpoint.

The work TODO, then is to get "DONE" all the way down the Notes column:
(a) verify if INC or DONE for each blank entry; (b) design a triton command for
each `-`; (c) deal with the notes below; (d) complete each INC. We should have
GH issues for each non-trivial chunk of work here.


| CloudAPI Endpoint                | Notes    | Triton command                                              |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **ACCOUNT**                      |          |                                                             |
| GetAccount                       | DONE     | `triton account`                                            |
| UpdateAccount                    | NYI      | `triton account -e [FIELD=VALUE ...]`                       |
| **KEYS**                         |          |                                                             |
| ListKeys                         | DONE     | `triton keys`                                               |
| GetKey                           | NYI      | `triton key KEY`                                            |
| CreateKey                        | NYI      | `triton key -a`                                             |
| DeleteKey                        | NYI      | `triton key -d`                                             |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **USERS**                        | \*RBAC   |                                                             |
| ListUsers                        | DONE     | `triton rbac users`                                         |
| GetUser                          | DONE     | `triton rbac user USER`                                     |
| CreateUser                       | DONE     | `triton rbac user -a ...`                                   |
| UpdateUser                       | INC      | `triton rbac user -e USER [FIELD=VALUE ...]`                |
|                                  | NYI      | `triton rbac user -u USER FILE` ???                         |
| ChangeUserPassword               | NYI      | `triton rbac user --change-password USER`                   |
| DeleteUser                       | DONE     | `triton rbac user -d USER [USER ...]`                       |
| **ROLES**                        | \*RBAC   |                                                             |
| ListRoles                        | DONE     | `triton rbac roles`                                         |
| GetRole                          | DONE     | `triton rbac role ROLE`                                     |
| CreateRole                       | DONE     | `triton rbac role -a ...`                                   |
| UpdateRole                       | INC      | `triton rbac role -e ROLE [FIELD=VALUE ...]`                |
|                                  | NYI      | `triton rbac role -u ROLE FILE` ???                         |
| DeleteRole                       | DONE     | `triton rbac role -d ROLE [ROLE ...]`                       |
| **ROLE TAGS**                    | \*RBAC   |                                                             |
| SetRoleTags                      | -        |                                                             |
| **POLICIES**                     | \*RBAC   |                                                             |
| ListPolicies                     | DONE     | `triton rbac policies`                                      |
| GetPolicy                        | DONE     | `triton rbac policy POLICY`                                 |
| CreatePolicy                     | DONE     | `triton rbac policy -a`                                     |
| UpdatePolicy                     | INC      | `triton rbac policy -e POLICY [FIELD=VALUE ...]`            |
| DeletePolicy                     | DONE     | `triton rbac policy -d POLICY [POLICY ...]`                 |
| **USER SSH KEYS**                | \*RBAC   |                                                             |
| ListUserKeys                     | DONE     | `triton rbac keys USER`                                     |
| GetUserKey                       | DONE     | `triton rbac key USER KEY`                                  |
| CreateUserKey                    | DONE     | `triton rbac key -a USER ...`                               |
| DeleteUserKey                    | DONE     | `triton rbac key -d USER KEY`                               |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **CONFIG**                       | \*CONFIG |                                                             |
| GetConfig                        | NYI      | `triton account-config`                                     |
| UpdateConfig                     | NYI      | `triton account-config -e ...`                              |
| **DATACENTERS**                  |          |                                                             |
| ListDatacenters                  |          | `triton datacenters`                                        |
| GetDatacenter                    | NYI      | `triton datacenter DC`                                      |
| **SERVICES**                     |          |                                                             |
| ListServices                     | DONE     | `triton services`                                           |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **IMAGES**                       |          |                                                             |
| ListImages                       | DONE     | `triton images`                                             |
| GetImage                         | DONE     | `triton image IMG`                                          |
| DeleteImage                      | NYI      | `triton image -d IMG`                                       |
| ExportImage                      | NYI      | `triton image --export [--manta-path=...] IMG`              |
| CreateImageFromMachine           | NYI      | `triton image-create`                                       |
| UpdateImage                      | NYI      | `triton image -e IMG`                                       |
| **PACKAGES**                     |          |                                                             |
| ListPackages                     | INC      | `triton packages`                                           |
| GetPackage                       | DONE     | `triton package PKG`                                        |
| **MACHINES**                     |          |                                                             |
| ListMachines                     |          | `triton instances`                                          |
| GetMachine                       |          | `triton instance INST`                                      |
| CreateMachine                    | \*CREATE | `triton create`                                             |
| StopMachine                      |          | `triton stop`                                               |
| StartMachine                     |          | `triton start`                                              |
| RebootMachine                    |          | `triton reboot`                                             |
| ResizeMachine                    | -        |                                                             |
| RenameMachine                    | \*       | `triton inst -e INST [name=NAME]`                           |
| EnableMachineFirewall            | NYI      | `triton inst --enable-firewall INST`                        |
| DisableMachineFirewall           | NYI      | `triton inst --disable-firewall INST`                       |
| ListMachineSnapshots             | NYI      | `triton snapshots INST`                                     |
| GetMachineSnapshot               | NYI      | `triton snapshot INST SNAP`                                 |
| CreateMachineSnapshot            | NYI      | `triton snapshot -c INST SNAP`                              |
| StartMachineFromSnapshot         | NYI      | `triton start --snapshot=SNAPSHOT`                          |
| DeleteMachineSnapshot            | NYI      | `triton snapshot -d INST SNAP`                              |
| UpdateMachineMetadata            | NYI\*    | `triton [instance-]metadata -a [-f] INST [FIELD=VALUE ...]` |
| ListMachineMetadata              | NYI      | `triton [instance-]metadata INST`                           |
| GetMachineMetadata               | NYI      | `triton [instance-]metadata INST KEY`                       |
| DeleteMachineMetadata            | NYI      | `triton [instance-]metadata INST KEY -d`                    |
| DeleteAllMachineMetadata         | NYI      | `triton [instance-]metadata INST -da`                       |
| AddMachineTags                   | NYI      | `triton tag -a INST/IMG KEY=VALUE`                          |
| ReplaceMachineTags               | NYI\*    | `triton tag -af INST/IMG KEY=VALUE [...]`                   |
| ListMachineTags                  | NYI      | `triton tags INST`                                          |
| GetMachineTag                    | NYI      | `triton tag INST KEY`                                       |
| DeleteMachineTag                 | NYI      | `triton tag -d INST KEY`                                    |
| DeleteMachineTags                | NYI      | `triton tags -d INST KEY`                                   |
| DeleteMachine                    | DONE     | `triton rm INST ...`                                        |
| MachineAudit                     | DONE     | `triton [instance-]audit`                                   |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **ANALYTICS**                    |          |                                                             |
| DescribeAnalytics                | -        |                                                             |
| ListInstrumentations             | -        |                                                             |
| GetInstrumentation               | -        |                                                             |
| GetInstrumentationValue          | -        |                                                             |
| GetInstrumentationHeatmap        | -        |                                                             |
| GetInstrumentationHeatmapDetails | -        |                                                             |
| CreateInstrumentation            | -        |                                                             |
| DeleteInstrumentation            | -        |                                                             |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **FIREWALL RULES**               |          |                                                             |
| ListFirewallRules                | -        |                                                             |
| GetFirewallRule                  | -        |                                                             |
| CreateFirewallRule               | -        |                                                             |
| UpdateFirewallRule               | -        |                                                             |
| EnableFirewallRule               | -        |                                                             |
| DisableFirewallRule              | -        |                                                             |
| DeleteFirewallRule               | -        |                                                             |
| ListMachineFirewallRules         | -        |                                                             |
| ListFirewallRuleMachines         | -        |                                                             |
| **FABRICS**                      | -        |                                                             |
| ListFabricVLANs                  | -        |                                                             |
| CreateFabricVLAN                 | -        |                                                             |
| GetFabricVLAN                    | -        |                                                             |
| UpdateFabricVLAN                 | -        |                                                             |
| DeleteFabricVLAN                 | -        |                                                             |
| ListFabricNetworks               | -        |                                                             |
| CreateFabricNetwork              | -        |                                                             |
| GetFabricNetwork                 | -        |                                                             |
| DeleteFabricNetwork              | -        |                                                             |
| **NETWORKS**                     |          |                                                             |
| ListNetworks                     |          | `triton networks`                                           |
| GetNetwork                       |          | `triton network NET`                                        |
| **NICS**                         | \*NICS   |                                                             |
| ListNics                         | NYI      | `triton nics`                                               |
| GetNic                           | NYI      | `triton nic NIC`                                            |
| AddNic                           | NYI      | `triton nic -a ...`                                         |
| RemoveNic                        | NYI      | `triton nic -d NIC`                                         |


Notes:

- RBAC: Feels a little generic: users, roles, roletags, policies. Perhaps
  these should all be under a 'triton rbac ...' or something. Some *single*
  widely used term should be prevalent in the CLI, APIs, Docs and UIs. For
  AWS is it "IAM". For Triton, "RBAC"? Relevant commands from node-smartdc
  to re-used: sdc-chmod, sdc-info, sdc-policy, sdc-role, sdc-user.
- CONFIG: 'Config' is a poor name, IMO. So generic. Should be called, perhaps,
  'Account Config'. Cloudapi rev to rename them? Endpoints can otherwise be the
  same.
- CREATE: `triton create` doesn't cover the full CreateMachine. See "triton
  create" section below to flesh that out.
- RenameMachine: Allow editing of metadata and tags as well. Really should just
  be a UpdateMachine? Is there one?
- UpdateMachineMetadata: '-a' for "add". *Is* this really about *adding*
  metadata keys? I.e. excluding a key doesn't delete it? But it *does* allow
  overwrite. Note that AddMachineTags does NOT allow overwrite. IOW, slight
  semantic difference. Sigh. TODO: we *could* give the same semantics manually.
- ReplaceMachineTags: '-f' for "force" to allow overwrite of existing tags?
  This is to attempt to align the differing semantics of this and
  `UpdateMachineMetadata`.
- NICS: See sdc-nics from node-smartdc for some inspiration.
- The whole "... foo -e ..." CLI UX for "edit/update" isn't figured out yet.

## triton create

`triton create` isn't complete. There are lots of options to CreateMachine that
it doesn't yet support.

TODO: list missing things and start fleshing it out


## RBAC

Herein the plan and discussion for RBAC support. See
<https://github.com/joyent/node-triton/issues/54> for implementation.

    triton rbac ...


- Perhaps `triton rbac users -a` to take a file or stdin with array of JSON
  users to create a number of users in a single go?
- Perhaps `triton rbac roles -a` to take a file or stdin with an *array* of JSON roles.
- CreateRole: Interactive and from JSON file or stdin.
- SetRoleTags: Seperate ones for each?

        triton rbac role-tags,tags

        triton rbac tag,role-tag ROLE[,ROLE2] RESOURCE [RESOURCE...]

        # NO: triton rbac tag dev inst foo image bar pkg frank   # confusing

        triton insts -r|resource FILTERS... | xargs triton rbac tag ROLE
            triton insts -r|--resource brand=docker | xargs triton rbac tag containerize
            triton rbac tag containerize $(triton inst -r db1)
            TODO: -r|--resource output mode for all resources: inst(s), img(s), pkg(s), net(s), etc.

        # Sigh... these are backwards from above.
        triton rbac tag-instance INST ROLE
        triton rbac tag-image IMG ROLE
        triton rbac tag-package PKG ROLE
        triton rbac tag-network NET ROLE
        Ugh: what about all these???
            var validResources = ['machines', 'users', 'roles', 'packages',
                'images', 'policies', 'keys', 'datacenters',
                'fwrules', 'networks', 'instrumentations'
            TODO: need to think through all of these and with the 'all access'
            administrator policy. Yuck.

        triton rbac [role-]tag -r ROLE[,ROLE2] RESOURCE...
            triton rbac tag -r ops /my/machines/a8a8428e-84e0-11e5-b55b-8f05619811db
            triton rbac tag -r ops inst:a8a8428e        # not sure, thinking not
            triton rbac tag-instances -r ops a8a8428e

        How about:
            triton inst -r|--role-tag ops INST?
        I like that better. Read on, though.

How to offer looking at rbac tags? node-smartdc has 'sdc-info', but you need
to know the resource URLs, which is lame. So really want something summary-wise
with `triton rbac tags` and/or something hanging off the individual resource
commands. If this to *assign* a tag:
    triton inst -r|--role-tag ops INST
what to *list* role tags? Hrm. Could include role-tags in the bodies of the
objects:
    $ triton inst -r,--role-tags rbactest0
    {
        "id": "4728b800-e7a1-ca39-8150-871d5b6c8005",
        "name": "rbactest0",
        "type": "smartmachine",
        "state": "running",
        "roleTags": ["eng", "ops"],
    ...
then eventually would like cloudapi to support this on the list. It already
needs to effectively do this whenever RBAC is in play.
    $ triton insts -r,--role-tags
    [
        ...
We *could* have the triton client handle this client-side for starters.
Though could be really slow. Would have to warn about that.

We already have:
    triton instance-stop
    triton instance-delete
    triton image-create
(at least after the renaming). Perhaps we should have:
    triton image-role-tag -r ROLE[,ROLE1...] IMAGE
    triton instance-role-tag -r ROLE[,ROLE1...] IMAGE
Those *could* be under 'rbac'... but not sure that is necessary. Cannot shorten
to 'instance-tag' unless under rbac tho. Comparison
    triton instance-role-tag -r ops webhead0
    triton rbac instance-tag -r ops webhead0

Survey. Which one?
1. triton instance-role-tag -r ops webhead0
2. triton rbac instance-tag -r ops webhead0
3. WTF?


Okay, discussion (Trent and Angela) led to this plan:

    $ triton rbac
    ...
    Usage:
        triton rbac [OPTIONS] COMMAND [ARGS...]
        triton rbac help COMMAND

    Commands:
        ...

        instance-role-tags  Show, add, edit and remove RBAC role tags on an instance.
        image-role-tags     Show, add, edit and remove RBAC role tags on an image.
        package-role-tags   Show, add, edit and remove RBAC role tags on a package.
        network-role-tags   Show, add, edit and remove RBAC role tags on a network.


Examples:

    triton rbac instance-role-tags webhead0             # list
    triton rbac instance-role-tags -a eng webhead0      # add
    triton rbac instance-role-tags -d support webhead0  # delete



### rbac summary/info/sync workflow

Don't want to have passwords in a config file.

Perhaps "RBAC Profile"? Could be confusing that you can only have one profile...
vs "Triton CLI Profiles".

    $ triton rbac profile
    ... text summary ...
        If there are no profile items, it says so (clippy-style) and suggests
        commands to run to create one and to look at canned profile examples.
        Use '-q' to avoid this clippy.

    $ triton rbac profile -j
    ... json summary (same as taken) ...

    $ triton rbac profile -j >profile.json
    $ vi profile.json
    $ triton rbac profile --sync=profile.json --dry-run
    $ triton rbac profile --sync=profile.json  # weird?



# `TritonApi` and `CloudApi` coverage

The node-triton module also provides a node library interface to the raw
CloudAPI and to a more helpful slightly higher level "Triton API" -- the
foundation of the `triton` commands.  Coverage for these, esp. the `TritonApi`
is much less complete. The work to be done there should be documented.
