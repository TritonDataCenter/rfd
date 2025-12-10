---
authors: Nahum Shalman <nshalman@edgecast.io>
state: predraft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+190%22
---

# RFD 190 Deprecating NodeJS for Rust

## Problem statement

We have lots of software that only runs against a very very old version of NodeJS.
This presents maintenance and security problems.

The NodeJS project's values are a mismatch with our own.

## Proposed Solution

The Rust project's values are a much closer match to ours.
We have known this for many years.

The time has come to start porting NodeJS applications to Rust.

Priorities:
- Net-new software
- Security-sensitive applications
- APIs that are currently broken
- APIs that need to be extended/expanded
- Everything else

To be clear, if something is not broken, not exposed to the internet, and doesn't need to be changed, we are not in a rush to rewrite the server implementation.
We DO want to capture the API description in a Dropshot trait so that we can interface with it from Rust.

A clarifying example that we will probably want to work on soon is CloudAPI. It is exposed to the internet and if we want to add additional features to it, we will either
have to continue working with the existing node implementation or port it to rust.
At the point when its turn comes to be written in Rust, its server implementation will need to be able to speak to a large number of our backend APIs. Chances are
that most of them will still be in nodejs when that happens. By capturing those API specifications in Dropshot traits we will be able to be rigorous about how
we interface with them, and when their turns come for porting, we will already have confidence that the trait we are using is correct.

### Technical Guidance

Follow in the footsteps of our former colleagues over at Oxide.

- [Dropshot API Manager](https://github.com/oxidecomputer/dropshot-api-manager)
- [Dropshot](https://github.com/oxidecomputer/dropshot) Traits → OpenAPI specifications
- Dropshot Traits → Dropshot implementations
- OpenAPI specifications → [Progenitor](https://github.com/oxidecomputer/progenitor) generated clients

We are very fortunate to have lots of very clean API boundaries. By maintaining interoperability across
those boundaries we can gain confidence that our new rust code is correct.

We should iterate on using LLM assistance for translating nodejs API implementations into Dropshot Traits
- Test rust clients against nodejs servers
- Test nodejs clients against rust servers

### Examples

Our [bugview](https://github.com/TritonDataCenter/bugview) service (a site to view JIRA tickets and issues that have been made public) was written using restify and had been operating just fine for quite a while.
When Atlassian finally turned off a deprecated JIRA search API it broke suddenly.
Rather than invest additional effort into maintaining the original nodejs implementation, bugview was used as a test case for migrating an application to Rust.

## References

- [monitor-reef AGENTS.md](https://github.com/TritonDataCenter/monitor-reef/blob/main/AGENTS.md)
- [Our JIRA trait](https://github.com/TritonDataCenter/monitor-reef/pull/2)
- [The port of bugview](https://github.com/TritonDataCenter/monitor-reef/pull/3)

- Platform as a Reflection of Values 
[Slides](https://speakerdeck.com/bcantrill/platform-as-reflection-of-values-joyent-node-dot-js-and-beyond)
[Recording](https://www.youtube.com/watch?v=Xhx970_JKX4)

- Platform values, Rust, and the implication for system software 
[Slides](https://speakerdeck.com/bcantrill/platform-values-rust-and-the-implications-for-system-software)
[Recording](https://www.youtube.com/watch?v=2wZ1pCpJUIM)

- The Summer of Rust
[Recording](https://www.youtube.com/watch?v=YKv_IDN0zCA)
