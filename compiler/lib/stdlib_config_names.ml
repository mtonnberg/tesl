(** Config-only stdlib names — the single source for the import surface that
    exists ONLY at compile time.

    Several stdlib names are importable (they appear in exposing lists and in
    {!Type_system.tesl_module_exports}) but are NOT data types and have NO
    runtime binding: config-block markers consumed by the desugar pass
    (`Database`, `Queue`, `App`, …), the config-block ADTs/constructors the
    checker seeds for typed config records (`Postgres`, `Memory`,
    `Exponential`, …), value constructors that lower inline (`Utc`, the
    IANA-zone and `Currency` constructors), surface forms rewritten by the
    parser/emitter (`asTool`, `Cache.get`, …), and the SI quantity aliases
    that erase to their canonical quantity TCon in emitted type positions.

    Two consumers share these groups, and their agreement is the point:

    - {!Emit_racket.config_only_import_names} ( = [require_suppressed]): these
      names never emit a `require` binding, because the runtime modules do not
      (and must not) provide them.  test_stdlib_runtime_binding.ml excludes
      the same list when asserting every remaining importable name has a real
      phase-0 runtime `provide`.
    - The checker ([Checker.check_type_names_in_scope]) REJECTS
      [rejected_in_type_position] names in type positions (fn/handler params,
      returns, record/entity fields, endpoint body/return): they would emit as
      unbound Racket identifiers, which `normalize-type-identifier` silently
      keys to the EMITTING file — same-file uses mint a meaningless per-file
      nominal type, cross-module uses trap at `define-server` with a type-ref
      mismatch.  Names that ARE real data types (TimeZone / Money / Currency /
      ExchangeRate / the MoneyPer aliases) are deliberately in NEITHER list:
      the runtime provides them as type-name symbols (issue #42).

    Keep the sub-lists straight: [erased_type_aliases] must STAY in
    [require_suppressed] while being ABSENT from [rejected_in_type_position] —
    swapping the two either breaks every units program or re-opens the
    unbound-emit hole (the accept-matrix test in
    test_config_only_type_positions.ml pins this). *)

(** Config-block record/marker types consumed by desugar: they configure a
    declaration (`database D = Database { … }`, `queue Q = Queue { … }`,
    `email M = Email { smtp: SmtpConfig { … } }`, `sseChannel C(…) =
    SseChannel { … }`, `cache C = Cache { … }`, the `main() -> App` tail, the
    `jobs: [Job …]` list) and have no runtime representation. *)
let config_block_types : string list =
  [ "Database"; "PostgresConfig"; "Queue"; "QueueRetryStrategy";
    "QueueRetryConfig"; "Email"; "SmtpConfig"; "SseChannel"; "App"; "Job";
    "Cache" ]

(** The checker-seeded config ADTs and their constructors
    (checker.ml [config_stdlib_seed]): `backend: Postgres (PostgresConfig
    { … })` / `Memory`, `connection: TcpConnection { … }` /
    `SocketConnection { … }`, `backoff: Exponential` / `Fixed` / `Linear`.
    Their values cannot escape config blocks (validation forces literal ctor
    forms), so outside one they are compile-time only. *)
let config_adts_and_ctors : string list =
  [ "DatabaseBackend"; "PostgresConnection"; "TcpConnection";
    "SocketConnection"; "Postgres"; "Memory"; "QueueRetryBackoff";
    "Exponential"; "Fixed"; "Linear" ]

(** Constructor → owning config ADT, for diagnostics ([config_adts_and_ctors]
    minus the three ADT names themselves). *)
let config_ctor_owner : (string * string) list =
  [ ("Postgres",         "DatabaseBackend");
    ("Memory",           "DatabaseBackend");
    ("TcpConnection",    "PostgresConnection");
    ("SocketConnection", "PostgresConnection");
    ("Exponential",      "QueueRetryBackoff");
    ("Fixed",            "QueueRetryBackoff");
    ("Linear",           "QueueRetryBackoff") ]

(** TimeZone value constructors: they lower inline to the __ttz_ constructors
    (no runtime binding under their surface names) and are values of type
    `TimeZone`, never types. *)
let timezone_ctors : string list =
  "Utc" :: "FixedOffset" :: Tz_zones.ctor_names

(** Currency value constructors (`Usd`, `Eur`, …): values of type `Currency`,
    never types. *)
let currency_ctors : string list = Currencies.ctor_names

(** Surface forms rewritten at parse/emit time, never runtime vars:
    `asTool fn` lowers to `__tart_tool …`; `serverTools S user` to
    `__tst_server-tools …`; `humanActions S user` to `__tht_human-actions …`;
    `cache` is the config-block keyword (DCache); `Cache.get/set/delete/
    invalidate NAME (k)` parse to ECache* nodes; `Email.send NAME to: …`
    parses to ESendEmail; `startEmailWorker` is a statement keyword
    (EStartEmailWorker).  `EmailBody` is NOT here: it is type-only but its
    TextBody/HtmlBody/RichBody constructors ARE runtime values and stay
    required.  2026-07-07: importing any of these typechecked then crashed
    the generated module at load ("identifier not included in nested require
    spec") — found by test_stdlib_runtime_binding.ml.
    Lowercase/dotted names never reach the type-position check
    (it passes lowercase as tyvars and dotted as qualified), so these are
    require-suppressed but not in [rejected_in_type_position]. *)
let lowered_forms : string list =
  [ "asTool"; "serverTools"; "humanActions";
    "cache"; "Cache.get"; "Cache.set"; "Cache.delete"; "Cache.invalidate";
    "Email.send"; "startEmailWorker" ]

(** SI quantity aliases (Speed, Duration, …): LEGITIMATE types that erase to
    the canonical quantity TCon (Real) in emitted type positions, so they need
    no runtime binding — require-suppressed, but accepted everywhere in type
    positions.  MoneyPer* aliases emit VERBATIM and are deliberately absent
    (the runtime provides them — issue #42). *)
let erased_type_aliases : string list = List.map fst Units_catalog.aliases

(** Names the checker rejects in TYPE positions when they are not locally
    bound (a local `type Email = String` / `record Fixed { … }` / non-Tesl
    module import shadows and wins). *)
let rejected_in_type_position : string list =
  config_block_types @ config_adts_and_ctors @ timezone_ctors @ currency_ctors

(** Everything above: the import names that must never emit a `require`
    binding.  This is {!Emit_racket.config_only_import_names}. *)
let require_suppressed : string list =
  config_block_types @ config_adts_and_ctors @ lowered_forms
  @ timezone_ctors @ currency_ctors @ erased_type_aliases

module SS = Set.Make (String)

(* ~700 entries (489 IANA zones + 180 currencies + the config names); interned
   once, on first use. *)
let rejected_set : SS.t Lazy.t = lazy (SS.of_list rejected_in_type_position)

let is_rejected_in_type_position (name : string) : bool =
  SS.mem name (Lazy.force rejected_set)
