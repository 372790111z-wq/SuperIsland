const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function fixture(initial) {
  let snapshot = initial, module;
  const context = vm.createContext({
    SuperIsland: {
      system: { getAIUsage: () => snapshot },
      registerModule: value => { module = value; }
    },
    View: new Proxy({}, { get: (_, type) => (...args) => ({ type, args }) })
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../Extensions/ai-usage/index.js'), 'utf8'), context);
  return {
    set: next => { snapshot = next; },
    full: () => column(module.fullExpanded(), 'Codex'),
    fullAll: () => module.fullExpanded(),
    all: () => [module.compact(), module.expanded(), module.fullExpanded(), module.minimalCompact.leading(), module.minimalCompact.trailing()]
  };
}

function column(node, title) {
  if (!node || typeof node !== 'object') return null;
  if (node.type === 'vstack' && node.args[0].some(child => child.type === 'text' && child.args[0] === title)) return node;
  for (const value of Object.values(node)) {
    const found = column(value, title);
    if (found) return found;
  }
  return null;
}

function strings(node) {
  const result = [];
  function walk(value) {
    if (!value || typeof value !== 'object') return;
    if (value.type === 'text') result.push(value.args[0]);
    for (const child of Object.values(value)) walk(child);
  }
  walk(node);
  return result;
}

function ready(primary, secondary = null) {
  return { codex: { available: true, status: 'ready', primary, secondary, updatedAt: 1790000000 } };
}

test('a weekly-only API result never appears as a session quota', () => {
  const f = fixture(ready({ remainingPercent: 28, windowMinutes: 10080 }));
  const text = strings(f.full());
  assert.ok(text.includes('每周剩余 28%'));
  assert.equal(text.some(s => /Session|会话|小时剩余/.test(s)), false);
});

test('both actual windows keep their durations and the smaller remaining value is summarized', () => {
  const f = fixture(ready({ usedPercent: 10, windowMinutes: 300 }, { remainingPercent: 28, windowMinutes: 10080 }));
  const text = strings(f.full());
  assert.ok(text.includes('5 小时剩余 90%'));
  assert.ok(text.includes('每周剩余 28%'));
  assert.ok(text.includes('28%'));
});

test('Claude remains visible and independent while Codex is unavailable', () => {
  const f = fixture({
    codex: { available: false, status: 'unavailable', errorCode: 'timeout' },
    claude: { available: true, remainingPercent: 45, weeklyRemainingPercent: 60, currentSessionRemainingPercent: 45 }
  });
  const text = strings(column(f.fullAll(), 'Claude'));
  assert.ok(text.includes('45%'));
  assert.ok(text.includes('Week 60%'));
  assert.ok(text.includes('Session 45%'));
  assert.equal(text.some(s => s.includes('超时')), false);
  assert.ok(strings(f.full()).includes('--'));
});

test('temporary failure retains the supplied last good number with a visible delay label, then clears the label on recovery', () => {
  const snapshot = ready({ remainingPercent: 28, windowMinutes: 10080 });
  const f = fixture(snapshot);
  snapshot.codex.status = 'stale';
  snapshot.codex.errorCode = 'timeout';
  const stale = strings(f.all());
  assert.ok(stale.includes('28%'));
  assert.ok(stale.includes('更新延迟'));
  assert.ok(stale.includes('延迟'));
  f.set(ready({ remainingPercent: 27, windowMinutes: 10080 }));
  const restored = strings(f.all());
  assert.ok(restored.includes('27%'));
  assert.equal(restored.some(s => s.includes('延迟')), false);
});

test('an auth error does not show previously cached values as usable', () => {
  const snapshot = ready({ remainingPercent: 28, windowMinutes: 10080 });
  snapshot.codex.available = false;
  snapshot.codex.status = 'unavailable';
  snapshot.codex.errorCode = 'auth';
  const text = strings(fixture(snapshot).full());
  assert.ok(text.includes('--'));
  assert.ok(text.includes('登录已失效，请重新登录 Codex'));
  assert.equal(text.some(s => s.includes('28%')), false);
});

test('empty and malformed usage cannot turn into zero use or unlimited quota', () => {
  for (const remainingPercent of [null, undefined, '', ' ', true, {}, NaN, Infinity, -1, 101]) {
    const snapshot = ready({ remainingPercent, windowMinutes: 10080 });
    snapshot.codex.unlimited = true;
    const text = strings(fixture(snapshot).full());
    assert.ok(text.includes('--'));
    assert.equal(text.some(s => /100%|∞/.test(s)), false);
  }
});

test('zero remaining is valid and stays distinguishable from missing data', () => {
  const text = strings(fixture(ready({ remainingPercent: 0, windowMinutes: 300 })).full());
  assert.ok(text.includes('0%'));
  assert.ok(text.includes('5 小时剩余 0%'));
});

test('loading and a first-request timeout explain the empty state', () => {
  const f = fixture({ codex: { available: false, status: 'loading' } });
  assert.ok(strings(f.full()).includes('读取中'));
  f.set({ codex: { available: false, status: 'unavailable', errorCode: 'timeout' } });
  assert.ok(strings(f.full()).includes('请求超时，稍后重试'));
});
