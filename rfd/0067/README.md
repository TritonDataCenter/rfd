---
authors: Trent Mick <trent.mick@joyent.com>
state: predraft
---

# RFD 67: Triton headnode resilience

Some parts of Triton support HA deployments -- e.g. binder (which houses
zookeeper), manatee, and moray -- so that theoretically the service can survive
the loss of a single node. Triton ops best practice is to have 3 instances of
these services. However, the many other services that make up Triton either
don't support multiple instances for HA or operator docs and tooling isn't
provided to do so. That means that currently the loss of the headnode (e.g. loss
of the zpool) makes for bad day: recovery is not a documented process and
could entail data loss.

This RFD is about documenting and implementing/fixing a process for headnode
backup/recovery and resilience. The holy grail is support for fully redundant
headnodes, so that no single node is "special" -- but that is a large
project. We want someting workable sooner. This RFD will include earlier
milestones for more manual recovery processes.


TODO: more details coming, obviously


