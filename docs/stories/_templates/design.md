# Design: <KEY> <summary>

## 1. Analysis
What the story asks for, in two or three sentences. What it does not ask for.

## 2. Impact
| Component | Files | Change |
|-----------|-------|--------|

## 3. Contract
What the tester and implementer both build against. Include whichever apply:
- API: for each new or changed endpoint, method, path, request fields
  (type, required, constraints), response fields, and every status code.
- Database: tables, columns, types, keys, constraints, indexes.
- Files: format, naming, fields.
- Infrastructure: resources, inputs, outputs, and how they are torn down.

## 4. Data model
Model and schema changes. Effect on existing data.

## 5. Risks
What could break, and how the tests will catch it.

## 6. Open questions
| # | Question | Recommended assumption |
|---|----------|------------------------|

<!-- Optional sections: include only when the story needs them -->
## 7. Sequence diagram (multi-component stories)
## 8. Decision record (when choosing between real alternatives)
Context, options considered, decision, consequences.
