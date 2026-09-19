'use strict';

/*
 * Modèle pur des réglages du lecteur (qml/js/DeferredReload.js) et décision
 * d'application côté playerOverlayHelper.js.
 */

const test = require('node:test');
const assert = require('node:assert');

const { loadQmlJs } = require('./qmljs');

const DR = loadQmlJs('qml/js/DeferredReload.js');
const H = loadQmlJs('qml/js/playerOverlayHelper.js');

/* ===== Descripteurs et égalité ===== */

test('audioSelection normalise les entrées', () => {
    const s = DR.audioSelection('3', '1', undefined);
    assert.strictEqual(s.kind, DR.KIND_AUDIO);
    assert.strictEqual(s.stream, 3);
    assert.strictEqual(s.uiIndex, 1);
    assert.strictEqual(s.manualDirectPlay, false);

    const bad = DR.audioSelection(undefined, null, true);
    assert.strictEqual(bad.stream, -1);
    assert.strictEqual(bad.uiIndex, -1);
    assert.strictEqual(bad.manualDirectPlay, true);
});

test('audio : égalité sur la ligne cochée, pas sur le flux', () => {
    // En DirectPlay pur, Jellyfin ne renvoie aucun AudioStreamIndex : le flux
    // actif vaut -1 alors que le menu coche bien la ligne 0.
    const active = DR.audioSelection(-1, 0, true);
    const pick = DR.audioSelection(1, 0, false);
    assert.strictEqual(DR.sameSelection(pick, active), true);

    const other = DR.audioSelection(2, 1, false);
    assert.strictEqual(DR.sameSelection(other, active), false);
});

test('audio : un index visuel inconnu n\'est jamais considéré identique', () => {
    assert.strictEqual(
        DR.sameSelection(DR.audioSelection(1, -1, false), DR.audioSelection(1, -1, false)),
        false);
});

test('sous-titres : « Aucun » déjà actif est identique', () => {
    const active = DR.subtitleSelection(-1, 0);
    assert.strictEqual(DR.sameSelection(DR.subtitleSelection(-1, 0), active), true);
    assert.strictEqual(DR.sameSelection(DR.subtitleSelection(4, 2), active), false);
});

test('qualité : égalité sur la valeur du panneau', () => {
    assert.strictEqual(
        DR.sameSelection(DR.qualitySelection(-1), DR.qualitySelection(-1)), true);
    assert.strictEqual(
        DR.sameSelection(DR.qualitySelection(-1), DR.qualitySelection(-2)), false);
    assert.strictEqual(
        DR.sameSelection(DR.qualitySelection(5000000), DR.qualitySelection(5000000)), true);
    // 0 = aucune valeur exploitable : jamais identique.
    assert.strictEqual(
        DR.sameSelection(DR.qualitySelection(0), DR.qualitySelection(0)), false);
});

test('sameSelection refuse les genres différents et les valeurs nulles', () => {
    assert.strictEqual(DR.sameSelection(null, DR.qualitySelection(-1)), false);
    assert.strictEqual(
        DR.sameSelection(DR.audioSelection(1, 0, false), DR.subtitleSelection(1, 0)), false);
});

/* ===== Décision côté helper ===== */

function fakeRoot(overrides) {
    const root = {
        selectedAudioStream: -1,
        effectiveAudioStream: -1,
        manualDirectPlayMode: false,
        useLocalSubs: false,
        localSubStreamIndex: -1,
        selectedSubtitleStream: -1,
        effectiveSubtitleStream: -1,
        _audioUiIndex: 0,
        _subtitleUiIndex: 0,
        _qualityValue: -3,
        _effectiveAudioUiIndexForSettings() { return this._audioUiIndex; },
        _effectiveSubtitleUiIndexForSettings() { return this._subtitleUiIndex; },
        _activeQualityChoiceValue() { return this._qualityValue; },
    };
    return Object.assign(root, overrides || {});
}

test('currentAudioSelection reflète la ligne cochée et le mode DirectPlay', () => {
    const root = fakeRoot({ selectedAudioStream: 2, _audioUiIndex: 1, manualDirectPlayMode: true });
    const sel = H.currentAudioSelection(root);
    assert.strictEqual(sel.stream, 2);
    assert.strictEqual(sel.uiIndex, 1);
    assert.strictEqual(sel.manualDirectPlay, true);
});

