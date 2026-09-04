# Mainstream installation

## Background

Today the only installation path is via nix. This has several benefits but also a major downside: Nix is not mainstream.

## Goal

- An easy way to install Tesl for Linux and Mac users, following all best practices in their ecosystem
- The deployment target should put very little additional burden on this repo
- Users should be able to check the SHA or similar to know that the shipped artifact is what it claims
- Users who would like to build from source should be able to do so
- It should be a single download artifact to get Tesl working
- The nix way should stay the main/fundamental way
- A new release for each new successfull build of a new revision pushed to "main"
