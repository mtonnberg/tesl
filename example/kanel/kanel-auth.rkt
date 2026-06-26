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
  (only-in tesl/tesl/prelude String Fact)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in (file "kanel-models.rkt") kanelDbRead KanelUser OrgMembership ProjectMembership Issue OrgRole RoleAdmin RoleMember RoleViewer)
)


(provide KanelSession Authenticated cookieAuth OrgMember OrgAdmin ProjMember IssueAssignee checkOrgMember checkOrgAdmin checkProjMember checkIssueAssignee cookieAuth-signature checkOrgMember-signature checkOrgAdmin-signature checkProjMember-signature checkIssueAssignee-signature)

(define Authenticated 'Authenticated)
(define IssueAssignee 'IssueAssignee)
(define OrgAdmin 'OrgAdmin)
(define OrgMember 'OrgMember)
(define ProjMember 'ProjMember)

(define-record KanelSession
  [userId : String]
  [displayName : String]
  [email : String]
)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [kanelDbRead]
  #:returns [session : KanelSession ::: (Authenticated session)]
  (thsl-src! "example/kanel/KanelAuth.tesl" 58 (list (cons 'request *request)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_Dict_lookup "kanel_user_id" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "not logged in" #:http-code 401)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([found (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'id) userId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_1 (raw-value found)]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (reject "session invalid" #:http-code 401)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (accept Authenticated #:value (KanelSession #:userId (raw-value user.id) #:displayName (raw-value user.displayName) #:email (raw-value user.email))))]))))])))))

(define-checker
  (checkOrgMember [userId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (OrgMember userId orgId)]
  (let ([membership (thsl-src! "example/kanel/KanelAuth.tesl" 79 (list (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src! "example/kanel/KanelAuth.tesl" 80 (list (cons 'membership *membership) (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_case_2 (raw-value membership)]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (reject "not a member of this organization" #:http-code 403)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (accept (OrgMember userId orgId) #:value *userId)]))))))

(define-checker
  (checkOrgAdmin [userId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (OrgAdmin userId orgId)]
  (let ([membership (thsl-src! "example/kanel/KanelAuth.tesl" 98 (list (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src! "example/kanel/KanelAuth.tesl" 99 (list (cons 'membership *membership) (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_case_3 (raw-value membership)]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Nothing)) (reject "not a member of this organization" #:http-code 403)] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Something)) (let ([m (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (let ([tesl_case_4 (tesl-dot/runtime m 'role)]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'RoleAdmin)) (accept (OrgAdmin userId orgId) #:value *userId)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'RoleMember)) (reject "admin role required" #:http-code 403)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'RoleViewer)) (reject "admin role required" #:http-code 403)])))]))))))

(define-checker
  (checkProjMember [userId : String] [projectId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (ProjMember userId projectId)]
  (let ([orgMember (thsl-src! "example/kanel/KanelAuth.tesl" 118 (list (cons 'userId *userId) (cons 'projectId *projectId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src! "example/kanel/KanelAuth.tesl" 119 (list (cons 'orgMember *orgMember) (cons 'userId *userId) (cons 'projectId *projectId) (cons 'orgId *orgId)) (lambda () (let ([tesl_case_5 (raw-value orgMember)]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Nothing)) (reject "not a member of this organization" #:http-code 403)] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Something)) (let ([m (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (let ([tesl_case_6 (tesl-dot/runtime m 'role)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'RoleAdmin)) (accept (ProjMember userId projectId) #:value *userId)] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'RoleMember)) (let ([projMember (let ([tesl_match (select-one (from ProjectMembership) (where (==. (entity-field-ref ProjectMembership 'userId) userId)) (where (==. (entity-field-ref ProjectMembership 'projectId) projectId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_7 (raw-value projMember)]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Nothing)) (reject "not a member of this project" #:http-code 403)] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Something)) (accept (ProjMember userId projectId) #:value *userId)])))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'RoleViewer)) (let ([projMember (let ([tesl_match (select-one (from ProjectMembership) (where (==. (entity-field-ref ProjectMembership 'userId) userId)) (where (==. (entity-field-ref ProjectMembership 'projectId) projectId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_8 (raw-value projMember)]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Nothing)) (reject "not a member of this project" #:http-code 403)] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Something)) (accept (ProjMember userId projectId) #:value *userId)])))])))]))))))

(define-checker
  (checkIssueAssignee [userId : String] [issueId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (IssueAssignee userId issueId)]
  (let ([issue (thsl-src! "example/kanel/KanelAuth.tesl" 147 (list (cons 'userId *userId) (cons 'issueId *issueId)) (lambda () (let ([tesl_match (select-one (from Issue) (where (==. (entity-field-ref Issue 'id) issueId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src! "example/kanel/KanelAuth.tesl" 148 (list (cons 'issue *issue) (cons 'userId *userId) (cons 'issueId *issueId)) (lambda () (let ([tesl_case_9 (raw-value issue)]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (reject "issue not found" #:http-code 404)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([i (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (let ([tesl_case_10 (tesl-dot/runtime i 'assigneeId)]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Nothing)) (reject "issue has no assignee \u2014 cannot verify assignment" #:http-code 403)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Something)) (let ([aid (hash-ref (adt-value-fields *tesl_case_10) 'value)]) (if (equal? (raw-value aid) *userId) (accept (IssueAssignee userId issueId) #:value *userId) (reject "not assigned to this issue" #:http-code 403)))])))]))))))
