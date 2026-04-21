#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
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
  (tesl_import_String_trim *raw))

(define/pow
  (validateTag [raw : String])
  #:returns (Maybe String)
  (let ([trimmed (tesl_import_String_trim *raw)]) (let ([lower (tesl_import_String_toLower (raw-value trimmed))]) (let ([len (tesl_import_String_length (raw-value lower))]) (if (and (> (raw-value len) 0) (<= (raw-value len) 30)) (raw-value (raw-value (Something (raw-value lower)))) (raw-value Nothing))))))

(define/pow
  (isNonEmpty [s : String])
  #:returns Boolean
  (equal? (raw-value (tesl_import_String_isEmpty *s)) #f))

(define/pow
  (countWords [csv : String])
  #:returns Integer
  (let ([parts (tesl_import_String_split *csv ",")]) (let ([trimmed (tesl_import_List_map tesl_import_String_trim (raw-value parts))]) (raw-value (tesl_import_List_length (raw-value (tesl_import_List_filter isNonEmpty (raw-value trimmed))))))))

(define/pow
  (joinWords [words : (List String)])
  #:returns String
  (raw-value (tesl_import_String_join *words " ")))

(define/pow
  (exampleStringOps)
  #:returns Boolean
  (let ([trimmed (tesl_import_String_trim "  hello  ")]) (let ([upper (tesl_import_String_toUpper "hello")]) (let ([lower (tesl_import_String_toLower "HELLO")]) (let ([parts (tesl_import_String_split "a,b,c" ",")]) (let ([joined (tesl_import_String_join (list "a" "b" "c") "-")]) (let ([padded (tesl_import_String_padLeft "42" 5 "0")]) (let ([replaced (tesl_import_String_replace "hello world" "world" "Tesl")]) (let ([starts (tesl_import_String_startsWith "hello" "hel")]) (let ([ends (tesl_import_String_endsWith "hello" "llo")]) (let ([contains (tesl_import_String_contains "hello world" "world")]) (let ([idx (tesl_import_String_indexOf "hello" "ll")]) (and (raw-value starts) (raw-value ends) (raw-value contains))))))))))))))

(define/pow
  (buildPath [base : String] [resource : String] [id : String])
  #:returns String
  (string-append (string-append (string-append (string-append *base "/") *resource) "/") *id))

(define/pow
  (formatRecord [key : String] [value : String])
  #:returns String
  (string-append (string-append *key ": ") *value))

(define/pow
  (sortedTags [tags : (List String)])
  #:returns (? (List String) _entity ::: (IsSorted _entity))
  (tesl_import_List_sort *tags))

(define/pow
  (double [n : Integer])
  #:returns Integer
  (+ *n *n))

(define/pow
  (isPositive [n : Integer])
  #:returns Boolean
  (> *n 0))

(define/pow
  (addInts [acc : Integer] [x : Integer])
  #:returns Integer
  (+ *acc *x))

(define/pow
  (prependInt [x : Integer] [acc : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_append (list *x) *acc)))

(define/pow
  (doubleAll [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_map double *ns)))

(define/pow
  (positiveOnly [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_filter isPositive *ns)))

(define/pow
  (sumList [ns : (List Integer)])
  #:returns Integer
  (raw-value (tesl_import_List_foldl addInts 0 *ns)))

(define/pow
  (reverseList [ns : (List Integer)])
  #:returns (List Integer)
  (raw-value (tesl_import_List_foldr prependInt (list) *ns)))

(define/pow
  (exampleListOps)
  #:returns Boolean
  (let ([sorted (tesl_import_List_sort (list "c" "a" "b"))]) (let ([mapped (tesl_import_List_map double (list 1 2 3))]) (let ([filtered (tesl_import_List_filter isPositive (list -1 0 1 2))]) (let ([head (raw-value (tesl_import_List_head (list 10 20 30)))]) (let ([summed (raw-value (tesl_import_List_sum (list 1 2 3 4)))]) (let ([unique (tesl_import_List_unique (list 1 2 1 3 2))]) (let ([range (tesl_import_List_range 1 5)]) (let ([hasPos (raw-value (tesl_import_List_any isPositive (list -1 1)))]) (let ([rawCount 2]) (let/check ([tesl_checked_0 (tesl_import_Int_nonNegative rawCount)]) (let ([count tesl_checked_0]) (let ([taken (tesl_import_List_take count (list 10 20 30))]) (let ([dropped (tesl_import_List_drop count (list 10 20 30 40))]) (let ([repeated (tesl_import_List_repeat "tesl" count)]) (and (equal? (raw-value (tesl_import_List_length (raw-value filtered))) 2) (equal? (raw-value summed) 10) (equal? (raw-value (tesl_import_List_length (raw-value taken))) 2) (equal? (raw-value (tesl_import_List_length (raw-value dropped))) 2) (equal? (raw-value (tesl_import_List_length (raw-value repeated))) 2)))))))))))))))))

(define/pow
  (safeDivide [numerator : Integer] [rawDenom : Integer])
  #:returns (Maybe Integer)
  (let/check ([tesl_checked_1 (tesl_import_Int_nonZero rawDenom)]) (let ([denom tesl_checked_1]) (raw-value (Something (tesl_import_Int_divide *numerator denom))))))

(define/pow
  (exampleIntOps)
  #:returns Boolean
  (let ([absVal (raw-value (tesl_import_Int_abs -42))]) (let ([minVal (raw-value (tesl_import_Int_min 3 7))]) (let ([maxVal (raw-value (tesl_import_Int_max 3 7))]) (let ([clamped (raw-value (tesl_import_Int_clamp 15 0 10))]) (let ([powered (raw-value (tesl_import_Int_pow 2 8))]) (let ([str (raw-value (tesl_import_Int_toString 42))]) (let ([sign (raw-value (tesl_import_Int_sign -5))]) (let ([isEven (raw-value (tesl_import_Int_isEven 4))]) (let ([isOdd (raw-value (tesl_import_Int_isOdd 3))]) (and (raw-value isEven) (raw-value isOdd) (equal? (raw-value powered) 256))))))))))))

(module+ test
  (require rackunit)
  (test-case "string basic"
  (check-equal? (raw-value (tesl_import_String_length "hello")) 5)
  (check-equal? (raw-value (tesl_import_String_length "")) 0)
  (check-equal? (raw-value (tesl_import_String_isEmpty "")) #t)
  (check-equal? (raw-value (tesl_import_String_isEmpty "x")) #f)
  )

  (test-case "string trim returns proof"
  (define t (tesl_import_String_trim "  hello  "))
  (check-equal? (raw-value (tesl_import_String_isEmpty (raw-value t))) #f)
  )

  (test-case "string predicates"
  (check-equal? (raw-value (tesl_import_String_startsWith "hello" "hel")) #t)
  (check-equal? (raw-value (tesl_import_String_startsWith "hello" "world")) #f)
  (check-equal? (raw-value (tesl_import_String_endsWith "hello" "llo")) #t)
  (check-equal? (raw-value (tesl_import_String_endsWith "hello" "hel")) #f)
  (check-equal? (raw-value (tesl_import_String_contains "hello world" "world")) #t)
  (check-equal? (raw-value (tesl_import_String_contains "hello world" "xyz")) #f)
  )

  (test-case "string split and join"
  (define parts (tesl_import_String_split "a,b,c" ","))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value parts)))) 3)
  (check-equal? (raw-value (tesl_import_String_join (list "a" "b" "c") ",")) "a,b,c")
  (check-equal? (raw-value (tesl_import_String_join (list "x") "-")) "x")
  )

  (test-case "string pad and replace"
  (check-equal? (raw-value (tesl_import_String_padLeft "42" 5 "0")) "00042")
  (check-equal? (raw-value (tesl_import_String_padRight "hi" 5 " ")) "hi   ")
  (check-equal? (raw-value (tesl_import_String_replace "hello world" "world" "there")) "hello there")
  )

  (test-case "string toInt"
  (check-equal? (raw-value (tesl_import_String_toInt "42")) (raw-value (Something 42)))
  (check-equal? (raw-value (tesl_import_String_toInt "abc")) Nothing)
  (check-equal? (raw-value (tesl_import_String_toInt "-7")) (raw-value (Something -7)))
  )

  (test-case "list basics"
  (check-equal? (raw-value (raw-value (tesl_import_List_length (list 1 2 3)))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_List_length (list)))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (list)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_List_isEmpty (list 1)))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list 10 20)))) (raw-value (Something 10)))
  (check-equal? (raw-value (raw-value (tesl_import_List_head (list)))) Nothing)
  )

  (test-case "list map filter sum"
  (check-equal? (raw-value (tesl_import_List_map double (list 1 2 3))) (list 2 4 6))
  (check-equal? (raw-value (tesl_import_List_filter isPositive (list -1 0 1 2))) (list 1 2))
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list 1 2 3 4)))) 10)
  (check-equal? (raw-value (raw-value (tesl_import_List_sum (list)))) 0)
  )

  (test-case "list sort"
  (define sorted (tesl_import_List_sort (list 3 1 4 1 5)))
  (check-equal? (raw-value (raw-value (tesl_import_List_head (raw-value sorted)))) (raw-value (Something 1)))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value sorted)))) 5)
  )

  (test-case "list range and unique"
  (check-equal? (raw-value (tesl_import_List_range 1 5)) (list 1 2 3 4))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value (tesl_import_List_unique (list 1 2 1 3 2)))))) 3)
  )

  (test-case "int basics"
  (check-equal? (raw-value (raw-value (tesl_import_Int_abs -5))) 5)
  (check-equal? (raw-value (raw-value (tesl_import_Int_abs 5))) 5)
  (check-equal? (raw-value (raw-value (tesl_import_Int_min 3 7))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Int_max 3 7))) 7)
  (check-equal? (raw-value (raw-value (tesl_import_Int_clamp 15 0 10))) 10)
  (check-equal? (raw-value (raw-value (tesl_import_Int_clamp -5 0 10))) 0)
  (check-equal? (raw-value (raw-value (tesl_import_Int_clamp 5 0 10))) 5)
  )

  (test-case "int pow and predicates"
  (check-equal? (raw-value (raw-value (tesl_import_Int_pow 2 10))) 1024)
  (check-equal? (raw-value (raw-value (tesl_import_Int_pow 3 0))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_isEven 4))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Int_isEven 3))) #f)
  (check-equal? (raw-value (raw-value (tesl_import_Int_isOdd 3))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Int_sign 5))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_sign -5))) -1)
  (check-equal? (raw-value (raw-value (tesl_import_Int_sign 0))) 0)
  )

  (test-case "safe division"
  (check-equal? (raw-value (safeDivide 10 2)) (raw-value (Something 5)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (safeDivide 10 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: safeDivide 10 0"))
  (check-equal? (raw-value (safeDivide 7 3)) (raw-value (Something 2)))
  )

  (test-case "count words"
  (check-equal? (raw-value (countWords "hello,world,foo")) 3)
  (check-equal? (raw-value (countWords "a, b ,  c  ")) 3)
  (check-equal? (raw-value (countWords "")) 0)
  )

  (test-case "++ string concatenation"
  (check-equal? (raw-value (buildPath "https://api.example.com" "users" "42")) "https://api.example.com/users/42")
  (check-equal? (raw-value (formatRecord "name" "Alice")) "name: Alice")
  (check-equal? (raw-value (string-append (string-append "a" "b") "c")) "abc")
  (check-equal? (raw-value (string-append "" "hello")) "hello")
  (check-equal? (raw-value (string-append "hello" "")) "hello")
  )

)
