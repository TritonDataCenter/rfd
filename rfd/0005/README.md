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

## Proposed solution

### The following new repositories will be created

 * node-sdc-changefeed
 * sdc-cf-agent
 * sdc-cfapi


### The solution will consist of four main components

 1. Publisher client module
 2. Publisher agent
 3. Change feed API
 4. Listener agent

### Publisher client module

 * Residing in the node-sdc-changefeed repository, the publisher client module
   will abstract away some of the boilerplate necessary for simultaneously
   modifying the publishers authoritative data store and its change feed
   datastore in the same operation.

 * A change feed data store (which will usually be a Moray bucket) is a
   publisher local (e.g. using the same Moray as its existing bucket) storage
   mechanism used to represent a chronologically ordered log of state changes.
   It is important that have the same availability characteristics as the
   authoritative data store because data will either be persisted to both the
   authoritative data store and the change feed data store, or not at all.
   Having the change feed data store in a different location presents some
   availability issues that are not desirable.

 * The change feed entry will look like the following (Note: this is a JSON
   representation, but the client should be storage mechanism agnostic):

   ```
   /*
    * {number} sequence-id    - Marks this entries position in the log
    * {string} agent-id       - UUID of the publisher-agent (blank until marked)
    * {string} change-feed-id - Feed name, identifies the bucket and content
    * {bool}   processed      - Identifies if this entry has been processed
    * {object} changes        - Properties changed in this entry
    */
   {
       "sequence-id": 63,
       "agent-id": "",
       "change-feed-id": "vmapi::vm",
       "processed": false,
       "changes": {
           "uuid": "78615996-1a0e-40ca-974e-8b484774711a",
           "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
           "alias": "shmeeny",
           "nics": [
            {
              "interface": "net0",
              "mac": "32:4d:c5:55:a7:4d",
              "vlan_id": 0,
              "nic_tag": "external",
              "ip": "10.99.99.8",
              "netmask": "255.255.255.0",
              "primary": true
            }
          ]
       }
   }
   ```


### Publisher agent

 * Located in the sdc-cf-agent repository, the publisher agent is a standalone
   node application that, by convention, lives in the same zone as the service
   creating the published events.

 * The publisher agent listens for modifications to the publishers change feed
   datastore, checks for entries that have not been marked processed, have an
   empty agent-id or its agent-id (e.g. marked but unprocessed entries, see the
   failure scenarios section for more detail).

 * When unprocessed entries are found, the agent first marks them with its
   agent-id (this is for debugability and to prevent double processing if
   multiple agents are used), and then POSTs the change feed entries to CFAPI.
   If successful, the in process entries are marked processed.

 * The agent-id should is configurable via a config.js file, however it should
   be considered permanent once used.  Also in the config.js file is a variable
   for configuring the change feed entries retention time (e.g. 2 days). The
   longer the retention period the less likely it is that a listener will need
   to be bootstrapped by a snapshot. However the consequence of a long retention
   time is more disk usage.

 * On startup the agent should act as if it has been notified of an entry and
   select all appropriate entries in the bucket. This is an important function
   that allows for automatic recovery from crash or restart.

 * Publisher agent should be datastore agnostic, but more benefit will come from
   using Moray with LISTEN and NOTIFY support.

 * The agent is also responsible for sweeping entries older than the retention
   time.

