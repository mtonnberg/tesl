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
  (only-in tesl/tesl/prelude Bool Int String List Unit)
  (only-in tesl/tesl/list [List.foldl tesl_import_List_foldl] [List.append tesl_import_List_append])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/time nowMillis time [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/db DeleteResult NoRowDeleted RowsDeleted)
  (only-in tesl/example/kanel/kanel-models kanelDbRead kanelDbWrite KanelUser Org OrgMembership Project Issue IssueComment TimeEntry Invoice OrgRole RoleAdmin RoleMember RoleViewer IssueStatus Backlog Todo InProgress InReview Done Cancelled InvoiceStatus Draft Approved Sent Paid Overdue)
  (only-in tesl/example/kanel/kanel-auth OrgMember OrgAdmin ProjMember)
  (only-in tesl/example/kanel/kanel-org ValidOrgName ValidSlug ValidEmail ValidDisplayName)
  (only-in tesl/example/kanel/kanel-issues ValidTitle ValidDescription PositiveEstimate PositiveMinutes NotDone ValidCommentBody)
  (only-in tesl/example/kanel/kanel-billing InvoiceDraft)
)


(provide dbGetOrg dbListOrgs dbInsertOrg dbGetOrgMembership dbListOrgMembers dbInsertOrgMembership dbUpdateMemberRole dbDeleteMembership dbGetUser dbGetUserByEmail dbInsertUser dbGetProject dbListProjects dbInsertProject dbArchiveProject dbGetIssue dbListIssues dbInsertIssue dbUpdateIssueFields dbUpdateIssueStatus dbInsertComment dbListComments dbInsertTimeEntry dbListTimeEntries dbListUnbilledEntries dbMarkEntriesBilled dbGetInvoice dbListInvoices dbInsertInvoice dbUpdateInvoiceStatus dbGetOrg-signature dbListOrgs-signature dbInsertOrg-signature dbGetOrgMembership-signature dbListOrgMembers-signature dbInsertOrgMembership-signature dbUpdateMemberRole-signature dbDeleteMembership-signature dbGetUser-signature dbGetUserByEmail-signature dbInsertUser-signature dbGetProject-signature dbListProjects-signature dbInsertProject-signature dbArchiveProject-signature dbGetIssue-signature dbListIssues-signature dbInsertIssue-signature dbUpdateIssueFields-signature dbUpdateIssueStatus-signature dbInsertComment-signature dbListComments-signature dbInsertTimeEntry-signature dbListTimeEntries-signature dbListUnbilledEntries-signature dbMarkEntriesBilled-signature dbGetInvoice-signature dbListInvoices-signature dbInsertInvoice-signature dbUpdateInvoiceStatus-signature)

(define/pow
  (dbGetOrg [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Org)
  (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'id) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbFetchOrgByMembership [acc : (List Org)] [m : OrgMembership])
  #:capabilities [kanelDbRead]
  #:returns (List Org)
  (let ([found (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'id) (raw-value (tesl-dot/runtime m 'orgId)))))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_0 (raw-value found)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) acc] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (tesl_import_List_append *acc (list *o)))]))))

(define/pow
  (dbListOrgs [userId : String])
  #:capabilities [kanelDbRead]
  #:returns (List Org)
  (let ([memberships (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)))]) (raw-value (tesl_import_List_foldl dbFetchOrgByMembership (list) *memberships))))

(define/pow
  (dbInsertOrg [orgId : String] [name : String ::: (ValidOrgName name)] [slug : String ::: (ValidSlug slug)])
  #:capabilities [kanelDbWrite time]
  #:returns (? Org _entity ::: (FromDb (Id == orgId) _entity))
  (insert-one! Org (hash 'id orgId 'name name 'slug slug 'createdAt (raw-value (nowMillis)))))

