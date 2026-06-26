(** Tests for the Tesl.HttpClient stdlib module.

    Covers:
    1. Parser — module import accepted, function names parsed
    2. Type inference — HttpClient functions infer correct types
    3. HttpResponse field access — status, body, headers fields
    4. Type mismatch errors — wrong argument types rejected
    5. Capability system — httpClient capability required and enforced
*)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

let http_imports =
  "import Tesl.Prelude exposing [Int, String, Bool, List, Unit]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Tuple exposing [Tuple2]\n\
   import Tesl.HttpClient exposing [httpClient, HttpResponse, HttpClient.get, HttpClient.post, HttpClient.put, HttpClient.delete]\n"

let module_ ?(name="M") ?(exports="") ?(extra="") body =
  Printf.sprintf "#lang tesl\nmodule %s exposing [%s]\n%s%s\n%s"
    name exports http_imports extra body

let compile_ok name src =
  match Compile.compile_source ~root_path:root "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

let compile_err name src =
  let diags = Compile.check_source "<test>" src in
  if diags = [] then
    Alcotest.failf "%s: expected errors but compilation succeeded" name
  else
    String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags)

let contains needle haystack =
  let n = String.length needle in
  let m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

let check_contains name src substr =
  let racket = compile_ok name src in
  if not (contains substr racket) then
    Alcotest.failf "%s: expected to find %S in output:\n%s" name substr racket

let [@warning "-32"] check_not_contains name src substr =
  let racket = compile_ok name src in
  if contains substr racket then
    Alcotest.failf "%s: expected NOT to find %S in output:\n%s" name substr racket

(* ── 1. Parser tests ─────────────────────────────────────────────────────── *)

let test_import_accepted () =
  let src = module_ ~exports:"dummy" {|
fn dummy(n: Int) -> Int = n
|} in
  check_contains "import_accepted" src "dummy"

