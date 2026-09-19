'use strict';

/*
 * Retour de focus déterministe après un choix dans un menu du lecteur.
 *
 * Contrat : quel que soit le chemin (validation, fermeture latérale, retour)
 * et quel que soit le sort du réglage (appliqué, différé, ignoré), le focus
 * revient sur le bouton du HUD qui a ouvert le panneau, HUD visible ; et après
 * un rechargement il est réaffirmé sur ce même bouton tant que l'utilisateur
 * n'a pas navigué ailleurs.
 */

const test = require('node:test');
const assert = require('node:assert');

const { loadQmlJs } = require('./qmljs');

const H = loadQmlJs('qml/js/playerOverlayHelper.js');

const CTRL = {
    quality: H.SETTINGS_CONTROL_QUALITY,
    zoom: H.SETTINGS_CONTROL_ZOOM,
    speed: H.SETTINGS_CONTROL_SPEED,
    audio: H.SETTINGS_CONTROL_AUDIO,
    subtitle: H.SETTINGS_CONTROL_SUBTITLE,
};

function fakeRoot(overrides) {
    const root = {
        // Constantes de focus de playeroverlay.qml.
        cF_PROGRESS: 0, cF_CONTROLS: 1, cF_MENU: 4,
        cF_CHAPTERS: 5, cF_QUALITY: 6, cF_ZOOM: 7, cF_SPEED: 8,

        controlsFocus: 1,
        menuIndex: 1,
        controlsVisible: false,
        audioMenuVisible: true,
        subMenuVisible: false,
        nextUiLocked: false,
        serverPrerollBlocking: false,
        _tearingDownPlayer: false,
        _lastSettingsFocusControl: -1,

        focusCalls: 0,
        updateCalls: 0,
        timerResets: 0,
        qualityPanel: false,
        chaptersPanel: false,

        forceActiveFocus() { this.focusCalls++; },
        _updateControlsActive() { this.updateCalls++; },
        resetControlsTimer() { this.timerResets++; },
        _qualityPanelOpen() { return this.qualityPanel; },
        _chaptersPanelOpen() { return this.chaptersPanel; },
    };
    return Object.assign(root, overrides || {});
}

test('les identifiants de boutons suivent PlayerSettingsOverlay/PlayerControls', () => {
    assert.strictEqual(CTRL.quality, 0);
    assert.strictEqual(CTRL.zoom, 1);
    assert.strictEqual(CTRL.speed, 2);
    assert.strictEqual(CTRL.audio, 3);
    assert.strictEqual(CTRL.subtitle, 4);
});

test('chaque bouton a une cible de focus unique', () => {
    const root = fakeRoot();
    assert.strictEqual(H.settingsControlFocusTarget(root, CTRL.quality), root.cF_QUALITY);
    assert.strictEqual(H.settingsControlFocusTarget(root, CTRL.zoom), root.cF_ZOOM);
    assert.strictEqual(H.settingsControlFocusTarget(root, CTRL.speed), root.cF_SPEED);
    assert.strictEqual(H.settingsControlFocusTarget(root, CTRL.audio), root.cF_MENU);
    assert.strictEqual(H.settingsControlFocusTarget(root, CTRL.subtitle), root.cF_MENU);
});

test('un identifiant invalide retombe sur Qualité au lieu de produire NaN', () => {
    const root = fakeRoot();
    assert.strictEqual(H.normalizeSettingsControl(undefined), CTRL.quality);
    assert.strictEqual(H.normalizeSettingsControl(-4), CTRL.quality);
    assert.strictEqual(H.normalizeSettingsControl(99), CTRL.quality);
    assert.strictEqual(H.settingsControlFocusTarget(root, null), root.cF_QUALITY);
});

test('fermeture du menu Audio : focus sur le bouton Audio, HUD visible', () => {
    const root = fakeRoot({ controlsFocus: 4, menuIndex: 2, audioMenuVisible: true });
    assert.strictEqual(H.restoreFocusAfterSettingsChoice(root, CTRL.audio, 'test'), true);
    assert.strictEqual(root.controlsFocus, root.cF_MENU);
    assert.strictEqual(root.menuIndex, 1);
    assert.strictEqual(root.audioMenuVisible, false);
    assert.strictEqual(root.subMenuVisible, false);
    assert.strictEqual(root.controlsVisible, true);
    assert.strictEqual(root._lastSettingsFocusControl, CTRL.audio);
    assert.strictEqual(root.focusCalls, 1);
    assert.strictEqual(root.updateCalls, 1);
    assert.strictEqual(root.timerResets, 1);
});

