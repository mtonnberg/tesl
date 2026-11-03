// The playground mounts an in-memory /tesl/ device under both browsers and Node.
// It contains only files named by vfile_of_source; it has no symlinks. Keep this
// primitive limited to those canonical names, rather than pretending to resolve
// arbitrary host paths or relaxing the native compiler's filesystem checks.
//Provides: caml_unix_realpath
//Requires: caml_jsbytes_of_string, caml_sys_file_exists, caml_raise_sys_error, caml_string_of_jsbytes
function caml_unix_realpath(path) {
  var name = caml_jsbytes_of_string(path);
  if ((name === "/tesl" || /^\/tesl\/[A-Za-z0-9_]+\.tesl$/.test(name)) &&
      caml_sys_file_exists(path)) {
    return path;
  }
  caml_raise_sys_error(caml_string_of_jsbytes(
    "playground realpath requires an existing canonical virtual source: " + name));
}
