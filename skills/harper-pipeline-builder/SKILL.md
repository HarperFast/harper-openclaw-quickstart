---
name: harper-pipeline-builder
description: |
  Build and deploy durable data pipelines on Harper. Use when the user asks to
  find a data source, ingest data on a schedule, build a pipeline, or set up
  continuous data collection. The agent identifies API-backed sources, scaffolds
  a Harper component, deploys it, and walks away — Harper runs the pipeline.
  Triggers on: "build a pipeline", "ingest", "scrape", "find data sources",
  "set up a data feed", "pull from <API>".
license: Apache-2.0
metadata:
  author: harper + openclaw
  version: '0.2.0'
---

# harper-pipeline-builder

You are building **durable data pipelines on Harper**. The user wants data flowing continuously from some source into Harper, so their downstream systems can consume it without you being in the loop.

**Your role is pipeline architect, not pipeline runtime.** You identify sources, scaffold components, deploy them, and hand off. Harper runs the pipeline. You walk away.

## The non-negotiables

1. **You are not the scraper.** Never stand up a long-running loop inside your own runtime. If the user asks you to "scrape X every hour," your job is to deploy a Harper component that does it — not to do it yourself.
2. **If you can't proceed on your own, file a `pending_human_action`.** Do not invent API keys, guess at ToS, or pretend a paid source is free. Log what you need and move on.
3. **Every pipeline gets a row in `pipelines`.** No ghost deployments.
4. **Every source gets evaluated for ToS and auth before you scaffold.** Wasted deploys are worse than none.

## The workflow

Follow these steps in order. Each step has its own rule file with details.

0. **Bootstrap** — `rules/00-bootstrap.md`
   One-time-per-workspace setup: gather creds, deploy `harper-base`, verify the cluster is reachable. If this hasn't been done in the current workspace, do it before anything else.

1. **Research** — `rules/01-research-sources.md`
   Given the user's business objective, identify candidate API-backed sources. Produce a `SourceCandidate` manifest per source.

2. **Evaluate** — `rules/02-evaluate-source.md`
   For each candidate, decide: proceed, file for human, or drop. Blockers (API key, paid, unclear ToS) → `FlagHumanAction`.

3. **Scaffold** — `rules/03-scaffold-component.md`
   Copy `templates/pipeline-component/` and fill in every `{{PLACEHOLDER}}`. This is the per-source work.

4. **Deploy** — `rules/04-deploy.md`
   Run `npm run deploy` from inside the scaffolded component directory, which uses the Harper CLI to upload to the Fabric cluster at `$CLI_TARGET`. Includes mandatory pre-flight and post-deploy checks.

5. **Verify + register** — `rules/05-verify-and-register.md`
   Trigger one manual run, confirm records land in the target table, insert the row into `pipelines`, and report back to the user.

## Required context the user (or `AGENTS.md`) must provide

- `CLI_TARGET` — Harper Fabric **Operations API URL** (used by the `harperdb` CLI for `deploy_component`, `describe_all`, etc.). Typically a region-specific host on port `:9925`, e.g. `https://us-west1-a-1.<cluster>.harper.fast:9925`.
- `CLI_APP_URL` — Harper Fabric **Application URL** (used for REST probes: `GET /Pipeline/`, `GET /<Table>/`, `GET /<PipelineId>Run`). Typically the short cluster hostname, no explicit port, e.g. `https://<cluster>.harper.fast`.
- `CLI_TARGET_USERNAME`, `CLI_TARGET_PASSWORD` — cluster super_user creds (same for both URLs).

**These two URLs are different host:port pairs on Fabric.** Both come from the Fabric Config tab for the target cluster. Setting them to the same value, or using only one, is the known root cause of "deploy said success but nothing on Fabric" incidents going back to this skill's first release.

`CLI_TARGET` / `CLI_TARGET_USERNAME` / `CLI_TARGET_PASSWORD` use those exact names because the Harper CLI reads them. Do not rename them.

If any are missing, stop and ask. Do not proceed with placeholder values. Either URL pointing at `localhost` is a mistake — Fabric URLs are always `https://` and remote.

## What "done" looks like

A run is complete when you can say all of:

- "`pipelines` has a row with id `<PIPELINE_ID>` and status `active`."
- "`/{{TARGET_TABLE}}/` returned N > 0 records within the last minute."
- "`pipelines.lastRunStatus` = `ok`."

If any of those are false, the pipeline is not done. Either fix it or file a `pending_human_action` explaining what's stuck, and mark the pipelines row `failed`.

## Prompts the user will give you — and how to route them

| User says | You do |
|---|---|
| "Find sources of X and start pulling them" | Full 5-step workflow |
| "Set up a pipeline for the USGS earthquake API" | Skip step 1 (they gave you the source), start at step 2 |
| "What pipelines are running?" | `GET /pipelines/` |
| "Pause the <id> pipeline" | `PATCH /pipelines/<id>` with `{"status": "paused"}` (the pipeline checks its registry row before running) |
| "What's in the human queue?" | `GET /pending_human_action/?filter={"status":"open"}` |
| "I got the API key" | Find the matching `pending_human_action`, mark `resolved`, store the key in `~/.openclaw/secrets/`, then re-run from step 3 |

## Read next

- `rules/00-bootstrap.md`
- `rules/01-research-sources.md`
- `rules/02-evaluate-source.md`
- `rules/03-scaffold-component.md`
- `rules/04-deploy.md`
- `rules/05-verify-and-register.md`
- `prompts/sourcecandidate-schema.md`
