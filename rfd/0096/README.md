---
authors: Jason King <jason.king@joyent.com>
state: draft
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent, Inc.
-->

# RFD 96: Named thread API

## Introduction

Several other OSes including Linux (more precisely glibc), Solaris (11.3+), FreeBSD, NetBSD, and
QNX(!) support the ability to assign arbitrary names to individual threads of a
process.  This RFD proposes implementing a similar facility for SmartOS.  Besides improved source-level compatibility, the additional visibility could prove useful for analysis and debugging. 

## Interface

Both Linux\[[1]\] and Solaris\[[2]\] use the following functions to get/set thread names:
```
    int pthread_getname_np(pthread_t tid, char *name, size_t len);
    int pthread_setname_np(pthread_t tid, const char *name);
```
(NOTE: at least some Linux man pages\[[1]\] incorrectly show the first argument as a pointer, however the glibc source shows the first argument is indeed just `pthread_t`).

Solaris also includes the following functions:
```
    int pthread_attr_getname_np(pthread_attr_t *attr, char *name, size_t len);
    int pthread_attr_setname_np(pthread_attr_t *attr, const char *name);
```
NetBSD uses a slightly different syntax on the set functions:
```
    int pthread_setname_np(pthread_t tid, const char *name, void *arg);
    int pthread_attr_setname_np(pthread_attr_t *attr, const char *name, void *arg);
```
Where name can be a `printf(3c)` style format string and arg is the argument (the function signature implies only a conversion specification, as it does not end with `...`, however \[[3]\] is not clear on this).

FreeBSD only defines a single set name function:
```
    int pthread_set_name_np(pthread_t tid, const char *name);
```

