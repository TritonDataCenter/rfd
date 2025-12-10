---
authors: Nahum Shalman <nahum.shalman@mnx.io>
state: predraft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+190%22
---

# RFD 190 Deprecating NodeJS for Rust

## Definitions of Terms

## Problem statement

We have lots of software that only runs against a very very old version of NodeJS.
This presents maintenance and security problems.

The NodeJS project's values are a mismatch with our own.

## Proposed Solution

The Rust project's values are a much closer match to ours.
We have known this for many years.

The time has come to start porting NodeJS applications to Rust.

### Technical Guidance

Follow in the footsteps of our former colleagues over at Oxide

Dropshot Traits -> OpenAPI specifications
Dropshot Traits -> Dropshot implementations
OpenAPI specifications -> Progenitor generated clients

monitor-reef monorepo

LLM assistance for translating nodejs API implementations into Dropshot Traits
Test rust clients against nodejs servers

## References

monitor-reef AGENTS.md

Platform as a Reflection of Values 
[Slides](https://speakerdeck.com/bcantrill/platform-as-reflection-of-values-joyent-node-dot-js-and-beyond)
[Recording](https://www.youtube.com/watch?v=Xhx970_JKX4)

Platform values, Rust, and the implication for system software 
[Slides](https://speakerdeck.com/bcantrill/platform-values-rust-and-the-implications-for-system-software)
[Recording](https://www.youtube.com/watch?v=2wZ1pCpJUIM)

The Summer of Rust
[Recording](https://www.youtube.com/watch?v=YKv_IDN0zCA)
