<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc.
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
| publish  | [RFD 6 Improving Triton and Manta RAS Infrastructure](./rfd/0006/README.md) |
| draft    | [RFD 7 Datalink LLDP and State Tracking](./rfd/0007/README.md) |
| predraft | [RFD 8 Datalink Fault Management Topology](./rfd/0008/README.md) |
| publish  | [RFD 9 sdcadm fabrics management](./rfd/0009/README.md) |
| publish  | [RFD 10 Sending GZ Docker Logs to Manta](./rfd/0010/README.md) |
| draft    | [RFD 11 IPv6 and multiple IP addresses support in Triton](./rfd/0011/README.md) |
| draft    | [RFD 12 Bedtime for node-smartdc](./rfd/0012/README.md) |
| draft    | [RFD 13 RBAC v2 for Improved Organization and Docker RBAC Support](./rfd/0013/README.md) |
| draft    | [RFD 14 Signed ZFS Send](./rfd/0014/README.md) |
| draft    | [RFD 15 Reduce/Eliminate runtime LX image customization](./rfd/0015/README.md) |
| predraft | [RFD 16 Manta Metering](./rfd/0016/README.md) |
| abandoned | ~~[RFD 17 Cloud Analytics v2](./rfd/0017/README.md)~~ |
| publish  | [RFD 18 Support for using labels to select networks and packages](./rfd/0018/README.md) |
| predraft | [RFD 19 Interface Drift In Workflow Modules](./rfd/0019/README.md) |
| draft    | [RFD 20 Manta Slop-Aware Zone Scheduling](./rfd/0020/README.md) |
| draft    | [RFD 21 Metadata Scrubber For Triton](./rfd/0021/README.md) |
| draft    | [RFD 22 Improved user experience after a request has failed](./rfd/0022/README.md) |
| publish  | [RFD 23 Manta docs pipeline](./rfd/0023/README.md) |
| draft    | [RFD 24 Designation API improvements to facilitate platform update](./rfd/0024/README.md) |
| draft    | [RFD 25 Pluralizing CloudAPI CreateMachine et al](./rfd/0025/README.md) |
| publish  | [RFD 26 Network Shared Storage for Triton](./rfd/0026/README.md) |
| publish  | [RFD 27 Triton Container Monitor](./rfd/0027/README.md) |
| predraft | [RFD 28 Improving syncing between Compute Nodes and NAPI](./rfd/0028/README.md) |
| draft    | [RFD 29 Nothing in Triton should rely on ur outside bootstrapping and emergencies](./rfd/0029/README.md) |
| predraft | [RFD 30 Handling "lastexited" for zones when CN is rebooted or crashes](./rfd/0030/README.md) |
| draft    | [RFD 31 libscsi and uscsi(7I) Improvements for Firmware Upgrade](./rfd/0031/README.md) |
| draft    | [RFD 32 Multiple IP Addresses in NAPI](./rfd/0032/README.md) |
| publish  | [RFD 33 Moray client v2](./rfd/0033/README.md) |
| publish | [RFD 34 Instance migration](./rfd/0034/README.md) |
| draft    | [RFD 35 Distributed Tracing for Triton](./rfd/0035/README.md) |
| draft    | [RFD 36 Mariposa](./rfd/0036/README.md) |
| draft    | [RFD 37 Metrics Instrumenter](./rfd/0037/README.md) |
| publish  | [RFD 38 Zone Physical Memory Capping](./rfd/0038/README.md) |
| draft    | [RFD 39 VM Attribute Cache (vminfod)](./rfd/0039/README.md) |
| publish  | [RFD 40 Standalone IMGAPI deployment](./rfd/0040/README.md) |
| draft    | [RFD 41 Improved JavaScript errors](./rfd/0041/README.md) |
| draft    | [RFD 42 Provide global zone pkgsrc package set](./rfd/0042/README.md) |
| publish  | [RFD 43 Rack Aware Network Pools](./rfd/0043/README.md) |
| predraft | [RFD 44 Create VMs with Delegated Datasets](./rfd/0044/README.md) |
| abandoned | ~~[RFD 45 Tooling for code reviews and code standards](./rfd/0045/README.md)~~ |
| publish  | [RFD 46 Origin images for Triton and Manta core images](./rfd/0046/README.md) |
| publish  | [RFD 47 Retention policy for Joyent engineering data in Manta](./rfd/0047/README.md) |
| predraft | [RFD 48 Triton A&A Overhaul (AUTHAPI)](./rfd/0048/README.md) |
| predraft | [RFD 49 AUTHAPI internals](./rfd/0049/README.md) |
| predraft | [RFD 50 Enhanced Audit Trail for Instance Lifecycle Events](./rfd/0050/README.md) |
| draft    | [RFD 51 Code Review Guidance](./rfd/0051/README.md) |
| draft    | [RFD 52 Moray test suite rework](./rfd/0052/README.md) |
| draft    | [RFD 53 Improving ZFS Pool Layout Flexibility](./rfd/0053/README.md) |
| predraft | [RFD 54 Remove 'autoboot' when VMs stop from within](./rfd/0054/README.md) |
| abandoned | ~~[RFD 55 LX support for Mount Namespaces](./rfd/0055/README.md)~~ |
| predraft | [RFD 56 Revamp Cloudapi](./rfd/0056/README.md) |
| publish  | [RFD 57 Moving to Content Addressable Docker Images](./rfd/0057/README.md) |
| predraft | [RFD 58 Moving Net-Agent Forward](./rfd/0058/README.md) |
| publish  | [RFD 59 Update Triton to Node.js v4-LTS](./rfd/0059/README.md) |
| draft    | [RFD 60 Scaling the Designation API](./rfd/0060/README.md) |
| draft    | [RFD 61 CNAPI High Availability](./rfd/0061/README.md) |
| predraft | [RFD 62 Replace Workflow API](./rfd/0062/README.md) |
| abandoned | ~~[RFD 63 Adding branding to kernel cred\_t](./rfd/0063/README.md)~~ |
| predraft | [RFD 64 Hardware Inventory GRUB Menu Item](./rfd/0064/README.md) |
| publish | [RFD 65 Multipart Uploads for Manta](./rfd/0065/README.md) |
| draft | [RFD 66 USBA improvements for USB 3.x](./rfd/0066/README.md) |
| draft    | [RFD 67 Triton headnode resilience](./rfd/0067/README.md) |
| draft    | [RFD 68 Triton versioning](./rfd/0068/README.md) |
| publish | [RFD 69 Metadata socket improvements](./rfd/0069/README.md) |
| draft | [RFD 70 Joyent Repository Metadata](./rfd/0070/README.md) |
| publish | [RFD 71 Manta Client-side Encryption](./rfd/0071/README.md) |
| abandoned | ~~[RFD 72 Chroot-independent Device Access](./rfd/0072/README.md)~~ |
| publish  | [RFD 73 Moray client support for SRV-based service discovery](./rfd/0073/README.md) |
| draft    | [RFD 74 Manta fault tolerance test plan](./rfd/0074/README.md) |
| abandoned | ~~[RFD 75 Virtualizing the number of CPUs](./rfd/0075/README.md)~~ |
| draft    | [RFD 76 Improving Manta Networking Setup](./rfd/0076/README.md) |
| draft    | [RFD 77 Hardware-backed per-zone crypto tokens](./rfd/0077/README.adoc) |
| publish | [RFD 78 Making Moray's findobjects requests robust with regards to unindexed fields](./rfd/0078/README.md) |
| predraft | [RFD 79 Reserved for Mariposa](./rfd/0079/README.md) |
| predraft | [RFD 80 Reserved for Mariposa](./rfd/0080/README.md) |
| predraft | [RFD 81 Reserved for Mariposa](./rfd/0081/README.md) |
| draft | [RFD 82 Triton agents install and update](./rfd/0082/README.md) |
| publish | [RFD 83 Triton `http_proxy` support](./rfd/0083/README.md) |
| predraft | [RFD 84 Providing Manta access on multiple networks](./rfd/0084/README.md) |
| publish  | [RFD 85 Tactical improvements for Manta alarms](./rfd/0085/README.md) |
| publish | [RFD 86 ContainerPilot 3](./rfd/0086/README.md) |
| predraft | [RFD 87 Docker Events for Triton](./rfd/0087/README.md) |
| publish  | [RFD 88 DC and Hardware Management Futures](./rfd/0088/README.md) |
| publish  | [RFD 89 Project Tiresias](./rfd/0089/README.md) |
| predraft | [RFD 90 Handling CPU Caps in Triton](./rfd/0090/README.md) |
| predraft | [RFD 91 Application Metrics in SDC and Manta](./rfd/0091/README.md) |
| predraft | [RFD 92 Triton Services High Availability](./rfd/0092/README.md) |
| publish  | [RFD 93 Modernize TLS Options](./rfd/0093/README.md) |
| draft | [RFD 94 Global Zone metrics in CMON](./rfd/0094/README.md) |
| publish | [RFD 95 Seamless Muppet Reconfiguration](./rfd/0095/README.md) |
| publish | [RFD 96 Named thread API](./rfd/0096/README.md) |
| draft | [RFD 97 Project Hookshot - Improved VLAN Handling](./rfd/0097/README.md) |
| predraft | [RFD 98 Issue Prioritisation Guidelines](./rfd/0098/README.md) |
| publish   | [RFD 99 Client Library for Collecting Application Metrics](./rfd/0099/README.md) |
| draft    | [RFD 100 Improving lint and style checks in JavaScript](./rfd/0100/README.md) |
| draft | [RFD 101 Models for operational escalation into engineering](./rfd/0101/README.md) |
| publish | [RFD 102 Requests for Enhancement](./rfd/0102/README.md) |
| draft    | [RFD 103 Operationalize Resharding](./rfd/0103/README.md) |
| draft    | [RFD 104 Engineering Guide - General Principles](./rfd/0104/README.md) |
| draft    | [RFD 105 Engineering Guide - Node.js Best Practices](./rfd/0105/README.md) |
| abandoned | ~~[RFD 106 Engineering Guide - Go Best Practices](./rfd/0106/README.adoc)~~ |
| publish  | [RFD 107 Self assigned IP's and reservations](./rfd/0107/README.md) |
| draft    | [RFD 108 Remove Support for the Kernel Memory Cage](./rfd/0108/README.md) |
| predraft | [RFD 109 Run Operator-Script Earlier during Image Creation](./rfd/0109/README.md) |
| predraft | [RFD 110 Operator-Configurable Throttles for Manta](./rfd/0110/README.md) |
| publish  | [RFD 111 Manta Incident Response Practice](./rfd/0111/README.md) |
| draft    | [RFD 112 Manta Storage Auditor](./rfd/0112/README.md) |
| publish  | [RFD 113 x-account image transfer and x-DC image copying](./rfd/0113/README.md) |
| predraft | [RFD 114 GPGPU Instance Support in Triton](./rfd/0114/README.md) |
| draft    | [RFD 115 Improving Manta Data Path Availability](./rfd/0115/README.md) |
| predraft | [RFD 116 Manta Bucket Exploration](./rfd/0116/README.md) |
| predraft | [RFD 117 Network Traits](./rfd/0117/README.md) |
| draft    | [RFD 118 MAC Checksum Offload Extensions](./rfd/0118/README.md)
| draft    | [RFD 119 Routing Between Fabric Networks](./rfd/0119/README.md)
| abandoned | ~~[RFD 120 The Triton Router Object, phase 1 (intra-DC, fabric only)](./rfd/0120/README.md)~~ |
| predraft | [RFD 121 bhyve brand](./rfd/0121/README.md)
| draft    | [RFD 122 Per-brand resource and property customization](./rfd/0122/README.md)
| predraft | [RFD 123 Online Manta Garbage Collection](./rfd/0123/README.md)
| draft    | [RFD 124 Manta Incident Response Guide](./rfd/0124/README.md)
| predraft | [RFD 125 Online Schema Changes in Manta](./rfd/0125/README.md)
| draft    | [RFD 126 Zone Configuration Conversions](./rfd/0126/README.md)
| predraft | [RFD 127 In-process Brand Hooks](./rfd/0127/README.md)
| draft    | [RFD 128 VXLAN Tunneling Performance Improvements](./rfd/0128/README.md)
| predraft | [RFD 129 Manta Performance Bottleneck Investigation](./rfd/0129/README.md)
| predraft | [RFD 130 The Triton Remote Network Object](./rfd/0130/README.md)
| predraft | [RFD 131 The Triton Datacenter API (DCAPI)](./rfd/0131/README.md)
| publish  | [RFD 132 Conch: Unified Rack Integration Process](./rfd/0132/README.md) |
| publish  | [RFD 133 Conch: Improved Device Validation](./rfd/0133/README.md) |
| publish  | [RFD 134 Conch: User Access Control](./rfd/0134/README.md) |
| draft    | [RFD 135 Conch: Job Queue and Real-Time Notifications](./rfd/0135/README.md) |
| draft    | [RFD 136 Conch: Orchestration](./rfd/0136/README.md) |
| publish  | [RFD 137 CPU Autoreplacement and ID Synthesis](./rfd/0137/README.md) |
| predraft | [RFD 138 Multi-subnet Admin Networks](./rfd/0138/README.md) |
| predraft | [RFD 139 Node.js test frameworks and Triton guidelines](./rfd/0139/README.md) |
| predraft | [RFD 140 Conch: Datacenter Designer](./rfd/0140/README.md) |
| predraft | [RFD 141 Platform Image Build v2 (PIBv2)](./rfd/0141/README.md) |
| draft    | [RFD 142 Use SMF logging for Manta services](./rfd/0142/README.md) |
| draft    | [RFD 143 Manta Scalable Garbage Collection Plan](./rfd/0143/README.md) |
| predraft | [RFD 144 Conch: Datacenter Switch Automation](./rfd/0144/README.md) |
| publish | [RFD 145 Lullaby 3: Improving the Triton/Manta builds](./rfd/0145/README.md) |
| predraft | [RFD 146 Conch: Inventory System](./rfd/0146/README.md) |
| publish  | [RFD 147 Project Tiresias: USB Topology](./rfd/0147/README.md) |
| abandoned | ~~[RFD 148 Snapper: VM Snapshots](./rfd/0148/README.md)~~ |
| draft    | [RFD 149 PostgreSQL Schema For Manta buckets](./rfd/0149/README.md) |
| draft    | [RFD 150 Operationalizing Prometheus, Thanos, and Grafana](./rfd/0150/README.md) |
| publish  | [RFD 151 Assessing Software Engineering Candidates](./rfd/0151/README.md) |
| draft | [RFD 152 Rack Aware Networking](./rfd/0152/README.md) |
| draft    | [RFD 153 Incremental metadata expansion for Manta buckets](./rfd/0153/README.md) |
| publish  | [RFD 154 Flexible disk space for bhyve VMs](./rfd/0154/README.md) |
| publish | [RFD 155 Manta Buckets API](./rfd/0155/README.md) |
| publish  | [RFD 156 SmartOS/Triton Boot Modernization](./rfd/0156/README.md) |
| draft    | [RFD 157 Notices to Operators](./rfd/0157/README.md) |
| draft | [RFD 158 NAT Reform, including public IPs for fabric-attached instances.](./rfd/0158/README.md) |
| draft    | [RFD 159 Manta Storage Zone Capacity Limit](./rfd/0159/README.md) |
| predraft | [RFD 160 CloudWatch-like Metrics for Manta](./rfd/0160/README.md) |
| predraft | [RFD 161 Rust on SmartOS/illumos](./rfd/0161/README.md) |
| predraft | [RFD 162 Online repair and rebalance of Manta objects](./rfd/0162/README.md) |
| draft | [RFD 163 Cloud Firewall Logging](./rfd/0163/README.md) |
| draft | [RFD 164 Open Source Policy](./rfd/0164/README.md) |
| draft | [RFD 165 Security Updates for Triton/Manta Core Images](./rfd/0165/README.md) |
| draft | [RFD 166 Improving phy Management](./rfd/0166/README.md) |
| predraft | [RFD 167 Drop i386 and multiarch Package Sets](./rfd/0167/README.md) |
| draft | [RFD 168 Bootstrapping a Manta Buckets deployment](./rfd/0168/README.md) |
| draft | [RFD 169 Encrypted kernel crash dump](./rfd/0169/README.md) |
| draft | [RFD 170 Manta Picker Component](./rfd/0170/README.md) |
| abandoned | ~~[RFD 171 A Proposal for Manta SnapLinks](./rfd/0171/README.md)~~ |
| predraft | [RFD 172 CNS Aggregation](./rfd/0172/README.md) |
| predraft | [RFD 173 KBMAPI and kbmd](./rfd/0173/README.adoc) |
| draft | [RFD 174 Improving Manta Storage Unit Cost (iSCSI)](./rfd/0174/README.md) |
| publish | [RFD 175 SmartOS integration process changes](./rfd/0175/README.md) |
| predraft | [RFD 176 SmartOS boot from ZFS pool](./rfd/0176/README.md) |
| predraft | [RFD 177 Linux Compute Node Umbrella](./rfd/0177/README.md) |
| predraft | [RFD 178 Linux Platform Image](./rfd/0178/README.md) |
| predraft | [RFD 179 Linux Compute Node Networking](./rfd/0179/README.md) |
| predraft | [RFD 180 Linux Compute Node Containers](./rfd/0180/README.md) |
| draft | [RFD 181 Improving Manta Storage Unit Cost (MinIO)](./rfd/0181/README.md) |
| draft | [RFD 182 Altering system pool detection in SmartOS/Triton](./rfd/0182/README.md) |

## Contents of an RFD

The following is a way to help you think about and structure an RFD
document. This includes some things that we think you might want to
include. If you're unsure if you need to write an RFD, here are some
occasions where it usually is appropriate:

* Adding new endpoints to an API or creating an entirely new API
* Adding new commands or adding new options
* Changing the behaviour of endpoints, commands, APIs
* Otherwise changing the implementation of a component in a significant way
* Something that changes how users and operators interact with the
  overall system.
* Changing the way that software is developed or deployed
* Changing the way that software is packaged or operated
* Otherwise changing the way that software is built

This is deliberately broad; the most important common strain across RFDs
is that they are technical documents describing implementation considerations
of some flavor or another.  Note that this does not include high-level
descriptions of desired functionality; such requests should instead phrased
as [Requests for Enhancement](./rfd/0102/README.md).

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

If an RFD is in the `predraft` or `draft` state, you should also [open an
issue](https://github.com/joyent/rfd/issues) to allow for additional
opportunity for discussion of the RFD.  This issue should have the synopsis
that reflects its purpose (e.g. "RFD 169: Discussion") and the body should
explain its intent (e.g. "This issue represents an opportunity for discussion
of RFD 169 while it remains in a pre-published state.").  Moreover, a
`discussion` field should be added to the RFD metadata, with a URL that
points to an issue query for the RFD number.  For example:

```
---
authors: Chewbacca <chewie77@falcon.org>
state: draft
discussion: https://github.com/joyent/rfd/issues?q="RFD+169"
---
```

When the RFD is transitioned into the `publish` state, the discussion issue
should be closed with an explanatory note (e.g. "This RFD has been published
and while additional feedback is welcome, this discussion issue is being
closed."), but the `discussion` link should remain in the RFD metadata.

Note that discussion might happen via more than one means; if discussion is
being duplicated across media, it's up to the author(s) to reflect or otherwise
reconcile discussion in the RFD itself.  (That is, it is the RFD that is
canonical, not necessarily the discussion which may be occurring online,
offline, in person, over chat, or wherever human-to-human interaction can be
found.)

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