test('fermeture du menu Sous-titres : menuIndex 2', () => {
    const root = fakeRoot({ subMenuVisible: true, menuIndex: 1 });
    H.restoreFocusAfterSettingsChoice(root, CTRL.subtitle, 'test');
    assert.strictEqual(root.controlsFocus, root.cF_MENU);
    assert.strictEqual(root.menuIndex, 2);
    assert.strictEqual(root._lastSettingsFocusControl, CTRL.subtitle);
});

test('choix de qualité : focus sur le bouton Qualité, menuIndex intouché', () => {
    const root = fakeRoot({ menuIndex: 2 });
    H.restoreFocusAfterSettingsChoice(root, CTRL.quality, 'test');
    assert.strictEqual(root.controlsFocus, root.cF_QUALITY);
    assert.strictEqual(root.menuIndex, 2, 'menuIndex ne concerne que Audio/Sous-titres');
    assert.strictEqual(root._lastSettingsFocusControl, CTRL.quality);
});

test('settingsFocusStillOnControl distingue Audio et Sous-titres', () => {
    const root = fakeRoot({ controlsFocus: 4, menuIndex: 1 });
    assert.strictEqual(H.settingsFocusStillOnControl(root, CTRL.audio), true);
    assert.strictEqual(H.settingsFocusStillOnControl(root, CTRL.subtitle), false);
    root.menuIndex = 2;
    assert.strictEqual(H.settingsFocusStillOnControl(root, CTRL.subtitle), true);
    root.controlsFocus = root.cF_CONTROLS;
    assert.strictEqual(H.settingsFocusStillOnControl(root, CTRL.subtitle), false);
});

test('réaffirmation après rechargement : le focus natif est repris', () => {
    const root = fakeRoot({ audioMenuVisible: false });
    H.restoreFocusAfterSettingsChoice(root, CTRL.audio, 'test');
    const before = root.focusCalls;
    assert.strictEqual(H.reassertSettingsFocus(root, 'reload-done'), true);
    assert.strictEqual(root.focusCalls, before + 1);
    assert.strictEqual(root._lastSettingsFocusControl, CTRL.audio);
});

test('réaffirmation abandonnée si l\'utilisateur a navigué ailleurs', () => {
    const root = fakeRoot({ audioMenuVisible: false });
    H.restoreFocusAfterSettingsChoice(root, CTRL.audio, 'test');
    root.controlsFocus = root.cF_PROGRESS;
    assert.strictEqual(H.reassertSettingsFocus(root, 'reload-done'), false);
    assert.strictEqual(root._lastSettingsFocusControl, -1);
});

test('réaffirmation abandonnée si le HUD est masqué', () => {
    const root = fakeRoot({ audioMenuVisible: false });
    H.restoreFocusAfterSettingsChoice(root, CTRL.quality, 'test');
    root.controlsVisible = false;
    assert.strictEqual(H.reassertSettingsFocus(root, 'reload-done'), false);
    assert.strictEqual(root._lastSettingsFocusControl, -1);
});

test('réaffirmation suspendue tant qu\'un panneau est ouvert, sans oublier la cible', () => {
    const root = fakeRoot({ audioMenuVisible: false });
    H.restoreFocusAfterSettingsChoice(root, CTRL.quality, 'test');
    root.qualityPanel = true;
    assert.strictEqual(H.reassertSettingsFocus(root, 'reload-done'), false);
    assert.strictEqual(root._lastSettingsFocusControl, CTRL.quality,
                       'la cible reste valide, le panneau a simplement la main');
    root.qualityPanel = false;
    assert.strictEqual(H.reassertSettingsFocus(root, 'reload-done'), true);
});

test('réaffirmation inactive sans choix préalable ou pendant la destruction', () => {
    assert.strictEqual(H.reassertSettingsFocus(fakeRoot(), 'x'), false);
    const root = fakeRoot({ audioMenuVisible: false });
    H.restoreFocusAfterSettingsChoice(root, CTRL.quality, 'test');
    root._tearingDownPlayer = true;
    assert.strictEqual(H.reassertSettingsFocus(root, 'x'), false);
});

test('forgetSettingsFocusIfMoved n\'oublie que si le focus a bougé', () => {
    const root = fakeRoot({ audioMenuVisible: false });
    H.restoreFocusAfterSettingsChoice(root, CTRL.subtitle, 'test');
    assert.strictEqual(H.forgetSettingsFocusIfMoved(root), false);
    assert.strictEqual(root._lastSettingsFocusControl, CTRL.subtitle);
    root.menuIndex = 1;
    assert.strictEqual(H.forgetSettingsFocusIfMoved(root), true);
    assert.strictEqual(root._lastSettingsFocusControl, -1);
    assert.strictEqual(H.forgetSettingsFocusIfMoved(root), false);
});
