---
authors: Bryan Cantrill <bryan@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+164%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2019, Joyent, Inc.
-->

# RFD 164 Open Source Policy

We -- like many companies -- built our business on open source that
we consumed:  cloud computing would not have been financially viable in an era
of rent-seeking proprietary system software.
We believe strongly in open source:  as users, as contributors, and
as originators -- and are mindful to avoid <a href="https://www.slideshare.net/bcantrill/corporate-open-source-antipatterns">corporate open source anti-patterns</a>.

Born as consumers of open source software, we established a track
record of contributing to the open source software that we use.
We did this out of our own business sense (floating patches has an
obvious
maintenance burden) as well as out of our view that open source is a
social contract:  that as a consumer of open source, we had a societal
responsibility to contribute back to those things that had been so
important to us.

While we used and contributed to open source, we nonetheless had a
substantial amount of proprietary software.  Fortunately, our business
model -- which involves selling cloud-based services as well as the
software that we use to run those services to others -- allowed a much
broader open source model, and in 2014
<a href="https://www.joyent.com/blog/sdc-and-manta-are-now-open-source">we open sourced our entire software stack</a>.

Since that time, the software that we have developed has been almost
exclusively open source, leading our peers in cloud computing.
At the margins, however, some questions have been raised about the
specifics of our policy.  This RFD is an attempt to elucidate our
open source policy, but it doesn't change our principles with respect
to open source.

## Open Source Counsel Office (OSCO)

This RFD creates a role, the Open Source Counsel Office (OSCO), that
serves as a focal point for consultation and approval with respect to open
source policy.  If and as much as additional counsel is required (e.g.,
legal counsel), it is up to the OSCO to make this determination.  This
role is nowhere near a full-time job; it is anticipated that this function
will be performed or delegated by the CTO or equivalent.

## Open source use

Any open source component licensed under the following commonly-used
licenses can be freely used without additional disclosure or approval by
the OSCO:

- Mozilla Public License, 1.0, 1.1 and 2.0 variants
- MIT License
- Berkeley Software Distribution (BSD), 3-clause, 2-clause and 0-clause variants
- Apache License, 1.0, 1.1 and 2.0 variants
- Common Development and Distribution License (CDDL)

Additionally, any open source component under the following less-commonly
used licenses can be freely used without additional disclosure or approval:

- PostgreSQL License
- Python Software Foundation License
- Public Domain
- Artistic License
- zlib/libpng License
- PHP License
- ICU License

Components with the following licenses can be freely used for *internal
use* (that is, not part of any service or software offering), but can only
be used for *external use* (part of a service or software offering) after
consultation with the OSCO:

- GNU Public License (GPL), v2 and v3
- Lesser GNU Public License (LGPL)

Software under the following licenses can be used *only* for internal use
(that is, they may never be used as part of any service or software
offering) and use *always* require explicit permission of the OSCO:

- Affero General Public License (AGPL)
- Server Side Public License (SSPL)
- Confluent Community License
- Redis Source Available License
- Any license bearing a Commons Clause addendum

## Open source contribution

We believe in contributing back to the projects that we use, and seek
to actively push changes upstream where and as appropriate.

### Personal attribution

Any open source contribution from Joyent must have the personal
attribution of the engineer (or engineers) who did the work.  (In general,
this attribution will take the form of the ```Author``` field of a git
commit, which can differ from the ```Commit``` field.) At no point should
work by one engineer be passed off as the work of another; it is every
engineer's responsibility to assure that their peers are appropriately
recognized.  Further, even with attribution, the original
engineer should generally be made aware that their work is being
upstreamed.  This is a courtesy (and may help inform the testing or
correctness of the upstreaming); if it's not possible to engage with
the original engineer, it should not impede upstreaming their committed
work.

### Copyright

Copyright for all open source contribution is held by Joyent, but how this
is attributed will depend on the specifics of the project.  For files with
file-based copyleft licenses (e.g., MPL, CDDL), it is our expectation that
each file will bear the copyright owners of material in the file.  For
other licenses, this will vary; it is not uncommon for the copyright to
be held by the project contributors, with a separate file elucidating these
contributors (e.g., ```AUTHORS``` or similar).  In this model, it is important 
that the e-mail address contain the author's corporate e-mail address
(e.g. "@joyent.com").

