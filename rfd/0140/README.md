---
authors: Bryan Horstmann-Allen <bdha@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+140%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 140 Conch: Datacenter Designer

## Overview

[Conch](https://github.com/joyent/conch/) is a datacenter management service. It supports validating various aspects of a datacenter deployment. However, it is currently difficult to manage regions, datacenters, and racks.

It would be extremely helpful if we had the ability to visually design a datacenter floor. We will need to provide new primitives and add new attributes to existing ones.

The Datacenter Designer is a set of APIs, CLI support, and UI that allows operators to design Datacenter Rooms -- giving us another vector of information (locality) in addition to all the system and environmental metrics we pull in as part of Conch itself.

## Design Workflow

The datacenter designer UI is built around the conept of Tiles. A grid of tiles, defined by an operator, encompasses the layout of a given Datacenter Room. This collection is called the Datacenter Room Map.

In the Map, the operator selects a Tile, selects a Tile Template to give it some default attributes. Once assigned, they can modify its default properties or drop a Datacenter Rack onto it.

It will be useful to limit the selection of Datacenter Racks to specific Workspaces.

In Design Mode, the application should certain constraints into consideration. For instance, it should not allow the operator to place a Rack that requires 20KW onto a Tile that can only provide 8KW. This action would raise an error. See the [Validations](#validations) section for more.

## View Mode

Displays a given Datacenter Room's layout and status information about the objects in it. If a device in a rack has a problem, this should be surfaced.

If we have environmental information about the room temps we should display hot/cold spots.

## Conch Objects

In Conch, we have the following concepts:

* Workspaces
* Regions
* Datacenter Rooms  / Availability Zones
* Racks
* Devices

### Workspaces

A Workspace is an arbitrary selection of Datacenter Rooms or individual Racks. We use Workspaces to logically group entire Regions, specific Rooms, or racks for expansions we are building out in a given datacenter.

Workspaces are queryable and powerful primitives.

### Regions

Defined in the `datacenter` table.

### Datacenter Rooms

Defined in the `datacenter_room` table.

A `datacenter_room` references a `datacenter.id`.

Datacenter rooms can also be considered "Availability Zones", as mapped into how Triton works. (This specific definition in Conch may change in the near future depending on how we approach expanding certain of our AZs.)

### Racks

Defined in the `datacenter_rack` table.

A `datacenter_rack` references a `datacenter_room.id`.

A rack posseses a name and a role. The name is an arbitrary string, and the role is a to `datacenter_rack_role.id`. The role is used by downstream consumers for various actions (e.g., deciding on how to configure the same system class depending on if it is in a TRITON or MANTA rack.)

Further, the `datacenter_rack_layout` table defines the layout of a given rack. It references `datacenter_rack.id` and `hardware_product.id`, and includes a `ru_start` attribute that allows us to define what class of hardware product is in a given slot in a given rack.

### Devices

Defined in the `device` table.

Devices reference `hardware_product.id`.

The `device_location` table references `datacenter_rack.id`, but the `rack_unit` field is a local integer, not a reference to `datacenter_rack_layout.id`. (This may be a future referential optimization.)

## Object Relationships

Described in more detail below, the overall topology of a Datacenter Room design is:

`datacenter_tiles` are organized into a `datacenter_room_map`. 

## Datacenter Room Maps

Maps should be associated with a given Workspace.

We need a way to map Tiles to specific locations in the grid of a Datacenter Rooms.

### datacenter_room_map

TODO: DB table that contains the map of a given room.

## Tiles

A Datacenter Room is a grid of Tiles.

Tiles are defined in the following database tables:

### datacenter_tile_template

Most Tiles within a given Datacenter Room will share many of the same set of attributes: How much power they are capable of pushing, max height for racks, the max weight they can sustain and so on.

When an operator selects a Tile in their Datacenter Room UI, they will need to a select a Template to "drop" into that slot.

We will need UI around managing Tile Templates.



| Name          | Description                                                  |
| ------------- | ------------------------------------------------------------ |
| Name          | A descriptive name given to the operator. For instance: `equinix_19in_42U_8KW`. |
| Max Weight    | The max weight a given Tile can support.                     |
| Max Height    | The max height (in RU?) a given Tile can support.            |
| Max Dimension |                                                              |

### datacenter_tile

When an operator places a Tile Template into a Tile Slot in a Datacenter Room, that specific Tile is created with these attributes:

| Name                        | Description                                                  |
| --------------------------- | ------------------------------------------------------------ |
| Name                        | Most datacenters provide a name for available tile on their floor. These names often map to what we call the Datacenter Rack, but not always. |
| datacenter_tile_template_id | A reference to `datacenter_tile_template.id`.                |
| datacenter_tile_location    | A reference to `datacenter_room_map.id`, which gives us the physical location of `datacenter_tile.id`. |

### datacenter_tile_circuits

A Tile may or may not contain active power circuilts in it. If the rack only contains spare hardware, it probably will not have circuits. However, the common case is we will have at least one, but usually two, circuits plugged into a Tile.



| Name            | Description                                                  |
| --------------- | ------------------------------------------------------------ |
| Name            | Most power circuilts provided by the datacenter will be labeled. |
| Voltage         | Provided voltage of the circuirt.                            |
| Amperage        | Provided amerage of the circuit.                             |
| Usable Capacity | Based off the 80% rule, what is the capacity of the circuit? |
| Current Usage   | By polling the PDUs, we can collect the current draw for a given circuit. |

## Racks and Tiles

A new field will need to be added to the `datacenter_rack` table `datacenter_rack_tile`, references `datacenter_tile.id`. This is how we will associate  given physical location in a Datacenter Room with a given rack in that datacenter.

## Validations

As we build the UI out, there will no doubt be a number of validations we will want to provide. Whether these should be defined in the UI app, or fed through the [Conch Validation Engine](https://github.com/joyent/rfd/blob/master/rfd/0133/README.md) is an open question.

Examples of Validations we want the Designer to provide

* Do not allow the operator to overcommit power on a given Tile
* Require that all Racks be placed such that their air flow is correct
* Surface cooling or airflow issues to the operator if environmental data is available