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

// The compiler pins literal-rule source bytes only for regular files. Supply
// stat/lstat on our mounted device, whose files cannot be symlinks. Do not
// replace the Unix primitives globally or describe arbitrary host paths.
//Provides: tesl_playground_vfs_metadata
//Requires: resolve_fs_device, MlFakeDevice, caml_string_of_jsbytes, caml_raise_sys_error, caml_raise_system_error, caml_int64_of_float
function tesl_playground_vfs_metadata() {
  var device = resolve_fs_device(caml_string_of_jsbytes("/tesl/")).device;
  if (!(device instanceof MlFakeDevice) || device.root !== "/tesl/") {
    caml_raise_sys_error(caml_string_of_jsbytes("playground virtual source device is unavailable"));
  }
  device.stat = device.lstat = function(name, large, raise_unix) {
    if ((name !== "" && !/^[A-Za-z0-9_]+\.tesl$/.test(name)) || !this.exists(name)) {
      caml_raise_system_error(raise_unix, "ENOENT", "stat", "no such virtual source", this.nm(name));
    }
    var directory = name === "";
    var size = directory ? 0 : this.content[name].length();
    // Unix.stats: dev, ino, kind, perm, nlink, uid, gid, rdev, size, a/m/ctime.
    // Timestamps are inert: source guards compare the actual immutable bytes.
    return [0, 0, 0, directory ? 1 : 0, directory ? 448 : 384, 1, 0, 0, 0,
            large ? caml_int64_of_float(size) : size, 0, 0, 0];
  };
  return 0;
}
