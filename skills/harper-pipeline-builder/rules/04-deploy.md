# Step 4: Deploy

**Goal:** get the scaffolded component running on the target Harper Fabric cluster.

## The deploy path

There is exactly one supported deploy path for this skill: **Harper CLI, driven by `npm run deploy` inside the component directory.** It matches Harper's canonical docs and doesn't require a git remote. If you find yourself reaching for a git URL, a `curl` to the Operations API, or anything else, stop — you're off the golden path.

Appendix A at the bottom covers the Operations-API + git-URL path for CI/CD only. Don't use it interactively.

## Pre-flight: prove the target is actually Fabric

**This step has broken every previous agent run. Do not skip it.**

Before you touch `npm run deploy`, verify four things in this order:

### 1. Credentials loaded, not inherited

```bash
cd <workspace>/harper-pipelines/<PIPELINE_ID>/
test -f .env || cp ~/.openclaw/secrets/harper.env .env
grep -E '^CLI_TARGET(_USERNAME|_PASSWORD)?=' .env
```

You must see exactly three lines — `CLI_TARGET`, `CLI_TARGET_USERNAME`, `CLI_TARGET_PASSWORD` — and none of them pointing at `localhost`, `127.0.0.1`, or `http://` (Fabric is always `https://`). A local `.env` silently overriding the global secrets file is the #1 cause of "the deploy said success but nothing's on the cluster."

### 2. Target is reachable and authenticated

```bash
source .env
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     -H 'Content-Type: application/json' \
     -d '{"operation":"describe_all"}' \
     "$CLI_TARGET" | head -c 200
```

Expected: a JSON object listing existing components/databases. If you get:

- `connection refused` → `CLI_TARGET` is missing the port or pointing at a dead host. Fabric clusters expose the Operations API on their Application URL — confirm with the user which URL to use.
- `401` → creds are wrong. Stop.
- HTML → you're hitting a web UI, not the Operations API. Wrong URL. Stop.
- `{}` or a short object → you're on Fabric and authenticated. Proceed.

### 3. `harper-base` is already deployed

```bash
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" "$CLI_TARGET/Pipeline/" | head -c 200
```

Expected: `[]` or a JSON array. If you get 404, `harper-base` hasn't been deployed to this cluster. Stop and tell the user — your pipeline has nowhere to register.

### 4. No in-flight deploy already running

Running two `deploy_component` calls against the same cluster at the same time is a known source of silent failure. If the user is running anything else against this cluster, wait.

Only after all four pre-flight checks pass, proceed to deploy.

## Deploy

```bash
cd <workspace>/harper-pipelines/<PIPELINE_ID>/
npm install
npm run deploy
```

`npm run deploy` runs `dotenv -- harperdb deploy_component . restart=rolling replicated=true` under the hood. That:

- Loads `.env` into the shell
- Authenticates to `$CLI_TARGET` as `$CLI_TARGET_USERNAME`
- Tars up the current directory
- Uploads the tar to the cluster
- Performs a rolling restart with `replicated: true`

Expected terminal output includes a line like:

```
{ message: "Successfully deployed: <PIPELINE_ID>" }
```

That message means **"Fabric accepted the upload"** — not "the pipeline is running." You confirm the latter in the post-deploy check below and in step 5.

## Post-deploy verification (mandatory)

**Do not move to step 5 until all three of these pass.** These are the checks that catch "CLI reported success but nothing landed on Fabric," which has been a repeated failure mode.

### A. The component's run endpoint exists

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
     -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     "$CLI_TARGET/<PIPELINE_ID_PASCAL>Run"
```

Expected: `200` or `405` (GET not allowed but endpoint exists). If you get `404`, the component did not land on Fabric — your deploy went somewhere else. Re-run the pre-flight (the usual culprit is a stale `.env` pointing at local Harper).

### B. The target table's REST endpoint exists

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
     -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     "$CLI_TARGET/<TARGET_TABLE>/"
```

Expected: `200` with body `[]`. A `404` means the schema didn't register — most commonly because `schema.graphql` has a syntax error that Fabric silently dropped. Check the component's logs via the `read_log` operation.

### C. Fabric knows about the component

```bash
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     -H 'Content-Type: application/json' \
     -d '{"operation":"get_components"}' \
     "$CLI_TARGET" | grep -q '<PIPELINE_ID>' \
     && echo "OK: component registered" \
     || echo "FAIL: component not in Fabric's component list"
```

All three must pass. If any fail, the pipeline is not deployed. Fix before moving on.

## If the deploy fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `ECONNREFUSED` | `CLI_TARGET` port missing or wrong protocol | Re-run pre-flight step 2; confirm Application URL with user |
| `401 Unauthorized` | wrong creds, or `CLI_TARGET_USERNAME` has trailing whitespace | `cat -A .env` and check |
| "Successfully deployed" but post-deploy check A returns 404 | deployed to wrong target (local Harper shadowed Fabric) | Re-run pre-flight step 1; delete any stale `.env`; re-deploy |
| `SyntaxError` in `resources.js` during deploy | template not fully rendered | Re-run step 3 validation; `node --check resources.js` must pass |
| `Cannot find module 'cron-parser'` in cluster logs | dependency missing from `package.json` | Check `package.json` against `templates/pipeline-component/package.json` |
| `403` from `deploy_component` | creds aren't `super_user` | Cluster owner grants super_user to the agent's creds |
| Deploy hangs > 2 minutes | rolling restart stuck | Check `read_log`; if a prior deploy is in flight, wait |

**Never retry a failed deploy more than twice.** On the third failure, file a `pending_human_action` with `blocker: "other"` and the full error message, plus the output of pre-flight steps 1 and 2.

---

## Appendix A — CI/CD deploy path (Operations API + git URL)

For automated deploys from GitHub Actions or similar, use the Operations API directly rather than the CLI. This is documented here for completeness but **should not be used for interactive agent runs** — it introduces a git-remote dependency that's the wrong shape for ephemeral pipeline scaffolds.

```bash
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     -H 'Content-Type: application/json' \
     -d '{
           "operation": "deploy_component",
           "project": "<PIPELINE_ID>",
           "package": "<org>/<repo>#semver:v0.1.0",
           "restart": "rolling",
           "replicated": true
         }' \
     "$CLI_TARGET"
```

The cluster pulls the git URL, runs `npm install`, and rolls the component out. The same post-deploy verification checks above still apply.

## Appendix B — `restart: rolling` in production

For iterative agent work, `restart: "rolling"` is fine. For high-volume clusters where many pipelines are running concurrently, a rolling restart briefly interrupts all of them. The cluster owner should set up a dedicated "pipeline worker" node pool and target it specifically.
