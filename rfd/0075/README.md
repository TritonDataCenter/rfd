---
author: Jerry Jelinek <jerry@joyent.com>
state: predraft
---

# RFD 75 Limiting CPU Visibility

## Problem Statement

We continue to encounter a set of applications which tune their behavior based
on the number of CPUs that they can 'see' on the system. Due to the nature of
zones and the way we use them (i.e. never using a CPU pool), applications will
see all of the CPUs on the machine. This can lead to pathological performance
problems when an application sees many CPUs, but is actually capped at some
smaller amount of CPU time. Typically in this case, the application will create
too many threads and induce a high level of contention, thereby hurting overall
performance. In these cases, the application can actually perform much better
under KVM where it only 'sees' the small number of CPUs allowed for that VM.

This problem has been described in OS-4816 and OS-4821. In addition, it appears
that many Java applications will tune their thread pool based on the number
of visibile CPUs.

Ideally these applications would be smarter or would provide a mechanism
for the user to override this behavior with some explicit tuning. However,
not all applications provide this capability, and even for those that do, this
is a barrier to entry for many customers who are unaware that the problem
even exists. Their experience is simply that the application performs poorly
in a Triton zone vs. elsewhere.

## High Level Solution

At a high level the solution appears easy. We could simply virtualize how
many CPUs are available. This is particularly easy inside of an lx-branded
zone where we already have a Linux /proc and interpose on all of the syscalls.
We could simply round up the zone cpu-cap to the next integer and present that
as the number of CPUs. However, there are a number of potential problems with
this approach.

## Problems

This section describes the known problems with virtualizing the number of CPUs.

1. CPU ID

   Because all CPUs will continue to be available for running threads, it is
   likely that threads will be scheduled on CPUs outside of the range that the
   application thinks is available. This can confuse tools which use the CPU
   ID for observability. It might also break an application which preallocates
   an array for CPU IDs based on how many CPUs it thinks are available.

2. CPU Time

   The cpu-cap accounting works on the quanta of the scheduler, so it is 
   possible for a CPU-bound application that is hitting the cap to sometimes
   get slightly more CPU time than the cap itself. This could confuse
   observability tools which might see more CPU time than is logically
   available.

## Proposed Solution

Because of the flexibility provided by the lx brand, the proposal is to only
fix this for lx.

1. CPU ID

   Report CPU ID modulo the number of "virtual" CPUs.

2. CPU Time

   Cap the reported time at the amount available for the "virtual" CPUs.

## Interposition Points

This section summarizes the locations that would need to be virtualized.

1. /proc

   The lx /proc is the primary interface for observability tools to learn about
   CPU information.

   * /proc/cpuinfo
   * /proc/[pid]/cpuset
   * /proc/[pid]/stat        processor field (39)
   * /proc/[pid]/status      Cpus_allowed
   * /proc/interrupts        ints/cpu
   * /proc/stat              cpu time

