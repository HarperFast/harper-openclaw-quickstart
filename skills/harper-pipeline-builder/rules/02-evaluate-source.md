# Step 2: Evaluate a source

**Goal:** for each `SourceCandidate`, produce exactly one of three outcomes: **proceed**, **file-for-human**, or **drop**.

## Prerequisite: the candidate must be real

Before you evaluate, confirm the candidate came out of rule 01 with **all** of the following recorded:

- `docsUrl` pointing at the source's actual API documentation (not a landing page, not a news release)
- A verified HTTP response from the **specific endpoint** you plan to pipeline against (not a neighboring reference endpoint)
- At least 3 sample records with field-level shape recorded

If any of those are missing, go back to rule 01. A candidate without these is a guess, not a candidate, and running it through the decision tree below will produce false-positive outcomes.

## Guess-404 handling

If you hit a 404 on an endpoint you constructed yourself (without the docs in front of you), that is **not** a `drop` and **not** a `file-for-human`. It's a you-need-to-read-the-docs bug. Re-read the API documentation, construct the correct request, retry. Only classify as file-for-human or drop after you've confirmed the docs-correct request still fails.

## The decision tree

```
SourceCandidate
   │
   ├─ auth = "none"? ──────────────────────────────────► PROCEED
   │
   ├─ auth = "api_key" and key is in ~/.openclaw/secrets/ ► PROCEED
   │
   ├─ auth = "api_key" and no key present ──────────────► FILE-FOR-HUMAN
   │      blocker: "api_key"
   │      suggestedNextStep: specific signup URL + env var name to set
   │
   ├─ auth = "paid" or requires contract ───────────────► FILE-FOR-HUMAN
   │      blocker: "paid_broker"
   │
   ├─ auth = "login_session" or requires browser login ─► FILE-FOR-HUMAN
   │      blocker: "login_required"
   │
   ├─ ToS clearly prohibits programmatic access ────────► DROP
   │      do not file; just drop with a short note to the user
   │
   ├─ ToS ambiguous ────────────────────────────────────► FILE-FOR-HUMAN
   │      blocker: "unclear_tos"
   │
   ├─ source is HTML-only (no API) ─────────────────────► FILE-FOR-HUMAN
   │      blocker: "other"
   │      blockerDetail: "No API available; consider outreach to provider"
   │
   └─ anything else you can't classify ─────────────────► FILE-FOR-HUMAN
          blocker: "other"
```

## How to file a pending_human_action

POST to `/FlagHumanAction` on the Harper cluster:

```json
{
  "sourceName": "SAM.gov Entity Management API",
  "sourceUrl": "https://api.sam.gov/entity-information/v3/entities",
  "businessObjective": "find contractor registrations for sales funnel",
  "blocker": "api_key",
  "blockerDetail": "Public API but requires a free API key obtained at api.sam.gov",
  "suggestedNextStep": "Register at https://open.gsa.gov/api/entity-api/ → generate a system account key → place in ~/.openclaw/secrets/sam-gov.env as SAM_GOV_API_KEY=...",
  "createdByAgent": "<your OpenClaw agent id>"
}
```

## What counts as "ToS clearly prohibits"

Explicit language in the source's terms saying: "no scraping," "no automated access," "API access by written permission only," etc. If you can't find the terms, treat it as `unclear_tos` and file-for-human — don't default to proceed.

## Per-source summary to emit

After evaluating all candidates, emit a short table to the user:

```
Source                         Outcome          Notes
USGS Earthquakes               proceed          no auth, JSON, documented
SAM.gov Entity API             file-for-human   needs free API key
Data.gov Contractors CSV       proceed          bulk CSV, daily refresh
LinkedIn Sales Navigator       file-for-human   ToS prohibits scraping — flagged for BD outreach
```

Then ask the user which of the `proceed` sources to build pipelines for. Don't build all of them by default — spinning up pipelines has cost (see `docs/cost-and-scale.md`).
