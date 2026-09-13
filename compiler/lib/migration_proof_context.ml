type site = { owner : Ast.module_form; constructor : string; field : string;
  argument : Ast.expr; projection : Proof_kernel.proven_fact list; predicates : (string * string) list }
type t = { sources : (Ast.module_form * string) list; sites : site list;
  validate : unit -> unit }
let active : t list ref = ref []
let owner : (t * Ast.module_form) option ref = ref None
let create ~sources ~sites ~revalidate = {sources;sites;validate=revalidate}
let revalidate t = t.validate ()
let require_graph t sources =
  revalidate t;
  let sort = List.sort (fun ((a:Ast.module_form),_) (b,_) -> compare a.source_file b.Ast.source_file) in
  if sort sources <> sort t.sources then invalid_arg "migration proof context belongs to another complete source graph"
let scope contexts run =
  let previous = !active and previous_owner = !owner in
  Query_cache.clear (); active := contexts; owner := None;
  Fun.protect ~finally:(fun () -> active := previous; owner := previous_owner; Query_cache.clear ()) run
let without_context run = scope [] run
let with_contexts contexts run =
  List.iter revalidate contexts;
  let result = scope contexts run in
  List.iter revalidate contexts; result
let with_context t run = with_contexts [t] run
let with_module m run =
  let previous = !owner in
  let candidates=List.filter (fun t -> List.exists (fun site -> site.owner=m) t.sites &&
    List.exists (fun (captured,_) -> captured=m) t.sources) !active in
  owner := (match candidates with [t] -> Some (t,m) | _ -> None);
  Fun.protect ~finally:(fun () -> owner := previous) run
let transport ~constructor ~field argument facts =
  match !owner with
  | Some (t,m) ->
    let sites=List.filter (fun site -> site.owner=m && site.constructor=constructor &&
      site.field=field && site.argument=argument) t.sites in
    let pairs=List.concat_map (fun site -> site.predicates) sites in
    let facts=facts @ List.concat_map (fun site -> site.projection) sites in
    facts @ List.concat_map (fun (previous,current) ->
      List.map (Proof_kernel.migration_same_predicate ~previous ~current) facts) pairs
  | None -> facts
