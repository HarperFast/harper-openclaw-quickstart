# harper-openclaw-quickstart

**Teach your [OpenClaw](https://openclaw.ai) agent to build and deploy durable data pipelines on [Harper](https://harper.fast).**

OpenClaw is great at figuring things out. It's not great at being a long-running scraper. Harper is great at being a long-running pipeline. This repo bolts them together: OpenClaw identifies API-backed data sources for your business, then writes and deploys a Harper component that continuously pulls from that source. OpenClaw walks away. Harper keeps running.

No agent in the hot path. No "the scraper stopped working." Just pipelines.

---

## What this gives you

1. A **Harper skill for OpenClaw** (`skills/harper-pipeline-builder/`) that teaches your agent the full pipeline-builder workflow: research sources → evaluate → scaffold component → deploy → verify → register.
2. A **Harper component template** (`templates/pipeline-component/`) that OpenClaw fills in per data source.
3. A **registry + escape-hatch schema** (`harper-base/`) — a pair of Harper tables (`pipelines`, `pending_human_action`) that give OpenClaw a place to record what it built and what it can't do without a human.
4. A **Hello-world walkthrough** proving the full loop against a free, no-auth government API.

## The mental model

```
┌──────────────────────┐
│ you: "find contractor │
│  registration sources │
│  for our sales funnel"│
└──────────┬────────────┘
           │
           ▼
  ┌────────────────────┐   ┌──────────────────────────┐
  │     OpenClaw       │──▶│ pending_human_action     │  (API keys, paid brokers, unclear ToS)
  │  (your agent)      │   │   table in Harper        │
  └────────┬───────────┘   └──────────────────────────┘
           │                         ▲
           │ for each viable source:  │
           │  1. scaffold component   │ (logs skipped sources here)
           │  2. deploy_component     │
           │  3. insert into pipelines│
           ▼
  ┌────────────────────┐
  │      Harper        │ ─── pulls data on schedule, forever ───▶ your funnel
  │  (pipeline runtime)│
  └────────────────────┘
```

Critical: **OpenClaw builds the pipeline. Harper runs it.** OpenClaw is not in the data path.

## 10-minute quickstart

You'll need:

- A Harper Fabric account (free tier, no CC) — https://fabric.harper.fast
- OpenClaw installed — https://docs.openclaw.ai/install
- `git`, `node >= 20`, `npm`

### 1. Spin up a free Harper cluster

Sign in at fabric.harper.fast → create org → create cluster (free tier) → set a cluster username + password → grab the **Application URL** from the Config tab.

### 2. Bootstrap Harper with the registry + escape-hatch

This creates the `pipelines` and `pending_human_action` tables OpenClaw will use to record its work.

```bash
git clone https://github.com/<your-org>/harper-openclaw-quickstart
cd harper-openclaw-quickstart/harper-base
cp .env.example .env
# Edit .env with your cluster credentials (CLI_TARGET, CLI_TARGET_USERNAME, CLI_TARGET_PASSWORD)
npm install
npm run deploy
```

Verify:

```bash
curl -u $CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD $CLI_TARGET/pipelines
# → []
curl -u $CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD $CLI_TARGET/pending_human_action
# → []
```

### 3. Install the OpenClaw skill

Copy the skill into your OpenClaw workspace (or `~/.openclaw/skills/`):

```bash
cp -r skills/harper-pipeline-builder ~/.openclaw/skills/
```

Then add these lines to your OpenClaw workspace `AGENTS.md` so the agent knows Harper is available:

```markdown
## Harper data layer

I have a Harper cluster available for building durable data pipelines.
When the user asks me to find a data source, build a pipeline, or ingest
something on a schedule, I should use the `harper-pipeline-builder` skill.

Credentials are in ~/.openclaw/secrets/harper.env:
  HARPER_URL, HARPER_USERNAME, HARPER_PASSWORD
```

Drop your cluster creds into `~/.openclaw/secrets/harper.env` (same three vars as `.env`).

### 4. Hello world: ask OpenClaw to build a pipeline

In your OpenClaw chat channel:

> Build a Harper pipeline that ingests the latest earthquakes from the USGS API (https://earthquake.usgs.gov/fdsnws/event/1/) every 15 minutes.

What happens:

1. OpenClaw reads the `harper-pipeline-builder` skill.
2. It inspects the USGS API (it's public, GeoJSON, no auth — the happiest path).
3. It fills in the `pipeline-component` template with an `Earthquake` schema and an ingest function.
4. It calls Harper's `deploy_component` operation with the component URL.
5. It inserts a row into `pipelines` recording what it built.
6. It polls the new `/Earthquake` endpoint and confirms data is flowing.
7. It reports back: "pipeline live, 147 records in the first pull, next run at 14:15 UTC."

**If any step would require an API key, paid broker access, or unclear ToS**, OpenClaw stops and writes a row to `pending_human_action` with exactly what it needs from you. No guessing. No fake credentials.

### 5. Graduate to your actual use case

Same flow. More interesting prompt. The agent doesn't care whether it's earthquakes or contractor registrations — the skill's job is to make the scaffolding + deploy path reliable.

See [`examples/`](./examples/) for a worked contractor-registration example.

---

## What's in this repo

```
harper-openclaw-quickstart/
├── README.md                    ← you are here
├── harper-base/                 ← the Harper component you deploy once per cluster
│   ├── schema.graphql              (pipelines + pending_human_action tables)
│   ├── resources.js                (small helpers OpenClaw calls)
│   ├── config.yaml
│   ├── package.json
│   └── .env.example
├── skills/
│   └── harper-pipeline-builder/ ← the OpenClaw skill
│       ├── SKILL.md                (how the agent should think)
│       ├── AGENTS.md               (drop-in fragment for workspace AGENTS.md)
│       ├── rules/                  (per-step rules — research, evaluate, scaffold, deploy, verify)
│       └── prompts/
├── templates/
│   └── pipeline-component/      ← template OpenClaw copies + fills in per source
│       ├── schema.graphql
│       ├── resources.js
│       ├── config.yaml
│       ├── package.json
│       └── README.md
├── examples/
│   └── usgs-earthquakes/        ← fully-built "hello world" example
└── docs/
    ├── architecture.md
    ├── cost-and-scale.md        ← free→paid tipping points, parallel-pipeline capacity
    └── troubleshooting.md
```

## Why Harper for this

- **Durable.** The pipeline keeps running after the agent disconnects.
- **Zero glue code.** `@table @export` gives you REST + WebSocket CRUD for free — your funnel can pull from `/ContractorRegistration?state=CO` the minute records start landing.
- **One-call deploy.** `deploy_component` accepts a git URL. OpenClaw doesn't need CI or container infra.
- **Replicated by default.** Set `replicated: true` and your pipeline runs across the cluster.
- **Real-time built in.** WebSockets on every table. Your downstream systems can subscribe instead of polling.

## Why OpenClaw for this

- **Workspace + skills model.** Skills live in `~/.openclaw/skills/`, scoped per agent. Dropping in `harper-pipeline-builder/` is the whole install.
- **Long-running.** OpenClaw is happy to be the research-and-scaffold agent while Harper handles the ongoing work.
- **Multi-channel.** Your team can ask for new pipelines from Slack, iMessage, WhatsApp — wherever OpenClaw listens.

## License

Apache-2.0.
