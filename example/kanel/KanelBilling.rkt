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
  (only-in tesl/tesl/prelude Int String List Fact)
  (only-in tesl/tesl/time nowMillis time [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in (file "kanel-models.rkt") ValidOrgId ValidInvoiceId kanelDbRead kanelDbWrite InvoiceStatus Draft Approved Sent Paid Overdue TimeEntry Invoice NewInvoiceRequest)
  (only-in (file "kanel-auth.rkt") KanelSession Authenticated checkOrgAdmin checkOrgAdmin-signature)
)


(provide addMinutes InvoiceDraft checkInvoiceDraft createInvoiceHandler getInvoiceHandler listInvoicesHandler approveInvoiceHandler markSentHandler markPaidHandler checkInvoiceDraft-signature addMinutes-signature createInvoiceHandler-signature getInvoiceHandler-signature listInvoicesHandler-signature approveInvoiceHandler-signature markSentHandler-signature markPaidHandler-signature)

(define InvoiceDraft 'InvoiceDraft)

(define-checker
  (checkInvoiceDraft [invoiceId : String])
  #:capabilities [kanelDbRead]
  #:returns [invoiceId : String ::: (InvoiceDraft invoiceId)]
  (let ([found (thsl-src! "example/kanel/KanelBilling.tesl" 49 (list (cons 'invoiceId *invoiceId)) (lambda () (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/kanel/KanelBilling.tesl" 50 (list (cons 'found *found) (cons 'invoiceId *invoiceId)) (lambda () (let ([tesl-case-0 (raw-value found)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/kanel/KanelBilling.tesl" 51 (list) (lambda () (reject "invoice not found" #:http-code 404)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/kanel/KanelBilling.tesl" 53 (list (cons 'inv inv)) (lambda () (let ([tesl-case-1 (tesl-dot/runtime inv 'status)]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Draft)) (thsl-src! "example/kanel/KanelBilling.tesl" 54 (list) (lambda () (accept (InvoiceDraft invoiceId) #:value *invoiceId)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Approved)) (thsl-src! "example/kanel/KanelBilling.tesl" 55 (list) (lambda () (reject "invoice is already approved and cannot be modified" #:http-code 422)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Sent)) (thsl-src! "example/kanel/KanelBilling.tesl" 56 (list) (lambda () (reject "invoice has already been sent" #:http-code 422)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Paid)) (thsl-src! "example/kanel/KanelBilling.tesl" 57 (list) (lambda () (reject "invoice has been paid" #:http-code 422)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Overdue)) (thsl-src! "example/kanel/KanelBilling.tesl" 58 (list) (lambda () (reject "invoice is overdue \u2014 contact support" #:http-code 422)))])))))]))))))

(define/pow
  (addMinutes [acc : Integer] [entry : TimeEntry])
  #:returns Integer
  (thsl-src! "example/kanel/KanelBilling.tesl" 63 (list (cons 'acc *acc) (cons 'entry *entry)) (lambda () (+ *acc (tesl-dot/runtime entry 'minutes)))))

(define-handler
  (createInvoiceHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [req : NewInvoiceRequest])
  #:capabilities [kanelDbRead kanelDbWrite random time]
  #:returns (Exists [invoiceId : String] (? Invoice _entity ::: (FromDb (Id == invoiceId) _entity)))
  (thsl-src! "example/kanel/KanelBilling.tesl" 73 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'req *req)) (lambda () (let/check ([tesl-checked-2 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl-checked-2]) (let ([entryCount (select-count (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) "")))]) (if (equal? (raw-value entryCount) 0) (reject "no unbilled time entries found for this organization" #:http-code 422) (let ([totalMinutes (select-sum (entity-field-ref TimeEntry 'minutes) (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) "")))]) (let ([invoiceId (generatePrefixedId "inv")]) (call-with-queue-transaction (lambda () (let ([_ (void (update-many! (from TimeEntry) (hash (entity-field-ref TimeEntry 'invoiceId) invoiceId) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) ""))))]) (pack ([invoiceId]) (insert-one! Invoice (hash 'id invoiceId 'orgId orgId 'status Draft 'totalMinutes totalMinutes 'notes (raw-value req.notes) 'createdAt (raw-value (nowMillis)) 'approvedAt (raw-value (tesl_import_Time_secondsToPosix 0)))))))))))))))))

(define-handler
  (getInvoiceHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead]
  #:returns Invoice
  (thsl-src! "example/kanel/KanelBilling.tesl" 104 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'invoiceId *invoiceId)) (lambda () (let/check ([tesl-checked-3 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl-checked-3]) (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-4 (raw-value found)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/kanel/KanelBilling.tesl" 107 (list) (lambda () (reject "invoice not found" #:http-code 404)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/kanel/KanelBilling.tesl" 108 (list (cons 'inv inv)) (lambda () *inv)))]))))))))

