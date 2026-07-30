(** Builtin-surface documentation catalog (roadmap:
    improved_transparency_for_built_in_types).

    Single source of renderable Tesl signatures for every builtin type and
    function — whether declared in Tesl or implemented in Racket.  Serves the
    `tesl doc` CLI command, the `--doc-json` editor query, and the LSP hover.

    DRIFT-PROOF BY CONSTRUCTION: function/value entries carry only PARAMETER
    NAMES and a one-line doc — their types are rendered live from
    {!Type_system.stdlib_env}, so a signature can never disagree with the
    checker.  Config-record entries are generated from
    {!Validation_structural.config_block_schema}.  Capability entries are
    generated from {!Validation_common.tesl_stdlib_cap_map}.  Only type/ADT
    declarations and syntax-form signatures are hand-written prose, and
    test_stdlib_docs.ml pins:
      - every entry name resolves against the real tables (no phantom entries);
      - every function entry's param count equals its scheme's arity;
      - every export of every module in {!Type_system.tesl_module_exports}
        (plus the always-available and bare-home-module names) has an entry —
        adding a stdlib export without documenting it fails the build. *)

(* The row types live in the data module {!Stdlib_docs_entries}; re-exported
   here with type equations so consumers only need Stdlib_docs. *)
type kind = Stdlib_docs_entries.kind =
  | KFunction of string list
      (** parameter names; types come from [stdlib_env] *)
  | KValue
      (** non-function [stdlib_env] binding (e.g. [nowMillis], [Float.nan]) *)
  | KType of string
      (** hand-written full Tesl declaration (ADT / record / newtype) *)
  | KFact of string
      (** proof predicate: hand-written `fact` declaration *)
  | KSyntax of string
      (** compiler-lowered special form: signature-shaped Tesl sketch *)
  | KCapability
      (** capability token; rendered from the provider table *)
  | KConfig
      (** config block record; rendered from [config_block_schema] *)
  | KFamily of string
      (** generated constructor family (time zones, currencies, units);
          payload = a short representative example *)

type entry = Stdlib_docs_entries.entry = {
  name : string;         (* primary lookup name, e.g. "Email.send" *)
  module_ : string;      (* owning module, e.g. "Tesl.Email"; "" = ambient *)
  kind : kind;
  doc : string;          (* one-line description *)
  aliases : string list; (* extra names that resolve to this entry *)
}

let e = Stdlib_docs_entries.e

(* ── Rendering ─────────────────────────────────────────────────────────────── *)

let scheme_of name = List.assoc_opt name Type_system.stdlib_env

let requires_suffix name =
  match Type_system.stdlib_capabilities_of name with
  | [] -> ""
  | caps -> Printf.sprintf " requires [%s]" (String.concat ", " caps)

(** Render a function entry's Tesl signature from its live checker scheme.
    Returns an [Error] description instead of raising so the CLI can degrade
    and the seam test can report the offending entry. *)
let render_function name (params : string list) : (string, string) result =
  match scheme_of name with
  | None -> Error (Printf.sprintf "entry '%s' has no stdlib_env scheme" name)
  | Some sch ->
    let args, ret = Type_system.split_fun_type sch.Type_system.mono in
    (* `fn f() -> T` is spelled with a Unit domain in the scheme. *)
    let args = match args with [ Type_system.TCon "Unit" ] when params = [] -> [] | _ -> args in
    if List.length args <> List.length params then
      Error (Printf.sprintf
               "entry '%s': %d parameter name(s) for %d argument type(s)"
               name (List.length params) (List.length args))
    else
      let rendered_params =
        List.map2 (fun p t -> Printf.sprintf "%s: %s" p (Type_system.pp_ty t))
          params args
      in
      Ok (Printf.sprintf "fn %s(%s) -> %s%s"
            name (String.concat ", " rendered_params)
            (Type_system.pp_ty ret) (requires_suffix name))

let render_value name : (string, string) result =
  match scheme_of name with
  | None -> Error (Printf.sprintf "entry '%s' has no stdlib_env scheme" name)
  | Some sch ->
    Ok (Printf.sprintf "%s : %s%s" name
          (Type_system.pp_ty sch.Type_system.mono) (requires_suffix name))

