# Troubleshooting

## OpenClaw says "I don't see the Harper skill"

The skill must be in one of OpenClaw's skill-loading locations:
- `<workspace>/skills/harper-pipeline-builder/`
- `<workspace>/.agents/skills/harper-pipeline-builder/`
- `~/.agents/skills/harper-pipeline-builder/`
- `~/.openclaw/skills/harper-pipeline-builder/`

And the top of `SKILL.md` must have the frontmatter (the `---` block with `name:` and `description:`). Without frontmatter, OpenClaw won't load it.

## `npm install` takes forever / hangs on "installing NATS server"

The `harperdb` npm package has a postinstall script that downloads and extracts a NATS server binary — needed if you're running Harper locally, **not** needed when you're just using the CLI to deploy to a remote Fabric cluster. Two fixes:

1. **Use `--ignore-scripts`** when installing deploy tooling: `npm install --ignore-scripts`. `bootstrap.sh` already does this.
2. **Only declare `harperdb` once, at the repo root.** Do NOT add it to individual component `package.json`s. The skill is set up so components inherit the CLI via Node's module resolution walk-up. If you see `harperdb` in a component's `devDependencies`, remove it.

If your install is slow anyway, check your network — the repo-root install is ~250MB on disk and ~611 packages, mostly because `harperdb` has a wide dependency footprint.

## Deploy says "Successfully deployed" but nothing shows up on Fabric

**This is the #1 silent failure, and the root cause is almost always the same:** `CLI_TARGET` and `CLI_APP_URL` are set to the same URL, or only one is set, or they don't belong to the same Fabric cluster.

On Fabric, two URLs do different jobs:

- **`CLI_TARGET`** — the **Operations API URL**, used by the `harperdb` CLI for `deploy_component`, `describe_all`, etc. Typically a region-specific host on port `:9925`, e.g. `https://us-west1-a-1.foo.cluster.harper.fast:9925`.
- **`CLI_APP_URL`** — the **Application URL**, used by every REST probe (`GET /Pipeline/`, `GET /<Table>/`, `GET /<PipelineId>Run`). Typically the short cluster hostname, no explicit port, e.g. `https://foo.cluster.harper.fast`.

They are different host:port pairs. Both are listed in the Fabric Config tab for the cluster. If you only copy one and use it for both variables, the CLI either (a) accepts the `deploy_component` call and the agent then 404s on `/Pipeline/`, or (b) 404s on `describe_all` during pre-flight. Either way, nothing useful happens.

**Fix:**

1. Open the cluster in the Fabric UI → Config tab.
2. Copy the Operations API URL (with port) into `CLI_TARGET`.
3. Copy the Application URL into `CLI_APP_URL`.
4. Delete any component-local `.env` that might be shadowing the global secrets file: `rm <component>/.env && cp ~/.openclaw/secrets/harper.env <component>/.env`.
5. Re-run `bootstrap.sh` if `harper-base` wasn't verified on this cluster.

Other historical causes of the same symptom, now rarer because the split catches them:

- **Local `.env` overriding the global secrets file** with an `http://localhost:9925` target — agent deployed to a local Harper instance instead of Fabric.
- **Wrong protocol** — `CLI_TARGET=http://...` appears to connect but won't match auth.
- **Stale URL** — Fabric can rotate Ops API hostnames when clusters are rebuilt; copying an old URL from chat history won't work. Always re-open the Config tab.

The pre-flight checks in `rules/04-deploy.md` catch all of these. Skipping them is what produces this failure mode.

## Deploy succeeds but verify fails with 404 on `/Pipeline/`

Sibling of the above, diagnosed more precisely. `harperdb deploy_component` printed `Successfully deployed`, cluster logs confirm the component landed, but `scripts/verify.mjs` retries five times and still gets 404.

This means the component deployed correctly but `CLI_APP_URL` is wrong. The tables *are* on Fabric — verify is looking in the wrong place.

**How to confirm:** the Fabric Config tab lists both URLs. curl the Application URL (no port) vs. the Ops API URL (with `:9925`). Whichever returns `200 []` for `GET /Pipeline/` is your `CLI_APP_URL`.

**Fix:** put the right value in `CLI_APP_URL` and re-run `npm run deploy:verify` (no re-deploy needed).

## Deploy fails with `ECONNREFUSED`

`CLI_TARGET` is unreachable. Re-run the pre-flight checks:

1. `source .env && echo "$CLI_TARGET"` — confirm you're pointing at the right URL (not `localhost`, not empty).
2. `curl -I "$CLI_TARGET"` — should return an HTTP status, not hang.
3. If `CLI_TARGET` is the cluster's Application URL and still refuses, the cluster may be paused — check the Fabric UI.

## Resource method returns 200 but stored record is empty

Symptom: `POST /FlagHumanAction` (or `POST /PipelineRegister`, etc.) returns HTTP 200 with a plausible response body like `{"ok": true, "id": "..."}`, but when you `GET /PendingHumanAction/<id>` the row exists with all fields blank. `bootstrap.sh` Step 7 is the one that catches this; if you're hitting it in production, the same root cause applies.

Two distinct defect classes cause this, and they look identical from the HTTP layer:

