const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function fixture(isWE1, settings = {}) {
  const calls = [];
  let module;
  const context = vm.createContext({
    SuperIsland: {
      host: { isWE1 },
      settings: { get: key => settings[key] ?? null },
      store: { get: () => null, set: () => {} },
      registerModule: value => { module = value; },
      log: () => {},
      notifications: { send: () => {} },
      http: { fetch: async (url, options) => {
        calls.push({ url, method: options.method });
        return { status: 200, data: { ok: true, sessions: [], state: 'Idle' } };
      } },
    },
    View: new Proxy({}, { get: () => () => ({}) }),
    console: { log: () => {}, warn: () => {}, error: () => {} },
    setInterval: () => 1, clearInterval: () => {},
    setTimeout: () => 2, clearTimeout: () => {},
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'index.js'), 'utf8'), context);
  return { calls, module, context };
}

async function settled() {
  for (let i = 0; i < 4; i++) await new Promise(resolve => setImmediate(resolve));
}

test('WE1 activation and reconnect never install or uninstall unselected CLI hooks', async () => {
  const f = fixture(true, { hooksClaudeCode: false, hooksCodex: false });
  f.module.onActivate();
  await settled();
  vm.runInContext('bridgeOnline = false; fetchState();', f.context);
  await settled();
  assert.equal(f.calls.some(call => call.url.includes('/hooks/')), false);
  assert.equal(f.calls.some(call => call.url.includes('/control/resume')), true);
  f.module.onDeactivate();
  await settled();
  assert.equal(f.calls.some(call => call.url.includes('/control/pause')), false);
});

test('only an explicit setting change installs or removes its selected CLI hook', async () => {
  const f = fixture(true);
  f.module.onSettingsChanged('hooksCodex', true);
  f.module.onSettingsChanged('hooksCodex', false);
  await settled();
  assert.deepEqual(f.calls.map(call => new URL(call.url).pathname + new URL(call.url).search), [
    '/hooks/install?agent=codex', '/hooks/uninstall?agent=codex',
  ]);
});

test('previously enabled WE1 hooks resume without changing the other CLI', async () => {
  const f = fixture(true, { hooksClaudeCode: true, hooksCodex: false });
  f.module.onActivate();
  await settled();
  const hooks = f.calls.filter(call => call.url.includes('/hooks/'));
  assert.ok(hooks.length > 0);
  assert.ok(hooks.every(call => call.url.endsWith('/hooks/install?agent=claude')));
  f.module.onDeactivate();
});

test('original host keeps its existing default hook behavior', async () => {
  const f = fixture(false);
  f.module.onActivate();
  await settled();
  assert.ok(f.calls.some(call => call.url.endsWith('/hooks/install?agent=claude')));
  assert.ok(f.calls.some(call => call.url.endsWith('/hooks/install?agent=codex')));
  f.module.onDeactivate();
});
