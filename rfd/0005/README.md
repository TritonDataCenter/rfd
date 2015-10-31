---
authors: Richard Kiene <richard.kiene@joyent.com>
state: draft
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
its logical extreme, polling will hit an upper bound where the time it takes to
complete a request to VMAPI will be slower than what is needed to keep the
appearance of being up to date.

### Goal

Provide a mechanism for state exchange which allows services to scale
sub-linearly in relation to consumer count, reduce overall load, decrease
the delay in eventually consistent data, and provide a better customer
experience.

### Requirements

 1. An individual service should be able to broadcast a state change to an
    arbitrary number of consumers.

 2. Change feed data is does not strictly depend on ordering and only informs
    listeners that something about a resource changed, not exactly what changed.

 3. In the event of a partition, listeners must reconnect and re-bootstrap.

 4. Publishing systems should provide a paginated HTTP API for retrieving the
    current state of a given resource(s). This provides the ability to hydrate
    new or re-connecting listeners.

 5. Each step in the broadcast of a state change should be observable and
    debuggable.

 6. The design should support an HA configuration.

### Assumptions

 * Fetching the entire state of a resource is an expensive operation, but it is
   reasonable to expect that it is possible in a way that doesn't jeopardize the
   system as a whole.

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

### The solution will consist of two main components

 1. Publisher module
 2. Listener module

### Publisher module

 * Residing in the node-sdc-changefeed repository, the publisher module will
   abstract away some of the boilerplate necessary for simultaneously modifying
   the publishers authoritative data store, change feed bucket, and sending
   events to listeners.

 * The publisher module is responsible for providing a websocket interface that
   listeners can receive updates from and an HTTP interface that listeners can
   register for events on.

 * The module will also track current listeners, what they are registered for,
   and publish a collection of available change feed resources via HTTP.

 * On startup the module will obtain the following settings from a configuration
   file (e.g. config.js).
     * The change feed bucket location.
     * The maximum age of a change feed item in the change feed bucket.
     * A list of resources that support change feeds and their respective
       bootstrap routes.


 * Example registration payload (websocket):

   ```
   /changefeeds
   ---
   /*
    * This will be sent by the listener to the change feed route
    *
    * {string} instance       - UUID of the listener / zone
    * {string} service        - Friendly name of the listening service
    *                           (e.g. TCNS)
    * {Object} changeKind     - Object expressing what resource and
    *                           sub-resources to listen for.
    */
   {
       "instance": "de1aac97-6f85-4ba9-b51e-514f48a6a46c",
       "service": "tcns",
       "changeKind": {
            "resource": "vm",
            "subResources": ["nic", "alias"]
       }
   }
   ```

 * Example registration response (websocket):

   ```
   /*
    * This is sent to the listener in response to its registration
    *
    * {string} bootstrapRoute - URI of the route to bootstrap the listener with
    *
    * Used by the listener each time it connects. Bootstrapping via walking the
    * paginated list of data available ensures the listener is up to date.
    */
    {
        "bootstrapRoute": "/vms"
    }
   ```

 * Example change feed item (websocket):

   ```
   /*
    * When changes happen, listeners will receive an object such as this one
    *
    * {Object} changeKind        - Object expressing what type of resource and
    *                              subResource(s) changed.
    * {string} changedResourceId - identifier of the root object that changed
    *
    * In this case we're saying that a VM identified by the given UUID had its
    * nic property changed. The listener would go fetch the VM from VMAPI using
    * the changed-resource-id.
    */
   {
       "changeKind": {
            "resource": "vm",
            "subResources": ["nic"]
           },
       "changedResourceId": "78615996-1a0e-40ca-974e-8b484774711a"
   }
   ```

 * Example statistics request (HTTP):

   ```
   GET /changefeeds/stats
   ---
   {
       "listeners":63,
       "registrations": [
        {
            "instance": "de1aac97-6f85-4ba9-b51e-514f48a6a46c",
            "service": "tcns",
            "changeKind": {
                "resource": "vm",
                "subResources": ["nic", "alias"]
            }
        }
       ]
   }
   ```

 * Example available change feed resources (HTTP):

   ```
   GET /changefeeds
   ---
   {
       "resources": [
        {
            "resource": "vm",
            "subResources": ["nic", "alias"],
            "bootstrapRoute": "/vms"
        }
       ]
   }
   ```

### Listener module

 * The listener module provides client functionality for connecting to a change
   feed via websocket. It is a part of the node-sdc-changefeed repository.

 * When the listener starts up, it connects to the websocket endpoint of the API
   (i.e. the publisher) that is the authoritative source for the events in
   question (e.g. If a listener would like to know about VM change events, it
   will use its existing configuration to talk with VMAPI). The listener sends a
   registration payload to the publisher (see the above publisher module example
   of a registration JSON payload). The registration request contains an object
   consisting of a resource and sub-resources array representing the kind of
   changes it would like to be notified about, its instance, and its service
   name (e.g. TCNS).

 * After registering with a change feed, the listener will be provided with a
   bootstrap route by the change feed source system. The listener must bootstrap
   itself by paging through the set of data returned by the bootstrap route.
   While the listener bootstraps itself it must also buffer incoming events from
   the change feed websocket so that they may be acted upon after bootstrapping
   completes.

 * The bootstrap and buffering process happens each time the listener connects.

 * When the listener receives new change feed items, it raises an event that can
   be handled by the listening system. The event will be associated with the
   change that took place, so that the listening system can act upon it
   accordingly (e.g. fetch that resource from the source system).

 * The listener module has a configurable buffer kind, defaulting to in-memory.
   In the future the buffer could also be configured to use Redis, Memcached,
   etc. The buffer size is configurable via a setting in its config.js.

 * The listener buffer is used in situations where the publisher is pushing
   change feed items to the listener faster than it can handle and also when it
   is bootstrapping. Under all circumstances if the buffer cannot be maintained,
   the listener should abort and re-initiate a registration with the publisher
   using exponential back off.

