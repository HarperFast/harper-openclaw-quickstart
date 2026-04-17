# Step 5: Verify + register

**Goal:** prove the pipeline is actually running and put its identity on the record.

## 1. Trigger a manual run

The template exposes a manual trigger endpoint at `POST /<PIPELINE_ID_PASCAL>Run`:

```bash
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     -X POST $CLI_APP_URL/<PIPELINE_ID_PASCAL>Run \
     -d '{}'
```

Expected response:

```json
{ "runAt": "2026-04-16T21:30:00.000Z", "status": "ok", "records": 147 }
```

If `status !== "ok"` or `records === 0`, the pipeline is not working. Debug:

- `curl $CLI_APP_URL/<PIPELINE_ID_PASCAL>Run` (GET) → returns registry row, but only after step 2 below
- Check cluster logs for your component via the Harper ops API `read_log` operation
- Common cause: `FETCH_FN_BODY` is returning records without the `PRIMARY_KEY_FIELD` — they're silently skipped. Re-do the dry-run from step 3.

## 2. Confirm records landed

```bash
curl -sS -u "$CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD" \
     "$CLI_APP_URL/<TARGET_TABLE>/?limit=3"
```

Should return a list of records. If it returns `[]`, records didn't land — check that `PRIMARY_KEY_FIELD` matches what `fetchFromSource` actually returns.

## 3. Register in `pipelines`

POST to `/PipelineRegister`:

```json
{
  "id": "<PIPELINE_ID>",
  "sourceName": "<SOURCE_NAME>",
  "sourceUrl": "<SOURCE_URL>",
  "targetTable": "<TARGET_TABLE>",
  "scheduleCron": "<SCHEDULE_CRON>",
  "businessObjective": "<BUSINESS_OBJECTIVE>",
  "status": "active",
  "createdByAgent": "<your agent id>",
  "componentPackage": "<git URL#semver:tag or 'payload' if you used path B>"
}
```

Register AFTER the first successful manual run, not before. That way `pipelines` is a record of pipelines that actually worked.

## 4. Report back to the user

A good report has four elements:

1. **What you built** — pipeline id, target table, schedule.
2. **Evidence it works** — first-run record count + a couple of sample records.
3. **How the funnel consumes it** — the REST URL(s) to hit. For table `ContractorRegistration`:
   - `GET $CLI_APP_URL/ContractorRegistration/?limit=100`
   - `GET $CLI_APP_URL/ContractorRegistration/?filter={"state":"CO"}`
   - WebSocket subscription: `wss://<cluster>/ContractorRegistration`
4. **What's next in the human queue** — if any sources were filed for human action during this work, list them with the specific next step.

## 5. Expected final state in Harper

```
GET /pipelines/<PIPELINE_ID>
   → { ..., status: "active", lastRunStatus: "ok", lastRunRecords: >0 }

GET /<TARGET_TABLE>/
   → non-empty list

GET /pending_human_action/?filter={"status":"open"}
   → any blockers the user needs to address
```

If all three are true, the run is done. Say so explicitly in your reply.
