#!/usr/bin/env node
// Pre-flight: confirm the target cluster is reachable + authenticated
// before we hand the component to the Harper CLI.
//
// Runs with env loaded via `dotenv-cli`. Exits non-zero on any failure.

const { CLI_TARGET, CLI_TARGET_USERNAME, CLI_TARGET_PASSWORD } = process.env;

const fail = (msg) => {
	console.error(`\n✗ preflight: ${msg}\n`);
	process.exit(1);
};
const ok = (msg) => console.log(`  ✓ ${msg}`);

// --- 1. vars present ---
for (const [k, v] of Object.entries({ CLI_TARGET, CLI_TARGET_USERNAME, CLI_TARGET_PASSWORD })) {
	if (!v) fail(`${k} not set. Copy ~/.openclaw/secrets/harper.env into ./.env, or export the var.`);
}

// --- 2. shape sanity ---
if (!CLI_TARGET.startsWith('https://')) {
	fail(`CLI_TARGET must be https://. Got: ${CLI_TARGET}`);
}
if (CLI_TARGET.includes('localhost') || CLI_TARGET.includes('127.0.0.1')) {
	fail(`CLI_TARGET points at localhost. Fabric URLs are always remote.`);
}
ok('env vars present and shaped correctly');

// --- 3. cluster reachable + authenticated ---
const auth = Buffer.from(`${CLI_TARGET_USERNAME}:${CLI_TARGET_PASSWORD}`).toString('base64');
const controller = new AbortController();
const t = setTimeout(() => controller.abort(), 15_000);
let res;
try {
	res = await fetch(CLI_TARGET, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', Authorization: `Basic ${auth}` },
		body: JSON.stringify({ operation: 'describe_all' }),
		signal: controller.signal,
	});
} catch (err) {
	clearTimeout(t);
	fail(`could not reach ${CLI_TARGET}: ${err.message}. Check URL (port included?) and that the cluster is running.`);
}
clearTimeout(t);

if (res.status === 401) fail('authentication failed. Check CLI_TARGET_USERNAME / CLI_TARGET_PASSWORD.');
if (res.status >= 500) fail(`cluster returned ${res.status}. Fabric may be down or misconfigured.`);

const body = await res.text();
if (body.startsWith('<')) fail(`got HTML from ${CLI_TARGET} — this is a web UI, not the Operations API. Use the Application URL from the Fabric Config tab.`);

try {
	JSON.parse(body);
} catch {
	fail(`response is not JSON. First 200 chars: ${body.slice(0, 200)}`);
}

ok(`cluster reachable + authenticated (HTTP ${res.status})`);
console.log('');
