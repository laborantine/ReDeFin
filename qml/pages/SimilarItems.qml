import "../js/SafeLog.js" as SafeLog
// SimilarItems.qml — rail de contenus similaires pour Freebox Player.
// Delegate 2:3 optimisé pour la Révolution : chargement d’images borné,
// marquee actif uniquement au focus, et navigation D-Pad sans snap systématique.

import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../js/jellyfinBridge.js" as Jellyfin

FocusScope {
    id: similar
    width: parent ? parent.width : 1280
    focus: false

    /* ==== Contexte ==== */
    property var    item: null
    property string serverUrl
    property string accessToken
    property string userId
    property var    fbx

    /* ==== Callbacks ==== */
    property var requestFocusAbove: null
    property var requestFocusBelow: null
    signal openItemRequested(string newItemId)

    /* ===== Profil unique : LIGHT ===== */
    readonly property bool allowHover:  false
    readonly property bool allowSmooth: true
    readonly property bool imgCacheEnabled: false
    readonly property int  jpgQlt: 90
    readonly property real posterOversample: 1.40
    readonly property int hqPosterQuality: 92
    readonly property real hqPosterOversample: 1.60

    /* ==== Layout ==== */
    property int sideMargin: 28
    property int cardWidth: 180
    property int cardGap:   10

    // ✅ plus serré (CastPage-like)
    property int cardSpacing: 10   // aligné sur l’écart visuel de seriepage

    property int posterAspectW: 2
    property int posterAspectH: 3
    readonly property int posterW: Math.round(cardWidth - cardGap)
    readonly property int posterH: Math.round(posterW * posterAspectH / posterAspectW)

    // ✅ CastPage focus
    readonly property real focusScale: 1.14
    readonly property int  focusLiftPx: 6
    readonly property int  edgeNudgePx: Math.max(0, Math.ceil(posterW * (focusScale - 1) * 0.55))
    readonly property int  edgePad: Math.max(18, edgeNudgePx + 10)

    function topPadFor(h) {
        // headroom pour ne pas couper le zoom + lift (ListView clip)
        return Math.ceil(h * (focusScale - 1)) + focusLiftPx + Math.ceil(frameWidth) + 2
    }

    // Texte + classification : bloc compact, aligné à gauche
    property int titleH: 28
    property int ageRatingH: 15
    property int captionBottomPad: 10
    property int vSpacing: 5

    // ✅ on ajoute le headroom (sinon lift/zoom se fait couper en haut)
    implicitHeight: hasContent
        ? (24 + 8 + topPadFor(posterH) + posterH + (vSpacing * 3) + titleH + ageRatingH + captionBottomPad + 14)
        : 40

    /* ==== Cadre inside (coins carrés) ==== */
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    readonly property real aaEps: -2.0
    property real frameBorderOutset: 0.8
    function frameMargin() { return frameInsetPx + frameWidth/2 + frameInnerEpsilon; }

    /* ==== Oversample (via URL) ==== */
    readonly property int reqPosterW: Math.round(posterW * posterOversample)
    readonly property int reqPosterH: Math.round(posterH * posterOversample)
    readonly property int reqPosterHqW: Math.round(posterW * hqPosterOversample)
    readonly property int reqPosterHqH: Math.round(posterH * hqPosterOversample)

    /* ==== Data ==== */
    property var  items: []
    property bool hasContent: items && items.length > 0
    property bool loading: false
    property string errorMsg: ""

    property string _loadedKey: ""
    property string _inflightKey: ""
    property string _failedKey: ""

    /* ==== Mémoire focus/scroll ==== */
    property int  lastFocusedIndex: 0
    property real savedX: 0
    property bool _pendingTakeFocus: false
    property string _hqPosterCandidateId: ""
    property string hqPosterTargetId: ""
    function _cancelHqPoster(){ hqPosterTimer.stop(); _hqPosterCandidateId = ""; hqPosterTargetId = "" }
    function _scheduleHqPoster(it){ hqPosterTimer.stop(); hqPosterTargetId = ""; var id = it && it.Id ? String(it.Id) : ""; if (!id || isScrolling || !strip || !strip.activeFocus) { _hqPosterCandidateId = ""; return } _hqPosterCandidateId = id; hqPosterTimer.restart() }
    Timer { id: hqPosterTimer; interval: 280; repeat: false; onTriggered: { var idx = strip ? strip.currentIndex : -1; var it = (idx >= 0 && idx < similar.items.length) ? similar.items[idx] : null; var id = it && it.Id ? String(it.Id) : ""; similar.hqPosterTargetId = (!similar.isScrolling && strip.activeFocus && id && id === similar._hqPosterCandidateId) ? id : "" } }

    /* ==== Gates anim (CastPage-like) ==== */
    readonly property bool isScrolling: !!(strip && (strip.moving || strip.dragging || strip.flicking))
    readonly property bool allowAnims: !!(similar.visible && !similar.isScrolling)
    readonly property bool allowMaskFx: !!(similar.visible && similar.activeFocus && !similar.loading && !similar.isScrolling)
    onIsScrollingChanged: { if (isScrolling) _cancelHqPoster(); else { var idx = strip ? strip.currentIndex : -1; _scheduleHqPoster((idx >= 0 && idx < items.length) ? items[idx] : null) } }

    /* ==== Marquee premium detailMoviePage/CastPage ==== */
    // Rendu validé : OpacityMask + masque alpha gauche/droite.
    // Optimisation Freebox : le masque du titre n'est actif que pendant le scroll réel,
    // pas au repos/focus simple. Pulse texture ralenti pour réduire le coût GPU/CPU.
    property bool marqueeEnabled: true
    property real marqueeSpeedPxPerSec: 56
    property int  marqueeStartDelayMs: 700
    property int  marqueeEndPauseMs: 260
    property int  marqueeGapPx: 44

    /* ===== FIX: bubble Up/Down si pas câblé ===== */
    function _tryFocusAbove() {
        if (typeof requestFocusAbove === "function") { requestFocusAbove(); return true; }
        return false;
    }
    function _tryFocusBelow() {
        if (typeof requestFocusBelow === "function") { requestFocusBelow(); return true; }
        return false;
    }

    function _itemAt(i) {
        if (!strip || strip.count <= 0) return null
        if (i < 0 || i >= strip.count) return null
        return strip.itemAtIndex(i) // Qt 5.15
    }

    function clampContentX(x) {
        var maxX = Math.max(0, strip.contentWidth - strip.width)
        return Math.max(0, Math.min(x, maxX))
    }

    /* ==== Focus retry: attend delegate prêt ==== */
    Timer {
        id: focusRetry
        repeat: false
        interval: 0
        property int targetIndex: -1
        property int tries: 0
        onTriggered: {
            if (!similar.visible || !hasContent || targetIndex < 0) return
            var obj = _itemAt(targetIndex)
            if (obj && obj.forceActiveFocus) { obj.forceActiveFocus(); return }
            tries += 1
            if (tries < 8) { interval = 30; restart() }
        }
    }
    function _focusIndexSoon(idx) {
        if (!similar.visible) return
        focusRetry.stop()
        focusRetry.targetIndex = idx
        focusRetry.tries = 0
        focusRetry.interval = 0
        focusRetry.restart()
    }

    function focusCard(i) {
        if (!hasContent) return
        var idx = Math.max(0, Math.min(i, items.length - 1))
        lastFocusedIndex = idx

        // Glide: ListView scrolle via highlight-range
        strip.currentIndex = idx
        strip.forceActiveFocus()

        // focus réel quand prêt
        _focusIndexSoon(idx)
    }
    function restoreLastCardFocus() { focusCard(lastFocusedIndex) }

    function takeFocus() {
        if (!hasContent) { _pendingTakeFocus = true; return }
        _pendingTakeFocus = false
        strip.contentX = clampContentX(savedX)
        strip.forceActiveFocus()
        restoreLastCardFocus()
    }

    onHasContentChanged: {
        if (hasContent && _pendingTakeFocus) Qt.callLater(function(){ takeFocus() })
        if (!hasContent) { lastFocusedIndex = 0; savedX = 0 }
    }

    /* ==== Utils réseau ==== */

    function includeTypesFor(it) {
        var t = (it && (it.Type || it.MediaType)) || ""
        if (t === "Movie")   return "Movie"
        if (t === "Series")  return "Series"
        if (t === "Episode") return "Episode"
        if (t === "Season")  return "Series"
        return ""
    }
    function posterUrlFor(it, hq) {
        if (!it || !it.Id || !serverUrl) return ""
        var q = hq === true ? hqPosterQuality : jpgQlt
        var w = hq === true ? reqPosterHqW : reqPosterW
        var h = hq === true ? reqPosterHqH : reqPosterH
        var tag = it.ImageTags && it.ImageTags.Primary ? it.ImageTags.Primary : ""
        return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tag, {
            quality: q,
            format: "jpg",
            fillWidth: w,
            fillHeight: h
        })
    }

    /* ==== Badge séries : épisodes non vus ==== */
    function isSeriesItem(it) {
        var t = (it && it.Type) ? String(it.Type).toLowerCase() : ""
        return t === "series"
    }

    function _num(v) {
        var n = Number(v)
        return (isFinite(n) && n > 0) ? Math.round(n) : 0
    }

    function unplayedEpisodeCountFor(it) {
        if (!isSeriesItem(it)) return 0

        // Jellyfin renvoie généralement le compteur dans UserData.UnplayedItemCount
        // quand UserId est fourni. Plusieurs fallbacks gardent la bulle robuste
        // selon les versions serveur et les champs retournés par /Similar.
        var ud = it.UserData || null
        var n = 0

        if (ud && ud.UnplayedItemCount !== undefined) n = _num(ud.UnplayedItemCount)
        if (!n && it.UnplayedItemCount !== undefined) n = _num(it.UnplayedItemCount)
        if (!n && it.RecursiveUnplayedItemCount !== undefined) n = _num(it.RecursiveUnplayedItemCount)
        if (!n && it.UnplayedCount !== undefined) n = _num(it.UnplayedCount)

        return n
    }

    function unplayedBadgeLabel(n) {
        n = _num(n)
        return n > 99 ? "99+" : String(n)
    }

    /* ==== Classification d'âge ==== */
    function _cleanAgeRating(v) {
        var s = (v === undefined || v === null) ? "" : String(v)
        s = s.replace(/^\s+|\s+$/g, "")
        if (!s || s === "null" || s === "undefined") return ""
        if (s === "NR" || s === "N/A" || s === "Unrated" || s === "Not Rated") return ""

        // Jellyfin peut renvoyer des libellés type FR-12 / France-12 selon les métadonnées.
        s = s.replace(/^France[-_\s]*/i, "")
        s = s.replace(/^FR[-_\s]*/i, "")
        s = s.replace(/^Rated\s+/i, "")

        if (/^[0-9]+$/.test(s)) s = s + "+"
        return s
    }

    function ageRatingFor(it) {
        if (!it) return ""
        var c = [
            it.OfficialRating,
            it.CustomRating,
            it.ParentalRating,
            it.AgeRating,
            it.ContentRating
        ]
        for (var i = 0; i < c.length; i++) {
            var r = _cleanAgeRating(c[i])
            if (r.length > 0) return r
        }
        return ""
    }

    function ageRatingLabelFor(it) {
        var r = ageRatingFor(it)
        return r.length > 0 ? r : ""
    }


    function _similarRequestKey() {
        if (!(serverUrl && accessToken && userId && item && item.Id)) return ""
        // Cache mémoire uniquement : ne pas garder serverUrl|userId|itemId en clair.
        return "similar#" + SafeLog.shortHash(serverUrl + "|" + userId + "|" + item.Id) +
               "|" + includeTypesFor(item)
    }

    function _clearFetchMemo() {
        _loadedKey = ""
        _inflightKey = ""
        _failedKey = ""
    }

    function requestFetchSoon() {
        fetchDebounce.restart()
    }

    /* ==== Fetch (debounce + anti-race) ==== */
    property int _fetchToken: 0
    Timer {
        id: fetchDebounce
        interval: 90
        repeat: false
        onTriggered: fetchSimilarIfReady()
    }

    function fetchSimilarIfReady() {
        if (!(serverUrl && accessToken && userId && item && item.Id)) {
            items = []; loading = false; errorMsg = ""; _inflightKey = ""; return
        }

        var key = _similarRequestKey()
        if (!key) return
        if (_inflightKey === key) return
        if (_loadedKey === key) return
        if (_failedKey === key) return

        _fetchToken += 1
        var t = _fetchToken
        _inflightKey = key

        loading = true
        errorMsg = ""

        Jellyfin.fetchSimilarItems(serverUrl, accessToken, userId, item.Id, 20,
            function(arr) {
                if (t !== _fetchToken) return
                loading = false
                _inflightKey = ""
                _loadedKey = key
                _failedKey = ""

                items = arr || []
                if (!items.length) errorMsg = "Aucun élément similaire"

                Qt.callLater(function() {
                    strip.contentX = clampContentX(savedX)
                    strip.currentIndex = Math.max(0, Math.min(lastFocusedIndex, items.length - 1))
                })
            },
            function(_err) {
                if (t !== _fetchToken) return
                loading = false
                _inflightKey = ""
                _failedKey = key
                errorMsg = "Erreur de connexion (similar)"
                items = []
            }
        )
    }

    Component.onCompleted: requestFetchSoon()
    onItemChanged:        { _clearFetchMemo(); requestFetchSoon() }
    onServerUrlChanged:   { _clearFetchMemo(); requestFetchSoon() }
    onAccessTokenChanged: { _clearFetchMemo(); requestFetchSoon() }
    onUserIdChanged:      { _clearFetchMemo(); requestFetchSoon() }

    /* ==== UI ==== */
    Text { textFormat: Text.PlainText;
        id: title
        text: "Plus comme ceci"
        color: "#ffe"
        font.pixelSize: 19
        font.bold: true
        anchors.left: parent.left
        anchors.leftMargin: similar.sideMargin
        anchors.top: parent.top
    }

    Text { textFormat: Text.PlainText;
        id: statusText
        text: loading ? "Chargement..." : (errorMsg || "")
        visible: loading || (!!errorMsg && !hasContent)
        color: "#b0b6d0"
        font.pixelSize: 14
        anchors.left: title.left
        anchors.top: title.bottom
        anchors.topMargin: 8
    }

    ListView {
        id: strip
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: statusText.visible ? statusText.bottom : title.bottom
        anchors.topMargin: statusText.visible ? 6 : 10

        // ✅ headroom inclus pour zoom/lift
        height: similar.topPadFor(similar.posterH) + similar.posterH + (similar.vSpacing * 3) + similar.titleH + similar.ageRatingH + similar.captionBottomPad

        orientation: ListView.Horizontal
        model: items
        spacing: similar.cardSpacing
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationWraps: false
        visible: hasContent
        reuseItems: true

        // ✅ Marge 1er/dernier poster (anti-overscan + anti zoom cut)
        header: Item { width: similar.edgePad; height: 1 }
        footer: Item { width: similar.edgePad; height: 1 }

        onContentXChanged: savedX = contentX

        // Glide CastPage/SeasonsBlock
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: similar.edgePad
        preferredHighlightEnd: Math.max(0, width - similar.cardWidth - similar.edgePad)
        highlightMoveDuration: 170
        highlightMoveVelocity: -1
        highlight: Item { width: similar.cardWidth; height: strip.height; visible: false }

        // Buffers réduits
        readonly property int cellW: (similar.cardWidth + strip.spacing)
        readonly property int padPx: cellW * 1
        cacheBuffer: Math.round(Math.max(cellW * 1.0, width / 4) + padPx)
        displayMarginBeginning: Math.round(Math.max(cellW * 1.0, width / 4) + padPx)
        displayMarginEnd: Math.round(Math.max(cellW * 1.25, width / 4) + padPx)

        // rayon load (sans +1)
        readonly property int approxVisibleCards: Math.max(1, Math.ceil(width / cellW))
        readonly property int loadRadiusCards: Math.max(1, approxVisibleCards)

        // FIX: ne pas avaler Up/Down si pas de callback
        Keys.onPressed: {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                event.accepted = similar._tryFocusAbove()
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                event.accepted = similar._tryFocusBelow()
            } else {
                event.accepted = false
            }
        }

        delegate: FocusScope {
            id: cardRoot
            width: similar.cardWidth
            height: strip.height

            readonly property bool isFocused: strip.activeFocus && (strip.currentIndex === index)

            // ✅ PATCH z-order : le focus passe au-dessus des voisins
            z: (strip.activeFocus && strip.currentIndex === index) ? 1000 : 0

            property string itemId: (modelData && modelData.Id) ? ("" + modelData.Id) : ""
            readonly property bool isSeriesCard: similar.isSeriesItem(modelData)
            readonly property int  seriesUnplayedCount: similar.unplayedEpisodeCountFor(modelData)
            readonly property bool showSeriesUnplayedBadge: isSeriesCard && seriesUnplayedCount > 0

            // sticky loading
            property bool _loadArmed: false
            // stagger arm source
            property bool _srcArmed: false

            property bool showFallback: true

            // marquee burst gating
            property bool marqueeArmed: false

            readonly property bool wantLoad: activeFocus || (Math.abs(index - strip.currentIndex) <= strip.loadRadiusCards)

            // ----- Marquee arming -----
            // On arme après le focus pour laisser Text.implicitWidth et ListView.currentItem se stabiliser.
            Timer {
                id: marqueeStart
                interval: similar.marqueeStartDelayMs
                repeat: false
                onTriggered: {
                    // Lot 1 Freebox: n'arme le marquee que si le delegate est encore le courant visible.
                    if (!similar.visible || !similar.activeFocus || similar.loading || similar.isScrolling || !cardRoot.visible || !cardRoot.isFocused) {
                        cardRoot.marqueeArmed = false
                        if (titleClip) titleClip.updateMarquee()
                        return
                    }
                    cardRoot.marqueeArmed = true
                    if (titleClip) titleClip.updateMarquee()
                }
            }
            Timer { id: marqueeStop; interval: 1; repeat: false; onTriggered: cardRoot.marqueeArmed = false }

            // ----- stagger -----
            Timer {
                id: armTimer
                repeat: false
                interval: 0
                onTriggered: {
                    // Lot 1 Freebox: évite d'armer une image pour un delegate recyclé ou une page masquée.
                    if (similar.visible && cardRoot.visible && cardRoot.wantLoad && cardRoot._loadArmed)
                        cardRoot._srcArmed = true
                }
            }
            function armSourceSoon() {
                if (cardRoot._srcArmed || !cardRoot._loadArmed) return
                var d = Math.abs(index - strip.currentIndex)
                armTimer.interval = (d === 0) ? 0 : Math.min(120, 18 + d * 12)
                armTimer.restart()
            }

            // IMPORTANT: wantLoad revient -> si src pas armé, réarme
            onWantLoadChanged: {
                if (wantLoad) {
                    if (!_loadArmed) _loadArmed = true
                    if (!_srcArmed)  armSourceSoon()
                } else {
                    armTimer.stop()
                }
            }

            onItemIdChanged: {
                // reset complet reuse-safe
                _loadArmed = false
                _srcArmed = false
                armTimer.stop()

                showFallback = true

                marqueeStart.stop()
                marqueeStop.stop()
                marqueeArmed = false

                // reset anim cast-style
                if (card && card._applyScaleImmediate) card._applyScaleImmediate()

                Qt.callLater(function() {
                    if (wantLoad) {
                        _loadArmed = true
                        if (!_srcArmed) armSourceSoon()
                    }
                })
            }

            Component.onCompleted: {
                Qt.callLater(function() {
                    if (wantLoad) {
                        _loadArmed = true
                        if (!_srcArmed) armSourceSoon()
                    }
                })
                showFallback = true
                marqueeArmed = false
            }

            Keys.onPressed: {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                    var it = modelData
                    if (it && it.Id) similar.openItemRequested(it.Id)
                    event.accepted = true

                } else if (event.key === Qt.Key_Left) {
                    if (index > 0) similar.focusCard(index - 1)
                    event.accepted = true

                } else if (event.key === Qt.Key_Right) {
                    if (index < strip.count - 1) similar.focusCard(index + 1)
                    event.accepted = true

                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                    event.accepted = similar._tryFocusAbove()

                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                    event.accepted = similar._tryFocusBelow()

                } else {
                    event.accepted = false
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: similar.allowHover
                onClicked: {
                    var it = modelData
                    if (it && it.Id) similar.openItemRequested(it.Id)
                }
            }

            // ----------------------------
            // UI (CastPage feel)
            // ----------------------------
            Column {
                anchors.fill: parent
                spacing: similar.vSpacing

                // headroom (anti clipping zoom+lifts)
                Item { width: 1; height: similar.topPadFor(similar.posterH) }

                // ====== CARD poster (zoom + lift identiques CastPage) ======
                Item {
                    id: card
                    width: parent.width
                    height: similar.posterH
                    transformOrigin: Item.Bottom
                    scale: 1.0

                    readonly property bool allowLocalAnims: similar.allowAnims && strip.activeFocus
                    readonly property bool selected: cardRoot.activeFocus   // focus réel (comme CastPage)
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast:  (strip.count > 0) ? (index === strip.count - 1) : false

                    transform: Translate {
                        x: (card.selected && strip.activeFocus)
                           ? (card.isFirst ? similar.edgeNudgePx : (card.isLast ? -similar.edgeNudgePx : 0))
                           : 0
                        y: (card.selected && strip.activeFocus) ? -similar.focusLiftPx : 0

                        Behavior on x { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    function _applyScaleImmediate() {
                        if (scaleIn && scaleIn.stop) scaleIn.stop()
                        if (scaleOut && scaleOut.stop) scaleOut.stop()
                        card.scale = (card.selected && strip.activeFocus) ? (similar.focusScale - 0.02) : 1.0
                    }

                    SequentialAnimation {
                        id: scaleIn
                        running: false
                        PropertyAnimation { target: card; property: "scale"; to: similar.focusScale; duration: 120; easing.type: Easing.OutCubic }
                        PropertyAnimation { target: card; property: "scale"; to: (similar.focusScale - 0.02); duration: 90; easing.type: Easing.OutCubic }
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
                    Connections { target: strip;   onActiveFocusChanged: card._applyScaleImmediate() }
                    Connections { target: similar; onIsScrollingChanged: { if (similar.isScrolling) card._applyScaleImmediate() } }

                    // micro backplate OFF pendant scroll
                    Rectangle {
                        anchors.fill: parent
                        color: "#ffffff"
                        opacity: (card.selected && similar.allowAnims) ? 0.05 : 0.0
                        visible: opacity > 0.0
                        Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    // micro shadow interne bas OFF pendant scroll
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.round(parent.height * 0.22)
                        opacity: (card.selected && similar.allowAnims) ? 1.0 : 0.0
                        visible: opacity > 0.0
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 1.0; color: "#22000000" }
                        }
                        Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    Item {
                        id: thumbBox
                        anchors.fill: parent
                        clip: true

                        // TWEAK Freebox GPU : clip simple poster, sans texture offscreen ShaderEffectSource/OpacityMask.
                        // Les coins restent carrés et le cadre garde antialiasing=false.
                        // ✅ paintLayer toujours non-null (anti ancienne texture au recyclage)
                        Item {
                            id: paintLayer
                            anchors.fill: parent
                            y: (card.selected && card.allowLocalAnims) ? -3 : 0
                            Behavior on y { enabled: card.allowLocalAnims; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                            Item {
                                id: imgLayer
                                anchors.fill: parent
                                visible: !cardRoot.showFallback

                                Image {
                                    id: posterImg
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop

                                    // sticky + arm stagger
                                    source: (cardRoot._loadArmed && cardRoot._srcArmed) ? similar.posterUrlFor(modelData) : ""

                                    cache: similar.imgCacheEnabled
                                    asynchronous: true
                                    mipmap: false
                                    smooth: similar.allowSmooth && !similar.isScrolling
                                    transformOrigin: Item.Center
                                    scale: 1.0

                                    onSourceChanged: {
                                        // Anti-recyclage : ne jamais laisser l'ancienne jaquette visible
                                        // pendant le chargement de la nouvelle source.
                                        cardRoot.showFallback = true
                                    }
                                    onStatusChanged: {
                                        cardRoot.showFallback = (source === "" || status !== Image.Ready)
                                    }
                                }
                                Image {
                                    id: posterImgHq
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    source: (posterImg.status === Image.Ready && cardRoot.isFocused && modelData && modelData.Id && similar.hqPosterTargetId === String(modelData.Id))
                                            ? similar.posterUrlFor(modelData, true) : ""
                                    cache: false
                                    asynchronous: true
                                    mipmap: false
                                    smooth: similar.allowSmooth && !similar.isScrolling
                                    visible: source !== "" && status === Image.Ready
                                    opacity: status === Image.Ready ? 1.0 : 0.0
                                    Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                }
                            }

                            Item {
                                id: fbLayer
                                anchors.fill: parent
                                visible: cardRoot.showFallback

                                Item {
                                    id: fbContent
                                    anchors.fill: parent
                                    transformOrigin: Item.Center
                                    scale: 1.0

                                    Text { textFormat: Text.PlainText;
                                        anchors.centerIn: parent
                                        text: {
                                            var t = (modelData && modelData.Name) ? modelData.Name : "?"
                                            return t && t.length ? t.charAt(0) : "?"
                                        }
                                        color: "#b9c3ff"
                                        font.pixelSize: 28
                                        font.bold: true
                                    }
                                }
                            }
                        }

                        // Placeholder (si image pas prête)
                        Rectangle {
                            anchors.fill: parent
                            color: "#1f233a"
                            visible: !cardRoot.showFallback && posterImg.status !== Image.Ready
                        }

                        // Cadre focus (CastPage driver-friendly: width constant + anim opacity)
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Math.max(0,
                                similar.frameMargin() + similar.frameWidth/2 + similar.aaEps - similar.frameBorderOutset
                            )
                            radius: 0
                            color: "transparent"
                            border.color: "#FFFFFF"
                            border.width: similar.frameWidth
                            opacity: (card.selected && strip.activeFocus) ? 1.0 : 0.0
                            antialiasing: false
                            Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                            z: 2
                        }

                        // Bulle séries : nombre d'épisodes non regardés
                        Rectangle {
                            id: seriesUnplayedBadge
                            visible: cardRoot.showSeriesUnplayedBadge
                            enabled: false
                            z: 6
                            width: Math.max(28, badgeText.implicitWidth + 14)
                            height: 28
                            radius: 14
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: 8
                            anchors.rightMargin: 8
                            color: "#2F6BFF"
                            border.width: 1
                            border.color: "#E8F0FF"
                            opacity: visible ? 0.96 : 0.0

                            Text { textFormat: Text.PlainText;
                                id: badgeText
                                anchors.centerIn: parent
                                text: similar.unplayedBadgeLabel(cardRoot.seriesUnplayedCount)
                                color: "#FFFFFF"
                                font.pixelSize: 13
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    // zoom anim (CastPage-like)
                    onSelectedChanged: {
                        if (!card.allowLocalAnims) { card._applyScaleImmediate(); return }
                        if (card.selected && strip.activeFocus) { scaleOut.stop(); scaleIn.start() }
                        else { scaleIn.stop(); scaleOut.start() }
                    }
                }

                // Titre + marquee premium detailMoviePage/CastPage livefix
                // Identique visuellement à CastPage : source live + OpacityMask + masque alpha.
                // Différence volontaire : focusHot inclut le delegate courant du ListView,
                // sinon SimilarItems peut afficher le fondu sans jamais lancer le scroll.
                Item {
                    id: titleClip
                    width: parent.width
                    height: similar.titleH
                    clip: false

                    readonly property bool focusHot: cardRoot.activeFocus || cardRoot.isFocused
                    readonly property bool allowMarquee: similar.marqueeEnabled
                                                         && similar.visible
                                                         && similar.activeFocus
                                                         && !similar.loading
                                                         && !similar.isScrolling
                                                         && focusHot
                                                         && cardRoot.visible
                                                         && cardRoot.wantLoad
                                                         && cardRoot.marqueeArmed
                                                         && visible
                    readonly property bool marqueeNeeded: titleText.paintedWidth > (titleClip.width + 1)
                    readonly property real marqueeOverflow: Math.max(0, titleText.paintedWidth - titleClip.width)
                    readonly property int  marqueeGap: similar.marqueeGapPx
                    readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, titleText.paintedWidth + marqueeGap) : 0
                    readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                    readonly property int  marqueeScrollMs: marqueeTravel > 0
                                                              ? Math.max(3200, Math.min(14000, Math.round((marqueeTravel / Math.max(1, similar.marqueeSpeedPxPerSec)) * 1000)))
                                                              : 0
                    readonly property int  marqueeFadeW: Math.min(34, Math.max(18, Math.round(width * 0.16)))

                    // ✅ Le masque réel est gardé pour éviter les artefacts sur fonds clairs,
                    // mais il ne s'active plus au simple focus : uniquement pendant le déplacement.
                    property bool marqueeMoving: false
                    readonly property bool marqueeEligible: marqueeNeeded && allowMarquee
                    readonly property bool maskActive: marqueeEligible && marqueeMoving && cardRoot.isFocused && similar.allowMaskFx
                    readonly property bool leftFadeActive: maskActive && (titleText.x < -2)
                    readonly property bool rightFadeActive: maskActive && (titleText.x > -marqueeOverflow + 2)

                    onAllowMarqueeChanged: updateMarquee()
                    onFocusHotChanged: updateMarquee()
                    onWidthChanged: updateMarquee()
                    onVisibleChanged: updateMarquee()
                    onMarqueeNeededChanged: updateMarquee()
                    onMarqueeMovingChanged: {
                        if (titleLineTexture && titleLineTexture.scheduleUpdate)
                            titleLineTexture.scheduleUpdate()
                    }
                    Component.onCompleted: updateMarquee()

                    Item {
                        id: titleLineSource
                        anchors.fill: parent
                        clip: true
                        // Important Freebox/ListView : garder la source vivante. Le masquage
                        // visuel est fait par ShaderEffectSource.hideSource, pas via visible:false.
                        visible: true

                        Text { textFormat: Text.PlainText;
                            id: titleText
                            text: (modelData && modelData.Name) ? modelData.Name : ""
                            x: 0
                            y: Math.round((titleLineSource.height - height) / 2) - 1
                            color: titleClip.focusHot ? "#ffffff" : "#e7eaff"
                            font.pixelSize: 15
                            font.bold: titleClip.focusHot
                            wrapMode: Text.NoWrap
                            elide: titleClip.allowMarquee ? Text.ElideNone : Text.ElideRight
                            onTextChanged: titleClip.updateMarquee()
                            onPaintedWidthChanged: titleClip.updateMarquee()
                            onXChanged: {
                                // Même garde que CastPage livefix, renforcée pour SimilarItems :
                                // certains delegates recyclés conservent une texture figée sans update explicite.
                                if (titleClip.maskActive && titleLineTexture && titleLineTexture.scheduleUpdate)
                                    titleLineTexture.scheduleUpdate()
                            }
                        }
                    }

                    ShaderEffectSource {
                        id: titleLineTexture
                        sourceItem: titleLineSource
                        live: titleClip.maskActive
                        enabled: titleClip.maskActive
                        hideSource: titleClip.maskActive
                        recursive: true
                        smooth: false
                        visible: false
                        wrapMode: ShaderEffectSource.ClampToEdge
                    }

                    Timer {
                        id: titleTexturePulse
                        interval: 140
                        repeat: true
                        running: titleClip.maskActive
                                 && titleMarquee.running
                                 && titleClip.allowMarquee
                                 && similar.visible
                                 && similar.activeFocus
                                 && !similar.loading
                                 && !similar.isScrolling
                                 && cardRoot.visible
                                 && cardRoot.isFocused
                        onTriggered: {
                            // Lot 1 Freebox: pas de pulse texture si le focus/visibilité a changé entre deux ticks.
                            if (!titleClip.maskActive || !titleClip.allowMarquee || !cardRoot.visible || !cardRoot.isFocused || !similar.visible || similar.isScrolling) {
                                stop()
                                return
                            }
                            if (titleLineTexture && titleLineTexture.scheduleUpdate)
                                titleLineTexture.scheduleUpdate()
                        }
                    }

                    OpacityMask {
                        id: titleMaskedLine
                        anchors.fill: parent
                        visible: titleClip.maskActive
                        enabled: titleClip.maskActive
                        source: titleLineTexture
                        maskSource: titleFadeMask
                        cached: false
                    }

                    Item {
                        id: titleFadeMask
                        visible: titleClip.maskActive
                        x: -10000
                        y: -10000
                        width: titleClip.width
                        height: titleClip.height
                        readonly property int leftW: titleClip.leftFadeActive ? titleClip.marqueeFadeW : 0
                        readonly property int rightW: titleClip.rightFadeActive ? titleClip.marqueeFadeW : 0

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
                        ScriptAction { script: { titleText.x = 0; titleText.opacity = 1.0; titleClip.marqueeMoving = false } }
                        PauseAnimation { duration: similar.marqueeStartDelayMs }
                        ScriptAction {
                            script: {
                                titleClip.marqueeMoving = true
                                if (titleLineTexture && titleLineTexture.scheduleUpdate)
                                    titleLineTexture.scheduleUpdate()
                            }
                        }
                        NumberAnimation {
                            target: titleText
                            property: "x"
                            from: 0
                            to: titleClip.marqueeExitX
                            duration: titleClip.marqueeScrollMs
                            easing.type: Easing.Linear
                        }
                        ScriptAction {
                            script: {
                                titleClip.marqueeMoving = false
                                if (titleLineTexture && titleLineTexture.scheduleUpdate)
                                    titleLineTexture.scheduleUpdate()
                            }
                        }
                        PauseAnimation { duration: 180 }
                        ScriptAction { script: { titleText.x = 0; titleText.opacity = 1.0; titleClip.marqueeMoving = false } }
                        PauseAnimation { duration: similar.marqueeEndPauseMs }
                        onRunningChanged: {
                            if (!running) {
                                titleClip.marqueeMoving = false
                                titleText.x = 0
                                titleText.opacity = 1.0
                            }
                            if (titleLineTexture && titleLineTexture.scheduleUpdate)
                                titleLineTexture.scheduleUpdate()
                        }
                    }

                    Timer {
                        id: titleMarqueeKick
                        interval: 40
                        repeat: false
                        onTriggered: {
                            // Lot 1 Freebox: un kick retardé ne doit pas relancer un marquee sur un ancien delegate.
                            if (titleClip.marqueeEligible && titleClip.marqueeScrollMs > 0 && !titleMarquee.running && cardRoot.visible && cardRoot.isFocused && similar.visible && similar.allowMaskFx)
                                titleMarquee.start()
                        }
                    }

                    function updateMarquee() {
                        titleMarquee.stop()
                        titleMarqueeKick.stop()
                        marqueeMoving = false
                        titleText.x = 0
                        titleText.opacity = 1.0
                        if (titleLineTexture && titleLineTexture.scheduleUpdate)
                            titleLineTexture.scheduleUpdate()

                        if (titleClip.marqueeEligible && titleClip.marqueeScrollMs > 0) {
                            // Laisse le temps à ListView.currentIndex, paintedWidth et source live
                            // de se stabiliser avant de lancer le scroll.
                            titleMarqueeKick.restart()
                        }
                    }
                }

                Item {
                    id: ageRatingLine
                    width: parent.width
                    property string ratingLabel: similar.ageRatingLabelFor(modelData)
                    height: ratingLabel.length > 0 ? similar.ageRatingH : 0
                    visible: ratingLabel.length > 0

                    Text { textFormat: Text.PlainText;
                        id: ageRatingText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: 0
                        height: parent.height
                        text: ageRatingLine.ratingLabel
                        visible: text.length > 0
                        color: titleClip.focusHot ? "#d7ddff" : "#aeb6d8"
                        font.pixelSize: 12
                        font.bold: titleClip.focusHot
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignLeft
                        verticalAlignment: Text.AlignTop
                    }
                }
            }

            // ---------- focus / perf wiring ----------
            onActiveFocusChanged: {
                if (activeFocus) {
                    similar.lastFocusedIndex = index
                    strip.currentIndex = index
                    similar._scheduleHqPoster(modelData)

                    marqueeStop.stop()
                    marqueeArmed = false
                    marqueeStart.restart()
                    if (titleClip) titleClip.updateMarquee()

                    if (!_loadArmed) _loadArmed = true
                    if (!_srcArmed)  armSourceSoon()

                } else {
                    if (modelData && modelData.Id && similar.hqPosterTargetId === String(modelData.Id)) similar._cancelHqPoster()
                    marqueeStart.stop()
                    marqueeStop.stop()
                    marqueeArmed = false
                    if (titleClip) titleClip.updateMarquee()
                }
            }
        }
    }

    // Bubble global au cas où le focus est sur le root
    Keys.onPressed: {
        if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
            event.accepted = similar._tryFocusAbove()
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
            event.accepted = similar._tryFocusBelow()
        } else {
            event.accepted = false
        }
    }
}