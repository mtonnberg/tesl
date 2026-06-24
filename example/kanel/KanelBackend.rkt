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
  (only-in tesl/tesl/prelude Bool String Unit)
  (only-in tesl/tesl/env env envInt)
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/queue queueRead queueWrite pubsub FromQueue FromDeadQueue)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.trim tesl_import_String_trim])
  (only-in tesl/tesl/api-test statusOk statusClientError jsonInt jsonString jsonBool jsonLength isNull isNotNull includesWhere excludesWhere hasLength isNotEmpty arrayAt hasField fieldAt bodyField jsonContains subscribe collect JobResult JobOk JobFailed processNextJob processNextDeadJob pendingJobCount expectJobOk expectJobFailed)
  (only-in tesl/github/tesl/example/kanel/kanel-models kanelDbRead kanelDbWrite kanelQueue kanelPubSub KanelUser Org OrgMembership Project ProjectMembership Issue IssueComment TimeEntry Invoice OrgRole RoleAdmin RoleMember RoleViewer IssueStatus Backlog Todo InProgress InReview Done Cancelled NewCommentRequest NewOrgRequest NewProjectRequest NewIssueRequest UpdateIssueRequest UpdateStatusRequest NewTimeEntryRequest NewInvoiceRequest ValidOrgId checkOrgId ValidProjectId checkProjectId ValidIssueId checkIssueId ValidInvoiceId checkInvoiceId ValidUserId checkUserId checkTargetUserId checkOrgId-signature checkProjectId-signature checkIssueId-signature checkInvoiceId-signature checkUserId-signature checkTargetUserId-signature)
  (only-in tesl/github/tesl/example/kanel/kanel-auth KanelSession Authenticated cookieAuth checkOrgMember cookieAuth-signature checkOrgMember-signature)
  (only-in tesl/github/tesl/example/kanel/kanel-org RegisterRequest LoginRequest InviteMemberRequest ChangeMemberRoleRequest registerHandler loginHandler createOrgHandler getOrgHandler listOrgMembersHandler inviteMemberHandler changeMemberRoleHandler removeMemberHandler listMyOrgsHandler registerHandler-signature loginHandler-signature createOrgHandler-signature getOrgHandler-signature listOrgMembersHandler-signature inviteMemberHandler-signature changeMemberRoleHandler-signature removeMemberHandler-signature listMyOrgsHandler-signature)
  (only-in tesl/github/tesl/example/kanel/kanel-issues checkCommentBody insertCommentBody checkNotDone createProjectHandler listProjectsHandler getProjectHandler archiveProjectHandler createIssueHandler listIssuesHandler getIssueHandler updateIssueHandler updateIssueStatusHandler listCommentsHandler logTimeHandler listTimeEntriesHandler checkCommentBody-signature insertCommentBody-signature checkNotDone-signature createProjectHandler-signature listProjectsHandler-signature getProjectHandler-signature archiveProjectHandler-signature createIssueHandler-signature listIssuesHandler-signature getIssueHandler-signature updateIssueHandler-signature updateIssueStatusHandler-signature listCommentsHandler-signature logTimeHandler-signature listTimeEntriesHandler-signature)
  (only-in tesl/github/tesl/example/kanel/kanel-billing createInvoiceHandler getInvoiceHandler listInvoicesHandler approveInvoiceHandler markSentHandler markPaidHandler createInvoiceHandler-signature getInvoiceHandler-signature listInvoicesHandler-signature approveInvoiceHandler-signature markSentHandler-signature markPaidHandler-signature)
)


(provide KanelServer)

