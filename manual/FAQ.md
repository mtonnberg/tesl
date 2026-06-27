# Frequently Asked Questions

Use `tesl help manual faq` to access this from the CLI.

---

## General Questions

### What does "Tesl" mean?

"Tesl" doesn't stand for anything - it's just a name. Think of it as a brand name like "Rust" or "Swift".

### Is Tesl a general-purpose programming language?

No, Tesl is specifically designed for **building web APIs**. It's a domain-specific language (DSL) focused on the web API problem domain. The goal is to be excellent at this one thing rather than adequate at many things.

### What does "alpha-stage" mean?

Tesl is in active development. This means:
- **Breaking changes** are expected and frequent
- **Backward compatibility** is not yet a goal
- **Not all features** are fully implemented
- **Performance** may not be optimal
- **Documentation** may be incomplete

We're working towards a stable 1.0 release, but we're not there yet.

---

## Installation and Setup

### How do I install Tesl?

The easiest way is via Nix:

```bash
nix profile install github:mtonnberg/tesl
```

Or try without installing:
```bash
nix run github:mtonnberg/tesl -- help
```

See [INSTALL.md](../INSTALL.md) for more options.

### Do I need to clone the repository to use Tesl?

No! You can install Tesl via Nix flake without cloning the repository. The repository is only needed if you want to:
- Contribute to Tesl's development
- Run the examples
- Build from source

### What are the system requirements?

- **Operating System**: Linux, macOS, or Windows (via WSL2)
- **Nix package manager** (for installation)
- **PostgreSQL** (for database examples)

### Can I use Tesl without Nix?

Currently, Nix is the recommended way to install and use Tesl. We're working on alternative installation methods, but for now, Nix provides the most reliable and reproducible environment.

---

## Language Questions

### What is GDP?

GDP stands for **Ghosts of Departed Proofs**, which is a research paper and technique for tracking validation proofs through a program's execution. The key insight is:

1. Validate data once at the boundary
2. Carry the proof ("ghost") along with the value
3. The type system ensures the proof is always present when needed
4. No need to re-validate the same data multiple times

Tesl brings GDP concepts to a practical, developer-friendly language.

### What does `:::` mean?

The `:::` syntax is Tesl's way of annotating a value with a proof. For example:

```tesl
check isValidEmail(email: String) -> email: String ::: ValidEmail email
```

This means: "This function takes a String called `email` and returns the same `email` but now with proof that it's valid (ValidEmail)."

### What's the difference between `fn` and `check`?

- **`fn`**: A regular function that can't fail. It operates on already-validated data.
- **`check`**: A validation function that can fail (returning an error) or succeed (returning a value with a proof).

### When should I use `check` for cross-field validation?

Use `check` for cross-field validation or complex validation that depends on multiple values:

```tesl
check passwordsMatch(password: String, confirm: String) -> unit ::: PasswordsMatch =
  if password = confirm then
    ok unit ::: PasswordsMatch
  else
    fail 400 "Passwords do not match"
```

### What are capabilities?

Capabilities in Tesl represent **effects** or **permissions**. They make explicit what a function can do:

- `db` - Can perform database operations
- `auth` - Can access authentication information
- `queue` - Can enqueue background jobs
- `time` - Can access the current time
- `sse` - Can send Server-Sent Events

Functions and handlers declare their capabilities in their signature:

```tesl
handler getTodo(id: String ::: ValidTodoId id) -> Todo ? FromDb (Id == id)
  requires [db] =
  selectOne todo from Todo where todo.id == id
```

This handler requires the `db` capability to access the database.

### What does "Validate Once" mean?

This is a core principle of Tesl: **validate data once at the boundary, then carry the proof throughout the system.**

In traditional frameworks:
```typescript
// Traditional approach - validate multiple times
function createUser(email: string) {
  if (!isValid(email)) throw new Error("Invalid email");
  // ... later ...
  if (!isValid(email)) throw new Error("Invalid email"); // Redundant!
}
```

In Tesl:
```tesl
-- Tesl approach - validate once
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if String.contains email "@" then
    ok email ::: ValidEmail email
  else
    fail 400 "Invalid email"

handler createUser(req: CreateUserRequest ::: ValidRequest req) -> User ? FromDb (Id == user.id)
  requires [db] =
  -- email is guaranteed to be valid here, no need to re-check
  insert User { email: req.email }
```

---

## Proof System Questions

### Why do I get "Proof not found" errors?

This error occurs when you try to use a value that doesn't have the required proof attached. Common causes:

1. **Missing validation**: You forgot to validate the input
2. **Proof scope**: The proof is not in scope where you're trying to use it
3. **Type mismatch**: The proof you have doesn't match what's expected

**Solution**: Make sure you're validating at the boundary and the proof flows through to where it's needed.

### How do I detach and reattach proofs?

Use `detachFact` and `attachFact` for explicit proof manipulation:

```tesl
-- Assuming we have: email: String ::: ValidEmail email
let proof = detachFact email in
-- proof is now a separate fact value

let emailWithProof = attachFact proof email in
-- email now has the proof attached again
```

