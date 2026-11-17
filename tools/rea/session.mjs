#!/usr/bin/env node
// Project-scoped REA MCP driver. Queue JSON requests under research/evidence/queue.
// This keeps one Ghidra import alive and retains complete replies without flooding chat.
import { mkdir, readdir, readFile, writeFile, rename } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rea = process.env.EDWARD_REA_ROOT || '/Volumes/FastSSD/github/clones/rea';
const { Client } = await import(pathToFileURL(join(rea, 'node_modules/@modelcontextprotocol/client/dist/index.mjs')));
const { StdioClientTransport } = await import(pathToFileURL(join(rea, 'node_modules/@modelcontextprotocol/client/dist/stdio.mjs')));
const evidence = join(root, 'research/evidence');
const queue = join(evidence, 'queue');
await mkdir(queue, { recursive: true });
const client = new Client({ name: 'edward-static-investigation', version: '1.0.0' });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [join(rea, 'scripts/rea.mjs'), 'mcp'],
  env: {
    ...process.env,
    GHIDRA_INSTALL_DIR: join(root, '.tools/ghidra_12.1.4_PUBLIC'),
    JAVA_HOME: join(root, '.tools/jdk-21.0.13+9/Contents/Home'),
    GHIDRA_HEADLESS_MAXMEM: '4G',
    REA_GHIDRA_STARTUP_TIMEOUT_MS: '1200000',
    // The default analyzer stalls in this target; see retained thread dump.
    REA_GHIDRA_DISABLED_ANALYZERS: process.env.REA_GHIDRA_DISABLED_ANALYZERS || 'Objective-C Message Analyzer',
    REA_ANALYSIS_PROVIDER: 'ghidra',
  },
  stderr: 'pipe',
});
const log = createWriteStream(join(evidence, 'rea-session.log'), { flags: 'a', mode: 0o600 });
transport.stderr?.pipe(log);
await client.connect(transport);
await writeFile(join(evidence, 'tool-catalog.json'), JSON.stringify(await client.listTools(), null, 2));
console.log('REA session ready; waiting for queued requests.');
let lastWork = Date.now();
let shutdown = false;
try {
  while (!shutdown && Date.now() - lastWork < 20 * 60 * 1000) {
    const pending = (await readdir(queue)).filter(x => x.endsWith('.request.json')).sort();
    if (!pending.length) { await new Promise(r => setTimeout(r, 500)); continue; }
    for (const file of pending) {
      let request;
      try { request = JSON.parse(await readFile(join(queue, file), 'utf8')); }
      catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      const id = file.replace('.request.json', '');
      if (request.name === '__shutdown') { await rename(join(queue, file), join(queue, id + '.done.json')); shutdown = true; break; }
      console.log(JSON.stringify({ id, operation: request.name, status: 'started' }));
      const started = Date.now();
      let result;
      try {
        result = await client.callTool({ name: request.name, arguments: request.arguments || {} }, { timeout: 1250000 });
      } catch (error) {
        result = { isError: true, error: { name: error.name, message: error.message } };
      }
      await writeFile(join(evidence, id + '.json'), JSON.stringify(result, null, 2), { mode: 0o600 });
      await rename(join(queue, file), join(queue, id + '.done.json'));
      console.log(JSON.stringify({ id, operation: request.name, status: result.isError ? 'error' : 'complete', seconds: (Date.now() - started) / 1000 }));
      lastWork = Date.now();
    }
  }
} finally {
  await client.close();
  log.end();
}
