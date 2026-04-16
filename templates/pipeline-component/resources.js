// Pipeline runtime for {{PIPELINE_ID}}.
//
// Flow:
//   1. Scheduled tick (cron {{SCHEDULE_CRON}}) fires `runPipeline()`.
//   2. `fetchFromSource()` calls {{SOURCE_URL}} and returns records.
//   3. Records are upserted into tables.{{TARGET_TABLE}} keyed on {{PRIMARY_KEY_FIELD}}.
//   4. A run report is posted back to the registry (PipelineRunReport).
//
// Everything OpenClaw-specific is in `fetchFromSource`. The rest of the file
// is canonical and should not be edited per-source.

import { Resource, tables } from 'harperdb';

const PIPELINE_ID = '{{PIPELINE_ID}}';
const SOURCE_NAME = '{{SOURCE_NAME}}';

// ---------------------------------------------------------------------------
// fetchFromSource: the only per-source code
// ---------------------------------------------------------------------------
async function fetchFromSource() {
{{FETCH_FN_BODY}}
}

// ---------------------------------------------------------------------------
// Shared ingestion machinery (do not edit per-source)
// ---------------------------------------------------------------------------
async function runPipeline() {
	const startedAt = new Date().toISOString();
	let status = 'ok';
	let count = 0;
	try {
		const records = await fetchFromSource();
		if (!Array.isArray(records)) {
			throw new Error('fetchFromSource() must return an array of records');
		}
		const ingestedAt = new Date().toISOString();
		for (const r of records) {
			const pk = r.{{PRIMARY_KEY_FIELD}};
			if (pk === undefined || pk === null) {
				status = 'partial';
				continue;
			}
			await tables.{{TARGET_TABLE}}.put(pk, {
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
	// Report back to the registry. Uses the Harper operations fetch; runs
	// inside the cluster so no auth needed for localhost.
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
		// Registry might not be deployed yet on first run; don't crash the pipeline.
	}
}

// ---------------------------------------------------------------------------
// Endpoint: POST /{{PIPELINE_ID_PASCAL}}Run — manual trigger for the agent to verify
// ---------------------------------------------------------------------------
export class {{PIPELINE_ID_PASCAL}}Run extends Resource {
	async post() {
		return runPipeline();
	}
	async get() {
		// Cheap health probe: returns the last-known run info from the registry.
		const reg = await tables.Pipeline.get(PIPELINE_ID);
		return reg ?? { pipelineId: PIPELINE_ID, status: 'unregistered' };
	}
}

// ---------------------------------------------------------------------------
// Scheduler: Harper auto-starts this module. We install a cron-ish interval.
// For production-grade scheduling, swap in `@harperdb/scheduler` or similar;
// this keeps the template dependency-free.
// ---------------------------------------------------------------------------
import { CronExpressionParser } from 'cron-parser';

let schedulerStarted = false;
function startScheduler() {
	if (schedulerStarted) return;
	schedulerStarted = true;

	const cron = '{{SCHEDULE_CRON}}';
	try {
		const it = CronExpressionParser.parse(cron);
		const scheduleNext = () => {
			const next = it.next().toDate();
			const ms = Math.max(1000, next.getTime() - Date.now());
			setTimeout(async () => {
				try { await runPipeline(); } catch { /* runPipeline already logged */ }
				scheduleNext();
			}, ms);
		};
		scheduleNext();
	} catch (err) {
		// eslint-disable-next-line no-console
		console.error('[pipeline ' + PIPELINE_ID + '] invalid cron "' + cron + '":', err);
	}
}

// Kick off on module load.
startScheduler();
