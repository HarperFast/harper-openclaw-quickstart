# Troubleshooting

## OpenClaw says "I don't see the Harper skill"

The skill must be in one of OpenClaw's skill-loading locations:
- `<workspace>/skills/harper-pipeline-builder/`
- `<workspace>/.agents/skills/harper-pipeline-builder/`
- `~/.agents/skills/harper-pipeline-builder/`
- `~/.openclaw/skills/harper-pipeline-builder/`

And the top of `SKILL.md` must have the frontmatter (the `---` block with `name:` and `description:`). Without frontmatter, OpenClaw won't load it.

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

Each OpenClaw workspace points at one Harper cluster (via `HARPER_URL`). If you need one agent managing multiple clusters, run a separate OpenClaw workspace per cluster — easier than parameterizing the skill.

## "The agent keeps hallucinating source URLs"

Usually the fix is in Step 1 of the skill: make sure the agent is actually hitting candidate URLs before emitting a `SourceCandidate`, not just generating plausible-looking endpoints. The `sampleResponse.httpStatus` field in the schema is there specifically to force this — if the agent is producing `SourceCandidate`s with no `sampleResponse`, it's cheating.

## "`pending_human_action` is piling up"

Feature, not bug. Healthy clusters will have a queue of blocked sources. The queue becoming long just means the agent is being honest about what it can't do. Triage it on a cadence — daily for a POC, weekly for a mature cluster.
