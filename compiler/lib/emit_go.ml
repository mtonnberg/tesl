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

type go_type = TInt | TString | TBool | TUnit | TCheck of go_type | TFailure

type signature = {
  params : go_type list;
  result : go_type;
  go_name : string;
}

exception Unsupported of emit_error

let unsupported loc fmt =
  Printf.ksprintf (fun message -> raise (Unsupported { loc; message })) fmt

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

let type_of_type_expr = function
  | TName { name = "Int"; _ } -> TInt
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } -> unsupported loc "Go backend does not support type `%s` yet" name
  | TVar { name; loc } -> unsupported loc "Go backend does not support type variable `%s` yet" name
  | TApp { loc; _ } -> unsupported loc "Go backend does not support applied types yet"
  | TFun { loc; _ } -> unsupported loc "Go backend does not support function values yet"
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

let type_of_return_spec = function
  | RetPlain { ty; _ } -> type_of_type_expr ty
  | RetAttached { binding; _ } -> TCheck (type_of_type_expr binding.type_expr)
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
  | TCheck ty -> Printf.sprintf "teslrt.Check[%s]" (go_type ty)
  | TFailure -> invalid_arg "Go failure has no standalone type"

let equal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "teslrt.Equal(%s, %s)" left right
  | TString | TBool | TUnit -> Printf.sprintf "(%s == %s)" left right
  | TCheck _ | TFailure -> invalid_arg "Go check results require explicit test handling"

let unequal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "!teslrt.Equal(%s, %s)" left right
  | TString | TBool | TUnit -> Printf.sprintf "(%s != %s)" left right
  | TCheck _ | TFailure -> invalid_arg "Go check results require explicit test handling"

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
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some ty, _ -> ty
     | None, Some { params = []; result; _ } -> result
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> lookup_env loc name env)
  | EConstructor { name = "True" | "False"; args = []; _ } -> TBool
  | EConstructor { name = "Unit"; args = []; _ } -> TUnit
  | EConstructor { name; loc; _ } ->
    unsupported loc "Go backend does not support constructor `%s` yet" name
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
    (match head with
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
       if left_ty <> TInt && left_ty <> TString then
         unsupported loc "Go backend ordering supports Int and String only";
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
     | TFailure, TFailure -> unsupported loc "Go backend cannot infer a check result from two failures"
     | TFailure, ty | ty, TFailure -> ty
     | left, right when left = right -> left
     | _ -> unsupported loc "Go backend if branches have different types")
  | ELet { name; value; body; _ } ->
    let value_ty = type_of_expr signatures env value in
    type_of_expr signatures ((name, value_ty) :: env) body
  | EField { loc; _ } -> unsupported loc "Go backend does not support record fields yet"
  | ECase { loc; _ } -> unsupported loc "Go backend does not support case expressions yet"
  | ELetProof { loc; _ } -> unsupported loc "Go backend does not support proof decomposition yet"
  | ERecord { loc; _ } -> unsupported loc "Go backend does not support records yet"
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

