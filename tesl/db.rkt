#lang racket

(require (only-in "../dsl/sql.rkt" [db-read dbRead] [db-write dbWrite]))
(require (only-in "../dsl/types.rkt" DeleteResult? NoRowDeleted NoRowDeleted? RowsDeleted RowsDeleted? RowsDeleted-count))

(define DeleteResult 'DeleteResult)

(provide dbRead dbWrite
         DeleteResult DeleteResult? NoRowDeleted NoRowDeleted? RowsDeleted RowsDeleted? RowsDeleted-count)
