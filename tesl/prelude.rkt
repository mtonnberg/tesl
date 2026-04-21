#lang racket

(require "../dsl/check.rkt"
         "../dsl/web.rkt")

(provide
 Any Bool Boolean True False Bytes Char Hash
 Int Integer Keyword List Null Number
 Fact Real String Symbol Unit Vector
 int integer string
 (rename-out [and-left andLeft]
             [and-right andRight]
             [attach-proof attachFact]
             [detach-proof detachFact]
             [forget-proof forgetFact]
             [intro-and introAnd]))

(define Any 'Any)
(define Bool 'Bool)
(define Boolean 'Boolean)
(define True #t)
(define False #f)
(define Bytes 'Bytes)
(define Char 'Char)
(define Hash 'Hash)
(define Int 'Int)
(define Integer 'Integer)
(define Keyword 'Keyword)
(define List 'List)
(define Null 'Null)
(define Number 'Number)
(define Fact 'Fact)
(define Real 'Real)
(define String 'String)
(define Symbol 'Symbol)
(define Unit 'Unit)
(define Vector 'Vector)

(define int integer-segment)
(define integer integer-segment)
(define string string-segment)
