(** Experimental Go backend. It intentionally supports a narrow pure subset and
    rejects everything else before writing an incomplete project. *)

open Ast

type mode = Release | Debug

type artifact = {
  path : string;
  contents : string;
}

type emit_error = {
  loc : Location.loc;
  message : string;
}

type go_type =
  | TInt
  | TFloat
  | TString
  | TBool
  | TUnit
  | TNewtype of newtype_info
  | TRecord of record_info
  | TAdt of adt_info * go_type list
  | TList of go_type
  | TDict of go_type * go_type
  | TSet of go_type
  | TParam of string
  (* A FUNCTION VALUE: `f: Int -> Int` as a parameter, or a lambda passed around.  The
     capability row on the arrow is compile-time (the checker propagates it), so only the
     domain and codomain survive. *)
  | TFunc of go_type list * go_type
  (* The UNTYPED api-test view of a JSON value.  Inside an `api-test` block a response body
     is inspected without types — `resp.body.userId` is deliberately untyped, and the checker
     types it as a fresh variable so the assertion reads like the JSON it checks.  That
     ergonomics is by design, so the emitter carries a dynamic value here rather than
     inventing a typed view the source never asked for. *)
  | TJson
  | TCheck of go_type
  | TFailure

and newtype_info = {
  tesl_name : string;
  (* The package that DECLARES this type.  A reference from another package has to be
     qualified, and only the declaring package may emit the declaration. *)
  owner : string;
  go_name : string;
  base : go_type;
  (* A `secret` newtype.  Its payload is a `teslrt.SecretString`, which prints as
     "[redacted]" through every fmt verb, and equality on it is CONSTANT TIME — a secret
     that leaked through a log line or a timing difference would be a secret in name only. *)
  secret : bool;
  loc : Location.loc;
}

and record_info = {
  rec_tesl_name : string;
  rec_owner : string;
  rec_go_name : string;
  mutable rec_fields : (string * go_type) list;
  rec_loc : Location.loc;
}

(* A Tesl ADT becomes one flat Go value struct: an enum tag plus each variant's
   payload under a variant-qualified field name.  A tag keeps the emitted `switch`
   checkable by the `exhaustive` linter, which a Go type switch would not be. *)
and adt_info = {
  adt_tesl_name : string;
  adt_owner : string;
  adt_go_name : string;
  adt_tag_type : string;
  (* Tesl type parameters in declaration order, paired with the Go type-parameter
     names they render as. A generic ADT is only ever referenced instantiated. *)
  adt_params : (string * string) list;
  mutable adt_variants : variant_info list;
  adt_loc : Location.loc;
  (* A runtime-provided ADT (today only `Maybe`) is referenced, never declared: the
     emitter must not write its type, tag constants, or methods. *)
  adt_builtin : bool;
}

and variant_info = {
  var_ctor : string;
  var_tag : string;
  mutable var_fields : (string * go_type) list;
  (* Explicit Go field names, for a runtime-provided type whose struct is written by
     hand.  Empty means "derive from the constructor and field names". *)
  var_go_fields : (string * string) list;
  var_loc : Location.loc;
}

type signature = {
  params : go_type list;
  result : go_type;
  go_name : string;
  (* True when the function declares `cookieCap`, i.e. it may write to the response and so
     takes the request scope as its first parameter.  The `requires` clause IS the marker:
     the checker forces it to propagate to every caller, so no call-graph pass is needed. *)
  sig_needs_scope : bool;
  (* Empty for a runtime function (already spelled `teslrt.X`) and for the module being
     emitted; otherwise the package that declares it. *)
  sig_owner : string;
}

(* The package currently being emitted.  A reference to a name owned by another package
   is qualified with the owner; a reference to one's own package is bare, since Go
   forbids self-qualification.  This is a ref rather than a threaded parameter because
   `go_type` is called from ~40 sites; it is set once per module in compile_project and
   read nowhere else. *)
let current_package = ref ""

let qualified owner name =
  if owner = "" || owner = !current_package then name else owner ^ "." ^ name

exception Unsupported of emit_error

let unsupported loc fmt =
  Printf.ksprintf (fun message -> raise (Unsupported { loc; message })) fmt

(* Emitted identifiers are the most visible surface of the "if Tesl does not work
   out you hold plain Go code" argument: a reviewer should read `Area(r)`, not
   `Tesl_area(tesl_r)`.  Names therefore keep their Tesl spelling and are only
   altered when they would collide with a Go keyword, a predeclared identifier, an
   imported package name, the emitter's own `tesl…` namespace, or another emitted
   name in the same package. *)
let go_keywords = [
  "break"; "case"; "chan"; "const"; "continue"; "default"; "defer"; "else";
  "fallthrough"; "for"; "func"; "go"; "goto"; "if"; "import"; "interface"; "map";
  "package"; "range"; "return"; "select"; "struct"; "switch"; "type"; "var";
]

let go_predeclared = [
  "any"; "bool"; "byte"; "comparable"; "complex64"; "complex128"; "error"; "float32";
  "float64"; "int"; "int8"; "int16"; "int32"; "int64"; "rune"; "string"; "uint";
  "uint8"; "uint16"; "uint32"; "uint64"; "uintptr"; "true"; "false"; "iota"; "nil";
  "append"; "cap"; "clear"; "close"; "complex"; "copy"; "delete"; "imag"; "len";
  "make"; "max"; "min"; "new"; "panic"; "print"; "println"; "real"; "recover";
]

(* Package names the emitted files import, plus the emitter's own namespace: every
   generated helper, temporary, and field the emitter introduces is spelled
   `tesl…`/`Tesl…`, so a Tesl name in that namespace is renamed rather than risking
   a silent capture. *)
let go_emitter_owned = ["fmt"; "os"; "strconv"; "testing"; "teslrt"]

let sanitize_chars name =
  let b = Buffer.create (String.length name) in
  String.iter (fun c ->
    let valid =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || c = '_' || (c >= '0' && c <= '9')
    in
    if valid then Buffer.add_char b c
    else Buffer.add_string b (Printf.sprintf "_x%02x_" (Char.code c))) name;
  let value = Buffer.contents b in
  if value = "" then "tesl"
  else if value.[0] >= '0' && value.[0] <= '9' then "_" ^ value
  else value

let reserved_go_ident name =
  let lowered = String.lowercase_ascii name in
  List.mem lowered go_keywords
  || List.mem lowered go_predeclared
  || List.mem lowered go_emitter_owned
  || (String.length name >= 4 && String.sub lowered 0 4 = "tesl")

let go_ident ~exported name =
  let cleaned = sanitize_chars name in
  let cased =
    if exported then String.capitalize_ascii cleaned
    else String.uncapitalize_ascii cleaned
  in
  if reserved_go_ident cased then cased ^ "_" else cased

(** A local, parameter, or pattern binder. Tesl rejects shadowing a top-level name,
    so these cannot collide with an emitted package-level name. *)
let local_ident name = go_ident ~exported:false name

(* Package-level names are minted through one table so two Tesl names can never
   render to the same Go identifier. *)
(* `r.Width` rather than `(r).Width`: the parentheses are only needed when the object
   is a compound expression. *)
let selector_operand value =
  let simple =
    value <> ""
    && (let ok = ref true in
        String.iteri (fun index c ->
          let valid =
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
            || ((c >= '0' && c <= '9' || c = '.') && index > 0)
          in
          if not valid then ok := false) value;
        !ok)
  in
  if simple then value else "(" ^ value ^ ")"

let unique_ident taken candidate =
  let rec loop candidate =
    if Hashtbl.mem taken candidate then loop (candidate ^ "_")
    else begin Hashtbl.add taken candidate (); candidate end
  in
  loop candidate

let package_name name =
  let b = Buffer.create (String.length name) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    then Buffer.add_char b (Char.lowercase_ascii c)) name;
  let value = Buffer.contents b in
  "teslmod" ^ value

(* JSON string/number rendering for an api-test body template.  Separate from `go_quote`,
   which escapes for GO source: here the escapes are JSON's, and the result is then quoted
   for Go as ordinary text. *)
let json_quote value =
  let b = Buffer.create (String.length value + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char b c) value;
  Buffer.add_char b '"';
  Buffer.contents b

(* JSON has no Inf/NaN, so a template carrying one is a compile error rather than invalid
   JSON on the wire. *)
let json_float value =
  if Float.is_nan value || Float.is_integer value = false && Float.is_finite value = false
  then invalid_arg "api-test body: JSON has no representation for NaN or Infinity"
  else if Float.is_integer value && Float.abs value < 1e15 then
    Printf.sprintf "%.1f" value
  else Printf.sprintf "%.17g" value

let go_quote value =
  let b = Buffer.create (String.length value + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 0x20 || Char.code c >= 0x7f ->
      Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
    | c -> Buffer.add_char b c) value;
  Buffer.add_char b '"';
  Buffer.contents b

let directive_file file =
  let file = if file = "" then "generated.tesl" else Filename.basename file in
  String.map (function '\n' | '\r' -> '_' | c -> c) file

let line_directive loc =
  let line = max 1 (loc.Location.start.line + 1) in
  Printf.sprintf "//line %s:%d\n" (directive_file loc.Location.file) line

let primitive_type_of_type_expr = function
  | TName { name = "Int"; _ } -> TInt
  | TName { name = "Float"; _ } -> TFloat
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } ->
    unsupported loc "Go backend newtype base `%s` is not a direct scalar type" name
  | TVar { name; loc } -> unsupported loc "Go backend does not support type variable `%s` yet" name
  | TApp { loc; _ } -> unsupported loc "Go backend does not support applied types yet"
  | TFun { loc; _ } -> unsupported loc "Go backend does not support function values yet"
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

(* An `entity` is a record PLUS a store.  The row type is an ordinary struct — that is
   what a query returns and what `insert` takes — and the store is one package-level
   table variable, since an entity belongs to exactly one database.  Both live here so a
   query can find the table from the entity name alone. *)
type entity_info = {
  ent_tesl_name : string;
  ent_row : record_info;
  (* The package-level `var XTable = teslrt.NewTable[X]()`, qualified by its owner when
     referenced from another package. *)
  ent_table_var : string;
  ent_owner : string;
  ent_primary_key : string;
  ent_loc : Location.loc;
}

(* A `queue` is a job STORE plus the wiring from job type to worker.  Like an entity's
   table it is one package-level variable; unlike one, it also carries the dispatch a
   test's `processNextJob` needs, which is why the worker names live here. *)
type queue_info = {
  qu_tesl_name : string;
  qu_go_var : string;
  qu_owner : string;
  qu_job_type : string;            (* the job record's Tesl name *)
  qu_worker : string;              (* the worker function's Tesl name *)
  qu_dead_worker : string option;
  qu_max_attempts : int;
  qu_loc : Location.loc;
}

(** Named nominal types the emitter can resolve: scalar newtypes and records. *)
type type_table = {
  newtypes : (string, newtype_info) Hashtbl.t;
  records : (string, record_info) Hashtbl.t;
  adts : (string, adt_info) Hashtbl.t;
  entities : (string, entity_info) Hashtbl.t;
  (* Keyed by the QUEUE's name and again by its job type: `enqueue` names the job type,
     while an api-test verb names the queue. *)
  queues : (string, queue_info) Hashtbl.t;
}

(* The table for the module being emitted.  A ref for the same reason `current_package`
   is one: the type family threads `signatures` only, and a lambda's PARAMETER
   ANNOTATION has to be resolvable where a fold's accumulator type is settled — that is
   the only thing that determines the type of `List.foldl (fn(acc: List Int, …) -> …) []
   xs`, the idiomatic list-rebuilding fold.  Set once per module beside
   `current_package`. *)
let current_types : type_table option ref = ref None

(* The server an `api-test` block drives, while its statements are being emitted.  A
   request verb (`get "/path"`) only means something inside such a block, and this is what
   tells the emitter which server it addresses. *)
let current_api_server : string option ref = ref None

(* Where the api-test response record lives in the record table.  It shares the Tesl name
   `HttpResponse` with `Tesl.HttpClient`'s outbound response — the checker has one opaque
   type for both, since field access on either is untyped — but the two have different
   RUNTIME shapes, and a module may import both.  So the api-test shape is keyed by a string
   no Tesl type name can spell, and the plain name is left for the outbound one, which is the
   only one an annotation can mention. *)
let api_response_key = "HttpResponse (api-test)"

(* Tesl type names that have their OWN codec in the module being emitted.  A value with a
   codec encodes through it; anything else falls back to the generic wire shape below. *)
let current_codec_types : string list ref = ref []

(* True while a HANDLER's body is being emitted.  A check rejection consumed there must
   ANSWER the client with its own status rather than trap: `dsl/web.rkt` installs the
   raise-on-escaping-failure wrapper for every function kind except `handler`, so a
   rejection reached in a handler body is the response on the Racket side too.  Set around
   the body, since the consumption site is where the choice is made. *)
let current_handler_body = ref false

(* Set when an empty list literal fell back to its DEFAULT element type because nothing
   constrained it.  The tolerance paths (an `if` branch, a `case` arm, a sibling element)
   consult this so a defaulted type never outranks a real one: `if c then [] else ["a"]`
   must be `List String`, not a type error. *)
let used_empty_default = ref false

(* Types [expr], reporting whether the result relied on the empty-list default. *)
let typed_with_default type_of expr =
  let saved = !used_empty_default in
  used_empty_default := false;
  let result = try Some (type_of expr) with Unsupported _ -> None in
  let defaulted = !used_empty_default in
  used_empty_default := saved;
  result, defaulted

(* What a compiled module offers its importers: the very tables it emitted from.  A
   dependent reuses these exact info records rather than re-deriving them, so the two
   cannot disagree about a type's Go name, its fields, or its identity — `go_type`
   equality is structural, and two separately-derived records would compare unequal even
   when they describe the same Tesl type. *)
type module_exports = {
  ex_module : string;
  ex_package : string;
  ex_types : type_table;
  ex_signatures : (string, signature) Hashtbl.t;
}

let rec flatten_type_app args = function
  | TApp { head; arg; _ } -> flatten_type_app (arg :: args) head
  | head -> head, args

(** [params] is the type-parameter scope: non-empty only while resolving the field
    types of a generic ADT's own variants. Everywhere else a type variable has no
    Go rendering and is rejected. *)
let rec type_of_type_expr ?(params=[]) types ty =
  let recur = type_of_type_expr ~params types in
  match ty with
  | TName { name = "Int"; _ } -> TInt
  | TName { name = "Float"; _ } -> TFloat
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } ->
    (* A type may be written QUALIFIED (`Sandbox3.S3Record2`), which is how a module
       imported without an `exposing` list is referred to.  The tables are keyed by the
       bare Tesl name — the qualification says which module it came from, and the checker
       has already verified that it is in scope — so the prefix is dropped here. *)
    let name = match String.rindex_opt name '.' with
      | Some index
        when not (Hashtbl.mem types.newtypes name || Hashtbl.mem types.records name
                  || Hashtbl.mem types.adts name) ->
        String.sub name (index + 1) (String.length name - index - 1)
      | _ -> name
    in
    (match Hashtbl.find_opt types.newtypes name, Hashtbl.find_opt types.records name,
           Hashtbl.find_opt types.adts name with
     | Some info, _, _ -> TNewtype info
     | None, Some info, _ -> TRecord info
     | None, None, Some info ->
       if info.adt_params <> [] then unsupported loc
         "Go backend requires `%s` to be applied to %d type argument(s)"
         name (List.length info.adt_params);
       TAdt (info, [])
     | None, None, None -> unsupported loc "Go backend does not support type `%s` yet" name)
  | TVar { name; loc } ->
    (match List.assoc_opt name params with
     | Some go_name -> TParam go_name
     | None -> unsupported loc "Go backend does not support type variable `%s` yet" name)
  | TApp { loc; _ } ->
    let head, args = flatten_type_app [] ty in
    (match head with
     | TName { name = "List"; _ } ->
       (match args with
        | [element] -> TList (recur element)
        | _ -> unsupported loc "Go backend requires `List` to be applied to 1 type argument")
     | TName { name = "Dict"; _ } ->
       (match args with
        | [key; value] -> TDict (recur key, recur value)
        | _ -> unsupported loc "Go backend requires `Dict` to be applied to 2 type arguments")
     | TName { name = "Set"; _ } ->
       (match args with
        | [element] -> TSet (recur element)
        | _ -> unsupported loc "Go backend requires `Set` to be applied to 1 type argument")
     | TName { name; _ } ->
       (match Hashtbl.find_opt types.adts name with
        | Some info ->
          if List.length args <> List.length info.adt_params then unsupported loc
            "Go backend requires `%s` to be applied to %d type argument(s)"
            name (List.length info.adt_params);
          TAdt (info, List.map recur args)
        | None ->
          (* `Fact P` is a DETACHED PROOF: a first-class witness produced by `establish`
             and consumed by `attachFact`.  It erases like every other proof — the runtime
             comment in dsl/private/check-runtime.rkt states the rule outright ("the proof
             is asserted without re-checking — correctness is guaranteed by the
             compile-time type system"), and LANGUAGE-SPEC 16.9 gives a proof no runtime
             structure.  So it becomes a zero-size value that carries nothing. *)
          if name = "Fact" then TUnit
          else unsupported loc "Go backend does not support applied type `%s` yet" name)
     | _ -> unsupported loc "Go backend does not support applied types yet")
  (* `a -> b` is a FUNCTION VALUE.  The arrow's capability row is compile-time — the checker
     propagates it to callers and it has no runtime form — so only the domain and codomain
     survive.  A curried arrow (`a -> b -> c`) flattens into ONE Go signature, which is the
     shape the call sites emit. *)
  | TFun { dom; cod; _ } ->
    let rec flatten acc = function
      | TFun { dom; cod; _ } -> flatten (recur dom :: acc) cod
      | result -> List.rev acc, recur result
    in
    let params, result = flatten [recur dom] cod in
    TFunc (params, result)
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

let rec type_of_return_spec types = function
  | RetPlain { ty; _ } -> type_of_type_expr types ty
  | RetAttached { binding; _ } -> TCheck (type_of_type_expr types binding.type_expr)
  (* `List T ::: ForAll P` is a TYPE-LEVEL contract with zero runtime structure
     (LANGUAGE-SPEC 16.9: "at runtime, the list is a plain list with no per-element
     proof structs"), so it erases to the list itself.  The frontend has already
     discharged the proof; nothing is erased that was not checked. *)
  | RetForAll { elem_ty; _ } -> TList (type_of_type_expr types elem_ty)
  | RetMaybeForAll { elem_ty; loc; _ } ->
    (match Hashtbl.find_opt types.adts "Maybe" with
     | Some info -> TAdt (info, [TList (type_of_type_expr types elem_ty)])
     | None -> unsupported loc
       "Go backend needs `Tesl.Maybe` imported for a `Maybe (List … ::: ForAll …)` return")
  (* `-> T ? P` is a proof-carrying return.  A proof has no runtime structure in Go — the
     frontend has already discharged it, exactly as for `ForAll` above — so it erases to
     the value's own type.  Racket does keep a wrapper (`attach-proof-to`), but every read
     there goes through `raw-value`, so the wrapper is an implementation detail of that
     backend rather than part of the value.
     The parser puts the FIRST `? P` in `entity_proof` whether or not it is a provenance
     proof, so that field cannot tell the two apart here.  It does not need to: a `FromDb`
     provenance proof erases by the same rule as every other proof — it records WHERE a
     value came from for the checker, and the checker has already used it.  (This used to
     be justified by "entities are refused before this point", which stopped being true
     when the DB slice landed; the rule above is the real reason.) *)
  | RetNamedPack { ty; _ } -> type_of_type_expr types ty
  (* Every remaining proof-bearing return is the same erasure applied to a different
     container: the proof is a TYPE-LEVEL contract with no runtime structure, so what comes
     back is the Maybe, the Set or the Dict itself. *)
  | RetMaybeAttached { binding; loc; _ } ->
    (match Hashtbl.find_opt types.adts "Maybe" with
     | Some info -> TAdt (info, [type_of_type_expr types binding.type_expr])
     | None -> unsupported loc
       "Go backend needs `Tesl.Maybe` imported for a `Maybe (… ::: …)` return")
  | RetSetForAll { elem_ty; _ } -> TSet (type_of_type_expr types elem_ty)
  | RetMaybeSetForAll { elem_ty; loc; _ } ->
    (match Hashtbl.find_opt types.adts "Maybe" with
     | Some info -> TAdt (info, [TSet (type_of_type_expr types elem_ty)])
     | None -> unsupported loc
       "Go backend needs `Tesl.Maybe` imported for a `Maybe (Set … ::: ForAll …)` return")
  | RetForAllDictValues { key_ty; val_ty; _ }
  | RetForAllDictKeys { key_ty; val_ty; _ } ->
    TDict (type_of_type_expr types key_ty, type_of_type_expr types val_ty)
  (* An EXISTENTIAL return (`-> exists taskId: String => Task ? FromDb (Id == taskId)`) hides
     the witness from the caller's proof context.  The witness is a proof SUBJECT, not a
     value the caller receives — the body still returns the same value it would without the
     `exists` — so the type is the inner spec's and the quantifier erases.  Soundness here is
     the CHECKER's: it is what refuses to let a packed witness be forwarded where the fact
     does not hold (issue #73), and it runs before this point. *)
  | RetExists { body; _ } -> type_of_return_spec types body

let rec go_type = function
  | TInt -> "teslrt.Int"
  | TFloat -> "float64"
  | TString -> "string"
  | TBool -> "bool"
  | TUnit -> "struct{}"
  | TNewtype info -> qualified info.owner info.go_name
  | TRecord info -> qualified info.rec_owner info.rec_go_name
  | TAdt (info, []) -> qualified info.adt_owner info.adt_go_name
  | TAdt (info, args) ->
    Printf.sprintf "%s[%s]" (qualified info.adt_owner info.adt_go_name)
      (String.concat ", " (List.map go_type args))
  | TList element -> "[]" ^ go_type element
  | TDict (key, value) ->
    Printf.sprintf "teslrt.Dict[%s, %s]" (go_type key) (go_type value)
  | TSet element -> Printf.sprintf "teslrt.Set[%s]" (go_type element)
  | TParam name -> name
  | TFunc (params, result) ->
    (* `func(A, B) R`.  A Unit result is written as the empty struct like any other value,
       so a function value and a named function agree on shape. *)
    Printf.sprintf "func(%s) %s"
      (String.concat ", " (List.map go_type params)) (go_type result)
  | TJson -> "teslrt.JsonValue"
  | TCheck ty -> Printf.sprintf "teslrt.Check[%s]" (go_type ty)
  | TFailure -> invalid_arg "Go failure has no standalone type"

let record_field_go_name name = go_ident ~exported:true name

(* `!(!(x))` is a staticcheck finding (SA4013) on emitted code, so negation
   cancels an existing top-level `!(...)` instead of stacking on it.  The scan
   skips Go string literals, where a parenthesis is data rather than structure. *)
let paren_wraps_whole value from =
  let length = String.length value in
  let rec scan index depth in_string escaped =
    if index >= length then false
    else
      let c = value.[index] in
      if in_string then
        if escaped then scan (index + 1) depth true false
        else if c = '\\' then scan (index + 1) depth true true
        else if c = '"' then scan (index + 1) depth false false
        else scan (index + 1) depth true false
      else match c with
        | '"' -> scan (index + 1) depth true false
        | '(' -> scan (index + 1) (depth + 1) false false
        | ')' ->
          if depth = 1 then index = length - 1 else scan (index + 1) (depth - 1) false false
        | _ -> scan (index + 1) depth false false
  in
  from + 1 < length && value.[from] = '(' && scan from 0 false false

(* A float literal is never emitted bare.  Go folds UNTYPED constant arithmetic
   EXACTLY — `0.1 + 0.2` becomes 0.3, where Racket gives 0.30000000000000004 — so every
   literal is emitted as a typed float64 value and each operation rounds per-op, as it
   must.  Two further reasons a bare literal will not do: Go constants have no negative
   zero, and a typed constant that overflows is a COMPILE error where Racket yields
   ±inf.0. *)
let emit_float_literal value =
  if Float.is_nan value then "math.NaN()"
  else if Float.is_integer value && Float.abs value = Float.infinity then
    if value > 0.0 then "math.Inf(1)" else "math.Inf(-1)"
  else if value = 0.0 && 1.0 /. value < 0.0 then "math.Copysign(0, -1)"
  else
    (* Shortest decimal that round-trips: Go parses decimal exactly, and `%h` (hex
       float) would round-trip too but reads as `0x1p+1` in code a human is supposed to
       own after ejecting. *)
    let shortest =
      let rec attempt = function
        | [] -> Printf.sprintf "%.17g" value
        | digits :: rest ->
          let text = Printf.sprintf "%.*g" digits value in
          if float_of_string text = value then text else attempt rest
      in
      attempt [1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15; 16; 17]
    in
    Printf.sprintf "float64(%s)" shortest

let negate_bool value =
  let length = String.length value in
  if length > 3 && value.[0] = '!' && paren_wraps_whole value 1 then
    String.sub value 2 (length - 3)
  else if paren_wraps_whole value 0 then "!" ^ value
  else Printf.sprintf "!(%s)" value

(* Only strips a parenthesis pair that wraps the WHOLE expression, so `(a) && (b)`
   survives intact. *)
let strip_outer_parens value =
  if paren_wraps_whole value 0 then String.sub value 1 (String.length value - 2)
  else value

(* Records hold teslrt.Int values, which are non-comparable by construction, so
   Go `==` on a record struct is a compile error rather than a wrong answer.
   Record equality is therefore always emitted field by field. *)
(* The tag is EXPORTED: an ADT provided by the runtime — or, later, by another emitted
   module — is matched from a different package, where an unexported field would be
   invisible. *)
let adt_tag_field = "Tag"

(* Every variant's payload lives in one flat struct, so a payload field is named
   after its constructor: `Pending (reason: String)` becomes `PendingReason`. *)
let variant_field_go_name variant name =
  match List.assoc_opt name variant.var_go_fields with
  | Some go_name -> go_name
  | None -> go_ident ~exported:true variant.var_ctor ^ go_ident ~exported:true name

(* A single-variant ADT has nothing to discriminate: it needs no tag field, matching
   binds its payload directly, and equality is field-wise like a record's. *)
let single_variant info =
  match info.adt_variants with
  | [variant] -> Some variant
  | _ -> None

let find_variant info ctor =
  List.find_opt (fun variant -> variant.var_ctor = ctor) info.adt_variants

let rec substitute_type bindings ty =
  match ty with
  | TParam name -> (match List.assoc_opt name bindings with Some ty -> ty | None -> ty)
  | TAdt (info, args) -> TAdt (info, List.map (substitute_type bindings) args)
  | TCheck inner -> TCheck (substitute_type bindings inner)
  | TList element -> TList (substitute_type bindings element)
  | TDict (key, value) -> TDict (substitute_type bindings key, substitute_type bindings value)
  | TSet element -> TSet (substitute_type bindings element)
  | TFunc (params, result) ->
    TFunc (List.map (substitute_type bindings) params, substitute_type bindings result)
  | TJson -> ty
  | TInt | TFloat | TString | TBool | TUnit | TNewtype _ | TRecord _ | TFailure -> ty

(** A variant's payload types with the ADT's type arguments substituted in. *)
let variant_field_types info args variant =
  if info.adt_params = [] || args = [] then variant.var_fields
  else
    let bindings = List.map2 (fun (_, go_param) arg -> go_param, arg) info.adt_params args in
    List.map (fun (name, ty) -> name, substitute_type bindings ty) variant.var_fields

(* Comparator helpers hoisted to package level, keyed by their generated name so the
   same comparator is defined once per file.  Reset and flushed by whichever file is being
   emitted; the tests file is in the same package but gets its own copies, because a
   helper defined in module.go and used only from the test would read as unused there. *)
let pending_helpers : (string, string) Hashtbl.t = Hashtbl.create 16

(* Helpers that cannot be named after a type (a `sortBy` key lambda is per-call-site) are
   named by their own SOURCE: every function body is emitted twice — once assuming it
   loops, then flat if no self tail call materialised — so a counter minted a fresh name
   per pass and left unreferenced helpers behind, which the `unused` linter rightly
   rejected.  Keying by source makes the second pass reuse the first pass's name. *)
let helper_names : (string, string) Hashtbl.t = Hashtbl.create 16

(* Helper names module.go already declared.  module_test.go is in the SAME package, so a
   second copy there is a redeclaration; it references these instead. *)
let module_helpers : (string, unit) Hashtbl.t = Hashtbl.create 16

(* [signature] is everything after the name — `(teslX, teslY string) bool` — and [body] is
   the returned expression.  The two together are the identity of the helper. *)
(* Like `remember_helper` but for a body that is a STATEMENT sequence rather than one
   expression — a combined check has to inspect the first result before running the next. *)
let remember_helper_stmts ~prefix ~signature ~body =
  let key = prefix ^ "\x00" ^ signature ^ "\x00" ^ body in
  match Hashtbl.find_opt helper_names key with
  | Some name -> name
  | None ->
    let name = Printf.sprintf "%s%d" prefix (Hashtbl.length helper_names + 1) in
    Hashtbl.replace helper_names key name;
    Hashtbl.replace pending_helpers name
      (Printf.sprintf "\nfunc %s%s {\n%s}\n" name signature body);
    name

let remember_helper ~prefix ~signature ~body =
  let key = prefix ^ "\x00" ^ signature ^ "\x00" ^ body in
  match Hashtbl.find_opt helper_names key with
  | Some name -> name
  | None ->
    let name = Printf.sprintf "%s%d" prefix (Hashtbl.length helper_names + 1) in
    Hashtbl.replace helper_names key name;
    Hashtbl.replace pending_helpers name
      (Printf.sprintf "\nfunc %s%s {\n\treturn %s\n}\n" name signature body);
    name

(* The helper's name must be INJECTIVE over Go types: stripping punctuation alone made
   `[]teslrt.Int` and `teslrt.Int` collide on `TeslrtInt`, so a `List (List Int)`
   comparison silently reused the `Int` comparator and Go rejected the call.  The
   structural markers are spelled out before the punctuation is dropped. *)
let helper_suffix ty =
  let text = go_type ty in
  let text =
    let buffer = Buffer.create (String.length text + 8) in
    let length = String.length text in
    let index = ref 0 in
    while !index < length do
      (* A marker is followed by a separator so the next segment capitalises: the name is
         read by whoever ejects, and `SliceOfTeslrtInt` beats `SliceOfteslrtInt`. *)
      if !index + 1 < length && text.[!index] = '[' && text.[!index + 1] = ']' then begin
        Buffer.add_string buffer "SliceOf."; index := !index + 2
      end else if !index + 3 < length && String.sub text !index 4 = "map[" then begin
        Buffer.add_string buffer "MapOf."; index := !index + 4
      end else begin
        Buffer.add_char buffer text.[!index]; incr index
      end
    done;
    Buffer.contents buffer
  in
  let buffer = Buffer.create (String.length text) in
  let capitalize = ref true in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') then begin
      Buffer.add_char buffer (if !capitalize then Char.uppercase_ascii c else c);
      capitalize := false
    end else capitalize := true) text;
  Buffer.contents buffer

(* Every comparator is hoisted into a named package-level function rather than passed as
   an inline func literal.  An inline literal reads well, but go/printer keeps one on a
   single line only while it judges the body "small enough", and that threshold is not
   something the emitter can predict: a comparator over a nested collection crosses it, and
   so does a plain two-field tuple comparison once the type names are long.  Each time, gofmt
   reformats the emitted file — which the gate treats as an emitter bug, correctly.  Hoisting
   is deterministic at every size and depth, costs one named function per element type, and
   reads at least as well in code someone owns after ejecting. *)
let comparator kind ty body =
  let name = Printf.sprintf "tesl%s%s" kind (helper_suffix ty) in
  if not (Hashtbl.mem pending_helpers name) then
    Hashtbl.replace pending_helpers name
      (Printf.sprintf "\nfunc %s(teslX, teslY %s) bool {\n\treturn %s\n}\n"
         name (go_type ty) body);
  name

let rec element_equal_func element =
  comparator "Equal" element (equal_expr element "teslX" "teslY")

and element_less_func element =
  comparator "Less" element (ordered_expr element "<" "teslX" "teslY")

(* The ordering Dict and Set use for KEYS, which is NOT the user-visible ordering.  Both
   are sorted, so their binary search reads key equivalence off the comparator — "neither
   side is less" means "same key" — and that equivalence must match the equality the
   language uses, or lookup itself is wrong.  For Float the two orderings genuinely
   differ: IEEE makes every NaN comparison false (so a NaN key matches whatever the search
   probes first) and treats -0.0 and +0.0 as equal (while `FloatEqual` distinguishes
   them).  `List.sort` and user comparisons keep plain IEEE. *)
and element_key_less_func element =
  comparator "KeyLess" element (ordered_key_expr element "teslX" "teslY")

and ordered_key_expr ty left right =
  match ty with
  | TFloat -> Printf.sprintf "teslrt.FloatKeyLess(%s, %s)" left right
  (* A Float-backed newtype inherits the key comparator, so it must be unwrapped here
     rather than delegated to `ordered_expr`. *)
  | TNewtype info ->
    ordered_key_expr info.base (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | _ -> ordered_expr ty "<" left right

and equal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "teslrt.Equal(%s, %s)" left right
  (* Float equality is Racket `equal?`, not IEEE `==`: NaN equals NaN and 0.0 does not
     equal -0.0.  Both are inverted from Go's `==`, so `==` is never emitted. *)
  | TFloat -> Printf.sprintf "teslrt.FloatEqual(%s, %s)" left right
  | TString | TBool | TUnit -> Printf.sprintf "(%s == %s)" left right
  (* A SECRET compares in CONSTANT TIME: comparing its payload with `==` would leak a prefix
     through how long the comparison took, which is the classic way a token check betrays the
     token.  Racket's `secret-constant-time-equal?` says the same thing. *)
  | TNewtype info when info.secret ->
    Printf.sprintf "teslrt.SecretEqual(%s.Value, %s.Value)"
      (selector_operand left) (selector_operand right)
  | TNewtype info ->
    equal_expr info.base (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | TRecord info ->
    (match info.rec_fields with
     | [] -> "true"
     | fields ->
       let parts = List.map (fun (name, field_ty) ->
         let field = record_field_go_name name in
         equal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
           (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
       "(" ^ String.concat " && " parts ^ ")")
  | TAdt (info, args) when single_variant info <> None ->
    (match single_variant info with
     | Some variant ->
       (match variant_field_types info args variant with
        | [] -> "true"
        | fields ->
          let parts = List.map (fun (name, field_ty) ->
            let field = variant_field_go_name variant name in
            equal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
              (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
          "(" ^ String.concat " && " parts ^ ")")
     | None -> assert false)
  (* A module-declared, non-generic ADT gets a generated `TeslEqual` method: it keeps
     the comparison site short.  A runtime-provided or generic one cannot — a method
     needs a type the module declares, and `teslrt.Maybe` is neither — so its payload
     comparison is inlined instead.  No tag SWITCH is needed for that: "same tag, and
     for each variant either the tag differs or the payload matches" says the same
     thing as a conjunction, which Go can express as an expression. *)
  | TAdt (info, _) when not info.adt_builtin && info.adt_params = [] ->
    Printf.sprintf "%s.TeslEqual(%s)" (selector_operand left) right
  | TAdt (info, args) ->
    let tag_equal =
      Printf.sprintf "%s.%s == %s.%s"
        (selector_operand left) adt_tag_field (selector_operand right) adt_tag_field
    in
    let payloads = List.filter_map (fun variant ->
      match variant_field_types info args variant with
      | [] -> None
      | fields ->
        let parts = List.map (fun (name, field_ty) ->
          let field = variant_field_go_name variant name in
          equal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
            (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
        Some (Printf.sprintf "(%s.%s != %s || %s)"
                (selector_operand left) adt_tag_field
                (qualified info.adt_owner variant.var_tag)
                (String.concat " && " parts))) info.adt_variants in
    "(" ^ String.concat " && " (tag_equal :: payloads) ^ ")"
  (* A generic Go function cannot compare a `T`, so the element comparison is passed
     in: the emitter knows the concrete element type at every call site. *)
  | TList element ->
    Printf.sprintf "teslrt.ListEqualBy(%s, %s, %s)" left right (element_equal_func element)
  (* Both dicts are stored in key order, so one pass compares them. *)
  | TDict (key, value) ->
    Printf.sprintf "teslrt.DictEqualBy(%s, %s, %s, %s)" left right
      (element_equal_func key) (element_equal_func value)
  | TSet element ->
    Printf.sprintf "teslrt.SetEqualBy(%s, %s, %s)" left right (element_equal_func element)
  | TFunc _ | TParam _ | TCheck _ | TFailure ->
    invalid_arg "Go equality on this type is rejected before emission"
  | TJson -> invalid_arg "Go api-test JSON equality goes through JsonEqual"

and unequal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "!teslrt.Equal(%s, %s)" left right
  | TFloat -> Printf.sprintf "!teslrt.FloatEqual(%s, %s)" left right
  | TString | TBool | TUnit -> Printf.sprintf "(%s != %s)" left right
  | TNewtype info when info.secret ->
    Printf.sprintf "!teslrt.SecretEqual(%s.Value, %s.Value)"
      (selector_operand left) (selector_operand right)
  | TNewtype info ->
    unequal_expr info.base (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | TRecord info ->
    (* De Morgan is applied here rather than negating the conjunction: emitted
       `!(a && b)` is a golangci-lint finding (staticcheck QF1001). *)
    (match info.rec_fields with
     | [] -> "false"
     | fields ->
       let parts = List.map (fun (name, field_ty) ->
         let field = record_field_go_name name in
         unequal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
           (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
       "(" ^ String.concat " || " parts ^ ")")
  | TAdt (info, args) when single_variant info <> None ->
    (match single_variant info with
     | Some variant ->
       (match variant_field_types info args variant with
        | [] -> "false"
        | fields ->
          let parts = List.map (fun (name, field_ty) ->
            let field = variant_field_go_name variant name in
            unequal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
              (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
          "(" ^ String.concat " || " parts ^ ")")
     | None -> assert false)
  | TAdt (info, _) when not info.adt_builtin && info.adt_params = [] ->
    Printf.sprintf "!%s.TeslEqual(%s)" (selector_operand left) right
  (* De Morgan applied to the inlined runtime/generic ADT equality above, for the same
     reason records and single-variant ADTs get it: `negate_bool` would emit
     `!(a && b)`, which staticcheck rejects as QF1001, and a lint finding on emitted code
     is an emitter bug by contract.  "Same tag AND every variant's payload matches"
     negates to "tags differ OR some variant's tag is held and its payload differs". *)
  | TAdt (info, args) ->
    let tag_unequal =
      Printf.sprintf "%s.%s != %s.%s"
        (selector_operand left) adt_tag_field (selector_operand right) adt_tag_field
    in
    let payloads = List.filter_map (fun variant ->
      match variant_field_types info args variant with
      | [] -> None
      | fields ->
        let parts = List.map (fun (name, field_ty) ->
          let field = variant_field_go_name variant name in
          unequal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
            (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
        Some (Printf.sprintf "(%s.%s == %s && %s)"
                (selector_operand left) adt_tag_field
                (qualified info.adt_owner variant.var_tag)
                (String.concat " || " parts))) info.adt_variants in
    "(" ^ String.concat " || " (tag_unequal :: payloads) ^ ")"
  | TList element ->
    Printf.sprintf "!teslrt.ListEqualBy(%s, %s, %s)" left right (element_equal_func element)
  | TDict (key, value) ->
    Printf.sprintf "!teslrt.DictEqualBy(%s, %s, %s, %s)" left right
      (element_equal_func key) (element_equal_func value)
  | TSet element ->
    Printf.sprintf "!teslrt.SetEqualBy(%s, %s, %s)" left right (element_equal_func element)
  | TFunc _ | TParam _ | TCheck _ | TFailure ->
    invalid_arg "Go equality on this type is rejected before emission"
  | TJson -> invalid_arg "Go api-test JSON equality goes through JsonEqual"

and ordered_expr ty op left right =
  match ty with
  | TInt -> Printf.sprintf "(teslrt.Compare(%s, %s) %s 0)" left right op
  (* Ordering, unlike equality, IS plain IEEE in both backends. *)
  | TFloat | TString -> Printf.sprintf "(%s %s %s)" left op right
  | TNewtype info ->
    ordered_expr info.base op (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | TBool | TUnit | TRecord _ | TAdt _ | TList _ | TDict _ | TSet _ | TParam _
  | TFunc _ | TJson | TCheck _ | TFailure ->
    invalid_arg "Go ordering requires an ordered scalar type"

let rec supports_ordering = function
  | TInt | TFloat | TString -> true
  (* A secret must not be ORDERED: sorting or comparing them leaks their relative values,
     and there is no use for it. *)
  | TNewtype info -> (not info.secret) && supports_ordering info.base
  | TBool | TUnit | TRecord _ | TAdt _ | TList _ | TDict _ | TSet _ | TParam _
  | TFunc _ | TJson | TCheck _ | TFailure -> false

(* A generic ADT has no comparable Go form: `TeslEqual` would have to dispatch
   `teslrt.Equal` for whatever the type parameter was instantiated with, which Go
   generics cannot express without an interface the thin-runtime invariant forbids.
   Equality on such a type is therefore rejected before emission. *)
let rec supports_equality = function
  | TInt | TFloat | TString | TBool | TUnit -> true
  | TNewtype info -> supports_equality info.base
  | TRecord info -> List.for_all (fun (_, ty) -> supports_equality ty) info.rec_fields
  | TAdt (info, args) ->
    (match single_variant info with
     (* A single-variant type compares field-wise, so it stays comparable even when
        generic: the emitter knows the instantiation at the comparison site. *)
     | Some variant ->
       List.for_all (fun (_, ty) -> supports_equality ty)
         (variant_field_types info args variant)
     | None ->
       (* A multi-variant type is comparable when every payload it could hold is —
          generic or not, since the instantiation is known at the comparison site. *)
       List.for_all (fun variant ->
         List.for_all (fun (_, ty) -> supports_equality ty)
           (variant_field_types info args variant)) info.adt_variants)
  | TList element -> supports_equality element
  | TDict (key, value) -> supports_equality key && supports_equality value
  | TSet element -> supports_equality element
  | TFunc _ | TJson | TParam _ | TCheck _ | TFailure -> false

let record_info_of_signature signatures name =
  match Hashtbl.find_opt signatures name with
  | Some { result = TRecord info; _ } -> Some info
  | _ -> None

(* ─── SQL ──────────────────────────────────────────────────────────────────────
   A query is ordinary application syntax in the surface tree, so its structure is
   recovered by {!Sql_query} — the same module the Racket backend and the checker use.
   Nothing about the shape of a query is re-derived here; this only decides which Go
   the recovered structure renders to. *)
type sql_form =
  | SqlSelect of Sql_query.sql_select_seed * Sql_query.sql_clause list
  | SqlInsert of Sql_query.sql_insert
  | SqlInsertMany of string * string            (* list binding, entity *)
  | SqlUpdate of Sql_query.sql_update
  | SqlDelete of Sql_query.sql_delete_seed * Sql_query.sql_clause list

(* The three surface shapes a query arrives in: a plain application, an application
   wrapped in the comparison that a `where` predicate parses as, and — for the
   multi-line forms — an underscore-`let` chain.  Tried in the same order as the Racket
   backend's guards, so the two agree on what a given tree means. *)
let recognise_sql expr =
  let first_of options = List.fold_left (fun found next ->
    match found with Some _ -> found | None -> next ()) None options in
  match expr with
  | EApp _ | EBinop _ ->
    first_of [
      (fun () -> Option.map (fun (seed, clauses) -> SqlSelect (seed, clauses))
        (Sql_query.extract_select_query expr));
      (fun () -> Option.map (fun insert -> SqlInsert insert)
        (Sql_query.parse_insert_expr expr));
      (fun () -> Option.map (fun (list_var, entity) -> SqlInsertMany (list_var, entity))
        (Sql_query.parse_insert_many_expr expr));
      (fun () -> Option.map (fun (seed, clauses) -> SqlDelete (seed, clauses))
        (Sql_query.extract_delete_query expr));
    ]
  | ELet _ ->
    first_of [
      (fun () -> Option.map (fun update -> SqlUpdate update) (Sql_query.extract_update expr));
      (fun () -> Option.map (fun (seed, clauses) -> SqlDelete (seed, clauses))
        (Sql_query.extract_delete expr));
      (fun () -> Option.map (fun (seed, clauses) -> SqlSelect (seed, clauses))
        (Sql_query.extract_multiline_select_query expr));
    ]
  | _ -> None

(* A query names its entity, and the entity carries both its row type and its store.
   `Tesl.Database`'s own names (`Database`, `Memory`) never reach here — a query's `from`
   is always a declared entity — so failing to find one is a compile error, not a
   fallback. *)
let entity_of_query loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.entities name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve entity `%s`" name

(* A queue is found by the JOB TYPE (`enqueue`) or by its own name (an api-test verb); the
   table holds both keys. *)
let queue_of_job_type loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.queues name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve a queue for `%s`" name

(* An api-test queue verb takes the QUEUE as its only argument, written as a bare name
   (`pendingJobCount SendQueue`), which parses as a constructor. *)
let queue_argument args =
  match args with
  | [EConstructor { name; args = []; _ }] | [EVar { name; _ }] -> Some name
  | _ -> None

let job_result_type signatures loc (info : queue_info) =
  let payload =
    match Option.bind !current_types
            (fun types -> Hashtbl.find_opt types.records info.qu_job_type) with
    | Some row -> TRecord row
    | None -> unsupported loc "Go backend cannot resolve job type `%s`" info.qu_job_type
  in
  match Hashtbl.find_opt signatures "JobOk" with
  | Some { result = TAdt (adt, _); _ } -> TAdt (adt, [payload])
  | _ -> unsupported loc
    "Go backend needs `JobResult` imported from `Tesl.ApiTest` for `processNextJob`"

(* `check (checkA && checkB) x` — a COMBINED check.  Racket's `check-and` runs the first,
   short-circuits on rejection, and passes the checked value to the next; the facts are
   merged into one conjunction.  Here the facts erase, so what is left is the sequencing. *)
let rec check_conjuncts expr =
  match expr with
  | EBinop { op = BAnd; left; right; _ } ->
    (match check_conjuncts left, check_conjuncts right with
     | Some left_names, Some right_names -> Some (left_names @ right_names)
     | _ -> None)
  | EVar { name; _ } -> Some [name]
  | _ -> None

let entity_column loc (info : entity_info) field =
  match List.assoc_opt field info.ent_row.rec_fields with
  | Some ty -> ty
  | None -> unsupported loc "Go backend: entity `%s` has no column `%s`"
    info.ent_tesl_name field

(* The tag is EXPORTED: an ADT provided by the runtime (or, later, by another
   emitted module) is matched from a different package, where an unexported field
   would be invisible. *)
(* `Tesl.List` leaves are element-polymorphic, so they cannot be fixed signatures
   like the String leaves.  Arity and argument ORDER come from tesl/list.tesl:
   `take n xs`, `member x xs`, `append xs ys`. *)
type list_leaf = {
  leaf_name : string;
  leaf_go : string;
  leaf_arity : int;
  (* How the result type is built from the element type of the list argument. *)
  (* `Inner` is for a leaf over a list OF lists, whose result is the inner list. *)
  leaf_result : [ `Int | `Bool | `Same | `MaybeElement | `MaybeSame | `Inner ];
  (* Which extra closure the runtime function takes, if any. *)
  leaf_closure : [ `None | `Equal | `Less ];
  (* Index of the argument that is the list, and of a non-list argument to check. *)
  leaf_list_index : int;
}

let list_leaves = [
  { leaf_name = "List.length"; leaf_go = "teslrt.ListLength"; leaf_arity = 1;
    leaf_result = `Int; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.isEmpty"; leaf_go = "teslrt.ListIsEmpty"; leaf_arity = 1;
    leaf_result = `Bool; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.head"; leaf_go = "teslrt.ListHead"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.last"; leaf_go = "teslrt.ListLast"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.tail"; leaf_go = "teslrt.ListTail"; leaf_arity = 1;
    leaf_result = `MaybeSame; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.reverse"; leaf_go = "teslrt.ListReverse"; leaf_arity = 1;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.sum"; leaf_go = "teslrt.ListSum"; leaf_arity = 1;
    leaf_result = `Int; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.append"; leaf_go = "teslrt.ListAppend"; leaf_arity = 2;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.take"; leaf_go = "teslrt.ListTake"; leaf_arity = 2;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 1 };
  { leaf_name = "List.drop"; leaf_go = "teslrt.ListDrop"; leaf_arity = 2;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 1 };
  { leaf_name = "List.member"; leaf_go = "teslrt.ListMemberBy"; leaf_arity = 2;
    leaf_result = `Bool; leaf_closure = `Equal; leaf_list_index = 1 };
  { leaf_name = "List.contains"; leaf_go = "teslrt.ListMemberBy"; leaf_arity = 2;
    leaf_result = `Bool; leaf_closure = `Equal; leaf_list_index = 1 };
  { leaf_name = "List.unique"; leaf_go = "teslrt.ListUniqueBy"; leaf_arity = 1;
    leaf_result = `Same; leaf_closure = `Equal; leaf_list_index = 0 };
  { leaf_name = "List.sort"; leaf_go = "teslrt.ListSortBy"; leaf_arity = 1;
    leaf_result = `Same; leaf_closure = `Less; leaf_list_index = 0 };
  (* `flatten` is `concat` under another name, per the stdlib docs. *)
  { leaf_name = "List.concat"; leaf_go = "teslrt.ListConcat"; leaf_arity = 1;
    leaf_result = `Inner; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.flatten"; leaf_go = "teslrt.ListConcat"; leaf_arity = 1;
    leaf_result = `Inner; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.maximum"; leaf_go = "teslrt.ListMaximum"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `Less; leaf_list_index = 0 };
  { leaf_name = "List.minimum"; leaf_go = "teslrt.ListMinimum"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `Less; leaf_list_index = 0 };
]

let list_leaf name = List.find_opt (fun leaf -> leaf.leaf_name = name) list_leaves

(* Dict leaves are polymorphic in both key and value, so like the list leaves they are
   typed per call site rather than by a fixed signature.  Every one that has to find a
   key takes the key ORDERING the emitter supplies — the same device used for list
   equality and sorting. *)
type dict_leaf = {
  dict_name : string;
  dict_go : string;
  dict_arity : int;
  dict_result : [ `Dict | `MaybeValue | `Int | `Bool | `Keys | `Values | `Pairs ];
  dict_needs_order : bool;
}

let dict_leaves = [
  { dict_name = "Dict.empty"; dict_go = "teslrt.DictEmpty"; dict_arity = 0;
    dict_result = `Dict; dict_needs_order = false };
  { dict_name = "Dict.insert"; dict_go = "teslrt.DictInsert"; dict_arity = 3;
    dict_result = `Dict; dict_needs_order = true };
  { dict_name = "Dict.lookup"; dict_go = "teslrt.DictLookup"; dict_arity = 2;
    dict_result = `MaybeValue; dict_needs_order = true };
  { dict_name = "Dict.member"; dict_go = "teslrt.DictMember"; dict_arity = 2;
    dict_result = `Bool; dict_needs_order = true };
  { dict_name = "Dict.remove"; dict_go = "teslrt.DictRemove"; dict_arity = 2;
    dict_result = `Dict; dict_needs_order = true };
  { dict_name = "Dict.size"; dict_go = "teslrt.DictSize"; dict_arity = 1;
    dict_result = `Int; dict_needs_order = false };
  { dict_name = "Dict.isEmpty"; dict_go = "teslrt.DictIsEmpty"; dict_arity = 1;
    dict_result = `Bool; dict_needs_order = false };
  { dict_name = "Dict.keys"; dict_go = "teslrt.DictKeys"; dict_arity = 1;
    dict_result = `Keys; dict_needs_order = false };
  { dict_name = "Dict.values"; dict_go = "teslrt.DictValues"; dict_arity = 1;
    dict_result = `Values; dict_needs_order = false };
  { dict_name = "Dict.toList"; dict_go = "teslrt.DictToList"; dict_arity = 1;
    dict_result = `Pairs; dict_needs_order = false };
  { dict_name = "Dict.fromList"; dict_go = "teslrt.DictFromList"; dict_arity = 1;
    dict_result = `Dict; dict_needs_order = true };
]

let dict_leaf name = List.find_opt (fun leaf -> leaf.dict_name = name) dict_leaves

(* Set leaves.  `set_result` says how the result is built from the element type; the Set
   argument keeps its Tesl position, since the runtime signatures were written to match
   (`SetInsert(value, s, less)`). *)
type set_leaf = {
  set_name : string;
  set_go : string;
  set_arity : int;
  set_result : [ `Set | `Int | `Bool | `Elements ];
  set_needs_order : bool;
  (* Index of the Set argument, or -1 when there is none (`Set.empty`). *)
  set_index : int;
}

let set_leaves = [
  { set_name = "Set.empty"; set_go = "teslrt.SetEmpty"; set_arity = 0;
    set_result = `Set; set_needs_order = false; set_index = -1 };
  { set_name = "Set.singleton"; set_go = "teslrt.SetSingleton"; set_arity = 1;
    set_result = `Set; set_needs_order = false; set_index = -1 };
  { set_name = "Set.member"; set_go = "teslrt.SetMember"; set_arity = 2;
    set_result = `Bool; set_needs_order = true; set_index = 1 };
  { set_name = "Set.insert"; set_go = "teslrt.SetInsert"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 1 };
  { set_name = "Set.remove"; set_go = "teslrt.SetRemove"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 1 };
  { set_name = "Set.delete"; set_go = "teslrt.SetRemove"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 1 };
  { set_name = "Set.size"; set_go = "teslrt.SetSize"; set_arity = 1;
    set_result = `Int; set_needs_order = false; set_index = 0 };
  { set_name = "Set.isEmpty"; set_go = "teslrt.SetIsEmpty"; set_arity = 1;
    set_result = `Bool; set_needs_order = false; set_index = 0 };
  { set_name = "Set.toList"; set_go = "teslrt.SetToList"; set_arity = 1;
    set_result = `Elements; set_needs_order = false; set_index = 0 };
  { set_name = "Set.fromList"; set_go = "teslrt.SetFromList"; set_arity = 1;
    set_result = `Set; set_needs_order = true; set_index = -1 };
  { set_name = "Set.union"; set_go = "teslrt.SetUnion"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 0 };
  { set_name = "Set.intersection"; set_go = "teslrt.SetIntersection"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 0 };
  { set_name = "Set.difference"; set_go = "teslrt.SetDifference"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 0 };
  { set_name = "Set.isSubset"; set_go = "teslrt.SetIsSubset"; set_arity = 2;
    set_result = `Bool; set_needs_order = true; set_index = 0 };
]

let set_leaf name = List.find_opt (fun leaf -> leaf.set_name = name) set_leaves

(* `Tuple2.first p` is a field read dressed as a call: the accessors are the only way
   to reach a tuple's components, since a tuple has no user-visible field syntax. *)
let tuple_accessor = function
  | "Tuple2.first" -> Some ("Tuple2", "first")
  | "Tuple2.second" -> Some ("Tuple2", "second")
  | "Tuple3.first" -> Some ("Tuple3", "first")
  | "Tuple3.second" -> Some ("Tuple3", "second")
  | "Tuple3.third" -> Some ("Tuple3", "third")
  | _ -> None

(* The higher-order leaves lower to an emitted LOOP rather than a runtime helper: a Go
   func value passed into a generic helper costs an indirect call per element and
   blocks inlining, and these are hot-path functions.  A lambda argument's body is
   inlined into the loop (no closure, no call), a named function becomes a direct
   call. *)
type hof =
  | HofMap | HofFilter | HofFoldl | HofFoldr | HofAny | HofAll | HofFilterCheck
  | HofAllCheck | HofZip | HofFind | HofFilterMap | HofConcatMap | HofSortBy

let higher_order_leaf = function
  | "List.map" -> Some HofMap
  | "List.filter" -> Some HofFilter
  | "List.foldl" -> Some HofFoldl
  | "List.foldr" -> Some HofFoldr
  | "List.any" -> Some HofAny
  | "List.all" -> Some HofAll
  | "List.filterCheck" -> Some HofFilterCheck
  | "List.allCheck" -> Some HofAllCheck
  | "List.zip" -> Some HofZip
  | "List.find" -> Some HofFind
  | "List.filterMap" -> Some HofFilterMap
  | "List.concatMap" -> Some HofConcatMap
  | "List.sortBy" -> Some HofSortBy
  | _ -> None

let higher_order_leaf_names =
  ["List.map"; "List.filter"; "List.foldl"; "List.foldr"; "List.any"; "List.all";
   "List.filterCheck"; "List.allCheck"; "List.zip"; "List.find"; "List.filterMap";
   "List.concatMap"; "List.sortBy"]

let hof_arity = function
  | HofFoldl | HofFoldr -> 3
  | HofFind | HofFilterMap | HofConcatMap | HofSortBy -> 2
  | HofMap | HofFilter | HofAny | HofAll | HofFilterCheck | HofAllCheck | HofZip -> 2

(* Every constructor is registered in the signature table under its own name, so a
   constructor application resolves without knowing its ADT up front. *)
let adt_ctor_of_signature signatures name =
  match Hashtbl.find_opt signatures name with
  | Some { result = TAdt (info, _); _ } ->
    (match find_variant info name with
     | Some variant -> Some (info, variant)
     | None -> None)
  | _ -> None

let lookup_env loc name env =
  match List.assoc_opt name env with
  | Some ty -> ty
  | None -> unsupported loc "Go backend cannot resolve value `%s`" name

let rec flatten_app args = function
  | EApp { fn; arg; _ } -> flatten_app (arg :: args) fn
  | head -> head, args

(* `String.length s` parses as a field access over the module name (`String` is a
   UIDENT, so it is an EConstructor).  Normalising it to the qualified name lets the
   ordinary call path resolve it against the stdlib signature table. *)
let normalize_call_head = function
  | EField { obj = EConstructor { name = module_name; args = []; _ }; field; loc } ->
    EVar { name = module_name ^ "." ^ field; loc }
  | head -> head

let normalize_call_args params args =
  match params, args with
  | [], [EConstructor { name = "Unit"; args = []; _ }]
  | [], [EList { elems = []; _ }] -> []
  | _ -> args

let expect_fail_call fn arg loc =
  let args = match arg with
    | EList { elems = []; _ } -> []
    | _ ->
      let head, rest = flatten_app [] arg in
      head :: rest
  in
  List.fold_left (fun call arg -> EApp { fn = call; arg; loc }) fn args

let bool_literal_value = function
  | ELit { lit = LBool value; _ } -> Some value
  | EConstructor { name = "True"; args = []; _ } -> Some true
  | EConstructor { name = "False"; args = []; _ } -> Some false
  | _ -> None

(* `check f a b` — a CHECK APPLICATION.  Two things depend on telling one apart from an
   ordinary call: its type (the check's value, not its `Check`), and — inside another
   check — that a rejection must PROPAGATE rather than trap. *)
let check_application signatures expr =
  match expr with
  | EApp _ ->
    let rec flatten acc = function
      | EApp { fn; arg; _ } -> flatten (arg :: acc) fn
      | head -> head, acc
    in
    (match flatten [] expr with
     | EVar { name = "check"; _ }, (callee :: args) ->
       (* The callee is NORMALISED first: a stdlib name is written `Crypto.checkSignature`,
          which parses as a field read on a constructor rather than as one identifier.  Without
          this, `let v = check Crypto.checkSignature …` inside a check or an `auth` fell through
          to the non-propagating path and emitted `MustCheck` — a PANIC where the request should
          have answered 401, i.e. a verification failure crashed the request instead of
          rejecting it. *)
       (match normalize_call_head callee with
        | EVar { name; _ } ->
          (match Hashtbl.find_opt signatures name with
           | Some ({ result = TCheck _; _ } as signature)
             when List.length args = List.length signature.params -> Some (signature, args)
           | _ -> None)
        | _ -> None)
     | _ -> None)
  | _ -> None

(* The type of a query.  A `select` yields rows, `selectOne` a `Maybe` row, and the
   write forms yield either the row they wrote or nothing at all — which is Tesl's `Unit`
   and Go's empty struct.  The aggregate and grouped forms are refused rather than
   guessed: each needs its own comparison or arithmetic over a column type. *)
let type_of_sql_form signatures loc form =
  let maybe_of inner =
    match adt_ctor_of_signature signatures "Nothing" with
    | Some (info, _) -> TAdt (info, [inner])
    | None -> unsupported loc
      "Go backend `selectOne` yields a Maybe; import `Tesl.Maybe`"
  in
  match form with
  | SqlSelect (seed, _) ->
    let info = entity_of_query loc seed.entity in
    let row = TRecord info.ent_row in
    (match seed.kind with
     | SelectMany -> TList row
     | SelectOne -> maybe_of row
     | SelectCount -> TInt
     (* A scalar aggregate speaks in its COLUMN's type — a sum of Money is Money — which is
        what the checker infers too (select_aggregate_field_type).  MAX/MIN are OPTIONAL:
        over no matching row they have no value of that type, and SUM does (zero). *)
     | SelectSum field -> entity_column loc info field
     | SelectMax field | SelectMin field -> maybe_of (entity_column loc info field)
     | SelectCountBy -> unsupported loc "Go backend does not support `selectCountBy` yet"
     | SelectSumBy _ -> unsupported loc "Go backend does not support `selectSumBy` yet")
  | SqlInsert insert -> TRecord (entity_of_query loc insert.entity).ent_row
  (* `insertMany` is typed as the entity by the checker but RETURNS nothing on Racket
     (`insert-many!` ends in `(void)`), so the only sound reading of its result here is
     `Unit`: a program that bound and used it would be broken on the other backend. *)
  | SqlInsertMany (_, entity) -> ignore (entity_of_query loc entity); TUnit
  | SqlUpdate update ->
    if update.returning_one then TRecord (entity_of_query loc update.entity).ent_row
    else TUnit
  | SqlDelete (seed, _) ->
    if seed.with_result then unsupported loc
      "Go backend does not support `deleteAndReturnResult` yet"
    else begin ignore (entity_of_query loc seed.entity); TUnit end

let rec type_of_expr signatures env expr =
  match expr with
  | ELit { lit = LInt _ | LBigInt _; _ } -> TInt
  | ELit { lit = LString _; _ } -> TString
  | ELit { lit = LBool _; _ } -> TBool
  | ELit { lit = LFloat _; _ } -> TFloat
  | ELit { lit = LInterp segments; _ } ->
    List.iter (function
      | ILiteral _ -> ()
      | IExpr expr ->
        (match type_of_expr signatures env expr with
         | TString | TInt | TBool | TFloat -> ()
         | _ -> unsupported (Checker.expr_loc expr)
           "Go backend interpolation supports String, Int, Float, and Bool only")) segments;
    TString
  | EVar { name; loc } ->
    (* A bare function name is a function VALUE, which the Go subset has no
       representation for.  Emitting a call here would diverge from the Racket
       backend, which hands back a procedure. *)
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some ty, _ -> ty
     (* A named function referred to WITHOUT arguments is a function value: Go spells that
        the same way (the function's own name), so the type is its signature read as an
        arrow.  A check is excluded — its `Check` result is not an ordinary value. *)
     | None, Some { params = (_ :: _ as params); result = (TCheck _ as result); _ } ->
       ignore params; ignore result;
       unsupported loc "Go backend does not support a `check` as a function value"
     | None, Some { params = (_ :: _ as params); result; _ } -> TFunc (params, result)
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> lookup_env loc name env)
  | EConstructor { name = "True" | "False"; args = []; _ } -> TBool
  | EConstructor { name = "Unit"; args = []; _ } -> TUnit
  | EConstructor { name; args; loc } when adt_ctor_of_signature signatures name <> None ->
    let info, variant = match adt_ctor_of_signature signatures name with
      | Some pair -> pair
      | None -> assert false
    in
    type_of_variant_application signatures env loc info variant args
  | EConstructor { name; args; loc } ->
    (match Hashtbl.find_opt signatures name with
     | Some { params = [base]; result = (TNewtype _ as result); _ } ->
       (match args with
        | [arg] when type_of_expr signatures env arg = base -> result
        | [_] -> unsupported loc "Go backend newtype constructor `%s` argument type mismatch" name
        | _ -> unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
     (* A proof term: `ValidPort port` applies a FACT, which erases to the zero-size proof.
        Its arguments are proof subjects, so nothing is evaluated. *)
     | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> TUnit
     | _ -> unsupported loc "Go backend does not support constructor `%s` yet" name)
  (* A query's type comes from its ENTITY and its form, not from a signature: `select`
     and friends are surface syntax rather than functions. *)
  | (EApp _ | EBinop _ | ELet _) as sql when recognise_sql sql <> None ->
    let loc = Checker.expr_loc sql in
    (match recognise_sql sql with
     | Some form -> type_of_sql_form signatures loc form
     | None -> assert false)
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
    let head = normalize_call_head head in
    (match head with
     | EVar { name = "#record-update#"; _ } ->
       (match args with
        | [ERecord { fields; _ }] -> type_of_record_update signatures env loc fields
        | _ -> unsupported loc "Go backend cannot resolve this record update")
     | EConstructor { name; args = constructor_args; _ }
       when record_info_of_signature signatures name <> None ->
       let info = match record_info_of_signature signatures name with
         | Some info -> info
         | None -> assert false
       in
       (match constructor_args @ args with
        | [ERecord { fields; _ }] ->
          check_record_literal signatures env loc info fields;
          TRecord info
        | _ -> unsupported loc "Go backend requires a `%s { field: value }` record literal" name)
     | EConstructor { name; args = constructor_args; _ }
       when adt_ctor_of_signature signatures name <> None ->
       let info, variant = match adt_ctor_of_signature signatures name with
         | Some pair -> pair
         | None -> assert false
       in
       type_of_variant_application signatures env loc info variant (constructor_args @ args)
     (* `exists name => body` parses as `make-witness (name body)`: the witness is a proof
        SUBJECT, not a value the caller receives, so the package erases to its body. *)
     | EVar { name = "make-witness"; _ } ->
       (match args with
        | [EApp { arg = body; _ }] -> type_of_expr signatures env body
        | [body] -> type_of_expr signatures env body
        | _ -> unsupported loc "Go backend cannot resolve this existential package")
     | EVar { name = "check"; _ }
       when (match args with
             | conjunction :: _ ->
               (match check_conjuncts conjunction with
                | Some (_ :: _ :: _) -> true
                | _ -> false)
             | [] -> false) ->
       (* Every conjunct is a check over the SAME type, since each one's result feeds the
          next; the combined result is that type, exactly as for a single check. *)
       let names = match args with
         | conjunction :: _ -> Option.value (check_conjuncts conjunction) ~default:[]
         | [] -> []
       in
       let value_ty = List.fold_left (fun expected name ->
         match Hashtbl.find_opt signatures name with
         | Some { params = [param]; result = TCheck result; _ }
           when param = result && (expected = None || expected = Some result) -> Some result
         | Some { params = [_]; result = TCheck _; _ } ->
           unsupported loc
             "Go backend combined check `%s` does not check the same type as the others" name
         | Some _ -> unsupported loc "`%s` is not a check" name
         | None -> unsupported loc "Go backend cannot resolve check `%s`" name) None names
       in
       (match value_ty, args with
        | Some want, [_; argument] ->
          if type_of_arg signatures env want argument <> want then
            unsupported (Checker.expr_loc argument)
              "Go backend combined check argument type mismatch";
          want
        | Some _, _ -> unsupported loc
          "Go backend requires a combined check applied to exactly one value"
        | None, _ -> unsupported loc "Go backend cannot resolve this combined check")
     | EVar { name = "check"; _ } ->
       (match List.map normalize_call_head args with
        | EVar { name; _ } :: call_args ->
          (match Hashtbl.find_opt signatures name with
            | Some { params; result = TCheck result; _ } ->
             if List.length params <> List.length call_args then
               unsupported loc "Go backend requires a fully-applied check `%s`" name;
             List.iter2 (fun arg want ->
               if type_of_arg signatures env want arg <> want then
                 unsupported (Checker.expr_loc arg) "Go backend check `%s` argument type mismatch" name)
               call_args params;
             result
           | Some _ -> unsupported loc "`%s` is not a check" name
           | None -> unsupported loc "Go backend cannot resolve check `%s`" name)
         | _ -> unsupported loc "Go backend requires `check` followed by a named check function")
      | EVar { name = "not"; _ } when not (Hashtbl.mem signatures "not") ->
       (match args with
        | [arg] when type_of_expr signatures env arg = TBool -> TBool
        | [_] -> unsupported loc "Go backend `not` requires Bool"
         | _ -> unsupported loc "Go backend requires a fully-applied call to `not`")
      | EConstructor { name; args = constructor_args; _ } ->
        (match Hashtbl.find_opt signatures name with
         | Some { params = [base]; result = (TNewtype _ as result); _ } ->
           let args = constructor_args @ args in
           (match args with
            | [arg] when type_of_expr signatures env arg = base -> result
            | [_] ->
              unsupported loc "Go backend newtype constructor `%s` argument type mismatch" name
            | _ ->
              unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
         (* An APPLIED fact — the proof term `ValidPort port` — erases to the zero proof. *)
         | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> TUnit
         | _ -> unsupported loc "Go backend does not support constructor `%s` yet" name)
      | EVar { name; _ } when set_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match set_leaf name with Some leaf -> leaf | None -> assert false in
       (* No expectation is available here; `Set.empty` resolves through type_of_arg,
          which is the path that carries one. *)
       type_of_set_leaf signatures env loc leaf args None
      | EVar { name; _ } when dict_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
       type_of_dict_leaf signatures env loc leaf args
      | EVar { name; _ } when tuple_accessor name <> None ->
       let owner, field = match tuple_accessor name with
         | Some pair -> pair
         | None -> assert false
       in
       (match args with
        | [tuple] ->
          (match type_of_expr signatures env tuple with
           | TAdt (info, type_args) when info.adt_tesl_name = owner ->
             (match single_variant info with
              | Some variant ->
                (match List.assoc_opt field (variant_field_types info type_args variant) with
                 | Some ty -> ty
                 | None -> unsupported loc "Go backend `%s` has no component `%s`" owner field)
              | None -> unsupported loc "Go backend `%s` is not a tuple" owner)
           | _ -> unsupported loc "Go backend `%s` requires a `%s` argument" name owner)
        | _ -> unsupported loc "Go backend requires `%s` applied to 1 argument" name)
      (* The GDP proof combinators erase: a proof has no runtime content, so `attachFact`
         and `forgetFact` are the identity on their value and `detachFact`/`introAnd`/
         `andLeft`/`andRight` produce the zero-size proof value. *)
      | EVar { name = ("forgetFact" | "attachFact") ; _ } when args <> [] ->
        type_of_expr signatures env (List.hd args)
      (* A request verb inside an `api-test` drives the server under test. *)
      | EVar { name = ("get" | "post" | "put" | "delete" | "patch"); _ }
        when !current_api_server <> None ->
        (match !current_types with
         | Some types ->
           (match Hashtbl.find_opt types.records api_response_key with
            | Some info -> TRecord info
            | None -> unsupported loc
              "Go backend needs `Tesl.ApiTest` imported for a request in an api-test")
         | None -> unsupported loc "Go backend cannot resolve the api-test response type")
      (* The api-test queue verbs name a QUEUE, which the emitter resolves statically; their
        result types come from the queue's job type. *)
     | EVar { name = ("pendingJobCount" | "drainQueue" | "processNextJob"
                     | "processNextDeadJob" | "deadJobs") as verb; _ }
       when queue_argument args <> None ->
       let info = match queue_argument args with
         | Some name -> queue_of_job_type loc name
         | None -> assert false
       in
       (match verb with
        | "pendingJobCount" -> TInt
        | "drainQueue" -> TUnit
        (* The dead-letter contents.  `DeadJob` is opaque — a test counts the list or
           requeues from it, which is all the Racket surface allows either. *)
        | "deadJobs" ->
          (match Option.bind !current_types (fun types ->
                   Hashtbl.find_opt types.records "DeadJob") with
           | Some row -> TList (TRecord row)
           | None -> unsupported loc
             "Go backend needs `deadJobs` imported from `Tesl.Queue`")
        | _ -> job_result_type signatures loc info)
     (* The secret-accepting header builders.  Their secret parameter is deliberately NOT
        matched against a fixed type: every `secret` newtype is a distinct Go type, and the
        generic call path demands an exact match, so the argument is checked here and unwrapped
        at the emit site.  A plain String is accepted for the same reason Racket accepts one. *)
     | EVar { name = ("HttpClient.bearer" | "HttpClient.secretHeader") as leaf; _ } ->
       let signature = match Hashtbl.find_opt signatures leaf with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" leaf
       in
       let secret = match leaf, args with
         | "HttpClient.bearer", [secret] -> secret
         | "HttpClient.secretHeader", [name; secret] ->
           if type_of_expr signatures env name <> TString then
             unsupported (Checker.expr_loc name)
               "Go backend `HttpClient.secretHeader` takes a String header name";
           secret
         | _ -> unsupported loc "Go backend `%s` is applied to the wrong arity" leaf
       in
       (match type_of_expr signatures env secret with
        | TNewtype info when info.secret -> ()
        | TString -> ()
        | _ -> unsupported (Checker.expr_loc secret)
          "Go backend `%s` takes a `secret` over String" leaf);
       signature.result
     | EVar { name = ("expectJobOk" | "expectJobFailed"); _ } ->
       (match args with
        | [result] ->
          (match type_of_expr signatures env result with
           | TAdt (info, [payload]) when info.adt_tesl_name = "JobResult" -> payload
           | _ -> unsupported loc
             "Go backend `expectJobOk` takes the result of `processNextJob`")
        | _ -> unsupported loc "Go backend requires `expectJobOk` applied to 1 argument")
     (* The api-test JSON surface.  Every one of these takes the UNTYPED value, and the
        argument order is Tesl's (needle/index/field first), matching tesl/api-test.rkt. *)
     | EVar { name = ("isNull" | "isNotNull" | "isEmpty" | "isNotEmpty"); _ } -> TBool
     | EVar { name = ("hasField" | "hasLength" | "jsonContains"); _ } -> TBool
     | EVar { name = "jsonLength"; _ } -> TInt
     | EVar { name = "jsonInt"; _ } -> TInt
     | EVar { name = "jsonString"; _ } -> TString
     | EVar { name = "jsonBool"; _ } -> TBool
     | EVar { name = ("arrayAt" | "fieldAt" | "bodyField" | "jsonArray" | "jsonObject"); _ } ->
       TJson
     | EVar { name = ("statusOk" | "statusClientError" | "statusServerError"); _ } -> TBool
      (* `Http.clearSessionCookie()` returns Unit and writes to the response. *)
      | EVar { name = "Http.clearSessionCookie"; _ } -> TUnit
      | EVar { name = ("detachFact" | "introAnd" | "andLeft" | "andRight"); _ } -> TUnit
      | EVar { name; _ } when higher_order_leaf name <> None && Hashtbl.mem signatures name ->
       let hof = match higher_order_leaf name with Some hof -> hof | None -> assert false in
       type_of_hof signatures env loc name hof args
      (* `List.range` and `List.repeat` CONSTRUCT a list rather than consuming one, so
         they carry no list argument for the leaf table to read an element type from.
         `range` is always `List Int`; `repeat` takes its element from its first
         argument.  Their counts carry an `IsNonNegative` proof that erases, so nothing
         about the count survives to the emitted call. *)
      | EVar { name = "List.range"; _ } when Hashtbl.mem signatures "List.range" ->
        if List.length args <> 2 then
          unsupported loc "Go backend requires `List.range` applied to 2 argument(s)";
        List.iter (fun arg ->
          if type_of_expr signatures env arg <> TInt then
            unsupported loc "Go backend `List.range` takes two Ints") args;
        TList TInt
      | EVar { name = "List.repeat"; _ } when Hashtbl.mem signatures "List.repeat" ->
        if List.length args <> 2 then
          unsupported loc "Go backend requires `List.repeat` applied to 2 argument(s)";
        if type_of_expr signatures env (List.nth args 1) <> TInt then
          unsupported loc "Go backend `List.repeat` takes a count as its second argument";
        TList (type_of_expr signatures env (List.nth args 0))
      | EVar { name; _ } when list_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match list_leaf name with Some leaf -> leaf | None -> assert false in
       type_of_list_leaf signatures env loc leaf args
      (* Calling a FUNCTION VALUE — a parameter or a `let`-bound lambda.  Its type says the
         arity, and a partial application is refused rather than curried: Go has no partial
         application, and inventing a closure would hide the arity mismatch. *)
      | EVar { name; _ } when (match List.assoc_opt name env with
                               | Some (TFunc _) -> true | _ -> false) ->
        let params, result = match List.assoc_opt name env with
          | Some (TFunc (params, result)) -> params, result
          | _ -> assert false
        in
        if List.length args <> List.length params then
          unsupported loc
            "Go backend requires the function value `%s` applied to %d argument(s)"
            name (List.length params);
        List.iter2 (fun arg want ->
          if type_of_arg signatures env want arg <> want then
            unsupported (Checker.expr_loc arg)
              "Go backend call through `%s` has an unsupported argument type" name)
          args params;
        result
      | EVar { name; _ } ->
       (match Hashtbl.find_opt signatures name with
        | None -> unsupported loc "Go backend cannot resolve function `%s`" name
        | Some signature ->
          let args = normalize_call_args signature.params args in
          if List.length args <> List.length signature.params then
            unsupported loc "Go backend requires a fully-applied call to `%s`" name;
          List.iter2 (fun arg want ->
            let got = type_of_arg signatures env want arg in
            if got <> want then unsupported (Checker.expr_loc arg)
              "Go backend call to `%s` has an unsupported argument type" name)
            args signature.params;
          signature.result)
     (* A call through any FUNCTION-VALUED expression — a record field holding one, say —
        not just through a name. *)
     | head when (match type_of_expr signatures env head with TFunc _ -> true | _ -> false) ->
       let params, result = match type_of_expr signatures env head with
         | TFunc (params, result) -> params, result
         | _ -> assert false
       in
       if List.length args <> List.length params then
         unsupported loc "Go backend requires this function value applied to %d argument(s)"
           (List.length params);
       List.iter2 (fun arg want ->
         if type_of_arg signatures env want arg <> want then
           unsupported (Checker.expr_loc arg)
             "Go backend call through a function value has an unsupported argument type")
         args params;
       result
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  | EBinop { op; left; right; loc; _ } ->
    (* A DEFAULTED empty list yields to a real type here for the same reason it does in an
       `if` branch: `List.reverse words == []` compares `List String`, not the default. *)
    let left_result, left_defaulted = typed_with_default (type_of_expr signatures env) left in
    let right_result, right_defaulted = typed_with_default (type_of_expr signatures env) right in
    let left_ty, right_ty = match left_result, right_result with
      | Some left_ty, Some right_ty when left_defaulted && not right_defaulted ->
        ignore left_ty; right_ty, right_ty
      | Some left_ty, Some right_ty when right_defaulted && not left_defaulted ->
        ignore right_ty; left_ty, left_ty
      | Some left_ty, Some right_ty -> left_ty, right_ty
      | _ ->
        (* Nothing to reconcile: re-type so the original error is reported. *)
        type_of_expr signatures env left, type_of_expr signatures env right
    in
    (* An UNTYPED api-test value compares against anything: `expect resp.body.age == 7` is
       the point of the dynamic view, and on Racket both sides are ordinary values by then.
       Only equality is allowed — ordering an untyped value has no meaning the source can
       rely on. *)
    if (left_ty = TJson || right_ty = TJson) && left_ty <> right_ty then begin
      match op with
      | BEq | BNeq -> ()
      | _ -> unsupported loc
        "Go backend supports `==` / `!=` on an api-test JSON value, not this operator"
    end
    else if left_ty <> right_ty then
      unsupported loc "Go backend binary operands have different types";
    (match op with
     | BAdd | BSub | BMul | BDiv ->
       (match left_ty with
        | TInt -> TInt
        | TFloat -> TFloat
        | _ -> unsupported loc "Go backend arithmetic requires Int or Float")
     | BMod ->
       (* Racket's `modulo`/`remainder` are integer operations; a Float `%` does not
          exist in Go either. *)
       if left_ty <> TInt then unsupported loc "Go backend `%%` requires Int";
       TInt
     | BConcat ->
       if left_ty <> TString then unsupported loc "Go backend ++ requires String";
       TString
     | BAnd | BOr ->
       if left_ty <> TBool then unsupported loc "Go backend boolean operator requires Bool";
       TBool
     | BEq | BNeq ->
       (* A generic ADT (or anything holding a type parameter) has no comparable Go
          form, so equality on it fails closed rather than reaching the emitter. *)
       if not (supports_equality left_ty) then unsupported loc
         "Go backend does not support equality on this type yet";
       TBool
      | BLt | BLe | BGt | BGe ->
        if not (supports_ordering left_ty) then
          unsupported loc "Go backend ordering supports Int, String, and their scalar newtypes only";
        TBool)
  | EUnop { op; arg; loc } ->
    let arg_ty = type_of_expr signatures env arg in
    (match op with
     | UNeg ->
       (match arg_ty with
        | TInt -> TInt
        | TFloat -> TFloat
        | _ -> unsupported loc "Go backend unary - requires Int or Float")
     | UNot -> if arg_ty <> TBool then unsupported loc "Go backend ! requires Bool"; TBool)
  | EIf { cond; then_; else_; loc } ->
    if type_of_expr signatures env cond <> TBool then
      unsupported loc "Go backend if condition must be Bool";
    (* A branch can be UNDER-CONSTRAINED on its own while the other settles the type —
       `if isEmpty s then [] else [s]`, the body of a `concatMap` lambda.  Whichever branch
       types supplies the type, and the other is then checked against it through
       `type_of_arg`, which is the expectation the emitter passes down anyway.  Same
       tolerance as `case` arms; if NEITHER branch types, the first one is re-typed so the
       real reason is what gets reported. *)
    let attempt expr = typed_with_default (type_of_expr signatures env) expr in
    let then_result, then_defaulted = attempt then_ in
    let else_result, else_defaulted = attempt else_ in
    (match then_result, else_result with
     | Some TFailure, Some TFailure -> TFailure
     | Some TFailure, Some ty | Some ty, Some TFailure -> ty
     (* A DEFAULTED branch yields to a real type: `if c then [] else ["a"]`. *)
     | Some _, Some ty when then_defaulted && not else_defaulted -> ty
     | Some ty, Some _ when else_defaulted && not then_defaulted -> ty
     | Some left, Some right when left = right -> left
     | Some _, Some _ -> unsupported loc "Go backend if branches have different types"
     | Some ty, None | None, Some ty ->
       let other = if then_result = None then then_ else else_ in
       if type_of_arg signatures env ty other <> ty then
         unsupported loc "Go backend if branches have different types";
       ty
     | None, None -> type_of_expr signatures env then_)
  | ELet { name; value; body; _ } ->
    let value_ty = type_of_expr signatures env value in
    type_of_expr signatures ((name, value_ty) :: env) body
  (* `Set.empty` takes no arguments, so it parses as a bare field access over the module
     name rather than a call.  Normalising it here lets the leaf tables resolve it. *)
  | EField _ when (match normalize_call_head expr with
                   | EVar { name; _ } ->
                     (set_leaf name <> None || dict_leaf name <> None)
                     && Hashtbl.mem signatures name
                   | _ -> false) ->
    (match normalize_call_head expr with
     | EVar { name; loc } ->
       (match set_leaf name, dict_leaf name with
        | Some leaf, _ -> type_of_set_leaf signatures env loc leaf [] None
        | _, Some leaf -> type_of_dict_leaf signatures env loc leaf []
        | None, None -> assert false)
     | _ -> assert false)
  | EField { obj; field; loc } ->
    (match type_of_expr signatures env obj, field with
     | TNewtype info, "value" -> info.base
     | TNewtype info, _ ->
       unsupported loc "Go backend newtype `%s` has no field `%s`" info.tesl_name field
     | TRecord info, _ -> record_field_type loc info field
     (* A field read on an UNTYPED JSON value stays untyped: `resp.body.user.id` is a chain
        of dynamic reads, and a missing key is null rather than an error — the same shape
        `api-test-field-access-ref` gives on Racket. *)
     | TJson, _ -> TJson
     | _ -> unsupported loc "Go backend does not support field `%s` yet" field)
  | ECase { scrut; arms; loc } ->
    let info, type_args = match type_of_expr signatures env scrut with
      | TAdt (info, args) -> info, args
      | _ -> unsupported loc "Go backend supports `case` over a module ADT only"
    in
    if arms = [] then unsupported loc "Go backend requires at least one `case` arm";
    let arm_envs = List.map (fun (arm : case_arm) ->
      let bindings = pattern_bindings loc info type_args arm.pattern in
      let arm_env = bindings @ env in
      (match arm.guard with
       | None -> ()
       | Some guard ->
         if type_of_expr signatures arm_env guard <> TBool then
           unsupported (Checker.expr_loc guard) "Go backend `case` guard must be Bool");
      arm_env, arm) arms in
    (* An arm can be UNDER-CONSTRAINED on its own while a sibling settles the case's
       type: `case … of Nothing -> Nothing | Something x -> Something (x + 1)` — a bare
       `Nothing` carries no type argument, but the other arm gives `Maybe Int`.  Such an
       arm is skipped here and later emitted against the resolved type, the same way an
       `if` branch is.  Nothing is lost by skipping: every arm is still emitted, so an arm
       that is genuinely unsupported raises there instead. *)
    let arm_results = List.map (fun (arm_env, (arm : case_arm)) ->
      typed_with_default (type_of_expr signatures arm_env) arm.body) arm_envs in
    (* A defaulted arm yields to a real one, for the same reason an `if` branch does. *)
    let has_real = List.exists (fun (result, defaulted) -> result <> None && not defaulted)
      arm_results in
    let arm_types = List.map (fun (result, defaulted) ->
      if has_real && defaulted then None else result) arm_results in
    (match List.filter_map (fun ty -> ty) arm_types with
     | [] ->
       (* No arm types on its own — report from the first, which raises the real reason. *)
       (match arm_envs with
        | (arm_env, arm) :: _ -> type_of_expr signatures arm_env arm.body
        | [] -> unsupported loc "Go backend requires at least one `case` arm")
     | types ->
       List.fold_left (fun acc ty ->
         match acc, ty with
         | TFailure, ty | ty, TFailure -> ty
         | left, right when left = right -> left
         | _ -> unsupported loc "Go backend `case` arms have different types")
         TFailure types)
  (* `let (v ::: pf) = y` DECOMPOSES a proof-carrying value: `v` is the value and `pf` the
     proof, which erases like every other proof (LANGUAGE-SPEC 16.9 gives a proof no runtime
     structure).  So the binding is the value itself and `pf` is the zero-size proof value —
     it exists because later code names it, e.g. `attachFact x pf`. *)
  | ELetProof { value_name; proof_name; value; body; _ } ->
    let value_ty = type_of_expr signatures env value in
    type_of_expr signatures
      ((proof_name, TUnit) :: (value_name, value_ty) :: env) body
  | ERecord { type_hint = Some name; fields; loc } ->
    (match record_info_of_signature signatures name with
     | Some info -> check_record_literal signatures env loc info fields; TRecord info
     | None -> unsupported loc "Go backend does not support record type `%s` yet" name)
  | ERecord { type_hint = None; loc; _ } ->
    unsupported loc "Go backend cannot infer the record type of this literal"
  (* An empty list literal whose element type NOTHING constrains.  Every path that can
     supply one runs first — an expectation from the call argument, the function's return
     type, a `let` tail, an `if` branch, a `case` arm, a sibling element, a fold's callback
     or accumulator, a leaf's own signature — so reaching here means the program genuinely
     never says what the list would hold: `expect List.reverse [] == []`, where both sides
     are empty.
     Such a program is legal Tesl and Racket runs it, so refusing to compile the module
     over it is a divergence with no upside (maintainer, 2026-08-13).  The element type is
     unobservable in exactly this situation — the list has no elements to read — and if the
     surrounding context did demand a specific type, Go's own type checker rejects the
     emitted code at build time rather than letting a wrong choice ship silently. *)
  | EList { elems = []; _ } -> used_empty_default := true; TList TInt
  | EList { elems; loc } ->
    (* An element may be under-constrained on its own — a nested `[]`, a bare `Nothing` —
       while its SIBLINGS settle the element type: `[[1, 2], [], [3]]`.  So the type comes
       from the first element that types, and the rest are checked AGAINST it through
       `type_of_arg`, which is the same expectation the emitter passes down per element.
       If no element types on its own, the first one is re-typed to report the real
       reason. *)
    let inferred = List.fold_left (fun found elem ->
      match found with
      | Some _ -> found
      | None ->
        (match typed_with_default (type_of_expr signatures env) elem with
         | Some ty, false -> Some ty
         | _ -> None))
      None elems in
    (* Nothing but defaulted elements: take the default rather than failing. *)
    let inferred = match inferred with
      | Some _ -> inferred
      | None -> fst (typed_with_default (type_of_expr signatures env) (List.hd elems))
    in
    let element = match inferred with
      | Some element -> element
      | None -> type_of_expr signatures env (List.hd elems)
    in
    List.iter (fun elem ->
      if type_of_arg signatures env element elem <> element then
        unsupported (Checker.expr_loc elem)
          "Go backend list literal elements have different types") elems;
    ignore loc;
    TList element
  | EOk { value; _ } -> TCheck (type_of_expr signatures env value)
  | EFail { message; loc; _ } ->
    if type_of_expr signatures env message <> TString then
      unsupported loc "Go backend check failure message must be String";
    TFailure
  (* `with database D { … }` names the store the body's queries run against.  With
     `backend: Memory` that store IS the entity's table variable, so the block adds
     nothing at run time and types as its body. *)
  | EWithDatabase { body; _ } -> type_of_expr signatures env body
  (* `enqueue` is a statement: the job id stays inside the store, as it does on Racket. *)
  | EEnqueue { payload; _ } -> ignore (type_of_expr signatures env payload); TUnit
  | ETelemetry { loc; _ } | EPublish { loc; _ }
  | EStartWorkers { loc; _ } | ECacheGet { loc; _ } | ECacheSet { loc; _ }
  | ECacheDelete { loc; _ } | ECacheInvalidate { loc; _ } | ESendEmail { loc; _ }
  | EStartEmailWorker { loc; _ }
  | EWithCapabilities { loc; _ } | EWithTransaction { loc; _ } | EServe { loc; _ } ->
    unsupported loc "Go backend does not support effects yet"
  (* A LAMBDA's type comes from its annotated parameters plus its inferred body.  Tesl
     requires the annotation, so nothing is guessed. *)
  | ELambda { params; body; loc } ->
    let types = match !current_types with
      | Some types -> types
      | None -> unsupported loc "Go backend cannot resolve a lambda's parameter types here"
    in
    let param_types = List.map (fun (binding : binding) ->
      type_of_type_expr types binding.type_expr) params in
    let lambda_env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) params param_types @ env in
    TFunc (param_types, type_of_expr signatures lambda_env body)

(* A nullary constructor of a generic ADT carries no argument to infer its type
   arguments from (`Empty` for `Labeled a`), so where a type is expected — a call
   argument — that expectation instantiates it.  Anywhere else it fails closed. *)
(* Types a list-leaf call from the element type of its list argument.  The same table
   drives emission, so arity and argument order cannot drift between the two. *)
and type_of_list_leaf signatures env loc leaf args =
  if List.length args <> leaf.leaf_arity then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)"
      leaf.leaf_name leaf.leaf_arity;
  (* Two kinds of leaf can accept an EMPTY list literal with nothing to infer from.
     `List.sum` has the element FIXED by its own signature (`List Int`).  `List.isEmpty`
     and `List.length` return a Bool/Int, so the element type is UNOBSERVABLE: the emitted
     call behaves identically whatever it is, and picking one cannot change a result.
     A leaf whose result mentions the element (`List.reverse []`) is NOT in this set — there
     the choice would be a guess, so it still fails closed. *)
  let fixed_element = match leaf.leaf_name, leaf.leaf_result with
    | ("List.sum" | "List.isEmpty" | "List.length"), _ -> Some TInt
    (* `concat []`/`flatten []` take a list OF LISTS, so the default has to be one. *)
    | _, `Inner -> Some (TList TInt)
    | _ -> None
  in
  let arg_types = List.mapi (fun index arg ->
    match arg, fixed_element with
    | EList { elems = []; _ }, Some element when index = leaf.leaf_list_index -> TList element
    | _ -> type_of_expr signatures env arg) args in
  let element = match List.nth arg_types leaf.leaf_list_index with
    | TList element -> element
    | _ -> unsupported loc "Go backend `%s` requires a List argument" leaf.leaf_name
  in
  (* The non-list argument is the element itself (member/contains) or a count. *)
  List.iteri (fun index arg_ty ->
    if index <> leaf.leaf_list_index then begin
      let want = match leaf.leaf_name with
        | "List.take" | "List.drop" -> TInt
        | "List.append" -> TList element
        | _ -> element
      in
      if arg_ty <> want then unsupported loc
        "Go backend `%s` argument %d has an unsupported type" leaf.leaf_name (index + 1)
    end) arg_types;
  if leaf.leaf_name = "List.sum" && element <> TInt then
    unsupported loc "Go backend `List.sum` requires a List Int";
  (match leaf.leaf_closure with
   | `Equal ->
     if not (supports_equality element) then unsupported loc
       "Go backend `%s` needs comparable elements" leaf.leaf_name
   | `Less ->
     if not (supports_ordering element) then unsupported loc
       "Go backend `%s` needs ordered elements" leaf.leaf_name
   | `None -> ());
  let maybe_of inner =
    match adt_ctor_of_signature signatures "Nothing" with
    | Some (info, _) -> TAdt (info, [inner])
    | None -> unsupported loc
      "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" leaf.leaf_name
  in
  (match leaf.leaf_result with
   | `Int -> TInt
   | `Bool -> TBool
   | `Same -> TList element
   | `MaybeElement -> maybe_of element
   | `MaybeSame -> maybe_of (TList element)
   | `Inner ->
     (match element with
      | TList inner -> TList inner
      | _ -> unsupported loc "Go backend `%s` requires a List of Lists" leaf.leaf_name))

(* A function ARGUMENT is either a lambda (whose parameter types come from the call
   site, so the declared annotations need no resolving here) or a named function. *)
and type_of_callable signatures env loc what callable param_types =
  match callable with
  | ELambda { params; body; _ } ->
    if List.length params <> List.length param_types then
      unsupported loc "Go backend `%s` needs a %d-parameter function" what
        (List.length param_types);
    let env = List.map2 (fun (binding : binding) ty -> binding.name, ty) params param_types @ env in
    type_of_expr signatures env body
  | EVar { name; _ } ->
    (match Hashtbl.find_opt signatures name with
     | Some signature ->
       if signature.params <> param_types then unsupported loc
         "Go backend `%s` function argument has unsupported parameter types" what;
       signature.result
     | None -> unsupported loc "Go backend cannot resolve function `%s`" name)
  | EApp _ ->
    (* A partial application supplied AT the call site — `List.filterCheck (checkFn
       arg) xs`.  The loop supplies the remaining arguments, so this needs no general
       function-value support: the emitted call is still fully applied. *)
    let head, supplied = flatten_app [] callable in
    let head = normalize_call_head head in
    (match head with
     | EVar { name; _ } ->
       (match Hashtbl.find_opt signatures name with
        | Some signature ->
          let count = List.length supplied in
          if count >= List.length signature.params then unsupported loc
            "Go backend `%s` function argument is already fully applied" what;
          let prefix = List.filteri (fun index _ -> index < count) signature.params in
          let rest = List.filteri (fun index _ -> index >= count) signature.params in
          List.iter2 (fun arg want ->
            if type_of_expr signatures env arg <> want then unsupported loc
              "Go backend `%s` partial application argument type mismatch" what)
            supplied prefix;
          if rest <> param_types then unsupported loc
            "Go backend `%s` function argument has unsupported parameter types" what;
          signature.result
        | None -> unsupported loc "Go backend cannot resolve function `%s`" name)
     | _ -> unsupported loc "Go backend `%s` takes a lambda or a named function" what)
  | _ ->
    unsupported loc "Go backend `%s` takes a lambda or a named function" what

and type_of_hof signatures env loc what hof args =
  if List.length args <> hof_arity hof then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)" what (hof_arity hof);
  (* A stdlib function passed as the callback — `List.sortBy String.length words` — parses
     as a field access over the module name, so it is normalised to the resolvable name
     before anything tries to treat it as a callable. *)
  let args = match args with
    | callable :: rest -> normalize_call_head callable :: rest
    | [] -> args
  in
  (* Where the CALLBACK declares the element type.  `foldl` takes (accumulator, element)
     and `foldr` takes (element, accumulator); every other leaf's callback takes the
     element first. *)
  let element_position = match hof with HofFoldl -> 1 | _ -> 0 in
  let element_from_callable () =
    match List.nth args 0 with
    | ELambda { params; _ } ->
      (match !current_types, List.nth_opt params element_position with
       | Some types, Some (binding : binding) ->
         (try Some (type_of_type_expr types binding.type_expr) with Unsupported _ -> None)
       | _ -> None)
    | EVar { name; _ } ->
      (match Hashtbl.find_opt signatures name with
       | Some signature -> List.nth_opt signature.params element_position
       | None -> None)
    | _ -> None
  in
  (* `List.map f []` and friends: an EMPTY list literal carries no element type, and the
     callback's declared parameter is what says what the list would have held. *)
  let list_of index =
    match List.nth args index with
    | EList { elems = []; _ } when element_from_callable () <> None ->
      (match element_from_callable () with Some element -> element | None -> assert false)
    | arg ->
      (match type_of_expr signatures env arg with
       | TList element -> element
       | _ -> unsupported loc "Go backend `%s` requires a List argument" what)
  in
  match hof with
  | HofMap ->
    let element = list_of 1 in
    TList (type_of_callable signatures env loc what (List.nth args 0) [element])
  | HofFilter | HofAny | HofAll ->
    let element = list_of 1 in
    if type_of_callable signatures env loc what (List.nth args 0) [element] <> TBool then
      unsupported loc "Go backend `%s` needs a Bool-returning function" what;
    (match hof with HofFilter -> TList element | _ -> TBool)
  | HofFind ->
    let element = list_of 1 in
    if type_of_callable signatures env loc what (List.nth args 0) [element] <> TBool then
      unsupported loc "Go backend `%s` needs a Bool-returning function" what;
    (match adt_ctor_of_signature signatures "Nothing" with
     | Some (info, _) -> TAdt (info, [element])
     | None -> unsupported loc
       "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" what)
  (* `filterMap`'s callback returns `Maybe b`, and the result is `List b`: the element is
     kept when the TAG is Something, never by the payload's truthiness — Racket's own
     implementation got that wrong and dropped `Something False`. *)
  | HofFilterMap ->
    let element = list_of 1 in
    (match type_of_callable signatures env loc what (List.nth args 0) [element] with
     | TAdt (info, [inner]) when info.adt_tesl_name = "Maybe" -> TList inner
     | _ -> unsupported loc "Go backend `%s` needs a Maybe-returning function" what)
  | HofConcatMap ->
    let element = list_of 1 in
    (match type_of_callable signatures env loc what (List.nth args 0) [element] with
     | TList inner -> TList inner
     | _ -> unsupported loc "Go backend `%s` needs a List-returning function" what)
  (* `sortBy` orders by a KEY function rather than a comparator, and the key is what has
     to be ordered.  The result keeps the element type (and mints `IsSorted`, which
     erases). *)
  | HofSortBy ->
    let element = list_of 1 in
    let key = type_of_callable signatures env loc what (List.nth args 0) [element] in
    if not (supports_ordering key) then unsupported loc
      "Go backend `%s` needs a key function returning an ordered type" what;
    TList element
  | HofZip ->
    let left = list_of 0 and right = list_of 1 in
    (match Hashtbl.find_opt signatures "Tuple2" with
     | Some { result = TAdt (info, _); _ } -> TList (TAdt (info, [left; right]))
     | _ -> unsupported loc
       "Go backend needs `Tesl.Tuple` imported for `%s`" what)
  | HofFilterCheck | HofAllCheck ->
    let element = list_of 1 in
    let result = type_of_callable signatures env loc what (List.nth args 0) [element] in
    if result <> TCheck element then unsupported loc
      "Go backend `%s` takes a `check` function over the element type" what;
    (match hof with
     | HofFilterCheck -> TList element
     | _ ->
       (match adt_ctor_of_signature signatures "Nothing" with
        | Some (info, _) -> TAdt (info, [TList element])
        | None -> unsupported loc
          "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" what))
  | HofFoldl | HofFoldr ->
    let element = list_of 2 in
    (* An EMPTY list literal as the initial accumulator carries no element type of its
       own, and it is the idiomatic init for a fold that rebuilds a list
       (`List.foldr prependInt [] ns`).  A NAMED callback settles it: the fold requires
       f's result to BE the accumulator, so the declared result type is the accumulator
       type.  A lambda's parameter annotations are not in scope here, so a lambda with a
       bare `[]` still fails closed rather than guessing. *)
    let declared_accumulator () =
      let resolve name = match Hashtbl.find_opt signatures name with
        | Some signature -> Some signature.result
        | None -> None
      in
      match List.nth args 0 with
      | EVar { name; _ } -> resolve name
      | EApp _ ->
        let head, _ = flatten_app [] (List.nth args 0) in
        (match normalize_call_head head with
         | EVar { name; _ } -> resolve name
         | _ -> None)
      | _ -> None
    in
    (* A lambda annotates its parameters, so the accumulator position says what the
       empty init cannot. *)
    let annotated_accumulator () =
      match List.nth args 0, !current_types with
      | ELambda { params; _ }, Some types ->
        let position = match hof with HofFoldr -> 1 | _ -> 0 in
        (match List.nth_opt params position with
         | Some (binding : binding) ->
           (try Some (type_of_type_expr types binding.type_expr) with Unsupported _ -> None)
         | None -> None)
      | _ -> None
    in
    let accumulator = match List.nth args 1 with
      | EList { elems = []; _ } ->
        (match declared_accumulator () with
         | Some ty -> ty
         | None ->
           (match annotated_accumulator () with
            | Some ty -> ty
            | None -> type_of_expr signatures env (List.nth args 1)))
      | _ -> type_of_expr signatures env (List.nth args 1)
    in
    (* `foldl`'s callback takes (accumulator, element); `foldr`'s takes them the other way
       round, per the stdlib signatures. *)
    let params = match hof with
      | HofFoldr -> [element; accumulator]
      | _ -> [accumulator; element]
    in
    let result = type_of_callable signatures env loc what (List.nth args 0) params in
    if result <> accumulator then unsupported loc
      "Go backend `%s` must return its accumulator type" what;
    accumulator

and constructor_head expr =
  match expr with
  | EConstructor { name; args; _ } -> Some (name, args)
  | EApp _ ->
    (match flatten_app [] expr with
     | EConstructor { name; args; _ }, rest -> Some (name, args @ rest)
     | _ -> None)
  | _ -> None

(* A set leaf's element type comes from its Set argument, from the element it is given
   (`Set.singleton`), from the list (`Set.fromList`), or — for `Set.empty`, which has
   neither — from the expectation, like `Nothing`. *)
and type_of_set_leaf signatures env loc leaf args expected =
  let args = normalize_call_args (List.init leaf.set_arity (fun _ -> TUnit)) args in
  if List.length args <> leaf.set_arity then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)"
      leaf.set_name leaf.set_arity;
  let element =
    if leaf.set_index >= 0 then
      match type_of_expr signatures env (List.nth args leaf.set_index) with
      | TSet element -> element
      | _ -> unsupported loc "Go backend `%s` requires a Set argument" leaf.set_name
    else match leaf.set_name, expected with
      | "Set.empty", Some (TSet element) -> element
      | "Set.empty", _ ->
        unsupported loc "Go backend cannot infer the element type of `Set.empty`"
      | "Set.singleton", _ -> type_of_expr signatures env (List.nth args 0)
      | "Set.fromList", _ ->
        (match type_of_expr signatures env (List.nth args 0) with
         | TList element -> element
         | _ -> unsupported loc "Go backend `%s` requires a List argument" leaf.set_name)
      | _ -> unsupported loc "Go backend cannot resolve `%s`" leaf.set_name
  in
  if leaf.set_needs_order && not (supports_ordering element) then
    unsupported loc "Go backend `%s` needs ordered elements" leaf.set_name;
  (* Check the non-Set arguments: an element for member/insert/remove, a Set for the
     algebra. *)
  List.iteri (fun index arg ->
    if index <> leaf.set_index then begin
      let want = match leaf.set_name with
        | "Set.union" | "Set.intersection" | "Set.difference" | "Set.isSubset" -> TSet element
        | "Set.fromList" -> TList element
        | _ -> element
      in
      if type_of_arg signatures env want arg <> want then unsupported loc
        "Go backend `%s` argument %d has an unsupported type" leaf.set_name (index + 1)
    end) args;
  (match leaf.set_result with
   | `Set -> TSet element
   | `Int -> TInt
   | `Bool -> TBool
   | `Elements -> TList element)

(* A dict leaf's types come from its Dict argument — except `Dict.empty`, which has no
   argument at all and so takes its type from the expectation, like `Nothing`. *)
and type_of_dict_leaf signatures env loc leaf args =
  let args = normalize_call_args (List.init leaf.dict_arity (fun _ -> TUnit)) args in
  if List.length args <> leaf.dict_arity then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)"
      leaf.dict_name leaf.dict_arity;
  let pair_of index =
    match type_of_expr signatures env (List.nth args index) with
    | TDict (key, value) -> key, value
    | _ -> unsupported loc "Go backend `%s` requires a Dict argument" leaf.dict_name
  in
  let maybe_of inner =
    match adt_ctor_of_signature signatures "Nothing" with
    | Some (info, _) -> TAdt (info, [inner])
    | None -> unsupported loc
      "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" leaf.dict_name
  in
  match leaf.dict_name with
  | "Dict.empty" ->
    unsupported loc "Go backend cannot infer the key and value types of `Dict.empty`"
  | "Dict.fromList" ->
    (match type_of_expr signatures env (List.nth args 0) with
     | TList (TAdt (info, [key; value])) when info.adt_tesl_name = "Tuple2" ->
       if not (supports_ordering key) then unsupported loc
         "Go backend `%s` needs ordered keys" leaf.dict_name;
       TDict (key, value)
     | _ -> unsupported loc
       "Go backend `%s` requires a List (Tuple2 k v) argument" leaf.dict_name)
  | _ ->
    (* The Dict is the LAST argument in every remaining leaf. *)
    let key, value = pair_of (leaf.dict_arity - 1) in
    if leaf.dict_needs_order && not (supports_ordering key) then
      unsupported loc "Go backend `%s` needs ordered keys" leaf.dict_name;
    (match leaf.dict_name with
     | "Dict.insert" ->
       if type_of_arg signatures env key (List.nth args 0) <> key then unsupported loc
         "Go backend `%s` key has an unsupported type" leaf.dict_name;
       if type_of_arg signatures env value (List.nth args 1) <> value then unsupported loc
         "Go backend `%s` value has an unsupported type" leaf.dict_name
     | "Dict.lookup" | "Dict.member" | "Dict.remove" ->
       if type_of_arg signatures env key (List.nth args 0) <> key then unsupported loc
         "Go backend `%s` key has an unsupported type" leaf.dict_name
     | _ -> ());
    (match leaf.dict_result with
     | `Dict -> TDict (key, value)
     | `MaybeValue -> maybe_of value
     | `Int -> TInt
     | `Bool -> TBool
     | `Keys -> TList key
     | `Values -> TList value
     | `Pairs ->
       (match Hashtbl.find_opt signatures "Tuple2" with
        | Some { result = TAdt (info, _); _ } -> TList (TAdt (info, [key; value]))
        | _ -> unsupported loc
          "Go backend `%s` returns tuples; import `Tesl.Tuple`" leaf.dict_name))

and type_of_arg signatures env want arg =
  match arg with
  (* A check may DELEGATE to another check in tail position: `check parseAge raw = … check
     checkAge parsed`.  The delegate's own `Check` IS this check's result — that is what
     Racket's `let/check`-based lowering does when the tail is the inner call — so the
     expectation is satisfied by the check's VALUE type. *)
  | _ when (match check_application signatures arg, want with
            | Some ({ result = TCheck inner; _ }, _), TCheck expected_inner ->
              inner = expected_inner
            | _ -> false) -> want
  (* `f <| value ::: pf` attaches a detached proof at the call site.  It parses as the same
     node as a check's `ok value ::: P`, and the two are told apart by what is EXPECTED: a
     check's tail wants a `Check`, an ordinary parameter wants the value.  The proof erases,
     so the argument is just the value. *)
  | EOk { value; _ } when (match want with TCheck _ -> false | _ -> true) ->
    type_of_arg signatures env want value
  (* An empty list literal has no element to infer from: the expectation supplies it. *)
  | EList { elems = []; _ } when (match want with TList _ -> true | _ -> false) -> want
  (* The expectation belongs to each BRANCH, and a branch is exactly where an
     under-constrained constructor sits. *)
  (* `Set.empty` and `Dict.empty` have no argument to infer an element type from, so the
     expectation supplies it — the same rule as an empty list literal and a nullary
     constructor.  Both are spelled as a bare name, since they take no arguments. *)
  | _ when (match normalize_call_head arg, want with
            | EVar { name = "Set.empty"; _ }, TSet _ -> true
            | EVar { name = "Dict.empty"; _ }, TDict _ -> true
            | _ -> false) -> want
  | EIf { cond; then_; else_; loc } ->
    if type_of_expr signatures env cond <> TBool then
      unsupported loc "Go backend if condition must be Bool";
    (match type_of_arg signatures env want then_, type_of_arg signatures env want else_ with
     | TFailure, ty | ty, TFailure -> ty
     | left, right when left = right -> left
     | _ -> unsupported loc "Go backend if branches have different types")
  (* A `let` chain passes the expectation THROUGH to its tail, the same way the tail
     emitter does.  Without this, one `let` before an `if` was enough to lose it, and an
     under-constrained tail (`[]`, `Nothing`, `Set.empty`) failed for no reason the author
     could see — the very shape a list-building function has. *)
  | ELet { name; value; body; _ } ->
    let inferred = type_of_expr signatures env value in
    let ty = if inferred = TFailure then want else inferred in
    type_of_arg signatures ((name, ty) :: env) want body
  (* The expectation belongs to each ARM for the same reason it belongs to each `if`
     branch. *)
  | ECase { scrut; arms; loc } ->
    let info, type_args = match type_of_expr signatures env scrut with
      | TAdt (info, args) -> info, args
      | _ -> unsupported loc "Go backend supports `case` over a module ADT only"
    in
    if arms = [] then unsupported loc "Go backend requires at least one `case` arm";
    List.fold_left (fun acc (arm : case_arm) ->
      let arm_env = pattern_bindings loc info type_args arm.pattern @ env in
      (match arm.guard with
       | None -> ()
       | Some guard ->
         if type_of_expr signatures arm_env guard <> TBool then
           unsupported (Checker.expr_loc guard) "Go backend `case` guard must be Bool");
      match acc, type_of_arg signatures arm_env want arm.body with
      | TFailure, ty | ty, TFailure -> ty
      | left, right when left = right -> left
      | _ -> unsupported loc "Go backend `case` arms have different types") TFailure arms
  | _ ->
    (* A constructor cannot always infer its ADT's type arguments from its own
       arguments — `Nothing` supplies none, and `Left e` never mentions the Right
       parameter — so where a type is expected, that expectation instantiates it. *)
    (match constructor_head arg, want with
     | Some (name, supplied), TAdt (info, (_ :: _ as type_args)) ->
       (match adt_ctor_of_signature signatures name with
        | Some (owner, variant) when owner.adt_tesl_name = info.adt_tesl_name ->
          let expected = variant_field_types info type_args variant in
          if List.length supplied <> List.length expected then
            unsupported (Checker.expr_loc arg)
              "Go backend requires constructor `%s.%s` applied to %d argument(s)"
              info.adt_tesl_name variant.var_ctor (List.length expected);
          List.iter2 (fun value (field, field_ty) ->
            if type_of_arg signatures env field_ty value <> field_ty then
              unsupported (Checker.expr_loc value)
                "Go backend constructor field `%s.%s` has an unsupported value type"
                variant.var_ctor field) supplied expected;
          want
        | _ -> type_of_expr signatures env arg)
     | _ -> type_of_expr signatures env arg)

(* A constructor application determines the ADT's type arguments: each parameter is
   read off the argument whose declared field type IS that parameter.  A parameter
   that appears in no field (or only nested inside another type) cannot be inferred
   here, and the application is rejected rather than guessed at. *)
and type_of_variant_application signatures env loc info variant args =
  if List.length args <> List.length variant.var_fields then
    unsupported loc "Go backend requires constructor `%s.%s` applied to %d argument(s)"
      info.adt_tesl_name variant.var_ctor (List.length variant.var_fields);
  let arg_types = List.map (type_of_expr signatures env) args in
  let type_args = List.map (fun (tesl_param, go_param) ->
    let rec find fields types =
      match fields, types with
      | (_, TParam candidate) :: _, arg_ty :: _ when candidate = go_param -> Some arg_ty
      | _ :: fields, _ :: types -> find fields types
      | _, _ -> None
    in
    match find variant.var_fields arg_types with
    | Some ty -> ty
    | None ->
      unsupported loc
        "Go backend cannot infer type argument `%s` of `%s` from constructor `%s`"
        tesl_param info.adt_tesl_name variant.var_ctor) info.adt_params in
  let expected = variant_field_types info type_args variant in
  List.iter2 (fun got (name, want) ->
    if got <> want then
      unsupported loc "Go backend constructor field `%s.%s` has an unsupported value type"
        variant.var_ctor name) arg_types expected;
  TAdt (info, type_args)

(* Returns the bindings a pattern introduces, rejecting every pattern shape the
   emitter cannot lower rather than binding it to the wrong payload field. *)
and pattern_bindings _loc info type_args pattern =
  match pattern with
  | PWild -> []
  | PVar name -> [name, TAdt (info, type_args)]
  | PLit { loc; _ } ->
    unsupported loc "Go backend does not support literal patterns over `%s` yet"
      info.adt_tesl_name
  | PNullary { ctor; loc } ->
    (match find_variant info ctor with
     | None ->
       unsupported loc "Go backend cannot resolve constructor `%s` of `%s`" ctor info.adt_tesl_name
     | Some variant ->
       if variant.var_fields <> [] then
         unsupported loc "Go backend requires constructor pattern `%s` to bind its %d field(s)"
           ctor (List.length variant.var_fields);
       [])
  | PCon { ctor; fields; loc } ->
    (match find_variant info ctor with
     | None ->
       unsupported loc "Go backend cannot resolve constructor `%s` of `%s`" ctor info.adt_tesl_name
     | Some variant ->
       if List.length fields <> List.length variant.var_fields then
         unsupported loc "Go backend requires constructor pattern `%s` to bind its %d field(s)"
           ctor (List.length variant.var_fields);
       (* Sub-patterns bind POSITIONALLY, matching the Racket backend: the pattern's
          own key is a binder name, not necessarily the declared field name. *)
       List.concat (List.mapi (fun index (_key, sub) ->
         let _, field_ty = List.nth (variant_field_types info type_args variant) index in
         match sub with
         | PWild -> []
         | PVar name -> [name, field_ty]
         | PNullary { loc; _ } | PCon { loc; _ } ->
           unsupported loc "Go backend does not support nested constructor patterns yet"
         | PLit { loc; _ } ->
           unsupported loc "Go backend does not support literal sub-patterns yet") fields))

and record_field_type loc info field =
  match List.assoc_opt field info.rec_fields with
  | Some ty -> ty
  | None ->
    unsupported loc "Go backend record `%s` has no field `%s`" info.rec_tesl_name field

and reject_duplicate_fields loc what fields =
  let rec loop = function
    | [] -> ()
    | (name, _) :: rest ->
      if List.mem_assoc name rest then
        unsupported loc "Go backend %s repeats field `%s`" what name;
      loop rest
  in
  loop fields

(* A record literal must mention every declared field exactly once: Go's zero
   value would otherwise silently stand in for a missing Tesl field. *)
and check_record_literal signatures env loc info fields =
  reject_duplicate_fields loc "record literal" fields;
  List.iter (fun (name, _) ->
    if not (List.mem_assoc name info.rec_fields) then
      unsupported loc "Go backend record `%s` has no field `%s`" info.rec_tesl_name name)
    fields;
  List.iter (fun (name, want) ->
    match List.assoc_opt name fields with
    | None ->
      unsupported loc "Go backend record literal for `%s` is missing field `%s`"
        info.rec_tesl_name name
    | Some value ->
      let got = type_of_arg signatures env want value in
      if got <> want then
        unsupported (Checker.expr_loc value)
          "Go backend record field `%s.%s` has an unsupported value type"
          info.rec_tesl_name name)
    info.rec_fields

and record_update_parts loc fields =
  match List.assoc_opt "__base__" fields with
  | None -> unsupported loc "Go backend cannot resolve the record being updated"
  | Some base ->
    let updates = List.filter (fun (name, _) -> name <> "__base__") fields in
    if updates = [] then unsupported loc "Go backend record update sets no field";
    base, updates

and type_of_record_update signatures env loc fields =
  let base, updates = record_update_parts loc fields in
  match type_of_expr signatures env base with
  | TRecord info ->
    reject_duplicate_fields loc "record update" updates;
    List.iter (fun (name, value) ->
      let want = record_field_type loc info name in
      let got = type_of_expr signatures env value in
      if got <> want then
        unsupported (Checker.expr_loc value)
          "Go backend record update `%s.%s` has an unsupported value type"
          info.rec_tesl_name name) updates;
    TRecord info
  | _ -> unsupported loc "Go backend record update requires a record value"

(* A `case` arm as the emitter needs it: the pattern, its optional guard, and a CLOSURE that
   emits the body.  A closure rather than the body itself because the body's type depends on
   the context — an expression for an ordinary `case`, a statement list inside a test block —
   and the discrimination logic is identical either way. *)
let arm_pattern (pattern, _, _) = pattern
let arm_guard (_, guard, _) = guard
let arm_body (_, _, body) = body

let rec emit_expr ?expected ?(indent="") signatures env expr =
  let emit = emit_expr ~indent signatures env in
  match expr with
  | ELit { lit = LInt value; _ } -> Printf.sprintf "teslrt.FromInt64(%d)" value
  | ELit { lit = LBigInt value; _ } ->
    Printf.sprintf "teslrt.MustParseDecimal(%s)" (go_quote value)
  | ELit { lit = LString value; _ } -> go_quote value
  | ELit { lit = LBool value; _ } -> if value then "true" else "false"
  | ELit { lit = LFloat value; _ } -> emit_float_literal value
  | ELit { lit = LInterp segments; _ } -> emit_interp ~indent signatures env segments
  | EVar { name; loc } ->
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some _, _ -> local_ident name
     (* A named function used as a VALUE is its own Go name; the type rule has already
        established that this is a function type and not a check. *)
     | None, Some signature when (match type_of_expr signatures env expr with
                                  | TFunc _ -> true | _ -> false) ->
       qualified signature.sig_owner signature.go_name
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> local_ident name)
  | EConstructor { name = "True"; args = []; _ } -> "true"
  | EConstructor { name = "False"; args = []; _ } -> "false"
  | EConstructor { name = "Unit"; args = []; _ } -> "struct{}{}"
  | EConstructor { name; args; _ } when adt_ctor_of_signature signatures name <> None ->
    let owner, variant = match adt_ctor_of_signature signatures name with
      | Some pair -> pair
      | None -> assert false
    in
    (* The expected type instantiates the ADT whenever it is available: a
       constructor's own arguments need not mention every type parameter. *)
    let result = match expected with
      | Some (TAdt (info, (_ :: _)) as want) when info.adt_tesl_name = owner.adt_tesl_name -> want
      | _ -> type_of_expr signatures env expr
    in
    emit_variant_literal ~indent signatures env result variant args
  | EConstructor { name; args; loc } ->
    (match Hashtbl.find_opt signatures name with
     | Some { params = [_]; result = (TNewtype _ as result); _ } ->
       ignore (type_of_expr signatures env expr);
       (match args with
        | [arg] ->
          let payload = emit arg in
          let payload = match result with
            | TNewtype info when info.secret ->
              Printf.sprintf "teslrt.MakeSecret(%s)" payload
            | _ -> payload
          in
          Printf.sprintf "%s{Value: %s}" (go_type result) payload
        | _ -> unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
     (* A proof term erases: `ValidPort port` is the zero-size proof value. *)
     | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> "struct{}{}"
     | _ -> unsupported loc "Go backend cannot emit constructor `%s`" name)
  | (EApp _ | EBinop _ | ELet _) as sql when recognise_sql sql <> None ->
    (match recognise_sql sql with
     | Some form -> emit_sql_form ~indent signatures env (Checker.expr_loc sql) form
     | None -> assert false)
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
    let head = normalize_call_head head in
    (match head with
     | EVar { name = "#record-update#"; _ } ->
       (match args with
        | [ERecord { fields; _ }] ->
          ignore (type_of_expr signatures env app);
          emit_record_update ~indent signatures env loc fields
        | _ -> unsupported loc "Go backend cannot emit this record update")
     | EConstructor { name; args = constructor_args; _ }
       when record_info_of_signature signatures name <> None ->
       let info = match record_info_of_signature signatures name with
         | Some info -> info
         | None -> assert false
       in
       (match constructor_args @ args with
        | [ERecord { fields; _ }] ->
          ignore (type_of_expr signatures env app);
          emit_record_literal ~indent signatures env info fields
        | _ -> unsupported loc "Go backend cannot emit record literal `%s`" name)
     | EConstructor { name; args = constructor_args; _ }
       when adt_ctor_of_signature signatures name <> None ->
       let owner, variant = match adt_ctor_of_signature signatures name with
         | Some pair -> pair
         | None -> assert false
       in
       let result = match expected with
         | Some (TAdt (info, (_ :: _)) as want)
           when info.adt_tesl_name = owner.adt_tesl_name -> want
         | _ -> type_of_expr signatures env app
       in
       emit_variant_literal ~indent signatures env result variant (constructor_args @ args)
     (* A COMBINED check: run each in turn, short-circuiting on the first rejection and
        feeding the checked value to the next — Racket's `check-and`, with the fact merge
        dropped because facts erase.  Hoisted into a helper so the call site stays one
        expression whatever the number of conjuncts. *)
      (* The existential package erases to its body. *)
      | EVar { name = "make-witness"; _ } ->
        (match args with
         | [EApp { arg = body; _ }] | [body] ->
           ignore (type_of_expr signatures env app);
           emit_expr ?expected ~indent signatures env body
         | _ -> unsupported loc "Go backend cannot emit this existential package")
     | EVar { name = "check"; _ }
       when (match args with
             | conjunction :: _ ->
               (match check_conjuncts conjunction with
                | Some (_ :: _ :: _) -> true
                | _ -> false)
             | [] -> false) ->
       let value_ty = type_of_expr signatures env app in
       let names = match args with
         | conjunction :: _ -> Option.value (check_conjuncts conjunction) ~default:[]
         | [] -> []
       in
       let go_of name = match Hashtbl.find_opt signatures name with
         | Some signature -> qualified signature.sig_owner signature.go_name
         | None -> unsupported loc "Go backend cannot resolve check `%s`" name
       in
       let checked = go_type value_ty in
       let body = Buffer.create 256 in
       List.iteri (fun index name ->
         let temporary = Printf.sprintf "teslStep%d" index in
         if index = 0 then
           Printf.bprintf body "\t%s := %s(teslValue)\n" temporary (go_of name)
         else
           Printf.bprintf body "\t%s := %s(teslrt.MustCheck(teslStep%d))\n"
             temporary (go_of name) (index - 1);
         if index < List.length names - 1 then
           Printf.bprintf body
             "\tif !%s.OK() {\n\t\treturn teslrt.Reject[%s](%s.Status(), %s.Message())\n\t}\n"
             temporary checked temporary temporary
         else
           Printf.bprintf body "\treturn %s\n" temporary) names;
       let helper = remember_helper_stmts ~prefix:"teslCheckAll"
         ~signature:(Printf.sprintf "(teslValue %s) teslrt.Check[%s]" checked checked)
         ~body:(Buffer.contents body) in
       let argument = match args with
         | [_; argument] -> argument
         | _ -> unsupported loc
           "Go backend requires a combined check applied to exactly one value"
       in
       Printf.sprintf "teslrt.%s(%s(%s))"
         (if !current_handler_body then "MustCheckRequest" else "MustCheck")
         helper (emit_expr ~expected:value_ty ~indent signatures env argument)
     | EVar { name = "check"; _ } ->
       (match List.map normalize_call_head args with
        | EVar { name; _ } :: call_args ->
          ignore (type_of_expr signatures env app);
           let signature = match Hashtbl.find_opt signatures name with
             | Some signature -> signature
             | None -> unsupported loc "Go backend cannot resolve check `%s`" name
           in
           Printf.sprintf "teslrt.%s(%s(%s))"
             (if !current_handler_body then "MustCheckRequest" else "MustCheck")
             (qualified signature.sig_owner signature.go_name)
              (String.concat ", " (List.map emit call_args))
         | _ -> unsupported loc "Go backend requires a named check function")
      | EVar { name = "not"; _ } when not (Hashtbl.mem signatures "not") ->
       ignore (type_of_expr signatures env app);
       (match args with
         | [arg] -> emit_negated ~indent signatures env arg
         | _ -> assert false)
      | EConstructor { name; args = constructor_args; _ } ->
        (match Hashtbl.find_opt signatures name with
         | Some { result = (TNewtype _ as result); _ } ->
           ignore (type_of_expr signatures env app);
           (match constructor_args @ args with
            | [arg] ->
              (* A secret's payload goes in through `MakeSecret`, so the plaintext is held by
                 the redacting carrier from the moment it is constructed. *)
              let payload = match result with
                | TNewtype info when info.secret ->
                  Printf.sprintf "teslrt.MakeSecret(%s)" (emit arg)
                | _ -> emit arg
              in
              Printf.sprintf "%s{Value: %s}" (go_type result) payload
            | _ -> assert false)
         (* A proof term erases: `ValidPort port` is the zero-size proof value. *)
         | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> "struct{}{}"
         | _ -> unsupported loc "Go backend cannot emit constructor `%s`" name)
      | EVar { name; _ } when set_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match set_leaf name with Some leaf -> leaf | None -> assert false in
       emit_set_leaf ~indent signatures env loc leaf args
         (type_of_expr signatures env app) expected
      | EVar { name; _ } when dict_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
       emit_dict_leaf ~indent signatures env loc leaf args
         (type_of_expr signatures env app) expected
      | EVar { name; _ } when tuple_accessor name <> None ->
       let field = match tuple_accessor name with
         | Some (_, field) -> field
         | None -> assert false
       in
       ignore (type_of_expr signatures env app);
       (match args with
        | [tuple] ->
          let variant = match type_of_expr signatures env tuple with
            | TAdt (info, _) ->
              (match single_variant info with
               | Some variant -> variant
               | None -> invalid_arg "tuple accessor validated before emission")
            | _ -> invalid_arg "tuple accessor validated before emission"
          in
          Printf.sprintf "%s.%s" (selector_operand (emit tuple))
            (variant_field_go_name variant field)
        | _ -> invalid_arg "tuple accessor validated before emission")
      | EVar { name = ("forgetFact" | "attachFact"); _ } when args <> [] ->
        (* The value passes through; the proof operand disappears with the proof. *)
        emit (List.hd args)
      | EVar { name = ("get" | "post" | "put" | "delete" | "patch") as verb; _ }
        when !current_api_server <> None ->
        let server = match !current_api_server with Some s -> s | None -> assert false in
        (* `post "/p" body { … } cookie c headers { … }` — the modifiers arrive as
           keyword/value pairs in the flat argument list, the same shape the Racket api-test
           emitter scans for. *)
        let path, request_body, cookie, request_headers = match args with
          | path :: rest ->
            let rec scan body cookie headers = function
              | EVar { name = "body"; _ } :: value :: more -> scan (Some value) cookie headers more
              | EVar { name = "cookie"; _ } :: value :: more -> scan body (Some value) headers more
              | EVar { name = "headers"; _ } :: value :: more -> scan body cookie (Some value) more
              | _ :: more -> scan body cookie headers more
              | [] -> body, cookie, headers
            in
            let body, cookie, headers = scan None None None rest in
            path, body, cookie, headers
          | [] -> unsupported loc "Go backend api-test request needs a path"
        in
        (* `cookie` is one `name=value` string — the wire form, since a REQUEST cookie carries
           none of the attributes a response cookie does — and `headers { … }` is a template
           whose values are Strings rather than JSON: they go on the wire as written. *)
        let cookies = match cookie with
          | None -> "nil"
          | Some value ->
            Printf.sprintf "[]string{%s}"
              (emit_expr ~expected:TString ~indent signatures env value)
        in
        let headers = match request_headers with
          | None -> "nil"
          | Some (ERecord { fields; _ }) ->
            Printf.sprintf "[]teslrt.Tuple2[string, string]{%s}"
              (String.concat ", " (List.map (fun (name, value) ->
                 let emitted =
                   if type_of_expr signatures env value = TString then
                     emit_expr ~expected:TString ~indent signatures env value
                   else unsupported (Checker.expr_loc value)
                     "Go backend api-test header `%s` must be a String" name
                 in
                 Printf.sprintf "{Tuple2First: %s, Tuple2Second: %s}" (go_quote name) emitted)
                 fields))
          | Some other -> unsupported (Checker.expr_loc other)
            "Go backend api-test `headers` must be a `{ \"name\": value }` template"
        in
        Printf.sprintf "teslrt.ApiRequest(%s, %S, %s, %s, %s, %s)" server
          (String.uppercase_ascii verb)
          (emit_expr ~expected:TString ~indent signatures env path)
          (match request_body with
           | None -> "\"\""
           | Some value -> emit_api_test_body ~indent signatures env value)
          cookies headers
      (* The api-test queue verbs.  The worker runs through a DISPATCHER closure: the store
         holds payloads as `any` because a queue may carry several job types, and the emitter
         is what knows which one this queue carries. *)
      | EVar { name = ("pendingJobCount" | "drainQueue" | "processNextJob"
                      | "processNextDeadJob" | "deadJobs") as verb; _ }
        when queue_argument args <> None ->
        let info = match queue_argument args with
          | Some name -> queue_of_job_type loc name
          | None -> assert false
        in
        ignore (type_of_expr signatures env app);
        let queue = qualified info.qu_owner info.qu_go_var in
        let row_go = match Option.bind !current_types
                             (fun types -> Hashtbl.find_opt types.records info.qu_job_type) with
          | Some row -> go_type (TRecord row)
          | None -> unsupported loc "Go backend cannot resolve job type `%s`" info.qu_job_type
        in
        let worker = match verb with
          | "processNextDeadJob" ->
            (match info.qu_dead_worker with
             | Some dead -> dead
             | None -> unsupported loc
               "Go backend: queue `%s` has no dead-letter worker" info.qu_tesl_name)
          | _ -> info.qu_worker
        in
        let worker_go = match Hashtbl.find_opt signatures worker with
          | Some signature -> qualified signature.sig_owner signature.go_name
          | None -> unsupported loc "Go backend cannot resolve worker `%s`" worker
        in
        (* The dispatcher is spliced as an ARGUMENT inside the wrapper closure, so its body
           sits one level deeper than the wrapper's statements. *)
        let inner = indent ^ "\t" in
        let dispatcher =
          Printf.sprintf
            "func(teslPayload any) teslrt.JobOutcome {\n%s\tteslJob = teslPayload.(%s)\n%s\t_ = %s(teslJob)\n%s\treturn teslrt.JobOutcome{OK: true}\n%s}"
            inner row_go inner worker_go inner inner
        in
        (match verb with
         | "pendingJobCount" -> Printf.sprintf "teslrt.PendingJobCount(%s)" queue
         (* `deadJobs` reads the store; no worker runs, so the dispatcher is unused here. *)
         | "deadJobs" -> Printf.sprintf "teslrt.DeadJobs(%s)" queue
         | "drainQueue" ->
           (* A drain is a statement; the count it reports is not surfaced in Tesl. *)
           Printf.sprintf
             "(func() struct{} {\n%s\tvar teslJob %s\n%s\t_ = teslJob\n%s\t_ = teslrt.DrainQueue(%s, %s, 1000)\n%s\treturn struct{}{}\n%s}())"
             indent row_go indent indent queue dispatcher indent indent
         | _ ->
           let runner = if verb = "processNextDeadJob" then "ProcessNextDeadJob"
                        else "ProcessNextJob" in
           (* The claimed job is captured so the result can carry it, which is what
              `expectJobOk` reads — and what `JobFailed job error` needs too. *)
           String.concat "" [
             Printf.sprintf "(func() teslrt.JobResult[%s] {\n" row_go;
             Printf.sprintf "%s\tvar teslJob %s\n" indent row_go;
             Printf.sprintf "%s\tteslOutcome := teslrt.%s(%s, %s)\n"
               indent runner queue dispatcher;
             Printf.sprintf "%s\tif !teslOutcome.Ran {\n" indent;
             Printf.sprintf "%s\t\tpanic(teslrt.EmptyQueue(%s, %s))\n"
               indent (go_quote info.qu_tesl_name) (go_quote verb);
             Printf.sprintf "%s\t}\n" indent;
             Printf.sprintf "%s\tif !teslOutcome.OK {\n" indent;
             Printf.sprintf "%s\t\treturn teslrt.JobFailed(teslJob, teslOutcome.Message)\n" indent;
             Printf.sprintf "%s\t}\n" indent;
             Printf.sprintf "%s\treturn teslrt.JobOk(teslJob)\n" indent;
             Printf.sprintf "%s}())" indent;
           ])
      (* The secret-accepting header builders.  They are the sanctioned sink for a `secret`,
         so the ARGUMENT is where the unwrapping happens: a secret newtype hands over its
         payload, and a plain String is wrapped on the way in — which is what
         `make-secret-header` accepts on Racket too.  The runtime then holds the plaintext
         behind an unguessable handle, so what the returned `Tuple2 String String` carries is
         not the secret itself. *)
      | EVar { name = ("HttpClient.bearer" | "HttpClient.secretHeader") as leaf; _ }
        when args <> [] ->
        ignore (type_of_expr signatures env app);
        let secret_argument value =
          let emitted = emit value in
          match type_of_expr signatures env value with
          | TNewtype info when info.secret ->
            Printf.sprintf "%s.Value" (selector_operand emitted)
          | TString -> Printf.sprintf "teslrt.MakeSecret(%s)" emitted
          | _ -> unsupported loc
            "Go backend `%s` takes a `secret` over String" leaf
        in
        (match leaf, args with
         | "HttpClient.bearer", [secret] ->
           Printf.sprintf "teslrt.HttpBearer(%s)" (secret_argument secret)
         | "HttpClient.secretHeader", [name; secret] ->
           Printf.sprintf "teslrt.HttpSecretHeader(%s, %s)"
             (emit_expr ~expected:TString ~indent signatures env name)
             (secret_argument secret)
         | _ -> unsupported loc "Go backend `%s` is applied to the wrong arity" leaf)
      | EVar { name = ("expectJobOk" | "expectJobFailed") as verb; _ } when args <> [] ->
        ignore (type_of_expr signatures env app);
        Printf.sprintf "teslrt.%s(%s)"
          (if verb = "expectJobOk" then "ExpectJobOk" else "ExpectJobFailed")
          (emit (List.hd args))
      (* The api-test JSON surface.  The runtime keeps Tesl's argument order, so the arguments
         go through unshuffled; `bodyField` is `fieldAt` on the response's body. *)
      | EVar { name = ("isNull" | "isNotNull" | "isEmpty" | "isNotEmpty" | "jsonLength"
                      | "jsonInt" | "jsonString" | "jsonBool" | "jsonArray" | "jsonObject"
                      | "hasField" | "hasLength" | "arrayAt" | "fieldAt" | "jsonContains"
                      | "bodyField") as verb; _ } ->
        ignore (type_of_expr signatures env app);
        let json_argument index =
          match List.nth_opt args index with
          | Some argument -> emit argument
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        let string_argument index =
          match List.nth_opt args index with
          | Some argument -> emit_expr ~expected:TString ~indent signatures env argument
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        let int_argument index =
          match List.nth_opt args index with
          | Some argument -> emit_expr ~expected:TInt ~indent signatures env argument
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        (match verb with
         | "isNull" -> Printf.sprintf "teslrt.JsonIsNull(%s)" (json_argument 0)
         | "isNotNull" -> Printf.sprintf "teslrt.JsonIsNotNull(%s)" (json_argument 0)
         | "isEmpty" -> Printf.sprintf "teslrt.JsonIsEmpty(%s)" (json_argument 0)
         | "isNotEmpty" -> Printf.sprintf "teslrt.JsonIsNotEmpty(%s)" (json_argument 0)
         | "jsonLength" -> Printf.sprintf "teslrt.JsonLength(%s)" (json_argument 0)
         | "jsonInt" -> Printf.sprintf "teslrt.JsonAsInt(%s)" (json_argument 0)
         | "jsonString" -> Printf.sprintf "teslrt.JsonAsString(%s)" (json_argument 0)
         | "jsonBool" -> Printf.sprintf "teslrt.JsonAsBool(%s)" (json_argument 0)
         (* `jsonArray`/`jsonObject` assert the shape and hand the value back; the assertion
            happens inside the length/field helpers that follow, so the value passes through. *)
         | "jsonArray" | "jsonObject" -> json_argument 0
         | "hasField" ->
           Printf.sprintf "teslrt.JsonHasField(%s, %s)" (string_argument 0) (json_argument 1)
         | "hasLength" ->
           Printf.sprintf "teslrt.JsonHasLength(%s, %s)" (int_argument 0) (json_argument 1)
         | "arrayAt" ->
           Printf.sprintf "teslrt.JsonArrayAt(%s, %s)" (int_argument 0) (json_argument 1)
         | "fieldAt" ->
           Printf.sprintf "teslrt.JsonFieldAt(%s, %s)" (string_argument 0) (json_argument 1)
         | "bodyField" ->
           Printf.sprintf "teslrt.JsonFieldAt(%s, %s.Body)"
             (string_argument 0) (selector_operand (json_argument 1))
         | _ ->
           (* jsonContains: the needle is an ordinary Tesl value, compared structurally. *)
           let needle = match List.nth_opt args 0 with
             | Some argument ->
               (match type_of_expr signatures env argument with
                | TJson -> emit argument
                | TString | TInt | TBool | TFloat -> emit argument
                | _ -> unsupported loc
                  "Go backend `jsonContains` takes a scalar or an api-test value as its needle")
             | None -> unsupported loc "Go backend requires `jsonContains` applied to 2 arguments"
           in
           Printf.sprintf "teslrt.JsonContains(%s, %s)" needle (json_argument 1))
      | EVar { name = ("statusOk" | "statusClientError" | "statusServerError") as predicate; _ } ->
        let go_name = match predicate with
          | "statusOk" -> "StatusOk"
          | "statusClientError" -> "StatusClientError"
          | _ -> "StatusServerError"
        in
        Printf.sprintf "teslrt.%s(%s)" go_name
          (String.concat ", " (List.map (fun arg ->
             emit_expr ~expected:TInt ~indent signatures env arg) args))
      (* The cookie writer targets the response the scope owns. *)
      | EVar { name = "Http.clearSessionCookie"; _ } ->
        "teslrt.ClearSessionCookie(teslScope)"
      | EVar { name = ("detachFact" | "introAnd" | "andLeft" | "andRight"); _ } ->
        List.iter (fun arg -> ignore (type_of_expr signatures env arg)) args;
        "struct{}{}"
      | EVar { name; _ } when higher_order_leaf name <> None && Hashtbl.mem signatures name ->
       let hof = match higher_order_leaf name with Some hof -> hof | None -> assert false in
       emit_hof ~indent signatures env loc name hof args
         (type_of_expr signatures env app)
      | EVar { name = ("List.range" | "List.repeat") as name; _ }
        when Hashtbl.mem signatures name ->
        ignore (type_of_expr signatures env app);
        let go = if name = "List.range" then "teslrt.ListRange" else "teslrt.ListRepeat" in
        Printf.sprintf "%s(%s)" go (String.concat ", " (List.map emit args))
      | EVar { name; _ } when list_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match list_leaf name with Some leaf -> leaf | None -> assert false in
       ignore (type_of_expr signatures env app);
       let element = match List.nth args leaf.leaf_list_index with
         | EList { elems = []; _ } when leaf.leaf_result = `Inner -> TList TInt
         | EList { elems = []; _ }
           when List.mem leaf.leaf_name ["List.sum"; "List.isEmpty"; "List.length"] -> TInt
         | arg ->
           (match type_of_expr signatures env arg with
            | TList element -> element
            | _ -> invalid_arg "list leaf validated before emission")
       in
       let emitted = List.mapi (fun index arg ->
         match arg with
         | EList { elems = []; _ } when index = leaf.leaf_list_index ->
           emit_expr ~expected:(TList element) ~indent signatures env arg
         | _ -> emit arg) args in
       let emitted = match leaf.leaf_closure with
         | `None -> emitted
         | `Equal -> emitted @ [element_equal_func element]
         | `Less -> emitted @ [element_less_func element]
       in
       Printf.sprintf "%s(%s)" leaf.leaf_go (String.concat ", " emitted)
      (* A call through a function VALUE is an ordinary Go call on the binding. *)
      | EVar { name; _ } when (match List.assoc_opt name env with
                               | Some (TFunc _) -> true | _ -> false) ->
        let params = match List.assoc_opt name env with
          | Some (TFunc (params, _)) -> params
          | _ -> assert false
        in
        ignore (type_of_expr signatures env app);
        Printf.sprintf "%s(%s)" (local_ident name)
          (String.concat ", " (List.map2 (fun arg want ->
             emit_expr ~expected:want ~indent signatures env arg) args params))
      | EVar { name; _ } ->
       let signature = match Hashtbl.find_opt signatures name with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" name
       in
       let args = normalize_call_args signature.params args in
       ignore (type_of_expr signatures env app);
       (* A callee that may write to the response takes the request scope FIRST.  The
          caller always has one to pass: the checker requires it to declare `cookieCap`
          too, which is what gave the caller its own scope parameter. *)
       let scope_argument = if signature.sig_needs_scope then [ "teslScope" ] else [] in
       Printf.sprintf "%s(%s)" (qualified signature.sig_owner signature.go_name)
          (String.concat ", " (scope_argument @ List.map2 (fun arg want ->
             emit_expr ~expected:want ~indent signatures env arg) args signature.params))
      (* The same call, emitted: the head is an expression of func type. *)
      | head when (match type_of_expr signatures env head with TFunc _ -> true | _ -> false) ->
        let params = match type_of_expr signatures env head with
          | TFunc (params, _) -> params
          | _ -> assert false
        in
        ignore (type_of_expr signatures env app);
        Printf.sprintf "%s(%s)" (selector_operand (emit head))
          (String.concat ", " (List.map2 (fun arg want ->
             emit_expr ~expected:want ~indent signatures env arg) args params))
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  (* One side is an UNTYPED api-test value: compare structurally through the runtime, with the
     typed side ENCODED the same way a response body is, so the two directions cannot disagree
     about what a value looks like as JSON. *)
  | EBinop { op = (BEq | BNeq) as op; left; right; loc; _ }
    when (let json side = type_of_expr signatures env side = TJson in
          json left <> json right) ->
    let json_side, typed_side =
      if type_of_expr signatures env left = TJson then left, right else right, left in
    let typed_ty = type_of_expr signatures env typed_side in
    (* The typed side is handed over in the shape the runtime compares against: a scalar as
       itself, a newtype unwrapped, a list lifted.  Anything richer (a record, a dict) fails
       closed rather than being compared as something it is not — an api-test compares FIELDS,
       and that is the shape the corpus uses. *)
    let rec comparand ty emitted = match ty with
      | TInt | TString | TBool | TFloat -> emitted
      | TNewtype info when not info.secret ->
        comparand info.base (Printf.sprintf "%s.Value" (selector_operand emitted))
      | TList (TInt | TString | TBool | TFloat) ->
        Printf.sprintf "teslrt.JsonListOf(%s)" emitted
      | _ -> unsupported loc
        "Go backend compares an api-test JSON value against a scalar, a newtype over one, or \
         a list of those"
    in
    let encoded =
      if typed_ty = TJson then emit_expr ~indent signatures env typed_side
      else comparand typed_ty
        (emit_expr ~expected:typed_ty ~indent signatures env typed_side)
    in
    Printf.sprintf "%steslrt.JsonEqual(%s, %s)"
      (if op = BNeq then "!" else "")
      (emit_expr ~indent signatures env json_side) encoded
  | EBinop { op; left; right; _ } ->
    let expr_binop_operand_source =
      match left, right with
      | EList { elems = []; _ }, _ -> right
      | _ -> left
    in
    (* The operand type is the one the TYPE rule settled on, which may come from the other
       side when this one is a defaulted empty list — so both operands are emitted against
       it rather than against whatever each infers alone. *)
    let ty = type_of_expr signatures env expr_binop_operand_source in
    let emitted_left = emit_expr ~expected:ty ~indent signatures env left in
    let emitted_right = emit_expr ~expected:ty ~indent signatures env right in
    let emit_bool_literal_comparison equal =
      match bool_literal_value left, bool_literal_value right with
      | Some expected, None ->
        if expected = equal then emitted_right
        else emit_negated ~indent signatures env right
      | None, Some expected ->
        if expected = equal then emitted_left
        else emit_negated ~indent signatures env left
      | _ ->
        if equal then equal_expr ty emitted_left emitted_right
        else unequal_expr ty emitted_left emitted_right
    in
    (match op with
     | BEq when ty = TBool -> emit_bool_literal_comparison true
     | BNeq when ty = TBool -> emit_bool_literal_comparison false
     | BAdd when ty = TFloat -> Printf.sprintf "(%s + %s)" emitted_left emitted_right
     | BSub when ty = TFloat -> Printf.sprintf "(%s - %s)" emitted_left emitted_right
     | BMul when ty = TFloat -> Printf.sprintf "(%s * %s)" emitted_left emitted_right
     (* No zero guard: IEEE division by zero yields ±Inf, which is what Racket's `/` on
        a flonum does too. *)
     | BDiv when ty = TFloat -> Printf.sprintf "(%s / %s)" emitted_left emitted_right
     | BAdd -> Printf.sprintf "teslrt.Add(%s, %s)" emitted_left emitted_right
     | BSub -> Printf.sprintf "teslrt.Sub(%s, %s)" emitted_left emitted_right
     | BMul -> Printf.sprintf "teslrt.Mul(%s, %s)" emitted_left emitted_right
     | BDiv -> Printf.sprintf "teslrt.MustQuo(%s, %s)" emitted_left emitted_right
     | BMod -> Printf.sprintf "teslrt.MustRem(%s, %s)" emitted_left emitted_right
     | BConcat -> Printf.sprintf "(%s + %s)" emitted_left emitted_right
     | BAnd -> Printf.sprintf "(%s && %s)" emitted_left emitted_right
     | BOr -> Printf.sprintf "(%s || %s)" emitted_left emitted_right
     | BEq | BNeq | BLt | BLe | BGt | BGe ->
       let compare left right = match op with
         | BEq -> equal_expr ty left right
         | BNeq -> unequal_expr ty left right
         | _ ->
           let symbol = match op with
             | BLt -> "<" | BLe -> "<=" | BGt -> ">" | _ -> ">=" in
           ordered_expr ty symbol left right
       in
       (* Two operands that EMIT THE SAME TEXT are a staticcheck finding (SA4000,
          "identical expressions on both sides"), and a lint finding on emitted code is an
          emitter bug by contract.  It is reachable from ordinary Tesl: comparing two calls
          of one effectful function — `generateId () != generateId ()` — is textually
          identical and semantically nothing of the kind.  Each side is bound first, which
          also fixes the evaluation ORDER at exactly what the source says. *)
       if emitted_left = emitted_right && String.contains emitted_left '(' then
         Printf.sprintf
           "(func() bool {\n%s\tteslLeft := %s\n%s\tteslRight := %s\n%s\treturn %s\n%s}())"
           indent emitted_left indent emitted_right indent
           (compare "teslLeft" "teslRight") indent
       else compare emitted_left emitted_right)
  (* Negating a LITERAL folds into the literal rather than emitting `-float64(0)`, which
     in Go is POSITIVE zero — the negation is applied to the already-typed value, so it
     cannot produce a negative zero (staticcheck SA4026 says exactly this).  Racket's
     `-0.0` is a real negative zero, and Tesl's Float equality distinguishes the two, so
     this was a wrong answer and not only a lint finding. *)
  | EUnop { op = UNeg; arg = ELit { lit = LFloat value; _ }; _ } ->
    emit_float_literal (-.value)
  | EUnop { op = UNeg; arg; _ } when type_of_expr signatures env arg = TFloat ->
    Printf.sprintf "(-%s)" (emit arg)
  | EUnop { op = UNeg; arg; _ } -> Printf.sprintf "teslrt.Neg(%s)" (emit arg)
  | EUnop { op = UNot; arg; _ } -> emit_negated ~indent signatures env arg
  | EIf _ as if_expr -> emit_if_expr ?expected ~indent signatures env if_expr
  | ELet _ as let_expr -> emit_let_expr ?expected ~indent signatures env let_expr
  | EField _ when (match normalize_call_head expr with
                   | EVar { name; _ } ->
                     (set_leaf name <> None || dict_leaf name <> None)
                     && Hashtbl.mem signatures name
                   | _ -> false) ->
    (match normalize_call_head expr with
     | EVar { name; loc } ->
       (match set_leaf name, dict_leaf name with
        | Some leaf, _ ->
          emit_set_leaf ~indent signatures env loc leaf []
            (match expected with Some want -> want | None -> TFailure) expected
        | _, Some leaf ->
          emit_dict_leaf ~indent signatures env loc leaf []
            (match expected with Some want -> want | None -> TFailure) expected
        | None, None -> assert false)
     | _ -> assert false)
  | EField { obj; field; _ } ->
    (match type_of_expr signatures env obj with
     | TNewtype _ ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "%s.Value" (selector_operand (emit obj))
     | TRecord _ ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "%s.%s" (selector_operand (emit obj)) (record_field_go_name field)
     (* A dynamic read on an api-test JSON value: a missing key is null, which is what makes
        `expect isNull resp.body.missing` writable. *)
     | TJson ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "teslrt.JsonFieldOf(%s, %s)" (emit obj) (go_quote field)
     | _ -> unsupported (Checker.expr_loc expr) "Go backend cannot emit this field read")
  | ERecord { type_hint = Some name; fields; loc } ->
    (match record_info_of_signature signatures name with
     | Some info ->
       ignore (type_of_expr signatures env expr);
       emit_record_literal ~indent signatures env info fields
     | None -> unsupported loc "Go backend cannot emit record type `%s`" name)
  | ECase { scrut; arms; _ } ->
    let inferred = type_of_expr signatures env expr in
    let result = match inferred, expected with
      | TFailure, Some expected -> expected
      | _ -> inferred
    in
    let buffer = Buffer.create 256 in
    emit_case_statements ~indent:(indent ^ "\t") signatures env buffer scrut
      (List.map (fun (arm : case_arm) ->
         arm.pattern, arm.guard,
         (fun arm_env body_indent ->
            Printf.bprintf buffer "%sreturn %s\n" body_indent
              (emit_expr ~expected:result ~indent:body_indent signatures arm_env arm.body)))
         arms);
    Printf.sprintf "(func() %s {\n%s%s}())" (go_type result) (Buffer.contents buffer) indent
  | EList { elems; _ } ->
    let element = match expected, elems with
      | Some (TList element), [] -> element
      | _ ->
        (match type_of_expr signatures env expr with
         | TList element -> element
         | _ -> invalid_arg "list literal validated before emission")
    in
    Printf.sprintf "[]%s{%s}" (go_type element)
      (String.concat ", " (List.map (fun elem ->
         emit_expr ~expected:element ~indent signatures env elem) elems))
  | ELetProof _ as let_proof -> emit_let_expr ?expected ~indent signatures env let_proof
  | ERecord { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"
  | EOk { value; _ } when (match expected with Some (TCheck _) | None -> false | Some _ -> true) ->
    (* Proof attachment at a call site: the proof has no runtime content. *)
    emit_expr ?expected ~indent signatures env value
  | EOk { value; _ } -> Printf.sprintf "teslrt.Accept(%s)" (emit value)
  | EFail { status; message; loc } ->
    (match expected with
     | Some (TCheck result) ->
       Printf.sprintf "teslrt.Reject[%s](%d, %s)" (go_type result) status
          (emit message)
     | _ -> unsupported loc "Go backend can emit fail only in a check tail")
  | EWithDatabase { body; _ } -> emit_expr ?expected ~indent signatures env body
  | EEnqueue { job_type; payload; loc } ->
    let info = queue_of_job_type loc job_type in
    let row = match Option.bind !current_types
                      (fun types -> Hashtbl.find_opt types.records info.qu_job_type) with
      | Some row -> TRecord row
      | None -> unsupported loc "Go backend cannot resolve job type `%s`" job_type
    in
    Printf.sprintf "teslrt.EnqueueJob(%s, %s)"
      (qualified info.qu_owner info.qu_go_var)
      (emit_expr ~expected:row ~indent signatures env payload)
  | ETelemetry { loc; _ } | EPublish { loc; _ }
  | EStartWorkers { loc; _ } | ECacheGet { loc; _ } | ECacheSet { loc; _ }
  | ECacheDelete { loc; _ } | ECacheInvalidate { loc; _ } | ESendEmail { loc; _ }
  | EStartEmailWorker { loc; _ }
  | EWithCapabilities { loc; _ } | EWithTransaction { loc; _ } | EServe { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"
  (* A LAMBDA is a Go function literal.  The body goes through the ordinary TAIL emitter, so
     a `let` chain or an `if` inside it keeps statement form instead of nesting closures. *)
  | ELambda { params; body; loc } ->
    let param_types = match type_of_expr signatures env expr with
      | TFunc (param_types, _) -> param_types
      | _ -> unsupported loc "Go backend cannot resolve this lambda's type"
    in
    let result = match type_of_expr signatures env expr with
      | TFunc (_, result) -> result
      | _ -> assert false
    in
    let lambda_env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) params param_types @ env in
    (* The body is emitted as an EXPRESSION, so a `let` chain inside it becomes the same
       immediately-called closure any other nested `let` does — one shape for both. *)
    let emitted_body =
      emit_expr ~expected:result ~indent:(indent ^ "\t") signatures lambda_env body in
    Printf.sprintf "func(%s) %s {\n%s\treturn %s\n%s}"
      (String.concat ", " (List.map2 (fun (binding : binding) ty ->
         Printf.sprintf "%s %s" (local_ident binding.name) (go_type ty)) params param_types))
      (go_type result) indent emitted_body indent

(* What one arm has to test and bind, resolved once so the type rule and the
   emitter cannot disagree about which payload field a binder refers to. *)
and pattern_plan info type_args pattern =
  match pattern with
  | PWild -> None, None, []
  | PVar name -> None, Some name, []
  | PNullary { ctor; _ } -> find_variant info ctor, None, []
  | PCon { ctor; fields; _ } ->
    let variant = match find_variant info ctor with
      | Some variant -> variant
      | None -> invalid_arg "case pattern validated before emission"
    in
    let bindings = List.concat (List.mapi (fun index (_key, sub) ->
      let field_name, field_ty =
        List.nth (variant_field_types info type_args variant) index in
      match sub with
      | PVar name -> [name, variant_field_go_name variant field_name, field_ty]
      | _ -> []) fields) in
    Some variant, None, bindings
  | PLit _ -> invalid_arg "case pattern validated before emission"

(* `case` lowers to statements, not an expression: a tag switch when no arm has a
   guard (so the emitted switch stays checkable), an ordered if-chain when a guard
   can make an arm fall through to the next one. *)
(* Arms arrive as (pattern, guard, body) TRIPLES rather than as `case_arm`s: an expression
   `case` carries an expr body while a test-block `case` carries a statement list, and the
   discrimination logic is the same for both. *)
and emit_case_statements ?(indent="") signatures env buffer scrut arms =
  let info, type_args = match type_of_expr signatures env scrut with
    | TAdt (info, args) -> info, args
    | _ -> invalid_arg "case scrutinee validated before emission"
  in
  let scrut_ty = TAdt (info, type_args) in
  let scrut_name = Printf.sprintf "teslScrut%d" (String.length indent) in
  let inner = indent ^ "\t" in
  Printf.bprintf buffer "%s{\n" indent;
  Printf.bprintf buffer "%s%s := %s\n" inner scrut_name
    (emit_expr ~expected:scrut_ty ~indent:inner signatures env scrut);
  let plans =
    List.map (fun ((pattern, guard, body) as arm) ->
      ignore guard; ignore body;
      arm, pattern_plan info type_args pattern) arms in
  let guarded = List.exists (fun (_, guard, _) -> guard <> None) arms in
  (* A single-variant ADT (a tuple) has nothing to discriminate: the first arm always
     matches, so binding its payload IS the match.  A switch would need a tag the type
     does not carry. *)
  let single = single_variant info <> None && not guarded in
  let bind_arm body_indent (whole, bindings) =
    let env = ref env in
    (match whole with
     | None -> ()
     | Some name ->
       Printf.bprintf buffer "%s%s := %s\n%s_ = %s\n" body_indent (local_ident name)
         scrut_name body_indent (local_ident name);
       env := (name, scrut_ty) :: !env);
    List.iter (fun (name, go_field, field_ty) ->
      Printf.bprintf buffer "%s%s := %s.%s\n%s_ = %s\n" body_indent (local_ident name)
        scrut_name go_field body_indent (local_ident name);
      env := (name, field_ty) :: !env) bindings;
    !env
  in
  let unreachable_default body_indent =
    Printf.bprintf buffer "%spanic(\"unreachable: checker guarantees case exhaustiveness\")\n"
      body_indent
  in
  if single then begin
    match plans with
    | (arm, (_, whole, bindings)) :: _ ->
      let arm_env = bind_arm inner (whole, bindings) in
      (arm_body arm) arm_env inner
    | [] -> invalid_arg "case validated before emission"
  end else if guarded then begin
    (* First match wins, so an unguarded catch-all ends the chain: anything after
       it is dead code, which `go vet` rejects. *)
    let rec chain = function
      | [] -> unreachable_default inner
      | (arm, (variant, whole, bindings)) :: rest ->
        let body_indent = inner ^ "\t" in
        (match variant with
         | Some variant ->
           Printf.bprintf buffer "%sif %s.%s == %s {\n" inner scrut_name adt_tag_field
             (qualified info.adt_owner variant.var_tag)
         | None -> Printf.bprintf buffer "%s{\n" inner);
        let arm_env = bind_arm body_indent (whole, bindings) in
        (match arm_guard arm with
         | None -> (arm_body arm) arm_env body_indent
         | Some guard ->
           Printf.bprintf buffer "%sif %s {\n" body_indent
             (strip_outer_parens (emit_expr ~indent:body_indent signatures arm_env guard));
           (arm_body arm) arm_env (body_indent ^ "\t");
           Printf.bprintf buffer "%s}\n" body_indent);
        Printf.bprintf buffer "%s}\n" inner;
        if variant = None && arm_guard arm = None then () else chain rest
    in
    chain plans
  end else begin
    (* Every tag is named explicitly — a Tesl catch-all becomes the list of tags no
       earlier arm covered — so the `exhaustive` linter can still verify the switch
       (`default:` alone would blind it under default-signifies-exhaustive: false). *)
    let all_tags =
      List.map (fun variant -> qualified info.adt_owner variant.var_tag) info.adt_variants in
    Printf.bprintf buffer "%sswitch %s.%s {\n" inner scrut_name adt_tag_field;
    let containment_default () =
      Printf.bprintf buffer "%sdefault:\n" inner;
      unreachable_default (inner ^ "\t")
    in
    let rec cases seen = function
      | [] -> containment_default ()
      | (arm, (variant, whole, bindings)) :: rest ->
        (match variant with
         | Some variant ->
           let tag = qualified info.adt_owner variant.var_tag in
           if List.mem tag seen then cases seen rest
           else begin
             Printf.bprintf buffer "%scase %s:\n" inner tag;
             let arm_env = bind_arm (inner ^ "\t") (whole, bindings) in
             (arm_body arm) arm_env (inner ^ "\t");
             cases (tag :: seen) rest
           end
         | None ->
           let uncovered = List.filter (fun tag -> not (List.mem tag seen)) all_tags in
           if uncovered = [] then containment_default ()
           else begin
             Printf.bprintf buffer "%scase %s:\n" inner (String.concat ", " uncovered);
             let arm_env = bind_arm (inner ^ "\t") (whole, bindings) in
             (arm_body arm) arm_env (inner ^ "\t");
             containment_default ()
           end)
    in
    cases [] plans;
    Printf.bprintf buffer "%s}\n" inner
  end;
  Printf.bprintf buffer "%s}\n" indent

(* Negation is pushed into the expression instead of wrapping the emitted string:
   `!(a && b)` and `!(a == b)` are golangci-lint findings on generated code, and a
   lint finding on emitted code is an emitter bug by contract. *)
and emit_negated ?(indent="") signatures env expr =
  let neg = emit_negated ~indent signatures env in
  let emit = emit_expr ~indent signatures env in
  let group value = if paren_wraps_whole value 0 then value else "(" ^ value ^ ")" in
  if type_of_expr signatures env expr <> TBool then
    unsupported (Checker.expr_loc expr) "Go backend can negate Bool expressions only";
  match expr with
  | ELit { lit = LBool value; _ } -> if value then "false" else "true"
  | EConstructor { name = "True"; args = []; _ } -> "false"
  | EConstructor { name = "False"; args = []; _ } -> "true"
  | EUnop { op = UNot; arg; _ } -> group (emit arg)
  | EBinop { op = BAnd; left; right; _ } ->
    Printf.sprintf "(%s || %s)" (group (neg left)) (group (neg right))
  | EBinop { op = BOr; left; right; _ } ->
    Printf.sprintf "(%s && %s)" (group (neg left)) (group (neg right))
  | EBinop { op = (BEq | BNeq) as op; left; right; _ } ->
    let ty = type_of_expr signatures env left in
    let emitted_left = emit left and emitted_right = emit right in
    let equal = (op = BEq) in
    (match bool_literal_value left, bool_literal_value right with
     | Some expected, None when ty = TBool ->
       if expected = equal then neg right else group emitted_right
     | None, Some expected when ty = TBool ->
       if expected = equal then neg left else group emitted_left
     | _ ->
       if equal then unequal_expr ty emitted_left emitted_right
       else equal_expr ty emitted_left emitted_right)
  | EBinop { op = (BLt | BLe | BGt | BGe) as op; left; right; _ } ->
    let ty = type_of_expr signatures env left in
    let flipped = match op with
      | BLt -> ">=" | BLe -> ">" | BGt -> "<=" | BGe -> "<" | _ -> assert false in
    ordered_expr ty flipped (emit left) (emit right)
  | _ -> negate_bool (emit expr)

(* A generic ADT's composite literal must name its type arguments: Go infers type
   parameters for calls, never for a composite literal. *)
(* Applies a function argument to already-bound Go variables.  A lambda's body is
   emitted with its parameters bound to those variable NAMES, so the loop variable is
   named after the lambda parameter and the body needs no rewriting — and if the name
   shadows an outer binding, the Go shadowing matches the Tesl scoping exactly. *)
and emit_applied ?(indent="") signatures env callable params bound =
  match callable with
  | ELambda { params = lambda_params; body; _ } ->
    let env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) lambda_params params @ env in
    emit_expr ~indent signatures env body
  | EVar { name; _ } ->
    let go_name = match Hashtbl.find_opt signatures name with
      | Some signature -> qualified signature.sig_owner signature.go_name
      | None -> invalid_arg "function argument validated before emission"
    in
    Printf.sprintf "%s(%s)" go_name (String.concat ", " bound)
  | EApp _ ->
    let head, supplied = flatten_app [] callable in
    let go_name = match normalize_call_head head with
      | EVar { name; _ } ->
        (match Hashtbl.find_opt signatures name with
         | Some signature -> qualified signature.sig_owner signature.go_name
         | None -> invalid_arg "function argument validated before emission")
      | _ -> invalid_arg "function argument validated before emission"
    in
    let supplied = List.map (emit_expr ~indent signatures env) supplied in
    Printf.sprintf "%s(%s)" go_name (String.concat ", " (supplied @ bound))
  | _ -> invalid_arg "function argument validated before emission"

and callable_binders callable fallback =
  match callable with
  | ELambda { params = lambda_params; _ } ->
    List.map (fun (binding : binding) -> local_ident binding.name) lambda_params
  | _ -> fallback

(* Each higher-order leaf is one emitted loop.  The output slice is allocated once at
   its exact length rather than grown, and nothing here allocates a closure. *)
and emit_hof ?(indent="") signatures env _loc _what hof args result =
  let depth = String.length indent in
  let inner = indent ^ "\t" in
  let body_indent = inner ^ "\t" in
  (* Same normalisation as the type rule: the callback may be spelled `String.length`. *)
  let callable = normalize_call_head (List.nth args 0) in
  (* Mirrors the type rule: an EMPTY list argument takes its element type from the
     callback's declared parameter, since the literal carries none of its own. *)
  let element_position = match hof with HofFoldl -> 1 | _ -> 0 in
  let element_from_callable () =
    match callable with
    | ELambda { params; _ } ->
      (match !current_types, List.nth_opt params element_position with
       | Some types, Some (binding : binding) ->
         (try Some (type_of_type_expr types binding.type_expr) with Unsupported _ -> None)
       | _ -> None)
    | EVar { name; _ } ->
      (match Hashtbl.find_opt signatures name with
       | Some signature -> List.nth_opt signature.params element_position
       | None -> None)
    | _ -> None
  in
  let element_of index =
    match List.nth args index with
    | EList { elems = []; _ } when element_from_callable () <> None ->
      (match element_from_callable () with Some element -> element | None -> assert false)
    | arg ->
      (match type_of_expr signatures env arg with
       | TList element -> element
       | _ -> invalid_arg "higher-order leaf validated before emission")
  in
  let emit_list ?(at=indent) index =
    match List.nth args index with
    | EList { elems = []; _ } ->
      emit_expr ~expected:(TList (element_of index)) ~indent:at signatures env
        (List.nth args index)
    | arg -> emit_expr ~indent:at signatures env arg
  in
  (* The source list is BOUND, never spliced twice: `make(…, len(xs))` and `range xs` both
     mention it, and a source that is itself a comprehension would otherwise be emitted — and
     evaluated — twice, squaring the work of `List.filter f (List.map g xs)`.  Binding it at
     `inner` also gives the nested emission its own depth, so its `teslOut`/`teslAt` names
     cannot shadow this level's. *)
  let source_binding index =
    let emitted = emit_list ~at:inner index in
    (* A plain name needs no binding: it is already a single evaluation, and the extra line
       would be noise in the emitted code a reader is meant to be able to eject to. *)
    let simple =
      emitted <> ""
      && String.for_all (fun c ->
           (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
           || c = '_' || c = '.') emitted
    in
    if simple then emitted, ""
    else
      let name = Printf.sprintf "teslSrc%d" depth in
      name, Printf.sprintf "%s%s := %s\n" inner name emitted
  in
  (* A fold's initial accumulator may be an empty list literal, which only emits against
     an expected type. *)
  let emit_init accumulator =
    emit_expr ~expected:accumulator ~indent signatures env (List.nth args 1) in
  match hof with
  | HofMap | HofFilter | HofAny | HofAll ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let applied = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    (match hof with
     | HofMap ->
       let out = Printf.sprintf "teslOut%d" depth and index = Printf.sprintf "teslAt%d" depth in
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, len(%s))\n%sfor %s, %s := range %s {\n%s%s[%s] = %s\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner index value source
         body_indent out index applied
         inner inner out indent
     | HofFilter ->
       let out = Printf.sprintf "teslOut%d" depth in
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s {\n%s\t%s = append(%s, %s)\n%s}\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner value source
         body_indent (strip_outer_parens applied)
         body_indent out out value
         body_indent inner inner out indent
     | _ ->
       let found = (hof = HofAny) in
       Printf.sprintf
         "(func() bool {\n%s%sfor _, %s := range %s {\n%sif %s {\n%s\treturn %b\n%s}\n%s}\n%sreturn %b\n%s}())"
         bind_source inner value source
         body_indent
         (if found then strip_outer_parens applied
          else strip_outer_parens (emit_negated_applied ~indent:body_indent signatures env callable element value))
         body_indent found body_indent inner inner (not found) indent)
  | HofZip ->
    (* Racket truncates to the shorter list; the emitted loop does the same. *)
    let out = Printf.sprintf "teslOut%d" depth in
    let index = Printf.sprintf "teslAt%d" depth in
    let left = Printf.sprintf "teslLeft%d" depth in
    let right = Printf.sprintf "teslRight%d" depth in
    let pair = match result with
      | TList (TAdt (info, args)) ->
        (match single_variant info with
         | Some variant ->
           let names = List.map (fun (name, _) -> variant_field_go_name variant name)
             (variant_field_types info args variant) in
           (match names with
            | [first; second] ->
              Printf.sprintf "%s{%s: %s[%s], %s: %s[%s]}"
                (go_type (TAdt (info, args))) first left index second right index
            | _ -> invalid_arg "zip validated before emission")
         | None -> invalid_arg "zip validated before emission")
      | _ -> invalid_arg "zip validated before emission"
    in
    Printf.sprintf
      "(func() %s {\n%s%s := %s\n%s%s := %s\n%s%s := len(%s)\n%sif len(%s) < %s {\n%s\t%s = len(%s)\n%s}\n%s%s := make(%s, %s)\n%sfor %s := range %s {\n%s%s[%s] = %s\n%s}\n%sreturn %s\n%s}())"
      (go_type result) inner left (emit_list ~at:inner 0)
      inner right (emit_list ~at:inner 1)
      inner (Printf.sprintf "teslLen%d" depth) left
      inner right (Printf.sprintf "teslLen%d" depth)
      inner (Printf.sprintf "teslLen%d" depth) right
      inner
      inner out (go_type result) (Printf.sprintf "teslLen%d" depth)
      inner index out
      body_indent out index pair
      inner inner out indent
  | HofFilterCheck | HofAllCheck ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let checked = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    let out = Printf.sprintf "teslOut%d" depth in
    let kept = Printf.sprintf "teslKept%d" depth in
    let ok = Printf.sprintf "teslOK%d" depth in
    (* The per-element `ok` is scoped to its `if`, so the running flag MUST NOT share
       its name: `teslOK := false` would otherwise assign to the shadow and allCheck
       would never report a failure. *)
    let all_ok = Printf.sprintf "teslAll%d" depth in
    let elements = go_type (TList element) in
    (match hof with
     | HofFilterCheck ->
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = append(%s, %s)\n%s}\n%s}\n%sreturn %s\n%s}())"
         elements bind_source inner out elements source
         inner value source
         body_indent kept ok checked ok
         body_indent out out kept
         body_indent inner inner out indent
     | _ ->
       (* Racket's allCheck runs the check on EVERY element before deciding, so this
          does too: an early return would skip checks the Racket backend performs. *)
       Printf.sprintf
         "(func() %s {\n%s%s%s := true\n%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = append(%s, %s)\n%s} else {\n%s\t%s = false\n%s}\n%s}\n%sif %s {\n%s\treturn %s{%s: %s, %s: %s}\n%s}\n%sreturn %s{%s: %s}\n%s}())"
         (go_type result) bind_source inner all_ok
         inner out elements source
         inner value source
         body_indent kept ok checked ok
         body_indent out out kept
         body_indent body_indent all_ok body_indent
         inner
         inner all_ok inner (go_type result) adt_tag_field "teslrt.MaybeSomething"
         "SomethingValue" out inner
         inner (go_type result) adt_tag_field "teslrt.MaybeNothing" indent)
  (* `find` is an early-return loop; the other three fill a fresh output. *)
  | HofFind | HofFilterMap | HofConcatMap ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let applied = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    let out = Printf.sprintf "teslOut%d" depth in
    let found = Printf.sprintf "teslFound%d" depth in
    (match hof with
     | HofFind ->
       Printf.sprintf
         "(func() %s {\n%s%sfor _, %s := range %s {\n%sif %s {\n%s\treturn %s{%s: teslrt.MaybeSomething, SomethingValue: %s}\n%s}\n%s}\n%sreturn %s{%s: teslrt.MaybeNothing}\n%s}())"
         (go_type result) bind_source inner value source
         body_indent (strip_outer_parens applied)
         body_indent (go_type result) adt_tag_field value
         body_indent inner
         inner (go_type result) adt_tag_field indent
     | HofFilterMap ->
       (* Decided by the TAG: a `Something` whose payload is `false` is still kept. *)
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s := %s; %s.%s == teslrt.MaybeSomething {\n%s\t%s = append(%s, %s.SomethingValue)\n%s}\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner value source
         body_indent found applied found adt_tag_field
         body_indent out out found
         body_indent inner inner out indent
     | _ ->
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%s%s = append(%s, %s...)\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner value source
         body_indent out out applied
         inner inner out indent)
  (* `sortBy` builds a comparator from the key function.  The key is recomputed per
     comparison, matching `List.sortBy` in tesl/list.rkt, and the sort is stable. *)
  | HofSortBy ->
    let element = element_of 1 in
    (* Fixed names, NOT depth-derived: the comparator is a package-level function with its
       own scope, so nothing can collide — and a depth-derived name would differ between
       the looped and flat emission passes, minting a second helper the first pass's name
       no longer matches and leaving an unused function behind. *)
    let left = "teslLeft" and right = "teslRight" in
    let key_ty = type_of_callable signatures env (Checker.expr_loc callable) "List.sortBy"
      callable [element] in
    (* A comparator needs the key on BOTH sides, and a lambda body inlined twice would
       reference its own parameter name, which is bound to neither side.  So a lambda key
       is hoisted into a named function — emitted once, with the lambda's parameter as the
       Go parameter, which is exactly the shape `emit_applied` already produces — and each
       side becomes a direct, inlinable call.  A named key function needs none of this. *)
    let key_call =
      match callable with
      | ELambda { params = [param]; _ } ->
        let binder = local_ident param.name in
        let name = remember_helper ~prefix:"teslSortKey"
          ~signature:(Printf.sprintf "(%s %s) %s" binder (go_type element) (go_type key_ty))
          ~body:(emit_applied ~indent:"\t" signatures env callable [element] [binder])
        in
        (fun side -> Printf.sprintf "%s(%s)" name side)
      | _ ->
        (fun side -> emit_applied ~indent:body_indent signatures env callable [element] [side])
    in
    (* The comparator is hoisted for the same reason a nested element comparator is: a
       one-line func literal survives only while go/printer judges it small enough, and
       this one is not. *)
    let less = remember_helper ~prefix:"teslSortLess"
      ~signature:(Printf.sprintf "(%s, %s %s) bool" left right (go_type element))
      ~body:(ordered_expr key_ty "<" (key_call left) (key_call right))
    in
    Printf.sprintf "teslrt.ListSortBy(%s, %s)" (emit_list 1) less
  | HofFoldl ->
    let element = element_of 2 in
    let accumulator = result in
    let bound = match callable_binders callable
      [Printf.sprintf "teslAcc%d" depth; Printf.sprintf "Value%d" depth] with
      | [acc; value] -> [acc; value]
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let state = Printf.sprintf "teslState%d" depth in
    let applied =
      emit_applied ~indent:body_indent signatures env callable [accumulator; element] bound in
    Printf.sprintf
      "(func() %s {\n%s%s := %s\n%sfor _, %s := range %s {\n%s%s := %s\n%s_ = %s\n%s%s = %s\n%s}\n%sreturn %s\n%s}())"
      (go_type accumulator) inner state (emit_init accumulator)
      inner (List.nth bound 1) (emit_list ~at:inner 2)
      body_indent (List.nth bound 0) state
      body_indent (List.nth bound 0)
      body_indent state applied
      inner inner state indent
  (* `foldr` walks the slice BACKWARDS in a plain loop rather than recursing: Go has no
     TCO and a Go stack overflow is fatal (no `recover`), so recursing once per element
     would put a list length limit on a function Racket runs fine.  The fold itself
     therefore adds only O(n) traversal.  What it CANNOT fix is a callback that performs
     an immutable write on a growing accumulator — `List.append [x] acc` copies Θ(k) at
     step k, so the canonical reconstruction fold is Θ(n²) in the CALLBACK, not in the
     fold.  Lowering recognised builder folds to a private allocate-once builder is a
     tracked gate, and it needs an escape/linearity condition first: an arbitrary callback
     may retain an earlier accumulator inside its result, so uniqueness cannot be assumed
     from the shape alone. *)
  | HofFoldr ->
    let element = element_of 2 in
    let accumulator = result in
    let bound = match callable_binders callable
      [Printf.sprintf "Value%d" depth; Printf.sprintf "teslAcc%d" depth] with
      | [value; acc] -> [value; acc]
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let state = Printf.sprintf "teslState%d" depth in
    let source = Printf.sprintf "teslSource%d" depth in
    let index = Printf.sprintf "teslAt%d" depth in
    let applied =
      emit_applied ~indent:body_indent signatures env callable [element; accumulator] bound in
    (* The list is bound once: it is an arbitrary expression, and backwards iteration
       needs both its length and an index into it. *)
    Printf.sprintf
      "(func() %s {\n%s%s := %s\n%s%s := %s\n%sfor %s := len(%s) - 1; %s >= 0; %s-- {\n%s%s := %s[%s]\n%s_ = %s\n%s%s := %s\n%s_ = %s\n%s%s = %s\n%s}\n%sreturn %s\n%s}())"
      (go_type accumulator) inner state (emit_init accumulator)
      inner source (emit_list ~at:inner 2)
      inner index source index index
      body_indent (List.nth bound 0) source index
      body_indent (List.nth bound 0)
      body_indent (List.nth bound 1) state
      body_indent (List.nth bound 1)
      body_indent state applied
      inner inner state indent

(* `all` is the negation of "any element fails", and negating structurally keeps the
   emitted condition free of the `!(a && b)` shapes the lint gate rejects. *)
and emit_negated_applied ?(indent="") signatures env callable element value =
  match callable with
  | ELambda { params = lambda_params; body; _ } ->
    let env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) lambda_params [element] @ env in
    emit_negated ~indent signatures env body
  | _ -> negate_bool (emit_applied ~indent signatures env callable [element] [value])

(* Dict leaves are ordinary runtime calls; the only emitted extra is the key ordering,
   appended last so the hand-written signatures read naturally. *)
and emit_dict_leaf ?(indent="") signatures env loc leaf args result expected =
  let args = normalize_call_args (List.init leaf.dict_arity (fun _ -> TUnit)) args in
  let key =
    match leaf.dict_name, result, expected with
    | "Dict.empty", _, Some (TDict (key, _)) -> Some key
    | "Dict.empty", _, _ -> None
    | _, TDict (key, _), _ -> Some key
    | _ ->
      (match type_of_expr signatures env (List.nth args (leaf.dict_arity - 1)) with
       | TDict (key, _) -> Some key
       | _ -> None)
  in
  (* `Dict.empty` takes no argument, so its type parameters have to be written out. *)
  let instantiation =
    if leaf.dict_name <> "Dict.empty" then ""
    else match expected with
      | Some (TDict (key, value)) ->
        Printf.sprintf "[%s, %s]" (go_type key) (go_type value)
      | _ -> unsupported loc
        "Go backend cannot infer the key and value types of `Dict.empty`"
  in
  let emitted = List.map (emit_expr ~indent signatures env) args in
  (* Tesl puts the dict LAST (`Dict.insert key value d`); the runtime signatures put it
     first, which is what a Go author expects.  The emitter rotates rather than
     distorting the hand-written runtime. *)
  let emitted =
    if leaf.dict_arity > 1 then
      match List.rev emitted with
      | dict :: rest -> dict :: List.rev rest
      | [] -> emitted
    else emitted
  in
  let emitted =
    if not leaf.dict_needs_order then emitted
    else match key with
      | Some key -> emitted @ [element_key_less_func key]
      | None -> unsupported loc "Go backend `%s` needs ordered keys" leaf.dict_name
  in
  Printf.sprintf "%s%s(%s)" leaf.dict_go instantiation (String.concat ", " emitted)

(* Set leaves are ordinary runtime calls; the ordering is appended last, and
   `Set.empty` writes its type parameter out since it has no argument to infer from. *)
and emit_set_leaf ?(indent="") signatures env loc leaf args result expected =
  let args = normalize_call_args (List.init leaf.set_arity (fun _ -> TUnit)) args in
  let element = match result, expected with
    | TSet element, _ -> element
    | _, Some (TSet element) -> element
    | _ ->
      if leaf.set_index >= 0 then
        (match type_of_expr signatures env (List.nth args leaf.set_index) with
         | TSet element -> element
         | _ -> unsupported loc "Go backend `%s` requires a Set argument" leaf.set_name)
      else unsupported loc "Go backend cannot infer the element type of `%s`" leaf.set_name
  in
  let instantiation =
    if leaf.set_name <> "Set.empty" then ""
    else Printf.sprintf "[%s]" (go_type element)
  in
  let emitted = List.map (emit_expr ~indent signatures env) args in
  let emitted =
    if not leaf.set_needs_order then emitted
    else emitted @ [element_key_less_func element]
  in
  Printf.sprintf "%s%s(%s)" leaf.set_go instantiation (String.concat ", " emitted)

and emit_variant_literal ?(indent="") signatures env result variant args =
  let info, type_args = match result with
    | TAdt (info, args) -> info, args
    | _ -> invalid_arg "constructor validated before emission"
  in
  let payload = variant_field_types info type_args variant in
  let parts = List.map2 (fun arg (name, field_ty) ->
    Printf.sprintf "%s: %s" (variant_field_go_name variant name)
      (emit_expr ~expected:field_ty ~indent signatures env arg)) args payload in
  let fields =
    if single_variant info <> None then parts
    else (adt_tag_field ^ ": " ^ qualified info.adt_owner variant.var_tag) :: parts
  in
  Printf.sprintf "%s{%s}" (go_type result) (String.concat ", " fields)

and emit_record_literal ?(indent="") signatures env info fields =
  (* A field-by-field COPY between two records with the same fields in the same order is a
     staticcheck finding on the emitted code (S1016, "should convert instead of using a
     struct literal") — and a lint finding on emitted code is an emitter bug by contract.
     It is also what the Go conversion says more clearly, so `Target(source)` is emitted
     when every field is `source.<same field>` and the source type matches field for
     field. *)
  let conversion_source () =
    let field_of_source name =
      match List.assoc_opt name fields with
      | Some (EField { obj = EVar { name = binder; _ }; field; _ }) when field = name ->
        Some binder
      | _ -> None
    in
    match info.rec_fields with
    | [] -> None
    | (first, _) :: _ ->
      (match field_of_source first with
       | None -> None
       | Some binder ->
         let all_from_binder =
           List.for_all (fun (name, _) -> field_of_source name = Some binder)
             info.rec_fields
         in
         if not all_from_binder then None
         else
           (match List.assoc_opt binder env with
            | Some (TRecord source)
              when source.rec_go_name <> info.rec_go_name
                && List.length source.rec_fields = List.length info.rec_fields
                && List.for_all2 (fun (left, left_ty) (right, right_ty) ->
                     left = right && left_ty = right_ty)
                     source.rec_fields info.rec_fields ->
              Some (local_ident binder)
            | _ -> None))
  in
  match conversion_source () with
  | Some source ->
    Printf.sprintf "%s(%s)" (qualified info.rec_owner info.rec_go_name) source
  | None ->
  let parts = List.map (fun (name, field_ty) ->
    let value = match List.assoc_opt name fields with
      | Some value -> value
      | None -> invalid_arg "record literal validated before emission"
    in
    Printf.sprintf "%s: %s" (record_field_go_name name)
      (emit_expr ~expected:field_ty ~indent signatures env value)) info.rec_fields in
  (* Qualified for the same reason `go_type` qualifies: a record declared by another
     package is constructed through that package's name. *)
  Printf.sprintf "%s{%s}" (qualified info.rec_owner info.rec_go_name)
    (String.concat ", " parts)

(* Tesl record update copies the base and overrides the listed fields.  A struct
   literal naming every field is the readable Go shape, but it repeats the base
   expression once per preserved field, so anything other than a local binding is
   bound first. *)
and emit_record_update ?(indent="") signatures env loc fields =
  let base, updates = record_update_parts loc fields in
  let info = match type_of_expr signatures env base with
    | TRecord info -> info
    | _ -> unsupported loc "Go backend record update requires a record value"
  in
  let literal value_indent base_text =
    let parts = List.map (fun (name, field_ty) ->
      let value = match List.assoc_opt name updates with
        | Some value -> emit_expr ~expected:field_ty ~indent:value_indent signatures env value
        | None -> Printf.sprintf "%s.%s" base_text (record_field_go_name name)
      in
      Printf.sprintf "%s: %s" (record_field_go_name name) value) info.rec_fields in
    Printf.sprintf "%s{%s}" (qualified info.rec_owner info.rec_go_name)
      (String.concat ", " parts)
  in
  let rec is_local = function
    | EVar { name; _ } -> List.mem_assoc name env
    | EField { obj; _ } -> is_local obj
    | _ -> false
  in
  (* The struct literal repeats the base once per preserved field, so the base has
     to be a binding rather than a computation.  Today's surface syntax only allows
     `{ identifier | ... }`, so this rejection is unreachable from `.tesl` source and
     stays as containment rather than an untested emit path. *)
  if not (is_local base) then
    unsupported loc "Go backend record update requires a bound record value";
  literal indent (selector_operand (emit_expr ~indent signatures env base))

(* ─── Queries ─────────────────────────────────────────────────────────────────
   The `backend: Memory` store has no query planner: a clause is the same comparison
   the Racket runtime performs row by row, so a query becomes a table call plus a Go
   PREDICATE over the row.  The binder is the one the query itself named, which is what
   lets a `set` value or a column-to-column comparison read as written. *)
and sql_table_ref (info : entity_info) = qualified info.ent_owner info.ent_table_var

and sql_row_type (info : entity_info) = go_type (TRecord info.ent_row)

and sql_column_value ~indent signatures row_env loc (info : entity_info) field expr =
  let want = entity_column loc info field in
  let got = type_of_expr signatures row_env expr in
  if got <> want then unsupported (Checker.expr_loc expr)
    "Go backend: the value written to `%s.%s` has a different type than the column"
    info.ent_tesl_name field;
  emit_expr ~expected:want ~indent signatures row_env expr

and emit_sql_predicate ~indent signatures env loc (info : entity_info) binder clauses =
  let row_env = (binder, TRecord info.ent_row) :: env in
  let column_ref field =
    Printf.sprintf "%s.%s" (local_ident binder) (record_field_go_name field) in
  let compare_op field op expr =
    let ty = entity_column loc info field in
    let left = column_ref field in
    let right = sql_column_value ~indent signatures row_env loc info field expr in
    match op with
    | BEq -> equal_expr ty left right
    | BNeq -> unequal_expr ty left right
    | BLt | BLe | BGt | BGe ->
      if not (supports_ordering ty) then unsupported loc
        "Go backend cannot order column `%s.%s`" info.ent_tesl_name field;
      let symbol = match op with
        | BLt -> "<" | BLe -> "<=" | BGt -> ">" | _ -> ">=" in
      ordered_expr ty symbol left right
    | _ -> unsupported loc
      "Go backend does not support this operator in a `where` clause yet"
  in
  (* `like` / `ilike` are String-only, as they are on the Racket side (which rejects a
     Money column outright and answers false for any non-string value). *)
  let like field pattern fold_case =
    let ty = entity_column loc info field in
    let text = match ty with
      | TString -> column_ref field
      | TNewtype newtype when newtype.base = TString ->
        Printf.sprintf "%s.Value" (column_ref field)
      | _ -> unsupported loc
        "Go backend supports `like`/`ilike` on a String column only, and `%s.%s` is not one"
        info.ent_tesl_name field
    in
    let pattern_ty = type_of_expr signatures row_env pattern in
    if pattern_ty <> TString then unsupported (Checker.expr_loc pattern)
      "Go backend `like`/`ilike` needs a String pattern";
    Printf.sprintf "teslrt.SqlLike(%s, %s, %b)" text
      (emit_expr ~expected:TString ~indent signatures row_env pattern) fold_case
  in
  let rec clause (c : Sql_query.sql_clause) =
    match c with
    | SqlPred { field; op; value } -> compare_op field op value
    | SqlOr parts ->
      (* An empty disjunction matches nothing, which is what the SQL `false` it would
         render to does.  It is not reachable from source; the case exists so the
         renderer is total. *)
      (match List.map clause parts with
       | [] -> "false"
       | rendered -> "(" ^ String.concat " || " rendered ^ ")")
    | SqlIn { field; values } ->
      (match List.map (fun value -> compare_op field BEq value) values with
       | [] -> "false"
       | rendered -> "(" ^ String.concat " || " rendered ^ ")")
    | SqlNotIn { field; values } ->
      (match List.map (fun value -> compare_op field BNeq value) values with
       | [] -> "true"
       | rendered -> "(" ^ String.concat " && " rendered ^ ")")
    | SqlIsNull { field } -> unsupported loc
      "Go backend does not support `where isNull %s.%s` yet" binder field
    | SqlIsNotNull { field } -> unsupported loc
      "Go backend does not support `where isNotNull %s.%s` yet" binder field
    | SqlLike { field; pattern } -> like field pattern false
    | SqlILike { field; pattern } -> like field pattern true
  in
  (* The predicate is emitted ALREADY SPLIT across lines rather than as a one-liner.  A
     `func(r T) bool { return … }` survives gofmt only while go/printer judges the whole line
     short enough, and a two-clause `where` on a newtype column is already past that — so a
     one-liner is gofmt-stable for small predicates and reflowed for the rest, which the
     emitted-code gate reads as an emitter bug (correctly: the emitter must produce gofmt's
     own output).  gofmt never JOINS a split literal, so the split form is stable at every
     size. *)
  let split params returned =
    Printf.sprintf "func(%s) bool {\n%s\treturn %s\n%s}" params indent returned indent
  in
  match clauses with
  (* No clause means every row, and naming the row would leave an unused parameter. *)
  | [] -> split (Printf.sprintf "_ %s" (sql_row_type info)) "true"
  | _ ->
    split (Printf.sprintf "%s %s" (local_ident binder) (sql_row_type info))
      (String.concat " && " (List.map clause clauses))

(* `where_field` is the field the RECOVERY saw first; every supported form also produces
   a clause for it.  One left over means the predicate was written in a shape this
   backend does not render, and emitting the query without it would silently read or
   write the wrong rows. *)
and sql_check_where_field loc where_field clauses =
  let rec mentions field (c : Sql_query.sql_clause) =
    match c with
    | SqlPred { field = other; _ } | SqlIsNull { field = other }
    | SqlIsNotNull { field = other } | SqlIn { field = other; _ }
    | SqlNotIn { field = other; _ } | SqlLike { field = other; _ }
    | SqlILike { field = other; _ } -> other = field
    | SqlOr parts -> List.exists (mentions field) parts
  in
  match where_field with
  | Some field when not (List.exists (mentions field) clauses) ->
    unsupported loc
      "Go backend does not support this `where` clause shape (on `%s`) yet" field
  | _ -> ()

(* The duplicate-primary-key test an insert carries: the same comparison the Racket
   memory backend performs by keying its store on the primary key. *)
and sql_key_conflict loc (info : entity_info) =
  let key = info.ent_primary_key in
  let key_type = entity_column loc info key in
  let field name = Printf.sprintf "%s.%s" name (record_field_go_name key) in
  Printf.sprintf "func(teslRow, teslNew %s) bool { return %s }" (sql_row_type info)
    (equal_expr key_type (field "teslRow") (field "teslNew"))

and emit_sql_form ?(indent="") signatures env loc form =
  match form with
  | SqlSelect (seed, clauses) ->
    let info = entity_of_query loc seed.entity in
    let all_clauses = seed.static_clauses @ clauses in
    sql_check_where_field loc seed.where_field all_clauses;
    if seed.joins <> [] then unsupported loc
      "Go backend does not support `innerJoin` yet";
    if seed.group_by <> [] then unsupported loc
      "Go backend does not support `groupBy` yet";
    let predicate =
      emit_sql_predicate ~indent signatures env loc info seed.binder all_clauses in
    (* `order p.field asc|desc` becomes the STRICTLY-BEFORE comparison on that column;
       `desc` is the same comparison with its operands swapped, which keeps the sort
       stable in the direction Racket's ordering does. *)
    let ordering () = match seed.order with
      | None -> None
      | Some (field, direction) ->
        let ty = entity_column loc info field in
        if not (supports_ordering ty) then unsupported loc
          "Go backend cannot order by column `%s.%s`" info.ent_tesl_name field;
        let column name = Printf.sprintf "%s.%s" name (record_field_go_name field) in
        let left, right = match direction with
          | "desc" -> column "teslRight", column "teslLeft"
          | _ -> column "teslLeft", column "teslRight"
        in
        Some (Printf.sprintf "func(teslLeft, teslRight %s) bool { return %s }"
                (sql_row_type info) (ordered_expr ty "<" left right))
    in
    let range () =
      (* A missing `limit` is "every row", spelled as a negative count. *)
      Printf.sprintf "%d, %d" (Option.value seed.offset ~default:0)
        (Option.value seed.limit ~default:(-1))
    in
    let table = sql_table_ref info in
    (match seed.kind with
     | SelectMany ->
       (match ordering (), seed.limit, seed.offset with
        | None, None, None -> Printf.sprintf "teslrt.TableSelect(%s, %s)" table predicate
        | None, _, _ ->
          Printf.sprintf "teslrt.TableSelectRange(%s, %s, %s)" table predicate (range ())
        | Some less, _, _ ->
          Printf.sprintf "teslrt.TableSelectSorted(%s, %s, %s, %s)"
            table predicate less (range ()))
     | SelectOne ->
       (* `limit`/`offset` on a `selectOne` would change WHICH row it is, so they are
          refused rather than dropped; `order` decides it and is supported. *)
       if seed.limit <> None || seed.offset <> None then unsupported loc
         "Go backend does not support `limit`/`offset` on `selectOne` yet";
       (match ordering () with
        | None -> Printf.sprintf "teslrt.TableSelectOne(%s, %s)" table predicate
        | Some less ->
          Printf.sprintf "teslrt.TableSelectOneSorted(%s, %s, %s)" table predicate less)
     | SelectCount ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on \
                          `selectCount` yet";
       Printf.sprintf "teslrt.TableCount(%s, %s)" table predicate
     | SelectSum field ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on \
                          `selectSum` yet";
       let ty = entity_column loc info field in
       let column = Printf.sprintf "teslRow.%s" (record_field_go_name field) in
       let project = Printf.sprintf "func(teslRow %s) %s { return %s }"
         (sql_row_type info) (go_type ty) column in
       (* The SUM is over the column's OWN type, so a newtype column sums to that
          newtype and a Float column to a Float — no unwrapping at the boundary. *)
       let combine, zero = match ty with
         | TInt -> "teslrt.Add", "teslrt.FromInt64(0)"
         | TFloat ->
           Printf.sprintf "func(teslLeft, teslRight float64) float64 { return teslLeft + teslRight }",
           "float64(0)"
         | TNewtype newtype when newtype.base = TInt ->
           Printf.sprintf
             "func(teslLeft, teslRight %s) %s { return %s{Value: teslrt.Add(teslLeft.Value, teslRight.Value)} }"
             (go_type ty) (go_type ty) (go_type ty),
           Printf.sprintf "%s{Value: teslrt.FromInt64(0)}" (go_type ty)
         | TNewtype newtype when newtype.base = TFloat ->
           Printf.sprintf
             "func(teslLeft, teslRight %s) %s { return %s{Value: teslLeft.Value + teslRight.Value} }"
             (go_type ty) (go_type ty) (go_type ty),
           Printf.sprintf "%s{Value: float64(0)}" (go_type ty)
         | _ -> unsupported loc
           "Go backend cannot sum column `%s.%s`" info.ent_tesl_name field
       in
       Printf.sprintf "teslrt.TableFold(%s, %s, %s, %s, %s)"
         table predicate project combine zero
     (* `selectMax`/`selectMin` answer a `Maybe`: no matching row is `Nothing`, not a trap
        and not a fabricated zero. *)
     | SelectMax field | SelectMin field ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on \
                          `selectMax`/`selectMin` yet";
       let biggest = match seed.kind with SelectMax _ -> true | _ -> false in
       let ty = entity_column loc info field in
       if not (supports_ordering ty) then unsupported loc
         "Go backend cannot compare column `%s.%s`" info.ent_tesl_name field;
       let project = Printf.sprintf "func(teslRow %s) %s { return teslRow.%s }"
         (sql_row_type info) (go_type ty) (record_field_go_name field) in
       let better =
         Printf.sprintf "func(teslLeft, teslRight %s) bool { return %s }" (go_type ty)
           (ordered_expr ty (if biggest then ">" else "<") "teslLeft" "teslRight") in
       Printf.sprintf "teslrt.TableExtreme(%s, %s, %s, %s)"
         table predicate project better
     | SelectCountBy -> unsupported loc "Go backend does not support `selectCountBy` yet"
     | SelectSumBy _ -> unsupported loc "Go backend does not support `selectSumBy` yet")
  | SqlInsert insert ->
    let info = entity_of_query loc insert.entity in
    check_record_literal signatures env loc info.ent_row insert.fields;
    Printf.sprintf "teslrt.TableInsert(%s, %s, %s, %s)"
      (sql_table_ref info) (go_quote info.ent_tesl_name)
      (emit_record_literal ~indent signatures env info.ent_row insert.fields)
      (sql_key_conflict loc info)
  | SqlInsertMany (list_var, entity) ->
    let info = entity_of_query loc entity in
    let rows = match List.assoc_opt list_var env with
      | Some (TList (TRecord row)) when row == info.ent_row -> local_ident list_var
      | Some _ -> unsupported loc
        "Go backend: `insertMany %s in %s` needs a list of `%s` rows"
        list_var entity entity
      | None -> unsupported loc "Go backend cannot resolve value `%s`" list_var
    in
    Printf.sprintf "teslrt.TableInsertMany(%s, %s, %s, %s)"
      (sql_table_ref info) (go_quote info.ent_tesl_name) rows (sql_key_conflict loc info)
  | SqlUpdate update ->
    let info = entity_of_query loc update.entity in
    sql_check_where_field loc None update.clauses;
    let row_env = (update.binder, TRecord info.ent_row) :: env in
    let predicate =
      emit_sql_predicate ~indent signatures env loc info update.binder update.clauses in
    let inner = indent ^ "\t" in
    let assignments = List.map (fun (field, value) ->
      Printf.sprintf "%steslNext.%s = %s\n" inner (record_field_go_name field)
        (sql_column_value ~indent:inner signatures row_env loc info field value))
      update.updates in
    (* Every `set` value reads the row as it was: SQL evaluates the whole SET list
       against the old row, so assigning into a COPY is the parity-preserving shape —
       assigning in place would let one `set` feed the next. *)
    let apply =
      Printf.sprintf "func(%s %s) %s {\n%steslNext := %s\n%s%sreturn teslNext\n%s}"
        (local_ident update.binder) (sql_row_type info) (sql_row_type info)
        inner (local_ident update.binder)
        (String.concat "" assignments) inner indent
    in
    Printf.sprintf "teslrt.%s(%s, %s, %s)"
      (if update.returning_one then "TableUpdateReturnOne" else "TableUpdate")
      (sql_table_ref info) predicate apply
  | SqlDelete (seed, clauses) ->
    let info = entity_of_query loc seed.entity in
    sql_check_where_field loc seed.where_field clauses;
    if seed.with_result then unsupported loc
      "Go backend does not support `deleteAndReturnResult` yet";
    Printf.sprintf "teslrt.TableDelete(%s, %s)" (sql_table_ref info)
      (emit_sql_predicate ~indent signatures env loc info seed.binder clauses)

(* An api-test request BODY is a JSON template: `body { "tag": "one" }`.  It is rendered to
   the JSON text the request carries.  A literal template becomes a constant string at
   compile time; a value spliced from the test's own bindings is encoded at run time through
   the runtime's JSON writer, so the two cannot disagree about escaping. *)
and emit_api_test_body ?(indent="") signatures env value =
  let rec literal_json expr =
    match expr with
    | ELit { lit = LString text; _ } -> Some (json_quote text)
    | ELit { lit = LInt n; _ } -> Some (string_of_int n)
    | ELit { lit = LBigInt text; _ } -> Some text
    | ELit { lit = LBool b; _ } -> Some (if b then "true" else "false")
    | ELit { lit = LFloat f; _ } -> Some (json_float f)
    | EConstructor { name = "True"; args = []; _ } -> Some "true"
    | EConstructor { name = "False"; args = []; _ } -> Some "false"
    | EList { elems; _ } ->
      let rendered = List.map literal_json elems in
      if List.for_all Option.is_some rendered then
        Some ("[" ^ String.concat "," (List.map Option.get rendered) ^ "]")
      else None
    | ERecord { fields; _ } ->
      let rendered = List.map (fun (key, field_value) ->
        Option.map (fun text -> json_quote key ^ ":" ^ text) (literal_json field_value))
        fields in
      if List.for_all Option.is_some rendered then
        Some ("{" ^ String.concat "," (List.map Option.get rendered) ^ "}")
      else None
    | _ -> None
  in
  match literal_json value with
  | Some json -> go_quote json
  | None ->
    (* Not a constant template: a String expression is sent as-is (it IS the body), and
       anything else fails closed rather than being guessed at. *)
    if type_of_expr signatures env value = TString then
      emit_expr ~expected:TString ~indent signatures env value
    else
      unsupported (Checker.expr_loc value)
        "Go backend api-test body must be a literal JSON template or a String"

and emit_interp ?(indent="") signatures env segments =
  let parts = List.map (function
    | ILiteral value -> go_quote value
    | IExpr expr ->
      let emitted = emit_expr ~indent signatures env expr in
      match type_of_expr signatures env expr with
      | TString -> emitted
      | TInt -> emitted ^ ".String()"
      | TFloat -> Printf.sprintf "teslrt.FormatFloat(%s)" emitted
      | TBool -> Printf.sprintf "strconv.FormatBool(%s)" emitted
      | _ -> unsupported (Checker.expr_loc expr)
        "Go backend interpolation supports String, Int, Float, and Bool only") segments in
  match parts with
  | [] -> go_quote ""
  | [part] -> part
  | _ -> "(" ^ String.concat " + " parts ^ ")"

and emit_if_expr ?expected ?(indent="") signatures env expr =
  match expr with
  | EIf { cond; then_; else_; _ } ->
    let inferred = type_of_expr signatures env expr in
    let result = match inferred, expected with
      | TFailure, Some expected -> expected
      | _ -> inferred
    in
    Printf.sprintf "teslrt.If(%s, func() %s {\n%s\treturn %s\n%s}, func() %s {\n%s\treturn %s\n%s})"
      (emit_expr ~indent signatures env cond)
      (go_type result)
      indent (emit_expr ~expected:result ~indent:(indent ^ "\t") signatures env then_) indent
      (go_type result)
      indent (emit_expr ~expected:result ~indent:(indent ^ "\t") signatures env else_) indent
  | _ -> invalid_arg "emit_if_expr requires EIf"

and emit_let_expr ?expected ?(indent="") signatures env expr =
  let inferred = type_of_expr signatures env expr in
  let result = match inferred, expected with
    | TFailure, Some expected -> expected
    | _ -> inferred
  in
  let buffer = Buffer.create 192 in
  Printf.bprintf buffer "(func() %s {\n" (go_type result);
  let rec emit_bindings env = function
    (* `let (v ::: pf) = y`: the value binding is `y` itself and the proof binder is the
       zero-size proof value.  Both are emitted, because later code names both. *)
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let value_ty = type_of_expr signatures env value in
      let emitted =
        emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent (local_ident value_name)
        emitted indent (local_ident value_name);
      Printf.bprintf buffer "%s\t%s := struct{}{}\n%s\t_ = %s\n" indent
        (local_ident proof_name) indent (local_ident proof_name);
      emit_bindings ((proof_name, TUnit) :: (value_name, value_ty) :: env) body
    | ELet { name; value; body; _ } ->
      let inferred_value_ty = type_of_expr signatures env value in
      let value_ty = if inferred_value_ty = TFailure then result else inferred_value_ty in
      let emitted =
        emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      (* `let _ = expr` is written for its EFFECT and discards the value; `_ := expr` is
         not legal Go, so it becomes a plain discard (as in the statement emitter). *)
      if name = "_" then Printf.bprintf buffer "%s\t_ = %s\n" indent emitted
      else begin
        let go_name = local_ident name in
        Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent go_name emitted indent go_name
      end;
      emit_bindings ((name, value_ty) :: env) body
    | body ->
      Printf.bprintf buffer "%s\treturn %s\n" indent
        (emit_expr ~expected:result ~indent:(indent ^ "\t") signatures env body)
  in
  emit_bindings env expr;
  Printf.bprintf buffer "%s}())" indent;
  Buffer.contents buffer

let loop_label = "teslLoop"

(* A Tesl self tail call is a loop, not a stack frame.  Racket has TCO, Go does not,
   and Go's stack overflow is a FATAL error that `recover` cannot catch — so a deep
   tail-recursive program that merely runs on Racket would kill the process here.
   Only a call in tail position to the enclosing function, with the whole parameter
   list supplied and the name not shadowed by a local, qualifies. *)
let self_tail_call_args signatures env ~name ~arity expr =
  let resolves_to_self called =
    called = name && not (List.mem_assoc called env)
  in
  match expr with
  | EVar { name = called; _ } when arity = 0 && resolves_to_self called -> Some []
  | EApp _ ->
    let head, args = flatten_app [] expr in
    (match head with
     | EVar { name = called; _ } when resolves_to_self called ->
       let signature = Hashtbl.find_opt signatures called in
       let args = match signature with
         | Some { params; _ } -> normalize_call_args params args
         | None -> args
       in
       if List.length args = arity then Some args else None
     | _ -> None)
  | _ -> None

let emit_tail ?self buffer signatures env expected indent expr =
  let self_name, self_params = match self with
    | Some (name, params) -> Some name, params
    | None -> None, []
  in
  let emit_self_tail_call env indent args =
    (* Every argument lands in its own temporary first: a direct tuple assignment
       makes a pass-through argument a self-assignment, which `go vet` rejects. *)
    let temporaries = List.mapi (fun index arg ->
      let temporary = Printf.sprintf "teslArg%d_%d" (String.length indent) index in
      Printf.bprintf buffer "%s%s := %s\n" indent temporary
        (emit_expr ~indent signatures env arg);
      temporary) args in
    if temporaries <> [] then
      Printf.bprintf buffer "%s%s = %s\n" indent (String.concat ", " self_params)
        (String.concat ", " temporaries);
    Printf.bprintf buffer "%scontinue %s\n" indent loop_label
  in
  let rec go env indent expr =
    match self_name with
    | Some name when
        self_tail_call_args signatures env ~name ~arity:(List.length self_params) expr <> None ->
      let args = match
        self_tail_call_args signatures env ~name ~arity:(List.length self_params) expr with
        | Some args -> args
        | None -> assert false
      in
      ignore (type_of_expr signatures env expr);
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      emit_self_tail_call env indent args
    | _ -> go_shape env indent expr
  and go_shape env indent expr =
    match expr with
    (* `with database D { … }` adds nothing at run time on the Memory backend, so its body
       is emitted in TAIL position — the block keeps statement form instead of collapsing
       into an immediately-called closure. *)
    | EWithDatabase { body; _ } -> go env indent body
    (* Proof decomposition in tail position keeps statement form, like an ordinary `let`.
       Either half may be `_`, since the decomposition is often written for one of them. *)
    | ELetProof { value_name; proof_name; value; body; loc; _ } ->
      let value_ty = type_of_expr signatures env value in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let emitted =
        emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      if value_name = "_" then
        Printf.bprintf buffer "%s\t_ = %s\n" indent emitted
      else
        Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent (local_ident value_name)
          emitted indent (local_ident value_name);
      if proof_name <> "_" then
        Printf.bprintf buffer "%s\t%s := struct{}{}\n%s\t_ = %s\n" indent
          (local_ident proof_name) indent (local_ident proof_name);
      go ((proof_name, TUnit) :: (value_name, value_ty) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    (* `let v = check g x` inside another CHECK: a rejection PROPAGATES — it becomes this
       check's own result, carrying the inner status and message.  Racket's `let/check`
       does exactly this (`(if (check-fail? result) result …)`), and the emitter used to
       reach for `MustCheck` here, which PANICS: a handler that should have answered 422
       crashed the request instead.  In a plain `fn` the trap is correct and stays — Racket
       raises there too, since `define/pow` installs a raising handler rather than letting a
       failure leak out as a value. *)
    | ELet { name; value; body; loc; _ }
      when (match check_application signatures value, expected with
            | Some _, TCheck _ -> true
            | _ -> false) ->
      let signature, args = match check_application signatures value with
        | Some pair -> pair
        | None -> assert false
      in
      let inner = match signature.result with
        | TCheck inner -> inner
        | _ -> assert false
      in
      (* Runs the ordinary check-call validation (arity, argument types) — the same one the
         non-propagating path gets — so this branch cannot accept a call the other rejects. *)
      ignore (type_of_expr signatures env value);
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let temporary = Printf.sprintf "teslDelegated%d" (String.length indent) in
      Printf.bprintf buffer "%s\t%s := %s(%s)\n" indent temporary
        (qualified signature.sig_owner signature.go_name)
        (String.concat ", " (List.map2 (fun arg want ->
           emit_expr ~expected:want ~indent:(indent ^ "\t") signatures env arg)
           args signature.params));
      Printf.bprintf buffer "%s\tif !%s.OK() {\n%s\t\treturn teslrt.Reject[%s](%s.Status(), %s.Message())\n%s\t}\n"
        indent temporary indent (go_type (match expected with TCheck ty -> ty | ty -> ty))
        temporary temporary indent;
      (* Past the propagation guard the check cannot be a rejection, so unwrapping is
         total; `MustCheck` states that rather than ignoring a second return value. *)
      if name = "_" then
        Printf.bprintf buffer "%s\t_ = teslrt.MustCheck(%s)\n" indent temporary
      else begin
        Printf.bprintf buffer "%s\t%s := teslrt.MustCheck(%s)\n" indent
          (local_ident name) temporary;
        Printf.bprintf buffer "%s\t_ = %s\n" indent (local_ident name)
      end;
      go (if name = "_" then env else (name, inner) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    | ELet { name; value; body; loc; _ } ->
      let inferred = type_of_expr signatures env value in
      let ty = if inferred = TFailure then expected else inferred in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let emitted_value =
        emit_expr ~expected:ty ~indent:(indent ^ "\t") signatures env value in
      (* `let _ = expr` discards its value — it is written for the EFFECT.  `_ := expr`
         is not legal Go ("no new variables on left side of :="), so it becomes a plain
         discard. *)
      if name = "_" then
        Printf.bprintf buffer "%s\t_ = %s\n" indent emitted_value
      else begin
        Printf.bprintf buffer "%s\t%s := %s\n" indent (local_ident name) emitted_value;
        Printf.bprintf buffer "%s\t_ = %s\n" indent (local_ident name)
      end;
      go ((name, ty) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    | EIf { cond; then_; else_; loc } ->
      (* Only the condition is typed here: each branch is typed against the EXPECTED
         type as it is emitted, which is what lets an under-constrained constructor in
         a branch resolve. *)
      if type_of_expr signatures env cond <> TBool then
        unsupported loc "Go backend if condition must be Bool";
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%sif %s {\n" indent
        (strip_outer_parens (emit_expr ~indent signatures env cond));
      go env (indent ^ "\t") then_;
      Printf.bprintf buffer "%s} else {\n" indent;
      go env (indent ^ "\t") else_;
      Printf.bprintf buffer "%s}\n" indent
    | ECase { scrut; arms; loc } ->
      (* Checked against the EXPECTED type, arm by arm, for the same reason the plain
         tail below is: an arm is exactly where an under-constrained constructor sits.
         `Err "no"` cannot infer the `ok` half of `Result Int String` from its own
         argument — only the return type says what it is — and typing the `case` without
         the expectation rejected that shape outright. *)
      ignore (type_of_arg signatures env expected expr);
      Buffer.add_string buffer (line_directive loc);
      emit_case_statements ~indent signatures env buffer scrut
        (List.map (fun (arm : case_arm) ->
           arm.pattern, arm.guard,
           (fun arm_env body_indent -> go arm_env body_indent arm.body)) arms)
    (* A check whose TAIL is another check hands that check's result straight back: the
       delegate's status and message are this check's, and no unwrapping happens at all. *)
    | _ when (match check_application signatures expr, expected with
              | Some ({ result = TCheck inner; _ }, _), TCheck outer -> inner = outer
              | _ -> false) ->
      let signature, args = match check_application signatures expr with
        | Some pair -> pair
        | None -> assert false
      in
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      Printf.bprintf buffer "%sreturn %s(%s)\n" indent
        (qualified signature.sig_owner signature.go_name)
        (String.concat ", " (List.map2 (fun arg want ->
           emit_expr ~expected:want ~indent signatures env arg) args signature.params))
    | _ ->
      (* The tail is checked against the EXPECTED type so a bare nullary constructor
         of a generic ADT (`Nothing`) is instantiated by the return type. *)
      ignore (type_of_arg signatures env expected expr);
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      Printf.bprintf buffer "%sreturn %s\n" indent (emit_expr ~expected ~indent signatures env expr)
  in
  go env indent expr

let contains_go_code haystack needle =
  let length = String.length haystack and needle_length = String.length needle in
  let rec loop index in_string escaped in_comment =
    if index >= length then false
    else if in_comment then
      if haystack.[index] = '\n' then loop (index + 1) false false false
      else loop (index + 1) false false true
    else if in_string then
      if escaped then loop (index + 1) true false false
      else if haystack.[index] = '\\' then loop (index + 1) true true false
      else if haystack.[index] = '"' then loop (index + 1) false false false
      else loop (index + 1) true false false
    else if haystack.[index] = '"' then loop (index + 1) true false false
    else if haystack.[index] = '/' && index + 1 < length && haystack.[index + 1] = '/' then
      loop (index + 2) false false true
    else if index + needle_length <= length
         && String.sub haystack index needle_length = needle then true
    else loop (index + 1) false false false
  in
  needle_length = 0 || loop 0 false false false

(* gofmt sorts an import block, so it is emitted sorted — otherwise every multi-import
   file is reported unformatted. *)
let import_block paths =
  let paths = List.sort_uniq String.compare paths in
  match paths with
  | [] -> ""
  | [path] -> Printf.sprintf "\nimport %s\n" (go_quote path)
  | _ -> Printf.sprintf "\nimport (\n%s)\n"
      (String.concat "" (List.map (fun path -> "\t" ^ go_quote path ^ "\n") paths))

(* One ADT emits its tag enum, one flat payload struct, and the equality method
   every comparison site calls.  The struct is deliberately NOT Go-comparable
   whenever a payload is, so `==` cannot silently replace TeslEqual. *)
let adt_source info =
  let body = Buffer.create 512 in
  Buffer.add_char body '\n';
  Buffer.add_string body (line_directive info.adt_loc);
  let type_params =
    if info.adt_params = [] then ""
    else "[" ^ String.concat ", "
      (List.map (fun (_, go_param) -> go_param ^ " any") info.adt_params) ^ "]"
  in
  Printf.bprintf body "type %s int\n\nconst (\n" info.adt_tag_type;
  List.iteri (fun index variant ->
    if index = 0 then Printf.bprintf body "\t%s %s = iota\n" variant.var_tag info.adt_tag_type
    else Printf.bprintf body "\t%s\n" variant.var_tag) info.adt_variants;
  Buffer.add_string body ")\n\n";
  let fields = (adt_tag_field, info.adt_tag_type)
    :: List.concat_map (fun variant ->
         List.map (fun (name, field_ty) ->
           variant_field_go_name variant name, go_type field_ty) variant.var_fields)
         info.adt_variants in
  let width = List.fold_left (fun width (name, _) -> max width (String.length name)) 0 fields in
  Printf.bprintf body "type %s%s struct {\n" info.adt_go_name type_params;
  List.iter (fun (name, go_field_type) ->
    Printf.bprintf body "\t%s%s %s\n" name
      (String.make (width - String.length name) ' ') go_field_type) fields;
  Buffer.add_string body "}\n";
  let payload_variants = List.filter (fun variant -> variant.var_fields <> []) info.adt_variants in
  (* A generic ADT gets no `TeslEqual`: equality on it is rejected before emission,
     and an unused method would be a lint finding. *)
  if info.adt_params <> [] then Buffer.contents body
  else begin
  Buffer.add_char body '\n';
  Printf.bprintf body "func (teslLeft %s) TeslEqual(teslRight %s) bool {\n"
    info.adt_go_name info.adt_go_name;
  if payload_variants = [] then
    Printf.bprintf body "\treturn teslLeft.%s == teslRight.%s\n" adt_tag_field adt_tag_field
  else begin
    Printf.bprintf body "\tif teslLeft.%s != teslRight.%s {\n\t\treturn false\n\t}\n"
      adt_tag_field adt_tag_field;
    Printf.bprintf body "\tswitch teslLeft.%s {\n" adt_tag_field;
    List.iter (fun variant ->
      Printf.bprintf body "\tcase %s:\n" variant.var_tag;
      let parts = List.map (fun (name, field_ty) ->
        let field = variant_field_go_name variant name in
        equal_expr field_ty (Printf.sprintf "teslLeft.%s" field)
          (Printf.sprintf "teslRight.%s" field)) variant.var_fields in
      Printf.bprintf body "\t\treturn %s\n" (String.concat " && " parts)) payload_variants;
    (* The payload-free tags are listed too: equal tags with no payload are equal, and
       naming them keeps the switch verifiable by the `exhaustive` linter. *)
    let nullary_variants =
      List.filter (fun variant -> variant.var_fields = []) info.adt_variants in
    if nullary_variants <> [] then
      Printf.bprintf body "\tcase %s:\n\t\treturn true\n"
        (String.concat ", " (List.map (fun variant -> variant.var_tag) nullary_variants));
    Buffer.add_string body "\tdefault:\n\t\treturn true\n\t}\n"
  end;
  Buffer.add_string body "}\n";
  Buffer.contents body
  end

(* A codec becomes two ordinary Go functions per direction, mirroring what the Racket
   backend generates (`tesl-codec-encode-T`, `tesl-codec-decode-T-N`) — there is no macro
   layer to reproduce.  Differences that matter, both verified against Racket:

   - ENCODING goes through a sorted-key map rather than a struct with json tags, because
     Racket's `jsexpr->string` sorts object keys and response bytes are observable.
   - An INTEGER is rendered from its decimal digits and decoded from `json.Number`, since
     Tesl's Int is arbitrary precision and Go's default number handling is float64.

   Decode returns a `teslrt.Check`, so a `via` failure carries the check's own status and
   message (the 400 the client sees), while a missing or mistyped field is a decode
   failure whose text Racket hides behind "Invalid request payload" by default. *)
(* Codec entry points are EXPORTED: they are the boundary API — the server layer calls
   them, and a user who ejects Tesl calls them directly.  They would also read as unused
   in a module that only declares codecs, which the `unused` linter rightly rejects. *)
let codec_encode_name type_name = "Encode" ^ go_ident ~exported:true type_name ^ "JSON"
let codec_decode_name type_name = "Decode" ^ go_ident ~exported:true type_name ^ "JSON"
let codec_alt_name type_name index =
  Printf.sprintf "teslDecode%sAlt%d" (go_ident ~exported:true type_name) index

(* The primitive codecs, by the name written in `with_codec`.  Anything else is a TYPE
   name and resolves to that type's own codec. *)
let primitive_codec = function
  | "stringCodec" -> Some `String
  | "intCodec" -> Some `Int
  | "boolCodec" -> Some `Bool
  | "floatCodec" -> Some `Float
  | _ -> None

(* The wire shape of a response value, mirroring `runtime-value->jsexpr` in dsl/types.rkt:
   a type with its own codec encodes through it; a record without one becomes an object of
   its fields; an ADT without one becomes a TAGGED object — `{"tag":"Nothing"}`, or
   `{"tag":"Something","fields":{…}}` when the variant carries payload.  That is why a
   handler returning `Maybe Task` works without a codec for `Maybe`: the tagged shape is
   the fallback, not an error.  A newtype unwraps, matching Racket.

   Each encoder is hoisted into a named function, so the call site stays a plain call and
   the same type is encoded one way everywhere. *)
let rec value_encoder ty =
  let encoded_field operand field_ty =
    Printf.sprintf "%s(%s)" (value_encoder field_ty) operand in
  match ty with
  | TInt | TString | TBool | TFloat | TUnit ->
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:"teslValue"
  | TNewtype info ->
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(encoded_field "teslValue.Value" info.base)
  | TRecord info when List.mem info.rec_tesl_name !current_codec_types ->
    codec_encode_name info.rec_tesl_name
  | TAdt (info, _) when List.mem info.adt_tesl_name !current_codec_types ->
    codec_encode_name info.adt_tesl_name
  | TRecord info ->
    let fields = List.map (fun (name, field_ty) ->
      Printf.sprintf "\t\t%S: %s," name
        (encoded_field ("teslValue." ^ record_field_go_name name) field_ty))
      info.rec_fields in
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(Printf.sprintf "map[string]any{\n%s\n\t}" (String.concat "\n" fields))
  | TAdt (info, args) ->
    let arms = List.map (fun variant ->
      let fields = variant_field_types info args variant in
      let payload = match fields with
        | [] -> Printf.sprintf "map[string]any{\"tag\": %S}" variant.var_ctor
        | _ ->
          let entries = List.map (fun (name, field_ty) ->
            Printf.sprintf "\t\t\t\t%S: %s," name
              (encoded_field ("teslValue." ^ variant_field_go_name variant name) field_ty))
            fields in
          Printf.sprintf
            "map[string]any{\"tag\": %S, \"fields\": map[string]any{\n%s\n\t\t\t}}"
            variant.var_ctor (String.concat "\n" entries)
      in
      Printf.sprintf "\t\tcase %s:\n\t\t\treturn %s"
        (qualified info.adt_owner variant.var_tag) payload) info.adt_variants in
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(Printf.sprintf
        "func() any {\n\t\tswitch teslValue.%s {\n%s\n\t\t}\n\t\tpanic(\"unreachable: checker guarantees case exhaustiveness\")\n\t}()"
        adt_tag_field (String.concat "\n" arms))
  | TList element ->
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(Printf.sprintf
        "func() any {\n\t\tteslOut := make([]any, len(teslValue))\n\t\tfor teslAt, teslItem := range teslValue {\n\t\t\tteslOut[teslAt] = %s(teslItem)\n\t\t}\n\t\treturn teslOut\n\t}()"
        (value_encoder element))
  | TDict _ | TSet _ | TParam _ | TFunc _ | TJson | TCheck _ | TFailure ->
    invalid_arg "Go response encoding for this type is rejected before emission"

(* ── HTTP: `api` routes and the `server` that binds them ──────────────────────
   An `api` declares endpoints; a `server` binds handler functions to them POSITIONALLY in
   declaration order (the endpoint's own `name` is a parser-assigned placeholder, and the
   syntax used to carry a name-keyed-looking prefix that was always matched by position).
   Both become ordinary Go values, so someone who sheds Tesl can read the routing table,
   call a handler directly, or mount the server on any net/http mux. *)
let http_method_name = function
  | GET -> "GET" | POST -> "POST" | PUT -> "PUT"
  | DELETE -> "DELETE" | PATCH -> "PATCH" | SSE -> "SSE"

let module_source ?(imported_packages=[]) ?(unreachable=[]) ?(codecs=[]) ?(apis=[])
    ?(servers=[]) ?(capturers=[]) module_path package signatures types
    (funcs : func_decl list) =
  Hashtbl.reset pending_helpers;
  Hashtbl.reset helper_names;
  Hashtbl.reset module_helpers;
  let body = Buffer.create 1024 in
  (* ONLY THE DECLARING PACKAGE EMITS A DECLARATION.  An imported type is present in
     these tables so it can be referenced and its fields read, but emitting it here too
     would produce a second, incompatible Go type with the same Tesl name. *)
  let declared_here owner = owner = package in
  Hashtbl.to_seq_values types.newtypes
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.tesl_name right.tesl_name)
  |> List.filter (fun info -> declared_here info.owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.loc);
    if info.secret then begin
      (* A SECRET newtype carries a redacting payload, and the type itself gets `String()` so
         that printing the newtype — not just its field — redacts.  Reaching the plaintext is
         `.Value.Reveal()`, spelled to be greppable. *)
      Printf.bprintf body "type %s struct {\n\tValue teslrt.SecretString\n}\n" info.go_name;
      Printf.bprintf body
        "\nfunc (teslSecret %s) String() string { return teslrt.SecretRedaction }\n"
        info.go_name
    end else
      Printf.bprintf body "type %s struct {\n\tValue %s\n}\n"
        info.go_name (go_type info.base));
  Hashtbl.to_seq_values types.records
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.rec_tesl_name right.rec_tesl_name)
  |> List.filter (fun info -> declared_here info.rec_owner)
  |> List.iter (fun info ->
    (* gofmt aligns a struct's field types in one column; emit that alignment
       directly so the corpus stays gofmt-clean. *)
    let width = List.fold_left (fun width (name, _) ->
      max width (String.length (record_field_go_name name))) 0 info.rec_fields in
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.rec_loc);
    Printf.bprintf body "type %s struct {\n" info.rec_go_name;
    List.iter (fun (name, field_ty) ->
      let field = record_field_go_name name in
      Printf.bprintf body "\t%s%s %s\n" field
        (String.make (width - String.length field) ' ') (go_type field_ty))
      info.rec_fields;
    Buffer.add_string body "}\n");
  Hashtbl.to_seq_values types.adts
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.adt_tesl_name right.adt_tesl_name)
  |> List.iter (fun info ->
    if not info.adt_builtin && declared_here info.adt_owner then
      Buffer.add_string body (adt_source info));
  (* The job store for a queue.  `maxAttempts` is baked in because the retry rule belongs to
     the queue rather than to any call site; the lowered form supplies it (default 1, matching
     "no retry" for a queue that declares none). *)
  Hashtbl.to_seq_values types.queues
  |> List.of_seq
  |> List.sort_uniq (fun left right -> String.compare left.qu_tesl_name right.qu_tesl_name)
  |> List.filter (fun info -> info.qu_owner = package)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.qu_loc);
    Printf.bprintf body "var %s = teslrt.NewQueue(%s, %d)\n"
      info.qu_go_var (go_quote info.qu_tesl_name) info.qu_max_attempts);
  (* The store for a `backend: Memory` entity.  One variable per entity, initialised at
     package level: an entity belongs to exactly one database, and the table itself is
     what carries the lock, so nothing has to be threaded through call sites. *)
  Hashtbl.to_seq_values types.entities
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.ent_tesl_name right.ent_tesl_name)
  |> List.filter (fun info -> declared_here info.ent_owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.ent_loc);
    Printf.bprintf body "var %s = teslrt.NewTable[%s]()\n"
      info.ent_table_var info.ent_row.rec_go_name);
  List.iter (fun (fd : func_decl) ->
    (* `establish` returns a detached proof, which erases — so the function body computes
       nothing observable and the emitted function returns the zero-size proof value.  It
       is still emitted (rather than dropped) because callers name it. *)
    (* An `auth` function is a check over the request: it returns `ok value ::: Proof` or
       `fail 401 …`, so it emits exactly like a `check`. *)
    (* A `worker` / `deadWorker` is an ordinary function of the job: its `FromQueue` proof
       annotation erases like every other proof, and the queue runtime is what calls it. *)
    if fd.kind <> FnKind && fd.kind <> CheckKind && fd.kind <> EstablishKind
       && fd.kind <> HandlerKind && fd.kind <> AuthKind
       && fd.kind <> WorkerKind && fd.kind <> DeadWorkerKind then
      unsupported fd.loc
        "Go backend supports `fn`, `check`, `auth`, `establish`, `handler`, `worker` and \
         `deadWorker` declarations only";
    (* A capability is a COMPILE-TIME grant: the checker verifies every call against the
       declared set and forces it to propagate to callers, so nothing about it survives to
       run time.  `cookieCap` is the exception in shape only — it says this function may
       write to the response, so it receives the request scope.  That marker is the
       `requires` clause itself; no call-graph analysis is needed. *)
    let needs_scope = List.mem "cookieCap" fd.capabilities in
    (* No capability is checked against a list any more.  A capability is a COMPILE-TIME
       grant with no runtime form, and a capability naming a subsystem this backend does
       not implement cannot be exercised anyway — its functions are what fail closed, at
       the import.  `cookieCap` is the one exception, handled above, and only because it
       says "this function may write to the response". *)
    ignore fd.capabilities;
    let signature = Hashtbl.find signatures fd.name in
    let params = List.map2 (fun (binding : binding) ty -> binding.name, ty)
      fd.params signature.params in
    let result = signature.result in
    let env = params in
    (* An `establish` body is a proof TERM, not a value expression — it is never typed or
       emitted, so it is not checked against the result type either.  When the result is a
       CONTAINER of proofs (`Maybe (Fact P)`) the body IS emitted, and then it is checked
       like any other. *)
    if fd.kind <> EstablishKind || result <> TUnit then begin
      let body_ty = type_of_arg signatures env result fd.body in
      if body_ty <> result && body_ty <> TFailure then
        unsupported fd.loc "Go backend function result type mismatch"
    end;
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive fd.loc);
    (* A function that may write to the response takes the request scope as its FIRST
       parameter.  Nothing else gains one, so ordinary functions keep plain signatures. *)
    let scope_parameter =
      if needs_scope then [ "teslScope *teslrt.RequestScope" ] else [] in
    Printf.bprintf body "func %s(%s) %s {\n"
      signature.go_name
      (String.concat ", "
         (scope_parameter
          @ List.map (fun (name, ty) -> local_ident name ^ " " ^ go_type ty) params))
      (go_type result);
    (* Emit the body once assuming it may loop.  If no self tail call actually turned
       into a `continue`, re-emit it flat: an unused label is a Go compile error, and
       a function that never tail-calls itself should read as plain Go. *)
    (* An `establish` body constructs a proof TERM (`Named "http" port`), which has no
       runtime content — so the emitted function returns the zero-size proof value and the
       body is not emitted at all.  Its parameters stay, since callers pass them.
       EXCEPT when the result is not the bare proof: `-> Maybe (Fact (ValidPort port))`
       answers "can this be established?", and the caller CASES on that answer, so the
       control flow is observable and the body must be emitted (with the proof inside it
       erased as usual).  Skipping it there emitted `return struct{}{}` for a Maybe. *)
    if fd.kind = EstablishKind && result = TUnit then begin
      List.iter (fun (name, _) ->
        Printf.bprintf body "\t_ = %s\n" (local_ident name)) params;
      Printf.bprintf body "\treturn struct{}{}\n}\n"
    end else begin
    let self = fd.name, List.map (fun (name, _) -> local_ident name) params in
    current_handler_body := (fd.kind = HandlerKind);
    let looped = Buffer.create 256 in
    emit_tail ~self looped signatures env result "\t\t" fd.body;
    if contains_go_code (Buffer.contents looped) ("continue " ^ loop_label) then begin
      Printf.bprintf body "%s:\n\tfor {\n" loop_label;
      Buffer.add_buffer body looped;
      Buffer.add_string body "\t}\n"
    end else
      emit_tail body signatures env result "\t" fd.body;
    current_handler_body := false;
    Buffer.add_string body "}\n" end) funcs;
  (* ── Codecs ─────────────────────────────────────────────────────────────── *)
  (* Which types have their own codec, for the response encoder above. *)
  current_codec_types :=
    List.map (fun (codec : codec_form) -> codec.type_name) codecs;
  List.iter (fun (codec : codec_form) ->
    let type_name = codec.type_name in
    let go_ty =
      match Hashtbl.find_opt types.records type_name with
      | Some info -> TRecord info
      | None ->
        (match Hashtbl.find_opt types.adts type_name with
         | Some info -> TAdt (info, [])
         | None ->
           (match Hashtbl.find_opt types.newtypes type_name with
            | Some info -> TNewtype info
            | None ->
              unsupported codec.loc "Go backend codec `%s` needs a record or ADT type"
                type_name))
    in
    let record_info = match go_ty with TRecord info -> Some info | _ -> None in
    let field_go name = record_field_go_name name in
    let field_type name =
      match record_info with
      | Some info ->
        (match List.assoc_opt name info.rec_fields with
         | Some ty -> ty
         | None ->
           unsupported codec.loc "Go backend codec `%s` has no field `%s`" type_name name)
      | None -> unsupported codec.loc "Go backend codec `%s` needs a record type" type_name
    in
    (* Encode: a record becomes a sorted-key map; an `adtJson` type becomes the
       constructor name as a JSON string. *)
    (match codec.to_json with
     | ToJsonForbidden -> ()
     | ToJsonAdt ->
       (match go_ty with
        | TAdt (info, _) ->
          Printf.bprintf body "\nfunc %s(teslValue %s) any {\n\tswitch teslValue.%s {\n"
            (codec_encode_name type_name) (go_type go_ty) adt_tag_field;
          List.iter (fun variant ->
            if variant.var_fields <> [] then unsupported codec.loc
              "Go backend `adtJson` needs constructors without payloads (`%s`)" variant.var_ctor;
            Printf.bprintf body "\tcase %s:\n\t\treturn %S\n"
              (qualified info.adt_owner variant.var_tag) variant.var_ctor) info.adt_variants;
          Printf.bprintf body "\t}\n\tpanic(\"unreachable: checker guarantees case exhaustiveness\")\n}\n"
        | _ -> unsupported codec.loc "Go backend `adtJson` needs an ADT type")
     | ToJsonFields entries ->
       Printf.bprintf body "\nfunc %s(teslValue %s) any {\n\treturn map[string]any{\n"
         (codec_encode_name type_name) (go_type go_ty);
       (* gofmt aligns the values in a map literal, so the padding is computed here. *)
       let width = List.fold_left (fun width (entry : codec_encode_entry) ->
         max width (String.length entry.json_key + 3)) 0 entries in
       List.iter (fun (entry : codec_encode_entry) ->
         let value = Printf.sprintf "teslValue.%s" (field_go entry.field_name) in
         let encoded = match primitive_codec entry.codec with
           | Some _ -> value
           | None -> Printf.sprintf "%s(%s)" (codec_encode_name entry.codec) value
         in
         let key = Printf.sprintf "%S:" entry.json_key in
         Printf.bprintf body "\t\t%s%s %s,\n" key
           (String.make (width - String.length key) ' ') encoded) entries;
       Buffer.add_string body "\t}\n}\n");
    (* Decode: each alternative is COMPLETE and they are tried in order, first success
       winning — the same rule the Racket decoder list follows. *)
    (match codec.from_json with
     | FromJsonForbidden -> ()
     | FromJsonAdt ->
       (match go_ty with
        | TAdt (info, _) ->
          Printf.bprintf body
            "\nfunc %s(teslJSON any) teslrt.Check[%s] {\n\tteslName, teslErr := teslrt.DecodeStringValue(teslJSON)\n\tif teslErr != nil {\n\t\treturn teslrt.Reject[%s](400, teslErr.Error())\n\t}\n\tswitch teslName {\n"
            (codec_decode_name type_name) (go_type go_ty) (go_type go_ty);
          List.iter (fun variant ->
            Printf.bprintf body "\tcase %S:\n\t\treturn teslrt.Accept(%s{%s: %s})\n"
              variant.var_ctor (go_type go_ty) adt_tag_field
              (qualified info.adt_owner variant.var_tag)) info.adt_variants;
          Printf.bprintf body
            "\t}\n\treturn teslrt.Reject[%s](400, \"expected one of the %s constructors, got \"+teslName)\n}\n"
            (go_type go_ty) type_name
        | _ -> unsupported codec.loc "Go backend `adtJson` needs an ADT type")
     | FromJsonAlts alternatives ->
       let go_type_name = go_type go_ty in
       List.iteri (fun index (alternative : codec_decode_alt) ->
         Printf.bprintf body "\nfunc %s(teslJSON any) teslrt.Check[%s] {\n"
           (codec_alt_name type_name index) go_type_name;
         let assignments = ref [] in
         List.iter (fun entry ->
           match entry with
           | DecodeField { field_name; json_key; codec = field_codec; via; _ } ->
             let suffix = go_ident ~exported:true field_name in
             let binder = "teslField" ^ suffix in
             (match primitive_codec field_codec with
              | Some kind ->
                let decoder = match kind with
                  | `String -> "DecodeStringField" | `Int -> "DecodeIntField"
                  | `Bool -> "DecodeBoolField" | `Float -> "DecodeFloatField"
                in
                Printf.bprintf body
                  "\t%s, teslErr%s := teslrt.%s(teslJSON, %S)\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n"
                  binder suffix decoder json_key suffix go_type_name suffix
              | None ->
                (* A nested codec decodes the field's own JSON value. *)
                Printf.bprintf body
                  "\tteslRaw%s, teslErr%s := teslrt.JSONFieldValue(teslJSON, %S)\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n\tteslNested%s := %s(teslRaw%s)\n\tif !teslNested%s.OK() {\n\t\treturn teslrt.Reject[%s](teslNested%s.Status(), teslNested%s.Message())\n\t}\n\t%s, _ := teslNested%s.Value()\n"
                  suffix suffix json_key suffix go_type_name suffix
                  suffix (codec_decode_name field_codec) suffix
                  suffix go_type_name suffix suffix
                  binder suffix);
             (* `via` CHAINS: each checker runs on the value the previous one accepted. *)
             List.iter (fun checker ->
               let signature = match Hashtbl.find_opt signatures checker with
                 | Some signature -> signature
                 | None -> unsupported codec.loc
                   "Go backend codec `%s` cannot resolve check `%s`" type_name checker
               in
               Printf.bprintf body
                 "\tteslChecked%s := %s(%s)\n\tif !teslChecked%s.OK() {\n\t\treturn teslrt.Reject[%s](teslChecked%s.Status(), teslChecked%s.Message())\n\t}\n\t%s, _ = teslChecked%s.Value()\n"
                 suffix (qualified signature.sig_owner signature.go_name) binder
                 suffix go_type_name suffix suffix binder suffix) via;
             (* Whether the binder holds the field's own type or its BASE value: a primitive
                codec answers a `string`/`Int`, so a newtype field still needs its constructor;
                a nested codec already answers the field's type. *)
             let base_value = primitive_codec field_codec <> None in
             assignments := (field_name, binder, base_value) :: !assignments
           | DecodeDefault { field_name; default_lit; _ } ->
             let binder = Printf.sprintf "teslField%s" (go_ident ~exported:true field_name) in
             let rendered = match default_lit, field_type field_name with
               | LInt n, _ -> Printf.sprintf "teslrt.FromInt64(%d)" n
               | LBool b, _ -> if b then "true" else "false"
               | LString text, _ -> Printf.sprintf "%S" text
               | LFloat f, _ -> emit_float_literal f
               | _ -> unsupported codec.loc
                 "Go backend codec `%s` default for `%s` is not a literal" type_name field_name
             in
             Printf.bprintf body "\t%s := %s\n" binder rendered;
             assignments := (field_name, binder, true) :: !assignments
           | DecodeCrossCheck _ -> ()) alternative;
         (* The record is built before any cross-check, which takes the whole value. *)
         let assignments = List.rev !assignments in
         (* A field whose TYPE is a newtype decoded its BASE value — a primitive codec answers
            a `string`/`Int`, never the wrapper — so the constructor is applied here, at
            construction, and NOT before.  That ordering is the fix a Racket-side soundness bug
            forced (`compiler/test/test_secret_surface.ml` ratchets it): wrapping first meant a
            `via` checker declared `(text: String)` was handed the wrapped secret, so an
            arbitrary checker could reach the plaintext under a signature promising it never saw
            more than a String — and echo it into a client-facing 400.  `via` therefore runs on
            the raw value above, and only a successful check's value is wrapped. *)
         let wrapped field binder =
           match field_type field with
           | TNewtype info when info.secret ->
             Printf.sprintf "%s{Value: teslrt.MakeSecret(%s)}" (go_type (TNewtype info)) binder
           | TNewtype info -> Printf.sprintf "%s{Value: %s}" (go_type (TNewtype info)) binder
           | _ -> binder
         in
         Printf.bprintf body "\tteslDecoded := %s{" go_type_name;
         Buffer.add_string body
           (String.concat ", " (List.map (fun (field, binder, base_value) ->
              Printf.sprintf "%s: %s" (field_go field)
                (if base_value then wrapped field binder else binder)) assignments));
         Buffer.add_string body "}\n";
         List.iter (fun entry ->
           match entry with
           | DecodeCrossCheck { checker; _ } ->
             let signature = match Hashtbl.find_opt signatures checker with
               | Some signature -> signature
               | None -> unsupported codec.loc
                 "Go backend codec `%s` cannot resolve check `%s`" type_name checker
             in
             (* The cross-check receives the decoded FIELDS in declaration order — not the
                record — matching the call `emit_racket` generates.  Its result is used
                only for pass/fail: the record is built from the fields either way. *)
             Printf.bprintf body
               "\tteslCross := %s(%s)\n\tif !teslCross.OK() {\n\t\treturn teslrt.Reject[%s](teslCross.Status(), teslCross.Message())\n\t}\n"
               (qualified signature.sig_owner signature.go_name)
               (String.concat ", " (List.map (fun (_, binder, _) -> binder) assignments))
               go_type_name
           | _ -> ()) alternative;
         Buffer.add_string body "\treturn teslrt.Accept(teslDecoded)\n}\n") alternatives;
       (* The entry point tries each alternative in order and reports the LAST failure
          when none matches, matching first-success semantics. *)
       Printf.bprintf body "\nfunc %s(teslJSON any) teslrt.Check[%s] {\n"
         (codec_decode_name type_name) go_type_name;
       (match alternatives with
        | [] ->
          Printf.bprintf body "\treturn teslrt.Reject[%s](400, \"no decode alternative\")\n"
            go_type_name
        | _ ->
          (* Alternative order follows Racket's registry loop exactly: a SHAPE mismatch
             moves on, a VALIDATION failure is remembered (the FIRST one wins) and the
             search continues, since a later alternative may still succeed.  Reporting
             the last failure instead would replace a real 400 from the first
             alternative's check with the last alternative's "missing field" complaint. *)
          Printf.bprintf body "\tvar teslFirstFailure teslrt.Check[%s]\n\tteslHaveFailure := false\n"
            go_type_name;
          List.iteri (fun index _ ->
            Printf.bprintf body
              "\tteslResult%d := %s(teslJSON)\n\tif teslResult%d.OK() {\n\t\treturn teslResult%d\n\t}\n\tif !teslResult%d.IsShapeMismatch() && !teslHaveFailure {\n\t\tteslFirstFailure = teslResult%d\n\t\tteslHaveFailure = true\n\t}\n"
              index (codec_alt_name type_name index) index index index index) alternatives;
          Printf.bprintf body
            "\tif teslHaveFailure {\n\t\treturn teslFirstFailure\n\t}\n\treturn teslrt.Reject[%s](400, \"no decode alternative matched\")\n"
            go_type_name);
       Buffer.add_string body "}\n")) codecs;
  (* ── Derived decoders ───────────────────────────────────────────────────────
     A request-body record needs no `codec` block: Racket decodes it generically from the
     record spec at run time (`dsl/types.rkt jsexpr->typed-value`), so the type alone is the
     contract. Go has no runtime type registry, so the equivalent decoder is EMITTED — and it
     has to be, because the dispatcher above already calls `Decode<T>JSON` for every body
     type. Without this the emitted package referenced a function nobody wrote: a fail-OPEN
     that produced uncompilable Go rather than a refusal.

     The rules are the generic decoder's, not a new dialect: the object's keys must be exactly
     the record's fields (an extra key is a 400, because silently ignoring unknown keys is how
     a typo'd field name becomes a silent default), a newtype decodes its base and is then
     wrapped, and a nested record recurses. A shape the generic decoder handles but this does
     not yet — an ADT's `{tag, fields}`, Dict, Set, Money — fails closed at emit. *)
  let derived_decoders = ref [] in
  let rec derive_decoder loc ty =
    match ty with
    | TRecord info when info.rec_owner = package
                        && not (List.mem info.rec_tesl_name !current_codec_types) ->
      if not (List.mem info.rec_tesl_name !derived_decoders) then begin
        derived_decoders := info.rec_tesl_name :: !derived_decoders;
        (* Fields first: a nested record's decoder is emitted before the one that calls it,
           which also keeps a cycle from recursing forever (the name is claimed above). *)
        List.iter (fun (_, field_ty) -> derive_decoder loc field_ty) info.rec_fields;
        let go_ty = go_type ty in
        Printf.bprintf body
          "\n// %s is the DERIVED decoder for a record with no `codec` block: the type is the\n\
           // whole contract, exactly as it is on the Racket runtime's generic decode.\n\
           func %s(teslJSON any) teslrt.Check[%s] {\n"
          (codec_decode_name info.rec_tesl_name) (codec_decode_name info.rec_tesl_name) go_ty;
        Printf.bprintf body "\tteslFields, teslShapeErr := teslrt.DecodeObjectShape(teslJSON, %s, []string{%s})\n\tif teslShapeErr != nil {\n\t\treturn teslrt.RejectShape[%s](teslShapeErr.Error())\n\t}\n"
          (go_quote info.rec_tesl_name)
          (String.concat ", " (List.map (fun (name, _) -> go_quote name) info.rec_fields))
          go_ty;
        List.iter (fun (name, field_ty) ->
          let suffix = go_ident ~exported:true name in
          (* Every field decoder is a `func(any) (T, error)`, so a list composes over the
             element's own decoder without the emitter writing the loop. *)
          let rec value_decoder ty = match ty with
            | TString -> "teslrt.DecodeStringValue"
            | TInt -> "teslrt.DecodeIntValue"
            | TBool -> "teslrt.DecodeBoolValue"
            | TFloat -> "teslrt.DecodeFloatValue"
            | TNewtype info ->
              let inner = value_decoder info.base in
              let wrap = if info.secret then "teslrt.MakeSecret(teslBase)" else "teslBase" in
              Printf.sprintf
                "func(teslRaw any) (%s, error) {\n\t\tteslBase, teslErr := %s(teslRaw)\n\t\tif teslErr != nil {\n\t\t\treturn %s{}, teslErr\n\t\t}\n\t\treturn %s{Value: %s}, nil\n\t}"
                (go_type ty) inner (go_type ty) (go_type ty) wrap
            | TList element ->
              Printf.sprintf
                "func(teslRaw any) ([]%s, error) {\n\t\treturn teslrt.DecodeListValue(teslRaw, %s)\n\t}"
                (go_type element) (value_decoder element)
            | TRecord nested when nested.rec_owner = package
                                  || List.mem nested.rec_tesl_name !current_codec_types ->
              (* A nested record decodes through its own decoder — derived or hand-written —
                 and its `Check` becomes an `error` here so one field shape covers both. *)
              Printf.sprintf
                "func(teslRaw any) (%s, error) {\n\t\tteslNested := %s(teslRaw)\n\t\tif !teslNested.OK() {\n\t\t\treturn %s{}, errors.New(teslNested.Message())\n\t\t}\n\t\tteslValue, _ := teslNested.Value()\n\t\treturn teslValue, nil\n\t}"
                (go_type ty) (codec_decode_name nested.rec_tesl_name) (go_type ty)
            | _ -> unsupported loc
              "Go backend cannot derive a decoder for field `%s.%s`; give the type a `codec`"
              info.rec_tesl_name name
          in
          Printf.bprintf body
            "\tteslField%s, teslErr%s := %s(teslFields[%s])\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n"
            suffix suffix (value_decoder field_ty) (go_quote name) suffix go_ty suffix)
          info.rec_fields;
        Printf.bprintf body "\treturn teslrt.Accept(%s{%s})\n}\n" go_ty
          (String.concat ", " (List.map (fun (name, _) ->
             Printf.sprintf "%s: teslField%s" (record_field_go_name name)
               (go_ident ~exported:true name)) info.rec_fields))
      end
    | _ -> ()
  in
  List.iter (fun (api : api_form) ->
    List.iter (fun (endpoint : api_endpoint) ->
      match endpoint.kind with
      | Http { body = Some (binding : binding); _ } ->
        derive_decoder endpoint.loc (type_of_type_expr types binding.type_expr)
      | _ -> ()) api.endpoints) apis;
  (* ── HTTP servers ───────────────────────────────────────────────────────── *)
  List.iter (fun (server : server_form) ->
    let api = match List.find_opt (fun (a : api_form) -> a.name = server.api_name) apis with
      | Some api -> api
      | None -> unsupported server.loc "Go backend cannot resolve api `%s`" server.api_name
    in
    (* SSE endpoints are a different transport and are not bound here. *)
    let endpoints = List.filter (fun (ep : api_endpoint) ->
      match ep.kind with Http _ -> true | Sse _ -> false) api.endpoints in
    if List.length endpoints <> List.length server.handlers then
      unsupported server.loc
        "Go backend needs one handler per endpoint in `%s` (%d endpoint(s), %d handler(s))"
        server.api_name (List.length endpoints) (List.length server.handlers);
    let bound = List.combine endpoints server.handlers in
    List.iter (fun ((ep : api_endpoint), _) ->
      ignore ep) bound;
    let server_name = go_ident ~exported:true server.name in
    Printf.bprintf body "\nvar %s = teslrt.Server{\n\tRoutes: []teslrt.Route{\n" server_name;
    List.iter (fun ((ep : api_endpoint), handler) ->
      Printf.bprintf body "\t\t{Method: %S, Path: %S, Endpoint: %S},\n"
        (http_method_name ep.method_) ep.path handler) bound;
    Buffer.add_string body "\t},\n\tHandlers: map[string]teslrt.HandlerFunc{\n";
    List.iter (fun ((endpoint : api_endpoint), handler) ->
      let endpoint_loc = endpoint.loc in
      let endpoint_path = endpoint.path in
      let endpoint_captures = endpoint.captures in
      let endpoint_auth = endpoint.auth in
      let endpoint_body = ep_body endpoint in
      let signature = match Hashtbl.find_opt signatures handler with
        | Some signature -> signature
        | None -> unsupported server.loc "Go backend cannot resolve handler `%s`" handler
      in
      (* The response goes through the result type's own codec, so the body bytes are the
         ones the codec layer already agrees with Racket on. *)
      let encoder = match signature.result with
        | TDict _ | TSet _ | TParam _ | TCheck _ | TFailure ->
          unsupported server.loc
            "Go backend cannot encode handler `%s`'s response type" handler
        | result -> value_encoder result
      in
      Printf.bprintf body
        "\t\t%S: func(teslScope *teslrt.RequestScope, teslRequest *http.Request) teslrt.Response {\n\t\t\t_ = teslScope\n"
        handler;
      (* Arguments are assembled in the handler's own parameter order: captures first (in
         path order), then the decoded body, matching how the endpoint declares them. *)
      let arguments = ref [] in
      (* Auth runs FIRST, before captures and the body: a request that is not authenticated
         is rejected before anything else about it is examined.  Its result carries the
         proven value the handler's proof-annotated parameter requires; the proof itself
         erases, so what the handler receives is the value. *)
      (* The request body is read ONCE, before anything examines the request: an `auth` may
         verify a MAC over the RAW bytes (every webhook scheme does), and the decoder needs the
         same bytes — `teslRequest.Body` is a stream that can only be read once, so reading it
         twice gave the auth an empty body and made it verify a tag over "". Racket reads
         `request-post-data/raw` once for exactly this reason. *)
      let reads_body = endpoint_auth <> None || endpoint_body <> None in
      if reads_body then
        Buffer.add_string body
          (if endpoint_auth <> None then
             "\t\t\tteslBodyBytes, teslBodyErr := io.ReadAll(teslRequest.Body)\n\t\t\tif teslBodyErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Missing JSON payload\")\n\t\t\t}\n\t\t\tteslBodyText := string(teslBodyBytes)\n"
           else
             "\t\t\tteslBodyBytes, teslBodyErr := io.ReadAll(teslRequest.Body)\n\t\t\tif teslBodyErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Missing JSON payload\")\n\t\t\t}\n");
      (match endpoint_auth with
       | None -> ()
       | Some (auth : api_auth) ->
         let signature = match Hashtbl.find_opt signatures auth.via_fn with
           | Some signature -> signature
           | None -> unsupported endpoint_loc
             "Go backend cannot resolve auth function `%s`" auth.via_fn
         in
         let binder = local_ident auth.binding.name in
         Printf.bprintf body
           "\t\t\tteslAuth := %s(teslrt.NewHttpRequest(teslRequest, teslBodyText))\n\t\t\tif !teslAuth.OK() {\n\t\t\t\treturn teslrt.Fail(teslAuth.Status(), teslAuth.Message())\n\t\t\t}\n\t\t\t%s, _ := teslAuth.Value()\n"
           (qualified signature.sig_owner signature.go_name) binder;
         arguments := !arguments @ [binder]);
      List.iter (fun (capture : api_capture) ->
        let name = capture.binding.name in
        let suffix = go_ident ~exported:true name in
        (* The capturer names how the segment is parsed and, optionally, a CHECK that
           mints a proof on it — the same "prove before the body runs" rule auth follows,
           applied to a path segment. *)
        let parser, checker = match capture.via_fn with
          | "" -> (match capture.inline_codec with Some c -> c | None -> "stringCodec"),
                  capture.inline_check
          | via ->
            (match List.find_opt (fun (c : capture_form) -> c.name = via) capturers with
             | Some form -> form.parser, form.checker
             | None -> unsupported endpoint_loc
               "Go backend cannot resolve capturer `%s`" via)
        in
        if parser <> "stringCodec" then unsupported endpoint_loc
          "Go backend supports `stringCodec` path captures only for now (`%s`)" parser;
        (match type_of_type_expr types capture.binding.type_expr with
         | TString -> ()
         | _ -> unsupported endpoint_loc
           "Go backend supports String path captures only for now");
        Printf.bprintf body
          "\t\t\t%s, teslFound%s := teslrt.PathParam(%S, teslRequest.URL.Path, %S)\n\t\t\tif !teslFound%s {\n\t\t\t\treturn teslrt.Fail(404, \"not found\")\n\t\t\t}\n"
          (local_ident name) suffix endpoint_path name suffix;
        (match checker with
         | None -> ()
         | Some check_fn ->
           let signature = match Hashtbl.find_opt signatures check_fn with
             | Some signature -> signature
             | None -> unsupported endpoint_loc
               "Go backend cannot resolve capture check `%s`" check_fn
           in
           Printf.bprintf body
             "\t\t\tteslCaptured%s := %s(%s)\n\t\t\tif !teslCaptured%s.OK() {\n\t\t\t\treturn teslrt.Fail(teslCaptured%s.Status(), teslCaptured%s.Message())\n\t\t\t}\n\t\t\t%s, _ = teslCaptured%s.Value()\n"
             suffix (qualified signature.sig_owner signature.go_name) (local_ident name)
             suffix suffix suffix (local_ident name) suffix);
        arguments := !arguments @ [local_ident name]) endpoint_captures;
      (match endpoint_body with
       | None -> if not reads_body then Buffer.add_string body "\t\t\t_ = teslRequest\n"
       | Some (binding : binding) ->
         let decoder = match type_of_type_expr types binding.type_expr with
           | TRecord info -> codec_decode_name info.rec_tesl_name
           | TAdt (info, _) -> codec_decode_name info.adt_tesl_name
           | _ -> unsupported endpoint_loc
             "Go backend request body needs a type with a codec"
         in
         (* The two failure strings are the ones the Racket server sends, so a client sees
            the same 400 either way. *)
         Printf.bprintf body
           "\t\t\tteslParsed, teslParseErr := teslrt.ParseJSON(teslBodyBytes)\n\t\t\tif teslParseErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Malformed JSON payload\")\n\t\t\t}\n\t\t\tteslDecoded := %s(teslParsed)\n\t\t\tif !teslDecoded.OK() {\n\t\t\t\treturn teslrt.Fail(teslDecoded.Status(), teslDecoded.Message())\n\t\t\t}\n\t\t\tteslBody, _ := teslDecoded.Value()\n"
           decoder;
         arguments := !arguments @ ["teslBody"]);
      (* A handler that may write cookies receives the scope the dispatcher created. *)
      let call_arguments =
        if signature.sig_needs_scope then "teslScope" :: !arguments else !arguments in
      Printf.bprintf body
        "\t\t\treturn teslrt.Response{Status: 200, Body: %s(%s(%s))}\n\t\t},\n"
        encoder (qualified signature.sig_owner signature.go_name)
        (String.concat ", " call_arguments)) bound;
    Buffer.add_string body "\t},\n}\n") servers;
  (* Comparator helpers the body referenced, in name order so the output is
     deterministic. *)
  Hashtbl.to_seq pending_helpers
  |> List.of_seq
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.iter (fun (name, source) ->
    Hashtbl.replace module_helpers name ();
    Buffer.add_string body source);
  (* A private Tesl function that nothing calls is legal Tesl, and the Racket backend
     emits it, so refusing to emit Go for the whole module over it was a divergence with
     no upside — a teaching file that declares a function to illustrate it could not be
     compiled at all.  It is emitted, and referenced once here because Go's `unused`
     linter (staticcheck U1000) rejects an uncalled unexported function, and a lint
     finding on emitted code is an emitter bug by contract. *)
  (match List.sort String.compare unreachable with
   | [] -> ()
   | names ->
     Buffer.add_string body
       "\n// Declared in Tesl but not called within this module.  Tesl permits an unused\n\
        // private declaration; Go's linters do not, so these references keep them.\n";
     (match names with
      | [single] -> Printf.bprintf body "var _ = %s\n" single
      | names ->
        Buffer.add_string body "var (\n";
        List.iter (fun name -> Printf.bprintf body "\t_ = %s\n" name) names;
        Buffer.add_string body ")\n"));
  let body = Buffer.contents body in
  let imports =
    (if contains_go_code body "strconv." then ["strconv"] else [])
    (* A Float literal that Go has no syntax for — negative zero, an infinity, a NaN —
       renders as a `math` call, so the literal itself pulls the import in. *)
    @ (if contains_go_code body "math." then ["math"] else [])
    (* A server's handler adapters take an `*http.Request`. *)
    @ (if contains_go_code body "http.Request" then ["net/http"] else [])
    @ (if contains_go_code body "io.ReadAll" then ["io"] else [])
    (* A derived decoder turns a nested record's rejection into an `error`. *)
    @ (if contains_go_code body "errors.New" then ["errors"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else [])
    (* Only packages the emitted body actually references: an unused import is a Go
       compile error, and a Tesl module may import names it only uses in a type
       annotation, or import facts that erase entirely. *)
    @ List.filter_map (fun dependency ->
        if contains_go_code body (dependency ^ ".") then
          Some (module_path ^ "/internal/" ^ dependency)
        else None)
        (List.sort String.compare imported_packages) in
  let header = Printf.sprintf "package %s\n%s" package (import_block imports) in
  header ^ body

let test_source ?(imported_packages=[]) ?(api_tests=[]) module_path package signatures
    (tests : test_form list) =
  Hashtbl.reset pending_helpers;
  Hashtbl.reset helper_names;
  let body = Buffer.create 1024 in
  (* Numbers the operand bindings a comparison introduces, unique across the file. *)
  let expect_operand = ref 0 in
  (* ── Per-test isolation ────────────────────────────────────────────────────
     Every test block starts from empty stores, which is what Racket's
     `call-with-fresh-memory-db` gives every `test`/`api-test` body.  Go runs a package's
     tests in one process and (absent t.Parallel, which emitted tests never use) one at a
     time, so without this the second block would see the first block's rows, jobs and HTTP
     stubs — the exact leak the Racket side was fixed for, where one api-test saw another's
     seed and answered 200 instead of 404.
     Tables and queues of IMPORTED packages are reset too: a `database` block in another
     module is where that leak actually bit, and here the owning package is known rather than
     having to be recovered from a runtime registry. *)
  let reset_calls =
    let owned owner = owner = package || List.mem owner imported_packages in
    match !current_types with
    | None -> []
    | Some types ->
      let tables =
        Hashtbl.to_seq_values types.entities
        |> List.of_seq
        |> List.filter (fun info -> owned info.ent_owner)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.TableTruncate(%s)"
               (qualified info.ent_owner info.ent_table_var))
      and queues =
        Hashtbl.to_seq_values types.queues
        |> List.of_seq
        |> List.filter (fun info -> owned info.qu_owner)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.ResetQueue(%s)" (qualified info.qu_owner info.qu_go_var))
      in
      (* The stub table is only reset when the module can stub at all: `stubHttp` is in
         `signatures` exactly when `Tesl.ApiTest` exposed it. *)
      let stubs =
        if Hashtbl.mem signatures "stubHttp" || Hashtbl.mem signatures "httpCallCount"
           || Hashtbl.mem signatures "httpCalled" || Hashtbl.mem signatures "httpLastBody"
        then ["teslrt.ResetHttpStubs()"] else []
      in
      List.sort_uniq String.compare (tables @ queues) @ stubs
  in
  let emit_reset () =
    if reset_calls <> [] then Buffer.add_string body "\tteslResetTestState()\n"
  in
  let rec emit_stmts env indent = function
    | [] -> ()
    | TsLet { name; value; loc; _ } :: rest ->
      let ty = type_of_expr signatures env value in
      Printf.bprintf body "%s{\n" indent;
      Buffer.add_string body (line_directive loc);
      let emitted = emit_expr ~indent:(indent ^ "\t") signatures env value in
      (* `let _ = …` runs the statement and DISCARDS the result — Go's `_` is not a
         variable, so it can neither be declared with `:=` nor read back. *)
      if name = "_" then Printf.bprintf body "%s\t_ = %s\n" indent emitted
      else begin
        Printf.bprintf body "%s\t%s := %s\n" indent (local_ident name) emitted;
        Printf.bprintf body "%s\t_ = %s\n" indent (local_ident name)
      end;
      emit_stmts (if name = "_" then env else (name, ty) :: env) (indent ^ "\t") rest;
      Printf.bprintf body "%s}\n" indent
    | TsExpect { left; right; loc } :: rest ->
      (* Each side may be the one that supplies the other's type: `expect xs == []`
         and `expect [] == xs` both have to work, and an empty list literal (like a
         nullary generic constructor) carries no type of its own. *)
      let needs_expectation = function
        | EList { elems = []; _ } -> true
        | EConstructor { args = []; _ } -> true
        | _ -> false
      in
      let left_ty = match right with
        | Some right when needs_expectation left ->
          type_of_arg signatures env (type_of_expr signatures env right) left
        | _ -> type_of_expr signatures env left
      in
      (* The emitted guard is the NEGATION of the expectation, built structurally so
         no `!(a && b)` / `!(a == b)` shape reaches the lint gate. *)
      let failure_condition = match right with
        | None ->
          if left_ty <> TBool then unsupported loc "Go backend bare expect requires Bool";
          strip_outer_parens (emit_negated ~indent signatures env left)
        | Some right ->
          let right_ty = type_of_arg signatures env left_ty right in
          (* An UNTYPED api-test value on either side compares structurally through the
             runtime — `expect r.body.count == 3` is the shape these tests are written in, and
             the two sides are different Go types by construction. *)
          if left_ty = TJson || right_ty = TJson then begin
            let json_side, typed_side, typed_ty =
              if left_ty = TJson then left, right, right_ty else right, left, left_ty in
            let rec comparand ty emitted = match ty with
              | TJson -> emitted
              | TInt | TString | TBool | TFloat -> emitted
              | TNewtype info when not info.secret ->
                comparand info.base (Printf.sprintf "%s.Value" (selector_operand emitted))
              | TList (TInt | TString | TBool | TFloat) ->
                Printf.sprintf "teslrt.JsonListOf(%s)" emitted
              | _ -> unsupported loc
                "Go backend compares an api-test JSON value against a scalar, a newtype over \
                 one, or a list of those"
            in
            let encoded = comparand typed_ty
              (if typed_ty = TJson then emit_expr ~indent signatures env typed_side
               else emit_expr ~expected:typed_ty ~indent signatures env typed_side) in
            Printf.sprintf "!teslrt.JsonEqual(%s, %s)"
              (emit_expr ~indent signatures env json_side) encoded
          end else begin
          if left_ty <> right_ty then unsupported loc "Go backend expect operands have different types";
          (match left_ty, bool_literal_value left, bool_literal_value right with
           | TBool, Some expected, None ->
             if expected then strip_outer_parens (emit_negated ~indent signatures env right)
             else strip_outer_parens (emit_expr ~indent signatures env right)
           | TBool, None, Some expected ->
             if expected then strip_outer_parens (emit_negated ~indent signatures env left)
             else strip_outer_parens (emit_expr ~indent signatures env left)
           | _ ->
             if not (supports_equality left_ty) then unsupported loc
               "Go backend does not support `expect` equality on this type yet";
             (* Comparing a multi-variant value expands to a tag test plus a payload test,
                each mentioning the operand — so a non-trivial operand would be emitted
                THREE times, evaluating the whole expression three times and producing a
                line gofmt then reflows.  Anything that is not already a simple name is
                bound first. *)
             let simple expr = match expr with
               | EVar _ | ELit _ -> true
               | _ -> false
             in
             let bind label expr =
               let emitted = emit_expr ~expected:left_ty ~indent signatures env expr in
               if simple expr then emitted
               else begin
                 (* Numbered per comparison, not per indent: two `expect`s in one block
                    sit at the same indent and would redeclare the name. *)
                 let name = Printf.sprintf "tesl%s%d" label !expect_operand in
                 Printf.bprintf body "%s%s := %s\n" indent name emitted;
                 name
               end
             in
             incr expect_operand;
             let emitted_left = bind "Left" left in
             let emitted_right = bind "Right" right in
             strip_outer_parens (unequal_expr left_ty emitted_left emitted_right))
          end
      in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif %s {\n%s\tteslT.Fatal(\"Tesl expectation failed\")\n%s}\n"
        indent failure_condition indent indent;
      emit_stmts env indent rest
    | TsExpr { e; loc } :: rest ->
      ignore (type_of_expr signatures env e);
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%s_ = %s\n" indent (emit_expr ~indent signatures env e);
      emit_stmts env indent rest
    | TsExpectFail { fn = EVar { name = "check"; _ }; arg; loc } :: rest ->
      let result_ty = type_of_expr signatures env arg in
      (match result_ty with
       | TCheck _ -> ()
       | _ -> unsupported loc "Go backend expectFail target is not a check");
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif (%s).OK() {\n%s\tteslT.Fatal(\"expected Tesl check failure\")\n%s}\n"
        indent (emit_expr ~indent signatures env arg) indent indent;
      emit_stmts env indent rest
    | TsExpectFail { fn = (EVar _ as fn); arg; loc } :: rest ->
      let call = expect_fail_call fn arg loc in
      let result_ty = type_of_expr signatures env call in
      let emitted = emit_expr ~indent signatures env call in
      Buffer.add_string body (line_directive loc);
      (match result_ty with
       | TCheck _ ->
         Printf.bprintf body "%sif (%s).OK() {\n%s\tteslT.Fatal(\"expected Tesl check failure\")\n%s}\n"
           indent emitted indent indent
       | TInt | TFloat | TString | TBool | TUnit | TNewtype _ | TRecord _ | TAdt _
       | TList _ | TDict _ | TSet _ | TParam _ | TFunc _ | TJson ->
         Printf.bprintf body "%steslExpectFailure(teslT, func() {\n%s\t_ = %s\n%s})\n"
           indent indent emitted indent
       | TFailure -> unsupported loc "Go backend expectFail target has no result type");
      emit_stmts env indent rest
    (* A `case` in a test block discriminates exactly like one in an expression — the same
       emitter runs it — but each arm carries STATEMENTS rather than a value. *)
    | TsCase { scrut; arms; loc } :: rest ->
      Buffer.add_string body (line_directive loc);
      emit_case_statements ~indent signatures env body scrut
        (List.map (fun (arm : ts_case_arm) ->
           arm.ts_pattern, arm.ts_guard,
           (fun arm_env body_indent -> emit_stmts arm_env body_indent arm.ts_body)) arms);
      emit_stmts env indent rest
    (* `let (v ::: pf) = value` in a test: the value binds and the proof erases, as in a
       function body.  A test may name several proofs at once (`::: p1 && p2`). *)
    | TsLetProof { value_name; proof_names; value; loc } :: rest ->
      let value_ty = type_of_expr signatures env value in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%s{\n" indent;
      let emitted = emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      if value_name = "_" then
        Printf.bprintf body "%s\t_ = %s\n" indent emitted
      else begin
        Printf.bprintf body "%s\t%s := %s\n" indent (local_ident value_name) emitted;
        Printf.bprintf body "%s\t_ = %s\n" indent (local_ident value_name)
      end;
      List.iter (fun proof_name ->
        if proof_name <> "_" then begin
          Printf.bprintf body "%s\t%s := struct{}{}\n" indent (local_ident proof_name);
          Printf.bprintf body "%s\t_ = %s\n" indent (local_ident proof_name)
        end) proof_names;
      let env =
        (value_name, value_ty)
        :: List.map (fun proof_name -> proof_name, TUnit) proof_names
        @ env in
      emit_stmts env (indent ^ "\t") rest;
      Printf.bprintf body "%s}\n" indent
    | (TsExpectFail { loc; _ } | TsExpectHasProof { loc; _ }
      | TsProperty { loc; _ } | TsIf { loc; _ }) :: _ ->
      unsupported loc "Go backend does not support this test statement yet"
  in
  List.iteri (fun index (test : test_form) ->
    (* `runs` is a property test's repetition count, which needs generators.  The
       capabilities and the `with database X` header, by contrast, are compile-time
       grants: with `backend: Memory` the store a test writes to is the entity's own
       table variable, exactly as in a function body. *)
    if test.runs <> None then
      unsupported test.loc "Go backend supports plain deterministic tests only";
    ignore test.capabilities;
    (* The header names a database the checker has already resolved, and every database
       this backend accepts is a Memory one, so there is nothing to bind. *)
    ignore test.database;
    Buffer.add_char body '\n';
    Printf.bprintf body "func TestTesl%d(teslT *testing.T) {\n" index;
    emit_reset ();
    emit_stmts [] "\t" test.stmts;
    Buffer.add_string body "}\n") tests;
  (* An `api-test` drives the emitted server IN PROCESS — no socket, so it is an ordinary
     `go test` case.  Racket dispatches the same way, so both backends exercise the same
     layer.  The statements are the same `test_stmt` forms an ordinary `test` block uses,
     so they go through the same emitter; only the request verbs are special. *)
  List.iteri (fun index (api_test : api_test_form) ->
    if api_test.seed_stmts <> [] then unsupported api_test.loc
      "Go backend does not support api-test seed statements yet";
    Buffer.add_char body '\n';
    (* The description comment goes BEFORE the line directive: gofmt treats a comment
       directly above a declaration as its doc comment and moves the directive below it. *)
    (* gofmt separates a doc comment from a following `//line` directive with a bare `//`
       line, so it is emitted that way rather than left for gofmt to add. *)
    Printf.bprintf body "// api-test %s\n//\n" (String.escaped api_test.description);
    Buffer.add_string body (line_directive api_test.loc);
    Printf.bprintf body "func TestTeslApi%d(teslT *testing.T) {\n" index;
    emit_reset ();
    current_api_server := Some (go_ident ~exported:true api_test.server_name);
    emit_stmts [] "\t" api_test.stmts;
    current_api_server := None;
    Buffer.add_string body "}\n") api_tests;
  if reset_calls <> [] then begin
    Buffer.add_string body
      "\n// teslResetTestState empties the stores every test block starts from, so no block\n\
       // inherits another's rows, jobs, or outbound-HTTP stubs.\n\
       func teslResetTestState() {\n";
    List.iter (fun call -> Printf.bprintf body "\t%s\n" call) reset_calls;
    Buffer.add_string body "}\n"
  end;
  let body = Buffer.contents body in
  let expect_failure_helper =
    if contains_go_code body "teslExpectFailure(" then
      "\nfunc teslExpectFailure(teslT *testing.T, teslThunk func()) {\n\tteslT.Helper()\n\tdefer func() {\n\t\tif recover() == nil {\n\t\t\tteslT.Fatal(\"expected Tesl failure\")\n\t\t}\n\t}()\n\tteslThunk()\n}\n"
    else ""
  in
  let body =
    (* Only the helpers module.go did NOT already declare: both files are one Go package,
       so a duplicate is a redeclaration, and a helper the module already has is in scope
       here anyway. *)
    (Hashtbl.to_seq pending_helpers
     |> List.of_seq
     |> List.filter (fun (name, _) -> not (Hashtbl.mem module_helpers name))
     |> List.sort (fun (left, _) (right, _) -> String.compare left right)
     |> List.map snd
     |> String.concat "")
    ^ body
  in
  let imports = ["fmt"; "os"]
    @ (if contains_go_code body "strconv." then ["strconv"] else [])
    @ (if contains_go_code body "math." then ["math"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else [])
    (* A test block may construct a dependency's type or call into it directly, so the
       test file needs the same imports — and only the ones it actually references. *)
    @ List.filter_map (fun dependency ->
        if contains_go_code body (dependency ^ ".") then
          Some (module_path ^ "/internal/" ^ dependency)
        else None) imported_packages
    @ ["testing"] in
  Printf.sprintf
    "package %s\n%s\nfunc TestMain(teslM *testing.M) {\n\t_, _ = fmt.Fprintln(os.Stderr, \"TESL_GO_TESTS_STARTED\")\n\tos.Exit(teslM.Run())\n}\n%s%s"
    package (import_block imports) expect_failure_helper body

(* Brings an imported local module's exposed names into scope by COPYING the entries
   from the tables that module emitted from.  Nothing is re-derived: a second derivation
   would produce info records that compare unequal to the originals (go_type equality is
   structural), so a value crossing the boundary would look like a different type.
   Facts are absent from these tables by design — a fact erases entirely, so an exposed
   name that resolves to nothing is not an error. *)
let register_imported_module ~loc ~exposed types signatures (exports : module_exports) =
  List.iter (fun name ->
    let copy_type () =
      match Hashtbl.find_opt exports.ex_types.newtypes name,
            Hashtbl.find_opt exports.ex_types.records name,
            Hashtbl.find_opt exports.ex_types.adts name with
      | Some info, _, _ -> Hashtbl.replace types.newtypes name info; true
      | None, Some info, _ ->
        Hashtbl.replace types.records name info;
        (* An exposed ENTITY brings its table along with its row type: a query in this
           module reads the other package's store, so the two must be the same table. *)
        (match Hashtbl.find_opt exports.ex_types.entities name with
         | Some entity -> Hashtbl.replace types.entities name entity
         | None -> ());
        true
      | None, None, Some info -> Hashtbl.replace types.adts name info; true
      | None, None, None -> false
    in
    (* An ADT exposed as `Colour(..)` brings its constructors; the bare name is also
       accepted, since the constructors live in the signature table either way. *)
    let base = match String.index_opt name '(' with
      | Some index -> String.sub name 0 index
      | None -> name
    in
    let found_type = copy_type () || (base <> name &&
      (match Hashtbl.find_opt exports.ex_types.adts base with
       | Some info -> Hashtbl.replace types.adts base info; true
       | None -> false)) in
    let found_value = match Hashtbl.find_opt exports.ex_signatures name with
      | Some signature -> Hashtbl.replace signatures name signature; true
      | None -> false
    in
    (* A constructor of an exposed ADT is itself a signature entry. *)
    if found_type then
      Hashtbl.iter (fun ctor (signature : signature) ->
        match signature.result with
        | TAdt (info, _) when info.adt_tesl_name = base ->
          Hashtbl.replace signatures ctor signature
        | _ -> ()) exports.ex_signatures;
    (* A name that is neither a type nor a value is a FACT: the frontend has already
       validated the import, and a fact has no runtime form to bring across. *)
    ignore (found_type, found_value, loc))
    exposed

let compile_module ?(mode=Release) ?(dependencies=[]) ?project_path (m : module_form) =
  try
    (match mode with
     | Release -> ()
     | Debug -> unsupported (Location.dummy_loc m.source_file)
       "Go debugger instrumentation is not implemented yet");
    (* `Maybe` is provided by `internal/teslrt` rather than emitted per module: a
       Maybe crosses module boundaries, and two packages declaring their own would
       be incompatible Go types.  Only the type and its constructors are available;
       the `Tesl.Maybe` FUNCTIONS still fail closed. *)
    let maybe_imported = ref false in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> []
        | ImportExposing names -> names
      in
      match import.module_name with
      | "Tesl.Prelude" ->
        if List.exists (fun name -> name = "Maybe" || name = "Maybe(..)") exposed then
          maybe_imported := true
      | "Tesl.Maybe" ->
        (* The type and its two constructors are the runtime type; every `Maybe.*`
           FUNCTION still fails closed until the stdlib lands. *)
        List.iter (fun name ->
          match name with
          | "Maybe" | "Maybe(..)" | "Nothing" | "Something" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Maybe` export `%s` yet" other) exposed;
        maybe_imported := true
      (* `Tesl.Json` exports codec COMBINATOR names, not values: `stringCodec` and
         friends only ever appear in a `with_codec` position, which the codec emitter
         resolves directly.  Nothing is bound at runtime, so the import needs no
         support beyond accepting the names it may expose. *)
      | "Tesl.Json" ->
        List.iter (fun name ->
          match name with
          | "stringCodec" | "intCodec" | "boolCodec" | "floatCodec" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Json` export `%s` yet" other) exposed
      (* `Tesl.Http`: the request type is runtime-provided (registered above) and
         `cookieCap` is a capability name the checker enforces — neither needs anything at
         run time.  The cookie WRITERS arrive with the session slice. *)
      (* `Tesl.ApiTest`: the response type is runtime-provided; the status predicates are
         runtime leaves.  A request verb is only meaningful inside an `api-test` block. *)
      | "Tesl.ApiTest" ->
        List.iter (fun name ->
          match name with
          | "HttpResponse" | "statusOk" | "statusClientError" | "statusServerError"
          | "get" | "post" | "put" | "delete" | "patch" -> ()
          (* The queue verbs an api-test drives.  `JobResult` is runtime-provided (registered
             below with Maybe and Either), the rest are calls whose QUEUE argument the
             emitter resolves statically. *)
          | "JobResult" | "JobResult(..)" | "JobOk" | "JobFailed"
          | "processNextJob" | "processNextDeadJob" | "pendingJobCount" | "drainQueue"
          | "expectJobOk" | "expectJobFailed" -> ()
          (* The untyped JSON surface: `JsonValue`/`JsonNull` are the type names, the rest are
             the predicates and accessors the emitter renders directly. *)
          | "JsonValue" | "JsonNull"
          | "isNull" | "isNotNull" | "isEmpty" | "isNotEmpty" | "hasLength" | "hasField"
          | "jsonInt" | "jsonString" | "jsonBool" | "jsonArray" | "jsonObject" | "jsonLength"
          | "arrayAt" | "fieldAt" | "bodyField" | "jsonContains" -> ()
          (* The outbound-HTTP double: statements a test writes before the code under test
             runs, and the assertions that read the call log afterwards. *)
          | "stubHttp" | "stubHttpFailure" | "stubHttpTimeout"
          | "httpCalled" | "httpCallCount" | "httpLastBody" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.ApiTest` export `%s` yet" other) exposed
      | "Tesl.Http" ->
        List.iter (fun name ->
          match name with
          | "HttpRequest" | "cookieCap" | "Http.clearSessionCookie" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Http` export `%s` yet" other) exposed
      (* `Tesl.Crypto`: message authentication, digests and tokens are runtime leaves over Go's
         standard library — the same primitives the Racket runtime reaches for in libsodium, so
         a tag or a fingerprint produced by one backend verifies on the other.  PASSWORD
         STORAGE is refused by name: Racket uses libsodium's Argon2id and Go's standard library
         has no Argon2, so matching it takes a dependency (`golang.org/x/crypto/argon2`) rather
         than an implementation — and a PBKDF2 substitute would mint hashes the Racket side
         cannot verify, which is worse than not having it. *)
      | "Tesl.Crypto" ->
        List.iter (fun name ->
          match name with
          | "Secret" | "Signature"
          | "Crypto.signWith" | "Crypto.hmacSha256" | "Crypto.checkSignature"
          | "Crypto.signatureHex" | "Crypto.signatureFromHex"
          | "Crypto.signatureBase64" | "Crypto.signatureFromBase64"
          | "Crypto.fingerprint" | "Crypto.keyFingerprint" | "Crypto.randomToken"
          | "Crypto.sha256" | "Crypto.sha512" -> ()
          (* The proof predicates erase, like every other fact. *)
          | "HashFor" | "PasswordVerified" | "Authentic" -> ()
          | ("PasswordHash" | "Crypto.hashPassword" | "Crypto.checkPassword"
            | "Crypto.needsRehash") as password ->
            unsupported import.loc
              "Go backend does not support `%s` yet: password storage is Argon2id on the \
               Racket runtime, and matching it needs an approved dependency \
               (`golang.org/x/crypto/argon2`) — a weaker substitute would mint hashes the \
               other backend cannot verify" password
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Crypto` export `%s` yet" other) exposed
      (* `Tesl.HttpClient`: the four verbs and the two secret-accepting header builders are
         runtime leaves (registered below); `HttpResponse` is the runtime-provided record
         they answer with, and `httpClient` is the capability the checker enforces. *)
      | "Tesl.HttpClient" ->
        List.iter (fun name ->
          match name with
          | "httpClient" | "HttpResponse" | "HttpResponse?"
          | "HttpClient.get" | "HttpClient.post" | "HttpClient.put" | "HttpClient.delete"
          | "HttpClient.bearer" | "HttpClient.secretHeader" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.HttpClient` export `%s` yet" other) exposed
      (* `Tesl.DB` exports the two database CAPABILITIES, which the checker enforces and
         which have no runtime form, plus the `delete … returning result` ADT — refused
         while `deleteAndReturnResult` is. *)
      | "Tesl.DB" ->
        List.iter (fun name ->
          match name with
          | "dbRead" | "dbWrite" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.DB` export `%s` yet" other) exposed
      (* `Tesl.Database` names the DECLARATION form (`= Database { entities: … backend:
         Memory }`); the declaration itself is where the backend is checked. *)
      | "Tesl.Database" ->
        List.iter (fun name ->
          match name with
          (* The Postgres names are accepted as NAMES — they are only meaningful inside a
             `database` declaration, and a declaration that selects that backend is
             refused there. *)
          | "Database" | "Memory" | "DatabaseBackend" | "Postgres" | "PostgresConfig"
          | "PostgresConnection" | "TcpConnection" | "SocketConnection" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Database` export `%s` yet" other) exposed
      | "Tesl.String" | "Tesl.List" | "Tesl.Int" | "Tesl.Tuple" | "Tesl.Dict"
      | "Tesl.Set" | "Tesl.Float" | "Tesl.Either" | "Tesl.EitherPrim"
      | "Tesl.Time" | "Tesl.Env" | "Tesl.Random" | "Tesl.Id" | "Tesl.Result" -> ()
      (* `Tesl.Queue` exports the DECLARATION vocabulary (`Queue`, the retry strategy and
         its backoff constructors), two capabilities, and the `FromQueue`/`FromDeadQueue`
         provenance proofs — which erase.  None of it needs a runtime binding: the store is
         the queue's own variable and the retry rule is baked into it. *)
      | "Tesl.Queue" ->
        List.iter (fun name ->
          match name with
          | "Queue" | "QueueRetryStrategy" | "Fixed" | "Exponential" | "Linear"
          | "queueRead" | "queueWrite" | "FromQueue" | "FromDeadQueue" | "Job"
          (* `pubsub` is the SSE capability: a compile-time grant, and the functions it
             gates fail closed on their own. *)
          | "pubsub"
          (* `deadJobs` is a FUNCTION over a queue (registered as a leaf below), and
             `DeadJob` the opaque type of its elements. *)
          | "deadJobs" | "DeadJob" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Queue` export `%s` yet" other) exposed
        (* validated against the leaf/type tables below *)
      | other when List.exists (fun (dependency : module_exports) ->
                     dependency.ex_module = other) dependencies ->
        (* A LOCAL module: registered below, once the type tables exist. *)
        ()
      | other ->
        unsupported import.loc "Go backend does not support import `%s` yet" other) m.imports;
    (* A `fact` is a proof PREDICATE.  Applying it (`ValidPort port`) builds a proof term,
       which erases — so it is registered like a zero-size constructor: the arguments are
       typed and then dropped, and the value is the empty struct.  Registered because a
       proof term can appear in an expression the emitter DOES walk: an `establish` whose
       result is `Maybe (Fact P)` answers with `Something (ValidPort port)`, and that Maybe
       is real control flow. *)
    let fact_names = List.filter_map (function DFact f -> Some f.name | _ -> None) m.decls in
    let funcs = List.filter_map (function DFunc fd -> Some fd | _ -> None) m.decls in
    let codecs = List.filter_map (function DCodec c -> Some c | _ -> None) m.decls in
    let apis = List.filter_map (function DApi a -> Some a | _ -> None) m.decls in
    let servers = List.filter_map (function DServer s -> Some s | _ -> None) m.decls in
    let capturers = List.filter_map (function DCapture c -> Some c | _ -> None) m.decls in
    let api_tests = List.filter_map (function DApiTest t -> Some t | _ -> None) m.decls in
    let tests = List.filter_map (function DTest test -> Some test | _ -> None) m.decls in
    let package = package_name m.module_name in
    let types = {
      newtypes = Hashtbl.create 8;
      records = Hashtbl.create 8;
      adts = Hashtbl.create 8;
      entities = Hashtbl.create 8;
      queues = Hashtbl.create 8;
    } in
    (* Every package-level Go name is minted here, in declaration order, so the
       emitted names are deterministic and provably distinct. *)
    let taken : (string, unit) Hashtbl.t = Hashtbl.create 32 in
    let package_ident name = unique_ident taken (go_ident ~exported:true name) in
    List.iter (function
      | DType (TypeNewtype { name; base_type; secret; loc; _ }) ->
        let base = primitive_type_of_type_expr base_type in
        (* A secret's payload is held as a `teslrt.SecretString`, so only a String base has a
           representation today; a secret over Int would need its own redacting carrier and
           has no corpus use. *)
        if secret && base <> TString then unsupported loc
          "Go backend supports a `secret` newtype over String only (`%s`)" name;
        Hashtbl.replace types.newtypes name {
          tesl_name = name;
          owner = package;
          go_name = package_ident name;
          base;
          secret;
          loc;
        }
      | _ -> ()) m.decls;
    let record_forms = List.filter_map (function DRecord r -> Some r | _ -> None) m.decls in
    List.iter (fun (r : record_form) ->
      (* A record-level `::: P` after the closing brace is a CROSS-FIELD invariant, and it is
         compile-time only — LANGUAGE-SPEC calls it a zero-cost annotation, and the Racket
         emitter reads it for nothing but property-test GENERATORS (`record_meta`), never for
         a check at construction.  Constructing such a record needs a witness, which the
         checker demands; here it erases with every other proof. *)
      ignore r.invariant;
      if r.fields = [] then unsupported r.loc
        "Go backend does not support the field-less record `%s`" r.name;
      List.iter (fun (field : field_def) ->
        (* A proof-carrying field (`name: String ::: Named name`) ERASES to its own type,
           the same rule every other proof follows: the checker has discharged it, and
           LANGUAGE-SPEC 16.9 gives a proof no runtime structure.  Racket attaches a
           wrapper and unwraps on every read, which is an implementation detail of that
           backend.  This used to fail closed as a not-yet; codecs are what forced the
           question, since a decoded field is exactly a proof-carrying field. *)
        ignore field.proof_ann;
        if field.checker <> None then unsupported field.loc
          "Go backend does not support `via` on record field `%s.%s` yet" r.name field.name)
        r.fields;
      if Hashtbl.mem types.newtypes r.name || Hashtbl.mem types.records r.name then
        unsupported r.loc "Go backend generated type name collision for `%s`" r.name;
      Hashtbl.replace types.records r.name {
        rec_tesl_name = r.name;
        rec_owner = package;
        rec_go_name = package_ident r.name;
        rec_fields = [];
        rec_loc = r.loc;
      }) record_forms;
    (* A `queue` declaration: one store variable plus the job-type → worker wiring.  The
       typed form (`= Queue { … }`) keeps its fields in `config_expr`, and the Go pipeline
       does not run the desugar pass, so the same lowering the Racket backend gets is
       applied here — including `job_entries`, which pairs each job type with its worker and
       optional dead-letter worker. *)
    let queue_forms = List.filter_map (function DQueue q -> Some q | _ -> None) m.decls in
    List.iter (fun (q : queue_form) ->
      let entries = match q.config_expr with
        | None -> []
        | Some config ->
          (match List.assoc_opt "jobs" (Desugar.config_record_fields config) with
           | Some jobs -> Desugar.job_entries jobs
           | None -> [])
      in
      let lowered = Desugar.desugar_queue_config q in
      (match entries with
       | [] -> unsupported q.loc
         "Go backend requires `jobs: [Job <JobType> <worker> …]` on queue `%s`" q.name
       | _ :: _ :: _ -> unsupported q.loc
         "Go backend does not support a queue carrying more than one job type yet (`%s`)"
         q.name
       | [(job_type, worker, dead_worker)] ->
         let go_var = package_ident (q.name ^ "Queue") in
         let info = {
           qu_tesl_name = q.name;
           qu_go_var = go_var;
           qu_owner = package;
           qu_job_type = job_type;
           qu_worker = worker;
           qu_dead_worker = dead_worker;
           qu_max_attempts = Option.value lowered.max_attempts ~default:1;
           qu_loc = q.loc;
         } in
         Hashtbl.replace types.queues q.name info;
         (* Also by job type, since `enqueue` names the JOB and not the queue. *)
         Hashtbl.replace types.queues job_type info;
         ignore lowered)) queue_forms;
    (* An entity's ROW type is registered exactly like a record — a query result and an
       `insert` argument are ordinary struct values — and its store is one package-level
       table variable. *)
    let entity_forms = List.filter_map (function DEntity e -> Some e | _ -> None) m.decls in
    List.iter (fun (e : entity_form) ->
      if e.fields = [] then unsupported e.loc
        "Go backend does not support the field-less entity `%s`" e.name;
      List.iter (fun (field : field_def) ->
        ignore field.proof_ann;
        if field.checker <> None then unsupported field.loc
          "Go backend does not support `via` on entity field `%s.%s` yet" e.name field.name)
        e.fields;
      if not (List.exists (fun (field : field_def) -> field.name = e.primary_key) e.fields) then
        unsupported e.loc
          "Go backend cannot find the primary key `%s` among the fields of entity `%s`"
          e.primary_key e.name;
      (* A UNIQUE index is a constraint the Memory backend ENFORCES on Racket (an insert
         that violates it raises), so accepting one here without enforcing it would make
         the two backends disagree about which programs run.  A plain index is a
         performance hint with no observable effect, so it is simply ignored. *)
      List.iter (fun (index : entity_index) ->
        if index.ix_unique then unsupported index.ix_loc
          "Go backend does not support `unique index` on entity `%s` yet" e.name)
        e.indexes;
      if Hashtbl.mem types.newtypes e.name || Hashtbl.mem types.records e.name then
        unsupported e.loc "Go backend generated type name collision for `%s`" e.name;
      let row = {
        rec_tesl_name = e.name;
        rec_owner = package;
        rec_go_name = package_ident e.name;
        rec_fields = [];
        rec_loc = e.loc;
      } in
      Hashtbl.replace types.records e.name row;
      Hashtbl.replace types.entities e.name {
        ent_tesl_name = e.name;
        ent_row = row;
        ent_table_var = package_ident (e.name ^ "Table");
        ent_owner = package;
        ent_primary_key = e.primary_key;
        ent_loc = e.loc;
      }) entity_forms;
    let tuple_imported = ref false in
    let set_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Set" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if set_leaf name <> None then set_imports := name :: !set_imports
          else match name with
            | "Set" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Set` export `%s` yet" other) exposed
      end) m.imports;
    let dict_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Dict" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if dict_leaf name <> None then begin
            dict_imports := name :: !dict_imports;
            (* lookup returns a Maybe; toList/fromList speak in tuples. *)
            if name = "Dict.lookup" then maybe_imported := true;
            if name = "Dict.toList" || name = "Dict.fromList" then tuple_imported := true
          end else match name with
            | "Dict" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Dict` export `%s` yet" other) exposed
      end) m.imports;
    (* A list leaf is element-polymorphic, so its signature cannot be a fixed tuple of
       types like a String leaf's.  Each entry says how to type the call from the
       element type, and `emit_go` builds the argument list the same way. *)
    let list_leaf_names = [
      "List.length"; "List.isEmpty"; "List.head"; "List.tail"; "List.last";
      "List.append"; "List.take"; "List.drop"; "List.reverse"; "List.sum";
      "List.member"; "List.contains"; "List.unique"; "List.sort";
      "List.concat"; "List.flatten"; "List.maximum"; "List.minimum";
      "List.range"; "List.repeat";
    ] @ higher_order_leaf_names in
    let list_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.List" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name list_leaf_names then begin
            list_imports := name :: !list_imports;
            (* zip builds tuples, so importing it brings the runtime tuple types in
               even when the module never names Tuple2. *)
            if name = "List.zip" then tuple_imported := true;
            (* head/tail/last return a Maybe, so importing one brings the runtime
               Maybe in even when the module never names it. *)
            if List.mem name
                 ["List.head"; "List.tail"; "List.last"; "List.maximum"; "List.minimum";
                  "List.find"; "List.filterMap"]
            then maybe_imported := true
          end else match name with
            (* `Tesl.List`'s proof predicates are compile-time only, like
               `Tesl.String`'s: they erase with every other proof, so importing one
               needs no runtime support. *)
            | "IsSorted" | "ForAll" | "IsNonEmpty" | "IsNonNegative" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.List` export `%s` yet" other) exposed
      end) m.imports;
    let string_leaves = [
      (* name, params, result-shape, teslrt function *)
      "String.length",    [`Str], `Int,     "teslrt.StringLength";
      "String.isEmpty",   [`Str], `Bool,    "teslrt.StringIsEmpty";
      "String.startsWith",[`Str; `Str], `Bool, "teslrt.StringStartsWith";
      "String.endsWith",  [`Str; `Str], `Bool, "teslrt.StringEndsWith";
      "String.contains",  [`Str; `Str], `Bool, "teslrt.StringContains";
      "String.concat",    [`Str; `Str], `Str,  "teslrt.StringConcat";
      "String.replace",   [`Str; `Str; `Str], `Str, "teslrt.StringReplace";
      "String.slice",     [`Str; `Int; `Int], `Str, "teslrt.StringSlice";
      "String.toUpper",   [`Str], `Str,     "teslrt.StringToUpper";
      "String.toLower",   [`Str], `Str,     "teslrt.StringToLower";
      "String.trim",      [`Str], `Str,     "teslrt.StringTrim";
      "String.fromInt",   [`Int], `Str,     "teslrt.StringFromInt";
      "String.toInt",     [`Str], `MaybeInt,"teslrt.StringToInt";
      "String.indexOf",   [`Str; `Str], `MaybeInt, "teslrt.StringIndexOf";
      "String.dropPrefix",[`Str; `Str], `Str, "teslrt.StringDropPrefix";
      "String.dropSuffix",[`Str; `Str], `Str, "teslrt.StringDropSuffix";
      "String.padLeft",   [`Str; `Int; `Str], `Str, "teslrt.StringPadLeft";
      "String.padRight",  [`Str; `Int; `Str], `Str, "teslrt.StringPadRight";
      "String.repeat",    [`Str; `Int], `Str, "teslrt.StringRepeat";
      "String.reverse",   [`Str], `Str,     "teslrt.StringReverse";
      "String.requireNonEmpty", [`Str], `CheckStr, "teslrt.StringRequireNonEmpty";
      "String.split",     [`Str; `Str], `StrList, "teslrt.StringSplit";
      "String.join",      [`StrList; `Str], `Str, "teslrt.StringJoin";
      (* `Tesl.Int` checks: `List.take`/`List.drop` are proof-total, so a caller
         needs `check Int.nonNegative n` before it can pass a count at all. *)
      "Int.nonZero",      [`Int], `CheckInt, "teslrt.IntNonZero";
      "Int.nonNegative",  [`Int], `CheckInt, "teslrt.IntNonNegative";
      "Int.abs",          [`Int], `Int,      "teslrt.Abs";
      "Int.min",          [`Int; `Int], `Int, "teslrt.Min";
      "Int.max",          [`Int; `Int], `Int, "teslrt.Max";
      (* Proof-total: the divisor carries `IsNonZero`, so the runtime guard is
         containment rather than the primary check. *)
      (* `Tesl.Float`.  The transcendentals are absent on purpose: Go's sin/cos/tan
         diverge from Racket on 22-34% of inputs and its math.Log is outright wrong for
         subnormals, so they fail closed rather than emit divergent results. *)
      (* The named arithmetic surface; `Float.div`'s divisor carries a FloatNonZero proof,
         which erases like every other proof. *)
      "Float.add",        [`Float; `Float], `Float, "teslrt.FloatAdd";
      "Float.sub",        [`Float; `Float], `Float, "teslrt.FloatSub";
      "Float.mul",        [`Float; `Float], `Float, "teslrt.FloatMul";
      "Float.div",        [`Float; `Float], `Float, "teslrt.FloatDiv";
      "Float.abs",        [`Float], `Float, "teslrt.FloatAbs";
      "Float.min",        [`Float; `Float], `Float, "teslrt.FloatMin";
      "Float.max",        [`Float; `Float], `Float, "teslrt.FloatMax";
      "Float.clamp",      [`Float; `Float; `Float], `Float, "teslrt.FloatClamp";
      "Float.sqrt",       [`Float], `Float, "teslrt.FloatSqrt";
      "Float.floor",      [`Float], `Int,   "teslrt.FloatFloor";
      "Float.ceil",       [`Float], `Int,   "teslrt.FloatCeil";
      "Float.round",      [`Float], `Int,   "teslrt.FloatRound";
      "Float.toString",   [`Float], `Str,   "teslrt.FormatFloat";
      "Float.toInt",      [`Float], `Int,   "teslrt.FloatToIntTruncating";
      "Float.parse",      [`Str], `MaybeFloat, "teslrt.ParseFloat";
      "Float.requireNonZero", [`Float], `CheckFloat, "teslrt.FloatRequireNonZero";
      "Float.requireNonNegative", [`Float], `CheckFloat, "teslrt.FloatRequireNonNegative";
      "Int.divide",       [`Int; `Int], `Int, "teslrt.MustQuo";
      (* Tesl's `Int.modulo` is Racket `remainder` (truncated, sign of the
         dividend), NOT `modulo` (floored) — see tesl/int.rkt:183.  Mapping it to
         teslrt.MustMod would silently disagree on every negative dividend. *)
      "Int.modulo",       [`Int; `Int], `Int, "teslrt.MustRem";
      "Int.clamp",        [`Int; `Int; `Int], `Int, "teslrt.Clamp";
      "Int.sign",         [`Int], `Int,     "teslrt.IntSign";
      "Int.isEven",       [`Int], `Bool,    "teslrt.IntIsEven";
      "Int.isOdd",        [`Int], `Bool,    "teslrt.IntIsOdd";
      "Int.toString",     [`Int], `Str,     "teslrt.IntToString";
      (* Racket's `Int.pow` REJECTS a negative exponent rather than returning a
         fraction, so the Go leaf raises there too. *)
      "Int.pow",          [`Int; `Int], `Int, "teslrt.MustPow";
      (* `Int.parse` is `String.toInt` under another name.  Racket's differ in one corner:
         `Int.parse` accepts anything `integer?` accepts, so `Int.parse "3.0"` yields
         `Something 3.0` — a FLOAT where the type says Int — while `String.toInt` demands
         `exact-integer?`.  Both are strict decimal here; the Racket wart is recorded in
         roadmap/next/migrate_to_golang.md rather than reproduced. *)
      "Int.parse",        [`Str], `MaybeInt, "teslrt.StringToInt";
    ] in
    let leaf_names_for prefix =
      List.filter_map (fun (name, _, _, _) ->
        if String.length name > String.length prefix
           && String.sub name 0 (String.length prefix) = prefix then Some name else None)
        string_leaves
    in
    let string_leaf_names = leaf_names_for "String." in
    let int_leaf_names = leaf_names_for "Int." in
    let string_imports = ref [] in
    let float_leaf_names = leaf_names_for "Float." in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Float" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name float_leaf_names then begin
            string_imports := name :: !string_imports;
            if name = "Float.parse" then maybe_imported := true
          end else match name with
            | "Float" | "FloatNonZero" | "FloatNonNegative" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Float` export `%s` yet" other) exposed
      end) m.imports;
    (* `String.toInt` and `String.indexOf` return `Maybe Int`, so importing either
       one brings the runtime Maybe in even when the module never names Maybe. *)

    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Int" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name int_leaf_names then begin
            string_imports := name :: !string_imports;
            if name = "Int.parse" then maybe_imported := true
          end else match name with
            (* Proof predicates are compile-time only. *)
            | "IsNonZero" | "IsNonNegative" | "IsPositive" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Int` export `%s` yet" other) exposed
      end) m.imports;
    (* ── `Tesl.Env` / `Tesl.Random`: effects with no state of their own ──────
       Both are gated by a capability the checker enforces (`envRead`, `random`), so what
       is left at run time is one runtime call.  `requireSecret` answers the stdlib's own secret
       newtype (registered with `Tesl.Crypto`'s types); `envRead`/`random` themselves are
       capability NAMES. *)
    let env_leaf_names = ["env"; "envInt"; "envString"; "requireEnv"; "requireSecret"] in
    let random_leaf_names = ["randomInt"; "randomFloat"] in
    let effect_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> []
        | ImportExposing names -> names
      in
      match import.module_name with
      | "Tesl.Env" ->
        List.iter (fun name ->
          if List.mem name env_leaf_names then begin
            effect_imports := name :: !effect_imports;
            if name = "env" then maybe_imported := true
          end else match name with
            | "envRead" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Env` export `%s` yet" other) exposed
      | "Tesl.Random" ->
        List.iter (fun name ->
          if List.mem name random_leaf_names then
            effect_imports := name :: !effect_imports
          else match name with
            | "random" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Random` export `%s` yet" other) exposed
      | "Tesl.Id" ->
        List.iter (fun name ->
          match name with
          | "generateId" | "generatePrefixedId" ->
            effect_imports := name :: !effect_imports
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Id` export `%s` yet" other) exposed
      | _ -> ()) m.imports;
    (* ── `Tesl.Time`: the instant, and exact-integer millisecond arithmetic ──
       `PosixMillis` is runtime-provided for the reason `Maybe` is: an instant crosses
       module boundaries.  The CALENDAR surface (`formatTime`, the `Time.trunc*` buckets,
       `TimeZone`/`Time.offsetAt`) is refused — it needs the zone database and the shared
       bucket engine, which is its own slice — and so is the Duration bridge, which needs
       `Tesl.Units`. *)
    let time_leaf_names = [
      "nowMillis"; "durationMs"; "addMs"; "subtractMs"; "diffMs";
      "Time.posixToSeconds"; "Time.secondsToPosix";
    ] in
    let time_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Time" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name time_leaf_names then time_imports := name :: !time_imports
          else match name with
            (* The type itself, and the `time` CAPABILITY (compile-time, like every
               other capability). *)
            | "PosixMillis" | "time" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Time` export `%s` yet" other) exposed;
        (* Registered whenever the module imports Tesl.Time at all: the type is named in
           signatures and entity columns even when no leaf is exposed. *)
        Hashtbl.replace types.newtypes "PosixMillis" {
          tesl_name = "PosixMillis";
          owner = "";
          go_name = "teslrt.PosixMillis";
          base = TInt;
          secret = false;
          loc = import.loc;
        }
      end) m.imports;
    (* ── `Tesl.Crypto`, and the `Secret` its functions take ──────────────────
       `Secret` is registered whenever it can appear — `requireSecret` answers one, and every
       Crypto function that takes a key takes one — because it is a runtime-provided SECRET
       newtype: it redacts when printed, compares in constant time, and reaches an outbound
       header only through `HttpClient.bearer`.  `Signature` is a newtype over the hex tag,
       which is the representation the Racket runtime keeps, so a tag crossing between the two
       is the same string. *)
    let crypto_leaf_names = [
      "Crypto.signWith"; "Crypto.hmacSha256"; "Crypto.checkSignature";
      "Crypto.signatureHex"; "Crypto.signatureFromHex";
      "Crypto.signatureBase64"; "Crypto.signatureFromBase64";
      "Crypto.fingerprint"; "Crypto.keyFingerprint"; "Crypto.randomToken";
      "Crypto.sha256"; "Crypto.sha512";
    ] in
    let crypto_imports = ref [] in
    let secret_type_needed = ref false in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> [] | ImportExposing names -> names in
      match import.module_name with
      | "Tesl.Crypto" ->
        secret_type_needed := true;
        List.iter (fun name ->
          if List.mem name crypto_leaf_names then crypto_imports := name :: !crypto_imports)
          exposed
      | "Tesl.Env" ->
        if List.mem "requireSecret" exposed then secret_type_needed := true
      | _ -> ()) m.imports;
    if !secret_type_needed then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.newtypes "Secret" {
        tesl_name = "Secret"; owner = ""; go_name = "teslrt.Secret";
        base = TString; secret = true; loc;
      };
      Hashtbl.replace types.newtypes "Signature" {
        tesl_name = "Signature"; owner = ""; go_name = "teslrt.Signature";
        base = TString; secret = false; loc;
      }
    end;
    (* ── `Tesl.HttpClient`: the outbound verbs ───────────────────────────────
       The `httpClient` capability erases with every other one; what the emitter needs is the
       four verbs, the two secret-accepting header builders, and the response record.
       `Tuple2` is registered as a side effect because the header list is a
       `List (Tuple2 String String)` whether or not the module names the type itself. *)
    let httpclient_leaf_names = [
      "HttpClient.get"; "HttpClient.post"; "HttpClient.put"; "HttpClient.delete";
      "HttpClient.bearer"; "HttpClient.secretHeader";
    ] in
    let httpclient_imports = ref [] in
    let httpclient_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.HttpClient" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        List.iter (fun name ->
          if List.mem name httpclient_leaf_names then
            httpclient_imports := name :: !httpclient_imports) exposed;
        httpclient_imported := true;
        tuple_imported := true
      end) m.imports;
    (* The outbound-HTTP test double.  Its declarations and assertions are ordinary calls, so
       only the leaf table is needed — plus the per-test reset, emitted with the test bodies. *)
    let http_stub_leaf_names = [
      "stubHttp"; "stubHttpFailure"; "stubHttpTimeout";
      "httpCalled"; "httpCallCount"; "httpLastBody";
    ] in
    let http_stub_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.ApiTest" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        List.iter (fun name ->
          if List.mem name http_stub_leaf_names then
            http_stub_imports := name :: !http_stub_imports) exposed
      end) m.imports;
    (* `deadJobs` answers the dead-letter contents of a queue.  Its element type is opaque
       (`DeadJob`), so what a test can do with the list is count it or requeue from it — which
       is what the Racket surface allows too. *)
    let dead_jobs_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Queue" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        if List.mem "deadJobs" exposed then dead_jobs_imported := true
      end) m.imports;
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.String" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name string_leaf_names then begin
            string_imports := name :: !string_imports;
            if name = "String.toInt" || name = "String.indexOf" then maybe_imported := true
          end else match name with
            (* The proof predicates are compile-time only: they erase with every
               other proof, so importing one needs no runtime support. *)
            | "IsTrimmed" | "IsUpperCase" | "IsLowerCase" | "IsNonNegative"
            | "IsNonEmpty" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.String` export `%s` yet" other) exposed
      end) m.imports;
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Tuple" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          match name with
          | "Tuple2" | "Tuple3" | "Tuple2(..)" | "Tuple3(..)"
          | "Tuple2.first" | "Tuple2.second"
          | "Tuple3.first" | "Tuple3.second" | "Tuple3.third" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Tuple` export `%s` yet" other) exposed;
        tuple_imported := true
      end) m.imports;
    if !tuple_imported then begin
      let loc = Location.dummy_loc m.source_file in
      let component index = Printf.sprintf "%c" (Char.chr (Char.code 'A' + index)) in
      List.iter (fun (name, arity) ->
        let fields = List.init arity (fun index ->
          let field = List.nth ["first"; "second"; "third"] index in
          field, TParam (component index)) in
        let go_fields = List.map (fun (field, _) ->
          field, name ^ go_ident ~exported:true field) fields in
        Hashtbl.replace types.adts name {
          adt_tesl_name = name;
          adt_owner = "";
          adt_go_name = "teslrt." ^ name;
          adt_tag_type = "teslrt." ^ name ^ "Tag";
          adt_params = List.init arity (fun index ->
            String.lowercase_ascii (component index), component index);
          adt_variants = [
            { var_ctor = name; var_tag = "teslrt." ^ name ^ "Only";
              var_fields = fields; var_go_fields = go_fields; var_loc = loc };
          ];
          adt_loc = loc;
          adt_builtin = true;
        }) ["Tuple2", 2; "Tuple3", 3]
    end;
    (* The outbound `HttpResponse`: `{ status: Int, body: String, headers: List (Tuple2 String
       String) }`.  Its `body` is response TEXT, not a parsed value — an outbound call is
       ordinary program code, so a body it wants to read structurally goes through a codec
       like any other string, and `String.contains resp.body "…"` stays a String operation. *)
    if !httpclient_imported then begin
      let loc = Location.dummy_loc m.source_file in
      let header_pair = match Hashtbl.find_opt types.adts "Tuple2" with
        | Some info -> TAdt (info, [TString; TString])
        | None -> unsupported loc "Go backend needs `Tuple2` for HttpClient headers"
      in
      Hashtbl.replace types.records "HttpResponse" {
        rec_tesl_name = "HttpResponse";
        rec_owner = "";
        rec_go_name = "teslrt.HttpResponse";
        rec_fields = [ "status", TInt; "body", TString; "headers", TList header_pair ];
        rec_loc = loc;
      }
    end;
    (* `DeadJob` is opaque: the runtime carries the job's identity and nothing a program can
       read, so the element type is a runtime struct with no Tesl-visible fields. *)
    if !dead_jobs_imported then
      Hashtbl.replace types.records "DeadJob" {
        rec_tesl_name = "DeadJob";
        rec_owner = "";
        rec_go_name = "teslrt.DeadJob";
        rec_fields = [];
        rec_loc = Location.dummy_loc m.source_file;
      };
    (* `HttpRequest` is runtime-provided too: a plain record the dispatcher builds once per
       request.  Only the fields Tesl exposes are present, so an ejecting author is not
       handed the whole net/http surface. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Http" || import.module_name = "Tesl.ApiTest" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        (* Registered whenever `Tesl.ApiTest` is imported at all, not only when the type
           is named in the exposing list: a module may import just `statusOk` and still
           write `let r = get "/path"`, whose result IS this type. *)
        if import.module_name = "Tesl.ApiTest" then begin
          let api_response = {
            rec_tesl_name = "HttpResponse";
            rec_owner = "";
            rec_go_name = "teslrt.ApiResponse";
            rec_fields = [
              (* `body` is a PARSED JSON value, matching Racket: `api-test-field-access-ref`
                 normalises the response and hands back the parsed body, which is why
                 `resp.body.userId` reads like the JSON it checks. *)
              "status", TInt; "body", TJson; "headers", TDict (TString, TString);
            ];
            rec_loc = import.loc;
          } in
          (* The checker has ONE opaque `HttpResponse`, shared by `Tesl.ApiTest` and
             `Tesl.HttpClient`, because field access on it is untyped either way.  The two
             backends' RUNTIME shapes differ (a parsed body here, response text and a header
             list there), and a module may import both — lesson58 does — so the api-test
             shape is kept under a key no Tesl type name can spell, and the NAME resolves to
             the outbound response whenever `Tesl.HttpClient` is imported: that is the one an
             annotation like `-> HttpResponse` can mention. *)
          Hashtbl.replace types.records api_response_key api_response;
          if not !httpclient_imported then
            Hashtbl.replace types.records "HttpResponse" api_response
        end;
        if List.mem "HttpRequest" exposed then begin
          let string_dict = TDict (TString, TString) in
          (* No explicit Go field names are needed: `record_field_go_name` capitalises, and
             the runtime struct is written with exactly those names.  `rec_owner = ""`
             keeps the declaration from being emitted, the same way `Maybe` does it. *)
          Hashtbl.replace types.records "HttpRequest" {
            rec_tesl_name = "HttpRequest";
            rec_owner = "";
            rec_go_name = "teslrt.HttpRequest";
            rec_fields = [
              "method", TString; "path", TString;
              "cookies", string_dict; "headers", string_dict;
              "queryParameters", string_dict; "body", TString;
            ];
            rec_loc = import.loc;
          }
        end
      end) m.imports;
    (* `Either` is the same runtime-provided shape as `Maybe`: two variants, one
       payload each, provided by teslrt so it can cross module boundaries. *)
    let either_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Either" || import.module_name = "Tesl.EitherPrim" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          match name with
          | "Either" | "Either(..)" | "Left" | "Right" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `%s` export `%s` yet" import.module_name other) exposed;
        either_imported := true
      end) m.imports;
    (* `JobResult` is the queue counterpart: `JobOk job` and `JobFailed job error` — the
       failed case carries BOTH, as it does on the Racket side, so a test can assert on the
       payload of a job that failed. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.ApiTest" then begin
        let loc = import.loc in
        Hashtbl.replace types.adts "JobResult" {
          adt_tesl_name = "JobResult";
          adt_owner = "";
          adt_go_name = "teslrt.JobResult";
          adt_tag_type = "teslrt.JobResultTag";
          adt_params = ["job", "Payload"];
          adt_variants = [
            { var_ctor = "JobOk"; var_tag = "teslrt.JobResultOk";
              var_fields = ["job", TParam "Payload"];
              var_go_fields = ["job", "OkJob"]; var_loc = loc };
            { var_ctor = "JobFailed"; var_tag = "teslrt.JobResultFailed";
              var_fields = ["job", TParam "Payload"; "error", TString];
              var_go_fields = ["job", "FailedJob"; "error", "FailedError"]; var_loc = loc };
          ];
          adt_loc = loc;
          adt_builtin = true;
        }
      end) m.imports;
    (* `Result ok err` is the same runtime-provided shape as `Either`: two variants, one
       payload each, provided by teslrt so it can cross module boundaries.  Tesl.Result
       exports the type and its constructors only — there are no `Result.*` functions. *)
    let result_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Result" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          match name with
          | "Result" | "Result(..)" | "Ok" | "Err" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Result` export `%s` yet" other) exposed;
        result_imported := true
      end) m.imports;
    if !result_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "Result" {
        adt_tesl_name = "Result";
        adt_owner = "";
        adt_go_name = "teslrt.Result";
        adt_tag_type = "teslrt.ResultTag";
        adt_params = ["ok", "Ok"; "err", "Err"];
        adt_variants = [
          { var_ctor = "Ok"; var_tag = "teslrt.ResultOk";
            var_fields = ["value", TParam "Ok"];
            var_go_fields = ["value", "OkValue"]; var_loc = loc };
          { var_ctor = "Err"; var_tag = "teslrt.ResultErr";
            var_fields = ["error", TParam "Err"];
            var_go_fields = ["error", "ErrValue"]; var_loc = loc };
        ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    if !either_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "Either" {
        adt_tesl_name = "Either";
        adt_owner = "";
        adt_go_name = "teslrt.Either";
        adt_tag_type = "teslrt.EitherTag";
        adt_params = ["a", "A"; "b", "B"];
        adt_variants = [
          { var_ctor = "Left"; var_tag = "teslrt.EitherLeft";
            var_fields = ["value", TParam "A"];
            var_go_fields = ["value", "LeftValue"]; var_loc = loc };
          { var_ctor = "Right"; var_tag = "teslrt.EitherRight";
            var_fields = ["value", TParam "B"];
            var_go_fields = ["value", "RightValue"]; var_loc = loc };
        ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    if !maybe_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "Maybe" {
        adt_tesl_name = "Maybe";
        adt_owner = "";
        adt_go_name = "teslrt.Maybe";
        adt_tag_type = "teslrt.MaybeTag";
        adt_params = ["a", "A"];
        adt_variants = [
          { var_ctor = "Nothing"; var_tag = "teslrt.MaybeNothing";
            var_fields = []; var_go_fields = []; var_loc = loc };
          { var_ctor = "Something"; var_tag = "teslrt.MaybeSomething";
            var_fields = ["value", TParam "A"]; var_go_fields = []; var_loc = loc };
        ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    let adt_forms = List.filter_map (function
      | DType (TypeAdt { name; params; variants; loc }) -> Some (name, params, variants, loc)
      | _ -> None) m.decls in
    List.iter (fun (name, params, variants, loc) ->
      if variants = [] then unsupported loc "Go backend requires `%s` to have variants" name;
      List.iter (fun (variant : adt_variant) ->
        List.iter (fun (field : field_def) ->
          if field.proof_ann <> None then unsupported field.loc
            "Go backend does not support proof-carrying constructor field `%s.%s` yet"
            variant.ctor field.name;
          if field.checker <> None then unsupported field.loc
            "Go backend does not support `via` on constructor field `%s.%s` yet"
            variant.ctor field.name) variant.fields) variants;
      if Hashtbl.mem types.newtypes name || Hashtbl.mem types.records name
         || Hashtbl.mem types.adts name then
        unsupported loc "Go backend generated type name collision for `%s`" name;
      let go_name = package_ident name in
      (* Type parameters live in the type's own scope, so they are named
         independently of the package-level uniqueness table. *)
      let param_names = Hashtbl.create 4 in
      let go_params = List.map (fun param ->
        param, unique_ident param_names (go_ident ~exported:true param)) params in
      Hashtbl.replace types.adts name {
        adt_tesl_name = name;
        adt_owner = package;
        adt_go_name = go_name;
        adt_tag_type = unique_ident taken (go_name ^ "Tag");
        adt_params = go_params;
        adt_variants = List.map (fun (variant : adt_variant) -> {
          var_ctor = variant.ctor;
          var_tag = unique_ident taken (go_name ^ go_ident ~exported:true variant.ctor);
          var_fields = [];
          var_go_fields = [];
          var_loc = variant.loc;
        }) variants;
        adt_loc = loc;
        adt_builtin = false;
      }) adt_forms;
    (* Field types resolve only after every named type is registered, so records and
       ADTs may reference each other; a cycle would be an infinitely sized Go value
       and is rejected below. *)
    List.iter (fun (r : record_form) ->
      let info = Hashtbl.find types.records r.name in
      info.rec_fields <- List.map (fun (field : field_def) ->
        field.name, type_of_type_expr types field.type_expr) r.fields) record_forms;
    List.iter (fun (e : entity_form) ->
      let info = Hashtbl.find types.records e.name in
      info.rec_fields <- List.map (fun (field : field_def) ->
        field.name, type_of_type_expr types field.type_expr) e.fields) entity_forms;
    List.iter (fun (name, _, variants, _) ->
      let info = Hashtbl.find types.adts name in
      (* The ADT's own type parameters are in scope only here, while resolving the
         field types of its variants. *)
      let params = info.adt_params in
      List.iter2 (fun (variant : adt_variant) target ->
        target.var_fields <- List.map (fun (field : field_def) ->
          field.name, type_of_type_expr ~params types field.type_expr) variant.fields)
        variants info.adt_variants) adt_forms;
    let contained = function
      | TRecord info -> `Record info
      | TAdt (info, _) -> `Adt info
      | _ -> `Scalar
    in
    let rec reaches target visited ty =
      match contained ty with
      | `Scalar -> false
      | `Record info ->
        info.rec_tesl_name = target
        || (not (List.mem info.rec_tesl_name visited)
            && List.exists (fun (_, field_ty) ->
                 reaches target (info.rec_tesl_name :: visited) field_ty) info.rec_fields)
      | `Adt info ->
        info.adt_tesl_name = target
        || (not (List.mem info.adt_tesl_name visited)
            && List.exists (fun variant ->
                 List.exists (fun (_, field_ty) ->
                   reaches target (info.adt_tesl_name :: visited) field_ty) variant.var_fields)
                 info.adt_variants)
    in
    List.iter (fun (r : record_form) ->
      let info = Hashtbl.find types.records r.name in
      if List.exists (fun (_, field_ty) -> reaches r.name [r.name] field_ty) info.rec_fields then
        unsupported r.loc "Go backend does not support the recursive record `%s`" r.name)
      record_forms;
    List.iter (fun (e : entity_form) ->
      let info = Hashtbl.find types.records e.name in
      if List.exists (fun (_, field_ty) -> reaches e.name [e.name] field_ty) info.rec_fields then
        unsupported e.loc "Go backend does not support the recursive entity `%s`" e.name)
      entity_forms;
    List.iter (fun (name, _, _, loc) ->
      let info = Hashtbl.find types.adts name in
      if List.exists (fun variant ->
           List.exists (fun (_, field_ty) -> reaches name [name] field_ty) variant.var_fields)
           info.adt_variants then
        unsupported loc "Go backend does not support the recursive type `%s` yet" name)
      adt_forms;
    List.iter (function
      | DFunc _ | DTest _ -> ()
      | DType (TypeNewtype _) -> ()
      | DRecord _ -> ()
      | DType (TypeAlias { loc; _ }) ->
        unsupported loc "Go backend does not support transparent type aliases yet"
      | DType (TypeAdt _) -> ()
      | DEntity _ -> ()
      | DFact _ -> ()
      | DCodec _ -> ()
      (* A `database` declaration names a BACKEND and the entities it owns.  With
         `Memory` the store is the entity's own table variable, so the declaration adds
         no runtime structure of its own; Postgres would, and is refused until the driver
         lands rather than silently running against an in-memory store. *)
      | DDatabase d ->
        (* The typed form (`= Database { … }`) leaves its fields in `config_expr`; the Go
           pipeline does not run the desugar pass, so the same lowering the Racket
           backend gets is applied to this one declaration.  Reusing that function is the
           point — a second reading of the config block here would be a second place for
           `backend:` to be misread. *)
        let d = Desugar.desugar_database_config d in
        let backend = String.lowercase_ascii d.backend in
        if backend <> "memory" then unsupported d.loc
          "Go backend supports `backend: Memory` only, not `%s`"
          (String.capitalize_ascii (if d.backend = "" then "postgres" else d.backend));
        List.iter (fun entity ->
          if not (Hashtbl.mem types.entities entity) then unsupported d.loc
            "Go backend cannot find entity `%s` listed in database `%s`" entity d.name)
          d.entities
      (* A `capability` DECLARATION grants nothing at run time: the checker verifies every
         call against the declared set and forces the grant to propagate to callers, so the
         declaration has no emitted form — the same reason a `requires` clause has none. *)
      | DCapability _ -> ()
      | DConst c -> unsupported c.loc "Go backend does not support constants yet"
      (* Validated and registered above; the store variable is emitted with the tables. *)
      | DQueue _ -> ()
      | DChannel c -> unsupported c.loc "Go backend does not support channels yet"
      (* A `workers` block wires job types to worker functions.  With the folded `jobs:`
         form the wiring is already on the queue, and the workers only RUN on App
         activation, which is its own slice — so the declaration itself adds nothing. *)
      | DWorkers _ -> ()
      | DCache c -> unsupported c.loc "Go backend does not support caches yet"
      | DAgent a -> unsupported a.loc "Go backend does not support agents yet"
      | DEmail e -> unsupported e.loc "Go backend does not support email yet"
      (* A `capturer` is metadata about how a path segment is parsed and checked; the
         check function it names is an ordinary `check` the emitter already handles. *)
      | DCapture _ -> ()
      | DApi _ -> ()
      | DServer _ -> ()
      | DApiTest _ -> ()
      | DLoadTest t -> unsupported t.loc "Go backend does not support load-test yet") m.decls;
    let is_exported name = List.exists (function
      | ExportName exported -> exported = name
      | ExportAdt _ -> false) m.exports in
    let function_names = List.map (fun (fd : func_decl) -> fd.name) funcs in
    let graph = List.map (fun (fd : func_decl) ->
      let calls = ref [] in
      Ast_visitor.iter (function
        | EVar { name; _ } when List.mem name function_names && not (List.mem name !calls) ->
          calls := name :: !calls
        | _ -> ()) fd.body;
       fd.name, !calls) funcs in
    let test_roots = ref [] in
    List.iter (fun (test : test_form) ->
      List.iter (fun stmt ->
        List.iter (Ast_visitor.iter (function
          | EVar { name; _ } when List.mem name function_names ->
            if not (List.mem name !test_roots) then test_roots := name :: !test_roots
          | _ -> ())) (Ast.test_stmt_exprs stmt)) test.stmts) tests;
    let rec reachable visited name =
      if List.mem name visited then visited
      else
        let visited = name :: visited in
        match List.assoc_opt name graph with
        | None -> visited
        | Some calls -> List.fold_left reachable visited calls
    in
    let roots = !test_roots @ List.filter is_exported function_names in
    let reachable_names = List.fold_left reachable [] roots in
    let unreachable_private = List.filter_map (fun (fd : func_decl) ->
      if List.mem fd.name reachable_names then None else Some fd.name) funcs in
    let signatures = Hashtbl.create
      (List.length funcs + Hashtbl.length types.newtypes + Hashtbl.length types.records) in
    (* A fact's own signature: no parameters to type against (a proof term's arguments are
       proof SUBJECTS, not values the emitter checks) and the zero-size proof as result. *)
    List.iter (fun name ->
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name {
          params = []; result = TUnit;
          go_name = "struct{}{}"; sig_owner = ""; sig_needs_scope = false;
        }) fact_names;
    Hashtbl.iter (fun name info ->
      Hashtbl.add signatures name {
        params = [info.base];
        result = TNewtype info;
        go_name = info.go_name; sig_owner = info.owner; sig_needs_scope = false;
      }) types.newtypes;
    Hashtbl.iter (fun name info ->
      Hashtbl.add signatures name {
        params = List.map snd info.rec_fields;
        result = TRecord info;
        go_name = info.rec_go_name; sig_owner = info.rec_owner; sig_needs_scope = false;
      }) types.records;
    (* Each constructor is its own signature entry: the surface syntax names the
       constructor, and the variant it belongs to is recovered from the result type. *)
    Hashtbl.iter (fun _ info ->
      List.iter (fun variant ->
        if Hashtbl.mem signatures variant.var_ctor then unsupported variant.var_loc
          "Go backend generated name collision for constructor `%s`" variant.var_ctor;
        (* The result carries no type arguments: it exists so a constructor
           application can find its ADT, which then infers the arguments. *)
        Hashtbl.add signatures variant.var_ctor {
          params = List.map snd variant.var_fields;
          result = TAdt (info, []);
          go_name = variant.var_tag; sig_owner = info.adt_owner; sig_needs_scope = false;
        }) info.adt_variants) types.adts;
    (* Imported stdlib leaves are ordinary signatures whose Go name is a runtime
       function, so the existing call machinery emits them with no special case. *)
    (* A list leaf is registered only so the call arms can tell an imported name from
       an unresolved one; its params/result are computed per call site. *)
    List.iter (fun name ->
      let leaf = match set_leaf name with Some leaf -> leaf | None -> assert false in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name = leaf.set_go; sig_owner = ""; sig_needs_scope = false }) !set_imports;
    List.iter (fun name ->
      let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name = leaf.dict_go; sig_owner = ""; sig_needs_scope = false }) !dict_imports;
    List.iter (fun name ->
      (* A higher-order leaf has no runtime function at all — it lowers to a loop — so
         its entry exists only to mark the name as imported. *)
      let go_name = match list_leaf name with
        | Some leaf -> leaf.leaf_go
        | None -> "teslrt.EmittedAsALoop"
      in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name; sig_owner = ""; sig_needs_scope = false }) !list_imports;
    List.iter (fun name ->
      let params, result, go_name =
        match List.find_opt (fun (leaf, _, _, _) -> leaf = name) string_leaves with
        | Some (_, params, result, go_name) -> params, result, go_name
        | None -> assert false
      in
      let maybe_int () =
        match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [TInt])
        | None -> assert false
      in
      let maybe_of inner =
        match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [inner])
        | None -> assert false
      in
      let shape = function
        | `Str -> TString
        | `Int -> TInt
        | `Float -> TFloat
        | `MaybeFloat -> maybe_of TFloat
        | `CheckFloat -> TCheck TFloat
        | `Bool -> TBool
        | `MaybeInt -> maybe_int ()
        | `StrList -> TList TString
        | `CheckStr -> TCheck TString
        | `CheckInt -> TCheck TInt
      in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name { params = List.map shape params; result = shape result; go_name; sig_owner = ""; sig_needs_scope = false }) !string_imports;
    List.iter (fun name ->
      let maybe_string () =
        match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [TString])
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend `env` yields a Maybe; import `Tesl.Maybe`"
      in
      let params, result, go_name = match name with
        | "env" -> [TString], maybe_string (), "teslrt.EnvMaybe"
        | "envInt" -> [TString; TInt], TInt, "teslrt.EnvInt"
        | "envString" -> [TString; TString], TString, "teslrt.EnvString"
        | "requireEnv" -> [TString], TString, "teslrt.RequireEnv"
        (* `requireSecret` answers the stdlib's own SECRET newtype rather than a String: that is
           the whole point of it over `Secret (requireEnv …)` — the value redacts, compares in
           constant time, and can only reach a header through `HttpClient.bearer`. *)
        | "requireSecret" ->
          (match Hashtbl.find_opt types.newtypes "Secret" with
           | Some info -> [TString], TNewtype info, "teslrt.RequireSecret"
           | None -> unsupported (Location.dummy_loc m.source_file)
             "Go backend `requireSecret` needs the `Secret` type")
        | "randomInt" -> [TInt; TInt], TInt, "teslrt.RandomInt"
        (* Like `nowMillis`, a VALUE in Tesl's type table, written `randomFloat()`. *)
        | "randomFloat" -> [], TFloat, "teslrt.RandomFloat"
        | "generateId" -> [], TString, "teslrt.GenerateId"
        | "generatePrefixedId" -> [TString], TString, "teslrt.GeneratePrefixedId"
        | other -> unsupported (Location.dummy_loc m.source_file)
          "Go backend does not support the effect leaf `%s` yet" other
      in
      Hashtbl.replace signatures name
        { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
      !effect_imports;
    List.iter (fun name ->
      let posix = match Hashtbl.find_opt types.newtypes "PosixMillis" with
        | Some info -> TNewtype info
        | None -> assert false
      in
      let params, result, go_name = match name with
        (* `nowMillis` is a VALUE in Tesl's type table, written `nowMillis()`; the
           empty-argument call normalises to a no-parameter call here. *)
        | "nowMillis" -> [], posix, "teslrt.NowMillis"
        | "durationMs" -> [posix], TInt, "teslrt.DurationMs"
        | "addMs" -> [posix; TInt], posix, "teslrt.AddMs"
        | "subtractMs" -> [posix; TInt], posix, "teslrt.SubtractMs"
        | "diffMs" -> [posix; posix], TInt, "teslrt.DiffMs"
        | "Time.posixToSeconds" -> [posix], TInt, "teslrt.PosixToSeconds"
        | "Time.secondsToPosix" -> [TInt], posix, "teslrt.SecondsToPosix"
        | other -> unsupported (Location.dummy_loc m.source_file)
          "Go backend does not support `Tesl.Time` export `%s` yet" other
      in
      Hashtbl.replace signatures name
        { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
      !time_imports;
    if !crypto_imports <> [] then begin
      let loc = Location.dummy_loc m.source_file in
      let secret = match Hashtbl.find_opt types.newtypes "Secret" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.Crypto` needs its `Secret` type"
      in
      let signature = match Hashtbl.find_opt types.newtypes "Signature" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.Crypto` needs its `Signature` type"
      in
      List.iter (fun name ->
        let params, result, go_name = match name with
          (* `hmacSha256` is the expert alias for the same function. *)
          | "Crypto.signWith" | "Crypto.hmacSha256" ->
            [secret; TString], signature, "teslrt.SignWith"
          (* A verification is a CHECK: it answers the verified payload or fails 401, and the
             constant-time compare lives inside it — which is why there is no
             `constantTimeEquals` on the surface to get wrong. *)
          | "Crypto.checkSignature" ->
            [secret; signature; TString], TCheck TString, "teslrt.CheckSignature"
          | "Crypto.signatureHex" -> [signature], TString, "teslrt.SignatureHex"
          | "Crypto.signatureFromHex" -> [TString], signature, "teslrt.SignatureFromHex"
          | "Crypto.signatureBase64" -> [signature], TString, "teslrt.SignatureBase64"
          | "Crypto.signatureFromBase64" -> [TString], signature, "teslrt.SignatureFromBase64"
          | "Crypto.fingerprint" -> [TString], TString, "teslrt.Fingerprint"
          | "Crypto.keyFingerprint" -> [secret], TString, "teslrt.KeyFingerprint"
          (* A VALUE in Tesl's type table, written `randomToken()`. *)
          | "Crypto.randomToken" -> [], TString, "teslrt.RandomToken"
          | "Crypto.sha256" -> [TString], TString, "teslrt.Sha256Hex"
          | "Crypto.sha512" -> [TString], TString, "teslrt.Sha512Hex"
          | other -> unsupported loc
            "Go backend does not support `Tesl.Crypto` export `%s` yet" other
        in
        Hashtbl.replace signatures name
          { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        !crypto_imports
    end;
    (* The outbound verbs.  A header list is `List (Tuple2 String String)`; the response is
       the record registered above.  `bearer`/`secretHeader` take a `Secret String`, which is
       a secret newtype — its Go type comes from the argument, so the parameter is typed as
       the newtype the call site has rather than being fixed here. *)
    if !httpclient_imports <> [] then begin
      let loc = Location.dummy_loc m.source_file in
      let response = match Hashtbl.find_opt types.records "HttpResponse" with
        | Some info -> TRecord info
        | None -> unsupported loc "Go backend `Tesl.HttpClient` needs its response type"
      in
      let header_pair = match Hashtbl.find_opt types.adts "Tuple2" with
        | Some info -> TAdt (info, [TString; TString])
        | None -> unsupported loc "Go backend needs `Tuple2` for HttpClient headers"
      in
      let headers = TList header_pair in
      List.iter (fun name ->
        let params, result, go_name = match name with
          | "HttpClient.get" -> [TString; headers], response, "teslrt.HttpGet"
          | "HttpClient.post" -> [TString; headers; TString], response, "teslrt.HttpPost"
          | "HttpClient.put" -> [TString; headers; TString], response, "teslrt.HttpPut"
          | "HttpClient.delete" -> [TString; headers], response, "teslrt.HttpDelete"
          (* The secret parameter is typed `TParam` so a call passes its own secret newtype
             through unchanged: the runtime takes a `teslrt.SecretString`, which is what every
             secret newtype's Go representation is. *)
          | "HttpClient.bearer" -> [TParam "Secret"], header_pair, "teslrt.HttpBearer"
          | "HttpClient.secretHeader" ->
            [TString; TParam "Secret"], header_pair, "teslrt.HttpSecretHeader"
          | other -> unsupported loc
            "Go backend does not support `Tesl.HttpClient` export `%s` yet" other
        in
        Hashtbl.replace signatures name
          { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        !httpclient_imports
    end;
    (* The outbound-HTTP double.  A stub DECLARATION is a statement whose Tesl type is Unit,
       so the runtime entry points answer `struct{}` like `enqueue` does. *)
    List.iter (fun name ->
      let params, result, go_name = match name with
        | "stubHttp" -> [TString; TString; TInt; TString], TUnit, "teslrt.StubHttp"
        | "stubHttpFailure" -> [TString; TString; TString], TUnit, "teslrt.StubHttpFailure"
        | "stubHttpTimeout" -> [TString; TString], TUnit, "teslrt.StubHttpTimeout"
        | "httpCalled" -> [TString; TString], TBool, "teslrt.HttpCalled"
        | "httpCallCount" -> [TString; TString], TInt, "teslrt.HttpCallCount"
        | "httpLastBody" -> [TString; TString], TString, "teslrt.HttpLastBody"
        | other -> unsupported (Location.dummy_loc m.source_file)
          "Go backend does not support the HTTP-stub leaf `%s` yet" other
      in
      Hashtbl.replace signatures name
        { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
      !http_stub_imports;
    (* An imported local module contributes its exported functions with the OWNING
       package attached, so every reference to them is qualified. *)
    let imported_packages = ref [] in
    List.iter (fun (import : import_decl) ->
      match List.find_opt (fun (dependency : module_exports) ->
              dependency.ex_module = import.module_name) dependencies with
      | None -> ()
      | Some dependency ->
        (* `import M` with no `exposing` list is the QUALIFIED-ONLY form: references are
           written `M.Name`.  Every entry the dependency emitted from is brought in, keyed
           by its bare name, and the qualified reference resolves through the prefix strip
           in `type_of_type_expr` / `normalize_call_head`.  Bringing in more than the
           source names cannot widen what compiles: the checker has already rejected any
           use of a name this module did not import. *)
        let exposed = match import.names with
          | ImportAll ->
            List.of_seq (Hashtbl.to_seq_keys dependency.ex_signatures)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.records)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.newtypes)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.adts)
          | ImportExposing names -> names
        in
        if not (List.mem dependency.ex_package !imported_packages) then
          imported_packages := dependency.ex_package :: !imported_packages;
        register_imported_module ~loc:import.loc ~exposed types signatures dependency)
      m.imports;
    List.iter (fun (fd : func_decl) ->
      if Hashtbl.mem signatures fd.name then unsupported fd.loc
        "Go backend generated name collision for `%s`" fd.name;
      let params = List.map (fun (binding : binding) ->
        type_of_type_expr types binding.type_expr) fd.params in
      let exported = is_exported fd.name in
      let go_name = unique_ident taken (go_ident ~exported fd.name) in
      (* `-> n: T ::: P` means different things by KIND: a `check`/`auth` answers a
         `Check T` (it can reject), while a plain `fn`/`worker` answers T carrying a proof —
         and the proof erases, so the result is just T.  Typing every attached return as a
         Check rejected an ordinary proof-passing `fn` as a "result type mismatch". *)
      let result = match type_of_return_spec types fd.return_spec, fd.kind with
        (* A `check`/`auth` can REJECT, so whatever its return spec says about the value, the
           result is a `Check` of it: `-> String ? Authenticated` on an `auth` is
           `Check[string]`, not `string`. *)
        | (TCheck _ as result), (CheckKind | AuthKind) -> result
        | result, (CheckKind | AuthKind) -> TCheck result
        | TCheck inner, (FnKind | WorkerKind | DeadWorkerKind | HandlerKind | MainKind) ->
          inner
        | result, _ -> result
      in
      Hashtbl.add signatures fd.name {
        params;
        result;
        go_name;
        sig_owner = package;
        (* The `requires` clause is the marker: a function that may write to the response
           takes the request scope, and the checker guarantees its callers declare the same
           capability — so the scope reaches it without any call-graph analysis. *)
        sig_needs_scope = List.mem "cookieCap" fd.capabilities;
      }) funcs;
    (* Every package in a multi-module program lives under ONE Go module path, so an
       importer and its dependency agree on the import path. *)
    let module_path = match project_path with
      | Some path -> path
      | None -> "tesl.generated/" ^ package
    in
    current_package := package;
    current_types := Some types;
    let source =
      module_source ~imported_packages:!imported_packages ~codecs ~apis ~servers ~capturers
        ~unreachable:(List.filter_map (fun name ->
          match Hashtbl.find_opt signatures name with
          | Some signature -> Some signature.go_name
          | None -> None) unreachable_private)
        module_path package signatures types funcs in
    let tests_source =
      if tests = [] && api_tests = [] then None
      else Some (test_source ~imported_packages:!imported_packages ~api_tests module_path
                   package signatures tests) in
    let needs_runtime = contains_go_code source "teslrt." ||
      match tests_source with Some text -> contains_go_code text "teslrt." | None -> false in
    (* The lint configuration is part of the emitter contract, versioned with this
       file: `exhaustive` is the static half of the ADT exhaustiveness mitigation and
       only sees a tag switch when a `default` arm does NOT count as covering. *)
    let lint_config =
      "# Generated by the Tesl Go backend. Every check here is part of the emitter\n\
       # contract: a finding on emitted code is an emitter bug, never a suppression.\n\
       version: \"2\"\n\
       linters:\n\
       \  enable:\n\
       \    - exhaustive\n\
       \  settings:\n\
       \    exhaustive:\n\
       \      default-signifies-exhaustive: false\n"
    in
    let artifacts = [
      (* The go directive tracks the toolchain the gates pin (maintainer: use the latest
         stable Go).  It also sets the language version the emitted code may use, so it has
         to be at least as new as anything the runtime relies on. *)
      { path = "go.mod"; contents = Printf.sprintf "module %s\n\ngo 1.26\n" module_path };
      { path = ".golangci.yml"; contents = lint_config };
      { path = "internal/" ^ package ^ "/module.go"; contents = source };
    ] in
    let artifacts = match tests_source with
      | None -> artifacts
      | Some contents -> artifacts @ [{ path = "internal/" ^ package ^ "/module_test.go"; contents }]
    in
    let artifacts =
      if not needs_runtime then artifacts
      else begin
        (* The HTTP half of the runtime ships ONLY to a module that serves HTTP.  Emitting
           it everywhere pulled `net/http` — and its whole dependency chain — into every
           program, including pure-computation ones: govulncheck then reported a real
           stdlib vulnerability (GO-2026-5972, reachable as
           `teslrt.init -> http.init -> asn1.Unmarshal`) against a module that never opens
           a socket.  A dependency a program does not use should not be in it, for
           vulnerability surface as much as for the eject story. *)
        (* Declaring a `server` is the common way to need the HTTP half, but not the only one:
           an `auth` function takes a `teslrt.HttpRequest`, and a module can declare one while
           the `server` that routes to it lives elsewhere.  So the test is what the emitted code
           REFERENCES, not what it declares — otherwise the package compiles against a runtime
           file that was not shipped (`undefined: teslrt.HttpRequest`), which is the fail-open
           version of the same size argument. *)
        let mentions name =
          contains_go_code source name
          || (match tests_source with
              | Some text -> contains_go_code text name
              | None -> false)
        in
        let serves_http = servers <> []
          || List.exists mentions
               [ "teslrt.HttpRequest"; "teslrt.ApiResponse"; "teslrt.ApiRequest";
                 "teslrt.JsonValue"; "teslrt.RequestScope"; "teslrt.Server" ] in
        (* `apitest_json.go` travels with `apitest.go`: the untyped JSON view exists to inspect
           a RESPONSE, so a module that serves no HTTP has no use for it. *)
        let http_only = [ "server.go"; "request.go"; "apitest.go"; "apitest_json.go" ] in
        artifacts @ List.filter_map (fun (name, contents) ->
          if (not serves_http) && List.mem name http_only then None
          else Some { path = "internal/teslrt/" ^ name; contents })
          Embedded_go_runtime.files
      end
    in
    Ok (artifacts, { ex_module = m.module_name; ex_package = package;
                     ex_types = types; ex_signatures = signatures })
  with Unsupported error -> Error [error]

(* Emits a whole program: one Go package per Tesl module, all under the entry module's
   Go module path.  `modules` must contain the entry and every local module it imports,
   transitively; the caller resolves that graph (compile.ml owns file resolution).
   Shared artifacts — go.mod, the lint config, the runtime — are emitted once.

   Modules are compiled DEPENDENCY-FIRST so an importer receives the very tables its
   dependency emitted from.  That is what makes a type crossing the boundary the same
   type on both sides: `go_type` equality is structural, so a re-derived record would
   compare unequal to the original even when it describes the same Tesl declaration. *)
let compile_project ?(mode=Release) ~(entry : module_form) (modules : module_form list) =
  let project_path = "tesl.generated/" ^ package_name entry.module_name in
  let local_names = List.map (fun (m : module_form) -> m.module_name) modules in
  let dependencies_of (m : module_form) =
    List.filter_map (fun (import : import_decl) ->
      if List.mem import.module_name local_names then Some import.module_name else None)
      m.imports
  in
  (* Topological order.  A cycle cannot appear here — compile.ml rejects one before this
     point — but the counter keeps a malformed graph from looping forever rather than
     failing. *)
  let rec order done_names remaining passes =
    if remaining = [] then Ok (List.rev done_names)
    else if passes = 0 then
      Error [{ loc = Location.dummy_loc entry.source_file;
               message = "Go backend could not order the module graph" }]
    else
      let ready, blocked = List.partition (fun (m : module_form) ->
        List.for_all (fun name -> List.mem name done_names) (dependencies_of m)) remaining in
      if ready = [] then
        Error [{ loc = Location.dummy_loc entry.source_file;
                 message = "Go backend could not order the module graph" }]
      else
        order (List.rev_append (List.map (fun (m : module_form) -> m.module_name) ready)
                 done_names) blocked (passes - 1)
  in
  match order [] modules (List.length modules + 1) with
  | Error errors -> Error errors
  | Ok ordered_names ->
    let ordered = List.filter_map (fun name ->
      List.find_opt (fun (m : module_form) -> m.module_name = name) modules) ordered_names in
    let rec emit acc exports = function
      | [] -> Ok (List.rev acc)
      | (m : module_form) :: rest ->
        (match compile_module ~mode ~dependencies:exports ~project_path m with
         | Error errors -> Error errors
         | Ok (artifacts, module_exports) ->
           emit (List.rev_append artifacts acc) (module_exports :: exports) rest)
    in
    (match emit [] [] ordered with
     | Error errors -> Error errors
     | Ok artifacts ->
       (* On a duplicate path the FIRST wins, and dependencies are emitted first, so the
          shared artifacts (go.mod, lint config, runtime) come from whichever module
          needed them earliest — they are byte-identical either way. *)
       let seen = Hashtbl.create 16 in
       Ok (List.filter (fun (artifact : artifact) ->
         if Hashtbl.mem seen artifact.path then false
         else begin Hashtbl.add seen artifact.path (); true end) artifacts))
