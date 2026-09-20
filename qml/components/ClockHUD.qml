// qml/components/ClockHUD.qml
// QtQuick 2.15 — ClockLite minute + Avatar rond (OpacityMask) + focus
// FIX loop Freebox: watchdog + restart local playing/frame, sans reload réseau périodique
// Loop UNIQUEMENT quand visible dans le viewport (via flick) + stop pendant scroll
// + Fade progressif du HUD au scroll (opacity basée sur flick.contentY)
// + Nom du profil sous l’avatar (centralisé dans le composant)
//
// TWEAK 1: suppression du viewportPoll (timer de polling) -> uniquement events Flickable
// TWEAK 2: gate animation sur opacité (hud.opacity > threshold) -> pas de decode GIF quand HUD quasi invisible

import QtQuick 2.15
import QtGraphicalEffects 1.15
import "../components" as Components
import "../js/UserStore.js" as Store
import "../js/jellyfinBridge.js" as Jellyfin

Item {
    id: hud

    // ===== compat =====
    property real hudOpacity: 1.0
    property bool scrolling: false           // peut être piloté par la page
    property bool clockEnabled: true

    property string userName: ""

    // ===== nom du profil sous l'avatar =====
    property bool  showUserName: true
    // Fallback avatar: ne pas dessiner l'initiale au centre du rond.
    // Le nom reste affiché sous l'avatar via userNameLabel.
    property bool  showFallbackInitial: false
    property int   userNameFontPx: 12
    property color userNameColor: "#e9ecff"
    property int   userNameMaxWidth: 96
    property int   userNameTopMargin: 4

    property var host: null
    property var flick: null

    // ===== ctx =====
    property var    fbx: null
    property var    shared: null
    property string serverUrl: ""
    property string userId: ""
    property string userImageTag: ""

    // ===== style =====
    property int  fontPx: 22
    property bool active: true

    // ===== avatar =====
    property bool   showAvatar: false
    property bool   avatarInteractive: false
    property bool   avatarFocus: false

    property string avatarAction: "login"
    property string loginPageQml: "LoginPage.qml"

    property string avatarUrl: ""
    property int    avatarSize: 46

    // compat legacy (acceptés)

    // style moviepage
    property real   avatarFocusScale: 1.08
    property int    avatarFocusRingWidth: 2
    property color  avatarFocusRingColor: "#FFFFFF"
    property int    avatarFocusRingInset: 0

    // loop policy
    property bool   avatarForceLoop: true
    // Qt 5.15 : une AnimatedImage lue depuis un flux réseau séquentiel ne peut
    // boucler correctement que si son cache est actif. On garde donc la source
    // chargée et on borne le décodage à la petite taille réellement affichée.
    property bool   avatarAnimateAlways: true
    property bool   avatarAnimateDuringScroll: false
    property bool   avatarLoopOnlyWhenVisible: true

    // Watchdog uniquement de récupération d'un vrai stall firmware. Il ne
    // pilote plus chaque fin normale du GIF.
    property int    avatarLoopCheckMs: 520
    property int    avatarRecoveryPauseMsRevo: 45
    property int    avatarRecoveryPauseMsDevi: 28

    // ===== Fade au scroll (HUD entier) =====
    property bool fadeWithScroll: true
    property int  fadeOutPx: 140          // 0->140px: 1->0
    property real fadeMinOpacity: 0.0

    // TWEAK 2: si HUD quasi invisible, pas d’animation GIF
    property real animateOpacityThreshold: 0.08

    readonly property real _scrollFade: {
        if (!fadeWithScroll || !flick) return 1.0
        var y = flick.contentY || 0
        var d = Math.max(1, fadeOutPx)
        var t = y / d
        if (t < 0) t = 0
        if (t > 1) t = 1
        // easeOutCubic
        t = 1 - Math.pow(1 - t, 3)
        var f = 1 - t
        if (f < fadeMinOpacity) f = fadeMinOpacity
        return f
    }

    signal avatarActivated()
    signal requestFocusBelow()
    // ✅ NEW: demandé par HomePage (ou toute page avec un bouton “settings” à gauche)
    signal requestFocusSettings()

    function _appShowClock() {
        try {
            if (Components.AppSettings && Components.AppSettings.showClock !== undefined)
                return !!Components.AppSettings.showClock
        } catch (e) {}
        return true
    }
    readonly property bool _clockOn: !!(clockEnabled && _appShowClock())

    // NOTE: visible ne dépend PAS du scroll (sinon pop instant)
    visible: !!(active && (_clockOn || showAvatar))
    opacity: hudOpacity * _scrollFade

    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    // scrolling effectif (si la page ne le fournit pas, on essaye de le déduire)
    readonly property bool _scrollingEff: !!(
        scrolling || (flick && ((flick.moving === true) || (flick.dragging === true)))
    )

    function _syncCtx() {
        try {
            if (!Components.AppSettings) return
            // Sécurité : contexte local minimal pour retrouver le serveur/profil courant.
            // Ne jamais logger serverUrl/userId ici, AppSettings doit rester silencieux.
            Components.AppSettings.setContext(serverUrl, userId)
        } catch (e) {}
    }

    function _emitNavigation(url) {
        try {
            if (host && typeof host.requestNavigation === "function") { host.requestNavigation(url); return true }
        } catch (e1) {}
        var p = hud.parent
        while (p) {
            try { if (typeof p.requestNavigation === "function") { p.requestNavigation(url); return true } }
            catch (e2) {}
            p = p.parent
        }
        return false
    }

    function _storeServerNavContext() {
        try {
            var api = shared && shared.__redefinNavApi ? shared.__redefinNavApi : null
            return api && api.storeValues ? api.storeValues({
                serverUrl: serverUrl || "",
                userName: userName || "",
                userImageTag: userImageTag || "",
                fbx: fbx || null
            }) : false
        } catch(e) { return false }
    }

    function _loginRouteForCurrentServer() {
        if (_storeServerNavContext())
            return loginPageQml + "?ctx=1"

        // Fallback volontairement sans serverUrl en query string.
        return loginPageQml
    }

    function _openLoginRoot() {
        if (!serverUrl || !serverUrl.length) return false
        return _emitNavigation(_loginRouteForCurrentServer())
    }

    function _avatarParamKey(part) {
        var p = String(part || "")
        var eq = p.indexOf("=")
        var k = (eq >= 0) ? p.slice(0, eq) : p
        try { k = decodeURIComponent(k) } catch (e) {}
        return String(k || "").toLowerCase()
    }
    function _avatarRemoveParams(u, names) {
        u = String(u || "")
        if (!u.length) return ""
        var q = u.indexOf("?")
        if (q < 0) return u

        var base = u.slice(0, q)
        var parts = u.slice(q + 1).split("&")
        var blocked = {}
        for (var i = 0; i < names.length; ++i)
            blocked[String(names[i]).toLowerCase()] = true

        var out = []
        for (var j = 0; j < parts.length; ++j) {
            var part = parts[j]
            if (!part || !part.length) continue
            if (blocked[_avatarParamKey(part)]) continue
            out.push(part)
        }
        return base + (out.length ? ("?" + out.join("&")) : "")
    }
    function _avatarStableUrl(raw) {
        // URL canonique avatar animé: on supprime les tokens et variantes statiques,
        // mais on ne force jamais format=jpg/fillWidth/fillHeight afin de préserver
        // les GIF animés Jellyfin avec leur boucle native.
        var u = Jellyfin.stripAuthQueryFromUrl(raw)
        u = _avatarRemoveParams(u, [
            "fbx" + "loop", "format", "fillwidth", "fillheight",
            "maxwidth", "maxheight", "quality", "_v"
        ])
        return u
    }

    readonly property string _autoAvatarUrl: Store.animatedAvatarUrl(serverUrl, userId, userImageTag)
    readonly property string effectiveAvatarUrl: _avatarStableUrl((avatarUrl && avatarUrl.length) ? avatarUrl : _autoAvatarUrl)

    // ===== ClockLite minute =====
    property string _last: ""
    function _fmtNow() { return Qt.formatTime(new Date(), "hh:mm") }

    function updateClock(force) {
        if (!_clockOn) return
        var s = _fmtNow()
        if (force || s !== _last) { _last = s; timeText.text = s }
    }
    function msToNextMinute() {
        var d = new Date()
        var ms = (60 - d.getSeconds()) * 1000 - d.getMilliseconds() + 10
        if (ms < 50) ms = 50
        if (ms > 60000) ms = 60000
        return ms
    }
    function _stopTimers() { alignTimer.stop(); minuteTickTimer.stop() }
    function _restartTimers() {
        _stopTimers()
        if (!hud.visible || !_clockOn) return
        updateClock(true)
        alignTimer.interval = msToNextMinute()
        alignTimer.start()
    }

    function focusAvatar() {
        if (avatarWrap.visible && avatarWrap.enabled) { avatarWrap.forceActiveFocus(); return true }
        return false
    }

    Component.onCompleted: { _syncCtx(); _restartTimers() }
    onFbxChanged: _syncCtx()
    onServerUrlChanged: _syncCtx()
    onUserIdChanged: _syncCtx()
    onActiveChanged: { if (active) _restartTimers(); else _stopTimers() }
    onClockEnabledChanged: _restartTimers()
    onVisibleChanged: { if (visible) _restartTimers(); else _stopTimers() }

    Connections {
        target: Components.AppSettings
        ignoreUnknownSignals: true
        function onShowClockChanged() { hud._restartTimers() }
    }

    Row {
        id: row
        spacing: 10
        anchors.verticalCenter: parent.verticalCenter

        Column {
            id: avatarColumn
            visible: !!hud.showAvatar
            spacing: hud.userNameTopMargin
            width: Math.max(hud.avatarSize,
                            userNameLabel.visible
                                ? Math.min(hud.userNameMaxWidth,
                                           Math.max(hud.avatarSize, Math.ceil(userNameLabel.implicitWidth)))
                                : hud.avatarSize)

            FocusScope {
                id: avatarWrap
                width: hud.avatarSize
                height: hud.avatarSize
                visible: !!hud.showAvatar
                enabled: !!(hud.active && hud.showAvatar)
                focus: !!(hud.avatarFocus && enabled)

                transformOrigin: Item.Center
                scale: activeFocus ? hud.avatarFocusScale : 1.0
                Behavior on scale {
                    enabled: !!(hud.active && hud.visible && !hud._scrollingEff)
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }

                readonly property bool isDevialet: {
                    try {
                        var m = ""
                        if (hud.fbx && hud.fbx.deviceModel !== undefined) m = String(hud.fbx.deviceModel)
                        else if (hud.fbx && hud.fbx.model !== undefined) m = String(hud.fbx.model)
                        m = m.toLowerCase()
                        return (m.indexOf("delta") >= 0) || (m.indexOf("devialet") >= 0) || (m.indexOf("fbx7") >= 0)
                    } catch (e) {}
                    return false
                }

                // ===== viewport gate (sans polling) =====
                property bool avatarInViewport: true
                function _computeInViewport() {
                    if (!hud.avatarLoopOnlyWhenVisible) return true
                    if (!hud.flick) return true
                    try {
                        var p = avatarWrap.mapToItem(hud.flick, 0, 0)
                        var y = p.y
                        var h = avatarWrap.height
                        var fh = hud.flick.height
                        return ((y + h) > 0) && (y < fh)
                    } catch (e) {}
                    return true
                }
                function _updateViewport() {
                    var v = _computeInViewport()
                    if (v === avatarInViewport) return
                    avatarInViewport = v
                    if (v) _restartGif()
                }

                // TWEAK 1: plus de Timer viewportPoll -> uniquement signaux Flickable
                Connections {
                    target: hud.flick
                    ignoreUnknownSignals: true
                    function onContentYChanged() { avatarWrap._updateViewport() }
                    function onHeightChanged()   { avatarWrap._updateViewport() }
                }
                Connections {
                    target: hud
                    ignoreUnknownSignals: true
                    function onFlickChanged() { avatarWrap._updateViewport() }
                }
                Component.onCompleted: { _updateViewport(); _startAvatarProbe() }
                Component.onDestruction: { _probeAlive = false; _probeSeq += 1; try { recoveryResumeTimer.stop() } catch (e) {} }

                // ===== URL avatar stable =====
                readonly property int reqAva: 70
                readonly property string baseUrl: hud.effectiveAvatarUrl

                property bool _probeAlive: true
                property int  _probeSeq: 0
                property bool _probePending: false
                property bool avatarStaticReady: false
                property bool avatarGifReady: false

                function _hasQueryParam(u, key) {
                    u = String(u || "")
                    key = String(key || "").toLowerCase()
                    var q = u.indexOf("?")
                    if (q < 0) return false
                    var parts = u.slice(q + 1).split("&")
                    for (var i = 0; i < parts.length; ++i) {
                        if (hud._avatarParamKey(parts[i]) === key) return true
                    }
                    return false
                }

                function _appendQueryOnce(u, key, value) {
                    u = String(u || "")
                    if (!u.length || !key || value === undefined || value === null || value === "") return u
                    if (_hasQueryParam(u, key)) return u
                    return u + (u.indexOf("?") >= 0 ? "&" : "?")
                            + encodeURIComponent(key) + "=" + encodeURIComponent(String(value))
                }

                function _avatarBaseClean() {
                    // On conserve le tag Jellyfin, mais on retire tout ce qui peut se dupliquer
                    // ou provoquer des logs d'URL sales pendant les rafraîchissements.
                    return hud._avatarRemoveParams(Jellyfin.stripAuthQueryFromUrl(baseUrl), [
                        "fbx" + "loop", "format", "fillwidth", "fillheight",
                        "maxwidth", "maxheight", "quality", "_v"
                    ])
                }

                readonly property string probeBaseUrl: (baseUrl && baseUrl.length) ? _avatarBaseClean() : ""

                function _displayBaseUrl() {
                    // Sécurité FreeStore/GitHub:
                    // Image.source ne doit jamais recevoir de token en query string.
                    // L'URL d'affichage reste sans jeton ni secret en query string.
                    return probeBaseUrl
                }

                // Le fallback statique est demandé uniquement lorsque l'animation
                // est réellement indisponible. Il n'est plus préchargé en parallèle
                // du GIF, ce qui évite un second UserImage de ~2 Mo au démarrage.
                readonly property string staticSrc: avatarStaticReady
                    ? _avatarHoldUrl()
                    : ""

                function _avatarHoldUrl() {
                    try {
                        if (hud.serverUrl && hud.serverUrl.length && hud.userId && hud.userId.length && hud.userImageTag && hud.userImageTag.length)
                            return Store.staticAvatarUrl(hud.serverUrl, hud.userId, hud.userImageTag)
                    } catch (e) {}

                    var u = hud._avatarRemoveParams(Jellyfin.stripAuthQueryFromUrl(_displayBaseUrl()), [
                        "fbx" + "loop", "format", "fillwidth", "fillheight",
                        "maxwidth", "maxheight", "quality", "_v"
                    ])
                    if (!u || !u.length) return ""
                    u = _appendQueryOnce(u, "format", "jpg")
                    u = _appendQueryOnce(u, "fillWidth", Math.max(reqAva, hud.avatarSize))
                    u = _appendQueryOnce(u, "fillHeight", Math.max(reqAva, hud.avatarSize))
                    u = _appendQueryOnce(u, "quality", 85)
                    return u
                }

                // La boucle normale est laissée à QMovie/AnimatedImage.
                // En cas de vrai stall uniquement, on utilise paused + frame 0,
                // sans toucher à source ni appeler stop()/start().
                property bool recoveryPause: false
                property int  recoveryAttempts: 0

                Timer {
                    id: recoveryResumeTimer
                    repeat: false
                    interval: avatarWrap.isDevialet ? hud.avatarRecoveryPauseMsDevi
                                                    : hud.avatarRecoveryPauseMsRevo
                    onTriggered: {
                        if (!avatarWrap._probeAlive) return
                        try { avatarAnim.currentFrame = 0 } catch(e0) {}
                        avatarWrap.recoveryPause = false
                        avatarWrap.lastFrame = 0
                        avatarWrap.lastFrameTs = Date.now()
                    }
                }

                function _stableAnimUrl(u) {
                    // Chemin animé stable : pas de conversion JPG, pas de cache-buster,
                    // pas de resize forcé. C'est volontaire pour conserver les GIF animés
                    // Jellyfin tels que les clients officiels les lisent.
                    u = hud._avatarRemoveParams(Jellyfin.stripAuthQueryFromUrl(String(u || "")), [
                        "fbx" + "loop", "format", "_v", "maxwidth", "maxheight",
                        "fillwidth", "fillheight", "quality"
                    ])
                    return u
                }
                readonly property string animSrc: avatarGifReady ? _stableAnimUrl(_displayBaseUrl()) : ""

                function _resetAvatarProbeState() {
                    _probeSeq += 1
                    _probePending = false
                    avatarStaticReady = false
                    avatarGifReady = false
                    recoveryPause = false
                    recoveryAttempts = 0
                    try { recoveryResumeTimer.stop() } catch(eTimer) {}
                    animMode = 0
                    stillStatus = Image.Null
                    animStatus = Image.Null
                    frameCount = 0
                    currentFrame = 0
                    _resetWatchdog()
                }

                function _startAvatarProbe() {
                    _resetAvatarProbeState()
                    if (!probeBaseUrl || !probeBaseUrl.length) return

                    // Pas de probe XHR brut : on affiche le JPG stable en fallback et
                    // on tente l'AnimatedImage sur une URL animée stable. Si ce n'est pas
                    // un GIF, le fallback statique reste prioritaire/visible.
                    _probePending = false
                    avatarStaticReady = true
                    avatarGifReady = true
                    recoveryPause = false
                    recoveryAttempts = 0
                    animMode = 0
                    stillStatus = Image.Null
                    animStatus = Image.Null
                    _resetWatchdog()
                }

                // ===== gate animate =====
                property int animMode: 0 // 0 unknown, 1 ok, -1 disabled

                readonly property bool wantAnimate: !!(
                    hud.visible && hud.active
                    && (hud.opacity > hud.animateOpacityThreshold)    // TWEAK 2
                    && avatarWrap.visible && avatarWrap.enabled
                    && (hud.avatarAnimateDuringScroll || !hud._scrollingEff)
                    && (!hud.avatarLoopOnlyWhenVisible || avatarWrap.avatarInViewport)
                    && (hud.avatarAnimateAlways || avatarWrap.activeFocus)
                    && (baseUrl && baseUrl.length)
                    && avatarGifReady
                    && (animMode !== -1)
                )

                // ===== status mirror =====
                property int stillStatus: Image.Null
                property int animStatus: Image.Null
                property int frameCount: 0
                property int currentFrame: 0

                readonly property bool fallbackWanted: !!(
                    !(baseUrl && baseUrl.length)
                    || (stillStatus === Image.Error)
                    || (
                        (stillStatus !== Image.Ready) &&
                        (!wantAnimate || (animStatus !== Image.Ready))
                    )
                )

                // ===== watchdog state =====
                property double lastFrameTs: 0
                property int    lastFrame: -1
                property bool   sawNonZeroFrame: false

                readonly property int stallMs: (isDevialet ? 950 : 1350)

                function _resetWatchdog() {
                    sawNonZeroFrame = false
                    lastFrameTs = 0
                    lastFrame = -1
                }

                function _noteFrame(cf) {
                    var now = Date.now()
                    if (cf !== lastFrame) {
                        // Un retour spontané d'une frame haute vers une frame basse
                        // prouve que la boucle native Qt fonctionne.
                        if (lastFrame > 0 && cf >= 0 && cf < lastFrame)
                            recoveryAttempts = 0
                        lastFrame = cf
                        lastFrameTs = now
                    }
                    if ((cf | 0) > 0) sawNonZeroFrame = true
                }

                function _recoverGifFromStall() {
                    if (!hud.avatarForceLoop || !wantAnimate
                            || animStatus !== Image.Ready || recoveryPause)
                        return false

                    // Cette voie n'est atteinte qu'après une vraie absence de
                    // changement de frame. Elle ne modifie jamais source.
                    recoveryAttempts += 1
                    recoveryPause = true
                    try { recoveryResumeTimer.stop() } catch(e0) {}
                    // recoveryPause pilote la propriété paused par binding.
                    // Ne jamais écrire avatarAnim.paused directement, sinon QML
                    // casserait ce binding.
                    try { avatarAnim.currentFrame = 0 } catch(e2) {}
                    lastFrame = 0
                    lastFrameTs = Date.now()
                    recoveryResumeTimer.restart()
                    return true
                }

                function _restartGif() {
                    // Compat des appels existants viewport/scroll/visible : si la
                    // source est déjà prête, on laisse simplement Qt reprendre.
                    if (!wantAnimate || animStatus !== Image.Ready) return false
                    if (recoveryPause) recoveryPause = false
                    return true
                }

                onWantAnimateChanged: {
                    // quand ça redevient animable (fade in / fin scroll / retour viewport), on relance proprement
                    if (wantAnimate) _restartGif()
                }

                // URL change => reset propre
                onBaseUrlChanged: { _startAvatarProbe() }
                onProbeBaseUrlChanged: { _startAvatarProbe() }

                Connections {
                    target: hud
                    ignoreUnknownSignals: true
                    function onScrollingChanged() {
                        if (!hud._scrollingEff && avatarWrap.wantAnimate) avatarWrap._restartGif()
                    }
                    function onVisibleChanged() {
                        if (hud.visible && avatarWrap.wantAnimate) avatarWrap._restartGif()
                    }
                    function onActiveChanged() {
                        if (hud.active && avatarWrap.wantAnimate) avatarWrap._restartGif()
                    }
                    function onAccessTokenChanged() { avatarWrap._startAvatarProbe() }
                    function onUserImageTagChanged() { avatarWrap._startAvatarProbe() }
                    function onUserIdChanged() { avatarWrap._startAvatarProbe() }
                    function onServerUrlChanged() { avatarWrap._startAvatarProbe() }
                }

                Keys.onPressed: {
                    // ✅ NAV: LEFT depuis l’avatar => focus Settings (géré par la page via host)
                    if (event.key === Qt.Key_Left) {
                        var routed = false
                        try {
                            if (hud.host && typeof hud.host.requestFocusSettings === "function") {
                                hud.host.requestFocusSettings()
                                routed = true
                            }
                        } catch (e0) {}
                        if (!routed) hud.requestFocusSettings()
                        event.accepted = true
                        return
                    }

                    if (event.key === Qt.Key_Down) { hud.requestFocusBelow(); event.accepted = true; return }
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                        if (hud.avatarInteractive) hud.avatarActivated()
                        if (hud.avatarAction === "login") { hud._openLoginRoot(); event.accepted = true; return }
                    }
                    event.accepted = false
                }

                // ===== BG =====
                Rectangle { anchors.fill: parent; radius: width/2; color: "#222533"; opacity: 0.55 }

                // ===== content (masqué en rond via layer.effect) =====
                Item {
                    id: contentLayer
                    anchors.fill: parent
                    opacity: 1.0

                    // masque rond appliqué AU CONTENU
                    layer.enabled: true
                    layer.smooth: false
                    layer.mipmap: false
                    layer.effect: OpacityMask {
                        maskSource: circleMask
                        cached: !avatarWrap.wantAnimate   // cache quand statique => coût continu ↓
                        antialiasing: false
                    }

                    // fallback
                    Item {
                        anchors.fill: parent
                        opacity: avatarWrap.fallbackWanted ? 1.0 : 0.0
                        Rectangle { anchors.fill: parent; radius: width/2; color: "#2a2f44" }
                        Rectangle {
                            width: parent.width*0.40; height: width; radius: width/2; color:"#8e97b8"
                            anchors.horizontalCenter: parent.horizontalCenter; y: parent.height*0.18; opacity:0.85
                        }
                        Rectangle {
                            width: parent.width*0.72; height: parent.height*0.44; radius: Math.min(width,height)*0.22; color:"#7680a4"
                            anchors.horizontalCenter: parent.horizontalCenter; y: parent.height*0.52; opacity:0.85
                        }
                        Text { textFormat: Text.PlainText;
                            anchors.centerIn: parent
                            text: { var s=(hud.userName||"").trim(); return s.length ? s.charAt(0).toUpperCase() : "" }
                            visible: hud.showFallbackInitial && text.length > 0
                            color:"#e9ecff"; font.pixelSize: Math.round(parent.width*0.42); font.bold:true; opacity:0.20
                        }
                    }

                    // photo
                    Item {
                        anchors.fill: parent
                        visible: !!(avatarWrap.baseUrl && avatarWrap.baseUrl.length)

                        Image {
                            id: avatarStill
                            anchors.fill: parent
                            // AnimatedImage reste chargée même lorsqu'elle est
                            // momentanément arrêtée. Le pipeline statique n'est
                            // utilisé qu'en vrai fallback de décodage.
                            source: (avatarWrap.avatarStaticReady
                                     && (avatarWrap.animMode === -1 || avatarWrap.animStatus === Image.Error))
                                    ? avatarWrap.staticSrc : ""
                            asynchronous: true
                            cache: true
                            smooth: false
                            mipmap: false
                            fillMode: Image.PreserveAspectCrop
                            onStatusChanged: {
                                avatarWrap.stillStatus = status
                                if (status === Image.Error) {
                                    avatarWrap.avatarStaticReady = false
                                    avatarWrap.stillStatus = Image.Error
                                }
                            }
                        }

                        AnimatedImage {
                            id: avatarAnim
                            anchors.fill: parent

                            // SOURCE STABLE : ne dépend ni du scroll, ni du fade,
                            // ni du focus. Sinon chaque changement de wantAnimate
                            // vide/recharge le flux réseau.
                            source: avatarWrap.avatarGifReady ? avatarWrap.animSrc : ""

                            asynchronous: true
                            // Le cache est nécessaire ici pour permettre à Qt de
                            // reboucler proprement le flux GIF réseau sur Freebox.
                            // AnimatedImage.sourceSize est en lecture seule sur le
                            // runtime Qt 5.15 Freebox : ne jamais l'assigner.
                            cache: true
                            fillMode: Image.PreserveAspectCrop
                            playing: avatarWrap.wantAnimate
                            paused: avatarWrap.recoveryPause
                            opacity: (status === Image.Ready) ? 1.0 : 0.0

                            onStatusChanged: {
                                avatarWrap.animStatus = status
                                avatarWrap.frameCount = frameCount | 0
                                avatarWrap.currentFrame = currentFrame | 0

                                if (!source || !source.length) return

                                if (status === Image.Ready) {
                                    avatarWrap.animMode = 1
                                    avatarWrap._resetWatchdog()
                                    avatarWrap._noteFrame(currentFrame | 0)
                                } else if (status === Image.Error) {
                                    avatarWrap.avatarGifReady = false
                                    if (avatarWrap.animMode === 0) avatarWrap.animMode = -1
                                }
                            }

                            onCurrentFrameChanged: {
                                avatarWrap.currentFrame = currentFrame | 0
                                avatarWrap._noteFrame(currentFrame | 0)
                            }
                        }
                    }
                }

                // ===== circle mask (utilisé par layer.effect) =====
                Rectangle {
                    id: circleMask
                    anchors.fill: parent
                    radius: width/2
                    color: "#ffffff"
                    visible: false
                }

                // ===== focus ring =====
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: hud.avatarFocusRingInset
                    radius: width/2
                    color: "transparent"
                    border.width: hud.avatarFocusRingWidth
                    border.color: hud.avatarFocusRingColor
                    antialiasing: true
                    opacity: avatarWrap.activeFocus ? 1.0 : 0.0
                    Behavior on opacity {
                        enabled: !!(hud.active && hud.visible)
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                }

                // ===== watchdog (NO frameCount gate) =====
                Timer {
                    id: loopWatchdog
                    interval: Math.max(260, hud.avatarLoopCheckMs)
                    repeat: true
                    running: !!(hud.visible && hud.active && hud.avatarForceLoop
                                && avatarWrap.wantAnimate
                                && (avatarWrap.animStatus === Image.Ready))

                    onTriggered: {
                        var now = Date.now()
                        if (!avatarWrap.lastFrameTs) avatarWrap.lastFrameTs = now

                        var dt = now - avatarWrap.lastFrameTs

                        // Aucune action spéciale sur la dernière frame : avec
                        // cache:true, QMovie doit reboucler nativement vers 0.
                        // Le watchdog n'intervient que si aucune frame ne change.
                        if (avatarWrap.sawNonZeroFrame && dt >= avatarWrap.stallMs) {
                            avatarWrap._recoverGifFromStall()
                            return
                        }

                        // Certains firmwares peuvent rester sur la frame 0 au
                        // démarrage. Une récupération locale reste autorisée.
                        if (!avatarWrap.sawNonZeroFrame && dt >= 2200) {
                            avatarWrap._recoverGifFromStall()
                            return
                        }
                    }
                }
            }

            Text { textFormat: Text.PlainText;
                id: userNameLabel
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                visible: !!(hud.showAvatar && hud.showUserName && hud.userName && hud.userName.length > 0)
                text: hud.userName
                color: hud.userNameColor
                opacity: 0.92
                font.pixelSize: hud.userNameFontPx
                font.bold: false
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
        }

        Text { textFormat: Text.PlainText;
            id: timeText
            visible: hud._clockOn
            color: "#e9ecff"
            font.pixelSize: hud.fontPx
            verticalAlignment: Text.AlignVCenter
            text: ""
            y: hud.showAvatar ? Math.max(0, Math.round((hud.avatarSize - height) / 2)) : 0
        }
    }

    Timer {
        id: alignTimer
        repeat: false
        interval: 60000
        onTriggered: { hud.updateClock(false); minuteTickTimer.start() }
    }
    Timer {
        id: minuteTickTimer
        repeat: true
        interval: 60000
        onTriggered: hud.updateClock(false)
    }
}
