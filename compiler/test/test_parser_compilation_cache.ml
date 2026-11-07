open Alcotest

let source = "module Cache exposing []\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int = 1\n"
let get file bytes = match Parser.parse_module file bytes with
 | Parser.Ok m -> m | Parser.Err error -> fail error.msg

let exact_inputs () =
 let first = Parser.with_module_cache (fun () ->
  let first = get "one.tesl" source in
  check bool "same bytes and filename reuse immutable AST" true (first == get "one.tesl" source);
  Parser.with_module_cache (fun () -> check bool "nested scope" true (first == get "one.tesl" source));
  let other = get "two.tesl" source in
  check string "source locations retain requested filename" "two.tesl" other.source_file;
  let changed = get "one.tesl" (source ^ "fn second() -> Int = 2\n") in
  check bool "changed bytes are parsed" false (first = changed);
  (match Parser.parse_module "one.tesl" "not a module" with
   | Parser.Err _ -> () | Parser.Ok _ -> fail "cached parse hid malformed source");
  check bool "repair can reuse exact original bytes" true (first == get "one.tesl" source);
  first) in
 Parser.with_module_cache (fun () -> check bool "scope ends reuse" false (first == get "one.tesl" source))

let exception_and_eviction () =
 let escaped = ref None in
 (try Parser.with_module_cache (fun () -> escaped := Some (get "one.tesl" source); raise Exit) with Exit -> ());
 Parser.with_module_cache (fun () ->
  let first = get "one.tesl" source in
  check bool "exception ends reuse" false (Option.get !escaped == first);
  for index = 1 to 257 do ignore (get (Printf.sprintf "input-%d.tesl" index) source) done;
  let after = get "one.tesl" source in
  check bool "eviction recomputes AST" false (first == after);
  check bool "eviction retains exact parsed structure" true (first = after))

let () = run "compilation parse cache" ["exact source", [
 test_case "filename bytes and nested scopes" `Quick exact_inputs;
 test_case "exception cleanup and eviction" `Quick exception_and_eviction]]