let render_capability name =
  let provider =
    List.find_opt (fun (_m, caps) -> List.mem_assoc name caps)
      Validation_common.tesl_stdlib_cap_map
  in
  match provider with
  | None -> Error (Printf.sprintf "capability '%s' has no provider row" name)
  | Some (m, caps) ->
    let implies = List.assoc name caps in
    let implies_s = match implies with
      | [] -> ""
      | is -> Printf.sprintf " implies %s" (String.concat ", " is)
    in
    Ok (Printf.sprintf "capability %s%s   # grant it with: import %s exposing [%s]"
          name implies_s m name)

(* (type text, extra note) — notes merge with the "optional" marker into one
   trailing comment. *)
let vkind_label : Validation_structural.vkind -> string * string option = function
  | VStr -> "String", None
  | VInt -> "Int", None
  | VPort -> "Int", Some "port, 1..65535"
  | VBool -> "Bool", None
  | VSub sub -> Printf.sprintf "%s { ... }" sub, None
  | VConn -> "TcpConnection { host, port } | SocketConnection { path }", None
  | VBackend -> "Postgres (PostgresConfig { ... }) | Memory", None
  | VBackoff -> "Exponential | Fixed", None
  | VDatabaseRef -> "<declared database name>", None
  | VEntityList -> "[<declared entities>]", None
  | VJobList -> "[Job <JobRecord> <workerFn> (Something <deadWorker> | Nothing), ...]", None
  | VRefList -> "[<declared component names>]", None
  | VTypeRef -> "<declared type name>", None
  | VExpr -> "<expression>", None

let render_config name =
  match Validation_structural.config_block_schema name with
  | [] -> Error (Printf.sprintf "'%s' has no config_block_schema row" name)
  | fields ->
    let lines =
      List.map (fun (fname, vk, required) ->
        let ty, note = vkind_label vk in
        let comments =
          (match note with Some n -> [ n ] | None -> [])
          @ (if required then [] else [ "optional" ])
        in
        Printf.sprintf "  %s: %s%s" fname ty
          (match comments with
           | [] -> ""
           | cs -> "   # " ^ String.concat "; " cs))
        fields
    in
    Ok (Printf.sprintf "%s {\n%s\n}" name (String.concat "\n" lines))

let render (en : entry) : (string, string) result =
  match en.kind with
  | KFunction params -> render_function en.name params
  | KValue -> render_value en.name
  | KType decl | KFact decl | KSyntax decl -> Ok decl
  | KCapability -> render_capability en.name
  | KConfig -> render_config en.name
  | KFamily example -> Ok example

let kind_label = function
  | KFunction _ -> "function"
  | KValue -> "value"
  | KType _ -> "type"
  | KFact _ -> "proof predicate"
  | KSyntax _ -> "syntax form"
  | KCapability -> "capability"
  | KConfig -> "config block"
  | KFamily _ -> "constructor family"

(* ── Generated entries ─────────────────────────────────────────────────────── *)

let capability_entries : entry list =
  List.concat_map (fun (m, caps) ->
    List.map (fun (cap, implies) ->
      let doc =
        match cap with
        | "emailCap" -> "The shared email-sending token (outbox pattern); import-gated like every stdlib capability."
        | "cookieCap" -> "The right to set the session cookie on the response. Reading request.cookies needs no capability — reading request data is not an effect."
        | "time" -> "Reading the wall clock is an effect."
        | "dbRead" -> "Read access to the declared databases."
        | "dbWrite" -> "Write access to the declared databases (implies dbRead)."
        | "random" -> "Randomness (also required by id generation)."
        | "envRead" -> "Reading process environment variables."
        | "queueRead" -> "Inspecting queue state (dead jobs etc.)."
        | "queueWrite" -> "Mutating queue state (requeue; implies queueRead)."
        | "pubsub" -> "Publishing to SSE channels."
        | "uuid" -> "Generating UUIDs (v4/v7)."
        | "jwt" -> "Signing/verifying JWTs; must be wrapped in a user capability via `implies`."
        | "httpClient" -> "Outbound HTTP; must be wrapped in a user capability via `implies`."
        | "aiProvider" -> "Calling an AI provider (implies httpClient)."
        | _ ->
          Printf.sprintf "Capability provided by %s.%s" m
            (match implies with
             | [] -> "" | is -> Printf.sprintf " Implies %s." (String.concat ", " is))
      in
      e cap ~m ~kind:KCapability ~doc)
      caps)
    Validation_common.tesl_stdlib_cap_map

