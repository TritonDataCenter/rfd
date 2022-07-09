---
authors: Bryan Horstmann-Allen <bdha@joyent.com>
state: publish
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 <contributor>
-->

# RFD 132 Conch: Unified Rack Integration Process

## Note

This document describes the state of the art circa late 2016. This work was
delivered mid-2017 and has thus far helped shave 60d off our datacenter build
times. -- bdha, 2018-04-04

## Introduction

We've seen a fair amount of variability in our delivered racks, and as we
increase the number of vendors we have building them for us, that variance is
likely only going to increase.

When we stand up new datacenters, the racks are generally assembled off-site by
a third-party vendor: the hardware integrator. Depending on the region, we have
different vendors fulfilling this role, with different capabilities.

Once all the equipment is gathered in their facility, they construct the rack,
mount the devices, and cable things up.

Finally, they run through a burn-in and configuration process defined in the
contract's Statement of Work.

## The Problem

We need to expand datacenters rapidly. This requires cutting as much time off
the process as possible wherever we can.

The burn-in/config process varies by integrator. Some integrators already have
a method for, e.g., booting the rack, applying configuration we provide to
them, and then doing burn-in tests. Others have had to build those facilities
to order -- which tends to be very time-consuming.

Even when they already have these capabilities, however, they still vary in
complexity, robustness, and reporting vendor to vendor.

It would be ideal if we had *one* process which was vendor agnostic.

## What We Want

* Vendor-agnostic validation process
* No lead-time waiting for the vendor to build config/validation capabilities
* Live progress updates as racks are built and validated
* Automated inventory gathering
* Identify incorrect hardware as quickly as possible
* Automatic reports of dead devices as delivered by the vendors (% DOA)
* Comparison of shipped status vs. received status (% hardware killed in transit)

## Previous Art

