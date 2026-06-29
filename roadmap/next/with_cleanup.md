## Background

Before we set up the main function with "with database" and "with x". Now we have moved to an App type instead which is an improvement. However that leaves tests in an awkward position on how we setup them correctly (currently they are using with database, with runs x etc). "with x" is used in several places now. See parser.ml line 492.

## Goal

- It is easy to understand with what capabilities test are being run
- It is easy to understand if the tests are run against a proper db or in memory
- The use of "with" is streamlined and easy to learn/extrapolate
  
## Notes

- We have "with transaction", "with database", "with cache" "with runs" etc. Only "with transaction is allowed in non-topnode code (main or testblock).

## Proposal

- change the capture syntax to only allow using and via - not with
- Change "with transaction {" to just "transaction {".
- Reduce the with to only "with TestConfig" where all of these things are set in the config, just as we did with App (Maybe this will be very clunky though if it is required for all test declarations - even if they do not require any database / queue / cache...)
- Running tests with in-memory db/cache/queues should still be possible (most tests will be run this way)

This proposal is a bit handwavy so validate before starting.

## Implementation caution (learned during the Phase F / capture review, 2026-06-29)

Precise inventory of where `with` is parsed today (the token is always a bare
`IDENT "with"`, not a keyword):
1. **Inline capture codec** — `capture id: T with <codecFn> [via <checkFn>]`
   (parser.ml:~3832 + the endpoint/api capture path). This is the ONLY `with` that
   directly follows a *type*, and it is exactly why the type-application parser
   special-cases `with` as a terminator (parser.ml:~492, the `IDENT ("where" | "with")`
   arm).
2. `with database X { … }` (parse_with_stmt, parser.ml:~2427).
3. `with transaction { … }` (parse_with_stmt, parser.ml:~2441).
4. `test "…" with N runs { … }` (parser.ml:~2780/4270).
(`with capabilities` was removed in the App / Phase-F work. I did not find a real
`with cache` form — current uses are the four above.)

⚠️ The capture step of this proposal (captures use `using`/`via` only, drop `with`) MUST
land BEFORE removing `with` from the type-application terminator (parser.ml:~492).
`capture id: T with codec` puts `with` right after a type; if that arm is deleted while the
inline-`with` capture syntax still exists, the type parser consumes `with` as a type
argument and inline captures silently break (regression caught by
`compiler/test/test_review66_api_validation` R66_CA13/CA14). Sequence: migrate the capture
syntax → migrate `with transaction`→`transaction` etc. → only THEN prune the parser arm.

## Alternativ proposal for test blocks

- Allow the "with x" syntax on the test block declarations - no where else
```tesl
api-test "subscribe collect and process queue" for Lesson33Server requires [queueRead, queueWrite, pubsub]
    with database ADatabaseDeclaration
    with queue AQueueDeclaration
    with noOfRuns 2 {
``` 