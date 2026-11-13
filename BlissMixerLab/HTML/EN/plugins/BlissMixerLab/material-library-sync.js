(function (root) {
    'use strict';
    async function resolvePlayerLibrary(command, id) {
        const selected = (await command(id, ['playerpref', 'libraryId', '?']))._p2;
        if (selected) return selected;
        return (await command('', ['pref', 'libraryId', '?']))._p2;
    }
    function createSynchronizer(env, initial) {
        let config = initial, player = null, generation = 0, applying = false, pending = 0, reading = false;
        let known = null;
        let writeQueue = Promise.resolve();
        const normalize = value => value && value !== '0' ? String(value) : '-1';
        async function read() {
            const id = env.getPlayer(), token = generation;
            if (!config.toBrowser || !env.isCompatible() || !id || pending || reading || !env.isVisible()) return;
            reading = true;
            try {
                const value = normalize(await env.readPlayerLibrary(id));
                if (id !== env.getPlayer() || token !== generation || pending) return;
                known = value;
                if (normalize(env.getBrowsingLibrary()) !== value) {
                    applying = true;
                    try { env.applyBrowsingLibrary(value); } finally { applying = false; }
                }
            } catch (error) { env.reportError(error); }
            finally { reading = false; }
        }
        function playerChanged() { player = env.getPlayer(); known = null; generation++; return read(); }
        function libraryChanged() {
            const id = env.getPlayer(), desired = normalize(env.getBrowsingLibrary());
            if (!config.toPlayer || !env.isCompatible() || applying || !id || id !== player || desired === known) return;
            generation++; known = desired; pending++;
            writeQueue = writeQueue.then(() => config.toPlayer && env.isCompatible() ? env.writePlayerLibrary(id, desired) : undefined)
                .catch(error => { env.reportError(error); known = null; })
                .finally(() => { pending--; });
        }
        function serverChanged(id, value) {
            if (id !== env.getPlayer() || pending || !env.isCompatible()) return;
            if (!value || value === '0') { generation++; read(); return; }
            generation++; known = normalize(value);
            if (config.toBrowser) {
                applying = true;
                try { env.applyBrowsingLibrary(known); } finally { applying = false; }
            }
        }
        return {
            setConfig(next) { config = next || {}; generation++; },
            async start() {
                env.on('playerChanged', playerChanged);
                env.on('libraryChanged', libraryChanged);
                env.on('playerLibraryChanged', serverChanged);
                env.on('reconnect', read);
                env.startTimer(read);
                await playerChanged();
            },
        };
    }
    if (typeof module !== 'undefined' && module.exports) module.exports = { createSynchronizer, resolvePlayerLibrary };
    if (typeof window === 'undefined') return;
    async function startBrowser() {
        if (typeof store === 'undefined' || typeof bus === 'undefined' || !bus.$store || lmsOptions.setPlayerLibrary) return;
        try {
            async function command(id, args) {
                const response = await lmsCommand(id, args);
                if (!response || !response.data || response.data.error || !response.data.result) {
                    throw new Error('Lyrion rejected the library synchronization request');
                }
                return response.data.result;
            }
            let config = (await command('', ['pref', 'plugin.blissmixerlab:material_sync_config', '?']))._p2 || {};
            if (!config.toPlayer && !config.toBrowser) return;
            function findServer(c) {
                if (!c) return null;
                if (c.$options && c.$options._componentTag === 'lms-server') return c;
                for (const child of c.$children || []) { const found = findServer(child); if (found) return found; }
                return null;
            }
            const server = findServer(app);
            if (!server) throw new Error('Material server component not found');
            const listeners = {};
            const original = server.handlePlayerPrefs;
            server.handlePlayerPrefs = function (id, data) {
                original.call(this, id, data);
                if (data && data[0] === 'prefset' && data[1] === 'server' && data[2] === 'libraryId' && listeners.playerLibraryChanged) listeners.playerLibraryChanged(id, data[3]);
            };
            let sync;
            let checkingConfig = false;
            const env = {
                getPlayer: () => store.state.player && store.state.player.id,
                getBrowsingLibrary: () => store.state.library,
                isVisible: () => document.visibilityState !== 'hidden',
                isCompatible: () => !lmsOptions.setPlayerLibrary,
                readPlayerLibrary: id => resolvePlayerLibrary(command, id),
                writePlayerLibrary: (id, value) => command(id, ['material-skin-client', 'set-lib', 'id:' + value]),
                applyBrowsingLibrary: value => store.commit('setLibrary', value),
                on: (name, fn) => {
                    if (name === 'playerLibraryChanged') listeners[name] = fn;
                    else if (name === 'reconnect') {
                        bus.$on('networkStatus', connected => { if (connected) fn(); });
                        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') fn(); });
                    } else bus.$on(name, fn);
                },
                startTimer: fn => {
                    const timer = setInterval(async () => {
                    if (document.visibilityState === 'hidden' || checkingConfig) return;
                    checkingConfig = true;
                    try {
                        const next = (await command('', ['pref', 'plugin.blissmixerlab:material_sync_config', '?']))._p2 || {};
                        if (next.toPlayer !== config.toPlayer || next.toBrowser !== config.toBrowser) {
                            config = next;
                            sync.setConfig(config);
                            if (!config.toPlayer && !config.toBrowser) clearInterval(timer);
                        }
                        await fn();
                    } catch (error) {
                        config = {};
                        sync.setConfig(config);
                        env.reportError(error);
                    } finally { checkingConfig = false; }
                    }, 3000);
                },
                reportError: error => console.error('[Bliss Mixer Lab library sync]', error),
            };
            sync = createSynchronizer(env, config);
            await sync.start();
        } catch (error) { console.error('[Bliss Mixer Lab library sync]', error); }
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startBrowser, { once: true });
    else startBrowser();
}(typeof globalThis !== 'undefined' ? globalThis : this));
