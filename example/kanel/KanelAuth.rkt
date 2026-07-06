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
  (thsl-src-control! "example/kanel/KanelAuth.tesl" 58 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "kanel_user_id" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 60 (list) (lambda () (reject "not logged in" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/kanel/KanelAuth.tesl" 62 (list (cons 'userId userId)) (lambda () (let ([found (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'id) userId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-1 (raw-value found)]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 65 (list) (lambda () (reject "session invalid" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/kanel/KanelAuth.tesl" 67 (list (cons 'user user)) (lambda () (accept Authenticated #:value (KanelSession #:userId (raw-value user.id) #:displayName (raw-value user.displayName) #:email (raw-value user.email))))))]))))))])))))

(define-checker
  (checkOrgMember [userId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (OrgMember userId orgId)]
  (let ([membership (thsl-src! "example/kanel/KanelAuth.tesl" 79 (list (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/kanel/KanelAuth.tesl" 80 (list (cons 'membership *membership) (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl-case-2 (raw-value membership)]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 82 (list) (lambda () (reject "not a member of this organization" #:http-code 403)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (thsl-src! "example/kanel/KanelAuth.tesl" 84 (list) (lambda () (accept (OrgMember userId orgId) #:value *userId)))]))))))

(define-checker
  (checkOrgAdmin [userId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (OrgAdmin userId orgId)]
  (let ([membership (thsl-src! "example/kanel/KanelAuth.tesl" 98 (list (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/kanel/KanelAuth.tesl" 99 (list (cons 'membership *membership) (cons 'userId *userId) (cons 'orgId *orgId)) (lambda () (let ([tesl-case-3 (raw-value membership)]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 101 (list) (lambda () (reject "not a member of this organization" #:http-code 403)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([m (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/kanel/KanelAuth.tesl" 103 (list (cons 'm m)) (lambda () (let ([tesl-case-4 (tesl-dot/runtime m 'role 'OrgMembership)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'RoleAdmin)) (thsl-src! "example/kanel/KanelAuth.tesl" 104 (list) (lambda () (accept (OrgAdmin userId orgId) #:value *userId)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'RoleMember)) (thsl-src! "example/kanel/KanelAuth.tesl" 105 (list) (lambda () (reject "admin role required" #:http-code 403)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'RoleViewer)) (thsl-src! "example/kanel/KanelAuth.tesl" 106 (list) (lambda () (reject "admin role required" #:http-code 403)))])))))]))))))

(define-checker
  (checkProjMember [userId : String] [projectId : String] [orgId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (ProjMember userId projectId)]
  (let ([orgMember (thsl-src! "example/kanel/KanelAuth.tesl" 118 (list (cons 'userId *userId) (cons 'projectId *projectId) (cons 'orgId *orgId)) (lambda () (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) userId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/kanel/KanelAuth.tesl" 119 (list (cons 'orgMember *orgMember) (cons 'userId *userId) (cons 'projectId *projectId) (cons 'orgId *orgId)) (lambda () (let ([tesl-case-5 (raw-value orgMember)]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 121 (list) (lambda () (reject "not a member of this organization" #:http-code 403)))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([m (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "example/kanel/KanelAuth.tesl" 123 (list (cons 'm m)) (lambda () (let ([tesl-case-6 (tesl-dot/runtime m 'role 'OrgMembership)]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'RoleAdmin)) (thsl-src! "example/kanel/KanelAuth.tesl" 125 (list) (lambda () (accept (ProjMember userId projectId) #:value *userId)))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'RoleMember)) (thsl-src! "example/kanel/KanelAuth.tesl" 127 (list) (lambda () (let ([projMember (let ([tesl_match (select-one (from ProjectMembership) (where (==. (entity-field-ref ProjectMembership 'userId) userId)) (where (==. (entity-field-ref ProjectMembership 'projectId) projectId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-7 (raw-value projMember)]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 129 (list) (lambda () (reject "not a member of this project" #:http-code 403)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something)) (thsl-src! "example/kanel/KanelAuth.tesl" 130 (list) (lambda () (accept (ProjMember userId projectId) #:value *userId)))])))))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'RoleViewer)) (thsl-src! "example/kanel/KanelAuth.tesl" 133 (list) (lambda () (let ([projMember (let ([tesl_match (select-one (from ProjectMembership) (where (==. (entity-field-ref ProjectMembership 'userId) userId)) (where (==. (entity-field-ref ProjectMembership 'projectId) projectId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-8 (raw-value projMember)]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 135 (list) (lambda () (reject "not a member of this project" #:http-code 403)))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something)) (thsl-src! "example/kanel/KanelAuth.tesl" 136 (list) (lambda () (accept (ProjMember userId projectId) #:value *userId)))])))))])))))]))))))

(define-checker
  (checkIssueAssignee [userId : String] [issueId : String])
  #:capabilities [kanelDbRead]
  #:returns [userId : String ::: (IssueAssignee userId issueId)]
  (let ([issue (thsl-src! "example/kanel/KanelAuth.tesl" 147 (list (cons 'userId *userId) (cons 'issueId *issueId)) (lambda () (let ([tesl_match (select-one (from Issue) (where (==. (entity-field-ref Issue 'id) issueId)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/kanel/KanelAuth.tesl" 148 (list (cons 'issue *issue) (cons 'userId *userId) (cons 'issueId *issueId)) (lambda () (let ([tesl-case-9 (raw-value issue)]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 150 (list) (lambda () (reject "issue not found" #:http-code 404)))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([i (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "example/kanel/KanelAuth.tesl" 152 (list (cons 'i i)) (lambda () (let ([tesl-case-10 (tesl-dot/runtime i 'assigneeId 'Issue)]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing)) (thsl-src! "example/kanel/KanelAuth.tesl" 154 (list) (lambda () (reject "issue has no assignee \u2014 cannot verify assignment" #:http-code 403)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something)) (let ([aid (hash-ref (adt-value-fields *tesl-case-10) 'value)]) (thsl-src! "example/kanel/KanelAuth.tesl" 156 (list (cons 'aid aid)) (lambda () (if (tesl-equal? (raw-value aid) *userId) (accept (IssueAssignee userId issueId) #:value *userId) (reject "not assigned to this issue" #:http-code 403)))))])))))]))))))
