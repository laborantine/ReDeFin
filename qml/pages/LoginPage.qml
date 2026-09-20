import QtQuick 2.15
import QtGraphicalEffects 1.15
import fbx.ui.base 1.0 as FbxBase
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/clientId.js" as ClientId
import "../js/UserStore.js" as Store
import "../js/SafeLog.js" as SafeLog
FocusScope {
    id: page

    width: 1280; height: 720
    focus: true

    /* ==== Palette neutre / AMOLED ==== */
    readonly property color uiBg: "#000000"
    readonly property color uiSurface: "#101010"
    readonly property color uiSurfaceRaised: "#171717"
    readonly property color uiSurfaceFocus: "#202020"
    readonly property color uiBorder: "#383838"
    readonly property color uiBorderStrong: "#5A5A5A"
    readonly property color uiFocus: "#FFFFFF"
    readonly property color uiText: "#FFFFFF"
    readonly property color uiTextSecondary: "#C8C8C8"
    readonly property color uiTextMuted: "#969696"
    readonly property color uiDanger: "#FFB4B4"
    // Rollback transparence menus : niveau historique commun.
    readonly property color uiMenuPanel: "#A6000000"
    readonly property real uiMenuShadeOpacity: 0.22
    readonly property int uiRadiusLarge: 20
    readonly property real uiCardFocusScale: 1.025
    readonly property real uiButtonFocusScale: 1.035
    readonly property int uiFocusLiftPx: 4
    property bool overlayOpen: (loginOverlay.active || quickOverlay.active || serverOverlay.active)
    // Pendant le volet de connexion, ne conserver derrière la transparence que
    // le backdrop, l'heure et le titre « Qui regarde ? ».
    readonly property bool loginBackdropOnly: loginOverlay.active || quickOverlay.active

    /* ==== Logo (haut-gauche) ==== */
    property url  redefinLogoUrl: Qt.resolvedUrl("../images/Redefin-logo2-512.png")
    property int  logoWidth: 320
    property int  logoHeight: 200
    property real logoOversample: 1.8
    property int  logoLeftMargin: 8
    property int  logoTopMargin: -30
    Item {
        id: logoLayer
        z: 10000
        width: page.logoWidth
        height: page.logoHeight
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: page.logoLeftMargin
        anchors.topMargin: page.logoTopMargin
        visible: !page.overlayOpen
        enabled: visible
        Image {
            id: logoImg
            anchors.fill: parent
            source: page.redefinLogoUrl
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            smooth: true
            mipmap: false
            sourceSize.width: Math.max(1, Math.round(parent.width  * page.logoOversample))
            sourceSize.height: Math.max(1, Math.round(parent.height * page.logoOversample))
        }
    }

    /* ==== Contexte / sorties ==== */
    property string serverUrl
    property var    fbx
    property var    shared: null
    property var    settingsRef: null

    // 404 d'avatar mémorisés uniquement pour la durée de vie de LoginPage.
    // Un rafraîchissement de modèle ne doit pas relancer la même URL invalide.
    property var _missingAvatarKeys: ({})

    /* ==== Message de bienvenue configuré côté Jellyfin ==== */
    property string loginDisclaimer: ""
    property int _brandingRequestSeq: 0
    property var _brandingRequestHandle: null

    function _plainBrandingText(value) {
        var s = String(value === undefined || value === null ? "" : value)
        if (!s) return ""

        // Jellyfin Web accepte du HTML dans LoginDisclaimer. ReDeFin le
        // transforme volontairement en texte brut : aucune image, CSS ou
        // ressource externe ne peut être déclenchée par le branding serveur.
        s = s.replace(/<script[\s\S]*?<\/script>/gi, " ")
        s = s.replace(/<style[\s\S]*?<\/style>/gi, " ")
        s = s.replace(/<br\s*\/?>/gi, "\n")
        s = s.replace(/<\/p\s*>/gi, "\n")
        s = s.replace(/<\/div\s*>/gi, "\n")
        s = s.replace(/<[^>]*>/g, " ")

        s = s.replace(/&nbsp;/gi, " ")
             .replace(/&amp;/gi, "&")
             .replace(/&lt;/gi, "<")
             .replace(/&gt;/gi, ">")
             .replace(/&quot;/gi, "\"")
             .replace(/&#39;/gi, "'")
             .replace(/&apos;/gi, "'")

        s = s.replace(/[ \t\r]+/g, " ")
        s = s.replace(/ *\n */g, "\n")
        s = s.replace(/\n{3,}/g, "\n\n")
        s = s.replace(/^\s+|\s+$/g, "")

        if (s.length > 720)
            s = s.substr(0, 717) + "…"
        return s
    }

    function _cancelBrandingRequest(reason) {
        var h = _brandingRequestHandle
        _brandingRequestHandle = null
        if (!h) return
        try {
            if (typeof h.cancel === "function")
                h.cancel(reason || "branding_replaced", false)
        } catch(e0) {}
    }

    function _loadLoginDisclaimerForServer(value) {
        var base = _normalizeContextServerUrl(value)
        var seq = ++_brandingRequestSeq
        _cancelBrandingRequest("branding_replaced")
        loginDisclaimer = ""
        if (!base || !Jellyfin || !Jellyfin.fetchBrandingConfiguration) return

        try {
            _brandingRequestHandle = Jellyfin.fetchBrandingConfiguration(base,
                function(cfg) {
                    if (seq !== page._brandingRequestSeq
                            || base !== page._normalizeContextServerUrl(page.serverUrl))
                        return
                    page._brandingRequestHandle = null
                    cfg = cfg || {}
                    page.loginDisclaimer = page._plainBrandingText(
                                cfg.LoginDisclaimer !== undefined
                                ? cfg.LoginDisclaimer
                                : cfg.loginDisclaimer)
                },
                function() {
                    if (seq !== page._brandingRequestSeq) return
                    page._brandingRequestHandle = null
                    page.loginDisclaimer = ""
                }
            )
        } catch(e1) {
            _brandingRequestHandle = null
            if (seq === page._brandingRequestSeq)
                page.loginDisclaimer = ""
        }
    }

    // Mode confort TV : le token peut être mémorisé dans le coffre séparé
    // de UserStore.js. Il ne doit jamais être écrit dans fbx.application.Settings.
    // Le mode "sécurité maximale" repasse automatiquement en RAM-only.
    readonly property bool persistentSessionTokensAllowed: true

    signal requestNavigation(string pageName)
    // ShellPage utilise ce signal pour afficher CircleDots immédiatement au
    // clic sur un profil tokenisé, puis le garde jusqu'à HomePage.
    signal requestHomeLoading(bool active)
    function _securityErrorForServerUrl(url) {
        try {
            if (Jellyfin && Jellyfin.isWanHttpUrl && Jellyfin.isWanHttpUrl(url))
                return "Connexion HTTP externe refusée. Utilise HTTPS ou une adresse locale."
        } catch(e0) {}
        try {
            if (SafeLog.isWanHttpUrl(url))
                return "Connexion HTTP externe refusée. Utilise HTTPS ou une adresse locale."
        } catch(e1) {}
        return ""
    }
    function _normalizeContextServerUrl(url) {
        var raw = String(url || "").trim()
        if (!raw) return ""
        try {
            if (Jellyfin && Jellyfin.normalizeServerUrl) {
                var u = Jellyfin.normalizeServerUrl(raw, false)
                if (u) return String(u)
            }
        } catch(e0) {}
        // Aucun fallback brut : une URL refusée par le bridge ne doit pas revenir
        // dans le store, les Settings ou le contexte partagé.
        return ""
    }
    function _securityCoordinator() {
        var host = _findShellHost()
        return host || null
    }
    function _clearApiCaches(cancelInflightLeaders) {
        var host = _securityCoordinator()
        if (host && typeof host.securityClearApiCaches === "function") {
            host.securityClearApiCaches(cancelInflightLeaders !== false)
            return
        }
        try {
            if (Jellyfin && typeof Jellyfin.clearApiCaches === "function")
                Jellyfin.clearApiCaches(cancelInflightLeaders !== false)
        } catch(e) {}
    }
    function _clearTrustedLanHosts() {
        var host = _securityCoordinator()
        if (host && typeof host.securityClearTrustedLanHosts === "function") {
            host.securityClearTrustedLanHosts()
            return
        }
        try { if (Jellyfin && Jellyfin.clearTrustedLanHosts) Jellyfin.clearTrustedLanHosts() } catch(e0) {}
    }
    function _forgetTrustedLanHost(value) {
        var host = _securityCoordinator()
        if (host && typeof host.securityForgetTrustedLanHost === "function") {
            host.securityForgetTrustedLanHost(value)
            return
        }
        try { if (Jellyfin && Jellyfin.forgetTrustedLanHost) Jellyfin.forgetTrustedLanHost(value) } catch(e0) {}
    }
    function _trustedLanHostBeforeRotation(value) {
        var host = _securityCoordinator()
        if (host && typeof host.securityIsTrustedLanHost === "function")
            return host.securityIsTrustedLanHost(value) === true
        try {
            return !!(Jellyfin && Jellyfin.isTrustedLanHost
                      && Jellyfin.isTrustedLanHost(value) === true)
        } catch(e0) {}
        return false
    }
    function _restoreTrustedLanHost(value) {
        var host = _securityCoordinator()
        if (host && typeof host.securityTrustLanHost === "function") {
            host.securityTrustLanHost(value)
            return
        }
        try { if (Jellyfin && Jellyfin.trustLanHost) Jellyfin.trustLanHost(value) } catch(e0) {}
    }
    function _rotateSecurityContextForServer(value) {
        var host = _securityCoordinator()
        if (host && typeof host.securityRotateForServer === "function") {
            host.securityRotateForServer(value)
            return
        }
        var keep = value && _trustedLanHostBeforeRotation(value)
        _clearTrustedLanHosts()
        if (keep) _restoreTrustedLanHost(value)
    }
    function _isShortLanServerUrl(value) {
        try {
            return Jellyfin && typeof Jellyfin.isShortLanHostName === "function"
                    && Jellyfin.isShortLanHostName(value) === true
        } catch(e0) {}
        return false
    }

    function _trustValidatedLanHost(value) {
        _restoreTrustedLanHost(value)
    }
    function _resetServerRuntimeStateForSwitch() {
        _clearApiCaches()
        _loadSeq++
        loading = false
        errorText = ""
        serverInfo = ({ name: "", version: "", id: "" })
        _brandingRequestSeq++
        _cancelBrandingRequest("server_switch")
        loginDisclaimer = ""
        serverUsers = []
        localUsers = []
        usersModel = []
        tokenByUserId = ({})
    }
    function _applyServerUrlFromContext(url) {
        var next = _normalizeContextServerUrl(url)
        if (!next) return false
        if (String(serverUrl || "") === next) return false
        _resetServerRuntimeStateForSwitch()
        serverUrl = next
        return true
    }
    function _rememberServerUrl(url, info) {
        var u = _normalizeContextServerUrl(url)
        if (!u) return false
        try {
            if (Store && Store.addOrUpdateServer) {
                return Store.addOrUpdateServer({
                    serverUrl: u,
                    name: info && (info.name || info.ServerName || info.ProductName || info.serverName) ? (info.name || info.ServerName || info.ProductName || info.serverName) : "",
                    version: info && (info.version || info.Version) ? (info.version || info.Version) : "",
                    id: info && (info.id || info.Id || info.ServerId) ? (info.id || info.Id || info.ServerId) : ""
                })
            }
        } catch(e0) {}
        return false
    }
    function _savedServersForOverlay() {
        var out = []
        var seen = {}
        function add(url, name, version, id) {
            url = _normalizeContextServerUrl(url)
            if (!url || seen[url]) return
            seen[url] = true
            out.push({
                name: name || "Jellyfin",
                url: url,
                serverUrl: url,
                version: version || "",
                id: id || ""
            })
        }
        try {
            if (Store && Store.listServers) {
                var servers = Store.listServers() || []
                for (var i = 0; i < servers.length; i++) {
                    var s0 = servers[i] || {}
                    add(s0.serverUrl || s0.url, s0.name, s0.version, s0.id)
                }
            }
        } catch(e1) {}
        return out
    }
    function _refreshSavedServersOverlay() {
        try {
            if (serverOverlay && serverOverlay.item && serverOverlay.item.applyHostContext)
                serverOverlay.item.applyHostContext(page._serverOverlayContext())
        } catch(e0) {}
    }
    function _requestSettingsUpdate(payload) {
        var host = _findShellHost()
        try {
            if (host && typeof host.saveSettingsRequested === "function") {
                host.saveSettingsRequested(payload || ({}))
                return true
            }
        } catch(e0) {}
        return false
    }
    function _clearLastSessionIfProfileMatches(serverUrl, userId) {
        try {
            if (!settingsRef) return
            var lastUid = String(settingsRef.lastUserId || "")
            var lastSrv = String(settingsRef.serverUrl || "")
            var srv = String(serverUrl || "")
            var uid = String(userId || "")
            var sameUser = (lastUid === uid)
            var sameServer = (!lastSrv || !srv || lastSrv === srv)
            if (sameUser && sameServer)
                _requestSettingsUpdate({ lastUserId: "", lastUserName: "" })
        } catch(e0) {}
    }
    function _clearLastSessionIfServerMatches(serverUrl) {
        try {
            if (!settingsRef) return
            var lastSrv = String(settingsRef.serverUrl || "")
            var srv = String(serverUrl || "")
            if (srv && lastSrv === srv)
                _requestSettingsUpdate({ serverUrl: "", lastUserId: "", lastUserName: "" })
        } catch(e0) {}
    }
    function _removeSavedServerUrl(url) {
        var u = _normalizeContextServerUrl(url)
        if (!u) return false
        _clearApiCaches()
        _forgetTrustedLanHost(u)
        try {
            if (Store && Store.forgetServer)
                Store.forgetServer(u)
            else if (Store && Store.clearServer)
                Store.clearServer(u)
            else if (Store && Store.removeServer)
                Store.removeServer(u)
        } catch(e1) {}
        _clearLastSessionIfServerMatches(u)
        try {
            if (String(page.serverUrl || "") === String(u || "")) {
                page.tokenByUserId = ({})
                page.localUsers = []
                page.usersModel = []
            }
        } catch(e2) {}
        _refreshSavedServersOverlay()
        return true
    }
    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        try {
            var api = _sharedNavApi()
            var ctx = api && api.peek ? api.peek() : null
            if (!ctx) return false
            var changed = false
            var consumed = false
            if (ctx.serverUrl) {
                changed = _applyServerUrlFromContext(ctx.serverUrl) || changed
                _rememberServerUrl(ctx.serverUrl, ctx)
                consumed = true
            }
            if (!fbx && ctx.fbx) { fbx = ctx.fbx; changed = true; consumed = true }
            if (consumed && api && api.clear) api.clear()
            return changed
        } catch(e) { return false }
    }
    function _clearSensitiveNavContext(){
        var api = _sharedNavApi()
        if (api && api.clear) api.clear()
    }
    function _resolvedSecuritySettings(){
        try {
            if (settingsRef) return settingsRef
        } catch(e0) {}

        // Loader.onLoaded injecte normalement settingsRef. Pendant les quelques
        // instructions précédentes du cycle QML, le Shell possède déjà Settings :
        // on peut donc le lire sans inventer une politique false transitoire.
        var host = _findShellHost()
        try {
            if (host && host.settings) return host.settings
        } catch(e1) {}
        return null
    }

    function _maximumSessionSecurityEnabled(){
        var ref = _resolvedSecuritySettings()
        try {
            if (ref && ("maximumSessionSecurity" in ref))
                return ref.maximumSessionSecurity === true
        } catch(e0) {}
        return false
    }

    function _syncStoreSecurityPolicy(){
        try {
            Store.init(page)
            var ref = _resolvedSecuritySettings()

            // CRITIQUE : absence momentanée de Settings != choix utilisateur false.
            // On ne modifie jamais la politique tant que le backend officiel
            // n'est pas résolu. La persistance reste ensuite décidée par profil.
            if (!ref) return false

            var maxSecurity = false
            var remember = false
            try {
                maxSecurity = ("maximumSessionSecurity" in ref)
                        && ref.maximumSessionSecurity === true
                remember = persistentSessionTokensAllowed === true
                        && !maxSecurity
                        && ("rememberJellyfinSession" in ref)
                        && ref.rememberJellyfinSession === true
            } catch(eRead) {}

            if (Store.configureSecurityPolicy)
                Store.configureSecurityPolicy(remember, maxSecurity)
            return true
        } catch(e) {}
        return false
    }

    function _findShellHost(){
        var p = page.parent
        for (var i = 0; i < 10 && p; i++) {
            try {
                if (typeof p.forgetThisDevice === "function"
                        || typeof p.setRememberJellyfinSession === "function")
                    return p
            } catch(e0) {}
            try { p = p.parent } catch(e1) { p = null }
        }
        return null
    }

    function _setRememberSessionEnabled(enabled){
        var next = persistentSessionTokensAllowed === true
                && enabled === true
                && !_maximumSessionSecurityEnabled()
        var host = _findShellHost()

        try {
            if (host && typeof host.setRememberJellyfinSession === "function")
                next = host.setRememberJellyfinSession(next) === true
            else
                _requestSettingsUpdate({ rememberJellyfinSession: next })
        } catch(e0) {}

        // Garde la politique UserStore cohérente même si la page est exécutée
        // isolément sans ShellPage (tests QML / chargement de secours).
        try {
            Store.init(page)
            if (Store.configureSecurityPolicy)
                Store.configureSecurityPolicy(next, _maximumSessionSecurityEnabled())
        } catch(e1) {}

        // Important : décocher « Mémoriser ce profil » ne purge jamais le coffre
        // global. Après authentification, addOrUpdateUser(... remember:false)
        // retire uniquement le token du profil concerné.
        return next
    }


    function _rememberTokenRequested(){
        if (persistentSessionTokensAllowed !== true) return false
        if (_maximumSessionSecurityEnabled()) return false

        // La case « Mémoriser ce profil » est l'autorité par profil.
        // rememberJellyfinSession est conservé comme réglage legacy/capacité UI,
        // mais une course de synchronisation Settings ne doit jamais transformer
        // un login explicitement mémorisé en simple profil sans session.
        _syncStoreSecurityPolicy()
        try {
            if (Store && Store.canPersistTokens)
                return Store.canPersistTokens() === true
        } catch(e0) {}
        return false
    }
    function _storeSensitiveNavContextForUser(tok, uid, name, tag, remember){

        try {
            if (!shared) {

                return false
            }
            var keepToken = (remember === undefined || remember === null)
                    ? _rememberTokenRequested()
                    : (remember === true)
            var api = _sharedNavApi()
            if (!(api && api.storeValues && api.storeValues({
                accessToken: tok || "",
                userId: uid || "",
                serverUrl: serverUrl || "",
                userName: name || "",
                userImageTag: tag || "",
                fbx: fbx || null,
                remember: keepToken
            }))) return false

            return true
        } catch(e) {

            return false
        }
    }

    /* ==== État ==== */
    property var    serverInfo: ({ name: "", version: "", id: "" })
    property var    serverUsers: []
    property var    localUsers: []
    property var    usersModel: []
    property bool   loading: true
    property string errorText: ""
    property var    tokenByUserId: ({})
    // Choix du prochain login. Comme dans l’ancienne logique v3 : coché par
    // défaut, puis appliqué uniquement au profil qui vient de s’authentifier.
    property bool   rememberProfileOnLogin: true
    property var    discoveredServersCache: []
    property string _overlaySwitchTarget: ""
    property bool   _suppressBackOnce: false
    Timer { id: backReleaseGuard; interval: 220; repeat: false; running: false; onTriggered: page._suppressBackOnce = false }
    function _swallowNextBackRelease(){ _suppressBackOnce = true; backReleaseGuard.restart(); }

    /* ==== Pare-chocs global OK ==== */
    property bool _okSwallowUntilRelease: false
    Timer { id: okSwallowGuard; interval: 300; repeat: false; running: false; onTriggered: { page._okSwallowUntilRelease = false; } }
    function _swallowOkUntilRelease() {
        _okSwallowUntilRelease = true
        okSwallowGuard.restart()
        Qt.callLater(function(){ if (inputShield.visible) inputShield.forceActiveFocus(); })
    }
    function _isOkKey(k){
        return k===Qt.Key_Return || k===Qt.Key_Enter || k===Qt.Key_Select || k===Qt.Key_Okay
    }

    /* ==== Latch post-logout ==== */
    property bool _postLogoutLatch: false
    Timer { id: _postLogoutLatchTimer; interval: 420; repeat: false; running: false; onTriggered: { page._postLogoutLatch = false; } }
    function _debounceAfterLogout(ms){
        page._postLogoutLatch = true
        _postLogoutLatchTimer.interval = ms || 420
        _postLogoutLatchTimer.restart()
        Qt.callLater(function(){ if (inputShield.visible) inputShield.forceActiveFocus(); })
    }

    /* ==== Splash Jellyfin (fond) ==== */
    Item {
        id: splashBg
        anchors.fill: parent
        z: -100
        // Rollback de l'intensité du branding Jellyfin :
        // l'image serveur retrouve sa présence visuelle d'avant redesign.
        property real imageAlpha: 0.28
        property string currentSource: ""
        property string requestedServerBase: ""
        property var failedServerBases: []

        function normalizedBase() {
            try { return Jellyfin.normalizeServerUrl(page.serverUrl, false) || "" }
            catch(e0) { return "" }
        }
        function hasFailed(base) {
            base = String(base || "")
            for (var i = 0; i < failedServerBases.length; i++)
                if (failedServerBases[i] === base) return true
            return false
        }
        function markFailed(base) {
            base = String(base || "")
            if (!base || hasFailed(base)) return
            var list = failedServerBases && failedServerBases.slice ? failedServerBases.slice(0) : []
            list.push(base)
            if (list.length > 8)
                list = list.slice(list.length - 8)
            failedServerBases = list
        }
        function wantedSource() {
            var base = normalizedBase()
            if (!base || hasFailed(base)) return ""
            return base + "/Branding/Splashscreen"
        }
        function scheduleRefresh(reason) {
            var base = normalizedBase()
            if (!base) {
                requestedServerBase = ""
                currentSource = ""
                splashRefreshTimer.stop()
                return
            }
            if (hasFailed(base)) {
                requestedServerBase = base
                currentSource = ""
                splashRefreshTimer.stop()
                return
            }
            splashRefreshTimer.restart()
        }
        function applySource() {
            var base = normalizedBase()
            var u = wantedSource()
            if (!base || !u) {
                currentSource = ""
                return
            }
            if (currentSource === u && splashImg.status !== Image.Error)
                return
            requestedServerBase = base
            currentSource = ""
            Qt.callLater(function() {
                var latestBase = splashBg.normalizedBase()
                var latest = splashBg.wantedSource()
                if (!latestBase || !latest || latestBase !== splashBg.requestedServerBase)
                    return
                splashBg.currentSource = latest
            })
        }
        Timer {
            id: splashRefreshTimer
            interval: 90
            repeat: false
            onTriggered: splashBg.applySource()
        }
        Rectangle {
            anchors.fill: parent
            color: page.uiBg
        }
        Image {
            id: splashImg
            anchors.fill: parent
            source: splashBg.currentSource
            asynchronous: true
            cache: false
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: page.width
            sourceSize.height: page.height
            opacity: (status === Image.Ready ? splashBg.imageAlpha : 0.0)
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            onStatusChanged: {
                if (status === Image.Error) {
                    var failedBase = splashBg.requestedServerBase
                    splashBg.markFailed(failedBase)
                    opacity = 0.0
                    // Un serveur sans branding ne doit pas être sollicité trois fois.
                    // Le fond local reste affiché pour toute la session.
                    splashBg.currentSource = ""
                }
            }
        }
        Rectangle { anchors.fill: parent; color: "black"; opacity: 0.06 }
    }

    /* ==== Découverte / Store ====
       Le scan réseau vit dans ServerOverlay.qml et n'existe en mémoire
       que lorsque l'overlay est chargé. LoginPage conserve uniquement
       le cache public et le contrat d'injection. */
    function _copyServerList(list) {
        return list && list.slice ? list.slice(0) : (list || [])
    }

    function setDiscoveredServers(list) {
        discoveredServersCache = _copyServerList(list)
        _syncServerOverlayDiscovery()
    }

    function _serverOverlayContext() {
        return {
            savedServers: _savedServersForOverlay(),
            discoveredServers: _copyServerList(discoveredServersCache),
            currentServerUrl: serverUrl,
            serverInfo: serverInfo,
            fbx: fbx,
            shared: shared
        }
    }

    function _syncServerOverlayDiscovery() {
        if (!serverOverlay.active || !serverOverlay.item) return
        var item = serverOverlay.item
        try {
            if (item.applyHostContext) item.applyHostContext(_serverOverlayContext())
        } catch(e0) {}
    }

    onSharedChanged: {
        page._hydrateSensitiveContextFromShared()
        _syncServerOverlayDiscovery()
    }
    onSettingsRefChanged: {
        _syncStoreSecurityPolicy();
        hydrateFromStore();
    }

    /* ==== Helpers ==== */
    function _join(base,path){ var b=String(base||"").replace(/\/+$/,""); var p=String(path||""); return b+(p.charAt(0)==='/'?p:("/"+p)); }
    function _hasToken(id){ return !!(id && tokenByUserId[id]); }
    function _primaryImageTagOf(userObj){
        if(!userObj) return "";
        return String(userObj.PrimaryImageTag || (userObj.ImageTags && userObj.ImageTags.Primary) || "");
    }
    function _persistVerifiedAvatarMeta(uid, name, tag){
        if(!uid) return;
        try {
            if(Store.updateUserAvatarMetadata)
                Store.updateUserAvatarMetadata(page.serverUrl, uid, name || "", tag || "");
        } catch(e) {}
    }
    function _recomputeModel(){
        var map={}, arr=[];
        // Les profils déjà authentifiés sur cet appareil restent visibles même
        // après redémarrage. Le tag d'avatar n'est utilisé que s'il a été relié
        // explicitement à cet userId par une réponse Jellyfin récente.
        for (var i=0;i<localUsers.length;i++){
            var u=localUsers[i];
            if (u && u.Id && !map[u.Id]) { map[u.Id]=true; arr.push(u); }
        }
        // Un utilisateur seulement découvert via /Users/Public n'est pas ajouté
        // à la grille tant qu'il n'a jamais été authentifié sur cet appareil.
        // Si un token de session existe déjà, il peut néanmoins rejoindre le modèle.
        for (var j=0;j<serverUsers.length;j++){
            var su=serverUsers[j];
            if (su && su.Id && !map[su.Id] && _hasToken(su.Id)) { map[su.Id]=true; arr.push(su); }
        }
        usersModel = arr;
    }
    function _ensureLocalUser(userObj, rememberValue){
        if(!userObj||!userObj.Id) return;
        var i,found=false;
        var modelDirty=false;
        for(i=0;i<localUsers.length;i++) if(localUsers[i].Id===userObj.Id){ found=true; break; }
        var tag=_primaryImageTagOf(userObj);
        var hasRemember = (rememberValue !== undefined && rememberValue !== null);
        var entry={
            Id:userObj.Id,
            Name:(userObj.Name||userObj.Username||"Profil"),
            PrimaryImageTag:tag,
            AvatarTagVerified:true,
            Remember: hasRemember ? (rememberValue === true) : false
        };
        if(!found){
            localUsers=[entry].concat(localUsers);
            modelDirty=true;
        } else {
            var uu=localUsers[i], ch=false;
            if(entry.Name!==uu.Name){ uu.Name=entry.Name; ch=true; }
            // Une réponse /Users/{id} ou d'authentification est l'autorité :
            // elle peut aussi confirmer qu'un ancien avatar a été supprimé.
            if(entry.PrimaryImageTag!==String(uu.PrimaryImageTag||"")){ uu.PrimaryImageTag=entry.PrimaryImageTag; ch=true; }
            if(uu.AvatarTagVerified!==true){ uu.AvatarTagVerified=true; ch=true; }
            if(hasRemember && uu.Remember !== entry.Remember){ uu.Remember=entry.Remember; ch=true; }
            if(ch){
                localUsers=localUsers.slice(0);
                modelDirty=true;
            }
        }
        _persistVerifiedAvatarMeta(entry.Id, entry.Name, entry.PrimaryImageTag);
        // Ne pas reconstruire usersModel si le GET /Users/{id} confirme
        // simplement les mêmes nom/tag que la réponse d'authentification.
        if(modelDirty) _recomputeModel();
    }
    function _reconcilePublicUsers(users){
        users = users || [];
        var byId = ({});
        var normalized = [];
        var i;
        for(i=0;i<users.length;i++){
            var pu=users[i];
            if(!pu || !pu.Id) continue;
            // /Users/Public est l'autorité pour les profils qu'il expose. Une
            // absence de PrimaryImageTag signifie donc « pas d'avatar public ».
            pu.PrimaryImageTag = _primaryImageTagOf(pu);
            pu.AvatarTagVerified = true;
            byId[pu.Id] = pu;
            normalized.push(pu);
        }

        var next=[];
        for(i=0;i<localUsers.length;i++){
            var lu=localUsers[i];
            if(!lu || !lu.Id) continue;
            var pub=byId[lu.Id];
            if(pub){
                var verifiedTag=_primaryImageTagOf(pub);
                var verifiedName=pub.Name || lu.Name || "Profil";
                next.push({
                    Id: lu.Id,
                    Name: verifiedName,
                    PrimaryImageTag: verifiedTag,
                    AvatarTagVerified: true,
                    Remember: lu.Remember === true
                });
                _persistVerifiedAvatarMeta(lu.Id, verifiedName, verifiedTag);
            } else {
                next.push(lu);
            }
        }
        localUsers = next;
        serverUsers = normalized;
    }
    function _validateNonPublicStoredAvatars(seq, srv){
        // Un profil masqué dans /Users/Public peut tout de même être mémorisé
        // localement. S'il possède un token valide, /Users/{id} permet de
        // valider son tag sans jamais tenter une URL /UserImage potentiellement
        // héritée d'un ancien store.
        for(var i=0;i<localUsers.length;i++){
            var lu=localUsers[i];
            if(!lu || !lu.Id || lu.AvatarTagVerified===true) continue;
            var tok=tokenByUserId[lu.Id] || "";
            if(!tok) continue;
            (function(uid, token, remembered){
                _fetchUser(uid, token, function(full){
                    if(seq!==_loadSeq || srv!==serverUrl || !full) return;
                    _ensureLocalUser(full, remembered);
                });
            })(lu.Id, tok, lu.Remember===true);
        }
    }
    function _fetchUser(uid, token, cb){
        if(!uid){ if(cb) cb(null); return; }
        try {
            Jellyfin.fetchUser(serverUrl, token, uid,
                function(u){ if(cb) cb(u); },
                function(){ if(cb) cb(null); }
            );
        } catch(e){
            if(cb) cb(null);
        }
    }
    function _acceptAuthenticatedUser(res, done, rememberRequested){
        res = res || {}
        var raw = res.raw || res
        var user = raw.User || raw.user || {}
        var token = res.accessToken || res.AccessToken || raw.AccessToken || ""
        var uid = res.userId || user.Id || user.id || ""

        if (!token || !uid) {

            return false
        }

        // Un login réussi crée un nouveau contexte d'authentification. Aucun résultat
        // du profil précédent ne doit survivre dans le cache partagé du bridge.
        _clearApiCaches()


        var tag = user.PrimaryImageTag || (user.ImageTags && user.ImageTags.Primary) || ""
        tokenByUserId[uid] = token

        // La case du formulaire est l'autorité. Elle est cochée par défaut, mais
        // une désactivation ne doit jamais être réécrasée par le mode confort.
        var rememberToken = (rememberRequested === undefined || rememberRequested === null)
                ? (page.rememberProfileOnLogin === true)
                : (rememberRequested === true)
        if (_maximumSessionSecurityEnabled() || persistentSessionTokensAllowed !== true)
            rememberToken = false

        try {
            // Synchronise le réglage global pour les anciennes versions/UI, mais
            // la persistance reste décidée par la case du profil. Le résultat du
            // write Settings ne doit donc pas pouvoir annuler silencieusement ce
            // choix si le coffre UserStore est disponible.
            if (rememberToken) {
                _setRememberSessionEnabled(true)
                rememberToken = _rememberTokenRequested()
            }
        } catch(eRemember) { rememberToken = false }

        _ensureLocalUser(user, rememberToken)
        try {
            Store.addOrUpdateUser({
                serverUrl: serverUrl,
                serverName: serverInfo.name || "Jellyfin",
                serverId: serverInfo.id || "",
                version: serverInfo.version || "",
                userId: uid,
                userName: user.Name || user.Username || "",
                imageTag: tag,
                imageTagOwnerId: tag ? uid : "",
                accessToken: token,
                remember: rememberToken
            })
            Store.setActive(serverUrl, uid)

        } catch(e) {

        }
        _fetchUser(uid, token, function(full){

            if (full) _ensureLocalUser(full, rememberToken)

            if (done) done()
        })
        return true
    }
    function _avatarKey(userId, tag) {
        return String(userId || "") + "|" + String(tag || "")
    }
    function _avatarKnownMissing(userId, tag) {
        var key = _avatarKey(userId, tag)
        return key.length > 1 && _missingAvatarKeys[key] === true
    }
    function _markAvatarMissing(userId, tag) {
        var key = _avatarKey(userId, tag)
        if (key.length <= 1 || _missingAvatarKeys[key] === true) return
        // Réassigner l'objet déclenche les bindings QML qui consultent la map.
        var next = ({})
        for (var k in _missingAvatarKeys)
            if (_missingAvatarKeys[k] === true) next[k] = true
        next[key] = true
        _missingAvatarKeys = next
    }

    function _avatarUrl(userId, tag, animated){
        // /UserImage ne transporte aucun token dans l'URL. Un profil mémorisé
        // sans session active peut donc conserver son avatar sur LoginPage.
        // Si le serveur refuse cette ressource sans authentification, le delegate
        // retombera simplement sur son fallback local.
        if(!userId || !tag) return "";
        try {
            if(animated)
                return Store.animatedAvatarUrl(page.serverUrl, userId, tag);
            return Store.staticAvatarUrl(page.serverUrl, userId, tag);
        } catch(e) {}
        var base=_join(page.serverUrl,"/UserImage")+"?UserId="+encodeURIComponent(userId);
        if(animated)
            return base+"&tag="+encodeURIComponent(tag);
        return base+"&tag="+encodeURIComponent(tag)+"&format=jpg";
    }
    // Login TV : une seule rangée de profils. Jusqu'à 6 comptes restent visibles
    // simultanément ; au-delà, la ListView défile horizontalement au D-Pad.
    // 190 px garde les avatars 160 px et leur zoom de focus dans une largeur
    // totale de 1140 px, adaptée au viewport 1280x720 de la Freebox.
    readonly property int profileCarouselVisibleSlots: 6
    readonly property int profileCarouselCellWidth: 190
    function _profileCarouselWidth(){
        var count = Math.max(1, Math.min(profileCarouselVisibleSlots, usersModel.length));
        return count * profileCarouselCellWidth;
    }
    function ensureProfileCarouselFocus(){
        if(loginOverlay.active || quickOverlay.active || serverOverlay.active) return;
        if(!loading && usersModel.length>0){
            if(userCarousel.currentIndex<0) userCarousel.currentIndex=0;
            userCarousel.forceActiveFocus();
            userCarousel.ensureCurrentVisible(false);
        }
    }
    function _setDefaultFocus(){
        if(loginOverlay.active || quickOverlay.active || serverOverlay.active || loading) return;
        Qt.callLater(function(){
            if(loginOverlay.active || quickOverlay.active || serverOverlay.active || loading) return;
            if(usersModel.length > 0) ensureProfileCarouselFocus();
            else addCard.forceActiveFocus();
        });
    }

    /* ==== Store ==== */
    function hydrateFromStore() {
        try {
            var active = Store.getActive ? (Store.getActive() || {}) : {};
            var su = page.serverUrl || active.serverUrl || "";
            if (!su && Store.listServers) {
                var savedServers = Store.listServers() || [];
                if (savedServers.length > 0)
                    su = savedServers[0].serverUrl || savedServers[0].url || "";
            }
            var list = (Store.listUsers ? Store.listUsers(su) : []) || [];
            if (list.length===0 && !su && Store.listUsers) list = Store.listUsers() || [];
            var loc = [];
            page.tokenByUserId = ({});
            for (var i=0;i<list.length;i++){
                var it=list[i];
                if (!it || !it.userId) continue;

                // Toujours restaurer les métadonnées non sensibles du profil.
                // Pour un profil explicitement mémorisé, UserStore réinjecte ici
                // le token depuis le coffre persistant après redémarrage. Sinon,
                // seul un éventuel token du cache RAM de la session courante existe.
                var storedTag = String(it.imageTag || "")
                var tagOwnedByProfile = !!(storedTag && it.imageTagOwnerId === it.userId)
                loc.push({
                    Id: it.userId,
                    Name: it.userName || "Profil",
                    PrimaryImageTag: storedTag,
                    // Les stores antérieurs à cette correction ne possèdent pas
                    // imageTagOwnerId : leur tag ne déclenche aucune requête avant
                    // validation par /Users/Public ou /Users/{id}.
                    AvatarTagVerified: !storedTag || tagOwnedByProfile,
                    Remember: it.remember === true
                });
                if (it.accessToken)
                    page.tokenByUserId[it.userId] = it.accessToken;
            }
            page.localUsers = loc;
            _recomputeModel();
            if (!page.serverUrl && active.serverUrl) page.serverUrl = _normalizeContextServerUrl(active.serverUrl);
            if ((!page.serverInfo.name || !page.serverInfo.version) && active.serverName) {
                page.serverInfo = ({ name: active.serverName||"Jellyfin", version: active.version||"", id: active.serverId||"" });
            }

        } catch(e){

        }
    }

    /* ==== Oubli complet de l'appareil ==== */
    property bool _forgetDeviceArmed: false
    Timer {
        id: forgetDeviceArmTimer
        interval: 4500
        repeat: false
        onTriggered: page._forgetDeviceArmed = false
    }

    function _forgetThisDeviceNow(){
        _clearApiCaches()
        _clearTrustedLanHosts()
        var host = _findShellHost()
        if (host && typeof host.forgetThisDevice === "function") {
            var shellForgetDone = false
            try {
                host.forgetThisDevice()
                shellForgetDone = true
            } catch(eHostForget) {}

            if (shellForgetDone) {
                // Le Shell purge toute la session puis positionne normalement
                // currentPage sur serverpage.qml. On repasse néanmoins par son
                // routeur afin de forcer un chargement propre si le Loader est
                // resté vide pendant la réinitialisation des Settings.
                try {
                    if (typeof host.handleNavigation === "function")
                        host.handleNavigation("serverpage.qml")
                    else if ("currentPage" in host)
                        host.currentPage = "serverpage.qml"
                    else
                        requestNavigation("serverpage.qml")
                } catch(eHostNav) {
                    requestNavigation("serverpage.qml")
                }
                return
            }
        }

        try { if (Store.forgetThisDevice) Store.forgetThisDevice(); else Store.clearAll() } catch(e0) {}
        _requestSettingsUpdate({ clearSensitiveSettings: true })
        tokenByUserId = ({})
        localUsers = []
        serverUsers = []
        usersModel = []
        serverInfo = ({ name: "", version: "", id: "" })
        serverUrl = ""
        _clearSensitiveNavContext()
        requestNavigation("serverpage.qml")
    }

    function requestForgetThisDevice(){
        if (!_forgetDeviceArmed) {
            _forgetDeviceArmed = true
            forgetDeviceArmTimer.restart()
            return
        }
        _forgetDeviceArmed = false
        forgetDeviceArmTimer.stop()
        _forgetThisDeviceNow()
    }

    /* ==== Déconnexion ==== */
    function logoutAndRemoveById(uid){
        if (!uid) return;
        _clearApiCaches()
        _debounceAfterLogout(420)
        _swallowNextBackRelease()
        var token = page.tokenByUserId[uid] || ""
        var srv   = page.serverUrl || ""
        try { Jellyfin.logout(srv, token, function(){}, function(){ /* pas critique */ }) } catch(e){}
        try { Store.removeUser(srv, uid); } catch(e){}
        _clearLastSessionIfProfileMatches(srv, uid)
        try { delete page.tokenByUserId[uid]; } catch(e){ page.tokenByUserId[uid] = ""; }
        page.localUsers = (page.localUsers || []).filter(function(it){ return it && it.Id !== uid; });
        _recomputeModel();
        Qt.callLater(function(){
            if (page.usersModel.length > 0) ensureProfileCarouselFocus();
            else addCard.forceActiveFocus();
        });
        Qt.callLater(hydrateFromStore);
    }

    /* ==== Chargement (via jellyfinBridge) ==== */
    property int  _loadSeq: 0
    Timer {
        id: loadDataDebounce
        interval: 120
        repeat: false
        onTriggered: page._doLoadData()
    }
    function loadData(){
        loadDataDebounce.restart();
    }
    function _doLoadData(){
        var seq = ++_loadSeq;
        var srv = serverUrl;
        loading=true; errorText="";
        if(!srv || srv.indexOf("http")!==0){
            loading=false; _recomputeModel(); _setDefaultFocus(); return;
        }
        var secErr = _securityErrorForServerUrl(srv)
        // Un nom LAN court non encore approuve peut uniquement effectuer le
        // probe public /System/Info/Public. Aucun secret n'est envoyé ici.
        if (secErr.length > 0 && !_isShortLanServerUrl(srv)) {
            loading=false; errorText=secErr; serverUsers=[];
            _recomputeModel(); _setDefaultFocus();
            return;
        }
        try {
            Jellyfin.pingServer(srv,
                function(info){
                    if (seq !== _loadSeq || srv !== serverUrl) return;
                    if (!Jellyfin.isValidPublicSystemInfo(info)) {
                        loading = false
                        errorText = "La réponse reçue n'est pas un serveur Jellyfin valide."
                        serverUsers = []
                        _recomputeModel()
                        _setDefaultFocus()
                        return
                    }
                    _trustValidatedLanHost(srv)
                    serverInfo = ({
                        name:    info.ServerName || info.ProductName || "Jellyfin",
                        version: info.Version || "",
                        id:      info.Id || info.ServerId || ""
                    });
                    _rememberServerUrl(srv, serverInfo);
                    _loadLoginDisclaimerForServer(srv)
                    Jellyfin.fetchPublicUsers(srv,
                        function(users){
                            if (seq !== _loadSeq || srv !== serverUrl) return
                            _reconcilePublicUsers(users || [])
                            loading=false; _recomputeModel(); _setDefaultFocus()
                            _validateNonPublicStoredAvatars(seq, srv)
                        },
                        function(err){
                            if (seq !== _loadSeq || srv !== serverUrl) return
                            loading=false; serverUsers=[]; _recomputeModel(); _setDefaultFocus()

                        })
                },
                function(errS){
                    if (seq !== _loadSeq || srv !== serverUrl) return;
                    loading=false; errorText="Impossible de contacter le serveur ("+errS+").";
                    _recomputeModel(); _setDefaultFocus();

                }
            );
        } catch(e){
            if (seq !== _loadSeq || srv !== serverUrl) return;
            loading=false; errorText="Erreur interne.";
            _recomputeModel(); _setDefaultFocus();

        }
    }
    Component.onCompleted: {

        page._hydrateSensitiveContextFromShared();
        var securityPolicyReady = false;
        try {
            if (fbx && Jellyfin.setFbx) {
                Jellyfin.setFbx(fbx);
            }
        } catch(e){}
        try {
            if (Jellyfin && typeof Jellyfin.setClientIdentity === "function" &&
                    ClientId && typeof ClientId.info === "function")
                Jellyfin.setClientIdentity(ClientId.info())
        } catch(e){}
        try { Store.init(page); } catch(e){}
        securityPolicyReady = _syncStoreSecurityPolicy();
        if (securityPolicyReady) {
            try {
                var active = Store.getActive ? (Store.getActive() || {}) : {};
                if (!page.serverUrl && active.serverUrl) {
                    page.serverUrl = _normalizeContextServerUrl(active.serverUrl);
                }
                if (!page.serverUrl && Store.listServers) {
                    var ss = Store.listServers() || [];
                    if (ss.length > 0)
                        page.serverUrl = _normalizeContextServerUrl(ss[0].serverUrl || ss[0].url || "");
                }
            } catch(e){}
            hydrateFromStore();
        }
        splashBg.scheduleRefresh("completed");
        loadData();

    }
    onServerUrlChanged: {
        // Couvre aussi les changements injectés directement par ShellPage.
        _rotateSecurityContextForServer(serverUrl)
        _clearApiCaches();
        if (_syncStoreSecurityPolicy())
            hydrateFromStore();
        splashBg.scheduleRefresh("serverUrlChanged");
        loadData();
    }
    onFbxChanged: {
        try {
            if (fbx && Jellyfin.setFbx) {
                Jellyfin.setFbx(fbx);
            }
        } catch(e){}
        _syncServerOverlayDiscovery();
        try { Store.init(page); } catch(e){}
        if (_syncStoreSecurityPolicy())
            hydrateFromStore();
        splashBg.scheduleRefresh("fbxChanged");
        loadData();
    }

    /* ================== OVERLAYS (Server / QuickConnect / Login) ================== */
    function openServerOverlay(){
        serverOverlay.active = true
        Qt.callLater(_syncServerOverlayDiscovery)
    }
    Loader {
        id: serverOverlay
        anchors.fill: parent
        z: 250
        active: false
        visible: active
        source: "ServerOverlay.qml"
        onLoaded: {
            if (!item) return;
            if (item.discoveryResultsChanged) item.discoveryResultsChanged.connect(function(list) {
                page.discoveredServersCache = page._copyServerList(list)
            })
            if (item.applyHostContext) item.applyHostContext(page._serverOverlayContext())
            if (item.closeRequested) item.closeRequested.connect(function () {
                serverOverlay.active = false;
                page.forceActiveFocus();
                Qt.callLater(page._setDefaultFocus);
            });
            if (item.chooseServer) item.chooseServer.connect(function (s) {
                if (s && s.url) {
                    var secErr = page._securityErrorForServerUrl(s.url)
                    if (secErr.length > 0 && !page._isShortLanServerUrl(s.url)) {
                        page.errorText = secErr;
                        page.loading = false;
                        page._recomputeModel();
                        page._setDefaultFocus();
                    } else {
                        page._clearApiCaches();
                        page._applyServerUrlFromContext(s.url);
                        page._rememberServerUrl(s.url, s);
                        page.loadData();
                    }
                }
                serverOverlay.active = false;
                page.forceActiveFocus();
                Qt.callLater(page._setDefaultFocus);
            });
            if (item.removeSavedServer) item.removeSavedServer.connect(function (url) {
                page._removeSavedServerUrl(url);
                page._refreshSavedServersOverlay();
            });
            if (item.enterAddressRequested) item.enterAddressRequested.connect(function () {
                serverOverlay.active = false;
                page.requestNavigation("serverpage.qml");
            });
            if (item.activate) item.activate(page._serverOverlayContext())
            else if (item.forceActiveFocus) item.forceActiveFocus();
        }
        onActiveChanged: {
            if (active) {
                Qt.callLater(function() {
                    if (serverOverlay.item && serverOverlay.item.activate)
                        serverOverlay.item.activate(page._serverOverlayContext())
                })
            } else {
                if (item && item.deactivate) item.deactivate()
                Qt.callLater(page._setDefaultFocus)
            }
        }
    }
    function closeQuickConnect(){ quickOverlay.active=false; }
    function openQuickConnectSafe(){
        if (loginOverlay.active) {
            page._swallowNextBackRelease();
            if (loginOverlay.item && loginOverlay.item.close) {
                loginOverlay.item.close("quick");
            } else {
                _overlaySwitchTarget = "quick";
                _clearLoginPasswordIfLoaded();
                loginOverlay.active = false;
            }
        } else { quickOverlay.active = true; }
    }

    /* ===== QuickConnect via jellyfinBridge ===== */
    Component {
        id: quickConnectComponent
        FocusScope {
            id: qc
            width: parent ? parent.width : 1280
            height: parent ? parent.height : 720
            focus: true
            property string code: ""
            property string secret: ""
            property bool   busy: false
            property string err: ""
            property real   startMs: 0.0
            property int    expiryMs: 8*60*1000
            property int    remainingMs: 0
            property bool   authPollInFlight: false
            property real   authPollStartedMs: 0.0
            property int    authPollTimeoutMs: 7500
            property int    authPollSeq: 0
            property int    authAttemptSeq: 0
            property var    authPollHandle: null
            function mmss(ms){
                var s = Math.max(0, Math.ceil(ms/1000));
                var m = Math.floor(s/60);
                var r = s % 60;
                function z(n){return (n<10?"0":"")+n;}
                return z(m)+":"+z(r);
            }
            function _cancelAuthPoll(reason){
                authAttemptSeq++
                authPollInFlight = false
                authPollStartedMs = 0
                authPollWatchdog.stop()
                var h = authPollHandle
                authPollHandle = null
                try {
                    if (h && typeof h.cancel === "function")
                        h.cancel(reason || "quickconnect-cancelled")
                } catch(e0) {}
            }
            function resetState(){
                authPollSeq++
                _cancelAuthPoll("quickconnect-reset")
                code=""; secret=""; err="";
                startMs=Date.now();
                remainingMs = expiryMs;
            }
            function initiate(){
                busy=true; resetState();
                Jellyfin.quickConnectInitiate(page.serverUrl,
                    function(resp){
                        code=(resp.Code||resp.code||"");
                        secret=(resp.Secret||resp.secret||"");
                        busy=false;
                        if(!secret||!code){ err="Réponse QuickConnect invalide."; return; }
                        pollTimer.start();
                        countdownTick.start();
                        Qt.callLater(function(){ regenBtn.forceActiveFocus(); circleTimer.requestPaint(); });
                    },
                    function(e){
                        busy=false;
                        err=(e==="http_404"?"QuickConnect indisponible.":("Init échouée ("+e+")."));

                        Qt.callLater(function(){ regenBtn.forceActiveFocus(); });
                    }
                );
            }
            function _finishAuthAttempt(flowSeq, attemptSeq){
                if (flowSeq !== authPollSeq || attemptSeq !== authAttemptSeq)
                    return false
                authPollHandle = null
                authPollInFlight = false
                authPollStartedMs = 0
                authPollWatchdog.stop()
                return true
            }
            function tryAuth(){
                if(!secret || busy || authPollInFlight) return
                if(Date.now()-startMs > expiryMs){
                    err="Le code a expiré. Régénérez."
                    pollTimer.stop()
                    _cancelAuthPoll("quickconnect-expired")
                    return
                }
                var flowSeq = authPollSeq
                var attemptSeq = ++authAttemptSeq
                authPollInFlight = true
                authPollStartedMs = Date.now()
                authPollWatchdog.restart()
                authPollHandle = Jellyfin.quickConnectTryAuthenticate(page.serverUrl, secret,
                    function(res){
                        if (!_finishAuthAttempt(flowSeq, attemptSeq)) {
                            return
                        }
                        pollTimer.stop()
                        countdownTick.stop()
                        if (!page._acceptAuthenticatedUser(res, function(){
                            qc.closeQuickConnect()
                            Qt.callLater(page._setDefaultFocus)
                        }, page.rememberProfileOnLogin)) err = "Réponse d’authentification incomplète."
                    },
                    function(e){
                        if (!_finishAuthAttempt(flowSeq, attemptSeq)) {
                            return
                        }
                        if (e==="pending") { /* attente normale : prochain poll dans 5 s */ }
                        else if (e==="invalid") {
                            err="Code expiré/invalide. Régénérez."
                            pollTimer.stop()
                        } else {

                        }
                    }
                )
            }
            function backToLogin(){
                page._swallowNextBackRelease();
                page._overlaySwitchTarget = "login";
                authPollSeq++
                _cancelAuthPoll("quickconnect-back")
                pollTimer.stop(); countdownTick.stop();
                quickOverlay.active = false;
            }
            Timer { id: pollTimer; interval: 5000; running: false; repeat: true; onTriggered: tryAuth() }
            Timer {
                id: authPollWatchdog
                interval: Math.max(5500, qc.authPollTimeoutMs)
                repeat: false
                running: false
                onTriggered: {
                    if (!qc.authPollInFlight) return
                    qc._cancelAuthPoll("quickconnect-poll-timeout")
                    if (qc.secret && !qc.busy && (Date.now()-qc.startMs) < qc.expiryMs)
                        Qt.callLater(qc.tryAuth)
                }
            }
            Timer {
                id: countdownTick
                interval: 1000; running: false; repeat: true
                onTriggered: {
                    if(!secret){ remainingMs = 0; return; }
                    var left = expiryMs - (Date.now() - startMs);
                    remainingMs = Math.max(0, left);
                    circleTimer.requestPaint();
                    if (remainingMs === 0) {
                        pollTimer.stop();
                        initiate(); // auto-régénération
                    }
                }
            }
            Rectangle {
                anchors.fill: parent
                color: "#000000"
                opacity: page.uiMenuShadeOpacity
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onClicked: {}
                }
            }
            Rectangle {
                id: quickConnectPanel
                width: Math.round(parent.width * 0.56)
                height: parent.height
                color: page.uiMenuPanel
                anchors.left: parent.left
                anchors.top: parent.top

                Rectangle {
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    width: 1
                    color: "#242424"
                }

                Column {
                    anchors.left: parent.left; anchors.leftMargin: 96
                    anchors.top: parent.top; anchors.topMargin: 72
                    spacing: 24; width: parent.width * 0.8
                    Column { spacing: 2
                        Text { textFormat: Text.PlainText; text: "QuickConnect"; color: "white"; font.pixelSize: 56; font.bold: true }
                        Text { textFormat: Text.PlainText; text: "(Connexion rapide)"; color: page.uiTextSecondary; font.pixelSize: 26 }
                    }
                    Text { textFormat: Text.PlainText; text: "Appuyez sur Retour pour revenir à la connexion par mot de passe."; color: page.uiTextSecondary; font.pixelSize: 18 }
                    Row {
                        id: codeRow
                        spacing: 24
                        anchors.horizontalCenter: parent.horizontalCenter
                        Text { textFormat: Text.PlainText;
                            id: codeText
                            text: qc.code || "— — — —"
                            color: "white"; font.pixelSize: 64; font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Item {
                            id: circleTimer
                            width: 84
                            height: 84
                            readonly property real frac: Math.max(
                                0,
                                Math.min(1, qc.expiryMs > 0 ? (qc.remainingMs / qc.expiryMs) : 0)
                            )
                            // Rollback du compte à rebours circulaire QuickConnect.
                            // La valeur suit le tick d'une seconde avec une interpolation courte,
                            // afin d'éviter un arc qui avance par gros à-coups.
                            property real displayedFrac: frac
                            Behavior on displayedFrac {
                                NumberAnimation {
                                    duration: 520
                                    easing.type: Easing.OutCubic
                                }
                            }
                            function requestPaint() {
                                countdownRing.requestPaint()
                            }
                            onDisplayedFracChanged: countdownRing.requestPaint()
                            onWidthChanged: countdownRing.requestPaint()
                            onHeightChanged: countdownRing.requestPaint()
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 7
                                radius: width / 2
                                color: "#171717"
                                border.width: 1
                                border.color: "#505050"
                                antialiasing: true
                            }
                            Canvas {
                                id: countdownRing
                                anchors.fill: parent
                                antialiasing: true
                                onPaint: {
                                    var ctx = getContext("2d")
                                    var cx = width * 0.5
                                    var cy = height * 0.5
                                    var lineW = 6
                                    var radius = Math.max(1, Math.min(width, height) * 0.5 - lineW * 0.5 - 2)
                                    var startAngle = -Math.PI * 0.5
                                    var endAngle = startAngle + Math.PI * 2 * circleTimer.displayedFrac
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.lineWidth = lineW
                                    ctx.lineCap = "round"
                                    // Rail discret du cercle complet.
                                    ctx.beginPath()
                                    ctx.strokeStyle = "#383838"
                                    ctx.arc(cx, cy, radius, 0, Math.PI * 2, false)
                                    ctx.stroke()
                                    // Temps restant, depuis le sommet et dans le sens horaire.
                                    if (circleTimer.displayedFrac > 0.001) {
                                        ctx.beginPath()
                                        ctx.strokeStyle = "#FFFFFF"
                                        ctx.arc(cx, cy, radius, startAngle, endAngle, false)
                                        ctx.stroke()
                                    }
                                }
                                Component.onCompleted: requestPaint()
                            }
                            Text { textFormat: Text.PlainText;
                                anchors.centerIn: parent
                                text: qc.mmss(qc.remainingMs)
                                color: "#ffffff"
                                font.pixelSize: 17
                                font.bold: true
                            }
                        }
                    }
                    Rectangle {
                        id: regenBtn
                        width: 280; height: 54; radius: 18
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: activeFocus ? page.uiFocus : page.uiSurfaceRaised
                        border.width: activeFocus ? 0 : 1
                        border.color: page.uiBorder
                        focus: true
                        scale: activeFocus ? page.uiButtonFocusScale : 1.0
                        transform: Translate {
                            y: regenBtn.activeFocus ? -page.uiFocusLiftPx : 0
                            Behavior on y { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
                        }
                        Behavior on scale { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 90 } }
                        Keys.onReturnPressed: { pollTimer.stop(); countdownTick.stop(); qc.initiate(); }
                        Keys.onEnterPressed:  { pollTimer.stop(); countdownTick.stop(); qc.initiate(); }
                        Keys.onPressed: { if (event.key===Qt.Key_Left || event.key===Qt.Key_Right) event.accepted=true; }
                        MouseArea { anchors.fill: parent; onClicked: { pollTimer.stop(); countdownTick.stop(); qc.initiate(); } }
                        Text {
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: "Régénérer le code"
                            color: regenBtn.activeFocus ? "#000000" : page.uiText
                            font.pixelSize: 18
                            font.bold: regenBtn.activeFocus
                            Behavior on color { ColorAnimation { duration: 90 } }
                        }
                    }
                    Text { textFormat: Text.PlainText; text: qc.err; color: "#ffb4b4"; font.pixelSize: 16; visible: qc.err.length>0 }
                }
            }
            Keys.onPressed: {
                if (event.key===Qt.Key_Back || event.key===Qt.Key_Escape) {
                    qc.backToLogin();
                    event.accepted = true;
                }
            }
            function closeQuickConnect(){
                authPollSeq++
                _cancelAuthPoll("quickconnect-close")
                pollTimer.stop(); countdownTick.stop();
                quickOverlay.active=false;
                page.forceActiveFocus();
                Qt.callLater(page._setDefaultFocus);
            }
            Component.onCompleted: initiate()
        }
    }
    Loader {
        id: quickOverlay
        anchors.fill: parent
        z: 300
        active: false
        visible: active
        sourceComponent: quickConnectComponent
        onActiveChanged: {
            if (active && item && item.forceActiveFocus) item.forceActiveFocus();
            if (!active) {
                if (page._overlaySwitchTarget === "login") {
                    Qt.callLater(function(){ page._overlaySwitchTarget = ""; loginOverlay.active = true; });
                } else { Qt.callLater(page._setDefaultFocus); }
            }
        }
    }

    /* ================== OVERLAY CONNEXION ================== */
    function openLogin(){
        page._swallowNextBackRelease()
        page.rememberProfileOnLogin = true
        loginOverlay.active = true
    }
    function openLoginForUser(name){
        page._swallowNextBackRelease()
        page.rememberProfileOnLogin = true
        loginOverlay.active = true
        Qt.callLater(function(){
            try {
                if (!loginOverlay.item) return
                if (loginOverlay.item.prepareForUser)
                    loginOverlay.item.prepareForUser(name || "")
            } catch(e) {}
        })
    }
    function _clearLoginPasswordIfLoaded(){
        try { if (loginOverlay.item && loginOverlay.item._clearPassword) loginOverlay.item._clearPassword(); } catch(e) {}
    }
    Component {
        id: fieldComponent
        FocusScope {
            id: field
            width: 560; height: 60
            property alias text: input.text
            property string label: ""
            property bool   password: false
            property Item   upTarget: null
            property Item   downTarget: null
            property var    consumeBack: null
            property var    syncTarget: null
            property string syncProp: ""
            onActiveFocusChanged: if (activeFocus) hit.forceActiveFocus()
            KeyNavigation.up:   upTarget
            KeyNavigation.down: downTarget
            Keys.onUpPressed:   { if (upTarget)   upTarget.forceActiveFocus();   event.accepted = true; }
            Keys.onDownPressed: { if (downTarget) downTarget.forceActiveFocus(); event.accepted = true; }
            Rectangle {
                id: fieldSurface
                anchors.fill: parent
                radius: 18
                readonly property bool focused: hit.activeFocus || input.activeFocus
                color: focused ? page.uiSurfaceRaised : page.uiSurface
                border.width: focused ? 2 : 1
                border.color: focused ? page.uiFocus : page.uiBorder
                Behavior on color { ColorAnimation { duration: 100 } }
                Behavior on border.color { ColorAnimation { duration: 100 } }
            }
            Text { textFormat: Text.PlainText;
                id: placeholder
                text: field.label
                anchors.left: parent.left; anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                color: page.uiTextMuted
                font.pixelSize: 16
                visible: !input.activeFocus && field.text.length === 0
            }
            Text { textFormat: Text.PlainText;
                id: display
                anchors.left: parent.left;  anchors.leftMargin: 18
                anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideRight
                color: "white"
                font.pixelSize: 20
                text: field.password && field.text.length>0 ? Array(field.text.length+1).join("•") : field.text
                visible: !input.activeFocus && field.text.length > 0
            }
            FbxBase.Clickable {
                id: hit
                anchors.fill: parent
                focus: true
                onClicked: input.forceActiveFocus()
                Keys.onReturnPressed: input.forceActiveFocus()
                Keys.onEnterPressed:  input.forceActiveFocus()
                KeyNavigation.up:   field.upTarget
                KeyNavigation.down: field.downTarget
                Keys.onUpPressed:   { if (field.upTarget)   field.upTarget.forceActiveFocus();   event.accepted=true; }
                Keys.onDownPressed: { if (field.downTarget) field.downTarget.forceActiveFocus(); event.accepted=true; }
            }
            TextInput {
                id: input
                anchors.left: parent.left;  anchors.leftMargin: 18
                anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: 20
                height: Math.round(font.pixelSize * 1.4)
                visible: activeFocus
                focus: false
                clip: true
                color: "white"
                selectionColor: "#666666"
                cursorVisible: true
                cursorDelegate: Rectangle { width: 2; height: Math.round(input.font.pixelSize * 1.15); color: "white"; radius: 1; anchors.verticalCenter: parent.verticalCenter }
                horizontalAlignment: Text.AlignLeft
                echoMode: field.password ? TextInput.Password : TextInput.Normal
                inputMethodHints: Qt.ImhNoPredictiveText
                onTextChanged: {
                    if (field.syncTarget && field.syncProp.length > 0 && field.syncTarget[field.syncProp] !== text)
                        field.syncTarget[field.syncProp] = text;
                }
                function submit(){
                    Qt.inputMethod.hide();
                    if (field.downTarget) field.downTarget.forceActiveFocus();
                    else hit.forceActiveFocus();
                }
                onActiveFocusChanged: { if (activeFocus) Qt.inputMethod.show(); else Qt.inputMethod.hide(); }
                onAccepted: submit()
                Keys.onReturnPressed: submit()
                Keys.onEnterPressed:  submit()
                Keys.onUpPressed:   { Qt.inputMethod.hide(); if (field.upTarget)   field.upTarget.forceActiveFocus();   event.accepted=true; }
                Keys.onDownPressed: { Qt.inputMethod.hide(); if (field.downTarget) field.downTarget.forceActiveFocus(); event.accepted=true; }
                Keys.onBackPressed: {
                    Qt.inputMethod.hide();
                    if (field.consumeBack) field.consumeBack();
                    hit.forceActiveFocus();
                    event.accepted=true;
                }
            }
        }
    }
    Component {
        id: loginOverlayComponent
        FocusScope {
            id: login
            width: parent ? parent.width : 1280
            height: parent ? parent.height : 720
            focus: true
            property string userText: ""
            property string passText: ""
            property string err: ""
            property bool   busy: false
            // Même volet latéral que ServerPage : ouverture/fermeture glissée,
            // en gardant le Loader vivant jusqu'à la fin de l'animation.
            property bool panelShown: false
            property bool closing: false
            property string closeTarget: ""
            readonly property int panelAnimationMs: 220
            // Choix local au formulaire, coché par défaut. Il ne modifie pas
            // directement les Settings Freebox : la persistance est appliquée
            // seulement après une authentification réussie.
            property bool rememberChoice: page.rememberProfileOnLogin
            property bool maximumSecurityChoice: false
            property double _lastRememberToggleMs: 0

            function refreshSecurityChoices(){
                maximumSecurityChoice = page._maximumSessionSecurityEnabled()
                if (maximumSecurityChoice) {
                    rememberChoice = false
                    page.rememberProfileOnLogin = false
                } else {
                    rememberChoice = page.rememberProfileOnLogin === true
                }
                try {
                    if (passField && passField.item)
                        passField.item.downTarget = rememberSessionToggle
                    if (maximumSecurityChoice && rememberSessionToggle.activeFocus)
                        btnLogin.forceActiveFocus()
                } catch(e0) {}
            }
            function toggleRememberChoice(){
                if (page.persistentSessionTokensAllowed !== true || maximumSecurityChoice)
                    return
                // Clickable + Keys peuvent tous deux être émis par certains firmwares.
                // Ce petit latch évite un double-toggle dans le même appui OK.
                var now = Date.now()
                if (now - _lastRememberToggleMs < 120) return
                _lastRememberToggleMs = now
                rememberChoice = !rememberChoice
                page.rememberProfileOnLogin = rememberChoice
            }
            function prepareForUser(name) {
                userText = String(name || "")
                passText = ""
                err = ""
                try { if (userField && userField.item) userField.item.text = userText } catch(e0) {}
                _clearPassword()
                Qt.callLater(function(){
                    try {
                        if (passField && passField.item)
                            passField.item.forceActiveFocus()
                    } catch(e1) {}
                })
            }
            property bool backJustHandled: false
            function consumeBack() { backJustHandled = true; backGuard.restart(); }
            Timer { id: backGuard; interval: 300; repeat: false; running: false; onTriggered: login.backJustHandled = false }
            function _loginString(v) {
                return String(v === undefined || v === null ? "" : v);
            }
            function _loginUserName() {
                return _loginString(userText).replace(/^\s+|\s+$/g, "");
            }
            function _loginPasswordValue() {
                return _loginString(passText);
            }
            function _authErrorToString(e) {
                if (e === undefined || e === null) return "network";
                if (typeof e === "string") return e;
                try {
                    if (e.code) return String(e.code);
                    if (e.ErrorCode) return String(e.ErrorCode);
                    if (e.errorCode) return String(e.errorCode);
                    if (e.Message) return "server_message";
                    if (e.message) return "server_message";
                } catch(ex) {}
                return "network";
            }
            function _authenticateManual(loginName, loginPass, ok, ko) {
                try {
                    Jellyfin.authenticate(page.serverUrl, loginName, loginPass, ok, ko)
                } catch(e) {
                    ko(e)
                }
            }
            function _handleAuthSuccess(res) {
                busy = false
                try {
                    if (!page._acceptAuthenticatedUser(res, login.close, login.rememberChoice))
                        err = "Réponse d’authentification incomplète."
                } catch(e) { err = "Erreur d’analyse de la réponse." }
            }
            function _handleAuthError(e) {
                busy = false;
                var code = _authErrorToString(e);
                err = code.indexOf("401") >= 0 ? "Identifiant ou mot de passe invalide." : ("Connexion refusée (" + code + ").");

            }
            function doLogin() {
                if (busy) return;
                if (!page.serverUrl) { err = "Aucun serveur."; return; }
                var secErr = page._securityErrorForServerUrl(page.serverUrl)
                if (secErr.length > 0) { err = secErr; return; }
                var loginName = _loginUserName();
                if (!loginName) { err = "Veuillez saisir un identifiant."; return; }
                var loginPass = _loginPasswordValue();
                busy = true; err = "";
                _authenticateManual(loginName, loginPass, _handleAuthSuccess, _handleAuthError);
            }
            function _clearPassword() {
                passText = "";
                try { if (passField && passField.item) passField.item.text = ""; } catch(e) {}
            }
            function close(target) {
                if (closing) return;
                _clearPassword();
                Qt.inputMethod.hide();
                closing = true;
                closeTarget = String(target || "");
                panelShown = false;
                closeAnimationTimer.restart();
            }
            Timer {
                id: closeAnimationTimer
                interval: login.panelAnimationMs
                repeat: false
                onTriggered: {
                    if (login.closeTarget === "quick")
                        page._overlaySwitchTarget = "quick";
                    loginOverlay.active = false;
                }
            }
            Rectangle {
                id: loginShade
                anchors.fill: parent
                color: "#000000"
                opacity: login.panelShown ? page.uiMenuShadeOpacity : 0.0
                Behavior on opacity {
                    NumberAnimation {
                        duration: login.panelShown ? 180 : login.panelAnimationMs
                        easing.type: login.panelShown ? Easing.OutCubic : Easing.InCubic
                    }
                }
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            }
            Rectangle {
                id: loginPanel
                width: Math.round(parent.width * 0.56)
                height: parent.height
                // Transparence restaurée, identique aux autres menus.
                color: page.uiMenuPanel
                clip: true
                anchors.left: parent.left
                anchors.top: parent.top
                transform: Translate {
                    x: login.panelShown ? 0 : -loginPanel.width
                    Behavior on x {
                        NumberAnimation {
                            duration: login.panelAnimationMs
                            easing.type: login.panelShown ? Easing.OutCubic : Easing.InCubic
                        }
                    }
                }
                Rectangle {
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    width: 1
                    color: "#242424"
                }
                Column {
                    anchors.left: parent.left; anchors.leftMargin: 68
                    anchors.top: parent.top; anchors.topMargin: 54
                    spacing: 14; width: parent.width - 108
                    Text { text: "Connexion"; textFormat: Text.PlainText; color: page.uiText; font.pixelSize: 44; font.bold: true }
                    Text { text: "Identifiez-vous sur " + (page.serverInfo.name || "Jellyfin"); textFormat: Text.PlainText; color: page.uiTextSecondary; font.pixelSize: 18 }
                    Loader {
                        id: userField
                        sourceComponent: fieldComponent
                        onLoaded: {
                            item.label = "Nom d'utilisateur"
                            item.password = false
                            item.text = login.userText
                            item.consumeBack = login.consumeBack
                            item.syncTarget = login
                            item.syncProp = "userText"
                        }
                    }
                    Loader {
                        id: passField
                        sourceComponent: fieldComponent
                        onLoaded: {
                            item.label = "Mot de passe"
                            item.password = true
                            item.upTarget = userField.item
                            item.text = login.passText
                            item.consumeBack = login.consumeBack
                            item.syncTarget = login
                            item.syncProp = "passText"
                        }
                    }

                    FbxBase.Clickable {
                        id: rememberSessionToggle
                        width: 560
                        height: 52
                        focus: false
                        enabled: page.persistentSessionTokensAllowed === true
                                 && !login.maximumSecurityChoice
                        opacity: enabled ? 1.0 : 0.48

                        KeyNavigation.up: passField.item
                        KeyNavigation.down: btnLogin

                        onClicked: login.toggleRememberChoice()
                        Keys.onReturnPressed: { login.toggleRememberChoice(); event.accepted = true }
                        Keys.onEnterPressed:  { login.toggleRememberChoice(); event.accepted = true }
                        Keys.onPressed: {
                            if (event.key === Qt.Key_Select || event.key === Qt.Key_Okay) {
                                login.toggleRememberChoice()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                                event.accepted = true
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 16
                            color: rememberSessionToggle.activeFocus
                                   ? page.uiSurfaceRaised : "transparent"
                            border.width: rememberSessionToggle.activeFocus ? 2 : 0
                            border.color: page.uiFocus
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Mémoriser ce profil"
                            textFormat: Text.PlainText
                            color: page.uiText
                            font.pixelSize: 17
                            font.bold: rememberSessionToggle.activeFocus
                        }

                        Rectangle {
                            id: rememberTrack
                            width: 46
                            height: 26
                            radius: 13
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            color: login.rememberChoice ? page.uiFocus : "#2B2B2B"
                            border.width: login.rememberChoice ? 0 : 1
                            border.color: page.uiBorderStrong
                            Behavior on color { ColorAnimation { duration: 110 } }

                            Rectangle {
                                id: rememberKnob
                                width: 20
                                height: 20
                                radius: 10
                                y: 3
                                x: login.rememberChoice ? (rememberTrack.width - width - 3) : 3
                                color: login.rememberChoice ? "#000000" : "#BEBEBE"
                                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }
                        }
                    }

                    Row {
                        id: btnRow
                        spacing: 16

                        Rectangle {
                            id: btnLogin
                            width: 238
                            height: 54
                            radius: 18
                            color: activeFocus ? page.uiFocus : page.uiSurfaceRaised
                            border.width: activeFocus ? 0 : 1
                            border.color: page.uiBorder
                            focus: true
                            scale: activeFocus ? page.uiButtonFocusScale : 1.0
                            transform: Translate {
                                y: btnLogin.activeFocus ? -page.uiFocusLiftPx : 0
                                Behavior on y { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
                            }
                            Behavior on scale { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 90 } }

                            KeyNavigation.up: rememberSessionToggle
                            KeyNavigation.right: btnQuick
                            Keys.onReturnPressed: login.doLogin()
                            Keys.onEnterPressed:  login.doLogin()
                            MouseArea { anchors.fill: parent; onClicked: login.doLogin() }

                            Text {
                                anchors.centerIn: parent
                                text: login.busy ? "Connexion…" : "Se connecter"
                                textFormat: Text.PlainText
                                color: btnLogin.activeFocus ? "#000000" : page.uiText
                                font.pixelSize: 18
                                font.bold: btnLogin.activeFocus
                                Behavior on color { ColorAnimation { duration: 90 } }
                            }
                        }

                        Rectangle {
                            id: btnQuick
                            width: 306
                            height: 54
                            radius: 18
                            color: activeFocus ? page.uiFocus : "transparent"
                            border.width: 1
                            border.color: activeFocus ? page.uiFocus : page.uiBorderStrong
                            scale: activeFocus ? page.uiButtonFocusScale : 1.0
                            transform: Translate {
                                y: btnQuick.activeFocus ? -page.uiFocusLiftPx : 0
                                Behavior on y { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
                            }
                            Behavior on scale { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 90 } }

                            KeyNavigation.left: btnLogin
                            KeyNavigation.up: rememberSessionToggle
                            Keys.onReturnPressed: { page.openQuickConnectSafe(); }
                            Keys.onEnterPressed:  { page.openQuickConnectSafe(); }
                            MouseArea { anchors.fill: parent; onClicked: page.openQuickConnectSafe() }

                            Text {
                                anchors.centerIn: parent
                                text: "QuickConnect"
                                textFormat: Text.PlainText
                                color: btnQuick.activeFocus ? "#000000" : page.uiTextSecondary
                                font.pixelSize: 18
                                font.bold: btnQuick.activeFocus
                                Behavior on color { ColorAnimation { duration: 90 } }
                            }
                        }
                    }
                    Text { width: 640; text: login.err; textFormat: Text.PlainText; wrapMode: Text.WordWrap; color: "#ffb4b4"; font.pixelSize: 15; visible: login.err.length>0 }
                }
            }
            Keys.onPressed: {
                if (event.key===Qt.Key_Back || event.key===Qt.Key_Escape) {
                    login.consumeBack();
                    login.close();
                    event.accepted = true;
                }
            }
            Keys.onReleased: {
                if (event.key===Qt.Key_Back || event.key===Qt.Key_Escape) {
                    if (login.backJustHandled) { login.backJustHandled = false; event.accepted = true; return; }
                    if (page._suppressBackOnce) { page._suppressBackOnce = false; event.accepted = true; return; }
                    login.close(); event.accepted=true;
                }
            }
            Connections {
                target: page.settingsRef
                ignoreUnknownSignals: true
                // Sort de la pile du signal Settings Freebox avant de relire la
                // politique. Aucun write n'est effectué par refreshSecurityChoices().
                function onRememberJellyfinSessionChanged(){
                    Qt.callLater(function(){ if (login) login.refreshSecurityChoices() })
                }
                function onMaximumSessionSecurityChanged(){
                    Qt.callLater(function(){ if (login) login.refreshSecurityChoices() })
                }
            }
            Component.onCompleted: Qt.callLater(function(){
                login.panelShown = true;
                if (!page._maximumSessionSecurityEnabled())
                    page.rememberProfileOnLogin = true;
                login.refreshSecurityChoices();
                if (userField.item && passField.item) {
                    userField.item.downTarget = passField.item;
                    passField.item.upTarget   = userField.item;
                    passField.item.downTarget = rememberSessionToggle;
                    userField.item.forceActiveFocus();
                }
            })
        }
    }
    Loader {
        id: loginOverlay
        anchors.fill: parent
        z: 200
        active: false
        visible: active
        sourceComponent: loginOverlayComponent
        onActiveChanged: {
            if (active && item && item.forceActiveFocus) item.forceActiveFocus();
            if (!active) {
                if (page._overlaySwitchTarget === "quick") {
                    Qt.callLater(function(){ page._overlaySwitchTarget = ""; quickOverlay.active = true; });
                } else { Qt.callLater(page._setDefaultFocus); }
            }
        }
    }

    /* ================== UI PRINCIPALE ================== */
    Item {
        id: headerBar
        anchors.left: parent.left; anchors.leftMargin: 64
        anchors.right: parent.right; anchors.rightMargin: 64
        anchors.top: parent.top; anchors.topMargin: 44
        height: 32
        Text { textFormat: Text.PlainText;
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatTime(new Date(),"hh:mm"); color: page.uiTextSecondary; font.pixelSize: 22
            function _updateClock(){
                text = Qt.formatTime(new Date(),"hh:mm");
                var now = new Date();
                var nextMs = 61000 - ((now.getSeconds() * 1000) + now.getMilliseconds());
                clockTick.interval = Math.max(1000, nextMs);
                clockTick.restart();
            }
            Component.onCompleted: _updateClock()
            Timer {
                id: clockTick
                interval: 60000
                running: false
                repeat: false
                onTriggered: parent._updateClock()
            }
        }
    }
    Row {
        id: bottomBar
        visible: !page.loginBackdropOnly
        anchors.bottom: parent.bottom; anchors.bottomMargin: 116
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 18
        Rectangle {
            id: addCard
            width: 330; height: 72; radius: page.uiRadiusLarge
            color: activeFocus ? page.uiSurfaceRaised : page.uiSurface
            border.width: activeFocus ? 2 : 1
            border.color: activeFocus ? page.uiFocus : page.uiBorder
            focus: false // focus initial piloté par _setDefaultFocus()
            enabled: !loginOverlay.active && !quickOverlay.active && !serverOverlay.active
            scale: activeFocus ? page.uiCardFocusScale : 1.0
            transform: Translate {
                y: addCard.activeFocus ? -page.uiFocusLiftPx : 0
                Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 100 } }
            Keys.onReturnPressed: { if (page._postLogoutLatch || page._okSwallowUntilRelease) { event.accepted=true; return; } openLogin() }
            Keys.onEnterPressed:  { if (page._postLogoutLatch || page._okSwallowUntilRelease) { event.accepted=true; return; } openLogin() }
            Keys.onPressed: {
                if (page._postLogoutLatch || page._okSwallowUntilRelease) { event.accepted=true; return; }
                if (event.key===Qt.Key_Select) { openLogin(); event.accepted=true; }
                if (event.key===Qt.Key_Right)  { serverCard.forceActiveFocus(); event.accepted=true; }
                if (event.key===Qt.Key_Down)   { forgetDeviceCard.returnTarget = addCard; forgetDeviceCard.forceActiveFocus(); event.accepted=true; }
                if (event.key===Qt.Key_Up)     { if (usersModel.length>0) userCarousel.forceActiveFocus(); event.accepted=true; }
            }
            MouseArea { anchors.fill: parent; onClicked: { if (page._postLogoutLatch || page._okSwallowUntilRelease) return; openLogin() } }
            Row {
                anchors.fill: parent; anchors.margins: 14; spacing: 14
                Item {
                    width: 30; height: 30
                    Rectangle { x: 3; y: 2; width: 16; height: 16; radius: 8; color: "transparent"; border.width: 2; border.color: "#D0D0D0"; antialiasing: true }
                    Rectangle { x: 3; y: 25; width: 17; height: 2; radius: 1; color: "#D0D0D0" }
                    Rectangle { x: 24; y: 7; width: 2; height: 17; radius: 1; color: "#D0D0D0" }
                    Rectangle { x: 17; y: 14; width: 16; height: 2; radius: 1; color: "#D0D0D0" }
                }
                Text { textFormat: Text.PlainText; text: "Ajouter un compte"; color: "white"; font.pixelSize: 20 }
            }
        }
        Rectangle {
            id: serverCard
            width: 500; height: 72; radius: page.uiRadiusLarge
            color: activeFocus ? page.uiSurfaceRaised : page.uiSurface
            border.width: activeFocus ? 2 : 1
            border.color: activeFocus ? page.uiFocus : page.uiBorder
            focus: false // ne concurrence jamais le carrousel
            enabled: !loginOverlay.active && !quickOverlay.active && !serverOverlay.active
            scale: activeFocus ? page.uiCardFocusScale : 1.0
            transform: Translate {
                y: serverCard.activeFocus ? -page.uiFocusLiftPx : 0
                Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 100 } }
            Keys.onReturnPressed: { if (page._postLogoutLatch || page._okSwallowUntilRelease) { event.accepted=true; return; } openServerOverlay() }
            Keys.onEnterPressed:  { if (page._postLogoutLatch || page._okSwallowUntilRelease) { event.accepted=true; return; } openServerOverlay() }
            Keys.onPressed: {
                if (page._postLogoutLatch || page._okSwallowUntilRelease) { event.accepted=true; return; }
                if (event.key===Qt.Key_Select) { openServerOverlay(); event.accepted=true; }
                if (event.key===Qt.Key_Left)   { addCard.forceActiveFocus(); event.accepted=true; }
                if (event.key===Qt.Key_Down)   { forgetDeviceCard.returnTarget = serverCard; forgetDeviceCard.forceActiveFocus(); event.accepted=true; }
                if (event.key===Qt.Key_Up)     { if (usersModel.length>0) userCarousel.forceActiveFocus(); event.accepted=true; }
            }
            MouseArea { anchors.fill: parent; onClicked: { if (page._postLogoutLatch || page._okSwallowUntilRelease) return; openServerOverlay() } }
            Row {
                anchors.fill: parent; anchors.margins: 14; spacing: 14
                Item {
                    width: 28; height: 28
                    Rectangle { x: 6; y: 13; width: 16; height: 13; color: "transparent"; border.width: 2; border.color: "#D0D0D0" }
                    Rectangle { x: 5; y: 9; width: 15; height: 2; radius: 1; color: "#D0D0D0"; rotation: -35; transformOrigin: Item.Left }
                    Rectangle { x: 13; y: 4; width: 15; height: 2; radius: 1; color: "#D0D0D0"; rotation: 35; transformOrigin: Item.Left }
                    Rectangle { x: 12; y: 18; width: 4; height: 8; color: "transparent"; border.width: 1; border.color: "#D0D0D0" }
                }
                Column {
                    // Row disponible : 500 - 2*14 px de marges.
                    // On réserve explicitement l'icône, les espacements,
                    // le séparateur et les 90 px de la version.
                    spacing: 2
                    width: Math.max(120, serverCard.width - 189)

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: serverInfo.name || "Jellyfin"
                        color: page.uiText
                        font.pixelSize: 20
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: page.serverUrl
                        color: page.uiTextSecondary
                        font.pixelSize: 16
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    width: 1
                    height: 36
                    anchors.verticalCenter: parent.verticalCenter
                    color: page.uiBorder
                }

                Item {
                    width: 90
                    height: parent.height

                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 4
                        anchors.rightMargin: 2
                        textFormat: Text.PlainText
                        text: serverInfo.version || ""
                        color: page.uiTextMuted
                        font.pixelSize: 15
                        horizontalAlignment: Text.AlignRight
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    Rectangle {
        id: forgetDeviceCard
        visible: !page.loginBackdropOnly
        width: 276; height: 56; radius: 18
        anchors.top: bottomBar.bottom
        anchors.topMargin: 9
        anchors.horizontalCenter: parent.horizontalCenter
        property Item returnTarget: serverCard
        color: page._forgetDeviceArmed
               ? "#211416"
               : (activeFocus ? page.uiSurfaceFocus : page.uiSurface)
        border.width: activeFocus ? 2 : 1
        border.color: activeFocus
                      ? page.uiFocus
                      : (page._forgetDeviceArmed ? "#9A646A" : page.uiBorder)
        enabled: !loginOverlay.active && !quickOverlay.active && !serverOverlay.active
        scale: activeFocus ? 1.02 : 1.0
        transform: Translate {
            y: forgetDeviceCard.activeFocus ? -3 : 0
            Behavior on y { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
        }
        Behavior on scale { NumberAnimation { duration: 115; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 100 } }
        Keys.onReturnPressed: page.requestForgetThisDevice()
        Keys.onEnterPressed: page.requestForgetThisDevice()
        Keys.onPressed: {
            if (event.key === Qt.Key_Select) {
                page.requestForgetThisDevice()
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                var target = forgetDeviceCard.returnTarget
                if (target && target.forceActiveFocus) target.forceActiveFocus()
                else serverCard.forceActiveFocus()
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                addCard.forceActiveFocus()
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                serverCard.forceActiveFocus()
                event.accepted = true
            }
        }
        MouseArea { anchors.fill: parent; onClicked: page.requestForgetThisDevice() }
        Column {
            anchors.centerIn: parent; width: parent.width - 20; spacing: 3
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: page._forgetDeviceArmed ? "Confirmer l’oubli" : "Oublier cet appareil"
                textFormat: Text.PlainText
                color: "white"; font.pixelSize: 17; font.bold: true
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: page._forgetDeviceArmed ? "Appuyez encore sur OK" : "Efface profils et sessions"
                textFormat: Text.PlainText
                color: page._forgetDeviceArmed ? page.uiDanger : page.uiTextMuted; font.pixelSize: 12
            }
        }
    }

    Text {
        id: serverWelcomeMessage
        anchors.top: forgetDeviceCard.bottom
        anchors.topMargin: 9
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(860, parent.width - 140)
        height: visible ? Math.min(38, implicitHeight) : 0
        visible: !page.loginBackdropOnly && page.loginDisclaimer.length > 0
        text: page.loginDisclaimer
        textFormat: Text.PlainText
        color: page.uiTextMuted
        font.pixelSize: 14
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignTop
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
    }

    /* ===== Zone centrale ===== */
    Column {
        id: centerCol
        spacing: 42
        anchors.top: headerBar.bottom; anchors.topMargin: 34
        anchors.bottom: bottomBar.top; anchors.bottomMargin: 40
        anchors.horizontalCenter: parent.horizontalCenter
        Text { textFormat: Text.PlainText;
            text: "Qui regarde ?"
            color: page.uiText; font.pixelSize: 38; font.bold: true
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Column {
            spacing: 8
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !page.loginBackdropOnly && !loading && usersModel.length === 0
            Text { textFormat: Text.PlainText; text: "Nous n'avons trouvé aucun compte !"; color: page.uiTextSecondary; font.pixelSize: 22 }
            Text { textFormat: Text.PlainText; text: "Ajoutez un nouveau compte via « Ajouter un compte »."; color: page.uiTextMuted; font.pixelSize: 18 }
        }
        ListView {
            id: userCarousel
            width: page._profileCarouselWidth()
            height: 244
            anchors.horizontalCenter: parent.horizontalCenter
            model: usersModel
            orientation: ListView.Horizontal
            spacing: 0
            clip: true
            interactive: false
            visible: !page.loginBackdropOnly && !loading && usersModel.length > 0
            focus: false // attribué après stabilisation de loading/usersModel
            enabled: !loginOverlay.active && !quickOverlay.active && !serverOverlay.active
            keyNavigationWraps: false
            boundsBehavior: Flickable.StopAtBounds
            snapMode: ListView.SnapToItem

            // On ne déplace le viewport que lorsque le profil courant sortirait
            // des 6 emplacements visibles. Le déplacement est animé pour garder
            // un comportement de carrousel propre à la télécommande.
            property bool _animateNextScroll: true
            function _targetXForIndex(index) {
                if (index < 0 || count <= page.profileCarouselVisibleSlots) return 0
                var cell = page.profileCarouselCellWidth
                var left = contentX
                var itemLeft = index * cell
                var itemRight = itemLeft + cell
                var viewportRight = left + width
                var target = left
                if (itemLeft < left)
                    target = itemLeft
                else if (itemRight > viewportRight)
                    target = itemRight - width
                var maxX = Math.max(0, contentWidth - width)
                return Math.max(0, Math.min(maxX, target))
            }
            function ensureCurrentVisible(animated) {
                if (currentIndex < 0) return
                var target = _targetXForIndex(currentIndex)
                if (Math.abs(target - contentX) < 0.5) return
                carouselScroll.stop()
                if (animated) {
                    carouselScroll.from = contentX
                    carouselScroll.to = target
                    carouselScroll.restart()
                } else {
                    contentX = target
                }
            }
            NumberAnimation {
                id: carouselScroll
                target: userCarousel
                property: "contentX"
                duration: 170
                easing.type: Easing.OutCubic
            }
            onCurrentIndexChanged: {
                if (currentIndex >= 0)
                    Qt.callLater(function(){ userCarousel.ensureCurrentVisible(userCarousel._animateNextScroll) })
            }
            onCountChanged: {
                if (count <= 0) {
                    currentIndex = -1
                    contentX = 0
                } else {
                    if (currentIndex < 0) currentIndex = 0
                    if (currentIndex >= count) currentIndex = count - 1
                    Qt.callLater(function(){ userCarousel.ensureCurrentVisible(false) })
                }
            }
            Keys.onPressed: {
                if(event.key===Qt.Key_Down){ addCard.forceActiveFocus(); event.accepted=true; }
            }
            delegate: FocusScope {
                id: tile
                Keys.priority: Keys.BeforeItem
                width: page.profileCarouselCellWidth; height: 244
                z: ListView.isCurrentItem ? 100 : 0
                focus: ListView.isCurrentItem
                property var    u: modelData
                readonly property string uid:  (u && u.Id) ? u.Id : ""
                readonly property string name: (u && u.Name) ? u.Name : "Profil"
                readonly property string rawTag: (u && (u.PrimaryImageTag || (u.ImageTags && u.ImageTags.Primary))) ? (u.PrimaryImageTag || u.ImageTags.Primary) : ""
                readonly property bool avatarTagVerified: !!(u && u.AvatarTagVerified === true)
                readonly property string tag: avatarTagVerified ? rawTag : ""
                readonly property bool remembered: !!(u && u.Remember === true)
                property bool  _selecting: false
                property bool  _pressActive: false
                property bool  _armed: false
                property bool  _keyHeld: false
                property real  _armedAtMs: 0
                property real  _downAtMs: 0
                property real  _holdProgress: 0
                property int   _shortTapMs: 200
                property int   _preArmMs: 1000
                property int   _commitMs: 1000
                property int   _fallbackLongMs: 2000
                Timer { id: preArm; interval: tile._preArmMs; repeat: false
                    onTriggered: {
                        if (!tile._pressActive) return;
                        tile._armed = true;
                        tile._armedAtMs = Date.now();
                        commitTimer.start();
                        progressTick.start();
                        tile._holdProgress = 0;
                        holdOverlay.visible = true;
                    }
                }
                Timer { id: commitTimer; interval: tile._commitMs; repeat: false
                    onTriggered: {
                        var removeId = tile.uid
                        var shouldRemove = tile._pressActive && tile._armed && !!removeId
                        if (shouldRemove) page._swallowOkUntilRelease()
                        // logoutAndRemoveById() peut reconstruire le modèle et détruire
                        // ce delegate. Toujours nettoyer le press AVANT l'appel.
                        tile._resetPress()
                        if (shouldRemove) page.logoutAndRemoveById(removeId)
                    }
                }
                Timer { id: progressTick; interval: 100; repeat: true
                    onTriggered: {
                        if (!tile._pressActive || !tile._armed) { stop(); return; }
                        tile._holdProgress = Math.max(0, Math.min(1, (Date.now() - tile._armedAtMs) / Math.max(1, tile._commitMs)));
                    }
                }
                function _isOkKey(k){ return page._isOkKey ? page._isOkKey(k) : (k===Qt.Key_Return || k===Qt.Key_Enter || k===Qt.Key_Select || k===Qt.Key_Okay); }
                function _beginPress() {
                    if (page._postLogoutLatch || page._okSwallowUntilRelease) { return; }
                    if (!uid) { return; }
                    tile._downAtMs = Date.now();
                    tile._pressActive = true;
                    tile._armed = false;
                    preArm.restart();
                }
                function _endPress() {
                    if (!tile._pressActive) { return; }
                    var now = Date.now();
                    var dur = now - tile._downAtMs;
                    var selectedUid = tile.uid
                    if (tile._armed) {
                        var armedDur = now - tile._armedAtMs;
                        if (armedDur >= tile._commitMs || dur >= tile._fallbackLongMs) {
                            page._swallowOkUntilRelease();
                            tile._resetPress();
                            if (selectedUid) page.logoutAndRemoveById(selectedUid);
                            return;
                        }
                        tile._resetPress();
                        return;
                    }
                    if (dur >= tile._fallbackLongMs) {
                        page._swallowOkUntilRelease();
                        tile._resetPress();
                        if (selectedUid) page.logoutAndRemoveById(selectedUid);
                        return;
                    }
                    if (dur <= tile._shortTapMs) {
                        // selectThis() peut ouvrir un overlay ou déclencher une navigation.
                        // Nettoyer le delegate avant toute action susceptible de le détruire.
                        tile._resetPress();
                        tile.selectThis();
                        return;
                    }
                    tile._resetPress();
                }
                function _resetPress() {
                    tile._pressActive = false;
                    tile._armed = false;
                    preArm.stop();
                    commitTimer.stop();
                    progressTick.stop();
                    tile._holdProgress = 0;
                    holdOverlay.visible = false;
                }
                function selectThis(){
                    if(page._postLogoutLatch || page._okSwallowUntilRelease || tile._selecting)
                        return;
                    if(!uid) return;

                    var tok = page.tokenByUserId[uid] || "";

                    // Même serveur, autre profil : les résultats du profil précédent
                    // ne doivent jamais être réutilisés.
                    page._clearApiCaches();
                    try { Store.setActive(page.serverUrl, uid); } catch(e0){}

                    if(!tok){
                        page.openLoginForUser(name || "")
                        return
                    }

                    // Le token du coffre peut avoir été révoqué côté Jellyfin depuis
                    // le dernier lancement. On valide uniquement le profil choisi.
                    tile._selecting = true
                    page.requestHomeLoading(true)
                    try {
                        Jellyfin.validateToken(
                            page.serverUrl,
                            tok,
                            function(){
                                tile._selecting = false
                                var stored = page._storeSensitiveNavContextForUser(tok, uid, name, tag || "", tile.remembered)
                                if (stored)
                                    page.requestNavigation("HomePage.qml?ctx=1")
                                else {
                                    page.requestHomeLoading(false)
                                    page.openLoginForUser(name || "")
                                }
                            },
                            function(){
                                tile._selecting = false
                                page.requestHomeLoading(false)
                                try { if (Store.clearUserToken) Store.clearUserToken(page.serverUrl, uid) } catch(e1) {}
                                try { delete page.tokenByUserId[uid] } catch(e2) { page.tokenByUserId[uid] = "" }
                                page.openLoginForUser(name || "")
                            }
                        )
                    } catch(e3) {
                        tile._selecting = false
                        page.requestHomeLoading(false)
                        // Si la primitive de validation est indisponible, ne jamais
                        // contourner la sécurité avec un token non vérifié.
                        page.openLoginForUser(name || "")
                    }
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 10
                    Item {
                        id: avatarBox
                        width: 160; height: 160
                        transformOrigin: Item.Center
                        property bool currentOrFocus: (ListView.isCurrentItem || tile.activeFocus)
                        scale: currentOrFocus ? 1.08 : 1.0
                        Behavior on scale {
                            NumberAnimation {
                                duration: 140
                                easing.type: Easing.OutCubic
                            }
                        }
                        Item {
                            id: rawAvatar
                            anchors.fill: parent
                            property string avatarUid: uid
                            property string avatarTag: tag
                            property bool loadFailed: false
                            readonly property string sourceUrl:
                                page._avatarKnownMissing(avatarUid, avatarTag)
                                ? "" : page._avatarUrl(avatarUid, avatarTag, true)

                            function _resetAvatarState() {
                                loadFailed = page._avatarKnownMissing(avatarUid, avatarTag)
                            }

                            onAvatarUidChanged: _resetAvatarState()
                            onAvatarTagChanged: _resetAvatarState()

                            // Pipeline unique statique/GIF. AnimatedImage sait aussi afficher
                            // les avatars JPG/PNG et préserve les GIF animés utilisés par Jellyfin.
                            // cache:true évite de rouvrir /UserImage à chaque boucle du GIF.
                            AnimatedImage {
                                id: avatarAnim
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                source: rawAvatar.loadFailed ? "" : rawAvatar.sourceUrl
                                visible: status === AnimatedImage.Ready

                                onStatusChanged: {
                                    if (status === AnimatedImage.Error) {
                                        rawAvatar.loadFailed = true
                                        page._markAvatarMissing(rawAvatar.avatarUid, rawAvatar.avatarTag)
                                    } else if (status === AnimatedImage.Ready) {
                                        // Un delegate peut être recyclé après avoir affiché une image
                                        // statique. Forcer playing à Ready garantit que le GIF du
                                        // profil suivant démarre réellement.
                                        playing = true
                                    }
                                }
                            }

                            Item {
                                anchors.fill: parent
                                visible: !avatarAnim.visible
                                Rectangle {
                                    width: parent.width * 0.34
                                    height: width
                                    radius: width / 2
                                    color: "#BDBDBD"
                                    opacity: 0.82
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: parent.height * 0.20
                                }
                                Rectangle {
                                    width: parent.width * 0.62
                                    height: parent.height * 0.34
                                    radius: Math.min(width, height) * 0.35
                                    color: "#9A9A9A"
                                    opacity: 0.76
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: parent.height * 0.54
                                }
                            }
                        }
                        ShaderEffectSource {
                            id: avatarSrc
                            sourceItem: rawAvatar
                            // Le masque doit rester live pour un éventuel GIF.
                            // LoginPage ne conserve que quelques avatars et est détruite
                            // après navigation vers Home, donc ce coût reste borné.
                            live: avatarBox.visible && page.visible
                            hideSource: true
                            smooth: true
                        }
                        Rectangle { id: circleMask; anchors.fill: parent; radius: width/2; visible: false }
                        OpacityMask { anchors.fill: parent; source: avatarSrc; maskSource: circleMask; cached: false; antialiasing: true }
                        // Rollback du système de focus avatar validé avant redesign.
                        // Important : ne pas dépendre de userCarousel.activeFocus ici.
                        // Sur certaines chaînes FocusScope/ListView de la Freebox,
                        // le delegate conserve le focus alors que ListView.activeFocus
                        // n'est pas le signal visuel fiable attendu.
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: "transparent"
                            antialiasing: true
                            border.width: (ListView.isCurrentItem
                                           ? 3
                                           : (tile.activeFocus ? 2 : 0))
                            border.color: ListView.isCurrentItem
                                          ? "white"
                                          : (tile.activeFocus ? "white" : "transparent")
                            Behavior on border.width {
                                NumberAnimation { duration: 120 }
                            }
                            Behavior on border.color {
                                ColorAnimation { duration: 120 }
                            }
                        }
                        Item {
                            id: holdOverlay
                            anchors.centerIn: parent
                            width: 176
                            height: 176
                            visible: false

                            // Même anneau continu que le compte à rebours QuickConnect,
                            // adapté à la validation d'un appui long sur un profil.
                            property real displayedFrac: Math.max(0.0, Math.min(1.0, tile._holdProgress))
                            Behavior on displayedFrac {
                                NumberAnimation {
                                    duration: 90
                                    easing.type: Easing.Linear
                                }
                            }
                            onDisplayedFracChanged: holdProgressRing.requestPaint()
                            onWidthChanged: holdProgressRing.requestPaint()
                            onHeightChanged: holdProgressRing.requestPaint()
                            onVisibleChanged: holdProgressRing.requestPaint()

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 7
                                radius: width / 2
                                color: "#22000000"
                                border.width: 1
                                border.color: "#505050"
                                antialiasing: true
                            }
                            Canvas {
                                id: holdProgressRing
                                anchors.fill: parent
                                antialiasing: true
                                onPaint: {
                                    var ctx = getContext("2d")
                                    var cx = width * 0.5
                                    var cy = height * 0.5
                                    var lineW = 7
                                    var radius = Math.max(1, Math.min(width, height) * 0.5 - lineW * 0.5 - 2)
                                    var startAngle = -Math.PI * 0.5
                                    var endAngle = startAngle + Math.PI * 2 * holdOverlay.displayedFrac
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.lineWidth = lineW
                                    ctx.lineCap = "round"

                                    ctx.beginPath()
                                    ctx.strokeStyle = "#383838"
                                    ctx.arc(cx, cy, radius, 0, Math.PI * 2, false)
                                    ctx.stroke()

                                    if (holdOverlay.displayedFrac > 0.001) {
                                        ctx.beginPath()
                                        ctx.strokeStyle = "#FFFFFF"
                                        ctx.arc(cx, cy, radius, startAngle, endAngle, false)
                                        ctx.stroke()
                                    }
                                }
                                Component.onCompleted: requestPaint()
                            }
                        }
                    }
                    Text {
                        textFormat: Text.PlainText
                        text: name
                        color: page.uiText
                        font.pixelSize: 18
                        width: avatarBox.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                    }
                }
                Keys.onPressed: {
                    if (tile._isOkKey(event.key)) {
                        event.accepted = true;
                        if (event.isAutoRepeat) { return; }
                        if (!tile._keyHeld) {
                            tile._keyHeld = true;
                            tile._beginPress();
                        }
                    } else if (event.key===Qt.Key_Left) {
                        if (userCarousel.currentIndex > 0)
                            userCarousel.currentIndex = userCarousel.currentIndex - 1;
                        event.accepted = true;
                    } else if (event.key===Qt.Key_Right) {
                        if (userCarousel.currentIndex >= 0 && userCarousel.currentIndex < userCarousel.count - 1)
                            userCarousel.currentIndex = userCarousel.currentIndex + 1;
                        event.accepted = true;
                    } else if (event.key===Qt.Key_Down) { addCard.forceActiveFocus(); event.accepted = true; }
                }
                Keys.onReleased: {
                    if (tile._isOkKey(event.key)) {
                        event.accepted = true;
                        if (event.isAutoRepeat) { return; }
                        if (!tile._pressActive) { return; } // release fantôme
                        tile._keyHeld = false;
                        tile._endPress();
                    }
                }
            }
            highlight: Rectangle { color: "transparent"; border.width: 0 }
        }
    }
    Text { textFormat: Text.PlainText;
        anchors.left: parent.left; anchors.leftMargin: 64
        anchors.bottom: parent.bottom; anchors.bottomMargin: 28
        color: loading ? "#969696" : "#ffb4b4"
        font.pixelSize: 16
        text: loading ? "Connexion au serveur…" : (errorText || "")
        visible: !page.loginBackdropOnly && (loading || errorText!="")
    }

    /* ==== Bouclier d'entrée global ==== */
    FocusScope {
        id: inputShield
        anchors.fill: parent
        z: 9999
        visible: page._okSwallowUntilRelease || page._postLogoutLatch
        enabled: visible
        focus: visible
        onVisibleChanged: if (visible) { forceActiveFocus(); }
        Keys.onPressed: { event.accepted = true }
        Keys.onReleased: {
            if (page._okSwallowUntilRelease && _isOkKey(event.key)) {
                page._okSwallowUntilRelease = false
                event.accepted = true
                return
            }
            event.accepted = true
        }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            preventStealing: true
            hoverEnabled: true
            onPressed: { mouse.accepted = true }
            onClicked: {}
            onReleased: { mouse.accepted = true }
            onWheel: { wheel.accepted = true }
        }
    }
    Keys.onPressed: {
        if ((page._okSwallowUntilRelease || page._postLogoutLatch) && _isOkKey(event.key)) {
            event.accepted = true; return
        }
        if (loginOverlay.active || quickOverlay.active || serverOverlay.active) return;
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            // Login est la racine d’authentification. La touche reste consommée
            // sans exposer un signal que personne ne traite.
            event.accepted = true
        }
        if (event.key===Qt.Key_Up && usersModel.length>0) { userCarousel.forceActiveFocus(); event.accepted = true; }
    }
    Keys.onReleased: {
        if (page._okSwallowUntilRelease && _isOkKey(event.key)) {
            page._okSwallowUntilRelease = false
            event.accepted = true
            return
        }
    }
}
