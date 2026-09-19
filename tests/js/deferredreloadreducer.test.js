'use strict';

/*
 * Réducteur de rechargement différé (qml/js/DeferredReload.js) et son câblage
 * dans playerOverlayHelper.js.
 *
 * Décision produit : un réglage choisi PENDANT UNE PAUSE ne relance pas la
 * lecture. Il est mémorisé, l'UI le reflète, et une SEULE négociation
 * l'applique à la reprise (ou au prochain seek réseau).
 *
 * Les cas limites couverts ici sont ceux du cahier des charges :
 *   (a) resélection du choix déjà actif sans attente -> no-op complet
 *   (b) A -> B puis B -> A en pause -> attente annulée
 *   (c) seek/scrub en pause avec attente -> une seule négociation
 *   (d) sortie / changement d'épisode / fin de média -> attente oubliée
 *   (e) échec de négociation à la reprise -> pas d'attente fantôme
 *   (f) reprise forcée cohérente (wasPlaying / resumeWanted / shouldResume)
 */

const test = require('node:test');
const assert = require('node:assert');

const { loadQmlJs } = require('./qmljs');

const DR = loadQmlJs('qml/js/DeferredReload.js');
const H = loadQmlJs('qml/js/playerOverlayHelper.js');

const AUDIO = DR.KIND_AUDIO;
const SUBTITLE = DR.KIND_SUBTITLE;
const QUALITY = DR.KIND_QUALITY;

function pick(value, active, paused) {
    return { type: 'pick', kind: value.kind, value: value, active: active, paused: paused };
}
// Les tableaux renvoyés par un module chargé dans un contexte vm
// appartiennent à un autre realm : on recopie toujours dans un tableau local
// avant toute comparaison structurelle.
function types(actions) {
    const out = [];
    for (let i = 0; i < actions.length; i++) out.push(actions[i].type);
    return out;
}
function kinds(picks) {
    const out = [];
    for (let i = 0; i < picks.length; i++) out.push(picks[i].kind);
    return out;
}

/* ===== Réducteur pur ===== */

test('état initial : aucune attente', () => {
    const s = DR.createState();
    assert.strictEqual(DR.pendingCount(s), 0);
    assert.strictEqual(DR.pendingPicks(s).length, 0);
    assert.strictEqual(DR.pendingFor(s, AUDIO), null);
});

