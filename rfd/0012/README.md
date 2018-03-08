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
| GetAccount                       | DONE     | `triton account get`                                        |
| UpdateAccount                    | DONE     | `triton account update`                                     |
| **KEYS**                         |          |                                                             |
| ListKeys                         | DONE     | `triton key list`, `triton keys`                            |
| GetKey                           | DONE     | `triton key get KEY`                                        |
| CreateKey                        | DONE     | `triton key add ...`                                        |
| DeleteKey                        | DONE     | `triton key delete KEY`                                     |
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
| SetRoleTags                      | DONE     | `triton rbac role-tags ...`                                 |
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
| GetConfig                        | NYI      | `triton account-config get-all` ???                         |
| UpdateConfig                     | NYI      | `triton account-config update ...`                          |
| **DATACENTERS**                  |          |                                                             |
| ListDatacenters                  | DONE     | `triton datacenters`                                        |
| GetDatacenter                    | NYI      | `triton datacenter DC`                                      |
| **SERVICES**                     |          |                                                             |
| ListServices                     | DONE     | `triton services`                                           |
| -------------------------------- | -------- | ----------------------------------------------------------- |
| **IMAGES**                       |          |                                                             |
| ListImages                       | DONE     | `triton image list`, `triton images`                        |
| GetImage                         | DONE     | `triton image get IMG`                                      |
| DeleteImage                      | DONE     | `triton image delete IMG`                                   |
| ExportImage                      | DONE     | `triton image export [--manta-path=...] IMG`                |
| CreateImageFromMachine           | DONE     | `triton image create ...`                                   |
| UpdateImage                      | NYI      | `triton image update IMG`                                   |
| **PACKAGES**                     |          |                                                             |
| ListPackages                     | DONE     | `triton package list`, `triton packages`                    |
| GetPackage                       | DONE     | `triton package get PKG`                                    |
| **MACHINES**                     |          |                                                             |
| ListMachines                     | DONE     | `triton instance list`, `triton instances`                  |
| GetMachine                       | DONE     | `triton instance get INST`                                  |
| CreateMachine                    | DONE     | `triton instance create`, `triton create`                   |
| StopMachine                      | DONE     | `triton instance stop`, `triton stop`                       |
| StartMachine                     | DONE     | `triton instance start`, `triton start`                     |
| RebootMachine                    | DONE     | `triton instance reboot`, `triton reboot`                   |
| ResizeMachine                    | -        |                                                             |
| RenameMachine                    | INC\*    | `triton instance rename INST [name=NAME]`                   |
| EnableMachineFirewall            | DONE     | `triton instance enable-firewall INST`                      |
| DisableMachineFirewall           | DONE     | `triton instance disable-firewall INST`                     |
| DeleteMachine                    | DONE     | `triton instance delete INST ...`                           |
| MachineAudit                     | DONE     | `triton instance audit`                                     |
| ListMachineSnapshots             | DONE     | `triton instance snapshot list INST`                        |
| GetMachineSnapshot               | DONE     | `triton instance snapshot get INST SNAPNAME`                |
| CreateMachineSnapshot            | DONE     | `triton instance snapshot create INST`                      |
| StartMachineFromSnapshot         | DONE     | `triton instance start --snapshot=SNAPNAME`                 |
| DeleteMachineSnapshot            | DONE     | `triton instance snapshot delete INST SNAPNAME`             |
| UpdateMachineMetadata            | NYI\*    | `triton instance update-metadata -a [-f] INST [FIELD=VALUE ...]` |
| ListMachineMetadata              | NYI      | `triton instance list-metadata INST`                        |
| GetMachineMetadata               | NYI      | `triton instance get-metadata INST KEY`                     |
| DeleteMachineMetadata            | NYI      | `triton instance delete-metadata INST KEY`                  |
| DeleteAllMachineMetadata         | NYI      | `triton instance delete-metadata --all INST`                |
| AddMachineTags                   | DONE     | `triton instance tag set INST [KEY=VALUE ...]`              |
| ReplaceMachineTags               | DONE     | `triton instance tag replace-all INST [KEY=VALUE ...]`      |
| ListMachineTags                  | DONE     | `triton instance tag list INST`                             |
| GetMachineTag                    | DONE     | `triton instance tag get INST KEY`                          |
| DeleteMachineTag(s)              | DONE     | `triton instance tag delete INST [KEY ...]`                 |
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
| ListFirewallRules                | DONE     | `triton fwrule list`                                        |
| GetFirewallRule                  | DONE     | `triton fwrule get FWRULE-ID`                               |
| CreateFirewallRule               | DONE     | `triton fwrule create RULE`                                 |
| UpdateFirewallRule               | DONE     | `triton fwrule update FWRULE-ID [FIELD=VALUE ...]`          |
| EnableFirewallRule               | DONE     | `triton fwrule enable FWRULE-ID`                            |
| DisableFirewallRule              | DONE     | `triton fwrule disable FWRULE-ID`                           |
| DeleteFirewallRule               | DONE     | `triton fwrule delete FWRULE-ID`                            |
| ListFirewallRuleMachines         | DONE     | `triton fwrule instances FWRULE-ID`                         |
| ListMachineFirewallRules         | DONE     | `triton instance fwrules INST`                              |
| **FABRICS**                      | \*NICS   |                                                             |
| ListFabricVLANs                  | NYI      |                                                             |
| CreateFabricVLAN                 | NYI      |                                                             |
| GetFabricVLAN                    | NYI      |                                                             |
| UpdateFabricVLAN                 | NYI      |                                                             |
| DeleteFabricVLAN                 | NYI      |                                                             |
| ListFabricNetworks               | NYI      |                                                             |
| CreateFabricNetwork              | NYI      |                                                             |
| GetFabricNetwork                 | NYI      |                                                             |
| DeleteFabricNetwork              | NYI      |                                                             |
| **NETWORKS**                     |          |                                                             |
| ListNetworks                     | DONE     | `triton network list`, `triton networks`                    |
| GetNetwork                       | DONE     | `triton network get NET`                                    |
| **NICS**                         | \*NICS   |                                                             |
| ListNics                         | DONE     | `triton instance nic list INST`                             |
| GetNic                           | DONE     | `triton instance nic get INST MAC`                          |
| AddNic                           | DONE     | `triton instance nic create INST NETWORK`                   |
| RemoveNic                        | DONE     | `triton instance nic delete,rm INST MAC`                    |


