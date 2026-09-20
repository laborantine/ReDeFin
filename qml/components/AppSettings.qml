// qml/components/AppSettings.qml
// Façade réactive des préférences ReDeFin. La persistance appartient à UserStore.js.
pragma Singleton
import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/UserStore.js" as UserStore

QtObject {
    id: root

    property string serverUrl: ""
    property string userId: ""
    // Référence au backend officiel fbx.application.Settings, consommée par UserStore.
    property var settingsRef: null

    property bool showClock: true
    // smart      : règles de sélection/remux ReDeFin.
    // directplay : priorité au fichier original, contraintes matérielles conservées.
    property string playbackMode: "smart"

    property bool _syncing: false
    property bool _syncScheduled: false
    property bool _storeInitialized: false

    function _normServer(srv) {
        try {
            if (Jellyfin && typeof Jellyfin.normalizeServerUrl === "function")
                return String(Jellyfin.normalizeServerUrl(srv || "", false) || "")
        } catch(e0) {}
        return ""
    }

    function _ctxOk(srv, uid) {
        var s = (srv !== undefined) ? String(srv || "") : String(serverUrl || "")
        var u = (uid !== undefined) ? String(uid || "") : String(userId || "")
        return s.length > 0 && u.length > 0
    }

    function normalizePlaybackMode(value) {
        var mode = String(value || "").toLowerCase().trim()
        if (mode === "directplay" || mode === "direct-play" || mode === "direct_play") return "directplay"
        return "smart"
    }

    function _ensureStoreInitialized() {
        if (_storeInitialized) return true
        try {
            UserStore.init(root)
            _storeInitialized = true
            return true
        } catch(e0) {}
        return false
    }

    function _ensureUserStoreContext() {
        if (!_ctxOk() || !_ensureStoreInitialized()) return false
        try {
            if (UserStore.ensureUserPrefsContext)
                return UserStore.ensureUserPrefsContext(serverUrl, userId) === true
            return true
        } catch(e0) {}
        return false
    }

    function _scheduleSync() {
        if (_syncScheduled) return
        _syncScheduled = true
        Qt.callLater(function() {
            _syncScheduled = false
            root._syncFromStore()
        })
    }

    function _syncFromStore() {
        if (!_ctxOk()) return
        var clock = !!get("showClock", true)
        var mode = normalizePlaybackMode(get("playbackMode", "smart"))
        _syncing = true
        if (showClock !== clock) showClock = clock
        if (playbackMode !== mode) playbackMode = mode
        _syncing = false
    }

    function init(fbxCtx, settingsCtx) {
        // main.qml est l'autorité d'initialisation et injecte explicitement Settings.
        // Le fallback via fbxCtx reste défensif pour les anciens environnements de test.
        var nextSettings = settingsCtx
        if ((nextSettings === undefined || nextSettings === null) && fbxCtx) {
            try { nextSettings = fbxCtx.settingsRef } catch(e0) {}
            if (nextSettings === undefined || nextSettings === null) {
                try { nextSettings = fbxCtx.settings } catch(e1) {}
            }
        }
        if (nextSettings !== undefined && nextSettings !== null) {
            if (settingsRef !== nextSettings) {
                settingsRef = nextSettings
                _storeInitialized = false
            }
        }

        _ensureStoreInitialized()
        _scheduleSync()
    }

    function setContext(srv, uid) {
        var newSrv = _normServer(srv)
        var newUid = String(uid || "")
        var hadValid = _ctxOk()
        var incomingValid = newSrv.length > 0 && newUid.length > 0

        if (!incomingValid && hadValid) {
            // On n'accepte qu'un clear complet ; un contexte partiel transitoire
            // ne doit jamais faire basculer les préférences sur un namespace vide.
            if (!newSrv && !newUid) {
                serverUrl = ""
                userId = ""
            }
            return
        }

        var changed = false
        if (serverUrl !== newSrv) { serverUrl = newSrv; changed = true }
        if (userId !== newUid) { userId = newUid; changed = true }
        if (changed) _scheduleSync()
    }

    function get(name, defVal) {
        if (!_ctxOk() || !_ensureStoreInitialized()) return defVal
        try {
            return UserStore.getUserPref(serverUrl, userId, name, defVal)
        } catch(e0) {}
        return defVal
    }

    function set(name, val) {
        if (!_ctxOk()) return
        if (name === "playbackMode") val = normalizePlaybackMode(val)
        if (!_ensureUserStoreContext()) return
        try { UserStore.setUserPref(serverUrl, userId, name, val) } catch(e0) { return }

        if (name === "showClock") {
            var clock = !!val
            if (showClock !== clock) {
                _syncing = true
                showClock = clock
                _syncing = false
            }
        } else if (name === "playbackMode") {
            var mode = normalizePlaybackMode(val)
            if (playbackMode !== mode) {
                _syncing = true
                playbackMode = mode
                _syncing = false
            }
        }
    }

    onShowClockChanged: {
        if (!_syncing && _ctxOk()) set("showClock", showClock)
    }

    onPlaybackModeChanged: {
        if (_syncing) return
        var mode = normalizePlaybackMode(playbackMode)
        if (playbackMode !== mode) {
            _syncing = true
            playbackMode = mode
            _syncing = false
        }
        if (_ctxOk()) set("playbackMode", mode)
    }

    onServerUrlChanged: _scheduleSync()
    onUserIdChanged: _scheduleSync()
}
