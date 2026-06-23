# Tesl Best Practices

This guide covers recommended patterns, conventions, and best practices for writing idiomatic and maintainable Tesl code.

Use `tesl help manual best-practices` to access this from the CLI.

---

## Table of Contents

1. [General Principles](#general-principles)
2. [Project Structure](#project-structure)
3. [Naming Conventions](#naming-conventions)
4. [Validation Patterns](#validation-patterns)
5. [Proof Management](#proof-management)
6. [Error Handling](#error-handling)
7. [API Design](#api-design)
8. [Database Access](#database-access)
9. [Testing](#testing)
10. [Performance](#performance)

---

## General Principles

### Validate Once at the Boundary

**✅ Do:**
```tesl
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if String.contains email "@" then
    ok email ::: ValidEmail email
  else
    fail 400 "Invalid email format"
```

**❌ Don't:** Re-validate the same value multiple times in the call stack.

The compiler tracks the proof (`:::` annotation) and ensures the value remains validated throughout its lifetime.

### Make Auth Requirements Explicit

**✅ Do:**
```tesl
handler getTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: ValidTodoId todoId)
  -> Todo ? FromDb (Id == todoId)
  requires [auth, db] =
  -- Auth requirement is visible in the signature
```

**❌ Don't:** Hide auth checks in middleware or handler bodies without type-level visibility.

### Keep Functions Small and Focused

Each function should:
- Have a single responsibility
- Validate its inputs (if at the boundary)
- Return clearly typed outputs with appropriate proofs

---

## Project Structure

### Recommended Directory Layout

```
my-api/
├── src/
│   ├── types.tesl          # Shared type definitions
│   ├── validation.tesl    # Validation functions (checks)
│   ├── auth.tesl          # Authentication predicates and handlers
│   ├── db.tesl            # Database schema and queries
│   ├── routes/
│   │   ├── todos.tesl     # Todo-related routes
│   │   ├── users.tesl     # User-related routes
│   │   └── ...
│   └── main.tesl          # Entry point with API declaration
├── tests/
│   ├── todos.test.tesl    # Tests for todo routes
│   └── users.test.tesl    # Tests for user routes
└── config/
    └── database.tesl      # Database configuration
```

### Module Organization

- **One module per file** with clear exports
- **Explicit imports** - always specify what you import
- **Layered architecture** - validation → types → business logic → routes

---

## Naming Conventions

### Types and Predicates

| Entity | Convention | Example |
|--------|------------|---------|
| Type names | PascalCase | `User`, `Todo`, `EmailAddress` |
| Predicate names | PascalCase, often prefixed with `Is`, `Has`, or `Valid` | `ValidEmail`, `UserExists`, `HasPermission` |
| Record fields | camelCase | `firstName`, `lastName`, `createdAt` |
| Variables | camelCase | `userId`, `todoList`, `email` |
| Functions | camelCase | `getUser`, `createTodo`, `validateEmail` |
| Proof names | Same as predicate | `ValidEmail`, `UserExists` |

### Route Naming

- **Plural nouns** for collections: `GET /todos`, `POST /todos`
- **Singular nouns** for single items: `GET /todos/:id`, `PUT /todos/:id`
- **Verbs** for actions: `POST /todos/:id/complete`, `POST /users/login`

### Check Function Naming

Prefix validation functions with verbs that indicate their purpose:
- `isValid...` - for simple boolean validation
- `check...` - for validation that returns proofs
- `parse...` - for parsing/transforming input

---

## Validation Patterns

### Composing Validations

**✅ Do:** Compose simple checks into complex ones:
```tesl
check validateUser(user: RawUser) -> validated: User ::: ValidUser validated =
  let email = check isValidEmail(user.email) in
  let name = check isValidName(user.name) in
  let age = check isValidAge(user.age) in
  ok { email, name, age } ::: ValidUser { email, name, age }
```

### Using Codecs

**✅ Do:** Define codecs for request/response types:
```tesl
record NewTodo {
  title: String ::: ValidTitle title
  description: String ::: ValidDescription description
  dueDate: Date ::: ValidFutureDate dueDate
}

codec NewTodo {
  toJson_forbidden
  fromJson
}
```

### Cross-Field Validation

**✅ Do:** Use `check` for cross-field validation:
```tesl
check validateRegistration(req: RegistrationRequest) -> valid: RegistrationRequest ::: ValidRegistration valid =
  let email = check isValidEmail(req.email) in
  let password = check isValidPassword(req.password) in
  let _ = check passwordsMatch(req.password, req.confirmPassword) in
  ok req ::: ValidRegistration req

check passwordsMatch(password: String, confirm: String) -> unit ::: PasswordsMatch =
  if password = confirm then
    ok unit ::: PasswordsMatch
  else
    fail 400 "Passwords do not match"
```

---

## Proof Management

### Attaching Proofs

**✅ Do:** Attach proofs at the validation boundary:
```tesl
handler createTodo(req: NewTodo ::: ValidNewTodo) -> Todo ? FromDb (Id == todo.id)
  requires [db] =
  -- req carries the ValidNewTodo proof automatically
  insert Todo req
```

### Detaching and Reattaching Proofs

When you need to pass proofs explicitly:
```tesl
fn processTodo(todo: Todo ::: TodoExists todo.id) -> Result =
  let proof = detachFact todo in
  -- proof is now a separate fact value
  -- todo is the raw value without the proof
  ...
```

### Forall Proofs

**✅ Do:** Use forall proofs for collections:
```tesl
handler getAllTodos() -> List Todo ? ForAll (FromDb (Id == todo.id))
  requires [db] =
  select todo from Todo
```

---

## Error Handling

### Use Appropriate HTTP Status Codes

| Error Type | Status Code | Message |
|------------|-------------|---------|
| Validation error | 400 | "Invalid input: <field> <reason>" |
| Authentication required | 401 | "Authentication required" |
| Permission denied | 403 | "Permission denied" |
| Not found | 404 | "Resource not found" |
| Conflict | 409 | "Resource already exists" |
| Server error | 500 | "Internal server error" |

### Structured Error Messages

**✅ Do:** Provide clear, actionable error messages:
```tesl
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if not (String.contains email "@") then
    fail 400 "Invalid email: must contain @ symbol"
  else if not (String.contains email ".") then
    fail 400 "Invalid email: must contain a domain"
  else
    ok email ::: ValidEmail email
```

**❌ Don't:**
```tesl
fail 400 "Bad request"  -- Too vague
```

---

## API Design

### Route Design

**✅ Do:**
```tesl
api TodoApi {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    auth user: User ::: Authenticated user via cookieAuth
    -> Todo ? FromDb (Id == id)

  post "/todos"
    auth user: User ::: Authenticated user via cookieAuth
    body req: NewTodo ::: ValidNewTodo
    -> Todo ? FromDb (Id == todo.id)

  put "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    auth user: User ::: Authenticated user via cookieAuth
    body req: UpdateTodo
    -> Todo ? FromDb (Id == id)
}
```

### Versioning

Include API version in endpoints:
```tesl
api TodoApi_v1 {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    -> Todo ? FromDb (Id == id)
}

api TodoApi_v2 {
  get "/todos/:id"
    capture id: String ::: ValidTodoId id via todoIdCapture
    -> TodoV2 ? FromDb (Id == id)
}
```

### Pagination

**✅ Do:**
```tesl
api TodoApi {
  get "/todos"
    query page: Int ::: Positive page
    query limit: Int ::: Positive limit
    -> Paginated(Todo)
}
```

---

## Database Access

### Typed Queries

**✅ Do:** Use typed SQL queries with entities:
```tesl
let todos = select todo from Todo where todo.userId == userId
```

The compiler infers the return type from the entity definition and query.

### Parameterized Queries

Always use parameterized queries to prevent SQL injection:
```tesl
-- ✅ Safe - parameterized query
let user = selectOne user from User where user.email == email

-- ❌ Unsafe (SQL injection risk) - don't use string concatenation
-- let user = db.query ("SELECT * FROM users WHERE email = '" ++ email ++ "'")
```

### Transactions

**✅ Do:** Use `with transaction` for multi-operation consistency:
```tesl
handler transferAmount(fromId: String, toId: String, amount: Int ::: Positive amount)
  -> TransferResult
  requires [db] =
  with transaction {
    let fromBalance = selectOne account from Account where account.id == fromId
    let toBalance = selectOne account from Account where account.id == toId

    if fromBalance = Nothing || toBalance = Nothing then
      fail 404 "Account not found"
    else if fromBalance.value.balance < amount then
      fail 400 "Insufficient funds"
    else
      update account in Account
        where account.id == fromId
        set account.balance = account.balance - amount
      update account in Account
        where account.id == toId
        set account.balance = account.balance + amount
      ok { success: true }
  }
```

---

## Testing

Tesl provides a comprehensive testing framework with multiple testing approaches. Understanding each type helps you write robust, maintainable tests for different aspects of your application.

### Test Organization

- **One test file per module** with `.test.tesl` suffix
- **Test both success and failure cases** - don't just test the happy path
- **Use mutation testing** for critical validation functions
- **Keep tests focused** - one assertion or related set of assertions per test
- **Name tests descriptively** - the test name should describe what it verifies

### Test Types Overview

Tesl supports several types of tests, each serving a different purpose:

| Test Type | Command | Purpose | When to Use |
|-----------|---------|---------|-------------|
| **Unit Tests** | `test` / `expect` | Test individual functions in isolation | Pure functions, validation logic |
| **Property Tests** | `property-test` | Verify properties hold across many inputs | Validation invariants, business rules |
| **API Tests** | `api-test` | Test HTTP endpoints | Integration, endpoint behavior |
| **Queue Tests** | `queue-test` | Test background job processing | Queue message handling |
| **SSE/PubSub Tests** | `sse-test` | Test real-time event streams | Server-Sent Events, pub/sub |
| **Load Tests** | `load-test` | Test performance under load | Performance-critical endpoints |
| **Mutation Tests** | `tesl mutate` | Verify validation functions | Critical check/establish/auth functions |

### 1. Unit Tests

Test individual functions in isolation. Use for pure functions and business logic.

**✅ Do:**
```tesl
-- Test a pure function
test "isValidEmail rejects empty strings" = 
  let result = isValidEmail("") in
  expect result.isError == true

test "isValidEmail accepts valid emails" = 
  let result = isValidEmail("test@example.com") in
  expect result.isOk == true
  case result of
    Ok email -> expect email == "test@example.com"
    Err _ -> fail "Expected Ok"

-- Test with specific values
test "addPositive adds correctly" = 
  let result = addPositive(5, 3) in
  case result of
    Ok sum -> expect sum == 8
    Err _ -> fail "Expected Ok"

test "addPositive rejects negative numbers" = 
  let result = addPositive(-1, 5) in
  expect result.isError == true
```

**Key patterns:**
- Use `test` for synchronous pure function tests
- Use `expect` to assert conditions
- Test both happy paths and error cases
- Return `unit` from test blocks

### 2. Property-Based Tests

Verify that properties hold across many randomly generated inputs. Ideal for validation functions.

**✅ Do:**
```tesl
property-test "valid emails are never empty" 100 times = 
  let email = generateValidEmail() in
  expect String.length email > 0

property-test "addPositive is commutative" 50 times = 
  let a = generatePositiveInt() in
  let b = generatePositiveInt() in
  let sum1 = addPositive(a, b) in
  let sum2 = addPositive(b, a) in
  expect sum1 == sum2

property-test "validated strings are never null" 100 times = 
  let input = generateNonNullString() in
  let result = check isValidNonNullString(input) in
  case result of
    Ok s -> expect s != null
    Err _ -> fail "Should always validate"
```

**Key patterns:**
- Use `property-test` with a number of iterations (e.g., 100)
- Use generators to create random inputs: `generateInt`, `generateString`, `generatePositiveInt`, etc.
- Test invariants and properties, not specific values
- Combine with fuzzing to find edge cases

### 3. API Tests

Test HTTP endpoints and API behavior. These are integration tests that verify your API works as expected.

**✅ Do:**
```tesl
api-test "GET /todos returns empty list when no todos exist" for TodoServer {
  let result = get "/todos"
  expect statusOk result.status
  expect result.body == []
}

api-test "POST /todos creates a new todo" for TodoServer {
  let newTodo = { title: "Buy groceries", description: "Milk, eggs, bread" }
  let result = post "/todos" body newTodo
  expect statusCreated result.status
  expect String.length result.body.id > 0
  expect result.body.title == "Buy groceries"
}

api-test "POST /todos fails with invalid title" for TodoServer {
  let result = post "/todos" body { title: "" }
  expect result.status == 400
  expect String.contains result.body "Title must be between 3 and 120 characters"
}

api-test "GET /todos/:id returns specific todo" for TodoServer {
  -- First create a todo
  let createResult = post "/todos" body { title: "Test todo", description: "Test" }
  expect statusCreated createResult.status
  
  -- Then get it by ID
  let id = createResult.body.id
  let getResult = get ("/todos/" ++ id)
  expect statusOk getResult.status
  expect getResult.body.id == id
}
```

**Key patterns:**
- Use `api-test` with a server name (e.g., `for TodoServer`)
- The server must be defined in your code with `server TodoServer impl TodoApi on <port>`
- Test the full HTTP cycle: request → handler → response
- Test both success and error responses
- Verify status codes, response bodies, and headers

### 4. Queue Tests

Test background job processing. Queue tests verify that your queue handlers process messages correctly.

**✅ Do:**
```tesl
queue-test "ProcessUserRegistration handles valid registration" for TodoServer {
  -- Setup: define what should be in the queue
  let registration = ProcessUserRegistration {
    userId: "user-123",
    email: "test@example.com",
    name: "Test User"
  }
  
  -- Enqueue the message
  enqueue registration
  
  -- Wait for processing (automatic in tests)
  
  -- Verify the result
  let user = selectOne user from User where user.id == "user-123"
  expect user.isSome == true
  let someUser = user.force
  expect someUser.email == "test@example.com"
}

queue-test "ProcessUserRegistration handles validation errors" for TodoServer {
  let invalidRegistration = ProcessUserRegistration {
    userId: "",  -- Invalid ID
    email: "test@example.com",
    name: "Test User"
  }
  
  enqueue invalidRegistration
  
  -- Verify error handling (e.g., dead letter queue or error log)
  let errors = select count(*) from QueueErrors
  expect errors > 0
}
```

**Key patterns:**
- Use `queue-test` with a server name
- Use `enqueue` to add messages to the test queue
- The queue processor runs automatically in the test context
- Verify both successful processing and error handling
- Check database state after queue processing

### 5. SSE/PubSub Tests

Test real-time event streams and server-sent events.

**✅ Do:**
```tesl
sse-test "Subscribing to todo updates receives events" for ChatServer {
  -- Setup: create initial state
  let todoId = createTestTodo()
  
  -- Subscribe to updates
  let subscription = subscribe ("/todos/" ++ todoId ++ "/updates")
  
  -- Trigger an update
  updateTodo todoId { completed: true }
  
  -- Wait for and verify the event
  let event = awaitNextEvent subscription
  expect event.type == "todo-updated"
  expect event.data.completed == true
  expect event.data.id == todoId
}

sse-test "Multiple subscribers receive broadcast events" for ChatServer {
  let sub1 = subscribe "/chat/messages"
  let sub2 = subscribe "/chat/messages"
  
  -- Send a message
  sendChatMessage { text: "Hello world" }
  
  -- Both subscribers should receive it
  let event1 = awaitNextEvent sub1
  let event2 = awaitNextEvent sub2
  
  expect event1.data.text == "Hello world"
  expect event2.data.text == "Hello world"
}
```

**Key patterns:**
- Use `sse-test` for Server-Sent Events tests
- Use `subscribe` to create test subscribers
- Use `awaitNextEvent` to wait for and receive events
- Verify event types, data, and timing
- Test both unicast and broadcast scenarios

### 6. Load Tests

Test performance under load. Useful for identifying bottlenecks and ensuring your API scales.

**✅ Do:**
```tesl
load-test "API handles 100 concurrent requests" for TodoServer {
  let requests = List.replicate 100 { title: "Load test todo", description: "Test" }
  
  -- Send all requests concurrently
  let results = sendConcurrentRequests "/todos" requests
  
  -- Verify all succeeded
  expect List.length results == 100
  let successes = List.filter (fun r -> r.status == 201) results
  expect List.length successes == 100
}

load-test "Database queries perform under load" for TodoServer {
  -- Create test data
  let todoIds = List.map (fun i -> createTodo ("Todo " ++ Int.toString i)) (List.range 0 1000)
  
  -- Query concurrently
  let results = List.map (fun id -> get ("/todos/" ++ id)) todoIds
  
  -- Verify all returned successfully
  expect List.all (fun r -> r.status == 200) results
}
```

**Key patterns:**
- Use `load-test` for performance testing
- Use `sendConcurrentRequests` to simulate load
- Test with realistic data volumes
- Measure response times and success rates
- Verify system stability under load

### 7. Mutation Testing

Mutation testing automatically modifies your validation functions and checks if your tests catch the bugs. This is critical for ensuring your validation logic is thoroughly tested.

**How it works:**
1. Tesl identifies all `check`, `establish`, and `auth` functions
2. For each function, it creates "mutants" (slightly modified versions)
3. Runs your tests against each mutant
4. Reports which mutants were **killed** (tests failed) and which **survived** (tests passed)

**✅ Do:**
```bash
# Run mutation testing on a single file
tesl mutate api.tesl

# Run mutation testing with specific test files
tesl mutate api.tesl tests/api.test.tesl

# Run mutation testing on all files
tesl mutate **/*.tesl
```

**Example output:**
```
Mutation testing: api.tesl

  [KILLED]   isValidEmail - changed condition from > to >=
  [KILLED]   isValidTitle - removed length check
  [SURVIVED] isValidAge - changed > 0 to >= 0  <-- NEEDS BETTER TESTS!
  [KILLED]   authenticateUser - removed password check

Mutation score: 85% (17/20 mutants killed)
```

**Interpreting results:**
- **Killed mutants**: Your tests caught the bug - good!
- **Survived mutants**: Your tests didn't catch the bug - you need better tests
- **Mutation score**: Percentage of mutants killed - aim for 80%+

**When a mutant survives:**
1. Look at what was changed (shown in the output)
2. Understand why your tests didn't catch it
3. Add or improve tests to catch this case
4. Re-run mutation testing

**Key patterns:**
- Run mutation testing regularly, especially before merging
- Aim for a mutation score of at least 80%
- Focus on critical validation functions first
- Survived mutants indicate missing test cases

### Test Best Practices

#### 1. The Testing Pyramid

Follow the testing pyramid principle:

```
          ┌─────────────┐
          │   Load      │  Few, slow, broad
          │   Tests     │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │   Queue/    │  Moderate, async behavior
          │   SSE Tests │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │  API Tests  │  Many, HTTP endpoints
          │             │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │  Unit/Prop  │  Most, pure functions
          │   Tests     │
          └─────────────┘
```

#### 2. Test Naming

**✅ Do:**
```tesl
-- Good: describes behavior and expected outcome
api-test "POST /users returns 400 when email is invalid"

-- Good: describes the property being tested
test "isValidEmail returns Ok for valid emails"

-- Good: describes the scenario
queue-test "ProcessPayment handles insufficient funds"
```

**❌ Don't:**
```tesl
-- Bad: too vague
test "test1"

-- Bad: doesn't describe what's being tested
test "user test"

-- Bad: uses implementation details
test "user controller create method"
```

#### 3. Test Structure

Follow the Arrange-Act-Assert pattern:

```tesl
api-test "POST /users creates user and returns 201" for TodoServer {
  -- Arrange: setup test data
  let newUser = { email: "test@example.com", name: "Test User" }
  
  -- Act: perform the operation
  let result = post "/users" body newUser
  
  -- Assert: verify the outcome
  expect statusCreated result.status
  expect result.body.email == "test@example.com"
}
```

#### 4. Test Isolation

- Each test should be independent of others
- Don't rely on state from previous tests
- Use setup/teardown patterns if needed
- Reset database state between tests

**✅ Do:**
```tesl
api-test "first test" for TodoServer {
  -- Create test data
  let todo1 = createTestTodo()
  -- Test with todo1
  -- Clean up
  deleteTodo todo1.id
}

api-test "second test" for TodoServer {
  -- Create fresh test data
  let todo2 = createTestTodo()
  -- Test with todo2
  -- Clean up
  deleteTodo todo2.id
}
```

#### 5. Testing Validation Functions

Validation functions (`check`, `establish`, `auth`) are critical and should be thoroughly tested:

1. **Test valid inputs** - ensure they pass
2. **Test invalid inputs** - ensure they fail with appropriate errors
3. **Test edge cases** - boundary values, empty strings, null, etc.
4. **Use mutation testing** - to catch subtle bugs

**✅ Do:**
```tesl
-- Test valid inputs
test "isValidEmail accepts valid emails" = 
  expect (isValidEmail("test@example.com")).isOk == true
  expect (isValidEmail("user@domain.co.uk")).isOk == true

-- Test invalid inputs
test "isValidEmail rejects invalid emails" = 
  expect (isValidEmail("")).isError == true
  expect (isValidEmail("not-an-email")).isError == true
  expect (isValidEmail("@example.com")).isError == true

-- Test edge cases
test "isValidEmail handles long emails" = 
  let longEmail = "a" ++ String.replicate 250 "x" ++ "@example.com"
  expect (isValidEmail(longEmail)).isError == true  -- or true, depending on spec
```

#### 6. Testing Error Cases

Don't forget to test that errors are handled correctly:

```tesl
api-test "GET /todos/:id returns 404 for non-existent todo" for TodoServer {
  let result = get "/todos/nonexistent-id"
  expect result.status == 404
  expect String.contains result.body "not found"
}

api-test "POST /todos returns 400 for invalid title" for TodoServer {
  let result = post "/todos" body { title: "" }
  expect result.status == 400
  expect String.contains result.body "Title must be between 3 and 120 characters"
}
```

#### 7. Test Data Builders

Create helper functions to build test data:

```tesl
-- In a test helper module
fn createTestUser(?email: String, ?name: String) -> User ::: FromDb (Id == user.id)
  requires [db, time] =
  let user = {
    id: generatePrefixedId("test-user"),
    email: email | default "test@example.com",
    name: name | default "Test User",
    createdAt: nowMillis()
  } in
  insert User user

fn createTestTodo(?title: String, ?userId: String) -> Todo ::: FromDb (Id == todo.id)
  requires [db, time] =
  let todo = {
    id: generatePrefixedId("test-todo"),
    title: title | default "Test todo",
    userId: userId | default (createTestUser()).id,
    completed: false,
    createdAt: nowMillis()
  } in
  insert Todo todo
```

Then use them in tests:

```tesl
api-test "GET /users/:id/todos returns user's todos" for TodoServer {
  let user = createTestUser(email: "alice@example.com")
  let todo1 = createTestTodo(title: "First todo", userId: user.id)
  let todo2 = createTestTodo(title: "Second todo", userId: user.id)
  let todo3 = createTestTodo(title: "Other user's todo")
  
  let result = get ("/users/" ++ user.id ++ "/todos")
  expect statusOk result.status
  expect List.length result.body == 2
}
```

### Running Tests

```bash
# Run all tests in a file
tesl test my-api.test.tesl

# Run multiple test files
tesl test tests/*.test.tesl

# Run with verbose output
tesl test my-api.test.tesl  # Set TESL_VERBOSE=1 for more details

# Run only API tests (filters by test type)
tesl test my-api.test.tesl  # Currently runs all test types

# Check test syntax without running
tesl check my-api.test.tesl
```

### Test Configuration

Configure test behavior in your test files:

```tesl
-- Set up test database
beforeAll for TodoServer = 
  runMigration "test-migration.sql"

-- Clean up after all tests
afterAll for TodoServer = 
  runMigration "test-cleanup.sql"

-- Set up before each test
beforeEach for TodoServer = 
  clearTable Todo
  clearTable User

-- Clean up after each test
afterEach for TodoServer = 
  clearTable Todo
  clearTable User
```

### Test Utilities

Tesl provides several test utilities:

```tesl
-- Assertions
expect condition          -- Assert condition is true
expect condition message  -- Assert with custom message
expectEqual a b          -- Assert a equals b
expectNotEqual a b       -- Assert a does not equal b
expectError fn           -- Assert fn raises an error
expectSome option        -- Assert option is Some
expectNone option        -- Assert option is None
expectOk result          -- Assert result is Ok
expectErr result         -- Assert result is Err

-- HTTP assertions
expect statusOk status        -- 200
expect statusCreated status   -- 201
expect statusNoContent status  -- 204
expect statusBadRequest status  -- 400
expect statusNotFound status     -- 404

-- Matchers
String.contains haystack needle    -- Check if string contains substring
String.startsWith str prefix      -- Check if string starts with prefix
String.endsWith str suffix        -- Check if string ends with suffix
List.contains list item           -- Check if list contains item
List.length list == n             -- Check list length
```

### Debugging Tests

When tests fail, use these techniques:

1. **Read the error message** - Tesl provides detailed error messages
2. **Check the test output** - Use `TESL_VERBOSE=1` for verbose output
3. **Add temporary output** - Use `println` for debugging:
   ```tesl
   test "debug test" = 
     let x = computeSomething() in
     println "x is: " x  -- Debug output
     expect x > 0
   ```
4. **Run a single test** - Isolate the failing test
5. **Check the database** - Manually inspect the test database state

### Test Performance Tips

1. **Reuse test servers** - Start the server once and run multiple tests
2. **Reset state efficiently** - Use `beforeEach`/`afterEach` instead of `beforeAll`/`afterAll` when possible
3. **Parallelize tests** - Run different test files in parallel
4. **Mock external services** - Don't test external API integrations in unit tests
5. **Use test doubles** - For complex dependencies that are hard to test

### Test Coverage

Tesl doesn't have built-in coverage reporting, but you can:

1. Use mutation testing (`tesl mutate`) to measure test quality
2. Manually track which functions are tested
3. Aim for 100% coverage of validation functions
4. Aim for 80%+ coverage of business logic

### Common Test Anti-Patterns

**❌ Don't:**
```tesl
-- Testing implementation details
test "handler uses selectOne" = 
  -- This tests HOW the handler works, not WHAT it does
  -- Better: test the behavior, not the implementation

-- Testing too much in one test
test "complex scenario with many assertions" = 
  let result = doComplexOperation()
  expect result.a == 1
  expect result.b == 2
  expect result.c == 3
  expect result.d == 4
  -- Better: split into multiple focused tests

-- Slow tests in the wrong place
test "sleep test" = 
  Thread.sleep 10000
  -- Better: use load tests for timing tests

-- Tests that depend on each other
test "first" = ...  -- creates data
test "second" = ...  -- depends on data from first
  -- Better: each test should be independent
```

**✅ Do instead:**
- Test behavior, not implementation
- Keep tests focused on one thing
- Use appropriate test types (unit, API, load, etc.)
- Keep tests independent

---

## Performance

---

## Performance

### Minimize Allocations

- **Proof structs** are currently allocated at runtime but will be elided in the future
- **Use value-level proofs** where possible instead of free-floating proofs
- **Batch database queries** when possible

### Caching

**✅ Do:** Cache expensive validation results. Consider using a database-backed cache for horizontal scaling.

### Database Indexing

Ensure your database has appropriate indexes for common queries:
```sql
CREATE INDEX idx_todos_user_id ON todos(user_id);
CREATE INDEX idx_todos_created_at ON todos(created_at);
```

---

## Common Pitfalls and Solutions

### Problem: "Proof not found" errors

**Solution:** Ensure you're attaching proofs at the validation boundary:
```tesl
-- ✅ Correct
check validateEmail(email: String) -> email: String ::: ValidEmail email = ...

-- ❌ Incorrect (missing proof attachment)
fn validateEmail(email: String) -> String = ...
```

### Problem: "Cannot find proof for predicate X"

**Solution:** Make sure the proof is in scope and attached to the value. Use `detachFact` and `attachFact` for explicit proof manipulation.

### Problem: "Type mismatch" in API endpoints

**Solution:** Check that your API endpoint and handler signatures match the actual types. Use `:::` annotations to make proofs explicit.

### Problem: Database query type inference fails

**Solution:** Make sure your entity declaration has the correct fields and types, and your query references them correctly.

---

## See Also

- [Manual Index](MANUAL.md) - Back to the main manual
- [Examples](examples.md) - Complete list of examples
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) - Formal specification
- [TESL.md](../TESL.md) - High-level introduction
