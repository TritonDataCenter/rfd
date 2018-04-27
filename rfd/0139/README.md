---
authors: Trent Mick <trent.mick@joyent.com>
state: predraft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+139%22
---

# RFD 139 Node.js test frameworks and Triton guidelines

This RFD's purpose is to evaluate some Node.js-land test frameworks for use in
Triton repos, suggest a winner, and give some guidelines/suggestions
for using it effectively.

tl;dr: Let's switch to using [node-tap](https://www.node-tap.org/).
If you are here just for guidelines on using node-tap, [jump to the guidelines
here](#guidelines-for-using-node-tap-in-triton-repos).


<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Status](#status)
- [History, Current State, and Goals](#history-current-state-and-goals)
- [Choosing node-tap](#choosing-node-tap)
  - [The bad with node-tap](#the-bad-with-node-tap)
  - [`npm install @smaller/tap`](#npm-install-smallertap)
  - [But I want coverage!](#but-i-want-coverage)
- [Guidelines for using node-tap in Triton repos](#guidelines-for-using-node-tap-in-triton-repos)
- [Appendices](#appendices)
  - [Appendix A: rastap](#appendix-a-rastap)
  - [Appendix B: tape](#appendix-b-tape)
  - [Appendix C: nodeunit](#appendix-c-nodeunit)
  - [Appendix D: mocha](#appendix-d-mocha)
  - [Appendix E: lab](#appendix-e-lab)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->


## Status

Yet to be widely discussed and agreed upon.

See [RFD-139 labelled issues](https://jira.joyent.us/issues/?jql=labels%20%3D%20RFD-139), if any.


## History, Current State, and Goals

Joyent Engineering has a lot of repos/apps/services/software that use Node.js
and has for a long time -- at least in the lifespan of Node.js. Over the years
for testing we've used the following testing tools/frameworks:

- early node-tap
- whiskey (both the drink and the framework)
- nodeunit
- tape
- catest (a homegrown test driver that isn't specifically about node.js at all)

Experience (unfortunately undocumented and perhaps unticked?) with early node-tap
and nodeunit has been that edge cases around test file crashes, hangs, and
poor reporting have led us away from them. The current favourite, at least
in Triton repos or in Trent's head, is `tape`. However, I want more.

Goals:

- a node.js server-side code test framework
- tape-like test file usage would be a plus, for migration (this biases us
  towards TDD-style rather than BDD-style, FWIW)
- a test file can be run on its own, e.g. `node test/foo.test.js`
- a CLI for more conveniently running multiple test files, e.g.
  `<testtool> test/*.test.js`
- [TAP](https://testanything.org/tap-version-13-specification.html) output,
  this has served use well
- good reporting for failing tests
- **parallel running of test files**
- **test files are run in separate processes for isolation**

"I want a Pony" Goals:

- small API (i.e. it doesn't take long to learn how to use it)
- reasonably small install footprint (many Triton images include the test
  framework and test suite in their built images)

Non-goals:

- browser JS support
- pluggable assert frameworks
- many pluggable output formats
- DWIM-y features

The bolded goals are the major new ones I was looking for. The others are
already (mostly) provided by `tape`. For more on test framework goals
I quite like node-tap's list at <https://github.com/tapjs/node-tap#why-tap> --
with one caveat that I will argue against necessarily including coverage
support below.

## Choosing node-tap

- [x] tape-like test file usage would be a plus, for migration

Yes. `tape`'s usage was originally designed to be compatible with node-tap.
Even better, because `tap` runs each test file in its own process and without
anything special (it just execs `node $testFile` and parses TAP output),
the migration process to using node-tap can be piecemeal: during migration
some test files can continue to use `tape`, for example.

- [x] a test file can be run on its own, e.g. `node test/foo.test.js`

Yes, by design for tap and tape.

- [x] a CLI for more conveniently running multiple test files

Yes, `tap`.

- [x] [TAP](https://testanything.org/tap-version-13-specification.html) output

Yes, via `tap -R tap ...`.

Two other good things about node-tap's TAP output. One is that

- [x] good reporting for failing tests

Yes.

By default `tap` uses a more compact formatted output ostensibly for a better
interactive experience. That's fair, the output does a good job of exposing
failing tests, e.g.:

![tap default error reporting of `t.deepEqual`](./tap-default-error-reporting.png)

With admittedly limited recent testing, node-tap does a better job of reporting
error context.

Node-tap handles "skip"-test more correctly:

```
$ cat skipping.test.js
var test = require('tap').test;

test('skipping some stuff', function (t) {
    t.pass('this is fine');
    t.skip('whoa skip this one test for now');
    t.fail('boom, but skipped', {skip: true});
    t.pass('this is also fine');
    t.end();
});

$ tap -R tap skipping.test.js
TAP version 13
# Subtest: skipping.test.js
    # Subtest: skipping some stuff
        ok 1 - this is fine
        ok 2 - whoa skip this one test for now # SKIP
        not ok 3 - boom, but skipped # SKIP
        ok 4 - this is also fine
        1..4
        # skip: 2
    ok 1 - skipping some stuff # time=6.031ms

    1..1
    # time=11.005ms
ok 1 - skipping.test.js # time=259.861ms

1..1
# time=270.82ms
```

In the `tape` equivalent of this, the `t.fail` is reported as a failure:

```
$ node skipping.test.js
TAP version 13
# skipping some stuff
...
not ok 3 boom, but skipped # SKIP
  ---
    operator: fail
    at: Test.<anonymous> (/Users/trentm/joy/node-rastap/examples/tap/skipping.test.js:6:7)
    stack: |-
      Error: boom, but skipped
...

1..4
# tests 4
# pass  3
# fail  1

$ echo $?
1
```

The above `tap` example also shows that tap does a much better job of
clearly reporting subtests.

- [x] **parallel running of test files**

Yes, via `tap -j N ...`.

Anecdotally this worked to run the node-triton test suite in about 12 minutes
where as a serial run can talk, IIRC, one hour.

- [x] **test files are run in separate processes for isolation**

Yes.

Anecdotally, with the node-triton test suite, there was recently/currently
a bug in "test/integration/cli-affinity.test.js" where it would screw up
and run `t.end()` twice. [`tap` handled
this](https://gist.github.com/trentm/f7cacc1b275653cd548489e39ef7a9e2#file-test-log-L205-L281)
and carried on with other
test files. [`tape` blew
up](https://gist.github.com/trentm/af857dcc19c5544d9b451b135afe21a5#file-test-log-L128-L257)
and exited without running the other test files.


### The bad with node-tap

- Current node-tap states it wants node v4, at least.

    ```
    $ json -f package.json engines -0
    {"node":">=4"}
    ```

  Some Triton repos are still on node 0.10. [RFD 59](../0059/) is attempting
  to migrate all those to node v4 or, more recently, v6. Hopefully this then
  is not a blocker for many repos.

- Node-tap bundles in coverage support -- that's a *Good Thing*. However, it
  is *huge*:

    ```
    $ du -sh node_modules/tap
     39M	node_modules/tap
    ```

  This is possibly a concern because we tend to bundle the test suite with
  our image builds, and huge images slows everyone down.


### `npm install @smaller/tap`

So node-tap's install footprint is huge. What if we dropped coverage support,
by dropping its "coveralls" and "nyc" dependencies, patched it to not blow
up and published that (as `@smaller/tap`)?

```
$ npm install @smaller/tap
@smaller/tap@11.1.4-1.0.0 node_modules/@smaller/tap
...

$ du -sh node_modules/@smaller/tap
5.0M	node_modules/@smaller/tap

$ cat hi.test.js
var test = require('@smaller/tap').test;
test('hi there', function (t) {
    t.pass('this is fine');
    t.end();
});

$ ./node_modules/.bin/tap -R tap hi.test.js
TAP version 13
# Subtest: hi.test.js
    # Subtest: hi there
        ok 1 - this is fine
        1..1
    ok 1 - hi there # time=4.334ms

    1..1
    # time=9.824ms
ok 1 - hi.test.js # time=254.482ms

1..1
# time=266.02ms
```

Like [this](https://github.com/trentm/node-smaller/blob/9152d4c17d93168c2803162eebf380d3599011e8/pkgs/tap/Makefile#L14-L30).

TODO: debate whether the overhead of this maintenance of a (light) fork of
node-tap is worth the size gain.


### But I want coverage!

That's fine. It is a per-Triton-component decision whether the install footprint
is worth it.


## Guidelines for using node-tap in Triton repos

TODO


## Appendices

If you don't care deeply about nits with the various test frameworks, don't
feel obliged to read this section.

### Appendix A: rastap

TODO: commit what I have and point to it at least


### Appendix B: tape

TODO: There should be a section talking about the goods and bads/limitations of
tape for Triton repo usage to allow future re-eval if desired.

### Appendix C: nodeunit

This is a quick list of points against nodeunit from memory:

- large install footprint
- doesn't support parallel running
- the default reporter *swallows* exceptions raised in tests (the "tap" reporter
  doesn't)
- From Cody: Nodeunit does have a problem with when it decides to render the
  deepEqual results though. If the object changes after deepEqual is called,
  then it prints out the modified version.
    https://github.com/joyent/smartos-live/blob/master/src/fw/tools/nodeunit.patch


### Appendix D: mocha

tl;dr: Mocha is disqualified because: (a) it doesn't support parallel running
(though there [is a module for
that](https://www.npmjs.com/package/mocha-parallel-tests), modulo
[this](https://github.com/yandex/mocha-parallel-tests/issues/129)), (b) is runs
test files in a special environment, (c) its use of exception capture conflats
test assertions with programmer errors in test code.


Following <https://mochajs.org/#getting-started>

```
$ cat test/mocha-play.test.js
var assert = require('assert');
describe('Array', function() {
    describe('#indexOf()', function() {
        it('should return -1 when the value is not present', function() {
            assert.equal([1,2,3].indexOf(4), -1);
        });
    });
});

$ ./node_modules/.bin/mocha test/mocha-play.test.js


  Array
    #indexOf()
      ✓ should return -1 when the value is not present


  1 passing (6ms)
```

However you can't just run mocha tests files independently without special
environment that mocha sets up:

```
$ node test/mocha-play.test.js
/Users/trentm/tm/play/test/mocha-play.test.js:2
describe('Array', function() {
^

ReferenceError: describe is not defined
    at Object.<anonymous> (/Users/trentm/tm/play/test/mocha-play.test.js:2:1)
    at Module._compile (module.js:409:26)
    at Object.Module._extensions..js (module.js:416:10)
    at Module.load (module.js:343:32)
    at Function.Module._load (module.js:300:12)
    at Function.Module.runMain (module.js:441:10)
    at startup (node.js:140:18)
    at node.js:1043:3
```

The design decision to run mocha test files in a special environment
disqualifies Mocha in my opinion. I don't want to have to cope with special
env handling when debugging test files. Less important, but one cost of
a special env is having to cope in tooling, e.g. linting:

```
$ eslint test/mocha-play.test.js

/Users/trentm/tm/play/test/mocha-play.test.js
  2:1  error  'describe' is not defined  no-undef
  3:5  error  'describe' is not defined  no-undef
  4:9  error  'it' is not defined        no-undef

✖ 3 problems (3 errors, 0 warnings)
```

Also, the design decision to use exception capture for tests has a couple
issues:

1. It means that test code after a failing assert is not run. For example in the
   following test file the "this is fine" test is not run after the "this isn't
   right" assertion failure.

    ```
    $ cat test/mocha-play.test.js
    var assert = require('assert');
    describe('Array', function() {
        describe('#indexOf()', function() {
            it('should return -1 when the value is not present', function() {
                assert.equal([1,2,3].indexOf(4), -1);
                assert.equal(1, 2, "this isn't right");
                assert.equal(5, 5, "this is fine");
            });
        });
    });

    $ ./node_modules/.bin/mocha -R tap test/mocha-play.test.js
    1..1
    not ok 1 Array indexOf() should return -1 when the value is not present
      AssertionError: this isn't right
          at Context.<anonymous> (test/mocha-play.test.js:6:20)
    # tests 1
    # pass 0
    # fail 1
    ```

    I suppose that might be considered a plus for some: you don't have to be as
    careful in your test code to cope with results that don't match earlier
    expectations.

2. More seriously, it doesn't allow separation of assertions to be tested from
   programmer errors (as defined by
   <https://www.joyent.com/node-js/production/design/errors>).


### Appendix E: lab

<https://github.com/hapijs/lab>

Fine print: I haven't used `lab`, so my notes here may be very unfair.

Points against `lab` usage for Triton repos:

- I don't believe it supports parallel running of test files.
- It `requires` test files rather than running them out of process:
  <https://github.com/hapijs/lab/blob/6b38457ef1e4bd819dbe55aa384b3ce4e7ba0173/lib/cli.js#L145>
- `wanted: {"node":">=8.9.0"}`   Triton and Manta repos still use versions of
  node back to 0.10, for better or worse.
- From the readme: "lab uses only async/await features". I'm not sure
  restricting to a promises-only world is necessarily a disqualifier for
  Triton *test suite* code. However, as long as the conflict between promises
  and the ability to have quality core dumps (via
  `--abort-on-uncaught-exception`) remains, it is a hard sell for Joyent
  Engineering.
- Judging only from the readme, is uses the same design decision of
  exception-capture that mocha does.
- Footprint is large:
    ```
    $ du -sh node_modules/lab/
     28M	node_modules/lab/
    ```
