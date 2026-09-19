import QtQuick 2.15
import "../components" as Components
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils
import "../js/MediaCatalog.js" as MediaCatalog
FocusScope {
    id: detailSeriePage
    width: parent ? parent.width : 1280
    height: parent ? parent.height : 720
    focus: true
    property string accessToken: ""
    property string userId: ""
    property string serverUrl: ""
    property string itemId: ""

    // ShellPage réinjecte l'épisode joué au retour du PlayerOverlay.
    // DetailSeriePage doit conserver cette ancre jusqu'à ce que NextUp soit prêt.
    property string preselectEpisodeId: ""
    property string userName: ""
    property string userImageTag: ""
    property var    fbx
    property var    shared: null

    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(detailSeriePage, false, 0, false) : false
    }

    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(detailSeriePage) : false
    }
    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(detailSeriePage, page, params || ({})) : (page + "?ctx=1")
    }

    readonly property color glassBase      : "#E6FFFFFF"
    readonly property color glassFocus     : "#1AFFFFFF"
    readonly property color glassBorder    : "#33FFFFFF"
    readonly property color glassBorderDim : "#18FFFFFF"
    // Même hiérarchie visuelle que detailMoviePage : libellés blancs, valeurs secondaires grises.
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
    function frameMargin() { return frameInsetPx + frameWidth/2 + frameInnerEpsilon; }
    property var  item: null
    property var  castPeople: []
    property var  seasons: []
    property bool seasonsFetched: false
    property bool seasonsFetchInFlight: false
    // Garde anti-race : plusieurs hydratations/visibilités peuvent relancer la
    // fiche presque simultanément. Une réponse Saisons d'une génération
    // précédente ne doit jamais écraser le modèle de la génération courante.
    property int  _seasonsFetchSeq: 0
    property int  _seasonsRetryCount: 0
    property string _seasonsRetrySeriesId: ""
    property int  castInitialLimit: 12
    property bool castHydrated: false
    property bool seasonsHydrated: false
    function _hydrateCastNow(){
        if (castHydrated) return;
        castHydrated = true;
        if (castPageLoader.item) {
            try { castPageLoader.item.people = castPeople; } catch(e) {}
            Qt.callLater(function(){ SeasonUtils.applyBlockPerf(castPageLoader.item); });
        }
    }
    function _hydrateSeasonsNow(){
        if (seasonsHydrated) return;
        seasonsHydrated = true;
        if (seasonsLoader.item) {
            try { seasonsLoader.item.seasons = seasons; } catch(e) {}
            Qt.callLater(function(){ SeasonUtils.applyBlockPerf(seasonsLoader.item); });
        }
    }
    property bool   hasItem: !!item
    property string itemTitle: (item && item.Name) ? item.Name : ""
    property bool   overviewVisible: (hasItem && item.Overview && item.Overview.length > 0)
    property var yearParts: MediaCatalog.seriesYearRangeParts(item, seasons, statusKind === 2)
    property string yearStartText: yearParts && yearParts.start ? yearParts.start : ""
    property string yearEndText: yearParts && yearParts.end ? yearParts.end : ""
    readonly property bool yearHasRange: yearStartText.length > 0 && yearEndText.length > 0 && yearEndText !== yearStartText
    property string yearText: yearHasRange ? (yearStartText + " → " + yearEndText) : yearStartText
    property int statusKind: MediaCatalog.seriesStatusKind(item)
    property string statusText: {
        if (!item || !item.Status) return ""
        if (statusKind === 1) return "EN PRODUCTION"
        if (statusKind === 2) return "TERMINÉ"
        return String(item.Status).toUpperCase()
    }
    readonly property color statusTagBorder: (statusKind===1) ? "#6DFF9A" : ((statusKind===2) ? "#FF8A80" : "#8EA0FF")
    readonly property color statusTagFill  : (statusKind===1) ? "#1F9D55" : ((statusKind===2) ? "#D93025" : "#33406A")
    property string genresLine: MediaCatalog.mediaGenresLine(item)
    property bool hasCommunityRating: !!(item && item.CommunityRating !== undefined && item.CommunityRating !== null)
    property string communityRatingText: hasCommunityRating ? Number(item.CommunityRating || 0).toFixed(1) : ""
    property bool hasOfficialRating: !!(item && item.OfficialRating)
    property string officialRatingText: hasOfficialRating ? ("" + item.OfficialRating) : ""
    property string averageEpisodeDurationText: ""
    property bool averageEpisodeDurationLoading: false
    property int _avgDurationSeq: 0
    property var _avgDurationHandle: null
    function _applyAverageDurationTicks(ticks){
        var t = Number(ticks || 0);
        averageEpisodeDurationText = t > 0 ? SeasonUtils.formatTicksToHhMm(t) : "";
    }
    function _resetAverageEpisodeDuration(){
        _avgDurationSeq++
        var h = _avgDurationHandle
        _avgDurationHandle = null
        try { if (h && h.cancel) h.cancel("context_changed") } catch(e) {}
        averageEpisodeDurationLoading = false
        averageEpisodeDurationText = ""
    }
    function _refreshAverageEpisodeDuration(){
        _resetAverageEpisodeDuration();
        var sid = _seriesId(), fallbackTicks = item ? Number(item.RunTimeTicks || 0) : 0;
        if (!serverUrl || !accessToken || !userId || !sid || !Jellyfin.fetchSeriesAverageEpisodeRuntimeTicks) {
            _applyAverageDurationTicks(MediaCatalog.seriesRuntimeTicksFallback(fallbackTicks));
            return;
        }
        var seq = ++_avgDurationSeq;
        averageEpisodeDurationLoading = true;
        var requestHandle = null
        requestHandle = Jellyfin.fetchSeriesAverageEpisodeRuntimeTicks(serverUrl, accessToken, userId, sid, fallbackTicks, function(avgTicks){
            if (seq !== _avgDurationSeq) return;
            if (_avgDurationHandle === requestHandle) _avgDurationHandle = null
            averageEpisodeDurationLoading = false;
            _applyAverageDurationTicks(avgTicks);
        }, function(){
            if (seq !== _avgDurationSeq) return;
            if (_avgDurationHandle === requestHandle) _avgDurationHandle = null
            averageEpisodeDurationLoading = false;
            _applyAverageDurationTicks(MediaCatalog.seriesRuntimeTicksFallback(fallbackTicks));
        });
        _avgDurationHandle = requestHandle
    }
    property string nextUpDurationText: ""
    property string nextUpEndText: ""
    function _updateNextUpMeta(){
        var ep = SeasonUtils.nextUpEpisodeFromBlock(nextUpLoader.item);
        if (!ep) { nextUpDurationText=""; nextUpEndText=""; return; }
        var ticks = Number(ep.RunTimeTicks || ep.RuntimeTicks || 0);
        if (!ticks || ticks <= 0) { nextUpDurationText=""; nextUpEndText=""; return; }
        nextUpDurationText = SeasonUtils.formatTicksToHhMm(ticks);
        nextUpEndText = SeasonUtils.formatEndClockFromTicks(ticks);
    }
    Timer {
        id: nextUpMetaTimer
        interval: 60000
        repeat: true
        // Timer minute utile uniquement si le bloc NextUp existe vraiment.
        running: uiReady && !hardLoading && overlayMode==="none" && hasNextUpContent()
        onTriggered: _updateNextUpMeta()
    }
    property int marginL: 40
    property int marginR: 40
    property int contentTopGap: 50
    property int sectionsSpacing: 12
    property int infoLeft: 40
    property int infoW: 180
    property int playBtnTopExtra: 220
    property int playBtnSize: 56
    property int posterW: 230
    property int posterH: 330
    property int posterEdgeGap: 20
    property int posterTopOffset: -20
    property int posterMaxW: Math.round(width * 0.78)
    property int posterMaxH: Math.round(height * 0.86)
    property int headerX: (infoLeft + infoW + 24) - 110
    property int tuneHeaderShiftY: 45
    property int tuneHeroShiftY: 15
    property int tuneInfoColShiftY: 0
    property int tuneInfoColShiftX: -110
    property int tuneActionsShiftY: 0
    property int tuneOverviewShiftY: 0
    property int tunePosterShiftY: -60
    property int tunePosterLogoShiftY: 0
    property int tuneTopHudShiftY: 0
    property int tuneNextUpShiftY: -30
    property int tuneSeasonsShiftY: -30
    property int tuneCastShiftY: 0
    property int tuneSimilarShiftY: 0
    readonly property int focusHud: -1
    property int currentFocus: 0
    property int lastFocusBeforeHud: 0
    onCurrentFocusChanged: {
        requestSaveFocusSnapshot(); // Tweak A
        if (currentFocus === 3) _hydrateCastNow();
        else if (currentFocus === 5) _hydrateSeasonsNow();
        if (currentFocus === 4) _scheduleViewportGate(); // aide Similar gate
    }
    function firstContentFocus(){ return overviewVisible ? 0 : 1; }
    function _applyDefaultFocus(){
        currentFocus = firstContentFocus();
        if (currentFocus === 0 && overviewBox && overviewBox.visible) overviewBox.forceActiveFocus();
        else if (actionsBlock) actionsBlock.focusFirst();
        didInitialFocus = true;
        isRestoring = false;
        requestSaveFocusSnapshot(); // Tweak A
        return true;
    }
    property bool scrollAnimEnabled: true
    function _jumpContentY(y){
        scrollAnimEnabled = false;
        rootFlick.contentY = y|0;
        Qt.callLater(function(){ scrollAnimEnabled = true; });
    }
    function focusHudAvatar(){
        if (overlayMode !== "none" || hardLoading) return false;
        if (!clockHud || !clockHud.visible || !clockHud.enabled) return false;
        if (currentFocus !== focusHud) lastFocusBeforeHud = currentFocus;
        currentFocus = focusHud;
        if (rootFlick && rootFlick.scrollToTop) rootFlick.scrollToTop(true);
        Qt.callLater(function(){
            try { if (clockHud && clockHud.focusAvatar) clockHud.focusAvatar(); } catch(e) {}
        });
        requestSaveFocusSnapshot();
        return true;
    }
    function restoreFocusFromHud(){
        var sec = lastFocusBeforeHud;
        if (!_wantSectionAvailable(sec) || sec === focusHud) sec = firstContentFocus();
        currentFocus = sec;
        if (sec===0) {
            if (overviewBox && overviewBox.visible) {
                ensureItemVisible(overviewBox, 40);
                overviewBox.forceActiveFocus();
            } else {
                currentFocus = 1;
                if (actionsBlock) actionsBlock.focusFirst();
            }
        } else if (sec===1) {
            if (actionsBlock) {
                ensureItemVisible(actionsBlock, 40);
                actionsBlock.focusFirst();
            }
        } else if (sec===2) {
            if (posterFocus) {
                ensureItemVisible(posterFocus, 20);
                posterFocus.forceActiveFocus();
            }
        } else if (sec===6) {
            focusNextUp();
        } else if (sec===5) {
            focusSeasons();
        } else if (sec===3) {
            focusCast();
        } else if (sec===4) {
            if (hasSimilarContent()) {
                _restoreSimilarFocusIfAny();
            } else {
                currentFocus = hasCast() ? 3 : (hasSeasons() ? 5 : 1);
                if (currentFocus===3) focusCast();
                else if (currentFocus===5) focusSeasons();
                else if (actionsBlock) actionsBlock.focusFirst();
            }
        } else {
            _applyDefaultFocus();
        }
        requestSaveFocusSnapshot();
    }
    property bool memoSaveWindow: false
    function _seriesId(){ return itemId || (item && item.Id) || ""; }
    function _detailFocusApi(){
        try { return shared && shared.__redefinDetailFocusApi ? shared.__redefinDetailFocusApi : null; }
        catch(e) { return null; }
    }
    function armMemo(scope){
        var api = _detailFocusApi(), sid = _seriesId();
        if (!api || !sid || !api.arm || api.arm(sid, scope) !== true) return;
        _cancelPendingFocusNavigation();
        memoSaveWindow = true;
    }
    function _isArmActive(){
        var api = _detailFocusApi(), sid = _seriesId();
        return !!(api && sid && api.isArmed && api.isArmed(sid));
    }
    function _activeMemoScope(){
        var api = _detailFocusApi(), sid = _seriesId();
        return api && sid && api.activeScope ? String(api.activeScope(sid) || "").toLowerCase() : "";
    }
    function _isPersonArmActive(){ return _activeMemoScope() === "person"; }
    /* ===== Retour PlayerOverlay -> NextUp, restauration déterministe ===== */
    property bool   _playerNextUpRestorePending: false
    property string _playerNextUpRestoreId: ""
    property int    _playerNextUpRestoreTries: 0
    property int    _playerNextUpRestoreFallbackIndex: 0
    property var    _playerNextUpRestoreItem: null
    property int    _playerNextUpRestoreStableTicks: 0
    property int    _playerNextUpRestoreStableRequired: 3
    function _nextUpSnapshotForReturn(id){
        var snap = _getFocusSnapshot();
        if (!snap || (id && snap.nextUpEpisodeId && String(snap.nextUpEpisodeId) !== String(id))) return null;
        return snap;
    }
    function _clearPlayerNextUpRestore(success){
        _playerNextUpRestorePending = false;
        _playerNextUpRestoreId = "";
        _playerNextUpRestoreTries = 0;
        _playerNextUpRestoreItem = null;
        _playerNextUpRestoreStableTicks = 0;
        try { playerNextUpRestoreTimer.stop(); } catch(e0) {}
        if (success) preselectEpisodeId = "";
    }
    function _fallbackFromPlayerNextUpRestore(){
        _cancelPendingFocusNavigation();
        _clearPlayerNextUpRestore(false);
        preselectEpisodeId = "";
        isRestoring = false;
        didInitialFocus = true;
        if (_isArmActive()) _disarmMemo();
        currentFocus = 1;
        Qt.callLater(function(){
            try {
                ensureItemVisible(actionsBlock, 40);
                if (actionsBlock) actionsBlock.focusFirst();
            } catch(e0) {}
        });
    }
    function _schedulePlayerNextUpRestore(delayMs){
        if (!_playerNextUpRestorePending) return;
        playerNextUpRestoreTimer.interval = Math.max(24, delayMs === undefined ? 45 : (delayMs|0));
        playerNextUpRestoreTimer.restart();
    }
    function _runPlayerNextUpRestore(){
        if (!_playerNextUpRestorePending) return;
        _playerNextUpRestoreTries++;
        if (!uiReady || hardLoading || overlayMode !== "none") {
            _playerNextUpRestoreStableTicks = 0;
            if (_playerNextUpRestoreTries < 180) { _schedulePlayerNextUpRestore(45); return; }
            _fallbackFromPlayerNextUpRestore();
            return;
        }
        // Ne pas attendre qu'un enfant possède déjà le focus pour pouvoir le
        // restaurer : après reconstruction de la fiche il peut justement n'y
        // avoir aucun activeFocus dans DetailSeriePage. Amorcer le FocusScope
        // parent casse cette boucle sans déplacer visuellement le focus.
        if (!activeFocus) {
            try { forceActiveFocus(Qt.OtherFocusReason); } catch(eRootFocus) {}
        }
        var it = nextUpLoader.item;
        if (it !== _playerNextUpRestoreItem) {
            _playerNextUpRestoreItem = it;
            _playerNextUpRestoreStableTicks = 0;
        }
        var snap = _nextUpSnapshotForReturn(_playerNextUpRestoreId);
        var fallbackIndex = snap && snap.nextUpIndex !== undefined
                ? (snap.nextUpIndex|0) : (_playerNextUpRestoreFallbackIndex|0);
        var snapshot = snap ? (snap.nextUpEpisodeSnapshot || null) : null;
        if (it) {
            try {
                if (it.setRestoreAnchor)
                    it.setRestoreAnchor(_playerNextUpRestoreId, fallbackIndex, snapshot);
            } catch(eAnchor) {}
        }

        if (!it || it.hasContent !== true) {
            if (_playerNextUpRestoreTries < 180) { _schedulePlayerNextUpRestore(45); return; }
            _fallbackFromPlayerNextUpRestore();
            return;
        }

        currentFocus = 6;
        ensureItemVisible(nextUpLoader, 30);
        var accepted = false;
        try {
            accepted = it.restoreCardFocus
                    ? (it.restoreCardFocus(_playerNextUpRestoreId, fallbackIndex) !== false)
                    : false;
        } catch(eFocus) {}

        if (accepted) {
            Qt.callLater(function(){
                if (!_playerNextUpRestorePending) return;
                var focused = false;
                try {
                    focused = it && it.hasFocusedEpisode
                            ? it.hasFocusedEpisode(_playerNextUpRestoreId)
                            : !!(it && it.activeFocus);
                } catch(eCheck) {}
                if (focused
                        && it === nextUpLoader.item
                        && nextUpLoader.status === Loader.Ready
                        && !hardLoading) {
                    _playerNextUpRestoreStableTicks++;
                    if (_playerNextUpRestoreStableTicks >= _playerNextUpRestoreStableRequired) {
                        _cancelPendingFocusNavigation();
                        didInitialFocus = true;
                        isRestoring = false;
                        if (_isArmActive()) _disarmMemo();
                        _clearPlayerNextUpRestore(true);
                        requestSaveFocusSnapshot();
                    } else {
                        _schedulePlayerNextUpRestore(55);
                    }
                } else if (_playerNextUpRestoreTries < 180) {
                    _playerNextUpRestoreStableTicks = 0;
                    _schedulePlayerNextUpRestore(45);
                } else {
                    _fallbackFromPlayerNextUpRestore();
                }
            });
            return;
        }

        if (_playerNextUpRestoreTries < 180) _schedulePlayerNextUpRestore(45);
        else _fallbackFromPlayerNextUpRestore();
    }

    Timer {
        id: playerNextUpRestoreTimer
        interval: 45
        repeat: false
        onTriggered: _runPlayerNextUpRestore()
    }

    // API attendue par ShellPage au retour du PlayerOverlay.
    function requestFocusItem(id){
        id = String(id || "");
        if (!id.length) return false;

        // ShellPage appelle cette API pour tout retour de lecture. N'activer la
        // restauration NextUp que si la lecture est réellement partie de ce rail;
        // les boutons principaux / Tout lire conservent leur propre snapshot.
        var snap = _getFocusSnapshot();
        if (!snap || (snap.section|0) !== 6) {
            preselectEpisodeId = "";
            return false;
        }

        _cancelPendingFocusNavigation();
        preselectEpisodeId = id;
        _playerNextUpRestoreId = id;
        _playerNextUpRestorePending = true;
        _playerNextUpRestoreTries = 0;
        _playerNextUpRestoreItem = null;
        _playerNextUpRestoreStableTicks = 0;
        _playerNextUpRestoreFallbackIndex = snap.nextUpIndex !== undefined
                ? (snap.nextUpIndex|0) : 0;

        try {
            snap.nextUpEpisodeId = id;
            var api = _detailFocusApi();
            if (api && api.put) api.put(_focusKey(), snap);
        } catch(eSnap) {}

        currentFocus = 6;
        _schedulePlayerNextUpRestore(24);
        return true;
    }

    function _storePersonReturnContext(personObj){
        try {
            if (!shared || !itemId || !personObj || !personObj.Id) return false;
            var snap = _getFocusSnapshot(), savedY = (snap && typeof snap.scrollY === "number") ? Number(snap.scrollY) : Number(rootFlick ? rootFlick.contentY : 0);
            var savedViewportY = (snap && snap.castViewportY !== undefined && snap.castViewportY !== null) ? Number(snap.castViewportY) : _castViewportY();
            shared.__redefinPersonReturnContext = ({
                detailItemId: String(itemId), personId: String(personObj.Id), castIndex: (castPageLoader.item && castPageLoader.item.currentActorIndex !== undefined) ? (castPageLoader.item.currentActorIndex|0) : 0,
                returnScrollY: isFinite(savedY) ? Math.max(0, savedY) : 0, returnCastViewportY: (savedViewportY !== null && isFinite(savedViewportY)) ? Number(savedViewportY) : null,
                detailKind: "series", ts: Date.now()
            });
            return true;
        } catch(e) { return false; }
    }

    function _consumePersonReturnRefreshMarker(){
        try {
            if (!shared || !shared.__redefinDetailReturnRefresh)
                return false;

            var marker = shared.__redefinDetailReturnRefresh;
            var markerId = String(marker.itemId || "");
            var scope = String(marker.scope || "").toLowerCase();
            var detailKind = String(marker.detailKind || "").toLowerCase();
            var ts = Number(marker.ts || 0);

            if (scope !== "person")
                return false;
            if (detailKind.length && detailKind !== "series")
                return false;
            if (!itemId || !markerId || markerId !== String(itemId))
                return false;
            if (ts > 0 && (Date.now() - ts) > 120000) {
                shared.__redefinDetailReturnRefresh = null;
                return false;
            }

            if (marker.castPersonId) {
                var a=_detailFocusApi(), s=a&&a.get?a.get(_focusKey()):null;
                if(a&&a.put){
                    if(!s) s={section:3,t:Date.now(),scrollY:0}; s.section=3; s.castIndex=(Number(marker.castIndex||0)|0); s.castPersonId=String(marker.castPersonId);
                    var ry=Number(marker.returnScrollY); if(isFinite(ry)&&ry>=0) s.scrollY=Math.round(ry);
                    if(marker.returnCastViewportY!==undefined&&marker.returnCastViewportY!==null){ var rvy=Number(marker.returnCastViewportY); if(isFinite(rvy)) s.castViewportY=rvy; }
                    a.put(_focusKey(),s);
                }
            }
            shared.__redefinDetailReturnRefresh = null;
            _personReturnGate = true;
            return true;
        } catch(e) {
            return false;
        }
    }

    function _disarmMemo(){
        var api = _detailFocusApi(), sid = _seriesId();
        if (api && sid && api.disarm) api.disarm(sid);
        memoSaveWindow = false;
    }
    function _castViewportY(){
        try {
            if (!rootFlick || !castPageLoader || !castPageLoader.visible
                    || castPageLoader.status !== Loader.Ready || !castPageLoader.item)
                return null;
            var p = castPageLoader.mapToItem(rootFlick, 0, 0);
            var y = Number(p ? p.y : NaN);
            return (isFinite(y) && !isNaN(y)) ? y : null;
        } catch(e) {
            return null;
        }
    }

    function _focusKey(){ return "detailSerie|" + _seriesId(); }
    property bool _saveQueued: false
    Timer {
        id: saveFocusTimer
        interval: 0
        repeat: false
        onTriggered: {
            _saveQueued = false;
            _saveFocusSnapshot();
        }
    }
    function requestSaveFocusSnapshot(){
        if (_saveQueued) {  return; }
        _saveQueued = true;
        saveFocusTimer.restart();
    }
    function flushSaveFocusSnapshotNow(){
        if (_saveQueued) {
            saveFocusTimer.stop();
            _saveQueued = false;
        }
        _saveFocusSnapshot();
    }
    function _saveFocusSnapshot(){
        if (isRestoring || !didInitialFocus) {  return; }
        if (!(memoSaveWindow || _isArmActive())) {  return; }
        var api = _detailFocusApi(); if(!api || !api.put) {  return; }
        var snap = { section: currentFocus, t: Date.now(), scrollY: rootFlick.contentY|0 };

        if (currentFocus === 3) {
            var castViewportY = _castViewportY();
            if (castViewportY !== null)
                snap.castViewportY = Number(castViewportY);
        }

        if (nextUpLoader.item && nextUpLoader.item.currentIndex !== undefined) {
            snap.nextUpIndex = nextUpLoader.item.currentIndex|0;
            try {
                if (nextUpLoader.item.currentEpisodeId)
                    snap.nextUpEpisodeId = String(nextUpLoader.item.currentEpisodeId);
                if (nextUpLoader.item.currentEpisodeSnapshot)
                    snap.nextUpEpisodeSnapshot = nextUpLoader.item.currentEpisodeSnapshot();
            } catch(eNextSnap) {}
        }
        if (seasonsLoader.item) {
            var g = seasonsLoader.item.grid || null;
            if (g && g.currentIndex !== undefined) snap.seasonsIndex = g.currentIndex|0;
        }
        if (castPageLoader.item && castPageLoader.item.lastFocusedIndex !== undefined) {
            snap.castIndex = castPageLoader.item.lastFocusedIndex;
            try {
                if (castPageLoader.item.currentActorId)
                    snap.castPersonId = String(castPageLoader.item.currentActorId);
            } catch(eCastId) {}
        }
        if (similarLoader.item && similarLoader.item.lastFocusedIndex !== undefined)
            snap.similarIndex = similarLoader.item.lastFocusedIndex;
        api.put(_focusKey(), snap);
    }
    function _getFocusSnapshot(){
        var api = _detailFocusApi();
        return api && api.get ? api.get(_focusKey()) : null;
    }

    // Retour terminal DetailSeriePage -> MoviePage/SeriePage : le stockage
    // reste la responsabilité exclusive de l'API DetailFocus de ShellPage.
    function _forgetFocusSnapshot(){
        if (_saveQueued) {
            try { saveFocusTimer.stop(); } catch(e0) {}
            _saveQueued = false;
        }

        try { restoreTimer.stop(); } catch(e1) {}
        _cancelPendingFocusNavigation();
        _restoreBudget = 0;
        isRestoring = false;

        _disarmMemo();

        var api = _detailFocusApi();
        if (api && api.remove) api.remove(_focusKey());
        memoSaveWindow = false;
    }

    function _leaveDetailToMenu(){
        // Annuler les restaurations spécifiques encore en attente avant de
        // quitter la fiche, afin qu'aucun callback tardif ne réarme son focus.
        _clearCastViewportRestore(true);
        _cancelPendingFocusNavigation();

        _forgetFocusSnapshot();
        _storeSensitiveNavContext();

        if (requestBackToMenu)
            requestBackToMenu();
    }
    property bool isRestoring: true
    property bool didInitialFocus: false
    property int  _restoreBudget: 0

    property bool _castViewportRestorePending: false
    property real _castViewportRestoreSavedY: 0
    property var  _castViewportRestoreSavedViewportY: null
    property int  _castViewportRestoreRetryLeft: 0
    property int  _castViewportRestoreStableTicks: 0
    property real _castViewportRestoreLastContentH: -1

    function _clearCastViewportRestore(releasePersonGate){
        castViewportRestoreTimer.stop();
        _castViewportRestorePending = false;
        _castViewportRestoreRetryLeft = 0;
        _castViewportRestoreStableTicks = 0;
        _castViewportRestoreLastContentH = -1;
        _castViewportRestoreSavedViewportY = null;
        if (releasePersonGate === true)
            _personReturnGate = false;
    }

    function _armCastViewportRestore(snap){
        if (!snap || !rootFlick)
            return false;

        var savedY = Number(snap.scrollY);
        if (!isFinite(savedY) || isNaN(savedY))
            savedY = Number(rootFlick.contentY || 0);

        var savedViewportY = null;
        if (snap.castViewportY !== undefined && snap.castViewportY !== null) {
            var rawViewportY = Number(snap.castViewportY);
            if (isFinite(rawViewportY) && !isNaN(rawViewportY))
                savedViewportY = rawViewportY;
        }

        _castViewportRestoreSavedY = Math.max(0, savedY);
        _castViewportRestoreSavedViewportY = savedViewportY;
        _castViewportRestoreRetryLeft = 18;
        _castViewportRestoreStableTicks = 0;
        _castViewportRestoreLastContentH = -1;
        _castViewportRestorePending = true;
        castViewportRestoreTimer.restart();
        return true;
    }

    Timer {
        id: castViewportRestoreTimer
        interval: 60
        repeat: true
        running: false
        onTriggered: {
            if (!_castViewportRestorePending || !rootFlick) {
                stop();
                return;
            }

            if (--_castViewportRestoreRetryLeft <= 0) {
                try { ensureItemVisible(castPageLoader, 40); } catch(e0) {}
                _clearCastViewportRestore(true);
                return;
            }

            if (!castPageLoader || !castPageLoader.visible
                    || castPageLoader.status !== Loader.Ready
                    || !castPageLoader.item
                    || (castPageLoader.height || 0) <= 0) {
                _castViewportRestoreStableTicks = 0;
                return;
            }

            var contentH = Number(rootFlick.contentHeight || 0);
            var viewH = Number(rootFlick.height || 720);
            var maxY = Math.max(0, contentH - viewH);
            var currentY = Number(rootFlick.contentY || 0);
            var targetY = currentY;
            var anchored = (_castViewportRestoreSavedViewportY !== null
                            && _castViewportRestoreSavedViewportY !== undefined);

            if (anchored) {
                var nowViewportY = _castViewportY();
                if (nowViewportY === null) {
                    _castViewportRestoreStableTicks = 0;
                    return;
                }
                var viewportDelta = Number(nowViewportY)
                                  - Number(_castViewportRestoreSavedViewportY);
                targetY = currentY + viewportDelta;
            } else {
                if (maxY + 2 < _castViewportRestoreSavedY
                        && _castViewportRestoreRetryLeft > 4) {
                    _castViewportRestoreStableTicks = 0;
                    return;
                }
                targetY = _castViewportRestoreSavedY;
            }

            targetY = Math.max(0, Math.min(maxY, Math.round(targetY)));
            var delta = Math.abs(targetY - currentY);
            if (delta > 1)
                _jumpContentY(targetY);

            var contentStable = (_castViewportRestoreLastContentH >= 0)
                    && Math.abs(contentH - _castViewportRestoreLastContentH) <= 1;
            _castViewportRestoreLastContentH = contentH;

            if (delta <= 1.5 && contentStable)
                _castViewportRestoreStableTicks++;
            else
                _castViewportRestoreStableTicks = 0;

            if (_castViewportRestoreStableTicks >= 3) {
                _clearCastViewportRestore(true);
                _scheduleViewportGate();
            }
        }
    }

    Timer {
        id: restoreTimer
        interval: 32
        repeat: true
        running: false
        onTriggered: {
            var keepRunning = false

            if (_restoreBudget > 0) {
                if (_tryRestoreOnce()) {
                    _restoreBudget = 0
                } else {
                    _restoreBudget--
                    if (_restoreBudget <= 0) {
                        isRestoring = false
                        if (_personReturnGate && !_castViewportRestorePending)
                            _personReturnGate = false
                        if (!didInitialFocus) Qt.callLater(_applyDefaultFocus)
                    } else {
                        keepRunning = true
                    }
                }
            }

            running = keepRunning
        }
    }
    function _requestRestore(budget){
        _cancelPendingFocusNavigation();
        isRestoring = true;
        _restoreBudget = budget|0;
        restoreTimer.start();
    }
    function _pokeRestore(){
        if (!uiReady || hardLoading) {  return; }
        if (_isArmActive()) {  _requestRestore(180); return; }
        if (didInitialFocus) {  return; }
        var s=_getFocusSnapshot();
        if (s) _requestRestore(40);
        else _applyDefaultFocus();
    }
    property bool _pokeRestoreQueued: false
    Timer {
        id: pokeRestoreCoalesceTimer
        interval: 0
        repeat: false
        onTriggered: {
            _pokeRestoreQueued = false
            _pokeRestore()
        }
    }
    function _schedulePokeRestore(){
        if (_pokeRestoreQueued) return
        _pokeRestoreQueued = true
        pokeRestoreCoalesceTimer.restart()
    }
    function _wantSectionAvailable(sec){
        if (sec===6) return hasNextUpContent();
        if (sec===5) return hasSeasons();
        if (sec===3) return hasCast();
        if (sec===4) return hasSimilarContent();
        if (sec===2) return hasItem;
        if (sec===1) return true;
        if (sec===0) return true;
        if (sec===focusHud) return true;
        return false;
    }
    function _tryRestoreOnce(){
        if (!uiReady || hardLoading) { return false; }
        var snap = _getFocusSnapshot();
        if (!snap) {
            if (_isArmActive()) _disarmMemo();
            return _applyDefaultFocus();
        }
        var sec = snap.section|0;
        if (sec===4 && !hasSimilarContent()) {
            currentFocus = 4;
            if (!heavyStageSimilar) heavyStageSimilar = true;
            return false;
        }
        if (sec===3) _hydrateCastNow();
        if (sec===5) _hydrateSeasonsNow();
        if (!_wantSectionAvailable(sec)) { return false; }

        currentFocus = sec;
        var focusConfirmed = true;

        if (sec===6) {
            ensureItemVisible(nextUpLoader, 30);
            var nextIt = nextUpLoader.item;
            var wantedEpisodeId = snap.nextUpEpisodeId ? String(snap.nextUpEpisodeId) : "";
            var wantedEpisodeIndex = snap.nextUpIndex !== undefined ? (snap.nextUpIndex|0) : 0;
            try {
                if (nextIt && nextIt.setRestoreAnchor)
                    nextIt.setRestoreAnchor(wantedEpisodeId, wantedEpisodeIndex, snap.nextUpEpisodeSnapshot || null);
            } catch(eNextAnchor) {}
            var nextRequested = _restoreNextUpFocusIfAny(snap);
            if (!nextRequested) {
                focusConfirmed = false;
            } else {
                try {
                    focusConfirmed = nextIt && nextIt.hasFocusedEpisode
                            ? nextIt.hasFocusedEpisode(wantedEpisodeId)
                            : !!(nextIt && nextIt.activeFocus);
                } catch(eNextCheck) { focusConfirmed = false; }
            }
        }
        else if (sec===5) {
            focusSeasons(true);
            Qt.callLater(function(){
                try {
                    var g = seasonsLoader.item && seasonsLoader.item.grid;
                    if (g && snap.seasonsIndex !== undefined) g.currentIndex = snap.seasonsIndex|0;
                } catch(e){}
                scheduleSeasonsBlockReframe("restore/seasons-index", 8, true);
            });
        }
        else if (sec===3) {
            var castIt = castPageLoader.item;
            var wantedCastIndex = snap.castIndex !== undefined ? (snap.castIndex|0) : 0;
            var wantedPersonId = snap.castPersonId ? String(snap.castPersonId) : "";
            try {
                if (castIt) {
                    castIt.lastFocusedIndex = wantedCastIndex;
                    if (castIt.restoreActorFocus)
                        castIt.restoreActorFocus(wantedPersonId, wantedCastIndex);
                    else if (castIt.restoreLastActorFocus)
                        castIt.restoreLastActorFocus();
                }
            } catch(eCastFocus) {}
            try {
                focusConfirmed = castIt && castIt.hasFocusedActor
                        ? castIt.hasFocusedActor(wantedPersonId)
                        : !!(castIt && castIt.activeFocus
                             && castIt.currentActorIndex === wantedCastIndex);
            } catch(eCastCheck) { focusConfirmed = false; }
        }
        else if (sec===4) {
            _restoreSimilarFocusIfAny();
            Qt.callLater(function(){
                try {
                    if (similarLoader.item && snap.similarIndex !== undefined) {
                        similarLoader.item.lastFocusedIndex = snap.similarIndex|0;
                        if (similarLoader.item.restoreLastCardFocus) similarLoader.item.restoreLastCardFocus();
                    }
                } catch(e){}
            });
        }
        else if (sec===2) { if (posterFocus) posterFocus.forceActiveFocus(); }
        else if (sec===1) { if (actionsBlock) actionsBlock.focusFirst(); }
        else if (sec===0) { goUpToResume(); }
        else if (sec===focusHud) { focusHudAvatar(); }

        // Les rails à delegates recyclés sont asynchrones. Tant que le poster
        // exact n'a pas réellement activeFocus, garder le snapshot armé et
        // laisser restoreTimer retenter. C'était la cause commune Cast/NextUp.
        if ((sec===3 || sec===6) && !focusConfirmed)
            return false;

        if (sec === 3) {
            _armCastViewportRestore(snap);
        } else if (typeof snap.scrollY === "number") {
            var maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height);
            var ry = Math.max(0, Math.min(maxY, snap.scrollY|0));
            rootFlick.contentY = ry;
            if (sec === 5) Qt.callLater(function(){ scheduleSeasonsBlockReframe("restore/after-scrollY", 8, true); });
        }
        _cancelPendingFocusNavigation();
        didInitialFocus = true;
        isRestoring = false;
        if (_isArmActive()) _disarmMemo();
        requestSaveFocusSnapshot();
        return true;
    }
    property bool fetchedOnce: false
    property int  _fetchToken: 0
    property var  _fetchHandle: null
    property var  _warmDetailSnapshot: null
    property bool warmSnapshotVisible: false
    property var  _seriesPlaylistHandle: null
    property bool fetchInFlight: false
    property bool gateMinDelay: false
    property bool gateItemReady: false
    property bool gatePosterReady: false
    property bool gateBGReady: false
    property bool serverResponseSlow: false
    readonly property bool hardLoading: (fetchInFlight && !warmSnapshotVisible) || !gateMinDelay || !gateItemReady || !gatePosterReady || !gateBGReady
    property bool uiReady: false
    property bool gateNextUpReady: false
    property bool gateSeasonsBlockReady: false
    property bool gateLayoutReady: false
    property bool extendedLoadingTimedOut: false

    // Gate Saisons strict :
    // - attendre le callback Jellyfin fetchSeasons()
    // - si la série possède des saisons, attendre que SeasonsBlock ait reçu le
    //   modèle COMPLET et que son ListView expose bien le même count.
    //
    // Le timeout des sections secondaires ne peut donc plus révéler une fiche
    // dont les saisons vont apparaître plusieurs secondes après.
    readonly property bool seasonsBlockFullyReady: {
        if (!hasItem) return true
        if (!seasonsFetched) return false
        if (!seasons || seasons.length <= 0) return true
        if (!seasonsLoader) return false
        if (seasonsLoader.status === Loader.Error) return true
        if (seasonsLoader.status !== Loader.Ready || !seasonsLoader.item) return false

        var g = null
        try { g = seasonsLoader.item.grid } catch(e0) { g = null }
        if (!g) return false

        var expected = seasons.length | 0
        var published = g.count | 0
        return expected > 0
            && published >= expected
            && (seasonsLoader.height | 0) > 0
    }
    readonly property bool seasonsStrictLoading: hasItem && !seasonsBlockFullyReady

    readonly property bool extendedLoading: !hardLoading && (!gateNextUpReady || !gateSeasonsBlockReady || !gateLayoutReady)
    property bool _personReturnGate: false
    readonly property bool visualLoading: hardLoading
                                          || extendedLoading
                                          || seasonsStrictLoading
                                          || _personReturnGate || _playerNextUpRestorePending
                                          || _castViewportRestorePending
    readonly property bool shellLoading: visualLoading
    readonly property string shellLoadingError: ""
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
        _refreshActionButtonStates()
        castPeople = (item && item.People) ? item.People : []
        fallbackPosterUrl = _buildFallbackPoster(item)
        castHydrated = false
        seasonsHydrated = false
        warmSnapshotVisible = true
        minLoadTimer.stop(); gateTimeoutTimer.stop()
        gateMinDelay = gateItemReady = gatePosterReady = gateBGReady = true
        _releaseExtendedGates()
        _syncPosterSources()
        bgUpdateTimer.restart()
        if (!seasonsFetched && !seasonsFetchInFlight)
            fetchSeasons()
        _schedulePokeRestore()
        _scheduleViewportGate()
        return true
    }
    function _cancelSeriesPlaylistFetch(reason){
        var h = _seriesPlaylistHandle
        _seriesPlaylistHandle = null
        try { if (h && h.cancel) h.cancel(reason || "context_changed") } catch(e) {}
    }
    function _resetExtendedGates(){
        gateNextUpReady = false;
        gateSeasonsBlockReady = false;
        gateLayoutReady = false;
        extendedLoadingTimedOut = false;
        extendedLoadingTimeout.stop();
        layoutReadyTimer.stop();
    }
    function _releaseExtendedGates(){
        extendedLoadingTimeout.stop();
        layoutReadyTimer.stop();
        gateNextUpReady = true;
        gateSeasonsBlockReady = true;
        gateLayoutReady = true;
        extendedLoadingTimedOut = true;
    }
    function _startExtendedLoadingGates(){
        if (hardLoading) return;
        _updateExtendedSectionGates();
        layoutReadyTimer.restart();
        extendedLoadingTimeout.restart();
    }
    function _updateExtendedSectionGates(){
        if (hardLoading) return;
        if (!hasItem) {
            gateNextUpReady = true;
            gateSeasonsBlockReady = true;
            return;
        }
        try {
            if (nextUpLoader.status === Loader.Error) gateNextUpReady = true;
            else if (heavyStageNextUp && nextUpLoader.status === Loader.Ready && nextUpLoader.item) {
                if ((nextUpLoader.height|0) > 0) gateNextUpReady = true;
            }
        } catch(e1) {}
        try {
            gateSeasonsBlockReady = seasonsBlockFullyReady
        } catch(e2) {
            gateSeasonsBlockReady = false
        }
    }
    function _resetGates(){
        gateMinDelay=false; gateItemReady=false; gatePosterReady=false; gateBGReady=false;
        serverResponseSlow=false;
        _resetExtendedGates();
        minLoadTimer.restart(); gateTimeoutTimer.restart();
    }
    function _releaseGatesImmediate(){
        minLoadTimer.stop(); gateTimeoutTimer.stop();
        fetchInFlight=false;
        serverResponseSlow=false;
        gateMinDelay=true; gateItemReady=true; gatePosterReady=true; gateBGReady=true;
        _releaseExtendedGates();
    }
    Timer { id: minLoadTimer; interval: 220; repeat: false; onTriggered: gateMinDelay=true }
    Timer {
        id: gateTimeoutTimer
        interval: 1800
        repeat: false
        // Ne jamais afficher une fiche incomplète simplement parce que le serveur
        // est lent : seul le callback Jellyfin peut libérer gateItemReady.
        onTriggered: { if (fetchInFlight) serverResponseSlow=true; }
    }
    Timer {
        id: layoutReadyTimer
        interval: 320
        repeat: false
        onTriggered: gateLayoutReady = true
    }
    Timer {
        id: extendedLoadingTimeout
        interval: 2600
        repeat: false
        onTriggered: _releaseExtendedGates()
    }
    readonly property int reqPosterW: Math.round(posterW * posterOS)
    readonly property int reqPosterH: Math.round(posterH * posterOS)
    readonly property int reqPosterHqW: Math.round(posterW * posterHqOS)
    readonly property int reqPosterHqH: Math.round(posterH * posterHqOS)

    // URLs image Jellyfin sans token : ne jamais logger Image.source ou URL /Items/... brute.

    property string fallbackPosterUrl: ""
    property bool   posterLogoFailed: false
    property string seriesLogoUrl: (hasItem && item.ImageTags && item.ImageTags.Logo)
        ? Jellyfin.itemImageUrl(serverUrl, item.Id, "Logo", item.ImageTags.Logo,
                               { maxWidth:900, maxHeight:900, quality:85, format:"png" })
        : ""
    property string seriesCoverUrl: (hasItem && item.ImageTags && item.ImageTags.Primary)
        ? Jellyfin.itemImageUrl(serverUrl, item.Id, "Primary", item.ImageTags.Primary,
                               { fillWidth:reqPosterW, fillHeight:reqPosterH, quality:88, format:"jpg" })
        : ""
    property string seriesCoverHqUrl: (hasItem && item.ImageTags && item.ImageTags.Primary)
        ? Jellyfin.itemImageUrl(serverUrl, item.Id, "Primary", item.ImageTags.Primary,
                               { fillWidth:reqPosterHqW, fillHeight:reqPosterHqH, quality:posterHqQuality, format:"jpg" })
        : ""
    function _posterCoverVisible(){
        return (!seriesLogoUrl || posterLogoFailed || posterLogo.status !== Image.Ready)
    }
    function _schedulePosterHq(){
        posterHqArmed = false
        posterHqTimer.stop()
        if (posterFocus && posterFocus.activeFocus && posterPrimary && posterPrimary.status === Image.Ready
                && _posterCoverVisible() && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking)))
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
                    && detailSeriePage._posterCoverVisible()
                    && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking)))
                detailSeriePage.posterHqArmed = true
        }
    }
    readonly property string effectivePosterUrl: (seriesLogoUrl && !posterLogoFailed && posterLogo.status !== Image.Error)
        ? seriesLogoUrl : seriesCoverUrl
    function _setImageSourceIfChanged(img, url) {
        if (!img) return;
        var next = String(url || "");
        if (String(img.source || "") === next) return;
        img.source = next;
    }

    function _syncPosterSources(){
        var wantLogo = (seriesLogoUrl && seriesLogoUrl!=="");
        if (!wantLogo) {
            posterLogoFailed=false;
            _setImageSourceIfChanged(posterLogo, "");
            _setImageSourceIfChanged(posterPrimary, seriesCoverUrl||"");
            return;
        }
        _setImageSourceIfChanged(posterLogo, seriesLogoUrl);
        _setImageSourceIfChanged(posterPrimary, posterLogoFailed ? (seriesCoverUrl||"") : "");
    }
    function _updatePosterGate(){
        if (gatePosterReady) return;
        var wantLogo = (seriesLogoUrl && seriesLogoUrl!=="");
        var hasCover = (seriesCoverUrl && seriesCoverUrl!=="");
        if (!wantLogo) {
            if (!hasCover) { gatePosterReady=true; return; }
            gatePosterReady = (posterPrimary.status===Image.Ready || posterPrimary.status===Image.Error);
            return;
        }
        if (posterLogo.status===Image.Ready) { gatePosterReady=true; return; }
        if (posterLogo.status===Image.Error) {
            if (!hasCover) { gatePosterReady=true; return; }
            gatePosterReady = (posterPrimary.status===Image.Ready || posterPrimary.status===Image.Error);
        }
    }
    property bool posterFxReady: false
    Timer { id: posterFxTimer; interval: 160; repeat: false; onTriggered: posterFxReady=true }
    onHardLoadingChanged: {
        if (hardLoading) {
            _resetExtendedGates();
            posterFxTimer.stop(); posterFxReady=false;
            nextUpDurationText=""; nextUpEndText="";
        } else {
            posterFxReady=false;
            posterFxTimer.restart();
            _startExtendedLoadingGates();
            _updateNextUpMeta();
            _schedulePokeRestore();
            _scheduleViewportGate();
        }
    }
    readonly property int bgW: 1280
    readonly property int bgH: 720
    property int bgBlur: 8
    property real bgDarken: 0.40
    Timer { id: bgUpdateTimer; interval: 320; repeat: false; onTriggered: backdrop.updateBackdropNow() }
    function _updateBGGate(){
        if (gateBGReady) return;
        var hasSrc = (backdrop.lastFull && backdrop.lastFull!=="");
        if (!hasSrc) { gateBGReady=true; return; }
        if (backdrop.bgImg && (backdrop.bgImg.status===Image.Ready || backdrop.bgImg.status===Image.Error))
            gateBGReady=true;
    }
    property int seasonsCount: SeasonUtils.countDisplaySeasons(seasons)
 property string seasonsCountText: (!seasonsFetched) ? "…" : ((seasonsCount <= 0) ? "0" : ("" + seasonsCount))
    signal requestPlay(string itemId, string accessToken, string userId, string serverUrl, string itemTitle)
    signal requestPlayList(var itemIds, string accessToken, string userId, string serverUrl, string listTitle)
    signal requestNavigation(string page)
    signal requestBackToMenu()
    function ensureItemVisible(target, m){
        SeasonUtils.ensureItemVisible(rootFlick, target, m)
    }
    property int seasonsReturnTopMargin: 90
    property int seasonsReturnBottomMargin: 64
    property int _seasonsReframeRetryLeft: 0
    property string _seasonsReframeReason: ""
    property bool _seasonsReframeJumpMode: true
    Timer {
        id: seasonsReframeTimer
        interval: 90
        repeat: false
        onTriggered: {
            if (_seasonsReframeRetryLeft <= 0) return;
            _seasonsReframeRetryLeft--;
            ensureSeasonsBlockFullyVisible(_seasonsReframeReason + "/retry", _seasonsReframeJumpMode);
            if (_seasonsReframeRetryLeft > 0 && currentFocus === 5)
                seasonsReframeTimer.restart();
        }
    }
    property bool _seasonsReframeLaterQueued: false
    Timer {
        id: seasonsReframeLaterTimer
        interval: 0
        repeat: false
        onTriggered: {
            _seasonsReframeLaterQueued = false
            ensureSeasonsBlockFullyVisible(_seasonsReframeReason + "/coalesced", _seasonsReframeJumpMode)
        }
    }
    function scheduleSeasonsBlockReframe(reason, retries, jumpMode){
        _seasonsReframeReason = reason || "unknown";
        _seasonsReframeJumpMode = (jumpMode !== false);
        _seasonsReframeRetryLeft = Math.max(_seasonsReframeRetryLeft, (retries === undefined ? 6 : retries|0));
        if (!_seasonsReframeLaterQueued) {
            _seasonsReframeLaterQueued = true
            seasonsReframeLaterTimer.restart()
        }
        seasonsReframeTimer.restart();
    }
    function ensureSeasonsBlockFullyVisible(reason, jumpMode){
        if (!rootFlick || !seasonsLoader || !seasonsSlot) return
        if (!seasonsLoader.visible || seasonsLoader.status !== Loader.Ready || !seasonsLoader.item) return

        var slotP = seasonsSlot.mapToItem(rootFlick.contentItem, 0, 0)
        var loaderP = seasonsLoader.mapToItem(rootFlick.contentItem, 0, 0)
        var target = SeasonUtils.seasonsReframeTarget({
            slotY: slotP.y,
            slotHeight: seasonsSlot.height,
            slotImplicitHeight: seasonsSlot.implicitHeight,
            loaderY: loaderP.y,
            loaderHeight: seasonsLoader.height,
            itemHeight: seasonsLoader.item.height,
            itemImplicitHeight: seasonsLoader.item.implicitHeight,
            contentHeight: rootFlick.contentHeight,
            viewHeight: rootFlick.height,
            contentY: rootFlick.contentY,
            topMargin: seasonsReturnTopMargin,
            bottomMargin: seasonsReturnBottomMargin
        })
        if (!target || !target.move || Math.abs(rootFlick.contentY - target.y) <= 1) return
        if (jumpMode !== false) _jumpContentY(target.y)
        else rootFlick.contentY = target.y
    }
    function hasNextUpContent(){ return (nextUpLoader.status===Loader.Ready && nextUpLoader.item && nextUpLoader.item.hasContent===true); }
    function hasSeasons(){ return (seasons && seasons.length>0 && seasonsLoader.item && (seasonsLoader.item.forceFirstFocus || (seasonsLoader.item.grid && seasonsLoader.item.grid.forceFirstFocus))); }
    function hasCast(){ return (castPeople.length>0 && castPageLoader.item && (castPageLoader.item.restoreLastActorFocus || castPageLoader.item.focusFirstActor || castPageLoader.item.forceFirstActorFocus)); }
    function hasSimilarContent(){ return (similarLoader.status===Loader.Ready && similarLoader.item && similarLoader.item.hasContent===true); }
    function similarReadyNoContent(){ return (similarLoader.status===Loader.Ready && similarLoader.item && similarLoader.item.hasContent===false); }
    function _restoreSimilarFocusIfAny(){
        if(!similarLoader.item) return;
        Qt.callLater(function(){
            var it=similarLoader.item; if(!it) return;
            if (it.restoreLastCardFocus) it.restoreLastCardFocus();
            else if (it.forceFirstCardFocus) it.forceFirstCardFocus();
            ensureItemVisible(similarBottomProbe, 0);
        });
    }
    function _restoreNextUpFocusIfAny(savedSnap){
        if(!nextUpLoader.item) return false;
        var it = nextUpLoader.item;

        // Navigation entre sections de la même DetailSeriePage : NextUpBlock
        // possède déjà la mémoire la plus fraîche (_lastIndex/currentIndex).
        // Ne pas l'écraser avec un snapshot partagé plus ancien ou l'index 0.
        var persistedRestore = savedSnap !== undefined && savedSnap !== null;
        var playerRestore = _playerNextUpRestorePending || (preselectEpisodeId && preselectEpisodeId.length);
        if (!persistedRestore && !playerRestore) {
            try {
                ensureItemVisible(nextUpLoader, 30);
                if (it.restoreLastCardFocus) return it.restoreLastCardFocus() !== false;
                if (it.restoreCardFocus) {
                    var liveId = it.currentEpisodeId ? String(it.currentEpisodeId) : "";
                    var liveIndex = it.currentIndex !== undefined ? (it.currentIndex|0) : 0;
                    return it.restoreCardFocus(liveId, liveIndex) !== false;
                }
                if (it.forceFirstCardFocus) { it.forceFirstCardFocus(); return true; }
            } catch(eLive) {}
            return false;
        }

        var snap = persistedRestore ? savedSnap : _getFocusSnapshot();
        var wantedId = _playerNextUpRestorePending && _playerNextUpRestoreId.length
                ? _playerNextUpRestoreId
                : (preselectEpisodeId || (snap ? (snap.nextUpEpisodeId || "") : ""));
        var wantedIndex = snap && snap.nextUpIndex !== undefined
                ? (snap.nextUpIndex|0)
                : (it.currentIndex !== undefined ? (it.currentIndex|0) : 0);
        try {
            if (it.setRestoreAnchor)
                it.setRestoreAnchor(wantedId, wantedIndex, snap ? (snap.nextUpEpisodeSnapshot || null) : null);
            ensureItemVisible(nextUpLoader, 30);
            if (it.restoreCardFocus) return it.restoreCardFocus(wantedId, wantedIndex) !== false;
            if (it.restoreLastCardFocus) return it.restoreLastCardFocus() !== false;
            if (it.forceFirstCardFocus) { it.forceFirstCardFocus(); return true; }
        } catch(e) {}
        return false;
    }
    function goTopBarFocus(){ focusHudAvatar(); }
    function goUpToResume(){ currentFocus=0; ensureItemVisible(overviewBox,40); overviewBox.forceActiveFocus(); }
    function focusNextUp(){ ensureItemVisible(nextUpLoader, 30); _restoreNextUpFocusIfAny(); }
    function focusSeasons(reframeMode){
        _hydrateSeasonsNow();
        ensureItemVisible(seasonsLoader, 40);
        SeasonUtils.focusFirstSeason(seasonsLoader.item);
        if (reframeMode === true)
            Qt.callLater(function(){ scheduleSeasonsBlockReframe("focusSeasons/restore", 6, true); });
    }
    function focusCast(){ _hydrateCastNow(); ensureItemVisible(castPageLoader,40); SeasonUtils.restoreCastFocus(castPageLoader.item); }
    function goDownPref(){
        if (hasNextUpContent()) { currentFocus=6; _restoreNextUpFocusIfAny(); }
        else if (hasSeasons()) { currentFocus=5; focusSeasons(); }
        else if (hasCast()) { currentFocus=3; focusCast(); }
        else {
            currentFocus = 4;
            if (!heavyStageSimilar) heavyStageSimilar = true;
            _armPendingFocus("similar");
        }
    }
    property string _pendingFocusTarget: ""
    property int _pendingFocusBudget: 0
    function _cancelPendingFocusNavigation(){
        _pendingFocusTarget = "";
        _pendingFocusBudget = 0;
        try { pendingFocusTimer.stop(); } catch(e0) {}
    }
    Timer {
        id: pendingFocusTimer
        interval: 32
        repeat: true
        running: false
        onTriggered: running = _runPendingFocusTick()
    }
    function _runPendingFocusTick(){
        if (isRestoring || _isArmActive() || _playerNextUpRestorePending) {
            _pendingFocusTarget = "";
            _pendingFocusBudget = 0;
            return false;
        }
        if (!uiReady || hardLoading || overlayMode !== "none") return true;

        // Un target différé n'est valable que tant que le routeur de section
        // pointe encore vers sa destination. Si l'utilisateur ou une
        // restauration a changé de section entre-temps, le target est périmé.
        var expectedSection = _pendingFocusTarget === "seasons" ? 5
                : (_pendingFocusTarget === "cast" ? 3
                : (_pendingFocusTarget === "similar" ? 4 : -1));
        if (expectedSection >= 0 && currentFocus !== expectedSection) {
            _pendingFocusTarget = "";
            _pendingFocusBudget = 0;
            return false;
        }

        _pendingFocusBudget--
        if (_pendingFocusBudget <= 0) {
            _pendingFocusTarget = ""
            return false
        }

        if (_pendingFocusTarget === "seasons") {
            if (seasonsLoader.status === Loader.Ready && seasonsLoader.item) {
                focusSeasons()
                _pendingFocusTarget = ""
                return false
            }
            return true
        }

        if (_pendingFocusTarget === "cast") {
            if (castPageLoader.status === Loader.Ready && castPageLoader.item) {
                focusCast()
                _pendingFocusTarget = ""
                return false
            }
            return true
        }

        if (_pendingFocusTarget === "similar") {
            if (similarLoader.status === Loader.Ready && similarLoader.item) {
                if (similarLoader.item.hasContent === true) {
                    _restoreSimilarFocusIfAny()
                    _pendingFocusTarget = ""
                    return false
                } else if (similarLoader.item.hasContent === false) {
                    if (_pendingFocusBudget > 8) return true
                    currentFocus = hasCast() ? 3 : (hasSeasons() ? 5 : 1)
                    if (currentFocus === 3) focusCast()
                    else if (currentFocus === 5) focusSeasons()
                    else if (actionsBlock) actionsBlock.focusFirst()
                    _pendingFocusTarget = ""
                    return false
                }
            }
            return true
        }

        _pendingFocusTarget = ""
        return false
    }
    function _armPendingFocus(kind){
        // Ne jamais laisser une navigation D-Pad différée concurrencer une
        // restauration de retour PersonPage/PlayerOverlay.
        if (isRestoring || _isArmActive() || _playerNextUpRestorePending) return;
        _pendingFocusTarget = kind || "";
        _pendingFocusBudget = 70;
        if (_pendingFocusTarget.length) pendingFocusTimer.restart();
        else pendingFocusTimer.stop();
    }
    function goDownFromNextUp(){
        if (seasons && seasons.length>0) {
            currentFocus = 5;
            if (!heavyStageSeasons) heavyStageSeasons = true;
            _armPendingFocus("seasons");
            return;
        }
        if (castPeople && castPeople.length>0) {
            currentFocus = 3;
            if (!heavyStageCast) heavyStageCast = true;
            _armPendingFocus("cast");
            return;
        }
        currentFocus = 4;
        if (!heavyStageSimilar) heavyStageSimilar = true;
        _armPendingFocus("similar");
    }
    property int viewportGateMargin: 520
    property bool similarViewportNear: false
    Timer {
        id: viewportGateTimer
        interval: 60
        repeat: false
        onTriggered: _updateViewportGates()
    }
    function _scheduleViewportGate(){
        if (!uiReady) return;
        viewportGateTimer.restart();
    }
    function _updateViewportGates(){
        try {
            if (!rootFlick || !similarSlot) { similarViewportNear=false; return; }
            var p = similarSlot.mapToItem(rootFlick.contentItem, 0, 0);
            var top = p.y;
            var bot = top + similarSlot.height;
            var viewTop = rootFlick.contentY - viewportGateMargin;
            var viewBot = rootFlick.contentY + rootFlick.height + viewportGateMargin;
            similarViewportNear = (bot >= viewTop) && (top <= viewBot);
        } catch(e) {
            similarViewportNear = false;
        }
    }
    property string overlayMode: "none"   // none | poster | overview
    property var overlayData: ({})
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
            hub.host = detailSeriePage
            hub.posterMaxW = detailSeriePage.posterMaxW
            hub.posterMaxH = detailSeriePage.posterMaxH
            if (hub.requestClose) hub.requestClose.connect(closeOverlay)
            if (hub.closed) hub.closed.connect(closeOverlay)
            Qt.callLater(function(){ if (overlayLoader.item && overlayMode !== "none") overlayLoader.item.forceActiveFocus() })
        }
    }
    readonly property bool heavyReady: uiReady && !hardLoading
    property bool heavyStageNextUp: false
    property bool heavyStageSeasons: false
    property bool heavyStageCast: false
    property bool heavyStageSimilar: false
    property int  _heavyStage: 0
    Timer {
        id: heavyStageTimer
        interval: 130
        repeat: false
        running: false
        onTriggered: {
            if (!heavyReady) { running=false; return; }
            if (_heavyStage===1) {
                heavyStageSeasons=true;
                _heavyStage=2;
                _updateExtendedSectionGates();
                restart();
                return;
            }
            if (_heavyStage===2) {
                heavyStageCast=true;
                _heavyStage=3;
                _updateExtendedSectionGates();
                restart();
                return;
            }
            if (_heavyStage===3) {
                heavyStageSimilar=true;
                running=false;
                _updateExtendedSectionGates();
                return;
            }
        }
    }
    function _resetHeavy(){
        heavyStageNextUp=false; heavyStageSeasons=false; heavyStageCast=false; heavyStageSimilar=false;
        _heavyStage=0; heavyStageTimer.stop();
    }
    function _startHeavy(){
        _resetHeavy();
        heavyStageNextUp=true; _heavyStage=1; _updateExtendedSectionGates(); heavyStageTimer.start();
    }
    function _resumeHeavy(){
        if (!heavyStageNextUp) {
            heavyStageNextUp = true;
            _heavyStage = 1;
        } else if (!heavyStageSeasons) {
            _heavyStage = 1;
        } else if (!heavyStageCast) {
            _heavyStage = 2;
        } else if (!heavyStageSimilar) {
            _heavyStage = 3;
        } else {
            _heavyStage = 0;
            _updateExtendedSectionGates();
            return;
        }
        _updateExtendedSectionGates();
        heavyStageTimer.restart();
    }
    // Une fois un rail lourd activé, un rebond transitoire de hardLoading ne
    // doit pas détruire son Loader et donc son focus. On suspend seulement la
    // progression des stages; un vrai changement de série appelle _resetHeavy().
    onHeavyReadyChanged: {
        if (heavyReady) {
            if (!heavyStageNextUp && !heavyStageSeasons && !heavyStageCast && !heavyStageSimilar)
                _startHeavy();
            else
                _resumeHeavy();
        } else {
            heavyStageTimer.stop();
        }
    }
    function _buildFallbackPoster(res) {
        if (!res || !res.Id || !res.ImageTags || !res.ImageTags.Primary) return ""
        return Jellyfin.itemImageUrl(serverUrl, res.Id, "Primary", res.ImageTags.Primary, {
            fillWidth: 226, fillHeight: 339, quality: 85, format: "jpg"
        })
    }
    function _invalidateSeasonsFetch(){
        _seasonsFetchSeq = (_seasonsFetchSeq + 1) | 0
        seasonsFetchInFlight = false
        _seasonsRetryCount = 0
        _seasonsRetrySeriesId = ""
        seasonsRetryTimer.stop()
    }
    function fetchSeasons(isRetry){
        if (seasonsFetchInFlight) return

        var sid = String(itemId || "")
        if (!isRetry) {
            _seasonsRetryCount = 0
            _seasonsRetrySeriesId = sid
        }
        seasonsFetched = false

        if (!serverUrl || !accessToken || !userId || !sid) {
            _invalidateSeasonsFetch()
            seasons = []
            seasonsFetched = true
            seasonsHydrated = true
            gateSeasonsBlockReady = true
            return
        }

        var seq = (_seasonsFetchSeq + 1) | 0
        _seasonsFetchSeq = seq
        seasonsFetchInFlight = true
        Jellyfin.fetchSeasons(serverUrl, accessToken, userId, sid,
            function(items){
                // Une ancienne requête peut terminer après une nouvelle vague
                // de navigation/hydratation. Elle ne doit plus toucher l'état.
                if (seq !== _seasonsFetchSeq || sid !== String(itemId || "")) return

                seasonsFetchInFlight = false
                _seasonsRetryCount = 0
                _seasonsRetrySeriesId = ""
                items = items || [];
                items.sort(function(a,b){
                    var ia=(a&&a.IndexNumber!=null)?a.IndexNumber:9999;
                    var ib=(b&&b.IndexNumber!=null)?b.IndexNumber:9999;
                    if (ia===0 && ib!==0) return 1;
                    if (ib===0 && ia!==0) return -1;
                    return ia-ib;
                });

                // Jellyfin nous a déjà rendu toutes les saisons. Les tronquer
                // côté QML ne réduirait pas le réseau : cela retarderait
                // uniquement leur publication dans SeasonsBlock. ListView garde
                // sa virtualisation, donc le modèle complet reste raisonnable sur
                // Freebox Révolution.
                seasons = items
                seasonsFetched = true
                seasonsHydrated = true
                gateSeasonsBlockReady = (!seasons || seasons.length === 0)

                if (seasonsLoader.item) {
                    seasonsLoader.item.seasons = seasons
                    if (seasonsLoader.item.hasOwnProperty("fallbackPosterUrl"))
                        seasonsLoader.item.fallbackPosterUrl = fallbackPosterUrl
                    seasonsLoader.item.serverUrl = serverUrl
                    SeasonUtils.applyBlockPerf(seasonsLoader.item)
                }

                Qt.callLater(function(){
                    _updateExtendedSectionGates()
                    _schedulePokeRestore()
                    _scheduleViewportGate()
                })
            },
            function(_err){
                if (seq !== _seasonsFetchSeq || sid !== String(itemId || "")) return

                seasonsFetchInFlight = false

                // Une annulation/transitoire ne doit pas faire croire à la fiche
                // qu'une série possède zéro saison. Un seul retry suffit à
                // absorber la course observée sans créer de boucle réseau.
                if (_seasonsRetryCount < 1 && visible && serverUrl && accessToken && userId) {
                    _seasonsRetryCount++
                    _seasonsRetrySeriesId = sid
                    seasonsRetryTimer.restart()
                    return
                }

                seasons = []
                seasonsFetched = true
                seasonsHydrated = true
                gateSeasonsBlockReady = true
                _updateExtendedSectionGates()
            }
        );
    }
    Timer {
        id: seasonsRetryTimer
        interval: 180
        repeat: false
        onTriggered: {
            if (_seasonsRetrySeriesId
                    && _seasonsRetrySeriesId === String(itemId || "")
                    && !seasonsFetchInFlight
                    && !seasonsFetched
                    && visible)
                fetchSeasons(true)
        }
    }
    function fetchItemIfReady(){
        if (!(serverUrl && accessToken && itemId)) {
            _cancelItemFetch();
            _invalidateSeasonsFetch()
            warmSnapshotVisible=false;
            _warmDetailSnapshot=null;
            fetchedOnce=true;
            item=null; castPeople=[]; seasons=[]; seasonsFetched=false; fallbackPosterUrl="";
            castHydrated=false; seasonsHydrated=false;
            posterLogoFailed=false;
            nextUpDurationText=""; nextUpEndText="";
            _resetAverageEpisodeDuration();
            bgUpdateTimer.restart();
            _releaseGatesImmediate();
            _schedulePokeRestore();
            _scheduleViewportGate();
            return;
        }
        _cancelItemFetch();
        _fetchToken++;
        var t = _fetchToken;
        fetchedOnce=true;
        fetchInFlight=true;
        var refreshingSameItem = !!(item && item.Id && String(item.Id) === String(itemId));
        _resetGates();
        _invalidateSeasonsFetch()
        seasonsFetched=false;
        if (!refreshingSameItem) seasons=[];
        seasonsHydrated=false; castHydrated=false;
        posterLogoFailed=false;
        nextUpDurationText=""; nextUpEndText="";
        _resetAverageEpisodeDuration();
        _useWarmDetailSnapshot();
        _fetchHandle = Jellyfin.fetchItem(serverUrl, accessToken, itemId,
            function(res){
                if (t!==_fetchToken) return;
                _fetchHandle=null;
                item = res;
                warmSnapshotVisible=false;
                _warmDetailSnapshot=null;
                _refreshActionButtonStates();
                _refreshAverageEpisodeDuration();
                castPeople = (res && res.People) ? res.People : [];
                fallbackPosterUrl = _buildFallbackPoster(res);
                castHydrated=false;
                seasonsHydrated=false;
                _syncPosterSources();
                _updatePosterGate();
                bgUpdateTimer.restart();
                if (!seasonsFetched && !seasonsFetchInFlight)
                    fetchSeasons()
                serverResponseSlow=false;
                gateItemReady=true;
                fetchInFlight=false;
                Qt.callLater(function(){
                    _updatePosterGate();
                    _updateBGGate();
                    _schedulePokeRestore();
                    _scheduleViewportGate();
                });
            },
            function(){
                if (t!==_fetchToken) return;
                _fetchHandle=null;
                if (!warmSnapshotVisible) {
                    item=null; castPeople=[]; seasons=[]; seasonsFetched=true; fallbackPosterUrl="";
                }
                serverResponseSlow=false;
                _resetAverageEpisodeDuration();
                castHydrated=false; seasonsHydrated=false;
                gateItemReady=true; gatePosterReady=true; gateBGReady=true; gateMinDelay=true;
                fetchInFlight=false;
                bgUpdateTimer.restart();
                _schedulePokeRestore();
                _scheduleViewportGate();
            }
        );
    }
    function _cancelItemFetch(){
        ++_fetchToken;
        var h = _fetchHandle;
        _fetchHandle = null;
        fetchInFlight = false;
        try { if (h && h.cancel) h.cancel("context_changed"); } catch(e) {}
    }
    Timer { id: fetchDebounce; interval: 80; repeat: false; onTriggered: fetchItemIfReady() }
    function scheduleFetch(){
        _cancelItemFetch()
        _invalidateSeasonsFetch()
        _resetAverageEpisodeDuration()
        fetchDebounce.restart()
    }
    Component.onCompleted: {
        _hydrateSensitiveContextFromShared();
        _consumePersonReturnRefreshMarker();
        // L'hydratation ci-dessus peut avoir déclenché plusieurs onXChanged et
        // donc armé fetchDebounce. L'appel immédiat ci-dessous possède déjà le
        // contexte final : supprimer ce doublon réduit fortement les fetchs
        // /Seasons concurrents à l'ouverture d'une fiche lourde.
        fetchDebounce.stop()
        fetchItemIfReady();
        Qt.callLater(function(){ uiReady=true;  rootFlick.contentY=0; _schedulePokeRestore(); _scheduleViewportGate();  });
    }
    Component.onDestruction: {
        _clearCastViewportRestore(false)
        try { playerNextUpRestoreTimer.stop(); } catch(eRestoreStop) {}
        _cancelItemFetch()
        _invalidateSeasonsFetch()
        _cancelSeriesPlaylistFetch("destroyed")
        _resetAverageEpisodeDuration()
    }
    onVisibleChanged: {
        if (visible) {
            var hydrated = _hydrateSensitiveContextFromShared()
            _consumePersonReturnRefreshMarker()
            if (hydrated || (accessToken && userId && serverUrl && itemId))
                scheduleFetch() // detailserie-visible
        } else {
            if (_isPersonArmActive())
                _personReturnGate = true
        }
    }

    onSharedChanged: {
        var hydrated = _hydrateSensitiveContextFromShared()
        _consumePersonReturnRefreshMarker()
        if (hydrated)
            scheduleFetch();
    }
    onAccessTokenChanged: { _cancelSeriesPlaylistFetch("context_changed"); scheduleFetch() }
    onUserIdChanged: { _cancelSeriesPlaylistFetch("context_changed"); scheduleFetch() }
    onServerUrlChanged: { _cancelSeriesPlaylistFetch("context_changed"); scheduleFetch() }
    onItemIdChanged: {
        _clearCastViewportRestore(true)
        _cancelPendingFocusNavigation()
        _resetHeavy()
        _consumePersonReturnRefreshMarker()
        _cancelSeriesPlaylistFetch("context_changed")
        scheduleFetch();
        posterFxTimer.stop();
        posterFxReady=false;
        posterLogoFailed=false;
        nextUpDurationText=""; nextUpEndText="";
    }
    onActiveFocusChanged: {
        if (activeFocus)
        if (activeFocus && didInitialFocus) _schedulePokeRestore();
    }
    onSeriesLogoUrlChanged: Qt.callLater(function(){ posterLogoFailed=false; _syncPosterSources(); _updatePosterGate(); })
    onSeriesCoverUrlChanged: { _clearPosterHq(); Qt.callLater(function(){ _syncPosterSources(); _updatePosterGate(); if (posterFocus && posterFocus.activeFocus) _schedulePosterHq(); }) }
    Rectangle { anchors.fill: parent; color: "#000"; z: -3 }
    Item {
        id: backdrop
        anchors.fill: parent
        z: -2
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
                if (loadToken !== backdrop._token) return;
                if (status===Image.Ready) { backdrop.lastFull=String(source || ""); backdrop.loadingFull=""; opacity=0.90; gateBGReady=true; }
                else if (status===Image.Error) { backdrop.loadingFull=""; opacity=0.0; gateBGReady=true; }
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
                lastFull="";
                loadingFull="";
                if (String(bgImg.source || "") !== "") bgImg.source="";
                bgImg.opacity=0.0;
                gateBGReady=true;
                return;
            }
            var ful = computeFullUrl();
            if (ful===lastFull || ful===loadingFull) { _updateBGGate(); return; }
            loadingFull = ful;
            _token += 1;
            bgImg.loadToken = _token;
            gateBGReady=false;
            if (String(bgImg.source || "") !== String(ful || "")) bgImg.source=ful;
            _updateBGGate();
        }
    }
    Item {
        id: mainLayer
        anchors.fill: parent
        z: 1
        opacity: visualLoading ? 0.0 : 1.0
        y: visualLoading ? 10 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Components.ClockHUD {
            id: clockHud
            z: 50
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.rightMargin: 24
            readonly property real _t: {
                var y = rootFlick ? Number(rootFlick.contentY || 0) : 0;
                var t = (y - 30) / 220;
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                return t;
            }
            anchors.topMargin: (20 + tuneTopHudShiftY) - Math.round(8 * _t)
            opacity: 1.0 - _t
            Behavior on anchors.topMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            fbx: detailSeriePage.fbx
            serverUrl: detailSeriePage.serverUrl
            userId: detailSeriePage.userId
            userImageTag: detailSeriePage.userImageTag
            userName: detailSeriePage.userName
            showUserName: true
            flick: rootFlick
            visible: uiReady && !visualLoading && overlayMode==="none"
            active: visible
            enabled: visible
            hudOpacity: opacity
            scrolling: rootFlick && (rootFlick.moving || rootFlick.dragging)
            showAvatar: true
            avatarSize: 52
            fontPx: 22
            avatarFocus: (currentFocus===focusHud)
            focus: (currentFocus===focusHud)
        }
        Connections {
            target: clockHud
            ignoreUnknownSignals: true
            onRequestFocusBelow: restoreFocusFromHud()
            onRequestOpenProfile: gotoSelectProfile()
            onAvatarActivated: gotoSelectProfile()
            onActivated: gotoSelectProfile()
        }
        function safeRowHeight(){
            try { if (overviewBox) return Math.max(posterH, overviewBox.height + 40); } catch(e) {}
            return Math.max(posterH, 230);
        }
        Flickable {
            id: rootFlick
            anchors.fill: parent
            clip: true
            interactive: (overlayMode==="none") && !visualLoading
            contentWidth: width
            contentHeight: pageColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            function scrollToTop(jump){
                if (jump) detailSeriePage._jumpContentY(0);
                else contentY = 0;
            }
            Behavior on contentY {
                enabled: scrollAnimEnabled && !isRestoring && !visualLoading && !rootFlick.moving && !rootFlick.dragging
                NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
            }
            onContentYChanged: {  _scheduleViewportGate(); }
            onHeightChanged: {  _scheduleViewportGate(); }
            onWidthChanged: {  _scheduleViewportGate(); }
            Keys.onPressed: {
                if (event.key===Qt.Key_Up) {
                    if (currentFocus===6) {
                        currentFocus = 1;
                        ensureItemVisible(actionsBlock, 40);
                        actionsBlock.focusFirst();
                        event.accepted = true;
                        return;
                    }
                    if (currentFocus===3) {
                        if (hasSeasons()) { currentFocus=5; focusSeasons(); }
                        else if (hasNextUpContent()) { currentFocus=6; focusNextUp(); }
                        else goUpToResume();
                        event.accepted=true;
                    }
                    else if (currentFocus===5) {
                        if (hasNextUpContent()) { currentFocus=6; focusNextUp(); }
                        else goUpToResume();
                        event.accepted=true;
                    }
                    else if (currentFocus===4) {
                        if (hasCast()) { currentFocus=3; focusCast(); }
                        else if (hasSeasons()) { currentFocus=5; focusSeasons(); }
                        else if (hasNextUpContent()) { currentFocus=6; focusNextUp(); }
                        else goUpToResume();
                        event.accepted=true;
                    } else {
                        event.accepted=false;
                    }
                } else if (event.key===Qt.Key_Down) {
                    if (currentFocus===6) {
                        goDownFromNextUp();
                        event.accepted=true;
                        return;
                    }
                    else if (currentFocus===5) {
                        if (hasCast()) {
                            currentFocus=3; focusCast();
                        } else if (hasSimilarContent()) {
                            currentFocus=4; _restoreSimilarFocusIfAny();
                        } else {
                            currentFocus=4;
                            if (!heavyStageSimilar) heavyStageSimilar=true;
                            _armPendingFocus("similar");
                        }
                        event.accepted=true;
                    }
                    else if (currentFocus===3) {
                        if (hasSimilarContent()) {
                            currentFocus=4; _restoreSimilarFocusIfAny(); event.accepted=true;
                        } else {
                            currentFocus=4;
                            if (!heavyStageSimilar) heavyStageSimilar=true;
                            _armPendingFocus("similar");
                            event.accepted=true;
                        }
                    } else {
                        event.accepted=false;
                    }
                } else {
                    event.accepted=false;
                }
            }
            Column {
                id: pageColumn
                width: rootFlick.width
                spacing: sectionsSpacing
                anchors.top: parent.top
                anchors.topMargin: contentTopGap
                Item {
                    id: headerSlot
                    width: parent.width
                    implicitHeight: headerBlock.implicitHeight + Math.max(0, tuneHeaderShiftY)
                    height: implicitHeight
                    Column {
                        id: headerBlock
                        x: Math.max(marginL, headerX)
                        y: tuneHeaderShiftY
                        spacing: 6
                        width: headerSlot.width - x - marginR
                        Text { textFormat: Text.PlainText;
                            text: hasItem ? item.Name : ""
                            font.pixelSize: 38
                            font.bold: true
                            color: "#FFFFFF"
                            wrapMode: Text.WordWrap
                            visible: hasItem
                        }
                        Row {
                            id: headerMetaRow
                            spacing: 12
                            visible: hasItem
                            width: headerBlock.width
                            clip: true
                            Row {
                                spacing: 6
                                height: 28
                                visible: hasCommunityRating

                                Text { textFormat: Text.PlainText;
                                    text: "★"
                                    color: "#FFC53F"
                                    font.pixelSize: 20
                                    font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Text { textFormat: Text.PlainText;
                                    text: communityRatingText
                                    color: "#FFFFFF"
                                    font.pixelSize: 18
                                    font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            Item {
                                id: yearInlineBox
                                visible: yearText.length > 0
                                width: yearHasRange ? yearRangeRow.implicitWidth : yearSingleText.implicitWidth
                                height: 28
                                Text { textFormat: Text.PlainText;
                                    id: yearSingleText
                                    visible: !yearHasRange
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: yearStartText
                                    color: "#FFFFFF"
                                    font.pixelSize: 20
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Row {
                                    id: yearRangeRow
                                    visible: yearHasRange
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 7
                                    Text { textFormat: Text.PlainText;
                                        text: yearStartText
                                        height: 28
                                        color: "#FFFFFF"
                                        font.pixelSize: 20
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    Canvas {
                                        id: yearRangeArrow
                                        width: 36
                                        height: 28
                                        antialiasing: true
                                        renderTarget: Canvas.Image
                                        readonly property real arrowOpacity: 0.92
                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.reset()
                                            ctx.clearRect(0, 0, width, height)
                                            var y = Math.round(height / 2) + 0.5
                                            var c = "rgba(255,255,255," + arrowOpacity + ")"
                                            ctx.strokeStyle = c
                                            ctx.lineWidth = 2
                                            ctx.lineCap = "round"
                                            ctx.lineJoin = "round"
                                            ctx.beginPath()
                                            ctx.moveTo(4, y)
                                            ctx.lineTo(25, y)
                                            ctx.stroke()
                                            ctx.fillStyle = c
                                            ctx.beginPath()
                                            ctx.moveTo(25, y - 6)
                                            ctx.lineTo(33, y)
                                            ctx.lineTo(25, y + 6)
                                            ctx.closePath()
                                            ctx.fill()
                                        }
                                        Component.onCompleted: requestPaint()
                                    }
                                    Text { textFormat: Text.PlainText;
                                        text: yearEndText
                                        height: 28
                                        color: "#FFFFFF"
                                        font.pixelSize: 20
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                            Rectangle {
                                visible: statusText.length > 0
                                radius: 7
                                height: 28
                                color: statusTagFill
                                border.width: 1
                                border.color: statusTagBorder
                                width: Math.max(70, statusTxt.implicitWidth + 18)
                                antialiasing: false
                                Text { textFormat: Text.PlainText;
                                    id: statusTxt
                                    anchors.centerIn: parent
                                    text: statusText
                                    color: "#FFFFFF"
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                            }
                            Rectangle {
                                visible: hasOfficialRating
                                radius: 8
                                height: 26
                                color: "#26304f"
                                border.width: 1
                                border.color: "#33406a"
                                width: Math.max(44, officialTxt.implicitWidth + 16)
                                antialiasing: false
                                Text { textFormat: Text.PlainText;
                                    id: officialTxt
                                    anchors.centerIn: parent
                                    text: officialRatingText
                                    color: "#FFFFFF"
                                    font.pixelSize: 13
                                    font.bold: true
                                }
                            }
                        }
                        Text { textFormat: Text.PlainText;
                            id: genresText
                            visible: hasItem && genresLine.length > 0
                            text: genresLine
                            color: infoValueColor
                            font.pixelSize: 18
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                            width: headerBlock.width
                        }
                    }
                }
                Item {
                    id: heroSlot
                    width: parent.width
                    implicitHeight: rowBlock.height + Math.max(0, tuneHeroShiftY)
                    height: implicitHeight
                    Item {
                        id: rowBlock
                        width: heroSlot.width
                        height: mainLayer.safeRowHeight()
                        y: tuneHeroShiftY
                        Column {
                            id: infoCol
                            width: infoW
                            x: infoLeft + tuneInfoColShiftX
                            y: tuneInfoColShiftY
                            visible: hasItem
                            spacing: 10
                            Column {
                                spacing: 1
                                Text { textFormat: Text.PlainText;
                                    width: infoW
                                    horizontalAlignment: Text.AlignRight
                                    text: "SAISONS"
                                    color: "#FFFFFF"
                                    font.pixelSize: 16
                                    font.bold: true
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                                Text { textFormat: Text.PlainText;
                                    width: infoW
                                    horizontalAlignment: Text.AlignRight
                                    text: seasonsCountText
                                    color: infoValueColor
                                    font.pixelSize: 15
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                            }
                            Column {
                                spacing: 1
                                visible: averageEpisodeDurationText.length > 0
                                Text { textFormat: Text.PlainText;
                                    width: infoW
                                    horizontalAlignment: Text.AlignRight
                                    text: "DURÉE"
                                    color: "#FFFFFF"
                                    font.pixelSize: 16
                                    font.bold: true
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                                Text { textFormat: Text.PlainText;
                                    width: infoW
                                    horizontalAlignment: Text.AlignRight
                                    text: averageEpisodeDurationText
                                    color: infoValueColor
                                    font.pixelSize: 15
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                            }
                            Column {
                                spacing: 1
                                visible: nextUpEndText.length > 0
                                Text { textFormat: Text.PlainText;
                                    width: infoW
                                    horizontalAlignment: Text.AlignRight
                                    text: "FIN"
                                    color: "#FFFFFF"
                                    font.pixelSize: 16
                                    font.bold: true
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                                Text { textFormat: Text.PlainText;
                                    width: infoW
                                    horizontalAlignment: Text.AlignRight
                                    text: nextUpEndText
                                    color: infoValueColor
                                    font.pixelSize: 15
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        FocusScope {
                            id: actionsBlock
                            width: infoW + 40
                            x: infoLeft
                            y: playBtnTopExtra + tuneActionsShiftY
                            height: playBtnSize + 38
                            focus: currentFocus===1
                            property string hint: ""
                            function buttons(){ return [playBtn, shuffleBtn, seenBtn, likeBtn]; }
                            function focusFirst(){
                                var bs=buttons();
                                for (var i=0;i<bs.length;i++) if (bs[i]) { currentFocus=1; bs[i].forceActiveFocus(); return; }
                            }
                            function _keyDown(e){
                                if (e.key===Qt.Key_Down) { goDownPref(); e.accepted=true; }
                                else if (e.key===Qt.Key_Up) { goUpToResume(); e.accepted=true; }
                            }
                            Row {
                                id: actionsRow
                                spacing: 18
                                Components.GlassCircleButton {
                                    id: playBtn
                                    width: playBtnSize; height: playBtnSize
                                    actionType: "play"
                                    tintColor: glassBase
                                    focusRingColor: "#FFFFFF"
                                    hintMode: "none"
                                    onTriggered: playAllFromStart()
                                    KeyNavigation.right: shuffleBtn
                                    KeyNavigation.left: likeBtn
                                    onActiveFocusChanged: if (activeFocus) actionsBlock.hint="Tout lire"
                                    Keys.onPressed: actionsBlock._keyDown(event)
                                }
                                Components.GlassCircleButton {
                                    id: shuffleBtn
                                    width: playBtnSize; height: playBtnSize
                                    actionType: "shuffle"
                                    tintColor: glassBase
                                    focusRingColor: "#FFFFFF"
                                    hintMode: "none"
                                    onTriggered: playRandomEpisode()
                                    KeyNavigation.right: seenBtn
                                    KeyNavigation.left: playBtn
                                    onActiveFocusChanged: if (activeFocus) actionsBlock.hint="Lecture aléatoire"
                                    Keys.onPressed: actionsBlock._keyDown(event)
                                }
                                Components.GlassCircleButton {
                                    id: seenBtn
                                    width: playBtnSize; height: playBtnSize
                                    actionType: "toggleSeen"
                                    checkable: true
                                    checked: !!(item && item.UserData && item.UserData.Played)
                                    getState: function(){ return !!(item && item.UserData && item.UserData.Played); }
                                    setState: function(v){ setSeriesPlayed(v); }
                                    tintColor: glassBase
                                    tintColorChecked: "#FF3B30"
                                    focusRingColor: "#FFFFFF"
                                    hintMode: "none"
                                    KeyNavigation.right: likeBtn
                                    KeyNavigation.left: shuffleBtn
                                    function _h(){ return checked ? "Marquer non vu" : "Marquer vu"; }
                                    onTriggered: setSeriesPlayed(checked)
                                    onActiveFocusChanged: if (activeFocus) actionsBlock.hint=_h()
                                    onCheckedChanged: if (activeFocus) actionsBlock.hint=_h()
                                    Component.onCompleted: checked = getState()
                                    Keys.onPressed: actionsBlock._keyDown(event)
                                }
                                Components.GlassCircleButton {
                                    id: likeBtn
                                    width: playBtnSize; height: playBtnSize
                                    actionType: "toggleLike"
                                    checkable: true
                                    checked: !!(item && item.UserData && item.UserData.IsFavorite)
                                    getState: function(){ return !!(item && item.UserData && item.UserData.IsFavorite); }
                                    setState: function(v){ setSeriesFavorite(v); }
                                    tintColor: glassBase
                                    tintColorChecked: "#FF3B30"
                                    focusRingColor: "#FFFFFF"
                                    hintMode: "none"
                                    KeyNavigation.right: playBtn
                                    KeyNavigation.left: seenBtn
                                    function _h(){ return checked ? "Retirer favori" : "Favori"; }
                                    onTriggered: setSeriesFavorite(checked)
                                    onActiveFocusChanged: if (activeFocus) actionsBlock.hint=_h()
                                    onCheckedChanged: if (activeFocus) actionsBlock.hint=_h()
                                    Component.onCompleted: checked = getState()
                                    Keys.onPressed: actionsBlock._keyDown(event)
                                }
                            }
                            Text { textFormat: Text.PlainText;
                                anchors.top: actionsRow.bottom
                                anchors.topMargin: 14
                                anchors.horizontalCenter: actionsRow.horizontalCenter
                                width: Math.max(actionsRow.implicitWidth, (playBtnSize*4 + actionsRow.spacing*3))
                                horizontalAlignment: Text.AlignHCenter
                                color: "#DDE1F6"
                                font.pixelSize: 12
                                text: actionsBlock.hint
                                elide: Text.ElideRight
                                visible: currentFocus===1 && text.length>0
                            }
                        }
                        FocusScope {
                            id: overviewBox
                            x: (infoLeft + infoW + 24) - 110
                            y: (-20 + tuneOverviewShiftY)
                            width: rowBlock.width - x - (posterW + posterEdgeGap + marginR + 24)
                            height: 230
                            visible: overviewVisible
                            focus: currentFocus===0
                            property bool focused: (currentFocus===0 || activeFocus)
                            scale: focused ? 1.012 : 1.0
                            transformOrigin: Item.Center
                            Behavior on scale {
                                enabled: !rootFlick.moving && !rootFlick.dragging
                                NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                            }
                            Rectangle {
                                anchors.fill: parent
                                radius: 12
                                color: overviewBox.focused ? glassFocus : "transparent"
                                border.width: overviewBox.focused ? 1 : 0
                                border.color: overviewBox.focused ? glassBorder : "transparent"
                                antialiasing: overviewBox.focused && aaEdges // Tweak E
                            }
                            Text {
                                anchors.fill: parent
                                anchors.margins: 14
                                color: "#FFFFFF"
                                font.pixelSize: 22
                                wrapMode: Text.WordWrap
                                text: (hasItem && item.Overview) ? item.Overview : ""
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                maximumLineCount: 7
                            }
                            Keys.onPressed: {
                                if (event.key===Qt.Key_Right) { currentFocus=2; posterFocus.forceActiveFocus(); event.accepted=true; }
                                else if (event.key===Qt.Key_Left) { currentFocus=1; actionsBlock.focusFirst(); event.accepted=true; }
                                else if (event.key===Qt.Key_Up) { goTopBarFocus(); event.accepted=true; }
                                else if (event.key===Qt.Key_Down) { currentFocus=1; actionsBlock.focusFirst(); event.accepted=true; }
                                else if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Select) { openOverviewOverlay(); event.accepted=true; }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { currentFocus=0; overviewBox.forceActiveFocus(); openOverviewOverlay(); }
                            }
                        }
                        FocusScope {
                            id: posterFocus
                            width: posterW
                            height: posterH
                            x: rowBlock.width - (marginR + posterEdgeGap + width)
                            y: (posterTopOffset + tunePosterShiftY)
                            visible: hasItem
                            focus: currentFocus===2
                            property bool focused: (currentFocus===2 || activeFocus)
                            onActiveFocusChanged: {
                                if (activeFocus) _schedulePosterHq()
                                else _clearPosterHq()
                            }
                            Keys.onPressed: {
                                if (event.key===Qt.Key_Left) {
                                    if (overviewVisible) { currentFocus=0; ensureItemVisible(overviewBox,20); overviewBox.forceActiveFocus(); }
                                    else { currentFocus=1; actionsBlock.focusFirst(); }
                                    event.accepted=true;
                                }
                                else if (event.key===Qt.Key_Down) { goDownPref(); event.accepted=true; }
                                else if (event.key===Qt.Key_Up) { goTopBarFocus(); event.accepted=true; }
                                else if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Select) { openPosterOverlay(); event.accepted=true; }
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: { currentFocus=2; posterFocus.forceActiveFocus(); }
                                onClicked: { currentFocus=2; posterFocus.forceActiveFocus(); openPosterOverlay(); }
                            }
                            Item {
                                id: posterImgLayer
                                anchors.fill: parent
                                anchors.margins: frameMargin()
                                clip: true
                                // PERF Freebox: suppression du layer OpacityMask poster.
                                // Le cadre arrondi reste overlay ; l'image est clipée rectangulairement sans offscreen GPU.
                                scale: posterFocus.focused ? 1.06 : 1.0
                                transformOrigin: Item.Center
                                Behavior on scale {
                                    enabled: !rootFlick.moving && !rootFlick.dragging
                                    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                                }
                                Image {
                                    id: posterPrimary
                                    anchors.fill: parent
                                    asynchronous: true
                                    cache: true
                                    mipmap: false
                                    smooth: !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking)) // Poster lissé au repos, focusé ou non
                                    fillMode: Image.PreserveAspectCrop
                                    source: ""
                                    opacity: (posterLogo.status===Image.Ready && !posterLogoFailed && seriesLogoUrl!=="") ? 0.0 : 1.0
                                    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                    onStatusChanged: {
                                        _updatePosterGate()
                                        if (status === Image.Ready && posterFocus.activeFocus) _schedulePosterHq()
                                    }
                                }
                                Image {
                                    id: posterPrimaryHq
                                    anchors.fill: parent
                                    asynchronous: true
                                    cache: false
                                    mipmap: false
                                    smooth: !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                    fillMode: Image.PreserveAspectCrop
                                    source: (posterHqArmed && posterFocus.activeFocus && posterPrimary.status === Image.Ready
                                             && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                             && detailSeriePage._posterCoverVisible())
                                            ? seriesCoverHqUrl : ""
                                    visible: source !== "" && status === Image.Ready
                                    opacity: visible ? 1.0 : 0.0
                                    Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                }
                                Image {
                                    id: posterLogo
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: tunePosterLogoShiftY
                                    width: parent.width*0.90
                                    height: parent.height*0.90
                                    asynchronous: true
                                    cache: true
                                    mipmap: false
                                    smooth: posterFocus.focused && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking)) // Tweak D
                                    fillMode: Image.PreserveAspectFit
                                    source: ""
                                    opacity: (seriesLogoUrl!=="" && !posterLogoFailed && status===Image.Ready) ? 1.0 : 0.0
                                    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                    onStatusChanged: {
                                        if (status===Image.Error) { posterLogoFailed=true; _syncPosterSources(); }
                                        _updatePosterGate();
                                    }
                                }
                                Component.onCompleted: _syncPosterSources()
                            }
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: frameMargin() + 0.5
                                radius: Math.max(0, Math.round(Math.min(width, height) * frameRadiusRatio) - 0.5)
                                color: "transparent"
                                border.width: posterFocus.focused ? 1 : 0
                                border.color: posterFocus.focused ? glassBorder : glassBorderDim
                                antialiasing: posterFocus.focused && aaEdges // Tweak E
                            }
                        }
                    }
                }
                Item {
                    id: nextUpSlot
                    width: parent.width
                    implicitHeight: nextUpLoader.height + Math.max(0, tuneNextUpShiftY)
                    height: implicitHeight
                    Loader {
                        id: nextUpLoader
                        width: parent.width
                        y: tuneNextUpShiftY
                        asynchronous: true
                        active: hasItem && heavyStageNextUp
                        source: active ? Qt.resolvedUrl("NextUpBlock.qml") : ""
                        visible: status===Loader.Ready
                        height: (status===Loader.Ready && nextUpLoader.item && nextUpLoader.item.hasContent===true) ? (nextUpLoader.item.implicitHeight||0) : 0
                        onStatusChanged: {
                            _updateExtendedSectionGates();
                            if (_playerNextUpRestorePending) {
                                _playerNextUpRestoreStableTicks = 0;
                                _schedulePlayerNextUpRestore(24);
                            }
                        }
                        onHeightChanged: _updateExtendedSectionGates()
                        onLoaded: {
                            wireNextUpLoader();
                            _updateExtendedSectionGates();
                            if (_playerNextUpRestorePending) {
                                _playerNextUpRestoreItem = null;
                                _playerNextUpRestoreStableTicks = 0;
                                _schedulePlayerNextUpRestore(24);
                            }
                        }
                    }
                }
                Item {
                    id: seasonsSlot
                    width: parent.width

                    // Le loader Saisons est actuellement remonté via
                    // tuneSeasonsShiftY (-30). Le slot doit suivre ce décalage,
                    // sinon il conserve ~30 px de vide sous les posters avant
                    // "Distribution et équipe".
                    implicitHeight: Math.max(0, seasonsLoader.height + tuneSeasonsShiftY)
                    height: implicitHeight
                    Loader {
                        id: seasonsLoader
                        width: parent.width
                        y: tuneSeasonsShiftY
                        asynchronous: true
                        active: (seasons && seasons.length>0) && heavyStageSeasons
                        source: active ? Qt.resolvedUrl("SeasonsBlock.qml") : ""
                        visible: status===Loader.Ready
                        height: (status===Loader.Ready && seasonsLoader.item) ? Math.max((seasonsLoader.item.implicitHeight||0), 140) : 0
                        onStatusChanged: { _updateExtendedSectionGates(); }
                        onHeightChanged: _updateExtendedSectionGates()
                        onLoaded: {
                            wireSeasonsLoader()
                            _updateExtendedSectionGates()
                        }
                    }
                }
                Item {
                    id: castTitleSlot
                    width: parent.width
                    implicitHeight: (castPeople && castPeople.length > 0 && heavyStageCast)
                        ? (24 + Math.max(0, tuneCastShiftY))
                        : 0
                    height: implicitHeight
                    visible: implicitHeight > 0
                    Item {
                        width: parent.width
                        height: 24
                        y: tuneCastShiftY
                        Text { textFormat: Text.PlainText;
                            text: "Distribution et équipe"
                            color: "#FFFFFF"
                            font.pixelSize: 19
                            font.bold: true
                            anchors.left: parent.left
                            anchors.leftMargin: 28
                        }
                    }
                }
                Item {
                    id: castSlot
                    width: parent.width
                    implicitHeight: castPageLoader.height + Math.max(0, tuneCastShiftY)
                    height: implicitHeight
                    Loader {
                        id: castPageLoader
                        width: parent.width
                        y: tuneCastShiftY
                        asynchronous: true
                        active: (castPeople.length>0) && heavyStageCast
                        source: active ? Qt.resolvedUrl("CastPage.qml") : ""
                        visible: status===Loader.Ready
                        height: (status===Loader.Ready && castPageLoader.item) ? (castPageLoader.item.implicitHeight||0) : 0
                        onStatusChanged: {
                            if (_castViewportRestorePending && !castViewportRestoreTimer.running)
                                castViewportRestoreTimer.restart()
                        }
                        onHeightChanged: {
                            if (_castViewportRestorePending) {
                                _castViewportRestoreStableTicks = 0
                                if (!castViewportRestoreTimer.running)
                                    castViewportRestoreTimer.restart()
                            }
                        }
                        onLoaded: {
                            wireCastLoader()
                            if (_castViewportRestorePending && !castViewportRestoreTimer.running)
                                castViewportRestoreTimer.restart()
                        }
                    }
                }
                Item {
                    id: similarTitleSlot
                    width: parent.width
                    implicitHeight: (heavyStageSimilar && similarReadyNoContent()) ? (24 + Math.max(0, tuneSimilarShiftY)) : 0
                    height: implicitHeight
                    visible: implicitHeight > 0
                    Item {
                        width: parent.width
                        height: 24
                        y: tuneSimilarShiftY
                        Text { textFormat: Text.PlainText;
                            text:"Plus comme ceci"
                            color:"#FFFFFF"
                            font.pixelSize:19
                            font.bold:true
                            anchors.left: parent.left
                            anchors.leftMargin: 28
                        }
                    }
                }
                Item {
                    id: similarSlot
                    width: parent.width
                    implicitHeight: similarLoader.height + Math.max(0, tuneSimilarShiftY)
                    height: implicitHeight
                    Loader {
                        id: similarLoader
                        width: parent.width
                        y: tuneSimilarShiftY
                        asynchronous: true
                        active: hasItem && heavyStageSimilar
                        source: active ? Qt.resolvedUrl("SimilarItems.qml") : ""
                        visible: status===Loader.Ready && similarLoader.item && similarLoader.item.hasContent===true
                        height: (status===Loader.Ready && similarLoader.item && similarLoader.item.hasContent===true) ? Math.max((similarLoader.item.implicitHeight||0), 283) : 0
                        onLoaded: wireSimilarLoader()
                    }
                }
                Item { id: similarBottomProbe; width: 1; height: 40 }
                Item { width: parent.width; height: 80 }
            }
        }
    }
    Connections {
        target: nextUpLoader.item
        ignoreUnknownSignals: true
        onHasContentChanged: {
            gateNextUpReady = true;
            requestSaveFocusSnapshot();
            _updateNextUpMeta();
            _schedulePokeRestore();
            if (_playerNextUpRestorePending) _schedulePlayerNextUpRestore(24);
        }
        onCurrentIndexChanged: { requestSaveFocusSnapshot(); _updateNextUpMeta(); }
        onActiveFocusChanged: {
            if (target && target.activeFocus) {
                currentFocus = 6;
                requestSaveFocusSnapshot();
                if (_playerNextUpRestorePending) _schedulePlayerNextUpRestore(24);
            }
        }
        onRequestPlayRequested: function(epId, epTitle){
            currentFocus = 6;
            armMemo("player");
            flushSaveFocusSnapshotNow();
            _storeSensitiveNavContext();
            if (epId && requestPlay) requestPlay(epId, accessToken, userId, serverUrl, epTitle || "");
        }
    }
    Connections {
        target: seasonsLoader.item && seasonsLoader.item.grid ? seasonsLoader.item.grid : null
        ignoreUnknownSignals: true
        onActiveFocusChanged: {  if (target && target.activeFocus) { currentFocus = 5; requestSaveFocusSnapshot();  } }
        onCurrentIndexChanged: {  requestSaveFocusSnapshot(); }
        onCountChanged: {
            _updateExtendedSectionGates()
        }
    }
    Connections {
        target: seasonsLoader.item
        ignoreUnknownSignals: true
        onActiveFocusChanged: {  if (seasonsLoader.item && seasonsLoader.item.activeFocus) { currentFocus = 5; requestSaveFocusSnapshot();  } }
        onImplicitHeightChanged: _updateExtendedSectionGates()
        onOpenSeasonRequested: function(seasonObj){
            if (!seasonObj || !seasonObj.Id || !requestNavigation) return;
            armMemo("season");
            flushSaveFocusSnapshotNow();
            requestNavigation(_navRoute("seasonpage.qml", { seasonId: seasonObj.Id }));
        }
    }
    Connections {
        target: castPageLoader.item
        ignoreUnknownSignals: true
        onActiveFocusChanged: {
            if (castPageLoader.item && castPageLoader.item.activeFocus) {
                currentFocus = 3;
                requestSaveFocusSnapshot();
            }
        }
        onLastFocusedIndexChanged: requestSaveFocusSnapshot()
        onActorActivated: function(personObj){ openPersonPage(personObj); }
    }
    Connections {
        target: similarLoader.item
        ignoreUnknownSignals: true
        onLastFocusedIndexChanged: requestSaveFocusSnapshot()
        onHasContentChanged: { requestSaveFocusSnapshot(); _schedulePokeRestore(); _scheduleViewportGate(); }
        onOpenItemRequested: function(newItemId, newItemType){
            if (!newItemId || !requestNavigation) return;
            flushSaveFocusSnapshotNow();
            var t = (newItemType || "").toString();
            var page = (t === "Series" || t === "" ) ? "detailSeriePage.qml" : "detailMoviePage.qml";
            requestNavigation(_navRoute(page, {
                itemId: newItemId,
                itemType: (t && t !== "Series") ? t : ""
            }));
        }
    }
    function wireCastLoader(){
        var it = castPageLoader.item; if(!it) return;
        it.people = castHydrated ? castPeople : castPeople.slice(0, castInitialLimit);
        it.serverUrl = serverUrl; it.accessToken=accessToken; it.userId=userId;
        it.userName=userName; it.userImageTag=userImageTag; it.fbx=fbx;
        SeasonUtils.applyBlockPerf(it);
        _schedulePokeRestore();
    }
    function wireSeasonsLoader(){
        var it = seasonsLoader.item; if(!it) {  return; }
        it.seasons = seasonsFetched ? seasons : []
        it.serverUrl = serverUrl;
        if (it.hasOwnProperty("fallbackPosterUrl")) it.fallbackPosterUrl = fallbackPosterUrl;
        SeasonUtils.applyBlockPerf(it);
        _schedulePokeRestore();
    }
    function wireSimilarLoader(){
        var it = similarLoader.item; if(!it) return;
        it.item=item; it.serverUrl=serverUrl; it.accessToken=accessToken; it.userId=userId; it.fbx=fbx;
        SeasonUtils.applyBlockPerf(it);
        if (it.fetchSimilarIfReady) Qt.callLater(it.fetchSimilarIfReady);
        _schedulePokeRestore();
        _scheduleViewportGate();
    }
    function wireNextUpLoader(){
        var it = nextUpLoader.item; if(!it) return;
        it.serverUrl=serverUrl;
        it.accessToken=accessToken;
        it.userId=userId;
        it.seriesId=_seriesId();
        it.fbx=fbx;
        if (it.hasOwnProperty("fallbackPosterUrl")) it.fallbackPosterUrl = fallbackPosterUrl;
        if (it.hasOwnProperty("seriesScopedOnly")) it.seriesScopedOnly = true;
        try {
            var restoreSnap = _getFocusSnapshot();
            var restoreId = preselectEpisodeId
                    || (_playerNextUpRestorePending ? _playerNextUpRestoreId : "")
                    || (restoreSnap ? (restoreSnap.nextUpEpisodeId || "") : "");
            if (restoreSnap && (restoreSnap.section|0) === 6 && it.setRestoreAnchor)
                it.setRestoreAnchor(restoreId,
                                    restoreSnap.nextUpIndex !== undefined ? (restoreSnap.nextUpIndex|0) : -1,
                                    restoreSnap.nextUpEpisodeSnapshot || null);
            else if (restoreId && it.setRestoreAnchor)
                it.setRestoreAnchor(restoreId, _playerNextUpRestoreFallbackIndex, null);
        } catch(eNextAnchor) {}
        it.requestFocusAbove = function(){
            currentFocus = 1;
            ensureItemVisible(actionsBlock, 40);
            actionsBlock.focusFirst();
        };
        it.requestFocusBelow = function(){
            goDownFromNextUp();
        };
        SeasonUtils.applyBlockPerf(it);
        if (it.refetch) Qt.callLater(it.refetch);
        else if (it.fetchNextUpIfReady) Qt.callLater(it.fetchNextUpIfReady);
        Qt.callLater(function(){
            _updateNextUpMeta();
            _schedulePokeRestore();
            if (_playerNextUpRestorePending) _schedulePlayerNextUpRestore(24);
        });
    }
    function _applySeriesUserDataFlag(flag, value){
        if (!item) return;
        var ud = item.UserData || {};
        ud[flag] = !!value;
        item.UserData = ud;
        try {
            if (flag === "Played" && seenBtn) seenBtn.checked = !!value;
            else if (flag === "IsFavorite" && likeBtn) likeBtn.checked = !!value;
        } catch(e) {}
    }
    function _refreshActionButtonStates(){
        try { if (seenBtn) seenBtn.checked = !!(item && item.UserData && item.UserData.Played); } catch(e1) {}
        try { if (likeBtn) likeBtn.checked = !!(item && item.UserData && item.UserData.IsFavorite); } catch(e2) {}
    }
    /* ===== Lecture / state ===== */
    function playAllFromStart(){
        var sid=_seriesId();  if(!sid) return;
        armMemo("player");
        flushSaveFocusSnapshotNow();
        _storeSensitiveNavContext();
        if (!Jellyfin.fetchSeriesPlayableEpisodeIds) {  return; }
        _cancelSeriesPlaylistFetch("replaced")
        var requestHandle = null
        requestHandle = Jellyfin.fetchSeriesPlayableEpisodeIds(serverUrl, accessToken, userId, sid,
            function(ids){
                if (_seriesPlaylistHandle === requestHandle) _seriesPlaylistHandle = null
                if (!ids || !ids.length) return;
                if (requestPlayList) {  requestPlayList(ids, accessToken, userId, serverUrl, itemTitle || "Lecture série"); }
                else if (requestPlay) {  requestPlay(ids[0], accessToken, userId, serverUrl, itemTitle || ""); }
            }, function(err){ if (_seriesPlaylistHandle === requestHandle) _seriesPlaylistHandle = null }
        );
        _seriesPlaylistHandle = requestHandle
    }

    function playRandomEpisode(){
        var sid=_seriesId();  if(!sid) return;
        armMemo("player");
        flushSaveFocusSnapshotNow();
        _storeSensitiveNavContext();
        if (!Jellyfin.buildRandomPlayableSeriesPlaylist) {  return; }
        _cancelSeriesPlaylistFetch("replaced")
        var requestHandle = null
        requestHandle = Jellyfin.buildRandomPlayableSeriesPlaylist(serverUrl, accessToken, userId, sid,
            function(ids){
                if (_seriesPlaylistHandle === requestHandle) _seriesPlaylistHandle = null
                if (!ids || !ids.length) return;
                if (requestPlayList) {  requestPlayList(ids, accessToken, userId, serverUrl, (itemTitle||"") + " — Aléatoire"); }
                else if (requestPlay) {  requestPlay(ids[0], accessToken, userId, serverUrl, itemTitle || ""); }
            }, function(err){ if (_seriesPlaylistHandle === requestHandle) _seriesPlaylistHandle = null }
        );
        _seriesPlaylistHandle = requestHandle
    }

    function setSeriesPlayed(v){
        if (!item || !item.Id) return;
        var nv = !!v;
        _applySeriesUserDataFlag("Played", nv);
        try {
            if (Jellyfin.setPlayedState) Jellyfin.setPlayedState(serverUrl, accessToken, userId, item.Id, nv,
                function(){ _applySeriesUserDataFlag("Played", nv); },
                function(){ _applySeriesUserDataFlag("Played", !nv); });
        } catch(e) {}
    }
    function setSeriesFavorite(v){
        if (!item || !item.Id) return;
        var nv = !!v;
        _applySeriesUserDataFlag("IsFavorite", nv);
        try {
            if (Jellyfin.setFavorite) Jellyfin.setFavorite(serverUrl, accessToken, userId, item.Id, nv,
                function(){ _applySeriesUserDataFlag("IsFavorite", nv); },
                function(){ _applySeriesUserDataFlag("IsFavorite", !nv); });
        } catch(e) {}
    }
    function gotoSelectProfile(){
        flushSaveFocusSnapshotNow();
        _storeSensitiveNavContext();
        var url = "LoginPage.qml?ctx=1";
        if (requestNavigation) requestNavigation(url);
    }
    property int lastFocusBeforeOverlay: 0
    function openPosterOverlay(){
        if (!hasItem) return;
        lastFocusBeforeOverlay=currentFocus;
        overlayMode="poster";
        overlayData={ posterUrl: effectivePosterUrl, posterMaxW: posterMaxW, posterMaxH: posterMaxH };
    }
    function _overviewReaderImageUrl(){
        return item ? Jellyfin.itemBackdropOrPrimaryUrl(serverUrl, item, {
            fillWidth: 720, fillHeight: 405, quality: 88, format: "jpg"
        }) : "";
    }
    function openOverviewOverlay(){
        if (!hasItem) return;
        var meta = [];
        if (yearText && yearText.length) meta.push(yearText);
        if (seasonsFetched && seasonsCount > 0)
            meta.push(seasonsCount + (seasonsCount === 1 ? " saison" : " saisons"));
        if (statusText && statusText.length) meta.push(statusText);
        lastFocusBeforeOverlay=currentFocus;
        overlayMode="overview";
        overlayData={
            readerStyle: "media",
            title: itemTitle || "Résumé",
            meta: meta.join("  •  "),
            posterUrl: _overviewReaderImageUrl() || seriesCoverUrl || effectivePosterUrl,
            overview: item.Overview || "",
            posterMaxW: posterMaxW,
            posterMaxH: posterMaxH
        };
    }
    function openPersonPage(personObj){
        if (!personObj || !personObj.Id || !requestNavigation) return;
        currentFocus = 3;
        try {
            var cast = castPageLoader.item;
            if (cast && cast.currentActorIndex !== undefined && cast.currentActorIndex >= 0)
                cast.lastFocusedIndex = cast.currentActorIndex|0;
        } catch(eCastSync) {}
        armMemo("person");
        flushSaveFocusSnapshotNow();
        _storePersonReturnContext(personObj);
        _disarmMemo();
        requestNavigation(_navRoute("PersonPage.qml", { itemId: personObj.Id }));
    }
    function closeOverlay(){
        overlayMode="none"; overlayData={};
        switch(lastFocusBeforeOverlay){
        case -1: focusHudAvatar(); break;
        case 0: goUpToResume(); break;
        case 1: currentFocus=1; actionsBlock.focusFirst(); break;
        case 2: currentFocus=2; ensureItemVisible(posterFocus,20); posterFocus.forceActiveFocus(); break;
        case 6: currentFocus=6; _restoreNextUpFocusIfAny(); break;
        case 5: currentFocus=5; focusSeasons(); break;
        case 3: currentFocus=3; ensureItemVisible(castPageLoader,40); SeasonUtils.restoreCastFocus(castPageLoader.item); break;
        case 4:
            if (hasSimilarContent()) { currentFocus=4; _restoreSimilarFocusIfAny(); }
            else {
                currentFocus = hasCast()?3:(hasSeasons()?5:1);
                if(currentFocus===3) focusCast();
                else if(currentFocus===5) focusSeasons();
                else actionsBlock.focusFirst();
            }
            break;
        default:
            _applyDefaultFocus();
            return;
        }
        requestSaveFocusSnapshot();
    }
    Item {
        id: loadingLayer
        anchors.fill: parent
        z: 7000
        opacity: visualLoading ? 1.0 : 0.0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Rectangle { anchors.fill: parent; color: "#000"; opacity: 0.18 }
        // Loader visuel global fourni par ShellPage.
    }
    Keys.onPressed: {
        if (currentFocus===focusHud && (event.key===Qt.Key_Down)) {
            restoreFocusFromHud();
            event.accepted = true;
            return;
        }
        if (event.key===Qt.Key_Back || event.key===Qt.Key_Escape) {
            if (overlayMode!=="none") { closeOverlay(); event.accepted=true; return; }

            // Back terminal : la position de la fiche ne doit pas survivre.
            _leaveDetailToMenu();
            event.accepted=true;
        }
    }
}
