# Drop-in fragment for your OpenClaw workspace AGENTS.md

Append this to the `AGENTS.md` in your OpenClaw workspace (`~/.openclaw/` or wherever `agents.defaults.workspace` points).

---

## Harper data layer (for pipeline work)

I have a Harper Fabric cluster available for building durable data pipelines. When the user asks me to find a data source, ingest data on a schedule, build a pipeline, or set up continuous data collection, I use the `harper-pipeline-builder` skill.

**Key principle:** I am a pipeline architect, not a pipeline runtime. I identify sources and deploy Harper components that ingest them. I do not scrape in my own runtime.

Credentials for the cluster are in `~/.openclaw/secrets/harper.env`. I must copy this file into each pipeline component's working directory as `.env` before running `npm run deploy`, because the Harper CLI loads env vars via `dotenv` and a local `.env` in the component directory overrides anything already in the shell.

```
CLI_TARGET=https://<region>.<cluster>.harper.fast:9925   # Operations API URL (used by harperdb CLI)
CLI_APP_URL=https://<cluster>.harper.fast                # Application URL (used by REST probes)
CLI_TARGET_USERNAME=<super_user>
CLI_TARGET_PASSWORD=<password>
```

**Important — these are two different URLs, not one.** `CLI_TARGET` is the Operations API (where `harperdb deploy_component` sends its payload, usually on port `:9925`). `CLI_APP_URL` is the Application URL (where `GET /Pipeline/`, `GET /<Table>/`, and `GET /<PipelineId>Run` are served, no explicit port). Both are listed in the Fabric Config tab. Setting them to the same value is the known root cause of "deploy reported success but nothing on Fabric."

`CLI_TARGET`, `CLI_TARGET_USERNAME`, and `CLI_TARGET_PASSWORD` use those exact names because the Harper CLI reads them.

Before any `npm run deploy`, I run the pre-flight checks in `rules/04-deploy.md`: verify `.env` is loaded (all four vars), verify `CLI_TARGET` responds with JSON to `describe_all`, verify `CLI_APP_URL` serves `/Pipeline/` (i.e. `harper-base` is deployed), and verify no other deploy is in flight. After deploy, I run the three post-deploy verification checks — all against `CLI_APP_URL` — to confirm the component actually landed on Fabric.

When I build a pipeline, the workflow is: **research → evaluate → scaffold → deploy → verify**. Every pipeline lands a row in the `Pipeline` table. Every blocker (API key needed, paid source, unclear ToS) lands a row in `PendingHumanAction` instead of being faked through.
