// harper-base/resources.js
//
// Small convenience resources OpenClaw calls. The tables themselves are
// already exported from schema.graphql (full REST CRUD for free). These
// resources give the agent a couple of ergonomic endpoints:
//
//   POST /PipelineRegister         record a new pipeline (upsert by id)
//   POST /PipelineRunReport        update lastRunAt / lastRunStatus / lastRunRecords
//   POST /FlagHumanAction          file a pending_human_action entry
//
// Keep these dumb. OpenClaw should do the thinking; these just persist.
//
// NOTE on globals: Harper v4.7+ injects `Resource` and `tables` into the
// module global scope at server init. Importing them from 'harperdb' returns
// the module-time binding, which for `tables` is NOT the same object the
// server populates at runtime — the import-time `tables` is always empty.
// Use the globals. Matches the canonical `application-template/resources.js`
// shipped inside the harperdb package.

const now = () => new Date().toISOString();

export class PipelineRegister extends Resource {
	async post(_target, data) {
		if (!data?.id) throw new Error('PipelineRegister requires `id`');

		const existing = await tables.Pipeline.get(data.id);
		const record = {
			id: data.id,
			sourceName: data.sourceName,
			sourceUrl: data.sourceUrl,
			targetTable: data.targetTable,
			scheduleCron: data.scheduleCron,
			businessObjective: data.businessObjective,
			status: data.status ?? 'active',
			createdAt: existing?.createdAt ?? now(),
			updatedAt: now(),
			createdByAgent: data.createdByAgent,
			componentPackage: data.componentPackage,
			notes: data.notes ?? '',
		};

		if (existing) {
			await tables.Pipeline.patch(data.id, record);
		} else {
			await tables.Pipeline.put(data.id, record);
		}
		return { ok: true, id: data.id, existed: Boolean(existing) };
	}
}

export class PipelineRunReport extends Resource {
	async post(_target, data) {
		if (!data?.id) throw new Error('PipelineRunReport requires `id`');
		await tables.Pipeline.patch(data.id, {
			lastRunAt: data.runAt ?? now(),
			lastRunStatus: data.status ?? 'ok',
			lastRunRecords: Number.isFinite(data.records) ? data.records : 0,
			updatedAt: now(),
		});
		return { ok: true };
	}
}

export class FlagHumanAction extends Resource {
	async post(_target, data) {
		const id = data?.id ?? crypto.randomUUID();
		const record = {
			id,
			sourceName: data.sourceName ?? '',
			sourceUrl: data.sourceUrl ?? '',
			businessObjective: data.businessObjective ?? '',
			blocker: data.blocker ?? 'other',
			blockerDetail: data.blockerDetail ?? '',
			suggestedNextStep: data.suggestedNextStep ?? '',
			status: 'open',
			createdAt: now(),
			createdByAgent: data.createdByAgent ?? '',
		};
		await tables.PendingHumanAction.put(id, record);
		return { ok: true, id };
	}
}
