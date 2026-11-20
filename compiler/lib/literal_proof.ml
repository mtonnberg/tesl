open Ast
module C = Literal_proof_context
module E = Literal_eval
type error = {loc:Location.loc;message:string}
exception Invalid of error
let reject loc message=raise(Invalid{loc;message})
type graph = { entry:string; sources:(module_form * string) list }
let active_graph : graph option ref = ref None
let with_graph ~entry sources run =
 if not(List.exists(fun((m:module_form),_)->List.exists(function DFact f->f.literal_via<>None|_->false)m.decls)sources)then Ok(run())else
 let entry=Source_input.canonical_path entry in
 let previous= !active_graph in
 let inputs=List.map(fun((m:module_form),text)->Source_input.canonical_path m.source_file,text)sources in
 let observe file=if Source_input.exists file then Some(Source_input.read file)else None in
 try
  let observed=Source_input.without_pinned_files(fun()->List.map(fun(file,text)->
    let actual=observe file in
    if file<>entry && actual<>Some text then reject(Location.dummy_loc file) "literal proof dependency changed before captured compilation";
    file,actual)inputs)in
  let verify ()=Source_input.without_pinned_files(fun()->
    List.iter(fun(file,expected)->if observe file<>expected then reject(Location.dummy_loc file) "literal proof source changed during captured compilation")observed;
    List.iter(fun((m:module_form),_)->List.iter(fun(i:import_decl)->if not(String.starts_with ~prefix:"Tesl." i.module_name)then
      match List.find_opt(fun((owner:module_form),_)->owner.module_name=i.module_name)sources with
      | Some(owner,_) when Validation_common.canonical_import_path owner.source_file=
          Validation_common.canonical_import_path(Validation_common.resolve_local_import_path m.source_file i.module_name)->()
      | _->reject i.loc "literal proof import changed during captured compilation")m.imports)sources)in
  verify();
  active_graph:=Some{entry;sources};Query_cache.clear();
  let result=Fun.protect ~finally:(fun()->active_graph:=previous;Query_cache.clear())(fun()->
    Source_input.with_pinned_files inputs(fun()->let result=run()in verify();result))in
  Ok result
 with Invalid e->Error[e]|Sys_error message|Invalid_argument message|Unix.Unix_error(_,_,message)->
  Error[{loc=Location.dummy_loc entry;message}]
let exported m name=List.exists(function ExportName n|ExportAdt n->n=name)m.exports ||
 List.exists(function DType(TypeAdt a)->List.mem(ExportAdt a.name)m.exports && List.exists(fun(v:adt_variant)->v.ctor=name)a.variants|_->false)m.decls
let local_values m=List.concat_map(function
 | DFunc f->[f.name]|DConst c->[c.name]|DRecord r->[r.name]|DEntity e->[e.name]
 | DType(TypeNewtype n)->[n.name]|DType(TypeAdt a)->List.map(fun(v:adt_variant)->v.ctor)a.variants
 | _->[])m.decls
let literal_shape=function ELit{lit=(LInt _|LBigInt _|LString _|LBool _|LFloat _);_}
 | EUnop{op=UNeg;arg=ELit _;_}|EConstructor{name=("True"|"False");args=[];_}->true|_->false
let requests m =
 let found=ref []in
 let bind name ty proof value=match ty,proof with
  | Some ty,Some proof when literal_shape value->found:=(name,ty,proof,value)::!found
  | _->()in
 let visit=Ast_visitor.iter(function ELet e->bind e.name e.declared_type e.declared_proof e.value|_->())in
 let rec statements stmts=List.iter(fun stmt->
  List.iter visit(Ast.test_stmt_exprs stmt);
  match stmt with TsLet s->bind s.name s.declared_type s.declared_proof s.value
   | TsIf s->statements s.then_stmts;statements s.else_stmts
   | TsCase s->List.iter(fun(a:ts_case_arm)->statements a.ts_body)s.arms
   | _->())stmts in
 List.iter(function DFunc f->visit f.body|DConst c->visit c.value
  | DTest t->statements t.stmts|DApiTest t->statements t.stmts|DLoadTest t->statements t.request_stmts
  | _->())m.decls;
 List.sort_uniq compare !found

