---
authors: Angela Fong <angela.fong@joyent.com>
state: draft
---

# RFD 13 Docker Subuser Support

## Background on SDC and Manta RBAC

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
8. Every time a CloudAPI or Manta call is issued, the caller (subuser) and the
   account logins are passed to mahi to get the roles and policies associated with
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

Like CloudAPI and Manta, there are three basic scenarios that need to be
supported in Docker's RBAC model, listed in the order of importance:

1. Tenancy separation - Users within an account can manage resources belong
   to the roles of which they are members and have no access to resources
   outside of those roles.
2. Access level - Users can be granted different levels of access to the
   same resources. E.g. some can read/write a certain resource while others
   may have read-only access.
3. Combination of 1 and 2, i.e. each user in an account may have different
   access permissions to different resources.

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
   apply the corresponding role to the operation. The current RBAC mechanism
   that automatically tags newly created resources to the roles passed to
   the create operation will be required for Docker containers as well. 
6. Instance-level access control to pulled-down docker image layers is not
   necessary. Uncommitted 'head images' (created via `docker build` or `docker tag`)
   are the ones that warrant RBAC.
7. For users who are accessing as account owners, it should be clear to them
   that when they run the setup script, they can ignore the prompts for
   subuser and role. For those who have already done the setup and are
   using docker currently, ideally they don't have to rerun setup or configure
   any role/policy/role-tag for themselves.


## Docker Policy Actions

### Some Sample Roles

In attmepting to collapse the API endpoint permissions into higher-level policy
actions, it will be helpful to have a few sample roles, or principals, in mind
based on what they need to achieve.

| Role | Description                                                 |
| ---- | ----------------------------------------------------------- |
| Dev  | Developers who define and build containers                  |
| Ops  | Operators who deploy and manage container operations        |
| User | End users who access containers to run/use the applications |
| APM  | Application performance monitoring system agents            |

### Fine-grained Permissions

Starting from the ground up, for each of the sample roles above, the need for access
to the docker API endpoints will probably look like this:
							
