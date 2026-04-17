#!/usr/bin/env node
// Post-deploy verification: confirm harper-base's tables actually landed
// on Fabric. This catches "CLI reported success but the component went
// somewhere else" — the #1 silent failure.
//
// Retries up to 5 times, 5s apart — Fabric can need a beat after deploy.

// REST endpoint probes go against the Application URL, NOT the Ops API URL.
// On Fabric these are usually different host:port. The harperdb CLI uses
// CLI_TARGET (Ops API) for deploy_component; we use CLI_APP_URL here.
const { CLI_TARGET, CLI_APP_URL, CLI_TARGET_USERNAME, CLI_TARGET_PASSWORD } = process.env;

const fail = (msg) => {
	console.error(`\n✗ verify: ${msg}\n`);
	process.exit(1);
};
const ok = (msg) => console.log(`  ✓ ${msg}`);

if (!CLI_TARGET || !CLI_APP_URL || !CLI_TARGET_USERNAME || !CLI_TARGET_PASSWORD) {
	fail('required env vars missing (CLI_TARGET, CLI_APP_URL, CLI_TARGET_USERNAME, CLI_TARGET_PASSWORD)');
}

const auth = Buffer.from(`${CLI_TARGET_USERNAME}:${CLI_TARGET_PASSWORD}`).toString('base64');

async function checkTable(name) {
	const res = await fetch(`${CLI_APP_URL}/${name}/`, {
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
		for (const [t, code] of results) ok(`GET ${CLI_APP_URL}/${t}/ → ${code}`);
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
			`harper-base tables did not become reachable on ${CLI_APP_URL} after ${maxAttempts} attempts. ` +
				`Two common causes: (1) CLI_APP_URL is wrong — confirm it's the Application URL from the Fabric Config tab, ` +
				`not the Operations API URL. (2) The deploy actually landed somewhere else because CLI_TARGET was pointed ` +
				`at the wrong Ops API. See docs/troubleshooting.md → "Deploy succeeds but verify fails with 404 on /Pipeline/".`
		);
	}
}
