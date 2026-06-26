# ─────────────────────────────────────────────────────────────────────────────
# Shared Tesl CLI body — the helper functions and `case "$CMD"` dispatch.
#
# This file is the SINGLE SOURCE OF TRUTH for the `tesl` command-line verbs.
# Both flake.nix and shell.nix splice it in verbatim via `builtins.readFile`,
# each prepending its own preamble that establishes the runtime env contract.
# Because it is read as a literal bash file (not a Nix `''` string), there is
# NO Nix interpolation here — `${...}` and `''` are ordinary bash.
#
# ENV CONTRACT (the preamble MUST set these before this body runs):
#   TESL_OCAML_COMPILER   path to the OCaml compiler binary (main.exe)
#   PLTCOLLECTS           racket collects + the tesl runtime collections
#   PATH                  must contain `racket`
# OPTIONAL (set by the installed preamble so assets resolve without a repo):
#   TESL_TEMPLATES_DIR    store path holding templates/{minimal,api,docker}
#   TESL_COLLECTIONS_DIR  store path holding the tesl/{dsl,tesl,lang} tree
#                         (the tesl-racket derivation's …/share/tesl-collections/tesl)
# DEV fallback:
#   TESL_REPO_ROOT        repo checkout; templates + collections come from here.
# ─────────────────────────────────────────────────────────────────────────────

_tesl_require_compiler() {
  if [ ! -x "$TESL_OCAML_COMPILER" ]; then
    echo "error: Tesl compiler not found at $TESL_OCAML_COMPILER" >&2
    exit 1
  fi
}

_tesl_compile_to_stdout() {
  local FILE="$1"
  _tesl_require_compiler
  "$TESL_OCAML_COMPILER" "$FILE"
}

_tesl_compile_deps() {
  local FILE="$1"
  _tesl_require_compiler
  "$TESL_OCAML_COMPILER" --deps "$FILE"
}

