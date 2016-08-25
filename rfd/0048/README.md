---
authors: Alex Wilson <alex.wilson@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc
-->

# RFD 48 Triton A&A Overhaul (AUTHAPI)

# Background

## Authentication and Authorization

Two key components of any infrastructure that enforces security policy are
authentication and authorization.

The term "authentication" refers to the establishment and proof of identity of
a user or component of the system. This is normally by way of the agent
presenting information that could only be known to them if they possessed the
identity being authenticated, such as a password or the output of a
cryptographic primitive (such as a key signature or a step in a hash chain).

We will refer to the abstract identity as a "principal", which a "user",
"agent" or "client" must prove that they possess in the authentication process.

The other component, "authorization", is responsible for ascertaining what
actions the principal may take once they have been authenticated. It
encompasses access control lists, roles, user groups, and everything needed in
order to make these decisions within a given system.

Authentication is generally a fairly well-established part of any system, and
Triton is no exception. It tends to require fairly similar processes and steps
across a wide variety of systems, and as a result is generally both very well
studied and well practiced by engineers who care to do some reading on the
topic before proceeding to implementation.

Authorization, on the other hand, is where the fundamentals of identity have
to be mapped to the possible actions and resources in each individual
application. This component exhibits high variability of design between
systems, though certain general patterns and schools of thought have been
established.

## Role-Based Access Control (RBAC)

One of these general patterns is known as Role-Based Access Control, or RBAC.
The notion of RBAC was formalized in the "NIST model", by Sandhu et al (2000),
after being originally proposed and experimented with through the 1980s and
1990s.

The NIST model approaches authorization by assigning principals to be members
of one or more *roles*. Roles, then, grant *permissions* to access certain
*resources* in the system. These permissions come in the form of access control
rules -- tuples of the form `(action, resource)` representing actions that will
be allowed.

If no permissions are granted via a role for a given principal to take an
action, then that action is denied. This is known as a *default-deny*
authorization model.

# A&A in Triton: a short history

Originally, Triton (SDC at the time) possessed an extremely simple authorization
scheme: there were *accounts*, and resources were always associated with exactly
one account. Accounts had all possible access to their own resources and nothing
else.

During the development of Manta, it became obvious that this simplistic model
was not going to meet the needs of a number of major customers, and so a new
system (loosely) based on NIST RBAC was devised.

## The Manta model

 * Manta *users* are billable principals that can own manta resources and are
   their own segment of the manta directory tree.
 * *Ownership* of a resource implies full action rights over that resource.
 * *Sub-users* are principals that are subservient to their parent *user*.
   They cannot own resources themselves and must be granted explicit rights
   to do anything.
 * Principals can be members of a *role* in two ways: regular membership, where
   they must *take up* the role by supplying appropriate headers with each
   request; and default membership, where the role is always active.
 * Roles can be associated with *policies*, which are lists of actions.
 * Roles can be associated with *resources*, in the form of *role tags*.

Note that in order to grant any access to a principal, the full set of
associated *role*, *policy* and *role tag* must be present.

The reason why *role tags* are used is essentially to bridge the gap between
the NIST model of resources (a flat space of unstructured specifiers) and
Manta's resource model (a UNIX-style filesystem tree). Having to specify
every possible file on the filesystem that should be targetted by a policy
is prohibitive for administrators, and prefix/suffix matching is insufficient
for many uses.

## The Manta model comes to Triton

Following the success of the Manta model with the original customers for whom it
was devised, there was pressure to update the Triton authorization model in a
similar fashion. To avoid duplication, it was decided to simply copy the same
model used in Manta, and make the two share their data.

Unfortunately, Triton would actually have been a better fit for something closer
to the stock NIST model, as it is not organised as a hierarchical filesystem. To
resolve the mismatch, it was simply decided that the role tags would be applied
to CloudAPI URLs (which look like a hierarchical filesystem if you squint a
bit).

The action verbs used by the Manta model were also defined largely by the
filesystem semantics of the storage system. For Triton, it was decided to
instead use the internal names given to each CloudAPI endpoint (also in the
documentation) as the action names. This creates some curious points of overlap,
where the endpoint in question has to be doubly stated by the administrator:
first in the action name, and then in the resource to be role-tagged.

