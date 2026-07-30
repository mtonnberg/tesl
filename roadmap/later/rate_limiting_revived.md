# Rate limiting

## Background

We have discussed rate limiting very early in the project and then rejected the idea for not being a core feature and would require costly syncing between horizontally scaled instances. But with the background of agent-features (that could become quite costly if the app-host is providing the key) and the ensure_sso_works.md feature(s) the case for built-in rate limiting is much stronger today.

## Goal

- Make Tesl apps resilient towards DoS-attacks
- Make Tesl apps resilient towards brute force auth attacks
- Make it possible, in a multi-tenant environement, give org/user based rate limits to avoid abuse/manage costs.


## Open questions

- How to do this the best?
- Should it be done (The issues is still solvable using a rproxy (that handles the ssl termination anyways since Tesl lacks that by choice))
- If we introduce rate limiting, should we then introduce ssl-termination as well?
- Any other short or long term effects of doing this?
- Is it a good feature for Tesl and its users?