### Change feed API

 * Located in the sdc-cfapi repository, the change feed API is a log entry bus
   that leverages an HTTP API, long polling, and Moray buckets. This is a new
   API that will live in a zone on the headnode just like other service API in
   Triton / SDC.

 * The API maintains a Moray bucket per change-feed-id, and ensures that each
   bucket is in chronological order.

 * Publishers will POST a registration to cfapi. Once registered they will be
   able to POST change feed entries.  Cfapi will use HTTP status codes to
   interact with publishers (e.g. status code 200 if an entry is successfully
   POSTed, and status code 503 if the entry cannot be persisted due to cfapi
   unavailability).

   example registration payload:

   ```
   POST /publishers/register
   ---
   {
       "agent-id": "de1aac97-6f85-4ba9-b51e-514f48a6a46c",
       "change-feed-id": "vmapi::vm"
   }
   ```

   example change feed entry:

   ```
   POST /feeds/{change-feed-id}/entries
   ---
   /*
    * {number} sequence-id    - Marks this entries position in the log
    * {string} agent-id       - UUID of the publisher-agent (blank until marked)
    * {string} change-feed-id - Feed name, identifies the bucket and content
    * {object} changes        - Properties changed in this entry
    */
   {
       "sequence-id": 63,
       "agent-id": "de1aac97-6f85-4ba9-b51e-514f48a6a46c",
       "change-feed-id": "vmapi::vm",
       "processed": false,
       "changes": {
           "uuid": "78615996-1a0e-40ca-974e-8b484774711a",
           "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
           "alias": "shmeeny",
           "nics": [
            {
              "interface": "net0",
              "mac": "32:4d:c5:55:a7:4d",
              "vlan_id": 0,
              "nic_tag": "external",
              "ip": "10.99.99.8",
              "netmask": "255.255.255.0",
              "primary": true
            }
          ]
       }
   }
   ```

 * Listeners will POST a registration to cfapi. Once registered the listener can
   long poll for change feed entries to the registered change feed.

   example registration payload:

   ```
   POST /listeners/register
   ---
   {
       "listener-id": "de1aac97-6f85-4ba9-b51e-514f48a6a46c",
       "change-feed-id": "vmapi::vm"
   }
   ```

   example long poll result set:

   ```
   {
       changes-list: [
       {
           "sequence-id": 63,
           "changes": {
               "uuid": "78615996-1a0e-40ca-974e-8b484774711a",
               "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
               "alias": "shmeeny",
               "nics": [
                {
                  "interface": "net0",
                  "mac": "32:4d:c5:55:a7:4d",
                  "vlan_id": 0,
                  "nic_tag": "external",
                  "ip": "10.99.99.8",
                  "netmask": "255.255.255.0",
                  "primary": true
                }
              ]
           }
       },
       {
           "sequence-id": 64,
           "changes": {
               "uuid": "78615996-1a0e-40ca-974e-8b484774711a",
               "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
               "alias": "devNullDb01",
               "nics": [
                {
                  "interface": "net0",
                  "mac": "32:4d:c5:55:a7:4d",
                  "vlan_id": 0,
                  "nic_tag": "external",
                  "ip": "10.99.99.8",
                  "netmask": "255.255.255.0",
                  "primary": true
                }
              ]
           }
       }
       ]
   }
   ```

 * Listeners can also ask for change feed items in a given sequence-id range.
   This is useful on startup, and after a crash / partition.

   example sequence-id range query:

   ```
   GET /feeds/{change-feed-id}/entries?beg-sequence-id=63&end-sequence-id=64
   ---
   {
       changes-list: [
       {
           "sequence-id": 63,
           "changes": {
               "uuid": "78615996-1a0e-40ca-974e-8b484774711a",
               "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
               "alias": "shmeeny",
               "nics": [
                {
                  "interface": "net0",
                  "mac": "32:4d:c5:55:a7:4d",
                  "vlan_id": 0,
                  "nic_tag": "external",
                  "ip": "10.99.99.8",
                  "netmask": "255.255.255.0",
                  "primary": true
                }
              ]
           }
       },
       {
           "sequence-id": 64,
           "changes": {
               "uuid": "78615996-1a0e-40ca-974e-8b484774711a",
               "owner_uuid": "930896af-bf8c-48d4-885c-6573a94b1853",
               "alias": "devNullDb01",
               "nics": [
                {
                  "interface": "net0",
                  "mac": "32:4d:c5:55:a7:4d",
                  "vlan_id": 0,
                  "nic_tag": "external",
                  "ip": "10.99.99.8",
                  "netmask": "255.255.255.0",
                  "primary": true
                }
              ]
           }
       }
       ]
   }
   ```