_tesl_check() {
  [ $# -gt 0 ] || { echo "Usage: tesl check <file.tesl> [more.tesl ...]" >&2; exit 1; }
  _tesl_require_compiler
  "$TESL_OCAML_COMPILER" --check "$@"
}

# Locate the templates dir (holds minimal/ api/ docker/).
# Prefer a live repo checkout (dev), else the store path baked by the preamble.
_tesl_templates_dir() {
  if [ -n "${TESL_REPO_ROOT:-}" ] && [ -d "$TESL_REPO_ROOT/templates" ]; then
    echo "$TESL_REPO_ROOT/templates"; return 0
  fi
  if [ -n "${TESL_TEMPLATES_DIR:-}" ] && [ -d "$TESL_TEMPLATES_DIR" ]; then
    echo "$TESL_TEMPLATES_DIR"; return 0
  fi
  return 1
}

# ── tesl.toml manifest reader (mirrors scripts/tesl-manifest.sh) ───────────
# tesl_manifest_get <file> <section> <key> -> prints value, rc 0 if found.
tesl_manifest_get() {
  local file="$1" section="$2" key="$3"
  [ -n "$file" ] && [ -n "$section" ] && [ -n "$key" ] || { echo "tesl_manifest_get: usage: <file> <section> <key>" >&2; return 2; }
  [ -f "$file" ] || { return 2; }
  awk -v want_section="$section" -v want_key="$key" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      t = trim($0)
      if (t == "" || substr(t, 1, 1) == "#") next
      if (t ~ /^\[[^]]*\]$/) { cur = trim(substr(t, 2, length(t) - 2)); next }
      eq = index(t, "="); if (eq == 0) next
      k = trim(substr(t, 1, eq - 1)); v = trim(substr(t, eq + 1))
      if (cur != want_section || k != want_key) next
      if (substr(v, 1, 1) == "\"") {
        rest = substr(v, 2); endq = index(rest, "\"")
        if (endq > 0) print substr(rest, 1, endq - 1); else print rest
        found = 1; exit
      }
      hash = index(v, "#"); if (hash > 0) v = trim(substr(v, 1, hash - 1))
      print v; found = 1; exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Locate the Tesl runtime collections source dir (contains dsl/ tesl/ lang/).
# Order: live repo (dev) -> baked store path -> any PLTCOLLECTS entry.
_tesl_collections_root() {
  if [ -n "${TESL_REPO_ROOT:-}" ] && [ -d "$TESL_REPO_ROOT/dsl" ] && [ -d "$TESL_REPO_ROOT/tesl" ] && [ -d "$TESL_REPO_ROOT/lang" ]; then
    echo "$TESL_REPO_ROOT"; return 0
  fi
  if [ -n "${TESL_COLLECTIONS_DIR:-}" ] && [ -d "$TESL_COLLECTIONS_DIR/dsl" ] && [ -d "$TESL_COLLECTIONS_DIR/tesl" ] && [ -d "$TESL_COLLECTIONS_DIR/lang" ]; then
    echo "$TESL_COLLECTIONS_DIR"; return 0
  fi
  if [ -n "${PLTCOLLECTS:-}" ]; then
    local IFS=':' entry
    for entry in $PLTCOLLECTS; do
      [ -n "$entry" ] || continue
      if [ -d "$entry/tesl/dsl" ] && [ -d "$entry/tesl/tesl" ] && [ -d "$entry/tesl/lang" ]; then
        echo "$entry/tesl"; return 0
      fi
    done
  fi
  return 1
}

# Resolve postgres binaries: prefer PATH, else the flake's .#postgresql output.
_tesl_pg_resolve() {
  if command -v initdb >/dev/null 2>&1 && command -v pg_ctl >/dev/null 2>&1; then
    _TESL_PG_BIN=""; return 0
  fi
  local flake="${TESL_REPO_ROOT:-github:mtonnberg/tesl}"
  echo "tesl db: postgres not on PATH; resolving via 'nix build $flake#postgresql' ..." >&2
  if command -v nix >/dev/null 2>&1; then
    local out
    out="$(nix build "$flake#postgresql" --no-link --print-out-paths 2>/dev/null | head -n1)"
    if [ -n "$out" ] && [ -x "$out/bin/initdb" ]; then _TESL_PG_BIN="$out/bin"; return 0; fi
  fi
  echo "error: could not find PostgreSQL binaries (initdb/pg_ctl). Enter 'nix develop' or install postgresql." >&2
  return 1
}
_pg() { local tool="$1"; shift; if [ -n "${_TESL_PG_BIN:-}" ]; then "$_TESL_PG_BIN/$tool" "$@"; else "$tool" "$@"; fi; }

# ── tesl db start|stop|status ──────────────────────────────────────────────
_tesl_db() {
  local SUB="${1:-status}"; shift || true
  local MANIFEST="./tesl.toml"
  local PGPORT PGUSER PGDB
  PGPORT="$(tesl_manifest_get "$MANIFEST" env TESL_POSTGRES_PORT 2>/dev/null || true)"; PGPORT="${PGPORT:-5432}"
  PGUSER="$(tesl_manifest_get "$MANIFEST" env TESL_POSTGRES_USER 2>/dev/null || true)"; PGUSER="${PGUSER:-app}"
  PGDB="$(tesl_manifest_get "$MANIFEST" env TESL_POSTGRES_DATABASE 2>/dev/null || true)"; PGDB="${PGDB:-app}"

  local PGDIR="${PWD}/.tesl-postgres"
  local PGDATA="$PGDIR/data"
  local PGLOG="$PGDIR/postgres.log"
  # Unix-socket paths are capped at ~107 bytes, so keep the socket in a short
  # stable tmp dir; the app connects over TCP (127.0.0.1) regardless.
  local PGSOCK="${TMPDIR:-/tmp}/tesl-pg-$(echo "$PGDATA" | cksum | cut -d' ' -f1)"
  mkdir -p "$PGSOCK" 2>/dev/null || true

  case "$SUB" in
    start)
      _tesl_pg_resolve || return 1
      if [ ! -f "$PGDATA/PG_VERSION" ]; then
        echo "tesl db: initializing managed Postgres cluster at $PGDATA"
        mkdir -p "$PGDIR"
        _pg initdb -D "$PGDATA" -A trust -U "$PGUSER" --locale=C >/dev/null
      fi
      if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        echo "tesl db: Postgres already running ($PGDATA, port $PGPORT)"
      else
        echo "tesl db: starting Postgres on port $PGPORT (data: $PGDATA)"
        _pg pg_ctl -D "$PGDATA" -l "$PGLOG" \
          -o "-F -k '$PGSOCK' -p $PGPORT -c listen_addresses='127.0.0.1'" \
          -w start >/dev/null
      fi
      _pg createdb -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER" "$PGDB" >/dev/null 2>&1 || true
      echo "tesl db: ready — database '$PGDB' as user '$PGUSER' at 127.0.0.1:$PGPORT"
      ;;
    stop)
      _tesl_pg_resolve || return 1
      if [ ! -f "$PGDATA/PG_VERSION" ]; then echo "tesl db: no managed cluster at $PGDATA"; return 0; fi
      if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        _pg pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
        echo "tesl db: stopped Postgres at $PGDATA"
      else
        echo "tesl db: Postgres not running for $PGDATA"
      fi
      ;;
    status)
      _tesl_pg_resolve || return 1
      if [ ! -f "$PGDATA/PG_VERSION" ]; then echo "tesl db: no managed cluster (run 'tesl db start')"; return 0; fi
      if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        echo "tesl db: running ($PGDATA, port $PGPORT)"
        _pg pg_isready -h 127.0.0.1 -p "$PGPORT" || true
      else
        echo "tesl db: stopped ($PGDATA)"
      fi
      ;;
    *) echo "Usage: tesl db <start|stop|status>" >&2; return 1 ;;
  esac
}

