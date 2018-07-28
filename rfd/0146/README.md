---
authors: Bryan Horstmann-Allen <bdha@joyent.com>
state: predraft
---

<!--
    this source code form is subject to the terms of the mozilla public
    license, v. 2.0. if a copy of the mpl was not distributed with this
    file, you can obtain one at http://mozilla.org/mpl/2.0/.
-->

<!--
    copyright 2018 joyent, inc.
-->

# RFD 146 Conch: Inventory System

**This document is very WIP.**

## Problem

Conch currently provides physical tracking of switches and servers in racks,
but does not have features commonly found in asset management systems.

There are off-the-shelf solutions for inventory tracking and computerized
maintenance management systems (CMMS), but they cannot leverage the data we
already gather -- and integrating with them can be non-trivial if our data
models do not align.

As we go along we will likely pull more features from standard [CMMS
practices](http://www.plant-maintenance.com/articles/CMMS_systems.shtml) but
the initial design here should be moderately simple.

## Goals

We want to automate as much of asset and inventory tracking as we possibly can.
We do not want humans doing a bunch of manual data entry work when we can
gather all of that information from the systems we have deployed.

We want the ability to track every component in every device in each
datacenter, throughout the course of its life.

We want the ability to design new device BOMs from the component inventory
database.

We want the ability to manage spares and defective inventory.

As much as possible, inventory information should be automatically updated via
Conch reports.

A primary objective is to provide primitives so other applications can consume
the asset system and build atop it -- for instance, a rack or datacenter
designer app to identify assets that can be used, and to define resulting
assets which might account for cable lengths based on the design.

These applications built around the asset system should allow to create
reliable BOMs for RFQs and POs. Components/parts need the ability to define
requirements about themselves, so we do not forget to order needed related
hardware, etc.

## Development Phases

Feature development is broken up into phases.

Phase 1 is required for initial delivery.

Other phases may be noted, but are not required for the first revision.

(TODO)

## User Stories (Basic)

* "How many servers are deployed in all regions?"
* "How many switches are in us-east-1?"
* "How many hard drives of x type are in eu-central-1?"
* "How many DIMMs of brand y have failed in the last year?"
* "I want to design a server, and have a JSON specification I can use Conch to validate against"
* "I want to design a rack, and be sure that the resulting BOM has accurate cable lengths"
* "I want to design a datacenter and I want to be sure that based on rack BOM metadata's power footprints I am not exceeding my power budget"
* "What tools are required to work on server class y?"
* "Who is our vendor contact for product z?"

## Example Inventory System Consumers

The inventory system must catalog every component in every device we deploy.
Partially this is so we can track things, perform inventory and audits,
generate RFQs, but also so we can build applications on top of the inventory
catalog. These applications would be domain specific, but all deal with
specific parts of managing the physical world of the datacenter.

### Parts Manager

### Server Designer

As DCOPS, CloudOps, or a customer, I want the ability to design server classes.

Each server chassis in the system has metadata associated with it, defining how
many CPUs, DIMM slots, disks, PCI slots, PSUs, etc, it contains. It also has a
list of the type of hardware it can allow -- PCIe/PCIx, 2.5" vs 3.5" disks, and
so forth. These constraints ensure that the system design is viable.

The designer leverages these component attributes. As the user builds selects
components, the application would keep monitor the power budget for the system
based on the selected PSUs.

Once the design is complete and validated, the entire BOM would be stored back
in the inventory system as an available asset. Other applications can then call
on this designed system for use.

### Rack Designer

#### Cable Lengths

### Datacenter Designer

## Resource Types

### Businesses

* Classification (supplier, manufacturer, client)
* Location
* Contact information

### Sites

A site is a building. It references a business, address, etc.

Sites contain rooms.

A room can contain an aisle/row and bins. When stock references a location, it
is this.

(In the case of e.g., realized assets -- servers, switches -- which are located
in a datacenter room and rack, we should decide how to reference Conch's
`device_location` table.)

### Parts

Parts may be consumable or field replaceable when installed in a given asset.

Parts can have the following criteria:

| Name          | Example                                     |
|---------------|---------------------------------------------|
| ID            | UUID                                        |
| SKU           |                                             |
| Mgr PN        | HUH721212AL42000                            |
| Description   | 12TB SAS 12Gb/s 7.2K RPM 128M 4kn SE (He12) |
| Vendor        | Ref: HGST                                   |
| Category      | Ref: Hard Drive (SAS)                       |
| Tools         | References to tools required                |
| Consumable    | Y/N                                         |

#### Part: Custom Fields

When a part is instantiated into stock, the following attributes are
automatically created for it:

| Name          | Type            | Extra |
|---------------|-----------------|-------|
| SKU           | Str             |       |
| ID            | UUID            |       |
| PN            | Ref: PN         |       |
| Serial Number | Str             |       |
| QR/barcode    |                 |       |
| Location      | Ref: Site (bin) |       |

Each attribute has a boolean "required" field.

### Part Categories

Part categories and management.

Examples:

* Hard Drive
* Processor
* Server Chassis
* Cable

A magical category called "tool" is specified by the system, and is referenced
by parts and assets so we can detail what tools are required to perform work on
that equipment.

#### Part Category: Custom Fields

Part categories can also include a list of user-defined attributes that gets
applied to a part using that category of part.

For instance, all hard drives will have the following attributes:

| Name            | Type | Extra |
|-----------------|------|-------|
| Capacity        | Int  | TB    |
| Speed           | Int  | RPM   |
| Connector       | Str  |       |
| Connector Speed | Int  | Gb/s  |

When a new "hard drive" type is created as a part, any type attributes are
created for that new part.

Each attribute has a boolean "required" field.

### Assets

Assets are a template, an equipment model comprised of a name and a list of
parts.

This may be things like server BOMs, which will consist of a dozen or so
high-level parts, or a "hard drive kit" that would contain the drive itself,
the required cables, and the referenced tools.

A rack BOM would consist of the follow asset types: rack, servers, switches,
PDUs, ...

#### Server Asset Example

An example server asset attributes:

| Key        | Type  | Example                          |
|------------|-------|----------------------------------|
| Name       | Str   | smci-2u-storage-256g-12-sas-12tb |
| Category   | Ref   | Storage Server                   |
| SKU        | Str   | 600-0033-001                     |
| Generation | Str   | Joyent-S12G5                     |

And its parts list, which are references to the parts database:

| Qty | PN                       | Descr                              |
|-----|--------------------------|------------------------------------|
| 1   | SSG-6049P-E1CR36LA-JI006 | SuperServer 4U chasis              |
| 2   | CD8067303592500          | Intel® Xeon® Gold 6132 Processor   |
| 2   | E10G42BTDA               | X520-DA2, dual 10GbE               |
| 8   | M393A4K40BB1-CRC         |       Samsung 32GB DDR4-2400 DIMMs |
| 35  | HUH721212AL42000         | 12TB SAS HDD                       |
| 1   | HUSMR3240ASS200          | 100GB SSD                          |
| 1   | DTSE9H/16GBZ             | 16GB USB HDD                       |
| 4   | CAB-SFP                  | 10gig DAC Twinax                   |
| 1   | CAT6B-blue               | CAT 6 (blue)                       |
| 1   | PBL-10A-red              | Power cord C13/C14                 |
| 1   | PBL-10A-black            | Power cord C13/C14                 |

etc...

There is some complexity here: Depending on where the server is located in the
rack, it will require different cable lengths. So we need to be able to say
"this asset requires x qty of this part *category*" and when we actually turn
that server into stock -- or we use the Rack Designer to build a rack BOM, we
have to fulfill that requirement.

Tracking anything manually will lead to broken BOMs, however, so ideally cables
will have some magical properties that allow us to manage this.

#### Rack Asset Example

Name: Storage Rack v4

| Qty | PN                                | Descr                              |
|-----|-----------------------------------|-----------------------------|
| 18  | smci-2u-storage-256g-12-sas-12tb  | Storage Server              |
| 2   | DCS-7160-48YC6-R                  | TOR switch                  |
| 1   | WS-C2960X-24TS-LL                 | OOB switch                  |
| 2   | PDU-001                           | PDU                         |
| 1   | RACK-001                          | NetShelter SX 45U           | 

etc...

#### Asset: Custom Fields

### Asset Categories

* Server
* Hard Drive Kit
* Computer Rack
* Storage Rack
* ...

#### Asset Category: Custom Fields

### Stock

Stock of parts and assets we have on hand.

Stock is owned by a business, and has a location.

## Future Features

### Warranty management

### Maint management

### Stock rules

Examples:

Each location must have n stock of y type. If we fall below that threshold,
fire an exception.

### Stock history

### Associate files with stock

For auditing purposes, take pictures?

### Diagrams

Everything should have a picture or diagram. These can be referenced to help
perform work on the part/asset.

### RFQs

### POs

### Consumables/spares management
