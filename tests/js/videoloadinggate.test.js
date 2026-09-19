'use strict';

/*
 * Libération de la gate de chargement vidéo (loader) quand un rechargement
 * de source se termine SANS reprise de lecture.
 *
 * Toutes les libérations naturelles du loader (_scheduleVideoLoadingRelease,
 * videoLoadingReleaseTimer, « position-progress », « state-playing ») exigent
 * l'état Playing. Un changement de piste / sous-titre / qualité effectué
 * pendant une pause se termine volontairement en pause : sans libération
 * explicite, le spinner reste affiché au-dessus d'une vidéo déjà prête.
 */

const test = require('node:test');
const assert = require('node:assert');

const { loadQmlJs } = require('./qmljs');

const H = loadQmlJs('qml/js/playerOverlayHelper.js');

// Codes Qt 5.15 réellement utilisés par playeroverlay.qml.
const MP = {
    StoppedState: 0,
    PlayingState: 1,
    PausedState: 2,
    NoMedia: 1,
    Loading: 2,
    Loaded: 3,
    Stalled: 4,
    Buffering: 5,
    Buffered: 6,
};

function fakeTimer() {
    return { running: false, stop() { this.running = false; }, restart() { this.running = true; } };
}

function fakeMediaPlayer(state) {
    return {
        playbackState: state,
        position: 0,
        duration: 0,
        status: MP.Buffered,
        calls: [],
        play() { this.calls.push('play'); this.playbackState = MP.PlayingState; },
        pause() { this.calls.push('pause'); this.playbackState = MP.PausedState; },
        stop() { this.calls.push('stop'); this.playbackState = MP.StoppedState; },
    };
}

function fakeRoot(overrides) {
    const root = {
        _mpStoppedState: MP.StoppedState,
        _mpPlayingState: MP.PlayingState,
        _mpPausedState: MP.PausedState,
        _mpNoMedia: MP.NoMedia,
        _mpLoaded: MP.Loaded,
        _mpBuffered: MP.Buffered,

        _tearingDownPlayer: false,
        _sourceResetActive: true,
        _sourceResetPhase: 2,
        _sourceResetMode: 'server-timed',
        _sourceResetPendingUrl: 'http://srv/x',
        _sourceResetShouldResume: false,
        _sourceResetExpectedUiMs: 900000,
        _sourceResetStartedWallMs: 0,
        _sourceResetAssignedWallMs: 0,
        _sourceResetReadyWallMs: 0,
        _sourceResetPlayRetries: 0,
        _pendingServerTimedBaseMs: -1,
        _pendingHardResetBaseMs: -1,
        _pendingSeekMs: -1,

        baseOffsetMs: 0,
        serverTimedStream: false,
        timeShifted: false,
        _trackSwitchTimebaseVerified: false,
        _trackSwitchVerificationActive: false,
        _trackSwitchRebaseActive: false,
        _trackSwitchWasPlaying: false,
        _wasPlayingBeforeSwitch: false,
        _trackSwitchResumeAfterVerified: false,
        _seekRestoreAccepted: false,
        _seekRestoreAttempts: 0,
        _seekRestoreLastTargetMs: -1,
        _seekRestoreLastCallWallMs: 0,
        _seekRestoreAwaitingResult: false,
        _seekRestoreStableSamples: 0,
        _seekRestoreBestDiffMs: 2147483647,
        _seekRestoreBestLocalMs: -1,
        _seekRestoreReadyWallMs: 0,
        _seekRestorePrimeWallMs: 0,
        _seekRestorePauseWallMs: 0,
        _seekRestorePhase: 0,
        _gateArmed: true,
        _resumeAfterGate: false,
        _startupPlayWanted: false,

        // Gate de chargement.
        videoLoadingGate: true,
        released: [],
        scheduled: [],
        _releaseVideoLoading(reason) { this.videoLoadingGate = false; this.released.push(reason); },
        _scheduleVideoLoadingRelease(reason) { this.scheduled.push(reason); },

        updateClocksFromPlaybackThrottled() {},
        _releaseSkipIntroResumeGate() {},
        trackSwitchSeekToleranceMs: 220,
        seekRestoreBootToleranceMs: 1500,
    };
    return Object.assign(root, overrides || {});
}

