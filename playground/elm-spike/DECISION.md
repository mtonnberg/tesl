# Elm feasibility decision — superseded

The initial experiment established that Elm could preserve editing and reject
stale compiler/search replies. On 2026-09-05 the user requested executing the
migration and invited a VS Code-like editor option.

The production application now uses Elm with a native editor and optional,
lazily loaded Monaco component. See the [current architecture](../ARCHITECTURE.md).
The experimental implementation was retired; its regression contracts now run
against the production interface. Earlier measurements remain historical evidence
in the adoption repository, not current bundle-size claims.
