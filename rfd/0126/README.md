---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues/82
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

**Please post comments in [Issue 82](https://github.com/TritonDataCenter/rfd/issues/82).**

# RFD 126 Zone Configuration Conversions

From time to time there may be incompatible changes in zone configurations due.
[RFD 121](../0121/README.md) discusses one such example as the bhyve brand
leaves behind its roots as a rough copy of the kvm brand.  In scenarios such as
this, there needs to be a way to convert existing zone configurations between
arbitrary versions.  This RFD describes that mechanism.

This work is intended to not be upstreamed to illumos so as to give Joyent the
maximum amount of flexibility to introduce change in SmartOS to meet Joyent's
needs.  Importantly, it is expected that some of the change in brands used by
Joyent are expected to be driven by our efforts to upstream code that we already
have in production.

## Versioned brands

Each zone that was created with `vmadm` has an `attr name=vm-version` resource.
This `vm-version` attribute will be used to track the version of a particular
zone configuration.  The brand's version will be stored as a new attribute,
`triton-brand-version`, in the top-level element of each brand's `config.xml`.
If these versions don't match, the zone's configuration is considered to be out
of sync with the platform image.

## Configuration update

When a zone's configuration is out of sync with the platform image, the
configuration is rebuilt by `svc:/system/triton-zone-config-update:default`
service.  When this service is running, it must assume that `zonecfg(1M)` is
unable to be used with the zone's configuration.  For this reason, it must
operate directly on each `/etc/zones/<zonename>.xml`.

There are two strategies that could be applied to upgrades and downgrades.

1. Whenever a new version N, is introduced, write an upgrade translator (*N - 1*
   to *N*) and a downgrade translator (*N* to *N-1*).  When a configuration
   needs to be upgraded or downgraded, pass it though all of the translators.
1. Use XML-to-JSON and JSON-to-XML translators.  The JSON format is based on the
   same format that is used by `vmadm`'s `create` and `get` commands.

The second strategy will be used because it has a couple of advantages.  First,
it avoids any issues that may be associated with having a lossy intermediate
version.  Second, it holds promise of someday being able to share code
(especially JSON-to-XML) with `vmadm`.

## Configuration update service

As mentioned above `svc:/system/triton-zone-config-update:default` will be
responsible for performing the configuration update.  Because this service may
be needed when falling back to platform images that predate this RFD, the
service and its supporting scripts and/or data files need to be delivered into
the `zones` pool by the new platform image.

The following will be used:

- `/var/svc/manifest/system/triton-zone-config-update.xml`:  The service
  manifest that delivers `svc:/system/triton-zone-config-update:default`.
- `/var/lib/triton/zones/config-update/version`:  Contains the time stamp of the
  platform image from which the content of `/var/lib/triton/zones/config-update`
  was last installed.
- `/var/lib/triton/zones/config-update/zone-config-update`:  The method script
  called during start of `svc:/system/triton-zone-config-update:default`
- `/var/lib/triton/zones/config-update>/<brand>/convert-<version>.js`:  Exports
  methods `zonecfgToJson()` and `jsonToZonecfg()` that perform version-specific
  conversions.  For each brand that has `triton-brand-version` greater than 1,
  the platform image must deliver a `<brand>/convert-<version>.js` for each
  version between 1 and `triton-brand-version`, inclusive.
- `/usr/lib/triton/zones/config-update/install`:  The install program, which is
  responsible for populating `/var/lib/triton/zones/config-update/`.

Both the `start` method and the `install` program perform version checks
according to the following algorithm:

- If `/var/lib/triton/zones/config-update/version` does not exist, the
  zones-config-update software is out date.
- If the content of the version file comes lexicographically before the running
  platform image's time stamp (e.g. `$(uname -v | cut -d_ -f2)`), the
  zones-config-update software is out of date.  Comparisons are performed in the
  `C` locale.
- Otherwise, the zones-config-update software is not out of date.

The `svc:/system/triton-zone-config-update:default` service uses
`/var/lib/triton/zones/config-update/zone-config-update` as its `start` method
script.  This method script performs the aforementioned version check.  If it is
out of date, it `exec`s `/usr/lib/triton/zones/config-update/install
update`.  Otherwise it iterates through all installed zones, updating the
configuration of each that has `vm-version` that mismatches the brand's
`triton-brand-version`.

Initial installation of the update service is triggered by
`svc:system/zones:default`.  As a PI boots, the zones service will run
`/usr/lib/triton/zones/config-update/install initialze`.  Once the `install`
program completes, the `zones` service will go about its normal duties of
booting zones.

The `install` program compares the time stamp in
`/var/lib/triton/zones/config-update/version` to the version of the running
platform image.  If the platform image is newer or the `version` file does not
exist:

- The content of `/usr/lib/triton/zones/config-update` is copied to
  `/var/lib/triton/zones/config-update`.
- `/usr/lib/triton/zones/config-update/triton-zone-config-update.xml` is copied
  to `/var/svc/manifest/system/`.
- `/var/lib/triton/zones/config-update/version` is updated to contain the
  platform image's time stamp.
- If the `update` argument is used, run `/var/lib/triton/zones/config-update`.

On boots that happen after the initial installation, the `install` program
called by `svc:/system/zones:default` will perform a version check which will
indicate that the current version of the `zone-config-update` software was
already installed and as such, the `triton-zone-config-update` service has
already taken care of configuration update tasks.

