(** A2-3 conformance: the single-source effect→capability registry.

    Before A2-3, [var_caps] (validation_capabilities.ml) re-listed every
    capability-bearing stdlib name by hand, and it had DRIFTED from the actual
    stdlib: `UUID.v4`/`UUID.v7` had no entry (compiled clean with `requires []`
    though runtime-gated), and the list carried phantom dotted `Time.durationMs`/…
    forms while the bare pure ops went unmapped.

    A2-3 makes [Type_system.stdlib_capabilities] the ONE source and derives
    [var_caps] from it. This test binds that registry to an INDEPENDENT hand-written
    oracle so it cannot silently drift again, pins the UUID drift-fix, and asserts
    the pure PosixMillis arithmetic ops carry no capability.

    Pure OCaml, no alcotest / no Racket, so it runs in every gate:
      dune exec test/test_capability_registry.exe *)

let failures = ref 0
let check name ok =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n" name end

(* Independent oracle: name -> the capability it introduces. Written by hand here;
   [Type_system.stdlib_capabilities] must agree with it EXACTLY (both directions),
   so adding/removing a capability-bearing name without updating the intent fails. *)
let oracle = [
  (* durationMs computes "elapsed since a past timestamp" and so READS the wall
     clock — its runtime (tesl/time.rkt:42-43) calls `require-capabilities! time`.
     C4/cap drift-fix (2026-07-05): it must charge `time`, like now/nowMillis. *)
  "now", ["time"]; "nowMillis", ["time"]; "durationMs", ["time"];
  "randomInt", ["random"]; "randomFloat", ["random"]; "generatePrefixedId", ["random"];
  "env", ["envRead"]; "envInt", ["envRead"];
  "envString", ["envRead"]; "requireEnv", ["envRead"];
  "deadJobs", ["queueRead"]; "requeue", ["queueWrite"];
  "JWT.sign", ["jwt"]; "JWT.verify", ["jwt"]; "JWT.decode", ["jwt"];
  "HttpClient.get", ["httpClient"]; "HttpClient.post", ["httpClient"];
  "HttpClient.put", ["httpClient"]; "HttpClient.delete", ["httpClient"];
  "UUID.v4", ["uuid"]; "UUID.v7", ["uuid"];
  "ask", ["aiProvider"]; "askReply", ["aiProvider"]; "askWith", ["aiProvider"];
  "askFor", ["aiProvider"]; "converse", ["aiProvider"];
  "converseStreaming", ["aiProvider"]; "agentRun", ["aiProvider"];
]

let () =
  (* 1. the registry agrees with the oracle for every capability-bearing name. *)
  List.iter (fun (name, caps) ->
    check (Printf.sprintf "%s -> [%s]" name (String.concat ";" caps))
      (Type_system.stdlib_capabilities_of name = caps))
    oracle;

  (* 2. the registry has EXACTLY the oracle's names — no extra, none missing. *)
  let reg_names = List.sort compare (List.map fst Type_system.stdlib_capabilities) in
  let ora_names = List.sort compare (List.map fst oracle) in
  check "registry name set == oracle name set (no drift)" (reg_names = ora_names);

  (* 3. UUID drift-fix regression: v4/v7 charge uuid (they were MISSING pre-A2-3). *)
  check "UUID.v4 charges uuid" (Type_system.stdlib_capabilities_of "UUID.v4" = ["uuid"]);
  check "UUID.v7 charges uuid" (Type_system.stdlib_capabilities_of "UUID.v7" = ["uuid"]);

  (* 4. phantom-fix: pure PosixMillis arithmetic carries NO capability, and the old
     phantom dotted `Time.*` forms resolve to nothing. *)
  List.iter (fun n ->
    check (Printf.sprintf "pure `%s` introduces no capability" n)
      (Type_system.stdlib_capabilities_of n = []))
    [ "diffMs"; "addMs"; "subtractMs"; "formatTime";
      "secondsToPosix"; "posixToMillis";
      "Time.diffMs" ];

  (* 5. every capability the registry mentions is a real capability token. *)
  let known_caps =
    [ "time"; "random"; "envRead"; "jwt"; "httpClient"; "uuid";
      "aiProvider"; "queueRead"; "queueWrite" ] in
  List.iter (fun (name, caps) ->
    List.iter (fun c ->
      check (Printf.sprintf "%s: `%s` is a known capability token" name c)
        (List.mem c known_caps))
      caps)
    Type_system.stdlib_capabilities;

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
