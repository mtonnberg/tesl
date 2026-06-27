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
  (only-in tesl/tesl/prelude String List Fact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] [String.isEmpty tesl_import_String_isEmpty] [String.toLower tesl_import_String_toLower] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/time nowMillis time)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl] [List.append tesl_import_List_append])
  (only-in (file "kanel-models.rkt") ValidOrgId ValidUserId kanelDbRead kanelDbWrite KanelUser Org OrgMembership OrgRole RoleAdmin RoleMember RoleViewer NewOrgRequest)
  (only-in (file "kanel-auth.rkt") KanelSession Authenticated checkOrgMember checkOrgAdmin checkOrgMember-signature checkOrgAdmin-signature)
)


(provide RegisterRequest LoginRequest InviteMemberRequest ChangeMemberRoleRequest ValidOrgName checkOrgName ValidSlug checkSlug ValidEmail checkEmail ValidDisplayName checkDisplayName registerHandler loginHandler createOrgHandler getOrgHandler listOrgMembersHandler inviteMemberHandler changeMemberRoleHandler removeMemberHandler listMyOrgsHandler checkOrgName-signature checkSlug-signature checkEmail-signature checkDisplayName-signature registerHandler-signature loginHandler-signature createOrgHandler-signature getOrgHandler-signature listMyOrgsHandler-signature listOrgMembersHandler-signature inviteMemberHandler-signature changeMemberRoleHandler-signature removeMemberHandler-signature)

