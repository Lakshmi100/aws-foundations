# Coding style

This codebase is read by people who know programming but are not necessarily
Python experts. Write code that a Java, C# or JavaScript developer can follow
without looking anything up. Readability should not cost quality or performance.
The rules below only rule out Python shortcuts that make no measurable
difference to either.

A target repo that adopts this standard should name a worked example of these
rules in its `AGENTS.md` (its reference pattern). When in doubt, copy what it does.

## 1. Principles

1. **Explicit over clever.** If there is a short Python trick and a plain
   version that any developer would recognise, use the plain version.
2. **One step per line.** Each line does one thing, and intermediate results
   get a named variable.
3. **Say why, not what.** Code shows what happens. Comments explain why it
   happens, or point out something a reader could not guess.
4. **Framework rules are not shortcuts.** FastAPI, SQLAlchemy, Pydantic and
   pytest require some Python-specific constructs. Keep them, and explain them
   (see section 5).

## 2. Naming

- Use full words: `customer`, `session`, `response`, `error`. Do not use `c`,
  `db`, `resp` or `e`.
- Do not use `_` as a variable or parameter name. Give unused values a real
  name.
- Do not start names with `_` to mean "private". Choose a name that says what
  the function does (`find_customer_or_404`, not `_get`).
- Name booleans as questions: `is_active`, `has_orders`.
- Name test data after the role it plays: `ADA`, `GRACE`,
  `ADA_WITH_EVERY_FIELD`. Avoid generic names such as `VALID` or `DATA`.

## 3. Structure

- **One step per line.** Do not chain calls more than two deep, and do not put
  calls inside other calls' arguments:

  ```python
  # Avoid
  return list(db.scalars(select(Customer).order_by(Customer.id)))

  # Prefer
  query = select(Customer).order_by(Customer.id)
  result = session.scalars(query)
  return list(result)
  ```

  One method chain that reads as a sentence is fine, such as
  `select(Customer).order_by(Customer.id)`.

- **Use `if` / `else` blocks, not inline conditionals as values:**

  ```python
  # Avoid
  connect_args = {"check_same_thread": False} if url.startswith("sqlite") else {}

  # Prefer
  if url.startswith("sqlite"):
      connection_options = {"check_same_thread": False}
  else:
      connection_options = {}
  ```

- **Give every function a return type and parameter types.** They act as
  documentation.

## 4. Python shortcuts to avoid

| Avoid | Write instead |
|---|---|
| `lambda` (anonymous functions) | A normal `def` with a name and a docstring |
| `*args` / `**kwargs` in your own functions | Named parameters |
| `**some_dict` to unpack into a call or another dict | Pass each argument by name, or use a named helper such as `with_changes(customer, {...})` |
| `setattr` / `getattr` with a field name held in a variable | Assign each attribute directly: `customer.email = payload.email` |
| Comprehensions with a condition, nesting or several `for`s | A normal `for` loop |
| Walrus operator `x := ...` | Assign on its own line first |
| Chained comparisons `a < b < c` | `a < b and b < c` |
| Inline `x if condition else y` used as a value | An `if` / `else` block |
| Clever slicing such as `items[::-1]` or `items[1:-1]` | A named helper or a loop, or `reversed(items)` |
| `raise ... from None` | `raise ... from error`, with a comment (see section 6) |
| `"x" * 30` string repetition | Allowed only with a comment saying what it builds (tests only) |

**Simple comprehensions are allowed:** one `for` with no `if` and no nesting.

```python
emails = [customer["email"] for customer in customers]   # allowed
```

**Allowed because most languages have an equivalent:** f-strings
(`f"/customers/{customer_id}"`), `with` blocks, `try` / `except` / `finally`,
`is None`, `for ... in ...`.

## 5. Framework constructs: keep them, explain them

These are required by the libraries. There is no plainer alternative that
still works, so keep them and help the reader:

- Each one gets a comment starting with `Framework note:` the **first time it
  appears in a file**.
- Section 9 explains each one in more detail.

| Construct | Where it appears |
|---|---|
| Decorators: `@router.post(...)`, `@app.get(...)`, `@pytest.fixture`, `@asynccontextmanager` | routes, main, tests |
| `Depends(get_db)` as a parameter default | routes |
| `yield` for "set up, hand over, clean up" | `get_db`, `lifespan`, test fixtures |
| `Mapped[...]` / `mapped_column(...)` | models |
| `BaseModel`, `Field(...)`, `model_config` | schemas |
| `async def` | `lifespan` only (FastAPI requires it there) |

Example:

```python
# Framework note: the line starting with @ (a "decorator") registers the
# function below as the handler for POST /customers.
@router.post("", response_model=CustomerRead, status_code=status.HTTP_201_CREATED)
def create_customer(payload: CustomerCreate, session: Session = Depends(get_db)) -> Customer:
```

## 6. Copying fields and handling errors

**Copy fields explicitly.** When building or updating a database object from a
request, assign each field by name. Add a comment that shows the shorter
Python alternative, so the team can switch to it later if it decides to:

```python
# Copy each field explicitly so it is clear what gets stored.
# Python shortcut (copies every field automatically, less to maintain):
#     customer = Customer(**payload.model_dump())
customer = Customer(
    first_name=payload.first_name,
    last_name=payload.last_name,
    email=payload.email,
    phone=payload.phone,
)
```