(define/pow
  (dbGetOrgMembership [userId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns (Maybe OrgMembership)
  (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbListOrgMembers [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List OrgMembership)
  (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))

(define/pow
  (dbInsertOrgMembership [memberId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [targetUserId : String] [role : OrgRole])
  #:capabilities [kanelDbWrite time]
  #:returns (? OrgMembership _entity ::: (FromDb (Id == memberId) _entity))
  (insert-one! OrgMembership (hash 'id memberId 'orgId orgId 'userId targetUserId 'role role 'joinedAt (raw-value (nowMillis)))))

(define/pow
  (dbUpdateMemberRole [targetUserId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [newRole : OrgRole])
  #:capabilities [kanelDbWrite]
  #:returns OrgMembership
  (car (update-many! (from OrgMembership) (hash (entity-field-ref OrgMembership 'role) newRole) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))))

(define/pow
  (dbDeleteMembership [targetUserId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbWrite]
  #:returns DeleteResult
  (delete-many-with-count! (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))

(define/pow
  (dbGetUser [userId : String])
  #:capabilities [kanelDbRead]
  #:returns (Maybe KanelUser)
  (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'id) userId)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbGetUserByEmail [email : String])
  #:capabilities [kanelDbRead]
  #:returns (Maybe KanelUser)
  (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'email) email)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbInsertUser [userId : String] [email : String ::: (ValidEmail email)] [displayName : String ::: (ValidDisplayName displayName)] [passwordHash : String])
  #:capabilities [kanelDbWrite time]
  #:returns (? KanelUser _entity ::: (FromDb (Id == userId) _entity))
  (insert-one! KanelUser (hash 'id userId 'email email 'passwordHash passwordHash 'displayName displayName 'createdAt (raw-value (nowMillis)))))

(define/pow
  (dbGetProject [projectId : String] [userId : String ::: (ProjMember userId projectId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Project)
  (let ([tesl_match (select-one (from Project) (where (==. (entity-field-ref Project 'id) projectId)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbListProjects [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List Project)
  (select-many (from Project) (where (==. (entity-field-ref Project 'orgId) orgId)) (where (==. (entity-field-ref Project 'archived) #f))))

(define/pow
  (dbInsertProject [projectId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [name : String ::: (ValidTitle name)] [description : String ::: (ValidDescription description)])
  #:capabilities [kanelDbWrite time]
  #:returns (? Project _entity ::: (FromDb (Id == projectId) _entity))
  (insert-one! Project (hash 'id projectId 'orgId orgId 'name name 'description description 'archived #f 'createdAt (raw-value (nowMillis)))))

(define/pow
  (dbArchiveProject [projectId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbWrite]
  #:returns Project
  (car (update-many! (from Project) (hash (entity-field-ref Project 'archived) #t) (where (==. (entity-field-ref Project 'id) projectId)))))

(define/pow
  (dbGetIssue [issueId : String] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Issue)
  (let ([tesl_match (select-one (from Issue) (where (==. (entity-field-ref Issue 'id) issueId)) (where (==. (entity-field-ref Issue 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbListIssues [projectId : String] [userId : String ::: (ProjMember userId projectId)])
  #:capabilities [kanelDbRead]
  #:returns (List Issue)
  (select-many (from Issue) (where (==. (entity-field-ref Issue 'projectId) projectId))))

(define/pow
  (dbInsertIssue [issueId : String] [projectId : String] [orgId : String] [userId : String ::: (ProjMember userId projectId)] [title : String ::: (ValidTitle title)] [description : String ::: (ValidDescription description)] [estimate : Integer ::: (PositiveEstimate estimate)])
  #:capabilities [kanelDbWrite time]
  #:returns (? Issue _entity ::: (FromDb (Id == issueId) _entity))
  (insert-one! Issue (hash 'id issueId 'projectId projectId 'orgId orgId 'title title 'description description 'status Backlog 'assigneeId Nothing 'reporterId userId 'estimate estimate 'dueAt Nothing 'createdAt (raw-value (nowMillis)) 'updatedAt (raw-value (nowMillis)))))

(define/pow
  (dbUpdateIssueFields [issueId : String ::: (NotDone issueId)] [orgId : String] [userId : String ::: (OrgMember userId orgId)] [title : String ::: (ValidTitle title)] [description : String ::: (ValidDescription description)] [estimate : Integer ::: (PositiveEstimate estimate)] [assigneeId : String])
  #:capabilities [kanelDbWrite time]
  #:returns Issue
  (car (update-many! (from Issue) (hash (entity-field-ref Issue 'title) title (entity-field-ref Issue 'description) description (entity-field-ref Issue 'estimate) estimate (entity-field-ref Issue 'assigneeId) assigneeId (entity-field-ref Issue 'updatedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Issue 'id) issueId)))))

(define/pow
  (dbUpdateIssueStatus [issueId : String] [newStatus : IssueStatus] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbWrite time]
  #:returns Issue
  (car (update-many! (from Issue) (hash (entity-field-ref Issue 'status) newStatus (entity-field-ref Issue 'updatedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Issue 'id) issueId)))))

(define/pow
  (dbInsertComment [commentId : String] [issueId : String ::: (NotDone issueId)] [orgId : String] [authorId : String ::: (OrgMember authorId orgId)] [body : String ::: (ValidCommentBody body)])
  #:capabilities [kanelDbWrite time]
  #:returns (? IssueComment _entity ::: (FromDb (Id == commentId) _entity))
  (insert-one! IssueComment (hash 'id commentId 'issueId issueId 'authorId authorId 'body body 'createdAt (raw-value (nowMillis)))))

(define/pow
  (dbListComments [issueId : String] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List IssueComment)
  (select-many (from IssueComment) (where (==. (entity-field-ref IssueComment 'issueId) issueId))))

(define/pow
  (dbInsertTimeEntry [entryId : String] [issueId : String ::: (NotDone issueId)] [orgId : String] [userId : String ::: (OrgMember userId orgId)] [minutes : Integer ::: (PositiveMinutes minutes)] [description : String])
  #:capabilities [kanelDbWrite time]
  #:returns (? TimeEntry _entity ::: (FromDb (Id == entryId) _entity))
  (insert-one! TimeEntry (hash 'id entryId 'issueId issueId 'userId userId 'orgId orgId 'minutes minutes 'description description 'invoiceId "" 'loggedAt (raw-value (nowMillis)))))

(define/pow
  (dbListTimeEntries [issueId : String] [orgId : String] [userId : String ::: (OrgMember userId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List TimeEntry)
  (select-many (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'issueId) issueId))))

(define/pow
  (dbListUnbilledEntries [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List TimeEntry)
  (select-many (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) ""))))

(define/pow
  (dbMarkEntriesBilled [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [invoiceId : String])
  #:capabilities [kanelDbWrite]
  #:returns Unit
  (void (update-many! (from TimeEntry) (hash (entity-field-ref TimeEntry 'invoiceId) invoiceId) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (==. (entity-field-ref TimeEntry 'invoiceId) "")))))

(define/pow
  (dbGetInvoice [invoiceId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (Maybe Invoice)
  (let ([tesl_match (select-one (from Invoice) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing)))

(define/pow
  (dbListInvoices [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List Invoice)
  (select-many (from Invoice) (where (==. (entity-field-ref Invoice 'orgId) orgId))))

(define/pow
  (dbInsertInvoice [invoiceId : String] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [totalMinutes : Integer] [notes : String])
  #:capabilities [kanelDbWrite time]
  #:returns (? Invoice _entity ::: (FromDb (Id == invoiceId) _entity))
  (insert-one! Invoice (hash 'id invoiceId 'orgId orgId 'status Draft 'totalMinutes totalMinutes 'notes notes 'createdAt (raw-value (nowMillis)) 'approvedAt (raw-value (tesl_import_Time_secondsToPosix 0)))))

(define/pow
  (dbUpdateInvoiceStatus [invoiceId : String ::: (InvoiceDraft invoiceId)] [orgId : String] [adminId : String ::: (OrgAdmin adminId orgId)] [newStatus : InvoiceStatus])
  #:capabilities [kanelDbWrite time]
  #:returns Invoice
  (car (update-many! (from Invoice) (hash (entity-field-ref Invoice 'status) newStatus (entity-field-ref Invoice 'approvedAt) (raw-value (nowMillis))) (where (==. (entity-field-ref Invoice 'id) invoiceId)) (where (==. (entity-field-ref Invoice 'orgId) orgId)))))
