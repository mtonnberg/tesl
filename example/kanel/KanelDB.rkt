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
  (only-in tesl/tesl/prelude Bool Int String List Unit)
  (only-in tesl/tesl/list [List.foldl tesl_import_List_foldl] [List.append tesl_import_List_append])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/time nowMillis time [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/db DeleteResult NoRowDeleted RowsDeleted)
  (only-in (file "KanelModels.rkt") kanelDbRead kanelDbWrite KanelUser Org OrgMembership Project Issue IssueComment TimeEntry Invoice OrgRole RoleAdmin RoleMember RoleViewer IssueStatus Backlog Todo InProgress InReview Done Cancelled InvoiceStatus Draft Approved Sent Paid Overdue)
  (only-in (file "KanelAuth.rkt") OrgMember OrgAdmin ProjMember)
  (only-in (file "KanelOrg.rkt") ValidOrgName ValidSlug ValidEmail ValidDisplayName)
  (only-in (file "KanelIssues.rkt") ValidTitle ValidDescription PositiveEstimate PositiveMinutes NotDone ValidCommentBody)
  (only-in (file "KanelBilling.rkt") InvoiceDraft)
)


(provide dbGetOrg dbListOrgs dbInsertOrg dbGetOrgMembership dbListOrgMembers dbInsertOrgMembership dbUpdateMemberRole dbDeleteMembership dbGetUser dbGetUserByEmail dbInsertUser dbGetProject dbListProjects dbInsertProject dbArchiveProject dbGetIssue dbListIssues dbInsertIssue dbUpdateIssueFields dbUpdateIssueStatus dbInsertComment dbListComments dbInsertTimeEntry dbListTimeEntries dbListUnbilledEntries dbMarkEntriesBilled dbGetInvoice dbListInvoices dbInsertInvoice dbUpdateInvoiceStatus dbGetOrg-signature dbListOrgs-signature dbInsertOrg-signature dbGetOrgMembership-signature dbListOrgMembers-signature dbInsertOrgMembership-signature dbUpdateMemberRole-signature dbDeleteMembership-signature dbGetUser-signature dbGetUserByEmail-signature dbInsertUser-signature dbGetProject-signature dbListProjects-signature dbInsertProject-signature dbArchiveProject-signature dbGetIssue-signature dbListIssues-signature dbInsertIssue-signature dbUpdateIssueFields-signature dbUpdateIssueStatus-signature dbInsertComment-signature dbListComments-signature dbInsertTimeEntry-signature dbListTimeEntries-signature dbListUnbilledEntries-signature dbMarkEntriesBilled-signature dbGetInvoice-signature dbListInvoices-signature dbInsertInvoice-signature dbUpdateInvoiceStatus-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/kanel/KanelDB.tesl" '(91 95 102 113 117 138 142 152 156 173 177 216 226 230 242 246))
(define/pow
  (dbGetOrg [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Org)
  (thsl-src! "example/kanel/KanelDB.tesl" 91 (list (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'id) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbFetchOrgByMembership [acc : (List Org)] [m : OrgMembership])
  #:capabilities [kanelDbRead]
  #:returns (List Org)
  (let ([found (thsl-src! "example/kanel/KanelDB.tesl" 95 (list (cons 'acc *acc) (cons 'm *m)) (lambda () (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'id) (tesl-dot/runtime m 'orgId 'OrgMembership))))]) (if tesl_match (Something tesl_match) Nothing))) 'found)]) (thsl-src-control! "example/kanel/KanelDB.tesl" 96 (list (cons 'found *found) (cons 'acc *acc) (cons 'm *m)) (lambda () (let ([tesl-case-0 (raw-value found)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/kanel/KanelDB.tesl" 97 (list) (lambda () *acc))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/kanel/KanelDB.tesl" 98 (list (cons 'o o)) (lambda () (raw-value (tesl_import_List_append *acc (list *o))))))]))))))

(define/pow
  (dbListOrgs [userId : String])
  #:capabilities [kanelDbRead]
  #:returns (List Org)
  (let ([memberships (thsl-src! "example/kanel/KanelDB.tesl" 102 (list (cons 'userId *userId)) (lambda () (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)))) 'memberships)]) (thsl-src! "example/kanel/KanelDB.tesl" 103 (list (cons 'memberships *memberships) (cons 'userId *userId)) (lambda () (raw-value (tesl_import_List_foldl dbFetchOrgByMembership (list) (raw-value memberships)))))))

(define/pow
  (dbInsertOrg [orgId : String] [name : String ::: (ValidOrgName name)] [slug : String ::: (ValidSlug slug)])
  #:capabilities [kanelDbWrite time]
  #:returns (? Org _entity ::: (FromDb (Id == orgId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 107 (list (cons 'orgId *orgId) (cons 'name *name) (cons 'slug *slug)) (lambda () (insert-one! Org (tesl-hash 'id orgId 'name name 'slug slug 'createdAt (raw-value (nowMillis)))))))

(define/pow
  (dbGetOrgMembership [userId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns (Maybe OrgMembership)
  (thsl-src! "example/kanel/KanelDB.tesl" 113 (list (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbListOrgMembers [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List OrgMembership)
  (thsl-src! "example/kanel/KanelDB.tesl" 117 (list (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))))

(define/pow
  (dbInsertOrgMembership [memberId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [targetUserId : String] [role : OrgRole])
  #:capabilities [kanelDbWrite time]
  #:returns (? OrgMembership _entity ::: (FromDb (Id == memberId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 121 (list (cons 'memberId *memberId) (cons 'orgId *orgId) (cons 'adminId *adminId) (cons 'targetUserId *targetUserId) (cons 'role *role)) (lambda () (insert-one! OrgMembership (tesl-hash 'id memberId 'orgId orgId 'userId targetUserId 'role role 'joinedAt (raw-value (nowMillis)))))))

(define/pow
  (dbUpdateMemberRole [targetUserId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [newRole : OrgRole])
  #:capabilities [kanelDbWrite]
  #:returns OrgMembership
  (thsl-src! "example/kanel/KanelDB.tesl" 125 (list (cons 'targetUserId *targetUserId) (cons 'orgId *orgId) (cons 'adminId *adminId) (cons 'newRole *newRole)) (lambda () (car (update-many! (from OrgMembership) (tesl-hash (entity-field-ref OrgMembership 'role) newRole) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))))))

(define/pow
  (dbDeleteMembership [targetUserId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbWrite]
  #:returns DeleteResult
  (thsl-src! "example/kanel/KanelDB.tesl" 132 (list (cons 'targetUserId *targetUserId) (cons 'orgId *orgId) (cons 'adminId *adminId)) (lambda () (delete-many-with-count! (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))))

(define/pow
  (dbGetUser [userId : String])
  #:capabilities [kanelDbRead]
  #:returns (Maybe KanelUser)
  (thsl-src! "example/kanel/KanelDB.tesl" 138 (list (cons 'userId *userId)) (lambda () (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'id) userId)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbGetUserByEmail [email : String])
  #:capabilities [kanelDbRead]
  #:returns (Maybe KanelUser)
  (thsl-src! "example/kanel/KanelDB.tesl" 142 (list (cons 'email *email)) (lambda () (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'email) email)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbInsertUser [userId : String] [email : String ::: (ValidEmail email)] [displayName : String ::: (ValidDisplayName displayName)] [passwordHash : String])
  #:capabilities [kanelDbWrite time]
  #:returns (? KanelUser _entity ::: (FromDb (Id == userId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 146 (list (cons 'userId *userId) (cons 'email *email) (cons 'displayName *displayName) (cons 'passwordHash *passwordHash)) (lambda () (insert-one! KanelUser (tesl-hash 'id userId 'email email 'passwordHash passwordHash 'displayName displayName 'createdAt (raw-value (nowMillis)))))))

(define/pow
  (dbGetProject [projectId : String] [userId : String ::: (ProjMember userId projectId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Project)
  (thsl-src! "example/kanel/KanelDB.tesl" 152 (list (cons 'projectId *projectId) (cons 'userId *userId)) (lambda () (let ([tesl_match (select-one (from Project) (where (==. (entity-field-ref Project 'id) projectId)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbListProjects [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List Project)
  (thsl-src! "example/kanel/KanelDB.tesl" 156 (list (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (select-many (from Project) (where (==. (entity-field-ref Project 'orgId) orgId)) (where (==. (entity-field-ref Project 'archived) #f))))))

(define/pow
  (dbInsertProject [projectId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [name : String ::: (ValidTitle name)] [description : String ::: (ValidDescription description)])
  #:capabilities [kanelDbWrite time]
  #:returns (? Project _entity ::: (FromDb (Id == projectId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 160 (list (cons 'projectId *projectId) (cons 'orgId *orgId) (cons 'adminId *adminId) (cons 'name *name) (cons 'description *description)) (lambda () (insert-one! Project (tesl-hash 'id projectId 'orgId orgId 'name name 'description description 'archived #f 'createdAt (raw-value (nowMillis)))))))

(define/pow
  (dbArchiveProject [projectId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbWrite]
  #:returns Project
  (thsl-src! "example/kanel/KanelDB.tesl" 164 (list (cons 'projectId *projectId) (cons 'orgId *orgId) (cons 'adminId *adminId)) (lambda () (car (update-many! (from Project) (tesl-hash (entity-field-ref Project 'archived) #t) (where (==. (entity-field-ref Project 'id) projectId)))))))

(define/pow
  (dbGetIssue [issueId : String] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Issue)
  (thsl-src! "example/kanel/KanelDB.tesl" 173 (list (cons 'issueId *issueId) (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (let ([tesl_match (select-one (from Issue) (where (==. (entity-field-ref Issue 'id) issueId)) (where (==. (entity-field-ref Issue 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbListIssues [projectId : String] [userId : String ::: (ProjMember userId projectId)])
  #:capabilities [kanelDbRead]
  #:returns (List Issue)
  (thsl-src! "example/kanel/KanelDB.tesl" 177 (list (cons 'projectId *projectId) (cons 'userId *userId)) (lambda () (select-many (from Issue) (where (==. (entity-field-ref Issue 'projectId) projectId))))))

(define/pow
  (dbInsertIssue [issueId : String] [projectId : String] [orgId : String] [userId : String ::: (ProjMember userId projectId)] [title : String ::: (ValidTitle title)] [description : String ::: (ValidDescription description)] [estimate : Integer ::: (PositiveEstimate estimate)])
  #:capabilities [kanelDbWrite time]
  #:returns (? Issue _entity ::: (FromDb (Id == issueId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 181 (list (cons 'issueId *issueId) (cons 'projectId *projectId) (cons 'orgId *orgId) (cons 'userId *userId) (cons 'title *title) (cons 'description *description) (cons 'estimate *estimate)) (lambda () (insert-one! Issue (tesl-hash 'id issueId 'projectId projectId 'orgId orgId 'title title 'description description 'status Backlog 'assigneeId Nothing 'reporterId userId 'estimate estimate 'dueAt Nothing 'createdAt (raw-value (nowMillis)) 'updatedAt (raw-value (nowMillis)))))))

(define/pow
  (dbUpdateIssueFields [issueId : String ::: (NotDone issueId)] [orgId : String] [userId : String ::: (OrgMember userId orgId)] [title : String ::: (ValidTitle title)] [description : String ::: (ValidDescription description)] [estimate : Integer ::: (PositiveEstimate estimate)] [assigneeId : String])
  #:capabilities [kanelDbWrite time]
  #:returns Issue
  (thsl-src! "example/kanel/KanelDB.tesl" 191 (list (cons 'issueId *issueId) (cons 'orgId *orgId) (cons 'userId *userId) (cons 'title *title) (cons 'description *description) (cons 'estimate *estimate) (cons 'assigneeId *assigneeId)) (lambda () (car (update-many! (from Issue) (tesl-hash (entity-field-ref Issue 'title) title (entity-field-ref Issue 'description) description (entity-field-ref Issue 'estimate) estimate (entity-field-ref Issue 'assigneeId) assigneeId (entity-field-ref Issue 'updatedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Issue 'id) issueId)))))))

(define/pow
  (dbUpdateIssueStatus [issueId : String] [newStatus : IssueStatus] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbWrite time]
  #:returns Issue
  (thsl-src! "example/kanel/KanelDB.tesl" 202 (list (cons 'issueId *issueId) (cons 'newStatus *newStatus) (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (car (update-many! (from Issue) (tesl-hash (entity-field-ref Issue 'status) newStatus (entity-field-ref Issue 'updatedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Issue 'id) issueId)))))))

(define/pow
  (dbInsertComment [commentId : String] [issueId : String ::: (NotDone issueId)] [orgId : String] [authorId : String ::: (OrgMember authorId orgId)] [body : String ::: (ValidCommentBody body)])
  #:capabilities [kanelDbWrite time]
  #:returns (? IssueComment _entity ::: (FromDb (Id == commentId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 212 (list (cons 'commentId *commentId) (cons 'issueId *issueId) (cons 'orgId *orgId) (cons 'authorId *authorId) (cons 'body *body)) (lambda () (insert-one! IssueComment (tesl-hash 'id commentId 'issueId issueId 'authorId authorId 'body body 'createdAt (raw-value (nowMillis)))))))

(define/pow
  (dbListComments [issueId : String] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List IssueComment)
  (thsl-src! "example/kanel/KanelDB.tesl" 216 (list (cons 'issueId *issueId) (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (select-many (from IssueComment) (where (==. (entity-field-ref IssueComment 'issueId) issueId))))))

(define/pow
  (dbInsertTimeEntry [entryId : String] [issueId : String ::: (NotDone issueId)] [orgId : String] [userId : String ::: (OrgMember userId orgId)] [minutes : Integer ::: (PositiveMinutes minutes)] [description : String])
  #:capabilities [kanelDbWrite time]
  #:returns (? TimeEntry _entity ::: (FromDb (Id == entryId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 222 (list (cons 'entryId *entryId) (cons 'issueId *issueId) (cons 'orgId *orgId) (cons 'userId *userId) (cons 'minutes *minutes) (cons 'description *description)) (lambda () (insert-one! TimeEntry (tesl-hash 'id entryId 'issueId issueId 'userId userId 'orgId orgId 'minutes minutes 'description description 'invoiceId "" 'loggedAt (raw-value (nowMillis)))))))

(define/pow
  (dbListTimeEntries [issueId : String] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List TimeEntry)
  (thsl-src! "example/kanel/KanelDB.tesl" 226 (list (cons 'issueId *issueId) (cons 'orgId *orgId) (cons 'userId *userId)) (lambda () (select-many (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'issueId) issueId))))))

(define/pow
  (dbListUnbilledEntries [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List TimeEntry)
  (thsl-src! "example/kanel/KanelDB.tesl" 230 (list (cons 'orgId *orgId) (cons 'adminId *adminId)) (lambda () (select-many (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) ""))))))

(define/pow
  (dbMarkEntriesBilled [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [invoiceId : String])
  #:capabilities [kanelDbWrite]
  #:returns Unit
  (thsl-src! "example/kanel/KanelDB.tesl" 234 (list (cons 'orgId *orgId) (cons 'adminId *adminId) (cons 'invoiceId *invoiceId)) (lambda () (void (update-many! (from TimeEntry) (tesl-hash (entity-field-ref TimeEntry 'invoiceId) invoiceId) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) "")))))))

(define/pow
  (dbGetInvoice [invoiceId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Invoice)
  (thsl-src! "example/kanel/KanelDB.tesl" 242 (list (cons 'invoiceId *invoiceId) (cons 'orgId *orgId) (cons 'adminId *adminId)) (lambda () (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (dbListInvoices [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List Invoice)
  (thsl-src! "example/kanel/KanelDB.tesl" 246 (list (cons 'orgId *orgId) (cons 'adminId *adminId)) (lambda () (select-many (from Invoice) (where (==. (entity-field-ref Invoice 'orgId) orgId))))))

(define/pow
  (dbInsertInvoice [invoiceId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [totalMinutes : Integer] [notes : String])
  #:capabilities [kanelDbWrite time]
  #:returns (? Invoice _entity ::: (FromDb (Id == invoiceId) _entity))
  (thsl-src! "example/kanel/KanelDB.tesl" 250 (list (cons 'invoiceId *invoiceId) (cons 'orgId *orgId) (cons 'adminId *adminId) (cons 'totalMinutes *totalMinutes) (cons 'notes *notes)) (lambda () (insert-one! Invoice (tesl-hash 'id invoiceId 'orgId orgId 'status Draft 'totalMinutes totalMinutes 'notes notes 'createdAt (raw-value (nowMillis)) 'approvedAt (raw-value (tesl_import_Time_secondsToPosix 0)))))))

(define/pow
  (dbUpdateInvoiceStatus [invoiceId : String ::: (InvoiceDraft invoiceId)] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [newStatus : InvoiceStatus])
  #:capabilities [kanelDbWrite time]
  #:returns Invoice
  (thsl-src! "example/kanel/KanelDB.tesl" 254 (list (cons 'invoiceId *invoiceId) (cons 'orgId *orgId) (cons 'adminId *adminId) (cons 'newStatus *newStatus)) (lambda () (car (update-many! (from Invoice) (tesl-hash (entity-field-ref Invoice 'status) newStatus (entity-field-ref Invoice 'approvedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))))))
