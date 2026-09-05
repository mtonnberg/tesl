open Alcotest

let self = if Filename.is_relative Sys.executable_name then Filename.concat (Sys.getcwd ()) Sys.executable_name else Sys.executable_name
let run ?(timeout=5) args = Process_runner.run ~timeout ~cwd:(Sys.getcwd ()) self args
let available () = not Sys.win32 || Sys.getenv_opt "TESL_PROCESS_RUNNER" <> None

let argv () = if available () then begin
  let args = ["a b"; "räksmörgås😀"; "$(echo should-not-run)"; "x;y&z"; "quote\"tail\\"; ""] in
  let code, output = run ("--echo-argv" :: args) in
  check int "exit" 0 code;
  check string "literal argv" (String.concat "\000" args) output
end
let exit_status () = if available () then begin
  let code, output = run ["--exit-seven"] in
  check int "exit status preserved" 7 code;
  check bool "stderr captured" true (String.length output >= 10)
end
let deadline () = if available () then begin
  let start = Unix.gettimeofday () in
  let code, _ = run ~timeout:1 ["--sleep"] in
  check int "timeout distinct from failed test" 124 code;
  check bool "deadline bounded" true (Unix.gettimeofday () -. start < 5.)
end
let output_limit () = if available () then begin
  let code, output = run ["--flood"] in
  check bool "oversize fails" true (code <> 0);
  check bool "capture bounded" true (String.length output <= Process_runner.max_output)
end
let descendants () = if available () then begin
  let path = Filename.temp_file "tesl-descendant-" "" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let code, _ = run ["--parent"; path] in
    check int "parent returns" 0 code;
    let first = In_channel.with_open_bin path In_channel.input_all in
    check bool "child started" true (first <> "");
    Unix.sleepf 0.2;
    let second = In_channel.with_open_bin path In_channel.input_all in
    check string "child stopped with parent" first second)
end
let missing_executable () = if available () then begin
  let code, _ = Process_runner.run ~timeout:1 ~cwd:(Sys.getcwd ()) "tesl-definitely-missing-process" [] in
  check bool "missing executable explicit failure" true (code <> 0)
end
let windows_requires_owner () = if Sys.win32 && not (available ()) then begin
  let code, output = run ["--echo-argv"; "no-owner"] in
  check int "unsupported unowned execution" 125 code;
  check bool "owner instruction" true (String.length output > 0)
end

let () = match Array.to_list Sys.argv |> List.tl with
 | "--echo-argv" :: args -> print_string (String.concat "\000" args)
 | ["--exit-seven"] -> prerr_string "child stderr"; exit 7
 | ["--sleep"] -> Unix.sleepf 30.
 | ["--flood"] -> for _ = 1 to 1024 do print_string (String.make 65536 'x') done
 | ["--heartbeat"; path] ->
   for i = 1 to 3000 do
     let out = open_out_gen [Open_wronly; Open_append; Open_binary] 0o600 path in
     output_string out (string_of_int i ^ "\n");
     close_out out;
     Unix.sleepf 0.01
   done
 | ["--parent"; path] ->
   ignore (Unix.create_process self [|self; "--heartbeat"; path|] Unix.stdin Unix.stdout Unix.stderr);
   let rec await remaining =
     if (Unix.stat path).Unix.st_size > 0 then ()
     else if remaining = 0 then exit 3 else (Unix.sleepf 0.01; await (remaining-1)) in
   await 200
 | _ -> Alcotest.run "Native compiler subprocesses" ["ownership", List.map (fun (name, test) -> test_case name `Quick test)
     ["argv literal", argv; "exit status", exit_status; "deadline", deadline;
      "output limit", output_limit; "parent exit kills descendants", descendants;
      "missing executable", missing_executable; "Windows owner required", windows_requires_owner]]