# If the current project is managed-mode and Postgres isn't up, auto-start it.
# Opt out with TESL_NO_DB_AUTOSTART=1. (Called by the `run` verb.)
_tesl_db_autostart_if_managed() {
  [ "${TESL_NO_DB_AUTOSTART:-0}" = "1" ] && return 0
  [ -f "./tesl.toml" ] || return 0
  local mode; mode="$(tesl_manifest_get ./tesl.toml database mode 2>/dev/null || true)"
  [ "$mode" = "managed" ] || return 0
  local PGDATA="${PWD}/.tesl-postgres/data"
  _tesl_pg_resolve >/dev/null 2>&1 || return 0
  if _pg pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then return 0; fi
  echo "tesl run: managed database not running — starting it (TESL_NO_DB_AUTOSTART=1 to skip)" >&2
  _tesl_db start >&2 || true
}

# Generate AGENTS.md (and a CLAUDE.md copy) for a scaffolded project.
_tesl_init_agents_md() {
  local out="$1" name="$2" template="$3" pgmode="$4"
  {
    echo "# Working on $name with an AI coding agent"
    echo ""
    echo "This project was scaffolded by \`tesl init\` (template: **$template**, database: **$pgmode**)."
    echo "This file (and its twin \`CLAUDE.md\`) tells a coding agent how to be productive here."
    echo ""
    echo "## What this project is"
    echo ""
    echo "A Tesl web service. The application lives in \`app.tesl\`; the project manifest is"
    echo "\`tesl.toml\`. Tesl's signature feature is **compile-time proofs**: values carry"
    echo "facts (e.g. \`::: TitleSafe title\`) that only a \`check\`/\`auth\`/\`codec\` boundary can"
    echo "mint, so a handler can trust its inputs without re-validating, and the type checker"
    echo "rejects code that drops a required proof."
    echo ""
    echo "## Commands (run from the project root)"
    echo ""
    echo '```sh'
    echo "tesl check app.tesl     # type-check + enforce proofs (do this after every edit)"
    echo "tesl run app.tesl       # compile and serve on \$PORT"
    echo "tesl test app.tesl      # run the test \"...\" blocks"
    echo "tesl build              # build a runnable Docker image"
    [ "$pgmode" = "managed" ] && echo "tesl db start|stop|status   # manage the project-local PostgreSQL"
    echo '```'
    echo ""
    echo "After ANY change to \`app.tesl\`, run \`tesl check app.tesl\` — proofs and the"
    echo "capability system are enforced there, and the error messages tell you exactly"
    echo "what is missing."
    echo ""
    echo "## Gotchas to watch for"
    echo ""
    echo "- **Capabilities are explicit.** A \`fn\`/\`handler\` can only do what its"
    echo "  \`requires [...]\` clause allows; \`main\`/\`serve\` decides which capabilities to grant."
    echo "- **Proofs cannot be fabricated.** Only a \`check\`, \`auth\`, or \`codec ... via\` can"
    echo "  produce a \`:::\` fact. Returning a value that carries a proof satisfies a \`?\`"
    echo "  return spec; minting one by hand will not type-check."
    if [ "$pgmode" != "none" ]; then
      echo "- **Database connection** comes from \`TESL_POSTGRES_*\` env (see \`.env\` / \`tesl.toml\`"
      echo "  \`[env]\`). Tables are auto-created on first boot — no migration step."
    fi
    echo ""
    echo "## Editor + MCP server + agent skills"
    echo ""
    echo "Tesl ships an MCP server and editor integration that give an agent live"
    echo "type-checking, jump-to-definition, and documentation search:"
    echo ""
    echo "- **MCP server** (\`editor/tesl-mcp\`): install it so your agent can call"
    echo "  \`tesl check\`/\`semantic-json\` and search the manual programmatically. See the"
    echo "  Tesl repo's \`editor/tesl-mcp/README.md\` for the install + client-config steps,"
    echo "  then point your agent client (Claude Code, etc.) at the server."
    echo "- **Agent skills**: the Tesl repo provides debugging/dev skills under its"
    echo "  \`.claude/\` directory; install or reference them so the agent knows the Tesl"
    echo "  workflow (check -> run -> test -> build) and the proof/capability idioms."
    echo "- **Docs for agents**: \`tesl help manual full\` prints the entire manual in one"
    echo "  shot — feed it to the model when it needs language reference."
    echo ""
    echo "## A good \"next change\""
    echo ""
    echo "Open \`app.tesl\`, add a new route to the \`api\` block plus a \`handler\` for it,"
    echo "wire it into the \`server\` block, then \`tesl check app.tesl\`. Add a \`test \"...\"\`"
    echo "block to cover it and run \`tesl test app.tesl\`."
  } > "$out"
}