### Flow


            VMAPI
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +
      |                                                     |
      |           +---------+                               |
      |           |         |                               |
      |           |  VMAPI  | <-----+                       |
      |           |         | <-+   |                       |
      |           +---------+   |   |                       |
      |            |            |   |                       |
      |      +-----+-----+      |   |                       |
      |      |           |      |   |                       |
      |      v           v      |   |                       |
      | +--------+ +--------+   |   |                       |
      | |        | |        |   |   |                       |
      | |   VM   | |  FEED  |   |   |                       |
      | | BUCKET | | BUCKET |   |   |                       |
      | |        | |        |   |   |                       |
      | +--------+ +--------+   |   |                       |
      |                         |   |                       |
      |                         |   |                       |
      + - - - - - - - - - - - - | - | - - - - - - - - - - - +
                                |   |
                (r/w websocket) |   | (HTTP)
                                |   |
          TCNS                  |   |
      + - - - - - - - - - - - - | - | - - - - - - - - - - - +
      |                         |   |                       |
      |                         v   |                       |
      |                     +--------+                      |
      |                     |        |                      |
      |                     |  TCNS  |                      |
      |                     |        |                      |
      |                     +--------+                      |
      |                                                     |
      + - - - - - - - - - - - - - - - - - - - - - - - - - - +


### Steps explained (happy path)

 1. TCNS registers with VMAPI `/changefeed` and establishes a read/write
    websocket connection.

 2. TCNS begins receiving change feed items from VMAPI via websocket, but must
    buffer them until it has been fully bootstrapped.

 3. TCNS pages via HTTP through all available data for the resource(s) it
    registered for, and fetches resource information from VMAPI via HTTP for
    each of the buffered change feed items received via websocket.

 4. VMAPI simultaneously writes to its existing Moray bucket and its change feed
    Moray bucket. -- It's important to note that the change feed Moray bucket is
    a dual purpose mechanism. It provides durability if the service should fail,
    and it also allows for a single feed that multiple publishers can poll, thus
    adding support for HA.

 5. VMAPI's publisher module polls its change feed Moray bucket for entries.
    When entries are found it sends them to TCNS via websocket and deletes
    entries from its change feed Moray bucket that are older than the maximum
    age setting. It is important to note that the publisher module does not care
    if the entry was successfully received by the TCNS listener.

### Failure scenarios

 * If for any reason a listener is partitioned from a publisher, the publisher
   will invalidate the registration. The listener must re-initiate registration
   and the full bootstrapping process. An exponential back off should be used so
   that listeners don't overwhelm the publisher. -- As a future consideration,
   the publisher could also buffer change feed items for a configurable
   duration, should bootstrapping become problematic.

 * If for some reason the publisher cannot send a change feed item to a listener
   it should not fail to persist the initiating change to its Moray bucket.
   Listeners will catch back up as a part of the normal bootstrapping process
   that is required after disconnect.

 * If during the bootstrapping process the listener exceeds its configured
   buffer size (e.g. too many change feed items come in while paging via HTTP).
   The listener should abort and retry with exponential back off.

### Registrations

 * Registrations are always ephemeral. As soon as a registered listener
   disconnects for any reason, the registration and associated data can be
   garbage collected.

 * Registrations use a change kind object to specify the type of change feed
   items they would like to receive.

 * Registrations are only for a single resource and its sub-resources. A new
   registration and websocket will need to be created for each top level
   resource kind.

### High Availability

 * Because the publisher is just a websocket implementation of existing
   functionality, it fits the existing and future HA plans of an API the same
   way a publishing APIs HTTP endpoints do.

 * The polling mechanism of the publisher is also HA compatible because the
   change feed bucket is shared by all publisher modules for a given system
   (e.g. VMAPI).

 * Multiple listeners can exist for a single HA system. Without coordination by
   the listening system, duplicate events may be received, and consequently
   duplicate fetches may happen. There is no correctness consequence for
   duplicate events and fetches.

### Back pressure

 * Publishers should not care about the health of a listener.

 * Listeners should make an attempt to buffer incoming change feed events if
   they are unable to process them as fast as they are received. However, if the
   listeners cannot successfully buffer the incoming change feed items, they
   should abort, clear the buffer, and retry with exponential back off.

### Garbage collection

 * There are two areas where garbage can accumulate, the publishers change feed
   item bucket, and the listeners buffer.
     * Listener garbage collection is handled as items are processed.
       (i.e. The listener will remove items from the buffer as it processes
       them.)
     * Publisher garbage collection is handled by checking for change feed items
       in the bucket that are older than the maximum age when polling for new
       change feed items. (i.e. As a part of polling for new items, the
       publisher also deletes objects it finds that are older than the max age.)

### Logging

 * In the interest of observability, publishers should log registration events,
   listener counts, and listener disconnects. Additionally listeners should log
   their connection attempts, buffer size, and back off status.