| Method | Docker Endpoint          | Docker Route     | Notes                             | Dev | Ops | User | APM |
| ------ | ------------------------ | ---------------- | --------------------------------- | --- | --- | ---- | --- |
| POST   | /containers/create       | ContainerCreate  |                                   | X   | X   |      |     |
| GET    | /containers              | ContainerList    |                                   | X   | X   | X    | X   |
| GET    | /containers/(id)         | ContainerInspect |                                   | X   | X   | X    | X   |
| GET    | /containers/(id)/logs    | ContainerLogs    |                                   | X   | X   | X    | X   |
| GET    | /containers/(id)/top     | ContainerTop     |                                   | X   | X   | X    | X   |
| GET    | /containers/(id)/changes | ContainerChanges | file system changes               | X   | X   | X    | X   |
| GET    | /containers/(id)/stat    | ContainerStats   |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/resize  | ContainerResize  | tty resize                        | X   | X   | X    |     |
| POST   | /containers/(id)/start   | ContainerStart   |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/stop    | ContainerStop    |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/restart | ContainerRestart |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/kill    | ContainerKill    |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/pause   | ContainerPause   |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/unpause | ContainerUnpause |                                   | X   | X   | X    | X   |
| POST   | /containers/(id)/attach  | ContainerAttach  |                                   | X   | X   | X    |     |
| POST   | /containers/(id)/wait    | ContainerWait    |                                   | X   | X   | X    |     |
| POST   | /containers/(id)/rename  | ContainerRename  |                                   | X   | X   |      |     |
| DELETE | /containers/(id)         | ContainerDelete  |                                   | X   | X   |      |     |
| POST   | /containers/(id)/copy    | ContainerCopy    | copy files from container         | X   | X   | X    |     |
| GET    | /containers/(id)/export  | ContainerExport  | export container                  | X   | X   | X    |     |
| GET    | /containers/(id)/archive | ContainerArchive | create archive from container fs  | X   | X   | X    |     |
| HEAD   | /containers/(id)/archive | ContainerArchive | file system info                  | X   | X   | X    |     |
| PUT    | /containers/(id)/archive | ContainerArchive | extract archive into fs           | X   | X   | X    |     |
| POST   | /containers/(id)/exec    | ContainerExec    | create exec instance in container | X   | X   | X    |     |
| POST   | /exec/(exec_id)/start    | ExecStart        |                                   | X   | X   | X    |     |
| POST   | /exec/(exec_id)/resize   | ExecResize       | tty resize                        | X   | X   | X    |     |
| POST   | /exec/(exec_id)/inspect  | ExecInspect      |                                   | X   | X   | X    |     |
| GET    | /images                  | ImageList        |                                   | X   | X   |      |     |
| GET    | /images/(name)           | ImageInspect     |                                   | X   | X   |      |     |
| GET    | /images/(name)/history   | ImageHistory     |                                   | X   | X   |      |     |
| GET    | /images/search           | ImageSearch      |                                   | X   | X   |      |     |
| GET    | /images/(name)/get       | ImageGet         | extract images into tarball       | X   | X   |      |     |
| GET    | /images/get              | ImageGet         | extract all images                | X   | X   |      |     |
| POST   | /images/create           | ImageCreate      | import from registry              | X   |     |      |     |
| POST   | /images/load             | ImageLoad        | load image tarball                | X   |     |      |     |
| POST   | /images/(name)/tag       | ImageTag         |                                   | X   |     |      |     |
| POST   | /images/(name)/push      | ImagePush        | push to registry                  | X   |     |      |     |
| DELETE | /images/(name)           | ImageDelete      |                                   | X   |     |      |     |
| POST   | /commit?container=(id)   | Commit           |                                   | X   |     |      |     |
| POST   | /build                   | Build            |                                   | X   |     |      |     |
| GET    | /_ping                   | Ping             |                                   | X   | X   | X    | X   |
| POST   | /auth                    | Auth             | login a registry                  | X   | X   | X    | X   |
| GET    | /info                    | Info             |                                   | X   | X   | X    | X   |
| GET    | /version                 | Version          |                                   | X   | X   | X    | X   |
| GET    | /events                  | Events           |                                   | X   | X   | X    | X   |

### Policy Action mapping

We can derive some patterns from the above list of fine-grained permissions, while
keeping in mind what the access allows the user to do to the resource.

GET access for a resource can be as trivial as getting its non-confidential metadata,
or as in depth as retrieving the operational data (logs, audit trails, processes),
or even the entire content of the resource in the form of an export file. It will be
appropriate to treat these permissions differently.

Likewise, PUT and POST access for a resource can range from changing its state (e.g.
the power state of a container), to its metadata (e.g. name, labels), to its content
(through file copy or executing commands in the container). These different types
of update actions warrant separate access permissions.

As far as the policy action naming is concerned, there are some advantages in
adopting the {service}:{policyAction} convention to provide more clarity on what
policy actions correspond to which services. For Docker and CloudAPI, they can be
in the same service category and with policy actions named tentatively to something
like `ecs:GetInstance` (ecs = Elastic Container Services). Manta policy actions can
likewise be renamed accordingly, e.g. `manta:PutObject`.

