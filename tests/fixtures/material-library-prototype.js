/* Experimental Material customization; not part of Material or Bliss Mixer Lab. */
(function () {
    'use strict';
    const all = '-1';
    let player = null;
    let applyingRemote = false;
    let knownLibrary = null;
    let generation = 0;
    let pendingWrites = 0;
    let reconciliationPending = false;

    function selectedPlayer() {
        return store.state.player && store.state.player.id;
    }
    function displayId(value) {
        return value && value !== '0' ? String(value) : all;
    }
    function applyLibrary(id) {
        knownLibrary = displayId(id);
        applyingRemote = true;
        try { store.commit('setLibrary', knownLibrary); }
        finally { applyingRemote = false; }
    }
    async function readPlayer() {
        const id = selectedPlayer();
        player = id;
        knownLibrary = null;
        const token = ++generation;
        if (!id) return;
        try {
            const response = await lmsCommand(id, ['playerpref', 'libraryId', '?']);
            if (token === generation && selectedPlayer() === id && response.data && response.data.result) {
                applyLibrary(response.data.result._p2);
            }
        } catch (error) { console.error('[library sync experiment] Cannot read player library', error); }
    }
    async function reconcile() {
        const id = selectedPlayer();
        if (document.visibilityState === 'hidden' || !id || id !== player || pendingWrites || reconciliationPending) return;
        const token = generation;
        reconciliationPending = true;
        try {
            const response = await lmsCommand(id, ['playerpref', 'libraryId', '?']);
            if (token === generation && id === selectedPlayer() && !pendingWrites && response.data && response.data.result) {
                const actual = displayId(response.data.result._p2);
                if (actual !== knownLibrary || actual !== displayId(store.state.library)) applyLibrary(actual);
            }
        } catch (error) { console.error('[library sync experiment] Cannot reconcile player library', error); }
        finally { reconciliationPending = false; }
    }
    function findServer(component) {
        if (!component) return null;
        if (component.$options && component.$options._componentTag === 'lms-server') return component;
        for (const child of component.$children || []) {
            const found = findServer(child);
            if (found) return found;
        }
        return null;
    }
    function start() {
        const server = typeof app !== 'undefined' && findServer(app);
        if (!server || typeof bus === 'undefined' || !bus.$store) {
            console.warn('[library sync experiment] Material is not ready; synchronization not started');
            return;
        }
        if (lmsOptions.setPlayerLibrary) {
            console.warn('[library sync experiment] Disable Material setting setPlayerLibrary to avoid conflicting behavior');
            return;
        }
        const original = server.handlePlayerPrefs;
        server.handlePlayerPrefs = function (id, data) {
            original.call(this, id, data);
            if (id === selectedPlayer() && data && data[0] === 'prefset' && data[1] === 'server' && data[2] === 'libraryId') {
                ++generation;
                applyLibrary(data[3]);
            }
        };
        bus.$on('playerChanged', readPlayer);
        bus.$on('networkStatus', function (connected) {
            if (connected) readPlayer();
        });
        bus.$on('libraryChanged', function () {
            const id = selectedPlayer();
            const desired = displayId(store.state.library);
            if (applyingRemote || !id || id !== player || desired === knownLibrary) return;
            ++generation;
            knownLibrary = desired;
            ++pendingWrites;
            lmsCommand(id, ['material-skin-client', 'set-lib', 'id:' + desired]).catch(function (error) {
                console.error('[library sync experiment] Cannot set player library', error);
                readPlayer();
            }).finally(function () { --pendingWrites; });
        });
        document.addEventListener('visibilitychange', function () {
            if (document.visibilityState === 'visible') reconcile();
        });
        setInterval(reconcile, 3000);
        readPlayer();
        console.info('[library sync experiment] Started');
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
    else start();
}());
