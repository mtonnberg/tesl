(** Durable seam test: every GATED runtime file set builds on its own.

    The Go runtime ships BY REFERENCE — a program gets the always-shipped files plus the ones
    its features pull in — and the gates in {!Emit_go.runtime_file_gates} are EXCLUSION
    filters: a file is dropped when its gate's condition is false.

    That makes one mistake invisible until a very specific program appears. A declaration in a
    file gated on condition A, used by a file gated on condition B, compiles fine for every
    program that pulls both and fails for the first one that pulls B without A. Measured, three
    times in one session:

      - [PgGroupZone] was declared in [dbquery.go] (postgres) and used by [timetrunc.go]
        (timezone), so a Memory-backed program that truncated by hour did not compile.
        [example/learn/lesson21-sql-reference.tesl] is that program, and it stayed broken until
        someone ran it.
      - the session-policy state lived in [sso_route.go] (http) and was read by [jwt.go]
        (always shipped), so a program that signed a token without serving HTTP did not
        compile.
      - and the same shape once more while fixing the first two.

    Each was found by a corpus program rather than by a check. This is the check: build the
    always-shipped set alone, then each gate on top of it, and let the Go compiler answer.
    Eight builds, no Tesl programs involved — a gate combination is a property of the runtime,
    not of any source that reaches it.

    A gate that genuinely NEEDS another one is fine, but it has to say so: add it to
    [gate_prerequisites] below, which is then the written record of the coupling rather than an
    accident that happens to hold. *)

let ( // ) = Filename.concat

(* `Alcotest.failf` — the labelled-argument form of `fail` makes a hand-rolled
   `ksprintf` wrapper not type. *)
let failf fmt = Alcotest.failf fmt

(* Gates that cannot stand alone, WITH THE REASON. A row here is a claim that the coupling is
   real — that no program can pull the gate without also pulling its prerequisite — not a
   licence to leave a stray reference in place. *)
let gate_prerequisites : (string * string list) list = [
  (* A `load-test` block is written `load-test "…" for <Server>`, so it names a server and the
     program therefore serves HTTP. `loadtest.go` measures that dispatch and reads its
     `ApiResponse`, which is the api-test view in the http set. The implication holds in the
     surface syntax, not merely in today's corpus. *)
  "load_test", [ "http" ];
]

let go_available () = Sys.command "go version >/dev/null 2>&1" = 0

let write_file path contents =
  let directory = Filename.dirname path in
  if not (Sys.file_exists directory) then
    ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote directory)));
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let remove_tree path =
  if Sys.file_exists path then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))

(* Every runtime file that is in NO gate: what a program with no features at all receives. *)
let ungated_files () =
  let gated =
    List.concat_map snd Emit_go.runtime_file_gates in
  List.filter (fun (name, _) -> not (List.mem name gated)) Embedded_go_runtime.files

let files_named names =
  List.filter (fun (name, _) -> List.mem name names) Embedded_go_runtime.files

(* Build one file set as its own module. The go.mod carries the driver requires only when the
   set includes the PostgreSQL half, which is the same rule the emitter applies. *)
let build_set label files =
  let root = Filename.temp_dir "tesl-go-gate" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    List.iter (fun (name, contents) ->
      write_file (root // "internal" // "teslrt" // name) contents) files;
    (* The same requires the emitter writes for the same file sets: Argon2id travels with
       `password.go`, the driver with the PostgreSQL half.  A set that carries the file without
       its require is not a set the emitter ever produces. *)
    let has name = List.exists (fun (file, _) -> file = name) files in
    let requires =
      (if has "password.go" then
         "\nrequire golang.org/x/crypto v0.55.0\n\nrequire golang.org/x/sys v0.47.0 // indirect\n"
       else "")
      ^ (if has "postgres.go" || has "dbquery.go" then Emit_go.postgres_dependency_go_mod
         else "") in
    write_file (root // "go.mod")
      (Printf.sprintf "module tesl.gategate\n\ngo 1.26\n%s" requires);
    (* And the go.sum for whatever the requires named: a pinned dependency without its hashes
       does not resolve, and the emitter writes both together for the same reason. *)
    if requires <> "" then
      write_file (root // "go.sum")
        ((if has "password.go" then Emit_go.password_dependency_go_sum else "")
         ^ (if has "postgres.go" || has "dbquery.go" then Emit_go.postgres_dependency_go_sum
            else ""));
    (* `go build` rather than `go vet`: the question is whether the set is a COMPLETE package —
       every name it references declared somewhere in it — which is exactly what the compiler's
       resolution answers, and the only failure this test is about. *)
    let command =
      Printf.sprintf "cd %s && CGO_ENABLED=0 go build ./... 2>&1" (Filename.quote root) in
    let channel = Unix.open_process_in command in
    let output = In_channel.input_all channel in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> ()
    | _ ->
      failf
        "the `%s` runtime file set does not build on its own:\n%s\n\
         A file in this gate names something declared in a DIFFERENT gate. Move the \
         declaration to a file that is never gated, or — if the coupling is real — record it \
         in `gate_prerequisites` so the pairing is written down rather than assumed."
        label output)

let test_ungated_set_builds () =
  if not (go_available ()) then
    Printf.printf "SKIP: go is not on PATH\n%!"
  else begin
    let files = ungated_files () in
    (* A sanity floor: if this ever went empty the test below would pass vacuously. *)
    if List.length files < 10 then
      failf "only %d ungated runtime file(s) — the gate table cannot be right"
        (List.length files);
    build_set "always-shipped" files
  end

let test_each_gate_builds () =
  if not (go_available ()) then
    Printf.printf "SKIP: go is not on PATH\n%!"
  else
    List.iter (fun (gate, names) ->
      let prerequisites =
        match List.assoc_opt gate gate_prerequisites with Some gates -> gates | None -> [] in
      let extra = List.concat_map (fun other -> Emit_go.runtime_gate_files other) prerequisites in
      let files = ungated_files () @ files_named (names @ extra) in
      (* Every file the gate names must EXIST: a rename that misses this table drops the file
         from every program silently, which is the other half of the same class. *)
      List.iter (fun name ->
        if not (List.mem_assoc name Embedded_go_runtime.files) then
          failf "the `%s` gate names %s, which is not a runtime file" gate name) names;
      build_set gate files)
      Emit_go.runtime_file_gates

(* The gates PARTITION the runtime: a file in two gates would be dropped when either condition
   is false, which is never what a gate means. *)
let test_no_file_is_in_two_gates () =
  let seen = Hashtbl.create 32 in
  List.iter (fun (gate, names) ->
    List.iter (fun name ->
      match Hashtbl.find_opt seen name with
      | Some other ->
        failf "%s is in both the `%s` and `%s` gates, so it is dropped unless BOTH \
               conditions hold" name other gate
      | None -> Hashtbl.replace seen name gate) names)
    Emit_go.runtime_file_gates

let () =
  Alcotest.run "Go runtime gates" [
    "file-sets", [
      Alcotest.test_case "the always-shipped set builds alone" `Slow test_ungated_set_builds;
      Alcotest.test_case "each gate builds on top of it" `Slow test_each_gate_builds;
      Alcotest.test_case "no file is in two gates" `Quick test_no_file_is_in_two_gates;
    ];
  ]
