'use strict';

/*
 * Verrou transport pendant un rechargement de source.
 *
 * Contrat : tant qu'une négociation est en vol, qu'un reset dur tourne ou que
 * l'URL du média est en cours de remplacement, reculer / avancer / scruber /
 * sauter de chapitre sont ignorés. En revanche, ni le démarrage initial, ni un
 * simple buffering, ni Retour / Stop / Lecture-Pause ne doivent être bloqués.
 */

const test = require('node:test');
const assert = require('node:assert');

const { loadQmlJs } = require('./qmljs');

const H = loadQmlJs('qml/js/playerOverlayHelper.js');

function fakeRoot(overrides) {
    const root = {
        _tearingDownPlayer: false,
        serverPrerollBlocking: false,
        _sourceResetActive: false,
        videoLoadingGate: false,
        _videoLoadingReason: '',
    };
    return Object.assign(root, overrides || {});
}

test('les raisons de rechargement sont exactement celles attendues', () => {
    assert.strictEqual(H.isReloadLoadingReason('negotiation'), true);
    assert.strictEqual(H.isReloadLoadingReason('hard-source-reset'), true);
    assert.strictEqual(H.isReloadLoadingReason('fresh-directplay-reset'), true);
    assert.strictEqual(H.isReloadLoadingReason('media-url-swap'), true);
});

test('les raisons d\'ouverture initiale et de buffering ne verrouillent pas', () => {
    ['', 'completed', 'item-changed', 'status-loading', 'initial-negotiation',
     'media-url-first', 'server-preroll-status-loading'].forEach((reason) => {
        assert.strictEqual(H.isReloadLoadingReason(reason), false, reason);
    });
    assert.strictEqual(H.isReloadLoadingReason(null), false);
    assert.strictEqual(H.isReloadLoadingReason(undefined), false);
});

test('un reset de source verrouille quelle que soit la gate', () => {
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ _sourceResetActive: true })), true);
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ _sourceResetActive: true, videoLoadingGate: true,
                                          _videoLoadingReason: 'status-loading' })), true);
});

test('une négociation de rechargement en vol verrouille', () => {
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: true,
                                           _videoLoadingReason: 'negotiation' })), true);
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: true,
                                           _videoLoadingReason: 'media-url-swap' })), true);
});

test('le démarrage initial ne verrouille pas', () => {
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: true,
                                           _videoLoadingReason: 'initial-negotiation' })), false);
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: true,
                                           _videoLoadingReason: 'media-url-first' })), false);
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: true,
                                           _videoLoadingReason: 'completed' })), false);
});

test('une gate relâchée ne verrouille pas, même avec une raison de rechargement', () => {
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: false,
                                           _videoLoadingReason: 'negotiation' })), false);
});

test('un buffering en cours de lecture ne verrouille pas', () => {
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ videoLoadingGate: true,
                                           _videoLoadingReason: 'status-loading' })), false);
});

test('destruction et pré-roll ne verrouillent jamais', () => {
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ _sourceResetActive: true,
                                           _tearingDownPlayer: true })), false);
    assert.strictEqual(
        H.reloadBlocksTransport(fakeRoot({ _sourceResetActive: true,
                                           serverPrerollBlocking: true })), false);
    assert.strictEqual(H.reloadBlocksTransport(null), false);
});