Notes:

- RBAC: Feels a little generic: users, roles, roletags, policies. Perhaps
  these should all be under a 'triton rbac ...' or something. Some *single*
  widely used term should be prevalent in the CLI, APIs, Docs and UIs. For
  AWS is it "IAM". For Triton, "RBAC"? Relevant commands from node-smartdc
  to re-used: sdc-chmod, sdc-info, sdc-policy, sdc-role, sdc-user.
  TODO: re-think. At the least, re-cast the style per joyent/node-triton#66.
- CONFIG: 'Config' is a poor name, IMO. So generic. Should be called, perhaps,
  'Account Config'. Cloudapi rev to rename them? Endpoints can otherwise be the
  same.
- RenameMachine: This is async and don't yet have a '-w,--wait' on it.
  <https://github.com/joyent/node-triton/issues/146> for that.
- UpdateMachineMetadata: '-a' for "add". *Is* this really about *adding*
  metadata keys? I.e. excluding a key doesn't delete it? But it *does* allow
  overwrite. Note that AddMachineTags does NOT allow overwrite. IOW, slight
  semantic difference. Sigh. TODO: we *could* give the same semantics manually.
- ReplaceMachineTags: '-f' for "force" to allow overwrite of existing tags?
  This is to attempt to align the differing semantics of this and
  `UpdateMachineMetadata`.
- NICS: See sdc-nics from node-smartdc for some inspiration.
  <https://devhub.joyent.com/jira/browse/PUBAPI-1292> for this.


## RBAC

Herein the plan and discussion for RBAC support. See
<https://github.com/joyent/node-triton/issues/54> for implementation.

    triton rbac ...

Note that this is obsoleted by planned RBAC v2 work: RFD 13, RFD 48, RFD 49.


# `TritonApi` and `CloudApi` coverage

The node-triton module also provides a node library interface to the raw
CloudAPI and to a more helpful slightly higher level "Triton API" -- the
foundation of the `triton` commands.  Coverage for these, esp. the `TritonApi`
is much less complete. The work to be done there should be documented.
