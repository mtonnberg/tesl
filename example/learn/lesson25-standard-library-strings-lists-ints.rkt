#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.isEmpty tesl_import_String_isEmpty] [String.trim tesl_import_String_trim] [String.toUpper tesl_import_String_toUpper] [String.toLower tesl_import_String_toLower] [String.startsWith tesl_import_String_startsWith] [String.endsWith tesl_import_String_endsWith] [String.contains tesl_import_String_contains] [String.split tesl_import_String_split] [String.join tesl_import_String_join] [String.replace tesl_import_String_replace] [String.toInt tesl_import_String_toInt] [String.padLeft tesl_import_String_padLeft] [String.padRight tesl_import_String_padRight] [String.indexOf tesl_import_String_indexOf] IsTrimmed IsUpperCase IsLowerCase)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.isEmpty tesl_import_List_isEmpty] [List.head tesl_import_List_head] [List.map tesl_import_List_map] [List.filter tesl_import_List_filter] [List.foldl tesl_import_List_foldl] [List.foldr tesl_import_List_foldr] [List.append tesl_import_List_append] [List.sort tesl_import_List_sort] [List.take tesl_import_List_take] [List.drop tesl_import_List_drop] [List.repeat tesl_import_List_repeat] [List.sum tesl_import_List_sum] [List.any tesl_import_List_any] [List.unique tesl_import_List_unique] [List.range tesl_import_List_range] IsSorted)
  (only-in tesl/tesl/int [Int.abs tesl_import_Int_abs] [Int.min tesl_import_Int_min] [Int.max tesl_import_Int_max] [Int.clamp tesl_import_Int_clamp] [Int.isEven tesl_import_Int_isEven] [Int.isOdd tesl_import_Int_isOdd] [Int.pow tesl_import_Int_pow] [Int.toString tesl_import_Int_toString] [Int.sign tesl_import_Int_sign] [Int.nonZero tesl_import_Int_nonZero] [Int.nonNegative tesl_import_Int_nonNegative] [Int.divide tesl_import_Int_divide] IsNonZero)
)


(provide exampleStringOps exampleListOps exampleIntOps countWords joinWords sortedTags safeDivide buildPath formatRecord countWords-signature joinWords-signature exampleStringOps-signature buildPath-signature formatRecord-signature sortedTags-signature exampleListOps-signature safeDivide-signature exampleIntOps-signature)

