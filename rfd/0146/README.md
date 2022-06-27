---
authors: Bryan Horstmann-Allen <bdha@joyent.com>, Chris Prather <chris.prather@joyent.com>
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
* "What tools are required to work on server class y?"
* "Who is our vendor contact for product z?"

## Example Inventory System Consumers

The inventory system must catalog every component in every device we deploy.
Partially this is so we can track things, perform inventory and audits,
generate RFQs, but also so we can build applications on top of the inventory
catalog. These applications would be domain specific, but all deal with
specific parts of managing the physical world of the datacenter.

### Parts Manager

As DCOPS, CloudOps, Finance, or a customer, I want the ability to manage all
parts in the datacenter. This includes adding all information about the part,
vendor information, potentially pricing information, custom internal SKUs, and
so forth.

I want reporting interfaces to identify what our stock is for a given part
(wheter that's a single hard drive type, or a type of server, or type of rack).

### Server Designer

As DCOPS, CloudOps, or a customer, I want the ability to design server classes.

Each server chassis in the system has metadata associated with it, defining how
many CPUs, DIMM slots, disks, PCI slots, PSUs, etc, it contains. It also has a
list of the type of hardware it can allow -- PCIe/PCIx, 2.5" vs 3.5" disks, and
so forth. These constraints ensure that the system design is viable.

The designer leverages these component attributes. As the user builds selects
components, the application would keep monitor the power budget for the system
based on the selected PSUs.

As components are added to the design, they bring along their own requirements
and constraints. For instance, adding a dual port 10Gbs NIC will require add
the cables as a requirement of the overall BOM once completed. (An override
system of some sort might be necessary too.)

Once the design is complete and validated, the entire BOM would be stored back
in the inventory system as an available asset. Other applications can then call
on this designed system for use. The required power to run that server would
also be stored as part of the BOM, for later use.

### Rack Designer

As DCOPS, CloudOps, or a customer, I want the ability to take server and switch
designs and design a rack.

Each rack asset in the inventory system has a number of attributes associated
with it, including height and depth, max weight, if it supports 0U PDUs, and so
forth.

Once a rack chassis has been selected, the application would keep track of the
total power required to run the rack as devices are added to it. All of this is
based on the metadata and device attributes stored in the inventory system.

As a device is slotted into the rack, this application would keep track of what
kind of cables are required -- as defined in the device attributes -- and
calculate the length of cable required based on the devices location in the
rack. These cables would be automatically selected from the inventory system.

Once the rack has been designed, it can then be saved in the inventory system
as a complete BOM, with total power required, weight, etc, stored in the system
as attributes.

### Datacenter Designer

As DCOPS, CloudOps, or a customer, I want the ability to take rack BOMs and
design a full datacenter deployment. This is discussed in [RFD
140](https://github.com/TritonDataCenter/rfd/blob/master/rfd/0140/README.md). All the
core data the designer does would again be stored back in the inventory system
as a BOM.


## Affordances

### Data Collection

Initially the primary data collection will be from Conch, or Conch related
services (c.f. Conch::Reporter). To that end the system should consume the
output formats from the Conch system.

### Querying / Filtering

Every data object discussed in the Data Model below should have an independent
method of retrieving and filtering the list of entities associated with it. For
example if we wanted to know:

* "How many servers are deployed in all regions?"

    curl -v https://example.com/assets?category=server

* "How many hard drives of x type are in eu-central-1?"

    curl -v https://example.com/assets?category="Hard Drive";vendor="Seagate";capacity="2TB";region="eu-cenral-1"

* "How many DIMMs of brand y have failed in the last year?"

    curl -v https://example.com/assets?category=DIMM;state=FAILED;since=1y

Each of these requests would return a paginated response containing the relevant data. While the query:

* "What tools are required to work on server class y?"

    curl -v https://example.com/assets?category=server;name=smci-2u-storage-256g-12-sas-12tb

Might return a response with a single result it would contain a link to the manifest of tools required to work on it. Or inversely:

    curl -v https://example.com/assets?category=tools;name="1mm star headed driver"

Might return a result for a specific tool which would contain links to all the assets it could be used for.

## Data Model

### Assets

Assets are any pieces of equipment we want to track for business reasons. They
may be discrete components (e.g. a Hard Drive,, DIMM chip, PDU, Chassis etc.),
or they may be aggregates.

Aggregates are things which consist of a dozen or so high-level parts (e.g.
racks, servers, switches, PDUs), or a "hard drive kit" that would contain the
drive itself, the required cables, and the referenced tools.

Each asset has a state, NEW, BROKEN, REFURB, WONTFIX, etc..

    CREATE TABLE asset (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        name text NOT NULL,
        type text NOT NULL,
        part_id uuid,
        sku str NOT NULL,
        category str NOT NULL,
        state str NOT NULL,
        comissioned timestamp with time zone NOT NULL,
        decomissioned timestamp with time zone,
		audit_id uuid NOT NULL,
        metadata jsonb
    );

#### Server Asset Example

An example server asset attributes:

| Key        | Type  | Example                          	|
|------------|-------|--------------------------------------|
| id 		 | UUID  | 00000000-0000-0000-0000-000000000000 |
| name       | Str   | smci-2u-storage-256g-12-sas-12tb 	|
| category   | Ref   | Storage Server                   	|
| SKU        | Str   | 600-0033-001                     	|
| Generation | Str   | Joyent-S12G5                     	|

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

#### Asset Categories

* Server
* Hard Drive Kit
* Computer Rack
* Storage Rack
* ...

### Parts

Parts are the discrete components and consumables. These are the things we
purchase, replace, or repair in our environment.

    CREATE TABLE part (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        name text NOT NULL,
        vendor_id uuid,
        decomissioned timestamp with time zone,
		audit_id uuid NOT NULL,
        metadata jsonb
    );

Parts may have the following metadata:

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
may be created for it:

| Name          | Type            | Extra |
|---------------|-----------------|-------|
| SKU           | Str             |       |
| ID            | UUID            |       |
| PN            | Ref: PN         |       |
| Serial Number | Str             |       |
| QR/barcode    |                 |       |

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

### Manifests

The Manifests track which assets are where, this is the heart of the "tracking"
in asset tracking. The manifests are split into two parts, a Manifest table
that tracks the specific collections of items, and the ManifestItems table that
tracks which items are included in each manifest.

Every aggregate component should have a manifest associated with it.

Manifests may be used to create BOMs and potentially budgets.

    CREATE TABLE manifest (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        name text NOT NULL,
		audit_id uuid NOT NULL,
        metadata jsonb
    );

    CREATE TABLE manifest_item (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        manifest_id uuid NOT NULL,
        asset_id uuid NOT NULL,
		audit_id uuid NOT NULL,
        metadata jsonb
    );

#### Server Manifests

An example manifest of parts for a specific server

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

### Locations

Locations are exactly that, they are the locations of an asset or
sub-location.

    CREATE TABLE location (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        name text NOT NULL,
        parent_id uuid,
        room_id uuid,
        data_center_id uuid,
		audit_id uuid NOT NULL,
        metadata jsonb
    );


### Businesses

Businesses are vendors, contractors, manufacturers, suppliers, clients etc.
Anybody we need to track who the human contact is basically.

    CREATE TABLE business (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        name text NOT NULL,
        audit_id uuid NOT NULL,
        metadata jsonb
    );


### Auditing

Because data integrity is vital to this system, we need to track every change
to the system at an atomic level. We do this via a mandatory audit_log. This is borrowed
heavily from https://github.com/2ndQuadrant/audit-trigger/blob/master/audit.sql

    CREATE TABLE audit_log (
        id uuid DEFAULT gen_random_uuid() NOT NULL primary key,
        schema_name text not null,
        table_name text not null,
        relid oid not null,
        session_user_name text,
        action_tstamp_tx TIMESTAMP WITH TIME ZONE NOT NULL,
        action_tstamp_stm TIMESTAMP WITH TIME ZONE NOT NULL,
        action_tstamp_clk TIMESTAMP WITH TIME ZONE NOT NULL,
        transaction_id bigint,
        application_name text,
        client_addr inet,
        client_port integer,
        client_query text,
        action TEXT NOT NULL CHECK (action IN ('I','D','U', 'T')),
        row_data hstore,
        changed_fields hstore,
        statement_only boolean not null
    );

## Future Features

### Design Tools

* "I want to design a server, and have a JSON specification I can use Conch to validate against"
* "I want to design a rack, and be sure that the resulting BOM has accurate cable lengths"
* "I want to design a datacenter and I want to be sure that based on rack BOM metadata's power footprints I am not exceeding my power budget"

### Maint management

### Warranty management

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
