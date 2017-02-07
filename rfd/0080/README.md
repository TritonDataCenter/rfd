---
authors: Casey Bisson <casey.bisson@joyent.com>, Jason Pincin <jason.pincin@joyent.com>
state: predraft
---

# RFD 80 ProjectsConvergence API implementation

The Mariposa (RFD36) convergence service will be responsible for insuring service goal state is met. It accomplishes this by polling the service and project APIs, the VMAPI, CNAPI, and by monitoring Changefeed. When a divergence between goal state and actual state is detected, the convergence service will interact with VMAPI and CNAPI to resolve the discrepancy. 

The tasks invoked to meet goal state will be managed via an internal task queue which is exposed via the service API. 

Note: Direct interaction here means that limits and other controls set for CloudAPI will not be applied to this service. Potential inconsistencies with this approach should be given consideration.

## Goal state

Goal state is obtained by reading the Mariposa Project service API. The Convergence service will be notified of goal state changes directly by the Project service, and the Convergence service will in turn update itself by re-reading the Project service.

## Actual state

The Convergence service will maintain data structures that represent the actual state. VMAPI Changefeed events will be monitored for changed in the VMs that the Convergence API is responsible for. Just as with goal state, the VMAPI and CNAPI will also be polled to protect against missed Changefeed events. The Convergence service will ignore events for VMs it did not create.

## State convergence

Any time there is a divergence between goal state and actual state, the Convergence service has work to do in order to bring the two states back into alignment. At a high level, the paths are:

### Configuration has changed

The Convergence service will interact with VM API to re-deploy all service containers in a rolling manner. 

### Goal has scaled up

The Convergence service will interact with VM API to deploy additional containers until the new scale has been met.

### Goal has scaled down

The Convergence service will interact with VM API to remove service containers until the number of running containers matches the new scale.

### Container has failed

The Convergence service will interact with VM API to reap the failed container(s), while deploying additional container(s) until the goal scale is met. There will need to be some throttling and intelligent backing off here to prevent thrashing in the event newly deployed containers fail for the same reason existing ones are failing.

### Service has been removed

The Convergence service will remove all running service containers.

## Task queue

The Convergence service will maintain a queue of all active/pending tasks (starting a service, stopping a service, etc), and will expose this information via it's API. It will be possible to cancel these tasks, indirectly, through freeze/unfreeze actions at the project level by a user, or at the service level internally. Mariposa will need to properly clean up after a cancelled task.

## Availability

The Convergence service will need to be horizontally scalable and fault tolerant. Thought needs to be invested into the best approach to presenting a distributed task queue as a single queue, and how to coordinate which convergence process is handling each task. 

## Optics / Endpoints

The Convergence service will expose it's status and other pertinent information via a restful API, traversable by service/project/customer ID.

All below endpoints may be prefixed with `/users/$userId` to access data for a user other than the one you're authenticated as, assuming authorization is granted. For example:

`GET /v1/users/abc123/state` will return the same data as a request to `/v1/state` would if you were authenticated as `abc123`. 

### /v1/state

Endpoint operations:

* GET - Get state information for all user projects including project summary, service names/IDs, running count, goal count, how many are being stopped/started, frozen status, etc. This list can be filtered by passing `project` or `service` GET params with ID values.

### /v1/queue

Endpoint operations:

* GET - List of queued tasks (`start`, `stop`, `scale`, `reprovision`) containing service/project, state, component, and ID for each task. 

### /v1/queue/$taskId

* GET - Detailed information for the given task ID, containing data in list, and potentially additional data.
* DELETE - Terminate the task and clean up the potential mess left behind by doing this.