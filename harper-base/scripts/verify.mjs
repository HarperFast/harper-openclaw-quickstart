#!/usr/bin/env node
// Post-deploy verification: confirm harper-base's tables actually landed
// on Fabric. This catches "CLI reported success but the component went
// somewhere else" — the #1 silent failure.
//
// Retries up to 5 times, 5s apart — Fabric can need a beat after deploy.

const { CLI_TARGET, CLI_TARGET_USERNAME, CLI_TARGET_PASSWORD } = process.env;

const fail = (msg) => {
	console.error(`\n✗ verify: ${msg}\n`);
	process.exit(1);
};
const ok = (msg) => console.log(`  ✓ ${msg}`);

if (!CLI_TARGET || !CLI_TARGET_USERNAME || !CLI_TARGET_PASSWORD) {
	fail('required env vars missing');
}

const auth = Buffer.from(`${CLI_TARGET_USERNAME}:${CLI_TARGET_PASSWORD}`).toString('base64');

async function checkTable(name) {
	const res = await fetch(`${CLI_TARGET}/${name}/`, {
		headers: { Authorization: `Basic ${auth}` },
	});
	return res.status;
}

const tables = ['Pipeline', 'PendingHumanAction'];
const maxAttempts = 5;

for (let attempt = 1; attempt <= maxAttempts; attempt++) {
	const results = await Promise.all(tables.map(async (t) => [t, await checkTable(t)]));
	const allOk = results.every(([, code]) => code === 200);
	if (allOk) {
		for (const [t, code] of results) ok(`GET ${CLI_TARGET}/${t}/ → ${code}`);
		console.log('\n  harper-base verified. Ready for pipelines.\n');
		process.exit(0);
	}
	if (attempt < maxAttempts) {
		console.log(`  attempt ${attempt}/${maxAttempts} — tables not yet reachable, retrying in 5s`);
		for (const [t, code] of results) console.log(`    ${t}: HTTP ${code}`);
		await new Promise((r) => setTimeout(r, 5000));
	} else {
		console.error('');
		for (const [t, code] of results) console.error(`    ${t}: HTTP ${code}`);
		fail(
			`harper-base tables did not become reachable on ${CLI_TARGET} after ${maxAttempts} attempts. ` +
				`The deploy may have landed somewhere other than your Fabric cluster (a local Harper? wrong CLI_TARGET?). ` +
				`See docs/troubleshooting.md → "Deploy says 'Successfully deployed' but nothing shows up on Fabric".`
		);
	}
}
