#!/usr/bin/env bash
# bootstrap.sh — one-command installer for harper-openclaw-quickstart
#
# Idempotent. Safe to re-run. Sequence:
#   1. Gather Harper Fabric creds (interactive; or read from existing env)
#   2. Write ~/.openclaw/secrets/harper.env
#   3. Pre-flight: confirm cluster reachable + authenticated
#   4. Deploy harper-base (registry + escape-hatch tables)
#   5. Post-deploy: confirm Pipeline + PendingHumanAction endpoints exist
#   6. Resource-method round-trip: POST /FlagHumanAction, GET it back, assert
#      body fields were preserved end-to-end. This is the check that catches
#      single-arg-vs-two-arg Resource.post() defects and @table(table:) schema
#      override mismatches — both of which pass "deploy + GET /Table/" but
#      silently drop data on first POST.
#   7. Install harper-pipeline-builder + harper-best-practices skills into
#      ~/.openclaw/skills/  (the latter via `npm create harper@latest` so it's
#      always fresh against Harper's current SDK)
#   8. Print AGENTS.md fragment for the user to paste into their workspace
#
# Designed to be run by humans OR by an agent. If any step fails, it stops with
# a specific error and does not proceed silently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${HOME}/.openclaw/secrets"
SECRETS_FILE="${SECRETS_DIR}/harper.env"
SKILLS_DIR="${HOME}/.openclaw/skills"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Gather creds
# ---------------------------------------------------------------------------
say "Step 1/8: gather Harper Fabric credentials"

if [[ -z "${CLI_TARGET:-}" || -z "${CLI_APP_URL:-}" || -z "${CLI_TARGET_USERNAME:-}" || -z "${CLI_TARGET_PASSWORD:-}" ]]; then
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$SECRETS_FILE"; set +a
    ok "loaded existing $SECRETS_FILE"
  fi
fi

if [[ -z "${CLI_TARGET:-}" ]]; then
  if [[ -t 0 ]]; then
    echo "    CLI_TARGET = Fabric Operations API URL (used by the harperdb CLI to deploy)."
    echo "    On Fabric this is usually a region host on port :9925."
    read -r -p "    CLI_TARGET (e.g. https://us-west1-a-1.foo.cluster.harper.fast:9925): " CLI_TARGET
  else
    die "CLI_TARGET not set and no TTY to prompt. Export it first, or run interactively."
  fi
fi
if [[ -z "${CLI_APP_URL:-}" ]]; then
  if [[ -t 0 ]]; then
    echo "    CLI_APP_URL = Fabric Application URL (used for REST: GET /Pipeline/, GET /<Table>/)."
    echo "    On Fabric this is usually the short cluster hostname, no explicit port."
    read -r -p "    CLI_APP_URL (e.g. https://foo.cluster.harper.fast): " CLI_APP_URL
  else
    die "CLI_APP_URL not set and no TTY to prompt. Export it first, or run interactively."
  fi