test('currentSubtitleSelection privilégie le sous-titre local actif', () => {
    const root = fakeRoot({
        useLocalSubs: true, localSubStreamIndex: 7,
        selectedSubtitleStream: -1, _subtitleUiIndex: 3,
    });
    const sel = H.currentSubtitleSelection(root);
    assert.strictEqual(sel.stream, 7);
    assert.strictEqual(sel.uiIndex, 3);
});

test('decideSettingChange : resélection = noop, autre ligne = applyNow', () => {
    const root = fakeRoot({ selectedAudioStream: 2, _audioUiIndex: 1 });
    const active = H.currentAudioSelection(root);
    assert.strictEqual(
        H.decideSettingChange(root, DR.audioSelection(2, 1, false), active), 'noop');
    assert.strictEqual(
        H.decideSettingChange(root, DR.audioSelection(3, 2, false), active), 'applyNow');
});

test('decideQualityChoice : ignore la valeur déjà appliquée', () => {
    const root = fakeRoot({ _qualityValue: -2 });
    assert.strictEqual(H.decideQualityChoice(root, -2), 'noop');
    assert.strictEqual(H.decideQualityChoice(root, -1), 'applyNow');
    assert.strictEqual(H.decideQualityChoice(root, 5000000), 'applyNow');
    // 0 n'est pas une valeur du panneau.
    assert.strictEqual(H.decideQualityChoice(root, 0), 'noop');
});

test('decideQualityChoice : un débit manuel identique est ignoré', () => {
    const root = fakeRoot({ _qualityValue: 20000000 });
    assert.strictEqual(H.decideQualityChoice(root, 20000000), 'noop');
    assert.strictEqual(H.decideQualityChoice(root, 10000000), 'applyNow');
});

/* ===== Non-régression : les handlers court-circuitent bien ===== */

function pickRoot(overrides) {
    const root = fakeRoot({
        scrubActive: false,
        audioMenuVisible: true,
        subMenuVisible: true,
        negotiated: 0,
        resets: 0,
        snt: -2147483648,
        _pendingAudioStream: -2147483648,
        _pendingAudioIndex: -1,
        _pendingAudioManualDirectPlay: false,
        manualRemuxMode: false,
        subtitleIsTextMap: [],
        subtitleStreamIndexMap: [],
        audioIndex: 0,
        resetControlsTimer() { this.resets++; },
        negotiatePlayback() { this.negotiated++; return true; },
        _beginTrackSwitchRebase() { return 0; },
        _guardUnsafeManualDirectPlayRequest() { return false; },
        keepUi() { return 0; },
        listIndexForStream() { return -1; },
        disableLocalSubsOverlay() {},
        _clampUi(v) { return v; },
        showScrubPreview() {},
        _pushLocalSubsUiMs() {},
    });
    return Object.assign(root, overrides || {});
}

test('handleAudioPick : la piste déjà cochée ne négocie rien', () => {
    const root = pickRoot({ selectedAudioStream: 2, _audioUiIndex: 1 });
    assert.strictEqual(H.handleAudioPick(root, 2, 1), true);
    assert.strictEqual(root.negotiated, 0);
    assert.strictEqual(root.audioMenuVisible, false);
    assert.strictEqual(root.audioIndex, 0, 'aucun état ne doit changer');
});

test('handleAudioPick : une autre piste négocie', () => {
    const root = pickRoot({ selectedAudioStream: 2, _audioUiIndex: 1 });
    assert.strictEqual(H.handleAudioPick(root, 3, 2), true);
    assert.strictEqual(root.negotiated, 1);
    assert.strictEqual(root.audioIndex, 2);
});

test('switchServerSubtitleStable : le sous-titre déjà coché ne négocie rien', () => {
    const root = pickRoot({ selectedSubtitleStream: 4, _subtitleUiIndex: 2 });
    H.switchServerSubtitleStable(root, 'test', 4, 2);
    assert.strictEqual(root.negotiated, 0);
    assert.strictEqual(root.subMenuVisible, false);
    assert.strictEqual(root.selectedSubtitleStream, 4);
});

test('switchServerSubtitleStable : un autre sous-titre négocie', () => {
    const root = pickRoot({ selectedSubtitleStream: 4, _subtitleUiIndex: 2 });
    H.switchServerSubtitleStable(root, 'test', 5, 3);
    assert.strictEqual(root.negotiated, 1);
    assert.strictEqual(root.selectedSubtitleStream, 5);
});
