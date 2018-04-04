---
authors: sungo <sungo@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+136%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 <contributor>
-->

# RFD 136 Conch: Orchestration

## Introduction

Conch needs a centralized system for controlling various processes inside the
Conch environment, ranging from centralized management of production datacenter
inventory validation to localized management of Conch relays and livesys images
inside an integration facility.

In the most general terms, the orchestration system should be a purpose-built
workflow engine. It must provide a way to specify policies, focused on build
operations, that determine the order of operations for the Conch relay and
livesys applications. The validation system ([RFD 133](../0133/README.md))
must be used to determine if those policies have completed successfully.

The user interface, whether HTML or CLI, is *not* described in this RFD and will
be specified at a later point.

## Concepts

### Automation

Automation is the execution of individual tasks, with the goal of simplifying or
standardizing tasks that were often run manually previously.

### Workflow

A workflow is a set of pre-defined automations launched by a trigger condition.
In the most general case, steps in a workflow may be optional or required and it
is usually possible to nest workflows.

### Workflow Engine

A workflow engine is a system that evaluates trigger conditions, trigger
individual workflows, and processes the results. Usually workflow engines are
purpose-built for the needs of a specific application.

### Orchestration

Orchestration is concerned with bringing workflows together into processes or
policies, with the goal of streamlining and reusing those processes. Automation
provides the building blocks upon which orchestration processes are built.

## Design

### Workflows

Orchestration operations are tied to a 'workflow', which itself is tied to a
hardware product. Every device is keyed to a hardware product, as well. This
combination allows for workflow steps and validations to be linked to specific
hardware revisions.

This is particularly useful when a newer version of a server design varies
wildly from an older one. Both systems can be built and validated because their
workflow, and the validations necessary to green-light the device, are tied to
the hardware product specification.

### Workflow Steps

Workflow steps are an ordered list of string names and validations. The string
names are opaque to the orchestration system but signal different operations to
the downstream clients.

### Status

Two types of status exist, one for the execution of an entire workflow, and
another for the execution of an individual step.

#### Workflow Status

Workflow status records the state of the execution of an entire workflow for a
specific device. Most of the time, a device's workflow will either be "ongoing"
or "completed". However, special circumstances may arise with a need to
interrupt that flow.

If an external entity (probably a human) determines that a workflow must be
stopped, the workflow status for that device will be set to 'abort'. The engine
cannot reach out to client devices and forcibly halt execution so 'abort'
indicates that workflow must cease when the current step finishes. When the
device completes its current step, the workflow status for the device will be
set to 'stopped'.

Similarly, an external entity may determine that the extraordinary circumstances
have passed and a workflow may continue from a previously aborted state. In this
case, the workflow status for that device will be set to 'resume'. When the
device resumes work, the workflow status for that device will be set to
'ongoing'.

#### Workflow Step Status

Workflow step status records the state of a particular workflow step for a
particular device. From a client perspective, they are write-once. However, a
status record must also contain the results of the appropriate validation. As
such, the backend must be able to update an existing status record.

When a workflow status is received with a status of 'complete' *and* 'data' is
present, the validation subsystem will be called, using the validation plan id.
The validation system call will be passed the relevant device id, hardware
product id, validation plan id, and the data from the workflow status. The
result will be written back into workflow status record, indicating pass/fail
status and a link to the full validation result.

By default, if validation fails for a workflow step, the client will receive a
failure indicator when requesting its next step. If 'retry' is set on the
workflow step, the client will be told to run that step again. Any retry-able
step must also set a maximum amount of retries. Clients will not be allowed to
proceed further once that maximum has been reached.

It is possible for the validation system to fail internally, providing neither a
fail nor success indicator. When this occurs, step retries must not happen and
the step must be marked as failed. It should be possible to re-execute the
validations of a step in this state, as long as the failed step is the most
recent one. When a revalidation occurs, a new status record must be written
containing the new validation result.

## Schema

### workflow

| column      | type   | modifiers |
| ---         | ---    | ---       |
| id          | uuid   | not null, pk |
| name        | string | not null, unique |
| version     | int    | not null, default 1, unique(name,version) |
| created     | ts     | not null, default now |
| hardware_id | uuid   | not null, fk hardware_product(id) |


### workflow_status

enum workflow_status_enum:
* ongoing
* stopped
* abort
* resume
* completed

| column        | type   | modifiers |
| ---           | ---    | ---       |
| id            | uuid   | pk |
| workflow_id   | uuid   | fk workflow(id) |
| device_id     | uuid   | fk device(id) |
| timestamp     | tz     | not null, default now |
| status        | workflow_status_enum | not null, default ongoing|


### workflow_step

| column        | type   | modifiers |
| ---           | ---    | ---       |
| id            | uuid   | not null, pk |
| workflow_id   | uuid   | not null, fk workflow(id) |
| name          | string | not null, unique(name, workflow_id) |
| order         | int    | not null, unique(workflow_id, order) |
| retry         | bool   | default false |
| max_retries   | int    | not null, default 0 |
| validation_plan_id | uuid   | not null, fk validation_plan(id) |

### workflow_step_status

enum workflow_step_state_enum:
* started
* processing
* complete

enum validation_status_enum:
* pass
* fail
* error
* noop (not run)

| column               | type   | modifiers |
| ---                  | ---    | ---       |
| id                   | uuid   | not null, pk |
| device_id            | string | not null, fk device(id) |
| workflow_step_id     | uuid   | not null, fk workflow_step(id) |
| timestamp            | ts     | not null, default now |
| state                | workflow_step_state_enum | not null, default(started) |
| retry_count          | int    | not null, default 1 |
| data                 | jsonb  | |
| validation_status    | validation_status_enum | default(noop) |
| validation_result_id | uuid   | fk validation_result(id) |


## Implementation

The orchestration API will exist within the existing Conch Mojo API codebase and
feature an independant user interface. A standalone CLI will be developed in Go.

### Auth

#### Authentication

The API will be divided into two segments, isolating authentication concerns.
For endpoints used by automation, authentication will occur via HTTP Signatures,
utilizing RSA keys generated and managed by a CLI tool. Users must be allowed
multiple RSA keys and it should be possible to bake an RSA key into the
orchestration CLI.

API endpoints used by user interfaces will use the same authentication as the
conch API server.

#### Authorization

Authorization will be managed by the existing concept of roles within the Conch
database. For automated clients, permissions will be based on roles within the
GLOBAL workspace. For human clients, permissions will be split. Administrators
in the GLOBAL workspace will be able to see all workflows, workflow statuses,
and devices.  Otherwise, the user will see items based on the device list for
their particular workspace.

Only Administrators in the GLOBAL zone can created or modify workflows.


## Project Management

This work will be managed in LiquidPlanner in the [Conch SaaS
Project](https://app.liquidplanner.com/space/174715/projects/show/36216545).

## Related Work

* [RFD 132 Conch: Unified Rack Integration Process)](../rfd/0132/README.md)
* [RFD 133 Conch: Improved Device Validation](./rfd/0133/README.md)
* [RFD 134 Conch: User Access Control](../rfd/0134/README.md)
* [RFD 135 Conch: Job Queue and Real-Time Notifications](./rfd/0135/README.md)
