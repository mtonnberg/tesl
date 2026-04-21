# Lesson 5: Introduction to Proofs — Conceptual Guide

## What is a proof in Tesl?

A "proof" in Tesl is not a mathematical proof you write by hand.
It is a **runtime stamp** — a piece of evidence that says:
"This value was checked and satisfies condition X."

Think of it like a security badge at an office building:

```
Without badge:  "I want to enter the server room."
Security:       "Do you have a badge?"
You:            "No, but I promise I'm authorized."
Security:       "Not good enough."

With badge:
Security:       "Show me your badge."
You:            [shows badge stamped 'SERVER-ROOM-ACCESS']
Security:       "Proceed."
```

In Tesl:

```
Without proof:  listenOnPort(someInteger)     ← COMPILE ERROR
Compiler:       "Does someInteger have a ValidPort proof?"
You:            "No, but it looks like a valid port..."
Compiler:       "Not good enough."

With proof:
let validated = isValidPort(someInteger)      ← stamp issued here
listenOnPort(validated)                       ← stamp checked here, OK
```

---

## The "check early, carry proof" mental model

The key insight is: **validate at the boundary, carry the evidence, never re-validate**.

```
HTTP request comes in
       │
       ▼
isValidPort(rawPort)         ← ONE validation here
       │
       ▼ (proof stamp attached)
handleRequest(validated)
       │
       ▼
listenOnPort(validated)      ← no re-validation needed: proof is already there
       │
       ▼
configureFirewall(validated) ← still no re-validation
```

Compare this to the traditional Optional/null-check style:

```python
# Traditional: keep checking everywhere
def handle_request(raw_port):
    if raw_port is None:
        return error(400)
    port = int(raw_port)
    if port < 1 or port > 65535:
        return error(400)
    start_server(port)          # start_server also validates, just in case
    configure_firewall(port)    # configure_firewall also validates, just in case
```

```tesl
# Tesl: validate once, carry proof
check isValidPort(port: Int) -> port: Int ::: ValidPort port = ...

fn handleRequest(port: Int ::: ValidPort port) -> ... =
  listenOnPort(port)            # no re-validation: proof already on port
  configureFirewall(port)       # same: proof travels with port
```

---

## What "ValidPort port" means

`ValidPort port` is a **proof predicate application**.

- `ValidPort` is the predicate name — it describes a property
- `port` is the subject — it says which value the property is about

When you write `ok port ::: ValidPort port` inside a `check` function,
you are saying: "I, the check function, hereby certify that the value
currently named `port` satisfies the `ValidPort` property."

The compiler records this in its proof environment for `port`.
Later, when someone passes `port` to a function requiring `ValidPort`,
the compiler confirms: "yes, we have evidence for `ValidPort port`."

---

## Why can't you just use if-checks everywhere?

You can, but there are two problems:

**Problem 1: It doesn't scale.**
Every function in the call chain must repeat the check, or trust that callers
already checked. In practice, callers forget. Or they check differently.
Or the check gets refactored out. The invariant leaks.

**Problem 2: The compiler can't help you.**
With `if *port >= 1 && *port <= 65535` scattered everywhere, the compiler
has no way to know "did this particular port value get validated?"
It can only see types, not validation history.

Tesl's proof system solves both problems:
- **Scales**: validate once at the entry point, proof travels everywhere
- **Compiler-enforced**: the `:::` annotation in the parameter is a compile-time
  requirement; the compiler rejects calls that don't have the evidence

---

## The anatomy of a check function

```tesl
check isValidPort(port: Int) -> port: Int ::: ValidPort port =
│     │            │       │       │     │         │      │
│     │            │       │       │     │         │      └── the subject being claimed about
│     │            │       │       │     │         └── the predicate (the claim)
│     │            │       │       │     └── proof annotation separator
│     │            │       │       └── the named return value
│     │            │       └── parameter type
│     │            └── parameter name
│     └── function name
└── this is a "check" kind (can fail with HTTP error, can attach proofs)
```

Inside the body:

```tesl
ok port ::: ValidPort port
│  │         │         │
│  │         │         └── the subject (must match a param name or bound name)
│  │         └── the predicate being certified
│  └── the named value to return
└── success keyword
```

---

## The anatomy of a proof-requiring parameter

```tesl
fn listenOnPort(port: Int ::: ValidPort port) -> String =
                │     │         │         │
                │     │         │         └── must match the param name (the subject)
                │     │         └── required predicate
                │     └── proof annotation separator
                └── parameter type
```

Reading this: "accept a parameter named `port` of type `Int`,
and require that `port` carries the proof fact `ValidPort port`."

At call sites, the compiler checks: "does the actual argument carry `ValidPort`?"
If not, it's a compile error — not a runtime error, not an exception.

---

## Proofs vs. exceptions vs. Optional

| Approach | Where does failure happen? | Repeated checks? | Compile-time guarantee? |
|---|---|---|---|
| Exceptions | Anywhere, unexpectedly | Often | No |
| Optional / Maybe | At every unwrap point | Yes | Partial |
| Tesl proofs | At the boundary, once | No | Yes |

Tesl proofs are closest to the "parse, don't validate" principle:
parse the raw input into a validated value at the boundary,
then carry the validated form throughout the rest of the program.
