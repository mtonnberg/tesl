(* Full family Contract diagnostics, not just plan construction. Each timed call
   owns fresh compilation caches and includes ABI lookup, history discovery,
   parsing and every Contract judgment. No timing threshold; complete diagnostics
   must equal the independent single-module path, including order and locations. *)
module H = Migration_history_sources
let single sources = List.concat_map (fun (file,source) ->
 match Parser.parse_module file source with
 | Err e -> [Frontend_check.diag_of_parse_error e]
 | Ok m -> Migration_contract.diagnostics source m) sources
let operation ~project_root ~family diagnostics =
 Migration_program.with_compilation_cache (fun () ->
  let abi=match Migration_abi.current () with Ok x->x | Error e->failwith e.message in
  let history=match H.discover ~compiler_abi:(Migration_abi.id abi) ~project_root ~family with
   | Ok x->x | Error e->failwith e.message in
  let contracts=H.contracts history in
  H.current history |> fun current -> current.version,List.length contracts,
   diagnostics (List.map (fun (c:H.migration_source) -> c.path,c.contents) contracts))
let () =
 if Array.length Sys.argv<>4 then failwith "usage: bench_migration_contract PROJECT_ROOT FAMILY RUNS";
 let project_root=Unix.realpath Sys.argv.(1) and family=Sys.argv.(2) in
 let runs=int_of_string Sys.argv.(3) in
 if runs<1 then invalid_arg "runs must be positive";
 let expected=ref None in
 let measure run (mode,diagnostics) =
  Gc.full_major ();
  let allocations=Gc.allocated_bytes () and cpu=Sys.time () and start=Unix.gettimeofday () in
  let ((version,contracts,ds) as result)=operation ~project_root ~family diagnostics in
  let seconds=Unix.gettimeofday ()-.start and cpu_seconds=Sys.time ()-.cpu in
  let allocated_bytes=Gc.allocated_bytes ()-.allocations in
  (match !expected with None->expected:=Some result | Some previous->
   if result<>previous then failwith "batch changed complete ordered diagnostics");
  Printf.printf "{\"mode\":%S,\"run\":%d,\"version\":%d,\"contracts\":%d,\"seconds\":%.6f,\"cpu_seconds\":%.6f,\"allocated_bytes\":%.0f,\"diagnostics\":%d,\"equal\":true}\n%!"
   mode run version contracts seconds cpu_seconds allocated_bytes (List.length ds) in
 for run=1 to runs do
  let pair=["single",single;"batch",Migration_contract.diagnostics_batch] in
  List.iter (measure run) (if run mod 2=1 then pair else List.rev pair)
 done