### What are forall proofs?

Forall proofs allow you to make statements about collections:

```tesl
forall todo in todos, TodoExists todo.id
```

This means "for all todos in the list, the todo with that id exists in the database."

### Can I have multiple proofs on a single value?

Yes! A value can carry multiple proofs:

```tesl
check validateEmail(email: String) -> email: String ::: ValidEmail email ::: EmailNotDisposable email
```

This email has two proofs: it's valid and it's not a disposable email address.

---

## API Development Questions

### How do I define API endpoints?

Use `api` to declare endpoints and `handler` functions to implement them:

```tesl
api TodoApi {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    -> Todo ? FromDb (Id == id)
}

handler getTodo(id: String ::: ValidTodoId id) -> Todo ? FromDb (Id == id)
  requires [db] =
  let found = selectOne todo from Todo where todo.id == id
  case found of
    Nothing -> fail 404 "Todo not found"
    Something todo -> todo

server TodoServer for TodoApi {
  getTodo = getTodo
}
```

Then use `main` to serve it:
```tesl
main with capabilities [webService] {
  serve TodoServer on 8080 with capabilities [webService]
}
```

### How do I handle different HTTP methods?

Tesl uses explicit HTTP method keywords in the `api` declaration:

- `get` → GET
- `post` → POST
- `put` → PUT
- `delete` → DELETE

Example:

```tesl
api TodoApi {
  get "/todos/:id" -> Todo ? FromDb (Id == id)
  post "/todos" body req: NewTodo -> Todo ? FromDb (Id == todo.id)
  put "/todos/:id" body req: UpdateTodo -> Todo ? FromDb (Id == id)
  delete "/todos/:id" -> Unit
}
```

### How do I parse request bodies?

Define a record and codec:

```tesl
record NewTodo {
  title: String ::: ValidTitle title
  description: String ::: ValidDescription description
}

codec NewTodo {
  toJson_forbidden  -- This type is input-only
  fromJson [
    {
      title       <- "title"       with_codec stringCodec via isValidTitle
      description <- "description" with_codec stringCodec via isValidDescription
    }
  ]
}

handler createTodo(req: NewTodo ::: ValidNewTodo) -> Todo ? FromDb (Id == todo.id)
  requires [db] =
  -- req is already parsed and validated
  insert Todo req
```

### How do I handle query parameters?

In handlers, you can access query parameters through the request. For typed query parameters, define them as handler parameters:

```tesl
handler listTodos(page: Int ::: Positive page, limit: Int ::: Positive limit) -> Paginated Todo
  requires [db] =
  let offset = (page - 1) * limit in
  let todos = select todo from Todo limit limit offset offset in
  ok { items: todos, page: page, limit: limit, total: countTodos() }
```

In the API declaration, use path parameters for URL segments and pass query parameters as regular handler arguments.

### How do I access the request object directly?

In most cases, you don't need to! Tesl's design encourages you to declare what you need in the handler signature. However, if you need raw access:

```tesl
handler rawRequest(request: HttpRequest) -> Response
  requires [] =
  let headers = request.headers in
  let queryParams = request.query in
  -- Access raw request fields
  ok response
```

---

## Database Questions

### Which databases are supported?

Currently, **PostgreSQL** is the primary supported database. We're working on support for other databases.

### How do I define a schema?

Use `entity` declarations to define your database schema:

```tesl
entity User table "users" primaryKey id {
  id: String
  email: String ::: ValidEmail email
  name: String
  createdAt: PosixMillis
}

database MyDatabase {
  backend: postgres
  schema: "my_app"
  entities: [User]
  postgres {
    database: env("POSTGRES_DB")
    user: env("POSTGRES_USER")
    password: env("POSTGRES_PASSWORD")
    host: env("POSTGRES_HOST")
    port: envInt("POSTGRES_PORT", 5432)
  }
}
```

The compiler generates the database schema from your entity declarations.

### How do I perform transactions?

Use `with transaction` to wrap multiple database operations:

```tesl
handler transferAmount(fromId: String, toId: String, amount: Int ::: Positive amount)
  -> TransferResult
  requires [db] =
  with transaction {
    update account in Account
      where account.id == fromId
      set account.balance = account.balance - amount
    update account in Account
      where account.id == toId
      set account.balance = account.balance + amount
    ok { success: true }
  }
```

### How do I use prepared statements?

All database operations in Tesl use parameterized queries automatically. The typed SQL syntax prevents SQL injection:

```tesl
-- ✅ Safe - typed query with compile-time checked field names
let user = selectOne user from User where user.email == email

-- ❌ Unsafe - don't use string concatenation in queries
-- let user = selectOne user from User where user.email == ("'" ++ email ++ "'")
```

---

## Error Handling Questions

### How do I return custom error messages?

Use `fail` with an appropriate status code:

```tesl
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if String.contains email "@" then
    ok email ::: ValidEmail email
  else
    fail 400 "Invalid email: must contain @ symbol"
```

### How do I handle errors in handlers?

Errors from `check` functions automatically become HTTP error responses. You can also return errors explicitly:

