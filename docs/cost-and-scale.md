# Cost + scale: when does this stop being free?

Answers the common customer question: *"What's the tipping point from free to paid, how much will it cost as this scales up, and how many parallel agents / tasks can we handle?"*

Numbers below are directional — confirm against current Harper Fabric pricing at https://harper.fast/pricing before quoting anything.

---

## What costs money in this pattern

Two distinct things:

1. **OpenClaw side** — model inference + agent runtime. Priced by the agent runtime provider (OpenClaw is free; the LLM calls are whatever the model provider charges). Pipeline-building is bursty and cheap per run.
2. **Harper side** — storage + compute + replication. This is the ongoing cost. Every pipeline consumes a small, predictable slice.

## OpenClaw costs per pipeline built

Building a pipeline (full 5-step skill run) typically burns:

- ~5–15 LLM calls across research, evaluation, and scaffold rendering
- ~10k–50k tokens total, heavily dependent on how many candidate sources Step 1 returns

At typical frontier-model rates, that's single-digit dollars per pipeline built, one-time. After the pipeline is deployed, OpenClaw is not in the data path — no ongoing agent cost.

## Harper costs per running pipeline

A pipeline consumes three Harper resources:

| Resource | Typical per-pipeline draw |
|---|---|
| Storage | Roughly `record_size × records_per_day × retention_days`. For the USAspending example: ~1kb records × 5k/day × 90 days ≈ 450MB/pipeline. |
| Compute (scheduled work) | One cron tick per schedule interval. At `*/15 * * * *`, that's 96 ticks/day. Each tick is usually <1s of CPU. |
| Egress | Per response to the downstream funnel. Usually dominated by the funnel's polling pattern, not by the pipeline. |

**Translation: a small fleet of pipelines (≤20, 15-minute cadence, low-thousands of records per run) fits well inside Harper Fabric's starter tier.**

## Where the tipping points actually are

In order of which you'll hit first:

1. **Storage retention.** First constraint is almost always "I want 2 years of historical awards, not 90 days." Retention drives cost linearly.
2. **Parallel pipelines.** Harper Fabric's starter tier has a soft cap on concurrent scheduled tasks. Past ~20–30 pipelines at sub-minute cadence, you're into a paid tier. Past ~200, you want dedicated worker nodes.
3. **Cluster replication.** If you're replicating across regions (for latency near downstream callers), each extra region multiplies storage linearly and adds a small replication cost.
4. **Real-time subscribers.** Many WebSocket subscribers to hot tables (thousands concurrent) push you into a higher compute tier. For a typical outreach funnel with <100 internal services polling, this is far from the bottleneck.

## How many parallel agents / parallel tasks can we handle?

Two separate questions:

**Parallel OpenClaw agents building pipelines at once:** bounded by the *inference provider* (OpenAI/Anthropic/whomever you point OpenClaw at), not by Harper. Harper's `deploy_component` handles concurrent deploys — the rolling-restart pattern serializes actual swap-in per node.

**Parallel Harper pipelines running at once:** a starter-tier Fabric cluster comfortably handles tens of pipelines with mixed schedules. For enterprise-scale ambition (hundreds of jurisdictions × multiple entity types), plan for:

- a dedicated "ingestion worker" node pool (keeps pipeline ticks isolated from API traffic)
- sharding pipelines across clusters by domain or region once you pass ~200 active pipelines
- moving hot target tables to their own component so restarts don't block them

## Rough quoting bands

To calibrate the pricing conversation:

| Scale | Monthly Harper cost (order of magnitude) | What you're getting |
|---|---|---|
| 5 pipelines, 15-min cadence, 90d retention | Free tier | POC / hello world |
| 25 pipelines, 15-min cadence, 1y retention | Low-hundreds of dollars | Pilot |
| 100 pipelines, mixed cadence, 2y retention, 2 regions | Low-thousands | Production for a regional sales org |
| 500+ pipelines, dedicated worker nodes, 3 regions | Custom | Enterprise; conversation with Harper sales |

These are the directional answers. Confirm exact pricing with Harper's current published tiers before quoting.
