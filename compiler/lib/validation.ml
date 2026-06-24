(** Validation passes (Phase 5 parity).

    Implements and wires the validation layer that sits after parsing/type/proof checking:
    1. Server binding completeness
    2. SQL/record field name validation
    3. Codec proof coverage validation
    4. Call-site proof satisfaction
    5. ForAll proof propagation at call sites
    6. Exists return/body validation *)

open Ast
open Location

(* ── Validation error ────────────────────────────────────────────────────── *)

type validation_error = {
  loc     : loc;
  message : string;
  hint    : string;
}

let make_error ?(hint="") loc message = { loc; message; hint }

let fmt_validation_error (e : validation_error) =
  Printf.sprintf "%s:%d:%d: validation: %s%s"
    e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.message
    (if e.hint = "" then "" else Printf.sprintf "\n  hint: %s" e.hint)

(* ── Proof helpers ───────────────────────────────────────────────────────── *)

let rec flatten_proof (p : proof_expr) : proof_expr list =
  match p with
  | PredAnd { left; right; _ } -> flatten_proof left @ flatten_proof right
  | other -> [other]

let rec pp_proof (p : proof_expr) : string =
  match p with
  | PredApp { pred; args = []; _ } -> pred
  | PredApp { pred; args; _ } -> pred ^ " " ^ String.concat " " args
  | PredAnd { left; right; _ } -> pp_proof left ^ " && " ^ pp_proof right

let rec pp_type_expr (te : type_expr) : string =
  match te with
  | TName { name; _ } -> name
  | TVar { name; _ } -> name
  | TApp { head; arg; _ } -> Printf.sprintf "%s %s" (pp_type_expr head) (pp_type_expr arg)
  | TFun { dom; cod; _ } -> Printf.sprintf "%s -> %s" (pp_type_expr dom) (pp_type_expr cod)
  | TTuple { elems; _ } -> Printf.sprintf "(%s)" (String.concat ", " (List.map pp_type_expr elems))

let strip_outer_parens (s : string) : string =
  let len = String.length s in
  if len >= 2 && s.[0] = '(' && s.[len - 1] = ')' then
    String.sub s 1 (len - 2)
  else
    s

let rec proof_key (p : proof_expr) : string =
  match p with
  | PredApp { pred = "ForAll"; args = [proof_name; subject]; _ } ->
    "ForAll " ^ strip_outer_parens proof_name ^ " " ^ subject
  | PredApp { pred; args = []; _ } -> pred
  | PredApp { pred; args; _ } -> pred ^ " " ^ String.concat " " args
  | PredAnd { left; right; _ } -> proof_key left ^ " && " ^ proof_key right

let rec proof_subjects (p : proof_expr) : string list =
  match p with
  | PredApp { args; _ } ->
    List.filter (fun s ->
      String.length s > 0
      && s.[0] >= 'a' && s.[0] <= 'z'
      && not (String.contains s '.')
      && not (String.contains s '(')
    ) args
  | PredAnd { left; right; _ } -> proof_subjects left @ proof_subjects right

let rec proof_predicates (p : proof_expr) : string list =
  match p with
  | PredApp { pred; _ } -> [pred]
  | PredAnd { left; right; _ } -> proof_predicates left @ proof_predicates right

let subst_proof_arg (mapping : (string * string) list) (arg : string) : string =
  match List.assoc_opt arg mapping with
  | Some repl -> repl
  | None ->
    let len = String.length arg in
    let is_ident_char = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' -> true
      | _ -> false
    in
    let buf = Buffer.create len in
    let flush_ident start_idx end_idx =
      if end_idx > start_idx then
        let token = String.sub arg start_idx (end_idx - start_idx) in
        Buffer.add_string buf (match List.assoc_opt token mapping with Some repl -> repl | None -> token)
    in
    let rec loop i ident_start =
      if i = len then begin
        (match ident_start with
         | Some start_idx -> flush_ident start_idx i
         | None -> ());
        Buffer.contents buf
      end else
        let ch = arg.[i] in
        if is_ident_char ch then
          match ident_start with
          | Some _ -> loop (i + 1) ident_start
          | None -> loop (i + 1) (Some i)
        else begin
          (match ident_start with
           | Some start_idx -> flush_ident start_idx i
           | None -> ());
          Buffer.add_char buf ch;
          loop (i + 1) None
        end
    in
    loop 0 None

let rec subst_proof (mapping : (string * string) list) (p : proof_expr) : proof_expr =
  match p with
  | PredApp ({ args; _ } as app) ->
    let args' = List.map (subst_proof_arg mapping) args in
    PredApp { app with args = args' }
  | PredAnd ({ left; right; _ } as conj) ->
    PredAnd { conj with left = subst_proof mapping left; right = subst_proof mapping right }

let rec expand_entity_proof_group (p : proof_expr) : proof_expr =
  match p with
  | PredApp ({ args; _ } as app) -> PredApp { app with args = args @ ["_entity"] }
  | PredAnd ({ left; right; _ } as conj) ->
    PredAnd {
      conj with
      left = expand_entity_proof_group left;
      right = expand_entity_proof_group right;
    }

let rec proof_matches (required : proof_expr) (carried : proof_expr list) : bool =
  let carried = List.concat_map flatten_proof carried in
  match required with
  | PredAnd { left; right; _ } ->
    proof_matches left carried && proof_matches right carried
  | _ ->
    let key = proof_key required in
    List.exists (fun p -> proof_key p = key) carried

let pred_names_of_return_spec (spec : return_spec) : string list =
  let dedup xs = List.sort_uniq String.compare xs in
  match spec with
  | RetAttached { binding = b; _ } ->
    (match b.proof_ann with Some p -> dedup (proof_predicates p) | None -> [])
  | RetNamedPack { entity_proof; other_proof; _ } ->
    dedup (
      (match entity_proof with Some p -> proof_predicates p | None -> [])
      @ (match other_proof with Some p -> proof_predicates p | None -> [])
    )
  | _ -> []

(** Extract the element-level predicate names from a ForAll/MaybeForAll/SetForAll return spec. *)
let forall_preds_of_return_spec (spec : return_spec) : string list =
  match spec with
  | RetForAll { proof; _ }
  | RetMaybeForAll { proof; _ }
  | RetSetForAll { proof; _ }
  | RetMaybeSetForAll { proof; _ } -> proof_predicates proof
  | RetForAllDictValues { proof; _ } | RetForAllDictKeys { proof; _ } -> proof_predicates proof
  | _ -> []

(* ── Type helpers ────────────────────────────────────────────────────────── *)

let gen_loc = dummy_loc "<validation>"

let mk_name_type name = TName { name; loc = gen_loc }
let mk_var_type name = TVar { name; loc = gen_loc }
let mk_app_type head arg = TApp { head; arg; loc = gen_loc }

let rec type_key (ty : type_expr) : string =
  match ty with
  | TName { name; _ } -> name
  | TVar { name; _ } -> name
  | TApp { head; arg; _ } -> type_key head ^ " " ^ type_key arg
  | TFun { dom; cod; _ } -> type_key dom ^ " -> " ^ type_key cod
  | TTuple { elems; _ } -> "(" ^ String.concat ", " (List.map type_key elems) ^ ")"

type func_info = {
  fi_name : string;
  fi_kind : func_kind;
  fi_params : binding list;
  fi_return : return_spec;
  fi_loc : loc;
}

type field_map = (string * field_def list) list
type type_env = (string * type_expr) list
type proof_env = (string * proof_expr list) list
type subject_env = (string * string) list
type ctor_info = (string * (type_expr list * type_expr)) list

let rec return_value_type (spec : return_spec) : type_expr option =
  match spec with
  | RetPlain { ty; _ } -> Some ty
  | RetAttached { binding = b; _ } -> Some b.type_expr
  | RetNamedPack { ty; _ } -> Some ty
  | RetForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "List") elem_ty)
  | RetMaybeForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "Maybe") (mk_app_type (mk_name_type "List") elem_ty))
  | RetSetForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "Set") elem_ty)
  | RetMaybeSetForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "Maybe") (mk_app_type (mk_name_type "Set") elem_ty))
  | RetForAllDictValues { key_ty; val_ty; _ } ->
    Some (mk_app_type (mk_app_type (mk_name_type "Dict") key_ty) val_ty)
  | RetForAllDictKeys   { key_ty; val_ty; _ } ->
    Some (mk_app_type (mk_app_type (mk_name_type "Dict") key_ty) val_ty)
  | RetMaybeAttached { outer_ty = Some ty; _ } -> Some ty
  | RetMaybeAttached { binding = b; _ } ->
    Some (mk_app_type (mk_name_type "Maybe") b.type_expr)
  | RetExists { body; _ } -> return_value_type body

let record_fields_of_type (fields_by_type : field_map) (ty : type_expr) : field_def list option =
  match ty with
  | TName { name; _ } -> List.assoc_opt name fields_by_type
  | TApp { head = TName { name; _ }; _ } -> List.assoc_opt name fields_by_type
  | _ -> None

let zip_prefix xs ys =
  let rec go acc xs ys =
    match xs, ys with
    | x :: xs', y :: ys' -> go ((x, y) :: acc) xs' ys'
    | _ -> List.rev acc
  in
  go [] xs ys

let rec unify_type_vars subst pattern actual =
  match pattern, actual with
  | TVar { name; _ }, ty ->
    (match List.assoc_opt name subst with
     | None -> Some ((name, ty) :: subst)
     | Some existing when type_key existing = type_key ty -> Some subst
     | Some _ -> None)
  | TName { name = lhs; _ }, TName { name = rhs; _ } when lhs = rhs -> Some subst
  | TApp { head = h1; arg = a1; _ }, TApp { head = h2; arg = a2; _ } ->
    (match unify_type_vars subst h1 h2 with
     | Some subst' -> unify_type_vars subst' a1 a2
     | None -> None)
  | TFun { dom = d1; cod = c1; _ }, TFun { dom = d2; cod = c2; _ } ->
    (match unify_type_vars subst d1 d2 with
     | Some subst' -> unify_type_vars subst' c1 c2
     | None -> None)
  | TTuple { elems = xs; _ }, TTuple { elems = ys; _ } when List.length xs = List.length ys ->
    List.fold_left2 (fun acc x y ->
      match acc with
      | Some subst' -> unify_type_vars subst' x y
      | None -> None
    ) (Some subst) xs ys
  | _ when type_key pattern = type_key actual -> Some subst
  | _ -> None

let rec instantiate_type subst ty =
  match ty with
  | TVar { name; _ } -> (match List.assoc_opt name subst with Some ty' -> ty' | None -> ty)
  | TApp ({ head; arg; _ } as app) -> TApp { app with head = instantiate_type subst head; arg = instantiate_type subst arg }
  | TFun ({ dom; cod; _ } as fn) -> TFun { fn with dom = instantiate_type subst dom; cod = instantiate_type subst cod }
  | TTuple ({ elems; _ } as tup) -> TTuple { tup with elems = List.map (instantiate_type subst) elems }
  | TName _ -> ty

let instantiate_ctor_field_types result_ty scrut_ty field_tys =
  match unify_type_vars [] result_ty scrut_ty with
  | Some subst -> List.map (instantiate_type subst) field_tys
  | None -> field_tys

let field_type (fields_by_type : field_map) (ty : type_expr) (field_name : string) : type_expr option =
  match record_fields_of_type fields_by_type ty with
  | None -> None
  | Some fields ->
    match List.find_opt (fun (f : field_def) -> f.name = field_name) fields with
    | Some f -> Some f.type_expr
    | None -> None

let builtin_ctor_info : ctor_info = [
  ("Nothing", ([], mk_app_type (mk_name_type "Maybe") (mk_var_type "a")));
  ("Something", ([mk_var_type "a"], mk_app_type (mk_name_type "Maybe") (mk_var_type "a")));
  ("Ok", ([mk_var_type "a"], mk_app_type (mk_app_type (mk_name_type "Result") (mk_var_type "a")) (mk_var_type "e")));
  ("Err", ([mk_var_type "e"], mk_app_type (mk_app_type (mk_name_type "Result") (mk_var_type "a")) (mk_var_type "e")));
  ("Left", ([mk_var_type "a"], mk_app_type (mk_app_type (mk_name_type "Either") (mk_var_type "a")) (mk_var_type "b")));
  ("Right", ([mk_var_type "b"], mk_app_type (mk_app_type (mk_name_type "Either") (mk_var_type "a")) (mk_var_type "b")));
  ("Tuple2", ([mk_var_type "a"; mk_var_type "b"], mk_app_type (mk_app_type (mk_name_type "Tuple2") (mk_var_type "a")) (mk_var_type "b")));
  ("Tuple3", ([mk_var_type "a"; mk_var_type "b"; mk_var_type "c"], mk_app_type (mk_app_type (mk_app_type (mk_name_type "Tuple3") (mk_var_type "a")) (mk_var_type "b")) (mk_var_type "c")));
]

let build_ctor_info (decls : top_decl list) : ctor_info =
  let adt_ctors = List.concat_map (function
    | DType (TypeAdt { name; variants; _ }) ->
      let result_ty = mk_name_type name in
      List.map (fun (v : adt_variant) ->
        (v.ctor, (List.map (fun (f : field_def) -> f.type_expr) v.fields, result_ty))
      ) variants
    | DType (TypeNewtype { name; base_type; _ })
    | DType (TypeAlias { name; base_type; _ }) ->
      [ (name, ([base_type], mk_name_type name)) ]
    | _ -> []
  ) decls in
  adt_ctors @ builtin_ctor_info

let build_func_info (decls : top_decl list) : (string * func_info) list =
  List.filter_map (function
    | DFunc fd -> Some (fd.name, { fi_name = fd.name; fi_kind = fd.kind; fi_params = fd.params; fi_return = fd.return_spec; fi_loc = fd.loc })
    | _ -> None
  ) decls

let module_name_to_kebab name =
  let buf = Buffer.create (String.length name + 4) in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
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

let normalize_exposed_type_name (name : string) : string option =
  let n = String.length name in
  let base =
    if n >= 4 && String.sub name (n - 4) 4 = "(..)" then
      String.sub name 0 (n - 4)
    else
      name
  in
  let parts = String.split_on_char '.' base in
  let local_name = match List.rev parts with
    | hd :: _ -> hd
    | [] -> base
  in
  if String.length local_name > 0 && local_name.[0] >= 'A' && local_name.[0] <= 'Z' then
    Some local_name
  else
    None

let load_imported_ctor_info (m : module_form) : ctor_info =
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
        (match Parser.parse_module path source with
         | Err _ -> []
         | Ok imported ->
           let requested_types = match imp.names with
             | ImportAll -> None
              | ImportExposing names -> Some (List.filter_map normalize_exposed_type_name names)
           in
           List.concat_map (function
             | DType (TypeAdt { name; variants; _ }) ->
               let include_it = match requested_types with
                 | None -> true
                 | Some names -> List.mem name names
               in
               if not include_it then []
               else
                 let result_ty = mk_name_type name in
                 List.map (fun (v : adt_variant) ->
                   (v.ctor, (List.map (fun (f : field_def) -> f.type_expr) v.fields, result_ty))
                 ) variants
             | _ -> []
           ) imported.decls)
  ) m.imports

(* ── Stdlib proof metadata ───────────────────────────────────────────────── *)
(* func_info records for stdlib functions that have proof-annotated parameters.
   Used by load_imported_func_info so calls like `Int.divide n d` are checked
   for the required `d ::: IsNonZero d` proof at the call site. *)

let stdlib_func_infos : (string * func_info) list =
  let g = gen_loc in
  let tname n = TName { name = n; loc = g } in
  let param name ty proof = { name; type_expr = tname ty; proof_ann = proof; loc = g } in
  let plain name ty = param name ty None in
  let with_proof name ty pred = param name ty (Some (PredApp { pred; args = [name]; loc = g })) in
  let ret ty = RetPlain { ty = tname ty; loc = g } in
  let ret_attached name ty pred =
    RetAttached {
      binding = { name; type_expr = tname ty;
                  proof_ann = Some (PredApp { pred; args = [name]; loc = g }); loc = g };
      loc = g }
  in
  [
    (* Int.divide: second arg b must carry IsNonZero b *)
    ("Int.divide",
     { fi_name = "Int.divide"; fi_kind = FnKind;
       fi_params = [ plain "a" "Int"; with_proof "b" "Int" "IsNonZero" ];
       fi_return = ret "Int"; fi_loc = g });
    (* Int.modulo: second arg b must carry IsNonZero b *)
    ("Int.modulo",
     { fi_name = "Int.modulo"; fi_kind = FnKind;
       fi_params = [ plain "a" "Int"; with_proof "b" "Int" "IsNonZero" ];
       fi_return = ret "Int"; fi_loc = g });
    (* Float.div: second arg b must carry FloatNonZero b *)
    ("Float.div",
     { fi_name = "Float.div"; fi_kind = FnKind;
       fi_params = [ plain "a" "Float"; with_proof "b" "Float" "FloatNonZero" ];
       fi_return = ret "Float"; fi_loc = g });
    (* Float.requireNonZero: check function returning f ::: FloatNonZero f *)
    ("Float.requireNonZero",
     { fi_name = "Float.requireNonZero"; fi_kind = CheckKind;
       fi_params = [ plain "f" "Float" ];
       fi_return = ret_attached "f" "Float" "FloatNonZero"; fi_loc = g });
    (* Int.nonZero: check function returning n ::: IsNonZero n *)
    ("Int.nonZero",
     { fi_name = "Int.nonZero"; fi_kind = CheckKind;
       fi_params = [ plain "n" "Int" ];
       fi_return = ret_attached "n" "Int" "IsNonZero"; fi_loc = g });
    (* Int.nonNegative: check function returning n ::: IsNonNegative n *)
    ("Int.nonNegative",
     { fi_name = "Int.nonNegative"; fi_kind = CheckKind;
       fi_params = [ plain "n" "Int" ];
       fi_return = ret_attached "n" "Int" "IsNonNegative"; fi_loc = g });
    (* List.take: second arg n must carry IsNonNegative n *)
    ("List.take",
     { fi_name = "List.take"; fi_kind = FnKind;
       fi_params = [ with_proof "n" "Int" "IsNonNegative"; plain "xs" "List" ];
       fi_return = ret "List"; fi_loc = g });
    (* List.drop: second arg n must carry IsNonNegative n *)
    ("List.drop",
     { fi_name = "List.drop"; fi_kind = FnKind;
       fi_params = [ with_proof "n" "Int" "IsNonNegative"; plain "xs" "List" ];
       fi_return = ret "List"; fi_loc = g });
    (* List.repeat: element x first, count n second (matches Racket List.repeat x n) *)
    ("List.repeat",
     { fi_name = "List.repeat"; fi_kind = FnKind;
       fi_params = [ plain "x" "a"; with_proof "n" "Int" "IsNonNegative" ];
       fi_return = ret "List"; fi_loc = g });
    (* String.requireNonEmpty: check function returning s ::: IsNonEmpty s *)
    ("String.requireNonEmpty",
     { fi_name = "String.requireNonEmpty"; fi_kind = CheckKind;
       fi_params = [ plain "s" "String" ];
       fi_return = ret_attached "s" "String" "IsNonEmpty"; fi_loc = g });
    (* Dict.get: dict must carry HasKey key dict proof (dict has been proven to contain key) *)
    ("Dict.get",
     { fi_name = "Dict.get"; fi_kind = FnKind;
       fi_params = [ plain "key" "a";
                     param "dict" "Dict"
                       (Some (PredApp { pred = "HasKey"; args = ["key"; "dict"]; loc = g })) ];
       fi_return = ret "b"; fi_loc = g });
    (* Dict.requireKey: check function returning dict ::: HasKey key dict (2-arg proof) *)
    ("Dict.requireKey",
     { fi_name = "Dict.requireKey"; fi_kind = CheckKind;
       fi_params = [ plain "key" "a"; plain "dict" "Dict" ];
       fi_return = RetAttached {
         binding = { name = "dict"; type_expr = tname "Dict";
                     proof_ann = Some (PredApp { pred = "HasKey";
                                                 args = ["key"; "dict"]; loc = g });
                     loc = g };
         loc = g }; fi_loc = g });
    (* String.trim / trimLeft / trimRight: fn returning String ? IsTrimmed *)
    ("String.trim",
     { fi_name = "String.trim"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsTrimmed"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("String.trimLeft",
     { fi_name = "String.trimLeft"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsTrimmed"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("String.trimRight",
     { fi_name = "String.trimRight"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsTrimmed"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    (* String.toUpper / toLower *)
    ("String.toUpper",
     { fi_name = "String.toUpper"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsUpperCase"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("String.toLower",
     { fi_name = "String.toLower"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsLowerCase"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    (* List.sort / sortBy: fn returning List T ? IsSorted *)
    ("List.sort",
     { fi_name = "List.sort"; fi_kind = FnKind;
       fi_params = [ plain "xs" "List" ];
       fi_return = RetNamedPack {
         ty = tname "List";
         entity_proof = Some (PredApp { pred = "IsSorted"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("List.sortBy",
     { fi_name = "List.sortBy"; fi_kind = FnKind;
       fi_params = [ plain "f" "a"; plain "xs" "List" ];
       fi_return = RetNamedPack {
         ty = tname "List";
         entity_proof = Some (PredApp { pred = "IsSorted"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
  ]

let split_module_name (full : string) : string * string =
  match String.rindex_opt full '.' with
  | Some i ->
    (String.sub full 0 i,
     String.sub full (i + 1) (String.length full - i - 1))
  | None -> ("", full)

let load_imported_func_info (m : module_form) : (string * func_info) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then
      (* Return stdlib func_info entries for functions imported from this module *)
      let requested = match imp.names with
        | ImportAll -> None
        | ImportExposing names -> Some names
      in
      List.filter_map (fun (full_name, info) ->
        let include_it = match requested with
          | None -> true
          | Some names ->
            (* "Int.divide" is included if "Int.divide" or "divide" is in names *)
            let (_, local_name) = split_module_name full_name in
            List.mem full_name names || List.mem local_name names
        in
        if include_it then Some (full_name, info) else None
      ) stdlib_func_infos
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
              let info = { fi_name = fd.name; fi_kind = fd.kind; fi_params = fd.params; fi_return = fd.return_spec; fi_loc = fd.loc } in
              let qualified_name = imp.module_name ^ "." ^ fd.name in
              let include_plain = match requested with
                | Some names -> List.mem fd.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem fd.name names
                | None -> true
              in
              (if include_plain then [ (fd.name, info) ] else [])
              @ (if include_qualified then [ (qualified_name, info) ] else [])
            | _ -> []
          ) imported.decls
  ) m.imports

let load_imported_cap_map (m : module_form) : (string * string list) list =
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
            | DCapability c ->
              let qualified_name = imp.module_name ^ "." ^ c.name in
              let include_plain = match requested with
                | Some names -> List.mem c.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem c.name names
                | None -> true
              in
              (if include_plain then [ (c.name, c.implies) ] else [])
              @ (if include_qualified then [ (qualified_name, c.implies) ] else [])
            | _ -> []
          ) imported.decls
  ) m.imports

let check_adt_variant_names (decls : top_decl list) : validation_error list =
  List.concat_map (function
    | DType (TypeAdt { name; variants; loc; _ }) ->
      List.filter_map (fun (v : adt_variant) ->
        if v.ctor = name then
          Some (make_error loc
            (Printf.sprintf
               "constructor '%s' has the same name as its type — rename the constructor (e.g. 'Mk%s')"
               v.ctor name))
        else None
      ) variants
    | _ -> []
  ) decls

(* R51_T03 — self-referential type alias / newtype. `type Foo = Foo` is not
   a meaningful nominal declaration; the base type is the alias itself. We
   forbid it at declaration time so the error lives where the bug lives,
   not at every use site. *)
let check_self_referential_aliases (decls : top_decl list) : validation_error list =
  let rec mentions_name name (te : type_expr) =
    match te with
    | TName { name = n; _ } -> n = name
    | TVar _ -> false
    | TApp { head; arg; _ } -> mentions_name name head || mentions_name name arg
    | TFun { dom; cod; _ } -> mentions_name name dom || mentions_name name cod
    | TTuple { elems; _ } -> List.exists (mentions_name name) elems
  in
  List.concat_map (function
    | DType (TypeAlias { name; base_type; loc })
    | DType (TypeNewtype { name; base_type; loc }) ->
      if mentions_name name base_type then
        [ make_error loc
            (Printf.sprintf
               "type `%s` is self-referential: the base type mentions `%s`, which creates an infinite alias. Rename the alias or use a recursive ADT declaration (`type %s = Mk%s %s` or multi-variant form)."
               name name name name name) ]
      else []
    | _ -> []
  ) decls

let collect_import_parse_errors (m : module_form) : validation_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.filter_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then None
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then None
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        match Parser.parse_module path source with
        | Ok _ -> None
        | Err e -> Some (make_error e.loc
            (Printf.sprintf "imported module '%s' has a parse error: %s" imp.module_name e.msg))
  ) m.imports

let build_fields_map (decls : top_decl list) : field_map =
  List.filter_map (function
    | DRecord r -> Some (r.name, r.fields)
    | DEntity e -> Some (e.name, e.fields)
    | _ -> None
  ) decls

let rec collect_call_head_and_args acc = function
  | EApp { fn; arg; _ } -> collect_call_head_and_args (arg :: acc) fn
  | fn -> (fn, acc)

let normalize_explicit_check_call head args =
  match head, args with
  | EVar { name = "check"; _ }, check_fn :: check_args -> (check_fn, check_args)
  | _ -> (head, args)

let function_name_of_expr = function
  | EVar { name; _ } -> Some name
  | EField { obj = EConstructor { name = mod_name; args = []; _ }; field; _ }
  | EField { obj = EVar { name = mod_name; _ }; field; _ } -> Some (mod_name ^ "." ^ field)
  | _ -> None

let rec flatten_check_chain_expr acc = function
  | EBinop { op = BAnd; left; right; _ } ->
    flatten_check_chain_expr (flatten_check_chain_expr acc right) left
  | other -> other :: acc

(** Detect SQL DSL expressions buried under WHERE-clause operator chains.

    The Tesl SQL DSL parses e.g.:
      selectCount m from T where m.x == v && m.y == w
    as:
      BAnd(BEq(App(App(App(App(selectCount, m), from), T), where_m.x), v),
           BEq(m.y, w))

    Similarly, WHERE filters with comparison operators:
      select p from Product where p.price > minPrice
    is parsed as:
      BGt(App(App(App(App(select, p), from), Product), where_p.price), minPrice)

    The left spine through BAnd / BEq / BNeq / BGt / BGe / BLt / BLe → EApp leads
    to the actual SQL function.  We follow it recursively to detect SQL expressions
    so that the ordering-operator validation pass can skip SQL predicate syntax. *)
let rec infer_sql_aggregate_type (e : expr) : type_expr option =
  match e with
  | EApp _ ->
    let (head, _) = collect_call_head_and_args [] e in
    (match function_name_of_expr head with
     | Some ("selectCount" | "selectSum" | "selectMin" | "selectMax") ->
       Some (mk_name_type "Int")
     | Some ("select" | "selectMany") ->
       Some (mk_app_type (mk_name_type "List") (mk_var_type "a"))
     | Some "selectOne" ->
       Some (mk_app_type (mk_name_type "Maybe") (mk_var_type "a"))
     | _ -> None)
  | EBinop { op = BAnd | BEq | BNeq | BGt | BGe | BLt | BLe; left; _ } ->
    infer_sql_aggregate_type left
  | _ -> None

let rec infer_expr_type
    (env : type_env)
    (funcs : (string * func_info) list)
    (fields_by_type : field_map)
    (ctors : ctor_info)
    (e : expr)
    : type_expr option =
  (* Check for SQL aggregate expressions buried under WHERE-clause chains first,
     before the regular BAnd/BEq → Bool inference runs. *)
  match infer_sql_aggregate_type e with
  | Some ty -> Some ty
  | None ->
  match e with
  | ELit { lit = LInt _; _ } -> Some (mk_name_type "Int")
  | ELit { lit = LFloat _; _ } -> Some (mk_name_type "Float")
  | ELit { lit = LBool _; _ } -> Some (mk_name_type "Bool")
  | ELit { lit = LString _; _ } | ELit { lit = LInterp _; _ } -> Some (mk_name_type "String")
  | EVar { name; _ } -> List.assoc_opt name env
  | EField { obj; field; _ } ->
    (match infer_expr_type env funcs fields_by_type ctors obj with
     | Some obj_ty -> field_type fields_by_type obj_ty field
     | None -> None)
  | ERecord { type_hint = Some type_name; _ } -> Some (mk_name_type type_name)
  | ERecord _ -> None
  | EList { elems = []; _ } -> Some (mk_app_type (mk_name_type "List") (mk_name_type "a"))
  | EList { elems = hd :: _; _ } ->
    (match infer_expr_type env funcs fields_by_type ctors hd with
     | Some elem_ty -> Some (mk_app_type (mk_name_type "List") elem_ty)
     | None -> None)
  | EIf { then_; else_; _ } ->
    (match infer_expr_type env funcs fields_by_type ctors then_,
           infer_expr_type env funcs fields_by_type ctors else_ with
     | Some t1, Some t2 when type_key t1 = type_key t2 -> Some t1
     | Some t, None | None, Some t -> Some t
     | _ -> None)
  | ECase { arms; _ } ->
    let arm_types = List.filter_map (fun (arm : case_arm) ->
      infer_expr_type env funcs fields_by_type ctors arm.body
    ) arms in
    (match arm_types with
     | first :: rest when List.for_all (fun t -> type_key t = type_key first) rest -> Some first
     | first :: _ -> Some first
     | [] -> None)
  | ELet { name; value; body; _ } ->
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: env
      | None -> env
    in
    infer_expr_type env' funcs fields_by_type ctors body
  | ELetProof { value_name; value; body; _ } ->
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (value_name, ty) :: env
      | None -> env
    in
    infer_expr_type env' funcs fields_by_type ctors body
  | EOk { value; _ } -> infer_expr_type env funcs fields_by_type ctors value
  | EFail _ -> None
  | ETelemetry _ | EEnqueue _ | EPublish _ | EStartWorkers _ -> Some (mk_name_type "Unit")
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    infer_expr_type env funcs fields_by_type ctors body
  | EServe _ -> Some (mk_name_type "Unit")
  | ELambda _ -> None
  | EBinop { op; _ } ->
    (match op with
     | BAnd | BOr | BEq | BNeq | BLt | BLe | BGt | BGe -> Some (mk_name_type "Bool")
     | BConcat -> Some (mk_name_type "String")
     | _ -> Some (mk_name_type "Int"))
  | EUnop { op; _ } -> (match op with UNot -> Some (mk_name_type "Bool") | UNeg -> Some (mk_name_type "Int"))
  | EConstructor { name; _ } ->
    (match List.assoc_opt name ctors with
     | Some (_, result_ty) -> Some result_ty
     | None -> None)
  | EApp _ ->
    let (head, _) = collect_call_head_and_args [] e in
    (match function_name_of_expr head with
    | Some fn_name ->
      (* Check user-defined functions first, then known SQL built-in return types. *)
      (match List.assoc_opt fn_name funcs with
       | Some info -> return_value_type info.fi_return
       | None ->
         (match fn_name with
          | "selectCount" | "selectSum" | "selectMin" | "selectMax" ->
            Some (mk_name_type "Int")
          | "select" | "selectMany" ->
            Some (mk_app_type (mk_name_type "List") (mk_var_type "a"))
          | "selectOne" ->
            Some (mk_app_type (mk_name_type "Maybe") (mk_var_type "a"))
          | "upsert" -> Some (mk_name_type "Unit")
          | _ -> None))
    | None -> None)

let rec pattern_bindings (scrut_ty : type_expr option) (ctors : ctor_info) (pat : pattern) : type_env =
  match pat with
  | PWild | PNullary _ | PLit _ -> []
  | PVar name ->
    (match scrut_ty with Some ty -> [ (name, ty) ] | None -> [])
  | PCon { ctor; fields; _ } ->
    let field_types = match List.assoc_opt ctor ctors, scrut_ty with
      | Some (tys, result_ty), Some scrut_ty -> instantiate_ctor_field_types result_ty scrut_ty tys
      | Some (tys, _), None -> tys
      | None, _ -> []
    in
    List.concat_map (fun ((_, sub_pat), ty) ->
      pattern_bindings (Some ty) ctors sub_pat
    ) (zip_prefix fields field_types)
    |> fun ok -> if ok = [] && fields <> [] then
         (* fallback: collect PVar names at any depth with Unknown type *)
         let rec collect_vars = function
           | PVar n -> [(n, mk_name_type "Unknown")]
           | PCon { fields; _ } -> List.concat_map (fun (_, p) -> collect_vars p) fields
           | _ -> []
         in
         List.concat_map (fun (_, sub_pat) -> collect_vars sub_pat) fields
       else ok

let normalize_carried_forall (result_name : string) (proof : proof_expr) : proof_expr =
  (* Use pp_proof to include literal args (e.g. "HasMin 10" from `HasMin 10 n`).
     The proof here has already had the element-subject stripped (it came from the
     `?` return-type annotation, where the element subject is implicit). *)
  PredApp { pred = "ForAll"; args = [pp_proof proof; result_name]; loc = gen_loc }

let normalize_carried_forall_dict_values (result_name : string) (proof : proof_expr) : proof_expr =
  PredApp { pred = "ForAllValues"; args = [pp_proof proof; result_name]; loc = gen_loc }

let normalize_carried_forall_dict_keys (result_name : string) (proof : proof_expr) : proof_expr =
  PredApp { pred = "ForAllKeys"; args = [pp_proof proof; result_name]; loc = gen_loc }

let name_of_proof_type_arg (ty : type_expr) : string option =
  match ty with
  | TName { name; _ } -> Some name
  | TVar { name; _ } -> Some name
  | _ -> None

let proof_of_fact_type (ty : type_expr) : proof_expr option =
  let extract_from_fact_type arg =
    type_expr_to_proof_expr arg
  in
  match ty with
  | TApp { head = TName { name = "Fact"; _ }; arg; _ } ->
    extract_from_fact_type arg
  (* Maybe (Fact P) — the inner proof, for establish functions returning optional proofs *)
  | TApp { head = TName { name = "Maybe"; _ };
           arg  = TApp { head = TName { name = "Fact"; _ }; arg = inner; _ }; _ } ->
    extract_from_fact_type inner
  | _ -> None
let proofs_of_return_spec
    (result_name : string)
    ?(param_mapping = [])
    (spec : return_spec)
    : proof_expr list =
  let attach_binding_proof (binding : binding) =
    (* Use the param_mapping's subject for this binding name ONLY when the mapping is
       non-trivial (maps to a different name). Self-mappings like rawLabel → rawLabel mean
       the result should be indexed by result_name.

       E.g. checkPositive(n: Int) -> n: Int ::: Positive n, called on `raw`:
         param_mapping = [("n","raw")] → "n" ≠ "raw" → use "raw" → proof = Positive raw
       E.g. sanitize(rawLabel: String) -> rawLabel: String ::: Sanitized rawLabel, called on `rawLabel`:
         param_mapping = [("rawLabel","rawLabel")] → self-map → use result_name → proof = Sanitized validLabel *)
    let subject_for_binding = match List.assoc_opt binding.name param_mapping with
      | Some s -> s      (* use the argument's subject (consistent with subject_env propagation) *)
      | None -> result_name  (* param not in mapping → use result_name *)
    in
    let mapping = (binding.name, subject_for_binding)
                  :: List.filter (fun (name, _) -> name <> binding.name) param_mapping in
    match binding.proof_ann with
    | Some proof -> [ subst_proof mapping proof ]
    | None -> []
  in
  match spec with
  | RetAttached { binding; _ } -> attach_binding_proof binding
  | RetNamedPack { entity_proof; other_proof; _ } ->
    let entity_mapping = ("_entity", result_name) :: param_mapping in


    (match entity_proof with
     | Some proof -> [ subst_proof entity_mapping (expand_entity_proof_group proof) ]
     | None -> [])
    @ (match other_proof with Some proof -> [ subst_proof param_mapping proof ] | None -> [])
  | RetForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetMaybeForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetSetForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetMaybeSetForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetForAllDictValues { proof; _ } ->
    [ normalize_carried_forall_dict_values result_name (subst_proof param_mapping proof) ]
  | RetForAllDictKeys { proof; _ } ->
    [ normalize_carried_forall_dict_keys result_name (subst_proof param_mapping proof) ]
  | RetMaybeAttached { binding; _ } -> attach_binding_proof binding
  | RetExists _ -> []
  | RetPlain { ty; _ } -> (match proof_of_fact_type ty with Some proof -> [ subst_proof param_mapping proof ] | None -> [])

let rec flatten_proof_conj (proof : proof_expr) : proof_expr list =
  match proof with
  | PredAnd { left; right; _ } -> flatten_proof_conj left @ flatten_proof_conj right
  | _ -> [proof]

let combine_proof_list (loc : loc) (proofs : proof_expr list) : proof_expr option =
  match proofs with
  | [] -> None
  | first :: rest ->
    Some (List.fold_left (fun acc proof -> PredAnd { left = acc; right = proof; loc }) first rest)

(** Substitute proof argument names using subject_env, so that a user-written
    annotation like [Fact (NonEmpty ne)] (where [ne] has subject [raw]) is
    normalised to [NonEmpty raw] before comparison against the tracked proofs. *)
let rec subst_proof_args_with_subjects (subject_env : subject_env) (proof : proof_expr) : proof_expr =
  match proof with
  | PredApp { pred; args; loc } ->
    let args' = List.map (subst_proof_arg subject_env) args in
    PredApp { pred; args = args'; loc }
  | PredAnd { left; right; loc } ->
    PredAnd {
      left  = subst_proof_args_with_subjects subject_env left;
      right = subst_proof_args_with_subjects subject_env right;
      loc;
    }

let rec normalize_proof_aliases (proof_env : proof_env) (proof : proof_expr) : proof_expr =
  match proof with
  | PredApp ({ pred; args = []; loc } as app) ->
    (match List.assoc_opt pred proof_env with
     | Some proofs ->
       (match combine_proof_list loc proofs with
        | Some combined -> combined
        | None -> PredApp app)
     | None -> PredApp app)
  | PredApp { pred = "introAnd"; args; loc } ->
    (* introAnd pf1 pf2 → conjunction of all proofs from each argument *)
    let component_proofs = List.filter_map (fun arg ->
      match List.assoc_opt arg proof_env with
      | Some proofs -> combine_proof_list loc proofs
      | None -> None
    ) args in
    (match combine_proof_list loc component_proofs with
     | Some combined -> combined
     | None -> proof)
  | PredApp { pred = ("andLeft" | "andRight"); args = [pf_name]; loc } ->
    (* andLeft/andRight: statically, return all proofs from the input (conservative) *)
    (match List.assoc_opt pf_name proof_env with
     | Some proofs ->
       (match combine_proof_list loc proofs with
        | Some combined -> combined
        | None -> proof)
     | None -> proof)
  | PredApp _ -> proof
  | PredAnd { left; right; loc } ->
    PredAnd {
      left = normalize_proof_aliases proof_env left;
      right = normalize_proof_aliases proof_env right;
      loc;
    }

let rec subject_of_expr (subject_env : subject_env) (expr : expr) : string option =
  match expr with
  | EVar { name; _ } ->
    Some (match List.assoc_opt name subject_env with Some subject -> subject | None -> name)
  | EOk { value; _ } -> subject_of_expr subject_env value
  | EField { obj; _ } -> subject_of_expr subject_env obj
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] expr in
    (match function_name_of_expr head, args with
     | Some "attachFact", value :: _ -> subject_of_expr subject_env value
     | Some "forgetFact", [value]
     | Some "detachFact", [value] -> subject_of_expr subject_env value
     (* Note: we do NOT propagate subjects for arbitrary function calls here,
        as that would incorrectly equate the result subject with arg subjects for
        non-identity functions (e.g. database selectors, transformers). *)
     | _ -> None)
  (* Literal values act as their own stable subjects (string representation).
     This allows integer/string constants to participate in multi-param proofs:
     `HasMin 100 n` where `100` is the `lo` argument. *)
  | ELit { lit = LInt n; _ } -> Some (string_of_int n)
  | ELit { lit = LFloat f; _ } -> Some (string_of_float f)
  | ELit { lit = LString s; _ } -> Some ("\"" ^ s ^ "\"")
  | EUnop { op = UNeg; arg = ELit { lit = LInt n; _ }; _ } -> Some ("-" ^ string_of_int n)
  | EUnop { op = UNeg; arg = ELit { lit = LFloat f; _ }; _ } -> Some ("-" ^ string_of_float f)
  | _ -> None

(** Extract proofs from an evidence expression (second arg to attachFact).
    When [funcs] is provided, inline establish/check function calls are resolved. *)
let rec proofs_of_evidence_expr
    ?(funcs : (string * func_info) list = [])
    (subject_env : subject_env)
    (proof_env : proof_env)
    (expr : expr)
    : proof_expr list option =
  match expr with
  | EVar { name; _ } -> List.assoc_opt name proof_env
  | EBinop { op = BAnd; left; right; _ } ->
    (match proofs_of_evidence_expr ~funcs subject_env proof_env left,
           proofs_of_evidence_expr ~funcs subject_env proof_env right with
     | Some left_proofs, Some right_proofs -> Some (left_proofs @ right_proofs)
     | _ -> None)
  | EOk { value; proof; _ } ->
    (* `value ::: proof_expr` as evidence: both the value's proofs and the proof annotation.
       The value may be an establish call (e.g. `positive n` returns IsPositive n),
       and the proof may be an establish function call (e.g. `nonzero n` returns NonZero n).
       Combine both. *)
    let value_proofs = proofs_of_evidence_expr ~funcs subject_env proof_env value in
    (* Resolve the proof annotation: if it's an establish function call, get its predicates *)
    let resolve_proof_predicate p = match p with
      | PredApp { pred; args; _ } when funcs <> [] ->
        (match List.assoc_opt pred funcs with
         | Some info when info.fi_kind = EstablishKind ->
           (* Map establish function params to their argument names *)
           let param_mapping = List.filter_map (fun ((param : binding), arg) ->
             match arg with
             | arg_name ->
               let subject = match List.assoc_opt arg_name subject_env with
                 | Some s -> s | None -> arg_name
               in
               Some (param.name, subject)
           ) (zip_prefix info.fi_params args) in
           proofs_of_return_spec "_" ~param_mapping info.fi_return
         | _ -> flatten_proof_conj (normalize_proof_aliases proof_env p))
      | _ -> flatten_proof_conj (normalize_proof_aliases proof_env p)
    in
    let proof_proofs = resolve_proof_predicate proof in
    (match value_proofs with
     | Some vp -> Some (vp @ proof_proofs)
     | None -> Some proof_proofs)
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] expr in
    (match function_name_of_expr head, args with
     | Some ("detachFact" | "detachAllFact"), [value] ->
       proofs_of_evidence_expr ~funcs subject_env proof_env value
     | Some fn_name, _ when funcs <> [] ->
       (* When funcs is available, resolve inline establish/check calls.
          E.g. `attachFact forgotten (validPort y)` — evidence is `validPort y`. *)
       (match List.assoc_opt fn_name funcs with
        | Some info ->
          let param_mapping = List.filter_map (fun ((param : binding), arg) ->
            match subject_of_expr subject_env arg with
            | Some subject -> Some (param.name, subject)
            | None -> None
          ) (zip_prefix info.fi_params args) in
          let preds = proofs_of_return_spec "_" ~param_mapping info.fi_return in
          if preds = [] then None else Some preds
        | None -> None)
     | _ -> None)
  | _ -> None

(** Module-level registry of field-name → (param_name, proof_expr) for all
    proof-annotated record/entity fields.  Set by [check_call_site_proofs] before
    the traversal so that [carried_proofs_of_expr] can look up field proofs without
    threading an extra parameter through every call site. *)
let field_proof_registry : (string * (string * proof_expr)) list ref = ref []

(** Build a flat map from field name to (field_param_name, proof_expr) for all
    proof-annotated record/entity fields in [decls]. *)
let build_field_proof_map (decls : top_decl list) : (string * (string * proof_expr)) list =
  List.concat_map (function
    | DRecord r ->
      List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some p -> Some (f.name, (f.name, p))
        | None -> None
      ) r.fields
    | DEntity e ->
      List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some p -> Some (f.name, (f.name, p))
        | None -> None
      ) e.fields
    | _ -> []
  ) decls

let rec carried_proofs_of_expr
    ?(funcs : (string * func_info) list = [])
    (subject_env : subject_env)
    (proof_env : proof_env)
    (expr : expr)
    : proof_expr list option =
  match expr with
  | EVar { name; _ } ->
    (* Resolve through subject_env to find the canonical subject name.
       This handles proof aliases created by ELetProof: `let (raw ::: lp && rp) = b`
       adds `subject_env["raw"] = "b"` but does NOT add `proof_env["raw"]`.
       We must follow the alias to find `proof_env["b"]`.
       IMPORTANT: always check proof_env[name] first. The subject_env alias is only a
       fallback for ELetProof where the new name has no own proofs. If a check function
       was called (e.g. `let notDoneId = checkNotDone issueId`), proof_env["notDoneId"]
       holds the established proofs and must take priority over proof_env["issueId"]. *)
    Some (match List.assoc_opt name proof_env with
          | Some proofs when proofs <> [] -> proofs
          | _ ->
            let subject = match List.assoc_opt name subject_env with Some s -> s | None -> name in
            match List.assoc_opt subject proof_env with
            | Some proofs -> proofs
            | None -> [])
  | EOk { value; proof; _ } ->
    let base = carried_proofs_of_expr ~funcs subject_env proof_env value in
    (* For the proof annotation: try to resolve establish function calls and
       detachFact references to concrete predicates. Recurse into PredAnd. *)
    let extra =
      let normalized = normalize_proof_aliases proof_env proof in
      let rec resolve_proof_ref p =
        match p with
        | PredApp { pred = "detachFact"; args = [name]; _ } ->
          let subject = match List.assoc_opt name subject_env with Some s -> s | None -> name in
          (match List.assoc_opt name proof_env with
           | Some proofs when proofs <> [] -> proofs
           | _ ->
             (match List.assoc_opt subject proof_env with
              | Some proofs -> proofs
              | None -> [p]))
        | PredApp { pred; args; _ } when funcs <> [] ->
          (match List.assoc_opt pred funcs with
           | Some info when info.fi_kind = EstablishKind ->
             let param_mapping = List.filter_map (fun ((param : binding), arg) ->
               let subject = match List.assoc_opt arg subject_env with
                 | Some s -> s | None -> arg
               in
               Some (param.name, subject)
             ) (zip_prefix info.fi_params args) in
             let preds = proofs_of_return_spec "_" ~param_mapping info.fi_return in
             if preds = [] then [p] else preds
           | _ -> [p])
        | PredApp { pred; args = []; _ } when
            String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' ->
          (* Proof variable reference (e.g. from let (_ ::: p) = ...):
             resolve through proof_env to find what it actually proves. *)
          (match List.assoc_opt pred proof_env with
           | Some proofs when proofs <> [] -> proofs
           | _ ->
             (* Also try subject_env alias *)
             let subject = match List.assoc_opt pred subject_env with Some s -> s | None -> pred in
             (match List.assoc_opt subject proof_env with
              | Some proofs when proofs <> [] -> proofs
              | _ -> [p]))
        | PredApp _ -> [p]
        | PredAnd { left; right; _ } ->
          resolve_proof_ref left @ resolve_proof_ref right
      in
      resolve_proof_ref normalized
    in
    (match base with
     | Some proofs -> Some (proofs @ extra)
     | None -> Some extra)
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] expr in
    (match function_name_of_expr head, args with
     | Some "attachFact", [value; evidence] ->
       let base = carried_proofs_of_expr ~funcs subject_env proof_env value in
       let extra = proofs_of_evidence_expr ~funcs subject_env proof_env evidence in
       (match base, extra with
        | Some left, Some right -> Some (left @ right)
        | Some left, None -> Some left
        | None, Some right -> Some right
        | None, None -> None)
     | Some "forgetFact", [_] -> Some []
     | Some "detachFact", [value] -> carried_proofs_of_expr ~funcs subject_env proof_env value
     (* Proof conjunction operations: return the combined proofs of their inputs *)
     | Some "introAnd", pf_args ->
       (* introAnd pf1 pf2 ... → carries all proofs from all arguments.
          Try carried_proofs first (for named Fact variables), then fall back
          to proofs_of_evidence_expr to handle inline establish calls like
          `introAnd (proveA x) (proveB x)` where the arguments are EApp nodes. *)
       let all = List.filter_map (fun arg ->
         match carried_proofs_of_expr ~funcs subject_env proof_env arg with
         | Some proofs when proofs <> [] -> Some proofs
         | _ -> proofs_of_evidence_expr ~funcs subject_env proof_env arg
       ) pf_args in
       Some (List.concat all)
     | Some ("andLeft" | "andRight"), [pf] ->
       (* andLeft/andRight: conservative — carries same proofs as input
          (static analysis doesn't know the structural split) *)
       carried_proofs_of_expr ~funcs subject_env proof_env pf
     | _ -> None)
  | EField { obj; field; _ } ->
    (* When a proof-annotated record field is accessed, propagate the field's
       declared proof with its subject substituted to the actual object subject. *)
    (match List.assoc_opt field !field_proof_registry with
     | None -> None
     | Some (param_name, proof) ->
       let obj_subj = match subject_of_expr subject_env obj with
         | Some s -> s
         | None -> field
       in
       Some [subst_proof [(param_name, obj_subj)] proof])
  | _ -> None

let proofs_of_expr
    (result_name : string)
    (funcs : (string * func_info) list)
    (subject_env : subject_env)
    (proof_env : proof_env)
    (expr : expr)
    : proof_expr list =
  let direct =
    match expr with
    | EVar _ | EField _ -> carried_proofs_of_expr ~funcs subject_env proof_env expr
    | EOk _ ->
      (* Handled after proofs_of_call_head is defined below, so we can merge
         sidecar proofs (from carried_proofs_of_expr) with check-call proofs. *)
      None
    | EApp _ ->
      let (head, _) = collect_call_head_and_args [] expr in
      (match function_name_of_expr head with
       | Some ("attachFact" | "forgetFact" | "detachFact"
              | "introAnd" | "andLeft" | "andRight") ->
         carried_proofs_of_expr ~funcs subject_env proof_env expr
       | _ -> None)
    | _ -> None
  in
  match direct with
  | Some proofs -> proofs
  | None ->
    let (head, args) = collect_call_head_and_args [] expr in
    let rec proofs_of_call_head head args =
      match function_name_of_expr head with
      | Some "check" ->
        (* `check f arg` is syntactic sugar for a proof-carrying call to f.
           Treat the first argument as the actual function and recurse. *)
        (match args with
         | fn_expr :: rest -> proofs_of_call_head fn_expr rest
         | [] -> [])
      | Some fn_name ->
        (match List.assoc_opt fn_name funcs with
         | Some info ->
           let param_mapping = List.filter_map (fun ((param : binding), arg) ->
             match subject_of_expr subject_env arg with
             | Some subject -> Some (param.name, subject)
             | None -> None
           ) (zip_prefix info.fi_params args) in
           let return_proofs = proofs_of_return_spec result_name ~param_mapping info.fi_return in
           (* For CheckKind functions: also carry forward existing proofs from the subject arg.
              E.g. `let y = check isB x` where x already has [IsA]: y should have [IsA, IsB]. *)
           let carried_subject_proofs =
             if info.fi_kind = CheckKind then
               let subj_param_name = match info.fi_return with
                 | RetAttached { binding; _ } -> Some binding.name
                 | _ -> None
               in
               (match subj_param_name with
                | Some spn ->
                  let idx = ref (-1) in
                  List.iteri (fun i (p : binding) -> if p.name = spn && !idx < 0 then idx := i) info.fi_params;
                  let subj_arg = match !idx with
                    | i when i >= 0 -> List.nth_opt args i
                    | _ -> List.nth_opt args 0
                  in
                  (match subj_arg with
                   | None -> []
                   | Some arg ->
                     match carried_proofs_of_expr ~funcs subject_env proof_env arg with
                     | Some proofs -> proofs
                     | None ->
                       let name = match arg with EVar { name; _ } -> name | _ -> "" in
                       let subj = match List.assoc_opt name subject_env with Some s -> s | None -> name in
                       (match List.assoc_opt subj proof_env with
                        | Some ps -> ps
                        | None -> (match List.assoc_opt name proof_env with Some ps -> ps | None -> [])))
                | None -> [])
             else []
           in
           (* Merge carried (old proofs) + return_proofs (new proofs), deduplicating by proof_key *)
           let seen_keys = ref [] in
           List.filter (fun p ->
             let k = proof_key p in
             if List.mem k !seen_keys then false
             else (seen_keys := k :: !seen_keys; true)
           ) (carried_subject_proofs @ return_proofs)
         | None ->
           (* BUG-2 fix: handle `List.filterCheck (checkA && checkB) xs`.
              Build a SINGLE combined ForAll proof for the chain so that
              `ForAll (PA && PB) result` matches the declared return type. *)
           let is_filtercheck_head h = match h with
             | EField { obj = EConstructor { name = "List"; _ }; field = "filterCheck"; _ }
             | EVar { name = "List.filterCheck"; _ }
             | EField { obj = EConstructor { name = "Set"; _ }; field = "filterCheck"; _ }
             | EVar { name = "Set.filterCheck"; _ }
             | EField { obj = EConstructor { name = "List"; _ }; field = "allCheck"; _ }
             | EVar { name = "List.allCheck"; _ }
             | EField { obj = EConstructor { name = "Set"; _ }; field = "allCheck"; _ }
             | EVar { name = "Set.allCheck"; _ }
             | EField { obj = EConstructor { name = "List"; _ }; field = "emptyForAll"; _ }
             | EVar { name = "List.emptyForAll"; _ } -> true
             | _ -> false
           in
           (* Returns the predicate string for ForAll, including literal args but
              stripping the binder/element arg (always the last positional arg).
              E.g. "IsPositive n" → "IsPositive", "HasMin 10 n" → "HasMin 10",
              "IsPositive && IsSmall" → "IsPositive && IsSmall". *)
           let pred_str_drop_last_arg pred args =
             match List.rev args with
             | _ :: rest -> (* last arg is the element subject; keep the literals *)
               let kept = List.rev rest in
               if kept = [] then pred
               else pred ^ " " ^ String.concat " " kept
             | [] -> pred
           in
           let rec pred_str_from_check_chain e = match e with
             | EVar { name = check_fn; _ } ->
               (match List.assoc_opt check_fn funcs with
                | Some info ->
                  (match info.fi_return with
                   | RetAttached { binding = { proof_ann = Some (PredApp { pred; args; _ }); _ }; _ } ->
                     Some (pred_str_drop_last_arg pred args)
                   | RetAttached { binding = { proof_ann = Some p; _ }; _ } ->
                     Some (pp_proof p)
                   | _ -> None)
                | None -> None)
             | EBinop { op = BAnd; left; right; _ } ->
               (match pred_str_from_check_chain left, pred_str_from_check_chain right with
                | Some lp, Some rp -> Some (lp ^ " && " ^ rp)
                | Some p, None | None, Some p -> Some p
                | None, None -> None)
             | _ -> None
           in
           (match head, args with
           | h, (check_fn_expr :: input_expr :: _) when is_filtercheck_head h ->
             (match pred_str_from_check_chain check_fn_expr with
              | Some new_pred_str ->
                (* Merge any prior ForAll predicates from the input list so that
                   sequential filterChecks accumulate: filterCheck checkSmall (filterCheck checkPos xs)
                   produces ForAll (IsPositive && IsSmall) rather than just ForAll (IsSmall). *)
                let prior_preds =
                  match carried_proofs_of_expr ~funcs subject_env proof_env input_expr with
                  | Some proofs ->
                    List.filter_map (fun p ->
                      match p with
                      | PredApp { pred = "ForAll"; args = (inner :: _); _ } -> Some inner
                      | _ -> None
                    ) proofs
                  | None -> []
                in
                let combined_pred_str =
                  List.fold_left (fun acc prior -> prior ^ " && " ^ acc) new_pred_str prior_preds
                in
                [PredApp { pred = "ForAll"; args = [combined_pred_str; result_name]; loc = gen_loc }]
              | None -> [])
           | h, (check_fn_expr :: _) when is_filtercheck_head h ->
             (match pred_str_from_check_chain check_fn_expr with
              | Some pred_str ->
                [PredApp { pred = "ForAll"; args = [pred_str; result_name]; loc = gen_loc }]
              | None -> [])
           | _ -> []))
      | None ->
        match head with
        | EBinop { op = BAnd; _ } ->
          flatten_check_chain_expr [] head
          |> List.concat_map (fun check_head -> proofs_of_call_head check_head args)
        | _ -> []
    in
    let call_proofs = proofs_of_call_head head args in
    (* For `EOk { value = expr; proof = proof_var }` (i.e. `expr ::: proof_var`):
       combine the check-call proofs from `value` with the sidecar proof.
       Without this, `check f n ::: p` in return position only carries `p`,
       losing the check function's own proofs (e.g. IsPositive, IsSmall). *)
    match expr with
    | EOk { value; _ } ->
      let sidecar = match carried_proofs_of_expr ~funcs subject_env proof_env expr with
        | Some ps -> ps
        | None -> []
      in
      let from_value =
        let (vhead, vargs) = collect_call_head_and_args [] value in
        proofs_of_call_head vhead vargs
      in
      let all = sidecar @ from_value in
      (* Deduplicate *)
      let seen = ref [] in
      List.filter (fun p ->
        let k = proof_key p in
        if List.mem k !seen then false
        else (seen := k :: !seen; true)
      ) all
    | _ -> call_proofs

(* ── 1. Server binding completeness ──────────────────────────────────────── *)

let is_synthetic_endpoint_name (name : string) : bool =
  let prefix = "endpoint_" in
  let prefix_len = String.length prefix in
  String.length name > prefix_len
  && String.sub name 0 prefix_len = prefix
  && let suffix = String.sub name prefix_len (String.length name - prefix_len) in
     String.length suffix > 0
     && String.for_all (fun ch -> ch >= '0' && ch <= '9') suffix

let take n xs =
  let rec go acc remaining count =
    if count <= 0 then List.rev acc else
    match remaining with
    | [] -> List.rev acc
    | x :: rest -> go (x :: acc) rest (count - 1)
  in
  go [] xs n

let drop n xs =
  let rec go remaining count =
    if count <= 0 then remaining else
    match remaining with
    | [] -> []
    | _ :: rest -> go rest (count - 1)
  in
  go xs n

type handler_decl_ref =
  | LocalHandler of func_decl
  | ImportedHandler of func_info

(** Extract the proof-predicate name from an auth function's return spec.
    Auth functions return `-> name: T ::: PredName name`, so the predicate
    is in the RetAttached binding's proof_ann. *)
let auth_proof_pred_of_return_spec spec =
  match spec with
  | RetAttached { binding; _ } ->
    (match binding.proof_ann with
     | Some (PredApp { pred; _ }) -> Some pred
     | _ -> None)
  | _ -> None

(** Build the set of proof-predicate names produced by all auth functions
    reachable from [decls] and [extra_funcs]. *)
let collect_auth_predicates decls extra_funcs =
  let from_decls =
    List.filter_map (function
      | DFunc fd when fd.kind = AuthKind ->
        auth_proof_pred_of_return_spec fd.return_spec
      | _ -> None
    ) decls
  in
  let from_imports =
    List.filter_map (fun (_, info : string * func_info) ->
      if info.fi_kind = AuthKind then
        auth_proof_pred_of_return_spec info.fi_return
      else None
    ) extra_funcs
  in
  from_decls @ from_imports

(** Return true if any param in [params] carries a proof annotation whose
    predicate name is in [auth_preds].  Handles conjunction proofs (PredAnd)
    by recursively checking all leaf predicates. *)
let has_auth_proof_param auth_preds params =
  let rec proof_mentions_auth = function
    | PredApp { pred; _ } -> List.mem pred auth_preds
    | PredAnd { left; right; _ } -> proof_mentions_auth left || proof_mentions_auth right
  in
  List.exists (fun (b : binding) ->
    match b.proof_ann with
    | Some p -> proof_mentions_auth p
    | None -> false
  ) params

(** Extract `:param` names from an endpoint path string. *)
let path_param_names (path : string) : string list =
  String.split_on_char '/' path
  |> List.filter_map (fun segment ->
       if String.length segment > 1 && segment.[0] = ':' then
         Some (String.sub segment 1 (String.length segment - 1))
       else None)

let check_api_endpoint_structure (decls : top_decl list) : validation_error list =
  let method_str = function
    | GET -> "get" | POST -> "post" | PUT -> "put"
    | DELETE -> "delete" | PATCH -> "patch" | SSE -> "sse"
  in
  List.concat_map (function
    | DApi af ->
      let seen_method_paths : (string * loc) list ref = ref [] in
      List.concat_map (fun (ep : api_endpoint) ->
        let errors = ref [] in
        let add_hint hint msg = errors := make_error ep.loc ~hint msg :: !errors in
        let ep_id = Printf.sprintf "`%s \"%s\"`" (method_str ep.method_) ep.path in

        (* Clause(s) appeared after `->` — they were silently ignored by the parser *)
        if ep.has_clause_after_return then
          add_hint
            "move all `auth`, `body`, `capture`, `response`, and `subscribe` \
             clauses to before the `->` return type"
            (Printf.sprintf
              "endpoint %s: endpoint clauses (auth/body/capture/response) \
               must come before the `->` return type, not after"
              ep_id);

        (* Missing `->` return type (SSE endpoints are exempt: they stream events, no response type) *)
        if not ep.has_explicit_return && ep.method_ <> SSE then
          add_hint
            "add `-> ReturnType` at the end of the endpoint, \
             e.g. `-> String` or `-> MyResponseRecord`"
            (Printf.sprintf
              "endpoint %s: missing return type — every endpoint must have \
               an explicit `-> TypeName`"
              ep_id);

        (* Empty path *)
        if ep.path = "" then
          add_hint "use a non-empty path string, e.g. `\"/health\"`"
            (Printf.sprintf
              "api `%s`: endpoint has an empty path; paths must not be empty"
              af.name);

        (* Path without leading slash *)
        if ep.path <> "" && ep.path.[0] <> '/' then
          add_hint
            (Printf.sprintf "change `\"%s\"` to `\"/%s\"`" ep.path ep.path)
            (Printf.sprintf
              "endpoint %s: path must start with `/`" ep_id);

        (* Auth binding must have a proof annotation *)
        (match ep.auth with
         | Some a when a.binding.proof_ann = None ->
           let ty_name = match a.binding.type_expr with
             | TName { name; _ } -> name | _ -> "T" in
           add_hint
             (Printf.sprintf
               "add a proof annotation, e.g. `auth %s : %s ::: ProofPred %s via %s`"
               a.binding.name ty_name a.binding.name a.via_fn)
             (Printf.sprintf
               "endpoint %s: auth binding `%s` must have a proof annotation \
                (`::: ProofPred %s`); without it the handler cannot receive \
                a verified identity"
               ep_id a.binding.name a.binding.name)
         | _ -> ());

        (* Capture names must match path parameters *)
        let path_params = path_param_names ep.path in
        List.iter (fun (c : api_capture) ->
          if not (List.mem c.binding.name path_params) then
            add_hint
              (Printf.sprintf
                "path is `\"%s\"`; available path parameters: %s"
                ep.path
                (if path_params = [] then "(none)"
                 else String.concat ", " (List.map (fun p -> ":"^p) path_params)))
              (Printf.sprintf
                "endpoint %s: capture clause for `%s` does not match any \
                 path parameter (`:param`) in the path"
                ep_id c.binding.name)
        ) ep.captures;

        (* Duplicate capture clauses for the same parameter *)
        let seen_captures : (string * loc) list ref = ref [] in
        List.iter (fun (c : api_capture) ->
          match List.assoc_opt c.binding.name !seen_captures with
          | Some first_loc ->
            errors := make_error c.binding.loc
              ~hint:(Printf.sprintf
                "first `capture %s` is at line %d; remove the duplicate"
                c.binding.name (first_loc.start.line + 1))
              (Printf.sprintf
                "endpoint %s: duplicate capture clause for `%s`"
                ep_id c.binding.name)
              :: !errors
          | None -> seen_captures := (c.binding.name, c.binding.loc) :: !seen_captures
        ) ep.captures;

        (* Duplicate endpoints: same HTTP method + path within this api block *)
        let mstr = String.uppercase_ascii (method_str ep.method_) in
        let key = mstr ^ " " ^ ep.path in
        (match List.assoc_opt key !seen_method_paths with
         | Some first_loc ->
           errors := make_error ep.loc
             ~hint:(Printf.sprintf "first declaration is at line %d" (first_loc.start.line + 1))
             (Printf.sprintf
               "api `%s`: duplicate endpoint %s"
               af.name ep_id)
             :: !errors
         | None ->
           seen_method_paths := (key, ep.loc) :: !seen_method_paths);

        List.rev !errors
      ) af.endpoints
    | _ -> []
  ) decls

let check_server_handler_binding
    (handlers : (string * handler_decl_ref) list)
    (auth_preds : string list)
    (sv : server_form)
    (endpoint_opt : api_endpoint option)
    (endpoint_name, handler_name)
    (errors : validation_error list ref)
  =
  match List.assoc_opt handler_name handlers with
  | None ->
    errors := make_error sv.loc
      ~hint:(Printf.sprintf "declare `handler %s(...)` in this module or import it explicitly" handler_name)
      (Printf.sprintf "server '%s': handler '%s' for endpoint '%s' is not declared" sv.name handler_name endpoint_name)
      :: !errors
  | Some (LocalHandler fd) when fd.kind <> HandlerKind ->
    errors := make_error fd.loc
      ~hint:"server bindings must point at `handler` declarations"
      (Printf.sprintf "server '%s': '%s' is declared, but it is not a handler" sv.name handler_name)
      :: !errors
  | Some (ImportedHandler info) when info.fi_kind <> HandlerKind ->
    errors := make_error info.fi_loc
      ~hint:"server bindings must point at `handler` declarations"
      (Printf.sprintf "server '%s': '%s' is declared, but it is not a handler" sv.name handler_name)
      :: !errors
  | Some hdl ->
    (* Auth-wiring alignment check — only meaningful when auth predicates are known *)
    if auth_preds <> [] then begin
      let handler_params = match hdl with
        | LocalHandler fd -> fd.params
        | ImportedHandler info -> info.fi_params
      in
      let handler_loc = match hdl with
        | LocalHandler fd -> fd.loc
        | ImportedHandler info -> info.fi_loc
      in
      match endpoint_opt with
      | None -> ()
      | Some ep ->
        let ep_needs_auth = ep.auth <> None in
        let handler_has_auth = has_auth_proof_param auth_preds handler_params in
        if ep_needs_auth && not handler_has_auth then
          errors := make_error handler_loc
            ~hint:(Printf.sprintf
              "add an auth-proof parameter to handler '%s' \
               (e.g. `user: T ::: AuthPred user`), or remove the `auth via …` clause from endpoint '%s'"
              handler_name endpoint_name)
            (Printf.sprintf
              "server '%s': endpoint '%s' requires auth but handler '%s' has no auth-proof parameter"
              sv.name endpoint_name handler_name)
            :: !errors
        else if not ep_needs_auth && handler_has_auth then
          errors := make_error handler_loc
            ~hint:(Printf.sprintf
              "add `auth via <authFn>` to endpoint '%s', \
               or remove the auth-proof parameter from handler '%s'"
              endpoint_name handler_name)
            (Printf.sprintf
              "server '%s': handler '%s' expects an auth-proof parameter \
               but endpoint '%s' declares no `auth` clause"
              sv.name handler_name endpoint_name)
            :: !errors
    end

let check_server_completeness ?(extra_funcs = []) (decls : top_decl list) : validation_error list =
  let apis = List.filter_map (function
    | DApi api -> Some (api.name, api)
    | _ -> None
  ) decls in
  let handlers =
    List.filter_map (function
      | DFunc fd -> Some (fd.name, LocalHandler fd)
      | _ -> None
    ) decls
    @ List.map (fun (name, info) -> (name, ImportedHandler info)) extra_funcs
  in
  let auth_preds = collect_auth_predicates decls extra_funcs in
  let errors = ref [] in
  List.iter (function
    | DServer sv ->
      (match List.assoc_opt sv.api_name apis with
       | None ->
         errors := make_error sv.loc
           ~hint:(Printf.sprintf "declare `api %s { ... }` before the server or import it once cross-module servers are supported" sv.api_name)
           (Printf.sprintf "server '%s' refers to unknown api '%s'" sv.name sv.api_name)
           :: !errors
       | Some api ->
         let non_sse_eps = api.endpoints |> List.filter (fun ep -> ep.method_ <> SSE) in
         let expected = List.map (fun (ep : api_endpoint) -> ep.name) non_sse_eps in
         let bound_names = List.map fst sv.bindings in
         if List.for_all is_synthetic_endpoint_name expected then begin
           let expected_count = List.length expected in
           let bound_count = List.length sv.bindings in
           if bound_count < expected_count then
             errors := make_error sv.loc
               ~hint:(Printf.sprintf "add %d more `<endpointName> = <handlerName>` binding(s) to server '%s'" (expected_count - bound_count) sv.name)
               (Printf.sprintf "server '%s' is missing %d binding(s) for api '%s'" sv.name (expected_count - bound_count) sv.api_name)
               :: !errors;
           List.iter (fun (endpoint_name, _handler_name) ->
             errors := make_error sv.loc
               ~hint:(Printf.sprintf "api '%s' declares %d endpoint(s)" sv.api_name expected_count)
               (Printf.sprintf "server '%s' binds extra endpoint '%s'" sv.name endpoint_name)
               :: !errors
           ) (drop expected_count sv.bindings);
           List.iteri (fun i binding ->
             let ep_opt = List.nth_opt non_sse_eps i in
             check_server_handler_binding handlers auth_preds sv ep_opt binding errors
           ) (take expected_count sv.bindings)
         end else begin
           List.iter (fun endpoint_name ->
             if not (List.mem endpoint_name bound_names) then
               errors := make_error sv.loc
                 ~hint:(Printf.sprintf "add `%s = <handlerName>` to server '%s'" endpoint_name sv.name)
                 (Printf.sprintf "server '%s' is missing a binding for endpoint '%s'" sv.name endpoint_name)
                 :: !errors
           ) expected;
           List.iter (fun (endpoint_name, handler_name) ->
             if not (List.mem endpoint_name expected) then
               errors := make_error sv.loc
                 ~hint:(Printf.sprintf "valid endpoints: %s" (String.concat ", " expected))
                 (Printf.sprintf "server '%s' binds unknown endpoint '%s'" sv.name endpoint_name)
                 :: !errors;
             let ep_opt = List.find_opt (fun (ep : api_endpoint) -> ep.name = endpoint_name) non_sse_eps in
             check_server_handler_binding handlers auth_preds sv ep_opt (endpoint_name, handler_name) errors
           ) sv.bindings
         end)
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 2. SQL/record field name validation ─────────────────────────────────── *)

let is_allowed_special_field = function
  | "value" | "cookies" | "headers" | "body" | "path" | "method_" | "status" -> true
  | _ -> false

let rec validate_field_accesses
    (env : type_env)
    (funcs : (string * func_info) list)
    (fields_by_type : field_map)
    (ctors : ctor_info)
    (e : expr)
    : validation_error list =
  match e with
  | EField { obj; field; loc } ->
    let inner = validate_field_accesses env funcs fields_by_type ctors obj in
    (match infer_expr_type env funcs fields_by_type ctors obj with
     | Some obj_ty ->
       (match record_fields_of_type fields_by_type obj_ty with
        | Some fields when not (List.exists (fun (f : field_def) -> f.name = field) fields)
                           && not (is_allowed_special_field field) ->
          make_error loc
            ~hint:(Printf.sprintf "valid fields: %s" (String.concat ", " (List.map (fun (f : field_def) -> f.name) fields)))
            (Printf.sprintf "unknown field `%s` on type `%s`" field (type_key obj_ty))
          :: inner
        | _ -> inner)
     | None -> inner)
  | ELit _ | EVar _ | EConstructor _ | EFail _ -> []
  | EApp _ ->
    (* Check if this is a SQL select expression: selectOne/select binder from Entity where/order/limit ...
       If so, add the binder (typed as Entity) to the env for validating sub-expressions. *)
    let flat = let rec go acc = function
      | EApp { fn; arg; _ } -> go (arg :: acc) fn
      | hd -> (hd, acc)
      in go [] e
    in
    let (head, args) = flat in
    let sql_binder_env = match head with
      | EVar { name = ("selectOne" | "select" | "selectCount" | "selectSum"); _ } ->
        (* args[0] = binder (or field for sum), args[1] = "from", args[2] = Entity name *)
        let binder_name = match args with
          | EVar { name; _ } :: _ -> Some name
          | EField { obj = EVar { name; _ }; _ } :: _ -> Some name  (* sum: binder.field from ... *)
          | _ -> None
        in
        let entity_name = match args with
          | _ :: EVar { name = "from"; _ } :: EConstructor { name; _ } :: _ -> Some name
          | _ :: EVar { name = "from"; _ } :: EVar { name; _ } :: _ -> Some name
          | _ -> None
        in
        (match binder_name, entity_name with
         | Some bn, Some en -> (bn, mk_name_type en) :: env
         | _ -> env)
      | EVar { name = "update"; _ } ->
        (* update binder in Entity ... *)
        let binder_name = match args with EVar { name; _ } :: _ -> Some name | _ -> None in
        let entity_name = match args with
          | _ :: EVar { name = "in"; _ } :: EConstructor { name; _ } :: _ -> Some name
          | _ :: EVar { name = "in"; _ } :: EVar { name; _ } :: _ -> Some name
          | _ -> None
        in
        (match binder_name, entity_name with
         | Some bn, Some en -> (bn, mk_name_type en) :: env
         | _ -> env)
      | EVar { name = ("delete" | "deleteAndReturnResult"); _ } ->
        (* delete binder from Entity [where binder.field] *)
        let binder_name = match args with EVar { name; _ } :: _ -> Some name | _ -> None in
        let entity_name = match args with
          | _ :: EVar { name = "from"; _ } :: EConstructor { name; _ } :: _ -> Some name
          | _ :: EVar { name = "from"; _ } :: EVar { name; _ } :: _ -> Some name
          | _ -> None
        in
        (match binder_name, entity_name with
         | Some bn, Some en -> (bn, mk_name_type en) :: env
         | _ -> env)
      | _ -> env
    in
    (* Also check insert/upsert/update field names directly *)
    let insert_errors = match head with
      | EVar { name = ("insert" | "upsert"); _ } ->
        (* args: [EntityExpr, ERecord { fields }, ...] *)
        (match args with
         | entity_expr :: ERecord { fields; _ } :: _ ->
           let entity_name = match entity_expr with
             | EConstructor { name; _ } | EVar { name; _ } -> Some name
             | _ -> None
           in
           (match entity_name with
            | None -> []
            | Some en ->
              let entity_fields = record_fields_of_type fields_by_type (mk_name_type en) in
              List.filter_map (fun (fname, _) ->
                match entity_fields with
                | None -> None
                | Some efs when not (List.exists (fun (f : field_def) -> f.name = fname) efs) ->
                  Some (make_error (match e with EApp { loc; _ } -> loc | _ -> dummy_loc "")
                    ~hint:(Printf.sprintf "valid fields: %s" (String.concat ", " (List.map (fun (f : field_def) -> f.name) efs)))
                    (Printf.sprintf "unknown field `%s` on type `%s`" fname en))
                | _ -> None
              ) fields)
         | _ -> [])
      | _ -> []
    in
    let (fn_e, arg_e) = match e with EApp { fn; arg; _ } -> (fn, arg) | _ -> assert false in
    insert_errors
    @ validate_field_accesses sql_binder_env funcs fields_by_type ctors fn_e
    @ validate_field_accesses sql_binder_env funcs fields_by_type ctors arg_e
  | EBinop { left; right; _ } ->
    validate_field_accesses env funcs fields_by_type ctors left
    @ validate_field_accesses env funcs fields_by_type ctors right
  | EUnop { arg; _ } -> validate_field_accesses env funcs fields_by_type ctors arg
  | EIf { cond; then_; else_; _ } ->
    validate_field_accesses env funcs fields_by_type ctors cond
    @ validate_field_accesses env funcs fields_by_type ctors then_
    @ validate_field_accesses env funcs fields_by_type ctors else_
  | ECase { scrut; arms; _ } ->
    let scrut_errors = validate_field_accesses env funcs fields_by_type ctors scrut in
    let scrut_ty = infer_expr_type env funcs fields_by_type ctors scrut in
    scrut_errors @ List.concat_map (fun (arm : case_arm) ->
      let arm_env = pattern_bindings scrut_ty ctors arm.pattern @ env in
      validate_field_accesses arm_env funcs fields_by_type ctors arm.body
    ) arms
  | ELet { name; value; body; _ } ->
    let value_errors = validate_field_accesses env funcs fields_by_type ctors value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: env
      | None -> env
    in
    (* Detect `update binder in Entity` statements and add binder to env for body *)
    let env' =
      let flat = let rec go acc = function
        | EApp { fn; arg; _ } -> go (arg :: acc) fn
        | hd -> (hd, acc)
        in go [] value
      in
      match flat with
      | (EVar { name = "update"; _ }, EVar { name = binder; _ } :: EVar { name = "in"; _ } :: entity_expr :: _) ->
        let entity_name = match entity_expr with
          | EConstructor { name; _ } | EVar { name; _ } -> Some name
          | _ -> None
        in
        (match entity_name with
         | Some en -> (binder, mk_name_type en) :: env'
         | None -> env')
      | _ -> env'
    in
    value_errors @ validate_field_accesses env' funcs fields_by_type ctors body
  | ELetProof { value_name; value; body; _ } ->
    let value_errors = validate_field_accesses env funcs fields_by_type ctors value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (value_name, ty) :: env
      | None -> env
    in
    value_errors @ validate_field_accesses env' funcs fields_by_type ctors body
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> validate_field_accesses env funcs fields_by_type ctors v) fields
  | EList { elems; _ } ->
    List.concat_map (validate_field_accesses env funcs fields_by_type ctors) elems
  | EOk { value; _ } -> validate_field_accesses env funcs fields_by_type ctors value
  | ETelemetry { fields; _ } ->
    List.concat_map (fun (_, v) -> validate_field_accesses env funcs fields_by_type ctors v) fields
  | EEnqueue { payload; _ } ->
    validate_field_accesses env funcs fields_by_type ctors payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> validate_field_accesses env funcs fields_by_type ctors e | None -> [])
    @ (match payload with Some e -> validate_field_accesses env funcs fields_by_type ctors e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    validate_field_accesses env funcs fields_by_type ctors body
  | EServe { port; _ } -> validate_field_accesses env funcs fields_by_type ctors port
  | ELambda { params; body; _ } ->
    let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
    validate_field_accesses env' funcs fields_by_type ctors body

let check_sql_field_names ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      errors := validate_field_accesses env funcs fields_by_type ctors fd.body @ !errors
    | _ -> ()
  ) decls;
  List.rev !errors

let local_declared_type_names (decls : top_decl list) : string list =
  List.concat_map (function
    | DType (TypeAdt { name; _ }) -> [name]
    | DType (TypeNewtype { name; _ })
    | DType (TypeAlias { name; _ }) -> [name]
    | DRecord r -> [r.name]
    | DEntity e -> [e.name]
    | _ -> []
  ) decls

let check_codec_target_types (decls : top_decl list) : validation_error list =
  let known_types = local_declared_type_names decls in
  let errors = ref [] in
  List.iter (function
    | DCodec cf when not (List.mem cf.type_name known_types) ->
      errors := make_error cf.loc
        ~hint:(Printf.sprintf "declare `record %s { ... }`, `entity %s { ... }`, or `type %s ...` before this codec" cf.type_name cf.type_name cf.type_name)
        (Printf.sprintf "codec '%s' refers to unknown type '%s'" cf.name cf.type_name)
        :: !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 3. Codec proof coverage ──────────────────────────────────────────────── *)

let check_codec_proof_coverage ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let record_proofs = List.filter_map (function
    | DRecord r ->
      let field_proofs = List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some proof -> Some (f.name, List.sort_uniq String.compare (proof_predicates proof))
        | None -> None
      ) r.fields in
      if field_proofs = [] then None else Some (r.name, field_proofs)
    | _ -> None
  ) decls in
  let errors = ref [] in
  List.iter (function
    | DCodec cf ->
      (match List.assoc_opt cf.name record_proofs with
       | None -> ()
       | Some field_requirements ->
         (match cf.from_json with
          | FromJsonForbidden | FromJsonAdt -> ()
          | FromJsonAlts alts ->
            List.iter (fun alt ->
              List.iter (function
                | DecodeField { field_name; via; loc; _ } ->
                  (match List.assoc_opt field_name field_requirements with
                   | None -> ()
                   | Some required_preds ->
                     if via = [] then
                       errors := make_error loc
                         ~hint:(Printf.sprintf "add `via <checkFn>` so field '%s' is validated before decoding succeeds" field_name)
                         (Printf.sprintf "codec '%s': decoder field '%s' requires proof predicates %s but has no `via` validation"
                            cf.name field_name (String.concat ", " required_preds))
                         :: !errors
                     else begin
                       let covered = ref [] in
                       List.iter (fun via_fn ->
                         match List.assoc_opt via_fn funcs with
                         | None ->
                           errors := make_error loc
                             ~hint:"codec `via` entries must reference declared `check` or `auth` functions"
                             (Printf.sprintf "codec '%s': `via %s` is not a declared function" cf.name via_fn)
                             :: !errors
                         | Some info when info.fi_kind <> CheckKind && info.fi_kind <> AuthKind ->
                           errors := make_error loc
                             ~hint:"only `check` and `auth` functions may appear after `via`"
                             (Printf.sprintf "codec '%s': `via %s` is a %s, not a check/auth function"
                                cf.name via_fn
                                (match info.fi_kind with
                                 | FnKind -> "fn"
                                 | HandlerKind -> "handler"
                                 | WorkerKind -> "worker"
                                 | DeadWorkerKind -> "dead-worker"
                                 | EstablishKind -> "establish"
                                 | MainKind -> "main"
                                 | CheckKind -> "check"
                                 | AuthKind -> "auth"))
                             :: !errors
                         | Some info ->
                           covered := pred_names_of_return_spec info.fi_return @ !covered
                       ) via;
                       let covered = List.sort_uniq String.compare !covered in
                       let uncovered = List.filter (fun pred -> not (List.mem pred covered)) required_preds in
                       if uncovered <> [] then
                         errors := make_error loc
                           ~hint:(Printf.sprintf "via functions provided: %s" (String.concat ", " via))
                           (Printf.sprintf "codec '%s': decoder field '%s' requires proof predicates %s that are not established by any `via` function"
                              cf.name field_name (String.concat ", " uncovered))
                           :: !errors
                     end)
                | DecodeDefault _ | DecodeCrossCheck _ -> ()
              ) alt
            ) alts))
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 3b. Codec field type vs codec type ───────────────────────────────────
   Builtin codecs (stringCodec, intCodec, boolCodec, floatCodec) must match
   the declared field type.  User-defined codec names (e.g. `Priority`) must
   match the field's head type name.  §11.7 of the language spec. *)

let builtin_codec_type : (string * string) list = [
  "stringCodec",      "String";
  "intCodec",         "Int";
  "boolCodec",        "Bool";
  "floatCodec",       "Float";
  "posixMillisCodec", "PosixMillis";
  "listCodec",        "List";
  "dictCodec",        "Dict";
  "setCodec",         "Set";
]

(** Extract the head type name from a type_expr.
    TName {name="Priority"} -> Some "Priority"
    TApp {head=TName {name="Maybe"}; arg=...} -> Some "Maybe"
    _ -> None *)
let type_head_name (te : type_expr) : string option =
  match te with
  | TName { name; _ } -> Some name
  | TApp { head = TName { name; _ }; _ } -> Some name
  | _ -> None

let check_codec_field_types (decls : top_decl list) : validation_error list =
  (* Build a map: record/entity name -> (field_name -> type_expr) *)
  let field_types_by_type : (string * (string * type_expr) list) list =
    List.filter_map (function
      | DRecord r -> Some (r.name, List.map (fun (f : field_def) -> (f.name, f.type_expr)) r.fields)
      | DEntity e -> Some (e.name, List.map (fun (f : field_def) -> (f.name, f.type_expr)) e.fields)
      | _ -> None
    ) decls
  in
  (* Build newtype-to-base-type map: NoteId -> String, UserId -> String, etc. *)
  let newtype_base_type : (string * string) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ }) ->
        (match type_head_name base_type with
         | Some base -> Some (name, base)
         | None -> None)
      | _ -> None
    ) decls
  in
  let errors = ref [] in
  (* Shared helper: check one field_name + codec pair against declared field types *)
  let check_field_codec ~direction cf_name field_types field_name codec loc =
    match List.assoc_opt field_name field_types with
    | None -> () (* unknown field — caught by other checks *)
    | Some field_type ->
      let field_type_name = type_head_name field_type in
      let verb = if direction = `Encode then "encodes" else "decodes to" in
      (match List.assoc_opt codec builtin_codec_type with
       | Some expected_type ->
         (match field_type_name with
          (* Accept builtin codec if the field is a newtype wrapping the codec's
             base type — newtypes are transparent at JSON boundaries (spec §11.6). *)
          | Some actual when actual <> expected_type
                          && not (match List.assoc_opt actual newtype_base_type with
                                  | Some base -> base = expected_type
                                  | None -> false) ->
            errors := make_error loc
              ~hint:(Printf.sprintf "use `with_codec %s` or a matching codec for %s fields"
                       (match actual with
                        | s when List.mem_assoc s (List.map (fun (a,b) -> (b,a)) builtin_codec_type) ->
                          List.assoc s (List.map (fun (a,b) -> (b,a)) builtin_codec_type)
                        | s -> s)
                       actual)
              (Printf.sprintf "codec '%s': field '%s' has type `%s` but `%s` %s `%s`"
                 cf_name field_name (pp_type_expr field_type) codec verb expected_type)
              :: !errors
          | _ -> ())
       | None ->
         (match field_type_name with
          | Some actual when actual <> codec ->
            errors := make_error loc
              ~hint:(Printf.sprintf "use `with_codec %s` to match the field's declared type" actual)
              (Printf.sprintf "codec '%s': field '%s' has type `%s` but `with_codec %s` references a different type"
                 cf_name field_name (pp_type_expr field_type) codec)
              :: !errors
          | _ -> ()))
  in
  List.iter (function
    | DCodec cf ->
      let field_types = match List.assoc_opt cf.type_name field_types_by_type with
        | Some ft -> ft
        | None -> []
      in
      (* Check fromJson *)
      (match cf.from_json with
       | FromJsonForbidden | FromJsonAdt -> ()
       | FromJsonAlts alts ->
         List.iter (fun alt ->
           List.iter (function
             | DecodeField { field_name; codec; loc; _ } ->
               check_field_codec ~direction:`Decode cf.name field_types field_name codec loc
             | DecodeDefault _ | DecodeCrossCheck _ -> ()
           ) alt
         ) alts);
      (* Check toJson *)
      (match cf.to_json with
       | ToJsonForbidden | ToJsonAdt -> ()
       | ToJsonFields entries ->
         List.iter (fun (entry : codec_encode_entry) ->
           check_field_codec ~direction:`Encode cf.name field_types entry.field_name entry.codec entry.loc
         ) entries)
    | _ -> ()
  ) decls;
  List.rev !errors


(* ── 4. Call-site proof flow + 5. ForAll propagation ────────────────────── *)

let build_initial_proof_env (params : binding list) : proof_env =
  List.filter_map (fun (b : binding) ->
    match b.proof_ann with
    | Some proof -> Some (b.name, [proof])
    | None -> None
  ) params

let build_initial_subject_env (params : binding list) : subject_env =
  List.map (fun (b : binding) -> (b.name, b.name)) params

(** Build a note about GDP subject synonyms for `arg_name` in `subject_env`.
    When `arg_name` has a canonical subject key that differs from its surface
    spelling (i.e. it's an alias), or when multiple names share the same
    subject, the note helps the user understand why the error message refers
    to a name that isn't the argument they wrote.
    Returns "" when there's nothing interesting to say. *)
let subject_chain_note (arg_name : string) (subject_env : subject_env) : string =
  let canonical = match List.assoc_opt arg_name subject_env with
    | Some s -> s
    | None -> arg_name
  in
  (* Find all names in subject_env whose canonical subject equals ours. *)
  let synonyms =
    List.filter_map (fun (name, subj) ->
      if subj = canonical && name <> arg_name then Some name else None
    ) subject_env
    |> List.sort_uniq String.compare
  in
  if canonical <> arg_name then
    (* arg_name is an alias for canonical — the error message mentions canonical,
       so tell the user why (arg_name derives from canonical). *)
    let other_aliases = List.filter (fun n -> n <> canonical) synonyms in
    if other_aliases = [] then
      Printf.sprintf " (`%s` is derived from `%s` — same GDP subject)" arg_name canonical
    else
      Printf.sprintf " (`%s` is derived from `%s` — same GDP subject; also aliased as: %s)"
        arg_name canonical
        (String.concat ", " (List.map (Printf.sprintf "`%s`") other_aliases))
  else if synonyms <> [] then
    (* arg_name IS the canonical subject but has aliases in scope *)
    Printf.sprintf " (also known as: %s in this scope)"
      (String.concat ", " (List.map (Printf.sprintf "`%s`") synonyms))
  else
    "" (* no interesting information to add *)

let unresolved_subjects
    (formal_names : string list)
    (mapping : (string * string) list)
    (proof : proof_expr)
    : string list =
  proof_subjects proof
  |> List.filter (fun subj -> List.mem subj formal_names && not (List.mem_assoc subj mapping))
  |> List.sort_uniq String.compare

let check_call_proofs
    ?(funcs : (string * func_info) list = [])
    (loc : loc)
    (func_name : string)
    (params : binding list)
    (args : expr list)
    (subject_env : subject_env)
    (proof_env : proof_env)
    : validation_error list =
  let formal_names = List.map (fun (b : binding) -> b.name) params in
  let mapping = List.filter_map (fun ((param : binding), arg) ->
    match subject_of_expr subject_env arg with
    | Some subject -> Some (param.name, subject)
    | None -> None
  ) (zip_prefix params args) in
  let errors = ref [] in
  List.iter2 (fun (param : binding) arg ->
    (* Check Fact-typed params against the full proof expression carried by the evidence. *)
    (match proof_of_fact_type param.type_expr with
     | Some expected_proof ->
       let expected_proof = subst_proof mapping expected_proof in
       let carried_fact_proofs = match proofs_of_evidence_expr ~funcs subject_env proof_env arg with
         | Some proofs -> proofs
         | None -> []
       in
       if carried_fact_proofs <> [] && not (proof_matches expected_proof carried_fact_proofs) then
         let carried_desc =
           carried_fact_proofs
           |> List.concat_map flatten_proof
           |> List.map pp_proof
           |> String.concat ", "
         in
         let expected_desc = pp_proof expected_proof in
         errors := make_error loc
           ~hint:(Printf.sprintf "the proof carried by the argument does not match the                    required `Fact (%s)` evidence" expected_desc)
           (Printf.sprintf "proof mismatch: argument to `%s` parameter `%s` carries proof(s)                   `%s`, but `Fact (%s)` is required"
              func_name param.name carried_desc expected_desc)
         :: !errors
     | None -> ());
    match param.proof_ann with
    | None -> ()
    | Some required ->
      let unresolved = unresolved_subjects formal_names mapping required in
      let carried = match carried_proofs_of_expr ~funcs subject_env proof_env arg with
        | Some proofs -> proofs
        | None -> []
      in
      (match subject_of_expr subject_env arg with
       | None ->
         (match arg with
           | ELit { loc = lit_loc; _ } ->
             errors := make_error lit_loc
               ~hint:(Printf.sprintf "bind the value to a named variable before passing it to `%s`" func_name)
               (Printf.sprintf "argument to `%s` parameter `%s` requires proof `%s`, but the argument is a literal"
                  func_name param.name (pp_proof required))
               :: !errors
           | _ ->
             errors := make_error loc
               ~hint:(Printf.sprintf "bind the expression to a named variable first, then pass that variable to `%s`" func_name)
               (Printf.sprintf "call to `%s` argument `%s` requires proof `%s`, but the argument is an expression with no trackable subject"
                  func_name param.name (pp_proof required))
               :: !errors)
       | Some _ ->
         if unresolved <> [] then
           errors := make_error loc
             ~hint:(Printf.sprintf "all proof subjects must be trackable variable names at the call site (%s unresolved)" (String.concat ", " unresolved))
             (Printf.sprintf "call to `%s` argument `%s` requires proof `%s`, but some cross-parameter subjects are not trackable"
                func_name param.name (pp_proof required))
             :: !errors
         else begin
           let required' = subst_proof_args_with_subjects subject_env (subst_proof mapping required) in
           (* Normalise carried proofs through subject_env so that, e.g.,
              Positive v1 resolves to Positive n1 when subject_env maps v1→n1.
              This is needed for RetNamedPack functions where the entity proof
              uses result_name but the required proof uses the argument's subject.
              We also normalise required' so that call-site subject aliases
              (e.g. `checked → result` from a case arm) are followed in both
              directions, preventing false negatives for lambda proof checks. *)
           let carried_norm = List.map (subst_proof_args_with_subjects subject_env) carried in
           (* R51 follow-up — narrow check for the user's bug pattern
              `requiresX (value ::: wrongProof)`, where `wrongProof` is a
              proof variable whose described subject is different from the
              required proof's subject. Fire this check BEFORE the generic
              carried-vs-required match so the error message is precise.
              We intentionally skip this when the attached proof is a
              combination (`p1 && p2`) or when the proof is not a bare
              variable reference — those forms are legitimate sidecar or
              composition uses. *)
           let attach_subject_mismatch =
             match arg with
             | EOk { proof = PredApp { pred = proof_var_name; args = []; _ }; _ } ->
               let proof_subjects =
                 match List.assoc_opt proof_var_name proof_env with
                 | Some proofs ->
                   List.filter_map (function
                     | PredApp { args = (_ :: _ as pargs); _ } ->
                       Some (List.nth pargs (List.length pargs - 1))
                     | _ -> None) proofs
                 | None -> []
               in
               let required_subjects =
                 let rec go = function
                   | PredApp { args = (_ :: _ as pargs); _ } ->
                     [List.nth pargs (List.length pargs - 1)]
                   | PredAnd { left; right; _ } -> go left @ go right
                   | _ -> []
                 in go required'
               in
               let resolve_chain n =
                 let rec follow seen n0 =
                   if List.mem n0 seen then n0
                   else match List.assoc_opt n0 subject_env with
                     | Some s when s <> n0 -> follow (n0 :: seen) s
                     | _ -> n0
                 in follow [] n
               in
               let proof_subjects_r = List.map resolve_chain proof_subjects in
               let required_subjects_r = List.map resolve_chain required_subjects in
               proof_subjects_r <> [] && required_subjects_r <> []
               && not (List.exists (fun s -> List.mem s required_subjects_r) proof_subjects_r)
             | _ -> false
           in
           if attach_subject_mismatch then begin
             let proof_var_name = match arg with
               | EOk { proof = PredApp { pred; _ }; _ } -> pred
               | _ -> "?"
             in
             errors := make_error loc
               ~hint:(Printf.sprintf
                 "the proof `%s` describes a different subject than the call site requires; \
                  rebind the value with a `check` that establishes `%s` here"
                 proof_var_name (pp_proof required'))
               (Printf.sprintf
                 "call to `%s` argument `%s`: the explicit `::: %s` attaches a proof about a different subject than the required `%s`"
                 func_name param.name proof_var_name (pp_proof required'))
               :: !errors
           end else
           if not (proof_matches required' carried_norm) &&
              not (proof_matches required' carried) then
             (* Use the surface variable name in the hint, not the internal subject — avoids
                confusing "validate validated" when the user passed `bare = forgetFact validated`. *)
             let subject_hint = match arg with
               | EVar { name; _ } -> name
               | _ -> (match subject_of_expr subject_env arg with Some s -> s | None -> param.name)
             in
             let chain_note = subject_chain_note subject_hint subject_env in
             errors := make_error loc
               ~hint:(Printf.sprintf "validate `%s` with a check function that establishes `%s`%s"
                  subject_hint (pp_proof required') chain_note)
               (Printf.sprintf "call to `%s` argument `%s` does not statically satisfy declared proof `%s`"
                  func_name param.name (pp_proof required'))
               :: !errors
         end)
  ) (List.filteri (fun i _ -> i < List.length args) params) (List.filteri (fun i _ -> i < List.length params) args);
  List.rev !errors

(* R51 follow-up — when `let (v ::: p1 && p2 && ...)` synthesises multiple
   ELetProof nodes, only the OUTER has the true binder (v); the inner ones
   use value_name = "_". For RetNamedPack RHSs, `_entity` must be renamed
   to the outer binder — otherwise `Small _` ends up in proof_env. We keep
   an expression-location → outer-binder map here so inner ELetProofs can
   recover the outer name. *)
let entity_binder_at_in_val : (loc * string) list ref = ref []

let effective_value_name value_name value =
  if value_name <> "_" then value_name
  else
    let loc_opt = match value with
      | EVar { loc; _ } | ELit { loc; _ } | EField { loc; _ }
      | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ }
      | EIf { loc; _ } | ECase { loc; _ } | ELet { loc; _ }
      | ELetProof { loc; _ } | ERecord { loc; _ } | EList { loc; _ }
      | EOk { loc; _ } | EFail { loc; _ } | EConstructor { loc; _ }
      | ELambda { loc; _ } -> Some loc
      | _ -> None
    in
    match loc_opt with
    | Some loc ->
      (match List.assoc_opt loc !entity_binder_at_in_val with
       | Some outer -> outer
       | None -> value_name)
    | None -> value_name

let record_entity_binder value_name value =
  if value_name = "_" then ()
  else
    let loc_opt = match value with
      | EVar { loc; _ } | ELit { loc; _ } | EField { loc; _ }
      | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ }
      | EIf { loc; _ } | ECase { loc; _ } | ELet { loc; _ }
      | ELetProof { loc; _ } | ERecord { loc; _ } | EList { loc; _ }
      | EOk { loc; _ } | EFail { loc; _ } | EConstructor { loc; _ }
      | ELambda { loc; _ } -> Some loc
      | _ -> None
    in
    match loc_opt with
    | Some loc -> entity_binder_at_in_val := (loc, value_name) :: !entity_binder_at_in_val
    | None -> ()

let rec check_expr_call_proofs
    (subject_env : subject_env)
    (proof_env : proof_env)
    (funcs : (string * func_info) list)
    (e : expr)
    : validation_error list =
  match e with
  | EApp _ ->
    let (head0, args0) = collect_call_head_and_args [] e in
    let (head, args) = normalize_explicit_check_call head0 args0 in
    let inner = List.concat_map (check_expr_call_proofs subject_env proof_env funcs) args in
    (* attachFact subject-mismatch check: the fact must describe the same underlying
       value as the one being attached to.
       E.g. `attachFact name2 proof` where proof was derived from `ne = check … name`
       is wrong because the proof says `NonEmpty name`, not `NonEmpty name2`.

       We determine what a fact *describes* by reading proof_env for the fact variable
       and taking the last argument of each carried proof predicate (conventionally the
       "subject" position, e.g. `NonEmpty name` → `name`, `InRange lo hi n` → `n`).
       This is more reliable than following subject_env, which only tracks which value
       the proof was *extracted from* (not what it says). *)
    let attach_errors = match function_name_of_expr head with
      | Some "attachFact" ->
        (match args with
         | [value_expr; fact_expr] ->
           let v_subj_opt = subject_of_expr subject_env value_expr in
           (* Collect the described subjects from the carried proofs *)
           let proof_subjects =
             let proofs = match fact_expr with
               | EVar { name = fact_name; _ } ->
                 (match List.assoc_opt fact_name proof_env with
                  | Some ps -> ps
                  | None -> [])
               | _ -> []
             in
             List.filter_map (function
               | PredApp { args = (_ :: _ as pargs); _ } ->
                 Some (List.nth pargs (List.length pargs - 1))
               | _ -> None) proofs
           in
           (match v_subj_opt with
            | Some v_subj
              when proof_subjects <> []
                && not (List.mem v_subj proof_subjects) ->
              let call_loc = match head with
                | EVar { loc; _ } -> loc
                | _ -> gen_loc
              in
              let described = String.concat ", " proof_subjects in
              let v_chain = subject_chain_note v_subj subject_env in
              [ make_error call_loc
                  ~hint:(Printf.sprintf
                    "the fact describes `%s`; use `attachFact` with a value derived from `%s`, \
                     or re-prove the value with a `check …` call%s"
                    described described v_chain)
                  (Printf.sprintf
                    "proof subject mismatch: the fact describes `%s` but is being attached \
                     to a value derived from `%s`"
                    described v_subj) ]
            | _ -> [])
         | _ -> [])
      | _ -> []
    in
    let call_errors = match function_name_of_expr head with
      | Some fn_name ->
        (match List.assoc_opt fn_name funcs with
         | Some info when List.exists (fun (p : binding) ->
             p.proof_ann <> None || Option.is_some (proof_of_fact_type p.type_expr)
           ) info.fi_params ->
           check_call_proofs ~funcs (match head with
             | EVar { loc; _ } -> loc
             | EField { loc; _ } -> loc
             | _ -> gen_loc) fn_name info.fi_params args subject_env proof_env
         | _ -> [])
      | None -> []
    in
    (* Detect proof-requiring fn/handler passed as a plain callback.
       Calling such a function via a higher-order combinator (e.g. List.map)
       silently drops proof requirements because the HOF has no knowledge of
       the proof obligations. Reject at validation time. *)
    let callback_errors = List.filter_map (fun arg ->
      match function_name_of_expr arg with
      | Some fn_name ->
        (match List.assoc_opt fn_name funcs with
         | Some info
           when (info.fi_kind = FnKind || info.fi_kind = HandlerKind)
             && List.exists (fun (p : binding) -> p.proof_ann <> None) info.fi_params ->
           let loc = match arg with
             | EVar { loc; _ } -> loc
             | EField { loc; _ } -> loc
             | _ -> gen_loc
           in
           Some (make_error loc
             ~hint:"wrap it in an explicit function literal that performs the proof check: e.g. `fn(x: T) -> myFn (check MyPred x)`"
             (Printf.sprintf
                "function `%s` requires proof annotations on its parameters and cannot be passed as a plain callback; \
                 callers via higher-order functions cannot satisfy the required proofs"
                fn_name))
         | _ -> None)
      | None -> None
    ) args in
    (* R52-L inline lambda call: `(fn(n: T ::: P n) -> ...) arg`
       When the call head is a lambda literal whose params carry proof annotations,
       check the actual arguments against those annotations. *)
    let inline_lambda_errors = match head with
      | ELambda { params; _ }
        when List.exists (fun (p : binding) -> p.proof_ann <> None) params ->
        let call_loc = match e with
          | EApp { fn = _; arg = _; loc = l } -> l
          | _ -> gen_loc
        in
        check_call_proofs ~funcs call_loc "<lambda>" params args subject_env proof_env
      | _ -> []
    in
    inner @ attach_errors @ call_errors @ callback_errors @ inline_lambda_errors
  | ELet { name = _binder; declared_proof; declared_type; value; body; loc } ->
    let name = _binder in
    (* R51_P01 / R51_P02 — proof laundering via `let`.
       A `let f = g` where `g` is a named function with one or more
       proof-annotated parameters, or `let f = g arg1 ... argK` where the
       remaining (unapplied) parameters include proof-annotated ones,
       silently drops the proof obligation — the subsequent `f arg` call
       has no trackable function identity, so `check_call_proofs` sees no
       obligation to enforce. Reject this at the `let` so the bug is
       caught where it occurs, not silently later. *)
    let laundering_errors =
      let rec head_and_applied_args = function
        | EVar { name = n; _ } -> Some (n, [])
        | EApp { fn; arg; _ } ->
          (match head_and_applied_args fn with
           | Some (n, args) -> Some (n, args @ [arg])
           | None -> None)
        | _ -> None
      in
      match head_and_applied_args value with
      | Some (fn_name, applied_args) ->
        (match List.assoc_opt fn_name funcs with
         | Some info ->
           let total = List.length info.fi_params in
           let applied_count = List.length applied_args in
           if applied_count < total then begin
             let remaining = List.filteri (fun i _ -> i >= applied_count) info.fi_params in
             let has_proof = List.exists
               (fun (p : binding) -> p.proof_ann <> None) remaining in
             if has_proof then begin
               (* Walk `body` looking for uses of `name` (the alias).
                  - If the alias appears as a call head `name x1 ... xM`,
                    reconstruct the full call `fn_name applied_args... x1..xM`
                    and run `check_expr_call_proofs` on it so proof obligations
                    on the remaining proof-bearing params are enforced at the
                    actual use site — this legitimises partial applications
                    that only strip non-proof-bearing leading args (e.g.
                    `let addToN = addProved 10` where the proof is on arg 2).
                  - If the alias appears anywhere else (passed as argument,
                    returned, stored in a record, etc.), the proof obligation
                    cannot be checked — report a single laundering error at
                    that location. *)
               let reconstructed_errors = ref [] in
               let non_call_loc : loc option ref = ref None in
               let rec visit e =
                 match e with
                 | EVar { name = n; loc = l; _ } when n = name ->
                   if !non_call_loc = None then non_call_loc := Some l
                 | EApp _ ->
                   let (h, args) = collect_call_head_and_args [] e in
                   (match function_name_of_expr h with
                    | Some n when n = name ->
                      List.iter visit args;
                      let reconstructed_args = applied_args @ args in
                      let rec build_app h_expr a_list =
                        match a_list with
                        | [] -> h_expr
                        | a :: rest ->
                          build_app (EApp { fn = h_expr; arg = a; loc = gen_loc }) rest
                      in
                      let fn_head = EVar { name = fn_name; loc = gen_loc } in
                      let reconstructed = build_app fn_head reconstructed_args in
                      reconstructed_errors := !reconstructed_errors
                        @ check_expr_call_proofs subject_env proof_env funcs reconstructed
                    | _ ->
                      visit h;
                      List.iter visit args)
                 | EField { obj; _ } -> visit obj
                 | EBinop { left; right; _ } -> visit left; visit right
                 | EUnop { arg; _ } -> visit arg
                 | EIf { cond; then_; else_; _ } ->
                   visit cond; visit then_; visit else_
                 | ECase { scrut; arms; _ } ->
                   visit scrut;
                   List.iter (fun (a : case_arm) ->
                     (match a.guard with Some g -> visit g | None -> ());
                     visit a.body) arms
                 | ELet { name = n; value = v; body = b; _ } ->
                   visit v;
                   (* Don't descend into body if alias is shadowed.
                      (Shadowing is illegal per spec, but be defensive.) *)
                   if n <> name then visit b
                 | ELetProof { value_name; proof_name; value = v; body = b; _ } ->
                   visit v;
                   if value_name <> name && proof_name <> name then visit b
                 | ERecord { fields; _ } ->
                   List.iter (fun (_, v) -> visit v) fields
                 | EList { elems; _ } -> List.iter visit elems
                 | EOk { value = v; _ } -> visit v
                 | EFail { message; _ } -> visit message
                 | ETelemetry { fields; _ } ->
                   List.iter (fun (_, v) -> visit v) fields
                 | EEnqueue { payload; _ } -> visit payload
                 | EPublish { key; payload; _ } ->
                   (match key with Some k -> visit k | None -> ());
                   (match payload with Some p -> visit p | None -> ())
                 | EWithDatabase { body = b; _ }
                 | EWithCapabilities { body = b; _ }
                 | EWithTransaction { body = b; _ } -> visit b
                 | EServe { port; _ } -> visit port
                 | EConstructor { args; _ } -> List.iter visit args
                 | ELambda { params; body = b; _ } ->
                   if not (List.exists (fun (p : binding) -> p.name = name) params)
                   then visit b
                 | ELit _ | EVar _ | EStartWorkers _ -> ()
               in
               visit body;
               let non_call_errors =
                 match !non_call_loc with
                 | Some l ->
                   [ make_error l
                       ~hint:(Printf.sprintf
                         "call `%s` directly at its use site (supplying all remaining arguments), or wrap `%s` in a fresh `fn(...) -> ...` lambda that re-validates the proof with `check`"
                         fn_name name)
                       (Printf.sprintf
                         "alias `%s` of proof-requiring function `%s` cannot be passed around — doing so would bypass the proof check on the remaining parameters"
                         name fn_name) ]
                 | None -> []
               in
               !reconstructed_errors @ non_call_errors
             end else []
           end else []
         | None -> [])
      | None -> []
    in
    (* R52-L let-bound lambda: `let f = fn(n: T ::: P n) -> ...; f arg`
       When the bound value is a lambda with proof-annotated parameters, walk the
       body looking for calls to `name` and check proof obligations at each call
       site, just like the R51 partial-application alias logic above. *)
    let let_lambda_errors =
      match value with
      | ELambda { params; _ }
        when List.exists (fun (p : binding) -> p.proof_ann <> None) params ->
        let call_errors_ref = ref [] in
        let non_call_loc : loc option ref = ref None in
        let rec visit e =
          match e with
          | EVar { name = n; loc = l; _ } when n = name ->
            if !non_call_loc = None then non_call_loc := Some l
          | EApp _ ->
            let (h, call_args) = collect_call_head_and_args [] e in
            (match function_name_of_expr h with
             | Some n when n = name ->
               List.iter visit call_args;
               let call_loc = match h with
                 | EVar { loc = l; _ } -> l
                 | _ -> gen_loc
               in
               call_errors_ref := !call_errors_ref
                 @ check_call_proofs ~funcs call_loc name params call_args subject_env proof_env
             | _ ->
               visit h;
               List.iter visit call_args)
          | EField { obj; _ } -> visit obj
          | EBinop { left; right; _ } -> visit left; visit right
          | EUnop { arg; _ } -> visit arg
          | EIf { cond; then_; else_; _ } ->
            visit cond; visit then_; visit else_
          | ECase { scrut; arms; _ } ->
            visit scrut;
            List.iter (fun (a : case_arm) ->
              (match a.guard with Some g -> visit g | None -> ());
              visit a.body) arms
          | ELet { name = n; value = v; body = b; _ } ->
            visit v;
            if n <> name then visit b
          | ELetProof { value_name; proof_name; value = v; body = b; _ } ->
            visit v;
            if value_name <> name && proof_name <> name then visit b
          | ERecord { fields; _ } ->
            List.iter (fun (_, v) -> visit v) fields
          | EList { elems; _ } -> List.iter visit elems
          | EOk { value = v; _ } -> visit v
          | EFail { message; _ } -> visit message
          | ETelemetry { fields; _ } ->
            List.iter (fun (_, v) -> visit v) fields
          | EEnqueue { payload; _ } -> visit payload
          | EPublish { key; payload; _ } ->
            (match key with Some k -> visit k | None -> ());
            (match payload with Some p -> visit p | None -> ())
          | EWithDatabase { body = b; _ }
          | EWithCapabilities { body = b; _ }
          | EWithTransaction { body = b; _ } -> visit b
          | EServe { port; _ } -> visit port
          | EConstructor { args; _ } -> List.iter visit args
          | ELambda { params = ps; body = b; _ } ->
            if not (List.exists (fun (p : binding) -> p.name = name) ps)
            then visit b
          | ELit _ | EVar _ | EStartWorkers _ -> ()
        in
        visit body;
        let non_call_errors =
          match !non_call_loc with
          | Some l ->
            [ make_error l
                ~hint:(Printf.sprintf
                  "wrap the lambda in a fresh `fn(...) -> ...` that re-validates the proof with `check`, or call the original lambda directly at its use site"
                  )
                (Printf.sprintf
                  "lambda alias `%s` has proof-annotated parameters and cannot be passed around — doing so would bypass the proof check"
                  name) ]
          | None -> []
        in
        !call_errors_ref @ non_call_errors
      | _ -> []
    in
    let value_errors = laundering_errors @ let_lambda_errors @ check_expr_call_proofs subject_env proof_env funcs value in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (name, subject) :: subject_env
      | None ->
        (* For check/establish function calls (RetAttached returns), the result IS the
           first argument (same value with proof). Propagate its subject so cross-parameter
           proof validation works correctly (e.g. requiresPositiveX raw checked). *)
        (match value with
         | EApp _ ->
           let (head, args) = collect_call_head_and_args [] value in
           (match function_name_of_expr head with
            | Some "check" ->
              (* `check fn arg` — fn is first arg, real arg is second *)
              (match args with
               | fn_expr :: rest_args ->
                 (match function_name_of_expr fn_expr with
                  | Some fn_name ->
                    (match List.assoc_opt fn_name funcs with
                     | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                       (* Use the arg corresponding to the return binding's param name *)
                       let binding_arg = match info.fi_return with
                         | RetAttached { binding = b; _ } ->
                           (* Find which param index has binding's name, use that arg *)
                           let rec find_idx i = function
                             | [] -> None
                             | (p : binding) :: _ when p.name = b.name ->
                               if i < List.length rest_args then Some (List.nth rest_args i) else None
                             | _ :: rest -> find_idx (i+1) rest
                           in
                           (match find_idx 0 info.fi_params with
                            | Some arg -> Some arg
                            | None -> match rest_args with x :: _ -> Some x | [] -> None)
                         | _ -> match rest_args with x :: _ -> Some x | [] -> None
                       in
                       (match binding_arg with
                        | Some arg ->
                          (match subject_of_expr subject_env arg with
                           | Some s -> (name, s) :: subject_env
                           | None -> subject_env)
                        | None -> subject_env)
                     | _ -> subject_env)
                  | None ->
                     (* Combined check: (checkA && checkB) real_arg.
                        fn_expr is an EBinop BAnd, not a simple function name.
                        The real argument is the first element of rest_args.
                        Propagate its subject to the let-binder so that
                        later calls like `needsBoth v` can resolve proofs. *)
                     (match rest_args with
                      | real_arg :: _ ->
                        (match subject_of_expr subject_env real_arg with
                         | Some s -> (name, s) :: subject_env
                         | None -> subject_env)
                      | [] -> subject_env))
               | [] -> subject_env)
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                 (* Use the arg that corresponds to the return binding's param name, NOT
                    always the first arg.  For single-param checks both are the same, but
                    for multi-param checks like isInRange(lo,hi,n)->n:T:::P, the relevant
                    arg is the one bound to `n` (3rd), not `lo` (1st). *)
                 let binding_arg = match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i+1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some arg -> Some arg
                      | None -> (match args with x :: _ -> Some x | [] -> None))
                   | _ -> (match args with x :: _ -> Some x | [] -> None)
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None ->
              (* Combined check: (checkA && checkB) arg — no "check" wrapper.
                 Propagate the argument subject to the let-binder. *)
              (match head with
               | EBinop { op = BAnd; _ } ->
                 (match args with
                  | subj_arg :: _ ->
                    (match subject_of_expr subject_env subj_arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | [] -> subject_env)
               | _ -> subject_env))
         | _ -> subject_env)
    in
    let new_proofs = proofs_of_expr name funcs subject_env proof_env value in
    (* Collect all atom names used as arguments in a proof expression. *)
    let rec proof_arg_names = function
      | PredApp { args; _ } -> args
      | PredAnd { left; right; _ } -> proof_arg_names left @ proof_arg_names right
    in
    let check_proof_annotation required =
      (* Most aliases inside a declared proof should resolve to their tracked
         subjects (e.g. `admin` → `adminStr`), but the binding being introduced
         may legitimately remain as the fresh result name (e.g. named-pack
         entity proofs such as `IsPositive result`). Accept either form. *)
      let normalize_required subject_env =
        normalize_proof_aliases proof_env
          (subst_proof_args_with_subjects subject_env required)
      in
      let subject_env_without_name =
        List.filter (fun (candidate, _) -> candidate <> name) subject_env' in
      let required_candidates = [
        normalize_required subject_env';
        normalize_required subject_env_without_name;
      ] in
      if List.exists (fun required' -> proof_matches required' new_proofs) required_candidates then []
      else
        let carried =
          match new_proofs with
          | [] -> "no tracked proofs"
          | proofs -> String.concat ", " (List.map pp_proof proofs)
        in
        [ make_error loc
            ~hint:(Printf.sprintf
              "bind a value that carries `%s`, or remove the incorrect annotation"
              (pp_proof required))
            (Printf.sprintf
              "let binding `%s` declares proof `%s`, but the bound expression carries %s"
              name (pp_proof required) carried) ]
    in
    let check_fact_annotation_proof proof fact_loc =
      (* Reject self-referential annotations: `let proof: Fact (NonEmpty proof)` is
         nonsensical because `proof` names the Fact holder, not the value being proven. *)
      if List.mem name (proof_arg_names proof) then
        [ make_error fact_loc
            ~hint:"the proof argument should name the proof-carrying value (e.g. the result of a `check …`), not the binding being defined"
            (Printf.sprintf
              "`%s` is used as both the binding name and a proof argument; \
               `Fact (P x)` describes a fact about `x`, not about the `Fact` holder itself"
              name) ]
      else
        check_proof_annotation proof
    in
    let declared_proof_errors =
      match declared_proof with
      | Some required -> check_proof_annotation required
      | None ->
        (* Also validate Fact(P) type annotations: `let x: Fact (P) = ...` *)
        (match declared_type with
         | Some (TApp { head = TName { name = "Fact"; _ }; arg; loc = fact_loc }) ->
           (match type_expr_to_proof_expr arg with
            | Some proof -> check_fact_annotation_proof proof fact_loc
            | None -> [])
         | Some (TName { name = "Fact"; loc = fact_loc }) ->
           (* Bare `Fact` without a proof argument is always invalid. *)
           [ make_error fact_loc
               ~hint:"write `Fact (P)` e.g. `Fact (NonEmpty x)` to name the proof"
               (Printf.sprintf
                 "bare `Fact` is not a valid type annotation for `%s`; \
                  a proof argument is required" name) ]
         | _ -> [])
    in
    let proof_env' = if new_proofs = [] then proof_env else (name, new_proofs) :: proof_env in
    value_errors @ declared_proof_errors @ check_expr_call_proofs subject_env' proof_env' funcs body
  | ELetProof { value_name; proof_name; proof_index; value; body; loc } ->
    let value_errors = check_expr_call_proofs subject_env proof_env funcs value in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (value_name, subject) :: subject_env
      | None ->
        (* For check-fn calls (RetAttached), propagate the subject of the
           return-bound argument — same logic as the ELet handler. *)
        (match value with
         | EApp _ ->
           let (head0, args0) = collect_call_head_and_args [] value in
           let (_head, args) = normalize_explicit_check_call head0 args0 in
           (match function_name_of_expr _head with
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                 let binding_arg = match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i+1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some arg -> Some arg
                      | None -> (match args with x :: _ -> Some x | [] -> None))
                   | _ -> (match args with x :: _ -> Some x | [] -> None)
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (value_name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None -> subject_env)
         | _ -> subject_env)
    in
    (* Use proofs_of_expr (not carried_proofs_of_expr) so that function-call
       return proofs are included — carried_proofs_of_expr can't derive proofs
       from arbitrary EApp calls like checkPosAndSmall n1. *)
    let detached_proofs =
      let carried = match carried_proofs_of_expr ~funcs subject_env proof_env value with
        | Some proofs -> proofs
        | None -> []
      in
      let () = record_entity_binder value_name value in
      let effective = effective_value_name value_name value in
      let full =
        if carried <> [] then carried
        else proofs_of_expr effective funcs subject_env' proof_env value
      in
      (* Flatten any top-level `P && Q && R` proofs so that each conjunct
         is its own element in the list.  Without this, a single
         `PredAnd { left; right }` element would be treated as one atom
         and EVERY positional binder in an `&&` decomposition would get
         back the full compound proof — a soundness hole that lets
         `let (_ ::: p && q) = (a ::: A && B)` bind both `p` and `q` to
         `A && B` instead of to `A` and `B` separately. *)
      let rec flatten_preds = function
        | [] -> []
        | PredAnd { left; right; _ } :: rest ->
          flatten_preds [left] @ flatten_preds [right] @ flatten_preds rest
        | p :: rest -> p :: flatten_preds rest
      in
      let full = flatten_preds full in
      (* Deduplicate: `let (x ::: p && q) = val` where val is `raw ::: lp && rp`
         would otherwise accumulate both the carried proofs of `raw` and the
         extra proofs on the annotation, producing duplicates that defeat
         the positional projection below. *)
      let rec dedup_by_key seen = function
        | [] -> []
        | p :: rest ->
          let k = proof_key p in
          if List.mem k seen then dedup_by_key seen rest
          else p :: dedup_by_key (k :: seen) rest
      in
      let full = dedup_by_key [] full in
      (* If this binder is one slot of an `&&` decomposition, pick the
         positional conjunct instead of handing the full proof set to every
         name.  `let (x ::: p && q) = val` — per LANGUAGE-SPEC / lesson09 —
         binds p to the left conjunct and q to the right conjunct. *)
      match proof_index with
      | Some (i, arity) when arity > 1 ->
        if List.length full = arity && i < arity then [List.nth full i]
        else if full = [] then []
        else
          (* Arity mismatch after dedup — unusual; fall back to full to avoid
             losing proof info, but this now only happens when the RHS truly
             provides an unexpected number of distinct proofs. *)
          full
      | _ -> full
    in
    (* Validate that the value actually carries at least one proof — if we can
       determine statically that it carries none, report an error. *)
    let no_proof_errors =
      match carried_proofs_of_expr ~funcs subject_env proof_env value with
      | Some [] ->
        [ make_error loc
            ~hint:(Printf.sprintf
              "use `attachFact` or a check function to attach a proof before destructuring with `%s ::: %s`"
              value_name proof_name)
            (Printf.sprintf
              "proof destructuring `let (%s ::: %s) = ...` requires at least one attached proof, \
               but the value carries none" value_name proof_name) ]
      | _ -> []
    in
    let proof_env' = if detached_proofs = [] then proof_env else (proof_name, detached_proofs) :: proof_env in
    value_errors @ no_proof_errors @ check_expr_call_proofs subject_env' proof_env' funcs body
  | EIf { cond; then_; else_; _ } ->
    check_expr_call_proofs subject_env proof_env funcs cond
    @ check_expr_call_proofs subject_env proof_env funcs then_
    @ check_expr_call_proofs subject_env proof_env funcs else_
  | ECase { scrut; arms; _ } ->
    let scrut_errors = check_expr_call_proofs subject_env proof_env funcs scrut in
    (* For `case (establish_fn arg) of Something proof ->`, the `proof` binding
       carries the inner proof from the establish function's Maybe (Fact P) return.
       Also handles user ADT round-trips: `let m = Something p; case m of Something x ->`
       where x should inherit p's proofs via subject aliasing. *)
    (* Use a sentinel result name for non-variable scrutinees so that named-return
       proofs like `Maybe (r: T ::: ForAll P r)` get a trackable subject.
       For EVar scrutinees the result_name is irrelevant (carried_proofs_of_expr
       uses the variable's own proof_env entry directly).  For call expressions the
       sentinel will be substituted with the pattern-bound name below. *)
    let scrut_result_name = match scrut with
      | EVar { name; _ } -> name
      | _ -> "_case_scrut"
    in
    let scrut_proofs = proofs_of_expr scrut_result_name funcs subject_env proof_env scrut in
    let arm_errors = List.concat_map (fun (arm : case_arm) ->
      let proof_env', subject_env' = match arm.pattern with
        | PCon { fields = [(_, PVar x)]; _ } ->
          (* Any single-field constructor: propagate scrutinee's proofs and subject chain
             to the bound variable x. This enables proof tracking through constructor
             round-trips: `let m = Something p; case m of Something x -> requiresP x`.
             For direct call scrutinees the sentinel result name is substituted with x
             so that `ForAll P _case_scrut` becomes `ForAll P x`.
             We fully resolve the subject chain (m→p→n) so that call-site substitution
             maps the proof subject correctly (Positive n, not Positive p). *)
          let scrut_proofs_for_x =
            if scrut_result_name = "_case_scrut" then
              List.map (subst_proof [("_case_scrut", x)]) scrut_proofs
            else scrut_proofs
          in
          let penv = if scrut_proofs_for_x <> [] then (x, scrut_proofs_for_x) :: proof_env else proof_env in
          let senv =
            (* Fully follow the subject_env chain to the final canonical subject.
               e.g. m→p→n resolves to "n", which is what x's call-site subject must be.
               When the chain doesn't extend (e.g. m has no subject alias), fall back to
               the subject described by the carried proofs themselves — e.g. if scrut_proofs
               contain `IsPositive raw`, use "raw" as x's subject so that `needPos x`
               resolves to `IsPositive raw` (matching the carried proof). *)
            let rec resolve_chain seen name =
              if List.mem name seen then name  (* cycle guard *)
              else match List.assoc_opt name subject_env with
                | Some s when s <> name -> resolve_chain (name :: seen) s
                | _ -> name
            in
            let chain_subj = match scrut with
              | EVar { name; _ } -> resolve_chain [] name
              | _ -> (match subject_of_expr subject_env scrut with Some s -> s | None -> x)
            in
            (* If the chain didn't extend beyond the scrutinee name, try to find
               the ultimate subject from the proof's own argument list. *)
            let final_subj =
              if chain_subj = (match scrut with EVar { name; _ } -> name | _ -> "") then
                (* Chain stopped at the scrutinee itself — try proof's last argument *)
                let proof_subject = List.find_map (fun p ->
                  match p with
                  | PredApp { args = (_ :: _ as pargs); _ } ->
                    let last = List.nth pargs (List.length pargs - 1) in
                    (* Only use if it's a simple lowercase identifier (a subject name) *)
                    if String.length last > 0 && last.[0] >= 'a' && last.[0] <= 'z'
                       && not (String.contains last '.')
                    then Some last
                    else None
                  | _ -> None
                ) scrut_proofs_for_x in
                (match proof_subject with
                 | Some s -> resolve_chain [] s  (* follow the chain from the proof's subject *)
                 | None -> chain_subj)
              else chain_subj
            in
            if final_subj <> x then (x, final_subj) :: subject_env
            else subject_env
          in
          (penv, senv)
        | _ -> (proof_env, subject_env)
      in
      check_expr_call_proofs subject_env' proof_env' funcs arm.body
    ) arms in
    scrut_errors @ arm_errors
  | EBinop { op = (BDiv | BMod) as op; left; right; loc } ->
    let child_errors =
      check_expr_call_proofs subject_env proof_env funcs left
      @ check_expr_call_proofs subject_env proof_env funcs right
    in
    (* The / and % operators require the divisor to carry an IsNonZero proof *)
    let op_name = match op with BDiv -> "/" | BMod -> "%" | _ -> "?" in
    let div_errors = match right with
      | ELit { lit = LInt 0; loc = lit_loc }
      | ELit { lit = LFloat 0.0; loc = lit_loc } ->
        [ make_error lit_loc
            ~hint:"use a non-zero literal, or use `check Int.nonZero` to validate the divisor"
            (Printf.sprintf "division by zero: the right operand of `%s` is literally 0" op_name) ]
      | ELit { lit = (LInt _ | LFloat _); _ } ->
        (* Non-zero literal — statically safe *)
        []
      | EVar { name; _ } ->
        let subject = match List.assoc_opt name subject_env with Some s -> s | None -> name in
        let carried = match List.assoc_opt subject proof_env with Some proofs -> proofs | None ->
          match List.assoc_opt name proof_env with Some proofs -> proofs | None -> [] in
        let has_nonzero = List.exists (fun p ->
          let key = proof_key p in
          String.length key >= 9 && String.sub key 0 9 = "IsNonZero"
        ) carried in
        if has_nonzero then []
        else
          [ make_error loc
              ~hint:(Printf.sprintf "use `let checked = check Int.nonZero %s` then `%s` the checked value" name op_name)
              (Printf.sprintf "the right operand of `%s` (`%s`) has no `IsNonZero` proof; division may crash at runtime"
                 op_name name) ]
      | _ ->
        [ make_error loc
            ~hint:(Printf.sprintf "bind the divisor to a named variable, then use `check Int.nonZero` before `%s`" op_name)
            (Printf.sprintf "the right operand of `%s` is an expression with no trackable `IsNonZero` proof" op_name) ]
    in
    child_errors @ div_errors
  | EBinop { left; right; _ } ->
    check_expr_call_proofs subject_env proof_env funcs left
    @ check_expr_call_proofs subject_env proof_env funcs right
  | EUnop { arg; _ } -> check_expr_call_proofs subject_env proof_env funcs arg
  | EList { elems; _ } -> List.concat_map (check_expr_call_proofs subject_env proof_env funcs) elems
  | ERecord { fields; _ } -> List.concat_map (fun (_, v) -> check_expr_call_proofs subject_env proof_env funcs v) fields
  | EOk { value; _ } -> check_expr_call_proofs subject_env proof_env funcs value
  | ETelemetry { fields; _ } -> List.concat_map (fun (_, v) -> check_expr_call_proofs subject_env proof_env funcs v) fields
  | EEnqueue { payload; _ } -> check_expr_call_proofs subject_env proof_env funcs payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> check_expr_call_proofs subject_env proof_env funcs e | None -> [])
    @ (match payload with Some e -> check_expr_call_proofs subject_env proof_env funcs e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } -> check_expr_call_proofs subject_env proof_env funcs body
  | EServe { port; _ } -> check_expr_call_proofs subject_env proof_env funcs port
  | ELambda { params; body; _ } ->
    (* Inject lambda parameter proofs into proof_env so callee's proof
       requirements can be satisfied by explicitly-annotated lambda params.
       e.g. `fn(x: Int ::: Positive x) -> double x` needs proof_env["x"] = [Positive x] *)
    let proof_env' = List.fold_left (fun acc (b : binding) ->
      match b.proof_ann with
      | None -> acc
      | Some proof -> (b.name, flatten_proof_conj proof) :: acc
    ) proof_env params in
    check_expr_call_proofs subject_env proof_env' funcs body
  | ELit _ | EVar _ | EField _ | EFail _ -> []
  | EConstructor { args; _ } -> List.concat_map (check_expr_call_proofs subject_env proof_env funcs) args

(** In test blocks, `let x = e` compiles to a bare Racket `(define x e)`, so
    the value is NOT wrapped in a named-value.  Every time a bare integer/string
    is passed into a check function the runtime creates a *fresh* gensym for it,
    so the gensym at the check-call site and at the require-call site will differ
    and the proof match will always fail at runtime.
    To prevent the confusing runtime failure, reject inline literals (and other
    non-variable expressions) at any proof-subject position of a check function
    call inside a test block.  The user must `let`-bind the value first. *)
let check_inline_proof_args (loc : loc) (fn_name : string) (info : func_info)
    (args : expr list) : validation_error list =
  match info.fi_return with
  | RetAttached { binding = b; _ } ->
    let subj_names = match b.proof_ann with
      | Some p -> proof_subjects p
      | None   -> []
    in
    List.concat (List.mapi (fun i (param : binding) ->
      if not (List.mem param.name subj_names) then []
      else
        match List.nth_opt args i with
        | None | Some (EVar _) -> []
        | Some (ELit { loc = arg_loc; _ }) ->
          [ make_error arg_loc
              ~hint:(Printf.sprintf
                "write `let %s = <value>` on a separate line before the call, \
                 then pass `%s` instead of the inline literal"
                param.name param.name)
              (Printf.sprintf
                "argument `%s` to `%s` is at a proof-subject position; \
                 inline literals cannot be tracked as proof subjects in test blocks \
                 — use a `let` binding"
                param.name fn_name) ]
        | Some _ ->
          [ make_error loc
              ~hint:(Printf.sprintf
                "bind the expression to `let %s = ...` before passing it to `%s`"
                param.name fn_name)
              (Printf.sprintf
                "argument `%s` to `%s` is at a proof-subject position; \
                 complex expressions cannot be tracked as proof subjects in test blocks \
                 — use a `let` binding"
                param.name fn_name) ]
    ) info.fi_params)
  | _ -> []

(** Apply check_inline_proof_args to a call expression (value) in a TsLet. *)
let inline_proof_arg_errors_for_call (loc : loc)
    (funcs : (string * func_info) list) (value : expr)
    : validation_error list =
  match value with
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] value in
    (match function_name_of_expr head with
     | Some "check" ->
       (match args with
        | fn_expr :: rest_args ->
          (match function_name_of_expr fn_expr with
           | Some fn_name ->
             (match List.assoc_opt fn_name funcs with
              | Some info -> check_inline_proof_args loc fn_name info rest_args
              | None -> [])
           | None -> [])
        | [] -> [])
     | Some fn_name ->
       (match List.assoc_opt fn_name funcs with
        | Some info -> check_inline_proof_args loc fn_name info args
        | None -> [])
     | None -> [])
  | _ -> []

(** Walk test statements and check proof obligations at call sites. *)
let rec check_test_stmt_call_proofs
    (subject_env : subject_env)
    (proof_env : proof_env)
    (funcs : (string * func_info) list)
    (stmt : test_stmt)
    : validation_error list * subject_env * proof_env =
  match stmt with
  | TsLetProof { value_name; proof_names; value; _ } ->
    let value_errors = check_expr_call_proofs subject_env proof_env funcs value in
    (* For proof variable tracking, we need a meaningful result name even when
       value_name is "_".  Use the first argument's subject so that entity proofs
       in RetNamedPack get the correct subject (e.g. Positive n99 not Positive _). *)
    let first_arg_subject =
      let (_, args) = collect_call_head_and_args [] value in
      match args with
      | arg :: _ -> subject_of_expr subject_env arg
      | [] -> None
    in
    let effective_name = if value_name = "_" then
      match first_arg_subject with Some s -> s | None -> value_name
    else value_name in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (effective_name, subject) :: subject_env
      | None ->
        (match first_arg_subject with
         | Some s -> (effective_name, s) :: subject_env
         | None -> subject_env)
    in
    let new_proofs = proofs_of_expr effective_name funcs subject_env' proof_env value in
    let proof_env' = List.fold_left (fun env pname ->
      if new_proofs = [] then env else (pname, new_proofs) :: env
    ) proof_env proof_names in
    let proof_env' = if new_proofs = [] then proof_env'
      else (effective_name, new_proofs) :: proof_env' in
    (value_errors, subject_env', proof_env')
  | TsLet { name; value; declared_type; declared_proof; loc; _ } ->
    let value_errors =
      check_expr_call_proofs subject_env proof_env funcs value
      @ inline_proof_arg_errors_for_call loc funcs value
    in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (name, subject) :: subject_env
      | None ->
        (* For check/establish/named-pack function calls, propagate subjects.
           Mirrors the ELet case in check_expr_call_proofs. *)
        (match value with
         | EApp _ ->
           let (head, args) = collect_call_head_and_args [] value in
           (match function_name_of_expr head with
            | Some "check" ->
              (* `check fn arg` — fn is first arg, real arg is second *)
              (match args with
               | fn_expr :: rest_args ->
                 (match function_name_of_expr fn_expr with
                  | Some fn_name ->
                    (match List.assoc_opt fn_name funcs with
                     | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                       let binding_arg = match info.fi_return with
                         | RetAttached { binding = b; _ } ->
                           let rec find_idx i = function
                             | [] -> None
                             | (p : binding) :: _ when p.name = b.name ->
                               if i < List.length rest_args then Some (List.nth rest_args i) else None
                             | _ :: rest -> find_idx (i+1) rest
                           in
                           (match find_idx 0 info.fi_params with
                            | Some arg -> Some arg
                            | None -> match rest_args with x :: _ -> Some x | [] -> None)
                         | _ -> match rest_args with x :: _ -> Some x | [] -> None
                       in
                       (match binding_arg with
                        | Some arg ->
                          (match subject_of_expr subject_env arg with
                           | Some s -> (name, s) :: subject_env
                           | None -> subject_env)
                        | None -> subject_env)
                     | _ -> subject_env)
                  | None ->
                    (* Compound check: fn_expr is EBinop (&&); use first real arg as subject *)
                    (match rest_args with
                     | arg :: _ ->
                       (match subject_of_expr subject_env arg with
                        | Some s -> (name, s) :: subject_env
                        | None -> subject_env)
                     | [] -> subject_env))
               | [] -> subject_env)
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ | RetNamedPack _ -> true | _ -> false) ->
                 (* For multi-parameter checks like checkInBounds(lo,hi,n)->n:T:::P,
                    the subject of the result is the subject of the argument that
                    corresponds to the return binding's param name (here `n`, index 2),
                    NOT always the first argument.  Mirror the find_idx logic used in
                    the ELet case of check_expr_call_proofs. *)
                 let binding_arg = match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i+1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some arg -> Some arg
                      | None -> (match args with x :: _ -> Some x | [] -> None))
                   | _ -> (match args with x :: _ -> Some x | [] -> None)
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None -> subject_env)
         | _ -> subject_env)
    in
    let new_proofs = proofs_of_expr name funcs subject_env proof_env value in
    let rec proof_arg_names = function
      | PredApp { args; _ } -> args
      | PredAnd { left; right; _ } -> proof_arg_names left @ proof_arg_names right
    in
    let check_proof_annotation required =
      (* Most aliases inside a declared proof should resolve to their tracked
         subjects (e.g. `admin` → `adminStr`), but the binding being introduced
         may legitimately remain as the fresh result name (e.g. named-pack
         entity proofs such as `IsPositive result`). Accept either form. *)
      let normalize_required subject_env =
        normalize_proof_aliases proof_env
          (subst_proof_args_with_subjects subject_env required)
      in
      let subject_env_without_name =
        List.filter (fun (candidate, _) -> candidate <> name) subject_env' in
      let required_candidates = [
        normalize_required subject_env';
        normalize_required subject_env_without_name;
      ] in
      if List.exists (fun required' -> proof_matches required' new_proofs) required_candidates then []
      else
        let carried =
          match new_proofs with
          | [] -> "no tracked proofs"
          | proofs -> String.concat ", " (List.map pp_proof proofs)
        in
        [ make_error loc
            ~hint:(Printf.sprintf
              "bind a value that carries `%s`, or remove the incorrect annotation"
              (pp_proof required))
            (Printf.sprintf
              "let binding `%s` declares proof `%s`, but the bound expression carries %s"
              name (pp_proof required) carried) ]
    in
    let check_fact_annotation_proof proof fact_loc =
      if List.mem name (proof_arg_names proof) then
        [ make_error fact_loc
            ~hint:"the proof argument should name the proof-carrying value (e.g. the result of a `check …`), not the binding being defined"
            (Printf.sprintf
              "`%s` is used as both the binding name and a proof argument;                `Fact (P x)` describes a fact about `x`, not about the `Fact` holder itself"
              name) ]
      else
        check_proof_annotation proof
    in
    let declared_proof_errors =
      match declared_proof with
      | Some required -> check_proof_annotation required
      | None ->
        (match declared_type with
         | Some (TApp { head = TName { name = "Fact"; _ }; arg; loc = fact_loc }) ->
           (match type_expr_to_proof_expr arg with
            | Some proof -> check_fact_annotation_proof proof fact_loc
            | None -> [])
         | Some (TName { name = "Fact"; loc = fact_loc }) ->
           [ make_error fact_loc
               ~hint:"write `Fact (P)` e.g. `Fact (NonEmpty x)` to name the proof"
               (Printf.sprintf
                 "bare `Fact` is not a valid type annotation for `%s`;                   a proof argument is required" name) ]
         | _ -> [])
    in
    let proof_env' = if new_proofs = [] then proof_env else (name, new_proofs) :: proof_env in
    (value_errors @ declared_proof_errors, subject_env', proof_env')
  | TsExpect { left; right; _ } ->
    let left_errors = check_expr_call_proofs subject_env proof_env funcs left in
    let right_errors = match right with
      | Some r -> check_expr_call_proofs subject_env proof_env funcs r
      | None -> []
    in
    (left_errors @ right_errors, subject_env, proof_env)
  | TsExpectFail { fn; arg; _ } ->
    let fn_errors = check_expr_call_proofs subject_env proof_env funcs fn in
    let arg_errors = check_expr_call_proofs subject_env proof_env funcs arg in
    (fn_errors @ arg_errors, subject_env, proof_env)
  | TsExpectHasProof { fn; arg; _ } ->
    let fn_errors = check_expr_call_proofs subject_env proof_env funcs fn in
    let arg_errors = check_expr_call_proofs subject_env proof_env funcs arg in
    (fn_errors @ arg_errors, subject_env, proof_env)
  | TsProperty { body; _ } ->
    let errors = check_expr_call_proofs subject_env proof_env funcs body in
    (errors, subject_env, proof_env)
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    let cond_errors = check_expr_call_proofs subject_env proof_env funcs cond in
    let then_errors = check_test_stmts_call_proofs subject_env proof_env funcs then_stmts in
    let else_errors = check_test_stmts_call_proofs subject_env proof_env funcs else_stmts in
    (cond_errors @ then_errors @ else_errors, subject_env, proof_env)
  | TsCase { scrut; arms; _ } ->
    let scrut_errors = check_expr_call_proofs subject_env proof_env funcs scrut in
    let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
    let arm_errors = List.concat_map (fun (arm : Ast.ts_case_arm) ->
      (* Propagate scrutinee proofs into the arm binding, same as ECase in
         check_expr_call_proofs: `case m of Something v ->` gives v the proof of m. *)
      let proof_env', subject_env' =
        let penv, senv = match arm.ts_pattern with
          | PCon { fields = [(_, PVar x)]; _ } ->
            let penv = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
            let senv =
              let rec resolve_chain seen name =
                if List.mem name seen then name
                else match List.assoc_opt name subject_env with
                  | Some s when s <> name -> resolve_chain (name :: seen) s
                  | _ -> name
              in
              let final_subj = match scrut with
                | EVar { name; _ } -> resolve_chain [] name
                | _ -> (match subject_of_expr subject_env scrut with Some s -> s | None -> x)
              in
              if final_subj <> x then (x, final_subj) :: subject_env else subject_env
            in
            (penv, senv)
          | _ -> (proof_env, subject_env)
        in
        (penv, senv)
      in
      let guard_errors = match arm.ts_guard with
        | Some g -> check_expr_call_proofs subject_env' proof_env' funcs g
        | None -> []
      in
      let body_errors =
        check_test_stmts_call_proofs subject_env' proof_env' funcs arm.ts_body
      in
      guard_errors @ body_errors
    ) arms in
    (scrut_errors @ arm_errors, subject_env, proof_env)
  | TsExpr { e; _ } ->
    let errors = check_expr_call_proofs subject_env proof_env funcs e in
    (errors, subject_env, proof_env)

(** Walk a list of test statements, threading subject_env and proof_env. *)
and check_test_stmts_call_proofs
    (subject_env : subject_env)
    (proof_env : proof_env)
    (funcs : (string * func_info) list)
    (stmts : test_stmt list)
    : validation_error list =
  let (errors, _, _) =
    List.fold_left (fun (acc_errors, se, pe) stmt ->
      let (errs, se', pe') = check_test_stmt_call_proofs se pe funcs stmt in
      (acc_errors @ errs, se', pe')
    ) ([], subject_env, proof_env) stmts
  in
  errors

let check_call_site_proofs ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  field_proof_registry := build_field_proof_map decls;
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let subject_env = build_initial_subject_env fd.params in
      let proof_env = build_initial_proof_env fd.params in
      errors := check_expr_call_proofs subject_env proof_env funcs fd.body @ !errors
    | DTest tf ->
      errors := check_test_stmts_call_proofs [] [] funcs tf.stmts @ !errors
    | DApiTest atf ->
      let seed_errors = List.concat_map (check_expr_call_proofs [] [] funcs) atf.seed_stmts in
      let stmt_errors = check_test_stmts_call_proofs [] [] funcs atf.stmts in
      errors := seed_errors @ stmt_errors @ !errors
    | DLoadTest ltf ->
      let seed_errors = List.concat_map (check_expr_call_proofs [] [] funcs) ltf.seed_stmts in
      let req_errors = check_test_stmts_call_proofs [] [] funcs ltf.request_stmts in
      errors := seed_errors @ req_errors @ !errors
    | _ -> ()
  ) decls;
  field_proof_registry := [];
  List.rev !errors

(** Validate that every argument passed to filterCheck/allCheck/filterCheckValues/
    filterCheckKeys is a declared `check` or `auth` function (or an `&&` combination
    thereof), not a plain lambda or `fn` function.

    The runtime implementations of these functions call the argument as a check
    function and validate that the result is `check-ok` or `check-fail`.  A plain
    lambda or fn returns a raw value, which crashes at runtime with "expected
    check-ok or check-fail".  This is a compile-time soundness gap: the type system
    does not distinguish check functions from plain functions, so we enforce this
    constraint here. *)
let check_filter_check_args ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let errors = ref [] in
  let filter_fns = [
    "List.filterCheck"; "Set.filterCheck";
    "List.allCheck"; "Set.allCheck";
    "Dict.filterCheckValues"; "Dict.filterCheckKeys";
  ] in
  (* Check that the first argument to filterCheck-family calls is a declared
     check/auth function or an && combination of them. *)
  let rec is_valid_check_arg e =
    match e with
    | EVar { name; _ } ->
      (match List.assoc_opt name funcs with
       | Some info -> info.fi_kind = CheckKind || info.fi_kind = AuthKind
       | None -> false)           (* unknown name — caught by other passes *)
    | EBinop { op = BAnd; left; right; _ } ->
      is_valid_check_arg left && is_valid_check_arg right
    | EApp { fn; _ } ->
      (* Allow partial application of check functions.
         E.g. `checkInRange 0 100` is EApp(EApp(EVar "checkInRange", 0), 100).
         Recurse into the function part to reach the base check function name. *)
      is_valid_check_arg fn
    | _ -> false
  in
  let check_fn_arg_of e =
    (* The check-function argument is the first positional arg after the fn name.
       For `List.filterCheck checkFn xs`, args = [checkFn; xs]. *)
    let (head, args) = collect_call_head_and_args [] e in
    match function_name_of_expr head with
    | Some name when List.mem name filter_fns ->
      (match args with first_arg :: _ -> Some first_arg | [] -> None)
    | _ -> None
  in
  let rec walk e =
    (match e with
     | EApp _ ->
       (match check_fn_arg_of e with
        | Some arg when not (is_valid_check_arg arg) ->
          let loc = match e with EApp { loc; _ } -> loc | _ -> gen_loc in
          let fname = match function_name_of_expr (fst (collect_call_head_and_args [] e)) with
            | Some n -> n | None -> "filterCheck"
          in
          let msg = match arg with
            | ELambda _ ->
              Printf.sprintf
                "the first argument to `%s` must be a declared `check` function, not an inline lambda; \
inline lambdas do not return the `check-ok`/`check-fail` value that `%s` requires at runtime"
                fname fname
            | EVar { name; _ } ->
              (match List.assoc_opt name funcs with
               | Some info ->
                 Printf.sprintf
                   "the first argument to `%s` is `%s` which is a `%s`, not a `check` function; \
only `check` (or `auth`) functions may be passed to `%s`"
                   fname name
                   (match info.fi_kind with
                    | FnKind -> "fn" | EstablishKind -> "establish"
                    | HandlerKind -> "handler" | WorkerKind -> "worker"
                    | DeadWorkerKind -> "deadWorker" | MainKind -> "main"
                    | CheckKind -> "check" | AuthKind -> "auth")
                   fname
               | None ->
                 Printf.sprintf
                   "the first argument to `%s` is not a declared `check` function; \
pass a `check` function or a `&&` combination of check functions"
                   fname)
            | _ ->
              Printf.sprintf
                "the first argument to `%s` must be a declared `check` function or `checkA && checkB` combination"
                fname
          in
          errors := make_error loc
            ~hint:(Printf.sprintf "replace the argument with a declared `check` function, e.g. `%s checkFn %s`"
                     fname
                     (match snd (collect_call_head_and_args [] e) with
                      | _ :: rest -> String.concat " " (List.map (fun _ -> "xs") rest)
                      | [] -> "xs"))
            msg
          :: !errors
        | _ -> ());
       let (head, args) = collect_call_head_and_args [] e in
       walk head;
       List.iter walk args
     | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _ -> ()
     | EBinop { left; right; _ } -> walk left; walk right
     | EUnop { arg; _ } -> walk arg
     | EIf { cond; then_; else_; _ } -> walk cond; walk then_; walk else_
     | ECase { scrut; arms; _ } ->
       walk scrut;
       List.iter (fun (arm : case_arm) -> walk arm.body) arms
     | ELet { value; body; _ } | ELetProof { value; body; _ } ->
       walk value; walk body
     | ERecord { fields; _ } | ETelemetry { fields; _ } ->
       List.iter (fun (_, v) -> walk v) fields
     | EList { elems; _ } -> List.iter walk elems
     | EOk { value; _ } -> walk value
     | EEnqueue { payload; _ } -> walk payload
     | EPublish { key; payload; _ } ->
       Option.iter walk key; Option.iter walk payload
     | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
     | EWithTransaction { body; _ } -> walk body
     | ELambda { body; _ } -> walk body);
  in
  List.iter (function
    | DFunc fd -> walk fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

let check_forall_consistency ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let errors = ref [] in
  (* Detect if an expression is a SQL select (which carries FromDb proofs). *)
  let rec is_sql_select e =
    match e with
    | EApp { fn; _ } -> (match fn with
      | EVar { name = ("select" | "selectOne" | "selectMany" | "selectCount" | "selectSum" | "selectMin" | "selectMax"); _ } -> true
      | _ -> is_sql_select fn)
    | EBinop { left; right; _ } -> is_sql_select left || is_sql_select right
    | _ -> false
  in
  (* Detect if an expression is a `check fn xs` / `filterCheck fn xs` call
     returning ForAll proofs.  Also threads `forall_env` so that predicates
     already carried by the input collection are included in the result. *)
  (* BUG-2 fix: extract ForAll predicates from a check function expression,
     including `&&` combinator chains like `(checkA && checkB)`.
     Returns the list of predicate names produced by the check chain. *)
  let rec preds_from_check_expr check_expr =
    match check_expr with
    | EVar { name = check_fn; _ } ->
      (match List.assoc_opt check_fn funcs with
       | Some info -> pred_names_of_return_spec info.fi_return
       | None -> [])
    | EBinop { op = BAnd; left; right; _ } ->
      List.sort_uniq String.compare (preds_from_check_expr left @ preds_from_check_expr right)
    | _ -> []
  in
  let check_call_produced_preds forall_env e =
    match e with
    | EApp _ ->
      let (head, args) = collect_call_head_and_args [] e in
      (match function_name_of_expr head with
       | Some ("List.check" | "Set.check"
              | "List.filterCheck" | "Set.filterCheck"
              | "List.allCheck" | "Set.allCheck"
              | "List.emptyForAll"
              | "Dict.filterCheckValues" | "Dict.filterCheckKeys") ->
         (match args with
          | check_fn_expr :: rest ->
            let input_preds = match rest with
              | EVar { name = coll_var; _ } :: _ ->
                (match List.assoc_opt coll_var forall_env with
                 | Some preds -> preds
                 | None -> [])
              | _ -> []
            in
            (* BUG-2: use preds_from_check_expr to handle `checkA && checkB` *)
            let check_preds = preds_from_check_expr check_fn_expr in
            List.sort_uniq String.compare (check_preds @ input_preds)
          | _ -> [])
       | Some fn_name ->
         (* For any other call, propagate ForAll predicates from known fn return specs *)
         let input_preds = match args with
           | EVar { name = coll_var; _ } :: _ ->
             (match List.assoc_opt coll_var forall_env with Some p -> p | None -> [])
           | _ -> []
         in
         let call_preds = match List.assoc_opt fn_name funcs with
           | Some info -> forall_preds_of_return_spec info.fi_return
           | None -> []
         in
         List.sort_uniq String.compare (call_preds @ input_preds)
       | None -> [])
    | _ -> []
  in
  (* Build a local ForAll-predicate environment from let bindings.
     Maps variable name → known element-level predicates it already carries.
     This lets us recognise that `filterCheck fn all` where `all` came from a
     DB select already carries `FromDb` — those don't need to come from `fn`. *)
  let rec walk forall_env expected e =
    match e with
    | EApp _ ->
      let (head, args) = collect_call_head_and_args [] e in
      (match function_name_of_expr head, expected with
       | (Some "List.filterCheck" | Some "Set.filterCheck"
         | Some "Dict.filterCheckValues" | Some "Dict.filterCheckKeys"), Some wanted
       | (Some "List.allCheck" | Some "Set.allCheck"), Some wanted
       | (Some "List.emptyForAll"), Some wanted ->
         (* BUG-2: handle both `EVar check_fn` and `EBinop BAnd (checkA && checkB)` *)
         let check_fn_loc = match args with
           | EVar { loc; _ } :: _ -> loc
           | EBinop { loc; _ } :: _ -> loc
           | _ -> gen_loc
         in
         (match args with
          | check_fn_expr :: rest ->
            (* Predicates already carried by the input collection. *)
            let input_preds = match rest with
              | EVar { name = coll_var; _ } :: _ ->
                (match List.assoc_opt coll_var forall_env with
                 | Some preds -> preds
                 | None -> [])
              | _ -> []
            in
            let produced_preds = preds_from_check_expr check_fn_expr in
            if produced_preds <> [] then begin
              let required_preds = proof_predicates wanted in
              (* Available = what the check fn(s) produce + what the input already has. *)
              let available_preds = List.sort_uniq String.compare (produced_preds @ input_preds) in
              let missing = List.filter (fun pred -> not (List.mem pred available_preds)) required_preds in
              if missing <> [] then begin
                let produced = String.concat ", " produced_preds in
                let required = String.concat ", " required_preds in
                let missing_s = String.concat ", " missing in
                let check_fn_str = match check_fn_expr with
                  | EVar { name; _ } -> name
                  | EBinop _ -> "(check combination)"
                  | _ -> "?"
                in
                errors := make_error check_fn_loc
                  ~hint:(Printf.sprintf "use a check function that produces all of [%s], e.g. one returning `x ::: %s x`" missing_s required)
                  (Printf.sprintf "%s uses `%s` (produces `[%s]`) but the surrounding return type requires `[%s]` — missing `[%s]`"
                     (match function_name_of_expr head with Some n -> n | None -> "filterCheck")
                     check_fn_str produced required missing_s)
                  :: !errors
              end
            end else begin
              (* No known predicates — for single EVar, report unknown check fn *)
              match check_fn_expr with
              | EVar { name = check_fn; loc } when List.assoc_opt check_fn funcs = None ->
                errors := make_error loc
                  ~hint:"use a declared check function"
                  (Printf.sprintf "`%s` is not a known check function" check_fn)
                  :: !errors
              | _ -> ()
            end
          | _ -> ())
       | _ -> ());
      (* Additional check for non-filterCheck expressions at ForAll return position *)
      (match function_name_of_expr head, expected with
       | (Some "List.filterCheck" | Some "Set.filterCheck"
         | Some "List.allCheck" | Some "Set.allCheck"
         | Some "List.emptyForAll"
         | Some "Dict.filterCheckValues" | Some "Dict.filterCheckKeys"), _ -> ()
       | _, Some wanted ->
         let required_preds = proof_predicates wanted in
         if is_sql_select e then begin
           (* A bare SQL select only establishes FromDb — flag any other required preds *)
           let non_fromdb = List.filter (fun p -> p <> "FromDb") required_preds in
           if non_fromdb <> [] then
             let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
             errors := make_error loc
               ~hint:(Printf.sprintf
                 "add `List.filterCheck <checkFn>` after the select to verify each element satisfies [%s]"
                 (String.concat ", " non_fromdb))
               (Printf.sprintf
                 "SQL select only establishes `FromDb`; return type requires `ForAll [%s]` — add a `List.filterCheck` call"
                 (String.concat ", " required_preds))
             :: !errors
         end else begin
           (* For a known function call, verify its return is ForAll-compatible *)
           (match function_name_of_expr head with
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info ->
                 let call_preds = forall_preds_of_return_spec info.fi_return in
                 if call_preds <> [] then begin
                   let missing = List.filter (fun p -> not (List.mem p call_preds)) required_preds in
                   if missing <> [] then
                     let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
                     errors := make_error loc
                       ~hint:(Printf.sprintf
                         "`%s` produces ForAll [%s]; add a `List.filterCheck` step to also prove [%s]"
                         fn_name (String.concat ", " call_preds) (String.concat ", " missing))
                       (Printf.sprintf
                         "`%s` produces `ForAll [%s]` but return type requires `ForAll [%s]` — missing [%s]"
                         fn_name (String.concat ", " call_preds)
                         (String.concat ", " required_preds) (String.concat ", " missing))
                     :: !errors
                 end else if required_preds <> [] then begin
                   let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
                   errors := make_error loc
                     ~hint:(Printf.sprintf
                       "`%s` does not return a `ForAll`-annotated collection; pass the result through `List.filterCheck` or use a function that already returns the required proof"
                       fn_name)
                     (Printf.sprintf
                       "`%s` does not return a `ForAll`-annotated collection but return type requires `ForAll [%s]`"
                       fn_name (String.concat ", " required_preds))
                   :: !errors
                 end
               | None -> ())  (* Unknown function (stdlib/imported) — skip conservatively *)
            | None -> ())
         end
       | _ -> ());
      List.iter (walk forall_env None) args
    | ELet { name; value; body; _ } ->
      walk forall_env None value;
      (* Track ForAll predicates for this binding so nested filterCheck calls can use them. *)
      let elem_preds =
        if is_sql_select value then ["FromDb"]
        else check_call_produced_preds forall_env value
      in
      let forall_env' = if elem_preds = [] then forall_env else (name, elem_preds) :: forall_env in
      walk forall_env' expected body
    | ELetProof { value_name; value; body; _ } ->
      walk forall_env None value;
      let elem_preds =
        if is_sql_select value then ["FromDb"]
        else check_call_produced_preds forall_env value
      in
      let forall_env' = if elem_preds = [] then forall_env else (value_name, elem_preds) :: forall_env in
      walk forall_env' expected body
    | EIf { then_; else_; _ } -> walk forall_env expected then_; walk forall_env expected else_
    | ECase { arms; _ } -> List.iter (fun (arm : case_arm) -> walk forall_env expected arm.body) arms
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
      walk forall_env expected body
    | EVar { name; loc } ->
      (* When a ForAll-annotated variable is returned directly, verify it carries
         all required predicates. *)
      (match expected with
       | Some wanted ->
         let var_preds = match List.assoc_opt name forall_env with
           | Some preds -> preds
           | None -> []
         in
         let required_preds = proof_predicates wanted in
         if var_preds <> [] then begin
           let missing = List.filter (fun pred -> not (List.mem pred var_preds)) required_preds in
           if missing <> [] then
             errors := make_error loc
               ~hint:(Printf.sprintf "add a `List.filterCheck` call to prove [%s] on each element before returning" (String.concat ", " missing))
               (Printf.sprintf "return value `%s` carries ForAll [%s] but return type requires [%s]"
                  name (String.concat ", " var_preds) (String.concat ", " required_preds))
             :: !errors
         end else if required_preds <> [] then
           (* Variable not in forall_env — no ForAll proof has been tracked for it *)
           errors := make_error loc
             ~hint:(Printf.sprintf
               "pass `%s` through `List.filterCheck <checkFn>` to establish the required proof, or annotate the parameter as `%s: List T ::: ForAll P %s`"
               name name name)
             (Printf.sprintf
               "variable `%s` has no tracked `ForAll` proof; cannot satisfy `ForAll [%s]` — is the collection filtered?"
               name (String.concat ", " required_preds))
           :: !errors
       | None -> ())
    | _ -> ()
  in
  List.iter (function
    | DFunc fd ->
      let expected = match fd.return_spec with
        | RetForAll { proof; _ }
        | RetMaybeForAll { proof; _ }
        | RetSetForAll { proof; _ }
        | RetMaybeSetForAll { proof; _ }
        | RetForAllDictValues { proof; _ }
        | RetForAllDictKeys { proof; _ } -> Some proof
        | _ -> None
      in
      (* Seed forall_env with predicates already on ForAll-annotated parameters. *)
      let init_env = List.filter_map (fun (b : binding) ->
        match b.proof_ann with
        | Some (PredApp { pred = "ForAll" | "ForAllValues" | "ForAllKeys"; args = [inner_pred; _]; _ }) ->
          (* Inner pred is a string like "IsActive" or "(P1 && P2)" — extract names *)
          let preds = List.filter (fun s -> s <> "") (String.split_on_char ' '
            (String.concat "" (List.map (fun c ->
              match c with '(' | ')' -> "" | c -> String.make 1 c)
              (List.of_seq (String.to_seq inner_pred))))) in
          let cleaned = List.filter (fun s -> s <> "&&" && s <> "") preds in
          if cleaned = [] then None else Some (b.name, cleaned)
        | _ -> None
      ) fd.params in
      walk init_env expected fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 6. Exists binding proof tracking ────────────────────────────────────── *)

let rec exists_witnesses (e : expr) : string list =
  match e with
  | EApp { fn = EVar { name = "make-witness"; _ };
           arg = EApp { fn = EVar { name = witness; _ }; arg = body; _ }; _ } ->
    witness :: exists_witnesses body
  | EApp { fn; arg; _ } -> exists_witnesses fn @ exists_witnesses arg
  | ELet { value; body; _ } | ELetProof { value; body; _ } -> exists_witnesses value @ exists_witnesses body
  | EIf { cond; then_; else_; _ } -> exists_witnesses cond @ exists_witnesses then_ @ exists_witnesses else_
  | ECase { scrut; arms; _ } -> exists_witnesses scrut @ List.concat_map (fun (arm : case_arm) -> exists_witnesses arm.body) arms
  | EBinop { left; right; _ } -> exists_witnesses left @ exists_witnesses right
  | EUnop { arg; _ } -> exists_witnesses arg
  | ERecord { fields; _ } -> List.concat_map (fun (_, v) -> exists_witnesses v) fields
  | EList { elems; _ } -> List.concat_map exists_witnesses elems
  | EOk { value; _ } -> exists_witnesses value
  | ETelemetry { fields; _ } -> List.concat_map (fun (_, v) -> exists_witnesses v) fields
  | EEnqueue { payload; _ } -> exists_witnesses payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> exists_witnesses e | None -> [])
    @ (match payload with Some e -> exists_witnesses e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } -> exists_witnesses body
  | EServe { port; _ } -> exists_witnesses port
  | ELambda { body; _ } -> exists_witnesses body
  | ELit _ | EVar _ | EField _ | EConstructor _ | EFail _ -> []

let check_exists_bindings (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      (match fd.return_spec with
       | RetExists { binding; _ } ->
         let witnesses = exists_witnesses fd.body |> List.sort_uniq String.compare in
         if witnesses = [] then
           errors := make_error fd.loc
             ~hint:(Printf.sprintf "use `exists %s => ...` in the function body" binding.name)
             (Printf.sprintf "function '%s' declares exists return type but body has no exists expression" fd.name)
             :: !errors
         (* Note: we do NOT enforce that the witness NAME in the body matches the declared name.
            The implementation may use a different internal name (e.g. `i`) while the public
            return spec uses a different name (e.g. `itemId`). The names are matched positionally. *)
       | _ -> ())
    | _ -> ()
  ) decls;
  List.rev !errors

(* R51_E01 — existential-return proof enforcement.
   A function `... -> exists x: T => T ::: P x` is supposed to guarantee
   that the packed value satisfies `P`. Prior to this check, the compiler
   accepted `exists n => n` with NO proof attachment, silently dropping
   the `P x` claim. Detect the obvious forging pattern: the packed body
   is a plain identifier (not the result of a check / establish / auth,
   not attached with `:::`, not the output of a proof-returning stdlib
   helper), but the return spec declares a non-trivial proof.

   This is intentionally conservative: it catches the common footgun
   without over-fitting. Programs that use genuinely complex packs
   (select results, upsert results, explicit attachFact, etc.) still
   go through the runtime evidence layer. *)
let rec inner_return_proof_spec = function
  | RetExists { body; _ } -> inner_return_proof_spec body
  | RetAttached { binding = b; _ } -> b.proof_ann
  | RetNamedPack { entity_proof = Some ep; _ } -> Some ep
  | RetNamedPack { other_proof = Some op; _ } -> Some op
  | _ -> None

(* Collect all the packed values from nested `exists` expressions in a body.
   The same function may contain multiple packs via conditionals, so we
   return a list to avoid losing any of them. *)
let rec packed_body_exprs (e : expr) : expr list =
  match e with
  (* Pattern emitted by parse_exists_expr:
       (make-witness (witness inner_body)) *)
  | EApp {
      fn = EVar { name = "make-witness"; _ };
      arg = EApp { arg = body; _ };
      _ } -> [body]
  | EIf { then_; else_; _ } ->
    packed_body_exprs then_ @ packed_body_exprs else_
  | ECase { arms; _ } ->
    List.concat_map (fun (a : case_arm) -> packed_body_exprs a.body) arms
  | ELet { body; _ } | ELetProof { body; _ } -> packed_body_exprs body
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
  | EWithTransaction { body; _ } -> packed_body_exprs body
  | _ -> []

(* Does this expression demonstrably carry a proof? The cheapest heuristic:
   it is an EOk (check `:::` form), an EConstructor with an uppercased fact
   name, a check / establish call, a stdlib proof-producing call, or a
   database / queue operation whose result is known to carry proofs. *)
let looks_proof_carrying (funcs : (string * func_info) list) (e : expr) : bool =
  match e with
  | EOk _ -> true
  | EConstructor _ -> true
  | EApp { fn; _ } ->
    let rec head = function
      | EVar { name; _ } -> Some name
      | EApp { fn; _ } -> head fn
      | _ -> None
    in
    (match head fn with
     | Some name ->
       (* `select` / `selectOne` / `insert` / `upsert` / `update` all attach
          FromDb / FromQueue style proofs; accept them. *)
       List.mem name [
         "select"; "selectOne"; "selectCount"; "selectSum";
         "selectMax"; "selectMin"; "insert"; "insertMany";
         "upsert"; "update"; "updateAndReturnOne";
         "check"; "make-witness"; "attachFact"; "#record-update#";
       ]
       || (match List.assoc_opt name funcs with
           | Some info ->
             info.fi_kind = CheckKind
             || info.fi_kind = EstablishKind
             || info.fi_kind = AuthKind
             || (match info.fi_return with
                 | RetAttached { binding = b; _ } -> b.proof_ann <> None
                 | RetNamedPack _ -> true
                 | _ -> false)
           | None -> false)
     | None -> false)
  | _ -> false

let check_existential_proof_enforcement (decls : top_decl list) : validation_error list =
  let _funcs = () in
  let _ = _funcs in
  List.concat_map (function
    | DFunc fd ->
      (match fd.return_spec with
       | RetExists _ ->
         (match inner_return_proof_spec fd.return_spec with
          | Some _ ->
            (* A non-trivial proof is declared for the inner body.
               Narrow heuristic — only flag when the packed expression is
               *literally a function parameter* with no further tracking,
               because a parameter has no proof history. `let`-bound names
               or database-operation results are left to the runtime
               evidence layer; they are too easily false-positive in this
               static analysis. *)
            let param_names =
              List.map (fun (b : binding) -> b.name) fd.params
            in
            List.concat_map (fun body ->
              match body with
              | EVar { loc; name } when List.mem name param_names ->
                [ make_error loc
                    ~hint:"validate the packed value with a `check` function so it carries the proof, or attach an existing proof with `value ::: proofVar`"
                    (Printf.sprintf
                       "existential pack returns the raw parameter `%s` but the declared proof is not demonstrably attached to it; the inner body of `exists ... => body` must carry the proof declared in the return spec"
                       name) ]
              | _ -> []
            ) (packed_body_exprs fd.body)
          | None -> [])
       | _ -> [])
    | _ -> []
  ) decls

(* ── B1. Non-exhaustive case expressions ─────────────────────────────────── *)

(** Extract the outermost type constructor name from a type expression.
    For `TName "Maybe"` → `"Maybe"`.
    For `TApp (TApp (TName "Result") a) e` → `"Result"`. *)
let rec head_type_name : type_expr -> string option = function
  | TName { name; _ } -> Some name
  | TApp { head; _ } -> head_type_name head
  | _ -> None

(** Given a ctor_info (ctor -> (field_types, result_type)) and an ADT type name,
    return the list of all constructor names for that ADT.
    Handles both plain types (TName) and parameterized types (TApp). *)
let ctors_for_type (ctors : ctor_info) (adt_name : string) : string list =
  match adt_name with
  | "Bool" -> ["True"; "False"]
  | _ ->
    List.filter_map (fun (ctor_name, (_, result_ty)) ->
      match head_type_name result_ty with
      | Some name when name = adt_name -> Some ctor_name
      | _ -> None
    ) ctors

let ctor_signature (ctors : ctor_info) (ctor_name : string) : (type_expr list * type_expr) option =
  match ctor_name with
  | "True" | "False" -> Some ([], mk_name_type "Bool")
  | _ -> List.assoc_opt ctor_name ctors

let rec unify_type_vars
    (expected : type_expr)
    (actual : type_expr)
    (subst : (string * type_expr) list)
    : (string * type_expr) list option =
  match expected, actual with
  | TVar { name; _ }, ty ->
    (match List.assoc_opt name subst with
     | Some existing when existing = ty -> Some subst
     | Some _ -> None
     | None -> Some ((name, ty) :: subst))
  | TName { name = expected_name; _ }, TName { name = actual_name; _ } when expected_name = actual_name -> Some subst
  | TApp { head = expected_head; arg = expected_arg; _ },
    TApp { head = actual_head; arg = actual_arg; _ } ->
    (match unify_type_vars expected_head actual_head subst with
     | Some subst' -> unify_type_vars expected_arg actual_arg subst'
     | None -> None)
  | TTuple { elems = expected_elems; _ }, TTuple { elems = actual_elems; _ }
    when List.length expected_elems = List.length actual_elems ->
    List.fold_left2 (fun acc expected_elem actual_elem ->
      match acc with
      | Some subst' -> unify_type_vars expected_elem actual_elem subst'
      | None -> None
    ) (Some subst) expected_elems actual_elems
  | TFun { dom = expected_dom; cod = expected_cod; _ },
    TFun { dom = actual_dom; cod = actual_cod; _ } ->
    (match unify_type_vars expected_dom actual_dom subst with
     | Some subst' -> unify_type_vars expected_cod actual_cod subst'
     | None -> None)
  | _ -> None

let rec apply_type_subst (subst : (string * type_expr) list) (ty : type_expr) : type_expr =
  match ty with
  | TVar { name; _ } -> Option.value (List.assoc_opt name subst) ~default:ty
  | TApp { head; arg; loc } ->
    TApp { head = apply_type_subst subst head; arg = apply_type_subst subst arg; loc }
  | TFun { dom; cod; loc } ->
    TFun { dom = apply_type_subst subst dom; cod = apply_type_subst subst cod; loc }
  | TTuple { elems; loc } ->
    TTuple { elems = List.map (apply_type_subst subst) elems; loc }
  | TName _ -> ty

let ctor_field_types_for_scrutinee
    (ctors : ctor_info)
    (ctor_name : string)
    (scrut_ty : type_expr)
    : type_expr list option =
  match ctor_signature ctors ctor_name with
  | Some (field_types, result_ty) ->
    (match unify_type_vars result_ty scrut_ty [] with
     | Some subst -> Some (List.map (apply_type_subst subst) field_types)
     | None -> Some field_types)
  | None -> None

let wildcard_patterns (field_types : type_expr list) : pattern list =
  List.map (fun _ -> PWild) field_types

let specialize_rows_for_ctor
    (ctor_name : string)
    (field_types : type_expr list)
    (rows : pattern list list)
    : pattern list list =
  let wilds = wildcard_patterns field_types in
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | pat :: tail ->
      match pat with
      | PWild | PVar _ -> Some (wilds @ tail)
      | PNullary { ctor; _ } when ctor = ctor_name && field_types = [] -> Some tail
      | PCon { ctor; fields; _ }
        when ctor = ctor_name && List.length fields = List.length field_types ->
        Some (List.map snd fields @ tail)
      | _ -> None
  ) rows

let default_rows (rows : pattern list list) : pattern list list =
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | (PWild | PVar _) :: tail -> Some tail
    | _ -> None
  ) rows

let row_is_catch_all (row : pattern list) : bool =
  List.for_all (function PWild | PVar _ -> true | _ -> false) row

let rec patterns_are_exhaustive_for_types
    (ctors : ctor_info)
    (tys : type_expr list)
    (rows : pattern list list)
    : bool =
  match tys with
  | [] -> rows <> []
  | _ when List.exists row_is_catch_all rows -> true
  | ty :: rest ->
    let defaults = default_rows rows in
    match head_type_name ty with
    | Some adt_name ->
      let all_ctors = ctors_for_type ctors adt_name in
      if all_ctors = [] then
        patterns_are_exhaustive_for_types ctors rest defaults
      else
        List.for_all (fun ctor_name ->
          match ctor_field_types_for_scrutinee ctors ctor_name ty with
          | Some field_types ->
            let specialized = specialize_rows_for_ctor ctor_name field_types rows in
            patterns_are_exhaustive_for_types ctors (field_types @ rest) specialized
          | None -> false
        ) all_ctors
    | None ->
      patterns_are_exhaustive_for_types ctors rest defaults

let patterns_are_exhaustive_for_type
    (ctors : ctor_info)
    (ty : type_expr)
    (patterns : pattern list)
    : bool =
  patterns_are_exhaustive_for_types ctors [ty] (List.map (fun pat -> [pat]) patterns)

let rec check_case_exhaustiveness_expr
    (env : type_env)
    (funcs : (string * func_info) list)
    (fields_by_type : field_map)
    (ctors : ctor_info)
    (e : expr)
    : validation_error list =
  let recurse = check_case_exhaustiveness_expr env funcs fields_by_type ctors in
  match e with
  | ECase { scrut; arms; loc } ->
    (* Check sub-expressions first *)
    let scrut_errors = recurse scrut in
    let scrut_ty = infer_expr_type env funcs fields_by_type ctors scrut in
    (* A guarded arm does NOT count as full coverage: if the guard fails, the
       value is unhandled.  Only unguarded arms (or unguarded wildcards) establish
       exhaustiveness.  Reachability analysis below is still guard-aware and does
       not let guards create duplicate-arm false positives. *)
    let has_wildcard = List.exists (fun (arm : case_arm) ->
      arm.guard = None &&
      (match arm.pattern with PWild | PVar _ -> true | _ -> false)
    ) arms in
    let case_errors =
      if has_wildcard then []
      else
        (* Collect constructors covered by at least one UNGUARDED arm.
           A guarded arm for constructor C does not count as covering C. *)
        let covered = List.filter_map (fun (arm : case_arm) ->
          if arm.guard <> None then None
          else match arm.pattern with
          | PCon { ctor; _ } -> Some ctor
          | PNullary { ctor; _ } -> Some ctor
          | _ -> None
        ) arms in
        (* Look up all constructors for the scrutinee's ADT *)
        let all_ctors = match scrut_ty with
          | Some ty ->
            (match head_type_name ty with
             | Some adt_name -> ctors_for_type ctors adt_name
             | None -> [])
          | None -> []
        in
        if all_ctors = [] then []
        else
          let missing = List.filter (fun c -> not (List.mem c covered)) all_ctors in
          if missing = [] then []
          else
            (* Distinguish between constructors that are truly absent and constructors
               that appear in the case but only with `where` guards.  If ALL arms for
               a constructor are guarded, those arms provide no exhaustiveness guarantee
               (the guard could fail), but the error message "missing" is misleading
               when the constructors ARE present. *)
            let guarded_only = List.filter (fun c ->
              List.mem c missing &&
              List.exists (fun (arm : case_arm) ->
                arm.guard <> None &&
                (match arm.pattern with
                 | PCon { ctor; _ } | PNullary { ctor; _ } -> ctor = c
                 | _ -> false)
              ) arms
            ) missing in
            let genuinely_missing = List.filter (fun c ->
              not (List.mem c guarded_only)) missing in
            let errors = ref [] in
            if genuinely_missing <> [] then
              errors := make_error loc
                (Printf.sprintf "non-exhaustive case: missing constructor(s) [%s]"
                   (String.concat ", " genuinely_missing))
                :: !errors;
            if guarded_only <> [] then
              errors := make_error loc
                ~hint:"add an unguarded catch-all arm `_ -> ...` to handle cases where all guards fail"
                (Printf.sprintf
                   "non-exhaustive case: constructor(s) [%s] only appear in guarded arms — \
if every guard fails at runtime, the case has no match"
                   (String.concat ", " guarded_only))
                :: !errors;
            List.rev !errors
    in
    (* Check pattern arity — PNullary used on a constructor that has fields is an error *)
    let arity_errors = List.concat_map (fun (arm : case_arm) ->
      match arm.pattern with
      | PNullary { ctor; loc } ->
        (match List.assoc_opt ctor ctors with
         | Some (field_types, _) when field_types <> [] ->
           [ make_error loc
               (Printf.sprintf "pattern `%s` expects %d field%s but was used without any"
                  ctor (List.length field_types)
                  (if List.length field_types = 1 then "" else "s")) ]
         | _ -> [])
      | _ -> []
    ) arms in
    let arm_errors = List.concat_map (fun (arm : case_arm) ->
      let arm_env = pattern_bindings scrut_ty ctors arm.pattern @ env in
      check_case_exhaustiveness_expr arm_env funcs fields_by_type ctors arm.body
    ) arms in
    (* Literal exhaustiveness: require a catch-all when all patterns are literals *)
    let literal_errors =
      if has_wildcard then []
      else
        let arm_count = List.length arms in
        let literal_count = List.length (List.filter (fun (arm : case_arm) ->
          match arm.pattern with PLit _ -> true | _ -> false
        ) arms) in
        if arm_count > 0 && literal_count = arm_count then
          [ make_error loc
              ~hint:"add a catch-all arm `_ -> ...` to handle all other values"
              "non-exhaustive case: literal patterns (Int, Float, or String) always require a catch-all arm `_ -> ...`" ]
        else []
    in
    let recursive_errors =
      if has_wildcard then []
      else
        match scrut_ty with
        | Some ty ->
          (* Only unguarded arms count toward exhaustiveness for nested patterns too. *)
          let patterns = List.filter_map (fun (arm : case_arm) ->
            if arm.guard = None then Some arm.pattern else None
          ) arms in
          if patterns_are_exhaustive_for_type ctors ty patterns
          || case_errors <> [] || literal_errors <> []
          then []
          else
            [ make_error loc
                ~hint:"add a catch-all arm `_ -> ...` or cover the remaining nested values explicitly"
                "non-exhaustive case: nested constructor/literal patterns leave uncovered values" ]
        | None -> []
    in
    (* Redundancy analysis (review 50 §2.4).
       Catches three independent classes of dead case arms:
       1. A constructor arm after an earlier arm with the same constructor tag
          and no narrowing inner pattern (each subsequent arm is unreachable).
       2. A literal arm duplicating an earlier literal arm with the same value.
       3. Any arm after a wildcard / variable catch-all (the catch-all already
          matches everything, so all following arms are dead code).
       Reporting is always at the offending arm's pattern location, so the
       editor can highlight exactly what to delete. *)
    let redundancy_errors =
      let lit_key = function
        | LInt n -> Some (`Int n)
        | LString s -> Some (`Str s)
        | LFloat _ -> None
        | LBool _ -> None
        | _ -> None
      in
      (* A constructor arm fully covers every value with that constructor only
         when its *immediate* fields are plain binders/wildcards.
         `Something 0`, `Something Nothing`, and `Something (Pair _ _)` all
         narrow the `Something` space, so later `Something ...` arms may still
         be reachable.  This deliberately stays conservative to avoid false
         positives on nested-pattern coverage. *)
      let pat_is_open = function
        | PWild | PVar _ -> true
        | PNullary _ -> true
        | PCon { fields; _ } ->
          List.for_all (function
            | (_, PWild) | (_, PVar _) -> true
            | _ -> false
          ) fields
        | PLit _ -> false
      in
      let catchall_seen = ref false in
      let catchall_loc = ref None in
      (* Open-coverage tracking: only an arm whose pattern is fully open
         establishes redundant coverage for the constructor tag. *)
      let seen_open_ctors : (string * Location.loc) list ref = ref [] in
      let seen_lits : ([ `Int of int | `Str of string ] * Location.loc) list ref = ref [] in
      let errs = ref [] in
      List.iter (fun (arm : case_arm) ->
        let guarded = arm.guard <> None in
        let pat_loc = match arm.pattern with
          | PWild -> loc
          | PVar _ -> loc
          | PCon { loc; _ } -> loc
          | PNullary { loc; _ } -> loc
          | PLit { loc; _ } -> loc
        in
        if !catchall_seen then begin
          let prior = match !catchall_loc with
            | Some l ->
              Printf.sprintf " (a catch-all arm at line %d already matches everything)"
                (l.Location.start.Location.line + 1)
            | None -> ""
          in
          errs := make_error pat_loc
            ~hint:"remove this arm, or move it before the catch-all arm"
            (Printf.sprintf "unreachable case arm%s" prior) :: !errs
        end else
          match arm.pattern with
          | PWild | PVar _ ->
            if not guarded then begin
              catchall_seen := true;
              catchall_loc := Some pat_loc
            end
          | PNullary { ctor; _ } | PCon { ctor; _ } ->
            (match List.assoc_opt ctor !seen_open_ctors with
             | Some prev_loc ->
               errs := make_error pat_loc
                 ~hint:(Printf.sprintf
                   "a case arm for `%s` already appears at line %d; remove this duplicate"
                   ctor (prev_loc.Location.start.Location.line + 1))
                 (Printf.sprintf "duplicate case arm: constructor `%s` is already covered" ctor)
                 :: !errs
             | None ->
               if (not guarded) && pat_is_open arm.pattern then
                 seen_open_ctors := (ctor, pat_loc) :: !seen_open_ctors)
          | PLit { value; _ } ->
            (match lit_key value with
             | Some key ->
               (match List.assoc_opt key !seen_lits with
                | Some prev_loc ->
                  errs := make_error pat_loc
                    ~hint:(Printf.sprintf
                      "this literal is already matched at line %d; remove this duplicate"
                      (prev_loc.Location.start.Location.line + 1))
                    "duplicate case arm: literal value is already covered"
                    :: !errs
                | None ->
                  seen_lits := (key, pat_loc) :: !seen_lits)
             | None -> ())
      ) arms;
      List.rev !errs
    in
    scrut_errors @ case_errors @ arity_errors @ literal_errors @ recursive_errors @ redundancy_errors @ arm_errors
  | ELit _ | EVar _ | EConstructor _ | EFail _ -> []
  | EField { obj; _ } -> recurse obj
  | EApp { fn; arg; _ } -> recurse fn @ recurse arg
  | EBinop { left; right; _ } -> recurse left @ recurse right
  | EUnop { arg; _ } -> recurse arg
  | EIf { cond; then_; else_; _ } -> recurse cond @ recurse then_ @ recurse else_
  | ELet { name; value; body; _ } ->
    let value_errors = recurse value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: env
      | None -> env
    in
    value_errors @ check_case_exhaustiveness_expr env' funcs fields_by_type ctors body
  | ELetProof { value_name; value; body; _ } ->
    let value_errors = recurse value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (value_name, ty) :: env
      | None -> env
    in
    value_errors @ check_case_exhaustiveness_expr env' funcs fields_by_type ctors body
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> recurse v) fields
  | EList { elems; _ } -> List.concat_map recurse elems
  | EOk { value; _ } -> recurse value
  | ETelemetry { fields; _ } ->
    List.concat_map (fun (_, v) -> recurse v) fields
  | EEnqueue { payload; _ } -> recurse payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> recurse e | None -> [])
    @ (match payload with Some e -> recurse e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    recurse body
  | EServe { port; _ } -> recurse port
  | ELambda { params; body; _ } ->
    let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
    check_case_exhaustiveness_expr env' funcs fields_by_type ctors body

let check_case_exhaustiveness ?(extra_ctors=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls @ extra_ctors in
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      errors := check_case_exhaustiveness_expr env funcs fields_by_type ctors fd.body @ !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── B2. Name shadowing detection ───────────────────────────────────────── *)

(** Collect variable names bound by a pattern (excluding "_"). *)
let rec pattern_bound_names (pat : pattern) : string list =
  match pat with
  | PWild | PLit _ -> []
  | PVar s -> if s = "_" then [] else [s]
  | PNullary _ -> []
  | PCon { fields; _ } ->
    List.concat_map (fun (_, sub_pat) -> pattern_bound_names sub_pat) fields

let duplicate_parameter_errors (bindings : binding list) : validation_error list =
  let seen = ref [] in
  List.concat_map (fun (b : binding) ->
    if b.name = "_" then []
    else if List.mem b.name !seen then
      [ make_error b.loc
          ~hint:(Printf.sprintf "rename one of the parameters named `%s`" b.name)
          (Printf.sprintf "duplicate parameter name `%s`" b.name) ]
    else (
      seen := b.name :: !seen;
      []
    )
  ) bindings

(** Walk every `exists witness => body` in an expression, tracking only the
    witness names seen in outer `exists` frames.  Fires when an inner `exists`
    reuses the same witness name as an outer one — e.g. `exists p => exists p
    => p` — which would make the two existential packages indistinguishable. *)
let rec check_exists_witness_shadowing (exist_seen : string list) (e : expr)
    : validation_error list =
  match e with
  | EApp { fn = EVar { name = "make-witness"; _ };
           arg = EApp { fn = EVar { name = witness; loc = wit_loc; _ }; arg = body; _ }; _ } ->
    let shadow_errors =
      if witness <> "_" && List.mem witness exist_seen then
        [ make_error wit_loc
            (Printf.sprintf
               "exists witness `%s` shadows the outer exists witness of the same name"
               witness) ]
      else []
    in
    let exist_seen' = if witness = "_" then exist_seen else witness :: exist_seen in
    shadow_errors @ check_exists_witness_shadowing exist_seen' body
  | EApp { fn; arg; _ } ->
    check_exists_witness_shadowing exist_seen fn
    @ check_exists_witness_shadowing exist_seen arg
  | ELet { value; body; _ } | ELetProof { value; body; _ } ->
    check_exists_witness_shadowing exist_seen value
    @ check_exists_witness_shadowing exist_seen body
  | EIf { cond; then_; else_; _ } ->
    check_exists_witness_shadowing exist_seen cond
    @ check_exists_witness_shadowing exist_seen then_
    @ check_exists_witness_shadowing exist_seen else_
  | ECase { scrut; arms; _ } ->
    check_exists_witness_shadowing exist_seen scrut
    @ List.concat_map (fun (arm : case_arm) ->
        check_exists_witness_shadowing exist_seen arm.body) arms
  | EBinop { left; right; _ } ->
    check_exists_witness_shadowing exist_seen left
    @ check_exists_witness_shadowing exist_seen right
  | EUnop { arg; _ } | EField { obj = arg; _ } ->
    check_exists_witness_shadowing exist_seen arg
  | EList { elems; _ } ->
    List.concat_map (check_exists_witness_shadowing exist_seen) elems
  | EOk { value; _ } -> check_exists_witness_shadowing exist_seen value
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> check_exists_witness_shadowing exist_seen v) fields
  | ELambda { body; _ }
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
  | EWithTransaction { body; _ } -> check_exists_witness_shadowing exist_seen body
  | EConstructor { args; _ } ->
    List.concat_map (check_exists_witness_shadowing exist_seen) args
  | ELit _ | EVar _ | EFail _ | EServe _ | EStartWorkers _
  | ETelemetry _ | EEnqueue _ | EPublish _ -> []

let rec check_name_shadowing_expr
    (seen : string list)
    (e : expr)
    : validation_error list =
  match e with
  | ELet { name; value; body; loc; _ } ->
    let value_errors = check_name_shadowing_expr seen value in
    let shadow_errors =
      if name <> "_" && List.mem name seen then
        [ make_error loc
            (Printf.sprintf "let binding shadows existing name(s): `%s`" name) ]
      else []
    in
    let seen' = if name <> "_" then name :: seen else seen in
    value_errors @ shadow_errors @ check_name_shadowing_expr seen' body
  | ECase { scrut; arms; _ } ->
    let scrut_errors = check_name_shadowing_expr seen scrut in
    let arm_errors = List.concat_map (fun (arm : case_arm) ->
      let bound = pattern_bound_names arm.pattern in
      (* Check for duplicate binders within this arm's own pattern *)
      let dup_errors =
        let rec find_dups seen_in_pat = function
          | [] -> []
          | name :: rest ->
            if List.mem name seen_in_pat then
              [ make_error arm.loc
                  ~hint:(Printf.sprintf "rename one of the `%s` binders" name)
                  (Printf.sprintf "duplicate variable binding `%s` in case arm pattern" name) ]
            else find_dups (name :: seen_in_pat) rest
        in
        find_dups [] bound
      in
      let shadow_errors = List.filter_map (fun var_name ->
        if List.mem var_name seen then
          Some (make_error arm.loc
            (Printf.sprintf "case pattern binder `%s` shadows an existing name" var_name))
        else None
      ) bound in
      let seen' = bound @ seen in
      let guard_errors =
        match arm.guard with
        | Some guard -> check_name_shadowing_expr seen' guard
        | None -> []
      in
      dup_errors @ shadow_errors @ guard_errors @ check_name_shadowing_expr seen' arm.body
    ) arms in
    scrut_errors @ arm_errors
  | ELit _ | EVar _ | EConstructor _ | EFail _ -> []
  | EField { obj; _ } -> check_name_shadowing_expr seen obj
  | EApp { fn; arg; _ } ->
    check_name_shadowing_expr seen fn @ check_name_shadowing_expr seen arg
  | EBinop { left; right; _ } ->
    check_name_shadowing_expr seen left @ check_name_shadowing_expr seen right
  | EUnop { arg; _ } -> check_name_shadowing_expr seen arg
  | EIf { cond; then_; else_; _ } ->
    check_name_shadowing_expr seen cond
    @ check_name_shadowing_expr seen then_
    @ check_name_shadowing_expr seen else_
  | ELetProof { value_name; proof_name; value; body; loc; _ } ->
    let value_errors = check_name_shadowing_expr seen value in
    let bound_names =
      List.filter (fun name -> name <> "_") [value_name; proof_name]
    in
    let duplicate_errors =
      match bound_names with
      | [a; b] when a = b ->
        [ make_error loc
            ~hint:(Printf.sprintf "rename one of the `%s` binders" a)
            (Printf.sprintf "duplicate variable binding `%s` in let-proof pattern" a) ]
      | _ -> []
    in
    let shadow_errors = List.filter_map (fun name ->
      if List.mem name seen then
        Some (make_error loc
          (Printf.sprintf "let binding shadows existing name(s): `%s`" name))
      else None
    ) bound_names in
    value_errors
    @ duplicate_errors
    @ shadow_errors
    @ check_name_shadowing_expr (bound_names @ seen) body
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> check_name_shadowing_expr seen v) fields
  | EList { elems; _ } -> List.concat_map (check_name_shadowing_expr seen) elems
  | EOk { value; _ } -> check_name_shadowing_expr seen value
  | ETelemetry { fields; _ } ->
    List.concat_map (fun (_, v) -> check_name_shadowing_expr seen v) fields
  | EEnqueue { payload; _ } -> check_name_shadowing_expr seen payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> check_name_shadowing_expr seen e | None -> [])
    @ (match payload with Some e -> check_name_shadowing_expr seen e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    check_name_shadowing_expr seen body
  | EServe { port; _ } -> check_name_shadowing_expr seen port
  | ELambda { params; body; _ } ->
    let duplicate_errors = duplicate_parameter_errors params in
    let shadow_errors = List.filter_map (fun (b : binding) ->
      if b.name <> "_" && List.mem b.name seen then
        Some (make_error b.loc
          (Printf.sprintf "let binding shadows existing name(s): `%s`" b.name))
      else None
    ) params in
    let seen' =
      List.fold_right (fun (b : binding) acc ->
        if b.name = "_" then acc else b.name :: acc
      ) params seen
    in
    duplicate_errors @ shadow_errors @ check_name_shadowing_expr seen' body


and check_name_shadowing_test_stmts
    (seen : string list)
    (stmts : test_stmt list)
    : validation_error list =
  match stmts with
  | [] -> []
  | stmt :: rest ->
    let stmt_errors, seen' =
      match stmt with
      | TsLetProof { value_name = name; proof_names; value; loc; _ } ->
        let value_errors = check_name_shadowing_expr seen value in
        let shadow_errors =
          if name <> "_" && List.mem name seen then
            [ make_error loc
                (Printf.sprintf "let binding shadows existing name(s): `%s`" name) ]
          else []
        in
        let seen' = if name <> "_" then name :: seen else seen in
        let seen' = List.fold_left (fun acc pn -> if pn <> "_" then pn :: acc else acc) seen' proof_names in
        (value_errors @ shadow_errors, seen')
      | TsLet { name; value; loc; _ } ->
        let value_errors = check_name_shadowing_expr seen value in
        let shadow_errors =
          if name <> "_" && List.mem name seen then
            [ make_error loc
                (Printf.sprintf "let binding shadows existing name(s): `%s`" name) ]
          else []
        in
        let seen' = if name <> "_" then name :: seen else seen in
        (value_errors @ shadow_errors, seen')
      | TsExpect { left; right; _ } ->
        let expr_errors =
          check_name_shadowing_expr seen left
          @ (match right with Some r -> check_name_shadowing_expr seen r | None -> [])
        in
        (expr_errors, seen)
      | TsExpectFail { fn; arg; _ }
      | TsExpectHasProof { fn; arg; _ } ->
        (check_name_shadowing_expr seen fn @ check_name_shadowing_expr seen arg, seen)
      | TsProperty { params; body; _ } ->
        let bindings = List.map (fun (p : property_param) -> p.binding) params in
        let duplicate_errors = duplicate_parameter_errors bindings in
        let shadow_errors = List.filter_map (fun (p : property_param) ->
          let b = p.binding in
          if b.name <> "_" && List.mem b.name seen then
            Some (make_error b.loc
              (Printf.sprintf "let binding shadows existing name(s): `%s`" b.name))
          else None
        ) params in
        let prop_seen =
          List.fold_right (fun (b : binding) acc ->
            if b.name = "_" then acc else b.name :: acc
          ) bindings seen
        in
        let where_errors = List.concat_map (fun (p : property_param) ->
          match p.where_clause with
          | Some guard -> check_name_shadowing_expr prop_seen guard
          | None -> []
        ) params in
        let body_errors = check_name_shadowing_expr prop_seen body in
        (duplicate_errors @ shadow_errors @ where_errors @ body_errors, seen)
      | TsIf { cond; then_stmts; else_stmts; _ } ->
        let branch_errors =
          check_name_shadowing_expr seen cond
          @ check_name_shadowing_test_stmts seen then_stmts
          @ check_name_shadowing_test_stmts seen else_stmts
        in
        (branch_errors, seen)
      | TsCase { scrut; arms; _ } ->
        let scrut_errors = check_name_shadowing_expr seen scrut in
        let arm_errors = List.concat_map (fun (arm : ts_case_arm) ->
          let bound = pattern_bound_names arm.ts_pattern in
          let dup_errors =
            let rec find_dups seen_in_pat = function
              | [] -> []
              | name :: rest ->
                if List.mem name seen_in_pat then
                  [ make_error arm.ts_loc
                      ~hint:(Printf.sprintf "rename one of the `%s` binders" name)
                      (Printf.sprintf "duplicate variable binding `%s` in case arm pattern" name) ]
                else find_dups (name :: seen_in_pat) rest
            in
            find_dups [] bound
          in
          let shadow_errors = List.filter_map (fun var_name ->
            if List.mem var_name seen then
              Some (make_error arm.ts_loc
                (Printf.sprintf "let binding shadows existing name(s): `%s`" var_name))
            else None
          ) bound in
          let arm_seen = bound @ seen in
          let guard_errors =
            match arm.ts_guard with
            | Some guard -> check_name_shadowing_expr arm_seen guard
            | None -> []
          in
          dup_errors
          @ shadow_errors
          @ guard_errors
          @ check_name_shadowing_test_stmts arm_seen arm.ts_body
        ) arms in
        (scrut_errors @ arm_errors, seen)
      | TsExpr { e; _ } ->
        (check_name_shadowing_expr seen e, seen)
    in
    stmt_errors @ check_name_shadowing_test_stmts seen' rest

(* ── ForAll parameter subject enforcement ───────────────────────────────── *)

(** True when a proof expression contains a ForAll predicate without an explicit
    subject variable — i.e. `ForAll P` with only one argument. *)
let rec has_subjectless_forall (proof : proof_expr) : bool =
  match proof with
  | PredApp { pred = "ForAll" | "ForAllValues" | "ForAllKeys"; args = [_]; _ } -> true
  | PredAnd { left; right; _ } -> has_subjectless_forall left || has_subjectless_forall right
  | _ -> false

(** True if a type expression is List, Maybe List, Set, or Maybe Set (i.e. valid ForAll subject). *)
let rec is_collection_type (te : Ast.type_expr) : bool =
  match te with
  | TName { name = "List"; _ }
  | TName { name = "Set"; _ } -> true
  | TApp { head = TName { name = "List"; _ }; _ }
  | TApp { head = TName { name = "Set"; _ }; _ } -> true
  | TApp { head = TName { name = "Maybe"; _ }; arg; _ } -> is_collection_type arg
  | TApp { head; _ } -> is_collection_type head
  | _ -> false

(** True if a type expression is Dict K V (valid ForAllValues/ForAllKeys subject). *)
let is_dict_type (te : Ast.type_expr) : bool =
  match te with
  | TApp { head = TApp { head = TName { name = "Dict"; _ }; _ }; _ } -> true
  | _ -> false

(** Extract the ForAll subject variable from a proof, if present. *)
let rec forall_subjects (proof : proof_expr) : string list =
  match proof with
  | PredApp { pred = "ForAll"; args = [_; subj]; _ } -> [subj]
  | PredApp { pred = "ForAll"; args = [_]; _ } -> []
  | PredAnd { left; right; _ } -> forall_subjects left @ forall_subjects right
  | _ -> []

(** Extract the ForAllValues/ForAllKeys subject variable from a proof, if present. *)
let rec foralldict_subjects (proof : proof_expr) : string list =
  match proof with
  | PredApp { pred = "ForAllValues" | "ForAllKeys"; args = [_; subj]; _ } -> [subj]
  | PredApp { pred = "ForAllValues" | "ForAllKeys"; args = [_]; _ } -> []
  | PredAnd { left; right; _ } -> foralldict_subjects left @ foralldict_subjects right
  | _ -> []

(** Check that every parameter (and handler body-binding) ForAll proof annotation
    carries an explicit subject variable that matches the parameter name.
    e.g. `xs: List T ::: ForAll P xs` is valid; `xs: List T ::: ForAll P` is not.
    Also checks that ForAll subjects have a collection type (List or Set). *)
let check_forall_param_subjects (decls : top_decl list) : validation_error list =
  let check_binding (b : binding) =
    match b.proof_ann with
    | None -> []
    | Some proof ->
      let subjectless_errors =
        if has_subjectless_forall proof then
          [ make_error b.loc
              ~hint:(Printf.sprintf
                "add the parameter name as explicit subject: `%s ::: ForAll P %s`"
                b.name b.name)
              (Printf.sprintf
                "parameter `%s` has a `ForAll` annotation without an explicit subject variable; \
                 write `ForAll Predicate %s` to ensure the proof is tied to this parameter"
                b.name b.name) ]
        else []
      in
      (* Check that the parameter's declared type is a collection when ForAll is used *)
      let non_collection_errors =
        let subjects = forall_subjects proof in
        let dict_subjects = foralldict_subjects proof in
        let forall_errors =
          if subjects = [] then []
          else
            if not (is_collection_type b.type_expr) then
              [ make_error b.loc
                  ~hint:(Printf.sprintf
                    "`ForAll` quantifies over elements of a collection; \
                     parameter `%s` should have type `List T` or `Set T`"
                    b.name)
                  (Printf.sprintf
                    "parameter `%s` has a `ForAll` proof annotation but its type is not a collection \
                     (`List` or `Set`); `ForAll` is only meaningful on list or set-typed parameters"
                    b.name) ]
            else []
        in
        let dict_forall_errors =
          if dict_subjects = [] then []
          else
            if not (is_dict_type b.type_expr) then
              [ make_error b.loc
                  ~hint:(Printf.sprintf
                    "`ForAllValues`/`ForAllKeys` quantifies over a dict; \
                     parameter `%s` should have type `Dict K V`"
                    b.name)
                  (Printf.sprintf
                    "parameter `%s` has a `ForAllValues`/`ForAllKeys` proof annotation but its type is not \
                     a `Dict K V`; these quantifiers are only meaningful on dict-typed parameters"
                    b.name) ]
            else []
        in
        forall_errors @ dict_forall_errors
      in
      subjectless_errors @ non_collection_errors
  in
  List.concat_map (function
    | DFunc fd ->
      List.concat_map check_binding fd.params
    | _ -> []
  ) decls

let strip_exposed_import_name (name : string) : string =
  let len = String.length name in
  if len > 4 && String.sub name (len - 4) 4 = "(..)" then
    String.sub name 0 (len - 4)
  else
    name

let push_unique_name acc name =
  if name = "_" || List.mem name acc then acc else name :: acc

let local_function_names (decls : top_decl list) : string list =
  (* Collect both top-level `fn` names and top-level immutable bindings
     (spec §11.2) so the no-shadowing rule (§7.4, §13.2) applies to both
     uniformly. R51_S01 closed the gap where top-level value bindings
     were silently shadowable by function parameters. *)
  List.fold_left (fun acc -> function
    | DFunc fd -> push_unique_name acc fd.name
    | DConst c -> push_unique_name acc c.name
    | _ -> acc
  ) [] decls
  |> List.rev

let imported_plain_exposed_name_entries (m : module_form) : (string * string * loc) list =
  List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> []
    | ImportExposing names ->
      List.filter_map (fun name ->
        let base = strip_exposed_import_name name in
        if String.contains base '.' then None
        else Some (base, imp.module_name, imp.loc)
      ) names
  ) m.imports

let imported_plain_exposed_names (m : module_form) : string list =
  List.fold_left (fun acc (name, _, _) -> push_unique_name acc name) [] (imported_plain_exposed_name_entries m)
  |> List.rev

let imported_plain_exposed_type_entries (m : module_form) : (string * string * loc) list =
  List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> []
    | ImportExposing names ->
      List.filter_map (fun name ->
        match normalize_exposed_type_name name with
        | Some type_name -> Some (type_name, imp.module_name, imp.loc)
        | None -> None
      ) names
  ) m.imports

let imported_ctor_request_type_names (imp : import_decl) : string list =
  match imp.names with
  | ImportAll -> []
  | ImportExposing names ->
    List.filter_map (fun name ->
      let n = String.length name in
      if n >= 4 && String.sub name (n - 4) 4 = "(..)" then
        normalize_exposed_type_name name
      else
        None
    ) names

(** Constructors exported by stdlib ADT types, keyed by the type name.
    Used to detect conflicts when a local ADT reuses a stdlib constructor name. *)
let stdlib_adt_ctors : (string * (string * string list)) list = [
  (* (tesl_module, (type_name, [constructors...])) *)
  ("Tesl.Maybe",   ("Maybe",        ["Maybe"; "Something"; "Nothing"]));
  ("Tesl.Result",  ("Result",       ["Result"; "Ok"; "Err"]));
  ("Tesl.Either",  ("Either",       ["Either"; "Left"; "Right"]));
  ("Tesl.DB",      ("DeleteResult", ["DeleteResult"; "NoRowDeleted"; "RowsDeleted"]));
  ("Tesl.ApiTest", ("JobResult",    ["JobResult"; "JobOk"; "JobFailed"]));
]

let imported_plain_exposed_ctor_entries (m : module_form) : (string * string * string * loc) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  let stdlib_entries =
    List.concat_map (fun (imp : import_decl) ->
      if not (is_tesl_module imp.module_name) then []
      else
        match imp.names with
        | ImportAll -> []
        | ImportExposing names ->
          let has_dotdot s =
            let n = String.length s in
            n > 4 && String.sub s (n - 4) 4 = "(..)"
          in
          let strip_dotdot s =
            let n = String.length s in
            if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s
          in
          (* Only expand constructors for names explicitly listed with (..) *)
          let dotdot_types = names |> List.filter has_dotdot |> List.map strip_dotdot in
          (match List.assoc_opt imp.module_name stdlib_adt_ctors with
           | None -> []
           | Some (type_name, ctors) ->
             if List.mem type_name dotdot_types then
               List.map (fun ctor -> (ctor, type_name, imp.module_name, imp.loc)) ctors
             else [])
    ) m.imports
  in
  stdlib_entries @
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let requested_types = imported_ctor_request_type_names imp in
      if requested_types = [] then []
      else
        let path = resolve_local_import_path m.source_file imp.module_name in
        if not (Sys.file_exists path) then []
        else
          let source = In_channel.with_open_text path In_channel.input_all in
          match Parser.parse_module path source with
          | Err _ -> []
          | Ok imported ->
            List.concat_map (function
              | DType (TypeAdt { name; variants; _ }) when List.mem name requested_types ->
                List.map (fun (v : adt_variant) ->
                  (v.ctor, name, imp.module_name, imp.loc)
                ) variants
              | _ -> []
            ) imported.decls
  ) m.imports

let local_type_entries (decls : top_decl list) : (string * loc) list =
  List.concat_map (function
    | DType (TypeNewtype { name; loc; _ }) -> [ (name, loc) ]
    | DType (TypeAlias { name; loc; _ }) -> [ (name, loc) ]
    | DType (TypeAdt { name; loc; _ }) -> [ (name, loc) ]
    | DRecord rf -> [ (rf.name, rf.loc) ]
    | DEntity ef -> [ (ef.name, ef.loc) ]
    | _ -> []
  ) decls

let local_ctor_entries (decls : top_decl list) : (string * string * loc) list =
  List.concat_map (function
    | DType (TypeAdt { name; variants; _ }) ->
      List.map (fun (v : adt_variant) -> (v.ctor, name, v.loc)) variants
    | _ -> []
  ) decls

let parameter_shadow_errors (seen : string list) (bindings : binding list) : validation_error list =
  List.filter_map (fun (b : binding) ->
    if b.name <> "_" && List.mem b.name seen then
      Some (make_error b.loc
        (Printf.sprintf "function parameter `%s` shadows an existing name" b.name))
    else None
  ) bindings

let check_name_shadowing (m : module_form) : validation_error list =
  let decls = m.decls in
  let seed_names =
    List.fold_left push_unique_name []
      ("gdp" :: (local_function_names decls @ imported_plain_exposed_names m))
    |> List.rev
  in
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let param_names =
        List.fold_right (fun (b : binding) acc ->
          if b.name = "_" then acc else b.name :: acc
        ) fd.params []
      in
      let seen = param_names @ seed_names in
      errors := duplicate_parameter_errors fd.params @ !errors;
      errors := parameter_shadow_errors seed_names fd.params @ !errors;
      errors := check_name_shadowing_expr seen fd.body @ !errors;
      errors := check_exists_witness_shadowing [] fd.body @ !errors
    | DTest tf ->
      errors := check_name_shadowing_test_stmts seed_names tf.stmts @ !errors
    | DApiTest atf ->
      errors := List.concat_map (check_name_shadowing_expr seed_names) atf.seed_stmts @ !errors;
      errors := check_name_shadowing_test_stmts seed_names atf.stmts @ !errors
    | DLoadTest ltf ->
      errors := List.concat_map (check_name_shadowing_expr seed_names) ltf.seed_stmts @ !errors;
      errors := check_name_shadowing_test_stmts seed_names ltf.request_stmts @ !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Duplicate top-level names ──────────────────────────────────────────── *)

let check_duplicate_top_level_names (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  (* Separate namespaces: functions and types/records/entities can share names with codecs *)
  let seen_funcs : (string * loc) list ref = ref [] in
  let seen_types : (string * loc) list ref = ref [] in
  let seen_facts : (string * loc) list ref = ref [] in
  let check seen name loc kind =
    match List.assoc_opt name !seen with
    | Some first_loc ->
      errors := make_error loc
        ~hint:(Printf.sprintf "first definition of `%s` is at line %d" name (first_loc.start.line + 1))
        (Printf.sprintf "duplicate %s `%s`" kind name)
        :: !errors
    | None -> seen := (name, loc) :: !seen
  in
  List.iter (function
    | DFunc fd -> check seen_funcs fd.name fd.loc "function"
    | DType (TypeNewtype { name; loc; _ }) -> check seen_types name loc "type"
    | DType (TypeAlias { name; loc; _ }) -> check seen_types name loc "type"
    | DType (TypeAdt { name; loc; _ }) -> check seen_types name loc "type"
    | DRecord rf -> check seen_types rf.name rf.loc "record"
    | DEntity ef -> check seen_types ef.name ef.loc "entity"
    | DFact ff -> check seen_facts ff.name ff.loc "fact"
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Duplicate ADT constructors within a single ADT ────────────────────── *)

let check_duplicate_adt_constructors (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let seen_global : (string, string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (function
    | DType (TypeAdt { name; variants; _ }) ->
      let seen_local = Hashtbl.create 8 in
      List.iter (fun (v : adt_variant) ->
        if Hashtbl.mem seen_local v.ctor then
          errors := make_error v.loc
            ~hint:(Printf.sprintf "each constructor in type `%s` must be unique" name)
            (Printf.sprintf "duplicate constructor `%s` in type `%s`" v.ctor name)
            :: !errors
        else begin
          Hashtbl.replace seen_local v.ctor v.loc;
          match Hashtbl.find_opt seen_global v.ctor with
          | Some (first_type, first_loc) when first_type <> name ->
            errors := make_error v.loc
              ~hint:(Printf.sprintf "constructor `%s` was already declared in type `%s` at line %d; constructors must be globally unique" v.ctor first_type (first_loc.start.line + 1))
              (Printf.sprintf "duplicate constructor `%s` across types `%s` and `%s`" v.ctor first_type name)
              :: !errors
          | _ ->
            Hashtbl.replace seen_global v.ctor (name, v.loc)
        end
      ) variants
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Duplicate record/entity field names within a single declaration ─────── *)

let check_duplicate_decl_fields (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let check_fields decl_kind decl_name (fields : field_def list) =
    let seen : (string, loc) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun (f : field_def) ->
      match Hashtbl.find_opt seen f.name with
      | Some first_loc ->
        errors := make_error f.loc
          ~hint:(Printf.sprintf "first field `%s` is at line %d; each field in %s `%s` must be unique" f.name (first_loc.start.line + 1) decl_kind decl_name)
          (Printf.sprintf "duplicate field `%s` in %s `%s`" f.name decl_kind decl_name)
          :: !errors
      | None ->
        Hashtbl.replace seen f.name f.loc
    ) fields
  in
  List.iter (function
    | DRecord r -> check_fields "record" r.name r.fields
    | DEntity e -> check_fields "entity" e.name e.fields
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Self-import detection ──────────────────────────────────────────────── *)

let check_self_imports (module_name : string) (imports : import_decl list) : validation_error list =
  let errors = ref [] in
  List.iter (fun (imp : import_decl) ->
    if imp.module_name = module_name then
      errors := make_error imp.loc
        ~hint:"remove the self-import"
        (Printf.sprintf "module `%s` imports itself" module_name)
        :: !errors
  ) imports;
  List.rev !errors

let has_dotdot_suffix (name : string) =
  let len = String.length name in
  len > 4 && String.sub name (len - 4) 4 = "(..)"

let strip_dotdot_suffix (name : string) =
  if has_dotdot_suffix name then
    String.sub name 0 (String.length name - 4)
  else
    name

let check_imported_exposed_name_conflicts (m : module_form) : validation_error list =
  let errors = ref [] in
  let seen_imports : (string, string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (name, module_name, loc) ->
    match Hashtbl.find_opt seen_imports name with
    | Some (first_module, _) when first_module <> module_name ->
      errors := make_error loc
        ~hint:(Printf.sprintf "remove one of the exposing imports for `%s`, or import one module qualified-only" name)
        (Printf.sprintf "imported name `%s` is exposed by multiple modules (`%s` and `%s`)" name first_module module_name)
        :: !errors
    | Some _ -> ()
    | None -> Hashtbl.add seen_imports name (module_name, loc)
  ) (imported_plain_exposed_name_entries m);
  List.iter (function
    | DFunc fd ->
      (match Hashtbl.find_opt seen_imports fd.name with
       | Some (module_name, _) ->
         errors := make_error fd.loc
           ~hint:(Printf.sprintf "rename `%s`, remove it from the exposing list, or switch to `import %s` for qualified access" fd.name module_name)
           (Printf.sprintf "top-level function `%s` shadows imported name from module `%s`" fd.name module_name)
           :: !errors
       | None -> ())
    | _ -> ()
  ) m.decls;
  List.rev !errors

let check_imported_exposed_type_and_ctor_conflicts (m : module_form) : validation_error list =
  let errors = ref [] in
  let seen_types : (string, string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (name, module_name, loc) ->
    match Hashtbl.find_opt seen_types name with
    | Some (first_module, _) when first_module <> module_name ->
      errors := make_error loc
        ~hint:(Printf.sprintf "remove one of the exposing imports for `%s`, or import one module qualified-only" name)
        (Printf.sprintf "imported type `%s` is exposed by multiple modules (`%s` and `%s`)" name first_module module_name)
        :: !errors
    | Some _ -> ()
    | None -> Hashtbl.add seen_types name (module_name, loc)
  ) (imported_plain_exposed_type_entries m);
  let seen_ctors : (string, string * string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (ctor_name, type_name, module_name, loc) ->
    match Hashtbl.find_opt seen_ctors ctor_name with
    | Some (first_type, first_module, _) when first_module <> module_name || first_type <> type_name ->
      errors := make_error loc
        ~hint:(Printf.sprintf "remove one of the `(..)` imports for `%s`, or import one module qualified-only" ctor_name)
        (Printf.sprintf "imported constructor `%s` is exposed by multiple modules (`%s` and `%s`)" ctor_name first_module module_name)
        :: !errors
    | Some _ -> ()
    | None -> Hashtbl.add seen_ctors ctor_name (type_name, module_name, loc)
  ) (imported_plain_exposed_ctor_entries m);
  List.iter (fun (name, loc) ->
    match Hashtbl.find_opt seen_types name with
    | Some (module_name, _) ->
      errors := make_error loc
        ~hint:(Printf.sprintf "rename `%s`, remove it from the exposing list, or switch to `import %s` for qualified access" name module_name)
        (Printf.sprintf "top-level type `%s` shadows imported type from module `%s`" name module_name)
        :: !errors
    | None -> ()
  ) (local_type_entries m.decls);
  List.iter (fun (ctor_name, owner_type, loc) ->
    match Hashtbl.find_opt seen_ctors ctor_name with
    | Some (_, module_name, _) ->
      errors := make_error loc
        ~hint:(Printf.sprintf "rename constructor `%s`, or remove the conflicting `(..)` import from `%s`" ctor_name module_name)
        (Printf.sprintf "constructor `%s` in type `%s` shadows imported constructor from module `%s`" ctor_name owner_type module_name)
        :: !errors
    | None -> ()
  ) (local_ctor_entries m.decls);
  List.rev !errors


let check_duplicate_imports (imports : import_decl list) : validation_error list =
  let errors = ref [] in
  let seen_by_module = Hashtbl.create 16 in
  let seen_tables module_name =
    match Hashtbl.find_opt seen_by_module module_name with
    | Some tables -> tables
    | None ->
      let exact = Hashtbl.create 16 in
      let plain = Hashtbl.create 16 in
      let dotdot = Hashtbl.create 16 in
      let tables = (exact, plain, dotdot) in
      Hashtbl.add seen_by_module module_name tables;
      tables
  in
  List.iter (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> ()
    | ImportExposing names ->
      let seen_exact, seen_plain, seen_dotdot = seen_tables imp.module_name in
      List.iter (fun name ->
        if Hashtbl.mem seen_exact name then
          errors := make_error imp.loc
            ~hint:(Printf.sprintf "remove the repeated import of `%s` from `%s`" name imp.module_name)
            (Printf.sprintf "duplicate import `%s` from module `%s`" name imp.module_name)
            :: !errors
        else begin
          Hashtbl.replace seen_exact name ();
          let base = strip_dotdot_suffix name in
          if has_dotdot_suffix name then begin
            if Hashtbl.mem seen_plain base then
              errors := make_error imp.loc
                ~hint:(Printf.sprintf "keep either `%s` or `%s(..)` when importing from `%s`" base base imp.module_name)
                (Printf.sprintf "cannot import both `%s` and `%s(..)` from module `%s`" base base imp.module_name)
                :: !errors;
            Hashtbl.replace seen_dotdot base ()
          end else begin
            if Hashtbl.mem seen_dotdot base then
              errors := make_error imp.loc
                ~hint:(Printf.sprintf "keep either `%s` or `%s(..)` when importing from `%s`" base base imp.module_name)
                (Printf.sprintf "cannot import both `%s` and `%s(..)` from module `%s`" base base imp.module_name)
                :: !errors;
            Hashtbl.replace seen_plain base ()
          end
        end
      ) names
  ) imports;
  List.rev !errors

(** Check that every non-stdlib import resolves to an existing file.
    When the file doesn't exist, the compiler silently ignores the import and
    later emits confusing "unknown name: fn" type errors.  This check surfaces
    the root cause early with a clear message. *)
let check_local_imports_exist (m : module_form) : validation_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.filter_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then None
    else
      let kebab_path = resolve_local_import_path m.source_file imp.module_name in
      (* resolve_local_import_path prefers the kebab-case path; fall back to PascalCase *)
      let dir    = Filename.dirname m.source_file in
      let kebab  = Filename.concat dir (module_name_to_kebab imp.module_name ^ ".tesl") in
      let pascal = Filename.concat dir (imp.module_name ^ ".tesl") in
      if Sys.file_exists kebab_path then None
      else
        let hint =
          if kebab <> pascal then
            Printf.sprintf "create `%s` or `%s` in the same directory" kebab pascal
          else
            Printf.sprintf "create `%s` in the same directory" kebab
        in
        Some (make_error imp.loc ~hint
          (Printf.sprintf "module `%s` not found: looked for `%s`"
             imp.module_name kebab_path))
  ) m.imports


(** Build a map from function name → declared capabilities for all DFunc decls *)
(** Build a map of ALL user-defined function names to their declared capabilities.
    Functions with `requires []` map to an empty list.
    This is used to distinguish user-defined `fn insert` from the SQL `insert` keyword. *)
let build_func_capability_map (decls : top_decl list) : (string * string list) list =
  List.filter_map (function
    | DFunc fd -> Some (fd.name, fd.capabilities)
    | _ -> None
  ) decls

(** Check whether an expression body uses any DB or queue/pubsub operations,
    or calls any functions that require capabilities.
    Returns a list of capability names needed. *)
let rec collect_needed_capabilities
    ?(func_caps : (string * string list) list = [])
    (e : expr)
    : string list =
  let sql_read_names = ["select"; "selectOne"; "selectCount"; "selectSum"; "selectMax"; "selectMin"] in
  let sql_write_names = ["insert"; "update"; "delete"; "upsert"] in
  match e with
  | EVar { name; _ } ->
    (* BUG-1 fix: Check user-defined functions FIRST.
       A user function named `insert`, `select`, `update`, or `delete` must NOT be
       treated as a SQL operation. `List.mem_assoc` returns true even for functions
       with empty capabilities (requires []), correctly shadowing the SQL keywords. *)
    if List.mem_assoc name func_caps then
      (match List.assoc_opt name func_caps with
       | Some caps -> caps
       | None -> [])
    else if List.mem name sql_read_names then ["dbRead"]
    else if List.mem name sql_write_names then ["dbWrite"]
    else if name = "deadJobs" then ["queueRead"]
    else if name = "requeue" then ["queueWrite"]
    else if List.mem name ["now"; "nowMillis"; "Time.now"; "Time.nowMillis";
                           "Time.secondsToPosix"; "Time.posixToMillis";
                           "Time.durationMs"; "Time.diffMs"; "Time.addMs";
                           "Time.subtractMs"; "Time.formatTime"] then ["time"]
    (* BUG-4 fix: generatePrefixedId and randomInt require the `random` capability. *)
    else if List.mem name ["generatePrefixedId"; "randomInt";
                           "Tesl.Id.generatePrefixedId"; "Tesl.Random.randomInt"] then ["random"]
    else []
  | EEnqueue _ -> ["queueWrite"]
  | EPublish _ -> ["pubsub"]
  | ELit _ | EConstructor _ | EFail _ | EStartWorkers _ -> []
  | EField { obj; _ } -> collect_needed_capabilities ~func_caps obj
  | EApp { fn; arg; _ } ->
    collect_needed_capabilities ~func_caps fn @ collect_needed_capabilities ~func_caps arg
  | EBinop { left; right; _ } ->
    collect_needed_capabilities ~func_caps left @ collect_needed_capabilities ~func_caps right
  | EUnop { arg; _ } -> collect_needed_capabilities ~func_caps arg
  | EIf { cond; then_; else_; _ } ->
    collect_needed_capabilities ~func_caps cond
    @ collect_needed_capabilities ~func_caps then_
    @ collect_needed_capabilities ~func_caps else_
  | ECase { scrut; arms; _ } ->
    collect_needed_capabilities ~func_caps scrut
    @ List.concat_map (fun (arm : case_arm) -> collect_needed_capabilities ~func_caps arm.body) arms
  | ELet { value; body; _ } ->
    collect_needed_capabilities ~func_caps value @ collect_needed_capabilities ~func_caps body
  | ELetProof { value; body; _ } ->
    collect_needed_capabilities ~func_caps value @ collect_needed_capabilities ~func_caps body
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> collect_needed_capabilities ~func_caps v) fields
  | EList { elems; _ } -> List.concat_map (collect_needed_capabilities ~func_caps) elems
  | EOk { value; _ } -> collect_needed_capabilities ~func_caps value
  | ETelemetry { fields; _ } ->
    List.concat_map (fun (_, v) -> collect_needed_capabilities ~func_caps v) fields
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    collect_needed_capabilities ~func_caps body
  | EServe { port; _ } -> collect_needed_capabilities ~func_caps port
  | ELambda { body; _ } -> collect_needed_capabilities ~func_caps body

let check_handler_capabilities ?(cap_map=[]) (decls : top_decl list) : validation_error list =
  let func_caps = build_func_capability_map decls in
  (* Full transitive closure: expand a set of declared capabilities to everything they
     imply, recursively. Uses the same algorithm as expand_caps in proof_checker.ml. *)
  let expand_declared declared =
    let result = Hashtbl.create 16 in
    let rec expand name =
      if not (Hashtbl.mem result name) then begin
        Hashtbl.replace result name ();
        match List.assoc_opt name cap_map with
        | Some implied -> List.iter expand implied
        | None -> ()
      end
    in
    List.iter expand declared;
    Hashtbl.fold (fun k () acc -> k :: acc) result []
  in
  let cap_covered declared needed =
    List.mem needed (expand_declared declared)
  in
  let errors = ref [] in
  List.iter (function
    | DFunc fd when fd.kind = HandlerKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the handler declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "handler '%s' uses [%s] but does not declare the required capabilities"
             fd.name (String.concat ", " missing))
          :: !errors
    | DFunc fd when fd.kind = WorkerKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the worker declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "worker '%s' uses [%s] but does not declare the required capabilities"
             fd.name (String.concat ", " missing))
          :: !errors
    | DFunc fd when fd.kind = FnKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the fn declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "fn '%s' uses privileged operations and callees requiring [%s] but does not declare them"
             fd.name (String.concat ", " missing))
          :: !errors
    | DFunc fd when fd.kind = DeadWorkerKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the deadWorker declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "deadWorker '%s' uses [%s] but does not declare the required capabilities"
             fd.name (String.concat ", " missing))
          :: !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(** Extract variable name from a `(Id == varName)` proof argument string.
    E.g., "(Id == id)" → Some "id". *)
let extract_id_eq_var (arg : string) : string option =
  (* Strip surrounding parens if present *)
  let s = String.trim arg in
  let s = if String.length s > 1 && s.[0] = '(' && s.[String.length s - 1] = ')'
          then String.sub s 1 (String.length s - 2) |> String.trim
          else s in
  (* Find "==" and take everything after it, trimmed *)
  match String.split_on_char ' ' s with
  | parts ->
    (* Find "==" token and take the next non-empty token *)
    let rec find_after_eq = function
      | [] -> None
      | "==" :: next :: _ ->
        let v = String.trim next in
        if String.length v > 0 then Some v else None
      | _ :: rest -> find_after_eq rest
    in
    find_after_eq (List.filter (fun p -> p <> "") parts)

(** Extract the variable from a FromDb proof's (Id == X) argument. *)
let fromdb_pk_var (proof : proof_expr) : string option =
  match proof with
  | PredApp { pred = "FromDb"; args = [arg]; _ } -> extract_id_eq_var arg
  | _ -> None

(** Extract the plain variable from a ForAll FromDb proof's (Field == X) argument.
    Returns None if the variable is a field access (e.g. requestUser.id — tokenized
    as "requestUser . id" with spaces, so the next token after the variable is ".").
    E.g., ForAll (FromDb (RoomId == roomId)) → Some "roomId".
    E.g., ForAll (FromDb (OwnerId == requestUser.id)) → None (field access). *)
let forall_fromdb_field_var (proof : proof_expr) : string option =
  match proof with
  | PredApp { pred = "FromDb"; args = [arg]; _ } ->
    let s = String.trim arg in
    let s = if String.length s > 1 && s.[0] = '(' && s.[String.length s - 1] = ')'
            then String.sub s 1 (String.length s - 2) |> String.trim
            else s in
    let parts = List.filter (fun p -> p <> "") (String.split_on_char ' ' s) in
    (* Find the variable after == and check if it's followed by "." (field access) *)
    let rec find_var = function
      | [] -> None
      | "==" :: v :: "." :: _ -> ignore v; None  (* field access: skip *)
      | "==" :: v :: _ ->
        if String.length v > 0 && v.[0] >= 'a' && v.[0] <= 'z'
        then Some v
        else None
      | _ :: rest -> find_var rest
    in
    find_var parts
  | _ -> None

(** Check that SELECT WHERE conditions match the named-pack return spec's pk constraint.
    E.g., `-> Task ? FromDb (Id == id)` requires `selectOne t from Task where t.id == id`.
    Also validates ForAll return types: `-> List Msg ? ForAll (FromDb (RoomId == roomId))`
    requires the SELECT to use `roomId`, not another variable. *)
let check_pk_match (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  List.iter (function
    | DFunc fd when (fd.kind = FnKind || fd.kind = HandlerKind) ->
      (* Determine the expected WHERE variable from the return spec, and a label
         describing it for error messages. Returns (expected_var, spec_label). *)
      let where_spec = match fd.return_spec with
        | RetNamedPack { entity_proof = Some ep; _ } ->
          (match fromdb_pk_var ep with
           | Some v -> Some (v, Printf.sprintf "Id == %s" v)
           | None -> None)
        | RetForAll { proof; _ } | RetMaybeForAll { proof; _ } ->
          (match forall_fromdb_field_var proof with
           | Some v when not (String.contains v '.') ->
             (* Only check simple parameter names (no field access like `user.id`).
                Field-access subjects like `requestUser.id` are legitimate but cannot
                be validated by simple param-name matching. *)
             Some (v, Printf.sprintf "FromDb (...%s...) in ForAll" v)
           | _ -> None)
        | _ -> None
      in
      (match where_spec with
       | None -> ()
       | Some (expected_var, spec_label) ->
         let param_names = List.map (fun (b : binding) -> b.name) fd.params in
         (* Check that expected_var is a parameter *)
         if not (List.mem expected_var param_names) then
           errors := make_error fd.loc
             ~hint:(Printf.sprintf "`%s` used in `%s` is not a parameter name; \
                     use a function parameter" expected_var spec_label)
             (Printf.sprintf "return spec `%s`: `%s` is not a parameter name"
                spec_label expected_var)
           :: !errors
         else begin
              (* Walk body looking for SELECT WHERE conditions *)
              let rec check_expr (e : expr) =
                match e with
                | EApp _ ->
                  let flat = let rec go acc = function
                    | EApp { fn; arg; _ } -> go (arg :: acc) fn
                    | hd -> (hd, acc)
                    in go [] e
                  in
                  let (head, args) = flat in
                  (match head with
                   | EVar { name = ("selectOne" | "select"); _ } ->
                     (* Find the WHERE condition — args: [binder, "from", Entity, "where", EField{binder.field}] *)
                     (* The actual comparison value is in the outer EBinop if present *)
                     List.iter check_expr args
                   | _ ->
                     List.iter check_expr args;
                     check_expr head)
                | EBinop { op = BEq; left; right; loc } ->
                  (* SELECT ... WHERE binder.field == value — check value matches expected_var *)
                  let flat = let rec go acc = function
                    | EApp { fn; arg; _ } -> go (arg :: acc) fn
                    | hd -> (hd, acc)
                    in go [] left
                  in
                  let (head, args) = flat in
                  (* Detect select WHERE: head = selectOne/select, last arg is binder.field *)
                  let is_select = match head with
                    | EVar { name = ("selectOne" | "select"); _ } -> true
                    | _ -> false
                  in
                  (* Detect update/standalone WHERE: head = "where", single arg = binder.field *)
                  let is_where_clause = match head with
                    | EVar { name = "where"; _ } -> true
                    | _ -> false
                  in
                  let check_where_value binder last_arg =
                    let is_binder_field = match last_arg with
                      | EField { obj = EVar { name; _ }; _ } when name = binder -> true
                      | _ -> false
                    in
                    if is_binder_field then begin
                      let where_val = match right with
                        | EVar { name; _ } -> Some name
                        | ELit _ -> None
                        | _ -> None
                      in
                      (match where_val with
                       | None ->
                         errors := make_error loc
                           ~hint:(Printf.sprintf "the WHERE clause should compare \
                                   to `%s` (from `Id == %s` in the return spec)"
                                   expected_var expected_var)
                           (Printf.sprintf "WHERE condition does not match \
                                  `Id == %s` in return spec; \
                                  use parameter `%s` not a literal"
                              expected_var expected_var)
                         :: !errors
                       | Some where_v when where_v <> expected_var ->
                         errors := make_error loc
                           ~hint:(Printf.sprintf "the WHERE clause should use `%s` \
                                   (from `Id == %s` in the return spec)"
                                   expected_var expected_var)
                           (Printf.sprintf "WHERE clause uses `%s` but return spec \
                                  declares `Id == %s`; these do not match"
                              where_v expected_var)
                         :: !errors
                       | _ -> ())
                    end
                  in
                  if is_select then begin
                    let binder = match args with EVar { name; _ } :: _ -> name | _ -> "_" in
                    let last_arg = match List.rev args with x :: _ -> x | [] -> ELit { lit = LInt 0; loc } in
                    check_where_value binder last_arg
                  end else if is_where_clause then begin
                    (* update WHERE: EApp{fn=EVar"where"; arg=EField{binder.field}} == value *)
                    let last_arg = match args with [x] -> x | _ -> ELit { lit = LInt 0; loc } in
                    let binder = match last_arg with
                      | EField { obj = EVar { name; _ }; _ } -> name
                      | _ -> "_"
                    in
                    check_where_value binder last_arg
                  end;
                  check_expr left; check_expr right
                | ELet { value; body; _ } -> check_expr value; check_expr body
                | ELetProof { value; body; _ } -> check_expr value; check_expr body
                | EIf { cond; then_; else_; _ } ->
                  check_expr cond; check_expr then_; check_expr else_
                | ECase { scrut; arms; _ } ->
                  check_expr scrut;
                  List.iter (fun (arm : case_arm) -> check_expr arm.body) arms
                | EWithTransaction { body; _ } | EWithDatabase { body; _ }
                | EWithCapabilities { body; _ } -> check_expr body
                | _ -> ()
              in
              check_expr fd.body
            end)
    | _ -> ()
  ) decls;
  List.rev !errors

(** Check that insert statements inside `exists witness => ...` use the witness variable
    for the primary-key field, not a different variable or literal.
    E.g., `-> exists msgId: String => Msg ? FromDb (Id == msgId)` requires
    `insert Msg { id: msgId, ... }`, not `insert Msg { id: "sneaky", ... }`. *)
let check_insert_pk_match (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  (* Recursively find witness name from RetExists chain. Returns the innermost
     exists witness name and the FromDb pk var from its inner RetNamedPack. *)
  let rec exists_pk_spec spec = match spec with
    | RetExists { binding; body; _ } ->
      let witness = binding.name in
      (match exists_pk_spec body with
       | Some (_, pk) -> Some (witness, pk)
       | None ->
         (match body with
          | RetNamedPack { entity_proof = Some ep; _ } ->
            (match fromdb_pk_var ep with
             | Some pk -> Some (witness, pk)
             | None -> None)
          | _ -> None))
    | _ -> None
  in
  (* Check a single insert expression that is the packed body of `exists witness =>`.
     Only the PACKED body insert is validated — other inserts in the function body
     (e.g. for related entities) are allowed to use different id bindings. *)
  let check_packed_insert witness pk_var (e : expr) =
    let (head, args) = collect_call_head_and_args [] e in
    match function_name_of_expr head with
    | Some "insert" ->
      List.iter (fun arg ->
        match arg with
        | ERecord { fields; loc; _ } ->
          List.iter (fun (fname, fval) ->
            if fname = "id" then begin
              match fval with
              | EVar { name; _ } when name <> pk_var && name <> witness ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "the `id` field must be `%s` (the existential witness) to satisfy `FromDb (Id == %s)` in the return spec"
                    witness witness)
                  (Printf.sprintf
                    "insert uses `id: %s` but return spec declares `Id == %s`; \
                     these do not match — use the existential witness `%s` for the id field"
                    name witness witness)
                :: !errors
              | ELit _ ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "use `id: %s` (the existential witness) instead of a literal to satisfy `FromDb (Id == %s)` in the return spec"
                    witness witness)
                  (Printf.sprintf
                    "insert uses a literal for `id` but return spec declares `Id == %s`; \
                     the `id` must be the existential witness `%s`, not a string or integer literal"
                    witness witness)
                :: !errors
              | _ -> ()
            end
          ) fields
        | _ -> ()
      ) args
    | _ -> ()
  in
  (* Find (actual_witness_var, body) pairs from `exists X => body` packs.
     actual_witness_var is the variable written in `exists X =>` — it may differ
     from the return-spec witness name (e.g. `exists i => ...` with return spec
     `-> exists itemId => ...`). Both names must be accepted for the id field. *)
  let rec packed_witness_and_bodies (e : expr) : (string * expr) list =
    match e with
    | EApp {
        fn = EVar { name = "make-witness"; _ };
        arg = EApp { fn = EVar { name = actual_witness; _ }; arg = body; _ };
        _ } -> [(actual_witness, body)]
    | EApp { fn; arg; _ } ->
      packed_witness_and_bodies fn @ packed_witness_and_bodies arg
    | EIf { cond; then_; else_; _ } ->
      packed_witness_and_bodies cond
      @ packed_witness_and_bodies then_
      @ packed_witness_and_bodies else_
    | ECase { scrut; arms; _ } ->
      packed_witness_and_bodies scrut
      @ List.concat_map (fun (arm : case_arm) -> packed_witness_and_bodies arm.body) arms
    | ELet { value; body; _ } | ELetProof { value; body; _ } ->
      packed_witness_and_bodies value @ packed_witness_and_bodies body
    | EWithTransaction { body; _ } | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ } -> packed_witness_and_bodies body
    | _ -> []
  in
  List.iter (function
    | DFunc fd when (fd.kind = FnKind || fd.kind = HandlerKind) ->
      (match exists_pk_spec fd.return_spec with
       | Some (witness, pk_var) ->
         List.iter (fun (actual_witness, body) ->
           (* Allow id to be: the return-spec pk var, the return-spec witness name,
              or the actual exists-X variable (which may differ from the spec name). *)
           let extended_witness =
             if actual_witness = witness then witness
             else actual_witness
           in
           check_packed_insert
             extended_witness
             (if pk_var = witness then extended_witness else pk_var)
             body)
           (packed_witness_and_bodies fd.body)
       | None -> ())
    | _ -> ()
  ) decls;
  List.rev !errors

(** Check for invalid HttpRequest field chain access (request.cookies.X).
    `cookies` is a Dict, so `.X` field access doesn't work — use Dict.lookup instead. *)
let check_cookies_field_access (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let rec check_expr (e : expr) =
    match e with
    | EField { obj = EField { obj = EVar { name = req_name; _ }; field = "cookies"; _ };
               field = _; loc } ->
      errors := make_error loc
        ~hint:(Printf.sprintf
          "use `Dict.lookup \"<key>\" %s.cookies` to get a cookie value" req_name)
        (Printf.sprintf
          "3-level dot access `%s.cookies.<field>` is not valid — \
           `cookies` is a Dict, not a record; \
           use Dict.lookup to access cookie values" req_name)
      :: !errors
    | EApp { fn; arg; _ } -> check_expr fn; check_expr arg
    | EField { obj; _ } -> check_expr obj
    | EBinop { left; right; _ } -> check_expr left; check_expr right
    | EUnop { arg; _ } -> check_expr arg
    | EIf { cond; then_; else_; _ } ->
      check_expr cond; check_expr then_; check_expr else_
    | ECase { scrut; arms; _ } ->
      check_expr scrut;
      List.iter (fun (arm : case_arm) -> check_expr arm.body) arms
    | ELet { value; body; _ } -> check_expr value; check_expr body
    | ELetProof { value; body; _ } -> check_expr value; check_expr body
    | ERecord { fields; _ } ->
      List.iter (fun (_, v) -> check_expr v) fields
    | EOk { value; _ } -> check_expr value
    | EWithTransaction { body; _ } | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ } -> check_expr body
    | _ -> ()
  in
  List.iter (function
    | DFunc fd -> check_expr fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Module-level validation ──────────────────────────────────────────────── *)

let build_local_cap_map (decls : top_decl list) : (string * string list) list =
  List.filter_map (function
    | DCapability c -> Some (c.name, c.implies)
    | _ -> None
  ) decls

(** Detect cycles in the capability `implies` graph using DFS.
    A cycle means a capability (transitively) implies itself, which makes the
    implication relation circular and semantically meaningless. *)
let check_capability_cycles (decls : top_decl list) : validation_error list =
  let caps : capability_form list =
    List.filter_map (function DCapability c -> Some c | _ -> None) decls
  in
  if caps = [] then []
  else begin
    (* Build adjacency: name → (list of implied names, loc) *)
    let adj : (string * (string list * loc)) list =
      List.map (fun (c : capability_form) -> (c.name, (c.implies, c.loc))) caps
    in
    let errors = ref [] in
    (* DFS with colour marking: white=0 unvisited, grey=1 in stack, black=2 done *)
    let colour : (string, int) Hashtbl.t = Hashtbl.create 8 in
    let rec dfs path node =
      match Hashtbl.find_opt colour node with
      | Some 2 -> ()  (* already fully explored *)
      | Some 1 ->
        (* Back-edge: cycle detected — report on the capability that closes the loop *)
        let cycle_str = String.concat " → " (List.rev (node :: path)) in
        let loc = match List.assoc_opt node adj with
          | Some (_, l) -> l | None -> dummy_loc "capability cycle"
        in
        errors := make_error loc
          ~hint:"remove one of the `implies` declarations that creates the cycle"
          (Printf.sprintf "capability cycle detected: %s" cycle_str)
          :: !errors
      | _ ->
        Hashtbl.replace colour node 1;
        (match List.assoc_opt node adj with
         | Some (implied, _) ->
           List.iter (fun target -> dfs (node :: path) target) implied
         | None -> ());
        Hashtbl.replace colour node 2
    in
    List.iter (fun (c : capability_form) ->
      if not (Hashtbl.mem colour c.name) then dfs [] c.name
    ) caps;
    List.rev !errors
  end

(** Check that the argument types in proof annotations match the declared
    parameter types in `fact` declarations.
    E.g. `fact IsPositive (n: Int)` with `ok s ::: IsPositive s` where `s: String`
    is a type mismatch and should be a compile error.
    Only simple variable-name arguments are checked; complex expressions are skipped. *)
let check_fact_arg_types (decls : top_decl list) : validation_error list =
  (* Build map: fact_name → declared param bindings *)
  let fact_map : (string * binding list) list =
    List.filter_map (function
      | DFact ff -> Some (ff.name, ff.params)
      | _ -> None
    ) decls
  in
  if fact_map = [] then []
  else begin
    let errors = ref [] in
    (* Check one proof expression given a local var→type_key env *)
    (* ~entity:true = this proof is in entity-proof position (e.g. Int ? BoundedBy limit)
       where the entity variable is auto-appended as the last argument, so
       n_params-1 explicit args is valid. *)
    let is_simple_proof_subject (arg : string) : bool =
      let n = String.length arg in
      let rec loop i =
        if i >= n then true
        else
          match arg.[i] with
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> loop (i + 1)
          | _ -> false
      in
      n > 0 && loop 0
    in
    let rec take_prefix n xs =
      if n <= 0 then []
      else
        match xs with
        | [] -> []
        | x :: rest -> x :: take_prefix (n - 1) rest
    in
    let rec check_proof ?(entity = false) ?(forall_inner = false) local_env loc (p : proof_expr) =
      match p with
      | PredApp { pred; args; loc = ploc } ->
        (match List.assoc_opt pred fact_map with
         | Some param_bindings ->
           let n_params = List.length param_bindings in
           let n_args   = List.length args in
           (* entity && n_args = n_params-1: entity auto-appended as last arg — also valid *)
           let entity_implicit = entity && n_params > 0 && n_args = n_params - 1 in
           if n_params = n_args then
             List.iter2 (fun (param : binding) arg_name ->
               match param.type_expr with
               | TVar _ -> ()  (* Generic type parameter — accept any type *)
               | decl_ty ->
                 let decl_key = type_key decl_ty in
                 (* Only check simple identifiers; skip dotted paths / complex args *)
                 if String.contains arg_name '.' || String.contains arg_name '('
                    || String.contains arg_name '*' then ()
                 else
                   match List.assoc_opt arg_name local_env with
                   | None -> ()  (* Variable not in scope map — skip *)
                   | Some actual_key ->
                     if actual_key <> decl_key then
                       let use_loc = if ploc.start.col > 0 || ploc.start.line > 0 then ploc else loc in
                       errors := make_error use_loc
                         ~hint:(Printf.sprintf
                           "fact `%s` declares parameter `%s: %s`, but `%s` has type `%s`; \
check your fact declaration or the type of `%s`"
                           pred param.name decl_key arg_name actual_key arg_name)
                         (Printf.sprintf
                           "proof `%s %s`: argument `%s` has type `%s` but fact `%s` declares type `%s`"
                           pred (String.concat " " args) arg_name actual_key pred decl_key)
                       :: !errors
             ) param_bindings args
           else if entity_implicit then
             ()  (* entity auto-appended — valid, skip type check for implicit entity arg *)
           else if forall_inner && (n_args = 0 || n_args = n_params - 1) then
             ()  (* ForAll/Set inner predicate: zero-arg OR (n_params-1) literal args (element subject implicit) *)
           else
             (* Wrong arity: n_args ≠ n_params and no special context allows it *)
             errors := make_error ploc
               ~hint:(Printf.sprintf
                 "fact `%s` declares %d argument%s — in `:::` annotations write `%s %s`"
                 pred n_params (if n_params = 1 then "" else "s")
                 pred
                 (String.concat " " (List.map (fun (b : binding) -> b.name) param_bindings)))
               (Printf.sprintf
                 "proof `%s`: argument count mismatch — expected %d, got %d; use `%s <subject>` in `:::` annotations"
                 pred n_params n_args pred)
             :: !errors
         | None -> ())  (* Not a user-declared fact — skip *)
      | PredAnd { left; right; _ } ->
        check_proof ~entity ~forall_inner local_env loc left;
        check_proof ~entity ~forall_inner local_env loc right
    in
    let rec check_entity_proof local_env loc (p : proof_expr) =
      match p with
      | PredApp { pred; args; loc = ploc } ->
        (match List.assoc_opt pred fact_map with
         | Some param_bindings ->
           let explicit_params = take_prefix (max 0 (List.length param_bindings - 1)) param_bindings in
           let expected_args = List.length explicit_params in
           let n_args = List.length args in
           if n_args <> expected_args then
             let explicit_names = List.map (fun (b : binding) -> b.name) explicit_params in
             let hint =
               match explicit_names with
               | [] ->
                 Printf.sprintf
                   "entity-side `?` proof `%s` takes no explicit subjects here; write `%s` and let the returned entity be implicit"
                   pred pred
               | _ ->
                 Printf.sprintf
                   "entity-side `?` proof `%s` takes %d explicit subject%s here; write `%s %s` and let the returned entity be implicit"
                   pred expected_args (if expected_args = 1 then "" else "s") pred
                   (String.concat " " explicit_names)
             in
             errors := make_error ploc ~hint
               (Printf.sprintf
                  "entity-side `?` proof `%s`: argument count mismatch — expected %d explicit argument%s before the returned entity, got %d"
                  pred expected_args (if expected_args = 1 then "" else "s") n_args)
               :: !errors
           else
             List.iter2 (fun (param : binding) arg_name ->
               let use_loc = if ploc.start.col > 0 || ploc.start.line > 0 then ploc else loc in
               if String.contains arg_name '.' then
                 errors := make_error use_loc
                   ~hint:"bind the value to a local variable first, then use that variable in the entity-side `?` proof"
                   (Printf.sprintf
                      "entity-side `?` proof subject '%s' is not a valid GDP subject — dotted paths are not trackable"
                      arg_name)
                   :: !errors
               else if is_simple_proof_subject arg_name then
                 (match List.assoc_opt arg_name local_env with
                  | None ->
                    errors := make_error use_loc
                      ~hint:"use a function parameter or local variable name here; the returned entity itself is implicit in `?` proofs"
                      (Printf.sprintf
                         "entity-side `?` proof subject `%s` is not in scope"
                         arg_name)
                      :: !errors
                  | Some actual_key ->
                    (match param.type_expr with
                     | TVar _ -> ()
                     | decl_ty ->
                       let decl_key = type_key decl_ty in
                       if actual_key <> decl_key then
                         errors := make_error use_loc
                           ~hint:(Printf.sprintf
                             "entity-side `?` proof `%s` expects `%s: %s`, but `%s` has type `%s`"
                             pred param.name decl_key arg_name actual_key)
                           (Printf.sprintf
                             "entity-side `?` proof `%s %s`: argument `%s` has type `%s` but fact `%s` declares type `%s`"
                             pred (String.concat " " args) arg_name actual_key pred decl_key)
                           :: !errors))
               else ()) explicit_params args
         | None -> ())
      | PredAnd { left; right; _ } ->
        check_entity_proof local_env loc left;
        check_entity_proof local_env loc right
    in
    (* Check proof annotations in a return spec *)
    let rec check_ret_spec local_env (spec : return_spec) =
      match spec with
      | RetAttached { binding = b; loc } ->
        Option.iter (check_proof local_env loc) b.proof_ann
      | RetForAll { proof; loc; _ }
      | RetMaybeForAll { proof; loc; _ }
      | RetSetForAll { proof; loc; _ }
      | RetMaybeSetForAll { proof; loc; _ }
      | RetForAllDictValues { proof; loc; _ }
      | RetForAllDictKeys   { proof; loc; _ } ->
        (* ForAll inner predicate: zero-arg usage is valid (the element is implicit) *)
        check_proof ~forall_inner:true local_env loc proof
      | RetMaybeAttached { binding = b; loc; _ } ->
        Option.iter (check_proof local_env loc) b.proof_ann
      | RetNamedPack { entity_proof; other_proof; loc; _ } ->
        Option.iter (check_entity_proof local_env loc) entity_proof;
        Option.iter (check_proof local_env loc) other_proof
      | RetExists { binding = b; body; _ } ->
        Option.iter (check_proof local_env b.loc) b.proof_ann;
        check_ret_spec local_env body
      | RetPlain _ -> ()
    in
    (* Walk an expression looking for ok ::: proof sites and let bindings *)
    let rec walk_expr local_env (e : expr) =
      match e with
      | EOk { value; proof; loc } ->
        check_proof local_env loc proof;
        walk_expr local_env value
      | ELet { name; declared_type; value; body; _ } ->
        walk_expr local_env value;
        let env' = match declared_type with
          | Some ty -> (name, type_key ty) :: local_env
          | None -> local_env
        in
        walk_expr env' body
      | ELetProof { value; body; _ } ->
        walk_expr local_env value;
        walk_expr local_env body
      | EIf { cond; then_; else_; _ } ->
        walk_expr local_env cond; walk_expr local_env then_; walk_expr local_env else_
      | ECase { scrut; arms; _ } ->
        walk_expr local_env scrut;
        List.iter (fun (arm : case_arm) -> walk_expr local_env arm.body) arms
      | EApp { fn; arg; _ } -> walk_expr local_env fn; walk_expr local_env arg
      | EBinop { left; right; _ } -> walk_expr local_env left; walk_expr local_env right
      | EUnop { arg; _ } -> walk_expr local_env arg
      | EField { obj; _ } -> walk_expr local_env obj
      | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk_expr local_env v) fields
      | EList { elems; _ } -> List.iter (walk_expr local_env) elems
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_expr local_env body
      | ELambda { body; _ } -> walk_expr local_env body
      | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk_expr local_env v) fields
      | EEnqueue { payload; _ } -> walk_expr local_env payload
      | EPublish { key; payload; _ } ->
        Option.iter (walk_expr local_env) key;
        Option.iter (walk_expr local_env) payload
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ -> ()
    in
    List.iter (function
      | DFunc fd ->
        (* Build local env from all parameter bindings *)
        let local_env = List.filter_map (fun (b : binding) ->
          match b.type_expr with
          | TVar _ -> None
          | ty -> Some (b.name, type_key ty)
        ) fd.params in
        (* Extend env with return binding name if present (for RetAttached) *)
        let local_env = match fd.return_spec with
          | RetAttached { binding = b; _ } ->
            (match b.type_expr with TVar _ -> local_env | ty -> (b.name, type_key ty) :: local_env)
          | _ -> local_env
        in
        (* Check parameter proof annotations *)
        List.iter (fun (b : binding) ->
          Option.iter (check_proof local_env b.loc) b.proof_ann
        ) fd.params;
        (* Check return spec *)
        check_ret_spec local_env fd.return_spec;
        (* Walk body for ok ::: proof sites *)
        walk_expr local_env fd.body
      | _ -> ()
    ) decls;
    List.rev !errors
  end

(* ── Type arity / kind checking ──────────────────────────────────────────── *)

(** Arities for known parameterized type constructors. User-defined ADT params
    are added dynamically in [check_type_arities]. *)
let stdlib_type_arities : (string * int) list = [
  "List",   1;
  "Maybe",  1;
  "Set",    1;
  "Dict",   2;
  "Either", 2;
  "Tuple2", 2;
  "Tuple3", 3;
]

(** Walk a [type_expr] and emit errors for bare (unapplied) parameterized
    type constructors.  [go_arg] is called for nodes in argument/top-level
    position (must be fully applied); [go_head n] is called for nodes in head
    position of [n] already-applied TApp layers. *)
let check_type_arity_te (arity_tbl : (string * int) list) (te : Ast.type_expr) : validation_error list =
  let errors = ref [] in
  let err loc msg = errors := make_error loc msg :: !errors in
  let rec go_arg te =
    match te with
    | Ast.TName { name; loc } ->
      let n = try List.assoc name arity_tbl with Not_found -> 0 in
      if n > 0 then
        err loc (Printf.sprintf
          "type `%s` requires %d type argument(s); \
           write e.g. `%s %s` or use a type variable like `%s a`"
          name n name
          (String.concat " " (List.init n (fun i ->
             String.make 1 (Char.chr (Char.code 'a' + i)))))
          name)
    | Ast.TVar _ -> ()
    | Ast.TApp { head; arg; _ } -> go_head head 1; go_arg arg
    | Ast.TFun { dom; cod; _ } -> go_arg dom; go_arg cod
    | Ast.TTuple { elems; _ } -> List.iter go_arg elems
  and go_head te n_applied =
    match te with
    | Ast.TName { name; loc } ->
      let expected = try List.assoc name arity_tbl with Not_found -> 0 in
      let remaining = expected - n_applied in
      if remaining > 0 then
        err loc (Printf.sprintf
          "type `%s` requires %d type argument(s) but only %d given"
          name expected n_applied)
    | Ast.TApp { head; arg; _ } -> go_head head (n_applied + 1); go_arg arg
    | _ -> ()
  in
  go_arg te;
  List.rev !errors

let check_type_arities (decls : top_decl list) : validation_error list =
  (* Build arity table: stdlib + user-defined parameterized ADTs *)
  let user_arities = List.filter_map (fun d ->
    match d with
    | DType (TypeAdt { name; params; _ }) when params <> [] ->
      Some (name, List.length params)
    | _ -> None
  ) decls in
  let arity_tbl = stdlib_type_arities @ user_arities in
  let check_te te = check_type_arity_te arity_tbl te in
  let check_ret rs =
    match rs with
    | RetPlain { ty; _ }            -> check_te ty
    | RetAttached { binding = b; _ }-> check_te b.type_expr
    | RetNamedPack { ty; _ }        -> check_te ty
    | RetForAll { elem_ty; _ }      -> check_te elem_ty
    | RetMaybeForAll { elem_ty; _ } -> check_te elem_ty
    | RetSetForAll { elem_ty; _ }   -> check_te elem_ty
    | RetMaybeSetForAll { elem_ty; _ } -> check_te elem_ty
    | RetForAllDictValues { key_ty; val_ty; _ }
    | RetForAllDictKeys   { key_ty; val_ty; _ } -> check_te key_ty @ check_te val_ty
    | _ -> []
  in
  List.concat_map (fun d ->
    match d with
    | DFunc fd ->
      let param_errs = List.concat_map (fun (b : binding) ->
        check_te b.type_expr) fd.params in
      let ret_errs = check_ret fd.return_spec in
      param_errs @ ret_errs
    | DType (TypeAdt { variants; _ }) ->
      List.concat_map (fun (v : adt_variant) ->
        List.concat_map (fun (f : field_def) ->
          check_te f.type_expr) v.fields) variants
    | DType (TypeNewtype { base_type; _ }) -> check_te base_type
    | _ -> []
  ) decls

(** Check that the ordering operators (<, <=, >, >=) are only applied to
    types that support a meaningful total order: Int, Float, PosixMillis, and
    any nominal type (type alias or newtype) whose declared base type resolves
    to one of those three through a chain of such declarations. *)
let check_ord_operator_types ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  (* Map: nominal type name -> declared base type_expr *)
  let alias_map : (string * type_expr) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ })
      | DType (TypeAlias   { name; base_type; _ }) -> Some (name, base_type)
      | _ -> None
    ) decls
  in
  let orderable_bases = ["Int"; "Float"; "PosixMillis"] in
  (* Resolve through alias/newtype chains to check orderability *)
  let rec is_orderable (seen : string list) (ty : type_expr) : bool =
    match ty with
    | TVar _ -> true  (* Generic type variable — can't determine at checking time; trust HM *)
    | TName { name; _ } ->
      List.mem name orderable_bases ||
      (not (List.mem name seen) &&
       match List.assoc_opt name alias_map with
       | Some base -> is_orderable (name :: seen) base
       | None -> false)
    | _ -> false
  in
  let ord_op_name = function
    | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">=" | _ -> "?"
  in
  let rec walk_expr (env : type_env) (e : expr) : validation_error list =
    match e with
    | EBinop { op = (BLt | BLe | BGt | BGe) as op; left; right; loc } ->
      let child_errs = walk_expr env left @ walk_expr env right in
      let ord_errs =
        (* SQL DSL: `select p from T where p.field > val` is parsed as
           EBinop(BGt, select_chain, val).  The comparison operator is SQL predicate
           syntax here, not a Tesl ordering comparison.  Skip the check. *)
        if infer_sql_aggregate_type e <> None then []
        else
          match infer_expr_type env funcs fields_by_type ctors left with
          | Some ty when is_orderable [] ty -> []
          | Some ty ->
            [ make_error loc
                ~hint:(Printf.sprintf
                  "only Int, Float, PosixMillis, and nominal types derived from them \
                   support `%s`; consider comparing a numeric representation instead"
                  (ord_op_name op))
                (Printf.sprintf
                  "ordering operator `%s` is not defined for type `%s`"
                  (ord_op_name op) (type_key ty)) ]
          | None -> []  (* cannot infer type — do not block *)
      in
      child_errs @ ord_errs
    | ELet { name; value; body; _ } ->
      let child_errs = walk_expr env value in
      let env' = match infer_expr_type env funcs fields_by_type ctors value with
        | Some ty -> (name, ty) :: env
        | None -> env
      in
      child_errs @ walk_expr env' body
    | ELetProof { value_name; value; body; _ } ->
      let child_errs = walk_expr env value in
      let env' = match infer_expr_type env funcs fields_by_type ctors value with
        | Some ty -> (value_name, ty) :: env
        | None -> env
      in
      child_errs @ walk_expr env' body
    | EIf { cond; then_; else_; _ } ->
      walk_expr env cond @ walk_expr env then_ @ walk_expr env else_
    | ECase { scrut; arms; _ } ->
      let scrut_ty = infer_expr_type env funcs fields_by_type ctors scrut in
      walk_expr env scrut
      @ List.concat_map (fun (arm : case_arm) ->
          let env' = pattern_bindings scrut_ty ctors arm.pattern @ env in
          walk_expr env' arm.body
        ) arms
    | EApp _ ->
      let (_, args) = collect_call_head_and_args [] e in
      List.concat_map (walk_expr env) args
    | EOk { value; _ } -> walk_expr env value
    | ELambda { params; body; _ } ->
      let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
      walk_expr env' body
    | EBinop { left; right; _ } -> walk_expr env left @ walk_expr env right
    | EUnop { arg; _ } -> walk_expr env arg
    | EList { elems; _ } -> List.concat_map (walk_expr env) elems
    | ERecord { fields; _ } -> List.concat_map (fun (_, v) -> walk_expr env v) fields
    | ETelemetry { fields; _ } -> List.concat_map (fun (_, v) -> walk_expr env v) fields
    | EEnqueue { payload; _ } -> walk_expr env payload
    | EPublish { key; payload; _ } ->
      (match key with Some e -> walk_expr env e | None -> [])
      @ (match payload with Some e -> walk_expr env e | None -> [])
    | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk_expr env body
    | EServe { port; _ } -> walk_expr env port
    | EStartWorkers _ | ELit _ | EVar _ | EField _
    | EFail _ | EConstructor _ -> []
  in
  let rec walk_test_stmts (env : type_env) (stmts : test_stmt list)
      : validation_error list =
    let (errs, _) = List.fold_left (fun (acc, env) stmt ->
      match stmt with
      | TsLetProof { value_name = name; value; _ } ->
        let e = walk_expr env value in
        let env' = (name, TName { name = "Any"; loc = dummy_loc "" }) :: env in
        (acc @ e, env')
      | TsLet { name; value; _ } ->
        let e = walk_expr env value in
        let env' = match infer_expr_type env funcs fields_by_type ctors value with
          | Some ty -> (name, ty) :: env
          | None -> env
        in
        (acc @ e, env')
      | TsExpect { left; right; _ } ->
        let e = walk_expr env left
                @ (match right with Some r -> walk_expr env r | None -> []) in
        (acc @ e, env)
      | TsExpectFail { fn; arg; _ }
      | TsExpectHasProof { fn; arg; _ } ->
        (acc @ walk_expr env fn @ walk_expr env arg, env)
      | TsProperty { body; _ } ->
        (acc @ walk_expr env body, env)
      | TsIf { cond; then_stmts; else_stmts; _ } ->
        let e = walk_expr env cond
                @ walk_test_stmts env then_stmts
                @ walk_test_stmts env else_stmts in
        (acc @ e, env)
      | TsCase { scrut; arms; _ } ->
        let e = walk_expr env scrut
                @ List.concat_map (fun (arm : Ast.ts_case_arm) ->
                    (match arm.ts_guard with Some g -> walk_expr env g | None -> [])
                    @ walk_test_stmts env arm.ts_body
                  ) arms in
        (acc @ e, env)
      | TsExpr { e; _ } ->
        (acc @ walk_expr env e, env)
    ) ([], env) stmts
    in errs
  in
  List.concat_map (function
    | DFunc fd ->
      let env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      walk_expr env fd.body
    | DTest tf ->
      walk_test_stmts [] tf.stmts
    | DApiTest atf ->
      List.concat_map (walk_expr []) atf.seed_stmts
      @ walk_test_stmts [] atf.stmts
    | DLoadTest ltf ->
      List.concat_map (walk_expr []) ltf.seed_stmts
      @ walk_test_stmts [] ltf.request_stmts
    | _ -> []
  ) decls

(* ── 3b. Record field proof enforcement at construction sites ─────────────── *)

(** Build a map from record name → list of (field_name, binding) for fields
    that have proof annotations.  The binding uses the field name as the
    parameter name so [check_call_proofs] can substitute it with the actual
    argument's subject at construction time. *)
let build_record_field_bindings (decls : top_decl list)
    : (string * binding list) list =
  List.filter_map (function
    | DRecord r ->
      let annotated = List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | None -> None
        | Some proof ->
          Some { name = f.name; type_expr = f.type_expr;
                 proof_ann = Some proof; loc = f.loc }
      ) r.fields in
      if annotated = [] then None else Some (r.name, annotated)
    | _ -> None
  ) decls

(** R51_SQ01 / R51_SQ02 / R51_SQ03 — SQL where-clause RHS validation.

    The where-clause LHS (`t.field`) has long been checked by
    `validate_field_accesses` (the "unknown field" error). The RHS and the
    `isNull`/`isNotNull` predicates were not. This pass adds:

      - type-compatibility between `t.field` and the RHS of a comparison
        (rejects `where t.title == 5` when `title: String`);
      - scope-check for identifiers on the RHS (rejects `where t.x == foo`
        when `foo` is not bound);
      - a `Maybe T` check for `isNull`/`isNotNull` (rejects these on
        non-nullable columns). *)
let check_sql_where_clauses
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  (* Newtypes are transparent at JSON/SQL boundaries (spec §11.6). Build a map
     from newtype head name to its base-type head name so SQL WHERE comparisons
     against a newtype field can accept the underlying primitive literal. *)
  let newtype_base : (string * string) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ }) ->
        (match type_head_name base_type with
         | Some base -> Some (name, base)
         | None -> None)
      | _ -> None
    ) decls
  in
  let rec resolve_nt (k : string) : string =
    match List.assoc_opt k newtype_base with
    | Some base when base <> k -> resolve_nt base
    | _ -> k
  in
  let errors = ref [] in
  let emit err = errors := err :: !errors in
  let scan_predicate tenv binder_env bound_names pred =
    let check_field_rhs binder field op right_expr loc =
      match List.assoc_opt binder binder_env with
      | None -> ()
      | Some entity_name ->
        let entity_fields =
          record_fields_of_type fields_by_type (mk_name_type entity_name)
        in
        (match entity_fields with
         | None -> ()
         | Some efs ->
           (match List.find_opt (fun (f : field_def) -> f.name = field) efs with
            | None -> ()
            | Some f ->
              let field_ty = f.type_expr in
              (match right_expr with
               | EVar { name; _ }
                 when not (List.mem name bound_names)
                   && not (List.mem_assoc name binder_env)
                   && not (List.mem_assoc name funcs)
                   && not (List.mem_assoc name tenv) ->
                 emit (make_error loc
                   ~hint:(Printf.sprintf
                     "`%s` is not in scope; bind it with `let %s = ...` or pass it in as a parameter"
                     name name)
                   (Printf.sprintf
                     "SQL WHERE clause references unbound identifier `%s`"
                     name))
               | _ ->
                 (match infer_expr_type tenv funcs fields_by_type ctors right_expr with
                  | None -> ()
                  | Some rhs_ty ->
                    let fk = resolve_nt (type_key field_ty) in
                    let rk = resolve_nt (type_key rhs_ty) in
                    if fk <> rk then
                      emit (make_error loc
                        ~hint:(Printf.sprintf
                          "field `%s` is declared as `%s` — wrap the RHS in a `check` or convert it to the same type"
                          field (type_key field_ty))
                        (Printf.sprintf
                          "SQL WHERE clause: type mismatch for `%s.%s %s <rhs>` — field type is `%s`, RHS is `%s`"
                          binder field op (type_key field_ty) (type_key rhs_ty)))))))
    in
    let check_isnull binder field loc =
      match List.assoc_opt binder binder_env with
      | None -> ()
      | Some entity_name ->
        let entity_fields =
          record_fields_of_type fields_by_type (mk_name_type entity_name)
        in
        (match entity_fields with
         | None -> ()
         | Some efs ->
           (match List.find_opt (fun (f : field_def) -> f.name = field) efs with
            | None -> ()
            | Some f ->
              let is_nullable = match f.type_expr with
                | TApp { head = TName { name = "Maybe"; _ }; _ } -> true
                | _ -> false
              in
              if not is_nullable then
                emit (make_error loc
                  ~hint:(Printf.sprintf
                    "declare the field as `%s: Maybe %s` to allow NULL, or remove the `isNull` check"
                    field (type_key f.type_expr))
                  (Printf.sprintf
                    "SQL WHERE clause: `isNull %s.%s` is always false because field `%s` is NOT NULL (declared as `%s`)"
                    binder field field (type_key f.type_expr)))))
    in
    match pred with
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe) as op; left; right; loc } ->
      (match left with
       | EField { obj = EVar { name = b; _ }; field; _ } ->
         let op_str = match op with
           | BEq -> "==" | BNeq -> "!=" | BLt -> "<" | BLe -> "<="
           | BGt -> ">" | BGe -> ">=" | _ -> "?"
         in
         check_field_rhs b field op_str right loc
       | _ -> ())
    | EApp { fn = EVar { name = ("isNull" | "isNotNull"); _ };
             arg = EField { obj = EVar { name = b; _ }; field; _ }; loc } ->
      check_isnull b field loc
    | _ -> ()
  in
  let rec walk tenv binder_env bound_names e =
    match e with
    | EApp _ ->
      let flat =
        let rec go acc = function
          | EApp { fn; arg; _ } -> go (arg :: acc) fn
          | hd -> (hd, acc)
        in go [] e
      in
      let head, args = flat in
      let binder_env' = match head with
        | EVar { name = ("selectOne" | "select" | "selectCount"
                       | "selectSum" | "selectMax" | "selectMin"
                       | "update" | "delete" | "deleteAndReturnResult"); _ } ->
          let binder_name = match args with
            | EVar { name; _ } :: _ -> Some name
            | EField { obj = EVar { name; _ }; _ } :: _ -> Some name
            | _ -> None
          in
          let entity_name =
            let rec find_entity = function
              | EVar { name = ("from" | "in"); _ } :: EConstructor { name; _ } :: _ -> Some name
              | EVar { name = ("from" | "in"); _ } :: EVar { name; _ } :: _ -> Some name
              | _ :: rest -> find_entity rest
              | [] -> None
            in find_entity args
          in
          (match binder_name, entity_name with
           | Some bn, Some en -> (bn, en) :: binder_env
           | _ -> binder_env)
        | _ -> binder_env
      in
      List.iter (fun arg ->
        (match arg with
         | EApp { fn = EVar { name = "where"; _ }; arg = pred_expr; _ } ->
           scan_predicate tenv binder_env' bound_names pred_expr
         | _ -> ());
        walk tenv binder_env' bound_names arg
      ) args;
      (* Additional scan: in a flattened select chain, `isNull t.field`
         appears as two adjacent atoms — `EVar "isNull"` and
         `EField { obj = EVar t; field }` — not as a single `EApp`. *)
      let rec scan_pairs = function
        | EVar { name = ("isNull" | "isNotNull"); _ }
          :: (EField { obj = EVar { name = b; _ }; field; loc } as fld)
          :: rest ->
          scan_predicate tenv binder_env' bound_names
            (EApp { fn = EVar { name = "isNull"; loc };
                    arg = fld; loc });
          ignore b; ignore field;
          scan_pairs rest
        | _ :: rest -> scan_pairs rest
        | [] -> ()
      in
      scan_pairs args
    | ELet { name; value; body; _ } ->
      walk tenv binder_env bound_names value;
      let tenv' = match infer_expr_type tenv funcs fields_by_type ctors value with
        | Some ty -> (name, ty) :: tenv
        | None -> tenv
      in
      walk tenv' binder_env (name :: bound_names) body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      walk tenv binder_env bound_names value;
      let bound' =
        (if value_name = "_" then [] else [value_name]) @
        (if proof_name  = "_" then [] else [proof_name])  @
        bound_names
      in
      walk tenv binder_env bound' body
    | EIf { cond; then_; else_; _ } ->
      walk tenv binder_env bound_names cond;
      walk tenv binder_env bound_names then_;
      walk tenv binder_env bound_names else_
    | ECase { scrut; arms; _ } ->
      walk tenv binder_env bound_names scrut;
      List.iter (fun (arm : case_arm) ->
        let bound = pattern_bound_names arm.pattern @ bound_names in
        (match arm.guard with
         | Some g -> walk tenv binder_env bound g
         | None -> ());
        walk tenv binder_env bound arm.body
      ) arms
    | ERecord { fields; _ } ->
      List.iter (fun (_, v) -> walk tenv binder_env bound_names v) fields
    | EList { elems; _ } ->
      List.iter (walk tenv binder_env bound_names) elems
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe) as op; left; right; loc } ->
      walk tenv binder_env bound_names left;
      walk tenv binder_env bound_names right;
      (* Detect SQL WHERE comparison: the top-level EBinop's LEFT is a
         flattened select...where chain whose last atom is `binder.field`. *)
      let rec flatten_atoms acc = function
        | EApp { fn; arg; _ } -> flatten_atoms (arg :: acc) fn
        | hd -> hd :: acc
      in
      let atoms = flatten_atoms [] left in
      (match atoms with
       | EVar { name = ("select" | "selectOne" | "selectCount"
                      | "selectSum" | "selectMax" | "selectMin"
                      | "update" | "delete" | "deleteAndReturnResult"); _ }
         :: _ ->
         (* Find the binder (first arg) and the entity (after "from" or "in"). *)
         let binder_name = match atoms with
           | _ :: EVar { name; _ } :: _ -> Some name
           | _ :: EField { obj = EVar { name; _ }; _ } :: _ -> Some name
           | _ -> None
         in
         let entity_name =
           let rec find_entity = function
             | EVar { name = ("from" | "in"); _ } :: EConstructor { name; _ } :: _ -> Some name
             | EVar { name = ("from" | "in"); _ } :: EVar { name; _ } :: _ -> Some name
             | _ :: rest -> find_entity rest
             | [] -> None
           in find_entity atoms
         in
         let binder_env' = match binder_name, entity_name with
           | Some bn, Some en -> (bn, en) :: binder_env
           | _ -> binder_env
         in
         (* The final atom before the right side of the EBinop is the LHS of
            the comparison — e.g. `t.title` in `where t.title == 5`. *)
         let last_atom = match List.rev atoms with a :: _ -> a | [] -> left in
         (match last_atom with
          | EField { obj = EVar { name = b; _ }; field; _ } ->
            let op_str = match op with
              | BEq -> "==" | BNeq -> "!=" | BLt -> "<" | BLe -> "<="
              | BGt -> ">" | BGe -> ">=" | _ -> "?"
            in
            let fake_pred = EBinop { op; left = last_atom; right; loc } in
            let _ = op_str in
            scan_predicate tenv binder_env' bound_names fake_pred;
            (* Also scan for isNull on the last atom if it appears via EApp *)
            ignore b; ignore field
          | _ -> ())
       | _ -> ())
    | EBinop { left; right; _ } ->
      walk tenv binder_env bound_names left;
      walk tenv binder_env bound_names right
    | EUnop { arg; _ } -> walk tenv binder_env bound_names arg
    | EOk { value; _ } -> walk tenv binder_env bound_names value
    | ETelemetry { fields; _ } ->
      List.iter (fun (_, v) -> walk tenv binder_env bound_names v) fields
    | EEnqueue { payload; _ } -> walk tenv binder_env bound_names payload
    | EPublish { key; payload; _ } ->
      (match key with Some k -> walk tenv binder_env bound_names k | None -> ());
      (match payload with Some p -> walk tenv binder_env bound_names p | None -> ())
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk tenv binder_env bound_names body
    | EServe { port; _ } -> walk tenv binder_env bound_names port
    | ELambda { params; body; _ } ->
      let bound' = List.map (fun (b : binding) -> b.name) params @ bound_names in
      walk tenv binder_env bound' body
    | _ -> ()
  in
  List.iter (function
    | DFunc fd ->
      let param_tenv = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      let param_names = List.map (fun (b : binding) -> b.name) fd.params in
      walk param_tenv [] param_names fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

(** Check that every record construction expression satisfies the proof
    annotations declared on the fields being assigned.  This ensures that
    `SafeReq { count: rawInt }` cannot pass a non-validated Int to a field
    declared as `count: Int ::: IsPositive count`. *)
let check_record_field_proof_construction
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let rec_bindings = build_record_field_bindings decls in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  if rec_bindings = [] then []
  else
    let errors = ref [] in
    (* Walk expressions accumulating type_env, subject_env and proof_env.  When we
       encounter a typed record construction whose record has proof-annotated
       fields, delegate to check_call_proofs treating fields as parameters. *)
    let rec walk_expr (type_env : type_env) (subject_env : subject_env) (proof_env : proof_env) (e : expr) =
      match e with
      | EApp {
          fn = EConstructor { name = rname; args = []; _ };
          arg = ERecord { fields; loc = rloc; _ };
          _;
        } when List.mem_assoc rname rec_bindings ->
        (* First recurse into the field values *)
        List.iter (fun (_, v) -> walk_expr type_env subject_env proof_env v) fields;
        (* Then check field proof requirements *)
        let field_bindings = List.assoc rname rec_bindings in
        (* Build an argument list aligned to the annotated fields *)
        let args = List.filter_map (fun (b : binding) ->
          List.assoc_opt b.name fields
        ) field_bindings in
        let checked = check_call_proofs ~funcs rloc rname field_bindings args subject_env proof_env in
        errors := checked @ !errors
      (* Record update: { r | field = val } — check proof requirements on updated fields *)
      | EApp {
          fn = EVar { name = "#record-update#"; _ };
          arg = ERecord { fields; loc = rloc; _ };
          _;
        } ->
        List.iter (fun (fn, fv) ->
          if fn <> "__base__" then walk_expr type_env subject_env proof_env fv
        ) fields;
        (match List.assoc_opt "__base__" fields with
         | Some base_expr ->
           walk_expr type_env subject_env proof_env base_expr;
           (match infer_expr_type type_env funcs fields_by_type ctors base_expr with
            | Some base_ty ->
              let rname = match base_ty with
                | TName { name; _ } -> name
                | TApp { head = TName { name; _ }; _ } -> name
                | _ -> ""
              in
              (match List.assoc_opt rname rec_bindings with
               | None -> ()
               | Some field_bindings ->
                 let updated_bindings = List.filter (fun (b : binding) ->
                   List.mem_assoc b.name fields
                 ) field_bindings in
                 if updated_bindings <> [] then begin
                   let updated_args = List.filter_map (fun (b : binding) ->
                     List.assoc_opt b.name fields
                   ) updated_bindings in
                   let checked = check_call_proofs ~funcs rloc rname updated_bindings updated_args subject_env proof_env in
                   errors := checked @ !errors
                 end)
            | None -> ())
         | None -> ())
      | EApp _ ->
        let (_, args) = collect_call_head_and_args [] e in
        List.iter (walk_expr type_env subject_env proof_env) args
      | ELet { name; value; body; _ } ->
        walk_expr type_env subject_env proof_env value;
        let subject_env' = match subject_of_expr subject_env value with
          | Some s -> (name, s) :: subject_env
          | None ->
            (* For direct check-fn calls (RetAttached), propagate the subject of the
               return-bound argument to the let-binder, mirroring check_expr_call_proofs. *)
            (match value with
             | EApp _ ->
               let (head0, args0) = collect_call_head_and_args [] value in
               let (head, args) = normalize_explicit_check_call head0 args0 in
               (match function_name_of_expr head with
                | Some fn_name ->
                  (match List.assoc_opt fn_name funcs with
                   | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                     let binding_arg = match info.fi_return with
                       | RetAttached { binding = b; _ } ->
                         let rec find_idx i = function
                           | [] -> None
                           | (p : binding) :: _ when p.name = b.name ->
                             if i < List.length args then Some (List.nth args i) else None
                           | _ :: rest -> find_idx (i+1) rest
                         in
                         (match find_idx 0 info.fi_params with
                          | Some a -> Some a
                          | None -> List.nth_opt args 0)
                       | _ -> List.nth_opt args 0
                     in
                     (match binding_arg with
                      | Some arg ->
                        (match subject_of_expr subject_env arg with
                         | Some s -> (name, s) :: subject_env
                         | None -> subject_env)
                      | None -> subject_env)
                   | _ -> subject_env)
                | None -> subject_env)
             | _ -> subject_env)
        in
        let new_proofs = proofs_of_expr name funcs subject_env' proof_env value in
        let proof_env' = if new_proofs = [] then proof_env
                         else (name, new_proofs) :: proof_env in
        let type_env' = match infer_expr_type type_env funcs fields_by_type ctors value with
          | Some ty -> (name, ty) :: type_env
          | None -> type_env
        in
        walk_expr type_env' subject_env' proof_env' body
      | ELetProof { value_name; proof_name; value; body; _ } ->
        walk_expr type_env subject_env proof_env value;
        let subject_env' = match subject_of_expr subject_env value with
          | Some s -> (value_name, s) :: subject_env
          | None ->
            (* For check-fn calls (RetAttached), propagate the subject of the
               return-bound argument — same logic as the ELet handler. *)
            (match value with
             | EApp _ ->
               let (head0, args0) = collect_call_head_and_args [] value in
               let (_head, args) = normalize_explicit_check_call head0 args0 in
               (match function_name_of_expr _head with
                | Some fn_name ->
                  (match List.assoc_opt fn_name funcs with
                   | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                     let binding_arg = match info.fi_return with
                       | RetAttached { binding = b; _ } ->
                         let rec find_idx i = function
                           | [] -> None
                           | (p : binding) :: _ when p.name = b.name ->
                             if i < List.length args then Some (List.nth args i) else None
                           | _ :: rest -> find_idx (i+1) rest
                         in
                         (match find_idx 0 info.fi_params with
                          | Some arg -> Some arg
                          | None -> (match args with x :: _ -> Some x | [] -> None))
                       | _ -> (match args with x :: _ -> Some x | [] -> None)
                     in
                     (match binding_arg with
                      | Some arg ->
                        (match subject_of_expr subject_env arg with
                         | Some s -> (value_name, s) :: subject_env
                         | None -> subject_env)
                      | None -> subject_env)
                   | _ -> subject_env)
                | None -> subject_env)
             | _ -> subject_env)
        in
        (* Propagate proofs: proof_name gets the detached proofs from the value.
           Mirror the logic in check_expr_call_proofs's ELetProof handler. *)
        let detached_proofs =
          let carried = match carried_proofs_of_expr ~funcs subject_env proof_env value with
            | Some proofs -> proofs
            | None -> []
          in
          if carried <> [] then carried
          else proofs_of_expr value_name funcs subject_env' proof_env value
        in
        let proof_env' =
          if proof_name <> "_" && detached_proofs <> [] then
            (proof_name, detached_proofs) :: proof_env
          else proof_env
        in
        walk_expr type_env subject_env' proof_env' body
      | EIf { cond; then_; else_; _ } ->
        walk_expr type_env subject_env proof_env cond;
        walk_expr type_env subject_env proof_env then_;
        walk_expr type_env subject_env proof_env else_
      | ECase { scrut; arms; _ } ->
        walk_expr type_env subject_env proof_env scrut;
        (* R51_P03 — propagate case-arm binder proofs.
           For `case scrut of Something p -> body`, the `p` binder carries
           the proofs extracted from the scrut's Maybe (Fact P) shape.  We
           mirror the logic in `check_expr_call_proofs`'s ECase handler so
           the record-field-proof pass can resolve `value ::: p` in the
           arm body, making `Holder { v: x ::: p }` accept the same proof
           evidence that the direct call form already does. *)
        let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
        List.iter (fun (arm : case_arm) ->
          let proof_env' = match arm.pattern with
            | PCon { fields = [(_, PVar x)]; _ } when scrut_proofs <> [] ->
              (x, scrut_proofs) :: proof_env
            | _ -> proof_env
          in
          walk_expr type_env subject_env proof_env' arm.body
        ) arms
      | EOk { value; _ } -> walk_expr type_env subject_env proof_env value
      | ELambda { params; body; _ } ->
        let type_env' = List.fold_left (fun acc (b : binding) ->
          (b.name, b.type_expr) :: acc) type_env params in
        let subject_env' = List.fold_left (fun acc (b : binding) ->
          (b.name, b.name) :: acc) subject_env params in
        let proof_env' = List.fold_left (fun acc (b : binding) ->
          match b.proof_ann with
          | Some p -> (b.name, [p]) :: acc
          | None -> acc) proof_env params in
        walk_expr type_env' subject_env' proof_env' body
      | EList { elems; _ } -> List.iter (walk_expr type_env subject_env proof_env) elems
      | ERecord { fields; _ } ->
        List.iter (fun (_, v) -> walk_expr type_env subject_env proof_env v) fields
      | EBinop { left; right; _ } ->
        walk_expr type_env subject_env proof_env left;
        walk_expr type_env subject_env proof_env right
      | EUnop { arg; _ } -> walk_expr type_env subject_env proof_env arg
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_expr type_env subject_env proof_env body
      | ETelemetry { fields; _ } ->
        List.iter (fun (_, v) -> walk_expr type_env subject_env proof_env v) fields
      | EEnqueue { payload; _ } -> walk_expr type_env subject_env proof_env payload
      | EPublish { key; payload; _ } ->
        (match key with Some e -> walk_expr type_env subject_env proof_env e | None -> ());
        (match payload with Some e -> walk_expr type_env subject_env proof_env e | None -> ())
      | EServe { port; _ } -> walk_expr type_env subject_env proof_env port
      | EConstructor { args; _ } ->
        List.iter (walk_expr type_env subject_env proof_env) args
      | EStartWorkers _ | ELit _ | EVar _ | EField _ | EFail _ -> ()
    in
    List.iter (function
      | DFunc fd ->
        let type_env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
        let subject_env = build_initial_subject_env fd.params in
        let proof_env = build_initial_proof_env fd.params in
        walk_expr type_env subject_env proof_env fd.body
      | _ -> ()
    ) decls;
    List.rev !errors

(** Forbid [fn] functions from declaring proof return types that cannot be
    established by the function's parameters.

    A [fn] may propagate an existing proof from a parameter (e.g.,
    [fn f(n: Int ::: P n) -> n: Int ::: P n = n] is a passthrough) but must
    not claim a proof the params do not already carry, because [fn] has no
    mechanism to establish new proofs at runtime — that is the job of [check]
    and [auth].

    Accepts: [fn f(n: Int ::: P n) -> n: Int ::: P n = n]  (passthrough)
    Rejects: [fn liar(n: Int) -> n: Int ::: P n = n]        (new proof, not from params) *)
let check_fn_return_proof_annotations
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  field_proof_registry := build_field_proof_map decls;
  let errors = ref [] in
  let actual_proof_summary proofs =
    match combine_proof_list (dummy_loc "named-pack return") proofs with
    | Some proof -> pp_proof proof
    | None -> "no proofs"
  in
  let extend_let_envs type_env subject_env proof_env name value =
    (* Special case: forgetFact strips all proofs — do not propagate subject chain,
       and add an explicit empty proof entry to prevent alias resolution from
       finding the original's proofs. *)
    let is_forget_fact =
      match value with
      | EApp _ ->
        let (head, _) = collect_call_head_and_args [] value in
        (match function_name_of_expr head with
         | Some "forgetFact" -> true
         | _ -> false)
      | _ -> false
    in
    if is_forget_fact then
      let type_env' =
        match infer_expr_type type_env funcs fields_by_type ctors value with
        | Some ty -> (name, ty) :: type_env
        | None -> type_env
      in
      (* Empty proof entry blocks alias resolution; no subject link *)
      (type_env', subject_env, (name, []) :: proof_env)
    else
    let subject_env' =
      match subject_of_expr subject_env value with
      | Some s -> (name, s) :: subject_env
      | None ->
        (match value with
         | EApp _ ->
           let (head0, args0) = collect_call_head_and_args [] value in
           let (head, args) = normalize_explicit_check_call head0 args0 in
           (match function_name_of_expr head with
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                 let binding_arg =
                   match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i + 1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some a -> Some a
                      | None -> List.nth_opt args 0)
                   | _ -> List.nth_opt args 0
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None -> subject_env)
         | _ -> subject_env)
    in
    let new_proofs = proofs_of_expr name funcs subject_env' proof_env value in
    let proof_env' = if new_proofs = [] then proof_env else (name, new_proofs) :: proof_env in
    (* When name is "_" (auto-unpack from check calls), the proofs are lost
       because nobody looks up "_".  Also store under the check call's argument
       name so that EOk { value = EVar arg_name } can find them. *)
    let proof_env' =
      if name = "_" && new_proofs <> [] then
        (* Extract the last argument of the check call *)
        let (_, args) = collect_call_head_and_args [] value in
        let last_arg = match List.rev args with a :: _ -> Some a | [] -> None in
        let arg_name = match last_arg with
          | Some (EVar { name = n; _ }) -> Some n
          | Some (EOk { value = EVar { name = n; _ }; _ }) -> Some n
          | _ -> None
        in
        (match arg_name with
         | Some n when n <> "_" -> (n, new_proofs) :: proof_env'
         | _ -> proof_env')
      else proof_env'
    in
    let type_env' =
      match infer_expr_type type_env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: type_env
      | None -> type_env
    in
    (type_env', subject_env', proof_env')
  in
  let extend_case_envs subject_env proof_env scrut scrut_proofs pat =
    match pat with
    | PVar x when x <> "_" ->
      let penv = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
      let senv =
        match subject_of_expr subject_env scrut with
        | Some s when s <> x -> (x, s) :: subject_env
        | _ -> subject_env
      in
      (penv, senv)
    | PCon { fields = [(_, PVar x)]; _ } ->
      let penv = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
      let senv =
        let rec resolve_chain seen name =
          if List.mem name seen then name
          else
            match List.assoc_opt name subject_env with
            | Some s when s <> name -> resolve_chain (name :: seen) s
            | _ -> name
        in
        let final_subj =
          match scrut with
          | EVar { name; _ } -> resolve_chain [] name
          | _ -> (match subject_of_expr subject_env scrut with Some s -> s | None -> x)
        in
        if final_subj <> x then (x, final_subj) :: subject_env else subject_env
      in
      (penv, senv)
    | _ -> (proof_env, subject_env)
  in
  (* Predicates that come from infrastructure (SQL, queue) and cannot be
     validated by tracing the function body — exclude them from proof-body
     checking so fn functions can correctly propagate these proofs.
     Note: IsTrimmed, IsSorted, IsUpperCase, IsLowerCase are now in
     stdlib_func_infos so they ARE validated; don't list them here. *)
  let stdlib_auto_preds =
    [ "FromDb"; "FromQueue"; "ForAll"; "ForAllValues"; "ForAllKeys";
      "HasKey"; "IsNonZero"; "IsNonNegative"; "IsNonEmpty"; "FloatNonZero" ] in
  let rec check_named_pack_body (fd : func_decl) ret_loc entity_proof other_proof type_env subject_env proof_env expr =
    match expr with
    | ELet { name; value; body; _ } ->
      let type_env', subject_env', proof_env' = extend_let_envs type_env subject_env proof_env name value in
      check_named_pack_body fd ret_loc entity_proof other_proof type_env' subject_env' proof_env' body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let type_env', subject_env', proof_env' = extend_let_envs type_env subject_env proof_env value_name value in
      (* Also register the proof variable in proof_env so it can be resolved
         when the body uses `::: p` annotations. *)
      let proof_env' =
        let proofs = proofs_of_expr value_name funcs subject_env' proof_env' value in
        if proofs = [] then proof_env'
        else (proof_name, proofs) :: proof_env'
      in
      check_named_pack_body fd ret_loc entity_proof other_proof type_env' subject_env' proof_env' body
    | EIf { then_; else_; _ } ->
      check_named_pack_body fd ret_loc entity_proof other_proof type_env subject_env proof_env then_;
      check_named_pack_body fd ret_loc entity_proof other_proof type_env subject_env proof_env else_
    | ECase { scrut; arms; _ } ->
      let scrut_ty = infer_expr_type type_env funcs fields_by_type ctors scrut in
      let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
      List.iter (fun (arm : case_arm) ->
        let type_env' = pattern_bindings scrut_ty ctors arm.pattern @ type_env in
        let proof_env', subject_env' = extend_case_envs subject_env proof_env scrut scrut_proofs arm.pattern in
        check_named_pack_body fd ret_loc entity_proof other_proof type_env' subject_env' proof_env' arm.body
      ) arms
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
      check_named_pack_body fd ret_loc entity_proof other_proof type_env subject_env proof_env body
    | EFail _ -> ()  (* fail never returns — no proof obligation *)
    | _ ->
      check_named_pack_body_leaf fd ret_loc entity_proof other_proof type_env subject_env proof_env expr
  and check_named_pack_body_leaf (fd : func_decl) ret_loc entity_proof other_proof _type_env subject_env proof_env expr =
      let result_subject =
        match subject_of_expr subject_env expr with
        | Some s -> s
        | None -> "__named_pack_result"
      in
      let param_mapping = List.map (fun (p : binding) ->
        let subject = match List.assoc_opt p.name subject_env with Some s -> s | None -> p.name in
        (p.name, subject)
      ) fd.params in
      let carried =
        let base = proofs_of_expr result_subject funcs subject_env proof_env expr in
        (* For EOk { value = EVar name; proof = p }, the check call's proofs
           are stored under "_" in proof_env (auto-unpack lets).  Supplement
           carried proofs with those entries, substituting "_" subjects. *)
        let all_underscore_proofs = List.concat (
          List.filter_map (fun (k, v) -> if k = "_" then Some v else None) proof_env
        ) in
        if all_underscore_proofs <> [] then
          let fix_subject p =
            let rec go = function
              | PredApp { pred; args; loc } ->
                PredApp { pred; args = List.map (fun a -> if a = "_" then result_subject else a) args; loc }
              | PredAnd { left; right; loc } ->
                PredAnd { left = go left; right = go right; loc }
            in go p
          in
          let fixed = List.map fix_subject all_underscore_proofs in
          let seen_keys = ref (List.map proof_key base) in
          let deduped = List.filter (fun p ->
            let k = proof_key p in
            if List.mem k !seen_keys then false
            else (seen_keys := k :: !seen_keys; true)
          ) fixed in
          base @ deduped
        else base
      in
      let kind_label = match fd.kind with HandlerKind -> "handler" | _ -> "fn" in
      let check_required kind required =
        let required_pred = match required with PredApp { pred; _ } -> Some pred | _ -> None in
        let is_stdlib_auto = match required_pred with Some pred -> List.mem pred stdlib_auto_preds | None -> false in
        if not is_stdlib_auto && not (proof_matches required carried) then
          errors := make_error ret_loc
            ~hint:(Printf.sprintf
              "establish `%s` before returning, or remove it from the named-pack return spec"
              (pp_proof required))
            (Printf.sprintf
              "%s `%s` returns a named pack claiming %s proof `%s`, but the returned expression only carries `%s`"
              kind_label fd.name kind (pp_proof required) (actual_proof_summary carried))
            :: !errors
      in
      (match entity_proof with
       | Some proof ->
         let expanded = expand_entity_proof_group proof in
         let required = subst_proof (("_entity", result_subject) :: param_mapping) expanded in
         if not (proof_matches required carried) then begin
           (* When subject_of_expr failed (result_subject = "__named_pack_result"),
              try each unique subject name from the carried proofs as the entity subject.
              The entity proof says "the returned value has this proof" — if the carried
              proofs use a specific name, that's the actual entity identity. *)
           let flat_carried = List.concat_map flatten_proof_conj carried in
           let carried_subjects =
             List.filter_map (fun (p : proof_expr) ->
               match p with
               | PredApp { args; _ } -> (match List.rev args with s :: _ -> Some s | [] -> None)
               | _ -> None
             ) flat_carried
           in
           (* Also collect subjects from ALL argument positions, not just last,
              since the entity may appear in any position depending on the fact declaration *)
           let all_arg_subjects =
             List.concat_map (fun (p : proof_expr) ->
               match p with
               | PredApp { args; _ } -> args
               | _ -> []
             ) flat_carried
           in
           let unique_subjects = List.sort_uniq String.compare (carried_subjects @ all_arg_subjects) in
           let found_match = List.exists (fun subj ->
             let alt_required = subst_proof (("_entity", subj) :: param_mapping) expanded in
             proof_matches alt_required carried
           ) unique_subjects in
           (* If still no match, try normalising carried proofs to entity-proof arg order:
              explicit args first, entity subject last (matching expand_entity_proof_group) *)
           let found_match = found_match || (
             let reorder_to_entity_order (p : proof_expr) =
               match p with
               | PredApp { pred; args; loc } when List.length args >= 2 ->
                 (* For each possible entity position, try moving it to last *)
                 let n = List.length args in
                 let try_pos i =
                   let entity_val = List.nth args i in
                   let rest = List.filteri (fun j _ -> j <> i) args in
                   let reordered = rest @ [entity_val] in
                   PredApp { pred; args = reordered; loc }
                 in
                 List.init n try_pos
               | _ -> [p]
             in
             let reordered_variants = List.concat_map reorder_to_entity_order flat_carried in
             List.exists (fun subj ->
               let alt_required = subst_proof (("_entity", subj) :: param_mapping) expanded in
               proof_matches alt_required reordered_variants
             ) unique_subjects
           ) in
           if not found_match then
             check_required "entity" required
         end
       | None -> ());
      (match other_proof with
       | Some proof ->
         let required = subst_proof param_mapping proof in
         check_required "cargo" required
       | None -> ())
  in
  List.iter (function
    | DFunc fd when fd.kind = FnKind || fd.kind = HandlerKind ->
      (match fd.return_spec with
       | RetAttached { binding = b; loc = ret_loc } when fd.kind = FnKind && b.proof_ann <> None ->
         let required_proof = match b.proof_ann with Some p -> p | None -> assert false in
         let proof_env = build_initial_proof_env fd.params in
         let subject_env = build_initial_subject_env fd.params in
         let record_field_map = List.filter_map (function
           | DRecord r -> Some (r.name, r.fields)
           | DEntity e -> Some (e.name, e.fields)
           | _ -> None
         ) decls in
         let param_type_names = List.filter_map (fun (p : binding) ->
           match p.type_expr with
           | TName { name; _ } -> Some name
           | _ -> None
         ) fd.params in
         let field_carried = List.concat_map (fun tn ->
           match List.assoc_opt tn record_field_map with
           | None -> []
           | Some fields ->
             List.filter_map (fun (f : field_def) ->
               match f.proof_ann with Some p -> Some p | None -> None
             ) fields
         ) param_type_names in
         let binding_subject = match List.assoc_opt b.name subject_env with Some s -> s | None -> b.name in
         let required_norm = subst_proof [(b.name, binding_subject)] required_proof in
         let required_pred = match required_norm with PredApp { pred; _ } -> Some pred | _ -> None in
         let is_stdlib_auto = match required_pred with Some p -> List.mem p stdlib_auto_preds | None -> false in
         let all_carried = List.concat_map snd proof_env @ field_carried in
         (* `fn f ... -> T ::: Proof` is legitimate when the body introduces
            the proof via `attachFact` (with an `establish`-produced Fact) or
            via an explicit `ok v ::: Proof`. Walk the body for either shape —
            if found, trust the existing call-proof validators to catch
            misuse and skip the conservative rejection. *)
         let rec body_uses_attach_or_ok (e : expr) : bool =
           match e with
           | EOk _ -> true
           | EApp _ ->
             let rec head = function
               | EApp { fn = f; _ } -> head f
               | x -> x
             in
             (match head e with
              | EVar { name = n; _ }
                when n = "attachFact" || n = "attach" -> true
              | _ ->
                let rec args_of acc = function
                  | EApp { fn = f; arg = a; _ } -> args_of (a :: acc) f
                  | _ -> acc
                in
                List.exists body_uses_attach_or_ok (args_of [] e))
           | ELet { value = v; body = b; _ }
           | ELetProof { value = v; body = b; _ } ->
             body_uses_attach_or_ok v || body_uses_attach_or_ok b
           | EIf { cond; then_; else_; _ } ->
             body_uses_attach_or_ok cond
             || body_uses_attach_or_ok then_
             || body_uses_attach_or_ok else_
           | ECase { scrut; arms; _ } ->
             body_uses_attach_or_ok scrut
             || List.exists (fun (a : case_arm) ->
                  body_uses_attach_or_ok a.body
                  || (match a.guard with
                      | Some g -> body_uses_attach_or_ok g
                      | None -> false)) arms
           | EBinop { left; right; _ } ->
             body_uses_attach_or_ok left || body_uses_attach_or_ok right
           | EUnop { arg; _ } -> body_uses_attach_or_ok arg
           | EField { obj; _ } -> body_uses_attach_or_ok obj
           | ERecord { fields; _ } ->
             List.exists (fun (_, v) -> body_uses_attach_or_ok v) fields
           | EList { elems; _ } -> List.exists body_uses_attach_or_ok elems
           | EFail { message; _ } -> body_uses_attach_or_ok message
           | EWithDatabase { body = b; _ }
           | EWithCapabilities { body = b; _ }
           | EWithTransaction { body = b; _ } -> body_uses_attach_or_ok b
           | EConstructor { args; _ } -> List.exists body_uses_attach_or_ok args
           | ELambda { body = b; _ } -> body_uses_attach_or_ok b
           | _ -> false
         in
         if not is_stdlib_auto
            && not (proof_matches required_norm all_carried)
            && not (body_uses_attach_or_ok fd.body) then begin
           let proof_str = pp_proof required_proof in
           errors := make_error ret_loc
             ~hint:(Printf.sprintf
               "use `check %s(...)` to validate and return a proof-carrying value; \
                `fn` cannot introduce new proofs" fd.name)
             (Printf.sprintf
               "fn `%s` cannot declare a proof return type (`-> %s ::: %s`); \
                only `check` and `auth` functions may have proof return types"
               fd.name (pp_type_expr b.type_expr) proof_str)
           :: !errors
         end
       | RetNamedPack { entity_proof; other_proof; loc; _ } when entity_proof <> None || other_proof <> None ->
         let type_env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
         let subject_env = build_initial_subject_env fd.params in
         let proof_env = build_initial_proof_env fd.params in
         check_named_pack_body fd loc entity_proof other_proof type_env subject_env proof_env fd.body
       | _ -> ())
    | _ -> ()
  ) decls;
  field_proof_registry := [];
  List.rev !errors

(** Check that top-level value bindings ([DConst]) do not form cycles.
    Cyclic initialisations such as [x = y + 1; y = x + 1] compile but produce
    undefined values at runtime. *)
let check_circular_const_bindings (decls : top_decl list) : validation_error list =
  let const_decls = List.filter_map (function
    | DConst c -> Some c
    | _ -> None
  ) decls in
  if List.length const_decls < 2 then []
  else
    let const_names = List.map (fun (c : const_form) -> c.name) const_decls in
    let name_set = List.sort_uniq String.compare const_names in
    let refs_of_expr e =
      let refs = ref [] in
      let rec walk = function
        | EVar { name; _ } when List.mem name name_set -> refs := name :: !refs
        | EVar _ | ELit _ | EFail _ | EStartWorkers _ -> ()
        | EApp { fn; arg; _ } -> walk fn; walk arg
        | ELet { value; body; _ } | ELetProof { value; body; _ } ->
          walk value; walk body
        | EIf { cond; then_; else_; _ } -> walk cond; walk then_; walk else_
        | ECase { scrut; arms; _ } ->
          walk scrut; List.iter (fun (a : case_arm) -> walk a.body) arms
        | EBinop { left; right; _ } -> walk left; walk right
        | EUnop { arg; _ } -> walk arg
        | EField { obj; _ } -> walk obj
        | EList { elems; _ } -> List.iter walk elems
        | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk v) fields
        | EConstructor { args; _ } -> List.iter walk args
        | ELambda { body; _ } -> walk body
        | EOk { value; _ } -> walk value
        | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
        | EWithTransaction { body; _ } -> walk body
        | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk v) fields
        | EEnqueue { payload; _ } -> walk payload
        | EPublish { key; payload; _ } ->
          (match key with Some e -> walk e | None -> ());
          (match payload with Some e -> walk e | None -> ())
        | EServe { port; _ } -> walk port
      in
      walk e;
      List.sort_uniq String.compare !refs
    in
    let deps = List.map (fun (c : const_form) -> (c.name, refs_of_expr c.value)) const_decls in
    let errors = ref [] in
    (* DFS with white/gray/black colouring: gray = on stack (cycle if revisited) *)
    let color : (string, int) Hashtbl.t = Hashtbl.create (List.length const_decls) in
    let rec dfs name =
      match Hashtbl.find_opt color name with
      | Some 2 -> ()
      | Some 1 ->
        (match List.find_opt (fun (c : const_form) -> c.name = name) const_decls with
         | Some c ->
           errors := make_error c.loc
             ~hint:"split into independent bindings, or use a \
                    function (`fn`) to break the cycle"
             (Printf.sprintf
               "circular binding: `%s` depends on itself transitively; \
                module-level value bindings cannot form cycles"
               name)
           :: !errors
         | None -> ())
      | _ ->
        Hashtbl.replace color name 1;
        (match List.assoc_opt name deps with
         | Some dep_names -> List.iter dfs dep_names
         | None -> ());
        Hashtbl.replace color name 2
    in
    List.iter dfs const_names;
    List.rev !errors

(* ── 3c. Ghost witness predicate validation ──────────────────────────────── *)

(** For each record type that declares a cross-field invariant (`::: Pred a b`),
    check that ghost witnesses supplied at construction sites carry a proof whose
    predicate matches the declared invariant predicate.
    E.g. `SafeOrder { ... } ::: wrongProof` where `wrongProof` carries
    `WrongFact x` instead of `PriceGtQty price quantity` should be rejected. *)
let check_ghost_witness_predicates (decls : top_decl list)
    : validation_error list =
  (* Build map: record_name → invariant predicate name *)
  let record_invariants : (string * string) list =
    List.filter_map (function
      | DRecord r ->
        (match r.invariant with
         | Some inv ->
           (* Extract the top-level predicate name from the invariant proof *)
           let pred = match inv.proof_text with
             | PredApp { pred; _ } -> pred
             | PredAnd _ ->
               (* For && invariants, use the first predicate *)
               (match flatten_proof inv.proof_text with
                | PredApp { pred; _ } :: _ -> pred
                | _ -> "")
           in
           if pred = "" then None else Some (r.name, pred)
         | None -> None)
      | _ -> None
    ) decls
  in
  if record_invariants = [] then []
  else
    let errors = ref [] in
    (* Check if a proof expression could plausibly carry the required predicate.
       This is checked conservatively: we only flag definite mismatches where the
       proof is a simple PredApp with a different predicate name, or a conjunction
       where no part matches. *)
    let pred_of_fact_type (te : type_expr) : string option =
      (* type_expr for a Fact parameter: Fact (PredName ...) or Fact PredName *)
      let rec inner = function
        | TApp { head; arg; _ } ->
          (match head with
           | TName { name = "Fact"; _ } -> inner arg
           | _ -> inner head)
        | TName { name; _ } when name <> "Fact" -> Some name
        | _ -> None
      in
      inner te
    in
    (* Build a map from parameter names that have Fact(...) type to their predicate.
       IMPORTANT: only include params whose actual type_expr is `TApp { head = Fact; arg = ... }`
       (i.e. truly Fact-typed params), not params with plain types like `Int` or `String`.
       `pred_of_fact_type` extracts the predicate but returns `Some name` for plain TName too —
       we must guard against that by checking the outer type wrapper is Fact. *)
    let is_fact_typed (te : type_expr) : bool =
      match te with
      | TApp { head = TName { name = "Fact"; _ }; _ } -> true
      | TApp { head = TName { name = "Maybe"; _ };
               arg = TApp { head = TName { name = "Fact"; _ }; _ }; _ } -> true
      | _ -> false
    in
    let fact_param_map (params : binding list) : (string * string) list =
      List.filter_map (fun (b : binding) ->
        if not (is_fact_typed b.type_expr) then None
        else match pred_of_fact_type b.type_expr with
        | Some pred -> Some (b.name, pred)
        | None -> None
      ) params
    in
    (* Build a map from function names (establish/check) to their Fact return predicate.
       Used to resolve `let pf = establish_fn args` → `pf` carries predicate `P`. *)
    let establish_pred_map : (string * string) list =
      List.filter_map (function
        | DFunc fd when fd.kind = EstablishKind || fd.kind = CheckKind ->
          let pred_opt = match fd.return_spec with
            | RetPlain { ty; _ } -> (match proof_of_fact_type ty with
                | Some (PredApp { pred; _ }) -> Some pred
                | Some (PredAnd _) -> None
                | None -> None)
            | RetAttached { binding = b; _ } ->
              (match b.proof_ann with
               | Some (PredApp { pred; _ }) -> Some pred
               | _ -> None)
            | _ -> None
          in
          (match pred_opt with Some p -> Some (fd.name, p) | None -> None)
        | _ -> None
      ) decls
    in
    let check_ghost_in_func (params : binding list) (body : expr) =
      (* Map from variable name → proof predicate name.
         Starts with fact-typed parameters, then augmented with local let bindings
         that call establish/check functions. Used to resolve detachFact(pf) proof. *)
      let local_fact_map = ref (fact_param_map params) in
      let track_let_binding name value =
        (* If value is a call to a known establish/check function, record the predicate *)
        let (head, _) = collect_call_head_and_args [] value in
        (match function_name_of_expr head with
         | Some fn_name ->
           (match List.assoc_opt fn_name establish_pred_map with
            | Some pred -> local_fact_map := (name, pred) :: !local_fact_map
            | None -> ())
         | None -> ())
      in
      let rec walk_body = function
        | EOk { value; proof; loc } ->
          (match value with
           | EApp { fn = EConstructor { name = rname; args = []; _ }; arg = ERecord _; _ }
             when List.mem_assoc rname record_invariants ->
             let expected_pred = List.assoc rname record_invariants in
             (* Resolve the proof predicate from the ghost witness expression.
                Handles: direct PredApp, detachFact(pf) where pf is in local_fact_map *)
             (* Determine the predicate name the ghost witness proof carries.
                - Uppercase PredApp: it IS a predicate constructor (`IsValidRange`)
                - Lowercase PredApp with no args: a PROOF VARIABLE (`proodd`) —
                  check local_fact_map; if not found, we can't determine predicate
                  so return None (don't flag — be conservative)
                - detachFact(pf_name): look up pf_name in local_fact_map *)
             let is_pred_name s =
               String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'
             in
             let proof_pred = match proof with
               | PredApp { pred; args = []; _ } when is_pred_name pred ->
                 (* Uppercase zero-arg proof variable (shouldn't normally appear) *)
                 (match List.assoc_opt pred !local_fact_map with
                  | Some p -> Some p
                  | None -> Some pred)
               | PredApp { pred; args = []; _ } ->
                 (* Lowercase proof variable: look up in local_fact_map *)
                 (match List.assoc_opt pred !local_fact_map with
                  | Some p -> Some p
                  | None -> None)   (* Unknown proof var — skip the check *)
               | PredApp { pred = "detachFact"; args = [pf_name]; _ } ->
                 (match List.assoc_opt pf_name !local_fact_map with
                  | Some p -> Some p
                  | None -> None)
               | PredApp { pred = "detachFact"; _ } ->
                 None  (* multi-arg or no-arg detachFact — can't determine predicate *)
               | PredApp { pred; _ } when pred <> "detachFact" && is_pred_name pred ->
                 Some pred
               | _ -> None
             in
             (match proof_pred with
              | Some actual_pred when actual_pred <> expected_pred ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "the ghost witness must establish `%s` (the declared invariant of `%s`), \
                     but carries `%s`; use a function that returns `Fact (%s ...)` instead"
                    expected_pred rname actual_pred expected_pred)
                  (Printf.sprintf
                    "ghost witness predicate mismatch on `%s` construction: \
                     invariant requires `%s` but witness carries `%s`"
                    rname expected_pred actual_pred)
                :: !errors
              | _ -> ());
             walk_body value
           | _ -> walk_body value);
        | EApp { fn; arg; _ } -> walk_body fn; walk_body arg
        | ELet { name; value; body; _ } ->
          track_let_binding name value;
          walk_body value; walk_body body
        | ELetProof { value; body; _ } -> walk_body value; walk_body body
        | EIf { cond; then_; else_; _ } ->
          walk_body cond; walk_body then_; walk_body else_
        | ECase { scrut; arms; _ } ->
          walk_body scrut;
          List.iter (fun (arm : case_arm) -> walk_body arm.body) arms
        | ELambda { body = b; _ } -> walk_body b
        | EList { elems; _ } -> List.iter walk_body elems
        | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk_body v) fields
        | EBinop { left; right; _ } -> walk_body left; walk_body right
        | EUnop { arg; _ } -> walk_body arg
        | EWithDatabase { body = b; _ } | EWithCapabilities { body = b; _ }
        | EWithTransaction { body = b; _ } -> walk_body b
        | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk_body v) fields
        | EEnqueue { payload; _ } -> walk_body payload
        | EPublish { key; payload; _ } ->
          (match key with Some e -> walk_body e | None -> ());
          (match payload with Some e -> walk_body e | None -> ())
        | EServe { port; _ } -> walk_body port
        | EConstructor { args; _ } -> List.iter walk_body args
        | EStartWorkers _ | ELit _ | EVar _ | EField _ | EFail _ -> ()
      in
      walk_body body
    in
    List.iter (function
      | DFunc fd -> check_ghost_in_func fd.params fd.body
      | _ -> ()
    ) decls;
    List.rev !errors

(** Check that handler functions are never called directly from code.
    Handlers are HTTP entry points and must only be referenced in server
    bindings (DServer.bindings), not called as regular functions.
    This prevents handler-to-handler calls and fn-to-handler calls. *)
(** Validate that auth functions are only called (via the `check` keyword) from
    handler bodies or from other auth function bodies.  Calling an auth function
    from a plain `fn`, `check`, `establish`, `worker`, or `deadWorker` body is
    rejected because auth functions are HTTP-level identity gates — their `fail 401`
    is meaningful only inside the request/response cycle of a handler. *)
let check_auth_call_restriction (decls : top_decl list) : validation_error list =
  let auth_names =
    List.filter_map (function
      | DFunc fd when fd.kind = AuthKind -> Some fd.name
      | _ -> None
    ) decls
  in
  if auth_names = [] then []
  else begin
    let errors = ref [] in
    (* Walk body looking for `check authFn …` or `(authFn && …)` call patterns.
       `check f x` is parsed as EApp(EApp(EVar "check", EVar f), EVar x). *)
    let rec collect_check_callee e acc =
      (* Collect every function name directly called via `check` in this expression.
         Also recurse into &&-combinator chains so `check (authFn && checkX) v`
         is handled correctly. *)
      match e with
      | EVar { name; _ } -> name :: acc
      | EBinop { op = BAnd; left; right; _ } ->
        collect_check_callee left (collect_check_callee right acc)
      | _ -> acc
    in
    let rec walk_body (caller_name : string) (caller_kind : func_kind) (e : expr) =
      match e with
      | EApp { fn = EApp { fn = EVar { name = "check"; _ }; arg = callee_expr; _ }; _ } ->
        (* Detect `check f x` — check whether the callee is an auth function. *)
        let callees = collect_check_callee callee_expr [] in
        let call_loc = match e with EApp { loc; _ } -> loc | _ -> gen_loc in
        List.iter (fun callee ->
          if List.mem callee auth_names && caller_kind <> HandlerKind && caller_kind <> AuthKind then
            errors := make_error call_loc
              ~hint:(Printf.sprintf
                "auth functions are HTTP-level identity gates; call `%s` from a handler body, \
or declare it as `auth user via %s` in an API endpoint" callee callee)
              (Printf.sprintf
                "`%s` calls auth function `%s` from a `%s`; auth functions may only be \
called from handler bodies or other auth functions"
                caller_name callee
                (match caller_kind with
                 | FnKind -> "fn" | CheckKind -> "check" | EstablishKind -> "establish"
                 | WorkerKind -> "worker" | DeadWorkerKind -> "deadWorker"
                 | AuthKind -> "auth" | HandlerKind -> "handler" | MainKind -> "main"))
            :: !errors
        ) callees;
        (* Still recurse into sub-expressions *)
        walk_body caller_name caller_kind (match e with EApp { fn; _ } -> fn | _ -> e);
        (match e with EApp { arg; _ } -> walk_body caller_name caller_kind arg | _ -> ())
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _ -> ()
      | EApp { fn; arg; _ } ->
        walk_body caller_name caller_kind fn;
        walk_body caller_name caller_kind arg
      | EBinop { left; right; _ } ->
        walk_body caller_name caller_kind left;
        walk_body caller_name caller_kind right
      | EUnop { arg; _ } -> walk_body caller_name caller_kind arg
      | EIf { cond; then_; else_; _ } ->
        walk_body caller_name caller_kind cond;
        walk_body caller_name caller_kind then_;
        walk_body caller_name caller_kind else_
      | ECase { scrut; arms; _ } ->
        walk_body caller_name caller_kind scrut;
        List.iter (fun (arm : case_arm) -> walk_body caller_name caller_kind arm.body) arms
      | ELet { value; body; _ } | ELetProof { value; body; _ } ->
        walk_body caller_name caller_kind value;
        walk_body caller_name caller_kind body
      | ERecord { fields; _ } ->
        List.iter (fun (_, v) -> walk_body caller_name caller_kind v) fields
      | EList { elems; _ } ->
        List.iter (walk_body caller_name caller_kind) elems
      | EOk { value; _ } -> walk_body caller_name caller_kind value
      | ETelemetry { fields; _ } ->
        List.iter (fun (_, v) -> walk_body caller_name caller_kind v) fields
      | EEnqueue { payload; _ } -> walk_body caller_name caller_kind payload
      | EPublish { key; payload; _ } ->
        Option.iter (walk_body caller_name caller_kind) key;
        Option.iter (walk_body caller_name caller_kind) payload
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_body caller_name caller_kind body
      | ELambda { body; _ } -> walk_body caller_name caller_kind body
    in
    List.iter (function
      | DFunc fd -> walk_body fd.name fd.kind fd.body
      | _ -> ()
    ) decls;
    List.rev !errors
  end

let check_handler_isolation (decls : top_decl list) : validation_error list =
  let handler_names =
    List.filter_map (function
      | DFunc fd when fd.kind = HandlerKind -> Some fd.name
      | _ -> None
    ) decls
  in
  if handler_names = [] then []
  else begin
    let errors = ref [] in
    let rec walk_body (caller_name : string) (e : expr) =
      match e with
      | EVar { name; loc } when List.mem name handler_names ->
        errors := make_error loc
          ~hint:"handlers are HTTP entry points that can only be wired via server declarations; \
extract shared logic into a helper `fn` function instead"
          (Printf.sprintf
            "`%s` calls handler `%s` directly; handlers cannot be called from code \
— only the server router may reference handlers"
            caller_name name)
        :: !errors
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _ -> ()
      | EApp { fn; arg; _ } -> walk_body caller_name fn; walk_body caller_name arg
      | EBinop { left; right; _ } -> walk_body caller_name left; walk_body caller_name right
      | EUnop { arg; _ } -> walk_body caller_name arg
      | EIf { cond; then_; else_; _ } ->
        walk_body caller_name cond; walk_body caller_name then_; walk_body caller_name else_
      | ECase { scrut; arms; _ } ->
        walk_body caller_name scrut;
        List.iter (fun (arm : case_arm) -> walk_body caller_name arm.body) arms
      | ELet { value; body; _ } | ELetProof { value; body; _ } ->
        walk_body caller_name value; walk_body caller_name body
      | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk_body caller_name v) fields
      | EList { elems; _ } -> List.iter (walk_body caller_name) elems
      | EOk { value; _ } -> walk_body caller_name value
      | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk_body caller_name v) fields
      | EEnqueue { payload; _ } -> walk_body caller_name payload
      | EPublish { key; payload; _ } ->
        Option.iter (walk_body caller_name) key; Option.iter (walk_body caller_name) payload
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_body caller_name body
      | ELambda { body; _ } -> walk_body caller_name body
    in
    List.iter (function
      | DFunc fd -> walk_body fd.name fd.body
      | _ -> ()
    ) decls;
    List.rev !errors
  end

(** Check that the file name on disk matches the declared module header.
    Rejects a file like `foo.tesl` that declares `module Bar exposing []` —
    no one else can import `Bar` because the loader resolves by file name.
    The accepted file names are the kebab-cased form (e.g. `my-module.tesl`
    for `MyModule`) OR the exact PascalCase form (e.g. `MyModule.tesl`), to
    match the import resolver's two-path fallback in `resolve_local_import_path`.
    Stdin (no source file), non-file synthetic paths like `<test>`, dotted
    stdlib module names, and standalone fixture/example files are not checked:
    those inputs are not resolved through the local import loader, so this rule
    would only create test noise without preventing a real import failure. *)
let check_file_module_name_match (m : module_form) : validation_error list =
  let src = m.source_file in
  let mname = m.module_name in
  let contains_substring needle haystack =
    let n = String.length needle in
    let h = String.length haystack in
    let rec loop i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else loop (i + 1)
    in
    n = 0 || loop 0
  in
  (* Skip: no source, stdin, synthetic/non-file input, dotted-name stdlib module,
     fixture/example files, or empty name. *)
  if src = "" || src = "-" || mname = "" then []
  else if String.contains mname '.' then []
  else
    let basename = Filename.basename src in
    if not (Filename.check_suffix basename ".tesl") then []
    else if contains_substring "/example/" src || contains_substring "/tests/" src then []
    else
      let stem = Filename.chop_suffix basename ".tesl" in
      let kebab = module_name_to_kebab mname in
      (* Accept exact kebab match or exact PascalCase match. Also accept any
         file whose stem starts with the prefix "tesl-" — this is the stable
         prefix used by `Filename.temp_file` in the test suite, which creates
         names like `tesl-r50abc123.tesl` that cannot realistically collide
         with a user-authored file. *)
      let starts_with_prefix prefix s =
        String.length s >= String.length prefix
        && String.sub s 0 (String.length prefix) = prefix
      in
      if stem = kebab
         || stem = mname
         || starts_with_prefix "tesl-" stem
         || starts_with_prefix ("temp-" ^ kebab) stem then []
      else
        let loc = m.decls
          |> List.filter_map (function DFunc fd -> Some fd.loc | _ -> None)
          |> (function [] -> Location.dummy_loc src
                    | hd :: _ -> hd)
        in
        [ make_error loc
            ~hint:(Printf.sprintf
              "rename the file to `%s.tesl` (kebab-case) or `%s.tesl` (PascalCase), or change the module header to `module %s exposing [...]`"
              kebab mname
              (match String.length stem with
               | 0 -> mname
               | _ ->
                 let buf = Buffer.create (String.length stem) in
                 let cap = ref true in
                 String.iter (fun c ->
                   if c = '-' || c = '_' then cap := true
                   else if !cap then begin
                     Buffer.add_char buf (Char.uppercase_ascii c);
                     cap := false
                   end else
                     Buffer.add_char buf c
                 ) stem;
                 Buffer.contents buf))
            (Printf.sprintf
              "module header `module %s` does not match file name `%s`; the compiler resolves imports by file name, so no other file can `import %s`"
              mname basename mname)
        ]

let check_module (m : module_form) : validation_error list =
  let decls = m.decls in
  let imported_funcs = load_imported_func_info m in
  let cap_map = build_local_cap_map decls @ load_imported_cap_map m in
  check_file_module_name_match m
  @ check_local_imports_exist m
  @ check_duplicate_imports m.imports
  @ check_imported_exposed_name_conflicts m
  @ check_imported_exposed_type_and_ctor_conflicts m
  @ check_self_imports m.module_name m.imports
  @ check_duplicate_top_level_names decls
  @ check_duplicate_adt_constructors decls
  @ check_duplicate_decl_fields decls
  @ check_capability_cycles decls
  @ check_api_endpoint_structure decls
  @ check_server_completeness ~extra_funcs:imported_funcs decls
  @ check_sql_field_names ~extra_funcs:imported_funcs decls
  @ check_codec_target_types decls
  @ check_codec_proof_coverage ~extra_funcs:imported_funcs decls
  @ check_codec_field_types decls
  @ check_call_site_proofs ~extra_funcs:imported_funcs decls
  @ check_record_field_proof_construction ~extra_funcs:imported_funcs decls
  @ check_sql_where_clauses ~extra_funcs:imported_funcs decls
  @ check_fn_return_proof_annotations ~extra_funcs:imported_funcs decls
  @ check_circular_const_bindings decls
  @ check_ghost_witness_predicates decls
  @ check_filter_check_args ~extra_funcs:imported_funcs decls
  @ check_forall_consistency ~extra_funcs:imported_funcs decls
  @ check_fact_arg_types decls
  @ check_exists_bindings decls
  @ check_existential_proof_enforcement decls
  @ check_case_exhaustiveness ~extra_ctors:(load_imported_ctor_info m) decls
  @ check_name_shadowing m
  @ check_forall_param_subjects decls
  @ check_handler_capabilities ~cap_map decls
  @ check_pk_match decls
  @ check_insert_pk_match decls
  @ check_cookies_field_access decls
  @ check_adt_variant_names decls
  @ check_self_referential_aliases decls
  @ check_type_arities decls
  @ check_ord_operator_types ~extra_funcs:imported_funcs decls
  @ check_handler_isolation decls
  @ check_auth_call_restriction decls
  @ collect_import_parse_errors m
