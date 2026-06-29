(** Racket DSL emitter.

    Converts a typed [Ast.module_form] to Racket source code that is
    semantically equivalent to the Python compiler's output.  The emitter
    is intentionally straightforward — it walks the AST and serialises
    each node.  No optimisation, no reordering. *)

open Ast

(** B5 — one emission path.  The emitter ALWAYS wraps each user statement /
    terminal expression in [(thsl-src! file line locals thunk)] and always emits
    the [tesl/dsl/debug/checkpoint] require.  The debug-vs-release decision moved
    to EXPANSION time in [dsl/debug/checkpoint.rkt]: with [TESL_DEBUG] set the
    macro expands to a real checkpoint; otherwise it erases to the bare thunk
    body (zero residue).  There is no longer a [--debug] emitter fork, so
    [tesl <file>] and [tesl --debug <file>] produce byte-identical Racket.

    [set_debug_mode] is retained as a NO-OP purely so the existing callers in
    [compile.ml] / [main.ml] (owned elsewhere) keep linking; it no longer alters
    emission. *)
let set_debug_mode (_ : bool) = ()

(** When Some "name", only emit the test-case whose description matches.
    Set from main.ml via [set_test_name_filter] before calling [compile_to_string]. *)
let test_name_filter : string option ref = ref None

let set_test_name_filter v = test_name_filter := v

(** When Some "kind" (one of "test" | "api-test" | "load-test" | "doctest"), restrict
    single-test selection to that kind.  This disambiguates same-named blocks of
    different kinds (all emit as `(test-case <description>)`).  Only meaningful together
    with [test_name_filter]. *)
let test_kind_filter : string option ref = ref None

let set_test_kind_filter v = test_kind_filter := v

(** Single-test selection used by `tesl test --test-name X [--test-kind K]`.  With no
    name filter every block is selected (a full `tesl test` run — unchanged behaviour).
    With a name filter, ONLY blocks whose description matches are emitted (and whose
    kind matches, if a kind filter is set).  This is what lets a single api-test /
    load-test be run in isolation — previously they emitted unconditionally. *)
let test_block_selected ~(kind : string) ~(description : string) =
  match !test_name_filter with
  | None -> true
  | Some name ->
    String.equal name description
    && (match !test_kind_filter with
        | None -> true
        | Some k -> String.equal k kind)

(* ── Source-position map recording (A1) ──────────────────────────────────────
   Purely *observational* instrumentation: when recording is enabled we measure
   how many newlines the buffer has accumulated around each emitted form/body and
   pair that emitted line-range with the form's [Location.loc].  Recording NEVER
   writes to the buffer, so emitted Racket is byte-identical whether recording is
   on or off (the data goes to a sidecar .tesl.map, not into the .rkt).

   State is module-level (mirroring [debug_mode]); the emitter is single-threaded
   per [compile_to_string] call, which resets it. *)

let sm_recording : bool ref = ref false
let sm_entries : Source_map.entry list ref = ref []

(** Enable/disable source-map recording for the next [compile_to_string].
    Resets any previously recorded entries. *)
let set_source_map_recording v =
  sm_recording := v;
  sm_entries := []

(** Take (and clear) the entries recorded during the last emission, as a
    finalised {!Source_map.t} describing [rkt_file]. *)
let take_source_map ~rkt_file () : Source_map.t =
  let es = List.rev !sm_entries in
  sm_entries := [];
  Source_map.of_entries ~rkt_file es

(* The [ctx]-dependent recording helpers ([sm_current_line], [sm_region]) are
   defined further down, right after the [ctx] type and the buffer primitives. *)

(* ── Module path resolution ──────────────────────────────────────────────── *)

(** Map Tesl module names to their Racket file paths.
    The paths are relative to the project root, matching Python output. *)
let module_path_table : (string, string) Hashtbl.t =
  let h = Hashtbl.create 32 in
  let add k v = Hashtbl.replace h k v in
  add "Tesl.Prelude"   "tesl/prelude.rkt";
  add "Tesl.String"    "tesl/string.rkt";
  add "Tesl.Int"       "tesl/int.rkt";
  add "Tesl.Float"     "tesl/float.rkt";
  add "Tesl.Bool"      "tesl/bool.rkt";
  add "Tesl.List"      "tesl/list.rkt";
  add "Tesl.ListPrim"  "tesl/list-prim.rkt";
  add "Tesl.Dict"      "tesl/dict.rkt";
  add "Tesl.Maybe"     "tesl/maybe.rkt";
  add "Tesl.Either"    "tesl/either.rkt";
  add "Tesl.EitherPrim" "tesl/either-prim.rkt";
  add "Tesl.Result"    "tesl/result.rkt";
  add "Tesl.Http"      "tesl/http.rkt";
  add "Tesl.Json"      "tesl/json.rkt";
  add "Tesl.DB"        "tesl/db.rkt";
  add "Tesl.Time"      "tesl/time.rkt";
  add "Tesl.Random"    "tesl/random.rkt";
  add "Tesl.Uuid"      "tesl/uuid.rkt";
  add "Tesl.Crypto"    "tesl/crypto.rkt";
  add "Tesl.Set"       "tesl/set.rkt";
  add "Tesl.Map"       "tesl/map.rkt";
  add "Tesl.Env"       "tesl/env.rkt";
  add "Tesl.Telemetry" "tesl/telemetry.rkt";
  add "Tesl.Cli"       "tesl/cli.rkt";
  add "Tesl.ApiTest"   "tesl/api-test.rkt";
  add "Tesl.Tuple"     "tesl/tuple.rkt";
  add "Tesl.Id"        "tesl/id.rkt";
  add "Tesl.Queue"     "tesl/queue.rkt";
  add "Tesl.Channel"   "tesl/channel.rkt";
  add "Tesl.Sql"       "tesl/sql.rkt";
  add "Tesl.Sse"       "tesl/sse.rkt";
  add "Tesl.SSE"       "tesl/sse.rkt";
  add "Tesl.Database"  "tesl/db.rkt";
  add "Tesl.App"       "tesl/prelude.rkt";
  add "Tesl.Logging"   "tesl/logging.rkt";
  add "Tesl.JWT"        "tesl/jwt.rkt";
  add "Tesl.HttpClient" "tesl/http-client.rkt";
  add "Tesl.UUID"       "tesl/uuid.rkt";  (* canonical uppercase alias *)
  add "Tesl.Cache"     "tesl/cache.rkt";
  add "Tesl.Email"     "tesl/email.rkt";
  add "Tesl.Agent"     "tesl/agent.rkt";
  h

(** Mapping from qualified import names to renamed Racket identifiers.
    E.g. Dict.lookup → tesl_import_Dict_lookup *)
let import_rename name =
  let escaped = String.concat "_" (String.split_on_char '.' name) in
  "tesl_import_" ^ escaped

(** Render a capability name as a Racket identifier.  Most capabilities are
    plain identifiers, but the implicit per-cache capability is two words
    (`cacheCap <Name>`); collapse spaces to underscores so it becomes the
    `cacheCap_<Name>` identifier that `define-cache` / `define-capability` bind. *)
let cap_ident name =
  if String.length name >= 9 && String.sub name 0 9 = "cacheCap "
  then String.concat "_" (String.split_on_char ' ' name)
  else name
let cap_list_str caps = String.concat " " (List.map cap_ident caps)

(** Codec name mapping from Tesl codec name to Racket codec function name.
    Primitive codecs map to cons-pair functions; user-defined types are
    referenced as quoted symbols so tesl-codec-decode-field can look them
    up in the type-codec registry. *)
let codec_name = function
  | "stringCodec"     -> "tesl-json-string-codec"
  | "intCodec"        -> "tesl-json-int-codec"
  | "boolCodec"       -> "tesl-json-bool-codec"
  | "floatCodec"      -> "tesl-json-float-codec"
  | "posixMillisCodec"-> "tesl-json-posix-millis-codec"
  | "listCodec"       -> "tesl-json-list-codec"
  | "dictCodec"       -> "tesl-json-dict-codec"
  | "setCodec"        -> "tesl-json-set-codec"
  | other             -> Printf.sprintf "'%s" other  (* user-defined type → registry symbol *)

(** Compile-time specialization of field ENCODE (compile_time_specialization).

    For a PRIMITIVE codec the generic runtime path
      [(tesl-codec-encode-field <val> <prim-codec-pair>)]
    routes through an interpreter that conds on the codec-spec kind and then
    calls the codec pair's [car] indirectly.  We instead emit a DIRECT call to
    the matching [tesl-encode-prim-*] helper (the SAME definition the primitive
    codec pair is built from in dsl/types.rkt), eliminating the per-field
    dispatch and the indirect call.  Output and error text are byte-identical
    by construction (one shared definition).

    For a USER-TYPE codec we KEEP the generic [tesl-codec-encode-field <val>
    '<name>] path: that symbol is the user's [with_codec] name and the runtime
    looks it up in the type-codec registry, falling back to
    [runtime-value->jsexpr] when no encoder is registered.  A direct
    [tesl-codec-encode-<name>] call would (a) reference a possibly-undefined
    identifier and (b) drop that fallback, so it is intentionally NOT
    specialized here.  Returns [None] when no primitive specialization applies. *)
let prim_encode_helper = function
  | "stringCodec"      -> Some "tesl-encode-prim-string"
  | "intCodec"         -> Some "tesl-encode-prim-int"
  | "boolCodec"        -> Some "tesl-encode-prim-bool"
  | "floatCodec"       -> Some "tesl-encode-prim-float"
  | "posixMillisCodec" -> Some "tesl-encode-prim-posix-millis"
  | "listCodec"        -> Some "tesl-encode-prim-list"
  | "dictCodec"        -> Some "tesl-encode-prim-dict"
  | "setCodec"         -> Some "tesl-encode-prim-set"
  | _                  -> None

(** Emit the encode call for one record field, specializing primitive codecs to
    a direct helper call and leaving user-type codecs on the generic path. *)
let codec_encode_field_call codec field_name =
  match prim_encode_helper codec with
  | Some helper ->
    Printf.sprintf "(%s (raw-value (hash-ref _fields '%s)))" helper field_name
  | None ->
    Printf.sprintf "(tesl-codec-encode-field (raw-value (hash-ref _fields '%s)) %s)"
      field_name (codec_name codec)

(** Compile-time specialization of field DECODE (compile_time_specialization,
    Phase 2 — mirrors the encoder specialization above).

    The generic runtime path
      [(tesl-codec-decode-field _j "key" <prim-codec-pair>)]
    routes through an interpreter that (a) does the missing-field check raising
    the localized [codec: required field "X" not found in JSON] error, then (b)
    conds on the codec-spec kind and calls the pair's [cdr] (the prim decoder)
    indirectly.  We instead emit a DIRECT call to
      [(tesl-decode-prim-field _j "key" <tesl-decode-prim-*>)]
    — the SAME shared helper the generic path's primitive branch now delegates
    to, with the SAME [tesl-decode-prim-*] type-mismatch decoder.  The
    missing-field error (in [tesl-decode-prim-field] via [jsexpr-required-field])
    and the type-mismatch error (in the prim decoder) are therefore byte-
    identical on every branch by construction (one shared definition each).

    For a USER-TYPE codec we KEEP the generic [tesl-codec-decode-field _j "key"
    '<name>] path: that symbol is looked up in the type-codec registry (and the
    missing-field check + registry dispatch + fallback stay intact).  A direct
    specialized call would drop that registry indirection, so user-type fields
    are intentionally NOT specialized.  Returns [None] when no primitive
    specialization applies. *)
let prim_decode_helper = function
  | "stringCodec"      -> Some "tesl-decode-prim-string"
  | "intCodec"         -> Some "tesl-decode-prim-int"
  | "boolCodec"        -> Some "tesl-decode-prim-bool"
  | "floatCodec"       -> Some "tesl-decode-prim-float"
  | "posixMillisCodec" -> Some "tesl-decode-prim-posix-millis"
  | "listCodec"        -> Some "tesl-decode-prim-list"
  | "dictCodec"        -> Some "tesl-decode-prim-dict"
  | "setCodec"         -> Some "tesl-decode-prim-set"
  | _                  -> None

(** Emit the decode expression for one field from the JSON object [_j],
    specializing primitive codecs to a direct [tesl-decode-prim-field] call and
    leaving user-type codecs on the generic [tesl-codec-decode-field] path. *)
let codec_decode_field_call codec json_key =
  match prim_decode_helper codec with
  | Some helper ->
    Printf.sprintf "(tesl-decode-prim-field _j %S %s)" json_key helper
  | None ->
    Printf.sprintf "(tesl-codec-decode-field _j %S %s)" json_key (codec_name codec)

(* ── Buffer helpers ──────────────────────────────────────────────────────── *)

type ctx = {
  buf    : Buffer.t;
  mutable case_counter : int;
  root_path : string;  (** absolute path to tesl project root *)
  record_fields : (string * (string * Ast.type_expr) list) list;
    (** record/entity name → (field_name, field_type) list — for typed record construction *)
  record_meta : (string * Ast.field_def list * Ast.record_invariant option) list;
    (** record/entity name → full field defs + optional invariant — for property generators *)
  mutable func_kind : Ast.func_kind option;
    (** current function kind, for emit decisions in EOk etc. *)
  mutable func_return_spec : Ast.return_spec option;
    (** current function return spec, for proof-preserving emission *)
  fn_names : (string, unit) Hashtbl.t;
  mutable auth_return_binding : string option;
    (** for auth/check functions: the declared return binding name, used to substitute
        proof args in the accept expression *)
    (** set of user-defined function names — these are not GDP named values *)
  fn_arities : (string, int) Hashtbl.t;
    (** known function arities for local/imported functions, used for partial application lowering *)
  mutable preserve_case_payload_names : bool;
    (** when true, constructor case payload bindings should remain named values instead of raw payloads *)
  proof_locals : (string, unit) Hashtbl.t;
    (** locals bound from check/let-check that must be passed as proof-carrying named values *)
  raw_locals : (string, unit) Hashtbl.t;
    (** locals bound from case patterns whose payloads are already raw backing values *)
  fact_locals : (string, unit) Hashtbl.t;
    (** locals known to hold Fact values (detachFact / establish calls).
        Used to detect `xProof1 && xProof2` as proof conjunction → emit intro-and. *)
  ctor_fields : (string, string list) Hashtbl.t;
    (** ADT constructor name → [field labels] — for resolving positional case bindings *)
  entity_names : (string, unit) Hashtbl.t;
    (** set of entity names — entity construction emits (hash 'field val) not (Name #:field val) *)
  param_names : (string, unit) Hashtbl.t;
    (** function parameter names — these have *name bindings from define/pow *)
  plain_param_names : (string, unit) Hashtbl.t;
    (** parameters WITHOUT proof annotations — their values may be gensyms (not named-values) *)
  mutable expr_type_tbl : (int * int, string) Hashtbl.t;
    (** Maps (start_line, start_col) → display_ty for each expression, used to emit
        correct #:returns types for lambdas. *)
  fn_return_specs : (string, Ast.return_spec) Hashtbl.t;
    (** function name → return_spec, for detecting proof-carrying call results *)
  proof_carrier_lets : (string, unit) Hashtbl.t;
    (** let-bound variables bound to proof-carrying wrapper function results
        (RetMaybeAttached outer_ty = Some). Case arms on these get proof_aware_locals. *)
  proof_aware_locals : (string, unit) Hashtbl.t;
    (** case arm variables extracted from proof-carrying wrappers.
        These should be passed as named-values (v, not *v) to preserve proof. *)
  proof_annotated_ctor_fields : (string, string list) Hashtbl.t;
    (** constructor name → list of proof-annotated field labels.
        These fields must preserve their named-value when stored in ADT constructors. *)
}

let default_root_path () =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

let mk_ctx ?(root_path=default_root_path ()) ?(record_fields=[]) ?(record_meta=[]) () =
  { buf = Buffer.create 4096; case_counter = 0; root_path; record_fields; record_meta; func_kind = None; func_return_spec = None;
    fn_names = Hashtbl.create 16; fn_arities = Hashtbl.create 16;
    preserve_case_payload_names = false;
    proof_locals = Hashtbl.create 16; raw_locals = Hashtbl.create 16;
    fact_locals = Hashtbl.create 8; ctor_fields = Hashtbl.create 8;
    entity_names = Hashtbl.create 4; param_names = Hashtbl.create 8;
    expr_type_tbl = Hashtbl.create 64;
    plain_param_names = Hashtbl.create 8;
    fn_return_specs = Hashtbl.create 16;
    proof_carrier_lets = Hashtbl.create 8;
    proof_aware_locals = Hashtbl.create 8;
    proof_annotated_ctor_fields = Hashtbl.create 8;
    auth_return_binding = None }

let emit ctx s = Buffer.add_string ctx.buf s
let emit_nl ctx = Buffer.add_char ctx.buf '\n'
let emit_line ctx s = emit ctx s; emit_nl ctx

(* ── Source-position map: ctx-dependent recording helpers (A1) ───────────────
   These only *read* the buffer length; they never change what is written, so
   emitted Racket is identical with recording on or off.  Counting newlines from
   scratch each call is O(n) but only happens when [sm_recording] is true (the
   sidecar/--source-map path), never on the hot release-emit path. *)

(* 1-based line of the *next* character to be written = newlines so far + 1. *)
let sm_current_line ctx =
  let s = Buffer.contents ctx.buf in
  let n = ref 1 in
  String.iter (fun c -> if c = '\n' then incr n) s;
  !n

(** Run [thunk] while recording the emitted-Racket line range it produces and
    associating it with [loc].  No-op (other than running [thunk]) when recording
    is off or [loc] is a dummy/synthetic location (line 0/col 0 — lowerings with
    no real source origin are never mapped, matching the B2 stepping design). *)
let sm_region ctx ~(form : string) (loc : Location.loc) (thunk : unit -> unit) =
  if not !sm_recording then thunk ()
  else begin
    let is_dummy =
      loc.Location.start.line = 0 && loc.Location.start.col = 0
      && loc.Location.stop.line = 0 && loc.Location.stop.col = 0
    in
    if is_dummy then thunk ()
    else begin
      let start_bytes = Buffer.length ctx.buf in
      let start_line = sm_current_line ctx in
      thunk ();
      let end_bytes = Buffer.length ctx.buf in
      (* Skip regions that emitted nothing (e.g. the DTest/DFact dispatch arms,
         which emit no Racket here — tests are emitted in a later batch block).
         A zero-byte region would otherwise record a spurious entry at the
         current line. *)
      if end_bytes <= start_bytes then ()
      else begin
        let after_line = sm_current_line ctx in
        (* Lines fully emitted by this region span [start_line, end]; if the
           region advanced the line counter, the last fully-owned line is
           [after_line - 1] (the current partial line belongs to whatever emits
           next).  Clamp so a region that emitted text but no newline still
           records its single starting line. *)
        let rkt_end_line = if after_line > start_line then after_line - 1 else start_line in
        let rkt_end_line = if rkt_end_line < start_line then start_line else rkt_end_line in
        sm_entries :=
          Source_map.entry_of_loc ~rkt_start_line:start_line ~rkt_end_line ~form loc
          :: !sm_entries
      end
    end
  end

let fresh_case ctx =
  let n = ctx.case_counter in
  ctx.case_counter <- n + 1;
  Printf.sprintf "tesl_case_%d" n

(* Return the raw-value reference for a scrutinee variable.
   In fn-body contexts, define/pow's transform-body-expr creates `*var` for every
   let-binding `var`, so patterns reference `*var`.  In test-block and other
   plain-let contexts (func_kind = None), no macro creates `*var` automatically —
   the emitter must bind `*var` directly.  This helper canonicalises: if scrut_var
   already starts with `*` it is returned unchanged; otherwise `*` is prepended. *)
let star_ref s = if String.length s > 0 && s.[0] = '*' then s else "*" ^ s

let rec flatten_app acc = function
  | EApp { fn; arg; _ } -> flatten_app (arg :: acc) fn
  | head -> (head, acc)

let direct_check_call = function
  | EApp _ as e ->
    (match flatten_app [] e with
     | EVar { name = "check"; _ }, check_fn :: check_args -> Some (check_fn, check_args)
     | _ -> None)
  | _ -> None

let is_lower_ident name =
  String.length name > 0 && name.[0] >= 'a' && name.[0] <= 'z'

(** True when [e] is a record construction: either a bare ERecord (with type hint)
    or the new TypeName { field: val } form: EApp(EConstructor "TypeName", ERecord{}). *)
let is_typed_record_construction = function
  | ERecord _ -> true
  | EApp { fn = EConstructor { args = []; _ }; arg = ERecord _; _ } -> true
  | _ -> false

(* ── Type name mapping ───────────────────────────────────────────────────── *)

(** Convert a display_ty string (from the type checker) to a Racket contract type name. *)
let display_ty_to_racket_type (s : string) : string =
  match s with
  | "Bool" -> "Boolean"
  | "Int" -> "Integer"
  | "Float" -> "Real"
  | "String" -> "String"
  | "Unit" -> "Unit"
  | s when String.length s = 1 -> "Any"  (* single-char type variable *)
  | _ -> "Any"  (* safe fallback for complex types *)

let rec emit_type_name ctx ty =
  match ty with
  | TName u ->
    (match u.name with
     | "Int" | "Integer" -> emit ctx "Integer"
     | "Float" -> emit ctx "Real"
     | "String" -> emit ctx "String"
     | "Bool" -> emit ctx "Boolean"
     | other -> emit ctx other)
  | TApp { head; arg; _ } ->
    (* Flatten left-associated TApp: (((f a) b) c) → (f a b c) *)
    let rec collect_args acc = function
      | TApp { head; arg; _ } -> collect_args (arg :: acc) head
      | t -> (t, acc)
    in
    let (base, args) = collect_args [arg] head in
    emit ctx "(";
    emit_type_name ctx base;
    List.iter (fun a -> emit ctx " "; emit_type_name ctx a) args;
    emit ctx ")"
  | TFun { dom; cod; _ } ->
    emit ctx "(-> ";
    emit_type_name ctx dom;
    emit ctx " ";
    emit_type_name ctx cod;
    emit ctx ")"
  | TVar v -> emit ctx v.name
  | TTuple { elems; _ } ->
    emit ctx "(list ";
    List.iter (fun t -> emit_type_name ctx t; emit ctx " ") elems;
    emit ctx ")"

(* ── Expression emission ─────────────────────────────────────────────────── *)

(** Mapping from imported Tesl qualified names.  Populated during require generation. *)
let qualified_imports : (string, string) Hashtbl.t = Hashtbl.create 16

(** Set of plain (unqualified) names imported from Tesl stdlib modules.
    These are stdlib functions that need (raw-value ...) wrapping. *)
let stdlib_plain_imports : (string, unit) Hashtbl.t = Hashtbl.create 16

(** Escape a UTF-8 string for use in a Racket string literal.
    Non-ASCII codepoints are emitted as \uXXXX (or \UXXXXXX for > 0xFFFF). *)
let racket_escape_string s =
  let buf = Buffer.create (String.length s + 4) in
  let bytes = Bytes.of_string s in
  let len = Bytes.length bytes in
  let i = ref 0 in
  while !i < len do
    let b = Char.code (Bytes.get bytes !i) in
    if b < 0x80 then begin
      (match Char.chr b with
       | '"'  -> Buffer.add_string buf "\\\""
       | '\\' -> Buffer.add_string buf "\\\\"
       | '\n' -> Buffer.add_string buf "\\n"
       | '\r' -> Buffer.add_string buf "\\r"
       | '\t' -> Buffer.add_string buf "\\t"
       | c    -> Buffer.add_char buf c);
      incr i
    end else if b land 0xE0 = 0xC0 && !i + 1 < len then begin
      let b2 = Char.code (Bytes.get bytes (!i + 1)) in
      let cp = ((b land 0x1F) lsl 6) lor (b2 land 0x3F) in
      Buffer.add_string buf (Printf.sprintf "\\u%04x" cp);
      i := !i + 2
    end else if b land 0xF0 = 0xE0 && !i + 2 < len then begin
      let b2 = Char.code (Bytes.get bytes (!i + 1)) in
      let b3 = Char.code (Bytes.get bytes (!i + 2)) in
      let cp = ((b land 0x0F) lsl 12) lor ((b2 land 0x3F) lsl 6) lor (b3 land 0x3F) in
      Buffer.add_string buf (Printf.sprintf "\\u%04x" cp);
      i := !i + 3
    end else if b land 0xF8 = 0xF0 && !i + 3 < len then begin
      let b2 = Char.code (Bytes.get bytes (!i + 1)) in
      let b3 = Char.code (Bytes.get bytes (!i + 2)) in
      let b4 = Char.code (Bytes.get bytes (!i + 3)) in
      let cp = ((b land 0x07) lsl 18) lor ((b2 land 0x3F) lsl 12)
               lor ((b3 land 0x3F) lsl 6) lor (b4 land 0x3F) in
      Buffer.add_string buf (Printf.sprintf "\\U%06x" cp);
      i := !i + 4
    end else begin
      Buffer.add_char buf (Char.chr b); incr i
    end
  done;
  Buffer.contents buf

let register_import _modname name =
  Hashtbl.replace qualified_imports name (import_rename name)

(** Table of Tesl prelude/stdlib names that map to different Racket names. *)
let stdlib_name_map : (string, string) Hashtbl.t =
  let h = Hashtbl.create 16 in
  let add k v = Hashtbl.replace h k v in
  add "forgetFact"  "forget-proof";
  add "attachFact"  "attach-proof";
  add "detachFact"  "detach-all-proof";
  add "detachAllFact" "detach-all-proof";
  add "andLeft"     "and-left";
  add "andRight"    "and-right";
  add "introAnd"    "intro-and";
  h

let resolve_name name =
  match Hashtbl.find_opt qualified_imports name with
  | Some r -> r
  | None   ->
    match Hashtbl.find_opt stdlib_name_map name with
    | Some r -> r
    | None -> name

(** Stdlib functions that return GDP named values (with proofs) — should NOT be wrapped in raw-value
    These are functions that return values with attached proof predicates (IsTrimmed, ForAll, etc.) *)
let gdp_returning_stdlib : (string, unit) Hashtbl.t =
  let h = Hashtbl.create 32 in
  List.iter (fun k -> Hashtbl.replace h k ())
    [
     (* Set functions returning ForAll-annotated sets *)
     "tesl_import_Set_filterCheck"; "tesl_import_Set_allCheck"; "tesl_import_Set_mapCheck";
     (* List functions returning ForAll-annotated lists *)
     "tesl_import_List_filterCheck"; "tesl_import_List_allCheck"; "tesl_import_List_mapCheck";
     "tesl_import_List_emptyForAll";
     (* String functions returning GDP-named values (no raw-value in let bindings) *)
     "tesl_import_String_trim"; "tesl_import_String_toLower"; "tesl_import_String_toUpper";
     "tesl_import_String_toInt"; "tesl_import_String_length"; "tesl_import_String_isEmpty";
     "tesl_import_String_split"; "tesl_import_String_join";
     "tesl_import_String_replace"; "tesl_import_String_padLeft"; "tesl_import_String_padRight";
     "tesl_import_String_fromInt"; "tesl_import_String_startsWith"; "tesl_import_String_endsWith";
     "tesl_import_String_contains"; "tesl_import_String_indexOf";
     (* List functions that return GDP-named collections *)
     "tesl_import_List_map"; "tesl_import_List_filter"; "tesl_import_List_foldl";
     "tesl_import_List_foldr"; "tesl_import_List_append"; "tesl_import_List_reverse";
     "tesl_import_List_sort"; "tesl_import_List_unique"; "tesl_import_List_take";
     "tesl_import_List_drop"; "tesl_import_List_range"; "tesl_import_List_repeat";
     (* Time functions — GDP-aware plain imports, no raw-value wrapping *)
     "diffMs"; "addMs"; "subtractMs"; "nowMillis"; "durationMs"; "formatTime";
     (* Random/ID functions — GDP-aware *)
     "generatePrefixedId"; "random";
     (* Int functions returning proof-carrying values *)
     "tesl_import_Int_divide"; "tesl_import_Int_modulo"; "tesl_import_Int_nonZero"; "tesl_import_Int_nonNegative";
    ];
  h

let stdlib_zero_arg_names : (string, unit) Hashtbl.t =
  let h = Hashtbl.create 8 in
  List.iter (fun k -> Hashtbl.replace h k ()) ["nowMillis"]; h

let job_type_to_queue : (string, string) Hashtbl.t = Hashtbl.create 16

(** Returns true for proof annotations that are compile-time only (no runtime evidence).
    Parameters with these proofs use *name (raw) when passed to stdlib functions. *)
let is_comptime_only_proof ann =
  match ann with
  | None -> true
  | Some (PredApp { pred = ("ForAll" | "ForAllValues" | "ForAllKeys"
                           | "IsSorted" | "IsLowerCase" | "IsUpperCase"); _ }) -> true
  | _ -> false

(** Stdlib functions that CONSUME proofs from their arguments at runtime via
    validate-runtime-argument with an expected proof template.  When passing a
    proof-annotated function parameter to one of these functions, we must emit
    `name` (the GDP symbol) instead of `*name` (raw value), so the runtime can
    look up the evidence in current-evidence-env and verify the required proof.
    All other stdlib functions receive raw values; they don't check argument proofs. *)
let proof_consuming_stdlib : (string, unit) Hashtbl.t =
  let h = Hashtbl.create 8 in
  List.iter (fun k -> Hashtbl.replace h k ())
    [ "tesl_import_Int_divide";
      "tesl_import_Int_modulo";
      "tesl_import_Float_div";
      "tesl_import_Dict_get";
      "tesl_import_List_take";
      "tesl_import_List_drop";
      "tesl_import_List_repeat";
    ];
  h

(** Check if a function expression resolves to a tesl_import_* function or stdlib plain import. *)
let is_stdlib_fn fn_expr =
  let check_renamed renamed =
    String.length renamed >= 12 && String.sub renamed 0 12 = "tesl_import_"
  in
  match fn_expr with
  | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
    let full = modname ^ "." ^ field in
    let renamed = match Hashtbl.find_opt qualified_imports full with
      | Some r -> r | None -> import_rename full
    in
    check_renamed renamed
  | EVar { name; _ } ->
    (match Hashtbl.find_opt qualified_imports name with
     | Some renamed -> check_renamed renamed
     | None ->
       Hashtbl.mem stdlib_plain_imports name &&
       not (Hashtbl.mem stdlib_name_map name))
  | _ -> false

type sql_clause =
  | SqlPred of { field : string; op : binop; value : expr }
  | SqlOr of sql_clause list
  | SqlIsNull of { field : string }
  | SqlIsNotNull of { field : string }
  | SqlIn of { field : string; values : expr list }
  | SqlNotIn of { field : string; values : expr list }
  | SqlLike of { field : string; pattern : expr }
  | SqlILike of { field : string; pattern : expr }

type sql_join = {
  join_entity : string;
  main_field : string;
  join_field : string;
}

type sql_select_kind =
  | SelectMany
  | SelectOne
  | SelectCount
  | SelectSum of string
  | SelectMax of string
  | SelectMin of string

type sql_select_seed = {
  kind : sql_select_kind;
  binder : string;
  entity : string;
  where_field : string option;
  order : (string * string) option;
  limit : int option;
  offset : int option;
  static_clauses : sql_clause list;
  group_by : string list;
  joins : sql_join list;
}

type sql_insert = {
  entity : string;
  fields : (string * expr) list;
}

type sql_delete_seed = {
  binder : string;
  entity : string;
  where_field : string option;
  with_result : bool;
}

type sql_update = {
  binder : string;
  entity : string;
  clauses : sql_clause list;
  updates : (string * expr) list;
  returning_one : bool;
}

type sql_upsert = {
  entity   : string;
  fields   : (string * expr) list;
  conflict : string list;    (* onConflict [f1, f2] *)
  do_update: string list;    (* doUpdate [f1, f2] *)
}

let rec flatten_app_expr acc = function
  | EApp { fn; arg; _ } -> flatten_app_expr (arg :: acc) fn
  | other -> (other, acc)

let entity_name_of_expr = function
  | EConstructor { name; args = []; _ } -> Some name
  | EVar { name; _ } -> Some name
  | _ -> None

let field_name_for_binder binder = function
  | EField { obj = EVar { name; _ }; field; _ } when String.equal name binder -> Some field
  | _ -> None

(* Like field_name_for_binder but also accepts EConstructor (uppercase entity names) *)
let field_name_for_entity entity_name = function
  | EField { obj = EVar { name; _ }; field; _ }
  | EField { obj = EConstructor { name; args = []; _ }; field; _ } when String.equal name entity_name -> Some field
  | _ -> None

let int_literal_value = function
  | ELit { lit = LInt n; _ } -> Some n
  | _ -> None

let rec parse_select_tail binder where_field order limit offset group_by static_clauses joins = function
  | [] -> Some (where_field, order, limit, offset, group_by, static_clauses, joins)
  | EVar { name = "where"; _ } :: EVar { name = "isNull"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlIsNull { field }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "isNotNull"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlIsNotNull { field }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "inList"; _ } :: field_expr :: list_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlIn { field; values }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "notInList"; _ } :: field_expr :: list_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlNotIn { field; values }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "like"; _ } :: field_expr :: pattern_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlLike { field; pattern = pattern_expr }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "ilike"; _ } :: field_expr :: pattern_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlILike { field; pattern = pattern_expr }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field -> parse_select_tail binder (Some field) order limit offset group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "order"; _ } :: field_expr :: EVar { name = dir; _ } :: rest
    when String.equal dir "asc" || String.equal dir "desc" ->
    (match field_name_for_binder binder field_expr with
     | Some field -> parse_select_tail binder where_field (Some (field, dir)) limit offset group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "limit"; _ } :: limit_expr :: rest ->
    (match int_literal_value limit_expr with
     | Some n -> parse_select_tail binder where_field order (Some n) offset group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "offset"; _ } :: offset_expr :: rest ->
    (match int_literal_value offset_expr with
     | Some n -> parse_select_tail binder where_field order limit (Some n) group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "groupBy"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field -> parse_select_tail binder where_field order limit offset (group_by @ [field]) static_clauses joins rest
     | None -> None)
  (* innerJoin EntityName on binder.mainField EntityName.joinField *)
  | EVar { name = "innerJoin"; _ } :: join_entity_expr :: EVar { name = "on"; _ } :: main_field_expr :: join_field_expr :: rest ->
    (match entity_name_of_expr join_entity_expr with
     | Some join_entity ->
       let join_opt =
         match field_name_for_binder binder main_field_expr,
               field_name_for_entity join_entity join_field_expr with
         | Some main_field, Some join_field -> Some { join_entity; main_field; join_field }
         | _ ->
           (match field_name_for_entity join_entity main_field_expr,
                  field_name_for_binder binder join_field_expr with
            | Some join_field, Some main_field -> Some { join_entity; main_field; join_field }
            | _ -> None)
       in
       (match join_opt with
        | Some j -> parse_select_tail binder where_field order limit offset group_by static_clauses (joins @ [j]) rest
        | None -> None)
     | None -> None)
  | _ -> None

let parse_select_seed e =
  let parse_plain kind args =
    match args with
    | EVar { name = binder; _ } :: EVar { name = "from"; _ } :: entity_expr :: rest ->
      (match entity_name_of_expr entity_expr, parse_select_tail binder None None None None [] [] [] rest with
       | Some entity, Some (where_field, order, limit, offset, group_by, static_clauses, joins) ->
         Some { kind; binder; entity; where_field; order; limit; offset; static_clauses; group_by; joins }
       | _ -> None)
    | _ -> None
  in
  let parse_sum args =
    match args with
    | field_expr :: EVar { name = "from"; _ } :: entity_expr :: rest ->
      (match field_expr, entity_name_of_expr entity_expr with
       | EField { obj = EVar { name = binder; _ }; field; _ }, Some entity ->
         (match parse_select_tail binder None None None None [] [] [] rest with
          | Some (where_field, order, limit, offset, group_by, static_clauses, joins) ->
            Some { kind = SelectSum field; binder; entity; where_field; order; limit; offset; static_clauses; group_by; joins }
          | None -> None)
       | _ -> None)
    | _ -> None
  in
  let parse_minmax kind args =
    match args with
    | field_expr :: EVar { name = "from"; _ } :: entity_expr :: rest ->
      (match field_expr, entity_name_of_expr entity_expr with
       | EField { obj = EVar { name = binder; _ }; field; _ }, Some entity ->
         (match parse_select_tail binder None None None None [] [] [] rest with
          | Some (where_field, order, limit, offset, group_by, static_clauses, joins) ->
            Some { kind = kind field; binder; entity; where_field; order; limit; offset; static_clauses; group_by; joins }
          | None -> None)
       | _ -> None)
    | _ -> None
  in
  match flatten_app_expr [] e with
  | EVar { name = "selectOne"; _ }, args -> parse_plain SelectOne args
  | EVar { name = "select"; _ }, args -> parse_plain SelectMany args
  | EVar { name = "selectCount"; _ }, args -> parse_plain SelectCount args
  | EVar { name = "selectSum"; _ }, args -> parse_sum args
  | EVar { name = "selectMax"; _ }, args -> parse_minmax (fun f -> SelectMax f) args
  | EVar { name = "selectMin"; _ }, args -> parse_minmax (fun f -> SelectMin f) args
  | _ -> None

let parse_insert_expr e =
  match flatten_app_expr [] e with
  | EVar { name = "insert"; _ }, entity_expr :: ERecord { fields; _ } :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity -> Some { entity; fields }
     | None -> None)
  | _ -> None

