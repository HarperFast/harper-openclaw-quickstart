# Architecture

## Principle

**OpenClaw is the architect. Harper is the runtime.** Once a pipeline is deployed, Harper runs it forever. OpenClaw is not in the data path.

This is the opposite of the "agent-as-scraper" pattern, and the distinction matters: that pattern is brittle (agent dies → pipeline dies), expensive (LLM tokens per ingestion), and hard to audit (no durable record of what was built). The pattern in this repo gives you durable pipelines with cheap ongoing cost and a full audit trail.

## Components

```
┌───────────────────────────────────────────────────────────────┐
│ OpenClaw workspace (per user / per cluster owner)             │
│                                                               │
│   agents.defaults.workspace                                   │
│   ├── AGENTS.md        ◀── your drop-in fragment lives here  │
│   ├── SOUL.md                                                 │
│   ├── skills/                                                 │
│   │   └── harper-pipeline-builder/   ◀── the skill            │
│   │       ├── SKILL.md                                        │
│   │       ├── rules/                                          │
│   │       └── prompts/                                        │
│   ├── harper-pipelines/              ◀── scratch area         │
│   │   └── <PIPELINE_ID>/             ◀── scaffolded per run   │
│   └── secrets/                                                │
│       └── harper.env                                          │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            │  deploy_component (git URL or tar payload)
                            ▼
┌───────────────────────────────────────────────────────────────┐
│ Harper Fabric cluster                                         │
│                                                               │
│   Components:                                                 │
│   ├── harper-base              ◀── deployed once              │
│   │     ├── Pipeline table (registry)                         │
│   │     ├── PendingHumanAction table (escape hatch)           │
│   │     └── helpers: PipelineRegister, FlagHumanAction, …     │
│   │                                                           │
│   ├── usgs-earthquakes         ◀── one per pipeline           │
│   │     ├── Earthquake table (@export → REST + WS)            │
│   │     ├── scheduled runPipeline() every 15m                 │
│   │     └── POST /UsgsEarthquakesRun (manual trigger)         │
│   │                                                           │
│   └── <more pipelines…>                                       │
│                                                               │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            │  REST / WebSocket
                            ▼
                    ┌───────────────────┐
                    │  your existing    │
                    │  outreach funnel  │
                    │  (Twilio, 11labs, │
                    │   sales CRM, etc) │
                    └───────────────────┘
```

## Data flow

1. **Build time (OpenClaw, seconds to minutes):**
   User intent → source research → evaluation → template scaffolding → git push → `deploy_component` call → verify → `PipelineRegister`.

2. **Run time (Harper, continuous):**
   Cron tick → `fetchFromSource` → upsert into target table → update `Pipeline.lastRun*` → REST/WS subscribers see new data.

3. **Human-in-the-loop (as needed):**
   OpenClaw hits a blocker → `FlagHumanAction` posts to `pending_human_action` → a human clears the blocker (gets the API key, confirms ToS) → human tells OpenClaw it's unblocked → OpenClaw re-runs from step 3 of the skill.

## Trust boundaries

- **Agent → Harper:** authenticated super_user. Minimum scope; only needs `deploy_component`, `add_component`, and CRUD on the registry tables. Consider a dedicated Harper role for agent credentials.
- **Downstream funnel → Harper:** normal Harper auth. Can be read-only if the funnel doesn't need to mutate records.
- **Agent → source APIs:** no secrets shared beyond what's in `~/.openclaw/secrets/`. The agent never stores credentials in scaffolded code — it emits `process.env.<NAME>` references and expects the cluster env to have them.

## What's deliberately NOT in this architecture

- **No intermediate queue.** Records go straight from `fetchFromSource` to the table. If you need buffering, stream-processing, or back-pressure, add a component; don't add it to every pipeline by default.
- **No feature flags per-pipeline.** `Pipeline.status` is the kill switch. If you need finer-grained control, each pipeline can read its own row before running.
- **No agent-in-the-path.** If your use case actually needs per-record LLM enrichment, that's a separate component (`@harperdb/something-enrichment`) that subscribes to the table via WebSocket — not something to bolt into the ingest loop.
