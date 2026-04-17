# Step 3: Scaffold the pipeline component

**Goal:** copy `templates/pipeline-component/` into a fresh working directory and render every `{{PLACEHOLDER}}`.

Before writing any Resource class, read the canonical patterns in skills/harper-best-practices/rules/custom-resources.md and extending-tables.md. Those files ship from npm create harper@latest and describe Harper's official patterns. Deviations are almost always bugs; the quickstart has burned three release cuts chasing defects that harper-best-practices documents correctly.

## Working directory

Scaffold under your OpenClaw workspace:

```
<workspace>/harper-pipelines/<PIPELINE_ID>/
```

Never scaffold over an existing directory without confirming with the user. If `<PIPELINE_ID>` already exists, either pick a new id (e.g. `-v2` suffix) or ask.

## Placeholders — complete list

| Placeholder | Rules |
|---|---|
| `PIPELINE_ID` | kebab-case, `[a-z0-9-]+`, ≤ 40 chars, globally unique in the cluster. Try `${SOURCE_SLUG}` first; add suffix if taken. |
| `PIPELINE_ID_PASCAL` | PascalCase version of `PIPELINE_ID`. |
| `TARGET_TABLE` | PascalCase, singular, matches the entity being ingested (e.g. `ContractorRegistration`). |
| `TARGET_TABLE_FIELDS` | GraphQL fields, tab-indented, one per line. Must include a `@primaryKey` field. |
| `PRIMARY_KEY_FIELD` | name of the `@primaryKey` field above. Must be stable across runs. |
| `SOURCE_NAME` | human label; used in registry + UI. |
| `SOURCE_URL` | base URL of the upstream API. |
| `SCHEDULE_CRON` | standard 5-field cron. Default `*/15 * * * *`. Never less than 1 minute; respect upstream rate limits. |
| `BUSINESS_OBJECTIVE` | the user's original prompt, short. |
| `FETCH_FN_BODY` | a JavaScript snippet. See below. |

## Writing `FETCH_FN_BODY`

This is the only per-source code. Rules:

1. Must return `Promise<Array<Record>>`. An array of plain objects.
2. Must throw on HTTP error (don't swallow).
3. Must be self-contained — use `fetch` (Node 20+ native). No outside imports.
4. If the source supports incremental pulls (`?since=` or similar), use it. Compute the `since` value from `Date.now()` and the schedule cron, with a comfortable overlap (2×) to absorb late-arriving data. Dedupe is handled by the template's `put` upsert.
5. Handle pagination with a loop, capped at some sane max (default 50 pages). If you hit the cap, log and stop — better to take multiple runs than to OOM.
6. If the source requires an API key, read it from `process.env.<SOURCE>_API_KEY`. Do not embed secrets in the file.
7. Normalize field names into the schema you defined. Don't emit fields not in the schema.

## Validation before moving on

Before you call deploy, run five sanity checks:

1. **Dry-run the fetch function**: extract `FETCH_FN_BODY` into a standalone `fetch-test.js` in your scratch dir, run it with `node`, confirm it returns an array with >0 records and a valid `PRIMARY_KEY_FIELD` on each.
2. **Lint the rendered resources.js**: `node --check resources.js` should pass. If it fails, you have a template-render bug — fix before deploying.
3. **No imports of `Resource` or `tables`**: grep the rendered `resources.js` for `from 'harperdb'` and `from '@harperfast/harper'`. Both should return zero matches. `Resource` and `tables` are runtime-injected globals; the module-time imports return empty bindings and will 500 inside Resource method handlers (e.g. `tables.X is undefined`) even though deploy itself reports success and REST CRUD on the tables works. The only legitimate import is `cron-parser`. This is the single most common post-deploy footgun; if you skip this check, the pipeline endpoint will deploy green and then 500 on first run.

   Also: if the schema uses `@table(table: "…")` to override the underlying table name, the `tables` global keys by the **override value**, not the GraphQL type name. REST routes use the type name (`/Pipeline/`), but in-code access goes `tables['pipelines']`. Mismatching these two is the #2 post-deploy footgun — it manifests as `"Cannot read properties of undefined (reading 'put')"` on the first POST into a Resource method, even though deploy + GET all succeed. For scaffolded pipelines this doesn't apply because the template schema doesn't use `@table(table:)`. The `harper-base` schema does, so the runtime code in `harper-base/resources.js` uses `tables.pipelines` and `tables.pending_human_action`.
4. **Confirm `package.json` is lean**: the scaffolded `package.json` must contain only runtime deps (usually just `cron-parser`) plus a `files` allowlist. Do NOT add `harperdb`, `@harperfast/harper`, or `dotenv-cli` — they live at the workspace root and resolve via npm's bin walk-up. A pipeline component with the harper package in its `devDependencies` is a scaffolding bug; fix it before deploying.
5. **Resource POST handlers use single-arg signature**: `async post(data) { ... }`, NOT `async post(target, data)` or `async post(_target, data)`. Harper dispatches HTTP POSTs to bare resources (e.g. POST /PipelineRegister) by passing the JSON body as the single positional argument. The TypeScript declaration in node_modules/harperdb/resources/Resource.d.ts shows a two-arg form that is misleading for this use case; trust Harper's own application-template/resources.js which shows `post(content) { return super.post(content); }`. Scaffolded pipelines don't need body access in their Run endpoints (they just trigger `runPipeline()`), so zero-arg `async post() {}` is fine there.

Only after all five pass, move to step 4.

## Example: USGS earthquakes, fully rendered

See `examples/usgs-earthquakes/` in this repo for the exact file output of a correct scaffold. Use it as a reference when rendering your own.
