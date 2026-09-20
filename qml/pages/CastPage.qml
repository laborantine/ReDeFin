// qml/pages/CastPage.qml — QtQuick 2.15 (sans Controls)
//
// Posters 2:3 + zoom + cadre inside + fallback personne (crop garanti)
//
// ✅ TWEAK Freebox GPU : portraits en clip simple, sans ShaderEffectSource/OpacityMask poster
// ✅ Anti ancienne texture : fallback forcé pendant chargement/recyclage
// ✅ Coins carrés : clip + cadre radius=0
// ✅ FIX FOCUS FREEZE : Up/Down acceptés seulement si callbacks présents (sinon bubble)
// ✅ Marquee premium detailMoviePage : OpacityMask + fondu gauche/droite + scroll one-way
// ✅ TWEAK Freebox GPU : masks texte activés uniquement pendant le déplacement réel
// ✅ FIX “id is not unique” : ids distincts pour les lignes nom/rôle
//
// ✅ MoviePage / mode Collections : comportement visuel partagé :
// - Espacement réduit
// - Focus “mise en avant” identique aux grilles MoviePage : zoom anim (scaleIn/scaleOut) + léger lift
// - Safe recycle: garde-fous + _applyScaleImmediate quand scroll/focus change
// - Edge-nudge (évite clipping aux bords) + highlight range ajusté
// - Micro backplate + micro shadow interne — coupés pendant scroll
// - ✅ Marge 1er/dernier poster via header/footer (anti-overscan + anti-zoom cut)
// - ✅ Remonte tout le bloc (posters+noms) via sectionTightenUpPx
//
// ✅ FIX (2026-02-28):
// - ReferenceError: selected is not defined -> utiliser card.selected dans Translate (scope)
// ✅ FIX logs Qt: ne tente plus les portraits sans PrimaryImageTag + mémo échec image