# ── tesl init ──────────────────────────────────────────────────────────────
_tesl_init() {
  local NAME="" TEMPLATE="" PGMODE="" YES=0 NOGIT=0 ans
  while [ $# -gt 0 ]; do
    case "$1" in
      --template) TEMPLATE="${2:?--template needs a value}"; shift 2 ;;
      --postgres) PGMODE="${2:?--postgres needs a value}"; shift 2 ;;
      --yes|-y)   YES=1; shift ;;
      --no-git)   NOGIT=1; shift ;;
      -*)         echo "tesl init: unknown flag $1" >&2; return 1 ;;
      *)          if [ -z "$NAME" ]; then NAME="$1"; else echo "tesl init: unexpected arg $1" >&2; return 1; fi; shift ;;
    esac
  done

  if [ -z "$NAME" ]; then
    if [ "$YES" = "1" ]; then NAME="demoapp"; else
      printf 'Project name [demoapp]: '; read -r NAME || true; NAME="${NAME:-demoapp}"
    fi
  fi
  if [ -z "$TEMPLATE" ]; then
    if [ "$YES" = "1" ]; then TEMPLATE="api"; else
      echo "Question 1 of 3  [#--]"
      echo "Template — what kind of app?"
      echo "  1) api      a PostgreSQL-backed CRUD service with proofs (recommended)"
      echo "  2) minimal  a tiny no-database service with proofs"
      printf 'Choose [1]: '; read -r ans || true
      case "${ans:-1}" in 2|minimal) TEMPLATE="minimal" ;; *) TEMPLATE="api" ;; esac
    fi
  fi
  case "$TEMPLATE" in api|minimal) ;; *) echo "tesl init: unknown template '$TEMPLATE' (api|minimal)" >&2; return 1 ;; esac

  local DEFAULT_PG; if [ "$TEMPLATE" = "api" ]; then DEFAULT_PG="managed"; else DEFAULT_PG="none"; fi
  if [ -z "$PGMODE" ]; then
    if [ "$YES" = "1" ] || [ "$TEMPLATE" = "minimal" ]; then PGMODE="$DEFAULT_PG"; else
      echo "Question 2 of 3  [##-]"
      echo "Database — where should your app store data?"
      echo "  1) managed   set one up for me (no install, lives in this project) (recommended)"
      echo "  2) existing  I'll connect my own Postgres"
      echo "  3) none      no database"
      printf 'Choose [1]: '; read -r ans || true
      case "${ans:-1}" in 2|existing) PGMODE="existing" ;; 3|none) PGMODE="none" ;; *) PGMODE="managed" ;; esac
    fi
  fi
  case "$PGMODE" in managed|existing|none) ;; *) echo "tesl init: unknown postgres mode '$PGMODE'" >&2; return 1 ;; esac

  local DEST="./$NAME"
  [ -e "$DEST" ] && { echo "tesl init: '$DEST' already exists" >&2; return 1; }

  if [ "$YES" != "1" ]; then
    echo "Question 3 of 3  [###]"
    echo "About to create: $DEST  (template=$TEMPLATE, postgres=$PGMODE, git=$([ "$NOGIT" = 1 ] && echo no || echo yes))"
    printf 'Proceed? [Y/n]: '; read -r ans || true
    case "${ans:-Y}" in n|N|no|NO) echo "Aborted."; return 1 ;; esac
  fi

  local TPL_ROOT; TPL_ROOT="$(_tesl_templates_dir)" || { echo "tesl init: cannot locate templates dir (set TESL_REPO_ROOT or reinstall)" >&2; return 1; }
  local TPL_DIR="$TPL_ROOT/$TEMPLATE"
  [ -d "$TPL_DIR" ] || { echo "tesl init: template dir missing: $TPL_DIR" >&2; return 1; }

  mkdir -p "$DEST"
  local f
  for f in app.tesl tesl.toml README.md; do
    sed "s/__APP_NAME__/$NAME/g" "$TPL_DIR/$f" > "$DEST/$f"
  done

  if [ "$PGMODE" != "$DEFAULT_PG" ]; then
    sed -i "s/^mode = \".*\"/mode = \"$PGMODE\"/" "$DEST/tesl.toml"
  fi

  {
    echo "# Generated by 'tesl init' from tesl.toml [env] defaults."
    echo "# In managed mode these point at the project-local Postgres ('tesl db start')."
    awk '
      /^\[/{ sec=$0 }
      sec=="[env]" && /=/ && $1 !~ /^#/ {
        line=$0; sub(/[ \t]*#.*$/,"",line)
        eq=index(line,"="); if(eq==0) next
        k=line; sub(/[ \t]*=.*/,"",k); gsub(/[ \t]/,"",k)
        v=substr(line,eq+1); sub(/^[ \t]*/,"",v); sub(/[ \t]*$/,"",v)
        gsub(/^"|"$/,"",v)
        if(k!="") print k"="v
      }
    ' "$DEST/tesl.toml"
  } > "$DEST/.env"

  {
    echo "# Managed Postgres data (recreate with \`tesl db start\`)"
    echo ".tesl-postgres/"
    echo "# Local environment overrides"
    echo ".env"
    echo "# Nix build symlink"
    echo "result"
    echo "# Racket compiled caches and generated output"
    echo "compiled/"
    echo "*.rkt"
  } > "$DEST/.gitignore"

  _tesl_init_agents_md "$DEST/AGENTS.md" "$NAME" "$TEMPLATE" "$PGMODE"
  cp "$DEST/AGENTS.md" "$DEST/CLAUDE.md"

  if [ "$NOGIT" != "1" ] && command -v git >/dev/null 2>&1; then
    ( cd "$DEST" && git init -q && git add -A && git commit -q -m "tesl init: scaffold $NAME ($TEMPLATE)" 2>/dev/null ) || true
  fi

  local PORT; PORT="$(tesl_manifest_get "$DEST/tesl.toml" env PORT 2>/dev/null || true)"; PORT="${PORT:-8086}"

  echo ""
  echo "Created '$NAME' with the '$TEMPLATE' template (postgres: $PGMODE)."
  echo ""
  echo "Next steps:"
  echo "  cd $NAME"
  [ "$PGMODE" = "managed" ] && echo "  tesl db start          # start the project-local Postgres"
  echo "  tesl run app.tesl      # serve on http://localhost:$PORT"
  echo "  tesl build             # produce a runnable Docker image"
  echo ""
  echo "Files: app.tesl, tesl.toml, .env, .gitignore, README.md, AGENTS.md, CLAUDE.md"
  echo "Learn more: tesl help manual   |   agent guide: AGENTS.md"
}