While this adoption of the Manta model in Triton was expedient from a
development perspective, it has not enjoyed broad adoption by users. The
facility is generally seen as difficult to use and little documentation was
ever produced to dispel that perception. The APIs used to interact with RBAC in
Triton were not very discoverable: there is no way to list all of the available
verbs, or to discover the correct resource URL to use in policy for a
particular Triton object. The writing of effective policy under these
conditions is extremely difficult.

## Triton Authentication

As well as the authorization scheme, there has been some history in the
development of authentication in Triton and Manta.

Originally, all information about customers was stored in CAPI (the Customer
API). During the development of SDC 7, it was decided that an LDAP-based
database would be a better store of this information than the existing CAPI.
This, combined with a dissatisfaction with other existing LDAP databases, lead
to the development of UFDS.

UFDS is an LDAP server implemented atop Moray, the key-value document store
developed primarily for use in Manta. Manta is well-served by the key-value
paradigm; most stored data is small in size and very close to immutable. Most
values are accessed directly by primary key; e.g., object metadata is
identified and accessed by its path in the exposed file system hierarchy.

By contrast, LDAP's underlying X.509 directory structure is a strict tree, and
LDAP servers generally expect to serve a lot of queries that are not on primary
keys (DNs or distinguished names). LDAP objects also experience frequent
updates to single properties, such as to change a password or update a
timestamp. There is thus a very high impedance mismatch between the key-value
document store paradigm that Moray provides, and the LDAP paradigm that UFDS
exposes to consumers.

<!-- NOTE: As I read the above, I am left a bit unsatisfied by the
     justification.  Manta is a strict tree as well; it feels like
     the substantive difference is that LDAP servers have historically just
     had more appropriate indexes and query planners for the kind of
     queries that are being done. -->

LDAP could have had some interesting advantages for Triton, such as being able
to integrate with PAM and the operating system authentication and authorization
model. Again, unfortunately, the LDAP schema that was selected for Triton's use
with UFDS precluded this, and UFDS grew into an LDAP store that was really only
ever used as yet another internal database, a job at which it has never proved
especially adept.

## Previous work

