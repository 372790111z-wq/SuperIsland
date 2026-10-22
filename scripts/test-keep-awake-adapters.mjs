#!/usr/bin/env node
// Fixture contract checks, not a claim of real provider integration acceptance.
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHmac, createHash} from 'node:crypto';
const executable = resolve(process.argv[2] || 'build/KA1Final/Build/Products/Debug/KeepAwakeEventTool');
const root = await mkdtemp(join(tmpdir(), 'KA1-adapter-fixtures-'));
const originalInterval = globalThis.setInterval, originalClear = globalThis.clearInterval;
const callbacks = new Set();
globalThis.setInterval = callback => { callbacks.add(callback); return {unref(){}, callback}; };
globalThis.clearInterval = timer => { if (timer) callbacks.delete(timer.callback); };
try {
  for (const source of ['opencode', 'pi']) {
    const inbox = join(root, source); await mkdir(inbox, {mode: 0o700});
    const credential = join(root, source + '.json'), key = Buffer.alloc(32, 17), generation = 'fixture-generation';
    await writeFile(credential, JSON.stringify({source, generation, key: key.toString('base64'), inbox}), {mode: 0o600});
    let code = await readFile(`SuperIsland/Resources/KeepAwakeAdapters/${source}.js`, 'utf8');
    code = code.replace('__SUPERISLAND_TOOL__', JSON.stringify(executable)).replace('__SUPERISLAND_CREDENTIAL__', JSON.stringify(credential));
    const file = join(root, source + '.mjs'); await writeFile(file, code);
    const adapter = await import(pathToFileURL(file));
    const waitFor = async (state, minimum = 1) => {
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline) {
        const names = await readdir(inbox);
        const rows = await Promise.all(names.map(async name => JSON.parse(await readFile(join(inbox, name), 'utf8'))));
        if (rows.length >= minimum && rows.some(row => row.event.state === state)) return;
        await new Promise(r => setTimeout(r, 30));
      }
      throw new Error(`${source}: timed out waiting for ${state}`);
    };
    let finish;
    if (source === 'opencode') {
      const plugin = await adapter.SuperIslandKeepAwake();
      await plugin.event({event:{type:'session.status', properties:{sessionID:'session-fixture', status:{type:'busy'}, prompt:'PRIVATE-CONTENT'}}});
      await waitFor('running');
      for (const callback of callbacks) callback();
      await waitFor('running', 2);
      await plugin.event({event:{type:'permission.asked', properties:{sessionID:'session-fixture'}}});
      await waitFor('waiting');
      finish = () => plugin.event({event:{type:'session.idle', properties:{sessionID:'session-fixture'}}});
    } else {
      const handlers = new Map();
      adapter.default({on(name, callback){handlers.set(name, callback);}});
      assert.equal(handlers.has('agent_end'), false, 'low-level run end must not become final completion');
      handlers.get('session_start')({}, {sessionManager:{getSessionId(){return 'session-fixture';}}});
      handlers.get('agent_start')({prompt:'PRIVATE-CONTENT'});
      await waitFor('running');
      handlers.get('agent_start')({retry:true});
      await waitFor('running', 2);
      for (const callback of callbacks) callback();
      finish = () => handlers.get('agent_settled')({messages:['PRIVATE-CONTENT']});
    }
    await finish();
    await waitFor(source === "pi" ? "completed" : "idle", 2);
    const files = await readdir(inbox); assert.ok(files.length >= 2, source);
    const events = [];
    for (const file of files) {
      const raw = await readFile(join(inbox, file), 'utf8');
      assert.ok(!raw.includes('PRIVATE-CONTENT')); assert.ok(!raw.includes('session-fixture'));
      const envelope = JSON.parse(raw), event = envelope.event;
      const timestamp = Number.isInteger(envelope.issuedAt) ? envelope.issuedAt.toFixed(1) : String(envelope.issuedAt);
      const fields = [generation, source, event.session, String(event.sequence), event.state, timestamp];
      if (event.taskID !== undefined || event.startsTask !== undefined) {
        fields.push('ka1.event-metadata.v1', event.taskID === undefined ? 'taskID:-' : 'taskID:' + Buffer.from(event.taskID, 'utf8').toString('base64'),
          event.startsTask === undefined ? 'startsTask:-' : 'startsTask:' + String(event.startsTask));
      }
      const bytes = fields.join('\n');
      assert.equal(typeof event.startsTask, 'boolean');
      if (source === 'pi' && event.state === 'completed') assert.match(event.taskID, /^[0-9a-f]{64}$/);
      assert.equal(createHmac('sha256', key).update(bytes).digest('base64'), envelope.mac);
      assert.equal(event.session, createHash('sha256').update('session-fixture').digest('hex'));
      events.push(event);
    }
    events.sort((a,b) => a.sequence - b.sequence);
    if (source === 'pi') {
      assert.equal(new Set(events.map(e => e.taskID)).size, 1, 'automatic retries belong to the same unsettled task');
      assert.equal(events.filter(e => e.startsTask).length, 1, 'only the first low-level run starts a task');
    }
    assert.equal(events.at(-1).state, source === 'pi' ? 'completed' : 'idle');
    callbacks.clear();
    console.log(`PASS ${source}: lifecycle, heartbeat, authenticated metadata, no private payload`);
  }
} finally {
  globalThis.setInterval = originalInterval; globalThis.clearInterval = originalClear;
  await rm(root, {recursive:true, force:true});
}
