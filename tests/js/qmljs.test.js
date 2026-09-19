'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadQmlJs } = require('./qmljs');

test('SafeLog.js : chargement direct (pas de .import) et fonctions pures', () => {
    const SafeLog = loadQmlJs('qml/js/SafeLog.js');

    // safeErrorCode() normalise des codes d'erreur hétérogènes.
    assert.equal(SafeLog.safeErrorCode('timeout'), 'timeout');
    assert.equal(SafeLog.safeErrorCode(404), 'http_404');
    assert.equal(SafeLog.safeErrorCode({ status: 401 }), 'http_401');
    assert.equal(SafeLog.safeErrorCode(undefined, 'network_error'), 'network_error');
    assert.equal(SafeLog.safeErrorCode('valeur-inconnue', 'network_error'), 'network_error');

    // isPrivateIpv4Literal() reconnaît les plages RFC1918 / loopback / link-local.
    assert.equal(SafeLog.isPrivateIpv4Literal('192.168.1.10'), true);
    assert.equal(SafeLog.isPrivateIpv4Literal('10.0.0.5'), true);
    assert.equal(SafeLog.isPrivateIpv4Literal('8.8.8.8'), false);
    assert.equal(SafeLog.isPrivateIpv4Literal('999.1.1.1'), false);

    // extractHost() extrait l'hôte d'une URL, sans port ni user-info.
    assert.equal(SafeLog.extractHost('http://192.168.1.10:8096/web/'), '192.168.1.10');
    assert.equal(SafeLog.extractHost('https://mon-jellyfin.local/'), 'mon-jellyfin.local');
    assert.equal(SafeLog.extractHost('http://user@evil.example/'), '');

    // shortHash() est déterministe (même entrée => même sortie).
    assert.equal(SafeLog.shortHash('redefin'), SafeLog.shortHash('redefin'));
    assert.equal(SafeLog.shortHash('redefin').length, 8);
});

test('JellyfinPlaybackRouter.js : résolution récursive des .import', () => {
    // Ce module déclare :
    //   .import "JellyfinPlaybackCore.js" as JFCore
    //   .import "JellyfinPlaybackRevolution.js" as JFRevolution
    //   .import "JellyfinPlaybackDevialet.js" as JFDevialet
    //   .import "clientId.js" as ClientId
    // qui eux-mêmes importent d'autres modules (JellyfinPlaybackCoreUrl.js,
    // clientId.js...). Le charger avec succès et pouvoir appeler une de ses
    // fonctions pures prouve que loadQmlJs() résout bien tout l'arbre de
    // dépendances .import, relativement à chaque fichier, sans avoir besoin
    // de stubs Qt (ces modules ne touchent aucune API Qt à leur simple
    // chargement, seulement lors de l'appel de certaines fonctions réseau).
    const Router = loadQmlJs('qml/js/JellyfinPlaybackRouter.js');

    assert.equal(typeof Router.normalizePlaybackRuleMode, 'function');
    assert.equal(Router.normalizePlaybackRuleMode('DirectPlay'), 'directplay');
    assert.equal(Router.normalizePlaybackRuleMode('autre-chose'), 'smart');

    assert.equal(Router.isDtsAudioCodec('DTS'), true);
    assert.equal(Router.isDtsAudioCodec('aac'), false);
    assert.equal(Router.isTrueHdAudioCodec('dolby_truehd'), true);
    assert.equal(Router.fullTranscodeAudioNeedsAc3('mlp'), true);
    assert.equal(Router.fullTranscodeAudioNeedsAc3('aac'), false);
});

test('loadQmlJs : injection de stubs (Qt, Date.now)', () => {
    // Démonstration de l'injection de stubs même si SafeLog.js n'en a pas
    // besoin : on vérifie que les globales fournies dans `stubs` sont bien
    // visibles depuis le module chargé.
    const calls = [];
    const mod = loadQmlJs('qml/js/SafeLog.js', {
        stubs: {
            Qt: { md5: (s) => `md5(${s})` },
            Date: Object.assign(function (...a) { return new Date(...a); }, Date, {
                now: () => 1700000000000,
            }),
            XMLHttpRequest: class {
                open(...args) { calls.push(args); }
            },
        },
    });

    // Le module lui-même n'utilise pas ces globales, mais elles doivent
    // être accessibles depuis son contexte (même sandbox `vm`).
    assert.equal(mod.Qt.md5('x'), 'md5(x)');
    assert.equal(mod.Date.now(), 1700000000000);
    const req = new mod.XMLHttpRequest();
    req.open('GET', 'http://example.invalid/');
    assert.equal(calls.length, 1);

    // Et les fonctions réelles du module continuent de fonctionner.
    assert.equal(mod.safeErrorCode('timeout'), 'timeout');
});
