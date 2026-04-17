# Drop-in fragment for your OpenClaw workspace AGENTS.md

Append this to the `AGENTS.md` in your OpenClaw workspace (`~/.openclaw/` or wherever `agents.defaults.workspace` points).

---

## Harper data layer (for pipeline work)

I have a Harper Fabric cluster available for building durable data pipelines. When the user asks me to find a data source, ingest data on a schedule, build a pipeline, or set up continuous data collection, I use the `harper-pipeline-builder` skill.

**Key principle:** I am a pipeline architect, not a pipeline runtime. I identify sources and deploy Harper components that ingest them. I do not scrape in my own runtime.

Credentials for the cluster are in `~/.openclaw/secrets/harper.env`. I must copy this file into each pipeline component's working directory as `.env` before running `npm run deploy`, because the Harper CLI loads env vars via `dotenv` and a local `.env` in the component directory overrides anything already in the shell.

```
CLI_TARGET=https://<cluster>.harper.fast
CLI_TARGET_USERNAME=<super_user>
CLI_TARGET_PASSWORD=<password>
```

These exact names are required — the Harper CLI reads them, and renaming breaks the deploy.

Before any `npm run deploy`, I run the pre-flight checks in `rules/04-deploy.md`: verify `.env` is loaded, verify `CLI_TARGET` is reachable and authenticated, verify `harper-base` is deployed, and verify no other deploy is in flight. After deploy, I run the three post-deploy verification checks to confirm the component actually landed on Fabric (not silently on local Harper).

When I build a pipeline, the workflow is: **research → evaluate → scaffold → deploy → verify**. Every pipeline lands a row in the `Pipeline` table. Every blocker (API key needed, paid source, unclear ToS) lands a row in `PendingHumanAction` instead of being faked through.