(define-handler
  (listInvoicesHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List Invoice)
  (thsl-src! "example/kanel/KanelBilling.tesl" 115 (list (cons 'session *session) (cons 'orgId *orgId)) (lambda () (let/check ([tesl-checked-5 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl-checked-5]) (select-many (from Invoice) (where (==. (entity-field-ref Invoice 'orgId) orgId))))))))

(define-handler
  (approveInvoiceHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead kanelDbWrite time]
  #:returns Invoice
  (thsl-src! "example/kanel/KanelBilling.tesl" 124 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'invoiceId *invoiceId)) (lambda () (let/check ([tesl-checked-6 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl-checked-6]) (let/check ([tesl-checked-7 (checkInvoiceDraft invoiceId)]) (let ([draftInvoice tesl-checked-7]) (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Approved (entity-field-ref Invoice 'approvedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Invoice 'id) draftInvoice)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))))))))))

(define-handler
  (markSentHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead kanelDbWrite]
  #:returns Invoice
  (thsl-src! "example/kanel/KanelBilling.tesl" 138 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'invoiceId *invoiceId)) (lambda () (let/check ([tesl-checked-8 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl-checked-8]) (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-9 (raw-value found)]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "example/kanel/KanelBilling.tesl" 141 (list) (lambda () (reject "invoice not found" #:http-code 404)))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "example/kanel/KanelBilling.tesl" 143 (list (cons 'inv inv)) (lambda () (let ([tesl-case-10 (tesl-dot/runtime inv 'status)]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Approved)) (thsl-src! "example/kanel/KanelBilling.tesl" 145 (list) (lambda () (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Sent) (where (==. (entity-field-ref Invoice 'id) invoiceId))))))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Draft)) (thsl-src! "example/kanel/KanelBilling.tesl" 149 (list) (lambda () (reject "invoice must be approved before sending" #:http-code 422)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Sent)) (thsl-src! "example/kanel/KanelBilling.tesl" 150 (list) (lambda () (reject "invoice already sent" #:http-code 422)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Paid)) (thsl-src! "example/kanel/KanelBilling.tesl" 151 (list) (lambda () (reject "invoice already paid" #:http-code 422)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Overdue)) (thsl-src! "example/kanel/KanelBilling.tesl" 152 (list) (lambda () (reject "invoice is overdue" #:http-code 422)))])))))]))))))))

(define-handler
  (markPaidHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead kanelDbWrite]
  #:returns Invoice
  (thsl-src! "example/kanel/KanelBilling.tesl" 160 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'invoiceId *invoiceId)) (lambda () (let/check ([tesl-checked-11 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl-checked-11]) (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-12 (raw-value found)]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing)) (thsl-src! "example/kanel/KanelBilling.tesl" 163 (list) (lambda () (reject "invoice not found" #:http-code 404)))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "example/kanel/KanelBilling.tesl" 165 (list (cons 'inv inv)) (lambda () (let ([tesl-case-13 (tesl-dot/runtime inv 'status)]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Sent)) (thsl-src! "example/kanel/KanelBilling.tesl" 167 (list) (lambda () (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Paid) (where (==. (entity-field-ref Invoice 'id) invoiceId))))))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Approved)) (thsl-src! "example/kanel/KanelBilling.tesl" 171 (list) (lambda () (reject "invoice must be sent before marking paid" #:http-code 422)))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Draft)) (thsl-src! "example/kanel/KanelBilling.tesl" 172 (list) (lambda () (reject "invoice must be approved and sent before marking paid" #:http-code 422)))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Paid)) (thsl-src! "example/kanel/KanelBilling.tesl" 173 (list) (lambda () (reject "invoice already paid" #:http-code 422)))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Overdue)) (thsl-src! "example/kanel/KanelBilling.tesl" 175 (list) (lambda () (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Paid) (where (==. (entity-field-ref Invoice 'id) invoiceId))))))])))))]))))))))
