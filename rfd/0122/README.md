---
authors: Mike Gerdts <mike.gerdts@joyent.com>
state: draft
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

This draft is provided to support upcoming changes to the bhyve brand draft,
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

As the bhyve brand is introduced via [RFD 121](../0121/README.md) there is a
desire to better represent the configuration items that are needed by the brand
in proper resources and properties.

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

Zone configurations may have simple values, complex values, and list values.
A simple value contains a single value such as a string or a number.  A complex
value stores a tuple, such as a key-value pair.  List values are made up of a
list of simple values or a list of complex values.

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

It is expected that new resources and properties will be added to illumos from
time to time.  To prevent these new resources and properties from causing churn
for downstream brands, each resource and property will be enabled only if
explicitly set to enabled by the brand's `config.xml`.  This will have a
one-time cost of augmenting each brand's `config.xml` with the set supported
resources and properties.  This augmentation will look like:

```xml
    <resource name="zone" enabled="true">
        <!--
	  These three are #REQUIRED in zonecfg.dtd.1 and are required in all
	  brands.
	-->
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

	<!--
	  This has a #FIXED value zonecfg.dtd.1 and is required in all brands.
	  It is not exposed in the zonecfg interface.
	-->
        <property name="version" enabled="true" fixed-value="1" />

        <resource name="filesystem" enabled="true" >
            <property name="special" enabled="true" />
            <property name="raw" enabled="true" />
            <property name="directory" enabled="true" />
            <property name="type" enabled="true" />
	    <property name="fsoption" enabled="true" />
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
            <property name="rctl-value" enabled="true" />
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

When the `brand` property is set in the global scope and when a new resource is
added, each enabled property in that scope that has a fixed value will
automatically set to the fixed value.

Fixed values are only supported for properties that have simple values.  Complex
values and list values are not supported.

If `zonecfg.dtd.1` specifies a fixed value for an element with `#FIXED`, the
`fixed-value` attribute should also be set.  See `zonecfg -b <brand>
properties`, below, for details.

### Integration with `zonecfg(1M)`

`zonecfg(1M)` will be enhanced to only allow adding of resources and setting of
properties that are enabled.  If an attempt is made to add a disabled
resource or set a disabled property, an error message will be printed.

To detect use of disabled resource and/or properties (e.g. as a result of
editing the zone's XML configuration file), `zonecfg -z <zone> verify` will
ensure that only enabled resources and properties are in the configuration.

`zonecfg(1M)` uses statically defined lists for command completions with
`libtecla(3LIB)`.  Because static lists will offer invalid completions, these
lists will be dynamically generated based on the scope.

`zonecfg` will be enhanced to allow system operators and developers of layered
software to determine which resource types and property types are supported.
The synopsis is:

```
zonecfg -b <brand> resources
zonecfg -b <brand> properties [restype]
```

Properties that have a `fixed-value` in `config.xml` will not be listed.
In the following examples, the `zonecfg` is used to retrieve the list of
property types allowed in the global scope, allowed resource types, and property
types allowed within the `attr` resource.

```
$ zonecfg -b somebrand properties
autoboot bootargs brand ...
$ zonecfg -b somebrand resources
attr dataset fs ...
$ zonecfg -b somebrand properties attr
name type value
```

While it would be helpful to also have metadata that expresses validation rules,
that information is not readily available.  Making that information would be a
noble effort that is far beyond the scope of this work.

**XXX `This does not deal with the fact that there is sometimes mismatch between
names used in `zonecfg` and those that appear in `zonecfg.dtd.1`.   For
instance, `zonecfg` uses `capped-memory` for elements specified as `mcap` in
`zonecfg.dtd.1`.  It's not clear whether there should be a `dtdname` attribute
in `config.xml` or if zonecfg should just perform the translation itself.**

### `libbrand` support

The following functions are added to libbrand.

```
boolean_t brand_res_enabled(brand_handle_t bh, const char *restype);
```

Returns `B_TRUE` if and only if `restype` is enabled in the brand's
configuration.  If `restype` is `NULL`, this implies the global scope which is
always enabled.

```
boolean_t brand_resprop_enabled(brand_handle_t bh, const char *restype,
    const char *proptype);
```

Returns `B_TRUE` if and only if `restype` is enabled and `proptype` within
`restype` is enabled.  If `restype` is `NULL`, `proptype` is checked within the
global scope.

```
ssize_t brand_get_fixed_value(brand_handle_t bh, const char *restype,
    const char *proptype, char *buf, size_t buflen);
```

Retrieves the fixed value of property `proptype` within `restype` resources.  If
`restype` is NULL, `proptype` refers to a property within the global scope.
Returns the number of characters copied into `buf`, or the number that would
have been copied if it were long enough.  See strlcpy(3C).  If no fixed value
exists, -1 is returned.

```
int brand_get_enabled_res(brand_handle_t bh, const char ***resnames,
    int *rescnt);
```

Retrieves a list of resource types enabled in the global scope.  On success,
`resnames` references newly allocated memory with one resource type
name per array element, `*rescnt` is set to the number of elements, and 0 is
returned.  The caller should free `*resnames`.  -1 is returned on error.

```
int brand_get_enabled_simple_props(brand_handle_t bh, const char *rt,
    const char ***propnames, int *propcnt);
int brand_get_enabled_complex_props(brand_handle_t bh, const char *rt,
    const char ***propnames, int *propcnt);
int brand_get_enabled_list_props(brand_handle_t bh, const char *rt,
    const char ***propnames, int *propcnt);
```

Retrieves a list of simple, complex, and list property types enabled in the
global scope.  On success, `propnames` references newly allocated memory with
one property type name per array element, `*propcnt` is set to the number of
elements, and 0 is returned.  The caller should free `*propnames`.  -1 is
returned on error.

### Interfaces

This work is intended to be submitted to illumos with a stability level that
matches the existing `brand.dtd.1`.

**XXX** This may be *committed* or *uncommitted* and I'm not sure what the
difference is between them in illumos.  In Solaris (SunOS 5.x) that distinction
was increasingly unclear as the major release number went unchanged for decades.

| Interface                                     | Stability     |
| --------------------------------------------- | ------------- |
| `resource` element in `brand.dtd.1`           | Committed     |
| `enabled` attribute on `resource` element     | Committed     |
| `property` element in `brand.dtd.1`           | Committed     |
| `enabled` attribute on `property` element     | Committed     |
| `fixed-value` attribute on `property` element | Committed     |
| `zonecfg -b <brand> <resources\|properties>`	| Committed	|
| `brand_get_enabled_res`			| Private	|
| `brand_get_enabled_simple_props`		| Private	|
| `brand_get_enabled_complex_props`		| Private	|
| `brand_get_enabled_list_props`		| Private	|