let rec emit_expr ?expected signatures env expr =
  match expr with
  | ELit { lit = LInt value; _ } -> Printf.sprintf "teslrt.FromInt64(%d)" value
  | ELit { lit = LBigInt value; _ } ->
    Printf.sprintf "teslrt.MustParseDecimal(%s)" (go_quote value)
  | ELit { lit = LString value; _ } -> go_quote value
  | ELit { lit = LBool value; _ } -> if value then "true" else "false"
  | ELit { lit = LFloat _; loc } ->
    unsupported loc "Go backend cannot emit Float yet"
  | ELit { lit = LInterp segments; _ } -> emit_interp signatures env segments
  | EVar { name; loc } ->
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some _, _ -> sanitize_ident name
     | None, Some { params = []; go_name; _ } -> go_name ^ "()"
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> sanitize_ident name)
  | EConstructor { name = "True"; args = []; _ } -> "true"
  | EConstructor { name = "False"; args = []; _ } -> "false"
  | EConstructor { name = "Unit"; args = []; _ } -> "struct{}{}"
  | EConstructor { name; loc; _ } -> unsupported loc "Go backend cannot emit constructor `%s`" name
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
    (match head with
     | EVar { name = "check"; _ } ->
       (match args with
        | EVar { name; _ } :: call_args ->
          ignore (type_of_expr signatures env app);
           let signature = match Hashtbl.find_opt signatures name with
             | Some signature -> signature
             | None -> unsupported loc "Go backend cannot resolve check `%s`" name
           in
           Printf.sprintf "teslrt.MustCheck(%s(%s))" signature.go_name
             (String.concat ", " (List.map (emit_expr signatures env) call_args))
         | _ -> unsupported loc "Go backend requires a named check function")
     | EVar { name = "not"; _ } when not (Hashtbl.mem signatures "not") ->
       ignore (type_of_expr signatures env app);
       (match args with
        | [arg] -> Printf.sprintf "!(%s)" (emit_expr signatures env arg)
        | _ -> assert false)
     | EVar { name; _ } ->
       let signature = match Hashtbl.find_opt signatures name with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" name
       in
       let args = normalize_call_args signature.params args in
       ignore (type_of_expr signatures env app);
       Printf.sprintf "%s(%s)" signature.go_name
         (String.concat ", " (List.map (emit_expr signatures env) args))
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  | EBinop { op; left; right; _ } ->
    let ty = type_of_expr signatures env left in
    let emitted_left = emit_expr signatures env left in
    let emitted_right = emit_expr signatures env right in
    let emit_bool_literal_comparison equal =
      match bool_literal_value left, bool_literal_value right with
      | Some expected, None ->
        if expected = equal then emitted_right else Printf.sprintf "!(%s)" emitted_right
      | None, Some expected ->
        if expected = equal then emitted_left else Printf.sprintf "!(%s)" emitted_left
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
       if ty = TInt then
         let op = match op with BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">=" | _ -> assert false in
          Printf.sprintf "(teslrt.Compare(%s, %s) %s 0)" emitted_left emitted_right op
       else
         let op = match op with BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">=" | _ -> assert false in
          Printf.sprintf "(%s %s %s)" emitted_left op emitted_right)
  | EUnop { op = UNeg; arg; _ } -> Printf.sprintf "teslrt.Neg(%s)" (emit_expr signatures env arg)
  | EUnop { op = UNot; arg; _ } -> Printf.sprintf "!(%s)" (emit_expr signatures env arg)
  | EIf { loc; _ } -> unsupported loc "Go backend supports if only in tail position"
  | ELet { loc; _ } -> unsupported loc "Go backend supports let only in tail position"
  | EField { loc; _ } | ECase { loc; _ } | ELetProof { loc; _ }
  | ERecord { loc; _ } | EList { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"
  | EOk { value; _ } -> Printf.sprintf "teslrt.Accept(%s)" (emit_expr signatures env value)
  | EFail { status; message; loc } ->
    (match expected with
     | Some (TCheck result) ->
       Printf.sprintf "teslrt.Reject[%s](%d, %s)" (go_type result) status
         (emit_expr signatures env message)
     | _ -> unsupported loc "Go backend can emit fail only in a check tail")
  | ETelemetry { loc; _ } | EEnqueue { loc; _ } | EPublish { loc; _ }
  | EStartWorkers { loc; _ } | ECacheGet { loc; _ } | ECacheSet { loc; _ }
  | ECacheDelete { loc; _ } | ECacheInvalidate { loc; _ } | ESendEmail { loc; _ }
  | EStartEmailWorker { loc; _ } | EWithDatabase { loc; _ }
  | EWithCapabilities { loc; _ } | EWithTransaction { loc; _ } | EServe { loc; _ }
  | ELambda { loc; _ } | ERuntimeCall { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"

and emit_interp signatures env segments =
  let parts = List.map (function
    | ILiteral value -> go_quote value
    | IExpr expr ->
      let emitted = emit_expr signatures env expr in
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

let strip_outer_parens value =
  let length = String.length value in
  if length >= 2 && value.[0] = '(' && value.[length - 1] = ')' then
    String.sub value 1 (length - 2)
  else value

let emit_tail buffer signatures env expected indent expr =
  let rec go env indent expr =
    match expr with
    | ELet { name; value; body; loc; _ } ->
      let ty = type_of_expr signatures env value in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%s\t%s := %s\n" indent (sanitize_ident name)
        (emit_expr signatures env value);
      Printf.bprintf buffer "%s\t_ = %s\n" indent (sanitize_ident name);
      go ((name, ty) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    | EIf { cond; then_; else_; loc } ->
      ignore (type_of_expr signatures env expr);
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%sif %s {\n" indent
        (strip_outer_parens (emit_expr signatures env cond));
      go env (indent ^ "\t") then_;
      Printf.bprintf buffer "%s} else {\n" indent;
      go env (indent ^ "\t") else_;
      Printf.bprintf buffer "%s}\n" indent
    | _ ->
      ignore (type_of_expr signatures env expr);
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      Printf.bprintf buffer "%sreturn %s\n" indent (emit_expr ~expected signatures env expr)
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

let module_source module_path package signatures (funcs : func_decl list) =
  let body = Buffer.create 1024 in
  List.iter (fun (fd : func_decl) ->
    if fd.kind <> FnKind && fd.kind <> CheckKind then unsupported fd.loc
      "Go backend supports plain `fn` and `check` declarations only";
    if fd.capabilities <> [] then unsupported fd.loc
      "Go backend does not support capabilities yet";
    let params = List.map (fun (binding : binding) ->
      let ty = type_of_type_expr binding.type_expr in
      binding.name, ty) fd.params in
    let result = type_of_return_spec fd.return_spec in
    let env = params in
    let body_ty = type_of_expr signatures env fd.body in
    if body_ty <> result then unsupported fd.loc "Go backend function result type mismatch";
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive fd.loc);
    let signature = Hashtbl.find signatures fd.name in
    Printf.bprintf body "func %s(%s) %s {\n"
      signature.go_name
      (String.concat ", " (List.map (fun (name, ty) -> sanitize_ident name ^ " " ^ go_type ty) params))
      (go_type result);
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
        (emit_expr signatures env value);
      Printf.bprintf body "%s\t_ = %s\n" indent (sanitize_ident name);
      emit_stmts ((name, ty) :: env) (indent ^ "\t") rest;
      Printf.bprintf body "%s}\n" indent
    | TsExpect { left; right; loc } :: rest ->
      let left_ty = type_of_expr signatures env left in
      let failure_condition = match right with
        | None ->
          if left_ty <> TBool then unsupported loc "Go backend bare expect requires Bool";
          Printf.sprintf "!(%s)" (strip_outer_parens (emit_expr signatures env left))
        | Some right ->
          let right_ty = type_of_expr signatures env right in
          if left_ty <> right_ty then unsupported loc "Go backend expect operands have different types";
          (match left_ty, bool_literal_value left, bool_literal_value right with
           | TBool, Some expected, None ->
             let compared = strip_outer_parens (emit_expr signatures env right) in
             if expected then Printf.sprintf "!(%s)" compared else compared
           | TBool, None, Some expected ->
             let compared = strip_outer_parens (emit_expr signatures env left) in
             if expected then Printf.sprintf "!(%s)" compared else compared
           | _ ->
             strip_outer_parens
               (unequal_expr left_ty (emit_expr signatures env left) (emit_expr signatures env right)))
      in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif %s {\n%s\tteslT.Fatal(\"Tesl expectation failed\")\n%s}\n"
        indent failure_condition indent indent;
      emit_stmts env indent rest
    | TsExpr { e; loc } :: rest ->
      ignore (type_of_expr signatures env e);
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%s_ = %s\n" indent (emit_expr signatures env e);
      emit_stmts env indent rest
    | TsExpectFail { fn = EVar { name = "check"; _ }; arg; loc } :: rest ->
      let result_ty = type_of_expr signatures env arg in
      (match result_ty with
       | TCheck _ -> ()
       | _ -> unsupported loc "Go backend expectFail target is not a check");
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif (%s).OK() {\n%s\tteslT.Fatal(\"expected Tesl check failure\")\n%s}\n"
        indent (emit_expr signatures env arg) indent indent;
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
  let imports = ["fmt"; "os"]
    @ (if contains_go_code body "strconv." then ["strconv"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else [])
    @ ["testing"] in
  Printf.sprintf
    "package %s\n%s\nfunc TestMain(teslM *testing.M) {\n\t_, _ = fmt.Fprintln(os.Stderr, \"TESL_GO_TESTS_STARTED\")\n\tos.Exit(teslM.Run())\n}\n%s"
    package (import_block imports) body

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
    List.iter (function
      | DFunc _ | DTest _ -> ()
      | DType form ->
        let loc = match form with
          | TypeNewtype { loc; _ } | TypeAlias { loc; _ } | TypeAdt { loc; _ } -> loc in
        unsupported loc "Go backend does not support type declarations yet"
      | DRecord r -> unsupported r.loc "Go backend does not support records yet"
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
    let rec reaches target visited current =
      if List.mem current visited then false
      else
        match List.assoc_opt current graph with
        | None -> false
        | Some next -> List.exists (fun name ->
            name = target || reaches target (current :: visited) name) next
    in
    List.iter (fun (fd : func_decl) ->
      if reaches fd.name [] fd.name then unsupported fd.loc
        "Go backend does not support recursive function `%s` yet; Go has no tail-call optimization"
        fd.name) funcs;
    let signatures = Hashtbl.create (List.length funcs) in
    List.iter (fun (fd : func_decl) ->
      let params = List.map (fun (binding : binding) -> type_of_type_expr binding.type_expr) fd.params in
      let exported = is_exported fd.name in
      let go_name = if exported then exported_ident fd.name else sanitize_ident fd.name in
      Hashtbl.replace signatures fd.name {
        params;
        result = type_of_return_spec fd.return_spec;
        go_name;
      }) funcs;
    let package = package_name m.module_name in
    let module_path = "tesl.generated/" ^ package in
    let source = module_source module_path package signatures funcs in
    let tests_source = if tests = [] then None else Some (test_source module_path package signatures tests) in
    let needs_runtime = contains_go_code source "teslrt." ||
      match tests_source with Some text -> contains_go_code text "teslrt." | None -> false in
    let artifacts = [
      { path = "go.mod"; contents = Printf.sprintf "module %s\n\ngo 1.22\n" module_path };
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
