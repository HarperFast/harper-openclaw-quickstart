# Step 1: Research sources

**Goal:** given a business objective, produce a ranked list of `SourceCandidate` manifests. Each manifest is a concrete, named, API-backed source you could build a pipeline for.

## What the business objective looks like

Examples you'll get:

- *"Find government sources of contractor business registrations that can lead to conversions for us."*
- *"Ingest every new SEC 8-K filing."*
- *"Track when HVAC permits are pulled in Colorado."*

These are not queries against a known API. They're intents. Your job is to translate intent → API-backed sources.

## What to produce

Per candidate, produce a JSON object matching `prompts/sourcecandidate-schema.md`. Return them ranked by "how cleanly can a Harper pipeline consume this?" — not by data quality.

Ranking heuristic (high to low):

1. Public REST/GraphQL API, no auth, documented.
2. Public API with a free API key.
3. Public API with a paid tier (and a free tier big enough to matter).
4. Bulk-download endpoint (CSV/JSON files on a schedule).
5. Anything requiring a data-broker contract or login-gated access — these go straight to `pending_human_action`; don't try to scrape around them.
6. HTML-only sources with no API — deprioritize. Harper pipelines are for API ingestion. If no API exists, either file a human-action ("contact X to ask for API access") or flag that this is out of scope.

## What NOT to do

- Don't invent URLs. Every `apiBaseUrl` you emit must be one you've actually seen respond.
- Don't guess at auth. If you don't know, say `auth: "unknown"`.
- Don't pick the first source and run. Produce at least three candidates before the user picks, unless the user named a specific source.
- Don't confuse "a website exists about X" with "an API exists for X."

## How to verify a source is real

Before emitting a `SourceCandidate`:

1. Fetch the API base URL (or a known endpoint). Record the HTTP status.
2. If it returns data, record the shape (top-level keys, one sample record).
3. If it 401s, it has auth — record that fact.
4. If it 404s or won't resolve, drop it. Don't emit.

## Output

Return all candidates as a JSON array. Show them to the user and ask which to proceed with — unless the user already specified one, in which case go straight to step 2 with just that one.
