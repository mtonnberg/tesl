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
  | TString
  | TBool
  | TUnit
  | TNewtype of newtype_info
  | TRecord of record_info
  | TAdt of adt_info
  | TCheck of go_type
  | TFailure

and newtype_info = {
  tesl_name : string;
  go_name : string;
  base : go_type;
  loc : Location.loc;
}

and record_info = {
  rec_tesl_name : string;
  rec_go_name : string;
  mutable rec_fields : (string * go_type) list;
  rec_loc : Location.loc;
}

(* A Tesl ADT becomes one flat Go value struct: an enum tag plus each variant's
   payload under a variant-qualified field name.  A tag keeps the emitted `switch`
   checkable by the `exhaustive` linter, which a Go type switch would not be. *)
and adt_info = {
  adt_tesl_name : string;
  adt_go_name : string;
  adt_tag_type : string;
  mutable adt_variants : variant_info list;
  adt_loc : Location.loc;
}

and variant_info = {
  var_ctor : string;
  var_tag : string;
  mutable var_fields : (string * go_type) list;
  var_loc : Location.loc;
}

type signature = {
  params : go_type list;
  result : go_type;
  go_name : string;
}

exception Unsupported of emit_error

let unsupported loc fmt =
  Printf.ksprintf (fun message -> raise (Unsupported { loc; message })) fmt

let sanitize_suffix name =
  let b = Buffer.create (String.length name) in
  String.iter (fun c ->
    let valid =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || c = '_' || (c >= '0' && c <= '9')
    in
    if valid then Buffer.add_char b c
    else Buffer.add_string b (Printf.sprintf "_x%02x_" (Char.code c))) name;
  Buffer.contents b

let sanitize_ident name =
  let b = Buffer.create (String.length name + 8) in
  Buffer.add_string b "tesl_";
  String.iter (fun c ->
    let valid =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || c = '_' || (c >= '0' && c <= '9')
    in
    if valid then Buffer.add_char b c
    else Buffer.add_string b (Printf.sprintf "_x%02x_" (Char.code c))) name;
  Buffer.contents b

let exported_ident name =
  String.capitalize_ascii (sanitize_ident name)

let package_name name =
  let b = Buffer.create (String.length name) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    then Buffer.add_char b (Char.lowercase_ascii c)) name;
  let value = Buffer.contents b in
  "teslmod" ^ value

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
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } ->
    unsupported loc "Go backend newtype base `%s` is not a direct scalar type" name
  | TVar { name; loc } -> unsupported loc "Go backend does not support type variable `%s` yet" name
  | TApp { loc; _ } -> unsupported loc "Go backend does not support applied types yet"
  | TFun { loc; _ } -> unsupported loc "Go backend does not support function values yet"
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

(** Named nominal types the emitter can resolve: scalar newtypes and records. *)
type type_table = {
  newtypes : (string, newtype_info) Hashtbl.t;
  records : (string, record_info) Hashtbl.t;
  adts : (string, adt_info) Hashtbl.t;
}

let type_of_type_expr types = function
  | TName { name = "Int"; _ } -> TInt
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } ->
    (match Hashtbl.find_opt types.newtypes name, Hashtbl.find_opt types.records name,
           Hashtbl.find_opt types.adts name with
     | Some info, _, _ -> TNewtype info
     | None, Some info, _ -> TRecord info
     | None, None, Some info -> TAdt info
     | None, None, None -> unsupported loc "Go backend does not support type `%s` yet" name)
  | TVar { name; loc } -> unsupported loc "Go backend does not support type variable `%s` yet" name
  | TApp { loc; _ } -> unsupported loc "Go backend does not support applied types yet"
  | TFun { loc; _ } -> unsupported loc "Go backend does not support function values yet"
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

let type_of_return_spec types = function
  | RetPlain { ty; _ } -> type_of_type_expr types ty
  | RetAttached { binding; _ } -> TCheck (type_of_type_expr types binding.type_expr)
  | RetNamedPack { loc; _ }
  | RetForAll { loc; _ }
  | RetMaybeForAll { loc; _ }
  | RetMaybeAttached { loc; _ }
  | RetSetForAll { loc; _ }
  | RetMaybeSetForAll { loc; _ }
  | RetForAllDictValues { loc; _ }
  | RetForAllDictKeys { loc; _ }
  | RetExists { loc; _ } ->
    unsupported loc "Go backend does not support proof-bearing return types yet"

let rec go_type = function
  | TInt -> "teslrt.Int"
  | TString -> "string"
  | TBool -> "bool"
  | TUnit -> "struct{}"
  | TNewtype info -> info.go_name
  | TRecord info -> info.rec_go_name
  | TAdt info -> info.adt_go_name
  | TCheck ty -> Printf.sprintf "teslrt.Check[%s]" (go_type ty)
  | TFailure -> invalid_arg "Go failure has no standalone type"

let record_field_go_name = exported_ident

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
let rec equal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "teslrt.Equal(%s, %s)" left right
  | TString | TBool | TUnit -> Printf.sprintf "(%s == %s)" left right
  | TNewtype info ->
    equal_expr info.base (Printf.sprintf "(%s).teslValue" left)
      (Printf.sprintf "(%s).teslValue" right)
  | TRecord info ->
    (match info.rec_fields with
     | [] -> "true"
     | fields ->
       let parts = List.map (fun (name, field_ty) ->
         let field = record_field_go_name name in
         equal_expr field_ty (Printf.sprintf "(%s).%s" left field)
           (Printf.sprintf "(%s).%s" right field)) fields in
       "(" ^ String.concat " && " parts ^ ")")
  (* Per-variant payload comparison lives in a generated method: inlining it would
     duplicate the whole tag switch at every comparison site. *)
  | TAdt _ -> Printf.sprintf "(%s).TeslEqual(%s)" left right
  | TCheck _ | TFailure -> invalid_arg "Go check results require explicit test handling"

