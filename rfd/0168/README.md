---
authors: Kelly McLaughlin <kelly.mclaughlin@joyent.com>
state: predraft
discussion: TBD
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Joyent, Inc.
-->

# RFD 168 Bootstrapping a Manta Buckets deployment

## Overview

This RFD covers the steps required to bootstrap a manta buckets deployment. This
includes specifying the buckets manatee shards, creating the initial hash ring
for the buckets system, and assigning virtual nodes to the buckets shards. It
also covers the changes to the current manta deployment scripts to enable the
creation of manta buckets shards that are distinct from other manta shard types
and the creation of a hash ring image that is distinct from the hash ring image
used by a standard manta deployment.
