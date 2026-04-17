# Troubleshooting

## OpenClaw says "I don't see the Harper skill"

The skill must be in one of OpenClaw's skill-loading locations:
- `<workspace>/skills/harper-pipeline-builder/`
- `<workspace>/.agents/skills/harper-pipeline-builder/`
- `~/.agents/skills/harper-pipeline-builder/`
- `~/.openclaw/skills/harper-pipeline-builder/`

And the top of `SKILL.md` must have the frontmatter (the `---` block with `name:` and `description:`). Without frontmatter, OpenClaw won't load it.

## Deploy says "Successfully deployed" but nothing shows up on Fabric

**This is the #1 silent failure.** The CLI reports success, the agent reports success, and yet `$CLI_TARGET/<TARGET_TABLE>/` returns 404. Almost always one of:

1. **Local `.env` overriding the global secrets file.** The component directory had a `.env` (or the Harper CLI found a default) pointing at `http://localhost:9925` — the agent deployed to a local Harper instance, not Fabric. Fix: `cat <component>/.env` and confirm `CLI_TARGET` is `https://...`. If the file doesn't exist, `cp ~/.openclaw/secrets/harper.env <component>/.env`.
2. **`CLI_TARGET` missing the port.** Fabric clusters sometimes expose the Operations API on a non-default port (e.g. `:9926`). The Application URL in the Fabric Config tab is authoritative — copy it verbatim, port included.
3. **Wrong protocol.** Fabric is always `https://`. A `CLI_TARGET=http://...` will appear to connect but won't match auth, and you'll end up on a different surface.

The pre-flight checks in `rules/04-deploy.md` catch all three. Skipping them is what produces this failure mode.

## Deploy fails with `ECONNREFUSED`

`CLI_TARGET` is unreachable. Re-run the pre-flight checks:

1. `source .env && echo "$CLI_TARGET"` — confirm you're pointing at the right URL (not `localhost`, not empty).
2. `curl -I "$CLI_TARGET"` — should return an HTTP status, not hang.
3. If `CLI_TARGET` is the cluster's Application URL and still refuses, the cluster may be paused — check the Fabric UI.

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
