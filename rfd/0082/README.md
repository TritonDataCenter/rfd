---
authors: Trent Mick <trent.mick@joyent.com>, Pedro Palazón Candel <pedro@joyent.com>
state: draft
---

# RFD 82 Triton agents install and update

A.k.a. "agentsshar must die" and more.

Currently the way most agents (those services that get install and run in the
global zone of all servers) get packaged and installed in Triton DataCenter is
via a thing called the "agentsshar". This is a
[shar](https://en.wikipedia.org/wiki/Shar) package that bundles all the global
zone core agents (e.g. vm-agent, cn-agent, etc.). It is built from the
[sdc-agents-installer](https://github.com/joyent/sdc-agents-installer) and
included in the USB key used for datacenter install.

1. Initial headnode (HN) setup runs this shar, initiated by the
   [headnode.sh](https://github.com/joyent/sdc-headnode/blob/master/scripts/headnode.sh) script.
2. Compute node (CN) setup -- initiated by the CNAPI [server-setup.js](https://github.com/joyent/sdc-cnapi/blob/master/lib/workflows/server-setup.js) job
   calling the [agentsetup.sh](https://github.com/joyent/sdc-headnode/blob/master/scripts/agentsetup.sh) script -- downloads this shar (from the
   assets zone) and runs it.
3. For *updates* to newer agents, the operator uses `sdcadm experimental
   update-agents` which pulls down the latest agentsshar from updates.joyent.com,
   saves it for use in later CN setup, and runs it on every server in the DC.

There are a number of problems here that we want to improve:

- If you want to upgrade just a single agent, updating with the agentsshar
  will reinstall (and hence restart) every agent on all servers. That's a pain.
  Nevermind that reinstalling every agent takes longer than one would like
  (hence longer DC maint period). The current hack is to manually edit an
  agentsshar (the shar format is just plain text) to remove those agents one
  doesn't want to install. *That* is not a process that belongs in a good
  upgrade system.

- Sometimes upgrading all agents is fine, *except* the "marlin-agent", which is
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

- There's no "blessed" procedure for removing a Server or factory reset it
  other than calling the related CNAPI HTTP end-points. None of these calls
  takes care of removing agent instances from SAPI, leading to agent instances
  remaining into SAPI forever, despite of the server being removed or, what it's
  worse, exceptions for those instances when the server factory reset is used.

- SAPI design ignores that instances are created in servers: currently, there's
  no way to perform a proper search for instances of any type being on a given
  server other than performing a search for **every** instance existing in SAPI
  and then loop over the results to check which of these instances have a
  `server_uuid` value which matches with the server we are interested into.
  The same happen when we're trying to verify that all the instances of a
  given VM/agent are using the same image_uuid, but in this case we can, at least,
  scope our search by service UUID. It would be desirable to add the required
  indexes and provide instance searches for these cases.

There are other issues that might expand the scope of this RFD:

- We would like to have a way to track installed versions of "dockerlogger",
  "gz-tools", "sdcadm", and possibly other core components installed to the
  GZ. Currently how that is done issues different for all three of these
  examples. The definition of what constitues an "agent" is overloaded:
  Currently "dockerlogger" is a type=agent service in SAPI. However it does not
  install to "/opt/smartdc/agents/..." nor does it run an SMF service (ignoring
  its transient setup service). It would be helpful if this RFD's work could
  also clean up this situation.

## Current Status

As of [TOOLS-563](https://smartos.org/bugview/TOOLS-563) `sdcadm experimental
update ...` supports updating all and individual agents using their individual
images from updates.joyent.com and Pedro has been using this for a long while
for daily us-east-3b updates. This handles case 3 above, and it isn't "blessed"
as the suggested way for operators to updates agents yet. To handle cases 1 and
2, and to get to where we can bless 3, we need to do some more work.

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


### dockerlogger

Currently "dockerlogger" is an odd duck: It is a 'type=agent' service in
SAPI. However it is *not* listed in `sysinfo["SDC Agents"]`, nor is it in
CNAPI server.agents. `sdcadm` uses *SAPI* instances to track on which servers
dockerlogger is installed. However, that object doesn't track the image
or version:

    {
      "uuid": "ad917a62-b587-4b3b-8271-b11d578e4acd",
      "service_uuid": "f206da7d-1928-4800-9dc0-34a6178a2c37",
      "params": {
        "server_uuid": "00000000-0000-0000-0000-002590918ccc"
      },
      "type": "agent"
    }

As well, reality could diverge and SAPI wouldn't know. As a result `sdcadm`
has no way to know what particular version of dockerlogger is installed on
which server. It falls back to a hopeful cheat: it assumes every install is
the image marked on the "dockerlogger" SAPI *service*:

    {
      "uuid": "f206da7d-1928-4800-9dc0-34a6178a2c37",
      "name": "dockerlogger",
      "application_uuid": "26cc7f2b-77ed-427f-8f09-d43d32a7331b",
      "params": {
        "image_uuid": "7630d856-f1fa-4481-ba1e-bb730a7c201f"
      },
      "type": "agent"
    }


### gz-tools

Currently the "gz-tools" component is also an odd duck. It doesn't exist in
SAPI as a service. It *does* record its image via writing a file at install
time:

    [root@headnode (nightly-1) ~]# cat /opt/smartdc/etc/gz-tools.image
    1b8527ec-e52c-4694-836b-0667330970f3

That info is not reflected in CNAPI at all, so `sdcadm` isn't able to know
which versions are installed on which servers.


## Proposal

This section proposes a design for tracking core component instances. Primarily
it is about improving the story for non-VM components, but the design touches
on VM components as well.

1. Deprecate `sysinfo['SDC Agents']`. Currently it doesn't contain sufficient
   fields to be useful (missing `image_uuid` and instance `uuid`). The code to
   update it (and hence to change its schema to consider adding those fields)
   is in the platform. We don't want to rely on a newer minimum platform to
   support changes in agent tracking.

2. Continue to use CNAPI server.agents as the API cache of what agents instances
   exist. Clarify and improve how 'server.agents' is kept up to date. Currently
   it is only updated as part of cn-agent's agent update process. The intent
   here is to mirror how VMAPI's list of VMs is the API cache of what core VM
   instances exist.

3. Use SAPI instances to track *intent* of which agent instances should exist,
   and use SAPI `*Instance` endpoints to control install and upgrade of agents.
   Again, this is meant to mirror how core *VM* instances are managed via
   SAPI (which, granted, isn't rigorous currently).

4. Provide a mechanism to clear all the agent instances associated with a
   server from SAPI when the server is deleted.

5. Expand the definition of CNAPI server.agents to include more than just those
   components under "/opt/smartdc/agents" -- "dockerlogger", "gz-tools",
   etc.

Point #3 is the hardest, and possibly controversial. There is possibly a debate
over whether (a) SAPI should be an independent authority for what core instances
should exist, or whether (b) the current state (provisioned VMs, installed
agents) should be the authority. Manta is firmly an (a). IIUC, SAPI was designed
for Manta for this and for config management (via config-agent).

Triton current state is undecided or ill-defined between (a) and (b). There is
some effort to get all instances into SAPI after bootstrapping headnode setup,
and SAPI's CreateInstance is used for subsequent provisions of core VMs.
However, there isn't an 'assets' SAPI service, for example. Other differences
between bootstrapped SAPI instances and actual provisioned VMs is often referred
to as the SAPI "split-brain". *Agent* instances currently work the opposite way:
we install an agent, e.g. vm-agent, and it "adopts" itself into SAPI. Generally
it feels like Triton's usage of SAPI has always primarily been just enough to
get config-agent to work. Using it as a record of intent for deployed instances
is at best half-hearted.

I'll attempt to propose a path moving Triton agent instances to style (a) and
possibly VM instances more towards style (a) as well. As part of that we can
debate the merits in any changes.

A benefit of a future where we can rely on SAPI instance data for Triton would
be that tooling that wants to work with core instances, like `sdcadm insts`, can
go to one place: SAPI. Currently `sdcadm insts` hits SAPI for VM instances and
CNAPI for agent instances (with the subtle exception of 'dockerlogger', which is
a SAPI type=agent but isn't in sysinfo "SDC Agents" or in CNAPI server.agents).


## M1: Short term more convenient agents updating

Here are a number of quicker conveniences we can implement for operators
to handle agent updates, which are a common sore point in Triton updates.

- [TOOLS-1648](https://smartos.org/bugview/TOOLS-1648): 'sdcadm post-setup cmon' should create cmon-agent instances
  This will enable TOOLS-1631 for 'cmon-agent'. *Done*.
- [TOOLS-1651](https://smartos.org/bugview/TOOLS-1651): 'sdcadm create should support agent instances'. *Done*.
- [TOOLS-1770](https://smartos.org/bugview/TOOLS-1770): for multiple-server support for 'sdcadm create'. *Done*.
- [TOOLS-1771](https://smartos.org/bugview/TOOLS-1771): Add "--skip-latest-symlink" option to `sdcadm experimental update-agents`. *Done*. 
- [TOOLS-1772](https://smartos.org/bugview/TOOLS-1772): Add "--just-update-symlink" option to `sdcadm experimental update-agents`. *Done*.


## M2: Improved agent instance tracking

We should be able to clean up the agent instance tracking situation without
necessarily having to have fully moved off the agentsshar.

- CNAPI and/or cn-agent changes so that 'server.agents' is kept up to date, and
  it is clear how that is done. Also add a 'sdcadm check cnapi-server-agents'
  that can be used to check this and will provide steps for correcting it if
  wrong. (See below)
- Include `params.image_uuid` in all SAPI instances (since we can have more than one instance for a given service and
  these could be using different images). [SAPI-296](https://smartos.org/bugview/SAPI-296)
- Include `params.server_uuid` in all SAPI agent instances. [AGENT-1087](https://smartos.org/bugview/AGENT-1087)
- [SAPI-285](https://smartos.org/bugview/SAPI-285): 'Create Service should not validate presence of provide `image_uuid`
  into local IMGAPI'. *Done*.
- Update SAPI to index and provide search options for instances `image_uuid` and
  `server_uuid`. [SAPI-297](https://smartos.org/bugview/SAPI-297)
- SAPI `CreateInstance`, `UpgradeInstance` and `DeleteInstance` should work for agent
  instances. [TRITON-415](https://smartos.org/bugview/TRITON-415)
- Any call to CNAPI factory-reset or delete for a given server should remove
  every agent instance existing into that server from SAPI. [TRITON-416](https://smartos.org/bugview/TRITON-416)
  
### CNAPI server.agents

Server's installed agents will change only when we initially setup the server
or when we update them either using update-agents from agentsshar or individually.

- Changes associated with individual updates are already being published to CNAPI
  as part of the `update_agent` CN task.
- Changes associated with server setup are published to CNAPI by sdc-cn-agent itself
  on each boot of the agent itself.

It's pending to handle the update of information associated with agents when we
update them using the agentsshar, or when we detect that the agents information
on a given server is not correct b/c it lacks of some pieces.

Additionally, having a custom method/end-point dedicated to update this information
will make easier to include additional information about CN agents in the future.

The following issues are required:

- sdc-cn-agent: Create independent `refresh_agents` task [AGENT-1079](https://smartos.org/bugview/AGENT-1079). This will require
  some refactoring of current `update_agent` task, in order to do not enter code
  duplication. *Done*.
- sdc-cnapi: Create end-point to call refreshAgents task, which should return the taskId [CNAPI-727](https://smartos.org/bugview/CNAPI-727)
- sdcadm: Create `sdcadm check server-agents` subcommand, which should be able to go
  through the available information for the given server(s) - or all of them if nothing
  else has been specified - and provide feedback about the status of agents property fo
  these servers. [TRITON-413](https://smartos.org/bugview/TRITON-413)
  This subcommand should ensure all the existing agent services in SAPI have the required
  `image_uuid` information associated with the `service.params` member and, otherwise, suggest
  the user to run `sdcadm experimental update-other` which will add the missing `image_uuid` to
  every service where it's required.
- sdcadm: This `sdcadm check server-agents` subcommand could provide an option to fix
  any problems it may detect, waiting for interactive user input or just proceeding
  by itself if the usual `--yes` option is given. [TRITON-414](https://smartos.org/bugview/TRITON-414)
- Implementation note:
  Can use CNAPI client methods `getTask`, `waitTask` or `pollTask` in order to
  know about task completion and lookup again at server's agents using CNAPI's `getServer`.
  Note that while `waitTask` takes a timeout as argument and let the work to be done
  by CNAPI, `pollTask` didn't take such timeout, and the work is done by whatever
  is running the CNAPI client (sdcadm on this case).

### Individual agents install/update improvements

- It has been reported that sometimes installing/updating individual agents, the sdcadm process
  hangs, w/o reporting any progress or failure information. Most of those cases have been due
  to previous incorrect agents setup. For example, install processes hanging, packages not really
  updated ...
  While `sdcadm check server-agents` will be useful to detect these cases ahead any attempt of
  running agents updates, it would be desirable to provide better feedback during the installation
  process and, eventually, ensure we timeout such processes when all but a number of individual
  agents setup have finished within _acceptable time_ and we still have one or more instances
  hanging.
  **Average agent install/update time and users warning:** Given the default timeouts for agent
  install/update are huge (1 hour for the cn-agent task, for example), it would be desirable to
  collect the time that it takes for each server and, when waiting too long for a given server
  setup, we could warn the user that the install is taking way longer than the average time for
  other servers, which will possibly mean a failure for that particular instance.
- Similarly, we could definitely bump the number of agents updates we run in parallel from the
  current default of `5` to something bigger. Starting with `20` or so could be a good idea.
- Additionally, there's a pretty good idea worth investigating regarding trying to use the
  NodeJS `{exclusive: false}` option for HTTP servers when we start the different agent
  services and delegate to the agent setup process the initialization of the new, updated
  agent before we take the currently running instance down. If there aren't any drawbacks for
  this approach, this should mean no downtime for agents despite of the upgrade processes
  going on into the different CNs.
- **Parallel setup of some agents:** While it’s not possible to setup `cn-agent`, `config-agent` and
  `agents_core` in parallel, given these are used during the install/update of every agent instance,
  it would be possible to run parallel updates for the other agents, which should help speeding up
  the whole process, specially when there are several agents to be updated.
  (Note the same could be applied for stateless Triton VM services, but that's out of this RFD scope).
  
## M3: Accurate VM instance tracking in SAPI (bonus points)

This section is optional for this RFD.

- 'sdcadm check sapi-services sapi-instances' to help deal with out of sync
  SAPI service and instance data.
- 'sdcadm experimental update-other' steps to ensure have the 'assets' service.
  Note this is related to [RFD 67](../../0067/README.md) and should be implemented.
  *Done* [TOOLS-1963](https://smartos.org/bugview/TOOLS-1963).
- Update headnode setup to create the 'assets' service and other missing ones,
  if any. Note this is related to [RFD 67](../../0067/README.md) and should be
  implemented.
- Update 'sdcadm svcs' to no longer have the hack that manually adds the
  'assets' service.
- TODO: Is this the only consistent missing SAPI data from headnode install?

## M4: Dropping the agentsshar

The following quick notes should be cleaned up, discussed, agreed upon, and
ticketed:

- [AGENT-1053](https://smartos.org/bugview/AGENT-1053) cn-agent agent_install needs to support installation of a new agent.
  Done.

* * *

- COAL/usb builds to ship with individual agents instead of the shar
- headnode setup to use individual agents
    - TODO: Think about requirements for coordinating these two steps.
- CN setup (agentsetup.sh) to use individual agents
- sdcadm process to get from agentsshar on the usbkey to individual agents
  on the key (for existing deployments). Likely via 'sdcadm ex update-other'.
- cn-agent agent_install should refresh sysinfo for that server.
  TODO: *Is* it already refreshing sysinfo? Note that because we propose to
  deprecate `sysinfo['SDC Agents']`, we don't really need this change.
  DONE: It is already refreshing server sysinfo here: https://github.com/joyent/sdc-cn-agent/blob/master/lib/tasks/agent_install.js#L427-L437
  And, indeed, it's not using a WF job for it.
- sysinfo-refresh shouldn't use a WF job. Is there a benefit to using WF
  for this? Perhaps queueing when refreshing for every server in the DC?
  sysinfo-refresh's for unsetup CNs can clog up WF (at least its history
  of jobs), FWIW. Arguably this is off-topic for this RFD.
- Does SAPI ListInstances support paging? It'll need to.
  Answer: No, it does not support pagging. Indeed, it attempts to load
  every existing instance by looping on moray findObjects in batches of 1000.

## M5: gz-tools, dockerlogger and sdcadm

- Update 'sdcadm' installation to have an instance UUID.
- Headnode setup and 'sdcadm ex update-other' changes to add 'gz-tools' and
  'sdcadm' services.
- cn-agent changes so the 'dockerlogger', 'gz-tools', and 'sdcadm' instance
  UUID and image uuid are included in 'server.agents'.
- Having an 'sdcadm' service might surprise some parts of 'sdcadm up'.
  Ensure 'sdcadm up' skips 'sdcadm' and points to 'sdcadm self-update'
  appropriately. Ensure that 'sdcadm create sdcadm' doesn't work.
  (Related issue: TOOLS-1585)
- Updating 'gz-tools': Either get 'sdcadm ex update-gz-tools' to update the SAPI
  service and instances accordingly, or do the part from M4 for moving to using
  'sdcadm up' for updating gz-tools.
- Get a service for 'gz-tools' and instances, and move to using 'sdcadm up' for
  updating gz-tools. This will obsolete 'sdcadm experimental update-gz-tools'.


## Trent's scratch notes

Y'all can ignore this section.

- what it means to be an "agent" (per SAPI and sdcadm at least):
    - it is something that installs to the GZ on one or more servers in the DC
    - it *might* have an SMF service
    - it *might* be installed as a "apm"-managed agent (i.e. in
      /opt/smartdc/agents/...)

- Aside: This is CNAPI handling of server.agents is busted for edge case:
        if (!server.agents ||
            server.agents && Array.isArray(server.agents) &&
            server.agents.length === 0)
        {
            server.agents = server.agents || sysinfo['SDC Agents'];
        }
    Also, I don't think we want that fallback. The schema for 'SDC Agents' is
    the same for server.agents. We should enforce the latter having the
    'image' and 'instance' fields.

So the next idea is to have agent instance management be much like it is for
VMs. CreateInstance in SAPI will initiate installing that agent on the new
given server (called "deploy" using language in the SAPI docs for
CreateInstance). UpgradeInstance on SAPI will call CNAPI->cn-agent to update the
agent (pulling from imgapi).

During headnode setup we bootstrap in the initial VM instances while SAPI is
in 'proto' mode. We don't have the luxury for installation of agents on a
new CN during setup. So... how should this be driven. Currently "some process"
installs the agents and the agents' postinstall scripts "adopt" themselves
into SAPI. I wonder if that is a little backwards.

TODO: finish this line of thought
