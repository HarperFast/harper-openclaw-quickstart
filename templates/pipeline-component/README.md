# Pipeline component template

This is the template OpenClaw copies + fills in once per data source. Placeholders are written as `{{UPPERCASE_SNAKE_CASE}}` so the agent has an obvious find-and-replace target.

**When OpenClaw uses this template, it renders these placeholders:**

| Placeholder | Example | Description |
|---|---|---|
| `{{PIPELINE_ID}}` | `usgs-earthquakes` | kebab-case id, unique per cluster. Used as component name and `Pipeline.id`. |
| `{{PIPELINE_ID_PASCAL}}` | `UsgsEarthquakes` | PascalCase version, used for JS class names. |
| `{{TARGET_TABLE}}` | `Earthquake` | PascalCase table name the ingested records land in. Singular. |
| `{{TARGET_TABLE_FIELDS}}` | see below | GraphQL fields, one per line, matching records returned by the source. |
| `{{PRIMARY_KEY_FIELD}}` | `id` | field in `{{TARGET_TABLE_FIELDS}}` with `@primaryKey`. |
| `{{SOURCE_NAME}}` | `USGS Earthquake Catalog` | human label. |
| `{{SOURCE_URL}}` | `https://earthquake.usgs.gov/fdsnws/event/1/query` | base URL. |
| `{{SCHEDULE_CRON}}` | `*/15 * * * *` | cron expression. |
| `{{BUSINESS_OBJECTIVE}}` | `demo pipeline for quickstart` | the user prompt that triggered this. |
| `{{FETCH_FN_BODY}}` | see below | a JS snippet returning an array of records. Must be self-contained; can use `fetch`. |

## Rules for filling in the template

1. **Primary key must be stable across runs.** If the source returns an `id` or `eventId`, use that. Otherwise synthesize one from fields guaranteed stable (e.g. `${date}-${subject}`). Never use a timestamp of the fetch itself.
2. **All `@indexed` fields must be fields that callers of the downstream funnel will actually filter by.** Don't over-index.
3. **`{{FETCH_FN_BODY}}` must be pure in → out.** No side effects. Returns `Promise<Record[]>`. Throw on HTTP errors.
4. **Dedupe on primary key.** The template uses `put` which upserts, so re-ingesting the same record is safe.
5. **Honor rate limits.** If the source publishes one, bake a delay into `{{FETCH_FN_BODY}}` (e.g. between pages) — don't rely on the cron alone.

## Example `{{TARGET_TABLE_FIELDS}}`

```graphql
	id: ID @primaryKey
	magnitude: Float @indexed
	place: String @indexed
	time: String @indexed
	url: String
```

## Example `{{FETCH_FN_BODY}}`

```javascript
	const url = 'https://earthquake.usgs.gov/fdsnws/event/1/query' +
		'?format=geojson&starttime=' + new Date(Date.now() - 3600_000).toISOString();
	const res = await fetch(url);
	if (!res.ok) throw new Error('USGS ' + res.status);
	const body = await res.json();
	return body.features.map(f => ({
		id: f.id,
		magnitude: f.properties.mag,
		place: f.properties.place,
		time: new Date(f.properties.time).toISOString(),
		url: f.properties.url,
	}));
```
