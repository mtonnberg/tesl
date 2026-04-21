#lang racket
;;; Tesl Language Server — diagnostics + hover + goto definition

(require json
         racket/port
         racket/path
         racket/string
         racket/runtime-path
         racket/list)

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
    (cons "List.map"            "fn List.map(f: a -> b, xs: List a) -> List b")
    (cons "List.filter"         "fn List.filter(pred: a -> Bool, xs: List a) -> List a")
    (cons "List.filterMap"      "fn List.filterMap(f: a -> Maybe b, xs: List a) -> List b")
    (cons "List.foldl"          "fn List.foldl(f: (b, a) -> b, init: b, xs: List a) -> b")
    (cons "List.foldr"          "fn List.foldr(f: (a, b) -> b, init: b, xs: List a) -> b")
    (cons "List.append"         "fn List.append(xs: List a, ys: List a) -> List a")
    (cons "List.reverse"        "fn List.reverse(xs: List a) -> List a")
    (cons "List.sort"           "fn List.sort(xs: List a) -> List a ? IsSorted")
    (cons "List.sortBy"         "fn List.sortBy(f: a -> b, xs: List a) -> List a ? IsSorted")
    (cons "List.contains"       "fn List.contains(xs: List a, x: a) -> Bool")
    (cons "List.find"           "fn List.find(pred: a -> Bool, xs: List a) -> Maybe a")
    (cons "List.take"           "fn List.take(n: Int ::: IsNonNegative n, xs: List a) -> List a")
    (cons "List.drop"           "fn List.drop(n: Int ::: IsNonNegative n, xs: List a) -> List a")
    (cons "List.zip"            "fn List.zip(xs: List a, ys: List b) -> List (Tuple2 a b)")
    (cons "List.sum"            "fn List.sum(xs: List Int) -> Int")
    (cons "List.product"        "fn List.product(xs: List Int) -> Int")
    (cons "List.maximum"        "fn List.maximum(xs: List Int) -> Maybe Int")
    (cons "List.minimum"        "fn List.minimum(xs: List Int) -> Maybe Int")
    (cons "List.any"            "fn List.any(pred: a -> Bool, xs: List a) -> Bool")
    (cons "List.all"            "fn List.all(pred: a -> Bool, xs: List a) -> Bool")
    (cons "List.count"          "fn List.count(pred: a -> Bool, xs: List a) -> Int")
    (cons "List.range"          "fn List.range(start: Int, end: Int) -> List Int")
    (cons "List.repeat"         "fn List.repeat(x: a, n: Int ::: IsNonNegative n) -> List a")
    (cons "List.unique"         "fn List.unique(xs: List a) -> List a")
    (cons "List.partition"      "fn List.partition(pred: a -> Bool, xs: List a) -> List (List a)")
    (cons "List.findIndex"      "fn List.findIndex(pred: a -> Bool, xs: List a) -> Maybe Int")
    (cons "List.zipWith"        "fn List.zipWith(f: (a, b) -> c, xs: List a, ys: List b) -> List c")
    (cons "List.unzip"          "fn List.unzip(pairs: List (List Any)) -> List (List Any)  — returns [firsts, seconds]")
    (cons "List.flatten"        "fn List.flatten(xss: List (List a)) -> List a")
    (cons "List.concat"         "fn List.concat(xss: List (List a)) -> List a  — flatten one level of nesting")
    (cons "List.dedupe"         "fn List.dedupe(xs: List a) -> List a  — removes consecutive duplicates")
    (cons "List.intersperse"    "fn List.intersperse(sep: a, xs: List a) -> List a")
    (cons "List.intercalate"    "fn List.intercalate(sep: List a, xss: List (List a)) -> List a")
    (cons "List.groupBy"        "fn List.groupBy(f: a -> b, xs: List a) -> List (List a)  — groups consecutive equal-keyed elements")
    (cons "List.filterCheck"    "fn List.filterCheck(checkFn: check a, xs: List a) -> List a\n\nFilter using a check function. Elements that pass are kept with their proof attached.")
    (cons "List.allCheck"       "fn List.allCheck(checkFn: check a, xs: List a) -> List a\n\nApply a check to every element. Fails if any element fails; returns the list with a ForAll proof.")
    (cons "List.concatMap"      "fn List.concatMap(f: a -> List b, xs: List a) -> List b\n\nMap each element to a list, then flatten one level. Equivalent to concat (map f xs). Also known as flatMap or bind.")
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
    (cons "Set.map"             "fn Set.map(f: a -> b, s: Set) -> Set")
    (cons "Set.filter"          "fn Set.filter(pred: a -> Bool, s: Set) -> Set")
    (cons "Set.foldl"           "fn Set.foldl(f: (b, a) -> b, init: b, s: Set) -> b")
    (cons "Set.any"             "fn Set.any(pred: a -> Bool, s: Set) -> Bool")
    (cons "Set.all"             "fn Set.all(pred: a -> Bool, s: Set) -> Bool")
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
    (cons "envInt"              "fn envInt(name: String, default: Int) -> Maybe Int")
    ;; Tesl.Cli
    (cons "lookupPortArgument"  "fn lookupPortArgument(args: List String) -> Maybe String")
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
        (map diag->lsp (hash-ref (read-json (open-input-string raw)) 'diagnostics '()))))))

