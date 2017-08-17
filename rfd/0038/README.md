---
authors: Jerry Jelinek <jerry@joyent.com>
contributors: Joshua Clulow <jclulow@joyent.com>
state: predraft
---

# RFD 38 Zone Physical Memory Capping

## Summary

Various resource limits can be set on a zone to control how much of a specific
system resource the zone can consume. Almost all of these limits are defined in
terms of an rctl (see the resource\_controls(5) man page) and set a hard cap on
the amount of the resource the zone can consume. However, the consumption of
physical memory falls into a separate category.

On a typical demand-paged virtual memory (VM) system, such as the one on
SmartOS, physical memory can be thought of as a page cache. Obviously the page
must be in physical memory to be used by the CPU, but each page has a backing
store, so pages can be freed and the physical page re-used for some other
backing object. The goal of the physical memory cap is to improve fairness
by trying to ensure that a single zone does not use more than its fair share
of the physical memory page cache at the expense of other zones.

There are a number of problems with the existing approach for physical memory
capping and we have pushed the current implementation about as far as possible.
The problems are described in this RFD, but to summarize, physical memory
capping is hard to enforce, can induce unacceptable latency onto the
application, and is hard to accurately observe. A new approach is needed to
address the known problems.

## Current Behavior

The 'zoneadmd' associated with a zone is responsible for physical memory
capping. A thread will periodically run to determine the zone's overall
resident set size (RSS). When the thread determines that the zone is over its
cap, it will start iterating processes within the zone. It will grab each
process in turn and invalidate page mappings until the RSS has dropped below
the cap. If the RSS goes above the cap again at a later time, the thread picks
up where it left off and continues this activity.

## Issues

This section describes the current problems with physical memory capping in
more detail.

1. Accurate Accounting

   One of the primary issues is that there is no good way to determine how much
   physical memory a zone is consuming. This is because pages can be shared
   among multiple processes which map the backing object (e.g. each process
   which maps libc will back to the same file and share pages that come
   from libc). Furthermore, these pages can be shared across zones. Taking
   the libc example, a process in one zone might map in libc, then another
   process in a different zone will map in libc and re-use the pages that were
   first brought into memory by the process in the first zone.

   In general, this behavior is advantageous and improves overall memory
   usage on the system, but inaccurate accounting is problematic for any
   physical memory capping solution.

   One type of application illustrates this problem. Some database applications
   will fork many processes for scalability. Each of these will map in the same
   large database files. All of these pages will be shared within the zone, but
   a naive accounting will make this zone appear to be using much more physical
   memory than is actually in use.

   Determining an accurate accounting of physical pages is expensive because
   of the way that the VM system works. It is easy to identify which pages are
   in-memory for an individual address space (a top-down process view), but
   there is no easy way to determine which address spaces a page belongs to (a
   bottom-up page view). Thus, to obtain an accurate count of physical page
   usage, all processes must be examined and page usage must be coalesced in a
   top-down manner.

   The "History" section below describes the background and current handling of
   this issue in more detail.

2. Soft cap

   Because our VM system is demand-paged, whenever a page which is not resident
   is accessed, a page fault occurs, the page is brought into physical memory
   from the backing object, and execution is then allowed to continue. Thus,
   as a whole, the only hard limit on physical pages is the actual amount of
   memory in the system. There are independent, asynchronous mechanisms, such
   as the page scanner or swapping, which are used to free up physical pages
   when the system starts to get low. Any per-zone mechanism for capping
   physical memory should follow this general approach. In particular, any kind
   of memory partitioning scheme should be avoided, since this would reduce
   efficiency and tenancy of the system as a whole. Thus, per-zone physical
   memory capping should always be thought of more as a soft cap than a hard
   limit.

3. Application memory usage patterns

   Many applications are "memory aware". That is, they ask the system how
   much memory is present and then scale their usage appropriately. Because
   we virtualize the reported amount of memory based on the cap, the
   application will see the memory value that is set on the zone.

   However, some applications will use physical memory as a page cache and
   simply depend on the VM system to manage residency as necessary. These
   types of applications can demand page in as much data as possible. One
   example is MongoDB, which maps in all of its large database files (this
   can lead to an address space usage of tens to hundreds of GB) and then
   simply accesses these pages. This style of behavior is not very well suited
   to a multi-tenant environment (either multiple zones or even a multi-user
   system), because the VM system has no ability to manage fairness across
   applications. In addition, even determining the resident set of a process
   with a multi-GB address space can become expensive.

