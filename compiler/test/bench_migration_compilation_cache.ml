(* Compare added caches with the previous inventory-only scope. Exact-source
   equality is checked; timings have no pass/fail threshold. *)
let () =
 if Array.length Sys.argv <> 4 then failwith "usage: bench_migration_compilation_cache PROJECT_ROOT FAMILY ITERATIONS";
 let project_root = Unix.realpath Sys.argv.(1) and family = Sys.argv.(2) in
 let iterations = int_of_string Sys.argv.(3) in
 if iterations < 1 then invalid_arg "iterations must be positive";
 let abi = match Migration_abi.current () with Ok x -> x | Error e -> failwith e.message in
 let history () = match Migration_history_sources.discover_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~project_root ~family with
  | Ok x -> x | Error e -> failwith e.message in
 let file = Filename.concat project_root "app.tesl" in
 let source = Source_input.read file in
 let parse () = match Parser.parse_module file source with
  | Parser.Ok x -> x | Parser.Err e -> failwith e.msg in
 let measure name count load =
  let expected = load () in
  List.iter (fun cached ->
   let work () =
    let last = ref None in
    for _ = 1 to count do last := Some (load ()) done;
    Option.get !last in
   let started = Unix.gettimeofday () in
   let result = if cached then Migration_program.with_compilation_cache work
     else Migration_inventory.with_cache work in
   let seconds = Unix.gettimeofday () -. started in
   if result <> expected then failwith (name ^ " changed checked result");
   Printf.printf "{\"component\":%S,\"cached\":%b,\"iterations\":%d,\"seconds\":%.6f,\"equal\":true}\n%!"
    name cached count seconds) [false;true;true;false] in
 measure "parse" (iterations * 10) parse;
 measure "history-with-live-guards" iterations history