let parse_upsert_expr e =
  (* upsert Entity { field: val, ... }
       onConflict [f1, f2]
       doUpdate   [f1, f2]
     The three keyword arguments appear in the flat arg list as:
       EVar "onConflict", EList [EVar f1; ...], EVar "doUpdate", EList [EVar f1; ...]
  *)
  match flatten_app_expr [] e with
  | EVar { name = "upsert"; _ },
    entity_expr :: ERecord { fields; _ }
    :: EVar { name = "onConflict"; _ } :: EList { elems = conflict_elems; _ }
    :: EVar { name = "doUpdate"; _ }   :: EList { elems = update_elems; _ }
    :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       let field_of = function EVar { name; _ } -> Some name | EField { field; _ } -> Some field | _ -> None in
       let conflict = List.filter_map field_of conflict_elems in
       let do_update = List.filter_map field_of update_elems in
       Some { entity; fields; conflict; do_update }
     | None -> None)
  | _ -> None

let parse_insert_many_expr e =
  (* insertMany list_var in Entity *)
  match flatten_app_expr [] e with
  | EVar { name = "insertMany"; _ }, list_expr :: EVar { name = "in"; _ } :: entity_expr :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       (match list_expr with
        | EVar { name = list_var; _ } -> Some (list_var, entity)
        | _ -> None)
     | None -> None)
  | _ -> None

let parse_delete_seed e =
  match flatten_app_expr [] e with
  | EVar { name = (("delete" | "deleteAndReturnResult") as kw); _ }, EVar { name = binder; _ } :: EVar { name = "from"; _ } :: entity_expr :: rest ->
    let with_result = String.equal kw "deleteAndReturnResult" in
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       (match rest with
        | [] -> Some { binder; entity; where_field = None; with_result }
        | [EVar { name = "where"; _ }; field_expr] ->
          (match field_name_for_binder binder field_expr with
           | Some field -> Some { binder; entity; where_field = Some field; with_result }
           | None -> None)
        | _ -> None)
     | None -> None)
  | _ -> None

let parse_update_start e =
  match flatten_app_expr [] e with
  | EVar { name = (("update" | "updateAndReturnOne") as kw); _ }, EVar { name = binder; _ } :: EVar { name = "in"; _ } :: entity_expr :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       let returning_one = String.equal kw "updateAndReturnOne" in
       Some (binder, entity, returning_one)
     | None -> None)
  | _ -> None

let parse_update_set binder e =
  match flatten_app_expr [] e with
  | EVar { name = "set"; _ }, field_expr :: value :: [] ->
    (match field_name_for_binder binder field_expr with
     | Some field -> Some (field, value)
     | None -> None)
  | _ -> None

let parse_update_value_app binder e =
  match flatten_app_expr [] e with
  | field_expr, [value] ->
    (match field_name_for_binder binder field_expr with
     | Some field -> Some (field, value)
     | None -> None)
  | _ -> None

let parse_returning_one e =
  match flatten_app_expr [] e with
  | EVar { name = "returning"; _ }, [EVar { name = "one"; _ }] -> Some true
  | _ -> None

let parse_standalone_where_field binder e =
  match flatten_app_expr [] e with
  | EVar { name = "where"; _ }, [field_expr] -> field_name_for_binder binder field_expr
  | _ -> None

let same_select_identity (a : sql_select_seed) (b : sql_select_seed) =
  a.kind = b.kind
  && String.equal a.binder b.binder
  && String.equal a.entity b.entity
  && a.order = b.order
  && a.limit = b.limit
  && a.offset = b.offset

let same_delete_identity (a : sql_delete_seed) (b : sql_delete_seed) =
  String.equal a.binder b.binder && String.equal a.entity b.entity

let is_sql_comparison = function
  | BEq | BNeq | BLt | BLe | BGt | BGe -> true
  | _ -> false

let clause_of_comparison binder base_field_of_expr op left right =
  match base_field_of_expr left with
  | Some field -> Some (SqlPred { field; op; value = right })
  | None ->
    (match field_name_for_binder binder left with
     | Some field -> Some (SqlPred { field; op; value = right })
     | None -> None)

let rec collect_sql_clauses binder base_field_of_expr expr =
  match expr with
  | EBinop { op = BAnd; left; right; _ } ->
    (match collect_sql_clauses binder base_field_of_expr left,
           collect_sql_clauses binder base_field_of_expr right with
     | Some left_clauses, Some right_clauses -> Some (left_clauses @ right_clauses)
     | _ -> None)
  | EBinop { op = (BOr | BAdd); left; right; _ } ->
    (match collect_sql_or binder base_field_of_expr left,
           collect_sql_or binder base_field_of_expr right with
     | Some left_clauses, Some right_clauses -> Some [SqlOr (left_clauses @ right_clauses)]
     | _ -> None)
  | EBinop { op; left; right; _ } when is_sql_comparison op ->
    Option.map (fun clause -> [clause]) (clause_of_comparison binder base_field_of_expr op left right)
  | EApp _ ->
    (match flatten_app_expr [] expr with
     | EVar { name = "isNull"; _ }, [field_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlIsNull { field }]
        | None ->
          (match base_field_of_expr field_expr with
           | Some field -> Some [SqlIsNull { field }]
           | None -> None))
     | EVar { name = "isNotNull"; _ }, [field_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlIsNotNull { field }]
        | None ->
          (match base_field_of_expr field_expr with
           | Some field -> Some [SqlIsNotNull { field }]
           | None -> None))
     | EVar { name = "inList"; _ }, [field_expr; list_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field ->
          let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
          Some [SqlIn { field; values }]
        | None -> None)
     | EVar { name = "notInList"; _ }, [field_expr; list_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field ->
          let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
          Some [SqlNotIn { field; values }]
        | None -> None)
     | EVar { name = "like"; _ }, [field_expr; pattern_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlLike { field; pattern = pattern_expr }]
        | None -> None)
     | EVar { name = "ilike"; _ }, [field_expr; pattern_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlILike { field; pattern = pattern_expr }]
        | None -> None)
     | _ -> None)
  | _ when Option.is_some (base_field_of_expr expr) -> Some []
  | _ -> None

and collect_sql_or binder base_field_of_expr expr =
  match expr with
  | EBinop { op = BAdd; left; right; _ } ->
    (match collect_sql_or binder base_field_of_expr left,
           collect_sql_or binder base_field_of_expr right with
     | Some left_clauses, Some right_clauses -> Some (left_clauses @ right_clauses)
     | _ -> None)
  | EBinop { op; left; right; _ } when is_sql_comparison op ->
    Option.map (fun clause -> [clause]) (clause_of_comparison binder base_field_of_expr op left right)
  | _ -> None

(** Collect SQL modifier continuation atoms from an ELet sequence.
    Returns the list of modifier atoms (e.g. [order; user.name; asc; limit; 10])
    by consuming consecutive ELet { name = "_" } whose value starts with a SQL
    modifier keyword (where, order, limit, offset, groupBy, innerJoin).
    Note: `where` only works for functional predicates (isNull, isNotNull,
    inList, notInList, like, ilike) since comparison operators (>, ==, etc.) have
    lower precedence than function application and cannot appear in a flat app chain. *)
let rec collect_sql_continuation_atoms acc = function
  | ELet { name = "_"; value = modifier; body; _ } ->
    let (head, args) = flatten_app_expr [] modifier in
    (match head with
     | EVar { name = ("where" | "order" | "limit" | "offset" | "groupBy" | "innerJoin"); _ } ->
       collect_sql_continuation_atoms (acc @ (head :: args)) body
     | _ -> (acc, body))
  | other -> (acc, other)

let extract_select_query e =
  let rec find_seed = function
    | EBinop { left; right; _ } ->
      (match find_seed left with
       | Some _ as found -> found
       | None -> find_seed right)
    | EApp { fn = _; _ } as app ->
      (* Try parsing the whole EApp first (handles simple EApp chains).
         If that fails (e.g. head is EBinop from a compound-where+order merge),
         recurse into fn to find the embedded select seed. *)
      (match parse_select_seed app with
       | Some _ as found -> found
       | None ->
         let (head, _) = flatten_app_expr [] app in
         (match head with
          | EBinop _ -> find_seed head
          | _ -> None))
    | other -> parse_select_seed other
  in
  match find_seed e with
  | None -> None
  | Some seed ->
    let base_field_of_expr expr =
      match parse_select_seed expr with
      | Some other when same_select_identity seed other -> other.where_field
      | _ -> None
    in
    match e with
    | EApp _ ->
      (match parse_select_seed e with
       | Some same_seed when same_select_identity seed same_seed ->
         (* Top-level EApp: all modifiers (order, limit, etc.) already parsed into seed *)
         Some (same_seed, [])
       | _ ->
         (* EApp wrapping an EBinop (compound where + outer modifiers).
            E.g.: EApp(EApp(EApp(EBinop(BAnd, where_preds), order), p.field), asc)
            Extract order/limit/etc from the outer EApp args, WHERE clauses from the EBinop. *)
         let (head, tail_args) = flatten_app_expr [] e in
         (match head with
          | EBinop _ ->
            (match parse_select_tail seed.binder seed.where_field
                     seed.order seed.limit seed.offset
                     seed.group_by [] seed.joins tail_args with
             | None -> None
             | Some (_, new_order, new_limit, new_offset, new_group_by, new_sc, new_joins) ->
               let updated_seed =
                 { seed with order = new_order; limit = new_limit; offset = new_offset;
                             group_by = new_group_by;
                             static_clauses = seed.static_clauses @ new_sc;
                             joins = seed.joins @ new_joins }
               in
               (match collect_sql_clauses seed.binder base_field_of_expr head with
                | Some where_clauses -> Some (updated_seed, where_clauses)
                | None -> None))
          | _ -> Some (seed, [])))
    | _ ->
      (match collect_sql_clauses seed.binder base_field_of_expr e with
       | Some clauses -> Some (seed, clauses)
       | None -> None)

(** Try to extract a SQL select query from a multi-line ELet chain.
    Handles the case where SQL modifier clauses (order, limit, offset, groupBy,
    innerJoin) appear on separate lines, parsed as separate ELet { name = "_" }
    sequencing expressions rather than as part of the same select EApp tree. *)
let extract_multiline_select_query = function
  | ELet { name = "_"; value = select_e; body; _ } ->
    (match parse_select_seed select_e with
     | Some _ ->
       let (extra_atoms, _) = collect_sql_continuation_atoms [] body in
       (match extra_atoms with
        | [] -> None
        | _ ->
          (* Rebuild: append modifier atoms as individual EApp args to the base select expr *)
          let dummy = Location.dummy_loc "" in
          let combined = List.fold_left
            (fun fn arg -> EApp { fn; arg; loc = dummy })
            select_e extra_atoms in
          extract_select_query combined)
     | None -> None)
  | _ -> None

let extract_delete_query e =
  let rec find_seed = function
    | EBinop { left; right; _ } ->
      (match find_seed left with
       | Some _ as found -> found
       | None -> find_seed right)
    | other -> parse_delete_seed other
  in
  match find_seed e with
  | None -> None
  | Some seed ->
    let base_field_of_expr expr =
      match parse_delete_seed expr with
      | Some other when same_delete_identity seed other -> other.where_field
      | _ -> None
    in
    let clauses =
      match e with
      | EApp _ -> Some []
      | _ -> collect_sql_clauses seed.binder base_field_of_expr e
    in
    Option.map (fun sql_clauses -> (seed, sql_clauses)) clauses

let flatten_underscore_seq e =
  let rec loop acc = function
    | ELet { name = "_"; value; body; _ } -> loop (value :: acc) body
    | last -> List.rev (last :: acc)
  in
  loop [] e

let extract_update e =
  match flatten_underscore_seq e with
  | first :: rest ->
    (match parse_update_start first with
     | None -> None
     | Some (binder, entity, initial_returning_one) ->
       let rec loop clauses updates returning_one = function
         | [] when updates <> [] -> Some { binder; entity; clauses; updates; returning_one }
         | [] -> None
         | expr :: tl ->
           (match parse_returning_one expr with
            | Some flag ->
              if tl = [] && updates <> [] then Some { binder; entity; clauses; updates; returning_one = flag }
              else None
            | None ->
              match parse_update_set binder expr with
              | Some update -> loop clauses (updates @ [update]) returning_one tl
              | None ->
                match collect_sql_clauses binder (parse_standalone_where_field binder) expr with
                | Some new_clauses when new_clauses <> [] -> loop (clauses @ new_clauses) updates returning_one tl
                | _ -> None)
       in
       loop [] [] initial_returning_one rest)
  | [] -> None

