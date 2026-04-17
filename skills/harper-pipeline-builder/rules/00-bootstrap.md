# Step 0: Bootstrap — before you build any pipeline

**Goal:** ensure the cluster is reachable, `harper-base` is deployed, and your workspace has everything the pipeline-builder needs. Run once per workspace.

This step is required the first time the skill runs in a given OpenClaw workspace, and any time the user says "I set up a new cluster." If everything is already in place, this step is a no-op (it re-verifies and moves on).

## Preferred path: run `bootstrap.sh`

If the user has cloned `harper-openclaw-quickstart` locally, run:

```bash
cd <path-to>/harper-openclaw-quickstart
./bootstrap.sh
```

The script gathers creds, writes `~/.openclaw/secrets/harper.env`, deploys `harper-base`, verifies the deploy actually landed on Fabric, and installs the skill. It's idempotent — safe to re-run.

If the script exits successfully, skip to step 1.

If the script fails, read its error message verbatim. **Do not guess a workaround.** The error tells you exactly what's wrong; fix that specific thing and re-run.

## Manual path: when you can't run the script

Do these five sub-steps in order. Stop at the first failure.

### 0.1 Gather credentials

If `~/.openclaw/secrets/harper.env` does not exist, ask the user for three values:

- `CLI_TARGET` — the Harper Fabric Application URL (starts with `https://`, never `localhost`)
- `CLI_TARGET_USERNAME` — cluster super_user username
- `CLI_TARGET_PASSWORD` — cluster super_user password

Do not invent these. Do not assume defaults. If the user hasn't created a Fabric cluster yet, point them at `https://fabric.harper.fast` and wait.

### 0.2 Write the secrets file

```bash
mkdir -p ~/.openclaw/secrets
chmod 700 ~/.openclaw/secrets
cat > ~/.openclaw/secrets/harper.env <<EOF
CLI_TARGET=<value>
CLI_TARGET_USERNAME=<value>
CLI_TARGET_PASSWORD=<value>
EOF
chmod 600 ~/.openclaw/secrets/harper.env
```

### 0.3 Pre-flight: cluster reachable + authenticated

```bash
source ~/.openclaw/secrets/harper.env
curl -sS --max-time 15 \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"operation":"describe_all"}' \
  "$CLI_TARGET" | head -c 400
```

Expected: a JSON object. If you see HTML, 401, or a connection error, stop — the creds or URL are wrong. See `docs/troubleshooting.md`.

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
    "$CLI_TARGET/${tbl}/")
  echo "$tbl: HTTP $code"
done
```

Both must be `200`. If either is `404`, the deploy did not actually land on Fabric — usually because of a wrong `CLI_TARGET` or a local `.env` shadowing the secrets file. Do not proceed; fix the deploy and re-verify.

Fabric sometimes needs a few seconds after a successful deploy before endpoints are live. Retry up to 5 times, 5 seconds apart, before declaring failure.

## When to re-run bootstrap

- User switched to a new Fabric cluster
- User rotated cluster creds
- `harper-base` was accidentally removed (`Pipeline` table returns 404 during a pipeline run)
- You see `pending_human_action` reference errors in a pipeline's post-deploy verification

In all other cases, bootstrap is a one-time setup — don't re-run it on every pipeline build.
