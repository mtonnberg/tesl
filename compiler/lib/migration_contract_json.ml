module P = Migration_program
module C = Migration_contract
let to_json source =
 let quote=Migration_row_companion.quote in
 let array f xs="[" ^ String.concat "," (List.map f xs) ^ "]" in
 let program=P.source_program source in
 P.unresumed program;
 let database (d:P.database) =
  let nodes=Migration_canonical_nodes.create ~quote in
  let revision (c:Migration_records.contract) = c.contract_version in
  let earlier,items=Migration_records.entries (P.records source d.identity) ~covered:(Emit_fragment.covered ())
    ~count:(fun s -> s.contract_count) ~items:(fun t -> t.contracts) ~revision in
  let contracts=Emit_fragment.render_entries ~earlier ~document:"contracts" ~database:d.identity ~revision nodes
    (Migration_records.contract_json ~quote ~contract:(Migration_canonical_nodes.reference nodes)) items in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"contracts":%s,"canonicalNodes":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) contracts (Migration_canonical_nodes.to_json nodes) in
 Printf.sprintf {|{"version":1,"kind":"compiled-row-contract-history","contractEncoding":"tesl-canonical-nodes-v1","compilerAbi":%s,"databases":%s}|}
  (quote(P.compiler_abi program)) (array database(P.databases program))