(define (run-local-bindings compiler file-path)
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
        (hash-ref (read-json (open-input-string raw)) 'bindings '())))))

(define (run-definition compiler file-path line col)
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
          (and (hash? definition) definition))))))

(define (run-occurrences compiler file-path line col)
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
        (hash-ref (read-json (open-input-string raw)) 'occurrences '())))))

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
     (let* ([dir  (or (path-only disk-path) (current-directory))]
            [tmp  (make-temporary-file "tesl-lsp-~a.tesl" #f dir)])
       (with-output-to-file tmp #:exists 'truncate (lambda () (display text)))
       (let ([diags    (run-check compiler tmp)]
             [bindings (run-local-bindings compiler tmp)])
         (hash-set! local-bindings-cache uri bindings)
         (delete-file tmp)
         (publish-diags! out uri diags)))]))

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

;; ── Document store ────────────────────────────────────────────────────────────

(define docs (make-hash))   ; uri → text
(define local-bindings-cache (make-hash)) ; uri → binding json list

(define (diag->code-action uri text diag)
  (define data (hash-ref diag 'data (hash)))
  (define fix (if (hash? data) (hash-ref data 'fix 'null) 'null))
  (cond
    [(or (eq? fix 'null) (not (hash? fix))) #f]
    [(equal? (hash-ref fix 'kind #f) "replace_line")
     (define line (hash-ref fix 'line 0))
     (define replacement (hash-ref fix 'replacement ""))
     (define lines (if text (string-split text "
") '()))
     (define current-line
       (if (and (>= line 0) (< line (length lines)))
           (list-ref lines line)
           ""))
     (hash 'title (format "Apply fix for ~a" (hash-ref diag 'code "diagnostic"))
           'kind "quickfix"
           'diagnostics (list diag)
           'edit (hash 'changes
                       (hash (uri->json-key uri)
                             (list
                              (hash 'range (hash 'start (hash 'line line 'character 0)
                                                 'end   (hash 'line line 'character (string-length current-line)))
                                    'newText replacement)))))]
    [else #f]))

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

          ;; ── Lifecycle ──────────────────────────────────────────────────────

          [(equal? method "initialize")
           (write-message out
             (hash 'jsonrpc "2.0" 'id id
                   'result (hash 'capabilities
                             (hash 'textDocumentSync  (hash 'openClose #t 'change 1 'save #t)
                                   'hoverProvider      #t
                                   'definitionProvider #t
                                   'referencesProvider #t
                                   'renameProvider     #t
                                   'codeActionProvider #t))))
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
           (let* ([doc     (hash-ref params 'textDocument (hash))]
                  [uri     (hash-ref doc 'uri "")]
                  [path    (uri->path uri)]
                  [changes (hash-ref params 'contentChanges '())]
                  [text    (and (pair? changes) (hash-ref (car changes) 'text #f))])
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
                       [else   #f])])
               (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result 'null)))))
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
                              (let* ([dir (or (path-only source-path) (current-directory))]
                                     [tmp (make-temporary-file "tesl-definition-~a.tesl" #f dir)])
                                (dynamic-wind
                                  void
                                  (lambda ()
                                    (with-output-to-file tmp #:exists 'truncate (lambda () (display text)))
                                    (definition->lsp (run-definition compiler tmp line-num char-num) original-uri tmp))
                                  (lambda ()
                                    (when (file-exists? tmp)
                                      (delete-file tmp)))))
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
                              (let* ([dir (or (path-only source-path) (current-directory))]
                                     [tmp (make-temporary-file "tesl-occurrences-~a.tesl" #f dir)])
                                (dynamic-wind
                                  void
                                  (lambda ()
                                    (with-output-to-file tmp #:exists 'truncate (lambda () (display text)))
                                    (occurrences->lsp (run-occurrences compiler tmp line-num char-num) original-uri tmp))
                                  (lambda ()
                                    (when (file-exists? tmp)
                                      (delete-file tmp)))))
                              (occurrences->lsp (run-occurrences compiler query-path line-num char-num) original-uri query-path))))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result '()))))
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
                              (let* ([dir (or (path-only source-path) (current-directory))]
                                     [tmp (make-temporary-file "tesl-rename-~a.tesl" #f dir)])
                                (dynamic-wind
                                  void
                                  (lambda ()
                                    (with-output-to-file tmp #:exists 'truncate (lambda () (display text)))
                                    (occurrences->workspace-edit (run-occurrences compiler tmp line-num char-num) new-name original-uri tmp))
                                  (lambda ()
                                    (when (file-exists? tmp)
                                      (delete-file tmp)))))
                              (occurrences->workspace-edit (run-occurrences compiler query-path line-num char-num) new-name original-uri query-path))))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result (or result 'null))))
           (loop)]

          [(equal? method "textDocument/codeAction")
           (let* ([doc         (hash-ref params 'textDocument (hash))]
                  [uri         (hash-ref doc 'uri "")]
                  [text        (hash-ref docs uri #f)]
                  [context     (hash-ref params 'context (hash))]
                  [diagnostics (hash-ref context 'diagnostics '())]
                  [actions     (filter values (map (lambda (d) (diag->code-action uri text d)) diagnostics))])
             (write-message out (hash 'jsonrpc "2.0" 'id id 'result actions)))
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
  (check-true (hash-has-key? stdlib-sigs "initTelemetry")))

(module+ main
  (run))
