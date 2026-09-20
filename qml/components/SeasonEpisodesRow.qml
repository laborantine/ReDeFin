// qml/components/SeasonEpisodesRow.qml — QtQuick 2.15
// Carousel d'épisodes extrait de seasonpage.qml.
// Le parent fournit directement le modèle déjà hydraté/segmenté ; le composant
// reste responsable du rendu, du focus D-Pad, du poster gating et du marquee.

import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils

FocusScope {
    id: root

    property var model: null

    property int currentIndex: 0

    property bool active: true
    property bool showFocus: true

    property string serverUrl: ""
    property int cardW: 360
    property int cardH: 240
    property int spacingPx: 22

    property bool initialWarmup: true
    property int  posterWindowWarmup: 1
    property int  posterWindowNormal: 2
    property int  posterRequestQuality: 85
    property real posterRequestScale: 1.30
    property int  posterHqRequestQuality: 90
    property real posterHqRequestScale: 1.50
    property string hqPosterTargetId: ""
    property string _hqPosterPendingId: ""
    property string posterFormat: "jpg"

    property string fallbackPosterUrl: ""

    // ✅ épisode à privilégier au retour (Id Jellyfin)
    property string preferredEpisodeId: ""
    property bool hydrated: true
    property bool focusRestoreGate: false

    // Focus style (guestpage / SeasonsBlock feel)
    property real focusScale: 1.14
    property real focusSettleScale: 1.12
    property int  focusLiftPx: 6
    property int  firstCardLeftShift: 10

    readonly property int edgeNudgePx: Math.max(0, Math.ceil(cardW * (focusScale - 1) * 0.55))
    readonly property int edgePad: Math.max(18, edgeNudgePx + 10)

    property int  frameWidth: 2
    property real frameMargin: 0

    // Cadre visible quand item sélectionné mais sans focus
    property real selectedFrameOpacity: 0.55

    // ✅ Réserve l’espace au-dessus pour zoom + lift + cadre
    readonly property int topFocusPad: Math.ceil(cardH * (focusScale - 1))
                                     + focusLiftPx
                                     + Math.ceil(frameWidth + Math.max(0, frameMargin))
                                     + 4

    // Ruban "manquant"
    property string missingRibbonText: "Manquant"
    property color  missingRibbonColor: "#C62828"
    property int    missingRibbonCornerSize: 92
    property int    missingRibbonBandW: 132
    property int    missingRibbonBandH: 26

    property string memoPrefix: "SeasonEpisodesRow"
    property string restoreToken: ""
    property string currentFocusToken: ""

    signal userIndexChanged(int idx)
    signal playRequested(int idx, var epObj)
    signal requestUp()
    signal requestGuestFocus()

    implicitHeight: root.topFocusPad + root.cardH + 58
    focus: root.active && root.showFocus
    enabled: true

    readonly property bool isScrolling: !!(list && (list.moving || list.dragging || list.flicking))
    readonly property bool allowAnims: !!(root.visible && root.active && root.showFocus && !root.isScrolling)

    // -------------------- Label helpers (SxEy + 1-liner) --------------------
    // Jellyfin: ParentIndexNumber = saison, IndexNumber = episode
    function _sxe(ep) {
        if (!ep) return ""
        var s = (ep.ParentIndexNumber !== undefined) ? (Number(ep.ParentIndexNumber) || 0) : 0
        var e = (ep.IndexNumber !== undefined) ? (Number(ep.IndexNumber) || 0) : 0

        s = (s | 0)
        e = (e | 0)

        if (s > 0 && e > 0) return "S" + String(s) + "E" + SeasonUtils.pad2(e)
        if (e > 0) return "E" + SeasonUtils.pad2(e)
        return ""
    }

    function _labelLine(ep) {
        var code = _sxe(ep)
        var name = (ep && ep.Name) ? String(ep.Name) : ""
        if (code.length && name.length) return code + " • " + name
        if (code.length) return code
        return name
    }

    function isMissingEpisode(ep) {
        if (!ep) return false
        try {
            if (ep.IsMissing === true) return true
            if (ep.IsPlaceHolder === true) return true

            var lt = String(ep.LocationType || "").toLowerCase()
            if (lt === "virtual") return true
        } catch (e) {}
        return false
    }

    function isPlayableEpisode(ep) {
        if (!ep) return false
        if (!ep.Id || !String(ep.Id).length) return false
        return !isMissingEpisode(ep)
    }

    // -------------------- Freebox-proof scheduling (no Qt.callLater) --------------------
    property bool _booting: true
    property bool _syncing: false
    property int  _restoreTries: 0
    property bool _emitAfterSync: false
    property string _emitReason: ""

    Timer {
        id: bootTimer
        interval: 0
        repeat: false
        onTriggered: root._tryFinishBoot()
    }

    Timer {
        id: syncOffTimer
        interval: 0
        repeat: false
        onTriggered: {
            root._syncing = false
            if (root._emitAfterSync) {
                root._emitAfterSync = false
                root._emitSelection(root._emitReason.length ? root._emitReason : "syncOff")
            }
        }
    }

    Timer {
        id: focusTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (root.active && root.showFocus) root.forceActiveFocus()
        }
    }

    function forceActiveFocus() {
        if (list && (root._booting || root.focusRestoreGate) && root.preferredEpisodeId && root.preferredEpisodeId.length) {
            var wanted = root._indexOfEpisodeId(root.preferredEpisodeId)
            if (wanted >= 0 && list.currentIndex !== wanted) root._commitIndex(wanted, "forceFocusPreferred", true)
        }
        if (list && list.currentItem && list.currentItem.forceActiveFocus)
            list.currentItem.forceActiveFocus()
        else if (list)
            list.forceActiveFocus()
        else
            root.forceActiveFocus()
    }


    function _emitSelection(reason) {
        if (!list || list.count <= 0) return
        root.userIndexChanged(list.currentIndex)

        if (list.currentItem && list.currentItem.epObj) {
            var tok = root._tokenFor(list.currentIndex, list.currentItem.epObj)
            if (root.currentFocusToken !== tok) {
                root.currentFocusToken = tok
            }
        }
    }

    function _commitIndex(idx, reason, silent) {
        if (!list || list.count <= 0) return false
        idx = Math.max(0, Math.min(idx | 0, list.count - 1))

        root._syncing = true
        list.currentIndex = idx
        root.currentIndex = idx

        root.updatePosterGate("commitIndex:" + reason)

        if (!silent) {
            root._emitAfterSync = true
            root._emitReason = "commitIndex:" + reason
            syncOffTimer.restart()
        } else {
            syncOffTimer.restart()
        }
        return true
    }

    // -------------------- Token helpers --------------------
    function _tokenFor(index, epObj) {
        var id = (epObj && epObj.Id) ? String(epObj.Id) : ""
        return memoPrefix + ":" + (id.length ? ("id:" + id) : ("idx:" + String(index)))
    }

    function _parseRestoreToken(tok) {
        tok = String(tok || "")
        if (!tok.length) return { kind:"", value:"" }

        var t = tok
        if (t.indexOf(memoPrefix + ":") === 0) t = t.slice((memoPrefix + ":").length)
        if (t.indexOf("id:") === 0)  return { kind:"id",  value: t.slice(3) }
        if (t.indexOf("idx:") === 0) return { kind:"idx", value: t.slice(4) }
        return { kind:"id", value: t }
    }

    function _unwrapEp(o) { return (o && o.ep) ? o.ep : o }
    function _hasExplicitBootTarget(){ return !!((preferredEpisodeId && preferredEpisodeId.length) || (restoreToken && restoreToken.length)); }
    function _isPreferredEp(ep){ return !!(ep && preferredEpisodeId && preferredEpisodeId.length && String(ep.Id || "") === preferredEpisodeId); }

    function _indexOfEpisodeId(epId) {
        epId = String(epId || "")
        if (!epId.length) return -1
        var m = model
        if (!m) return -1

        if (Array.isArray(m)) {
            for (var i = 0; i < m.length; i++) {
                var o = _unwrapEp(m[i])
                if (o && String(o.Id || "") === epId) return i
                if (m[i] && String(m[i].Id || "") === epId) return i
            }
            return -1
        }

        try {
            var c = list ? list.count : (m.count || 0)
            for (var j = 0; j < c; j++) {
                var md = m.get ? m.get(j) : null
                var eo = _unwrapEp(md)
                if (eo && String(eo.Id || "") === epId) return j
                if (md && String(md.Id || "") === epId) return j
            }
        } catch (e) {}
        return -1
    }

    function _tryFinishBoot() {
        if (!root._booting) return
        if (!list || !list.model || list.count <= 0) return

        var idx = -1
        var usedExplicit = false

        if (root.restoreToken && root.restoreToken.length && root._restoreTries < 6) {
            root._restoreTries++
            var p = _parseRestoreToken(root.restoreToken)
            if (p.kind === "idx") {
                idx = Math.max(0, Math.min(parseInt(p.value, 10) || 0, list.count - 1))
                usedExplicit = true
            } else if (p.kind === "id") {
                idx = _indexOfEpisodeId(p.value)
                if (idx >= 0) usedExplicit = true
            }
        }

        if (idx < 0 && root.preferredEpisodeId && root.preferredEpisodeId.length) {
            idx = _indexOfEpisodeId(root.preferredEpisodeId)
            if (idx >= 0) usedExplicit = true
        }

        if (idx < 0) {
            idx = Math.max(0, Math.min(root.currentIndex | 0, list.count - 1))
        }
        root._commitIndex(idx, "bootDone", true)
        root._booting = false

        if (usedExplicit && root.hydrated === false) {
            root._emitAfterSync = false
            syncOffTimer.restart()
        } else {
            root._emitAfterSync = true
            root._emitReason = "bootEmit"
            syncOffTimer.restart()
        }

        if (root.active && root.showFocus) focusTimer.restart()
    }

    // -------------------- URL helpers --------------------

    function _displayImageUrl(url) {
        // La politique de retrait des tokens d'URL appartient au bridge Jellyfin.
        // Ce wrapper reste volontairement local car il protège aussi les URL de
        // fallback/retry fournies par les delegates, pas seulement itemImageUrl().
        try {
            if (Jellyfin && typeof Jellyfin.stripAuthQueryFromUrl === "function")
                return Jellyfin.stripAuthQueryFromUrl(url)
        } catch (e) {}
        return String(url || "")
    }

    function _pickTag(ep, type) {
        if (!ep) return ""
        try {
            if (ep.ImageTags) {
                if (type === "Primary" && ep.ImageTags.Primary) return ep.ImageTags.Primary
                if (type === "Thumb" && ep.ImageTags.Thumb) return ep.ImageTags.Thumb
            }
            if (type === "Primary" && ep.PrimaryImageTag) return ep.PrimaryImageTag
            if (type === "Thumb" && ep.ThumbImageTag) return ep.ThumbImageTag
        } catch (e) {}
        return ""
    }

    function _hasAnnouncedImage(ep, type) {
        // Évite de donner à Image.source une URL Jellyfin probablement absente.
        // Sinon Qt peut logguer l'URL complète sous forme de QML Image Error.
        var tag = _pickTag(ep, type)
        return !!(tag && tag.length)
    }

    function buildImageUrl(epOrWrap, imageType, w, h, qualityOverride) {
        var ep = _unwrapEp(epOrWrap)
        if (!ep || !ep.Id || !root.serverUrl) return ""

        var type = (imageType && imageType.length) ? String(imageType) : "Primary"
        if (!_hasAnnouncedImage(ep, type)) return ""

        var iw = Math.max(64, w | 0)
        var ih = Math.max(64, h | 0)
        var q = (qualityOverride !== undefined && qualityOverride !== null)
                ? Math.max(1, Math.min(100, Number(qualityOverride) | 0))
                : Math.max(1, Math.min(100, root.posterRequestQuality | 0))
        var fmt = (root.posterFormat && root.posterFormat.length) ? root.posterFormat : "jpg"
        var tag = _pickTag(ep, type)

        return _displayImageUrl(Jellyfin.itemImageUrl(root.serverUrl, ep.Id, type, tag, {
            format: fmt,
            fillWidth: iw,
            fillHeight: ih,
            quality: q
        }))
    }

    function _focusedEpisodeId(){
        if (!list || !list.activeFocus || !list.currentItem || !root.active || !root.showFocus) return ""
        var ep = list.currentItem.epObj
        return (ep && ep.Id) ? String(ep.Id) : ""
    }
    function _scheduleHqPoster(id){
        id = id ? String(id) : ""
        hqPosterTargetId = ""
        _hqPosterPendingId = id
        hqPosterTimer.stop()
        if (id.length && root.active && root.showFocus && !root.isScrolling)
            hqPosterTimer.restart()
    }
    Timer {
        id: hqPosterTimer
        interval: 300
        repeat: false
        onTriggered: {
            var id = root._focusedEpisodeId()
            if (id.length && id === root._hqPosterPendingId && !root.isScrolling)
                root.hqPosterTargetId = id
        }
    }
    function _retryVisiblePostersAfterScroll() {
        if (!list || list.count <= 0) return

        var minI = Math.max(0, posterGateMin)
        var maxI = (posterGateMax >= 0) ? Math.min(list.count - 1, posterGateMax) : Math.min(list.count - 1, list.currentIndex + _nearEff)
        if (maxI < minI) { minI = Math.max(0, list.currentIndex - _nearEff); maxI = Math.min(list.count - 1, list.currentIndex + _nearEff) }

        for (var i = minI; i <= maxI; ++i) {
            var it = null
            try { it = list.itemAtIndex(i) } catch(e) {}
            if (it && typeof it.retryPosterAfterScroll === "function") it.retryPosterAfterScroll()
        }
    }

    onIsScrollingChanged: {
        if (isScrolling) {
            _scheduleHqPoster("")
        } else {
            _retryVisiblePostersAfterScroll()
            var id = _focusedEpisodeId()
            if (id.length) _scheduleHqPoster(id)
        }
    }

    // -------------------- Poster gate --------------------
    property int posterGateMin: 0
    property int posterGateMax: -1

    readonly property int _nearCfg: (initialWarmup ? posterWindowWarmup : posterWindowNormal)

    readonly property int _itemsPerView: {
        if (!list || list.width <= 0) return 1
        var step = cardW + list.spacing
        if (step <= 1) step = 1
        return Math.max(1, Math.ceil(list.width / step))
    }

    readonly property int _nearEff: Math.max(_nearCfg, _itemsPerView + 1)

    Timer {
        id: gateTimer
        interval: 70
        repeat: false
        onTriggered: {
            root.updatePosterGate("tick")
            // Deuxième passe après stabilisation de contentX : à cet instant les
            // delegates visibles/recyclés existent réellement et peuvent réarmer
            // une image annulée pendant le glide.
            if (!root.isScrolling) root._retryVisiblePostersAfterScroll()
        }
    }

    function updatePosterGate(reason) {
        if (!list || !list.model || list.count <= 0 || list.width <= 0) {
            posterGateMin = 0
            posterGateMax = -1
            return
        }

        var step = cardW + list.spacing
        if (step <= 1) step = 1

        var marginPx = Math.max(Math.round(cardW * 0.85), list.width)
        var left  = list.contentX - marginPx
        var right = list.contentX + list.width + marginPx

        var visMin = Math.floor(left / step)
        var visMax = Math.ceil(right / step)

        var nearMin = list.currentIndex - _nearEff
        var nearMax = list.currentIndex + _nearEff

        var minI = Math.min(visMin, nearMin)
        var maxI = Math.max(visMax, nearMax)

        minI = Math.max(0, Math.min(minI, list.count - 1))
        maxI = Math.max(0, Math.min(maxI, list.count - 1))

        posterGateMin = minI
        posterGateMax = maxI
    }

    // -------------------- Reactive hooks --------------------
    onPreferredEpisodeIdChanged: { root._booting = true; bootTimer.restart() }

    onModelChanged: { root._booting = true; bootTimer.restart() }

    onRestoreTokenChanged: {
        root._restoreTries = 0
        root._booting = true
        bootTimer.restart()
    }

    onCurrentIndexChanged: {
        if (root._booting || root._syncing) return
        if (!list || list.count <= 0) return

        var idx = Math.max(0, Math.min(root.currentIndex | 0, list.count - 1))
        if (idx !== list.currentIndex)
            root._commitIndex(idx, "externalCurrentIndex", true)
    }

    // -------------------- View --------------------
    ListView {
        id: list
        anchors.fill: parent
        clip: true

        orientation: ListView.Horizontal
        spacing: root.spacingPx

        model: root.model
        interactive: root.active
        keyNavigationWraps: false

        header: Item { width: Math.max(8, root.edgePad - root.firstCardLeftShift); height: 1 }
        footer: Item { width: root.edgePad; height: 1 }

        snapMode: ListView.NoSnap
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: Math.max(8, root.edgePad - root.firstCardLeftShift)
        preferredHighlightEnd: Math.max(0, width - root.cardW - root.edgePad)
        highlightMoveDuration: root.active ? 170 : 0
        highlightMoveVelocity: -1
        highlight: Item { width: root.cardW; height: root.topFocusPad + root.cardH + 58; visible: false }

        boundsBehavior: Flickable.StopAtBounds
        flickDeceleration: 5000
        maximumFlickVelocity: 3200

        reuseItems: true
        cacheBuffer: (width > 0 ? ((Math.max(root.cardW + root.spacingPx, (width * 0.60)) | 0)) : 0)
        displayMarginBeginning: (width > 0 ? ((Math.max(root.cardW + root.spacingPx, width * 0.40)) | 0) : 0)
        displayMarginEnd: (width > 0 ? ((Math.max(root.cardW + root.spacingPx, width * 0.40)) | 0) : 0)

        onContentXChanged: {
            if (!root.active) return
            gateTimer.restart()
        }
        onMovementStarted: root.updatePosterGate("moveStart")
        onMovementEnded: root.updatePosterGate("moveEnd")
        onWidthChanged: { root.updatePosterGate("widthChanged"); if (root._booting) bootTimer.restart() }
        onCountChanged: { root.updatePosterGate("countChanged"); if (root._booting) bootTimer.restart() }

        Component.onCompleted: {
            root._booting = true
            bootTimer.restart()
        }

        onCurrentIndexChanged: {
            root.updatePosterGate("currentIndexChanged")

            if (root.focusRestoreGate && root.preferredEpisodeId && root.preferredEpisodeId.length) {
                var wanted = root._indexOfEpisodeId(root.preferredEpisodeId)
                if (wanted >= 0 && currentIndex !== wanted) {
                    root._commitIndex(wanted, "restoreGateProtect", true)
                    return
                }
            }

            if (root._booting || root._syncing) return

            if (root.currentIndex !== currentIndex) root.currentIndex = currentIndex

            root.userIndexChanged(currentIndex)

            if (list.currentItem && list.currentItem.epObj) {
                var tok = root._tokenFor(list.currentIndex, list.currentItem.epObj)
                if (root.currentFocusToken !== tok) {
                    root.currentFocusToken = tok
                }
            }

            if (root.active && root.showFocus) focusTimer.restart()
        }

        delegate: FocusScope {
            id: card
            width: root.cardW
            height: root.topFocusPad + root.cardH + 58
            z: focusVisual ? 1000 : 0

            readonly property var _wrap: (modelData !== undefined)
                                         ? modelData
                                         : ({
                                                ep: (typeof ep !== "undefined") ? ep : null,
                                                posterUrlQ: (typeof posterUrlQ !== "undefined") ? posterUrlQ : "",
                                                posterUrl: (typeof posterUrl !== "undefined") ? posterUrl : ""
                                            })

            readonly property var epObj: root._unwrapEp(_wrap)
            readonly property bool _hideRestoreReset: (root._booting || root.focusRestoreGate) && root._hasExplicitBootTarget() && root.preferredEpisodeId.length > 0 && !root._isPreferredEp(epObj)
            readonly property bool selected: (list.currentIndex === index) && !_hideRestoreReset
            focus: root.active && root.showFocus && selected

            readonly property bool focusVisual: (activeFocus && root.showFocus && root.active)
            readonly property bool isHot: activeFocus || (ma && ma.containsMouse)
            readonly property bool selectedVisual: selected
            readonly property bool missingEpisode: root.isMissingEpisode(epObj)
            readonly property bool canPlay: root.isPlayableEpisode(epObj)

            readonly property bool allowLocalAnims: root.allowAnims && list.activeFocus
            readonly property bool isFirst: index === 0
            readonly property bool isLast: (list.count > 0) ? (index === list.count - 1) : false

            readonly property int reqW: Math.max(200, Math.round(root.cardW * root.posterRequestScale))
            readonly property int reqH: Math.max(140, Math.round(root.cardH * root.posterRequestScale))
            readonly property int hqReqW: Math.max(200, Math.round(root.cardW * root.posterHqRequestScale))
            readonly property int hqReqH: Math.max(140, Math.round(root.cardH * root.posterHqRequestScale))

            readonly property bool inNearWindow: (Math.abs(index - list.currentIndex) <= root._nearEff)
            readonly property bool wantPoster: {
                if (!root.active) return false
                if (selected) return true
                if (inNearWindow) return true
                if (root.posterGateMax >= 0 && index >= root.posterGateMin && index <= root.posterGateMax) return true
                return false
            }

            property string primaryUrl: {
                var u = ""
                if (_wrap && _wrap.posterUrlQ) u = String(_wrap.posterUrlQ)
                else if (_wrap && _wrap.posterUrl) u = String(_wrap.posterUrl)
                if (!u || !u.length) u = root.buildImageUrl(epObj, "Primary", reqW, reqH)
                return root._displayImageUrl(u)
            }
            property string thumbUrl: root.buildImageUrl(epObj, "Thumb", reqW, reqH)

            property int stage: 0
            property string src: ""
            property bool _deferredPosterRetry: false
            property int _fallbackRetryCount: 0
            property int _stageRetryCount: 0
            property string _retryUrl: ""

            // Une erreur Image pendant un glide rapide peut être une annulation
            // transitoire du backend Qt. On force une vraie réouverture de source
            // en deux frames au lieu de passer immédiatement au fallback.
            Timer {
                id: posterRetryDelayTimer
                interval: 120
                repeat: false
                onTriggered: {
                    if (!card.wantPoster || card.stage >= 2) return
                    if (root.isScrolling) { restart(); return }
                    var u = card._retryUrl && card._retryUrl.length
                            ? card._retryUrl : root._displayImageUrl(card._urlForStage())
                    if (!u || !u.length) { card._advancePosterStage(); return }
                    card._retryUrl = u
                    card.src = ""
                    posterRetryReloadTimer.restart()
                }
            }
            Timer {
                id: posterRetryReloadTimer
                interval: 24
                repeat: false
                onTriggered: {
                    if (!card.wantPoster || card.stage >= 2) return
                    if (root.isScrolling) { posterRetryDelayTimer.restart(); return }
                    var u = card._retryUrl
                    if (!u || !u.length) u = root._displayImageUrl(card._urlForStage())
                    if (u && u.length) card.src = u
                }
            }

            function _urlForStage() {
                if (stage === 0) return primaryUrl
                if (stage === 1) return thumbUrl
                return root.fallbackPosterUrl || ""
            }

            function _hqUrlForStage() {
                if (!epObj || !epObj.Id) return ""
                if (stage === 0) return root.buildImageUrl(epObj, "Primary", hqReqW, hqReqH, root.posterHqRequestQuality)
                if (stage === 1) return root.buildImageUrl(epObj, "Thumb", hqReqW, hqReqH, root.posterHqRequestQuality)
                return ""
            }

            function ensureSrc() {
                if (!wantPoster) return
                var next = _urlForStage()

                if ((!next || !next.length) && stage === 0) { stage = 1; next = _urlForStage() }
                if ((!next || !next.length) && stage === 1) { stage = 2; next = _urlForStage() }

                if (next && next.length) {
                    var cleanNext = root._displayImageUrl(next)
                    if (src !== cleanNext) src = cleanNext
                }
            }

            function _schedulePosterRetry() {
                if (!wantPoster || stage >= 2) return
                var u = _urlForStage()
                if (!u || !u.length) { _advancePosterStage(); return }
                _retryUrl = root._displayImageUrl(u)
                posterRetryReloadTimer.stop()
                posterRetryDelayTimer.restart()
            }

            function _advancePosterStage() {
                posterRetryDelayTimer.stop()
                posterRetryReloadTimer.stop()
                _retryUrl = ""
                _deferredPosterRetry = false
                _stageRetryCount = 0
                if (stage === 0) {
                    stage = 1
                    src = ""
                    ensureSrc()
                } else if (stage === 1) {
                    stage = 2
                    src = ""
                    ensureSrc()
                } else {
                    src = root._displayImageUrl(root.fallbackPosterUrl || "")
                }
            }

            function retryPosterAfterScroll() {
                if (!wantPoster) return

                // Le premier Error pendant le déplacement compte comme l'essai
                // initial. La réouverture différée ci-dessous est sa seconde chance.
                if (_deferredPosterRetry && stage < 2) {
                    _deferredPosterRetry = false
                    _stageRetryCount = Math.max(1, _stageRetryCount)
                    _schedulePosterRetry()
                    return
                }

                // Récupération d'un ancien delegate déjà tombé sur le fallback.
                // Une seule tentative par incarnation de delegate, puis on laisse
                // la vraie cascade Primary -> Thumb -> fallback décider.
                if (stage >= 2 && _fallbackRetryCount < 1 &&
                        ((primaryUrl && primaryUrl.length) || (thumbUrl && thumbUrl.length))) {
                    _fallbackRetryCount++
                    stage = 0
                    _stageRetryCount = 1
                    _retryUrl = ""
                    _schedulePosterRetry()
                }
            }

            onEpObjChanged: {
                posterRetryDelayTimer.stop()
                posterRetryReloadTimer.stop()
                stage = 0
                src = ""
                _retryUrl = ""
                _deferredPosterRetry = false
                _fallbackRetryCount = 0
                _stageRetryCount = 0
                ensureSrc()
            }
            onWantPosterChanged: ensureSrc()
            onPrimaryUrlChanged: { if (wantPoster && stage === 0) ensureSrc() }
            onThumbUrlChanged:   { if (wantPoster && stage === 1) ensureSrc() }

            Component.onCompleted: ensureSrc()

            Keys.onPressed: {
                if (!root.active) { event.accepted = true; return }

                if (event.key === Qt.Key_Left) {
                    if (list.currentIndex > 0) list.currentIndex--
                    event.accepted = true
                } else if (event.key === Qt.Key_Right) {
                    if (list.currentIndex < list.count - 1) list.currentIndex++
                    event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                    if (epObj && card.canPlay) root.playRequested(index, epObj)
                    event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                    root.requestUp()
                    event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                    root.requestGuestFocus()
                    event.accepted = true
                }
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                onEntered: {
                    if (!root.active) return
                    list.currentIndex = index
                    if (root.showFocus) card.forceActiveFocus()
                }
                onClicked: {
                    if (!root.active) return
                    list.currentIndex = index
                    if (root.showFocus) card.forceActiveFocus()
                    if (epObj && card.canPlay) root.playRequested(index, epObj)
                }
            }

            function _applyZoomImmediate() {
                scaleIn.stop()
                scaleOut.stop()
                if (focusCard) focusCard.scale = focusVisual ? root.focusSettleScale : 1.0
            }

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Item {
                    width: 1
                    height: root.topFocusPad
                }

                Item {
                    id: posterSlot
                    width: root.cardW
                    height: root.cardH
                    clip: false

                    Item {
                        id: focusCard
                        anchors.fill: parent
                        clip: false
                        transformOrigin: Item.Bottom
                        scale: 1.0

                        transform: Translate {
                            x: (card.focusVisual && list.activeFocus)
                               ? (card.isFirst ? root.edgeNudgePx : (card.isLast ? -root.edgeNudgePx : 0))
                               : 0
                            y: (root.active && card.isHot) ? -root.focusLiftPx : 0

                            Behavior on x {
                                enabled: card.allowLocalAnims
                                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                            }
                            Behavior on y {
                                enabled: card.allowLocalAnims
                                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                            }
                        }

                        Item {
                            id: posterShell
                            anchors.fill: parent
                            clip: true
                            opacity: card.missingEpisode ? 0.90 : 1.0

                            Rectangle {
                                anchors.fill: parent
                                color: "#121826"
                                visible: (posterImg.status !== Image.Ready)
                            }

                            Image {
                                id: posterImg
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                // Les vignettes épisode sont déjà bornées par le poster gate.
                                // Garder la version standard dans le cache évite de redécoder/
                                // recharger une image qui vient juste d'être affichée après un
                                // aller-retour rapide dans la ListView.
                                cache: true
                                mipmap: false
                                smooth: !root.isScrolling
                                source: card.src
                                visible: (status === Image.Ready)

                                onStatusChanged: {
                                    if (status === Image.Ready) {
                                        card._deferredPosterRetry = false
                                        card._stageRetryCount = 0
                                        card._retryUrl = ""
                                        posterRetryDelayTimer.stop()
                                        posterRetryReloadTimer.stop()
                                        if (card.focusVisual && card.epObj && card.epObj.Id)
                                            root._scheduleHqPoster(card.epObj.Id)
                                        return
                                    }
                                    if (status !== Image.Error) return
                                    if (card.stage >= 2) return

                                    // Sur Freebox, un Image.Error lors d'un déplacement rapide
                                    // peut être une annulation de chargement asynchrone, pas un 404.
                                    // On ne dégrade donc jamais vers Thumb/fallback pendant le glide.
                                    if (root.isScrolling) {
                                        card._deferredPosterRetry = true
                                        card._stageRetryCount = Math.max(1, card._stageRetryCount)
                                        return
                                    }

                                    // Hors scroll, chaque source Jellyfin a exactement une seconde
                                    // chance. Si elle échoue encore, seulement alors on passe de
                                    // Primary à Thumb, puis éventuellement au fallback série.
                                    if (card._stageRetryCount < 1) {
                                        card._stageRetryCount = 1
                                        card._schedulePosterRetry()
                                    } else {
                                        card._advancePosterStage()
                                    }
                                }
                            }

                            Image {
                                id: posterImgHq
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                mipmap: false
                                smooth: !root.isScrolling
                                source: (card.focusVisual && !root.isScrolling && posterImg.status === Image.Ready
                                         && card.epObj && card.epObj.Id
                                         && root.hqPosterTargetId === String(card.epObj.Id))
                                        ? card._hqUrlForStage() : ""
                                visible: source !== "" && status === Image.Ready
                                opacity: visible ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                            }

                            Item {
                                id: missingRibbonWrap
                                visible: card.missingEpisode
                                anchors.top: parent.top
                                anchors.right: parent.right
                                width: root.missingRibbonCornerSize
                                height: root.missingRibbonCornerSize
                                clip: true
                                z: 18

                                Rectangle {
                                    width: root.missingRibbonBandW
                                    height: root.missingRibbonBandH
                                    color: root.missingRibbonColor
                                    rotation: 45
                                    anchors.centerIn: parent
                                    antialiasing: false
                                    border.width: 0
                                }

                                Text { textFormat: Text.PlainText;
                                    text: root.missingRibbonText
                                    color: "#FFFFFF"
                                    font.pixelSize: 15
                                    font.bold: true
                                    rotation: 45
                                    anchors.centerIn: parent
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: Math.max(0, root.frameMargin)
                                color: "transparent"
                                border.color: "#FFFFFF"
                                border.width: root.frameWidth
                                antialiasing: false
                                opacity: card.focusVisual ? 1.0 : (card.selectedVisual ? root.selectedFrameOpacity : 0.0)
                                z: 10

                                Behavior on opacity {
                                    enabled: root.active
                                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                }
                            }
                        }
                    }
                }

                Item {
                    id: labelViewport
                    width: root.cardW
                    height: 22
                    clip: true

                    // Marquee premium identique au SeasonPage validé :
                    // - défile jusqu'au bout du texte ;
                    // - pas de retour arrière visible ;
                    // - fondu gauche/droite dynamique ;
                    // - fondu droite désactivé en fin de course pour révéler les dernières lettres.
                    property string lineText: root._labelLine(card.epObj)
                    property real _mx: 0
                    property real overflow: Math.max(0, Math.ceil(labelText.implicitWidth - width + 12))
                    property bool marqueeOn: (root.active && card.isHot && overflow > 6)

                    // Le masque réel reste utilisé pour éviter les artefacts sur fonds clairs,
                    // mais il ne tourne plus pendant les pauses/états immobiles du marquee.
                    property bool marqueeMoving: false
                    readonly property bool maskActive: marqueeOn && marqueeMoving && root.allowAnims
                    readonly property bool atStart: _mx >= -1
                    readonly property bool atEnd: overflow <= 1 || _mx <= -(overflow - 1)

                    function restartMarquee() {
                        labelMarqueeAnim.stop()
                        _mx = 0
                        marqueeMoving = false
                        if (labelLineTexture && labelLineTexture.scheduleUpdate)
                            labelLineTexture.scheduleUpdate()
                        if (marqueeOn) labelMarqueeAnim.restart()
                    }

                    onMarqueeOnChanged: restartMarquee()
                    onLineTextChanged: restartMarquee()
                    onWidthChanged: restartMarquee()
                    onOverflowChanged: restartMarquee()
                    onMarqueeMovingChanged: {
                        if (labelLineTexture && labelLineTexture.scheduleUpdate)
                            labelLineTexture.scheduleUpdate()
                    }

                    Item {
                        id: labelSourceViewport
                        anchors.fill: parent
                        clip: true

                        Text { textFormat: Text.PlainText;
                            id: labelText
                            x: labelViewport._mx
                            y: 0
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter

                            text: labelViewport.lineText
                            color: "#FFFFFF"
                            font.pixelSize: 18
                            font.bold: card.focusVisual
                            wrapMode: Text.NoWrap

                            elide: labelViewport.marqueeOn ? Text.ElideNone : Text.ElideRight
                            width: labelViewport.marqueeOn ? Math.ceil(implicitWidth) : labelViewport.width

                            opacity: card.focusVisual ? 1.0 : 0.94
                            onPaintedWidthChanged: labelViewport.restartMarquee()
                        }
                    }

                    ShaderEffectSource {
                        id: labelLineTexture
                        sourceItem: labelSourceViewport
                        enabled: labelViewport.maskActive
                        hideSource: labelViewport.maskActive
                        live: labelViewport.maskActive
                        recursive: false
                        visible: false
                    }

                    Item {
                        id: labelLineFadeMask
                        anchors.fill: labelSourceViewport
                        visible: false

                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.00; color: labelViewport.atStart ? "#ff000000" : "#00000000" }
                                GradientStop { position: 0.10; color: "#ff000000" }
                                GradientStop { position: 0.90; color: "#ff000000" }
                                GradientStop { position: 1.00; color: labelViewport.atEnd ? "#ff000000" : "#00000000" }
                            }
                        }
                    }

                    OpacityMask {
                        id: labelMaskedLine
                        anchors.fill: labelSourceViewport
                        source: labelLineTexture
                        maskSource: labelLineFadeMask
                        visible: labelViewport.maskActive
                        enabled: labelViewport.maskActive
                        cached: false
                    }

                    SequentialAnimation {
                        id: labelMarqueeAnim
                        running: labelViewport.marqueeOn
                        loops: Animation.Infinite

                        ScriptAction { script: { labelViewport._mx = 0; labelViewport.marqueeMoving = false } }
                        PauseAnimation { duration: 650 }

                        ScriptAction {
                            script: {
                                labelViewport.marqueeMoving = true
                                if (labelLineTexture && labelLineTexture.scheduleUpdate)
                                    labelLineTexture.scheduleUpdate()
                            }
                        }
                        NumberAnimation {
                            target: labelViewport
                            property: "_mx"
                            from: 0
                            to: -labelViewport.overflow
                            duration: Math.max(1800, Math.min(12000, Math.round(labelViewport.overflow * 38)))
                            easing.type: Easing.Linear
                        }

                        ScriptAction {
                            script: {
                                labelViewport.marqueeMoving = false
                                if (labelLineTexture && labelLineTexture.scheduleUpdate)
                                    labelLineTexture.scheduleUpdate()
                            }
                        }
                        PauseAnimation { duration: 900 }
                        PropertyAction { target: labelViewport; property: "_mx"; value: 0 }
                        ScriptAction { script: { labelViewport.marqueeMoving = false } }
                        PauseAnimation { duration: 260 }

                        onRunningChanged: {
                            if (!running) {
                                labelViewport._mx = 0
                                labelViewport.marqueeMoving = false
                                if (labelLineTexture && labelLineTexture.scheduleUpdate)
                                    labelLineTexture.scheduleUpdate()
                            }
                        }
                    }
                }
            }

            SequentialAnimation {
                id: scaleIn
                running: false
                PropertyAnimation {
                    target: focusCard
                    property: "scale"
                    to: root.focusScale
                    duration: 120
                    easing.type: Easing.OutCubic
                }
                PropertyAnimation {
                    target: focusCard
                    property: "scale"
                    to: root.focusSettleScale
                    duration: 90
                    easing.type: Easing.OutCubic
                }
            }

            NumberAnimation {
                id: scaleOut
                target: focusCard
                property: "scale"
                to: 1.0
                duration: 130
                easing.type: Easing.OutCubic
                running: false
            }

            onActiveFocusChanged: {
                if (activeFocus && epObj && epObj.Id)
                    root._scheduleHqPoster(epObj.Id)
                else if (!activeFocus && epObj && epObj.Id
                         && (root._hqPosterPendingId === String(epObj.Id)
                             || root.hqPosterTargetId === String(epObj.Id)))
                    root._scheduleHqPoster("")

                if (!root.active || !root.showFocus) {
                    _applyZoomImmediate()
                    return
                }

                if (!card.allowLocalAnims) {
                    _applyZoomImmediate()
                    return
                }

                if (activeFocus) {
                    scaleOut.stop()
                    scaleIn.start()
                } else {
                    scaleIn.stop()
                    scaleOut.start()
                }
            }

            onVisibleChanged: if (visible) _applyZoomImmediate()

            Connections {
                target: root
                function onActiveChanged() { if (!root.active) card._applyZoomImmediate() }
                function onShowFocusChanged() { if (!root.showFocus) card._applyZoomImmediate() }
                function onAllowAnimsChanged() { if (!root.allowAnims) card._applyZoomImmediate() }
            }

            Connections {
                target: list
                function onActiveFocusChanged() { card._applyZoomImmediate() }
            }
        }
    }
}