We have built a network booted [preflight
service](https://github.com/TritonDataCenter/conch) that validates system inventory,
raising errors when we find the following:

* Incorrect network cabling
* Missing RAM
* Missing disks (leading to incorrectly built `zpools`)
* Bad DRAC cards
* Bad firmware versions
* Bad fans
* Incorrect BIOS configuration
* etc...

To date this service has been used in a post-integrator per-datacenter role,
but it can be expanded to run centrally, and contain data for all regions and
datacenters.

Importantly, the same software we use for the integration-phase validation can
be used post-delivery. We will get the delta of hardware that goes out of spec
due to packing and shipment.

### Current Workflow

Racks are built and shipped by the integrator. They provide us with inventory
in the form of text files. This inventory tends to come in different forms
depending on the vendor. The burn-in reports might be in PDFs or text files.

We can specify formats in the SOW, but if the vendor is not geared for that
process, we have to wait while they build it.

Once the rack is installed in the datacenter, we boot it into the preflight
environment and validate it. We verify the system has a correct configuration,
the expected hardware, etc. If something needs to be repaired, we create
breakfix tasks.

Once the system is validated, it's flipped to Triton.

### Proposed Workflow

Supply the integrators with devices that plug into the rack and act as
preflight relays. These devices will execute all the usual preflight checks,
collect all the data we need, walk the integrator staff through repairing
broken hardware, etc.

They'll also talk to a "public" API and push up their data, so we can see,
live, what the progress of each rack is. This is important as managing
timelines is currently very difficult. We don't really know when things are
going to ship until everything is ready. If we see, on a rack by rack basis,
when things are going to arrive at the DC, we can schedule work more
efficiently.

## Components

### Preflight "SaaS"

A version of preflight that is cross-region aware and accessible over the
Internet.

The following changes will need to be made to the existing codebase:

* API tokens bound to vendors working on specific builds
* Support for Preflight Relay Device registration and management
* Web interface updated to allow for multiple datacenters

### Preflight Relay Device

The PRD is a small embedded computer running custom software.

Documentation will be provided for setting up the device and using it.
Nominally actually using the web app (below) will be trivial, however.

It runs the following software:

#### Switch Configurator

An agent on the PRD will need to detect the switches via the serial console
cables and configure them. The following changes will be made:

* Set the switch hostname / location data (if netops requests this)
* Set up the Triton and Preflight VLANs on the proper ports
* Enable LLDP

#### An HTTP proxy

This proxy takes JSON blobs from the systems being validated and pushes them to
the Preflight SaaS via the wifi interface.

#### PXE Services

Our standard DHCP/TFTP setup for PXE booting servers into Preflight and running
the validation agent.

#### Web app

A management app will need to be written so the integrator can do data entry
for the rack being tested, view status, and review a simple "problems" page for
breakfix.

#### SSH Reverse Tunnel

When the devices come up, they should open a tunnel to a support zone. If we
have a problem with a device, or with a server being validated, this tunnel
gives us remote access into the environment to perform a diagnosis.

### Site Requirements and Limitations

#### DHCP Set on BMC

All BMC/DRACs must be configured to DHCP. If they are not, the integrator will
need to go into the BIOS and set them. Otherwise we will not be able to change
the system boot order to PXE it, update BIOS/firmware, etc.

#### Network Access

One major goal is getting telemetry data before the racks arrive at the data
center is so Joyent can be proactive rather than reactive. Network access is
the biggest limitation. We'll need to ensure the integrator can supply a wifi
network with Internet access for the devices.

#### SSH Reverse Tunnel Auth

Each PRD will need to generate a new SSH key on first boot. This key will need
to be put onto the support zone before the device can connect. We'll also need
some way of identifying each device to the reverse port -- presumably this can
be pushed up to Preflight SaaS as part of registration.

#### Device Per Rack

We need to plug directly into the serial console on each Top of Rack switch to
configure it. (There are ways around this, but they require wiring racks
together, knowing serial numbers of switches, etc.) 

Using a device per rack incurs the following limitations:

* We can only validate one rack at a time per device
* 24 hour burn-in (72 would be better) means a given device is locked up for n hours while burn-in runs

We need to know how many racks the integrator will be building in parallel so
we can supply the correct number of devices.

### Process

#### Step 0: Prep

Joyent Cloud Deployment, manual

* Imports the rack map from DCOPS into the Preflight SaaS DB
* Creates an API token for the integrator to use for this build
* Ships the devices to the integrator

#### Step 1: Rack Build

Integrator, manual

* Builds rack
* Racks servers and switches
* Cables servers and switches
* Applies power to rack
* Ensures status lights are good
* Ensures network has link lights
* Tags the rack name based off the DCOPS rack map

#### Step 2: Preflight Relay Device Install

Integrator, manual

* Plugs Preflight Appliance into ethernet port X on TOR #1
* Plugs Preflight Appliance into serial management ports on the TORs
* Plugs laptop into (management side) port X on TOR #1, is given a DHCP IP
* Browses to http://192.168.1.1
* Selects the local wireless network to use for Internet access
* A report page shows current Preflight status
* Enters the API token
 * The device polls Preflight SaaS for rack information
* User selects current rack from dropdown
* The rack type displays an empty rack map
 * The map displayed should be identical to what is installed in the rack
* Enters the server serial numbers into the rack map
* As devices are detected, they are automatically run through preflight

#### Step 3: Preflight Validation

Automatic

* PRD registers itself with Preflight SaaS
* Configures switches
* Verifies switches are healthy
* Verifies all expected BMC/DRACs have DHCP'd
* Pushes firmware upates for BIOS, BMC/DRACs
* Pushes configuration to BMC/DRACs
* Sets boot order
* Boots systems via PXE
* Preflight runs
* Surfaces validation status via PRD web UI

#### Step 4: Breakfix

Integrator, manual

* Reviews problems in web UI
* Performs breakfix as requires
* Waits for board to go green
* Marks the rack completed
* Shuts down the rack
* Ships the rack
* Moves PRD to next rack
* Back to Step 1

#### Step 5: Build Complete

* Integrator ships PRDs back to Joyent
* PRDs are reset to "factory", removing the API tokens and any local state

#### Step 6: Rack Installed in Datacenter

* Rack gets installed in the target DC by DCOPS
* Boots into preflight and is revalidated
* Reports available to show any variance in the pre-shipment and delivered state