(define/pow
  (normalizeName [raw : String])
  #:returns (? String _entity ::: (IsTrimmed _entity))
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 107 (list (cons 'raw *raw)) (lambda () (tesl_import_String_trim *raw))))

(define/pow
  (validateTag [raw : String])
  #:returns (Maybe String)
  (let ([trimmed (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 111 (list (cons 'raw *raw)) (lambda () (tesl_import_String_trim *raw)))]) (let ([lower (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 112 (list (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (tesl_import_String_toLower (raw-value trimmed))))]) (let ([len (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 113 (list (cons 'lower *lower) (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (tesl_import_String_length (raw-value lower))))]) (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 114 (list (cons 'len *len) (cons 'lower *lower) (cons 'trimmed *trimmed) (cons 'raw *raw)) (lambda () (if (and (> (raw-value len) 0) (<= (raw-value len) 30)) (raw-value (raw-value (Something (raw-value lower)))) (raw-value Nothing))))))))

(define/pow
  (isNonEmpty [s : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 121 (list (cons 's *s)) (lambda () (equal? (raw-value (tesl_import_String_isEmpty *s)) #f))))

(define/pow
  (countWords [csv : String])
  #:returns Integer
  (let ([parts (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 125 (list (cons 'csv *csv)) (lambda () (tesl_import_String_split *csv ",")))]) (let ([trimmed (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 126 (list (cons 'parts *parts) (cons 'csv *csv)) (lambda () (tesl_import_List_map tesl_import_String_trim (raw-value parts))))]) (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 127 (list (cons 'trimmed *trimmed) (cons 'parts *parts) (cons 'csv *csv)) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_List_filter isNonEmpty (raw-value trimmed))))))))))

(define/pow
  (joinWords [words : (List String)])
  #:returns String
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 130 (list (cons 'words *words)) (lambda () (raw-value (tesl_import_String_join *words " ")))))

(define/pow
  (exampleStringOps)
  #:returns Boolean
  (let ([trimmed (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 133 (list) (lambda () (tesl_import_String_trim "  hello  ")))]) (let ([upper (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 134 (list (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_toUpper "hello")))]) (let ([lower (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 135 (list (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_toLower "HELLO")))]) (let ([parts (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 136 (list (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_split "a,b,c" ",")))]) (let ([joined (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 137 (list (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_join (list "a" "b" "c") "-")))]) (let ([padded (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 138 (list (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_padLeft "42" 5 "0")))]) (let ([replaced (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 139 (list (cons 'padded *padded) (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_replace "hello world" "world" "Tesl")))]) (let ([starts (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 140 (list (cons 'replaced *replaced) (cons 'padded *padded) (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_startsWith "hello" "hel")))]) (let ([ends (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 141 (list (cons 'starts *starts) (cons 'replaced *replaced) (cons 'padded *padded) (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_endsWith "hello" "llo")))]) (let ([contains (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 142 (list (cons 'ends *ends) (cons 'starts *starts) (cons 'replaced *replaced) (cons 'padded *padded) (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_contains "hello world" "world")))]) (let ([idx (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 143 (list (cons 'contains *contains) (cons 'ends *ends) (cons 'starts *starts) (cons 'replaced *replaced) (cons 'padded *padded) (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (tesl_import_String_indexOf "hello" "ll")))]) (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 144 (list (cons 'idx *idx) (cons 'contains *contains) (cons 'ends *ends) (cons 'starts *starts) (cons 'replaced *replaced) (cons 'padded *padded) (cons 'joined *joined) (cons 'parts *parts) (cons 'lower *lower) (cons 'upper *upper) (cons 'trimmed *trimmed)) (lambda () (and (raw-value starts) (raw-value ends) (raw-value contains))))))))))))))))

(define/pow
  (buildPath [base : String] [resource : String] [id : String])
  #:returns String
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 157 (list (cons 'base *base) (cons 'resource *resource) (cons 'id *id)) (lambda () (string-append (string-append (string-append (string-append *base "/") *resource) "/") *id))))

(define/pow
  (formatRecord [key : String] [value : String])
  #:returns String
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 161 (list (cons 'key *key) (cons 'value *value)) (lambda () (string-append (string-append *key ": ") *value))))

(define/pow
  (sortedTags [tags : (List String)])
  #:returns (? (List String) _entity ::: (IsSorted _entity))
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 168 (list (cons 'tags *tags)) (lambda () (tesl_import_List_sort *tags))))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 172 (list (cons 'n *n)) (lambda () (+ *n *n))))

(define/pow
  (isPositive [n : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 175 (list (cons 'n *n)) (lambda () (> *n 0))))

(define/pow
  (addInts [acc : Integer] [x : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 178 (list (cons 'acc *acc) (cons 'x *x)) (lambda () (+ *acc *x))))

(define/pow
  (prependInt [x : Integer] [acc : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 181 (list (cons 'x *x) (cons 'acc *acc)) (lambda () (raw-value (tesl_import_List_append (list *x) *acc)))))

(define/pow
  (doubleAll [ns : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 185 (list (cons 'ns *ns)) (lambda () (raw-value (tesl_import_List_map double *ns)))))

(define/pow
  (positiveOnly [ns : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 189 (list (cons 'ns *ns)) (lambda () (raw-value (tesl_import_List_filter isPositive *ns)))))

(define/pow
  (sumList [ns : (List Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 193 (list (cons 'ns *ns)) (lambda () (raw-value (tesl_import_List_foldl addInts 0 *ns)))))

(define/pow
  (reverseList [ns : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 197 (list (cons 'ns *ns)) (lambda () (raw-value (tesl_import_List_foldr prependInt (list) *ns)))))

(define/pow
  (exampleListOps)
  #:returns Boolean
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 200 (list) (lambda () (let ([sorted (tesl_import_List_sort (list "c" "a" "b"))]) (let ([mapped (tesl_import_List_map double (list 1 2 3))]) (let ([filtered (tesl_import_List_filter isPositive (list -1 0 1 2))]) (let ([head (raw-value (tesl_import_List_head (list 10 20 30)))]) (let ([summed (raw-value (tesl_import_List_sum (list 1 2 3 4)))]) (let ([unique (tesl_import_List_unique (list 1 2 1 3 2))]) (let ([range (tesl_import_List_range 1 5)]) (let ([hasPos (raw-value (tesl_import_List_any isPositive (list -1 1)))]) (let ([rawCount 2]) (let/check ([tesl-checked-0 (tesl_import_Int_nonNegative rawCount)]) (let ([count tesl-checked-0]) (let ([taken (tesl_import_List_take count (list 10 20 30))]) (let ([dropped (tesl_import_List_drop count (list 10 20 30 40))]) (let ([repeated (tesl_import_List_repeat "tesl" count)]) (and (equal? (raw-value (tesl_import_List_length (raw-value filtered))) 2) (equal? (raw-value summed) 10) (equal? (raw-value (tesl_import_List_length (raw-value taken))) 2) (equal? (raw-value (tesl_import_List_length (raw-value dropped))) 2) (equal? (raw-value (tesl_import_List_length (raw-value repeated))) 2)))))))))))))))))))

(define/pow
  (safeDivide [numerator : Integer] [rawDenom : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 223 (list (cons 'numerator *numerator) (cons 'rawDenom *rawDenom)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Int_nonZero rawDenom)]) (let ([denom tesl-checked-1]) (raw-value (Something (tesl_import_Int_divide *numerator denom))))))))

(define/pow
  (exampleIntOps)
  #:returns Boolean
  (let ([absVal (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 227 (list) (lambda () (raw-value (tesl_import_Int_abs -42))))]) (let ([minVal (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 228 (list (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_min 3 7))))]) (let ([maxVal (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 229 (list (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_max 3 7))))]) (let ([clamped (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 230 (list (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_clamp 15 0 10))))]) (let ([powered (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 231 (list (cons 'clamped *clamped) (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_pow 2 8))))]) (let ([str (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 232 (list (cons 'powered *powered) (cons 'clamped *clamped) (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_toString 42))))]) (let ([sign (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 233 (list (cons 'str *str) (cons 'powered *powered) (cons 'clamped *clamped) (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_sign -5))))]) (let ([isEven (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 234 (list (cons 'sign *sign) (cons 'str *str) (cons 'powered *powered) (cons 'clamped *clamped) (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_isEven 4))))]) (let ([isOdd (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 235 (list (cons 'isEven *isEven) (cons 'sign *sign) (cons 'str *str) (cons 'powered *powered) (cons 'clamped *clamped) (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (raw-value (tesl_import_Int_isOdd 3))))]) (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 236 (list (cons 'isOdd *isOdd) (cons 'isEven *isEven) (cons 'sign *sign) (cons 'str *str) (cons 'powered *powered) (cons 'clamped *clamped) (cons 'maxVal *maxVal) (cons 'minVal *minVal) (cons 'absVal *absVal)) (lambda () (and (raw-value isEven) (raw-value isOdd) (equal? (raw-value powered) 256))))))))))))))

(module+ test
  (require rackunit)
  (test-case "string basic"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 314 (list) (lambda () (tesl_import_String_length "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 315 (list) (lambda () (tesl_import_String_length "")))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 316 (list) (lambda () (tesl_import_String_isEmpty "")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 317 (list) (lambda () (tesl_import_String_isEmpty "x")))) #f)
  )

  (test-case "string trim returns proof"
  (define t (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 321 (list) (lambda () (tesl_import_String_trim "  hello  "))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 322 (list (cons 't t)) (lambda () (tesl_import_String_isEmpty (raw-value t))))) #f)
  )

  (test-case "string predicates"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 326 (list) (lambda () (tesl_import_String_startsWith "hello" "hel")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 327 (list) (lambda () (tesl_import_String_startsWith "hello" "world")))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 328 (list) (lambda () (tesl_import_String_endsWith "hello" "llo")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 329 (list) (lambda () (tesl_import_String_endsWith "hello" "hel")))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 330 (list) (lambda () (tesl_import_String_contains "hello world" "world")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 331 (list) (lambda () (tesl_import_String_contains "hello world" "xyz")))) #f)
  )

  (test-case "string split and join"
  (define parts (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 335 (list) (lambda () (tesl_import_String_split "a,b,c" ","))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 336 (list (cons 'parts parts)) (lambda () (raw-value (tesl_import_List_length (raw-value parts)))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 337 (list (cons 'parts parts)) (lambda () (tesl_import_String_join (list "a" "b" "c") ",")))) "a,b,c")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 338 (list (cons 'parts parts)) (lambda () (tesl_import_String_join (list "x") "-")))) "x")
  )

  (test-case "string pad and replace"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 342 (list) (lambda () (tesl_import_String_padLeft "42" 5 "0")))) "00042")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 343 (list) (lambda () (tesl_import_String_padRight "hi" 5 " ")))) "hi   ")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 344 (list) (lambda () (tesl_import_String_replace "hello world" "world" "there")))) "hello there")
  )

  (test-case "string toInt"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 348 (list) (lambda () (tesl_import_String_toInt "42")))) (raw-value (Something 42)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 349 (list) (lambda () (tesl_import_String_toInt "abc")))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 350 (list) (lambda () (tesl_import_String_toInt "-7")))) (raw-value (Something -7)))
  )

  (test-case "list basics"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 354 (list) (lambda () (raw-value (tesl_import_List_length (list 1 2 3)))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 355 (list) (lambda () (raw-value (tesl_import_List_length (list)))))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 356 (list) (lambda () (raw-value (tesl_import_List_isEmpty (list)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 357 (list) (lambda () (raw-value (tesl_import_List_isEmpty (list 1)))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 358 (list) (lambda () (raw-value (tesl_import_List_head (list 10 20)))))) (raw-value (Something 10)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 359 (list) (lambda () (raw-value (tesl_import_List_head (list)))))) Nothing)
  )

  (test-case "list map filter sum"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 363 (list) (lambda () (tesl_import_List_map double (list 1 2 3))))) (list 2 4 6))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 364 (list) (lambda () (tesl_import_List_filter isPositive (list -1 0 1 2))))) (list 1 2))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 365 (list) (lambda () (raw-value (tesl_import_List_sum (list 1 2 3 4)))))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 366 (list) (lambda () (raw-value (tesl_import_List_sum (list)))))) 0)
  )

  (test-case "list sort"
  (define sorted (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 370 (list) (lambda () (tesl_import_List_sort (list 3 1 4 1 5)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 371 (list (cons 'sorted sorted)) (lambda () (raw-value (tesl_import_List_head (raw-value sorted)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 372 (list (cons 'sorted sorted)) (lambda () (raw-value (tesl_import_List_length (raw-value sorted)))))) 5)
  )

  (test-case "list range and unique"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 376 (list) (lambda () (tesl_import_List_range 1 5)))) (list 1 2 3 4))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 377 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_List_unique (list 1 2 1 3 2)))))))) 3)
  )

  (test-case "int basics"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 381 (list) (lambda () (raw-value (tesl_import_Int_abs -5))))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 382 (list) (lambda () (raw-value (tesl_import_Int_abs 5))))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 383 (list) (lambda () (raw-value (tesl_import_Int_min 3 7))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 384 (list) (lambda () (raw-value (tesl_import_Int_max 3 7))))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 385 (list) (lambda () (raw-value (tesl_import_Int_clamp 15 0 10))))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 386 (list) (lambda () (raw-value (tesl_import_Int_clamp -5 0 10))))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 387 (list) (lambda () (raw-value (tesl_import_Int_clamp 5 0 10))))) 5)
  )

  (test-case "int pow and predicates"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 391 (list) (lambda () (raw-value (tesl_import_Int_pow 2 10))))) 1024)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 392 (list) (lambda () (raw-value (tesl_import_Int_pow 3 0))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 393 (list) (lambda () (raw-value (tesl_import_Int_isEven 4))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 394 (list) (lambda () (raw-value (tesl_import_Int_isEven 3))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 395 (list) (lambda () (raw-value (tesl_import_Int_isOdd 3))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 396 (list) (lambda () (raw-value (tesl_import_Int_sign 5))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 397 (list) (lambda () (raw-value (tesl_import_Int_sign -5))))) -1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 398 (list) (lambda () (raw-value (tesl_import_Int_sign 0))))) 0)
  )

  (test-case "safe division"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 402 (list) (lambda () (safeDivide 10 2)))) (raw-value (Something 5)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 403 (list) (lambda ()
                          (safeDivide 10 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: safeDivide 10 0"))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 404 (list) (lambda () (safeDivide 7 3)))) (raw-value (Something 2)))
  )

  (test-case "count words"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 408 (list) (lambda () (countWords "hello,world,foo")))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 409 (list) (lambda () (countWords "a, b ,  c  ")))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 410 (list) (lambda () (countWords "")))) 0)
  )

  (test-case "++ string concatenation"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 414 (list) (lambda () (buildPath "https://api.example.com" "users" "42")))) "https://api.example.com/users/42")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 415 (list) (lambda () (formatRecord "name" "Alice")))) "name: Alice")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 417 (list) (lambda () (string-append (string-append "a" "b") "c")))) "abc")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 419 (list) (lambda () (string-append "" "hello")))) "hello")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson25-standard-library-strings-lists-ints.tesl" 420 (list) (lambda () (string-append "hello" "")))) "hello")
  )

)
