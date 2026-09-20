// qml/pages/ShellPage.qml — Boot Splash → ServerPage → LoginPage (+ auto-restore + token check)
// + Playlist unique (Components.Playlist) partagée avec les pages et l’overlay
// + Retour focus *précis* depuis le player : propage l’ID courant à la page sous-jacente
// + Hints de saison/ordre transmis au playeroverlay (selectedSeasonId, seasonPageOrderIds)
// + Injection `shared` vers toutes les pages (persistance de focus detailSeriePage/seasonpage)
// + FIX nav: reload forcé quand on rouvre la même page
// + Intégration Application.Settings via properties `settings` + `saveSettingsRequested` + `restoreFromSettings()`
// QtQuick 2.15 only, aucun QtQuick Controls
//
// ✅ Version "no logs"
// ✅ FIX sécurité routes : ne jamais injecter accessToken/serverUrl/userId/userName/userImageTag
//    dans les query strings ; passage via ctx=1/shared.__redefinNavContext + Loader.
// ✅ MoviePage universel : injection libraryMode/browserTitle + restauration restoreIndex/restoreY.

import QtQuick 2.15
import fbx.system 1.0
import "../js/jellyfinBridge.js" as JellyfinBridge
import "../js/UserStore.js" as Users
import "../components" as Components
import "../js/clientId.js" as ClientId
import "../js/SafeLog.js" as SafeLog

