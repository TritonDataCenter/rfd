---
authors: Jerry Jelinek <jerry@joyent.com>
state: draft
---

# RFD 75 Virtualizing the number of CPUs

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

### Complications of the comm page

As a result of the work done in [OS-5192](https://smartos.org/bugview/OS-5192),
the equivalent of the `getcpu(2)` syscall can be accessed via its vDSO
implementation.  This means that enhancing the in-kernel syscall implementation
is inadequate to constrain the observed CPU IDs. However, note that there is no
`getcpu(2)` wrapper in `glibc` and an invocation using the `syscall` function
will make the syscall, so using the `__vdso_getcpu` entry in the vDSO must be
coded up explicitly by an application. It is unclear how many applications
attempt to make use of this value directly from the vDSO.

One way to address this issue would be to push the modulo figure needed for
virtual CPU ID calculation into the comm page.  This is somewhat strange, given
that it is effectively per-process information, unlike everything else in the
page which is global to the system.  Despite that, it does not seem
unreasonable to pull a 'virtual CPU ID limit' from the `kthread_t` or `proc_t`
structure and place it in the approrpiate CPU slot in the comm page when
performing a `swtch()`.

### Complications with processor binding

Under `lx` we support processor binding using the Linux `sched_setaffinity(2)`
syscall. If we virtualize CPUs modulo the cap, this implies that an application
could be binding processes only to low-numbered CPUs. If this is happening
for multiple applications across multiple zones, we could see undesirabled
behavior with contention on low-numbered CPUs and less usage on higher-numbered
CPUs.

After some discussion, it is not really clear that we should actually be
doing processor binding at all. Any assumptions that an application would
make around this being a performance "improvement" will be negated by the
multi-tenant nature of our system. We probably need to revisit the current
implemenation of `sched_setaffinity(2)` and simply pretend that we're
binding, when in fact we won't.

### Interposition Points

This section summarizes the non-vDSO locations that need to be virtualized.

1. /proc

   The lx /proc is the primary interface for observability tools to learn about
   CPU information.

   * /proc/cpuinfo
   * /proc/[pid]/stat        processor field (39)
   * /proc/stat              cpu time
   * /proc/[pid]/cpu         (no change needed, we report an empty file)
   * /proc/[pid]/cpuset      (no change needed, we don't provide this file)
   * /proc/[pid]/status      (no change needed, Cpus\_allowed not provided)
   * /proc/interrupts        (no change needed, we report an empty file)

2. /sysfs

   The lx /sys filesystem also exposes some CPU information.

   *  /sys/devices/system/cpu

3. `getcpu(2)`