**1. POST handler declared as `post(target, data)` instead of `post(data)`.** For bare `POST /ResourceName` requests, Harper passes the request body as the **single positional argument** to your instance `post()`. If you declare two args — a common mistake because `node_modules/harperdb/resources/Resource.d.ts` line 104 shows a two-arg signature — then `target` receives the body and `data` is `undefined`. Your handler writes `{id: data?.id, sourceName: data?.sourceName, ...}` which becomes `{id: undefined, sourceName: undefined, ...}`. The row gets created (because `crypto.randomUUID()` fallbacks provide *something*), but with empty fields.

**Fix:** single-arg only. Match Harper's own `node_modules/harperdb/application-template/resources.js`:
```js
export class FlagHumanAction extends Resource {
    async post(data) {  // single argument. NOT (target, data).
        await tables.PendingHumanAction.put(id, record);
    }
}
```

**2. Schema uses `@table(table: "snake_case_name")` override.** Harper's `tables` global keys by the **underlying table name** from the override, not the GraphQL type name. So `tables.PendingHumanAction` is `undefined` while `tables.pending_human_action` works. The REST router is unaffected (it uses the type name), which is why `GET /PendingHumanAction/` returns 200 — but your Resource method code references the wrong key and `tables.PendingHumanAction.put(...)` throws `Cannot read properties of undefined`. The request fails *inside* your handler, but the error often isn't surfaced cleanly.

**Fix:** drop the `@table(table:)` override. Let the GraphQL type name be the table name.
```graphql
# Wrong:
type PendingHumanAction @table(table: "pending_human_action") @export { ... }
# Right:
type PendingHumanAction @table @export { ... }
```

**How to confirm which one you're hitting:** `POST` a payload with a recognizable marker field (e.g. `{"businessObjective":"test-$(uuidgen)"}`), `GET` the row back, check:
- If `businessObjective` is empty and `id` is present → **defect 1** (two-arg signature dropped the body).
- If POST itself returns 500 with "Cannot read properties of undefined" → **defect 2** (schema override mismatch).

**Meta-rule:** when writing new Resource classes, start from `npm create harper@latest` and follow `harper-best-practices/rules/custom-resources.md`. These patterns are canonical and both defects above exist solely because we deviated from them.

## Deploy fails with `Cannot find module 'harperdb'`

Your scaffolded `package.json` is missing the `harperdb` devDependency. Harper runs `npm install` in the component directory after deploy, so the dependency must be declared. Compare against `templates/pipeline-component/package.json`.

## Pipeline deploys but no data lands

Check in this order:

1. `GET /<PIPELINE_ID_PASCAL>Run` — does it return a registry row? If not, the pipeline hasn't completed even one run.
2. `POST /<PIPELINE_ID_PASCAL>Run` with `{}` — does it return `{"status":"ok", "records":N}`? If not, `fetchFromSource` is failing. Look at cluster logs.
3. If `records > 0` but `/<TARGET_TABLE>/` is empty — the `PRIMARY_KEY_FIELD` values in your returned records are `undefined`. The template silently skips records with no primary key. Either fix the source mapping or synthesize a key.

## "I got the API key" flow

When a human unblocks a `pending_human_action`:

1. Drop the key into `~/.openclaw/secrets/<source>.env` (e.g. `SAM_GOV_API_KEY=xxx`).
2. Ensure the Harper cluster has the same env var set (via Fabric's environment config, or by adding it to the component's deploy).
3. Ask OpenClaw to "retry <pipeline_id>" — it will find the `pending_human_action` row, mark it `resolved`, and re-run the skill from step 3 for that source.

## Multiple clusters, multiple OpenClaw instances

Each OpenClaw workspace points at one Harper cluster (via `CLI_TARGET`). If you need one agent managing multiple clusters, run a separate OpenClaw workspace per cluster — easier than parameterizing the skill.

## "The agent keeps hallucinating source URLs"

Usually the fix is in Step 1 of the skill: make sure the agent is actually hitting candidate URLs before emitting a `SourceCandidate`, not just generating plausible-looking endpoints. The `sampleResponse.httpStatus` field in the schema is there specifically to force this — if the agent is producing `SourceCandidate`s with no `sampleResponse`, it's cheating.

## "`pending_human_action` is piling up"

Feature, not bug. Healthy clusters will have a queue of blocked sources. The queue becoming long just means the agent is being honest about what it can't do. Triage it on a cadence — daily for a POC, weekly for a mature cluster.

## Deploy fails with `HarperDB config file validation error: Specified path database does not exist`

Symptom: `harperdb deploy_component` fails with an error about a missing database path.

Root cause: a stale `~/.harperdb/hdb_boot_properties.file` left over from a previous local Harper installation (or v5 experiment), pointing at a non-existent local database directory.

**Fix:**

```bash
mv ~/.harperdb/hdb_boot_properties.file ~/.harperdb/hdb_boot_properties.file.bak
# Then retry:
harperdb deploy_component
```

If the boot file comes back, the conflict is persistent — add a preflight check to `bootstrap.sh` to detect and warn about it early. The file should only exist if you're running Harper locally; it's harmless to move it aside for remote Fabric deployments.