| Policy Action                | Dev | Ops | User | APM | Docker Route                                          | Method | Docker Endpoint                                               | CloudAPI Equiv                           |
| ---------------------------- | --- | --- | ---- | --- | ----------------------------------------------------- | ------ | ------------------------------------------------------------- | ---------------------------------------- |
| ecs:GetImage                 | X   | X   |      |     | ImageList, ImageInspect, ImageHistory, ImageSearch    | GET    | /images/*                                                     | getimage, listimages                     |
| ecs:ImportImage (TM)         | X   | X   |      |     | ImageCreate                                           | POST   | /images ???                                                   |                                          |
| ecs:ExportImage              | X   |     |      |     | ImageGet, ImagePush                                   | POST   | /images                                                       |                                          |
| ecs:UpdateImage (TM)         | X   |     |      |     | ImageTag                                              | POST   | /images                                                       |                                          |
| ecs:CreateImage              | X   |     |      |     | CreateImage, LoadImage                                | POST   | /images                                                       |                                          |
| ecs:DeleteImage              | X   |     |      |     | DeleteImage                                           | DELETE | /images                                                       | deleteimage                              |
| ecs:CreateImage              | X   |     |      |     | Commit                                                | POST   | /commit                                                       | createimagefrommachine                   |
| ecs:CreateImage              | X   |     |      |     | Build                                                 | POST   | /build                                                        |                                          |
| ecs:GetInstance              | X   | X   | X    | X   | Container{List,Inspect,Top,Logs,Stats}                | GET    | /containers/* (except export,archive,changes)                 | getmachine, listmachines                 |
| ecs:ExportInstance           | X   | X   | X    |     | Container{Export,Archive,Changes}                     | GET    | /containers/(id)/{export,archive,changes}                     |                                          |
| ecs:ExportInstance           | X   | X   | X    |     | ContainerCopy                                         | POST   | /containers/(id)/copy                                         |                                          |
| ecs:UpdateInstance           | X   | X   | X    |     | ContainerArchive                                      | HEAD   | /containers                                                   |                                          |
| ecs:UpdateInstance           | X   | X   | X    |     | ContainerArchive                                      | PUT    | /containers                                                   |                                          |
| ecs:UpdateInstance           | X   | X   | X    |     | Container{Rename}                                     | POST   | /containers/(id)/{rename}                                     | renamemachine                            |
| ecs:LoginInstance (TM)       | X   | X   | X    |     | Container{Attach,Exec,Resize}                         | POST   | /containers/(id)/{attach,exec,resize}                         |                                          |
| ecs:LoginInstance (TM)       | X   | X   | X    |     | Exec{Start,Resize,Inspect}                            | POST   | /exec/(id)/{start,resize,inspect}                             |                                          |
| ecs:CreateInstance           | X   | X   |      |     | ContainerCreate                                       | POST   | /containers/create                                            | createmachine                            |
| ecs:OperateInstance (TM)     | X   | X   | X    | X   | Container{Start,Stop,Restart,Kill,Wait,Pause,Unpause} | POST   | /containers/(id)/{start,stop,restart,kill,wait,pause,unpause} | startmachine, stopmachine, rebootmachine |
| ecs:DeleteInstance           | X   | X   |      |     | ContainerDelete                                       | DELETE | /containers                                                   | deletemachine                            |
| N/A - accessible to all      | X   | X   | X    | X   | Ping                                                  | GET    | /_ping                                                        |                                          |
| ecs:GetImage                 | X   | X   | X    | X   | Auth                                                  | POST   | /auth                                                         |                                          |
| N/A - accessible to all      | X   | X   | X    | X   | Info                                                  | GET    | /info                                                         |                                          |
| N/A - accessible to all      | X   | X   | X    | X   | Version                                               | GET    | /version                                                      |                                          |
| ecs:AuditInstance            | X   | X   | X    | X   | Events                                                | GET    | /events                                                       | machineaudit                             |

See [full table of RBAC actions here](./rbac-actions.md).

Trent Notes: (askfongjojo: responded, we can remove this section in next rev)
- "ecs:*Container": I changed to "Instance". [a: updated, *Instance now]
- ImageCreate: you'd missed this one [a: agreed]
- ImageTag: I changed to "ecs:CreateImage" [a: agreed]
- ContainerChanges (aka `docker diff`) is closer to ContainerExport `docker export`
  and/or ContainerArchive (`docker cp`) [a: agreed, moved to Export]
- ContainerResize as "UpdateContainer"? Hrm.  Resize is called for `docker attach`
  and as part of `docker start -i` and `docker run`.i [a: true, hence grouped
  with attach, changed to Login* now per rbac-actions table]
- Proposing moving "ContainerWait" to "ecs:GetInstance"... because it is just
  about getting the current state of the container and waiting until it is
  stopped. [a: true, but it's normally used with power cycle; fine either way
  though]
- Info: Perhaps elide the image and container counts for non-account access.
  [a: yes if time, not too concerned since these are just counts]

## Open Questions

### List all instances being a separate policy action/attribute?

To grant the permission to see all instances of a certain resource type for a
particular role, there are a few ways to achieve it:

1. The role concerned should be tagged to every single instance of the resource, and
   is attached to the Get{Resource} policy action.
2. There is a separate policy action List{Resource} that grant the access permission
   to all instances of that resource.
3. Have a separate "scope" attribute as part of the policy definition. Scope can be
   set to "all instances" or "role-tagged instances".

CloudAPI currently supports #2 but it is confusing to user since the `List` permission
applies to the `Get` action only. If a role has `ListMachines` and `StartMachine`
permissions, it still won't allow users with that role to perform `StartMachine` on any
of the machines the user sees in `ListMachines`. The only way to enable the user to do
so is to practice role-tagging (#1) as well. Role tagging is taken care of automatically
for newly created resources but the existing resources are the ones often forgotten.
To hide this complexity from user, currently Portal auto role-tags existing resources
resources in the account whenever a List* policy is added to a role (and supposedly
untag them when the policy is dropped). API users have to take care of that manually.

#3 will provide the most flexibility and reduce a lot of the need for role-tagging
when tenancy-separation is not required for the resource. It'll potentially help
performance but it is a major change to the policy data model. If we can implement
this, we can remove the Portal hack which is expensive and unreliable.


### Converge Docker and Cloud API policy actions

- If we decide to pursue the summary policy route, ideally CloudAPI would follow the
  same model. Based on the current usage of RBAC in JPC, many users have resorted
  to granting all policies or the 'administrator' role. The user experience will likely
  improve if we make the policy set cleaner and have sample roles for users to model
  after.

- We still need to reconcile what happens when user has the permission to ListMachines
  in CloudAPI but not the Docker API equivalent (and vice versa). Further decision
  has to be made as part of this project to ensure we do not leave behind two islands
  of permissions which would result in more segregated and confusing behavior.

One way to view this is that even though docker resources are a subset of all the
resources owned by the account, it is unlikely that users want to segregate the
permissions by container/vm type (i.e. some subusers can manage LX/smartos zones,
while others can only docker ones, and so on). The intention for granting
ecs:ListInstances is allowing user to see all instances, regardless of the type.
If we can agree on this premise, we can potentially convert existing CloudAPI and
Manta policies to the new nomenclature. This involves changing the RBAC check in
mahi and grouping the more granular CloudAPI policies into the coarse-grained
ones (Manta ones are already at the right granularity and do not require changes).
Existing customer data will likely have to be migrated with some manual
intervention, or kept unchanged with if we built in backwards compatibility.
Maybe we need another RFD for this when we get to do it.

## Other Considerations

- sdc-docker uses the CN defined in the certificate file passed from the
  Docker clients to identify the account login. As subuser login is not
  globally unique, both account and subuser login may need to be captured
  in the form of a concatenated string like "CN=jill.user/bob.subuser",
  in the same way as subusers enter their login ID in Portal.
- Auditing is not returning correct information for docker containers
  currently because the docker request payload to vmapi is missing the
  "Context" section that is typically present in cloudapi requests:

    ```
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
    ```

  The caller info for docker operations are returned as "operator" in
  [MachineAudit](https://github.com/joyent/sdc-cloudapi/blob/master/lib/audit.js#L74-L81).
  This needs to be fixed as part of the RBAC feature.

- There is already a pre-defined "docker" role and "docker" policy used by
  the KVM Docker features in the Portal. Those features are being deprecated.
  To avoid confusion, we'll need to clean up those roles/policies in accounts
  which have previously made use of KVM Docker.
