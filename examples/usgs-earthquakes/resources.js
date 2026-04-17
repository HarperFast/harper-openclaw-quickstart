// usgs-earthquakes pipeline.
//
// Fully-rendered from templates/pipeline-component/resources.js — compare side
// by side to see what {{PLACEHOLDER}} substitution looks like.
//
// `Resource` and `tables` are Harper-injected globals — do NOT import them
// from 'harperdb'. The import returns an empty module-time binding; the
// global is what the server populates after init.

import { CronExpressionParser } from 'cron-parser';

const PIPELINE_ID = 'usgs-earthquakes';
const SOURCE_NAME = 'USGS Earthquake Catalog';

async function fetchFromSource() {
	// Pull the last hour with overlap; upserts dedupe.
	const since = new Date(Date.now() - 3600_000).toISOString();
	const url =
		'https://earthquake.usgs.gov/fdsnws/event/1/query' +
		'?format=geojson&starttime=' + encodeURIComponent(since);
	const res = await fetch(url);
	if (!res.ok) throw new Error('USGS ' + res.status);
	const body = await res.json();
	if (!body?.features) throw new Error('USGS response missing features');

	return body.features.map((f) => ({
		id: f.id,
		magnitude: f.properties.mag,
		place: f.properties.place,
		time: new Date(f.properties.time).toISOString(),
		url: f.properties.url,
		tsunami: f.properties.tsunami ?? 0,
		felt: f.properties.felt ?? 0,
	}));
}

async function runPipeline() {
	const startedAt = new Date().toISOString();
	let status = 'ok';
	let count = 0;
	try {
		const records = await fetchFromSource();
		if (!Array.isArray(records)) {
			throw new Error('fetchFromSource() must return an array');
		}
		const ingestedAt = new Date().toISOString();
		for (const r of records) {
			if (r.id === undefined || r.id === null) {
				status = 'partial';
				continue;
			}
			await tables.Earthquake.put(r.id, {
				...r,
				_ingestedAt: ingestedAt,
				_sourcePipeline: PIPELINE_ID,
			});
			count++;
		}
	} catch (err) {
		status = 'error';
		// eslint-disable-next-line no-console
		console.error('[pipeline ' + PIPELINE_ID + '] run failed:', err);
	}
	await reportRun({ runAt: startedAt, status, records: count });
	return { runAt: startedAt, status, records: count };
}

async function reportRun({ runAt, status, records }) {
	try {
		await tables.Pipeline.patch(PIPELINE_ID, {
			lastRunAt: runAt,
			lastRunStatus: status,
			lastRunRecords: records,
			updatedAt: new Date().toISOString(),
		});
	} catch {
		/* harper-base may not be deployed yet */
	}
}

export class UsgsEarthquakesRun extends Resource {
	async post() {
		return runPipeline();
	}
	async get() {
		const reg = await tables.Pipeline.get(PIPELINE_ID);
		return reg ?? { pipelineId: PIPELINE_ID, status: 'unregistered' };
	}
}

// --- scheduler ---
let schedulerStarted = false;
(function startScheduler() {
	if (schedulerStarted) return;
	schedulerStarted = true;
	const cron = '*/15 * * * *';
	const it = CronExpressionParser.parse(cron);
	const scheduleNext = () => {
		const next = it.next().toDate();
		const ms = Math.max(1000, next.getTime() - Date.now());
		setTimeout(async () => {
			try { await runPipeline(); } catch { /* logged above */ }
			scheduleNext();
		}, ms);
	};
	scheduleNext();
})();
