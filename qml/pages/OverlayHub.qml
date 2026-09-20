// qml/pages/OverlayHub.qml — overlay "poster" | "overview" | "person" | "loading"
//
// ✅ Optimisations Freebox (GPU/RAM/CPU/DISK):
// - Backdrop/scrim: un seul Rectangle + fade (pas d’effets)
// - Modes via Loader: instanciation à la demande (RAM/CPU ↓)
// - Images overlay: cache=false (évite écritures disque), mipmap=false (VRAM ↓)
// - Bornage URL Jellyfin (évite decode 4K)
// - Flickable: interactive seulement si scroll nécessaire
// - Scrollbar: visible/opacity conditionnels (pas d’animations inutiles)
// - Close: centralisé (anti double signal), + trap clavier propre
// - Reset scroll sur changement de mode/payload (stabilité)
//
// ✅ 5 tweaks PIC appliqués (objectif Revolution):
// (1) Caps plus agressifs par défaut (fallback 1280×720) + caps locaux (overview/person)
// (2) PreserveAspectFit => bornage serveur via maxWidth/maxHeight (pas fill*)
// (3) Suppression des sourceSize (on borne via URL Jellyfin uniquement)
// (4) Arm en 2 ticks: texte/layout d’abord, images ensuite (anti “tout la même frame”)
// (5) Gate texte lourd (overview/bio) + apply/reset/focus coalescé (anti doubles resets)
//
// ✅ Tweak 1 (HOST-DRIVEN):
// - Peut suivre un host (detail/seasonpage) via host.overlayMode + host.overlayData
// - Plus besoin de “applyState()” côté page: OverlayHub se met à jour tout seul
//
// ✅ Tweak 2 (déport Loading layer dans OverlayHub):
// - mode "loading": spinner + dots + message + Back/Escape handling via payload.onBack()
// - Click-to-close désactivé en mode loading (comme ton loadingOverlay)
//
// QtQuick 2.15

import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/SafeLog.js" as SafeLog

