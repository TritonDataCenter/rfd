---
authors: Josh Wilsdon <jwilsdon@joyent.com>
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

# RFD 35 Distributed Tracing for Triton

## Introduction

This will describe requirements and solutions for distributed tracing in Triton
in order to help monitor and diagnose issues around performance and
interdependencies.

## Background Reading

 - [AppDash](https://github.com/sourcegraph/appdash)
 - [DiTrace](https://ditrace.readthedocs.io/en/latest/)
 - [Google's Dapper](http://research.google.com/pubs/pub36356.html)
 - [HTrace](https://github.com/cloudera/htrace)
 - [OpenTracing.io](OpenTracing.io)
 - [X-Trace](https://github.com/rfonseca/X-Trace)
 - [Zipkin](http://zipkin.io/)
