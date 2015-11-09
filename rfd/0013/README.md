---
authors: Angela Fong <angela.fong@joyent.com>
state: draft
---

# RFD 13 Docker Subuser Support

## Background

Skip this section if you are already familiar with CloudAPI or Manta RBAC. There are
some rather detailed end-user docs (https://docs.joyent.com/public-cloud/rbac)
if you want to pursue further on the feature details.

There are some key characteristics of the current RBAC model that are
important to highlight here for the discussion on Docker subuser support:

1. Each account owner may create one or more subusers (Note on terminology:
   for Manta, account owners and subusers are designated by MANTA_USER and
   MANTA_SUBUSER; for CloudAPI, they are designated by SDC_ACCOUNT and SDC_USER).
2. Subusers authenticate with their own SSH keys. The subuser login is unique
   within each account but is **not** globally unique.
3. Each subuser can be assigned one or more roles that enable the subuser's
   access to account's resources.
4. There are two dimensions to the access permissions of a role:
   - Policies: Policies define the actions allowed (e.g. listmachines,
     createmachine). Each role has one or more policies attached.
   - Role tags: Tags control which **instances** of the account's resources
     (e.g. machines, images, users) are allowed for the role.

   The two sets of capabilities together control what a subuser can act on.
   When creating a new resource (e.g. machine), the role tags are automatically
   added to the instance based on which role(s) are passed in the create
   command (no --role arg means "tag all of my roles").
6. There is also a hardcoded 'administrator' role that acts as a super-user
   role, granting full access to everything the account owns.
7. Account owner is free to define roles, policies and tag their resources to
   achieve granular RBAC. There is no out-of-the-box role but the Portal has a few
   canned roles that are inserted to user's profile behind the scenes for the
   KVM docker host and registry feature.
8. Every time a CloudAPI call is issued, the caller (subuser) and the account
   logins are passed to mahi to get the roles and policies associated with
   the caller. If the API endpoint is not authorized in any of the subuser's
   role policies or the resource involved is tagged to a role that the subuser
   doesn't have, an "NotAuthorized" error is returned to the caller.
9. Once a subuser has passed authentication and authorization, the caller invokes
   the operation **on behalf of the account owner**. From the perspective of the
   backend API (e.g. vmapi), it sees only the account owner's uuid. All owner_uuid
   references point to the account owner. The subuser's identity is tracked
   in jobs but not persisted in the resource's moray bucket. `MachineAudit`
   CloudAPI does include the subuser's information.


## Current State of Docker Subuser Access

The setup script for sdc-docker currently does not support the use of subuser
login. Authentication works with sdc accounts only. The *workaround* at
this time is for the account owner to add the public keys of subusers to his
account. The side effect of doing so is giving the subusers full access to
all other resources in the account, including users and keys (essentially
making the subuser a delegated admin). This is obviously undesirable.


## Proposed Scope for Docker RBAC

For Docker API, we can potentially follow the same RBAC model as CloudAPI.
At this time, there are only two types of resources managed in docker -
containers and images. There may be additional ones such as volumes and
networks going forward.

There are a few wrinkles however:
- We are bound by the Docker clients in terms of what can be passed as
  arguments. For containers, we have the option of leveraging `--label`
  to pass the role information. But such flexibility is absent for other
  resource types.
- A single command from Docker clients (CLI, Compose) can result in
  multiple remote API calls. Users are not necessarily aware of the
  actual API endpoints involved. It will be difficult for them to grant
  the right set of permissions to cover one client action.
- Docker remote API and client capabilities are still growing/changing rapidly.
  It'll be a burden for us (or users or both) to keep up.
- Docker operations overlap with many of the CloudAPI actions. Having
  separate policy actions such as `listmachines` vs `getcontainers` is going
  to create a perfect storm for confusion. Having docker users learn to
  use our CloudAPI semantics is unlikely to be acceptable either.
- Docker image layers are owned by admin. There is already some form of
  image tagging to account owners. Adding another layer of tagging can
  get complicated.
- Maintaining instance-level permissions will have a negative impact
  on performance.

Taking the above into consideration, here is the minimum set of requirements
for Docker RBAC:

1. Subusers can access sdc-docker and authenticate with their own SSH keys.
2. Subusers can act on behalf of the account owner to invoke docker remote
   API call. The granularity of which does not have to mimic the current
   cloudapi's endpoint-level permissions. From a usage perspective, some of
   the actions are highly associated with each other and are better granted
   as a group (e.g. start/stop/kill/pause/unpause/wait). Granting access at
   this level will simplify the RBAC setup.
3. Optionally, a set of recommended roles, provided in the form of documentation
   or scripts that user can execute as part of docker setup may be useful.
   Examples of such roles are 'developers', 'operators', 'users' and 'agents'
   (monitoring applications).
4. Subusers will not be able to perform any CloudAPI or Manta API actions unless
   they have been explicitly granted the permissions to do so.
5. Subusers will have a way to segregate their container instance permissions
   by role. One way to support this (coming out of some earlier discussions with
   Trent) is to prompt for a role name during docker setup. Subusers who have
   multiple roles can have multiple profiles, each of them will have a separate
   certificate file. Based on the DOCKER_CERT_PATH specified, sdc-docker will
   apply the corresponding role to the operation.
6. Instance-level access control to pulled down docker image layers is not
   necessary. Uncommitted 'head images' (created via `docker build` or `docker tag`)
   are the ones that warrant RBAC.
7. For users who are accessing as account owners, it should be clear to them
   that when they run the setup script, they can ignore the prompts for
   subuser and role. For those who have already done the setup and are
   using docker currently, ideally they don't have to rerun setup or configure
   any role/policy/role-tag for themselves.


## Some Sample Roles

Here are a few sample roles that are typically used to help us to group policy
actions in a meaningful way:

| Role | Description |
| ---- | ----------- |
| Dev | Developers who define and build containers |
| Ops | Operators who deploy and manage container operations |
| User | End users who access containers to run/use the applications |
| APM | Application performance monitoring system agents |

## Fine-grained Permissions							
| Method | Docker Endpoint | Docker Route | Notes | Dev | Ops | User | APM |
| ------ | --------------- | ------------ | ----- | --- | --- | ---- | --- |
| POST | /containers/create | ContainerCreate | | X | X | | |	
| GET | /containers | ContainerList | | X | X | X | X |
| GET | /containers/(id) | ContainerInspect | | X | X | X | X |
| GET | /containers/(id)/logs | ContainerLogs | | X | X | X | X |
| GET | /containers/(id)/top | ContainerTop | | X | X | X | X |
| GET | /containers/(id)/changes | ContainerChanges | file system changes | X | X | X | X |
| GET | /containers/(id)/stat | ContainerStats | | X | X | X | X |
| POST | /containers/(id)/resize | ContainerResize | tty resize | X | X | X | |
| POST | /containers/(id)/start | ContainerStart | | X | X | X | X |
| POST | /containers/(id)/stop | ContainerStop | | X | X | X | X |
| POST | /containers/(id)/restart | ContainerRestart | | X | X | X | X |
| POST | /containers/(id)/kill | ContainerKill | | X | X | X | X |
| POST | /containers/(id)/pause | ContainerPause | | X | X | X | X |
| POST | /containers/(id)/unpause | ContainerUnpause | | X | X | X | X |
| POST | /containers/(id)/attach | ContainerAttach | | X | X | X | |
| POST | /containers/(id)/wait | ContainerWait | | X | X | X | |
| POST | /containers/(id)/rename | ContainerRename | | X | X | | |
| DELETE | /containers/(id) | ContainerDelete | | X | X | | |		
| POST | /containers/(id)/copy | ContainerCopy | copy files from container | X | X | X | |
| GET | /containers/(id)/export | ContainerExport | export container | X | X | X | |
| GET | /containers/(id)/archive | ContainerArchive | create archive from container fs | X | X | X | |
| HEAD | /containers/(id)/archive | ContainerArchive | file system info | X | X | X | |
| PUT | /containers/(id)/archive | ContainerArchive | extract archive into fs | X | X | X | |
| POST | /containers/(id)/exec | ContainerExec | create exec instance in container | X | X | X | |
| POST | /exec/(exec_id)/start | ExecStart | | X | X | X | |
| POST | /exec/(exec_id)/resize | ExecResize | tty resize | X | X | X | |
| POST | /exec/(exec_id)/inspect | ExecInspect | | X | X | X | |
| GET | /images | ImageList | | X | X | | |	
| GET | /images/(name) | ImageInspect | | X | X | | |	
| GET | /images/(name)/history | ImageHistory | | X | X | | |	
| GET | /images/search | ImageSearch | | X | X | | |
| GET | /images/(name)/get | ImageGet | extract images into tarball | X | X | | |	
| GET | /images/get | ImageGet | extract all images | X | X | | |
| POST | /images/create | ImageCreate | import from registry | X | | | |
| POST | /images/load | ImageLoad | load image tarball | X | | | |
| POST | /images/(name)/tag | ImageTag | | X | | | |
| POST | /images/(name)/push | ImagePush | push to registry | X | | | |
| DELETE | /images/(name) | ImageDelete | | X | | | |
| POST | /commit?container=(id) | Commit | | X | | | |
| POST | /build | Build | | X | | | |
| GET | /_ping | Ping | | X | X | X | X |
| POST | /auth | Auth | | X | X | X | X |
| GET | /info | Info | | X | X | X | X |
| GET | /version | Version | | X | X | X | X |
| GET | /events | Events | | X | X | X | X |
							
## Proposed Policy Action Categories

| Policy Action | Method | Docker Endpoint | Docker Route | CloudAPI Equiv | Dev | Ops | User | APM |
| ------------- | ------ | --------------- | ------------ | -------------- | --- | --- | ---- | --- |
| ecs:GetContainer | GET | /containers/* (except export and archive) | ContainerList, ContainerInspect, ContainerTop, ContainerLogs, ContainerStats, ContainerChanges | getmachine, listmachines | X | X | X | X |
| ecs:ExportContainer | GET | /containers/(id)/export, /containers/(id)/archive | ContainerExport, ContainerArchive | | X | X | X | |	
| ecs:ExportContainer | POST | /containers/(id)/copy | ContainerCopy | | X | X | X | |	
| ecs:UpdateContainer | HEAD | /containers | ContainerArchive | | X | X | X | |
| ecs:UpdateContainer | PUT | /containers | ContainerArchive | | X | X | X | |
| ecs:UpdateContainer | POST | /containers/(id)/rename, /containers/(id)/attach, /containers/(id)/exec, /containers/(id)/resize | ContainerRename, ContainerAttach, ContainerExec, ContainerResize | renamemachine | X | X | X | |	
| ecs:CreateContainer | POST | /containers/create | ContainerCreate | createmachine | X | X | | |	
| ecs:OperateContainer | POST | /containers/(id)/start, /containers/(id)/stop, /containers/(id)/restart, /containers/(id)/kill, /containers/(id)/wait, /containers/(id)/pause, /containers/(id)/unpause | ContainerStart, ContainerStop, ContainerRestart, ContainerKill, ContainerWait, ContainerPause, ContainerUnpause | startmachine, stopmachine,  rebootmachine | X | X | X | X |
| ecs:DeleteContainer | DELETE | /containers | ContainerDelete | deletemachine | X | X | | |
| ecs:GetImage | GET | /images/* | ImageList, ImageInspect, ImageHistory, ImageSearch | getimage, listimages | X | X | | |
| ecs:ExportImage | POST | /images | ImageGet, ImagePush | | X | | | |
| ecs:UpdateImage | POST | /images | ImageTag | | X | | | |
| ecs:CreateImage | POST | /images | CreateImage, LoadImage | | X | | | |
| ecs:DeleteImage | DELETE | /images | DeleteImage | deleteimage | X | | | |	
| ecs:CreateImage | POST | /commit | Commit | createimagefrommachine | X | | | |
| ecs:Createimage | POST | /build | Build | | X | | | |
| N/A - accessible to all | GET | /_ping | Ping | | X | X | X | X |
| N/A - accessible to all | POST | /auth | Auth | | X | X | X | X |
| N/A - accessible to all | GET | /info | Info | | X | X | X | X |
| N/A - accessible to all | GET | /version | Version | | X | X | X | X |
| ecs:AuditContainer | GET | /events | Events | machineaudit | X | X | X | X |


## Open Questions

### List all instances being a separate policy action?

To grant the permission to see all instances of a certain resource for a particular role,
there are two ways to achieve it:

- The role concerned should be tagged to every single instance of the resource, and
  is attached to the Get<Resource> policy action.
or
- There is a separate policy action List<Resource> that grant the Get access permission
  to all instances of that resource.

CloudAPI follows the latter model. It is better for performance but is a slight
deviation from the action vs instance permission model.

### Converge Docker and Cloud API policy actions

- If we decide to pursue the summary policy route, CloudAPI should follow the same
  model. Based on the current usage of RBAC in CloudAPI, many users have resorted to
  granting all policies or the 'administrator' role. The user experience will likely
  improve if we make the policy set cleaner and have sample roles for users to model
  after.

- We still need to reconcile what happens when user has the permission to ListMachines
  in CloudAPI but not the equivalent in Docker API (and vice versa). Further decision
  has to be made as part of this project to ensure we do not leave behind such
  segregated and confusing behavior.


## Other Considerations

- sdc-docker uses the CN defined in the certificate file passed from the
  Docker clients to identify the account login. As subuser login is not
  globally unique, both account and subuser login may need to be captured
  in the form of a concatenated string like "CN=jill.user/bob.subuser",
  in the same way as subusers enter their login ID in Portal.
- Auditing is not returning correct information for docker containers
  currently because the docker request payload to vmapi is missing the
  "Context" section that is typically present in cloudapi requests:
`````
      "context": {
        "caller": {
          "type": "signature",
          "ip": "127.0.0.1",
          "keyId": "/angela.fong/keys/d5:ca:36:85:e7:f0:9a:08:4d:05:81:ad:10:c8:a3:a0"
        },
        "params": {
          "account": "angela.fong",
          "name": "lx-debian2",
          "image": "7c815c22-4606-11e5-8bb5-9f853c19be54",
          "package": "20e583d5-ea48-411d-f0e2-9079352f48f8",
          "dataset": "7c815c22-4606-11e5-8bb5-9f853c19be54"
        }
      },
`````

  The caller info for docker operations are returned as "operator" in
  [MachineAudit](https://github.com/joyent/sdc-cloudapi/blob/master/lib/audit.js#L74-L81).
  This needs to be fixed as part of the RBAC feature.
  
- There is already a pre-defined "docker" role and "docker" policy used by
  the KVM Docker features in the Portal. Those features are being deprecated.
  To avoid confusion, we'll need to clean up those roles/policies in accounts
  which have previously made use of KVM Docker.

