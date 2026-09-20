// qml/pages/SeasonsBlock.qml — QtQuick 2.15 (sans Controls)
//
// 2:3, zoom overshoot + lift (CastPage/SimilarItems feel),
// texte simple (plus d’encadré),
// + ligne “N épisode(s)” sous “Saison X”,
// fallbackPosterUrl, bulle “non vus”
//
// ✅ Profil UNIQUE (mode light only)
// ✅ TWEAK Freebox GPU : posters en clip simple, sans ShaderEffectSource/OpacityMask
// ✅ PIC: quality ↓ / oversample ↓ / stagger / buffers ↓ / pas de mask poster
// ✅ Focus memo + bubble Up/Down si callbacks absents
// ✅ FIX: épisode(s) => récupéré via API /Items (TotalRecordCount) si non présent dans le modèle
// ✅ FIX: fallback autonome du contexte (serverUrl / accessToken / userId) en remontant l’arbre QML
// ✅ FIX UI: premier poster légèrement décalé à gauche pour mieux s’aligner avec CastPage
//
// IMPORTANT: si le parent injecte accessToken + userId + serverUrl, ils sont utilisés.
//            Sinon le bloc tente de les retrouver automatiquement dans son contexte parent.

import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin

FocusScope {
    id: root
    width: parent ? parent.width : 1280
    focus: true

    /* ===== Profil unique : LIGHT ===== */
    readonly property bool allowHover: false
    readonly property bool allowSmooth: true

    readonly property int  jpgQlt: 85
    readonly property real posterOversample: 1.30
    readonly property int  hqPosterQuality: 92
    readonly property real hqPosterOversample: 1.55
    readonly property bool imgCacheEnabled: false
    property string hqPosterTargetId: ""
    property string _hqPosterPendingId: ""

    /* ===== API exposée ===== */
    property var    seasons: []
    property string serverUrl
    property string fallbackPosterUrl: ""

    // injectables si dispo
    property string accessToken
    property string userId

    property int    currentIndex: 0
    property var    requestFocusAbove
    property var    requestFocusBelow
    signal openSeasonRequested(var seasonObj)

    property alias grid: grid

    /* ===== Focus memory interne ===== */
    property int  lastFocusedIndex: 0
    property bool _indexFromGrid: false

    /* ===== Compromis chargement (light) ===== */
    property int preloadPadCards: 1

    /* ===== Layout / Style ===== */
    property int sideMargin: 28
    property int titleBottomMargin: 10

    property int cardW: 180
    property int cardInnerGap: 6
    property int cardSpacing: 10

    property int posterAspectW: 2
    property int posterAspectH: 3
    readonly property int posterW: Math.round(cardW - cardInnerGap)
    readonly property int posterH: Math.round(posterW * posterAspectH / posterAspectW)

    readonly property real focusScale: 1.14
    readonly property int  focusLiftPx: 6
    readonly property int  edgeNudgePx: Math.max(0, Math.ceil(posterW * (focusScale - 1) * 0.55))
    readonly property int  edgePad: Math.max(18, edgeNudgePx + 10)

    // ✅ décale légèrement le 1er poster vers la gauche
    property int firstPosterLeftShift: 10

    function topPadFor(h) {
        return Math.ceil(h * (focusScale - 1)) + focusLiftPx + Math.ceil(frameWidth) + 2
    }

    property int labelH: 22
    property int epsH: 18
    property int vSpacing: 5

    readonly property int cardH: topPadFor(posterH) + posterH + vSpacing + labelH + epsH + vSpacing
    readonly property int gridHeight: cardH + 2

    /* ===== Cadre inside (coins carrés) ===== */
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    readonly property real aaEps: -2.0
    property real frameBorderOutset: 0.8
    function frameMargin() { return frameInsetPx + frameWidth/2 + frameInnerEpsilon }

    readonly property int reqPosterW: Math.round(posterW * posterOversample)
    readonly property int reqPosterH: Math.round(posterH * posterOversample)
    readonly property int hqReqPosterW: Math.round(posterW * hqPosterOversample)
    readonly property int hqReqPosterH: Math.round(posterH * hqPosterOversample)

    function forceFirstFocus() { grid.restoreOrFirstFocus() }
    function forceLastFocus()  { grid.forceLastFocus() }
    function restoreLastFocus(){ grid.restoreOrFirstFocus() }
    function forceAbsoluteFirstFocus(){ grid.forceAbsoluteFirstFocus() }

    function _tryFocusAbove() {
        if (typeof root.requestFocusAbove === "function") {
            root.requestFocusAbove()
            return true
        }
        return false
    }

    function _tryFocusBelow() {
        if (typeof root.requestFocusBelow === "function") {
            root.requestFocusBelow()
            return true
        }
        return false
    }

    function labelFor(it) {
        if (!it) return ""
        if (it.IndexNumber === 0) return "Spéciaux"
        if (it.IndexNumber > 0)   return "Saison " + it.IndexNumber
        return it.Name || "Saison"
    }

    /* ===== Contexte parent fallback ===== */
    function _lookupCtxProp(name) {
        var p = root
        var hops = 0
        while (p && hops < 20) {
            try {
                var v = p[name]
                if (v !== undefined && v !== null && ("" + v).length > 0)
                    return "" + v
            } catch(e) {}
            p = p.parent
            hops++
        }
        return ""
    }

    function _resolvedServerUrl() {
        return (serverUrl && serverUrl.length) ? serverUrl : _lookupCtxProp("serverUrl")
    }

    function _resolvedAccessToken() {
        return (accessToken && accessToken.length) ? accessToken : _lookupCtxProp("accessToken")
    }

    function _resolvedUserId() {
        return (userId && userId.length) ? userId : _lookupCtxProp("userId")
    }

    /* ===================== EPISODES COUNT ===================== */

    // Caches mémoire locaux indexés par seasonId Jellyfin.
    // Toutes les sources de demande (préchargement, delegate, focus) passent
    // par la même file afin de protéger la Freebox et le serveur Jellyfin.
    property var epCountCache: ({})   // seasonId -> number | -1 (unknown) | -2 (loading)
    property var epInFlight:   ({})   // seasonId -> true
    property var _epQueued:    ({})   // seasonId -> true
    property var _epQueue:     []     // seasonId[]
    property int _epActiveCount: 0
    property int _epPrefetchPos: 0
    property int _epRequestSeq: 0
    property string _epContextKey: ""

    readonly property int episodeCountMaxInflight: 2
    readonly property int episodeCountMaxQueued: 4
    readonly property int episodeCountStartDelayMs: 120

    property int episodeCountsRev: 0  // bump => refresh bindings

    function _seasonId(it) {
        if (!it || !it.Id) return ""
        return "" + it.Id
    }

    function _modelEpisodeCount(it) {
        if (!it) return -1
        var n = -1
        try {
            if (it.ChildCount !== undefined && it.ChildCount !== null) n = Number(it.ChildCount)
            else if (it.EpisodeCount !== undefined && it.EpisodeCount !== null) n = Number(it.EpisodeCount)
            else if (it.ItemCounts && it.ItemCounts.EpisodeCount !== undefined) n = Number(it.ItemCounts.EpisodeCount)
            else if (it.ItemCounts && it.ItemCounts.Episodes !== undefined) n = Number(it.ItemCounts.Episodes)
            else if (it.RecursiveItemCount !== undefined && it.RecursiveItemCount !== null) n = Number(it.RecursiveItemCount)
        } catch(e) {
            n = -1
        }

        if (!isFinite(n) || n < 0) return -1
        return (n | 0)
    }

    function _canFetchEpisodeCounts() {
        var s = _resolvedServerUrl()
        var a = _resolvedAccessToken()
        var u = _resolvedUserId()
        return !!(s && s.length && a && a.length && u && u.length)
    }

    function _episodeContextKey() {
        return String(_resolvedServerUrl() || "") + "|" + String(_resolvedUserId() || "")
    }

    function _bumpRev() {
        episodeCountsRev = (episodeCountsRev + 1) | 0
    }

    function _setEpCache(seasonId, value) {
        if (!seasonId) return
        epCountCache[seasonId] = value
        _bumpRev()
    }

    function _setInFlight(seasonId, on) {
        if (!seasonId) return
        if (on) epInFlight[seasonId] = true
        else delete epInFlight[seasonId]
        _bumpRev()
    }

    function _clearEpisodeQueue() {
        _epQueue = []
        _epQueued = ({})
        epQueuePumpTimer.stop()
    }

    function _scheduleEpisodePump(immediate) {
        if (!_canFetchEpisodeCounts()) return
        if (_epActiveCount >= episodeCountMaxInflight) return
        if (!_epQueue || _epQueue.length <= 0) return

        epQueuePumpTimer.interval = immediate === true ? 0 : episodeCountStartDelayMs
        if (!epQueuePumpTimer.running)
            epQueuePumpTimer.restart()
    }

    function _queueEpisodeCount(seasonId, priority) {
        var sid = String(seasonId || "")
        if (!sid || !_canFetchEpisodeCounts()) return false
        if (epInFlight[sid] || _epQueued[sid]) return false

        var cur = epCountCache.hasOwnProperty(sid) ? Number(epCountCache[sid]) : -999
        if (isFinite(cur) && (cur >= 0 || cur === -1)) return false

        // Le préchargement respecte une petite file bornée. Une demande de focus
        // peut passer devant sans lancer plus de requêtes que la limite globale.
        if (priority !== true && _epQueue.length >= episodeCountMaxQueued)
            return false

        _epQueued[sid] = true
        if (priority === true) _epQueue.unshift(sid)
        else _epQueue.push(sid)

        _scheduleEpisodePump(priority === true)
        return true
    }

    function _finishEpisodeRequest(owner, sid, requestSeq, contextKey, success, count) {
        if (!owner) return

        owner._epActiveCount = Math.max(0, (owner._epActiveCount | 0) - 1)
        owner._setInFlight(sid, false)

        var current = owner._epRequestSeq === requestSeq
                && owner._episodeContextKey() === contextKey

        if (current) {
            var n = success ? Number(count) : -1
            if (!isFinite(n) || n < 0) owner._setEpCache(sid, -1)
            else owner._setEpCache(sid, Math.floor(n))
        }

        owner._scheduleEpisodePump(false)
    }

    function _startEpisodeCountRequest(seasonId) {
        var sid = String(seasonId || "")
        if (!sid || !_canFetchEpisodeCounts()) return false
        if (epInFlight[sid]) return false

        _setInFlight(sid, true)
        _setEpCache(sid, -2)
        _epActiveCount++

        var owner = root
        var requestSeq = _epRequestSeq
        var contextKey = _episodeContextKey()
        var settled = false

        function finish(success, count) {
            if (settled) return
            settled = true
            try {
                if (owner && owner._finishEpisodeRequest)
                    owner._finishEpisodeRequest(owner, sid, requestSeq, contextKey, success, count)
            } catch(e0) {}
        }

        try {
            Jellyfin.fetchFolderItemCount(
                _resolvedServerUrl(),
                _resolvedAccessToken(),
                _resolvedUserId(),
                sid,
                "Episode",
                true,
                function(count) { finish(true, count) },
                function(_err) { finish(false, -1) }
            )
        } catch(e1) {
            finish(false, -1)
        }
        return true
    }

    function _pumpEpisodeCountQueueOne() {
        if (!_canFetchEpisodeCounts()) {
            _clearEpisodeQueue()
            return
        }
        if (_epActiveCount >= episodeCountMaxInflight) return
        if (!_epQueue || _epQueue.length <= 0) return

        var sid = String(_epQueue.shift() || "")
        if (sid) delete _epQueued[sid]

        if (!sid || epInFlight[sid]) {
            _scheduleEpisodePump(false)
            return
        }

        var cur = epCountCache.hasOwnProperty(sid) ? Number(epCountCache[sid]) : -999
        if (isFinite(cur) && (cur >= 0 || cur === -1)) {
            _scheduleEpisodePump(false)
            return
        }

        _startEpisodeCountRequest(sid)

        // Espace le départ du second slot pour ne jamais créer une rafale.
        if (_epActiveCount < episodeCountMaxInflight && _epQueue.length > 0)
            _scheduleEpisodePump(false)
    }

    function _fetchEpisodeCountNow(seasonId, priority) {
        return _queueEpisodeCount(seasonId, priority === true)
    }

    Timer {
        id: epQueuePumpTimer
        interval: root.episodeCountStartDelayMs
        repeat: false
        running: false
        onTriggered: root._pumpEpisodeCountQueueOne()
    }

    Timer {
        id: epPrefetchTimer
        interval: 120
        repeat: true
        running: false
        onTriggered: {
            if (!_canFetchEpisodeCounts() || !seasons || seasons.length <= 0) {
                stop()
                return
            }
            if (_epPrefetchPos >= seasons.length) {
                stop()
                return
            }

            // Back-pressure : le préchargement n'empile jamais toute une série.
            if ((_epQueue.length + _epActiveCount)
                    >= (episodeCountMaxQueued + episodeCountMaxInflight))
                return

            var it = seasons[_epPrefetchPos]
            var sid = _seasonId(it)

            if (!sid || _modelEpisodeCount(it) >= 0) {
                _epPrefetchPos++
                return
            }

            if (epInFlight[sid] || _epQueued[sid])
                return

            if (epCountCache.hasOwnProperty(sid)) {
                var cached = Number(epCountCache[sid])
                if (isFinite(cached) && (cached >= 0 || cached === -1)) {
                    _epPrefetchPos++
                    return
                }
            }

            if (_queueEpisodeCount(sid, false))
                _epPrefetchPos++
        }
    }

    function _restartEpisodePrefetch() {
        epPrefetchTimer.stop()
        _clearEpisodeQueue()

        // Les anciennes requêtes restent comptées dans _epActiveCount jusqu'à
        // leur callback. La nouvelle vague attend donc réellement les slots libres.
        _epRequestSeq = (_epRequestSeq + 1) | 0
        _epPrefetchPos = 0

        var nextContext = _episodeContextKey()
        if (_epContextKey !== nextContext) {
            _epContextKey = nextContext
            epCountCache = ({})
        } else {
            // Les marqueurs -2 appartiennent à la génération invalidée.
            // Ils doivent redevenir éligibles dès que l'ancienne requête libère son slot.
            for (var sid in epCountCache) {
                try {
                    if (!Object.prototype.hasOwnProperty.call(epCountCache, sid)) continue
                    if (Number(epCountCache[sid]) === -2)
                        delete epCountCache[sid]
                } catch(e0) {}
            }
        }

        if (_canFetchEpisodeCounts() && seasons && seasons.length > 0)
            epPrefetchTimer.start()

        _bumpRev()
    }

    // Toujours visible : placeholder si inconnu / erreur
    function episodeText(it) {
        var n = _modelEpisodeCount(it)
        if (n >= 0) return n + " " + (n === 1 ? "épisode" : "épisodes")

        var sid = _seasonId(it)
        if (!sid) return "… épisodes"

        if (epCountCache.hasOwnProperty(sid)) {
            var c = Number(epCountCache[sid])
            if (c === -2) return "… épisodes"
            if (isFinite(c) && c >= 0) {
                c = c | 0
                return c + " " + (c === 1 ? "épisode" : "épisodes")
            }
            return "… épisodes"
        }

        return "… épisodes"
    }





    function seasonPosterHqUrl(it) {
        if (!it || !it.Id) return ""
        var srv = _resolvedServerUrl()
        var tags = it.ImageTags || {}
        if (!srv || !tags.Primary) return ""
        return Jellyfin.itemImageUrl(srv, it.Id, "Primary", tags.Primary, {
            quality: hqPosterQuality,
            fillWidth: hqReqPosterW,
            fillHeight: hqReqPosterH,
            format: "jpg"
        })
    }
    function _scheduleHqPoster(id) {
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
            if (!root.activeFocus || root.isScrolling || !root.seasons || root.currentIndex < 0 || root.currentIndex >= root.seasons.length)
                return
            var it = root.seasons[root.currentIndex]
            var id = (it && it.Id) ? String(it.Id) : ""
            if (id.length && id === root._hqPosterPendingId)
                root.hqPosterTargetId = id
        }
    }

    function seasonPosterUrl(it) {
        if (!it) return ""
        var srv = _resolvedServerUrl()
        var tags = it.ImageTags || {}
        if (!srv || !tags.Primary) return root.fallbackPosterUrl || ""
        return Jellyfin.itemImageUrl(srv, it.Id, "Primary", tags.Primary, {
            quality: root.jpgQlt,
            fillWidth: root.reqPosterW,
            fillHeight: root.reqPosterH,
            format: "jpg"
        })
    }

    function unplayedCount(it) {
        if (!it || !it.UserData) return 0
        var u = it.UserData.UnplayedItemCount
        return (typeof u === "number") ? (u | 0) : 0
    }

    function unplayedText(n) {
        return (n > 999) ? "999+" : ("" + n)
    }

    readonly property bool hasContent: seasons && seasons.length > 0
    implicitHeight: hasContent ? (title.implicitHeight + titleBottomMargin + grid.height) : 0
    visible: hasContent

    function _clampIndex(i, count) {
        var c = (count | 0)
        if (c <= 0) return 0
        var x = (i | 0)
        if (x < 0) x = 0
        if (x >= c) x = c - 1
        return x
    }

    onSeasonsChanged: {
        var c = (seasons && seasons.length) ? seasons.length : 0
        if (c <= 0) {
            currentIndex = 0
            lastFocusedIndex = 0
            epPrefetchTimer.stop()
            _clearEpisodeQueue()
            _epRequestSeq = (_epRequestSeq + 1) | 0
            _epPrefetchPos = 0
            epCountCache = ({})
            _bumpRev()
            return
        }

        var cl = _clampIndex(currentIndex, c)
        if (cl !== currentIndex) currentIndex = cl
        lastFocusedIndex = _clampIndex(lastFocusedIndex, c)

        if (grid && grid.count > 0 && grid.currentIndex !== currentIndex) {
            grid._syncing = true
            grid.currentIndex = currentIndex
            grid.positionViewAtIndex(currentIndex, ListView.Contain)
            grid._syncing = false
        }

        _restartEpisodePrefetch()
    }

    onServerUrlChanged:   _restartEpisodePrefetch()
    onAccessTokenChanged: _restartEpisodePrefetch()
    onUserIdChanged:      _restartEpisodePrefetch()

    Component.onCompleted: _restartEpisodePrefetch()

    Component.onDestruction: {
        epPrefetchTimer.stop()
        epQueuePumpTimer.stop()
        _clearEpisodeQueue()
        _epRequestSeq = (_epRequestSeq + 1) | 0
        epInFlight = ({})
        _epActiveCount = 0
    }

    onCurrentIndexChanged: {
        if (_indexFromGrid) return
        var c2 = grid ? grid.count : ((seasons && seasons.length) ? seasons.length : 0)
        var idx = _clampIndex(currentIndex, c2)
        if (idx !== currentIndex) currentIndex = idx
        lastFocusedIndex = idx

        if (grid && grid.count > 0 && grid.currentIndex !== idx) {
            grid._syncing = true
            grid.currentIndex = idx
            grid.positionViewAtIndex(idx, ListView.Contain)
            grid._syncing = false
        }
        var it = (seasons && idx >= 0 && idx < seasons.length) ? seasons[idx] : null
        _scheduleHqPoster(it && it.Id ? it.Id : "")
    }

    onActiveFocusChanged: {
        if (activeFocus) {
            grid.forceActiveFocus()
            grid.positionViewAtIndex(grid.currentIndex, ListView.Contain)
            var it = (seasons && currentIndex >= 0 && currentIndex < seasons.length) ? seasons[currentIndex] : null
            _scheduleHqPoster(it && it.Id ? it.Id : "")
        } else {
            _scheduleHqPoster("")
        }
    }

    Text { textFormat: Text.PlainText;
        id: title
        text: "Saisons"
        color: "#ffe"
        font.pixelSize: 19
        font.bold: true
        anchors.left: parent.left
        anchors.leftMargin: root.sideMargin
        visible: root.hasContent
    }

    readonly property bool isScrolling: !!(grid && (grid.moving || grid.dragging || grid.flicking))
    readonly property bool allowAnims: !!(root.visible && !root.isScrolling)

    ListView {
        id: grid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: title.bottom
        anchors.topMargin: root.titleBottomMargin
        anchors.leftMargin: root.sideMargin
        anchors.rightMargin: root.sideMargin

        height: root.gridHeight
        model: root.seasons
        orientation: ListView.Horizontal
        boundsBehavior: Flickable.StopAtBounds
        snapMode: ListView.NoSnap
        clip: true
        focus: root.activeFocus
        spacing: root.cardSpacing
        keyNavigationWraps: false
        reuseItems: true

        // ✅ premier poster légèrement plus à gauche
        header: Item { width: Math.max(8, root.edgePad - root.firstPosterLeftShift); height: 1 }
        footer: Item { width: root.edgePad; height: 1 }

        property bool _syncing: false
        Component.onCompleted: {
            _syncing = true
            var c = count | 0
            currentIndex = root._clampIndex(root.currentIndex, c)
            positionViewAtIndex(currentIndex, ListView.Contain)
            _syncing = false
        }

        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: Math.max(8, root.edgePad - root.firstPosterLeftShift)
        preferredHighlightEnd: Math.max(0, width - root.cardW - root.edgePad)
        highlightMoveDuration: 170
        highlightMoveVelocity: -1
        highlight: Item { width: root.cardW; height: root.cardH; visible: false }

        readonly property int cellW: (root.cardW + spacing)
        readonly property int padPx: cellW * root.preloadPadCards
        cacheBuffer: Math.round(Math.max(cellW * 1.5, width / 3) + padPx)
        displayMarginBeginning: Math.round(Math.max(cellW * 1.5, width / 3) + padPx)
        displayMarginEnd: Math.round(Math.max(cellW * 2.0, width / 3) + padPx)

        readonly property int approxVisibleCards: Math.max(1, Math.ceil(width / cellW))
        readonly property int loadRadiusCards: Math.max(1, approxVisibleCards + root.preloadPadCards)

        onCountChanged: {
            if (count <= 0) return
            var cl = root._clampIndex(currentIndex, count)
            if (cl !== currentIndex) {
                _syncing = true
                currentIndex = cl
                positionViewAtIndex(currentIndex, ListView.Contain)
                _syncing = false
            }
            root.lastFocusedIndex = root._clampIndex(root.lastFocusedIndex, count)
            if (!root._indexFromGrid)
                root.currentIndex = root._clampIndex(root.currentIndex, count)
        }

        onCurrentIndexChanged: {
            if (_syncing) return
            root._indexFromGrid = true
            root.currentIndex = currentIndex
            root.lastFocusedIndex = currentIndex
            root._indexFromGrid = false
        }

        function restoreOrFirstFocus() {
            var idx = root.lastFocusedIndex
            if (typeof idx !== "number" || idx < 0) idx = 0
            if (count > 0) idx = root._clampIndex(idx, count)
            _syncing = true
            currentIndex = idx
            positionViewAtIndex(currentIndex, ListView.Contain)
            _syncing = false
            forceActiveFocus()
        }

        function forceAbsoluteFirstFocus() {
            _syncing = true
            currentIndex = 0
            positionViewAtIndex(currentIndex, ListView.Contain)
            _syncing = false
            forceActiveFocus()
        }

        function forceLastFocus() {
            _syncing = true
            currentIndex = Math.max(0, count - 1)
            positionViewAtIndex(currentIndex, ListView.Contain)
            _syncing = false
            forceActiveFocus()
        }

        Keys.onPressed: {
            if (!root.seasons || !root.seasons.length) { event.accepted = false; return }

            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                if (currentIndex >= 0 && currentIndex < root.seasons.length)
                    root.openSeasonRequested(root.seasons[currentIndex])
                event.accepted = true

            } else if (event.key === Qt.Key_Left) {
                if (currentIndex > 0) currentIndex = currentIndex - 1
                event.accepted = true

            } else if (event.key === Qt.Key_Right) {
                if (currentIndex < count - 1) currentIndex = currentIndex + 1
                event.accepted = true

            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                event.accepted = root._tryFocusAbove()

            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                event.accepted = root._tryFocusBelow()

            } else {
                event.accepted = false
            }
        }

        delegate: FocusScope {
            id: seasonCard
            width: root.cardW
            height: root.cardH
            z: activeFocus ? 1000 : 0

            property string itemId: (modelData && modelData.Id) ? ("" + modelData.Id) : ""

            property bool _loadArmed: false
            property bool _srcArmed: false
            property int  _unplayed: 0
            property bool showFallback: true

            readonly property bool wantLoad: activeFocus || (Math.abs(index - grid.currentIndex) <= grid.loadRadiusCards)

            Timer {
                id: armTimer
                repeat: false
                interval: 0
                onTriggered: seasonCard._srcArmed = true
            }

            function _armSourceSoon() {
                if (_srcArmed || !_loadArmed) return
                var d = Math.abs(index - grid.currentIndex)
                armTimer.interval = activeFocus ? 0 : Math.min(80, d * 10)
                armTimer.restart()
            }

            Timer {
                id: epFetchTimer
                repeat: false
                interval: 0
                onTriggered: root._fetchEpisodeCountNow(seasonCard.itemId, seasonCard.activeFocus)
            }

            function _armEpisodeCountSoon() {
                if (!seasonCard.itemId) return
                if (!root._canFetchEpisodeCounts()) return
                if (root.epInFlight[seasonCard.itemId] || root._epQueued[seasonCard.itemId]) return
                if (root._modelEpisodeCount(modelData) >= 0) return
                if (root.epCountCache.hasOwnProperty(seasonCard.itemId)) return

                var d = Math.abs(index - grid.currentIndex)
                epFetchTimer.interval = activeFocus ? 0 : Math.min(260, 40 + d * 35)
                epFetchTimer.restart()
            }

            onWantLoadChanged: {
                if (wantLoad) {
                    if (!_loadArmed) _loadArmed = true
                    if (!_srcArmed) _armSourceSoon()
                    _armEpisodeCountSoon()
                } else {
                    armTimer.stop()
                    epFetchTimer.stop()
                }
            }

            onItemIdChanged: {
                _loadArmed = false
                _srcArmed = false
                armTimer.stop()
                epFetchTimer.stop()

                _unplayed = root.unplayedCount(modelData)
                showFallback = true
                if (card && card._applyScaleImmediate) card._applyScaleImmediate()

                if (wantLoad) {
                    _loadArmed = true
                    _armSourceSoon()
                    _armEpisodeCountSoon()
                }
            }

            Component.onCompleted: {
                if (wantLoad) {
                    _loadArmed = true
                    _armSourceSoon()
                    _armEpisodeCountSoon()
                }
                _unplayed = root.unplayedCount(modelData)
                showFallback = true
            }

            Keys.onPressed: {
                if (!modelData) { event.accepted = true; return }

                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                    root.openSeasonRequested(modelData)
                    event.accepted = true

                } else if (event.key === Qt.Key_Left) {
                    if (grid.currentIndex > 0) grid.currentIndex = grid.currentIndex - 1
                    event.accepted = true

                } else if (event.key === Qt.Key_Right) {
                    if (grid.currentIndex < grid.count - 1) grid.currentIndex = grid.currentIndex + 1
                    event.accepted = true

                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                    event.accepted = root._tryFocusAbove()

                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                    event.accepted = root._tryFocusBelow()

                } else {
                    event.accepted = false
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: root.allowHover
                onClicked: {
                    grid.currentIndex = index
                    seasonCard.forceActiveFocus()
                    root.openSeasonRequested(modelData)
                }
            }

            Column {
                anchors.fill: parent
                spacing: root.vSpacing

                Item { width: 1; height: root.topPadFor(root.posterH) }

                Item {
                    id: card
                    width: parent.width
                    height: root.posterH
                    transformOrigin: Item.Bottom
                    scale: 1.0

                    readonly property bool allowLocalAnims: root.allowAnims && grid.activeFocus
                    readonly property bool selected: seasonCard.activeFocus
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast:  (grid.count > 0) ? (index === grid.count - 1) : false

                    transform: Translate {
                        x: (card.selected && grid.activeFocus)
                           ? (card.isFirst ? root.edgeNudgePx : (card.isLast ? -root.edgeNudgePx : 0))
                           : 0
                        y: (card.selected && grid.activeFocus) ? -root.focusLiftPx : 0

                        Behavior on x { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    function _applyScaleImmediate() {
                        if (scaleIn && scaleIn.stop) scaleIn.stop()
                        if (scaleOut && scaleOut.stop) scaleOut.stop()
                        card.scale = (card.selected && grid.activeFocus) ? (root.focusScale - 0.02) : 1.0
                    }

                    SequentialAnimation {
                        id: scaleIn
                        running: false
                        PropertyAnimation { target: card; property: "scale"; to: root.focusScale; duration: 120; easing.type: Easing.OutCubic }
                        PropertyAnimation { target: card; property: "scale"; to: (root.focusScale - 0.02); duration: 90; easing.type: Easing.OutCubic }
                    }

                    NumberAnimation {
                        id: scaleOut
                        target: card
                        property: "scale"
                        to: 1.0
                        duration: 130
                        easing.type: Easing.OutCubic
                        running: false
                    }

                    onVisibleChanged: if (visible) _applyScaleImmediate()
                    Connections { target: grid; onActiveFocusChanged: card._applyScaleImmediate() }
                    Connections { target: root; onIsScrollingChanged: { if (root.isScrolling) card._applyScaleImmediate() } }

                    Item {
                        id: thumbBox
                        anchors.fill: parent
                        clip: true

                        // TWEAK Freebox GPU : clip simple poster, sans rendu offscreen ShaderEffectSource/OpacityMask.
                        Item {
                            id: paintLayer
                            anchors.fill: parent

                            Item {
                                id: imgLayer
                                anchors.fill: parent
                                visible: !seasonCard.showFallback

                                Image {
                                    id: seasonImg
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    source: (seasonCard._loadArmed && seasonCard._srcArmed) ? root.seasonPosterUrl(modelData) : ""
                                    cache: root.imgCacheEnabled
                                    asynchronous: true
                                    mipmap: false
                                    smooth: root.allowSmooth && !root.isScrolling
                                    onSourceChanged: {
                                        seasonCard.showFallback = true
                                    }
                                    onStatusChanged: {
                                        seasonCard.showFallback = (source === "" || status !== Image.Ready)
                                        if (status === Image.Ready && seasonCard.activeFocus)
                                            root._scheduleHqPoster(seasonCard.itemId)
                                    }
                                }
                                Image {
                                    id: seasonImgHq
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    source: (seasonCard.activeFocus && !root.isScrolling && seasonImg.status === Image.Ready
                                             && seasonCard.itemId.length && root.hqPosterTargetId === seasonCard.itemId)
                                            ? root.seasonPosterHqUrl(modelData) : ""
                                    cache: false
                                    asynchronous: true
                                    mipmap: false
                                    smooth: root.allowSmooth && !root.isScrolling
                                    visible: source !== "" && status === Image.Ready
                                    opacity: visible ? 1.0 : 0.0
                                    Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                }
                            }

                            Item {
                                anchors.fill: parent
                                visible: seasonCard.showFallback
                                Rectangle { anchors.fill: parent; color: "#1f233a" }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Math.max(0,
                                root.frameMargin() + root.frameWidth/2 + root.aaEps - root.frameBorderOutset
                            )
                            radius: 0
                            color: "transparent"
                            border.color: "#FFFFFF"
                            border.width: root.frameWidth
                            opacity: (card.selected && grid.activeFocus) ? 1.0 : 0.0
                            antialiasing: false
                            Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                            z: 2
                        }

                        Rectangle {
                            visible: seasonCard._unplayed > 0
                            height: 22
                            width: Math.max(height, badgeLabel.paintedWidth + 12)
                            radius: height / 2
                            color: "#2b6cf6"
                            border.color: "#ffffff"
                            border.width: 1
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 6
                            z: 4

                            Text { textFormat: Text.PlainText;
                                id: badgeLabel
                                anchors.centerIn: parent
                                text: root.unplayedText(seasonCard._unplayed)
                                color: "#ffffff"
                                font.pixelSize: 13
                                font.bold: true
                            }
                        }
                    }

                    onSelectedChanged: {
                        if (!card.allowLocalAnims) {
                            card._applyScaleImmediate()
                            return
                        }
                        if (card.selected && grid.activeFocus) {
                            scaleOut.stop()
                            scaleIn.start()
                        } else {
                            scaleIn.stop()
                            scaleOut.start()
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: root.labelH
                    clip: true

                    Text { textFormat: Text.PlainText;
                        anchors.fill: parent
                        anchors.margins: 2
                        text: root.labelFor(modelData)
                        color: seasonCard.activeFocus ? "#ffffff" : "#e7eaff"
                        font.pixelSize: 15
                        font.bold: seasonCard.activeFocus
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Item {
                    width: parent.width
                    height: root.epsH
                    clip: true

                    Text { textFormat: Text.PlainText;
                        anchors.fill: parent
                        anchors.margins: 2
                        text: {
                            var _ = root.episodeCountsRev
                            return root.episodeText(modelData)
                        }
                        color: seasonCard.activeFocus ? "#cfd6ff" : "#aeb7d7"
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            onActiveFocusChanged: {
                if (activeFocus && seasonCard.itemId) {
                    root._fetchEpisodeCountNow(seasonCard.itemId, true)
                    root._scheduleHqPoster(seasonCard.itemId)
                } else if (root._hqPosterPendingId === seasonCard.itemId || root.hqPosterTargetId === seasonCard.itemId) {
                    root._scheduleHqPoster("")
                }
            }
        }
    }

    Keys.onPressed: {
        if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
            event.accepted = root._tryFocusAbove()
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
            event.accepted = root._tryFocusBelow()
        } else {
            event.accepted = false
        }
    }
}