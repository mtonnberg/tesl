# SQL Expansion Roadmap

## Context

Tesl currently supports single-table `select`, `selectOne`, `selectCount`, and `selectMany` queries with basic `WHERE` predicates, `ORDER BY`, and `LIMIT`. `withTransaction` is already supported for grouping multiple operations atomically. The missing features described below are the most commonly requested for real-world web APIs.

---

## 1. Multi-Table Joins with Type Inference

**Description:** `innerJoin` is partly implemented but lacks full type inference when joining across tables. The result type of a join should be automatically derived from the two source schemas.

**Why it matters:** Nearly every non-trivial API endpoint reads from more than one table — users joined to orders, posts joined to authors. Without joins, code falls back to N+1 query patterns in application logic.

**Proposed syntax:**

```tesl
let rows =
  select (u, o) from User as u
    innerJoin Order as o on u.id == o.userId
    where o.total > minAmount
    orderBy o.createdAt desc
```

The result type is inferred as `List (Tuple2 User Order)`, no annotation required.

---

## 2. GROUP BY and HAVING

**Description:** Aggregate queries that group rows and optionally filter groups. Pairs with aggregate functions (`count`, `sum`, `avg`, `min`, `max`).

**Why it matters:** Dashboards, reporting endpoints, and analytics all need aggregated data. Fetching all rows and summing in application code is inefficient and does not scale.

**Proposed syntax:**

```tesl
let stats =
  select { userId: o.userId, total: sum o.amount }
  from Order as o
  groupBy o.userId
  having sum o.amount > threshold
```

---

## 3. Subqueries

**Description:** A `select` expression used as a source or filter inside an outer query. Covers `IN (subquery)`, `EXISTS (subquery)`, and derived-table subqueries in `FROM`.

**Why it matters:** Many filtering patterns require comparing against a computed set — e.g., "all users who have placed at least one order" or "products not yet reviewed by this user".

**Proposed syntax:**

```tesl
# IN subquery
let active =
  select u from User as u
  where u.id in (select o.userId from Order as o where o.status == "open")

# EXISTS subquery
let reviewed =
  select p from Product as p
  where exists (select r from Review as r where r.productId == p.id)
```

---

## 4. Advanced WHERE Predicates

**Description:** `BETWEEN`, `IN` (literal list), `LIKE`/`ILIKE`, and `IS NULL` / `IS NOT NULL` are absent from the current predicate set.

**Why it matters:** These predicates appear in virtually every real schema. Workarounds require raw SQL strings, bypassing Tesl's type safety.

**Proposed syntax:**

```tesl
where p.price between minPrice and maxPrice
where u.role in ["admin", "moderator"]
where u.email like "%@example.com"
where u.deletedAt isNull
where u.verifiedAt isNotNull
```

---

## 5. Upsert (Insert-or-Update)

**Description:** A single operation that inserts a row or updates it if a conflict on a unique key occurs. Maps to `INSERT … ON CONFLICT DO UPDATE` in PostgreSQL.

**Why it matters:** Idempotent writes are essential for webhook handlers, import pipelines, and retry-safe API endpoints.

**Proposed syntax:**

```tesl
upsert User { id: userId, email: email, name: name }
  onConflict [id]
  doUpdate   [email, name]
```

---

## 6. Window Functions

**Description:** `ROW_NUMBER()`, `RANK()`, `LEAD()`, `LAG()`, and `SUM() OVER (PARTITION BY …)` for ordered, partitioned computations within a result set.

**Why it matters:** Pagination with stable row numbers, running totals, and leaderboards require window functions. Without them, multi-step application logic approximates what the database can do in a single pass.

**Proposed syntax:**

```tesl
let ranked =
  select { u: u, rank: rowNumber over (partitionBy u.country orderBy u.score desc) }
  from User as u
```

## 7. Better transparency - debug view

Add either a function (sql query -> string) or add Language server support to view the sql that will be run directly by hovering/selecting the sql query.


---

## Priority Order

| # | Feature | Complexity | Impact |
|---|---------|------------|--------|
| 1 | Multi-table joins | Medium | High |
| 2 | Advanced WHERE | Low | High |
| 3 | Upsert | Low | High |
| 4 | GROUP BY / HAVING | Medium | Medium |
| 5 | Subqueries | High | Medium |
| 7 | Debug view | Unknown | High |
| 6 | Window functions | High | Low |