4. Stopping a process

   Our current mechanism for coalescing the page residency data to get an
   accurate RSS for the zone depends on locking each process while we
   traverse its address space. This pause is not noticeable for the typical
   small process, but can become noticeable once a process address space
   becomes large (tens of GB), as described above. This pause can cause
   noticeable latency issues for some applications and we strive hard to avoid
   this. In addition, our current mechanism for invalidating pages when we're
   over the cap also locks the process, and suffers from the same latency
   concern on large processes.

5. Pathological capping

   The combination of inaccurate RSS numbers, demand paging and large address
   spaces can lead to situations where we never truly get the zone under its
   memory cap. This is particularly problematic when the zone is hosting one
   very large process which accounts for the majority of the zone's RSS (see
   the MongoDB example above). In this situation we can wind up continuously
   trying to cap the zone. The locking for accounting and page invalidation
   can lead to poor performance for the applications in the zone.

## History

This section reviews the history of how the system has tried to address memory
capping over time.

The first solution for memory capping was provided by the 'rcapd' daemon. This
originally was implemented to provide memory capping for projects, then
extended to also cap zones. There were a number of problems with rcapd:

   * At the time there was no mechanism to get an accurate RSS for the zone,
     so sometimes a zone would be incorrectly capped when it was actually well
     under it's limit, due to shared pages. 

   * The daemon was a single process responsible for capping all projects and
     zones on the system, so it was easy for it to get very far behind.

   * Setting, managing and observing the zone memory cap used a different
     mechanism from the normal rctl & kstat mechanism used for all other zone
     limits.

To address the issue of inaccurate RSS data, a new, private system call
was added; 'getvmusage'. This syscall can calculate a correct, aggregated
RSS for a given type of container (e.g. a project or zone). Because this is
implemented in the kernel, it is more efficient at this calculation, but the
code still locks the process while traversing the address space, so latency
issues can occur, as described earlier. Various user-level tools, such as 'rcapd'
and 'prstat', were enhanced to make use of this new system call when they
need RSS data for a project or zone.

To improve the scalability of zone capping, 'zoneadmd' was enhanced to use
an internal thread to cap only the zone the daemon is managing. The 'rcapd' is
no longer involved in zone memory capping, but can still be used to cap
projects. As part of this integration, the zone memory cap was changed to
look more like a true rctl. Although there is no in-kernel code enforcing the
cap, the value is managed like any other rctl and 'zoneadmd' will use a private
interface into the kernel to set/get the values associated with the rctl.
A kstat was also added for observability and 'zoneadmd' will set values on the
kstat as it runs.

As we built up real world experience with memory capping and learned more
about the latency issues that occur in some cases, 'zoneadmd' was enhanced to
avoid the 'getvmusage' syscall as much as possible. Use of the lightweight, but
inaccurate per-process RSS was emphasized, with 'getvmusage' only being called
when it appears that the zone has gone over the cap. The 'prstat' command was
also changed to avoid 'getvmusage' unless an accurate RSS was explicitly
requested. Currently 'zoneadmd' uses a moderately complex RSS scaling mechanism
to further reduce the calls to 'getvmusage' while still trying to maintain a
reasonable approximation of the RSS.

To invalidate pages 'zoneadmd' originally used the proc 'pr_memcntl' call
to inject an 'MS_INVALIDATE' onto the victim process. Later this was changed
to an 'MS_INVALCURPROC'. Both of these required the memory capper to 'Pgrab'
the victim process via proc. This stops the process, which can cause the latency
issues described earlier. Later 'zoneadmd' was changed so that it now uses a
private \_RUSAGESYS_INVALMAP kernel syscall to minimize the disruption to the
victim process, although locking still has to occur while invalidating the
pages.

As part of the historical overview, it is worth summarizing the system's
existing mechanisms for managing physical memory.

In general, the system strives to keep memory as full as possible. There is
no benefit to freeing pages until the system is under memory pressure.
Once the system enters this state, the well known two-handed page scanner will
start going through the pages and marking them as candidates for freeing.
The second hand of the page scanner leverages the 'accessed' and 'modified'
bits on the page to determine if the page has been used since the first hand
passed over. The second hand will free pages that have not been accessed.
The scanning stops once enough pages have been freed.

Pages that are not dirty can be immediately put on the cache list, whereas
dirty pages must be flushed to their backing store before being added to the
cache list. Pages on the cache list can be reclaimed if they are accessed again
before being re-used for some other object.

If memory pressure becomes severe, entire processes can be swapped out of
physical memory, although once in this state, the system is likely to be
thrashing. On a modern system with a large memory, swapping is normally not
seen.

## High Level Summary

