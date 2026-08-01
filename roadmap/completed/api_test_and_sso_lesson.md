We should have a lesson that shows how to combine api-testing when you use SSO

Done: `example/learn/lesson80-testing-sso.tesl` — mint-session testing (no IdP),
stubbed login-redirect testing for both a named provider and a generic
`Sso.oidc` issuer, and a full stubbed GitHub login->callback round trip.
Required two runtime fixes to make `sso` routes reachable from `api-test` at
all: `dsl/web.rkt`/`dsl/test-support.rkt` (SSO route dispatch + response-shape
adapter) — see `dispatch-api-test-request`.