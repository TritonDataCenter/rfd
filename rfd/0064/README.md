---
authors: Jason Schmidt <jason.schmidt@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent
-->

# RFD 64 Hardware Inventory GRUB Menu Item

## Introduction

Currently, when qualifiying hardware for use in Triton we require enterprise customers
to boot from either a SmartOS USB key or a Triton USB key and then provide
the output of the following commands for hardware validation:

- `prtdiag -v`
- `prtconf -dD`
- `diskinfo`

A significant number of customers are using VGA consoles, so they are unable
to cut/paste the output easily. Additoinally, in most cases the customers
are not able to or unable to bring networking up in order to allow the files
to be moved/sent from another system.

In these cases, the customer needs to be walked through the process of 
copying the files to the USB key, unmounting the key, and inserting it into 
another system to send to Joyent Support.

## This RFD

The goal of this document is to describe the justification and proposed steps
to create a "Hardware Inventory" menu item to be presented in the Triton boot
menu that will boot into a mode where the hardware inventory is automatically
collected and written to files on the USB key, along with instructions to the
customer on how to retrieve the files from the USB key.

## Justification


## Proposal


