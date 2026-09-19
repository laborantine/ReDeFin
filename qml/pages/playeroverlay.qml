// ReDeFin DirectPlay : les sous-titres externes dormants ne forcent pas le remux initial.
// Le routage texte QML reste réservé au DirectPlay pur ; remux, DirectStream,
// transcodage et HLS restent gérés côté serveur. Les ticks Jellyfin sont figés
// avant Stop/Retour et le reporting de reprise reste délégué aux modules JS.
import QtQuick 2.15
import QtMultimedia 5.15
import "../components" as Components
import "../js/JellyfinPlaybackRouter.js" as JF
import "../js/jellyfinBridge.js"  as JFB
import "../js/playerOverlayHelper.js" as H
import "../js/DevLog.js" as DevLog
import "../js/SkipIntro.js" as SkipIntro
FocusScope {
    id: root
    width: 1920; height: 1080
    focus: true
    z: 900
    clip: false

    // Le PlayerOverlay doit toujours être visuellement opaque par rapport à la
    // page détail située dessous. Pendant un changement de source ou les toutes
    // premières frames du nouveau MediaPlayer, VideoOutput peut momentanément
    // ne rien dessiner. Ce fond empêche alors DetailMovie/DetailSerie de
    // transparaître sans modifier le pipeline vidéo.
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
                mediaGuard: mediaErrorRecoveryGuard
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
    // Raison du dernier armement de la gate. Elle distingue un rechargement
    // (négociation, reset dur, remplacement d'URL) d'une simple ouverture
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
        DevLog.log("T8", "loader ARM reason=" + reason)
        videoLoadingGate = true
        _videoLoadingReason = String(reason || "")
        try { videoLoadingHideTimer.stop() } catch(e0) {}
        if (!videoLoadingVisible && !videoLoadingShowTimer.running)
            videoLoadingShowTimer.restart()
    }
    function _releaseVideoLoading(reason){
        // Appelée à chaque seconde de lecture (« position-progress ») : ne
        // tracer que les libérations effectives, quand la gate était armée.
        if (DevLog.ENABLED && videoLoadingGate)
            DevLog.log("T8", "loader RELEASE reason=" + reason)
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
    // Un rechargement de source est en cours : reculer / avancer / scruber /
    // sauter de chapitre doivent être ignorés le temps qu'il aboutisse.
    // Retour, Stop, la sortie du lecteur et Lecture/Pause restent actifs.
    readonly property bool _reloadInProgress: H.reloadBlocksTransport(root)
    function _transportLocked(origin){
        if (!_reloadInProgress) return false
        DevLog.log("T15", "transport ignore origin=" + origin +
                    " sourceReset=" + _sourceResetActive +
                    " gate=" + videoLoadingGate + " reason=" + _videoLoadingReason)
        // Le geste est refusé mais reste une activité utilisateur : le HUD
        // doit rester visible pour montrer le chargement en cours.
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
    property string serverUrl: ""
    property string itemId: ""
    property string itemTitle: ""
    property string currentItemTitle: ""
    property string currentItemLogoUrl: ""
    property string currentItemType: ""
    // Pré-roll Jellyfin (/Items/{itemId}/Intros), alimenté notamment par jellyfin-plugin-intros. L'item principal reste toujours root.itemId.
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
    property string _topBarLogoCandidateNorm: ""
    property int _topBarLogoReadyPollsLeft: 0
    property var    fbx
    property var    shared: null
    property string playbackDeviceMode: ""
    property string playbackBackendMode: ""
    // Politique de lecture utilisateur. "smart" conserve les heuristiques ReDeFin ; "directplay" supprime uniquement les remux automatiques de préférence.
    property string playbackRuleMode: "smart"
    function _normalizedPlaybackRuleMode(value){ return JF.normalizePlaybackRuleMode(value) }
    function _smartPlaybackRulesEnabled(){
        // La préférence appartient à cette instance de PlayerOverlay. Ne pas
        // dépendre de l'état global du Router, qui peut encore refléter le
        // player précédent pendant quelques millisecondes au chargement.
        return _normalizedPlaybackRuleMode(playbackRuleMode) !== "directplay"
    }
    function _syncPlaybackRuleMode(reason){ var m=_normalizedPlaybackRuleMode(playbackRuleMode); if(playbackRuleMode!==m)playbackRuleMode=m; JF.setPlaybackRuleMode(m) }
    function _syncPlaybackBackend(reason){ JF.syncPlayerBackendContext(root) }
    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(root) : false
    }
    // Handshake léger avec DetailMoviePage. Le marker est posé AVANT le signal de retour afin qu'une fiche recréée sache qu'elle doit afficher son CircleDotsLoader dès sa toute première frame.
    function _markDetailReturnRefresh(reason){
        try {
            if (!shared || !itemId) return false
            shared.__redefinDetailReturnRefresh = ({
                itemId: String(itemId || ""),
                positionMs: Math.max(0, Math.floor(Number(_finalExitPositionMs || 0))),
                reason: String(reason || "player-exit"),
                ts: _nowMs()
            })
            return true
        } catch(e) {
            return false
        }
    }
    signal requestBackToDetails(string returnFocusId)
    // Reload interne demandé lors d'un passage Remux/Transcode -> DirectPlay.
    // ShellPage détruit puis recrée PlayerOverlay afin d'obtenir une NOUVELLE
    // instance QtMultimedia, seule façon fiable de retrouver le pipeline d'un
    // DirectPlay natif sur intelce.
    signal requestDirectPlayReload()
    onRequestBackToDetails: { _storeSensitiveNavContext() }
    property var    playlistRef: null
    property var    playerPlaylist: []
    property string playerPlaylistTitle: ""
    // Une playlist explicitement lancée depuis DetailSeriePage doit ignorer
    // PlaybackPositionTicks pour chacun de ses épisodes.
    property bool forcePlaylistStartAtZero: false
    property bool   autoplayNext: true
    property bool _internalDirectPlayReload: false
    property string selectedSeasonId: ""
    property var    seasonPageOrderIds: []   // liste d’IDs dans l’ordre d’affichage SeasonPage
    property bool clearPlaylistOnExit: true
    function _plHasContent(){ return H.playlistHasContent(playlistRef) }
    property bool nextOverlayEnabled: true
    property int  nextOverlayWindowMs: 30000
    property bool nextOverlayAutostart: false
    property int  tvSafeMargin: 60
    // Sous-titres texte rendus localement en DirectPlay pur.
    // Décalage VISUEL appliqué après le calcul des anchors du Loader :
    //   + => plus bas, - => plus haut.
    // Le déplacement positif est plafonné pour conserver la safe-area TV.
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
    function _syncNextOverlayContext(){ H.syncNextOverlayContext(root, nextLoader.item) }
    onPlayerPlaylistChanged: {
        if (playlistRef && playlistRef.list !== playerPlaylist)
            playlistRef.list = (playerPlaylist || []).map(function(x){return String(x||"")})
        _syncNextOverlayContext()
    }
    onPlayerPlaylistTitleChanged: {
        if (playlistRef && typeof playlistRef.title !== "undefined")
            playlistRef.title = playerPlaylistTitle || ""
    }
    onAutoplayNextChanged: {
        if (playlistRef && typeof playlistRef.autoplayNext !== "undefined")
            playlistRef.autoplayNext = autoplayNext
    }
    onPlaylistRefChanged: {
        if (playlistRef) {
            if (typeof playlistRef.autoplayNext !== "undefined")
                playlistRef.autoplayNext = autoplayNext
            if (playerPlaylist && playerPlaylist.length)
                playlistRef.list = (playerPlaylist || []).map(function(x){return String(x||"")})
            if (typeof playlistRef.title !== "undefined")
                playlistRef.title = playerPlaylistTitle || ""
            if (_plHasContent()) {
                var __idx = H.syncPlaylistToCurrent(root)
                if (__idx < 0 && typeof playlistRef.start === "function") playlistRef.start()
            }
        }
        _syncNextOverlayContext()
    }
    onSelectedSeasonIdChanged:  { if(!_plHasContent()) _ensureSeasonPlaylistFromHints() }
    onSeasonPageOrderIdsChanged:{ if(!_plHasContent()) _ensureSeasonPlaylistFromHints() }
    onNextUserHiddenChanged:    { _syncNextOverlayContext() }
    property bool skipIntroEnabled: true
    property var  skipIntroSegment: null       // { startMs, endMs, promptMs, hideMs, source, type }
    property string skipIntroLoadedItemId: ""
    property bool skipIntroDismissed: false
    property bool skipIntroConsumed: false
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
    // Verrou uniquement pour éviter de re-prioriser SkipIntro pendant que le
    // chrome reste visible après une sortie volontaire (↓ ou ←/→). Dès que le
    // chrome est totalement masqué, SkipIntro redevient éligible à l'auto-focus.
    property bool skipIntroFocusReleasedByUser: false
    property bool skipIntroFocusClaimed: false
    // Distingue le focus pris automatiquement lorsque le chrome est masqué du
    // focus demandé explicitement avec ↑ depuis la progressbar. Seul le premier
    // doit être rendu automatiquement lorsque les panneaux réapparaissent.
    property bool skipIntroAutoFocusClaimed: false

    onSkipIntroFocusClaimedChanged: {
        // Un seul focus visuel à la fois : quand SkipIntro est prioritaire,
        // masquer les halos ProgressBar/Transports sans perdre leur position logique.
        _updateControlsActive()
    }

    property bool skipIntroResumeGateActive: false
    property int skipIntroResumeTargetMs: -1
    property string skipIntroResumeGateReason: ""
    function _armSkipIntroResumeGate(targetMs, reason){ H.armSkipIntroResumeGate(root, targetMs, reason) }
    function _releaseSkipIntroResumeGate(actualUiMs){ H.releaseSkipIntroResumeGate(root, SkipIntro, skipIntroLoader.item, actualUiMs) }
    function _setSkipIntroItemActive(it, show){ H.setSkipIntroItemActive(root, SkipIntro, it, show) }
    function _syncSkipIntroOverlay(){ H.syncSkipIntroOverlay(root, SkipIntro, skipIntroLoader.item) }
    function _resetSkipIntroState(reason){ H.resetSkipIntroState(root, SkipIntro, skipIntroLoader.item, reason) }
    function _loadSkipIntroForCurrentItem(reason){ H.loadSkipIntroForCurrentItem(root, SkipIntro, skipIntroLoader.item, reason) }
    function skipIntroNow(origin){ H.skipIntroNow(root, SkipIntro, skipIntroLoader.item, mp.playbackState === MediaPlayer.PlayingState, origin) }
    function _armSkipIntroPlayback(){ return H.armSkipIntroPlayback(root, SkipIntro, skipIntroLoader.item, uiPositionMs()) }
    function _restoreFocusAfterSkipIntro(origin){
        skipIntroFocusClaimed=false; skipIntroAutoFocusClaimed=false; controlsVisible=true; controlsFocus=cF_CONTROLS; _updateControlsActive(); _syncControlsTimer(); try{root.forceActiveFocus()}catch(e){}
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
                // Focus AUTO uniquement lorsque le chrome est caché. Lorsque les
                // panneaux sont visibles, la priorité reste logique/visuelle.
                skipIntroAutoFocusClaimed = (String(reason || "") === "chrome-hidden")
                controlsTimer.stop()
                
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
    // changement de source / état. On ne dépend donc plus d'un simple binding QML :
    // le taux demandé est appliqué explicitement et resynchronisé avec un budget borné.
    property real playbackSpeed: 1.0
    property int _playbackRateSyncAttempts: 0
    readonly property int playbackRateSyncMaxAttempts: 4
    readonly property int playbackRateSyncDelayMs: 90
    function _normalizePlaybackSpeed(rate){
        return JF.normalizePlayerPlaybackSpeed(rate)
    }
    function _syncPlaybackSpeedToPlayer(reason, resetBudget){
        return JF.syncPlayerPlaybackSpeed(root, mp, playbackRateSyncTimer, resetBudget)
    }
    function _applyPlaybackSpeed(rate){
        playbackSpeed=_normalizePlaybackSpeed(rate)
        _syncPlaybackSpeedToPlayer("user", true)
        return true
    }

    // Feedback utilisateur lorsque le réglage Vitesse est utilisé sur un flux
    // qui n'est pas un DirectPlay pur. La fenêtre est non modale : elle ne
    // capture aucune touche et disparaît automatiquement en 5 secondes, avec
    // fondu d'entrée puis de sortie.
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
    // Opacité unique du chrome lecteur. Tous les éléments visuels du PlayerOverlay suivent cette même animation afin de disparaître exactement ensemble.
    readonly property bool uiChromeTargetVisible: !serverPrerollBlocking
                                                  && !nextUiLocked
                                                  && (controlsVisible || scrubActive || audioMenuVisible || subMenuVisible)
    property real uiChromeOpacity: uiChromeTargetVisible ? 1.0 : 0.0
    readonly property bool uiChromeRenderVisible: uiChromeTargetVisible || uiChromeOpacity > 0.001
    Behavior on uiChromeOpacity { NumberAnimation { duration: 280; easing.type: Easing.InOutQuad } }
    function _skipIntroAutoFocusAllowed() {
        // "Pas apparent" signifie ici que le chrome a fini son fade-out ET
        // qu'aucun panneau modal/track/scrub n'est encore actif.
        // Une sortie volontaire de SkipIntro ne vaut que tant que le chrome
        // reste visible : une fois le player nu, SkipIntro redevient prioritaire.
        return !uiChromeRenderVisible && !scrubActive &&
               !_chaptersPanelOpen() && !_qualityPanelOpen() && !_trackPanelOpen()
    }
    onUiChromeRenderVisibleChanged: {
        // Le retour du chrome ne retire plus la priorité visuelle/logique.
        // La prochaine navigation décide de la sortie : ↓ vers ProgressBar,
        // ←/→ vers le modèle courant, ↑ reste sur SkipIntro.
        if (uiChromeRenderVisible && skipIntroFocusClaimed) {
            
            return
        }
        if (!uiChromeRenderVisible && _skipIntroAutoFocusAllowed()) {
            // La sortie utilisateur ne doit pas survivre au passage en plein écran
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
        return H.seekToChapter(root,mp,_playbackTimers(),ms)
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
    function _isStaticDirectPlaySource(){ return H.isStaticDirectPlaySource(root) }
    function _fallbackStaticDirectPlayToServerRemux(targetUi, reason){
        return H.fallbackStaticDirectPlayToServerRemux(root, mp, _playbackTimers(), targetUi, reason)
    }
    function _guardUnsafeManualDirectPlayRequest(targetUi, reason){
        return H.guardUnsafeManualDirectPlayRequest(root, mp, _playbackTimers(), targetUi, reason)
    }
    function _maybeCompleteStaticDirectPlayFallback(reason){ return H.maybeCompleteStaticDirectPlayFallback(root, mp) }
    function _tryDirectPlayOpenRemuxFallback(reason){
        return H.tryDirectPlayOpenRemuxFallback(root, mp, _playbackTimers(), reason)
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
    property bool audioMenuVisible: false
    property bool subMenuVisible:   false
    property bool scrubActive: false
    property int  scrubAccumUiMs: -1
    property int  _scrubCommitTargetUiMs: -1
    property int  scrubCommitDelayMs: 1000
    property bool commitOnKeyRelease: false

    // DirectPlay obtenu apres un reload complet Remux/Transcodage -> DirectPlay :
    // certains fichiers font bloquer MediaPlayer.seek() 0,5 a 1,5 s sur intelce.
    // Les auto-repeat telecommande s'accumulent alors dans la file Qt puis
    // explosent en rafale. On coalesce UNIQUEMENT ce chemin degrade ; le
    // DirectPlay natif conserve son seek immediat, deja plus fluide.
    property bool coalescedDirectPlaySeekMode: false
    property int  coalescedDirectPlaySeekDelayMs: 85
    property int  coalescedDirectPlaySeekMaxJumpMs: 30000
    property int  _coalescedLocalSeekTargetUiMs: -1
    property int  _coalescedLocalSeekDirection: 0
    property var audioTracks: []
    property var audioStreamIndexMap: []
    property var audioCodecMap: []
    property int audioIndex: 0
    property int selectedAudioStream: -1
    property bool manualDirectPlayMode: false
    property int effectiveAudioStream: -1
    property var subtitleTracks: []
    property var subtitleStreamIndexMap: []
    property var subtitleIsTextMap: []
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
    // Handle annulable du téléchargement/conversion SRT/VTT en cours. Une seule
    // requête locale reste active afin d'éviter les réponses Jellyfin croisées.
    property var    _localSubtitleRequestHandle: null
    property int    subtitleDelayMs: 0
    // Résolution de l'horloge locale des sous-titres. Ce seuil ne décale pas les cues : il évite seulement des écritures QML redondantes à très haute fréquence. 50 ms = précision max de 1/20 s.
    property int    subsUiPushMinDeltaMs: 50
    // QtMultimedia 5.15 notifie position/bufferProgress toutes les 1000 ms par
    // défaut. Pour les sous-titres texte locaux DirectPlay uniquement, on
    // resserre cette cadence afin que les cues SRT/VTT apparaissent quasiment
    // à leur timestamp réel sans timer QML supplémentaire.
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
    // "server-timed" : reset historique pour flux serveur repositionné.
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
    // n'ouvre AUCUN flux : il est mémorisé ici, l'UI le reflète immédiatement,
    // et une seule négociation l'applique à la reprise. La décision pure vit
    // dans qml/js/DeferredReload.js.
    property var  _deferredReloadState: null
    property int  _deferredAudioUiIndex: -1
    property int  _deferredSubtitleUiIndex: -1
    property int  _deferredQualityValue: 0
    property bool _deferredReloadReplaying: false
    property bool _forceResumeAfterDeferredReload: false
    property bool _coalescedNegotiationActive: false
    property var  _coalescedNegotiationCall: null
    readonly property bool deferredReloadPending:
        _deferredAudioUiIndex >= 0 || _deferredSubtitleUiIndex >= 0 || _deferredQualityValue !== 0
    // Une pause réelle, hors téléchargement de source, hors scrub et hors
    // pré-roll : seul contexte dans lequel un réglage doit être différé.
    function _deferredReloadPauseActive(){
        return !_tearingDownPlayer && !serverPrerollBlocking && !_sourceResetActive &&
               !scrubActive && mp.playbackState === MediaPlayer.PausedState
    }
    function _resetDeferredReload(reason){ return H.resetDeferredReload(root, reason) }
    property int _autoLocalizeSubStream: -1
    property int resumePrerollMs: 1500
    property bool   scrobbleEnabled: true
    // Cadence de reprise : PlaybackPositionTicks est écrit très régulièrement
    // côté Jellyfin via le progressTimer existant, sans timer QML supplémentaire.
    // Cadence canonique Jellyfin : Progress + UserData, mêmes ticks.
    property int    progressEveryMs: 2500
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
            if (!(norm.length===0 && _lastPushedLogoNorm.length>0)) {
                if (norm !== _lastPushedLogoNorm) {
                    try { topBarLoader.item.itemLogoUrl = _pendingLogo } catch(e){}
                    _lastPushedLogoNorm = norm
                }
            }
            _topBarDirty = false
        }
    }
    function _queueTopBarPush(){ _topBarDirty=true; if(!topBarApplyTimer.running) topBarApplyTimer.start() }
    function isDsLike(){ return isHls || lastUsedTranscoding || lastUsedDirectStream || lastUsedServerRemux || serverTimedStream || timeShifted || (selectedAudioStream >= 0) }
    function isPureDirectPlay(){ return H.isPureDirectPlay(root) }
    function listIndexForStream(s){ return H.indexForStream(subtitleStreamIndexMap, s) }
    function _indexInStreamMap(map, streamIdx){
        if (!(streamIdx >= 0) || !map || map.length === undefined) return -1
        for (var i=0; i<map.length; ++i)
            if (Number(map[i]) === Number(streamIdx)) return i
        return -1
    }
    function _effectiveAudioUiIndexForSettings(){
        var count=audioTracks && audioTracks.length ? audioTracks.length : 0
        if (count <= 0) return 0
        var stream=selectedAudioStream >= 0 ? selectedAudioStream : effectiveAudioStream
        var idx=_indexInStreamMap(audioStreamIndexMap, stream)
        if (idx < 0) idx=audioIndex|0
        return Math.max(0, Math.min(idx, count-1))
    }
    function _effectiveSubtitleUiIndexForSettings(){
        var map=subtitleStreamIndexMap || []
        var count=map && map.length ? map.length
                  : ((subtitleTracks && subtitleTracks.length ? subtitleTracks.length : 0) + 1)
        if (count <= 0) return 0
        var stream=useLocalSubs && localSubStreamIndex >= 0 ? localSubStreamIndex
                  : (selectedSubtitleStream >= 0 ? selectedSubtitleStream : effectiveSubtitleStream)
        if (!(stream >= 0)) return 0
        var idx=_indexInStreamMap(map, stream)
        return idx < 0 ? Math.max(0, Math.min(subtitleIndex|0, count-1))
                       : Math.max(0, Math.min(idx|0, count-1))
    }
    // Index réellement affichés par les menus : une attente de rechargement
    // prend le pas sur l'état appliqué, afin que la coche suive immédiatement
    // le choix de l'utilisateur alors qu'aucun flux n'a encore été ouvert.
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
        // conservent seuls l'index synthétique 0 pour « Aucun ».
        H.syncTrackMenuIndexes(root, null, null)
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
        // froid, puis restaurer la position localement. Le détour historique
        // par handleAudioPick() injectait le temps courant dans la négociation
        // et pouvait déclencher le remux de seek préventif du Core.
        try {
            return H.handleQualityDirectPlay(root, mp) !== false
        } catch(e) {
            return false
        }
    }
    function _applyManualRemuxFromQuality(){
        return JF.applyManualRemuxQuality(root, mp)
    }
    function _applyAutomaticQualityFromQuality(){
        return JF.applyAutomaticQuality(root, mp)
    }
    function durationMs(){
        return JF.playerDurationMs(root, mp)
    }
    function uiPositionMs(){
        return JF.playerUiPositionMs(root, mp)
    }
    function subtitleClockMs(){
        return JF.playerSubtitleClockMs(root, mp)
    }
    function keepUi(){
        return JF.playerKeepUiPosition(root, mp)
    }
    function _ticks(ms){
        return Math.max(0, ms | 0) * 10000
    }
    function _rememberPersistablePositionMs(pos, reason){
        return JF.rememberPlayerPersistablePosition(root, mp, pos, reason)
    }
    function _capturePersistablePositionMs(reason){
        return JF.capturePlayerPersistablePosition(root, mp, reason)
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

        // Une seule position capturée devient l'autorité du checkpoint.
        // IMPORTANT Jellyfin : UserData doit être écrit APRES Progress afin que
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
    function _sendUserDataCheckpoint(reason){
        return _sendPlaybackCheckpoint(reason, false, false)
    }
    function _finalizeCurrentSessionForSwitch(reason){
        if (!playSessionId || _stoppedReportedSessionId === playSessionId ||
                _stoppedPendingSessionId === playSessionId)
            return
        var pos = _capturePersistablePositionMs(reason || "item-switch")
        try { progressTimer.stop() } catch(e0) {}
        try { resumeCheckpointTimer.stop() } catch(e1) {}
        JF.sendStoppedAtPosition(root, JFB, pos, function(){})
    }
    function finalizePlaybackAndExit(reason){
        if (_playbackExitInProgress)
            return true
        var wasServerPreroll = serverPrerollBlocking
        if (wasServerPreroll)
            _abortServerPrerollForExit(reason || "exit")
        _finalExitPositionMs = wasServerPreroll ? 0 : _capturePersistablePositionMs(reason || "exit")
        if (!wasServerPreroll)
            _rememberPersistablePositionMs(_finalExitPositionMs, reason || "exit")
        _playbackExitInProgress = true
        _resetDeferredReload("player-exit")
        try { scrubCommitTimer.stop() } catch(e0) {}
        _cancelCoalescedLocalSeek()
        try { resumeCheckpointTimer.stop() } catch(e1) {}
        try { progressTimer.stop() } catch(e2) {}
        // L'appel HTTP est amorcé avec une position figée avant que Qt ne puisse remettre mp.position à zéro. Le verrou bloque ensuite tous les handlers de StoppedState susceptibles d'écraser ces ticks.
        JF.sendStoppedAtPosition(root, JFB, _finalExitPositionMs, function(){})
        _tearingDownPlayer = true
        try { H.cancelLocalSubtitleRequest(root, "player-exit") } catch(eCancelSub) {}
        scrubActive = false
        scrubAccumUiMs = -1
        _scrubCommitTargetUiMs = -1
        try { mp.stop() } catch(e3) {}
        // Le retour peut recréer ou simplement réafficher DetailMoviePage. Dans les deux cas, le marker empêche toute frame de fiche obsolète.
        _markDetailReturnRefresh(reason || "player-exit")
        try { requestBackToDetails(itemId || "") } catch(e4) {}
        return true
    }
    function _beginTrackSwitchRebase(reason, forceLocalSeek){ return H.beginTrackSwitchRebase(root, mp, forceLocalSeek) }
    function _trackSwitchRebasedStartMs(fallbackMs){ return H.trackSwitchRebasedStartMs(root, fallbackMs) }
    function _armTrackSwitchTimebaseSettle(reason){ H.armTrackSwitchTimebaseSettle(root, trackSwitchSettleTimer) }
    function _resetSeekRestoreGuard(targetMs, reason){ H.resetSeekRestoreGuard(root, targetMs, reason) }
    function _trackSwitchFragileHevc(){ return H.trackSwitchFragileHevc(root) }
    function _seekRestoreIsTrueTrackSwitch(){ return H.seekRestoreIsTrueTrackSwitch(root) }
    function _seekRestoreToleranceMs(){ return H.seekRestoreToleranceMs(root) }
    function _completeSeekRestoreVerified(targetUi, localNow, diff, reason){ H.completeSeekRestoreVerified(root, seekRestoreTimer, trackSwitchVerifiedResumeTimer, targetUi) }
    function _abandonBootSeekRestoreWithoutReload(targetUi, reason){ H.abandonBootSeekRestoreWithoutReload(root, seekRestoreTimer, targetUi, reason) }
    function _failTrackSwitchExactSeek(reason){ H.failTrackSwitchExactSeek(root, mp, seekRestoreTimer, trackSwitchSettleTimer, trackSwitchFailureRestartTimer) }
    function _retrySeekRestoreWithJellyfinCopyRemux(targetUi, reason){
        H.retrySeekRestoreWithJellyfinCopyRemux(root, mp, _playbackTimers(), targetUi, reason)
    }
    function _finishTrackSwitchRebase(reason){
        H.finishTrackSwitchRebase(root, trackSwitchSettleTimer)
        _reassertSettingsFocus("track-switch-done")
    }
    // Etat affiché dans Qualité vidéo. Le menu reflète le mode réellement obtenu.
    function _qualityOriginalDirectPlaySelected(){
        return JF.qualityOriginalDirectPlaySelected(root, mp)
    }
    function _qualityRemuxSelected(){
        return JF.qualityRemuxSelected(root, mp)
    }
    function _qualityAutomaticServerSelected(){
        return JF.qualityAutomaticServerSelected(root, mp)
    }
    function _qualityAutomaticServerLabel(){
        return JF.qualityAutomaticServerLabel(root)
    }
    function _qualityStatusText(){
        return JF.qualityStatusText(root, mp)
    }
    // Valeur du panneau Qualité vidéo réellement cochée, avec exactement le
    // même ordre de priorité que PlayerSettingsOverlay._appliedIndex().
    function _activeQualityChoiceValue(){
        if (_qualityOriginalDirectPlaySelected()) return -1
        if (_qualityRemuxSelected()) return -2
        if (_qualityAutomaticServerSelected()) return -3
        if (manualQualityBitrate > 0) return manualQualityBitrate
        return -3
    }
    // Qualité vidéo réellement affichée par le panneau : une attente prend le
    // pas sur l'état appliqué.
    function _displayQualityBitrate(){
        return _deferredQualityValue > 0 ? _deferredQualityValue : manualQualityBitrate
    }
    function _displayQualityDirectPlaySelected(){
        return _deferredQualityValue !== 0 ? _deferredQualityValue === -1
                                           : _qualityOriginalDirectPlaySelected()
    }
    function _displayQualityRemuxSelected(){
        return _deferredQualityValue !== 0 ? _deferredQualityValue === -2
                                           : _qualityRemuxSelected()
    }
    function _displayQualityAutomaticSelected(){
        return _deferredQualityValue !== 0 ? _deferredQualityValue === -3
                                           : _qualityAutomaticServerSelected()
    }
    function _displayQualityStatusText(){
        return _deferredQualityValue !== 0 ? "Appliqué à la reprise de la lecture"
                                           : _qualityStatusText()
    }
    // Point d'entrée unique du panneau Qualité vidéo : une seule place décide
    // d'ignorer, de différer ou d'appliquer un choix de qualité.
    function _applyQualityChoice(requested){
        requested = Math.floor(Number(requested || 0))
        if (requested === 0) return false
        if (H.decideQualityChoice(root, requested) !== "applyNow") return true
        if (requested === -3) return _applyAutomaticQualityFromQuality()
        if (requested === -2) return _applyManualRemuxFromQuality()
        if (requested === -1) return _applyOriginalDirectPlayFromQuality()
        manualRemuxMode = false
        return H.applyManualQuality(root, mp, requested)
    }
    function _effectiveTopBarTitle(){
        // Tant que le logo n'est pas réellement prêt, le titre conserve son fallback centré. Dès qu'un logo est confirmé Ready, le TopBar central se libère. Pour un épisode, le titre est alors rendu juste sous le logo par episodeLogoTitle ci-dessous.
        return _topBarLogoReadyForCurrent ? "" : (currentItemTitle || "")
    }
    function _syncTopBarLogoReadyState(){
        var candidateNorm = _normalizeUrl(_pendingLogo || "")
        var readyNorm = ""
        try {
            if (topBarLoader.item && topBarLoader.item._lastGoodUrl !== undefined)
                readyNorm = _normalizeUrl(String(topBarLoader.item._lastGoodUrl || ""))
        } catch(e0) {
            readyNorm = ""
        }
        var ready = candidateNorm.length > 0 && readyNorm === candidateNorm
        if (_topBarLogoReadyForCurrent !== ready) {
            _topBarLogoReadyForCurrent = ready
            _pendingTitle = _effectiveTopBarTitle()
            _queueTopBarPush()
        }
        return ready
    }
    Timer {
        id: topBarLogoReadyTimer
        interval: 100
        repeat: false
        running: false
        onTriggered: {
            if (_syncTopBarLogoReadyState())
                return
            if (_topBarLogoReadyPollsLeft > 0 && _pendingLogo && _pendingLogo.length > 0) {
                _topBarLogoReadyPollsLeft--
                restart()
            }
        }
    }
    function refreshCurrentItemTitle(){
        if (!serverUrl || !accessToken || !itemId) {
            currentItemType = ""
            currentItemTitle = ""
            currentItemLogoUrl = ""
            _topBarLogoReadyForCurrent = false
            _pushTopBar()
            return
        }
        var expectedItemId = String(itemId || "")
        JFB.fetchItem(serverUrl, accessToken, expectedItemId, function(it){
            if (expectedItemId !== String(root.itemId || ""))
                return
            currentItemType = String(it && it.Type || "")
            currentItemTitle = H.labelForItem(it, itemTitle || "")
            currentItemLogoUrl = H.logoUrlFromItem(root, it)
            if (H.hasQueryTag(currentItemLogoUrl)) {
                lastGoodLogoUrl = currentItemLogoUrl
                lastGoodLogoItemId = (it && it.Id) ? String(it.Id) : expectedItemId
            }
            _topBarLogoReadyForCurrent = false
            _pushTopBar()
            _ensureAutoEpisodePlaylistWithItem(it)
            var typ = String(it && it.Type || "")
            if (!H.hasQueryTag(currentItemLogoUrl) &&
                    (typ === "Episode" || typ === "Season"))
                H.ensureSeriesLogoTag(root, JFB, it)
        }, function(){
            if (expectedItemId !== String(root.itemId || ""))
                return
            currentItemType = ""
            currentItemTitle = ""
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
        var candidateNorm = _normalizeUrl(candidate)
        if (_topBarLogoCandidateNorm !== candidateNorm) {
            _topBarLogoCandidateNorm = candidateNorm
            _topBarLogoReadyForCurrent = false
        }
        _pendingLogo = candidate
        // Détection immédiate lorsque TopBar possède déjà le logo en cache, puis polling court uniquement pendant le chargement asynchrone.
        _syncTopBarLogoReadyState()
        _pendingTitle = _effectiveTopBarTitle()
        _queueTopBarPush()
        if (candidateNorm.length > 0) {
            // Le polling court est également nécessaire pour les épisodes : leur titre ne quitte le centre qu'après confirmation Image.Ready.
            _topBarLogoReadyPollsLeft = 40
            topBarLogoReadyTimer.restart()
        } else {
            topBarLogoReadyTimer.stop()
        }
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
    function disableLocalSubsOverlay(){ H.disableLocalSubsOverlay(root,subsLoader.item,null,null); _syncTrackMenuIndexes("disableLocalSubsOverlay") }
    function _tryAutoLocalizeAfterDP(){ H.tryAutoLocalizeAfterDP(root, subsLoader.item) }
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
    function _cancelHardSourceReset(reason){ H.cancelHardSourceReset(root, sourceResetTimer) }
    function _commitFreshServerTimedSource(reason){
        H.completeFreshServerTimedSource(root, mp, sourceResetTimer, subsLoader.item)
        _reassertSettingsFocus("fresh-source-commit")
    }
    function _finishFreshServerTimedSourceTimeout(reason){
        H.completeFreshServerTimedSource(root, mp, sourceResetTimer, subsLoader.item)
        // Le reset dur a expiré sans progression : le comportement de sortie
        // reste celui du succès, mais la gate de chargement ne doit plus
        // pouvoir rester armée indéfiniment sur un pipeline qui ne démarre pas.
        _releaseVideoLoading("fresh-source-reset-timeout")
        _reassertSettingsFocus("fresh-source-timeout")
    }
    function _beginHardSourceReset(u,shouldResume){ H.beginHardSourceReset(root,mp,sourceResetTimer,audioGateDelay,startupPlayTimer,subsLoader.item,u,shouldResume) }
    function _beginFreshDirectPlayReset(u,shouldResume,targetUi){
        H.beginFreshDirectPlayReset(root,mp,sourceResetTimer,audioGateDelay,startupPlayTimer,subsLoader.item,u,shouldResume,targetUi)
    }
    function _mediaUrlSwap(u,resume){ H.mediaUrlSwap(root,mp,_playbackTimers(),subsLoader.item,u,resume) }
    function refreshStreams(done){
        H.refreshStreams(root, JF, function(ok){
            if (typeof done === "function") {
                try { done(ok) } catch(e0) {}
            }
        })
    }
    // Le cycle Local Intros est orchestré par le routeur playback. PlayerOverlay
    // conserve seulement les façades appelées par ses handlers et par le helper.
    function _resetServerPrerollState(reason){ JF.resetServerPrerollState(root, mp, JFB, reason) }
    function _sendServerPrerollStartIfNeeded(){ JF.sendServerPrerollStartIfNeeded(root, mp, JFB) }
    function _tryStartServerPreroll(mainStartMs, forceMainRemux, rawResumeMs){
        return JF.tryStartServerPreroll(root, mp, JFB, mainStartMs, forceMainRemux, rawResumeMs)
    }
    function _finishServerPreroll(reason){ JF.finishServerPreroll(root, mp, JFB, reason) }
    function _completeServerPrerollTransition(){ JF.completeServerPrerollTransition(root) }
    function _abortServerPrerollForExit(reason){ JF.abortServerPrerollForExit(root, mp, JFB, reason) }
    function _startInitialPlayback(){ JF.startInitialPlayback(root, JFB) }
    function _ensureSeasonPlaylistFromHints(){ H.ensureSeasonPlaylistFromHints(root, JFB) }
    function _ensureAutoEpisodePlaylist(){ H.ensureAutoEpisodePlaylist(root, JFB) }
    function _ensureAutoEpisodePlaylistWithItem(it){ H.ensureAutoEpisodePlaylistWithItem(root, JFB, it) }
    function negotiatePlayback(startMs, forceHls, preferTicks, forceMp4, forceDPOnAudioSwitch, extra){
        return H.negotiateAndApply(root, mp, JF, subsLoader.item,
                                   _playbackTimers(),
                                   startMs, forceHls, preferTicks, forceMp4,
                                   forceDPOnAudioSwitch, extra)
    }
    function loadLocalSubtitleByStreamIndex(streamIdx, cb, preserveOnFailure){
        return H.loadLocalSubtitleForOverlay(root, JFB, subsLoader.item, streamIdx, function(){
            if (typeof cb === "function") {
                try { cb.apply(null, arguments) } catch(e0) {
                    try { cb(arguments.length ? arguments[0] : false, arguments.length > 1 ? arguments[1] : "callback-error") } catch(e1) {}
                }
            }
        }, preserveOnFailure)
    }
    function _reportUiPositionMs(reason, isPaused){ return H.reportUiPositionMs(root, mp) }
    function _armFrozenPlaybackWatch(reason, windowMs){
        H.armFrozenPlaybackWatch(root, mp, _playbackTimers().frozenWatch, reason, windowMs)
    }
    function _stopFrozenPlaybackWatch(reason){ H.stopFrozenPlaybackWatch(root, _playbackTimers().frozenWatch) }
    function _tickFrozenPlaybackWatch(){
        if (serverPrerollBlocking) {
            _stopFrozenPlaybackWatch("server-preroll")
            return
        }
        H.tickFrozenPlaybackWatch(root, mp, _playbackTimers().frozenWatch, _playbackTimers().mediaGuard)
    }
    function _sendStartIfNeeded(positionMs){
        var p = (positionMs !== undefined && positionMs !== null)
              ? _clampUi(Number(positionMs) || 0)
              : _clampUi(keepUi())
        JF.sendStartIfNeeded(root, JFB, p)
    }
    function _sendProgress(isPaused, positionMs, done){
        var p = (positionMs !== undefined && positionMs !== null)
              ? _clampUi(Number(positionMs) || 0)
              : _capturePersistablePositionMs(isPaused ? "progress-paused" : "progress")
        JF.sendProgress(root, JFB, isPaused, p, done)
    }
    function _sendStopped(){ JF.sendStopped(root, JFB) }
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
    function _mediaSeekable(){
        try { return !!(mp && mp.seek && mp.seekable === true) } catch(e) { return false }
    }
    function shouldNetworkSeek(){
        // Un fichier DirectPlay statique non seekable ne doit jamais recevoir un mp.seek() local : on bascule sur un remux serveur positionné.
        if (_isStaticDirectPlaySource() && !_mediaSeekable()) return true
        if (isHls) return true
        if (lastUsedTranscoding) return true
        if (lastUsedDirectStream) return true
        if (lastUsedServerRemux) return true
        if (serverTimedStream || timeShifted) return true
        if (baseOffsetMs > 0) return true
        if (!durationMs() || durationMs() <= 0) return true
        return false
    }
    function _clampUi(t){ var d=durationMs(); if(d<=0)d=24*3600*1000; return Math.max(0,Math.min(t,d)) }
    function showScrubPreview(targetUi){ _pushProgress(targetUi, durationMs()) }
    function _serverSeekFallback(targetUi,reason){ H.serverSeekFallback(root,mp,_playbackTimers(),targetUi,reason) }
    function _localSeekTo(targetUi,reason){ return H.localSeekTo(root,mp,_playbackTimers(),targetUi,reason) }
    function _coalescedLocalSeekEligible(){
        if (!coalescedDirectPlaySeekMode) return false
        if (!_isStaticDirectPlaySource()) return false
        if (_pendingSeekMs >= 0 || _trackSwitchVerificationActive || _sourceResetActive) return false
        return !shouldNetworkSeek()
    }
    function _cancelCoalescedLocalSeek(){
        _coalescedLocalSeekTargetUiMs = -1
        _coalescedLocalSeekDirection = 0
        try { coalescedLocalSeekTimer.stop() } catch(e0) {}
    }
    function _queueCoalescedLocalSeek(deltaMs){
        if (!_coalescedLocalSeekEligible()) return false
        var nowUi = _clampUi(uiPositionMs())
        var dir = deltaMs < 0 ? -1 : 1
        var base = (_coalescedLocalSeekTargetUiMs >= 0 && _coalescedLocalSeekDirection === dir)
                 ? _coalescedLocalSeekTargetUiMs : nowUi
        var target = _clampUi(base + deltaMs)

        // Quand mp.seek() bloque le thread QML, plusieurs secondes d'auto-repeat
        // peuvent etre livrees d'un coup au retour. Elles ne doivent jamais
        // transformer une seule frame actualisee en saut de plusieurs minutes.
        var maxJump = Math.max(Math.abs(deltaMs), coalescedDirectPlaySeekMaxJumpMs | 0)
        if (dir > 0) target = Math.min(target, _clampUi(nowUi + maxJump))
        else target = Math.max(target, _clampUi(nowUi - maxJump))

        _coalescedLocalSeekDirection = dir
        _coalescedLocalSeekTargetUiMs = target
        lastUiTargetMs = target
        showScrubPreview(target)
        // Throttle, pas debounce : le timer ne redemarre pas a chaque repeat.
        // Il doit pouvoir produire des frames pendant un maintien continu.
        if (!coalescedLocalSeekTimer.running) coalescedLocalSeekTimer.start()
        return true
    }
    function _flushCoalescedLocalSeek(){
        if (!_coalescedLocalSeekEligible()) { _cancelCoalescedLocalSeek(); return }
        var target = _coalescedLocalSeekTargetUiMs
        _coalescedLocalSeekTargetUiMs = -1
        _coalescedLocalSeekDirection = 0
        if (target < 0) return
        _localSeekTo(target, "coalesced-directplay")
    }
    function commitScrub(){
        if (!scrubActive) return
        var target = (scrubAccumUiMs >= 0) ? scrubAccumUiMs : _scrubCommitTargetUiMs
        if (target < 0) target = (lastUiTargetMs >= 0 ? lastUiTargetMs : uiPositionMs())
        target = _clampUi(target)

        // Un choix audio effectué pendant la fenêtre de scrub doit être appliqué
        // avec CE target final. L'ancienne implémentation remplissait ces champs
        // sans jamais les consommer, d'où un premier choix parfois "avalé".
        var pendingAudioStream = _pendingAudioStream
        var pendingAudioIndex = _pendingAudioIndex
        var pendingAudioManualDirectPlay = _pendingAudioManualDirectPlay
        var hasPendingAudio = pendingAudioStream !== snt && pendingAudioIndex >= 0
        _pendingAudioStream = snt
        _pendingAudioIndex = -1
        _pendingAudioManualDirectPlay = false

        scrubActive = false
        scrubAccumUiMs = -1
        _scrubCommitTargetUiMs = -1
        if (subsLoader.item) subsLoader.item.gateArmed = false

        if (hasPendingAudio) {
            try {
                // Une seule négociation : sélection de piste + reprise à la
                // position de scrub. Si une garde DirectPlay refuse la demande,
                // on retombe simplement sur le seek normal ci-dessous.
                if (H.handleAudioPick(root, pendingAudioStream, pendingAudioIndex,
                                      pendingAudioManualDirectPlay, target) !== false)
                    return
            } catch(eAudio) {}
        }
        if (_pendingSeekMs >= 0){
            _setPendingSeekMs(_clampUi(target), "commitScrub-existing-pending")
            lastUiTargetMs = _pendingSeekMs
            showScrubPreview(_pendingSeekMs)
            return
        }
        // Un réglage différé embarque dans la négociation du seek : une seule
        // négociation, à la position finale, et la pause reste conservée si le
        // scrub a été lancé depuis une pause.
        if (H.seekDeferredReload(root, mp, target, "commitScrub", _wasPlayingBeforeSwitch))
            return
        if (shouldNetworkSeek()){
            _resumeWantedAfterNegotiation = _wasPlayingBeforeSwitch
            _serverSeekFallback(target, "commitScrub")
        } else {
            _localSeekTo(target, "commitScrub")
            if (_wasPlayingBeforeSwitch) mp.play()
        }
    }
    function seekBy(deltaMs){
        if (_transportLocked("seekBy")) return
        var d = durationMs(); if (d<=0) d = 24*3600*1000
        var nowUi = uiPositionMs()
        if (_pendingSeekMs >= 0){
            var base = (_pendingSeekMs >= 0) ? _pendingSeekMs : nowUi
            var targetUi = _clampUi(base + deltaMs)
            _setPendingSeekMs(targetUi, "seekBy-existing-pending")
            lastUiTargetMs = targetUi
            showScrubPreview(targetUi)
            return
        }
        if (shouldNetworkSeek()){
            _cancelCoalescedLocalSeek()
            if (!scrubActive){
                scrubActive = true
                if (subsLoader.item) subsLoader.item.gateArmed = true
                _wasPlayingBeforeSwitch = (mp.playbackState === MediaPlayer.PlayingState)
                mp.pause()
            }
            var base2 = (scrubAccumUiMs >= 0 ? scrubAccumUiMs : nowUi)
            scrubAccumUiMs = _clampUi(base2 + deltaMs)
            _scrubCommitTargetUiMs = scrubAccumUiMs
            lastUiTargetMs = scrubAccumUiMs
            showScrubPreview(scrubAccumUiMs)
            scrubCommitTimer.restart()
            return
        }
        if (_queueCoalescedLocalSeek(deltaMs)) return
        _localSeekTo(nowUi + deltaMs, "seekBy")
    }
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
        onTriggered: H.tickSourceReset(root, mp, sourceResetTimer, seekRestoreTimer, subsLoader.item)
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
        onTriggered: H.tickSeekRestore(root, mp, seekRestoreTimer)
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
    function _recoverFromMediaError(){ H.recoverFromMediaError(root,mp,_playbackTimers().frozenWatch,_playbackTimers().mediaGuard) }
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
            DevLog.log("T7", "mpError error=" + mp.error + " " + mp.errorString +
                        " status=" + mp.status + " sourceReset=" + _sourceResetActive)
            if (serverPrerollBlocking) {
                if (_serverPrerollState === 2)
                    _finishServerPreroll("media-error")
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
                _completeServerPrerollTransition()
            // Cette source est le média principal uniquement une fois sorti de l'état pré-roll. Cela évite d'armer Skip Intro sur le clip Local Intros.
            if (hasSource && !serverPrerollBlocking)
                _skipIntroMainSourceSeen = true
            if (hasSource)
                root._syncPlaybackSpeedToPlayer("source-changed", true)
        }
        onPlaybackStateChanged: {
            DevLog.log("T10", "playbackState=" + mp.playbackState + " status=" + mp.status +
                        " pos=" + mp.position + " gate=" + videoLoadingGate +
                        " reason=" + _videoLoadingReason)
            if (_tearingDownPlayer) return
            if (serverPrerollBlocking) {
                if (serverPrerollActive && mp.playbackState === MediaPlayer.PlayingState) {
                    _sendServerPrerollStartIfNeeded()
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
                    _sendServerPrerollStartIfNeeded()
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
            DevLog.log("T10", "status=" + mp.status + " state=" + mp.playbackState +
                        " pos=" + mp.position + " err=" + mp.error +
                        " gate=" + videoLoadingGate + " reason=" + _videoLoadingReason)
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
                    _finishServerPreroll("end-of-media")
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
                JF.sendStoppedAtPosition(root, JFB, endPos, function(){})
                if (playlistRef && autoplayNext) {
                    hideNextPanel()
                    nextHiddenWaiter.budget = nextHideMaxWaitMs
                    nextHiddenWaiter.restart()
                }
            }
        }
    }
    VideoOutput {
        id: videoOutput
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
        id: speedDirectPlayPopup
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
                item.showClock   = Qt.binding(function(){ return root.topbarShowClock })
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
    Text {
        id: episodeLogoTitle
        z: 501
        anchors.left: parent.left
        anchors.leftMargin: Math.max(28, root.tvSafeMargin)
        anchors.top: parent.top
        anchors.topMargin: 63
        width: Math.min(760, Math.max(240, root.width - Math.max(28, root.tvSafeMargin) - 420))
        visible: topBarLoader.visible
                 && root.uiChromeRenderVisible
                 && root.currentItemIsEpisode
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
            
            skipIntroNow("../components/SkipIntro.qml")
            _restoreFocusAfterSkipIntro("skip")
        }
        function onDismissed() {
            
            skipIntroDismissed = true
            skipIntroFocusReleasedByUser = true
            if (skipIntroLoader.item) { try { _setSkipIntroItemActive(skipIntroLoader.item, false) } catch(e) {} }
            _restoreFocusAfterSkipIntro("dismissed")
        }
        function onVisualExpired() {
            // Expiration automatique des 10 s : restituer uniquement le focus.
            // Ne jamais passer par _restoreFocusAfterSkipIntro()/resetControlsTimer(),
            // car ces chemins rendent volontairement le chrome visible.
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
        try {
            if (playlistRef && Array.isArray(playlistRef.list) && playlistRef.list.length > 0) src = playlistRef.list
            else if (Array.isArray(playerPlaylist) && playerPlaylist.length > 0) src = playerPlaylist
        } catch(e) { src = [] }
        var out = []
        for (var i=0; i<src.length; i++) {
            var v = String(src[i] || "")
            if (v.length) out.push(v)
        }
        return out
    }
    function _syncPlaylistIndex(i){ try{if(!playlistRef)return; if(typeof playlistRef.setIndex==="function")playlistRef.setIndex(i); else if(typeof playlistRef.index!=="undefined")playlistRef.index=i}catch(e){} }
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
        if (!willPause && H.resumeDeferredReload(root, mp, origin || "manual-toggle"))
            return
        try {
            if (willPause) { mp.pause() }
            else { mp.play() }
        } catch(e) {
        }
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
            item.directPlaySelected = Qt.binding(function(){
                return root._displayQualityDirectPlaySelected()
            })
            item.remuxSelected = Qt.binding(function(){
                return root._displayQualityRemuxSelected()
            })
            item.automaticServerSelected = Qt.binding(function(){
                return root._displayQualityAutomaticSelected()
            })
            item.automaticQualityLabel = Qt.binding(function(){
                return root._qualityAutomaticServerLabel()
            })
            item.qualityStatusText = Qt.binding(function(){
                return root._displayQualityStatusText()
            })
            item.selectedMode = Qt.binding(function(){ return root.videoZoomMode })
            item.selectedRate = Qt.binding(function(){ return root.playbackSpeed })
            item.speedDirectPlayAvailable = Qt.binding(function(){ return root.isPureDirectPlay() })
            item.audioMenuOpen = Qt.binding(function(){ return root.audioMenuVisible })
            item.subtitleMenuOpen = Qt.binding(function(){ return root.subMenuVisible })
            item.audioTracks = Qt.binding(function(){ return root.audioTracks })
            item.audioStreamIndexMap = Qt.binding(function(){ return root.audioStreamIndexMap })
            item.audioCurrentIndex = Qt.binding(function(){ return root._displayAudioUiIndexForSettings() })
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
        return H.handleAudioPick(root, streamIdx, uiIdx,
                                 explicitManualDirectPlay === true, targetUiOverride)
    }
    function handleSubsOff(){ H.handleSubsOff(root) }
    function handleSubsText(streamIdx, listIdx){
        H.handleSubsText(root, subsLoader.item, streamIdx, listIdx)
    }
    function handleSubsImage(streamIdx, listIdx){
        H.handleSubsImage(root, streamIdx, listIdx)
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
    function _resetCommonPlaybackRuntimeState(resetScrub) {
        baseOffsetMs = 0
        _setPendingSeekMs(-1, "reset-common-runtime")
        _pendingHardResetBaseMs = -1
        lastUiTargetMs = 0
        if (resetScrub === true) {
            scrubActive = false
            scrubAccumUiMs = -1
            _scrubCommitTargetUiMs = -1
        }

        _pauseWatchStartedWallMs = 0
        _pauseWatchStartedUiMs = 0
        _pauseWatchLastStableUiMs = 0
        _pauseWatchLastStableWallMs = 0
        _pauseWatchInPause = false

        _mediaErrorRecoveryInProgress = false
        _mediaErrorRecoverySafeUiMs = 0
        _mediaErrorProgressGuardUntilWallMs = 0
        _mediaErrorRecoveryReason = ""

        _frozenPlaybackWatchActive = false
        _frozenPlaybackNoProgressSinceWallMs = 0
        _frozenPlaybackRecoveryCount = 0
        _frozenPlaybackLastLocalMs = -1
        _frozenPlaybackLastUiMs = -1
        try { frozenPlaybackWatchTimer.stop() } catch(eFrozenWatch) {}

        lastUsedServerRemux = false
        serverTimedStream = false
        timeShifted = false
        currentPlaybackVideoTranscodeByPolicy = false

        _trackSwitchVerificationActive = false
        _trackSwitchTimebaseVerified = false
        _trackSwitchRequestedUiMs = 0
        _trackSwitchLocalStrategy = 1
        _seekRestoreLastCallWallMs = 0
        _seekRestoreAwaitingResult = false
        _seekRestoreStableSamples = 0
        _seekRestoreBestDiffMs = 2147483647
        _seekRestoreBestLocalMs = -1
        _seekRestoreAccepted = false
        _seekRestoreReadyWallMs = 0
        _seekRestorePrimeWallMs = 0
        _seekRestorePhase = 0
        _trackSwitchSourceHevc10 = false
        _trackSwitchSourceVideoCodec = ""
        _trackSwitchSourceContainer = ""

        _directPlayOpenFallbackUsed = false
        _directPlayOpenStartedWallMs = 0
        _staticDirectPlaySeekUnsafe = false
        _staticDirectPlaySeekUnsafeItemId = ""
        _staticDirectPlaySeekFallbackInProgress = false
        _staticDirectPlayFallbackAwaitingStableRemux = false
        _staticDirectPlayFallbackTargetMs = -1
        _staticDirectPlayFallbackStartedWallMs = 0

        _startedReported = false
        _reportedSessionId = ""
        _stoppedReportedSessionId = ""
        _stoppedPendingSessionId = ""
        _lastProgressSentMs = 0
        _lastUserDataSentMs = 0
        _playbackExitInProgress = false
        _finalExitPositionMs = -1
        _lastPersistableUiMs = 0
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
        _syncPlaybackBackend("completed")
        controlsVisible=true; controlsFocus=cF_CONTROLS; root.forceActiveFocus()
        _syncControlsTimer(); Qt.callLater(_focusControlsLater)
        if (playlistRef) {
            if (typeof playlistRef.autoplayNext !== "undefined")
                playlistRef.autoplayNext = autoplayNext
            if (playerPlaylist && playerPlaylist.length)
                playlistRef.list = (playerPlaylist || []).map(function(x){return String(x||"")})
            if (typeof playlistRef.title !== "undefined")
                playlistRef.title = playerPlaylistTitle || ""
        }
        _syncNextOverlayContext()
        if (nextLoader.item && nextLoader.item.findNextByPlaylist)
            nextLoader.item.findNextByPlaylist(itemId, nextLoader.item.playlist)
        refreshStreams()
        selectedAudioStream = -1
        selectedSubtitleStream = -1
        useLocalSubs = false
        manualDirectPlayMode = false
        manualRemuxMode = false
        _resetCommonPlaybackRuntimeState(false)
        _pushTopBar()
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("completed")
        if (!_plHasContent()) _ensureAutoEpisodePlaylist()
        _startInitialPlayback()
        updateClocksFromPlayback()
    }
    onFbxChanged:        { _syncPlaybackBackend("fbxChanged"); _syncNextOverlayContext() }
    onPlaybackDeviceModeChanged: _syncPlaybackBackend("playbackDeviceModeChanged")
    onPlaybackRuleModeChanged: _syncPlaybackRuleMode("playbackRuleModeChanged")
    onAccessTokenChanged: {
        _resetServerPrerollState("accessToken")
        refreshStreams()
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("accessToken")
        if (!_plHasContent()) _ensureAutoEpisodePlaylist()
        _startInitialPlayback()
        _syncNextOverlayContext()
    }
    onUserIdChanged: {
        _resetServerPrerollState("userId")
        refreshCurrentItemTitle()
        if (!_plHasContent()) _ensureAutoEpisodePlaylist()
        _startInitialPlayback()
        _syncNextOverlayContext()
    }
    onServerUrlChanged: {
        _resetServerPrerollState("serverUrl")
        refreshStreams()
        refreshCurrentItemTitle()
        _loadSkipIntroForCurrentItem("serverUrl")
        if (!_plHasContent()) _ensureAutoEpisodePlaylist()
        _startInitialPlayback()
        _queueTopBarPush()
        _syncNextOverlayContext()
    }
    onItemIdChanged: {
        try { H.cancelLocalSubtitleRequest(root, "item-changed") } catch(eCancelSub) {}
        currentItemType = ""
        _topBarLogoReadyForCurrent = false
        _topBarLogoCandidateNorm = ""
        _topBarLogoReadyPollsLeft = 0
        try { topBarLogoReadyTimer.stop() } catch(eTopBarLogoTimer) {}
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
        if (!_plHasContent()) _ensureAutoEpisodePlaylist()
        _cancelHardSourceReset("item-changed")
        _resetCommonPlaybackRuntimeState(true)
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
        _startInitialPlayback()
        updateClocksFromPlayback()
        _syncControlsTimer()
        Qt.callLater(_focusControlsLater)
    }
    function _stopTimerSafe(t){ try{if(t&&t.running)t.stop()}catch(e){} }
    function _cleanupMediaPlayerForDestruction() {
        var wasServerPreroll = serverPrerollBlocking
        if (wasServerPreroll)
            _abortServerPrerollForExit("destruction")
        if (_finalExitPositionMs < 0)
            _finalExitPositionMs = wasServerPreroll ? 0 : _capturePersistablePositionMs("destruction")
        try { _sendStopped() } catch(eStop) {}
        _tearingDownPlayer = true
        _stopTimerSafe(nextRearmTimer)
        _stopTimerSafe(topBarApplyTimer)
        _stopTimerSafe(topBarLogoReadyTimer)
        _stopTimerSafe(progressTimer)
        _stopTimerSafe(resumeCheckpointTimer)
        _stopTimerSafe(controlsTimer)
        _stopTimerSafe(startupPlayTimer)
        _stopTimerSafe(sourceResetTimer)
        _stopTimerSafe(audioGateDelay)
        _stopTimerSafe(seekRestoreTimer)
        _stopTimerSafe(scrubCommitTimer)
        _stopTimerSafe(coalescedLocalSeekTimer)
        _stopTimerSafe(mediaErrorRecoveryGuard)
        _stopTimerSafe(pauseResumeProbeTimer)
        _stopTimerSafe(trackSwitchFailureRestartTimer)
        _stopTimerSafe(trackSwitchVerifiedResumeTimer)
        _stopTimerSafe(frozenPlaybackWatchTimer)
        _stopTimerSafe(videoLoadingShowTimer)
        _stopTimerSafe(videoLoadingHideTimer)
        _stopTimerSafe(videoLoadingReleaseTimer)
        _stopTimerSafe(speedDirectPlayPopupFadeOutTimer)
        _stopTimerSafe(speedDirectPlayPopupCleanupTimer)
        _stopTimerSafe(playbackRateSyncTimer)
        _stopTimerSafe(nextHiddenWaiter)
        try { disableLocalSubsOverlay() } catch(e0) {}
        try {
            if (mp) {
                mp.stop()
                mp.source = ""
            }
        } catch(e1) {}
        mediaUrl = ""
        _setPendingSeekMs(-1, "component-cleanup")
        _pendingServerTimedBaseMs = -1
        _sourceResetActive = false
        _sourceResetPhase = 0
        _sourceResetPendingUrl = ""
        _sourceResetExpectedUiMs = -1
        _sourceResetReadyWallMs = 0
        _pendingHardResetBaseMs = -1
        scrubActive = false
        scrubAccumUiMs = -1
        _scrubCommitTargetUiMs = -1
        _coalescedLocalSeekTargetUiMs = -1
        _coalescedLocalSeekDirection = 0
        _startupPlayWanted = false
        _directPlayOpenFallbackUsed = false
        _directPlayOpenStartedWallMs = 0
        _gateArmed = false
        _resumeAfterGate = false
        _deferredReloadReplaying = false
        _forceResumeAfterDeferredReload = false
        _coalescedNegotiationActive = false
        _coalescedNegotiationCall = null
        _resetDeferredReload("destruction")
        _mediaErrorRecoveryArmed = false
        _mediaErrorRecoveryInProgress = false
        _frozenPlaybackWatchActive = false
        _pauseWatchInPause = false
        videoLoadingGate = false
        videoLoadingVisible = false
    }
    Component.onDestruction: {
        try { primaryUiTimer.stop() } catch(ePrimaryUi) {}
        try { secondaryUiTimer.stop() } catch(eSecondaryUi) {}
        _storeSensitiveNavContext()
        _cleanupMediaPlayerForDestruction()
        if (!_internalDirectPlayReload) H.clearPlaylist(root, "destruction")
    }
}