let rec emit_expr ctx e =
  let sql_op_name = function
    | BEq -> "==." | BNeq -> "!=" ^ "." | BLt -> "<." | BLe -> "<=."
    | BGt -> ">." | BGe -> ">=."
    | op -> failwith (Printf.sprintf
        "emit_racket: operator %s used in SQL WHERE clause — only ==, !=, <, <=, >, >= are valid SQL predicates; the type-checker should have caught this"
        (match op with BAdd -> "+" | BSub -> "-" | BMul -> "*" | BDiv -> "/" | BMod -> "%%" | BConcat -> "^" | BAnd -> "&&" | BOr -> "||" | _ -> "?"))
  in
  let rec emit_sql_clause entity = function
    | SqlPred { field; op; value } ->
      emit ctx "(";
      emit ctx (sql_op_name op);
      emit ctx " (entity-field-ref ";
      emit ctx entity;
      emit ctx (Printf.sprintf " '%s) " field);
      emit_expr ctx value;
      emit ctx ")"
    | SqlOr clauses ->
      (match clauses with
       | [] -> emit ctx "#f"
       | [left; right] ->
         emit ctx "(or. ";
         emit_sql_clause entity left;
         emit ctx " ";
         emit_sql_clause entity right;
         emit ctx ")"
       | first :: rest ->
         emit ctx "(or. ";
         emit_sql_clause entity first;
         List.iter (fun clause -> emit ctx " "; emit_sql_clause entity clause) rest;
         emit ctx ")")
    | SqlIsNull { field } ->
      emit ctx (Printf.sprintf "(null?. (entity-field-ref %s '%s))" entity field)
    | SqlIsNotNull { field } ->
      emit ctx (Printf.sprintf "(not-null?. (entity-field-ref %s '%s))" entity field)
    | SqlIn { field; values } ->
      emit ctx "(in?. (entity-field-ref ";
      emit ctx entity;
      emit ctx (Printf.sprintf " '%s) (list" field);
      List.iter (fun v -> emit ctx " "; emit_expr ctx v) values;
      emit ctx "))"
    | SqlNotIn { field; values } ->
      emit ctx "(not-in?. (entity-field-ref ";
      emit ctx entity;
      emit ctx (Printf.sprintf " '%s) (list" field);
      List.iter (fun v -> emit ctx " "; emit_expr ctx v) values;
      emit ctx "))"
    | SqlLike { field; pattern } ->
      emit ctx "(like?. (entity-field-ref ";
      emit ctx entity;
      emit ctx (Printf.sprintf " '%s) " field);
      emit_expr ctx pattern;
      emit ctx ")"
    | SqlILike { field; pattern } ->
      emit ctx "(ilike?. (entity-field-ref ";
      emit ctx entity;
      emit ctx (Printf.sprintf " '%s) " field);
      emit_expr ctx pattern;
      emit ctx ")"
  in
  let emit_sql_where_clauses entity clauses =
    List.iter (fun clause ->
      emit ctx " (where ";
      emit_sql_clause entity clause;
      emit ctx ")"
    ) clauses
  in
  let emit_sql_select (seed : sql_select_seed) clauses =
    let all_clauses = seed.static_clauses @ clauses in
    let emit_core () =
      (match seed.kind with
       | SelectMany | SelectOne ->
         emit ctx (Printf.sprintf "(%s (from %s)"
           (match seed.kind with SelectOne -> "select-one" | _ -> "select-many")
           seed.entity)
       | SelectCount ->
         emit ctx (Printf.sprintf "(select-count (from %s)" seed.entity)
       | SelectSum field ->
         emit ctx (Printf.sprintf "(select-sum (entity-field-ref %s '%s) (from %s)" seed.entity field seed.entity)
       | SelectMax field ->
         emit ctx (Printf.sprintf "(select-max (entity-field-ref %s '%s) (from %s)" seed.entity field seed.entity)
       | SelectMin field ->
         emit ctx (Printf.sprintf "(select-min (entity-field-ref %s '%s) (from %s)" seed.entity field seed.entity));
      emit_sql_where_clauses seed.entity all_clauses;
      List.iter (fun (j : sql_join) ->
        emit ctx (Printf.sprintf " (inner-join %s (entity-field-ref %s '%s) (entity-field-ref %s '%s))"
          j.join_entity seed.entity j.main_field j.join_entity j.join_field)
      ) seed.joins;
      (match seed.kind with
       | SelectMany | SelectOne ->
         (match seed.order with
          | Some (field, dir) ->
            emit ctx (Printf.sprintf " (order-by (entity-field-ref %s '%s) '%s)" seed.entity field dir)
          | None -> ());
         (match seed.limit with
          | Some n -> emit ctx (Printf.sprintf " (limit %d)" n)
          | None -> ());
         (match seed.offset with
          | Some n -> emit ctx (Printf.sprintf " (offset %d)" n)
          | None -> ())
       | SelectCount | SelectSum _ | SelectMax _ | SelectMin _ -> ());
      (match seed.group_by with
       | [] -> ()
       | fields ->
         emit ctx " (group-by";
         List.iter (fun f ->
           emit ctx (Printf.sprintf " (entity-field-ref %s '%s)" seed.entity f)
         ) fields;
         emit ctx ")");
      emit ctx ")"
    in
    match seed.kind with
    | SelectOne ->
      emit ctx "(let ([tesl_match ";
      emit_core ();
      emit ctx "]) (if tesl_match (Something tesl_match) Nothing))"
    | SelectMany | SelectCount | SelectSum _ | SelectMax _ | SelectMin _ ->
      emit_core ()
  in
  let emit_sql_insert (insert : sql_insert) =
    emit ctx (Printf.sprintf "(insert-one! %s (hash" insert.entity);
    List.iter (fun (field, value) ->
      emit ctx " ";
      emit ctx (Printf.sprintf "'%s " field);
      emit_expr ctx value
    ) insert.fields;
    emit ctx "))"
  in
  let emit_sql_delete (seed : sql_delete_seed) clauses =
    let fn = if seed.with_result then "delete-many-with-count!" else "delete-many!" in
    emit ctx (Printf.sprintf "(%s (from %s)" fn seed.entity);
    emit_sql_where_clauses seed.entity clauses;
    emit ctx ")"
  in
  let emit_sql_insert_many (list_var : string) (entity : string) =
    emit ctx (Printf.sprintf "(insert-many! (from %s) %s)" entity list_var)
  in
  let emit_sql_update (update : sql_update) =
    let emit_core () =
      emit ctx (Printf.sprintf "(update-many! (from %s) (hash" update.entity);
      List.iter (fun (field, value) ->
        emit ctx (Printf.sprintf " (entity-field-ref %s '%s) " update.entity field);
        emit_expr ctx value
      ) update.updates;
      emit ctx ")";
      emit_sql_where_clauses update.entity update.clauses;
      emit ctx ")"
    in
    if update.returning_one then begin
      emit ctx "(car ";
      emit_core ();
      emit ctx ")"
    end else begin
      emit ctx "(void ";
      emit_core ();
      emit ctx ")"
    end
  in
  let _ = emit_sql_insert_many in (* used below *)
  let emit_sql_upsert (upsert : sql_upsert) =
    emit ctx (Printf.sprintf "(upsert-one! %s (hash" upsert.entity);
    List.iter (fun (field, value) ->
      emit ctx " ";
      emit ctx (Printf.sprintf "'%s " field);
      emit_expr ctx value
    ) upsert.fields;
    emit ctx ") '(";
    List.iter (fun f -> emit ctx (Printf.sprintf "%s " f)) upsert.conflict;
    emit ctx ") '(";
    List.iter (fun f -> emit ctx (Printf.sprintf "%s " f)) upsert.do_update;
    emit ctx "))"
  in
  let emit_ctor_arg arg =
    match arg with
    | EVar { name; _ } when not (Hashtbl.mem ctx.fn_names name) &&
                             not (Hashtbl.mem stdlib_name_map name) &&
                             not (Hashtbl.mem qualified_imports name) &&
                             not (Hashtbl.mem stdlib_plain_imports name) ->
      if Hashtbl.mem ctx.proof_locals name then emit ctx name
      else if ctx.func_kind <> None then begin
        if Hashtbl.mem ctx.param_names name || Hashtbl.mem ctx.raw_locals name then emit ctx ("*" ^ name)
        else emit ctx (Printf.sprintf "(raw-value %s)" name)
      end
      else emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
    | _ -> emit_expr_simple ctx arg
  in
  match e with
  | ELit { lit; _ } -> emit_lit ctx lit
  | EVar { name; loc } ->
    (* Bare stdlib plain import (not GDP-aware) → zero-arg call with raw-value wrapping.
       GDP-aware plain imports (in gdp_returning_stdlib) → zero-arg call without raw-value. *)
    if ctx.func_kind <> None && Hashtbl.mem ctx.proof_aware_locals name then
      emit ctx (resolve_name name)  (* proof-carrying var: pass as named-value *)
    else if ctx.func_kind <> None && Hashtbl.mem ctx.raw_locals name then
      emit ctx ("*" ^ name)
    else if Hashtbl.mem stdlib_plain_imports name && not (Hashtbl.mem stdlib_name_map name) then begin
      if Hashtbl.mem gdp_returning_stdlib name then
        emit ctx (Printf.sprintf "(%s)" (resolve_name name))  (* GDP: no raw-value *)
      else
        emit ctx (Printf.sprintf "(raw-value (%s))" (resolve_name name))
    end else begin
      (* SQL operation keywords must only appear in recognised SQL patterns.
         If they reach here as free variables the emitter has not matched the
         surrounding expression as a SQL pattern — report a compile-time error
         rather than emitting an unbound identifier that fails at Racket runtime. *)
      let sql_op_keywords = ["update"; "updateAndReturnOne"; "insert"; "insertMany";
                             "delete"; "deleteAndReturnResult"; "selectOne"] in
      if List.mem name sql_op_keywords &&
         not (Hashtbl.mem ctx.fn_names name) then
        failwith (Printf.sprintf
          "%s:%d:%d: SQL keyword '%s' used in an unrecognized expression pattern.\n\
           Hint: SQL operations require the multi-line form, e.g.:\n\
           \  update p in Entity\n\
           \    where p.field == value\n\
           \    set p.field = value\n\
           Single-line SQL syntax is not supported."
          loc.file loc.start.line loc.start.col name)
      else
        emit ctx (resolve_name name)
    end
  | EField { obj = EVar { name = "cli"; _ }; field = "args"; _ } ->
    emit ctx "tesl_import_cli_args"
  | EField { obj; field; _ } ->
    (* Check if this is a module-qualified name: Module.function *)
    let qual_name = match obj with
      | EConstructor { name = modname; args = []; _ } ->
        let full = modname ^ "." ^ field in
        (match Hashtbl.find_opt qualified_imports full with
         | Some renamed -> Some renamed
         | None -> Some (import_rename full))
      | _ -> None
    in
    (match qual_name with
     | Some renamed -> emit ctx renamed
     | None ->
       (* Field access strategy:
          - EVar with special fields (value/cookies/headers/body/path/method/status): dot notation
          - EVar in handler context: dot notation for all fields
          - All other cases: field-access-ref *)
       (* Use dot notation in all function contexts except plain fn (define/pow) *)
       let is_handler_ctx = match ctx.func_kind with
         | Some HandlerKind | Some WorkerKind | Some DeadWorkerKind
         | Some CheckKind | Some AuthKind | Some EstablishKind -> true
         | _ -> false
       in
       let is_special_field = match field with
         | "value" | "cookies" | "headers" | "body" | "path" | "method_" | "status" -> true
         | _ -> false
       in
       let in_func_context = ctx.func_kind <> None in
       (match obj with
        | EVar _ when in_func_context && (is_special_field || is_handler_ctx) ->
          (* In function context with special fields: use dot notation *)
          emit ctx "(raw-value ";
          emit_field_inner ctx obj;
          emit ctx (Printf.sprintf ".%s)" field)
        | _ ->
          (* Use tesl-dot/runtime so gensym symbols are resolved via evidence-env
             (needed for fn-kind params like w: B.Widget where w is a gensym) *)
          (* In function context, emit without raw-value so proof-bearing
             named-values propagate to callee parameter bindings.
             In test/top-level context, wrap in raw-value for equality checks. *)
          if ctx.func_kind <> None then begin
            emit ctx "(tesl-dot/runtime ";
            emit_field_inner ctx obj;
            emit ctx (Printf.sprintf " '%s)" field)
          end else begin
            emit ctx "(raw-value (tesl-dot/runtime ";
            emit_field_inner ctx obj;
            emit ctx (Printf.sprintf " '%s))" field)
          end))
  | EApp { fn = EVar { name = "make-witness"; _ };
           arg = EApp { fn = EVar { name = witness_name; _ }; arg = body; _ }; _ } ->
    (* Existential witness: (pack ([witness]) body) *)
    emit ctx (Printf.sprintf "(pack ([%s]) " witness_name);
    emit_expr ctx body;
    emit ctx ")"
  | EApp _ as app when (match extract_select_query app with Some _ -> true | None -> false) ->
    (match extract_select_query app with
     | Some (seed, clauses) -> emit_sql_select seed clauses
     | None -> failwith "emit_racket: extract_select_query guard passed but returned None — compiler invariant violation; please report this bug")
  | EApp _ as app when (match parse_insert_expr app with Some _ -> true | None -> false) ->
    (match parse_insert_expr app with
     | Some insert -> emit_sql_insert insert
     | None -> failwith "emit_racket: parse_insert_expr guard passed but returned None — compiler invariant violation; please report this bug")
  | EApp _ as app when (match parse_upsert_expr app with Some _ -> true | None -> false) ->
    (match parse_upsert_expr app with
     | Some upsert -> emit_sql_upsert upsert
     | None -> failwith "emit_racket: parse_upsert_expr guard passed but returned None — compiler invariant violation; please report this bug")
  | EApp _ as app when (match parse_insert_many_expr app with Some _ -> true | None -> false) ->
    (match parse_insert_many_expr app with
     | Some (list_var, entity) -> emit_sql_insert_many list_var entity
     | None -> failwith "emit_racket: parse_insert_many_expr guard passed but returned None — compiler invariant violation; please report this bug")
  | EApp _ as app when (match extract_delete_query app with Some _ -> true | None -> false) ->
    (match extract_delete_query app with
     | Some (seed, clauses) -> emit_sql_delete seed clauses
     | None -> failwith "emit_racket: extract_delete_query guard passed but returned None — compiler invariant violation; please report this bug")
  | EApp { fn = EVar { name = "#record-update#"; _ }; arg = ERecord { fields; type_hint = _; loc = _ }; _ } ->
    (* Record update: (tesl-record-update *base (hash 'f1 v1 ...)) *)
    (* Determine the record type from field names so we can preserve proof on
       proof-annotated fields.  The type checker has already validated the update,
       so we scan record_meta for the first type that owns the updated fields. *)
    let updated_field_names = List.filter_map (fun (k, _) ->
      if k = "__base__" then None else Some k
    ) fields in
    let update_record_type_opt =
      List.find_opt (fun (_, field_defs, _) ->
        updated_field_names <> [] &&
        List.for_all (fun fname ->
          List.exists (fun (fd : Ast.field_def) -> fd.name = fname) field_defs
        ) updated_field_names
      ) ctx.record_meta
    in
    let update_field_has_proof k =
      match update_record_type_opt with
      | None -> false
      | Some (_, field_defs, _) ->
        (match List.find_opt (fun (fd : Ast.field_def) -> fd.name = k) field_defs with
         | Some fd -> fd.proof_ann <> None
         | None -> false)
    in
    let emit_update_field_val k v =
      match v with
      | EVar { name; _ } when not (Hashtbl.mem ctx.fn_names name) &&
                               not (Hashtbl.mem stdlib_name_map name) ->
        if update_field_has_proof k then emit ctx (resolve_name name)
        else if ctx.func_kind <> None then emit ctx ("*" ^ name)
        else emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
      | _ ->
        (* For complex expressions: preserve named-value for proof-annotated fields,
           otherwise strip to raw value (matching construction path behaviour). *)
        if update_field_has_proof k then emit_expr_simple ctx v
        else emit_raw_value ctx v
    in
    (match List.assoc_opt "__base__" fields with
     | Some base_expr ->
       let other_fields = List.filter (fun (k, _) -> k <> "__base__") fields in
       emit ctx "(tesl-record-update ";
       emit_raw_value ctx base_expr;
       emit ctx " (hash ";
       List.iteri (fun i (k, v) ->
         if i > 0 then emit ctx " ";
         emit ctx (Printf.sprintf "'%s " k);
         emit_update_field_val k v
       ) other_fields;
       emit ctx "))"
     | None -> emit ctx "()"  (* should not happen *))
  (* TypeName { field: val } — record or entity construction with explicit type name *)
  | EApp {
      fn = EConstructor { name = rname; args = []; _ };
      arg = ERecord { fields; loc = _; _ };
      loc = _;
    } when List.mem_assoc rname ctx.record_fields ->
    let field_defs = match List.assoc_opt rname ctx.record_fields with
      | Some defs -> defs
      | None -> []
    in
    let emit_field_val k v =
      let v' = match v with
        | ERecord { fields = sub_fields; type_hint = None; loc } ->
          (match List.assoc_opt k field_defs with
           | Some (TName { name = sub_type; _ }) ->
             ERecord { fields = sub_fields; type_hint = Some sub_type; loc }
           | _ -> v)
        | _ -> v
      in
      (* Check if this field carries a proof annotation — preserve proof if so *)
      let field_has_proof =
        match List.find_opt (fun (n, _, _) -> n = rname) ctx.record_meta with
        | Some (_, field_defs_meta, _) ->
          (match List.find_opt (fun (fd : Ast.field_def) -> fd.name = k) field_defs_meta with
           | Some fd -> fd.proof_ann <> None
           | None -> false)
        | None -> false
      in
      match v' with
      | EVar { name; _ } when not (Hashtbl.mem ctx.fn_names name) &&
                               not (Hashtbl.mem qualified_imports name) &&
                               not (Hashtbl.mem stdlib_name_map name) ->
        if field_has_proof then emit ctx (resolve_name name)
        else if ctx.func_kind <> None then emit ctx ("*" ^ name)
        else emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
      | _ -> emit_expr_simple ctx v'
    in
    if Hashtbl.mem ctx.entity_names rname then begin
      (* Entity rows are plain hashes at runtime — emit (hash 'field val ...) *)
      emit ctx "(hash";
      List.iter (fun (k, v) ->
        emit ctx (Printf.sprintf " '%s " k);
        emit_field_val k v
      ) fields;
      emit ctx ")"
    end else begin
      (* Plain record — emit (TypeName #:field val ...) *)
      emit ctx (Printf.sprintf "(%s" rname);
      List.iter (fun (k, v) ->
        emit ctx (Printf.sprintf " #:%s " k);
        emit_field_val k v
      ) fields;
      emit ctx ")"
    end
  | EApp _ ->
    (match direct_check_call e with
     | Some (check_fn, check_args) ->
       (* Inside a check/auth body, preserve the check-ok result so define-checker
          can thread the proof through.  Everywhere else, strip the named-value
          wrapper to produce a raw value. *)
       let inside_checker = match ctx.func_kind with
         | Some CheckKind | Some AuthKind -> true
         | _ -> false
       in
       (* Also skip raw-value for fn functions with proof-carrying returns
          (RetNamedPack, RetAttached) — the GDP proof must be preserved. *)
       let has_proof_return = match ctx.func_return_spec with
         | Some (RetNamedPack _) -> true
         | _ -> false
       in
       if inside_checker || has_proof_return then emit ctx "(" else emit ctx "(raw-value (";
       emit_expr ctx check_fn;
       List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) check_args;
       if inside_checker || has_proof_return then emit ctx ")" else emit ctx "))"
     | None ->
       (* Flatten curried application: f x y z → (f x y z) in Racket *)
    let rec collect_args acc e = match e with
      | EApp { fn; arg; _ } -> collect_args (arg :: acc) fn
      | _                   -> (e, acc)
    in
    let (fn, args) = collect_args [] e in
    (* Special case: initTelemetry keyword value ... → (init-opentelemetry! #:kw val ...) *)
    let is_init_telemetry = match fn with
      | EVar { name = "initTelemetry"; _ } -> true | _ -> false
    in
    if is_init_telemetry then begin
      emit ctx "(init-opentelemetry!";
      let rec emit_kw_args = function
        | [] -> ()
        | EVar { name = kw; _ } :: v :: rest ->
          let racket_kw = match kw with
            | "service" -> "service-name"
            | "endpoint" -> "endpoint"
            | "console" -> "console?"
            | other -> other
          in
          emit ctx (Printf.sprintf " #:%s " racket_kw);
          (match v with
           | ELit { lit = LBool true; _ } -> emit ctx "#t"
           | ELit { lit = LBool false; _ } -> emit ctx "#f"
           | _ -> emit_expr_simple ctx v);
          emit_kw_args rest
        | _ -> ()
      in
      emit_kw_args args;
      emit ctx ")"
    end else
    let stdlib_racket_name fn =
      match fn with
      | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
        let full = modname ^ "." ^ field in
        (match Hashtbl.find_opt qualified_imports full with
         | Some r -> r | None -> import_rename full)
      | EVar { name; _ } when Hashtbl.mem stdlib_plain_imports name -> name
      | _ -> ""
    in
    (* Check for zero-arg call: f () -> (f). For stdlib calls, only a small whitelist really behaves as zero-arg; otherwise [] is an empty-list argument. *)
    let is_unit_arg = match args with
      | [EList { elems = []; _ }] -> true
      | _ -> false
    in
    let is_zero_arg_stdlib =
      let name = stdlib_racket_name fn in
      name <> "" && Hashtbl.mem stdlib_zero_arg_names name
    in
    (* Helper: emit just the function name (no zero-arg call treatment) *)
    let emit_fn_name fn =
      match fn with
      | EVar { name; _ } -> emit ctx (resolve_name name)
      | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
        let full = modname ^ "." ^ field in
        (match Hashtbl.find_opt qualified_imports full with
         | Some r -> emit ctx r | None -> emit ctx (import_rename full))
      | _ -> emit_expr ctx fn
    in
    let fn_arity = match fn with
      | EVar { name; _ } -> Hashtbl.find_opt ctx.fn_arities name
      | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
        Hashtbl.find_opt ctx.fn_arities (modname ^ "." ^ field)
      | _ -> None
    in
    begin match fn_arity with
    | Some arity when List.length args < arity && not is_unit_arg ->
      let missing = arity - List.length args in
      let partial_id = ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      let params = List.init missing (fun i -> Printf.sprintf "_tesl_p%d_%d" partial_id i) in
      (* Emit nested curried lambdas so chained partial application works:
         mul3 2 => (lambda (p0) (lambda (p1) (mul3 2 p0 p1))) *)
      List.iter (fun param ->
        emit ctx "(lambda (";
        emit ctx param;
        emit ctx ") "
      ) params;
      emit ctx "(";
      emit_fn_name fn;
      (* Use emit_ctor_arg (not emit_expr_simple) so that function-parameter
         variables are emitted as *name (raw value) rather than as their GDP
         name symbol, which would be unresolvable outside the originating
         define/pow evidence environment. *)
      List.iter (fun arg -> emit ctx " "; emit_ctor_arg arg) args;
      List.iter (fun param -> emit ctx " "; emit ctx param) params;
      emit ctx ")";
      List.iter (fun _ -> emit ctx ")") params
    | _ -> begin
    (* Only treat [] as a zero-arg call when the function is known to take 0
       parameters (fn_arity = Some 0) or has no recorded arity (None).
       When the function is known to take ≥ 1 argument, [] is a real empty-list
       argument, NOT a unit/zero-arg marker. *)
    let is_actually_zero_arg =
      is_unit_arg &&
      (match fn_arity with
       | Some n when n > 0 -> false  (* has parameters — [] is a real empty list *)
       | _ -> (not (is_stdlib_fn fn)) || is_zero_arg_stdlib)
    in
    if is_actually_zero_arg then begin
      (* Zero-arg call: if stdlib fn, emit (raw-value (fn)), else (fn) *)
      if is_stdlib_fn fn then begin
        emit ctx "(raw-value ("; emit_fn_name fn; emit ctx "))"
      end else begin
        emit ctx "("; emit_expr ctx fn; emit ctx ")"
      end
    end else
    (* If the function is a constructor, wrap in raw-value *)
    let is_ctor = match fn with
      | EConstructor _ -> true
      | EVar { name; _ } ->
        (* Uppercase identifier is a constructor *)
        String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z'
      | _ -> false
    in
    if is_ctor then begin
      let ctor_name = match fn with
        | EConstructor { name; _ } -> Some name
        | EVar { name; _ } -> Some name
        | _ -> None
      in
      (* When a constructor is called with a single ERecord argument,
         the fields need to be emitted positionally (not as a hash map),
         because define-adt generates constructors with positional arguments.
         Use ctor_fields to determine the correct field order. *)
      let handled_as_positional = match ctor_name, args with
        | Some cname, [ERecord { fields = record_fields; _ }] ->
          (match Hashtbl.find_opt ctx.ctor_fields cname with
           | Some labels when labels <> [] ->
             let proof_fields = match Hashtbl.find_opt ctx.proof_annotated_ctor_fields cname with
               | Some fs -> fs | None -> []
             in
             emit ctx "(raw-value (";
             emit_fn_name fn;
             List.iter (fun label ->
               emit ctx " ";
               (match List.assoc_opt label record_fields with
                | Some fval ->
                  (* For proof-annotated fields: always emit the variable as-is (named-value)
                     so the IsPositive proof survives ADT storage and retrieval.
                     For non-proof-annotated fields: use emit_expr (which may strip to *var). *)
                  let is_proof_field = List.mem label proof_fields in
                  (match fval with
                   | EVar { name; _ } when is_proof_field && (Hashtbl.mem ctx.raw_locals name || Hashtbl.mem ctx.param_names name) ->
                     emit ctx (resolve_name name)  (* keep named-value, no star *)
                   | _ -> emit_expr ctx fval)
                | None -> emit ctx "Leaf")  (* fallback for missing fields *)
             ) labels;
             emit ctx "))";
             true
           | _ -> false)
        | _ -> false
      in
      if not handled_as_positional then begin
        (* When returning a proof-carrying generic wrapper (outer_ty = Some),
           preserve inner variable proofs — emit the variable name directly
           instead of *name so the named-value survives through the constructor. *)
        let preserve_inner_proofs = match ctx.func_return_spec with
          | Some (RetMaybeAttached { outer_ty = Some _; binding = b; _ }) when b.proof_ann <> None -> true
          | _ -> false
        in
        emit ctx "(raw-value (";
        emit_fn_name fn;
        List.iter (fun arg ->
          emit ctx " ";
          if preserve_inner_proofs then
            (match arg with
             | EVar { name = vname; _ } -> emit ctx (resolve_name vname)
             | _ -> emit_ctor_arg arg)
          else
            emit_ctor_arg arg) args;
        emit ctx "))"
      end
    end else if is_stdlib_fn fn then begin
      (* Stdlib/import call: wrap result in (raw-value ...), unwrap EVar args with * *)
      (* Compute fn_racket_name first so emit_stdlib_arg can check proof_consuming_stdlib *)
      let fn_racket_name = match fn with
        | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
          let full = modname ^ "." ^ field in
          (match Hashtbl.find_opt qualified_imports full with
           | Some r -> r | None -> import_rename full)
        | EVar { name; _ } ->
          if Hashtbl.mem stdlib_plain_imports name then name else ""
        | _ -> ""
      in
      let emit_stdlib_arg arg =
        let rec app_head_name = function
          | EApp { fn; _ } -> app_head_name fn
          | EVar { name; _ } -> Some name
          | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
            let full = modname ^ "." ^ field in
            Some (match Hashtbl.find_opt qualified_imports full with
              | Some renamed -> renamed
              | None -> import_rename full)
          | EField { obj = EVar { name = modname; _ }; field; _ } -> Some (modname ^ "." ^ field)
          | _ -> None
        in
        match arg with
        | EVar { name; _ } when not (Hashtbl.mem ctx.fn_names name) &&
                                 not (Hashtbl.mem stdlib_name_map name) &&
                                 not (Hashtbl.mem qualified_imports name) &&
                                 not (Hashtbl.mem stdlib_plain_imports name) ->
          if Hashtbl.mem ctx.proof_locals name then emit ctx name
          else if ctx.func_kind <> None && (Hashtbl.mem ctx.param_names name || Hashtbl.mem ctx.raw_locals name) then
            (* Proof-annotated function parameters carry GDP named-values with runtime
               proofs.  Proof-CONSUMING stdlib functions (Int.divide, Dict.get, Float.div)
               need the GDP symbol so validate-runtime-argument can find the evidence in
               current-evidence-env.  All other stdlib functions receive raw [*]name values.
               raw_locals always use [*]name. *)
            if not (Hashtbl.mem ctx.raw_locals name)
               && not (Hashtbl.mem ctx.plain_param_names name)
               && Hashtbl.mem proof_consuming_stdlib fn_racket_name then
              emit ctx name
            else
              emit ctx ("*" ^ name)
          else emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
        | EApp _ ->
          let needs_raw = match app_head_name arg with
            | Some fn_name -> Hashtbl.mem gdp_returning_stdlib fn_name || Hashtbl.mem ctx.fn_names fn_name
            | None -> false
          in
          if needs_raw then emit_raw_value ctx arg else emit_expr_simple ctx arg
        | _ -> emit_expr_simple ctx arg
      in
      let wraps_in_raw_value = not (Hashtbl.mem gdp_returning_stdlib fn_racket_name) in
      (* Always emit opening paren for the call *)
      if wraps_in_raw_value then emit ctx "(raw-value (" else emit ctx "(";
      emit_fn_name fn;
      List.iter (fun arg -> emit ctx " "; emit_stdlib_arg arg) args;
      if wraps_in_raw_value then emit ctx "))" else emit ctx ")"
    end else begin
      emit ctx "(";
      emit_expr ctx fn;
      List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) args;
      emit ctx ")"
    end
    end
    end
    )
  | EBinop _ as sql_expr when (match extract_select_query sql_expr with Some _ -> true | None -> false) ->
    (match extract_select_query sql_expr with
     | Some (seed, clauses) -> emit_sql_select seed clauses
     | None -> failwith "emit_racket: extract_select_query (EBinop) guard passed but returned None — compiler invariant violation; please report this bug")
  | EBinop _ as sql_expr when (match extract_delete_query sql_expr with Some _ -> true | None -> false) ->
    (match extract_delete_query sql_expr with
     | Some (seed, clauses) -> emit_sql_delete seed clauses
     | None -> failwith "emit_racket: extract_delete_query (EBinop) guard passed but returned None — compiler invariant violation; please report this bug")
  | EBinop { op; left; right; _ } -> emit_binop ctx op left right
  | EUnop { op; arg; _ } ->
    (* Helper: emit a bare EVar param as *name (raw value), else emit normally.
       Needed for boolean conditions where named-value params must be unwrapped. *)
    let emit_raw_param_or_expr e =
      match e with
      | EVar { name; _ } when ctx.func_kind <> None &&
                               (Hashtbl.mem ctx.param_names name || Hashtbl.mem ctx.raw_locals name) ->
        emit ctx ("*" ^ name)
      | _ -> emit_expr ctx e
    in
    (match op with
     | UNeg ->
       (* Emit negative integer literals as -n directly, not (- n) *)
       (match arg with
        | ELit { lit = LInt n; _ } -> emit ctx (string_of_int (-n))
        | _ -> emit ctx "(- "; emit_raw_param_or_expr arg; emit ctx ")")
     | UNot -> emit ctx "(not "; emit_raw_param_or_expr arg; emit ctx ")")
  | EIf { cond; then_; else_; _ } ->
    (* Helper: emit a bare EVar param as *name (raw value), else emit normally. *)
    let emit_raw_param_or_expr e =
      match e with
      | EVar { name; _ } when ctx.func_kind <> None &&
                               (Hashtbl.mem ctx.param_names name || Hashtbl.mem ctx.raw_locals name) ->
        emit ctx ("*" ^ name)
      | _ -> emit_expr ctx e
    in
    emit ctx "(if ";
    emit_raw_param_or_expr cond;
    emit ctx " ";
    emit_raw_param_or_expr then_;
    emit ctx " ";
    emit_raw_param_or_expr else_;
    emit ctx ")"
  | ECase { scrut; arms; _ } ->
    let var = fresh_case ctx in
    (* In test-block context (func_kind = None), define/pow's transform-body-expr is
       absent so the macro never creates *var from a plain `var` let-binding.  Bind
       *var directly so pattern_to_racket's star_ref references resolve correctly.
       In fn-body context (func_kind <> None), the macro creates *var automatically
       from the plain `var` binding — keep the existing behaviour. *)
    let bind_var = if ctx.func_kind = None then "*" ^ var else var in
    emit ctx (Printf.sprintf "(let ([%s " bind_var);
    emit_raw_value ctx scrut;
    emit ctx "]) (cond ";
    List.iteri (fun i arm ->
      if i > 0 then emit ctx " ";
      emit_case_arm ctx bind_var arm
    ) arms;
    emit ctx "))"
  | ELet _ as seq when (match extract_update seq with Some _ -> true | None -> false) ->
    (match extract_update seq with
     | Some update -> emit_sql_update update
     | None -> failwith "emit_racket: extract_update guard passed but returned None — compiler invariant violation; please report this bug")
  | ELet _ as seq when (match extract_multiline_select_query seq with Some _ -> true | None -> false) ->
    (* Multi-line SQL: select on one line, modifier keywords (order/limit/etc.) on subsequent lines *)
    (match extract_multiline_select_query seq with
     | Some (seed, clauses) -> emit_sql_select seed clauses
     | None -> failwith "emit_racket: extract_multiline_select_query guard passed but returned None — compiler invariant violation; please report this bug")
  | ELet { name = "_"; value = ((ETelemetry _ | EEnqueue _ | EPublish _ | EStartWorkers _ | EWithDatabase _ | EWithCapabilities _ | EWithTransaction _ | EServe _ | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _ | ESendEmail _ | EStartEmailWorker _ | ERuntimeCall _) as stmt); body; _ } ->
    (* Runtime statements in sequence lower to begin blocks. *)
    emit ctx "(begin ";
    emit_expr ctx stmt;
    emit ctx " ";
    emit_expr ctx body;
    emit ctx ")"
  | ELet { name = binding_name; value = (EApp _ as check_app); body; _ }
    when (let rec find_check = function
           | EApp { fn = EVar { name = "check"; _ }; _ } -> true
           | EApp { fn; _ } -> find_check fn
           | _ -> false
          in find_check check_app) ->
    (* check form: let x = check fn args → (let/check ([tmp (fn args)]) (let ([x (attach-proof...)]) body)) *)
    let tmp = Printf.sprintf "tesl_checked_%d" ctx.case_counter in
    ctx.case_counter <- ctx.case_counter + 1;
    (* Strip the "check" prefix: collect all args and the real function *)
    let rec collect_check_args acc = function
      | EApp { fn = EVar { name = "check"; _ }; arg; _ } -> (arg, acc)
      | EApp { fn; arg; _ } -> collect_check_args (arg :: acc) fn
      | e -> (e, List.rev acc)
    in
    let (fn_expr, args) = collect_check_args [] check_app in
    (* When the check call is a partial application (args=[]) and the body is
       an EOk, the EOk's value is the actual argument to the check function.
       E.g. `let _ = (check (checkP && checkS)); n ::: p` should apply the
       combined check to n, then attach proof p. *)
    let (args, body, extra_proof) = match args, body with
      | [], EOk { value; proof; _ } -> ([value], EVar { name = binding_name; loc = Location.dummy_loc "" }, Some proof)
      | _ -> (args, body, None)
    in
    emit ctx (Printf.sprintf "(let/check ([%s (" tmp);
    emit_expr ctx fn_expr;
    List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) args;
    emit ctx (Printf.sprintf ")]) (let ([%s %s]) " binding_name tmp);
    Hashtbl.replace ctx.proof_locals binding_name ();
    (match extra_proof with
     | Some proof ->
       emit ctx "(attach-proof ";
       emit_expr ctx body;
       emit ctx " ";
       emit_runtime_proof ctx proof;
       emit ctx ")"
     | None -> emit_expr ctx body);
    Hashtbl.remove ctx.proof_locals binding_name;
    emit ctx "))"
  | ELet { name; value; body; _ } ->
    (* Track Fact-valued bindings so BAnd of Fact vars can use intro-and. *)
    let is_fact_value = match value with
      | EApp _ ->
        let rec head = function EApp { fn; _ } -> head fn | e -> e in
        (match head value with
         | EVar { name = fn_name; _ } ->
           (* detachFact always produces a Fact *)
           fn_name = "detachFact" ||
           (* validPort / establish calls also produce Facts — detect by checking
              that fn_name is NOT a stdlib plain import and IS a user function.
              More reliable: check if value is already tracked as fact. *)
           (Hashtbl.mem ctx.fn_names fn_name &&
            not (Hashtbl.mem stdlib_plain_imports fn_name))
         | _ -> false)
      | EBinop { op = BAnd; left; right; _ } ->
        (* Conjunction of fact_locals is also a Fact *)
        let rec all_facts e = match e with
          | EVar { name; _ } -> Hashtbl.mem ctx.fact_locals name
          | EBinop { op = BAnd; left; right; _ } -> all_facts left && all_facts right
          | _ -> false
        in
        all_facts left && all_facts right
      | _ -> false
    in
    if is_fact_value then Hashtbl.replace ctx.fact_locals name ();
    let is_proof_carrier_value =
      match value with
      | EApp _ ->
        let rec get_fn = function EApp { fn; _ } -> get_fn fn | e -> e in
        (match get_fn value with
         | EVar { name = fn_name; _ } ->
           (match Hashtbl.find_opt ctx.fn_return_specs fn_name with
            | Some (RetMaybeAttached { binding = b; _ }) when b.proof_ann <> None -> true
            | _ -> false)
         | _ -> false)
      | _ -> false
    in
    if is_proof_carrier_value then Hashtbl.replace ctx.proof_carrier_lets name ();
    emit ctx (Printf.sprintf "(let ([%s " name);
    emit_expr ctx value;
    emit ctx "]) ";
    emit_expr ctx body;
    if is_fact_value then Hashtbl.remove ctx.fact_locals name;
    if is_proof_carrier_value then Hashtbl.remove ctx.proof_carrier_lets name;
    emit ctx ")"
  | ELetProof { value_name; proof_name; value; body; _ } ->
    (* Proof decompose: let (x ::: p) = y →
       (let ([tmp y]) (let ([x (forget-proof tmp)] [p (detach-all-proof tmp)]) body))
       When y is a check call, emit it WITHOUT the raw-value wrapper so that
       detach-all-proof can access the proof carried by the check-ok result. *)
    let tmp = Printf.sprintf "tesl_proof_binding_%d" ctx.case_counter in
    ctx.case_counter <- ctx.case_counter + 1;
    emit ctx (Printf.sprintf "(let ([%s " tmp);
    (match direct_check_call value with
     | Some (check_fn, check_args) ->
       (* Preserve check-ok result: emit (checkFn args) without raw-value *)
       emit ctx "(";
       emit_expr ctx check_fn;
       List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) check_args;
       emit ctx ")"
     | None -> emit_expr ctx value);
    emit ctx (Printf.sprintf "]) (let ([%s (forget-proof %s)] [%s (detach-all-proof %s)]) "
      value_name tmp proof_name tmp);
    emit_expr ctx body;
    emit ctx "))"
  | ERecord { fields; type_hint; _ } ->
    (* Check for record update: __base__ field indicates update expression *)
    (match List.assoc_opt "__base__" fields with
     | Some base_expr ->
       (* Record update: (tesl-record-update *base (hash 'f1 v1 ...)) *)
       let other_fields = List.filter (fun (k, _) -> k <> "__base__") fields in
       (* Determine the record type from type_hint or field names to preserve proofs *)
       let er_update_record_type_opt =
         match type_hint with
         | Some tn -> List.find_opt (fun (n, _, _) -> n = tn) ctx.record_meta
         | None ->
           let field_names = List.map fst other_fields in
           List.find_opt (fun (_, field_defs, _) ->
             field_names <> [] &&
             List.for_all (fun fname ->
               List.exists (fun (fd : Ast.field_def) -> fd.name = fname) field_defs
             ) field_names
           ) ctx.record_meta
       in
       let er_update_field_has_proof k =
         match er_update_record_type_opt with
         | None -> false
         | Some (_, field_defs, _) ->
           (match List.find_opt (fun (fd : Ast.field_def) -> fd.name = k) field_defs with
            | Some fd -> fd.proof_ann <> None
            | None -> false)
       in
       let emit_er_update_field_val k v =
         match v with
         | EVar { name; _ } when not (Hashtbl.mem ctx.fn_names name) &&
                                  not (Hashtbl.mem stdlib_name_map name) ->
           if er_update_field_has_proof k then emit ctx (resolve_name name)
           else if ctx.func_kind <> None then emit ctx ("*" ^ name)
           else emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
         | _ ->
           if er_update_field_has_proof k then emit_expr_simple ctx v
           else emit_raw_value ctx v
       in
       emit ctx "(tesl-record-update ";
       emit_raw_value ctx base_expr;
       emit ctx " (hash ";
       List.iteri (fun i (k, v) ->
         if i > 0 then emit ctx " ";
         emit ctx (Printf.sprintf "'%s " k);
         emit_er_update_field_val k v
       ) other_fields;
       emit ctx "))"
     | None ->
       (match type_hint with
        | Some type_name ->
          (* Use constructor form: (TypeName #:field val ...) — matches Python *)
          let field_defs = match List.assoc_opt type_name ctx.record_fields with
            | Some defs -> defs
            | None -> []
          in
          emit ctx (Printf.sprintf "(%s" type_name);
          List.iter (fun (k, v) ->
            emit ctx (Printf.sprintf " #:%s " k);
            (* Propagate nested type hints for sub-record literals *)
            let v' = match v with
              | ERecord { fields = sub_fields; type_hint = None; loc } ->
                (match List.assoc_opt k field_defs with
                 | Some (TName { name = sub_type; _ }) ->
                   ERecord { fields = sub_fields; type_hint = Some sub_type; loc }
                 | _ -> v)
              | _ -> v
            in
            (* Named values in record constructor need * prefix,
               UNLESS the field carries a proof annotation — in that case
               we must pass the proof-bearing named-value through so the
               runtime's coerce-record-field-value can store it with proof. *)
            let field_has_proof =
              match List.find_opt (fun (n, _, _) -> n = type_name) ctx.record_meta with
              | Some (_, field_defs_meta, _) ->
                (match List.find_opt (fun (fd : Ast.field_def) -> fd.name = k) field_defs_meta with
                 | Some fd -> fd.proof_ann <> None
                 | None -> false)
              | None -> false
            in
            (match v' with
             | EVar { name; _ } when not field_has_proof &&
                                      not (Hashtbl.mem ctx.fn_names name) &&
                                      not (Hashtbl.mem qualified_imports name) &&
                                      not (Hashtbl.mem stdlib_name_map name) ->
               emit ctx ("*" ^ name)
             | EVar { name; _ } when field_has_proof &&
                                      not (Hashtbl.mem ctx.fn_names name) &&
                                      not (Hashtbl.mem qualified_imports name) &&
                                      not (Hashtbl.mem stdlib_name_map name) ->
               (* Proof-annotated field: pass the named-value with proof intact *)
               emit ctx name
             | _ -> emit_expr_simple ctx v')
          ) fields;
          emit ctx ")"
        | None ->
          (* Plain hash — used when type is unknown *)
          emit ctx "(hash ";
          List.iteri (fun i (k, v) ->
            if i > 0 then emit ctx " ";
            emit ctx (Printf.sprintf "'%s " k);
            (* Hash values: EVar named values need raw-value unwrapping *)
            (match v with
             | EVar { name; _ } when not (Hashtbl.mem ctx.fn_names name) &&
                                      not (Hashtbl.mem qualified_imports name) &&
                                      not (Hashtbl.mem stdlib_name_map name) ->
               if ctx.func_kind <> None then
                 emit ctx ("*" ^ name)
               else
                 emit ctx (Printf.sprintf "(raw-value %s)" name)
             | _ -> emit_expr_simple ctx v)
          ) fields;
          emit ctx ")"))
  | EList { elems = []; _ } ->
    emit ctx "(list)"
  | EList { elems; _ } ->
    emit ctx "(list ";
    List.iteri (fun i e ->
      if i > 0 then emit ctx " ";
      (* List elements: EVar named values need * prefix only in GDP function context.
         In test/top-level scope (func_kind = None) params are plain Racket let bindings. *)
      (match e with
       | EVar { name; _ } when ctx.func_kind <> None &&
                                not (Hashtbl.mem ctx.fn_names name) &&
                                not (Hashtbl.mem qualified_imports name) &&
                                not (Hashtbl.mem stdlib_name_map name) ->
         emit ctx ("*" ^ name)
       | _ -> emit_expr_simple ctx e)
    ) elems;
    emit ctx ")"
  | EOk { value; proof; _ } when
    (* In FnKind, if the proof name corresponds to a value already carrying that
       proof (bound via let/check), just emit the value directly — the proof is
       already part of the GDP wrapper.  This covers `let x = check f v; x :::
       proof` patterns where the value already has the proof attached.
       For separately-computed Fact variables (`yProof = validPort y`; then
       `y ::: yProof`), we fall through to the attach-proof path below. *)
    (match ctx.func_kind, proof with
     | Some FnKind, PredApp { pred = "detachFact"; args = [_]; _ } when is_typed_record_construction value ->
       (* detachFact as ghost witness on record — proof is a Fact extracted from a proof-carrying value.
          The proof is consumed by the record construction, not attached to the result. *)
       true
     | Some FnKind, PredApp { pred; args = []; _ } ->
       (* Only skip if the proof name is in proof_locals (bound via let/check),
          meaning the VALUE already carries this proof. *)
       String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' &&
       not (Hashtbl.mem qualified_imports pred) &&
       not (Hashtbl.mem stdlib_plain_imports pred) &&
       (* Skip attach-proof for:
          - ERecord or TypeName{} with ghost witness (record construction; proof is consumed, not carried)
          - EVar in proof_locals (already carries proof via let/check)
          - EVar whose name matches the pred (parameter carrying its own proof)
          Don't skip for EVar with a separately-computed Fact (y ::: yProof
          where y doesn't already carry yProof). *)
       (match value with
        | _ when is_typed_record_construction value -> true  (* ghost witness on record literal — skip attach-proof *)
        | EVar { name; _ } ->
          Hashtbl.mem ctx.proof_locals name || name = pred
        | _ -> false)
     | None, _ ->
       (* In test context, skip attach-proof for static predicate annotations
          (e.g. `raw ::: IsPositive n` where the proof is a static predicate).
          Emit attach-proof for runtime proof variables (e.g. `port443 ::: pf`
          where pf holds a runtime detached-proof from an establish call). *)
       let is_static_predicate_annotation =
         let rec is_static = function
           | PredApp { pred; args = []; _ } ->
             (* Uppercase = static predicate; lowercase not in proof_locals = runtime var *)
             String.length pred > 0 && pred.[0] >= 'A' && pred.[0] <= 'Z'
           | PredAnd { left; right; _ } -> is_static left && is_static right
           | _ -> false
         in
         is_static proof
       in
       is_static_predicate_annotation
     | _ -> false) ->
    (* Value already carries the proof — just emit the value *)
    emit_expr_simple ctx value
  | EOk { value; proof; _ } ->
    (match ctx.func_kind with
     | Some CheckKind | Some AuthKind ->
       (* For auth/named-pack context, emit just the predicate symbol (not (Pred arg)) *)
       (* For auth context, substitute the return-binding name for the ok-value
          name in the proof template so all references resolve to names that
          are in scope.  For single-arg proofs this turns (Pred returnName) into
          (Pred okValueName); for multi-arg it keeps all args. *)
       let emit_auth_resolved_proof proof value =
         let return_binding_name = ctx.auth_return_binding in
         let ok_value_name = match value with
           | EVar { name; _ } -> Some name
           | _ -> None
         in
         match return_binding_name, ok_value_name with
         | Some rb, Some okn when rb <> okn ->
           (* Substitute return-binding name with ok-value name in all proof args *)
           let rec subst_proof = function
             | PredApp { pred; args; loc } ->
               PredApp { pred; args = List.map (fun a -> if a = rb then okn else a) args; loc }
             | PredAnd { left; right; loc } ->
               PredAnd { left = subst_proof left; right = subst_proof right; loc }
           in
           emit_proof_expr ctx (subst_proof proof)
         | Some _rb, None ->
           (* ok-value is a complex expression (record constructor etc.), not a
              simple variable — the return-binding name in proof args would be
              unbound at runtime.  Strip all args, like the original emitter. *)
           let rec strip_args = function
             | PredApp { pred; loc; _ } -> PredApp { pred; args = []; loc }
             | PredAnd { left; right; loc } ->
               PredAnd { left = strip_args left; right = strip_args right; loc }
           in
           emit_proof_expr ctx (strip_args proof)
         | _ -> emit_proof_expr ctx proof
       in
       (* When the ok value is a constructor expression (not a simple variable),
          bind the return-binding name so it is in scope for the proof template.
          `ok (Ctor raw) ::: ValidId u` → (let ([u (Ctor *raw)]) (accept (ValidId u) #:value u)) *)
       (match ctx.func_kind, value with
        | Some CheckKind, EVar { name; _ } ->
          emit ctx "(accept ";
          emit_proof_expr ctx proof;
          emit ctx " #:value ";
          emit ctx ("*" ^ name);
          emit ctx ")"
        | Some CheckKind, _ ->
          (* ok (Ctor arg) ::: Proof u — emit accept/value directly.
             accept's body-bound-names only covers function params, so a local let
             binding would lose the newtype wrapper via (raw-value ...) in
             transform-body-expr.  Bypass the macro with accept/value. *)
          let rec emit_ctor_raw ctx e =
            match e with
            | EConstructor { name = cname; _ } -> emit ctx cname
            | EApp { fn; arg; _ } ->
              emit ctx "(";
              emit_ctor_raw ctx fn;
              emit ctx " ";
              emit_raw_value ctx arg;
              emit ctx ")"
            | _ -> emit_raw_value ctx e
          in
          (* Emit proof as a quoted datum: '(Pred subj1 subj2 ...) *)
          let rec proof_to_datum p =
            match p with
            | PredApp { pred; args; _ } ->
              if args = [] then Printf.sprintf "%s" pred
              else Printf.sprintf "%s %s" pred (String.concat " " args)
            | PredAnd { left; right; _ } ->
              Printf.sprintf "(%s) && (%s)" (proof_to_datum left) (proof_to_datum right)
          in
          emit ctx "(accept/value '(";
          emit ctx (proof_to_datum proof);
          emit ctx ") ";
          emit_ctor_raw ctx value;
          emit ctx ")"
        | _ ->
          emit ctx "(accept ";
          emit_auth_resolved_proof proof value;
          emit ctx " #:value ";
          (match direct_check_call value with
           | Some (check_fn, check_args) ->
             emit ctx "("; emit_expr ctx check_fn;
             List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) check_args;
             emit ctx ")"
           | None ->
             (match value with
              | EVar { name; _ } -> emit ctx ("*" ^ name)
              | _ -> emit_expr_simple ctx value));
          emit ctx ")")
     | _ ->
       emit ctx "(attach-proof ";
       (* If the value is a surface `check …` call, emit `(checkFn args)` WITHOUT the
          `check` wrapper (which has no runtime binding) so attach-proof carries the
          check-ok result's proof — mirrors the ELetProof handling above.  Without this
          the EOk path (reached for `ok (check …) ::: proof` tails since the always-on
          checkpoint change) emitted a literal unbound `check` head. *)
       (match direct_check_call value with
        | Some (check_fn, check_args) ->
          emit ctx "("; emit_expr ctx check_fn;
          List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) check_args;
          emit ctx ")"
        | None ->
          (match value with
           | EVar { name; _ } -> emit ctx (resolve_name name)
           | _ -> emit_expr_simple ctx value));
       emit ctx " ";
       emit_runtime_proof ctx proof;
       emit ctx ")")
  | EFail { status; message; _ } ->
    emit ctx "(reject ";
    emit_expr_simple ctx message;
    emit ctx (Printf.sprintf " #:http-code %d)" status)
  | ETelemetry { name; fields; _ } ->
    emit ctx (Printf.sprintf "(telemetry-event! %S #:attributes (" name);
    List.iteri (fun i (k, v) ->
      if i > 0 then emit ctx " ";
      emit ctx (Printf.sprintf "[%S " k);
      (* Telemetry values need * prefix for named values *)
      (match v with
       | EVar { name; _ } -> emit ctx ("*" ^ name)
       | _ -> emit_expr_simple ctx v);
      emit ctx "]"
    ) fields;
    emit ctx "))"
  | EEnqueue _ | EStartWorkers _ | EServe _ ->
    (* These fixed-shape effect forms are lowered to [ERuntimeCall] by
       {!Desugar.desugar_module}, which [compile_to_string] runs before
       [emit_module].  Reaching emit means the module was not desugared — a
       pipeline bug — so fail loudly rather than emit malformed Racket. *)
    failwith "emit_racket: EEnqueue/EStartWorkers/EServe reached the emitter \
              un-desugared (Desugar.desugar_module must run before emit_module)"
  | EPublish { channel_name; key; event_ctor; payload; _ } ->
    emit ctx (Printf.sprintf "(publish-event! %s " channel_name);
    (match key with
     | Some key_expr ->
       emit ctx "(format \"~a\" ";
       (match key_expr with
        | EVar { name; _ } ->
          if ctx.func_kind <> None then emit ctx ("*" ^ resolve_name name)
          else emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
        | _ -> emit_expr ctx key_expr);
       emit ctx ")"
     | None -> emit ctx "\"\"");
    emit ctx " ";
    (match payload with
     | Some (ERecord { fields; _ }) ->
       emit ctx (Printf.sprintf "(%s" event_ctor);
       List.iter (fun (_, v) -> emit ctx " "; emit_expr_simple ctx v) fields;
       emit ctx ")"
     | Some payload_expr -> emit_expr_simple ctx payload_expr
     | None -> emit ctx (Printf.sprintf "(%s)" event_ctor));
    emit ctx ")"
  | EWithDatabase { database_name; body; _ } ->
    emit ctx (Printf.sprintf "(call-with-database %s (lambda () " database_name);
    emit_expr ctx body;
    emit ctx "))"
  | EWithCapabilities { capabilities; body; _ } ->
    emit ctx "(with-capabilities (";
    emit ctx (cap_list_str capabilities);
    emit ctx ") ";
    emit_expr ctx body;
    emit ctx ")"
  | EWithTransaction { body; _ } ->
    emit ctx "(call-with-queue-transaction (lambda () ";
    emit_expr ctx body;
    emit ctx "))"
  | ECacheGet { cache_name; key; _ } ->
    emit ctx (Printf.sprintf "(cache-get! %s " cache_name);
    emit_expr_simple ctx key;
    emit ctx ")"
  | ECacheSet { cache_name; key; value; ttl; _ } ->
    emit ctx (Printf.sprintf "(cache-set! %s " cache_name);
    emit_expr_simple ctx key;
    emit ctx " ";
    emit_expr_simple ctx value;
    (match ttl with
     | Some ttl_expr -> emit ctx " "; emit_expr_simple ctx ttl_expr
     | None -> ());
    emit ctx ")"
  | ECacheDelete { cache_name; key; _ } ->
    emit ctx (Printf.sprintf "(cache-delete! %s " cache_name);
    emit_expr_simple ctx key;
    emit ctx ")"
  | ECacheInvalidate { cache_name; prefix; _ } ->
    emit ctx (Printf.sprintf "(cache-invalidate-prefix! %s " cache_name);
    emit_expr_simple ctx prefix;
    emit ctx ")"
  | ESendEmail { email_name; to_; subject; body; _ } ->
    emit ctx (Printf.sprintf "(send-email! %s #:to " email_name);
    emit_expr_simple ctx to_;
    emit ctx " #:subject ";
    emit_expr_simple ctx subject;
    emit ctx " #:body ";
    emit_expr_simple ctx body;
    emit ctx ")"
  | EStartEmailWorker { email_name; _ } ->
    emit ctx (Printf.sprintf "(start-email-worker! %s)" email_name)
  | ERuntimeCall { segments; _ } ->
    (* Desugar-lowered fixed-shape runtime call (EEnqueue / EStartWorkers /
       EServe).  Literal segments are emitted verbatim (the call prefix, keyword
       args and runtime fn names were rendered at desugar time); argument
       sub-expressions are emitted through the context-aware emit_expr_simple
       path, exactly as the original effect arms did. *)
    List.iter (function
      | RLit s -> emit ctx s
      | RArg e -> emit_expr_simple ctx e) segments
  | EConstructor { name = "Nothing"; args = []; _ } ->
    emit ctx "Nothing"
  | EConstructor { name = "True"; args = []; _ } ->
    emit ctx "#t"
  | EConstructor { name = "False"; args = []; _ } ->
    emit ctx "#f"
  | EConstructor { name = "Something"; args = [a]; _ } ->
    (* When the function declares a proof-carrying Maybe return (RetMaybeAttached),
       preserve the inner value's named-value wrapper so its proof survives
       through the Something constructor and is verifiable at runtime. *)
    let preserve_proof = match ctx.func_return_spec with
      | Some (RetMaybeAttached { binding = b; _ }) when b.proof_ann <> None -> true
      | _ -> false
    in
    if preserve_proof then begin
      (* Preserve the named-value wrapper so proof survives through Something.
         Do NOT use emit_ctor_arg (which strips proof with *name for raw_locals).
         Instead emit the plain variable name so Racket sees the named-value. *)
      emit ctx "(raw-value (Something ";
      (match a with
       | EVar { name; _ } ->
         (* proof_locals: already named-value. raw_locals/params: force named-value. *)
         emit ctx (resolve_name name)
       | _ -> emit_expr ctx a);
      emit ctx "))"
    end else begin
      emit ctx "(raw-value (Something ";
      emit_ctor_arg a;
      emit ctx "))"
    end
  | EConstructor { name; args = []; _ } ->
    emit ctx name
  | EConstructor { name; args; _ } ->
    (* Constructor with args: wrap in raw-value per Python convention.
       When the enclosing function returns a proof-carrying generic wrapper
       (outer_ty = Some), preserve inner variable proofs via resolve_name. *)
    let preserve_inner_proofs = match ctx.func_return_spec with
      | Some (RetMaybeAttached { outer_ty = Some _; binding = b; _ }) when b.proof_ann <> None -> true
      | _ -> false
    in
    emit ctx (Printf.sprintf "(raw-value (%s" name);
    List.iter (fun a ->
      emit ctx " ";
      if preserve_inner_proofs then
        (match a with
         | EVar { name = vname; _ } -> emit ctx (resolve_name vname)
         | _ -> emit_expr ctx a)
      else
        emit_ctor_arg a) args;
    emit ctx "))"
  | ELambda { params; body; _ } ->
    (* Anonymous lambda: emit as a local define/pow inside let so GDP wrapping works.
       Proof annotations on params (fn(n: T ::: Proof n) -> ...) are NOT emitted in
       the define/pow signature (which would require proof at call time — but ForAll
       list elements are plain values at runtime).  Instead, we wrap the body in a
       let-binding that creates a named-value carrying the declared proof, so that
       inner functions requiring the proof (e.g., doubleOne n ::: IsPositive n) can
       satisfy it.  This implements ForAll-proof propagation through List.map. *)
    let tmp_name = Printf.sprintf "tesl-lambda-%d" ctx.case_counter in
    ctx.case_counter <- ctx.case_counter + 1;
    emit ctx (Printf.sprintf "(let () (define/pow (%s" tmp_name);
    List.iter (fun (b : Ast.binding) ->
      emit ctx " ["; emit ctx b.name; emit ctx " : ";
      emit_type_name ctx b.type_expr; emit ctx "]"
    ) params;
    let body_type_name =
      let body_loc = Checker.expr_loc body in
      match Hashtbl.find_opt ctx.expr_type_tbl (body_loc.Location.start.line, body_loc.Location.start.col) with
      | Some display_ty -> display_ty_to_racket_type display_ty
      | None -> "Any"
    in
    emit ctx (Printf.sprintf ") #:returns %s " body_type_name);
    (* For each proof-annotated param, wrap the body in a let that establishes the
       proof on the GDP name so inner calls can satisfy their proof requirements. *)
    let proof_params = List.filter (fun (b : Ast.binding) ->
      match b.proof_ann with
      | None | Some (PredApp { pred = "ForAll"; _ }) -> false
      | Some _ -> true
    ) params in
    List.iter (fun (b : Ast.binding) ->
      match b.proof_ann with
      | Some p ->
        (* (let ([n (tesl-establish-param-proof n *n `(Proof ,n))]) body) *)
        emit ctx (Printf.sprintf "(let ([%s (tesl-establish-param-proof %s *%s `(" b.name b.name b.name);
        (* Emit proof with args as unquoted vars: (IsPositive ,n) becomes `(IsPositive ,n) *)
        (match p with
         | PredApp { pred; args = []; _ } -> emit ctx pred
         | PredApp { pred; args; _ } ->
           emit ctx pred;
           List.iter (fun arg -> emit ctx " ,"; emit ctx arg) args
         | _ -> emit_proof_expr ctx p);
        emit ctx (Printf.sprintf "))]) " )
      | _ -> ()
    ) proof_params;
    (* Lambda body lives inside define/pow, so parameters use GDP *name style.
       Temporarily set func_kind = FnKind and register lambda params so that
       string interpolation (${x}) and other func_kind-sensitive emission use
       the correct *name accessor regardless of the outer context. *)
    let saved_func_kind = ctx.func_kind in
    let saved_return_spec = ctx.func_return_spec in
    let saved_param_names = Hashtbl.copy ctx.param_names in
    ctx.func_kind <- Some FnKind;
    ctx.func_return_spec <- None;
    (* Add lambda params on top of outer params (not clear+replace) so that
       captured outer-function variables like `n` in `makeAdder(n) = fn(x) -> x + n`
       remain accessible as *n inside the lambda body.
       Also register params without proof annotations in plain_param_names so that
       emit_stdlib_arg uses *name (raw) for them, consistent with regular functions. *)
    List.iter (fun (b : Ast.binding) ->
      Hashtbl.replace ctx.param_names b.name ();
      if is_comptime_only_proof b.proof_ann then
        Hashtbl.replace ctx.plain_param_names b.name ()
    ) params;
    emit_expr ctx body;
    ctx.func_kind <- saved_func_kind;
    ctx.func_return_spec <- saved_return_spec;
    Hashtbl.clear ctx.param_names;
    Hashtbl.iter (Hashtbl.replace ctx.param_names) saved_param_names;
    List.iter (fun _ -> emit ctx ")") proof_params;
    emit ctx (Printf.sprintf ") %s)" tmp_name)

(** Emit an expression for use as the object in field-access-ref.
    For a nested field access (EField), emit as another field-access-ref (no outer raw-value).
    For variables, emit the name directly (they're GDP named values). *)
and emit_field_inner ctx e =
  match e with
  | EVar { name; _ } -> emit ctx (resolve_name name)
  | EField { obj; field; _ } ->
    (match obj with
     | EConstructor { name = modname; args = []; _ } ->
       let full = modname ^ "." ^ field in
       (match Hashtbl.find_opt qualified_imports full with
        | Some renamed -> emit ctx renamed
        | None -> emit ctx (import_rename full))
     | EVar _ when
         field = "value" || field = "cookies" || field = "headers" || field = "body" ->
       (* Dot-notation fields on simple variables *)
       emit_field_inner ctx obj;
       emit ctx (Printf.sprintf ".%s" field)
     | _ ->
       (* Nested field access: use tesl-dot/runtime to handle gensym symbols.
          This correctly resolves GDP-tracked variables (e.g. task.meta in FnKind). *)
       emit ctx "(tesl-dot/runtime ";
       emit_field_inner ctx obj;
       emit ctx (Printf.sprintf " '%s)" field))
  | _ -> emit_expr ctx e  (* complex expr — pass as-is (GDP named value) *)

(** Emit an expression in "bare" position — used for the object in obj.field.
    For named values (EVar), emit the name directly (no raw-value wrapper). *)
and emit_expr_bare ctx e =
  (* Emit expression for use as the object in obj.field patterns.
     Uses emit_field_inner for nested fields. *)
  emit_field_inner ctx e

and emit_expr_simple ctx e =
  (* Emit an expression in argument position.
     Constructor applications are NOT wrapped in raw-value here — they
     become named-values via define/pow's parameter handling. *)
  match e with
  (* These expressions emit with their own outer parens or are bare tokens — no extra wrapping needed *)
  | ELit _ | EVar _ | EConstructor { args = []; _ } | EField _ -> emit_expr ctx e
  | ELambda _ | EList _ | EBinop _ | EUnop _ | EIf _ | ECase _
  | ELet _ | ELetProof _ | ERecord _ | EOk _ | EFail _ | ETelemetry _
  | EEnqueue _ | EPublish _ | EStartWorkers _ | EWithDatabase _
  | EWithCapabilities _ | EWithTransaction _ | EServe _ | EConstructor _
  | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
  | ESendEmail _ | EStartEmailWorker _ | ERuntimeCall _ -> emit_expr ctx e
  | EApp _ as app ->
    (* SQL-like expressions and TypeName { } record construction need the full emit_expr lowering. *)
    let is_typename_record = match app with
      | EApp { fn = EConstructor { args = []; _ }; arg = ERecord _; _ } -> true
      | _ -> false
    in
    if is_typename_record
       || (match extract_select_query app with Some _ -> true | None -> false)
       || (match parse_insert_expr app with Some _ -> true | None -> false)
       || (match parse_insert_many_expr app with Some _ -> true | None -> false)
       || (match extract_delete_query app with Some _ -> true | None -> false) then
      emit_expr ctx app
    else
      (* For constructor apps in argument position, don't wrap in raw-value.
         But stdlib calls and zero-arg calls delegate to emit_expr for proper handling. *)
      let rec collect_args acc e = match e with
        | EApp { fn; arg; _ } -> collect_args (arg :: acc) fn
        | _ -> (e, acc)
      in
      let (fn, args) = collect_args [] app in
      let is_unit_arg = match args with [EList { elems = []; _ }] -> true | _ -> false in
      let is_ctor = match fn with
        | EConstructor _ -> true
        | EVar { name; _ } -> String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z'
        | _ -> false
      in
      if (is_unit_arg || is_stdlib_fn fn) && not is_ctor then
        (* Delegate to emit_expr for stdlib/zero-arg — it handles raw-value properly *)
        emit_expr ctx app
      else begin
        (* Constructor as arg: (Circle 5) without raw-value *)
        emit ctx "(";
        emit_expr ctx fn;
        List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) args;
        emit ctx ")"
      end

and emit_lit ctx = function
  | LInt n -> emit ctx (string_of_int n)
  | LFloat f -> emit ctx (string_of_float f)
  | LBool true -> emit ctx "#t"
  | LBool false -> emit ctx "#f"
  | LString s ->
    (* Use Racket string literal with Unicode escaping *)
    emit ctx "\"";
    emit ctx (racket_escape_string s);
    emit ctx "\""
  | LInterp segs -> emit_interp ctx segs

and emit_interp ctx segs =
  (* String interpolation: "Hello, ${name}!" → (format "Hello, ~a!" (raw-value name)) *)
  let has_exprs = List.exists (function IExpr _ -> true | _ -> false) segs in
  if not has_exprs then begin
    (* Plain string, no interpolation needed *)
    let s = String.concat "" (List.filter_map (function
      | ILiteral s -> Some s | IExpr _ -> None) segs) in
    emit ctx "\""; emit ctx (racket_escape_string s); emit ctx "\""
  end else begin
    emit ctx "(format \"";
    List.iter (function
      | ILiteral s ->
        (* Escape the literal part for format — tilde must be doubled, use Unicode escape *)
        let escaped = racket_escape_string s in
        (* Also double any tildes in the escaped string (format spec) *)
        let double_tilde = String.concat "~~" (String.split_on_char '~' escaped) in
        emit ctx double_tilde
      | IExpr _ -> emit ctx "~a"
    ) segs;
    emit ctx "\"";
    List.iter (function
      | ILiteral _ -> ()
      | IExpr e ->
        emit ctx " ";
        (match e with
         | EVar { name; _ } ->
           (* In function contexts parameters compile to raw backing names; elsewhere unwrap named values explicitly. *)
           if ctx.func_kind <> None then
             emit ctx (Printf.sprintf "(tesl-display-val *%s)" name)
           else
             emit ctx (Printf.sprintf "(tesl-display-val %s)" (resolve_name name))
         | EField { obj = EVar { name; _ }; field; _ } when ctx.func_kind <> None ->
           (* name.field in function context: dot notation *)
           emit ctx (Printf.sprintf "(tesl-display-val (raw-value %s.%s))" name field)
         | _ ->
           emit ctx "(tesl-display-val ";
           emit_expr ctx e;
           emit ctx ")")
    ) segs;
    emit ctx ")"
  end

and emit_binop ctx op left right =
  let op_str = match op with
    | BAdd -> "+" | BSub -> "-" | BMul -> "*" | BDiv -> "quotient" | BMod -> "remainder"
    | BConcat -> "string-append"  (* handled specially below — needs emit_val_arg *)
    | BAnd -> "and" | BOr -> "or" | BEq -> "equal?" | BNeq -> "not equal?"
    | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">="
  in
  (* For comparison/arithmetic, bare EVar needs raw-value unwrapping,
     and GDP-returning stdlib calls also need raw-value in this context *)
  let get_stdlib_fn_name e =
    let rec get_head = function EApp { fn; _ } -> get_head fn | e -> e in
    match get_head e with
    | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
      let full = modname ^ "." ^ field in
      (match Hashtbl.find_opt qualified_imports full with
       | Some r -> r | None -> import_rename full)
    | _ -> ""
  in
  let rec app_head_name = function
    | EApp { fn; _ } -> app_head_name fn
    | EVar { name; _ } -> Some name
    | EField { obj = EConstructor { name = modname; _ }; field; _ } -> Some (modname ^ "." ^ field)
    | EField { obj = EVar { name = modname; _ }; field; _ } -> Some (modname ^ "." ^ field)
    | _ -> None
  in
  let emit_val_arg e = match e with
    | EVar { name; _ } ->
      if ctx.func_kind <> None then begin
        if Hashtbl.mem ctx.param_names (resolve_name name) || Hashtbl.mem ctx.raw_locals (resolve_name name) then
          emit ctx ("*" ^ resolve_name name)
        else
          emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
      end else
        emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
    | EApp _ ->
      let needs_raw = match app_head_name e with
        | Some fn_name ->
          Hashtbl.mem gdp_returning_stdlib (get_stdlib_fn_name e)
          || Hashtbl.mem ctx.fn_names fn_name
        | None -> false
      in
      if needs_raw then begin
        emit ctx "(raw-value ";
        emit_expr ctx e;
        emit ctx ")"
      end else
        emit_expr ctx e
    | _ -> emit_expr ctx e
  in
  (match op with
   | BConcat ->
     (* String concatenation: unwrap GDP named values via emit_val_arg so
        Racket's string-append receives plain strings. *)
     emit ctx "(string-append ";
     emit_val_arg left; emit ctx " "; emit_val_arg right;
     emit ctx ")"
   | BNeq ->
     emit ctx "(not (equal? ";
     emit_val_arg left; emit ctx " "; emit_val_arg right;
     emit ctx "))"
   | BEq ->
     emit ctx "(equal? ";
     emit_val_arg left; emit ctx " "; emit_val_arg right;
     emit ctx ")"
   | BAnd ->
     (* Use check-and when both operands are function references (check functions) *)
     let is_fn_ref e = match e with
       | EVar { name; _ } -> Hashtbl.mem ctx.fn_names name
       | EBinop { op = BAnd; _ } -> true  (* nested check-and *)
       | _ -> false
     in
     let use_check_and = is_fn_ref left && is_fn_ref right in
     (* Use intro-and when all leaf operands are known Fact locals (detachFact/establish results). *)
     let rec all_fact_leaves e = match e with
       | EVar { name; _ } -> Hashtbl.mem ctx.fact_locals name
       | EBinop { op = BAnd; left; right; _ } -> all_fact_leaves left && all_fact_leaves right
       | _ -> false
     in
     let use_intro_and = not use_check_and && all_fact_leaves left && all_fact_leaves right in
     let rec collect_and_args = function
       | EBinop { op = BAnd; left; right; _ } ->
         collect_and_args left @ collect_and_args right
       | e -> [e]
     in
     if use_check_and then begin
       emit ctx "(check-and ";
       emit_expr ctx left; emit ctx " "; emit_expr ctx right;
       emit ctx ")"
     end else if use_intro_and then begin
       (* Proof value conjunction: (intro-and fact1 fact2 ...) *)
       let args = collect_and_args left @ collect_and_args right in
       emit ctx "(intro-and ";
       List.iteri (fun i a -> if i > 0 then emit ctx " "; emit_expr ctx a) args;
       emit ctx ")"
     end else begin
       (* Boolean conjunction: (and *a *b *c) *)
       let args = collect_and_args left @ collect_and_args right in
       emit ctx "(and ";
       List.iteri (fun i a -> if i > 0 then emit ctx " "; emit_val_arg a) args;
       emit ctx ")"
     end
   | BOr ->
     (* Boolean disjunction: (or *a *b) *)
     emit ctx "(or ";
     emit_val_arg left; emit ctx " "; emit_val_arg right;
     emit ctx ")"
   | _ ->
     emit ctx (Printf.sprintf "(%s " op_str);
     emit_val_arg left; emit ctx " "; emit_val_arg right;
     emit ctx ")")

and emit_raw_value ctx e =
  (* Emit raw-value for case scrutinees — match Python's *name style *)
  match e with
  | EVar { name; _ } ->
    if ctx.func_kind <> None && Hashtbl.mem ctx.param_names (resolve_name name) then
      emit ctx ("*" ^ (resolve_name name))
    else
      emit ctx (Printf.sprintf "(raw-value %s)" (resolve_name name))
  | EField { obj; field; _ } ->
    (match obj with
     | EConstructor { name = modname; args = []; _ } ->
       let full = modname ^ "." ^ field in
       let renamed = match Hashtbl.find_opt qualified_imports full with
         | Some r -> r | None -> import_rename full
       in
       emit ctx renamed
     | _ ->
       (* Use tesl-dot/runtime so gensym params are resolved via evidence-env.
          This mirrors emit_expr's field access strategy. *)
       emit ctx "(tesl-dot/runtime ";
       emit_field_inner ctx obj;
       emit ctx (Printf.sprintf " '%s)" field))
  | EApp _ when (
      let rec fn_of = function EApp { fn; _ } -> fn_of fn | e -> e in
      is_stdlib_fn (fn_of e)) ->
    (* For stdlib calls:
       - If GDP-returning (no raw-value in emit_expr): add raw-value here
       - Otherwise: emit_expr already produces (raw-value ...), don't double-wrap *)
    let rec fn_of = function EApp { fn; _ } -> fn_of fn | e -> e in
    let fn_racket_name = match fn_of e with
      | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
        let full = modname ^ "." ^ field in
        (match Hashtbl.find_opt qualified_imports full with
         | Some r -> r | None -> import_rename full)
      | _ -> ""
    in
    if Hashtbl.mem gdp_returning_stdlib fn_racket_name then begin
      (* GDP-returning: emit_expr gives (fn args), so we need (raw-value (fn args)) *)
      emit ctx "(raw-value "; emit_expr ctx e; emit ctx ")"
    end else
      (* Regular stdlib: emit_expr gives (raw-value (fn args)), use as-is *)
      emit_expr ctx e
  | _ ->
    emit ctx "(raw-value ";
    emit_expr ctx e;
    emit ctx ")"

and emit_proof_expr ctx p =
  match p with
  | PredApp { pred; args = []; _ } -> emit ctx pred
  | PredApp { pred; args; _ } ->
    emit ctx (Printf.sprintf "(%s %s)" pred (String.concat " " args))
  | PredAnd { left; right; _ } ->
    (* Compound proofs use && format matching Python emitter *)
    emit ctx "(";
    emit_proof_expr ctx left;
    emit ctx " && ";
    emit_proof_expr ctx right;
    emit ctx ")"

and emit_runtime_proof ctx p =
  match p with
  | PredApp { pred = "detachFact"; args = [arg]; _ } ->
    emit ctx "(detach-all-proof ";
    emit ctx arg;
    emit ctx ")"
  | PredApp { pred; args = []; _ }
    when String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' &&
         not (Hashtbl.mem qualified_imports pred) &&
         not (Hashtbl.mem stdlib_plain_imports pred) ->
    emit ctx pred
  | PredAnd { left; right; _ } ->
    emit ctx "(list ";
    emit_runtime_proof ctx left;
    emit ctx " ";
    emit_runtime_proof ctx right;
    emit ctx ")"
  | _ -> emit_proof_expr ctx p

and expand_entity_proof_group p =
  match p with
  | PredApp ({ args; _ } as app) -> PredApp { app with args = args @ ["_entity"] }
  | PredAnd ({ left; right; _ } as conj) ->
    PredAnd {
      conj with
      left = expand_entity_proof_group left;
      right = expand_entity_proof_group right;
    }

and emit_named_pack_spec ctx ty entity_proof other_proof =
  let is_forall_proof = match entity_proof with
    | Some (PredApp { pred = "ForAll"; _ }) -> true
    | _ -> false
  in
  if is_forall_proof then
    emit_type_name ctx ty
  else begin
    emit ctx "(? ";
    emit_type_name ctx ty;
    emit ctx " _entity";
    (match entity_proof, other_proof with
     | None, None -> ()
     | Some entity, None ->
       emit ctx " ::: ";
       emit_proof_expr ctx (expand_entity_proof_group entity)
     | None, Some other ->
       emit ctx " ::: ";
       emit_proof_expr ctx other
     | Some entity, Some other ->
       emit ctx " ::: (";
       emit_proof_expr ctx (expand_entity_proof_group entity);
       emit ctx " && ";
       emit_proof_expr ctx other;
       emit ctx ")");
    emit ctx ")"
  end

and emit_case_arm ctx scrut_var arm =
  let rec collect_bound_names = function
    | PVar n -> if n = "_" then [] else [n]
    | PWild | PLit _ | PNullary _ -> []
    | PCon { fields; _ } -> List.concat_map (fun (_, sub) -> collect_bound_names sub) fields
  in
  let raw_bound_names = match arm.pattern with
    | PVar n -> if n = "_" then [] else [n]
    | PCon { fields; _ } when not ctx.preserve_case_payload_names ->
      List.concat_map (fun (_, sub_pat) -> collect_bound_names sub_pat) fields
    | _ -> []
  in
  List.iter (fun name -> Hashtbl.replace ctx.raw_locals name ()) raw_bound_names;
  emit ctx "[";
  let pattern_guard, binding_code = pattern_to_racket ctx arm.pattern scrut_var in
  (* Incorporate `where` guard into the cond condition.
     Use nested single-binding let forms - the let-star branch in the DSL
     runtime macro has a temp-id hygiene issue with multiple bindings. *)
  let nested_let_str bindings body_str =
    List.fold_right
      (fun b acc -> Printf.sprintf "(let (%s) %s)" b acc)
      bindings body_str
  in
  let full_guard = match arm.guard with
    | None -> pattern_guard
    | Some guard_expr ->
      let guard_buf = Buffer.create 64 in
      let guard_ctx = { ctx with buf = guard_buf } in
      emit_expr guard_ctx guard_expr;
      let guard_racket = Buffer.contents guard_buf in
      if binding_code = [] then
        Printf.sprintf "(and %s %s)" pattern_guard guard_racket
      else
        Printf.sprintf "(and %s %s)" pattern_guard
          (nested_let_str binding_code guard_racket)
  in
  emit ctx full_guard;
  emit ctx " ";
  let has_guard_with_bindings = arm.guard <> None && binding_code <> [] in
  (* Wrap the arm BODY in its own checkpoint (at the arm's source line) so a step
     lands on the arm the code actually takes — the macro erases in release, and
     only the chosen arm's body runs, so exactly one fires. Empty locals keeps it
     decoupled from the arm's raw/proof binding scheme (no `*name` references). *)
  let emit_arm_body () =
    let bloc = Checker.expr_loc arm.body in
    (* Surface the pattern-bound variables (e.g. `todo` in `Something todo`) in the
       arm checkpoint's Locals. They are bound by binding_code, which wraps this
       checkpoint, so referencing each by its bound name is in scope. *)
    let arm_vars = collect_bound_names arm.pattern in
    emit ctx (Printf.sprintf "(thsl-src! %S %d "
      bloc.Location.file (bloc.Location.start.line + 1));
    (if arm_vars = [] then emit ctx "(list)"
     else begin
       emit ctx "(list";
       List.iter (fun n -> emit ctx (Printf.sprintf " (cons '%s %s)" n n)) arm_vars;
       emit ctx ")"
     end);
    emit ctx " (lambda () ";
    emit_expr ctx arm.body;
    emit ctx "))"
  in
  (match binding_code with
   | [] -> emit_arm_body ()
   | _ ->
     (* Nested single-binding lets ensure sequential deps work (e.g. nested patterns).
        Guard and body both use the same bindings when has_guard_with_bindings. *)
     ignore has_guard_with_bindings;
     List.iter (fun b -> emit ctx (Printf.sprintf "(let (%s) " b)) binding_code;
     emit_arm_body ();
     List.iter (fun _ -> emit ctx ")") binding_code);
  emit ctx "]";
  List.iter (fun name -> Hashtbl.remove ctx.raw_locals name) raw_bound_names

and pattern_to_racket ctx pat scrut_var =
  match pat with
  | PWild ->
    ("#t", [])
  | PVar n ->
    (* Bind the whole scrutinee — star_ref handles both plain and already-starred vars. *)
    let binding = Printf.sprintf "[%s %s]" n (star_ref scrut_var) in
    ("#t", [binding])
  | PLit { value; _ } ->
    let guard = match value with
      | LString s -> Printf.sprintf "(equal? %s \"%s\")" (star_ref scrut_var) (String.escaped s)
      | LInt n    -> Printf.sprintf "(= %s %d)" (star_ref scrut_var) n
      | LBool b   -> Printf.sprintf "(eq? %s %b)" (star_ref scrut_var) b
      | _         -> "#t"
    in
    (guard, [])
  | PNullary { ctor = "True"; _ } ->
    let r = star_ref scrut_var in
    (Printf.sprintf "(eq? %s #t)" r, [])
  | PNullary { ctor = "False"; _ } ->
    let r = star_ref scrut_var in
    (Printf.sprintf "(eq? %s #f)" r, [])
  | PNullary { ctor; _ } ->
    let r = star_ref scrut_var in
    let guard =
      Printf.sprintf "(and (adt-value? %s) (eq? (adt-value-variant %s) '%s))"
        r r ctor
    in
    (guard, [])
  | PCon { ctor; fields; _ } ->
    let r = star_ref scrut_var in
    let ctor_guard =
      Printf.sprintf "(and (adt-value? %s) (eq? (adt-value-variant %s) '%s))"
        r r ctor
    in
    (* Look up actual ADT field labels to correctly resolve positional fields.
       E.g. `Circle radius` for `Circle radius:Int` → label = 'radius
            `Opened count` for `Opened Int` (positional) → label = 'value *)
    let adt_labels = Hashtbl.find_opt ctx.ctor_fields ctor in
    (* For each field, generate guards and bindings, handling nested patterns. *)
    let extra_guards = ref [] in
    let all_bindings = ref [] in
    List.iteri (fun i (label, sub_pat) ->
      let actual_label = match adt_labels with
        | Some labels when i < List.length labels -> List.nth labels i
        | _ -> label
      in
      if actual_label = "_" then ()
      else
        let field_expr = Printf.sprintf "(hash-ref (adt-value-fields %s) '%s)" r actual_label in
        match sub_pat with
        | PWild -> ()
        | PVar var_name when var_name <> "_" ->
          all_bindings := (Printf.sprintf "[%s %s]" var_name field_expr) :: !all_bindings
        | PVar _ -> ()
        | _ ->
          (* Nested pattern: extract field into temp var for sub-pattern matching.
             When scrut_var already starts with star (test-block context), the temp var
             inherits the star prefix so it is directly bound to the raw value.
             When scrut_var is plain (fn-body), define/pow creates star-temp_var
             automatically, so no prefix is added here. star_ref() normalises both. *)
          let temp_var_base =
            let base = if scrut_var.[0] = '*' then String.sub scrut_var 1 (String.length scrut_var - 1)
                       else scrut_var in
            Printf.sprintf "%s_f%d" base i
          in
          let temp_var = if scrut_var.[0] = '*' then "*" ^ temp_var_base else temp_var_base in
          let raw_field_expr = Printf.sprintf "(raw-value %s)" field_expr in
          let temp_binding = Printf.sprintf "[%s %s]" temp_var raw_field_expr in
          all_bindings := temp_binding :: !all_bindings;
          let (sub_guard, sub_bindings) = pattern_to_racket ctx sub_pat temp_var in
          if sub_guard <> "#t" then
            extra_guards := (Printf.sprintf "(let ([%s %s]) %s)" temp_var raw_field_expr sub_guard) :: !extra_guards;
          all_bindings := List.rev_append sub_bindings !all_bindings
    ) fields;
    let all_guards = ctor_guard :: List.rev !extra_guards in
    let guard = match all_guards with
      | [g] -> g
      | gs -> Printf.sprintf "(and %s)" (String.concat " " gs)
    in
    (guard, List.rev !all_bindings)

(* ── Binding parameter emission ─────────────────────────────────────────── *)

let emit_binding_param ctx (b : Ast.binding) =
  emit ctx "[";
  emit ctx b.name;
  emit ctx " : ";
  emit_type_name ctx b.type_expr;
  (match b.proof_ann with
   | None -> ()
   | Some (PredApp { pred = "ForAll"; _ }) ->
     (* ForAll proof annotations in params are not emitted (they're set-type annotations) *)
     ()
   | Some p ->
     emit ctx " ::: ";
     emit_proof_expr ctx p);
  emit ctx "]"

let emit_params ctx params =
  List.iter (fun b ->
    emit ctx " ";
    emit_binding_param ctx b
  ) params

(* ── Return spec emission ────────────────────────────────────────────────── *)

let rec emit_return_spec ctx spec =
  match spec with
  | RetPlain { ty; _ } ->
    emit ctx "#:returns ";
    emit_type_name ctx ty
  | RetAttached { binding = b; _ } ->
    emit ctx (Printf.sprintf "#:returns [%s : " b.name);
    emit_type_name ctx b.type_expr;
    (match b.proof_ann with
     | None -> ()
     | Some p ->
       emit ctx " ::: ";
       emit_proof_expr ctx p);
    emit ctx "]"
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    emit ctx "#:returns ";
    emit_named_pack_spec ctx ty entity_proof other_proof
  | RetForAll { elem_ty; _ } ->
    (* ForAll is compile-time only; runtime contract is the plain collection type. *)
    emit ctx "#:returns (List ";
    emit_type_name ctx elem_ty;
    emit ctx ")"
  | RetMaybeForAll { elem_ty; _ } ->
    emit ctx "#:returns (Maybe (List ";
    emit_type_name ctx elem_ty;
    emit ctx "))"
  | RetMaybeAttached { outer_ty = Some oty; _ } ->
    emit ctx "#:returns ";
    emit_type_name ctx oty
  | RetMaybeAttached { binding = b; _ } ->
    (* Proof is compile-time only; emit as Maybe T *)
    emit ctx "#:returns (Maybe ";
    emit_type_name ctx b.type_expr;
    emit ctx ")"
  | RetSetForAll { elem_ty; _ } ->
    (* Set ForAll is also compile-time only. *)
    emit ctx "#:returns (Set ";
    emit_type_name ctx elem_ty;
    emit ctx ")"
  | RetMaybeSetForAll { elem_ty; _ } ->
    emit ctx "#:returns (Maybe (Set ";
    emit_type_name ctx elem_ty;
    emit ctx "))"
  | RetForAllDictValues { key_ty; val_ty; _ }
  | RetForAllDictKeys   { key_ty; val_ty; _ } ->
    emit ctx "#:returns (Dict ";
    emit_type_name ctx key_ty;
    emit ctx " ";
    emit_type_name ctx val_ty;
    emit ctx ")"
  | RetExists { binding = b; body; _ } ->
    (* Emit: #:returns (Exists [name : Type] body_spec) *)
    emit ctx "#:returns (Exists [";
    emit ctx b.name;
    emit ctx " : ";
    emit_type_name ctx b.type_expr;
    emit ctx "] ";
    (* Emit the body spec — strip #:returns prefix and use just the type/binding part *)
    (match body with
     | RetPlain { ty; _ } -> emit_type_name ctx ty
     | RetAttached { binding = rb; _ } ->
       emit ctx "[";
       emit ctx rb.name;
       emit ctx " : ";
       emit_type_name ctx rb.type_expr;
       (match rb.proof_ann with
        | Some p -> emit ctx " ::: "; emit_proof_expr ctx p
        | None -> ());
       emit ctx "]"
     | RetNamedPack { ty; entity_proof; other_proof; _ } ->
        emit_named_pack_spec ctx ty entity_proof other_proof
     | _ -> emit_return_spec ctx body);
    emit ctx ")"

(* ── Proof symbol declarations ───────────────────────────────────────────── *)

(** Collect all proof predicate names used in the module and emit
    [define P 'P] for each one. *)
let collect_proof_names (m : module_form) =
  let names = Hashtbl.create 16 in
  (* Build set of names imported from other modules — don't re-define those *)
  let imported = Hashtbl.create 16 in
  List.iter (fun (imp : Ast.import_decl) ->
    match imp.names with
    | ImportExposing ns ->
      List.iter (fun n ->
        (* Strip Any(..) suffix, expand to plain name *)
        let plain = if String.contains n '(' then
          String.sub n 0 (String.index n '(') |> String.trim
        else n
        in
        Hashtbl.replace imported plain ()
      ) ns
    | ImportAll -> ()
  ) m.imports;
  (* Only add uppercase proof names (predicates start uppercase; lowercase vars are not predicates) *)
  let add n =
    if String.length n > 0 && n.[0] >= 'A' && n.[0] <= 'Z' &&
       not (Hashtbl.mem imported n) then
      Hashtbl.replace names n ()
  in
  (* These are structural keywords, not proof predicates *)
  let is_reserved_pred = function
    | "ForAll" | "MaybeForAll" | "Exists"
    | "FromDb" | "FromQueue" | "FromDeadQueue" | "Id" -> true
    | _ -> false
  in
  let rec visit_proof = function
    | PredApp { pred; _ } -> if not (is_reserved_pred pred) then add pred
    | PredAnd { left; right; _ } -> visit_proof left; visit_proof right
  in
  let visit_binding (b : Ast.binding) = Option.iter visit_proof b.proof_ann in
  (* Extract proof predicate names from type expressions (for Fact (Pred n) return types) *)
  let visit_type_for_proofs = function
    | TApp { head = TName { name = "Fact"; _ }; arg; _ } ->
      let rec get_head = function
        | TName { name; _ } -> add name
        | TApp { head; _ } -> get_head head
        | _ -> ()
      in
      get_head arg
    | _ -> ()
  in
  let visit_return_spec rs =
    let rec go = function
      | RetPlain { ty; _ } -> visit_type_for_proofs ty
      | RetAttached { binding = b; _ } -> visit_binding b
      | RetNamedPack { entity_proof; other_proof; _ } ->
        Option.iter visit_proof entity_proof;
        Option.iter visit_proof other_proof
      | RetForAll { proof; _ } | RetMaybeForAll { proof; _ }
      | RetSetForAll { proof; _ } | RetMaybeSetForAll { proof; _ }
      | RetForAllDictValues { proof; _ } | RetForAllDictKeys { proof; _ } ->
        visit_proof proof
      | RetMaybeAttached { binding = b; _ } -> visit_binding b
      | RetExists { binding = b; body; _ } ->
        visit_binding b; go body
    in
    go rs
  in
  (* Collect proof-predicate names referenced inside an expression.  Only the
     two variants that carry a [proof_expr] alongside their sub-exprs get
     bespoke handling — [EOk]'s attached proof and [ELambda]'s parameter proof
     annotations.  Recursion into every other variant's child exprs (including,
     now, [EFail.message] — previously skipped by an [EFail _ -> ()] arm) is
     delegated to {!Ast_visitor.iter_children}, the single shared traversal, so
     a proof nested in any expression position cannot be silently missed. *)
  let rec visit_expr e =
    match e with
    | EOk { value; proof; _ } ->
      visit_expr value;
      visit_proof proof
    | ELambda { params; body; _ } ->
      List.iter (fun (b : Ast.binding) -> Option.iter visit_proof b.proof_ann) params;
      visit_expr body
    | _ -> Ast_visitor.iter_children visit_expr e
  in
  List.iter (fun decl ->
    match decl with
    | DFunc fd ->
      List.iter visit_binding fd.params;
      visit_return_spec fd.return_spec;
      visit_expr fd.body
    | DRecord r ->
      List.iter (fun f -> Option.iter visit_proof f.proof_ann) r.fields;
      Option.iter (fun inv -> visit_proof inv.proof_text) r.invariant
    | DEntity e ->
      List.iter (fun f -> Option.iter visit_proof f.proof_ann) e.fields
    | _ -> ()
  ) m.decls;
  Hashtbl.fold (fun k () acc -> k :: acc) names []
  |> List.sort String.compare

(** Known constructors for stdlib ADTs — used to expand Type(..) in import lists. *)
let adt_constructors : (string, string list) Hashtbl.t =
  let h = Hashtbl.create 16 in
  Hashtbl.replace h "Maybe"        ["Maybe"; "Something"; "Nothing"];
  Hashtbl.replace h "Either"       ["Either"; "Left"; "Right"];
  Hashtbl.replace h "Result"       ["Result"; "Ok"; "Err"];
  Hashtbl.replace h "JobResult"    ["JobResult"; "JobOk"; "JobFailed"];
  Hashtbl.replace h "DeleteResult" ["DeleteResult"; "NoRowDeleted"; "RowsDeleted"];
  h

(** Expand an import name (possibly with (..)) to a list of concrete names.
    E.g. "Maybe" → ["Maybe"; "Something"; "Nothing"] if it has (..) *)
let strip_dotdot_suffix n =
  let len = String.length n in
  if len > 4 && String.sub n (len-4) 4 = "(..)" then String.sub n 0 (len-4) else n

let expand_import_names names =
  List.concat_map (fun n ->
    let n = strip_dotdot_suffix n in
    if String.contains n '.' then
      [n]  (* qualified name like Dict.lookup — no expansion *)
    else
      match Hashtbl.find_opt adt_constructors n with
      | Some ctors -> ctors
      | None -> [n]
  ) names

(** Convert PascalCase module name to kebab-case filename.
    E.g., Lesson07Home → lesson07-home *)
let module_name_to_kebab name =
  let buf = Buffer.create (String.length name + 4) in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      (* Always insert hyphen before uppercase letter *)
      Buffer.add_char buf '-';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf c
  ) name;
  Buffer.contents buf

let resolve_local_import_path source_file module_name =
  let dir = Filename.dirname source_file in
  let kebab_path = Filename.concat dir (module_name_to_kebab module_name ^ ".tesl") in
  if Sys.file_exists kebab_path then kebab_path
  else Filename.concat dir (module_name ^ ".tesl")

let cyclic_local_import_table : (string, unit) Hashtbl.t = Hashtbl.create 16

let is_cyclic_local_import (m : module_form) (imp : import_decl) =
  let is_tesl_stdlib = String.length imp.module_name >= 5 &&
                       String.sub imp.module_name 0 5 = "Tesl." in
  not is_tesl_stdlib &&
  m.source_file <> "" && m.source_file <> "<test>" &&
  Hashtbl.mem cyclic_local_import_table (resolve_local_import_path m.source_file imp.module_name)

let load_local_import_module source_file module_name =
  let path = resolve_local_import_path source_file module_name in
  if not (Sys.file_exists path) then None
  else
    let source = In_channel.with_open_text path In_channel.input_all in
    match Parser.parse_module path source with
    | Err _ -> None
    | Ok imported -> Some imported

let load_local_import_function_names source_file module_name =
  match load_local_import_module source_file module_name with
  | None -> []
  | Some imported ->
    List.filter_map (function
      | DFunc fd when fd.kind <> MainKind -> Some fd.name
      | _ -> None
    ) imported.decls

let expand_local_import_names source_file module_name names =
  match load_local_import_module source_file module_name with
  | None -> expand_import_names names
  | Some imported ->
    let adts = Hashtbl.create 16 in
    List.iter (function
      | DType (TypeAdt { name; variants; _ }) ->
        Hashtbl.replace adts name (name :: List.map (fun v -> v.ctor) variants)
      | DType (TypeNewtype { name; _ }) ->
        Hashtbl.replace adts name [name]
      | _ -> ()
    ) imported.decls;
    List.concat_map (fun n ->
      let n = strip_dotdot_suffix n in
      if String.contains n '.' then [n]
      else match Hashtbl.find_opt adts n with
           | Some expanded -> expanded
           | None -> [n]
    ) names

let load_imported_fn_arities (m : module_form) : (string * int) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then []
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        match Parser.parse_module path source with
        | Err _ -> []
        | Ok imported ->
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some names
          in
          List.concat_map (function
            | DFunc fd ->
              let arity = List.length fd.params in
              let qualified_name = imp.module_name ^ "." ^ fd.name in
              let include_plain = match requested with
                | Some names -> List.mem fd.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem fd.name names
                | None -> true
              in
              (if include_plain then [ (fd.name, arity) ] else [])
              @ (if include_qualified then [ (qualified_name, arity) ] else [])
            | _ -> []
          ) imported.decls
  ) m.imports

(* ── Require block ────────────────────────────────────────────────────────── *)

(** Collect all Module.field qualified uses from the module's function bodies.
    Used to build `only-in` bindings for `import Tesl.Foo` (no `exposing`).
    Returns a list of "Module.field" strings for all usages of `short_name.x`. *)
let collect_qualified_uses_for_module short_name (m : module_form) : string list =
  let seen = Hashtbl.create 8 in
  let add n = if not (Hashtbl.mem seen n) then Hashtbl.replace seen n () in
  let rec walk_expr : Ast.expr -> unit = function
    | EField { obj = EConstructor { name = mname; args = []; _ }; field; _ }
      when mname = short_name -> add (mname ^ "." ^ field)
    | EField { obj = EVar { name = mname; _ }; field; _ }
      when mname = short_name -> add (mname ^ "." ^ field)
    | EField { obj; _ } -> walk_expr obj
    | EApp { fn; arg; _ } -> walk_expr fn; walk_expr arg
    | EBinop { left; right; _ } -> walk_expr left; walk_expr right
    | EUnop { arg; _ } -> walk_expr arg
    | EIf { cond; then_; else_; _ } -> walk_expr cond; walk_expr then_; walk_expr else_
    | ECase { scrut; arms; _ } ->
      walk_expr scrut; List.iter (fun (arm : Ast.case_arm) -> walk_expr arm.body) arms
    | ELet { value; body; _ } -> walk_expr value; walk_expr body
    | ELetProof { value; body; _ } -> walk_expr value; walk_expr body
    | EList { elems; _ } -> List.iter walk_expr elems
    | ERecord { fields; _ } -> List.iter (fun (_, e) -> walk_expr e) fields
    | EOk { value; _ } -> walk_expr value
    | EConstructor { args; _ } -> List.iter walk_expr args
    | ELambda { body; _ } -> walk_expr body
    | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk_expr body
    | ETelemetry { fields; _ } -> List.iter (fun (_, e) -> walk_expr e) fields
    | EEnqueue { payload; _ } -> walk_expr payload
    | EPublish { key; payload; _ } ->
      (match key with Some k -> walk_expr k | None -> ());
      (match payload with Some p -> walk_expr p | None -> ())
    | EServe { port; _ } -> walk_expr port
    | EFail { message; _ } -> walk_expr message
    | ELit _ | EVar _ | EStartWorkers _ | EStartEmailWorker _ -> ()
    | ECacheGet { key; _ } -> walk_expr key
    | ECacheSet { key; value; ttl; _ } ->
      walk_expr key; walk_expr value;
      (match ttl with Some e -> walk_expr e | None -> ())
    | ECacheDelete { key; _ } -> walk_expr key
    | ECacheInvalidate { prefix; _ } -> walk_expr prefix
    | ESendEmail { to_; subject; body; _ } ->
      walk_expr to_; walk_expr subject; walk_expr body
    | ERuntimeCall { segments; _ } ->
      List.iter (function RLit _ -> () | RArg e -> walk_expr e) segments
  in
  List.iter (function
    | DFunc (fd : Ast.func_decl) -> walk_expr fd.body
    | _ -> ()
  ) m.decls;
  Hashtbl.fold (fun k () acc -> k :: acc) seen []

let emit_requires ctx (m : module_form) =
  let lazy_local_imports : (string * (string * string) list) list ref = ref [] in
  let needs_runtime_path =
    List.exists (fun (imp : Ast.import_decl) ->
      imp.module_name <> "Tesl.Json" && is_cyclic_local_import m imp
    ) m.imports
  in
  let binding_pair_to_string (orig_name, bound_name) =
    if String.equal orig_name bound_name then orig_name
    else Printf.sprintf "[%s %s]" orig_name bound_name
  in
  emit_line ctx "#lang racket";
  emit_nl ctx;
  emit_line ctx "(require";
  emit_line ctx "  tesl/dsl/capability";
  emit_line ctx "  tesl/dsl/types";
  emit_line ctx "  tesl/dsl/check";
  emit_line ctx "  tesl/dsl/otel";
  emit_line ctx "  tesl/dsl/sql";
  emit_line ctx "  tesl/dsl/web";
  emit_line ctx "  tesl/dsl/test-support";
  (* B5: always require checkpoint.  thsl-src!/thsl-src are expansion-time-gated
     macros there — zero residue in release, real checkpoint under TESL_DEBUG. *)
  emit_line ctx "  tesl/dsl/debug/checkpoint";
  emit_line ctx "  tesl/tesl/private/runtime";
  emit_line ctx "  tesl/tesl/queue";
  emit_line ctx "  tesl/tesl/sse";
  (* cache and email DSL macros live in their own tesl/tesl modules.
     Only emit their require when the module actually uses them so that
     files compiled without a database/SMTP connection don't load the
     runtime eagerly. *)
  let has_cache = List.exists (function Ast.DCache _ -> true | _ -> false) m.decls in
  let has_email = List.exists (function Ast.DEmail _ -> true | _ -> false) m.decls in
  let has_agent = List.exists (function Ast.DAgent _ -> true | _ -> false) m.decls in
  if has_cache then emit_line ctx "  tesl/tesl/cache";
  if has_email then emit_line ctx "  tesl/tesl/email";
  (* A declarative `agent { … }` block lowers to the Tesl.Agent library constructors.
     Require them under a private prefix so the lowering works regardless of what the
     module chose to `expose`-import, and never collides with a user's own imports. *)
  if has_agent then
    emit_line ctx "  (prefix-in __tart_ (only-in tesl/tesl/agent defineAgent withTools tool anthropic openai mistral local tesl-agent-decode-args))";
  if needs_runtime_path then
    emit_line ctx "  racket/runtime-path";

  (* Per-import requires *)
  List.iter (fun (imp : Ast.import_decl) ->
    (* Tesl.Json codec names are handled inline by the emitter — no require needed *)
    if imp.module_name = "Tesl.Json" then ()
    else
    let is_tesl_stdlib = Hashtbl.mem module_path_table imp.module_name in
    let modpath = match Hashtbl.find_opt module_path_table imp.module_name with
      | Some p -> p
      | None ->
        (* Local module — resolve relative to source file's directory *)
        if m.source_file = "" || m.source_file = "<test>" then
          module_name_to_kebab imp.module_name ^ ".rkt"
        else
          (* Resolve the actual path of the imported .tesl file *)
          let imported_path = resolve_local_import_path m.source_file imp.module_name in
          if imported_path = "" then
            module_name_to_kebab imp.module_name ^ ".rkt"
          else
            (* Convert .tesl to .rkt and get basename *)
            let kebab = module_name_to_kebab imp.module_name in
            kebab ^ ".rkt"
    in
    (* Non-absolute paths are repo-relative; convert to Racket collection path *)
    let is_absolute = String.length modpath > 0 && modpath.[0] = '/' in
    let require_path, use_file_syntax =
      if is_absolute then modpath, false
      else if is_tesl_stdlib then
        (* Tesl stdlib modules: use collection path *)
        let without_ext =
          if Filename.check_suffix modpath ".rkt"
          then Filename.chop_suffix modpath ".rkt"
          else modpath
        in
        "tesl/" ^ without_ext, false
      else
        (* Local modules: use (file "basename.rkt") - both files in same directory *)
        modpath, true
    in
    match imp.names with
    | ImportAll ->
      (* For wildcard imports, register all exported names as qualified imports
         so `Lib.double` maps to `double` in the generated code *)
      (if not is_tesl_stdlib then
        (match load_local_import_module m.source_file imp.module_name with
         | None -> ()
         | Some lib_m ->
           List.iter (function
             | ExportName n | ExportAdt n ->
               let qualified = imp.module_name ^ "." ^ n in
               Hashtbl.replace qualified_imports qualified n
           ) lib_m.exports));
      (* R52-Q: For Tesl stdlib ImportAll, collect Module.field usages and emit
         proper only-in bindings so qualified calls like `List.length [1,2,3]`
         compile to bound Racket identifiers rather than unbound ones. *)
      if is_tesl_stdlib then begin
        let short_name =
          match String.rindex_opt imp.module_name '.' with
          | Some i -> String.sub imp.module_name (i+1) (String.length imp.module_name - i - 1)
          | None -> imp.module_name
        in
        let used_names = collect_qualified_uses_for_module short_name m in
        List.iter (fun n -> register_import imp.module_name n) used_names;
        if is_cyclic_local_import m imp then ()
        else if used_names = [] then begin
          if is_absolute || use_file_syntax
          then emit_line ctx (Printf.sprintf "  (file \"%s\")" require_path)
          else emit_line ctx (Printf.sprintf "  %s" require_path)
        end else begin
          let bindings = List.map (fun n -> (n, import_rename n)) used_names in
          let pairs_str = String.concat " " (List.map binding_pair_to_string bindings) in
          if is_absolute || use_file_syntax
          then emit_line ctx (Printf.sprintf "  (only-in (file \"%s\") %s)" require_path pairs_str)
          else emit_line ctx (Printf.sprintf "  (only-in %s %s)" require_path pairs_str)
        end
      end else begin
        if is_cyclic_local_import m imp then ()
        else if is_absolute || use_file_syntax
             then emit_line ctx (Printf.sprintf "  (file \"%s\")" require_path)
             else emit_line ctx (Printf.sprintf "  %s" require_path)
      end
    | ImportExposing names ->
      let expanded =
        if is_tesl_stdlib || m.source_file = "" || m.source_file = "<test>" then
          expand_import_names names
        else
          expand_local_import_names m.source_file imp.module_name names
      in
      (* Config-block types (database/queue/email/sse) are compile-time only:
         the desugar pass consumes the config record literal and they never
         appear in emitted Racket, so importing them must NOT emit a `require`
         for runtime bindings that don't exist. *)
      let config_only_names =
        [ "Database"; "DatabaseBackend"; "Postgres"; "Memory"; "PostgresConfig";
          "PostgresConnection"; "TcpConnection"; "SocketConnection";
          "Queue"; "QueueRetryStrategy"; "QueueRetryConfig"; "QueueRetryBackoff";
          "Exponential"; "Fixed"; "Linear";
          "Email"; "SmtpConfig"; "SseChannel"; "App"; "Job"; "Cache" ] in
      let expanded = List.filter (fun n -> not (List.mem n config_only_names)) expanded in
      let qualified = List.filter (fun n -> String.contains n '.') expanded in
      let plain = List.filter (fun n -> not (String.contains n '.')) expanded in
      (* Register plain names from Tesl stdlib modules as stdlib functions *)
      let is_tesl_stdlib = String.length imp.module_name >= 5 &&
                           String.sub imp.module_name 0 5 = "Tesl." in
      if is_tesl_stdlib then
        List.iter (fun n ->
          if String.length n > 0 && n.[0] >= 'a' && n.[0] <= 'z'
             && not (Hashtbl.mem stdlib_name_map n) then
            Hashtbl.replace stdlib_plain_imports n ()
        ) plain;
      List.iter (fun n -> register_import imp.module_name n) qualified;
      let sig_bindings =
        if is_tesl_stdlib || m.source_file = "" || m.source_file = "<test>" then []
        else
          let function_names = load_local_import_function_names m.source_file imp.module_name in
          List.filter_map (fun n ->
            if List.mem n function_names then
              let sig_name = n ^ "-signature" in
              Some (sig_name, sig_name)
            else None
          ) plain
      in
      let ordered_bindings = List.map (fun n ->
        if List.mem n qualified then (n, import_rename n)
        else (n, n)
      ) expanded in
      let all_bindings = ordered_bindings @ sig_bindings in
      (* R52-EMIT: Deduplicate by orig_name to avoid duplicate only-in bindings
         (e.g. when a name appears from both Bool(..) expansion and another import). *)
      let seen_orig = Hashtbl.create 16 in
      let all_bindings = List.filter (fun (orig, _) ->
        if Hashtbl.mem seen_orig orig then false
        else (Hashtbl.replace seen_orig orig (); true)
      ) all_bindings in
      if is_cyclic_local_import m imp then begin
        (* Cyclic imports: do NOT use lazy imports. The cyclic module's declarations
           will be emitted inline by emit_module after the main module's declarations.
           No require or lazy-import is needed. *)
        ignore (require_path, all_bindings)
      end else if all_bindings = [] then
        (* All imported names were compile-time-only config types — no require. *)
        ()
      else begin
        let pairs_str = String.concat " " (List.map binding_pair_to_string all_bindings) in
        if is_absolute || use_file_syntax
        then emit_line ctx (Printf.sprintf "  (only-in (file \"%s\") %s)" require_path pairs_str)
        else emit_line ctx (Printf.sprintf "  (only-in %s %s)" require_path pairs_str)
      end
  ) m.imports;
  emit_line ctx ")";
  emit_nl ctx;
  if !lazy_local_imports <> [] then begin
    emit_line ctx "(define-syntax-rule (tesl-define-lazy-import name getter)";
    emit_line ctx "  (define-syntax name";
    emit_line ctx "    (lambda (stx)";
    emit_line ctx "      (syntax-case stx ()";
    emit_line ctx "        [(id . rest) #'((getter) . rest)]";
    emit_line ctx "        [id #'(getter)]))))";
    emit_nl ctx;
    List.iteri (fun import_i (path, bindings) ->
      let path_id = Printf.sprintf "tesl_lazy_import_path_%d" import_i in
      emit_line ctx (Printf.sprintf "(define-runtime-path %s %S)" path_id path);
      List.iteri (fun binding_i (orig_name, bound_name) ->
        let getter_id = Printf.sprintf "tesl_lazy_import_%d_%d" import_i binding_i in
        emit_line ctx (Printf.sprintf "(define %s" getter_id);
        emit_line ctx "  (let ([loaded? #f] [value #f])";
        emit_line ctx "    (lambda ()";
        emit_line ctx "      (unless loaded?";
        emit_line ctx (Printf.sprintf "        (set! value (dynamic-require `(file ,(path->string %s)) (string->symbol %S)))" path_id orig_name);
        emit_line ctx "        (set! loaded? #t))";
        emit_line ctx "      value)))";
        emit_line ctx (Printf.sprintf "(tesl-define-lazy-import %s %s)" bound_name getter_id);
        emit_nl ctx
      ) bindings
    ) (List.rev !lazy_local_imports)
  end;
  emit_nl ctx

(* ── Provide block ───────────────────────────────────────────────────────── *)

let emit_provide ctx (m : module_form) =
  let names_from_module (mod_m : module_form) (decls : top_decl list) =
    List.concat_map (function
      | ExportName n  -> [n]
      | ExportAdt n   ->
        let ctors = List.concat_map (function
          | DType (TypeAdt { name; variants; _ }) when name = n ->
            n :: List.map (fun v -> v.ctor) variants
          | DType (TypeNewtype { name; _ }) when name = n -> [name]
          | _ -> []
        ) decls in
        if ctors = [] then [n] else ctors
    ) mod_m.exports
  in
  let names = names_from_module m m.decls in
  (* Also export names from cyclic SCC modules *)
  let cyclic_names = ref [] in
  List.iter (fun (imp : Ast.import_decl) ->
    if is_cyclic_local_import m imp then begin
      (match load_local_import_module m.source_file imp.module_name with
       | None -> ()
       | Some cyclic_m ->
         let cn = names_from_module cyclic_m cyclic_m.decls in
         cyclic_names := !cyclic_names @ cn)
    end
  ) m.imports;
  (* Also export -signature names for each EXPORTED function, in declaration order *)
  let exported_names_set =
    let h = Hashtbl.create 16 in
    List.iter (function ExportName n -> Hashtbl.replace h n () | _ -> ()) m.exports;
    List.iter (fun n -> Hashtbl.replace h n ()) !cyclic_names;
    h
  in
  let sig_names = List.filter_map (function
    | DFunc fd when Hashtbl.mem exported_names_set fd.name && fd.kind <> MainKind ->
      Some (fd.name ^ "-signature")
    | _ -> None
  ) m.decls in
  let all_provides = names @ !cyclic_names @ sig_names in
  (* Deduplicate while preserving order *)
  let seen = Hashtbl.create 16 in
  let deduped = List.filter (fun n ->
    if Hashtbl.mem seen n then false
    else begin Hashtbl.replace seen n (); true end
  ) all_provides in
  emit ctx "(provide ";
  emit ctx (String.concat " " deduped);
  emit_line ctx ")";
  emit_nl ctx

(* ── Top-level declaration emitters ─────────────────────────────────────── *)

(* Shared helper: emit a Racket (list (cons 'display racket) ...) for the
   Variables panel.  Used by both emit_func and emit_test. *)
let emit_locals_list ctx pairs =
  if pairs = [] then emit ctx "(list)"
  else begin
    emit ctx "(list";
    List.iter (fun (display, racket) ->
      emit ctx (Printf.sprintf " (cons '%s %s)" display racket)) pairs;
    emit ctx ")"
  end

let emit_func ctx (fd : func_decl) =
  (* MainKind emits as (module+ main ...) *)
  if fd.kind = MainKind then begin
    emit_line ctx "(module+ main";
    emit ctx "  ";
    ctx.func_kind <- Some MainKind;
    ctx.func_return_spec <- None;
    (* B5: always wrap each statement in (thsl-src! file line locals thunk) so
       breakpoints can fire inside main blocks.  The macro erases to the bare
       thunk body in release (zero residue) and to a real checkpoint under
       TESL_DEBUG.  Wrapped in sm_region so the source-map tool still records
       the body's emitted line range. *)
    (* [locals] accumulates the names bound by enclosing `let`s so each checkpoint
       reports the in-scope locals for the Variables panel — mirroring the
       fn/handler path (emit_checkpoint_tail). Without this, debugging `main`
       showed an always-empty Locals panel. `main` binds names bare (no `*`
       prefix), so a local `port` is referenced as `port`. `_` (effect
       statements like initTelemetry) is never a user-visible local and is
       skipped. A let's VALUE checkpoint sees only the PRECEDING locals (the new
       name isn't bound yet); the body checkpoints see it. *)
    let emit_main_cp_locals locals =
      if locals = [] then emit ctx "(list)"
      else begin
        emit ctx "(list";
        List.iter (fun n -> emit ctx (Printf.sprintf " (cons '%s %s)" n n)) (List.rev locals);
        emit ctx ")"
      end
    in
    let rec emit_main_debug locals e =
      match e with
      | ELet { name; value; body; _ } ->
        let val_loc = Checker.expr_loc value in
        emit ctx (Printf.sprintf "(let ([%s (thsl-src! %S %d " name
          val_loc.Location.file (val_loc.Location.start.line + 1));
        emit_main_cp_locals locals;
        emit ctx " (lambda () ";
        emit_expr ctx value;
        emit ctx "))])";   (* ) closes lambda, ) closes thsl-src!, ] closes [, ) closes let bindings *)
        emit_nl ctx;
        emit ctx "  ";
        let locals' = if name = "_" then locals else name :: locals in
        emit_main_debug locals' body;
        emit ctx ")"
      | ELetProof { value_name; proof_name; value; body; _ } ->
        let val_loc = Checker.expr_loc value in
        let tmp = Printf.sprintf "tesl_proof_binding_%d" ctx.case_counter in
        ctx.case_counter <- ctx.case_counter + 1;
        emit ctx (Printf.sprintf "(let ([%s (thsl-src! %S %d " tmp
          val_loc.Location.file (val_loc.Location.start.line + 1));
        emit_main_cp_locals locals;
        emit ctx " (lambda () ";
        emit_expr ctx value;
        emit ctx (Printf.sprintf "))]) (let ([%s (forget-proof %s)] [%s (detach-all-proof %s)]) "
          value_name tmp proof_name tmp);
        let locals' =
          let add n acc = if n = "_" then acc else n :: acc in
          add proof_name (add value_name locals)
        in
        emit_main_debug locals' body;
        emit ctx "))"
      | other ->
        let loc = Checker.expr_loc other in
        emit ctx (Printf.sprintf "(thsl-src! %S %d "
          loc.Location.file (loc.Location.start.line + 1));
        emit_main_cp_locals locals;
        emit ctx " (lambda () ";
        emit_expr ctx other;
        emit ctx "))"
    in
    sm_region ctx ~form:"main block body" (Checker.expr_loc fd.body)
      (fun () -> emit_main_debug [] fd.body);
    ctx.func_kind <- None;
    emit_line ctx ")";
    emit_nl ctx
  end else
  let macro_name = match fd.kind with
    | FnKind -> "define/pow"
    | CheckKind -> "define-checker"
    | AuthKind -> "define-auther"
    | EstablishKind -> "define-trusted"
    | HandlerKind -> "define-handler"
    | WorkerKind -> "define/pow"   (* workers use define/pow with #:returns Any *)
    | DeadWorkerKind -> "define/pow"
    | MainKind -> "define"  (* fallback, not reached *)
  in
  emit_line ctx (Printf.sprintf "(%s" macro_name);
  emit ctx (Printf.sprintf "  (%s" fd.name);
  emit_params ctx fd.params;
  emit_line ctx ")";
  (* Drop capability-row VARIABLES (e.g. the `c` in a higher-order function's
     `requires ([time] ++ c)`): they are compile-time only — instantiated per call
     site by the static checker — and have no runtime capability value.  Only
     concrete capabilities reach `#:capabilities`. *)
  (let bound_vars = Ast.func_bound_cap_vars fd in
   let concrete = List.filter (fun c -> not (List.mem c bound_vars)) fd.capabilities in
   if concrete <> [] then begin
    emit ctx "  #:capabilities [";
    emit ctx (cap_list_str concrete);
    emit_line ctx "]"
  end);
  emit ctx "  ";
  (* Workers always return Any *)
  emit_return_spec ctx fd.return_spec;
  emit_nl ctx;
  emit ctx "  ";
  let return_preserves_case_payload_names = match fd.return_spec with
    | RetAttached _ | RetNamedPack _ | RetExists _ -> true
    | RetMaybeAttached { outer_ty = Some _; binding = b; _ } when b.proof_ann <> None -> true
    | _ -> false
  in
  let old_kind = ctx.func_kind in
  let old_auth_return_binding = ctx.auth_return_binding in
  let old_preserve_case_payload_names = ctx.preserve_case_payload_names in
  ctx.func_kind <- Some fd.kind;
  let old_return_spec = ctx.func_return_spec in
  ctx.func_return_spec <- Some fd.return_spec;
  ctx.auth_return_binding <- (match fd.return_spec with
    | RetAttached { binding = { name; _ }; _ } -> Some name
    | _ -> None);
  ctx.preserve_case_payload_names <- return_preserves_case_payload_names;
  (* For fn functions, user-defined GDP function calls in tail position need raw-value *)
  let is_user_defined_fn_call e =
    match fd.kind with
    | FnKind ->
      let rec get_head = function EApp { fn; _ } -> get_head fn | e -> e in
      (match get_head e with
       | EVar { name; _ } ->
         let is_upper = String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' in
         let is_sql_runtime = match name with
           | "select" | "selectOne" | "selectCount" | "selectSum"
           | "insert" | "update" | "delete" | "where" | "set" | "returning"
           | "select-one" | "select-many" | "select-count" | "select-sum"
           | "insert-one!" | "update-many!" | "delete-many!" -> true
           | _ -> false
         in
         not is_upper &&
         not is_sql_runtime &&
         not (Hashtbl.mem stdlib_plain_imports name) &&
         not (Hashtbl.mem stdlib_name_map name) &&
         not (Hashtbl.mem qualified_imports name) &&
         name <> "#record-update#"  (* record updates handled directly *)
         && name <> "make-witness"   (* exists witness → pack, handled directly *)
       | _ -> false)
    | _ -> false
  in
  let rec get_tail_expr = function
    | ELet { body; _ } | ELetProof { body; _ } -> get_tail_expr body
    | EWithTransaction { body; _ } | EWithDatabase { body; _ } | EWithCapabilities { body; _ } -> get_tail_expr body
    | EIf _ | ECase _ | EApp _ as e -> e
    | e -> e
  in
  let tail = get_tail_expr fd.body in
  (* Check if a case expression has user-defined fn calls in tail positions (for raw-value wrapping) *)
  let case_arms_have_fn_calls = match tail, fd.kind with
    | ECase { arms; _ }, FnKind when not (match fd.return_spec with RetNamedPack _ | RetAttached _ | RetMaybeAttached _ | RetForAll _ | RetMaybeForAll _ | RetSetForAll _ | RetMaybeSetForAll _ | RetForAllDictValues _ | RetForAllDictKeys _ -> true | _ -> false) ->
      List.exists (fun (arm : case_arm) ->
        match get_tail_expr arm.body with
        | EApp _ as app -> is_user_defined_fn_call app
        | _ -> false
      ) arms
    | _ -> false
  in
  (* Check if tail is a lowercase EVar that is a STDLIB-BOUND local var needing *name.
     Only trigger for let-bindings whose value came from a stdlib call (which returns raw values).
     We detect this by checking if the variable was bound in a let whose value was a stdlib EApp. *)
  let param_names = List.map (fun (b : Ast.binding) -> b.name) fd.params in
  (* Populate param_names in context so the emitter can differentiate parameters from let-bindings *)
  Hashtbl.clear ctx.param_names;
  List.iter (fun name -> Hashtbl.replace ctx.param_names name ()) param_names;
  (* plain_param_names: parameters WITHOUT proof annotations, OR with compile-time-only
     proof annotations that have no runtime evidence (ForAll, IsSorted, etc.).
     These parameters are emitted as *name (raw) when passed to stdlib functions.
     Parameters with runtime-evidence proofs (IsNonZero, FloatNonZero, HasKey, etc.)
     are NOT in this set — they preserve their GDP symbol so proof-total stdlib
     functions like Int.divide can find the evidence in current-evidence-env. *)
  Hashtbl.clear ctx.plain_param_names;
  List.iter (fun (b : Ast.binding) ->
    if is_comptime_only_proof b.proof_ann then Hashtbl.replace ctx.plain_param_names b.name ()
  ) fd.params;
  let find_let_value name body =
    let rec go = function
      | ELet { name = n; value; body = _; _ } when n = name -> Some value
      | ELet { body; _ } | ELetProof { body; _ } -> go body
      | _ -> None
    in go body
  in
  let is_local_var_tail = match tail, fd.kind with
    | EVar { name; _ }, FnKind
      when String.length name > 0 && name.[0] >= 'a' && name.[0] <= 'z' &&
           not (Hashtbl.mem stdlib_plain_imports name) &&
           not (Hashtbl.mem stdlib_name_map name) &&
           not (Hashtbl.mem qualified_imports name) &&
           not (List.mem name param_names) ->
      (* Trigger raw-tail for:
         1. Literals and stdlib calls (already raw values)
         2. check-call bindings (`let x = check f arg`): the check
            machinery wraps the value as a named-value; tail position
            in a plain-return fn should strip that wrapper via *name. *)
      (match find_let_value name fd.body with
       | Some (ELit _) | Some (EApp _ ) ->
         let rec get_head = function EApp { fn; _ } -> get_head fn | e -> e in
         let is_check_call = match find_let_value name fd.body with
           | Some (EApp _ as app) ->
             (match get_head app with
              | EVar { name = "check"; _ } -> true
              | _ -> false)
           | _ -> false
         in
         (* Check if it's a non-user-defined call (stdlib or literal) *)
         let is_user_call = match find_let_value name fd.body with
           | Some (EApp _ as app) ->
             (match get_head app with
              | EVar { name = fn_name; _ } ->
                not (Hashtbl.mem stdlib_plain_imports fn_name) &&
                not (is_stdlib_fn (get_head app))
              | _ -> false)
           | _ -> false
         in
         is_check_call || not is_user_call
       | _ -> false)
    | _ -> false
  in
  (* emit_establish_proof_ctor: emit a proof constructor expression for use inside
     (trusted-proof ...) in establish bodies. Handles EConstructor, curried EApp,
     and EBinop BAnd for proof conjunctions like (ValidPort x && IsPositive y). *)
  let rec emit_establish_proof_ctor v =
    match v with
    | EBinop { op = BAnd; left; right; _ } ->
      (* Proof conjunction: (P1 x && P2 y) → emitted as (P1 x) && (P2 y) inside trusted-proof *)
      emit ctx "(";
      emit_establish_proof_ctor left;
      emit ctx " && ";
      emit_establish_proof_ctor right;
      emit ctx ")"
    | EConstructor { name; args = []; _ } -> emit ctx name
    | EConstructor { name; args; _ } ->
      emit ctx (Printf.sprintf "(%s" name);
      List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) args;
      emit ctx ")"
    | EApp _ ->
      let rec collect acc = function
        | EApp { fn; arg; _ } -> collect (arg :: acc) fn
        | head -> (head, acc)
      in
      let (head, args) = collect [] v in
      (match head with
       | EVar { name; _ } | EConstructor { name; _ }
         when String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' ->
         emit ctx (Printf.sprintf "(%s" name);
         List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) args;
         emit ctx ")"
       | _ -> emit_expr ctx v)
    | _ -> emit_expr ctx v
  in
  (* emit_with_raw_tail: traverse ELet chains, wrap tail in (raw-value ...) *)
  let rec emit_with_raw_tail e =
    match e with
    | EWithTransaction { body; _ } ->
      emit ctx "(call-with-queue-transaction (lambda () ";
      emit_with_raw_tail body;
      emit ctx "))"
    | EWithDatabase { body; _ } ->
      emit ctx "(with-database (lambda () ";
      emit_with_raw_tail body;
      emit ctx "))"
    | EWithCapabilities { capabilities; body; _ } ->
      emit ctx "(call-with-declared-capabilities (list";
      List.iter (fun cap -> emit ctx (Printf.sprintf " %s" cap)) capabilities;
      emit ctx ") (lambda () ";
      emit_with_raw_tail body;
      emit ctx "))"
    | ELet { name = "_"; value = ((ETelemetry _ | EEnqueue _ | EPublish _ | EStartWorkers _ | EWithDatabase _ | EWithCapabilities _ | EServe _ | ERuntimeCall _) as stmt); body; _ } ->
      (* Runtime statement as statement → (begin stmt body) *)
      emit ctx "(begin ";
      emit_expr ctx stmt;
      emit ctx " ";
      emit_with_raw_tail body;
      emit ctx ")"
    | ELet { name = binding_name; value = (EApp _ as check_app); body; _ }
      when (let rec find_check = function
             | EApp { fn = EVar { name = "check"; _ }; _ } -> true
             | EApp { fn; _ } -> find_check fn
             | _ -> false
            in find_check check_app) ->
      (* let x = check fn args in tail position: must use let/check form, same as emit_expr *)
      let tmp = Printf.sprintf "tesl_checked_%d" ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      let rec collect_check_args acc = function
        | EApp { fn = EVar { name = "check"; _ }; arg; _ } -> (arg, acc)
        | EApp { fn; arg; _ } -> collect_check_args (arg :: acc) fn
        | e -> (e, List.rev acc)
      in
      let (fn_expr, args) = collect_check_args [] check_app in
      (* Preserve the original check-ok so named-pack/attached returns keep the
         checker's GDP subject intact all the way to the tail expression. *)
      emit ctx (Printf.sprintf "(let/check ([%s (" tmp);
      emit_expr ctx fn_expr;
      List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) args;
      emit ctx (Printf.sprintf ")]) (let ([%s %s]) " binding_name tmp);
      Hashtbl.replace ctx.proof_locals binding_name ();
      emit_with_raw_tail body;
      Hashtbl.remove ctx.proof_locals binding_name;
      emit ctx "))"
    | ELet { name; value; body; _ } ->
      (* Track Fact-valued bindings for intro-and detection (same as emit_expr). *)
      let is_fact_here = match value with
        | EApp _ ->
          let rec hd = function EApp { fn; _ } -> hd fn | e -> e in
          (match hd value with
           | EVar { name = fn_name; _ } ->
             fn_name = "detachFact" ||
             (Hashtbl.mem ctx.fn_names fn_name &&
              not (Hashtbl.mem stdlib_plain_imports fn_name))
           | _ -> false)
        | EBinop { op = BAnd; left; right; _ } ->
          let rec all_facts e = match e with
            | EVar { name; _ } -> Hashtbl.mem ctx.fact_locals name
            | EBinop { op = BAnd; left; right; _ } -> all_facts left && all_facts right
            | _ -> false
          in
          all_facts left && all_facts right
        | _ -> false
      in
      if is_fact_here then Hashtbl.replace ctx.fact_locals name ();
      (* Track if this let is bound to a proof-carrying wrapper function result
         so case arms on this variable propagate proof to their sub-variables. *)
      let is_proof_carrier_here =
        match value with
        | EApp _ ->
          let rec get_fn = function EApp { fn; _ } -> get_fn fn | e -> e in
          (match get_fn value with
           | EVar { name = fn_name; _ } ->
             (match Hashtbl.find_opt ctx.fn_return_specs fn_name with
              | Some (RetMaybeAttached { binding = b; _ }) when b.proof_ann <> None -> true
              | _ -> false)
           | _ -> false)
        | _ -> false
      in
      if is_proof_carrier_here then Hashtbl.replace ctx.proof_carrier_lets name ();
      emit ctx (Printf.sprintf "(let ([%s " name);
      emit_expr ctx value;
      emit ctx "]) ";
      emit_with_raw_tail body;
      if is_fact_here then Hashtbl.remove ctx.fact_locals name;
      if is_proof_carrier_here then Hashtbl.remove ctx.proof_carrier_lets name;
      emit ctx ")"
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let tmp = Printf.sprintf "tesl_proof_binding_%d" ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      emit ctx (Printf.sprintf "(let ([%s " tmp);
      (* Preserve check-ok result for proof decomposition — do not wrap in raw-value *)
      (match direct_check_call value with
       | Some (check_fn, check_args) ->
         emit ctx "(";
         emit_expr ctx check_fn;
         List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) check_args;
         emit ctx ")"
       | None -> emit_expr ctx value);
      emit ctx (Printf.sprintf "]) (let ([%s (forget-proof %s)] [%s (detach-all-proof %s)]) "
        value_name tmp proof_name tmp);
      emit_with_raw_tail body;
      emit ctx "))"
    (* Non-establish fn/worker: recurse into if branches so params get *name treatment *)
    | EIf { cond; then_; else_; _ } when ctx.func_kind <> Some EstablishKind ->
      let emit_cond_expr e = match e with
        | EVar { name; _ } when Hashtbl.mem ctx.param_names name || Hashtbl.mem ctx.raw_locals name ->
          emit ctx ("*" ^ name)
        | _ -> emit_expr ctx e
      in
      emit ctx "(if ";
      emit_cond_expr cond;
      emit ctx " ";
      emit_with_raw_tail then_;
      emit ctx " ";
      emit_with_raw_tail else_;
      emit ctx ")"
    (* Establish: handle if recursively so proof constructors appear at leaves *)
    | EIf { cond; then_; else_; _ } when ctx.func_kind = Some EstablishKind ->
      let emit_cond_expr e = match e with
        | EVar { name; _ } when Hashtbl.mem ctx.param_names name || Hashtbl.mem ctx.raw_locals name ->
          emit ctx ("*" ^ name)
        | _ -> emit_expr ctx e
      in
      emit ctx "(if ";
      emit_cond_expr cond;
      emit ctx " ";
      emit_with_raw_tail then_;
      emit ctx " ";
      emit_with_raw_tail else_;
      emit ctx ")"
    (* Establish leaf: Nothing → Nothing *)
    | EConstructor { name = "Nothing"; _ } when ctx.func_kind = Some EstablishKind ->
      emit ctx "Nothing"
    (* Establish leaf: EConstructor "Something" args=[arg] (parser form) *)
    | EConstructor { name = "Something"; args = [arg]; _ }
      when ctx.func_kind = Some EstablishKind ->
      emit ctx "(Something (trusted-proof ";
      emit_establish_proof_ctor arg;
      emit ctx "))"
    (* Establish leaf: Something (ProofCtor ...) in EApp form (via <| operator) *)
    | EApp { fn = EConstructor { name = "Something"; _ }; arg; _ }
      when ctx.func_kind = Some EstablishKind ->
      emit ctx "(Something (trusted-proof ";
      emit_establish_proof_ctor arg;
      emit ctx "))"
    (* Establish leaf: direct zero-arg proof constructor → (trusted-proof Name) *)
    | EConstructor { name; args = []; _ }
      when ctx.func_kind = Some EstablishKind
        && String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' ->
      emit ctx (Printf.sprintf "(trusted-proof %s)" name)
    (* Establish leaf: proof constructor with args (parser EConstructor form) → (trusted-proof (Name args)) *)
    | EConstructor { name; args; _ }
      when ctx.func_kind = Some EstablishKind
        && String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' ->
      emit ctx (Printf.sprintf "(trusted-proof (%s" name);
      List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) args;
      emit ctx "))"
    (* Establish leaf: proof constructor application → (trusted-proof (Ctor args)) *)
    | EApp _
      when ctx.func_kind = Some EstablishKind ->
      (let rec get_head = function EApp { fn; _ } -> get_head fn | e -> e in
       match get_head e with
       | EConstructor { name; _ } | EVar { name; _ }
         when String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' ->
         emit ctx "(trusted-proof ";
         emit_establish_proof_ctor e;
         emit ctx ")"
       | _ -> emit ctx "(raw-value "; emit_expr ctx e; emit ctx ")")
    (* Establish: proof conjunction at tail (total establish returning Fact (P && Q)) *)
    | EBinop { op = BAnd; _ } when ctx.func_kind = Some EstablishKind ->
      emit ctx "(trusted-proof ";
      emit_establish_proof_ctor e;
      emit ctx ")"
        | ECase { scrut; arms; _ } when ctx.func_kind <> Some EstablishKind ->
      (* Case expression in raw tail: emit cond with each arm body through emit_with_raw_tail *)
      let tmp = Printf.sprintf "tesl_case_%d" ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      (* Check if scrutinee is a proof-carrying Maybe value — either a let-bound
         variable tracked in proof_carrier_lets, or an inline call to a function
         that returns RetMaybeAttached with a proof annotation.  Both cases need
         the Something-arm payload to be treated as a named-value (not raw). *)
      let scrut_is_proof_carrier = match scrut with
        | EVar { name; _ } -> Hashtbl.mem ctx.proof_carrier_lets name
        | EApp _ ->
          let rec get_fn = function EApp { fn; _ } -> get_fn fn | e -> e in
          (match get_fn scrut with
           | EVar { name = fn_name; _ } ->
             (match Hashtbl.find_opt ctx.fn_return_specs fn_name with
              | Some (RetMaybeAttached { binding = b; _ }) when b.proof_ann <> None -> true
              | _ -> false)
           | _ -> false)
        | _ -> false
      in
      emit ctx (Printf.sprintf "(let ([%s " tmp);
      emit_raw_value ctx scrut;
      emit ctx "]) (cond";
      List.iter (fun (arm : case_arm) ->
        emit ctx " ";
        let raw_bound_names = match arm.pattern with
          | PVar n -> [n]
          | PCon { fields; _ } when not ctx.preserve_case_payload_names ->
            let rec collect_names = function
              | PVar n when n <> "_" -> [n]
              | PCon { fields; _ } -> List.concat_map (fun (_, sub) -> collect_names sub) fields
              | _ -> []
            in
            List.concat_map (fun (_, sub_pat) -> collect_names sub_pat) fields
          | _ -> []
        in
        (* For proof-carrying scrutinees, mark single-field PCon vars as proof-aware
           so they're passed as named-values (not stripped) to proof-requiring functions. *)
        let proof_aware_names =
          if scrut_is_proof_carrier then
            match arm.pattern with
            | PCon { fields = [(_, PVar n)]; _ } when n <> "_" -> [n]
            | _ -> []
          else []
        in
        List.iter (fun name -> Hashtbl.replace ctx.raw_locals name ()) raw_bound_names;
        List.iter (fun name -> Hashtbl.replace ctx.proof_aware_locals name ()) proof_aware_names;
        let guard, binding_code = pattern_to_racket ctx arm.pattern tmp in
        (* Incorporate `where` guard into the cond condition — mirrors emit_case_arm.
           Use nested single-binding let forms to avoid DSL runtime hygiene bug. *)
        let nested_let_str bindings body_str =
          List.fold_right
            (fun b acc -> Printf.sprintf "(let (%s) %s)" b acc)
            bindings body_str
        in
        let full_guard = match arm.guard with
          | None -> guard
          | Some guard_expr ->
            let guard_buf = Buffer.create 64 in
            let guard_ctx = { ctx with buf = guard_buf } in
            emit_expr guard_ctx guard_expr;
            let guard_racket = Buffer.contents guard_buf in
            if binding_code = [] then
              Printf.sprintf "(and %s %s)" guard guard_racket
            else
              Printf.sprintf "(and %s %s)" guard
                (nested_let_str binding_code guard_racket)
        in
        emit ctx "[";
        emit ctx full_guard;
        emit ctx " ";
        let has_guard_with_bindings = arm.guard <> None && binding_code <> [] in
        (* Per-arm checkpoint (see emit_case_arm): step lands on the taken arm, and
           the arm's pattern-bound variables show in Locals (bound by binding_code,
           which wraps this checkpoint). *)
        let emit_arm_body () =
          let bloc = Checker.expr_loc arm.body in
          let rec collect_vars = function
            | PVar n -> if n = "_" then [] else [n]
            | PWild | PLit _ | PNullary _ -> []
            | PCon { fields; _ } -> List.concat_map (fun (_, sub) -> collect_vars sub) fields
          in
          let arm_vars = collect_vars arm.pattern in
          emit ctx (Printf.sprintf "(thsl-src! %S %d "
            bloc.Location.file (bloc.Location.start.line + 1));
          (if arm_vars = [] then emit ctx "(list)"
           else begin
             emit ctx "(list";
             List.iter (fun n -> emit ctx (Printf.sprintf " (cons '%s %s)" n n)) arm_vars;
             emit ctx ")"
           end);
          emit ctx " (lambda () ";
          emit_with_raw_tail arm.body;
          emit ctx "))"
        in
        (match binding_code with
         | [] -> emit_arm_body ()
         | _ ->
           ignore has_guard_with_bindings;
           List.iter (fun b -> emit ctx (Printf.sprintf "(let (%s) " b)) binding_code;
           emit_arm_body ();
           List.iter (fun _ -> emit ctx ")") binding_code);
        emit ctx "]";
        List.iter (fun name -> Hashtbl.remove ctx.raw_locals name) raw_bound_names;
        List.iter (fun name -> Hashtbl.remove ctx.proof_aware_locals name) proof_aware_names
      ) arms;
      emit ctx "))"
    | EVar { name; _ } ->
      (* Named variable in tail: use *name for params/raw-locals, else (raw-value name) *)
      if List.mem name param_names || Hashtbl.mem ctx.raw_locals name then
        emit ctx ("*" ^ name)
      else begin
        emit ctx "(raw-value ";
        emit_expr ctx (EVar { name; loc = Location.dummy_loc "" });
        emit ctx ")"
      end
    | app ->
      emit ctx "(raw-value ";
      emit_expr ctx app;
      emit ctx ")"
  in
  (* Check if tail is a GDP-returning stdlib function that needs raw-value in tail position.
     Skip for functions with ForAll return types (their GDP value is used directly). *)
  (* Functions with proof-carrying returns should not have their GDP value stripped *)
  let has_forall_return = match fd.return_spec with
    | RetNamedPack _ -> true  (* all named-pack returns carry GDP proof values *)
    | RetAttached _ -> true   (* RetAttached returns carry GDP proof values too *)
    | RetMaybeAttached _ -> true  (* RetMaybeAttached also carries proof *)
    | RetSetForAll _ | RetMaybeSetForAll _ | RetForAll _ | RetMaybeForAll _
    | RetForAllDictValues _ | RetForAllDictKeys _ -> true
    | _ -> false
  in
  (* Functions that ALWAYS return GDP named values with proofs — never add raw-value in tail *)
  let always_gdp_in_tail fn_racket =
    match fn_racket with
    | "tesl_import_Set_filterCheck" | "tesl_import_List_filterCheck"
    | "tesl_import_Set_allCheck" | "tesl_import_List_allCheck"
    | "tesl_import_Set_mapCheck" | "tesl_import_List_mapCheck"
    | "tesl_import_List_emptyForAll" -> true
    | _ -> false
  in
  let is_gdp_stdlib_tail = match tail, fd.kind with
    | EApp _, FnKind when not has_forall_return ->
      let rec fn_of = function EApp { fn; _ } -> fn_of fn | e -> e in
      let fn_racket = match fn_of tail with
        | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
          let full = modname ^ "." ^ field in
          (match Hashtbl.find_opt qualified_imports full with
           | Some r -> r | None -> import_rename full)
        | _ -> ""
      in
      Hashtbl.mem gdp_returning_stdlib fn_racket &&
      not (always_gdp_in_tail fn_racket)
    | _ -> false
  in
  (* Worker functions: when returning a parameter, need *name *)
  let is_worker_param_tail = match tail, fd.kind with
    | EVar { name; _ }, (WorkerKind | DeadWorkerKind) ->
      List.mem name param_names
    | _ -> false
  in
  let is_fn_param_tail = match tail, fd.kind with
    | EVar { name; _ }, FnKind when List.mem name param_names && not has_forall_return -> true
    | _ -> false
  in
  (* Inside define/pow, transform-body-sequence wraps every let binding with
     wrap-runtime-named-binding, which creates:
       (let ([*name (runtime-binding-raw bind)]   ; *name = raw value (int, string, etc.)
             [name  (runtime-binding-name bind)])  ; name  = gensym for GDP tracking
         ...)
     So 'name' is always a gensym inside a define/pow fn, while '*name' is the raw value.
     We must use *name everywhere — both for locals capture AND for the terminal expression —
     to get actual values in the Variables panel and avoid validate-signature-return errors.
     This applies equally to parameters (already using *name) and let-bound variables. *)
  let emit_locals_list = emit_locals_list ctx in
  let star name = Printf.sprintf "*%s" name in
  (* All bindings use *name: parameters (already raw via runtime-binding-raw) and
     let-bound variables (raw via wrap-runtime-named-binding's *name let). *)
  let param_locals = List.map (fun n -> (n, star n)) param_names in
  (* B5 — unified body emitter.  ONE emission path: the emitter ALWAYS wraps the
     function body in [(thsl-src! file line locals (lambda () …))] checkpoints,
     and the macro erases them to the bare body in release (zero residue).

     Two shapes:
       • "peelable" bodies — a chain of plain [let x = v] / [let (x ::: p) = v]
         bindings ending in a simple terminal — are peeled so EACH binding gets
         its own checkpoint LINE (per-statement stepping for the debugger).  Every
         value / terminal inside a checkpoint is emitted by the SAME release
         helpers ([emit_expr] / [emit_with_raw_tail]), so erasure recovers the
         exact release semantics (proofs, fact tracking, …).
       • everything else (SQL update/select lowering, check-call let/check chains,
         runtime-statement sequencing, with-blocks, …) is emitted WHOLE by the
         release path under a SINGLE function-entry checkpoint — never
         re-implemented, so those forms keep byte-for-byte release semantics.
         Granularity there is function-entry rather than per-line, which is
         acceptable; correctness is preserved exactly.

     [locals] threads (display, *raw) pairs for the debugger Variables panel; the
     macro drops the list entirely in release. *)

  (* Emit [fd.body] EXACTLY as the former release path did (the old `match tail`
     decision).  Used both for the non-peelable whole-body checkpoint and for the
     peeled terminal leaf. *)
  let emit_release_body e =
    match tail with
    | EApp _ when (is_user_defined_fn_call tail && not has_forall_return) || is_gdp_stdlib_tail ->
      emit_with_raw_tail e
    | EVar _ when (is_local_var_tail || is_worker_param_tail || is_fn_param_tail) && not has_forall_return ->
      emit_with_raw_tail e
    | ECase _ when case_arms_have_fn_calls -> emit_with_raw_tail e
    | ECase _ when fd.kind = FnKind && not has_forall_return -> emit_with_raw_tail e
    | EIf _ when fd.kind = FnKind && not has_forall_return -> emit_with_raw_tail e
    | _ when fd.kind = EstablishKind -> emit_with_raw_tail e
    | _ when has_forall_return ->
      (match e with
       | EField { obj; field; _ } when (match obj with EVar _ -> true | _ -> false) ->
         emit ctx "(tesl-dot/runtime ";
         emit_field_inner ctx obj;
         emit ctx (Printf.sprintf " '%s)" field)
       | _ -> emit_expr ctx e)
    | _ -> emit_expr ctx e
  in
  (* A let node is plainly peelable when it is NOT one of the special forms the
     release ELet arms / emit_expr lowerings recognise (runtime-statement "_",
     check-call, SQL update/select chains). *)
  let plain_let_node e =
    match e with
    | ELet { name; value; _ } ->
      let is_runtime_stmt_underscore =
        String.equal name "_" &&
        (match value with
         | ETelemetry _ | EEnqueue _ | EPublish _ | EStartWorkers _
         | EWithDatabase _ | EWithCapabilities _ | EWithTransaction _ | EServe _
         | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
         | ESendEmail _ | EStartEmailWorker _ | ERuntimeCall _ -> true
         | _ -> false)
      in
      let is_check_call =
        match value with
        | EApp _ ->
          let rec find_check = function
            | EApp { fn = EVar { name = "check"; _ }; _ } -> true
            | EApp { fn; _ } -> find_check fn
            | _ -> false
          in find_check value
        | _ -> false
      in
      (* SQL update/select chains are recognised by emit_expr over the *chain*;
         peeling the outer let would hide them, so they are not peelable. *)
      let is_sql_chain =
        (match extract_update e with Some _ -> true | None -> false)
        || (match extract_multiline_select_query e with Some _ -> true | None -> false)
        || (match extract_select_query e with Some _ -> true | None -> false)
      in
      not is_runtime_stmt_underscore && not is_check_call && not is_sql_chain
    | _ -> false
  in
  (* A `let _ = <simple effect>` statement (telemetry/enqueue/publish/cache/email/
     runtime-call). These lower to a bare effect via emit_expr (the same code the
     non-peeled `(begin stmt body)` arm uses), so each can SAFELY get its own
     checkpoint line — enabling per-statement stepping through a handler (e.g. step
     from `telemetry` onto the SQL line). The STRUCTURAL `_`-statements (with-*,
     serve, startWorkers/startEmailWorker) have nested blocks and stay whole. *)
  let is_simple_effect_underscore e =
    match e with
    | ELet { name = "_"; value; _ } ->
      (match value with
       | ETelemetry _ | EEnqueue _ | EPublish _
       | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
       | ESendEmail _ | ERuntimeCall _ -> true
       | _ -> false)
    | _ -> false
  in
  (* The whole body is peelable iff every binding down the chain is a plain let, a
     simple-effect `_` statement, or an ELetProof whose value is a direct
     check-call (the ELetProof shape the peeler reproduces faithfully), and the
     final tail is a non-let expression. *)
  let rec body_peelable e =
    match e with
    | ELet _ -> (plain_let_node e || is_simple_effect_underscore e)
                && body_peelable (match e with ELet { body; _ } -> body | _ -> e)
    | ELetProof { value; body; _ } ->
      (match direct_check_call value with Some _ -> true | None -> false) && body_peelable body
    | _ -> true
  in
  (* Emit a single checkpoint over [e], delegating the body to [emit_release_body]
     (so SQL / proof / terminal forms keep exact release semantics). *)
  let emit_checkpoint_tail locals e =
    let loc = Checker.expr_loc e in
    (* A `case` is CONTROL FLOW, not a call: its arm-body checkpoints are in the
       same frame, so use the control-flow checkpoint (which does not deepen the
       step frame) — otherwise step-over would skip over the arm the code takes.
       Everything else uses the normal (frame-deepening) checkpoint. *)
    let macro = (match e with ECase _ -> "thsl-src-control!" | _ -> "thsl-src!") in
    emit ctx (Printf.sprintf "(%s %S %d " macro loc.Location.file (loc.Location.start.line + 1));
    emit_locals_list locals;
    emit ctx " (lambda () ";
    emit_release_body e;
    emit ctx "))"
  in
  let rec emit_debug_stmts ?(locals=[]) e =
    match e with
    | ELet { value; body; _ } when is_simple_effect_underscore e ->
      (* `let _ = <simple effect>` → its own checkpoint at the effect's line, then
         continue peeling the rest of the body. Emit the effect with emit_expr
         (identical to the non-peeled `(begin stmt body)` arm). `_` is not a
         user-visible local, so it is NOT added to the locals list (and there is
         no `*_` raw binding to reference). *)
      let loc = Checker.expr_loc value in
      emit ctx (Printf.sprintf "(let ([_ (thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list locals;
      emit ctx " (lambda () ";
      emit_expr ctx value;
      emit ctx "))]) ";
      emit_debug_stmts ~locals body;
      emit ctx ")"
    | ELet { name; value; body; _ } when plain_let_node e ->
      (* Replicate the plain-ELet fact / proof-carrier tracking from
         emit_with_raw_tail so downstream case-arm proof propagation is identical. *)
      let is_fact_here = match value with
        | EApp _ ->
          let rec hd = function EApp { fn; _ } -> hd fn | e -> e in
          (match hd value with
           | EVar { name = fn_name; _ } ->
             fn_name = "detachFact" ||
             (Hashtbl.mem ctx.fn_names fn_name &&
              not (Hashtbl.mem stdlib_plain_imports fn_name))
           | _ -> false)
        | EBinop { op = BAnd; left; right; _ } ->
          let rec all_facts e = match e with
            | EVar { name; _ } -> Hashtbl.mem ctx.fact_locals name
            | EBinop { op = BAnd; left; right; _ } -> all_facts left && all_facts right
            | _ -> false
          in all_facts left && all_facts right
        | _ -> false
      in
      if is_fact_here then Hashtbl.replace ctx.fact_locals name ();
      let is_proof_carrier_here =
        match value with
        | EApp _ ->
          let rec get_fn = function EApp { fn; _ } -> get_fn fn | e -> e in
          (match get_fn value with
           | EVar { name = fn_name; _ } ->
             (match Hashtbl.find_opt ctx.fn_return_specs fn_name with
              | Some (RetMaybeAttached { binding = b; _ }) when b.proof_ann <> None -> true
              | _ -> false)
           | _ -> false)
        | _ -> false
      in
      if is_proof_carrier_here then Hashtbl.replace ctx.proof_carrier_lets name ();
      let val_loc = Checker.expr_loc value in
      emit ctx (Printf.sprintf "(let ([%s (thsl-src! %S %d " name
        val_loc.Location.file (val_loc.Location.start.line + 1));
      emit_locals_list locals;
      emit ctx " (lambda () ";
      emit_expr ctx value;
      emit ctx "))]) ";
      (* Use *name so the next checkpoint's locals show the raw value. *)
      emit_debug_stmts ~locals:((name, star name) :: locals) body;
      if is_fact_here then Hashtbl.remove ctx.fact_locals name;
      if is_proof_carrier_here then Hashtbl.remove ctx.proof_carrier_lets name;
      emit ctx ")"
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let val_loc = Checker.expr_loc value in
      let tmp = Printf.sprintf "tesl_proof_binding_%d" ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      emit ctx (Printf.sprintf "(let ([%s (thsl-src! %S %d " tmp
        val_loc.Location.file (val_loc.Location.start.line + 1));
      emit_locals_list locals;
      emit ctx " (lambda () ";
      (* Preserve check-ok result for proof decomposition — match emit_with_raw_tail. *)
      (match direct_check_call value with
       | Some (check_fn, check_args) ->
         emit ctx "(";
         emit_expr ctx check_fn;
         List.iter (fun arg -> emit ctx " "; emit_expr_simple ctx arg) check_args;
         emit ctx ")"
       | None -> emit_expr ctx value);
      emit ctx (Printf.sprintf "))]) (let ([%s (forget-proof %s)] [%s (detach-all-proof %s)]) "
        value_name tmp proof_name tmp);
      emit_debug_stmts ~locals:((value_name, star value_name) :: locals) body;
      emit ctx "))"
    | other ->
      (* Terminal leaf of a peelable body: one checkpoint, release emission. *)
      emit_checkpoint_tail locals other
  in
  (* Record the body's emitted line range against the body's source span so a
     runtime trace into this function resolves to the body, refining the
     form-level entry recorded by emit_module's dispatch. *)
  sm_region ctx ~form:(Printf.sprintf "body of %s" fd.name) (Checker.expr_loc fd.body) (fun () ->
  if body_peelable fd.body then
    emit_debug_stmts ~locals:param_locals fd.body
  else
    (* Non-peelable: emit the whole body via the release path under one
       function-entry checkpoint (correct for SQL / special forms). *)
    emit_checkpoint_tail param_locals fd.body);
  ctx.func_kind <- old_kind;
  ctx.func_return_spec <- old_return_spec;
  ctx.auth_return_binding <- old_auth_return_binding;
  ctx.preserve_case_payload_names <- old_preserve_case_payload_names;
  emit_line ctx ")";
  emit_nl ctx

let emit_record ctx (r : record_form) =
  emit_line ctx (Printf.sprintf "(define-record %s" r.name);
  List.iter (fun (f : field_def) ->
    emit ctx (Printf.sprintf "  [%s : " f.name);
    emit_type_name ctx f.type_expr;
    (match f.proof_ann with
     | None -> ()
     | Some p ->
       emit ctx " ::: ";
       emit_proof_expr ctx p);
    emit_line ctx "]"
  ) r.fields;
  emit_line ctx ")";
  emit_nl ctx

let capitalize s =
  if String.length s = 0 then s
  else String.make 1 (Char.uppercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

let emit_entity ctx (e : entity_form) =
  emit_line ctx (Printf.sprintf "(define-entity %s" e.name);
  emit_line ctx "  #:source (make-hash)";
  emit_line ctx (Printf.sprintf "  #:table %s" e.table);
  emit_line ctx (Printf.sprintf "  #:primary-key %s" e.primary_key);
  List.iter (fun (f : field_def) ->
    (* proof-name: use proof annotation predicate if available, else capitalize field name *)
    let proof_name = match f.proof_ann with
      | Some (PredApp { pred; _ }) -> pred
      | Some (PredAnd _) -> capitalize f.name  (* conjunction — use capitalized name *)
      | None -> capitalize f.name
    in
    emit ctx (Printf.sprintf "  [%s %s : " proof_name f.name);
    emit_type_name ctx f.type_expr;
    (match f.db_type with
     | Some t -> emit ctx (Printf.sprintf " #:db-type %s" t)
     | None -> ());
    emit_line ctx "]"
  ) e.fields;
  emit_line ctx ")";
  emit_nl ctx

let emit_type_form ctx = function
  | TypeNewtype { name; base_type; _ } ->
    emit ctx (Printf.sprintf "(define-newtype %s " name);
    emit_type_name ctx base_type;
    emit_line ctx ")";
    emit_nl ctx
  | TypeAlias { name; base_type; _ } ->
    emit ctx (Printf.sprintf "(define-type-alias %s " name);
    emit_type_name ctx base_type;
    emit_line ctx ")";
    emit_nl ctx
  | TypeAdt { name; params; variants; _ } ->
    (* Parameterized ADT: (define-adt (Name a b) ...) vs simple (define-adt Name ...) *)
    if params = [] then
      emit_line ctx (Printf.sprintf "(define-adt %s" name)
    else
      emit_line ctx (Printf.sprintf "(define-adt (%s %s)" name (String.concat " " params));
    List.iter (fun (v : adt_variant) ->
      if v.fields = [] then
        emit_line ctx (Printf.sprintf "  [%s]" v.ctor)
      else begin
        emit ctx (Printf.sprintf "  [%s" v.ctor);
        List.iter (fun (f : field_def) ->
          emit ctx (Printf.sprintf " [%s : " f.name);
          emit_type_name ctx f.type_expr;
          emit ctx "]"
        ) v.fields;
        emit_line ctx "]"
      end
    ) variants;
    emit_line ctx ")";
    emit_nl ctx

let emit_capability ctx (c : capability_form) =
  (match c.implies with
  | [] -> emit_line ctx (Printf.sprintf "(define-capability %s)" c.name)
  | caps ->
    emit ctx (Printf.sprintf "(define-capability %s (implies " c.name);
    emit ctx (String.concat " " caps);
    emit_line ctx "))");
  emit_nl ctx

(** Emit encoder + decoder for an ADT whose variants are all zero-argument
    (a pure enum, e.g. IssueStatus = Backlog | Todo | InReview | ...).
    The JSON representation is the constructor name as a plain string. *)
let emit_adt_codec ctx (cf : codec_form) (variants : adt_variant list) =
  let ctors = List.map (fun (v : adt_variant) -> v.ctor) variants in
  (* Encoder: ADT value -> {"tag": "ConstructorName"} *)
  emit_line ctx (Printf.sprintf "(define (tesl-codec-encode-%s _v)" cf.name);
  emit_line ctx "  (define _raw (raw-value _v))";
  if ctors = [] then
    emit_line ctx (Printf.sprintf "  (error \"adtJson: no variants for type %s\"))" cf.name)
  else begin
    emit_line ctx "  (cond";
    List.iter (fun ctor ->
      emit_line ctx (Printf.sprintf "    [(equal? _raw %s) (hash \"tag\" %S)]" ctor ctor)
    ) ctors;
    emit_line ctx (Printf.sprintf "    [else (error (format \"%s: unexpected value ~~a\" _raw))]))" cf.name)
  end;
  (* Decoder: {"tag": "ConstructorName"} or plain string -> ADT value.
     Checks both string key "tag" and symbol key 'tag to handle both
     Elm (string keys) and api-test framework (symbol keys) formats. *)
  emit_line ctx (Printf.sprintf "(define (tesl-codec-decode-%s-0 _j)" cf.name);
  emit_line ctx "  (define _tag";
  emit_line ctx "    (cond [(hash? _j) (or (hash-ref _j \"tag\" #f) (hash-ref _j 'tag #f))]";
  emit_line ctx "          [(string? _j) _j]";
  emit_line ctx "          [else #f]))";
  emit_line ctx (Printf.sprintf "  (unless _tag (error (format \"%s: expected {{\\\"tag\\\": ...}} or string, got ~~a\" _j)))" cf.name);
  if ctors = [] then
    emit_line ctx (Printf.sprintf "  (error \"%s: no variants defined\"))" cf.name)
  else begin
    emit_line ctx "  (cond";
    List.iter (fun ctor ->
      emit_line ctx (Printf.sprintf "    [(equal? _tag %S) %s]" ctor ctor)
    ) ctors;
    let valid = String.concat ", " ctors in
    emit_line ctx (Printf.sprintf "    [else (error (format \"%s: expected one of %s, got ~~a\" _tag))]))" cf.name valid)
  end;
  emit_line ctx (Printf.sprintf "(register-type-codec! '%s tesl-codec-encode-%s (list tesl-codec-decode-%s-0))"
    cf.name cf.name cf.name);
  emit_nl ctx

let emit_codec ctx (cf : codec_form) =
  (* Emit encode function *)
  (match cf.to_json with
   | ToJsonForbidden ->
     emit_line ctx (Printf.sprintf "(define (tesl-codec-encode-%s _v)" cf.name);
     emit_line ctx (Printf.sprintf "  (error \"toJson is forbidden for type %s: this type cannot be JSON-encoded\"))" cf.name);
   | ToJsonFields entries ->
     emit_line ctx (Printf.sprintf "(define (tesl-codec-encode-%s _v)" cf.name);
     emit_line ctx "  (define _raw";
     emit_line ctx "    (let loop ([v _v])";
     emit_line ctx "      (cond [(named-value? v) (loop (named-value-value v))]";
     emit_line ctx "            [(check-ok? v) (loop (check-ok-value v))]";
     emit_line ctx "            [else v])))";
     emit_line ctx "  (define _fields (record-value-fields _raw))";
     emit ctx "  (hash ";
     List.iteri (fun i (e : codec_encode_entry) ->
       if i > 0 then emit ctx "\n        ";
       emit ctx (Printf.sprintf "'%s %s"
         e.json_key (codec_encode_field_call e.codec e.field_name))
     ) entries;
     emit_line ctx "\n  ))";
   | ToJsonAdt -> () (* handled by emit_adt_codec; should not reach here *)
  );
  (* Emit decode function(s) *)
  (match cf.from_json with
   | FromJsonForbidden ->
     let decodes = "(list )" in
     emit_line ctx (Printf.sprintf "(register-type-codec! '%s tesl-codec-encode-%s %s)"
       cf.name cf.name decodes)
   | FromJsonAdt -> () (* handled by emit_adt_codec; should not reach here *)
   | FromJsonAlts alts ->
     List.iteri (fun i alt ->
       emit_line ctx (Printf.sprintf "(define (tesl-codec-decode-%s-%d _j)" cf.name i);
       List.iter (function
         | DecodeField { field_name; json_key; codec; via = []; _ } ->
           emit_line ctx (Printf.sprintf "  (define _f_%s %s)"
             field_name (codec_decode_field_call codec json_key))
         | DecodeField { field_name; json_key; codec; via = [via_fn]; _ } ->
           (* Via checker: decode raw then apply checker *)
           let r_var = Printf.sprintf "_r1_%s" field_name in
           emit_line ctx (Printf.sprintf "  (define _fraw_%s %s)"
             field_name (codec_decode_field_call codec json_key));
           emit_line ctx (Printf.sprintf "  (define %s" r_var);
           emit_line ctx (Printf.sprintf "    (let ([_r (%s _fraw_%s)])" via_fn field_name);
           emit_line ctx "      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))";
           emit_line ctx (Printf.sprintf "  (define _f_%s" field_name);
           emit_line ctx (Printf.sprintf "    (if (check-ok? %s)" r_var);
           emit_line ctx (Printf.sprintf "        (ensure-named '%s (check-ok-value %s) (check-ok-facts %s) (check-ok-bindings %s) #:subject '%s)"
             field_name r_var r_var r_var field_name);
           emit_line ctx (Printf.sprintf "        %s))" r_var)
         | DecodeField { field_name; json_key; codec; via = via_fns; _ } ->
           (* Multiple via checkers: compose with check-and *)
           let combined_via = List.fold_right (fun fn acc ->
             match acc with
             | None -> Some fn
             | Some rest -> Some (Printf.sprintf "(check-and %s %s)" fn rest)
           ) via_fns None in
           (match combined_via with
            | None ->
              emit_line ctx (Printf.sprintf "  (define _f_%s %s)"
                field_name (codec_decode_field_call codec json_key))
            | Some combined ->
              let r_var = Printf.sprintf "_r1_%s" field_name in
              emit_line ctx (Printf.sprintf "  (define _fraw_%s %s)"
                field_name (codec_decode_field_call codec json_key));
              emit_line ctx (Printf.sprintf "  (define %s" r_var);
              emit_line ctx (Printf.sprintf "    (let ([_r (%s _fraw_%s)])" combined field_name);
              emit_line ctx "      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))";
              emit_line ctx (Printf.sprintf "  (define _f_%s" field_name);
              emit_line ctx (Printf.sprintf "    (if (check-ok? %s)" r_var);
              emit_line ctx (Printf.sprintf "        (ensure-named '%s (check-ok-value %s) (check-ok-facts %s) (check-ok-bindings %s) #:subject '%s)"
                field_name r_var r_var r_var field_name);
              emit_line ctx (Printf.sprintf "        %s))" r_var))
         | DecodeDefault { field_name; default_expr; _ } ->
           emit_line ctx (Printf.sprintf "  (define _f_%s %s)" field_name default_expr)
         | DecodeCrossCheck _ -> ()  (* handled below *)
       ) alt;
       let cross_checks = List.filter_map (function
         | DecodeCrossCheck { checker; _ } -> Some checker
         | _ -> None
       ) alt in
       let field_names = List.filter_map (function
         | DecodeField { field_name; _ } | DecodeDefault { field_name; _ } ->
           Some field_name
         | DecodeCrossCheck _ -> None
       ) alt in
       let via_fields = List.filter_map (function
         | DecodeField { field_name; via = (_ :: _); _ } -> Some field_name
         | _ -> None
       ) alt in
       if via_fields <> [] then begin
         (* Emit error-checking before record construction *)
         emit ctx "  (or ";
         List.iteri (fun i fn ->
           if i > 0 then emit ctx " ";
           emit ctx (Printf.sprintf "(and (check-fail? _f_%s) _f_%s)" fn fn)
         ) via_fields;
         emit_nl ctx;
         emit ctx "      "
       end else
         emit ctx "  ";
       (* Emit cross-check wrapper if present (inside or, wrapping record-value) *)
       (match cross_checks with
        | [checker] ->
          emit ctx (Printf.sprintf "(let ([_cross_check_result (%s" checker);
          List.iter (fun fn -> emit ctx (Printf.sprintf " _f_%s" fn)) field_names;
          emit_line ctx ")])";  (* close checker call + let binding *)
          emit_line ctx "        (if (check-fail? _cross_check_result)";
          emit_line ctx "            _cross_check_result";
          emit ctx "            "
        | _ -> ());
       emit ctx (Printf.sprintf "(record-value '%s (hash " cf.name);
       List.iteri (fun i fn ->
         if i > 0 then emit ctx " ";
         emit ctx (Printf.sprintf "'%s _f_%s" fn fn)) field_names;
       (* Count closing parens: hash(1) + record-value(1) + fn_define(1) + or(via) + let+if(cross) *)
       let extra_close = (if via_fields <> [] then 1 else 0) + (if cross_checks <> [] then 2 else 0) in
       emit_line ctx (String.make (3 + extra_close) ')');
     ) alts;
     let decode_list = String.concat " "
       (List.mapi (fun i _ -> Printf.sprintf "tesl-codec-decode-%s-%d" cf.name i) alts) in
     emit_line ctx (Printf.sprintf "(register-type-codec! '%s tesl-codec-encode-%s (list %s))"
       cf.name cf.name decode_list)
  );
  emit_nl ctx

(** Convert a postgres value like env("VAR") to Racket (tesl-env-raw "VAR") *)
let emit_postgres_value ctx v =
  let strip_parens s =
    let n = String.length s in
    if n >= 2 && s.[0] = '"' && s.[n-1] = '"' then String.sub s 1 (n-2)
    else s
  in
  if String.length v >= 4 && String.sub v 0 4 = "env(" then begin
    let inner = String.sub v 4 (String.length v - 5) in
    let var_name = strip_parens inner in
    emit ctx (Printf.sprintf "(tesl-env-raw %S)" var_name)
  end else if String.length v >= 7 && String.sub v 0 7 = "envInt(" then begin
    (* envInt("VAR", default) *)
    let inner = String.sub v 7 (String.length v - 8) in
    (match String.split_on_char ',' inner with
     | [var; def] ->
       let var_name = strip_parens (String.trim var) in
       let def_val = String.trim def in
       emit ctx (Printf.sprintf "(tesl-env-int-raw %S %s)" var_name def_val)
     | _ ->
       emit ctx (Printf.sprintf "(tesl-env-raw %S)" inner))
  end else if String.length v >= 10 && String.sub v 0 10 = "envString(" then begin
    (* envString("VAR", "default") *)
    let inner = String.sub v 10 (String.length v - 11) in
    (match String.split_on_char ',' inner with
     | var :: rest ->
       let var_name = strip_parens (String.trim var) in
       let def_val  = strip_parens (String.trim (String.concat "," rest)) in
       emit ctx (Printf.sprintf "(tesl-env-string-raw %S %S)" var_name def_val)
     | _ -> emit ctx (Printf.sprintf "(tesl-env-raw %S)" inner))
  end else begin
    (* Check if value is a plain integer *)
    let is_int = String.length v > 0 && String.for_all (fun c -> c >= '0' && c <= '9') v in
    if is_int then emit ctx v
    else emit ctx (Printf.sprintf "%S" v)
  end

(** Map postgres key names to Racket keyword names *)
let postgres_key_to_racket = function
  | "database" -> "database"
  | "user" -> "user"
  | "password" -> "password"
  | "host" -> "server"
  | "port" -> "port"
  | "socket" -> "socket"
  | other -> other

let emit_database ctx (d : database_form) =
  emit_line ctx (Printf.sprintf "(define-database %s" d.name);
  if d.postgres = [] then begin
    (* Memory backend — no connection params *)
    emit_line ctx "  #:backend memory";
    if d.schema <> "" then
      emit_line ctx (Printf.sprintf "  #:schema %s" d.schema)
  end else begin
    emit_line ctx "  #:backend postgres";
    (* Emit postgres connection params as #:key (tesl-env-raw "VAR") *)
    List.iter (fun (k, v) ->
      let rk = postgres_key_to_racket k in
      emit ctx (Printf.sprintf "  #:%s " rk);
      emit_postgres_value ctx v;
      emit_nl ctx
    ) d.postgres;
    if d.schema <> "" then
      emit_line ctx (Printf.sprintf "  #:schema %s" d.schema)
  end;
  (* Always emit #:entities — with trailing space when empty *)
  emit ctx "  #:entities";
  List.iter (fun e -> emit ctx (Printf.sprintf " %s" e)) d.entities;
  if d.entities = [] then emit_line ctx " )" else emit_line ctx ")";
  emit_nl ctx

let emit_capture ctx (c : capture_form) =
  emit_line ctx (Printf.sprintf "(define-capture %s" c.name);
  emit ctx "  [";
  emit ctx c.binding.name;
  emit ctx " : ";
  emit_type_name ctx c.binding.type_expr;
  (match c.binding.proof_ann with
   | Some p -> emit ctx " ::: "; emit_proof_expr ctx p
   | None -> ());
  let parser_fn = match c.parser with
    | "stringCodec" -> "string-segment"
    | "intCodec"    -> "integer-segment"
    | other         -> other
  in
  emit ctx (Printf.sprintf "]
  #:parser %s" parser_fn);
  (match c.checker with
   | Some checker -> emit_line ctx (Printf.sprintf " #:check %s)" checker)
   | None -> emit_line ctx ")");
  emit_nl ctx

let emit_sse_route ctx (ep : api_endpoint) =
  emit ctx "(list (list";
  let path_parts = String.split_on_char '/' ep.path |> List.filter (fun s -> s <> "" && s.[0] <> ':') in
  List.iter (fun part ->
    emit ctx " ";
    emit ctx (Printf.sprintf "%S" part)
  ) path_parts;
  emit ctx ") ";
  (match ep.auth with
   | Some auth -> emit ctx auth.via_fn
   | None -> emit ctx "#f");
  emit ctx " ";
  (match ep.subscribes with
   | channel_name :: _ -> emit ctx channel_name
   | [] -> emit ctx "#f");
  emit ctx ")"

let rec emit_api ctx ?(server_name="") ?(server_bindings=[]) (api : api_form) =
  let http_endpoints = List.filter (fun (ep : api_endpoint) -> ep.method_ <> SSE) api.endpoints in
  let sse_endpoints = List.filter (fun (ep : api_endpoint) -> ep.method_ = SSE) api.endpoints in
  let sse_name = if server_name <> "" then server_name else api.name ^ "Server" in
  if sse_endpoints = [] then
    emit_line ctx (Printf.sprintf "(define %s-sse-routes '())" sse_name)
  else begin
    emit_line ctx (Printf.sprintf "(define %s-sse-routes" sse_name);
    emit ctx "  (list";
    List.iter (fun ep -> emit ctx " "; emit_sse_route ctx ep) sse_endpoints;
    emit_line ctx "))"
  end;
  emit_line ctx (Printf.sprintf "(define-api %s" api.name);
  let endpoint_names =
    if List.length server_bindings = List.length http_endpoints then
      List.map fst server_bindings
    else
      List.mapi (fun i _ -> Printf.sprintf "endpoint%d" (i + 1)) http_endpoints
  in
  List.iteri (fun i (ep : api_endpoint) ->
    let handler_name = match List.nth_opt endpoint_names i with
      | Some name -> name
      | None -> ep.name
    in
    emit ctx (Printf.sprintf "  [%s :" handler_name);
    (match ep.auth with
     | Some auth ->
       emit ctx "
    (Auth [";
       emit ctx auth.binding.name;
       emit ctx " : ";
       emit_type_name ctx auth.binding.type_expr;
       (match auth.binding.proof_ann with
        | Some p -> emit ctx " ::: "; emit_proof_expr ctx p
        | None -> ());
       emit ctx (Printf.sprintf "] #:via %s)" auth.via_fn)
     | None -> ());
    let path_parts = String.split_on_char '/' ep.path |> List.filter (fun s -> s <> "") in
    List.iteri (fun idx part ->
      if String.length part > 0 && part.[0] = ':' then begin
        let cap_name = String.sub part 1 (String.length part - 1) in
        let cap = List.find_opt (fun (c : api_capture) -> c.binding.name = cap_name) ep.captures in
        let cap_via, cap_ty = match cap with
          | Some c -> c.via_fn, c.binding.type_expr
          | None -> cap_name ^ "Capture", TName { name = "String"; loc = ep.loc }
        in
        emit ctx (Printf.sprintf "
    :> (Capture %s [%s : " cap_via cap_name);
        emit_type_name ctx cap_ty;
        (match cap with
         | Some c ->
           (match c.binding.proof_ann with
            | Some p -> emit ctx " ::: "; emit_proof_expr ctx p
            | None -> ())
         | None -> ());
        emit ctx "])"
      end else if ep.auth <> None || idx > 0 then
        emit ctx (Printf.sprintf "
    :> %S" part)
      else
        emit ctx (Printf.sprintf "
    %S" part)
    ) path_parts;
    (match ep.body with
     | Some b ->
       emit ctx "
    :> (ReqBody JSON [";
       emit ctx b.name;
       emit ctx " : ";
       (* Detect `Type from WireType` pattern in type expr:
          TApp { head = TApp { head = Type; arg = TName "from" }; arg = WireType }
          → emit as `Type #:wire WireType #:decoder DecoderFn` *)
       let (actual_type, wire_opt) = match b.type_expr with
         | TApp { head = TApp { head = base_ty; arg = TVar { name = "from"; _ }; _ };
                  arg = wire_ty; _ }
         | TApp { head = TApp { head = base_ty; arg = TName { name = "from"; _ }; _ };
                  arg = wire_ty; _ } ->
           (base_ty, Some wire_ty)
         | other -> (other, None)
       in
       emit_type_name ctx actual_type;
       emit ctx "]";
       (* Emit #:wire and #:decoder OUTSIDE the binding brackets *)
       (match wire_opt with
        | Some wire_ty ->
          emit ctx " #:wire ";
          emit_type_name ctx wire_ty;
          (match ep.body_via with
           | Some via_fn -> emit ctx (Printf.sprintf " #:decoder %s" via_fn)
           | None ->
             match ep.body_decoder with
             | Some decoder -> emit ctx (Printf.sprintf " #:decoder %s" decoder)
             | None -> ())
        | None ->
          (* Also handle body_wire_type set directly *)
          (match ep.body_wire_type with
           | Some wire ->
             emit ctx (Printf.sprintf " #:wire %s" wire);
             (match ep.body_decoder with
              | Some decoder -> emit ctx (Printf.sprintf " #:decoder %s" decoder)
              | None -> ())
           | None -> ()));
       emit ctx ")"
     | None -> ());
    (* Emit Response spec if there's a wire response type or response encoder *)
    (match ep.response_wire_type, ep.response_encoder with
     | Some wire_type, encoder_opt ->
       emit ctx "
    :> (Response JSON ";
       emit ctx wire_type;
       (match encoder_opt with
        | Some enc -> emit ctx (Printf.sprintf " #:encoder %s" enc)
        | None -> ());
       emit ctx ")"
     | None, Some enc ->
       (* Response encoder without separate wire type *)
       emit ctx "
    :> (Response JSON ";
       emit_return_spec_type ctx ep.return_spec;
       emit ctx (Printf.sprintf " #:encoder %s)" enc)
     | None, None -> ());
    let method_str = match ep.method_ with
      | GET -> "Get" | POST -> "Post" | PUT -> "Put"
      | DELETE -> "Delete" | PATCH -> "Patch"
      | SSE -> failwith (Printf.sprintf
          "emit_racket: SSE endpoint '%s' passed to HTTP route emitter — SSE endpoints must be handled by emit_sse_route and filtered out before emit_api iterates http_endpoints (compiler bug)" ep.name)
    in
    emit ctx "
    :> (";
    emit ctx method_str;
    emit ctx " JSON ";
    emit_return_spec_type ctx ep.return_spec;
    emit_line ctx ")";
    emit_line ctx "    ]"
  ) http_endpoints;
  emit_line ctx ")";
  emit_nl ctx
and emit_return_spec_type ctx = function
  | RetPlain { ty; _ } -> emit_type_name ctx ty
  | RetAttached { binding = b; _ } ->
    emit ctx "[";
    emit ctx b.name;
    emit ctx " : ";
    emit_type_name ctx b.type_expr;
    (match b.proof_ann with
     | Some p -> emit ctx " ::: "; emit_proof_expr ctx p
     | None -> ());
    emit ctx "]"
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    emit_named_pack_spec ctx ty entity_proof other_proof
  | RetForAll { elem_ty; _ } ->
    emit ctx "(List "; emit_type_name ctx elem_ty; emit ctx ")"
  | RetMaybeForAll { elem_ty; _ } ->
    emit ctx "(Maybe (List "; emit_type_name ctx elem_ty; emit ctx "))"
  | RetSetForAll { elem_ty; _ } ->
    emit ctx "(Set "; emit_type_name ctx elem_ty; emit ctx ")"
  | RetMaybeSetForAll { elem_ty; _ } ->
    emit ctx "(Maybe (Set "; emit_type_name ctx elem_ty; emit ctx "))"
  | RetForAllDictValues { key_ty; val_ty; _ }
  | RetForAllDictKeys   { key_ty; val_ty; _ } ->
    emit ctx "(Dict "; emit_type_name ctx key_ty; emit ctx " ";
    emit_type_name ctx val_ty; emit ctx ")"
  | RetMaybeAttached { outer_ty = Some oty; _ } ->
    emit_type_name ctx oty
  | RetMaybeAttached { binding = b; _ } ->
    emit ctx "(Maybe "; emit_type_name ctx b.type_expr; emit ctx ")"
  | RetExists { binding = b; body; _ } ->
    emit ctx "(Exists [";
    emit ctx b.name;
    emit ctx " : ";
    emit_type_name ctx b.type_expr;
    emit ctx "] ";
    (match body with
     | RetPlain { ty; _ } -> emit_type_name ctx ty
     | RetAttached { binding = rb; _ } ->
       emit ctx "[";
       emit ctx rb.name;
       emit ctx " : ";
       emit_type_name ctx rb.type_expr;
       (match rb.proof_ann with
        | Some p -> emit ctx " ::: "; emit_proof_expr ctx p
        | None -> ());
       emit ctx "]"
     | RetNamedPack { ty; entity_proof; other_proof; _ } ->
       emit_named_pack_spec ctx ty entity_proof other_proof
     | _ -> emit_return_spec_type ctx body);
    emit ctx ")"

let emit_server ctx (sv : server_form) =
  emit_line ctx (Printf.sprintf "(define-server %s" sv.name);
  emit_line ctx (Printf.sprintf "  #:api %s" sv.api_name);
  List.iter (fun (ep, handler) ->
    emit_line ctx (Printf.sprintf "  [%s %s]" ep handler)
  ) sv.bindings;
  emit_line ctx ")";
  emit_nl ctx

(* ── Declarative agent block ────────────────────────────────────────────────
   Lowers `agent X requires [...] = Agent { provider, model, apiKey, systemPrompt,
   tools: [fn...], maxTokens }` to a runtime agent value built from the existing
   Tesl.Agent library constructors (defineAgent + withTools + tool).  Each tool is a
   typed Tesl function: its JSON Schema is DERIVED from the parameter types, and the
   model's tool-call arguments are decoded into the function's positional parameters
   under the hood — no hand-written schema string or validator. *)

(* base type -> the type tag tesl-agent-decode-args understands (None = unsupported) *)
let agent_arg_type_tag (t : Ast.type_expr) : string option =
  match t with
  | TName { name = "String"; _ }      -> Some "string"
  | TName { name = "Int"; _ }         -> Some "int"
  | TName { name = "PosixMillis"; _ } -> Some "int"
  | TName { name = "Float"; _ }       -> Some "float"
  | TName { name = "Bool"; _ }        -> Some "bool"
  | _                                 -> None

(* base type -> JSON Schema property fragment *)
let agent_arg_schema_prop (t : Ast.type_expr) : string =
  match t with
  | TName { name = "Int"; _ } | TName { name = "PosixMillis"; _ } -> {|{"type":"integer"}|}
  | TName { name = "Float"; _ } -> {|{"type":"number"}|}
  | TName { name = "Bool"; _ }  -> {|{"type":"boolean"}|}
  | _ -> {|{"type":"string"}|}

(* JSON Schema object string derived from a tool function's parameter list *)
let agent_tool_schema_json (params : Ast.binding list) : string =
  let props = List.map (fun (b : Ast.binding) ->
    Printf.sprintf "%S:%s" b.name (agent_arg_schema_prop b.type_expr)) params in
  let required = List.map (fun (b : Ast.binding) -> Printf.sprintf "%S" b.name) params in
  Printf.sprintf {|{"type":"object","properties":{%s},"required":[%s]}|}
    (String.concat "," props) (String.concat "," required)

let emit_agent ctx (decls : Ast.top_decl list) (a : Ast.agent_form) =
  let find_fn name =
    List.find_map (function Ast.DFunc fd when fd.name = name -> Some fd | _ -> None) decls in
  let emit_provider () =
    let kind = if a.provider = "" then "anthropic" else a.provider in
    match kind with
    | "local" ->
      emit ctx "(__tart_local "; emit_postgres_value ctx a.endpoint;
      emit ctx " "; emit_postgres_value ctx a.model; emit ctx ")"
    | "openai" ->
      emit ctx "(__tart_openai "; emit_postgres_value ctx a.api_key;
      emit ctx " "; emit_postgres_value ctx a.model; emit ctx ")"
    | "mistral" ->
      emit ctx "(__tart_mistral "; emit_postgres_value ctx a.api_key;
      emit ctx " "; emit_postgres_value ctx a.model; emit ctx ")"
    | _ ->
      emit ctx "(__tart_anthropic "; emit_postgres_value ctx a.api_key;
      emit ctx " "; emit_postgres_value ctx a.model; emit ctx ")"
  in
  emit_line ctx (Printf.sprintf "(define %s" a.name);
  emit ctx "  (__tart_withTools (__tart_defineAgent ";
  emit_provider ();
  emit ctx (Printf.sprintf " %S %d)" a.system_prompt a.max_tokens);
  emit_nl ctx;
  emit ctx "    (list";
  List.iter (fun tool_name ->
    match find_fn tool_name with
    | None -> ()  (* validation has already reported the missing tool *)
    | Some fd ->
      let schema = agent_tool_schema_json fd.params in
      (* The tool description is the fn's harvested doc-comment, else its name. *)
      let desc = match fd.doc with Some d when String.trim d <> "" -> d | _ -> tool_name in
      emit_nl ctx;
      emit ctx (Printf.sprintf "      (__tart_tool %S %S %S" tool_name desc schema);
      emit_nl ctx;
      (* validator: decode the model's args JSON into the fn's positional params *)
      emit ctx "        (lambda (_args) (__tart_tesl-agent-decode-args _args (list";
      List.iter (fun (b : Ast.binding) ->
        match agent_arg_type_tag b.type_expr with
        | Some tag -> emit ctx (Printf.sprintf " (cons %S '%s)" b.name tag)
        | None -> ()) fd.params;
      emit ctx ")))";
      emit_nl ctx;
      (* dispatch: apply the typed Tesl function; the loop stringifies the result *)
      emit ctx (Printf.sprintf "        (lambda (_decoded) (apply %s _decoded)))" tool_name)
  ) a.tools;
  emit_line ctx ")))";
  emit_nl ctx

let emit_test ctx (t : test_form) =
  Hashtbl.clear ctx.proof_locals;
  let property_runs = match t.runs with Some n -> n | None -> 200 in
  let rec proof_datum = function
    | PredApp { pred; args; _ } ->
      let arg_parts = List.map (fun arg -> Printf.sprintf "'%s" arg) args in
      Printf.sprintf "(list '%s%s)" pred
        (if arg_parts = [] then "" else " " ^ String.concat " " arg_parts)
    | PredAnd { left; right; _ } ->
      Printf.sprintf "(list %s '&& %s)" (proof_datum left) (proof_datum right)
  in
  (* Returns Some generator_expr if we can guarantee the generated value satisfies the proof,
     None if the predicate is unknown (don't attach proof — avoids fabricating false proofs). *)
  let rec proof_aware_generator ty proof =
    match ty, proof with
    | TName { name = ("Int" | "Integer"); _ }, PredApp { pred; _ } ->
      let pred_lc = String.lowercase_ascii pred in
      if pred_lc = "ispositive" then Some "(+ 1 (random 1000000))"
      else if pred_lc = "isnonnegative" || pred_lc = "nonnegative" || pred_lc = "non_negative" then
        Some "(random 1000000)"
      else if pred_lc = "nonzero" || pred_lc = "isnonzero" || pred_lc = "non_zero" then
        Some "(let ([v (- (random 2000001) 1000000)]) (if (= v 0) 1 v))"
      else None
    | _, _ -> None
  and random_expr_for_type ty =
    match ty with
    | TName { name = ("Int" | "Integer"); _ } -> "(- (random 2000001) 1000000)"
    | TName { name = "Bool"; _ } -> "(zero? (random 2))"
    | TName { name = "String"; _ } -> "(format \"s~a\" (random 1000000))"
    | TApp { head = TName { name = "List"; _ }; arg = elem_ty; _ } ->
      (* Generate a random-length list (0–7 elements) of the element type *)
      let elem_gen = random_expr_for_type elem_ty in
      Printf.sprintf "(map (lambda (_) %s) (make-list (random 8) #f))" elem_gen
    | TApp { head = TName { name = "Maybe"; _ }; arg = elem_ty; _ } ->
      let elem_gen = random_expr_for_type elem_ty in
      Printf.sprintf "(if (zero? (random 2)) (Nothing) (Something %s))" elem_gen
    | TName { name = type_name; _ } ->
      (match List.find_opt (fun (n, _, _) -> n = type_name) ctx.record_meta with
       | Some (_, fields, _invariant) ->
         let has_proofs = List.exists (fun (f : Ast.field_def) -> f.proof_ann <> None) fields in
         if has_proofs then
           let let_bindings, parts = List.fold_left (fun (bindings, parts) (field : Ast.field_def) ->
             let tmp = "tesl_gen_" ^ field.name in
             let raw_gen, proof_expr_opt = match field.proof_ann with
               | Some proof ->
                 (match proof_aware_generator field.type_expr proof with
                  | Some gen -> gen, Some (proof_datum proof)   (* known predicate: gen satisfies proof *)
                  | None ->
                    random_expr_for_type field.type_expr, None) (* unknown: don't fabricate proof *)
               | None -> random_expr_for_type field.type_expr, None
             in
             let part = match proof_expr_opt with
               | Some pd ->
                 Printf.sprintf "#:%s (tesl-test-proof-field '%s %s %s)" field.name field.name tmp pd
               | None -> Printf.sprintf "#:%s %s" field.name tmp
             in
             (bindings @ [Printf.sprintf "[%s %s]" tmp raw_gen], parts @ [part])
           ) ([], []) fields in
           Printf.sprintf "(let (%s) (%s %s))"
             (String.concat " " let_bindings)
             type_name
             (String.concat " " parts)
         else
           let parts = List.map (fun (field : Ast.field_def) ->
             Printf.sprintf "#:%s %s" field.name (random_expr_for_type field.type_expr)
           ) fields in
           Printf.sprintf "(%s %s)" type_name (String.concat " " parts)
       | None -> "0")
    | _ -> "0"
  in
  let param_needs_retry (p : property_param) =
    match p.binding.type_expr with
    | TName { name; _ } ->
      (match List.find_opt (fun (n, _, _) -> n = name) ctx.record_meta with
       | Some (_, _, Some _) -> true
       | Some (_, fields, None) -> List.exists (fun (f : Ast.field_def) -> f.proof_ann <> None) fields
       | _ -> false)
    | _ -> false
  in
  let generator_expr (p : property_param) =
    match p.generator with
    | Some gen -> Printf.sprintf "(%s tesl-prop-i)" gen
    | None -> random_expr_for_type p.binding.type_expr
  in
  let emit_property_guard clauses =
    match clauses with
    | [] -> ()
    | [cond] -> emit_expr ctx cond
    | conds ->
      emit ctx "(and ";
      List.iteri (fun i cond ->
        if i > 0 then emit ctx " ";
        emit_expr ctx cond
      ) conds;
      emit ctx ")"
  in
  (* locals: (display-name, racket-name) pairs accumulated from prior let bindings *)
  let rec emit_test_stmt ?(locals=[]) indent stmt =
    match stmt with
    | TsLet { name; value = (EApp _ as check_app); _ } when (let rec find_check = function
         | EApp { fn = EVar { name = "check"; _ }; _ } -> true
         | EApp { fn; _ } -> find_check fn
         | _ -> false
       in find_check check_app) ->
      let binding_name =
        if String.equal name "_" then begin
          let n = ctx.case_counter in
          ctx.case_counter <- ctx.case_counter + 1;
          Printf.sprintf "tesl_ignored_%d" n
        end else
          name
      in
      let tmp = Printf.sprintf "tesl_checked_%d" ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      let rec collect_check_args acc = function
        | EApp { fn = EVar { name = "check"; _ }; arg; _ } -> (arg, acc)
        | EApp { fn; arg; _ } -> collect_check_args (arg :: acc) fn
        | e -> (e, List.rev acc)
      in
      let fn_expr, args = collect_check_args [] check_app in
      (* Keep the original check-ok so later proof-sensitive uses preserve the
         checker-produced GDP subject instead of manufacturing a fresh one. *)
      emit ctx indent;
      emit ctx (Printf.sprintf "(define %s (" tmp);
      emit_expr ctx fn_expr;
      List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) args;
      emit_line ctx "))";
      emit_line ctx (Printf.sprintf "%s(when (check-fail? %s)" indent tmp);
      emit_line ctx (Printf.sprintf "%s  (raise-user-error 'tesl-test \"unexpected failure in let %s: ~a\" (check-fail-message %s)))" indent binding_name tmp);
      emit ctx indent;
      emit ctx (Printf.sprintf "(define %s %s)" binding_name tmp);
      emit_nl ctx;
      Hashtbl.replace ctx.proof_locals binding_name ()
    | TsLetProof { value_name; proof_names; value; _ } ->
      (* Proof destructuring: let (x ::: p) = expr
         → (define tmp (expr))
           (when (check-fail? tmp) (raise ...))
           (define x (forget-proof tmp))
           (define p (detach-all-proof tmp)) *)
      let tmp = Printf.sprintf "tesl_proof_bind_%d" ctx.case_counter in
      ctx.case_counter <- ctx.case_counter + 1;
      emit ctx indent;
      emit ctx (Printf.sprintf "(define %s " tmp);
      emit_expr ctx value;
      emit_line ctx ")";
      emit_line ctx (Printf.sprintf "%s(when (check-fail? %s)" indent tmp);
      emit_line ctx (Printf.sprintf "%s  (raise-user-error 'tesl-test \"unexpected failure in let-proof: ~a\" (check-fail-message %s)))" indent tmp);
      let vname = if String.equal value_name "_" then
        let n = ctx.case_counter in ctx.case_counter <- ctx.case_counter + 1;
        Printf.sprintf "tesl_ignored_%d" n
      else value_name in
      emit_line ctx (Printf.sprintf "%s(define %s (forget-proof %s))" indent vname tmp);
      List.iter (fun pname ->
        emit_line ctx (Printf.sprintf "%s(define %s (detach-all-proof %s))" indent pname tmp);
        Hashtbl.replace ctx.proof_locals pname ()
      ) proof_names
    | TsLet { name; value; loc; _ } ->
      let binding_name =
        if String.equal name "_" then begin
          let n = ctx.case_counter in
          ctx.case_counter <- ctx.case_counter + 1;
          Printf.sprintf "tesl_ignored_%d" n
        end else
          name
      in
      emit ctx indent;
      emit ctx (Printf.sprintf "(define %s " binding_name);
      emit ctx (Printf.sprintf "(thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list ctx locals;
      emit ctx " (lambda () ";
      emit_expr ctx value;
      emit ctx "))";
      emit_line ctx ")"
    | TsExpect { left = EBinop { op = BNeq; left = l; right = r; _ }; right = None; loc } ->
      emit ctx indent;
      emit ctx "(check-not-equal? ";
      emit ctx (Printf.sprintf "(thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list ctx locals;
      emit ctx " (lambda () ";
      emit_expr_simple ctx l;
      emit ctx ")) ";
      emit_expr_simple ctx r;
      emit_line ctx ")"
    | TsExpect { left = EBinop { op = (BLt | BLe | BGt | BGe | BEq | BAnd | BOr); _ } as cmp; right = None; loc } ->
      emit ctx indent;
      emit ctx "(check-true ";
      emit ctx (Printf.sprintf "(thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list ctx locals;
      emit ctx " (lambda () ";
      emit_expr ctx cmp;
      emit ctx "))";
      emit_line ctx ")"
    | TsExpect { left; right = None; loc } ->
      emit ctx indent;
      emit ctx "(check-true (raw-value ";
      emit ctx (Printf.sprintf "(thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list ctx locals;
      emit ctx " (lambda () ";
      emit_expr ctx left;
      emit ctx "))";
      emit_line ctx "))"
    | TsExpect { left; right = Some right; loc } ->
      emit ctx indent;
      let needs_raw = match left with
        | ELit _ -> false
        | EField _ -> false
        | _ -> true
      in
      if needs_raw then begin
        emit ctx "(check-equal? (raw-value ";
        emit ctx (Printf.sprintf "(thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
        emit_locals_list ctx locals;
        emit ctx " (lambda () ";
        emit_expr ctx left;
        emit ctx "))";
        emit ctx ") "
      end else begin
        emit ctx "(check-equal? ";
        emit ctx (Printf.sprintf "(thsl-src! %S %d " loc.Location.file (loc.Location.start.line + 1));
        emit_locals_list ctx locals;
        emit ctx " (lambda () ";
        emit_expr ctx left;
        emit ctx ")) "
      end;
      emit_expr ctx right;
      emit_line ctx ")"
    | TsExpectFail { fn; arg; loc } ->
      let rec flatten_args acc a = match a with
        | EApp { fn = base; arg = last; _ } -> flatten_args (last :: acc) base
        | _ -> a :: acc
      in
      let flat_args = flatten_args [] arg in
      let emit_expect_fail_call () =
        match fn, flat_args with
        | EVar { name = "check"; _ }, check_fn :: check_args ->
          emit ctx "(";
          emit_expr ctx check_fn;
          List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) check_args;
          emit ctx ")"
        | _ ->
          emit ctx "(";
          emit_expr ctx fn;
          List.iter (fun a -> emit ctx " "; emit_expr_simple ctx a) flat_args;
          emit ctx ")"
      in
      emit ctx indent;
      emit ctx (Printf.sprintf "(let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! %S %d "
        loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list ctx locals;
      emit_line ctx " (lambda ()";
      emit ctx (indent ^ "                        ");
      emit_expect_fail_call ();
      emit_line ctx ")))])";
      emit_line ctx (indent ^ "  (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))");
      let escape_for_str s = String.escaped s in
      let fn_buf = Buffer.create 32 in
      let args_buf = Buffer.create 64 in
      let fn_ctx = { ctx with buf = fn_buf } in
      let args_ctx = { ctx with buf = args_buf } in
      emit_expr fn_ctx fn;
      List.iteri (fun i a ->
        if i > 0 then Buffer.add_char args_buf ' ';
        emit_expr_simple args_ctx a
      ) flat_args;
      emit_line ctx (Printf.sprintf "%s              \"expected failure: %s %s\"))"
        indent
        (escape_for_str (Buffer.contents fn_buf))
        (escape_for_str (Buffer.contents args_buf)))
    | TsExpectHasProof { fn; arg; proof_name; loc } ->
      emit ctx indent;
      (* B5: always wrap in a 4-arg thsl-src! (file line locals thunk).  The
         former --debug branch emitted a 3-arg call (no locals) which would
         crash the runtime checkpoint; unified here with an empty locals list. *)
      emit ctx (Printf.sprintf "(let ([tesl-hpv (thsl-src! %S %d "
        loc.Location.file (loc.Location.start.line + 1));
      emit_locals_list ctx locals;
      emit ctx " (lambda () (";
      emit_expr ctx fn;
      emit ctx " ";
      emit_expr_simple ctx arg;
      emit_line ctx ")))])";
      emit_line ctx (indent ^ "  (check-true");
      emit_line ctx (indent ^ "    (for/or ([f (in-list (facts-of tesl-hpv))])");
      emit_line ctx (Printf.sprintf "%s      (and (pair? f) (eq? (car f) '%s)))" indent proof_name);
      emit_line ctx (Printf.sprintf "%s    \"expected result to carry proof %s\"))" indent proof_name)
    | TsProperty { description; params; body; _ } ->
      let guards = List.filter_map (fun (p : property_param) -> p.where_clause) params in
      let needs_retry = List.exists param_needs_retry params in
      emit_line ctx (Printf.sprintf "%s; property: %s" indent description);
      emit_line ctx (Printf.sprintf "%s(for ([tesl-prop-i (in-range %d)])" indent property_runs);
      if needs_retry then begin
        emit_line ctx (indent ^ "  (let tesl-retry ([tesl-attempts 0])");
        emit_line ctx (indent ^ "    (if (> tesl-attempts 100)");
        emit_line ctx (indent ^ "      (void) ; skip this iteration after too many retries");
        emit_line ctx (indent ^ "      (with-handlers ([exn:fail? (lambda (e) (tesl-retry (+ tesl-attempts 1)))])");
        emit ctx (indent ^ "        (let (")
      end else
        emit ctx (indent ^ "  (let (");
      List.iteri (fun i p ->
        if i > 0 then emit ctx " ";
        emit ctx (Printf.sprintf "[%s %s]" p.binding.name (generator_expr p))
      ) params;
      emit_line ctx ")";
      (match guards with
       | [] ->
         emit ctx (indent ^ (if needs_retry then "          (check-true " else "    (check-true "));
         emit_expr ctx body;
         emit_line ctx (Printf.sprintf " %S)" description)
       | _ ->
         emit ctx (indent ^ (if needs_retry then "          (when " else "    (when "));
         emit_property_guard guards;
         emit ctx " (check-true ";
         emit_expr ctx body;
         emit_line ctx (Printf.sprintf " %S))" description));
      if needs_retry then
        emit_line ctx (indent ^ "        )))))")
      else
        emit_line ctx (indent ^ "  ))")
    | TsIf { cond; then_stmts; else_stmts; _ } ->
      emit ctx indent;
      emit ctx "(if ";
      emit_expr ctx cond;
      emit_nl ctx;
      emit_line ctx (indent ^ "    (let ()");
      List.iter (emit_test_stmt (indent ^ "      ")) then_stmts;
      emit_line ctx (indent ^ "    )");
      emit_line ctx (indent ^ "    (let ()");
      List.iter (emit_test_stmt (indent ^ "      ")) else_stmts;
      emit_line ctx (indent ^ "    ))")
    | TsCase { scrut; arms; _ } ->
      let var = fresh_case ctx in
      (* Test-block context has no define/pow macro — bind *var directly. *)
      let star_var = "*" ^ var in
      emit ctx indent;
      emit_line ctx (Printf.sprintf "(let ([%s (raw-value " star_var);
      emit ctx (indent ^ "  ");
      emit_expr ctx scrut;
      emit_line ctx (Printf.sprintf ")]) (cond");
      List.iter (fun (arm : ts_case_arm) ->
        let raw_bound_names = match arm.ts_pattern with
          | PVar n -> [n]
          | PCon { fields; _ } ->
            let rec collect_names = function
              | PVar n when n <> "_" -> [n]
              | PCon { fields; _ } -> List.concat_map (fun (_, sub) -> collect_names sub) fields
              | _ -> []
            in
            List.concat_map (fun (_, sub_pat) -> collect_names sub_pat) fields
          | _ -> []
        in
        List.iter (fun n -> Hashtbl.replace ctx.raw_locals n ()) raw_bound_names;
        let pattern_guard, binding_code = pattern_to_racket ctx arm.ts_pattern star_var in
        let nested_let_str bindings body_str =
          List.fold_right
            (fun b acc -> Printf.sprintf "(let (%s) %s)" b acc)
            bindings body_str
        in
        let full_guard = match arm.ts_guard with
          | None -> pattern_guard
          | Some g ->
            let gbuf = Buffer.create 32 in
            let gctx = { ctx with buf = gbuf } in
            emit_expr gctx g;
            if binding_code = [] then Printf.sprintf "(and %s %s)" pattern_guard (Buffer.contents gbuf)
            else Printf.sprintf "(and %s %s)" pattern_guard
                   (nested_let_str binding_code (Buffer.contents gbuf))
        in
        emit ctx (indent ^ "  [");
        emit ctx full_guard;
        emit_nl ctx;
        let arm_indent = indent ^ "    " in
        if binding_code <> [] then begin
          (* Nested single-binding lets for sequential dependency correctness *)
          List.iter (fun b -> emit_line ctx (arm_indent ^ Printf.sprintf "(let (%s)" b)) binding_code;
          List.iter (emit_test_stmt (arm_indent ^ "  ")) arm.ts_body;
          List.iter (fun _ -> emit_line ctx (arm_indent ^ ")")) binding_code
        end else begin
          List.iter (emit_test_stmt arm_indent) arm.ts_body
        end;
        emit_line ctx (indent ^ "  ]");
        List.iter (fun n -> Hashtbl.remove ctx.raw_locals n) raw_bound_names
      ) arms;
      emit_line ctx (indent ^ "))")
    | TsExpr { e; _ } ->
      emit ctx indent;
      emit_expr ctx e;
      emit_nl ctx
  in
  (* Emit the test-case body — callers batch these into one (module+ test …) block.
     All DTest blocks for a file are batched together to avoid rackunit side-effects
     from multiple (require rackunit) calls in separate submodule fragments. *)
  emit_line ctx (Printf.sprintf "  (test-case %S" t.description);
  (* Optional `with database X` header clause binds X for the test body (queries run
     against X's configured backend).  Absent ⇒ the default in-memory store, in which
     case nothing extra is emitted (byte-identical to a test with no clause). *)
  (match t.database with
   | Some db -> emit_line ctx (Printf.sprintf "    (call-with-database %s (lambda ()" db)
   | None -> ());
  let body_indent = if t.capabilities = [] then "  " else "    " in
  if t.capabilities <> [] then
    emit_line ctx (Printf.sprintf "    (with-capabilities (%s)" (cap_list_str t.capabilities));
  (* Fold through stmts accumulating in-scope locals for the Variables panel *)
  let _ = List.fold_left (fun locals stmt ->
    emit_test_stmt ~locals body_indent stmt;
    (* After a user-named let binding, add it to locals for subsequent stmts.
       B5: always thread locals (the thsl-src! wrapper is now always emitted; the
       macro drops the locals list in release). *)
    match stmt with
    | TsLet { name; _ } when not (String.equal name "_")
                           && not (String.length name >= 5 && String.sub name 0 5 = "tesl_") ->
      (name, name) :: locals
    | TsLetProof { value_name; _ } ->
      (value_name, value_name) :: locals
    | _ -> locals
  ) [] t.stmts in
  if t.capabilities <> [] then emit_line ctx "    )";
  (match t.database with
   | Some _ -> emit_line ctx "    ))"   (* close (lambda () and (call-with-database *)
   | None -> ());
  emit_line ctx "  )"

type api_test_template_part =
  | ApiTestTemplateLiteral of string
  | ApiTestTemplateExpr of expr

let parse_api_test_template_expr expr_text =
  let text = String.trim expr_text in
  let tokens = Lexer.tokenize "<api-test-template>" text in
  let stream = Parser.make_stream "<api-test-template>" tokens in
  match Parser.parse_expr stream with
  | Ok e -> e
  | Err _ -> EVar { name = text; loc = Location.dummy_loc "<api-test-template>" }

let parse_api_test_template_content content =
  let len = String.length content in
  let parts = ref [] in
  let cursor = ref 0 in
  while !cursor < len do
    match String.index_from_opt content !cursor '{' with
    | None ->
      if !cursor < len then
        parts := ApiTestTemplateLiteral (String.sub content !cursor (len - !cursor)) :: !parts;
      cursor := len
    | Some open_brace ->
      if open_brace > !cursor then
        parts := ApiTestTemplateLiteral (String.sub content !cursor (open_brace - !cursor)) :: !parts;
      (match String.index_from_opt content (open_brace + 1) '}' with
       | None ->
         parts := ApiTestTemplateLiteral (String.sub content open_brace (len - open_brace)) :: !parts;
         cursor := len
       | Some close_brace ->
         let expr_text = String.sub content (open_brace + 1) (close_brace - open_brace - 1) in
         parts := ApiTestTemplateExpr (parse_api_test_template_expr expr_text) :: !parts;
         cursor := close_brace + 1)
  done;
  List.rev !parts

let rec emit_api_test_template_content ctx ~server_name ~capabilities ~helper_name content =
  let parts = parse_api_test_template_content content in
  match parts with
  | [] -> emit ctx "\"\""
  | [ApiTestTemplateLiteral s] -> emit ctx (Printf.sprintf "%S" s)
  | [ApiTestTemplateExpr e] ->
    emit ctx "(";
    emit ctx helper_name;
    emit ctx " ";
    emit_api_test_arg ctx ~server_name ~capabilities e;
    emit ctx ")"
  | _ ->
    emit ctx "(string-append";
    List.iter (function
      | ApiTestTemplateLiteral s ->
        emit ctx " ";
        emit ctx (Printf.sprintf "%S" s)
      | ApiTestTemplateExpr e ->
        emit ctx " (";
        emit ctx helper_name;
        emit ctx " ";
        emit_api_test_arg ctx ~server_name ~capabilities e;
        emit ctx ")"
    ) parts;
    emit ctx ")"

and emit_api_test_path ctx ~server_name ~capabilities e =
  match e with
  | ELit { lit = LString s; _ } ->
    emit ctx "(list";
    List.iter (fun part ->
      emit ctx " ";
      emit_api_test_template_content ctx ~server_name ~capabilities ~helper_name:"api-test-path-fragment" part
    ) (String.split_on_char '/' s |> List.filter (fun part -> part <> ""));
    emit ctx ")"
  | _ -> emit_expr ctx e

and emit_api_test_json ctx ~server_name ~capabilities e =
  match e with
  | ELit { lit = LString s; _ } ->
    emit_api_test_template_content ctx ~server_name ~capabilities ~helper_name:"api-test-string-fragment" s
  | ERecord { fields; _ } ->
    emit ctx "(hash";
    List.iter (fun (k, v) ->
      emit ctx " (string->symbol ";
      emit ctx (Printf.sprintf "%S" k);
      emit ctx ") ";
      emit_api_test_json ctx ~server_name ~capabilities v
    ) fields;
    emit ctx ")"
  | EList { elems; _ } ->
    emit ctx "(list";
    List.iter (fun elem -> emit ctx " "; emit_api_test_json ctx ~server_name ~capabilities elem) elems;
    emit ctx ")"
  | _ -> emit_expr ctx e

and emit_api_test_arg ctx ~server_name ~capabilities e =
  match e with
  | EVar { name; _ } when is_lower_ident name ->
    emit ctx "(raw-value ";
    emit_api_test_expr ctx ~server_name ~capabilities e;
    emit ctx ")"
  | EField _ ->
    emit ctx "(raw-value ";
    emit_api_test_expr ctx ~server_name ~capabilities e;
    emit ctx ")"
  | _ -> emit_api_test_expr ctx ~server_name ~capabilities e

and emit_api_test_expr ctx ~server_name ~capabilities e =
  match e with
  | ELit { lit = LString s; _ } ->
    emit_api_test_template_content ctx ~server_name ~capabilities ~helper_name:"api-test-string-fragment" s
  | EApp _ as app when (match extract_select_query app with Some _ -> true | None -> false) ->
    emit_expr ctx app
  | EApp _ as app when (match parse_insert_expr app with Some _ -> true | None -> false) ->
    emit_expr ctx app
  | EApp _ as app when (match parse_insert_many_expr app with Some _ -> true | None -> false) ->
    emit_expr ctx app
  | EApp _ as app when (match extract_delete_query app with Some _ -> true | None -> false) ->
    emit_expr ctx app
  | EBinop _ as sql_expr when (match extract_select_query sql_expr with Some _ -> true | None -> false) ->
    emit_expr ctx sql_expr
  | EBinop _ as sql_expr when (match extract_delete_query sql_expr with Some _ -> true | None -> false) ->
    emit_expr ctx sql_expr
  | EField { obj; field; _ } ->
    emit ctx "(api-test-field-access-ref ";
    emit_api_test_expr ctx ~server_name ~capabilities obj;
    emit ctx (Printf.sprintf " '%s)" field)
  | EApp _ ->
    let head, args = flatten_app [] e in
    (match head, args with
     | EVar { name; _ }, path :: rest when List.mem name ["get"; "post"; "put"; "delete"; "patch"] ->
       let rec scan cookie headers body = function
         | EVar { name = "cookie"; _ } :: v :: more -> scan (Some v) headers body more
         | EVar { name = "headers"; _ } :: v :: more -> scan cookie (Some v) body more
         | EVar { name = "body"; _ } :: v :: more -> scan cookie headers (Some v) more
         | _ :: more -> scan cookie headers body more
         | [] -> (cookie, headers, body)
       in
       let cookie, headers, body = scan None None None rest in
       emit ctx (Printf.sprintf "(dispatch-api-test-request %s '%s " server_name name);
       emit_api_test_path ctx ~server_name ~capabilities path;
       (match cookie with
        | Some cookie_expr -> emit ctx " #:cookie "; emit_api_test_expr ctx ~server_name ~capabilities cookie_expr
        | None -> ());
       emit ctx " #:headers ";
       (match headers with
        | Some headers_expr -> emit_api_test_json ctx ~server_name ~capabilities headers_expr
        | None -> emit ctx "(hash)");
       (match body with
        | Some body_expr -> emit ctx " #:body "; emit_api_test_json ctx ~server_name ~capabilities body_expr
        | None -> ());
       emit ctx " #:capabilities ";
       if capabilities = [] then emit ctx "'()"
       else emit ctx (Printf.sprintf "(list %s)" (cap_list_str capabilities));
       emit ctx ")"
     | EVar { name = "subscribe"; _ }, path :: rest ->
       let rec scan cookie headers = function
         | EVar { name = "cookie"; _ } :: v :: more -> scan (Some v) headers more
         | EVar { name = "headers"; _ } :: v :: more -> scan cookie (Some v) more
         | _ :: more -> scan cookie headers more
         | [] -> (cookie, headers)
       in
       let cookie, headers = scan None None rest in
       emit ctx (Printf.sprintf "(subscribe %s-sse-routes " server_name);
       emit_api_test_path ctx ~server_name ~capabilities path;
       (match cookie with
        | Some cookie_expr -> emit ctx " #:cookie "; emit_api_test_expr ctx ~server_name ~capabilities cookie_expr
        | None -> ());
       emit ctx " #:headers ";
       (match headers with
        | Some headers_expr -> emit_api_test_json ctx ~server_name ~capabilities headers_expr
        | None -> emit ctx "(hash)");
       emit ctx " #:name ";
       (match path with
        | ELit { lit = LString s; _ } -> emit ctx (Printf.sprintf "%S" s)
        | _ -> emit ctx "\"\"");
       emit ctx ")"
     | EVar { name = "collect"; _ }, stream :: rest ->
       let rec scan count timeout = function
         | EVar { name = "count"; _ } :: v :: more -> scan (Some v) timeout more
         | EVar { name = "timeout"; _ } :: v :: more -> scan count (Some v) more
         | _ :: more -> scan count timeout more
         | [] -> (count, timeout)
       in
       let count, timeout = scan None None rest in
       emit ctx "(collect ";
       emit_api_test_arg ctx ~server_name ~capabilities stream;
       (match count with
        | Some count_expr -> emit ctx " #:count "; emit_api_test_expr ctx ~server_name ~capabilities count_expr
        | None -> ());
       (match timeout with
        | Some timeout_expr -> emit ctx " #:timeout-ms "; emit_api_test_expr ctx ~server_name ~capabilities timeout_expr
        | None -> ());
       emit ctx ")"
     | _ ->
       emit ctx "(";
       (match head with
        | EVar { name; _ } -> emit ctx (resolve_name name)
        | EField { obj = EConstructor { name = modname; _ }; field; _ } ->
          let full = modname ^ "." ^ field in
          let renamed = match Hashtbl.find_opt qualified_imports full with
            | Some r -> r
            | None -> import_rename full
          in
          emit ctx renamed
        | EConstructor { name; _ } -> emit ctx name
        | _ -> emit_api_test_expr ctx ~server_name ~capabilities head);
       List.iter (fun arg -> emit ctx " "; emit_api_test_arg ctx ~server_name ~capabilities arg) args;
       emit ctx ")")
  | _ -> emit_expr ctx e

let rec emit_api_test_stmt ctx ~indent ~server_name ~capabilities = function
  | TsLet { name; value = (EApp _ as check_app); _ } when (let rec find_check = function
        | EApp { fn = EVar { name = "check"; _ }; _ } -> true
        | EApp { fn; _ } -> find_check fn
        | _ -> false
      in find_check check_app) ->
    let binding_name =
      if String.equal name "_" then begin
        let n = ctx.case_counter in
        ctx.case_counter <- ctx.case_counter + 1;
        Printf.sprintf "tesl_ignored_%d" n
      end else
        name
    in
    let tmp = Printf.sprintf "tesl_checked_%d" ctx.case_counter in
    ctx.case_counter <- ctx.case_counter + 1;
    let rec collect_check_args acc = function
      | EApp { fn = EVar { name = "check"; _ }; arg; _ } -> (arg, acc)
      | EApp { fn; arg; _ } -> collect_check_args (arg :: acc) fn
      | e -> (e, List.rev acc)
    in
    let fn_expr, args = collect_check_args [] check_app in
    (* Keep the original check-ok so proof-sensitive API-test assertions and
       helper calls preserve the checker-produced GDP subject. *)
    emit ctx indent;
    emit ctx (Printf.sprintf "(define %s (" tmp);
    emit_api_test_expr ctx ~server_name ~capabilities fn_expr;
    List.iter (fun a -> emit ctx " "; emit_api_test_arg ctx ~server_name ~capabilities a) args;
    emit_line ctx "))";
    emit_line ctx (Printf.sprintf "%s(when (check-fail? %s)" indent tmp);
    emit_line ctx (Printf.sprintf "%s  (raise-user-error 'tesl-test \"unexpected failure in let %s: ~a\" (check-fail-message %s)))" indent binding_name tmp);
    emit ctx indent;
    emit ctx (Printf.sprintf "(define %s %s)" binding_name tmp);
    emit_nl ctx;
    Hashtbl.replace ctx.proof_locals binding_name ()
  | TsLetProof { value_name; proof_names; value; _ } ->
    let tmp = Printf.sprintf "tesl_proof_bind_%d" ctx.case_counter in
    ctx.case_counter <- ctx.case_counter + 1;
    emit_line ctx (Printf.sprintf "  (define %s " tmp);
    emit_expr ctx value;
    emit_line ctx ")";
    emit_line ctx (Printf.sprintf "  (when (check-fail? %s)" tmp);
    emit_line ctx (Printf.sprintf "    (raise-user-error 'tesl-test \"unexpected failure in let-proof: ~a\" (check-fail-message %s)))" tmp);
    let vname = if String.equal value_name "_" then Printf.sprintf "tesl_ignored_%d" (let n = ctx.case_counter in ctx.case_counter <- ctx.case_counter + 1; n) else value_name in
    emit_line ctx (Printf.sprintf "  (define %s (forget-proof %s))" vname tmp);
    List.iter (fun pname ->
      emit_line ctx (Printf.sprintf "  (define %s (detach-all-proof %s))" pname tmp);
      Hashtbl.replace ctx.proof_locals pname ()
    ) proof_names
  | TsLet { name; value; _ } ->
    let binding_name =
      if String.equal name "_" then begin
        let n = ctx.case_counter in
        ctx.case_counter <- ctx.case_counter + 1;
        Printf.sprintf "tesl_ignored_%d" n
      end else
        name
    in
    emit ctx indent;
    emit ctx (Printf.sprintf "(define %s " binding_name);
    emit_api_test_expr ctx ~server_name ~capabilities value;
    emit_line ctx ")"
  | TsExpect { left; right = None; _ } ->
    emit ctx indent;
    emit ctx "(check-true (raw-value ";
    emit_api_test_expr ctx ~server_name ~capabilities left;
    emit_line ctx "))"
  | TsExpect { left; right = Some right; _ } ->
    emit ctx indent;
    emit ctx "(check-equal? ";
    emit ctx "(raw-value ";
    emit_api_test_expr ctx ~server_name ~capabilities left;
    emit ctx ") ";
    emit_api_test_expr ctx ~server_name ~capabilities right;
    emit_line ctx ")"
  | TsExpr { e; _ } ->
    emit ctx indent;
    emit_api_test_expr ctx ~server_name ~capabilities e;
    emit_nl ctx
  | TsExpectFail { fn; arg; _ } ->
    let rec flatten_args acc a = match a with
      | EApp { fn = base; arg = last; _ } -> flatten_args (last :: acc) base
      | _ -> a :: acc
    in
    let flat_args = flatten_args [] arg in
    let emit_expect_fail_call () =
      match fn, flat_args with
      | EVar { name = "check"; _ }, check_fn :: check_args ->
        emit ctx "(";
        emit_api_test_expr ctx ~server_name ~capabilities check_fn;
        List.iter (fun a -> emit ctx " "; emit_api_test_arg ctx ~server_name ~capabilities a) check_args;
        emit ctx ")"
      | _ ->
        emit ctx "(";
        emit_api_test_expr ctx ~server_name ~capabilities fn;
        List.iter (fun a -> emit ctx " "; emit_api_test_arg ctx ~server_name ~capabilities a) flat_args;
        emit ctx ")"
    in
    emit ctx indent;
    emit_line ctx "(let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])";
    emit ctx (indent ^ "                        ");
    emit_expect_fail_call ();
    emit_line ctx ")])";
    emit_line ctx (indent ^ "  (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))))")
  | TsExpectHasProof { fn; arg; proof_name = _; _ } ->
    emit ctx indent;
    emit ctx "(";
    emit_api_test_expr ctx ~server_name ~capabilities fn;
    emit ctx " ";
    emit_api_test_expr ctx ~server_name ~capabilities arg;
    emit_line ctx ")"
  | TsProperty { description = _; params = _; body; _ } ->
    emit ctx indent;
    emit ctx "(check-true ";
    emit_api_test_expr ctx ~server_name ~capabilities body;
    emit_line ctx ")"
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    emit ctx indent;
    emit ctx "(if ";
    emit_api_test_expr ctx ~server_name ~capabilities cond;
    emit_nl ctx;
    emit_line ctx (indent ^ "  (let ()");
    List.iter (emit_api_test_stmt ctx ~indent:(indent ^ "    ") ~server_name ~capabilities) then_stmts;
    emit_line ctx (indent ^ "  )");
    emit_line ctx (indent ^ "  (let ()");
    List.iter (emit_api_test_stmt ctx ~indent:(indent ^ "    ") ~server_name ~capabilities) else_stmts;
    emit_line ctx (indent ^ "  ))")
  | TsCase { scrut; arms; _ } ->
    let var = fresh_case ctx in
    (* API test-block context has no define/pow macro — bind *var directly. *)
    let star_var = "*" ^ var in
    emit ctx indent;
    emit ctx (Printf.sprintf "(let ([%s (raw-value " star_var);
    emit_api_test_expr ctx ~server_name ~capabilities scrut;
    emit_line ctx ")]) (cond";
    List.iter (fun (arm : ts_case_arm) ->
      let pattern_guard, binding_code = pattern_to_racket ctx arm.ts_pattern star_var in
      let full_guard = match arm.ts_guard with
        | None -> pattern_guard
        | Some g ->
          let gbuf = Buffer.create 32 in
          let gctx = { ctx with buf = gbuf } in
          emit_api_test_expr gctx ~server_name ~capabilities g;
          Printf.sprintf "(and %s %s)" pattern_guard (Buffer.contents gbuf)
      in
      emit ctx (indent ^ "  [");
      emit ctx full_guard;
      emit_nl ctx;
      (match binding_code with
       | [] -> List.iter (emit_api_test_stmt ctx ~indent:(indent ^ "    ") ~server_name ~capabilities) arm.ts_body
       | _ ->
         List.iter (fun b -> emit_line ctx (indent ^ "    " ^ Printf.sprintf "(let (%s)" b)) binding_code;
         List.iter (emit_api_test_stmt ctx ~indent:(indent ^ "      ") ~server_name ~capabilities) arm.ts_body;
         List.iter (fun _ -> emit_line ctx (indent ^ "    )")) binding_code);
      emit_line ctx (indent ^ "  ]")
    ) arms;
    emit_line ctx (indent ^ "))")

let emit_api_test ctx ~(database_names : string list) (t : api_test_form) =
  Hashtbl.clear ctx.proof_locals;
  emit_line ctx "(module+ test";
  emit_line ctx "  (require rackunit)";
  emit_line ctx (Printf.sprintf "  (test-case %S" t.description);
  if database_names = [] then
    emit_line ctx "    (call-with-fresh-memory-db '()"
  else
    emit_line ctx (Printf.sprintf "    (call-with-fresh-memory-db (list %s)" (String.concat " " database_names));
  emit_line ctx "      (lambda ()";
  emit_line ctx "        (call-with-api-test-subscriptions";
  emit_line ctx "          (lambda ()";
  let body_indent = if t.capabilities = [] then "            " else "              " in
  if t.capabilities <> [] then
    emit_line ctx (Printf.sprintf "            (with-capabilities (%s)" (cap_list_str t.capabilities));
  List.iter (fun seed_expr ->
    emit ctx body_indent;
    emit_api_test_expr ctx ~server_name:t.server_name ~capabilities:t.capabilities seed_expr;
    emit_nl ctx
  ) t.seed_stmts;
  List.iter (emit_api_test_stmt ctx ~indent:body_indent ~server_name:t.server_name ~capabilities:t.capabilities) t.stmts;
  if t.capabilities <> [] then emit_line ctx "            )";
  emit_line ctx "          ))";
  emit_line ctx "      ))";
  emit_line ctx "  )";
  emit_line ctx ")";
  emit_nl ctx

(* ── Load-test emitter ───────────────────────────────────────────────────── *)

let emit_load_test_metric = function
  | LtP50 -> "'p50"
  | LtP95 -> "'p95"
  | LtP99 -> "'p99"
  | LtP999 -> "'p99.9"
  | LtErrorRate -> "'error-rate"
  | LtThroughput -> "'throughput"

let emit_load_test_op = function
  | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">="
  | _ -> "<"

let emit_load_test ctx ~(database_names : string list) (t : load_test_form) =
  Hashtbl.clear ctx.proof_locals;
  emit_line ctx "(module+ test";
  emit_line ctx "  (require rackunit tesl/dsl/load-test)";
  emit_line ctx (Printf.sprintf "  (test-case %S" t.description);
  if database_names = [] then
    emit_line ctx "    (call-with-fresh-memory-db '()"
  else
    emit_line ctx (Printf.sprintf "    (call-with-fresh-memory-db (list %s)"
      (String.concat " " database_names));
  emit_line ctx "      (lambda ()";
  emit_line ctx "        (call-with-api-test-subscriptions";
  emit_line ctx "          (lambda ()";
  let body_indent = if t.capabilities = [] then "            " else "              " in
  if t.capabilities <> [] then
    emit_line ctx (Printf.sprintf "            (with-capabilities (%s)"
      (cap_list_str t.capabilities));
  (* Seed stmts *)
  List.iter (fun seed_expr ->
    emit ctx body_indent;
    emit_api_test_expr ctx ~server_name:t.server_name ~capabilities:t.capabilities seed_expr;
    emit_nl ctx
  ) t.seed_stmts;
  (* Emit load-test runner call *)
  emit ctx body_indent;
  emit ctx (Printf.sprintf "(run-load-test %s %d %d" t.server_name t.rate t.duration);
  emit_nl ctx;
  (* Request thunk *)
  emit ctx body_indent;
  emit ctx "  (lambda ()";
  emit_nl ctx;
  List.iter (emit_api_test_stmt ctx ~indent:(body_indent ^ "    ") ~server_name:t.server_name ~capabilities:t.capabilities) t.request_stmts;
  emit ctx body_indent;
  emit ctx "  )";
  emit_nl ctx;
  (* Baseline *)
  (match t.baseline with
   | Some bl ->
     emit ctx body_indent;
     emit ctx (Printf.sprintf "  #:baseline %S" bl);
     emit_nl ctx
   | None -> ());
  (* Assertions *)
  emit ctx body_indent;
  emit ctx "  #:assertions (list";
  List.iter (fun a ->
    match a with
    | LtAssertMetric { metric; op; value; unit; } ->
      let _ = unit in
      emit ctx (Printf.sprintf " (load-test-assert %s '%s %g)"
        (emit_load_test_metric metric) (emit_load_test_op op) value)
    | LtAssertRegression { metric; ratio } ->
      emit ctx (Printf.sprintf " (load-test-regression %s %g)"
        (emit_load_test_metric metric) ratio)
  ) t.assertions;
  emit ctx ")";
  emit_nl ctx;
  emit ctx body_indent;
  emit ctx ")";
  emit_nl ctx;
  if t.capabilities <> [] then emit_line ctx "            )";
  emit_line ctx "          ))";
  emit_line ctx "      ))";
  emit_line ctx "  )";
  emit_line ctx ")";
  emit_nl ctx

(* ── Main module emitter ─────────────────────────────────────────────────── *)

(* For the source-map: the [Location.loc] and a short human label of each
   top-level declaration.  Every [top_decl] payload already carries a [loc]
   (parser-assigned) — we read it, never duplicate it. *)
let top_decl_loc_label (d : top_decl) : Location.loc * string =
  match d with
  | DFunc fd ->
    let k = match fd.kind with
      | FnKind -> "fn" | CheckKind -> "check" | AuthKind -> "auth"
      | EstablishKind -> "establish" | HandlerKind -> "handler"
      | WorkerKind -> "worker" | DeadWorkerKind -> "dead-letter worker"
      | MainKind -> "main"
    in
    fd.loc, (if fd.kind = MainKind then "main block" else Printf.sprintf "%s %s" k fd.name)
  | DType (TypeNewtype { loc; name; _ }) -> loc, Printf.sprintf "newtype %s" name
  | DType (TypeAlias { loc; name; _ })   -> loc, Printf.sprintf "type alias %s" name
  | DType (TypeAdt { loc; name; _ })     -> loc, Printf.sprintf "type %s" name
  | DRecord r     -> r.loc, Printf.sprintf "record %s" r.name
  | DEntity e     -> e.loc, Printf.sprintf "entity %s" e.name
  | DFact f       -> f.loc, Printf.sprintf "fact %s" f.name
  | DCodec c      -> c.loc, Printf.sprintf "codec %s" c.name
  | DDatabase d   -> d.loc, Printf.sprintf "database %s" d.name
  | DCapability c -> c.loc, Printf.sprintf "capability %s" c.name
  | DConst c      -> c.loc, Printf.sprintf "const %s" c.name
  | DQueue q      -> q.loc, Printf.sprintf "queue %s" q.name
  | DChannel c    -> c.loc, Printf.sprintf "channel %s" c.name
  | DWorkers w    -> w.loc, Printf.sprintf "workers %s" w.name
  | DCache c      -> c.loc, Printf.sprintf "cache %s" c.name
  | DAgent a      -> a.loc, Printf.sprintf "agent %s" a.name
  | DEmail e      -> e.loc, Printf.sprintf "email %s" e.name
  | DCapture c    -> c.loc, Printf.sprintf "capture %s" c.name
  | DApi a        -> a.loc, Printf.sprintf "api %s" a.name
  | DServer s     -> s.loc, Printf.sprintf "server %s" s.name
  | DTest t       -> t.loc, Printf.sprintf "test %S" t.description
  | DApiTest t    -> t.loc, Printf.sprintf "api test %S" t.description
  | DLoadTest t   -> t.loc, Printf.sprintf "load test %S" t.description

let emit_module ctx (m : module_form) =
  (* Pre-populate known stdlib ADT constructor → field labels.
     These are not in user-imports (stdlib is always skipped) but pattern matching
     against them needs the correct field keys (e.g. Ok n → field key is 'value, not 'n). *)
  let stdlib_ctors = [
    ("Ok",         ["value"]);
    ("Err",        ["error"]);
    ("Something",  ["value"]);
    ("Left",       ["value"]);
    ("Right",      ["value"]);
    ("RowsDeleted",["count"]);
    ("JobOk",      ["job"]);
    ("JobFailed",  ["job"; "error"]);
    ("Tuple2",     ["first"; "second"]);
  ] in
  List.iter (fun (ctor, labels) ->
    Hashtbl.replace ctx.ctor_fields ctor labels
  ) stdlib_ctors;
  (* Populate ADT constructor → field labels mapping for case pattern resolution,
     and proof_annotated_ctor_fields for proof-annotated fields that must preserve named-values. *)
  List.iter (function
    | DType (TypeAdt { variants; _ }) ->
      List.iter (fun (v : Ast.adt_variant) ->
        let labels = List.map (fun (f : Ast.field_def) -> f.name) v.fields in
        if labels <> [] then
          Hashtbl.replace ctx.ctor_fields v.ctor labels;
        (* Track proof-annotated fields so we can preserve their named-values in ctor emission *)
        let proof_fields = List.filter_map (fun (f : Ast.field_def) ->
          if f.proof_ann <> None then Some f.name else None
        ) v.fields in
        if proof_fields <> [] then
          Hashtbl.replace ctx.proof_annotated_ctor_fields v.ctor proof_fields
      ) variants
    | _ -> ()
  ) m.decls;
  (* Also populate ctor_fields from imported local modules *)
  let is_tesl_stdlib name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.iter (fun (imp : import_decl) ->
    if not (is_tesl_stdlib imp.module_name) then begin
      let path = resolve_local_import_path m.source_file imp.module_name in
      if Sys.file_exists path then begin
        let source = In_channel.with_open_text path In_channel.input_all in
        (match Parser.parse_module path source with
         | Err _ -> ()
         | Ok imported ->
           List.iter (function
             | DType (TypeAdt { variants; _ }) ->
               List.iter (fun (v : Ast.adt_variant) ->
                 let labels = List.map (fun (f : Ast.field_def) -> f.name) v.fields in
                 if labels <> [] && not (Hashtbl.mem ctx.ctor_fields v.ctor) then
                   Hashtbl.replace ctx.ctor_fields v.ctor labels
               ) variants
             | _ -> ()
           ) imported.decls)
      end
    end
  ) m.imports;
  (* Collect record/entity field definitions for typed record construction *)
  let record_fields = List.filter_map (function
    | DRecord r -> Some (r.name, List.map (fun (f : Ast.field_def) -> (f.name, f.type_expr)) r.fields)
    | DEntity e -> Some (e.name, List.map (fun (f : Ast.field_def) -> (f.name, f.type_expr)) e.fields)
    | _ -> None
  ) m.decls in
  let record_meta = List.filter_map (function
    | DRecord r -> Some (r.name, r.fields, r.invariant)
    | DEntity e -> Some (e.name, e.fields, None)
    | _ -> None
  ) m.decls in
  let ctx = { ctx with record_fields; record_meta } in
  List.iter (function
    | DEntity e -> Hashtbl.replace ctx.entity_names e.name ()
    | _ -> ()
  ) m.decls;
  let database_names = List.filter_map (function
    | DDatabase d -> Some d.name
    | _ -> None
  ) m.decls in

  (* Populate fn_names, arities, and return specs for declared functions. *)
  List.iter (function
    | DFunc fd ->
      Hashtbl.replace ctx.fn_names fd.name ();
      Hashtbl.replace ctx.fn_arities fd.name (List.length fd.params);
      Hashtbl.replace ctx.fn_return_specs fd.name fd.return_spec
    | _ -> ()
  ) m.decls;
  List.iter (fun (name, arity) ->
    Hashtbl.replace ctx.fn_names name ();
    Hashtbl.replace ctx.fn_arities name arity
  ) (load_imported_fn_arities m);

  (* Build api_name → server_name mapping for SSE routes naming *)
  let api_to_server : (string, string) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | DServer sv -> Hashtbl.replace api_to_server sv.api_name sv.name
    | _ -> ()
  ) m.decls;

  emit_requires ctx m;
  emit_provide ctx m;

  (* Emit proof predicate symbol definitions *)
  let proof_names = collect_proof_names m in
  List.iter (fun pname ->
    emit_line ctx (Printf.sprintf "(define %s '%s)" pname pname)
  ) proof_names;
  if proof_names <> [] then emit_nl ctx;

  (* Emit each declaration *)
  List.iter (fun decl ->
    let sm_loc, sm_form = top_decl_loc_label decl in
    sm_region ctx ~form:sm_form sm_loc (fun () ->
    match decl with
    | DFunc fd -> emit_func ctx fd
    | DType tf -> emit_type_form ctx tf
    | DRecord r -> emit_record ctx r
    | DEntity e -> emit_entity ctx e
    | DCodec cf ->
      (match cf.to_json with
       | ToJsonAdt ->
         (* adtJson: look up the ADT variants from this module's decls *)
         let variants = List.find_map (function
           | DType (TypeAdt { name; variants; _ }) when name = cf.type_name -> Some variants
           | _ -> None) m.decls in
         emit_adt_codec ctx cf (Option.value variants ~default:[])
       | _ -> emit_codec ctx cf)
    | DDatabase d -> emit_database ctx d
    | DCapability c -> emit_capability ctx c
    | DFact _ -> () (* predicates are phantom — no runtime emission *)
    | DConst c ->
      emit ctx (Printf.sprintf "(define %s " c.name);
      emit_expr ctx c.value;
      emit_line ctx ")";
      emit_nl ctx
    | DQueue q ->
      emit_line ctx (Printf.sprintf "(define-queue %s" q.name);
      emit_line ctx (Printf.sprintf "  #:database %s" q.database);
      emit ctx "  #:job-types (";
      List.iteri (fun i j -> if i > 0 then emit ctx " "; emit ctx j) q.jobs;
      emit_line ctx ")";
      (* Emit max-attempts, backoff, initial-delay — use defaults if not specified *)
      let max_att = match q.max_attempts with Some n -> n | None -> 3 in
      let backoff = match q.backoff with Some b -> b | None -> "exponential" in
      let init_delay = match q.initial_delay with Some d -> d | None -> 0 in
      emit_line ctx (Printf.sprintf "  #:max-attempts %d" max_att);
      emit_line ctx (Printf.sprintf "  #:backoff %s" backoff);
      emit_line ctx (Printf.sprintf "  #:initial-delay %d)" init_delay);
      emit_nl ctx
    | DChannel c ->
      emit_line ctx (Printf.sprintf "(define-channel %s)" c.name);
      emit_nl ctx
    | DWorkers w ->
      (* Workers lower to (define WorkerName (list (cons Queue handler))) *)
      emit_line ctx (Printf.sprintf "(define %s" w.name);
      emit ctx "  (list";
      List.iter (fun (_job, handler) ->
        emit ctx (Printf.sprintf " (cons %s %s)" w.queue_name handler)
      ) w.bindings;
      emit_line ctx "))";
      let register_fn = if w.is_dead then "register-api-test-dead-workers!" else "register-api-test-workers!" in
      emit ctx (Printf.sprintf "(%s (list" register_fn);
      List.iter (fun (job, handler) ->
        emit ctx (Printf.sprintf " (list %s '%s %s)" w.queue_name job handler)
      ) w.bindings;
      emit_line ctx "))";
      emit_nl ctx
    | DCapture c -> emit_capture ctx c
    | DApi api ->
      let server_name = match Hashtbl.find_opt api_to_server api.name with
        | Some sn -> sn | None -> ""
      in
      (* Get server bindings for this API *)
      let server_bindings = List.find_map (function
        | DServer sv when sv.api_name = api.name -> Some sv.bindings
        | _ -> None
      ) m.decls |> Option.value ~default:[] in
      emit_api ctx ~server_name ~server_bindings api
    | DServer sv -> emit_server ctx sv
    | DTest _ -> ()  (* collected and emitted in one batch below *)
    | DApiTest t ->
      if test_block_selected ~kind:"api-test" ~description:t.description then
        emit_api_test ctx ~database_names t
    | DLoadTest t ->
      if test_block_selected ~kind:"load-test" ~description:t.description then
        emit_load_test ctx ~database_names t
    | DCache c ->
      (* The define-cache macro references the cache capability `cacheCap_<name>`,
         so bind it first (define-capability before define-cache). *)
      emit_line ctx (Printf.sprintf "(define-capability cacheCap_%s)" c.name);
      emit ctx (Printf.sprintf "(define-cache %s #:database %s" c.name c.database);
      (match c.default_ttl with
       | Some ttl -> emit ctx (Printf.sprintf " #:default-ttl %d" ttl)
       | None -> ());
      emit_line ctx ")";
      emit_nl ctx
    | DAgent a -> emit_agent ctx m.decls a
    | DEmail e ->
      emit ctx (Printf.sprintf "(define-email %s #:database %s" e.name e.database);
      emit ctx " #:smtp-host ";
      emit_postgres_value ctx e.smtp.host;
      emit ctx (Printf.sprintf " #:smtp-port %d" e.smtp.port);
      emit ctx " #:smtp-username ";
      emit_postgres_value ctx e.smtp.username;
      emit ctx " #:smtp-password ";
      emit_postgres_value ctx e.smtp.password;
      emit ctx (Printf.sprintf " #:smtp-tls %s" (if e.smtp.tls then "#t" else "#f"));
      emit_line ctx ")";
      emit_nl ctx
    )  (* close sm_region thunk *)
  ) m.decls;

  (* Emit all DTest blocks in a single (module+ test ...) to avoid rackunit
     side-effects from multiple (require rackunit) calls in separate fragments. *)
  let plain_tests =
    let all = List.filter_map (function DTest t -> Some t | _ -> None) m.decls in
    (* A synthetic doctest block carries the "doctest: <fn>" description prefix; a
       hand-written `test "..."` block is kind "test".  This lets `--test-kind doctest`
       and `--test-kind test` disambiguate. *)
    let dtest_kind (t : test_form) =
      let p = "doctest: " in
      if String.length t.description >= String.length p
         && String.equal (String.sub t.description 0 (String.length p)) p
      then "doctest" else "test"
    in
    List.filter
      (fun (t : test_form) ->
        test_block_selected ~kind:(dtest_kind t) ~description:t.description)
      all
  in
  if plain_tests <> [] then begin
    emit_line ctx "(module+ test";
    emit_line ctx "  (require rackunit)";
    List.iter (fun (t : test_form) ->
      sm_region ctx ~form:(Printf.sprintf "test %S" t.description) t.loc
        (fun () -> emit_test ctx t);
      emit_nl ctx) plain_tests;
    emit_line ctx ")";
    emit_nl ctx
  end;

  (* Inline declarations from cyclic SCC modules.
     When A and B form a cyclic SCC, compiling A also emits B's declarations inline
     so that A.rkt is self-contained (no lazy load of B.rkt needed). *)
  let emitted_names : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  (* Track main module's own declared names to avoid re-emitting them *)
  List.iter (function
    | DFunc fd -> Hashtbl.replace emitted_names fd.name ()
    | DConst c -> Hashtbl.replace emitted_names c.name ()
    | DRecord r -> Hashtbl.replace emitted_names r.name ()
    | DEntity e -> Hashtbl.replace emitted_names e.name ()
    | DType (TypeAdt { name; _ }) | DType (TypeNewtype { name; _ }) | DType (TypeAlias { name; _ }) ->
      Hashtbl.replace emitted_names name ()
    | _ -> ()
  ) m.decls;
  (* Track which cyclic modules have been processed to avoid infinite recursion *)
  let processed_cyclic : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  Hashtbl.replace processed_cyclic m.source_file ();
  (* Inline declarations from all SCC members recursively via BFS *)
  let inline_cyclic (cyclic_m : module_form) =
    emit_nl ctx;
    emit_line ctx (Printf.sprintf "; ── Inlined from cyclic module %s ──────────────────" cyclic_m.module_name);
    (* Populate fn_names/arities for cyclic module *)
    List.iter (function
      | DFunc fd ->
        Hashtbl.replace ctx.fn_names fd.name ();
        Hashtbl.replace ctx.fn_arities fd.name (List.length fd.params)
      | _ -> ()
    ) cyclic_m.decls;
    (* Emit cyclic module's proof predicate symbols *)
    let cyclic_proof_names = collect_proof_names cyclic_m in
    List.iter (fun pname ->
      if not (Hashtbl.mem emitted_names pname) then begin
        emit_line ctx (Printf.sprintf "(define %s '%s)" pname pname);
        Hashtbl.replace emitted_names pname ()
      end
    ) cyclic_proof_names;
    (* Emit cyclic module's declarations (skip already-defined names) *)
    List.iter (fun decl ->
      let skip = match decl with
        | DFunc fd -> Hashtbl.mem emitted_names fd.name
        | DConst c -> Hashtbl.mem emitted_names c.name
        | DRecord r -> Hashtbl.mem emitted_names r.name
        | DType (TypeAdt { name; _ }) | DType (TypeNewtype { name; _ })
        | DType (TypeAlias { name; _ }) -> Hashtbl.mem emitted_names name
        | _ -> false
      in
      if not skip then
        (match decl with
         | DFunc fd ->
           Hashtbl.replace emitted_names fd.name ();
           emit_func ctx fd
         | DType tf ->
           emit_type_form ctx tf
         | DRecord r ->
           Hashtbl.replace emitted_names r.name ();
           emit_record ctx r
         | DEntity e ->
           Hashtbl.replace emitted_names e.name ();
           emit_entity ctx e
         | DConst c ->
           Hashtbl.replace emitted_names c.name ();
           emit ctx (Printf.sprintf "(define %s " c.name);
           emit_expr ctx c.value;
           emit_line ctx ")";
           emit_nl ctx
         | _ -> ())
    ) cyclic_m.decls
  in
  (* Use a queue to process all SCC members, not just direct imports *)
  let to_process : module_form Queue.t = Queue.create () in
  List.iter (fun (imp : Ast.import_decl) ->
    if is_cyclic_local_import m imp &&
       not (Hashtbl.mem processed_cyclic (resolve_local_import_path m.source_file imp.module_name)) then begin
      let path = resolve_local_import_path m.source_file imp.module_name in
      Hashtbl.replace processed_cyclic path ();
      (match load_local_import_module m.source_file imp.module_name with
       | None -> ()
       | Some cyclic_m -> Queue.add cyclic_m to_process)
    end
  ) m.imports;
  while not (Queue.is_empty to_process) do
    let cyclic_m = Queue.pop to_process in
    inline_cyclic cyclic_m;
    (* Also enqueue transitive cyclic imports of this module *)
    List.iter (fun (imp : Ast.import_decl) ->
      let path = resolve_local_import_path cyclic_m.source_file imp.module_name in
      if Hashtbl.mem cyclic_local_import_table path &&
         not (Hashtbl.mem processed_cyclic path) then begin
        Hashtbl.replace processed_cyclic path ();
        (match load_local_import_module cyclic_m.source_file imp.module_name with
         | None -> ()
         | Some transitive_m -> Queue.add transitive_m to_process)
      end
    ) cyclic_m.imports
  done

let compile_to_string ?(root_path=default_root_path ()) ?(cyclic_local_import_paths=[]) (m : module_form) =
  let ctx = mk_ctx ~root_path () in
  (* Populate expr_type_tbl from the type checker so lambdas can emit correct
     #:returns types instead of always using Unit. *)
  (let expr_types, _ = Checker.check_module_with_expr_types m in
   List.iter (fun (info : Checker.expr_type_info) ->
     let key = (info.loc.Location.start.line, info.loc.Location.start.col) in
     Hashtbl.replace ctx.expr_type_tbl key info.display_ty
   ) expr_types);
  Hashtbl.clear qualified_imports;
  Hashtbl.clear stdlib_plain_imports;
  Hashtbl.clear job_type_to_queue;
  Hashtbl.clear cyclic_local_import_table;
  List.iter (fun path -> Hashtbl.replace cyclic_local_import_table path ()) cyclic_local_import_paths;
  List.iter (function
    | DQueue q -> List.iter (fun job -> Hashtbl.replace job_type_to_queue job q.name) q.jobs
    | _ -> ()
  ) m.decls;
  (* Surface-form lowering (reduce_language_size).  Run here, AFTER the type
     checker has seen the surface forms (so [expr_type_tbl] keys/diagnostics are
     unchanged) and immediately BEFORE [emit_module], so the emitter only ever
     sees the lowered core forms (EEnqueue/EStartWorkers/EServe → ERuntimeCall).
     Idempotent: re-running on an already-lowered module is the identity, so the
     compile.ml pipeline's own desugar pass and direct callers of this function
     both produce identical output. *)
  let m = Desugar.desugar_module m in
  emit_module ctx m;
  (* Trim trailing blank line to match Python compiler output *)
  let s = Buffer.contents ctx.buf in
  let n = String.length s in
  if n >= 2 && s.[n-1] = '\n' && s.[n-2] = '\n' then String.sub s 0 (n-1)
  else s