FocusScope {
    id: shell
    width: 1920
    height: 1080
    focus: true

    /* ===================== NAVIGATION DE BASE ===================== */
    property string currentPage: "SplashPage.qml"
    property var    navStack: []
    property var    fbx
    property bool _pageLoadCurtainHold: false
    property int _pageLoadCurtainSeq: 0

    /* ===================== UPDATE CHECK ===================== */
    // Une seule requête distante par démarrage.
    // La version technique FreeStore sert à la comparaison ; displayVersion
    // est uniquement destinée à l'affichage utilisateur.
    property var _pendingUpdateInfo: null
    property bool _updateDialogShownForSession: false

    Components.UpdateManager {
        id: updateManager

        onUpdateAvailable: {
            shell._pendingUpdateInfo = ({
                version: version || "",
                displayVersion: displayVersion || version || "",
                channel: channel || "",
                notes: notes || "",
                releasedAt: releasedAt || "",
                localVersion: localVersion || ""
            })

            shell._tryShowPendingUpdate()
        }

        // En production, absence de mise à jour et erreurs réseau restent muettes.
        onNoUpdate: {
        }

        onCheckFailed: {
        }
    }

    Components.UpdateDialog {
        id: updateDialog

        anchors.fill: parent
        z: 5000

        onDismissed:
            shell._restoreFocusAfterUpdateDialog()

        onAccepted:
            shell._restoreFocusAfterUpdateDialog()
    }

    function _restoreFocusAfterUpdateDialog() {
        Qt.callLater(function() {
            if (shell.playerActive ||
                    shell.playerLaunchPending ||
                    shell._directPlayReloadPending) {
                return
            }

            if (pageLoadCurtain && pageLoadCurtain.visible)
                return

            try {
                if (pageLoader.item &&
                        pageLoader.item.forceActiveFocus) {
                    pageLoader.item.forceActiveFocus(
                                Qt.OtherFocusReason
                            )
                    return
                }
            } catch (e0) {}

            try {
                shell.forceActiveFocus(
                            Qt.OtherFocusReason
                        )
            } catch (e1) {}
        })
    }

    function _tryShowPendingUpdate() {
        if (!_pendingUpdateInfo ||
                _updateDialogShownForSession ||
                updateDialog.visible) {
            return
        }

        // Ne jamais superposer le dialogue au lecteur ni à un reload DirectPlay.
        if (playerActive ||
                playerLaunchPending ||
                _directPlayReloadPending) {
            return
        }

        var base =
                _baseOf(currentPage).toLowerCase()

        // Le Splash reste exclusivement consacré au boot.
        if (!base || base === "splashpage.qml")
            return

        if (pageLoader.status !== Loader.Ready ||
                !pageLoader.item) {
            return
        }

        // Attendre que le rideau global ait réellement libéré la page.
        if (pageLoadCurtain && pageLoadCurtain.visible)
            return

        updateDialog.availableVersion =
                String(
                    _pendingUpdateInfo.displayVersion ||
                    _pendingUpdateInfo.version ||
                    ""
                )

        updateDialog.channel =
                String(
                    _pendingUpdateInfo.channel ||
                    ""
                )

        updateDialog.releaseNotes =
                String(
                    _pendingUpdateInfo.notes ||
                    ""
                )

        updateDialog.localVersion =
                String(
                    _pendingUpdateInfo.localVersion ||
                    ""
                )

        _updateDialogShownForSession = true
        updateDialog.open()
    }

    // Le CircleDots global n'est autorisé qu'à partir d'une entrée réelle vers
    // HomePage. Toute la phase de boot/auth (Splash/Server/Login) reste donc
    // sans animation CircleDots. Après déconnexion, le verrou est réarmé.
    property bool _circleDotsRuntimeEnabled: false
    property bool _homeLaunchPending: false

    function _setHomeLaunchPending(active) {
        active = active === true
        _homeLaunchPending = active
        if (active)
            _circleDotsRuntimeEnabled = true
        else {
            var baseNow = _baseOf(currentPage).toLowerCase()
            if (baseNow === "splashpage.qml" || baseNow === "serverpage.qml" || baseNow === "loginpage.qml")
                _circleDotsRuntimeEnabled = false
        }
    }

    // Anti-flash inter-page :
    // Loader.Ready signifie seulement que l'objet QML existe. Certaines pages
    // arment leur vrai état de chargement dans le même tour ou juste après
    // (restauration de grille, fetch Jellyfin, backdrop, focus). On garde donc
    // le curtain jusqu'à ce que l'état "prêt" soit stable plusieurs probes.
    property double _pageCurtainReadySinceMs: 0
    property int _pageCurtainStableTicks: 0
    readonly property int pageCurtainReadyMinHoldMs: 180
    readonly property int pageCurtainStableTicksRequired: 2

    function _beginPageCurtainTransition() {
        _pageLoadCurtainSeq = (_pageLoadCurtainSeq + 1) | 0
        _pageLoadCurtainHold = true
        _pageCurtainReadySinceMs = 0
        _pageCurtainStableTicks = 0
        try { pageCurtainReleaseTimer.stop() } catch(e0) {}
    }

    function _prepareDetailCurtainBeforeNavigation(pageName) {
        var base = _baseOf(pageName).toLowerCase()
        if (!_circleDotsRuntimeEnabled) return
        if (base === "detailmoviepage.qml" || base === "detailseriepage.qml")
            _beginPageCurtainTransition()
    }

    function _schedulePageCurtainRelease(seq) {
        if (seq !== _pageLoadCurtainSeq) return
        if (!pageLoader || pageLoader.status !== Loader.Ready || !pageLoader.item) return
        if (!(_pageCurtainReadySinceMs > 0))
            _pageCurtainReadySinceMs = Date.now()
        _pageCurtainStableTicks = 0
        pageCurtainReleaseTimer.curtainSeq = seq
        if (!pageCurtainReleaseTimer.running)
            pageCurtainReleaseTimer.start()
    }

    Timer {
        id: pageCurtainReleaseTimer
        interval: 60
        repeat: true
        running: false
        property int curtainSeq: -1
        onTriggered: {
            if (curtainSeq !== shell._pageLoadCurtainSeq) {
                stop()
                return
            }
            if (!pageLoader || pageLoader.status !== Loader.Ready || !pageLoader.item) {
                shell._pageCurtainStableTicks = 0
                return
            }

            var elapsed = Date.now() - Number(shell._pageCurtainReadySinceMs || 0)
            if (elapsed < shell.pageCurtainReadyMinHoldMs)
                return

            if (shell._pageReportedLoading) {
                shell._pageCurtainStableTicks = 0
                return
            }

            shell._pageCurtainStableTicks++
            if (shell._pageCurtainStableTicks >= shell.pageCurtainStableTicksRequired) {
                stop()
                if (curtainSeq === shell._pageLoadCurtainSeq &&
                        pageLoader.status === Loader.Ready &&
                        !shell._pageReportedLoading) {
                    shell._pageLoadCurtainHold = false
                    shell._homeLaunchPending = false
                }
            }
        }
    }

    // État visuel remonté par la page courante. Le Loader QML peut être Ready
    // alors que Jellyfin, le backdrop ou le focus ne le sont pas encore.
    readonly property bool _pageReportedLoading: {
        var p = pageLoader ? pageLoader.item : null
        if (!p) return false
        try { if (p.hasOwnProperty("shellLoading")) return p.shellLoading === true } catch(e0) {}
        var base = _baseOf(currentPage).toLowerCase()
        return false
    }
    readonly property string _pageReportedLoadingError: {
        var p = pageLoader ? pageLoader.item : null
        try { if (p && p.hasOwnProperty("shellLoadingError")) return String(p.shellLoadingError || "") } catch(e0) {}
        return ""
    }

    // Le curtain global possède le focus pendant le chargement. À sa fermeture,
    // rendre explicitement le focus à la page évite qu'un focus restauré pendant
    // le curtain soit perdu visuellement.
    property int _pageFocusHandoffSeq: 0
    function _handoffFocusAfterPageCurtain() {
        var seq = ++_pageFocusHandoffSeq
        Qt.callLater(function() {
            if (seq !== shell._pageFocusHandoffSeq) return
            if (shell.playerActive || pageLoadCurtain.visible) return
            if (!pageLoader || pageLoader.status !== Loader.Ready || !pageLoader.item) return

            var p = pageLoader.item
            try {
                if (p.restoreFocusAfterShellCurtain
                        && typeof p.restoreFocusAfterShellCurtain === "function") {
                    if (p.restoreFocusAfterShellCurtain() !== false)
                        return
                }
            } catch(e0) {}

            try {
                if (p.forceActiveFocus)
                    p.forceActiveFocus(Qt.OtherFocusReason)
            } catch(e1) {}
        })
    }

    // Mode player Freebox transmis au routeur playback.
    // Valeurs attendues par JellyfinPlaybackRouter: "revolution", "devialet" ou "auto".
    property string playbackDeviceMode: "auto"
    property string playbackDeviceModel: ""

    // `shared` peut stocker des états inter-pages (ex: discoveredServers, __detailFocus, etc.)
    property var    shared: ({ discoveredServers: [] })
    onSharedChanged: {
        _installSharedNavApi()
        _installSharedDetailFocusApi()
    }

    // Injecté depuis main.qml : Settings Freebox (fbx.application.Settings via Application.Settings)
    property var settings
    signal saveSettingsRequested(var payload)

    // Hints doux issus d'Application.Settings (utilisés au boot)
    property var bootHints: ({
        serverUrl:  "",
        userId:     "",
        userName:   ""
    })

    function restoreFromSettings(s) {
        if (!s) return
        try {
            bootHints = {
                serverUrl:   _normalizeSessionServerUrl(s.serverUrl || ""),
                userId:      s.lastUserId      || "",
                userName:    s.lastUserName    || ""
            }
        } catch (e) {}
        _syncUserStoreSecurityPolicy(s)
    }

    /* ===================== FOCUS MEMORY ===================== */
    property var focusMemory: ({})

    // Ouvrir le sélecteur de profils depuis une page de contenu démarre un
    // nouveau cycle UI. L'identité/token courant restent disponibles pour
    // LoginPage, mais aucune position/focus d'une page précédente ne doit être
    // restaurée après le retour sur Home.
    function _resetUiFocusStateForProfilePicker() {
        focusMemory = ({})
        __pendingFocusId = ""
        __seasonHintId = ""
        __seasonHintOrderIds = []
        _fastHomeReturnRequestedAtMs = 0

        // Invalide un éventuel handoff différé posé avant la navigation.
        _pageFocusHandoffSeq++

        try {
            if (shared) {
                shared.__detailFocus = ({})
                shared.__focusState = ({})
                shared.__personPageFocus = ({})
                shared.__redefinFocus = ({})
                shared.__redefinPersonReturnContext = null
                shared.__redefinSeasonGuestReturn = null
                shared.__redefinDetailReturnRefresh = null
            }
        } catch(e0) {}
    }

    // Un seul watchdog pour toutes les transactions Jellyfin. Il dort lorsqu'il
    // n'existe aucune requête et évite donc un polling permanent sur CE4100.
    property bool _httpWatchdogArmed: false
    function _setHttpWatchdogActive(active) {
        active = active === true
        _httpWatchdogArmed = active
        try {
            // Pilotage explicite plutôt qu'un simple binding "running".
            // Sur Qt 5.15/Freebox, cela évite qu'un changement venant d'un
            // callback JS de bibliothèque reste sans réveiller le Timer QML.
            if (active) {
                if (!httpWatchdogTimer.running) httpWatchdogTimer.start()
            } else if (httpWatchdogTimer.running) {
                httpWatchdogTimer.stop()
            }
        } catch(e0) {}
    }
    function _configureHttpWatchdog() {
        try {
            if (JellyfinBridge && JellyfinBridge.setHttpWatchdogWake) {
                JellyfinBridge.setHttpWatchdogWake(function(active) {
                    try { if (shell) shell._setHttpWatchdogActive(active === true) } catch(eCb) {}
                })
            }
        } catch(e0) {}
    }
    Timer {
        id: httpWatchdogTimer
        interval: 500
        repeat: true
        running: false
        onTriggered: {
            try {
                var remaining = JellyfinBridge.sweepHttpWatchdogs(Date.now())
                if (!(remaining > 0))
                    shell._setHttpWatchdogActive(false)
            } catch(e0) {
                shell._setHttpWatchdogActive(false)
            }
        }
    }

    function _normalize(str){ return (str||"").trim() }
    function _normalizeSessionServerUrl(value) {
        try {
            if (JellyfinBridge && JellyfinBridge.normalizeServerUrl)
                return String(JellyfinBridge.normalizeServerUrl(value || "", false) || "")
        } catch(e0) {}
        return ""
    }
    function _baseOf(url) { return _normalize(url).split("?")[0] }
    function _qsOf(url)   {
        var s = _normalize(url)
        var p = s.indexOf("?")
        return (p >= 0) ? s.substring(p + 1) : ""
    }

    function extractParam(param, str) {
        var q = (String(str || "").split("?")[1] || "")
        if (!q.length) return ""
        var params = q.split("&")
        for (var i = 0; i < params.length; ++i) {
            var kv = params[i].split("=")
            if (kv[0] === param) return decodeURIComponent(kv[1] || "")
        }
        return ""
    }

    function buildUrl(page, params) {
        var qs = []
        for (var k in params) {
            if (params[k] !== undefined && params[k] !== null)
                qs.push(k + "=" + encodeURIComponent(params[k]))
        }
        return page + (qs.length ? ("?" + qs.join("&")) : "")
    }

    function setParam(url, key, value) {
        var base = _baseOf(url)
        var qs = _qsOf(url)
        var parts = qs ? qs.split("&") : []
        var out = []
        for (var i = 0; i < parts.length; ++i) {
            var k = parts[i].split("=")[0]
            if (k && k !== key && parts[i] !== "")
                out.push(parts[i])
        }
        out.push(key + "=" + encodeURIComponent(value))
        return base + (out.length ? ("?" + out.join("&")) : "")
    }

    function stripParams(url, keys) {
        var base = _baseOf(url)
        var qs = _qsOf(url)
        if (!qs) return base
        var parts = qs.split("&")
        var out = []
        for (var i = 0; i < parts.length; ++i) {
            var p = parts[i]
            if (!p) continue
            var k = p.split("=")[0]
            if (keys.indexOf(k) >= 0) continue
            out.push(p)
        }
        return base + (out.length ? ("?" + out.join("&")) : "")
    }

    function _isCtxRoute(url) {
        return extractParam("ctx", url) === "1"
    }

    function _stripSensitiveQueryForCtx(url) {
        if (!_isCtxRoute(url)) return url
        return stripParams(url, [
            "serverUrl",
            "accessToken",
            "userId",
            "userName",
            "userImageTag"
        ])
    }

    function _sharedNavContext() {
        try {
            return shared ? shared.__redefinNavContext : null
        } catch(e) {
            return null
        }
    }


    // API runtime unique de navigation sensible. Les pages gardent leurs décisions
    // de navigation/focus, mais ne recopient plus la plomberie ctx=1.
    function _clearSharedNavContext() {
        try {
            if (shared) shared.__redefinNavContext = null
            return true
        } catch(e) {}
        return false
    }

    function _navContextFresh(ctx, maxAgeMs) {
        if (!ctx) return false
        var maxAge = Number(maxAgeMs || 0)
        if (maxAge <= 0) return true
        var ts = Number(ctx.ts || 0)
        if (ts <= 0) return true
        var age = Date.now() - ts
        return age >= 0 && age <= maxAge
    }

    function _storeNavContextValues(values) {
        try {
            if (!shared) return false
            values = values || ({})
            shared.__redefinNavContext = ({
                accessToken: values.accessToken || "",
                userId: values.userId || "",
                serverUrl: values.serverUrl || "",
                userName: values.userName || "",
                userImageTag: values.userImageTag || "",
                fbx: values.fbx || null,
                remember: values.remember === true,
                forceServerUrl: values.forceServerUrl === true,
                sourcePage: values.sourcePage || "",
                personSource: values.personSource || "",
                personId: values.personId || "",
                ts: Date.now()
            })
            return true
        } catch(e) {}
        return false
    }

    function _storeNavContextFromTarget(target) {
        if (!target) return false
        try {
            return _storeNavContextValues({
                accessToken: target.accessToken || "",
                userId: target.userId || "",
                serverUrl: target.serverUrl || "",
                userName: target.userName || "",
                userImageTag: target.userImageTag || "",
                fbx: target.fbx || null,
                remember: target.remember === true || target.rememberProfileOnLogin === true
            })
        } catch(e) {}
        return false
    }

    function _storeServerNavContextFromTarget(target) {
        if (!target) return false
        try {
            return _storeNavContextValues({
                serverUrl: target.serverUrl || "",
                fbx: target.fbx || null,
                remember: false
            })
        } catch(e) {}
        return false
    }

    function _hydrateTargetFromSharedNav(target, overwrite, maxAgeMs, clearAlways) {
        if (!target) return false
        var ctx = _sharedNavContext()
        if (!ctx) return false
        if (!_navContextFresh(ctx, maxAgeMs)) {
            _clearSharedNavContext()
            return false
        }
        var changed = false
        var fields = ["accessToken", "userId", "serverUrl", "userName", "userImageTag"]
        try {
            for (var i = 0; i < fields.length; i++) {
                var key = fields[i]
                var value = ctx[key]
                if (value === undefined || value === null || String(value) === "") continue
                if (!(key in target)) continue
                var current = String(target[key] || "")
                if (overwrite === true ? current !== String(value) : current === "") {
                    target[key] = String(value)
                    changed = true
                }
            }
            if (("fbx" in target) && !target.fbx && ctx.fbx) {
                target.fbx = ctx.fbx
                changed = true
            }
        } catch(e) {}
        if (clearAlways === true || changed)
            _clearSharedNavContext()
        return changed
    }

    function _appendNavParam(url, key, value) {
        if (value === undefined || value === null || value === "") return url
        return url + (String(url).indexOf("?") >= 0 ? "&" : "?")
             + encodeURIComponent(String(key)) + "=" + encodeURIComponent(String(value))
    }

    function _navBaseForTarget(target, pageName) {
        _storeNavContextFromTarget(target)
        return String(pageName || "") + "?ctx=1"
    }

    function _navRouteForTarget(target, pageName, params) {
        var url = _navBaseForTarget(target, pageName)
        params = params || ({})
        for (var key in params) {
            try { if (!Object.prototype.hasOwnProperty.call(params, key)) continue } catch(e0) { continue }
            url = _appendNavParam(url, key, params[key])
        }
        return url
    }

    function _installSharedNavApi() {
        try {
            if (!shared) return false
            if (shared.__redefinNavApi && shared.__redefinNavApi.version === 2) return true
            shared.__redefinNavApi = ({
                version: 2,
                peek: function() { return shell._sharedNavContext() },
                clear: function() { return shell._clearSharedNavContext() },
                hydrate: function(target, overwrite, maxAgeMs, clearAlways) {
                    return shell._hydrateTargetFromSharedNav(target, overwrite === true, maxAgeMs || 0, clearAlways === true)
                },
                storeTarget: function(target) { return shell._storeNavContextFromTarget(target) },
                storeServerTarget: function(target) { return shell._storeServerNavContextFromTarget(target) },
                storeValues: function(values) { return shell._storeNavContextValues(values) },
                base: function(target, pageName) { return shell._navBaseForTarget(target, pageName) },
                append: function(url, key, value) { return shell._appendNavParam(url, key, value) },
                route: function(target, pageName, params) { return shell._navRouteForTarget(target, pageName, params) }
            })
            return true
        } catch(e) {}
        return false
    }

    /* ====== Focus persistant des fiches : stockage partagé borné ====== */
    function _detailFocusRoot() {
        if (!shared) return null
        if (!shared.__detailFocus) shared.__detailFocus = ({})
        return shared.__detailFocus
    }

    function _detailFocusSnapshotBucket() {
        var root = _detailFocusRoot()
        if (!root) return null
        if (!root.__snapshots) root.__snapshots = ({})
        return root.__snapshots
    }

    function _detailFocusArm(itemId, scope) {
        var root = _detailFocusRoot()
        itemId = String(itemId || "")
        if (!root || !itemId.length) return false
        if (!root.__arms) root.__arms = ({})
        JellyfinBridge.putBoundedMemory(root.__arms, itemId, ({
            scope: String(scope || ""),
            t: Date.now()
        }), 48)
        return true
    }

    function _detailFocusIsArmed(itemId) {
        var root = _detailFocusRoot()
        itemId = String(itemId || "")
        return !!(root && root.__arms && itemId.length && root.__arms[itemId])
    }

    function _detailFocusActiveScope(itemId) {
        var root = _detailFocusRoot()
        itemId = String(itemId || "")
        if (!root || !root.__arms || !itemId.length || !root.__arms[itemId]) return ""
        return String(root.__arms[itemId].scope || "").toLowerCase()
    }

    function _detailFocusDisarm(itemId) {
        var root = _detailFocusRoot()
        itemId = String(itemId || "")
        if (!root || !root.__arms || !itemId.length || !root.__arms[itemId]) return false
        delete root.__arms[itemId]
        return true
    }

    function _detailFocusPut(key, snapshot) {
        var bucket = _detailFocusSnapshotBucket()
        key = String(key || "")
        if (!bucket || !key.length || !snapshot) return false
        return JellyfinBridge.putBoundedMemory(bucket, key, snapshot, 48)
    }

    function _detailFocusGet(key) {
        var bucket = _detailFocusSnapshotBucket()
        key = String(key || "")
        return bucket && key.length && bucket[key] ? bucket[key] : null
    }

    function _detailFocusRemove(key) {
        var bucket = _detailFocusSnapshotBucket()
        key = String(key || "")
        if (!bucket || !key.length || !Object.prototype.hasOwnProperty.call(bucket, key)) return false
        delete bucket[key]
        return true
    }

    function _installSharedDetailFocusApi() {
        try {
            if (!shared) return false
            if (shared.__redefinDetailFocusApi && shared.__redefinDetailFocusApi.version === 2) return true
            shared.__redefinDetailFocusApi = ({
                version: 2,
                arm: function(itemId, scope) { return shell._detailFocusArm(itemId, scope) },
                isArmed: function(itemId) { return shell._detailFocusIsArmed(itemId) },
                activeScope: function(itemId) { return shell._detailFocusActiveScope(itemId) },
                disarm: function(itemId) { return shell._detailFocusDisarm(itemId) },
                put: function(key, snapshot) { return shell._detailFocusPut(key, snapshot) },
                get: function(key) { return shell._detailFocusGet(key) },
                remove: function(key) { return shell._detailFocusRemove(key) }
            })
            return true
        } catch(e) {}
        return false
    }

    function _isWanHttpServerUrl(url) {
        try {
            if (JellyfinBridge && JellyfinBridge.isWanHttpUrl)
                return JellyfinBridge.isWanHttpUrl(url) === true
        } catch(e0) {}
        try {
            if (Users && Users.isWanHttpUrl)
                return Users.isWanHttpUrl(url) === true
        } catch(e1) {}
        return false
    }

    function _tokenTransportAllowed(url) {
        var normalized = _normalizeSessionServerUrl(url)
        return !!normalized && !_isWanHttpServerUrl(normalized)
    }
    function _clearApiCaches(cancelInflightLeaders) {
        try {
            if (JellyfinBridge && typeof JellyfinBridge.clearApiCaches === "function")
                JellyfinBridge.clearApiCaches(cancelInflightLeaders === true)
        } catch(e) {}
        if (cancelInflightLeaders === true) {
            // Les snapshots contiennent des métadonnées d'un profil précis.
            // Ils ne doivent jamais traverser une vraie transition de session.
            try {
                if (shared) {
                    shared.__redefinDetailSnapshots = ({})
                    shared.__detailFocus = ({})
                }
            } catch(e2) {}
        }
    }

    function _clearTrustedLanHosts() {
        try {
            if (JellyfinBridge && typeof JellyfinBridge.clearTrustedLanHosts === "function")
                JellyfinBridge.clearTrustedLanHosts()
        } catch(e0) {}
    }

    function _forgetTrustedLanHost(value) {
        try {
            if (JellyfinBridge && typeof JellyfinBridge.forgetTrustedLanHost === "function")
                JellyfinBridge.forgetTrustedLanHost(value)
        } catch(e0) {}
    }

    function _isTrustedLanHostInAnyRegistry(value) {
        try {
            return !!(JellyfinBridge && typeof JellyfinBridge.isTrustedLanHost === "function"
                      && JellyfinBridge.isTrustedLanHost(value) === true)
        } catch(e0) {}
        return false
    }

    function _restoreTrustedLanHost(value) {
        if (!value) return
        try {
            if (JellyfinBridge && typeof JellyfinBridge.trustLanHost === "function")
                JellyfinBridge.trustLanHost(value)
        } catch(e0) {}
    }

    // Surface de coordination utilisée par LoginPage. Shell reste l'autorité
    // du contexte global et du registre des hôtes LAN explicitement approuvés.
    function securityClearApiCaches(cancelInflightLeaders) {
        _clearApiCaches(cancelInflightLeaders === true)
    }
    function securityClearTrustedLanHosts() { _clearTrustedLanHosts() }
    function securityForgetTrustedLanHost(value) { _forgetTrustedLanHost(value) }
    function securityIsTrustedLanHost(value) { return _isTrustedLanHostInAnyRegistry(value) }
    function securityTrustLanHost(value) { _restoreTrustedLanHost(value) }
    function securityRotateForServer(value) {
        var keep = value && _isTrustedLanHostInAnyRegistry(value)
        _clearTrustedLanHosts()
        if (keep) _restoreTrustedLanHost(value)
    }

    property string _securityContextServerUrl: ""
    function _syncTransientSecurityContext() {
        var nextServer = String(sessionServerUrl || "")
        if (nextServer !== _securityContextServerUrl) {
            // La validation de serverpage/ServerOverlay peut avoir approuvé le
            // nouveau nom LAN juste avant son injection. L'ancien registre est
            // purgé puis seule cette approbation déjà acquise est restaurée.
            var keepNewHost = nextServer && _isTrustedLanHostInAnyRegistry(nextServer)
            _clearTrustedLanHosts()
            if (keepNewHost) _restoreTrustedLanHost(nextServer)
        }
        _securityContextServerUrl = nextServer
    }

    readonly property int forcedServerNavContextMaxAgeMs: 30000

    function _isFreshForcedServerNavContext(ctx) {
        try {
            if (!ctx || ctx.forceServerUrl !== true || _isBadParam(ctx.serverUrl))
                return false

            var ts = Number(ctx.ts || 0)
            if (ts > 0) {
                var age = Date.now() - ts
                if (age < 0 || age > forcedServerNavContextMaxAgeMs)
                    return false
            }
            return true
        } catch(e) {
            return false
        }
    }

    function _adoptForcedServerNavContext() {
        try {
            var ctx = _sharedNavContext()
            if (!_isFreshForcedServerNavContext(ctx))
                return false

            _clearApiCaches(true)

            // Changement explicite de serveur depuis serverpage :
            // l'ancienne identité ne doit jamais suivre vers le nouveau serveur.
            sessionAccessToken = ""
            sessionUserId = ""
            var normalizedServer = _normalizeSessionServerUrl(ctx.serverUrl)
            if (!normalizedServer) return false
            sessionServerUrl = normalizedServer
            sessionUserName = ""
            sessionUserImageTag = ""
            sessionRemember = false
            return true
        } catch(e) {
            return false
        }
    }

    function _hasValidSharedNavContext() {
        try {
            var ctx = _sharedNavContext()
            return !!(ctx && ctx.accessToken && ctx.userId && ctx.serverUrl)
        } catch(e) {
            return false
        }
    }

    function _syncSessionFromSharedNavContext() {
        try {
            var ctx = _sharedNavContext()
            if (!ctx) return false
            if (!_isBadParam(ctx.serverUrl) && !_normalizeSessionServerUrl(ctx.serverUrl))
                return false

            // Un contexte server-only forcé est valide même sans token/userId.
            // Il doit être adopté avant toute restauration de l'ancienne session.
            if (_isFreshForcedServerNavContext(ctx))
                return _adoptForcedServerNavContext()

            var changed = false
            if (!_isBadParam(ctx.accessToken)) { sessionAccessToken = String(ctx.accessToken); changed = true }
            if (!_isBadParam(ctx.userId)) { sessionUserId = String(ctx.userId); changed = true }
            if (!_isBadParam(ctx.serverUrl)) {
                var normalizedServer = _normalizeSessionServerUrl(ctx.serverUrl)
                if (normalizedServer) { sessionServerUrl = normalizedServer; changed = true }
            }
            if (!_isBadParam(ctx.userName)) { sessionUserName = String(ctx.userName); changed = true }
            if (!_isBadParam(ctx.userImageTag)) { sessionUserImageTag = String(ctx.userImageTag); changed = true }
            if (ctx.remember !== undefined && ctx.remember !== null) { sessionRemember = (ctx.remember === true); changed = true }

            // Un contexte mémoire forgé ou restauré ne doit jamais propager un token vers HTTP WAN.
            if (!_isBadParam(sessionAccessToken) && _isWanHttpServerUrl(sessionServerUrl)) {
                sessionAccessToken = ""
                sessionRemember = false
                changed = true
            }

            return changed
        } catch(e) {
            return false
        }
    }

    function _hasValidSessionContext() {
        return !_isBadParam(sessionAccessToken)
            && !_isBadParam(sessionUserId)
            && !_isBadParam(sessionServerUrl)
            && _tokenTransportAllowed(sessionServerUrl)
    }

    function _storeServerContextForCtx(serverUrl) {
        try {
            serverUrl = _normalizeSessionServerUrl(serverUrl)
            if (!serverUrl) return false
            return _storeNavContextValues({
                serverUrl: serverUrl,
                fbx: fbx || null,
                remember: false
            })
        } catch(e) {
            return false
        }
    }

    function _storeSessionContextForCtx() {
        try {
            if (!shared) return false

            // serverpage vient de poser une nouvelle URL sans token/userId :
            // on l'adopte et surtout on ne la remplace pas par l'ancienne session.
            if (_adoptForcedServerNavContext())
                return true

            // Important : ne jamais écraser un contexte frais posé par LoginPage/page source.
            // Après sélection profil, la session Shell peut encore être vide à cet instant.
            if (_hasValidSharedNavContext()) {
                _syncSessionFromSharedNavContext()
                return true
            }

            if (!_hasValidSessionContext())
                return false

            sessionServerUrl = _normalizeSessionServerUrl(sessionServerUrl)
            return _storeNavContextValues({
                accessToken: sessionAccessToken || "",
                userId: sessionUserId || "",
                serverUrl: sessionServerUrl || "",
                userName: sessionUserName || "",
                userImageTag: sessionUserImageTag || "",
                fbx: fbx || null,
                remember: sessionRemember === true
            })
        } catch(e) {
            return false
        }
    }

    function _focusKeyFor(url) {
        var base = _baseOf(url).toLowerCase()
        if (base === "moviepage.qml") {
            var folder = extractParam("folderId", url) || ""
            // MoviePage porte désormais tous les navigateurs média. Le mode fait
            // donc partie de l'identité de la page afin qu'un focus Collections,
            // Séries ou Mixte ne puisse jamais écraser celui d'un autre mode.
            var mode = String(extractParam("libraryMode", url) || "movies").toLowerCase()
            if (mode !== "series" && mode !== "mixed" && mode !== "collections")
                mode = "movies"
            return base + "|" + folder + "|" + mode
        }
        return base
    }

    function _rememberFocus(url, index) {
        try {
            var key = _focusKeyFor(url)
            JellyfinBridge.putBoundedMemory(focusMemory, key, (index | 0), 48)
        } catch(e) {}
    }

    function _recallFocus(url) {
        try {
            var k = _focusKeyFor(url)
            if (focusMemory.hasOwnProperty(k))
                return focusMemory[k]
        } catch(e) {}
        return -1
    }

    function _shouldRestoreFocusOn(targetBase, currentBase) {
        targetBase  = (targetBase || "").toLowerCase()
        currentBase = (currentBase || "").toLowerCase()
        if (targetBase === "moviepage.qml")
            return (currentBase === "detailmoviepage.qml"
                    || currentBase === "detailseriepage.qml"
                    || currentBase === "detailcollectionpage.qml")
        return false
    }

    function _withStartIndexIfReturningFromDetails(targetUrl, currentBase) {
        var base = _baseOf(targetUrl).toLowerCase()
        if (!_shouldRestoreFocusOn(base, currentBase))
            return targetUrl
        var idx = _recallFocus(targetUrl)
        if (idx >= 0)
            return setParam(targetUrl, "startIndex", idx)
        return targetUrl
    }

    /* ===================== PLAYER OVERLAY / SESSION ========================= */
    property bool   playerActive: false
    // Préparation visuelle distincte de l'instanciation du player : la page
    // courante reste en mémoire le temps d'afficher une frame noire animée,
    // puis playeroverlay reste créé synchronement pour préserver IntelCE.
    property bool   playerLaunchPending: false
    property int    _playerLaunchSeq: 0
    property int    playerLaunchDelayMs: 70
    property bool   _directPlayReloadPending: false
    property int    directPlayReloadDelayMs: 180
    readonly property bool _playerOverlayReportsLoading: {
        if (!playerActive) return false
        try {
            if (!playerOverlayLoader || !playerOverlayLoader.item)
                return true
            if (playerOverlayLoader.item.videoLoadingRequested !== undefined)
                return playerOverlayLoader.item.videoLoadingRequested === true
        } catch(e) {}
        return false
    }
    property string playerItemId: ""
    property string playerAccessToken: ""
    property string playerUserId: ""
    property string playerServerUrl: ""
    property string playerItemTitle: ""
    property var    playerPlaylist: []
    property string playerPlaylistTitle: ""
    // Politique de démarrage de la playlist courante. DetailSeriePage utilise
    // true pour "Tout lire" / "Lecture aléatoire" : chaque épisode doit
    // commencer à 0 même si Jellyfin conserve une position de reprise.
    property bool   playerPlaylistStartAtZero: false

    function _requestPlayerLaunch() {
        if (playerActive) return false
        if (!playerItemId || !String(playerItemId).length) return false
        _captureDetailSnapshotFromPage()
        playerLaunchPending = true
        _playerLaunchSeq = (_playerLaunchSeq + 1) | 0
        playerLaunchTimer.launchSeq = _playerLaunchSeq
        playerLaunchTimer.restart()
        return true
    }

    function _cancelPendingPlayerLaunch() {
        _playerLaunchSeq = (_playerLaunchSeq + 1) | 0
        playerLaunchPending = false
        try { playerLaunchTimer.stop() } catch(e0) {}
    }

    function _requestDirectPlayPlayerReload() {
        if (!playerActive || !playerItemId || !String(playerItemId).length) return false
        _cancelPendingPlayerLaunch()
        _directPlayReloadPending = true
        // Ne pas détruire le Loader pendant l'émission du signal provenant de
        // PlayerOverlay. Le timer effectue d'abord l'unload au tour d'event
        // suivant, puis attend avant la recréation pour laisser intelce libérer
        // complètement son pipeline natif.
        directPlayReloadTimer.phase = 0
        directPlayReloadTimer.restart()
        return true
    }

    Timer {
        id: directPlayReloadTimer
        property int phase: 0 // 0=unload au prochain event, 1=reload après teardown
        interval: phase === 0 ? 1 : Math.max(80, shell.directPlayReloadDelayMs | 0)
        repeat: false
        onTriggered: {
            if (!shell._directPlayReloadPending) { phase = 0; return }
            if (phase === 0) {
                if (shell.playerActive) shell.playerActive = false
                phase = 1
                restart()
                return
            }
            phase = 0
            if (!shell.playerItemId || !String(shell.playerItemId).length) {
                shell._directPlayReloadPending = false
                return
            }
            // Réactiver d'abord le Loader pendant que le rideau de transition
            // reste affiché. Cela évite d'exposer la page détail entre la
            // destruction de l'ancien MediaPlayer et la création du nouveau.
            shell.playerActive = true
            Qt.callLater(function() {
                shell._directPlayReloadPending = false
            })
        }
    }

    Timer {
        id: playerLaunchTimer
        interval: Math.max(16, shell.playerLaunchDelayMs | 0)
        repeat: false
        property int launchSeq: 0
        onTriggered: {
            if (launchSeq !== shell._playerLaunchSeq || !shell.playerLaunchPending) return
            if (!shell.playerItemId || !String(shell.playerItemId).length) {
                shell.playerLaunchPending = false
                return
            }
            // La frame de transition a déjà été rendue. L'instanciation reste
            // volontairement synchrone à partir d'ici.
            shell.playerActive = true
            shell.playerLaunchPending = false
        }
    }

    /* ========= CONTEXTE SESSION (injecté vers Playlist au besoin) == */
    property string sessionAccessToken: ""
    property string sessionUserId: ""
    property string sessionServerUrl: ""
    property string sessionUserName: ""
    property string sessionUserImageTag: ""
    property bool sessionRemember: false

    // Empreinte uniquement mémoire servant à détecter les transitions de profil.
    // Le token n'est jamais dupliqué en clair dans cette propriété.
    property string _apiSessionScopeFingerprint: ""

    function _currentApiSessionFingerprint() {
        var token = String(sessionAccessToken || "")
        var user = String(sessionUserId || "")
        var server = String(sessionServerUrl || "")
        return SafeLog.shortHash(server) + "|"
             + SafeLog.shortHash(user) + "|"
             + SafeLog.shortHash(token) + "|" + token.length
    }

    function _syncApiCacheSessionContext() {
        var next = _currentApiSessionFingerprint()
        if (next === _apiSessionScopeFingerprint) return
        _apiSessionScopeFingerprint = next
        _clearApiCaches(true)
    }

    onSessionAccessTokenChanged: _syncApiCacheSessionContext()
    onSessionUserIdChanged: {
        _syncApiCacheSessionContext()
        _syncTransientSecurityContext()
    }
    onSessionServerUrlChanged: {
        _syncApiCacheSessionContext()
        _syncTransientSecurityContext()
    }

    function _resetSessionContext() {
        // Purge aussi lorsque la session est déjà vide mais qu'un cache public ou
        // une requête coalescée subsiste encore.
        _clearApiCaches(true)
        sessionAccessToken = ""
        sessionUserId = ""
        sessionServerUrl = ""
        sessionUserName = ""
        sessionUserImageTag = ""
        sessionRemember = false
    }

    function _persistRememberedSessionBeforeProfilePicker() {
        if (sessionRemember !== true || !_rememberSessionSetting(settings)) return false
        if (!_hasValidSessionContext()) return false
        if (!_syncUserStoreSecurityPolicy(settings)) return false

        try {
            var active = Users.getActive ? (Users.getActive() || {}) : ({})
            var sameProfile = active
                    && String(active.serverUrl || "") === String(sessionServerUrl || "")
                    && String(active.userId || "") === String(sessionUserId || "")

            Users.addOrUpdateUser({
                serverUrl: sessionServerUrl,
                userId: sessionUserId,
                userName: sessionUserName || (sameProfile ? active.userName || "" : ""),
                imageTag: sessionUserImageTag || (sameProfile ? active.imageTag || "" : ""),
                accessToken: sessionAccessToken,
                remember: true,
                prefs: sameProfile ? (active.prefs || {}) : ({})
            })
            Users.setActive(sessionServerUrl, sessionUserId)
            return true
        } catch(e) {}
        return false
    }

    /* ====== SNAPSHOTS pour hints & focus (robuste au destroy page) === */
    property string __seasonHintId: ""
    property var    __seasonHintOrderIds: []
    property string __pendingFocusId: ""  // id à refocaliser au retour du player
    property int    detailSnapshotMaxEntries: 10
    property int    detailSnapshotTtlMs: 21600000 // 6 h : couvre un film long sans cache illimité

    function _isSnapshotDetailPage(baseName) {
        var b = String(baseName || "").toLowerCase()
        return b === "detailmoviepage.qml"
            || b === "detailseriepage.qml"
            || b === "detailcollectionpage.qml"
    }

    function _detailSnapshotBucket() {
        if (!shared) return null
        if (!shared.__redefinDetailSnapshots)
            shared.__redefinDetailSnapshots = ({})
        return shared.__redefinDetailSnapshots
    }

    function _detailSnapshotKey(baseName, id) {
        return String(baseName || "").toLowerCase() + "#"
             + SafeLog.shortHash(String(id || "")) + "#" + _currentApiSessionFingerprint()
    }

    function _cloneItemForDetailSnapshot(src) {
        if (!src || !src.Id) return null
        var out = ({})
        var heavy = ({
            "UserData": true,
            "MediaSources": true,
            "MediaStreams": true,
            "Chapters": true,
            "Trickplay": true
        })
        try {
            for (var key in src) {
                if (!Object.prototype.hasOwnProperty.call(src, key) || heavy[key]) continue
                var value = src[key]
                if (value && value.length !== undefined && typeof value !== "string") {
                    // Les listes d'une fiche restent utiles visuellement, mais sont
                    // plafonnées pour ne pas transformer le snapshot en copie de page.
                    var cap = key === "People" ? 16 : 24
                    try { out[key] = Array.prototype.slice.call(value, 0, cap) }
                    catch(e0) { out[key] = value }
                } else {
                    out[key] = value
                }
            }
        } catch(e1) { return null }
        // UserData est volontairement absent : progression/lu/favori seront
        // réhydratés exclusivement par la requête fraîche au retour du player.
        return out
    }

    function _captureDetailSnapshotFromPage() {
        try {
            var base = _baseOf(currentPage).toLowerCase()
            if (!_isSnapshotDetailPage(base)) return false
            var page = pageLoader.item
            if (!page || !page.hasOwnProperty("item") || !page.item || !page.item.Id) return false
            var itemCopy = _cloneItemForDetailSnapshot(page.item)
            if (!itemCopy) return false
            var key = _detailSnapshotKey(base, itemCopy.Id)
            var bucket = _detailSnapshotBucket()
            if (!bucket) return false
            return JellyfinBridge.putBoundedMemory(bucket, key, ({
                page: base,
                itemId: String(itemCopy.Id),
                item: itemCopy,
                userDataInvalid: true,
                ts: Date.now()
            }), detailSnapshotMaxEntries)
        } catch(e) {}
        return false
    }

    function _applyDetailSnapshotToPage(baseName, page, params) {
        try {
            var base = String(baseName || "").toLowerCase()
            if (!_isSnapshotDetailPage(base) || !page || !page.applyDetailSnapshot) return false
            var id = String((params && (params.itemId || params.boxSetId)) || "")
            if (!id.length) return false
            var bucket = _detailSnapshotBucket()
            var key = _detailSnapshotKey(base, id)
            var snap = bucket ? bucket[key] : null
            if (!snap || String(snap.itemId || "") !== id || snap.page !== base) return false
            var age = Date.now() - Number(snap.ts || 0)
            if (age < 0 || age > detailSnapshotTtlMs) {
                delete bucket[key]
                return false
            }
            // Un éventuel GET user-scoped vieux de quelques secondes ne doit pas
            // réinjecter la progression/les favoris antérieurs au player.
            try {
                if (JellyfinBridge.evictUserItemApiCache)
                    JellyfinBridge.evictUserItemApiCache(id)
            } catch(e0) {}
            return page.applyDetailSnapshot(snap) === true
        } catch(e) {}
        return false
    }

    function _snapshotSeasonHintsFromPage() {
        try {
            var p = pageLoader.item
            if (!p) return
            __seasonHintId = p.hasOwnProperty("selectedSeasonId")
                    ? (p.selectedSeasonId || "")
                    : ""
            __seasonHintOrderIds = p.hasOwnProperty("seasonPageOrderIds")
                    ? ((p.seasonPageOrderIds || []).slice(0))
                    : []
        } catch(e) {}
    }

    /* ===================== HELPERS PARAMS ======================== */
    function _isBadParam(v) {
        if (v === undefined || v === null) return true
        v = ("" + v).trim()
        return (v === "" || v === "undefined" || v === "null")
    }

    // Sécurité FreeStore/GitHub :
    // les données sensibles ne doivent jamais être injectées dans les routes.
    // Elles voyagent via shared.__redefinNavContext et via l'injection de propriétés du Loader.
    function _ensureSessionParams(url) {
        url = _normalize(url)
        if (!url) return url

        var baseL = _baseOf(url).toLowerCase()

        // ctx=1 : le contexte sensible voyage via shared.__redefinNavContext, jamais dans l'URL.
        if (_isCtxRoute(url)) {
            _storeSessionContextForCtx()
            return _stripSensitiveQueryForCtx(url)
        }

        // LoginPage : si une ancienne route transporte serverUrl, on la déplace en mémoire
        // puis on retourne une route ctx propre.
        if (baseL === "loginpage.qml") {
            var curSrv = extractParam("serverUrl", url)
            var srvForCtx = !_isBadParam(curSrv) ? curSrv : sessionServerUrl

            url = stripParams(url, [
                "serverUrl", "accessToken", "userId", "userName", "userImageTag",
                "folderId", "itemId", "boxSetId", "seasonId", "seriesId", "preselectEpisodeId", "startIndex", "restoreIndex", "restoreY", "libraryMode", "browserTitle", "ageMax"
            ])

            if (!_isBadParam(srvForCtx) && _storeServerContextForCtx(srvForCtx))
                return "LoginPage.qml?ctx=1"

            return url
        }

        // Server/Splash : on ne colle rien.
        if (baseL === "serverpage.qml" || baseL === "splashpage.qml")
            return stripParams(url, ["serverUrl", "accessToken", "userId", "userName", "userImageTag"])

        // Toutes les autres pages reçoivent les secrets via les propriétés injectées
        // au Loader, pas via query string. On nettoie seulement d'éventuelles anciennes routes.
        return stripParams(url, ["serverUrl", "accessToken", "userId", "userName", "userImageTag"])
    }

    /* ===================== QUARANTAINE MMS ======================== */
    property bool _mmsQuarantined: false
    function quarantineFbxMms(enable) {
        if (!fbx) return
        try {
            if (enable && !_mmsQuarantined) {
                if (fbx.mms && fbx.mms.stop) fbx.mms.stop()
                if (fbx.bus && fbx.bus.off) {
                    fbx.bus.off("/fbxmms/media", "audio_tracks_changed")
                    fbx.bus.off("/fbxmms/media", "video_tracks_changed")
                    fbx.bus.off("/fbxmms/media", "metadata_changed")
                }
                _mmsQuarantined = true
            } else if (!enable && _mmsQuarantined) {
                _mmsQuarantined = false
            }
        } catch (e) {}
    }
    onPlayerActiveChanged: {
        quarantineFbxMms(playerActive)

        if (!playerActive && !_directPlayReloadPending) {
            Qt.callLater(function() {
                shell._tryShowPendingUpdate()
            })
        }
    }

    /* ============ DÉTECTION PLAYER FREEBOX POUR ROUTER PLAYBACK ==== */
    function _settingString(name) {
        try {
            if (settings && name in settings && settings[name] !== undefined && settings[name] !== null)
                return String(settings[name])
        } catch(e) {}
        return ""
    }

    function _detectPlaybackDeviceMode() {
        // Priorité à un réglage explicite si l'application en fournit un.
        var explicitMode =
                _settingString("playbackDeviceMode")
                || _settingString("freeboxPlayerMode")
                || _settingString("freeboxModel")
                || _settingString("deviceModel")
                || _settingString("boxModel")

        var m = ClientId.freeboxPlayerModeFromModel(explicitMode)
        if (m) {
            playbackDeviceModel = explicitMode
            return m
        }

        // Source officielle libfbxqml : fbx.system.Device est un singleton.
        // Device.model vaut notamment fbx6hd (Révolution) ou fbx7hd-delta
        // (Delta / Player Devialet). L'objet générique fbx n'expose pas
        // nécessairement cette propriété, d'où l'ancien detected=none.
        try {
            var systemModel = String(Device.model || "")
            m = ClientId.freeboxPlayerModeFromModel(systemModel)
            if (m) {
                playbackDeviceModel = systemModel
                return m
            }
        } catch(eDevice) {}

        if (fbx) {
            var candidates = []

            try { candidates.push(fbx.productId) } catch(e1) {}
            try { candidates.push(fbx.modelId) } catch(e2) {}
            try { candidates.push(fbx.model) } catch(e3) {}
            try { candidates.push(fbx.deviceName) } catch(e4) {}
            try { candidates.push(fbx.hwVersion) } catch(e5) {}
            try { candidates.push(fbx.name) } catch(e6) {}

            try {
                if (fbx.player) {
                    candidates.push(fbx.player)
                    candidates.push(fbx.player.model)
                    candidates.push(fbx.player.modelId)
                    candidates.push(fbx.player.name)
                    candidates.push(fbx.player.deviceName)
                }
            } catch(e7) {}

            for (var i = 0; i < candidates.length; i++) {
                var value = candidates[i]
                m = ClientId.freeboxPlayerModeFromModel(value)
                if (m) {
                    playbackDeviceModel = String(value || "")
                    return m
                }
            }
        }

        playbackDeviceModel = ""
        return "auto"
    }

    function _syncPlaybackDeviceMode() {
        playbackDeviceMode = _detectPlaybackDeviceMode()
    }

    /* ============ INIT IDENTITÉ CLIENT (Jellyfin) ================= */
    function _initClientIdentityFromFbx() {
        try {
            var dev = {}
            try {
                if (Device.model !== undefined && Device.model !== null)
                    dev.modelId = String(Device.model)
                if (Device.firmwareVersion !== undefined && Device.firmwareVersion !== null)
                    dev.swVersion = String(Device.firmwareVersion)
            } catch(eDevice) {}
            if (fbx) {
                try { if (fbx.productId !== undefined && fbx.productId !== null) dev.productId = String(fbx.productId) } catch(e1) {}
                try { if (fbx.modelId   !== undefined && fbx.modelId   !== null) dev.modelId   = String(fbx.modelId) } catch(e2) {}
                try { if (!dev.modelId && fbx.model !== undefined && fbx.model !== null) dev.modelId = String(fbx.model) } catch(e3) {}
                try { if (!dev.modelId && fbx.deviceName !== undefined && fbx.deviceName !== null) dev.modelId = String(fbx.deviceName) } catch(e4) {}
                try { if (fbx.hwVersion !== undefined && fbx.hwVersion !== null) dev.hwVersion = String(fbx.hwVersion) } catch(e5) {}
                try { if (fbx.swVersion !== undefined && fbx.swVersion !== null) dev.swVersion = String(fbx.swVersion) } catch(e6) {}
            }

            if (typeof ClientId.initFromQmlDevice === "function")
                ClientId.initFromQmlDevice(dev)

            try {
                // SÉCURITÉ : ClientId.info() sert uniquement à configurer l'identité Jellyfin.
                // Ne jamais logger son retour brut ; anonymiser explicitement tout diagnostic.
                if (typeof ClientId.info === "function") {
                    var info = ClientId.info()
                    if (info && JellyfinBridge.setClientIdentity)
                        JellyfinBridge.setClientIdentity(info)
                }
            } catch(eSet) {}
        } catch (e) {}
    }

    /* ============ INJECTION CONTEXTE FREEBOX DANS LE BRIDGE ======= */
    onFbxChanged: {
        try { if (JellyfinBridge.setFbx) JellyfinBridge.setFbx(fbx) } catch(e) {}
        _configureHttpWatchdog()
        _initClientIdentityFromFbx()
        _syncPlaybackDeviceMode()
    }

    Component.onCompleted: {
        _installSharedNavApi()
        _installSharedDetailFocusApi()
        try { if (JellyfinBridge.setFbx) JellyfinBridge.setFbx(fbx) } catch(e) {}
        _configureHttpWatchdog()
        _initClientIdentityFromFbx()
        _syncPlaybackDeviceMode()
        _syncUserStoreSecurityPolicy(settings)

        // Ne bloque jamais le boot : la requête GitHub part au tour QML suivant.
        Qt.callLater(function() {
            updateManager.check()
        })
    }

    onSettingsChanged: {
        _syncPlaybackDeviceMode()
        _syncUserStoreSecurityPolicy(settings)
    }

    property bool _settingsPolicySyncQueued: false
    function _queueSettingsPolicySync() {
        if (_settingsPolicySyncQueued) return
        _settingsPolicySyncQueued = true
        Qt.callLater(function() {
            if (!shell) return
            shell._settingsPolicySyncQueued = false
            shell._syncUserStoreSecurityPolicy(shell.settings)
            if (shell._maximumSessionSecuritySetting(shell.settings))
                shell.sessionRemember = false
        })
    }

    Connections {
        target: shell.settings
        ignoreUnknownSignals: true
        // Ne jamais persister ni réassigner un Setting depuis sa propre pile de
        // changement. L'implémentation Freebox peut réémettre le signal même pour
        // une valeur identique.
        function onRememberJellyfinSessionChanged() {
            shell._queueSettingsPolicySync()
        }
        function onMaximumSessionSecurityChanged() {
            shell._queueSettingsPolicySync()
        }
    }

    function _rememberSessionSetting(s) {
        var ref = s || settings
        try {
            return !!ref
                && ref.rememberJellyfinSession === true
                && ref.maximumSessionSecurity !== true
        } catch(e) {}
        return false
    }

    function _maximumSessionSecuritySetting(s) {
        var ref = s || settings
        try { return !!ref && ref.maximumSessionSecurity === true } catch(e) {}
        return false
    }

    function _syncUserStoreSecurityPolicy(s) {
        try {
            var ref = s || settings
            Users.init(shell)

            // Au Component.onCompleted, main.qml n'a pas forcément encore injecté
            // l'objet Settings. Cet état "inconnu" ne doit jamais devenir une
            // désactivation explicite qui purgerait les profils mémorisés.
            if (!ref) return false

            if (Users.configureSecurityPolicy)
                Users.configureSecurityPolicy(
                    _rememberSessionSetting(ref),
                    _maximumSessionSecuritySetting(ref)
                )
            return true
        } catch(e) {}
        return false
    }

    function setRememberJellyfinSession(enabled) {
        var next = enabled === true && !_maximumSessionSecuritySetting(settings)
        var changed = _rememberSessionSetting(settings) !== next

        // UserStore reçoit la politique immédiatement ; la persistance Freebox passe
        // exclusivement par saveSettingsRequested afin de conserver une seule autorité.
        try {
            Users.init(shell)
            if (Users.configureSecurityPolicy)
                Users.configureSecurityPolicy(next, _maximumSessionSecuritySetting(settings))
        } catch(e0) {}

        // Ne jamais purger tous les profils quand le booléen legacy passe à false.
        // La mémorisation réelle appartient à chaque profil et UserStore retire
        // uniquement son token lorsqu'un profil est sauvegardé avec remember:false.
        if (changed) {
            try { saveSettingsRequested({ rememberJellyfinSession: next }) }
            catch(e1) {}
        }
        return next
    }


    /* ================== APPLICATION SETTINGS (PERSIST) ============= */

    // PROD Freebox : pas de polling permanent. UserStore persiste les profils
    // directement au moment des mutations ; la destruction ne gère que le réseau.
    Component.onDestruction: {
        try {
            shell._setHttpWatchdogActive(false)
            if (JellyfinBridge && JellyfinBridge.setHttpWatchdogWake)
                JellyfinBridge.setHttpWatchdogWake(null)
            if (JellyfinBridge && JellyfinBridge.cancelAllHttpRequests)
                JellyfinBridge.cancelAllHttpRequests("shutdown")
        } catch(e0) {}
    }

    /* ===================== APP SETTINGS (par-profil) ============== */
    function _updateAppSettingsContext() {
        try { Components.AppSettings.setContext(sessionServerUrl || "", sessionUserId || "") } catch(e) {}
    }

    /* ===================== NAVIGATION ============================= */
    property double _fastHomeReturnRequestedAtMs: 0
    readonly property int fastHomeReturnMarkerMaxAgeMs: 5000

    function _requestFastHomeReturn(sourceBase) {
        sourceBase = String(sourceBase || "").toLowerCase()
        if (sourceBase === "" || sourceBase === "homepage.qml"
                || sourceBase === "splashpage.qml"
                || sourceBase === "loginpage.qml"
                || sourceBase === "serverpage.qml")
            return
        _fastHomeReturnRequestedAtMs = Date.now()
    }

    function _takeFastHomeReturn() {
        var ts = Number(_fastHomeReturnRequestedAtMs || 0)
        _fastHomeReturnRequestedAtMs = 0
        if (ts <= 0) return false
        var age = Date.now() - ts
        return age >= 0 && age <= fastHomeReturnMarkerMaxAgeMs
    }

    function _navigateTo(nextPage) {
        nextPage = _normalize(nextPage)
        if (!nextPage) return

        // Ouvrir le sélecteur de profils n'est pas une déconnexion. On consolide
        // d'abord le profil courant si l'utilisateur a choisi "Rester connecté".
        if (_baseOf(nextPage).toLowerCase() === "loginpage.qml")
            _persistRememberedSessionBeforeProfilePicker()

        nextPage = _ensureSessionParams(nextPage)
        nextPage = _stripSensitiveQueryForCtx(nextPage)
        if (_isCtxRoute(nextPage)) _syncSessionFromSharedNavContext()

        var baseNext = _baseOf(nextPage)
        var baseCurr = _baseOf(currentPage)
        var baseNextL = baseNext.toLowerCase()
        var baseCurrL = baseCurr.toLowerCase()
        var enteringProfilePicker = baseNextL === "loginpage.qml"
                && baseCurrL !== "loginpage.qml"
                && baseCurrL !== "serverpage.qml"
                && baseCurrL !== "splashpage.qml"

        if (enteringProfilePicker) {
            _resetUiFocusStateForProfilePicker()
            navStack = []
        }

        // Le boot et les écrans d'authentification ne doivent jamais démarrer
        // CircleDots. HomePage déverrouille l'animation pour la session UI.
        if (baseNextL === "homepage.qml") {
            _circleDotsRuntimeEnabled = true
        } else if (baseNextL === "splashpage.qml" || baseNextL === "serverpage.qml" || baseNextL === "loginpage.qml") {
            _homeLaunchPending = false
            _circleDotsRuntimeEnabled = false
        }

        _updateAppSettingsContext()

        if (baseNextL === "homepage.qml") {
            _requestFastHomeReturn(baseCurrL)
            navStack = []
            currentPage = nextPage
            return
        }

        // Le curtain doit être levé AVANT que Loader.source change. Sinon le
        // Loader asynchrone peut laisser l'ancienne fiche visible une frame.
        _prepareDetailCurtainBeforeNavigation(nextPage)

        var sameBase = baseCurr && baseNext && (baseCurrL === baseNextL)

        if (baseCurr && baseCurrL !== "splashpage.qml"
            && baseCurrL !== "loginpage.qml"
            && !sameBase
            && !enteringProfilePicker) {
            navStack.push(_stripSensitiveQueryForCtx(currentPage))
            if (navStack.length > 50)
                navStack.splice(0, navStack.length - 50)
        }

        // FIX nav: reload forcé quand on rouvre la même page
        if (sameBase) {
            var keep = nextPage
            currentPage = ""
            Qt.callLater(function(){ currentPage = keep })
        } else {
            currentPage = nextPage
        }

    }

    function goBackOrHome() {
        var currentBase = _baseOf(currentPage).toLowerCase()
        if (navStack.length > 0) {
            var prev = navStack.pop()
            var prevBase = _baseOf(prev).toLowerCase()
            if (prevBase === "homepage.qml")
                _requestFastHomeReturn(currentBase)
            if (prevBase === "moviepage.qml")
                prev = _withStartIndexIfReturningFromDetails(prev, currentBase)
            _updateAppSettingsContext()
            _prepareDetailCurtainBeforeNavigation(prev)
            currentPage = prev
        } else {
            // Sécurité : ne jamais "tomber" sur HomePage depuis l'écran de boot/login.
            if (currentBase === "loginpage.qml" || currentBase === "serverpage.qml" || currentBase === "splashpage.qml")
                return

            _requestFastHomeReturn(currentBase)
            _storeSessionContextForCtx()
            var home = buildUrl("HomePage.qml", {
                ctx:    "1",
                ageMax: extractParam("ageMax", currentPage) || "99"
            })
            try { Components.AppSettings.setContext(sessionServerUrl || "", sessionUserId || "") } catch(e0) {}
            currentPage = home
        }
    }

    function handleNavigation(pageName) {
        pageName = _normalize(pageName)
        if (!pageName) return

        var baseCurr = _baseOf(currentPage).toLowerCase()
        var baseNext = _baseOf(pageName).toLowerCase()

        // Snapshot du focus MoviePage avant de quitter
        try {
            if (baseCurr === "moviepage.qml"
                && pageLoader.item && pageLoader.item.hasOwnProperty("currentIndex")) {
                _rememberFocus(currentPage, pageLoader.item.currentIndex || 0)
            }
        } catch(e) {}

        // MoviePage : startIndex si retour depuis une page de détails
        if (baseNext === "moviepage.qml") {
            pageName = _withStartIndexIfReturningFromDetails(pageName, baseCurr)
            _navigateTo(pageName)
            return
        }

        _navigateTo(pageName)
    }

    /* ========= REDIRECTION APRÈS DÉCONNEXION / SUPPRESSION ========= */
    function _routeAfterSignout(serverUrl) {
        _clearApiCaches(true)
        _homeLaunchPending = false
        _circleDotsRuntimeEnabled = false
        var srv = (serverUrl || "")
        if (srv && srv.length) {
            _storeServerContextForCtx(srv)
            navStack = []
            currentPage = "LoginPage.qml?ctx=1"
            return
        }
        navStack = []
        currentPage = "serverpage.qml"
    }

    /* ===================== PLAYLIST UNIQUE (sans UI) ============== */
    Components.Playlist {
        id: playlist
        autoplayNext: true

        onRequestPlayItem: function(itemId) {
            shell._snapshotSeasonHintsFromPage()

            shell.playerItemId      = itemId || ""
            shell.playerAccessToken = shell.sessionAccessToken || shell.playerAccessToken
            shell.playerUserId      = shell.sessionUserId     || shell.playerUserId
            shell.playerServerUrl   = shell.sessionServerUrl  || shell.playerServerUrl
            shell.playerItemTitle   = shell.playerPlaylistTitle || shell.playerItemTitle
            shell._requestPlayerLaunch()
        }
    }

    /* ===================== CONTRAT DES PAGES CHARGÉES ============ */
    // ShellPage reste l'autorité de navigation/session. Les pages exposent des
    // capacités optionnelles (signaux/propriétés) que Shell branche ici. Le
    // découpage ci-dessous rend ce contrat découvrable sans changer sa nature
    // dynamique ni imposer une interface artificielle à toutes les pages.
    function _wireLoadedPageNavigation(pageItem) {
        if (pageItem.requestNavigation && pageItem.requestNavigation.connect) {
            pageItem.requestNavigation.connect(function(pageName) {
                shell.handleNavigation(pageName)
            })
        }
        if (pageItem.requestHomeLoading && pageItem.requestHomeLoading.connect) {
            pageItem.requestHomeLoading.connect(function(active) {
                shell._setHomeLaunchPending(active === true)
            })
        }
        if (pageItem.requestBackToMenu && pageItem.requestBackToMenu.connect)
            pageItem.requestBackToMenu.connect(function() { shell.goBackOrHome() })

        function bindLogout(signalName, removeEntry) {
            if (pageItem[signalName] && pageItem[signalName].connect) {
                pageItem[signalName].connect(function() {
                    shell.disconnectActiveProfile(removeEntry === true)
                })
            }
        }
        bindLogout("requestLogout", false)
        bindLogout("requestLogoutProfile", false)
        bindLogout("requestDisconnectProfile", false)
        bindLogout("requestRemoveProfile", true)
    }

    function _loadedPageParams(safeCurrentPage) {
        return {
            accessToken: shell.sessionAccessToken,
            userId: shell.sessionUserId,
            serverUrl: shell.sessionServerUrl,
            userName: shell.sessionUserName,
            userImageTag: shell.sessionUserImageTag,

            folderId: extractParam("folderId", safeCurrentPage),
            itemId: extractParam("itemId", safeCurrentPage),
            boxSetId: extractParam("boxSetId", safeCurrentPage),
            seasonId: extractParam("seasonId", safeCurrentPage),
            seriesId: extractParam("seriesId", safeCurrentPage),
            preselectEpisodeId: extractParam("preselectEpisodeId", safeCurrentPage),

            // MoviePage universel : le mode ne doit pas être perdu par ShellPage.
            libraryMode: extractParam("libraryMode", safeCurrentPage),
            browserTitle: extractParam("browserTitle", safeCurrentPage),
            ageMax: extractParam("ageMax", safeCurrentPage)
        }
    }

    function _injectLoginPageContext(pageItem, params) {
        // Ordre volontaire : politique Settings avant shared/fbx.
        if (pageItem.hasOwnProperty("settingsRef")) pageItem.settingsRef = shell.settings
        if (pageItem.hasOwnProperty("shared")) pageItem.shared = shell.shared
        if (pageItem.hasOwnProperty("fbx")) pageItem.fbx = shell.fbx

        var loginCtx = shell._sharedNavContext()
        var loginServerUrl = params.serverUrl
        if (_isBadParam(loginServerUrl) && loginCtx && !_isBadParam(loginCtx.serverUrl))
            loginServerUrl = String(loginCtx.serverUrl)

        if (pageItem.hasOwnProperty("serverUrl") && !_isBadParam(loginServerUrl))
            pageItem.serverUrl = loginServerUrl

        try { Components.AppSettings.setContext(loginServerUrl || "", "") } catch(e0) {}
        if (!_isBadParam(loginServerUrl)) shell.sessionServerUrl = loginServerUrl
    }

    function _injectStandardPageContext(pageItem, params, safeCurrentPage) {
        // shared arrive en premier afin que les routes ctx=1 puissent hydrater
        // leur contexte avant le fallback sur la session Shell.
        if (pageItem.hasOwnProperty("shared")) pageItem.shared = shell.shared
        if (shell._isCtxRoute(safeCurrentPage)) shell._syncSessionFromSharedNavContext()

        for (var key in params) {
            if (!pageItem.hasOwnProperty(key)) continue
            if (key === "accessToken" || key === "userId" || key === "serverUrl"
                    || key === "userName" || key === "userImageTag") {
                if (!_isBadParam(params[key])) pageItem[key] = params[key]
            } else {
                pageItem[key] = params[key]
            }
        }

        var startIndexRaw = extractParam("startIndex", shell.currentPage)
        if (startIndexRaw !== "" && pageItem.hasOwnProperty("startIndex")) {
            var startIndex = parseInt(startIndexRaw)
            if (!isNaN(startIndex)) pageItem.startIndex = startIndex
        }

        var restoreIndexRaw = extractParam("restoreIndex", shell.currentPage)
        if (restoreIndexRaw !== "" && pageItem.hasOwnProperty("restoreIndex")) {
            var restoreIndex = parseInt(restoreIndexRaw)
            if (!isNaN(restoreIndex)) pageItem.restoreIndex = restoreIndex
        }

        var restoreYRaw = extractParam("restoreY", shell.currentPage)
        if (restoreYRaw !== "" && pageItem.hasOwnProperty("restoreY")) {
            var restoreY = Number(restoreYRaw)
            if (isFinite(restoreY) && !isNaN(restoreY)) pageItem.restoreY = restoreY
        }

        if (!_isBadParam(params.accessToken)) shell.sessionAccessToken = params.accessToken
        if (!_isBadParam(params.userId)) shell.sessionUserId = params.userId
        if (!_isBadParam(params.serverUrl)) shell.sessionServerUrl = params.serverUrl
        if (!_isBadParam(params.userName)) shell.sessionUserName = params.userName
        if (!_isBadParam(params.userImageTag)) shell.sessionUserImageTag = params.userImageTag
        try { Components.AppSettings.setContext(shell.sessionServerUrl, shell.sessionUserId) } catch(e1) {}
    }

    function _injectLoadedPageCommonContext(pageItem, baseNow, params, fastHomeReturn) {
        if (pageItem.hasOwnProperty("playlistRef")) pageItem.playlistRef = playlist
        if (pageItem.hasOwnProperty("shared") && pageItem.shared !== shell.shared)
            pageItem.shared = shell.shared
        if (pageItem.hasOwnProperty("playbackDeviceMode"))
            pageItem.playbackDeviceMode = shell.playbackDeviceMode

        // La fiche chaude est appliquée après l'identité/itemId mais avant la
        // restauration du focus ; la page réhydrate ensuite les données lourdes.
        shell._applyDetailSnapshotToPage(baseNow, pageItem, params)

        if (baseNow === "homepage.qml" && pageItem.hasOwnProperty("fastHomeReturn"))
            pageItem.fastHomeReturn = fastHomeReturn

        if (baseNow === "homepage.qml") {
            Qt.callLater(function() {
                try {
                    if (pageLoader.item && pageLoader.item.forceActiveFocus)
                        pageLoader.item.forceActiveFocus()
                } catch(eFocusHome) {}
            })
        }

        if (baseNow === "moviepage.qml"
                && pageItem.hasOwnProperty("currentIndex") && pageItem.currentIndexChanged) {
            try {
                pageItem.currentIndexChanged.connect(function() {
                    shell._rememberFocus(shell.currentPage, pageItem.currentIndex || 0)
                })
            } catch(e2) {}
        }
    }

    function _startRequestedPlaylist(itemIds, accessToken, userId, serverUrl, listTitle) {
        shell._snapshotSeasonHintsFromPage()

        // Une playlist émise par DetailSeriePage représente toute la série et
        // doit repartir du premier élément. On retire donc d'abord les filtres
        // et le curseur éventuellement laissés par SeasonPage.
        try { if (playlist.allowedIds !== undefined) playlist.allowedIds = null } catch(ePl0) {}
        try {
            if (playlist.clear) playlist.clear()
            else { playlist.list = []; playlist.index = -1; playlist.currentItemId = "" }
        } catch(ePl1) {
            try { playlist.index = -1; playlist.currentItemId = "" } catch(ePl2) {}
        }

        playlist.list = (itemIds || [])
                .map(function(id) { return String(id || "") })
                .filter(function(id) { return id.length > 0 })
        shell.playerPlaylist = playlist.list.slice(0)
        shell.playerPlaylistTitle = listTitle || ""
        shell.playerPlaylistStartAtZero = true

        if (!_isBadParam(accessToken)) shell.sessionAccessToken = accessToken
        if (!_isBadParam(userId)) shell.sessionUserId = userId
        if (!_isBadParam(serverUrl)) shell.sessionServerUrl = serverUrl
        playlist.start()
    }

    function _wireLoadedPagePlayback(pageItem, isLogin, params) {
        if (isLogin) return

        if (pageItem.requestPlay && pageItem.requestPlay.connect) {
            pageItem.requestPlay.connect(function(itemId, accessToken, userId, serverUrl, itemTitle) {
                shell._snapshotSeasonHintsFromPage()
                playlist.list = []
                shell.playerPlaylist = []
                shell.playerPlaylistTitle = ""
                shell.playerPlaylistStartAtZero = false
                shell.playerItemId = itemId || ""
                shell.playerAccessToken = accessToken || params.accessToken || shell.sessionAccessToken
                shell.playerUserId = userId || params.userId || shell.sessionUserId
                shell.playerServerUrl = serverUrl || params.serverUrl || shell.sessionServerUrl
                shell.playerItemTitle = itemTitle || ""
                shell._requestPlayerLaunch()
            })
        }

        if (pageItem.requestPlayList && pageItem.requestPlayList.connect) {
            pageItem.requestPlayList.connect(function(itemIds, accessToken, userId, serverUrl, listTitle) {
                shell._startRequestedPlaylist(itemIds, accessToken, userId, serverUrl, listTitle)
            })
        }
    }

    function _wireLoadedPageServerDiscovery(pageItem, baseNow) {
        if (baseNow === "serverpage.qml" && pageItem.discoveredServersUpdated) {
            pageItem.discoveredServersUpdated.connect(function(list) {
                shell.shared.discoveredServers = (list && list.slice) ? list.slice(0) : (list || [])
                if (pageLoader.item
                        && _baseOf(shell.currentPage).toLowerCase() === "loginpage.qml") {
                    var loginPage = pageLoader.item
                    if (loginPage.hasOwnProperty("setDiscoveredServers"))
                        loginPage.setDiscoveredServers(shell.shared.discoveredServers)
                }
            })
        }
        if (baseNow === "loginpage.qml" && pageItem.hasOwnProperty("setDiscoveredServers"))
            pageItem.setDiscoveredServers(shell.shared.discoveredServers || [])
    }

    function _persistLoadedPageContext(baseNow) {
        if (baseNow === "loginpage.qml") {
            var loginCtx = shell._sharedNavContext()
            var server = extractParam("serverUrl", shell.currentPage)
                    || shell.sessionServerUrl || (loginCtx && loginCtx.serverUrl) || ""
            if (server && server.length && shell.saveSettingsRequested)
                shell.saveSettingsRequested({ serverUrl:server })
        }

        if (baseNow === "homepage.qml" && shell.saveSettingsRequested) {
            shell.saveSettingsRequested({
                serverUrl: shell.sessionServerUrl || "",
                lastUserId: shell.sessionUserId || "",
                lastUserName: shell.sessionUserName || ""
            })
        }
    }

    function _applyPendingLoadedPageFocus(pageItem) {
        if (!shell.__pendingFocusId || !shell.__pendingFocusId.length) return
        try {
            if (pageItem.hasOwnProperty("preselectEpisodeId"))
                pageItem.preselectEpisodeId = String(shell.__pendingFocusId)
            if (pageItem.requestFocusItem && pageItem.requestFocusItem.call)
                pageItem.requestFocusItem(String(shell.__pendingFocusId))
        } catch(e4) {}
        shell.__pendingFocusId = ""
    }

    function _onPageLoaded(pageItem, loadedCurtainSeq) {
        if (!pageItem) {
            shell._pageLoadCurtainHold = false
            return
        }

        shell._wireLoadedPageNavigation(pageItem)

        var baseNow = _baseOf(shell.currentPage).toLowerCase()
        var isLogin = baseNow === "loginpage.qml"
        var fastHomeReturn = baseNow === "homepage.qml" ? shell._takeFastHomeReturn() : false

        if ((baseNow === "detailmoviepage.qml" || baseNow === "detailseriepage.qml")
                && pageItem.hasOwnProperty("enableAvatarProfileNavigation"))
            pageItem.enableAvatarProfileNavigation = true

        var safeCurrentPage = shell._stripSensitiveQueryForCtx(shell.currentPage)
        if (shell._isCtxRoute(safeCurrentPage)) shell._syncSessionFromSharedNavContext()
        var params = shell._loadedPageParams(safeCurrentPage)

        if (isLogin) shell._injectLoginPageContext(pageItem, params)
        else shell._injectStandardPageContext(pageItem, params, safeCurrentPage)

        shell._injectLoadedPageCommonContext(pageItem, baseNow, params, fastHomeReturn)
        shell._wireLoadedPagePlayback(pageItem, isLogin, params)
        shell._wireLoadedPageServerDiscovery(pageItem, baseNow)
        shell._persistLoadedPageContext(baseNow)
        shell._applyPendingLoadedPageFocus(pageItem)

        Qt.callLater(function() {
            if (loadedCurtainSeq === shell._pageLoadCurtainSeq)
                shell._schedulePageCurtainRelease(loadedCurtainSeq)

            shell._tryShowPendingUpdate()
        })
    }

    /* ===================== PAGE COURANTE ========================== */
    Loader {
        id: pageLoader
        anchors.fill: parent
        source: !playerActive ? _stripSensitiveQueryForCtx(currentPage) : ""
        visible: !playerActive
        asynchronous: true
        onStatusChanged: {
            if (status === Loader.Loading) {
                shell._beginPageCurtainTransition()
            } else if (status === Loader.Error || status === Loader.Null) {
                shell._pageLoadCurtainSeq = (shell._pageLoadCurtainSeq + 1) | 0
                shell._pageLoadCurtainHold = false
                shell._homeLaunchPending = false
                shell._pageCurtainReadySinceMs = 0
                shell._pageCurtainStableTicks = 0
                try { pageCurtainReleaseTimer.stop() } catch(e0) {}
            } else if (status === Loader.Ready) {
                shell._schedulePageCurtainRelease(shell._pageLoadCurtainSeq)
            }
        }

        onLoaded: shell._onPageLoaded(item, shell._pageLoadCurtainSeq)
    }

    // Curtain global de session : il couvre la construction QML et le chargement
    // visuel réel uniquement après le lancement de HomePage. Pendant Splash /
    // Server / Login, SplashPage reste l'unique écran logo + CircleDots.
    FocusScope {
        id: pageLoadCurtain
        anchors.fill: parent
        z: 900
        // Le curtain global (logo + CircleDots) est totalement muet pendant
        // le boot/authentification. SplashPage possède son propre logo + loader.
        // Il n'apparaît qu'à partir de l'intention réelle d'entrer dans HomePage,
        // puis reste disponible pour les transitions de la session connectée.
        visible: !shell.playerActive &&
                 shell._circleDotsRuntimeEnabled &&
                 (shell._homeLaunchPending ||
                  pageLoader.status === Loader.Loading ||
                  shell._pageLoadCurtainHold ||
                  shell._pageReportedLoading)
        enabled: visible
        focus: visible

        Rectangle { anchors.fill: parent; color: "#000000" }

        Image {
            source: "../images/Redefin-logo2-512.png"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -50
            width: 420
            height: 140
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            smooth: true
            mipmap: false
            sourceSize.width: Math.round(width * 2)
            sourceSize.height: Math.round(height * 2)
        }

        Components.CircleDotsLoader {
            id: globalPageDots
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 10
            width: 80
            height: 80
            dotSize: 6
            radius: 30
            active: pageLoadCurtain.visible && shell._circleDotsRuntimeEnabled
            running: active
            preservePhase: true
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: globalPageDots.bottom
            anchors.topMargin: 10
            width: Math.min(parent.width - 120, 860)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: shell._pageReportedLoadingError
            color: "#ffdfdf"
            font.pixelSize: 16
            textFormat: Text.PlainText
            visible: text.length > 0
        }

        onVisibleChanged: {
            if (visible) {
                ++shell._pageFocusHandoffSeq
                try { forceActiveFocus(Qt.OtherFocusReason) } catch(e0) {}
            } else {
                shell._handoffFocusAfterPageCurtain()

                Qt.callLater(function() {
                    shell._tryShowPendingUpdate()
                })
            }
        }
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape)
                shell.goBackOrHome()
            event.accepted = true
        }
        Keys.onReleased: event.accepted = true
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
    }

    /* ===================== PLAYER OVERLAY ========================= */
    FocusScope {
        id: playerLaunchCurtain
        anchors.fill: parent
        // Loader Player unique, au-dessus du PlayerOverlay jusqu'à lecture prête.
        z: 5000
        visible: shell.playerLaunchPending
                 || shell._directPlayReloadPending
                 || shell._playerOverlayReportsLoading
        focus: visible
        onVisibleChanged: {
            if (visible) {
                try { forceActiveFocus(Qt.OtherFocusReason) } catch(e0) {}
            } else {
                // Le curtain a volontairement pris le focus pendant le chargement.
                // Dès qu'il disparaît, le rendre immédiatement au PlayerOverlay
                // au lieu d'attendre l'auto-hide de la barre de contrôles.
                Qt.callLater(function() {
                    if (!shell.playerActive ||
                            shell.playerLaunchPending ||
                            shell._directPlayReloadPending ||
                            shell._playerOverlayReportsLoading)
                        return

                    try {
                        if (playerOverlayLoader.item &&
                                playerOverlayLoader.item.forceActiveFocus) {
                            playerOverlayLoader.item.forceActiveFocus(
                                        Qt.OtherFocusReason)
                            return
                        }
                    } catch(e1) {}

                    try {
                        shell.forceActiveFocus(Qt.OtherFocusReason)
                    } catch(e2) {}
                })
            }
        }

        // Aucun fond : le PlayerOverlay reste visible pendant le chargement.
        Components.CircleDotsLoader {
            id: playerLaunchCircle
            anchors.centerIn: parent
            visible: playerLaunchCurtain.visible
            active: visible
            Component.onCompleted: {
                try { if ("running" in playerLaunchCircle) playerLaunchCircle.running = visible } catch(e0) {}
            }
            onVisibleChanged: {
                try { if ("running" in playerLaunchCircle) playerLaunchCircle.running = visible } catch(e0) {}
            }
        }

        Text {
            anchors.top: playerLaunchCircle.bottom
            anchors.topMargin: 14
            anchors.horizontalCenter: playerLaunchCircle.horizontalCenter
            text: "Chargement..."
            color: "#E7ECFF"
            font.pixelSize: 17
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            visible: playerLaunchCurtain.visible
        }

        Keys.onPressed: event.accepted = true
        Keys.onReleased: event.accepted = true
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
    }

    Loader {
        id: playerOverlayLoader
        anchors.fill: parent
        source: playerActive ? Qt.resolvedUrl("playeroverlay.qml") : ""
        visible: playerActive
        asynchronous: false
        z: 1000

        property string accessToken: shell.sessionAccessToken || shell.playerAccessToken
        property string userId:      shell.sessionUserId      || shell.playerUserId
        property string serverUrl:   shell.sessionServerUrl   || shell.playerServerUrl
        property string itemId:      shell.playerItemId
        property string itemTitle:   shell.playerItemTitle
        property var    fbx:         shell.fbx
        property string playbackDeviceMode: shell.playbackDeviceMode
        property string playbackRuleMode: {
            try {
                return (Components.AppSettings && Components.AppSettings.playbackMode === "directplay")
                        ? "directplay" : "smart"
            } catch (e) {}
            return "smart"
        }

        property var    playerPlaylist:       shell.playerPlaylist
        property string playerPlaylistTitle:  shell.playerPlaylistTitle
        property bool   playlistStartAtZero:    shell.playerPlaylistStartAtZero

        property var    playlistRef:          playlist
        property string playlistTitle:        shell.playerPlaylistTitle

        property string seasonHintSelectedId: shell.__seasonHintId
        property var    seasonHintOrderIds:   shell.__seasonHintOrderIds

        function _handleOverlayBack(returnFocusId) {
            shell.__pendingFocusId = String(returnFocusId || "")
            shell._cancelPendingPlayerLaunch()
            shell._directPlayReloadPending = false
            try { directPlayReloadTimer.stop() } catch(eReloadTimer) {}

            // Retour PlayerOverlay -> DetailSeriePage : armer le curtain AVANT
            // de détruire le Player. pageLoader est recréé de façon asynchrone
            // après playerActive=false ; sans ce verrou, une frame de la fiche
            // peut devenir visible entre deux états de chargement.
            var returnBase = shell._baseOf(shell.currentPage).toLowerCase()
            if (shell._circleDotsRuntimeEnabled && returnBase === "detailseriepage.qml")
                shell._beginPageCurtainTransition()

            shell.playerActive = false
        }

        function _handleDirectPlayReload() {
            shell._requestDirectPlayPlayerReload()
        }

        onLoaded: {
            if (!item) return

            // Installer le backend matériel avant d'injecter itemId/session.
            // Les handlers de contexte peuvent démarrer la négociation dès itemId.
            if (item.hasOwnProperty("playbackDeviceMode")) item.playbackDeviceMode = playbackDeviceMode
            if (item.hasOwnProperty("playbackRuleMode"))   item.playbackRuleMode   = playbackRuleMode
            if (item.hasOwnProperty("fbx"))         item.fbx         = fbx
            if (item.hasOwnProperty("shared"))      item.shared      = shell.shared
            if (item.hasOwnProperty("settingsRef")) item.settingsRef = shell.settings
            // Doit être injecté AVANT itemId/session : leurs handlers peuvent
            // lancer immédiatement la négociation initiale.
            if (item.hasOwnProperty("forcePlaylistStartAtZero")) item.forcePlaylistStartAtZero = playlistStartAtZero
            if (item.hasOwnProperty("accessToken")) item.accessToken = accessToken
            if (item.hasOwnProperty("userId"))      item.userId      = userId
            if (item.hasOwnProperty("serverUrl"))   item.serverUrl   = serverUrl
            if (item.hasOwnProperty("itemId"))      item.itemId      = itemId
            if (item.hasOwnProperty("itemTitle"))   item.itemTitle   = itemTitle

            if (item.hasOwnProperty("playlistRef"))         item.playlistRef         = playlistRef
            if (item.hasOwnProperty("playlist"))            item.playlist            = playlistRef
            if (item.hasOwnProperty("playlistTitle"))       item.playlistTitle       = playlistTitle
            if (item.hasOwnProperty("playerPlaylist"))      item.playerPlaylist      = playerPlaylist
            if (item.hasOwnProperty("playerPlaylistTitle")) item.playerPlaylistTitle = playerPlaylistTitle

            if (item.hasOwnProperty("selectedSeasonId"))    item.selectedSeasonId    = seasonHintSelectedId
            if (item.hasOwnProperty("seasonPageOrderIds"))  item.seasonPageOrderIds  =
                    (seasonHintOrderIds || []).slice(0)

            if (item.requestBackToDetails && item.requestBackToDetails.connect) {
                try { item.requestBackToDetails.disconnect(_handleOverlayBack) } catch(e) {}
                item.requestBackToDetails.connect(_handleOverlayBack)
            }
            if (item.requestDirectPlayReload && item.requestDirectPlayReload.connect) {
                try { item.requestDirectPlayReload.disconnect(_handleDirectPlayReload) } catch(eDp0) {}
                item.requestDirectPlayReload.connect(_handleDirectPlayReload)
            }

            try { item.forceActiveFocus() } catch(e2) {}

            try {
                item.destroyed.connect(function(){
                    try {
                        item.requestBackToDetails
                        && item.requestBackToDetails.disconnect
                        && item.requestBackToDetails.disconnect(_handleOverlayBack)
                        if (item.requestDirectPlayReload && item.requestDirectPlayReload.disconnect)
                            item.requestDirectPlayReload.disconnect(_handleDirectPlayReload)
                    } catch(e3) {}
                })
            } catch(e4) {}
        }
    }

    function forgetThisDevice() {
        _clearApiCaches(true)
        _clearTrustedLanHosts()
        try { Users.init(shell) } catch(e0) {}
        try { if (Users.forgetThisDevice) Users.forgetThisDevice(); else Users.clearAll() } catch(e1) {}

        _cancelPendingPlayerLaunch()
        _directPlayReloadPending = false
        try { directPlayReloadTimer.stop() } catch(eReloadStop) {}
        playerActive = false
        playerItemId = ""
        playerAccessToken = ""
        playerUserId = ""
        playerServerUrl = ""
        playerItemTitle = ""
        playerPlaylist = []
        playerPlaylistTitle = ""
        playerPlaylistStartAtZero = false
        try { playlist.list = [] } catch(e2) {}

        _resetSessionContext()
        try { if (shared) shared.__redefinNavContext = null } catch(e3) {}
        try { Components.AppSettings.setContext("", "") } catch(eCtx) {}
        navStack = []
        focusMemory = ({})

        // Canal unique de persistance : main.qml effectue la purge officielle des
        // fbx.application.Settings après que UserStore a vidé ses propres données.
        saveSettingsRequested({ clearSensitiveSettings: true })

        currentPage = "serverpage.qml"
    }

    /* ===================== DÉCONNEXION PROFIL ===================== */
    function disconnectActiveProfile(removeEntry) {
        // Le POST Logout n'est pas mis en cache. On peut donc invalider
        // immédiatement toutes les lectures du profil sortant.
        _clearApiCaches(true)
        try { Users.init(shell) } catch(e) {}

        var active = Users.getActive()
        if (!active) {
            _clearTrustedLanHosts()
            _resetSessionContext()
            _routeAfterSignout("")

            if (saveSettingsRequested) {
                saveSettingsRequested({
                    serverUrl:       "",
                    lastUserId:      "",
                    lastUserName:    ""
                })
            }
            return
        }

        var srv = active.serverUrl   || ""
        var tok = active.accessToken || ""
        var uid = active.userId      || ""

        function _afterLogout() {
            _clearApiCaches(true)
            _clearTrustedLanHosts()
            try { if (Users.clearUserToken) Users.clearUserToken(srv, uid) } catch(eToken) {}
            if (removeEntry === true) {
                Users.removeUser(srv, uid)
            } else {
                Users.addOrUpdateUser({
                    serverUrl: srv,
                    userId:    uid,
                    accessToken: "",
                    remember: (active.remember === true),
                    prefs:    active.prefs || {}
                })
            }
            Users.setActive(srv, uid)

            if (saveSettingsRequested) {
                if (removeEntry === true) {
                    saveSettingsRequested({
                        serverUrl:       srv,
                        lastUserId:      "",
                        lastUserName:    ""
                    })
                } else {
                    saveSettingsRequested({
                        serverUrl:       srv,
                        lastUserId:      uid,
                        lastUserName:    active.userName || ""
                    })
                }
            }

            _resetSessionContext()
            _routeAfterSignout(srv)
        }

        if (srv && tok) {
            JellyfinBridge.logout(
                srv, tok,
                function(){ _afterLogout() },
                function(){ _afterLogout() }
            )
        } else {
            _afterLogout()
        }
    }

    /* ===================== RACCOURCIS GLOBAUX ===================== */
    Keys.onPressed: {
        if (playerActive) return
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            goBackOrHome()
            event.accepted = true
        }
    }

    /* ===================== BOOT / AUTORESTORE ===================== */

    function _showStoredProfilePicker(active, all, hintSrv) {
        all = all || []
        var u0 = active || (all.length ? all[0] : null)

        if (u0) {
            try { Components.AppSettings.setContext(u0.serverUrl || "", u0.userId || "") } catch(e0) {}
            if (saveSettingsRequested) {
                saveSettingsRequested({
                    serverUrl:       u0.serverUrl   || "",
                    lastUserId:      u0.userId      || "",
                    lastUserName:    u0.userName    || ""
                })
            }
            _storeServerContextForCtx(u0.serverUrl || "")
            currentPage = "LoginPage.qml?ctx=1"
            navStack = []
            return
        }

        var lastSrv = hintSrv || ""
        if (lastSrv && lastSrv.length) {
            if (saveSettingsRequested) {
                saveSettingsRequested({
                    serverUrl:       lastSrv,
                    lastUserId:      "",
                    lastUserName:    ""
                })
            }
            _storeServerContextForCtx(lastSrv)
            currentPage = "LoginPage.qml?ctx=1"
            navStack = []
            return
        }

        currentPage = "serverpage.qml"
        navStack = []
    }

    function _autoBoot() {
        _clearApiCaches(true)
        Users.init(shell)
        _syncUserStoreSecurityPolicy(settings)
        try { if (Users.sanitizeStoredUsers) Users.sanitizeStoredUsers() } catch(eSanitize) {}

        var hintSrv = (bootHints && bootHints.serverUrl) ? bootHints.serverUrl : ""
        var hintUid = (bootHints && bootHints.userId) ? bootHints.userId : ""

        var active = Users.getActive()
        var all = Users.listUsers()

        if (!active && hintSrv && hintUid && all && all.length) {
            for (var i = 0; i < all.length; ++i) {
                var u = all[i] || {}
                if ((u.serverUrl || "") === hintSrv && (u.userId || "") === hintUid) {
                    active = u
                    Users.setActive(hintSrv, hintUid)
                    break
                }
            }
        }

        // Le sélecteur de profils apparaît immédiatement. La validation du token
        // persistant est faite uniquement pour le profil sélectionné dans LoginPage,
        // ce qui évite N requêtes au boot lorsqu'une famille possède plusieurs profils.
        _showStoredProfilePicker(active, all, hintSrv)
    }

    // Splash → autoboot
    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: {
            if (shell.currentPage === "SplashPage.qml")
                _autoBoot()
        }
    }
}
