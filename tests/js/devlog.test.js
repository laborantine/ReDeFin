'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadQmlJs } = require('./qmljs');

const SOURCE = path.join(__dirname, '..', '..', 'qml', 'js', 'DevLog.js');

function load(lines) {
  return loadQmlJs('qml/js/DevLog.js', {
    stubs: { console: { log: (m) => lines.push(m) } },
  });
}

test('le drapeau du dépôt est à false, sur la ligne exacte attendue par fbx-run.py et build.sh', () => {
  const src = fs.readFileSync(SOURCE, 'utf8');
  const matches = src.split('\n').filter((l) => l === 'var ENABLED = false;');
  assert.equal(matches.length, 1);
  assert.equal(src.includes('var ENABLED = true;'), false);
});

test('désactivé : log() ne produit rien et renvoie false', () => {
  const lines = [];
  const DevLog = load(lines);
  assert.equal(DevLog.ENABLED, false);
  assert.equal(DevLog.log('T1', 'message'), false);
  assert.deepEqual(lines, []);
});

test('activé : log() préfixe [RDF] et le tag', () => {
  const lines = [];
  const DevLog = load(lines);
  DevLog.ENABLED = true;
  assert.equal(DevLog.log('T8', 'loader ARM reason=negotiation'), true);
  assert.equal(DevLog.log('T9'), true);
  assert.deepEqual(lines, ['[RDF] T8 loader ARM reason=negotiation', '[RDF] T9 ']);
});

test('une console défaillante ne propage jamais d\'exception', () => {
  const DevLog = loadQmlJs('qml/js/DevLog.js', {
    stubs: { console: { log: () => { throw new Error('boom'); } } },
  });
  DevLog.ENABLED = true;
  assert.equal(DevLog.log('T1', 'x'), false);
});

test('maskUrl masque tous les jetons connus et rien d\'autre', () => {
  const DevLog = load([]);
  const url = 'http://h:8096/Videos/1/stream.mkv?ApiKey=SECRET1&AudioStreamIndex=2&api_key=SECRET2&X-Emby-Token=SECRET3#f';
  const masked = DevLog.maskUrl(url);
  assert.equal(masked.includes('SECRET'), false);
  assert.ok(masked.includes('ApiKey=***'));
  assert.ok(masked.includes('api_key=***'));
  assert.ok(masked.includes('X-Emby-Token=***#f'));
  assert.ok(masked.includes('AudioStreamIndex=2'));
  assert.equal(DevLog.maskUrl(undefined), '');
  assert.equal(DevLog.maskUrl(null), '');
  assert.equal(DevLog.maskUrl('http://h/x?a=1'), 'http://h/x?a=1');
});
