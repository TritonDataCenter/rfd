---
authors: Trent Mick <trent.mick@joyent.com>
state: predraft
---

# RFD 68: Triton versioning

This document will attempt to codify how we version things in Triton components.
This covers things like the following:

- package.json: What should the "version" field in a node.js project's
  package.json file be and how should it change?
- CHANGES.md: What are requirements for a changelog section (commonly
  "CHANGES.md") for a new version?
- image version: What should the "version" field in a Triton component's image
  manifest be? How is the "latest" version of a Triton image from
  updates.joyent.com determined?
- API versioning: How should API versioning work for Triton restify-based
  services?

TODO: more details coming, obviously


