const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { createSynchronizer, resolvePlayerLibrary } = require('../BlissMixerLab/HTML/EN/plugins/BlissMixerLab/material-library-sync.js');

function environment(config) {
    const calls = [], listeners = {}, server = { library: 'jazz' };
    let current = 'jazz';
    const env = {
        getPlayer: () => 'kitchen',
        getBrowsingLibrary: () => current,
        isVisible: () => true,
        isCompatible: () => true,
        readPlayerLibrary: async () => server.library,
        writePlayerLibrary: async (_id, value) => { calls.push(value); server.library = value; },
        applyBrowsingLibrary: value => { current = value; },
        on: (event, fn) => { listeners[event] = fn; },
        startTimer: fn => { listeners.timer = fn; },
        reportError: error => { throw error; },
    };
    const sync = createSynchronizer(env, config);
    return { sync, env, server, calls, listeners, get current() { return current; }, select(value) { current = value; listeners.libraryChanged(); } };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
for (const toPlayer of [false, true]) for (const toBrowser of [false, true]) {
    test(`directions player=${toPlayer} browser=${toBrowser}`, async () => {
        const x = environment({ toPlayer, toBrowser });
        await x.sync.start();
        x.select('rock'); await tick();
        assert.equal(x.calls.length, toPlayer ? 1 : 0);
        x.server.library = 'classical'; await x.listeners.timer(); await tick();
        assert.equal(x.current, toBrowser ? 'classical' : 'rock');
        assert.equal(x.calls.length, toPlayer ? 1 : 0, 'server update must not be echoed');
    });
}
test('hidden clients do not poll', async () => {
    const x = environment({ toPlayer: true, toBrowser: true });
    await x.sync.start(); x.env.isVisible = () => false; x.server.library = 'other';
    await x.listeners.timer(); assert.equal(x.current, 'jazz');
});
test('disabling writing stops subsequent picker changes without a reload', async () => {
    const x = environment({ toPlayer: true, toBrowser: true });
    await x.sync.start();
    x.sync.setConfig({ toPlayer: false, toBrowser: true });
    x.select('rock'); await tick();
    assert.equal(x.calls.length, 0);
});
test('an older server notification does not overwrite an in-flight user selection', async () => {
    const x = environment({ toPlayer: true, toBrowser: true });
    let finish;
    x.env.writePlayerLibrary = () => new Promise(resolve => { finish = resolve; });
    await x.sync.start();
    x.select('rock');
    x.listeners.playerLibraryChanged('kitchen', 'jazz');
    assert.equal(x.current, 'rock');
    await tick(); finish(); await tick();
});
test('rapid selections are written in order', async () => {
    const x = environment({ toPlayer: true, toBrowser: false });
    const started = [], finish = [];
    x.env.writePlayerLibrary = (_id, value) => {
        started.push(value);
        return new Promise(resolve => finish.push(resolve));
    };
    await x.sync.start();
    x.select('rock'); x.select('classical'); await tick();
    assert.deepEqual(started, ['rock']);
    finish[0](); await tick();
    assert.deepEqual(started, ['rock', 'classical']);
    finish[1](); await tick();
});
test('Material automatic player library option disables bridge operations', async () => {
    const x = environment({ toPlayer: true, toBrowser: true });
    await x.sync.start();
    x.env.isCompatible = () => false;
    x.select('rock'); await tick();
    x.server.library = 'classical'; await x.listeners.timer();
    assert.equal(x.calls.length, 0);
    assert.equal(x.current, 'rock');
});
test('unset player library inherits the server library', async () => {
    const queries = [];
    const value = await resolvePlayerLibrary(async (id, command) => {
        queries.push([id, command]);
        return { _p2: command[0] === 'playerpref' ? '' : 'global-library' };
    }, 'kitchen');
    assert.equal(value, 'global-library');
    assert.equal(queries.length, 2);
});
test('explicit player library takes precedence over server library', async () => {
    let count = 0;
    const value = await resolvePlayerLibrary(async () => { count++; return { _p2: '-1' }; }, 'kitchen');
    assert.equal(value, '-1'); assert.equal(count, 1);
});
test('removing player library re-reads the inherited server library', async () => {
    const x = environment({ toPlayer: false, toBrowser: true });
    await x.sync.start();
    x.server.library = 'inherited-global';
    x.listeners.playerLibraryChanged('kitchen', '');
    await tick();
    assert.equal(x.current, 'inherited-global');
});
test('browser adapter reads Lab settings and applies a player notification', async () => {
    const source = fs.readFileSync(path.join(__dirname, '../BlissMixerLab/HTML/EN/plugins/BlissMixerLab/material-library-sync.js'), 'utf8');
    const events = {}, server = { $options: { _componentTag: 'lms-server' }, $children: [], handlePlayerPrefs() {} };
    const store = { state: { player: { id: 'kitchen' }, library: 'old' }, commit(_name, value) { this.state.library = value; if (events.libraryChanged) events.libraryChanged(); } };
    const context = {
        window: {}, app: { $children: [server] }, store,
        bus: { $store: store, $on(name, fn) { events[name] = fn; } },
        document: { readyState: 'complete', visibilityState: 'visible', addEventListener() {} },
        lmsOptions: { setPlayerLibrary: false }, setInterval() {}, clearInterval() {}, console,
        lmsCommand: async (_id, args) => ({ data: { result: { _p2: args[0] === 'pref' ? { toPlayer: 1, toBrowser: 1 } : 'jazz' } } }),
    };
    vm.runInNewContext(source, context); await tick(); await tick();
    assert.equal(store.state.library, 'jazz');
    server.handlePlayerPrefs('kitchen', ['prefset', 'server', 'libraryId', 'rock']);
    assert.equal(store.state.library, 'rock');
});
