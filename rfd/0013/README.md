---
authors: Angela Fong <angela.fong@joyent.com>
state: draft
---

# RFD 13 Docker Subuser Support

## Background

Skip this section if you are already familiar with SDC or Manta RBAC. There are
some rather detailed end-user docs (https://docs.joyent.com/public-cloud/rbac)
if you want to pursue further.

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
5. Account owner is free to define roles, policies and tag their resources to
   achieve granular RBAC. There is no out-of-the-box role but the Portal has a few
   canned roles that are inserted to user's profile behind the scenes for the
   KVM docker host and registry feature.
6. Every time a CloudAPI call is issued, the caller (subuser) and the account
   logins are passed to mahi to get the roles and policies associated with
   the caller. If the type of action is not covered by any of the subuser's
   role policies or the resource involved is tagged to a role that the subuser
   doesn't have, an "NotAuthorized" error is returned to the caller.
7. Once a subuser has passed authentication and authorization, the caller invokes
   the operation **on behalf of the account owner**. From the perspective of the
   backend API (e.g. vmapi), it sees only the account owner's uuid. All owner_uuid
   references point to the account owner. The subuser's identity is tracked
   in jobs but not persisted in the resource's moray bucket. `MachineAudit`
   CloudAPI does include the subuser's information.


## Current State of Docker Subuser Access

Docker API doesn't allow subusers of an account to use sdc-docker API. The
authentication is set up to work with sdc accounts only. The *workaround* at
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
- Docker actions will grow/change over time. It'll be a burden for us
  (or users or both) to keep up.
- Docker operations overlap with many of the CloudAPI actions. Having
  separate policy actions such as `listmachines` vs `docker-ps` is going
  to create a perfect storm for confusion. Having docker users learn to
  use our CloudAPI semantics is unlikely to be acceptable either.
- Docker image layers are owned by admin. There is already some form of
  image tagging to account owners. Adding another layer of tagging can
  get complicated.
- Maintaining instance-level permissions will have a negative impact
  on performance.

Taking the above into consideration, here is the minimum set of requirements
I am proposing for Docker RBAC:

1. Subusers can access sdc-docker and authenticate with their own SSH keys.
2. Subusers can act on behalf of the account owner to invoke **any docker remote
   API call**. In other words, there is only one blanket policy action for docker.
   This can be a canned policy attached to a canned role, pre-created behind
   the scenes in each account, and assigned to the subusers automatically
   when they run `sdc-docker-setup.sh`.
3. Subusers will not be able to perform any CloudAPI or Manta API actions unless
   they have been explicitly granted the permissions to do so.
4. Subusers will have a way to segregate their container instance permissions
   by role. One way to support this (coming out of some earlier discussions with
   Trent) is to prompt for a role name during docker setup. Subusers who have
   multiple roles can have multiple profiles, each of them will have a separate
   certificate file. Based on the DOCKER_CERT_PATH specified, sdc-docker will
   apply the corresponding role to the operation.
5. Instance-level access control to pulled down docker image layers is not
   necessary. Uncommitted 'head images' (created via `docker build` or `docker tag`)
   are the ones that warrant RBAC.
6. For users who are accessing as account owners, it should be clear to them
   that when they run the setup script, they can ignore the prompts for
   subuser and role. For those who have already done the setup and are
   using docker currently, ideally they don't have to rerun setup or configure
   any role/policy/role-tag for themselves.


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
- Creating the new canned "docker" role and policy for each new account and
  backfilling them for existing accounts may not be trivial work. Also for the
  setup script to see and act on the user/role/policy objects, the account owners
  will need to grant those permissions in the first place. Maybe we can have
  the canned role/policy setup scripted separately for account owners who
  wish to use RBAC. It is just an one-time setup per account. `sdc-docker-setup.sh`
  will validate this pre-requisite when configuring subusers.

