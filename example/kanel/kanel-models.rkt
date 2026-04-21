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
  (only-in tesl/tesl/prelude Int Bool String Fact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/queue queueWrite pubsub)
  (only-in tesl/tesl/time PosixMillis)
)


(provide kanelDbRead kanelDbWrite kanelQueue kanelPubSub OrgRole RoleAdmin RoleMember RoleViewer IssueStatus Backlog Todo InProgress InReview Done Cancelled InvoiceStatus Draft Approved Sent Paid Overdue KanelUser Org OrgMembership Project ProjectMembership Issue IssueComment TimeEntry Invoice NotifyPayload NewOrgRequest NewProjectRequest NewIssueRequest UpdateIssueRequest UpdateStatusRequest NewCommentRequest NewTimeEntryRequest NewInvoiceRequest ValidOrgId checkOrgId ValidProjectId checkProjectId ValidIssueId checkIssueId ValidInvoiceId checkInvoiceId ValidUserId checkUserId checkTargetUserId checkOrgId-signature checkProjectId-signature checkIssueId-signature checkInvoiceId-signature checkUserId-signature checkTargetUserId-signature)

(define ValidInvoiceId 'ValidInvoiceId)
(define ValidIssueId 'ValidIssueId)
(define ValidOrgId 'ValidOrgId)
(define ValidProjectId 'ValidProjectId)
(define ValidUserId 'ValidUserId)

(define-capability kanelDbRead (implies dbRead))

(define-capability kanelDbWrite (implies dbWrite))

(define-capability kanelQueue (implies queueWrite))

(define-capability kanelPubSub (implies pubsub))

(define-adt OrgRole
  [RoleAdmin]
  [RoleMember]
  [RoleViewer]
)

(define-adt IssueStatus
  [Backlog]
  [Todo]
  [InProgress]
  [InReview]
  [Done]
  [Cancelled]
)

(define-adt InvoiceStatus
  [Draft]
  [Approved]
  [Sent]
  [Paid]
  [Overdue]
)

(define-entity KanelUser
  #:source (make-hash)
  #:table kanel_users
  #:primary-key id
  [Id id : String]
  [Email email : String #:db-type text]
  [PasswordHash passwordHash : String #:db-type text]
  [DisplayName displayName : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-entity Org
  #:source (make-hash)
  #:table kanel_orgs
  #:primary-key id
  [Id id : String]
  [Name name : String #:db-type text]
  [Slug slug : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-entity OrgMembership
  #:source (make-hash)
  #:table kanel_org_memberships
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String #:db-type text]
  [UserId userId : String #:db-type text]
  [Role role : OrgRole]
  [JoinedAt joinedAt : PosixMillis]
)

(define-entity Project
  #:source (make-hash)
  #:table kanel_projects
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String #:db-type text]
  [Name name : String #:db-type text]
  [Description description : String #:db-type text]
  [Archived archived : Boolean]
  [CreatedAt createdAt : PosixMillis]
)

(define-entity ProjectMembership
  #:source (make-hash)
  #:table kanel_project_memberships
  #:primary-key id
  [Id id : String]
  [ProjectId projectId : String #:db-type text]
  [UserId userId : String #:db-type text]
  [JoinedAt joinedAt : PosixMillis]
)

(define-entity Issue
  #:source (make-hash)
  #:table kanel_issues
  #:primary-key id
  [Id id : String]
  [ProjectId projectId : String #:db-type text]
  [OrgId orgId : String #:db-type text]
  [Title title : String #:db-type text]
  [Description description : String #:db-type text]
  [Status status : IssueStatus]
  [AssigneeId assigneeId : (Maybe String) #:db-type text]
  [ReporterId reporterId : String #:db-type text]
  [Estimate estimate : Integer]
  [DueAt dueAt : (Maybe PosixMillis)]
  [CreatedAt createdAt : PosixMillis]
  [UpdatedAt updatedAt : PosixMillis]
)

(define-entity IssueComment
  #:source (make-hash)
  #:table kanel_issue_comments
  #:primary-key id
  [Id id : String]
  [IssueId issueId : String #:db-type text]
  [AuthorId authorId : String #:db-type text]
  [Body body : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-entity TimeEntry
  #:source (make-hash)
  #:table kanel_time_entries
  #:primary-key id
  [Id id : String]
  [IssueId issueId : String #:db-type text]
  [UserId userId : String #:db-type text]
  [OrgId orgId : String #:db-type text]
  [Minutes minutes : Integer]
  [Description description : String #:db-type text]
  [InvoiceId invoiceId : String #:db-type text]
  [LoggedAt loggedAt : PosixMillis]
)

(define-entity Invoice
  #:source (make-hash)
  #:table kanel_invoices
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String #:db-type text]
  [Status status : InvoiceStatus]
  [TotalMinutes totalMinutes : Integer]
  [Notes notes : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
  [ApprovedAt approvedAt : PosixMillis]
)

(define-record NotifyPayload
  [recipientUserId : String]
  [recipientEmail : String]
  [subject : String]
  [body : String]
)

(define-record NewOrgRequest
  [name : String]
  [slug : String]
)

(define-record NewProjectRequest
  [name : String]
  [description : String]
)

(define-record NewIssueRequest
  [title : String]
  [description : String]
  [estimate : Integer]
)

(define-record UpdateIssueRequest
  [title : String]
  [description : String]
  [estimate : Integer]
  [assigneeId : String]
)

(define-record UpdateStatusRequest
  [newStatus : IssueStatus]
)

(define-record NewCommentRequest
  [body : String]
)

(define-record NewTimeEntryRequest
  [minutes : Integer]
  [description : String]
)

(define-record NewInvoiceRequest
  [notes : String]
)

(define-checker
  (checkOrgId [orgId : String])
  #:returns [orgId : String ::: (ValidOrgId orgId)]
  (if (< (raw-value (tesl_import_String_length *orgId)) 3) (reject "invalid org id" #:http-code 400) (accept (ValidOrgId orgId) #:value *orgId)))

(define-checker
  (checkProjectId [projectId : String])
  #:returns [projectId : String ::: (ValidProjectId projectId)]
  (if (< (raw-value (tesl_import_String_length *projectId)) 3) (reject "invalid project id" #:http-code 400) (accept (ValidProjectId projectId) #:value *projectId)))

(define-checker
  (checkIssueId [issueId : String])
  #:returns [issueId : String ::: (ValidIssueId issueId)]
  (if (< (raw-value (tesl_import_String_length *issueId)) 3) (reject "invalid issue id" #:http-code 400) (accept (ValidIssueId issueId) #:value *issueId)))

(define-checker
  (checkInvoiceId [invoiceId : String])
  #:returns [invoiceId : String ::: (ValidInvoiceId invoiceId)]
  (if (< (raw-value (tesl_import_String_length *invoiceId)) 3) (reject "invalid invoice id" #:http-code 400) (accept (ValidInvoiceId invoiceId) #:value *invoiceId)))

(define-checker
  (checkUserId [userId : String])
  #:returns [userId : String ::: (ValidUserId userId)]
  (if (< (raw-value (tesl_import_String_length *userId)) 3) (reject "invalid user id" #:http-code 400) (accept (ValidUserId userId) #:value *userId)))

(define-checker
  (checkTargetUserId [targetUserId : String])
  #:returns [targetUserId : String ::: (ValidUserId targetUserId)]
  (if (< (raw-value (tesl_import_String_length *targetUserId)) 3) (reject "invalid user id" #:http-code 400) (accept (ValidUserId targetUserId) #:value *targetUserId)))

(define (tesl-codec-encode-OrgRole _v)
  (define _raw (raw-value _v))
  (cond
    [(equal? _raw RoleAdmin) (hash "tag" "RoleAdmin")]
    [(equal? _raw RoleMember) (hash "tag" "RoleMember")]
    [(equal? _raw RoleViewer) (hash "tag" "RoleViewer")]
    [else (error (format "OrgRole: unexpected value ~~a" _raw))]))
(define (tesl-codec-decode-OrgRole-0 _j)
  (define _tag
    (cond [(hash? _j) (or (hash-ref _j "tag" #f) (hash-ref _j 'tag #f))]
          [(string? _j) _j]
          [else #f]))
  (unless _tag (error (format "OrgRole: expected {{\"tag\": ...}} or string, got ~~a" _j)))
  (cond
    [(equal? _tag "RoleAdmin") RoleAdmin]
    [(equal? _tag "RoleMember") RoleMember]
    [(equal? _tag "RoleViewer") RoleViewer]
    [else (error (format "OrgRole: expected one of RoleAdmin, RoleMember, RoleViewer, got ~~a" _tag))]))
(register-type-codec! 'OrgRole tesl-codec-encode-OrgRole (list tesl-codec-decode-OrgRole-0))

(define (tesl-codec-encode-IssueStatus _v)
  (define _raw (raw-value _v))
  (cond
    [(equal? _raw Backlog) (hash "tag" "Backlog")]
    [(equal? _raw Todo) (hash "tag" "Todo")]
    [(equal? _raw InProgress) (hash "tag" "InProgress")]
    [(equal? _raw InReview) (hash "tag" "InReview")]
    [(equal? _raw Done) (hash "tag" "Done")]
    [(equal? _raw Cancelled) (hash "tag" "Cancelled")]
    [else (error (format "IssueStatus: unexpected value ~~a" _raw))]))
(define (tesl-codec-decode-IssueStatus-0 _j)
  (define _tag
    (cond [(hash? _j) (or (hash-ref _j "tag" #f) (hash-ref _j 'tag #f))]
          [(string? _j) _j]
          [else #f]))
  (unless _tag (error (format "IssueStatus: expected {{\"tag\": ...}} or string, got ~~a" _j)))
  (cond
    [(equal? _tag "Backlog") Backlog]
    [(equal? _tag "Todo") Todo]
    [(equal? _tag "InProgress") InProgress]
    [(equal? _tag "InReview") InReview]
    [(equal? _tag "Done") Done]
    [(equal? _tag "Cancelled") Cancelled]
    [else (error (format "IssueStatus: expected one of Backlog, Todo, InProgress, InReview, Done, Cancelled, got ~~a" _tag))]))
(register-type-codec! 'IssueStatus tesl-codec-encode-IssueStatus (list tesl-codec-decode-IssueStatus-0))

(define (tesl-codec-encode-InvoiceStatus _v)
  (define _raw (raw-value _v))
  (cond
    [(equal? _raw Draft) (hash "tag" "Draft")]
    [(equal? _raw Approved) (hash "tag" "Approved")]
    [(equal? _raw Sent) (hash "tag" "Sent")]
    [(equal? _raw Paid) (hash "tag" "Paid")]
    [(equal? _raw Overdue) (hash "tag" "Overdue")]
    [else (error (format "InvoiceStatus: unexpected value ~~a" _raw))]))
(define (tesl-codec-decode-InvoiceStatus-0 _j)
  (define _tag
    (cond [(hash? _j) (or (hash-ref _j "tag" #f) (hash-ref _j 'tag #f))]
          [(string? _j) _j]
          [else #f]))
  (unless _tag (error (format "InvoiceStatus: expected {{\"tag\": ...}} or string, got ~~a" _j)))
  (cond
    [(equal? _tag "Draft") Draft]
    [(equal? _tag "Approved") Approved]
    [(equal? _tag "Sent") Sent]
    [(equal? _tag "Paid") Paid]
    [(equal? _tag "Overdue") Overdue]
    [else (error (format "InvoiceStatus: expected one of Draft, Approved, Sent, Paid, Overdue, got ~~a" _tag))]))
(register-type-codec! 'InvoiceStatus tesl-codec-encode-InvoiceStatus (list tesl-codec-decode-InvoiceStatus-0))

(define (tesl-codec-encode-NewOrgRequest _v)
  (error "toJson is forbidden for type NewOrgRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewOrgRequest-0 _j)
  (define _f_name (tesl-codec-decode-field _j "name" tesl-json-string-codec))
  (define _f_slug (tesl-codec-decode-field _j "slug" tesl-json-string-codec))
  (record-value 'NewOrgRequest (hash 'name _f_name 'slug _f_slug)))
(register-type-codec! 'NewOrgRequest tesl-codec-encode-NewOrgRequest (list tesl-codec-decode-NewOrgRequest-0))

(define (tesl-codec-encode-NewProjectRequest _v)
  (error "toJson is forbidden for type NewProjectRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewProjectRequest-0 _j)
  (define _f_name (tesl-codec-decode-field _j "name" tesl-json-string-codec))
  (define _f_description (tesl-codec-decode-field _j "description" tesl-json-string-codec))
  (record-value 'NewProjectRequest (hash 'name _f_name 'description _f_description)))
(register-type-codec! 'NewProjectRequest tesl-codec-encode-NewProjectRequest (list tesl-codec-decode-NewProjectRequest-0))

(define (tesl-codec-encode-NewIssueRequest _v)
  (error "toJson is forbidden for type NewIssueRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewIssueRequest-0 _j)
  (define _f_title (tesl-codec-decode-field _j "title" tesl-json-string-codec))
  (define _f_description (tesl-codec-decode-field _j "description" tesl-json-string-codec))
  (define _f_estimate (tesl-codec-decode-field _j "estimate" tesl-json-int-codec))
  (record-value 'NewIssueRequest (hash 'title _f_title 'description _f_description 'estimate _f_estimate)))
(register-type-codec! 'NewIssueRequest tesl-codec-encode-NewIssueRequest (list tesl-codec-decode-NewIssueRequest-0))

(define (tesl-codec-encode-UpdateIssueRequest _v)
  (error "toJson is forbidden for type UpdateIssueRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-UpdateIssueRequest-0 _j)
  (define _f_title (tesl-codec-decode-field _j "title" tesl-json-string-codec))
  (define _f_description (tesl-codec-decode-field _j "description" tesl-json-string-codec))
  (define _f_estimate (tesl-codec-decode-field _j "estimate" tesl-json-int-codec))
  (define _f_assigneeId (tesl-codec-decode-field _j "assigneeId" tesl-json-string-codec))
  (record-value 'UpdateIssueRequest (hash 'title _f_title 'description _f_description 'estimate _f_estimate 'assigneeId _f_assigneeId)))
(register-type-codec! 'UpdateIssueRequest tesl-codec-encode-UpdateIssueRequest (list tesl-codec-decode-UpdateIssueRequest-0))

(define (tesl-codec-encode-UpdateStatusRequest _v)
  (error "toJson is forbidden for type UpdateStatusRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-UpdateStatusRequest-0 _j)
  (define _f_newStatus (tesl-codec-decode-field _j "newStatus" 'IssueStatus))
  (record-value 'UpdateStatusRequest (hash 'newStatus _f_newStatus)))
(register-type-codec! 'UpdateStatusRequest tesl-codec-encode-UpdateStatusRequest (list tesl-codec-decode-UpdateStatusRequest-0))

(define (tesl-codec-encode-NewCommentRequest _v)
  (error "toJson is forbidden for type NewCommentRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewCommentRequest-0 _j)
  (define _f_body (tesl-codec-decode-field _j "body" tesl-json-string-codec))
  (record-value 'NewCommentRequest (hash 'body _f_body)))
(register-type-codec! 'NewCommentRequest tesl-codec-encode-NewCommentRequest (list tesl-codec-decode-NewCommentRequest-0))

(define (tesl-codec-encode-NewTimeEntryRequest _v)
  (error "toJson is forbidden for type NewTimeEntryRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewTimeEntryRequest-0 _j)
  (define _f_minutes (tesl-codec-decode-field _j "minutes" tesl-json-int-codec))
  (define _f_description (tesl-codec-decode-field _j "description" tesl-json-string-codec))
  (record-value 'NewTimeEntryRequest (hash 'minutes _f_minutes 'description _f_description)))
(register-type-codec! 'NewTimeEntryRequest tesl-codec-encode-NewTimeEntryRequest (list tesl-codec-decode-NewTimeEntryRequest-0))

(define (tesl-codec-encode-NewInvoiceRequest _v)
  (error "toJson is forbidden for type NewInvoiceRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-NewInvoiceRequest-0 _j)
  (define _f_notes (tesl-codec-decode-field _j "notes" tesl-json-string-codec))
  (record-value 'NewInvoiceRequest (hash 'notes _f_notes)))
(register-type-codec! 'NewInvoiceRequest tesl-codec-encode-NewInvoiceRequest (list tesl-codec-decode-NewInvoiceRequest-0))
