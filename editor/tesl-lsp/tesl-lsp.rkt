#lang racket
;;; Tesl Language Server — diagnostics + hover + goto definition

(require json
         racket/port
         racket/path
         racket/string
         racket/runtime-path
         racket/list
         file/sha1)

;; ── Logging ──────────────────────────────────────────────────────────────────

(define (log msg)
  (fprintf (current-error-port) "[tesl-lsp] ~a\n" msg)
  (flush-output (current-error-port)))

;; ── Compiler discovery ───────────────────────────────────────────────────────

(define-runtime-path script-dir ".")

(define (find-compiler)
  (define (ocaml-at root)
    (let ([p (build-path root "compiler" "_build" "default" "bin" "main.exe")])
      (and (file-exists? p) p)))
  (or (let ([e (getenv "TESL_COMPILER")])  (and e (file-exists? e) (string->path e)))
      (let ([r (getenv "TESL_REPO_ROOT")]) (and r (ocaml-at r)))
      (ocaml-at (simplify-path (build-path script-dir ".." "..")))
      #f))

;; ── LSP framing ──────────────────────────────────────────────────────────────

(define (read-message in)
  (let ([headers (make-hash)])
    (let loop ()
      (let ([line (read-line in 'any)])
        (cond
          [(eof-object? line)               (error 'lsp "stdin EOF")]
          [(string=? (string-trim line) "") (void)]
          [else
           (let ([m (regexp-match #rx"^([^:]+):(.*)" line)])
             (when m
               (hash-set! headers
                          (string-downcase (string-trim (cadr m)))
                          (string-trim (caddr m)))))
           (loop)])))
    (let* ([n   (string->number (hash-ref headers "content-length" "0"))]
           [buf (make-bytes n)])
      (read-bytes! buf in)
      (with-handlers ([exn? (lambda (e) (log (format "json-parse: ~a" (exn-message e))) (hash))])
        (read-json (open-input-bytes buf))))))

(define (write-message out msg)
  (let ([body (jsexpr->bytes msg)])
    (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length body))
    (write-bytes body out)
    (flush-output out)))

;; ── Stdlib signatures ─────────────────────────────────────────────────────────
;; Hover docs for Tesl.* standard library functions and well-known builtins.
;; Entries with "\n\n" separate code signature from prose description.

(define stdlib-sigs
  (make-hash
   (list
    ;; Tesl.String
    (cons "String.length"       "fn String.length(s: String) -> Int")
    (cons "String.isEmpty"      "fn String.isEmpty(s: String) -> Bool")
    (cons "String.trim"         "fn String.trim(s: String) -> String ? IsTrimmed")
    (cons "String.trimLeft"     "fn String.trimLeft(s: String) -> String ? IsTrimmed")
    (cons "String.trimRight"    "fn String.trimRight(s: String) -> String ? IsTrimmed")
    (cons "String.toUpper"      "fn String.toUpper(s: String) -> String ? IsUpperCase")
    (cons "String.toLower"      "fn String.toLower(s: String) -> String ? IsLowerCase")
    (cons "String.startsWith"   "fn String.startsWith(s: String, prefix: String) -> Bool")
    (cons "String.endsWith"     "fn String.endsWith(s: String, suffix: String) -> Bool")
    (cons "String.contains"     "fn String.contains(s: String, sub: String) -> Bool")
    (cons "String.split"        "fn String.split(s: String, sep: String) -> List String")
    (cons "String.join"         "fn String.join(strs: List String, sep: String) -> String")
    (cons "String.replace"      "fn String.replace(s: String, from: String, to: String) -> String")
    (cons "String.slice"        "fn String.slice(s: String, start: Int, end: Int) -> String")
    (cons "String.concat"       "fn String.concat(a: String, b: String) -> String")
    (cons "String.repeat"       "fn String.repeat(s: String, n: Int) -> String")
    (cons "String.reverse"      "fn String.reverse(s: String) -> String")
    (cons "String.toInt"        "fn String.toInt(s: String) -> Maybe Int")
    (cons "String.toFloat"      "fn String.toFloat(s: String) -> Maybe Float")
    (cons "String.fromInt"      "fn String.fromInt(n: Int) -> String")
    (cons "String.fromFloat"    "fn String.fromFloat(f: Float) -> String")
    (cons "String.padLeft"      "fn String.padLeft(s: String, width: Int, char: String) -> String")
    (cons "String.padRight"     "fn String.padRight(s: String, width: Int, char: String) -> String")
    (cons "String.dropPrefix"   "fn String.dropPrefix(s: String, prefix: String) -> String")
    (cons "String.dropSuffix"   "fn String.dropSuffix(s: String, suffix: String) -> String")
    (cons "String.indexOf"      "fn String.indexOf(s: String, sub: String) -> Maybe Int")
    (cons "String.lines"        "fn String.lines(s: String) -> List String")
    (cons "String.words"        "fn String.words(s: String) -> List String")
    (cons "String.requireNonEmpty" "check String.requireNonEmpty(s: String) -> s: String ::: IsNonEmpty s")
    ;; Tesl.Int
    (cons "Int.parse"           "fn Int.parse(s: String) -> Maybe Int")
    (cons "Int.fromFloat"       "fn Int.fromFloat(f: Float) -> Int")
    (cons "Int.toString"        "fn Int.toString(n: Int) -> String")
    (cons "Int.abs"             "fn Int.abs(n: Int) -> Int")
    (cons "Int.min"             "fn Int.min(a: Int, b: Int) -> Int")
    (cons "Int.max"             "fn Int.max(a: Int, b: Int) -> Int")
    (cons "Int.clamp"           "fn Int.clamp(n: Int, lo: Int, hi: Int) -> Int")
    (cons "Int.isPositive"      "fn Int.isPositive(n: Int) -> Bool")
    (cons "Int.isNegative"      "fn Int.isNegative(n: Int) -> Bool")
    (cons "Int.isZero"          "fn Int.isZero(n: Int) -> Bool")
    (cons "Int.isEven"          "fn Int.isEven(n: Int) -> Bool")
    (cons "Int.isOdd"           "fn Int.isOdd(n: Int) -> Bool")
    (cons "Int.pow"             "fn Int.pow(base: Int, exp: Int) -> Int")
    (cons "Int.gcd"             "fn Int.gcd(a: Int, b: Int) -> Int")
    (cons "Int.toFloat"         "fn Int.toFloat(n: Int) -> Float")
    (cons "Int.sign"            "fn Int.sign(n: Int) -> Int")
    (cons "Int.nonZero"         "check Int.nonZero(n: Int) -> n: Int ::: IsNonZero n")
    (cons "Int.nonNegative"     "check Int.nonNegative(n: Int) -> n: Int ::: IsNonNegative n")
    (cons "Int.divide"          "fn Int.divide(a: Int, b: Int ::: IsNonZero b) -> Int")
    (cons "Int.lcm"             "fn Int.lcm(a: Int, b: Int) -> Int")
    (cons "Int.digits"          "fn Int.digits(n: Int) -> Int  — number of decimal digits in abs(n)")
    ;; Tesl.Telemetry
    (cons "telemetry"           "fn telemetry(name: String) -> Unit\n\nSpecial form: `telemetry \"span.name\" { key = value }`. The brace fields become span attributes.")
    (cons "initTelemetry"       "fn initTelemetry(service: String, endpoint: String, console: Bool) -> Unit\n\nCalled as `initTelemetry service \"my-service\" endpoint \"in-memory\" console True`. `service` and `endpoint` must be strings; `console` must be Bool.")
    ;; Tesl.Float
    (cons "Float.parse"         "fn Float.parse(s: String) -> Maybe Float")
    (cons "Float.toString"      "fn Float.toString(f: Float) -> String")
    (cons "Float.toInt"         "fn Float.toInt(f: Float) -> Int  — truncates toward zero")
    (cons "Float.abs"           "fn Float.abs(f: Float) -> Float")
    (cons "Float.min"           "fn Float.min(a: Float, b: Float) -> Float")
    (cons "Float.max"           "fn Float.max(a: Float, b: Float) -> Float")
    (cons "Float.clamp"         "fn Float.clamp(f: Float, lo: Float, hi: Float) -> Float")
    (cons "Float.ceil"          "fn Float.ceil(f: Float) -> Int")
    (cons "Float.floor"         "fn Float.floor(f: Float) -> Int")
    (cons "Float.round"         "fn Float.round(f: Float) -> Int")
    (cons "Float.sqrt"          "fn Float.sqrt(f: Float) -> Float")
    (cons "Float.pow"           "fn Float.pow(base: Float, exp: Float) -> Float")
    (cons "Float.log"           "fn Float.log(f: Float) -> Float")
    (cons "Float.exp"           "fn Float.exp(f: Float) -> Float")
    (cons "Float.sin"           "fn Float.sin(f: Float) -> Float")
    (cons "Float.cos"           "fn Float.cos(f: Float) -> Float")
    (cons "Float.tan"           "fn Float.tan(f: Float) -> Float")
    (cons "Float.isNaN"         "fn Float.isNaN(f: Float) -> Bool")
    (cons "Float.isInfinite"    "fn Float.isInfinite(f: Float) -> Bool")
    (cons "Float.isPositive"    "fn Float.isPositive(f: Float) -> Bool")
    (cons "Float.isNegative"    "fn Float.isNegative(f: Float) -> Bool")
    (cons "Float.isZero"        "fn Float.isZero(f: Float) -> Bool")
    (cons "Float.sign"          "fn Float.sign(f: Float) -> Float  — returns 1.0, -1.0, or 0.0")
    ;; Tesl.List
    (cons "List.isEmpty"        "fn List.isEmpty(xs: List a) -> Bool")
    (cons "List.length"         "fn List.length(xs: List a) -> Int")
    (cons "List.head"           "fn List.head(xs: List a) -> Maybe a")
    (cons "List.tail"           "fn List.tail(xs: List a) -> Maybe (List a)")
    (cons "List.last"           "fn List.last(xs: List a) -> Maybe a")
    (cons "List.nth"            "fn List.nth(xs: List a, i: Int) -> Maybe a")
    (cons "List.map"            "fn List.map(f: (a -> b requires c), xs: List a) -> List b requires c")
    (cons "List.filter"         "fn List.filter(pred: (a -> Bool requires c), xs: List a) -> List a requires c")
    (cons "List.filterMap"      "fn List.filterMap(f: (a -> Maybe b requires c), xs: List a) -> List b requires c")
    (cons "List.foldl"          "fn List.foldl(f: (b -> a -> b requires c), acc: b, xs: List a) -> b requires c")
    (cons "List.foldr"          "fn List.foldr(f: (a -> b -> b requires c), acc: b, xs: List a) -> b requires c")
    (cons "List.append"         "fn List.append(xs: List a, ys: List a) -> List a")
    (cons "List.reverse"        "fn List.reverse(xs: List a) -> List a")
    (cons "List.sort"           "fn List.sort(xs: List a) -> List a ? IsSorted")
    (cons "List.sortBy"         "fn List.sortBy(f: (a -> b requires c), xs: List a) -> List a ? IsSorted requires c")
    (cons "List.contains"       "fn List.contains(xs: List a, x: a) -> Bool")
    (cons "List.find"           "fn List.find(pred: (a -> Bool requires c), xs: List a) -> Maybe a requires c")
    (cons "List.take"           "fn List.take(n: Int ::: IsNonNegative n, xs: List a) -> List a")
    (cons "List.drop"           "fn List.drop(n: Int ::: IsNonNegative n, xs: List a) -> List a")
    (cons "List.zip"            "fn List.zip(xs: List a, ys: List b) -> List (Tuple2 a b)")
    (cons "List.sum"            "fn List.sum(xs: List Int) -> Int")
    (cons "List.product"        "fn List.product(xs: List Int) -> Int")
    (cons "List.maximum"        "fn List.maximum(xs: List Int) -> Maybe Int")
    (cons "List.minimum"        "fn List.minimum(xs: List Int) -> Maybe Int")
    (cons "List.any"            "fn List.any(pred: (a -> Bool requires c), xs: List a) -> Bool requires c")
    (cons "List.all"            "fn List.all(pred: (a -> Bool requires c), xs: List a) -> Bool requires c")
    (cons "List.count"          "fn List.count(pred: (a -> Bool requires c), xs: List a) -> Int requires c")
    (cons "List.range"          "fn List.range(start: Int, end: Int) -> List Int")
    (cons "List.repeat"         "fn List.repeat(x: a, n: Int ::: IsNonNegative n) -> List a")
    (cons "List.unique"         "fn List.unique(xs: List a) -> List a")
    (cons "List.partition"      "fn List.partition(pred: (a -> Bool requires c), xs: List a) -> List (List a) requires c")
    (cons "List.findIndex"      "fn List.findIndex(pred: (a -> Bool requires c), xs: List a) -> Maybe Int requires c")
    (cons "List.zipWith"        "fn List.zipWith(f: ((a, b) -> d requires c), xs: List a, ys: List b) -> List d requires c")
    (cons "List.unzip"          "fn List.unzip(pairs: List (List Any)) -> List (List Any)  — returns [firsts, seconds]")
    (cons "List.flatten"        "fn List.flatten(xss: List (List a)) -> List a")
    (cons "List.concat"         "fn List.concat(xss: List (List a)) -> List a  — flatten one level of nesting")
    (cons "List.dedupe"         "fn List.dedupe(xs: List a) -> List a  — removes consecutive duplicates")
    (cons "List.intersperse"    "fn List.intersperse(sep: a, xs: List a) -> List a")
    (cons "List.intercalate"    "fn List.intercalate(sep: List a, xss: List (List a)) -> List a")
    (cons "List.groupBy"        "fn List.groupBy(f: (a -> b requires c), xs: List a) -> List (List a) requires c  — groups consecutive equal-keyed elements")
    (cons "List.filterCheck"    "fn List.filterCheck(checkFn: check a, xs: List a) -> List a\n\nFilter using a check function. Elements that pass are kept with their proof attached.")
    (cons "List.allCheck"       "fn List.allCheck(checkFn: check a, xs: List a) -> List a\n\nApply a check to every element. Fails if any element fails; returns the list with a ForAll proof.")
    (cons "List.concatMap"      "fn List.concatMap(f: (a -> List b requires c), xs: List a) -> List b requires c\n\nMap each element to a list, then flatten one level. Equivalent to concat (map f xs). Also known as flatMap or bind.")
    (cons "List.member"         "fn List.member(x: a, xs: List a) -> Bool\n\nReturns True if x is an element of xs, False otherwise. Uses structural equality.")
    ;; Tesl.Maybe
    (cons "Maybe"               "type Maybe a\n  = Nothing\n  | Something value: a\n\nRepresents an optional value. Use case to match on Something v or Nothing.")
    (cons "Something"           "Something value — the presence variant of Maybe\n\nExample: Something 42, Something \"hello\"")
    (cons "Nothing"             "Nothing — the absence variant of Maybe\n\nRepresents the absence of a value.")
    ;; Tesl.Result
    (cons "Result"              "type Result ok err\n  = Ok value: ok\n  | Err error: err\n\nRepresents a computation that can succeed (Ok) or fail with an error (Err).\nPrefer Result over Maybe when the failure reason is meaningful.")
    (cons "Ok"                  "Ok value — the success variant of Result\n\nExample: Ok 42, Ok user")
    (cons "Err"                 "Err error — the failure variant of Result\n\nExample: Err \"not found\", Err (InvalidInput \"too short\")")
    ;; Tesl.Either
    (cons "Left"                "Left value — the error/other side of Either")
    (cons "Right"               "Right value — the success side of Either")
    (cons "Either.isLeft"       "fn Either.isLeft(e: Either a b) -> Bool")
    (cons "Either.isRight"      "fn Either.isRight(e: Either a b) -> Bool")
    (cons "Either.fromLeft"     "fn Either.fromLeft(e: Either a b) -> Maybe a")
    (cons "Either.fromRight"    "fn Either.fromRight(e: Either a b) -> Maybe b")
    (cons "Either.map"          "fn Either.map(f: a -> b, e: Either) -> Either")
    (cons "Either.mapLeft"      "fn Either.mapLeft(f: a -> c, e: Either a b) -> Either c b")
    (cons "Either.andThen"      "fn Either.andThen(f: a -> Either, e: Either) -> Either")
    (cons "Either.withDefault"  "fn Either.withDefault(default: a, e: Either) -> a")
    (cons "Either.toMaybe"      "fn Either.toMaybe(e: Either) -> Maybe a")
    (cons "Either.fromMaybe"    "fn Either.fromMaybe(leftVal: a, m: Maybe b) -> Either a b")
    (cons "Either.partition"    "fn Either.partition(eithers: List (Either a b)) -> List (List Any)  — returns [lefts, rights]")
    ;; Tesl.Dict
    (cons "Dict.empty"          "Dict.empty : Dict  — an empty dictionary")
    (cons "Dict.singleton"      "fn Dict.singleton(key: k, value: v) -> Dict")
    (cons "Dict.insert"         "fn Dict.insert(key: k, value: v, d: Dict) -> Dict")
    (cons "Dict.remove"         "fn Dict.remove(key: k, d: Dict) -> Dict")
    (cons "Dict.lookup"         "fn Dict.lookup(key: k, d: Dict) -> Maybe v")
    (cons "Dict.requireKey"     "check Dict.requireKey(key: k, d: Dict k v) -> d: Dict k v ::: HasKey key d")
    (cons "Dict.get"            "fn Dict.get(key: k, d: Dict k v ::: HasKey key d) -> v")
    (cons "Dict.member"         "fn Dict.member(key: k, d: Dict) -> Bool")
    (cons "Dict.size"           "fn Dict.size(d: Dict) -> Int")
    (cons "Dict.isEmpty"        "fn Dict.isEmpty(d: Dict) -> Bool")
    (cons "Dict.fromList"       "fn Dict.fromList(pairs: List (k, v)) -> Dict k v\n\nBuild a Dict from a list of (key, value) pairs. Later duplicates win.")
    (cons "Dict.toList"         "fn Dict.toList(d: Dict k v) -> List (k, v)")
    (cons "Dict.union"          "fn Dict.union(d1: Dict, d2: Dict) -> Dict  — d1 wins on conflict")
    (cons "Dict.unionWith"      "fn Dict.unionWith(f: (v, v) -> v, d1: Dict, d2: Dict) -> Dict")
    (cons "Dict.intersection"   "fn Dict.intersection(d1: Dict, d2: Dict) -> Dict")
    (cons "Dict.difference"     "fn Dict.difference(d1: Dict, d2: Dict) -> Dict")
    (cons "Dict.keys"           "fn Dict.keys(d: Dict) -> List k")
    (cons "Dict.values"         "fn Dict.values(d: Dict) -> List v")
    (cons "Dict.map"            "fn Dict.map(f: v -> w, d: Dict) -> Dict")
    (cons "Dict.filter"         "fn Dict.filter(pred: v -> Bool, d: Dict) -> Dict")
    (cons "Dict.filterCheckValues" "fn Dict.filterCheckValues(checkFn: check v, d: Dict k v) -> Dict k v ::: ForAllValues P\n\nFilter by applying a check function to each value. Entries whose value passes are kept with the proof attached. Entries that fail are dropped.\n\nUse as the body of a function returning Dict k v ::: ForAllValues P.")
    (cons "Dict.filterCheckKeys"   "fn Dict.filterCheckKeys(checkFn: check k, d: Dict k v) -> Dict k v ::: ForAllKeys P\n\nFilter by applying a check function to each key. Entries whose key passes are kept with the proof attached. Entries that fail are dropped.\n\nUse as the body of a function returning Dict k v ::: ForAllKeys P.")
    (cons "Dict.foldl"          "fn Dict.foldl(f: (b, v) -> b, init: b, d: Dict) -> b")
    (cons "Dict.foldr"          "fn Dict.foldr(f: (v, b) -> b, init: b, d: Dict) -> b")
    (cons "Dict.update"         "fn Dict.update(key: k, f: Maybe v -> Maybe v, d: Dict) -> Dict")
    ;; Tesl.Set
    (cons "Set.empty"           "Set.empty : Set  — an empty set")
    (cons "Set.singleton"       "fn Set.singleton(x: a) -> Set")
    (cons "Set.insert"          "fn Set.insert(x: a, s: Set) -> Set")
    (cons "Set.remove"          "fn Set.remove(x: a, s: Set) -> Set")
    (cons "Set.member"          "fn Set.member(x: a, s: Set) -> Bool")
    (cons "Set.size"            "fn Set.size(s: Set) -> Int")
    (cons "Set.isEmpty"         "fn Set.isEmpty(s: Set) -> Bool")
    (cons "Set.union"           "fn Set.union(s1: Set, s2: Set) -> Set")
    (cons "Set.intersection"    "fn Set.intersection(s1: Set, s2: Set) -> Set")
    (cons "Set.difference"      "fn Set.difference(s1: Set, s2: Set) -> Set")
    (cons "Set.fromList"        "fn Set.fromList(xs: List a) -> Set")
    (cons "Set.toList"          "fn Set.toList(s: Set) -> List a")
    (cons "Set.isSubset"        "fn Set.isSubset(s1: Set, s2: Set) -> Bool")
    (cons "Set.map"             "fn Set.map(f: (a -> b requires c), s: Set) -> Set requires c")
    (cons "Set.filter"          "fn Set.filter(pred: (a -> Bool requires c), s: Set) -> Set requires c")
    (cons "Set.foldl"           "fn Set.foldl(f: (b, a) -> b, init: b, s: Set) -> b")
    (cons "Set.any"             "fn Set.any(pred: (a -> Bool requires c), s: Set) -> Bool requires c")
    (cons "Set.all"             "fn Set.all(pred: (a -> Bool requires c), s: Set) -> Bool requires c")
    (cons "Set.filterCheck"     "fn Set.filterCheck(checkFn: check a, s: Set) -> Set\n\nFilter using a check function. Elements that pass are kept with their proof attached.")
    (cons "Set.allCheck"        "fn Set.allCheck(checkFn: check a, s: Set) -> Set\n\nApply a check to every element. Returns with ForAll proof.")
    ;; Capabilities
    (cons "dbRead"              "capability dbRead\n\nPermits read operations (select, selectOne).")
    (cons "dbWrite"             "capability dbWrite implies dbRead\n\nPermits write operations (insert, update, delete). Implies dbRead.")
    (cons "queueRead"           "capability queueRead\n\nPermits inspecting job queue status.")
    (cons "queueWrite"          "capability queueWrite implies queueRead\n\nPermits enqueueing background jobs (enqueue). Implies queueRead.")
    (cons "pubsub"              "capability pubsub\n\nPermits publishing to pub/sub channels (publish) and holding SSE subscriptions.")
    (cons "time"                "capability time\n\nPermits reading the current time (nowMillis(), durationMs()).")
    (cons "random"              "capability random\n\nPermits generating random values (randomInt, generatePrefixedId).")
    ;; Tesl.Time
    (cons "nowMillis"           "fn nowMillis() -> PosixMillis  requires [time]")
    (cons "formatTime"          "fn formatTime(ms: PosixMillis, timezone: String, fmt: String) -> String")
    (cons "durationMs"          "fn durationMs(pastMs: PosixMillis) -> Int  requires [time]\n\nMilliseconds elapsed since pastMs.")
    (cons "addMs"               "fn addMs(ts: PosixMillis, delta: Int) -> PosixMillis")
    (cons "subtractMs"          "fn subtractMs(ts: PosixMillis, delta: Int) -> PosixMillis")
    (cons "diffMs"              "fn diffMs(a: PosixMillis, b: PosixMillis) -> Int  — b − a in milliseconds")
    (cons "Time.posixToSeconds" "fn Time.posixToSeconds(ms: PosixMillis) -> Int")
    (cons "Time.secondsToPosix" "fn Time.secondsToPosix(s: Int) -> PosixMillis")
    (cons "PosixMillis"         "type PosixMillis\n\nCanonical Tesl timestamp: milliseconds since Unix epoch. Maps to BIGINT in PostgreSQL.")
    ;; Tesl.Id / Tesl.Random
    (cons "generatePrefixedId"  "fn generatePrefixedId(prefix: String) -> String  requires [random]")
    (cons "randomInt"           "fn randomInt(n: Int) -> Int  requires [random]\n\nReturns a uniformly random integer in [0, n).")
    ;; Tesl.Env
    (cons "env"                 "fn env(name: String) -> Maybe String")
    (cons "envInt"              "fn envInt(name: String, default: Int) -> Int\n\nReads the env var as an integer, returning `default` when it is unset or unparseable (so the result is always an `Int`, never `Maybe Int`).")
    (cons "requireEnv"          "fn requireEnv(name: String) -> String\n\nReads an env var as a String, failing at startup if it is unset. The String-returning counterpart to `env` (which returns `Maybe String`), for places that need a value directly — e.g. `anthropic (requireEnv \"ANTHROPIC_API_KEY\") \"claude-opus-4-8\"`.")
    ;; Tesl.Agent (AI)
    (cons "Agent"               "Agent { provider: LlmProvider, systemPrompt: String, maxTokens: Int, tools: List Tool } -> Agent\n\nThe agent constructor. Use it as a top-level `agent X requires [..] = Agent { … }` block OR as a plain expression (e.g. building a per-request bring-your-own-key agent inside a function). `provider` is a full LlmProvider (`anthropic key model`, `mistral key model`, `mockProvider [...]`, …); `tools` is a `List Tool` — wrap typed functions with `asTool`.")
    (cons "tool"                "fn tool(name: String, description: String, schema: String, validate: (String) -> a, dispatch: (a) -> String) -> Tool\n\nBuild a tool from a name, description, JSON-schema string, an argument validator, and a dispatch function. For a typed Tesl function, prefer `asTool`, which derives all of this automatically.")
    (cons "asTool"              "asTool <fn> -> Tool\n\nWrap a typed Tesl function as an LLM tool: the JSON schema is derived from the function's parameter types, the model's tool-call arguments are decoded into those parameters, and the function is dispatched — no hand-written schema or validator. Use it in an `Agent { tools: [...] }` field (block or expression), e.g. `tools: [asTool lookupOrderStatus]`. The tool's description is the function's doc-comment.")
    (cons "ask"                 "fn ask(agent: Agent, prompt: String) -> String\n  requires [aiProvider]\n\nRun the agent's tool-calling loop on the prompt and return the model's final assistant text.")
    (cons "askReply"            "fn askReply(agent: Agent, prompt: String) -> AgentReply\n  requires [aiProvider]\n\nLike ask, but returns a richer AgentReply (text + token usage + tool-call count).")
    (cons "askWith"             "fn askWith(agent: Agent, prompt: String, provider: LlmProvider) -> AgentReply\n  requires [aiProvider]\n\nLike askReply, but overrides the agent's default provider for this call — the per-user / bring-your-own-key (BYOK) path.")
    (cons "askFor"              "fn askFor(agent: Agent, prompt: String, decode: (String) -> a, maxRetries: Int) -> a\n  requires [aiProvider]\n\nStructured output: run inference, decode the reply into a typed value, and retry up to maxRetries on a decode failure. Only a well-typed value escapes.")
    (cons "decodeAs"            "fn decodeAs(typeName: String, json: String) -> a\n\nDecode a JSON string into the named type through its codec (the same proof-carrying path an HTTP body uses). Raises on malformed input.")
    (cons "replyText"           "fn replyText(reply: AgentReply) -> String\n\nThe model's final assistant text.")
    (cons "replyTokens"         "fn replyTokens(reply: AgentReply) -> Int\n\nThe token usage the provider reported for the reply.")
    (cons "replyToolCalls"      "fn replyToolCalls(reply: AgentReply) -> Int\n\nHow many tool round-trips the loop made — assert the exact tool-call sequence length.")
    (cons "anthropic"           "fn anthropic(apiKey: String, model: String) -> LlmProvider\n\nAn Anthropic provider binding. Used inline as an agent block's `provider:` default, or passed to askWith for BYOK.")
    (cons "openai"              "fn openai(apiKey: String, model: String) -> LlmProvider\n\nAn OpenAI provider binding.")
    (cons "mistral"             "fn mistral(apiKey: String, model: String) -> LlmProvider\n\nA Mistral provider binding (the OpenAI-compatible chat-completions API at Mistral's endpoint).")
    (cons "local"               "fn local(endpoint: String, model: String) -> LlmProvider\n\nA local / OpenAI-compatible provider binding (e.g. Ollama, vLLM) reached at endpoint.")
    (cons "mockProvider"        "fn mockProvider(replies: List String) -> LlmProvider\n\nA deterministic text provider for tests: returns the scripted replies by call index. No network, no keys, no cost.")
    (cons "mockToolProvider"    "fn mockToolProvider(steps: List ToolStep) -> LlmProvider\n\nA deterministic tool-calling provider for tests: scripts the model's tool-use requests and final text with toolUseStep / textStep.")
    (cons "toolUseStep"         "fn toolUseStep(name: String, id: String, argsJson: String) -> ToolStep\n\nScript one model tool-call (with the raw arguments JSON it produced) for a mockToolProvider.")
    (cons "textStep"            "fn textStep(text: String) -> ToolStep\n\nScript the model's final assistant text for a mockToolProvider; ends the loop.")
    (cons "agentRun"            "fn agentRun(agent: Agent, prompt: String, publish: (String) -> Unit) -> AgentReply\n  requires [aiProvider]\n\nRun the agent loop to completion (typically on a worker), publishing each step via the callback. For long, worker-backed runs.")
    (cons "newConversation"     "fn newConversation(agent: Agent) -> Conversation\n\nStart a fresh multi-turn conversation for the agent.")
    (cons "conversationFrom"    "fn conversationFrom(agent: Agent, json: String) -> Conversation\n\nRestore a conversation from its persisted JSON (see conversationJson).")
    (cons "converse"            "fn converse(conversation: Conversation, prompt: String) -> ConversationTurn\n  requires [aiProvider]\n\nTake one turn: send the prompt and return a ConversationTurn carrying the reply and the advanced conversation.")
    (cons "converseStreaming"   "fn converseStreaming(conversation: Conversation, prompt: String, publish: (String) -> Unit) -> ConversationTurn\n  requires [aiProvider]\n\nLike converse, but calls `publish` once per loop step with a step event (\"tool: <name>\" as each tool runs, \"text: <reply>\" for the final text) — stream the tool-use/thought process and reply over SSE while threading conversation history.")
    (cons "turnReply"           "fn turnReply(turn: ConversationTurn) -> AgentReply\n\nThe AgentReply produced by a conversation turn.")
    (cons "turnConversation"    "fn turnConversation(turn: ConversationTurn) -> Conversation\n\nThe conversation advanced past this turn (thread it into the next converse).")
    (cons "conversationJson"    "fn conversationJson(conversation: Conversation) -> String\n\nSerialize a conversation to JSON for persistence; restore with conversationFrom.")
    (cons "conversationLength"  "fn conversationLength(conversation: Conversation) -> Int\n\nThe number of turns recorded in the conversation.")
    (cons "Agent"               "type Agent\n\nA capability-bounded AI agent: provider + system prompt + tools. Declared with the `agent { … }` block or built with defineAgent.")
    (cons "LlmProvider"         "type LlmProvider\n\nA provider binding (which model answers and whose key pays). Built with anthropic / openai / local / mockProvider; resolved per call via askWith for BYOK.")
    (cons "AgentReply"          "type AgentReply\n\nThe result of an agent run: final text (replyText), token usage (replyTokens), and tool-call count (replyToolCalls).")
    (cons "Tool"                "type Tool\n\nA tool the model may call. In the declarative `agent` block, tools are typed Tesl functions; the schema and argument decoding are derived from the function signature.")
    (cons "ToolStep"            "type ToolStep\n\nA scripted step for mockToolProvider: a model tool-call (toolUseStep) or final assistant text (textStep).")
    (cons "Conversation"        "type Conversation\n\nMulti-turn agent conversation state. Advance with converse; persist with conversationJson / conversationFrom.")
    (cons "ConversationTurn"    "type ConversationTurn\n\nOne conversation turn: the reply (turnReply) plus the advanced conversation (turnConversation).")
    (cons "aiProvider"          "capability aiProvider implies httpClient\n\nThe AI boundary capability: every inference call (ask / askReply / askWith / askFor / converse / agentRun) requires it. Implies httpClient because real providers perform outbound HTTP.")
    ;; Fact operations (Tesl.Prelude)
    (cons "attachFact"          "fn attachFact(value: a, fact: Fact p) -> a ::: p")
    (cons "detachFact"          "fn detachFact(value: a ::: p) -> Fact p")
    (cons "forgetFact"          "fn forgetFact(value: a ::: p) -> a")
    (cons "introAnd"            "fn introAnd(left: Fact p, right: Fact q) -> Fact (p && q)")
    (cons "andLeft"             "fn andLeft(fact: Fact (p && q)) -> Fact p")
    (cons "andRight"            "fn andRight(fact: Fact (p && q)) -> Fact q")
    ;; Well-known GDP proof predicates
    (cons "FromDb"              "GDP fact predicate: value was fetched from the database via the trusted SQL boundary.")
    (cons "FromQueue"           "GDP fact predicate: job was dequeued via the trusted queue boundary.")
    (cons "IsTrimmed"           "Proof predicate: String has no leading/trailing whitespace.\n\nAttached by String.trim, String.trimLeft, String.trimRight.")
    (cons "IsUpperCase"         "Proof predicate: String is entirely uppercase.\n\nAttached by String.toUpper.")
    (cons "IsLowerCase"         "Proof predicate: String is entirely lowercase.\n\nAttached by String.toLower.")
    (cons "IsSorted"            "Proof predicate: List is sorted in ascending order.\n\nAttached by List.sort, List.sortBy.")
    (cons "IsNonNegative"       "Proof predicate: Int is >= 0.\n\nAttached by Int.nonNegative. Required by List.take, List.drop, List.repeat.")
    (cons "IsNonEmpty"          "Proof predicate: String is non-empty.\n\nAttached by String.requireNonEmpty.")
    (cons "IsNonZero"           "Proof predicate: Int != 0.\n\nAttached by Int.nonZero. Required by Int.divide.")
    ;; Load-test keywords
    (cons "load-test"           "load-test \"name\" for Server rate Nrps duration Ns { ... }\n\nDeclares a load/performance test using an open workload model. Reuses the same seed and request syntax as api-test. Asserts on latency percentiles, throughput, and error rate.")
    (cons "rate"                "rate Nrps\n\nTarget arrival rate in requests per second for a load-test block. Uses an open workload model — requests arrive at a fixed rate regardless of response time.")
    (cons "duration"            "duration Ns\n\nMeasurement phase duration in seconds for a load-test block. Warm-up runs automatically before measurement begins.")
    (cons "baseline"            "baseline \"label\"\n\nCompare load-test results against a stored baseline. Baselines are stored in .tesl-baselines/ as JSON. First run creates the baseline; subsequent runs compare against it.")
    (cons "regressionVsBaseline" "assert regressionVsBaseline metric < ratio\n\nAsserts the current run's metric is within ratio× of the stored baseline. E.g. `assert regressionVsBaseline p95 < 1.2` fails if p95 regressed more than 20%.")
    (cons "p50"                 "Load-test metric: 50th percentile (median) latency in milliseconds.")
    (cons "p95"                 "Load-test metric: 95th percentile latency in milliseconds.")
    (cons "p99"                 "Load-test metric: 99th percentile latency in milliseconds.")
    (cons "errorRate"           "Load-test metric: fraction of requests that returned HTTP >= 400 or threw an exception.")
    (cons "throughput"          "Load-test metric: actual achieved requests per second during the measurement phase.")
    ;; GDP proof predicates and keywords
    (cons "fact"                "fact PredicateName (param: T)\n\nDeclares a compile-time proof predicate (GDP fact). Used with check functions to attach proofs to values at the type level. The predicate is erased at runtime — zero overhead.")
    (cons "ForAll"              "ForAll P\n\nProof annotation on a list or set: every element satisfies predicate P.\n\nExample: List Int ::: ForAll (IsPositive)\n\nProduced by List.filterCheck, List.allCheck, Set.filterCheck, Set.allCheck.\nConsumed by functions that require all elements to meet a precondition.")
    (cons "ForAllValues"        "ForAllValues P\n\nProof annotation on a Dict: every value satisfies predicate P.\n\nExample: Dict String User ::: ForAllValues (IsAuthenticated)\n\nProduced by Dict.filterCheckValues.\nConsumed by functions that require all dict values to meet a precondition.")
    (cons "ForAllKeys"          "ForAllKeys P\n\nProof annotation on a Dict: every key satisfies predicate P.\n\nExample: Dict Email User ::: ForAllKeys (IsValidEmail)\n\nProduced by Dict.filterCheckKeys.\nConsumed by functions that require all dict keys to meet a precondition.")
    (cons "ok"                  "ok value ::: ProofName arg\n\nSuccessful return inside a `check` function. Attaches the GDP proof to the returned value.\n\nExample:\n  check isPositive(n: Int) -> n: Int ::: IsPositive n =\n    if n > 0 then ok n ::: IsPositive n\n    else fail 400 \"not positive\"")
    (cons "fail"                "fail statusCode \"message\"\n\nFails inside a `check` function (or any function). Returns a check-failure with an HTTP status code and description.\n\nExample: fail 400 \"value out of range\"")
    ;; SQL query keywords
    (cons "select"              "select p from Entity\n  where p.field == val\n  order p.field asc\n  limit N\n\nSelects rows from an entity table. Returns List Entity.\nField names are validated at compile time.")
    (cons "selectOne"           "selectOne p from Entity where p.field == val\n\nSelects at most one row. Returns Maybe Entity — Nothing if no row matches, Something entity otherwise.")
    (cons "selectCount"         "selectCount p from Entity\n  where p.field == val\n\nReturns the number of matching rows as Int.")
    (cons "selectSum"           "selectSum p.field from Entity\n  where p.field >= lo\n\nReturns the sum of a numeric field across matching rows. Returns 0 if no rows match. Return type matches the field type (Int or Float).")
    (cons "selectMax"           "selectMax p.field from Entity\n  where p.field == val\n\nReturns the maximum value of a numeric field across matching rows. Supports the same where/order/limit/groupBy clauses as select. Return type matches the field type (Int or Float).")
    (cons "selectMin"           "selectMin p.field from Entity\n  where p.field == val\n\nReturns the minimum value of a numeric field across matching rows. Supports the same where/order/limit/groupBy clauses as select. Return type matches the field type (Int or Float).")
    (cons "insert"              "insert Entity { field: value, ... }\n\nInserts one row. Returns the inserted entity with a FromDb proof attached.")
    (cons "insertMany"          "insertMany list in Entity\n\nInserts all entities in list into the table. Returns Unit.\n\nUse for batch inserts: webhook handlers, import pipelines.")
    (cons "update"              "update p in Entity where p.field == val set p.field = newVal\n\nUpdates matching rows. Returns Unit.")
    (cons "updateAndReturnOne"  "updateAndReturnOne p in Entity\n  where p.field == val\n  set p.field = newVal\n\nUpdates one matching row and returns the updated entity with FromDb proof. Raises 404 at runtime if no row matches.")
    (cons "delete"              "delete p from Entity where p.field == val\n\nDeletes matching rows. Returns Unit.")
    (cons "deleteAndReturnResult" "deleteAndReturnResult p from Entity where p.field == val\n\nDeletes matching rows. Returns DeleteResult:\n  NoRowDeleted — no rows matched\n  RowsDeleted n — n rows were deleted")
    (cons "upsert"              "upsert Entity { field: val, ... } onConflict [keyField] doUpdate [f1, f2]\n\nInserts a row; if a row with the same value in [keyField] already exists, updates [f1, f2] instead.\nMaps to INSERT … ON CONFLICT DO UPDATE in PostgreSQL.\nIdeal for idempotent writes: webhook handlers, import pipelines, retry-safe endpoints.")
    (cons "onConflict"          "onConflict [keyField]\n\nPart of upsert: specifies the conflict-target field(s).")
    (cons "doUpdate"            "doUpdate [field1, field2]\n\nPart of upsert: specifies which fields to overwrite on conflict.")
    (cons "groupBy"             "groupBy p.field\n\nSQL GROUP BY modifier for selectCount and selectSum queries.\n\nExample:\n  selectCount p from Product\n  groupBy p.category")
    (cons "like"                "where like p.field \"pattern%\"\n\nSQL LIKE predicate (case-sensitive). % matches any sequence of characters, _ matches exactly one character.\n\nExample: where like p.name \"Widget%\"")
    (cons "ilike"               "where ilike p.field \"pattern%\"\n\nSQL ILIKE predicate (case-insensitive). Same wildcards as like.\nPostgreSQL extension — in-memory backend treats it identically to like.\n\nExample: where ilike p.name \"widget%\"")
    (cons "order"               "order p.field asc\norder p.field desc\n\nSQL ORDER BY modifier. Use asc or desc for direction.")
    (cons "limit"               "limit N\n\nSQL LIMIT modifier — restricts the number of rows returned.")
    (cons "offset"              "offset N\n\nSQL OFFSET modifier — skips the first N rows.")
    (cons "innerJoin"           "innerJoin OtherEntity on p.fk == o.id\n\nSQL INNER JOIN — combines rows from two entities where the join condition holds.")
    (cons "from"                "from Entity\n\nSpecifies the source entity table in a SQL query."))))

(define (format-stdlib-hover raw)
  ;; Entries with "\n\n" split into code block + prose.
  (let ([m (regexp-match-positions #rx"\n\n" raw)])
    (if m
        (let* ([idx       (caar m)]
               [code-part (substring raw 0 idx)]
               [prose     (string-trim (substring raw (+ idx 2)))])
          (format "```tesl\n~a\n```\n\n~a" code-part prose))
        (format "```tesl\n~a\n```" raw))))

;; ── Keyword completions ────────────────────────────────────────────────────────
;; The compiler's --completions-json returns in-scope identifiers (functions,
;; locals, stdlib, ctors) but NOT language keywords. We supply those here so the
;; completion list covers the whole surface syntax. Each entry is
;; (label . short-detail); richer markdown docs come from stdlib-sigs when present
;; (e.g. select, insert, ok, fail, fact, order, limit … all have stdlib-sigs docs).

(define tesl-keywords
  '( ;; Declarations
    ("module"      . "module declaration")
    ("exposing"    . "module export list")
    ("import"      . "import another module")
    ("fn"          . "function declaration")
    ("check"       . "check function — returns a proof-carrying value")
    ("auth"        . "authentication declaration")
    ("handler"     . "request handler")
    ("worker"      . "background worker")
    ("deadWorker"  . "dead-letter worker")
    ("establish"   . "establish a proof for a value")
    ("type"        . "algebraic data type declaration")
    ("record"      . "record type declaration")
    ("entity"      . "database entity declaration")
    ("capability"  . "capability declaration")
    ("database"    . "database declaration")
    ("queue"       . "job queue declaration")
    ("sseChannel"     . "pub/sub channel declaration")
    ("codec"       . "JSON codec declaration")
    ("capture"     . "capture clause")
    ("server"      . "server declaration")
    ("main"        . "program entry point")
    ("implies"     . "capability implication")
    ("requires"    . "required capabilities list")
    ("fact"        . "GDP proof-predicate declaration")
    ;; Control flow / expressions
    ("if"          . "conditional expression")
    ("then"        . "then branch")
    ("else"        . "else branch")
    ("case"        . "pattern match expression")
    ("of"          . "case scrutinee/branches")
    ("let"         . "local binding")
    ("in"          . "let-body / membership")
    ("exists"      . "existential proof")
    ("ok"          . "successful check return (attaches proof)")
    ("fail"        . "fail with HTTP status and message")
    ("where"       . "query / guard condition")
    ("with"        . "with clause")
    ("transaction" . "atomic database transaction")
    ("and"         . "proof conjunction")
    ;; Tests
    ("test"            . "unit test block")
    ("seed"            . "api-test seed data")
    ("property"        . "property-based test")
    ("expect"          . "test assertion")
    ("expectFail"      . "expect a check to fail")
    ("expectHasProof"  . "expect a value to carry a proof")
    ("runs"            . "api-test request")
    ("via"             . "capture proof via a check")
    ("assert"          . "load-test assertion")
    ("rate"            . "load-test arrival rate (rps)")
    ("duration"        . "load-test measurement duration (s)")
    ("baseline"        . "compare against a stored baseline")
    ("regressionVsBaseline" . "assert no regression vs baseline")
    ;; SQL / query body
    ("select"               . "select rows from an entity")
    ("selectOne"            . "select at most one row")
    ("selectCount"          . "count matching rows")
    ("selectSum"            . "sum a numeric field")
    ("selectMax"            . "max of a numeric field")
    ("selectMin"            . "min of a numeric field")
    ("from"                 . "query source entity")
    ("insert"               . "insert one row")
    ("insertMany"           . "batch insert rows")
    ("update"               . "update matching rows")
    ("updateAndReturnOne"   . "update one row and return it")
    ("set"                  . "update assignment clause")
    ("returning"            . "returning clause")
    ("delete"               . "delete matching rows")
    ("deleteAndReturnResult" . "delete and return DeleteResult")
    ("upsert"               . "insert or update on conflict")
    ("onConflict"           . "upsert conflict target")
    ("doUpdate"             . "upsert fields to overwrite")
    ("order"                . "ORDER BY clause")
    ("limit"                . "LIMIT clause")
    ("offset"               . "OFFSET clause")
    ("groupBy"              . "GROUP BY clause")
    ("like"                 . "SQL LIKE predicate")
    ("ilike"                . "SQL ILIKE predicate (case-insensitive)")
    ("innerJoin"            . "SQL INNER JOIN")
    ("asc"                  . "ascending sort order")
    ("desc"                 . "descending sort order")
    ;; Effects / serving
    ("serve"          . "serve the API")
    ("telemetry"      . "emit an OpenTelemetry span")
    ("initTelemetry"  . "configure the telemetry exporter")
    ("enqueue"        . "enqueue a background job")
    ("publish"        . "publish to a pub/sub channel")
    ("subscribe"      . "subscribe to a channel")
    ("get"            . "GET route")
    ("post"           . "POST route")
    ("put"            . "PUT route")
    ("body"           . "request body binding")
    ("response"       . "response binding")
    ("retry"          . "job retry policy")
    ("maxAttempts"    . "max retry attempts")
    ("backoff"        . "retry backoff strategy")
    ;; Literals
    ("True"     . "Bool literal")
    ("False"    . "Bool literal")
    ("Nothing"  . "Maybe — absence variant")))

;; Compound (hyphenated) keywords that can't be typed as a single ident token.
(define tesl-compound-keywords
  '(("api-test"     . "API integration test block")
    ("load-test"    . "load / performance test block")
    ("dead-worker"  . "dead-letter worker declaration")))

;; Snippet bodies (LSP InsertTextFormat=2) for the highest-value structural
;; keywords. Each maps a keyword label → a tabstop template. Only keywords that
;; meaningfully expand into a multi-token scaffold are listed; everything else
;; inserts as a plain word. ${1:foo} are placeholders, $0 the final cursor.
(define tesl-snippets
  (hash
   "fn"       "fn ${1:name}(${2:arg}: ${3:Type}) -> ${4:Type} =\n  $0"
   "check"    "check ${1:name}(${2:arg}: ${3:Type}) -> ${4:Type} =\n  $0"
   "if"       "if ${1:condition}\nthen\n  ${2:thenExpr}\nelse\n  ${0:elseExpr}"
   "case"     "case ${1:subject} of\n  ${2:Pattern} -> ${0:result}"
   "let"      "let ${1:name} = ${0:expr}"
   "type"     "type ${1:Name}\n  = ${2:Variant}\n  | ${0:Variant}"
   "record"   "record ${1:Name} {\n  ${2:field}: ${0:Type}\n}"
   "test"     "test \"${1:description}\" {\n  expect ${0:expr}\n}"
   "module"   "module ${1:Name} exposing [$0]"
   "import"   "import ${1:Tesl.Module} exposing [$0]"
   "handler"  "handler ${1:Name} =\n  $0"
   "worker"   "worker ${1:Name} =\n  $0"))

(define (keyword-doc-markdown label detail)
  ;; Prefer the richer stdlib-sigs entry (multi-line usage block) when one exists
  ;; for this keyword; otherwise fall back to the short detail string.
  (cond
    [(hash-ref stdlib-sigs label #f) => format-stdlib-hover]
    [else detail]))

;; ── Declaration parser ────────────────────────────────────────────────────────
;;
;; Entry: (vector file-path line-idx kind sig extra)
;;   sig   — first declaration line with trailing " =" or "{" stripped
;;   extra — depends on kind:
;;     fn/check/auth/establish/handler/worker/deadWorker → indented body lines
;;     type                                              → "  = Ctor …" / "  | Ctor …" lines
;;     record/entity                                     → field lines from { } block
;;     other                                             → '()

(define decl-pattern
  #rx"^(fn|check|auth|handler|worker|deadWorker|establish|type|record|entity|capability|database|queue|channel|codec)[ \t]+([A-Za-z_][A-Za-z0-9_]*)")

(define local-let-pattern
  #rx"^let[ \t]+([A-Za-z_][A-Za-z0-9_]*)")

(define func-kinds '("fn" "check" "auth" "establish" "handler" "worker" "deadWorker"))

(define (find-local-binding-type binding-types line-idx name)
  (for/or ([binding (in-list binding-types)])
    (and (= (hash-ref binding 'line -1) line-idx)
         (equal? (hash-ref binding 'name "") name)
         (hash-ref binding 'type #f))))

(define (parse-local-let-line file-path raw-line line-idx [binding-types '()])
  (let* ([trimmed (string-trim raw-line)]
         [m       (regexp-match local-let-pattern trimmed)])
    (and m
         (let* ([name (cadr m)]
                [binding-type (find-local-binding-type binding-types line-idx name)]
                [sig (if binding-type (format "~a: ~a" name binding-type) trimmed)])
           (cons name
                 (vector file-path line-idx "let" sig '()))))))

(define (strip-decl-trailing s)
  ;; Remove trailing bare "=" (function body delimiter) or "{" (block opener).
  ;; Note: string-suffix? s1 s2 → #t if s1 ends with s2
  (let ([t (string-trim s)])
    (cond
      ;; Trailing bare "=" — not "==" or "=>"
      [(and (string-suffix? t "=")
            (not (string-suffix? t "=="))
            (not (string-suffix? t "=>")))
       (string-trim (substring t 0 (- (string-length t) 1)))]
      ;; Trailing "{"
      [(string-suffix? t "{")
       (string-trim (substring t 0 (- (string-length t) 1)))]
      [else t])))

(define (collect-body lines start-idx)
  ;; Collect indented non-blank lines after line start-idx (the declaration).
  ;; Stops at the first non-indented non-blank line.
  (define n (length lines))
  (let lp ([j (+ start-idx 1)] [acc '()])
    (if (>= j n)
        (reverse acc)
        (let ([raw (list-ref lines j)])
          (cond
            [(string=? (string-trim raw) "")
             (lp (+ j 1) acc)]
            [(and (> (string-length raw) 0)
                  (not (char-whitespace? (string-ref raw 0))))
             (reverse acc)]
            [else
             (lp (+ j 1) (cons (string-trim raw) acc))])))))

(define (collect-variants lines start-idx)
  ;; Collect ADT variant lines after a "type" declaration.
  ;; Returns strings prefixed with "  " like "  = Open" / "  | Done".
  (define n (length lines))
  (let lp ([j (+ start-idx 1)] [acc '()])
    (if (>= j n)
        (reverse acc)
        (let* ([raw (list-ref lines j)]
               [s   (string-trim raw)])
          (cond
            [(string=? s "")           (lp (+ j 1) acc)]
            [(string-prefix? s "#")    (lp (+ j 1) acc)]
            [(regexp-match? #rx"^[=|]" s)
             (lp (+ j 1) (cons (string-append "  " s) acc))]
            [else (reverse acc)])))))

(define (collect-brace-fields lines start-idx)
  ;; Collect field lines from a { … } block, tracking brace depth.
  (define n (length lines))
  (let lp ([j (+ start-idx 1)] [acc '()] [depth 1])
    (if (or (>= j n) (<= depth 0))
        (reverse acc)
        (let* ([raw   (list-ref lines j)]
               [s     (string-trim raw)]
               [opens  (length (regexp-match* #rx"[{]" s))]
               [closes (length (regexp-match* #rx"[}]" s))]
               [new-d  (+ depth opens (- closes))])
          (cond
            [(string=? s "")         (lp (+ j 1) acc new-d)]
            [(string-prefix? s "#")  (lp (+ j 1) acc new-d)]
            [(<= new-d 0)            (reverse acc)]           ;; closing brace
            [else                    (lp (+ j 1) (cons s acc) new-d)])))))

(define (parse-decls! table file-path text)
  (define lines (string-split text "\n"))
  (for ([raw-line (in-list lines)]
        [i        (in-naturals)])
    ;; Only process non-indented lines (top-level declarations)
    (when (and (> (string-length raw-line) 0)
               (not (char-whitespace? (string-ref raw-line 0))))
      (let* ([line (string-trim raw-line)]
             [m    (regexp-match decl-pattern line)])
        (when m
          (let* ([kw      (cadr m)]
                 [name    (caddr m)]
                 [sig     (strip-decl-trailing line)]
                 [extra   (cond
                            [(member kw func-kinds equal?)
                             (collect-body lines i)]
                            [(equal? kw "type")
                             (collect-variants lines i)]
                            [(or (equal? kw "record") (equal? kw "entity")
                                 (equal? kw "database"))
                             (collect-brace-fields lines i)]
                            [else '()])])
            (unless (hash-has-key? table name)
              (hash-set! table name (vector file-path i kw sig extra)))
            ;; For ADTs: add each constructor as an entry pointing to the parent type
            (when (equal? kw "type")
              (for ([variant (in-list extra)])
                (let ([mc (regexp-match #rx"^  [=|][ \t]+([A-Z][A-Za-z0-9_]*)" variant)])
                  (when mc
                    (let ([ctor-name (cadr mc)])
                      (unless (hash-has-key? table ctor-name)
                        (hash-set! table ctor-name
                                   (vector file-path i kw sig extra))))))))))))))

;; ── Hover formatter ───────────────────────────────────────────────────────────

(define (format-hover-entry entry [note #f])
  (define kw    (vector-ref entry 2))
  (define sig   (vector-ref entry 3))
  (define extra (vector-ref entry 4))
  (define base
    (cond
      ;; check / auth: signature block + body excerpt (≤5 lines)
      [(or (equal? kw "check") (equal? kw "auth"))
       (if (null? extra)
           (format "```tesl\n~a\n```" sig)
           (let* ([shown    (take extra (min 5 (length extra)))]
                  [ellipsis (> (length extra) 5)]
                  [body     (string-join shown "\n  ")])
             (string-append
              (format "```tesl\n~a\n```" sig)
              "\n\n"
              (format "```tesl\n  ~a~a\n```" body (if ellipsis "\n  ..." "")))))]
      ;; establish: full signature + full body
      [(equal? kw "establish")
       (if (null? extra)
           (format "```tesl\n~a\n```" sig)
           (format "```tesl\n~a =\n  ~a\n```" sig (string-join extra "\n  ")))]
      ;; type: show full ADT with variants
      [(equal? kw "type")
       (if (null? extra)
           (format "```tesl\n~a\n```" sig)
           (format "```tesl\n~a\n~a\n```" sig (string-join extra "\n")))]
      ;; record / entity / database: show brace-block fields
      [(or (equal? kw "record") (equal? kw "entity") (equal? kw "database"))
       (if (null? extra)
           (format "```tesl\n~a\n```" sig)
           (let* ([shown    (take extra (min 10 (length extra)))]
                  [ellipsis (> (length extra) 10)]
                  [fields   (string-join (map (lambda (f) (string-append "  " f)) shown) "\n")])
             (format "```tesl\n~a {\n~a~a\n}\n```"
                     sig fields
                     (if ellipsis
                         (format "\n  ... (+~a more)" (- (length extra) 10))
                         ""))))]
      ;; local binding hover: signature plus optional note lines from compiler metadata
      [(equal? kw "local")
       (if (null? extra)
           (format "```tesl\n~a\n```" sig)
           (string-append
            (format "```tesl\n~a\n```" sig)
            "\n\n"
            (string-join (map (lambda (line) (format "*~a*" line)) extra) "\n")))]
      ;; default (fn, handler, capability, etc.): just the signature
      [else (format "```tesl\n~a\n```" sig)]))
  (if note
      (string-append base "\n\n" note)
      base))

;; ── Proof-predicate lookup ────────────────────────────────────────────────────

(define (find-proof-owner table pred-name)
  ;; Return the first check/establish/auth entry whose signature mentions pred-name.
  ;; pred-name must start with an uppercase letter (proof predicates are PascalCase).
  (and (> (string-length pred-name) 0)
       (char-upper-case? (string-ref pred-name 0))
       (let ([pat (pregexp (string-append "\\b" (regexp-quote pred-name) "\\b"))])
         (for/or ([(name entry) (in-hash table)])
           (and (member (vector-ref entry 2) '("check" "establish" "auth"))
                (regexp-match? pat (vector-ref entry 3))
                entry)))))

;; ── Import resolution ─────────────────────────────────────────────────────────

(define (resolve-import-path source-file module-name)
  (define dir (path-only (string->path source-file)))
  (define (kebab s)
    (list->string
     (let loop ([cs (string->list s)] [first #t])
       (cond [(null? cs) '()]
             [(char-upper-case? (car cs))
              (if first
                  (cons (char-downcase (car cs)) (loop (cdr cs) #f))
                  (cons #\- (cons (char-downcase (car cs)) (loop (cdr cs) #f))))]
             [else (cons (car cs) (loop (cdr cs) #f))]))))
  (let* ([d        (or dir (current-directory))]
         [kebab-p  (build-path d (string-append (kebab module-name) ".tesl"))]
         [pascal-p (build-path d (string-append module-name ".tesl"))])
    (cond [(file-exists? kebab-p)  (path->string kebab-p)]
          [(file-exists? pascal-p) (path->string pascal-p)]
          [else #f])))

(define (build-decl-table source-file text)
  (define table (make-hash))
  (parse-decls! table source-file text)
  (for ([line (in-list (string-split text "\n"))])
    (let ([m (regexp-match #rx"^import[ \t]+([A-Za-z][A-Za-z0-9.]*)" (string-trim line))])
      (when m
        (let ([mod (cadr m)])
          (unless (string-prefix? mod "Tesl.")
            (let ([imp-path (resolve-import-path source-file mod)])
              (when imp-path
                (with-handlers ([exn? void])
                  (let ([imp-text (file->string imp-path)])
                    (parse-decls! table imp-path imp-text))))))))))
  table)

(define (top-level-line? raw-line)
  (define trimmed (string-trim raw-line))
  (and (> (string-length raw-line) 0)
       (not (char-whitespace? (string-ref raw-line 0)))
       (not (string-prefix? trimmed "#"))))

(define (enclosing-top-level-start lines current-line)
  (let loop ([i (min current-line (- (length lines) 1))])
    (cond
      [(< i 0) 0]
      [(top-level-line? (list-ref lines i)) i]
      [else (loop (- i 1))])))

(define (find-typed-local-binding binding-types block-start current-line word)
  (for/fold ([best #f]) ([binding (in-list binding-types)])
    (define line (hash-ref binding 'line -1))
    (define name (hash-ref binding 'name ""))
    (define ty (hash-ref binding 'type #f))
    (if (and ty
             (equal? name word)
             (<= block-start line)
             (<= line current-line)
             (or (not best) (> line (hash-ref best 'line -1))))
        binding
        best)))

(define (find-local-binding-entry source-file text current-line word [binding-types '()])
  (define lines (string-split text "
"))
  (define typed-binding
    (and (not (null? binding-types))
         (let ([block-start (enclosing-top-level-start lines current-line)])
           (find-typed-local-binding binding-types block-start current-line word))))
  (cond
    [typed-binding
     (define note (hash-ref typed-binding 'note #f))
     (vector source-file
             (hash-ref typed-binding 'line -1)
             "local"
             (format "~a: ~a"
                     (hash-ref typed-binding 'name word)
                     (hash-ref typed-binding 'type "Unknown"))
             (if note (list note) '()))]
    [else
     (define candidate #f)
     (for ([raw-line (in-list lines)]
           [i        (in-naturals)]
           #:break (> i current-line))
       (when (top-level-line? raw-line)
         (set! candidate #f))
       (let ([entry (parse-local-let-line source-file raw-line i binding-types)])
         (when (and entry (equal? (car entry) word))
           (set! candidate (cdr entry)))))
     candidate]))

;; ── Text helpers ──────────────────────────────────────────────────────────────

(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (eqv? c #\_)))

(define (qualified-ident-char? c)
  ;; Like ident-char? but also includes '.' for qualified names like String.length
  (or (char-alphabetic? c) (char-numeric? c) (eqv? c #\_) (eqv? c #\.)))

(define (hyphenated-ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (eqv? c #\_) (eqv? c #\-)))

(define (word-at-pred lines line-num char-num pred?)
  (and (< line-num (length lines))
       (let* ([line (list-ref lines line-num)]
              [len  (string-length line)]
              [col  (min char-num (max 0 (- len 1)))])
         (let ([start (let lp ([i col])
                        (if (and (> i 0) (pred? (string-ref line (- i 1))))
                            (lp (- i 1))
                            i))])
           (let ([end (let lp ([i col])
                        (if (and (< i len) (pred? (string-ref line i)))
                            (lp (+ i 1))
                            i))])
             (if (> end start)
                 (substring line start end)
                 #f))))))

(define (word-at lines line-num char-num)
  (word-at-pred lines line-num char-num ident-char?))

(define (qualified-word-at lines line-num char-num)
  (word-at-pred lines line-num char-num qualified-ident-char?))

(define (hyphenated-word-at lines line-num char-num)
  (word-at-pred lines line-num char-num hyphenated-ident-char?))

;; ── Validation temp copies ────────────────────────────────────────────────────
;; To validate an unsaved buffer we write its text to a transient .tesl copy and
;; invoke a compiler query command on that copy. The copy goes in the SYSTEM temp
;; dir (not beside the document) so the project tree never gets stray files —
;; even on a crash, cleanup gap, or read-only/watched source dir.
;;
;; But local imports resolve relative to the source file's directory, so a copy
;; in the temp dir would no longer see its sibling modules. We bridge that with
;; the `TESL_LOGICAL_PATH` env var: the compiler reads the buffer text from the
;; temp copy but resolves imports (and reports location `file`s) as if the file
;; lived at this logical path — the document's true on-disk path. `current-logical-path`
;; carries that path; the run-* subprocess helpers set the env var from it.
(define current-logical-path (make-parameter #f))

(define (logical-path->string lp)
  (cond [(path? lp) (path->string lp)]
        [(string? lp) lp]
        [else #f]))

;; Spawn a compiler subprocess with `TESL_LOGICAL_PATH` set to the current
;; logical path (when one is in effect). Restores the environment afterward.
(define (with-logical-env thunk)
  (let ([lp (logical-path->string (current-logical-path))])
    (if lp
        (let ([env (environment-variables-copy (current-environment-variables))])
          (environment-variables-set! env #"TESL_LOGICAL_PATH" (string->bytes/utf-8 lp))
          (parameterize ([current-environment-variables env]) (thunk)))
        (thunk))))

;; Create a transient validation copy in the system temp dir (no document-dir arg).
(define (make-validation-tmp template)
  (make-temporary-file template))

;; Write `text` to a system-temp validation copy, run `proc` with the temp path
;; while `current-logical-path` is bound to `logical-path`, then delete the copy.
;; Returns `fallback` if there is no text/compiler.
(define (with-validation-tmp template text logical-path compiler proc [fallback #f])
  (if (and text compiler)
      (let ([tmp (make-validation-tmp template)])
        (dynamic-wind
          void
          (lambda ()
            (with-output-to-file tmp #:exists 'truncate (lambda () (display text)))
            (parameterize ([current-logical-path logical-path])
              (proc tmp)))
          (lambda () (when (file-exists? tmp) (delete-file tmp)))))
      fallback))

;; ── Diagnostics ──────────────────────────────────────────────────────────────

(define (diag->lsp d)
  (let* ([s (hash-ref d 'start (hash))]
         [e (hash-ref d 'end   (hash))])
    (hash 'range    (hash 'start (hash 'line      (hash-ref s 'line 0)
                                       'character (hash-ref s 'col  0))
                          'end   (hash 'line      (hash-ref e 'line 0)
                                       'character (hash-ref e 'col  0)))
          'severity (if (equal? (hash-ref d 'severity "error") "error") 1 2)
          'code     (hash-ref d 'code "E000")
          'source   "tesl"
          'message  (hash-ref d 'message "")
          'data     (let ([fix (hash-ref d 'fix 'null)])
                       (if (eq? fix 'null) (hash) (hash 'fix fix))))))

(define (run-check compiler file-path)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--check-json"
                            (path->string file-path))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "check json: ~a" (exn-message e))) '())])
        (map diag->lsp (hash-ref (read-json (open-input-string raw)) 'diagnostics '()))))))))

(define (run-local-bindings compiler file-path)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--local-bindings-json"
                            (path->string file-path))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "local bindings json: ~a" (exn-message e))) '())])
        (hash-ref (read-json (open-input-string raw)) 'bindings '())))))))

(define (run-definition compiler file-path line col)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--definition-json"
                            (path->string file-path)
                            (number->string line)
                            (number->string col))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "definition json: ~a" (exn-message e))) #f)])
        (let ([definition (hash-ref (read-json (open-input-string raw)) 'definition 'null)])
          (and (hash? definition) definition))))))))

(define (run-occurrences compiler file-path line col)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--occurrences-json"
                            (path->string file-path)
                            (number->string line)
                            (number->string col))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "occurrences json: ~a" (exn-message e))) '())])
        (hash-ref (read-json (open-input-string raw)) 'occurrences '())))))))

(define (run-semantic compiler file-path)
  ;; --semantic-json <file> → full typed module snapshot (or #f on parse error).
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--semantic-json"
                            (path->string file-path))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "semantic json: ~a" (exn-message e))) #f)])
        (let ([j (read-json (open-input-string raw))])
          (and (hash? j) j))))))))

(define (run-fmt compiler text source-path)
  ;; The CLI `--fmt` rewrites a file in place. Run it on a temp copy of the
  ;; current (possibly unsaved) buffer text and read the formatted result back.
  ;; Returns the formatted string, or #f if formatting failed (parse error etc.).
  (and text compiler
       (let ([tmp (make-validation-tmp "tesl-fmt-~a.tesl")])
         (dynamic-wind
           void
           (lambda ()
             (with-output-to-file tmp #:exists 'truncate (lambda () (display text)))
             (parameterize ([current-logical-path source-path])
             (with-logical-env (lambda ()
             (let-values ([(proc pout pin perr)
                           (subprocess #f #f #f
                                       (path->string compiler)
                                       "--fmt"
                                       (path->string tmp))])
               (close-output-port pin)
               (let* ([_  (port->string pout)]
                      [er (port->string perr)]
                      [_  (subprocess-wait proc)]
                      [code (subprocess-status proc)])
                 (if (zero? code)
                     (file->string tmp)
                     (begin (log (format "fmt failed: ~a" (string-trim er))) #f))))))))
           (lambda ()
             (when (file-exists? tmp) (delete-file tmp)))))))

(define (run-completions compiler file-path line col)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--completions-json"
                            (path->string file-path)
                            (number->string line)
                            (number->string col))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "completions json: ~a" (exn-message e))) '())])
        (hash-ref (read-json (open-input-string raw)) 'completions '())))))))

(define (run-type-at compiler file-path line col)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--type-at-json"
                            (path->string file-path)
                            (number->string line)
                            (number->string col))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "type-at json: ~a" (exn-message e))) #f)])
        (let ([type-at (hash-ref (read-json (open-input-string raw)) 'type_at 'null)])
          (and (hash? type-at) type-at))))))))

(define (run-field-at compiler file-path line col)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            "--field-at-json"
                            (path->string file-path)
                            (number->string line)
                            (number->string col))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "field-at json: ~a" (exn-message e))) #f)])
        (let ([field-at (hash-ref (read-json (open-input-string raw)) 'field_at 'null)])
          (and (hash? field-at) field-at))))))))

;; ── New positional compiler queries (Wave E2) ───────────────────────────────────
;; Generic helper: run the compiler with a positional JSON flag and return the
;; parsed top-level jsexpr, or `on-fail` when anything goes wrong. Mirrors the
;; one-off run-* helpers above; centralised so new flags stay one-liners.
(define (run-compiler-positional-json compiler flag file-path line col on-fail label)
  (with-logical-env (lambda ()
  (let-values ([(proc pout pin perr)
                (subprocess #f #f #f
                            (path->string compiler)
                            flag
                            (path->string file-path)
                            (number->string line)
                            (number->string col))])
    (close-output-port pin)
    (let* ([raw (port->string pout)]
           [_   (port->string perr)]
           [_   (subprocess-wait proc)])
      (with-handlers ([exn? (lambda (e) (log (format "~a json: ~a" label (exn-message e))) on-fail)])
        (read-json (open-input-string raw))))))))

(define (run-signature-help compiler file-path line col)
  ;; --signature-help-json → {signature:{label,parameters,active_parameter}|null}.
  ;; Returns the inner `signature` hash, or #f.
  (let ([j (run-compiler-positional-json compiler "--signature-help-json" file-path line col #f "signature-help")])
    (and (hash? j)
         (let ([sig (hash-ref j 'signature 'null)])
           (and (hash? sig) sig)))))

(define (run-selection-range compiler file-path line col)
  ;; --selection-range-json → {ranges:[{line,col,end_line,end_col},...]} innermost-first.
  ;; Returns the list of range hashes (possibly empty).
  (let ([j (run-compiler-positional-json compiler "--selection-range-json" file-path line col #f "selection-range")])
    (if (hash? j) (hash-ref j 'ranges '()) '())))

(define (run-type-definition compiler file-path line col)
  ;; --type-definition-json → {type_definition:{file,line,col,end_line,end_col}|null}.
  ;; Returns the inner location hash, or #f.
  (let ([j (run-compiler-positional-json compiler "--type-definition-json" file-path line col #f "type-definition")])
    (and (hash? j)
         (let ([td (hash-ref j 'type_definition 'null)])
           (and (hash? td) td)))))

(define (run-config-context compiler file-path line col)
  ;; --config-context-json → {config_context:{block,fields:[{name,type,doc,required,present}]}|null}.
  ;; Returns the inner context hash (with 'block and 'fields), or #f when the
  ;; cursor is not inside a configuration block.
  (let ([j (run-compiler-positional-json compiler "--config-context-json" file-path line col #f "config-context")])
    (and (hash? j)
         (let ([cc (hash-ref j 'config_context 'null)])
           (and (hash? cc) cc)))))

;; Find a config field hash by name within a config-context's field list.
(define (config-field-lookup cc name)
  (and cc
       (for/or ([f (in-list (hash-ref cc 'fields '()))])
         (and (hash? f) (equal? (hash-ref f 'name #f) name) f))))

;; Markdown hover for a config-block field: `field: Type` + doc + required note.
(define (config-field-hover-markdown block f)
  (let ([name (hash-ref f 'name "")]
        [type (hash-ref f 'type "")]
        [doc  (hash-ref f 'doc "")]
        [req  (hash-ref f 'required #f)])
    (string-append
     "```tesl\n" name ": " type "\n```\n\n"
     "*field of `" block "` block" (if req " — required" "") "*"
     (if (and (string? doc) (> (string-length doc) 0))
         (string-append "\n\n" doc) ""))))

;; LSP completion items for the not-yet-written fields of a config block.
;; `insertText` adds the `: ` so accepting a field lands the colon for free.
(define lsp-kind-field-config 5)
(define (config-field-completions cc)
  (if (not cc) '()
      (for/list ([f (in-list (hash-ref cc 'fields '()))]
                 #:when (and (hash? f) (not (hash-ref f 'present #f))))
        (let ([name (hash-ref f 'name "")]
              [type (hash-ref f 'type "")]
              [doc  (hash-ref f 'doc "")]
              [req  (hash-ref f 'required #f)])
          (hash 'label name
                'kind lsp-kind-field-config
                'detail (string-append ": " type (if req "  (required)" ""))
                'insertText (string-append name ": ")
                'insertTextFormat 1
                'sortText (string-append "0" name)
                'documentation (hash 'kind "markdown" 'value doc))))))

;; signature {label, parameters:[{label,type}], active_parameter} → LSP SignatureHelp.
;; Returns the SignatureHelp hash, or #f when there is no active signature.
(define (signature->signature-help sig)
  (and (hash? sig)
       (let* ([label  (hash-ref sig 'label "")]
              [params (hash-ref sig 'parameters '())]
              [active (hash-ref sig 'active_parameter 0)]
              [lsp-params
               (for/list ([p (in-list params)])
                 (let ([plabel (hash-ref p 'label "")]
                       [ptype  (hash-ref p 'type "")])
                   (hash 'label plabel
                         'documentation
                         (if (and (string? ptype) (> (string-length ptype) 0))
                             (hash 'kind "markdown" 'value (format "```tesl\n~a\n```" ptype))
                             'null))))])
         (hash 'signatures
               (list (hash 'label label
                           'parameters lsp-params
                           'activeParameter (if (integer? active) (max 0 active) 0)))
               'activeSignature 0
               'activeParameter (if (integer? active) (max 0 active) 0)))))

;; ranges:[{line,col,end_line,end_col},...] innermost-first → nested SelectionRange.
;; LSP SelectionRange is {range, parent?}; we chain each range as the parent of
;; the one before it (so the innermost is the head, widening outward).
(define (selection-ranges->lsp ranges)
  (define (range->lsp r)
    (hash 'start (hash 'line (hash-ref r 'line 0)
                       'character (hash-ref r 'col 0))
          'end   (hash 'line (hash-ref r 'end_line 0)
                       'character (hash-ref r 'end_col 0))))
  ;; Build from outermost (last) inward so each inner node points at its parent.
  (let loop ([rs (reverse ranges)] [parent #f])
    (if (null? rs)
        parent
        (let ([node (let ([base (hash 'range (range->lsp (car rs)))])
                      (if parent (hash-set base 'parent parent) base))])
          (loop (cdr rs) node)))))

;; ── Folding ranges (textDocument/foldingRange) ───────────────────────────────
;; Syntactic, text-driven: we fold (a) top-level declaration blocks — a decl line
;; at column 0 down to the line before the next column-0 decl/blank-run boundary,
;; (b) brace-delimited blocks `{ … }`, and (c) runs of ≥2 consecutive comment
;; lines. Each FoldingRange is {startLine,endLine,kind?}. 0-based lines.
(define decl-start-rx
  #px"^(fn|check|auth|handler|worker|deadWorker|establish|type|record|entity|capability|database|queue|channel|codec|server|main|fact|test|property|module|import|seed|api-test|load-test|dead-worker)\\b")

(define (blank-line? s) (regexp-match? #px"^[ \t]*$" s))
(define (comment-line? s) (regexp-match? #px"^[ \t]*#" s))

(define (folding-ranges lines)
  (define n (length lines))
  (define vec (list->vector lines))
  (define out '())
  (define (push! sl el [kind #f])
    (when (> el sl)
      (set! out (cons (let ([base (hash 'startLine sl 'endLine el)])
                        (if kind (hash-set base 'kind kind) base))
                      out))))
  ;; (a) top-level decl blocks: each column-0 decl extends to the line before the
  ;; next column-0 decl (trailing blank lines trimmed off the fold).
  (define decl-lines
    (for/list ([i (in-range n)]
               #:when (regexp-match? decl-start-rx (vector-ref vec i)))
      i))
  (let loop ([ds decl-lines])
    (when (pair? ds)
      (define start (car ds))
      (define next  (if (pair? (cdr ds)) (cadr ds) n))
      ;; trim trailing blanks before `next`
      (let trim ([end (sub1 next)])
        (cond
          [(<= end start) (void)]
          [(blank-line? (vector-ref vec end)) (trim (sub1 end))]
          [else (push! start end "region")]))
      (loop (cdr ds))))
  ;; (b) brace blocks: match each unmatched '{' to its closing '}' by depth.
  (let ([stack '()])
    (for ([i (in-range n)])
      (define ln (vector-ref vec i))
      (for ([ch (in-string ln)])
        (cond
          [(eqv? ch #\{) (set! stack (cons i stack))]
          [(eqv? ch #\}) (when (pair? stack)
                           (push! (car stack) i)
                           (set! stack (cdr stack)))]))))
  ;; (c) comment runs of length ≥2.
  (let loop ([i 0])
    (when (< i n)
      (if (comment-line? (vector-ref vec i))
          (let scan ([j (add1 i)])
            (if (and (< j n) (comment-line? (vector-ref vec j)))
                (scan (add1 j))
                (begin (push! i (sub1 j) "comment")
                       (loop j))))
          (loop (add1 i)))))
  (reverse out))

;; ── Compiler-backed hover ───────────────────────────────────────────────────────
;; Produce precise markdown from --field-at-json / --type-at-json. field-at wins
;; (it knows the field name + owning record), then type-at for any other
;; expression. Returns markdown string or #f.
(define (format-field-at-hover field-at)
  (let ([field (hash-ref field-at 'field #f)]
        [rty   (hash-ref field-at 'record_type #f)]
        [fty   (hash-ref field-at 'field_type #f)])
    (and field fty
         (string-append
          (format "```tesl\n~a: ~a\n```" field fty)
          (if rty (format "\n\n*field of `~a`*" rty) "")))))

(define (format-type-at-hover type-at)
  (let ([ty (hash-ref type-at 'type #f)])
    (and ty (string? ty) (> (string-length ty) 0)
         (format "```tesl\n~a\n```" ty))))

(define (compiler-hover-markdown compiler source-path text line col)
  (with-validation-tmp "tesl-hover-~a.tesl" text source-path compiler
    (lambda (tmp)
      (let ([field-at (run-field-at compiler tmp line col)])
        (or (and field-at (format-field-at-hover field-at))
            (let ([type-at (run-type-at compiler tmp line col)])
              (and type-at (format-type-at-hover type-at))))))))

;; ── Completion mapping ──────────────────────────────────────────────────────────
;; LSP CompletionItemKind numeric codes we use.
(define lsp-kind-field    5)
(define lsp-kind-function 3)
(define lsp-kind-variable 6)
(define lsp-kind-keyword  14)

(define (completion-kind->lsp kind)
  (cond
    [(equal? kind "field")    lsp-kind-field]
    [(equal? kind "function") lsp-kind-function]
    [else                     lsp-kind-variable]))

(define (completion-doc-markdown label detail)
  ;; Attach richer docs from stdlib-sigs when the label is a known stdlib name;
  ;; otherwise fall back to the compiler-supplied detail (type signature).
  (cond
    [(hash-ref stdlib-sigs label #f) => format-stdlib-hover]
    [(and detail (> (string-length detail) 0)) (format "```tesl\n~a\n```" detail)]
    [else #f]))

;; sortText groups: compiler-supplied identifiers/fields sort before keywords so
;; real bindings surface first. The leading digit is the bucket; the label keeps
;; alphabetical order within a bucket.
(define (completion-sort-text bucket label)
  (format "~a~a" bucket label))

(define (compiler-completion->lsp item)
  ;; item is a jsexpr hash from --completions-json: {label, detail, kind}
  (and (hash? item)
       (let ([label  (hash-ref item 'label #f)]
             [detail (hash-ref item 'detail "")]
             [kind   (hash-ref item 'kind "variable")])
         (and label
              (let ([doc (completion-doc-markdown label detail)])
                (hash 'label  label
                      'kind   (completion-kind->lsp kind)
                      'detail detail
                      ;; fields (after a dot) sort to the very top; other idents next.
                      'sortText (completion-sort-text
                                 (if (equal? kind "field") "0" "1") label)
                      ;; carry enough for completionItem/resolve to enrich lazily.
                      'data (hash 'label label 'detail detail 'kind kind)
                      'documentation (if doc
                                         (hash 'kind "markdown" 'value doc)
                                         'null)))))))

(define (keyword-completion->lsp pair)
  (let* ([label  (car pair)]
         [detail (cdr pair)]
         [doc    (keyword-doc-markdown label detail)]
         [snippet (hash-ref tesl-snippets label #f)]
         [base   (hash 'label  label
                       'kind   lsp-kind-keyword
                       'detail detail
                       ;; keywords sort after compiler identifiers.
                       'sortText (completion-sort-text "2" label)
                       'data (hash 'label label 'detail detail 'kind "keyword")
                       'documentation (hash 'kind "markdown" 'value doc))])
    (if snippet
        ;; Structural keyword → expand into a tabstop scaffold (InsertTextFormat=2).
        (hash-set* base
                   'insertText snippet
                   'insertTextFormat 2)
        base)))

;; completionItem/resolve: enrich a previously-returned item with detail and
;; documentation lazily, using the `data` payload we stashed at build time. The
;; client sends back the whole item; we fill any missing/`null` documentation.
(define (completion-item-resolve item)
  (and (hash? item)
       (let* ([data  (hash-ref item 'data (hash))]
              [label (or (and (hash? data) (hash-ref data 'label #f))
                         (hash-ref item 'label #f))]
              [detail (or (and (hash? data) (hash-ref data 'detail #f))
                          (hash-ref item 'detail ""))]
              [existing-doc (hash-ref item 'documentation 'null)]
              [doc (and label (completion-doc-markdown label (or detail "")))])
         (let* ([with-detail (if (and detail (> (string-length detail) 0))
                                 (hash-set item 'detail detail)
                                 item)])
           (if (and (or (eq? existing-doc 'null) (not existing-doc)) doc)
               (hash-set with-detail 'documentation (hash 'kind "markdown" 'value doc))
               with-detail)))))

;; Build the full completion list. After a `.` we return ONLY the compiler's
;; result (field completions for the inferred record type) — keywords would be
;; noise there. Otherwise we merge compiler identifiers with language keywords,
;; de-duplicating by label so a keyword does not shadow a real binding.
(define (build-completions compiler-items after-dot?)
  (define mapped (filter values (map compiler-completion->lsp compiler-items)))
  (if after-dot?
      mapped
      (let ([seen (make-hash)])
        (for ([item (in-list mapped)])
          (hash-set! seen (hash-ref item 'label) #t))
        (define kw-items
          (for/list ([pair (in-list (append tesl-keywords tesl-compound-keywords))]
                     #:unless (hash-has-key? seen (car pair)))
            (keyword-completion->lsp pair)))
        (append mapped kw-items))))

(define (location->lsp location [original-uri #f] [queried-path #f])
  (cond
    [(not (hash? location)) #f]
    [else
     (let* ([file (hash-ref location 'file #f)]
            [result-path (and file (string->path file))]
            [queried-path* (and queried-path (simplify-path queried-path))]
            [result-path* (and result-path (simplify-path result-path))]
            [uri (and result-path*
                      (if (and original-uri queried-path* (equal? result-path* queried-path*))
                          original-uri
                          (path->uri result-path*)))])
       (and uri
            (hash 'uri uri
                  'range
                  (hash 'start (hash 'line (hash-ref location 'line 0)
                                      'character (hash-ref location 'col 0))
                        'end   (hash 'line (hash-ref location 'end_line 0)
                                      'character (hash-ref location 'end_col 0))))))]))

(define (definition->lsp definition [original-uri #f] [queried-path #f])
  (location->lsp definition original-uri queried-path))

(define (occurrences->lsp occurrences [original-uri #f] [queried-path #f])
  (filter values (map (lambda (occurrence) (location->lsp occurrence original-uri queried-path)) occurrences)))

(define (occurrences->workspace-edit occurrences new-name [original-uri #f] [queried-path #f])
  (define changes (make-hash))
  (for ([location (in-list (occurrences->lsp occurrences original-uri queried-path))])
    (define uri (hash-ref location 'uri #f))
    (define range (hash-ref location 'range #f))
    (define key (and uri (uri->json-key uri)))
    (when (and key range)
      (hash-set! changes key
                 (append (hash-ref changes key '())
                         (list (hash 'range range
                                     'newText new-name))))))
  (and (> (hash-count changes) 0)
       (hash 'changes changes)))

;; ── prepareRename (textDocument/prepareRename) ───────────────────────────────
;; Decide whether the symbol under the caret is renameable, and if so, return the
;; precise identifier RANGE (so the editor's rename box pre-selects only the token
;; — e.g. just `somerecord`, never the trailing `.id`).  Returning `'null` makes
;; the client refuse to open the rename popup; this is how we reject stdlib types
;; (String), keywords (handler, requires) and the `:::` operator — for all of
;; those `--occurrences-json` yields no occurrences (they are not user symbols).
(define (position-in-range? line col range)
  (let* ([start (hash-ref range 'start (hash))]
         [end   (hash-ref range 'end (hash))]
         [sl (hash-ref start 'line 0)] [sc (hash-ref start 'character 0)]
         [el (hash-ref end   'line 0)] [ec (hash-ref end   'character 0)])
    (and (or (> line sl) (and (= line sl) (>= col sc)))
         (or (< line el) (and (= line el) (<= col ec))))))

(define (occurrences->prepare-rename occurrences line col)
  ;; Find the occurrence range that contains the caret; that token is exactly
  ;; what will be renamed. No occurrences (keyword / operator / stdlib type) ⇒
  ;; reject the rename.
  (let ([ranges (filter values
                        (map (lambda (occ)
                               (let ([loc (location->lsp occ)])
                                 (and loc (hash-ref loc 'range #f))))
                             occurrences))])
    (cond
      [(null? ranges) 'null]
      [else
       (let ([hit (findf (lambda (r) (position-in-range? line col r)) ranges)])
         (cond
           ;; Caret sits inside a known occurrence token: select that exact span.
           [hit (hash 'range hit)]
           ;; Renameable symbol, but caret not inside a recovered token span
           ;; (defensive): allow rename, let the client choose the word range.
           [else (hash 'range (car ranges))]))])))

;; ── Document symbols (textDocument/documentSymbol) ───────────────────────────
;; Built from the typed snapshot (--semantic-json). We return the flat
;; SymbolInformation[] form (uri + location), which every LSP client accepts and
;; which sidesteps needing nested selectionRange data the snapshot doesn't carry.

;; LSP SymbolKind numeric codes.
(define symkind-function    12)
(define symkind-struct      23)
(define symkind-enum        10)
(define symkind-enummember  22)
(define symkind-field        8)
(define symkind-constant    14)

(define (decl-kind->symbol-kind kind)
  (cond
    [(member kind '("fn" "handler" "worker" "check" "auth" "establish" "main")) symkind-function]
    [(equal? kind "const") symkind-constant]
    [else symkind-function]))

(define (loc-hash->lsp-range loc)
  ;; semantic-json `loc` carries 0-based start_line/start_col/end_line/end_col.
  (and (hash? loc)
       (hash 'start (hash 'line (hash-ref loc 'start_line 0)
                          'character (hash-ref loc 'start_col 0))
             'end   (hash 'line (hash-ref loc 'end_line 0)
                          'character (hash-ref loc 'end_col 0)))))

(define (sym-info uri name kind range [container #f])
  (let ([base (hash 'name name
                    'kind kind
                    'location (hash 'uri uri 'range range))])
    (if container (hash-set base 'containerName container) base)))

(define (semantic->document-symbols semantic uri)
  ;; Flatten functions, records (+fields), and ADTs (+constructors) into a
  ;; SymbolInformation list. Entries with no usable loc are skipped.
  (and (hash? semantic)
       (let ([syms '()])
         (define (push! s) (set! syms (cons s syms)))
         ;; functions / checks / handlers / workers / consts
         (for ([fn (in-list (hash-ref semantic 'functions '()))])
           (let ([r (loc-hash->lsp-range (hash-ref fn 'loc #f))])
             (when r
               (push! (sym-info uri (hash-ref fn 'name "?")
                                (decl-kind->symbol-kind (hash-ref fn 'kind "fn")) r)))))
         ;; records + their fields (records carry no loc in the snapshot, so we
         ;; only surface them when the document also lists them via functions —
         ;; here we emit the record name as a struct symbol with a zero range
         ;; only if no loc; clients tolerate a zero range).
         (for ([rec (in-list (hash-ref semantic 'records '()))])
           (let* ([rname (hash-ref rec 'name "?")]
                  [r (or (loc-hash->lsp-range (hash-ref rec 'loc #f))
                         (hash 'start (hash 'line 0 'character 0)
                               'end   (hash 'line 0 'character 0)))])
             (push! (sym-info uri rname symkind-struct r))
             (for ([f (in-list (hash-ref rec 'fields '()))])
               (push! (sym-info uri (hash-ref f 'name "?") symkind-field r rname)))))
         (for ([adt (in-list (hash-ref semantic 'adts '()))])
           (let* ([aname (hash-ref adt 'name "?")]
                  [r (or (loc-hash->lsp-range (hash-ref adt 'loc #f))
                         (hash 'start (hash 'line 0 'character 0)
                               'end   (hash 'line 0 'character 0)))])
             (push! (sym-info uri aname symkind-enum r))
             (for ([v (in-list (hash-ref adt 'variants '()))])
               (push! (sym-info uri (hash-ref v 'constructor "?") symkind-enummember r aname)))))
         (reverse syms))))

;; ── Semantic tokens (textDocument/semanticTokens/full) ───────────────────────
;; Token legend — order is the index space the protocol reports. Advertised in
;; the initialize capabilities. We deliberately keep types FEW and SHORT-RANGE:
;; the minimap-oversize bug came from a scope painting whole lines/files, so each
;; token here covers exactly the declared identifier span (never a full body).

(define semantic-token-types
  '("function" "type" "enum" "enumMember" "property" "variable"))
(define semantic-token-modifiers '("declaration"))

(define (token-type-index name)
  (let loop ([i 0] [ts semantic-token-types])
    (cond [(null? ts) 0]
          [(equal? (car ts) name) i]
          [else (loop (+ i 1) (cdr ts))])))

(define (decl-kind->token-type kind)
  (cond
    [(member kind '("fn" "handler" "worker" "check" "auth" "establish" "main" "const")) "function"]
    [else "function"]))

;; A raw token: (vector line start-col length type-index modifier-bits).
;; We clamp length so a token never spills past its own declaration name — the
;; root cause of the prior minimap-oversize artifact (a span that ran to EOF).
(define (mk-token line col length type-name)
  (vector line col (max 0 length) (token-type-index type-name) 1))

(define (name-length-on-line lines line col fallback)
  ;; Length of the identifier starting at (line,col); falls back when the source
  ;; line is unavailable. Guarantees the token never exceeds the identifier.
  (if (and (>= line 0) (< line (length lines)))
      (let* ([ln  (list-ref lines line)]
             [len (string-length ln)])
        (let loop ([i col])
          (if (and (< i len) (ident-char? (string-ref ln i)))
              (loop (+ i 1))
              (max 1 (- i col)))))
      fallback))

(define (semantic->raw-tokens semantic lines)
  ;; Produce single-identifier tokens from the snapshot. Each function/record/
  ;; adt/ctor/local gets ONE token over its NAME only.
  (and (hash? semantic)
       (let ([toks '()])
         (define (emit! line col len type) (set! toks (cons (mk-token line col len type) toks)))
         (for ([fn (in-list (hash-ref semantic 'functions '()))])
           (let ([loc  (hash-ref fn 'loc #f)]
                 [kind (hash-ref fn 'kind "fn")])
             ;; `main` is a KEYWORD, not a user-named function: its decl `name`
             ;; is literally "main", so name-col-in-line would anchor a "function"
             ;; token onto the `main` keyword and override its keyword color
             ;; (the "main is just yellow like a function" bug). Skip it and let
             ;; the TextMate grammar scope `main` as a declaration keyword.
             (when (and (hash? loc) (not (equal? kind "main")))
               (let* ([line (hash-ref loc 'start_line 0)]
                      ;; The decl loc starts at the keyword; the name follows it.
                      ;; Find the name's column from source for an exact span.
                      [nm   (hash-ref fn 'name "")]
                      [ncol (name-col-in-line lines line nm (hash-ref loc 'start_col 0))]
                      [len  (string-length nm)])
                 (emit! line ncol (max 1 len) (decl-kind->token-type kind))))))
         (for ([b (in-list (hash-ref semantic 'local_bindings '()))])
           ;; semantic-json bindings carry their span under `loc` (start_line/
           ;; start_col). IMPORTANT: that loc is the binding STATEMENT start — it
           ;; points at the `let` keyword for a `let x = …`, and at the leading
           ;; keyword of an effect statement (telemetry/initTelemetry/with/…) that
           ;; the checker binds to `_`. Trusting start_col paints a `variable`
           ;; token straight onto the keyword and steals its color (the
           ;; "let / first-letter-of-with-telemetry-initTelemetry loses keyword
           ;; color" bug). So: skip wildcard/anonymous `_` bindings, and re-anchor
           ;; named bindings to the NAME's column (like the decl path); if the name
           ;; isn't on the line, skip rather than risk painting a keyword.
           (let ([loc (hash-ref b 'loc #f)]
                 [nm  (hash-ref b 'name "")])
             (when (and (hash? loc)
                        (> (string-length nm) 0)
                        (not (string=? nm "_")))
               (let* ([line (hash-ref loc 'start_line 0)]
                      [ncol (name-col-in-line lines line nm -1)])
                 (when (>= ncol 0)
                   (let ([len (max 1 (min (string-length nm)
                                          (name-length-on-line lines line ncol (string-length nm))))])
                     (emit! line ncol len "variable")))))))
         ;; Sort by (line, col) — required for delta encoding.
         (sort (reverse toks)
               (lambda (a b)
                 (let ([la (vector-ref a 0)] [lb (vector-ref b 0)])
                   (if (= la lb)
                       (< (vector-ref a 1) (vector-ref b 1))
                       (< la lb))))))))

(define (name-col-in-line lines line name fallback)
  ;; Column of `name` on the given source line (0-based), used to anchor a decl
  ;; token to the identifier rather than the leading keyword. Falls back when not
  ;; found so the token still lands somewhere sane.
  (if (and (>= line 0) (< line (length lines)) (> (string-length name) 0))
      (let* ([ln (list-ref lines line)]
             [m  (regexp-match-positions
                  (pregexp (string-append "\\b" (regexp-quote name) "\\b")) ln)])
        (if m (caar m) fallback))
      fallback))

(define (raw-tokens->data tokens)
  ;; Delta-encode per the LSP semanticTokens spec:
  ;;   [deltaLine, deltaStartChar, length, tokenType, tokenModifiers] × N
  (let loop ([ts tokens] [pl 0] [pc 0] [acc '()])
    (if (null? ts)
        (reverse acc)
        (let* ([t  (car ts)]
               [ln (vector-ref t 0)]
               [cl (vector-ref t 1)]
               [dl (- ln pl)]
               [dc (if (= dl 0) (- cl pc) cl)])
          (loop (cdr ts) ln cl
                (cons (vector-ref t 4)
                      (cons (vector-ref t 3)
                            (cons (vector-ref t 2)
                                  (cons dc (cons dl acc))))))))))

;; semanticTokens/full/delta: compute a single SemanticTokensEdit that turns the
;; previous `old-data` int list into `new-data`. We find the common prefix and
;; suffix and replace the differing middle — a correct, minimal-enough edit per
;; the LSP spec ({start, deleteCount, data}). Returns a list of zero or one edit.
(define (semantic-tokens-delta old-data new-data)
  (define ov (list->vector old-data))
  (define nv (list->vector new-data))
  (define olen (vector-length ov))
  (define nlen (vector-length nv))
  ;; common prefix length
  (define pre
    (let loop ([i 0])
      (if (and (< i olen) (< i nlen) (= (vector-ref ov i) (vector-ref nv i)))
          (loop (add1 i)) i)))
  ;; common suffix length (not overlapping the prefix)
  (define suf
    (let loop ([k 0])
      (if (and (< (+ pre k) olen) (< (+ pre k) nlen)
               (= (vector-ref ov (- olen 1 k)) (vector-ref nv (- nlen 1 k))))
          (loop (add1 k)) k)))
  (define del-count (- olen pre suf))
  (define mid (for/list ([i (in-range pre (- nlen suf))]) (vector-ref nv i)))
  (if (and (= del-count 0) (null? mid))
      '()  ; identical → no edits
      (list (hash 'start pre 'deleteCount del-count 'data mid))))

;; ── Formatting edits ─────────────────────────────────────────────────────────
;; Build a single TextEdit that replaces the WHOLE document `text` with
;; `formatted`. The end position uses one-past-the-last line at character 0,
;; which spans any document length without scanning. Returns '() when there is
;; nothing to change. Shared by full + range formatting (the compiler only
;; formats whole files; the requested range is advisory, which every client
;; tolerates — a partial reflow would risk producing invalid intermediate text).
(define (whole-document-edits text formatted)
  (if (and formatted text (not (equal? formatted text)))
      (let ([lines (string-split text "\n" #:trim? #f)])
        (list (hash 'range (hash 'start (hash 'line 0 'character 0)
                                 'end   (hash 'line (max 0 (length lines))
                                              'character 0))
                    'newText formatted)))
      '()))

;; onType formatting after a newline: a light, conservative reindent of the line
;; just opened. We do NOT reflow — we only strip trailing whitespace that the
;; editor may have carried over onto the fresh (now-empty) line, which avoids the
;; jitter of a full reformat on every keystroke. Returns '() unless the current
;; line is whitespace-only with trailing spaces to trim. `lines` is 0-based.
(define (on-type-edits lines line-num)
  (if (and (>= line-num 0) (< line-num (length lines)))
      (let ([ln (list-ref lines line-num)])
        (if (and (regexp-match? #px"^[ \t]+$" ln))
            ;; whitespace-only line → collapse to empty (drop stray trailing ws)
            (list (hash 'range (hash 'start (hash 'line line-num 'character 0)
                                     'end   (hash 'line line-num 'character (string-length ln)))
                        'newText ""))
            '()))
      '()))

;; ── Document links (textDocument/documentLink) ───────────────────────────────
;; URLs appearing in comments become clickable links. We deliberately do NOT
;; turn `import Foo.Bar` module paths into file links: cross-file/project-wide
;; resolution is IR-1-blocked, so a module→file mapping would be a guess. URLs
;; are self-contained and safe. Returns a list of DocumentLink {range, target}.
(define url-rx #px"https?://[^\\s)<>\"']+")

(define (document-links lines)
  (define out '())
  (for ([i (in-range (length lines))])
    (define ln (list-ref lines i))
    (for ([m (in-list (regexp-match-positions* url-rx ln))])
      (let* ([s (car m)] [e (cdr m)]
             [target (substring ln s e)])
        (set! out (cons (hash 'range (hash 'start (hash 'line i 'character s)
                                           'end   (hash 'line i 'character e))
                              'target target)
                        out)))))
  (reverse out))

;; ── Linked editing (textDocument/linkedEditingRange) ─────────────────────────
;; Same-name identifier occurrences within the current top-level block become a
;; linked-editing group, so renaming one live-edits the rest. We reuse the same
;; word scan the rest of the server uses and confine matches to the enclosing
;; block (column-0 decl boundaries) to avoid cross-scope bleed. `lines` 0-based.
(define (block-bounds lines line-num)
  ;; Returns (values start-line end-line-exclusive) of the column-0 decl block
  ;; containing line-num. A block starts at a column-0 non-blank/non-comment line
  ;; and ends at the next such line.
  (define n (length lines))
  (define (boundary? i)
    (let ([s (list-ref lines i)])
      (and (> (string-length s) 0)
           (not (char-whitespace? (string-ref s 0)))
           (not (eqv? (string-ref s 0) #\#)))))
  (define start
    (let loop ([i (min line-num (max 0 (sub1 n)))])
      (cond [(< i 0) 0]
            [(boundary? i) i]
            [else (loop (sub1 i))])))
  (define end
    (let loop ([i (add1 start)])
      (cond [(>= i n) n]
            [(boundary? i) i]
            [else (loop (add1 i))])))
  (values start end))

(define (linked-editing-ranges lines line-num char-num word-at-proc)
  ;; word-at-proc: (lines line char) → identifier string or #f.
  (define word (word-at-proc lines line-num char-num))
  (and word (> (string-length word) 0)
       (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_]*$" word)
       (let-values ([(bstart bend) (block-bounds lines line-num)])
         (define rx (pregexp (string-append "\\b" (regexp-quote word) "\\b")))
         (define ranges
           (for*/list ([i (in-range bstart bend)]
                       [m (in-list (regexp-match-positions* rx (list-ref lines i)))])
             (hash 'start (hash 'line i 'character (car m))
                   'end   (hash 'line i 'character (cdr m)))))
         (and (>= (length ranges) 2)
              (hash 'ranges ranges)))))

;; ── Pull diagnostics (textDocument/diagnostic) ───────────────────────────────
;; Full-document report with a resultId = content hash. When the client passes
;; back its previousResultId and the content is unchanged, we return an
;; 'unchanged report instead of recomputing/resending.
(define (content-result-id text)
  (sha1 (open-input-string (or text ""))))

(define (diagnostic-report diags result-id)
  (hash 'kind "full" 'resultId result-id 'items diags))

(define (unchanged-report result-id)
  (hash 'kind "unchanged" 'resultId result-id))

;; ── Inlay hints (textDocument/inlayHint) ─────────────────────────────────────
;; Inferred `let` types from --local-bindings-json. We only hint bindings that
;; are written `let <name> = …` WITHOUT an explicit `: Type` annotation, and we
;; skip parameters (which live inside `(…)` on a decl line). Parameter-name hints
;; are not derivable from the frozen flags, so they are intentionally omitted.

(define inferred-let-rx #px"^[ \t]*let[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=")

(define (inferred-let-hint lines binding)
  ;; Returns an LSP InlayHint or #f.
  (define line (hash-ref binding 'line -1))
  (define name (hash-ref binding 'name ""))
  (define ty   (hash-ref binding 'type #f))
  (and ty (string? ty) (> (string-length ty) 0)
       (>= line 0) (< line (length lines))
       (let* ([ln (list-ref lines line)]
              [m  (regexp-match-positions inferred-let-rx ln)])
         (and m
              ;; confirm this is the binding's own `let name =` (name matches)
              (let ([nm-pos (cadr m)])
                (and (equal? (substring ln (car nm-pos) (cdr nm-pos)) name)
                     ;; no explicit annotation: there's no ':' between name and '='
                     (let ([after-name (substring ln (cdr nm-pos))])
                       (not (regexp-match? #px"^[ \t]*:" after-name)))
                     ;; place the hint immediately after the binding name
                     (hash 'position (hash 'line line 'character (cdr nm-pos))
                           'label (format ": ~a" ty)
                           'kind 1            ; Type
                           'paddingLeft #f
                           'paddingRight #f)))))))

(define (bindings->inlay-hints bindings lines)
  (filter values (map (lambda (b) (inferred-let-hint lines b)) bindings)))

;; ── Document highlight (textDocument/documentHighlight) ──────────────────────
;; Same-file occurrence ranges from --occurrences-json. DocumentHighlight[] is
;; {range, kind}. Each occurrence now carries a `kind` ∈ {"write","read","text"}
;; which we map to DocumentHighlightKind: Text=1, Read=2, Write=3.
(define (highlight-kind->lsp kind)
  (cond
    [(equal? kind "write") 3]
    [(equal? kind "read")  2]
    [else                  1]))   ; "text" / missing → Text

(define (occurrences->document-highlights occurrences)
  (filter values
          (map (lambda (occ)
                 (let ([r (loc-hash->lsp-range
                           (hash 'start_line (hash-ref occ 'line 0)
                                 'start_col  (hash-ref occ 'col 0)
                                 'end_line   (hash-ref occ 'end_line 0)
                                 'end_col    (hash-ref occ 'end_col 0)))])
                   (and r (hash 'range r
                                'kind (highlight-kind->lsp (hash-ref occ 'kind "text"))))))
               occurrences)))

(define (publish-diags! out uri diags)
  (log (format "~a diagnostic(s)" (length diags)))
  (write-message out (hash 'jsonrpc "2.0"
                           'method  "textDocument/publishDiagnostics"
                           'params  (hash 'uri uri 'diagnostics diags))))

(define (check-text! out uri disk-path text compiler)
  (cond
    [(not compiler)
     (hash-set! local-bindings-cache uri '())
     (log "no compiler")]
    [else
     (with-validation-tmp "tesl-lsp-~a.tesl" text disk-path compiler
       (lambda (tmp)
         (let ([diags    (run-check compiler tmp)]
               [bindings (run-local-bindings compiler tmp)])
           (hash-set! local-bindings-cache uri bindings)
           (publish-diags! out uri diags))))]))

(define (check-disk! out uri disk-path compiler)
  (cond
    [(not compiler)
     (hash-set! local-bindings-cache uri '())
     (log "no compiler")]
    [(not (file-exists? disk-path))
     (hash-set! local-bindings-cache uri '())
     (log (format "not found: ~a" disk-path))]
    [else
     (hash-set! local-bindings-cache uri (run-local-bindings compiler disk-path))
     (publish-diags! out uri (run-check compiler disk-path))]))

;; ── URI / path ────────────────────────────────────────────────────────────────

(define (uri->path uri)
  (string->path
   (regexp-replace* #rx"%([0-9A-Fa-f]{2})"
                    (regexp-replace #rx"^file://" uri "")
                    (lambda (_ h) (string (integer->char (string->number h 16)))))))

(define (path->uri p)
  (string-append "file://" (if (path? p) (path->string (simplify-path p)) p)))

(define (uri->json-key uri)
  (string->symbol uri))

;; Run `proc` with a temp file holding the current (possibly unsaved) buffer
;; `text`, written to the SYSTEM temp dir. `current-logical-path` is bound to
;; `source-path` so the run-* helpers tell the compiler to resolve imports (and
;; report location `file`s) as if the copy lived at `source-path`. `proc` takes
;; the temp path and returns whatever; the file is always cleaned up. Returns
;; `fallback` when there is no text/compiler. Centralises the repeated
;; make-temporary-file / dynamic-wind idiom used by positional queries.
(define (with-text-tmp text source-path compiler proc [fallback #f])
  (with-validation-tmp "tesl-lsp-q-~a.tesl" text source-path compiler proc fallback))

;; ── Incremental document sync ────────────────────────────────────────────────
;; Convert an LSP {line,character} position into a 0-based string offset within
;; `text`, counting "\n" as one char (LSP UTF-16 caveat ignored: Tesl source is
;; ASCII-dominant and the compiler re-derives spans, so a byte≈char offset is
;; safe here). Lines/chars past the end clamp to the text length.
(define (lsp-position->offset text line character)
  (define len (string-length text))
  (let loop ([i 0] [ln 0])
    (cond
      [(= ln line)
       (min len (+ i (max 0 character)))]
      [(>= i len) len]
      [(eqv? (string-ref text i) #\newline) (loop (add1 i) (add1 ln))]
      [else (loop (add1 i) ln)])))

;; Apply a single LSP contentChange to `text`. A change with a `range` replaces
;; that span with its `text`; a change with no range (whole-document) replaces
;; everything. Returns the new text. Robust to out-of-order/invalid ranges.
(define (apply-content-change text change)
  (cond
    [(not (hash? change)) text]
    [(not (hash-has-key? change 'range))
     (hash-ref change 'text text)]   ; whole-document replacement
    [else
     (let* ([rng   (hash-ref change 'range (hash))]
            [start (hash-ref rng 'start (hash))]
            [end   (hash-ref rng 'end (hash))]
            [so    (lsp-position->offset text (hash-ref start 'line 0) (hash-ref start 'character 0))]
            [eo    (lsp-position->offset text (hash-ref end 'line 0) (hash-ref end 'character 0))]
            [lo    (min so eo)]
            [hi    (max so eo)]
            [new   (hash-ref change 'text "")])
       (string-append (substring text 0 lo) new (substring text hi)))]))

(define (apply-content-changes text changes)
  (for/fold ([t text]) ([c (in-list changes)])
    (apply-content-change t c)))

;; ── Document store ────────────────────────────────────────────────────────────

(define docs (make-hash))   ; uri → text
(define local-bindings-cache (make-hash)) ; uri → binding json list

;; Wave E2 server state. `client-caps` records what the client advertised so we
;; only send refresh requests it supports. `semtok-cache` maps uri → (cons
;; resultId data) for semanticTokens delta. `diag-cache` maps uri → (cons
;; content-hash resultId) for pull-diagnostics 'unchanged. `server-request-id`
;; is a fresh-id counter for server→client requests (applyEdit / refresh).
(define client-caps (hash))
(define semtok-cache (make-hash))
(define diag-cache (make-hash))
(define server-request-id 0)
(define (next-server-id!)
  (set! server-request-id (add1 server-request-id))
  (format "tesl-srv-~a" server-request-id))

;; Does the client advertise a given nested capability path? `path` is a list of
;; symbols drilling into client-caps; returns #t only when the leaf is truthy.
(define (client-supports? . path)
  (let loop ([h client-caps] [p path])
    (cond
      [(null? p) (and h (not (eq? h 'null)) #t)]
      [(hash? h) (loop (hash-ref h (car p) #f) (cdr p))]
      [else #f])))

;; Extract the single TextEdit a diagnostic's `fix` implies (replace_line), or #f.
(define (diag->fix-edit text diag)
  (define data (hash-ref diag 'data (hash)))
  (define fix (if (hash? data) (hash-ref data 'fix 'null) 'null))
  (and (hash? fix)
       (equal? (hash-ref fix 'kind #f) "replace_line")
       (let* ([line (hash-ref fix 'line 0)]
              [replacement (hash-ref fix 'replacement "")]
              [lines (if text (string-split text "\n") '())]
              [current-line (if (and (>= line 0) (< line (length lines)))
                                (list-ref lines line) "")])
         (hash 'range (hash 'start (hash 'line line 'character 0)
                            'end   (hash 'line line 'character (string-length current-line)))
               'newText replacement))))

;; Is this diagnostic an import-related fix (its message offers an `import …`)?
;; Used to pull the relevant edits into a `source.organizeImports` action.
(define (import-fix? diag)
  (let ([msg (hash-ref diag 'message "")])
    (and (string? msg)
         (regexp-match? #px"(?i:\\bimport\\b)" msg))))

(define (diag->code-action uri text diag)
  (let ([edit (diag->fix-edit text diag)])
    (and edit
         (hash 'title (format "Apply fix for ~a" (hash-ref diag 'code "diagnostic"))
               'kind "quickfix"
               'diagnostics (list diag)
               'edit (hash 'changes (hash (uri->json-key uri) (list edit)))))))

;; Build the full code-action set for a request: the per-diagnostic quickfixes,
;; plus aggregate `source.fixAll` (every fixable edit) and
;; `source.organizeImports` (only import-offering fixes). `only` is the client's
;; requested CodeActionKind filter (a list or '()); we honour it when present.
(define (code-actions uri text diagnostics only)
  (define wanted?
    (if (and (list? only) (pair? only))
        (lambda (kind)
          (for/or ([k (in-list only)])
            (and (string? k) (string-prefix? kind k))))
        (lambda (_kind) #t)))
  (define quickfixes (filter values (map (lambda (d) (diag->code-action uri text d)) diagnostics)))
  (define all-edits (filter values (map (lambda (d) (diag->fix-edit text d)) diagnostics)))
  (define import-edits
    (filter values (map (lambda (d) (and (import-fix? d) (diag->fix-edit text d))) diagnostics)))
  (define (aggregate title kind edits diags)
    (and (pair? edits)
         (hash 'title title
               'kind kind
               'diagnostics diags
               'edit (hash 'changes (hash (uri->json-key uri) edits)))))
  (append
   (if (wanted? "quickfix") quickfixes '())
   (filter values
           (list
            (and (wanted? "source.fixAll")
                 (aggregate "Fix all auto-fixable problems" "source.fixAll"
                            all-edits diagnostics))
            (and (wanted? "source.organizeImports")
                 (aggregate "Organize imports" "source.organizeImports"
                            import-edits (filter import-fix? diagnostics)))))))

;; Compute the delta-encoded semantic-tokens int list for the buffer `text`.
;; Returns '() when there is no text/compiler. Shared by full / delta / range.
(define (compute-semtok-data text source-path compiler)
  (let* ([lines (if text (string-split text "\n" #:trim? #f) '())]
         [tokens (with-text-tmp text source-path compiler
                   (lambda (tmp) (semantic->raw-tokens (run-semantic compiler tmp) lines)))])
    (raw-tokens->data (or tokens '()))))

;; Ask the client to refresh derived data after server-side state changes. Each
;; request is gated on the matching client capability so we never send a request
;; the client cannot handle. These are server→client requests (fresh ids).
(define (request-refresh! out)
  (define (send! method)
    (write-message out (hash 'jsonrpc "2.0" 'id (next-server-id!)
                             'method method 'params (hash))))
  (when (client-supports? 'workspace 'semanticTokens 'refreshSupport)
    (send! "workspace/semanticTokens/refresh"))
  (when (client-supports? 'workspace 'inlayHint 'refreshSupport)
    (send! "workspace/inlayHint/refresh"))
  (when (client-supports? 'workspace 'diagnostics 'refreshSupport)
    (send! "workspace/diagnostic/refresh")))

;; Run `thunk` (which computes a result jsexpr) and write it as the response for
;; `id`; if anything raises, log it and reply with `benign` instead so a single
;; bad request never crashes the loop. New Wave-E2 handlers funnel through this.
(define (respond-safely out id benign thunk)
  (write-message out
    (hash 'jsonrpc "2.0" 'id id
          'result
          (with-handlers ([exn? (lambda (e)
                                  (log (format "handler error: ~a" (exn-message e)))
                                  benign)])
            (thunk)))))

;; ── Main loop ─────────────────────────────────────────────────────────────────

(define (run)
  (define in       (current-input-port))
  (define out      (current-output-port))
  (define compiler (find-compiler))
  (define shutdown #f)

  (log (if compiler (format "compiler: ~a" compiler) "WARNING: no compiler"))

  (let loop ()
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (log (format "error: ~a" (exn-message e)))
            (unless shutdown (loop)))])
      (let* ([msg    (read-message in)]
             [method (hash-ref msg 'method #f)]
             [id     (hash-ref msg 'id #f)]
             [params (hash-ref msg 'params (hash))])

        (log (format "← ~a" method))

        (cond

          ;; ── Client responses to our server→client requests (applyEdit /
          ;; refresh): these carry an `id` but no `method`. Acknowledge silently
          ;; — never reply, or we'd answer the client's own reply. ──────────────
          [(not method) (loop)]

          ;; ── Lifecycle ──────────────────────────────────────────────────────

          [(equal? method "initialize")
           (write-message out
             (hash 'jsonrpc "2.0" 'id id
                   'result (hash 'capabilities
                             (hash ;; change=2 → Incremental: we apply ranged edits to the buffer.
                                   'textDocumentSync  (hash 'openClose #t 'change 2 'save #t)
                                   'hoverProvider      #t
                                   'definitionProvider #t
                                   'declarationProvider #t
                                   'typeDefinitionProvider #t
                                   'referencesProvider #t
                                   'renameProvider     (hash 'prepareProvider #t)
                                   'documentSymbolProvider #t
                                   'documentHighlightProvider #t
                                   'inlayHintProvider  (hash 'resolveProvider #t)
                                   'documentFormattingProvider #t
                                   'documentRangeFormattingProvider #t
                                   'documentOnTypeFormattingProvider
                                   (hash 'firstTriggerCharacter "\n")
                                   'foldingRangeProvider #t
                                   'selectionRangeProvider #t
                                   'documentLinkProvider (hash 'resolveProvider #f)
                                   'linkedEditingRangeProvider #t
                                   'diagnosticProvider
                                   (hash 'interFileDependencies #f
                                         'workspaceDiagnostics #f)
                                   'signatureHelpProvider
                                   (hash 'triggerCharacters (list "(" ",")
                                         'retriggerCharacters (list ","))
                                   'codeActionProvider
                                   (hash 'codeActionKinds
                                         (list "quickfix" "source.fixAll" "source.organizeImports"))
                                   'executeCommandProvider
                                   (hash 'commands (list "tesl.applyFix" "tesl.organizeImports"))
                                   'semanticTokensProvider
                                   (hash 'legend (hash 'tokenTypes semantic-token-types
                                                       'tokenModifiers semantic-token-modifiers)
                                         'full (hash 'delta #t)
                                         'range #t)
                                   'completionProvider
                                   (hash 'triggerCharacters (list "." "(" ",")
                                         'resolveProvider #t)))))
           (set! client-caps (hash-ref params 'capabilities (hash)))
           (loop)]

          [(equal? method "initialized") (loop)]

          ;; ── Document sync ─────────────────────────────────────────────────

          [(equal? method "textDocument/didOpen")
           (let* ([doc  (hash-ref params 'textDocument (hash))]
                  [uri  (hash-ref doc 'uri "")]
                  [text (hash-ref doc 'text "")]
                  [path (uri->path uri)])
             (hash-set! docs uri text)
             (check-text! out uri path text compiler))
           (loop)]

          [(equal? method "textDocument/didChange")
           ;; change=2 (Incremental): each contentChange may carry a `range`.
           ;; Apply them in order to the cached buffer. Whole-document changes
           ;; (no range) replace everything — so this also handles a Full client.
           (let* ([doc     (hash-ref params 'textDocument (hash))]
                  [uri     (hash-ref doc 'uri "")]
                  [path    (uri->path uri)]
                  [changes (hash-ref params 'contentChanges '())]
                  [prev    (hash-ref docs uri "")]
                  [text    (and (pair? changes) (apply-content-changes prev changes))])
             (when text (hash-set! docs uri text))
             (if text
                 (check-text! out uri path text compiler)
                 (check-disk! out uri path       compiler)))
           (loop)]

          [(equal? method "textDocument/didSave")
           (let* ([doc  (hash-ref params 'textDocument (hash))]
                  [uri  (hash-ref doc 'uri "")]
                  [path (uri->path uri)])
             (check-disk! out uri path compiler))
           (loop)]

          [(equal? method "textDocument/didClose")
           (let ([uri (hash-ref (hash-ref params 'textDocument (hash)) 'uri "")])
             (hash-remove! docs uri)
             (hash-remove! local-bindings-cache uri)
             (write-message out (hash 'jsonrpc "2.0"
                                      'method "textDocument/publishDiagnostics"
                                      'params (hash 'uri uri 'diagnostics '()))))
           (loop)]

          ;; ── Hover ─────────────────────────────────────────────────────────

          [(equal? method "textDocument/hover")
           (let* ([doc       (hash-ref params 'textDocument (hash))]
                  [uri       (hash-ref doc 'uri "")]
                  [pos       (hash-ref params 'position (hash))]
                  [line-num  (hash-ref pos 'line 0)]
                  [char-num  (hash-ref pos 'character 0)]
                  [text      (hash-ref docs uri #f)]
                  [lines     (if text (string-split text "\n") '())]
                  ;; plain word (no dots) — for decl table lookup
                  [word      (and text (word-at lines line-num char-num))]
                  ;; qualified word (with dots) — for stdlib lookup (e.g. String.length)
                  [qualified (and text (qualified-word-at lines line-num char-num))]
                  ;; hyphenated word for compound keywords (api-test, load-test)
                  [hyphenated (and text (hyphenated-word-at lines line-num char-num))])
             (log (format "hover: word=~a qualified=~a" word qualified))
             (let* ([source-file (path->string (uri->path uri))]
                    [table  (if word
                              (build-decl-table source-file text)
                              (hash))]
                    [binding-types (hash-ref local-bindings-cache uri '())]
                    ;; Priority 1: local let in the current top-level block, then local/imported declarations.
                    [entry  (or (and word text (find-local-binding-entry source-file text line-num word binding-types))
                                (and word (hash-ref table word #f)))]
                    ;; Priority 2: qualified stdlib (handles String.length, generatePrefixedId, etc.)
                    [stdlib (and (not entry)
                                 (or (and qualified (hash-ref stdlib-sigs qualified #f))
                                     (and hyphenated (hash-ref stdlib-sigs hyphenated #f))))]
                    ;; Priority 3: proof-predicate owner (e.g. hover on "ValidPort" →
                    ;;   finds "check isValidPort ... -> ... ValidPort ...")
                    [owner  (and (not entry) (not stdlib) word
                                 (find-proof-owner table word))]
                    ;; Priority 4: configuration-block field (database/postgres/
                    ;;   queue/retry/channel/cache/email/smtp). When the cursor is
                    ;;   inside a config block and the word is one of its schema
                    ;;   fields, show the field's type + doc from Config_schema.
                    [cfg-cc (and word text (not entry) (not stdlib) (not owner)
                                 (with-text-tmp text (uri->path uri) compiler
                                   (lambda (tmp) (run-config-context compiler tmp line-num char-num))))]
                    [cfg-field (and cfg-cc (config-field-lookup cfg-cc word))]
                    ;; Priority 5: ask the compiler for the precise inferred type
                    ;;   (record field access via --field-at-json, otherwise the
                    ;;   expression type via --type-at-json). Covers expressions the
                    ;;   text-based heuristics above cannot resolve.
                    [compiler-md (and (not entry) (not stdlib) (not owner) (not cfg-field) text
                                      (compiler-hover-markdown compiler (uri->path uri) text line-num char-num))]
                    [result
                     (cond
                       [entry  (hash 'contents
                                     (hash 'kind  "markdown"
                                           'value (format-hover-entry entry)))]
                       [stdlib (hash 'contents
                                     (hash 'kind  "markdown"
                                           'value (format-stdlib-hover stdlib)))]
                       [owner  (hash 'contents
                                     (hash 'kind  "markdown"
                                           'value (let* ([kw   (vector-ref owner 2)]
                                                         [sig  (vector-ref owner 3)]
                                                         [m    (regexp-match #rx"^[a-z]+[ \t]+([A-Za-z_][A-Za-z0-9_]*)" sig)]
                                                         [fname (if m (cadr m) "?")]
                                                         [note  (format "*Fact predicate declared by `~a ~a`*" kw fname)])
                                                    (format-hover-entry owner note))))]
                       [cfg-field (hash 'contents
                                        (hash 'kind  "markdown"
                                              'value (config-field-hover-markdown
                                                      (hash-ref cfg-cc 'block "") cfg-field)))]
                       [compiler-md (hash 'contents
                                          (hash 'kind  "markdown"
                                                'value compiler-md))]
                       [else   #f])])
               (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result 'null)))))
           (loop)]

          ;; ── Completion ─────────────────────────────────────────────────────

          [(equal? method "textDocument/completion")
           (let* ([doc      (hash-ref params 'textDocument (hash))]
                  [uri      (hash-ref doc 'uri "")]
                  [pos      (hash-ref params 'position (hash))]
                  [line-num (hash-ref pos 'line 0)]
                  [char-num (hash-ref pos 'character 0)]
                  [text     (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [lines    (if text (string-split text "\n") '())]
                  ;; After-dot detection: char immediately before the cursor is '.'.
                  [after-dot?
                   (and (< line-num (length lines))
                        (let* ([ln  (list-ref lines line-num)]
                               [idx (- char-num 1)])
                          (and (>= idx 0) (< idx (string-length ln))
                               (eqv? (string-ref ln idx) #\.))))]
                  [compiler-items
                   (with-validation-tmp "tesl-completion-~a.tesl" text source-path compiler
                     (lambda (tmp)
                       (run-completions compiler tmp line-num char-num)))]
                  ;; Inside a config block (and not after a dot): offer the
                  ;; block's not-yet-written schema fields, ranked first.
                  [cfg-cc (and text (not after-dot?)
                               (with-text-tmp text source-path compiler
                                 (lambda (tmp) (run-config-context compiler tmp line-num char-num))))]
                  [items (append (config-field-completions cfg-cc)
                                 (build-completions (or compiler-items '()) after-dot?))])
             (write-message out (hash 'jsonrpc "2.0" 'id id
                                      'result (hash 'isIncomplete #f
                                                    'items items))))
           (loop)]

          ;; ── Completion item resolve (lazy detail/documentation) ───────────
          [(equal? method "completionItem/resolve")
           (respond-safely out id params
             (lambda () (or (completion-item-resolve params) params)))
           (loop)]

          ;; ── Signature help ────────────────────────────────────────────────
          [(equal? method "textDocument/signatureHelp")
           (respond-safely out id 'null
             (lambda ()
               (let* ([doc      (hash-ref params 'textDocument (hash))]
                      [uri      (hash-ref doc 'uri "")]
                      [pos      (hash-ref params 'position (hash))]
                      [line-num (hash-ref pos 'line 0)]
                      [char-num (hash-ref pos 'character 0)]
                      [text     (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [sig (with-text-tmp text source-path compiler
                             (lambda (tmp) (run-signature-help compiler tmp line-num char-num)))])
                 (or (signature->signature-help sig) 'null))))
           (loop)]

          ;; ── Goto declaration (reuse definition query) ─────────────────────
          [(equal? method "textDocument/declaration")
           (respond-safely out id 'null
             (lambda ()
               (let* ([doc      (hash-ref params 'textDocument (hash))]
                      [uri      (hash-ref doc 'uri "")]
                      [pos      (hash-ref params 'position (hash))]
                      [line-num (hash-ref pos 'line 0)]
                      [char-num (hash-ref pos 'character 0)]
                      [text     (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [result (with-text-tmp text source-path compiler
                                (lambda (tmp)
                                  ;; The compiler reports same-file locations under the
                                  ;; logical path (source-path), so compare against it.
                                  (definition->lsp (run-definition compiler tmp line-num char-num) uri source-path)))])
                 (or result 'null))))
           (loop)]

          ;; ── Goto type definition ──────────────────────────────────────────
          [(equal? method "textDocument/typeDefinition")
           (respond-safely out id 'null
             (lambda ()
               (let* ([doc      (hash-ref params 'textDocument (hash))]
                      [uri      (hash-ref doc 'uri "")]
                      [pos      (hash-ref params 'position (hash))]
                      [line-num (hash-ref pos 'line 0)]
                      [char-num (hash-ref pos 'character 0)]
                      [text     (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [result (with-text-tmp text source-path compiler
                                (lambda (tmp)
                                  (location->lsp (run-type-definition compiler tmp line-num char-num) uri source-path)))])
                 (or result 'null))))
           (loop)]

          ;; ── Goto definition ───────────────────────────────────────────────

          [(equal? method "textDocument/definition")
           (let* ([doc      (hash-ref params 'textDocument (hash))]
                  [uri      (hash-ref doc 'uri "")]
                  [pos      (hash-ref params 'position (hash))]
                  [line-num (hash-ref pos 'line 0)]
                  [char-num (hash-ref pos 'character 0)]
                  [text     (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [lines    (if text (string-split text "
") '())]
                  [word     (and text (word-at lines line-num char-num))]
                  [compiler-result
                   (and text
                        compiler
                        (let ([query-path source-path]
                              [original-uri uri])
                          (if (hash-has-key? docs uri)
                              (with-validation-tmp "tesl-definition-~a.tesl" text source-path compiler
                                (lambda (tmp)
                                  (definition->lsp (run-definition compiler tmp line-num char-num) original-uri source-path)))
                              (definition->lsp (run-definition compiler query-path line-num char-num) original-uri query-path))))]
                  [fallback-result
                   (and text
                        word
                        (let* ([table (build-decl-table (path->string source-path) text)]
                               [entry (hash-ref table word #f)])
                          (and entry
                               (hash 'uri   (path->uri (vector-ref entry 0))
                                     'range (hash 'start (hash 'line      (vector-ref entry 1)
                                                               'character 0)
                                                 'end   (hash 'line      (vector-ref entry 1)
                                                              'character 0))))))]
                  [result (or compiler-result fallback-result)])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result 'null))))
           (loop)]

          [(equal? method "textDocument/references")
           (let* ([doc      (hash-ref params 'textDocument (hash))]
                  [uri      (hash-ref doc 'uri "")]
                  [pos      (hash-ref params 'position (hash))]
                  [line-num (hash-ref pos 'line 0)]
                  [char-num (hash-ref pos 'character 0)]
                  [text     (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [result
                   (and text
                        compiler
                        (let ([query-path source-path]
                              [original-uri uri])
                          (if (hash-has-key? docs uri)
                              (with-validation-tmp "tesl-occurrences-~a.tesl" text source-path compiler
                                (lambda (tmp)
                                  (occurrences->lsp (run-occurrences compiler tmp line-num char-num) original-uri source-path)))
                              (occurrences->lsp (run-occurrences compiler query-path line-num char-num) original-uri query-path))))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result '()))))
           (loop)]

          [(equal? method "textDocument/prepareRename")
           (let* ([doc       (hash-ref params 'textDocument (hash))]
                  [uri       (hash-ref doc 'uri "")]
                  [pos       (hash-ref params 'position (hash))]
                  [line-num  (hash-ref pos 'line 0)]
                  [char-num  (hash-ref pos 'character 0)]
                  [text      (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [result
                   (with-validation-tmp "tesl-prepare-~a.tesl" text source-path compiler
                     (lambda (tmp)
                       (occurrences->prepare-rename
                        (run-occurrences compiler tmp line-num char-num)
                        line-num char-num)))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result 'null))))
           (loop)]

          [(equal? method "textDocument/rename")
           (let* ([doc       (hash-ref params 'textDocument (hash))]
                  [uri       (hash-ref doc 'uri "")]
                  [pos       (hash-ref params 'position (hash))]
                  [line-num  (hash-ref pos 'line 0)]
                  [char-num  (hash-ref pos 'character 0)]
                  [new-name  (hash-ref params 'newName "")]
                  [text      (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [result
                   (and text
                        compiler
                        (let ([query-path source-path]
                              [original-uri uri])
                          (if (hash-has-key? docs uri)
                              (with-validation-tmp "tesl-rename-~a.tesl" text source-path compiler
                                (lambda (tmp)
                                  (occurrences->workspace-edit (run-occurrences compiler tmp line-num char-num) new-name original-uri source-path)))
                              (occurrences->workspace-edit (run-occurrences compiler query-path line-num char-num) new-name original-uri query-path))))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result 'null))))
           (loop)]

          [(equal? method "textDocument/codeAction")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc         (hash-ref params 'textDocument (hash))]
                      [uri         (hash-ref doc 'uri "")]
                      [text        (hash-ref docs uri #f)]
                      [context     (hash-ref params 'context (hash))]
                      [diagnostics (hash-ref context 'diagnostics '())]
                      [only        (hash-ref context 'only '())])
                 (code-actions uri text diagnostics only))))
           (loop)]

          ;; ── Document symbols ──────────────────────────────────────────────

          [(equal? method "textDocument/documentSymbol")
           (let* ([doc  (hash-ref params 'textDocument (hash))]
                  [uri  (hash-ref doc 'uri "")]
                  [text (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [result
                   (with-validation-tmp "tesl-symbols-~a.tesl" text source-path compiler
                     (lambda (tmp)
                       (semantic->document-symbols (run-semantic compiler tmp) uri)))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result '()))))
           (loop)]

          ;; ── Semantic tokens (full) ────────────────────────────────────────

          [(equal? method "textDocument/semanticTokens/full")
           (respond-safely out id (hash 'data '())
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [text  (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [data  (compute-semtok-data text source-path compiler)]
                      [rid   (next-server-id!)])
                 (hash-set! semtok-cache uri (cons rid data))
                 (hash 'resultId rid 'data data))))
           (loop)]

          ;; ── Semantic tokens (delta vs a cached resultId) ──────────────────
          [(equal? method "textDocument/semanticTokens/full/delta")
           (respond-safely out id (hash 'data '())
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [prev-id (hash-ref params 'previousResultId #f)]
                      [text  (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [data  (compute-semtok-data text source-path compiler)]
                      [rid   (next-server-id!)]
                      [cached (hash-ref semtok-cache uri #f)])
                 (hash-set! semtok-cache uri (cons rid data))
                 (if (and cached (equal? (car cached) prev-id))
                     ;; we have the exact previous snapshot → emit edits
                     (hash 'resultId rid
                           'edits (semantic-tokens-delta (cdr cached) data))
                     ;; unknown baseline → fall back to a full token set
                     (hash 'resultId rid 'data data)))))
           (loop)]

          ;; ── Semantic tokens (range) ───────────────────────────────────────
          ;; The compiler emits per-decl tokens for the whole file; we filter to
          ;; the requested line range, then re-delta-encode that subset.
          [(equal? method "textDocument/semanticTokens/range")
           (respond-safely out id (hash 'data '())
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [rng   (hash-ref params 'range (hash))]
                      [start (hash-ref rng 'start (hash))]
                      [end   (hash-ref rng 'end (hash))]
                      [sline (hash-ref start 'line 0)]
                      [eline (hash-ref end 'line 1000000)]
                      [text  (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [lines (if text (string-split text "\n" #:trim? #f) '())]
                      [tokens (with-text-tmp text source-path compiler
                                (lambda (tmp) (semantic->raw-tokens (run-semantic compiler tmp) lines)))]
                      [in-range (filter (lambda (t)
                                          (let ([l (vector-ref t 0)])
                                            (and (>= l sline) (<= l eline))))
                                        (or tokens '()))])
                 (hash 'data (raw-tokens->data in-range)))))
           (loop)]

          ;; ── Formatting ────────────────────────────────────────────────────

          [(equal? method "textDocument/formatting")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [text  (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [formatted (and text (run-fmt compiler text source-path))])
                 (whole-document-edits text formatted))))
           (loop)]

          ;; ── Range formatting (advisory range; full-file reflow) ───────────
          [(equal? method "textDocument/rangeFormatting")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [text  (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [formatted (and text (run-fmt compiler text source-path))])
                 (whole-document-edits text formatted))))
           (loop)]

          ;; ── On-type formatting (light reindent after newline) ─────────────
          [(equal? method "textDocument/onTypeFormatting")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc      (hash-ref params 'textDocument (hash))]
                      [uri      (hash-ref doc 'uri "")]
                      [pos      (hash-ref params 'position (hash))]
                      [line-num (hash-ref pos 'line 0)]
                      [text     (hash-ref docs uri #f)]
                      [lines    (if text (string-split text "\n" #:trim? #f) '())])
                 (on-type-edits lines line-num))))
           (loop)]

          ;; ── Inlay hints ───────────────────────────────────────────────────

          [(equal? method "textDocument/inlayHint")
           (let* ([doc   (hash-ref params 'textDocument (hash))]
                  [uri   (hash-ref doc 'uri "")]
                  [text  (hash-ref docs uri #f)]
                  [lines (if text (string-split text "\n" #:trim? #f) '())]
                  [bindings (hash-ref local-bindings-cache uri '())]
                  [result (if text (bindings->inlay-hints bindings lines) '())])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result result)))
           (loop)]

          ;; ── Document highlight ────────────────────────────────────────────

          [(equal? method "textDocument/documentHighlight")
           (let* ([doc      (hash-ref params 'textDocument (hash))]
                  [uri      (hash-ref doc 'uri "")]
                  [pos      (hash-ref params 'position (hash))]
                  [line-num (hash-ref pos 'line 0)]
                  [char-num (hash-ref pos 'character 0)]
                  [text     (hash-ref docs uri #f)]
                  [source-path (uri->path uri)]
                  [result
                   (with-validation-tmp "tesl-highlight-~a.tesl" text source-path compiler
                     (lambda (tmp)
                       (occurrences->document-highlights
                        (run-occurrences compiler tmp line-num char-num))))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result '()))))
           (loop)]

          ;; ── Folding ranges ────────────────────────────────────────────────
          [(equal? method "textDocument/foldingRange")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [text  (hash-ref docs uri #f)]
                      [lines (if text (string-split text "\n" #:trim? #f) '())])
                 (if (null? lines) '() (folding-ranges lines)))))
           (loop)]

          ;; ── Selection ranges (one per requested position) ─────────────────
          [(equal? method "textDocument/selectionRange")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc       (hash-ref params 'textDocument (hash))]
                      [uri       (hash-ref doc 'uri "")]
                      [positions (hash-ref params 'positions '())]
                      [text      (hash-ref docs uri #f)]
                      [source-path (uri->path uri)])
                 (for/list ([pos (in-list positions)])
                   (let* ([line-num (hash-ref pos 'line 0)]
                          [char-num (hash-ref pos 'character 0)]
                          [ranges (with-text-tmp text source-path compiler
                                    (lambda (tmp) (run-selection-range compiler tmp line-num char-num))
                                    '())]
                          [sr (selection-ranges->lsp (or ranges '()))])
                     ;; LSP requires a SelectionRange per position; fall back to a
                     ;; zero-width range at the cursor when the compiler has none.
                     (or sr
                         (hash 'range (hash 'start (hash 'line line-num 'character char-num)
                                            'end   (hash 'line line-num 'character char-num)))))))))
           (loop)]

          ;; ── Document links (URLs in comments) ─────────────────────────────
          [(equal? method "textDocument/documentLink")
           (respond-safely out id '()
             (lambda ()
               (let* ([doc   (hash-ref params 'textDocument (hash))]
                      [uri   (hash-ref doc 'uri "")]
                      [text  (hash-ref docs uri #f)]
                      [lines (if text (string-split text "\n" #:trim? #f) '())])
                 (document-links lines))))
           (loop)]

          ;; ── Linked editing ranges ─────────────────────────────────────────
          [(equal? method "textDocument/linkedEditingRange")
           (respond-safely out id 'null
             (lambda ()
               (let* ([doc      (hash-ref params 'textDocument (hash))]
                      [uri      (hash-ref doc 'uri "")]
                      [pos      (hash-ref params 'position (hash))]
                      [line-num (hash-ref pos 'line 0)]
                      [char-num (hash-ref pos 'character 0)]
                      [text     (hash-ref docs uri #f)]
                      [lines    (if text (string-split text "\n" #:trim? #f) '())])
                 (or (and (pair? lines)
                          (linked-editing-ranges lines line-num char-num word-at))
                     'null))))
           (loop)]

          ;; ── Pull diagnostics (full report + unchanged via resultId) ───────
          [(equal? method "textDocument/diagnostic")
           (respond-safely out id (diagnostic-report '() "")
             (lambda ()
               (let* ([doc     (hash-ref params 'textDocument (hash))]
                      [uri     (hash-ref doc 'uri "")]
                      [prev    (hash-ref params 'previousResultId #f)]
                      [text    (hash-ref docs uri #f)]
                      [source-path (uri->path uri)]
                      [rid     (content-result-id text)])
                 (if (and prev (equal? prev rid))
                     (unchanged-report rid)
                     (let ([diags (with-text-tmp text source-path compiler
                                    (lambda (tmp) (run-check compiler tmp))
                                    '())])
                       (hash-set! diag-cache uri rid)
                       (diagnostic-report (or diags '()) rid))))))
           (loop)]

          ;; ── Execute command (server-driven edits via applyEdit) ───────────
          [(equal? method "workspace/executeCommand")
           (respond-safely out id 'null
             (lambda ()
               (let* ([command (hash-ref params 'command "")]
                      [args    (hash-ref params 'arguments '())])
                 (cond
                   ;; tesl.applyFix: arguments = [uri, TextEdit]; ask the client to
                   ;; apply it via a workspace/applyEdit server→client request.
                   [(and (equal? command "tesl.applyFix") (>= (length args) 2))
                    (let* ([uri  (first args)]
                           [edit (second args)]
                           [we   (hash 'changes (hash (uri->json-key uri) (list edit)))])
                      (write-message out
                        (hash 'jsonrpc "2.0" 'id (next-server-id!)
                              'method "workspace/applyEdit"
                              'params (hash 'label "Tesl: apply fix" 'edit we)))
                      'null)]
                   ;; tesl.organizeImports: arguments = [uri, [TextEdit,...]].
                   [(and (equal? command "tesl.organizeImports") (>= (length args) 2))
                    (let* ([uri   (first args)]
                           [edits (second args)]
                           [we    (hash 'changes (hash (uri->json-key uri) edits))])
                      (write-message out
                        (hash 'jsonrpc "2.0" 'id (next-server-id!)
                              'method "workspace/applyEdit"
                              'params (hash 'label "Tesl: organize imports" 'edit we)))
                      'null)]
                   [else
                    (log (format "executeCommand: unknown/under-specified ~a" command))
                    'null]))))
           (loop)]

          ;; ── Configuration / watched files (re-validate, clear caches) ─────
          [(equal? method "workspace/didChangeConfiguration")
           (log "configuration changed — clearing caches")
           (hash-clear! semtok-cache)
           (hash-clear! diag-cache)
           ;; ask the client to refresh derived data it supports
           (request-refresh! out)
           (loop)]

          [(equal? method "workspace/didChangeWatchedFiles")
           (log "watched files changed — clearing caches, re-validating open docs")
           (hash-clear! semtok-cache)
           (hash-clear! diag-cache)
           (for ([(uri text) (in-hash docs)])
             (with-handlers ([exn? (lambda (e) (log (format "revalidate ~a: ~a" uri (exn-message e))))])
               (check-text! out uri (uri->path uri) text compiler)))
           (request-refresh! out)
           (loop)]

          ;; ── Inlay hint resolve (no-op enrichment; items already complete) ──
          [(equal? method "inlayHint/resolve")
           (respond-safely out id params (lambda () params))
           (loop)]

          ;; ── Shutdown / exit ───────────────────────────────────────────────

          [(equal? method "shutdown")
           (set! shutdown #t)
           (when id (write-message out (hash 'jsonrpc "2.0" 'id id 'result 'null)))
           (loop)]

          [(equal? method "exit")
           (exit (if shutdown 0 1))]

          [else
           (when id
             (write-message out (hash 'jsonrpc "2.0" 'id id
                                      'error (hash 'code -32601
                                                   'message (format "unknown: ~a" method)))))
           (loop)])))))

(module+ test
  (require rackunit)

  (define local-let-hover-src
    (string-join
     '("#lang tesl"
       "module Main exposing [value]"
       "import Tesl.Prelude exposing [Int, String]"
       "fn value() -> Int ="
       "  let formatted: Int = 1"
       "  *formatted"
       "test \"local lets\" {"
       "  let inferred = 2"
       "  expect inferred == 2"
       "}")
     "
"))

  (define local-let-binding-types
    (list (hash 'name "formatted" 'line 4 'type "Int")
          (hash 'name "inferred" 'line 7 'type "Int")))

  (define broader-local-hover-src
    (string-join
     '("#lang tesl"
       "module Main exposing [value]"
       "import Tesl.Prelude exposing [Int]"
       "import Tesl.Maybe exposing [Maybe(..)]"
       "fn value(input: Maybe Int) -> Int ="
       "  case input of"
       "    Something matched ->"
       "      let inferred = matched"
       "      inferred"
       "    Nothing -> 0")
     "
"))

  (define broader-local-binding-types
    (list (hash 'name "input" 'line 4 'type "Maybe Int")
          (hash 'name "matched" 'line 6 'type "Int")
          (hash 'name "inferred" 'line 7 'type "Int")))

  (define proof-local-hover-src
    (string-join
     '("#lang tesl"
       "module Main exposing [checkNoteId]"
       "import Tesl.Prelude exposing [String]"
       "check checkNoteId(s: String) -> s: String::: ValidNoteId s ="
       "  ok s::: ValidNoteId s")
     "
"))

  (define proof-local-binding-types
    (list (hash 'name "s" 'line 3 'type "String ::: ValidNoteId s")))

  (define proof-let-local-hover-src
    (string-join
     '("#lang tesl"
       "module Main exposing [value]"
       "import Tesl.Prelude exposing [Int, detachFact]"
       "fn value(quantity: Int) -> Int ="
       "  let p = checkPositiveInt 10"
       "  let pq = checkPriceExceedsQuantity p quantity"
       "  let proodd = detachFact pq"
       "  let (_ ::: xProof2) = pq"
       "  proodd")
     "
"))

  (define proof-let-binding-types
    (list (hash 'name "p" 'line 4 'type "Int ::: IsPositive p")
          (hash 'name "pq" 'line 5 'type "Int ::: PriceExceedsQuantity pq quantity"
                'note "subjects: pq; quantity")
          (hash 'name "proodd" 'line 6 'type "Fact (PriceExceedsQuantity pq quantity)"
                'note "fact subjects: pq; quantity")
          (hash 'name "xProof2" 'line 7 'type "Fact (PriceExceedsQuantity pq quantity)"
                'note "fact subjects: pq; quantity")))

  (let* ([tmp-path (string->path "/tmp/definition-temp.tesl")]
         [original-uri "file:///tmp/source.tesl"]
         [same-file-def (hash 'file "/tmp/definition-temp.tesl" 'line 3 'col 2 'end_line 3 'end_col 8)]
         [other-file-def (hash 'file "/tmp/other.tesl" 'line 1 'col 0 'end_line 1 'end_col 6)]
         [same-file-lsp (definition->lsp same-file-def original-uri tmp-path)]
         [other-file-lsp (definition->lsp other-file-def original-uri tmp-path)]
         [occurrence-locations (occurrences->lsp (list same-file-def other-file-def) original-uri tmp-path)])
    (check-equal? (hash-ref same-file-lsp 'uri) original-uri)
    (check-equal? (hash-ref (hash-ref same-file-lsp 'range) 'start) (hash 'line 3 'character 2))
    (check-equal? (hash-ref other-file-lsp 'uri) "file:///tmp/other.tesl")
    (check-equal? (length occurrence-locations) 2)
    (check-equal? (hash-ref (first occurrence-locations) 'uri) original-uri)
    (check-equal? (hash-ref (second occurrence-locations) 'uri) "file:///tmp/other.tesl"))

  (let* ([tmp-path (string->path "/tmp/definition-temp.tesl")]
         [original-uri "file:///tmp/source.tesl"]
         [same-file-def (hash 'file "/tmp/definition-temp.tesl" 'line 3 'col 2 'end_line 3 'end_col 8)]
         [other-file-def (hash 'file "/tmp/other.tesl" 'line 1 'col 0 'end_line 1 'end_col 6)]
         [rename-edit (occurrences->workspace-edit (list same-file-def other-file-def) "renamed" original-uri tmp-path)]
         [changes (hash-ref rename-edit 'changes)]
         [same-file-edits (hash-ref changes (uri->json-key original-uri))]
         [other-file-edits (hash-ref changes (uri->json-key "file:///tmp/other.tesl"))])
    (check-not-false rename-edit)
    (check-equal? (length same-file-edits) 1)
    (check-equal? (length other-file-edits) 1)
    (check-equal? (hash-ref (first same-file-edits) 'newText) "renamed")
    (check-equal? (hash-ref (hash-ref (first same-file-edits) 'range) 'start) (hash 'line 3 'character 2))
    (check-equal? (hash-ref (first other-file-edits) 'newText) "renamed")
    (check-false (occurrences->workspace-edit '() "renamed" original-uri tmp-path)))

  ;; prepareRename: reject non-symbols (no occurrences ⇒ 'null) and otherwise
  ;; return the precise token range the caret sits inside — never a wider span.
  (let* ([rec-occ  (hash 'file "/tmp/p.tesl" 'line 7 'col 2  'end_line 7 'end_col 12)] ; "somerecord"
         [read-occ (hash 'file "/tmp/p.tesl" 'line 9 'col 0  'end_line 9 'end_col 10)])
    ;; No occurrences (keyword / ::: / stdlib type) → reject.
    (check-equal? (occurrences->prepare-rename '() 7 4) 'null)
    ;; Caret inside `somerecord` (col 4) → range is exactly the identifier, NOT
    ;; including any trailing `.id` (the occurrence span ends at col 12).
    (let ([res (occurrences->prepare-rename (list rec-occ read-occ) 7 4)])
      (check-not-false res)
      (check-equal? (hash-ref (hash-ref res 'range) 'start) (hash 'line 7 'character 2))
      (check-equal? (hash-ref (hash-ref res 'range) 'end)   (hash 'line 7 'character 12)))
    ;; Caret on the other occurrence resolves to that occurrence's span.
    (let ([res (occurrences->prepare-rename (list rec-occ read-occ) 9 3)])
      (check-not-false res)
      (check-equal? (hash-ref (hash-ref res 'range) 'start) (hash 'line 9 'character 0))
      (check-equal? (hash-ref (hash-ref res 'range) 'end)   (hash 'line 9 'character 10))))

  (let ([typed-entry (find-local-binding-entry "/tmp/local-lets.tesl" local-let-hover-src 5 "formatted" local-let-binding-types)]
        [inferred-entry (find-local-binding-entry "/tmp/local-lets.tesl" local-let-hover-src 8 "inferred" local-let-binding-types)]
        [fallback-entry (find-local-binding-entry "/tmp/local-lets.tesl" local-let-hover-src 8 "inferred")]
        [param-entry (find-local-binding-entry "/tmp/broader-locals.tesl" broader-local-hover-src 5 "input" broader-local-binding-types)]
        [case-entry (find-local-binding-entry "/tmp/broader-locals.tesl" broader-local-hover-src 6 "matched" broader-local-binding-types)]
        [case-use-entry (find-local-binding-entry "/tmp/broader-locals.tesl" broader-local-hover-src 7 "matched" broader-local-binding-types)]
        [proof-entry (find-local-binding-entry "/tmp/proof-locals.tesl" proof-local-hover-src 3 "s" proof-local-binding-types)]
        [proof-let-p-entry (find-local-binding-entry "/tmp/proof-let-locals.tesl" proof-let-local-hover-src 8 "p" proof-let-binding-types)]
        [proof-let-pq-entry (find-local-binding-entry "/tmp/proof-let-locals.tesl" proof-let-local-hover-src 8 "pq" proof-let-binding-types)]
        [proof-let-fact-entry (find-local-binding-entry "/tmp/proof-let-locals.tesl" proof-let-local-hover-src 8 "proodd" proof-let-binding-types)]
        [proof-let-destructured-fact-entry (find-local-binding-entry "/tmp/proof-let-locals.tesl" proof-let-local-hover-src 7 "xProof2" proof-let-binding-types)])
    (check-not-false typed-entry)
    (check-equal? (vector-ref typed-entry 1) 4)
    (check-equal? (vector-ref typed-entry 3) "formatted: Int")
    (check-not-false inferred-entry)
    (check-equal? (vector-ref inferred-entry 1) 7)
    (check-equal? (vector-ref inferred-entry 3) "inferred: Int")
    (check-not-false fallback-entry)
    (check-equal? (vector-ref fallback-entry 3) "let inferred = 2")
    (check-not-false param-entry)
    (check-equal? (vector-ref param-entry 1) 4)
    (check-equal? (vector-ref param-entry 3) "input: Maybe Int")
    (check-not-false case-entry)
    (check-equal? (vector-ref case-entry 1) 6)
    (check-equal? (vector-ref case-entry 3) "matched: Int")
    (check-not-false case-use-entry)
    (check-equal? (vector-ref case-use-entry 1) 6)
    (check-equal? (vector-ref case-use-entry 3) "matched: Int")
    (check-not-false proof-entry)
    (check-equal? (vector-ref proof-entry 1) 3)
    (check-equal? (vector-ref proof-entry 3) "s: String ::: ValidNoteId s")
    (check-not-false proof-let-p-entry)
    (check-equal? (vector-ref proof-let-p-entry 1) 4)
    (check-equal? (vector-ref proof-let-p-entry 3) "p: Int ::: IsPositive p")
    (check-not-false proof-let-pq-entry)
    (check-equal? (vector-ref proof-let-pq-entry 1) 5)
    (check-equal? (vector-ref proof-let-pq-entry 3) "pq: Int ::: PriceExceedsQuantity pq quantity")
    (check-equal? (vector-ref proof-let-pq-entry 4) '("subjects: pq; quantity"))
    (check-true (regexp-match? #rx"subjects: pq; quantity"
                               (format-hover-entry proof-let-pq-entry)))
    (check-not-false proof-let-fact-entry)
    (check-equal? (vector-ref proof-let-fact-entry 1) 6)
    (check-equal? (vector-ref proof-let-fact-entry 3) "proodd: Fact (PriceExceedsQuantity pq quantity)")
    (check-equal? (vector-ref proof-let-fact-entry 4) '("fact subjects: pq; quantity"))
    (check-true (regexp-match? #rx"fact subjects: pq; quantity"
                               (format-hover-entry proof-let-fact-entry)))
    (check-not-false proof-let-destructured-fact-entry)
    (check-equal? (vector-ref proof-let-destructured-fact-entry 1) 7)
    (check-equal? (vector-ref proof-let-destructured-fact-entry 3) "xProof2: Fact (PriceExceedsQuantity pq quantity)")
    (check-equal? (vector-ref proof-let-destructured-fact-entry 4) '("fact subjects: pq; quantity"))
    (check-true (regexp-match? #rx"fact subjects: pq; quantity"
                               (format-hover-entry proof-let-destructured-fact-entry))))

  (let* ([uri "file:///tmp/lint-fix.tesl"]
         [text (string-join
                '("#lang tesl"
                  "module Main exposing [value]"
                  "import Tesl.Prelude exposing [Int]   "
                  "fn value() -> Int = 1")
                "\n")]
         [diag (hash
                'code "W010"
                'data (hash 'fix (hash 'kind "replace_line"
                                      'line 2
                                      'replacement "import Tesl.Prelude exposing [Int]")))]
         [action (diag->code-action uri text diag)]
         [changes (hash-ref (hash-ref action 'edit) 'changes)]
         [uri-edits (hash-ref changes (uri->json-key uri))]
         [edit (car uri-edits)])
    (check-not-false action)
    (check-equal? (hash-ref action 'kind) "quickfix")
    (check-equal? (hash-ref action 'title) "Apply fix for W010")
    (check-equal? (hash-ref edit 'newText) "import Tesl.Prelude exposing [Int]")
    (check-equal? (hash-ref (hash-ref edit 'range) 'start) (hash 'line 2 'character 0)))

  (check-true (hash-has-key? stdlib-sigs "telemetry"))
  (check-true (hash-has-key? stdlib-sigs "initTelemetry"))

  ;; ── Completion: kind mapping ────────────────────────────────────────────────
  (check-equal? (completion-kind->lsp "field")    lsp-kind-field)
  (check-equal? (completion-kind->lsp "function") lsp-kind-function)
  (check-equal? (completion-kind->lsp "variable") lsp-kind-variable)
  (check-equal? (completion-kind->lsp "anything-else") lsp-kind-variable)

  ;; ── Completion: compiler item → LSP item ────────────────────────────────────
  (let ([field-item (compiler-completion->lsp
                     (hash 'label "width" 'detail "Int" 'kind "field"))]
        [fn-item    (compiler-completion->lsp
                     (hash 'label "myFunc" 'detail "Int -> Int" 'kind "function"))]
        [stdlib-item (compiler-completion->lsp
                      (hash 'label "String.length" 'detail "String -> Int" 'kind "function"))]
        [bad-item   (compiler-completion->lsp (hash 'detail "no label"))])
    (check-not-false field-item)
    (check-equal? (hash-ref field-item 'label) "width")
    (check-equal? (hash-ref field-item 'kind) lsp-kind-field)
    (check-equal? (hash-ref field-item 'detail) "Int")
    ;; A non-stdlib field still gets a fenced detail block as documentation.
    (check-equal? (hash-ref (hash-ref field-item 'documentation) 'value)
                  "```tesl\nInt\n```")
    (check-equal? (hash-ref fn-item 'kind) lsp-kind-function)
    ;; A known stdlib name pulls its richer doc from stdlib-sigs.
    (check-true (regexp-match? #rx"String.length"
                               (hash-ref (hash-ref stdlib-item 'documentation) 'value)))
    (check-false bad-item))

  ;; ── Completion: keyword item ────────────────────────────────────────────────
  (let ([kw (keyword-completion->lsp (cons "select" "select rows from an entity"))])
    (check-equal? (hash-ref kw 'label) "select")
    (check-equal? (hash-ref kw 'kind) lsp-kind-keyword)
    ;; "select" has a richer stdlib-sigs doc, which should be preferred.
    (check-true (regexp-match? #rx"select"
                               (hash-ref (hash-ref kw 'documentation) 'value))))
  (let ([kw (keyword-completion->lsp (cons "then" "then branch"))])
    ;; "then" has no stdlib-sigs entry → falls back to the short detail.
    (check-equal? (hash-ref (hash-ref kw 'documentation) 'value) "then branch"))

  ;; ── Completion: build-completions merge / dedup ─────────────────────────────
  (let* ([compiler-items (list (hash 'label "myFunc" 'detail "Int -> Int" 'kind "function")
                               ;; collides with the "select" keyword → keyword suppressed
                               (hash 'label "select" 'detail "a -> b" 'kind "function"))]
         [general (build-completions compiler-items #f)]
         [labels  (map (lambda (i) (hash-ref i 'label)) general)]
         [dotted  (build-completions
                   (list (hash 'label "width" 'detail "Int" 'kind "field")) #t)]
         [dot-labels (map (lambda (i) (hash-ref i 'label)) dotted)])
    ;; compiler identifiers present
    (check-not-false (member "myFunc" labels))
    ;; keywords merged in (e.g. "fn", "case")
    (check-not-false (member "fn" labels))
    (check-not-false (member "case" labels))
    (check-not-false (member "api-test" labels))
    ;; "select" appears exactly once (compiler item wins; keyword deduped)
    (check-equal? (length (filter (lambda (l) (equal? l "select")) labels)) 1)
    ;; after a dot: ONLY compiler field items, no keywords
    (check-equal? dot-labels (list "width"))
    (check-false (member "fn" dot-labels)))

  ;; ── Hover: field-at / type-at formatting ────────────────────────────────────
  (let ([md (format-field-at-hover
             (hash 'field "width" 'record_type "Rectangle" 'field_type "Int"))])
    (check-true (regexp-match? #rx"width: Int" md))
    (check-true (regexp-match? #rx"field of `Rectangle`" md)))
  (check-false (format-field-at-hover (hash 'record_type "Rectangle")))
  (check-equal? (format-type-at-hover (hash 'type "Maybe Int"))
                "```tesl\nMaybe Int\n```")
  (check-false (format-type-at-hover (hash 'type "")))

  ;; ── Document symbols ─────────────────────────────────────────────────────────
  (let* ([uri "file:///tmp/sym.tesl"]
         [semantic (hash
                    'functions (list
                                (hash 'name "double" 'kind "fn"
                                      'loc (hash 'start_line 3 'start_col 0
                                                 'end_line 4 'end_col 1))
                                (hash 'name "noLoc" 'kind "fn")) ; skipped (no loc)
                    'records (list
                              (hash 'name "User"
                                    'fields (list (hash 'name "email" 'type "String"))))
                    'adts (list
                           (hash 'name "Color"
                                 'variants (list (hash 'constructor "Red")
                                                 (hash 'constructor "Blue")))))]
         [syms (semantic->document-symbols semantic uri)]
         [names (map (lambda (s) (hash-ref s 'name)) syms)])
    ;; function with loc present; one without loc dropped
    (check-not-false (member "double" names))
    (check-false (member "noLoc" names))
    ;; record + field + enum + members
    (check-not-false (member "User" names))
    (check-not-false (member "email" names))
    (check-not-false (member "Color" names))
    (check-not-false (member "Red" names))
    (check-not-false (member "Blue" names))
    ;; double is a Function symbol kind, located at the right range/uri
    (let ([dbl (findf (lambda (s) (equal? (hash-ref s 'name) "double")) syms)])
      (check-equal? (hash-ref dbl 'kind) symkind-function)
      (check-equal? (hash-ref (hash-ref dbl 'location) 'uri) uri)
      (check-equal? (hash-ref (hash-ref (hash-ref dbl 'location) 'range) 'start)
                    (hash 'line 3 'character 0)))
    ;; field carries its container
    (let ([fld (findf (lambda (s) (equal? (hash-ref s 'name) "email")) syms)])
      (check-equal? (hash-ref fld 'kind) symkind-field)
      (check-equal? (hash-ref fld 'containerName) "User")))

  ;; ── Semantic tokens: delta encoding + single-identifier span ─────────────────
  (let* ([lines (list "#lang tesl"
                      "module M exposing [double]"
                      "import Tesl.Prelude exposing [Int]"
                      "fn double(n: Int) -> Int ="
                      "  let result = n + n")]
         [semantic (hash
                    'functions (list
                                (hash 'name "double" 'kind "fn"
                                      'loc (hash 'start_line 3 'start_col 0
                                                 'end_line 4 'end_col 18)))
                    'local_bindings (list
                                     (hash 'name "result" 'type "Int"
                                           'loc (hash 'start_line 4 'start_col 6
                                                      'end_line 4 'end_col 12))))]
         [toks (semantic->raw-tokens semantic lines)]
         [data (raw-tokens->data toks)])
    ;; two tokens: double (line 3) and result (line 4)
    (check-equal? (length toks) 2)
    ;; first token anchored at the NAME "double" (col 3), length 6 — NOT the
    ;; whole declaration; this is the minimap-oversize guard.
    (check-equal? (vector-ref (first toks) 0) 3)
    (check-equal? (vector-ref (first toks) 1) 3)
    (check-equal? (vector-ref (first toks) 2) 6)
    ;; "result" token: col 6, length 6 (bounded to the identifier, not to EOL)
    (check-equal? (vector-ref (second toks) 1) 6)
    (check-equal? (vector-ref (second toks) 2) 6)
    ;; data is 5 ints per token, delta encoded
    (check-equal? (length data) 10)
    ;; first token: deltaLine=3, deltaStartChar=3, len=6
    (check-equal? (take data 3) (list 3 3 6))
    ;; second token: deltaLine=1 (next line), deltaStartChar=6 (absolute, new line)
    (check-equal? (list-ref data 5) 1)
    (check-equal? (list-ref data 6) 6))

  ;; ── Inlay hints: inferred lets only, skip annotated & params ─────────────────
  (let* ([lines (list "fn f(x: Int) -> Int ="            ; line 0 (param, skip)
                      "  let inferred = x + 1"            ; line 1 (hint!)
                      "  let annotated: Int = x"          ; line 2 (annotated, skip)
                      "  inferred")]
         [bindings (list
                    (hash 'name "x" 'line 0 'col 5 'type "Int")          ; param
                    (hash 'name "inferred" 'line 1 'col 6 'type "Int")
                    (hash 'name "annotated" 'line 2 'col 6 'type "Int"))]
         [hints (bindings->inlay-hints bindings lines)])
    (check-equal? (length hints) 1)
    (let ([h (first hints)])
      (check-equal? (hash-ref h 'label) ": Int")
      (check-equal? (hash-ref (hash-ref h 'position) 'line) 1)
      ;; positioned right after "inferred" (2 spaces + "let " = 6 chars; name 8 long → col 14)
      (check-equal? (hash-ref (hash-ref h 'position) 'character) 14)))

  ;; ── Document highlights from occurrences ─────────────────────────────────────
  (let* ([occs (list (hash 'line 3 'col 3 'end_line 3 'end_col 9)
                     (hash 'line 7 'col 5 'end_line 7 'end_col 11))]
         [hls (occurrences->document-highlights occs)])
    (check-equal? (length hls) 2)
    (check-equal? (hash-ref (first hls) 'kind) 1)
    (check-equal? (hash-ref (hash-ref (first hls) 'range) 'start)
                  (hash 'line 3 'character 3))
    (check-equal? (hash-ref (hash-ref (second hls) 'range) 'end)
                  (hash 'line 7 'character 11)))

  ;; ── Document highlights: kind mapping (write=3, read=2, text=1) ───────────────
  (check-equal? (highlight-kind->lsp "write") 3)
  (check-equal? (highlight-kind->lsp "read")  2)
  (check-equal? (highlight-kind->lsp "text")  1)
  (check-equal? (highlight-kind->lsp "unknown") 1)
  (let* ([occs (list (hash 'line 4 'col 10 'end_line 4 'end_col 11 'kind "write")
                     (hash 'line 5 'col 2  'end_line 5 'end_col 3  'kind "read"))]
         [hls (occurrences->document-highlights occs)])
    (check-equal? (hash-ref (first hls) 'kind) 3)
    (check-equal? (hash-ref (second hls) 'kind) 2))

  ;; ── Signature help: compiler signature → LSP SignatureHelp ───────────────────
  (let* ([sig (hash 'label "double n: Int"
                    'parameters (list (hash 'label "n" 'type "Int"))
                    'active_parameter 0)]
         [help (signature->signature-help sig)])
    (check-not-false help)
    (check-equal? (hash-ref help 'activeSignature) 0)
    (check-equal? (hash-ref help 'activeParameter) 0)
    (let ([sigs (hash-ref help 'signatures)])
      (check-equal? (length sigs) 1)
      (check-equal? (hash-ref (first sigs) 'label) "double n: Int")
      (check-equal? (length (hash-ref (first sigs) 'parameters)) 1)
      (let ([p (first (hash-ref (first sigs) 'parameters))])
        (check-equal? (hash-ref p 'label) "n")
        (check-true (regexp-match? #rx"Int" (hash-ref (hash-ref p 'documentation) 'value))))))
  ;; multi-arg signature: activeParameter tracks the cursor's arg
  (let* ([sig (hash 'label "clamp lo: Int hi: Int n: Int"
                    'parameters (list (hash 'label "lo" 'type "Int")
                                      (hash 'label "hi" 'type "Int")
                                      (hash 'label "n" 'type "Int"))
                    'active_parameter 2)]
         [help (signature->signature-help sig)])
    (check-equal? (hash-ref help 'activeParameter) 2)
    (check-equal? (length (hash-ref (first (hash-ref help 'signatures)) 'parameters)) 3))
  ;; a param with no type produces null documentation (not a crash)
  (let* ([sig (hash 'label "f x" 'parameters (list (hash 'label "x" 'type "")) 'active_parameter 0)]
         [p (first (hash-ref (first (hash-ref (signature->signature-help sig) 'signatures)) 'parameters))])
    (check-eq? (hash-ref p 'documentation) 'null))
  (check-false (signature->signature-help 'null))
  (check-false (signature->signature-help #f))

  ;; ── Selection range: innermost-first list → nested SelectionRange ────────────
  (let* ([ranges (list (hash 'line 5 'col 2 'end_line 5 'end_col 5)    ; innermost
                       (hash 'line 5 'col 2 'end_line 5 'end_col 7)    ; middle
                       (hash 'line 4 'col 3 'end_line 9 'end_col 1))]  ; outermost
         [sr (selection-ranges->lsp ranges)])
    ;; head node is the innermost range
    (check-equal? (hash-ref (hash-ref sr 'range) 'start) (hash 'line 5 'character 2))
    (check-equal? (hash-ref (hash-ref sr 'range) 'end)   (hash 'line 5 'character 5))
    ;; parent chain widens outward
    (let* ([p1 (hash-ref sr 'parent)]
           [p2 (hash-ref p1 'parent)])
      (check-equal? (hash-ref (hash-ref p1 'range) 'end) (hash 'line 5 'character 7))
      (check-equal? (hash-ref (hash-ref p2 'range) 'start) (hash 'line 4 'character 3))
      ;; outermost has no parent
      (check-false (hash-has-key? p2 'parent))))
  ;; single range: a node with no parent
  (let ([sr (selection-ranges->lsp (list (hash 'line 0 'col 0 'end_line 0 'end_col 3)))])
    (check-false (hash-has-key? sr 'parent)))
  ;; empty list: #f
  (check-false (selection-ranges->lsp '()))

  ;; ── Completion: sortText, snippet inserts, resolve ───────────────────────────
  (let ([fld (compiler-completion->lsp (hash 'label "width" 'detail "Int" 'kind "field"))]
        [fn  (compiler-completion->lsp (hash 'label "myFunc" 'detail "Int -> Int" 'kind "function"))])
    ;; fields sort to bucket 0, identifiers to bucket 1
    (check-equal? (hash-ref fld 'sortText) "0width")
    (check-equal? (hash-ref fn 'sortText) "1myFunc")
    ;; resolve data carried for lazy enrichment
    (check-equal? (hash-ref (hash-ref fld 'data) 'label) "width"))
  ;; structural keyword "fn" → snippet insert (InsertTextFormat=2)
  (let ([kw-fn (keyword-completion->lsp (cons "fn" "function declaration"))])
    (check-equal? (hash-ref kw-fn 'insertTextFormat) 2)
    (check-true (regexp-match? #rx"\\$\\{1:" (hash-ref kw-fn 'insertText)))
    (check-equal? (hash-ref kw-fn 'sortText) "2fn"))
  ;; plain keyword "then" → no snippet
  (let ([kw-then (keyword-completion->lsp (cons "then" "then branch"))])
    (check-false (hash-has-key? kw-then 'insertText)))
  ;; completionItem/resolve fills documentation from data for a stdlib name
  (let* ([item (hash 'label "String.length" 'kind lsp-kind-function
                     'documentation 'null
                     'data (hash 'label "String.length" 'detail "String -> Int" 'kind "function"))]
         [resolved (completion-item-resolve item)])
    (check-true (regexp-match? #rx"String.length"
                               (hash-ref (hash-ref resolved 'documentation) 'value))))

  ;; ── Folding ranges: decl blocks, brace blocks, comment runs ──────────────────
  (let* ([lines (list "#lang tesl"                  ; 0
                      "module M exposing [f]"       ; 1
                      "# a comment"                 ; 2
                      "# second comment line"       ; 3
                      "fn f(n: Int) -> Int ="       ; 4  decl start
                      "  n * 2"                      ; 5
                      ""                             ; 6  (trailing blank trimmed)
                      "test \"t\" {"                ; 7  decl start + brace
                      "  expect f 1 == 2"            ; 8
                      "}")]                          ; 9  brace close
         [folds (folding-ranges lines)])
    ;; comment run lines 2..3 folds as a comment region
    (check-not-false (findf (lambda (r) (and (= (hash-ref r 'startLine) 2)
                                             (= (hash-ref r 'endLine) 3)
                                             (equal? (hash-ref r 'kind #f) "comment")))
                            folds))
    ;; fn block: line 4 down to 5 (the trailing blank at 6 is trimmed)
    (check-not-false (findf (lambda (r) (and (= (hash-ref r 'startLine) 4)
                                             (= (hash-ref r 'endLine) 5)))
                            folds))
    ;; brace block: line 7 to 9
    (check-not-false (findf (lambda (r) (and (= (hash-ref r 'startLine) 7)
                                             (= (hash-ref r 'endLine) 9)))
                            folds)))
  ;; single-line constructs never fold (start==end suppressed)
  (check-equal? (folding-ranges (list "fn f() -> Int = 1")) '())

  ;; ── Semantic tokens delta: prefix/suffix diff → minimal edit ─────────────────
  ;; identical → no edits
  (check-equal? (semantic-tokens-delta '(0 0 6 0 0) '(0 0 6 0 0)) '())
  ;; one token changed length (index 2): replaces just that middle slot
  (let ([edits (semantic-tokens-delta '(0 0 6 0 0) '(0 0 8 0 0))])
    (check-equal? (length edits) 1)
    (let ([e (first edits)])
      (check-equal? (hash-ref e 'start) 2)
      (check-equal? (hash-ref e 'deleteCount) 1)
      (check-equal? (hash-ref e 'data) (list 8))))
  ;; appended a whole new token (5 ints) at the end → pure insert
  (let ([edits (semantic-tokens-delta '(0 0 6 0 0) '(0 0 6 0 0 1 2 4 1 0))])
    (check-equal? (length edits) 1)
    (let ([e (first edits)])
      (check-equal? (hash-ref e 'start) 5)
      (check-equal? (hash-ref e 'deleteCount) 0)
      (check-equal? (hash-ref e 'data) (list 1 2 4 1 0))))
  ;; removed the last token → pure delete
  (let ([edits (semantic-tokens-delta '(0 0 6 0 0 1 2 4 1 0) '(0 0 6 0 0))])
    (check-equal? (hash-ref (first edits) 'start) 5)
    (check-equal? (hash-ref (first edits) 'deleteCount) 5)
    (check-equal? (hash-ref (first edits) 'data) '()))

  ;; ── Formatting edits: whole-document replacement ─────────────────────────────
  (let ([edits (whole-document-edits "a\nb\n" "a\n  b\n")])
    (check-equal? (length edits) 1)
    (check-equal? (hash-ref (first edits) 'newText) "a\n  b\n")
    (check-equal? (hash-ref (hash-ref (first edits) 'range) 'start) (hash 'line 0 'character 0)))
  ;; no change → no edits
  (check-equal? (whole-document-edits "x\n" "x\n") '())
  (check-equal? (whole-document-edits "x\n" #f) '())

  ;; ── On-type formatting: collapse a whitespace-only line, else nothing ────────
  (let ([edits (on-type-edits (list "fn f() ->" "   ") 1)])
    (check-equal? (length edits) 1)
    (check-equal? (hash-ref (first edits) 'newText) "")
    (check-equal? (hash-ref (hash-ref (first edits) 'range) 'end) (hash 'line 1 'character 3)))
  (check-equal? (on-type-edits (list "  let x = 1") 0) '())   ; non-blank line untouched
  (check-equal? (on-type-edits (list "a") 9) '())             ; out-of-range line

  ;; ── Incremental sync: position→offset + ranged edit application ──────────────
  (check-equal? (lsp-position->offset "abc\ndef" 0 1) 1)
  (check-equal? (lsp-position->offset "abc\ndef" 1 0) 4)
  (check-equal? (lsp-position->offset "abc\ndef" 1 2) 6)
  (check-equal? (lsp-position->offset "abc\ndef" 9 9) 7)   ; past end clamps
  ;; replace "b" (line0 col1..col2) with "XY"
  (let ([txt (apply-content-change "abc\ndef"
                                   (hash 'range (hash 'start (hash 'line 0 'character 1)
                                                      'end   (hash 'line 0 'character 2))
                                         'text "XY"))])
    (check-equal? txt "aXYc\ndef"))
  ;; insert at a point (empty range)
  (let ([txt (apply-content-change "abc"
                                   (hash 'range (hash 'start (hash 'line 0 'character 3)
                                                      'end   (hash 'line 0 'character 3))
                                         'text "d"))])
    (check-equal? txt "abcd"))
  ;; whole-document change (no range) replaces everything
  (check-equal? (apply-content-change "old" (hash 'text "new")) "new")
  ;; multiple ranged edits applied in sequence
  (let ([txt (apply-content-changes "hello"
                                    (list (hash 'range (hash 'start (hash 'line 0 'character 0)
                                                             'end   (hash 'line 0 'character 1))
                                                'text "H")
                                          (hash 'range (hash 'start (hash 'line 0 'character 4)
                                                             'end   (hash 'line 0 'character 5))
                                                'text "O")))])
    (check-equal? txt "HellO"))

  ;; ── Document links: URLs in comments only ────────────────────────────────────
  (let* ([lines (list "# docs at https://tesl.dev/x and http://a.b/c"
                      "fn f() -> Int = 1"
                      "import Tesl.List exposing [List.map]")]   ; module path NOT linked
         [links (document-links lines)])
    (check-equal? (length links) 2)
    (check-equal? (hash-ref (first links) 'target) "https://tesl.dev/x")
    (check-equal? (hash-ref (second links) 'target) "http://a.b/c")
    ;; first link range starts at the 'h' of https (char 10 on line 0)
    (check-equal? (hash-ref (hash-ref (first links) 'range) 'start) (hash 'line 0 'character 10)))
  (check-equal? (document-links (list "fn f() -> Int = 1")) '())

  ;; ── Block bounds: enclosing column-0 decl block ──────────────────────────────
  (let ([lines (list "fn a() -> Int ="     ; 0  block start
                     "  let n = 1"          ; 1
                     "  n"                   ; 2
                     "fn b() -> Int ="      ; 3  next block start
                     "  2")])               ; 4
    (let-values ([(s e) (block-bounds lines 2)]) (check-equal? (list s e) (list 0 3)))
    (let-values ([(s e) (block-bounds lines 4)]) (check-equal? (list s e) (list 3 5))))

  ;; ── Linked editing ranges: same-name idents within the block ─────────────────
  (let* ([lines (list "fn double(n: Int) -> Int ="   ; 0
                      "  n + n"                       ; 1  two uses
                      "fn other() -> Int ="          ; 2  different block
                      "  n")]                         ; 3  must NOT join (other block)
         [ler (linked-editing-ranges lines 0 10 word-at)])   ; cursor on "n" param
    (check-not-false ler)
    ;; param decl + 2 body uses = 3 ranges, all within lines 0..1
    (check-equal? (length (hash-ref ler 'ranges)) 3)
    (check-true (for/and ([r (in-list (hash-ref ler 'ranges))])
                  (<= (hash-ref (hash-ref r 'start) 'line) 1))))
  ;; a single occurrence is not a linked group → #f
  (check-false (linked-editing-ranges (list "fn f() -> Int =" "  x") 1 2 word-at))

  ;; ── Diagnostic fix extraction + classification ───────────────────────────────
  (let* ([text "#lang tesl\nmodule M exposing [f]\nfn f() -> Int = 1\n"]
         [import-diag (hash 'code "T001"
                            'message "type `Int` is not in scope; add it to an import. Try: import Tesl.Prelude exposing [Int]"
                            'data (hash 'fix (hash 'kind "replace_line" 'line 1
                                                   'replacement "import Tesl.Prelude exposing [Int]")))]
         [plain-diag (hash 'code "W001" 'message "unused binding"
                           'data (hash 'fix (hash 'kind "replace_line" 'line 2 'replacement "fn f() -> Int = 2")))]
         [no-fix-diag (hash 'code "E999" 'message "no fix" 'data (hash))])
    (check-not-false (diag->fix-edit text import-diag))
    (check-false (diag->fix-edit text no-fix-diag))
    (check-true (import-fix? import-diag))
    (check-false (import-fix? plain-diag))
    ;; full code-action set with no `only` filter: 2 quickfixes + fixAll + organizeImports
    (let* ([uri "file:///tmp/ca.tesl"]
           [actions (code-actions uri text (list import-diag plain-diag) '())]
           [kinds (map (lambda (a) (hash-ref a 'kind)) actions)])
      (check-equal? (length (filter (lambda (k) (equal? k "quickfix")) kinds)) 2)
      (check-not-false (member "source.fixAll" kinds))
      (check-not-false (member "source.organizeImports" kinds))
      ;; fixAll bundles both edits; organizeImports only the import edit
      (let ([fa (findf (lambda (a) (equal? (hash-ref a 'kind) "source.fixAll")) actions)]
            [oi (findf (lambda (a) (equal? (hash-ref a 'kind) "source.organizeImports")) actions)])
        (check-equal? (length (hash-ref (hash-ref (hash-ref fa 'edit) 'changes)
                                        (uri->json-key uri))) 2)
        (check-equal? (length (hash-ref (hash-ref (hash-ref oi 'edit) 'changes)
                                        (uri->json-key uri))) 1)))
    ;; `only` filter: request just source.organizeImports → only that action
    (let* ([uri "file:///tmp/ca.tesl"]
           [actions (code-actions uri text (list import-diag plain-diag) (list "source.organizeImports"))]
           [kinds (map (lambda (a) (hash-ref a 'kind)) actions)])
      (check-equal? kinds (list "source.organizeImports"))))

  ;; ── Pull diagnostics: report + resultId + unchanged ──────────────────────────
  (check-equal? (content-result-id "abc") (content-result-id "abc"))
  (check-not-equal? (content-result-id "abc") (content-result-id "abd"))
  (let ([rep (diagnostic-report (list (hash 'message "x")) "RID")])
    (check-equal? (hash-ref rep 'kind) "full")
    (check-equal? (hash-ref rep 'resultId) "RID")
    (check-equal? (length (hash-ref rep 'items)) 1))
  (let ([unch (unchanged-report "RID")])
    (check-equal? (hash-ref unch 'kind) "unchanged")
    (check-equal? (hash-ref unch 'resultId) "RID")))

(module+ main
  (run))
