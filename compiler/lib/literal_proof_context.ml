open Ast
type site = { value:expr; binder:string; proof:proof_expr }
let active : site list ref = ref []
let with_sites sites run =
  let previous = !active in
  active := sites;
  Fun.protect ~finally:(fun ()->active:=previous) run
let proofs subject expression =
  List.filter_map(fun site->if site.value!=expression then None else
    let rec rename = function
      | PredApp p -> PredApp{p with args=List.map(fun name->if name=site.binder then subject else name)p.args}
      | PredAnd p -> PredAnd{p with left=rename p.left;right=rename p.right}in
    Some(Proof_kernel.elaborated Proof_kernel.LiteralRule(rename site.proof)))!active