# ── tesl build ───────────────────────────────────────────────────────────
_tesl_build() {
  _tesl_require_compiler
  local VARIANT="" TAG="" NO_DOCKER=0 OUT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app-only)      VARIANT="app-only"; shift ;;
      --with-postgres) VARIANT="all-in-one"; shift ;;
      --tag)           TAG="${2:?--tag needs a value}"; shift 2 ;;
      --no-docker)     NO_DOCKER=1; shift ;;
      --out)           OUT="${2:?--out needs a value}"; shift 2 ;;
      -*)              echo "tesl build: unknown flag $1" >&2; return 1 ;;
      *)               echo "tesl build: unexpected arg $1" >&2; return 1 ;;
    esac
  done

  local MANIFEST="./tesl.toml"
  [ -f "$MANIFEST" ] || { echo "tesl build: no tesl.toml in $(pwd) (run 'tesl init' first)" >&2; return 1; }

  local NAME ENTRY PORT DBMODE
  NAME="$(tesl_manifest_get "$MANIFEST" project name 2>/dev/null || true)"; NAME="${NAME:-app}"
  ENTRY="$(tesl_manifest_get "$MANIFEST" project entrypoint 2>/dev/null || true)"; ENTRY="${ENTRY:-app.tesl}"
  PORT="$(tesl_manifest_get "$MANIFEST" env PORT 2>/dev/null || true)"; PORT="${PORT:-8086}"
  DBMODE="$(tesl_manifest_get "$MANIFEST" database mode 2>/dev/null || true)"; DBMODE="${DBMODE:-none}"

  [ -f "$ENTRY" ] || { echo "tesl build: entrypoint '$ENTRY' not found" >&2; return 1; }

  if [ -z "$VARIANT" ]; then
    if [ "$DBMODE" = "managed" ]; then VARIANT="all-in-one"; else VARIANT="app-only"; fi
  fi
  [ -z "$TAG" ] && TAG="$NAME"

  local RACKET_BASE="${TESL_RACKET_BASE:-racket/racket:8.18-full}"
  local APP_RKT="app.rkt"

  local CTX
  if [ -n "$OUT" ]; then CTX="$OUT"; mkdir -p "$CTX"; else CTX="$(mktemp -d)"; fi
  echo "tesl build: staging context at $CTX (variant=$VARIANT, port=$PORT)"

  if ! "$TESL_OCAML_COMPILER" "$ENTRY" > "$CTX/$APP_RKT"; then
    echo "tesl build: failed to compile $ENTRY" >&2; return 1
  fi
  local dep deps rel; deps="$("$TESL_OCAML_COMPILER" --deps "$ENTRY" 2>/dev/null || true)"
  if [ -n "$deps" ]; then
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      rel="${dep%.tesl}.rkt"
      mkdir -p "$CTX/$(dirname "$rel")"
      "$TESL_OCAML_COMPILER" "$dep" > "$CTX/$rel" || { echo "tesl build: failed to compile dep $dep" >&2; return 1; }
    done <<< "$deps"
  fi

  local COLL_ROOT; COLL_ROOT="$(_tesl_collections_root)" || { echo "tesl build: cannot locate Tesl runtime collections (dsl/tesl/lang)" >&2; return 1; }
  mkdir -p "$CTX/collections/tesl"
  local c
  for c in dsl tesl lang; do cp -R "$COLL_ROOT/$c" "$CTX/collections/tesl/$c"; done
  chmod -R u+w "$CTX/collections" 2>/dev/null || true
  find "$CTX/collections" -type d -name compiled -prune -exec rm -rf {} + 2>/dev/null || true

  local TPL_ROOT; TPL_ROOT="$(_tesl_templates_dir)" || { echo "tesl build: cannot locate templates dir (set TESL_REPO_ROOT or reinstall)" >&2; return 1; }
  local TPL_DIR="$TPL_ROOT/docker"
  local DF_SRC
  if [ "$VARIANT" = "all-in-one" ]; then DF_SRC="$TPL_DIR/Dockerfile.all-in-one.tmpl"; else DF_SRC="$TPL_DIR/Dockerfile.app-only.tmpl"; fi
  sed -e "s|__RACKET_BASE__|$RACKET_BASE|g" \
      -e "s|__APP_NAME__|$NAME|g" \
      -e "s|__APP_RKT__|$APP_RKT|g" \
      -e "s|__PORT__|$PORT|g" \
      "$DF_SRC" > "$CTX/Dockerfile"
  if [ "$VARIANT" = "all-in-one" ]; then
    sed -e "s|__RACKET_BASE__|$RACKET_BASE|g" \
        -e "s|__APP_NAME__|$NAME|g" \
        -e "s|__APP_RKT__|$APP_RKT|g" \
        -e "s|__PORT__|$PORT|g" \
        "$TPL_DIR/entrypoint.sh.tmpl" > "$CTX/entrypoint.sh"
    chmod +x "$CTX/entrypoint.sh"
  fi
  echo "tesl build: staged Dockerfile ($VARIANT) + app.rkt + collections"

  if [ "$NO_DOCKER" = "1" ]; then
    echo "tesl build: --no-docker set; build context ready at $CTX"
    echo "  docker build -t $TAG \"$CTX\""
    return 0
  fi
  command -v docker >/dev/null 2>&1 || { echo "tesl build: docker not found; context staged at $CTX" >&2; return 1; }
  echo "tesl build: building image '$TAG' ..."
  docker build -t "$TAG" "$CTX" || { echo "tesl build: docker build failed" >&2; return 1; }

  echo ""
  echo "Built image: $TAG ($VARIANT)"
  if [ "$VARIANT" = "all-in-one" ]; then
    echo "Run it (embedded Postgres, no external DB):"
    echo "  docker run -p $PORT:$PORT $TAG"
  else
    echo "Run it (app-only — supply an external Postgres if the app has a database):"
    if [ "$DBMODE" = "none" ]; then
      echo "  docker run -p $PORT:$PORT $TAG"
    else
      echo "  docker run -p $PORT:$PORT \\"
      echo "    -e TESL_POSTGRES_HOST=<host> -e TESL_POSTGRES_PORT=<port> \\"
      echo "    -e TESL_POSTGRES_DATABASE=<db> -e TESL_POSTGRES_USER=<user> -e TESL_POSTGRES_PASSWORD=<pw> \\"
      echo "    $TAG"
    fi
  fi
}

