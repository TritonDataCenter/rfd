<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2016 Joyent, Inc.
-->

# Requests for Discussion

Writing down ideas for system enhancement while they are still nascent
allows for important, actionable technical discussion.  We capture
these in **Requests for Discussion**, which are documents in the original
sprit of the [IETF Request for Comments](https://en.wikipedia.org/wiki/Request_for_Comments),
as expressed by [RFC 3](https://tools.ietf.org/html/rfc3):

> The content of a note may be any thought, suggestion, etc. related to
> the software or other aspect of the network.  Notes are encouraged to
> be timely rather than polished.  Philosophical positions without examples
> or other specifics, specific suggestions or implementation techniques
> without introductory or background explication, and explicit questions
> without any attempted answers are all acceptable.  The minimum length for
> a note is one sentence.

> These standards (or lack of them) are stated explicitly for two reasons.
> First, there is a tendency to view a written statement as ipso facto
> authoritative, and we hope to promote the exchange and discussion of
> considerably less than authoritative ideas.  Second, there is a natural
> hesitancy to publish something unpolished, and we hope to ease this
> inhibition.

The philosophy of our Requests for Discussion is exactly this: timely
rather than polished, with the immediate idea of promoting technical
discussion.  Over time, we expect that this discussion will often converge
on an authoritative explanation of new functionality -- but it's entirely
acceptable for an RFD to serve only as a vector of discussion.
(We use the term "Requests for Discussion" in lieu of "Requests for
Comments" to avoid conflation with the IETF construct -- and the more
formal writing that it has come to represent.)

## RFDs

| state    | RFD |
| -------- | ------------------------------------------------------------- |
| publish  | [RFD 1 Triton Container Naming Service](./rfd/0001/README.md) |
| publish  | [RFD 2 Docker Logging in SDC](./rfd/0002/README.md) |
| draft    | [RFD 3 Triton Compute Nodes Reboot](./rfd/0003/README.md) |
| draft    | [RFD 4 Docker Build Implementation For Triton](./rfd/0004/README.md) |
| publish  | [RFD 5 Triton Change Feed Support](./rfd/0005/README.md) |
| draft    | [RFD 6 Improving Triton and Manta RAS Infrastructure](./rfd/0006/README.md) |
| draft    | [RFD 7 Datalink LLDP and State Tracking](./rfd/0007/README.md) |
| publish  | [RFD 9 sdcadm fabrics management](./rfd/0009/README.md) |
| publish  | [RFD 10 Sending GZ Docker Logs to Manta](./rfd/0010/README.md) |
| draft    | [RFD 11 IPv6 and multiple IP addresses support in Triton](./rfd/0011/README.md) |
| draft    | [RFD 12 Bedtime for node-smartdc](./rfd/0012/README.md) |
| draft    | [RFD 13 RBAC v2 for Improved Organization and Docker RBAC Support](./rfd/0013/README.md) |
| draft    | [RFD 14 Signed ZFS Send](./rfd/0014/README.md) |
| draft    | [RFD 15 Reduce/Eliminate runtime LX image customization](./rfd/0015/README.md) |
| predraft | [RFD 16 Manta Metering](./rfd/0016/README.md) |
| draft    | [RFD 17 Cloud Analytics v2](./rfd/0017/README.md) |
| predraft | [RFD 18 Support for using labels to select networks and packages](./rfd/0018/README.md) |
| predraft | [RFD 19 Interface Drift In Workflow Modules](./rfd/0019/README.md) |
| draft    | [RFD 20 Manta Slop-Aware Zone Scheduling](./rfd/0020/README.md) |
| draft    | [RFD 21 Metadata Scrubber For Triton](./rfd/0021/README.md) |
| draft    | [RFD 22 Improved user experience after a request has failed](./rfd/0022/README.md) |
| draft    | [RFD 23 A plan for Manta docs](./rfd/0023/README.md) |
| predraft | [RFD 24 Designation API improvements to facilitate platform update](./rfd/0024/README.md) |
| draft    | [RFD 25 Pluralizing CloudAPI CreateMachine et al](./rfd/0025/README.md) |
| draft    | [RFD 26 Network Shared Storage for Triton](./rfd/0026/README.md) |
| publish  | [RFD 27 Triton Container Monitor](./rfd/0027/README.md) |
| predraft | [RFD 28 Improving syncing between Compute Nodes and NAPI](./rfd/0028/README.md) |
| draft    | [RFD 29 Nothing in Triton should rely on ur outside bootstrapping and emergencies](./rfd/0029/README.md) |
| predraft | [RFD 30 Handling "lastexited" for zones when CN is rebooted or crashes](./rfd/0030/README.md) |
| draft    | [RFD 31 libscsi and uscsi(7I) Improvements for Firmware Upgrade](./rfd/0031/README.md)
| draft    | [RFD 32 Multiple IP Addresses in NAPI](./rfd/0032/README.md) |
| publish  | [RFD 33 Moray client v2](./rfd/0033/README.md) |
| predraft | [RFD 34 Instance migration](./rfd/0034/README.md) |
| draft | [RFD 35 Distributed Tracing for Triton](./rfd/0035/README.md) |
| draft    | [RFD 36 Mariposa](./rfd/0036/README.md) |
| draft    | [RFD 37 Metrics Instrumenter](./rfd/0037/README.md) |
| draft    | [RFD 38 Zone Physical Memory Capping](./rfd/0038/README.md) |
| draft    | [RFD 39 VM Attribute Cache (vminfod)](./rfd/0039/README.md) |
| publish  | [RFD 40 Standalone IMGAPI deployment](./rfd/0040/README.md) |
| draft    | [RFD 41 Improved JavaScript errors](./rfd/0041/README.md) |
| predraft | [RFD 42 Provide global zone pkgsrc package set](./rfd/0042/README.md) |
| draft    | [RFD 43 Rack Aware Network Pools](./rfd/0043/README.md) |
| predraft | [RFD 44 Create VMs with Delegated Datasets](./rfd/0044/README.md) |
| draft    | [RFD 45 Tooling for code reviews and code standards](./rfd/0045/README.md) |
| draft    | [RFD 46 Origin images for Triton and Manta core images](./rfd/0046/README.md) |
| draft    | [RFD 47 Retention policy for Joyent engineering data in Manta](./rfd/0047/README.md) |
| predraft | [RFD 48 Triton A&A Overhaul (AUTHAPI)](./rfd/0048/README.md) |
| predraft | [RFD 49 AUTHAPI internals](./rfd/0049/README.md) |
| predraft | [RFD 50 Enhanced Audit Trail for Instance Lifecycle Events](./rfd/0050/README.md) |
| draft    | [RFD 51 Code Review Guidance](./rfd/0051/README.md) |
| draft    | [RFD 52 Moray test suite rework](./rfd/0052/README.md) |
| draft    | [RFD 53 Improving ZFS Pool Layout Flexibility](./rfd/0053/README.md) |
| predraft | [RFD 54 Remove 'autoboot' when VMs stop from within](./rfd/0054/README.md) |
| draft | [RFD 55 LX support for Namespaces](./rfd/0055/README.md) |
| predraft | [RFD 56 Revamp Cloudapi](./rfd/0056/README.md) |
| draft | [RFD 57 Moving to Content Addressable Docker Images](./rfd/0057/README.md) |
| predraft | [RFD 58 Moving Net-Agent Forward](./rfd/0058/README.md) |
| predraft | [RFD 59 Update Triton to Node.js v4-LTS](./rfd/0059/README.md) |
| draft    | [RFD 60 Scaling the Designation API](./rfd/0060/README.md) |
| predraft | [RFD 61 CNAPI High Availability](./rfd/0061/README.md) |
| predraft | [RFD 62 Replace Workflow API](./rfd/0062/README.md) |
| predraft | [RFD 63 Adding branding to kernel cred\_t](./rfd/0063/README.md) |
| predraft | [RFD 64 Hardware Inventory GRUB Menu Item](./rfd/0064/README.md) |
| draft | [RFD 65 Multipart Uploads for Manta](./rfd/0065/README.md) |
| draft | [RFD 66 USBA improvements for USB 3.x](./rfd/0066/README.md) |
| draft    | [RFD 67 Triton headnode resilience](./rfd/0067/README.md) |
| draft    | [RFD 68 Triton versioning](./rfd/0068/README.md) |
| publish | [RFD 69 Metadata socket improvements](./rfd/0069/README.md) |
| draft | [RFD 70 Joyent Repository Metadata](./rfd/0070/README.md) |
| draft | [RFD 71 Manta Client-side Encryption](./rfd/0071/README.md) |
| predraft | [RFD 72 Chroot-independent Device Access](./rfd/0072/README.md) |
| publish  | [RFD 73 Moray client support for SRV-based service discovery](./rfd/0073/README.md) |
| draft    | [RFD 74 Manta fault tolerance test plan](./rfd/0074/README.md) |
| predraft | [RFD 75 Virtualizing the number of CPUs](./rfd/0075/README.md) |
| draft    | [RFD 76 Improving Manta Networking Setup](./rfd/0076/README.md) |
| predraft | [RFD 77 Hardware-backed per-zone crypto tokens](./rfd/0077/README.md) |
| draft | [RFD 78 Making Moray's findobjects requests robust with regards to unindexed fields](./rfd/0078/README.md) |
| predraft | [RFD 79 Projects API](./rfd/0079/README.md) (part of Mariposa) |
| predraft | [RFD 80 ProjectsConvergence API](./rfd/0080/README.md) (part of Mariposa) |
| predraft | [RFD 81 ServicesHealth agent](./rfd/0081/README.md) (part of Mariposa) |
| predraft | [RFD 82 Triton agents install and update](./rfd/0082/README.md) |
| publish | [RFD 83 Triton `http_proxy` support](./rfd/0083/README.md) |
| predraft | [RFD 84 Providing Manta access on multiple networks](./rfd/0084/README.md) |
| draft    | [RFD 85 Tactical improvements for Manta alarms](./rfd/0085/README.md) |
| predraft | [RFD 86 ContainerPilot 3](./rfd/0086/README.md) |
| predraft | [RFD 87 Docker Events for Triton](./rfd/0087/README.md) |
| predraft | [RFD 88 DC and Hardware Management Futures](./rfd/0088/README.md)
| predraft | [RFD 89 Project Tiresias](./rfd/0089/README.md)


## Contents of an RFD

The following is a way to help you think about and structure an RFD
document. This includes some things that we think you might want to
include. If you're unsure if you need to write an RFD, here are some
occasions where it usually is appropriate:

* Adding new endpoints to an API or creating an entirely new API
* Adding new commands or adding new options
* Changing the behaviour of endpoints, commands, APIs
* Something that changes how users and operators interact with the
  overall system.

RFDs start as a simple markdown file that use a bit of additional metadata
to describe its current state. Every RFD needs a title that serves as a
simple synopsis of the document. (This title is not fixed; RFDs are numbered
to allow the title to change.) In general, we recommend any initial RFD
address and/or ask the following questions:

##### Title

This is a simple synopsis of the document. Note, the title is not fixed.
It may change as the RFD evolves.

##### What problem is this solving?

The goal here is to describe the problems that we are trying to address
that motivate the solution. The problem should not be described in terms
of the solution.

##### What are the principles and constraints on the design of the solution?

You should use this section to describe the first principles or other
important decisions that constrain the problem. For example, a
constraint on the design may be that we should be able to do an
operation without downtime.

##### How will users interact with these features?

Here, you should consider both operators, end users, and developers. You
should consider not only how they'll verify that it's working correctly,
but also how they'll verify if it's broken and what actions they should
take from there.

##### What repositories are being changed, if known?

If it's known, a list of what git repositories are being changed as a
result of this would be quite useful.

##### What public interfaces are changing?

What interfaces that users and operators are using and rely upon are
changing? Note that when changing public interfaces we have to be extra
careful to ensure that we don't break existing users and scripts.

##### What private interfaces are changing?

What interfaces that are private to the system are changing? Changing
these interfaces may impact the system, but should not impact operators
and users directly.

##### What is the upgrade impact?

For an existing install, what are the implications if anything is
upgraded through the normal update mechanisms, e.g. platform reboot,
sdcadm update, manta-adm update, etc. Are there any special steps that
need to be taken or do certain updates need to happen together for this

##### What is the security impact?

What (untrusted) user input (including both data and code) will be used as part
of the change?  Which components will interact with that input?  How will that
input be validated and managed securely?  What new operations are exposed and
which privileges will they require (both system privileges and Triton privileges)?
How would an attacker use the proposed facilities to escalate their privileges?


## Mechanics of an RFD

To create a new RFD, you should do the following steps.

### Allocate a new RFD number

RFDs are numbered starting at 1, and then increase from there. When you
start, you should allocate the next currently unused number. Note that
if someone puts back to the repository before you, then you should just
increase your number to the next available one. So, if the next RFD
would be number 42, then you should make the directory 0042 and place it
in the file 0042.md. Note, that while we use four digits in the
directories and numbering, when referring to an RFD, you do not need to
use the leading zeros.

```
$ mkdir -p rfd/0042
$ cp prototypes/prototype.md rfd/0042/README.md
$
```

### Write the RFD

At this point, you should write up the RFD. Any files that end in `*.md`
will automatically be rendered into HTML and any other assets in that
directory will automatically be copied into the output directory.

RFDs should have a default text width of 80 characters. Any other
materials related to that RFD should be in the same directory.

#### RFD Metadata and State

At the start of every RFD document, we'd like to include a brief amount of
metadata. The metadata format is based on the
[python-markdown2](https://github.com/trentm/python-markdown2/wiki/metadata)
metadata format. It'd look like:

```
---
authors: Han Solo <han.solo@shot.first.org>, Alexander Hamilton <ah@treasury.gov>
state: draft
---
```

We keep track of two pieces of metadata. The first is the `authors`, the
second is the state. There may be any number of `authors`, they should
be listed with their name and e-mail address.

Currently the only piece of metadata we keep track of is the state. The
state can be in any of the following. An RFD can be in one of the
following four states:

1. predraft
1. draft
1. publish
1. abandoned

While a document is in the `predraft` state, it indicates that the work is
not yet ready for discussion, but the RFD is effectively a placeholder.
Documents under active discussion should be in the `draft` state.  Once
(or if) discussion has converged and the document has come to reflect
reality rather than propose it, it should be updated to the `publish`
state.

Note that just because something is in the `publish` state does not
mean that it cannot be updated and corrected. See the "Touching up"
section for more information.

Finally, if an idea is found to be non-viable (that is, deliberately never
implemented) or if an RFD should be otherwise indicated that it should
be ignored, it can be moved into the `abandoned` state.

### Start the discussion

Once you have reached a point where you're happy with your thoughts and
notes, then to start the discussion, you should first make sure you've
pushed your changes to the repository and that the build is working.

From here, send an e-mail to the appropriate mailing list that best fits
your work. The options are:

* [sdc-discuss@lists.smartdatacenter.org](https://www.listbox.com/member/archive/247449/=now)
* [manta-discuss@lists.mantastorage.org](https://www.listbox.com/member/archive/247448/=now)
* [smartos-discuss@lists.smartos.org](https://www.listbox.com/member/archive/184463/=now)

The subject of the message should be the RFD number and synopsis. For
example, if you RFD number 169 with the title  Overlay Networks for Triton,
then the subject would be `RFD 169 Overlay Networks for Triton`.

In the body, make sure to include a link to the RFD.

### Finishing up

When discussion has wrapped up and the relevant feedback has been
incorporated, then you should go ahead and change the state of the
document to `publish` and push that change.

### Touching up

As work progresses on a project, it may turn out that our initial ideas
and theories have been disproved or other architectural issues have come
up. In such cases, you should come back and update the RFD to reflect
the final conclusions or, if it's a rather substantial issue, then you
should consider creating a new RFD.

## Contributing

Contributions are welcome, you do not have to be a Joyent employee to
submit an RFD or to comment on one. The discussions for RFDs happen on
the open on the various mailing lists related to Triton, Manta, and
SmartOS.

To submit a new RFD, please provide a git patch or a pull request that
consists of a single squashed commit and we will incorporate it into the
repository or feel free to send out the document to the mailing list and
as we discuss it, we can work together to pull it into the RFD
repository.