Our approach is based on the system's page scanner and attempts
to be minimally invasive in the VM system.

   1. We will ignore pages shared across zones. By the very definition of
      SmartOS, there is only a small amount (< 200MB) of program text shipped
      in the GZ that could be shared. Any pages shared from there are likely in
      use by many zones and are uninteresting to the overall application memory
      consumption of a zone. Also, by ignoring cross-zone shared pages we can
      take advantage of the 'referenced' and 'modified' bits on each page to
      know how a zone is using the page.

   2. We need a better mechanism to track an on-going accurate count of
      overall page residency for a zone. This is a prerequisite to any other
      improvements in capping. This accounting mechanism should work in
      conjunction with the next item. The count is used to determine when the
      page scanner runs for the zone. We will track page "ownership" by zone.

   3. We should leverage the system's approach for the page scanner when the
      zone is over its memory cap and start freeing pages from within
      the kernel. In particular, we want to scan pages bottom-up, and not have
      to go top-down from processes inside the zone. We want to avoid the
      process locking the top-down approach entails, since it causes the
      latency issues described earlier. We will use the traditional two-handed
      approach for the scanner to determine which pages are candidates to be
      freed.

## High-Level Design Outline

We want to keep the VM changes as simple and as low-overhead as possible.
This outline describes a design with minimal impact on the VM system.
There are also some more complex options, described later in this document,
which can be considered for future work, if we determine it is necessary.

   1. We will add a zoneid to each page\_t to track the page's zone ownership
      (p\_zoneid). We want to minimize additions to the page\_t since that space
      adds up.  The current size of the page\_t is 120 bytes and a 128GB machine
      has 33 million pages. Adding p\_zoneid adds either 4 bytes, or 0 bytes if
      we repurpose p\_sharepad.

   2. The new p\_zoneid member will be set to ALL\_ZONES for pages that are in
      use by the kernel, that are free, or that are in use by multiple zones.
      Otherwise, it will be set to the zoneid that is using the page.

   3. hment\_insert(), hment\_remove() and hment\_assign() are where we
      hook in for zone ownership tracking.

   4. We keep a count of the total number of unshared pages (pages used only by
      that zone) within the zone\_t.

   5. When a process first gets a new page, we set the page's p\_zoneid to the
      current zoneid and increment the zone's page counter.

   6. If another zone gets the same page, we decrement the owning zone's
      page counter and reset p\_zoneid to ALL\_ZONES.

   7. There will be two new functions to hook into hment\_insert(),
      hment\_remove() and hment\_assign().

          add_page_mapping(page_t *pp)
              if p_share is 0 (i.e. 1st mapping), set p_zoneid and incr zone cnt
              else if p_zoneid matches current zone, do nothing
              else decr zone cnt and set p_zoneid to ALL_ZONES

          rm_page_mapping(page_t *pp)
              if p_zoneid == ALL_ZONES, do nothing
              else if p_share is 0 decr zone cnt and set p_zoneid to ALL_ZONES

      Since we're using a zoneid for p\_zoneid, add\_page\_mapping() will have
      to do a zone lookup by id for the 3rd condition (page now being shared
      with a different zone). The cost for this is probably fine since
      cross-zone sharing is less common.

   7. When a zone's page counter hits the zone's physical memory cap we must
      add the zoneid to a list of zoneid's for page scanning. We will use a
      boolean array indexed by zoneid for direct lookup by the scanner. We
      also keep a count of how many zones are over their cap and we must
      also make sure the page scanner knows it has to run.

   8. The pageout\_scanner() continues to do its current work when the entire
      machine is low on memory. Otherwise, if there are any zones in the list
      of zones to pageout (based on the array counter), then it will also scan.

      For zone-related scanning, the scanner will check the page's p\_zoneid
      against the entry in the over-memory array. If that bit is set, the page
      is a candidate for being reclaimed. The scanner continues to use the
      normal two-handed algorithm so that checkpage() on the backhand will
      reclaim pages that haven't been used recently. The logic for when
      the pageout scanner runs will need to be updated to check the zoneid
      array counter and we need to change some of the tunables around keeping
      this going when we have zones over their cap (based on the counter).

   9. Once a zone goes below its physical memory cap, we clear the zoneid bit
      in the zone pageout array and decrement the counter. If the array counter
      is 0, the scanner can stop running.

   10. The zone physical memory cap will still be a soft cap. That is, we
       won't change page\_create\_throttle() or do anything to prevent new
       pages being used by a zone that is over its cap. We can revisit this
       later, once the core work is complete.

