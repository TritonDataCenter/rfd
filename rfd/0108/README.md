---
authors: Jerry Jelinek <jerry@joyent.com>
state: predraft
---

# RFD 108 Remove Support for Dynamic Reconfiguration (DR)

## Overview

The support for DR was added by Sun in the late '90s to support dynamic
hardware reconfiguration for some niche, high-end SPARC platforms. The
intention is to allow the addition/removal of hardware boards containing
memory and/or CPUs while the system is running.

This concept is dubious at best for the modern hardware landscape, and certainly
does not apply to any platform on which illumos will run for the forseeable
future.

There is currently a significant amount of code complexity and overhead to
support DR, but no hardware that illumos runs on will ever support DR. Given
this, removing the support for DR will simplify and streamline the core kernel
code in ways which will benefit all illumos derivatives.

## High-Level Changes

### VM system
#### kernel cage
### Other
