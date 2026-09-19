import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../components" as Components
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils
import "../js/MediaCatalog.js" as MediaCatalog
FocusScope {
    id: seasonpage
    width: parent ? parent.width : 1280
    height: parent ? parent.height : 720
    focus: true
    property string accessToken
    property string userId
    property string serverUrl
    property string seasonId
    property string seriesId
    property string _guestStarsItemId
    property string preselectEpisodeId
    property string restoreEpisodeId
    property int restoreIndex: -1
    property real restoreY: -1
    property string userName
    property string userImageTag
    property var playlist: null
    property var playlistRef: null
    onPlaylistRefChanged: {
        if (!playlist && playlistRef) playlist = playlistRef;
    }
    property var fbx
    property var shared: null
    property bool showClock: true
    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(seasonpage, false, 0, false) : false
    }

    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(seasonpage) : false
    }

    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(seasonpage, page, params || ({})) : (page + "?ctx=1")
    }

    function _guestFocusSnapshot(){
        var g = (guestLoader && guestLoader.status === Loader.Ready) ? guestLoader.item : null
        if (!g) return ({ index: 0, key: "" })
        try {
            if (typeof g.focusSnapshot === "function")
                return g.focusSnapshot()
        } catch(e0) {}
        return ({
            index: (g.lastFocusedIndex !== undefined) ? (Number(g.lastFocusedIndex) | 0) : 0,
            key: (g.lastFocusedKey !== undefined) ? String(g.lastFocusedKey || "") : ""
        })
    }

    function _saveGuestPersonReturnState(){
        try {
            if (!shared) return false
            var fs = _guestFocusSnapshot()
            shared.__redefinSeasonGuestReturn = ({
                seasonId: String(seasonId || ""),
                seriesId: String(seriesId || ""),
                episodeId: String(selectedEpisodeId || ""),
                episodeIndex: currentIndex | 0,
                scrollY: rootFlick ? Number(rootFlick.contentY || 0) : 0,
                guestIndex: fs && fs.index !== undefined ? (Number(fs.index) | 0) : 0,
                guestKey: fs && fs.key !== undefined ? String(fs.key || "") : "",
                ts: Date.now()
            })
            return true
        } catch(e) {
            return false
        }
    }

    function _guestReturnStateMatches(st){
        if (!st) return false
        var sid = String(st.seasonId || "")
        var srid = String(st.seriesId || "")
        if (seasonId && sid && String(seasonId) !== sid) return false
        if (seriesId && srid && String(seriesId) !== srid) return false
        return true
    }

    function _hydrateGuestPersonReturnState(){
        if (_guestPersonReturnPending) return true
        try {
            if (!shared || !shared.__redefinSeasonGuestReturn) return false
            if (!seasonId && !seriesId) return false

            var st = shared.__redefinSeasonGuestReturn
            var age = Date.now() - Number(st.ts || 0)
            if (age < 0 || age > 21600000) {
                shared.__redefinSeasonGuestReturn = null
                return false
            }
            if (!_guestReturnStateMatches(st)) return false

            shared.__redefinSeasonGuestReturn = null

            restoreEpisodeId = String(st.episodeId || "")
            restoreIndex = (st.episodeIndex !== undefined && st.episodeIndex !== null)
                         ? (Number(st.episodeIndex) | 0) : -1
            restoreY = (st.scrollY !== undefined && st.scrollY !== null)
                     ? Number(st.scrollY) : -1

            _guestPersonReturnIndex = (st.guestIndex !== undefined && st.guestIndex !== null)
                                    ? (Number(st.guestIndex) | 0) : 0
            _guestPersonReturnKey = String(st.guestKey || "")
            _guestPersonReturnY = restoreY
            _guestPersonReturnAttempts = 0
            _guestPersonReturnPending = true
            _guestPersonReturnOwnsEpisodeRestore = true

            // Force l'instanciation du rail guests dès que ses données seront prêtes.
            _guestPrefetch = true
            return true
        } catch(e) {
            return false
        }
    }

    function _applyGuestReturnSnapshot(g){
        if (!g || !_guestPersonReturnPending) return
        var snap = ({
            index: _guestPersonReturnIndex | 0,
            key: String(_guestPersonReturnKey || "")
        })
        try {
            if (typeof g.applyFocusSnapshot === "function") {
                g.applyFocusSnapshot(snap)
                return
            }
        } catch(e0) {}
        try {
            if (g.lastFocusedIndex !== undefined) g.lastFocusedIndex = snap.index
            if (g.lastFocusedKey !== undefined) g.lastFocusedKey = snap.key
        } catch(e1) {}
    }

    function _scheduleGuestPersonReturnRestore(){
        if (!_guestPersonReturnPending || disposed) return
        if (!guestPersonReturnTimer.running)
            guestPersonReturnTimer.restart()
    }

    function _tryRestoreGuestAfterPerson(){
        if (!_guestPersonReturnPending || disposed) return

        if (isLoading || visualRevealPending || overlayOpen || layoutSettle || !hasGuests) {
            if ((_guestPersonReturnAttempts++ | 0) < 90)
                guestPersonReturnTimer.restart()
            return
        }

        _guestPrefetch = true
        var g = (guestLoader.status === Loader.Ready) ? guestLoader.item : null
        if (!g) {
            if ((_guestPersonReturnAttempts++ | 0) < 90)
                guestPersonReturnTimer.restart()
            return
        }

        _applyGuestReturnSnapshot(g)

        // Tant que _guestPersonReturnPending est vrai, requestGuestScroll() est
        // volontairement bloqué pour ne pas écraser le scroll exact mémorisé.
        currentFocus = 2

        later(function(){
            if (disposed || !_guestPersonReturnPending) return

            var gg = (guestLoader.status === Loader.Ready) ? guestLoader.item : null
            if (!gg) {
                guestPersonReturnTimer.restart()
                return
            }

            _applyGuestReturnSnapshot(gg)

            if (gg.restoreLastGuestFocus) gg.restoreLastGuestFocus()
            else if (gg.takeFocus) gg.takeFocus(_guestPersonReturnIndex)
            else if (gg.forceFirstGuestFocus) gg.forceFirstGuestFocus()

            if (rootFlick && _guestPersonReturnY >= 0) {
                var maxY = Math.max(0, Number(rootFlick.contentHeight || 0) - Number(rootFlick.height || 0))
                var yy = Math.max(0, Math.min(maxY, Number(_guestPersonReturnY)))
                rootFlick.jumpToY(yy)
            }

            // Le retour est maintenant stabilisé sur le bon épisode et le bon guest.
            // Neutralise le preselect historique de la route afin qu'un restore tardif
            // ne puisse plus revenir à l'épisode qui était sélectionné à l'ouverture
            // initiale de SeasonPage.
            preselectEpisodeId = ""
            _guestPersonReturnOwnsEpisodeRestore = false
            _guestPersonReturnPending = false
            _guestPersonReturnAttempts = 0
            requestHudOpacityUpdate("guestPersonReturn")
            bumpActivity()
        })
    }

    readonly property int backdropQuality: 70
    readonly property bool marqueeAllowed: true
    readonly property real marqueePxPerSec: 55.0
    readonly property int marqueePauseMs: 660
    readonly property real metaMarqueePxPerSec: 36.0      // tags/meta: plus lent pour laisser lire tous les badges
    readonly property int metaMarqueeStartPauseMs: 760    // pause avant départ du défilement tags/meta
    readonly property int metaMarqueeEndPauseMs: 1900     // pause en fin pour lire les derniers tags
    readonly property int metaMarqueeEndPadding: 56       // marge après dernier tag avant retour au début
    readonly property int metaMarqueeRestartDelayMs: 420  // laisse le Row/Repeater stabiliser toutes les largeurs avant de relancer
    readonly property int metaMarqueeBootDelayMs: 700     // kick initial après premier rendu complet des tags
    readonly property int endTimeTickMs: 60000
    // Même hiérarchie visuelle que detailMoviePage : libellés blancs,
    // valeurs descriptives et résumé en gris lisible.
    readonly property color metadataValueColor: "#b8bdcc"
    property bool initialWarmup: true
    readonly property int posterWarmupMs: 340
    readonly property int posterWindowWarmup: 1
    readonly property int posterWindowNormal: 2
    readonly property real posterRequestScale: 1.30
    readonly property int posterRequestQuality: 85
    readonly property real posterHqRequestScale: 1.50
    readonly property int posterHqRequestQuality: 90
    readonly property int extrasArmDelayMs: 420
    property bool _logoArmed: false
    property bool _actionsArmed: false
    readonly property int hudThrottleMs: 60
    readonly property real hudEps: 0.02
    readonly property bool ctxOk: !!(serverUrl && accessToken && userId && (seasonId || seriesId))
    readonly property bool overlayOpen: !!(overlayMode !== "none")
    readonly property bool canInteract: !!(!disposed && !isLoading && !visualRevealPending && !overlayOpen)
    readonly property bool uiReady: !!(canInteract && postFirstFrame)
    readonly property bool _scrolling: !!(rootFlick && (rootFlick.dragging || rootFlick.moving))
    readonly property bool hasGuests: !!SeasonUtils.hasGuestStars(guestStars)
    readonly property bool canPin: !!(!disposed && !isLoading && !overlayOpen
                                     && !!rootFlick && !_scrolling && currentFocus === 1
                                     && !!episodes && (episodes.length > 0) && !layoutSettle && !_deferPinAfterNav)
    readonly property bool canGuestScroll: !!(canInteract && !!rootFlick && currentFocus === 2 && hasGuests)
    readonly property bool canRunTimers: !!(uiReady && !deepIdle && !_scrolling)
    readonly property var h: seasonpage
    function later(fn){ Qt.callLater(function(){ if(!disposed && fn) fn(); }); }
    function safeCall(fn){ try{ if(fn) fn(); } catch(e){} }
    function _sigIndex(args, fallback){
        if (typeof idx !== "undefined") return idx;
        if (typeof index !== "undefined") return index;
        if (args && args.length > 0) return args[0];
        return (fallback !== undefined) ? fallback : 0;
    }
    function _sigObj(args, pos, fallback){
        if (args && args.length > pos) return args[pos];
        return (fallback !== undefined) ? fallback : null;
    }
    function _guardRun(){ return !disposed; }
    function _isActivateKey(key){
        return key === Qt.Key_Return
            || key === Qt.Key_Enter
            || key === Qt.Key_Select
            || key === Qt.Key_Ok;
    }
    function _it(){ return (selectedDetails && selectedDetails.Id) ? selectedDetails : selectedEpisode; }
    function _epId(ep){ return MediaCatalog.shuffleEpisodeId(ep); }
    function _episodePlayableForShuffle(ep){ return MediaCatalog.episodePlayableForShuffle(ep); }
    function _ownedShuffleCandidates(preferUnplayed){
        return MediaCatalog.ownedShuffleCandidates(episodes || [], preferUnplayed === true);
    }
    function pickOwnedShuffleEpisode(preferUnplayed){
        return MediaCatalog.pickOwnedShuffleEpisode(episodes || [], preferUnplayed === true);
    }
    property bool _ownedPlaylistSyncBusy: false
    function _applyOwnedPlaylist(pl, ids){
        if (!pl || !ids || !ids.length) return;
        try { if (pl.list !== undefined) pl.list = ids; } catch(e0) {}
        try { if (pl.items !== undefined) pl.items = ids; } catch(e1) {}
        try { if (pl.playlist !== undefined) pl.playlist = ids; } catch(e2) {}
        try { if (pl.itemIds !== undefined) pl.itemIds = ids; } catch(e3) {}
        try { if (pl.allowedIds !== undefined) pl.allowedIds = ids; } catch(e4) {}
        try { if (pl.title !== undefined) pl.title = (seasonItem && seasonItem.Name) ? seasonItem.Name : "Saison"; } catch(e5) {}
        try { if (pl.autoplayNext !== undefined) pl.autoplayNext = true; } catch(e6) {}
        try { if (pl.controller !== undefined) pl.controller = "seasonpage"; } catch(e7) {}
        try { if (pl.scope !== undefined) pl.scope = seasonId ? ("season:" + seasonId) : "season"; } catch(e8) {}
        try { if (pl.setAllowedFromList) pl.setAllowedFromList(ids); } catch(e9) {}
        try {
            var cur = String(selectedEpisodeId || "");
            if (!cur || ids.indexOf(cur) < 0) cur = ids[0];
            if (pl.syncTo) pl.syncTo(cur);
            else if (pl.currentItemId !== undefined) pl.currentItemId = cur;
        } catch(e10) {}
    }
    function updatePlaylistFromOwnedEpisodes(){
        if (_ownedPlaylistSyncBusy) return;
        var pl = playlist || playlistRef, owned = _ownedShuffleCandidates(false);
        if (!pl || !owned.length) return;
        var ids = []; for (var i = 0; i < owned.length; i++) ids.push(_epId(owned[i]));
        _ownedPlaylistSyncBusy = true;
        try { SeasonUtils.updatePlaylistFromEpisodes(seasonpage); _applyOwnedPlaylist(pl, ids); }
        finally { _ownedPlaylistSyncBusy = false; }
    }
    function withEpisodesRow(fn){
        var it = (episodesRowLoader && episodesRowLoader.item) ? episodesRowLoader.item : null;
        if (it && fn) fn(it);
    }
    property bool deepIdle: false
    Timer {
        id: idleFreezeTimer
        interval: 3000
        repeat: false
        onTriggered: deepIdle = true
    }
    function bumpActivity(){
        if (!_guardRun()) return;
        if (deepIdle) deepIdle = false;
        if (!isLoading && !overlayOpen) idleFreezeTimer.restart();
    }
    property bool layoutSettle: true
    Timer {
        id: settleTimer
        interval: 380
        repeat: false
        onTriggered: {
            layoutSettle = false;
            requestPinEpisodes("settleDone");
            requestReflow("settleDone");
            maybeHydrateEpisodesRow();
            if (_detailsPending && !disposed && !isLoading) detailsDebounceTimer.restart();
            if (!disposed && !isLoading) {
                if (!_logoArmed) logoArmTimer.restart();
                if (!_actionsArmed) actionsArmTimer.restart();
            }
        }
    }
    property bool _mtFirstFrame: false
    property bool _mtFetch: false
    property bool _mtAnchor: false
    property bool _mtReflow: false
    property bool _mtPin: false
    property bool _mtFocus: false
    property string _mtFetchReason: ""
    property string _mtAnchorTag: ""
    property string _mtReflowTag: ""
    property string _mtPinTag: ""
    Timer {
        id: microTask
        interval: 0
        repeat: false
        onTriggered: {
            if (disposed) return;
            if (_mtFirstFrame){ _mtFirstFrame = false; postFirstFrame = true; }
            if (_mtFetch){
                _mtFetch = false;
                var r = _mtFetchReason; _mtFetchReason = "";
                triggerFetch(r);
                return;
            }
            if (_mtAnchor){ _mtAnchor = false; _recomputeAnchorCache(); _mtAnchorTag = ""; }
            if (_mtReflow){ _mtReflow = false; reflow(_mtReflowTag || "mtReflow"); _mtReflowTag = ""; }
            if (_mtPin){ _mtPin = false; _kickPinEpisodes(_mtPinTag || "mtPin"); _mtPinTag = ""; }
            if (_mtFocus){ _mtFocus = false; _applyFocusNow(); }
        }
    }
    function schedulePostFirstFrame(){
        if (disposed || postFirstFrame) return;
        _mtFirstFrame = true; microTask.restart();
    }
    function requestFetch(reason){
        if (disposed) return;
        _mtFetchReason = reason || "";
        _mtFetch = true;
        microTask.restart();
    }
    function requestAnchorRecompute(tag){
        if (disposed || !rootFlick) return;
        _mtAnchorTag = tag || "";
        _mtAnchor = true;
        microTask.restart();
    }
    function requestReflow(tag){
        if (disposed) return;
        _mtReflowTag = tag || "";
        _mtReflow = true;
        microTask.restart();
    }
    function requestPinEpisodes(tag){
        if (!canPin) return;
        _mtPinTag = tag || "";
        _mtPin = true;
        microTask.restart();
    }
    function requestApplyFocus(){
        if (disposed || isLoading || _focusRestoreGate || _playlistRestoreInFlight) return;
        if (_mtFocus) return;
        _mtFocus = true;
        microTask.restart();
    }
    Timer {
        id: posterWarmupTimer
        interval: posterWarmupMs
        repeat: false
        onTriggered: {
            initialWarmup = false;
            withEpisodesRow(function(it){
                if (it.updatePosterGate) it.updatePosterGate("warmupDone");
            });
            maybeHydrateEpisodesRow();
        }
    }
    Timer {
        id: logoArmTimer
        interval: extrasArmDelayMs
        repeat: false
        onTriggered: {
            if (!_guardRun()) return;
            if (!isLoading && !overlayOpen && postFirstFrame && !layoutSettle) {
                _logoArmed = true;
            } else if (!disposed && !isLoading) {
                logoArmTimer.restart();
            }
        }
    }
    Timer {
        id: actionsArmTimer
        interval: Math.max(220, extrasArmDelayMs - 120)
        repeat: false
        onTriggered: {
            if (!_guardRun()) return;
            if (!isLoading && !overlayOpen && postFirstFrame && !layoutSettle) {
                _actionsArmed = true;
                requestPinEpisodes("actionsArmTimer");
            } else if (!disposed && !isLoading) {
                actionsArmTimer.restart();
            }
        }
    }
    function _marqueeDurationMs(deltaPx, pxPerSec){
        var d = Math.max(1, Number(deltaPx) || 0);
        var s = Math.max(1.0, Number(pxPerSec) || 1.0);
        return Math.max(1, Math.round((d / s) * 1000));
    }
    function _metaMarqueeEligible(deltaPx, viewportItem, marginPx, extraCond){
        var m = (marginPx === undefined) ? 24 : marginPx;
        return marqueeAllowed && !!extraCond
            && !!uiReady && !overlayOpen && !_scrolling
            && (Number(deltaPx) > 6)
            && isInViewport(viewportItem, m)
            && (viewportGen >= 0);
    }
    function _marqueeStop(box, anim){ if (!box) return; try { if (box.marqueeMoving !== undefined) box.marqueeMoving = false; } catch(e) {} box._mx = 0; if (anim) anim.stop(); }
    property real _guestAnchorY: -1
    property real _episodesBottomY: -1
    function _recomputeAnchorCache(){
        if (disposed || !rootFlick) return;
        safeCall(function(){ _guestAnchorY = rootFlick.safeMapY(guestAnchor); });
        safeCall(function(){
            if (episodesRowLoader){
                var y = rootFlick.safeMapY(episodesRowLoader);
                _episodesBottomY = y + (Number(episodesRowLoader.height) || 0);
            } else _episodesBottomY = -1;
        });
    }
    property bool _suppressContentYAnim: false
    property bool _internalJump: false
    property bool _pinEpisodesActive: false
    property int _pinQuietMs: 220
    Timer { id: pinEpisodesQuietTimer; interval: _pinQuietMs; repeat: false; onTriggered: _pinEpisodesActive = false }
    property bool _deferPinAfterNav: false
    Timer { id: pinAfterNavTimer; interval: 260; repeat: false; onTriggered: { _deferPinAfterNav = false; requestPinEpisodes("afterNav"); } }
    function schedulePinAfterNav(){ if (!disposed){ _deferPinAfterNav = true; pinAfterNavTimer.restart(); } }
    function _kickPinEpisodes(tag){
        if (!canPin) return;
        _pinEpisodesActive = true;
        rootFlick.pinEpisodesBottom();
        pinEpisodesQuietTimer.restart();
    }
    function reflow(tag){
        if (disposed) return;
        _recomputeAnchorCache();
        requestHudOpacityUpdate(tag);
        requestPinEpisodes(tag);
    }
    property int hudFadeStartPx: 40
    property int hudFadeEndPadPx: 120
    property int hudFadeMinSpanPx: 260
    property real hudOpacity: 1.0
    property bool _hudDirty: false
    property string _hudDirtyTag: ""
    Timer {
        id: hudOpacityThrottle
        interval: hudThrottleMs
        repeat: false
        onTriggered: {
            if (disposed) return;
            if (!_hudDirty) return;
            _hudDirty = false;
            var t = _hudDirtyTag; _hudDirtyTag = "";
            _updateHudOpacityNow(t);
        }
    }
    function requestHudOpacityUpdate(tag){
        if (disposed) return;
        _hudDirtyTag = tag || "";
        _hudDirty = true;
        hudOpacityThrottle.restart();
    }
    function _setHudOpacityIfNeeded(o){
        o = Math.max(0.0, Math.min(1.0, o));
        if (o === 0.0 || o === 1.0){
            if (hudOpacity !== o) hudOpacity = o;
            return;
        }
        if (Math.abs(o - hudOpacity) >= hudEps) hudOpacity = o;
    }
    function _updateHudOpacityNow(tag){
        if (!rootFlick){ _setHudOpacityIfNeeded(1.0); return; }
        if (layoutSettle || _internalJump) return;
        var y = Number(rootFlick.contentY) || 0;
        var start = Math.max(0, Number(hudFadeStartPx) || 0);
        var end = start + 620;
        var gy = Number(_guestAnchorY);
        if (!(gy > 0)){
            requestAnchorRecompute("hud:" + (tag || ""));
        } else if (hasGuests){
            end = Math.max(start + hudFadeMinSpanPx, (gy - (Number(hudFadeEndPadPx) || 0)));
        }
        if (y <= start){ _setHudOpacityIfNeeded(1.0); return; }
        if (y >= end){ _setHudOpacityIfNeeded(0.0); return; }
        var t2 = (y - start) / Math.max(1, (end - start));
        t2 = Math.max(0.0, Math.min(1.0, t2));
        var o = 1.0 - t2;
        o = o * o;
        _setHudOpacityIfNeeded(o);
    }
    property var seasonItem: null
    property var episodes: null
    property int currentIndex: 0
    property var detailsCache: ({})
    property var _detailsCacheOrder: []
    property int _detailsCacheMax: 24
    function _rememberEpisodeDetails(details){
        if (!details || !details.Id) return;
        var id = String(details.Id), order = _detailsCacheOrder || [], idx = order.indexOf(id);
        detailsCache[id] = MediaCatalog.compactEpisodeDetailsForCache(details);
        if (idx >= 0) order.splice(idx, 1);
        order.push(id);
        while (order.length > Math.max(1, _detailsCacheMax | 0)) {
            var oldId = order.shift();
            if (oldId && detailsCache[oldId]) delete detailsCache[oldId];
        }
    }
    function _getEpisodeDetails(id){
        id = String(id || "");
        var details = id ? detailsCache[id] : null;
        if (!details) return null;
        var order = _detailsCacheOrder || [], idx = order.indexOf(id);
        if (idx >= 0) { order.splice(idx, 1); order.push(id); }
        return details;
    }
    function _clearDetailsCache(){ detailsCache = ({}); _detailsCacheOrder = []; }
    property var selectedDetails: null
    property bool ready: false
    readonly property var selectedEpisode: (episodes && episodes.length > 0 && currentIndex >= 0 && currentIndex < episodes.length) ? episodes[currentIndex] : null
    readonly property string selectedEpisodeId: (selectedEpisode && selectedEpisode.Id) ? selectedEpisode.Id : ""
    property bool _episodesHydrated: false
    property int episodesHydrateCount: 10
    property int _episodesSliceStart: 0
    property var _episodesSlice: []
    readonly property var episodesForRow: (_episodesHydrated ? episodes : _episodesSlice)
    readonly property int episodesRowIndex: {
        if (_episodesHydrated) return currentIndex;
        if (!_episodesSlice || _episodesSlice.length === 0) return 0;
        var idx = currentIndex - _episodesSliceStart;
        if (idx < 0) idx = 0;
        if (idx >= _episodesSlice.length) idx = _episodesSlice.length - 1;
        return idx;
    }
    function _computeEpisodesSlice(centerIndex){
        var slice = MediaCatalog.episodeSliceWindow(episodes || [], centerIndex, episodesHydrateCount);
        _episodesSliceStart = slice.start;
        _episodesSlice = slice.items;
    }
    function prepareEpisodesSlice(){
        var arr = episodes || [];
        if (_hasExplicitEpisodeRestoreTarget() && arr.length) {
            _episodesHydrated = true; _episodesSliceStart = 0; _episodesSlice = [];
        } else {
            _episodesHydrated = false; _computeEpisodesSlice(currentIndex);
        }
    }
    function maybeHydrateEpisodesRow(){
        if (_episodesHydrated) return;
        var arr = episodes || [];
        if (!arr.length) return;
        if (arr.length <= episodesHydrateCount) {
            _episodesHydrated = true; _episodesSlice = []; _episodesSliceStart = 0;
            _maybeReleaseFocusRestoreGate();
            return;
        }
        if (isLoading || overlayOpen || layoutSettle || initialWarmup || !postFirstFrame || _scrolling) return;
        _episodesHydrated = true; _episodesSlice = []; _episodesSliceStart = 0;
        _maybeReleaseFocusRestoreGate();
        later(function(){
            withEpisodesRow(function(it){ if (it.updatePosterGate) it.updatePosterGate("episodesHydrated"); });
            requestPinEpisodes("episodesHydrated");
        });
    }
    property int viewportGen: 0
    Timer { id: viewportPulseTimer; interval: 90; repeat: false; onTriggered: viewportGen++ }
    property var guestStars: []
    property var guestStarsFull: null
    property int guestHydrateInitialCount: 12
    property int guestDataEpoch: 0
    property int guestScrollPadPx: 64
    property bool _guestWasReady: false
    property int _guestH: 0

    // Retour PersonPage -> seasonpage.
    property bool _guestPersonReturnPending: false
    property int _guestPersonReturnIndex: 0
    property string _guestPersonReturnKey: ""
    property real _guestPersonReturnY: -1
    property int _guestPersonReturnAttempts: 0
    // Tant qu'un retour Guest -> PersonPage est en cours, le snapshot de retour
    // est l'autorité pour l'épisode. Le preselectEpisodeId de l'URL correspond
    // uniquement à l'ouverture initiale de SeasonPage et peut être obsolète.
    property bool _guestPersonReturnOwnsEpisodeRestore: false

    Timer {
        id: guestPersonReturnTimer
        interval: 90
        repeat: false
        onTriggered: _tryRestoreGuestAfterPerson()
    }
    function syncGuestHeight(){
        var newH = 0, g = (guestLoader.status === Loader.Ready) ? guestLoader.item : null;
        if (hasGuests && g) {
            var ih = Number(g.implicitHeight) || Number(g.height) || 230;
            newH = Math.ceil(ih);
        }
        if (newH !== _guestH) _guestH = newH;
    }
    Timer { id: guestScrollDebounce; interval: 100; repeat: false; onTriggered: { if (canGuestScroll) rootFlick.scrollToGuests(true); } }
    function requestGuestScroll(){
        if (!disposed && canGuestScroll && !_guestPersonReturnPending)
            guestScrollDebounce.restart()
    }
    function _bumpGuestEpoch(){ guestDataEpoch = ((guestDataEpoch | 0) + 1) | 0; if (guestDataEpoch < 0) guestDataEpoch = 0; }
    function _clearGuests(){
        guestStars = []; guestStarsFull = null;
        var g = (guestLoader.status === Loader.Ready) ? guestLoader.item : null;
        if (!g) return;
        try { if (g.applyPeople) g.applyPeople([], guestDataEpoch | 0); else g.people = []; } catch(e0) {}
        try { if (g.applyPeopleAll) g.applyPeopleAll(null, guestDataEpoch | 0); else g.peopleAll = null; } catch(e1) {}
    }
    function _applyGuestsToGuestpage(){
        var g = (guestLoader.status === Loader.Ready) ? guestLoader.item : null;
        if (!g) return;
        try { if (g.applyPeople) g.applyPeople(guestStars || [], guestDataEpoch | 0); else g.people = guestStars || []; } catch(e0) {}
        try { if (g.applyPeopleAll) g.applyPeopleAll(guestStarsFull, guestDataEpoch | 0); else g.peopleAll = guestStarsFull; } catch(e1) {}
        _applyGuestReturnSnapshot(g)
        if (_guestPersonReturnPending) _scheduleGuestPersonReturnRestore()
        else if (!isLoading && !overlayOpen && currentFocus === 2) requestGuestScroll();
    }
    function _syncEpisodesRowPreferredId(){
        withEpisodesRow(function(it){
            try {
                if (it.preferredEpisodeId !== undefined) it.preferredEpisodeId = selectedEpisodeId;
                else if (it.preferredItemId !== undefined) it.preferredItemId = selectedEpisodeId;
            } catch(e0) {}
        });
    }
    onSelectedEpisodeIdChanged: {
        if (disposed) return;
        _guestStarsItemId = selectedEpisodeId || "";
        _bumpGuestEpoch();
        _clearGuests();
        _syncEpisodesRowPreferredId();
        requestDetailsFetchDebounced();
    }
    property bool autoRevealGuests: false
    property bool _guestPrefetch: false
    property int guestPrefetchPx: 520
    Timer { id: guestPrefetchCheck; interval: 120; repeat: false; onTriggered: _maybePrefetchGuests("debounced"); }
    function _maybeGuestPrefetchKick(){
        if (!disposed && !isLoading && !overlayOpen && !_guestPrefetch && hasGuests) guestPrefetchCheck.restart();
    }
    function _maybePrefetchGuests(tag){
        if (disposed || isLoading || overlayOpen || _guestPrefetch || !hasGuests || !rootFlick) return;
        var gy = Number(_guestAnchorY);
        if (!(gy > 0)) { requestAnchorRecompute("prefetch:" + (tag || "")); return; }
        var viewBottom = (Number(rootFlick.contentY) || 0) + (Number(rootFlick.height) || 0);
        if (viewBottom + Number(guestPrefetchPx || 520) >= gy) _guestPrefetch = true;
    }
    function requestGuestFocusSafe(restore){
        if (!hasGuests) return;
        _guestPrefetch = true; guestPrefetchCheck.stop();
        _deferPinAfterNav = false; pinAfterNavTimer.stop();
        currentFocus = 2;
        rootFlick.scrollToGuests(true);
        later(function(){
            var g = (guestLoader.status === Loader.Ready) ? guestLoader.item : null;
            if (g) {
                if (restore && g.restoreLastGuestFocus) g.restoreLastGuestFocus();
                else if (g.forceFirstFocus) g.forceFirstFocus();
                else if (g.forceFirstGuestFocus) g.forceFirstGuestFocus();
            }
            requestGuestScroll();
        });
    }
    function hasChapters(){ return !!(chaptersLoader.status === Loader.Ready && chaptersLoader.item && chaptersLoader.item.hasContent === true); }
    function requestChapterFocusSafe(restore){
        if (!hasChapters()) return; currentFocus = focusChapters;
        var y = rootFlick.safeMapY(chaptersLoader), maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height);
        rootFlick._setScrollY(rootFlick.clamp(y + chaptersLoader.height - rootFlick.height + 64, 0, maxY), true);
        later(function(){ var c = chaptersLoader.item; if (c) { if (restore && c.restoreLastFocus) c.restoreLastFocus(); else if (c.forceFirstFocus) c.forceFirstFocus(); } });
    }
    readonly property int contentLeft: 72
    readonly property int contentRight: 72
    readonly property int contentTop: 48
    readonly property int gapBelowHeader: 10
    readonly property int gapBelowOverview: 22
    property int liftAllPx: 30
    property int episodesLiftPx: 50
    property int guestsLiftPx: 90
    readonly property int _episodesExtraUp: (episodesLiftPx > gapBelowOverview) ? (episodesLiftPx - gapBelowOverview) : 0
    readonly property int _episodesSpacerH: (episodesLiftPx >= 0)
        ? Math.max(0, gapBelowOverview - Math.min(episodesLiftPx, gapBelowOverview))
        : (gapBelowOverview + (-episodesLiftPx))
    property int leftMetaW: 260
    property int rightColMaxW: 720
    property int rightColMaxWTitle: 0
    property int rightColMaxWOverview: 750
    property int metaLineMaxW: 0
    readonly property int _effTitleMaxW: (rightColMaxWTitle > 0 ? rightColMaxWTitle : 99999)
    readonly property int _effOverviewMaxW: (rightColMaxWOverview > 0 ? rightColMaxWOverview : rightColMaxW)
    property real rightColRatio: 1.0
    property int columnsSpacing: 16
    property int headerShiftPx: 200
    property int overviewShiftPx: 190
    property bool allowOverviewOverlap: true
    readonly property int headerColX: Math.max(0, leftMetaW + columnsSpacing - headerShiftPx)
    readonly property int overviewColX: allowOverviewOverlap ? (leftMetaW + columnsSpacing - overviewShiftPx)
                                                            : Math.max(0, leftMetaW + columnsSpacing - overviewShiftPx)
    readonly property int episodeCardW: 360
    readonly property int episodeCardH: 240
    readonly property int episodesRowTopPad: 46

    // Étend SeasonEpisodesRow au-delà de la colonne texte pour utiliser presque toute la largeur écran.
    // Garde un léger bleed pour que le premier/dernier épisode respirent sans être rognés au focus.
    readonly property int episodesRowBleedPx: 24
    readonly property color glassFocus: "#1AFFFFFF"
    readonly property color glassBorder: "#33FFFFFF"
    property bool showSeriesLogo: true
    property int seriesLogoMaxW: 320
    property int seriesLogoMaxH: 160
    property int seriesLogoMinW: 80
    property int seriesLogoGap: 18
    property string seriesLogoPos: "right"
    property int seriesLogoOffsetX: 0
    property int seriesLogoOffsetY: -30
    property bool showActionPanel: true
    property int actionCircleSize: 60
    property int actionCircleGap: 10
    property int actionPanelLiftPx: 0
    property string actionPanelAnchor: "auto" // auto|fixed
    property int actionPanelFixedX: 0
    property int actionPanelFixedY: 0
    property int actionPanelOffsetX: contentRight - 12
    property int actionPanelOffsetY: -20
    readonly property int overviewMaxLines: 5
    readonly property real overviewLineSpacing: 1.30
    property int overviewPadding: 0
    property int overviewMinLines: 5
    property int bgBlur: 8
    property string overlayMode: "none"   // none | overview
    property var overlayData: ({})
    property int lastFocusBeforeOverlay: 0
    property bool disposed: false
    property int reqSeq: 0
    property var _seasonItemLoadHandle: null
    property var _episodesLoadHandle: null
    property bool episodesPartial: false
    property int detailsReqSeq: 0
    property int currentFocus: 1
    readonly property int focusActions: 3
    readonly property int focusChapters: 4
    readonly property int focusHud: -1
    property int lastFocusBeforeHud: 0
    property bool _restoringFocus: false
    property bool _playlistRestoreInFlight: false
    property bool _focusRestoreGate: false
    property string _lastPlaylistRestoreKey: ""
    function _hasExplicitEpisodeRestoreTarget(){
        return !!((preselectEpisodeId && preselectEpisodeId.length) ||
                  (restoreEpisodeId && restoreEpisodeId.length) || restoreIndex >= 0);
    }
    function _desiredRestoreIndex(){
        if (!episodes || !episodes.length) return -1;

        // Retour Guest -> PersonPage : le snapshot de retour doit gagner sur le
        // preselectEpisodeId de la route, qui décrit seulement l'entrée initiale
        // dans SeasonPage et peut viser un ancien épisode.
        if (_guestPersonReturnOwnsEpisodeRestore) {
            var rid = String(restoreEpisodeId || "");
            if (rid.length) {
                for (var i = 0; i < episodes.length; i++) {
                    if (episodes[i] && String(episodes[i].Id || "") === rid)
                        return i;
                }
            }
            if (restoreIndex >= 0 && restoreIndex < episodes.length)
                return restoreIndex | 0;
        }

        var idx = SeasonUtils.desiredIndexFromInputs(episodes, preselectEpisodeId, restoreEpisodeId, restoreIndex, playlist);
        return idx >= 0 ? idx : Math.max(0, Math.min(currentIndex | 0, episodes.length - 1));
    }
    function _restoreTargetIdForIndex(idx){
        var ep = (episodes && idx >= 0 && idx < episodes.length) ? episodes[idx] : null;
        return ep && ep.Id ? String(ep.Id) : "";
    }
    function _playlistRestoreKey(idx){
        return [preselectEpisodeId || "", restoreEpisodeId || "", String(restoreIndex),
                String(_guestPersonReturnOwnsEpisodeRestore),
                _restoreTargetIdForIndex(idx), episodes ? String(episodes.length) : "0",
                String(_episodesHydrated), String(_episodesSliceStart)].join("|");
    }
    function _armFocusRestoreGate(){
        if (!_hasExplicitEpisodeRestoreTarget()) return false;
        _focusRestoreGate = true; return true;
    }
    function _maybeReleaseFocusRestoreGate(){
        if ((!_focusRestoreGate && !_playlistRestoreInFlight) || !_hasExplicitEpisodeRestoreTarget() || !episodes || !episodes.length) return;
        var idx = _desiredRestoreIndex(), target = _restoreTargetIdForIndex(idx);
        if (idx < 0 || (target && selectedEpisodeId !== target) || currentIndex !== idx || !_episodesHydrated) return;
        _lastPlaylistRestoreKey = _playlistRestoreKey(idx);
        _playlistRestoreInFlight = false; _focusRestoreGate = false;
    }
    function _applyFocusNow(){
        if (disposed || isLoading || visualRevealPending || overlayOpen) return;
        forceActiveFocus();
        if (currentFocus === focusHud) {
            try { if (clockHud.visible && clockHud.focusAvatar && clockHud.focusAvatar()) return; } catch(e0) {}
            currentFocus = 1;
        }
        if (currentFocus === 1) { withEpisodesRow(function(it){ if (it.forceActiveFocus) it.forceActiveFocus(); }); return; }
        if (currentFocus === 0) { try { overviewBox.forceActiveFocus(); return; } catch(e1) {} }
        if (currentFocus === 2 && hasGuests) {
            _guestPrefetch = true; rootFlick.scrollToGuests(true); requestGuestScroll();
            var g = (guestLoader.status === Loader.Ready) ? guestLoader.item : null;
            if (g) {
                if (g.restoreLastGuestFocus) g.restoreLastGuestFocus();
                else if (g.forceFirstFocus) g.forceFirstFocus();
                return;
            }
        }
        if (currentFocus === focusChapters && hasChapters()) { requestChapterFocusSafe(true); return; }
        if (currentFocus === focusActions) {
            try { if (actionCircles.visible && actionCircles.focusFirstAction()) return; } catch(e2) {}
        }
        currentFocus = 1;
        withEpisodesRow(function(it){ if (it.forceActiveFocus) it.forceActiveFocus(); });
    }
    function isInViewport(item, marginPx){
        if (!item || !item.visible || !rootFlick) return false;
        var m = (marginPx === undefined) ? 0 : marginPx;
        var p = item.mapToItem(rootFlick, 0, 0);
        var y = p.y, hhh = item.height;
        return (y + hhh) > -m && y < (rootFlick.height + m);
    }
    function focusEpisodes(){
        currentFocus = 1;
        withEpisodesRow(function(it){ if (it.forceActiveFocus) it.forceActiveFocus(); });
        // Effacer après le transfert : aucun bouton encore actif ne peut republier le hint.
        try { if (actionCircles && actionCircles.clearHint) actionCircles.clearHint(); } catch(e0) {}
        rootFlick.scrollToEpisodes(true);
        schedulePinAfterNav();
    }
    function focusHudAvatar(){
        if (disposed || isLoading || overlayOpen || !clockHud.visible || !clockHud.focusAvatar) return false;
        if (currentFocus !== focusHud) lastFocusBeforeHud = currentFocus;
        currentFocus = focusHud; rootFlick.scrollToTop(true);
        later(function(){ try { if (!clockHud.focusAvatar()) restoreFocusFromHud(); } catch(e0) { restoreFocusFromHud(); } });
        return true;
    }
    function restoreFocusFromHud(){
        var f = lastFocusBeforeHud;
        if (f === focusActions) {
            try { if (actionCircles.visible && actionCircles.focusFirstAction()) { currentFocus = focusActions; rootFlick.scrollToTop(true); return; } } catch(e0) {}
        }
        if (f === 0) { currentFocus = 0; overviewBox.forceActiveFocus(); rootFlick.scrollToTop(true); return; }
        if (f === 2) { if (hasGuests) requestGuestFocusSafe(true); else focusEpisodes(); return; }
        if (f === focusChapters) { if (hasChapters()) requestChapterFocusSafe(true); else focusEpisodes(); return; }
        focusEpisodes();
    }
    onPlaylistChanged: updatePlaylistFromOwnedEpisodes()
    Rectangle { anchors.fill: parent; color: "#000000"; z: -10000 }
    property bool isLoading: true

    // Gate de révélation visuelle : les données et composants se préparent derrière
    // le CircleDotsLoader. La page n'est révélée qu'une fois le fond, le logo,
    // la rangée d'épisodes et les éléments différés stabilisés.
    property bool visualRevealPending: false
    property bool _visualRevealHasShown: false
    property bool _visualRevealReturnMode: false
    property bool _externalFocusWasLost: false
    property double _visualRevealStartedMs: 0
    property double _visualRevealSuppressReturnUntilMs: 0
    property int visualRevealInitialMinMs: 680
    property int visualRevealReturnMinMs: 220
    property int visualRevealPollMs: 80
    property int visualRevealSettleMs: 160
    property int visualRevealHardTimeoutMs: 3200
    readonly property bool loadingGateActive: !!(isLoading || visualRevealPending)
    readonly property bool shellLoading: loadingGateActive
    readonly property string shellLoadingError: loadingError || ""

    property bool _episodesFetchedOnce: false
    property bool _seasonFetchedOnce: false
    property bool _episodesRowAlive: true
    property int minLoadingMs: 350
    property int emptyEpisodesGraceMs: 2600
    property int _loadingStartedMs: 0
    property string loadingError: ""
    function _loadingTitle(){ return ctxOk ? "Chargement" : "Initialisation"; }
    Timer {
        id: emptyEpisodesGraceTimer
        interval: emptyEpisodesGraceMs
        repeat: false
        onTriggered: {
            if (disposed) return;
            if (isLoading && _episodesFetchedOnce && _seasonFetchedOnce && episodes && episodes.length === 0)
                scheduleEndLoading();
        }
    }
    Timer {
        id: loadingHardTimeout
        interval: 15000
        repeat: false
        onTriggered: {
            if (disposed) return;
            if (isLoading && !(_episodesFetchedOnce && _seasonFetchedOnce)){
                ctxWaitTimer.stop();
                _awaitingCtx = false;
                loadingError = "Timeout réseau / API.";
            }
        }
    }
    function _visualImageSettled(img){
        if (!img || !String(img.source || "").length) return true;
        return img.status === Image.Ready || img.status === Image.Error;
    }
    function _visualEpisodesRowSettled(){
        if (!episodes || !episodes.length) return true;
        var it = (episodesRowLoader.status === Loader.Ready) ? episodesRowLoader.item : null;
        if (!it || it._booting === true) return false;
        try { if (it.posterGateMax !== undefined && Number(it.posterGateMax) < 0) return false; } catch(e0) {}
        return true;
    }
    function _visualDetailsSettled(){
        if (!episodes || !episodes.length || !selectedEpisodeId) return true;
        return !!(selectedDetails && String(selectedDetails.Id || "") === selectedEpisodeId);
    }
    function _visualAssetsSettled(){
        if (disposed || isLoading || !postFirstFrame || layoutSettle || initialWarmup || !_visualEpisodesRowSettled()) return false;
        if (_bgWantedUrl && bgDebounceTimer.running) return false;
        if (_bgActiveUrl && !_visualImageSettled(blurredBG)) return false;
        if (showSeriesLogo && seriesLogoBox.width >= seriesLogoMinW && (!_logoArmed || !_visualImageSettled(seriesLogoImage))) return false;
        if (showActionPanel && actionCircles.visible && (!_actionsArmed || (actionButtonsLoader.active && actionButtonsLoader.status !== Loader.Ready))) return false;
        return _visualDetailsSettled();
    }
    function _armVisualReveal(reason, returnMode){
        if (disposed) return;
        _visualRevealReturnMode = returnMode === true; _visualRevealStartedMs = Date.now(); visualRevealPending = true;
        visualRevealSettleTimer.stop(); visualRevealPollTimer.restart(); visualRevealHardTimer.restart();
    }
    function _releaseVisualReveal(reason){
        if (!visualRevealPending) return;
        visualRevealPollTimer.stop(); visualRevealSettleTimer.stop(); visualRevealHardTimer.stop();
        visualRevealPending = false; _visualRevealHasShown = true; _visualRevealReturnMode = false;
        _visualRevealSuppressReturnUntilMs = Date.now() + 900; _externalFocusWasLost = false;
        var suffix = "visualReveal:" + (reason || "ready");
        requestReflow(suffix); requestPinEpisodes(suffix);
        if (_hasExplicitEpisodeRestoreTarget()) restoreFocusFromPlaylist(suffix);
        requestApplyFocus(); bumpActivity();
        if (_guestPersonReturnPending) _scheduleGuestPersonReturnRestore();
    }
    function _tickVisualReveal(){
        if (!visualRevealPending || disposed) return;
        if (isLoading) { visualRevealPollTimer.restart(); return; }
        var elapsed = Math.max(0, Date.now() - Number(_visualRevealStartedMs || 0));
        var minHold = _visualRevealReturnMode ? visualRevealReturnMinMs : visualRevealInitialMinMs;
        if (elapsed >= minHold && _visualAssetsSettled()) {
            if (!visualRevealSettleTimer.running) visualRevealSettleTimer.restart();
        } else visualRevealPollTimer.restart();
    }
    Timer {
        id: visualRevealPollTimer
        interval: Math.max(40, visualRevealPollMs)
        repeat: false
        onTriggered: _tickVisualReveal()
    }
    Timer {
        id: visualRevealSettleTimer
        interval: Math.max(80, visualRevealSettleMs)
        repeat: false
        onTriggered: {
            if (!visualRevealPending) return;
            if (_visualAssetsSettled())
                _releaseVisualReveal("assets-ready");
            else
                visualRevealPollTimer.restart();
        }
    }
    Timer {
        id: visualRevealHardTimer
        interval: Math.max(1200, visualRevealHardTimeoutMs)
        repeat: false
        onTriggered: {
            if (visualRevealPending && !isLoading)
                _releaseVisualReveal("hard-timeout");
        }
    }

    Timer {
        id: loadingOffTimer
        interval: 140
        repeat: false
        onTriggered: {
            if (disposed) return;
            if (isLoading && _episodesFetchedOnce && _seasonFetchedOnce){
                _episodesRowAlive = true;
                var explicitRestore = _hasExplicitEpisodeRestoreTarget();
                if (explicitRestore) _armFocusRestoreGate();

                // Armer avant isLoading=false pour qu'aucune image intermédiaire
                // ne puisse apparaître entre le chargement API et la préparation visuelle.
                _armVisualReveal("loadingOffTimer", false);
                isLoading = false;

                if (explicitRestore) later(function(){ restoreFocusFromPlaylist("loadingOffTimer"); });
                else requestApplyFocus();
            }
        }
    }
    function scheduleEndLoading(){
        if (disposed || !(_episodesFetchedOnce && _seasonFetchedOnce)) return;
        if (episodes && episodes.length) loadingError = "";
        emptyEpisodesGraceTimer.stop();
        loadingOffTimer.interval = Math.max(140, minLoadingMs - (Date.now() - _loadingStartedMs));
        loadingOffTimer.restart();
    }
    function beginLoading(){
        _loadingStartedMs = Date.now(); emptyEpisodesGraceTimer.stop(); loadingError = "";
        visualRevealPending = false; _visualRevealReturnMode = false; _externalFocusWasLost = false;
        visualRevealPollTimer.stop(); visualRevealSettleTimer.stop(); visualRevealHardTimer.stop();
        idleFreezeTimer.stop(); settleTimer.stop(); posterWarmupTimer.stop(); logoArmTimer.stop();
        actionsArmTimer.stop(); detailsDebounceTimer.stop(); bgDebounceTimer.stop();
        guestPrefetchCheck.stop(); pinAfterNavTimer.stop();
        isLoading = true; postFirstFrame = false; deepIdle = false; layoutSettle = true; episodesPartial = false;
        _episodesFetchedOnce = false; _seasonFetchedOnce = false; selectedDetails = null;
        _clearDetailsCache(); _bumpGuestEpoch(); _clearGuests();
        _guestWasReady = false; _guestH = 0; episodes = null; seasonItem = null; currentIndex = 0;
        _episodesRowAlive = false; _episodesHydrated = false; _episodesSliceStart = 0; _episodesSlice = [];
        _playlistRestoreInFlight = false; _focusRestoreGate = false; _lastPlaylistRestoreKey = "";
        overlayMode = "none"; overlayData = ({}); _bgWantedUrl = ""; _bgActiveUrl = "";
        _guestPrefetch = false; initialWarmup = true; _logoArmed = false; _actionsArmed = false;
        _detailsPending = false; _guestAnchorY = -1; _episodesBottomY = -1; _deferPinAfterNav = false;
        if (currentFocus === focusHud) currentFocus = 1;
        loadingHardTimeout.restart();
    }
    function maybeEndLoading(){
        if (disposed || !(_episodesFetchedOnce && _seasonFetchedOnce)) return;
        if (episodes && episodes.length === 0) {
            if (!emptyEpisodesGraceTimer.running) emptyEpisodesGraceTimer.restart();
            return;
        }
        scheduleEndLoading();
    }
    onIsLoadingChanged: {
        if (disposed) return;
        deepIdle = false;
        idleFreezeTimer.stop();
        postFirstFrame = false;
        _deferPinAfterNav = false;
        pinAfterNavTimer.stop();
        if (isLoading){
            _episodesRowAlive = false;
            layoutSettle = true;
            settleTimer.stop();
            initialWarmup = true;
            posterWarmupTimer.stop();
            _logoArmed = false;
            logoArmTimer.stop();
            _actionsArmed = false;
            actionsArmTimer.stop();
            _episodesHydrated = false;
            _episodesSliceStart = 0;
            _episodesSlice = [];
            withEpisodesRow(function(it){ if (it.onLoadingGateChanged) it.onLoadingGateChanged(); });
        } else {
            emptyEpisodesGraceTimer.stop();
            loadingHardTimeout.stop();
            _episodesRowAlive = true;
            layoutSettle = true;
            settleTimer.restart();
            schedulePostFirstFrame();
            initialWarmup = true;
            posterWarmupTimer.restart();
            _logoArmed = false;
            logoArmTimer.interval = extrasArmDelayMs;
            logoArmTimer.restart();
            _actionsArmed = false;
            actionsArmTimer.interval = Math.max(220, extrasArmDelayMs - 120);
            actionsArmTimer.restart();
            withEpisodesRow(function(it){ if (it.onLoadingGateChanged) it.onLoadingGateChanged(); });
            if (_hasExplicitEpisodeRestoreTarget()) later(function(){ restoreFocusFromPlaylist("isLoading:false"); });
            else requestApplyFocus();
            bumpActivity();
            later(function(){
                requestReflow("loadingOff");
                requestPinEpisodes("isLoading:false");
            });
        }
    }
    onPostFirstFrameChanged: if (visualRevealPending) visualRevealPollTimer.restart()
    onLayoutSettleChanged: if (visualRevealPending) visualRevealPollTimer.restart()
    onInitialWarmupChanged: if (visualRevealPending) visualRevealPollTimer.restart()

    property bool _awaitingCtx: false
    property int _ctxWaitTries: 0
    function startAwaitCtx(tag){
        if (disposed) return;
        if (ctxOk){ later(function(){ requestFetch(tag || "ctxOk"); }); return; }
        if (_awaitingCtx) return;
        _awaitingCtx = true;
        _ctxWaitTries = 0;
        ctxWaitTimer.start();
    }
    Timer {
        id: ctxWaitTimer
        interval: 90
        repeat: false
        running: false
        onTriggered: {
            if (disposed){ stop(); return; }
            if (ctxOk){
                stop();
                _awaitingCtx = false;
                requestFetch("ctxReady");
                return;
            }
            _ctxWaitTries++;
            if (_awaitingCtx)
                restart();
        }
    }
    onCtxOkChanged: {
        if (disposed) return;
        if (ctxOk && _awaitingCtx){
            ctxWaitTimer.stop();
            _awaitingCtx = false;
            later(function(){ requestFetch("ctxOkChanged"); });
        }
    }
    function triggerFetch(reason){
        if (!ready || disposed) return;
        if (!ctxOk){
            beginLoading();
            startAwaitCtx("triggerFetch:" + (reason || ""));
            return;
        }
        beginLoading();
        SeasonUtils.fetchSeasonAndEpisodes(seasonpage, Jellyfin);
    }
    property int detailsDebounceMs: 240
    property bool _detailsPending: false
    Timer {
        id: detailsDebounceTimer
        interval: detailsDebounceMs
        repeat: false
        onTriggered: {
            if (disposed || !episodes || episodes.length === 0) return;
            if (isLoading || overlayOpen || layoutSettle) {
                _detailsPending = true;
                detailsDebounceTimer.restart();
                return;
            }
            _detailsPending = false;
            detailsReqSeq++;
            SeasonUtils.fetchSelectedDetails(seasonpage, Jellyfin);
        }
    }
    function requestDetailsFetchDebounced(){
        if (disposed) return;
        _detailsPending = true;
        detailsDebounceTimer.restart();
    }
    property int bgDebounceMs: 520
    property string _bgWantedUrl: ""
    property string _bgActiveUrl: ""
    property bool postFirstFrame: false
    Timer {
        id: bgDebounceTimer
        interval: bgDebounceMs
        repeat: false
        onTriggered: {
            if (disposed) return;
            if (_bgWantedUrl === _bgActiveUrl) return;
            if (!_bgWantedUrl || _bgWantedUrl.length === 0) return;
            _bgActiveUrl = _bgWantedUrl;
        }
    }
    function requestBgUpdate(){
        if (disposed || !serverUrl) return;
        _bgWantedUrl = SeasonUtils.computeBgUrl(seasonpage);
        bgDebounceTimer.restart();
    }
    onBgBlurChanged: requestBgUpdate()
    property var _tagsAll: []
    property var _tagsShown: []
    property int _tagsExtraCount: 0
    property string _tagsSrcId: ""
    property bool _tagsSrcIsDetails: false
    property string _tagsSignature: ""
    function recomputeTagsFromDetails(force){
        SeasonUtils.recomputeTagsFromDetails(seasonpage, force);
    }
    onSelectedDetailsChanged: {
        if (selectedDetails && selectedDetails.Id) _rememberEpisodeDetails(selectedDetails);
        recomputeTagsFromDetails(true);
        requestPinEpisodes("selectedDetailsChanged");
        if (visualRevealPending) visualRevealPollTimer.restart();
    }
    function restoreFocusFromPlaylist(reason){
        if (!episodes || !episodes.length || _playlistRestoreInFlight) return;
        var idx = _desiredRestoreIndex();
        if (idx < 0) return;
        var key = _playlistRestoreKey(idx), targetId = _restoreTargetIdForIndex(idx);
        if (_lastPlaylistRestoreKey === key && targetId && selectedEpisodeId === targetId &&
                currentIndex === idx && currentFocus === 1 && _episodesHydrated) return;
        _playlistRestoreInFlight = true; _focusRestoreGate = true; _restoringFocus = true;
        currentIndex = idx; prepareEpisodesSlice();
        if (restoreY >= 0) {
            var maxY = Math.max(0, Number(rootFlick.contentHeight || 0) - Number(rootFlick.height || 0));
            rootFlick.contentY = Math.max(0, Math.min(Number(restoreY), maxY));
        }
        rootFlick.scrollToEpisodes(true);
        later(function(){
            currentFocus = 1; _applyFocusNow(); _restoringFocus = false;
            detailsReqSeq++; SeasonUtils.fetchSelectedDetails(seasonpage, Jellyfin);
            requestPinEpisodes("restoreFocusFromPlaylist");
            maybeHydrateEpisodesRow();
            _maybeReleaseFocusRestoreGate();
        });
    }
    Component {
        id: loadingLayerCmp
        FocusScope {
            id: layer
            anchors.fill: parent
            focus: true
            readonly property bool runGate: !!(seasonpage.loadingGateActive && layer.visible && layer.enabled && !seasonpage.disposed)
            Rectangle { anchors.fill: parent; color: "#000" }
            // Loader visuel global fourni par ShellPage.

            Keys.onPressed: {
                seasonpage.bumpActivity();
                if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape){
                    seasonpage.requestBackToMenu();
                    event.accepted = true;
                }
            }
        }
    }
    Loader {
        id: loadingLayer
        anchors.fill: parent
        z: 9998
        active: !!loadingGateActive
        visible: active
        sourceComponent: loadingLayerCmp
    }
    Item {
        id: contentLayer
        anchors.fill: parent
        visible: !isLoading
        enabled: !isLoading
        opacity: isLoading ? 0.0 : 1.0
        Behavior on opacity {
            enabled: !layoutSettle
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Rectangle { anchors.fill: parent; color: "#000"; z: -2 }
        Image {
            id: blurredBG
            anchors.fill: parent
            z: -1
            fillMode: Image.PreserveAspectCrop
            // _bgActiveUrl vient de SeasonUtils et doit rester sans token.
            // Ne jamais logger Image.source/_bgActiveUrl en brut.
            source: postFirstFrame ? _bgActiveUrl : ""
            opacity: 0.90
            visible: source !== ""
            cache: false
            asynchronous: true
            mipmap: false
            smooth: false
            onStatusChanged: if (visualRevealPending) visualRevealPollTimer.restart()
        }
        Rectangle { anchors.fill: parent; color: "#0b0d14"; opacity: 0.40 }
        Components.ClockHUD {
            id: clockHud
            z: 3000
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 20
            anchors.rightMargin: 24
            visible: !!(postFirstFrame && !isLoading && !h.overlayOpen)
            active: visible
            hudOpacity: h.hudOpacity
            scrolling: h._scrolling
            fbx: h.fbx
            serverUrl: h.serverUrl
            userId: h.userId
            userImageTag: h.userImageTag
            userName: h.userName
            showUserName: true
            clockEnabled: !!h.showClock
            fontPx: 22
            showAvatar: true
            avatarSize: 52
            avatarInteractive: false
            avatarFocus: (h.currentFocus === h.focusHud)
            onRequestFocusBelow: {
                h.bumpActivity();
                h.restoreFocusFromHud();
            }
        }
        Flickable {
            id: rootFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: pageColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Behavior on contentY {
                enabled: !rootFlick.dragging && !_suppressContentYAnim
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
            function _setScrollY(target, force){
                var mustJump = layoutSettle;
                if (mustJump) jumpToY(target);
                else contentY = target;
            }
            function jumpToY(target){
                _internalJump = true;
                _suppressContentYAnim = true;
                contentY = target;
                later(function(){
                    _suppressContentYAnim = false;
                    _internalJump = false;
                    requestHudOpacityUpdate("jumpToY.done");
                });
            }
            function clamp(v, minV, maxV){ return Math.max(minV, Math.min(maxV, v)); }
            function safeMapY(item){
                if (!item) return 0;
                try {
                    var p = item.mapToItem(rootFlick.contentItem, 0, 0);
                    return p.y;
                } catch (e) { return 0; }
            }
            function scrollToTop(force){
                var target = 0;
                if (!force && Math.abs(target - contentY) < 6) return;
                _setScrollY(target, force);
            }
            function _episodesTargetY(){
                var bottom = Number(_episodesBottomY);
                if (!(bottom > 0)) requestAnchorRecompute("episodesTargetY");
                if (!(bottom > 0)){
                    var y = safeMapY(episodesRowLoader);
                    bottom = y + (Number(episodesRowLoader.height) || 0);
                }
                return clamp(bottom - height, 0, Math.max(0, contentHeight - height));
            }
            function scrollToEpisodes(force){
                var target = _episodesTargetY();
                if (!force && Math.abs(target - contentY) < 6) return;
                _setScrollY(target, force);
            }
            function pinEpisodesBottom(){
                if (!episodesRowLoader || episodesRowLoader.height <= 0) return;
                var target = _episodesTargetY();
                if (Math.abs(target - contentY) < 0.5) return;
                jumpToY(target);
            }
            function scrollToGuests(force){
                var y = Number(_guestAnchorY);
                if (!(y > 0)) requestAnchorRecompute("scrollToGuests");
                if (!(y > 0)) y = safeMapY(guestAnchor);
                var hGuess = 260;
                safeCall(function(){
                    if (guestLoader && guestLoader.status === Loader.Ready && guestLoader.item){
                        var ih = Number(guestLoader.item.implicitHeight) || 0;
                        if (ih > 0) hGuess = Math.ceil(ih);
                    } else if (guestLoader && guestLoader.height > 0){
                        hGuess = Math.ceil(guestLoader.height);
                    }
                });
                var bottom = y + hGuess;
                var target = clamp(bottom - height + guestScrollPadPx, 0, Math.max(0, contentHeight - height));
                var moved = Math.abs(target - contentY) >= 1;
                if (!force && !moved) return;
                _setScrollY(target, force);
            }
            onContentYChanged: {
                if (_internalJump) return;
                bumpActivity();
                viewportPulseTimer.restart();
                requestHudOpacityUpdate("contentYChanged");
                _maybeGuestPrefetchKick();
            }
            onHeightChanged: {
                bumpActivity();
                viewportGen++;
                requestAnchorRecompute("heightChanged");
                requestHudOpacityUpdate("heightChanged");
                _maybeGuestPrefetchKick();
                if (_pinEpisodesActive) requestPinEpisodes("heightChanged");
            }
            onContentHeightChanged: {
                bumpActivity();
                requestAnchorRecompute("contentHeightChanged");
                _maybeGuestPrefetchKick();
                if (_pinEpisodesActive) requestPinEpisodes("contentHeightChanged");
            }
            Column {
                id: pageColumn
                width: rootFlick.width
                spacing: 0
                y: -liftAllPx
                Item { height: contentTop; width: 1 }
                Item {
                    id: headerRow
                    x: contentLeft
                    width: parent.width - (contentLeft + contentRight)
                    height: headerMain.implicitHeight
                    Column {
                        id: headerMain
                        x: headerColX
                        readonly property int _rightAvail: headerRow.width - headerColX
                        width: Math.min(Math.round(_rightAvail * rightColRatio), _effTitleMaxW)
                        spacing: 8
                        Item {
                            id: headerTitleBox
                            readonly property int profileGuardW: 160
                            readonly property int minTitleW: 420
                            readonly property int _safeW: Math.max(minTitleW, headerRow.width - headerMain.x - profileGuardW)
                            width: Math.min(parent.width, _safeW)
                            height: headerTitle.implicitHeight
                            clip: true

                            Text { textFormat: Text.PlainText;
                                id: headerTitle
                                text: selectedEpisode ? SeasonUtils.displayEpisodeTitle(selectedEpisode)
                                                      : ((seasonItem && seasonItem.Name) ? seasonItem.Name : "")
                                width: parent.width
                                color: "#ffffff"
                                font.pixelSize: 48
                                font.bold: true
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Item {
                            id: metaMarqueeBox
                            readonly property int _overviewEndX: overviewColX + Math.min(Math.round((headerRow.width - Math.max(0, overviewColX)) * rightColRatio), _effOverviewMaxW)
                            readonly property int _autoWToOverviewEnd: Math.max(240, _overviewEndX - headerMain.x)
                            width: metaLineMaxW > 0 ? metaLineMaxW : Math.min(parent.width, _autoWToOverviewEnd)
                            height: 30
                            clip: true
                            property real _mx: 0
                            property real _contentW: 0
                            property string _cycleSignature: ""
                            property string _pendingReason: ""
                            property bool _pendingForce: false
                            property bool marqueeMoving: false
                            readonly property bool _overflow: _contentW > (width + 6)
                            readonly property real _delta: _overflow ? Math.max(0, Math.ceil(_contentW - width + metaMarqueeEndPadding)) : 0
                            readonly property bool marqueeActive: _metaMarqueeEligible(_delta, metaMarqueeBox, 24, visible)
                            readonly property bool maskActive: marqueeActive && marqueeMoving && !loadingLayer.active
                            function _measureContentW(){
                                var iw = Number(metaRow.implicitWidth) || 0;
                                var cw = (metaRow.childrenRect && metaRow.childrenRect.width) ? Number(metaRow.childrenRect.width) : 0;
                                var w = Math.max(iw, cw);
                                if (Math.abs(_contentW - w) > 0.5) _contentW = w;

                            }
                            function _currentCycleSignature(){
                                return String(_tagsSignature || "") + "|w=" + Math.round(width) + "|c=" + Math.round(_contentW);
                            }
                            function _scheduleMarqueeRestart(delayMs, forceRestart, reason){
                                _measureContentW();
                                var sig = _currentCycleSignature();
                                var d = Math.max(1, delayMs || metaMarqueeRestartDelayMs);

                                if (metaRowMarqueeAnim.running && sig === _cycleSignature) {

                                    return;
                                }
                                if (!forceRestart && metaRowMarqueeAnim.running) {

                                    return;
                                }
                                _pendingReason = reason || "?";
                                _pendingForce = !!forceRestart;
                                metaMarqueeBootKick.interval = d;
                                metaMarqueeBootKick.restart();
                            }
                            onMarqueeActiveChanged: {
                                if (!marqueeActive) {

                                    _marqueeStop(metaMarqueeBox, metaRowMarqueeAnim);
                                } else {
                                    _scheduleMarqueeRestart(metaMarqueeRestartDelayMs, true, "activeChangedTrue");
                                }
                            }
                            onWidthChanged: { _measureContentW(); _scheduleMarqueeRestart(metaMarqueeRestartDelayMs, true, "boxWidthChanged"); }
                            onVisibleChanged: { if (!visible) { _marqueeStop(metaMarqueeBox, metaRowMarqueeAnim); } else _scheduleMarqueeRestart(metaMarqueeBootDelayMs, true, "visibleTrue"); }
                            Component.onCompleted: {
                                _scheduleMarqueeRestart(metaMarqueeBootDelayMs, true, "completed");
                                Qt.callLater(function(){ if (metaMarqueeBox) metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeBootDelayMs, true, "completed.callLater"); });
                            }
                            Timer {
                                id: metaMarqueeBootKick
                                interval: metaMarqueeRestartDelayMs
                                repeat: false
                                onTriggered: {

                                    metaMarqueeBox._measureContentW();
                                    var sig = metaMarqueeBox._currentCycleSignature();
                                    if (metaRowMarqueeAnim.running && sig === metaMarqueeBox._cycleSignature) {

                                        return;
                                    }
                                    metaMarqueeBox._cycleSignature = sig;
                                    metaMarqueeBox._mx = 0;
                                    if (metaRowMarqueeAnim.running) metaRowMarqueeAnim.stop();
                                    if (metaMarqueeBox.marqueeActive) metaRowMarqueeAnim.restart();

                                }
                            }
                            Connections {
                                target: seasonpage
                                function onSelectedEpisodeChanged(){ metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeBootDelayMs, true, "selectedEpisodeChanged"); }
                                function onSelectedDetailsChanged(){ metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeRestartDelayMs, false, "selectedDetailsChanged"); }
                                function onPostFirstFrameChanged(){ metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeBootDelayMs, false, "postFirstFrameChanged"); }
                                function onUiReadyChanged(){ metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeBootDelayMs, false, "uiReadyChanged"); }
                                function onViewportGenChanged(){ metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeRestartDelayMs, false, "viewportGenChanged"); }
                            }
                            SequentialAnimation {
                                id: metaRowMarqueeAnim
                                running: false
                                loops: Animation.Infinite
                                onRunningChanged: {
                                    if (!running) metaMarqueeBox.marqueeMoving = false
                                }
                                ScriptAction { script: { metaMarqueeBox._mx = 0; metaMarqueeBox.marqueeMoving = false } }
                                PauseAnimation { duration: metaMarqueeStartPauseMs }
                                ScriptAction { script: { metaMarqueeBox.marqueeMoving = true } }
                                NumberAnimation { target: metaMarqueeBox; property: "_mx"; to: -metaMarqueeBox._delta; duration: _marqueeDurationMs(metaMarqueeBox._delta, metaMarqueePxPerSec); easing.type: Easing.Linear }
                                ScriptAction { script: { metaMarqueeBox.marqueeMoving = false } }
                                PauseAnimation { duration: metaMarqueeEndPauseMs }
                                ScriptAction { script: { metaMarqueeBox.marqueeMoving = true } }
                                NumberAnimation { target: metaMarqueeBox; property: "_mx"; to: 0; duration: _marqueeDurationMs(metaMarqueeBox._delta, metaMarqueePxPerSec); easing.type: Easing.Linear }
                                ScriptAction { script: { metaMarqueeBox.marqueeMoving = false } }
                            }
                            Item {
                                id: metaRowViewport
                                anchors.fill: parent
                                clip: true
                                visible: !metaMarqueeBox.maskActive

                            Row {
                                id: metaRow
                                x: metaMarqueeBox._mx
                                spacing: 10
                                height: 30
                                onImplicitWidthChanged: { metaMarqueeBox._measureContentW(); metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeRestartDelayMs, false, "rowImplicitWidthChanged"); }
                                onChildrenRectChanged: { metaMarqueeBox._measureContentW(); metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeRestartDelayMs, false, "rowChildrenRectChanged"); }
                                Item {
                                    id: ratingWrap
                                    readonly property var it: _it()
                                    visible: (it && it.CommunityRating !== undefined)
                                    height: 30
                                    width: ratingRow.implicitWidth
                                    Row {
                                        id: ratingRow
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 6
                                        Item {
                                            id: ratingStar
                                            width: 20
                                            height: 20
                                            anchors.verticalCenter: parent.verticalCenter
                                            Canvas {
                                                anchors.fill: parent
                                                visible: ratingWrap.visible
                                                antialiasing: true
                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    ctx.clearRect(0, 0, width, height)
                                                    var cx = width * 0.5
                                                    var cy = height * 0.52
                                                    var outer = Math.min(width, height) * 0.47
                                                    var inner = outer * 0.45
                                                    ctx.beginPath()
                                                    for (var i = 0; i < 10; i++) {
                                                        var a = -Math.PI / 2 + i * Math.PI / 5
                                                        var r = (i % 2 === 0) ? outer : inner
                                                        var x = cx + Math.cos(a) * r
                                                        var y = cy + Math.sin(a) * r
                                                        if (i === 0) ctx.moveTo(x, y)
                                                        else ctx.lineTo(x, y)
                                                    }
                                                    ctx.closePath()
                                                    ctx.fillStyle = "#FFC53F"
                                                    ctx.fill()
                                                }
                                            }
                                        }
                                        Text { textFormat: Text.PlainText;
                                            text: SeasonUtils.fmtRatingFr(ratingWrap.it ? (ratingWrap.it.CommunityRating || 0) : 0)
                                            color: "#ffffff"
                                            font.pixelSize: 20
                                            font.bold: true
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }
                                Text { textFormat: Text.PlainText; text: SeasonUtils.sxeCode(selectedEpisode, seasonItem); color: "#ffffff"; font.pixelSize: 20; font.bold: true; visible: text.length > 0; anchors.verticalCenter: parent.verticalCenter }
                                Text { textFormat: Text.PlainText; text: (selectedEpisode && selectedEpisode.PremiereDate) ? SeasonUtils.fmtDateLong(selectedEpisode.PremiereDate) : ""; color: "#ffffff"; font.pixelSize: 20; font.bold: true; visible: !!(selectedEpisode && selectedEpisode.PremiereDate); anchors.verticalCenter: parent.verticalCenter }
                                Repeater {
                                    model: _tagsAll
                                    onModelChanged: { metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeBootDelayMs, true, "repeaterModelChanged"); }
                                    delegate: Rectangle {
                                        radius: 6
                                        height: 30
                                        color: "#e0e3ea"
                                        border.color: "#c8ceda"
                                        border.width: 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        Component.onCompleted: Qt.callLater(function(){ metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeBootDelayMs, false, "tagDelegateComplete"); })
                                        Text { textFormat: Text.PlainText;
                                            id: tagTxt
                                            anchors.centerIn: parent
                                            text: modelData
                                            color: "#1b2233"
                                            font.pixelSize: 16
                                            onPaintedWidthChanged: { metaMarqueeBox._scheduleMarqueeRestart(metaMarqueeRestartDelayMs, false, "tagPaintedWidthChanged"); }
                                        }
                                        width: Math.max(40, Math.ceil(tagTxt.paintedWidth) + 18)
                                    }
                                }
                            }
                            }

                            ShaderEffectSource {
                                id: metaRowTexture
                                sourceItem: metaRowViewport
                                hideSource: metaMarqueeBox.maskActive
                                live: metaMarqueeBox.maskActive
                                recursive: false
                                visible: false
                            }

                            Item {
                                id: metaRowFadeMask
                                anchors.fill: metaRowViewport
                                visible: false

                                readonly property bool atStart: metaMarqueeBox._mx >= -1
                                readonly property bool atEnd: metaMarqueeBox._delta <= 1
                                    || metaMarqueeBox._mx <= -(metaMarqueeBox._delta - 1)

                                Rectangle {
                                    anchors.fill: parent
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.00; color: metaRowFadeMask.atStart ? "#ff000000" : "#00000000" }
                                        GradientStop { position: 0.10; color: "#ff000000" }
                                        GradientStop { position: 0.90; color: "#ff000000" }
                                        GradientStop { position: 1.00; color: metaRowFadeMask.atEnd ? "#ff000000" : "#00000000" }
                                    }
                                }
                            }

                            OpacityMask {
                                id: metaMaskedLine
                                anchors.fill: metaRowViewport
                                source: metaRowTexture
                                maskSource: metaRowFadeMask
                                visible: metaMarqueeBox.maskActive
                                cached: false
                            }

                        }
                    }
                }
                Item { height: gapBelowHeader; width: 1 }
                Item {
                    id: metaOverviewRow
                    x: contentLeft
                    width: parent.width - (contentLeft + contentRight)
                    height: Math.max(leftMeta.implicitHeight, overviewBox.height, actionCircles.visible ? (actionCircles.y + actionCircles.height) : 0)
                    clip: false
                    z: 10
                    Column {
                        id: leftMeta
                        width: leftMetaW
                        spacing: 10
                        anchors.left: parent.left
                        anchors.leftMargin: -50
                        Column {
                            spacing: 4
                            visible: true
                            Text { textFormat: Text.PlainText;
                                text: "RÉALISÉ PAR"
                                color: "#ffffff"
                                font.pixelSize: 14
                                font.bold: true
                            }
                            Item {
                                id: directorLineBox
                                readonly property int maxVisibleChars: 10
                                readonly property int directorFontPx: 18
                                readonly property string dirStr: {
                                    var s = SeasonUtils.directorNames(_it());
                                    return s.length > 0 ? s : "Inconnu";
                                }

                                FontMetrics {
                                    id: fmDirector
                                    font.pixelSize: directorLineBox.directorFontPx
                                }

                                function _directorViewportW(){
                                    var sample = dirStr.slice(0, maxVisibleChars);
                                    if (!sample || sample.length <= 0)
                                        sample = "Inconnu";
                                    var r = fmDirector.boundingRect(sample);
                                    var w = (r && r.width !== undefined) ? Math.ceil(r.width) : 92;
                                    return Math.max(64, Math.min(108, w + 4));
                                }

                                width: _directorViewportW()
                                height: Math.max(22, directorMovingText.implicitHeight)
                                clip: false

                                Item {
                                    id: directorViewport
                                    anchors.fill: parent
                                    clip: true
                                    property real _mx: 0
                                    property bool marqueeMoving: false
                                    readonly property real _delta: Math.max(0, directorMovingText.paintedWidth - width)
                                    readonly property bool marqueeActive: marqueeAllowed
                                        && !!uiReady
                                        && !isLoading
                                        && !overlayOpen
                                        && !_scrolling
                                        && directorLineBox.dirStr.length > directorLineBox.maxVisibleChars
                                        && _delta > 4
                                    readonly property bool maskActive: marqueeActive && marqueeMoving && !loadingLayer.active

                                    function restartMarquee(){
                                        if (!marqueeActive) {
                                            marqueeMoving = false;
                                            _mx = 0;
                                            directorMarqueeAnim.stop();
                                            return;
                                        }
                                        _mx = 0;
                                        marqueeMoving = false;
                                        directorMarqueeAnim.restart();
                                    }

                                    onMarqueeActiveChanged: restartMarquee()
                                    onWidthChanged: restartMarquee()
                                    onVisibleChanged: restartMarquee()

                                    SequentialAnimation {
                                        id: directorMarqueeAnim
                                        running: false
                                        loops: Animation.Infinite
                                        onRunningChanged: {
                                            if (!running) directorViewport.marqueeMoving = false
                                        }
                                        ScriptAction { script: { directorViewport._mx = 0; directorViewport.marqueeMoving = false } }
                                        PauseAnimation { duration: marqueePauseMs }
                                        ScriptAction { script: { directorViewport.marqueeMoving = true } }
                                        NumberAnimation {
                                            target: directorViewport
                                            property: "_mx"
                                            to: -Math.max(1, directorViewport._delta)
                                            duration: _marqueeDurationMs(Math.max(1, directorViewport._delta), marqueePxPerSec)
                                            easing.type: Easing.Linear
                                        }
                                        ScriptAction { script: { directorViewport.marqueeMoving = false } }
                                        PauseAnimation { duration: marqueePauseMs }
                                        ScriptAction { script: { directorViewport.marqueeMoving = true } }
                                        NumberAnimation {
                                            target: directorViewport
                                            property: "_mx"
                                            to: 0
                                            duration: _marqueeDurationMs(Math.max(1, directorViewport._delta), marqueePxPerSec)
                                            easing.type: Easing.Linear
                                        }
                                        ScriptAction { script: { directorViewport.marqueeMoving = false } }
                                    }

                                    Text { textFormat: Text.PlainText;
                                        id: directorMovingText
                                        text: directorLineBox.dirStr
                                        color: seasonpage.metadataValueColor
                                        font.pixelSize: directorLineBox.directorFontPx
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideNone
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: directorViewport._mx
                                        onTextChanged: directorViewport.restartMarquee()
                                        onPaintedWidthChanged: directorViewport.restartMarquee()
                                    }
                                }

                                ShaderEffectSource {
                                    id: directorLineTexture
                                    sourceItem: directorViewport
                                    hideSource: directorViewport.maskActive
                                    live: directorViewport.maskActive
                                    recursive: false
                                    visible: false
                                }

                                Item {
                                    id: directorLineFadeMask
                                    width: directorViewport.width
                                    height: directorViewport.height
                                    visible: false

                                    readonly property bool atStart: directorViewport._mx >= -1
                                    readonly property bool atEnd: directorViewport._delta <= 1
                                        || directorViewport._mx <= -(directorViewport._delta - 1)

                                    Rectangle {
                                        anchors.fill: parent
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.00; color: directorLineFadeMask.atStart ? "#ff000000" : "#00000000" }
                                            GradientStop { position: 0.16; color: "#ff000000" }
                                            GradientStop { position: 0.84; color: "#ff000000" }
                                            GradientStop { position: 1.00; color: directorLineFadeMask.atEnd ? "#ff000000" : "#00000000" }
                                        }
                                    }
                                }

                                OpacityMask {
                                    id: directorMaskedLine
                                    anchors.fill: directorViewport
                                    source: directorLineTexture
                                    maskSource: directorLineFadeMask
                                    visible: directorViewport.maskActive
                                    cached: false
                                }
                            }
                        }
                        Column {
                            spacing: 4
                            visible: true
                            Text { textFormat: Text.PlainText; text: "DURÉE"; color: "#ffffff"; font.pixelSize: 14; font.bold: true }
                            Text { textFormat: Text.PlainText;
                                text: (selectedEpisode && selectedEpisode.RunTimeTicks) ? SeasonUtils.fmtMinutesFromTicks(selectedEpisode.RunTimeTicks) : "Inconnu"
                                color: seasonpage.metadataValueColor
                                font.pixelSize: 18
                            }
                        }
                        Column {
                            spacing: 4
                            visible: true
                            Text { textFormat: Text.PlainText; text: "FIN"; color: "#ffffff"; font.pixelSize: 14; font.bold: true }
                            Text { textFormat: Text.PlainText;
                                id: endTxt
                                text: (selectedEpisode && selectedEpisode.RunTimeTicks) ? SeasonUtils.endTimeFor(selectedEpisode.RunTimeTicks) : "Inconnu"
                                color: seasonpage.metadataValueColor
                                font.pixelSize: 18
                            }
                            Timer {
                                id: endTimeTimer
                                interval: endTimeTickMs
                                repeat: true
                                running: !!(canRunTimers && !!(selectedEpisode && selectedEpisode.RunTimeTicks) && isInViewport(metaOverviewRow, 80) && (viewportGen >= 0))
                                onTriggered: {
                                    if (selectedEpisode && selectedEpisode.RunTimeTicks){
                                        var t = SeasonUtils.endTimeFor(selectedEpisode.RunTimeTicks);
                                        if (endTxt.text !== t) endTxt.text = t;
                                    }
                                }
                            }
                            Connections {
                                target: seasonpage
                                ignoreUnknownSignals: true
                                function onSelectedEpisodeChanged(){
                                    if (selectedEpisode && selectedEpisode.RunTimeTicks){
                                        var t = SeasonUtils.endTimeFor(selectedEpisode.RunTimeTicks);
                                        if (endTxt.text !== t) endTxt.text = t;
                                    } else endTxt.text = "Inconnu";
                                }
                                function onOverlayModeChanged(){
                                    if (!overlayOpen && selectedEpisode && selectedEpisode.RunTimeTicks){
                                        var t2 = SeasonUtils.endTimeFor(selectedEpisode.RunTimeTicks);
                                        if (endTxt.text !== t2) endTxt.text = t2;
                                    }
                                }
                            }
                        }
                    }
                    FocusScope {
                        id: overviewBox
                        x: overviewColX
                        readonly property int _rightAvailOverview: metaOverviewRow.width - Math.max(0, overviewColX)
                        width: Math.min(Math.round(_rightAvailOverview * rightColRatio), _effOverviewMaxW)
                        anchors.top: parent.top
                        FontMetrics { id: fmO; font: overviewText.font }
                        function minPanelH(){
                            if (overviewMinLines <= 0) return 0;
                            return Math.ceil(fmO.height * overviewText.lineHeight * overviewMinLines) + overviewPadding * 2;
                        }
                        height: Math.max(overviewText.paintedHeight + overviewPadding * 2, minPanelH())
                        focus: currentFocus === 0 && visible
                        property bool focused: (currentFocus === 0) && overviewBox.activeFocus && !overlayOpen && !isLoading
                        transformOrigin: Item.Center
                        scale: focused ? 1.03 : 1.0
                        Behavior on scale {
                            enabled: !layoutSettle && !_scrolling && !overlayOpen
                            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                        }
                        Keys.onPressed: {
                            bumpActivity();
                            if (_isActivateKey(event.key)){
                                openOverviewOverlay();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down){
                                if (actionCircles.visible && actionCircles.focusFirstAction()){
                                    currentFocus = focusActions;
                                    rootFlick.scrollToTop(true);
                                } else focusEpisodes();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up){
                                if (!focusHudAvatar()) rootFlick.scrollToTop(true);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Right){
                                event.accepted = true;
                            } else {
                                event.accepted = false;
                            }
                        }
                        onActiveFocusChanged: if (activeFocus) rootFlick.scrollToTop(true)
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                bumpActivity();
                                currentFocus = 0;
                                overviewBox.forceActiveFocus();
                                openOverviewOverlay();
                            }
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: 16
                            color: glassFocus
                            border.width: 1
                            border.color: glassBorder
                            antialiasing: false
                            opacity: overviewBox.focused ? 1.0 : 0.0
                            Behavior on opacity {
                                enabled: !layoutSettle && !_scrolling && !overlayOpen
                                NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
                            }
                        }
                        Text { textFormat: Text.PlainText;
                            id: overviewText
                            anchors.fill: parent
                            anchors.margins: overviewPadding
                            width: parent.width - overviewPadding * 2
                            color: seasonpage.metadataValueColor
                            opacity: 1.0
                            font.pixelSize: 22
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                            maximumLineCount: overviewMaxLines
                            lineHeightMode: Text.ProportionalHeight
                            lineHeight: overviewLineSpacing
                            text: {
                                var it = _it();
                                return (it && it.Overview) ? it.Overview : "";
                            }
                        }
                    }
                    Item {
                        id: seriesLogoBox
                        readonly property int _availW_right: Math.max(0, metaOverviewRow.width - (overviewBox.x + overviewBox.width) - seriesLogoGap)
                        readonly property int _w_right: Math.max(0, Math.min(seriesLogoMaxW, _availW_right))
                        readonly property int _w_left: Math.max(0, Math.min(seriesLogoMaxW, Math.max(0, overviewBox.x - seriesLogoGap)))
                        width: (seriesLogoPos === "right") ? _w_right
                             : (seriesLogoPos === "left") ? _w_left
                             : (seriesLogoPos === "underTitle") ? Math.min(seriesLogoMaxW, headerMain.width)
                             : seriesLogoMaxW
                        height: (seriesLogoPos === "right" || seriesLogoPos === "left")
                            ? Math.min(seriesLogoMaxH, overviewBox.height)
                            : seriesLogoMaxH
                        visible: showSeriesLogo && postFirstFrame && width >= seriesLogoMinW
                        transform: [ Translate { x: seriesLogoOffsetX; y: seriesLogoOffsetY } ]
                        states: [
                            State {
                                name: "right"
                                when: seriesLogoPos === "right"
                                AnchorChanges { target: seriesLogoBox; anchors.top: overviewBox.top; anchors.right: metaOverviewRow.right }
                            },
                            State {
                                name: "left"
                                when: seriesLogoPos === "left"
                                AnchorChanges { target: seriesLogoBox; anchors.top: overviewBox.top; anchors.right: overviewBox.left }
                                PropertyChanges { target: seriesLogoBox; anchors.rightMargin: seriesLogoGap }
                            },
                            State {
                                name: "underTitle"
                                when: seriesLogoPos === "underTitle"
                                AnchorChanges { target: seriesLogoBox; anchors.top: headerRow.bottom; anchors.left: headerRow.left }
                                PropertyChanges { target: seriesLogoBox; anchors.topMargin: 8 }
                            },
                            State {
                                name: "fixedTopRight"
                                when: seriesLogoPos === "fixedTopRight"
                                AnchorChanges { target: seriesLogoBox; anchors.top: contentLayer.top; anchors.right: contentLayer.right }
                                PropertyChanges { target: seriesLogoBox; z: 3500; anchors.topMargin: 20; anchors.rightMargin: 24 }
                            }
                        ]
                        transitions: [
                            Transition {
                                enabled: !layoutSettle && !_scrolling && !overlayOpen
                                NumberAnimation { properties: "x,y,width,height,opacity"; duration: 160; easing.type: Easing.OutCubic }
                            }
                        ]
                        Image {
                            id: seriesLogoImage
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: true
                            smooth: false
                            mipmap: false
                            source: (_logoArmed && postFirstFrame)
                                ? SeasonUtils.computeSeriesLogoUrl(serverUrl, seriesId, selectedEpisode, seasonItem, seriesLogoBox.width, seriesLogoMaxW)
                                : ""
                            opacity: _logoArmed ? 0.95 : 0.0
                            onStatusChanged: if (visualRevealPending) visualRevealPollTimer.restart()
                        }
                    }
                    FocusScope {
                        id: actionCircles
                        width: seriesLogoBox.width
                        readonly property int _reservedH: actionCircleSize + 10 + 6 + 18
                        height: _reservedH
                        visible: postFirstFrame && showActionPanel && ctxOk
                             && (actionPanelAnchor === "fixed" || (seriesLogoBox.visible && (seriesLogoPos === "right" || seriesLogoPos === "left")))
                        transform: [ Translate { x: actionPanelOffsetX; y: actionPanelOffsetY } ]
                        onActiveFocusChanged: {
                            if (activeFocus) currentFocus = focusActions;
                            else clearHint();
                        }
                        function _btnRoot(){ return actionButtonsLoader.item; }
                        function _buttons(){
                            var r = _btnRoot();
                            if (!r || !r.actionRep) return [];
                            var rep = r.actionRep, out = [];
                            for (var i = 0; i < rep.count; i++){
                                var b = rep.itemAt(i);
                                if (b && b.visible && b.width > 0 && b.height > 0 && b.enabled !== false) out.push(b);
                            }
                            return out;
                        }
                        function hintBar(){ var r = _btnRoot(); return (r && r.glassHintBar) ? r.glassHintBar : null; }
                        function clearHint(){
                            var hb = hintBar();
                            if (!hb) return;
                            try { hb.hintOwner = null; } catch(e0) {}
                            hb.text = "";
                            hb.opacity = 0.0;
                        }
                        function _syncHintForButton(btn){
                            if (!btn) return;
                            var hb = hintBar();
                            if (!hb) return;
                            var txt = "";
                            try { txt = String(btn.currentHint || ""); } catch(e0) {}
                            try { hb.hintOwner = btn; } catch(e1) {}
                            hb.text = txt;
                            hb.opacity = txt.length ? 0.95 : 0.0;
                        }
                        function focusFirstAction(){
                            var bs = _buttons();
                            if (bs.length === 0) return false;
                            currentFocus = focusActions;
                            bs[0].forceActiveFocus();
                            _syncHintForButton(bs[0]);
                            return true;
                        }
                        function focusIndex(idx){
                            var bs = _buttons();
                            if (idx < 0 || idx >= bs.length) return false;
                            currentFocus = focusActions;
                            bs[idx].forceActiveFocus();
                            _syncHintForButton(bs[idx]);
                            return true;
                        }
                        function indexOfFocused(){ var bs = _buttons(); for (var i = 0; i < bs.length; i++) if (bs[i].activeFocus) return i; return -1; }
                        states: [
                            State {
                                name: "rightAuto"
                                when: actionPanelAnchor !== "fixed" && seriesLogoPos === "right"
                                AnchorChanges { target: actionCircles; anchors.top: seriesLogoBox.bottom; anchors.right: metaOverviewRow.right }
                                PropertyChanges { target: actionCircles; anchors.topMargin: 12 - actionPanelLiftPx }
                            },
                            State {
                                name: "leftAuto"
                                when: actionPanelAnchor !== "fixed" && seriesLogoPos === "left"
                                AnchorChanges { target: actionCircles; anchors.top: seriesLogoBox.bottom; anchors.right: overviewBox.left }
                                PropertyChanges { target: actionCircles; anchors.topMargin: 12 - actionPanelLiftPx; anchors.rightMargin: seriesLogoGap }
                            },
                            State {
                                name: "fixed"
                                when: actionPanelAnchor === "fixed"
                                AnchorChanges { target: actionCircles; anchors.top: undefined; anchors.bottom: undefined; anchors.left: undefined; anchors.right: undefined }
                                PropertyChanges { target: actionCircles; x: actionPanelFixedX; y: actionPanelFixedY }
                            }
                        ]
                        Keys.onPressed: {
                            bumpActivity();
                            if (event.key === Qt.Key_Left){
                                var i = indexOfFocused(), bs = _buttons();
                                if (bs.length > 0) focusIndex(Math.max(0, (i < 0 ? (bs.length - 1) : (i - 1))));
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Right){
                                var i2 = indexOfFocused(), bs2 = _buttons();
                                if (bs2.length > 0) focusIndex(Math.min(bs2.length - 1, (i2 < 0 ? 0 : (i2 + 1))));
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up){
                                currentFocus = 0;
                                overviewBox.forceActiveFocus();
                                rootFlick.scrollToTop(true);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down){
                                focusEpisodes();
                                event.accepted = true;
                            }
                        }
                        Loader {
                            id: actionButtonsLoader
                            active: !!(actionCircles.visible && _actionsArmed && !overlayOpen && postFirstFrame && !layoutSettle)
                            anchors.fill: parent
                            onLoaded: requestPinEpisodes("actionButtonsLoader.onLoaded")
                            sourceComponent: Component {
                                Item {
                                    id: abRoot
                                    property alias glassHintBar: glassHintBar
                                    property alias actionRep: actionRep
                                    readonly property var actionTypes: ["restart","resume","toggleLike","toggleSeen","shuffle"]
                                    implicitHeight: actionCircles.height
                                    Row {
                                        id: actionRow
                                        anchors.top: parent.top
                                        anchors.right: parent.right
                                        spacing: actionCircleGap
                                        Repeater {
                                            id: actionRep
                                            model: abRoot.actionTypes
                                            delegate: Components.GlassCircleButtonSeason {
                                                size: actionCircleSize
                                                actionType: modelData
                                                serverUrl: h.serverUrl
                                                userId: h.userId
                                                itemId: selectedEpisode ? selectedEpisode.Id : ""
                                                itemTitle: selectedEpisode ? SeasonUtils.displayEpisodeTitle(selectedEpisode) : ""
                                                userData: selectedDetails ? selectedDetails.UserData : (selectedEpisode ? selectedEpisode.UserData : null)
                                                runTimeTicks: selectedEpisode ? (Number(selectedEpisode.RunTimeTicks) || 0) : 0
                                                seasonId: h.seasonId
                                                seriesId: h.seriesId
                                                itemData: selectedEpisode || null
                                                isMissingOverride: selectedEpisode ? !h._episodePlayableForShuffle(selectedEpisode) : false
                                                shuffleEpisodeProvider: (modelData === "shuffle") ? function(preferUnplayed){ return h.pickOwnedShuffleEpisode(preferUnplayed); } : null
                                                shuffleFallbackToJellyfinWhenProviderEmpty: (modelData === "shuffle") ? false : true
                                                explicitHintTarget: glassHintBar
                                                Keys.onDownPressed: { h.focusEpisodes(); event.accepted = true; }
                                            }
                                        }
                                    }
                                    Text { textFormat: Text.PlainText;
                                        id: glassHintBar
                                        objectName: "GlassHintBar"
                                        // Le texte appartient au bouton actuellement focusé.
                                        // Évite qu'un toggle asynchrone d'un autre bouton
                                        // (vu/favori) écrase le hint "Lire"/"Aléatoire", etc.
                                        property var hintOwner: null
                                        anchors.top: actionRow.bottom
                                        anchors.topMargin: 6
                                        anchors.horizontalCenter: actionRow.horizontalCenter
                                        text: ""
                                        color: "#E9ECFF"
                                        // Garde visuel contre toute republication tardive hors des actions.
                                        opacity: (currentFocus === focusActions && text && text.length) ? 0.95 : 0.0
                                        font.pixelSize: 16
                                        visible: currentFocus === focusActions
                                    }
                                }
                            }
                        }
                    }
                }
                Item {
                    id: beforeEpisodesSpacer
                    width: 1
                    height: _episodesSpacerH
                }
                Loader {
                    id: episodesRowLoader
                    x: -seasonpage.episodesRowBleedPx
                    width: pageColumn.width + (seasonpage.episodesRowBleedPx * 2)
                    height: episodeCardH + 58 + seasonpage.episodesRowTopPad
                    active: _episodesRowAlive
                    onHeightChanged: requestAnchorRecompute("episodesRow.heightChanged")
                    transform: Translate { y: -(Number(seasonpage._episodesExtraUp) + seasonpage.episodesRowTopPad) }
                    sourceComponent: Components.SeasonEpisodesRow {
                        id: episodesRow
                        anchors.fill: parent
                        serverUrl: h.serverUrl
                        model: h.episodesForRow
                        hydrated: h._episodesHydrated
                        focusRestoreGate: h._focusRestoreGate || h._playlistRestoreInFlight || h._restoringFocus
                        fallbackPosterUrl: SeasonUtils.computeSeriesPosterFallbackUrl(h)
                        currentIndex: h.episodesRowIndex
                        active: !h.isLoading && !h.overlayOpen
                        showFocus: (h.currentFocus === 1)
                        cardW: h.episodeCardW
                        cardH: h.episodeCardH

                        // Le Loader déborde de episodesRowBleedPx de chaque côté.
                        // En revenant vers la gauche, StrictlyEnforceRange plaçait les
                        // cartes intermédiaires trop près du bord : le zoom et le cadre
                        // sortaient alors de l’écran. Une valeur négative augmente la
                        // marge gauche calculée par SeasonEpisodesRow sans changer le
                        // comportement fluide ni la position côté droit.
                        firstCardLeftShift: -Math.max(16, h.episodesRowBleedPx - 6)

                        posterRequestScale: h.posterRequestScale
                        posterRequestQuality: h.posterRequestQuality
                        posterHqRequestScale: h.posterHqRequestScale
                        posterHqRequestQuality: h.posterHqRequestQuality
                        initialWarmup: h.initialWarmup
                        posterWindowWarmup: h.posterWindowWarmup
                        posterWindowNormal: h.posterWindowNormal
                        onUserIndexChanged: {
                            h.bumpActivity();
                            var localIdx = h._sigIndex(arguments, 0);
                            var absIdx = h._episodesHydrated ? localIdx : (localIdx + h._episodesSliceStart);
                            if (h._restoringFocus || h._focusRestoreGate || h._playlistRestoreInFlight) {
                                var wanted = h._desiredRestoreIndex();
                                if (wanted >= 0 && absIdx !== wanted) return;
                            }
                            h.currentIndex = absIdx;
                            var ep = (h.episodes && h.episodes.length > absIdx) ? h.episodes[absIdx] : null;
                            h.selectedDetails = (ep && ep.Id) ? h._getEpisodeDetails(ep.Id) : null;
                            h.recomputeTagsFromDetails(false);
                            h.requestDetailsFetchDebounced();
                            SeasonUtils.syncPlaylistCursor(h.playlist, ep);
                            h._clearGuests();
                            h._syncEpisodesRowPreferredId();
                            if (h.currentFocus !== 1) rootFlick.scrollToEpisodes(false);
                            h.requestPinEpisodes("episodesRow.userIndexChanged");
                            h.maybeHydrateEpisodesRow();
                            h._maybeReleaseFocusRestoreGate();
                        }
                        onPlayRequested: {
                            h.bumpActivity();
                            var localIdx = h._sigIndex(arguments, 0);
                            var epFromSignal = h._sigObj(arguments, 1, null);
                            var absIdx = h._episodesHydrated ? localIdx : (localIdx + h._episodesSliceStart);
                            var ep2 = (h.episodes && h.episodes.length > absIdx) ? h.episodes[absIdx] : epFromSignal;
                            if (!ep2 || !ep2.Id) return;
                            h.restoreEpisodeId = ep2.Id;
                            h.restoreIndex = absIdx;
                            h.restoreY = rootFlick.contentY;
                            if (typeof h.requestPlay === "function") {
                                _storeSensitiveNavContext()
                                h.requestPlay(ep2.Id, h.accessToken, h.userId, h.serverUrl, SeasonUtils.displayEpisodeTitle(ep2));
                            }
                        }
                        onRequestUp: {
                            h.bumpActivity();
                            if (actionCircles.visible && actionCircles.focusFirstAction()){
                                h.currentFocus = h.focusActions;
                                rootFlick.scrollToTop(true);
                            } else {
                                h.currentFocus = 0;
                                overviewBox.forceActiveFocus();
                                rootFlick.scrollToTop(true);
                            }
                        }
                        onRequestGuestFocus: {
                            h.bumpActivity();
                            if (h.hasGuests) h.requestGuestFocusSafe(false); else if (h.hasChapters()) h.requestChapterFocusSafe(false);
                        }
                        Component.onCompleted: {
                            h.later(function(){
                                h._syncEpisodesRowPreferredId();
                                if (!h.isLoading && !h.overlayOpen && h.currentFocus === 1){
                                    h._applyFocusNow();
                                    h.requestPinEpisodes("episodesRow.onCompleted");
                                }
                            });
                        }
                    }
                }
                Item {
                    id: guestsSection
                    width: pageColumn.width
                    height: guestsCol.implicitHeight
                    transform: Translate { y: -Number(seasonpage.guestsLiftPx) }
                    Column {
                        id: guestsCol
                        width: parent.width
                        spacing: 0
                        Item { id: guestAnchor; width: 1; height: 1; visible: true }
                        Item {
                            id: guestTitleRow
                            height: hasGuests ? 28 : 0
                            width: parent.width
                            visible: hasGuests
                            Text { textFormat: Text.PlainText;
                                text: "Stars invité·es"
                                color: "#ffffee"
                                font.pixelSize: 20
                                font.bold: true
                                anchors.left: parent.left
                                anchors.leftMargin: contentLeft
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Loader {
                            id: guestLoader
                            source: Qt.resolvedUrl("guestpage.qml")
                            width: guestsCol.width
                            active: !!(hasGuests && (_guestPrefetch || _guestPersonReturnPending || currentFocus === 2 || autoRevealGuests || (overlayOpen && _guestWasReady)))
                            enabled: !isLoading && !overlayOpen
                            visible: (status === Loader.Ready) && hasGuests
                            height: h._guestH
                            function _guestLayoutBump(tag){
                                h.syncGuestHeight();
                                requestAnchorRecompute(tag);
                                if (status === Loader.Ready && currentFocus === 2 && !overlayOpen && !isLoading) requestGuestScroll();
                            }
                            onStatusChanged: {
                                if (status === Loader.Ready) _guestWasReady = true;
                                _guestLayoutBump("guestLoader.statusChanged");
                            }
                            onHeightChanged: _guestLayoutBump("guestLoader.heightChanged")
                            Connections {
                                target: guestLoader.item
                                ignoreUnknownSignals: true
                                function onImplicitHeightChanged(){ guestLoader._guestLayoutBump("guestLoader.item.implicitHeightChanged"); }
                                function onHeightChanged(){ guestLoader._guestLayoutBump("guestLoader.item.heightChanged"); }
                            }
                            onLoaded: {
                                if (!guestLoader.item) return;
                                var g = guestLoader.item;
                                g.serverUrl = serverUrl;
                                g.accessToken = accessToken;
                                g.userId = userId;
                                g.userName = userName;
                                g.userImageTag = userImageTag;
                                if (g.hydrateInitialCount !== undefined) g.hydrateInitialCount = guestHydrateInitialCount;
                                g.host = seasonpage;
                                g.requestFocusAbove = function(){ focusEpisodes(); };
                                g.requestFocusBelow = function(){ if (hasChapters()) requestChapterFocusSafe(false); };
                                _applyGuestsToGuestpage();
                                _applyGuestReturnSnapshot(g);
                                h.syncGuestHeight();
                                requestAnchorRecompute("guestLoader.onLoaded");
                                requestGuestScroll();
                                try {
                                    if (g.actorActivated && g.actorActivated.connect)
                                        g.actorActivated.connect(function(personObj){ openPersonPage(personObj); });
                                } catch(eActor) {}
                                later(function(){
                                    if (_guestPersonReturnPending) {
                                        _scheduleGuestPersonReturnRestore();
                                    } else if (currentFocus === 2){
                                        requestGuestScroll();
                                        if (g.restoreLastGuestFocus) g.restoreLastGuestFocus();
                                        else if (g.forceFirstFocus) g.forceFirstFocus();
                                    }
                                });
                            }
                        }
                    }
                }
                Loader {
                    id: chaptersLoader
                    width: pageColumn.width; asynchronous: true; active: !!selectedEpisodeId
                    source: active ? Qt.resolvedUrl("ChaptersCarousel.qml") : ""
                    visible: status === Loader.Ready && item && item.hasContent === true
                    height: visible ? (item.implicitHeight || 0) : 0
                    transform: Translate { y: h.hasGuests ? -Number(h.guestsLiftPx) : 0 }
                    onLoaded: {
                        item.serverUrl = Qt.binding(function(){ return h.serverUrl }); item.accessToken = Qt.binding(function(){ return h.accessToken }); item.itemId = Qt.binding(function(){ return h.selectedEpisodeId }); item.sectionLeftMargin = h.contentLeft
                        item.requestFocusAbove.connect(function(){ if (h.hasGuests) h.requestGuestFocusSafe(true); else h.focusEpisodes() })
                        item.requestFocusBelow.connect(function(){})
                    }
                }
                Item { height: 36; width: 1 }
            }
        }
        Text { textFormat: Text.PlainText;
            anchors.centerIn: parent
            text: (episodes && episodes.length === 0) ? "Aucun épisode trouvé." : ""
            color: "#ffffff"
            font.pixelSize: 24
            visible: episodes && episodes.length === 0
        }
        Text { textFormat: Text.PlainText;
            anchors.centerIn: parent
            width: parent.width * 0.82
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: (loadingError && (!episodes || episodes.length === 0)) ? loadingError : ""
            color: "#ffdfdf"
            font.pixelSize: 22
            visible: text.length > 0
        }
    }
    Connections {
        target: chaptersLoader.item
        ignoreUnknownSignals: true
        function onActiveFocusChanged(){ if (chaptersLoader.item && chaptersLoader.item.activeFocus) currentFocus = focusChapters; }
        function onHasContentChanged(){ if (currentFocus === focusChapters && !hasChapters()) { if (hasGuests) requestGuestFocusSafe(true); else focusEpisodes(); } }
        function onChapterActivated(index, chapter){
            if (!selectedEpisodeId) return; restoreEpisodeId = selectedEpisodeId; restoreIndex = currentIndex; restoreY = rootFlick.contentY
            var startMs = Math.max(0, Math.floor(Number(chapter && chapter.StartPositionTicks || 0) / 10000))
            try { if (shared) shared.__redefinExplicitPlaybackStart = ({ source:"chapter", itemId:String(selectedEpisodeId), serverUrl:String(serverUrl||""), userId:String(userId||""), startMs:startMs, ts:Date.now() }) } catch(e) {}
            _storeSensitiveNavContext(); requestPlay(selectedEpisodeId, accessToken, userId, serverUrl, SeasonUtils.displayEpisodeTitle(selectedEpisode))
        }
    }
    Loader {
        id: overlayLoader
        anchors.fill: parent
        z: 9999
        readonly property bool overlayActive: !!(overlayMode === "overview")
        active: overlayActive
        visible: active
        source: overlayActive ? Qt.resolvedUrl("OverlayHub.qml") : ""
        onLoaded: {
            if (!overlayLoader.item) return;
            var hh = overlayLoader.item;
            hh.host = seasonpage;
            hh.posterMaxW = width;
            hh.posterMaxH = height;
            if (hh.requestClose) hh.requestClose.connect(closeOverlay);
            if (hh.closed) hh.closed.connect(closeOverlay);
            later(function(){ if (overlayLoader.item && overlayMode !== "none") overlayLoader.item.forceActiveFocus(); });
        }
    }
    function openOverviewOverlay(){
        if (!_guardRun() || isLoading) return;
        var ep = _it(), payload = SeasonUtils.buildOverviewOverlayPayload(ep, serverUrl);
        if (!payload) return;
        var meta = [], code = SeasonUtils.sxeCode(ep, seasonItem);
        if (code && String(code).length) meta.push(String(code));
        if (ep && ep.RunTimeTicks) meta.push(String(SeasonUtils.fmtMinutesFromTicks(ep.RunTimeTicks)));
        if (ep && ep.PremiereDate) meta.push(String(SeasonUtils.fmtDateLong(ep.PremiereDate)));
        payload.readerStyle = "episode"; payload.title = ep ? SeasonUtils.displayEpisodeTitle(ep) : "Résumé"; payload.meta = meta.join("  •  ");
        lastFocusBeforeOverlay = currentFocus; overlayMode = "overview"; overlayData = payload;
        later(function(){ if (overlayLoader.item) overlayLoader.item.forceActiveFocus(); });
    }
    function openPersonPage(personObj){
        if (!_guardRun() || isLoading || !personObj || typeof requestNavigation !== "function") return

        var personId = String(personObj.Id || personObj.PersonId || personObj.ItemId || "")
        if (!personId.length) return

        // Conserve l'épisode, le scroll et le guest focalisé avant de quitter la saison.
        restoreEpisodeId = String(selectedEpisodeId || "")
        restoreIndex = currentIndex | 0
        restoreY = rootFlick ? Number(rootFlick.contentY || 0) : -1

        _saveGuestPersonReturnState()

        var q = _navRoute("PersonPage.qml", { itemId: personId })

        // personSource n'est volontairement pas un paramètre ShellPage.
        // On le transporte dans le contexte mémoire déjà utilisé pour les secrets.
        try {
            if (shared && shared.__redefinNavContext) {
                shared.__redefinNavContext.personSource = "guest"
                shared.__redefinNavContext.personId = personId
            }
        } catch(eCtx) {}

        requestNavigation(q)
    }
    onOverlayModeChanged: {
        deepIdle = false;
        idleFreezeTimer.stop();
        if (!overlayOpen && !isLoading) bumpActivity();
        if (overlayOpen){
            _externalFocusWasLost = false;
            _deferPinAfterNav = false;
            pinAfterNavTimer.stop();
        }
        withEpisodesRow(function(it){ if (it.onLoadingGateChanged) it.onLoadingGateChanged(); });
        if (overlayOpen) later(function(){ if (overlayLoader.item) overlayLoader.item.forceActiveFocus(); });
        if (!overlayOpen && !isLoading){
            if (currentFocus === focusHud) currentFocus = 0;
            requestApplyFocus();
            if (currentFocus === 2) requestGuestScroll();
            requestPinEpisodes("overlayMode:none");
            if (!_logoArmed) logoArmTimer.restart();
            if (!_actionsArmed) actionsArmTimer.restart();
            syncGuestHeight();
        }
    }
    function _restoreFocusAfterOverlay(){
        var f = lastFocusBeforeOverlay;
        if (f === focusHud){ f = 0; }
        if (f === 0){
            currentFocus = 0;
            overviewBox.forceActiveFocus();
            rootFlick.scrollToTop(true);
            return;
        }
        if (f === 1){
            currentFocus = 1;
            withEpisodesRow(function(it){ if (it.forceActiveFocus) it.forceActiveFocus(); });
            rootFlick.scrollToEpisodes(true);
            schedulePinAfterNav();
            return;
        }
        if (f === 2){
            hasGuests ? requestGuestFocusSafe(true) : focusEpisodes();
            return;
        }
        if (f === focusActions){
            if (actionCircles.visible && actionCircles.focusFirstAction()){
                currentFocus = focusActions;
                rootFlick.scrollToTop(true);
            } else focusEpisodes();
            return;
        }
        focusEpisodes();
    }
    function closeOverlay(){
        overlayMode = "none";
        overlayData = ({});
        _restoreFocusAfterOverlay();
        requestApplyFocus();
    }
    function requestPlayAt(itemIdArg, accessTokenArg, userIdArg, serverUrlArg, itemTitleArg, startMs, sourceArg) {
        var explicitStart = Math.max(0, Math.floor(Number(startMs) || 0))
        try {
            if (shared) {
                shared.__redefinExplicitPlaybackStart = ({
                    source: sourceArg && String(sourceArg).length ? String(sourceArg) : "chapter",
                    itemId: String(itemIdArg || ""),
                    serverUrl: String(serverUrlArg || ""),
                    userId: String(userIdArg || ""),
                    startMs: explicitStart,
                    ts: Date.now()
                })
            }
        } catch(e) {}
        _storeSensitiveNavContext()
        requestPlay(itemIdArg, accessTokenArg, userIdArg, serverUrlArg, itemTitleArg)
    }
    signal requestBackToMenu()
    signal requestPlay(string itemId, string accessToken, string userId, string serverUrl, string itemTitle)
    signal requestNavigation(string page)
    Component.onCompleted: {
        _hydrateSensitiveContextFromShared();
        _hydrateGuestPersonReturnState();
        ready = true;
        safeCall(function(){
            if (Components.AppSettings && Components.AppSettings.showClock !== undefined)
                showClock = !!Components.AppSettings.showClock;
        });
        if (preselectEpisodeId && playlist){
            safeCall(function(){
                if (playlist.setCurrentItemId) playlist.setCurrentItemId("");
                else if (playlist.currentItemId !== undefined) playlist.currentItemId = "";
            });
        }
        if (ctxOk) requestFetch("onCompleted");
        else startAwaitCtx("onCompleted");
        bumpActivity();
        later(function(){ requestReflow("onCompleted"); });
    }
    Component.onDestruction: {
        disposed = true
        reqSeq++
        SeasonUtils.cancelSeasonLoadRequests(seasonpage, "destroyed")
        guestPersonReturnTimer.stop()
        visualRevealPollTimer.stop()
        visualRevealSettleTimer.stop()
        visualRevealHardTimer.stop()
    }
    function _ctxChanged(reason){
        SeasonUtils.cancelSeasonLoadRequests(seasonpage, "context_changed")
        if (ready) requestFetch(reason)
    }
    onSharedChanged: {
        var hydratedCtx = _hydrateSensitiveContextFromShared()
        var hydratedGuest = _hydrateGuestPersonReturnState()
        if (hydratedCtx)
            _ctxChanged("sharedContextChanged");
        if (hydratedGuest)
            _scheduleGuestPersonReturnRestore();
    }
    onAccessTokenChanged: _ctxChanged("accessTokenChanged")
    onUserIdChanged: _ctxChanged("userIdChanged")
    onServerUrlChanged: _ctxChanged("serverUrlChanged")
    onSeasonIdChanged: {
        var restoredGuest = _hydrateGuestPersonReturnState()
        _ctxChanged("seasonIdChanged")
        if (restoredGuest) _scheduleGuestPersonReturnRestore()
    }
    onSeriesIdChanged: {
        var restoredGuest = _hydrateGuestPersonReturnState()
        _ctxChanged("seriesIdChanged")
        if (restoredGuest) _scheduleGuestPersonReturnRestore()
    }
    onVisibleChanged: {
        if (visible) {
            var hydrated = _hydrateSensitiveContextFromShared()
            var hydratedGuestReturn = _hydrateGuestPersonReturnState()
            if (hydrated)
                _ctxChanged("visibleContextChanged")
            if (hydratedGuestReturn)
                _scheduleGuestPersonReturnRestore()

            if (!isLoading){
                if (_visualRevealHasShown && !visualRevealPending)
                    _armVisualReveal("visible-return", true);

                later(function(){
                    bumpActivity();
                    if (_hasExplicitEpisodeRestoreTarget()) restoreFocusFromPlaylist("visibleChanged");
                    else requestApplyFocus();
                    requestReflow("visibleChanged");
                });
            }
        } else if (_visualRevealHasShown && !isLoading && !overlayOpen) {
            _externalFocusWasLost = true;
        }
    }
    onActiveFocusChanged: {
        if (!activeFocus) {
            if (_visualRevealHasShown && !isLoading && !overlayOpen
                    && Date.now() >= _visualRevealSuppressReturnUntilMs)
                _externalFocusWasLost = true;
            return;
        }
        if (_externalFocusWasLost && visible && !isLoading && !overlayOpen
                && !visualRevealPending
                && Date.now() >= _visualRevealSuppressReturnUntilMs) {
            _externalFocusWasLost = false;
            _armVisualReveal("focus-return", true);
        }
    }
    onEpisodesChanged: {
        if (episodes === null) return;
        _episodesFetchedOnce = true;
        updatePlaylistFromOwnedEpisodes();
        requestBgUpdate();
        if (!isLoading && !_episodesRowAlive) _episodesRowAlive = true;
        if (_hasExplicitEpisodeRestoreTarget()) {
            _armFocusRestoreGate();
            var wanted = _desiredRestoreIndex();
            if (wanted >= 0) currentIndex = wanted;
        }
        prepareEpisodesSlice();
        maybeEndLoading();
        withEpisodesRow(function(it){ if (it.updatePosterGate) it.updatePosterGate("episodesChanged"); });
        _syncEpisodesRowPreferredId();
        _maybeGuestPrefetchKick();
        later(function(){ requestReflow("episodesChanged"); });
    }
    onSeasonItemChanged: {
        if (seasonItem === null) return;
        _seasonFetchedOnce = true;
        updatePlaylistFromOwnedEpisodes();
        requestBgUpdate();
        maybeEndLoading();
        _maybeGuestPrefetchKick();
        later(function(){ requestReflow("seasonItemChanged"); });
    }
    onGuestStarsChanged: {
        _applyGuestsToGuestpage();
        if (hasGuests) _maybeGuestPrefetchKick();
        else {
            guestPrefetchCheck.stop();
            _guestPrefetch = false;
            _guestWasReady = false;
            _guestH = 0;
            if (currentFocus === 2) focusEpisodes();
        }
        syncGuestHeight();
        if (_guestPersonReturnPending) _scheduleGuestPersonReturnRestore();
        else if (!isLoading && !overlayOpen && currentFocus === 2) requestGuestScroll();
        later(function(){
            requestAnchorRecompute("guestStarsChanged");
            requestHudOpacityUpdate("guestStarsChanged");
        });
    }
    onGuestStarsFullChanged: {
        _applyGuestsToGuestpage()
        if (_guestPersonReturnPending) _scheduleGuestPersonReturnRestore()
    }
    onCurrentFocusChanged: {
        bumpActivity();
        if (currentFocus !== 1 && _deferPinAfterNav){
            _deferPinAfterNav = false;
            pinAfterNavTimer.stop();
        }
        withEpisodesRow(function(it){ if (it.onLoadingGateChanged) it.onLoadingGateChanged(); });
        if (currentFocus !== focusActions){
            try { if (actionCircles && actionCircles.clearHint) actionCircles.clearHint(); } catch(e0) {}
        }
        if (!isLoading && !overlayOpen) requestApplyFocus();
        if (!isLoading && !overlayOpen && currentFocus === 2) requestGuestScroll();
        if (!isLoading && !overlayOpen && currentFocus === focusChapters && hasChapters()) requestChapterFocusSafe(true);
        later(function(){ requestHudOpacityUpdate("currentFocusChanged"); });
        requestPinEpisodes("currentFocusChanged");
    }
    Keys.onPressed: {
        bumpActivity();
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape){
            if (overlayOpen){
                closeOverlay();
                event.accepted = true;
                return;
            }
            requestBackToMenu();
            event.accepted = true;
            return;
        }
        if (loadingGateActive){
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Up){
            if ((currentFocus === 0 || currentFocus === focusActions) && clockHud && clockHud.visible){
                if (focusHudAvatar()) {
                    event.accepted = true;
                    return;
                }
            }
        }
        if (event.key === Qt.Key_Down){
            if (currentFocus === focusHud){
                restoreFocusFromHud();
                event.accepted = true;
            } else if (currentFocus === 0){
                if (actionCircles.visible && actionCircles.focusFirstAction()){
                    currentFocus = focusActions;
                    rootFlick.scrollToTop(true);
                } else focusEpisodes();
                event.accepted = true;
            } else if (currentFocus === 1 && (hasGuests || hasChapters())){
                if (hasGuests) requestGuestFocusSafe(false); else requestChapterFocusSafe(false);
                event.accepted = true;
            } else if (currentFocus === 2 && hasChapters()) { requestChapterFocusSafe(false); event.accepted = true; }
        }
    }
}
