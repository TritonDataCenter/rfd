---
authors: sungo <sungo@joyent.com>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+135%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 <contributor>
-->

# RFD 135 Conch: Job Queue and Real-Time Notifications

## Introduction

As Conch grows, it would benefit from having a common backend for processing
asynchronous jobs and sending notifications about those jobs. Use cases include
but are not limited to:

* Executing tasks locally on a livesys image
* Issuing commands to control multiple livesys systems inside an integrator's
  facility or datacenter
* Executing validations against Conch system reports

## Requirements

### Job Queue

* Conch is written mostly in Perl. It is desirable to maintain this language
  choice to allow the job queue system to leverage existing libraries
* The job queue system must be generic enough to allow disparate application
  types to leverage the system with minimal modifications
* The job queue system must be flexible enough to allow more complex logic, such
  as a workflow engine, to be built on top of it

### Notifications

* The notifications system must use an industry-standard, preferably open,
  protocol to allow interoperability without mandating a particular language
* There is no specific language mandate for the notifications system. However,
  since most of Conch is in Perl, it is desirable to maintain this language
  choice
* The notifications system should offer a pub/sub model


## Technology Choices

### Job Queue

[Minion](https://github.com/kraih/minion) is a Perl-based job queue system. Its
compelling features include:

* Multiple named queues (often used for application isolation or resource
  allocation)
* PostgreSQL backend is available
* Distributed workers
* Parallel processing
* Job dependencies
* Optional plugin based workers
* Named tasks

#### PostgreSQL Backend

Minion uses a fairly simple set of database tables to keep track of tasks
waiting in the queue and to record information about completed tasks. Conch uses
PostgreSQL currently and it is desirable to maintain this technology choice.

That said, Minion also supports SQLite, including its in-memory database type.
This feature is compelling for temporary applications such as a Conch instance
on a USB stick or for testing purposes.

#### Named Tasks

In Minion, tasks are named. They are enqueued using a string name and code
inside a worker uses this name to determine if the worker can process that task.
In most cases, tasks should be named something that makes sense to a human
operator who may be looking at the current queue or a report on a later date.
However, this is not a hard requirement and the systems built on top of Minion
can specific whatever names make sense for the application in question. For
instance, it might be appropriate for an application to use a UUID or database
ID to indicate which code to execute.

#### Plugins

Minion workers can use plugins in addition to, or instead of, embedding the code
directly in the worker. These plugins are perl modules that follow a common
interface. This allows the plugins to be separate from the main worker code,
creating the opportunity for code reuse and, perhaps, open-sourcing the plugins
individually. Plugins can register code for multiple tasks and the plugin
determines the name of the tasks.

#### Distributed Workers

A Minion worker is a standalone application that contains the code necessary to
execute specific named tasks. The worker must be able to reach the backend
database to function. Each worker can contain a unique set of plugins or task
code and many workers can be deployed at the same time.

From a deployment perspective, this allows workers to be added or removed from
production based on operational concerns like system load or backlog. It also
allows for workers to be specialized for their application. Since tasks are
queued based on a string name, as long as all applications use unique names, a
single Minion database can manage all work happening in Conch.

Distributed workers are also the basis for parallel processing. Processing power
is increased by deploying additional workers.

If no workers are online, or no workers are available for a particular task, the
task remains in the queue until a resource is available.

#### Conclusion

Minion is a very capable job queue system and should meet Conch's needs. It will
allow the reuse of existing code, with modifications to match the Minion plugin
interface. More advanced systems can be layered on top of Minion by building
special logic into their queuing applications and workers.

### Notifications

#### Protocol

WebSockets is a two-way communication mechanism introduced in [RFC
6455](https://tools.ietf.org/html/rfc6455) and designed to provide a
long-running data channel between web browsers and a server. Since its
introduction, libraries have been developed for many languages that allow
applications other than web browsers to communicate over a WebSockets
connection.

The protocol itself is fairly simple, providing a basic framing layer on top of
TCP/IP. RFC 6455 does not mandate a particular payload format and provides
specific data frames for text and binary data.

For the case of real-time notifications, WebSockets is compelling both as an
open standard and a communications channel that supports web browsers as well as
backend applications. It is possible for both user-facing and server
applications to share data streams, allowing for the development of monitoring
and alerting dashboards that rely on the exact same data streams the backend
uses for internal regulation. WebSockets would also allow the development of web
based command and control applications to allow operators to control Conch
without requiring command line access or knowledge.

It is recommended that the payload contain serialized JSON in documented
structures such that applications can write and verify data in a strict fashion,
preferably by channel. For instance, the websocket bus named '/bus/livesys'
could contain a different JSON dataset the bus named '/bus/validation'.

#### Software

[Mercury](https://github.com/preaction/Mercury) is a message broker for
WebSockets, written in Perl. It provides a message bus, pub/sub messaging, as
well as push/pull which provides a queue-like channel. Mercury is compelling for
its ease of operation and its multiple communication patterns.

Production operation simply requires installation and execution. There is no
database backend and no other operational requirements, other than network
connectivity from clients to Mercury's listening port.

Of the communication patterns offered by Mercury, pub/sub messaging is
particularly interesting because it allows for hierarchical subscriptions. For
instance, a livesys image could subscribe to "/sub/livesys/$id" and receive
specific instructions while an audit process could subscribe to "/sub/livesys"
and record all instructions sent to all livesys images.

#### Conclusion

Mercury is a solid platform to serve as Conch's messaging bus. The combination
of WebSockets and multiple modes of communication allows for the development of
application-specific data paths while maintaining a common platform or
production instance.

## Concerns

### Scale

While POCs were conducted for both Minion and Mercury, no attempts were made to
determine scaling limits. Minion is the least concerning since its core is
inside PostgreSQL and since Minion allows the deployment of parallel instances
of all parts of the software. Mercury is a potential SPOF, particularly in
initial deployment. It is possible to deploy multiple Mercury instances, perhaps
per application type, but Mercury instances cannot talk to each other. With no
scaling data, it is impossible to predict capacity and form deployment
guidelines in advance.

### Downtime

Of the two systems, Minion has the lowest risk when it comes to downtime. If the
database goes down, Minion cannot launch new tasks but will begin launching
tasks again when the database recovers. However, it is not currently known what
happens to task results or failures during the downtime. This issue should be
studied to determine if results are lost during database downtime. Otherwise, an
outage of all workers will simply cause work to cease but jobs will continue to
be queued in the database. When a worker becomes available, work will continue.

Mercury is a high risk when it comes to downtime. Lacking a database backend,
Mercury cannot recover from an outage. Any in-flight messages will be lost.
WebSockets libraries do not typically offer transmission retries on their own.
As such, while Mercury is offline, all notifications will be dropped and lost
forever.

### Integrating Minion With Mercury

It would be beneficial for activities in Minion to be broadcast into Mercury
with as little effort as possible. Auditing is a significant possible use
case. Specifically it is desirable to create a log of all task work and store it
indefinitely for the purposes of reporting and auditing. The process of auditing
needs to inflict as little burden as possible on application developers.

Currently, the state of the art is a Perl module named Minion::Notifier. It must
be loaded in any application that interacts with Minion, enqueuing or processing
tasks. Once loaded, Notifier sends a short message to Mercury containing the
task id and the action taken. For instance `[ 1234, 'enqueue' ]` where task ID
1234 was enqueued by some application. Other information about the task in
question must be retrieved separately from the database.

This is suboptimal, at least for the auditing use case. Minion does eventually
purge information about completed jobs so just storing the Notifier packets is
not sufficient for long term auditing. Any auditing system would need to catch
the Notifier messages, do a separate lookup in the Minion database, and store
that data in its own system. It would be easier for the auditing system to get a
notification containing all the data known about a task operation.

For now, Minion::Notifier should be sufficient as all interested applications
are likely to be integrated with Minion already. As the design for auditing
grows towards its upcoming RFD, a solution will be needed to provide the
additional necessary data. This should be addressed in the auditing RFD.

## Conclusion

Minion is a solid job queue system that will serve well the needs of Conch, with
no significant reservations.

Mercury is a solid WebSockets broker that will serve well the needs of Conch.
The largest concern is the issue of downtime. Further investigation is warranted
to uncover a general solution.
