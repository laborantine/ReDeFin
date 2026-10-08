// ReDeFin DirectPlay : les sous-titres externes dormants ne forcent pas le remux initial.
// Le routage texte QML reste réservé au DirectPlay pur ; remux, DirectStream,
import QtQuick 2.15
import "../js/NavigationContext.js" as NavContext
import QtMultimedia 5.15
import "../js/JellyfinPlaybackRouter.js" as JF
import "../js/PlayerSession.js" as PlayerSession
import "../js/PlayerTrackSelection.js" as TrackSelection
import "../js/jellyfinBridge.js"  as JFB
import "../js/playerOverlayHelper.js" as H
import "../js/SkipIntro.js" as SkipIntro
FocusScope {
    id: root
    width: 1920; height: 1080
    focus: true
    z: 900
    clip: false
    // premières frames du nouveau MediaPlayer, VideoOutput peut momentanément
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        z: 0
    }
    property var settingsRef: null
    property bool topbarShowClock: true
    // Le noyau MediaPlayer/VideoOutput reste créé synchronement. Les sous-vues purement UI sont armées après une courte frame afin d'étaler le coût de création sur Révolution sans modifier le backend multimédia.
    property bool _primaryUiReady: false
    property bool _secondaryUiReady: false
    property int primaryUiDelayMs: 70
    property int secondaryUiDelayMs: 190
    Timer {
        id: primaryUiTimer
        interval: Math.max(16, root.primaryUiDelayMs | 0)
        repeat: false
        onTriggered: root._primaryUiReady = true
    }
    Timer {
        id: secondaryUiTimer
        interval: Math.max(root.primaryUiDelayMs + 16, root.secondaryUiDelayMs | 0)
        repeat: false
        onTriggered: root._secondaryUiReady = true
    }
    property var __playbackTimerRefs: null
    function _playbackTimers(){
        if (!__playbackTimerRefs) {
            __playbackTimerRefs = ({
                startup: startupPlayTimer,
                seekRestore: seekRestoreTimer,
                scrubCommit: scrubCommitTimer,
                audioGate: audioGateDelay,
                progress: progressTimer,
                controls: controlsTimer,
                resumeCheckpoint: resumeCheckpointTimer,
                frozenWatch: frozenPlaybackWatchTimer,
                mediaGuard: mediaErrorRecoveryGuard,
                nextRearm: nextRearmTimer,
                topBarApply: topBarApplyTimer,
                sourceReset: sourceResetTimer,
                coalescedLocalSeek: coalescedLocalSeekTimer,
                pauseResumeProbe: pauseResumeProbeTimer,
                trackSwitchFailureRestart: trackSwitchFailureRestartTimer,
                trackSwitchVerifiedResume: trackSwitchVerifiedResumeTimer,
                videoLoadingShow: videoLoadingShowTimer,
                videoLoadingHide: videoLoadingHideTimer,
                videoLoadingRelease: videoLoadingReleaseTimer,
                speedPopupFadeOut: speedDirectPlayPopupFadeOutTimer,
                speedPopupCleanup: speedDirectPlayPopupCleanupTimer,
                playbackRateSync: playbackRateSyncTimer,
                nextHidden: nextHiddenWaiter
            })
        }
        return __playbackTimerRefs
    }
    Keys.forwardTo: []
    Keys.priority: Keys.BeforeItem
    readonly property int _mpStoppedState: MediaPlayer.StoppedState
    readonly property int _mpPlayingState: MediaPlayer.PlayingState
    readonly property int _mpPausedState: MediaPlayer.PausedState
    readonly property int _mpLoading: MediaPlayer.Loading
    readonly property int _mpStalled: MediaPlayer.Stalled
    readonly property int _mpNoMedia: MediaPlayer.NoMedia
    readonly property int _mpLoaded: MediaPlayer.Loaded
    readonly property int _mpBuffered: MediaPlayer.Buffered
    property bool _tearingDownPlayer: false
    property real _lastUiClockPushWallMs: 0
    property int uiClockPushMinIntervalMs: 200
    property real _pauseWatchStartedWallMs: 0
    property int _pauseWatchStartedUiMs: 0
    property int _pauseWatchLastStableUiMs: 0
    property real _pauseWatchLastStableWallMs: 0
    property bool _pauseWatchInPause: false
    property int _pauseWatchResumeSeq: 0
    property int _pauseResumeProbeTicks: 0
    property bool _frozenPlaybackWatchActive: false
    property real _frozenPlaybackWatchArmedWallMs: 0
    property real _frozenPlaybackWatchUntilWallMs: 0
    property real _frozenPlaybackNoProgressSinceWallMs: 0
    property int _frozenPlaybackLastLocalMs: -1
    property int _frozenPlaybackLastUiMs: -1
    property int _frozenPlaybackRecoveryCount: 0
    property int frozenPlaybackLongPauseThresholdMs: 30000
    property int frozenPlaybackWatchWindowMs: 90000
    property int frozenPlaybackNoProgressMs: 5500
    property int frozenPlaybackStartupGraceMs: 2800
    // Overlay visuel de chargement vidéo. Il n'influence jamais la politique DirectPlay / remux / transcodage et reste purement informatif.
    property bool videoLoadingGate: true
    // initiale ou d'un buffering, et sert de base au verrou transport.
    property string _videoLoadingReason: ""
    property bool videoLoadingVisible: false
    property int videoLoadingShowDelayMs: 180
    property int videoLoadingHideDelayMs: 90
    readonly property bool videoLoadingRequested:
        !_tearingDownPlayer &&
        (
            videoLoadingGate ||
            _sourceResetActive ||
            (
                mp.playbackState !== MediaPlayer.PausedState &&
                (
                    mp.status === MediaPlayer.Stalled ||
                    (mp.status === MediaPlayer.Loading &&
                     !(mp.playbackState === MediaPlayer.PlayingState && mp.position > 0))
                )
            )
        )
    function _setCircleLoaderRunning(loader, running){
        try {
            if (loader && ("running" in loader))
                loader["running"] = !!running
        } catch(e) {}
    }
    function _armVideoLoading(reason){
        videoLoadingGate = true
        _videoLoadingReason = String(reason || "")
        try { videoLoadingHideTimer.stop() } catch(e0) {}
        if (!videoLoadingVisible && !videoLoadingShowTimer.running)
            videoLoadingShowTimer.restart()
    }
    function _releaseVideoLoading(reason){
        videoLoadingGate = false
        _videoLoadingReason = ""
        if (!videoLoadingRequested) {
            try { videoLoadingShowTimer.stop() } catch(e0) {}
            videoLoadingHideTimer.restart()
        }
    }
    function _scheduleVideoLoadingRelease(reason){
        if (_tearingDownPlayer || _sourceResetActive)
            return
        if (mp.playbackState === MediaPlayer.PlayingState &&
                (mp.status === MediaPlayer.Loaded || mp.status === MediaPlayer.Buffered))
            videoLoadingReleaseTimer.restart()
    }
    onVideoLoadingRequestedChanged: {
        if (videoLoadingRequested) {
            videoLoadingHideTimer.stop()
            if (!videoLoadingVisible && !videoLoadingShowTimer.running)
                videoLoadingShowTimer.restart()
        } else {
            videoLoadingShowTimer.stop()
            videoLoadingHideTimer.restart()
        }
    }
    // Retour, Stop, la sortie du lecteur et Lecture/Pause restent actifs.
    readonly property bool _reloadInProgress: PlayerSession.reloadBlocksTransport(root)
    function _transportLocked(origin){
        if (!_reloadInProgress) return false
        resetControlsTimer()
        return true
    }
    function _nowMs(){ return Date.now ? Date.now() : (new Date()).getTime() }
    function _serverTimedLike(){ return !!(serverTimedStream||timeShifted||lastUsedServerRemux||baseOffsetMs>0) }
    function _seekLocalPosition(localTarget){
        mp.seek(localTarget)
    }
    function _setMediaPlayerSource(u, reason){
        mp.source = u
    }
    property int _negotiationSeq: 0
    property int _initialPlaybackSeq: 0
    property int _streamsSeq: 0
    property string _streamsReadyKey: ""
    property string _streamsLoadingKey: ""
    property var _streamsWaiters: []
    property string accessToken: ""
    property string userId: ""
    property string userName: ""
    property string userImageTag: ""
    property string serverUrl: ""
    property string itemId: ""
    property string itemTitle: ""
    property string currentItemTitle: ""
    property string currentItemLogoUrl: ""
    property string currentItemType: ""
    property bool serverPrerollEnabled: true
    property int _serverPrerollState: 0 // 0=idle, 1=resolve, 2=intro, 3=main switch, 4=done
    readonly property bool serverPrerollBlocking:
        _serverPrerollState > 0 && _serverPrerollState < 4
    property bool serverPrerollActive: false
    property int _serverPrerollSeq: 0
    property string _serverPrerollForItemId: ""
    property string _serverPrerollServerUrl: ""
    property string _serverPrerollItemId: ""
    property string _serverPrerollPlaySessionId: ""
    property string _serverPrerollMediaSourceId: ""
    property string _serverPrerollMediaUrl: ""
    property string _serverPrerollPlayMethod: "DirectPlay"
    property bool _serverPrerollStartReported: false
    property bool _serverPrerollStopReported: false
    property int _serverPrerollMainStartMs: 0
    property bool _serverPrerollMainForceRemux: false
    property bool _serverPrerollMainStarted: false
    readonly property bool currentItemIsEpisode:
        String(currentItemType || "").toLowerCase() === "episode"
    property bool _topBarLogoReadyForCurrent: false
    // Le titre attend la resolution du logo (item et, pour un episode, serie).
    // La lecture video et les autres controles ne sont jamais retardes.
    property bool _topBarMetadataPending: false
    property int _topBarMetadataSeq: 0
    property var    fbx
    property var    shared: null
    property string playbackDeviceMode: ""
    property string playbackBackendMode: ""
    // Politique de lecture utilisateur. "smart" conserve les heuristiques ReDeFin ; "directplay" supprime uniquement les remux automatiques de préférence.
    property string playbackRuleMode: "smart"
    function _normalizedPlaybackRuleMode(value) {
        return JF.normalizePlaybackRuleMode(value)
    }
    function _smartPlaybackRulesEnabled(){
        return _normalizedPlaybackRuleMode(playbackRuleMode) !== "directplay"
    }
    function _syncPlaybackRuleMode(reason) {
        var mode = _normalizedPlaybackRuleMode(playbackRuleMode)
        if (playbackRuleMode !== mode) playbackRuleMode = mode
        JF.setPlaybackRuleMode(mode)
    }
    function _storeSensitiveNavContext() {
        return NavContext.storeTarget(shared, root)
    }
    // Handshake léger avec DetailMoviePage. Le marker est posé AVANT le signal de retour afin qu'une fiche recréée sache qu'elle doit afficher son CircleDotsLoader dès sa toute première frame.
    function _markDetailReturnRefresh(reason){
        try {
            if (!shared || !itemId) return false
            NavContext.setDetailReturnRefresh(shared, ({
                itemId: String(itemId || ""),
                positionMs: Math.max(0, Math.floor(Number(_finalExitPositionMs || 0))),
                reason: String(reason || "player-exit"),
                ts: _nowMs()
            }))
            return true
        } catch(e) {
            return false
        }
    }
    signal requestBackToDetails(string returnFocusId)
    // Reload interne demandé lors d'un passage Remux/Transcode -> DirectPlay.
    // instance QtMultimedia, seule façon fiable de retrouver le pipeline d'un
    // DirectPlay natif sur intelce.
    signal requestDirectPlayReload()
    onRequestBackToDetails: { _storeSensitiveNavContext() }
    property var    playlistRef: null
    property var    playerPlaylist: []
    property string playerPlaylistTitle: ""
    property bool forcePlaylistStartAtZero: false
    property bool   autoplayNext: true
    property bool _internalDirectPlayReload: false
    property string selectedSeasonId: ""
    property var    seasonPageOrderIds: []   // liste d’IDs dans l’ordre d’affichage SeasonPage
    property bool clearPlaylistOnExit: true
    function _plHasContent() {
        return PlayerSession.playlistHasContent(playlistRef)
    }
    property bool nextOverlayEnabled: true
    property int  nextOverlayWindowMs: 30000
    property bool nextOverlayAutostart: false
    property int  tvSafeMargin: 60
    // Sous-titres texte rendus localement en DirectPlay pur.
    // Décalage VISUEL appliqué après le calcul des anchors du Loader :
    property int  localSubtitleDirectPlayYOffset: 50
    property bool nextUserHidden: false
    function showNextPanel(){ H.showNextPanel(root, nextLoader.item) }
    function hideNextPanel(){ H.hideNextPanel(root, nextLoader.item) }
    property int  nextRearmDelayMs: 1200
    Timer {
        id: nextRearmTimer
        interval: nextRearmDelayMs
        repeat: false
        onTriggered: {
            nextUserHidden = false
            _syncNextOverlayContext()
        }
    }
    property bool nextPanelShowing: !!(nextLoader.item && nextLoader.item.panelVisible)
    property bool nextUiLocked: !serverPrerollBlocking && nextOverlayEnabled && !nextUserHidden && nextPanelShowing
    onNextUiLockedChanged: {
        if (nextUiLocked) {
            audioMenuVisible = false
            subMenuVisible = false
            controlsVisible = false
            controlsTimer.stop()
        } else {
        }
    }
    function _syncNextOverlayContext(){
        H.syncNextOverlayContext(root, nextLoader.item)
    }
    function _syncPlaylistPresentation(){
        if (!playlistRef) return
        playlistRef.setAutoplayNext(autoplayNext)
        playlistRef.setTitle(playerPlaylistTitle || "")
    }
    function _syncIncomingPlaylist(allowEmpty){
        if (!playlistRef) return
        if (allowEmpty || (playerPlaylist && playerPlaylist.length))
            playlistRef.setList(playerPlaylist || [])
        _syncPlaylistPresentation()
    }
    onPlayerPlaylistChanged: {
        _syncIncomingPlaylist(true)
        _syncNextOverlayContext()
    }
    onPlayerPlaylistTitleChanged: _syncPlaylistPresentation()
    onAutoplayNextChanged: _syncPlaylistPresentation()
    onPlaylistRefChanged: {
        if (playlistRef) {
            _syncIncomingPlaylist(false)
            if (_plHasContent()) {
                var __idx = PlayerSession.syncPlaylistToCurrent(root)
                if (__idx < 0) playlistRef.start()
            }
        }
        _syncNextOverlayContext()
    }
    onSelectedSeasonIdChanged:  { if(!_plHasContent()) PlayerSession.ensureSeasonPlaylistFromHints(root, JFB) }
    onSeasonPageOrderIdsChanged:{ if(!_plHasContent()) PlayerSession.ensureSeasonPlaylistFromHints(root, JFB) }
    onNextUserHiddenChanged:    { _syncNextOverlayContext() }
    property bool skipIntroEnabled: true
    property var  skipIntroSegment: null       // { startMs, endMs, promptMs, hideMs, source, type }
    property string skipIntroLoadedItemId: ""
    property bool skipIntroDismissed: false
    property bool skipIntroConsumed: false
    // Mémorise l’expiration automatique des 10 s pour la fenêtre d’intro
    // courante. Contrairement à dismissed, ce n’est pas une action utilisateur.
    // Elle est réarmée uniquement après un vrai retour arrière dans l’intro.
    property bool skipIntroVisualExpired: false
    property bool _skipIntroWasInside: false
    property bool _skipIntroLastShow: false
    property int  _skipIntroLastPos: -1
    property int  skipIntroRearmRewindDeltaMs: 1200
    property int  skipIntroLeadMs: 5000
    property int  skipIntroEndPadMs: 250
    property int  skipIntroRearmBackMs: 1500
    property bool skipIntroPlaybackArmed: false
    property int  skipIntroPlaybackStartMs: 0
    property bool _skipIntroMainSourceSeen: false
    // chrome est totalement masqué, SkipIntro redevient éligible à l'auto-focus.
    property bool skipIntroFocusReleasedByUser: false
    property bool skipIntroFocusClaimed: false
    // Distingue le focus pris automatiquement lorsque le chrome est masqué du
    // focus demandé explicitement avec ↑ depuis la progressbar. Seul le premier
    property bool skipIntroAutoFocusClaimed: false
    onSkipIntroFocusClaimedChanged: {
        // Un seul focus visuel à la fois : quand SkipIntro est prioritaire,
        // masquer les halos ProgressBar/Transports sans perdre leur position logique.
        _updateControlsActive()
    }
    property bool skipIntroResumeGateActive: false
    property int skipIntroResumeTargetMs: -1
    property string skipIntroResumeGateReason: ""
    function _armSkipIntroResumeGate(targetMs, reason){
        SkipIntro.armSkipIntroResumeGate(root, targetMs, reason)
    }
    function _releaseSkipIntroResumeGate(actualUiMs){
        SkipIntro.releaseSkipIntroResumeGate(root, skipIntroLoader.item, actualUiMs)
    }
    function _setSkipIntroItemActive(it, show){
        SkipIntro.setSkipIntroItemActive(root, it, show)
    }
    function _syncSkipIntroOverlay(){
        SkipIntro.syncSkipIntroOverlay(root, skipIntroLoader.item)
    }
    function _resetSkipIntroState(reason){
        SkipIntro.resetSkipIntroState(root, skipIntroLoader.item)
    }
    function _loadSkipIntroForCurrentItem(reason){
        SkipIntro.loadSkipIntroForCurrentItem(root, skipIntroLoader.item)
    }
    function skipIntroNow(origin, preserveHiddenChrome){
        return SkipIntro.skipIntroNow(
            root,
            skipIntroLoader.item,
            mp.playbackState === MediaPlayer.PlayingState,
            preserveHiddenChrome === true
        )
    }
    function _armSkipIntroPlayback(){
        return SkipIntro.armSkipIntroPlayback(root, skipIntroLoader.item, uiPositionMs())
    }
    function _restoreFocusAfterSkipIntro(origin, preserveHiddenChrome){
        skipIntroFocusClaimed=false
        skipIntroAutoFocusClaimed=false
        if (preserveHiddenChrome === true) {
            // Skip lancé depuis l'auto-focus alors que le chrome était déjà caché :
            // rendre le focus au PlayerOverlay sans réveiller les volets haut/bas.
            controlsTimer.stop()
            controlsVisible=false
            _updateControlsActive()
            try{root.forceActiveFocus()}catch(e0){}
            return
        }
        controlsVisible=true
        controlsFocus=cF_CONTROLS
        _updateControlsActive()
        _syncControlsTimer()
        try{root.forceActiveFocus()}catch(e1){}
    }
    function _focusSkipIntroIfVisible(reason, requestNativeFocus) {
        var w = skipIntroLoader.item
        var nativeFocus = requestNativeFocus !== false
        if (!skipIntroLoader.visible || !w || w.effectiveShow !== true) {
            return false
        }
        try {
            if (w.claimPriorityFocus && w.claimPriorityFocus(reason || "manual-focus", nativeFocus)) {
                skipIntroFocusReleasedByUser = false
                skipIntroFocusClaimed = true
                // Focus AUTO seulement si le chrome est caché ; SkipIntro ne suspend jamais l’auto-hide.
                skipIntroAutoFocusClaimed = (String(reason || "") === "chrome-hidden")
                return true
            }
        } catch(e) {  }
        return false
    }
    function _handleSkipIntroKey(event){
        var handled = SkipIntro.handlePlayerOverlayKey(root,skipIntroLoader.item,event)
        return handled
    }
    property string mediaUrl: ""
    property string playSessionId: ""
    property string currentMediaSourceId: ""
    property real sourceVideoBitrate: 0 // métadonnée UI des jauges, sans effet playback
    property real   runtimeTicks: 0
    property bool   isHls: false
    property bool   lastUsedTranscoding: false
    property bool   lastUsedDirectStream: false
    property bool   lastUsedServerRemux: false
    property bool   serverTimedStream: false
    property bool   timeShifted: false
    property int  baseOffsetMs: 0
    property int  _pendingSeekMs: -1
    function _setPendingSeekMs(value, reason){
        _pendingSeekMs = value
        return _pendingSeekMs
    }
    property bool _wasPlayingBeforeSwitch: false
    property bool _resumeWantedAfterNegotiation: false
    property int  lastUiTargetMs: 0
    property int manualQualityBitrate: 0
    property bool manualRemuxMode: false
    // Zoom local QtMultimedia. 0=100 %, 1=110 %, 2=125 %, 3=150 %. PreserveAspectFit reste fixe : seul le rectangle du VideoOutput est agrandi. Aucun changement de source ni transcodage Jellyfin n'est déclenché.
    property int videoZoomMode: 0
    readonly property real videoZoomFactor: videoZoomMode === 1 ? 1.10
                                                  : (videoZoomMode === 2 ? 1.25
                                                     : (videoZoomMode === 3 ? 1.50 : 1.0))
    function _normalizeVideoZoomMode(mode){ var m=Math.floor(Number(mode)||0); return m<0?0:(m>3?3:m) }
    function _applyVideoZoomMode(mode){ videoZoomMode=_normalizeVideoZoomMode(mode); return true }
    // Vitesse locale QtMultimedia, quantifiée par pas de 0,25x.
    // Certains backends QtMultimedia Freebox peuvent réinitialiser playbackRate lors d'un
    property real playbackSpeed: 1.0
    property int _playbackRateSyncAttempts: 0
    readonly property int playbackRateSyncMaxAttempts: 4
    readonly property int playbackRateSyncDelayMs: 90
    function _normalizePlaybackSpeed(rate){
        return PlayerSession.normalizePlayerPlaybackSpeed(rate)
    }
    function _syncPlaybackSpeedToPlayer(reason, resetBudget){
        return PlayerSession.syncPlayerPlaybackSpeed(root, mp, playbackRateSyncTimer, resetBudget)
    }
    function _applyPlaybackSpeed(rate){
        playbackSpeed=_normalizePlaybackSpeed(rate)
        _syncPlaybackSpeedToPlayer("user", true)
        return true
    }
    // qui n'est pas un DirectPlay pur. La fenêtre est non modale : elle ne
    property bool _speedDirectPlayPopupMounted: false
    property bool _speedDirectPlayPopupShown: false
    property string _speedDirectPlayPopupModeLabel: ""
    readonly property int speedDirectPlayPopupFadeOutAtMs: 4500
    readonly property int speedDirectPlayPopupFadeOutMs: 500
    function _speedRestrictionPlaybackModeLabel(){
        if (lastUsedTranscoding || isHls) return "Transcodage"
        if (lastUsedServerRemux) return "Remux"
        if (lastUsedDirectStream) return "DirectStream"
        if (serverTimedStream || timeShifted || baseOffsetMs > 0) return "Flux serveur"
        return "Flux non DirectPlay"
    }
    function _showSpeedDirectPlayOnlyPopup(){
        try { speedDirectPlayPopupFadeOutTimer.stop() } catch(e0) {}
        try { speedDirectPlayPopupCleanupTimer.stop() } catch(e1) {}
        _speedDirectPlayPopupModeLabel = _speedRestrictionPlaybackModeLabel()
        _speedDirectPlayPopupMounted = true
        _speedDirectPlayPopupShown = false
        Qt.callLater(function(){
            if (root._tearingDownPlayer || !root._speedDirectPlayPopupMounted) return
            root._speedDirectPlayPopupShown = true
            speedDirectPlayPopupFadeOutTimer.restart()
        })
        return true
    }
    Timer {
        id: speedDirectPlayPopupFadeOutTimer
        interval: root.speedDirectPlayPopupFadeOutAtMs
        repeat: false
        running: false
        onTriggered: {
            root._speedDirectPlayPopupShown = false
            speedDirectPlayPopupCleanupTimer.restart()
        }
    }
    Timer {
        id: speedDirectPlayPopupCleanupTimer
        interval: root.speedDirectPlayPopupFadeOutMs
        repeat: false
        running: false
        onTriggered: root._speedDirectPlayPopupMounted = false
    }
    Timer {
        id: playbackRateSyncTimer
        interval: root.playbackRateSyncDelayMs
        repeat: false
        running: false
        onTriggered: root._syncPlaybackSpeedToPlayer("retry", false)
    }
    property bool   controlsVisible: true
    readonly property bool uiChromeTargetVisible: !serverPrerollBlocking
                                                  && !nextUiLocked
                                                  && (controlsVisible || scrubActive || audioMenuVisible || subMenuVisible)
    property real uiChromeOpacity: uiChromeTargetVisible ? 1.0 : 0.0
    readonly property bool uiChromeRenderVisible: uiChromeTargetVisible || uiChromeOpacity > 0.001
    Behavior on uiChromeOpacity { NumberAnimation { duration: 280; easing.type: Easing.InOutQuad } }
    function _skipIntroAutoFocusAllowed() {
        return !uiChromeRenderVisible && !scrubActive &&
               !_chaptersPanelOpen() && !_qualityPanelOpen() && !_trackPanelOpen()
    }
    onUiChromeRenderVisibleChanged: {
        if (uiChromeRenderVisible && skipIntroFocusClaimed) {
            return
        }
        if (!uiChromeRenderVisible && _skipIntroAutoFocusAllowed()) {
            // sans chrome. C'est un nouveau contexte de focus.
            if (skipIntroFocusReleasedByUser) {
                skipIntroFocusReleasedByUser = false
            }
            Qt.callLater(function() {
                if (_skipIntroAutoFocusAllowed())
                    _focusSkipIntroIfVisible("chrome-hidden", true)
            })
        }
    }
    property int    controlsFocus: 1
    property int    menuIndex: 1
    onMenuIndexChanged: {
        var clamped = menuIndex < 1 ? 1 : (menuIndex > 2 ? 2 : menuIndex)
        if (clamped !== menuIndex) { menuIndex = clamped; return }
        H.forgetSettingsFocusIfMoved(root)
    }
    // Dernier bouton de réglages ayant reçu le focus après un choix. Il permet
    // de réaffirmer ce focus une fois le rechargement terminé.
    property int    _lastSettingsFocusControl: -1
    function _restoreFocusAfterSettingsChoice(control, origin){
        return H.restoreFocusAfterSettingsChoice(root, control, origin)
    }
    function _reassertSettingsFocus(origin){ return H.reassertSettingsFocus(root, origin) }
    readonly property int cF_PROGRESS: 0
    readonly property int cF_CONTROLS: 1
    readonly property int cF_MENU: 4
    readonly property int cF_CHAPTERS: 5
    readonly property int cF_QUALITY: 6
    readonly property int cF_ZOOM: 7
    readonly property int cF_SPEED: 8
    // Les boutons latéraux sont volontairement légèrement plus hauts que les commandes de transport centrales, juste sous la ProgressBar.
    readonly property int sideButtonBottomMargin: Math.max(78, tvSafeMargin + 30)
    function getControlsButtonIndex(){ try{if(controlsLoader.item&&controlsLoader.item.hasOwnProperty("focusIndex"))return controlsLoader.item.focusIndex}catch(e){} return 3 }
    function _forceControlsFocusNow(origin){ controlsFocus=cF_CONTROLS; try{root.forceActiveFocus()}catch(e){} _updateControlsActive() }
    function _focusProgressBarSilent(origin){
        controlsFocus=cF_PROGRESS; try{if(controlsLoader.item&&controlsLoader.item.hasOwnProperty("focused"))controlsLoader.item.focused=true; root.forceActiveFocus()}catch(e){}
    }
    function _parkFocusOnProgress(origin){
        if(nextUiLocked||audioMenuVisible||subMenuVisible||scrubActive||_qualityPanelOpen())return; _focusProgressBarSilent(origin||"park-progress")
    }
    function _focusChaptersButtonSilent(origin){ var w=chaptersOverlayLoader.item; if(!w||!w.hasContent||w.panelOpen)return false; controlsFocus=cF_CHAPTERS; root.forceActiveFocus(); return true }
    function _openChaptersPanel(){ var w=chaptersOverlayLoader.item; if(!w||!w.hasContent)return false; controlsVisible=true; controlsTimer.stop(); return w.openPanel(uiPositionMs()) }
    function _seekToChapterMs(ms){
        if (_transportLocked("chapter-seek")) return false
        return PlayerSession.seekToChapter(root,mp,_playbackTimers(),ms)
    }
    function _chaptersPanelOpen(){ return !!(chaptersOverlayLoader.item && chaptersOverlayLoader.item.panelOpen) }
    function _settingsOverlay(){ return settingsOverlayLoader.item }
    // Alias historique utilisé par playerOverlayHelper.js pour les trois panneaux Qualité / Zoom / Vitesse. Audio et Sous-titres conservent leurs booléens historiques dédiés afin de préserver le contrat du helper.
    function _qualityPanelOpen(){ var w=_settingsOverlay(); return !!(w && w.settingsPanelOpen) }
    function _trackPanelOpen(){ var w=_settingsOverlay(); return !!(w && w.trackPanelOpen) }
    function _focusQualityButtonSilent(origin){ var w=_settingsOverlay(); if(!w||w.panelOpen||_chaptersPanelOpen())return false; controlsFocus=cF_QUALITY; root.forceActiveFocus(); return true }
    function _openQualityPanel(){
        var w=_settingsOverlay()
        if(!w || w.panelOpen || _chaptersPanelOpen()) return false
        controlsVisible=true
        controlsTimer.stop()
        _syncSettingsQualityPresentation()
        return w.openQualityPanel(manualQualityBitrate)
    }
    function _openZoomPanel(){ var w=_settingsOverlay(); if(!w||w.panelOpen||_chaptersPanelOpen())return false; controlsVisible=true; controlsTimer.stop(); return w.openZoomPanel(videoZoomMode) }
    function _openSpeedPanel(){ var w=_settingsOverlay(); if(!w||w.panelOpen||_chaptersPanelOpen())return false; controlsVisible=true; controlsTimer.stop(); return w.openSpeedPanel(playbackSpeed) }
    function _activateSettingsButton(control){
        var w = _settingsOverlay()
        if (!w || w.panelOpen || _chaptersPanelOpen() || nextUiLocked || serverPrerollBlocking)
            return false
        if (control === w.controlZoom) controlsFocus = cF_ZOOM
        else if (control === w.controlSpeed) controlsFocus = cF_SPEED
        else if (control === w.controlAudio) { controlsFocus = cF_MENU; menuIndex = 1 }
        else if (control === w.controlSubtitle) { controlsFocus = cF_MENU; menuIndex = 2 }
        else controlsFocus = cF_QUALITY
        root.forceActiveFocus()
        resetControlsTimer()
        if (control === w.controlQuality) return _openQualityPanel()
        if (control === w.controlZoom) return _openZoomPanel()
        if (control === w.controlSpeed) return _openSpeedPanel()
        if (control === w.controlSubtitle) { openSubMenu(); return true }
        openAudioMenu()
        return true
    }
    function _handleQualityPanelKey(event){ var w=_settingsOverlay(); return !!(w&&w.panelOpen&&w.handleKey&&w.handleKey(event)) }
    // Navigation D-Pad unifiée. Elle remplace les interceptions Zoom/Speed historiques et intercepte aussi Quality avant playerOverlayHelper.js afin de conserver la chaîne : Contrôles <-> Vitesse <-> Zoom <-> Qualité.
    function _handleSettingsFocusKey(event){ var w=_settingsOverlay(); return !!(w&&w.handlePlayerFocusKey&&w.handlePlayerFocusKey(event,w.focusedControl,controlsFocus===cF_CONTROLS,getControlsButtonIndex())) }
    function _handleSideFocusKey(event){
        if (!event || _chaptersPanelOpen() || _qualityPanelOpen() || _trackPanelOpen()) return false
        // Sous les boutons latéraux, il n'y a aucune commande : Bas ne change pas le focus.
        // Les menus ouverts restent gérés par leurs propres handlers pour préserver la navigation interne.
        if (event.key === Qt.Key_Down && !audioMenuVisible && !subMenuVisible &&
            (controlsFocus === cF_ZOOM || controlsFocus === cF_SPEED ||
             controlsFocus === cF_CHAPTERS || controlsFocus === cF_QUALITY ||
             controlsFocus === cF_MENU)) {
            event.accepted = true
            return true
        }
        if (controlsFocus === cF_CHAPTERS) {
            if (event.key === Qt.Key_Up) { _focusProgressBarSilent("chapters-up"); event.accepted=true; return true }
            if (event.key === Qt.Key_Left) { controlsFocus=cF_SPEED; root.forceActiveFocus(); event.accepted=true; return true }
            if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) { _setControlsButtonIndex(1,"chapters-to-controls"); _forceControlsFocusNow("chapters-to-controls"); event.accepted=true; return true }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select || event.key === Qt.Key_Ok || event.key === Qt.Key_Space) { _openChaptersPanel(); event.accepted=true; return true }
        }
        if (controlsFocus === cF_MENU) {
            if (event.key === Qt.Key_Up) { _focusProgressBarSilent("tracks-up"); event.accepted=true; return true }
            if (event.key === Qt.Key_Down) { _setControlsButtonIndex(5,"tracks-down"); _forceControlsFocusNow("tracks-down"); event.accepted=true; return true }
            if (event.key === Qt.Key_Left) {
                if (menuIndex > 1) menuIndex=1
                else controlsFocus=cF_QUALITY
                root.forceActiveFocus(); event.accepted=true; return true
            }
            if (event.key === Qt.Key_Right) { if (menuIndex < 2) menuIndex=2; event.accepted=true; return true }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select || event.key === Qt.Key_Ok || event.key === Qt.Key_Space) {
                if (menuIndex === 1) openAudioMenu(); else openSubMenu()
                event.accepted=true; return true
            }
        }
        return false
    }
    property int  audioGateMsDefault: 450
    property bool _gateArmed: false
    property bool _resumeAfterGate: false
    property bool _startupPlayWanted: false
    property int  _startupPlayTries: 0
    property int  startupPlayMaxTries: 3
    property bool _directPlayOpenFallbackUsed: false
    property real _directPlayOpenStartedWallMs: 0
    property int  directPlayOpenFallbackMinMs: 1800
    // Un DirectPlay statique peut être lisible mais non seekable avec le backend QtMultimedia 5.15 de la Freebox. Dans ce cas on mémorise l'échec pour la session et on repasse en remux serveur sans perdre la position courante.
    property bool _staticDirectPlaySeekUnsafe: false
    property string _staticDirectPlaySeekUnsafeItemId: ""
    property bool _staticDirectPlaySeekFallbackInProgress: false
    property bool _staticDirectPlayFallbackAwaitingStableRemux: false
    property int _staticDirectPlayFallbackTargetMs: -1
    property real _staticDirectPlayFallbackStartedWallMs: 0
    function _isStaticDirectPlaySource(){ return PlayerSession.isStaticDirectPlaySource(root) }
    function _fallbackStaticDirectPlayToServerRemux(targetUi, reason){
        return PlayerSession.fallbackStaticDirectPlayToServerRemux(root, mp, _playbackTimers(), targetUi, reason)
    }
    function _guardUnsafeManualDirectPlayRequest(targetUi, reason){
        return PlayerSession.guardUnsafeManualDirectPlayRequest(root, mp, _playbackTimers(), targetUi, reason)
    }
    function _maybeCompleteStaticDirectPlayFallback(reason){ return PlayerSession.maybeCompleteStaticDirectPlayFallback(root, mp) }
    function _tryDirectPlayOpenRemuxFallback(reason){
        return PlayerSession.tryDirectPlayOpenRemuxFallback(root, mp, _playbackTimers(), reason)
    }
    function _cancelStartupPlay(reason){ _startupPlayWanted=false; _startupPlayTries=0; try{startupPlayTimer.stop()}catch(e){} }
    function _kickStartupPlay(reason){
        if (!_startupPlayWanted) return
        if (mp.playbackState === MediaPlayer.PlayingState) {
            _cancelStartupPlay("playing")
            return
        }
        if (_startupPlayTries >= startupPlayMaxTries) {
            if (_tryDirectPlayOpenRemuxFallback("max-tries"))
                return
            _cancelStartupPlay("max-tries")
            return
        }
        _startupPlayTries++
        try { mp.play() } catch(e) {}
        startupPlayTimer.restart()
    }
    // OFF par défaut : les règles audio multicanal existantes sont conservées.
    property string audioOutputMode: "multichannel"
    property string _deferredAudioOutputMode: ""
    function _displayAudioOutputMode(){ return _deferredAudioOutputMode || audioOutputMode }
    property bool audioMenuVisible: false
    property bool subMenuVisible:   false
    property bool scrubActive: false
    property int  scrubAccumUiMs: -1
    property int  _scrubCommitTargetUiMs: -1
    property int  scrubCommitDelayMs: 1000
    property bool commitOnKeyRelease: false
    // DirectPlay obtenu apres un reload complet Remux/Transcodage -> DirectPlay :
    // certains fichiers font bloquer MediaPlayer.seek() 0,5 a 1,5 s sur intelce.
    // DirectPlay natif conserve son seek immediat, deja plus fluide.
    property bool coalescedDirectPlaySeekMode: false
    property int  coalescedDirectPlaySeekDelayMs: 85
    property int  coalescedDirectPlaySeekMaxJumpMs: 30000
    property int  _coalescedLocalSeekTargetUiMs: -1
    property int  _coalescedLocalSeekDirection: 0
    property var itemChapters: null
    property string _chaptersItemId: ""
    property var audioTracks: []
    property var audioStreamIndexMap: []
    property var audioChannelMap: []
    property var audioCodecMap: []
    property var audioBitrateMap: []
    property int audioIndex: 0
    property int selectedAudioStream: -1
    property bool manualDirectPlayMode: false
    property int effectiveAudioStream: -1
    property var subtitleTracks: []
    property var subtitleStreamIndexMap: []
    property var subtitleIsTextMap: []
    property var subtitleCodecMap: []
    // Décision auto calculée à partir des vraies pistes Jellyfin. Vrai uniquement quand l'audio effectivement choisi par défaut est français et que la piste interne active est un sous-titre texte français forcé sûr.
    property int firstAudioStreamIndex: -1
    property int bestFrenchAudioStreamIndex: -1
    property bool preferredFrenchAudioNeedsServerSelection: false
    property int firstInternalSubtitleStreamIndex: -1
    property bool preferredFrenchForcedSubtitleNeedsServerSelection: false
    property bool strictFrenchAutoDirectPlayEligible: false
    property bool hasPriorityInternalSubtitleRisk: false
    property bool hasImplicitFirstInternalSubtitleRisk: false
    property bool hasInternalDvdSubtitle: false
    property bool isDvdSource: false
    property bool requiresInterlacedTsTranscode: false
    property int safeFrenchForcedDvdSubtitleStream: -1
    property int strictFrenchForcedDefaultTextSubtitleStream: -1
    property int legacyFrenchForcedTextSubtitleStream: -1
    property int subtitleIndex: 0
    property int selectedSubtitleStream: -1
    property int effectiveSubtitleStream: -1
    // Verrou de session : un choix manuel « Aucun » ne doit pas être annulé par la règle automatique VO + sous-titres français complets lors d'un seek.
    property bool disableAutoVoFrenchFullSubtitle: false
    // Règle ReDeFin : le texte local QML n'est autorisé qu'en DirectPlay pur. Sur remux/DirectStream/transcode/HLS, Jellyfin garde la piste côté serveur via Embed. Le burn-in texte reste désactivé par défaut à cause du bug ffmpeg Encode + seek/reprise déjà reproduit sur Freebox.
    property bool preferServerSubtitleBurnInOnVideoTranscode: false
    property bool currentPlaybackVideoTranscodeByPolicy: false
    property bool   useLocalSubs: false
    property var    localCues: []
    property string localSubFormat: ""
    property int    localSubStreamIndex: -1
    property int    _localSubtitlePickSeq: 0
    property var    _localSubtitleRequestHandle: null
    property int    subtitleDelayMs: 0
    // Résolution de l'horloge locale des sous-titres. Ce seuil ne décale pas les cues : il évite seulement des écritures QML redondantes à très haute fréquence. 50 ms = précision max de 1/20 s.
    property int    subsUiPushMinDeltaMs: 50
    // QtMultimedia 5.15 notifie position/bufferProgress toutes les 1000 ms par
    // défaut. Pour les sous-titres texte locaux DirectPlay uniquement, on
    readonly property int localSubtitleNotifyIntervalMs: 80
    readonly property int normalMediaNotifyIntervalMs: 1000
    property int    _lastSubsUiPushMs: -1
    property bool _trackSwitchRebaseActive: false
    property int  _trackSwitchRebaseSeq: 0
    property int  _trackSwitchAnchorUiMs: 0
    property real _trackSwitchAnchorWallMs: 0
    property bool _trackSwitchWasPlaying: false
    property int  _trackSwitchSettleTicks: 0
    property bool _trackSwitchForceLocalSeek: false
    property int  _trackSwitchLocalSeekMs: 0
    property int  _seekRestoreAttempts: 0
    property bool _seekRestoreHlsFallbackTried: false
    property int  _seekRestoreLastTargetMs: -1
    property int  _pendingServerTimedBaseMs: -1
    property int  _pendingHardResetBaseMs: -1
    property bool   _sourceResetActive: false
    property int    _sourceResetPhase: 0       // 0=idle, 1=clear, 2=fresh source assigned
    // "directplay-local" : teardown complet du backend avant un DP statique
    // issu d'un switch Remux/Transcode -> DirectPlay.
    property string _sourceResetMode: ""
    property string _sourceResetPendingUrl: ""
    property bool   _sourceResetShouldResume: false
    property int    _sourceResetExpectedUiMs: -1
    property real   _sourceResetStartedWallMs: 0
    property real   _sourceResetAssignedWallMs: 0
    property real   _sourceResetReadyWallMs: 0
    property int    _sourceResetRevision: 0
    property int    _sourceResetPlayRetries: 0
    property int    sourceResetPollMs: 50
    property int    sourceResetClearTimeoutMs: 900
    property int    sourceResetStartRetryMs: 1400
    property int    sourceResetStartTimeoutMs: 6500
    property bool _trackSwitchVerificationActive: false
    property bool _trackSwitchTimebaseVerified: false
    property int  _trackSwitchRequestedUiMs: 0
    property int  _trackSwitchLocalStrategy: 1
    property real _seekRestoreLastCallWallMs: 0
    property bool _seekRestoreAwaitingResult: false
    property int  _seekRestoreStableSamples: 0
    property int  _seekRestoreBestDiffMs: 2147483647
    property int  _seekRestoreBestLocalMs: -1
    property bool _seekRestoreAccepted: false
    property real _seekRestoreReadyWallMs: 0
    property real _seekRestorePrimeWallMs: 0
    property real _seekRestorePauseWallMs: 0
    property int  _seekRestorePhase: 0 // 0=attente, 1=prime, 2=pause demandée, 3=seek émis
    property bool _trackSwitchRestartAfterFailure: false
    property bool _trackSwitchResumeAfterVerified: false
    property string _trackSwitchSourceVideoCodec: ""
    property string _trackSwitchSourceContainer: ""
    property bool _trackSwitchSourceHevc10: false
    property int  trackSwitchSeekToleranceMs: 220
    property int  seekRestoreBootToleranceMs: 1500
    property int  trackSwitchSeekRetryDelayMs: 340
    property int  trackSwitchSeekMaxAttempts: 2
    property int  trackSwitchPrimeMinMs: 180
    property int  trackSwitchPauseGraceMs: 120
    property int  trackSwitchSeekMaxTotalMs: 3200
    property int  trackSwitchSeekHevcMaxTotalMs: 1700
    readonly property int snt: -2147483648
    property int  _pendingAudioStream: snt
    property int  _pendingAudioIndex:  -1
    property bool _pendingAudioManualDirectPlay: false
    property int  _pendingSubStream:   snt
    property int  _pendingSubIndex:    -1
    // ===== Rechargement différé des réglages choisis en pause =====
    // Un choix audio / sous-titre serveur / qualité effectué pendant une pause
    property var  _deferredReloadState: null
    property int  _deferredAudioUiIndex: -1
    property int  _deferredSubtitleUiIndex: -1
    property int  _deferredQualityValue: 0
    property bool _deferredReloadReplaying: false
    property bool _forceResumeAfterDeferredReload: false
    property bool _coalescedNegotiationActive: false
    property var  _coalescedNegotiationCall: null
    // PlaybackInfo anticipé pendant PAUSE ; mp.source ne change qu'à PLAY.
    property int _deferredPrefetchSeq: 0
    property var _deferredPrefetchResult: null
    property int deferredPrefetchDebounceMs: 220
    property int deferredPrefetchTtlMs: 60000
    function _invalidateDeferredPrefetch(reason){
        _deferredPrefetchSeq++; _deferredPrefetchResult = null
        try { deferredPrefetchTimer.stop() } catch(e0) {}
    }
    function _scheduleDeferredPrefetch(reason){
        if (!_deferredReloadPauseActive()) { _invalidateDeferredPrefetch(reason || "not-paused"); return false }
        _deferredPrefetchSeq++; _deferredPrefetchResult = null
        deferredPrefetchTimer.interval = Math.max(80, deferredPrefetchDebounceMs | 0)
        deferredPrefetchTimer.restart(); return true
    }
    Timer {
        id: deferredPrefetchTimer
        interval: Math.max(80, root.deferredPrefetchDebounceMs | 0)
        repeat: false
        onTriggered: TrackSelection.prefetchDeferredReload(root, JF, root._deferredPrefetchSeq)
    }
    // Une pause réelle, hors téléchargement de source, hors scrub et hors
    function _deferredReloadPauseActive(){
        return !_tearingDownPlayer && !serverPrerollBlocking && !_sourceResetActive &&
               !scrubActive && mp.playbackState === MediaPlayer.PausedState
    }
    function _resetDeferredReload(reason){ return TrackSelection.resetDeferredReload(root, reason) }
    property int _autoLocalizeSubStream: -1
    property int resumePrerollMs: 1500
    property bool   scrobbleEnabled: true
    property int    userDataEveryMs: 2500
    property int    resumeCheckpointDelayMs: 1800
    property bool   _startedReported: false
    property string _reportedSessionId: ""
    property string _stoppedReportedSessionId: ""
    property string _stoppedPendingSessionId: ""
    property double _lastProgressSentMs: 0
    property double _lastUserDataSentMs: 0
    property bool   _playbackExitInProgress: false
    property int    _finalExitPositionMs: -1
    property int    _lastPersistableUiMs: 0
    property string lastGoodLogoUrl: ""
    property string lastGoodLogoItemId: ""
    function _normalizeUrl(u){ return H.normalizeUrl(u) }
    property string _lastPushedTitle: ""
    property string _lastPushedLogoNorm: ""
    property string _pendingTitle: ""
    property string _pendingLogo: ""
    property bool   _topBarDirty: false
    Timer {
        id: topBarApplyTimer
        interval: 40; repeat: false
        onTriggered: {
            if (!topBarLoader.item) return
            try {
                topBarLoader.item.baseUrl   = (serverUrl||"").replace(/\/$/,"")
                topBarLoader.item.fbx       = root.fbx
                topBarLoader.item.serverUrl = root.serverUrl
                topBarLoader.item.userId    = root.userId
                topBarLoader.item.showClock   = Qt.binding(function(){ return root.topbarShowClock })
                // Même position que les pages de détail; GIF seulement si chrome visible.
                topBarLoader.item.clockHudActive = Qt.binding(function(){
                    return root.uiChromeOpacity > 0.08 && topBarLoader.visible
                })
                if (topBarLoader.item.hasOwnProperty("safeMarginRight"))
                    topBarLoader.item.safeMarginRight = Qt.binding(function(){ return Math.max(28, root.tvSafeMargin) })
                if (topBarLoader.item.hasOwnProperty("safeMarginLeft"))
                    topBarLoader.item.safeMarginLeft  = Qt.binding(function(){ return Math.max(28, root.tvSafeMargin) })
                if (topBarLoader.item.hasOwnProperty("safeMarginTop"))
                    topBarLoader.item.safeMarginTop   = Qt.binding(function(){ return Math.max(28, root.tvSafeMargin) })
            } catch(e){}
            if (_pendingTitle !== _lastPushedTitle) {
                try { topBarLoader.item.itemTitle = _pendingTitle } catch(e){}
                _lastPushedTitle = _pendingTitle
            }
            var norm = _normalizeUrl(_pendingLogo)
            // Ne jamais conserver le logo de l'episode precedent quand le
            // nouvel item n'en possede pas : le vide est une vraie decision.
            if (norm !== _lastPushedLogoNorm) {
                try { topBarLoader.item.itemLogoUrl = _pendingLogo } catch(e){}
                _lastPushedLogoNorm = norm
            }
            _topBarDirty = false
        }
    }
    function _queueTopBarPush(){ _topBarDirty=true; if(!topBarApplyTimer.running) topBarApplyTimer.start() }
    function isDsLike(){ return isHls || lastUsedTranscoding || lastUsedDirectStream || lastUsedServerRemux || serverTimedStream || timeShifted || (selectedAudioStream >= 0) }
    function isPureDirectPlay(){ return JF.isPureDirectPlay(root) }
    function listIndexForStream(s){ return TrackSelection.indexForStream(subtitleStreamIndexMap, s) }
    function _indexInStreamMap(map, streamIdx){
        if (!(streamIdx >= 0) || !map || map.length === undefined) return -1
        for (var i=0; i<map.length; ++i)
            if (Number(map[i]) === Number(streamIdx)) return i
        return -1
    }
    function _effectiveAudioUiIndexForSettings() { return TrackSelection.effectiveAudioUiIndex(root) }
    function _effectiveSubtitleUiIndexForSettings() { return TrackSelection.effectiveSubtitleUiIndex(root) }
    function _displayAudioUiIndexForSettings(){
        return _deferredAudioUiIndex >= 0 ? _deferredAudioUiIndex
                                          : _effectiveAudioUiIndexForSettings()
    }
    function _displaySubtitleUiIndexForSettings(){
        return _deferredSubtitleUiIndex >= 0 ? _deferredSubtitleUiIndex
                                             : _effectiveSubtitleUiIndexForSettings()
    }
    function _deferredSelectionNote(pending){
        return pending ? "Appliqué à la reprise" : ""
    }
    function _syncTrackMenuIndexes(reason){
        // Les index Audio sont alignés sur les vraies pistes. Les sous-titres
        TrackSelection.syncTrackMenuIndexes(root, null, null)
        var w=_settingsOverlay()
        if(w && w.syncTrackIndexes)
            w.syncTrackIndexes(_displayAudioUiIndexForSettings(),
                               _displaySubtitleUiIndexForSettings())
    }
    function _applyOriginalDirectPlayFromQuality(){
        manualQualityBitrate = 0
        manualRemuxMode = false
        // Le changement de qualité n'est PAS un changement de piste audio.
        // Il doit ouvrir le même fichier statique qu'un DirectPlay démarré à
        // par handleAudioPick() injectait le temps courant dans la négociation
        try {
            return TrackSelection.applyOriginalDirectPlayQuality(root, mp) !== false
        } catch(e) {
            return false
        }
    }
    function _applyManualRemuxFromQuality(){
        return TrackSelection.applyManualRemuxQuality(root, mp)
    }
    function _applyAutomaticQualityFromQuality(){
        return TrackSelection.applyAutomaticQuality(root, mp)
    }
    function durationMs(){
        return PlayerSession.playerDurationMs(root, mp)
    }
    function uiPositionMs(){
        return PlayerSession.playerUiPositionMs(root, mp)
    }
    function subtitleClockMs(){
        return PlayerSession.playerSubtitleClockMs(root, mp)
    }
    function keepUi(){
        return PlayerSession.playerKeepUiPosition(root, mp)
    }
    function _ticks(ms){
        return Math.max(0, ms | 0) * 10000
    }
    function _rememberPersistablePositionMs(pos, reason){
        return PlayerSession.rememberPlayerPersistablePosition(root, mp, pos, reason)
    }
    function _capturePersistablePositionMs(reason){
        return PlayerSession.capturePlayerPersistablePosition(root, mp, reason)
    }
    function _sendPlaybackCheckpoint(reason, isPaused, includeSessionProgress){
        if (serverPrerollBlocking)
            return false
        if (_tearingDownPlayer || _playbackExitInProgress || !scrobbleEnabled ||
                _trackSwitchVerificationActive || _sourceResetActive || _gateArmed ||
                !serverUrl || !accessToken || !userId || !itemId)
            return false
        var pos = _capturePersistablePositionMs(reason || "checkpoint")
        if (pos <= 0) return false
        // la position exacte ReDeFin reste la dernière écriture du cycle.
        _rememberPersistablePositionMs(pos, reason || "checkpoint")
        _sendStartIfNeeded(pos)
        function persistExactUserData(){
            if (_tearingDownPlayer || _playbackExitInProgress) return
            JFB.updateUserPlaybackPosition(serverUrl, accessToken, userId, itemId,
                                           _ticks(pos), function(){}, function(){})
            _lastUserDataSentMs = _nowMs()
        }
        if (includeSessionProgress === true && playSessionId) {
            _sendProgress(!!isPaused, pos, function(){ persistExactUserData() })
            _lastProgressSentMs = _nowMs()
        } else {
            persistExactUserData()
        }
        return true
    }
    function _finalizeCurrentSessionForSwitch(reason){
        if (!playSessionId || _stoppedReportedSessionId === playSessionId ||
                _stoppedPendingSessionId === playSessionId)
            return
        var pos = _capturePersistablePositionMs(reason || "item-switch")
        try { progressTimer.stop() } catch(e0) {}
        try { resumeCheckpointTimer.stop() } catch(e1) {}
        PlayerSession.sendStoppedAtPosition(root, JFB, pos, function(){})
    }
    function finalizePlaybackAndExit(reason){
        if (_playbackExitInProgress)
            return true
        var wasServerPreroll = serverPrerollBlocking
        if (wasServerPreroll)
            PlayerSession.abortServerPrerollForExit(root, mp, JFB, reason || "exit")
        _finalExitPositionMs = wasServerPreroll ? 0 : _capturePersistablePositionMs(reason || "exit")
        if (!wasServerPreroll)
            _rememberPersistablePositionMs(_finalExitPositionMs, reason || "exit")
        _playbackExitInProgress = true
        _resetDeferredReload("player-exit")
        try { scrubCommitTimer.stop() } catch(e0) {}
        _cancelCoalescedLocalSeek()
        try { resumeCheckpointTimer.stop() } catch(e1) {}
        try { progressTimer.stop() } catch(e2) {}
        PlayerSession.sendStoppedAtPosition(root, JFB, _finalExitPositionMs, function(){})
        _tearingDownPlayer = true
        try { TrackSelection.cancelLocalSubtitleRequest(root, "player-exit") } catch(eCancelSub) {}
        scrubActive = false
        scrubAccumUiMs = -1
        _scrubCommitTargetUiMs = -1
        try { mp.stop() } catch(e3) {}
        _markDetailReturnRefresh(reason || "player-exit")
        try { requestBackToDetails(itemId || "") } catch(e4) {}
        return true
    }
    function _beginTrackSwitchRebase(reason, forceLocalSeek){ return PlayerSession.beginTrackSwitchRebase(root, mp, forceLocalSeek) }
    function _trackSwitchRebasedStartMs(fallbackMs){ return PlayerSession.trackSwitchRebasedStartMs(root, fallbackMs) }
    function _armTrackSwitchTimebaseSettle(reason){ PlayerSession.armTrackSwitchTimebaseSettle(root, trackSwitchSettleTimer) }
    function _resetSeekRestoreGuard(targetMs, reason){ PlayerSession.resetSeekRestoreGuard(root, targetMs, reason) }
    function _trackSwitchFragileHevc(){ return PlayerSession.trackSwitchFragileHevc(root) }
    function _seekRestoreIsTrueTrackSwitch(){ return PlayerSession.seekRestoreIsTrueTrackSwitch(root) }
    function _seekRestoreToleranceMs(){ return PlayerSession.seekRestoreToleranceMs(root) }
    function _completeSeekRestoreVerified(targetUi, localNow, diff, reason){ PlayerSession.completeSeekRestoreVerified(root, seekRestoreTimer, trackSwitchVerifiedResumeTimer, targetUi) }
    function _abandonBootSeekRestoreWithoutReload(targetUi, reason){ PlayerSession.abandonBootSeekRestoreWithoutReload(root, seekRestoreTimer, targetUi, reason) }
    function _failTrackSwitchExactSeek(reason){ PlayerSession.failTrackSwitchExactSeek(root, mp, seekRestoreTimer, trackSwitchSettleTimer, trackSwitchFailureRestartTimer) }
    function _retrySeekRestoreWithJellyfinCopyRemux(targetUi, reason){
        PlayerSession.retrySeekRestoreWithJellyfinCopyRemux(root, mp, _playbackTimers(), targetUi, reason)
    }
    function _finishTrackSwitchRebase(reason){
        PlayerSession.finishTrackSwitchRebase(root, trackSwitchSettleTimer)
        _reassertSettingsFocus("track-switch-done")
    }
    // Etat affiché dans Qualité vidéo. Le menu reflète le mode réellement obtenu.
    function _qualityOriginalDirectPlaySelected(){
        return TrackSelection.qualityOriginalDirectPlaySelected(root, mp)
    }
    function _qualityRemuxSelected(){
        return TrackSelection.qualityRemuxSelected(root, mp)
    }
    function _qualityAutomaticServerSelected(){
        return TrackSelection.qualityAutomaticServerSelected(root, mp)
    }
    function _qualityAutomaticServerLabel(){
        return TrackSelection.qualityAutomaticServerLabel(root)
    }
    function _qualityStatusText(){
        return TrackSelection.qualityStatusText(root, mp)
    }
    // Valeur du panneau Qualité vidéo réellement cochée, avec exactement le
    function _activeQualityChoiceValue() { return TrackSelection.activeQualityChoiceValue(root) }
    // Qualité vidéo réellement affichée par le panneau : une attente prend le
    // pas sur l'état appliqué.
    function _displayQualityBitrate() { return TrackSelection.displayQualityBitrate(root) }
    function _displayQualityDirectPlaySelected() { return TrackSelection.displayQualityDirectPlaySelected(root) }
    function _displayQualityRemuxSelected() { return TrackSelection.displayQualityRemuxSelected(root) }
    function _displayQualityAutomaticSelected() { return TrackSelection.displayQualityAutomaticSelected(root) }
    function _displayQualityStatusText() { return TrackSelection.displayQualityStatusText(root) }
    // Qt 5.15 / Freebox : pousser un snapshot cohérent plutôt que maintenir
    // cinq Qt.binding() imbriqués. Cela évite les binding loops du panneau
    // Qualité tout en conservant PlayerTrackSelection comme propriétaire métier.
    function _syncSettingsQualityPresentation(){
        var w = _settingsOverlay()
        if (!w) return false
        try {
            w.directPlaySelected = !!_displayQualityDirectPlaySelected()
            w.remuxSelected = !!_displayQualityRemuxSelected()
            w.automaticServerSelected = !!_displayQualityAutomaticSelected()
            w.automaticQualityLabel = String(_qualityAutomaticServerLabel() || "Automatique")
            w.qualityStatusText = String(_displayQualityStatusText() || "")
            return true
        } catch(e) {
            return false
        }
    }
    // Point d'entrée unique du panneau Qualité vidéo : une seule place décide
    // d'ignorer, de différer ou d'appliquer un choix de qualité.
    function _applyQualityChoice(requested){
        requested = Math.floor(Number(requested || 0))
        if (requested === 0) return false
        if (TrackSelection.decideQualityChoice(root, requested) !== "applyNow") return true
        if (requested === -3) return _applyAutomaticQualityFromQuality()
        if (requested === -2) return _applyManualRemuxFromQuality()
        if (requested === -1) return _applyOriginalDirectPlayFromQuality()
        manualRemuxMode = false
        return TrackSelection.applyManualBitrateQuality(root, mp, requested)
    }
    function _topBarTitleMustWait(){
        if (_topBarMetadataPending) return true
        var wanted = _normalizeUrl(_pendingLogo || "")
        var bar = topBarLoader.item
        if (!bar) return wanted.length > 0
        // Y compris sans logo : attendre que l'ancienne image ait ete effacee.
        if (_normalizeUrl(String(bar.itemLogoUrl || "")) !== wanted) return true
        return bar.logoResolutionComplete !== true
    }
    function _effectiveTopBarTitle(){
        // Aucune apparition centree provisoire : choix final avant le premier rendu.
        if (_topBarTitleMustWait() || _topBarLogoReadyForCurrent) return ""
        return currentItemTitle || ""
    }
    function _syncTopBarLogoReadyState(){
        var candidateNorm = _normalizeUrl(_pendingLogo || "")
        var readyNorm = ""
        var ready = false
        try {
            if (topBarLoader.item && topBarLoader.item.logoReady === true) {
                readyNorm = _normalizeUrl(String(topBarLoader.item.readyLogoUrl || ""))
                ready = candidateNorm.length > 0 && readyNorm === candidateNorm
            }
        } catch(e0) {}
        if (_topBarLogoReadyForCurrent !== ready)
            _topBarLogoReadyForCurrent = ready
        // La fin d'un probe sans logo ne change pas logoReady : elle doit
        // neanmoins liberer le titre centre, une seule fois et sans deplacement.
        var wantedTitle = _effectiveTopBarTitle()
        if (_pendingTitle !== wantedTitle) {
            _pendingTitle = wantedTitle
            _queueTopBarPush()
        }
        return ready
    }
    function refreshCurrentItemTitle(){
        var seq = ++_topBarMetadataSeq
        if (!serverUrl || !accessToken || !itemId) {
            _topBarMetadataPending = false
            currentItemType = ""
            currentItemTitle = ""
            currentItemLogoUrl = ""
            _topBarLogoReadyForCurrent = false
            _pushTopBar()
            return
        }
        var expectedItemId = String(itemId || "")
        var expectedServer = String(serverUrl || "")
        _topBarMetadataPending = true
        _pushTopBar()
        JFB.fetchItem(serverUrl, accessToken, expectedItemId, function(it){
            if (seq !== root._topBarMetadataSeq || expectedItemId !== String(root.itemId || "") ||
                    expectedServer !== String(root.serverUrl || "")) return
            currentItemType = String(it && it.Type || "")
            currentItemTitle = H.labelForItem(it, itemTitle || "")
            currentItemLogoUrl = H.logoUrlFromItem(root, JFB, it)
            if (H.hasQueryTag(currentItemLogoUrl)) {
                lastGoodLogoUrl = currentItemLogoUrl
                lastGoodLogoItemId = (it && it.Id) ? String(it.Id) : expectedItemId
            }
            _topBarLogoReadyForCurrent = false
            PlayerSession.ensureAutoEpisodePlaylistWithItem(root, JFB, it)
            var typ = String(it && it.Type || "")
            if (!H.hasQueryTag(currentItemLogoUrl) &&
                    (typ === "Episode" || typ === "Season")) {
                // Le logo appartient generalement a la serie, pas a l'episode.
                // Ne pas exposer le fallback titre entre ces deux requetes.
                _pushTopBar()
                H.ensureSeriesLogoTag(root, JFB, it, function(){
                    if (seq !== root._topBarMetadataSeq ||
                            expectedItemId !== String(root.itemId || "")) return
                    root._topBarMetadataPending = false
                    root._pushTopBar()
                })
            } else {
                _topBarMetadataPending = false
                _pushTopBar()
            }
        }, function(){
            if (seq !== root._topBarMetadataSeq || expectedItemId !== String(root.itemId || "")) return
            _topBarMetadataPending = false
            currentItemType = ""
            currentItemTitle = itemTitle || ""
            currentItemLogoUrl = ""
            _topBarLogoReadyForCurrent = false
            _pushTopBar()
        }, fbx)
    }
    function _pushTopBar(){
        var candidate = currentItemLogoUrl || ""
        var hasGoodForThisItem =
                lastGoodLogoUrl.length > 0 &&
                String(lastGoodLogoItemId || "") === String(itemId || "")
        if ((!candidate || !candidate.length) && hasGoodForThisItem)
            candidate = lastGoodLogoUrl
        if (hasGoodForThisItem && !H.hasQueryTag(candidate) && H.hasQueryTag(lastGoodLogoUrl))
            candidate = lastGoodLogoUrl
        var previousCandidateNorm = _normalizeUrl(_pendingLogo || "")
        var candidateNorm = _normalizeUrl(candidate)
        if (previousCandidateNorm !== candidateNorm)
            _topBarLogoReadyForCurrent = false
        _pendingLogo = candidate
        // Si TopBar possède déjà ce logo en cache, le fallback titre peut être
        // levé immédiatement. Sinon les signaux logoReady/readyLogoUrl prennent
        // le relais sans polling périodique.
        _syncTopBarLogoReadyState()
        _pendingTitle = _effectiveTopBarTitle()
        _queueTopBarPush()
    }
    function _pushProgress(pos, dur){
        if (!controlsLoader.item) return
        try {
            controlsLoader.item.posMs = pos
            controlsLoader.item.durMs = dur
        } catch(e){}
    }
    function _pushLocalSubsUiMs(pos, force){
        // Le paramètre pos est conservé pour compatibilité avec playerOverlayHelper.js, mais les sous-titres ne suivent plus uiPositionMs() : cette horloge peut volontairement pointer sur une cible future pendant un seek/rebase.  Une seule source de vérité : subtitleClockMs().
        H.pushLocalSubsUiMs(root, subsLoader.item, subtitleClockMs(), force)
    }
    function updateClocksFromPlayback(){
        var d=durationMs(), pos=uiPositionMs()
        _pushProgress(pos, d)
        if (subsLoader.item){
            _pushLocalSubsUiMs(pos, false)
            subsLoader.item.controlsVisible = (controlsVisible || scrubActive)
        }
        if (nextLoader.item && nextOverlayEnabled && !serverPrerollBlocking) {
            var nearNextWindow = (d > 0 && (d - pos) <= (nextOverlayWindowMs + 5000))
            if (nearNextWindow || nextPanelShowing) {
                var w = nextLoader.item
                w.uiMs = pos
                w.durMs = d
            }
        }
        _syncSkipIntroOverlay()
    }
    function updateClocksFromPlaybackThrottled(force){
        if (force === true) {
            _lastUiClockPushWallMs = _nowMs()
            updateClocksFromPlayback()
            return
        }
        var now = _nowMs()
        var minDelay = Math.max(80, uiClockPushMinIntervalMs | 0)
        if (_lastUiClockPushWallMs > 0 && (now - _lastUiClockPushWallMs) < minDelay)
            return
        _lastUiClockPushWallMs = now
        updateClocksFromPlayback()
    }
    function disableLocalSubsOverlay(){ TrackSelection.disableLocalSubsOverlay(root,subsLoader.item,null,null); _syncTrackMenuIndexes("disableLocalSubsOverlay") }
    function _tryAutoLocalizeAfterDP(){ TrackSelection.tryAutoLocalizeAfterDP(root, subsLoader.item) }
    function _updateControlsActive(){
        if (controlsLoader.item) {
            if (controlsLoader.item.hasOwnProperty("active"))
                controlsLoader.item.active = !skipIntroFocusClaimed &&
                                             !audioMenuVisible && !subMenuVisible &&
                                             (controlsFocus === cF_CONTROLS)
            if (controlsLoader.item.hasOwnProperty("focused"))
                controlsLoader.item.focused = !skipIntroFocusClaimed &&
                                              (controlsFocus === cF_PROGRESS)
        }
    }
    function _syncControlsTimer(){
        if (audioMenuVisible || subMenuVisible || scrubActive || _chaptersPanelOpen() || _qualityPanelOpen()){ controlsVisible = true; controlsTimer.stop() }
        else { if (controlsVisible) controlsTimer.restart() }
    }
    function _focusControlsLater(){
        Qt.callLater(function(){
            try {
                if (!audioMenuVisible && !subMenuVisible && !nextUiLocked)
                    root.forceActiveFocus()
                _updateControlsActive()
            } catch(e) {}
        })
    }
    function _cancelHardSourceReset(reason){ PlayerSession.cancelHardSourceReset(root, sourceResetTimer) }
    function _commitFreshServerTimedSource(reason){
        PlayerSession.completeFreshServerTimedSource(root, mp, sourceResetTimer, subsLoader.item)
        _reassertSettingsFocus("fresh-source-commit")
    }
    function _finishFreshServerTimedSourceTimeout(reason){
        PlayerSession.completeFreshServerTimedSource(root, mp, sourceResetTimer, subsLoader.item)
        // Le reset dur a expiré sans progression : le comportement de sortie
        // reste celui du succès, mais la gate de chargement ne doit plus
        // pouvoir rester armée indéfiniment sur un pipeline qui ne démarre pas.
        _releaseVideoLoading("fresh-source-reset-timeout")
        _reassertSettingsFocus("fresh-source-timeout")
    }
    function _beginHardSourceReset(u,shouldResume){ PlayerSession.beginHardSourceReset(root,mp,sourceResetTimer,audioGateDelay,startupPlayTimer,subsLoader.item,u,shouldResume) }
    function _beginFreshDirectPlayReset(u,shouldResume,targetUi){
        PlayerSession.beginFreshDirectPlayReset(root,mp,sourceResetTimer,audioGateDelay,startupPlayTimer,subsLoader.item,u,shouldResume,targetUi)
    }
    function _mediaUrlSwap(u,resume){ PlayerSession.mediaUrlSwap(root,mp,_playbackTimers(),subsLoader.item,u,resume) }
    function refreshStreams(done){
        TrackSelection.refreshStreams(root, JF, function(ok){
            if (typeof done === "function") {
                try { done(ok) } catch(e0) {}
            }
        })
    }
    // Le cycle Local Intros est orchestré par le routeur playback. PlayerOverlay
    // conserve seulement les façades appelées par ses handlers et par le helper.
    function _resetServerPrerollState(reason) {
        PlayerSession.resetServerPrerollState(root, mp, JFB, reason)
    }
    function _tryStartServerPreroll(mainStartMs, forceMainRemux, rawResumeMs){
        return PlayerSession.tryStartServerPreroll(root, mp, JFB, mainStartMs, forceMainRemux, rawResumeMs)
    }
    function negotiatePlayback(startMs, forceHls, preferTicks, forceMp4, forceDPOnAudioSwitch, extra){
        return H.negotiateAndApply(root, mp, JF, subsLoader.item,
                                   _playbackTimers(),
                                   startMs, forceHls, preferTicks, forceMp4,
                                   forceDPOnAudioSwitch, extra)
    }
    function loadLocalSubtitleByStreamIndex(streamIdx, cb, preserveOnFailure){
        return TrackSelection.loadLocalSubtitleForOverlay(root, JFB, subsLoader.item, streamIdx, function(){
            if (typeof cb === "function") {
                // Une exception dans le callback ne doit jamais le rejouer :
                // il peut déjà avoir modifié les pistes ou lancé une négociation.
                try { cb.apply(null, arguments) } catch(e0) {
                    console.warn("ReDeFin: erreur dans le callback de sous-titres locaux")
                }
            }
        }, preserveOnFailure)
    }
    function _reportUiPositionMs(reason, isPaused){ return PlayerSession.reportUiPositionMs(root, mp) }
    function _armFrozenPlaybackWatch(reason, windowMs){
        PlayerSession.armFrozenPlaybackWatch(root, mp, _playbackTimers().frozenWatch, reason, windowMs)
    }
    function _stopFrozenPlaybackWatch(reason){ PlayerSession.stopFrozenPlaybackWatch(root, _playbackTimers().frozenWatch) }
    function _tickFrozenPlaybackWatch(){
        if (serverPrerollBlocking) {
            _stopFrozenPlaybackWatch("server-preroll")
            return
        }
        PlayerSession.tickFrozenPlaybackWatch(root, mp, _playbackTimers().frozenWatch, _playbackTimers().mediaGuard)
    }
    function _sendStartIfNeeded(positionMs){
        var p = (positionMs !== undefined && positionMs !== null)
              ? _clampUi(Number(positionMs) || 0)
              : _clampUi(keepUi())
        PlayerSession.sendStartIfNeeded(root, JFB, p)
    }
    function _sendProgress(isPaused, positionMs, done){
        var p = (positionMs !== undefined && positionMs !== null)
              ? _clampUi(Number(positionMs) || 0)
              : _capturePersistablePositionMs(isPaused ? "progress-paused" : "progress")
        PlayerSession.sendProgress(root, JFB, isPaused, p, done)
    }
    function _sendStopped(){ PlayerSession.sendStopped(root, JFB) }
    Timer {
        id: resumeCheckpointTimer
        interval: Math.max(500, resumeCheckpointDelayMs)
        repeat: false
        running: false
        onTriggered: {
            if (serverPrerollBlocking)
                return
            if (mp.playbackState === MediaPlayer.PlayingState &&
                    !_trackSwitchVerificationActive && !_sourceResetActive)
                _sendPlaybackCheckpoint("resume-checkpoint", false, true)
        }
    }
    Timer {
        id: progressTimer
        interval: Math.max(500, userDataEveryMs)
        repeat: true
        running: scrobbleEnabled && !!itemId
        onTriggered: {
            if (serverPrerollBlocking) return
            if (!scrobbleEnabled || _tearingDownPlayer || _playbackExitInProgress) return
            if (_trackSwitchVerificationActive || _sourceResetActive || _gateArmed) return
            if (mp.playbackState === MediaPlayer.PlayingState) {
                _sendPlaybackCheckpoint("periodic", false, true)
            }
            // Aucun envoi depuis StoppedState : QtMultimedia peut déjà avoir remis la position à zéro à cet instant.
        }
    }
    function _mediaSeekable() { return PlayerSession.mediaSeekable(root, mp) }
    function shouldNetworkSeek() { return PlayerSession.playerShouldNetworkSeek(root, mp) }
    function _clampUi(t) { return PlayerSession.clampPlayerUi(root, t) }
    function showScrubPreview(targetUi){ _pushProgress(targetUi, durationMs()) }
    function _serverSeekFallback(targetUi,reason){ PlayerSession.serverSeekFallback(root,mp,_playbackTimers(),targetUi,reason) }
    function _localSeekTo(targetUi,reason){ return PlayerSession.localSeekTo(root,mp,_playbackTimers(),targetUi,reason) }
    function _coalescedLocalSeekEligible() { return PlayerSession.coalescedLocalSeekEligible(root) }
    function _cancelCoalescedLocalSeek() { return PlayerSession.cancelCoalescedLocalSeek(root, coalescedLocalSeekTimer) }
    function _queueCoalescedLocalSeek(deltaMs) { return PlayerSession.queueCoalescedLocalSeek(root, coalescedLocalSeekTimer, deltaMs) }
    function _flushCoalescedLocalSeek() { return PlayerSession.flushCoalescedLocalSeek(root) }
    function commitScrub() { return PlayerSession.commitScrub(root, mp, subsLoader.item) }
    function seekBy(deltaMs) { return PlayerSession.seekBy(root, mp, _playbackTimers(), subsLoader.item, deltaMs) }
    Timer {
        id: controlsTimer
        interval: 5000
        running: controlsVisible
        repeat: false
        onTriggered: {
            _parkFocusOnProgress("auto-hide-to-progress")
            controlsVisible = false
        }
    }
    Timer {
        id: sourceResetTimer
        interval: sourceResetPollMs
        repeat: true
        running: false
        onTriggered: PlayerSession.tickSourceReset(root, mp, sourceResetTimer, seekRestoreTimer, subsLoader.item)
    }
    Timer {
        id: startupPlayTimer
        interval: 650
        repeat: false
        onTriggered: _kickStartupPlay("timer")
    }
    Timer {
        id: trackSwitchFailureRestartTimer
        interval: 180
        repeat: false
        onTriggered: {
            if (!_trackSwitchRestartAfterFailure) return
            _trackSwitchRestartAfterFailure = false
            try { mp.play() } catch(e0) {}
            _startupPlayWanted = true
            _resumeAfterGate = true
            startupPlayTimer.restart()
        }
    }
    Timer {
        id: trackSwitchVerifiedResumeTimer
        interval: 80
        repeat: false
        onTriggered: {
            if (!_trackSwitchResumeAfterVerified) return
            _trackSwitchResumeAfterVerified = false
            try { mp.play() } catch(e0) {}
            _startupPlayWanted = true
            _resumeAfterGate = true
            startupPlayTimer.restart()
        }
    }
    Timer {
        id: audioGateDelay
        interval: audioGateMsDefault; repeat: false
        onTriggered: {
            if (_gateArmed){
                _gateArmed=false
                if (subsLoader.item) subsLoader.item.gateArmed=false
                if (_resumeAfterGate) _kickStartupPlay("audioGate")
            }
        }
    }
    Timer {
        id: seekRestoreTimer
        interval: 100
        repeat: true
        running: false
        onTriggered: PlayerSession.tickSeekRestore(root, mp, seekRestoreTimer)
    }
    Timer { id: scrubCommitTimer; interval: scrubCommitDelayMs; repeat: false; running: false; onTriggered: commitScrub() }
    Timer {
        id: coalescedLocalSeekTimer
        interval: Math.max(16, coalescedDirectPlaySeekDelayMs | 0)
        repeat: false
        running: false
        onTriggered: _flushCoalescedLocalSeek()
    }
    Timer {
        id: trackSwitchSettleTimer
        interval: 120
        repeat: true
        running: false
        onTriggered: {
            if (!_trackSwitchRebaseActive) { stop(); return }
            _trackSwitchSettleTicks++
            _lastUiClockPushWallMs = 0
            updateClocksFromPlayback()
            var pendingOk = (_pendingSeekMs < 0)
            var resetOk = !_sourceResetActive
            var verifiedOk = resetOk && (_trackSwitchTimebaseVerified || !_trackSwitchForceLocalSeek)
            var progressOk = resetOk && (mp.playbackState === MediaPlayer.PlayingState && mp.position > 0)
            if (pendingOk && verifiedOk && (_trackSwitchSettleTicks >= 18 || progressOk)) {
                root._finishTrackSwitchRebase("settled-verified")
            }
        }
    }
    property bool _mediaErrorRecoveryArmed: false
    property int  _mediaErrorRecoveryCount: 0
    property bool _mediaErrorRecoveryInProgress: false
    property int  _mediaErrorRecoverySafeUiMs: 0
    property real _mediaErrorProgressGuardUntilWallMs: 0
    property string _mediaErrorRecoveryReason: ""
    Timer {
        id: mediaErrorRecoveryGuard
        interval: 1200
        repeat: false
        onTriggered: root._mediaErrorRecoveryArmed = false
    }
    Timer {
        id: pauseResumeProbeTimer
        interval: 1000
        repeat: true
        running: false
        onTriggered: {
            _pauseResumeProbeTicks++
            var expected = Math.max(_pauseWatchStartedUiMs, _pauseWatchLastStableUiMs)
            var nearZeroAfterResume = expected > 10000 && uiPositionMs() < 3000
            if (_pauseResumeProbeTicks >= 30 || nearZeroAfterResume)
                pauseResumeProbeTimer.stop()
        }
    }
    Timer {
        id: frozenPlaybackWatchTimer
        interval: 1000
        repeat: false
        running: false
        onTriggered: root._tickFrozenPlaybackWatch()
    }
    function _recoverFromMediaError(){ PlayerSession.recoverFromMediaError(root,mp,_playbackTimers().frozenWatch,_playbackTimers().mediaGuard) }
    Timer {
        id: videoLoadingShowTimer
        interval: Math.max(0, videoLoadingShowDelayMs)
        repeat: false
        onTriggered: {
            if (videoLoadingRequested)
                videoLoadingVisible = true
        }
    }
    Timer {
        id: videoLoadingHideTimer
        interval: Math.max(0, videoLoadingHideDelayMs)
        repeat: false
        onTriggered: {
            if (!videoLoadingRequested)
                videoLoadingVisible = false
        }
    }
    Timer {
        id: videoLoadingReleaseTimer
        interval: 160
        repeat: false
        onTriggered: {
            if (!_tearingDownPlayer && !_sourceResetActive &&
                    mp.playbackState === MediaPlayer.PlayingState &&
                    (mp.status === MediaPlayer.Loaded || mp.status === MediaPlayer.Buffered))
                _releaseVideoLoading("playback-ready")
        }
    }
    MediaPlayer {
        id: mp
        // QtMultimedia 5.15 : déclarer explicitement la bande-son comme flux
        // vidéo afin que le backend audio Freebox puisse lui appliquer le
        // routage / la priorité adaptés, notamment face à une source Bluetooth.
        // Qt exige que le rôle soit défini avant la source.
        audioRole: MediaPlayer.VideoRole
        autoPlay: true
        source: root.mediaUrl
        // Qt 5.15 : positionChanged suit notifyInterval (1000 ms par défaut).
        // Une cadence de 80 ms n'est activée que lorsque l'overlay SRT/VTT
        // DirectPlay est réellement utilisé ; le reste du temps on conserve le
        // coût historique de 1000 ms sur la Révolution.
        notifyInterval: root.useLocalSubs ? root.localSubtitleNotifyIntervalMs
                                          : root.normalMediaNotifyIntervalMs
        // Application impérative via _syncPlaybackSpeedToPlayer(). Un binding
        // seul ne se réévalue pas si le backend remet lui-même le taux à 1x.
        playbackRate: 1.0
        onPlaybackRateChanged: {
            if (_tearingDownPlayer) return
            var wanted=root._normalizePlaybackSpeed(root.playbackSpeed)
            var current=Number(mp.playbackRate)
            if (!isFinite(current) || isNaN(current)) current=1.0
            if (Math.abs(current-wanted)>0.001 &&
                    root._playbackRateSyncAttempts < root.playbackRateSyncMaxAttempts &&
                    !playbackRateSyncTimer.running) {
                root._playbackRateSyncAttempts++
                playbackRateSyncTimer.restart()
            }
        }
        onError: if (!_tearingDownPlayer && mp.error !== MediaPlayer.NoError){
            if (serverPrerollBlocking) {
                if (_serverPrerollState === 2)
                    PlayerSession.finishServerPreroll(root, mp, JFB, "media-error")
                return
            }
            _recoverFromMediaError()
        }
        onSourceChanged: {
            if (_tearingDownPlayer) return
            var hasSource = String(mp.source || "").length > 0
            if (!hasSource)
                _skipIntroMainSourceSeen = false
            if (_serverPrerollState === 3 && _serverPrerollMainStarted && hasSource)
                PlayerSession.completeServerPrerollTransition(root)
            // Cette source est le média principal uniquement une fois sorti de l'état pré-roll. Cela évite d'armer Skip Intro sur le clip Local Intros.
            if (hasSource && !serverPrerollBlocking)
                _skipIntroMainSourceSeen = true
            if (hasSource)
                root._syncPlaybackSpeedToPlayer("source-changed", true)
        }
        onPlaybackStateChanged: {
            if (_tearingDownPlayer) return
            if (serverPrerollBlocking) {
                if (serverPrerollActive && mp.playbackState === MediaPlayer.PlayingState) {
                    PlayerSession.sendServerPrerollStartIfNeeded(root, mp, JFB)
                    _cancelStartupPlay("server-preroll-playing")
                    _scheduleVideoLoadingRelease("server-preroll-playing")
                }
                return
            }
            if (mp.playbackState === MediaPlayer.PlayingState)
                root._syncPlaybackSpeedToPlayer("state-playing", true)
            if (mp.playbackState === MediaPlayer.PausedState && !_pauseWatchInPause) {
                _stopFrozenPlaybackWatch("paused")
                _pauseWatchInPause = true
                _pauseWatchStartedWallMs = _nowMs()
                _pauseWatchStartedUiMs = uiPositionMs()
                _pauseWatchLastStableUiMs = Math.max(_pauseWatchLastStableUiMs, _pauseWatchStartedUiMs)
            } else if (mp.playbackState === MediaPlayer.PlayingState && _pauseWatchInPause) {
                var pausedMs = _pauseWatchStartedWallMs > 0 ? Math.floor(_nowMs() - _pauseWatchStartedWallMs) : 0
                _pauseWatchResumeSeq++
                _pauseResumeProbeTicks = 0
                pauseResumeProbeTimer.restart()
                if (pausedMs >= frozenPlaybackLongPauseThresholdMs && (_serverTimedLike() || lastUsedServerRemux))
                    _armFrozenPlaybackWatch("resumeAfterLongPause pausedMs=" + pausedMs, frozenPlaybackWatchWindowMs)
                _pauseWatchInPause = false
            }
            if (controlsLoader.item && controlsLoader.item.hasOwnProperty("isPlaying"))
                controlsLoader.item.isPlaying=(mp.playbackState===MediaPlayer.PlayingState)
            if (mp.playbackState === MediaPlayer.PlayingState){
                if (_skipIntroMainSourceSeen)
                    _armSkipIntroPlayback()
                _sendStartIfNeeded()
                _cancelStartupPlay("state-playing")
                _scheduleVideoLoadingRelease("state-playing")
                resumeCheckpointTimer.restart()
            } else if (mp.playbackState === MediaPlayer.PausedState) {
                try { resumeCheckpointTimer.stop() } catch(ePauseCheckpoint) {}
                if (!_trackSwitchVerificationActive && !_sourceResetActive && !_gateArmed) {
                    _sendPlaybackCheckpoint("pause-checkpoint", true, true)
                }
            } else if (mp.playbackState === MediaPlayer.StoppedState) {
                try { resumeCheckpointTimer.stop() } catch(eStoppedCheckpoint) {}
                // Ne jamais envoyer de Progress ici : position peut déjà valoir 0.
            }
        }
        onPositionChanged: {
            if (_tearingDownPlayer) return
            if (serverPrerollBlocking) {
                if (serverPrerollActive && mp.playbackState === MediaPlayer.PlayingState && mp.position > 0) {
                    PlayerSession.sendServerPrerollStartIfNeeded(root, mp, JFB)
                    // Le pré-roll est réellement en train d'avancer : ne pas attendre
                    // que QtMultimedia quitte tardivement Loading/Buffered pour masquer
                    // le spinner par-dessus une image déjà décodée.
                    if (!_sourceResetActive) _releaseVideoLoading("server-preroll-progress")
                }
                return
            }
            if (mp.playbackState === MediaPlayer.PlayingState && _skipIntroMainSourceSeen && !skipIntroPlaybackArmed)
                _armSkipIntroPlayback()
            if (mp.playbackState === MediaPlayer.PlayingState && mp.position > 0) {
                // La progression effective du MediaPlayer est un signal plus fiable
                // que status=Loaded/Buffered sur le backend Freebox : certains flux
                // restent en Loading plusieurs secondes alors que la vidéo est visible.
                if (!_sourceResetActive) _releaseVideoLoading("position-progress")
            }
            _maybeCompleteStaticDirectPlayFallback("position")
            // Synchronisation locale dédiée : on suit directement MediaPlayer.position (+ baseOffsetMs) à chaque progression utile. La ProgressBar peut rester throttlée indépendamment.
            if (!scrubActive && useLocalSubs && subsLoader.item)
                _pushLocalSubsUiMs(0, false)
            if (!scrubActive) updateClocksFromPlaybackThrottled(false)
            if (_mediaErrorRecoveryInProgress && _mediaErrorRecoverySafeUiMs > 0 &&
                    mp.playbackState === MediaPlayer.PlayingState &&
                    uiPositionMs() >= _mediaErrorRecoverySafeUiMs - 2000 &&
                    mp.position > 0) {
                _mediaErrorRecoveryInProgress = false
                _stopFrozenPlaybackWatch("positionRecovered")
            }
            if (mp.playbackState === MediaPlayer.PlayingState && uiPositionMs() > 0 &&
                    !(_mediaErrorRecoveryInProgress && mp.position <= 1000 && uiPositionMs() <= baseOffsetMs + 1500)) {
                var stableUi = uiPositionMs()
                _pauseWatchLastStableUiMs = stableUi
                _pauseWatchLastStableWallMs = _nowMs()
                _rememberPersistablePositionMs(stableUi, "position")
            }
        }
        onDurationChanged: {
            if (_tearingDownPlayer || serverPrerollBlocking) return
            updateClocksFromPlaybackThrottled(true)
        }
        onSeekableChanged: {
            if (_tearingDownPlayer || serverPrerollBlocking) return
            if (manualDirectPlayMode && _isStaticDirectPlaySource() &&
                    _pendingSeekMs > 0 && mp.seekable === false &&
                    (mp.status === MediaPlayer.Buffered || mp.status === MediaPlayer.Loaded)) {
                _fallbackStaticDirectPlayToServerRemux(_pendingSeekMs,
                                                       "manual-directplay-not-seekable")
            }
        }
        onStatusChanged: {
            if (_tearingDownPlayer) return
            if (serverPrerollBlocking) {
                if (mp.status===MediaPlayer.Buffered || mp.status===MediaPlayer.Loaded) {
                    _kickStartupPlay("server-preroll-status-ready")
                    _scheduleVideoLoadingRelease("server-preroll-status-ready")
                } else if (mp.status===MediaPlayer.Loading || mp.status===MediaPlayer.Stalled) {
                    // Loading peut rester signalé pendant qu'un Local Intro joue déjà.
                    // Stalled reste toujours bloquant ; Loading ne réarme le spinner
                    // que tant qu'aucune progression de lecture n'est visible.
                    if (mp.playbackState !== MediaPlayer.PausedState &&
                            (mp.status===MediaPlayer.Stalled ||
                             mp.playbackState !== MediaPlayer.PlayingState || mp.position <= 0))
                        _armVideoLoading("server-preroll-status-loading")
                }
                if (_serverPrerollState === 2 && mp.status===MediaPlayer.EndOfMedia)
                    PlayerSession.finishServerPreroll(root, mp, JFB, "end-of-media")
                return
            }
            if (mp.status===MediaPlayer.Buffered || mp.status===MediaPlayer.Loaded) {
                if (!_mediaErrorRecoveryInProgress)
                    _mediaErrorRecoveryCount = 0
                root._syncPlaybackSpeedToPlayer("status-ready", true)
                _maybeCompleteStaticDirectPlayFallback("status-ready")
                _kickStartupPlay("status-ready")
                _scheduleVideoLoadingRelease("status-ready")
            } else if (mp.status===MediaPlayer.Loading || mp.status===MediaPlayer.Stalled) {
                if (mp.playbackState !== MediaPlayer.PausedState &&
                        (mp.status===MediaPlayer.Stalled ||
                         mp.playbackState !== MediaPlayer.PlayingState || mp.position <= 0))
                    _armVideoLoading("status-loading")
            }
            if (_pendingSeekMs>=0 && (mp.status===MediaPlayer.Buffered || mp.status===MediaPlayer.Loaded)) seekRestoreTimer.start()
            if (mp.status===MediaPlayer.EndOfMedia){
                _releaseVideoLoading("end-of-media")
                _resetDeferredReload("end-of-media")
                var endPos = durationMs() > 0 ? durationMs() : _capturePersistablePositionMs("end-of-media")
                _rememberPersistablePositionMs(endPos, "end-of-media")
                PlayerSession.sendStoppedAtPosition(root, JFB, endPos, function(){})
                if (playlistRef && autoplayNext) {
                    hideNextPanel()
                    nextHiddenWaiter.budget = nextHideMaxWaitMs
                    nextHiddenWaiter.restart()
                }
            }
        }
    }
    VideoOutput {
        anchors.centerIn: parent
        width: Math.round(parent.width * root.videoZoomFactor)
        height: Math.round(parent.height * root.videoZoomFactor)
        source: mp
        fillMode: VideoOutput.PreserveAspectFit
        z: 1
        focus: false
        opacity: (root._trackSwitchVerificationActive && !root._trackSwitchTimebaseVerified) ? 0 : 1
    }
    // Feedback visuel pendant l'ouverture initiale, une reprise serveur ou un buffering réel. Aucun focus ni interception télécommande.
    // Notification de contrainte Vitesse. Placée au-dessus du chrome et du
    // loader vidéo, mais sans focus ni MouseArea afin de ne jamais perturber
    // la télécommande pendant la lecture.
    Item {
        z: 4500
        anchors.fill: parent
        enabled: false
        visible: root._speedDirectPlayPopupMounted || opacity > 0.001
        opacity: root._speedDirectPlayPopupShown ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation {
                duration: root._speedDirectPlayPopupShown
                          ? 280
                          : root.speedDirectPlayPopupFadeOutMs
                easing.type: root._speedDirectPlayPopupShown
                             ? Easing.OutCubic
                             : Easing.InOutQuad
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 150
            width: Math.min(690, Math.max(460, parent.width - 180))
            height: popupTextColumn.implicitHeight + 38
            radius: 12
            color: Qt.rgba(0.075, 0.075, 0.085, 0.96)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.20)
            Column {
                id: popupTextColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Text {
                    width: parent.width
                    text: "Vitesse indisponible"
                    textFormat: Text.PlainText
                    color: "white"
                    font.pixelSize: 22
                    font.bold: true
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: "La vitesse de lecture peut être modifiée uniquement en DirectPlay. " +
                          "Passez le flux en DirectPlay dans Qualité vidéo, puis réessayez."
                    textFormat: Text.PlainText
                    color: Qt.rgba(1, 1, 1, 0.88)
                    font.pixelSize: 17
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    text: root._speedDirectPlayPopupModeLabel.length > 0
                          ? ("Flux actuel : " + root._speedDirectPlayPopupModeLabel)
                          : ""
                    textFormat: Text.PlainText
                    color: Qt.rgba(1, 1, 1, 0.58)
                    font.pixelSize: 14
                    visible: text.length > 0
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }
            }
        }
    }
    Rectangle {
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 180; z: 15; enabled: false
        opacity: root.uiChromeOpacity
        gradient: Gradient { GradientStop { position:0.0; color:"#99000000" } GradientStop { position:1.0; color:"transparent" } }
    }
    Rectangle {
        anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 220; z: 15; enabled: false
        opacity: root.uiChromeOpacity
        gradient: Gradient { GradientStop { position:0.0; color:"transparent" } GradientStop { position:1.0; color:"#AA000000" } }
    }
    Loader {
        id: topBarLoader
        objectName: "TopBar@PlayerOverlay"
        source: "TopBar.qml"
        active: root._primaryUiReady
        visible: !nextUiLocked && !serverPrerollBlocking
        focus: false
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 70
        z: 500
        clip: false
        onLoaded: {
            try {
                item.anchors.left  = topBarLoader.left
                item.anchors.right = topBarLoader.right
                item.anchors.top   = topBarLoader.top
                item.height = 70
                item.visible = true
                item.baseUrl   = (serverUrl||"").replace(/\/$/,"")
                item.fbx       = root.fbx
                item.serverUrl = root.serverUrl
                item.userId    = root.userId
                item.userName = Qt.binding(function(){ return root.userName })
                item.userImageTag = Qt.binding(function(){ return root.userImageTag })
                // Un nouveau media ne doit pas reutiliser le logo de l'ancien.
                item.stickyLogo = false
                item.showClock   = Qt.binding(function(){ return root.topbarShowClock })
                item.clockHudActive = Qt.binding(function(){
                    return root.uiChromeOpacity > 0.08 && topBarLoader.visible
                })
                if (item.hasOwnProperty("safeMarginRight"))
                    item.safeMarginRight = Qt.binding(function(){ return Math.max(28, root.tvSafeMargin) })
                if (item.hasOwnProperty("safeMarginLeft"))
                    item.safeMarginLeft  = Qt.binding(function(){ return Math.max(28, root.tvSafeMargin) })
                if (item.hasOwnProperty("safeMarginTop"))
                    item.safeMarginTop   = Qt.binding(function(){ return Math.max(28, root.tvSafeMargin) })
            } catch(e){}
            _pushTopBar()
        }
        opacity: root.uiChromeOpacity
    }
    Connections {
        target: topBarLoader.item
        ignoreUnknownSignals: true
        function onLogoReadyChanged() { root._syncTopBarLogoReadyState() }
        function onReadyLogoUrlChanged() { root._syncTopBarLogoReadyState() }
        function onLogoResolutionCompleteChanged() { root._syncTopBarLogoReadyState() }
    }
    Text {
        id: episodeLogoTitle
        z: 501
        anchors.left: parent.left
        // Meme origine horizontale que le logo dans TopBar.
        anchors.leftMargin: topBarLoader.item
                            ? topBarLoader.item.mediaLeftInset
                            : Math.max(28, root.tvSafeMargin - 16)
        anchors.top: parent.top
        // Le titre suit le bas REEL du logo : jamais de chevauchement sur
        // un visuel carre/vertical, ni d'espace superflu sur un logo tres large.
        anchors.topMargin: Math.max(63, topBarLoader.item
                                   ? Math.ceil(topBarLoader.item.logoBottomY + 10) : 63)
        width: Math.min(760, Math.max(240, root.width - anchors.leftMargin - 420))
        visible: topBarLoader.visible
                 && root.uiChromeRenderVisible
                 && root.currentItemIsEpisode
                 && !root._topBarMetadataPending
                 && !root._topBarTitleMustWait()
                 && root._topBarLogoReadyForCurrent
                 && root.currentItemTitle.length > 0
        text: root.currentItemTitle
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        color: "#FFFFFF"
        opacity: 0.92 * root.uiChromeOpacity
        font.pixelSize: 24
        clip: true
        height: 34
        enabled: false
    }
    Loader {
        id: skipIntroLoader
        active: root._secondaryUiReady && skipIntroEnabled
        visible: active && item && !nextUiLocked && !serverPrerollBlocking
                 && !skipIntroResumeGateActive
                 && _skipIntroLastShow
                 && !skipIntroConsumed
                 && !skipIntroDismissed
        enabled: visible
        source: Qt.resolvedUrl("../components/SkipIntro.qml")
        z: 2600
        anchors.fill: parent
        clip: false
        onLoaded: {
            if (item && item.prioritizeOnShow !== undefined) item.prioritizeOnShow = true
            _syncSkipIntroOverlay()
            Qt.callLater(function() {
                var w = skipIntroLoader.item
                if (!w || !_skipIntroLastShow ||
                        (skipIntroFocusReleasedByUser && uiChromeRenderVisible) ||
                        skipIntroConsumed || skipIntroDismissed)
                    return
                try {
                    if (w.stealFocusOnShow !== undefined)
                        w.stealFocusOnShow = _skipIntroAutoFocusAllowed()
                    // Toujours passer par l'autorité PlayerOverlay afin que le
                    // focus pris ici soit identifié comme AUTO et puisse être
                    // rendu dès que le chrome réapparaît.
                    if (w.stealFocusOnShow === true)
                        _focusSkipIntroIfVisible("chrome-hidden", true)
                    else if (w.prioritizeOnShow !== false)
                        _focusSkipIntroIfVisible("chrome-visible-priority", false)
                } catch(e0) {  }
            })
        }
        onStatusChanged: {
            if (status === Loader.Error) 0
        }
    }
    Connections {
        target: skipIntroLoader.item
        ignoreUnknownSignals: true
        function onSkipRequested(targetMs) {
            // Si SkipIntro avait pris automatiquement le focus alors que le
            // chrome était complètement masqué, OK doit skipper sans réveiller
            // les volets. Le flag est capturé avant que skipIntroNow() ne libère
            // l'auto-focus.
            var preserveHiddenChrome = skipIntroAutoFocusClaimed &&
                                       !uiChromeRenderVisible && !controlsVisible
            skipIntroNow("../components/SkipIntro.qml", preserveHiddenChrome)
            _restoreFocusAfterSkipIntro("skip", preserveHiddenChrome)
        }
        function onDismissed() {
            skipIntroDismissed = true
            skipIntroFocusReleasedByUser = true
            if (skipIntroLoader.item) { try { _setSkipIntroItemActive(skipIntroLoader.item, false) } catch(e) {} }
            _restoreFocusAfterSkipIntro("dismissed")
        }
        function onVisualExpired() {
            // Expiration automatique des 10 s : mémoriser qu’elle a déjà été
            // montrée pour cette intro. Sans ce latch, ouvrir puis fermer un menu
            // remet show=false puis show=true et relance une seconde fenêtre.
            // Cette expiration reste distincte d’un dismissed utilisateur.
            skipIntroVisualExpired = true
            var chromeWasHidden = !uiChromeRenderVisible && !controlsVisible
            skipIntroAutoFocusClaimed = false
            skipIntroFocusClaimed = false
            skipIntroFocusReleasedByUser = true
            var w = skipIntroLoader.item
            try {
                if (w && w.releasePriorityFocus) w.releasePriorityFocus("visual-expired")
                else if (w && w.hasOwnProperty("focusClaimed")) w.focusClaimed = false
            } catch(e0) {}
            try { root.forceActiveFocus() } catch(e1) {}
            // Préserver strictement l'état d'affichage qui précédait l'expiration.
            // Le focus logique sous-jacent reste mémorisé mais aucun panneau n'est réveillé.
            if (chromeWasHidden) {
                controlsTimer.stop()
                controlsVisible = false
            }
            _updateControlsActive()
        }
        function onFocusBelowRequested() {
            // Défense côté parent : le composant libère déjà son FocusScope dans
            // _doFocusBelow(), mais on répète l'opération de façon idempotente pour
            // les backends Freebox où activeFocus peut rester collé un tour d'event.
            try {
                var skipWidget = skipIntroLoader.item
                if (skipWidget && skipWidget.releasePriorityFocus)
                    skipWidget.releasePriorityFocus("playeroverlay-focus-below")
            } catch(eRelease) {}
            skipIntroFocusReleasedByUser = true
            skipIntroAutoFocusClaimed = false
            skipIntroFocusClaimed = false
            if (skipIntroLoader.item && skipIntroLoader.item.stealFocusOnShow !== undefined)
                skipIntroLoader.item.stealFocusOnShow = false
            // Hiérarchie verticale : SkipIntro → ProgressBar → PlayerControls.
            // ↓ depuis SkipIntro doit donc revenir d'abord sur la progressbar.
            controlsVisible = true
            controlsFocus = cF_PROGRESS
            _updateControlsActive()
            _syncControlsTimer()
            try { root.forceActiveFocus() } catch(e0) {}
        }
    }
    property int nextToProgressGap: 24
    property int nextFallbackBottom: 96
    property int nextHideMaxWaitMs: 1500
    function _goNextEpisode(){ transportNext("next-panel") }
    function _playlistArray(){
        var src = []
        if (playlistRef && playlistRef.hasList())
            src = playlistRef.copyList()
        else if (Array.isArray(playerPlaylist) && playerPlaylist.length > 0)
            src = playerPlaylist

        var out = []
        for (var i = 0; i < src.length; i++) {
            var v = String(src[i] || "")
            if (v.length) out.push(v)
        }
        return out
    }
    function _syncPlaylistIndex(i){
        if (!playlistRef) return
        playlistRef.setIndex(i)
    }
    function playRelative(step, origin){
        var arr = _playlistArray()
        var cur = String(root.itemId || "")
        var idx = -1
        for (var i=0; i<arr.length; i++) { if (arr[i] === cur) { idx = i; break } }
        if (idx >= 0 && arr.length > 0) {
            var ni = Math.max(0, Math.min(arr.length - 1, idx + step))
            if (ni === idx) { 0; return false }
            nextHiddenWaiter.stop()
            nextUserHidden = true
            nextRearmTimer.restart()
            _syncPlaylistIndex(ni)
            _finalizeCurrentSessionForSwitch(origin || "playlist-relative")
            root.itemId = arr[ni]
            return true
        }
        try {
            if (step > 0 && playlistRef && typeof playlistRef.nextFrom === "function") { playlistRef.nextFrom(root.itemId); return true }
            if (step < 0 && playlistRef && typeof playlistRef.prevFrom === "function") { playlistRef.prevFrom(root.itemId); return true }
        } catch(e2) {}
        return false
    }
    function mediaPause(){ mp.pause(); return true }
    function mediaStop(){ return finalizePlaybackAndExit("mediaStop") }
    function mediaToggle(){ transportToggle("mediaToggle"); return true }
    function stopScrubCommitTimer(){ scrubCommitTimer.stop() }
    function transportPrev(origin){ return playRelative(-1, origin || "prev") }
    function transportNext(origin){ return playRelative( 1, origin || "next") }
    function transportRewind(origin){ resetControlsTimer(); seekBy(-10000) }
    function transportForward(origin){ resetControlsTimer(); seekBy(10000) }
    function transportToggle(origin){
        var willPause = (mp.playbackState === MediaPlayer.PlayingState)
        resetControlsTimer()
        _cancelStartupPlay(origin || "manual-toggle")
        // Voie de reprise unique du lecteur : toutes les commandes Play
        // (bouton HUD, OK sur la progressbar, touche média, mediaToggle)
        // convergent ici. Des réglages choisis pendant la pause sont appliqués
        // en une seule négociation, avec reprise forcée ; aucun mp.play() ne
        // doit alors être émis sur l'ancien flux.
        if (!willPause && TrackSelection.resumeDeferredReload(root, mp, origin || "manual-toggle"))
            return
        try {
            if (willPause) { mp.pause() }
            else { mp.play() }
        } catch(e) {
        }
    }
    // ===== Contrôle distant Jellyfin =====
    // Ces façades ne contournent jamais le moteur ReDeFin : elles réutilisent
    // les mêmes automates que la télécommande locale.
    function remoteControlReady(){
        var expectedKey = String(serverUrl || "") + "|" + String(itemId || "")
        return !!itemId
            && !!mediaUrl
            && _streamsReadyKey === expectedKey
            && !_sourceResetActive
            && !_trackSwitchVerificationActive
            && !_tearingDownPlayer
    }
    function remotePause(){
        try {
            _cancelStartupPlay("remote-pause")
            if (mp.playbackState !== MediaPlayer.PausedState)
                mp.pause()
            return true
        } catch(e) {}
        return false
    }
    function remoteUnpause(){
        try {
            if (mp.playbackState === MediaPlayer.PlayingState)
                return true
            _cancelStartupPlay("remote-unpause")
            if (TrackSelection.resumeDeferredReload(root, mp, "remote-unpause"))
                return true
            mp.play()
            return true
        } catch(e) {}
        return false
    }
    function remoteStop(){
        return finalizePlaybackAndExit("remote-stop")
    }
    function remoteReportState(reason){
        try {
            var paused = mp.playbackState !== MediaPlayer.PlayingState
            return _sendPlaybackCheckpoint(reason || "remote-command", paused, true)
        } catch(e) {}
        return false
    }
    function remoteSwitchItem(newItemId){
        var id = String(newItemId || "")
        if (!id.length)
            return false
        if (id === String(itemId || ""))
            return true
        // Même comptabilité Jellyfin que les changements d'épisode locaux :
        // clôturer l'ancienne session avant de changer root.itemId.
        _finalizeCurrentSessionForSwitch("remote-play")
        root.itemId = id
        return true
    }
    function remoteSeekTicks(ticks){
        var n = Number(ticks)
        if (!isFinite(n) || isNaN(n) || n < 0)
            return false
        if (_transportLocked("remote-seek"))
            return false

        var target = _clampUi(Math.floor(n / 10000))
        var wasPlaying = (mp.playbackState === MediaPlayer.PlayingState)
        _cancelCoalescedLocalSeek()

        if (_pendingSeekMs >= 0) {
            _setPendingSeekMs(target, "remote-seek-existing-pending")
            lastUiTargetMs = target
            showScrubPreview(target)
            return true
        }

        if (TrackSelection.seekDeferredReload(root, mp, target, "remote-seek", wasPlaying))
            return true

        if (shouldNetworkSeek()) {
            _resumeWantedAfterNegotiation = wasPlaying
            _serverSeekFallback(target, "remote-seek")
        } else {
            _localSeekTo(target, "remote-seek")
        }
        return true
    }
    function remoteSetAudioStreamIndex(streamIdx){
        var n = Number(streamIdx)
        if (!isFinite(n) || isNaN(n) || n < 0)
            return true
        var ui = _indexInStreamMap(audioStreamIndexMap, n)
        if (ui < 0)
            return true
        return handleAudioPick(n, ui, false) !== false
    }
    function remoteSetSubtitleStreamIndex(streamIdx){
        var n = Number(streamIdx)
        if (!isFinite(n) || isNaN(n))
            return true
        if (n < 0) {
            handleSubsOff()
            return true
        }
        var ui = _indexInStreamMap(subtitleStreamIndexMap, n)
        if (ui < 0)
            return true
        var isText = ui >= 0 && ui < subtitleIsTextMap.length
                && subtitleIsTextMap[ui] === true
        if (isText)
            handleSubsText(n, ui)
        else
            handleSubsImage(n, ui)
        return true
    }

    function _setControlsButtonIndex(idx,origin){ idx=Math.max(1,Math.min(5,idx|0)); controlsFocus=1; if(controlsLoader.item&&controlsLoader.item.hasOwnProperty("focusIndex"))controlsLoader.item.focusIndex=idx }
    function _activateControlsButton(origin){
        var idx = (controlsLoader.item && controlsLoader.item.focusIndex) ? controlsLoader.item.focusIndex : 3
        if (idx===1)      { var wp=chaptersOverlayLoader.item; if(wp&&wp.seekRelativeChapter) wp.seekRelativeChapter(-1,uiPositionMs()) }
        else if (idx===2) transportRewind(origin || "controls-rewind")
        else if (idx===3) transportToggle(origin || "controls-toggle")
        else if (idx===4) transportForward(origin || "controls-forward")
        else if (idx===5) { var wn=chaptersOverlayLoader.item; if(wn&&wn.seekRelativeChapter) wn.seekRelativeChapter(1,uiPositionMs()) }
    }
    function _startControlsTransportHold(){ var w=controlsLoader.item,idx=getControlsButtonIndex(); if(!w||(idx!==1&&idx!==5)||!w._startTransportHold)return false; w._startTransportHold(idx); return true }
    function _controlsTransportHoldActive(){ var w=controlsLoader.item; return !!(w&&w._transportPressActive) }
    function _finishControlsTransportHold(){ var w=controlsLoader.item; return !!(w&&w._finishTransportHold&&w._finishTransportHold()) }
    Timer {
        id: nextHiddenWaiter
        interval: 50
        repeat: false
        running: false
        property int budget: 0
        onTriggered: {
            if (!nextPanelShowing || !nextLoader.visible) {
                stop()
                _goNextEpisode()
            } else {
                budget -= interval
                if (budget <= 0) {
                    stop()
                    _goNextEpisode()
                } else {
                    restart()
                }
            }
        }
    }
    Loader {
        id: nextLoader
        active: root._secondaryUiReady && nextOverlayEnabled
        visible: active && !serverPrerollBlocking
        source: "NextEpisode.qml"
        z: 1600
        anchors.fill: parent
        clip: false
        onLoaded: {
            _syncNextOverlayContext()
            var w = item; if (!w) return
            w.width  = Qt.binding(function(){ return nextLoader.width })
            w.height = Qt.binding(function(){ return nextLoader.height })
            if (w.hasOwnProperty("safeMarginLeft")) {
                w.safeMarginLeft = Qt.binding(function(){ return tvSafeMargin })
            }
            if (w.hasOwnProperty("safeMarginRight")) {
                w.safeMarginRight = Qt.binding(function(){ return tvSafeMargin })
            }
            if (w.hasOwnProperty("safeMarginTop")) {
                w.safeMarginTop = Qt.binding(function(){ return tvSafeMargin })
            }
            if (w.hasOwnProperty("safeMarginBottom")) {
                w.safeMarginBottom = Qt.binding(function(){
                    if (nextUiLocked) return tvSafeMargin
                    if (controlsVisible || scrubActive) {
                        var pb = controlsLoader.item
                        if (pb) {
                            // PlayerControls occupe maintenant le plein ecran ;
                            // reconstruire explicitement le sommet de sa zone
                            // de progression pour garder l'overlay Episode suivant
                            // a la meme hauteur qu'avant l'extraction.
                            var needed = pb.transportBottomInset
                                       + pb.controlsAreaHeight
                                       + pb.sectionGap
                                       + pb.progressAreaHeight
                                       + nextToProgressGap
                            return Math.max(needed, tvSafeMargin)
                        }
                    }
                    return Math.max(nextFallbackBottom, tvSafeMargin)
                })
            }
            if (w.requestStartNow) w.requestStartNow.connect(function(){
                hideNextPanel()
                nextHiddenWaiter.budget = nextHideMaxWaitMs
                nextHiddenWaiter.restart()
            })
            if (w.requestHide) w.requestHide.connect(function(){ hideNextPanel() })
            if (w.findNextByPlaylist) w.findNextByPlaylist(itemId, w.playlist)
        }
        onActiveChanged: _syncNextOverlayContext()
    }
    Loader {
        id: controlsLoader
        active: root._primaryUiReady
        source: "PlayerControls.qml"
        anchors.fill: parent
        clip: false
        z: 300
        visible: root.uiChromeRenderVisible
        opacity: root.uiChromeOpacity
        onLoaded: {
            item.focusIndex = 3
            item.isPlaying = (mp.playbackState === MediaPlayer.PlayingState)
            if (item.allowEpisodeLongPress !== undefined)
                item.allowEpisodeLongPress = Qt.binding(function(){ return root.currentItemIsEpisode })
            if (item.hasOwnProperty("focused"))
                item.focused = !skipIntroFocusClaimed && (controlsFocus === cF_PROGRESS)
            item.settingsVisible = Qt.binding(function(){ return root.uiChromeRenderVisible })
            item.settingsAllowed = Qt.binding(function(){ return !root.nextUiLocked && !root.serverPrerollBlocking })
            item.settingsFocusedControl = Qt.binding(function(){
                if (root.controlsFocus === root.cF_ZOOM) return item.controlZoom
                if (root.controlsFocus === root.cF_SPEED) return item.controlSpeed
                if (root.controlsFocus === root.cF_QUALITY) return item.controlQuality
                if (root.controlsFocus === root.cF_MENU)
                    return root.menuIndex === 2 ? item.controlSubtitle : item.controlAudio
                return -1
            })
            item.transportBottomInset = Qt.binding(function(){ return Math.max(48, root.tvSafeMargin) })
            item.settingsBottomInset = Qt.binding(function(){ return root.sideButtonBottomMargin })
            item.selectedRate = Qt.binding(function(){ return root.playbackSpeed })
            _pushProgress(scrubActive && scrubAccumUiMs >= 0 ? scrubAccumUiMs : uiPositionMs(), durationMs())
            _updateControlsActive()
            _focusControlsLater()
        }
    }
    Connections {
        target: playlistRef
        ignoreUnknownSignals: true
        function onRequestPlayItem(nextId) {
            if (nextId && nextId.length) {
                _finalizeCurrentSessionForSwitch("playlist-request")
                nextHiddenWaiter.stop()
                nextUserHidden = true
                nextRearmTimer.restart()
                root.itemId = nextId
                _syncNextOverlayContext()
                if (nextLoader.item) {
                    if (nextLoader.item.resetForNewItem) Qt.callLater(function(){ nextLoader.item.resetForNewItem() })
                    if (nextLoader.item.findNextByPlaylist)
                        Qt.callLater(function(){ nextLoader.item.findNextByPlaylist(root.itemId, nextLoader.item.playlist) })
                }
            }
        }
    }
    Connections {
        target: controlsLoader.item; ignoreUnknownSignals: true
        // Signaux de la ProgressBar désormais intégrée.
        function onSeekRequested(delta){  resetControlsTimer(); seekBy(delta) }
        function onToggleRequested(){  transportToggle("progressbar-signal") }
        function onFocusUp(){
            // Certaines builds Freebox font remonter ↑ par le signal de la
            // ProgressBar plutôt que par Keys.BeforeItem. Les deux chemins doivent
            // donc mener au même focus SkipIntro et au même encadré blanc.
            if (_focusSkipIntroIfVisible("progressbar-signal-up", false)) return
            _parkFocusOnProgress("progressbar-signal-up-stay")
        }
        function onFocusDown(){  controlsFocus = cF_CONTROLS; _updateControlsActive(); root.forceActiveFocus();  }
        function onPreviousChapter(){
            var w = chaptersOverlayLoader.item
            if (w && w.hasContent) {
                if (w.seekRelativeChapter) w.seekRelativeChapter(-1, uiPositionMs())
                return
            }
            if (currentItemIsEpisode && w && w.chaptersResolved === true)
                transportPrev("controls-short-prev-no-chapters")
        }
        function onPreviousEpisode(){
            if (currentItemIsEpisode) transportPrev("controls-hold-prev-episode")
        }
        function onNextChapter(){
            var w = chaptersOverlayLoader.item
            if (w && w.hasContent) {
                if (w.seekRelativeChapter) w.seekRelativeChapter(1, uiPositionMs())
                return
            }
            if (currentItemIsEpisode && w && w.chaptersResolved === true)
                transportNext("controls-short-next-no-chapters")
        }
        function onNextEpisode(){
            if (currentItemIsEpisode) transportNext("controls-hold-next-episode")
        }
        function onRewind(){ transportRewind("controls-signal-rewind") }
        function onForward(){ transportForward("controls-signal-forward") }
        function onTogglePlay(){ transportToggle("controls-signal-toggle") }
        function onMoveRight(){ controlsFocus=4; menuIndex=1; _focusControlsLater() }
        function onFocusChanged(idx){ controlsFocus = 1 }
        function onSettingsButtonClicked(control){ root._activateSettingsButton(control) }
        function onUserActivity(){ resetControlsTimer() }
    }
    onControlsFocusChanged: {
        H.forgetSettingsFocusIfMoved(root)
        if (controlsLoader.item && controlsLoader.item.hasOwnProperty("focused")) {
            try { controlsLoader.item.focused = !skipIntroFocusClaimed && (controlsFocus===cF_PROGRESS) } catch(e) {}
        }
        _updateControlsActive()
        _syncControlsTimer()
        _focusControlsLater()
    }
    // controlsLoader.active dépend aussi de ces deux booléens : sans
    // resynchronisation ici, le halo des transports restait figé sur sa
    // valeur précédente jusqu'au prochain changement de controlsFocus.
    onAudioMenuVisibleChanged: { _syncControlsTimer(); _updateControlsActive() }
    onSubMenuVisibleChanged:   { _syncControlsTimer(); _updateControlsActive() }
    onScrubActiveChanged:      _syncControlsTimer()
    onManualQualityBitrateChanged: _syncSettingsQualityPresentation()
    onManualRemuxModeChanged: _syncSettingsQualityPresentation()
    onManualDirectPlayModeChanged: _syncSettingsQualityPresentation()
    onIsHlsChanged: _syncSettingsQualityPresentation()
    onLastUsedTranscodingChanged: _syncSettingsQualityPresentation()
    onLastUsedDirectStreamChanged: _syncSettingsQualityPresentation()
    onLastUsedServerRemuxChanged: _syncSettingsQualityPresentation()
    onServerTimedStreamChanged: _syncSettingsQualityPresentation()
    onTimeShiftedChanged: _syncSettingsQualityPresentation()
    onCurrentPlaybackVideoTranscodeByPolicyChanged: _syncSettingsQualityPresentation()
    onMediaUrlChanged: _syncSettingsQualityPresentation()
    onBaseOffsetMsChanged: {
        if (subsLoader.item)
            _pushLocalSubsUiMs(0, true)
    }
    onSelectedAudioStreamChanged: _syncTrackMenuIndexes("selectedAudioStreamChanged")
    onSelectedSubtitleStreamChanged: _syncTrackMenuIndexes("selectedSubtitleStreamChanged")
    onUseLocalSubsChanged: {
        // Resynchroniser le renderer même si le Loader QML est déjà en cache.
        if (subsLoader.item) {
            subsLoader.item.cues = localCues || []
            subsLoader.item.enabled = useLocalSubs && localCues && localCues.length > 0
            if (subsLoader.item.enabled)
                _pushLocalSubsUiMs(0, true)
        }
        _syncTrackMenuIndexes("useLocalSubsChanged")
    }
    onLocalCuesChanged: {
        // Les cues seules ne doivent jamais activer le renderer.
        if (subsLoader.item) {
            subsLoader.item.cues = localCues || []
            subsLoader.item.enabled = useLocalSubs && localCues && localCues.length > 0
            if (subsLoader.item.enabled)
                _pushLocalSubsUiMs(0, true)
        }
    }
    onLocalSubStreamIndexChanged: _syncTrackMenuIndexes("localSubStreamIndexChanged")
    onEffectiveAudioStreamChanged: _syncTrackMenuIndexes("effectiveAudioStreamChanged")
    onEffectiveSubtitleStreamChanged: _syncTrackMenuIndexes("effectiveSubtitleStreamChanged")
    Loader {
        id: chaptersOverlayLoader
        active: root._secondaryUiReady && !serverPrerollBlocking
        visible: active
        source: "PlayerChaptersOverlay.qml"
        anchors.fill: parent
        z: (item && item.panelOpen) ? 400 : 340
        opacity: root.uiChromeOpacity
        onLoaded: {
            item.serverUrl = Qt.binding(function(){ return root.serverUrl })
            item.accessToken = Qt.binding(function(){ return root.accessToken })
            item.itemId = Qt.binding(function(){ return root.itemId })
            item.allowUi = Qt.binding(function(){ return !root.nextUiLocked && !root.serverPrerollBlocking })
            item.buttonFocused = Qt.binding(function(){ return root.controlsFocus === root.cF_CHAPTERS })
            item.safeBottomMargin = Qt.binding(function(){ return root.sideButtonBottomMargin })
            item.currentPlaybackMs = Qt.binding(function(){ return root.uiPositionMs() })
            item.itemChapters = Qt.binding(function(){ return root._chaptersItemId === root.itemId ? root.itemChapters : null })
            item.fetchEnabled = Qt.binding(function(){ return root._chaptersItemId === root.itemId })
        }
    }
    Connections {
        target: chaptersOverlayLoader.item
        ignoreUnknownSignals: true
        function onRequestSeek(startMs) {
            var fromPanel = _chaptersPanelOpen()
            var keepIdx = getControlsButtonIndex()
            _seekToChapterMs(startMs)
            if (fromPanel) {
                controlsFocus = cF_CHAPTERS
            } else {
                controlsFocus = cF_CONTROLS
                if (controlsLoader.item && controlsLoader.item.hasOwnProperty("focusIndex"))
                    controlsLoader.item.focusIndex = keepIdx
                _updateControlsActive()
                root.forceActiveFocus()
            }
            resetControlsTimer()
        }
        function onRequestFocusProgress(){ _focusProgressBarSilent("chapters") }
        function onRequestFocusControls(){ _forceControlsFocusNow("chapters") }
        function onRequestButtonFocus(){
            controlsFocus = cF_CHAPTERS
            root.forceActiveFocus()
            resetControlsTimer()
        }
        function onUserActivity(){
            if (_chaptersPanelOpen()) controlsTimer.stop()
            else resetControlsTimer()
        }
        function onPanelOpenChanged(){ _syncControlsTimer() }
    }
    Loader {
        id: settingsOverlayLoader
        active: root._secondaryUiReady && !serverPrerollBlocking
        visible: active
        source: "PlayerSettingsOverlay.qml"
        anchors.fill: parent
        z: 370
        opacity: root.uiChromeOpacity
        onLoaded: {
            item.allowUi = Qt.binding(function(){ return !root.nextUiLocked && !root.serverPrerollBlocking })
            item.focusedControl = Qt.binding(function(){
                if (root.controlsFocus === root.cF_ZOOM) return item.controlZoom
                if (root.controlsFocus === root.cF_SPEED) return item.controlSpeed
                if (root.controlsFocus === root.cF_QUALITY) return item.controlQuality
                if (root.controlsFocus === root.cF_MENU)
                    return root.menuIndex === 2 ? item.controlSubtitle : item.controlAudio
                return -1
            })
            item.chaptersPanelOpen = Qt.binding(function(){ return root._chaptersPanelOpen() })
            item.safeBottomMargin = Qt.binding(function(){ return root.sideButtonBottomMargin })
            item.selectedBitrate = Qt.binding(function(){ return root._displayQualityBitrate() })
            item.sourceVideoBitrate = Qt.binding(function(){ return root.sourceVideoBitrate })
            // Snapshot impératif : évite les binding loops Qt 5.15.
            root._syncSettingsQualityPresentation()
            item.selectedMode = Qt.binding(function(){ return root.videoZoomMode })
            item.selectedRate = Qt.binding(function(){ return root.playbackSpeed })
            item.speedDirectPlayAvailable = Qt.binding(function(){ return root.isPureDirectPlay() })
            item.audioMenuOpen = Qt.binding(function(){ return root.audioMenuVisible })
            item.subtitleMenuOpen = Qt.binding(function(){ return root.subMenuVisible })
            item.audioTracks = Qt.binding(function(){ return root.audioTracks })
            item.audioStreamIndexMap = Qt.binding(function(){ return root.audioStreamIndexMap })
            item.audioChannelMap = Qt.binding(function(){ return root.audioChannelMap })
            item.audioCurrentIndex = Qt.binding(function(){ return root._displayAudioUiIndexForSettings() })
            item.audioOutputStereo = Qt.binding(function(){ return root._displayAudioOutputMode() === "stereo" })
            item.audioSelectionNote = Qt.binding(function(){ return root._deferredSelectionNote(root._deferredAudioUiIndex >= 0) })
            item.subtitleTracks = Qt.binding(function(){ return root.subtitleTracks })
            item.subtitleStreamIndexMap = Qt.binding(function(){ return root.subtitleStreamIndexMap })
            item.subtitleIsTextMap = Qt.binding(function(){ return root.subtitleIsTextMap })
            item.subtitleCurrentIndex = Qt.binding(function(){ return root._displaySubtitleUiIndexForSettings() })
            item.subtitleSelectionNote = Qt.binding(function(){ return root._deferredSelectionNote(root._deferredSubtitleUiIndex >= 0) })
            if (item.syncTrackIndexes)
                item.syncTrackIndexes(root._displayAudioUiIndexForSettings(),
                                      root._displaySubtitleUiIndexForSettings())
        }
    }
    Connections {
        target: settingsOverlayLoader.item
        ignoreUnknownSignals: true
        function onRequestQuality(bitrate){
            _applyQualityChoice(bitrate)
            _restoreFocusAfterSettingsChoice(H.SETTINGS_CONTROL_QUALITY, "quality-choice")
        }
        function onRequestZoom(mode){
            _applyVideoZoomMode(mode)
            _restoreFocusAfterSettingsChoice(H.SETTINGS_CONTROL_ZOOM, "zoom-choice")
        }
        function onRequestSpeed(rate){
            if (!root.isPureDirectPlay()) {
                root._showSpeedDirectPlayOnlyPopup()
                _restoreFocusAfterSettingsChoice(H.SETTINGS_CONTROL_SPEED, "speed-refused")
                return
            }
            _applyPlaybackSpeed(rate)
            _restoreFocusAfterSettingsChoice(H.SETTINGS_CONTROL_SPEED, "speed-choice")
        }
        function onRequestAudioOutput(stereo){
            TrackSelection.handleAudioOutputPick(root, stereo ? "stereo" : "multichannel")
            _restoreFocusAfterSettingsChoice(H.SETTINGS_CONTROL_AUDIO, "audio-output")
        }
        function onRequestAudioPick(streamIdx, uiIdx){
            handleAudioPick(streamIdx, Math.max(0, uiIdx | 0))
        }
        function onRequestSubtitleOff(){
            handleSubsOff()
        }
        function onRequestSubtitleText(streamIdx, uiIdx){
            handleSubsText(streamIdx, uiIdx)
        }
        function onRequestSubtitleImage(streamIdx, uiIdx){
            handleSubsImage(streamIdx, uiIdx)
        }
        function onRequestTrackClose(control){
            _restoreFocusAfterSettingsChoice(control, "track-close")
        }
        function onRequestFocusProgress(){
            _focusProgressBarSilent("settings")
        }
        function onRequestFocusControls(fromControl){
            var w=settingsOverlayLoader.item
            if(controlsLoader.item && controlsLoader.item.hasOwnProperty("focusIndex"))
                controlsLoader.item.focusIndex = (w && fromControl === w.controlQuality) ? 5 : 1
            _forceControlsFocusNow("settings")
        }
        function onRequestFocusChapters(){
            if (_focusChaptersButtonSilent("settings-to-chapters")) { resetControlsTimer(); return }
            // Aucun chapitre sur ce média : conserver une navigation naturelle
            // entre les voisins réellement visibles.
            if (controlsFocus === cF_CONTROLS) {
                controlsFocus = cF_SPEED
                root.forceActiveFocus()
            } else {
                _setControlsButtonIndex(1,"settings-no-chapters-to-controls")
                _forceControlsFocusNow("settings-no-chapters-to-controls")
            }
            resetControlsTimer()
        }
        function onRequestButtonFocus(control){
            _restoreFocusAfterSettingsChoice(control, "button-focus")
        }
        function onRequestFocusControlsLeft(){ if(controlsLoader.item&&controlsLoader.item.hasOwnProperty("focusIndex"))controlsLoader.item.focusIndex=1; _forceControlsFocusNow("settings-dpad") }
        function onRequestOpenControl(control){ var w=settingsOverlayLoader.item; if(!w)return; if(control===w.controlQuality)_openQualityPanel(); else if(control===w.controlZoom)_openZoomPanel(); else if(control===w.controlSpeed)_openSpeedPanel() }
        function onUserActivity(){
            if(_qualityPanelOpen() || _trackPanelOpen()) controlsTimer.stop()
            else resetControlsTimer()
        }
        function onPanelOpenChanged(){
            _syncControlsTimer()
        }
    }
    function handleAudioPick(streamIdx, uiIdx, explicitManualDirectPlay, targetUiOverride){
        return TrackSelection.handleAudioPick(root, streamIdx, uiIdx,
                                 explicitManualDirectPlay === true, targetUiOverride)
    }
    function handleSubsOff(){ TrackSelection.handleSubsOff(root) }
    function handleSubsText(streamIdx, listIdx){
        TrackSelection.handleSubsText(root, subsLoader.item, streamIdx, listIdx)
    }
    function handleSubsImage(streamIdx, listIdx){
        TrackSelection.handleSubsImage(root, streamIdx, listIdx)
    }
    Loader {
        id: subsLoader
        // Attendre à la fois l'état local actif et des cues prêtes.
        active: root._secondaryUiReady
                && !serverPrerollBlocking
                && root.useLocalSubs
                && root.localCues
                && root.localCues.length > 0
        source: "SubtitleOverlay.qml"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        // Position de base commune aux sous-titres locaux. Le réglage DirectPlay
        // est appliqué ensuite via Translate, donc il n'est plus neutralisé par
        // la hauteur interne de SubtitleOverlay.qml.
        // Position fixe : volets visibles ou masqués, même hauteur.
        anchors.bottomMargin: Math.max(96, root.tvSafeMargin)
        transform: Translate {
            // Décalage VISUEL final, après calcul des anchors. Aucun clamp caché :
            //   valeur positive = plus bas
            //   valeur négative = plus haut
            // Cela permet aussi de tester facilement avec une valeur extrême.
            y: (root.useLocalSubs && root.isPureDirectPlay())
               ? root.localSubtitleDirectPlayYOffset
               : 0
        }
        z: 220
        onLoaded: {
            // Initialiser depuis l'état courant ; les handlers gardent la synchro.
            item.cues = localCues || []
            item.enabled = useLocalSubs && localCues && localCues.length > 0
            item.delayMs = subtitleDelayMs
            if (item.enabled)
                _pushLocalSubsUiMs(0, true)
            item.controlsVisible = (controlsVisible || scrubActive)
            item.gateArmed = _gateArmed
        }
    }
    onSubtitleDelayMsChanged: { if (subsLoader.item) subsLoader.item.delayMs = subtitleDelayMs }
    onControlsVisibleChanged: {
        if (subsLoader.item) subsLoader.item.controlsVisible = (controlsVisible || scrubActive)
        if (!controlsVisible) {
            _parkFocusOnProgress("controls-hidden-to-progress")
        } else if (controlsFocus===cF_CONTROLS) {
            _focusControlsLater()
        }
    }
    function resetControlsTimer(){
        if(nextUiLocked){  return }
        controlsVisible=true
        if(_chaptersPanelOpen()||_qualityPanelOpen()||_trackPanelOpen()){controlsTimer.stop();  return}
        controlsTimer.restart(); _syncControlsTimer()
    }
    function openAudioMenu(){
        if (nextUiLocked || _chaptersPanelOpen() || _qualityPanelOpen()) return
        _syncTrackMenuIndexes("openAudioMenu-before")
        controlsFocus=cF_MENU; menuIndex=1
        subMenuVisible=false; audioMenuVisible=true
        controlsVisible=true; controlsTimer.stop()
        var w=_settingsOverlay()
        if(w && w.syncTrackIndexes)
            w.syncTrackIndexes(_displayAudioUiIndexForSettings(),
                               _displaySubtitleUiIndexForSettings())
        if(w && w.focusCurrentTrack) Qt.callLater(function(){ if(audioMenuVisible) w.focusCurrentTrack() })
    }
    function openSubMenu(){
        if (nextUiLocked || _chaptersPanelOpen() || _qualityPanelOpen()) return
        _syncTrackMenuIndexes("openSubMenu-before")
        controlsFocus=cF_MENU; menuIndex=2
        audioMenuVisible=false; subMenuVisible=true
        controlsVisible=true; controlsTimer.stop()
        var w=_settingsOverlay()
        if(w && w.syncTrackIndexes)
            w.syncTrackIndexes(_displayAudioUiIndexForSettings(),
                               _displaySubtitleUiIndexForSettings())
        if(w && w.focusCurrentTrack) Qt.callLater(function(){ if(subMenuVisible) w.focusCurrentTrack() })
    }
    Keys.onPressed: {
        if (serverPrerollBlocking) {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape || event.key === Qt.Key_MediaStop)
                finalizePlaybackAndExit("server-preroll-key")
            event.accepted = true
            return
        }
        // PlayerOverlay possède Keys.priority=BeforeItem : route d'abord les touches du bouton Skip Intro lorsqu'il a réellement pris le focus.
        if (_handleSkipIntroKey(event)) {  return }
        // Même principe pour le menu Audio/Sous-titres partagé.
        if (_trackPanelOpen()) {
            var trackSettings=_settingsOverlay()
            if (trackSettings && trackSettings.handleKey && trackSettings.handleKey(event)) {
                event.accepted=true
                return
            }
        }
        // Ordre latéral : Zoom → Vitesse → Chapitres | transports |
        // Qualité → Audio → Sous-titres. On intercepte Chapitres/Menu avant le
        // helper historique, qui conserve l'ancien placement.
        if (_handleSideFocusKey(event)) {  return }
        if (_handleSettingsFocusKey(event)) {  return }
        if (typeof H !== "undefined" && H && typeof H.handlePressed === "function") {
            H.handlePressed(root, event)
            if (event.accepted) return
        }
        if (!nextUiLocked) {
            controlsVisible = true
            _syncControlsTimer()
            root.forceActiveFocus()
        }
    }
    Keys.onReleased: {
        if (serverPrerollBlocking) {
            event.accepted = true
            return
        }
        if (typeof H !== "undefined" && H && typeof H.handleReleased === "function") {
            H.handleReleased(root, event)
            if (event.accepted) return
        }
    }
    
    Component.onCompleted: {
        _resetDeferredReload("completed")
        _primaryUiReady = false
        _secondaryUiReady = false
        primaryUiTimer.restart()
        secondaryUiTimer.restart()
        _armVideoLoading("completed")
        // Synchroniser la règle AVANT le backend et avant toute négociation.
        // Loader.onLoaded la réinjecte ensuite avec le contexte utilisateur,
        // mais cette étape élimine tout démarrage fugitif en mode "smart".
        _syncPlaybackRuleMode("completed")
        JF.syncPlayerBackendContext(root)
        controlsVisible=true; controlsFocus=cF_CONTROLS; root.forceActiveFocus()
        _syncControlsTimer(); Qt.callLater(_focusControlsLater)
        _syncIncomingPlaylist(false)
        _syncNextOverlayContext()
        if (nextLoader.item && nextLoader.item.findNextByPlaylist)
            nextLoader.item.findNextByPlaylist(itemId, nextLoader.item.playlist)
        refreshStreams()
        selectedAudioStream = -1
        selectedSubtitleStream = -1
        useLocalSubs = false
        manualDirectPlayMode = false
        manualRemuxMode = false
        PlayerSession.resetPlaybackState(root, false)
        _pushTopBar()
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("completed")
        if (!_plHasContent()) PlayerSession.ensureAutoEpisodePlaylist(root, JFB)
        PlayerSession.startInitialPlayback(root, JFB)
        updateClocksFromPlayback()
    }
    onFbxChanged:        { JF.syncPlayerBackendContext(root); _syncNextOverlayContext() }
    onPlaybackDeviceModeChanged: JF.syncPlayerBackendContext(root)
    onPlaybackRuleModeChanged: _syncPlaybackRuleMode("playbackRuleModeChanged")
    onAccessTokenChanged: {
        _resetServerPrerollState("accessToken")
        refreshStreams()
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("accessToken")
        if (!_plHasContent()) PlayerSession.ensureAutoEpisodePlaylist(root, JFB)
        PlayerSession.startInitialPlayback(root, JFB)
        _syncNextOverlayContext()
    }
    onUserIdChanged: {
        _resetServerPrerollState("userId")
        refreshCurrentItemTitle()
        if (!_plHasContent()) PlayerSession.ensureAutoEpisodePlaylist(root, JFB)
        PlayerSession.startInitialPlayback(root, JFB)
        _syncNextOverlayContext()
    }
    onServerUrlChanged: {
        _resetServerPrerollState("serverUrl")
        refreshStreams()
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("serverUrl")
        if (!_plHasContent()) PlayerSession.ensureAutoEpisodePlaylist(root, JFB)
        PlayerSession.startInitialPlayback(root, JFB)
        _queueTopBarPush()
        _syncNextOverlayContext()
    }
    onItemIdChanged: {
        ++_topBarMetadataSeq
        _topBarMetadataPending = true
        // Effacer immediatement l'ancien titre, sans attendre le push differe.
        if (topBarLoader.item) {
            try { topBarLoader.item.itemTitle = "" } catch(e0) {}
        }
        _lastPushedTitle = ""
        try { TrackSelection.cancelLocalSubtitleRequest(root, "item-changed") } catch(eCancelSub) {}
        currentItemType = ""
        _topBarLogoReadyForCurrent = false
        _armVideoLoading("item-changed")
        if (playlistRef && typeof playlistRef.syncTo === "function")
            playlistRef.syncTo(root.itemId)
        nextHiddenWaiter.stop()
        nextUserHidden = true
        nextRearmTimer.restart()
        _resetServerPrerollState("itemChanged")
        _resetSkipIntroState("itemChanged")
        // Ne jamais exposer les métadonnées de l'item précédent pendant le fetch asynchrone.
        runtimeTicks = 0
        sourceVideoBitrate = 0
        _streamsReadyKey = ""
        _streamsLoadingKey = ""
        _streamsWaiters = []
        disableLocalSubsOverlay()
        refreshStreams()
        if (itemId && itemId.length) {
            // Ne jamais fabriquer /Items/<itemId>/Images/Logo avant d'avoir les
            // métadonnées Jellyfin. Les épisodes n'ont généralement pas de logo
            // propre et cette préconstruction provoquait un 404, puis un second
            // traitement d'erreur QtNetwork lors du fallback vers la série.
            // On ne réutilise qu'un logo déjà validé pour CE même item ; sinon
            // refreshCurrentItemTitle() résoudra un URL taggé depuis les métadonnées.
            if (lastGoodLogoItemId === itemId && H.hasQueryTag(lastGoodLogoUrl))
                currentItemLogoUrl = lastGoodLogoUrl
            else
                currentItemLogoUrl = ""
            currentItemTitle = ""
            _pushTopBar()
        } else {
            currentItemLogoUrl = ""
            currentItemTitle = ""
            _pushTopBar()
        }
        _syncNextOverlayContext()
        if (nextLoader.item && nextLoader.item.resetForNewItem) nextLoader.item.resetForNewItem()
        if (nextLoader.item && nextLoader.item.findNextByPlaylist)
            nextLoader.item.findNextByPlaylist(root.itemId, nextLoader.item.playlist)
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("itemChanged")
        if (!_plHasContent()) PlayerSession.ensureAutoEpisodePlaylist(root, JFB)
        _cancelHardSourceReset("item-changed")
        PlayerSession.resetPlaybackState(root, true)
        _resetDeferredReload("item-changed")
        _pendingAudioStream = snt
        _pendingAudioIndex = -1
        _pendingAudioManualDirectPlay = false
        _pendingSubStream = snt
        _pendingSubIndex = -1
        _autoLocalizeSubStream = -1
        selectedAudioStream = -1
        selectedSubtitleStream = -1
        useLocalSubs = false
        disableAutoVoFrenchFullSubtitle = false
        manualDirectPlayMode = false
        manualRemuxMode = false
        audioCodecMap = []
        audioChannelMap = []
        audioBitrateMap = []
        firstAudioStreamIndex = -1
        bestFrenchAudioStreamIndex = -1
        preferredFrenchAudioNeedsServerSelection = false
        firstInternalSubtitleStreamIndex = -1
        preferredFrenchForcedSubtitleNeedsServerSelection = false
        strictFrenchAutoDirectPlayEligible = false
        hasPriorityInternalSubtitleRisk = false
        hasImplicitFirstInternalSubtitleRisk = false
        hasInternalDvdSubtitle = false
        isDvdSource = false
        requiresInterlacedTsTranscode = false
        safeFrenchForcedDvdSubtitleStream = -1
        strictFrenchForcedDefaultTextSubtitleStream = -1
        legacyFrenchForcedTextSubtitleStream = -1
        PlayerSession.startInitialPlayback(root, JFB)
        updateClocksFromPlayback()
        _syncControlsTimer()
        Qt.callLater(_focusControlsLater)
    }

    Component.onDestruction: {
        try { primaryUiTimer.stop() } catch(ePrimaryUi) {}
        try { secondaryUiTimer.stop() } catch(eSecondaryUi) {}
        _storeSensitiveNavContext()
        PlayerSession.cleanupMediaPlayer(root, mp, JFB)
        if (!_internalDirectPlayReload) PlayerSession.clearPlaylist(root)
    }
}
