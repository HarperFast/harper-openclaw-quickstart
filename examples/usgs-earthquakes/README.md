# usgs-earthquakes

A fully-rendered version of the `pipeline-component` template, built for the USGS Earthquake Catalog. Use this as a reference when OpenClaw scaffolds its own pipelines.

**Source:** https://earthquake.usgs.gov/fdsnws/event/1/
**Schedule:** every 15 minutes
**Target table:** `Earthquake`
**Why this source for hello-world:** public, no auth, stable JSON, gives you a visible stream of data immediately.

## Deploy it

```bash
cp .env.example .env
# fill in your Harper Fabric credentials
npm install
npm run deploy
```

Then trigger a first run:

```bash
curl -u $CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD \
     -X POST $CLI_APP_URL/UsgsEarthquakesRun -d '{}'
# → {"runAt":"...","status":"ok","records":147}

curl -u $CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD \
     "$CLI_APP_URL/Earthquake/?limit=3"
```

Then register it in the `pipelines` table (if you deployed `harper-base/`):

```bash
curl -u $CLI_TARGET_USERNAME:$CLI_TARGET_PASSWORD \
     -H 'Content-Type: application/json' \
     -X POST $CLI_APP_URL/PipelineRegister \
     -d '{
           "id": "usgs-earthquakes",
           "sourceName": "USGS Earthquake Catalog",
           "sourceUrl": "https://earthquake.usgs.gov/fdsnws/event/1/",
           "targetTable": "Earthquake",
           "scheduleCron": "*/15 * * * *",
           "businessObjective": "hello-world pipeline for quickstart",
           "status": "active",
           "createdByAgent": "manual"
         }'
```
