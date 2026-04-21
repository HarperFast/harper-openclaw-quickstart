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

Before emitting a `SourceCandidate`, you must do all of the following. Shortcuts here are what produced false-positive `pending_human_action` rows in prior runs.

1. **Read the API docs first.** Find the source's actual API documentation URL — the page that lists endpoints, request shapes, and auth requirements. Record it on the candidate as `docsUrl`. No `docsUrl`, no candidate.
2. **Hit the specific endpoint you plan to pipeline against — not just the base URL or a reference endpoint.** A 200 on `/healthcheck` or `/toptier_agencies/` does not prove the contractor-data endpoint works. Construct the exact request the docs describe (method, headers, body, query params) and fire it. Record the HTTP status.
3. If the endpoint needs a POST with a JSON body, send a POST with a JSON body. If it uses case-sensitive field names (USAspending's `"Action Date"` vs `action_date`, etc.), use the exact strings the docs show. A 400 with a helpful error message is `proceed — request shape wrong`, not `drop`.
4. If the response is 200, pull **at least 3 sample records** and record their shape (top-level keys, field-level types, which fields are null). One record is not enough — it can look complete while a required field is systematically null across the endpoint.
5. If it 401s or 403s, it has auth — record that fact.
6. If it 404s after you've followed the docs, drop it. If it 404s because you guessed the URL, that's your bug — re-read the docs and retry. Don't emit a `drop` or a `pending_human_action` for guess-404s.

**Never file a `pending_human_action` for a request-construction error.** Auth gaps (401/403 with docs confirming API key or login), paid tiers, and ToS blockers are legitimate human-action items. A 400 or a null-field response because you sent the wrong payload shape is a bug in your request, not a source constraint — fix it and retry.

## Output

Return all candidates as a JSON array. Show them to the user and ask which to proceed with — unless the user already specified one, in which case go straight to step 2 with just that one.
