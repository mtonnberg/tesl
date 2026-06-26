#!/usr/bin/env bash
# tesl-manifest.sh — dependency-free reader for the tesl.toml manifest subset.
#
# Source this file, then call:
#
#     tesl_manifest_get <file> <section> <key>
#
# It prints the value (stdout) and returns 0 if found, or returns non-zero and
# prints nothing if the file, section, or key is absent.
#
# SUPPORTED TOML SUBSET (deliberately tiny — matches dev-docs/tesl-manifest.md):
#   * `[section]` headers (bare names, no dotted/nested tables, no `[[arrays]]`).
#   * `key = value` pairs, one per line.
#   * Double-quoted string values  ->  surrounding quotes are stripped.
#   * Bare values (numbers, bools)  ->  taken verbatim.
#   * `#` comments: a whole-line comment, or a trailing comment after an
#     UNQUOTED value. A `#` inside a double-quoted value is preserved.
#   * Leading/trailing whitespace around keys, values, and headers is trimmed.
#
# NOT supported (by design — the manifest never needs them): multi-line strings,
# single-quoted/literal strings, arrays, inline tables, dotted keys, escapes.
#
# Implementation: a single awk pass. No external deps beyond awk + the shell.

tesl_manifest_get() {
  local file="$1" section="$2" key="$3"
  if [ -z "$file" ] || [ -z "$section" ] || [ -z "$key" ]; then
    echo "tesl_manifest_get: usage: tesl_manifest_get <file> <section> <key>" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "tesl_manifest_get: no such file: $file" >&2
    return 2
  fi

  awk -v want_section="$section" -v want_key="$key" '
    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    {
      line = $0
      # Strip a full-line comment.
      t = trim(line)
      if (t == "" || substr(t, 1, 1) == "#") next

      # Section header: [name]
      if (t ~ /^\[[^]]*\]$/) {
        cur = substr(t, 2, length(t) - 2)
        cur = trim(cur)
        next
      }

      # key = value
      eq = index(t, "=")
      if (eq == 0) next
      k = trim(substr(t, 1, eq - 1))
      v = trim(substr(t, eq + 1))

      if (cur != want_section || k != want_key) next

      # Quoted string value: take inside the first pair of double quotes.
      if (substr(v, 1, 1) == "\"") {
        rest = substr(v, 2)
        endq = index(rest, "\"")
        if (endq > 0) {
          print substr(rest, 1, endq - 1)
        } else {
          print rest          # malformed (unterminated) — emit best effort
        }
        found = 1
        exit
      }

      # Bare value: drop a trailing comment, then trim.
      hash = index(v, "#")
      if (hash > 0) v = trim(substr(v, 1, hash - 1))
      print v
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Allow direct invocation for quick testing / use from non-bash callers:
#   tesl-manifest.sh <file> <section> <key>
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  tesl_manifest_get "$@"
fi
