# `SourceCandidate` schema

Used by step 1 of the `harper-pipeline-builder` skill.

```typescript
type SourceCandidate = {
  /** short, kebab-case id. Becomes the default PIPELINE_ID. */
  id: string;
  /** human label. e.g. "USGS Earthquake Catalog" */
  name: string;
  /** what kind of entity does this source supply? e.g. "earthquake", "contractor registration" */
  entity: string;
  /** base URL you've actually verified responds */
  apiBaseUrl: string;
  /** one example endpoint that returns data */
  sampleEndpoint: string;
  /** result of actually calling sampleEndpoint during research */
  sampleResponse: {
    httpStatus: number;
    topLevelKeys: string[];
    firstRecord: Record<string, unknown> | null;
    recordCount: number;
  };
  /** auth requirement */
  auth: "none" | "api_key" | "oauth" | "paid" | "login_session" | "unknown";
  /** URL where a human would obtain credentials, if any */
  authSignupUrl?: string;
  /** terms-of-service classification */
  tos: "permitted" | "ambiguous" | "prohibited" | "unknown";
  /** link to the ToS you read */
  tosUrl?: string;
  /** known rate limits, or "unknown" */
  rateLimit?: string;
  /** refresh cadence of the source itself (how often new data appears upstream) */
  upstreamCadence?: string;
  /** fitness score 0–10 for Harper pipeline ingestion */
  fitnessScore: number;
  /** why this score */
  fitnessReason: string;
};
```

## Example

```json
{
  "id": "usgs-earthquakes",
  "name": "USGS Earthquake Catalog",
  "entity": "earthquake",
  "apiBaseUrl": "https://earthquake.usgs.gov/fdsnws/event/1/",
  "sampleEndpoint": "https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&limit=1",
  "sampleResponse": {
    "httpStatus": 200,
    "topLevelKeys": ["type", "metadata", "features", "bbox"],
    "firstRecord": { "id": "us7000abcd", "properties": { "mag": 4.3, "place": "..." } },
    "recordCount": 1
  },
  "auth": "none",
  "tos": "permitted",
  "tosUrl": "https://www.usgs.gov/information-policies-and-instructions/",
  "rateLimit": "no documented limit; be polite",
  "upstreamCadence": "continuous",
  "fitnessScore": 10,
  "fitnessReason": "Public, documented, no auth, canonical geojson, ideal for pipeline ingest."
}
```
