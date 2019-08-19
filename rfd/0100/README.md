---
authors: Cody Mello <cody.mello@joyent.com>
state: draft
discussion: https://github.com/joyent/rfd/issues?q=%22RFD+100%22
---

<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2017 Joyent Inc.
-->

# RFD 100 Improving lint and style checks in JavaScript

At Joyent, we require all repositories to provide a `check` target in their
Makefiles. Currently, for code written in JavaScript, we require using
[JavaScript Lint]. While it does catch a variety of issues, it has some
problems of its own:

- JavaScript Lint doesn't recognize `"use strict"` as being special, which makes
  using strict mode with the `want_assign_or_call` check impossible.
- The unreferenced identifier checks aren't configurable, which makes it
  annoying to turn them on when using a library like [vasync], which passes a
  frequently ignored variable to the functions given to `pipeline()`.

  While these identifiers can be marked as okay with `jsl:ignore` or `jsl:unused`
  comments, doing this everywhere gets annoying and ugly pretty quickly.
- Building it is time-consuming, and requires Python and a C compiler (to build
  SpiderMonkey).

  Since we normally ship it as a submodule in most of our repos, this means that
  on a fresh checkout of a repo you need to compile SpiderMonkey and its bindings
  again. Additionally, the Mac OS X build tends to break after upgrades.

  The upstream Subversion repo that we forked has moved to a pure Python
  implementation, which we then [tried to use with some changes][javascriptlint#18].
  Initial experiments with the recent updates found some drawbacks, however. The
  new pure Python parser is significantly slower, and isn't complete: it lacks
  support for `const`, getters and setters in object literals, and more. This made
  trying to use it in several of our repositories somewhat frustrating.

While most of the annoying edges of the linter can be worked around by
disabling some of the checks, this defeats the purpose behind using a
linter in the first place. After repeatedly running into code that didn't
handle the errors passed to callbacks, and didn't produce any kind of linter
warnings, I decided to investigate alternatives to determine whether we could
improve on the current situation.

## Alternative Linters

Two popular alternatives to JavaScript Lint are [ESLint] and [JSHint]. ESLint
offers both lint and style checks, while JSHint concentrates more on offering
just lint checks. (It has historically also offered several style checks, but
has removed them in recent versions.) Both are written entirely in JavaScript,
and can be installed through npm.

If we were to fully switch to using one of these, rather than just supplementing
our checks with them, we would want to make sure that we didn't lose any useful
checks in the transition. To help compare them, the following table lists all of
the checks provided by JavaScript Lint, and shows their equivalents (or lack
thereof) in the right two columns.

All three of these offer ways to instruct the linter to ignore specific lines.

Each of the JavaScript Lint options are preceded by a plus (`+`) or minus (`-`)
to indicate if they are enabled or disabled in the Joyent Engineering Guide's
[recommended configuration][eng.git/tools/jsl.node.conf].

Note that JSHint, unlike JavaScript Lint and ESLint, works mostly by providing a
set of checks that are always on by default, so there isn't always an equivalent
option to turn on or off. I have called out where this is the case for each
option below by marking it as "on by default". There are also several options
that are specific to JavaScript Lint control comments. I have marked these as
"N/A" for ESLint and JSHint.

| Warns on                                                                                                          | JavaScript Lint                             | ESLint                                  | JSHint
|-------------------------------------------------------------------------------------------------------------------|---------------------------------------------|-----------------------------------------|-----------------
| The else statement could be matched with one of multiple if statements (use curly braces to indicate intent)      | +ambiguous_else_stmt                        | curly (sort of)                         | curly (sort of)
| Block statements containing block statements should use curly braces to resolve ambiguity                         | +ambiguous_nested_stmt                      | curly (sort of)                         | curly (sort of)
| Unexpected end of line; it is ambiguous whether these lines are part of the same statement                        | +ambiguous_newline                          | no-unexpected-multiline                 | :x:
| Anonymous function does not always return value                                                                   | +anon_no_return_value                       | consistent-return                       | :x:
| Assignment to a function call                                                                                     | +assign_to_function_call                    | (parsing error)                         | (on by default)
| Block statement without curly braces                                                                              | -block_without_braces                       | curly                                   | curly
| Multiple statements separated by commas (use semicolons?)                                                         | +comma_separated_stmts                      | no-sequences                            | nocomma
| Comparisons against null, 0, true, false, or an empty string allowing implicit type conversion (use === or !==)   | +comparison_type_conv                       | eqeqeq                                  | eqeqeq
| The default case is not at the end of the switch statement                                                        | +default_not_at_end                         | :x:                                     | :x:
| Duplicate case in switch statement                                                                                | +duplicate_case_in_switch                   | no-duplicate-case                       | :x:
| Duplicate formal argument {name}                                                                                  | +duplicate_formal                           | no-dupe-args                            | (on by default)
| Empty statement or extra semicolon                                                                                | +empty_statement                            | no-extra-semi/no-empty                  | (on by default)
| Test for equality (==) mistyped as assignment (=)                                                                 | +equal_as_assign                            | no-cond-assign                          | (on by default)
| Identifier {name} hides an identifier in a parent scope                                                           | +identifier_hides_another                   | no-shadow                               | shadow
| Increment (++) and decrement (--) operators used as part of greater statement                                     | -inc_dec_within_stmt                        | no-plusplus                             | plusplus
| Unexpected "fallthru" control comment                                                                             | +invalid_fallthru                           | :x:                                     | :x:
| Unexpected "pass" control comment                                                                                 | +invalid_pass                               | :x:                                     | :x:
| Leading decimal point may indicate a number or an object member                                                   | +leading_decimal_point                      | no-floating-decimal                     | (on by default)
| Meaningless block; curly braces have no impact                                                                    | +meaningless_block                          | no-lone-blocks                          | :x:
| Unconventional use of function expression                                                                         | -misplaced_function                         | :x:                                     | :x:
| Regular expressions should be preceded by a left parenthesis, assignment, colon, or comma                         | +misplaced_regex                            | wrap-regex                              | :x:
| Regular expression contains an empty character class (`[]`), which doesn't match any characters                   | :x:                                         | no-empty-character-class                | :x:
| Missing break statement                                                                                           | +missing_break                              | no-fallthrough                          | (on by default)
| Missing break statement for last case in switch                                                                   | +missing_break_for_last_case                | :x:                                     | :x:
| Missing default case in switch statement                                                                          | +missing_default_case                       | default-case                            | :x:
| Missing semicolon                                                                                                 | +missing_semicolon                          | semi                                    | (on by default)
| Missing semicolon for lambda assignment                                                                           | +missing_semicolon_for_lambda               | semi (also covers above)                | (on by default)
| Unknown order of operations for successive plus (e.g. x+++y) or minus (e.g. x---y) signs                          | +multiple_plus_minus                        | space-infix-ops                         | :x:
| Nested comment                                                                                                    | +nested_comment                             | :x:                                     | :x:
| Function {name} does not always return a value                                                                    | +no_return_value                            | consistent-return                       | :x:
| Leading zeros make an octal number                                                                                | +octal_number                               | no-octal                                | :x:
| `parseInt()` missing radix parameter                                                                              | +parseint_missing_radix                     | radix                                   | :x:
| Redeclaration of {name}                                                                                           | +redeclared_var                             | no-redeclare                            | (on by default)
| Extra comma is not recommended in object initializers                                                             | -trailing_comma                             | comma-dangle                            | :x:
| Extra comma is not recommended in array initializers                                                              | +trailing_comma_in_array                    | comma-dangle                            | :x:
| Extra comma in array initializer, creating an empty slot (e.g., `["a", , "b"]`)                                   | :x:                                         | no-sparse-arrays                        | (on by default)
| Trailing decimal point may indicate a number or an object member                                                  | +trailing_decimal_point                     | no-floating-decimal                     | (on by default)
| Trailing decimal point may indicate a number or an object member                                                  | -trailing_whitespace                        | no-trailing-spaces                      | :x:
| Undeclared identifier: {name}                                                                                     | +undeclared_identifier                      | no-undef                                | undef
| Unreachable code                                                                                                  | +unreachable_code                           | no-unreachable                          | (on by default)
| Variable is declared but never referenced: {name}                                                                 | +unreferenced_variable                      | no-unused-vars (much more configurable) | unused
| JavaScript {version} is not supported                                                                             | +unsupported_version                        | (ecmaVersion in config)                 | esversion
| Use of label                                                                                                      | +use_of_label                               | no-labels/no-unused-labels              | :x:
| Useless assignment                                                                                                | +useless_assign                             | no-self-assign                          | :x:
| Useless comparison; comparing identical expressions                                                               | +useless_comparison                         | no-self-compare                         | :x:
| The quotation marks are unnecessary                                                                               | -useless_quotes                             | quote-props                             | :x:
| Use of the void type may be unnecessary (void is always undefined)                                                | +useless_void                               | no-void                                 | :x:
| Variable {name} hides argument                                                                                    | +var_hides_arg                              | no-redeclare                            | shadow
| Expected an assignment or function call                                                                           | +want_assign_or_call                        | no-unused-expressions                   | (on by default)
| With statement hides undeclared variables; use temporary variable instead                                         | +with_statement                             | no-with                                 | (on by default)
| The file is missing a `"use strict"`                                                                              | :x:                                         | strict                                  | strict
| The left side of an `in` expression is negated (e.g., `(!key in object)` instead of `!(key in object)`)           | :x:                                         | no-negated-in-lhs                       | (on by default)
| A variable was used before the point where it's defined                                                           | :x:                                         | no-use-before-define                    | latedef
| Use of the expression `new require("foo")` (probably a mistake) or `new (require("foo"))` (confusing)             | :x:                                         | no-new-require                          | :x:
| Multiple properties with the same key defined in an object literal                                                | :x:                                         | no-dupe-keys                            | (on by default)
| Function defined inside of a loop                                                                                 | :x:                                         | no-loop-func                            | (on by default)
| Comparison to `NaN` instead of using `isNaN()` or `Number.isNaN()`                                                | :x:                                         | use-isnan                               | (on by default)
| `typeof` expression compared against an invalid string (probable spelling mistake)                                | :x:                                         | valid-typeof                            | (on by default)
| Duplicate "option explicit" control comment                                                                       | +dup_option_explicit                        | N/A                                     | N/A
| Expected /\*jsl:content-type\*/ control comment. The script was parsed with the wrong version.                    | +incorrect_version                          | N/A                                     | N/A
| Couldn't understand control comment using /\*jsl:keyword\*/ syntax                                                | +jsl_cc_not_understood                      | N/A                                     | N/A
| Couldn't understand control comment using /\*@keyword@\*/ syntax                                                  | +legacy_cc_not_understood                   | N/A                                     | N/A
| Mismatched control comment; "ignore" and "end" control comments must have a one-to-one correspondence             | +mismatch_ctrl_comments                     | N/A                                     | N/A
| The "option explicit" control comment is missing                                                                  | +missing_option_explicit                    | N/A                                     | N/A
| The "option explicit" control comment, if used, must be in the first script tag                                   | +partial_option_explicit                    | N/A                                     | N/A

Of the two alternative linters, ESLint comes the closest to matching the checks
provided by JavaScript Lint. The checks that it is missing are:

- default_not_at_end
- invalid_fallthru
- invalid_pass
- missing_break_for_last_case
- nested_comment

We will want to determine how much we care about each of these options.

## Additional Style Checks

ESLint also supports performing a variety of style checks. Most of
[jsstyle's][jsstyle] features can be recreated using the following options:


| Description                                                                                         | jsstyle                                                 | ESLint
|-----------------------------------------------------------------------------------------------------|---------------------------------------------------------|---------------------------------------------
| Maximum line length                                                                                 | line-length                                             | max-len
| Whether to enforce single or double quoting                                                         | literal-string-quote                                    | quotes
| Whether to require a space after `/*`                                                               | blank-after-start-comment                               | spaced-comment
| Whether to require a space before `*/`                                                              | (on by default)                                         | spaced-comment ([but not in 2.x][node-eslint-plugin-joyent#2])
| Whether to require a space after `//`                                                               | blank-after-open-comment                                | spaced-comment
| Whether to require a leading `*` in multiline comments                                              | (on by default)                                         | :x: ([being worked on][eslint#8320])
| Whether to require a newline after `/*` and before `*/` in multiline comments                       | (on by default)                                         | :x: ([being worked on][eslint#8320])
| Whether keywords (if, for, function, etc.) should be followed by a space                            | (on by default)                                         | keyword-spacing
| How the code should be indented                                                                     | indent                                                  | indent (see below)
| Whether a space is required before the opening parenthesis of an anonymous function                 | no-blank-for-anon-function                              | space-before-function-paren
| Whether values and identifiers need to be parenthesized when returned                               | unparenthesized-return                                  | :x:
| Whether arguments to the `typeof` keyword need to be parenthesized                                  | (on by default)                                         | :x:
| Whether operators must go at the start or end of a statement split across two lines                 | continuation-at-front (only boolean operators)          | operator-linebreak
| Whether spaces are allowed before semicolons                                                        | (on by default)                                         | semi-spacing
| Whether trailing spaces are allowed                                                                 | (on by default)                                         | no-trailing-spaces
| Whether a trailing newline is allowed at the end of the file                                        | (on by default)                                         | no-multiple-empty-lines
| Whether spaces are required around infix operations                                                 | (on by default for relational and assignment operators) | space-infix-ops
| Whether spaces are required before an opening `{`                                                   | (on by default)                                         | space-before-blocks
| Whether spaces are allowed to pad the inside of parentheses                                         | (on by default)                                         | space-in-parens
| Whether spaces are allowed before/after commas                                                      | (on by default)                                         | comma-spacing
| Whether spaces are allowed before/after the colon in an object literal                              | :x:                                                     | key-spacing
| Whether spaces are allowed before property names (e.g., `Object. keys(obj)` or `Object .keys(obj)`) | :x:                                                     | no-whitespace-before-property
| Whether constant values can be written on the left-hand side of comparisons (e.g., `0 === x`)       | :x:                                                     | yoda
| Whether constructors can be invoked without parentheses (e.g., `new Object`)                        | :x:                                                     | new-parens
| Whether to warn on unusual whitespace characters (non-breaking spaces, zero-width chars, etc.)      | :x:                                                     | no-irregular-whitespace

Note that the indentation checks in ESLint don't support some of the styles used
throughout Triton and Manta code, so it's not really useful. For example, some
of our code is indented using tabs with four-space continuations. Additionally,
when indenting callbacks written out inline, ESLint expects that the body of the
function is indented one more level from the _line_ the `function` keyword is
on, rather than the _statement_ that it is in. This means that the following two
examples are fine:

```javascript
foo("this is a very", "long line of arguments", function (err) {
    if (err) {
        cb(err);
        return;
    }

    cb(null, "foo");
});
```

```javascript
foo("this is a very", "long line of arguments",
    function (err) {
        if (err) {
            cb(err);
            return;
        }

        cb(null, "foo");
    });
```

But the following is not:

```javascript
foo("this is a very", "long line of arguments",
    function (err) {
    if (err) {
        cb(err);
        return;
    }

    cb(null, "foo");
});
```

A lot of code throughout Triton and Manta is written in this style, and it would
be preferable to continue supporting it. While ESLint's `indent` option may not
support these styles currently, we should be able to extend it such that it can.

## Recommended Changes

Based on the above comparisons, we can replace JavaScript Lint with ESLint as
our default linter without losing important checks, and gain new useful ones. To
make it easy for people to use ESLint in new and current repos, the example
Makefiles in the Engineering Guide provide a `check-eslint` target
that `check` depends on when `ESLINT_FILES` is defined (see [TOOLS-1826]). It
will take care of installing ESLint and [node-eslint-plugin-joyent], which
contains a standard configuration for projects to use. Each project should
keep its configuration in an `.eslintrc` file at its root, to make it easier for
people's editors to automatically discover the configuration.

Given the lack of several important style checks in ESLint, we should continue
to use `jsstyle` for style checks going forward, and supplement what it
provides with several from ESLint. Once we've worked on extending ESLint (either
upstream or in our plugin) to support the missing features, we'll be able to
switch to using just ESLint.

For the time being, some projects will need to use the ESLint 2.x series of
versions, since newer releases [dropped support for node 0.10 and 0.12][eslint-3-node-support].
Once [RFD 59] is fully executed, they will be able to move to version 4 or
newer. [node-eslint-plugin-joyent] 1.x releases will be compatible with
ESLint 2.x, and [node-eslint-plugin-joyent] 2.x will be compatible with
ESLint 4.x.

Updating repositories will be done as a gradual process, as people work in
different repos and take the time to figure out how to appropriately fix lint
issues (such as unused identifiers). We could update every repo to use ESLint
with local overrides to silence issues until they are fixed, but doing so would
probably result in them not being fixed for a while.

<!-- JIRA tickets -->
[TOOLS-1826]: https://smartos.org/bugview/TOOLS-1826

<!-- Github repos -->
[vasync]: https://www.npmjs.com/package/vasync
[node-eslint-plugin-joyent]: https://github.com/joyent/node-eslint-plugin-joyent/
[eng.git/tools/jsl.node.conf]: https://github.com/joyent/eng/blob/master/tools/jsl.node.conf

<!-- Github issues -->
[javascriptlint#18]: https://github.com/davepacheco/javascriptlint/pull/18
[node-eslint-plugin-joyent#2]: https://github.com/joyent/node-eslint-plugin-joyent/issues/2
[eslint#8320]: https://github.com/eslint/eslint/issues/8320

<!-- External links -->
[JavaScript Lint]: http://javascriptlint.com/
[ESLint]: http://eslint.org/
[JSHint]: http://jshint.com/
[jsstyle]: https://github.com/davepacheco/jsstyle
[eslint-3-node-support]: http://eslint.org/docs/user-guide/migrating-to-3.0.0#dropping-support-for-nodejs--4

<!-- Other RFDs -->
[RFD 59]: ../0059
