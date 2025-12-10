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

<!-- TODO: Briefly summarize which values are mismatched (e.g., stability, backwards compatibility, long-term support)? The references cover this but a sentence or two here would help readers. -->

## Proposed Solution

The Rust project's values are a much closer match to ours.

<!-- TODO: Similarly, which Rust values align with yours? -->
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

<!-- TODO: Clarify - does this mean generating Rust clients to talk to existing NodeJS servers? Being explicit about interoperability during migration would help. -->

### Technical Guidance

Follow in the footsteps of our former colleagues over at Oxide.

<!-- TODO: Is "API Manager" the right term? Dropshot is typically described as an HTTP server framework. Is this heading meant to describe a pattern/workflow? -->
[Dropshot](https://github.com/oxidecomputer/dropshot) API Manager:
- Dropshot Traits → OpenAPI specifications
- Dropshot Traits → Dropshot implementations
- OpenAPI specifications → [Progenitor](https://github.com/oxidecomputer/progenitor) generated clients

<!-- TODO: The structure here is ambiguous. Is the line below meant to be a bullet point introducing the sub-items? Or are the test items separate from the LLM guidance? -->
LLM assistance for translating nodejs API implementations into Dropshot Traits
- Test rust clients against nodejs servers
- Test nodejs clients against rust servers

### Examples

<!-- TODO: Brief note about what bugview does would help readers understand the example. Is it a Jira integration? -->
Our bugview service was written using restify and had been operating just fine for quite a while.
When Atlassian finally turned off a deprecated API it broke suddenly.
Rather than invest additional effort into maintaining the original nodejs implementation, bugview was used as a test case for migrating an application to Rust.

## References

<!-- TODO: Should there be links to the actual bugview migration PR/code as an example for others to follow? -->

[monitor-reef AGENTS.md](https://github.com/TritonDataCenter/monitor-reef/blob/main/AGENTS.md)

Platform as a Reflection of Values 
[Slides](https://speakerdeck.com/bcantrill/platform-as-reflection-of-values-joyent-node-dot-js-and-beyond)
[Recording](https://www.youtube.com/watch?v=Xhx970_JKX4)

Platform values, Rust, and the implication for system software 
[Slides](https://speakerdeck.com/bcantrill/platform-values-rust-and-the-implications-for-system-software)
[Recording](https://www.youtube.com/watch?v=2wZ1pCpJUIM)

The Summer of Rust
[Recording](https://www.youtube.com/watch?v=YKv_IDN0zCA)
