---
authors: Angela Fong <angela.fong@joyent.com>, Trent Mick <trent.mick@joyent.com>
state: draft
---

# RFD 13 RBAC v2 for Improved Organization and Docker RBAC Support

- [Introduction](#introduction)
- [Terminology](#terminology)
- [RBAC v1 Background](#rbac-v1-background)
- [Problem Space](#problem-space)
    - [RBAC Support for Docker API](#rbac-support-for-docker-api)
    - [RBAC support for Organizations and Projects](#rbac-support-for-organizations-and-projects)
- [Proposal](#proposal)
    - [Projects and Orgs](#projects-and-orgs)
        - [Projects](#projects)
        - [Orgs](#orgs)
        - [associating resources with a project](#associating-resources-with-a-project)
    - [RBAC Actions](#rbac-actions)
- [Implementation notes](#implementation-notes)
- [Open Questions](#open-questions)
- [Notes from earlier discussions](#notes-from-earlier-discussions)
    - [List all instances being a separate policy action/attribute?](#list-all-instances-being-a-separate-policy-action-attribute-)
    - [Converging Docker and Cloud API policy actions](#converging-docker-and-cloud-api-policy-actions)
    - [Auditing](#auditing)

## Introduction

The initial motivations for looking into a v2 RBAC model were to address the lack of
of RBAC support for Docker containers and images. Upon reviewing the use cases for
organization-level and project-level RBAC, it has become apparent that some major
enhancements are required to handle the complexity of resource sharing across accounts,
especially in the context of on-prem customer deployment where one user may belong
to multiple organizations and multiple project teams.


## Terminology

- **customer** or **person**: An honest to god human being (or bot) that is
  calling an endpoint on CloudAPI or Manta with account or subuser credentials.
- **operator**: An honest to god human being (or bot) that is calling an endpoint
  on internal SDC APIs (imgapi, vmapi, adminui, etc.). No credentials are
  involved here.
- **account**: The top-level CloudAPI account. In UFDS an sdcPerson that is NOT
  a `sdcAccountUser`, a.k.a a subuser. Identified for Manta with `MANTA_USER`.
  Identified for CloudAPI with `SDC_ACCOUNT`.
- **subuser**: A login that is scoped on an account. In UFDS, a node that is
  both an `sdcPerson` and a `sdcAccountUser`.
- **login**: The string identifier for an "account" or "subuser". The login for
  an account is unique for all accounts in that cloud. The login for a subuser
  is only unique within that account.
- **user**: This is ambigous. I'd like to use it in lieu of "customer", but given
  Manta and CloudAPI use "user" to mean different things, this RFD will attempt
  to avoid it.


## RBAC v1 Background

Skip this section if you are already familiar with CloudAPI or Manta RBAC. There are
some rather detailed end-user docs (https://docs.joyent.com/public-cloud/rbac)
if you want to pursue further on the feature details.

There are some key characteristics of the current RBAC model that are
important to highlight here for the discussion on RBAC v2:

1. Each account owner may create one or more subusers

2. Subusers authenticate with their own SSH keys. The subuser login is unique
   within each account but is **not** globally unique.

3. Each subuser can be assigned one or more roles that enable the subuser's
   access to the account's resources.

4. There are two dimensions to the access permissions of a role:

   - Policies: Policies define the actions allowed (e.g. "listmachines",
     "createmachine"). Each role has one or more policies attached.
   - Role tags: Role tags control which **instances** of the account's resources
     (e.g. machines, images, users) are allowed for the role.

   The two sets of capabilities together control what a subuser can act on.
   When creating a new resource (e.g. machine), the role tags are automatically
   added to the instance based on which role(s) are passed in the create
   command (no --role arg means "tag all of my roles").

6. There is also a hardcoded 'administrator' role that acts as a super-user
   role, granting full access to everything the account owns.

7. The account owner is free to define roles and policies, and tag their
   resources to achieve granular RBAC. There is no out-of-the-box role but the
   Portal has a few canned roles that are inserted to customer's profile behind
   the scenes for the KVM docker host and registry feature.

8. On every CloudAPI or Manta API request, authorization works like this:

    - get the roles for the caller (subuser login and account login) from mahi;
    - limit to a set of "active roles", if a role was specified in the request;
    - get the role-tags for the resource being accessed;
    - filter to the intersection of active roles and role-tags; and
    - evaluate the policies for those roles (e.g. if this is a CreateMachine
      call, is one of the policy's rules "CAN createmachine"?).

   On failure, a "NotAuthorized" error is returned.

9. Once a subuser has passed authentication and authorization, the caller invokes
   the operation **on behalf of the account owner**. From the perspective of the
   backend API (e.g. vmapi), it sees only the account uuid. All `owner_uuid`
   references point to the account owner. The subuser's identity is tracked
   in jobs but not persisted in the resource's moray bucket. The only tracking is
   via `MachineAudit` CloudAPI which returns the subuser's information from the
   Workflow API jobs.


## Problem Space

### RBAC Support for Docker API

The setup script for sdc-docker does not support the use of subuser login
currently. Authentication works with sdc accounts only. The *workaround* at
this time is for the account owner to add the public keys of subusers to his
account. The side effect of doing so is giving the subusers full access to
all other resources in the account, including users and keys (essentially
making the subuser a delegated admin). This is obviously undesirable.

Like CloudAPI and Manta, there are three basic scenarios that need to be
supported in Docker's RBAC model, listed in the order of importance:

1. Tenancy separation - Users can be granted access to resources based
   on certain group membership and are denied access to resources that
   fall outside of those groups (e.g. 'dev' vs 'prod' environments,
   'financials' vs 'sales' application teams).
2. Access level - Users can be granted different levels of access to the
   same resources. E.g. some can read/write a certain resource while others
   may have read-only access.
3. Combination of 1 and 2, i.e. each user in an account may have different
   access permissions to different groups of resources.

It is also important to note that we are bound by the Docker clients in terms
of what can be passed as arguments to include RBAC information. For containers,
we have the option of leveraging `docker run --label` to pass the role information.
But such flexibility is absent for other resource types.


### RBAC support for Organizations and Projects

The current RBAC model does not support the sharing of resources across
accounts. The key assumption has been that an *organization* - the higher
level entity that owns multiple cloud resources and contains multiple users -
can be abstracted as an 'account'. Members in the organization are subusers
of the account. When a user (person) belongs to multiple organizations, they
need to have multiple logins. The other drawback with this model is that
auditing is easily lost as 'account' has a login of its own.

When an organization has multiple projects, and different access levels for
resources within the projects, there is no good way to model the relationships
using the current RBAC roles. If there are three projects (A, B and C) and two
different access levels (RW, RO), we need to have six unique roles to cover the
permutations even when the access policies are identical for those different
projects.


## Proposal

### Projects and Orgs

(We assert) the customer wants:

- ... to be able to segment groups of resources (e.g. my instances for project A
  separate from my instances for project B).
- ... multiple people in a group be able to share resource access.
- ... to have access control for members of these groups.

Some problems with current RBAC:

- Top-level account vs. subuser separation leads to customers often needing
  separate sets of creds. That's annoying for `triton` CLI profile management,
  bad for auditing, and a real pain for web portal session management.
- Having non-person top-level "company accounts" (or whatever name you want
  to use) results in authentication using a non-person credential, which is
  problematic for good auditing.
- Achieving resource separation with current RBAC requires (a) careful and
  error prone role setup and (b) sometimes manual role-tagging.
- Cross-account sharing isn't possible.
- Various other clunkiness we'd also like to fix: hack 'administrator' special
  case role, weird role-tag requirements for List* endpoints, etc.

Forget "company accounts" (e.g. an "acmecorp" JPC account) and subusers.
Forget mapping resources to *roles* with role-tags (though arguably we'll
introduce something similar). Let's try this all again. If it helps, think
roughly of the GitHub user/org model as we go through this.


#### Projects

You are Wendy. You have a JPC account 'wendy':

    account 'wendy':
        email 'wendy@example.com'

and you have some resources:

        inst 'wvm0'
        inst 'wvm1'
        image 'wimg0'       # a custom image, as opposed to a stock image like 'base-64'

However, now you'd like to play with Terraform or Docker Compose. You'll feel
more comfortable [and IIUC, some tooling will be easier --trent] with an
isolated view of your resources while using those. Enter *projects*:

    $ triton project create terraplay      # I'm making up this command for now
    Created project 'terraplay' (use '-P terraplay' opt, or add to profile)

You create a 'terraplay' `triton` profile for convenience:

    $ triton profile get -j \
        | json -e 'this.name = this.project = "terraplay"' \
        | triton profile create -f -
    Created profile "terraplay"
    $ triton profile set-current terraplay
    Set "terraplay" as current profile
    $ triton profile get
    name: terraplay
    account: wendy
    curr: true
    keyId: SHA256:2XCGHt3iufa9GqoVQHejf03lkjadsglFrN12YUPpA
    url: https://us-east-3b.api.joyent.com
    project: terraplay                                 # <-- this

Now you are scoped on resources that are part of that project. The existing
'wvm0', 'wvm1' and 'wimg0' don't show up.

    $ triton insts
    SHORTID  NAME  IMG  STATE  PRIMARYIP  AGO

Now you run through <https://www.joyent.com/blog/introducing-hashicorp-terraform-for-joyent-triton>
and:

    $ triton insts
    SHORTID   NAME                IMG                                   STATE    PRIMARYIP        AGO
    0311dadb  nginx-terraform-01  a23c9a08-089d-134b-c85e-f656e514549e  running  165.225.168.228  5d
    62609fb1  test-machine        ubuntu-15.04@20151105                 running  165.225.168.229  5d

The full layout looks something like this:

    account 'wendy':
        email 'wendy@example.com'
        --
        inst 'wvm0'
        inst 'wvm1'
        image 'wimg0'
        --
        project 'terraplay':
            inst 'nginx-terraform-01'
            inst 'test-machine'

Featuritis? Bear with me.


#### Orgs

Currently, to have multiple people sharing resources you create a sorta-meta
non-person account with subusers for the actual auditable separate people. The
proposed alternative is organizations (**orgs** for short) -- which contain
members (top-level accounts, with RBAC roles) and projects. An attempt to give a
feel for the hierarchy and rules for these things:

- Orgs are siblings to accounts in UFDS. They share the same namespace:
  you can't have a `trent` account *and* a `trent` org.
- Resources (vms, custom images, fabric networks) are "owned"
  by either an account (as now) or by an org. I.e. `vm.owner_uuid`, and the
  equiv for other resource types, is the UUID of an account or an org.
- Orgs do *not* have keys. You cannot authenticate as an org.
- An org has members. These are top-level accounts.
- Some of those members can be owners (there must be at least one). Being
  an org owner affords full access to changing it: deleting,
  adding/removing members, creating projects in the org.
- Resources owned by an org *must* belong to one or more projects. E.g. a fabric
  network might reasonably belong to two projects so instances in those projects
  can talk to each other privately. (This differs from resources belonging to
  accounts, which *can* exist without a project.)
- Projects have membership: an *account and a role*. The role defines the
  access level.
- Roles are basically the same as now: A role has a set of polices, which have a
  list of [aperture](https://github.com/joyent/node-aperture) rules like "CAN
  CreateInstance" to define what actions (called "RBAC Actions") can be
  performed.


Back to Wendy. This JPC thing is working out. You are going to use it for your
startup called "Wassup". You're going to wipe the floor with those
http://www.suptheapp.com/ jokers. You have a co-founder Warren (he gets a JPC
account 'warren'), and webdev Wil. Wil already has a 'startrek42' JPC account.

Grouping all company resources under 'wendy's account is silly, so you create
an org, switch your profile to use it:

    $ triton org create wassup
    Created organization 'wassup' (owners: wendy)
    $ triton profile create
    name: wassup
    ...
    $ triton profile set-current wassup

and add your employees:

    $ triton org member-add wassup --owner warren   # also make Warren an owner of the org
    Added member 'warren' to organization 'wassup' (as an owner)
    $ triton org member-add wassup startrek42
    Added member 'startrek42' to organization 'wassup'

And roles/policies for the org:

    $ triton ...        # [we hope to have reasonable canned policies to simplify]

and some starter projects (high flyin' trekkie Wil doesn't need access to
billing resources):

    $ triton project create web --membership-all
    $ triton project create app --membership-all
    $ triton project create billing -m wendy -m warren

To get something like this:

    account 'wendy': ...
    account 'warren'
    account 'startrek42'
    org 'wassup':
        role 'ops' with policy 'poli-ops'
        policy 'poli-ops'
        role 'readonly' with policy 'poli-readonly'
        policy 'poli-readonly'
        --
        member 'wendy' (owner, default role 'ops')
        member 'warren' (owner, default role 'ops')
        member 'startrek42' (default role 'ops')
        --
        project 'web':
            member *         # IOW, all org members can access this project
        project 'app':
            member *
        project 'billing':
            member 'wendy' with role 'readonly'
            member 'warren'

Some notes on this:

- Each member will typically have a "default role" -- the role that typically
  applies when they access project resources.
- The default role can be overridden per-project. E.g. wendy doesn't want to
  mess up billing resources, so her role in project 'billing' is 'readonly'
  (which has a policy that doesn't allow DeleteInstance).


Now how to uses these projects? Let's be Wil. He'll setup a `triton` profile
like this:

    $ triton profile get
    name: wassupweb
    account: startrek42
    curr: true
    keyId: SHA256:yYMdKsaFzAugDQALtxUxZhRsBtjdgDY2tT958I39hnQ
    url: https://us-east-3b.api.joyent.com
    org: wassup                         <------ this
    project: web                        <------ this

and then create away:

    $ triton create -n web0 minimal-32 t4-standard-1G

[Note that we are proposing that "stock" resources (for lack of a better word)
like standard images, public packages, networks without an
`owner_uuid`, etc. are not restricted. I.e. Wil has access to the 'minimal-32'
image. Support for allowing an org or project to restrict stock resources
can be considered later.]

or use Docker:

    $ curl -O https://raw.githubusercontent.com/joyent/sdc-docker/master/tools/sdc-docker-setup.sh
    $ ./sdc-docker-setup.sh -p wassupweb -o wassup -P web us-east-3b
    $ ./tools/sdc-docker-setup.sh -p wassupweb
    SDC CloudAPI URL [https://us-east-1.api.joyent.com]: us-east-3b
    SDC account: startrek42
    SSH private key [/Users/wil/.ssh/id_rsa]:
    Organization: wassup
    Project: web
    ...
    $ source ~/.sdc/docker/wassupweb/env.sh
    $ docker run --name web0 nginx:latest

[Dev Note: crying out for `triton docker-setup` or something here.]

Then we'd have:

    org 'wassup':
        ...
        project 'web':
            member *
            --
            inst 'web0'


And theoretically, this is it. There remain a lot of details, but the gist is:

1. Org owners need to do some rare management/setup of the org, roles, policies,
   projects, membership and (possibly) manual addition of resources to a
   project.
2. Account holders need to set one or both of 'project' and 'org' in their
   `triton` profile.


#### associating resources with a project

Given a resource, SDC already provides an owner -- `vm.owner_uuid`,
`image.owner`, `network.owner_uuids` (that this is plural might complicate, not
sure), etc. Now we need to know what projects, if any, to which a resource
belongs.

We'll think about a `projects` property on CloudAPI objects. The equivalent in
legacy RBAC is role-tags (associating with roles instead of with projects).
Effectively, a resource created by a cloudapi request scoping to that project
(e.g. the `triton` profile has `project=foo` set) will be associated with that
project.

The expected user experience is that resources naturally belong to the
appropriate project. Some use cases (e.g., a network or image belonging to
multiple projects) justify support for manually adding a resource to a project.


### RBAC Actions

Background: Roughly speaking, an RBAC v1 subuser a has zero or more *roles*. A
role has a set of *policies*. A policy looks like this:

    {
        "name": "ops",
        "description": "full access",
        "rules": [
            "CAN createmachine",
            "CAN getmachine",
            "CAN getimage",
            ...
        ]
    },

`CAN createmachine` is a **rule** (defined by the
[aperture](https://github.com/joyent/node-aperture) policy language).
`createmachine` is an example of an RBAC **action**. In RBAC v1 the RBAC actions
(mostly) map one-to-one to CloudAPI and Muskie endpoint names.

At this time, there are only two types of resources managed in Docker -
containers and images. There may be additional ones (e.g. volumes, networks)
going forward. We can potentially follow the current RBAC model to have
fine-grained policy actions.

The Problem: There are a few wrinkles:

- A single command from Docker clients (CLI, Compose) can result in
  multiple remote API calls. Users are not necessarily aware of the
  actual API endpoints involved. It will be difficult for them to grant
  the right set of policy actions to cover one client action.
- Docker remote API and client capabilities are still growing/changing rapidly.
  It'll be a burden for user to keep up with policy action update whenever a
  new endpoint is added.

Taking the above into consideration, it may be more appropriate to have logical
groups of policy actions to cover the many Docker API endpoints (e.g. a single policy
'OperateContainer' to control container start/stop/kill/pause/unpause/wait permissions).
Having the more coarse-grained policy actions will simplify the RBAC setup.

The coarse-grained policy actions will need to meet the following requirements so that
they are simple enough but not overly simplistic:

- GET access for a resource can be as trivial as getting its non-confidential metadata,
  or as in depth as retrieving the operational data (logs, audit trails, processes),
  or even the entire content of the resource in the form of an export file. It will be
  appropriate to treat these permissions differently.

- Likewise, PUT and POST access for a resource can range from changing its state (e.g.
  the power state of a container), to its metadata (e.g. name, labels), to its content
  (through file copy or executing commands in the container). These different types
  of update actions warrant separate access permissions.

- As far as the policy action naming is concerned, there are some advantages in
  adopting the {service}:{policyAction} convention to provide more clarity on what
  policy actions correspond to which services. For Docker and CloudAPI, they can be
  in the same service category and with policy actions named tentatively to something
  like `ecs:GetInstance` (ecs = Elastic Container Services). Manta policy actions can
  likewise be renamed accordingly, e.g. `manta:PutObject`.

Putting it all together, here is a first-stab of the Docker policy actions, along with
a naive list of key user roles that consume them:

| Role | Description                                                 |
| ---- | ----------------------------------------------------------- |
| Dev  | Developers who define and build containers                  |
| Ops  | Operators who deploy and manage container operations        |
| User | End users who access containers to run/use the applications |
| APM  | Application performance monitoring system agents            |

| Policy Action                | Dev | Ops | User | APM | Docker Route                                          | Method | Docker Endpoint                                               | CloudAPI Equiv                           |
| ---------------------------- | --- | --- | ---- | --- | ----------------------------------------------------- | ------ | ------------------------------------------------------------- | ---------------------------------------- |
| ecs:GetImage                 | X   | X   |      |     | ImageList, ImageInspect, ImageHistory, ImageSearch    | GET    | /images/\*                                                     | getimage, listimages                     |
| ecs:ImportImage (TM)         | X   | X   |      |     | ImageCreate                                           | POST   | /images ???                                                   |                                          |
| ecs:ExportImage              | X   |     |      |     | ImageGet, ImagePush                                   | POST   | /images                                                       |                                          |
| ecs:UpdateImage (TM)         | X   |     |      |     | ImageTag                                              | POST   | /images                                                       |                                          |
| ecs:CreateImage              | X   |     |      |     | CreateImage, LoadImage                                | POST   | /images                                                       |                                          |
| ecs:DeleteImage              | X   |     |      |     | DeleteImage                                           | DELETE | /images                                                       | deleteimage                              |
| ecs:CreateImage              | X   |     |      |     | Commit                                                | POST   | /commit                                                       | createimagefrommachine                   |
| ecs:CreateImage              | X   |     |      |     | Build                                                 | POST   | /build                                                        |                                          |
| ecs:GetInstance              | X   | X   | X    | X   | Container{List,Inspect,Top,Logs,Stats}                | GET    | /containers/\* (except export,archive,changes)                 | getmachine, listmachines                 |
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
| N/A - accessible to all      | X   | X   | X    | X   | Ping                                                  | GET    | /\_ping                                                        |                                          |
| ecs:GetImage                 | X   | X   | X    | X   | Auth                                                  | POST   | /auth                                                         |                                          |
| N/A - accessible to all      | X   | X   | X    | X   | Info                                                  | GET    | /info                                                         |                                          |
| N/A - accessible to all      | X   | X   | X    | X   | Version                                               | GET    | /version                                                      |                                          |
| ecs:AuditInstance            | X   | X   | X    | X   | Events                                                | GET    | /events                                                       | machineaudit                             |

See a [full table of RBAC actions here](./rbac-actions.md).


## Implementation notes

(Obviously, only a start so far.)

Association of projects with resources:

(a) be handled at the edges -- i.e. in cloudapi and muskie. VMAPI
    doesn't know about project association. This is similar to role-tags
    currently.

(b) be handled by a new API, call it PROJAPI. The idea here is that real API
    rather than slumming in UFDS for non-replicated data will help
    (less messy DB migrations, API control over object field names vs.
    restricted to raw objects in UFDS, better indexing control).


## Open Questions

- full API and tooling for CRUD on orgs and membership
- full API and tooling for CRUD on projects and membership
- supporting legacy RBAC
- implications for Manta
- transferring resources from one account to another
- supporting transforming an existing account to an org (e.g. existing tunacorp
  account really wants to just be a tunacorp *org*)
- lots of Qs in my other notes
- There is already a pre-defined "docker" role and "docker" policy used by
  the KVM Docker features in the Portal. Those features are being deprecated.
  To avoid confusion, we'll need to clean up those roles/policies in accounts
  which have previously made use of KVM Docker.


## Notes from earlier discussions

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
resources in the account whenever a `List*` policy is added to a role (and supposedly
untag them when the policy is dropped). API users have to take care of that manually.

Option #3 will provide the most flexibility and reduce a lot of the need for role-tagging
when tenancy separation is not required for the resource. It'll potentially help
performance but it is a major change to the policy data model. If we can implement
this, we can remove the Portal hack which is expensive and unreliable.

### Converging Docker and Cloud API policy actions

Based on a survey of current usage of RBAC in JPC, it appears that people have
found it difficult to understand which policy actions need to be granted together to
support certain high-level actions. Many users have resorted to granting all
policies or using the 'administrator' role. The user experience will likely
improve if CloudAPI policy actions move from the fine-grained to coarse-grained model
as well.

We'll also need to reconcile what happens when user has the permission to `ListMachines`
in CloudAPI but not the Docker API equivalent (and vice versa). One way to view this
is that even though docker resources are a subset of all the resources owned by the
account, it is unlikely that users want to segregate the permissions by container/vm type
(i.e. some users can manage LX/SmartOS zones, while others can only manage docker).
The intention for granting `ecs:ListInstances` is allowing user to see all instances,
regardless of the type. Hence, there should not be two islands of permissions for
CloudAPI and Docker API. A user who has `ecs:CreateInstance` access should be able
to create any type of containers. We'll need to consider some kind of migration/conversion
for existing RBAC data that have been defined for CloudAPI to use the new coarse-grained
model and naming convention.

### Auditing

Auditing is not returning correct information for docker containers
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
