# Ensure SSO/3rd party Auth services works

## Background

We have added crypto and session cookies. A lot of real apps use Single-sign-on (SSO), both to avoid handling the critical sign in logic themselves but also because that is a common demand from customers. Also that allows us to scope out mfa etc from Tesl.

## Current state

It is not clear right now if Tesl would work out of the box with a standard SSO solution/3rd party Auth service (Azure AD, Auth0 or similar)

## Goal

It should be painless and easy to setup SSO/using a 3rd party Auth handler. It should map nicely into our proofs/auth-handlers. The compiler should help in a friendly and constructive way as always.

## Notes

I guess some of it is possible to do inside an auth-handler with the help of http-calls but for SSO we need to redirect