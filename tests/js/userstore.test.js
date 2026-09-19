'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadQmlJs } = require('./qmljs');

const Store = loadQmlJs('qml/js/UserStore.js');

test('shouldDropStoredToken : rejets explicites du serveur => purge', () => {
    // Réponse 200 sans Id/Name : la session n'est plus reconnue.
    assert.equal(Store.shouldDropStoredToken('invalid_token'), true);
    // Le serveur refuse explicitement ce token.
    assert.equal(Store.shouldDropStoredToken('http_401'), true);
    assert.equal(Store.shouldDropStoredToken('http_403'), true);
    // Requête d'authentification refusée telle quelle : réessayer boucle.
    assert.equal(Store.shouldDropStoredToken('http_400'), true);
});

test('shouldDropStoredToken : pannes de transport => on garde le token', () => {
    assert.equal(Store.shouldDropStoredToken('network_error'), false);
    assert.equal(Store.shouldDropStoredToken('timeout'), false);
    assert.equal(Store.shouldDropStoredToken('cancelled'), false);
    assert.equal(Store.shouldDropStoredToken('parse_error'), false);
    assert.equal(Store.shouldDropStoredToken('too_large'), false);
});

test('shouldDropStoredToken : erreurs serveur 4xx non authentifiantes et 5xx', () => {
    // 404 : mauvais chemin/reverse-proxy, pas une révocation de session.
    assert.equal(Store.shouldDropStoredToken('http_404'), false);
    assert.equal(Store.shouldDropStoredToken('http_500'), false);
    assert.equal(Store.shouldDropStoredToken('http_502'), false);
    assert.equal(Store.shouldDropStoredToken('http_503'), false);
    assert.equal(Store.shouldDropStoredToken('http_504'), false);
});

test('shouldDropStoredToken : valeurs absentes ou inconnues => on garde le token', () => {
    assert.equal(Store.shouldDropStoredToken(undefined), false);
    assert.equal(Store.shouldDropStoredToken(null), false);
    assert.equal(Store.shouldDropStoredToken(''), false);
    assert.equal(Store.shouldDropStoredToken('quelque-chose-dinconnu'), false);
    assert.equal(Store.shouldDropStoredToken({}), false);
    assert.equal(Store.shouldDropStoredToken([]), false);
});

test('shouldDropStoredToken : formes brutes normalisées par SafeLog', () => {
    // Objet d'erreur du pont Jellyfin ({ code, message, status }).
    assert.equal(Store.shouldDropStoredToken({ code: 'http_401' }), true);
    assert.equal(Store.shouldDropStoredToken({ code: 'invalid_token' }), true);
    assert.equal(Store.shouldDropStoredToken({ code: 'network_error' }), false);
    assert.equal(Store.shouldDropStoredToken({ code: 'cancelled' }), false);

    // Statut HTTP seul (objet ou nombre).
    assert.equal(Store.shouldDropStoredToken({ status: 401 }), true);
    assert.equal(Store.shouldDropStoredToken({ status: 500 }), false);
    assert.equal(Store.shouldDropStoredToken(403), true);
    assert.equal(Store.shouldDropStoredToken(500), false);

    // Codes numériques sous forme de chaîne, tels que normalisés par SafeLog.
    assert.equal(Store.shouldDropStoredToken('401'), true);
    assert.equal(Store.shouldDropStoredToken('403'), true);
    assert.equal(Store.shouldDropStoredToken('404'), false);
});