fi
if [[ -z "${CLI_TARGET_USERNAME:-}" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "    CLI_TARGET_USERNAME: " CLI_TARGET_USERNAME
  else
    die "CLI_TARGET_USERNAME not set and no TTY to prompt."
  fi
fi
if [[ -z "${CLI_TARGET_PASSWORD:-}" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "    CLI_TARGET_PASSWORD: " CLI_TARGET_PASSWORD
    echo
  else
    die "CLI_TARGET_PASSWORD not set and no TTY to prompt."
  fi
fi

# Sanity — both URLs
for var in CLI_TARGET CLI_APP_URL; do
  val="${!var}"
  [[ "$val" == https://* ]] || die "$var must start with https://. Got: $val"
  [[ "$val" != *localhost* && "$val" != *127.0.0.1* ]] || die "$var points at localhost. Fabric URLs are remote."
done
if [[ "$CLI_TARGET" == "$CLI_APP_URL" ]]; then
  printf '    \033[1;33m⚠\033[0m CLI_TARGET and CLI_APP_URL are identical. On Fabric these are usually different host:port.\n'
  printf '        If verify fails later with 404 on /Pipeline/, this is why — go back to the Fabric Config tab and copy both URLs.\n'
fi
ok "creds present and shaped correctly"

# ---------------------------------------------------------------------------
# 2. Write secrets file
# ---------------------------------------------------------------------------
say "Step 2/8: write $SECRETS_FILE"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
{
  echo "CLI_TARGET=$CLI_TARGET"
  echo "CLI_APP_URL=$CLI_APP_URL"
  echo "CLI_TARGET_USERNAME=$CLI_TARGET_USERNAME"
  echo "CLI_TARGET_PASSWORD=$CLI_TARGET_PASSWORD"
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
ok "wrote $SECRETS_FILE (mode 600)"

# ---------------------------------------------------------------------------
# 3. Pre-flight: reachable + authenticated
# ---------------------------------------------------------------------------
say "Step 3/8: pre-flight — confirm Fabric cluster is reachable + authenticated"

# Probe the Operations API (CLI_TARGET). It must respond to describe_all with
# valid JSON, not a 404 page, HTML login screen, or "Not found" string.
preflight_status="$(curl -sS --max-time 15 \
  -o /tmp/harper-preflight.body \
  -w '%{http_code}' \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"operation":"describe_all"}' \
  "$CLI_TARGET" || echo "000")"
preflight_body="$(cat /tmp/harper-preflight.body 2>/dev/null || true)"
rm -f /tmp/harper-preflight.body

if [[ "$preflight_status" == "000" || -z "$preflight_body" ]]; then
  die "No response from $CLI_TARGET. Check URL (port included? typically :9925) and that the cluster is running."
fi
if [[ "$preflight_status" == "401" ]]; then
  die "Auth failed against $CLI_TARGET (HTTP 401). Check CLI_TARGET_USERNAME / CLI_TARGET_PASSWORD."
fi
# The decisive check: must parse as JSON. This rejects "Not found", HTML error
# pages, and anything else the gateway might emit for a non-Ops URL.
if ! printf '%s' "$preflight_body" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
  printf '    cluster response (HTTP %s, first 200 chars):\n    %s\n' \
    "$preflight_status" "$(printf '%s' "$preflight_body" | head -c 200)"
  die "CLI_TARGET did not return JSON for describe_all. This is not a Harper Operations API endpoint. Confirm CLI_TARGET is the Ops API URL (typically :9925), not the Application URL."
fi
ok "CLI_TARGET reachable + Ops API responding (HTTP $preflight_status)"

# Probe the Application URL too — if it's wrong, verify will fail later
# and it's kinder to catch it now. We accept any 2xx/4xx as "reachable";
# the important thing is the host resolves and responds.
app_status="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  "$CLI_APP_URL/" || echo "000")"
if [[ "$app_status" == "000" ]]; then
  die "CLI_APP_URL is unreachable ($CLI_APP_URL). Confirm this is the Application URL from the Fabric Config tab."
fi
ok "CLI_APP_URL reachable (HTTP $app_status)"

# ---------------------------------------------------------------------------
# 4. Install deploy tooling (once, at repo root) + deploy harper-base
# ---------------------------------------------------------------------------
say "Step 4/8: install deploy tooling at repo root (small, one-time)"

# Tooling (harperdb CLI + dotenv-cli) lives ONCE at the repo root, not per
# component. Components inherit via Node's module resolution walk-up. This
# keeps each component's tar small and keeps cluster-side installs fast.
(
  cd "$SCRIPT_DIR"
  if [[ ! -d node_modules ]]; then
    # --ignore-scripts skips harperdb's postinstall (which tries to download
    # a NATS server binary we don't need for CLI-only use). Cuts install
    # time from minutes-plus to seconds.
    npm install --silent --no-audit --no-fund --ignore-scripts
    ok "repo-root npm install completed"
  else
    ok "node_modules already present at repo root"
  fi
)

say "Step 5/8: deploy harper-base (registry + escape-hatch tables)"

HARPER_BASE_DIR="${SCRIPT_DIR}/harper-base"
[[ -d "$HARPER_BASE_DIR" ]] || die "harper-base directory not found at $HARPER_BASE_DIR"

cp "$SECRETS_FILE" "$HARPER_BASE_DIR/.env"
ok "copied creds into harper-base/.env"

# No npm install in harper-base — harperdb + dotenv-cli resolve from
# the parent node_modules via npm's .bin walk-up. harper-base itself
# has zero runtime dependencies and will NOT ship a node_modules dir
# to Fabric.
(
  cd "$HARPER_BASE_DIR"
  npm run deploy 2>&1 | tail -30
)
ok "harper-base deploy completed (Harper CLI reported success)"

# ---------------------------------------------------------------------------
# 5. Post-deploy verification
# ---------------------------------------------------------------------------
say "Step 6/8: verify harper-base tables are live on Fabric"

check_endpoint() {
  local table="$1"
  local code
  # REST probes go against CLI_APP_URL — the Application URL, NOT the Ops API.
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
    "$CLI_APP_URL/${table}/" || true)"
  if [[ "$code" == "200" ]]; then
    ok "GET $CLI_APP_URL/${table}/ → 200"
    return 0
  fi
  return 1
}

# Fabric sometimes needs a few seconds after deploy before the endpoint is live.
max_attempts=5
for attempt in $(seq 1 $max_attempts); do
  if check_endpoint "Pipeline" && check_endpoint "PendingHumanAction"; then
    break
  fi
  if [[ $attempt -eq $max_attempts ]]; then
    die "harper-base tables not reachable on $CLI_APP_URL after $max_attempts attempts. Either (a) the deploy landed on the wrong cluster (CLI_TARGET Ops API pointed elsewhere), or (b) CLI_APP_URL is wrong. See docs/troubleshooting.md."
  fi
  printf '    (attempt %d/%d — waiting 5s)\n' "$attempt" "$max_attempts"
  sleep 5
done

# ---------------------------------------------------------------------------
# 6.5. Resource-method round-trip: POST /FlagHumanAction, GET /PendingHumanAction/<id>,
#      assert body fields actually landed. This is the check that catches
#      single-arg-vs-two-arg Resource.post() defects and @table(table:) schema
#      override mismatches.
#
#      History: v0.1.3 shipped a tables.* undefined defect; v0.1.4 shipped a
#      schema-override mismatch; v0.1.5 shipped a two-arg post signature that
#      silently dropped body fields. All three passed "deploy succeeded + GET
#      /Table/ 200" and failed here. Keep this check.
# ---------------------------------------------------------------------------
say "Step 7/8: Resource-method round-trip (body preservation check)"

# Marker string the round-trip will assert on. Using a UUID so a stale row from
# a prior run never matches a fresh assertion.
PROBE_MARKER="bootstrap-probe-$(python3 -c 'import uuid; print(uuid.uuid4())')"
PROBE_BODY=$(python3 -c "
import json
print(json.dumps({
    'sourceName': 'harper-openclaw-bootstrap-probe',
    'sourceUrl': 'https://example.invalid/probe',
    'businessObjective': '$PROBE_MARKER',
    'blocker': 'other',
    'blockerDetail': 'bootstrap Resource-method round-trip probe — safe to ignore or delete',
    'suggestedNextStep': 'no action required',
    'createdByAgent': 'bootstrap.sh',
}))
")

# POST the probe. Capture HTTP status + body separately so a 500 gives a useful
# error message.
post_status="$(curl -sS --max-time 15 \
  -o /tmp/harper-probe-post.body \
  -w '%{http_code}' \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "$PROBE_BODY" \
  "$CLI_APP_URL/FlagHumanAction" || echo "000")"
post_body="$(cat /tmp/harper-probe-post.body 2>/dev/null || true)"
rm -f /tmp/harper-probe-post.body

if [[ "$post_status" != "200" && "$post_status" != "201" ]]; then
  printf '    POST /FlagHumanAction → HTTP %s\n    body: %s\n' "$post_status" "$(printf '%s' "$post_body" | head -c 400)"
  die "POST /FlagHumanAction failed. harper-base tables are reachable (Step 6 passed), but the Resource method is 500ing. This is the v0.1.3-era 'tables.* undefined' defect class — check harper-base/resources.js and harper-base/schema.graphql against skills/harper-best-practices canonical patterns. See docs/troubleshooting.md 'Resource method returns 200 but stored record is empty'."
fi

# Parse the returned id. Harper's FlagHumanAction returns {ok: true, id: "..."}.
probe_id="$(printf '%s' "$post_body" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("id") or "")' 2>/dev/null || true)"
if [[ -z "$probe_id" ]]; then
  printf '    POST /FlagHumanAction body: %s\n' "$(printf '%s' "$post_body" | head -c 400)"
  die "POST /FlagHumanAction returned HTTP $post_status but the response body had no 'id' field. Either Resource.post() is not returning its expected shape, or the response was truncated."
fi
ok "POST /FlagHumanAction → HTTP $post_status, id=$probe_id"

# GET the row back. Fabric can take a moment to index writes — retry briefly.
probe_get=""
for attempt in 1 2 3 4 5; do
  probe_get="$(curl -sS --max-time 15 \
    -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
    "$CLI_APP_URL/PendingHumanAction/$probe_id" || true)"
  # A 404 returns HTML or "Not found" — check for a known JSON field instead.
  if printf '%s' "$probe_get" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "id" in d' 2>/dev/null; then
    break
  fi
  if [[ $attempt -eq 5 ]]; then
    printf '    GET /PendingHumanAction/%s → %s\n' "$probe_id" "$(printf '%s' "$probe_get" | head -c 400)"
    die "Wrote FlagHumanAction id=$probe_id but GET /PendingHumanAction/$probe_id never returned a row. POST is not actually persisting — schema name vs. tables-global key mismatch, or FlagHumanAction.post() isn't awaiting tables.PendingHumanAction.put()."
  fi
  sleep 2
done

# Round-trip the body. v0.1.5's defect: POST returned 200 with an id, but GET
# showed all body fields empty because Resource.post(target, data) captured the
# body in `target` and left `data` undefined. We assert the specific marker we
# sent came back on the row.
#
# f-string note: the marker interpolation extracts to a variable first — older
# Python (3.11-) rejects backslashes inside f-string braces, which bit us in
# v0.2.0's validation script. Keeping the interpolation trivial here.
python3 - <<PYEOF || die "Round-trip body assertion failed. See message above."
import json, sys
body = json.loads('''$probe_get''')
expected_marker = '$PROBE_MARKER'
actual_marker = body.get('businessObjective') or ''
actual_source = body.get('sourceName') or ''
actual_blocker = body.get('blocker') or ''
missing = []
if actual_marker != expected_marker:
    missing.append(f"businessObjective (expected {expected_marker!r}, got {actual_marker!r})")
if actual_source != 'harper-openclaw-bootstrap-probe':
    missing.append(f"sourceName (got {actual_source!r})")
if actual_blocker != 'other':
    missing.append(f"blocker (got {actual_blocker!r})")
if missing:
    print("    Body round-trip failed. Fields lost between POST and GET:", file=sys.stderr)
    for m in missing:
        print(f"      - {m}", file=sys.stderr)
    print("", file=sys.stderr)
    print("    This is the v0.1.5-era 'single-arg Resource.post()' defect class:", file=sys.stderr)
    print("    your POST handler is declared as post(target, data) but Harper dispatches", file=sys.stderr)
    print("    bare POSTs with the body as the single positional argument. Fix: change", file=sys.stderr)
    print("    to 'async post(data)' and index fields directly off 'data'.", file=sys.stderr)
    print("    See docs/troubleshooting.md 'Resource method returns 200 but stored record is empty'.", file=sys.stderr)
    sys.exit(1)
print("    body round-trip: all asserted fields preserved")
PYEOF
ok "Resource method round-trip passed (POST→GET preserved body fields)"

# Cleanup: mark the probe row resolved so it doesn't pollute a real human-review
# queue. If the mark fails it's not fatal — the row is obviously a probe and a
# human can purge it.
curl -sS --max-time 10 -o /dev/null \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X PATCH \
  -d '{"status":"resolved","resolvedBy":"bootstrap.sh","resolvedAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' \
  "$CLI_APP_URL/PendingHumanAction/$probe_id" || true

# ---------------------------------------------------------------------------
# 7. Install skills
#
# Two skills get installed to ~/.openclaw/skills/:
#   - harper-pipeline-builder (this repo)  — pattern for building OpenClaw→Harper
#     pipelines, copied from skills/ in this repo.
#   - harper-best-practices (Harper, upstream) — canonical guidance for writing
#     schemas, Resource classes, and deployment. Fetched via `npm create
#     harper@latest` so it's always current against Harper's latest SDK.
#
# The harper-pipeline-builder skill REFERENCES harper-best-practices (see
# rules/03-scaffold-component.md, top of file). Installing pipeline-builder
# without best-practices is a known-bad state: agents will deviate from
# canonical patterns and reproduce the defect classes documented in
# docs/troubleshooting.md. Fail loud if best-practices install fails.
# ---------------------------------------------------------------------------
say "Step 8/8: install harper-pipeline-builder + harper-best-practices skills"

mkdir -p "$SKILLS_DIR"

# --- harper-pipeline-builder (local) ----------------------------------------
SKILL_SRC="${SCRIPT_DIR}/skills/harper-pipeline-builder"
SKILL_DST="${SKILLS_DIR}/harper-pipeline-builder"

[[ -d "$SKILL_SRC" ]] || die "Skill source not found at $SKILL_SRC"

if [[ -d "$SKILL_DST" ]]; then
  rm -rf "$SKILL_DST"
  ok "removed existing harper-pipeline-builder skill (re-install)"
fi
cp -r "$SKILL_SRC" "$SKILL_DST"
ok "installed harper-pipeline-builder to $SKILL_DST"

# --- harper-best-practices (upstream, via npm create harper@latest) ---------
HBP_DST="${SKILLS_DIR}/harper-best-practices"

if [[ -d "$HBP_DST" && -z "${FORCE_REINSTALL_SKILLS:-}" ]]; then
  ok "harper-best-practices already installed at $HBP_DST (set FORCE_REINSTALL_SKILLS=1 to refresh)"
else
  # Scratch dir — create-harper writes a full project tree and we only want
  # the one skill directory out of it. Clean up unconditionally at the end.
  HBP_SCRATCH="$(mktemp -d -t harper-bp-fetch.XXXXXX)"
  trap 'rm -rf "$HBP_SCRATCH"' EXIT

  printf '    fetching harper-best-practices via npm create harper@latest (can take ~30s)...\n'
  (
    cd "$HBP_SCRATCH"
    # --yes skips the interactive TUI; the scaffolder still writes the skill.
    # Redirect stderr+stdout to a log so we can fish out a failure cause if
    # needed, without spamming the console with its spinner output.
    if ! npm create harper@latest -- --yes >"$HBP_SCRATCH/.create-harper.log" 2>&1; then
      cat "$HBP_SCRATCH/.create-harper.log" >&2
      die "npm create harper@latest failed. See output above. (Does the machine have network access + npm?)"
    fi
  )

  # The scaffold lands the skill at <scratch>/<project>/.agents/skills/harper-best-practices/.
  # Project name isn't deterministic — locate by skill path.
  hbp_src="$(find "$HBP_SCRATCH" -maxdepth 6 -type d -name 'harper-best-practices' -path '*/.agents/skills/*' 2>/dev/null | head -1)"
  if [[ -z "$hbp_src" || ! -d "$hbp_src" ]]; then
    die "npm create harper@latest completed but harper-best-practices skill not found under $HBP_SCRATCH. Harper may have changed the install layout — check the scaffolder output."
  fi

  # Validate it's a real skill (has SKILL.md with frontmatter).
  if [[ ! -f "$hbp_src/SKILL.md" ]] || ! grep -q '^name: harper-best-practices' "$hbp_src/SKILL.md"; then
    die "Found $hbp_src but SKILL.md is missing or has no frontmatter. Rejecting as unsafe."
  fi

  if [[ -d "$HBP_DST" ]]; then
    rm -rf "$HBP_DST"
  fi
  cp -rL "$hbp_src" "$HBP_DST"
  ok "installed harper-best-practices to $HBP_DST"

  rm -rf "$HBP_SCRATCH"
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<'EOF'

✓ Bootstrap complete.

Next: append the AGENTS.md fragment below to your OpenClaw workspace AGENTS.md
(typically at ~/.openclaw/AGENTS.md or wherever agents.defaults.workspace
points). Then ask OpenClaw to build a pipeline.

───── paste this into AGENTS.md ─────
EOF

cat "${SCRIPT_DIR}/skills/harper-pipeline-builder/AGENTS.md"

cat <<'EOF'

───── end of AGENTS.md fragment ─────

Try it:

    In OpenClaw: "Build a Harper pipeline for USGS earthquakes, schedule every 15m."

EOF
