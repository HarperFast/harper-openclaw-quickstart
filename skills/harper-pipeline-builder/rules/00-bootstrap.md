# Step 0: Bootstrap — before you build any pipeline

**Goal:** ensure the cluster is reachable, `harper-base` is deployed, and your workspace has everything the pipeline-builder needs. Run once per workspace.

This step is required the first time the skill runs in a given OpenClaw workspace, and any time the user says "I set up a new cluster." If everything is already in place, this step is a no-op (it re-verifies and moves on).

## Preferred path: run `bootstrap.sh`

If the user has cloned `harper-openclaw-quickstart` locally, run:

```bash
cd <path-to>/harper-openclaw-quickstart
./bootstrap.sh
```

The script gathers creds, writes `~/.openclaw/secrets/harper.env`, deploys `harper-base`, verifies the deploy actually landed on Fabric, and installs two skills into `~/.openclaw/skills/`: `harper-pipeline-builder` (this skill) and `harper-best-practices` (Harper's canonical guidance for schemas, Resource classes, and Fabric deploy — fetched via `npm create harper@latest` so it stays current). It's idempotent — safe to re-run. To force a refresh of the best-practices skill, set `FORCE_REINSTALL_SKILLS=1`.

If the script exits successfully, skip to step 1.

If the script fails, read its error message verbatim. **Do not guess a workaround.** The error tells you exactly what's wrong; fix that specific thing and re-run.

## Manual path: when you can't run the script

Do these five sub-steps in order. Stop at the first failure.

### 0.1 Gather credentials

If `~/.openclaw/secrets/harper.env` does not exist, ask the user for four values. **Both URLs come from the Fabric Config tab for the target cluster — they are usually different host:port pairs and both matter.**

- `CLI_TARGET` — Harper **Operations API URL** (used by the `harperdb` CLI for `deploy_component`, `describe_all`, etc.). On Fabric this is typically a region-specific host on port `:9925`. Example: `https://us-west1-a-1.foo.cluster.harper.fast:9925`
- `CLI_APP_URL` — Harper **Application URL** (used for REST endpoints: `GET /Pipeline/`, `GET /<Table>/`, `GET /<PipelineId>Run`). Typically the short cluster hostname, no explicit port. Example: `https://foo.cluster.harper.fast`
- `CLI_TARGET_USERNAME` — cluster super_user username (same creds authenticate both URLs)
- `CLI_TARGET_PASSWORD` — cluster super_user password

Do not invent these. Do not assume defaults. If the user gives you only one URL, ask them for the other — setting both to the same value is the known root cause of "deploy said success but nothing on Fabric" incidents going back months.

### 0.2 Write the secrets file

```bash
mkdir -p ~/.openclaw/secrets
chmod 700 ~/.openclaw/secrets
cat > ~/.openclaw/secrets/harper.env <<EOF
CLI_TARGET=<ops-api-url>
CLI_APP_URL=<application-url>
CLI_TARGET_USERNAME=<value>
CLI_TARGET_PASSWORD=<value>
EOF
chmod 600 ~/.openclaw/secrets/harper.env
```

### 0.3 Pre-flight: both URLs reachable

```bash
source ~/.openclaw/secrets/harper.env

# Ops API — must return JSON (not "Not found", not HTML)
curl -sS --max-time 15 \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"operation":"describe_all"}' \
  "$CLI_TARGET" | python3 -m json.tool | head -c 400

# Application URL — should respond (expect 200/404, NOT connection refused)
curl -sS -o /dev/null -w 'CLI_APP_URL: HTTP %{http_code}\n' \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  "$CLI_APP_URL/"
```

Expected: the first command prints a valid JSON object. If it errors with `Expecting value` or prints `Not found`, `CLI_TARGET` is pointed at the wrong URL — most likely the Application URL instead of the Ops API. The second command prints any HTTP code that isn't `000` — if it's `000`, `CLI_APP_URL` is unreachable.

If you see HTML, 401, or a connection error on either, stop — the creds or URLs are wrong. See `docs/troubleshooting.md`.

### 0.4 Install deploy tooling at repo root, then deploy `harper-base`

The Harper CLI (`harperdb`) and `dotenv-cli` live **once** at the repo root, not per component. This keeps component tarballs small and avoids a cluster-side install of the Harper CLI itself (which is what was taking "forever" in early test runs).

```bash
cd <path-to>/harper-openclaw-quickstart
npm install --no-audit --no-fund --ignore-scripts   # skip harperdb's NATS postinstall

cd harper-base
cp ~/.openclaw/secrets/harper.env .env
npm run deploy                                       # resolves harperdb + dotenv from parent node_modules
```

The `--ignore-scripts` flag matters: installing `harperdb` normally triggers a postinstall that downloads a NATS server binary we don't need for CLI-only use. Skipping it cuts install from minutes-plus to seconds.

There is **no** `npm install` inside `harper-base`. It has zero runtime dependencies.

### 0.5 Verify `harper-base` landed on Fabric

```bash
for tbl in Pipeline PendingHumanAction; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
    "$CLI_APP_URL/${tbl}/")
  echo "$tbl: HTTP $code"
done
```

Both must be `200`. If either is `404`, one of two things is wrong: (a) the deploy landed on a different cluster than `CLI_APP_URL` points at — check that `CLI_TARGET` and `CLI_APP_URL` came from the same Fabric Config tab; (b) a local `.env` shadowed the secrets file and deployed to the wrong target. Do not proceed; fix and re-verify.

Fabric sometimes needs a few seconds after a successful deploy before endpoints are live. Retry up to 5 times, 5 seconds apart, before declaring failure.

### 0.6 Round-trip a Resource method — body preservation check

**Do not skip this.** `GET /Table/` returning 200 is not proof the pipeline will work. Three separate defect classes (tables.* undefined, schema-name-override mismatch, two-arg Resource.post signature) have shipped past this check historically. The round-trip catches all three.

```bash
marker="probe-$(uuidgen | tr '[:upper:]' '[:lower:]')"
payload=$(cat <<EOF
{"sourceName":"bootstrap-probe","sourceUrl":"https://example.invalid","businessObjective":"$marker","blocker":"other","blockerDetail":"bootstrap round-trip","suggestedNextStep":"none","createdByAgent":"manual-bootstrap"}
EOF
)

# POST — must return 200 with {"id": "..."}
post_resp=$(curl -sS -w '\n%{http_code}' \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X POST -d "$payload" \
  "$CLI_APP_URL/FlagHumanAction")
echo "$post_resp"

# Extract id, then GET the row back
id=$(printf '%s' "$post_resp" | head -n1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("id",""))')
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  "$CLI_APP_URL/PendingHumanAction/$id" | python3 -m json.tool
```

The row returned by `GET /PendingHumanAction/$id` must contain `"businessObjective": "$marker"` with the exact marker you sent. If the field is empty or the row has no body fields at all, one of the two defects in `docs/troubleshooting.md` → "Resource method returns 200 but stored record is empty" applies. Fix harper-base/resources.js or harper-base/schema.graphql before moving on.

Cleanup: mark the probe row resolved so it doesn't pollute the human-review queue:

```bash
curl -sS -o /dev/null \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X PATCH -d '{"status":"resolved","resolvedBy":"manual-bootstrap"}' \
  "$CLI_APP_URL/PendingHumanAction/$id"
```

### 0.7 Install both skills

Install `harper-pipeline-builder` (this skill) and `harper-best-practices` (Harper's canonical guidance) into `~/.openclaw/skills/`. Having **both** is required — the pipeline-builder rules reference patterns in best-practices explicitly, and deviating from those patterns is what produced the v0.1.3/v0.1.4/v0.1.5 defect classes.

```bash
mkdir -p ~/.openclaw/skills

# 1. harper-pipeline-builder (from this repo)
cp -r <path-to>/harper-openclaw-quickstart/skills/harper-pipeline-builder ~/.openclaw/skills/

# 2. harper-best-practices (from npm create harper@latest)
scratch=$(mktemp -d)
(cd "$scratch" && npm create harper@latest -- --yes >/dev/null 2>&1)
hbp_src=$(find "$scratch" -maxdepth 6 -type d -name 'harper-best-practices' -path '*/.agents/skills/*' | head -1)
cp -rL "$hbp_src" ~/.openclaw/skills/
rm -rf "$scratch"
```

Verify both SKILL.md files start with a `---` frontmatter block. Without frontmatter, agents won't load the skill.

## When to re-run bootstrap

- User switched to a new Fabric cluster
- User rotated cluster creds
- `harper-base` was accidentally removed (`Pipeline` table returns 404 during a pipeline run)
- You see `pending_human_action` reference errors in a pipeline's post-deploy verification

In all other cases, bootstrap is a one-time setup — don't re-run it on every pipeline build.
