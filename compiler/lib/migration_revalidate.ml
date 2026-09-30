open Ast
module I = Migration_ir
module R = Migration_transform_rules
module S = Migration_sparse

exception Invalid of S.error
let reject code loc message = raise (Invalid {S.code;loc;message;related=[]})
let at = Checker.expr_loc
let rec bound = function
  | PVar name -> [name]
  | PCon p -> List.concat_map (fun (_,p) -> bound p) p.fields
  | PWild | PNullary _ | PLit _ -> []
let name = function
  | EVar e -> Some e.name
  | EConstructor {name;args=[];_} -> Some name
  | EField {obj=EConstructor {name;args=[];_};field;_} -> Some (name ^ "." ^ field)
  | _ -> None
let rec application = function
  | EApp e -> let head,args=application e.fn in head,args@[e.arg]
  | EConstructor e -> Some e.name,e.args
  | e -> name e,[]

let check ~resolve ~modules ~root ~owner ~(declaration:func_decl) ~mapping =
 try
  let symbol owner namespace value = Option.bind value (resolve owner namespace) in
  let primitive owner expected name = resolve owner I.Value name=Some (I.Primitive expected) in
  let field (stored:Migration_inventory.stored_field) =
   match List.concat_map (fun (m:module_form) -> List.concat_map (function
    | DEntity e when m.module_name ^ "." ^ e.name=stored.entity ->
      List.filter_map (fun (f:field_def)->if f.name=stored.name then Some(m,f) else None) e.fields
    | _ -> []) m.decls) modules with
   | [one] -> one
   | _ -> reject "MIG022" stored.loc "Revalidate requires an exact owned entity field" in
  let same_type a_owner a b_owner b = match a,b with
   | TName a,TName b -> (match resolve a_owner I.Type a.name,resolve b_owner I.Type b.name with
      | Some (I.Primitive a),Some (I.Primitive b) -> a=b
      | _ -> false)
   | _ -> false in
  let rules=List.filter_map (function
   | R.Revalidated {previous;current;function_ref;loc} ->
    let target_owner,target=field current in
    let identity=match symbol root I.Value (name function_ref) with
     | Some (I.Global identity) -> identity
     | _ -> reject "MIG022" loc "Revalidate must name the target schema's establish" in
    let fn=match List.filter_map (function
     | DFunc f when target_owner.module_name ^ "." ^ f.name=identity -> Some f
     | _ -> None) target_owner.decls with
     | [f] when f.kind=EstablishKind && f.capabilities=[] && f.http_methods=[] -> f
     | _ -> reject "MIG022" loc "Revalidate requires a pure establish owned by the target field's schema module" in
     let rec same_proof result actual expected = match actual,expected with
       | PredApp actual,PredApp expected ->
         expected.args=[target.name] && actual.args=[result] &&
         resolve target_owner I.Predicate actual.pred=resolve target_owner I.Predicate expected.pred &&
         Option.is_some(resolve target_owner I.Predicate expected.pred)
       | PredAnd actual,PredAnd expected ->
         same_proof result actual.left expected.left && same_proof result actual.right expected.right
       | _ -> false in
     let input=match fn.params,fn.return_spec,target.proof_ann with
      | [parameter],RetMaybeAttached {outer_ty=None;binding=result;_},Some proof
        when parameter.proof_ann=None &&
          same_type target_owner parameter.type_expr target_owner target.type_expr &&
          same_type target_owner result.type_expr target_owner target.type_expr ->
        (match result.proof_ann with
         | Some returned when same_proof result.name returned proof -> parameter.name
        | _ -> reject "MIG022" loc "Revalidate establish must return Maybe of the exact target field proof")
      | _ -> reject "MIG022" loc "Revalidate requires a primitive field and optional field-local target proofs" in
    let no_shadow names loc = if List.mem input names || List.exists (fun name ->
      primitive target_owner "Tesl.Maybe.Something" name ||
      primitive target_owner "Tesl.Maybe.Nothing" name) names then
      reject "MIG018" loc "Revalidate establish cannot shadow its original input or Maybe constructors" in
    let rec preserves = function
     | ELet e -> no_shadow [e.name] e.loc; preserves e.body
     | ELetProof e -> no_shadow [e.value_name;e.proof_name] e.loc; preserves e.body
     | EIf e -> preserves e.then_; preserves e.else_
     | ECase e -> List.iter (fun (arm:case_arm)->no_shadow (bound arm.pattern) arm.loc;preserves arm.body) e.arms
     | value -> (match application value with
       | Some ctor,[] when primitive target_owner "Tesl.Maybe.Nothing" ctor -> ()
       | Some ctor,[EOk {value=EVar v;keyword=false;_}]
         when primitive target_owner "Tesl.Maybe.Something" ctor && v.name=input -> ()
       | _ -> reject "MIG018" (at value)
          "Revalidate establish must return Nothing or Something of its exact original input with a proof") in
    preserves fn.body;
    Some(current.name,previous.name,identity)
   | _ -> None) mapping.R.values in
  if rules<>[] then begin
   let old=match declaration.params with [p]->p.name | _ ->
     reject "MIG018" declaration.loc "Revalidate requires a single original row parameter" in
   let forget names env=List.filter(fun(binder,_)->not(List.mem binder names)) env in
   let shadow names loc=if List.mem old names || List.exists (fun name ->
     List.exists (fun (_,_,identity)->resolve owner I.Value name=Some(I.Global identity)) rules ||
     List.exists (fun ctor->primitive owner ctor name)
       ["Tesl.Maybe.Something";"Tesl.Maybe.Nothing";"Tesl.Migration.Row";"Tesl.Migration.Reject"]) names then
     reject "MIG018" loc "Revalidate cannot shadow the original row, establish or result constructors" in
   let check_fields env fields loc = List.iter(fun(target,_,identity)->
    match List.assoc_opt target fields with
    | Some(EVar v) when List.assoc_opt v.name env=Some(target,identity) -> ()
    | value -> reject "MIG018" (Option.fold ~none:loc ~some:at value)
       ("`" ^ target ^ "` must be the Something binder from its Revalidate establish applied to the original field")) rules in
   let row env = function
    | ERecord e -> check_fields env e.fields e.loc
    | EApp {arg=ERecord e;_} -> check_fields env e.fields e.loc
    | e -> reject "MIG018" (at e) "Revalidate requires an explicit target row literal" in
   let rec returns env = function
    | ELet e -> shadow [e.name] e.loc; returns (forget [e.name] env) e.body
    | ELetProof e -> let names=[e.value_name;e.proof_name] in shadow names e.loc; returns (forget names env) e.body
    | EIf e -> returns env e.then_; returns env e.else_
    | ECase e ->
      let evidence=match application e.scrut with
       | fn,[EField {obj=EVar source;field;_}] when source.name=old ->
        List.filter(fun(_,previous,identity)->previous=field && symbol owner I.Value fn=Some(I.Global identity)) rules
       | _ -> [] in
      List.iter(fun(arm:case_arm)->
       let names=bound arm.pattern in shadow names arm.loc;
       let env=forget names env in
       let env=match arm.pattern,arm.guard,evidence with
        | PCon p,None,[(target,_,identity)] when primitive owner "Tesl.Maybe.Something" p.ctor ->
          (match p.fields with [_,PVar binder]->(binder,(target,identity))::env | _ -> env)
        | _ -> env in
       returns env arm.body) e.arms
    | value -> (match application value with
      | Some ctor,[value] when primitive owner "Tesl.Migration.Row" ctor -> row env value
      | Some ctor,[_] when primitive owner "Tesl.Migration.Reject" ctor -> ()
      | _ -> reject "MIG018" (at value) "Revalidate requires explicit Row or Reject results") in
   returns [] declaration.body
  end;
  Ok ()
 with Invalid error -> Error [error]
