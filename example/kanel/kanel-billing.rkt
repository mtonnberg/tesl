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
  (only-in tesl/tesl/prelude Int String List Fact)
  (only-in tesl/tesl/time nowMillis time [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/example/kanel/kanel-models ValidOrgId ValidInvoiceId kanelDbRead kanelDbWrite InvoiceStatus Draft Approved Sent Paid Overdue TimeEntry Invoice NewInvoiceRequest)
  (only-in tesl/example/kanel/kanel-auth KanelSession Authenticated checkOrgAdmin checkOrgAdmin-signature)
)


(provide addMinutes InvoiceDraft checkInvoiceDraft createInvoiceHandler getInvoiceHandler listInvoicesHandler approveInvoiceHandler markSentHandler markPaidHandler checkInvoiceDraft-signature addMinutes-signature createInvoiceHandler-signature getInvoiceHandler-signature listInvoicesHandler-signature approveInvoiceHandler-signature markSentHandler-signature markPaidHandler-signature)

(define InvoiceDraft 'InvoiceDraft)

(define-checker
  (checkInvoiceDraft [invoiceId : String])
  #:capabilities [kanelDbRead]
  #:returns [invoiceId : String ::: (InvoiceDraft invoiceId)]
  (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_0 (raw-value found)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "invoice not found" #:http-code 404)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([tesl_case_1 (tesl-dot/runtime inv 'status)]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Draft)) (accept (InvoiceDraft invoiceId) #:value *invoiceId)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Approved)) (reject "invoice is already approved and cannot be modified" #:http-code 422)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Sent)) (reject "invoice has already been sent" #:http-code 422)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Paid)) (reject "invoice has been paid" #:http-code 422)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Overdue)) (reject "invoice is overdue \u2014 contact support" #:http-code 422)])))]))))

(define/pow
  (addMinutes [acc : Integer] [entry : TimeEntry])
  #:returns Integer
  (+ *acc (tesl-dot/runtime entry 'minutes)))

(define-handler
  (createInvoiceHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [req : NewInvoiceRequest])
  #:capabilities [kanelDbRead kanelDbWrite random time]
  #:returns (Exists [invoiceId : String] (? Invoice _entity ::: (FromDb (Id == invoiceId) _entity)))
  (let/check ([tesl_checked_2 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_2]) (let ([entryCount (select-count (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) "")))]) (if (equal? (raw-value entryCount) 0) (reject "no unbilled time entries found for this organization" #:http-code 422) (let ([totalMinutes (select-sum (entity-field-ref TimeEntry 'minutes) (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) "")))]) (let ([invoiceId (generatePrefixedId "inv")]) (call-with-queue-transaction (lambda () (let ([_ (void (update-many! (from TimeEntry) (hash (entity-field-ref TimeEntry 'invoiceId) invoiceId) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) ""))))]) (pack ([invoiceId]) (insert-one! Invoice (hash 'id invoiceId 'orgId orgId 'status Draft 'totalMinutes totalMinutes 'notes (raw-value req.notes) 'createdAt (raw-value (nowMillis)) 'approvedAt (raw-value (tesl_import_Time_secondsToPosix 0)))))))))))))))

(define-handler
  (getInvoiceHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead]
  #:returns Invoice
  (let/check ([tesl_checked_3 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_3]) (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_4 (raw-value found)]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (reject "invoice not found" #:http-code 404)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl_case_4) 'value)]) *inv)]))))))

(define-handler
  (listInvoicesHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List Invoice)
  (let/check ([tesl_checked_5 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_5]) (select-many (from Invoice) (where (==. (entity-field-ref Invoice 'orgId) orgId))))))

(define-handler
  (approveInvoiceHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead kanelDbWrite time]
  #:returns Invoice
  (let/check ([tesl_checked_6 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_6]) (let/check ([tesl_checked_7 (checkInvoiceDraft invoiceId)]) (let ([draftInvoice tesl_checked_7]) (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Approved (entity-field-ref Invoice 'approvedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Invoice 'id) draftInvoice)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))))))))

(define-handler
  (markSentHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead kanelDbWrite]
  #:returns Invoice
  (let/check ([tesl_checked_8 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_8]) (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_9 (raw-value found)]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (reject "invoice not found" #:http-code 404)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (let ([tesl_case_10 (tesl-dot/runtime inv 'status)]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Approved)) (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Sent) (where (==. (entity-field-ref Invoice 'id) invoiceId))))] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Draft)) (reject "invoice must be approved before sending" #:http-code 422)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Sent)) (reject "invoice already sent" #:http-code 422)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Paid)) (reject "invoice already paid" #:http-code 422)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Overdue)) (reject "invoice is overdue" #:http-code 422)])))]))))))

(define-handler
  (markPaidHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [invoiceId : String ::: (ValidInvoiceId invoiceId)])
  #:capabilities [kanelDbRead kanelDbWrite]
  #:returns Invoice
  (let/check ([tesl_checked_11 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_11]) (let ([found (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_12 (raw-value found)]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Nothing)) (reject "invoice not found" #:http-code 404)] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Something)) (let ([inv (hash-ref (adt-value-fields *tesl_case_12) 'value)]) (let ([tesl_case_13 (tesl-dot/runtime inv 'status)]) (cond [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Sent)) (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Paid) (where (==. (entity-field-ref Invoice 'id) invoiceId))))] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Approved)) (reject "invoice must be sent before marking paid" #:http-code 422)] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Draft)) (reject "invoice must be approved and sent before marking paid" #:http-code 422)] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Paid)) (reject "invoice already paid" #:http-code 422)] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Overdue)) (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) Paid) (where (==. (entity-field-ref Invoice 'id) invoiceId))))])))]))))))