test('en lecture, un choix différent est appliqué immédiatement', () => {
    const out = DR.reduce(DR.createState(),
        pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), false));
    assert.deepStrictEqual(types(out.actions), ['applyNow']);
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('(a) en lecture, resélectionner la ligne cochée est un no-op', () => {
    const out = DR.reduce(DR.createState(),
        pick(DR.audioSelection(1, 0, false), DR.audioSelection(1, 0, false), false));
    assert.deepStrictEqual(types(out.actions), ['noop']);
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('(a) en pause, resélectionner la ligne cochée est un no-op', () => {
    const out = DR.reduce(DR.createState(),
        pick(DR.subtitleSelection(-1, 0), DR.subtitleSelection(-1, 0), true));
    assert.deepStrictEqual(types(out.actions), ['noop']);
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('en pause, un choix différent est différé', () => {
    const out = DR.reduce(DR.createState(),
        pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true));
    assert.deepStrictEqual(types(out.actions), ['defer']);
    assert.strictEqual(DR.pendingCount(out.state), 1);
    assert.strictEqual(DR.pendingFor(out.state, AUDIO).uiIndex, 2);
});

test('(b) en pause, A -> B puis B -> A annule l\'attente', () => {
    const active = DR.audioSelection(1, 0, false);
    let out = DR.reduce(DR.createState(), pick(DR.audioSelection(3, 2, false), active, true));
    assert.strictEqual(DR.pendingCount(out.state), 1);

    out = DR.reduce(out.state, pick(DR.audioSelection(1, 0, false), active, true));
    assert.deepStrictEqual(types(out.actions), ['cancelPending']);
    assert.strictEqual(DR.pendingCount(out.state), 0);

    // Plus rien à rejouer à la reprise.
    const resumed = DR.reduce(out.state, { type: 'resume' });
    assert.deepStrictEqual(types(resumed.actions), ['noop']);
});

test('en pause, redemander exactement l\'attente en cours est un no-op', () => {
    const active = DR.audioSelection(1, 0, false);
    let out = DR.reduce(DR.createState(), pick(DR.audioSelection(3, 2, false), active, true));
    out = DR.reduce(out.state, pick(DR.audioSelection(3, 2, false), active, true));
    assert.deepStrictEqual(types(out.actions), ['noop']);
    assert.strictEqual(DR.pendingCount(out.state), 1);
});

test('en pause, changer trois fois d\'avis ne garde qu\'une attente par genre', () => {
    const active = DR.audioSelection(1, 0, false);
    let out = DR.reduce(DR.createState(), pick(DR.audioSelection(3, 2, false), active, true));
    out = DR.reduce(out.state, pick(DR.audioSelection(4, 3, false), active, true));
    assert.strictEqual(DR.pendingCount(out.state), 1);
    assert.strictEqual(DR.pendingFor(out.state, AUDIO).uiIndex, 3);
});

test('les trois genres coexistent et sont rejoués dans l\'ordre audio/sous-titres/qualité', () => {
    let s = DR.createState();
    s = DR.reduce(s, pick(DR.qualitySelection(-2), DR.qualitySelection(-3), true)).state;
    s = DR.reduce(s, pick(DR.subtitleSelection(4, 2), DR.subtitleSelection(-1, 0), true)).state;
    s = DR.reduce(s, pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true)).state;
    assert.strictEqual(DR.pendingCount(s), 3);

    const out = DR.reduce(s, { type: 'resume' });
    assert.deepStrictEqual(types(out.actions), ['replayOnResume']);
    assert.strictEqual(out.actions[0].reason, 'resume');
    assert.deepStrictEqual(kinds(out.actions[0].picks), [AUDIO, SUBTITLE, QUALITY]);
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('(c) un seek consomme les attentes comme une reprise', () => {
    let s = DR.reduce(DR.createState(),
        pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true)).state;
    const out = DR.reduce(s, { type: 'seek' });
    assert.deepStrictEqual(types(out.actions), ['replayOnResume']);
    assert.strictEqual(out.actions[0].reason, 'seek');
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('(d) reset oublie toutes les attentes', () => {
    let s = DR.createState();
    s = DR.reduce(s, pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true)).state;
    s = DR.reduce(s, pick(DR.qualitySelection(-2), DR.qualitySelection(-3), true)).state;
    const out = DR.reduce(s, { type: 'reset' });
    assert.deepStrictEqual(types(out.actions), ['cancelPending', 'cancelPending']);
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('(e) negotiationFailed et negotiationDone nettoient l\'état', () => {
    let s = DR.reduce(DR.createState(),
        pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true)).state;
    assert.strictEqual(DR.pendingCount(DR.reduce(s, { type: 'negotiationFailed' }).state), 0);
    assert.strictEqual(DR.pendingCount(DR.reduce(s, { type: 'negotiationDone' }).state), 0);
});

test('cancel ne touche que le genre visé', () => {
    let s = DR.createState();
    s = DR.reduce(s, pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true)).state;
    s = DR.reduce(s, pick(DR.subtitleSelection(4, 2), DR.subtitleSelection(-1, 0), true)).state;
    const out = DR.reduce(s, { type: 'cancel', kind: SUBTITLE });
    assert.deepStrictEqual(types(out.actions), ['cancelPending']);
    assert.strictEqual(DR.pendingCount(out.state), 1);
    assert.ok(DR.pendingFor(out.state, AUDIO));
});

test('reduce ne mute jamais l\'état reçu', () => {
    const s = DR.createState();
    const out = DR.reduce(s, pick(DR.audioSelection(3, 2, false), DR.audioSelection(1, 0, false), true));
    assert.strictEqual(DR.pendingCount(s), 0);
    assert.strictEqual(DR.pendingCount(out.state), 1);
    assert.notStrictEqual(out.state, s);
});

test('en lecture, une attente résiduelle est annulée avant application', () => {
    const active = DR.audioSelection(1, 0, false);
    const s = DR.reduce(DR.createState(), pick(DR.audioSelection(3, 2, false), active, true)).state;
    const out = DR.reduce(s, pick(DR.audioSelection(4, 3, false), active, false));
    assert.deepStrictEqual(types(out.actions), ['cancelPending', 'applyNow']);
    assert.strictEqual(DR.firstActionType(out.actions), 'applyNow');
    assert.strictEqual(DR.pendingCount(out.state), 0);
});

test('un événement inconnu ou vide ne fait rien', () => {
    assert.deepStrictEqual(types(DR.reduce(DR.createState(), null).actions), ['noop']);
    assert.deepStrictEqual(types(DR.reduce(DR.createState(), { type: 'bidon' }).actions), ['noop']);
});

/* ===== Fusion des négociations rejouées ===== */

test('mergeCoalescedNegotiationCall : les scalaires du dernier appel gagnent', () => {
    const first = { startMs: 100, forceHls: true, preferTicks: true, forceMp4: false,
                    forceDPOnAudioSwitch: false, extra: { forceServerRemux: true } };
    const second = { startMs: 200, forceHls: false, preferTicks: false, forceMp4: true,
                     forceDPOnAudioSwitch: false, extra: { forceServerRemux: false } };
    const merged = H.mergeCoalescedNegotiationCall(first, second);
    assert.strictEqual(merged.startMs, 200);
    assert.strictEqual(merged.forceHls, false);
    assert.strictEqual(merged.preferTicks, false);
    assert.strictEqual(merged.forceMp4, true);
    assert.strictEqual(merged.extra.forceServerRemux, false);
});

test('mergeCoalescedNegotiationCall : la première transaction de rollback est préservée', () => {
    const first = { startMs: 0, extra: {
        audioSwitchTransaction: true, previousSelectedAudioStream: 1,
        previousManualRemuxMode: false, forcePlaybackInfoAudioStreamIndex: 3 } };
    const second = { startMs: 0, extra: {
        previousManualRemuxMode: true, previousManualQualityBitrate: 42, manualQualityRequest: true } };
    const merged = H.mergeCoalescedNegotiationCall(first, second);
    assert.strictEqual(merged.extra.audioSwitchTransaction, true);
    assert.strictEqual(merged.extra.previousSelectedAudioStream, 1);
    assert.strictEqual(merged.extra.previousManualRemuxMode, false,
                       'le rollback doit décrire l\'état antérieur à TOUTE la série');
    assert.strictEqual(merged.extra.previousManualQualityBitrate, undefined);
    assert.strictEqual(merged.extra.manualQualityRequest, true);
    assert.strictEqual(merged.extra.forcePlaybackInfoAudioStreamIndex, 3);
});

test('mergeCoalescedNegotiationCall : premier appel seul, rien à fusionner', () => {
    const only = { startMs: 7, extra: { a: 1 } };
    assert.strictEqual(H.mergeCoalescedNegotiationCall(null, only), only);
    assert.strictEqual(H.mergeCoalescedNegotiationCall(only, null), only);
});

/* ===== Câblage helper : différer puis rejouer ===== */

const MP = { StoppedState: 0, PlayingState: 1, PausedState: 2 };

function fakeRoot(overrides) {
    const root = {
        _mpStoppedState: MP.StoppedState,
        _mpPlayingState: MP.PlayingState,
        _mpPausedState: MP.PausedState,
        _tearingDownPlayer: false,
        snt: -2147483648,

        paused: true,
        negotiations: [],
        syncs: 0,

        _deferredReloadState: null,
        _deferredAudioUiIndex: -1,
        _deferredSubtitleUiIndex: -1,
        _deferredQualityValue: 0,
        _deferredReloadReplaying: false,
        _forceResumeAfterDeferredReload: false,
        _coalescedNegotiationActive: false,
        _coalescedNegotiationCall: null,
        _internalDirectPlayReload: false,

        selectedAudioStream: 1,
        effectiveAudioStream: 1,
        audioIndex: 0,
        manualDirectPlayMode: false,
        manualRemuxMode: false,
        useLocalSubs: false,
        localSubStreamIndex: -1,
        selectedSubtitleStream: -1,
        effectiveSubtitleStream: -1,
        subtitleIndex: 0,
        subtitleIsTextMap: [],
        subtitleStreamIndexMap: [-1, 4],
        scrubActive: false,
        audioMenuVisible: false,
        subMenuVisible: false,
        _pendingAudioStream: -2147483648,
        _pendingAudioIndex: -1,
        _pendingAudioManualDirectPlay: false,
        _trackSwitchForceLocalSeek: false,
        _trackSwitchRebaseActive: false,
        _trackSwitchWasPlaying: false,
        _wasPlayingBeforeSwitch: false,
        _resumeWantedAfterNegotiation: false,
        _trackSwitchAnchorUiMs: 0,
        _trackSwitchAnchorWallMs: 0,
        _trackSwitchLocalSeekMs: 0,
        _trackSwitchRequestedUiMs: 0,
        _trackSwitchVerificationActive: false,
        _trackSwitchTimebaseVerified: false,
        lastUiTargetMs: 0,
        _qualityValue: -3,

        _audioUiIndex: 0,
        _subtitleUiIndex: 0,
        _effectiveAudioUiIndexForSettings() { return this._audioUiIndex; },
        _effectiveSubtitleUiIndexForSettings() { return this._subtitleUiIndex; },
        _activeQualityChoiceValue() { return this._qualityValue; },
        _deferredReloadPauseActive() { return this.paused === true; },
        _syncTrackMenuIndexes() { this.syncs++; },
        resetControlsTimer() {},
        keepUi() { return 600000; },
        _clampUi(v) { return v; },
        showScrubPreview() {},
        _pushLocalSubsUiMs() {},
        listIndexForStream() { return -1; },
        disableLocalSubsOverlay() {},
        _guardUnsafeManualDirectPlayRequest() { return false; },
        _beginTrackSwitchRebase(reason, forceLocalSeek) {
            this._trackSwitchRebaseActive = true;
            this._trackSwitchWasPlaying =
                (this.paused !== true) || this._forceResumeAfterDeferredReload === true;
            this._wasPlayingBeforeSwitch = this._trackSwitchWasPlaying;
            this._resumeWantedAfterNegotiation = this._trackSwitchWasPlaying;
            return 600000;
        },
        // Façade QML negotiatePlayback() -> H.negotiateAndApply() : la
        // coalescence est interceptée exactement au même endroit qu'en vrai.
        negotiatePlayback(startMs, forceHls, preferTicks, forceMp4, forceDP, extra) {
            if (H.coalesceNegotiationIfActive(this, startMs, forceHls, preferTicks,
                                              forceMp4, forceDP, extra))
                return true;
            this.negotiations.push({ startMs: startMs, extra: extra || {} });
            return true;
        },
        _applyQualityChoice(value) {
            // Reproduit le dispatch réel : décision puis négociation unique.
            if (H.decideQualityChoice(this, value) !== 'applyNow') return true;
            this._qualityValue = value;
            return this.negotiatePlayback(600000, false, true, false, false,
                                          { manualQualityRequest: true });
        },
    };
    return Object.assign(root, overrides || {});
}

function fakeMediaPlayer() {
    return { playbackState: MP.PausedState, position: 0, duration: 0,
             play() { this.playbackState = MP.PlayingState; },
             pause() { this.playbackState = MP.PausedState; } };
}

test('en pause, un choix audio ne négocie rien et met à jour l\'UI', () => {
    const root = fakeRoot({ paused: true, selectedAudioStream: 1, _audioUiIndex: 0 });
    assert.strictEqual(H.handleAudioPick(root, 3, 2), true);
    assert.strictEqual(root.negotiations.length, 0, 'aucun appel réseau en pause');
    assert.strictEqual(root._deferredAudioUiIndex, 2, 'la coche suit le choix');
    assert.strictEqual(root.selectedAudioStream, 1, 'l\'état appliqué ne bouge pas');
    assert.strictEqual(root.audioMenuVisible, false, 'le menu se ferme');
    assert.strictEqual(H.deferredReloadPendingCount(root), 1);
});

test('en lecture, un choix audio négocie immédiatement (comportement inchangé)', () => {
    const root = fakeRoot({ paused: false, selectedAudioStream: 1, _audioUiIndex: 0 });
    H.handleAudioPick(root, 3, 2);
    assert.strictEqual(root.negotiations.length, 1);
    assert.strictEqual(root.selectedAudioStream, 3);
    assert.strictEqual(H.deferredReloadPendingCount(root), 0);
});

test('(b) annuler son choix en pause remet l\'UI et ne laisse rien à rejouer', () => {
    const root = fakeRoot({ paused: true, selectedAudioStream: 1, _audioUiIndex: 0 });
    H.handleAudioPick(root, 3, 2);
    H.handleAudioPick(root, 1, 0);
    assert.strictEqual(root._deferredAudioUiIndex, -1);
    assert.strictEqual(H.deferredReloadPendingCount(root), 0);
    assert.strictEqual(H.resumeDeferredReload(root, fakeMediaPlayer(), 'toggle'), false,
                       'la reprise doit rester un simple mp.play()');
});

test('(f) la reprise rejoue les attentes en UNE négociation, reprise forcée', () => {
    const root = fakeRoot({ paused: true, selectedAudioStream: 1, _audioUiIndex: 0 });
    H.handleAudioPick(root, 3, 2);
    H.switchServerSubtitleStable(root, 'test', 4, 1);
    root._applyQualityChoice(-2);
    assert.strictEqual(root.negotiations.length, 0);
    assert.strictEqual(H.deferredReloadPendingCount(root), 3);

    const mp = fakeMediaPlayer();
    assert.strictEqual(H.resumeDeferredReload(root, mp, 'toggle'), true);

    assert.strictEqual(root.negotiations.length, 1, 'une seule négociation');
    const call = root.negotiations[0];
    assert.strictEqual(call.extra.deferredReplay, true);
    assert.strictEqual(call.extra.manualQualityRequest, true, 'la qualité domine le pipeline');
    assert.strictEqual(call.extra.audioSwitchTransaction, true, 'rollback audio conservé');
    assert.strictEqual(call.extra.previousSelectedAudioStream, 1);

    // État réellement appliqué et drapeaux de reprise cohérents.
    assert.strictEqual(root.selectedAudioStream, 3);
    assert.strictEqual(root.selectedSubtitleStream, 4);
    assert.strictEqual(root._trackSwitchWasPlaying, true);
    assert.strictEqual(root._wasPlayingBeforeSwitch, true);
    assert.strictEqual(root._resumeWantedAfterNegotiation, true);

    // Plus rien en attente, surcharges d'affichage effacées, drapeaux rendus.
    assert.strictEqual(H.deferredReloadPendingCount(root), 0);
    assert.strictEqual(root._deferredAudioUiIndex, -1);
    assert.strictEqual(root._deferredSubtitleUiIndex, -1);
    assert.strictEqual(root._deferredQualityValue, 0);
    assert.strictEqual(root._deferredReloadReplaying, false);
    assert.strictEqual(root._forceResumeAfterDeferredReload, false);
    assert.strictEqual(root._coalescedNegotiationActive, false);
});

test('(c) un seek en pause applique l\'attente à la position cible sans reprendre', () => {
    const root = fakeRoot({ paused: true, selectedAudioStream: 1, _audioUiIndex: 0 });
    H.handleAudioPick(root, 3, 2);
    const mp = fakeMediaPlayer();

    assert.strictEqual(H.seekDeferredReload(root, mp, 123456, 'commitScrub', false), true);
    assert.strictEqual(root.negotiations.length, 1);
    assert.strictEqual(root.negotiations[0].startMs, 123456);
    assert.strictEqual(root._trackSwitchWasPlaying, false, 'la pause est conservée');
    assert.strictEqual(root._trackSwitchRequestedUiMs, 123456);
});

test('sans attente, la reprise et le seek ne font rien', () => {
    const root = fakeRoot({ paused: true });
    const mp = fakeMediaPlayer();
    assert.strictEqual(H.resumeDeferredReload(root, mp, 'toggle'), false);
    assert.strictEqual(H.seekDeferredReload(root, mp, 1000, 'scrub', false), false);
    assert.strictEqual(root.negotiations.length, 0);
});

test('(d) resetDeferredReload oublie l\'attente et efface l\'UI', () => {
    const root = fakeRoot({ paused: true, selectedAudioStream: 1, _audioUiIndex: 0 });
    H.handleAudioPick(root, 3, 2);
    H.resetDeferredReload(root, 'item-changed');
    assert.strictEqual(H.deferredReloadPendingCount(root), 0);
    assert.strictEqual(root._deferredAudioUiIndex, -1);
    assert.strictEqual(H.resumeDeferredReload(root, fakeMediaPlayer(), 'toggle'), false);
});

test('un sous-titre texte local annule l\'attente serveur du même genre', () => {
    const root = fakeRoot({ paused: true, selectedSubtitleStream: -1, _subtitleUiIndex: 0 });
    H.switchServerSubtitleStable(root, 'test', 4, 1);
    assert.strictEqual(root._deferredSubtitleUiIndex, 1);
    assert.strictEqual(H.cancelDeferredReload(root, SUBTITLE, 'local'), true);
    assert.strictEqual(root._deferredSubtitleUiIndex, -1);
    assert.strictEqual(H.deferredReloadPendingCount(root), 0);
});

test('un rechargement DirectPlay complet n\'émet aucune négociation mourante', () => {
    const root = fakeRoot({ paused: true, selectedAudioStream: 1, _audioUiIndex: 0 });
    root._applyQualityChoice(-1);
    assert.strictEqual(H.deferredReloadPendingCount(root), 1);
    // Le handler réel demande la recréation de PlayerOverlay.
    root._applyQualityChoice = function () { this._internalDirectPlayReload = true; return true; };
    assert.strictEqual(H.resumeDeferredReload(root, fakeMediaPlayer(), 'toggle'), true);
    assert.strictEqual(root.negotiations.length, 0);
});