CMD="${1:-help}"
shift || true

case "$CMD" in
  compile)
    FILE="${1:?Usage: tesl compile <file.tesl>}"
    OUT="${FILE%.tesl}.rkt"
    OUT_TMP="$(mktemp --suffix=.rkt)"

    # Get all dependencies (transitive imports) of the file
    DEPS="$(_tesl_compile_deps "$FILE" 2>/dev/null)"

    # Compile all dependencies first to .rkt files in their directories
    RET=0
    for DEP in $DEPS; do
      if [ -n "$DEP" ] && [ "$DEP" != "$FILE" ]; then
        DEP_RKT="${DEP%.tesl}.rkt"
        if ! _tesl_compile_to_stdout "$DEP" > "$DEP_RKT" 2>&1; then
          echo "error: Failed to compile dependency: $DEP" >&2
          rm -f "$DEP_RKT"
          RET=1
        fi
      fi
    done
    if [ "$RET" -ne 0 ]; then
      rm -f "$OUT_TMP"; exit 1
    fi

    if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"; then
      mv "$OUT_TMP" "$OUT"
      echo "compiled $FILE → $OUT"
    else
      RET=$?; rm -f "$OUT_TMP"; exit "$RET"
    fi
    ;;
  check)
    _tesl_check "$@"
    ;;
  check-json)
    [ $# -gt 0 ] || { echo "Usage: tesl check-json <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --check-json "$@"
    ;;
  definition-json)
    [ $# -eq 3 ] || { echo "Usage: tesl definition-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --definition-json "$@"
    ;;
  occurrences-json)
    [ $# -eq 3 ] || { echo "Usage: tesl occurrences-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --occurrences-json "$@"
    ;;
  type-at-json)
    [ $# -eq 3 ] || { echo "Usage: tesl type-at-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --type-at-json "$@"
    ;;
  field-at-json)
    [ $# -eq 3 ] || { echo "Usage: tesl field-at-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --field-at-json "$@"
    ;;
  completions-json)
    [ $# -eq 3 ] || { echo "Usage: tesl completions-json <file.tesl> <line> <col>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --completions-json "$@"
    ;;
  local-bindings-json)
    [ $# -gt 0 ] || { echo "Usage: tesl local-bindings-json <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --local-bindings-json "$@"
    ;;
  semantic-json)
    [ $# -gt 0 ] || { echo "Usage: tesl semantic-json <file.tesl>" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --semantic-json "$@"
    ;;
  lint)
    [ $# -gt 0 ] || { echo "Usage: tesl lint <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --lint "$@"
    ;;
  fmt|format)
    [ $# -gt 0 ] || { echo "Usage: tesl fmt <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --fmt "$@"
    ;;
  fmt-check)
    [ $# -gt 0 ] || { echo "Usage: tesl fmt-check <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --fmt-check "$@"
    ;;
  run)
    FILE="${1:?Usage: tesl run <file.tesl> [args…]}"
    shift
    # Managed-mode projects: auto-start the project-local Postgres if needed.
    _tesl_db_autostart_if_managed
    OUT="${FILE%.tesl}.rkt"
    RET=0

    # Get all dependencies (transitive imports) of the file
    DEPS="$(_tesl_compile_deps "$FILE" 2>/dev/null)"

    # Compile all dependencies first to .rkt files in their directories
    for DEP in $DEPS; do
      if [ -n "$DEP" ] && [ "$DEP" != "$FILE" ]; then
        DEP_RKT="${DEP%.tesl}.rkt"
        if ! _tesl_compile_to_stdout "$DEP" > "$DEP_RKT" 2>&1; then
          echo "error: Failed to compile dependency: $DEP" >&2
          rm -f "$DEP_RKT"
          RET=1
        fi
      fi
    done

    if [ "$RET" -eq 0 ]; then
      OUT_TMP="$(mktemp --suffix=.rkt)"
      if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"; then
        # Only update $OUT if content changed — preserves mtime for Racket's .zo cache
        if ! cmp -s "$OUT_TMP" "$OUT"; then
          mv "$OUT_TMP" "$OUT"
        else
          rm -f "$OUT_TMP"
        fi
        echo "[tesl] Starting..." >&2
        if [ "${TESL_VERBOSE:-0}" = "1" ]; then
          racket "$OUT" "$@"; RET=$?
        else
          STDERR_TMP="$(mktemp)"
          racket "$OUT" "$@" 2>"$STDERR_TMP"; RET=$?
          grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
          rm -f "$STDERR_TMP"
        fi
      else
        RET=$?; rm -f "$OUT_TMP"
      fi
    fi
    exit "$RET"
    ;;
  test)
    # Optional: --test-name "name" runs only the named test case.
    TEST_NAME=""
    if [ "${1:-}" = "--test-name" ]; then
      TEST_NAME="${2:?--test-name requires a test name argument}"
      shift 2
    fi
    [ $# -gt 0 ] || { echo "Usage: tesl test [--test-name <name>] <file.tesl> [more.tesl ...]" >&2; exit 1; }
    RET=0
    for FILE in "$@"; do
      OUT="${FILE%.tesl}.rkt"
      OUT_TMP="$(mktemp --suffix=.rkt)"
      _tesl_require_compiler
      if [ -n "$TEST_NAME" ]; then
        "$TESL_OCAML_COMPILER" --test-name "$TEST_NAME" "$FILE" > "$OUT_TMP"
      else
        _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"
      fi
      if [ $? -eq 0 ]; then
        mv "$OUT_TMP" "$OUT"
        if [ "${TESL_VERBOSE:-0}" = "1" ]; then
          raco test "$OUT" || RET=$?
        else
          STDERR_TMP="$(mktemp)"
          raco test "$OUT" 2>"$STDERR_TMP"; STATUS=$?
          grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
          rm -f "$STDERR_TMP"
          [ "$STATUS" -ne 0 ] && RET="$STATUS"
        fi
      else
        rm -f "$OUT_TMP"; RET=1
      fi
    done
    exit "$RET"
    ;;
  watch)
    FILE="${1:?Usage: tesl watch <file.tesl>}"
    shift
    OUT="${FILE%.tesl}.rkt"
    RACKET_PID=""
    PREV_SNAP=""
    trap '[ -n "$RACKET_PID" ] && kill "$RACKET_PID" 2>/dev/null' EXIT

    _tesl_dep_snapshot() {
      local f="$1" deps
      if command -v "$TESL_OCAML_COMPILER" >/dev/null 2>&1; then
        deps="$("$TESL_OCAML_COMPILER" --deps "$f" 2>/dev/null)"
        deps="$f${deps:+$'\n'$deps}"
      else
        local dir; dir="$(dirname "$(realpath "$f")")"
        deps="$(find "$dir" -name "*.tesl" 2>/dev/null)"
      fi
      echo "$deps" | sort -u | xargs -d '\n' stat -c "%n %Y" 2>/dev/null | sort
    }

    echo "[tesl watch] Watching $(realpath "$FILE") and its imports (Ctrl+C to stop)"
    while true; do
      CURR_SNAP="$(_tesl_dep_snapshot "$FILE")"
      if [ "$CURR_SNAP" != "$PREV_SNAP" ]; then
        PREV_SNAP="$CURR_SNAP"
        echo "[tesl watch] Compiling..."
        STDERR_TMP="$(mktemp)"
        OUT_TMP="$(mktemp --suffix=.rkt)"
        if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP" 2>"$STDERR_TMP"; then
          grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
          rm -f "$STDERR_TMP"
          if ! cmp -s "$OUT_TMP" "$OUT"; then
            mv "$OUT_TMP" "$OUT"
          else
            rm -f "$OUT_TMP"
          fi
          [ -n "$RACKET_PID" ] && { kill "$RACKET_PID" 2>/dev/null; wait "$RACKET_PID" 2>/dev/null; }
          echo "[tesl watch] Starting..." >&2
          racket "$OUT" "$@" &
          RACKET_PID=$!
          echo "[tesl watch] Server running (pid $RACKET_PID)"
        else
          grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
          rm -f "$STDERR_TMP"
          rm -f "$OUT_TMP"
          echo "[tesl watch] Compile error — previous server kept running" >&2
        fi
      fi
      sleep 0.3
    done
    ;;
  generate)
    SUBCMD="${1:-help}"
    shift || true
    case "$SUBCMD" in
      ir)
        FILE="${1:?Usage: tesl generate ir <file.tesl>}"
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --ir "$FILE"
        ;;
      ts)
        FILE="${1:?Usage: tesl generate ts <file.tesl>}"
        shift || true
        _tesl_require_compiler
        if [ "${1:-}" = "--out" ]; then
          "$TESL_OCAML_COMPILER" --generate-ts "$FILE" --out "${2:?--out requires a filename}"
        else
          "$TESL_OCAML_COMPILER" --generate-ts "$FILE"
        fi
        ;;
      elm)
        FILE="${1:?Usage: tesl generate elm <file.tesl>}"
        shift || true
        _tesl_require_compiler
        if [ "${1:-}" = "--out" ]; then
          "$TESL_OCAML_COMPILER" --generate-elm "$FILE" --out "${2:?--out requires a filename}"
        else
          "$TESL_OCAML_COMPILER" --generate-elm "$FILE"
        fi
        ;;
      help|*)
        echo "Usage: tesl generate <ir|ts|elm> <file.tesl> [--out <file>]"
        ;;
    esac
    ;;
  validate)
    [ $# -gt 0 ] || { echo "Usage: tesl validate <file.tesl> [more.tesl ...]" >&2; exit 1; }
    _tesl_require_compiler
    "$TESL_OCAML_COMPILER" --check "$@" \
      && "$TESL_OCAML_COMPILER" --lint "$@" \
      && "$TESL_OCAML_COMPILER" --fmt-check "$@"
    ;;
  init)
    _tesl_init "$@"
    ;;
  db)
    _tesl_db "$@"
    ;;
  build)
    _tesl_build "$@"
    ;;
  help|--help|-h)
    if [ -n "$1" ]; then
      # Pass help subcommands to the compiler
      _tesl_require_compiler
      "$TESL_OCAML_COMPILER" --help "$@"
    else
      cat <<'EOF'