The benefits of this approach is that we have an accurate and relatively
inexpensive value for a zone's RSS and we integrate with the existing and
stable pageout\_scanner(). There is still only a single pageout scanner
running and it uses the tried and true technique to reclaim pages.
Handling a zone halt is easy since processes will release their
page reference as they terminate (so zone cleanup happens in hment\_remove).
We can also verify the page scanner array entry for that zoneid is clear on
zone halt.

The downside is that we'll be hooking in zone-awareness down at the page level.
A secondary issue is memory capping for projects. I think projects are not
widely used and not worth adding even more complexity here for that.
Existing project memory capping can be used for anyone who cares about that.
However, see `Alternative 3` below.

### Alternative 1

Track a list of pages that are in-use by the zone. Use a
zone-specific pageout scanner for when the zone is over its cap.

This would modify the design above so that in add\_page\_mapping() we would add
the page to a new AVL tree on the zone. We also remove it from the AVL tree as
necessary. We need insert and removal for this zone list to be fast since this
is in the hment\_insert(), hment\_remove() and hment\_assign() code paths, so
an AVL tree on the zone makes the most sense. Non-zone pages (kernel, free,
shared across zones, etc.) won't be in any zone AVL tree.

We would add a new avl\_node\_t element to each page\_t so that the page can be
maintained on the zone's tree. This would add 24 bytes to each page\_t in
addition to the p\_zoneid we're already going to be adding.

When a zone hits its memory cap we would create a kernel task to perform
page scanning on the list of pages associated with the zone. This scanning
would behave in essentially the same way as the system pageout scanner, using
the two-handed mark and sweep algorithm

Locking for this task is complex. We can't simply lock the zone's AVL tree
while we scan the pages since that would block all normal activity for the
zone through hment\_insert(), hment\_remove() and hment\_assign(). The
scanner would have to periodically release the AVL tree lock and figure out
where to resume scanning when it reaquired the lock.  There are also additional
locking concerns around interaction with the system's pageout\_scanner() if
both are running. All of this has the potential to reintroduce the latency
bubbles that we've worked hard to eliminate in the existing memory capping code.

Because of the additional cost (memory/page) and complexity of this alternative,
it is not being considered for the initial implemenation. This approach
could be revisited at a later date if it is determined that the single system
pageout\_scanner() is inadequate.

### Alternative 2

Multiple page scanners.

If we determine that the single set of "clock hands" that we use for the
pageout scanner is not sufficient to handle the additional zone-oriented memory
capping, a straightforward extension would be to support multiple pairs of
hands that start out spread evenly around the "clock face" of memory.
If the front hand of one pair runs into the back hand of a different pair,
we would rebalance all of the hands around the clock again.

This approach is not part of the current design, but could be added later
if necessary.

### Alternative 3

Track a page's membership in multiple hierarchical containers. At
a minimum this would be for a zone and a project, but could be extended to
other kinds of containers in the future.

A fundamental limitation with handling multiple containers is that there is
only a single set of MMU access/modify bits per page, so the page scanner
cannot fully cope with page activity across multiple containers.

We could add a level of indirection to the reference on a page. Instead of
simply storing a zoneid in p\_zoneid, we would add a pointer to an intermediate
"container" object into each page\_t. This "container" object would be a
set of references to all of the entities that the page belongs to. For
example, it could have a zoneid, a projectid, and any other references we
might want.

For our current usage where we never use projects, there would be a single
intermediate "container" object for each page our zone is using. If we did
have two different projects in the zone, there would be two intermediate
"container" objects, both with the same zoneid but with different projectids.
Some of the zone's pages would reference one of these "container" objects while
other pages would reference the other "container" object.

We could track a page count per entity (zone, project, etc.) but we can
still only do pageout scanning using mark/sweep for one entity. If we
assume that these different entities are strictly hierarchical (zone,
project, etc.) then the pageout scanner could be modified to handle
the lowest entity in the hierarchy. For example, if a project was
over its memory cap, the scanner would only consider pages which belonged
to the specific intermedate "container" that described the zone/project.
If all of the projects were under their memory cap, but the total for the
zone was over the cap, then all of the "container" objects for that zone
would need to be considered by the scanner.

The scanner could not use a simple zoneid array in this case. We would need
an AVL tree in which we would add the appropriate "container" pointers
when we're over a cap. The scanner would then have check the page's pointer
against the AVL tree to see if that page is a candidate to be reclaimed.

At this time it does not appear that there is enough justification to warrant
tracking page membership in multiple entities vs. the additional complexity
to the code.  In the future, if we need better handling for memory caps on
multiple hierarchical containers, we could extend the implementation to support
this kind of indirection. Also, this approach will break down if we ever have
to deal with a set of containers which is not strictly hierarchical.
