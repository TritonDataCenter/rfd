---
authors: Trent Mick <trent.mick@joyent.com>, Pedro Palaz—n Candel <pedro@joyent.com>
state: predraft
---

# RFD 82 Triton agents install and update

A.k.a. "agentsshar must die".

Currently the way agents (those services that run in the global zone of all
servers) get packaged and installed in Triton DataCenter is via a thing called
the "agentsshar". This is a [shar](https://en.wikipedia.org/wiki/Shar) package
that bundles all the global zone core agents (e.g. vm-agent, cn-agent, etc.).
It is built from the
[sdc-agents-installer](https://github.com/joyent/sdc-agents-installer) and
included in the USB key used for datacenter install.

- Initial headnode (HN) setup runs this shar, initiated by the
  [headnode.sh](XXX) script.
- Compute node (CN) setup -- initiated by the CNAPI [server-setup.js](XXX) job
  calling the [agentsetup.sh](XXX) script -- downloads this shar (from the
  assets zone) and runs it.
- For *updates* to newer agents, the operator uses `sdcadm experimental
  update-agents` which pulls down the latest agentsshar from updates.joyent.com,
  saves it for use in later CN setup, and runs it on every server in the DC.

There are a number of problems here that we want to improve:

- If you want to upgrade just a single agent, updating with the agentsshar
  will reinstall (and hence restart) every agent on all servers. That's a pain.
  Nevermind that reinstalling every agents takes longer than one would like
  (hence longer DC maint period). The current hack is to manually edit an
  agentsshar (the shar format is just plain text) to remove those agents one
  doesn't want to install. *That* is not a process that belongs in a good
  upgrade system.

- Sometimes upgrading all agents is fine, *expect* the "marlin-agent", which is
  a part of Manta. HUP'ing the marlin-agent can have adverse effects on Manta.
  That leads to a common procedure being to manually edit the shar to exclude
  the marlin-agent (see the previous point).

- Because we avoid installing with a full agentsshar, in practice for some DCs,
  we end up never properly doing the "saves it for use in later CN setup" part
  above. This means that subsequent CN setup might not correctly get the
  latest agents.

- Current handling for what agent instances (i.e. what agent version/image UUID)
  are installed is poor. See [Tracking agent instances](#tracking-agent-instances) below
  for details.


## Current Status

`sdcadm experimental update ...` supports updating all and individual agents
using their individual images from updates.joyent.com and Pedro has been using
this for a long while for daily us-east-3b updates. (Pedro will remind me the
ticket for this work.) This handles case 3 above, and it isn't "blessed" as
the suggested way for operators to updates agents yet. To handle cases 1 and 2,
and to get to where we can bless 3, we need to do some more work.

Defining that work is ongoing. Read on.



## Tracking agent instances

To manage agents in the DC, the upgrade tooling needs to know what versions
are installed where. Currently this info is in CNAPI -- in the `agents` property
of each CNAPI `server` object.

Some (not enough) info about installed agents is in `sysinfo` on each CN, and
hence (assuming adequate sysinfo-refresh) in the `server.sysinfo` record in
CNAPI. For example:

    "SDC Agents": [
      {
        "name": "config-agent",
        "version": "1.5.0"
      },
      {
        "name": "firewaller",
        "version": "1.3.2"
      },
      ...

*Independently* there is a `server.agents` property that is stored in CNAPI
and updated explicitly by the cn-agent `agent_install` task (added for
individual agent install support). For example:

    "agents": [
      {
        "name": "cn-agent",
        "version": "1.5.4",
        "image_uuid": "fd5f189c-c26a-46a6-bd1a-b0e0150edf8f",
        "uuid": "04a3fd8b-da16-4f8d-a003-06dc52f0a1e3"
      },
      {
        "name": "hagfish-watcher",
        "version": "1.0.0-master-20160527T165825Z-g020d169",
        "image_uuid": "bac59322-fd11-4dcc-87de-6fd6bcd52f0e",
        "uuid": "3259e87b-2c87-4a97-9061-49c3008fe84a"
      },
    ...

That `image_uuid` is the agent image build identifier (in the DC's IMGAPI
and updates.joyent.com), and `uuid` is the instance identifier, also in
SAPI:

    [root@headnode (nightly-2) ~]# sdc-sapi /instances/04a3fd8b-da16-4f8d-a003-06dc52f0a1e3 | json -H
    {
      "uuid": "04a3fd8b-da16-4f8d-a003-06dc52f0a1e3",
      "service_uuid": "2e52bcfe-c61e-482f-a072-f3c79018a3db",
      "type": "agent"
    }
    [root@headnode (nightly-2) ~]# sdc-sapi /services/2e52bcfe-c61e-482f-a072-f3c79018a3db | json -Ha name
    cn-agent

Some issues with using CNAPI to store this info:

- There is split brain within CNAPI server records themselves between
  `server.agents` and `server.sysinfo['SDC Agents']`: one can get updated
  without the other being updated.
- We also track (some of) the agent instance info in SAPI -- just like we do
  for VM instances.

Proposal: Deprecate CNAPI's `server.agents` and move to tracking agent instance
data fully in SAPI. This will mean that the agent update process needs to
keep SAPI agent instances up to date -- no different than for VM instance
updates. In fact that should happen directly by using SAPI to *initiate*
agent updates -- again, as is done for VM instance updates.

A side-benefit of this change would be that tooling that wants to work with
core instances, like `sdcadm insts`, can go to one place: SAPI. Currently
`sdcadm insts` hits SAPI for VM instances and CNAPI for agent instances.


## Trent's quick scatch notes on work to be done

This should be cleaned up, discussed, agreed upon, and ticketed.

TODOs related to getting agents updating more convenient in the short term:

- TOOLS ticket for 'sdcadm post-setup cmon' to create cmon-agent instances
  Link that to TOOLS-1631.
- TOOLS ticket for 'sdcadm create' support for agents
    - also possibly separate ticket for multiple-server support for 'sdcadm create'
  Link these to TOOLS-1631.
- consider ticket for 'sdcadm ex update-agents' to be able to skip the 'latest' linking
- consider ticket to update the latest link with an agentsshar without updating
  the agents.

Remaining work to drop agentsshar:

- headnode setup to use individual agents
- CN setup (agentsetup.sh) to use individual agents
- COAL/usb builds to ship with individual agents instead of the shar
- sdcadm process to get from agentsshar on the usbkey to individual agents
  on the key (for existing deployments).
- cn-agent agent_install should refresh sysinfo for that server
  TODO: verify that it is indeed NOT updating server.sysinfo after an
  individual agent install
- sysinfo-refresh shouldn't use a WF job. Is there a benefit to using WF
  for this? Perhaps queueing when refreshing for every server in the DC?
  sysinfo-refresh's for unsetup CNs can clog up WF (at least its history
  of jobs), FWIW. Arguably this is off-topic for this RFD.
- See the "deprecate CNAPI server.agents and use SAPI" discussion.
- Does SAPI ListInstances support paging? It'll need to.
- SAPI CreateInstance and DeleteInstance should work for agent instances.