let with_module ~source (root:module_form) run =
 let wanted=requests root in
 let has_rules=List.exists(function DFact f->f.literal_via<>None|_->false)root.decls in
 if wanted=[] && not has_rules then Literal_proof_context.with_sites [] run,[] else
 let errors=ref [] and sites=ref [] and modules=ref [] and inputs=ref [] and edges=ref []in
 let root_file=Source_input.canonical_path root.source_file in
 let observe ()=if Source_input.exists root_file then Some(Source_input.read root_file)else None in
 let original_root=Source_input.without_pinned_files observe in
 let rec load (m:module_form) text =
  match List.find_opt(fun(m',_)->m'.module_name=m.module_name)!modules with
  | Some(previous,bytes) -> if Validation_common.canonical_import_path previous.source_file<>
      Validation_common.canonical_import_path m.source_file || bytes<>text then
      reject(Location.dummy_loc m.source_file) "literal proof module has conflicting source owners"
  | None -> begin
   if List.length !modules>=256 then reject (Location.dummy_loc root.source_file) "literal proof import graph exceeds 256 modules";
   modules:=(m,text)::!modules;inputs:=(Source_input.canonical_path m.source_file,text)::!inputs;
   List.iter(fun(i:import_decl)->if not(String.starts_with ~prefix:"Tesl." i.module_name)then
     let file=Validation_common.resolve_local_import_path m.source_file i.module_name |> Source_input.canonical_path in
     (match !active_graph with None->()|Some graph->
       match List.find_opt(fun((owner:module_form),_)->owner.module_name=i.module_name)graph.sources with
       | Some(owner,_) when Validation_common.canonical_import_path owner.source_file=Validation_common.canonical_import_path file->()
       | _->reject i.loc "literal proof attempted to use an uncaptured import");
     edges:=(m.source_file,i.module_name,file)::!edges;
     let text=Source_input.read file in
     match Parser.parse_module file text with
      | Parser.Ok child when child.module_name=i.module_name->load child text
      | _->reject i.loc "literal proof dependency could not be parsed with its declared module name")m.imports
  end in
 let prepare () =
  let forms=List.map fst !modules in
  let imported home candidate name =
    List.exists(fun(i:import_decl)->i.module_name=candidate.module_name && exported candidate name)home.imports in
  let visible home candidate name reference =
    let qualified=candidate.module_name ^ "." ^ name in
    (candidate.module_name=home.module_name && (reference=name || reference=qualified)) ||
    (imported home candidate name && (reference=qualified ||
      List.exists(fun(i:import_decl)->i.module_name=candidate.module_name && match i.names with
       | ImportExposing ns->List.mem name ns || List.exists(function DType(TypeAdt a)->List.mem(a.name ^ "(..)")ns && List.exists(fun(v:adt_variant)->v.ctor=name)a.variants|_->false)candidate.decls
       | _->false)home.imports && reference=name))in
  let resolve home name =
    let local=List.find_map(function DFunc f when f.name=name->Some(E.Function(home,f))
      |DConst c when c.name=name->Some(E.Constant(home,c))|_->None)home.decls in
    if local<>None then local else if List.mem name(local_values home)then None else
    let matches=List.concat_map(fun candidate->List.filter_map(function
      | DFunc f when visible home candidate f.name name->Some(E.Function(candidate,f))
      | DConst c when visible home candidate c.name name->Some(E.Constant(candidate,c))|_->None)candidate.decls)forms in
    match matches with [one]->Some one|_::_::_->None|_->
    if List.exists(fun candidate->List.exists(fun n->visible home candidate n name)(local_values candidate))forms then None else
    let primitive=Type_system.tesl_module_exports |> List.concat_map(fun(module_name,names)->List.filter_map(fun n->
      if (name=n || name=module_name ^ "." ^ n) &&
         (List.exists(fun(i:import_decl)->i.module_name=module_name)home.imports || List.mem n ["True";"False";"Unit"])
      then Some(E.Primitive(module_name ^ "." ^ n))else None)names) |> List.sort_uniq compare in
    match primitive with [one]->Some one|_->None in
  let fact home name =
    let locals=Validation_common.provided_predicate_owners home in
    let local=List.find_map(function DFact f when name=f.name || name=home.module_name ^ "." ^ f.name->Some(home,f)|_->None)home.decls in
    if local<>None then local else if List.mem_assoc name locals then None else
    match List.concat_map(fun candidate->List.filter_map(function
      | DFact f when visible home candidate f.name name->Some(candidate,f)|_->None)candidate.decls)forms with
    | [one]->Some one|_->None in
  let primitive_type home = function
    | TName n when List.mem n.name ["Int";"String";"Bool"] && not(List.exists(fun candidate->List.exists(function
        | DType(TypeAdt t)->visible home candidate t.name n.name|DType(TypeNewtype t)->visible home candidate t.name n.name
        | DRecord r->visible home candidate r.name n.name|DEntity e->visible home candidate e.name n.name|_->false)candidate.decls)forms) -> Some n.name
    | _->None in
  let checked=Hashtbl.create 8 in
  let require_original ()=match Parser.parse_module root.source_file source with
    | Parser.Ok original when original=root->()
    | _->reject(Location.dummy_loc root.source_file) "literal proof checking requires the exact parsed source module"in
   let reject_capabilities ~loc ~fact_name ~validator (home:module_form) (fn:func_decl) =
     if fn.capabilities <> [] then
       let required = String.concat ", " fn.capabilities in
       let dependency = if fn.name = validator && home.module_name = root.module_name then
         Printf.sprintf "validator `%s`" validator
       else Printf.sprintf "function `%s.%s`, used by validator `%s`," home.module_name fn.name validator in
       reject loc (Printf.sprintf
         "cannot validate literals for `%s` at compile time: %s requires [%s]. Capabilities are only available at runtime.\nHint: remove `literal via %s` from the fact declaration. Call `%s` at runtime from a function declaring the required capabilities (`requires [%s]`), then use its returned proof-carrying value."
         fact_name dependency required validator validator required) in
   let validate_functions ~rule_loc ~fact_name ~validator visited =
    let reached=ref []in
    let rec include_decl home decl = if not(List.mem(home,decl)!reached)then begin
      reached:=(home,decl)::!reached;
       (match decl with
        | DFunc f ->
          reject_capabilities ~loc:rule_loc ~fact_name ~validator home f;
          if not(List.mem f.kind [FnKind;CheckKind;EstablishKind]) || f.http_methods<>[] then
            reject f.loc "literal rules require a pure validator closure without HTTP operations"
        | _ -> ());
      let rec pattern_names=function PVar n->[n]|PCon p->List.concat_map(fun(_,p)->pattern_names p)p.fields|_->[]in
      let rec walk bound expr =
        (match expr with
         | ESqlQuery _|EWithDatabase _|EWithCapabilities _|EWithTransaction _|ETelemetry _
         | EEnqueue _|EPublish _|EStartWorkers _|ECacheGet _|ECacheSet _|ECacheDelete _|ECacheInvalidate _
         | ESendEmail _|EStartEmailWorker _|EServe _ -> reject(Checker.expr_loc expr) "literal validator closure contains a runtime effect"
         | _->());
        (match expr with EOk e->
          let rec proof_refs=function PredApp p->(match resolve home p.pred with
            |Some(E.Function(m,f))->include_decl m (DFunc f)|_->())
            |PredAnd p->proof_refs p.left;proof_refs p.right in proof_refs e.proof
         | _->());
        (match E.name expr with Some n when not(List.mem n bound)->
          (match resolve home n with Some(E.Function(m,f))->include_decl m (DFunc f)
            |Some(E.Constant(m,c))->include_decl m (DConst c)|_->())|_->());
        match expr with
        | ELet e->walk bound e.value;walk(e.name::bound)e.body
        | ELetProof e->walk bound e.value;walk(e.value_name::e.proof_name::bound)e.body
        | ELambda e->walk(List.map(fun(p:binding)->p.name)e.params @ bound)e.body
        | ECase e->walk bound e.scrut;List.iter(fun(a:case_arm)->let bound=pattern_names a.pattern @ bound in Option.iter(walk bound)a.guard;walk bound a.body)e.arms
        | _->Ast_visitor.iter_children(walk bound)expr in
      (match decl with DFunc f->walk(List.map(fun(p:binding)->p.name)f.params)f.body
        | DConst c->walk[]c.value|_->())
    end in
    List.iter(fun(m,d)->include_decl m d)visited;
    List.iter(fun(m:module_form)->
      let selected=List.filter_map(fun(owner,d)->if owner=m then Some d else None)!reached in
      if selected<>[] then begin
        let decls=List.filter(function
          | (DFunc _|DConst _)as d->List.mem d selected
          | DFact _|DType _|DRecord _|DEntity _->true|_->false)m.decls in
        let sub={m with decls;exports=[]}in
        let stack=Stack.create()and nodes=ref 0 in
        List.iter(function DFunc f->Stack.push(f.body,0)stack|DConst c->Stack.push(c.value,0)stack|_->())selected;
        while not(Stack.is_empty stack)do
          let expr,depth=Stack.pop stack in incr nodes;
          if depth>512 || !nodes>100000 then reject(Checker.expr_loc expr) "literal validator exceeds compiler complexity limits";
          Ast_visitor.iter_children(fun child->Stack.push(child,depth+1)stack)expr
        done;
        Literal_proof_context.with_sites [] (fun()->
          let _,_,_,_,_,_,types=Checker.check_module_with_metadata sub in
          let proofs=Proof_checker.check_module sub and validation=Validation.check_module sub in
          if types<>[] || proofs<>[] || validation<>[] then reject(Location.dummy_loc m.source_file)
            "literal validator must type-check and establish its proof without relying on literal-proof inference")
      end)forms in
  let rule home f = match f.literal_via with None->None|Some reference->
    require_original();
    let name=reference.name in
    let key=home.module_name ^ "." ^ f.name in
    (match Hashtbl.find_opt checked key with Some rule->Some rule|None->
      let fn=List.find_opt(fun(fn:func_decl)->fn.name=name || home.module_name ^ "." ^ fn.name=name)
        (List.filter_map(function DFunc f->Some f|_->None)home.decls)in
       let fn=match fn with Some fn->fn|None->reject f.loc "literal rule must name a validator declared in the fact's module"in
       reject_capabilities ~loc:reference.loc ~fact_name:f.name ~validator:fn.name home fn;
      let parameter=match f.params,fn.params with [p],[arg] when p.proof_ann=None && arg.proof_ann=None->p,arg
        | _->reject f.loc "literal rules require one plain argument for one unary fact"in
      let p,arg=parameter in
      let ty=match primitive_type home p.type_expr with Some ty when primitive_type home arg.type_expr=Some ty->ty
        | _->reject f.loc "literal rules currently require matching Int, String or Bool types"in
      let binding,optional=match fn.kind,fn.return_spec with
        | CheckKind,RetAttached r->r.binding,false
        | (FnKind|EstablishKind),RetMaybeAttached{outer_ty=None;binding;_}->binding,true
        | _->reject f.loc "literal validator must be a pure check or a pure optional proof-producing function"in
       if fn.http_methods<>[] then reject f.loc "literal validators cannot have HTTP operations";
       if primitive_type home binding.type_expr<>Some ty then
         reject f.loc "literal validators cannot change the value type";
      (match binding.proof_ann with Some(PredApp p) when p.args=[binding.name] &&
        (match fact home p.pred with Some(m,decl)->m=home && decl.name=f.name|_->false)->()
       | _->reject f.loc "literal validator must return the exact declared fact on its returned value");
       validate_functions ~rule_loc:reference.loc ~fact_name:f.name ~validator:fn.name [home,DFunc fn];
      Hashtbl.add checked key(home,fn,ty,optional);Some(home,fn,ty,optional))in
  List.iter(function DFact f->ignore(rule root f)|_->())root.decls;
  List.iter(fun(binder,ty,proof,value)->
    let rec prove = function
      | PredAnd p->Option.bind(prove p.left)(fun left->Option.map(fun right->left @ right)(prove p.right))
      | PredApp p when p.args=[binder]->
        (match fact root p.pred with None->None|Some(home,f)->
          match rule home f with None->None|Some(home,fn,expected,optional)->
            if primitive_type root ty<>Some expected then reject(Checker.expr_loc value) "literal proof annotation has the wrong value type";
            let visited=ref []in
            let visit m f=if not(List.mem(m,f)!visited)then visited:=(m,f)::!visited in
            let input=E.literal value in
            let result=E.evaluate ~resolve ~visit home fn input in
            let returned=match optional,result with true,E.Something v->v|false,v->v
              | _->raise E.Rejected in
            if returned<>input then reject(Checker.expr_loc value) "literal validator changes this value; use an already-normalized literal or validate explicitly";
            let canonical=home.module_name ^ "." ^ f.name in
            Some(if canonical=p.pred then [PredApp p]else[PredApp p;PredApp{p with pred=canonical}]))
      | _->None in
    try match prove proof with None->()|Some proofs->
      List.iter(fun proof->sites:={C.value;binder;proof}::!sites)proofs
    with Invalid e->errors:=e::!errors
      | E.Rejected->errors:={loc=Checker.expr_loc value;message="literal is rejected by its declared proof validator"}::!errors
      | E.Unsupported message->errors:={loc=Checker.expr_loc value;message="cannot establish literal proof at compile time: " ^ message}::!errors)wanted in
 let result = try
   Source_input.with_pinned_files [root_file,source](fun()->load root source);
   Source_input.with_pinned_files !inputs(fun()->
     Literal_proof_context.with_sites [] prepare;
     Literal_proof_context.with_sites !sites run)
 with Invalid e->errors:=e::!errors;Literal_proof_context.with_sites [] run
  | Sys_error message|Invalid_argument message|Unix.Unix_error(_,_,message)->errors:={loc=Location.dummy_loc root.source_file;message}::!errors;Literal_proof_context.with_sites [] run in
 (try Source_input.without_pinned_files(fun()->
    if observe()<>original_root then reject(Location.dummy_loc root.source_file) "literal proof source changed during checking";
    List.iter(fun(file,text)->if file<>root_file && not(Option.fold ~none:false ~some:(fun graph->file=graph.entry)!active_graph) && Source_input.read file<>text then reject(Location.dummy_loc file) "literal proof dependency changed during checking")!inputs;
    List.iter(fun(file,name,expected)->if Source_input.canonical_path(Validation_common.resolve_local_import_path file name)<>expected then
      reject(Location.dummy_loc file) "literal proof import resolution changed during checking")!edges)
  with Invalid e->errors:=e::!errors|Sys_error message|Unix.Unix_error(_,_,message)->errors:={loc=Location.dummy_loc root.source_file;message}::!errors);
 result,List.rev !errors