Tesl language CLI

Usage:
  tesl init                [name] [--template api|minimal]   Scaffold a new project
                           [--postgres managed|existing|none] [--yes] [--no-git]
  tesl db                  start|stop|status                 Manage the project-local Postgres
  tesl build               [--app-only|--with-postgres]      Build a runnable Docker image
                           [--tag NAME] [--no-docker] [--out DIR]
  tesl compile             <file.tesl>                    Compile .tesl → .rkt
  tesl check               <file.tesl> [more.tesl ...]   Type-check without output
  tesl lint                <file.tesl> [more.tesl ...]   Run the opinionated linter
  tesl fmt                 <file.tesl> [more.tesl ...]   Format in-place
  tesl fmt-check           <file.tesl> [more.tesl ...]   Check formatting without modifying
  tesl validate            <file.tesl> [more.tesl ...]   Run check + lint + fmt-check
  tesl run                 <file.tesl> [args…]           Compile then execute
  tesl test                <file.tesl> [more.tesl ...]   Compile and run tests
  tesl watch               <file.tesl> [args…]           Watch, recompile, and restart on changes
  tesl generate ir         <file.tesl>                   Emit API IR as JSON
  tesl generate ts         <file.tesl> [--out <file>]    Emit TypeScript + Zod client
  tesl generate elm        <file.tesl> [--out <file>]    Emit Elm HTTP client