In [RFD 13](https://github.com/joyent/rfd/blob/master/rfd/0013/README.md), it
was proposed to make a number of changes to the Triton-specific parts of the
existing RBAC scheme, particularly:

 * Some notion of "projects" and "organizations" as entities for grouping
   Triton resources
 * An overhaul of the RBAC actions/verbs used for Triton
 * Applying RBAC to Docker as well as CloudAPI

This previous work will be largely subsumed into the proposals in this
document, which can be considered a way to implement the changes proposed
in RFD 13.

# Proposal

The most fundamental aspect of the AUTHAPI proposal is to replace UFDS. The
new AUTHAPI will provide extensive backwards compatibility with UFDS to aide
in the transition, but this LDAP compatibility interface will not expose any
new features and will be deprecated from inception.

There will be no internal LDAP server within the Triton stack going forwards.
AUTHAPI will be used over HTTP. It will also support the changefeed interface
(from RFD 5).

AUTHAPI will also take over the authorization responsibilities that are
currently splintered and re-implemented separately in CloudAPI, Muskie
and the Mahi client. All parsing and processing of RBAC rules and entities
to make an authorization decision will take place in AUTHAPI and not in
any of its clients.

This means that AUTHAPI will primarily answer questions at the level of
"Can user X take action Y on resource Z?" and *not* "What roles does user X
have? What rules do they contain?"

One of the core goals of the AUTHAPI service will be to aggressively make
use of caching and scale-out techniques in order to make sure that Mahi
is unnecessary going forwards. Manta must be able to query AUTHAPI directly
and have AUTHAPI able to handle the scale and load.

## RBAC model

Along with the implementation changes, the AUTHAPI proposal also includes some
changes to the RBAC model. These subsume the proposals made in RFD 13.
The new model, to whit:

 * *Accounts* are billable entities capable of owning resources. They are also
   principals that can be authenticated.
 * *Ownership* of a resource implies full action rights over that resource.
 * *Sub-users* are principals that are subservient to their parent *account*.
   They cannot own resources themselves and must be granted explicit rights
   to do anything.
 * *Projects* and *Services* are containers for instances within an account. For
   RBAC purposes, they are nothing more than a way to refer to a group of
   instances as one unit for policy purposes. A given instance can only be
   listed in exactly one Service, which may be part of exactly one Project. An
   instance may also be listed directly in one Project without an intermediary
   Service.
 * *Foreign principals* are principals whose identity cannot be verified
   by Triton or Manta itself, but who have been authenticated by a trusted
   external means (further information below).
 * Principals (either *accounts*, *sub-users*, or *foreign principals*) can
   be members of *roles* or *groups*, which exist within the context of an
   *account*.
 * Both *roles* and *groups* have members, and a collection of *access rules*.
   *Roles* must be "taken up" in order for their rules to apply to a member.
   *Groups* have their rules automatically applied at all times.
 * *Access rules* are a pair of a *verb* (or action) and a *target*. The
   *target* may be a specific resource (like an instance), a group of
   instances (such as a project), or an owning entity (like an account).
 * *Roles* may *imply* other roles. If role A implies role B, it means that
   when role A is taken up by a principal, role B is necessarily taken up as
   well, without being explicitly specified.
 * *Groups* may be a member of a role, meaning that all members of the group
   are permitted to take up that role if they explicitly do so. It does not
   cause the role to be automatically taken up by all group members.
 * *Groups* may be a member of another group, which is equivalent in
   behaviour to all the members of one group being members of the other as
   well.
 * *Organization accounts* are a sub-class of *accounts* that are not
   principals for authentication. They are otherwise identical to an account.
   They must at all times have at least one other account as a member of a role
   or group that grants full administration rights over the organization
   account.

Key differences/deprecations versus the current model:

 * The distinction between *policy* and *role* has been removed. Roles contain
   access rules directly.
 * Roles and groups will be able to list *any* principal, including other
   accounts, sub-users of other accounts etc, as members.
 * *Role tags* will not be used for Triton RBAC at all. Instead, rules placed
   in a role's access rule list will be able to accept explicit targets, or
   will have implied targets (e.g. for `triton:GetAccount`).
 * For Manta, *role tags* will remain as they are. All Manta verbs used in
   access rules have an implied target of all objects tagged with the matching
   role tag.

## Verbs and targets

As in the RFD 13 proposal, a new set of verbs will be used, namespaced
separately for actions that relate to each major part of the system. Initially
there will be two major namespaces, one for Manta and one for the Triton compute
services (CloudAPI and Docker), and one smaller namespace for RBAC meta-actions.

Extending the previous proposal, namespaces will also be used for the targets of
rules, normally denoting the type of entity being targetted. This may seem
redundant, in the case of a rule such as `CAN triton:GetInstance instance:uuid`,
but this is important to distinguish it from
`CAN triton:GetInstance account:uuid`, which applies to all instances owned by
the named account.

The notion of applying a verb relating to one type of noun to a noun of a
different type that serves as a container for it (e.g. applying an instance
verb to an account) is referred to as making use of the "target hierarchy".

The most common target hierarchy relationship is between entities and their
containing Accounts. In general most verbs can target an entire Account in order
to refer to all of the targets owned by that Account.

For instances, however, a further relationship may exist with Projects and
Services. Instance-related verbs may target a Project or Service to refer to all
instances within that group.

## Role and group templates

Many other hosted web services such as GitHub offer a very simple authorization
scheme based on pre-made roles. The roles are associated with a given object,
such as a repository, and include broad-sweeping rights in the style of "read",
"write" and "admin". Many users have reported that they find this style of
authorization sufficient for their purposes and vastly simpler to administer
than fully-fledged RBAC.

As a result, it is desirable that the new RBAC interface can present such a
simplified view to users who desire it, without sacrificing the flexibility
needed for more advanced use.

The proposed means of implementing this comes in the form of role and group
"templates". A role template is created by the developers of the system, and
exists centrally. It has a name, is associated with a target type (e.g.
Accounts), and contains a set of access rules targetting an entity of that type.
A user may instantiate a template role, making a concrete role associated with a
particular entity. The concrete role continues to refer to its template for
access rules and name after instantiation.

In this way, the Triton system as a whole can have a role template for an
"Account reader", which includes read-only access to all the different types of
entities owned by that Account. Users can simply instantiate the "Account
reader" template role for their account and add principals to it, and if the
Triton software is updated and some new type of entity is added, the necessary
"read" RBAC verbs for it can be added to the template and automatically be
present in the account's local instantitation.

In general most entity types will have 4 template roles associated with them:

 * *Readers* have read-only access to resources;
 * *Modifiers* can modify existing resources and operate them (e.g. for an
   Instance, they can log in administratively, stop and start etc);
 * *Creators* can create and destroy resources; and
 * *Administrators* can manage membership in the other template roles and alter
   security metadata.

These are additive: a member of an administrator template role would have the
powers of a reader, modifier and creator as well.

To avoid dealing with unfortunate levels of recursion, templated RBAC roles and
groups will not have template roles or groups associated with them. However,
manually created roles or groups will have a reader and modifier template role.

Any template role may be instantiated as a group instead of a role. It is
generally expected that most users using this feature will in fact primarily
instantiate them as groups.

## Public API and introspection

One source of difficulty in building upon the existing RBAC scheme in Triton has
been the lack of any mechanism to discover or introspect verbs and targets, and
a very limited and terse API surface. We propose to improve this situation by
providing a much richer public API for RBAC-related queries and operations.

A rough draft of the API itself is pending, but the key points are:

 * `List` endpoints for all of the RBAC concepts outlined here. In particular,
   filterable List endpoints for RBAC verbs, target types, roles, groups, etc.
 * `Audit` endpoints, which allow the user to find the effective access rights
   of a particular principal, or the list of principals with certain effective
   rights to a given entity. For example, the user will be able to list all
   principals that can create a VM under their account (whether those rights
   are targetting a Project or Service or the entire Account).
 * A `Check` endpoint to evaluate whether a particular operation would be
   allowed without having to attempt the operation itself.
 * Endpoints for listing the template roles/groups available under a given
   entity and instantiating them.
 * Simplified endpoints for managing group and role membership without requiring
   read-modify-write cycles.

Commandline tools such as `node-triton` will make use of these endpoints to
provide facilities like tab-completion for RBAC commands, as well as detailed
help text.

## Migration, replication and compatibility

As replacing UFDS is one of the fundamental aspects of this proposal, this
necessitates the capacity both to migrate seamlessly from UFDS to AUTHAPI, and
to retain compatibility for some time after such a migration.

It also implies providing much of the important functionality required by the
system which UFDS currently provides. In particular, inter-data-center
replication is a major point of development focus (as it has been the source of
many operational issues with UFDS).

The upgrade process from UFDS to AUTHAPI for a single datacenter follows the
following general outline:

 * Start AUTHAPI in its default mode, acting as a UFDS-compatible replication
   client, replicating all changes from the existing UFDS. AUTHAPI remains
   read-only.
 * As part of AUTHAPI installation, "DC-local" data is copied from the existing
   UFDS into AUTHAPI. The UFDS protocol does not include support for replicating
   changes to this data. This can be synced up periodically using an
   administrative tool while the DC in this state.
 * AUTHAPI provides a UFDS-compatible interface (LDAP), which services
   immediately begin to use for read-only operations.
 * Updated service images (as they are updated) will start to use the new
   AUTHAPI interfaces for reading data and authentication/authorization
   decisions that don't require any writes.
 * Rollback is possible at this stage.
 * At some point, the decision is made to switch off UFDS. The administrator
   runs a single authapi administrative command which drains, then shuts
   down UFDS, re-syncs DC local data and makes AUTHAPI writable.
 * Schema upgrades begin in the background to enable the new RBAC features. At
   this point rollback is no longer possible.

For multi-datacenter deployments, the situation is slightly more complex:

 * Start one AUTHAPI in its default mode, acting as a UFDS replication client,
   only in the UFDS "master" DC.
 * AUTHAPI instances in other DCs use the "master" DC's AUTHAPI as their
   replication source, not their local UFDS.
 * At the time of cutover, non-"master" DCs have their local UFDS drained and
   shut down first, before the "master".

The time between first starting an AUTHAPI instance and switching off UFDS can
be arbitrarily long. Service images will be required to continue being able to
operate in both a UFDS-only or AUTHAPI-only world (or a mixed environment) for
at least the year or two following general availability of AUTHAPI.

AUTHAPI will support multi-instance operation from day 1 of general
availability. Multiple AUTHAPI instances can be run in any datacenter. Some
components of its operation (particularly cross-data-center replication) require
one instance to take a special role in the cluster. A ZooKeeper leader election
protocol will be used to nominate a single AUTHAPI in the DC to undertake each
special role at a time.

## Internal relationships with Triton components

As well as changing the external public API of the Triton stack, AUTHAPI
brings some changes to internal Triton services. In particular:

 * CloudAPI will no longer be responsible for authorization decisions. Instead
   it will handle authentication (with AUTHAPI's assistance), and then provide
   the user and list of active roles to internal APIs in the form of an HTTP
   `Authorization` header.
 * Internal APIs (especially VMAPI, NAPI etc) will be responsible for
   authorizing user actions by querying AUTHAPI. In the case that they receive a
   request with no authentication details (ie, no `Authorization` header), they
   proceed assuming the request is on behalf of the `admin` user. For
   bootstrapping purposes, requests on behalf of `admin` may be carried out
   even when no AUTHAPI can be reached.
 * Internal APIs will also be required to register and manage aspects of their
   data schema with AUTHAPI. For example, VMAPI will publish to AUTHAPI a
   specification of the objects that it deals with that need authorization
   (instances, projects etc) and the verbs and template roles that may be
   associated.
 * For internal APIs that require authorization on objects that participate in a
   target schema relationship, they must also give AUTHAPI a "callback"
   endpoint that lets AUTHAPI find the "parents" of a given individual object.
   This is to enable the `Audit` functionality in the public API.

This transition will be managed by versioning internal APIs (using both
DNS-mediated versioning and `Accept-Version` HTTP headers). CloudAPI will have
to continue to carry out authorization checks until all backend services are
upgraded, and be prepared to return to that role if any roll back. Eventually at
some point in the future (possibly in 2-3 years) CloudAPI will simply refuse to
answer requests in an environment where services are not capable of performing
authorization checks.

The finer details of this arrangement and the transition to it are the primary
topic of RFD 49.

## Foreign principals and single sign-on

The initial work for RBACv2 and AUTHAPI described here does not include the
actual support for foreign principals and single sign-on. However, it is
important to note that the API designs will take these mechanisms into account.

In particular, authentication will no longer be assumed to be exclusively
key-based. AUTHAPI will accept standardized descriptions of the points of proof
that an external-facing API has been given (e.g. proof that the principal they
are communicating with holds some private key) and convert these into the
authentication tokens that are used for authorization (as described in the
"Internal relationships" section, previously).

In future, it is expected that AUTHAPI will also accept OAuth and SAML tokens as
possibly means by which to prove identity for foreign principals. Somewhat like
sub-users, these foreign principals will not be capable of owning any resources
themselves, but can act in limited ways upon some already-existing account (as
defined by the access rules of roles they may take up, or groups of which they
are a member).

# Dependencies

## Service discovery overhaul: cueball and libregistrar

The interaction with other Triton components requires DNS-assisted versioning in
order to cross the boundary between the current world and the `Accept-Version`
enforcing one. For this and HA-mode operation to be possible, the cueball and
libregistrar projects need to be completed.

# Development milestones

## 1. Full specification of AUTHAPI API interface (in progress)

A full endpoint-by-endpoint specification of the AUTHAPI internal-facing API, as
well as the public portions to be exposed via CloudAPI.

## 2. Review of current UFDS workload and data (in progress)

Review of the current UFDS workload and data is necessary in order to inform the
design of the UFDS LDAP compatibility interface, to see what forms of queries it
needs to support.

## 3. Full specification of UFDS LDAP compatibility

A full set of queries that the UFDS compatibility must be able to handle and
expected results, to be made into a suite of test cases.

## 4. Data model and basic schema

Design of the core data model (for users, roles, groups etc) down to Postgres
tables and structure. Extensive design and testing of the concepts around schema
upgrades and migration.

## 5. UFDS replication client

Ability to ingest the entire JPC UFDS changelog and store it correctly.

## 6. Basic authentication and authorization APIs implemented

Basic APIs which can be used to help test #5. Workflows such as authenticating
using a public key, and authorizing basic actions without hierarchy support.

## 7. Target hierarchy and changefeed support

Support for the target hierarchy and changefeeds.

## 8. UFDS compatibility interface (LDAP)

A working LDAP compatibility interface that can pass all of the specification
tests developed in #3. Can function as a full read-only UFDS in the JPC without
issue.

## 9. Native AUTHAPI replication

The native replication scheme for AUTHAPI, including full authentication and TLS
support.

## 10. CloudAPI authentication usage

CloudAPI uses AUTHAPI for authentication workflows only.

## 11. VMAPI authorization usage

VMAPI uses AUTHAPI for authorization when given an appropriate request header.
CloudAPI uses DNS-mediated versioning to detect the new VMAPI and delegate
authorization decisions about CloudAPI actions to it. CloudAPI still performs
authorization on other entities itself (e.g. networks).

## 12. Wider *API authorization

Support for AUTHAPI authorization in all internal Triton APIs. AUTHAPI ready for
sole operation and the shutdown of UFDS.
