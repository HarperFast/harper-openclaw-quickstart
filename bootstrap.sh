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

if [[ -z "${CLI_TARGET:-}" || -z "${CLI_TARGET_USERNAME:-}" || -z "${CLI_TARGET_PASSWORD:-}" ]]; then
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$SECRETS_FILE"; set +a
    ok "loaded existing $SECRETS_FILE"
  fi
fi

if [[ -z "${CLI_TARGET:-}" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "    CLI_TARGET (Fabric Application URL, e.g. https://foo.cluster.harper.fast): " CLI_TARGET
  else
    die "CLI_TARGET not set and no TTY to prompt. Export it first, or run interactively."
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

# Sanity
[[ "$CLI_TARGET" == https://* ]] || die "CLI_TARGET must start with https://. Got: $CLI_TARGET"
[[ "$CLI_TARGET" != *localhost* && "$CLI_TARGET" != *127.0.0.1* ]] || die "CLI_TARGET points at localhost. Fabric URLs are remote."
ok "creds present and shaped correctly"

# ---------------------------------------------------------------------------
# 2. Write secrets file
# ---------------------------------------------------------------------------
say "Step 2/7: write $SECRETS_FILE"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
{
  echo "CLI_TARGET=$CLI_TARGET"
  echo "CLI_TARGET_USERNAME=$CLI_TARGET_USERNAME"
  echo "CLI_TARGET_PASSWORD=$CLI_TARGET_PASSWORD"
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
ok "wrote $SECRETS_FILE (mode 600)"

# ---------------------------------------------------------------------------
# 3. Pre-flight: reachable + authenticated
# ---------------------------------------------------------------------------
say "Step 3/7: pre-flight — confirm Fabric cluster is reachable + authenticated"

preflight_response="$(curl -sS --max-time 15 \
  -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"operation":"describe_all"}' \
  "$CLI_TARGET" || true)"

if [[ -z "$preflight_response" ]]; then
  die "No response from $CLI_TARGET. Check the URL (port included?) and that the cluster is running."
fi
if [[ "$preflight_response" == *"Unauthorized"* || "$preflight_response" == *"401"* ]]; then
  die "Authentication failed against $CLI_TARGET. Check CLI_TARGET_USERNAME / CLI_TARGET_PASSWORD."
fi
if [[ "$preflight_response" == "<!DOCTYPE"* || "$preflight_response" == "<html"* ]]; then
  die "Got HTML from $CLI_TARGET — this is a web UI, not the Operations API. Use the Application URL from the Fabric Config tab."
fi
ok "cluster reachable + authenticated"

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
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
    "$CLI_TARGET/${table}/" || true)"
  if [[ "$code" == "200" ]]; then
    ok "GET $CLI_TARGET/${table}/ → 200"
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
    die "harper-base tables not reachable after $max_attempts attempts. Deploy may have gone to wrong target or failed silently. See docs/troubleshooting.md."
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
