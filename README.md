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

### 2. Bootstrap — one command

```bash
git clone https://github.com/HarperFast/harper-openclaw-quickstart
cd harper-openclaw-quickstart
./bootstrap.sh
```

`bootstrap.sh` does everything: prompts for your cluster creds, writes `~/.openclaw/secrets/harper.env`, deploys `harper-base` (with pre-flight + post-deploy verification), installs the skill into `~/.openclaw/skills/`, and prints the AGENTS.md fragment for you to paste into your OpenClaw workspace.

It's idempotent — safe to re-run.

If you'd rather do it manually, see [`skills/harper-pipeline-builder/rules/00-bootstrap.md`](./skills/harper-pipeline-builder/rules/00-bootstrap.md).

### 3. Paste the AGENTS.md fragment

Bootstrap prints a fragment — append it to your OpenClaw workspace `AGENTS.md` (typically `~/.openclaw/AGENTS.md`). The fragment tells the agent that a Harper cluster is available and which skill to use.

### 4. Hello world: ask OpenClaw to build a pipeline

In your OpenClaw chat channel:

> Build a Harper pipeline that ingests the latest earthquakes from the USGS API (https://earthquake.usgs.gov/fdsnws/event/1/) every 15 minutes.

What happens:

1. OpenClaw reads the `harper-pipeline-builder` skill.
2. It inspects the USGS API (it's public, GeoJSON, no auth — the happiest path).
3. It fills in the `pipeline-component` template with an `Earthquake` schema and an ingest function.
4. It runs `npm run deploy` in the new component directory, which uploads to Fabric via the Harper CLI, with pre-flight and post-deploy verification around it.
5. It inserts a row into `Pipeline` recording what it built.
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
├── bootstrap.sh                 ← one-command install
├── harper-base/                 ← the Harper component you deploy once per cluster
│   ├── schema.graphql              (Pipeline + PendingHumanAction tables)
│   ├── resources.js                (small helpers OpenClaw calls)
│   ├── config.yaml
│   ├── package.json
│   ├── scripts/
│   │   ├── preflight.mjs           (runs before deploy — verifies target)
│   │   └── verify.mjs              (runs after deploy — verifies tables are live)
│   └── .env.example
├── skills/
│   └── harper-pipeline-builder/ ← the OpenClaw skill
│       ├── SKILL.md                (how the agent should think)
│       ├── AGENTS.md               (drop-in fragment for workspace AGENTS.md)
│       └── rules/                  (per-step rules — bootstrap, research, evaluate, scaffold, deploy, verify)
├── .agents/
│   └── prompts/                 ← release-cut playbooks and orchestration prompts
│       ├── v0.2.1-cut.md
│       └── v0.3-cut.md
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
- **One-call deploy.** `npm run deploy` uploads the component directory straight to Fabric. No git URL, no CI, no container infra.
- **Replicated by default.** Set `replicated: true` and your pipeline runs across the cluster.
- **Real-time built in.** WebSockets on every table. Your downstream systems can subscribe instead of polling.

## Why OpenClaw for this

- **Workspace + skills model.** Skills live in `~/.openclaw/skills/`, scoped per agent. Dropping in `harper-pipeline-builder/` is the whole install.
- **Long-running.** OpenClaw is happy to be the research-and-scaffold agent while Harper handles the ongoing work.
- **Multi-channel.** Your team can ask for new pipelines from Slack, iMessage, WhatsApp — wherever OpenClaw listens.

## License

Apache-2.0.
