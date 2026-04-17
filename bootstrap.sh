#!/usr/bin/env bash
# bootstrap.sh — one-command installer for harper-openclaw-quickstart
#
# Idempotent. Safe to re-run. Sequence:
#   1. Gather Harper Fabric creds (interactive; or read from existing env)
#   2. Write ~/.openclaw/secrets/harper.env
#   3. Pre-flight: confirm cluster reachable + authenticated
#   4. Deploy harper-base (registry + escape-hatch tables)
#   5. Post-deploy: confirm Pipeline + PendingHumanAction endpoints exist
#   6. Install skill into ~/.openclaw/skills/harper-pipeline-builder/
#   7. Print AGENTS.md fragment for the user to paste into their workspace
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
say "Step 1/7: gather Harper Fabric credentials"

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
say "Step 2/7: write $SECRETS_FILE"
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
say "Step 3/7: pre-flight — confirm Fabric cluster is reachable + authenticated"

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
say "Step 4/7: install deploy tooling at repo root (small, one-time)"

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

say "Step 5/7: deploy harper-base (registry + escape-hatch tables)"

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
say "Step 6/7: verify harper-base tables are live on Fabric"

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
# 6. Install skill
# ---------------------------------------------------------------------------
say "Step 7/7: install harper-pipeline-builder skill"

mkdir -p "$SKILLS_DIR"
SKILL_SRC="${SCRIPT_DIR}/skills/harper-pipeline-builder"
SKILL_DST="${SKILLS_DIR}/harper-pipeline-builder"

[[ -d "$SKILL_SRC" ]] || die "Skill source not found at $SKILL_SRC"

if [[ -d "$SKILL_DST" ]]; then
  rm -rf "$SKILL_DST"
  ok "removed existing skill (re-install)"
fi
cp -r "$SKILL_SRC" "$SKILL_DST"
ok "installed skill to $SKILL_DST"

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