(define-database KanelDatabase
  #:backend postgres
  #:database (tesl-env-raw "KANEL_DB")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:socket (tesl-env-raw "TESL_POSTGRES_SOCKET")
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
  (if (equal? (raw-value job.recipientEmail) "blocked@example.com") (reject "notifications blocked for recipient" #:http-code 500) (begin (publish-event! UserNotifications (format "~a" (raw-value job.recipientUserId)) (NotificationDelivered (raw-value job.recipientEmail) (raw-value job.subject))) job)))

(define/pow
  (deadNotifyWorker [job : KanelNotifyJob ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [notifyWorkerCap kanelPubSub]
  #:returns KanelNotifyJob
  (begin (publish-event! UserNotifications (format "~a" (raw-value job.recipientUserId)) (NotificationFailed (raw-value job.recipientEmail) (raw-value job.subject))) *job))

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
  (list (list (list "events" "users") cookieAuth UserNotifications)))
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
  [addCommentHandler :
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
  (let/check ([tesl_checked_0 (checkOrgMember (raw-value session.userId) orgId)]) (let ([userId tesl_checked_0]) (let/check ([tesl_checked_1 (checkNotDone issueId)]) (let ([notDoneId tesl_checked_1]) (let/check ([tesl_checked_2 (checkCommentBody (tesl_import_String_trim (raw-value req.body)))]) (let ([commentBody tesl_checked_2]) (let ([commentId (generatePrefixedId "cmt")]) (let ([issue (let ([tesl_match (select-one (from Issue) (where (==. (entity-field-ref Issue 'id) issueId)) (where (==. (entity-field-ref Issue 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_3 (raw-value issue)]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Nothing)) (reject "issue not found" #:http-code 404)] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Something)) (let ([currentIssue (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (let ([reporter (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'id) (raw-value currentIssue.reporterId))))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_4 (raw-value reporter)]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (reject "issue reporter not found" #:http-code 404)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([targetUser (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (call-with-queue-transaction (lambda () (begin (enqueue! KanelNotifyQueue (KanelNotifyJob #:recipientUserId (raw-value targetUser.id) #:recipientEmail (raw-value targetUser.email) #:subject "New comment on issue {issueId}" #:body "Comment from {session.displayName}: {commentBody}")) (pack ([commentId]) (insertCommentBody commentId userId orgId notDoneId commentBody))))))]))))])))))))))))

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
  [addCommentHandler addCommentAndNotifyHandler]
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
              (define orgs (dispatch-api-test-request KanelServer 'get (list "orgs") #:headers (hash) #:capabilities (list kanelDbRead)))
              (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref orgs 'status)))))
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
              (define registered (dispatch-api-test-request KanelServer 'post (list "auth" "register") #:headers (hash) #:body (hash (string->symbol "email") "alice@example.com" (string->symbol "password") "password123" (string->symbol "displayName") "Alice") #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref registered 'status)))))
              (check-true (raw-value (hasField "id" (raw-value (api-test-field-access-ref registered 'body)))))
              (check-equal? (raw-value (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'email)))) "alice@example.com")
              (check-true (raw-value (jsonContains "Alice" (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'displayName)))))
              (check-true (raw-value (isNull (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'session)))))
              (define registeredEmail (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'email))))
              (define registeredDisplayName (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'displayName))))
              (define duplicate (dispatch-api-test-request KanelServer 'post (list "auth" "register") #:headers (hash) #:body (hash (string->symbol "email") (api-test-string-fragment (raw-value registeredEmail)) (string->symbol "password") "password123" (string->symbol "displayName") (api-test-string-fragment (raw-value registeredDisplayName))) #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-equal? (raw-value (api-test-field-access-ref duplicate 'status)) 409)
              (define missingLogin (dispatch-api-test-request KanelServer 'post (list "auth" "login") #:headers (hash) #:body (hash (string->symbol "email") "nobody@example.com" (string->symbol "password") "password123") #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref missingLogin 'status)))))
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
              (define registered (dispatch-api-test-request KanelServer 'post (list "auth" "register") #:headers (hash) #:body (hash (string->symbol "email") "bob@example.com" (string->symbol "password") "password123" (string->symbol "displayName") "Bob") #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref registered 'status)))))
              (define registeredUserId (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref registered 'body) 'id))))
              (define login (dispatch-api-test-request KanelServer 'post (list "auth" "login") #:headers (hash) #:body (hash (string->symbol "email") "bob@example.com" (string->symbol "password") "password123") #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref login 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref login 'body)) registeredUserId)
              (define sessionUserId (jsonString (raw-value (api-test-field-access-ref login 'body))))
              (define createdOrg (dispatch-api-test-request KanelServer 'post (list "orgs") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (hash) #:body (hash (string->symbol "name") "Acme Inc" (string->symbol "slug") "acme-inc") #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref createdOrg 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref createdOrg 'body) 'name)) "Acme Inc")
              (check-true (raw-value (hasField "slug" (raw-value (api-test-field-access-ref createdOrg 'body)))))
              (check-true (raw-value (isNull (raw-value (api-test-field-access-ref (api-test-field-access-ref createdOrg 'body) 'owner)))))
              (define orgId (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref createdOrg 'body) 'id))))
              (define orgSlugJson (bodyField "slug" (raw-value createdOrg)))
              (define orgSlug (jsonString (raw-value orgSlugJson)))
              (define createdProject (dispatch-api-test-request KanelServer 'post (list "orgs" (api-test-path-fragment (raw-value orgId)) "projects") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (hash) #:body (hash (string->symbol "name") "Platform" (string->symbol "description") "Ship api-tests") #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref createdProject 'status)))))
              (check-true (raw-value (hasField "archived" (raw-value (api-test-field-access-ref createdProject 'body)))))
              (define projectId (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref createdProject 'body) 'id))))
              (define orgs (dispatch-api-test-request KanelServer 'get (list "orgs") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (hash) #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref orgs 'status)))))
              (check-true (raw-value (isNotEmpty (raw-value (api-test-field-access-ref orgs 'body)))))
              (check-true (raw-value (includesWhere (hash 'id (raw-value orgId) 'slug (raw-value orgSlug)) (raw-value (api-test-field-access-ref orgs 'body)))))
              (check-true (raw-value (excludesWhere (hash 'slug "missing-org") (raw-value (api-test-field-access-ref orgs 'body)))))
              (define projects (dispatch-api-test-request KanelServer 'get (list "orgs" (api-test-path-fragment (raw-value orgId)) "projects") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (hash) #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref projects 'status)))))
              (check-true (raw-value (hasLength 1 (raw-value (api-test-field-access-ref projects 'body)))))
              (check-equal? (raw-value (jsonLength (raw-value (api-test-field-access-ref projects 'body)))) 1)
              (define firstProject (arrayAt 0 (raw-value (api-test-field-access-ref projects 'body))))
              (check-equal? (raw-value (fieldAt "id" (raw-value firstProject))) projectId)
              (define archived (fieldAt "archived" (raw-value firstProject)))
              (check-equal? (raw-value (jsonBool (raw-value archived))) #f)
              (define createdAt (fieldAt "createdAt" (raw-value firstProject)))
              (check-true (raw-value (>= (raw-value (jsonInt (raw-value createdAt))) 0)))
              (define fetched (dispatch-api-test-request KanelServer 'get (list "orgs" (api-test-path-fragment (raw-value orgId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value sessionUserId))) #:headers (hash) #:capabilities (list kanelDbRead kanelDbWrite random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref fetched 'status)))))
              (define fetchedSlug (bodyField "slug" (raw-value fetched)))
              (check-equal? (raw-value (jsonString (raw-value fetchedSlug))) orgSlug)
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
              (insert-one! KanelUser (hash 'id "usr-seeded" 'email "seeded@example.com" 'passwordHash "password123" 'displayName "Seeded Alice" 'createdAt 0))
              (insert-one! Org (hash 'id "org-seeded" 'name "Seeded Org" 'slug "seeded-org" 'createdAt 0))
              (insert-one! OrgMembership (hash 'id "mem-seeded" 'orgId "org-seeded" 'userId "usr-seeded" 'role RoleAdmin 'joinedAt 0))
              (define userId "usr-seeded")
              (define orgId "org-seeded")
              (define orgs (dispatch-api-test-request KanelServer 'get (list "orgs") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:capabilities (list kanelDbRead kanelDbWrite)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref orgs 'status)))))
              (check-true (raw-value (hasLength 1 (raw-value (api-test-field-access-ref orgs 'body)))))
              (define firstOrg (arrayAt 0 (raw-value (api-test-field-access-ref orgs 'body))))
              (check-equal? (raw-value (fieldAt "slug" (raw-value firstOrg))) "seeded-org")
              (define fetched (dispatch-api-test-request KanelServer 'get (list "orgs" (api-test-path-fragment (raw-value orgId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:capabilities (list kanelDbRead kanelDbWrite)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref fetched 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref fetched 'body) 'name)) "Seeded Org")
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref fetched 'body) 'slug)) "seeded-org")
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
              (insert-one! KanelUser (hash 'id "usr-reporter" 'email "reporter@example.com" 'passwordHash "password123" 'displayName "Reporter" 'createdAt 0))
              (insert-one! KanelUser (hash 'id "usr-commenter" 'email "commenter@example.com" 'passwordHash "password123" 'displayName "Commenter" 'createdAt 0))
              (insert-one! Org (hash 'id "org-notify" 'name "Notify Org" 'slug "notify-org" 'createdAt 0))
              (insert-one! OrgMembership (hash 'id "mem-reporter" 'orgId "org-notify" 'userId "usr-reporter" 'role RoleAdmin 'joinedAt 0))
              (insert-one! OrgMembership (hash 'id "mem-commenter" 'orgId "org-notify" 'userId "usr-commenter" 'role RoleMember 'joinedAt 0))
              (insert-one! Project (hash 'id "proj-notify" 'orgId "org-notify" 'name "Notify project" 'description "Exercise api tests" 'archived #f 'createdAt 0))
              (insert-one! Issue (hash 'id "iss-notify" 'projectId "proj-notify" 'orgId "org-notify" 'title "Ship api-tests" 'description "Expand coverage" 'status Backlog 'assigneeId Nothing 'reporterId "usr-reporter" 'estimate 60 'dueAt Nothing 'createdAt 0 'updatedAt 0))
              (define reporterId "usr-reporter")
              (define commenterId "usr-commenter")
              (define orgId "org-notify")
              (define issueId "iss-notify")
              (define stream (subscribe KanelServer-sse-routes (list "events" "users" (api-test-path-fragment (raw-value reporterId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value reporterId))) #:headers (hash) #:name "/events/users/{reporterId}"))
              (define comment (dispatch-api-test-request KanelServer 'post (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "comments") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value commenterId))) #:headers (hash) #:body (hash (string->symbol "body") "Please review the latest changes") #:capabilities (list kanelDbRead kanelDbWrite kanelQueue kanelPubSub notifyWorkerCap random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref comment 'status)))))
              (check-equal? (raw-value (pendingJobCount KanelNotifyQueue)) 1)
              (define queued (processNextJob KanelNotifyQueue))
              (define job (expectJobOk (raw-value queued)))
              (check-equal? (raw-value (api-test-field-access-ref job 'recipientUserId)) reporterId)
              (check-equal? (raw-value (api-test-field-access-ref job 'recipientEmail)) "reporter@example.com")
              (check-true (raw-value (hasField "body" (raw-value job))))
              (check-equal? (raw-value (pendingJobCount KanelNotifyQueue)) 0)
              (define events (collect (raw-value stream) #:count 1 #:timeout-ms 1500))
              (check-true (raw-value (isNotEmpty (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "NotificationDelivered" 'fields (hash 'recipientEmail "reporter@example.com")) (raw-value events))))
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
              (insert-one! KanelUser (hash 'id "usr-blocked" 'email "blocked@example.com" 'passwordHash "password123" 'displayName "Blocked Reporter" 'createdAt 0))
              (insert-one! KanelUser (hash 'id "usr-commenter" 'email "commenter@example.com" 'passwordHash "password123" 'displayName "Commenter" 'createdAt 0))
              (insert-one! Org (hash 'id "org-failed-notify" 'name "Failed Notify Org" 'slug "failed-notify-org" 'createdAt 0))
              (insert-one! OrgMembership (hash 'id "mem-blocked" 'orgId "org-failed-notify" 'userId "usr-blocked" 'role RoleAdmin 'joinedAt 0))
              (insert-one! OrgMembership (hash 'id "mem-commenter" 'orgId "org-failed-notify" 'userId "usr-commenter" 'role RoleMember 'joinedAt 0))
              (insert-one! Project (hash 'id "proj-failed-notify" 'orgId "org-failed-notify" 'name "Failure project" 'description "Exercise dead-letter handling" 'archived #f 'createdAt 0))
              (insert-one! Issue (hash 'id "iss-failed-notify" 'projectId "proj-failed-notify" 'orgId "org-failed-notify" 'title "Queue failure" 'description "Expect dead-letter delivery" 'status Backlog 'assigneeId Nothing 'reporterId "usr-blocked" 'estimate 30 'dueAt Nothing 'createdAt 0 'updatedAt 0))
              (define reporterId "usr-blocked")
              (define commenterId "usr-commenter")
              (define orgId "org-failed-notify")
              (define issueId "iss-failed-notify")
              (define stream (subscribe KanelServer-sse-routes (list "events" "users" (api-test-path-fragment (raw-value reporterId))) #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value reporterId))) #:headers (hash) #:name "/events/users/{reporterId}"))
              (define comment (dispatch-api-test-request KanelServer 'post (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "comments") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value commenterId))) #:headers (hash) #:body (hash (string->symbol "body") "This should fail delivery") #:capabilities (list kanelDbRead kanelDbWrite kanelQueue kanelPubSub notifyWorkerCap random time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref comment 'status)))))
              (check-equal? (raw-value (pendingJobCount KanelNotifyQueue)) 1)
              (define firstAttempt (processNextJob KanelNotifyQueue))
              (define firstError (expectJobFailed (raw-value firstAttempt)))
              (check-true (raw-value (isNotNull (raw-value firstError))))
              (define secondAttempt (processNextJob KanelNotifyQueue))
              (define secondError (expectJobFailed (raw-value secondAttempt)))
              (check-true (raw-value (isNotNull (raw-value secondError))))
              (define thirdAttempt (processNextJob KanelNotifyQueue))
              (define thirdError (expectJobFailed (raw-value thirdAttempt)))
              (check-true (raw-value (isNotNull (raw-value thirdError))))
              (check-equal? (raw-value (pendingJobCount KanelNotifyQueue)) 0)
              (define deadResult (processNextDeadJob KanelNotifyQueue))
              (define deadJob (expectJobOk (raw-value deadResult)))
              (check-equal? (raw-value (api-test-field-access-ref deadJob 'recipientUserId)) reporterId)
              (check-equal? (raw-value (api-test-field-access-ref deadJob 'recipientEmail)) "blocked@example.com")
              (define events (collect (raw-value stream) #:timeout-ms 1500))
              (check-true (raw-value (includesWhere (hash 'tag "NotificationFailed" 'fields (hash 'recipientEmail "blocked@example.com")) (raw-value events))))
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
              (insert-one! KanelUser (hash 'id "usr-status-test" 'email "statustest@example.com" 'passwordHash "password123" 'displayName "Status Tester" 'createdAt 0))
              (insert-one! Org (hash 'id "org-status-test" 'name "Status Test Org" 'slug "status-test-org" 'createdAt 0))
              (insert-one! OrgMembership (hash 'id "mem-status-test" 'orgId "org-status-test" 'userId "usr-status-test" 'role RoleAdmin 'joinedAt 0))
              (insert-one! Project (hash 'id "proj-status-test" 'orgId "org-status-test" 'name "Status Test Project" 'description "For testing status transitions" 'archived #f 'createdAt 0))
              (insert-one! Issue (hash 'id "iss-status-test" 'projectId "proj-status-test" 'orgId "org-status-test" 'title "Transition test issue" 'description "Testing status machine" 'status Backlog 'assigneeId Nothing 'reporterId "usr-status-test" 'estimate 30 'dueAt Nothing 'createdAt 0 'updatedAt 0))
              (define userId "usr-status-test")
              (define orgId "org-status-test")
              (define issueId "iss-status-test")
              (define toTodo (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:body (hash (string->symbol "newStatus") (hash (string->symbol "tag") "Todo")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref toTodo 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref toTodo 'body) 'status)) (hash 'tag "Todo"))
              (define toInProgress (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:body (hash (string->symbol "newStatus") (hash (string->symbol "tag") "InProgress")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref toInProgress 'status)))))
              (define toInReview (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:body (hash (string->symbol "newStatus") (hash (string->symbol "tag") "InReview")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref toInReview 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref toInReview 'body) 'status)) (hash 'tag "InReview"))
              (define badTransition (dispatch-api-test-request KanelServer 'put (list "orgs" (api-test-path-fragment (raw-value orgId)) "issues" (api-test-path-fragment (raw-value issueId)) "status") #:cookie (string-append "kanel_user_id=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:body (hash (string->symbol "newStatus") (hash (string->symbol "tag") "Backlog")) #:capabilities (list kanelDbRead kanelDbWrite kanelPubSub time)))
              (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref badTransition 'status)))))
            )
          ))
      ))
  )
)

(module+ main
  (let ([port (raw-value (envInt "KANEL_PORT" 8080))]) (call-with-database KanelDatabase (lambda () (with-capabilities (kanelDbRead kanelDbWrite kanelQueue kanelPubSub random time notifyWorkerCap) (begin (start-workers! KanelNotifyWorkers (list notifyWorkerCap kanelPubSub) #:concurrency 2) (begin (start-dead-workers! KanelDeadNotifyWorkers (list notifyWorkerCap kanelPubSub)) (serve KanelServer #:port port #:capabilities (list kanelDbRead kanelDbWrite kanelQueue kanelPubSub random time) #:static-dir "example/kanel/frontend" #:sse-routes KanelServer-sse-routes))))))))

(define KanelNotifyWorkers
  (list (cons KanelNotifyQueue notifyWorker)))
(register-api-test-workers! (list (list KanelNotifyQueue 'KanelNotifyJob notifyWorker)))

(define KanelDeadNotifyWorkers
  (list (cons KanelNotifyQueue deadNotifyWorker)))
(register-api-test-dead-workers! (list (list KanelNotifyQueue 'KanelNotifyJob deadNotifyWorker)))
