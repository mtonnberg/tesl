test_aisuite_entitlement.ml need updating after we changed how defineAgent/tool use works.

---
DONE (core_polish): migrated test_aisuite_entitlement.ml to the unified `Agent { }` constructor (removed defineAgent/withTools); 263 entitlement cases green + 4 new REMOVED-API negative cases (old API must not compile). 267 tests pass.
