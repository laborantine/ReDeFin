// qml/pages/NextUpBlock.qml — rail « À suivre » pour Freebox Player.
// Le bridge Jellyfin porte le transport réseau ; ce composant conserve uniquement
// la sélection métier, le focus D-Pad, le poster gating et la présentation 16:9.

import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SafeLog.js" as SafeLog

FocusScope {
    id: root
    width: parent ? parent.width : 1280
    focus: false  // le parent décide

    /* ===== API ===== */
    property var    item: null                 // si fourni: item.Id = seriesId
    property string seriesId
    property string userId
    property string accessToken
    property string serverUrl
    property var    fbx

    property int    limit: 200
    property int    nextUpQueryLimit: 50
    property string title: "À suivre"
    property string fallbackPosterUrl: ""
    property int    currentIndex: 0
    property var    requestFocusAbove          // function() OR Item
    property var    requestFocusBelow          // function() OR Item
    property bool   seriesScopedOnly: true

    // Algo
    property int    stopGraceMs: 45000

    signal requestPlayRequested(string itemId, string title)

    /* ===== Profil LIGHT (par défaut) ===== */
    readonly property bool allowHover: false
    readonly property bool allowSmooth: false
    readonly property bool imgCacheEnabled: false
    readonly property int  jpgQlt: 85
    readonly property real oversample: 1.30
    readonly property int  hqJpgQlt: 92
    readonly property real hqOversample: 1.55
    property string hqPosterTargetId: ""
    property string _hqPosterPendingId: ""

    /* ===== Marquee titre — rendu identique detailMoviePage ===== */
    property bool marqueeEnabled: true
    property real titleMarqueeSpeedPxPerSec: 56
    property int  titleMarqueePauseStartMs: 700
    property int  titleMarqueePauseEndMs: 260

    /* ===== Données ===== */
    property var  episodes: []
    property bool loading: false
    property bool ready: false
    readonly property bool isScrolling: !!(list && (list.moving || list.dragging || list.flicking))
    readonly property bool allowAnims: !!(root.visible && !root.isScrolling)
    readonly property bool hasContent: !!(episodes && episodes.length > 0)
    property string currentEpisodeId: ""

    // Ancre de retour PlayerOverlay. L'ID est autoritatif, l'index n'est
    // qu'un fallback car un refetch NextUp peut modifier la rangée.
    property string restoreEpisodeId: ""
    property int restoreEpisodeIndex: -1
    property var restoreEpisodeSnapshot: null

    /* ===== Trace / anti-stale ===== */
    property string _lastKey: ""
    property int    _pending: 0
    property bool   _inFlight: false
    property string _dataKey: ""
    property bool   disposed: false

    // Les requêtes du bridge exposent un contrôleur annulable. On les libère dès
    // leur fin et on coupe proprement celles encore actives à la destruction.
    property var _inflightRequests: []
    function _requestIsActive(handle){
        if (!handle) return false;
        try {
            if (typeof handle.isActive === "function") return handle.isActive() === true;
            if (handle.active !== undefined) return handle.active === true;
        } catch(e) {}
        return true;
    }
    function _trackRequest(handle){
        if (!handle || !_requestIsActive(handle)) return;
        _inflightRequests.push(handle);
    }
    function _untrackRequest(handle){
        if (!handle) return;
        try {
            var out=[];
            for (var i=0; i<_inflightRequests.length; i++){
                var current=_inflightRequests[i];
                if (current && current !== handle) out.push(current);
            }
            _inflightRequests = out;
        } catch(e) {}
    }
    function _cancelInflightRequests(){
        var pending = _inflightRequests;
        _inflightRequests = [];
        try {
            for (var i=0; i<pending.length; i++){
                var handle=pending[i];
                if (handle && typeof handle.cancel === "function")
                    handle.cancel("component_destroyed", false);
            }
        } catch(e) {}
    }

    // Grace
    property string _lastLaunchedId: ""
    property var    _lastLaunchedSnapshot: null
    property double _lastLaunchedAtMs: 0
    property int    _lastLaunchedIndex: -1
    function _resetLaunchGrace(){
        _lastLaunchedId = "";
        _lastLaunchedSnapshot = null;
        _lastLaunchedAtMs = 0;
        _lastLaunchedIndex = -1;
    }

    function _sid() { return seriesId ? seriesId : (item && item.Id ? item.Id : ""); }
    function _key() {
        // Cache mémoire uniquement : ne pas garder serverUrl|userId|seriesId en clair.
        return "nextup#" + SafeLog.shortHash([serverUrl || "", userId || "", _sid()].join("|")) +
               "|" + (seriesScopedOnly ? "scoped" : "all");
    }

    function _withinGrace(){ return _lastLaunchedId && (Date.now() - (_lastLaunchedAtMs||0) <= stopGraceMs); }

    /* ===== FIX: requestFocusAbove/Below acceptent function() OU Item ===== */
    function _focusTarget(t) {
        if (!t) return false;
        if (typeof t === "function") { t(); return true; }
        if (t.forceActiveFocus) { t.forceActiveFocus(); return true; }
        if (t.focus !== undefined) { t.focus = true; return true; }
        return false;
    }
    function _tryFocusAbove(){ return _focusTarget(root.requestFocusAbove); }
    function _tryFocusBelow(){ return _focusTarget(root.requestFocusBelow); }

    /* ===== Invalidation ===== */
    function _invalidate(){
        _pending = 0;
        _inFlight = false;
        loading = false;
        ready = false;
        _dataKey = "";
        episodes = [];
        currentEpisodeId = "";
        try {
            if (list && list.currentIndex !== undefined) list.currentIndex = 0;
        } catch(e) {}
    }

    function _beginFetch(force){
        if (disposed) return null;

        var k=_key();
        if(!force && k===_lastKey){
            if(_inFlight) return null;
            if(ready && hasContent) return null;
        }

        if(k!==_lastKey){
            _invalidate();
            _resetLaunchGrace();
        }

        _lastKey=k;
        _pending++;
        _inFlight=true;
        loading=true;
        ready=false;

        return k;
    }

    function _finishFetch(k){
        if (disposed) return false;

        _pending = Math.max(0, _pending - 1);
        if (_pending === 0) _inFlight = false;
        if (k !== _lastKey) return false;

        loading = false;
        ready = true;
        return true;
    }

    /* ===== Layout / Style ===== */
    property int sideMargin: 28
    property int titleBottomMargin: 12

    property int cardW: 320
    property int cardGap: 10
    property int aspectW: 16
    property int aspectH: 9
    readonly property int thumbW: Math.round(cardW - cardGap)
    readonly property int thumbH: Math.round(thumbW * aspectH / aspectW)

    // Focus identique CastPage / SimilarItems.
    readonly property real focusScale: 1.14
    readonly property int focusLiftPx: 6
    readonly property int edgeNudgePx: Math.max(0, Math.ceil(cardW * (focusScale - 1) * 0.55))
    readonly property int edgePad: Math.max(18, edgeNudgePx + 10)

    // Aligne visuellement le premier épisode avec les autres rails de
    // DetailSeriePage. Le headroom anti-clipping reste présent, mais on retire
    // le petit excès observé sur le premier poster uniquement.
    property int firstPosterLeftShift: 10
    readonly property int firstEdgePad: Math.max(8, edgePad - firstPosterLeftShift)

    function topPadFor(h) {
        return Math.max(18,
            Math.ceil(h * (focusScale - 1))
            + focusLiftPx
            + Math.ceil(frameWidth)
            + 2)
    }

    // titre seul sous la jaquette
    property int titleLineH: 24
    readonly property int cardH: topPadFor(thumbH) + thumbH + titleLineH + 6
    readonly property int viewH: cardH + 2

    /* Cadre inside — aligné SimilarItems */
    property real frameWidth: 2.0
    property real frameInsetPx: 0.0
    property real frameInnerEpsilon: 0.2
    property real aaEps: 0.5
    function frameMargin(){ return frameInsetPx + frameWidth/2 + frameInnerEpsilon; }

    // Même extension de cadre que CastPage. La propriété historique est
    // conservée pour compatibilité avec un éventuel override parent.
    property real focusFrameExtraPx: 2.5
    function focusFrameMargin(){
        return Math.max(0,
            frameMargin() + frameWidth/2 + aaEps - focusFrameExtraPx)
    }

    /* Qualité / decode borné via URL */
    readonly property int reqW: Math.round(thumbW * oversample)
    readonly property int reqH: Math.round(thumbH * oversample)
    readonly property int hqReqW: Math.round(thumbW * hqOversample)
    readonly property int hqReqH: Math.round(thumbH * hqOversample)

    /* ===== Visibilité ===== */
    implicitHeight: hasContent ? (titleText.implicitHeight + titleBottomMargin + viewH) : 0
    visible: hasContent

    /* ===== Helpers ===== */
    property int  _lastIndex: 0

    function percentPlayed(ep){
        var d=(ep&&ep.RunTimeTicks)||0;
        var p=(ep&&ep.UserData&&ep.UserData.PlaybackPositionTicks)||0;
        if(d<=0) return 0;
        return Math.max(0,Math.min(100,Math.round((p/d)*100)));
    }

    function _episodeIndexById(id){
        id = id ? String(id) : "";
        if (!id.length) return -1;
        for (var i=0; i<(episodes||[]).length; i++) {
            if (episodes[i] && String(episodes[i].Id || "") === id) return i;
        }
        return -1;
    }

    function _setCurrentEpisodeIndex(idx){
        var maxIdx = Math.max(0, (episodes ? episodes.length : 0) - 1);
        idx = Math.max(0, Math.min(idx|0, maxIdx));
        currentIndex = idx;
        _lastIndex = idx;
        try { if (list) list.currentIndex = idx; } catch(e0) {}
        var ep = (episodes && idx >= 0 && idx < episodes.length) ? episodes[idx] : null;
        currentEpisodeId = ep && ep.Id ? String(ep.Id) : "";
        return idx;
    }

    function currentEpisodeSnapshot(){
        var idx = Math.max(0, Math.min(currentIndex|0, Math.max(0, (episodes||[]).length-1)));
        var ep = (episodes && idx < episodes.length) ? episodes[idx] : null;
        if (!ep) return null;
        try { return JSON.parse(JSON.stringify(ep)); }
        catch(e) { return ep; }
    }

    function setRestoreAnchor(id, idx, snapshot){
        restoreEpisodeId = id ? String(id) : "";
        restoreEpisodeIndex = (idx === undefined || idx === null) ? -1 : (idx|0);
        restoreEpisodeSnapshot = snapshot || null;
        if (restoreEpisodeIndex >= 0) _lastIndex = restoreEpisodeIndex;
    }

    function forceFirstCardFocus(){
        try{
            _setCurrentEpisodeIndex(0);
            Qt.callLater(function(){
                if(!root || root.disposed || !list) return;
                if(list.currentItem) list.currentItem.forceActiveFocus();
                else list.forceActiveFocus();
            });
        }catch(e){}
    }

    function hasFocusedEpisode(id){
        try {
            var idx = _episodeIndexById(id);
            if (idx < 0) idx = currentIndex|0;
            var ok = !!(root.activeFocus && list && list.activeFocus
                      && list.currentIndex === idx
                      && list.currentItem && list.currentItem.activeFocus);
            return ok;
        } catch(e) {}
        return false;
    }

    function restoreCardFocus(id, fallbackIndex){
        try {
            if (!episodes || !episodes.length || !list || list.count <= 0) return false;
            var idx = _episodeIndexById(id);
            if (idx < 0) idx = (fallbackIndex === undefined || fallbackIndex === null) ? _lastIndex : (fallbackIndex|0);
            idx = _setCurrentEpisodeIndex(idx);

            // Forcer d'abord le ListView permet au FocusScope parent de devenir
            // actif même si le delegate demandé n'est pas encore instancié.
            list.forceActiveFocus();
            try { list.positionViewAtIndex(idx, ListView.Contain); } catch(ePos) {}
            _focusIndexSoon(idx, true);
            Qt.callLater(function(){
                if(!root || root.disposed || !list) return;
                var obj = list.itemAtIndex ? list.itemAtIndex(idx) : list.currentItem;
                if(obj && obj.forceActiveFocus) obj.forceActiveFocus();
                else list.forceActiveFocus();
            });
            return true;
        } catch(e) {}
        return false;
    }

    function restoreLastCardFocus(){
        return restoreCardFocus(currentEpisodeId || restoreEpisodeId, _lastIndex);
    }




    function epTitle(ep){
        if (!ep) return "";
        var s=(ep.ParentIndexNumber!=null)?ep.ParentIndexNumber:"";
        var e=(ep.IndexNumber!=null)?ep.IndexNumber:"";
        var sx=(s!==""?("S"+s):"");
        var ex=(e!==""?("E"+e):"");
        var sep=(sx&&ex)?"·":"";
        return (sx||ex)
            ? (sx+(sep?(" "+sep+" "):"")+ex+" — "+(ep.Name||""))
            : (ep.Name||"");
    }

    function _episodeImageUrl(ep, widthPx, heightPx, quality, fallbackUrl) {
        if (!ep || !serverUrl) return fallbackUrl || ""
        var tags = ep.ImageTags || {}
        var id = ep.Id || ""
        var type = tags.Thumb ? "Thumb" : (tags.Primary ? "Primary" : "")
        var tag = tags.Thumb || tags.Primary || ""
        if (!tag && ep.SeriesId && ep.SeriesPrimaryImageTag) {
            id = ep.SeriesId
            type = "Primary"
            tag = ep.SeriesPrimaryImageTag
        }
        if (!id || !type || !tag) return fallbackUrl || ""
        return Jellyfin.itemImageUrl(serverUrl, id, type, tag, {
            quality: quality,
            fillWidth: widthPx,
            fillHeight: heightPx,
            format: "jpg"
        })
    }

    function epImage(ep) {
        return _episodeImageUrl(ep, reqW, reqH, jpgQlt, fallbackPosterUrl || "")
    }

    function epImageHq(ep) {
        return _episodeImageUrl(ep, hqReqW, hqReqH, hqJpgQlt, "")
    }
    function _scheduleHqPoster(id){
        id = id ? String(id) : ""
        hqPosterTargetId = ""
        _hqPosterPendingId = id
        hqPosterTimer.stop()
        if (id.length && activeFocus && !isScrolling)
            hqPosterTimer.restart()
    }
    Timer {
        id: hqPosterTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (!root.activeFocus || root.isScrolling || !root.episodes || root.currentIndex < 0 || root.currentIndex >= root.episodes.length)
                return
            var ep = root.episodes[root.currentIndex]
            var id = (ep && ep.Id) ? String(ep.Id) : ""
            if (id.length && id === root._hqPosterPendingId)
                root.hqPosterTargetId = id
        }
    }


    function _signEpisodes(arr){
        try{
            return JSON.stringify((arr||[]).map(function(e){
                var p=(e&&e.UserData&&e.UserData.PlaybackPositionTicks)||0;
                return (e.Id||"")+":"+p;
            }));
        }catch(e){ return ""; }
    }

    function _onlyEpisodes(arr){
        return (arr||[]).filter(function(it){
            return it && (!it.Type || it.Type==="Episode");
        });
    }

    function _dedupById(arr){
        var seen={}, out=[];
        (arr||[]).forEach(function(it){
            var id=(it&&it.Id)||"";
            if(id && !seen[id]){
                seen[id]=1;
                out.push(it);
            }
        });
        return out;
    }

    function _strictFilterBySeries(arr,sid){
        return (arr||[]).filter(function(it){
            return it && (it.SeriesId===sid || (it.Series && it.Series.Id===sid));
        });
    }

    /* ===== Meta saisons (barre position saison) ===== */
    property var _seasonCacheBySeries: ({})
    property int _seasonCacheVersion: 0

    function _ensureSeasons(sId){
        if(!sId || disposed) return;

        var c = _seasonCacheBySeries[sId];
        if (c && c.loaded) return;
        if (c && c.inFlight) return;

        _seasonCacheBySeries[sId] = { loaded:false, inFlight:true, byIndex:{} };

        Jellyfin.fetchSeasons(serverUrl, accessToken, userId, sId, function(items){
            if (!root || root.disposed) return;
            var byIdx={};
            items = items || [];
            for(var i=0;i<items.length;i++){
                var it=items[i]||{};
                var idx=(it.IndexNumber!=null)? it.IndexNumber : -1;
                var tot=(it.EpisodeCount!=null)? it.EpisodeCount : ((it.ChildCount!=null)? it.ChildCount : 0);
                if(idx>=0) byIdx[idx]=tot;
            }
            _seasonCacheBySeries[sId] = { loaded:true, inFlight:false, byIndex:byIdx };
            _seasonCacheVersion++;
        }, function(){
            if (!root || root.disposed) return;
            _seasonCacheBySeries[sId] = { loaded:true, inFlight:false, byIndex:{} };
            _seasonCacheVersion++;
        });
    }

    function _seasonTotal(sId, seasonIndex){
        var c=_seasonCacheBySeries[sId];
        if(!c || !c.byIndex) return 0;
        return c.byIndex[seasonIndex]||0;
    }

    function _seasonRatio(ep){
        // IMPORTANT : fonction volontairement pure.
        // Un binding géométrique ne doit jamais déclencher de requête réseau
        // ni modifier _seasonCacheBySeries pendant son propre calcul.
        // _seasonCacheVersion est lu pour réévaluer le ratio quand le cache
        // asynchrone reçoit les compteurs de saisons.
        var _v = _seasonCacheVersion;
        if(!ep) return 0;

        var sid = ep.SeriesId || (ep.Series && ep.Series.Id) || "";
        var sidx = (ep.ParentIndexNumber!=null)? ep.ParentIndexNumber : -1;
        var eidx = (ep.IndexNumber!=null)? ep.IndexNumber : 0;

        var tot = _seasonTotal(sid, sidx);
        if(tot>0 && eidx>0) return Math.max(0, Math.min(1, (eidx-1)/tot));
        return 0;
    }

    /* ===== Ancre de retour / grâce de lancement ===== */
    function _injectEpisodeAtIndex(arr, ep, wantedIndex){
        if (!ep || !ep.Id) return arr || [];
        var out = (arr || []).slice(0);
        var id = String(ep.Id);
        for (var i=0; i<out.length; i++) {
            if (out[i] && String(out[i].Id || "") === id) return out;
        }
        var idx = Math.max(0, Math.min(wantedIndex|0, out.length));
        out.splice(idx, 0, ep);
        return out;
    }

    function _applyReturnAnchor(arr){
        var out = arr || [];
        var anchorId = restoreEpisodeId || (_withinGrace() ? _lastLaunchedId : "");
        var anchorIndex = restoreEpisodeIndex >= 0 ? restoreEpisodeIndex : _lastLaunchedIndex;
        var snapshot = restoreEpisodeSnapshot || (_withinGrace() ? _lastLaunchedSnapshot : null);
        if (!anchorId || !snapshot || !snapshot.Id) return out;
        if (String(snapshot.Id) !== String(anchorId)) return out;
        return _injectEpisodeAtIndex(out, snapshot, Math.max(0, anchorIndex));
    }

    /* ===== Fetch ===== */
    function _normalizeFetchedEpisodes(items, sid) {
        var arr = _onlyEpisodes(items || []);
        if (sid) arr = _strictFilterBySeries(arr, sid);
        // Laisser Jellyfin décider si un spécial appartient au NextUp :
        // Android TV ne retire pas localement les saisons 0 de cette rangée.
        return _dedupById(arr);
    }

    function _publishEpisodes(k, items, sid) {
        var arr = _normalizeFetchedEpisodes(items, sid || "");
        arr = _applyReturnAnchor(arr);
        if (!_finishFetch(k)) return;

        var sliced = arr.slice(0, Math.max(1, limit));
        var anchorId = restoreEpisodeId || (_withinGrace() ? _lastLaunchedId : currentEpisodeId);
        var anchorIndex = -1;
        if (anchorId) {
            for (var i=0; i<sliced.length; i++) {
                if (sliced[i] && String(sliced[i].Id || "") === String(anchorId)) { anchorIndex = i; break; }
            }
        }

        var sig = _signEpisodes(sliced);
        if (sig !== _dataKey) {
            _dataKey = sig;
            episodes = sliced;
        }

        if (episodes && episodes.length) {
            if (anchorIndex < 0) anchorIndex = Math.min(Math.max(0, currentIndex|0), episodes.length-1);
            _setCurrentEpisodeIndex(anchorIndex);
        } else {
            currentIndex = 0;
            _lastIndex = 0;
            currentEpisodeId = "";
        }
    }

    function _runTrackedRequest(startRequest) {
        var host = root;
        var handle = null;
        function release() {
            if (handle) host._untrackRequest(handle);
        }
        handle = startRequest(release);
        _trackRequest(handle);
        return handle;
    }

    function fetchNextUpIfReady(force){
        if (disposed) return;

        if(!serverUrl || !accessToken || !userId){
            _invalidate();
            ready=true;
            return;
        }

        var sid=_sid();
        if(sid) _nextUpForSeries(sid, !!force);
        else if(!seriesScopedOnly) _nextUpGlobal(!!force);
        else { _invalidate(); ready=true; }
    }

    function refetch(){ fetchNextUpIfReady(true); }

    function _nextUpGlobal(force){
        var host = root;
        var k=_beginFetch(!!force); if(!k) return;

        _runTrackedRequest(function(release) {
            return Jellyfin.fetchHomeNextUpItems(serverUrl, accessToken, userId, Math.max(1, limit),
                function(items){
                    release();
                    if (!host || host.disposed) return;
                    _publishEpisodes(k, items || [], "");
                },
                function(){
                    release();
                    if (!host || host.disposed) return;
                    if(!_finishFetch(k)) return;
                    _invalidate(); ready=true;
                }
            );
        });
    }

    function _nextUpForSeries(sid, force){
        var host = root;
        var k=_beginFetch(!!force); if(!k) return;

        _runTrackedRequest(function(release) {
            return Jellyfin.fetchHomeNextUpItems(serverUrl, accessToken, userId, Math.max(1, nextUpQueryLimit),
                function(items){
                    release();
                    if (!host || host.disposed) return;

                    var arr = _normalizeFetchedEpisodes(items || [], sid);
                    var first = arr.length ? arr[0] : null;

                    // Jellyfin Android TV, FullDetails : si NextUp renvoie
                    // exactement un épisode pour la série, compléter la rangée
                    // avec les épisodes suivants de CETTE saison à partir de
                    // l'index de l'épisode NextUp.
                    if (arr.length === 1 && first && first.SeasonId && first.IndexNumber !== undefined && first.IndexNumber !== null
                            && Jellyfin.fetchSeasonItemsFromIndex) {
                        _runTrackedRequest(function(releaseSeason) {
                            return Jellyfin.fetchSeasonItemsFromIndex(serverUrl, accessToken, userId, first.SeasonId,
                                Math.max(0, first.IndexNumber|0), Math.max(1, limit - 1),
                                function(extraItems){
                                    releaseSeason();
                                    if (!host || host.disposed) return;
                                    _publishEpisodes(k, [first].concat(extraItems || []), sid);
                                },
                                function(){
                                    releaseSeason();
                                    if (!host || host.disposed) return;
                                    _publishEpisodes(k, arr, sid);
                                }
                            );
                        });
                        return;
                    }

                    // Réponse vide = rangée vide. Pas de reconstruction locale
                    // à partir de tous les épisodes, conformément à Android TV.
                    _publishEpisodes(k, arr, sid);
                },
                function(){
                    release();
                    if (!host || host.disposed) return;
                    _publishEpisodes(k, [], sid);
                },
                sid
            );
        });
    }

    /* ===== Réactivité ===== */
    Timer {
        id: _debounce
        interval: 80
        repeat: false
        onTriggered: {
            // Lot 1 Freebox: évite un fetch retardé si le bloc a été masqué/détruit entre-temps.
            if (!root.visible || root.disposed) return;
            fetchNextUpIfReady();
        }
    }
    Component.onCompleted: _debounce.restart()
    Component.onDestruction: { disposed = true; _cancelInflightRequests(); }

    onServerUrlChanged:   { _invalidate(); _debounce.restart(); }
    onAccessTokenChanged: { _invalidate(); _debounce.restart(); }
    onUserIdChanged:      { _invalidate(); _debounce.restart(); }
    onSeriesIdChanged:    { _lastIndex=0; _resetLaunchGrace(); _invalidate(); _debounce.restart(); }
    onItemChanged:        { _lastIndex=0; _resetLaunchGrace(); _invalidate(); _debounce.restart(); }

    onCurrentIndexChanged: {
        try {
            if (!list || list._syncing) return;
            list._syncing = true;
            list.currentIndex = Math.max(0, Math.min(root.currentIndex|0, Math.max(0, list.count-1)));
            list._syncing = false;
        } catch(e) {
            try { if (list) list._syncing = false; } catch(e2) {}
        }
        var ep = (episodes && currentIndex >= 0 && currentIndex < episodes.length) ? episodes[currentIndex] : null
        currentEpisodeId = ep && ep.Id ? String(ep.Id) : ""
        _scheduleHqPoster(ep && ep.Id ? ep.Id : "")
    }

    onActiveFocusChanged: {
        if (activeFocus) {
            var ep = (episodes && currentIndex >= 0 && currentIndex < episodes.length) ? episodes[currentIndex] : null
            _scheduleHqPoster(ep && ep.Id ? ep.Id : "")
        } else {
            _scheduleHqPoster("")
        }
    }

    onEpisodesChanged: {
        try {
            if (!episodes || episodes.length === 0) {
                currentIndex = 0;
                _lastIndex = 0;
                currentEpisodeId = "";
                list.currentIndex = 0;
            } else {
                var idx = Math.max(0, Math.min(currentIndex|0, episodes.length - 1));
                list.currentIndex = idx;
                currentIndex = idx;
                var ep = episodes[idx];
                currentEpisodeId = ep && ep.Id ? String(ep.Id) : "";
            }
        } catch(e) {}
    }

    /* ===== Titre ===== */
    Text { textFormat: Text.PlainText;
        id: titleText
        text: root.title
        color: "#ffe"
        font.pixelSize: 19
        font.bold: true
        anchors.left: parent.left
        anchors.leftMargin: root.sideMargin
        visible: root.hasContent
    }

    /* ===== Focus retry (delegate instancié hors écran) ===== */
    Timer {
        id: focusRetry
        repeat: false
        interval: 0
        property int targetIndex: -1
        property int tries: 0
        // Les déplacements D-Pad voisins doivent laisser le ListView faire son
        // glissement natif, exactement comme CastPage. Le repositionnement forcé
        // est réservé aux restaurations lointaines (retour PlayerOverlay).
        property bool forcePosition: false
        onTriggered: {
            if (!root.visible || root.disposed || !root.hasContent || !list) return;
            if (targetIndex < 0 || targetIndex >= list.count) return;
            try {
                list.currentIndex = targetIndex;
                root.currentIndex = targetIndex;
                if (forcePosition && tries === 0) {
                    list.forceActiveFocus();
                    list.positionViewAtIndex(targetIndex, ListView.Contain);
                }
            } catch(e0) {}
            var obj = list.itemAtIndex ? list.itemAtIndex(targetIndex) : list.currentItem;
            if (obj && obj.forceActiveFocus) { obj.forceActiveFocus(); return; }
            tries += 1;
            if (tries < 10) { interval = 30; restart(); }
        }
    }
    function _focusIndexSoon(idx, forcePosition){
        if (!root.visible || root.disposed) return;
        focusRetry.stop();
        focusRetry.targetIndex = idx;
        focusRetry.tries = 0;
        focusRetry.forcePosition = (forcePosition === true);
        focusRetry.interval = 0;
        focusRetry.restart();
    }

    function _rememberLaunchedEpisode(ep, idx){
        if (!ep) return;
        _lastLaunchedId = ep.Id ? String(ep.Id) : "";
        _lastLaunchedAtMs = Date.now();
        _lastLaunchedIndex = Math.max(0, idx|0);
        _lastIndex = _lastLaunchedIndex;
        currentIndex = _lastLaunchedIndex;
        currentEpisodeId = _lastLaunchedId;
        try { _lastLaunchedSnapshot = JSON.parse(JSON.stringify(ep)); }
        catch(e){ _lastLaunchedSnapshot = ep; }
    }

    /* ===== Liste ===== */
    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: titleText.bottom
        anchors.topMargin: root.titleBottomMargin
        anchors.leftMargin: root.sideMargin
        anchors.rightMargin: root.sideMargin
        height: root.viewH

        orientation: ListView.Horizontal
        model: root.episodes
        spacing: root.cardGap
        clip: true

        snapMode: ListView.NoSnap
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationWraps: false
        reuseItems: true
        interactive: contentWidth > width + 2
        flickDeceleration: 5000
        maximumFlickVelocity: 3200

        // Marge début/fin anti-overscan + anti-clipping du zoom.
        header: Item { width: root.firstEdgePad; height: 1 }
        footer: Item { width: root.edgePad; height: 1 }

        focus: root.activeFocus

        property bool _syncing: false
        Component.onCompleted: {
            _syncing = true;
            currentIndex = Math.max(0, Math.min(root.currentIndex, Math.max(0, count-1)));
            _syncing = false;
        }
        onCurrentIndexChanged: {
            if (_syncing) return;
            root.currentIndex = currentIndex;
            root._lastIndex = currentIndex;
        }

        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: root.firstEdgePad
        preferredHighlightEnd: Math.max(root.firstEdgePad, width - root.cardW - root.edgePad)
        highlightMoveDuration: 170
        highlightMoveVelocity: -1
        highlight: Item { width: root.cardW; height: list.height; visible: false }

        readonly property int cellW: (root.cardW + list.spacing)
        readonly property int padPx: cellW * 1
        cacheBuffer: Math.round(Math.max(cellW * 1.0, width / 4) + padPx)
        displayMarginBeginning: Math.round(Math.max(cellW * 1.0, width / 4) + padPx)
        displayMarginEnd: Math.round(Math.max(cellW * 1.25, width / 4) + padPx)
        readonly property int approxVisibleCards: Math.max(1, Math.ceil(width / cellW))
        readonly property int loadRadiusCards: Math.max(1, approxVisibleCards)

        Keys.onPressed: {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                event.accepted = root._tryFocusAbove();
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                event.accepted = root._tryFocusBelow();
            } else {
                event.accepted = false;
            }
        }

        delegate: FocusScope {
            id: card
            width:  root.cardW
            height: root.cardH
            z: activeFocus ? 1000 : 0

            readonly property bool isFocused: list.activeFocus && (list.currentIndex === index)
            readonly property bool isHot: isFocused
            property string itemId: (modelData && modelData.Id) ? ("" + modelData.Id) : ""
            property bool _loadArmed: false
            property bool showFallback: true
            property int _imgToken: 0
            readonly property real seasonProgressRatio: root._seasonRatio(modelData)

            readonly property bool wantLoad: isFocused || (Math.abs(index - list.currentIndex) <= list.loadRadiusCards)

            function _ensureSeasonMeta(){
                try {
                    var sid = modelData && (modelData.SeriesId || (modelData.Series && modelData.Series.Id))
                    if (sid) root._ensureSeasons(sid)
                } catch(e) {}
            }

            onWantLoadChanged: {
                if (wantLoad && !_loadArmed) _loadArmed = true;
            }

            onItemIdChanged: {
                _imgToken += 1;

                _loadArmed = false;
                showFallback = true;

                try { thumbBox._applyScaleImmediate() } catch(e0) {}

                // ListView.reuseItems peut recycler ce delegate pendant un
                // scroll rapide. Si wantLoad était déjà vrai avant le recyclage,
                // onWantLoadChanged ne se déclenche pas à nouveau et l'image
                // restait alors bloquée en fallback. Réarmer explicitement la
                // source pour le nouvel épisode corrige ce cas sans conserver
                // toutes les textures de la saison en mémoire.
                if (wantLoad) _loadArmed = true;
                _ensureSeasonMeta()
            }

            Component.onCompleted: {
                if (wantLoad) _loadArmed = true;
                showFallback = true;
                _ensureSeasonMeta()
            }

            Keys.onPressed: {
                if (!modelData) { event.accepted = true; return; }

                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                    root._rememberLaunchedEpisode(modelData, index);
                    root.requestPlayRequested(modelData.Id, modelData.Name || "");

                    event.accepted = true;

                } else if (event.key === Qt.Key_Left) {
                    if (list.currentIndex > 0) {
                        list.currentIndex = Math.max(0, list.currentIndex - 1);
                        _focusIndexSoon(list.currentIndex, false);
                    }
                    // Le bord gauche est terminal horizontalement, comme le
                    // bord droit. Remonter reste réservé à ↑.
                    event.accepted = true;

                } else if (event.key === Qt.Key_Right) {
                    if (list.currentIndex < list.count - 1) {
                        list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1);
                        _focusIndexSoon(list.currentIndex, false);
                    }
                    // Le bord droit du rail est terminal horizontalement.
                    // Descendre vers la section suivante reste réservé à ↓.
                    event.accepted = true;

                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                    event.accepted = root._tryFocusAbove();

                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                    event.accepted = root._tryFocusBelow();

                } else {
                    event.accepted = false;
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: root.allowHover
                onEntered: {
                    list.currentIndex = index;
                    card.forceActiveFocus();
                    _focusIndexSoon(index, false);
                }
                onClicked: {
                    if (!modelData) return;

                    root._rememberLaunchedEpisode(modelData, index);

                    list.currentIndex = index;
                    card.forceActiveFocus();
                    _focusIndexSoon(index, false);

                    root.requestPlayRequested(modelData.Id, modelData.Name || "");
                }
            }

            onActiveFocusChanged: {
                if (activeFocus) {
                    root._lastIndex = index
                    list.currentIndex = index
                    if (modelData && modelData.Id)
                        root._scheduleHqPoster(modelData.Id)
                } else {
                    if (modelData && modelData.Id
                            && (root._hqPosterPendingId === String(modelData.Id)
                                || root.hqPosterTargetId === String(modelData.Id)))
                        root._scheduleHqPoster("")
                }
            }


            Column {
                anchors.fill: parent
                spacing: 6

                // Headroom identique CastPage : le zoom + lift ne touche pas le
                // bord supérieur du viewport.
                Item { width: 1; height: root.topPadFor(root.thumbH) }

                Item {
                    id: thumbBox
                    width: parent.width
                    height: root.thumbH
                    clip: true
                    transformOrigin: Item.Bottom
                    scale: 1.0

                    readonly property bool selected: card.activeFocus
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast: root.episodes && index === root.episodes.length - 1
                    readonly property bool allowLocalAnims: root.allowAnims && list.activeFocus

                    transform: Translate {
                        x: (thumbBox.selected && list.activeFocus)
                           ? (thumbBox.isFirst
                              ? root.edgeNudgePx
                              : (thumbBox.isLast ? -root.edgeNudgePx : 0))
                           : 0
                        y: (thumbBox.selected && list.activeFocus)
                           ? -root.focusLiftPx : 0

                        Behavior on x {
                            enabled: thumbBox.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                        Behavior on y {
                            enabled: thumbBox.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                    }

                    function _applyScaleImmediate(){
                        thumbScaleIn.stop()
                        thumbScaleOut.stop()
                        scale = (selected && list.activeFocus)
                                ? (root.focusScale - 0.02) : 1.0
                    }

                    SequentialAnimation {
                        id: thumbScaleIn
                        running: false
                        PropertyAnimation {
                            target: thumbBox
                            property: "scale"
                            to: root.focusScale
                            duration: 120
                            easing.type: Easing.OutCubic
                        }
                        PropertyAnimation {
                            target: thumbBox
                            property: "scale"
                            to: (root.focusScale - 0.02)
                            duration: 90
                            easing.type: Easing.OutCubic
                        }
                    }
                    NumberAnimation {
                        id: thumbScaleOut
                        target: thumbBox
                        property: "scale"
                        to: 1.0
                        duration: 130
                        easing.type: Easing.OutCubic
                        running: false
                    }

                    onSelectedChanged: {
                        if (!allowLocalAnims) {
                            _applyScaleImmediate()
                            return
                        }
                        if (selected && list.activeFocus) {
                            thumbScaleOut.stop()
                            thumbScaleIn.start()
                        } else {
                            thumbScaleIn.stop()
                            thumbScaleOut.start()
                        }
                    }
                    onVisibleChanged: if (visible) _applyScaleImmediate()

                    Connections {
                        target: list
                        function onActiveFocusChanged(){ thumbBox._applyScaleImmediate() }
                    }
                    Connections {
                        target: root
                        function onIsScrollingChanged(){
                            if (root.isScrolling) thumbBox._applyScaleImmediate()
                        }
                    }

                    // Micro backplate CastPage, uniquement au focus et hors scroll.
                    Rectangle {
                        anchors.fill: parent
                        color: "#FFFFFF"
                        opacity: (thumbBox.selected && root.allowAnims) ? 0.05 : 0.0
                        visible: opacity > 0
                        Behavior on opacity {
                            enabled: thumbBox.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                    }

                    // Micro profondeur interne bas, cheap et coupée pendant scroll.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.round(parent.height * 0.22)
                        opacity: (thumbBox.selected && root.allowAnims) ? 1.0 : 0.0
                        visible: opacity > 0
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 1.0; color: "#22000000" }
                        }
                        Behavior on opacity {
                            enabled: thumbBox.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                    }

                    // Image/fallback rendus directement : plus de ShaderEffectSource/OpacityMask sur le thumb.
                    // Le clipping simple de thumbBox suffit ; le cadre overlay conserve le rendu propre sans texture offscreen.
                    Item {
                        id: paintLayer
                        anchors.fill: parent
                        y: card.isHot ? -3 : 0
                        Behavior on y {
                            enabled: thumbBox.allowLocalAnims
                            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                        }

                        Item {
                            id: imgLayer
                            anchors.fill: parent
                            visible: !card.showFallback

                            Image {
                                id: epImg
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop

                                source: card._loadArmed ? root.epImage(modelData) : ""

                                asynchronous: true
                                cache: root.imgCacheEnabled
                                mipmap: false
                                smooth: !root.isScrolling

                                property int token: card._imgToken

                                onSourceChanged: {
                                    if (token !== card._imgToken) return;
                                    card.showFallback = true;
                                }
                                onStatusChanged: {
                                    if (token !== card._imgToken) return;
                                    card.showFallback = (source === "" || status !== Image.Ready);
                                    if (status === Image.Ready && card.activeFocus && modelData && modelData.Id)
                                        root._scheduleHqPoster(modelData.Id)
                                }
                            }
                            Image {
                                id: epImgHq
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                source: (card.activeFocus && !root.isScrolling && epImg.status === Image.Ready && modelData && modelData.Id
                                         && root.hqPosterTargetId === String(modelData.Id))
                                        ? root.epImageHq(modelData) : ""
                                asynchronous: true
                                cache: false
                                mipmap: false
                                smooth: !root.isScrolling
                                visible: source !== "" && status === Image.Ready
                                opacity: visible ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                            }
                        }

                        Item {
                            id: fbLayer
                            anchors.fill: parent
                            visible: card.showFallback

                            Item {
                                id: fbContent
                                anchors.fill: parent

                                Text { textFormat: Text.PlainText;
                                    anchors.centerIn: parent
                                    text: (modelData && modelData.Name) ? modelData.Name.charAt(0) : "?"
                                    color: "#b9c3ff"
                                    font.pixelSize: 28
                                    font.bold: true
                                }
                            }
                        }
                    }


                    Item {
                        id: bars
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: root.frameMargin() + root.aaEps
                        height: seasonTrack.height + 2 + playbackTrack.height
                        z: 1.5

                        Rectangle {
                            id: seasonTrack
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: playbackTrack.top
                            height: 3
                            color: "#0f1430"
                            opacity: 0.85
                        }
                        Rectangle {
                            id: seasonMarker
                            width: 2
                            height: seasonTrack.height

                            // Pas de binding direct sur x. Le marqueur est ancré
                            // au track, et la marge dépend d'un ratio pur déjà
                            // calculé par le delegate.
                            anchors.left: seasonTrack.left
                            anchors.leftMargin: Math.round(
                                Math.max(0, seasonTrack.width - width)
                                * card.seasonProgressRatio
                            )
                            anchors.verticalCenter: seasonTrack.verticalCenter

                            color: "#cfd6ff"
                            visible: card.seasonProgressRatio > 0
                        }

                        Rectangle {
                            id: playbackTrack
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 6
                            color: "#0e1228"
                            opacity: 0.95
                        }
                        Rectangle {
                            id: playbackFill
                            anchors.left: playbackTrack.left
                            anchors.bottom: playbackTrack.bottom
                            height: playbackTrack.height
                            width: Math.round(playbackTrack.width * (root.percentPlayed(modelData)/100))
                            color: "#6e7bf4"
                            visible: modelData && modelData.UserData && (modelData.UserData.PlaybackPositionTicks>0)
                        }
                    }

                    // Cadre inside driver-friendly, même comportement CastPage :
                    // épaisseur constante et animation uniquement par opacity.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: root.focusFrameMargin()
                        radius: 0
                        color: "transparent"
                        border.color: "#FFFFFF"
                        border.width: root.frameWidth
                        opacity: card.isFocused ? 1.0 : 0.0
                        antialiasing: false
                        Behavior on opacity {
                            enabled: thumbBox.allowLocalAnims
                            NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                        }
                        z: 2
                    }
                }

                // ===== Titre épisode : Marquee live + layer mask =====
                // Important Freebox/ListView:
                // - le Text reste VISIBLE et vivant ; on anime directement epTxt.x.
                // - le fondu est appliqué sur le layer de titleLineSource.
                // - pas de source masquée/offscreen, pas de ShaderEffectSource, pas de texture figée.
                Item {
                    id: titleLineBox
                    width: parent.width
                    height: root.titleLineH
                    clip: false

                    readonly property bool allowMarquee: root.marqueeEnabled
                                                         && root.visible
                                                         && list.visible
                                                         && card.visible
                                                         && root.activeFocus
                                                         && root.hasContent
                                                         && !root.loading
                                                         && !root.disposed
                                                         && card.isFocused
                                                         && !root.isScrolling
                    readonly property bool marqueeNeeded: epTxt.paintedWidth > titleLineBox.width + 1
                    readonly property real marqueeOverflow: Math.max(0, epTxt.paintedWidth - titleLineBox.width)
                    readonly property int  marqueeGap: 44
                    readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, epTxt.paintedWidth + marqueeGap) : 0
                    readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                    readonly property int  marqueeScrollMs: marqueeTravel > 0
                                                            ? Math.max(3200, Math.min(14000, Math.round((marqueeTravel / Math.max(1, root.titleMarqueeSpeedPxPerSec)) * 1000)))
                                                            : 0
                    readonly property int  marqueeFadeW: Math.min(42, Math.max(22, Math.round(width * 0.12)))

                    // Eligible = le marquee peut tourner. Moving = le texte bouge vraiment.
                    // Le masque réel reste premium, mais il dort pendant les pauses et au repos.
                    property bool marqueeMoving: false
                    readonly property bool marqueeEligible: marqueeNeeded && allowMarquee
                    readonly property bool maskActive: marqueeEligible && marqueeMoving && !root.loading && !root.isScrolling
                    readonly property bool leftFadeActive: maskActive && (epTxt.x < -2)
                    readonly property bool rightFadeActive: maskActive && (epTxt.x > -marqueeOverflow + 2)

                    onAllowMarqueeChanged: updateMarquee()
                    onWidthChanged: updateMarquee()
                    onVisibleChanged: updateMarquee()
                    onMarqueeNeededChanged: updateMarquee()

                    Connections {
                        target: card
                        function onIsFocusedChanged() { titleLineBox.updateMarquee() }
                    }
                    Connections {
                        target: list
                        function onMovingChanged() { titleLineBox.updateMarquee() }
                        function onDraggingChanged() { titleLineBox.updateMarquee() }
                        function onCurrentIndexChanged() { titleLineBox.updateMarquee() }
                    }

                    Item {
                        id: titleLineSource
                        anchors.fill: parent
                        clip: true
                        visible: true

                        // Le masque est sur le layer du vrai item animé.
                        // C'est la partie clé : epTxt reste rendu par Qt, donc x bouge vraiment.
                        layer.enabled: titleLineBox.maskActive
                        layer.smooth: false
                        layer.mipmap: false
                        layer.effect: OpacityMask {
                            maskSource: titleFadeMask
                            cached: false
                        }

                        Text { textFormat: Text.PlainText;
                            id: epTxt
                            x: 0
                            y: Math.round((titleLineSource.height - height) / 2)
                            text: root.epTitle(modelData)
                            color: "#ffffff"
                            font.pixelSize: 16
                            font.bold: card.isFocused
                            wrapMode: Text.NoWrap
                            elide: titleLineBox.allowMarquee ? Text.ElideNone : Text.ElideRight
                            onTextChanged: titleLineBox.updateMarquee()
                            onPaintedWidthChanged: titleLineBox.updateMarquee()
                        }
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

                    Timer {
                        id: titleMarqueeTick
                        interval: 50
                        repeat: true
                        running: false
                        property real posX: 0
                        property int phase: 0       // 0 pause départ, 1 scroll, 2 pause fin
                        property int waitMs: 0

                        onTriggered: {
                            // Lot 1 Freebox: stoppe le tick si le delegate n'est plus courant/visible.
                            if (!root.visible || root.disposed || !list.visible || !card.visible || !card.isFocused || root.isScrolling || !titleLineBox.marqueeEligible || titleLineBox.marqueeScrollMs <= 0) {
                                titleLineBox.resetMarquee()
                                return
                            }

                            if (phase === 0) {
                                waitMs -= interval
                                if (waitMs <= 0) {
                                    phase = 1
                                    titleLineBox.marqueeMoving = true
                                }
                                return
                            }

                            if (phase === 1) {
                                posX -= (root.titleMarqueeSpeedPxPerSec * interval / 1000.0)
                                titleLineBox.marqueeMoving = true
                                if (posX <= titleLineBox.marqueeExitX) {
                                    posX = titleLineBox.marqueeExitX
                                    epTxt.x = Math.round(posX)
                                    phase = 2
                                    titleLineBox.marqueeMoving = false
                                    waitMs = root.titleMarqueePauseEndMs
                                    return
                                }
                                epTxt.x = Math.round(posX)
                                return
                            }

                            waitMs -= interval
                            if (waitMs <= 0) {
                                posX = 0
                                epTxt.x = 0
                                titleLineBox.marqueeMoving = false
                                phase = 0
                                waitMs = root.titleMarqueePauseStartMs
                            }
                        }
                    }

                    function resetMarquee() {
                        titleMarqueeTick.stop()
                        titleMarqueeTick.posX = 0
                        titleMarqueeTick.phase = 0
                        titleMarqueeTick.waitMs = root.titleMarqueePauseStartMs
                        titleLineBox.marqueeMoving = false
                        epTxt.x = 0
                        epTxt.opacity = 1.0
                    }

                    function updateMarquee() {
                        resetMarquee()
                        if (titleLineBox.marqueeEligible && titleLineBox.marqueeScrollMs > 0) {
                            Qt.callLater(function(){
                                if (!root.visible || root.disposed || !list.visible || !card.visible || !card.isFocused || root.isScrolling) {
                                    titleLineBox.resetMarquee()
                                    return
                                }
                                if (titleLineBox.marqueeEligible && titleLineBox.marqueeNeeded && titleLineBox.marqueeScrollMs > 0) {
                                    titleMarqueeTick.posX = 0
                                    titleMarqueeTick.phase = 0
                                    titleMarqueeTick.waitMs = root.titleMarqueePauseStartMs
                                    titleLineBox.marqueeMoving = false
                                    titleMarqueeTick.restart()
                                }
                            })
                        }
                    }
                }

            }
        }
    }

    /* ===== Nav externe (bubble si pas câblé) ===== */
    Keys.onPressed: {
        if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
            event.accepted = root._tryFocusAbove();
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
            event.accepted = root._tryFocusBelow();
        } else {
            event.accepted = false;
        }
    }
}