Documentation:
  tesl help manual                                             Show full documentation index
  tesl help manual <section>                                   Show specific documentation section
  tesl help manual full                                        Show ALL documentation (for LLMs)
  tesl help examples                                           List all examples
  tesl help search <query>                                     Search documentation

Editor / Language Server (LSP) flags:
  tesl check-json          <file.tesl>                   Type-check, diagnostics as IR-2 JSON
  tesl local-bindings-json <file.tesl>                   Inferred local binding types as JSON
  tesl semantic-json       <file.tesl>                   Full module semantic snapshot as JSON
  tesl definition-json     <file.tesl> <line> <col>      Jump-to-definition location as JSON
  tesl occurrences-json    <file.tesl> <line> <col>      Same-file symbol occurrences as JSON
  tesl type-at-json        <file.tesl> <line> <col>      Inferred type at cursor as JSON
  tesl field-at-json       <file.tesl> <line> <col>      Record field info at cursor as JSON
  tesl completions-json    <file.tesl> <line> <col>      Context-aware completions as JSON

Verbose logging:
  TESL_VERBOSE=1 tesl run your-api.tesl

Logs HTTP requests/responses, SQL queries, queue operations, and
pub/sub events to stderr. Zero overhead when TESL_VERBOSE is unset.
EOF
    fi
    ;;
  *)
    echo "unknown command: $CMD  (try: tesl help)" >&2
    exit 1
    ;;
esac
