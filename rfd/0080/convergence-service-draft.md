---
authors: Casey Bisson <casey.bisson@joyent.com>, Jason Pincin <jason.pincin@joyent.com>
state: predraft
---

# RFD 80 projectsConvergence implementation

The Mariposa (RFD36) convergence service will be responsible for insuring service goal state is met. It accomplishes this by polling the service and project APIs, the VM API, and by monitoring Changefeed. When a divergence between goal state and actual state is detected, the convergence service will interact with VM API to resolve the discrepancy. 

Note: Direct interaction here means that limits and other controls set for CloudAPI will not be applied to this service. Potential inconsistencies with this approach should be given consideration.

## Goal state

Goal state is obtained by reading the Mariposa Project service API. Changes to goal state will be detected by the Convergence service via Changefeed (assuming the service API can leverage Changefeed for publishing changes), and by polling the Mariposa service API. Although propagation of changes via Changefeed will be faster, polling remains important because by it's nature, Changefeed is not 100% reliable. 

## Actual state

The Convergence service will maintain data structures that represent the actual state. VMAPI Changefeed events will be monitored for changed in the VMs that the Convergence API is responsible for. Just as with goal state, the VM API will also be polled to protect against missed Changefeed events. The Convergence service will ignore events for VMs it did not create. 

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

## Optics / Endpoints

The Convergence service will expose it's status and other pertinent information via a restful API, traversable by service/project/customer ID.

All below endpoints may be prefixed with `/users/$userId` to access data for a user other than the one you're authenticated as, assuming authorization is granted. For example:

`GET /users/abc123/state` will return the same data as a request to `/state` would if you were authenticated as `abc123`. 

### /state

Endpoint operations:

* GET - Get state information for all user projects including project summary, service names/IDs, running count, goal count, how many are being stopped/started, etc. This list can be filtered by passing `project` or `service` GET params with ID values.
