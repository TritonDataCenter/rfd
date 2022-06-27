---
authors: bryan@joyent.com
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+169%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# RFD 169 Encrypted kernel crash dump

With the advent of encrypted ZFS datasets, there remains a hole:  when the
operating system crashes, kernel memory is written (in compressed cleartext)
to a dump device.  If an attacker were to get a physical device that had had
a crash dump, they would be able to easily access (by default) all kernel
memory at the time of the crash dump -- potentially allowing a vector by
which an encrypted dataset could be compromised.

This RFD is to discuss a modest extension to the kernel crash dump
functionality:  adding the ability to encrypt kernel crash dumps.  Note that
this RFD does not address key management, and nor does it assume encrypted
ZFS -- the encrypted dump functionality is entirely orthogonal to the
encryption of the filesystem.

## Guiding principles

The dump path is critically important:  the operating system does not crash
frequently, and it is therefore of paramount importance that every such
failure be debugged from a single instance.  Without crash dumps, this
becomes essentially impossible -- and indeed, the dependability of the dump
path and the infrequency of fatal kernel failure are very much related:
getting crash dumps allows for unusual failures to be debugged and their
causes fixed, increasing the robustness of the system.  So
the overriding principle here is to keep the dump path as simple as
possible; in the dump path, where there is a choice between performance and
simplicity (and therefore, robustness), painful history has taught us to
<a href="https://github.com/TritonDataCenter/smartos-live/commit/aff9687fd077bca1157b7481d4a9da81e7dce498">choose
the latter</a>.

## Encryption algorithm

In that spirit, we seek a cryptographically strong algorithm that does not
exhibit pathological performance when given minimal register footprint.  (That
is, does not depend on microprocessor extensions for acceptable performance.)
For these purposes, <a
href="https://cr.yp.to/chacha/chacha-20080128.pdf">ChaCha20</a> (with a 256-bit
key) is perfect -- and has the added advantage of an already-integrated
implementation.  While ChaCha20 appears to be the right choice, the
implementation nonetheless allows for an additional or different algorithm to
be added at a later time.

## Implementation details

This work is explicitly not focused at all on key management; it is assumed
that key management is being handled elsewhere in the system.  As a result,
the utilities that need to change will all be altered to optionally take
an encryption key.

### ```dumpadm``` changes

The <a href="https://illumos.org/man/1M/dumpadm">dumpadm</a> command will
be extended to take an optional file that points to on-disk representation of a
key (or, by specifying ```/dev/stdin```, indicates that the key should be read
from standard input).  Once a key has been set, encryption will be enabled on
the dump (there is currently no way to disable dump encryption once enabled).

Proposed additions to the dumpadm man page:

>Crash dump encryption may be optionally enabled via the **-k** option, which
>specifies a file that contains an encryption key. When crash dump encryption
>is enabled, the contents of kernel memory as stored in the dump device will be
>encrypted. Decryption of a kernel crash dump must occur when the dump is
>extracted via **savecore** (to which the encryption key must be separately
>provided). Decompression can only occur on a decrypted dump; when dump
>encryption is enabled, **savecore** must store the dump in its compressed
>state. Note that **savecore** cannot extract an encrypted dump without also
>decrypting it; when dump encryption is enabled, the operator should be sure
>to only operate **savecore** on a directory that is separately encrypted
>or otherwise secured.

### Dump format changes

The crash dump will be changed to indicate that it has been encrypted
(by setting the new ```DF_ENCRYPTED``` in ```dump_flags```).
The header itself will be in cleartext, as will the trailing the header,
and the performance metrics.  The header will add the following members:

1. ```dump_crypt_algo```: Encryption algorithm used. Only valid values are
```DUMP_CRYPT_ALGO_NONE``` and ```DUMP_CRYPT_ALGO_CHACHA```.

2. ```dump_crypt_hmac```: ```DUMP_CRYPT_HMACLEN``` length HMAC, which is
the result of using ```dump_crypt_algo``` to encrypt the first
```DUMP_CRYPT_HMACLEN``` bytes of the ```dump_utsname``` member.  (The
purpose of the HMAC is to allow for quick key rejection without
decrypting the entire dump.)

3. ```dump_crypt_nonce```: ```DUMP_CRYPT_NONCELEN``` of nonce, used as the
initialization vector for ```dump_crypt_algo```

Note the ```DUMP_VERSION``` will be bumped to reflect the new changes -- which
will prevent an older crash dump from being saved on a newer system.
This may be a particular problem where machines spontaneously upgrade:
panicking on an old platform or rebooting onto a new one.  In this case,
the crash dump will have to be extracted manually via an old savecore
binary.

### ```dumpsys``` changes

The actual act of encryption will occur in the (always single-threaded)
path that actually performs I/O; where multi-threaded dump is enabled,
encryption will remain single-threaded.  The encryption mode will be CTR mode.

### ```savecore``` changes

Crash dumps are saved from the dump device via the <a
href="https://illumos.org/man/1M/savecore">savecore</a> command.  As with
dumpadm, savecore will be modified to take a key file in the same manner
(also via the addition of **-k** option).  Decompression can only occur on a
decrypted dump; when dump encryption is enabled, savecore must store the
dump in its compressed state (which is already the default behavior).  If
the provided key does not match the encryption key, savecore will use the
HMAC to determine this condition and fail explicitly.  savecore will always
write the dump in a compressed, decrypted form:  if ZFS encryption is not in
use, the operator needs to take care about writing the decrypted dump to
otherwise unencrypted media.

## Performance

While the overriding principle is robustness, it must also be true that
crash dumping is not made pathologically slow.  ChaCha20 seems to 
fit these constraints but to be able to see the performance in production,
the (terrible) ```METRICS.csv``` has been augmented to include 
the amount of time spent in encryption (```..crypt nsec```).  While the
exact number will naturally fluctuate based on machine and architecture,
the cost of compression appears to be on the order of ~2 μsecs/page -- which
is dwarfed by compression time (~6-10 μsecs/page) and I/O time (varies,
but generally at least 10 μsecs/page).  Certainly, the performance seems
to not be pathological.

