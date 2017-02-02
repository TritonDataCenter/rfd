# microsite.jupiter.example.com

Story details include:

- project creation
- copying and moving projects
- secrets/configuration

The operators of [jupiter.example.com](./jupiter-example-com.md) sometimes run the same CMS to power microsites for events and other purposes. Most of the operations are the same as for [jupiter.example.com](./jupiter-example-com.md), but the frequency with which they have to create new projects, copy existing projects, or move them is much higher.

When embarking on a new microsite project, the team creates a new repository in GitGub with all the source code, including Dockerfiles and project manifest. Each repo is substantially similar, but it's still a separate repo (or, alternatively, a distinct branch in the same repo as other projects).

The operators manually create a new project using the web UI tools, specifying the GitHub repo and branch from which to fetch the project manifest, though they sometimes manually paste in the manifest without specifying a GitHub repo.

Upon creating the new project, the web UI prompts the operators with a list of required configuration variables (project meta) for them to fill in. That list of configuration variables is specified in the project manifest, but their values are not set. The web UI might even use validation hints from the project manifest to suggest values for some variables (random string generators of variable length, etc.).

At times, the operators need to copy the project to manually test a different configuration or for other reasons. Care must be taken when copying a project to make sure that none of the variables (project meta) are unintentionally copied. Only the operator can know which variables make sense to copy, and which do not. The web UI does not default to copying any variables, but may include a feature that allows operators to specify which variables to copy at the time the copy is made.

Variables are scoped to individual projects, rather than the organization. This prevents changes in variables to one project from negatively affecting the behavior or operations of another project. Future software versions _may_ include features that allow organization-scope variables, but the guardrails to make that work reliably are beyond the scope of the initial versions of Mariposa.

Occasionally, a microsite needs to be changed to new owners in a different Triton organization. Rather than entirely re-implementing the project in that organization, Triton and Mariposa offer a feature to move the project from one organization to another. Unlike when copying a project (which creates new instances), moving a project changes the ownership of existing instances with a goal of zero downtime.

To move a project, you must have elevated permissions (perhaps "superadmin"?) within the source project (but you may have no permissions in the source org), as well as permission to create new projects within the destination org. The "superadmin" permission within the source project gives that user full access to all the secrets of that project.

Naively, moving a project triggers the same questions about variable/project metadata management as copying the project, but consider this:

> If a project can be moved without all its secrets (as is allowed with copying), what happens to running instances that depend on those secrets? What about those secrets already in memory or on disk in those containers (and which are probably accessible to the new operators)?

Preventing the secret leaks described there in a way that can work reasonably across a meaningfully broad set of applications is beyond the scope of Mariposa. Instead, we will **assume that moving a project _also_ moves all its secrets**. This requires that the tools give appropriate warnings when moving projects and perform a new password check to verify identity. If the organization sending the project does not wish to transfer all its secrets, they will have to change out the existing secrets as a separate operational step prior to migrating (and, presumably, prior to adding a "superuser" that will perform the migration, because that role has access to all the secrets).
