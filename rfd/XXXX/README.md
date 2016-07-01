---
authors: Joshua M. Clulow <jmc@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# RFD XXX Identifier String Spaces and User Input Sanitation

The Triton software suite deals with a diverse array of different objects, from
virtual machines and containers, to storage and network resources.  These
objects are generally canonically identified within the system by a
[Universally Unique Identifier][wikipedia-uuid], but users of the system
(whether human or automaton) may also specify their own arbitrary "friendly
name" for many resources.

XXX - explore what identifiers we currently allow users to specify in triton
      (distinguish between identifiers where we care about equality: e.g.,
       a network name or VM alias; vs. an identifier that is just there for
       show: e.g., a description field.)

XXX - explore the various string spaces for identifiers:
      - UNIX file names (ZFS, UFS, etc)
      - DNS names (SRV, A, etc)
      - UNIX user and group names
      - Windows Active Directory User accounts
      - X509 Certificate DNs?
      - URI encoding?  Manta paths?
      - ASCII, UTF-8, etc.  Deal with normalisation for Unicode?
      - What we can put in attribute values in zone configuration XML files
      - What can be represented in JSON

XXX - do a survey of identifiers in use within the Triton Cloud today



<!-- References -->

[wikipedia-uuid]: https://en.wikipedia.org/wiki/Universally_unique_identifier