import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../js/jellyfinBridge.js" as Jellyfin
FocusScope {
    id: castPage
    width: 1280

    // ✅ Remonte le contenu du bloc (réduit l’espace sous “Distribution et équipe”)
    //   -> ajuste 8..18 selon ton goût
    property int sectionTightenUpPx: 12

    readonly property int _computedHeight: Math.max(140, cardHeight - Math.max(0, sectionTightenUpPx|0))
    height: _computedHeight
    implicitHeight: _computedHeight

    focus: false
    visible: people && people.length > 0

    /* ==== Données / Contexte ==== */
    property var    people: []
    property string serverUrl
    property string accessToken
    property string userId
    property string userName
    property string userImageTag
    property var    fbx

    /* Callbacks vers le parent */
    property var requestBackToResume: null
    property var requestFocusBelow:   null
    property var requestFocusAbove:   null

    // Le parent ouvre PersonPage.qml afin de garder CastPage léger sur Freebox Révolution.
    signal actorActivated(var personObj)

    /* ---- Style / Layout ---- */
    property int  cardWidth: 180
    property int  cardSpacing: 10
    property int  cardGap: 6

    property int  posterAspectW: 2
    property int  posterAspectH: 3
    readonly property int posterW: Math.round(cardWidth - cardGap)
    readonly property int posterH: Math.round(posterW * posterAspectH / posterAspectW)

    // Focus (identique aux grilles MoviePage)
    readonly property real focusScale: 1.14
    readonly property int  focusLiftPx: 6
    readonly property int  edgeNudgePx: Math.max(0, Math.ceil(posterW * (focusScale - 1) * 0.55))

    // marge “safe edge” (overscan + zoom)
    readonly property int edgePad: Math.max(18, edgeNudgePx + 10)

    // headroom pour que zoom+lifts ne se fassent pas couper (on garde safe)
    property int topPadTightenPx: 0
    function topPadFor(h) {
        var base = Math.ceil(h * (focusScale - 1)) + focusLiftPx + Math.ceil(frameWidth) + 2
        return Math.max(18, base - Math.max(0, topPadTightenPx|0))
    }

    // Text cut fix
    property int  nameH: 24
    property int  roleH: 21
    property int  vSpacing: 5
    readonly property int cardHeight: topPadFor(posterH) + posterH + vSpacing + nameH + roleH + vSpacing

    /* ==== Perf / anim gates ==== */
    readonly property bool isScrolling: !!(castList && (castList.moving || castList.dragging || castList.flicking))
    readonly property bool allowAnims: !!(castPage.visible && !castPage.isScrolling)
    readonly property bool allowMaskFx: !!(castPage.visible && castList && castList.activeFocus && !castPage.isScrolling)

    // Cadre inside (driver-friendly)
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    readonly property real aaEps: 0.5
    function frameMargin() { return frameInsetPx + frameWidth/2 + frameInnerEpsilon; }

    property real focusFrameExpandPx: 2.5

    /* ==== Image request policy ==== */
    property int  posterQuality: 85
    property real posterOversample: 1.30
    readonly property int  reqPosterW: Math.round(posterW * posterOversample)
    readonly property int  reqPosterH: Math.round(posterH * posterOversample)
    readonly property int  hqPosterQuality: 90
    readonly property real hqPosterOversample: 1.50
    readonly property int  hqReqPosterW: Math.round(posterW * hqPosterOversample)
    readonly property int  hqReqPosterH: Math.round(posterH * hqPosterOversample)
    property string hqPosterTargetId: ""
    property string _hqPosterPendingId: ""

    /* ==== Marquee ==== */
    property bool marqueeEnabled: true
    // Marquee premium aligné sur detailMoviePage (titre/tags/réalisé par)
    property real marqueeSpeedPxPerSec: 56
    property int  marqueeStartDelayMs: 700
    property int  marqueeEndPauseMs: 260
    property int  marqueeGapPx: 44

    /* ==== Focus state ==== */
    property int  lastFocusedIndex: 0
    readonly property int currentActorIndex: castList ? castList.currentIndex : lastFocusedIndex
    readonly property string currentActorId: {
        var idx = currentActorIndex;
        var row = (people && idx >= 0 && idx < people.length) ? people[idx] : null;
        return row && row.Id ? String(row.Id) : "";
    }
    property bool _pendingFocus: false

    function _tryFocusAbove() {
        if (typeof requestFocusAbove === "function") { requestFocusAbove(); return true; }
        if (typeof requestBackToResume === "function") { requestBackToResume(); return true; }
        return false;
    }
    function _tryFocusBelow() {
        if (typeof requestFocusBelow === "function") { requestFocusBelow(); return true; }
        return false;
    }

    function takeFocus(preferIndex) {
        if (typeof preferIndex === "number") {
            lastFocusedIndex = Math.max(0, Math.min(preferIndex, (people ? people.length - 1 : 0)));
        }
        _pendingFocus = true;
        castPage.forceActiveFocus();
        _applyPendingFocus();
    }

    function forceFirstActorFocus()  { takeFocus(0); }
    function restoreLastActorFocus() { takeFocus(lastFocusedIndex); }
    function focusFirstActor()       { takeFocus(0); }
    function focusLastActor()        { takeFocus(Math.max(0, (people ? people.length - 1 : 0))); }

    function _focusActorWhenReady(idx, tries) {
        var obj = castList.itemAtIndex(idx);
        if (obj && obj.forceActiveFocus) {
            castList.currentIndex = idx;
            obj.forceActiveFocus();
            return true;
        }
        if (tries >= 14) return false;
        Qt.callLater(function(){ _focusActorWhenReady(idx, tries + 1); });
        return false;
    }

    function focusActor(i) {
        if (!people || !people.length) return;
        var idx = Math.max(0, Math.min(i, people.length - 1));
        lastFocusedIndex = idx;
        castList.currentIndex = idx;
        _focusActorWhenReady(idx, 0);
    }

    function _actorIndexById(id) {
        id = id ? String(id) : "";
        if (!id.length || !people) return -1;
        for (var i = 0; i < people.length; i++) {
            if (people[i] && String(people[i].Id || "") === id) return i;
        }
        return -1;
    }

    function hasFocusedActor(id) {
        try {
            var idx = _actorIndexById(id);
            if (idx < 0) idx = lastFocusedIndex|0;
            var obj = castList && castList.currentItem ? castList.currentItem : null;
            var ok = !!(castPage.activeFocus && castList
                      && castList.currentIndex === idx
                      && obj && obj.activeFocus);
            return ok;
        } catch(e) {}
        return false;
    }

    function restoreActorFocus(id, fallbackIndex) {
        if (!people || !people.length || !castList) return false;
        var idx = _actorIndexById(id);
        if (idx < 0) idx = (fallbackIndex === undefined || fallbackIndex === null)
                ? lastFocusedIndex : (fallbackIndex|0);
        idx = Math.max(0, Math.min(idx, people.length - 1));
        lastFocusedIndex = idx;
        castList.currentIndex = idx;
        castPage.forceActiveFocus();
        try { castList.positionViewAtIndex(idx, ListView.Contain); } catch(ePos) {}
        _focusActorWhenReady(idx, 0);
        return true;
    }

    function _applyPendingFocus() {
        if (!_pendingFocus) return;
        if (!visible || !people || !people.length) return;
        Qt.callLater(function(){
            focusActor(lastFocusedIndex);
            _pendingFocus = false;
        });
    }


    /* ==== Images personnes : anti-spam logs Qt ====
       Ne jamais donner à Image.source une URL vouée à échouer.
       Jellyfin annonce normalement les portraits via PrimaryImageTag ou ImageTags.Primary.
       Sans tag annoncé, on affiche directement le fallback local. */
    property var _personImageFailureMemo: ({})
    readonly property int _personImageFailureMemoLimit: 128

    function _trimPersonImageFailureMemo(m) {
        var keys = Object.keys(m || ({}));
        if (keys.length <= _personImageFailureMemoLimit) return m || {};
        var out = {};
        var start = Math.max(0, keys.length - _personImageFailureMemoLimit);
        for (var i = start; i < keys.length; i++) out[keys[i]] = m[keys[i]];
        return out;
    }

    function _personPrimaryTag(p) {
        if (!p) return "";
        if (p.PrimaryImageTag) return p.PrimaryImageTag + "";
        if (p.ImageTags && p.ImageTags.Primary) return p.ImageTags.Primary + "";
        return "";
    }

    function _personImageKey(p) {
        if (!p || !p.Id) return "";
        // SÉCURITÉ : clé mémoire locale uniquement, sans token ni URL serveur.
        // Ne jamais logger cette clé en build public.
        return (p.Id + "") + "|" + _personPrimaryTag(p);
    }

    function _rememberPersonImageFailed(p) {
        var k = _personImageKey(p);
        if (!k) return;
        var m = castPage._personImageFailureMemo || {};
        if (m[k] === true) return;
        m[k] = true;
        castPage._personImageFailureMemo = _trimPersonImageFailureMemo(m);
    }

    function _personImagePreviouslyFailed(p) {
        var k = _personImageKey(p);
        if (!k) return true;
        var m = castPage._personImageFailureMemo || {};
        return m[k] === true;
    }

    function posterUrlForPerson(p) {
        if (!serverUrl || !p || !p.Id) return ""
        var tag = _personPrimaryTag(p)
        if (!tag || _personImagePreviouslyFailed(p)) return ""
        return Jellyfin.itemImageUrl(serverUrl, p.Id, "Primary", tag, {
            format: "jpg",
            quality: posterQuality,
            fillWidth: reqPosterW,
            fillHeight: reqPosterH
        })
    }

    function posterHqUrlForPerson(p) {
        if (!serverUrl || !p || !p.Id) return ""
        var tag = _personPrimaryTag(p)
        if (!tag || _personImagePreviouslyFailed(p)) return ""
        return Jellyfin.itemImageUrl(serverUrl, p.Id, "Primary", tag, {
            format: "jpg",
            quality: hqPosterQuality,
            fillWidth: hqReqPosterW,
            fillHeight: hqReqPosterH
        })
    }
    function _scheduleHqPoster(id) {
        id = id ? String(id) : ""
        hqPosterTargetId = ""
        _hqPosterPendingId = id
        hqPosterTimer.stop()
        if (id.length && castList && castList.activeFocus && !isScrolling)
            hqPosterTimer.restart()
    }
    Timer {
        id: hqPosterTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (!castList || !castList.activeFocus || castPage.isScrolling) return
            var idx = castList.currentIndex
            var p = (castPage.people && idx >= 0 && idx < castPage.people.length) ? castPage.people[idx] : null
            var id = (p && p.Id) ? String(p.Id) : ""
            if (id.length && id === castPage._hqPosterPendingId)
                castPage.hqPosterTargetId = id
        }
    }

    function ensureVisible(idx) {
        if (!castList || castList.count <= 0) return;
        castList.currentIndex = Math.max(0, Math.min(idx, castList.count - 1));
    }

    Component.onCompleted: { _applyPendingFocus(); if (visible && people && people.length) focusActor(Math.min(lastFocusedIndex, people.length - 1)); }
    onPeopleChanged: { if (people && people.length) lastFocusedIndex = Math.min(lastFocusedIndex, people.length - 1); _applyPendingFocus(); }
    onVisibleChanged: _applyPendingFocus()
    onActiveFocusChanged: { if (activeFocus) { _pendingFocus = true; _applyPendingFocus(); } }

    /* ==== UI ==== */
    ListView {
        id: castList

        // ✅ on remonte tout le contenu (posters + noms)
        y: -Math.max(0, castPage.sectionTightenUpPx|0)
        height: castPage.height + Math.max(0, castPage.sectionTightenUpPx|0)
        width: castPage.width

        clip: true
        orientation: ListView.Horizontal
        spacing: cardSpacing

        model: people || []
        interactive: true
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true

        // ✅ marge début/fin (anti overscan + zoom cut)
        header: Item { width: castPage.edgePad; height: 1 }
        footer: Item { width: castPage.edgePad; height: 1 }

        highlightFollowsCurrentItem: true
        onCurrentIndexChanged: {
            if (currentIndex >= 0 && currentIndex < castList.count)
                castPage.lastFocusedIndex = currentIndex
        }
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: castPage.edgePad
        preferredHighlightEnd: Math.max(0, width - castPage.cardWidth - castPage.edgePad)

        highlightMoveDuration: 170
        highlightMoveVelocity: -1
        highlight: Item { width: castPage.cardWidth; height: castPage.cardHeight; visible: false }

        readonly property int dynCacheBuffer: {
            var n = (people && people.length) ? people.length : 0;
            var base = 240;
            var bonus = (n <= 10) ? 120 : ((n <= 25) ? 60 : 0);
            return Math.max(120, Math.min(620, base + bonus));
        }
        cacheBuffer: dynCacheBuffer

        // ✅ FIX: n'avale Up/Down QUE si un handler existe
        Keys.onPressed: {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) event.accepted = castPage._tryFocusAbove();
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) event.accepted = castPage._tryFocusBelow();
            else event.accepted = false;
        }

        delegate: FocusScope {
            id: actorCard
            width: cardWidth
            height: cardHeight

            property var  p: modelData
            property bool localImageFailed: false
            property string posterSource: localImageFailed ? "" : castPage.posterUrlForPerson(p)
            property bool showFallback: posterSource === ""

            onPChanged: {
                localImageFailed = false
                // Anti-recyclage : cacher l'ancienne image tant que la nouvelle n'est pas Ready.
                showFallback = true
            }
            onPosterSourceChanged: {
                // Ne pas afficher l'ancienne texture pendant le chargement de la nouvelle source.
                showFallback = true
            }

            function _setCurrentAndFocus() { castList.currentIndex = index; castPage.lastFocusedIndex = index; actorCard.forceActiveFocus(); }

            Keys.onPressed: {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                    // Figer l'index AVANT de quitter la fiche. Cela évite que le
                    // snapshot parent capture l'ancien acteur lorsqu'on ouvre PersonPage.
                    actorCard._setCurrentAndFocus();
                    if (p) castPage.actorActivated(p);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left) {
                    if (index > 0) castPage.focusActor(index - 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right) {
                    if (people && index < people.length - 1) castPage.focusActor(index + 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) {
                    event.accepted = castPage._tryFocusAbove();
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) {
                    event.accepted = castPage._tryFocusBelow();
                } else {
                    event.accepted = false;
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: false
                onClicked: { actorCard._setCurrentAndFocus(); if (actorCard.p) castPage.actorActivated(actorCard.p); }
            }

            // Z-order béton
            z: activeFocus ? 1000 : 0

            Column {
                width: parent.width
                height: parent.height
                spacing: vSpacing

                // headroom (anti clipping zoom+lifts)
                Item { width: 1; height: castPage.topPadFor(posterH) }

                // ====== “CARD” poster (zoom + lift identiques aux grilles MoviePage) ======
                Item {
                    id: card
                    width: parent.width
                    height: posterH
                    transformOrigin: Item.Bottom
                    scale: 1.0

                    readonly property bool allowLocalAnims: castPage.allowAnims && castList.activeFocus
                    readonly property bool selected: actorCard.activeFocus
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast:  (people && people.length) ? (index === people.length - 1) : false

                    // ✅ FIX: utiliser card.selected (sinon ReferenceError)
                    transform: Translate {
                        x: (card.selected && castList.activeFocus)
                           ? (card.isFirst ? castPage.edgeNudgePx : (card.isLast ? -castPage.edgeNudgePx : 0))
                           : 0
                        y: (card.selected && castList.activeFocus) ? -castPage.focusLiftPx : 0

                        Behavior on x { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    function _applyScaleImmediate() {
                        if (scaleIn && scaleIn.stop) scaleIn.stop()
                        if (scaleOut && scaleOut.stop) scaleOut.stop()
                        card.scale = (card.selected && castList.activeFocus) ? (castPage.focusScale - 0.02) : 1.0
                    }

                    SequentialAnimation {
                        id: scaleIn
                        running: false
                        PropertyAnimation { target: card; property: "scale"; to: castPage.focusScale; duration: 120; easing.type: Easing.OutCubic }
                        PropertyAnimation { target: card; property: "scale"; to: (castPage.focusScale - 0.02); duration: 90; easing.type: Easing.OutCubic }
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
                    Connections { target: castList; onActiveFocusChanged: card._applyScaleImmediate() }
                    Connections { target: castPage; onIsScrollingChanged: { if (castPage.isScrolling) card._applyScaleImmediate() } }

                    // micro backplate (cheap depth) OFF pendant scroll
                    Rectangle {
                        anchors.fill: parent
                        color: "#ffffff"
                        opacity: (card.selected && castPage.allowAnims) ? 0.05 : 0.0
                        visible: opacity > 0.0
                        Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    // micro shadow interne bas OFF pendant scroll
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.round(parent.height * 0.22)
                        opacity: (card.selected && castPage.allowAnims) ? 1.0 : 0.0
                        visible: opacity > 0.0
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 1.0; color: "#22000000" }
                        }
                        Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }

                    Item {
                        anchors.fill: parent
                        clip: true

                        // TWEAK Freebox GPU : clip simple portrait, sans texture offscreen ShaderEffectSource/OpacityMask.
                        // Fond neutre de chargement derrière le portrait.
                        // Important : ne jamais le placer au-dessus de paintLayer, sinon le portrait
                        // peut rester masqué hors focus jusqu'au refresh du masque.
                        Rectangle {
                            anchors.fill: parent
                            color: "#1f233a"
                            visible: !actorCard.showFallback && actorImg.status !== Image.Ready
                            z: -1
                        }

                        // ✅ Toujours non-null (anti flash noir)
                        Item {
                            id: paintLayer
                            anchors.fill: parent
                            y: actorCard.activeFocus ? -3 : 0
                            Behavior on y { enabled: card.allowLocalAnims; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                            Item {
                                anchors.fill: parent
                                visible: !actorCard.showFallback

                                Image {
                                    id: actorImg
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    source: actorCard.posterSource
                                    cache: true
                                    asynchronous: true
                                    mipmap: false
                                    smooth: !castPage.isScrolling
                                    onSourceChanged: {
                                        // Anti-recyclage : cacher l'ancienne texture jusqu'au Ready réel.
                                        actorCard.showFallback = true
                                    }
                                    onStatusChanged: {
                                        if (status === Image.Error) {
                                            castPage._rememberPersonImageFailed(actorCard.p);
                                            actorCard.localImageFailed = true;
                                            actorCard.showFallback = true;
                                        } else if (source === "") {
                                            actorCard.showFallback = true;
                                        } else if (status === Image.Ready) {
                                            actorCard.showFallback = false;
                                            if (actorCard.activeFocus && actorCard.p && actorCard.p.Id)
                                                castPage._scheduleHqPoster(actorCard.p.Id)
                                        }
                                    }
                                }
                                Image {
                                    id: actorImgHq
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectCrop
                                    source: (actorCard.activeFocus && !castPage.isScrolling && actorImg.status === Image.Ready
                                             && actorCard.p && actorCard.p.Id
                                             && castPage.hqPosterTargetId === String(actorCard.p.Id))
                                            ? castPage.posterHqUrlForPerson(actorCard.p) : ""
                                    cache: false
                                    asynchronous: true
                                    mipmap: false
                                    smooth: !castPage.isScrolling
                                    visible: source !== "" && status === Image.Ready
                                    opacity: visible ? 1.0 : 0.0
                                    Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                }
                            }

                            Item {
                                anchors.fill: parent
                                visible: actorCard.showFallback

                                Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                                Item {
                                    anchors.centerIn: parent
                                    width: parent.width * 0.72
                                    height: parent.height * 0.62
                                    Rectangle {
                                        width: parent.width * 0.44
                                        height: width
                                        radius: width/2
                                        color: "#9aa3bd"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: 0
                                    }
                                    Rectangle {
                                        width: parent.width * 0.78
                                        height: parent.height * 0.58
                                        radius: Math.min(width, height) * 0.22
                                        color: "#7d86a4"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: parent.height * 0.38
                                    }
                                }
                            }
                        }

                        // Cadre inside (driver-friendly: width constant, anim via opacity)
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Math.max(0,
                                castPage.frameMargin() + castPage.frameWidth/2 + castPage.aaEps
                                - (actorCard.activeFocus ? castPage.focusFrameExpandPx : 0)
                            )
                            radius: 0
                            color: "transparent"
                            border.color: "#FFFFFF"
                            border.width: castPage.frameWidth
                            opacity: actorCard.activeFocus ? 1.0 : 0.0
                            antialiasing: false
                            Behavior on opacity { enabled: card.allowLocalAnims; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                            z: 2
                        }
                    }

                    // zoom anim (safe recycle)
                    onSelectedChanged: {
                        if (!card.allowLocalAnims) { card._applyScaleImmediate(); return; }
                        if (card.selected && castList.activeFocus) { scaleOut.stop(); scaleIn.start(); }
                        else { scaleIn.stop(); scaleOut.start(); }
                    }
                }

                // ===== NAME (marquee premium detailMoviePage) =====
                Item {
                    id: nameClip
                    width: parent.width
                    height: nameH
                    clip: false

                    readonly property bool allowMarquee: castPage.marqueeEnabled
                                                         && castPage.allowMaskFx
                                                         && actorCard.visible
                                                         && actorCard.activeFocus
                                                         && visible
                                                         && width > 0
                                                         && height > 0
                    readonly property bool marqueeNeeded: nameTxt.paintedWidth > (nameClip.width + 1)
                    readonly property real marqueeOverflow: Math.max(0, nameTxt.paintedWidth - nameClip.width)
                    readonly property int  marqueeGap: castPage.marqueeGapPx
                    readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, nameTxt.paintedWidth + marqueeGap) : 0
                    readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                    readonly property int  marqueeScrollMs: marqueeTravel > 0
                                                              ? Math.max(3200, Math.min(14000, Math.round((marqueeTravel / Math.max(1, castPage.marqueeSpeedPxPerSec)) * 1000)))
                                                              : 0
                    readonly property int  marqueeFadeW: Math.min(34, Math.max(18, Math.round(width * 0.16)))
                    readonly property bool marqueeArmed: marqueeNeeded && allowMarquee
                    property bool marqueeMoving: false
                    readonly property bool maskActive: marqueeArmed
                                                  && marqueeMoving
                                                  && allowMarquee
                                                  && castPage.allowMaskFx
                                                  && actorCard.visible
                                                  && actorCard.activeFocus
                                                  && visible
                                                  && width > 0
                                                  && height > 0
                    readonly property bool leftFadeActive: maskActive && (nameTxt.x < -2)
                    readonly property bool rightFadeActive: maskActive && (nameTxt.x > -marqueeOverflow + 2)

                    onAllowMarqueeChanged: updateMarquee()
                    onWidthChanged: updateMarquee()
                    onVisibleChanged: updateMarquee()
                    onMarqueeNeededChanged: updateMarquee()
                    onMarqueeMovingChanged: {
                        if (nameLineTexture && nameLineTexture.scheduleUpdate)
                            nameLineTexture.scheduleUpdate()
                    }

                    Item {
                        id: nameLineSource
                        anchors.fill: parent
                        clip: true
                        // Important Freebox/ListView: garder la source vivante pour que l'OpacityMask
                        // voie le déplacement du Text.x. Le ShaderEffectSource masque la source
                        // quand le rendu premium est actif, sans figer la texture.
                        visible: true

                        Text { textFormat: Text.PlainText;
                            id: nameTxt
                            text: (actorCard.p && actorCard.p.Name) ? actorCard.p.Name : ""
                            x: 0
                            y: Math.round((nameLineSource.height - height) / 2) - 1
                            color: actorCard.activeFocus ? "#ffffff" : "#e7ecff"
                            font.pixelSize: 15
                            font.bold: actorCard.activeFocus
                            wrapMode: Text.NoWrap
                            elide: nameClip.allowMarquee ? Text.ElideNone : Text.ElideRight
                            onTextChanged: nameClip.updateMarquee()
                            onPaintedWidthChanged: nameClip.updateMarquee()
                            onXChanged: {
                                if (nameClip.maskActive && nameLineTexture && nameLineTexture.scheduleUpdate)
                                    nameLineTexture.scheduleUpdate()
                            }
                        }
                    }

                    ShaderEffectSource {
                        id: nameLineTexture
                        sourceItem: nameLineSource
                        live: nameClip.maskActive
                        enabled: nameClip.maskActive
                        hideSource: nameClip.maskActive
                        recursive: true
                        smooth: false
                        visible: false
                        wrapMode: ShaderEffectSource.ClampToEdge
                    }

                    OpacityMask {
                        id: nameMaskedLine
                        anchors.fill: parent
                        visible: nameClip.maskActive
                        enabled: nameClip.maskActive
                        source: nameLineTexture
                        maskSource: nameFadeMask
                        cached: false
                    }

                    Item {
                        id: nameFadeMask
                        visible: nameClip.maskActive
                        x: -10000
                        y: -10000
                        width: nameClip.width
                        height: nameClip.height
                        readonly property int leftW: nameClip.leftFadeActive ? nameClip.marqueeFadeW : 0
                        readonly property int rightW: nameClip.rightFadeActive ? nameClip.marqueeFadeW : 0

                        Rectangle {
                            visible: nameFadeMask.leftW > 0
                            x: 0
                            y: 0
                            width: nameFadeMask.leftW
                            height: parent.height
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#00FFFFFF" }
                                GradientStop { position: 1.0; color: "#FFFFFFFF" }
                            }
                        }
                        Rectangle {
                            x: nameFadeMask.leftW
                            y: 0
                            width: Math.max(0, parent.width - nameFadeMask.leftW - nameFadeMask.rightW)
                            height: parent.height
                            color: "#FFFFFFFF"
                        }
                        Rectangle {
                            visible: nameFadeMask.rightW > 0
                            x: parent.width - nameFadeMask.rightW
                            y: 0
                            width: nameFadeMask.rightW
                            height: parent.height
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                GradientStop { position: 1.0; color: "#00FFFFFF" }
                            }
                        }
                    }

                    SequentialAnimation {
                        id: nameMarquee
                        running: false
                        loops: Animation.Infinite
                        ScriptAction { script: { nameClip.marqueeMoving = false; nameTxt.x = 0; nameTxt.opacity = 1.0 } }
                        PauseAnimation { duration: castPage.marqueeStartDelayMs }
                        ScriptAction { script: { nameClip.marqueeMoving = true; if (nameLineTexture && nameLineTexture.scheduleUpdate) nameLineTexture.scheduleUpdate() } }
                        NumberAnimation {
                            target: nameTxt
                            property: "x"
                            from: 0
                            to: nameClip.marqueeExitX
                            duration: nameClip.marqueeScrollMs
                            easing.type: Easing.Linear
                        }
                        ScriptAction { script: { nameTxt.x = 0; nameTxt.opacity = 1.0; nameClip.marqueeMoving = false; if (nameLineTexture && nameLineTexture.scheduleUpdate) nameLineTexture.scheduleUpdate() } }
                        PauseAnimation { duration: 180 }
                        PauseAnimation { duration: castPage.marqueeEndPauseMs }
                        onRunningChanged: {
                            if (!running) {
                                nameClip.marqueeMoving = false
                                nameTxt.x = 0
                                nameTxt.opacity = 1.0
                            }
                        }
                    }

                    Timer {
                        id: nameMarqueeArmTimer
                        interval: 16
                        repeat: false
                        onTriggered: {
                            if (nameClip.marqueeArmed
                                    && nameClip.marqueeNeeded
                                    && nameClip.allowMarquee
                                    && nameClip.marqueeScrollMs > 0
                                    && actorCard.visible
                                    && actorCard.activeFocus)
                                nameMarquee.start()
                        }
                    }

                    function updateMarquee() {
                        nameMarqueeArmTimer.stop()
                        nameMarquee.stop()
                        nameTxt.x = 0
                        nameTxt.opacity = 1.0
                        nameClip.marqueeMoving = false
                        if (nameLineTexture && nameLineTexture.scheduleUpdate)
                            nameLineTexture.scheduleUpdate()
                        if (nameClip.marqueeArmed && nameClip.marqueeScrollMs > 0)
                            nameMarqueeArmTimer.restart()
                    }
                }

                // ===== ROLE (marquee premium detailMoviePage) =====
                Item {
                    id: roleClip
                    width: parent.width
                    height: roleH
                    clip: false

                    readonly property bool allowMarquee: castPage.marqueeEnabled
                                                         && castPage.allowMaskFx
                                                         && actorCard.visible
                                                         && actorCard.activeFocus
                                                         && visible
                                                         && width > 0
                                                         && height > 0
                    readonly property bool marqueeNeeded: roleTxt.paintedWidth > (roleClip.width + 1)
                    readonly property real marqueeOverflow: Math.max(0, roleTxt.paintedWidth - roleClip.width)
                    readonly property int  marqueeGap: castPage.marqueeGapPx
                    readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, roleTxt.paintedWidth + marqueeGap) : 0
                    readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                    readonly property int  marqueeScrollMs: marqueeTravel > 0
                                                              ? Math.max(3200, Math.min(14000, Math.round((marqueeTravel / Math.max(1, castPage.marqueeSpeedPxPerSec)) * 1000)))
                                                              : 0
                    readonly property int  marqueeFadeW: Math.min(30, Math.max(16, Math.round(width * 0.15)))
                    readonly property bool marqueeArmed: marqueeNeeded && allowMarquee
                    property bool marqueeMoving: false
                    // Fondu doux conservé comme le nom acteur, mais uniquement pendant le déplacement réel.
                    readonly property bool maskActive: marqueeArmed
                                                  && marqueeMoving
                                                  && allowMarquee
                                                  && castPage.allowMaskFx
                                                  && actorCard.visible
                                                  && actorCard.activeFocus
                                                  && visible
                                                  && width > 0
                                                  && height > 0
                    readonly property bool leftFadeActive: maskActive && (roleTxt.x < -2)
                    readonly property bool rightFadeActive: maskActive && (roleTxt.x > -marqueeOverflow + 2)

                    onAllowMarqueeChanged: updateMarquee()
                    onWidthChanged: updateMarquee()
                    onVisibleChanged: updateMarquee()
                    onMarqueeNeededChanged: updateMarquee()
                    onMarqueeMovingChanged: {
                        if (roleLineTexture && roleLineTexture.scheduleUpdate)
                            roleLineTexture.scheduleUpdate()
                    }

                    Item {
                        id: roleLineSource
                        anchors.fill: parent
                        clip: true
                        // Même principe que le nom : source live + hideSource via ShaderEffectSource
                        // pour éviter le marquee figé dans les delegates ListView.
                        visible: true

                        Text { textFormat: Text.PlainText;
                            id: roleTxt
                            text: {
                                var base = (actorCard.p && actorCard.p.Role) ? actorCard.p.Role
                                          : ((actorCard.p && actorCard.p.Type) ? actorCard.p.Type : "")
                                return base || ""
                            }
                            x: 0
                            y: Math.round((roleLineSource.height - height) / 2) - 1
                            color: actorCard.activeFocus ? "#cfd6ff" : "#aeb7d7"
                            font.pixelSize: 13
                            wrapMode: Text.NoWrap
                            elide: roleClip.allowMarquee ? Text.ElideNone : Text.ElideRight
                            onTextChanged: roleClip.updateMarquee()
                            onPaintedWidthChanged: roleClip.updateMarquee()
                            onXChanged: {
                                if (roleClip.maskActive && roleLineTexture && roleLineTexture.scheduleUpdate)
                                    roleLineTexture.scheduleUpdate()
                            }
                        }
                    }

                    ShaderEffectSource {
                        id: roleLineTexture
                        sourceItem: roleLineSource
                        live: roleClip.maskActive
                        enabled: roleClip.maskActive
                        hideSource: roleClip.maskActive
                        recursive: true
                        smooth: false
                        visible: false
                        wrapMode: ShaderEffectSource.ClampToEdge
                    }

                    OpacityMask {
                        id: roleMaskedLine
                        anchors.fill: parent
                        visible: roleClip.maskActive
                        enabled: roleClip.maskActive
                        source: roleLineTexture
                        maskSource: roleFadeMask
                        cached: false
                    }

                    Item {
                        id: roleFadeMask
                        visible: roleClip.maskActive
                        x: -10000
                        y: -10000
                        width: roleClip.width
                        height: roleClip.height
                        readonly property int leftW: roleClip.leftFadeActive ? roleClip.marqueeFadeW : 0
                        readonly property int rightW: roleClip.rightFadeActive ? roleClip.marqueeFadeW : 0

                        Rectangle {
                            visible: roleFadeMask.leftW > 0
                            x: 0
                            y: 0
                            width: roleFadeMask.leftW
                            height: parent.height
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#00FFFFFF" }
                                GradientStop { position: 1.0; color: "#FFFFFFFF" }
                            }
                        }
                        Rectangle {
                            x: roleFadeMask.leftW
                            y: 0
                            width: Math.max(0, parent.width - roleFadeMask.leftW - roleFadeMask.rightW)
                            height: parent.height
                            color: "#FFFFFFFF"
                        }
                        Rectangle {
                            visible: roleFadeMask.rightW > 0
                            x: parent.width - roleFadeMask.rightW
                            y: 0
                            width: roleFadeMask.rightW
                            height: parent.height
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                GradientStop { position: 1.0; color: "#00FFFFFF" }
                            }
                        }
                    }

                    SequentialAnimation {
                        id: roleMarquee
                        running: false
                        loops: Animation.Infinite
                        ScriptAction { script: { roleClip.marqueeMoving = false; roleTxt.x = 0; roleTxt.opacity = 1.0 } }
                        PauseAnimation { duration: castPage.marqueeStartDelayMs }
                        ScriptAction { script: { roleClip.marqueeMoving = true; if (roleLineTexture && roleLineTexture.scheduleUpdate) roleLineTexture.scheduleUpdate() } }
                        NumberAnimation {
                            target: roleTxt
                            property: "x"
                            from: 0
                            to: roleClip.marqueeExitX
                            duration: roleClip.marqueeScrollMs
                            easing.type: Easing.Linear
                        }
                        ScriptAction { script: { roleTxt.x = 0; roleTxt.opacity = 1.0; roleClip.marqueeMoving = false; if (roleLineTexture && roleLineTexture.scheduleUpdate) roleLineTexture.scheduleUpdate() } }
                        PauseAnimation { duration: 180 }
                        PauseAnimation { duration: castPage.marqueeEndPauseMs }
                        onRunningChanged: {
                            if (!running) {
                                roleClip.marqueeMoving = false
                                roleTxt.x = 0
                                roleTxt.opacity = 1.0
                            }
                        }
                    }

                    Timer {
                        id: roleMarqueeArmTimer
                        interval: 16
                        repeat: false
                        onTriggered: {
                            if (roleClip.marqueeArmed
                                    && roleClip.marqueeNeeded
                                    && roleClip.allowMarquee
                                    && roleClip.marqueeScrollMs > 0
                                    && actorCard.visible
                                    && actorCard.activeFocus)
                                roleMarquee.start()
                        }
                    }

                    function updateMarquee() {
                        roleMarqueeArmTimer.stop()
                        roleMarquee.stop()
                        roleTxt.x = 0
                        roleTxt.opacity = 1.0
                        roleClip.marqueeMoving = false
                        if (roleLineTexture && roleLineTexture.scheduleUpdate)
                            roleLineTexture.scheduleUpdate()
                        if (roleClip.marqueeArmed && roleClip.marqueeScrollMs > 0)
                            roleMarqueeArmTimer.restart()
                    }
                }
            }

            onActiveFocusChanged: {
                if (activeFocus) {
                    castPage.lastFocusedIndex = index;
                    castPage.ensureVisible(index);
                    if (actorCard.p && actorCard.p.Id)
                        castPage._scheduleHqPoster(actorCard.p.Id);
                    // Pas de Qt.callLater ici : le delegate peut être recyclé
                    // avant l'exécution du callback. Les Timer locaux des deux
                    // marquées assurent désormais le léger différé en sécurité.
                    if (nameClip) nameClip.updateMarquee();
                    if (roleClip) roleClip.updateMarquee();
                } else {
                    if (actorCard.p && actorCard.p.Id
                            && (castPage._hqPosterPendingId === String(actorCard.p.Id)
                                || castPage.hqPosterTargetId === String(actorCard.p.Id)))
                        castPage._scheduleHqPoster("");
                    if (nameClip) nameClip.updateMarquee();
                    if (roleClip) roleClip.updateMarquee();
                }
            }
        }
    }

    // Bubble global si focus est sur castPage (pas sur castList/actorCard)
    Keys.onPressed: {
        if (event.key === Qt.Key_Up || event.key === Qt.Key_PageUp) event.accepted = castPage._tryFocusAbove();
        else if (event.key === Qt.Key_Down || event.key === Qt.Key_PageDown) event.accepted = castPage._tryFocusBelow();
        else event.accepted = false;
    }
}
