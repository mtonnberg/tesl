(** The Go runtime (runtime/go/teslrt) the compiler copies into every emitted project,
    as (file name, contents) pairs — one per file, in gen_go_runtime.ml's order.
    Implemented by go_runtime/embedded (the generated snapshot, the default) and by
    go_runtime/none (empty; the browser playground). *)
val files : (string * string) list
