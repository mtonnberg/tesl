(** Bounded argv-based subprocesses for compiler build/mutation commands.
    The native CLI supplies itself as the Windows process-tree owner. Direct
    POSIX compiler invocations own a session/process group without a shell. *)
let max_output = 8 * 1024 * 1024
let status_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 1

let read_bounded_file path =
  In_channel.with_open_bin path (fun input ->
    let size = min max_output (In_channel.length input |> Int64.to_int) in
    really_input_string input size)

let via_owner owner ~timeout ~cwd program arguments =
  let output = Filename.temp_file "tesl-owned-process-" ".log" in
  Fun.protect ~finally:(fun () -> Sys.remove output) (fun () ->
    let descriptor = Unix.openfile output [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let pid = Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      let args = [owner; "--internal-run-process"; string_of_int timeout; cwd; program] @ arguments in
      Unix.create_process_env owner (Array.of_list args) (Unix.environment ()) Unix.stdin descriptor descriptor) in
    let _, status = Unix.waitpid [] pid in
    status_code status, read_bounded_file output)

let posix ~timeout ~cwd program arguments =
  let input, output = Unix.pipe ~cloexec:true () in
  let pid = try Unix.fork () with exn -> Unix.close input; Unix.close output; raise exn in
  if pid = 0 then begin
    (try
      Unix.close input;
      ignore (Unix.setsid ());
      Unix.chdir cwd;
      Unix.dup2 output Unix.stdout;
      Unix.dup2 output Unix.stderr;
      Unix.close output;
      Unix.execvp program (Array.of_list (program :: arguments))
     with exn ->
       (try output_string stderr (Printexc.to_string exn ^ "\n"); flush stderr with _ -> ());
       Unix._exit 127)
  end;
  Unix.close output;
  let kill () =
    (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ());
    (* Before setsid, the root has not acquired its group yet. *)
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()) in
  let reaped = ref false in
  Fun.protect ~finally:(fun () ->
    Unix.close input;
    if not !reaped then (kill (); ignore (Unix.waitpid [] pid))) (fun () ->
    Unix.set_nonblock input;
    let deadline = Unix.gettimeofday () +. float_of_int timeout in
    let buffer = Buffer.create 4096 and chunk = Bytes.create 65536 in
    let ended = ref None and timed_out = ref false and overflow = ref false and eof = ref false in
    while not !eof || !ended = None do
      if !ended = None then begin
        let child, status = Unix.waitpid [Unix.WNOHANG] pid in
        if child <> 0 then begin
          ended := Some status; reaped := true;
          (* Descendants holding stdout cannot delay parent completion. *)
          (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ())
        end else if Unix.gettimeofday () >= deadline then begin
          timed_out := true; kill ()
        end
      end;
      if not !eof then begin
        let ready, _, _ = Unix.select [input] [] [] 0.02 in
        if ready <> [] then
          (try
            let count = Unix.read input chunk 0 (Bytes.length chunk) in
            if count = 0 then eof := true
            else if Buffer.length buffer + count > max_output then (overflow := true; if !ended = None then kill ())
            else Buffer.add_subbytes buffer chunk 0 count
           with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ())
      end else if !ended = None then Unix.sleepf 0.01
    done;
    let code = if !timed_out then 124 else if !overflow then 125 else status_code (Option.get !ended) in
    code, Buffer.contents buffer)

let run ~timeout ~cwd program arguments =
  if timeout < 1 then invalid_arg "process timeout must be positive";
  try match Sys.getenv_opt "TESL_PROCESS_RUNNER" with
  | Some owner when owner <> "" -> via_owner owner ~timeout ~cwd program arguments
  | _ when Sys.win32 -> 125, "native Windows compiler subprocesses require the Tesl CLI process owner; invoke `tesl`\n"
  | _ -> posix ~timeout ~cwd program arguments
  with Unix.Unix_error (error, fn, arg) ->
    127, Printf.sprintf "%s %s: %s\n" fn arg (Unix.error_message error)