test('reset server-timed terminé en pause : le loader est libéré explicitement', () => {
    const root = fakeRoot({ _sourceResetShouldResume: false });
    const mp = fakeMediaPlayer(MP.PlayingState);

    H.completeFreshServerTimedSource(root, mp, fakeTimer(), null);

    assert.deepStrictEqual(mp.calls, ['pause']);
    assert.strictEqual(root.videoLoadingGate, false);
    assert.ok(root.released.indexOf('fresh-source-ready-paused') >= 0);
});

test('reset server-timed terminé en lecture : aucune libération forcée', () => {
    const root = fakeRoot({ _sourceResetShouldResume: true });
    const mp = fakeMediaPlayer(MP.PausedState);

    H.completeFreshServerTimedSource(root, mp, fakeTimer(), null);

    assert.deepStrictEqual(mp.calls, ['play']);
    assert.deepStrictEqual(root.released, []);
    // La libération normale reste planifiée par completeFreshSourceResetState().
    assert.ok(root.scheduled.indexOf('fresh-source-reset-complete') >= 0);
});

test('reset DirectPlay terminé en pause : le loader est libéré explicitement', () => {
    const root = fakeRoot({
        _sourceResetMode: 'directplay-local',
        _sourceResetShouldResume: false,
        _pendingSeekMs: -1,
    });
    const mp = fakeMediaPlayer(MP.PausedState);

    H.completeFreshDirectPlaySource(root, mp, fakeTimer(), fakeTimer(), null);

    assert.strictEqual(root.videoLoadingGate, false);
    assert.ok(root.released.indexOf('fresh-directplay-ready-paused') >= 0);
});

test('reset DirectPlay terminé en lecture : aucune libération forcée', () => {
    const root = fakeRoot({
        _sourceResetMode: 'directplay-local',
        _sourceResetShouldResume: true,
        _pendingSeekMs: -1,
    });
    const mp = fakeMediaPlayer(MP.PausedState);

    H.completeFreshDirectPlaySource(root, mp, fakeTimer(), fakeTimer(), null);

    assert.deepStrictEqual(mp.calls, ['play']);
    assert.deepStrictEqual(root.released, []);
});

test('seek de restauration validé sans reprise : le loader est libéré', () => {
    const root = fakeRoot({
        _sourceResetActive: false,
        _trackSwitchRebaseActive: true,
        _trackSwitchVerificationActive: true,
        _wasPlayingBeforeSwitch: false,
        _pendingSeekMs: 900000,
    });
    const resumeTimer = fakeTimer();

    H.completeSeekRestoreVerified(root, fakeTimer(), resumeTimer, 900000);

    assert.strictEqual(resumeTimer.running, false);
    assert.strictEqual(root._trackSwitchResumeAfterVerified, false);
    assert.strictEqual(root.videoLoadingGate, false);
    assert.ok(root.released.indexOf('seek-restore-verified-paused') >= 0);
});

test('seek de restauration validé avec reprise : la reprise prime sur la libération', () => {
    const root = fakeRoot({
        _sourceResetActive: false,
        _trackSwitchRebaseActive: true,
        _trackSwitchVerificationActive: true,
        _wasPlayingBeforeSwitch: true,
        _pendingSeekMs: 900000,
    });
    const resumeTimer = fakeTimer();

    H.completeSeekRestoreVerified(root, fakeTimer(), resumeTimer, 900000);

    assert.strictEqual(root._trackSwitchResumeAfterVerified, true);
    assert.strictEqual(resumeTimer.running, true);
    assert.deepStrictEqual(root.released, []);
});