With the exception of FreeBSD (which doesn't specify), all the other implementations impose a maximum size on the name of a thread:

| Platform | Size (characters) |
| --------- | ------ |
| Linux | 16 |
| Solaris | 32 |
| NetBSD | `PTHREAD_MAX_NAMELEN_NP` (32) |

On Linux, the man page\[[1]\] explicitly states the thread name is modified and read by reading the value out of `/proc/self/task/<tid>/comm`.  Consultation with the glibc source indicates that this is only partially true.  If a thread is setting or reading it's own name (i.e. `tid == pthread_self()`), `prctl(PR_{GET,SET}_NAME, name)` is used.  Only when the tid of another thread is specified is `/proc` accessed.  The functions can return `ERANGE` if the name is too long (set) or the buffer to hold the name is too small (get), as well as any error returned by `open(2)`.  Again, the man page is slightly misleading -- it returns `ERANGE` if `strlen(name) > 16` (set) or `len < 16`.

On Solaris, it appears to silently truncate any oversized names.  It will return `ESRCH` if the thread id doesn't exist, and in the get case, `EINVAL` if a NULL buffer is supplied.

NetBSD returns `EINVAL` if the sizes in questions are larger than `PTHREAD_MAX_NAMELEN_NP`.

## Use

The primary use envisioned would be for utilities such as mdb(1), ps(1), pstack(1), and prstat(1m) to be able to display the thread name (when present) in addition to the thread id.  Additionally, it seems useful to make this information available within core dumps for post-mortem analysis.  This of course doesn't preclude additional uses beyond this, but merely a suggested list of initial consumers.  Solaris also allows names to be set on kernel threads \[[4]\].  In addition, they also define the `uthreadname` and `kthreadname` functions in `dtrace(1m)` for use within dtrace scripts \[[4]\].

NOTE: The thread names in the below examples are merely illustrative.

### ps

ps(1) will contain two major changes:

1. A new format specifier `lname` will be added for use with the `-o` options.  The header displayed using it will be the same (but upper case).
2. The `-L` option currently adds the `LWP` field to the output, while `-eL` adds both the `LWP` field and the `NLWP` (number of LWPs).  In both instances, this will now also include the `LNAME`
field.

Any LWPs without a name will just display spaces (i.e. appear empty).

```
# ps -efL
     UID   PID  PPID   LWP  LNAME   NLWP   C    STIME TTY        LTIME CMD
    root 82207 54517     1             1   0   May 09 ?           0:00 sendmail -i -- nobody
    root 54534 54517     1            13   0   Apr 25 ?           0:00 /lib/svc/bin/svc.startd
    root 54534 54517     2  fizz      13   0   Apr 25 ?           0:01 /lib/svc/bin/svc.startd
    root 54534 54517     3  buzz      13   0   Apr 25 ?           0:01 /lib/svc/bin/svc.startd
    root 54534 54517     4            13   0   Apr 25 ?           0:01 /lib/svc/bin/svc.startd
    root 54534 54517     5            13   0   Apr 25 ?           0:00 /lib/svc/bin/svc.startd
    root 54534 54517     6            13   0   Apr 25 ?           0:05 /lib/svc/bin/svc.startd
    root 54534 54517     7  acme      13   0   Apr 25 ?           0:01 /lib/svc/bin/svc.startd
    root 54534 54517     8            13   0   Apr 25 ?           0:00 /lib/svc/bin/svc.startd
    root 54534 54517     9            13   0   Apr 25 ?           0:01 /lib/svc/bin/svc.startd
    root 54534 54517    23            13   0   Apr 25 ?           0:20 /lib/svc/bin/svc.startd
    root 54534 54517    47            13   0   Apr 25 ?           0:00 /lib/svc/bin/svc.startd
    root 54534 54517   211.           13   0   Apr 25 ?           0:00 /lib/svc/bin/svc.startd
    root 54534 54517   204            13   0   Apr 25 ?           0:00 /lib/svc/bin/svc.startd
    root 55124 54517     1             1   0   Apr 25 ?           0:01 /usr/sbin/cron
    . . .
```

### prstat

The behavior of `prstat -L` will change slightly.  Currently, there is a ‘PROCESS/LWPID’ column that displays the process name and numeric lwpid.  Instead, this will change to ‘PROCESS/LWPNAME’ and a ‘LWPID’ column will be added in front of it.  In the event a thread doesn’t have a name, LWPNAME
will display the LWPID:

```
   PID USERNAME  SIZE   RSS STATE  PRI NICE      TIME  CPU LWPID PROCESS/LWPID
 54873 root     2676K 1768K sleep    1    0   0:00:00 0.0%     1 pfexecd/1
 55131 root     2216K 1368K sleep   59    0   0:00:00 0.0%     1 sac/1
 30172 root     8204K 3740K sleep   59    0   0:00:00 0.0%     1 sendmail/1
 55177 root     7436K 1464K sleep   59    0   0:00:52 0.0%     1 sshd/1
 34915 root     8192K 3596K sleep   59    0   0:00:32 0.0%     1 postdrop/1
 55142 root     1996K 1336K sleep    1    0   0:00:00 0.0%     1 ttymon/1
 55124 root     1952K 1308K sleep   59    0   0:00:00 0.0%     1 cron/1
 54534 root     7372K 5852K sleep    1    0   0:00:00 0.0%   204 svc.startd/method
 54534 root     7372K 5852K sleep    1    0   0:00:00 0.0%   211 svc.startd/method
 54534 root     7372K 5852K sleep    1    0   0:00:00 0.0%    47 svc.startd/restarter_evt
 54534 root     7372K 5852K sleep   59    0   0:00:22 0.0%    23 svc.startd/wait
 54534 root     7372K 5852K sleep    1    0   0:00:00 0.0%     9 svc.startd/configd
 54534 root     7372K 5852K sleep   59    0   0:00:00 0.0%     8 svc.startd/graph
 54534 root     7372K 5852K sleep    1    0   0:00:00 0.0%     7 svc.startd/graph_evt
 54534 root     7372K 5852K sleep   59    0   0:00:05 0.0%     6 svc.startd/repo_evt
 54534 root     7372K 5852K sleep   59    0   0:00:00 0.0%     5 svc.startd/single-user
 54534 root     7372K 5852K sleep   59    0   0:00:00 0.0%     4 svc.startd/sulogin
 54534 root     7372K 5852K sleep   59    0   0:00:00 0.0%     3 svc.startd/3
 54534 root     7372K 5852K sleep   59    0   0:00:00 0.0%     2 svc.startd/2
 54534 root     7372K 5852K sleep   59    0   0:00:00 0.0%     1 svc.startd/1
 82207 root     8204K 3732K sleep   59    0   0:00:00 0.0%     1 sendmail/1
```

### pstack

Currently for each thread, `pstack(1)` prints the lwpid.  This can be supplemented with the thread name when set:

```
54534:    /lib/svc/bin/svc.startd
-----------------  lwp# 1 / thread# 1  --------------------
 feee20b5 sigsuspend (8047e10)
 08076014 main     (8047e4c, fef4c6e8, 8047e80, 805af0b, 1, 8047e8c) + 20e
 0805af0b _start   (1, 8047f54, 0, 8047f6c, 8047f8d, 8047f94) + 83
-----------------  lwp# 2 / thread# 2 (configd) -----------
 feee1a45 ioctl    (5, 63746502, 8167fa8)
 fedc2fbf ct_event_read_critical (5, fed5efac, fed5efa8, 1, fef470e0, fedf2000) + 16
 0805eae6 fork_configd_thread (ffffffff, 0, 0, 0) + 14b
 feedd3dd _thrp_setup (fec50240) + 88
 feedd570 _lwp_start (fec50240, 0, 0, 0, 0, 0)
-----------------  lwp# 3 / thread# 3 (restarter_timeout)————————
 feedd5c9 lwp_park (0, 0, 0)
 feed7568 cond_wait_queue (8162f80, 8162f68, 0, 805663f, 0, 80590e0) + 6a
 feed783c cond_wait_common (8162f80, 8162f68, 0, fef40000, fec50a40, 815eea4) + 27b
 feed7bf9 __cond_wait (8162f80, 8162f68, fe92efa8, fef40000, fef40000, fec50a40) + a8
 feed7c34 cond_wait (8162f80, 8162f68, 1, 807183b, fec50a40, fef40000) + 2e
 feed7c7d pthread_cond_wait (8162f80, 8162f68, fe92efc8, 8071979, fec50a40, 0) + 24
 080719e8 restarter_timeouts_event_thread (0, 0, 0, 0) + 7a
 feedd3dd _thrp_setup (fec50a40) + 88
 feedd570 _lwp_start (fec50a40, 0, 0, 0, 0, 0)
-----------------  lwp# 4 / thread# 4 (restarter_event) ----
 feedd5c9 lwp_park (0, 0, 0)
 feed7568 cond_wait_queue (8162fb0, 8162f98, 0, fea9a950, 80c1010, 80c4280) + 6a
 feed783c cond_wait_common (8162fb0, 8162f98, 0, feed7198, 815eec4, 0) + 27b
 feed7bf9 __cond_wait (8162fb0, 8162f98, fe82ff88, 2, fef40000, 82d08b0) + a8
 feed7c34 cond_wait (8162fb0, 8162f98, fe82ffa8, 80701b5, 815eec4, 0) + 2e
 feed7c7d pthread_cond_wait (8162fb0, 8162f98, fe82ffc8, 8073366) + 24
 0807307d restarter_event_thread (0, 0, 0, 0) + 5f
 feedd3dd _thrp_setup (fec51240) + 88
 feedd570 _lwp_start (fec51240, 0, 0, 0, 0, 0)
```

### Doors (maybe)

Door servers implement a thread pool to service door client requests.  Typically, door servers
let `door_create(3C)` handle the creation of the thread pool, though a server can optionally use
`door_server_create(3C)` to specify a custom thread creation routine.  The latter function would
allow door servers to set the thread name if they desire, but does add additional complexity.
It is proposed that `door_create(3C)` be extended in the following compatible manner:

```
    int door_create(void (*server_procedure)(void *cookie, char *argp,
        size_t arg_size, door_desc_t *dp, uint_t n_desc), void *cookie,
        uint_t attributes, ...);
```

In addition, a new attribute is proposed: `DOOR_NAME`.  When present, it indicates that
included at the end of the arguments is a `const char *` value pointing to the name to use
when creating the door server threads.  Otherwise, any additional arguments after attributes is
ignored.

This could be especially useful in the somewhat more unusual situations where a process contains
multiple door servers.  An example of this would be a process that acts as both a door server in
implementing it’s normal day to day tasks, but is also a `syseventd(1M)` event publisher as  `libsysevent(3LIB)` creates it’s f own private door server in publishers.

### mdb

The `mdb(1)` command includes the genunix module which is used to both examine system crash dumps as well as allow examination of a live system.  Two commands of note are `::ps` and `::threadlist`.

When `::ps -l` (show LWPs) is run, it is proposed to include the name after the LWP id when present:

```
> ::ps -l
S    PID   PPID   PGID    SID    UID      FLAGS             ADDR NAME
R      0      0      0      0      0 0x00000001 fffffffffbc37680 sched
        L              lwp0 ID: 1
...
R  18040   7990  18040  18040      0 0x42000000 ffffff04a2430028 nscd
        L  0xffffff04a9ea9300 ID: 1
        L  0xffffff04ad81ea40 ID: 2
        L  0xffffff0423db9040 ID: 3
        L  0xffffff04cdeb18c0 ID: 4
        L  0xffffff04ccd95780 ID: 5 NAME: reaper
        L  0xffffff042fb350c0 ID: 6 NAME: revalidate
        L  0xffffff042fb48200 ID: 7 NAME: reaper
        L  0xffffff04bbcc8100 ID: 8
        L  0xffffff04aa367ec0 ID: 9
        L  0xffffff0430619c00 ID: 10
```

When `::threadlist` is run, for user threads, it is proposed to append the thread name to the CMD/LWPID column when a thread name has been set:

```
            ADDR             PROC              LWP CMD/LWPID
fffffffffbc38660 fffffffffbc37680 fffffffffbc3a160 sched/1
ffffff000f405c40 fffffffffbc37680                0 idle()
ffffff000f40bc40 fffffffffbc37680                0 thread_reaper()
ffffff000f411c40 fffffffffbc37680                0 tq:kmem_move_taskq
ffffff000f417c40 fffffffffbc37680                0 tq:kmem_taskq
ffffff000f41dc40 fffffffffbc37680                0 tq:pseudo_nexus_enum_tq
ffffff000f423c40 fffffffffbc37680                0 scsi_hba_barrier_daemon()
...
ffffff03e2c3a080 ffffff03d6020028 ffffff03d7dea740 nscd/2
ffffff03e2c340a0 ffffff03d6020028 ffffff03d8309600 nscd/3
ffffff03d7efd7e0 ffffff03d6020028 ffffff03d7de6e80 nscd/6 revalidate
ffffff03e2c3b400 ffffff03d6020028 ffffff03d7c9b500 nscd/7 reaper
ffffff03e2c1bae0 ffffff03d6020028 ffffff03d7c7e080 nscd/8
ffffff03d9052b40 ffffff03d6020028 ffffff03d7de03c0 nscd/9
```

### dtrace

`dtrace(1m)` will have the `uthreadname` function which returns the name of the user thread, or the LWPID as a string if not set:

```
$ dtrace -n ‘profile-997 /pid == $target/ { @[uthreadname] == count(); }’ -c ./mycmd

larry     345
darrell    72
daryl      66
12          2
843         5
```
 
## Behavior

As noted above, Linux implements these commands either via `prctl()` or manipulation of `/proc`.  The method of implementation in Solaris is unknown.  In FreeBSD, a specific syscall exists to set the name of a thread.  Since the primary consumers are already heavy users of `proc(4)` in SmartOS, it seems reasonable that we also utilize `proc(4)` to present the information for consumers such as `ps(1)`, `pstack(1)`, etc.  The most sensible location would be a somewhere under `/proc/<pid>/lwp/<lwpid>`.

There is some apparent differences in error handling as noted above.  Our existing `pthreads(5)` implementation often uses `ESRCH` when commands that take a `pthread_t` argument are given an non-existent thread id.  For consistency, it is recommend we do the same for out `pthread_{get,set}name_np()`.  This is also compatible with the documented Solaris behavior, however it should be noted that this differs from the documented Linux behavior.  On Linux, it should appear that the return value is that of a file not found (`ENOENT`).  This should be taken into consideration for lx-branded zones.  Solaris also returns `EINVAL` from `pthread_getname_np()` if passed a NULL buffer.  This is somewhat inconsistent with other functions, for example `read(2)` is documented as returning `EFAULT` if given an invalid address (which NULL presumably is).  Solaris also silently truncates names greater than it's max (32), while Linux returns `ERANGE`.  The Linux approach seems better here.

None of the implementations place any apparent restrictions on reading this data, and there do not appear any expectations that the thread name should contain any sort of sensitive information, so not requiring any additional permissions or privileges beyond those needed to run `ps(1)` or `prstat(1m)` to read this data seems sufficient.  Updating this information should be restricted to the owner of the process and/or root.

## Implementation

Given that almost all the intended utilities already heavily utilize `proc(4)` to operate, it seems natural to expose thread names via `proc(4)` as well.  This also strongly suggests that the information should reside within the kernel (though doesn't preclude libc from caching values in userland).  For lx-brand, it is suggested that we match the existing Linux behavior and allow the reading/setting of thread names via the lx-brand proc (via /proc/\<pid\>/task/\<tid\>/comm) as well as `prctl()`.  For native processes, the exact location to read the information is currently TBD as well as the mechanism for setting the name.

## Man Pages

### pthread\_attr\_getname\_np

```
pthread_attr_getname_np(3c)           3c           pthread_attr_getname_np(3c)

NAME
     pthread_attr_getname_np, pthread_attr_setname_np - get or set thread name
     attribute

SYNOPSIS
     library ``libpthread''
     #include <pthread.h>

     int
     pthread_attr_getname_np(pthread_attr_t *restrict attr, char *name,
         size_t len);

     int
     pthread_attr_setname_np(pthread_attr_t *restrict attr, const char *name);

DESCRIPTION
     The pthread_attr_setname_np() and pthread_attr_getname_np() functions,
     respectively, set and get the thread name attribute in attr to name.  For
     pthread_attr_getname_np(), len is the size of name.  Any threads created
     with pthread_create(3c) using attr will have their name set to name upon
     creation.  Thread names are limited to XX characters.

RETURN VALUES
     Upon successful completion, the pthread_attr_getname_np() and
     pthread_attr_setname_np() functions return 0.  Otherwise, and error
     number is returned to indicate the error.

ERRORS
     The pthread_attr_getname_np() function may fail with:

     EINVAL             The name argument is NULL.

     ERANGE             The size of name as indicated by len is too small to
                        contain the attribute name.

     The pthread_attr_setname_np() function may fail with:

     ERANGE             The length of name given in name exceeds the maximum
                        size allowed.

INTERFACE STABILITY
     Uncommitted

MT-LEVEL
     MT-Safe

SEE ALSO
     pthread_create(3c), pthread_getname_np(3c)

illumos                          May 18, 2017                          illumos
```

### pthread\_getname\_np

```
pthread_getname_np(3c)                3c                pthread_getname_np(3c)

NAME
     pthread_getname_np, pthread_setname_np - get or set the name of a thread

SYNOPSIS
     library ``libpthread''
     #include <pthread.h>

     int
     pthread_getname_np(pthread_t tid, char *name, size_t len);

     int
     pthread_setname_np(pthread_t tid, const char *name);

DESCRIPTION
     The pthread_getname_np() and pthread_setname_np() functions,
     respectively, get and set the names of the thread whose id is given by
     the tid parameter.  For pthread_getname_np(), len indicates the size of
     name.  Thread names are limited to XX characters. To clear a thread name,
     call pthread_setname_np() with NULL.

RETURN VALUES
     Upon successful completion, the pthread_getname_np() and
     pthread_setname_np() functions return 0.  Otherwise, an error number is
     returned to indicate the error.  If the thread identified by tid does not
     have a name set, pthread_getname_np will be set to an empty string
     (length = 0).

ERRORS
     The pthread_getname_np() function will fail with:

     EINVAL             The name argument is NULL.

     ERANGE             The size of name as given by len was not large enough
                        to contain the name of the thread.

     ESRCH              The thread tid was not found.

     The pthread_setname_np() function will fail with:

     ERANGE             The length of name exceeds the maximum allowed size.

     ESRCH              The thread tid was not found.

INTERFACE STABILITY
     Uncommitted

MT-LEVEL
     MT-Safe

SEE ALSO
     pthread_attr_getname_np(3c), pthread_create(3c)

illumos                          May 18, 2017                          illumos
```

# References

[1]: https://linux.die.net/man/3/pthread_create
[2]: http://docs.oracle.com/cd/E86824_01/html/E54766/pthread-setname-np-3c.html
[3]: http://netbsd.gw.com/cgi-bin/man-cgi?pthread_attr_getname_np+3+NetBSD-current
[4]: https://blogs.oracle.com/observatory/named-threads-in-oracle-solaris-113

\[1\] https://linux.die.net/man/3/pthread_create

\[2\] http://docs.oracle.com/cd/E86824_01/html/E54766/pthread-setname-np-3c.html

\[3\] http://netbsd.gw.com/cgi-bin/man-cgi?pthread_attr_getname_np+3+NetBSD-current

\[4\] https://blogs.oracle.com/observatory/named-threads-in-oracle-solaris-113
