---
authors: Richard Kiene <richard.kiene@joyent.com>
state: predraft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2015 Joyent Inc.
-->

# RFD 5 Triton Change Feed Support

## Introduction

### Motivation

At the time of this writing, SDC / Triton service to service state exchange
consists of frequent polling and synchronously chained calls.  As demand for the
platform grows and customer facing services like TCNS (which needs near real
time data about customer zones) are added, the overhead and delay of polling and
synchronously chained calls make them insufficient as a means of relaying state
throughout the platform.

For example, TCNS needs to know what IPs are allocated to a given customer at
the moment the customer initiates a request to allocate a new TCNS entry.  
Synchronously calling VMAPI every time a customer begins such a request creates
delay and forces VMAPI to scale one to one with TCNS request rate.  Similarly,
polling VMAPI frequently enough to give the appearance of being up to date,
would introduce significant and unnecessary load.  Additionally, when taken to
it's logical extreme, polling will hit an upper bound where the time it takes to
complete a request to VMAPI will be slower than what is needed to keep the
appearance of being up to date.

### Goal

Provide a mechanism for state exchange which allows services to scale
sub-linearly in relation to consumer count, reduce overall load, decrease
the delay in eventually consistent data, and provide a better customer
experience.

### Requirements

 1. An individual service should be able to broadcast a state change to an
    arbitrary number of consumers with a single change feed entry.

 2. Change feed data is chronologically ordered and eventually consistent.

 3. In the event of a partition, messages will not be lost and an automatic
    replay / catch-up mechanism should take over.

 4. Producers should allow for a full state dump in order to hydrate new
    consumers.

 5. Each step in the broadcast of a state change should be observable and
    debuggable.

### Assumptions

 * Hydrating new or significantly out of date consumers is not in the scope of
   the change feed bus.

 * Producers will provide a mechanism for hydrating new or significantly out of
    date consumers.

 * Eventual consistency is acceptable.

