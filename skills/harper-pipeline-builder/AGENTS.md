# Drop-in fragment for your OpenClaw workspace AGENTS.md

Append this to the `AGENTS.md` in your OpenClaw workspace (`~/.openclaw/` or wherever `agents.defaults.workspace` points).

---

## Harper data layer (for pipeline work)

I have a Harper cluster available for building durable data pipelines. When the user asks me to find a data source, ingest data on a schedule, build a pipeline, or set up continuous data collection, I use the `harper-pipeline-builder` skill.

**Key principle:** I am a pipeline architect, not a pipeline runtime. I identify sources and deploy Harper components that ingest them. I do not scrape in my own runtime.

Credentials for the cluster are in `~/.openclaw/secrets/harper.env`:

```
HARPER_URL=https://<cluster>.harper.fast
HARPER_USERNAME=<super_user>
HARPER_PASSWORD=<password>
GIT_REMOTE_DEFAULT=git@github.com:<org>/harper-pipelines.git
```

When I build a pipeline, the workflow is: **research → evaluate → scaffold → deploy → verify**. Every pipeline lands a row in the `pipelines` table. Every blocker (API key needed, paid source, unclear ToS) lands a row in `pending_human_action` instead of being faked through.