```tesl
handler getTodo(id: String ::: ValidTodoId id) -> Todo ? FromDb (Id == id)
  requires [db] =
  let found = selectOne todo from Todo where todo.id == id
  case found of
    Nothing -> fail 404 "Todo not found"
    Something todo -> todo
```

### What error status codes should I use?

| Error Type | Status Code |
|------------|-------------|
| Validation error | 400 |
| Authentication required | 401 |
| Permission denied | 403 |
| Not found | 404 |
| Conflict | 409 |
| Server error | 500 |

---

## Testing Questions

### How do I write tests?

Use the `test` keyword for unit tests:

```tesl
test "double 5 is 10" {
  expect double 5 == 10
}

test "property: add is commutative" with 100 runs {
  property "commutative" (x: Int, y: Int) { add x y == add y x }
}
```

For API integration tests, use `api-test`:

```tesl
api-test "GET /todos returns empty list" for TodoServer {
  let result = get "/todos"
  expect statusOk result.status
  expect result.body == []
}
```

### How do I run tests?

```bash
tesl test example/sandbox2.test.tesl
```

### What is mutation testing?

Mutation testing automatically generates small changes ("mutants") to your validation functions and checks if your tests catch them. This helps ensure your tests are thorough.

```bash
tesl mutate example/todo-api.tesl
```

---

## Performance Questions

### Is there runtime overhead for proofs?

**No — proofs are zero-cost by default.** In a normal (release) build the proof annotations
(`:::`) are **erased** after type-checking: there is no wrapper, no struct, and no allocation.
The proof exists only in the compiler's static checker, so by the time your code runs it is
completely gone.

Even under `--debug`, proofs stay erased — the step debugger shows the raw runtime value and
overlays a binding's proof/type from compile-time type info (the static checker already knows it).
Setting `TESL_ZERO_COST_PROOFS=0` restores the runtime net for regression comparison.

The one construct that always carries a minimal runtime token is a *free-floating* proof
(`detachFact` / `attachFact`), because such a proof is an explicit first-class value that is
passed around at runtime.

See the [proof cost model](best-practices.md#proof-cost-model) for the full per-feature table.

### How fast is Tesl?

The compiler is written in OCaml and is quite fast. The runtime is Racket, which has good performance characteristics. However, we haven't done extensive performance optimization yet, as we're focused on getting the language right first.

### Can I use Tesl in production?

Tesl is **alpha-stage**, so we don't recommend it for production use yet. However, we're actively working towards a stable release.

---

## Tooling Questions

### Is there editor support?

Yes! We have:
- **VS Code/VSCodium extension** in `editor/vscode-tesl/`
- **Language Server Protocol (LSP)** support
- **Syntax highlighting**
- **Live diagnostics** (as you type)
- **Go-to-definition**
- **Hover information**
- **Auto-completion**

See [README.md#editor-and-language-server](../README.md#editor-and-language-server) for setup instructions.

### Can I generate client code?

Yes! Tesl can generate TypeScript and Elm client code:

```bash
tesl --generate-ts my-api.tesl --out client.ts
tesl --generate-elm my-api.tesl --out Client.elm
```

### Is there a formatter?

Yes! Use the built-in formatter:

```bash
tesl --fmt my-file.tesl           # Format in place
tesl --fmt-check my-file.tesl    # Check formatting without modifying
```

### Is there a linter?

Yes! Use the built-in linter:

```bash
tesl --lint my-file.tesl
```

---

## Contribution Questions

### How can I contribute?

We welcome contributions! See [dev-docs/README.md](../dev-docs/README.md) for getting started. Common ways to contribute:

- Report bugs and suggest features
- Improve documentation
- Add examples
- Fix bugs in the compiler or runtime
- Add new features to the language
- Improve tooling

### Do I need to know OCaml or Racket?

- **OCaml**: The compiler is written in OCaml. To work on the compiler, you'll need to learn OCaml.
- **Racket**: The runtime is written in Racket. To work on the runtime, you'll need to learn Racket.
- **Tesl**: The language itself is designed to be approachable without knowing OCaml or Racket.

### How do I build from source?

```bash
nix develop  # or nix-shell
cd compiler
bash build.sh
```

---

## Getting Help

### Where can I ask questions?

- **GitHub Issues**: https://github.com/mtonnberg/tesl/issues
- **Discussions**: Check the GitHub repository for discussion forums

### How do I report a bug?

Please include:
1. What you were trying to do
2. What you expected to happen
3. What actually happened
4. The exact error message (if any)
5. A minimal reproduction case (if possible)

### How do I request a feature?

Please create a GitHub issue with:
1. A clear description of the feature
2. The problem it solves
3. Any relevant examples or use cases

---

## See Also

- [Manual Index](MANUAL.md) - Back to the main manual
- [Overview](overview.md) - Introduction to Tesl
- [TESL.md](../TESL.md) - High-level language introduction
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) - Formal specification
- [Examples](examples.md) - Complete list of examples
- [Best Practices](best-practices.md) - Recommended patterns
- [Developer Docs](../dev-docs/) - Contribution guides
