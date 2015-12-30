# Proposed new RBAC actions

*Current* RBAC actions (let's call them RBAC Actions v1) are, for the most part,
the cloudapi and manta (aka muskie) restify endpoint names. Some goals for changes
proposed here:

- Generalize the cloudapi action names to make sense for docker usage as well.
- Introduce namespaces: (a) help separate for UX; (b) separate out the RBAC
  endpoints leading to more naturally supporting globbing (e.g. "ecs:*" for all
  infrastructure stuff, but not the ability to change the RBAC config itself);
  (c) avoid conflicts on endpoint names between services.
- Some grouping to simplify rules.

Attempted patterns:

- "Get*" gives access to all read-only actions.
- Try to limit the number of "Verb*"'s necessary to give access to all
  non-delete actions.

Generate meaning of the verb in an RBAC action:

- "Get*" Read-only.
- "Create*" Create a new resource.
- "Recreate*" Akin to create in that the content of the instance can be wholely
  lost and replaced, but other metadata remains.
- "Import*" Add content for/to the resource.
- "Export*" Get content from the resource.
- "Operate*" State changes on the resource.
- "Update*" Change metadata (name, tags, etc.) about the resource.
- "Login*" Ability to run processes in the resource. Effectively this only
  makes sense for instances. Hence "ecs:LoginInstance".


| CloudAPI Endpoint         | Docker Endpoint        | RBAC Action                          | Commands                                   |
| ------------------------- | ---------------------- | ------------------------------------ | ------------------------------------------ |
| **IMAGES**                |                        |                                      |                                            |
| ListImages                | ImageList              | ecs:GetImage                         | `triton images`, `docker images`           |
| GetImage                  | ImageInspect           | ecs:GetImage                         | `triton image IMG`, `docker inspect`       |
| -                         | ImageSearch            | ecs:GetImage                         | `docker search`                            |
| -                         | ImageHistory           | ecs:GetImage                         | `docker history`                           |
| -                         | Auth                   | ecs:ImportImage                      | `docker login`                             |
| -                         | ImageCreate            | ecs:ImportImage                      | `docker pull`                              |
| -                         | ImageLoad (NYI)        | ecs:ImportImage                      | `docker load`                              |
| -                         | ImageImport (NYI)      | ecs:ImportImage                      | `docker import`                            |
| -                         | ImagePush              | ecs:ExportImage                      | `docker push`                              |
| ExportImage               | ImageGet               | ecs:ExportImage                      | `triton image --export ...`, `docker save` |
| -                         | ImageTag               | ecs:CreateImage [^1]                 | `docker tag`                               |
| CreateImageFromMachine    | Commit                 | ecs:CreateImage                      | `triton image-create`, `docker commit`     |
| -                         | Build                  | ecs:CreateImage                      | `docker build`                             |
| UpdateImage               | -                      | ecs:UpdateImage                      | `triton image -e IMG`                      |
| DeleteImage               | ImageDelete            | ecs:DeleteImage                      | `triton image -d IMG`, `docker rmi`        |
| **PACKAGES**              |                        |                                      |                                            |
| ListPackages              | -                      | ecs:GetPackage                       | `triton packages`                          |
| GetPackage                | -                      | ecs:GetPackage                       | `triton package PKG`                       |
| **MACHINES**              |                        |                                      |                                            |
| CreateMachine             | ContainerCreate        | ecs:CreateInstance                   | `triton create`, `docker run`              |
| StartMachineFromSnapshot  | -                      | ecs:RecreateInstance                 | `triton start --snapshot=SNAPSHOT`         |
| ReprovisionMachine (NYI)  | -                      | ecs:RecreateInstance                 |                                            |
| ListMachines              | ContainerList          | ecs:GetInstance                      | `triton instances`, `docker ps`            |
| GetMachine                | ContainerInspect       | ecs:GetInstance                      | `triton instance INST`, `docker inspect`   |
| -                         | ContainerTop           | ecs:GetInstance                      | `docker ps`                                |
| -                         | ContainerLogs          | ecs:GetInstance                      | `docker logs`                              |
| -                         | ContainerStats         | ecs:GetInstance                      | `docker stats`                             |
| -                         | ContainerWait          | ecs:GetInstance                      | `docker wait`, `triton wait` (sort of)     |
| ListMachineSnapshots      | -                      | ecs:GetInstance                      | `triton snapshots INST`                    |
| ListMachineMetadata       | -                      | ecs:GetInstance                      | `triton metadata INST`                     |
| GetMachineMetadata        | -                      | ecs:GetInstance                      | `triton metadata INST KEY`                 |
| ListMachineTags           | -                      | ecs:GetInstance                      | `triton tags INST`                         |
| GetMachineTag             | -                      | ecs:GetInstance                      | `triton tag INST KEY`                      |
| MachineAudit              | -                      | ecs:AuditInstance                    | `triton [instance-]audit`                  |
| - (~MachineAudit)         | Events (NYI)           | ecs:AuditInstance                    | `docker events`                            |
| -                         | ContainerExport (NYI)  | ecs:ExportInstance                   | `docker export`                            |
| -                         | ContainerChanges (NYI) | ecs:ExportInstance                   | `docker diff`                              |
| -                         | ContainerCopy          | ecs:ExportInstance                   | older `docker cp`                          |
| -                         | ContainerStatArchive   | ecs:ExportInstance                   | `docker cp`                                |
| -                         | ContainerReadArchive   | ecs:ExportInstance                   | `docker cp`                                |
| -                         | ContainerWriteArchive  | ecs:ImportInstance                   | `docker cp`                                |
| StopMachine               | ContainerStop          | ecs:OperateInstance                  | `triton stop`, `docker stop`               |
| StartMachine              | ContainerStart         | ecs:OperateInstance                  | `triton start`, `docker start`             |
| RebootMachine             | ContainterRestart      | ecs:OperateInstance                  | `triton reboot`, `docker restart`          |
| -                         | ContainerPause (NYI)   | ecs:OperateInstance                  | `container pause`                          |
| -                         | ContainerUnpause (NYI) | ecs:OperateInstance                  | `container unpause`                        |
| EnableMachineFirewall     | -                      | ecs:UpdateInstance                   | `triton inst --enable-firewall INST`       |
| DisableMachineFirewall    | -                      | ecs:UpdateInstance                   | `triton inst --disable-firewall INST`      |
| ResizeMachine             | -                      | ecs:UpdateInstance                   | `triton resize`                            |
| RenameMachine             | ContainerRename        | ecs:UpdateInstance                   | `triton inst -e INST`, `docker rename`     |
| UpdateMachineMetadata     | -                      | ecs:UpdateInstance                   | `triton metadata -a [-f] INST ...`         |
| DeleteMachineMetadata     | -                      | ecs:UpdateInstance                   | `triton metadata INST KEY -d`              |
| DeleteAllMachineMetadata  | -                      | ecs:UpdateInstance                   | `triton metadata INST -da`                 |
| AddMachineTags            | -                      | ecs:UpdateInstance                   | `triton tag -a INST/IMG KEY=VALUE`         |
| ReplaceMachineTags        | -                      | ecs:UpdateInstance                   | `triton tag -af INST/IMG KEY=VALUE [...]`  |
| DeleteMachineTag          | -                      | ecs:UpdateInstance                   | `triton tag -d INST KEY`                   |
| DeleteMachineTags         | -                      | ecs:UpdateInstance                   | `triton tags -d INST KEY`                  |
| -                         | LinkDelete             | ecs:UpdateInstance                   | `docker rm -l ...`                         |
| GetMachineSnapshot        | -                      | ecs:GetInstanceSnapshot              | `triton snapshot INST SNAP`                |
| CreateMachineSnapshot     | -                      | ecs:CreateInstanceSnapshot           | `triton snapshot -c INST SNAP`             |
| DeleteMachineSnapshot     | -                      | ecs:DeleteInstanceSnapshot           | `triton snapshot -d INST SNAP`             |
| DeleteMachine             | -                      | ecs:DeleteInstance                   | `triton rm INST`                           |
| -                         | ContainerAttach        | ecs:LoginInstance                    | `docker attach`                            |
| -                         | ContainerResize        | ecs:LoginInstance [^2]               | -                                          |
| -                         | ContainerExec          | ecs:LoginInstance                    | `docker exec`                              |
| -                         | ExecStart              | ecs:LoginInstance                    | `docker exec`                              |
| -                         | ExecResize             | ecs:LoginInstance                    | `docker exec`                              |
| -                         | ExecInspect            | ecs:LoginInstance                    | `docker exec`                              |
| --------------------      |                        |                                      | --------------                             |
| **NETWORKS**              |                        |                                      |                                            |
| ListNetworks              | docker network?        | ecs:GetNetwork                       | `triton networks`                          |
| GetNetwork                | docker network?        | ecs:GetNetwork                       | `triton network NET`                       |
| **NICS**                  |                        |                                      |                                            |
| ListNics                  | -                      | ecs:GetNic                           | `triton nics`                              |
| GetNic                    | -                      | ecs:GetNic                           | `triton nic NIC`                           |
| AddNic                    | -                      | ecs:CreateNic                        | `triton nic -a ...`                        |
| RemoveNic                 | -                      | ecs:DeleteNic                        | `triton nic -d NIC`                        |
| **FIREWALL RULES**        |                        |                                      |                                            |
| ListFirewallRules         | -                      | ecs:GetFirewallRule                  |                                            |
| GetFirewallRule           | -                      | ecs:GetFirewallRule                  |                                            |
| CreateFirewallRule        | -                      | ecs:CreateFirewallRule               |                                            |
| UpdateFirewallRule        | -                      | ecs:UpdateFirewallRule               |                                            |
| EnableFirewallRule        | -                      | ecs:UpdateFirewallRule               |                                            |
| DisableFirewallRule       | -                      | ecs:UpdateFirewallRule               |                                            |
| DeleteFirewallRule        | -                      | ecs:DeleteFirewallRule               |                                            |
| ListMachineFirewallRules  | -                      | ecs:GetFirewallRule, ecs:GetInstance |                                            |
| ListFirewallRuleMachines  | -                      | ecs:GetFirewallRule, ecs:GetInstance | (Note: undocumented endpoint) |
| **FABRICS**               |                        |                                      |                                            |
| ListFabricVLANs           | -                      | ecs:GetFabricVLAN                    |                                            |
| GetFabricVLAN             | -                      | ecs:GetFabricVLAN                    |                                            |
| CreateFabricVLAN          | -                      | ecs:CreateFabricVLAN                 |                                            |
| UpdateFabricVLAN          | -                      | ecs:UpdateFabricVLAN                 |                                            |
| DeleteFabricVLAN          | -                      | ecs:DeleteFabricVLAN                 |                                            |
| ListFabricNetworks        | -                      | ecs:GetFabricNetwork                 |                                            |
| GetFabricNetwork          | -                      | ecs:GetFabricNetwork                 |                                            |
| CreateFabricNetwork       | -                      | ecs:CreateFabricNetwork              |                                            |
| DeleteFabricNetwork       | -                      | ecs:DeleteFabricNetwork              |                                            |
| -------------             |                        |                                      | --------------                             |
| **ACCOUNT**               |                        |                                      |                                            |
| GetAccount                | -                      | ecs:GetAccount                       | `triton account`                           |
| UpdateAccount             | -                      | ecs:UpdateAccount                    | `triton account -e [FIELD=VALUE ...]`      |
| **KEYS**                  |                        |                                      |                                            |
| ListKeys                  | -                      | ecs:GetKey                           | `triton keys`                              |
| GetKey                    | -                      | ecs:GetKey                           | `triton key KEY`                           |
| CreateKey                 | -                      | ecs:CreateKey                        | `triton key -a`                            |
| DeleteKey                 | -                      | ecs:DeleteKey                        | `triton key -d`                            |
| **CONFIG**                |                        |                                      |                                            |
| GetConfig                 | -                      | ecs:GetAccountConfig                 | `triton account-config`                    |
| UpdateConfig              | -                      | ecs:UpdateAccountConfig              | `triton account-config -e ...`             |
| **DATACENTERS**           |                        |                                      |                                            |
| ListDatacenters           | -                      | ecs:GetDatacenter                    | `triton datacenters`                       |
| GetDatacenter             | -                      | ecs:GetDatacenter                    | `triton datacenter DC`                     |
| **SERVICES**              |                        |                                      |                                            |
| ListServices              | -                      | ecs:GetService                       | `triton services`                          |
| --------------            |                        |                                      | --------------                             |
| **ANALYTICS**             |                        |                                      |                                            |
| DescribeAnalytics         | -                      | ecs:GetAnalytics                     |                                            |
| ListInstrumentations      | -                      | ecs:GetInstrumentation               |                                            |
| GetInstrumentation        | -                      | ecs:GetInstrumentation               |                                            |
| GetInstrumentationValue   | -                      | ecs:GetInstrumentation               |                                            |
| GetInstrumentationHeatmap | -                      | ecs:GetInstrumentation               |                                            |
| *HeatmapDetails           | -                      | ecs:GetInstrumentation               |                                            |
| CreateInstrumentation     | -                      | ecs:CreateInstrumentation            |                                            |
| DeleteInstrumentation     | -                      | ecs:DeleteInstrumentation            |                                            |
| --------------            |                        |                                      | --------------                             |
| **OTHER**                 |                        |                                      |                                            |
| Ping                      | Ping                   | N/A                                  | -                                          |
| -                         | CA                     | N/A                                  | -                                          |
| -                         | Info                   | [^3]                     | `docker info`                              |
| -                         | Version                | N/A                                  | `docker version`                           |
| -----------------         |                        |                                      | --------------                             |
| **RBAC**                  |                        |                                      |                                            |
| ListUsers                 |                        | rbac:GetUser                         | `triton rbac users`                        |
| GetUser                   |                        | rbac:GetUser                         | `triton rbac user USER`                    |
| CreateUser                |                        | rbac:CreateUser                      | `triton rbac user -a ...`                  |
| UpdateUser                |                        | rbac:UpdateUser                      | `triton rbac user -e USER ...`             |
| ChangeUserPassword        |                        | rbac:UpdateUserPassword              | `triton rbac passwd USER`                  |
| DeleteUser                |                        | rbac:DeleteUser                      | `triton rbac user -d USER`                 |
| ListRoles                 |                        | rbac:GetRole                         | `triton rbac roles`                        |
| GetRole                   |                        | rbac:GetRole                         | `triton rbac role ROLE`                    |
| CreateRole                |                        | rbac:CreateRole                      | `triton rbac role -a ...`                  |
| UpdateRole                |                        | rbac:UpdateRole                      | `triton rbac role -e ROLE ...`             |
| DeleteRole                |                        | rbac:DeleteRole                      | `triton rbac role -d ROLE`                 |
| SetRoleTags               |                        | rbac:UpdateRoleTags                  | `triton rbac *-role-tags ...`              |
| ListPolicies              |                        | rbac:GetPolicy                       | `triton rbac policies`                     |
| GetPolicy                 |                        | rbac:GetPolicy                       | `triton rbac policy POLICY`                |
| CreatePolicy              |                        | rbac:CreatePolicy                    | `triton rbac policy POLICY`                |
| UpdatePolicy              |                        | rbac:UpdatePolicy                    | `triton rbac policy -e POLICY`             |
| DeletePolicy              |                        | rbac:DeletePolicy                    | `triton rbac policy -d POLICY`             |
| ListUserKeys              |                        | rbac:GetUserKey                      | `triton rbac users`                        |
| GetUserKey                |                        | rbac:GetUserKey                      | `triton rbac user USER`                    |
| CreateUserKey             |                        | rbac:CreateUserKey                   | `triton rbac user -e USER`                 |
| DeleteUserKey             |                        | rbac:DeleteUserKey                   | `triton rbac user -d USER`                 |


Notes:

1. `docker tag`: `docker tag` feels like less of capability than UpdateImage.
   I'm okay with Bob tagging my image so he can use it with `docker run`. But
   I'm less okay with Bob having the CloudAPI ability to change the name of my
   image (also "UpdateImage" RBAC action). Is ecs:DockerTagImage too granular?
   `docer tag` is kinda like CopyImage. *kind* of. Which is kinda like
   CreateImage. I lean to CreateImage here. If we need to separate that so that
   an op can grant `docker tag` but NOT `docker build`, then we can use a
   separate name. However, *most* commonly I (naively) assert that tagging is
   used mostly for `docker pull` and `docker build`. Hrm... so that's
   "ImportImage". Or we make sure that 'docker pull' works on the tagging with
   `ImportImage`. So ignore that. Options:

        UpdateImage (angela's)
        CreateImage (i.e. same as `docker build`)
        something else: UpdateImageDockerTag, DockerTagImage, CopyImage

2. ContainerResize:
   <http://docs.docker.com/engine/reference/api/docker_remote_api_v1.21/#resize-a-container-tty>
   Not sure if this is needed for `docker run`. If so then I hesitate to have
   this be a separate "ecs:OperateInstance".
   Q: what `docker` actions result in ContainerResize?

   joshw suggested same as "ContainerAttach"
   Currently have "ecs:LoginInstance"... the verb doesn't feel right. Ideas:
        ecs:LoginInstance
        ecs:LoginToInstance (would like to avoid two-word verb)
        ecs:ExecOnInstance
        ecs:ExecInstance
        ecs:ConsoleInstance

   Weird example is that `docker-compose logs` will issue ContainerResize
   even though it doesn't need to, IIUC. It might be undesirable (and certainly
   surprising) to have `docker-compose logs` fail unless one has 'ecs:LoginInstance'.
   IOW, perhaps "ecs:LoginInstance" is overkill for ContainerResize. Make it
   a separate special case? Does it actually *change* the container at all?
   If not perhaps an innocuous "Get"?

3. Info. `docker info` includes a count of images and containers. Might want to
   consider filtering those on GetInstance/GetImage and those which are accessible,
   but that seems unnecessarily expensive. If possible, just elide those values
   for RBAC-y access.
