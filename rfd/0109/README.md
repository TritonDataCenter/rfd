---
authors: Jan Wyszynski <jan.wyszynski@joyent.com>
state: predraft
dicussion: https://github.com/joyent/rfd/issues/52
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 <contributor>
-->

# RFD 109 Operator-Configurable Throttles for Manta

## Overview

During Manta stress tests, we've observed that either the synchronous or
asynchronous peer in a Manatee cluster can fall arbitrarily far behind the
primary because the application of PostgreSQL WAL records on the peer is slower
than the rate at which they are being sent. In such an event, there is no risk
to consistency or durability, but if a synchronous peer were to takeover the
primary, it would need to block for an amount of time that is only bounded by
how long it takes to fill up the machine's disk with WAL records before being
able to receive requests again.

We've also seen availability issues crop up when users publish URLs to
Manta objects on social media without using a CDN.

Such availability lapses suggest that operator-configurable request throttles
on a per-account or per-IP basis could be useful for the purpose of maintaining
availability and allowing operators to tailor their deployments to suit the
needs of particular workloads.

## Proposal

We propose a general-purpose throttling module for Manta that implements
Adaptive LIFO queueing on top of the Controlled Delay (CoDel) algorithm.
Any Manta service can use this module with an operator-configurable SAPI
configuration.
