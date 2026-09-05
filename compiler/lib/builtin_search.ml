(** Pure builtin discovery, shared by the native CLI and browser. Types come
    from checker schemes; prose-shaped syntax entries never enter type matching.
    This is alpha-equivalence, not unification or a proof of callability. *)
open Type_system

let version = 1
let limit = 20
let max_query_bytes = 256
let quote s = "\"" ^ Stdlib_docs.json_escape s ^ "\""
let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]"
let nullable f = function None -> "null" | Some x -> f x
let lower = String.lowercase_ascii
let contains hay needle =
  let n = String.length needle in
  let rec loop i = i + n <= String.length hay &&
    (String.sub hay i n = needle || loop (i + 1)) in
  loop 0
let prefix s p = String.starts_with ~prefix:p s

let id (e : Stdlib_docs.entry) =
  e.module_ ^ "/" ^ e.name ^ "/" ^ Stdlib_docs.kind_label e.kind

let entries =
  (* Generated constructor names are real aliases, including in the exported
     catalog and its identity. Otherwise adding a time zone could change search
     results without invalidating a client's cached catalog. Resolve ownership
     through the documentation catalog rather than a second family map. *)
  let generated_names = Tz_zones.ctor_names @ Currencies.ctor_names
    @ Currencies.money_ctor_names @ Units_catalog.exported_names
    @ List.map fst Units_catalog.money_rate_aliases in
  let family_aliases = List.concat_map (fun name ->
    List.map (fun e -> id e, name) (Stdlib_docs.lookup name)) generated_names in
  List.map (fun (e : Stdlib_docs.entry) -> { e with aliases = List.sort_uniq String.compare
    (e.aliases @ List.filter_map (fun (owner, alias) ->
      if owner = id e && alias <> e.name then Some alias else None) family_aliases) }) Stdlib_docs.entries
  |> List.sort_uniq (fun a b -> String.compare (id a) (id b))

let scheme (e : Stdlib_docs.entry) =
  match e.kind with
  | KFunction _ | KValue -> Stdlib_docs.scheme_of e.name
  | KType _ | KFact _ | KSyntax _ | KCapability | KConfig | KFamily _ -> None

let type_variables ty =
  let rec visit seen = function
    | TVar v -> if List.mem v seen then seen else seen @ [v]
    | TCon _ -> seen
    | TApp (a, b) | TFun (a, b) -> visit (visit seen a) b in
  visit [] ty

let quantified_variables s =
  type_variables s.mono |> List.mapi (fun i v -> i, v)
  |> List.filter_map (fun (i, v) -> if List.mem v s.vars then Some i else None)

let closed_scheme s = List.for_all (fun v -> List.mem v s.vars) (type_variables s.mono)