### Copyright notice

Different projects differ in the mechanics of their copyright notice,
and legal counsel opinion will vary on mechanics of year and so on.
Our preference is for each file we have modified to bear a copyright
header that includes the word "Copyright", the year of the
most recent modification, and our identity, e.g.:

```
/*
 * Copyright 2019 Joyent, Inc.
 */
```

If there is an existing block that has such copyrights, our copyright
should be added to it, e.g.:
 
```
/*
 * Copyright (c) 2016, 2017 by Delphix. All rights reserved.
 * Copyright 2016 Nexenta Systems, Inc.
 * Copyright 2017 RackTop Systems.
 * Copyright 2019 Joyent, Inc.
 */
```

If the project differs in the way that it presents copyright (e.g.,
with a range of years, with the "(c)" symbol, etc.), these are acceptable.
We do not, however, allow contributions without any Joyent attribution
whatsoever.

### Contributing source from third parties

There are occasions when we wish to integrate source from third
parties into other open source projects.  If the third party source is
not already open source, this activity must be done in concert with the
OSCO, who will take responsibility for assuring that the third party has
condoned this activity and that risk is appropriately minimized.

### De minimis change

Some changes can be considered *de minimis*, and need not have a copyright
notice or update.  These kinds of changes include:

- Pure deletion of code
- Correcting spelling or grammar
- Changing only code comments

In general, any code change -- however small -- should not be considered
*de minimis*.

### Conduct

A challenge of contributing to open source projects is that we expect our
staff to professionally engage with people who are not Joyent employees.
It is our expectation that conduct in open source engagement will reflect
the professionalism of our workplace.  Where this is not the case -- where
we believe that actions by others in the community are violating our
standards for our own conduct -- action should be taken.  Employees who
wish to report this conduct should either report it to the OSCO or to
Joyent HR.  Working with the employee, the OSCO and/or Joyent HR will
determine the correct course of action, with the priority being to
protect the employee.

### Contributor License Agreements

If a contributor license agreement is required, the OSCO should be
consulted.  Most CLAs are harmless, but formal OSCO permission will
regrettably be required.

## Open source creation

When we create wholly new software, our overwhelming bias is to open
source it.  Even where we choose to not open source new software,
it should always be created with the idea that it *will* be open sourced.
This means that these guidelines should essentially be followed.

### Repositories

Absent explicit permission from the OSCO, all new repositories should be
in GitHub, under the "joyent" GitHub account (that is, not under personal
accounts).

### License

For any new Joyent-created software, the MPL 2.0 should generally be the
license of choice. The exception to this should be any software that is a
part of a larger ecosystem that has a prevailing license, in which case
that prevailing license may be used.  For example, node.js-based npm
modules are generally MIT-licensed.  The "Licenses" section under open
source use applies here; if new software is to be created that is (for
example) LGPL, it can only be done with the explicit permission of the
OSCO.

### Security

Especially with our broad open source disposition, in Joyent-originated
repositories it can be easy to accidentally divulge a secret.  Certainly,
there should never be production key material or passwords in a
repository, even when private.  We also need to be careful about
production data that might be used as test data.  This data can take on
subtle forms, e.g. a signed Manta URL to otherwise private data.
Unfortunately, code review can be too late to catch this, as our code
reviews are also publicly accessible.  There is no mechanical guideline
here other than to be very mindful!

### Contributor license agreements

In our view, <a href="https://www.joyent.com/blog/broadening-node-js-contributions">contributor license agreements (CLAs) are an impediment
to contributions</a>, and we do not use them for any Joyent-originated 
repository.  (Part of the reason for our strong preference for MPL 2.0 is
that the license warrants the originality of the work and obviates the
need for a CLA entirely.)

### Code of conduct

We have historically not adopted formal codes of conduct for our
repositories, but only because many of our open source repositories
predate their proliferation.  In repositories that are attracting
attention (in the form of use, contributors, issues, etc.), a formal code
of conduct is likely well-advised.  This should be done in consultation
with the OSCO, but it is recommended that projects use a derivative of the
Contributor Covenant.