FocusScope {
    id: overlayhub
    anchors.fill: parent
    focus: true

    /* ===== API host-driven ===== */
    // "none" | "poster" | "overview" | "person" | "loading"
    // Attendu: host.overlayMode + host.overlayData (seasonpage/detail*).
    property var host: null

    // ✅ IMPORTANT: propriétés attendues par detailMoviePage / detailSeriePage
    // (assignables depuis l’extérieur, sans binding-loop)
    // 0 => fallback interne
    property int posterMaxW: 0
    property int posterMaxH: 0

    // Qualité
    readonly property int defaultQuality: 85

    // Sécurité publication:
    // true => Image.source ne reçoit jamais X-Emby-Token / X-MediaBrowser-Token / api_key.
    // Le probe XHR peut encore utiliser le token extrait en header, ce qui évite les fuites dans les logs Qt Image.
    readonly property bool publicBuildNoImageTokenInUrl: true
    property bool allowImageTokenInUrl: false

    // Caches image overlay: évite de redonner à Image.source des URLs connues KO
    // et évite le spam naturel Qt avec token dans les erreurs QML Image.
    property var _imageReadyMemo: ({})
    property var _imageFailureMemo: ({})
    readonly property int _imageMemoLimit: 128

    function _trimImageMemo(m) {
        var keys = Object.keys(m || ({}));
        if (keys.length <= _imageMemoLimit) return m || {};
        var out = {};
        var start = Math.max(0, keys.length - _imageMemoLimit);
        for (var i = start; i < keys.length; i++) out[keys[i]] = m[keys[i]];
        return out;
    }

    function _rememberImageReady(key) {
        if (!key) return;
        var m = _imageReadyMemo || {};
        if (m[key] === true) return;
        m[key] = true;
        _imageReadyMemo = _trimImageMemo(m);
    }

    function _rememberImageFailure(key) {
        if (!key) return;
        var m = _imageFailureMemo || {};
        if (m[key] === true) return;
        m[key] = true;
        _imageFailureMemo = _trimImageMemo(m);
    }

    // Mode/payload effectifs fournis par le host.
    function _hostMode() {
        if (!host) return "";
        if (host.overlayMode !== undefined) return _safeStr(host.overlayMode);
        if (host.mode !== undefined) return _safeStr(host.mode);
        return "";
    }
    function _hostPayload() {
        if (!host) return null;
        if (host.overlayData !== undefined) return host.overlayData;
        if (host.payload !== undefined) return host.payload;
        return null;
    }

    readonly property string effectiveMode: host ? (_hostMode() || "none") : "none"
    readonly property var effectivePayload: host ? (_hostPayload() || ({})) : ({})

    signal requestClose()
    signal closed()

    // anti-double close
    property bool _closing: false

    /* ===== helpers ===== */
    function _safeStr(x){ return (x === undefined || x === null) ? "" : ("" + x); }
    function _safeObj(o){ return o ? o : ({}); }

    // Query helpers sans URLSearchParams (compat Qt/QML Freebox).
    function _queryKey(part) {
        var p = _safeStr(part);
        var eq = p.indexOf("=");
        return ((eq >= 0) ? p.substring(0, eq) : p).toLowerCase();
    }

    function _hasQueryParam(url, key) {
        var u = _safeStr(url);
        var k = _safeStr(key).toLowerCase();
        if (!u || !k || u.indexOf("?") < 0) return false;
        var q = u.substring(u.indexOf("?") + 1);
        var hash = q.indexOf("#");
        if (hash >= 0) q = q.substring(0, hash);
        var parts = q.split("&");
        for (var i = 0; i < parts.length; ++i) {
            if (_queryKey(parts[i]) === k) return true;
        }
        return false;
    }

    function _removeQueryParams(url, names) {
        var u = _safeStr(url);
        if (!u || u.indexOf("?") < 0) return u;

        var hash = "";
        var hashPos = u.indexOf("#");
        if (hashPos >= 0) {
            hash = u.substring(hashPos);
            u = u.substring(0, hashPos);
        }

        var qPos = u.indexOf("?");
        var base = u.substring(0, qPos);
        var q = u.substring(qPos + 1);
        var deny = ({})
        for (var n = 0; n < names.length; ++n)
            deny[_safeStr(names[n]).toLowerCase()] = true;

        var out = [];
        var parts = q.split("&");
        for (var i = 0; i < parts.length; ++i) {
            var part = parts[i];
            if (!part) continue;
            if (deny[_queryKey(part)] === true) continue;
            out.push(part);
        }
        return base + (out.length > 0 ? ("?" + out.join("&")) : "") + hash;
    }

    function _normalizeQueryDedupe(url) {
        var u = _safeStr(url);
        if (!u || u.indexOf("?") < 0) return u;

        var hash = "";
        var hashPos = u.indexOf("#");
        if (hashPos >= 0) {
            hash = u.substring(hashPos);
            u = u.substring(0, hashPos);
        }

        var qPos = u.indexOf("?");
        var base = u.substring(0, qPos);
        var q = u.substring(qPos + 1);
        var out = [];
        var seen = ({})
        var seenAuth = false;
        var parts = q.split("&");

        for (var i = 0; i < parts.length; ++i) {
            var part = parts[i];
            if (!part) continue;
            var k = _queryKey(part);
            var isAuth = (k === "x-emby-token" || k === "x-mediabrowser-token" || k === "api_key");
            if (isAuth) {
                if (seenAuth) continue;
                seenAuth = true;
                out.push(part);
                continue;
            }
            if (seen[k] === true) continue;
            seen[k] = true;
            out.push(part);
        }
        return base + (out.length > 0 ? ("?" + out.join("&")) : "") + hash;
    }

    function _appendQueryOnce(url, key, value) {
        var u = _safeStr(url);
        var k = _safeStr(key);
        if (!u || !k || value === undefined || value === null || value === "") return u;
        if (_hasQueryParam(u, k)) return u;
        return u + (u.indexOf("?") >= 0 ? "&" : "?")
                + encodeURIComponent(k) + "=" + encodeURIComponent(value);
    }

    function _stripSizingForOverlay(url) {
        return _removeQueryParams(url, [
            "fillWidth", "fillHeight", "maxWidth", "maxHeight", "width", "height", "quality"
        ]);
    }

    function _displayImageUrl(url) {
        var u = _safeStr(url);
        if (!u) return "";
        if (publicBuildNoImageTokenInUrl || !allowImageTokenInUrl)
            u = Jellyfin.stripAuthQueryFromUrl(u);
        return u;
    }

    function _authTokenFromUrl(url) {
        var u = _safeStr(url);
        if (!u || u.indexOf("?") < 0) return "";
        var q = u.substring(u.indexOf("?") + 1);
        var hash = q.indexOf("#");
        if (hash >= 0) q = q.substring(0, hash);
        var parts = q.split("&");
        for (var i = 0; i < parts.length; ++i) {
            var part = parts[i];
            var k = _queryKey(part);
            if (k === "x-emby-token" || k === "x-mediabrowser-token" || k === "api_key" || k === "apikey" || k === "access_token" || k === "accesstoken" || k === "token") {
                var eq = part.indexOf("=");
                if (eq >= 0) {
                    try { return decodeURIComponent(part.substring(eq + 1)); }
                    catch(e) { return part.substring(eq + 1); }
                }
            }
        }
        return "";
    }


    function _imageMemoKey(url) {
        // SÉCURITÉ : la clé mémoire ne doit pas garder serverUrl/itemId en clair.
        // L'URL est d'abord nettoyée des paramètres auth, puis remplacée par un hash court.
        var clean = _stripSizingForOverlay(Jellyfin.stripAuthQueryFromUrl(_normalizeQueryDedupe(url)));
        return clean ? ("img#" + SafeLog.shortHash(clean)) : "";
    }

    function _imageProbeUrl(url) {
        var u = _stripSizingForOverlay(Jellyfin.stripAuthQueryFromUrl(_normalizeQueryDedupe(url)));
        u = _appendQueryOnce(u, "format", "jpg");
        u = _appendQueryOnce(u, "maxWidth", 16);
        u = _appendQueryOnce(u, "maxHeight", 24);
        u = _appendQueryOnce(u, "quality", 35);
        return u;
    }

    // Bornage URL Jellyfin:
    // - nettoie les paramètres dupliqués (token, quality, fill/max)
    // - fitMode === "max"  => maxWidth/maxHeight (pour PreserveAspectFit)
    // - fitMode === "fill" => fillWidth/fillHeight (pour PreserveAspectCrop)
    // capW/capH optionnels pour caps locaux (overview/person)
    function _boundedImageUrl(url, w, h, fitMode, capW, capH, qualityOverride) {
        var u = _normalizeQueryDedupe(_safeStr(url));
        if (!u) return "";

        // on ne pollue pas une URL non-Jellyfin
        if (u.indexOf("/Images/") === -1 && u.indexOf("/Items/") === -1 && u.indexOf("/Persons/") === -1) {
            return u;
        }

        // (1) caps plus agressifs par défaut
        var fallbackW = (overlayhub.posterMaxW > 0) ? overlayhub.posterMaxW : 1280;
        var fallbackH = (overlayhub.posterMaxH > 0) ? overlayhub.posterMaxH : 720;

        capW = (capW && capW > 0) ? capW : fallbackW;
        capH = (capH && capH > 0) ? capH : fallbackH;

        // clamp (évite bêtises si layout transitoire)
        w = Math.max(1, Math.min(capW, Math.round(w)));
        h = Math.max(1, Math.min(capH, Math.round(h)));

        // On retire les vieux caps/quality pour éviter quality=90&...&quality=85.
        // Le token peut rester ici pour le probe XHR, mais Image.source passe ensuite par _displayImageUrl().
        u = _stripSizingForOverlay(u);

        var q = (qualityOverride && qualityOverride > 0) ? qualityOverride : overlayhub.defaultQuality;

        // (2) PreserveAspectFit => maxWidth/maxHeight
        if (fitMode === "max") {
            u = _appendQueryOnce(u, "maxWidth", w);
            u = _appendQueryOnce(u, "maxHeight", h);
            u = _appendQueryOnce(u, "quality", q);
            return u;
        }

        // PreserveAspectCrop => fillWidth/fillHeight
        u = _appendQueryOnce(u, "fillWidth", w);
        u = _appendQueryOnce(u, "fillHeight", h);
        u = _appendQueryOnce(u, "quality", q);
        return u;
    }

    function _payloadAllowClose() {
        var p = _safeObj(effectivePayload);
        if (p.allowClose === undefined || p.allowClose === null) return true;
        return !!p.allowClose;
    }

    function _payloadOnBack() {
        var p = _safeObj(effectivePayload);
        return p.onBack;
    }

    function close() {
        if (_closing) return;
        _closing = true;
        // Laisse 1 tick pour éviter double-fire (MouseArea + Keys)
        Qt.callLater(function(){
            overlayhub.requestClose();
            overlayhub.closed();
            _closing = false;
        });
    }

    /* ===== Apply coalescé (5) ===== */
    Timer {
        id: applyTimer
        interval: 0
        repeat: false
        onTriggered: {
            _resetScrolls();
            _focusMode();
        }
    }

    function _scheduleApply() { applyTimer.restart(); }

    function _focusMode() {
        if (effectiveMode === "loading" && loadingLoader.item && loadingLoader.item.focusTarget)
            loadingLoader.item.focusTarget.forceActiveFocus();
        else if (effectiveMode === "person" && personLoader.item && personLoader.item.focusTarget)
            personLoader.item.focusTarget.forceActiveFocus();
        else if (effectiveMode === "overview" && overviewLoader.item && overviewLoader.item.focusTarget)
            overviewLoader.item.focusTarget.forceActiveFocus();
        else if (effectiveMode === "poster" && posterLoader.item && posterLoader.item.focusTarget)
            posterLoader.item.focusTarget.forceActiveFocus();
        else
            overlayhub.forceActiveFocus();
    }

    function _resetScrolls() {
        try { if (overviewLoader.item && overviewLoader.item.resetScroll) overviewLoader.item.resetScroll(); } catch(e) {}
        try { if (personLoader.item   && personLoader.item.resetScroll)   personLoader.item.resetScroll(); } catch(e) {}
    }

    onHostChanged: _scheduleApply()

    // Réagit aux changements du host (sans dépendre des bindings mode/payload)
    Connections {
        target: overlayhub.host
        ignoreUnknownSignals: true
        onOverlayModeChanged: overlayhub._scheduleApply()
        onOverlayDataChanged: overlayhub._scheduleApply()
        // Compat de host : certains hôtes peuvent exposer mode/payload.
        onModeChanged: overlayhub._scheduleApply()
        onPayloadChanged: overlayhub._scheduleApply()
    }

    /* ===== Fond assombri (pas utilisé pour loading) ===== */
    Rectangle {
        id: scrim
        anchors.fill: parent
        color: "#000000"
        opacity: (effectiveMode !== "none" && effectiveMode !== "loading") ? 0.72 : 0
        visible: (effectiveMode !== "none" && effectiveMode !== "loading")
        z: 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        MouseArea {
            anchors.fill: parent
            onClicked: {
                // click-to-close désactivé en loading
                if (overlayhub.effectiveMode !== "loading") overlayhub.close();
            }
        }
    }

    /* ===== Trap clavier global ===== */
    Keys.onPressed: {
        if (effectiveMode === "none") { event.accepted = false; return; }

        // Mode loading: on bloque tout, et Back/Escape appelle payload.onBack() si fourni
        if (effectiveMode === "loading") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                var cb = _payloadOnBack();
                if (cb && typeof cb === "function") cb();
                else if (_payloadAllowClose()) overlayhub.close();
                event.accepted = true;
                return;
            }
            // Tout le reste est avalé (comme ton loadingOverlay)
            event.accepted = true;
            return;
        }

        // Modes classiques
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            overlayhub.close(); event.accepted = true; return;
        }
        // Enter/Return ferme seulement en mode poster
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && effectiveMode === "poster") {
            overlayhub.close(); event.accepted = true; return;
        }
        event.accepted = false;
    }

    /* ===================== LOADER PAR MODE (RAM ↓) ===================== */
    Loader {
        id: loadingLoader
        anchors.fill: parent
        z: 2
        active: effectiveMode === "loading"
        sourceComponent: loadingComponent
    }

    Loader {
        id: posterLoader
        anchors.fill: parent
        z: 1
        active: effectiveMode === "poster"
        sourceComponent: posterComponent
    }

    Loader {
        id: overviewLoader
        anchors.fill: parent
        z: 1
        active: effectiveMode === "overview"
        sourceComponent: overviewComponent
    }

    Loader {
        id: personLoader
        anchors.fill: parent
        z: 1
        active: effectiveMode === "person"
        sourceComponent: personComponent
    }

    /* ===================== MODE: LOADING (Tweak 2) ===================== */
    Component {
        id: loadingComponent

        FocusScope {
            id: loadingOverlay
            anchors.fill: parent
            focus: true

            property Item focusTarget: loadingOverlay

            // Dots sans Timer (animation QML)
            property real dotsPhase: 0
            NumberAnimation on dotsPhase {
                from: 0; to: 4
                duration: 1000
                loops: Animation.Infinite
                running: true
                easing.type: Easing.Linear
            }
            function dots() {
                return (dotsPhase < 1) ? "" : (dotsPhase < 2) ? "." : (dotsPhase < 3) ? ".." : "...";
            }

            Rectangle { anchors.fill: parent; color: "#000000" }

            // ✅ FIX: spinner + texte dans le MÊME bloc centré (plus de spinner qui “reste en haut”)
            Column {
                id: loadingCol
                anchors.centerIn: parent
                width: Math.min(parent.width * 0.82, 620)
                spacing: 16

                // Spinner cercle de points (sans Timer)
                Item {
                    id: circle
                    width: 84
                    height: 84
                    anchors.horizontalCenter: parent.horizontalCenter

                    property int dotCount: 12
                    property real radius: width * 0.38
                    property real dotSize: 6
                    property int cycleMs: 900
                    property real phase: 0.0

                    NumberAnimation on phase {
                        from: 0.0
                        to: 1.0
                        duration: circle.cycleMs
                        loops: Animation.Infinite
                        easing.type: Easing.Linear
                        running: true
                    }

                    function dotOpacity(i, ph) {
                        var t = ph - (i / dotCount);
                        t = t - Math.floor(t);
                        var tail = 3.4;
                        var a = Math.max(0.0, 1.0 - t * tail);
                        a = a * a * (1.15 - 0.15 * a);
                        return 0.10 + 0.90 * a;
                    }

                    Repeater {
                        model: circle.dotCount
                        delegate: Rectangle {
                            width: circle.dotSize
                            height: circle.dotSize
                            radius: width / 2
                            color: "#E7ECFF"
                            antialiasing: true
                            x: circle.width / 2 + circle.radius * Math.cos(2 * Math.PI * index / circle.dotCount) - width / 2
                            y: circle.height / 2 + circle.radius * Math.sin(2 * Math.PI * index / circle.dotCount) - height / 2
                            opacity: circle.dotOpacity(index, circle.phase)
                        }
                    }
                }

                Text { textFormat: Text.PlainText;
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: {
                        var p = overlayhub._safeObj(overlayhub.effectivePayload);
                        var t = overlayhub._safeStr(p.title);
                        if (!t) t = "Chargement";
                        return t + loadingOverlay.dots();
                    }
                    color: "#E7ECFF"
                    font.pixelSize: 20
                    opacity: 0.95
                }

                Text { textFormat: Text.PlainText;
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: {
                        var p2 = overlayhub._safeObj(overlayhub.effectivePayload);
                        return overlayhub._safeStr(p2.errorText);
                    }
                    color: "#ffdfdf"
                    font.pixelSize: 16
                    opacity: (text && text.length) ? 0.95 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }
            }

            // Bloque le clic (pas de close au clic)
            MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }
        }
    }

    /* ===================== MODE: POSTER ===================== */
    Component {
        id: posterComponent

        Item {
            id: posterOverlay
            anchors.fill: parent
            focus: true

            // focus target exposé au hub
            property Item focusTarget: posterOverlay

            // (4) arm 2 ticks: stage 1 (layout), stage 2 (images)
            property int armStage: 0
            Timer {
                id: armPoster
                interval: 0
                running: true
                repeat: false
                onTriggered: {
                    Qt.callLater(function(){
                        posterOverlay.armStage = 1;
                        Qt.callLater(function(){ posterOverlay.armStage = 2; });
                    });
                }
            }

            // bornage overlay (évite plein écran)
            readonly property int maxW: (overlayhub.posterMaxW > 0) ? overlayhub.posterMaxW : 1280
            readonly property int maxH: (overlayhub.posterMaxH > 0) ? overlayhub.posterMaxH : 720

            Item {
                id: posterBox
                anchors.centerIn: parent
                width: Math.round(Math.min(parent.width * 0.86, parent.width - 48, posterOverlay.maxW))
                height: Math.round(Math.min(parent.height * 0.86, parent.height - 48, posterOverlay.maxH))

                Image {
                    id: posterImg
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    mipmap: false
                    cache: false

                    source: {
                        if (posterOverlay.armStage < 2) return "";
                        var u = (overlayhub.effectivePayload && overlayhub.effectivePayload.posterUrl)
                                ? overlayhub._safeStr(overlayhub.effectivePayload.posterUrl) : "";
                        // (2) Fit => maxWidth/maxHeight
                        var bounded = overlayhub._boundedImageUrl(u, posterBox.width, posterBox.height, "max",
                                                                  posterOverlay.maxW, posterOverlay.maxH);
                        return overlayhub._displayImageUrl(bounded);
                    }
                    visible: source !== ""
                }
            }
        }
    }

    /* ===================== MODE: OVERVIEW ===================== */
    Component {
        id: overviewComponent

        Item {
            id: overviewOverlay
            anchors.fill: parent
            focus: true
            property Item focusTarget: overviewStyleLoader.item && overviewStyleLoader.item.focusTarget
                                       ? overviewStyleLoader.item.focusTarget : null

            function resetScroll() {
                try {
                    if (overviewStyleLoader.item && overviewStyleLoader.item.resetScroll)
                        overviewStyleLoader.item.resetScroll();
                } catch(e) {}
            }

            Loader {
                id: overviewStyleLoader
                anchors.fill: parent
                sourceComponent: episodeOverviewComponent
                onLoaded: Qt.callLater(function(){
                    if (overviewStyleLoader.item && overviewStyleLoader.item.focusTarget)
                        overviewStyleLoader.item.focusTarget.forceActiveFocus();
                })
            }

            /* Reader premium partagé : épisode, film, série et collection. */
            Component {
                id: episodeOverviewComponent

                FocusScope {
                    id: episodeReader
                    anchors.fill: parent
                    focus: true

                    property Item focusTarget: episodeOverviewFlick
                    readonly property var episodePayload: overlayhub.effectivePayload || ({})
                    readonly property real maxScrollY: Math.max(0, episodeOverviewFlick.contentHeight - episodeOverviewFlick.height)
                    readonly property bool canScroll: maxScrollY > 2
                    property int armStage: 0

                    function resetScroll() { episodeOverviewFlick.contentY = 0; }
                    function scrollBy(delta) {
                        if (!canScroll) return;
                        episodeOverviewFlick.contentY = Math.max(0, Math.min(maxScrollY,
                            episodeOverviewFlick.contentY + Number(delta || 0)));
                    }

                    Timer {
                        interval: 0
                        running: true
                        repeat: false
                        onTriggered: Qt.callLater(function(){
                            episodeReader.armStage = 1;
                            Qt.callLater(function(){ episodeReader.armStage = 2; });
                        })
                    }

                    Rectangle {
                        id: episodeReaderCard
                        width: Math.min(parent.width - 112, 1088)
                        height: Math.min(parent.height - 92, 572)
                        anchors.centerIn: parent
                        radius: 22
                        color: "#111722"
                        border.width: 1
                        border.color: "#2AFFFFFF"
                        clip: true
                        opacity: 0.0
                        scale: 0.97

                        NumberAnimation on opacity {
                            from: 0.0; to: 1.0; duration: 150; easing.type: Easing.OutCubic
                        }
                        NumberAnimation on scale {
                            from: 0.97; to: 1.0; duration: 170; easing.type: Easing.OutCubic
                        }

                        MouseArea { anchors.fill: parent; onClicked: mouse.accepted = true }

                        Item {
                            id: episodeReaderHeader
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.leftMargin: 34
                            anchors.rightMargin: 34
                            anchors.topMargin: 26
                            height: 82

                            Text { textFormat: Text.PlainText;
                                id: episodeReaderTitle
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                text: episodeReader.armStage >= 1 ? overlayhub._safeStr(episodeReader.episodePayload.title || "Résumé") : ""
                                color: "#FFFFFF"
                                font.pixelSize: 34
                                font.bold: true
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            Text { textFormat: Text.PlainText;
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: episodeReaderTitle.bottom
                                anchors.topMargin: 8
                                text: episodeReader.armStage >= 1 ? overlayhub._safeStr(episodeReader.episodePayload.meta) : ""
                                color: "#AEB6C7"
                                font.pixelSize: 18
                                font.bold: true
                                elide: Text.ElideRight
                                visible: text.length > 0
                            }
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: episodeReaderHeader.bottom
                            anchors.leftMargin: 34
                            anchors.rightMargin: 34
                            height: 1
                            color: "#18FFFFFF"
                        }

                        Item {
                            id: episodeReaderBody
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: episodeReaderHeader.bottom
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: 34
                            anchors.rightMargin: 34
                            anchors.topMargin: 24
                            anchors.bottomMargin: 28

                            Rectangle {
                                id: episodeVisualFrame
                                width: Math.min(430, Math.round(episodeReaderBody.width * 0.43))
                                height: Math.round(width * 9 / 16)
                                anchors.left: parent.left
                                anchors.top: parent.top
                                radius: 15
                                color: "#1A2130"
                                border.width: 1
                                border.color: "#25FFFFFF"

                                Image {
                                    id: episodeOverviewImage
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: false
                                    smooth: false
                                    mipmap: false
                                    source: {
                                        if (episodeReader.armStage < 2) return "";
                                        var u = episodeReader.episodePayload.posterUrl ? overlayhub._safeStr(episodeReader.episodePayload.posterUrl) : "";
                                        var bounded = overlayhub._boundedImageUrl(u, episodeVisualFrame.width, episodeVisualFrame.height,
                                                                                  "fill", 720, 405, 88);
                                        return overlayhub._displayImageUrl(bounded);
                                    }
                                    visible: source !== ""
                                }

                                Text { textFormat: Text.PlainText;
                                    anchors.centerIn: parent
                                    text: "Aucune image"
                                    color: "#778093"
                                    font.pixelSize: 18
                                    visible: episodeOverviewImage.source === ""
                                }
                            }

                            Rectangle {
                                id: episodeReaderDivider
                                width: 1
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.left: episodeVisualFrame.right
                                anchors.leftMargin: 28
                                color: "#18FFFFFF"
                            }

                            Item {
                                id: episodeReaderTextColumn
                                anchors.left: episodeReaderDivider.right
                                anchors.leftMargin: 28
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom

                                Text { textFormat: Text.PlainText;
                                    id: episodeReaderLabel
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    text: "RÉSUMÉ"
                                    color: "#FFFFFF"
                                    opacity: 0.86
                                    font.pixelSize: 15
                                    font.bold: true
                                    font.letterSpacing: 1.2
                                }

                                Flickable {
                                    id: episodeOverviewFlick
                                    anchors.left: parent.left
                                    anchors.right: episodeScrollTrack.left
                                    anchors.rightMargin: 14
                                    anchors.top: episodeReaderLabel.bottom
                                    anchors.topMargin: 14
                                    anchors.bottom: parent.bottom
                                    clip: true
                                    focus: true
                                    interactive: contentHeight > height + 1
                                    boundsBehavior: Flickable.StopAtBounds
                                    contentWidth: width
                                    contentHeight: episodeReader.armStage >= 1
                                                   ? Math.max(height, episodeOverviewText.paintedHeight) : height

                                    Behavior on contentY {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                    }

                                    Text { textFormat: Text.PlainText;
                                        id: episodeOverviewText
                                        width: episodeOverviewFlick.width
                                        text: episodeReader.armStage >= 1 ? overlayhub._safeStr(episodeReader.episodePayload.overview) : ""
                                        color: "#D0D5E0"
                                        font.pixelSize: 22
                                        wrapMode: Text.WordWrap
                                        lineHeightMode: Text.ProportionalHeight
                                        lineHeight: 1.32
                                    }

                                    Keys.onPressed: {
                                        var step = Math.max(72, Math.round(height * 0.22));
                                        if (event.key === Qt.Key_Down) {
                                            episodeReader.scrollBy(step); event.accepted = true;
                                        } else if (event.key === Qt.Key_Up) {
                                            episodeReader.scrollBy(-step); event.accepted = true;
                                        } else if (event.key === Qt.Key_PageDown) {
                                            episodeReader.scrollBy(Math.round(height * 0.82)); event.accepted = true;
                                        } else if (event.key === Qt.Key_PageUp) {
                                            episodeReader.scrollBy(-Math.round(height * 0.82)); event.accepted = true;
                                        } else event.accepted = false;
                                    }
                                }

                                Rectangle {
                                    id: episodeScrollTrack
                                    anchors.top: episodeOverviewFlick.top
                                    anchors.bottom: episodeOverviewFlick.bottom
                                    anchors.right: parent.right
                                    width: 3
                                    radius: 2
                                    color: "#18FFFFFF"
                                    visible: episodeReader.canScroll

                                    Rectangle {
                                        width: parent.width
                                        radius: 2
                                        color: "#8FFFFFFF"
                                        height: Math.max(34, parent.height * Math.min(1.0,
                                            episodeOverviewFlick.height / Math.max(1, episodeOverviewFlick.contentHeight)))
                                        y: episodeReader.maxScrollY > 0
                                           ? (parent.height - height) * (episodeOverviewFlick.contentY / episodeReader.maxScrollY) : 0
                                    }
                                }

                                Rectangle {
                                    anchors.left: episodeOverviewFlick.left
                                    anchors.right: episodeOverviewFlick.right
                                    anchors.top: episodeOverviewFlick.top
                                    height: 32
                                    visible: episodeReader.canScroll && episodeOverviewFlick.contentY > 2
                                    gradient: Gradient {
                                        orientation: Gradient.Vertical
                                        GradientStop { position: 0.0; color: "#FF111722" }
                                        GradientStop { position: 1.0; color: "#00111722" }
                                    }
                                }

                                Rectangle {
                                    anchors.left: episodeOverviewFlick.left
                                    anchors.right: episodeOverviewFlick.right
                                    anchors.bottom: episodeOverviewFlick.bottom
                                    height: 44
                                    visible: episodeReader.canScroll && episodeOverviewFlick.contentY < (episodeReader.maxScrollY - 2)
                                    gradient: Gradient {
                                        orientation: Gradient.Vertical
                                        GradientStop { position: 0.0; color: "#00111722" }
                                        GradientStop { position: 1.0; color: "#FF111722" }
                                    }
                                }
                            }
                        }

                    }
                }
            }
        }
    }

    /* ===================== MODE: PERSON ===================== */
    Component {
        id: personComponent

        Item {
            id: personOverlay
            anchors.fill: parent
            focus: true

            property Item focusTarget: bioFlick
            function resetScroll() { bioFlick.contentY = 0; }

            // (4) arm 2 ticks: stage 1 (texte/layout), stage 2 (images)
            property int armStage: 0
            Timer {
                id: armPerson
                interval: 0
                running: true
                repeat: false
                onTriggered: {
                    Qt.callLater(function(){
                        personOverlay.armStage = 1;
                        Qt.callLater(function(){ personOverlay.armStage = 2; });
                    });
                }
            }

            property int _photoSeq: 0
            property string _photoWantedUrl: ""
            property string _photoSourceUrl: ""
            property bool _photoFailed: false

            function _wantedPhotoUrl() {
                if (personOverlay.armStage < 2) return "";
                var u = (overlayhub.effectivePayload && overlayhub.effectivePayload.photoUrl)
                        ? overlayhub._safeStr(overlayhub.effectivePayload.photoUrl) : "";
                return overlayhub._boundedImageUrl(u, photoWrap.width, photoWrap.height, "fill",
                                                   photoWrap.capW, photoWrap.capH);
            }

            function _refreshPhotoSource() {
                if (personOverlay.armStage < 2) return;

                var wanted = _wantedPhotoUrl();
                if (wanted === personOverlay._photoWantedUrl &&
                        (personOverlay._photoSourceUrl !== "" || personOverlay._photoFailed))
                    return;

                personOverlay._photoWantedUrl = wanted;
                personOverlay._photoSourceUrl = "";
                personOverlay._photoFailed = false;

                if (!wanted) {
                    personOverlay._photoFailed = true;
                    return;
                }

                var key = overlayhub._imageMemoKey(wanted);
                if (overlayhub._imageFailureMemo && overlayhub._imageFailureMemo[key] === true) {
                    personOverlay._photoFailed = true;
                    return;
                }
                if (overlayhub._imageReadyMemo && overlayhub._imageReadyMemo[key] === true) {
                    personOverlay._photoSourceUrl = overlayhub._displayImageUrl(wanted);
                    return;
                }

                var seq = ++personOverlay._photoSeq;
                var probeUrl = overlayhub._imageProbeUrl(wanted);
                var token = overlayhub._authTokenFromUrl(wanted);

                if (!Jellyfin || typeof Jellyfin.probeResource !== "function") {
                    overlayhub._rememberImageFailure(key);
                    personOverlay._photoFailed = true;
                    return;
                }

                Jellyfin.probeResource(probeUrl, token,
                    { accept: "image/*", metadataOnly: true, timeoutMs: 7000 },
                    function() {
                        if (seq !== personOverlay._photoSeq) return;
                        overlayhub._rememberImageReady(key);
                        personOverlay._photoFailed = false;
                        personOverlay._photoSourceUrl = overlayhub._displayImageUrl(wanted);
                    },
                    function() {
                        if (seq !== personOverlay._photoSeq) return;
                        overlayhub._rememberImageFailure(key);
                        personOverlay._photoSourceUrl = "";
                        personOverlay._photoFailed = true;
                    }
                );
            }

            onArmStageChanged: { if (armStage >= 2) _refreshPhotoSource(); }

            Connections {
                target: overlayhub
                ignoreUnknownSignals: true
                onEffectivePayloadChanged: personOverlay._refreshPhotoSource()
            }

            Rectangle { anchors.fill: parent; color: "#0e1330"; opacity: 0.92 }

            Rectangle {
                id: personCard
                anchors.centerIn: parent
                width: Math.min(parent.width * 0.86, 1000)
                height: Math.min(parent.height * 0.86, 640)
                radius: 18
                color: "#141a38"
                border.color: "#2a356d"
                border.width: 1
                clip: false

                Row {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 20

                    Rectangle {
                        id: photoWrap
                        width: 300
                        height: parent.height
                        radius: 12
                        color: "#0b1130"
                        clip: true

                        // (1) caps locaux person
                        readonly property int capW: 480
                        readonly property int capH: 720

                        onWidthChanged: personOverlay._refreshPhotoSource()
                        onHeightChanged: personOverlay._refreshPhotoSource()

                        Image {
                            id: photoImg
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            smooth: true
                            mipmap: false
                            cache: false

                            source: personOverlay._photoSourceUrl
                            visible: source !== "" && status !== Image.Error

                            onStatusChanged: {
                                if (status === Image.Error) {
                                    var key = overlayhub._imageMemoKey(personOverlay._photoWantedUrl);
                                    if (key) overlayhub._rememberImageFailure(key);
                                    personOverlay._photoSourceUrl = "";
                                    personOverlay._photoFailed = true;
                                }
                            }
                        }

                        // fallback visuel si pas de photo
                        Item {
                            anchors.fill: parent
                            visible: !photoImg.visible

                            Rectangle {
                                width: parent.width * 0.42
                                height: width
                                radius: width/2
                                color: "#9aa3bd"
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: parent.height * 0.18
                            }
                            Rectangle {
                                width: parent.width * 0.70
                                height: parent.height * 0.42
                                radius: Math.min(width, height) * 0.22
                                color: "#7d86a4"
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: parent.height * 0.18 + (parent.width * 0.42) + 8
                            }
                        }
                    }

                    Item {
                        width: parent.width - photoWrap.width - 20
                        height: parent.height

                        Column {
                            anchors.fill: parent
                            spacing: 8

                            Text { textFormat: Text.PlainText;
                                text: (overlayhub.effectivePayload && overlayhub.effectivePayload.name)
                                      ? overlayhub._safeStr(overlayhub.effectivePayload.name) : ""
                                color: "#f2f4ff"
                                font.pixelSize: 26
                                font.bold: true
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }

                            Text { textFormat: Text.PlainText;
                                text: (overlayhub.effectivePayload && overlayhub.effectivePayload.role)
                                      ? overlayhub._safeStr(overlayhub.effectivePayload.role) : ""
                                color: "#b3bce0"
                                font.pixelSize: 18
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }

                            Text { textFormat: Text.PlainText;
                                color: "#ccd5ff"
                                font.pixelSize: 16
                                wrapMode: Text.WordWrap
                                text: {
                                    var p = overlayhub._safeObj(overlayhub.effectivePayload);
                                    var birth = overlayhub._safeStr(p.birthDate);
                                    var death = overlayhub._safeStr(p.deathDate);
                                    var pob   = overlayhub._safeStr(p.placeOfBirth);

                                    var s = "";
                                    if (birth) {
                                        var d = MediaCatalog.personDateShortFr ? MediaCatalog.personDateShortFr(birth) : birth;
                                        var ageValue = MediaCatalog.personAgeFromDates ? MediaCatalog.personAgeFromDates(birth, death) : -1;
                                        var age = ageValue >= 0 ? String(ageValue) : "";
                                        s = "Né·e : " + d + (age ? (" (" + age + " ans)") : "");
                                    }
                                    if (pob) s += (s ? " — " : "") + pob;
                                    return s;
                                }
                            }

                            Item {
                                width: parent.width
                                height: Math.max(1, parent.height - 160)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 12
                                    color: "#0f1533"
                                    border.color: "#2a356d"
                                    border.width: 1
                                    clip: true

                                    Flickable {
                                        id: bioFlick
                                        anchors.fill: parent
                                        anchors.margins: 12
                                        focus: true
                                        clip: true
                                        contentWidth: Math.max(1, width)

                                        // (5) gate texte lourd
                                        contentHeight: (personOverlay.armStage >= 1) ? bioText.paintedHeight : 1
                                        interactive: contentHeight > height + 1
                                        boundsBehavior: Flickable.StopAtBounds

                                        Text {
                                            id: bioText
                                            width: bioFlick.width
                                            text: {
                                                if (personOverlay.armStage < 1) return "";
                                                return (overlayhub.effectivePayload && overlayhub.effectivePayload.overview)
                                                        ? overlayhub._safeStr(overlayhub.effectivePayload.overview) : "—";
                                            }
                                            color: "#e6e9ff"
                                            font.pixelSize: 18
                                            wrapMode: Text.WordWrap
                                            textFormat: Text.PlainText
                                        }

                                        Keys.onPressed: {
                                            if (!interactive) { event.accepted = false; return; }
                                            var step = Math.max(40, Math.round(height * 0.18));
                                            if (event.key === Qt.Key_Down) {
                                                contentY = Math.min(contentHeight - height, contentY + step); event.accepted = true;
                                            } else if (event.key === Qt.Key_Up) {
                                                contentY = Math.max(0, contentY - step); event.accepted = true;
                                            } else if (event.key === Qt.Key_PageDown) {
                                                contentY = Math.min(contentHeight - height, contentY + Math.round(height * 0.9)); event.accepted = true;
                                            } else if (event.key === Qt.Key_PageUp) {
                                                contentY = Math.max(0, contentY - Math.round(height * 0.9)); event.accepted = true;
                                            } else {
                                                event.accepted = false;
                                            }
                                        }
                                    }

                                    // mini-scrollbar (affichée seulement si scroll)
                                    Rectangle {
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        anchors.rightMargin: 4
                                        width: 4
                                        radius: 2
                                        color: "#2a356d"
                                        opacity: (bioFlick.contentHeight > bioFlick.height + 1) ? 0.5 : 0.0
                                        visible: opacity > 0.01

                                        Rectangle {
                                            width: parent.width
                                            radius: 2
                                            color: "#6e7bf4"
                                            height: Math.max(16, parent.height * bioFlick.height / Math.max(1, bioFlick.contentHeight))
                                            y: (bioFlick.contentY / Math.max(1, bioFlick.contentHeight - bioFlick.height)) * (parent.height - height)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
