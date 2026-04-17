// harper-base/resources.js
//
// Registry + human-escape-hatch endpoints for the OpenClaw→Harper pipeline-builder
// pattern. Matches the canonical patterns from Harper's harper-best-practices skill
// (ship with `npm create harper@latest`). Specifically:
//
//   - Import { Resource, tables } from 'harperdb' (rules/custom-resources.md).
//   - POST handler takes a single `data` argument, the request body
//     (matches application-template/resources.js MyCustomResource.post pattern;
//      matches threadServer.js dispatch: l.post(target, body, context) → the
//      user's single-arg handler receives body as first positional).
//   - Access tables by GraphQL type name (no @table(table:) overrides in the
//     companion schema.graphql — rules/adding-tables-with-schemas.md).
//
// Endpoints:
//   POST /PipelineRegister         record a new pipeline (upsert by id)
//   POST /PipelineRunReport        update lastRunAt / lastRunStatus / lastRunRecords
//   POST /FlagHumanAction          file a PendingHumanAction entry

import { Resource, tables } from 'harperdb';

const now = () => new Date().toISOString();

export class PipelineRegister extends Resource {
    async post(data) {
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
    async post(data) {
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
    async post(data) {
        const id = data?.id ?? crypto.randomUUID();
        const record = {
            id,
            sourceName: data?.sourceName ?? '',
            sourceUrl: data?.sourceUrl ?? '',
            businessObjective: data?.businessObjective ?? '',
            blocker: data?.blocker ?? 'other',
            blockerDetail: data?.blockerDetail ?? '',
            suggestedNextStep: data?.suggestedNextStep ?? '',
            status: 'open',
            createdAt: now(),
            createdByAgent: data?.createdByAgent ?? '',
        };
        await tables.PendingHumanAction.put(id, record);
        return { ok: true, id };
    }
}