### Listener agent

 * The listener-agent provides client functionality for long polling the
   sdc-changefeed API for notifications. It is a part of the node-sdc-changefeed
   repository. The listener-agent can be included in an existing system or run
   as an agent on its own.

 * After registering with sdc-cfapi, listener-agent long polls sdc-cfapi waiting
   for new change feed entries. When the listener-agent receives new entries
   from sdc-cfapi, it raises an event that can be handled by the consuming
   application. Additionally, it is responsible for keeping track of the last
   seen sequence-id and getting caught up if necessary (either by a range query
   against sdc-cfapi or a snapshot from the publishing system if necessary).

 * Listener-agent needs to be provided with a storage mechanism. It is data
   store agnostic, but it would be wise to choose a durable data store. This is
   used to persist the last seen sequence-id across restarts, crashes, etc.

 * When the listener-agent is in an out of date state, it will buffer incoming
   change feed items while querying sdc-cfapi for the missing range of items or
   retrieving a snapshot from the publishing system.


### The following modifications to Moray will be required

 * To avoid polling Moray for changes, support for PostgreSQL NOTIFY and LISTEN
   operations will be added to Moray.  Database connection exhaustion is a real
   concern here, so we need to expose the NOTIFY and LISTEN functionality to
   Moray consumers via long polling or a similar mechanism.


### The following modifications to publishers will be required

 * Support for a snapshot of the current state of the publishers data store with
   a representative sequence-id.


### Flow


     s = step

            VMAPI
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +
      |                                                     |
      |           +---------+           +---------+         |
      |           |         |           |         |         |
      |           |  VMAPI  |           |   PUB   |         |
      |           |         |           |  AGENT  |--+      |
      |           +---------+           |         |  |      |
      |                |                +---------+  |      |
      |        s1 +----+----+            ^   |  |    |      |
      |           |         |         s2 |   |  |    |      |
      |           v         v            | s3|  |    |      |
      |      +--------+ +--------+       |   |  |    |      |
      |      |        | |        |-------+   |  |    |      |
      |      |   VM   | | VMAPI  |<----------+  |    |      |
      |      | BUCKET | | FEED   |              |    |      |
      |      |        | | BUCKET |          s5a |    |      |
      |      +--------+ |        |<-------------+    |      |
      |                 +--------+                   |      |
      |                                              |      |
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +
                                                     |
           CFAPI                                     |
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +
      |                                           s4 |      |
      |                 +---------------+            |      |
      |                 |               |            |      |
      |                 |     CFAPI     |<-----------+      |
      |                 |               |                   |
      |                 +---------------+                   |
      |                s5b |         |                      |
      |                    v         |                      |
      |               +--------+     |                      |
      |               |        |     |                      |
      |               | STREAM |     |                      |
      |               |  FEED  |     |                      |
      |               | BUCKET |     |                      |
      |               |        |     |                      |
      |               +--------+     |                      |
      |                              |                      |
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +
                                     |
                                  s6 |
          TCNS                       |
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +
      |                              |                      |
      |                              v                      |
      |                          +--------+                 |
      |                          |        |                 |
      |                          |  TCNS  |                 |
      |                          |        |                 |
      |                          +--------+                 |
      |                                                     |
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +




### Steps explained (happy path)

 1. VMAPI persists updated information in its VM bucket(s) and inserts a new
    change feed record into its change feed bucket (Ideally this is done in a
    single transaction and the node-sdc-clients code can assist in that
    behavior).  The data is either persisted to both the VM bucket and the
    change feed bucket or everything is rolled back. Change feed entries, among
    other things, will have a sequence-id, agent-id, and processed fields.

 2. The publisher-agent, running in the same zone as VMAPI and using the same
    Moray, is notified by Moray that a record has been inserted into the change
    feed bucket.

 3. The publisher-agent selects all entries with an empty agent-id and/or all
    entries with an agent-id that matches the publisher-agent and a processed
    field which is empty.  This ensures that an agent crash and restart does not
    leave messages marked but unprocessed.

 4. Publisher-agent POSTs the unprocessed entries to the sdc-changefeed API
    (We'll cover failure scenarios in detail later, but suffice it to say that
    HTTP response codes will be quite helpful).

 5. (a) Assuming step 5 was successful, the publisher-agent will update the
        entries in it's bucket as processed to prevent them from being replayed.
    (b) Under the same assumption that step 5 was successful, sdc-changefeed API
        will persist the change feed entries, in chronological order using the
        sequence-id attached by the publisher-agent, to its own change feed
        bucket.  Persisting each entry in sdc-changefeed API allows listeners to
        ask sdc-changefeed API for a range of entries in the event that they
        miss events due to a crash, restart, etc.  We'll cover more about that
        in later sections.
 6. Sdc-changefeed API notifies long polling listeners (in this case TCNS)
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
   * sdc-changefeed will continue to persist change feed entries without any
     regard for its listener count. It is perfectly reasonable for sdc-changfeed
     to have zero listeners.


 * A listener-agent is partitioned from sdc-changefeed API and within the stored
   sequence-id range
   * listener-agents should attempt to reconnect to sdc-changefeed API with an
     exponential back off. Additionally the agent is required to durably store
     its last seen sequence-id. Storing the last seen sequence-id allows the
     agent to pick up where it left off. Upon reconnecting to sdc-changefeed the
     agent will get the latest sequence-id that sdc-changefeed is aware of.  If
     the sdc-changefeed's sequence-id doesn't match the agent's last seen
     sequence-id it will request all entries after its last seen sequence-id up
     to the current sequence-id from sdc-changefeed API while buffering any
     entries received from long polling.


 * A listener-agent is partitioned from sdc-changefeed API and outside of the
   stored sequence range
   * Since it isn't reasonable, and perhaps infeasible, for sdc-changfeed API to
     persist every event that has ever happened, it will only maintain a
     configurable range of sequence-ids (e.g. 2 days worth).  In the scenario
     where a listener-agent is partitioned from sdc-changefeed API longer than
     the configurable range of sequence-ids can accommodate, the listener-agent
     will need to fetch the current state of the world from the source system
     (e.g VMAPI needs to produce a snapshot of what its state looks like at a
     given sequence-id). Once the listener-agent has caught up with the source
     system it can begin to apply any buffered entries and resume long polling.


 * Sdc-changefeed receives a duplicate entry from a publisher-agent
   * This is a state that realistically shouldn't ever exist. However, if this
     scenario is encountered, sdc-changefeed API should refuse all new entries
     from the publisher-agent in question and alarm loudly because this is a
     state that will likely need manual intervention and inspection of the
     change feed buckets in each subsystem.


 * A listener-agent receives a duplicate entry from sdc-changefeed API
   * The handling of duplicate events at the listener-agent is a correctness
     issue that is left up to the consumer.


### Suggested mechanisms for snapshotting

 * When cfapi has gone beyond its retention time for a given feed and a consumer
   needs to be caught up to the latest sequence-id, the publishing system will
   need to provide a snapshot of its data that corresponds to a given
   sequence-id. The publishing system can create snapshots on any interval, so
   long as they happen more frequently than the retention time.

### Future considerations

 * HA serivce endpoints
   * If we have multiple service endpoints for a publishing system there should
     still only be one writer / publisher-agent

 * Scaling the Publisher Agent
   * Multiple Publisher Agent's are a nice way to scale out, however it presents
     a concurrency challenge to keep the log in chronological order.