**Every explicit copy needs a guard test.** Explicit copying has one risk: a
new field is added to the schema, but someone forgets to copy it, and its value
is silently dropped. Each service has guard tests that:

1. check the test data lists **every** field the schemas accept, so a new
   field fails the test until it is added to the test data, and
2. create and update a record with every field set, and check that every field
   comes back.

For example, tests named `test_guard_data_covers_every_schema_field`,
`test_create_stores_every_field` and `test_update_stores_every_field`.

**Re-raising errors.** Inside an `except` block, raise the new error
`from error`. This records the original error as the cause, which shows up in
logs. The linter enforces it (ruff rule B904). Add a short comment the first
time it appears in a file.

## 7. Comments and docstrings

- **Every module** starts with a docstring saying what the file is for.
- **Every class and function** has a docstring: one line saying what it does,
  plus more lines only if the "why" is not obvious.
- **Inline comments explain why**, or flag something surprising. Do not
  restate the code:

  ```python
  # Avoid
  session.refresh(customer)  # refresh the customer

  # Prefer
  # Reload so values set by the database (id, created_at, updated_at) are filled in.
  session.refresh(customer)
  ```

## 8. Tests

- **One behaviour per test.** The name says the behaviour:
  `test_update_to_duplicate_email_returns_409`.
- **Every test has a docstring** stating the behaviour in plain English.
- **Arrange / Act / Assert.** Separate the setup, the call being tested and
  the checks with blank lines. Add `# Arrange`, `# Act` and `# Assert` labels
  when a test is longer than about six lines.
- **Named test data:** module-level constants such as `ADA` and `GRACE`. Make
  variations with a helper such as `with_changes(ADA, {"email": "..."})`,
  not with dict unpacking.
- **Setup helpers check their own success.** For example, `create_customer`
  asserts the response was 201. A broken setup step then fails clearly instead
  of being mistaken for the behaviour under test.
- **One step per line**, here too: `grace = create_customer(client, GRACE)`
  and then `grace["id"]`, not `create(...).json()["id"]`.

## 9. Glossary of framework constructs

**Decorator (`@something` above a function).** Wraps or registers the
function below it. In this codebase decorators only register things:
`@router.get("/{customer_id}")` means "call this function for GET requests to
this path". Docs: <https://fastapi.tiangolo.com/tutorial/first-steps/>

**`Depends(get_db)`.** FastAPI's dependency injection. Before calling the
endpoint, FastAPI calls `get_db()` and passes the result in as that parameter.
In tests, `app.dependency_overrides` swaps `get_db` for a test version.
Docs: <https://fastapi.tiangolo.com/tutorial/dependencies/>

**`yield` in `get_db`, `lifespan` and fixtures.** Splits a function into
"before" and "after". Code before `yield` runs first, the yielded value is
handed over (to the endpoint or to the test), and code after `yield`, or in a
`finally` block, runs once the endpoint or test has finished. It works like
try-with-resources in Java or `using` in C#.

**`Mapped[str | None]` and `mapped_column(...)`.** SQLAlchemy's way of
declaring a table column. `Mapped[...]` gives the Python type
(`str | None` means the column may be empty, NULL) and `mapped_column(...)`
gives the storage details (length, unique, index).
Docs: <https://docs.sqlalchemy.org/en/20/orm/quickstart.html>

**`BaseModel`, `Field(...)`, `model_config`.** Pydantic models describe the
JSON an endpoint accepts or returns. FastAPI validates incoming JSON against
them and returns 422 if it does not fit. `Field(...)` adds rules such as
`max_length`. `model_config = ConfigDict(from_attributes=True)` lets a schema
be built from a database object rather than only from a dictionary.
Docs: <https://docs.pydantic.dev/latest/concepts/models/>

**`async def`.** Marks a function as asynchronous. FastAPI requires the
`lifespan` start-up function to be async. Endpoints in this codebase are plain
`def`, and FastAPI runs them on a thread pool.

**pytest fixtures (`@pytest.fixture`, `conftest.py`).** pytest loads
`conftest.py` automatically. A test that has a parameter with the same name as
a fixture (for example `client`) receives what the fixture yields.
Docs: <https://docs.pytest.org/en/stable/how-to/fixtures.html>

## 10. How this is enforced

- `AGENTS.md` requires every change to follow this file, and lists it in the
  definition of done.
- Reviewers check it on every PR.
- The repo's lint command (e.g. `ruff`) catches formatting and some error-prone patterns.
  Ruff is not yet configured to check the rules in this file automatically.
- Deliberate exceptions are allowed, but they must be marked and explained
  (see section 11).
## 11. Exceptions

These rules serve readability. They are not an end in themselves. If following
a rule would clearly make a particular piece of code worse (harder to read,
slower, or less correct), do not follow it. Instead:

1. Mark the spot with a comment that starts with `Style exception:`, names the
   rule and says why it was broken:

   ```python
   # Style exception: section 4 (comprehension with a condition). A loop here
   # would need three extra lines and a temporary list for no gain in clarity.
   active_emails = [customer.email for customer in customers if customer.is_active]
   ```

2. List every style exception under "Open questions" in the PR, so the reviewer
   can agree or push back.

"I prefer it" or "it's shorter" is not a reason. Exceptions should be rare. If
the same exception keeps coming up, propose changing the rule in this file
instead.
