currently unused imports are not correct for Queues (See chat-backend.tesl for example, where we have a bunch of incorrect warnings)

Also, chat-backend.tesl should not compile since while we import Queue we do not import Queue(..) so the constructor (Queue) should not be in scope

---
DONE (core_polish): (1) soundness — `load_imported_ctors` no longer leaks an ADT's constructors when only the bare type is imported (needs the ctor name or `T(..)`); 7 CTORSCOPE tests. (2) lint — `collect_decl_names` now credits config-block `config_expr` (DQueue/DChannel/DCache/DEmail/DConst/DWorkers/DDatabase), killing the spurious W050s on chat-backend; 2 W050 tests. chat-backend cleaned of genuinely-unused imports. The "Queue needs Queue(..)" claim was a misunderstanding (config-block syntax, not a generic ctor) — see taken_decision.md.