let config_entries : entry list =
  let m_of = function
    | "Database" | "PostgresConfig" | "TcpConnection" | "SocketConnection" -> "Tesl.Database"
    | "Queue" | "QueueRetryStrategy" -> "Tesl.Queue"
    | "Email" | "SmtpConfig" -> "Tesl.Email"
    | "SseChannel" -> "Tesl.SSE"
    | "Cache" -> "Tesl.Cache"
    | "App" -> "Tesl.App"
    | _ -> ""
  in
  let doc_of = function
    | "Database" -> "Declares a database: `database Name = Database { ... }`."
    | "PostgresConfig" -> "PostgreSQL backend configuration (inside `backend: Postgres (...)`)."
    | "TcpConnection" -> "TCP connection details for a Postgres backend."
    | "SocketConnection" -> "Unix-socket connection details for a Postgres backend."
    | "Queue" -> "Declares a job queue: `queue Name requires [...] = Queue { ... }`."
    | "QueueRetryStrategy" -> "Retry policy for a queue's jobs."
    | "Email" -> "Declares an email outbox: `email Name = Email { ... }`. Sending also needs `import Tesl.Email exposing [emailCap]`."
    | "SmtpConfig" -> "SMTP delivery settings for an `email` block. Use `env`/`envInt` for credentials."
    | "SseChannel" -> "Declares a server-sent-events channel: `channel Name = SseChannel { ... }`."
    | "Cache" -> "Declares a cache: `cache Name = Cache { ... }` (grants `cacheCap Name`)."
    | "App" -> "The application root returned by `main() -> App`."
    | name -> Printf.sprintf "Config block %s." name
  in
  List.map (fun name -> e name ~m:(m_of name) ~kind:KConfig ~doc:(doc_of name))
    [ "Database"; "PostgresConfig"; "TcpConnection"; "SocketConnection";
      "Queue"; "QueueRetryStrategy"; "Email"; "SmtpConfig"; "SseChannel";
      "Cache"; "App" ]

let family_entries : entry list =
  [ e "TimeZone" ~m:"Tesl.Time"
      ~kind:(KType "type TimeZone = Utc | FixedOffset Int | Europe_Stockholm | America_New_York | ... (one constructor per IANA zone)")
      ~doc:(Printf.sprintf
              "DST-correct IANA time zones — %d zone constructors plus Utc and FixedOffset <minutes>; used with Time.offsetAt / formatTime."
              (List.length Tz_zones.ctor_names));
    e "Currency" ~m:"Tesl.Money"
      ~kind:(KType "type Currency = Sek | Usd | Eur | ... (one constructor per ISO-4217 code)")
      ~doc:(Printf.sprintf
              "ISO-4217 currencies — %d constructors; see Currency.code / Currency.minorDigits / Currency.fromCode."
              (List.length Currencies.ctor_names));
    e "MoneyCtors" ~m:"Tesl.Money"
      ~kind:(KFamily "Money.sek 100 : Money   |   Money.usd 5 : Money   # one constructor per currency")
      ~doc:"Money constructors, one per currency (e.g. `Money.sek 100`); exact half-even minor-unit arithmetic.";
    e "Units" ~m:"Tesl.Units"
      ~kind:(KFamily "meters 5 : Length   |   kilograms 2 : Mass   |   Speed, Area, ... # compile-time SI dimensions")
      ~doc:"First-class SI units: quantity constructors, accessors and dimension aliases (Length, Mass, Duration, Speed, ...) checked at compile time.";
  ]