let test_httpclient_get_parses () =
  let src = module_ ~exports:"fetchUrl" {|
capability myHttp implies httpClient

handler fetchUrl(url: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.get url []
|} in
  check_contains "get_parses" src "HttpClient.get"

let test_httpclient_post_parses () =
  let src = module_ ~exports:"postData" {|
capability myHttp implies httpClient

handler postData(url: String, body: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.post url [] body
|} in
  check_contains "post_parses" src "HttpClient.post"

let test_httpclient_put_parses () =
  let src = module_ ~exports:"putData" {|
capability myHttp implies httpClient

handler putData(url: String, body: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.put url [] body
|} in
  check_contains "put_parses" src "HttpClient.put"

let test_httpclient_delete_parses () =
  let src = module_ ~exports:"deleteResource" {|
capability myHttp implies httpClient

handler deleteResource(url: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.delete url []
|} in
  check_contains "delete_parses" src "HttpClient.delete"

let test_httpresponse_type_parses () =
  let src = module_ ~exports:"mkResp" {|
fn mkResp(r: HttpResponse) -> Int =
  r.status
|} in
  check_contains "httpresponse_type_parses" src "mkResp"

let test_headers_list_parses () =
  let src = module_ ~exports:"withHeaders" {|
capability myHttp implies httpClient

handler withHeaders(url: String) -> HttpResponse
  requires [myHttp] =
  let headers = [Tuple2 "Authorization" "Bearer token123"]
  HttpClient.get url headers
|} in
  check_contains "headers_list_parses" src "Authorization"

let test_capability_declaration_parses () =
  let src = module_ ~exports:"dummy" {|
capability webService implies httpClient
fn dummy(n: Int) -> Int = n
|} in
  check_contains "capability_decl_parses" src "httpClient"

let test_module_path_in_output () =
  let src = module_ ~exports:"dummy" {|
fn dummy(n: Int) -> Int = n
|} in
  check_contains "module_path_in_output" src "tesl/tesl/http-client"

let test_httpresponse_in_output () =
  let src = module_ ~exports:"getStatus" {|
fn getStatus(r: HttpResponse) -> Int =
  r.status
|} in
  check_contains "httpresponse_in_output" src "HttpResponse"

(* ── 2. Type inference tests ─────────────────────────────────────────────── *)

let test_get_returns_httpresponse () =
  let src = module_ ~exports:"fetchStatus" {|
capability myHttp implies httpClient

handler fetchStatus(url: String) -> Int
  requires [myHttp] =
  let resp = HttpClient.get url []
  resp.status
|} in
  check_contains "get_returns_httpresponse" src "fetchStatus"

let test_post_returns_httpresponse () =
  let src = module_ ~exports:"postAction" {|
capability myHttp implies httpClient

handler postAction(url: String, body: String) -> String
  requires [myHttp] =
  let resp = HttpClient.post url [] body
  resp.body
|} in
  check_contains "post_returns_httpresponse" src "postAction"

let test_status_field_is_int () =
  let src = module_ ~exports:"checkOk" {|
capability myHttp implies httpClient

handler checkOk(url: String) -> Bool
  requires [myHttp] =
  let resp = HttpClient.get url []
  resp.status == 200
|} in
  check_contains "status_field_is_int" src "checkOk"

let test_body_field_is_string () =
  let src = module_ ~exports:"getBody" {|
capability myHttp implies httpClient

handler getBody(url: String) -> String
  requires [myHttp] =
  let resp = HttpClient.get url []
  resp.body
|} in
  check_contains "body_field_is_string" src "getBody"

let test_headers_field_accessible () =
  let src = module_ ~exports:"getHeaders" {|
capability myHttp implies httpClient

handler getHeaders(url: String) -> List (Tuple2 String String)
  requires [myHttp] =
  let resp = HttpClient.get url []
  resp.headers
|} in
  check_contains "headers_field_accessible" src "getHeaders"

let test_delete_returns_httpresponse () =
  let src = module_ ~exports:"deleteAction" {|
capability myHttp implies httpClient

handler deleteAction(url: String) -> Int
  requires [myHttp] =
  let resp = HttpClient.delete url []
  resp.status
|} in
  check_contains "delete_returns_httpresponse" src "deleteAction"

let test_put_returns_httpresponse () =
  let src = module_ ~exports:"updateAction" {|
capability myHttp implies httpClient

handler updateAction(url: String, body: String) -> Int
  requires [myHttp] =
  let resp = HttpClient.put url [] body
  resp.status
|} in
  check_contains "put_returns_httpresponse" src "updateAction"

let test_response_passed_to_function () =
  let src = module_ ~exports:"isSuccess, handleResp" {|
capability myHttp implies httpClient

fn isSuccess(resp: HttpResponse) -> Bool =
  resp.status == 200

handler handleResp(url: String) -> Bool
  requires [myHttp] =
  let resp = HttpClient.get url []
  isSuccess resp
|} in
  check_contains "response_passed_to_fn" src "isSuccess"

let test_httpresponse_status_used_in_case () =
  let src = module_ ~exports:"classify" {|
capability myHttp implies httpClient

fn classify(resp: HttpResponse) -> String =
  if resp.status == 200 then
    "ok"
  else if resp.status == 404 then
    "not found"
  else
    "error"

handler getClassified(url: String) -> String
  requires [myHttp] =
  let resp = HttpClient.get url []
  classify resp
|} in
  check_contains "response_status_in_case" src "classify"

let test_custom_headers_typed () =
  let src = module_ ~exports:"callWithAuth" {|
capability myHttp implies httpClient

handler callWithAuth(url: String, token: String) -> HttpResponse
  requires [myHttp] =
  let authHeader = Tuple2 "Authorization" token
  HttpClient.get url [authHeader]
|} in
  check_contains "custom_headers_typed" src "callWithAuth"

(* ── 3. Type mismatch errors ─────────────────────────────────────────────── *)

let test_get_wrong_first_arg_type () =
  let src = module_ ~exports:"badGet" {|
capability myHttp implies httpClient

handler badGet(n: Int) -> HttpResponse
  requires [myHttp] =
  HttpClient.get n []
|} in
  let err = compile_err "get_wrong_first_arg" src in
  if not (contains "type" (String.lowercase_ascii err) ||
          contains "Int" err || contains "String" err) then
    Alcotest.failf "get_wrong_first_arg: expected type error, got: %s" err

let test_post_body_must_be_string () =
  let src = module_ ~exports:"badPost" {|
capability myHttp implies httpClient

handler badPost(url: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.post url [] 42
|} in
  let err = compile_err "post_body_must_be_string" src in
  if not (contains "type" (String.lowercase_ascii err) ||
          contains "Int" err || contains "String" err) then
    Alcotest.failf "post_body_must_be_string: expected type error, got: %s" err

let test_wrong_header_element_type () =
  let src = module_ ~exports:"badHeaders" {|
capability myHttp implies httpClient

handler badHeaders(url: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.get url [42]
|} in
  let err = compile_err "wrong_header_element_type" src in
  if not (contains "type" (String.lowercase_ascii err) ||
          contains "Int" err || contains "Tuple" err || contains "List" err) then
    Alcotest.failf "wrong_header_element_type: expected type error, got: %s" err

(* ── 4. Capability tests ─────────────────────────────────────────────────── *)

let test_handler_without_capability_fails () =
  let src = module_ ~exports:"uncapHandler" {|
handler uncapHandler(url: String) -> HttpResponse =
  HttpClient.get url []
|} in
  let err = compile_err "handler_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "handler_without_cap: expected capability error, got: %s" err

let test_fn_without_capability_fails () =
  let src = module_ ~exports:"uncapFn" {|
fn uncapFn(url: String) -> HttpResponse =
  HttpClient.get url []
|} in
  let err = compile_err "fn_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "fn_without_cap: expected capability error, got: %s" err

let test_handler_with_capability_succeeds () =
  let src = module_ ~exports:"capHandler" {|
capability myService implies httpClient

handler capHandler(url: String) -> HttpResponse
  requires [myService] =
  HttpClient.get url []
|} in
  check_contains "handler_with_cap" src "capHandler"

let test_fn_with_http_client_capability_succeeds () =
  let src = module_ ~exports:"capFn" {|
fn capFn(url: String) -> HttpResponse
  requires [httpClient] =
  HttpClient.get url []
|} in
  check_contains "fn_with_http_client_cap" src "capFn"

let test_post_without_cap_fails () =
  let src = module_ ~exports:"uncapPost" {|
handler uncapPost(url: String, body: String) -> HttpResponse =
  HttpClient.post url [] body
|} in
  let err = compile_err "post_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "post_without_cap: expected capability error, got: %s" err

let test_delete_without_cap_fails () =
  let src = module_ ~exports:"uncapDelete" {|
handler uncapDelete(url: String) -> HttpResponse =
  HttpClient.delete url []
|} in
  let err = compile_err "delete_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "delete_without_cap: expected capability error, got: %s" err

let test_put_without_cap_fails () =
  let src = module_ ~exports:"uncapPut" {|
handler uncapPut(url: String, body: String) -> HttpResponse =
  HttpClient.put url [] body
|} in
  let err = compile_err "put_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "put_without_cap: expected capability error, got: %s" err

let test_capability_error_names_http_client () =
  let src = module_ ~exports:"uncapGet" {|
handler uncapGet(url: String) -> HttpResponse =
  HttpClient.get url []
|} in
  let err = compile_err "cap_error_names_http_client" src in
  if not (contains "httpClient" err) then
    Alcotest.failf "cap_error_names_http_client: expected 'httpClient' in error, got: %s" err

let test_implied_capability_works () =
  let src = module_ ~exports:"impliedCap" {|
capability apiService implies httpClient

handler impliedCap(url: String) -> HttpResponse
  requires [apiService] =
  HttpClient.get url []
|} in
  check_contains "implied_cap_works" src "impliedCap"

let test_transitive_capability_works () =
  let src = module_ ~exports:"transCap" {|
capability httpBase implies httpClient
capability apiCap implies httpBase

handler transCap(url: String) -> HttpResponse
  requires [apiCap] =
  HttpClient.get url []
|} in
  check_contains "transitive_cap_works" src "transCap"

let test_worker_without_cap_fails () =
  let src = module_ ~exports:"uncapWorker" {|
worker uncapWorker(url: String) -> Unit =
  let _ = HttpClient.get url []
  Unit
|} in
  let err = compile_err "worker_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "worker_without_cap: expected capability error, got: %s" err

(* ── 5. Additional integration tests ─────────────────────────────────────── *)

let test_multiple_requests_in_function () =
  let src = module_ ~exports:"twoRequests" {|
capability myHttp implies httpClient

handler twoRequests(url1: String, url2: String) -> Int
  requires [myHttp] =
  let r1 = HttpClient.get url1 []
  let r2 = HttpClient.get url2 []
  r1.status + r2.status
|} in
  check_contains "multiple_requests" src "twoRequests"

let test_response_body_string_ops () =
  let src = module_ ~exports:"bodyLen"
    ~extra:"import Tesl.String exposing [String.length]\n" {|
capability myHttp implies httpClient

handler bodyLen(url: String) -> Int
  requires [myHttp] =
  let resp = HttpClient.get url []
  String.length resp.body
|} in
  check_contains "response_body_string_ops" src "bodyLen"

let test_response_used_in_maybe () =
  let src = module_ ~exports:"maybeGet" {|
capability myHttp implies httpClient

fn getIfOk(resp: HttpResponse) -> Maybe String =
  if resp.status == 200 then
    Something resp.body
  else
    Nothing

handler maybeGet(url: String) -> Maybe String
  requires [myHttp] =
  let resp = HttpClient.get url []
  getIfOk resp
|} in
  check_contains "response_used_in_maybe" src "maybeGet"

(* ── 6. Additional edge case tests ───────────────────────────────────────── *)

let test_httpresponse_type_annotation () =
  (* HttpResponse can be used as a type annotation *)
  let src = module_ ~exports:"wrapResp" {|
fn wrapResp(r: HttpResponse) -> Maybe HttpResponse =
  if r.status == 200 then
    Something r
  else
    Nothing
|} in
  check_contains "httpresponse_type_annotation" src "wrapResp"

let test_list_of_httpresponse () =
  (* Can have List HttpResponse as a type *)
  let src = module_ ~exports:"pickSuccess"
    ~extra:"import Tesl.List exposing [List.filter]\n" {|
fn pickSuccess(resps: List HttpResponse) -> List HttpResponse =
  List.filter (fn(r: HttpResponse) -> r.status == 200) resps
|} in
  check_contains "list_of_httpresponse" src "pickSuccess"

let test_get_emits_require_capabilities () =
  let src = module_ ~exports:"checkCaps" {|
capability myHttp implies httpClient

handler checkCaps(url: String) -> HttpResponse
  requires [myHttp] =
  HttpClient.get url []
|} in
  let racket = compile_ok "get_emits_require_capabilities" src in
  check_contains "get_emits_require_capabilities_body" src "myHttp";
  if not (contains "capabilities" racket || contains "httpClient" racket) then
    Alcotest.failf "get_emits_require_capabilities: expected capability in output:\n%s" racket

let test_post_with_content_type_header () =
  let src = module_ ~exports:"jsonPost" {|
capability myHttp implies httpClient

handler jsonPost(url: String, body: String) -> HttpResponse
  requires [myHttp] =
  let ct = Tuple2 "Content-Type" "application/json"
  HttpClient.post url [ct] body
|} in
  check_contains "post_with_content_type" src "application/json"

let test_headers_field_returns_list () =
  let src = module_ ~exports:"countHeaders"
    ~extra:"import Tesl.List exposing [List.length]\n" {|
capability myHttp implies httpClient

handler countHeaders(url: String) -> Int
  requires [myHttp] =
  let resp = HttpClient.get url []
  List.length resp.headers
|} in
  check_contains "headers_field_returns_list" src "countHeaders"

let test_httpresponse_not_constructible_from_literal () =
  (* HttpResponse cannot be created as a bare record literal
     (it's an opaque stdlib type) *)
  let src = module_ ~exports:"dummy" {|
fn dummy(n: Int) -> HttpResponse =
  { status: 200, body: "ok", headers: [] }
|} in
  let err = compile_err "httpresponse_not_constructible" src in
  if String.length err = 0 then
    Alcotest.failf "httpresponse_not_constructible: expected an error for bare record literal"

let test_status_arithmetic () =
  let src = module_ ~exports:"statusSum" {|
capability myHttp implies httpClient

handler statusSum(url1: String, url2: String) -> Int
  requires [myHttp] =
  let r1 = HttpClient.get url1 []
  let r2 = HttpClient.get url2 []
  r1.status + r2.status
|} in
  check_contains "status_arithmetic" src "statusSum"

let test_capability_check_on_delete_in_fn () =
  (* delete inside a fn (not handler) also requires capability *)
  let src = module_ ~exports:"deleteFn" {|
fn deleteFn(url: String) -> HttpResponse =
  HttpClient.delete url []
|} in
  let err = compile_err "delete_in_fn_without_cap" src in
  if not (contains "httpClient" err || contains "capabilities" (String.lowercase_ascii err)) then
    Alcotest.failf "delete_in_fn_without_cap: expected capability error, got: %s" err

(* ── Main ────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "HttpClient" [
    "parser", [
      Alcotest.test_case "import accepted" `Quick test_import_accepted;
      Alcotest.test_case "get parses" `Quick test_httpclient_get_parses;
      Alcotest.test_case "post parses" `Quick test_httpclient_post_parses;
      Alcotest.test_case "put parses" `Quick test_httpclient_put_parses;
      Alcotest.test_case "delete parses" `Quick test_httpclient_delete_parses;
      Alcotest.test_case "HttpResponse type parses" `Quick test_httpresponse_type_parses;
      Alcotest.test_case "headers list parses" `Quick test_headers_list_parses;
      Alcotest.test_case "capability declaration parses" `Quick test_capability_declaration_parses;
      Alcotest.test_case "module path in output" `Quick test_module_path_in_output;
      Alcotest.test_case "HttpResponse in output" `Quick test_httpresponse_in_output;
    ];
    "type-inference", [
      Alcotest.test_case "get returns HttpResponse" `Quick test_get_returns_httpresponse;
      Alcotest.test_case "post returns HttpResponse" `Quick test_post_returns_httpresponse;
      Alcotest.test_case "status field is Int" `Quick test_status_field_is_int;
      Alcotest.test_case "body field is String" `Quick test_body_field_is_string;
      Alcotest.test_case "headers field accessible" `Quick test_headers_field_accessible;
      Alcotest.test_case "delete returns HttpResponse" `Quick test_delete_returns_httpresponse;
      Alcotest.test_case "put returns HttpResponse" `Quick test_put_returns_httpresponse;
      Alcotest.test_case "response passed to function" `Quick test_response_passed_to_function;
      Alcotest.test_case "status used in if" `Quick test_httpresponse_status_used_in_case;
      Alcotest.test_case "custom headers typed" `Quick test_custom_headers_typed;
    ];
    "type-mismatch-errors", [
      Alcotest.test_case "get wrong first arg type" `Quick test_get_wrong_first_arg_type;
      Alcotest.test_case "post body must be string" `Quick test_post_body_must_be_string;
      Alcotest.test_case "wrong header element type" `Quick test_wrong_header_element_type;
    ];
    "capability", [
      Alcotest.test_case "handler without cap fails" `Quick test_handler_without_capability_fails;
      Alcotest.test_case "fn without cap fails" `Quick test_fn_without_capability_fails;
      Alcotest.test_case "handler with cap succeeds" `Quick test_handler_with_capability_succeeds;
      Alcotest.test_case "fn with httpClient cap succeeds" `Quick test_fn_with_http_client_capability_succeeds;
      Alcotest.test_case "post without cap fails" `Quick test_post_without_cap_fails;
      Alcotest.test_case "delete without cap fails" `Quick test_delete_without_cap_fails;
      Alcotest.test_case "put without cap fails" `Quick test_put_without_cap_fails;
      Alcotest.test_case "cap error names httpClient" `Quick test_capability_error_names_http_client;
      Alcotest.test_case "implied capability works" `Quick test_implied_capability_works;
      Alcotest.test_case "transitive capability works" `Quick test_transitive_capability_works;
      Alcotest.test_case "worker without cap fails" `Quick test_worker_without_cap_fails;
    ];
    "integration", [
      Alcotest.test_case "multiple requests in function" `Quick test_multiple_requests_in_function;
      Alcotest.test_case "response body string ops" `Quick test_response_body_string_ops;
      Alcotest.test_case "response used in maybe" `Quick test_response_used_in_maybe;
    ];
    "edge-cases", [
      Alcotest.test_case "HttpResponse type annotation" `Quick test_httpresponse_type_annotation;
      Alcotest.test_case "List of HttpResponse" `Quick test_list_of_httpresponse;
      Alcotest.test_case "get emits require-capabilities" `Quick test_get_emits_require_capabilities;
      Alcotest.test_case "post with content-type header" `Quick test_post_with_content_type_header;
      Alcotest.test_case "headers field returns list" `Quick test_headers_field_returns_list;
      Alcotest.test_case "HttpResponse not constructible from literal" `Quick test_httpresponse_not_constructible_from_literal;
      Alcotest.test_case "status arithmetic on multiple responses" `Quick test_status_arithmetic;
      Alcotest.test_case "capability check on delete in fn" `Quick test_capability_check_on_delete_in_fn;
    ];
  ]