let rec unequal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "!teslrt.Equal(%s, %s)" left right
  | TString | TBool | TUnit -> Printf.sprintf "(%s != %s)" left right
  | TNewtype info ->
    unequal_expr info.base (Printf.sprintf "(%s).teslValue" left)
      (Printf.sprintf "(%s).teslValue" right)
  | TRecord info ->
    (* De Morgan is applied here rather than negating the conjunction: emitted
       `!(a && b)` is a golangci-lint finding (staticcheck QF1001). *)
    (match info.rec_fields with
     | [] -> "false"
     | fields ->
       let parts = List.map (fun (name, field_ty) ->
         let field = record_field_go_name name in
         unequal_expr field_ty (Printf.sprintf "(%s).%s" left field)
           (Printf.sprintf "(%s).%s" right field)) fields in
       "(" ^ String.concat " || " parts ^ ")")
  | TAdt _ -> Printf.sprintf "!(%s).TeslEqual(%s)" left right
  | TCheck _ | TFailure -> invalid_arg "Go check results require explicit test handling"

let rec ordered_expr ty op left right =
  match ty with
  | TInt -> Printf.sprintf "(teslrt.Compare(%s, %s) %s 0)" left right op
  | TString -> Printf.sprintf "(%s %s %s)" left op right
  | TNewtype info ->
    ordered_expr info.base op (Printf.sprintf "(%s).teslValue" left)
      (Printf.sprintf "(%s).teslValue" right)
  | TBool | TUnit | TRecord _ | TAdt _ | TCheck _ | TFailure ->
    invalid_arg "Go ordering requires an ordered scalar type"

let rec supports_ordering = function
  | TInt | TString -> true
  | TNewtype info -> supports_ordering info.base
  | TBool | TUnit | TRecord _ | TAdt _ | TCheck _ | TFailure -> false

let record_info_of_signature signatures name =
  match Hashtbl.find_opt signatures name with
  | Some { result = TRecord info; _ } -> Some info
  | _ -> None

let adt_tag_field = "teslTag"

let variant_field_go_name variant name =
  exported_ident (variant.var_ctor ^ "_" ^ name)

let find_variant info ctor =
  List.find_opt (fun variant -> variant.var_ctor = ctor) info.adt_variants

(* Every constructor is registered in the signature table under its own name, so a
   constructor application resolves without knowing its ADT up front. *)
let adt_ctor_of_signature signatures name =
  match Hashtbl.find_opt signatures name with
  | Some { result = TAdt info; _ } ->
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

