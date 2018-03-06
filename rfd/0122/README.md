---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2018, Joyent, Inc.
-->

# RFD 122 Per-brand resource and property customization

This pre-draft is provided to support upcoming changes to the bhyve brand draft,
described in [RFD 121](../0121/README.md).

Discussion is being held in [issue 78](https://github.com/joyent/rfd/issues/78).

## Problem Statement

The `brands(5)` framework was conceived in a time when all zone brands were
expected to be some form of operating system container.  The similarity in
purpose between brands meant that all brands could share the same set of
resources and properties within those resources.

The `kvm(5)` brand in SmartOS demonstrates that those initial assumptions no
longer hold true.  For instance, SmartOS uses an `attr` resource with `name` set
to `ram` to specify the guest memory size.  Other `attr` resources are used to
specify other properties that are essential to the brand.  Meanwhile, there are
some properties and resource types that are unsupported in the `kvm(5)` brand.

As the bhyve brand is introduced via [RFD
121](https://github.com/joyent/rfd/blob/master/rfd/0121/README.md) there is a
desire to better represent the configuration items that are needed by the brand
in proper reosurces and properties.

## Current implementation

There are several XML DTD files involved in the configuration of a brand and
zones of that brand.  These files all live in `/usr/share/lib/xml/dtd`.

- `brand.dtd.1` describes brand-specific helper commands that are called to
  perform tasks before, during, or after various state changes.  Each
  `/usr/lib/brand/<brand>/config.xml` file specifies per-brand values and must
  conform to this DTD.
- `zone_platform.dtd.1` describes immutable configuration items that form the
  basis of the zone platform.  That is, this describes the base set of devices
  and mounted file systems used by each brand.  Each
  `/usr/lib/brand/<brand>/platform.xml` file specifies per-brand values and must
  conform to this DTD.
- `zonecfg.dtd.` describes the resources and properties that are allowed within
  a zone configuration.  Each `/etc/zones/<zone>.xml` file specifies the
  per-zone values and must conform to this DTD.

The `zonecfg(1M)` command is used to configure a subset of the resources and
properties described in `zonecfg.dtd.1`.  Some resources, such as `package`, and
`patch` were used by the `detach` and `attach` commands in the non-branded
implementation in Solaris 10 and were never exposed in `zonecfg(1M)`.  Others,
such as `inherit-pkg-dir` were exposed in `zonecfg(1M)` but are no longer
appropriate to any brand and have had the associated code removed.

## Brand-specific resources and properties

To allow brand authors to specify which resources are appropriate for a brand,
`brand.dtd.1` will be extended to allow each brand's `config.xml` to specify
whether a resource is enabled or disabled.  For example, a brand may enable a
resource with:

```xml
    <resource name="fs" enabled="true" />
```

Similarly, a property is enabled via:

```xml
    <property name="hostid" enabled="true" />
```

Zone configurations are hierarchical.  While not reflected as such in the
`zonecfg(1M)` syntax, resources nest within each other.  For example, the global
scope is a resource of type `zone`, a file system is specified in a resource of
type `fs` and options to that file system may be specified via `fsoption`
resources.  Note that `zonecfg(1M)` presents `fsoption` as the multi-valued
`options` property.  This hierarchy will be reflected in the new elements.

It is expected that new resources and properties will be added to illumos from
time to time.  To prevent these new resources and properties from causing churn
for downstream brands, each resource and property will be enabled only if
explicitly set to enabled by the brand's `config.xml`.  This will have a
one-time cost of augmenting each brand's `config.xml` with the set supported
resources and properties.  This augmentation will look like:

```xml
    <resource name="zone" enabled="true">
        <property name="name" enabled="true" />
        <property name="zonepath" enabled="true" />
        <property name="autoboot" enabled="true" />
        <property name="ip-type" enabled="true" />
        <property name="hostid" enabled="true" />
        <property name="pool" enabled="true" />
        <property name="limitpriv" enabled="true" />
        <property name="bootargs" enabled="true" />
        <property name="brand" enabled="true" />
        <property name="scheduling-class" enabled="true" />
        <property name="fs-allowed" enabled="true" />

        <resource name="filesystem" enabled="true" >
            <property name="special" enabled="true" />
            <property name="raw" enabled="true" />
            <property name="directory" enabled="true" />
            <property name="type" enabled="true" />

            <resource name="fsoption" enabled="true" >
                <property name="name" />
            </resource>
        </resource>

        <resource name="network" enabled="true" >
            <property name="address" enabled="true" />
            <property name="allowed-address" enabled="true" />
            <property name="defrouter" enabled="true" />
            <property name="physical" enabled="true" />
        </resource>

        <resource name="device" enabled="true" >
            <property name="match" enabled="true" />
        </resource>

        <resource name="rctl" enabled="true" >
            <property name="name" enabled="true" />

            <resource name="rctl-value" >
                <property name="priv" enabled="true" />
                <property name="limit" enabled="true" />
                <property name="action" enabled="true" />
            </resource>
        </resource>

        <resource name="attr" enabled="true" >
            <property name="name" enabled="true" />
            <property name="type" enabled="true" />
            <property name="value" enabled="true" />
        </resource>

        <resource name="dataset" enabled="true" >
            <property name="name" enabled="true" />
        </resource>

        <resource name="pset" enabled="true" >
            <property name="ncpu_min" enabled="true" />
            <property name="ncpu_max" enabled="true" />
        </resource>

        <resource name="mcap" enabled="true" >
            <property name="physical" enabled="true" />
        </resource>

        <resource name="admin" enabled="true" >
            <property name="user" enabled="true" />
            <property name="auths" enabled="true" />
        </resource>

        <resource name="security-flags" enabled="true" >
            <property name="default" enabled="true" />
            <property name="lower" enabled="true" />
            <property name="upper" enabled="true" />
        </resource>
    </resource>
```

### Properties with fixed values

There are cases where a property is required by the DTD and/or the zones
framework to have a value, but the brand supports only a single value for that
property.  For instance, in the kvm and bhyve brands, shared IP stack is not
supported.  As such, the `ip-type` property should be set to the fixed value of
`exclusive`.  This can be accomplished with the new `fixed-value` attribute on a
property.

```xml
        <property name="ip-type" enabled="true" fixed-value="exclusive" />
```

### Integration with `zonecfg(1M)`

`zonecfg(1M)` will be enhanced to only allow adding of resources and setting of
properties that are enabled.  If an attempt is made to add a disabled
resource or set a disabled property, an error message will be printed.

**XXX** What do we do about `libtecla(3LIB)` completions?

### Interfaces

This work is intended to be sumitted to illumos with a stability level that
matches the existing `brand.dtd.1`.

**XXX** This may be *committed* or *uncommitted* and I'm not sure what the
difference is between them in illumos.  In Solaris (SunOS 5.x) that destinction
was increasingly unclear as the major release number went unchanged for decades.

| Interface                                     | Stability     |
| --------------------------------------------- | ------------- |
| `resource` element in `brand.dtd.1`           | Committed     |
| `enabled` attribute on `resource` element     | Committed     |
| `property` element in `brand.dtd.1`           | Committed     |
| `enabled` attribute on `property` element     | Committed     |
| `fixed-value` attribute on `property` element | Committed     |
