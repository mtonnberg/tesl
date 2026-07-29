# Improved transparancy for built in types

## Background

Today, a developer cannot see how the type for "SmtpConfig" or "Email.send" really looks like. Especially problematic for record/ADT types because that makes it hard to understand how to "please" the compiler and that breaks the fundamental Tesl goal to help the developer forward.

## Goal

Make all functions/types (both those declared in Tesl and in Racket) easily viewable for a developer using Tesl in their own project (outside this codebase and without access to it). All types/functions should be expressed in Tesl (even if the runtime is implemented in Racket)