(** Backend-neutral desugaring contract.

    Effect forms remain in the AST until the selected backend handles them. The
    shared pass must therefore preserve expression identity and locations.
*)

open Ast

let loc = Validation_common.gen_loc

let test_empty_tables_are_backend_neutral () =
  let expr = ELit { lit = LInt 1; loc } in
  if Desugar.desugar_expr (Desugar.empty_tables ()) expr <> expr then
    failwith "desugar changed a backend-neutral expression"

let test_app_email_lowers_before_serve () =
  let source = {|module EmailStartup exposing []
main() -> App requires [emailCap] =
  App {
    database: Store
    email: [AppMail]
    api: AppServer
    port: 8080
  }
|} in
  let parsed = match Parser.parse_module "<email-startup>" source with
    | Ok parsed -> parsed
    | Err error -> failwith ("startup fixture did not parse: " ^ error.msg) in
  let main = match List.find_opt (function DFunc fd -> fd.kind = MainKind | _ -> false) parsed.decls with
    | Some (DFunc fd) -> fd
    | _ -> failwith "startup fixture has no main" in
  let lowered = Desugar.lower_main_app parsed.decls main in
  let rec startup_order = function
    | EWithCapabilities { body; _ } | EWithDatabase { body; _ } -> startup_order body
    | ELet { value; body; _ } -> startup_order value @ startup_order body
    | EStartEmailWorker { email_name; _ } -> ["email:" ^ email_name]
    | EServe { server_name; _ } -> ["serve:" ^ server_name]
    | _ -> [] in
  match startup_order lowered.body with
  | ["email:AppMail"; "serve:AppServer"] -> ()
  | order -> failwith ("wrong App startup order: " ^ String.concat ", " order)

let () =
  test_empty_tables_are_backend_neutral ();
  test_app_email_lowers_before_serve ();
  print_endline "desugar: PASS"