(** Names covered by a family entry rather than individually. *)
let family_member name =
  List.mem name Tz_zones.ctor_names
  || List.mem name Currencies.ctor_names
  || List.mem name Currencies.money_ctor_names
  || List.mem name Units_catalog.exported_names
  || List.mem_assoc name Units_catalog.money_rate_aliases

(* ── Hand-authored entries ─────────────────────────────────────────────────── *)
(* Split per module in stdlib_docs_entries.ml (data only, no logic).  The
   coverage seam test drives completeness. *)

let entries : entry list =
  Stdlib_docs_entries.entries
  @ capability_entries
  @ config_entries
  @ family_entries

(* ── Lookup ────────────────────────────────────────────────────────────────── *)

let modules : string list = List.map fst Type_system.tesl_module_exports

let normalize_query q = String.trim q

(** All entries whose primary name or alias matches [q]. *)
let lookup (q : string) : entry list =
  let q = normalize_query q in
  let direct =
    List.filter (fun en -> en.name = q || List.mem q en.aliases) entries in
  if direct <> [] then direct
  else if family_member q then
    (* An individual generated constructor: resolve to its family. *)
    List.filter (fun en ->
      match en.name with
      | "TimeZone" -> List.mem q Tz_zones.ctor_names
      | "Currency" -> List.mem q Currencies.ctor_names
      | "MoneyCtors" -> List.mem q Currencies.money_ctor_names
      | "Units" ->
        List.mem q Units_catalog.exported_names
        || List.mem_assoc q Units_catalog.money_rate_aliases
      | _ -> false)
      entries
  else []

(** Entries owned by stdlib module [m] (for `tesl doc Tesl.X`). *)
let module_surface (m : string) : entry list =
  List.filter (fun en -> en.module_ = m) entries

(** Case-insensitive nearest names for an unknown query. *)
let suggestions (q : string) : string list =
  let q = String.lowercase_ascii (normalize_query q) in
  let dist a b =
    (* Levenshtein, small strings only *)
    let la = String.length a and lb = String.length b in
    let d = Array.make_matrix (la + 1) (lb + 1) 0 in
    for i = 0 to la do d.(i).(0) <- i done;
    for j = 0 to lb do d.(0).(j) <- j done;
    for i = 1 to la do
      for j = 1 to lb do
        let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
        d.(i).(j) <- min (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1))
                       (d.(i - 1).(j - 1) + cost)
      done
    done;
    d.(la).(lb)
  in
  let candidates =
    List.map (fun en -> en.name) entries
    @ modules
  in
  let scored =
    List.filter_map (fun c ->
      let lc = String.lowercase_ascii c in
      let contains_sub =
        String.length q >= 3 &&
        (let n = String.length q and m = String.length lc in
         let rec go i = i + n <= m && (String.sub lc i n = q || go (i + 1)) in
         m >= n && go 0)
      in
      let d = dist q lc in
      if d <= 2 || contains_sub then Some (d, c) else None)
      candidates
  in
  List.sort_uniq compare scored
  |> List.filteri (fun i _ -> i < 5)
  |> List.map snd

(* ── Text + JSON rendering for the CLI / LSP ───────────────────────────────── *)

let render_entry_text (en : entry) : string =
  let sig_ = match render en with Ok s -> s | Error msg -> "<render error: " ^ msg ^ ">" in
  let home = if en.module_ = "" then "always available (no import needed)"
    else Printf.sprintf "from %s" en.module_ in
  Printf.sprintf "%s — %s (%s)\n\n```tesl\n%s\n```\n%s"
    en.name (kind_label en.kind) home sig_ en.doc

let json_escape s =
  let buf = Buffer.create (String.length s + 8) in
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c) s;
  Buffer.contents buf

let render_entry_json (en : entry) : string =
  let sig_ = match render en with Ok s -> s | Error msg -> "<render error: " ^ msg ^ ">" in
  Printf.sprintf
    {|{"name":"%s","module":"%s","kind":"%s","signature":"%s","doc":"%s"}|}
    (json_escape en.name) (json_escape en.module_)
    (json_escape (kind_label en.kind))
    (json_escape sig_) (json_escape en.doc)
