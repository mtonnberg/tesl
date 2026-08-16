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
  (only-in tesl/tesl/prelude Bool String Unit List)
  (only-in tesl/tesl/env env envInt envRead)
  (only-in tesl/tesl/time time [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/queue queueRead queueWrite pubsub FromQueue FromDeadQueue)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim])
  (only-in tesl/tesl/api-test statusOk statusClientError jsonInt jsonString jsonBool jsonLength isNull isNotNull includesWhere excludesWhere hasLength isNotEmpty arrayAt hasField fieldAt bodyField jsonContains subscribe collect JobResult JobOk JobFailed processNextJob processNextDeadJob pendingJobCount expectJobOk expectJobFailed)
  (only-in (file "KanelModels.rkt") kanelDbRead kanelDbWrite kanelQueue kanelPubSub KanelUser Org OrgMembership Project ProjectMembership Issue IssueComment TimeEntry Invoice OrgRole RoleAdmin RoleMember RoleViewer IssueStatus Backlog Todo InProgress InReview Done Cancelled NewCommentRequest NewOrgRequest NewProjectRequest NewIssueRequest UpdateIssueRequest UpdateStatusRequest NewTimeEntryRequest NewInvoiceRequest ValidOrgId checkOrgId ValidProjectId checkProjectId ValidIssueId checkIssueId ValidInvoiceId checkInvoiceId ValidUserId checkUserId checkTargetUserId checkOrgId-signature checkProjectId-signature checkIssueId-signature checkInvoiceId-signature checkUserId-signature checkTargetUserId-signature)
  (only-in (file "KanelAuth.rkt") KanelSession Authenticated cookieAuth checkOrgMember cookieAuth-signature checkOrgMember-signature)
  (only-in (file "KanelOrg.rkt") RegisterRequest LoginRequest InviteMemberRequest ChangeMemberRoleRequest registerHandler loginHandler createOrgHandler getOrgHandler listOrgMembersHandler inviteMemberHandler changeMemberRoleHandler removeMemberHandler listMyOrgsHandler registerHandler-signature loginHandler-signature createOrgHandler-signature getOrgHandler-signature listOrgMembersHandler-signature inviteMemberHandler-signature changeMemberRoleHandler-signature removeMemberHandler-signature listMyOrgsHandler-signature)
  (only-in (file "KanelIssues.rkt") checkCommentBody insertCommentBody checkNotDone createProjectHandler listProjectsHandler getProjectHandler archiveProjectHandler createIssueHandler listIssuesHandler getIssueHandler updateIssueHandler updateIssueStatusHandler listCommentsHandler logTimeHandler listTimeEntriesHandler checkCommentBody-signature insertCommentBody-signature checkNotDone-signature createProjectHandler-signature listProjectsHandler-signature getProjectHandler-signature archiveProjectHandler-signature createIssueHandler-signature listIssuesHandler-signature getIssueHandler-signature updateIssueHandler-signature updateIssueStatusHandler-signature listCommentsHandler-signature logTimeHandler-signature listTimeEntriesHandler-signature)
  (only-in (file "KanelBilling.rkt") createInvoiceHandler getInvoiceHandler listInvoicesHandler approveInvoiceHandler markSentHandler markPaidHandler createInvoiceHandler-signature getInvoiceHandler-signature listInvoicesHandler-signature approveInvoiceHandler-signature markSentHandler-signature markPaidHandler-signature)
)