(* Stable, first-occurrence variable IDs, independent of compiler allocation. *)
let canonical_type ty =
  let vars = Hashtbl.create 8 in
  let rec visit = function
    | TVar v ->
      let n = match Hashtbl.find_opt vars v with
        | Some n -> n
        | None -> let n = Hashtbl.length vars in Hashtbl.add vars v n; n in
      Printf.sprintf {|{"tag":"var","id":%d}|} n
    | TCon name -> {|{"tag":"con","name":|} ^ quote name ^ "}"
    | TApp (f, a) -> {|{"tag":"app","fn":|} ^ visit f ^ {|,"arg":|} ^ visit a ^ "}"
    | TFun (a, b) -> {|{"tag":"fun","arg":|} ^ visit a ^ {|,"result":|} ^ visit b ^ "}"
  in
  (* OCaml argument evaluation order must not determine variable numbering. *)
  let rec ordered = function
    | TVar v as t -> ignore (visit t); ignore v
    | TCon _ -> ()
    | TApp (a, b) | TFun (a, b) -> ordered a; ordered b in
  ordered ty;
  visit ty

let parameters (e : Stdlib_docs.entry) =
  match e.kind, scheme e with
  | KFunction names, Some sch ->
    let args, _ = split_fun_type sch.mono in
    let args = match args, names with [TCon "Unit"], [] -> [] | _ -> args in
    if List.length names = List.length args then Some names else None
  | KValue, Some _ -> Some []
  | (KFunction _ | KValue | KType _ | KFact _ | KSyntax _ | KCapability | KConfig | KFamily _), _ -> None

let import (e : Stdlib_docs.entry) =
  if e.module_ = "" || List.mem e.name Type_system.always_available_stdlib_names then None
  else match e.kind with
    | KSyntax _ | KFamily _ | KConfig -> None
    | KFunction _ | KValue | KType _ | KFact _ | KCapability ->
      Some (Printf.sprintf "import %s exposing [%s]" e.module_ e.name)

let entry_json (e : Stdlib_docs.entry) =
  let shape = scheme e in
  let signature = match Stdlib_docs.render e with Ok s -> s | Error s -> s in
  Printf.sprintf
    {|{"id":%s,"name":%s,"module":%s,"kind":%s,"aliases":%s,"signature":%s,"doc":%s,"import":%s,"parameter_labels":%s,"type":%s,"quantified_variables":%s,"structural_status":%s,"requirements":{"capabilities":%s,"capabilities_status":%s,"proofs_status":"unavailable","additional_requirements_status":"unavailable"}}|}
    (quote (id e)) (quote e.name) (quote e.module_) (quote (Stdlib_docs.kind_label e.kind))
    (array quote e.aliases) (quote signature) (quote e.doc) (nullable quote (import e))
    (nullable (array quote) (parameters e))
    (nullable (fun s -> canonical_type s.mono) shape)
    (nullable (fun s -> array string_of_int (quantified_variables s)) shape)
    (quote (match shape with None -> "text-only" | Some s -> if closed_scheme s then "checker-scheme" else "incomplete-scheme"))
    (array quote (stdlib_capabilities_of e.name))
    (quote (if Option.is_some shape then "known-direct" else "unavailable"))

(* A content identity, not a security digest. Delivery integrity uses SHA-256.
   Includes signatures, docs, labels, aliases, requirements and structured types. *)
let catalog_rows = lazy (array entry_json entries)
let catalog_id = lazy (Digest.to_hex (Digest.string (Lazy.force catalog_rows)))
let catalog_json () = Printf.sprintf
  {|{"version":%d,"catalog_id":%s,"scope":"builtins","entries":%s}|}
  version (quote (Lazy.force catalog_id)) (Lazy.force catalog_rows)

type query_type = Var of string | Con of string | App of query_type * query_type | Fun of query_type * query_type
type token = Ident of string | Arrow | Left | Right
exception Invalid_query of string
let invalid s = raise (Invalid_query s)

let parse_type source =
  let n = String.length source in
  let ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
  let ident_char c = ident_start c || (c >= '0' && c <= '9') || c = '_' || c = '.' in
  let rec lex i acc =
    if List.length acc > 96 then invalid "Type query has too many tokens.";
    if i = n then List.rev acc else
    match source.[i] with
    | ' ' | '\t' | '\n' | '\r' -> lex (i + 1) acc
    | '(' -> lex (i + 1) (Left :: acc)
    | ')' -> lex (i + 1) (Right :: acc)
    | '-' when i + 1 < n && source.[i + 1] = '>' -> lex (i + 2) (Arrow :: acc)
    | c when ident_start c ->
      let j = ref (i + 1) in
      while !j < n && ident_char source.[!j] do incr j done;
      let name = String.sub source i (!j - i) in
      if List.mem name ["requires"; "fact"; "fn"; "check"] then
        invalid "Proofs, capabilities and labels are not supported in type queries; search their names instead.";
      lex !j (Ident name :: acc)
    | _ -> invalid "Use names, application, parentheses and ->. Labels, wildcards and proof/effect syntax are not supported." in
  let tokens = ref (lex 0 []) in
  let rec arrow depth =
    if depth > 24 then invalid "Type query is nested too deeply.";
    let a = application depth in
    match !tokens with
    | Arrow :: rest -> tokens := rest; let b = arrow (depth + 1) in Fun (a, b)
    | _ -> a
  and application depth =
    let a = atom depth in
    let rec more a = match !tokens with
      | (Ident _ | Left) :: _ -> let b = atom depth in more (App (a, b))
      | _ -> a in
    more a
  and atom depth = match !tokens with
    | Ident s :: rest -> tokens := rest;
      if s.[0] >= 'a' && s.[0] <= 'z' then Var s else Con s
    | Left :: rest -> tokens := rest; let t = arrow (depth + 1) in
      (match !tokens with Right :: rest -> tokens := rest; t | _ -> invalid "Missing closing parenthesis.")
    | _ -> invalid "Expected a type name or parenthesized type." in
  let result = arrow 0 in
  if !tokens <> [] then invalid "Unexpected token after type.";
  result

(* Bijection rather than a wildcard/unifier: a -> a differs from a -> b,
   and a never silently specializes to a nominal type such as Int32. *)
let matches query ty =
  let forward = Hashtbl.create 8 and reverse = Hashtbl.create 8 in
  let rec go q t = match q, t with
    | Var a, TVar b ->
      (match Hashtbl.find_opt forward a, Hashtbl.find_opt reverse b with
       | None, None -> Hashtbl.add forward a b; Hashtbl.add reverse b a; true
       | Some b', Some a' -> b = b' && a = a'
       | _ -> false)
    | Con a, TCon b -> a = b
    | App (a, b), TApp (x, y) | Fun (a, b), TFun (x, y) -> go a x && go b y
    | _ -> false in
  go query ty

let words s = String.split_on_char ' ' (String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s)
  |> List.filter ((<>) "")

let text_score query (e : Stdlib_docs.entry) =
  let q = lower query and name = lower e.name and module_ = lower e.module_ in
  let aliases = List.map lower e.aliases in
  let names = name :: aliases in
  if q = "" then Some 0
  else if name = q then Some 0
  else if List.mem q aliases then
    Some (if List.exists (fun family -> id family = id e) Stdlib_docs.family_entries then 2 else 1)
  else if List.exists (fun n -> prefix n q) names then Some 3
  else if List.exists (fun n -> prefix (List.hd (List.rev (String.split_on_char '.' n))) q) names then Some 4
  else if q = module_ then Some 5
  else if List.for_all (fun w -> List.exists (fun n -> contains n w) (module_ :: names)) (words q) then Some 6
  else if List.for_all (fun w -> contains (String.concat " " (lower e.doc :: module_ :: names)) w) (words q) then Some 7
  else None

type response = { query : string; mode : string; error : string option; total : int; results : Stdlib_docs.entry list }

let search query =
  let query = String.trim query in
  let mode = ref "text" in
  try
    if String.length query > max_query_bytes then invalid "Query exceeds 256 UTF-8 bytes.";
    let text_query, type_query =
      match String.index_opt query ':' with
      | Some i when i + 1 < String.length query && query.[i + 1] = ':' ->
        mode := "type";
        String.trim (String.sub query 0 i), Some (parse_type (String.sub query (i + 2) (String.length query - i - 2)))
      | Some _ -> mode := "type"; invalid "Parameter labels are not supported. Use String -> Int, or name :: TYPE."
      | None when contains query "->" -> mode := "type"; "", Some (parse_type query)
      | None -> query, None in
    let scored = List.filter_map (fun e ->
      let shape_ok = match type_query with
        | None -> true
        | Some q -> (match scheme e with
          | Some s -> closed_scheme s && matches q s.mono
          | None -> false) in
      if shape_ok then Option.map (fun score -> score, e) (text_score text_query e) else None) entries in
    (* Typo fallback only when there are no direct results; bounded by the
       existing catalog suggestion function. Never makes a type near-match. *)
    let scored = if scored = [] && type_query = None && String.length query >= 3 && List.length (words query) = 1 then
      let suggestions = Stdlib_docs.suggestions query in
      List.filter_map (fun e -> if List.mem e.Stdlib_docs.name suggestions then Some (8, e) else None) entries
      else scored in
    let ordered = List.sort (fun (a, x) (b, y) -> let c = compare a b in if c = 0 then String.compare (id x) (id y) else c) scored in
    { query; mode = !mode; error = None; total = List.length ordered;
      results = List.filteri (fun i _ -> i < limit) ordered |> List.map snd }
  with Invalid_query message -> { query; mode = !mode; error = Some message; total = 0; results = [] }

let response_json r = Printf.sprintf
  {|{"version":%d,"catalog_id":%s,"scope":"builtins","query":%s,"mode":%s,"error":%s,"total":%d,"limit":%d,"results":%s}|}
  version (quote (Lazy.force catalog_id)) (quote r.query) (quote r.mode)
  (nullable quote r.error) r.total limit (array entry_json r.results)

let search_json query = response_json (search query)