(define ValidDisplayName 'ValidDisplayName)
(define ValidEmail 'ValidEmail)
(define ValidOrgName 'ValidOrgName)
(define ValidSlug 'ValidSlug)

(define-checker
  (checkOrgName [name : String])
  #:returns [trimmed : String ::: (ValidOrgName trimmed)]
  (let ([trimmed (thsl-src! "example/kanel/KanelOrg.tesl" 77 (list (cons 'name *name)) (lambda () (tesl_import_String_trim *name)))]) (thsl-src! "example/kanel/KanelOrg.tesl" 78 (list (cons 'trimmed *trimmed) (cons 'name *name)) (lambda () (if (tesl_import_String_isEmpty (raw-value trimmed)) (reject "organization name must not be empty" #:http-code 400) (if (< (raw-value (tesl_import_String_length (raw-value trimmed))) 2) (reject "organization name must be at least 2 characters" #:http-code 400) (if (> (raw-value (tesl_import_String_length (raw-value trimmed))) 80) (reject "organization name must be at most 80 characters" #:http-code 400) (accept (ValidOrgName trimmed) #:value *trimmed))))))))

(define-checker
  (checkSlug [slug : String])
  #:returns [slug : String ::: (ValidSlug slug)]
  (thsl-src! "example/kanel/KanelOrg.tesl" 92 (list (cons 'slug *slug)) (lambda () (if (tesl_import_String_isEmpty *slug) (reject "slug must not be empty" #:http-code 400) (if (< (raw-value (tesl_import_String_length *slug)) 2) (reject "slug must be at least 2 characters" #:http-code 400) (if (> (raw-value (tesl_import_String_length *slug)) 40) (reject "slug must be at most 40 characters" #:http-code 400) (accept (ValidSlug slug) #:value *slug)))))))

(define-checker
  (checkEmail [email : String])
  #:returns [email : String ::: (ValidEmail email)]
  (thsl-src! "example/kanel/KanelOrg.tesl" 106 (list (cons 'email *email)) (lambda () (if (tesl_import_String_isEmpty *email) (reject "email must not be empty" #:http-code 400) (if (tesl_import_String_contains *email "@") (accept (ValidEmail email) #:value *email) (reject "email must contain @" #:http-code 400))))))

(define-checker
  (checkDisplayName [name : String])
  #:returns [name : String ::: (ValidDisplayName name)]
  (thsl-src! "example/kanel/KanelOrg.tesl" 117 (list (cons 'name *name)) (lambda () (if (tesl_import_String_isEmpty *name) (reject "display name must not be empty" #:http-code 400) (if (> (raw-value (tesl_import_String_length *name)) 100) (reject "display name must be at most 100 characters" #:http-code 400) (accept (ValidDisplayName name) #:value *name))))))

(define-record RegisterRequest
  [email : String]
  [password : String]
  [displayName : String]
)

(define (tesl-codec-encode-RegisterRequest _v)
  (error "toJson is forbidden for type RegisterRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-RegisterRequest-0 _j)
  (define _f_email (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _f_displayName (tesl-decode-prim-field _j "displayName" tesl-decode-prim-string))
  (record-value 'RegisterRequest (hash 'email _f_email 'displayName _f_displayName)))
(register-type-codec! 'RegisterRequest tesl-codec-encode-RegisterRequest (list tesl-codec-decode-RegisterRequest-0))

(define-record LoginRequest
  [email : String]
  [password : String]
)

(define (tesl-codec-encode-LoginRequest _v)
  (error "toJson is forbidden for type LoginRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-LoginRequest-0 _j)
  (define _f_email (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (record-value 'LoginRequest (hash 'email _f_email)))
(register-type-codec! 'LoginRequest tesl-codec-encode-LoginRequest (list tesl-codec-decode-LoginRequest-0))

(define-handler
  (registerHandler [req : RegisterRequest])
  #:capabilities [kanelDbRead kanelDbWrite random time]
  #:returns (Exists [userId : String] (? KanelUser _entity ::: (FromDb (Id == userId) _entity)))
  (thsl-src! "example/kanel/KanelOrg.tesl" 162 (list (cons 'req *req)) (lambda () (let/check ([tesl_checked_0 (checkEmail (tesl_import_String_trim (raw-value req.email)))]) (let ([email tesl_checked_0]) (let/check ([tesl_checked_1 (checkDisplayName (tesl_import_String_trim (raw-value req.displayName)))]) (let ([name tesl_checked_1]) (if (< (raw-value (tesl_import_String_length (raw-value req.password))) 8) (reject "password must be at least 8 characters" #:http-code 400) (let ([existing (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'email) email)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_2 (raw-value existing)]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (thsl-src! "example/kanel/KanelOrg.tesl" 169 (list) (lambda () (reject "email already registered" #:http-code 409)))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 171 (list) (lambda () (let ([userId (generatePrefixedId "usr")]) (pack ([userId]) (insert-one! KanelUser (hash 'id userId 'email email 'passwordHash (raw-value req.password) 'displayName name 'createdAt (raw-value (nowMillis))))))))])))))))))))

(define-handler
  (loginHandler [req : LoginRequest])
  #:capabilities [kanelDbRead]
  #:returns String
  (thsl-src! "example/kanel/KanelOrg.tesl" 183 (list (cons 'req *req)) (lambda () (let/check ([tesl_checked_3 (checkEmail (raw-value req.email))]) (let ([email tesl_checked_3]) (let ([found (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'email) email)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_4 (raw-value found)]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 186 (list) (lambda () (reject "invalid email or password" #:http-code 401)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([user (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (thsl-src! "example/kanel/KanelOrg.tesl" 188 (list (cons 'user user)) (lambda () (if (equal? (raw-value user.passwordHash) (raw-value req.password)) (raw-value user.id) (reject "invalid email or password" #:http-code 401)))))]))))))))

(define-handler
  (createOrgHandler [session : KanelSession ::: (Authenticated session)] [req : NewOrgRequest])
  #:capabilities [kanelDbRead kanelDbWrite random time]
  #:returns (Exists [orgId : String] (? Org _entity ::: (FromDb (Id == orgId) _entity)))
  (thsl-src! "example/kanel/KanelOrg.tesl" 203 (list (cons 'session *session) (cons 'req *req)) (lambda () (let/check ([tesl_checked_5 (checkOrgName (tesl_import_String_trim (raw-value req.name)))]) (let ([orgName tesl_checked_5]) (let/check ([tesl_checked_6 (checkSlug (tesl_import_String_toLower (raw-value (tesl_import_String_trim (raw-value req.slug)))))]) (let ([slug tesl_checked_6]) (let ([existing (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'slug) slug)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_7 (raw-value existing)]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Something)) (thsl-src! "example/kanel/KanelOrg.tesl" 208 (list) (lambda () (reject "slug already taken" #:http-code 409)))] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 210 (list) (lambda () (let ([orgId (generatePrefixedId "org")]) (let ([memberId (generatePrefixedId "mem")]) (call-with-queue-transaction (lambda () (let ([_ (insert-one! OrgMembership (hash 'id memberId 'orgId orgId 'userId (raw-value session.userId) 'role RoleAdmin 'joinedAt (raw-value (nowMillis))))]) (pack ([orgId]) (insert-one! Org (hash 'id orgId 'name orgName 'slug slug 'createdAt (raw-value (nowMillis))))))))))))]))))))))))

(define-handler
  (getOrgHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)])
  #:capabilities [kanelDbRead]
  #:returns Org
  (thsl-src! "example/kanel/KanelOrg.tesl" 236 (list (cons 'session *session) (cons 'orgId *orgId)) (lambda () (let/check ([tesl_checked_8 (checkOrgMember (raw-value session.userId) orgId)]) (let ([_member tesl_checked_8]) (let ([found (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'id) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_9 (raw-value found)]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 239 (list) (lambda () (reject "organization not found" #:http-code 404)))] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([org (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (thsl-src! "example/kanel/KanelOrg.tesl" 240 (list (cons 'org org)) (lambda () *org)))]))))))))

(define/pow
  (fetchOrgByMembership [acc : (List Org)] [m : OrgMembership])
  #:capabilities [kanelDbRead]
  #:returns (List Org)
  (let ([found (thsl-src! "example/kanel/KanelOrg.tesl" 246 (list (cons 'acc *acc) (cons 'm *m)) (lambda () (let ([tesl_match (select-one (from Org) (where (==. (entity-field-ref Org 'id) (tesl-dot/runtime m 'orgId))))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/kanel/KanelOrg.tesl" 247 (list (cons 'found *found) (cons 'acc *acc) (cons 'm *m)) (lambda () (let ([tesl_case_10 (raw-value found)]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 248 (list) (lambda () *acc))] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl_case_10) 'value)]) (thsl-src! "example/kanel/KanelOrg.tesl" 249 (list (cons 'o o)) (lambda () (raw-value (tesl_import_List_append *acc (list *o))))))]))))))

(define-handler
  (listMyOrgsHandler [session : KanelSession ::: (Authenticated session)])
  #:capabilities [kanelDbRead]
  #:returns (List Org)
  (let ([memberships (thsl-src! "example/kanel/KanelOrg.tesl" 254 (list (cons 'session *session)) (lambda () (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) (raw-value session.userId))))))]) (thsl-src! "example/kanel/KanelOrg.tesl" 255 (list (cons 'memberships *memberships) (cons 'session *session)) (lambda () (tesl_import_List_foldl fetchOrgByMembership (list) (raw-value memberships))))))

(define-record InviteMemberRequest
  [email : String]
  [role : OrgRole]
)

(define (tesl-codec-encode-InviteMemberRequest _v)
  (error "toJson is forbidden for type InviteMemberRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-InviteMemberRequest-0 _j)
  (define _f_email (tesl-decode-prim-field _j "email" tesl-decode-prim-string))
  (define _f_role (tesl-codec-decode-field _j "role" 'OrgRole))
  (record-value 'InviteMemberRequest (hash 'email _f_email 'role _f_role)))
(register-type-codec! 'InviteMemberRequest tesl-codec-encode-InviteMemberRequest (list tesl-codec-decode-InviteMemberRequest-0))

(define-record ChangeMemberRoleRequest
  [role : OrgRole]
)

(define (tesl-codec-encode-ChangeMemberRoleRequest _v)
  (error "toJson is forbidden for type ChangeMemberRoleRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-ChangeMemberRoleRequest-0 _j)
  (define _f_role (tesl-codec-decode-field _j "role" 'OrgRole))
  (record-value 'ChangeMemberRoleRequest (hash 'role _f_role)))
(register-type-codec! 'ChangeMemberRoleRequest tesl-codec-encode-ChangeMemberRoleRequest (list tesl-codec-decode-ChangeMemberRoleRequest-0))

(define-handler
  (listOrgMembersHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)])
  #:capabilities [kanelDbRead]
  #:returns (List OrgMembership)
  (thsl-src! "example/kanel/KanelOrg.tesl" 292 (list (cons 'session *session) (cons 'orgId *orgId)) (lambda () (let/check ([tesl_checked_11 (checkOrgMember (raw-value session.userId) orgId)]) (let ([_member tesl_checked_11]) (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))))))

(define-handler
  (inviteMemberHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [req : InviteMemberRequest])
  #:capabilities [kanelDbRead kanelDbWrite random time]
  #:returns (Exists [memberId : String] (? OrgMembership _entity ::: (FromDb (Id == memberId) _entity)))
  (thsl-src! "example/kanel/KanelOrg.tesl" 301 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'req *req)) (lambda () (let/check ([tesl_checked_12 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_12]) (let/check ([tesl_checked_13 (checkEmail (tesl_import_String_trim (raw-value req.email)))]) (let ([email tesl_checked_13]) (let ([found (let ([tesl_match (select-one (from KanelUser) (where (==. (entity-field-ref KanelUser 'email) email)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_14 (raw-value found)]) (cond [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 306 (list) (lambda () (reject "user not found \u2014 they must register first" #:http-code 404)))] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Something)) (let ([targetUser (hash-ref (adt-value-fields *tesl_case_14) 'value)]) (thsl-src! "example/kanel/KanelOrg.tesl" 309 (list (cons 'targetUser targetUser)) (lambda () (let ([existing (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) (raw-value targetUser.id))) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_15 (raw-value existing)]) (cond [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Something)) (thsl-src! "example/kanel/KanelOrg.tesl" 311 (list) (lambda () (reject "user is already a member" #:http-code 409)))] [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 313 (list) (lambda () (let ([memberId (generatePrefixedId "mem")]) (pack ([memberId]) (insert-one! OrgMembership (hash 'id memberId 'orgId orgId 'userId (raw-value targetUser.id) 'role (raw-value req.role) 'joinedAt (raw-value (nowMillis))))))))]))))))]))))))))))

(define-handler
  (changeMemberRoleHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [targetUserId : String ::: (ValidUserId targetUserId)] [req : ChangeMemberRoleRequest])
  #:capabilities [kanelDbRead kanelDbWrite]
  #:returns OrgMembership
  (thsl-src! "example/kanel/KanelOrg.tesl" 330 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'targetUserId *targetUserId) (cons 'req *req)) (lambda () (let/check ([tesl_checked_16 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_16]) (let ([allAdmins (select-many (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)) (where (==. (entity-field-ref OrgMembership 'role) RoleAdmin)))]) (let ([targetMembership (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_17 (raw-value targetMembership)]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 335 (list) (lambda () (reject "user is not a member of this organization" #:http-code 404)))] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something)) (let ([membership (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (thsl-src! "example/kanel/KanelOrg.tesl" 337 (list (cons 'membership membership)) (lambda () (let ([tesl_case_18 (tesl-dot/runtime membership 'role)]) (cond [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'RoleAdmin)) (thsl-src! "example/kanel/KanelOrg.tesl" 339 (list) (lambda () (if (<= (raw-value (tesl_import_List_length (raw-value allAdmins))) 1) (reject "cannot demote the last admin \u2014 promote another member first" #:http-code 400) (car (update-many! (from OrgMembership) (hash (entity-field-ref OrgMembership 'role) (raw-value req.role)) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))))))] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'RoleMember)) (thsl-src! "example/kanel/KanelOrg.tesl" 347 (list) (lambda () (car (update-many! (from OrgMembership) (hash (entity-field-ref OrgMembership 'role) (raw-value req.role)) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))))] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'RoleViewer)) (thsl-src! "example/kanel/KanelOrg.tesl" 352 (list) (lambda () (car (update-many! (from OrgMembership) (hash (entity-field-ref OrgMembership 'role) (raw-value req.role)) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId))))))])))))])))))))))

(define-handler
  (removeMemberHandler [session : KanelSession ::: (Authenticated session)] [orgId : String ::: (ValidOrgId orgId)] [targetUserId : String ::: (ValidUserId targetUserId)])
  #:capabilities [kanelDbRead kanelDbWrite]
  #:returns String
  (thsl-src! "example/kanel/KanelOrg.tesl" 363 (list (cons 'session *session) (cons 'orgId *orgId) (cons 'targetUserId *targetUserId)) (lambda () (let/check ([tesl_checked_19 (checkOrgAdmin (raw-value session.userId) orgId)]) (let ([_adminUserId tesl_checked_19]) (let ([targetMembership (let ([tesl_match (select-one (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_20 (raw-value targetMembership)]) (cond [(and (adt-value? *tesl_case_20) (eq? (adt-value-variant *tesl_case_20) 'Nothing)) (thsl-src! "example/kanel/KanelOrg.tesl" 366 (list) (lambda () (reject "user is not a member of this organization" #:http-code 404)))] [(and (adt-value? *tesl_case_20) (eq? (adt-value-variant *tesl_case_20) 'Something)) (let ([membership (hash-ref (adt-value-fields *tesl_case_20) 'value)]) (thsl-src! "example/kanel/KanelOrg.tesl" 368 (list (cons 'membership membership)) (lambda () (let ([tesl_case_21 (tesl-dot/runtime membership 'role)]) (cond [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'RoleAdmin)) (thsl-src! "example/kanel/KanelOrg.tesl" 370 (list) (lambda () (let ([adminCount (select-count (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)) (where (==. (entity-field-ref OrgMembership 'role) RoleAdmin)))]) (if (<= (raw-value adminCount) 1) (reject "cannot remove the last admin" #:http-code 400) (let ([_ (delete-many! (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) "removed")))))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'RoleMember)) (thsl-src! "example/kanel/KanelOrg.tesl" 377 (list) (lambda () (let ([_ (delete-many! (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) "removed")))] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'RoleViewer)) (thsl-src! "example/kanel/KanelOrg.tesl" 380 (list) (lambda () (let ([_ (delete-many! (from OrgMembership) (where (==. (entity-field-ref OrgMembership 'userId) targetUserId)) (where (==. (entity-field-ref OrgMembership 'orgId) orgId)))]) "removed")))])))))]))))))))