(provide KanelServer)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/kanel/KanelBackend.tesl" '(408 412))
(define-database KanelDatabase
  #:backend postgres
  #:database (tesl-env-raw "KANEL_DB")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:schema kanel
  #:entities KanelUser Org OrgMembership Project ProjectMembership Issue IssueComment TimeEntry Invoice)

(define-record KanelNotifyJob
  [recipientUserId : String]
  [recipientEmail : String]
  [subject : String]
  [body : String]
)

(define-queue KanelNotifyQueue
  #:database KanelDatabase
  #:job-types (KanelNotifyJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 30)

(define-capability notifyWorkerCap (implies queueRead))

(define-adt UserNotificationEvent
  [NotificationDelivered [recipientEmail : String] [subject : String]]
  [NotificationFailed [recipientEmail : String] [subject : String]]
)

(define-channel UserNotifications)

(define/pow
  (notifyWorker [job : KanelNotifyJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [notifyWorkerCap kanelPubSub]
  #:returns KanelNotifyJob
  (thsl-src! "example/kanel/KanelBackend.tesl" 194 (list (cons 'job *job)) (lambda () (if (tesl-equal? (raw-value (tesl-dot/runtime job 'recipientEmail 'KanelNotifyJob)) "blocked@example.com") (reject "notifications blocked for recipient" #:http-code 500) (begin (publish-event! UserNotifications (format "~a" (tesl-dot/runtime job 'recipientUserId 'KanelNotifyJob)) (NotificationDelivered (tesl-dot/runtime job 'recipientEmail 'KanelNotifyJob) (tesl-dot/runtime job 'subject 'KanelNotifyJob))) job)))))

(define/pow
  (deadNotifyWorker [job : KanelNotifyJob ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [notifyWorkerCap kanelPubSub]
  #:returns KanelNotifyJob
  (let ([_ (thsl-src! "example/kanel/KanelBackend.tesl" 202 (list (cons 'job *job)) (lambda () (publish-event! UserNotifications (format "~a" (tesl-dot/runtime job 'recipientUserId 'KanelNotifyJob)) (NotificationFailed (tesl-dot/runtime job 'recipientEmail 'KanelNotifyJob) (tesl-dot/runtime job 'subject 'KanelNotifyJob)))))]) (thsl-src! "example/kanel/KanelBackend.tesl" 203 (list (cons 'job *job)) (lambda () *job))))

(define-capture orgCapture
  [orgId : String ::: (ValidOrgId orgId)]
  #:parser string-segment #:check checkOrgId)

(define-capture projectCapture
  [projectId : String ::: (ValidProjectId projectId)]
  #:parser string-segment #:check checkProjectId)

(define-capture issueCapture
  [issueId : String ::: (ValidIssueId issueId)]
  #:parser string-segment #:check checkIssueId)

(define-capture invoiceCapture
  [invoiceId : String ::: (ValidInvoiceId invoiceId)]
  #:parser string-segment #:check checkInvoiceId)

(define-capture userCapture
  [userId : String ::: (ValidUserId userId)]
  #:parser string-segment #:check checkUserId)

(define-capture targetUserCapture
  [targetUserId : String ::: (ValidUserId targetUserId)]
  #:parser string-segment #:check checkTargetUserId)

(define KanelServer-sse-routes
  (list (list (list "events" "users" #f) cookieAuth UserNotifications 2 (list (cons 2 (sse-key-capture userCapture))))))
(define-api KanelApi
  [registerHandler :
    "auth"
    :> "register"
    :> (ReqBody JSON [req : RegisterRequest])
    :> (Post JSON (Exists [userId : String] (? KanelUser _entity ::: (FromDb (Id == userId) _entity))))
    ]
  [loginHandler :
    "auth"
    :> "login"
    :> (ReqBody JSON [req : LoginRequest])
    :> (Post JSON String)
    ]
  [createOrgHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (ReqBody JSON [req : NewOrgRequest])
    :> (Post JSON (Exists [orgId : String] (? Org _entity ::: (FromDb (Id == orgId) _entity))))
    ]
  [listMyOrgsHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Get JSON (List Org))
    ]
  [getOrgHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> (Get JSON Org)
    ]
  [listOrgMembersHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "members"
    :> (Get JSON (List OrgMembership))
    ]
  [inviteMemberHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "members"
    :> (ReqBody JSON [req : InviteMemberRequest])
    :> (Post JSON (Exists [memberId : String] (? OrgMembership _entity ::: (FromDb (Id == memberId) _entity))))
    ]
  [changeMemberRoleHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "members"
    :> (Capture targetUserCapture [targetUserId : String ::: (ValidUserId targetUserId)])
    :> "role"
    :> (ReqBody JSON [req : ChangeMemberRoleRequest])
    :> (Put JSON OrgMembership)
    ]
  [removeMemberHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "members"
    :> (Capture targetUserCapture [targetUserId : String ::: (ValidUserId targetUserId)])
    :> (Delete JSON String)
    ]
  [createProjectHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "projects"
    :> (ReqBody JSON [req : NewProjectRequest])
    :> (Post JSON (Exists [projectId : String] (? Project _entity ::: (FromDb (Id == projectId) _entity))))
    ]
  [listProjectsHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "projects"
    :> (Get JSON (List Project))
    ]
  [getProjectHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "projects"
    :> (Capture projectCapture [projectId : String ::: (ValidProjectId projectId)])
    :> (Get JSON Project)
    ]
  [archiveProjectHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "projects"
    :> (Capture projectCapture [projectId : String ::: (ValidProjectId projectId)])
    :> "archive"
    :> (Put JSON Project)
    ]
  [createIssueHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "projects"
    :> (Capture projectCapture [projectId : String ::: (ValidProjectId projectId)])
    :> "issues"
    :> (ReqBody JSON [req : NewIssueRequest])
    :> (Post JSON (Exists [issueId : String] (? Issue _entity ::: (FromDb (Id == issueId) _entity))))
    ]
  [listIssuesHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "projects"
    :> (Capture projectCapture [projectId : String ::: (ValidProjectId projectId)])
    :> "issues"
    :> (Get JSON (List Issue))
    ]
  [getIssueHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> (Get JSON Issue)
    ]
  [updateIssueHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> (ReqBody JSON [req : UpdateIssueRequest])
    :> (Put JSON Issue)
    ]
  [updateIssueStatusHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> "status"
    :> (ReqBody JSON [req : UpdateStatusRequest])
    :> (Put JSON Issue)
    ]
  [addCommentAndNotifyHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> "comments"
    :> (ReqBody JSON [req : NewCommentRequest])
    :> (Post JSON (Exists [commentId : String] (? IssueComment _entity ::: (FromDb (Id == commentId) _entity))))
    ]
  [listCommentsHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> "comments"
    :> (Get JSON (List IssueComment))
    ]
  [logTimeHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> "time"
    :> (ReqBody JSON [req : NewTimeEntryRequest])
    :> (Post JSON (Exists [entryId : String] (? TimeEntry _entity ::: (FromDb (Id == entryId) _entity))))
    ]
  [listTimeEntriesHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "issues"
    :> (Capture issueCapture [issueId : String ::: (ValidIssueId issueId)])
    :> "time"
    :> (Get JSON (List TimeEntry))
    ]
  [createInvoiceHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "invoices"
    :> (ReqBody JSON [req : NewInvoiceRequest])
    :> (Post JSON (Exists [invoiceId : String] (? Invoice _entity ::: (FromDb (Id == invoiceId) _entity))))
    ]
  [listInvoicesHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "invoices"
    :> (Get JSON (List Invoice))
    ]
  [getInvoiceHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "invoices"
    :> (Capture invoiceCapture [invoiceId : String ::: (ValidInvoiceId invoiceId)])
    :> (Get JSON Invoice)
    ]
  [approveInvoiceHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "invoices"
    :> (Capture invoiceCapture [invoiceId : String ::: (ValidInvoiceId invoiceId)])
    :> "approve"
    :> (Put JSON Invoice)
    ]
  [markSentHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "invoices"
    :> (Capture invoiceCapture [invoiceId : String ::: (ValidInvoiceId invoiceId)])
    :> "send"
    :> (Put JSON Invoice)
    ]
  [markPaidHandler :
    (Auth [session : KanelSession ::: (Authenticated session)] #:via cookieAuth)
    :> "orgs"
    :> (Capture orgCapture [orgId : String ::: (ValidOrgId orgId)])
    :> "invoices"
    :> (Capture invoiceCapture [invoiceId : String ::: (ValidInvoiceId invoiceId)])
    :> "pay"
    :> (Put JSON Invoice)
    ]
)

(define-handler
  (addCommentAndNotifyHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [issueId : String ::: (ValidIssueId issueId)] [req : NewCommentRequest])
  #:capabilities [kanelDbRead kanelDbWrite kanelQueue random time]
  #:returns (Exists [commentId : String] (? IssueComment _entity ::: (FromDb (Id == commentId) _entity)))
  (thsl-src! "example/kanel/KanelBackend.tesl" 404 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'issueId *issueId) (cons 'req *req)) (lambda () (let/check ([tesl-checked-0 (checkOrgMember (tesl-dot/runtime session 'userId 'KanelSession) orgId)]) (let ([userId tesl-checked-0]) (let/check ([tesl-checked-1 (checkNotDone issueId)]) (let ([notDoneId tesl-checked-1]) (let/check ([tesl-checked-2 (checkCommentBody (tesl_import_String_trim (raw-value req.body)))]) (let ([commentBody tesl-checked-2]) (let ([commentId (generatePrefixedId "cmt")]) (let ([issue (let ([tesl_match (select-one (from Issue) (where (==. (entity-field-ref Issue 'id) issueId)) (where (==. (entity-field-ref Issue 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-3 (raw-value issue)]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/kanel/KanelBackend.tesl" 410 (list) (lambda () (reject "issue not found" #:http-code 404)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([currentIssue (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/kanel/KanelBackend.tesl" 412 (list (cons 'currentIssue currentIssue)) (lambda () (let ([reporter (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'id) (tesl-dot/runtime currentIssue 'reporterId 'Issue))))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-4 (raw-value reporter)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/kanel/KanelBackend.tesl" 414 (list) (lambda () (reject "issue reporter not found" #:http-code 404)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([targetUser (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/kanel/KanelBackend.tesl" 416 (list (cons 'targetUser targetUser)) (lambda () (call-with-queue-transaction (lambda () (begin (enqueue! KanelNotifyQueue (KanelNotifyJob #:recipientUserId (tesl-dot/runtime targetUser 'id 'KanelUser) #:recipientEmail (tesl-dot/runtime targetUser 'email 'KanelUser) #:subject "New comment on issue {issueId}" #:body "Comment from {session.displayName}: {commentBody}")) (pack ([commentId]) (insertCommentBody commentId userId orgId notDoneId commentBody))))))))]))))))])))))))))))))

(define-server KanelServer
  #:api KanelApi
  [registerHandler registerHandler]
  [loginHandler loginHandler]
  [createOrgHandler createOrgHandler]
  [listMyOrgsHandler listMyOrgsHandler]
  [getOrgHandler getOrgHandler]
  [listOrgMembersHandler listOrgMembersHandler]
  [inviteMemberHandler inviteMemberHandler]
  [changeMemberRoleHandler changeMemberRoleHandler]
  [removeMemberHandler removeMemberHandler]
  [createProjectHandler createProjectHandler]
  [listProjectsHandler listProjectsHandler]
  [getProjectHandler getProjectHandler]
  [archiveProjectHandler archiveProjectHandler]
  [createIssueHandler createIssueHandler]
  [listIssuesHandler listIssuesHandler]
  [getIssueHandler getIssueHandler]
  [updateIssueHandler updateIssueHandler]
  [updateIssueStatusHandler updateIssueStatusHandler]
  [addCommentAndNotifyHandler addCommentAndNotifyHandler]
  [listCommentsHandler listCommentsHandler]
  [logTimeHandler logTimeHandler]
  [listTimeEntriesHandler listTimeEntriesHandler]
  [createInvoiceHandler createInvoiceHandler]
  [listInvoicesHandler listInvoicesHandler]
  [getInvoiceHandler getInvoiceHandler]
  [approveInvoiceHandler approveInvoiceHandler]
  [markSentHandler markSentHandler]
  [markPaidHandler markPaidHandler]
)

(module+ test
  (require rackunit)
  (test-case "organizations require authentication"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead)
              (define orgs (thsl-src! "example/kanel/KanelBackend.tesl" 454 (list) (lambda () (dispatch-api-test-request KanelServer 'get (list "orgs") #:headers (tesl-hash) #:capabilities (list kanelDbRead)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 455 (list (cons 'orgs orgs)) (lambda () (statusClientError (raw-value (api-test-field-access-ref orgs 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "register response JSON can drive follow-up requests"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead kanelDbWrite random time)
              (define registered (thsl-src! "example/kanel/KanelBackend.tesl" 459 (list) (lambda () (dispatch-api-test-request KanelServer 'post (list "auth" "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "alice@example.com" (string->symbol "password") "password123" (string->symbol "displayName") "Alice") #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 460 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 461 (list (cons 'registered registered)) (lambda () (hasField "id" (raw-value (api-test-field-access-ref registered 'body)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 462 (list (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'email)))))) "alice@example.com")
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 463 (list (cons 'registered registered)) (lambda () (jsonContains "Alice" (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'displayName)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 464 (list (cons 'registered registered)) (lambda () (isNull (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'session)))))))
              (define registeredEmail (thsl-src! "example/kanel/KanelBackend.tesl" 466 (list (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'email))))))
              (define registeredDisplayName (thsl-src! "example/kanel/KanelBackend.tesl" 467 (list (cons 'registeredEmail registeredEmail) (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'displayName))))))
              (define duplicate (thsl-src! "example/kanel/KanelBackend.tesl" 469 (list (cons 'registeredDisplayName registeredDisplayName) (cons 'registeredEmail registeredEmail) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'post (list "auth" "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") (api-test-string-fragment (raw-value registeredEmail)) (string->symbol "password") "password123" (string->symbol "displayName") (api-test-string-fragment (raw-value registeredDisplayName))) #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 471 (list (cons 'duplicate duplicate) (cons 'registeredDisplayName registeredDisplayName) (cons 'registeredEmail registeredEmail) (cons 'registered registered)) (lambda () (api-test-field-access-ref duplicate 'status)))) 409)
              (define missingLogin (thsl-src! "example/kanel/KanelBackend.tesl" 473 (list (cons 'duplicate duplicate) (cons 'registeredDisplayName registeredDisplayName) (cons 'registeredEmail registeredEmail) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'post (list "auth" "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "nobody@example.com" (string->symbol "password") "password123") #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 474 (list (cons 'missingLogin missingLogin) (cons 'duplicate duplicate) (cons 'registeredDisplayName registeredDisplayName) (cons 'registeredEmail registeredEmail) (cons 'registered registered)) (lambda () (statusClientError (raw-value (api-test-field-access-ref missingLogin 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "register login and project listing use JSON helpers"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead kanelDbWrite random time)
              (define registered (thsl-src! "example/kanel/KanelBackend.tesl" 478 (list) (lambda () (dispatch-api-test-request KanelServer 'post (list "auth" "register") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "bob@example.com" (string->symbol "password") "password123" (string->symbol "displayName") "Bob") #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 479 (list (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref registered 'status)))))))
              (define registeredUserId (thsl-src! "example/kanel/KanelBackend.tesl" 481 (list (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'id))))))
              (define login (thsl-src! "example/kanel/KanelBackend.tesl" 482 (list (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'post (list "auth" "login") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "email") "bob@example.com" (string->symbol "password") "password123") #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 483 (list (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref login 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 484 (list (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (api-test-field-access-ref login 'body)))) registeredUserId)
              (define sessionUserId (thsl-src! "example/kanel/KanelBackend.tesl" 486 (list (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref login 'body))))))
              (define createdOrg (thsl-src! "example/kanel/KanelBackend.tesl" 487 (list (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'post (list "orgs") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "name") "Acme Inc" (string->symbol "slug") "acme-inc") #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 490 (list (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref createdOrg 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 491 (list (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (api-test-field-access-ref (api-test-field-access-ref createdOrg 'body) 'name)))) "Acme Inc")
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 492 (list (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (hasField "slug" (raw-value (api-test-field-access-ref createdOrg 'body)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 493 (list (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (isNull (raw-value (api-test-field-access-ref (api-test-field-access-ref createdOrg 'body) 'owner)))))))
              (define orgId (thsl-src! "example/kanel/KanelBackend.tesl" 495 (list (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref createdOrg 'body) 'id))))))
              (define orgSlugJson (thsl-src! "example/kanel/KanelBackend.tesl" 496 (list (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (bodyField "slug" (raw-value createdOrg)))))
              (define orgSlug (thsl-src! "example/kanel/KanelBackend.tesl" 497 (list (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonString (raw-value orgSlugJson)))))
              (define createdProject (thsl-src! "example/kanel/KanelBackend.tesl" 499 (list (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'post (list "orgs" (api-test-path-fragment (raw-value orgId)) "projects") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "name") "Platform" (string->symbol "description") "Ship api-tests") #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 502 (list (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref createdProject 'status)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 503 (list (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (hasField "archived" (raw-value (api-test-field-access-ref createdProject 'body)))))))
              (define projectId (thsl-src! "example/kanel/KanelBackend.tesl" 504 (list (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref createdProject 'body) 'id))))))
              (define orgs (thsl-src! "example/kanel/KanelBackend.tesl" 506 (list (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'get (list "orgs") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (tesl-hash) #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 507 (list (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref orgs 'status)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 508 (list (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (isNotEmpty (raw-value (api-test-field-access-ref orgs 'body)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 509 (list (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (includesWhere (tesl-hash 'id (raw-value orgId) 'slug (raw-value orgSlug)) (raw-value (api-test-field-access-ref orgs 'body)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 510 (list (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (excludesWhere (tesl-hash 'slug "missing-org") (raw-value (api-test-field-access-ref orgs 'body)))))))
              (define projects (thsl-src! "example/kanel/KanelBackend.tesl" 512 (list (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'get (list "orgs" (api-test-path-fragment (raw-value orgId)) "projects") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (tesl-hash) #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 513 (list (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref projects 'status)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 514 (list (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (hasLength 1 (raw-value (api-test-field-access-ref projects 'body)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 515 (list (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonLength (raw-value (api-test-field-access-ref projects 'body)))))) 1)
              (define firstProject (thsl-src! "example/kanel/KanelBackend.tesl" 516 (list (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (arrayAt 0 (raw-value (api-test-field-access-ref projects 'body))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 517 (list (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (fieldAt "id" (raw-value firstProject))))) projectId)
              (define archived (thsl-src! "example/kanel/KanelBackend.tesl" 518 (list (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (fieldAt "archived" (raw-value firstProject)))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 519 (list (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonBool (raw-value archived))))) #f)
              (define createdAt (thsl-src! "example/kanel/KanelBackend.tesl" 520 (list (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (fieldAt "createdAt" (raw-value firstProject)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 521 (list (cons 'createdAt createdAt) (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (tesl-ge? (raw-value (jsonInt (raw-value createdAt))) 0)))))
              (define fetched (thsl-src! "example/kanel/KanelBackend.tesl" 523 (list (cons 'createdAt createdAt) (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (dispatch-api-test-request KanelServer 'get (list "orgs" (api-test-path-fragment (raw-value orgId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (tesl-hash) #:capabilities (list kanelDbRead kanelDbWrite random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 524 (list (cons 'fetched fetched) (cons 'createdAt createdAt) (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (statusOk (raw-value (api-test-field-access-ref fetched 'status)))))))
              (define fetchedSlug (thsl-src! "example/kanel/KanelBackend.tesl" 525 (list (cons 'fetched fetched) (cons 'createdAt createdAt) (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (bodyField "slug" (raw-value fetched)))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 526 (list (cons 'fetchedSlug fetchedSlug) (cons 'fetched fetched) (cons 'createdAt createdAt) (cons 'archived archived) (cons 'firstProject firstProject) (cons 'projects projects) (cons 'orgs orgs) (cons 'projectId projectId) (cons 'createdProject createdProject) (cons 'orgSlug orgSlug) (cons 'orgSlugJson orgSlugJson) (cons 'orgId orgId) (cons 'createdOrg createdOrg) (cons 'sessionUserId sessionUserId) (cons 'login login) (cons 'registeredUserId registeredUserId) (cons 'registered registered)) (lambda () (jsonString (raw-value fetchedSlug))))) orgSlug)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "seed can prepare organization membership for authenticated reads"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead kanelDbWrite)
              (let ([_ (insert-one! KanelUser (tesl-hash 'id "usr-seeded" 'email "seeded@example.com" 'passwordHash "password123" 'displayName "Seeded Alice" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Org (tesl-hash 'id "org-seeded" 'name "Seeded Org" 'slug "seeded-org" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (insert-one! OrgMembership (tesl-hash 'id "mem-seeded" 'orgId "org-seeded" 'userId "usr-seeded" 'role RoleAdmin 'joinedAt (raw-value (tesl_import_Time_secondsToPosix 0))))))
              (define userId (thsl-src! "example/kanel/KanelBackend.tesl" 553 (list) (lambda () "usr-seeded")))
              (define orgId (thsl-src! "example/kanel/KanelBackend.tesl" 554 (list (cons 'userId userId)) (lambda () "org-seeded")))
              (define orgs (thsl-src! "example/kanel/KanelBackend.tesl" 556 (list (cons 'orgId orgId) (cons 'userId userId)) (lambda () (dispatch-api-test-request KanelServer 'get (list "orgs") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (tesl-hash) #:capabilities (list kanelDbRead kanelDbWrite)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 557 (list (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (statusOk (raw-value (api-test-field-access-ref orgs 'status)))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 558 (list (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (hasLength 1 (raw-value (api-test-field-access-ref orgs 'body)))))))
              (define firstOrg (thsl-src! "example/kanel/KanelBackend.tesl" 559 (list (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (arrayAt 0 (raw-value (api-test-field-access-ref orgs 'body))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 560 (list (cons 'firstOrg firstOrg) (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (fieldAt "slug" (raw-value firstOrg))))) "seeded-org")
              (define fetched (thsl-src! "example/kanel/KanelBackend.tesl" 562 (list (cons 'firstOrg firstOrg) (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (dispatch-api-test-request KanelServer 'get (list "orgs" (api-test-path-fragment (raw-value orgId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (tesl-hash) #:capabilities (list kanelDbRead kanelDbWrite)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 563 (list (cons 'fetched fetched) (cons 'firstOrg firstOrg) (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (statusOk (raw-value (api-test-field-access-ref fetched 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 564 (list (cons 'fetched fetched) (cons 'firstOrg firstOrg) (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (api-test-field-access-ref (api-test-field-access-ref fetched 'body) 'name)))) "Seeded Org")
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 565 (list (cons 'fetched fetched) (cons 'firstOrg firstOrg) (cons 'orgs orgs) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (api-test-field-access-ref (api-test-field-access-ref fetched 'body) 'slug)))) "seeded-org")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "comment notifications enqueue work and publish delivery events"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead kanelDbWrite kanelQueue kanelPubSub notifyWorkerCap random time)
              (let ([_ (insert-one! KanelUser (tesl-hash 'id "usr-reporter" 'email "reporter@example.com" 'passwordHash "password123" 'displayName "Reporter" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! KanelUser (tesl-hash 'id "usr-commenter" 'email "commenter@example.com" 'passwordHash "password123" 'displayName "Commenter" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Org (tesl-hash 'id "org-notify" 'name "Notify Org" 'slug "notify-org" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! OrgMembership (tesl-hash 'id "mem-reporter" 'orgId "org-notify" 'userId "usr-reporter" 'role RoleAdmin 'joinedAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! OrgMembership (tesl-hash 'id "mem-commenter" 'orgId "org-notify" 'userId "usr-commenter" 'role RoleMember 'joinedAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Project (tesl-hash 'id "proj-notify" 'orgId "org-notify" 'name "Notify project" 'description "Exercise api tests" 'archived #f 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (insert-one! Issue (tesl-hash 'id "iss-notify" 'projectId "proj-notify" 'orgId "org-notify" 'title "Ship api-tests" 'description "Expand coverage" 'status Backlog 'assigneeId Nothing 'reporterId "usr-reporter" 'estimate 60 'dueAt Nothing 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0)) 'updatedAt (raw-value (tesl_import_Time_secondsToPosix 0))))))))))
              (define reporterId (thsl-src! "example/kanel/KanelBackend.tesl" 628 (list) (lambda () "usr-reporter")))
              (define commenterId (thsl-src! "example/kanel/KanelBackend.tesl" 629 (list (cons 'reporterId reporterId)) (lambda () "usr-commenter")))
              (define orgId (thsl-src! "example/kanel/KanelBackend.tesl" 630 (list (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () "org-notify")))
              (define issueId (thsl-src! "example/kanel/KanelBackend.tesl" 631 (list (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () "iss-notify")))
              (define stream (thsl-src! "example/kanel/KanelBackend.tesl" 633 (list (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (subscribe KanelServer-sse-routes (list "events" "users" (api-test-path-fragment (raw-value reporterId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value reporterId))) #:headers (tesl-hash) #:name "/events/users/{reporterId}"))))
              (define comment (thsl-src! "example/kanel/KanelBackend.tesl" 634 (list (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (dispatch-api-test-request KanelServer 'post (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "comments") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value commenterId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "body") "Please review the latest changes") #:capabilities (list kanelDbRead kanelDbWrite kanelQueue kanelPubSub notifyWorkerCap random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 637 (list (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (statusOk (raw-value (api-test-field-access-ref comment 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 638 (list (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (pendingJobCount KanelNotifyQueue)))) 1)
              (define queued (thsl-src! "example/kanel/KanelBackend.tesl" 640 (list (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (processNextJob KanelNotifyQueue))))
              (define job (thsl-src! "example/kanel/KanelBackend.tesl" 641 (list (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (expectJobOk (raw-value queued)))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 642 (list (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (api-test-field-access-ref job 'recipientUserId)))) reporterId)
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 643 (list (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (api-test-field-access-ref job 'recipientEmail)))) "reporter@example.com")
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 644 (list (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (hasField "body" (raw-value job))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 645 (list (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (pendingJobCount KanelNotifyQueue)))) 0)
              (define events (thsl-src! "example/kanel/KanelBackend.tesl" 647 (list (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (collect (raw-value stream) #:count 1 #:timeout-ms 1500))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 648 (list (cons 'events events) (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (isNotEmpty (raw-value events))))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 649 (list (cons 'events events) (cons 'job job) (cons 'queued queued) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (includesWhere (tesl-hash 'tag "NotificationDelivered" 'fields (tesl-hash 'recipientEmail "reporter@example.com")) (raw-value events))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "blocked notification jobs reach dead-letter and publish failure events"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead kanelDbWrite kanelQueue kanelPubSub notifyWorkerCap random time)
              (let ([_ (insert-one! KanelUser (tesl-hash 'id "usr-blocked" 'email "blocked@example.com" 'passwordHash "password123" 'displayName "Blocked Reporter" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! KanelUser (tesl-hash 'id "usr-commenter" 'email "commenter@example.com" 'passwordHash "password123" 'displayName "Commenter" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Org (tesl-hash 'id "org-failed-notify" 'name "Failed Notify Org" 'slug "failed-notify-org" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! OrgMembership (tesl-hash 'id "mem-blocked" 'orgId "org-failed-notify" 'userId "usr-blocked" 'role RoleAdmin 'joinedAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! OrgMembership (tesl-hash 'id "mem-commenter" 'orgId "org-failed-notify" 'userId "usr-commenter" 'role RoleMember 'joinedAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Project (tesl-hash 'id "proj-failed-notify" 'orgId "org-failed-notify" 'name "Failure project" 'description "Exercise dead-letter handling" 'archived #f 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (insert-one! Issue (tesl-hash 'id "iss-failed-notify" 'projectId "proj-failed-notify" 'orgId "org-failed-notify" 'title "Queue failure" 'description "Expect dead-letter delivery" 'status Backlog 'assigneeId Nothing 'reporterId "usr-blocked" 'estimate 30 'dueAt Nothing 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0)) 'updatedAt (raw-value (tesl_import_Time_secondsToPosix 0))))))))))
              (define reporterId (thsl-src! "example/kanel/KanelBackend.tesl" 712 (list) (lambda () "usr-blocked")))
              (define commenterId (thsl-src! "example/kanel/KanelBackend.tesl" 713 (list (cons 'reporterId reporterId)) (lambda () "usr-commenter")))
              (define orgId (thsl-src! "example/kanel/KanelBackend.tesl" 714 (list (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () "org-failed-notify")))
              (define issueId (thsl-src! "example/kanel/KanelBackend.tesl" 715 (list (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () "iss-failed-notify")))
              (define stream (thsl-src! "example/kanel/KanelBackend.tesl" 717 (list (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (subscribe KanelServer-sse-routes (list "events" "users" (api-test-path-fragment (raw-value reporterId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value reporterId))) #:headers (tesl-hash) #:name "/events/users/{reporterId}"))))
              (define comment (thsl-src! "example/kanel/KanelBackend.tesl" 718 (list (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (dispatch-api-test-request KanelServer 'post (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "comments") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value commenterId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "body") "This should fail delivery") #:capabilities (list kanelDbRead kanelDbWrite kanelQueue kanelPubSub notifyWorkerCap random time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 721 (list (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (statusOk (raw-value (api-test-field-access-ref comment 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 722 (list (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (pendingJobCount KanelNotifyQueue)))) 1)
              (define firstAttempt (thsl-src! "example/kanel/KanelBackend.tesl" 724 (list (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (processNextJob KanelNotifyQueue))))
              (define firstError (thsl-src! "example/kanel/KanelBackend.tesl" 725 (list (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (expectJobFailed (raw-value firstAttempt)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 726 (list (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (isNotNull (raw-value firstError))))))
              (define secondAttempt (thsl-src! "example/kanel/KanelBackend.tesl" 728 (list (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (processNextJob KanelNotifyQueue))))
              (define secondError (thsl-src! "example/kanel/KanelBackend.tesl" 729 (list (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (expectJobFailed (raw-value secondAttempt)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 730 (list (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (isNotNull (raw-value secondError))))))
              (define thirdAttempt (thsl-src! "example/kanel/KanelBackend.tesl" 732 (list (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (processNextJob KanelNotifyQueue))))
              (define thirdError (thsl-src! "example/kanel/KanelBackend.tesl" 733 (list (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (expectJobFailed (raw-value thirdAttempt)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 734 (list (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (isNotNull (raw-value thirdError))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 735 (list (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (pendingJobCount KanelNotifyQueue)))) 0)
              (define deadResult (thsl-src! "example/kanel/KanelBackend.tesl" 737 (list (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (processNextDeadJob KanelNotifyQueue))))
              (define deadJob (thsl-src! "example/kanel/KanelBackend.tesl" 738 (list (cons 'deadResult deadResult) (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (expectJobOk (raw-value deadResult)))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 739 (list (cons 'deadJob deadJob) (cons 'deadResult deadResult) (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (api-test-field-access-ref deadJob 'recipientUserId)))) reporterId)
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 740 (list (cons 'deadJob deadJob) (cons 'deadResult deadResult) (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (api-test-field-access-ref deadJob 'recipientEmail)))) "blocked@example.com")
              (define events (thsl-src! "example/kanel/KanelBackend.tesl" 742 (list (cons 'deadJob deadJob) (cons 'deadResult deadResult) (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (collect (raw-value stream) #:timeout-ms 1500))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 745 (list (cons 'events events) (cons 'deadJob deadJob) (cons 'deadResult deadResult) (cons 'thirdError thirdError) (cons 'thirdAttempt thirdAttempt) (cons 'secondError secondError) (cons 'secondAttempt secondAttempt) (cons 'firstError firstError) (cons 'firstAttempt firstAttempt) (cons 'comment comment) (cons 'stream stream) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'commenterId commenterId) (cons 'reporterId reporterId)) (lambda () (includesWhere (tesl-hash 'tag "NotificationFailed" 'fields (tesl-hash 'recipientEmail "blocked@example.com")) (raw-value events))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "issue status can be updated through valid transitions"
    (call-with-fresh-memory-db (list KanelDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (kanelDbRead kanelDbWrite kanelPubSub time)
              (let ([_ (insert-one! KanelUser (tesl-hash 'id "usr-status-test" 'email "statustest@example.com" 'passwordHash "password123" 'displayName "Status Tester" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Org (tesl-hash 'id "org-status-test" 'name "Status Test Org" 'slug "status-test-org" 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! OrgMembership (tesl-hash 'id "mem-status-test" 'orgId "org-status-test" 'userId "usr-status-test" 'role RoleAdmin 'joinedAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (let ([_ (insert-one! Project (tesl-hash 'id "proj-status-test" 'orgId "org-status-test" 'name "Status Test Project" 'description "For testing status transitions" 'archived #f 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0))))]) (insert-one! Issue (tesl-hash 'id "iss-status-test" 'projectId "proj-status-test" 'orgId "org-status-test" 'title "Transition test issue" 'description "Testing status machine" 'status Backlog 'assigneeId Nothing 'reporterId "usr-status-test" 'estimate 30 'dueAt Nothing 'createdAt (raw-value (tesl_import_Time_secondsToPosix 0)) 'updatedAt (raw-value (tesl_import_Time_secondsToPosix 0))))))))
              (define userId (thsl-src! "example/kanel/KanelBackend.tesl" 794 (list) (lambda () "usr-status-test")))
              (define orgId (thsl-src! "example/kanel/KanelBackend.tesl" 795 (list (cons 'userId userId)) (lambda () "org-status-test")))
              (define issueId (thsl-src! "example/kanel/KanelBackend.tesl" 796 (list (cons 'orgId orgId) (cons 'userId userId)) (lambda () "iss-status-test")))
              (define toTodo (thsl-src! "example/kanel/KanelBackend.tesl" 799 (list (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "newStatus") (tesl-hash (string->symbol "tag") "Todo")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 802 (list (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (statusOk (raw-value (api-test-field-access-ref toTodo 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 803 (list (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (api-test-field-access-ref (api-test-field-access-ref toTodo 'body) 'status)))) (tesl-hash 'tag "Todo"))
              (define toInProgress (thsl-src! "example/kanel/KanelBackend.tesl" 806 (list (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "newStatus") (tesl-hash (string->symbol "tag") "InProgress")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 809 (list (cons 'toInProgress toInProgress) (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (statusOk (raw-value (api-test-field-access-ref toInProgress 'status)))))))
              (define toInReview (thsl-src! "example/kanel/KanelBackend.tesl" 812 (list (cons 'toInProgress toInProgress) (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "newStatus") (tesl-hash (string->symbol "tag") "InReview")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 815 (list (cons 'toInReview toInReview) (cons 'toInProgress toInProgress) (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (statusOk (raw-value (api-test-field-access-ref toInReview 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 816 (list (cons 'toInReview toInReview) (cons 'toInProgress toInProgress) (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (api-test-field-access-ref (api-test-field-access-ref toInReview 'body) 'status)))) (tesl-hash 'tag "InReview"))
              (define badTransition (thsl-src! "example/kanel/KanelBackend.tesl" 819 (list (cons 'toInReview toInReview) (cons 'toInProgress toInProgress) (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (tesl-hash) #:body (tesl-hash (string->symbol "newStatus") (tesl-hash (string->symbol "tag") "Backlog")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))))
              (check-true (raw-value (thsl-src! "example/kanel/KanelBackend.tesl" 822 (list (cons 'badTransition badTransition) (cons 'toInReview toInReview) (cons 'toInProgress toInProgress) (cons 'toTodo toTodo) (cons 'issueId issueId) (cons 'orgId orgId) (cons 'userId userId)) (lambda () (statusClientError (raw-value (api-test-field-access-ref badTransition 'status)))))))
            )
          ))
      ))
  )
)

(module+ main
  (thsl-src! "example/kanel/KanelBackend.tesl" 827 (list) (lambda () (with-capabilities (kanelDbRead kanelDbWrite kanelQueue kanelPubSub random time notifyWorkerCap envRead) (call-with-database KanelDatabase (lambda () (let ([port (raw-value (envInt "KANEL_PORT" 8080))]) (begin (start-workers! KanelNotifyQueueWorkers (list notifyWorkerCap kanelPubSub) #:concurrency 2) (begin (start-dead-workers! KanelNotifyQueueDeadWorkers (list notifyWorkerCap kanelPubSub)) (serve KanelServer #:port port #:capabilities (list kanelDbRead kanelDbWrite kanelQueue kanelPubSub random time notifyWorkerCap envRead) #:static-dir "example/kanel/frontend" #:sse-routes KanelServer-sse-routes))))))))))

(define KanelNotifyQueueWorkers
  (list (cons KanelNotifyQueue notifyWorker)))
(register-api-test-workers! (list (list KanelNotifyQueue 'KanelNotifyJob notifyWorker)))

(define KanelNotifyQueueDeadWorkers
  (list (cons KanelNotifyQueue deadNotifyWorker)))
(register-api-test-dead-workers! (list (list KanelNotifyQueue 'KanelNotifyJob deadNotifyWorker)))
