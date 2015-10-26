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


| CloudAPI Endpoint                | Notes  | Triton command |
| -------------------------------- | ------ | -------------- |
| **ACCOUNT**                      |        |                |
| GetAccount                       |        | `triton account` |
| UpdateAccount                    | NYI    | `triton account -e [FIELD=VALUE ...]` |
| **KEYS**                         |        |                |
| ListKeys                         |        | `triton keys` |
| GetKey                           | NYI    | `triton key KEY` |
| CreateKey                        | NYI    | `triton key -a` |
| DeleteKey                        | NYI    | `triton key -d` |
| **USERS**                        | \*RBAC |                |
| ListUsers                        | NYI    | `triton users` |
| GetUser                          | NYI    | `triton user USER` |
| CreateUser                       | NYI    | `triton user -a ...` |
| UpdateUser                       | NYI    | `triton user -e USER [FIELD=VALUE ...]` |
| ChangeUserPassword               | NYI    | `triton user --change-password USER` |
| DeleteUser                       | NYI    | `triton user -d USER` |
| **ROLES**                        | \*RBAC |                |
| ListRoles                        | NYI    | `triton roles` |
| GetRole                          | NYI    | `triton role ROLE` |
| CreateRole                       | NYI    | `triton role -a ...` |
| UpdateRole                       | NYI    | `triton role -e ROLE [FIELD=VALUE ...]` |
| DeleteRole                       | NYI    | `triton role -d ROLE` |
| **ROLE TAGS**                    | \*RBAC |                |
| SetRoleTags                      | -      |                |
| **POLICIES**                     | \*RBAC |                |
| ListPolicies                     | -      |                |
| GetPolicy                        | -      |                |
| CreatePolicy                     | -      |                |
| UpdatePolicy                     | -      |                |
| DeletePolicy                     | -      |                |
| **USER SSH KEYS**                | \*RBAC |                |
| ListUserKeys                     | -      |                |
| GetUserKey                       | -      |                |
| CreateUserKey                    | -      |                |
| DeleteUserKey                    | -      |                |
| **CONFIG**                       | \*CONFIG |              |
| GetConfig                        | NYI    | `triton account-config` |
| UpdateConfig                     | NYI    | `triton account-config -e ...` |
| **DATACENTERS**                  |        |                |
| ListDatacenters                  |        | `triton datacenters` |
| GetDatacenter                    | NYI    | `triton datacenter DC` |
| **SERVICES**                     |        |                |
| ListServices                     |        | `triton services` |
| **IMAGES**                       |        |                |
| ListImages                       |        | `triton images` |
| GetImage                         |        | `triton image IMG` |
| DeleteImage                      | NYI    | `triton image -d IMG` |
| ExportImage                      | NYI    | `triton image --export [--manta-path=...] IMG` |
| CreateImageFromMachine           | NYI    | `triton image-create` |
| UpdateImage                      | NYI    | `triton image -e IMG` |
| **PACKAGES**                     |        |                |
| ListPackages                     |        | `triton packages` |
| GetPackage                       |        | `triton package PKG` |
| **MACHINES**                     |        |                |
| ListMachines                     |        | `triton instances` |
| GetMachine                       |        | `triton instance INST` |
| CreateMachine                    |        | `triton create` |
| StopMachine                      |        | `triton stop` |
| StartMachine                     |        | `triton start` |
| RebootMachine                    |        | `triton reboot` |
| ResizeMachine                    | -      |                |
| RenameMachine                    | \*     | `triton inst -e INST [name=NAME]` |
| EnableMachineFirewall            | NYI    | `triton inst --enable-firewall INST` |
| DisableMachineFirewall           | NYI    | `triton inst --disable-firewall INST` |
| ListMachineSnapshots             | NYI    | `triton snapshots INST` |
| GetMachineSnapshot               | NYI    | `triton snapshot INST SNAP` |
| CreateMachineSnapshot            | NYI    | `triton snapshot -c INST SNAP` |
| StartMachineFromSnapshot         | NYI    | `triton start --snapshot=SNAPSHOT` |
| DeleteMachineSnapshot            | NYI    | `triton snapshot -d INST SNAP` |
| UpdateMachineMetadata            | NYI\*  | `triton [instance-]metadata -a [-f] INST [FIELD=VALUE ...]` |
| ListMachineMetadata              | NYI    | `triton [instance-]metadata INST` |
| GetMachineMetadata               | NYI    | `triton [instance-]metadata INST KEY` |
| DeleteMachineMetadata            | NYI    | `triton [instance-]metadata INST KEY -d` |
| DeleteAllMachineMetadata         | NYI    | `triton [instance-]metadata INST -da` |
| AddMachineTags                   | NYI    | `triton tag -a INST/IMG KEY=VALUE` |
| ReplaceMachineTags               | NYI\*  | `triton tag -af INST/IMG KEY=VALUE [...]` |
| ListMachineTags                  | NYI    | `triton tags INST` |
| GetMachineTag                    | NYI    | `triton tag INST KEY` |
| DeleteMachineTag                 | NYI    | `triton tag -d INST KEY` |
| DeleteMachineTags                | NYI    | `triton tags -d INST KEY` |
| DeleteMachine                    |        | `triton rm INST` |
| MachineAudit                     |        | `triton [instance-]audit` |
| **ANALYTICS**                    |        |                |
| DescribeAnalytics                | -      |                |
| ListInstrumentations             | -      |                |
| GetInstrumentation               | -      |                |
| GetInstrumentationValue          | -      |                |
| GetInstrumentationHeatmap        | -      |                |
| GetInstrumentationHeatmapDetails | -      |                |
| CreateInstrumentation            | -      |                |
| DeleteInstrumentation            | -      |                |
| **FIREWALL RULES**               |        |                |
| ListFirewallRules                | -      |                |
| GetFirewallRule                  | -      |                |
| CreateFirewallRule               | -      |                |
| UpdateFirewallRule               | -      |                |
| EnableFirewallRule               | -      |                |
| DisableFirewallRule              | -      |                |
| DeleteFirewallRule               | -      |                |
| ListMachineFirewallRules         | -      |                |
| ListFirewallRuleMachines         | -      |                |
| **FABRICS**                      | -      |                |
| ListFabricVLANs                  | -      |                |
| CreateFabricVLAN                 | -      |                |
| GetFabricVLAN                    | -      |                |
| UpdateFabricVLAN                 | -      |                |
| DeleteFabricVLAN                 | -      |                |
| ListFabricNetworks               | -      |                |
| CreateFabricNetwork              | -      |                |
| GetFabricNetwork                 | -      |                |
| DeleteFabricNetwork              | -      |                |
| **NETWORKS**                     |        |                |
| ListNetworks                     |        | `triton networks` |
| GetNetwork                       |        | `triton network NET` |
| **NICS**                         | \*NICS |                |
| ListNics                         | NYI    | `triton nics` |
| GetNic                           | NYI    | `triton nic NIC` |
| AddNic                           | NYI    | `triton nic -a ...` |
| RemoveNic                        | NYI    | `triton nic -d NIC` |


Notes:

- RBAC: Feels a little generic: users, roles, roletags, policies. Perhaps
  these should all be under a 'triton rbac ...' or something. Some *single*
  widely used term should be prevalent in the CLI, APIs, Docs and UIs. For
  AWS is it "IAM". For Triton, "RBAC"? Relevant commands from node-smartdc
  to re-used: sdc-chmod, sdc-info, sdc-policy, sdc-role, sdc-user.
- CONFIG: 'Config' is a poor name, IMO. So generic. Should be called, perhaps,
  'Account Config'. Cloudapi rev to rename them? Endpoints can otherwise be the
  same.
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



# `TritonApi` and `CloudApi` coverage

The node-triton module also provides a node library interface to the raw
CloudAPI and to a more helpful slightly higher level "Triton API" -- the
foundation of the `triton` commands.  Coverage for these, esp. the `TritonApi`
is much less complete. The work to be done there should be documented.
