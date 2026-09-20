// qml/pages/detailMoviePage.qml — QtQuick 2.15 / sans Controls
// Version compactée en gardant les optimisations déjà effectives.
import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../components" as Components
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/SafeLog.js" as SafeLog
FocusScope {
    id: detailMoviePage
    width: 1280; height: 720; focus: true
    /* ===== Contexte ===== */
    property string accessToken: ""
    property string userId: ""
    property string serverUrl: ""
    property string itemId: ""
    property string userName: ""
    property string userImageTag: ""
    property var fbx
    property var shared: null
    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(detailMoviePage, false, 0, false) : false
    }
    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(detailMoviePage) : false
    }
    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(detailMoviePage, page, params || ({})) : (page + "?ctx=1")
    }
    property var settings: null
    readonly property bool showClockHud: {
        try { if (settings && settings.showClock !== undefined) return !!settings.showClock } catch(e) {}
        try { if (Components.AppSettings && Components.AppSettings.showClock !== undefined) return !!Components.AppSettings.showClock } catch(e2) {}
        try { if (fbx && fbx.showClock !== undefined) return !!fbx.showClock } catch(e3) {}
        return true
    }
    property bool enableAvatarProfileNavigation: false
    property bool disposed: false
    readonly property bool lowPowerMode: true
    readonly property bool flickBusy: !!(rootFlick && (rootFlick.moving || rootFlick.dragging))
    property bool enableSceneFreeze: false
    function safeRestart(t){ if (!t) return; try { t.restart() } catch(e) { try { t.stop(); t.start() } catch(e2) {} } }
    function safeCallLater(fn){ Qt.callLater(function(){ if (!disposed && fn) fn() }) }
    function _setPropSafe(o, p, v){ if (!o) return; try { if (p in o) o[p] = v } catch(e) {} }
    /* ===== Style ===== */
    readonly property color glassBase      : "#E6FFFFFF"
    readonly property color glassFocus     : "#1AFFFFFF"
    readonly property color glassBorder    : "#33FFFFFF"
    readonly property color glassBorderDim : "#18FFFFFF"
    readonly property color infoValueColor : "#C8CCD8"
    readonly property bool aaEdges: true
    readonly property real posterOS: 1.35
    readonly property real posterHqOS: 1.60
    readonly property int posterHqQuality: 92
    property bool posterHqArmed: false
    readonly property real frameRadiusRatio: 0.06
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    function frameMargin(){ return frameInsetPx + frameWidth / 2 + frameInnerEpsilon }
    /* ===== Guard nav ===== */
    property var _navGuard: ({ busy:false, lastId:"", t:0 })
    function _openOnce(id, url){
        var now = Date.now()
        if (!id || id === itemId)
            return
        // Capturer l'objet avant requestNavigation(): la page peut être détruite
        // avant l'évaluation différée du callback Qt.callLater.
        var guard = _navGuard
        if (!guard)
            return
        if (guard.busy
                && guard.lastId === id
                && (now - guard.t) < 900)
            return
        guard.busy = true
        guard.lastId = id
        guard.t = now
        if (typeof requestNavigation === "function")
            requestNavigation(url)
        safeCallLater(function(){
            if (guard)
                guard.busy = false
        })
    }
    /* ===== Data ===== */
    property var item: null
    property var castPeopleAll: []
    property var castPeople: []
    property int  castInitialLimit: 12
    property bool castExpanded: false
    // Préchargement direct des portraits Cast depuis DetailMoviePage.
    // Objectif: lancer les URLs portraits dès que fetchItem() donne People,
    // donc bien avant que l'utilisateur descende jusqu'au bloc Distribution.
    property bool castPortraitPrewarmEnabled: true
    property int  castPortraitPrewarmCount: 6
    property int  castPortraitPrewarmImmediateCount: 3
    property int  castPortraitPrewarmDeferredCount: 3
    property bool _castPortraitPrewarmSecondPhase: false
    readonly property int castPortraitPrewarmW: 322
    readonly property int castPortraitPrewarmH: 483
    property var  castPortraitPrewarmPeople: []
    property int  _castPortraitPrewarmEpoch: 0
    function _clearCastPortraitPrewarm(){
        castPortraitPrewarmPeople = []; _castPortraitPrewarmSecondPhase = false; _castPortraitPrewarmEpoch++
        if (castPortraitPrewarmDeferredTimer.running) castPortraitPrewarmDeferredTimer.stop()
    }
    property int  similarWarmCount: 14
    property bool similarExpanded: false
    property var  chipModel: []
    property string genresLine: ""
    property bool posterLogoFailed: false
    function _resetData(clearError){
        item = null
        castPeopleAll = []; castPeople = []; castExpanded = false
        _clearCastPortraitPrewarm()
        similarExpanded = false
        chipModel = []; genresLine = ""
        posterLogoFailed = false
        if (clearError) loadingError = ""
    }
    function _resetOverlay(){
        overlayMode = "none"; overlayData = ({}); lastFocusBeforeOverlay = 0
    }
    function _applyCastWarm(){
        if (!castPeopleAll || castPeopleAll.length === 0) { castPeople = []; castExpanded = false; return }
        castExpanded = castPeopleAll.length <= castInitialLimit
        castPeople = castExpanded ? castPeopleAll : castPeopleAll.slice(0, castInitialLimit)
    }
    function _personPrimaryTagForPrewarm(p) {
        if (!p) return ""
        if (p.PrimaryImageTag) return String(p.PrimaryImageTag)
        if (p.ImageTags && p.ImageTags.Primary) return String(p.ImageTags.Primary)
        return ""
    }

    function castPortraitUrlForPrewarm(p) {
        if (!castPortraitPrewarmEnabled || !p || !p.Id || !serverUrl) return ""
        var tag = _personPrimaryTagForPrewarm(p)
        if (!tag) return ""
        // Même URL et mêmes dimensions que CastPage pour maximiser le partage du cache QML.
        return Jellyfin.itemImageUrl(serverUrl, p.Id, "Primary", tag, {
            format: "jpg",
            quality: 82,
            fillWidth: castPortraitPrewarmW,
            fillHeight: castPortraitPrewarmH
        })
    }
    function _refreshCastPortraitPrewarm() {
        if (!castPortraitPrewarmEnabled || disposed || !visible || !serverUrl || !castPeopleAll || castPeopleAll.length <= 0) {
            _clearCastPortraitPrewarm()
            return
        }
        var cap = Math.min(Math.max(0, castPortraitPrewarmCount | 0), castPeopleAll.length)
        var first = Math.min(Math.max(0, castPortraitPrewarmImmediateCount | 0), cap)
        var deferred = Math.max(0, castPortraitPrewarmDeferredCount | 0)
        var n = _castPortraitPrewarmSecondPhase ? Math.min(cap, first + deferred) : first
        var arr = []
        for (var i = 0; i < n; ++i) {
            var p = castPeopleAll[i]
            if (p && p.Id && _personPrimaryTagForPrewarm(p)) arr.push(p)
        }
        castPortraitPrewarmPeople = arr
        _castPortraitPrewarmEpoch++
        if (!_castPortraitPrewarmSecondPhase && cap > n && !disposed && visible && !castPortraitPrewarmDeferredTimer.running)
            castPortraitPrewarmDeferredTimer.restart()
    }
    function _hydrateCastNow(){
        if (castExpanded || !castPeopleAll || !castPeopleAll.length) return
        castExpanded = true; castPeople = castPeopleAll
        if (castPageLoader.item) {
            try { castPageLoader.item.people = castPeople } catch(e) {}
            safeCallLater(function(){ _applyBlockPerf(castPageLoader.item) })
        }
    }
    onCastPeopleChanged: {
        _refreshCastPortraitPrewarm()
        if (castPageLoader.item) try { castPageLoader.item.people = castPeople } catch(e) {}
        _updateExtendedSectionGates()
    }
    function _applySimilarWarm(){
        if (!similarLoader.item) return
        var it = similarLoader.item
        _setPropSafe(it, "warmCount", similarWarmCount)
        _setPropSafe(it, "expanded", false)
        _setPropSafe(it, "lowPowerMode", lowPowerMode)
        _setPropSafe(it, "fxOnDemand", lowPowerMode)
        _setPropSafe(it, "fxFocusOnly", lowPowerMode)
        try { if (typeof it.requestFetchSoon === "function") it.requestFetchSoon() } catch(e2) {}
    }
    function _expandSimilarIfNeeded(){
        if (similarExpanded || !similarLoader.item) return
        similarExpanded = true
        var it = similarLoader.item
        _setPropSafe(it, "expanded", true)
        _setPropSafe(it, "warmCount", 9999)
        try {
            if (typeof it.expandAll === "function") it.expandAll()
            if (typeof it.fetchSimilarFull === "function") it.fetchSimilarFull()
        } catch(e) {}
    }
    /* ===== Derived ===== */
    readonly property bool ctxOk: !!(serverUrl && accessToken && itemId)
    property bool   hasItem: !!item
    readonly property bool isMusicVideo: MediaCatalog.isMusicVideoItem(item)
    property string itemTitle: hasItem && item.Name ? item.Name : ""
    readonly property string artistsLine: MediaCatalog.mediaArtistsText(item)
    property bool   overviewVisible: !!(hasItem && item.Overview && item.Overview.length > 0)
    property int    durationMinutes: MediaCatalog.mediaRuntimeMinutes(item)
    property string endTimeString: {
        if (!durationMinutes) return ""
        var n = new Date(); n.setMinutes(n.getMinutes() + durationMinutes)
        return SeasonUtils.pad2(n.getHours()) + ":" + SeasonUtils.pad2(n.getMinutes())
    }
    property string directorsLine: {
        var s = MediaCatalog.mediaDirectorsText(item)
        return s || (isMusicVideo ? "" : "inconnu")
    }
    function safeRowHeight(){
        var ovh = 0
        try { if (overviewBox && overviewBox.visible) ovh = overviewBox.height|0 } catch(e) {}
        return Math.max(posterH, Math.max(overviewMinH, ovh) + 40)
    }
    /* ===== Layout ===== */
    property int marginL: 40
    property int marginR: 40
    property int contentTopGap: 90
    property int titleTopExtra: 0
    property int titleLeftOffset: 235
    property int sectionsSpacing: 12
    property int headerTopNudgeY: -12
    property int titleCharLimit: 45
    property int titleFontPx: 38
    property real titleMarqueeSpeedPxPerSec: 56
    property int titleMarqueePauseStartMs: 700
    property int titleMarqueePauseEndMs: 260
    property int tagsMarqueePauseStartMs: 700
    property int tagsMarqueePauseEndMs: 260
    property real directorMarqueeSpeedPxPerSec: 56
    property int directorMarqueePauseStartMs: 700
    property int directorMarqueePauseEndMs: 260
    property int infoLeft: 40
    property int infoW: 180
    property int infoRowGap: 14
    property int infoTopExtra: 15
    property int infoNudgeX: 0
    property int playBtnTopExtra: 55
    property int playBtnSize: 56
    property int actionsNudgeX: 0
    property bool overviewAutoWidth: true
    property int overviewFromInfoGap: 12
    property int overviewLeftOffset: 24
    property int overviewAnchorLeft: 40
    property int centerLeft: (overviewAnchorLeft + infoW + overviewFromInfoGap + overviewLeftOffset)
    property int overviewW: 600
    property int overviewMinH: 190
    property int overviewTopShift: -5
    property int overviewMaxLines: 7
    property int posterW: 230
    property int posterH: 330
    property int posterEdgeGap: 20
    property int posterTopOffset: -20
    readonly property real artworkRatio: {
        var r = Number(item && item.PrimaryImageAspectRatio || 0)
        if ((!r || r <= 0) && posterPrimary && posterPrimary.sourceSize.height > 0) r = posterPrimary.sourceSize.width / posterPrimary.sourceSize.height
        return (isFinite(r) && r > 0) ? Math.max(0.55, Math.min(2.4, r)) : (isMusicVideo ? 16/9 : posterW/posterH)
    }
    readonly property int artworkH: isMusicVideo ? Math.max(96, Math.min(posterH, Math.round(posterW / artworkRatio))) : posterH
    property int posterLogoNudgeX: 0
    property int posterLogoNudgeY: 0
    property int bottomScrollPad: 80
    readonly property int avatarSize: 52
    /* ===== Focus ===== */
    readonly property int focusHud: -1
    property int currentFocus: 0
    property int lastFocusBeforeHud: 0
    property bool uiReady: false
    property bool didInitialFocus: false
    property bool isRestoring: true
    function firstContentFocus(){ return overviewVisible ? 0 : 1 }

    // Une nouvelle fiche film démarre sur l'action de lecture, jamais sur le résumé.
    // La sélection exacte Reprendre/Lire depuis le début reste décidée par
    // actionsBlock selon le shouldShow du GlassCircleButtonMovie "resume".
    function initialContentFocus(){ return 1 }

    // v45 — focus hardening Freebox : évite le focus "dans le vide" après disparition du loader.
    property int _focusRepairBudget: 0
    property bool _focusRepairNeedsInit: false
    property string _focusRepairReason: ""
    function _hasActiveContentFocus(){
        try {
            if (currentFocus === focusHud && clockHud && clockHud.activeFocus) return true
            if (currentFocus === 0 && overviewBox && overviewBox.visible && overviewBox.activeFocus) return true
            if (currentFocus === 1 && actionsBlock && actionsBlock.visible && actionsBlock.activeFocus) return true
            if (currentFocus === 2 && posterFocus && posterFocus.visible && posterFocus.activeFocus) return true
            if (currentFocus === 3 && castPageLoader && castPageLoader.item && castPageLoader.item.activeFocus) return true
            if (currentFocus === 4 && similarLoader && similarLoader.item && similarLoader.item.activeFocus) return true
            if (currentFocus === 5 && chaptersLoader && chaptersLoader.item && chaptersLoader.item.activeFocus) return true
        } catch(e) {}
        return false
    }
    function _focusSectionNow(sec, reason){
        if (hardLoading || overlayMode !== "none") return false
        sec = sec|0
        if (sec === focusHud) return focusHudAvatar()
        if (sec === 0) {
            if (!overviewBox || !overviewBox.visible) return false
            currentFocus = 0
            ensureItemVisible(overviewBox, 40)
            overviewBox.forceActiveFocus()
            return true
        }
        if (sec === 1) {
            if (!actionsBlock || !actionsBlock.visible || !actionsArmed) return false
            currentFocus = 1
            ensureItemVisible(actionsBlock, 40)
            actionsBlock.focusSavedOrFirst()
            return true
        }
        if (sec === 2) {
            if (!posterFocus || !posterFocus.visible) return false
            currentFocus = 2
            ensureItemVisible(posterFocus, 20)
            posterFocus.forceActiveFocus()
            return true
        }
        if (sec === 3) {
            if (!hasCast()) return false
            currentFocus = 3
            focusCast()
            return true
        }
        if (sec === 4) {
            if (!hasSimilarContent()) return false
            currentFocus = 4; focusSimilar(); return true
        }
        if (sec === 5) { if (!hasChapters()) return false; currentFocus = 5; focusChapters(); return true }
        return false
    }
    function _queueFocusRepair(reason, budget){
        _focusRepairReason = reason || "unknown"
        _focusRepairBudget = Math.max(_focusRepairBudget, budget || 18)
        if (!focusRepairTimer.running) focusRepairTimer.start()
    }
    function _queueInitFocus(reason){
        if (disposed) return
        _focusRepairReason = reason || "init"
        _focusRepairNeedsInit = true
        _focusRepairBudget = Math.max(_focusRepairBudget, 24)
        if (!focusRepairTimer.running) focusRepairTimer.start()
    }
    function _applyDefaultFocus(){
        var sec = initialContentFocus()
        if (!_focusSectionNow(sec, "default")) {
            didInitialFocus = false
            isRestoring = false
            _queueFocusRepair("defaultFocusFailed", 24)
            return false
        }
        didInitialFocus = true
        isRestoring = false
        requestSaveFocusSnapshot()
        _queueFocusRepair("verifyDefaultFocus", 8)
        return true
    }
    onCurrentFocusChanged: {
        if (currentFocus === 3) _hydrateCastNow()
        if (currentFocus === 4) _expandSimilarIfNeeded()
        requestSaveFocusSnapshot()
        _forceSectionFocus()
        _scheduleClockHudSync()
    }
    /* ===== Gates stricts ===== */
    property bool fetchInFlight: false
    property bool gateMinDelay: false
    property bool gateItemReady: false
    property bool gatePosterReady: false
    property bool gateBGReady: false
    property bool serverResponseSlow: false
    // Une fiche chaude peut rester interactive pendant la révalidation réseau.
    readonly property bool hardLoading: (fetchInFlight && !warmSnapshotVisible) || !gateMinDelay || !gateItemReady || !gatePosterReady || !gateBGReady
    /* ===== Loading étendu semi-strict (hero + premières sections movie) =====
       On garde le CircleDotsLoader jusqu'à ce que le hero soit prêt ET que les blocs
       Cast / Similar soient au moins instanciés ou déclarés vides. Cast/Similar gardent
       leur logique lazy, avec timeout de sécurité pour éviter un écran noir infini. */
    property bool gateCastBlockReady: false
    property bool gateSimilarBlockReady: false
    property bool gateLayoutReady: false
    property bool extendedLoadingTimedOut: false
    readonly property bool extendedLoading: !hardLoading && (!gateCastBlockReady || !gateSimilarBlockReady || !gateLayoutReady)
    // Gate commun de retour vers DetailMoviePage.
    // - Player : refresh Jellyfin forcé pour UserData / « Reprendre ».
    // - PersonPage : pas de requête forcée si la fiche en mémoire est encore valide,
    //   mais le CircleDotsLoader couvre quand même toute reconstruction éventuelle.
    property bool detailReturnRefreshGate: false
    property string _detailReturnScope: ""
    property bool _detailReturnForceRefreshPending: false
    property bool _detailReturnDataRefreshDone: false
    property int _detailReturnReleaseSettleTicks: 0
    // Tant que la première lecture autoritaire n'a pas été obtenue avec UserId,
    // le snapshot chaud ne doit jamais être exposé seul. Il peut être préparé en
    // arrière-plan, mais le curtain reste actif pour éviter le flash "fiche -> loader".
    property bool initialAuthoritativeFetchPending: true
    readonly property bool baseVisualLoading: hardLoading || extendedLoading
    readonly property bool visualLoading: baseVisualLoading || detailReturnRefreshGate || initialAuthoritativeFetchPending
    readonly property bool isLoading: visualLoading
    readonly property bool shellLoading: visualLoading
    readonly property string shellLoadingError: loadingError || ""
    property string loadingError: ""
    property int _fetchToken: 0
    property string _fetchKey: ""
    property var _fetchHandle: null
    property var _warmDetailSnapshot: null
    property bool warmSnapshotVisible: false
    function _cancelItemFetch(){
        ++_fetchToken
        var h = _fetchHandle
        _fetchHandle = null
        fetchInFlight = false
        try { if (h && h.cancel) h.cancel("context_changed") } catch(e) {}
    }
    function _mkFetchKey(){
        var rawKey = [serverUrl, userId, itemId].join("|")
        return "movie#" + SafeLog.shortHash(rawKey) + "|" + (accessToken ? "auth" : "anon")
    }
    function _armDetailReturnRefresh(reason, forceRefresh, scope){
        if (disposed) return false
        detailReturnRefreshGate = true
        _detailReturnScope = String(scope || "")
        _detailReturnForceRefreshPending = (forceRefresh === true)
        _detailReturnDataRefreshDone = false
        _detailReturnReleaseSettleTicks = 0
        // Le vieux focus/actions ne doit jamais redevenir interactif derrière
        // le loader, quel que soit le sous-écran dont on revient.
        try { actionsArmTimer.stop() } catch(e0) {}
        actionsArmed = false
        return true
    }
    function _consumeDetailReturnRefreshMarker(reason){
        try {
            if (!shared || !shared.__redefinDetailReturnRefresh)
                return false
            var marker = shared.__redefinDetailReturnRefresh
            var markerId = String(marker.itemId || "")
            var scope = String(marker.scope || "player").toLowerCase()
            var now = Date.now()
            var ts = Number(marker.ts || 0)
            // Compatibilité avec le marker Player du build précédent :
            // sans scope explicite, il reste considéré comme un retour Player.
            var maxAge = (scope === "person") ? 120000 : 15000
            if (ts > 0 && (now - ts) > maxAge) {
                shared.__redefinDetailReturnRefresh = null
                return false
            }
            if (!itemId || !markerId || markerId !== String(itemId))
                return false
            var forceRefresh = (marker.forceRefresh !== undefined)
                    ? (marker.forceRefresh === true)
                    : (scope !== "person")
            if (scope === "person" && marker.castPersonId) {
                var a=_detailFocusApi(), s=a&&a.get?a.get(_focusKey()):null
                if(a&&a.put){
                    if(!s) s={section:3,t:Date.now(),scrollY:0}
                    s.section=3; s.castIndex=(Number(marker.castIndex||0)|0); s.castPersonId=String(marker.castPersonId)
                    var ry=Number(marker.returnScrollY); if(isFinite(ry)&&ry>=0) s.scrollY=Math.round(ry)
                    a.put(_focusKey(),s)
                }
            }
            shared.__redefinDetailReturnRefresh = null
            return _armDetailReturnRefresh(
                        reason || (scope + "-return-marker"),
                        forceRefresh,
                        scope)
        } catch(e) {
            return false
        }
    }
    function _detailReturnReleaseReady(){
        if (!detailReturnRefreshGate)
            return false
        if (!_detailReturnDataRefreshDone)
            return false
        if (baseVisualLoading)
            return false
        // Les boutons utilisent item.UserData directement. On attend aussi que
        // le bloc Actions ait eu le temps de recalculer shouldShow/navigation.
        if (!actionsArmed) {
            if (!actionsArmTimer.running)
                actionsArmTimer.restart()
            return false
        }
        return true
    }
    function _scheduleDetailReturnRelease(){
        if (!detailReturnRefreshGate)
            return
        if (!detailReturnReleaseTimer.running)
            detailReturnReleaseTimer.start()
    }
    function applyDetailSnapshot(snapshot){
        try {
            if (!MediaCatalog.detailSnapshotCanApply(snapshot, itemId)) return false
            _warmDetailSnapshot = snapshot
            return _useWarmDetailSnapshot()
        } catch(e) {}
        return false
    }
    function _useWarmDetailSnapshot(){
        var snap = _warmDetailSnapshot
        if (!snap || !snap.item || String(snap.itemId || "") !== String(itemId || "")) {
            warmSnapshotVisible = false
            return false
        }
        item = snap.item
        castPeopleAll = (item && item.People) ? item.People : []
        _applyCastWarm()
        similarExpanded = false
        recomputeChips()
        loadingError = ""
        warmSnapshotVisible = true
        minLoadTimer.stop(); gateTimeoutTimer.stop()
        gateMinDelay = gateItemReady = gatePosterReady = gateBGReady = true
        _releaseExtendedGates()
        _syncPosterSources()
        safeRestart(bgUpdateTimer)
        safeCallLater(function(){ _updatePosterGate(); _updateBGGate(); _pokeRestore() })
        return true
    }
    function _resetExtendedGates(){
        gateCastBlockReady = false
        gateSimilarBlockReady = false
        gateLayoutReady = false
        extendedLoadingTimedOut = false
        extendedLoadingTimeout.stop()
        layoutReadyTimer.stop()
    }
    function _releaseExtendedGates(){
        extendedLoadingTimeout.stop()
        layoutReadyTimer.stop()
        gateCastBlockReady = true
        gateSimilarBlockReady = true
        gateLayoutReady = true
        extendedLoadingTimedOut = true
    }
    function _startExtendedLoadingGates(){
        if (hardLoading) return
        _updateExtendedSectionGates()
        layoutReadyTimer.restart()
        extendedLoadingTimeout.restart()
    }
    function _updateExtendedSectionGates(){
        if (hardLoading) return
        if (!hasItem) {
            gateCastBlockReady = true
            gateSimilarBlockReady = true
            return
        }
        try {
            if (!castPeople || castPeople.length === 0) gateCastBlockReady = true
            else if (castPageLoader.status === Loader.Error) gateCastBlockReady = true
            else if (castPageLoader.status === Loader.Ready && castPageLoader.item) gateCastBlockReady = true
        } catch(e1) {}
        try {
            if (similarLoader.status === Loader.Error) gateSimilarBlockReady = true
            else if (heavyStageSimilar && similarLoader.status === Loader.Ready && similarLoader.item) gateSimilarBlockReady = true
        } catch(e2) {}
    }
    function _resetGates(){
        gateMinDelay = gateItemReady = gatePosterReady = gateBGReady = false
        serverResponseSlow = false
        _resetExtendedGates()
        safeRestart(minLoadTimer)
        safeRestart(gateTimeoutTimer)
    }
    function _releaseGatesImmediate(){
        minLoadTimer.stop(); gateTimeoutTimer.stop(); fetchInFlight = false
        serverResponseSlow = false
        gateMinDelay = gateItemReady = gatePosterReady = gateBGReady = true
        _releaseExtendedGates()
    }
    Timer { id: minLoadTimer; interval: 220; repeat: false; onTriggered: gateMinDelay = true }
    Timer {
        id: gateTimeoutTimer
        interval: 1800; repeat: false
        // Le timeout informe l'utilisateur, mais ne libère jamais les gates avant
        // le retour réel de Jellyfin. Cela évite une page partiellement vide/noire.
        onTriggered: { if (fetchInFlight) serverResponseSlow = true }
    }
    Timer { id: layoutReadyTimer; interval: 320; repeat: false; onTriggered: gateLayoutReady = true }
    Timer { id: extendedLoadingTimeout; interval: 2600; repeat: false; onTriggered: _releaseExtendedGates() }
    Timer {
        id: detailReturnReleaseTimer
        interval: 40
        repeat: true
        running: false
        onTriggered: {
            if (disposed || !detailReturnRefreshGate) {
                stop()
                return
            }
            if (!_detailReturnReleaseReady()) {
                _detailReturnReleaseSettleTicks = 0
                return
            }
            // Deux frames/ticks pour laisser GlassCircleButtonMovie recalculer
            // shouldShow à partir du nouveau item.UserData.
            _detailReturnReleaseSettleTicks++
            if (_detailReturnReleaseSettleTicks < 2)
                return
            stop()
            _detailReturnReleaseSettleTicks = 0
            _detailReturnForceRefreshPending = false
            _detailReturnDataRefreshDone = false
            _detailReturnScope = ""
            detailReturnRefreshGate = false
        }
    }
    /* ===== Heavy stagger ===== */
    readonly property bool heavyReady: uiReady && !hardLoading
    property bool heavyStageHero: false
    property bool heavyStageCast: false
    property bool heavyStageSimilar: false
    property int _heavyStage: 0
    Timer {
        id: heavyStageTimer
        interval: 130; repeat: true; running: false
        onTriggered: {
            if (!heavyReady) return
            if (_heavyStage === 0) { heavyStageHero = true; _heavyStage = 1; return }
            if (_heavyStage === 1) { heavyStageCast = true; _heavyStage = 2; return }
            if (_heavyStage === 2) { heavyStageSimilar = true; running = false; return }
        }
    }
    function _resetHeavy(){ heavyStageHero = heavyStageCast = heavyStageSimilar = false; _heavyStage = 0; heavyStageTimer.stop() }
    function _startHeavy(){
        _resetHeavy()
        heavyStageHero = true
        // CastPage est préchauffée immédiatement : ses portraits peuvent commencer
        // à charger pendant que le hero/backdrop termine, au lieu d'arriver après coup.
        heavyStageCast = true
        _heavyStage = 2
        heavyStageTimer.start()
    }
    onHeavyReadyChanged: {
        if (heavyReady) {
            _startHeavy()
            safeCallLater(function(){ _updateExtendedSectionGates() })
        } else _resetHeavy()
    }
    onHeavyStageCastChanged: _updateExtendedSectionGates()
    onHeavyStageSimilarChanged: _updateExtendedSectionGates()
    readonly property bool castReady: castPeople.length > 0 && castPageLoader.status === Loader.Ready && castPageLoader.item
    /* ===== Snapshot / memo ===== */
    property bool memoSaveWindow: false
    property bool _saveQueued: false
    property int _restoreBudget: 0
    function _movieId(){ return itemId || (item && item.Id) || "" }
    function _detailFocusApi(){
        try { return shared && shared.__redefinDetailFocusApi ? shared.__redefinDetailFocusApi : null }
        catch(e) { return null }
    }
    function armMemo(scope){
        var api = _detailFocusApi(), mid = _movieId()
        if (!api || !mid || !api.arm || api.arm(mid, scope) !== true) return
        memoSaveWindow = true
    }
    function _isArmActive(){
        var api = _detailFocusApi(), mid = _movieId()
        return !!(api && mid && api.isArmed && api.isArmed(mid))
    }
    function _activeMemoScope(){
        var api = _detailFocusApi(), mid = _movieId()
        return api && mid && api.activeScope ? String(api.activeScope(mid) || "").toLowerCase() : ""
    }
    function _disarmMemo(){
        var api = _detailFocusApi(), mid = _movieId()
        if (api && mid && api.disarm) api.disarm(mid)
        memoSaveWindow = false
    }
    function _storePersonReturnContext(personObj){
        try {
            if (!shared || !itemId || !personObj || !personObj.Id) return false
            var snap = _getFocusSnapshot()
            var savedY = (snap && typeof snap.scrollY === "number") ? Number(snap.scrollY) : Number(rootFlick ? rootFlick.contentY : 0)
            shared.__redefinPersonReturnContext = ({
                detailItemId: String(itemId), personId: String(personObj.Id),
                castIndex: (castPageLoader.item && castPageLoader.item.currentActorIndex !== undefined) ? (castPageLoader.item.currentActorIndex|0) : 0,
                returnScrollY: isFinite(savedY) ? Math.max(0, savedY) : 0,
                detailKind: "movie", ts: Date.now()
            })
            return true
        } catch(e) { return false }
    }
    function _focusKey(){ return "detailMovie|" + _movieId() }
    signal requestPlay(string itemId, string accessToken, string userId, string serverUrl, string itemTitle)
    // Pool root-level : précharge les portraits Cast même quand CastPage est encore hors écran.
    // Le léger opacity évite certains builds Qt/Freebox qui retardent des Images totalement invisibles.
    Timer {
        id: castPortraitPrewarmDeferredTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (detailMoviePage.disposed || !detailMoviePage.visible) return
            if (detailMoviePage.visualLoading) { restart(); return }
            detailMoviePage._castPortraitPrewarmSecondPhase = true
            detailMoviePage._refreshCastPortraitPrewarm()
        }
    }
    Item {
        id: castPortraitPrewarmPool
        x: -4
        y: -4
        width: 1
        height: 1
        opacity: 0.01
        visible: !detailMoviePage.disposed && detailMoviePage.visible && castPortraitPrewarmEnabled && castPortraitPrewarmPeople && castPortraitPrewarmPeople.length > 0
        z: -10000
        Repeater {
            model: castPortraitPrewarmPeople ? castPortraitPrewarmPeople.length : 0
            delegate: Image {
                width: 1
                height: 1
                visible: true
                asynchronous: true
                cache: index < Math.min(detailMoviePage.castPortraitPrewarmImmediateCount, detailMoviePage.castPortraitPrewarmCount)
                mipmap: false
                smooth: false
                fillMode: Image.PreserveAspectCrop
                source: (!detailMoviePage.disposed && detailMoviePage.visible) ? detailMoviePage.castPortraitUrlForPrewarm(detailMoviePage.castPortraitPrewarmPeople[index]) : ""
                sourceSize.width: detailMoviePage.castPortraitPrewarmW
                sourceSize.height: detailMoviePage.castPortraitPrewarmH
            }
        }
    }
    signal requestNavigation(string page)
    signal requestBackToMenu()
    Timer { id: saveFocusTimer; interval: 0; repeat: false; onTriggered: { _saveQueued = false; _saveFocusSnapshotNow() } }
    function requestSaveFocusSnapshot(){ if (_saveQueued) return; _saveQueued = true; safeRestart(saveFocusTimer) }
    function flushSaveFocusSnapshotNow(){ if (_saveQueued) { saveFocusTimer.stop(); _saveQueued = false }; _saveFocusSnapshotNow() }
    function _saveFocusSnapshotNow(){
        if (isRestoring || !didInitialFocus || !(memoSaveWindow || _isArmActive())) return
        var api = _detailFocusApi(); if (!api || !api.put) return
        var snap = { section: currentFocus, t: Date.now(), scrollY: rootFlick ? (rootFlick.contentY|0) : 0,
                     castExpanded: castExpanded, similarExpanded: similarExpanded }
        if (actionsBlock) snap.actionIndex = actionsBlock.lastActionIndex
        if (castPageLoader.item && castPageLoader.item.lastFocusedIndex !== undefined) {
            snap.castIndex = castPageLoader.item.lastFocusedIndex
            try {
                if (castPageLoader.item.currentActorId)
                    snap.castPersonId = String(castPageLoader.item.currentActorId)
            } catch(eCastId) {}
        }
        if (chaptersLoader.item && chaptersLoader.item.lastFocusedIndex !== undefined) snap.chapterIndex = chaptersLoader.item.lastFocusedIndex
        if (similarLoader.item && similarLoader.item.lastFocusedIndex !== undefined) snap.similarIndex = similarLoader.item.lastFocusedIndex
        api.put(_focusKey(), snap)
    }
    function _getFocusSnapshot(){
        var api = _detailFocusApi()
        return api && api.get ? api.get(_focusKey()) : null
    }

    // Retour terminal DetailMoviePage -> MoviePage : le stockage reste la
    // responsabilité exclusive de l'API DetailFocus installée par ShellPage.
    function _forgetFocusSnapshot(){
        if (_saveQueued) {
            try { saveFocusTimer.stop() } catch(e0) {}
            _saveQueued = false
        }

        try { restoreTimer.stop() } catch(e1) {}
        _restoreBudget = 0
        isRestoring = false

        _disarmMemo()

        var api = _detailFocusApi()
        if (api && api.remove) api.remove(_focusKey())
        memoSaveWindow = false
    }

    function _leaveDetailToMenu(){
        _forgetFocusSnapshot()
        _storeSensitiveNavContext()
        if (typeof requestBackToMenu === "function")
            requestBackToMenu()
    }
    Timer {
        id: restoreTimer
        interval: 16; repeat: true; running: false
        onTriggered: {
            if (_tryRestoreOnce()) { running = false; return }
            if (--_restoreBudget <= 0) {
                isRestoring = false; running = false
                if (!didInitialFocus) {
                    safeCallLater(_applyDefaultFocus)
                    _queueFocusRepair("restoreBudgetExpired", 16)
                }
            }
        }
    }
    Timer {
        id: focusRepairTimer
        interval: 80
        repeat: true
        running: false
        onTriggered: {
            if (disposed) {
                running = false
                _focusRepairNeedsInit = false
                _focusRepairBudget = 0
                return
            }
            if (overlayMode !== "none")
                return
            if (_focusRepairNeedsInit) {
                if (--_focusRepairBudget <= 0) {
                    running = false
                    _focusRepairNeedsInit = false
                    return
                }
                if (!uiReady || hardLoading || !actionsArmed)
                    return
                _focusRepairNeedsInit = false
                setInitialFocus()
                if (didInitialFocus && _hasActiveContentFocus()) {
                    running = false
                    _focusRepairBudget = 0
                }
                return
            }
            if (hardLoading)
                return
            if (_hasActiveContentFocus()) {
                running = false
                _focusRepairBudget = 0
                return
            }
            if (--_focusRepairBudget <= 0) {
                running = false
                return
            }
            didInitialFocus = false
            isRestoring = false
            var snap = _getFocusSnapshot()
            if (snap && _wantSectionAvailable((snap.section|0))) {
                if ((snap.section|0) === 1 && !actionsArmed) return
                _requestRestore(16)
            } else {
                setInitialFocus()
            }
        }
    }
    function _requestRestore(budget){ isRestoring = true; _restoreBudget = budget|0; restoreTimer.start() }
    function _pokeRestore(){
        if (!uiReady || hardLoading) return

        // Un retour Player/Person encore armé doit restaurer son snapshot.
        if (_isArmActive()) {
            _requestRestore(80)
            return
        }

        // Une fois la restauration consommée, ne plus relire le même snapshot
        // à chaque changement de gate/layout. Il reste seulement conservé pour
        // d'éventuelles réparations de focus jusqu'au Back terminal.
        if (didInitialFocus)
            return

        var snap = _getFocusSnapshot()
        if (snap) _requestRestore(40)
        else _applyDefaultFocus()
    }
    function _wantSectionAvailable(sec){ return sec===3 ? hasCast() : sec===4 ? hasSimilarContent() : sec===5 ? hasChapters() : sec===2 ? hasItem : (sec===1 || sec===0 || sec===focusHud) }
    function _tryRestoreOnce(){
        if (!uiReady || hardLoading) return false
        var snap = _getFocusSnapshot()
        if (!snap) { if (_isArmActive()) _disarmMemo(); return _applyDefaultFocus() }
        if (snap.castExpanded === true) { castExpanded = true; castPeople = castPeopleAll }
        if (snap.similarExpanded === true) similarExpanded = true
        var sec = snap.section|0
        if (!_wantSectionAvailable(sec)) return false
        currentFocus = sec
        var focusConfirmed = true
        if (sec === focusHud) focusHudAvatar()
        else if (sec === 0) goUpToResume()
        else if (sec === 1) {
            if (snap.actionIndex !== undefined) actionsBlock.lastActionIndex = snap.actionIndex|0
            ensureItemVisible(actionsBlock, 40); actionsBlock.focusSavedOrFirst()
        } else if (sec === 2) {
            ensureItemVisible(posterFocus, 20); posterFocus.forceActiveFocus()
        } else if (sec === 3) {
            _hydrateCastNow()
            ensureItemVisible(castPageLoader, 40)
            // Comme DetailSeriePage, restaurer d'abord par Id Jellyfin puis par index.
            // Surtout, ne consommer le snapshot qu'une fois le delegate exact réellement
            // actif : CastPage est recyclé/asynchrone et peut publier brièvement l'acteur 0.
            var wantedCastIndex = snap.castIndex !== undefined ? (snap.castIndex|0) : 0
            var wantedPersonId = snap.castPersonId ? String(snap.castPersonId) : ""
            var castIt = castPageLoader.item
            try {
                if (castIt) {
                    castIt.lastFocusedIndex = wantedCastIndex
                    if (castIt.restoreActorFocus)
                        castIt.restoreActorFocus(wantedPersonId, wantedCastIndex)
                    else if (castIt.restoreLastActorFocus)
                        castIt.restoreLastActorFocus()
                }
            } catch(eCastFocus) {}
            try {
                focusConfirmed = castIt && castIt.hasFocusedActor
                        ? castIt.hasFocusedActor(wantedPersonId)
                        : !!(castIt && castIt.activeFocus
                             && castIt.currentActorIndex === wantedCastIndex)
            } catch(eCastCheck) { focusConfirmed = false }
            if (!focusConfirmed)
                return false
        } else if (sec === 4) {
            _expandSimilarIfNeeded(); focusSimilar()
            safeCallLater(function(){
                try {
                    if (similarLoader.item && snap.similarIndex !== undefined) {
                        similarLoader.item.lastFocusedIndex = snap.similarIndex|0
                        if (similarLoader.item.restoreLastCardFocus) similarLoader.item.restoreLastCardFocus()
                    }
                } catch(e){}
            })
        } else if (sec === 5) {
            if (chaptersLoader.item && snap.chapterIndex !== undefined) chaptersLoader.item.lastFocusedIndex = snap.chapterIndex|0
            focusChapters()
        }
        if (typeof snap.scrollY === "number" && rootFlick) {
            var maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height)
            rootFlick.contentY = Math.max(0, Math.min(maxY, snap.scrollY|0))
        }
        didInitialFocus = true; isRestoring = false
        if (_isArmActive()) _disarmMemo()
        requestSaveFocusSnapshot()
        _queueFocusRepair("restoreVerify", 8)
        return true
    }
    /* ===== Init focus ===== */
    property bool actionsArmed: false
    Timer {
        id: actionsArmTimer
        interval: 40
        repeat: false
        onTriggered: {
            actionsArmed = true
            if (uiReady && !hardLoading && overlayMode === "none") {
                if (!didInitialFocus || !_hasActiveContentFocus()) {
                    _queueInitFocus("retry")
                    _queueFocusRepair("actionsArmed", 20)
                }
            }
        }
    }
    function setInitialFocus(){
        if (!uiReady || hardLoading || !actionsArmed) { _queueInitFocus("retry"); return }
        if (didInitialFocus) return
        var snap = _getFocusSnapshot()
        isRestoring = true
        if (_isArmActive() && snap) { _requestRestore(80); return }
        if (snap) { _requestRestore(40); return }
        if (!_focusSectionNow(initialContentFocus(), "initial")) {
            didInitialFocus = false
            isRestoring = false
            _queueFocusRepair("initialFocusFailed", 24)
            return
        }
        didInitialFocus = true
        isRestoring = false
        requestSaveFocusSnapshot()
        _queueFocusRepair("initialVerify", 8)
    }
    /* ===== Scroll / focus helpers ===== */
    property bool scrollAnimEnabled: true
    function ensureItemVisible(target, m){
        if (!target || !target.visible || !rootFlick) return
        var margin = m || 20, p = target.mapToItem(rootFlick.contentItem, 0, 0)
        var top = p.y - margin, bot = p.y + target.height + margin
        var viewTop = rootFlick.contentY, viewBot = rootFlick.contentY + rootFlick.height
        var maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height)
        if (top < viewTop) rootFlick.scrollToY(Math.max(0, top), true)
        else if (bot > viewBot) rootFlick.scrollToY(Math.max(0, Math.min(maxY, bot - rootFlick.height)), true)
    }
    function hasCast(){
        return castPeople.length > 0 && castPageLoader.item && (
            typeof castPageLoader.item.focusFirstActor === "function" ||
            typeof castPageLoader.item.restoreLastActorFocus === "function" ||
            typeof castPageLoader.item.focusLastActor === "function" ||
            typeof castPageLoader.item.forceFirstActorFocus === "function")
    }
    function hasSimilarContent(){ return !!(similarLoader.status === Loader.Ready && similarLoader.item && similarLoader.item.hasContent === true) }
    function hasChapters(){ return !!(chaptersLoader.status === Loader.Ready && chaptersLoader.item && chaptersLoader.item.hasContent === true) }
    function restoreCastFocus(){
        if (!castPageLoader.item) return
        if (castPageLoader.item.restoreLastActorFocus) castPageLoader.item.restoreLastActorFocus()
        else if (castPageLoader.item.focusFirstActor) castPageLoader.item.focusFirstActor()
        else if (castPageLoader.item.forceFirstActorFocus) castPageLoader.item.forceFirstActorFocus()
        else if (castPageLoader.item.focusLastActor) castPageLoader.item.focusLastActor()
    }
    function _restoreSimilarFocusIfAny(){
        if (!similarLoader.item) return
        if (similarLoader.item.restoreLastCardFocus) safeCallLater(function(){ if (similarLoader.item) similarLoader.item.restoreLastCardFocus() })
        else if (similarLoader.item.forceFirstCardFocus) safeCallLater(function(){ if (similarLoader.item) similarLoader.item.forceFirstCardFocus() })
        safeCallLater(function(){ ensureItemVisible(similarBottomProbe, 0) })
    }
    function focusCast(){ _hydrateCastNow(); ensureItemVisible(castPageLoader, 40); restoreCastFocus() }
    function focusChapters(){ ensureItemVisible(chaptersLoader, 30); if (chaptersLoader.item) chaptersLoader.item.restoreLastFocus() }
    function focusSimilar(){ ensureItemVisible(similarLoader, 40); _restoreSimilarFocusIfAny() }
    function focusHudAvatar(){
        if (overlayMode !== "none" || visualLoading || !clockHud || !clockHud.visible || !clockHud.enabled) return false
        if (currentFocus !== focusHud) lastFocusBeforeHud = currentFocus
        currentFocus = focusHud
        if (rootFlick && rootFlick.scrollToTop) rootFlick.scrollToTop(false)
        safeCallLater(function(){ try { if (clockHud && clockHud.focusAvatar) clockHud.focusAvatar() } catch(e) {} })
        requestSaveFocusSnapshot()
        return true
    }
    function restoreFocusFromHud(){
        var sec = (!_wantSectionAvailable(lastFocusBeforeHud) || lastFocusBeforeHud === focusHud) ? firstContentFocus() : lastFocusBeforeHud
        currentFocus = sec
        if (sec === 0) {
            if (overviewBox && overviewBox.visible) { ensureItemVisible(overviewBox, 40); overviewBox.forceActiveFocus() }
            else { currentFocus = 1; if (actionsBlock) actionsBlock.focusSavedOrFirst() }
        } else if (sec === 1) {
            ensureItemVisible(actionsBlock, 40); if (actionsBlock) actionsBlock.focusSavedOrFirst()
        } else if (sec === 2) {
            ensureItemVisible(posterFocus, 20); if (posterFocus) posterFocus.forceActiveFocus()
        } else if (sec === 3) focusCast()
        else if (sec === 4) {
            if (hasSimilarContent()) focusSimilar()
            else if (hasCast()) { currentFocus = 3; focusCast() }
            else if (actionsBlock) { currentFocus = 1; actionsBlock.focusSavedOrFirst() }
        } else _applyDefaultFocus()
        requestSaveFocusSnapshot()
    }
    function goTopBarFocus(){ focusHudAvatar() }
    function goUpToResume(){ if (!hardLoading) { currentFocus = 0; ensureItemVisible(overviewBox, 40); if (overviewBox) overviewBox.forceActiveFocus() } }
    function goUpToActions(){ if (!hardLoading) { currentFocus = 1; ensureItemVisible(actionsBlock, 40); if (actionsBlock) actionsBlock.focusSavedOrFirst() } }
    function goDownPref(){
        if (hardLoading) return
        if (hasCast()) { currentFocus = 3; focusCast(); _forceSectionFocus() }
        else if (hasChapters()) { currentFocus = 5; focusChapters(); _forceSectionFocus() }
        else if (hasSimilarContent()) { currentFocus = 4; focusSimilar(); _forceSectionFocus() }
    }
    function _forceSectionFocus(){
        if (hardLoading) return
        if (currentFocus === 3 && castPageLoader.item) {
            safeCallLater(function(){
                if (disposed || hardLoading) return
                var it = castPageLoader.item
                if (it.forceActiveFocus) it.forceActiveFocus()
                if (it.restoreLastActorFocus) it.restoreLastActorFocus()
                else if (it.focusFirstActor) it.focusFirstActor()
                else if (it.focusLastActor) it.focusLastActor()
                else if (it.forceFirstActorFocus) it.forceFirstActorFocus()
            })
        } else if (currentFocus === 5 && chaptersLoader.item) {
            safeCallLater(function(){ if (!disposed && !hardLoading && chaptersLoader.item) chaptersLoader.item.restoreLastFocus() })
        } else if (currentFocus === 4 && similarLoader.item) {
            safeCallLater(function(){
                if (disposed || hardLoading) return
                var it = similarLoader.item
                if (it.forceActiveFocus) it.forceActiveFocus()
                if (it.restoreLastCardFocus) it.restoreLastCardFocus()
                else if (it.forceFirstCardFocus) it.forceFirstCardFocus()
            })
        } else if (currentFocus === focusHud) {
            safeCallLater(function(){ if (!disposed && !hardLoading && clockHud && clockHud.focusAvatar) clockHud.focusAvatar() })
        }
    }
    /* ===== Chips / perf ===== */
    function recomputeChips(){
        var ms = (item && item.MediaStreams) ? item.MediaStreams : [], res = "", vcodec = "", acodec = "", ch = "", aud = [], subs = []
        for (var i=0; i<ms.length; ++i) {
            var s = ms[i]; if (!s) continue
            if (s.Type === "Video") {
                if (!res && s.Width) {
                    var w = s.Width|0
                    res = (w>=2160) ? "2160p" : (w>=1900) ? "1080p" : (w>=1200) ? "720p" : (w>=700) ? "480p" : (w + "p")
                }
                if (!vcodec && s.Codec) vcodec = ("" + s.Codec).toUpperCase()
            } else if (s.Type === "Audio") {
                if (!acodec && s.Codec) acodec = ("" + s.Codec).toUpperCase()
                if (!ch && s.Channels) ch = ((s.Channels|0) + " ch")
                if (s.Language) {
                    var L = ("" + s.Language).toUpperCase()
                    if (aud.indexOf(L) === -1) aud.push(L)
                }
            } else if (s.Type === "Subtitle") {
                var SL = ("" + (s.Language || "—")).toUpperCase()
                if (subs.indexOf(SL) === -1) subs.push(SL)
            }
        }
        var genres = (item && item.Genres) ? item.Genres : [], gs = []
        for (var g=0; g<genres.length; ++g) if (genres[g] !== undefined && genres[g] !== null && ("" + genres[g]).length) gs.push("" + genres[g])
        genresLine = gs.length ? gs.join(" / ") : ""
        var audio = aud.length > 1 ? ("AUDIO " + aud.join("/")) : "", st = subs.length > 0 ? ("ST " + subs.join("/")) : "", m = []
        if (isMusicVideo) m.push({ t:"CLIP", c:"#2f5b83", px:14 })
        if (item && item.OfficialRating) m.push({ t:""+item.OfficialRating, c:"#1151a3", px:14 })
        if (res)    m.push({ t:res,    c:"#232373", px:14 })
        if (vcodec) m.push({ t:vcodec, c:"#5a45b6", px:14 })
        if (acodec) m.push({ t:acodec, c:"#295393", px:14 })
        if (ch)     m.push({ t:ch,     c:"#223344", px:13 })
        if (audio)  m.push({ t:audio,  c:"#465f9c", px:13 })
        if (st)     m.push({ t:st,     c:"#2f5b83", px:13 })
        chipModel = m
    }
    function _applyViewVirtualization(v){
        if (!v) return
        _setPropSafe(v, "reuseItems", true)
        try {
            var extent = Math.max((v.width|0), (v.height|0)); if (extent <= 0) extent = 720
            _setPropSafe(v, "cacheBuffer", Math.round(extent * 0.7))
        } catch(e) {}
        _setPropSafe(v, "highlightFollowsCurrentItem", true)
    }
    function _applyBlockPerf(block){
        if (!block) return
        _setPropSafe(block, "lowPowerMode", lowPowerMode)
        _setPropSafe(block, "fxOnDemand", lowPowerMode)
        _setPropSafe(block, "fxFocusOnly", lowPowerMode)
        try { if (block.grid) _applyViewVirtualization(block.grid) } catch(e1) {}
        try { if (block.list) _applyViewVirtualization(block.list) } catch(e2) {}
        try { if (block.view) _applyViewVirtualization(block.view) } catch(e3) {}
        try { if (block.cards) _applyViewVirtualization(block.cards) } catch(e4) {}
        try { if (block.gridView) _applyViewVirtualization(block.gridView) } catch(e5) {}
        try { if (block.listView) _applyViewVirtualization(block.listView) } catch(e6) {}
    }
    /* ===== Backdrop / poster ===== */
    readonly property int bgW: 1280
    readonly property int bgH: 720
    property int bgBlur: 8
    property real bgDarken: 0.40
    // URLs image Jellyfin sans token : ne jamais logger Image.source ou URL /Items/... brute.


    function _updateBGGate(){
        if (gateBGReady) return
        var hasSrc = !!(backdrop.lastFull && backdrop.lastFull !== "")
        if (!hasSrc) { gateBGReady = true; return }
        if (backdrop.bgImg && (backdrop.bgImg.status === Image.Ready || backdrop.bgImg.status === Image.Error)) gateBGReady = true
    }
    readonly property int reqPosterW: Math.round(posterW * posterOS)
    readonly property int reqPosterH: Math.round(posterH * posterOS)
    readonly property int reqPosterHqW: Math.round(posterW * posterHqOS)
    readonly property int reqPosterHqH: Math.round(posterH * posterHqOS)
    property string movieLogoUrl: {
        if (!hasItem || isMusicVideo) return ""
        var tag = item.ImageTags && item.ImageTags.Logo ? String(item.ImageTags.Logo) : ""
        return tag ? Jellyfin.itemImageUrl(serverUrl, item.Id, "Logo", tag, {
            maxWidth: 900, maxHeight: 900, quality: 85, format: "png"
        }) : ""
    }
    property string movieCoverUrl: {
        if (!hasItem || !item.ImageTags) return ""
        var tag = item.ImageTags.Primary || (isMusicVideo ? item.ImageTags.Thumb : "")
        var kind = item.ImageTags.Primary ? "Primary" : "Thumb"
        if (!tag) return ""
        var options = { quality: 88, format: "jpg" }
        if (isMusicVideo) { options.maxWidth = reqPosterW; options.maxHeight = reqPosterH }
        else { options.fillWidth = reqPosterW; options.fillHeight = reqPosterH }
        return Jellyfin.itemImageUrl(serverUrl, item.Id, kind, tag, options)
    }
    property string movieCoverHqUrl: {
        if (!hasItem || !item.ImageTags) return ""
        var tag = item.ImageTags.Primary || (isMusicVideo ? item.ImageTags.Thumb : "")
        var kind = item.ImageTags.Primary ? "Primary" : "Thumb"
        if (!tag) return ""
        var options = { quality: posterHqQuality, format: "jpg" }
        if (isMusicVideo) { options.maxWidth = reqPosterHqW; options.maxHeight = reqPosterHqH }
        else { options.fillWidth = reqPosterHqW; options.fillHeight = reqPosterHqH }
        return Jellyfin.itemImageUrl(serverUrl, item.Id, kind, tag, options)
    }
    function _posterCoverVisible(){
        return (!movieLogoUrl || posterLogoFailed || posterLogo.status !== Image.Ready)
    }
    function _schedulePosterHq(){
        posterHqArmed = false
        posterHqTimer.stop()
        if (posterFocus && posterFocus.activeFocus && posterPrimary && posterPrimary.status === Image.Ready
                && _posterCoverVisible() && !flickBusy)
            posterHqTimer.restart()
    }
    function _clearPosterHq(){
        posterHqTimer.stop()
        posterHqArmed = false
    }
    Timer {
        id: posterHqTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (posterFocus && posterFocus.activeFocus && posterPrimary && posterPrimary.status === Image.Ready
                    && detailMoviePage._posterCoverVisible() && !detailMoviePage.flickBusy)
                detailMoviePage.posterHqArmed = true
        }
    }
    readonly property string effectivePosterUrl: (movieLogoUrl && !posterLogoFailed && posterLogo.status !== Image.Error) ? movieLogoUrl : movieCoverUrl
    function _setImageSourceIfChanged(img, url) {
        if (!img) return
        var next = String(url || "")
        if (String(img.source || "") === next) return
        img.source = next
    }
    function _syncPosterSources(){
        var wantLogo = movieLogoUrl && movieLogoUrl !== ""
        if (!wantLogo) {
            posterLogoFailed = false
            _setImageSourceIfChanged(posterLogo, "")
            _setImageSourceIfChanged(posterPrimary, movieCoverUrl || "")
            return
        }
        _setImageSourceIfChanged(posterLogo, movieLogoUrl)
        _setImageSourceIfChanged(posterPrimary, posterLogoFailed ? (movieCoverUrl || "") : "")
    }
    function _updatePosterGate(){
        if (gatePosterReady) return
        var wantLogo = movieLogoUrl && movieLogoUrl !== "", hasCover = movieCoverUrl && movieCoverUrl !== ""
        if (!wantLogo) { gatePosterReady = !hasCover || posterPrimary.status === Image.Ready || posterPrimary.status === Image.Error; return }
        if (posterLogo.status === Image.Ready) { gatePosterReady = true; return }
        if (posterLogo.status === Image.Error)
            gatePosterReady = !hasCover || posterPrimary.status === Image.Ready || posterPrimary.status === Image.Error
    }
    property bool posterFxReady: false
    Timer { id: posterFxTimer; interval: 160; repeat: false; onTriggered: posterFxReady = true }
    onHardLoadingChanged: {
        if (hardLoading) {
            _resetExtendedGates()
            posterFxTimer.stop(); posterFxReady = false
            actionsArmTimer.stop(); actionsArmed = false
        } else {
            posterFxReady = false; safeRestart(posterFxTimer)
            actionsArmed = false
            safeRestart(actionsArmTimer)
            _queueInitFocus("retry")
            _startExtendedLoadingGates()
            safeCallLater(_pokeRestore)
            _queueFocusRepair("hardLoadingReleased", 28)
        }
        _scheduleClockHudSync()
    }
    onVisualLoadingChanged: {
        if (!visualLoading) {
            _updateExtendedSectionGates()
            _queueFocusRepair("visualLoadingReleased", 24)
        }
        if (detailReturnRefreshGate)
            _scheduleDetailReturnRelease()
        _scheduleClockHudSync()
    }
    onBaseVisualLoadingChanged: {
        if (detailReturnRefreshGate)
            _scheduleDetailReturnRelease()
    }
    /* ===== Overlay ===== */
    property string overlayMode: "none"
    property var overlayData: ({})
    property int lastFocusBeforeOverlay: 0
    readonly property int overlayPosterMaxW: Math.round(width * 0.92)
    readonly property int overlayPosterMaxH: Math.round(height * 0.92)
    onOverlayModeChanged: {
        if (rootFlick) rootFlick.interactive = (overlayMode === "none") && !visualLoading
        _scheduleClockHudSync()
    }
    /* ===== Play / nav ===== */
    function requestPlayAt(itemIdArg, accessTokenArg, userIdArg, serverUrlArg, itemTitleArg, startMs, sourceArg) {
        armMemo("player")
        flushSaveFocusSnapshotNow()
        _storeSensitiveNavContext()
        try {
            if (shared && startMs !== undefined && startMs !== null && Number(startMs) >= 0) {
                shared.__redefinExplicitPlaybackStart = ({
                    source: sourceArg && String(sourceArg).length ? String(sourceArg) : "chapter",
                    itemId: String(itemIdArg || ""),
                    serverUrl: String(serverUrlArg || ""),
                    userId: String(userIdArg || ""),
                    startMs: Math.max(0, Math.floor(Number(startMs))),
                    ts: Date.now()
                })
            }
        } catch(e) {}
        requestPlay(itemIdArg, accessTokenArg, userIdArg, serverUrlArg, itemTitleArg)
    }
    function gotoSelectProfile(){
        var srv = (serverUrl || "").trim()
        if (!srv.length) {
            if (typeof requestNavigation === "function")
                requestNavigation("serverpage.qml")
            return
        }
        flushSaveFocusSnapshotNow()
        _storeSensitiveNavContext()
        if (typeof requestNavigation === "function")
            requestNavigation("LoginPage.qml?ctx=1")
    }
    /* ===== Fetch ===== */
    Timer { id: fetchDebounce; interval: 80; repeat: false; onTriggered: fetchItemIfReady() }
    function scheduleFetch(){ _cancelItemFetch(); safeRestart(fetchDebounce) }
    function fetchItemIfReady(){
        if (!ctxOk) {
            _cancelItemFetch()
            initialAuthoritativeFetchPending = false
            warmSnapshotVisible = false
            _warmDetailSnapshot = null
            _resetData(true)
            _releaseGatesImmediate()
            _detailReturnForceRefreshPending = false
            _detailReturnDataRefreshDone = true
            safeRestart(bgUpdateTimer)
            safeCallLater(function(){
                _pokeRestore()
                _scheduleDetailReturnRelease()
            })
            return
        }
        var key = _mkFetchKey()
        if (fetchInFlight && _fetchKey === key) return
        // Seul le retour Player force la révalidation réseau.
        // Un retour PersonPage réutilise la fiche déjà valide si possible.
        var forceDetailRefresh = _detailReturnForceRefreshPending === true
        if (!forceDetailRefresh &&
                !fetchInFlight &&
                _fetchKey === key &&
                item &&
                item.Id === itemId) {
            initialAuthoritativeFetchPending = false
            if (detailReturnRefreshGate) {
                _detailReturnDataRefreshDone = true
                _detailReturnForceRefreshPending = false
                safeCallLater(_scheduleDetailReturnRelease)
            }
            safeCallLater(_pokeRestore)
            return
        }
        _cancelItemFetch()
        _fetchKey = key
        var t = ++_fetchToken
        fetchInFlight = true
        loadingError = ""
        _resetGates()
        _resetData(false)
        _resetOverlay()
        _useWarmDetailSnapshot()
        // IMPORTANT : la fiche DetailMovie doit toujours être user-scoped.
        // Invalider aussi le petit cache per-item juste avant la lecture
        // autoritaire : un aller/retour MoviePage ne doit jamais restaurer
        // un UserData antérieur à la dernière écriture du Player.
        try {
            if (Jellyfin.evictUserItemApiCache)
                Jellyfin.evictUserItemApiCache(itemId)
        } catch(eCache) {}
        _fetchHandle = Jellyfin.fetchUserItem(serverUrl, accessToken, userId, itemId,
            function(res){
                if (t !== _fetchToken || disposed) return
                _fetchHandle = null
                item = res
                warmSnapshotVisible = false
                _warmDetailSnapshot = null
                castPeopleAll = (res && res.People) ? res.People : []
                _applyCastWarm()
                _refreshCastPortraitPrewarm()
                similarExpanded = false
                recomputeChips()
                serverResponseSlow = false
                gateItemReady = true; fetchInFlight = false
                initialAuthoritativeFetchPending = false
                if (detailReturnRefreshGate || _detailReturnForceRefreshPending) {
                    _detailReturnForceRefreshPending = false
                    _detailReturnDataRefreshDone = true
                }
                _syncPosterSources(); _updatePosterGate(); safeRestart(bgUpdateTimer)
                if (castPageLoader.item) wireCastLoader()
                if (similarLoader.item) wireSimilarLoader()
                safeCallLater(function(){
                    _updatePosterGate()
                    _updateBGGate()
                    try { if (actionsBlock) actionsBlock.requestNavRebuild() } catch(eActions) {}
                    _pokeRestore()
                    _scheduleDetailReturnRelease()
                })
            },
            function(){
                if (t !== _fetchToken || disposed) return
                _fetchHandle = null
                serverResponseSlow = false
                if (!warmSnapshotVisible) {
                    _resetData(false)
                    loadingError = "Erreur réseau / API. Back pour sortir."
                } else {
                    // Le snapshot est neutre (sans UserData) : mieux vaut garder
                    // la fiche visible que revenir à un écran vide sur réseau lent.
                    loadingError = ""
                }
                gateItemReady = gatePosterReady = gateBGReady = gateMinDelay = true
                fetchInFlight = false
                initialAuthoritativeFetchPending = false
                if (detailReturnRefreshGate || _detailReturnForceRefreshPending) {
                    _detailReturnForceRefreshPending = false
                    _detailReturnDataRefreshDone = true
                }
                safeRestart(bgUpdateTimer)
                safeCallLater(function(){
                    _pokeRestore()
                    _scheduleDetailReturnRelease()
                })
            }
        )
    }
    onMovieLogoUrlChanged: safeCallLater(function(){ posterLogoFailed = false; _syncPosterSources(); _updatePosterGate() })
    onMovieCoverUrlChanged: { _clearPosterHq(); safeCallLater(function(){ _syncPosterSources(); _updatePosterGate(); if (posterFocus && posterFocus.activeFocus) _schedulePosterHq() }) }
    /* ===== Wiring loaders ===== */
    function wireCastLoader(){
        var it = castPageLoader.item; if (!it) return
        it.people = castExpanded ? castPeopleAll : castPeople
        it.serverUrl = serverUrl; it.accessToken = accessToken; it.userId = userId
        it.userName = userName; it.userImageTag = userImageTag; it.fbx = fbx
        if (it.hasOwnProperty("requestFocusAbove")) it.requestFocusAbove = function(){ goUpToActions() }
        if (it.hasOwnProperty("requestFocusBelow")) it.requestFocusBelow = function(){
            if (hasChapters()) { currentFocus = 5; focusChapters(); _forceSectionFocus() }
            else if (hasSimilarContent()) { currentFocus = 4; focusSimilar(); _forceSectionFocus() }
            else ensureItemVisible(castPageLoader, 20)
        }
        _applyBlockPerf(it)
        safeCallLater(_pokeRestore); safeCallLater(_forceSectionFocus)
    }
    function wireSimilarLoader(){
        var it = similarLoader.item; if (!it) return
        it.item = item; it.serverUrl = serverUrl; it.accessToken = accessToken; it.userId = userId; it.fbx = fbx
        if (it.hasOwnProperty("requestFocusAbove")) it.requestFocusAbove = function(){
            if (hasChapters()) { currentFocus = 5; focusChapters(); _forceSectionFocus() }
            else if (hasCast()) { currentFocus = 3; focusCast(); _forceSectionFocus() }
            else goUpToActions()
        }
        _applyBlockPerf(it); _applySimilarWarm()
        safeCallLater(_pokeRestore); safeCallLater(_forceSectionFocus)
    }
    /* ===== Actions wiring ===== */
    function _isPlayAction(kind){ return kind==="resume" || kind==="restart" || kind==="play" || kind==="start" }
    function _runPlayFromButton(btn, idx, kind){
        if (!btn) return
        try { actionsBlock.lastActionIndex = idx } catch(e) {}
        var action = String(kind || "").toLowerCase()
        if (action === "restart" || action === "play" || action === "start") {
            requestPlayAt(btn.itemId, accessToken, userId, serverUrl, itemTitle, 0, "restart")
            return
        }
        armMemo("player"); flushSaveFocusSnapshotNow(); _storeSensitiveNavContext()
        requestPlay(btn.itemId, accessToken, userId, serverUrl, itemTitle)
    }
    function _wireActionSignals(btn, kind, idx){
        if (!btn) return
        try { if (btn._wired === true) return } catch(e) {}
        try { btn._wired = true } catch(e2) {}
        try {
            btn.triggered.connect(function(action){
                if (_isPlayAction(kind) && _isPlayAction(("" + action).toLowerCase()))
                    _runPlayFromButton(btn, idx, kind)
            })
        } catch(e3) {}
    }
    /* ===== ClockHUD ===== */
    property bool _hudSyncQueued: false
    Timer { id: hudSyncTimer; interval: 60; repeat: false; onTriggered: { _hudSyncQueued = false; _syncClockHudNow() } }
    function _scheduleClockHudSync(){ if (_hudSyncQueued) return; _hudSyncQueued = true; safeRestart(hudSyncTimer) }
    function _syncClockHudNow(){
        if (!clockHud) return
        _setPropSafe(clockHud, "fbx", fbx)
        _setPropSafe(clockHud, "serverUrl", serverUrl)
        _setPropSafe(clockHud, "userId", userId)
        _setPropSafe(clockHud, "userImageTag", userImageTag)
        _setPropSafe(clockHud, "userName", userName)
        _setPropSafe(clockHud, "showAvatar", true)
        _setPropSafe(clockHud, "avatarSize", avatarSize)
        _setPropSafe(clockHud, "avatarFocus", currentFocus === focusHud)
        _setPropSafe(clockHud, "showClock", showClockHud)
        _setPropSafe(clockHud, "showClockHud", showClockHud)
        _setPropSafe(clockHud, "showClockText", showClockHud)
        _setPropSafe(clockHud, "active", !visualLoading && overlayMode === "none")
        _setPropSafe(clockHud, "scrolling", !!(rootFlick && (rootFlick.moving || rootFlick.dragging)))
        _setPropSafe(clockHud, "hudOpacity", 1.0 - Math.min((rootFlick ? rootFlick.contentY : 0) / 80, 1))
    }
    /* ===== Lifecycle ===== */
    Component.onCompleted: {
        initialAuthoritativeFetchPending = true
        _hydrateSensitiveContextFromShared()
        _consumeDetailReturnRefreshMarker("component-completed")
        safeRestart(fetchDebounce)
        safeCallLater(function(){
            uiReady = true
            if (rootFlick) rootFlick.contentY = 0
            _pokeRestore()
            _scheduleClockHudSync()
        })
    }
    Component.onDestruction: {
        disposed = true
        try { detailReturnReleaseTimer.stop() } catch(e0) {}
        _cancelItemFetch()
    }
    function _ctxChanged(){ scheduleFetch(); _scheduleClockHudSync() }
    onVisibleChanged: {
        if (visible) {
            var hydrated = _hydrateSensitiveContextFromShared()
            // Pour une page recréée au retour du Player ou de PersonPage,
            // le marker partagé arme le loader avant sa première frame exploitable.
            _consumeDetailReturnRefreshMarker("visible")
            if (hydrated || (accessToken && userId && serverUrl && itemId)) {
                _ctxChanged()
                _queueFocusRepair("detailmovie-visible", 16)
            }
            if (castPeopleAll && castPeopleAll.length > 0)
                _refreshCastPortraitPrewarm()
        } else {
            // Page conservée en mémoire : lever le rideau PENDANT qu'elle est
            // cachée garantit qu'aucune frame obsolète ne puisse apparaître
            // lorsque ShellPage la remet au premier plan.
            var returnScope = _activeMemoScope()
            if (returnScope === "player")
                _armDetailReturnRefresh("hidden-for-player", true, "player")
            else if (returnScope === "person")
                _armDetailReturnRefresh("hidden-for-person", false, "person")
            _clearCastPortraitPrewarm()
        }
    }
    onSharedChanged: {
        var hydrated = _hydrateSensitiveContextFromShared()
        _consumeDetailReturnRefreshMarker("shared-changed")
        if (hydrated)
            _ctxChanged()
    }
    onAccessTokenChanged: _ctxChanged()
    onUserIdChanged: _ctxChanged()
    onServerUrlChanged: _ctxChanged()
    onItemIdChanged: {
        _consumeDetailReturnRefreshMarker("item-changed")
        try { if (actionsBlock) actionsBlock.lastActionIndex = -1 } catch(eFocusReset) {}
        scheduleFetch()
        posterFxTimer.stop()
        posterFxReady = false
        posterLogoFailed = false
    }
    onUserImageTagChanged: _scheduleClockHudSync()
    onUserNameChanged: _scheduleClockHudSync()
    onShowClockHudChanged: _scheduleClockHudSync()
    onActiveFocusChanged: if (activeFocus && !visualLoading && overlayMode === "none") {
        if (didInitialFocus && !_hasActiveContentFocus()) _queueFocusRepair("pageFocusReturned", 16)
        else if (!didInitialFocus) _queueInitFocus("retry")
    }
    Rectangle { anchors.fill: parent; color: "#000000"; z: -1 }
    /* ============================================================================================
       CONTENT
       ============================================================================================ */
    Item {
        id: contentLayer
        anchors.fill: parent
        z: 1
        opacity: visualLoading ? 0.0 : 1.0
        Behavior on opacity { enabled: !flickBusy; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Loader {
            id: overlayLoader
            anchors.fill: parent
            z: 9999
            active: overlayMode !== "none"
            visible: active
            asynchronous: true
            source: active ? Qt.resolvedUrl("OverlayHub.qml") : ""
            onLoaded: {
                if (!overlayLoader.item) return
                var hub = overlayLoader.item
                hub.host = detailMoviePage
                hub.posterMaxW = overlayPosterMaxW
                hub.posterMaxH = overlayPosterMaxH
                try {
                    if (hub.requestClose) hub.requestClose.connect(closeOverlay)
                    if (hub.closed) hub.closed.connect(closeOverlay)
                } catch(e) {}
                safeCallLater(function(){
                    if (overlayLoader.item && overlayMode !== "none") overlayLoader.item.forceActiveFocus()
                })
            }
        }
        Item {
            id: staticScene
            anchors.fill: parent
            z: 1
            layer.enabled: enableSceneFreeze && lowPowerMode && !visualLoading && overlayMode === "none" && !(rootFlick && (rootFlick.moving || rootFlick.dragging))
            layer.smooth: false
            layer.mipmap: false
            Item {
                id: backdrop
                anchors.fill: parent
                z: 0
                property string lastFull: ""
                property string loadingFull: ""
                property int _token: 0
                property alias bgImg: bgImg
                Image {
                    id: bgImg
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                    mipmap: false
                    smooth: false
                    opacity: 0.0
                    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    property int loadToken: 0
                    onStatusChanged: {
                        if (loadToken !== backdrop._token) return
                        if (status === Image.Ready) { backdrop.lastFull = String(source || ""); backdrop.loadingFull = ""; opacity = 0.90; gateBGReady = true }
                        else if (status === Image.Error) { backdrop.loadingFull = ""; opacity = 0.0; gateBGReady = true }
                    }
                }
                Rectangle {
                    anchors.fill: bgImg
                    z: bgImg.z + 1
                    color: "#000000"
                    opacity: bgDarken
                    visible: (bgImg.source && ("" + bgImg.source).length > 0) && bgDarken > 0.001
                }
                function computeFullUrl(){
                    return item ? Jellyfin.itemBackdropOrPrimaryUrl(serverUrl, item, {
                        fillWidth: Math.round(bgW), fillHeight: Math.round(bgH),
                        quality: 80, blur: MediaCatalog.clampBlur(bgBlur), format: "jpg"
                    }) : ""
                }
                function updateBackdropNow(){
                    if (!item) {
                        lastFull = ""
                        loadingFull = ""
                        if (String(bgImg.source || "") !== "") bgImg.source = ""
                        bgImg.opacity = 0.0
                        gateBGReady = true
                        return
                    }
                    var ful = computeFullUrl()
                    if (ful === lastFull || ful === loadingFull) { _updateBGGate(); return }
                    loadingFull = ful; _token += 1; bgImg.loadToken = _token
                    gateBGReady = false
                    if (String(bgImg.source || "") !== String(ful || "")) bgImg.source = ful
                    _updateBGGate()
                }
            }
            Flickable {
                id: rootFlick
                anchors.fill: parent
                clip: true
                z: 1
                interactive: overlayMode === "none" && !visualLoading
                contentWidth: width
                contentHeight: pageColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                property bool progScroll: false
                function _maxY(){ return Math.max(0, contentHeight - height) }
                function _clampY(y){
                    var maxY = _maxY(), v = Number(y || 0)
                    if (v < 0) v = 0
                    if (v > maxY) v = maxY
                    return v
                }
                function scrollToY(y, smooth){
                    var ty = _clampY(y)
                    if (!smooth) { scrollAnimEnabled = false; contentY = ty; safeCallLater(function(){ scrollAnimEnabled = true }); return }
                    if (dragging) { contentY = ty; return }
                    try { if (cancelFlick) cancelFlick() } catch(e) {}
                    progScroll = true; contentYAnim.stop()
                    var dist = Math.abs(Number(contentY) - Number(ty))
                    contentYAnim.duration = Math.round(Math.max(180, Math.min(520, 140 + dist * 0.14)))
                    contentYAnim.to = ty; contentYAnim.restart()
                }
                function scrollToTop(jump){ scrollToY(0, !jump) }
                NumberAnimation {
                    id: contentYAnim
                    target: rootFlick
                    property: "contentY"
                    easing.type: Easing.OutCubic
                    duration: 240
                    onRunningChanged: if (!running) rootFlick.progScroll = false
                }
                Behavior on contentY {
                    enabled: scrollAnimEnabled && !isRestoring && !visualLoading && !rootFlick.dragging && (!rootFlick.moving || rootFlick.progScroll) && !contentYAnim.running
                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                }
                onContentYChanged: _scheduleClockHudSync()
                onMovingChanged: _scheduleClockHudSync()
                onDraggingChanged: _scheduleClockHudSync()
                Column {
                    id: pageColumn
                    width: rootFlick.width
                    spacing: sectionsSpacing
                    anchors.top: parent.top
                    anchors.topMargin: contentTopGap
                    Item { width: 1; height: titleTopExtra }
                    Column {
                        id: headerBlock
                        x: marginL + titleLeftOffset
                        width: Math.max(60, parent.width - x - marginR)
                        spacing: 6
                        transform: [ Translate { y: headerTopNudgeY } ]
                        FontMetrics { id: titleMetrics; font.pixelSize: titleFontPx; font.bold: true }
                        readonly property bool titleShouldMarquee: (itemTitle && itemTitle.length > titleCharLimit)
                        Item {
                            id: titleLineBox
                            width: headerBlock.titleShouldMarquee ? Math.min(headerBlock.width, MediaCatalog.titleTextCapPx(titleMetrics.averageCharacterWidth, titleCharLimit)) : headerBlock.width
                            height: Math.max(36, titleTextItem.implicitHeight + 2)
                            clip: false
                            visible: hasItem
                            readonly property bool allowMarquee: detailMoviePage.visible
                                                                 && !visualLoading
                                                                 && (overlayMode === "none")
                                                                 && !flickBusy
                                                                 && hasItem
                                                                 && visible
                            readonly property bool marqueeNeeded: titleTextItem.paintedWidth > titleLineBox.width
                            readonly property real marqueeOverflow: Math.max(0, titleTextItem.paintedWidth - titleLineBox.width)
                            readonly property int  marqueeGap: 44
                            readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, titleTextItem.paintedWidth + marqueeGap) : 0
                            readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                            readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round(marqueeTravel * 24))) : 0
                            readonly property int  marqueeFadeW: Math.min(58, Math.max(28, Math.round(width * 0.12)))
                            property bool marqueeMoving: false
                            readonly property bool maskActive: marqueeNeeded && allowMarquee && marqueeMoving && visible && width > 0 && height > 0 && !visualLoading && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                            readonly property bool leftFadeActive: maskActive && (titleTextItem.x < -2)
                            readonly property bool rightFadeActive: maskActive && (titleTextItem.x > -marqueeOverflow + 2)
                            onAllowMarqueeChanged: updateMarquee()
                            onWidthChanged: updateMarquee()
                            onVisibleChanged: updateMarquee()
                            onMarqueeNeededChanged: updateMarquee()
                            Connections {
                                target: detailMoviePage
                                function onItemTitleChanged() { titleLineBox.updateMarquee() }
                                function onCurrentFocusChanged() { titleLineBox.updateMarquee() }
                            }
                            Item {
                                id: titleLineSource
                                anchors.fill: parent
                                clip: true
                                visible: !titleLineBox.maskActive
                                Text { textFormat: Text.PlainText;
                                    id: titleTextItem
                                    x: 0
                                    y: Math.round((titleLineSource.height - height) / 2)
                                    text: itemTitle || ""
                                    font.pixelSize: titleFontPx
                                    font.bold: true
                                    color: "#FFFFFF"
                                    wrapMode: Text.NoWrap
                                    elide: titleLineBox.allowMarquee ? Text.ElideNone : Text.ElideRight
                                    onTextChanged: titleLineBox.updateMarquee()
                                    onPaintedWidthChanged: titleLineBox.updateMarquee()
                                }
                            }
                            OpacityMask {
                                id: titleMaskedLine
                                anchors.fill: parent
                                visible: titleLineBox.maskActive
                                enabled: titleLineBox.maskActive
                                source: titleLineSource
                                maskSource: titleFadeMask
                                cached: false
                            }
                            Item {
                                id: titleFadeMask
                                visible: titleLineBox.maskActive
                                x: -10000
                                y: -10000
                                width: titleLineBox.width
                                height: titleLineBox.height
                                readonly property int leftW: titleLineBox.leftFadeActive ? titleLineBox.marqueeFadeW : 0
                                readonly property int rightW: titleLineBox.rightFadeActive ? titleLineBox.marqueeFadeW : 0
                                Rectangle {
                                    visible: titleFadeMask.leftW > 0
                                    x: 0
                                    y: 0
                                    width: titleFadeMask.leftW
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#00FFFFFF" }
                                        GradientStop { position: 1.0; color: "#FFFFFFFF" }
                                    }
                                }
                                Rectangle {
                                    x: titleFadeMask.leftW
                                    y: 0
                                    width: Math.max(0, parent.width - titleFadeMask.leftW - titleFadeMask.rightW)
                                    height: parent.height
                                    color: "#FFFFFFFF"
                                }
                                Rectangle {
                                    visible: titleFadeMask.rightW > 0
                                    x: parent.width - titleFadeMask.rightW
                                    y: 0
                                    width: titleFadeMask.rightW
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                        GradientStop { position: 1.0; color: "#00FFFFFF" }
                                    }
                                }
                            }
                            SequentialAnimation {
                                id: titleMarquee
                                running: false
                                loops: Animation.Infinite
                                ScriptAction { script: { titleLineBox.marqueeMoving = false; titleTextItem.x = 0; titleTextItem.opacity = 1.0 } }
                                PauseAnimation { duration: titleMarqueePauseStartMs }
                                ScriptAction { script: { titleLineBox.marqueeMoving = true } }
                                NumberAnimation {
                                    target: titleTextItem
                                    property: "x"
                                    from: 0
                                    to: titleLineBox.marqueeExitX
                                    duration: titleLineBox.marqueeScrollMs
                                    easing.type: Easing.Linear
                                }
                                ScriptAction { script: { titleLineBox.marqueeMoving = false } }
                                PauseAnimation { duration: 180 }
                                ScriptAction { script: { titleTextItem.x = 0; titleTextItem.opacity = 1.0; titleLineBox.marqueeMoving = false } }
                                PauseAnimation { duration: titleMarqueePauseEndMs }
                                onRunningChanged: {
                                    if (!running) {
                                        titleLineBox.marqueeMoving = false
                                        titleTextItem.x = 0
                                        titleTextItem.opacity = 1.0
                                    }
                                }
                            }
                            function updateMarquee() {
                                titleMarquee.stop()
                                titleLineBox.marqueeMoving = false
                                titleTextItem.x = 0
                                titleTextItem.opacity = 1.0
                                if (titleLineBox.marqueeNeeded && titleLineBox.allowMarquee && titleLineBox.marqueeScrollMs > 0) {
                                    Qt.callLater(function(){
                                        if (titleLineBox.marqueeNeeded && titleLineBox.allowMarquee && titleLineBox.visible && titleLineBox.marqueeScrollMs > 0)
                                            titleMarquee.start()
                                    })
                                }
                            }
                        }
                        Text { textFormat: Text.PlainText;
                            visible: isMusicVideo && text.length > 0
                            text: artistsLine
                            color: "#D7DCF2"; font.pixelSize: 20; font.bold: true
                            width: headerBlock.width; elide: Text.ElideRight; wrapMode: Text.NoWrap
                        }
                        Item {
                            id: metaLine
                            width: headerBlock.width
                            height: Math.max(28, Math.max(ratingWrap.height, dateText.implicitHeight))
                            visible: hasItem
                            Item {
                                id: ratingWrap
                                visible: hasItem && typeof item.CommunityRating !== "undefined"
                                width: ratingText2.paintedWidth + 26
                                height: Math.max(22, ratingText2.paintedHeight)
                                anchors.verticalCenter: parent.verticalCenter
                                Row {
                                    spacing: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text { textFormat: Text.PlainText; text:"★"; color:"#FFC53F"; font.pixelSize:20; verticalAlignment: Text.AlignVCenter }
                                    Text { textFormat: Text.PlainText;
                                        id: ratingText2
                                        text: (hasItem && typeof item.CommunityRating !== "undefined") ? Number(item.CommunityRating || 0).toFixed(1) : ""
                                        color: "#FFFFFF"; font.pixelSize: 20; font.bold: true; verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                            Text { textFormat: Text.PlainText;
                                id: dateText
                                text: (hasItem && item.PremiereDate) ? SeasonUtils.fmtDateLong(item.PremiereDate) : ""
                                visible: text.length > 0
                                color: "#E6FFFFFF"; font.pixelSize: 20; font.bold: true
                                anchors.verticalCenter: parent.verticalCenter
                                x: ratingWrap.visible ? (ratingWrap.width + 14) : 0
                            }
                            Item {
                                id: techChipsClip
                                anchors.verticalCenter: parent.verticalCenter
                                height: 28
                                clip: false
                                visible: hasItem && chipModel && chipModel.length > 0
                                x: {
                                    var xx = 0
                                    if (ratingWrap.visible) xx += ratingWrap.width + 14
                                    if (dateText.visible) xx += dateText.implicitWidth + 14
                                    return xx
                                }
                                width: Math.max(0, metaLine.width - x)
                                readonly property bool allowMarquee: detailMoviePage.visible
                                                                     && !visualLoading
                                                                     && (overlayMode === "none")
                                                                     && !flickBusy
                                                                     && visible
                                                                     && chipModel
                                                                     && chipModel.length > 0
                                readonly property real contentW: Math.max(techChipRow.implicitWidth || 0, techChipRow.childrenRect.width || 0)
                                readonly property bool marqueeNeeded: contentW > (width + 6)
                                readonly property real marqueeOverflow: Math.max(0, contentW - width)
                                readonly property int  marqueeGap: 44
                                readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, contentW + marqueeGap) : 0
                                readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                                readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round(marqueeTravel * 24))) : 0
                                readonly property int  marqueeFadeW: Math.min(46, Math.max(24, Math.round(width * 0.14)))
                                property bool marqueeMoving: false
                            readonly property bool maskActive: marqueeNeeded && allowMarquee && marqueeMoving && visible && width > 0 && height > 0 && !visualLoading && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                readonly property bool leftFadeActive: maskActive && (techChipRow.x < -2)
                                readonly property bool rightFadeActive: maskActive && (techChipRow.x > -marqueeOverflow + 2)
                                onAllowMarqueeChanged: updateMarquee()
                                onWidthChanged: updateMarquee()
                                onVisibleChanged: updateMarquee()
                                onMarqueeNeededChanged: updateMarquee()
                                onContentWChanged: updateMarquee()
                                Connections {
                                    target: detailMoviePage
                                    function onChipModelChanged() { techChipsClip.updateMarquee() }
                                    function onCurrentFocusChanged() { techChipsClip.updateMarquee() }
                                }
                                Item {
                                    id: techChipSource
                                    anchors.fill: parent
                                    clip: true
                                    visible: !techChipsClip.maskActive
                                    Row {
                                        id: techChipRow
                                        x: 0
                                        spacing: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        onChildrenRectChanged: techChipsClip.updateMarquee()
                                        onImplicitWidthChanged: techChipsClip.updateMarquee()
                                        Repeater {
                                            model: chipModel ? chipModel.length : 0
                                            delegate: Rectangle {
                                                radius: 8
                                                height: 28
                                                color: chipModel[index].c
                                                width: chipText.paintedWidth + 16
                                                antialiasing: false
                                                Text { textFormat: Text.PlainText;
                                                    id: chipText
                                                    anchors.centerIn: parent
                                                    text: chipModel[index].t
                                                    color: "#FFFFFF"
                                                    font.pixelSize: chipModel[index].px
                                                    font.bold: true
                                                }
                                            }
                                        }
                                    }
                                }
                                OpacityMask {
                                    id: techChipMaskedLine
                                    anchors.fill: parent
                                    visible: techChipsClip.maskActive
                                    enabled: techChipsClip.maskActive
                                    source: techChipSource
                                    maskSource: techChipFadeMask
                                    cached: false
                                }
                                Item {
                                    id: techChipFadeMask
                                    visible: techChipsClip.maskActive
                                    x: -10000
                                    y: -10000
                                    width: techChipsClip.width
                                    height: techChipsClip.height
                                    readonly property int leftW: techChipsClip.leftFadeActive ? techChipsClip.marqueeFadeW : 0
                                    readonly property int rightW: techChipsClip.rightFadeActive ? techChipsClip.marqueeFadeW : 0
                                    Rectangle {
                                        visible: techChipFadeMask.leftW > 0
                                        x: 0
                                        y: 0
                                        width: techChipFadeMask.leftW
                                        height: parent.height
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: "#00FFFFFF" }
                                            GradientStop { position: 1.0; color: "#FFFFFFFF" }
                                        }
                                    }
                                    Rectangle {
                                        x: techChipFadeMask.leftW
                                        y: 0
                                        width: Math.max(0, parent.width - techChipFadeMask.leftW - techChipFadeMask.rightW)
                                        height: parent.height
                                        color: "#FFFFFFFF"
                                    }
                                    Rectangle {
                                        visible: techChipFadeMask.rightW > 0
                                        x: parent.width - techChipFadeMask.rightW
                                        y: 0
                                        width: techChipFadeMask.rightW
                                        height: parent.height
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                            GradientStop { position: 1.0; color: "#00FFFFFF" }
                                        }
                                    }
                                }
                                SequentialAnimation {
                                    id: techChipMarquee
                                    running: false
                                    loops: Animation.Infinite
                                    ScriptAction { script: { techChipsClip.marqueeMoving = false; techChipRow.x = 0; techChipRow.opacity = 1.0 } }
                                    PauseAnimation { duration: tagsMarqueePauseStartMs }
                                    ScriptAction { script: { techChipsClip.marqueeMoving = true } }
                                    NumberAnimation {
                                        target: techChipRow
                                        property: "x"
                                        from: 0
                                        to: techChipsClip.marqueeExitX
                                        duration: techChipsClip.marqueeScrollMs
                                        easing.type: Easing.Linear
                                    }
                                    ScriptAction { script: { techChipsClip.marqueeMoving = false } }
                                    PauseAnimation { duration: 180 }
                                    ScriptAction { script: { techChipRow.x = 0; techChipRow.opacity = 1.0; techChipsClip.marqueeMoving = false } }
                                    PauseAnimation { duration: tagsMarqueePauseEndMs }
                                    onRunningChanged: {
                                        if (!running) {
                                            techChipsClip.marqueeMoving = false
                                            techChipRow.x = 0
                                            techChipRow.opacity = 1.0
                                        }
                                    }
                                }
                                function updateMarquee() {
                                    techChipMarquee.stop()
                                    techChipsClip.marqueeMoving = false
                                    techChipRow.x = 0
                                    techChipRow.opacity = 1.0
                                    if (techChipsClip.marqueeNeeded && techChipsClip.allowMarquee && techChipsClip.marqueeScrollMs > 0) {
                                        Qt.callLater(function(){
                                            if (techChipsClip.marqueeNeeded && techChipsClip.allowMarquee && techChipsClip.visible && techChipsClip.marqueeScrollMs > 0)
                                                techChipMarquee.start()
                                        })
                                    }
                                }
                            }
                        }
                        Item {
                            id: genresLineBox
                            width: headerBlock.width
                            height: Math.max(22, genresTextItem.implicitHeight + 2)
                            clip: false
                            visible: hasItem && genresLine && genresLine.length > 0
                            readonly property bool allowMarquee: detailMoviePage.visible
                                                                 && !visualLoading
                                                                 && (overlayMode === "none")
                                                                 && !flickBusy
                                                                 && visible
                            readonly property bool marqueeNeeded: genresTextItem.paintedWidth > genresLineBox.width
                            readonly property real marqueeOverflow: Math.max(0, genresTextItem.paintedWidth - genresLineBox.width)
                            readonly property int  marqueeGap: 44
                            readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, genresTextItem.paintedWidth + marqueeGap) : 0
                            readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                            readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round(marqueeTravel * 24))) : 0
                            readonly property int  marqueeFadeW: Math.min(46, Math.max(24, Math.round(width * 0.12)))
                            property bool marqueeMoving: false
                            readonly property bool maskActive: marqueeNeeded && allowMarquee && marqueeMoving && visible && width > 0 && height > 0 && !visualLoading && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                            readonly property bool leftFadeActive: maskActive && (genresTextItem.x < -2)
                            readonly property bool rightFadeActive: maskActive && (genresTextItem.x > -marqueeOverflow + 2)
                            onAllowMarqueeChanged: updateMarquee()
                            onWidthChanged: updateMarquee()
                            onVisibleChanged: updateMarquee()
                            onMarqueeNeededChanged: updateMarquee()
                            Connections {
                                target: detailMoviePage
                                function onGenresLineChanged() { genresLineBox.updateMarquee() }
                                function onCurrentFocusChanged() { genresLineBox.updateMarquee() }
                            }
                            Item {
                                id: genresLineSource
                                anchors.fill: parent
                                clip: true
                                visible: !genresLineBox.maskActive
                                Text { textFormat: Text.PlainText;
                                    id: genresTextItem
                                    x: 0
                                    y: Math.round((genresLineSource.height - height) / 2)
                                    text: genresLine || ""
                                    color: "#DDE1F6"
                                    font.pixelSize: 18
                                    wrapMode: Text.NoWrap
                                    elide: genresLineBox.allowMarquee ? Text.ElideNone : Text.ElideRight
                                    onTextChanged: genresLineBox.updateMarquee()
                                    onPaintedWidthChanged: genresLineBox.updateMarquee()
                                }
                            }
                            OpacityMask {
                                id: genresMaskedLine
                                anchors.fill: parent
                                visible: genresLineBox.maskActive
                                enabled: genresLineBox.maskActive
                                source: genresLineSource
                                maskSource: genresFadeMask
                                cached: false
                            }
                            Item {
                                id: genresFadeMask
                                visible: genresLineBox.maskActive
                                x: -10000
                                y: -10000
                                width: genresLineBox.width
                                height: genresLineBox.height
                                readonly property int leftW: genresLineBox.leftFadeActive ? genresLineBox.marqueeFadeW : 0
                                readonly property int rightW: genresLineBox.rightFadeActive ? genresLineBox.marqueeFadeW : 0
                                Rectangle {
                                    visible: genresFadeMask.leftW > 0
                                    x: 0
                                    y: 0
                                    width: genresFadeMask.leftW
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#00FFFFFF" }
                                        GradientStop { position: 1.0; color: "#FFFFFFFF" }
                                    }
                                }
                                Rectangle {
                                    x: genresFadeMask.leftW
                                    y: 0
                                    width: Math.max(0, parent.width - genresFadeMask.leftW - genresFadeMask.rightW)
                                    height: parent.height
                                    color: "#FFFFFFFF"
                                }
                                Rectangle {
                                    visible: genresFadeMask.rightW > 0
                                    x: parent.width - genresFadeMask.rightW
                                    y: 0
                                    width: genresFadeMask.rightW
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                        GradientStop { position: 1.0; color: "#00FFFFFF" }
                                    }
                                }
                            }
                            SequentialAnimation {
                                id: genresMarquee
                                running: false
                                loops: Animation.Infinite
                                ScriptAction { script: { genresLineBox.marqueeMoving = false; genresTextItem.x = 0; genresTextItem.opacity = 1.0 } }
                                PauseAnimation { duration: tagsMarqueePauseStartMs }
                                ScriptAction { script: { genresLineBox.marqueeMoving = true } }
                                NumberAnimation {
                                    target: genresTextItem
                                    property: "x"
                                    from: 0
                                    to: genresLineBox.marqueeExitX
                                    duration: genresLineBox.marqueeScrollMs
                                    easing.type: Easing.Linear
                                }
                                ScriptAction { script: { genresLineBox.marqueeMoving = false } }
                                PauseAnimation { duration: 180 }
                                ScriptAction { script: { genresTextItem.x = 0; genresTextItem.opacity = 1.0; genresLineBox.marqueeMoving = false } }
                                PauseAnimation { duration: tagsMarqueePauseEndMs }
                                onRunningChanged: {
                                    if (!running) {
                                        genresLineBox.marqueeMoving = false
                                        genresTextItem.x = 0
                                        genresTextItem.opacity = 1.0
                                    }
                                }
                            }
                            function updateMarquee() {
                                genresMarquee.stop()
                                genresLineBox.marqueeMoving = false
                                genresTextItem.x = 0
                                genresTextItem.opacity = 1.0
                                if (genresLineBox.marqueeNeeded && genresLineBox.allowMarquee && genresLineBox.marqueeScrollMs > 0) {
                                    Qt.callLater(function(){
                                        if (genresLineBox.marqueeNeeded && genresLineBox.allowMarquee && genresLineBox.visible && genresLineBox.marqueeScrollMs > 0)
                                            genresMarquee.start()
                                    })
                                }
                            }
                        }
                    }
                    Item {
                        id: rowBlock
                        width: parent.width
                        height: safeRowHeight()
                        Column {
                            id: infoCol
                            width: infoW
                            x: infoLeft + infoNudgeX
                            y: infoTopExtra
                            spacing: infoRowGap
                            visible: hasItem
                            Item {
                                id: infoTextClip
                                width: infoW
                                clip: true
                                height: infoTextCol.implicitHeight
                                implicitHeight: infoTextCol.implicitHeight
                                Column {
                                    id: infoTextCol
                                    width: parent.width
                                    spacing: infoRowGap
                                    Column {
                                        spacing: 6
                                        visible: hasItem && directorsLine.length > 0
                                        Text { textFormat: Text.PlainText;
                                            width: infoTextClip.width
                                            text: "RÉALISÉ PAR"
                                            color: "#FFFFFF"; font.pixelSize: 16; font.bold: true
                                            horizontalAlignment: Text.AlignRight
                                            wrapMode: Text.NoWrap; elide: Text.ElideRight
                                        }
                                        Item {
                                            id: directorLineBox
                                            width: infoTextClip.width
                                            height: Math.max(18, directorsText.implicitHeight + 2)
                                            clip: false
                                            readonly property bool allowMarquee: detailMoviePage.visible
                                                                                 && !visualLoading
                                                                                 && (overlayMode === "none")
                                                                                 && !flickBusy
                                                                                 && visible
                                                                                 && directorsLine.length > 0
                                            readonly property bool marqueeNeeded: directorsText.paintedWidth > directorLineBox.width
                                            readonly property real marqueeOverflow: Math.max(0, directorsText.paintedWidth - directorLineBox.width)
                                            readonly property int  marqueeGap: 44
                                            readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, directorsText.paintedWidth + marqueeGap) : 0
                                            readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                                            readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round((marqueeTravel / directorMarqueeSpeedPxPerSec) * 1000))) : 0
                                            readonly property int  marqueeFadeW: Math.min(38, Math.max(20, Math.round(width * 0.18)))
                                            property bool marqueeMoving: false
                            readonly property bool maskActive: marqueeNeeded && allowMarquee && marqueeMoving && visible && width > 0 && height > 0 && !visualLoading && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                            readonly property bool leftFadeActive: maskActive && (directorsText.x < -2)
                                            readonly property bool rightFadeActive: maskActive && (directorsText.x > -marqueeOverflow + 2)
                                            onAllowMarqueeChanged: updateMarquee()
                                            onWidthChanged: updateMarquee()
                                            onVisibleChanged: updateMarquee()
                                            onMarqueeNeededChanged: updateMarquee()
                                            Connections {
                                                target: detailMoviePage
                                                function onDirectorsLineChanged() { directorLineBox.updateMarquee() }
                                                function onCurrentFocusChanged() { directorLineBox.updateMarquee() }
                                            }
                                            Item {
                                                id: directorLineSource
                                                anchors.fill: parent
                                                clip: true
                                                visible: !directorLineBox.maskActive
                                                Text { textFormat: Text.PlainText;
                                                    id: directorsText
                                                    x: directorLineBox.maskActive ? 0 : Math.max(0, directorLineBox.width - paintedWidth)
                                                    y: Math.round((directorLineSource.height - height) / 2)
                                                    text: directorsLine
                                                    color: infoValueColor
                                                    font.pixelSize: 15
                                                    wrapMode: Text.NoWrap
                                                    elide: directorLineBox.allowMarquee ? Text.ElideNone : Text.ElideRight
                                                    horizontalAlignment: Text.AlignLeft
                                                    onTextChanged: directorLineBox.updateMarquee()
                                                    onPaintedWidthChanged: directorLineBox.updateMarquee()
                                                }
                                            }
                                            OpacityMask {
                                                id: directorMaskedLine
                                                anchors.fill: parent
                                                visible: directorLineBox.maskActive
                                                enabled: directorLineBox.maskActive
                                                source: directorLineSource
                                                maskSource: directorFadeMask
                                                cached: false
                                            }
                                            Item {
                                                id: directorFadeMask
                                                visible: directorLineBox.maskActive
                                                x: -10000
                                                y: -10000
                                                width: directorLineBox.width
                                                height: directorLineBox.height
                                                readonly property int leftW: directorLineBox.leftFadeActive ? directorLineBox.marqueeFadeW : 0
                                                readonly property int rightW: directorLineBox.rightFadeActive ? directorLineBox.marqueeFadeW : 0
                                                Rectangle {
                                                    visible: directorFadeMask.leftW > 0
                                                    x: 0
                                                    y: 0
                                                    width: directorFadeMask.leftW
                                                    height: parent.height
                                                    gradient: Gradient {
                                                        orientation: Gradient.Horizontal
                                                        GradientStop { position: 0.0; color: "#00FFFFFF" }
                                                        GradientStop { position: 1.0; color: "#FFFFFFFF" }
                                                    }
                                                }
                                                Rectangle {
                                                    x: directorFadeMask.leftW
                                                    y: 0
                                                    width: Math.max(0, parent.width - directorFadeMask.leftW - directorFadeMask.rightW)
                                                    height: parent.height
                                                    color: "#FFFFFFFF"
                                                }
                                                Rectangle {
                                                    visible: directorFadeMask.rightW > 0
                                                    x: parent.width - directorFadeMask.rightW
                                                    y: 0
                                                    width: directorFadeMask.rightW
                                                    height: parent.height
                                                    gradient: Gradient {
                                                        orientation: Gradient.Horizontal
                                                        GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                                        GradientStop { position: 1.0; color: "#00FFFFFF" }
                                                    }
                                                }
                                            }
                                            SequentialAnimation {
                                                id: directorMarquee
                                                running: false
                                                loops: Animation.Infinite
                                                ScriptAction { script: { directorLineBox.marqueeMoving = false; directorsText.x = 0; directorsText.opacity = 1.0 } }
                                                PauseAnimation { duration: directorMarqueePauseStartMs }
                                                ScriptAction { script: { directorLineBox.marqueeMoving = true } }
                                                NumberAnimation {
                                                    target: directorsText
                                                    property: "x"
                                                    from: 0
                                                    to: directorLineBox.marqueeExitX
                                                    duration: directorLineBox.marqueeScrollMs
                                                    easing.type: Easing.Linear
                                                }
                                                ScriptAction { script: { directorLineBox.marqueeMoving = false } }
                                                PauseAnimation { duration: 180 }
                                                ScriptAction { script: { directorsText.x = 0; directorsText.opacity = 1.0; directorLineBox.marqueeMoving = false } }
                                                PauseAnimation { duration: directorMarqueePauseEndMs }
                                                onRunningChanged: {
                                                    if (!running) {
                                                        directorLineBox.marqueeMoving = false
                                                        directorsText.x = directorLineBox.maskActive ? 0 : Math.max(0, directorLineBox.width - directorsText.paintedWidth)
                                                        directorsText.opacity = 1.0
                                                    }
                                                }
                                            }
                                            function updateMarquee() {
                                                directorMarquee.stop()
                                                directorLineBox.marqueeMoving = false
                                                directorsText.x = directorLineBox.maskActive ? 0 : Math.max(0, directorLineBox.width - directorsText.paintedWidth)
                                                directorsText.opacity = 1.0
                                                if (directorLineBox.marqueeNeeded && directorLineBox.allowMarquee && directorLineBox.marqueeScrollMs > 0) {
                                                    Qt.callLater(function(){
                                                        if (directorLineBox.marqueeNeeded && directorLineBox.allowMarquee && directorLineBox.visible && directorLineBox.marqueeScrollMs > 0)
                                                            directorMarquee.start()
                                                    })
                                                }
                                            }
                                        }
                                    }
                                    Repeater {
                                        model: [
                                            { l:"DURÉE", v: MediaCatalog.fmtDurationMinutes(durationMinutes) },
                                            { l:"FIN",   v: endTimeString }
                                        ]
                                        delegate: Column {
                                            spacing: 1
                                            Text { textFormat: Text.PlainText;
                                                width: infoTextClip.width
                                                text: modelData.l
                                                color: "#FFFFFF"; font.pixelSize: 16; font.bold: true
                                                horizontalAlignment: Text.AlignRight
                                                wrapMode: Text.NoWrap; elide: Text.ElideRight
                                            }
                                            Text { textFormat: Text.PlainText;
                                                width: infoTextClip.width
                                                text: modelData.v
                                                color: infoValueColor; font.pixelSize: 15
                                                horizontalAlignment: Text.AlignRight
                                                wrapMode: Text.NoWrap; elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }
                            }
                            FocusScope {
                                id: actionsBlock
                                width: infoW + 40
                                height: playBtnTopExtra + playBtnSize + 58
                                focus: currentFocus === 1
                                visible: hasItem
                                // -1 = aucun choix précédent : au premier focus,
                                // Reprendre si disponible, sinon Lire depuis le début.
                                property int lastActionIndex: -1
                                property string hintText: ""
                                property int hintTopGap: 14
                                property var btns: [null, null, null, null]
                                property var actionModel: [
                                    { idx:0, kind:"resume",     name:"resumeBtn" },
                                    { idx:1, kind:"restart",    name:"playBtn"   },
                                    { idx:2, kind:"toggleSeen", name:"seenBtn"   },
                                    { idx:3, kind:"toggleLike", name:"likeBtn"   }
                                ]
                                Timer { id: navKick; interval: 0; repeat: false; onTriggered: actionsBlock._buildNav() }
                                onActiveFocusChanged: if (activeFocus) safeRestart(navKick)
                                function requestNavRebuild(){ safeRestart(navKick) }
                                function _btnShown(b){ if (!b) return false; try { if (b.shouldShow !== undefined) return !!b.shouldShow } catch(e) {}; try { return !!b.visible } catch(e2) {}; return false }
                                function _showResume(){ return _btnShown(btns[0]) }
                                function _register(btn, idx, kind){ btns[idx] = btn; detailMoviePage._wireActionSignals(btn, kind, idx); safeRestart(navKick) }
                                function _buildNav(){
                                    var resume = btns[0], play = btns[1], seen = btns[2], like = btns[3], showResume = _showResume()
                                    if (!play || !seen || !like) return
                                    try { if (resume) { resume.KeyNavigation.right = play; resume.KeyNavigation.left = like } } catch(e) {}
                                    try { play.KeyNavigation.right = seen; play.KeyNavigation.left = showResume ? resume : like } catch(e2) {}
                                    try { seen.KeyNavigation.right = like; seen.KeyNavigation.left = play } catch(e3) {}
                                    try { like.KeyNavigation.left = seen; like.KeyNavigation.right = posterFocus } catch(e4) {}
                                }
                                function _normalizeIndex(i){ i=i|0; if (i<0) i=0; if (i>3) i=3; if (!_showResume() && i===0) i=1; return i }
                                function hintFor(kind, btn){
                                    if (kind === "resume") return "Reprendre"
                                    if (kind === "restart" || kind === "play" || kind === "start") return "Lire depuis le début"
                                    if (kind === "toggleSeen") return (btn && btn.checked) ? "Marquer non vu" : "Marquer vu"
                                    if (kind === "toggleLike") return (btn && btn.checked) ? "Retirer des favoris" : "Ajouter aux favoris"
                                    return ""
                                }
                                function updateHintFromButton(btn, kind){ hintText = hintFor("" + kind, btn) }
                                function focusIndex(idx){
                                    if (!actionsArmed) return
                                    var i = _normalizeIndex(idx), b = btns[i]
                                    currentFocus = 1; lastActionIndex = i
                                    if (b) updateHintFromButton(b, actionModel[i].kind)
                                    if (b && b.forceActiveFocus) b.forceActiveFocus()
                                    else if (btns[1] && btns[1].forceActiveFocus) btns[1].forceActiveFocus()
                                }
                                function focusSavedOrFirst(){
                                    if (!actionsArmed) return
                                    if (lastActionIndex >= 0) {
                                        focusIndex(lastActionIndex)
                                        return
                                    }
                                    focusIndex(_showResume() ? 0 : 1)
                                }
                                Keys.priority: Keys.BeforeItem
                                Keys.onPressed: {
                                    if (!actionsArmed) { event.accepted = true; return }
                                    if (event.key === Qt.Key_Down) { goDownPref(); event.accepted = true }
                                    else if (event.key === Qt.Key_Up) {
                                        if (overviewVisible) { currentFocus = 0; ensureItemVisible(overviewBox, 20); overviewBox.forceActiveFocus() }
                                        else goTopBarFocus()
                                        event.accepted = true
                                    }
                                }
                                Row {
                                    id: actionsRow
                                    spacing: 18
                                    anchors.top: parent.top
                                    anchors.topMargin: playBtnTopExtra
                                    transform: [ Translate { x: actionsNudgeX } ]
                                    Repeater {
                                        model: actionsBlock.actionModel
                                        delegate: Components.GlassCircleButtonMovie {
                                            id: actionBtn
                                            objectName: modelData.name
                                            size: playBtnSize
                                            actionType: modelData.kind
                                            serverUrl: serverUrl
                                            accessToken: accessToken
                                            userId: userId
                                            itemId: hasItem ? item.Id : ""
                                            itemTitle: itemTitle
                                            userData: hasItem ? item.UserData : null
                                            runTimeTicks: hasItem && item.RunTimeTicks ? Number(item.RunTimeTicks) : 0
                                            tintColor: glassBase
                                            focusRingColor: "#FFFFFF"
                                            onActiveFocusChanged: if (activeFocus) {
                                                actionsBlock.lastActionIndex = modelData.idx
                                                actionsBlock.updateHintFromButton(actionBtn, modelData.kind)
                                                requestSaveFocusSnapshot()
                                            }
                                            Connections {
                                                target: actionBtn
                                                ignoreUnknownSignals: true
                                                onShouldShowChanged: { actionsBlock.requestNavRebuild(); if (actionBtn.activeFocus) actionsBlock.updateHintFromButton(actionBtn, modelData.kind) }
                                                onWidthChanged: actionsBlock.requestNavRebuild()
                                                onCheckedChanged: if (actionBtn.activeFocus) actionsBlock.updateHintFromButton(actionBtn, modelData.kind)
                                            }
                                            Keys.onPressed: {
                                                if (!actionsArmed) { event.accepted = true; return }
                                                if (modelData.kind === "toggleLike" && event.key === Qt.Key_Right) {
                                                    currentFocus = 2; posterFocus.forceActiveFocus(); event.accepted = true
                                                }
                                            }
                                            Component.onCompleted: actionsBlock._register(actionBtn, modelData.idx, modelData.kind)
                                        }
                                    }
                                }
                                Text { textFormat: Text.PlainText;
                                    anchors.top: actionsRow.bottom
                                    anchors.topMargin: actionsBlock.hintTopGap
                                    anchors.horizontalCenter: actionsRow.horizontalCenter
                                    width: Math.max(actionsRow.implicitWidth, (playBtnSize * 4 + actionsRow.spacing * 3))
                                    horizontalAlignment: Text.AlignHCenter
                                    color: "#DDE1F6"
                                    font.pixelSize: 12
                                    text: actionsBlock.hintText
                                    visible: currentFocus === 1 && text.length > 0
                                    opacity: visible ? 1 : 0
                                    Behavior on opacity { enabled: !flickBusy; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                }
                            }
                        }
                        FocusScope {
                            id: overviewBox
                            z: 5
                            x: centerLeft
                            y: overviewTopShift
                            width: overviewAutoWidth ? (rowBlock.width - x - (posterW + posterEdgeGap + marginR + 24)) : overviewW
                            property int lineHeight: Math.round(overviewText.font.pixelSize * 1.4)
                            height: Math.max(overviewMinH, lineHeight * overviewMaxLines + 20)
                            visible: overviewVisible
                            focus: currentFocus === 0
                            property bool focused: (currentFocus === 0 || activeFocus)
                            scale: focused ? 1.012 : 1.0
                            transformOrigin: Item.Center
                            Behavior on scale { enabled: !flickBusy; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                            Rectangle {
                                anchors.fill: parent
                                radius: 12
                                color: overviewBox.focused ? glassFocus : "transparent"
                                border.width: overviewBox.focused ? 1 : 0
                                border.color: overviewBox.focused ? glassBorder : "transparent"
                                antialiasing: overviewBox.focused && aaEdges
                            }
                            Text { textFormat: Text.PlainText;
                                id: overviewText
                                anchors.fill: parent
                                anchors.margins: 10
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                verticalAlignment: Text.AlignTop
                                color: "#FFFFFF"
                                font.pixelSize: 22
                                wrapMode: Text.WordWrap
                                text: (hasItem && item.Overview) ? item.Overview : ""
                                elide: Text.ElideRight
                                maximumLineCount: overviewMaxLines
                            }
                            Keys.onPressed: {
                                if (event.key === Qt.Key_Right) { currentFocus = 2; posterFocus.forceActiveFocus(); event.accepted = true }
                                else if (event.key === Qt.Key_Left) { currentFocus = 1; actionsBlock.focusSavedOrFirst(); event.accepted = true }
                                else if (event.key === Qt.Key_Up) { goTopBarFocus(); event.accepted = true }
                                else if (event.key === Qt.Key_Down) { currentFocus = 1; ensureItemVisible(actionsBlock, 20); actionsBlock.focusSavedOrFirst(); event.accepted = true }
                                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) { openOverviewOverlay(); event.accepted = true }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { currentFocus = 0; overviewBox.forceActiveFocus(); openOverviewOverlay() }
                            }
                        }
                        FocusScope {
                            id: posterFocus
                            width: posterW; height: artworkH
                            x: rowBlock.width - (marginR + posterEdgeGap + width)
                            y: posterTopOffset + (isMusicVideo ? Math.round((posterH - height) / 2) : 0)
                            visible: hasItem
                            focus: currentFocus === 2
                            clip: true
                            KeyNavigation.left: overviewVisible ? overviewBox : actionsBlock
                            property bool focused: (currentFocus === 2 || activeFocus)
                            onActiveFocusChanged: {
                                if (activeFocus) _schedulePosterHq()
                                else _clearPosterHq()
                            }
                            scale: focused ? 1.02 : 1.0
                            transformOrigin: Item.Center
                            Behavior on scale { enabled: !flickBusy; NumberAnimation { duration: 120 } }
                            Keys.onPressed: {
                                if (event.key === Qt.Key_Left) {
                                    if (overviewVisible) { currentFocus = 0; ensureItemVisible(overviewBox, 20); overviewBox.forceActiveFocus() }
                                    else { currentFocus = 1; actionsBlock.focusSavedOrFirst() }
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Down) { goDownPref(); event.accepted = true }
                                else if (event.key === Qt.Key_Up) { goTopBarFocus(); event.accepted = true }
                                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) { openPosterOverlay(); event.accepted = true }
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: { currentFocus = 2; posterFocus.forceActiveFocus() }
                                onClicked: { currentFocus = 2; posterFocus.forceActiveFocus(); openPosterOverlay() }
                            }
                            Item {
                                id: posterImgLayer
                                anchors.fill: parent
                                anchors.margins: frameMargin()
                                clip: true
                                // PERF Freebox: suppression du layer OpacityMask poster.
                                // Le poster/logo reste focusable et animé ; plus d'offscreen GPU pour le crop.
                                scale: posterFocus.focused ? 1.06 : 1.0
                                transformOrigin: Item.Center
                                Behavior on scale { enabled: !flickBusy; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } } }
                            Rectangle {
                                anchors.fill: posterImgLayer
                                color: "#0E1017"
                                visible: !((posterLogo.status === Image.Ready && !posterLogoFailed && movieLogoUrl !== "") || (posterPrimary.status === Image.Ready))
                            }
                            Image {
                                id: posterPrimary
                                parent: posterImgLayer
                                anchors.fill: parent
                                asynchronous: true
                                cache: true
                                mipmap: false
                                smooth: !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                fillMode: isMusicVideo ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                source: ""
                                opacity: (posterLogo.status === Image.Ready && !posterLogoFailed && movieLogoUrl !== "") ? 0.0 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                onStatusChanged: {
                                    _updatePosterGate()
                                    if (status === Image.Ready && posterFocus.activeFocus) _schedulePosterHq()
                                }
                            }
                            Image {
                                id: posterPrimaryHq
                                parent: posterImgLayer
                                anchors.fill: parent
                                asynchronous: true
                                cache: false
                                mipmap: false
                                smooth: !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                fillMode: isMusicVideo ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                source: (posterHqArmed && posterFocus.activeFocus && posterPrimary.status === Image.Ready
                                         && !flickBusy && detailMoviePage._posterCoverVisible())
                                        ? movieCoverHqUrl : ""
                                visible: source !== "" && status === Image.Ready
                                opacity: visible ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                            }
                            Image {
                                id: posterLogo
                                parent: posterImgLayer
                                anchors.centerIn: parent
                                width: parent.width * 0.90
                                height: parent.height * 0.90
                                asynchronous: true
                                cache: true
                                mipmap: false
                                smooth: posterFocus.focused && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                fillMode: Image.PreserveAspectFit
                                source: ""
                                transform: [ Translate { x: posterLogoNudgeX; y: posterLogoNudgeY } ]
                                opacity: (movieLogoUrl !== "" && !posterLogoFailed && status === Image.Ready) ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                onStatusChanged: {
                                    if (status === Image.Error) { posterLogoFailed = true; _syncPosterSources() }
                                    _updatePosterGate()
                                }
                                Component.onCompleted: _syncPosterSources()
                            }
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: frameMargin() + 0.5
                                scale: posterImgLayer.scale
                                transformOrigin: Item.Center
                                radius: 0
                                color: "transparent"
                                border.width: posterFocus.focused ? 1 : 0
                                border.color: posterFocus.focused ? glassBorder : glassBorderDim
                                antialiasing: posterFocus.focused && aaEdges
                            }
                        }
                    }
                    Item {
                        width: parent.width
                        height: (castReady && castPeople.length > 0 && hasItem) ? 24 : 0
                        visible: castReady && castPeople.length > 0 && hasItem
                        Text { textFormat: Text.PlainText;
                            text: isMusicVideo ? "Équipe du clip" : "Distribution et équipe"
                            color: "#FFFFFF"
                            font.pixelSize: 19; font.bold: true
                            anchors.left: parent.left; anchors.leftMargin: 28
                        }
                    }
                    Loader {
                        id: castPageLoader
                        active: castPeople.length > 0 && hasItem
                        source: active ? Qt.resolvedUrl("CastPage.qml") : ""
                        width: parent.width
                        visible: status === Loader.Ready && castPageLoader.item
                        asynchronous: true
                        height: (status === Loader.Ready && castPageLoader.item) ? (castPageLoader.item.implicitHeight || 0) : 0
                        onStatusChanged: _updateExtendedSectionGates()
                        onHeightChanged: _updateExtendedSectionGates()
                        onLoaded: { wireCastLoader(); _refreshCastPortraitPrewarm(); _updateExtendedSectionGates() }
                    }
                    Loader {
                        id: chaptersLoader
                        active: hasItem
                        source: active ? Qt.resolvedUrl("ChaptersCarousel.qml") : ""
                        width: parent.width; asynchronous: true
                        visible: status === Loader.Ready && item && item.hasContent === true
                        height: visible ? (item.implicitHeight || 0) : 0
                        onLoaded: {
                            item.serverUrl = Qt.binding(function(){ return detailMoviePage.serverUrl })
                            item.accessToken = Qt.binding(function(){ return detailMoviePage.accessToken })
                            item.itemId = Qt.binding(function(){ return detailMoviePage.itemId })
                            item.sectionLeftMargin = 28
                            item.requestFocusAbove.connect(function(){
                                if (hasCast()) {
                                    currentFocus = 3
                                    focusCast()
                                } else {
                                    goUpToActions()
                                }
                            })
                            item.requestFocusBelow.connect(function(){
                                if (hasSimilarContent()) {
                                    currentFocus = 4
                                    focusSimilar()
                                }
                            })
                        }
                    }
                    Loader {
                        id: similarLoader
                        active: hasItem && heavyReady && heavyStageSimilar
                        source: active ? Qt.resolvedUrl("SimilarItems.qml") : ""
                        width: parent.width
                        visible: status === Loader.Ready && similarLoader.item && similarLoader.item.hasContent === true
                        asynchronous: true
                        height: (status === Loader.Ready && similarLoader.item && similarLoader.item.hasContent === true) ? Math.max((similarLoader.item.implicitHeight || 0), 140) : 0
                        onStatusChanged: _updateExtendedSectionGates()
                        onHeightChanged: _updateExtendedSectionGates()
                        onLoaded: { wireSimilarLoader(); _updateExtendedSectionGates() }
                    }
                    Item { id: similarBottomProbe; width: 1; height: Math.max(24, bottomScrollPad / 2) }
                    Item { width: parent.width; height: bottomScrollPad }
                }
            }
        }
        Components.ClockHUD {
            id: clockHud
            z: 3000
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 20
            anchors.rightMargin: 24
            visible: uiReady && !visualLoading && overlayMode === "none"
            active: visible
            enabled: visible
            opacity: 1.0 - Math.min((rootFlick ? rootFlick.contentY : 0) / 80, 1)
            Component.onCompleted: _scheduleClockHudSync()
        }
        Text { textFormat: Text.PlainText;
            z: 4000
            anchors.centerIn: parent
            width: parent.width * 0.86
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: (!hasItem && loadingError) ? loadingError : ""
            color: "#ffdfdf"
            font.pixelSize: 22
            visible: text.length > 0
        }
    }
    /* ===== Timers dépendant d'ids visuels ===== */
    Timer { id: bgUpdateTimer; interval: 320; repeat: false; onTriggered: backdrop.updateBackdropNow() }
    /* ===== Connections ===== */
    Connections {
        target: castPageLoader.item
        ignoreUnknownSignals: true
        onActiveFocusChanged: if (castPageLoader.item && castPageLoader.item.activeFocus) { currentFocus = 3; requestSaveFocusSnapshot() }
        onLastFocusedIndexChanged: requestSaveFocusSnapshot()
        onActorActivated: function(personObj){ openPersonPage(personObj) }
    }
    Connections {
        target: chaptersLoader.item
        ignoreUnknownSignals: true
        onActiveFocusChanged: if (chaptersLoader.item && chaptersLoader.item.activeFocus) { currentFocus = 5; requestSaveFocusSnapshot() }
        onLastFocusedIndexChanged: requestSaveFocusSnapshot()
        onChapterActivated: function(index, chapter){ requestPlayAt(itemId, accessToken, userId, serverUrl, itemTitle, SeasonUtils.chapterStartMs(chapter)) }
    }
    Connections {
        target: similarLoader.item
        ignoreUnknownSignals: true
        onActiveFocusChanged: if (similarLoader.item && similarLoader.item.activeFocus) { currentFocus = 4; requestSaveFocusSnapshot() }
        onLastFocusedIndexChanged: requestSaveFocusSnapshot()
        onHasContentChanged: { _updateExtendedSectionGates(); safeCallLater(_pokeRestore) }
        onOpenItemRequested: function(obj){ openSimilarSelection(obj) }
        onItemActivated: function(obj){ openSimilarSelection(obj) }
        onCardActivated: function(obj){ openSimilarSelection(obj) }
    }
    Connections {
        target: clockHud
        ignoreUnknownSignals: true
        onRequestFocusBelow: restoreFocusFromHud()
        onActivated: { if (enableAvatarProfileNavigation) gotoSelectProfile(); else restoreFocusFromHud() }
        onAvatarActivated: { if (enableAvatarProfileNavigation) gotoSelectProfile(); else restoreFocusFromHud() }
    }
    /* ===== Loading overlay ===== */
    FocusScope {
        id: loadingOverlay
        anchors.fill: parent
        z: 999999
        visible: visualLoading
        enabled: visualLoading
        focus: visualLoading
        onVisibleChanged: if (!visible) _queueFocusRepair("loadingOverlayHidden", 24)
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Rectangle { anchors.fill: parent; color: "#000000" }
        // Spinner/texte plein écran centralisés dans ShellPage.

        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }
        Keys.onPressed: {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
                if (overlayMode !== "none") closeOverlay()
                else _leaveDetailToMenu()
                event.accepted = true
            } else event.accepted = true
        }
    }
    /* ===== Root back / escape ===== */
    Keys.onPressed: {
        if (currentFocus === focusHud && event.key === Qt.Key_Down) { restoreFocusFromHud(); event.accepted = true; return }
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            if (overlayMode !== "none") { closeOverlay(); event.accepted = true; return }

            // Back terminal : ne jamais sauvegarder la position actuelle.
            // Elle n'est utile que pour les sous-écrans Player / PersonPage.
            _leaveDetailToMenu()
            event.accepted = true
        }
    }
    /* ===== Overlay helpers ===== */
    function _currentArtUrl(){
        if (movieLogoUrl && !posterLogoFailed && posterLogo.status === Image.Ready) return movieLogoUrl
        if (movieCoverUrl && movieCoverUrl.length) return movieCoverUrl
        return movieLogoUrl
    }
    function openOverlay(mode, payload){
        if (!hasItem) return
        lastFocusBeforeOverlay = currentFocus
        overlayMode = mode
        overlayData = payload || ({})
    }
    function openPosterOverlay(){ openOverlay("poster", { posterUrl: _currentArtUrl() }) }
    function _overviewReaderImageUrl(){
        return item ? Jellyfin.itemBackdropOrPrimaryUrl(serverUrl, item, { fillWidth:720, fillHeight:405, quality:88, format:"jpg" }) : ""
    }
    function _overviewReaderRuntimeText(){
        var mins=Math.max(0,durationMinutes|0); if(!mins) return ""
        var hh=Math.floor(mins/60), mm=mins%60
        return hh>0 ? (hh+" h"+(mm>0 ? (" "+mm+" min") : "")) : (mins+" min")
    }
    function openOverviewOverlay(){
        if (!hasItem) return
        var meta=[], runtime=_overviewReaderRuntimeText()
        if (item && item.ProductionYear) meta.push(String(item.ProductionYear)); if (runtime.length) meta.push(runtime)
        if (item && item.OfficialRating) meta.push(String(item.OfficialRating))
        openOverlay("overview", { readerStyle:"media", title:itemTitle||"Résumé", meta:meta.join("  •  "),
            posterUrl:_overviewReaderImageUrl()||movieCoverUrl||_currentArtUrl(), overview:(item&&item.Overview)?item.Overview:"" })
    }
    function openPersonPage(personObj){
        if (!personObj || !personObj.Id || typeof requestNavigation !== "function") return
        // Le signal actorActivated peut arriver dans le même tour d'event que
        // le changement d'index du delegate. Synchroniser la section et l'index
        // ici garantit que le snapshot représente bien l'acteur réellement ouvert.
        currentFocus = 3
        try {
            var cast = castPageLoader.item
            if (cast && cast.currentActorIndex !== undefined && cast.currentActorIndex >= 0)
                cast.lastFocusedIndex = cast.currentActorIndex|0
        } catch(eCastSync) {}
        // Le retour depuis PersonPage doit restaurer précisément le casting focalisé.
        // On mémorise également la fiche d'origine afin que PersonPage puisse poser
        // un marker frais juste AVANT son retour, même après plusieurs minutes.
        armMemo("person")
        flushSaveFocusSnapshotNow()
        _storePersonReturnContext(personObj)
        _disarmMemo()
        requestNavigation(_navRoute("PersonPage.qml", { itemId: personObj.Id }))
    }
    function openSimilarSelection(x){
        if (!x) return
        var obj = (typeof x === "string") ? { Id: x } : x
        var id = obj.Id || obj.ItemId || obj.id || ""
        if (!id || id === itemId) return
        flushSaveFocusSnapshotNow()
        var type = (obj.Type || obj.CollectionType || obj.MediaType || "").toLowerCase()
        var isSeries = (type.indexOf("series") >= 0) || (obj.Type === "Series") || !!obj.SeriesId
        var page = isSeries ? "detailSeriePage.qml" : "detailMoviePage.qml"
        _openOnce(id, _navRoute(page, { itemId: id }))
    }
    function closeOverlay(){
        overlayMode = "none"; overlayData = ({})
        safeCallLater(function(){
            if (hardLoading) return
            switch (lastFocusBeforeOverlay) {
            case focusHud: focusHudAvatar(); break
            case 0: goUpToResume(); break
            case 1: currentFocus = 1; actionsBlock.focusSavedOrFirst(); break
            case 2: currentFocus = 2; ensureItemVisible(posterFocus, 20); posterFocus.forceActiveFocus(); break
            case 3:
                if (hasCast()) { currentFocus = 3; focusCast(); _forceSectionFocus() }
                break
            case 4:
                if (hasSimilarContent()) { currentFocus = 4; focusSimilar(); _forceSectionFocus() }
                else if (hasChapters()) { currentFocus = 5; focusChapters() }
                else if (hasCast()) { currentFocus = 3; focusCast() }
                else { currentFocus = firstContentFocus(); if (currentFocus === 0 && overviewBox && overviewBox.visible) overviewBox.forceActiveFocus(); else if (actionsBlock) actionsBlock.focusSavedOrFirst() }
                break
            case 5: if (hasChapters()) { currentFocus = 5; focusChapters() } else goDownPref(); break
            default:
                currentFocus = firstContentFocus()
                if (currentFocus === 0 && overviewBox && overviewBox.visible) overviewBox.forceActiveFocus()
                else if (actionsBlock) actionsBlock.focusSavedOrFirst()
            }
            requestSaveFocusSnapshot()
            _queueFocusRepair("overlayClosed", 8)
        })
    }
}