### Solutions considered but not chosen

 * [Kafka](http://kafka.apache.org/) is a pub/sub bus which uses a log
   much like a change feed to keep consumers up to date with published changes.
    While this provides some inspiration for the proposed solution, it also
   comes with the overhead of additional ZooKeeper configuration and a new set
   of failure modes to learn. That said, Kafka has been a source of inspiration.

 * [RabbitMQ](http://www.rabbitmq.com) is an AMQP based message broker. Due to
   observability and debugabilty issues, we have already started moving away
   from RabbitMQ.

 * [RethinkDB](http://www.rethinkdb.com) is a JSON based datastore with a push
   to client change model that appears to be well suited for a change feed.  
   Unfortunately RethinkDB is a relatively new technology and placing it at the
   core of our infrastructure seems inappropriate. Additionally RethinkDB does
   not offer full ACID compliance, which is problematic if we want to guarantee
   strict ordering of change feed entries.

 * [CouchDB](http://couchdb.apache.org) yet another JSON based datastore.
   CouchDB has excellent change feed support and ACID compliance. However,
   CouchDB is more of a Moray replacement than a supplement.  Since it is less
   studied and written in a language that is not first class at Joyent (erlang),
   I took a pass.  However; its HTTP API for changes has inspired some of the
   proposed design.

### Proposed solution

 * Create a new repository to house an HTTP API called sdc-changefeed. This
   service will provide a bus for publishers to push state changes to and allow
   consumers to register for the types of state changes they would like to be
   notified of.  The service will be built on top of Moray and use it to
   persist a chronological log of state changes per publisher.

 * To avoid polling Moray for changes, support for PostgreSQL NOTIFY and LISTEN
   operations will be added to Moray.  Database connection exhaustion is a real
   concern here, so we need to expose the NOTIFY and LISTEN functionality to
   Moray consumers via long polling.

 * Create a new repository for node-sdc-changefeed.  This repository will
   house client side functionality.  Three main areas will be created, the
   publisher, publisher-agent, and listener-agent.

 * The publisher is to be used by change feed event producers in the same
   transaction as the native change. It provides an API for creating a change
   feed event in a configurable datastore with a strict schema definition.

 * The publisher-agent watches the local change feed event datastore and pushes
   entries to the sdc-changefeed API in order of entry. The agent will mark and
   sweep entries to ensure durability and delivery.

 * The listener-agent provides client functionality for registering as a
   listener with sdc-changefeed and a lightweight HTTP endpoint for receiving
   change feed notifications.

### Flow

     s = step

              +-----------------+
              | VM-AGENT CHANGE |
              +-----------------+
                       +
                    s1 |
                       v
                  +---------+           +---------+
                  |         |           |         |
                  |  VMAPI  |           |   PUB   |
                  |         |           |  AGENT  |--+
                  +---------+           |         |  |
                       |                +---------+  |
               s2 +----+----+            ^   |  |    |
                  |         |         s3 |   |  |    |
                  v         v            | s4|  |    |
             +--------+ +--------+       |   |  |    |
             |        | |        |-------+   |  |    |
             |   VM   | |  FEED  |<----------+  |    |
             | BUCKET | | BUCKET |          s6a |    |
             |        | |        |------------- +    |
             +--------+ +--------+                   |
                                                     |
                                                  s5 |
                        +---------------+            |
                        |               |            |
                        |      SDC      |<-----------+
                        |  CHANGE FEED  |
                        |               |
                        +---------------+
                       s6b |         |
                           v         |
                      +--------+     |
                      |        |     |
                      |  FEED  |     |
                      | BUCKET |     |
                      |        |     |
                      +--------+     |
                                  s7 |
                                     v
                                +--------+
                                |        |
                                |  TCNS  |
                                |        |
                                +--------+

### Steps explained (happy path)

 1. VM-AGENT pushes a change to VMAPI, through the pre-existing mechanism.

 2. VMAPI persists the updated information in its VM bucket(s) and inserts a new
    change feed record into its change feed bucket (Ideally this is done in a
    single transaction and the node-sdc-clients code can assist in that
    behavior).  The data is either persisted to both the VM bucket and the
    change feed bucket or everything is rolled back. Change feed entries, among
    other things, will have a sequence-id, agent-id, and processed fields
    (more on this later).

 3. The publisher-agent, running in the same zone as VMAPI and using the same
    Moray, is notified by Moray that a record has been inserted into the change
    feed bucket.

 4. The publisher-agent selects all entries with an empty agent-id and/or all
    entries with an agent-id that matches the publisher-agent and a processed
    field which is empty.  This ensures that an agent crash and restart does not
    leave messages marked but unprocessed (more on this later).

 5. Publisher-agent POSTs the unprocessed entries to the sdc-changefeed API
    (We'll cover failure scenarios in detail later, but suffice it to say that
    HTTP response codes will be quite helpful).

 6. (a) Assuming step 5 was successful, the publisher-agent will update the
        entries in it's bucket as processed to prevent them from being replayed.
    (b) Under the same assumption that step 5 was successful, sdc-changefeed API
        will persist the change feed entries, in chronological order using the
        sequence-id attached by the publisher-agent, to its own change feed
        bucket.  Persisting each entry in sdc-changefeed API allows listeners to
        ask sdc-changefeed API for a range of entries in the event that they
        miss events due to a crash, restart, etc.  We'll cover more about that
        in later sections.
 7. Sdc-changefeed API notifies long polling listeners (in this case TCNS)
    and provides a JSON payload with the entry(s).

### Failure scenarios

 * VMAPI is partitioned from Moray
   * No writes to Moray from VMAPI will happen until the partition is
     resolved. Thus no change feed entries will be produced.  Once the partition
     is resolved VMAPI will begin storing data and publisher-agent will pick up
     the changes and push them to Sdc-changefeed API.  VMAPI may need to true-up
     with any VM-AGENT updates, but that is outside the scope of this document
     because it relies on a different mechanism for updates. VM-AGENT should
     eventually be updated to use sdc-changefeed API.


 * VMAPI's publisher-agent crashes
   * Since publisher-agent entries are not considered processed until
     sdc-changefeed has accepted them, we don't need to consider entries marked
     processed that haven't actually been processed. What we do need to consider
     is entries which happen during the time the publisher-agent is unavailable
     and entries marked with the publisher-agent's id. Because we may have
     missed notifications from Moray and the next notification event will happen
     at a non-deterministic time, we should assume that we missed notifications
     and have marked entries in the change feed bucket at agent startup. With
     this behavior if the agent crashes or is restarted, any in process and/or
     missed notifications will be processed at startup and which will result in
     a delay, but maintain correctness and sequential ordering.


 * VMAPI's publisher-agent is partitioned off from sdc-changefeed API
   * the change feed bucket will continue to receive new entries and the
     publisher-agent will continue marking entries which need to be processed.
     The publisher-agent will continue attempts to publish to sdc-changefeed API
     and use an exponential back-off.  When sdc-changefeed API becomes available
     again, messages piled up on the publisher-agent's change feed bucket will
     be delivered. The result is delayed, but sequentially correct events being
     delivered.


* Sdc-changefeed API is partitioned from its Moray
  * If sdc-changefeed API is unable to persist entries, it must refuse all
    incoming POSTs and respond with an HTTP 503 (Service unavailable).  The 503
    response will be handled by the publisher-agent(s) in exactly the same way
    as a partition between the publisher-agent and sdc-changefeed API
    (See above scenario).


* Sdc-changfeed API is partitioned from listener(s)
  * // This is where it gets tricky... Retry vs offset fetches...