let rec type_of_expr signatures env expr =
  match expr with
  | ELit { lit = LInt _ | LBigInt _; _ } -> TInt
  | ELit { lit = LString _; _ } -> TString
  | ELit { lit = LBool _; _ } -> TBool
  | ELit { lit = LFloat _; loc } ->
    unsupported loc "Go backend does not support Float yet"
  | ELit { lit = LInterp segments; _ } ->
    List.iter (function
      | ILiteral _ -> ()
      | IExpr expr ->
        (match type_of_expr signatures env expr with
         | TString | TInt | TBool -> ()
         | _ -> unsupported (Checker.expr_loc expr)
           "Go backend interpolation supports String, Int, and Bool only")) segments;
    TString
  | EVar { name; loc } ->
    (* A bare function name is a function VALUE, which the Go subset has no
       representation for.  Emitting a call here would diverge from the Racket
       backend, which hands back a procedure. *)
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some ty, _ -> ty
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> lookup_env loc name env)
  | EConstructor { name = "True" | "False"; args = []; _ } -> TBool
  | EConstructor { name = "Unit"; args = []; _ } -> TUnit
  | EConstructor { name; args; loc } when adt_ctor_of_signature signatures name <> None ->
    let info, variant = match adt_ctor_of_signature signatures name with
      | Some pair -> pair
      | None -> assert false
    in
    check_variant_args signatures env loc info variant args;
    TAdt info
  | EConstructor { name; args; loc } ->
    (match Hashtbl.find_opt signatures name with
     | Some { params = [base]; result = (TNewtype _ as result); _ } ->
       (match args with
        | [arg] when type_of_expr signatures env arg = base -> result
        | [_] -> unsupported loc "Go backend newtype constructor `%s` argument type mismatch" name
        | _ -> unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
     | _ -> unsupported loc "Go backend does not support constructor `%s` yet" name)
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
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
       check_variant_args signatures env loc info variant (constructor_args @ args);
       TAdt info
     | EVar { name = "check"; _ } ->
       (match args with
        | EVar { name; _ } :: call_args ->
          (match Hashtbl.find_opt signatures name with
            | Some { params; result = TCheck result; _ } ->
             if List.length params <> List.length call_args then
               unsupported loc "Go backend requires a fully-applied check `%s`" name;
             List.iter2 (fun arg want ->
               if type_of_expr signatures env arg <> want then
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
         | _ -> unsupported loc "Go backend does not support constructor `%s` yet" name)
      | EVar { name; _ } ->
       (match Hashtbl.find_opt signatures name with
        | None -> unsupported loc "Go backend cannot resolve function `%s`" name
        | Some signature ->
          let args = normalize_call_args signature.params args in
          if List.length args <> List.length signature.params then
            unsupported loc "Go backend requires a fully-applied call to `%s`" name;
          List.iter2 (fun arg want ->
            let got = type_of_expr signatures env arg in
            if got <> want then unsupported (Checker.expr_loc arg)
              "Go backend call to `%s` has an unsupported argument type" name)
            args signature.params;
          signature.result)
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  | EBinop { op; left; right; loc; _ } ->
    let left_ty = type_of_expr signatures env left in
    let right_ty = type_of_expr signatures env right in
    if left_ty <> right_ty then unsupported loc "Go backend binary operands have different types";
    (match op with
     | BAdd | BSub | BMul | BDiv | BMod ->
       if left_ty <> TInt then unsupported loc "Go backend arithmetic requires Int";
       TInt
     | BConcat ->
       if left_ty <> TString then unsupported loc "Go backend ++ requires String";
       TString
     | BAnd | BOr ->
       if left_ty <> TBool then unsupported loc "Go backend boolean operator requires Bool";
       TBool
     | BEq | BNeq -> TBool
      | BLt | BLe | BGt | BGe ->
        if not (supports_ordering left_ty) then
          unsupported loc "Go backend ordering supports Int, String, and their scalar newtypes only";
        TBool)
  | EUnop { op; arg; loc } ->
    let arg_ty = type_of_expr signatures env arg in
    (match op with
     | UNeg -> if arg_ty <> TInt then unsupported loc "Go backend unary - requires Int"; TInt
     | UNot -> if arg_ty <> TBool then unsupported loc "Go backend ! requires Bool"; TBool)
  | EIf { cond; then_; else_; loc } ->
    if type_of_expr signatures env cond <> TBool then
      unsupported loc "Go backend if condition must be Bool";
    let then_ty = type_of_expr signatures env then_ in
    let else_ty = type_of_expr signatures env else_ in
    (match then_ty, else_ty with
     | TFailure, TFailure -> TFailure
     | TFailure, ty | ty, TFailure -> ty
     | left, right when left = right -> left
     | _ -> unsupported loc "Go backend if branches have different types")
  | ELet { name; value; body; _ } ->
    let value_ty = type_of_expr signatures env value in
    type_of_expr signatures ((name, value_ty) :: env) body
  | EField { obj; field; loc } ->
    (match type_of_expr signatures env obj, field with
     | TNewtype info, "value" -> info.base
     | TNewtype info, _ ->
       unsupported loc "Go backend newtype `%s` has no field `%s`" info.tesl_name field
     | TRecord info, _ -> record_field_type loc info field
     | _ -> unsupported loc "Go backend does not support field `%s` yet" field)
  | ECase { scrut; arms; loc } ->
    let info = match type_of_expr signatures env scrut with
      | TAdt info -> info
      | _ -> unsupported loc "Go backend supports `case` over a module ADT only"
    in
    if arms = [] then unsupported loc "Go backend requires at least one `case` arm";
    let arm_types = List.map (fun (arm : case_arm) ->
      let bindings = pattern_bindings signatures loc info arm.pattern in
      let arm_env = bindings @ env in
      (match arm.guard with
       | None -> ()
       | Some guard ->
         if type_of_expr signatures arm_env guard <> TBool then
           unsupported (Checker.expr_loc guard) "Go backend `case` guard must be Bool");
      type_of_expr signatures arm_env arm.body) arms in
    List.fold_left (fun acc ty ->
      match acc, ty with
      | TFailure, ty | ty, TFailure -> ty
      | left, right when left = right -> left
      | _ -> unsupported loc "Go backend `case` arms have different types")
      TFailure arm_types
  | ELetProof { loc; _ } -> unsupported loc "Go backend does not support proof decomposition yet"
  | ERecord { type_hint = Some name; fields; loc } ->
    (match record_info_of_signature signatures name with
     | Some info -> check_record_literal signatures env loc info fields; TRecord info
     | None -> unsupported loc "Go backend does not support record type `%s` yet" name)
  | ERecord { type_hint = None; loc; _ } ->
    unsupported loc "Go backend cannot infer the record type of this literal"
  | EList { loc; _ } -> unsupported loc "Go backend does not support lists yet"
  | EOk { value; _ } -> TCheck (type_of_expr signatures env value)
  | EFail { message; loc; _ } ->
    if type_of_expr signatures env message <> TString then
      unsupported loc "Go backend check failure message must be String";
    TFailure
  | ETelemetry { loc; _ } | EEnqueue { loc; _ } | EPublish { loc; _ }
  | EStartWorkers { loc; _ } | ECacheGet { loc; _ } | ECacheSet { loc; _ }
  | ECacheDelete { loc; _ } | ECacheInvalidate { loc; _ } | ESendEmail { loc; _ }
  | EStartEmailWorker { loc; _ } | EWithDatabase { loc; _ }
  | EWithCapabilities { loc; _ } | EWithTransaction { loc; _ } | EServe { loc; _ } ->
    unsupported loc "Go backend does not support effects yet"
  | ELambda { loc; _ } -> unsupported loc "Go backend does not support lambdas yet"
  | ERuntimeCall { loc; _ } ->
    unsupported loc "internal error: Go backend received Racket-specific desugaring"

and check_variant_args signatures env loc info variant args =
  let wanted = List.length variant.var_fields in
  if List.length args <> wanted then
    unsupported loc "Go backend requires constructor `%s.%s` applied to %d argument(s)"
      info.adt_tesl_name variant.var_ctor wanted;
  List.iter2 (fun arg (name, want) ->
    let got = type_of_expr signatures env arg in
    if got <> want then
      unsupported (Checker.expr_loc arg)
        "Go backend constructor field `%s.%s` has an unsupported value type"
        variant.var_ctor name) args variant.var_fields

(* Returns the bindings a pattern introduces, rejecting every pattern shape the
   emitter cannot lower rather than binding it to the wrong payload field. *)
and pattern_bindings _signatures _loc info pattern =
  match pattern with
  | PWild -> []
  | PVar name -> [name, TAdt info]
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
         let _, field_ty = List.nth variant.var_fields index in
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
      let got = type_of_expr signatures env value in
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

let rec emit_expr ?expected ?(indent="") signatures env expr =
  let emit = emit_expr ~indent signatures env in
  match expr with
  | ELit { lit = LInt value; _ } -> Printf.sprintf "teslrt.FromInt64(%d)" value
  | ELit { lit = LBigInt value; _ } ->
    Printf.sprintf "teslrt.MustParseDecimal(%s)" (go_quote value)
  | ELit { lit = LString value; _ } -> go_quote value
  | ELit { lit = LBool value; _ } -> if value then "true" else "false"
  | ELit { lit = LFloat _; loc } ->
    unsupported loc "Go backend cannot emit Float yet"
  | ELit { lit = LInterp segments; _ } -> emit_interp ~indent signatures env segments
  | EVar { name; loc } ->
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some _, _ -> sanitize_ident name
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> sanitize_ident name)
  | EConstructor { name = "True"; args = []; _ } -> "true"
  | EConstructor { name = "False"; args = []; _ } -> "false"
  | EConstructor { name = "Unit"; args = []; _ } -> "struct{}{}"
  | EConstructor { name; args; _ } when adt_ctor_of_signature signatures name <> None ->
    let info, variant = match adt_ctor_of_signature signatures name with
      | Some pair -> pair
      | None -> assert false
    in
    ignore (type_of_expr signatures env expr);
    emit_variant_literal ~indent signatures env info variant args
  | EConstructor { name; args; loc } ->
    (match Hashtbl.find_opt signatures name with
     | Some { params = [_]; result = (TNewtype _ as result); _ } ->
       ignore (type_of_expr signatures env expr);
       (match args with
        | [arg] ->
          Printf.sprintf "%s{teslValue: %s}" (go_type result) (emit arg)
        | _ -> unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
     | _ -> unsupported loc "Go backend cannot emit constructor `%s`" name)
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
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
       let info, variant = match adt_ctor_of_signature signatures name with
         | Some pair -> pair
         | None -> assert false
       in
       ignore (type_of_expr signatures env app);
       emit_variant_literal ~indent signatures env info variant (constructor_args @ args)
     | EVar { name = "check"; _ } ->
       (match args with
        | EVar { name; _ } :: call_args ->
          ignore (type_of_expr signatures env app);
           let signature = match Hashtbl.find_opt signatures name with
             | Some signature -> signature
             | None -> unsupported loc "Go backend cannot resolve check `%s`" name
           in
           Printf.sprintf "teslrt.MustCheck(%s(%s))" signature.go_name
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
              Printf.sprintf "%s{teslValue: %s}" (go_type result) (emit arg)
            | _ -> assert false)
         | _ -> unsupported loc "Go backend cannot emit constructor `%s`" name)
      | EVar { name; _ } ->
       let signature = match Hashtbl.find_opt signatures name with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" name
       in
       let args = normalize_call_args signature.params args in
       ignore (type_of_expr signatures env app);
       Printf.sprintf "%s(%s)" signature.go_name
          (String.concat ", " (List.map emit args))
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  | EBinop { op; left; right; _ } ->
    let ty = type_of_expr signatures env left in
    let emitted_left = emit left in
    let emitted_right = emit right in
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
     | BAdd -> Printf.sprintf "teslrt.Add(%s, %s)" emitted_left emitted_right
     | BSub -> Printf.sprintf "teslrt.Sub(%s, %s)" emitted_left emitted_right
     | BMul -> Printf.sprintf "teslrt.Mul(%s, %s)" emitted_left emitted_right
     | BDiv -> Printf.sprintf "teslrt.MustQuo(%s, %s)" emitted_left emitted_right
     | BMod -> Printf.sprintf "teslrt.MustRem(%s, %s)" emitted_left emitted_right
     | BConcat -> Printf.sprintf "(%s + %s)" emitted_left emitted_right
     | BAnd -> Printf.sprintf "(%s && %s)" emitted_left emitted_right
     | BOr -> Printf.sprintf "(%s || %s)" emitted_left emitted_right
     | BEq -> equal_expr ty emitted_left emitted_right
     | BNeq -> unequal_expr ty emitted_left emitted_right
     | BLt | BLe | BGt | BGe ->
       let op = match op with BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">=" | _ -> assert false in
       ordered_expr ty op emitted_left emitted_right)
  | EUnop { op = UNeg; arg; _ } -> Printf.sprintf "teslrt.Neg(%s)" (emit arg)
  | EUnop { op = UNot; arg; _ } -> emit_negated ~indent signatures env arg
  | EIf _ as if_expr -> emit_if_expr ?expected ~indent signatures env if_expr
  | ELet _ as let_expr -> emit_let_expr ?expected ~indent signatures env let_expr
  | EField { obj; field; _ } ->
    (match type_of_expr signatures env obj with
     | TNewtype _ ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "(%s).teslValue" (emit obj)
     | TRecord _ ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "(%s).%s" (emit obj) (record_field_go_name field)
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
    emit_case_statements ~indent:(indent ^ "\t") signatures env buffer
      (fun arm_env body_indent body ->
        Printf.bprintf buffer "%sreturn %s\n" body_indent
          (emit_expr ~expected:result ~indent:body_indent signatures arm_env body))
      scrut arms;
    Printf.sprintf "(func() %s {\n%s%s}())" (go_type result) (Buffer.contents buffer) indent
  | ELetProof { loc; _ }
  | ERecord { loc; _ } | EList { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"
  | EOk { value; _ } -> Printf.sprintf "teslrt.Accept(%s)" (emit value)
  | EFail { status; message; loc } ->
    (match expected with
     | Some (TCheck result) ->
       Printf.sprintf "teslrt.Reject[%s](%d, %s)" (go_type result) status
          (emit message)
     | _ -> unsupported loc "Go backend can emit fail only in a check tail")
  | ETelemetry { loc; _ } | EEnqueue { loc; _ } | EPublish { loc; _ }
  | EStartWorkers { loc; _ } | ECacheGet { loc; _ } | ECacheSet { loc; _ }
  | ECacheDelete { loc; _ } | ECacheInvalidate { loc; _ } | ESendEmail { loc; _ }
  | EStartEmailWorker { loc; _ } | EWithDatabase { loc; _ }
  | EWithCapabilities { loc; _ } | EWithTransaction { loc; _ } | EServe { loc; _ }
  | ELambda { loc; _ } | ERuntimeCall { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"

(* What one arm has to test and bind, resolved once so the type rule and the
   emitter cannot disagree about which payload field a binder refers to. *)
and pattern_plan info pattern =
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
      let field_name, field_ty = List.nth variant.var_fields index in
      match sub with
      | PVar name -> [name, variant_field_go_name variant field_name, field_ty]
      | _ -> []) fields) in
    Some variant, None, bindings
  | PLit _ -> invalid_arg "case pattern validated before emission"

(* `case` lowers to statements, not an expression: a tag switch when no arm has a
   guard (so the emitted switch stays checkable), an ordered if-chain when a guard
   can make an arm fall through to the next one. *)
and emit_case_statements ?(indent="") signatures env buffer emit_body scrut arms =
  let info = match type_of_expr signatures env scrut with
    | TAdt info -> info
    | _ -> invalid_arg "case scrutinee validated before emission"
  in
  let scrut_name = Printf.sprintf "teslScrut%d" (String.length indent) in
  let inner = indent ^ "\t" in
  Printf.bprintf buffer "%s{\n" indent;
  Printf.bprintf buffer "%s%s := %s\n" inner scrut_name
    (emit_expr ~expected:(TAdt info) ~indent:inner signatures env scrut);
  let plans = List.map (fun (arm : case_arm) -> arm, pattern_plan info arm.pattern) arms in
  let guarded = List.exists (fun (arm : case_arm) -> arm.guard <> None) arms in
  let bind_arm body_indent (whole, bindings) =
    let env = ref env in
    (match whole with
     | None -> ()
     | Some name ->
       Printf.bprintf buffer "%s%s := %s\n%s_ = %s\n" body_indent (sanitize_ident name)
         scrut_name body_indent (sanitize_ident name);
       env := (name, TAdt info) :: !env);
    List.iter (fun (name, go_field, field_ty) ->
      Printf.bprintf buffer "%s%s := %s.%s\n%s_ = %s\n" body_indent (sanitize_ident name)
        scrut_name go_field body_indent (sanitize_ident name);
      env := (name, field_ty) :: !env) bindings;
    !env
  in
  let unreachable_default body_indent =
    Printf.bprintf buffer "%spanic(\"unreachable: checker guarantees case exhaustiveness\")\n"
      body_indent
  in
  if guarded then begin
    (* First match wins, so an unguarded catch-all ends the chain: anything after
       it is dead code, which `go vet` rejects. *)
    let rec chain = function
      | [] -> unreachable_default inner
      | ((arm : case_arm), (variant, whole, bindings)) :: rest ->
        let body_indent = inner ^ "\t" in
        (match variant with
         | Some variant ->
           Printf.bprintf buffer "%sif %s.%s == %s {\n" inner scrut_name adt_tag_field variant.var_tag
         | None -> Printf.bprintf buffer "%s{\n" inner);
        let arm_env = bind_arm body_indent (whole, bindings) in
        (match arm.guard with
         | None -> emit_body arm_env body_indent arm.body
         | Some guard ->
           Printf.bprintf buffer "%sif %s {\n" body_indent
             (strip_outer_parens (emit_expr ~indent:body_indent signatures arm_env guard));
           emit_body arm_env (body_indent ^ "\t") arm.body;
           Printf.bprintf buffer "%s}\n" body_indent);
        Printf.bprintf buffer "%s}\n" inner;
        if variant = None && arm.guard = None then () else chain rest
    in
    chain plans
  end else begin
    (* Every tag is named explicitly — a Tesl catch-all becomes the list of tags no
       earlier arm covered — so the `exhaustive` linter can still verify the switch
       (`default:` alone would blind it under default-signifies-exhaustive: false). *)
    let all_tags = List.map (fun variant -> variant.var_tag) info.adt_variants in
    Printf.bprintf buffer "%sswitch %s.%s {\n" inner scrut_name adt_tag_field;
    let containment_default () =
      Printf.bprintf buffer "%sdefault:\n" inner;
      unreachable_default (inner ^ "\t")
    in
    let rec cases seen = function
      | [] -> containment_default ()
      | ((arm : case_arm), (variant, whole, bindings)) :: rest ->
        (match variant with
         | Some variant ->
           if List.mem variant.var_tag seen then cases seen rest
           else begin
             Printf.bprintf buffer "%scase %s:\n" inner variant.var_tag;
             let arm_env = bind_arm (inner ^ "\t") (whole, bindings) in
             emit_body arm_env (inner ^ "\t") arm.body;
             cases (variant.var_tag :: seen) rest
           end
         | None ->
           let uncovered = List.filter (fun tag -> not (List.mem tag seen)) all_tags in
           if uncovered = [] then containment_default ()
           else begin
             Printf.bprintf buffer "%scase %s:\n" inner (String.concat ", " uncovered);
             let arm_env = bind_arm (inner ^ "\t") (whole, bindings) in
             emit_body arm_env (inner ^ "\t") arm.body;
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

and emit_variant_literal ?(indent="") signatures env info variant args =
  let parts = List.map2 (fun arg (name, field_ty) ->
    Printf.sprintf "%s: %s" (variant_field_go_name variant name)
      (emit_expr ~expected:field_ty ~indent signatures env arg)) args variant.var_fields in
  Printf.sprintf "%s{%s}" info.adt_go_name
    (String.concat ", " ((adt_tag_field ^ ": " ^ variant.var_tag) :: parts))

and emit_record_literal ?(indent="") signatures env info fields =
  let parts = List.map (fun (name, field_ty) ->
    let value = match List.assoc_opt name fields with
      | Some value -> value
      | None -> invalid_arg "record literal validated before emission"
    in
    Printf.sprintf "%s: %s" (record_field_go_name name)
      (emit_expr ~expected:field_ty ~indent signatures env value)) info.rec_fields in
  Printf.sprintf "%s{%s}" info.rec_go_name (String.concat ", " parts)

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
    Printf.sprintf "%s{%s}" info.rec_go_name (String.concat ", " parts)
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
  literal indent (Printf.sprintf "(%s)" (emit_expr ~indent signatures env base))

and emit_interp ?(indent="") signatures env segments =
  let parts = List.map (function
    | ILiteral value -> go_quote value
    | IExpr expr ->
      let emitted = emit_expr ~indent signatures env expr in
      match type_of_expr signatures env expr with
      | TString -> emitted
      | TInt -> emitted ^ ".String()"
      | TBool -> Printf.sprintf "strconv.FormatBool(%s)" emitted
      | _ -> unsupported (Checker.expr_loc expr)
        "Go backend interpolation supports String, Int, and Bool only") segments in
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
    | ELet { name; value; body; _ } ->
      let inferred_value_ty = type_of_expr signatures env value in
      let value_ty = if inferred_value_ty = TFailure then result else inferred_value_ty in
      let go_name = sanitize_ident name in
      Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent go_name
        (emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value) indent go_name;
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
    | ELet { name; value; body; loc; _ } ->
      let inferred = type_of_expr signatures env value in
      let ty = if inferred = TFailure then expected else inferred in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%s\t%s := %s\n" indent (sanitize_ident name)
        (emit_expr ~expected:ty ~indent:(indent ^ "\t") signatures env value);
      Printf.bprintf buffer "%s\t_ = %s\n" indent (sanitize_ident name);
      go ((name, ty) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    | EIf { cond; then_; else_; loc } ->
      ignore (type_of_expr signatures env expr);
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%sif %s {\n" indent
        (strip_outer_parens (emit_expr ~indent signatures env cond));
      go env (indent ^ "\t") then_;
      Printf.bprintf buffer "%s} else {\n" indent;
      go env (indent ^ "\t") else_;
      Printf.bprintf buffer "%s}\n" indent
    | ECase { scrut; arms; loc } ->
      ignore (type_of_expr signatures env expr);
      Buffer.add_string buffer (line_directive loc);
      emit_case_statements ~indent signatures env buffer
        (fun arm_env body_indent body -> go arm_env body_indent body) scrut arms
    | _ ->
      ignore (type_of_expr signatures env expr);
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

let import_block paths =
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
  Printf.bprintf body "type %s struct {\n" info.adt_go_name;
  List.iter (fun (name, go_field_type) ->
    Printf.bprintf body "\t%s%s %s\n" name
      (String.make (width - String.length name) ' ') go_field_type) fields;
  Buffer.add_string body "}\n\n";
  let payload_variants = List.filter (fun variant -> variant.var_fields <> []) info.adt_variants in
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

let module_source module_path package signatures types (funcs : func_decl list) =
  let body = Buffer.create 1024 in
  Hashtbl.to_seq_values types.newtypes
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.tesl_name right.tesl_name)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.loc);
    Printf.bprintf body "type %s struct {\n\tteslValue %s\n}\n"
      info.go_name (go_type info.base));
  Hashtbl.to_seq_values types.records
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.rec_tesl_name right.rec_tesl_name)
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
  |> List.iter (fun info -> Buffer.add_string body (adt_source info));
  List.iter (fun (fd : func_decl) ->
    if fd.kind <> FnKind && fd.kind <> CheckKind then unsupported fd.loc
      "Go backend supports plain `fn` and `check` declarations only";
    if fd.capabilities <> [] then unsupported fd.loc
      "Go backend does not support capabilities yet";
    let signature = Hashtbl.find signatures fd.name in
    let params = List.map2 (fun (binding : binding) ty -> binding.name, ty)
      fd.params signature.params in
    let result = signature.result in
    let env = params in
    let body_ty = type_of_expr signatures env fd.body in
    if body_ty <> result && body_ty <> TFailure then
      unsupported fd.loc "Go backend function result type mismatch";
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive fd.loc);
    Printf.bprintf body "func %s(%s) %s {\n"
      signature.go_name
      (String.concat ", " (List.map (fun (name, ty) -> sanitize_ident name ^ " " ^ go_type ty) params))
      (go_type result);
    (* Emit the body once assuming it may loop.  If no self tail call actually turned
       into a `continue`, re-emit it flat: an unused label is a Go compile error, and
       a function that never tail-calls itself should read as plain Go. *)
    let self = fd.name, List.map (fun (name, _) -> sanitize_ident name) params in
    let looped = Buffer.create 256 in
    emit_tail ~self looped signatures env result "\t\t" fd.body;
    if contains_go_code (Buffer.contents looped) ("continue " ^ loop_label) then begin
      Printf.bprintf body "%s:\n\tfor {\n" loop_label;
      Buffer.add_buffer body looped;
      Buffer.add_string body "\t}\n"
    end else
      emit_tail body signatures env result "\t" fd.body;
    Buffer.add_string body "}\n") funcs;
  let body = Buffer.contents body in
  let imports =
    (if contains_go_code body "strconv." then ["strconv"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else []) in
  let header = Printf.sprintf "package %s\n%s" package (import_block imports) in
  header ^ body

let test_source module_path package signatures (tests : test_form list) =
  let body = Buffer.create 1024 in
  let rec emit_stmts env indent = function
    | [] -> ()
    | TsLet { name; value; loc; _ } :: rest ->
      let ty = type_of_expr signatures env value in
      Printf.bprintf body "%s{\n" indent;
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%s\t%s := %s\n" indent (sanitize_ident name)
        (emit_expr ~indent:(indent ^ "\t") signatures env value);
      Printf.bprintf body "%s\t_ = %s\n" indent (sanitize_ident name);
      emit_stmts ((name, ty) :: env) (indent ^ "\t") rest;
      Printf.bprintf body "%s}\n" indent
    | TsExpect { left; right; loc } :: rest ->
      let left_ty = type_of_expr signatures env left in
      (* The emitted guard is the NEGATION of the expectation, built structurally so
         no `!(a && b)` / `!(a == b)` shape reaches the lint gate. *)
      let failure_condition = match right with
        | None ->
          if left_ty <> TBool then unsupported loc "Go backend bare expect requires Bool";
          strip_outer_parens (emit_negated ~indent signatures env left)
        | Some right ->
          let right_ty = type_of_expr signatures env right in
          if left_ty <> right_ty then unsupported loc "Go backend expect operands have different types";
          (match left_ty, bool_literal_value left, bool_literal_value right with
           | TBool, Some expected, None ->
             if expected then strip_outer_parens (emit_negated ~indent signatures env right)
             else strip_outer_parens (emit_expr ~indent signatures env right)
           | TBool, None, Some expected ->
             if expected then strip_outer_parens (emit_negated ~indent signatures env left)
             else strip_outer_parens (emit_expr ~indent signatures env left)
           | _ ->
             strip_outer_parens
               (unequal_expr left_ty (emit_expr ~indent signatures env left)
                  (emit_expr ~indent signatures env right)))
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
       | TInt | TString | TBool | TUnit | TNewtype _ | TRecord _ | TAdt _ ->
         Printf.bprintf body "%steslExpectFailure(teslT, func() {\n%s\t_ = %s\n%s})\n"
           indent indent emitted indent
       | TFailure -> unsupported loc "Go backend expectFail target has no result type");
      emit_stmts env indent rest
    | (TsLetProof { loc; _ } | TsExpectFail { loc; _ } | TsExpectHasProof { loc; _ }
      | TsProperty { loc; _ } | TsIf { loc; _ } | TsCase { loc; _ }) :: _ ->
      unsupported loc "Go backend does not support this test statement yet"
  in
  List.iteri (fun index (test : test_form) ->
    if test.runs <> None || test.capabilities <> [] || test.database <> None then
      unsupported test.loc "Go backend supports plain deterministic tests only";
    Buffer.add_char body '\n';
    Printf.bprintf body "func TestTesl%d(teslT *testing.T) {\n" index;
    emit_stmts [] "\t" test.stmts;
    Buffer.add_string body "}\n") tests;
  let body = Buffer.contents body in
  let expect_failure_helper =
    if contains_go_code body "teslExpectFailure(" then
      "\nfunc teslExpectFailure(teslT *testing.T, teslThunk func()) {\n\tteslT.Helper()\n\tdefer func() {\n\t\tif recover() == nil {\n\t\t\tteslT.Fatal(\"expected Tesl failure\")\n\t\t}\n\t}()\n\tteslThunk()\n}\n"
    else ""
  in
  let imports = ["fmt"; "os"]
    @ (if contains_go_code body "strconv." then ["strconv"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else [])
    @ ["testing"] in
  Printf.sprintf
    "package %s\n%s\nfunc TestMain(teslM *testing.M) {\n\t_, _ = fmt.Fprintln(os.Stderr, \"TESL_GO_TESTS_STARTED\")\n\tos.Exit(teslM.Run())\n}\n%s%s"
    package (import_block imports) expect_failure_helper body

let compile_module ?(mode=Release) (m : module_form) =
  try
    (match mode with
     | Release -> ()
     | Debug -> unsupported (Location.dummy_loc m.source_file)
       "Go debugger instrumentation is not implemented yet");
    List.iter (fun (import : import_decl) ->
      if import.module_name <> "Tesl.Prelude" then unsupported import.loc
        "Go backend does not support import `%s` yet" import.module_name) m.imports;
    let funcs = List.filter_map (function DFunc fd -> Some fd | _ -> None) m.decls in
    let tests = List.filter_map (function DTest test -> Some test | _ -> None) m.decls in
    let types = {
      newtypes = Hashtbl.create 8;
      records = Hashtbl.create 8;
      adts = Hashtbl.create 8;
    } in
    List.iter (function
      | DType (TypeNewtype { name; secret = true; loc; _ }) ->
        unsupported loc "Go backend does not support secret newtype `%s` yet" name
      | DType (TypeNewtype { name; base_type; loc; _ }) ->
        let base = primitive_type_of_type_expr base_type in
        Hashtbl.replace types.newtypes name {
          tesl_name = name;
          go_name = exported_ident name;
          base;
          loc;
        }
      | _ -> ()) m.decls;
    let record_forms = List.filter_map (function DRecord r -> Some r | _ -> None) m.decls in
    List.iter (fun (r : record_form) ->
      if r.invariant <> None then unsupported r.loc
        "Go backend does not support record invariants yet";
      if r.fields = [] then unsupported r.loc
        "Go backend does not support the field-less record `%s`" r.name;
      List.iter (fun (field : field_def) ->
        if field.proof_ann <> None then unsupported field.loc
          "Go backend does not support proof-carrying record field `%s.%s` yet" r.name field.name;
        if field.checker <> None then unsupported field.loc
          "Go backend does not support `via` on record field `%s.%s` yet" r.name field.name)
        r.fields;
      if Hashtbl.mem types.newtypes r.name || Hashtbl.mem types.records r.name then
        unsupported r.loc "Go backend generated type name collision for `%s`" r.name;
      Hashtbl.replace types.records r.name {
        rec_tesl_name = r.name;
        rec_go_name = exported_ident r.name;
        rec_fields = [];
        rec_loc = r.loc;
      }) record_forms;
    let adt_forms = List.filter_map (function
      | DType (TypeAdt { name; params; variants; loc }) -> Some (name, params, variants, loc)
      | _ -> None) m.decls in
    List.iter (fun (name, params, variants, loc) ->
      if params <> [] then unsupported loc
        "Go backend does not support the generic type `%s` yet" name;
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
      Hashtbl.replace types.adts name {
        adt_tesl_name = name;
        adt_go_name = exported_ident name;
        adt_tag_type = exported_ident name ^ "Tag";
        adt_variants = List.map (fun (variant : adt_variant) -> {
          var_ctor = variant.ctor;
          var_tag = exported_ident name ^ "Tag_" ^ sanitize_suffix variant.ctor;
          var_fields = [];
          var_loc = variant.loc;
        }) variants;
        adt_loc = loc;
      }) adt_forms;
    (* Field types resolve only after every named type is registered, so records and
       ADTs may reference each other; a cycle would be an infinitely sized Go value
       and is rejected below. *)
    List.iter (fun (r : record_form) ->
      let info = Hashtbl.find types.records r.name in
      info.rec_fields <- List.map (fun (field : field_def) ->
        field.name, type_of_type_expr types field.type_expr) r.fields) record_forms;
    List.iter (fun (name, _, variants, _) ->
      let info = Hashtbl.find types.adts name in
      List.iter2 (fun (variant : adt_variant) target ->
        target.var_fields <- List.map (fun (field : field_def) ->
          field.name, type_of_type_expr types field.type_expr) variant.fields)
        variants info.adt_variants) adt_forms;
    let contained = function
      | TRecord info -> `Record info
      | TAdt info -> `Adt info
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
      | DEntity e -> unsupported e.loc "Go backend does not support entities yet"
      | DFact _ -> ()
      | DCodec c -> unsupported c.loc "Go backend does not support codecs yet"
      | DDatabase d -> unsupported d.loc "Go backend does not support databases yet"
      | DCapability c -> unsupported c.loc "Go backend does not support capabilities yet"
      | DConst c -> unsupported c.loc "Go backend does not support constants yet"
      | DQueue q -> unsupported q.loc "Go backend does not support queues yet"
      | DChannel c -> unsupported c.loc "Go backend does not support channels yet"
      | DWorkers w -> unsupported w.loc "Go backend does not support workers yet"
      | DCache c -> unsupported c.loc "Go backend does not support caches yet"
      | DAgent a -> unsupported a.loc "Go backend does not support agents yet"
      | DEmail e -> unsupported e.loc "Go backend does not support email yet"
      | DCapture c -> unsupported c.loc "Go backend does not support captures yet"
      | DApi a -> unsupported a.loc "Go backend does not support APIs yet"
      | DServer s -> unsupported s.loc "Go backend does not support servers yet"
      | DApiTest t -> unsupported t.loc "Go backend does not support api-test yet"
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
    List.iter (fun (fd : func_decl) ->
      if not (List.mem fd.name reachable_names) then unsupported fd.loc
        "Go backend does not emit unreachable private function `%s` yet; export it, call it, or remove it"
        fd.name) funcs;
    let signatures = Hashtbl.create
      (List.length funcs + Hashtbl.length types.newtypes + Hashtbl.length types.records) in
    Hashtbl.iter (fun name info ->
      Hashtbl.add signatures name {
        params = [info.base];
        result = TNewtype info;
        go_name = info.go_name;
      }) types.newtypes;
    Hashtbl.iter (fun name info ->
      Hashtbl.add signatures name {
        params = List.map snd info.rec_fields;
        result = TRecord info;
        go_name = info.rec_go_name;
      }) types.records;
    (* Each constructor is its own signature entry: the surface syntax names the
       constructor, and the variant it belongs to is recovered from the result type. *)
    Hashtbl.iter (fun _ info ->
      List.iter (fun variant ->
        if Hashtbl.mem signatures variant.var_ctor then unsupported variant.var_loc
          "Go backend generated name collision for constructor `%s`" variant.var_ctor;
        Hashtbl.add signatures variant.var_ctor {
          params = List.map snd variant.var_fields;
          result = TAdt info;
          go_name = variant.var_tag;
        }) info.adt_variants) types.adts;
    List.iter (fun (fd : func_decl) ->
      if Hashtbl.mem signatures fd.name then unsupported fd.loc
        "Go backend generated name collision for `%s`" fd.name;
      let params = List.map (fun (binding : binding) ->
        type_of_type_expr types binding.type_expr) fd.params in
      let exported = is_exported fd.name in
      let go_name = if exported then exported_ident fd.name else sanitize_ident fd.name in
      Hashtbl.add signatures fd.name {
        params;
        result = type_of_return_spec types fd.return_spec;
        go_name;
      }) funcs;
    let package = package_name m.module_name in
    let module_path = "tesl.generated/" ^ package in
    let source = module_source module_path package signatures types funcs in
    let tests_source = if tests = [] then None else Some (test_source module_path package signatures tests) in
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
      { path = "go.mod"; contents = Printf.sprintf "module %s\n\ngo 1.22\n" module_path };
      { path = ".golangci.yml"; contents = lint_config };
      { path = "internal/" ^ package ^ "/module.go"; contents = source };
    ] in
    let artifacts = match tests_source with
      | None -> artifacts
      | Some contents -> artifacts @ [{ path = "internal/" ^ package ^ "/module_test.go"; contents }]
    in
    let artifacts =
      if needs_runtime then artifacts @ List.map (fun (name, contents) ->
        { path = "internal/teslrt/" ^ name; contents }) Embedded_go_runtime.files
      else artifacts
    in
    Ok artifacts
  with Unsupported error -> Error [error]
